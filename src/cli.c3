module llmcli::cli;

import std::io;
import std::core::mem::allocators;
import std::collections::list;
import std::time::datetime;
import llmcli::buf, llmcli::config, llmcli::log, llmcli::skill, llmcli::trajectory;

// ---- 常量 ----

// 技能资产目录名：技能放在 <assets_dir>/skills/<name>/SKILL.md，默认 .agents。
const String SKILLS_ASSETS_DIR = ".agents";

// 退出码约定（PRD 已确认细分）
const int EXIT_OK = 0;           // 成功
const int EXIT_FAILURE = 1;      // 网络/API/协议错误
const int EXIT_USAGE = 2;        // 用法/参数错误
const int EXIT_UNCONVERGED = 3;  // 循环未收敛

const String DEFAULT_API_URL = "https://api.openai.com/v1/chat/completions";

// 轨迹目录 flag 名：parse 与 configure_trajectory 共用，避免两处各写一遍字面量而漂移。
const String FLAG_TRAJ_DIR = "--traj-dir";
const String FLAG_CONFIG_DIR = "--config-dir";

const String USAGE = `用法：llmcli --model <id> --api-key <key> [flags] [<prompt>]`;

// ---- 类型 ----

// 一次运行（一个 Trace）的全部配置。经函数参数向下传递，不是全局：
// 同一进程内换一份 Ctx 再跑一次是合法用法（比如给后续的子运行换一套提示词或边界）。
//
// 字段分五类。新增字段必须先归入某一类，别让它退化回"什么都往里塞"的篮子。
struct Ctx
{
	// --- 初始设置：本次运行的固定前提，运行期间不变，换了就等于换一次运行 ---
	String api_key;      // 端点密钥；仅用于 Authorization，日志里由 log 脱敏
	String api_url;      // 端点，默认 DEFAULT_API_URL
	String model;        // 模型 id，原样进请求体
	String config_dir;   // 配置根目录（轨迹落盘位置）；空 = 用默认 ~/.llmcli

	// --- 本次运行边界：约束这一次 Trace 的范围，运行期间同样不变 ---
	String traj_id;         // 非空 = 续接/写入该轨迹目录名（--traj）；空 = 新建
	bool resume;            // --resume：续接既有轨迹（配合 --traj 指定 id，缺省续最近的）
	String workdir;         // 生成代码的工作目录（--workdir）；空 = 继承当前目录
	String[] vars;          // 传入生成代码的环境变量（--var NAME=VALUE，可重复）
	String system_prompt;   // 已展开占位符；空 = 用一个空的 system 消息（resolve 会回填默认提示词）
	String user_input;      // 本次要问的内容（mem 堆串，调用方负责释放）
	int max_iterations;     // 0 或负数 = 循环不设上限
	usz max_bytes;          // context 渲染预算；0 = 不限
	String context_scope;   // traj / run；空 = traj
	int inactivity_timeout; // 看门狗：空闲秒数；0 = 用默认；<0 = 关闭
	usz max_output_size;    // 看门狗：输出字节；0 = 用默认
	int max_exec_time;      // 看门狗：墙钟秒数；0 = 用默认；<0 = 关闭

	// --- 解析中间量：只在 parse/resolve 里用，agent 一次都不读。
	//     resolve 成功后 prompt / system_prompt_file 必然被搬空（进 user_input / system_prompt），
	//     input_file 留着只为报错能指名道姓。run 与工具都别依赖它们。 ---
	String system_prompt_file;
	String input_file;
	String prompt;
	String traj_dir;        // 解析中间量：轨迹根目录（--traj-dir），resolve 后搬到 trajectory 模块
	bool no_config;         // 解析中间量：--no-config，跳过整份 llmcli.json（只在 resolve 里读）

	// --- 日志开关：只影响 stderr 的过程日志，与请求/落盘内容无关 ---
	bool quiet;        // stderr 只保留错误
	bool debug;        // stderr 额外打印原始请求/响应
	bool no_color;     // 关闭 stderr 颜色

