module llmcli::cli;

import std::io;
import std::core::mem::allocators;
import std::collections::list;
import std::time::datetime;
import llmcli::buf, llmcli::skill, llmcli::trajectory;

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
		if (name == "--debug") { o.debug = true; i++; continue; }
		if (name == "--no-color") { o.no_color = true; i++; continue; }
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
				o.inactivity_timeout = secs;
			}
			else
			{
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
			vars.push(value.copy(mem));
			i++;
			continue;
		}

		String* slot = null;
		if (name == "--api-key") slot = &o.api_key;
		if (name == "--api-url") slot = &o.api_url;
		if (name == "--model") slot = &o.model;
		if (name == "--traj") slot = &o.traj_id;
		if (name == FLAG_TRAJ_DIR) slot = &o.traj_dir;
		if (name == FLAG_CONFIG_DIR) slot = &o.config_dir;
		if (name == "--workdir") slot = &o.workdir;
		if (name == "--system-prompt") slot = &o.system_prompt;
		if (name == "--system-prompt-file") slot = &o.system_prompt_file;
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

// 在 argv 里找 --traj-dir / --config-dir 并配置轨迹根，返回去掉这两个 flag（及其值）后的
// 参数列表。命令群（traj/context）没有完整 Ctx，但也要认这两个 flag；这是**唯一**一处扫
// 这两个 flag 的地方，flag 知识不再散落到 cmd 层。
// 认 `--flag value` 与 `--flag=value` 两种形态。
fn String[] configure_trajectory(String[] args)
{
	String traj_dir = "";
	String config_dir = "";
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
		rest.push(a);
	}
	if (traj_dir.len || config_dir.len) trajectory::configure(traj_dir, config_dir);
	return rest.to_array(tmem);
}

// ---- 补齐运行输入（有 I/O） ----

// parse + 补齐运行所需的一切：系统提示词与用户输入也在这里读取。
// 注意有 I/O 副作用：stdin 是管道时会阻塞到 EOF，--input-file / --system-prompt-file 会读文件。
fn ParseResult resolve(String[] args)
{
	ParseResult res = parse(args);
	Ctx* o = &res.ctx;
	if (res.error.len || o.help) return res;
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
  --config-dir <dir>       配置目录根；只影响轨迹落盘位置，默认 ~/.llmcli
                           不读任何环境变量
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

子命令（命令名必须是第一个参数；子命令自身只认 --traj-dir / --config-dir）：
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