	// --- 动作开关：不改运行配置，只决定 main 走哪条路（然后立刻返回） ---
	bool print_system_prompt;
	bool help;
}

struct ParseResult
{
	Ctx ctx;
	Seen seen;
	String error;
}

// 哪些配置键被命令行显式给出：config 只在对应 flag **没有**出现时才回填该字段
// （优先级 默认 < 配置 < flag）。只由 parse 填、resolve 读；不进 agent，也不属 Ctx。
struct Seen
{
	bool api_key;
	bool api_url;
	bool model;
	bool traj_dir;
	bool workdir;
	bool system_prompt;
	bool system_prompt_file;
	bool max_iterations;
	bool context_scope;
	bool max_bytes;
	bool inactivity_timeout;
	bool max_output_size;
	bool max_exec_time;
	bool vars;
	bool debug;
	bool no_color;
}

// 子命令参数扫描结果：rest 是去掉目录 flag 后的参数，error 非空 = 配置读取失败（退出码 2）。
struct TrajArgs
{
	String[] rest;
	String error;
}

// ---- 纯解析（无 I/O） ----

// 纯解析：只看 argv，不读 stdin、不读任何文件。
// --help 在这里就短路返回——它必须在碰 stdin 之前结束，
// 否则 `llmcli --help` 在终端里会阻塞等输入。
fn ParseResult parse(String[] args)
{
	ParseResult res;
	Ctx* o = &res.ctx;
	o.api_url = DEFAULT_API_URL;
	o.context_scope = "traj";
	List{String} vars;
	vars.init(tmem);
	bool seen_prompt = false;

	usz i = 1;
	while (i < args.len)
	{
		String arg = args[i];
		// -h 不以 -- 开头，得在位置参数分支之前单独认，否则被当 prompt 吃掉
		if (arg == "-h") { o.help = true; i++; continue; }
		// -p <task>：显式 prompt。给了它时命令名不会被派发（见 cmd/main），
		// 所以 `llmcli -p traj` 是把 "traj" 当任务，而不是跑 traj 子命令。
		if (arg == "-p")
		{
			if (seen_prompt)
			{
				res.error = "只接受一个 prompt";
				return res;
			}
			if (!take_value(args, &i, arg, "", false, &o.prompt, &res.error)) return res;
			seen_prompt = true;
			i++;
			continue;
		}
		if (!arg.starts_with("--"))
		{
			if (seen_prompt)
			{
				res.error = "只接受一个位置参数 prompt（或用 -p / --input-file）";
				return res;
			}
			o.prompt = arg;
			seen_prompt = true;
			i++;
			continue;
		}

		String name = arg;
		String inline_value = "";
		bool has_inline = false;
		if (try eq = arg.index_of_char('='))
		{
			if (eq > 2)
			{
				usz cut = (usz)eq;
				has_inline = true;
				name = arg[:cut];
				inline_value = arg[cut + 1 .. ^1];
			}
		}

		if (name == "--prompt")
		{
			if (seen_prompt)
			{
				res.error = "只接受一个 prompt";
				return res;
			}
			if (!take_value(args, &i, name, inline_value, has_inline, &o.prompt, &res.error)) return res;
			seen_prompt = true;
			i++;
			continue;
		}
		if (name == "-h" || name == "--help") { o.help = true; i++; continue; }
		if (name == "--quiet") { o.quiet = true; i++; continue; }
		if (name == "--debug") { o.debug = true; res.seen.debug = true; i++; continue; }
		if (name == "--no-color") { o.no_color = true; res.seen.no_color = true; i++; continue; }
		if (name == "--no-config") { o.no_config = true; i++; continue; }
		if (name == "--print-system-prompt") { o.print_system_prompt = true; i++; continue; }
		if (name == "--resume") { o.resume = true; i++; continue; }

		if (name == "--max-iterations")
		{
			String value;
			if (!take_value(args, &i, name, inline_value, has_inline, &value, &res.error)) return res;
			int? iters = value.to_int();
			if (catch err = iters)
			{
				res.error = string::tformat("%s 需要整数，收到 %s", name, value);
				return res;
			}
			res.seen.max_iterations = true;
			// <=0 视为不设上限（与"没给这个参数"等价）
			if (iters > 0) o.max_iterations = iters;
			i++;
			continue;
		}
		if (name == "--max-bytes")
		{
			String value;
			if (!take_value(args, &i, name, inline_value, has_inline, &value, &res.error)) return res;
			int? bytes = value.to_int();
			if (catch err = bytes)
			{
				res.error = string::tformat("--max-bytes 需要整数，收到 %s", value);
				return res;
			}
			res.seen.max_bytes = true;
			if (bytes > 0) o.max_bytes = (usz)bytes;
			i++;
			continue;
		}
		if (name == "--inactivity-timeout" || name == "--max-exec-time")
		{
			String value;
			if (!take_value(args, &i, name, inline_value, has_inline, &value, &res.error)) return res;
			int? secs = value.to_int();
			if (catch err = secs)
			{
				res.error = string::tformat("%s 需要整数，收到 %s", name, value);
				return res;
			}
			if (name == "--inactivity-timeout")
			{
				res.seen.inactivity_timeout = true;
				o.inactivity_timeout = secs;
			}
			else
			{
				res.seen.max_exec_time = true;
				o.max_exec_time = secs;
			}
			i++;
			continue;
		}
		if (name == "--max-output-size")
		{
			String value;
			if (!take_value(args, &i, name, inline_value, has_inline, &value, &res.error)) return res;
			int? bytes = value.to_int();
			if (catch err = bytes)
			{
				res.error = string::tformat("--max-output-size 需要整数，收到 %s", value);
				return res;
			}
			res.seen.max_output_size = true;
			if (bytes > 0) o.max_output_size = (usz)bytes;
			i++;
			continue;
		}
		if (name == "--context-scope")
		{
			String value;
			if (!take_value(args, &i, name, inline_value, has_inline, &value, &res.error)) return res;
			if (value != "traj" && value != "run")
			{
				res.error = string::tformat("--context-scope 只能是 traj 或 run，收到 %s", value);
				return res;
			}
			res.seen.context_scope = true;
			o.context_scope = value;
			i++;
			continue;
		}
		if (name == "--var")
		{
			String value;
			if (!take_value(args, &i, name, inline_value, has_inline, &value, &res.error)) return res;
			if (!value.contains("="))
			{
				res.error = string::tformat("--var 需要 NAME=VALUE 形式，收到 %s", value);
				return res;
			}
			res.seen.vars = true;
			vars.push(value.copy(mem));
			i++;
			continue;
		}

		String* slot = null;
		if (name == "--api-key") { slot = &o.api_key; res.seen.api_key = true; }
		if (name == "--api-url") { slot = &o.api_url; res.seen.api_url = true; }
		if (name == "--model") { slot = &o.model; res.seen.model = true; }
		if (name == "--traj") slot = &o.traj_id;
		if (name == FLAG_TRAJ_DIR) { slot = &o.traj_dir; res.seen.traj_dir = true; }
		if (name == FLAG_CONFIG_DIR) slot = &o.config_dir;
		if (name == "--workdir") { slot = &o.workdir; res.seen.workdir = true; }
		if (name == "--system-prompt") { slot = &o.system_prompt; res.seen.system_prompt = true; }
		if (name == "--system-prompt-file") { slot = &o.system_prompt_file; res.seen.system_prompt_file = true; }
		if (name == "--input-file") slot = &o.input_file;

		if (!slot)
		{
			res.error = string::tformat("未知参数 %s", name);
			return res;
		}
		if (!take_value(args, &i, name, inline_value, has_inline, slot, &res.error)) return res;
		i++;
	}
	o.vars = vars.to_array(mem);

	// --system-prompt / --system-prompt-file 互斥对所有模式都成立，放在动作短路之前
	if (o.system_prompt.len && o.system_prompt_file.len)
	{
		res.error = "--system-prompt 与 --system-prompt-file 互斥";
		return res;
	}

	// --help / --print-system-prompt 不需要 api-key、model 与输入
	if (o.help || o.print_system_prompt) return res;

	// traj-id 会直接当目录名用，在读任何输入之前先挡住路径穿越与非法字符
	if (o.traj_id.len && !trajectory::valid_id(o.traj_id))
	{
		res.error = "--traj 只能包含文件名安全字符，且不能含 ..";
		return res;
	}

	// 输入来源判定：
	//   1) 显式来源（-p / 位置参数 / --input-file）优先；同时给多个才是用法错误。
	//   2) 都没给时，stdin 是管道则用管道内容（isatty 只问一句，不读内容）。
	//   3) 都没给、stdin 也不是管道 → 缺输入。
	// 显式来源存在时不看 stdin：这样生成代码起子代理用的 `llmcli -p "<task>"`（其 stdin 被父
	// 进程接 /dev/null、非 tty）不会被误判成"输入 + stdin 管道"冲突。
	usz explicit_count = (usz)((o.prompt.len ? 1 : 0) + (o.input_file.len ? 1 : 0));
	if (explicit_count > 1)
	{
		res.error = "输入必须三选一（-p / 位置参数 / --input-file），不能同时给";
		return res;
	}
	if (explicit_count == 0 && io::stdin().isatty())
	{
		res.error = "缺少输入：请用 -p、位置参数、stdin 管道或 --input-file 提供 prompt";
		return res;
	}
	return res;
}

// 从 argv 里取值：支持 `--flag value` 与 `--flag=value` 两种形态。
fn bool take_value(String[] args, usz* i, String flag, String inline_value,
                   bool has_inline, String* out, String* error)
{
	if (has_inline)
	{
		*out = inline_value;
		return true;
	}
	if (*i + 1 >= args.len)
	{
		*error = string::tformat("%s 缺少参数值", flag);
		return false;
	}
	*i += 1;
	*out = args[*i];
	return true;
}

// ---- 补齐运行输入（有 I/O） ----

// 在 argv 里找 --traj-dir / --config-dir / --no-config 并配置轨迹根，返回去掉这些 flag
// （及其值）后的参数列表与错误。命令群（traj/context/skills）没有完整 Ctx，但也吃配置里
// 的 traj_dir：
//   轨迹根 = --traj-dir > 配置的 traj_dir > <config-dir>/traj（再默认 ~/.llmcli/traj）。
// 这是**唯一**一处扫这两个目录 flag 的地方，flag 知识不再散落到 cmd 层；因涉及读配置，它有
// I/O，所以放在补齐阶段而非纯解析段。认 `--flag value` 与 `--flag=value` 两种形态。
fn TrajArgs configure_trajectory(String[] args)
{
	TrajArgs res;
	String traj_dir = "";
	String config_dir = "";
	bool no_config = false;
	List{String} rest;
	rest.init(tmem);
	for (usz i = 0; i < args.len; i++)
	{
		String a = args[i];
		if (a == FLAG_TRAJ_DIR || a == FLAG_CONFIG_DIR)
		{
			if (i + 1 < args.len)
			{
				if (a == FLAG_TRAJ_DIR)
				{
					traj_dir = args[i + 1];
				}
				else
				{
					config_dir = args[i + 1];
				}
				i++;
			}
			continue;
		}
		if (a.starts_with(FLAG_TRAJ_DIR +++ "="))
		{
			traj_dir = a[11..];
			continue;
		}
		if (a.starts_with(FLAG_CONFIG_DIR +++ "="))
		{
			config_dir = a[13..];
			continue;
		}
		if (a == "--no-config")
		{
			no_config = true;
			continue;
		}
		rest.push(a);
	}

	// 子命令也读整份配置（坏配置照样退出码 2），但只吃 traj_dir；--no-config 整份跳过。
	// 轨迹根只回填 flag 没给的情况，保持 --traj-dir 的优先级。
	if (!no_config)
	{
		config::LoadResult loaded = config::load(config_dir);
		if (loaded.error.len)
		{
			res.error = loaded.error;
			return res;
		}
		if (!traj_dir.len && loaded.settings.h_traj_dir) traj_dir = loaded.settings.traj_dir;
	}

	if (traj_dir.len || config_dir.len) trajectory::configure(traj_dir, config_dir);
	res.rest = rest.to_array(tmem);
	return res;
}

// parse + 补齐运行所需的一切：系统提示词与用户输入也在这里读取。
// 注意有 I/O 副作用：stdin 是管道时会阻塞到 EOF，--input-file / --system-prompt-file 会读文件。
fn ParseResult resolve(String[] args)
{
	ParseResult res = parse(args);
	Ctx* o = &res.ctx;
	if (res.error.len || o.help) return res;

	// 配置是文件 I/O，只能在补齐阶段读；--help 已在上面短路，所以看帮助永不读配置。
	// 先按 flag 初始化日志，让配置加载期的告警也听 --quiet / --no-color（配置里的
	// debug/no_color 由 main 在 resolve 后重新 init 时生效）。
	log::init(o.quiet, o.debug, o.no_color);
	if (!o.no_config)
	{
		config::LoadResult loaded = config::load(o.config_dir);
		if (loaded.error.len)
		{
			res.error = loaded.error;
			return res;
		}
		apply_config(o, &res.seen, &loaded.settings);
	}

	if (o.system_prompt_file.len)
	{
		// 读进来后统一走 expand_prompt_placeholders 复制到 mem，这里用 tmem 不留中间缓冲
		char[]? data = file::load(tmem, o.system_prompt_file);
		if (catch err = data)
		{
			res.error = string::tformat("无法读取 --system-prompt-file %s（%s）",
			                           o.system_prompt_file, err);
			return res;
		}
		o.system_prompt = (String)data;
	}

	// --print-system-prompt：只装配系统提示词给 main 打印，不要求 api-key / model，也不碰输入
	if (o.print_system_prompt)
	{
		assemble_system_prompt(o);
		return res;
	}

	if (!o.api_key.len)
	{
		res.error = "--api-key 必填（不读环境变量兜底）";
		return res;
	}
	if (!o.model.len)
	{
		res.error = "--model 必填";
		return res;
	}

	if (o.input_file.len)
	{
		char[]? data = file::load(mem, o.input_file);
		if (catch err = data)
		{
			res.error = string::tformat("无法读取 --input-file %s（%s）", o.input_file, err);
			return res;
		}
		o.user_input = (String)data;
	}
	else if (o.prompt.len)
	{
		o.user_input = o.prompt;
	}
	else
	{
		// 管道输入可长，LIBC_ALLOCATOR 脱离 @pool；读失败按 EOF 处理（?? 吞掉错误，保留已读部分）。
		DString raw;
		raw.init(&allocators::LIBC_ALLOCATOR);
		defer raw.free();
		raw.read_from_stream(io::stdin()) ?? 0;
		o.user_input = raw.copy_str(mem);
	}

	if (!o.user_input.len)
	{
		res.error = "输入为空";
		return res;
	}

	// 系统提示词：没给就用编译期嵌入的默认提示词（src/system_prompt.md），再展开环境占位符。
	// 放在最后，让参数错误路径不产生 mem 分配。
	assemble_system_prompt(o);
	return res;
}

// 把配置回填进 Ctx：只改 flag **未显式给出**的字段（优先级 默认 < 配置 < flag）。
// 数值与同名 flag 语义完全一致（含 0/负数的"不限/用默认/关闭"哨兵含义）。
fn void apply_config(Ctx* o, Seen* seen, config::Settings* s) @private
{
	if (s.h_api_key && !seen.api_key) o.api_key = s.api_key;
	if (s.h_api_url && !seen.api_url) o.api_url = s.api_url;
	if (s.h_model && !seen.model) o.model = s.model;
	if (s.h_traj_dir && !seen.traj_dir) o.traj_dir = s.traj_dir;
	if (s.h_workdir && !seen.workdir) o.workdir = s.workdir;

	if (s.h_max_iterations && !seen.max_iterations)
	{
		o.max_iterations = s.max_iterations > 0 ? s.max_iterations : 0;
	}
	if (s.h_max_bytes && !seen.max_bytes) o.max_bytes = s.max_bytes > 0 ? (usz)s.max_bytes : 0;
	if (s.h_inactivity_timeout && !seen.inactivity_timeout) o.inactivity_timeout = s.inactivity_timeout;
	if (s.h_max_output_size && !seen.max_output_size)
	{
		o.max_output_size = s.max_output_size > 0 ? (usz)s.max_output_size : 0;
	}
	if (s.h_max_exec_time && !seen.max_exec_time) o.max_exec_time = s.max_exec_time;
	if (s.h_context_scope && !seen.context_scope) o.context_scope = s.context_scope;

	// 布尔开关：配置能开；本次不提供反义 flag，命令行关不掉（要关就 --no-config 整份跳过）。
	if (s.h_debug && !seen.debug) o.debug = s.debug;
	if (s.h_no_color && !seen.no_color) o.no_color = s.no_color;

	// var：配置提供基础，命令行逐键追加/覆盖（配置先、CLI 后；执行时后写的胜出）。
	// 结果整体落在 mem（Ctx 里长期使用），旧 CLI 数组随即释放。
	if (s.h_var)
	{
		List{String} out;
		out.init(tmem);
		foreach (v : s.vars) out.push(string::format(mem, "%s=%s", v.name, v.value));
		if (seen.vars)
		{
			foreach (v : o.vars) out.push(v);
			if (o.vars.len) free(o.vars.ptr);
		}
		o.vars = out.to_array(mem);
	}

	// 系统提示词来源二选一：flag 只要给了任一来源，本次运行就由 flag 决定，配置两个来源键都忽略
	// （否则配置的 system_prompt_file 会反过来覆盖 flag 的 --system-prompt）。
	if (!seen.system_prompt && !seen.system_prompt_file)
	{
		if (s.h_system_prompt) o.system_prompt = s.system_prompt;
		if (s.h_system_prompt_file) o.system_prompt_file = s.system_prompt_file;
	}
}

// 装配系统提示词：来源（--system-prompt / --system-prompt-file / 内置默认）→ 展开占位符
// → 追加本机 skill 列表。--print-system-prompt 与真实运行共用这一处，保证打印的就是
// 实际会发给端点的内容。结果落在 o.system_prompt（mem 堆串，由调用方释放）。
fn void assemble_system_prompt(Ctx* o)
{
	if (!o.system_prompt.len) o.system_prompt = $embed("system_prompt.md");
	o.system_prompt = expand_prompt_placeholders(o.system_prompt);
	o.system_prompt = inject_skills(o.system_prompt);
}

fn String host_os()
{
	$switch:
	$case env::WIN32:
		return "Windows";
	$case env::MACOS:
		return "macOS";
	$default:
		return "Linux";
	$endswitch
}

// 系统提示词里的环境占位符：默认提示词与 --system-prompt / --system-prompt-file 通用。
// 结果总是 mem 上的新串，与 --input-file 读入的 user_input 一样由调用方持有。
fn String expand_prompt_placeholders(String text)
{
	String date = datetime::now().to_local().format(tmem, DateTimeFormat.DATEONLY);
	String cwd = ".";
	if (try found = path::tcwd()) cwd = (String)found;

	// 复用 std 的 DString.replace（就地替换、自动扩容）。占位符全是 ASCII，
	// 字节级匹配不会命中多字节 UTF-8 字符内部，未命中部分按字节原样搬运。
	DString out = dstring::new(tmem, text);
	out.replace("{{date}}", date);
	out.replace("{{cwd}}", cwd);
	out.replace("{{os}}", host_os());
	return out.copy_str(mem);
}

// 把本机发现的 skill 列表追加到系统提示词末尾（发现与组装在 skill 模块）。
// 无 skill 时原样返回，系统提示词里不留任何痕迹。
fn String inject_skills(String prompt)
{
	skill::SkillHub hub;
	hub.init(mem, SKILLS_ASSETS_DIR);
	defer hub.free();

	String block = hub.print_installed(tmem);
	if (!block.len) return prompt;

	// prompt 一定来自 expand_prompt_placeholders 的 mem 堆串，拼接后旧串即可释放
	String appended = string::format(mem, "%s\n\n## 可用技能\n\n%s\n", prompt, block);
	free(prompt.ptr);
	return appended;
}

// ---- --help 文本（就是这个 CLI 的产品文档） ----

const String HELP = `llmcli - 把 LLM 接进 shell 流水线

用法：llmcli --model <id> --api-key <key> [flags] [<prompt>]
      llmcli <命令> [参数]        # 子命令：shellm / traj / context / skills

一次运行即一条 trajectory：模型回复一个 ` +++ "```bash" +++ ` 代码块，本地以 bash 执行，
输出作为下一条 user 消息回填，循环直到代码里设置 FINAL / FINAL_FILE——bash 是唯一的工具。
trajectory 是唯一真相源：每轮 messages 从 trajectory 重渲染。

输入（-p / 位置参数 / --input-file 三选一，不能同时给；都不给时读 stdin 管道）：
  -p, --prompt <text>      显式 prompt（推荐用于脚本 / 子代理：任务名撞子命令也不歧义）
  <prompt>                 位置参数，直接写在命令行上
  --input-file <file>      从文件读取（UTF-8）
  stdin                    管道输入，如 cat x.md | llmcli ...（未给上面三者时才用）

必备参数：
  --api-key <key>          API 密钥；不读环境变量兜底，缺失即用法错误
  --model <id>             模型 id
  --api-url <url>          端点，默认 ` +++ DEFAULT_API_URL +++ `

可选参数：
  --traj <id>              续接/写入既有轨迹目录；不给则新建
  --resume                 续接既有轨迹（配合 --traj）
  --traj-dir <dir>         轨迹根目录；默认 <config-dir>/traj（再默认 ~/.llmcli/traj）
  --config-dir <dir>       配置目录根：llmcli.json 与轨迹落盘位置的根，默认 ~/.llmcli
                           不读任何环境变量
  --no-config              跳过整份 llmcli.json，只用内置默认 + 命令行 flag
  --max-iterations <n>     最多发起 n 次请求（n>0 生效）；不给或 <=0 表示不设上限
  --context-scope <s>      渲染范围 traj | run（默认 traj）
  --max-bytes <n>          context 渲染预算（字节）；0 = 不限
  --workdir <dir>          生成代码的工作目录
  --var NAME=VALUE         传入生成代码的环境变量（可重复）
  --inactivity-timeout <s> 看门狗：无输出超过 s 秒即杀（默认 120；<=0 关闭）
  --max-output-size <n>    看门狗：累计输出超过 n 字节即杀（默认 10485760）
  --max-exec-time <s>      看门狗：墙钟超过 s 秒即杀（默认 1800；<=0 关闭）
  --system-prompt <text>   系统提示词（与 --system-prompt-file 互斥）
  --system-prompt-file <f> 系统提示词文件
                           两者都不给时用内置默认提示词（src/system_prompt.md）；
                           三种来源都支持 {{date}} / {{cwd}} / {{os}} 占位符
  --print-system-prompt    打印本次实际会发给端点的系统提示词（含已注入的 skill 列表），随后退出
  --quiet                  stderr 只保留错误
  --debug                  stderr 额外打印原始请求/响应（密钥已脱敏）
  --no-color               关闭 stderr 颜色
  -h, --help               打印本帮助

配置文件（llmcli.json）：
  启动时自动读取 <config-dir>/llmcli.json（config-dir 默认 ~/.llmcli），一次写好常用偏好，
  日常只给"本次输入"。优先级固定为：内置默认值 < llmcli.json < 命令行 flag。
  不存在则静默跳过；可用 --no-config 整份关闭。--help 不读配置文件。
  键名 = 同名 flag 去掉 -- 并把连字符换成下划线；键缺失才落到内置默认：
    api_key, api_url, model, traj_dir, workdir,
    system_prompt, system_prompt_file（两者互斥）,
    max_iterations, context_scope, max_bytes,
    inactivity_timeout, max_output_size, max_exec_time,
    var（对象，NAME -> VALUE）, debug, no_color
  以下 flag 不属于持久偏好，配置文件里不认（写了按未知键告警并忽略）：
    -h/--help、--print-system-prompt、-p/--prompt/位置参数、--input-file、--traj、--resume、
    --config-dir、--quiet、--no-config。
  JSON 语法错误或值类型不符会立刻报错（退出码 2）；未知键只告警不失败。
  示例：{"model":"gpt-4o-mini","api_url":"https://...","max_iterations":20}
  风险：api_key 写进配置文件即为明文落盘，是使用者显式选择；程序自身绝不写回任何密钥。

子命令（命令名必须是第一个参数；子命令自身只认 --traj-dir / --config-dir / --no-config）：
  llmcli traj list [--children]   列出轨迹；--children 额外标注 fork/merge 子关系
  llmcli traj show <name> [--full] 打印某条轨迹的全部步骤（--full 不截断正文）
  llmcli traj tail <name> [n]     打印末尾 n 步
  llmcli traj search <name> <pat> 按子串搜索步骤
  llmcli context [--traj <name>]  打印渲染出的 messages
  llmcli skills             列出本机可用 skill

子代理：生成代码里再调用一次本二进制就是子代理，用 -p 给任务最稳（父轨迹会记 fork/merge）：

  llmcli -p "<子任务>" --traj-dir "$TRAJ_DIR" --model "$MODEL" \
    --api-key "$API_KEY" --api-url "$API_URL" > 子代理.log 2>&1 &

退出码：
  0  成功
  1  网络/API/协议错误
  2  用法/参数错误
  3  循环未收敛（无最终答案）
  130 被使用者中断（Ctrl+C / Ctrl+Break；进行中的子进程会被一并终止）

示例：
  llmcli --model gpt-4o-mini --api-key $KEY "用一句话解释什么是快排"
  llmcli --model gpt-4o-mini --api-key $KEY -p "用一句话解释什么是快排"
  cat README.md | llmcli --model gpt-4o-mini --api-key $KEY
  llmcli --model gpt-4o-mini --api-key $KEY --system-prompt-file sys.md \
         --input-file article.md --traj work

注意：输入来源为 -p / 位置参数 / --input-file 三选一（不能同时给）。三者都不给时若 stdin 是
      管道则读管道，否则报"缺少输入"。显式给了其中之一就忽略 stdin——这正是生成代码写
      llmcli -p "<子任务>"（stdin 被父进程接 /dev/null）能直接工作的原因。
      要用任务拿内容又听指令，请把指令写进 --system-prompt / --system-prompt-file，内容走
      stdin 或 --input-file。
      子命令名（traj/context/skills）是保留字：裸位置参数恰好是它们会被当子命令；要用同名任务，
      请用 -p traj 或 stdin / --input-file。

系统提示词还会自动追加本机可用 skill 列表（发现于 ~/.agents/skills 与
  ./.agents/skills 下各 <name>/SKILL.md），模型可据此用 bash 读取并照其执行。
  用 llmcli skills 查看当前发现了哪些。

轨迹存储：
  默认 <根目录>/<hex8>-<slug>/trajectory.jsonl（首步 UUID 前 8 位 + 输入 slug），
  根目录 = --traj-dir，或 ~/.llmcli/traj；环境变量不参与决定位置。
  每行一个 Step（JSON），append 原子：中断或报错时文件末尾永远是完整步骤。
  大字段（超 8 KiB）spill 到同目录 blobs/。v1 不提供清理功能，请自行删除目录。
  落盘内容可能含敏感信息，注意存放位置。

风险提示：
  模型生成的 bash 代码默认放行任意命令，提示注入或模型误判可导致任意代码执行。
  每轮执行的代码原文都会打印到 stderr 供审计。默认不设 iteration 上限（执行器有
  空闲/输出量/墙钟三看门狗）；失控请用 Ctrl+C 中断，CI 中请用外部超时
  （如 timeout 60 llmcli ...）包裹。

CI/脚本集成：
  无需任何交互输入；stdout 只包含最终答案，可直接重定向或交给 jq。
  输出不是终端时不使用 ANSI 颜色。`;
