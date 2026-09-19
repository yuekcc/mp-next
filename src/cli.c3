module llmcli::cli;

import std::io;
import std::time::datetime;
import llmcli::buf, llmcli::session;

// 退出码约定（PRD 已确认细分）
const int EXIT_OK = 0;           // 成功
const int EXIT_FAILURE = 1;      // 网络/API/协议错误
const int EXIT_USAGE = 2;        // 用法/参数错误
const int EXIT_UNCONVERGED = 3;  // 循环未收敛

const String DEFAULT_API_URL = "https://api.openai.com/v1/chat/completions";

const String USAGE = `用法：llmcli --model <id> --api-key <key> [flags] [<prompt>]`;

const String HELP = `llmcli - 把 LLM 接进 shell 流水线

用法：llmcli --model <id> --api-key <key> [flags] [<prompt>]

输入（三选一，不能同时给）：
  <prompt>                 位置参数，直接写在命令行上
  stdin                    管道输入，如 cat x.md | llmcli ...
  --input-file <file>      从文件读取（UTF-8）

必备参数：
  --api-key <key>          API 密钥；不读环境变量兜底，缺失即用法错误
  --model <id>             模型 id
  --api-url <url>          端点，默认 ` +++ DEFAULT_API_URL +++ `

可选参数：
  --session-id <id>        会话 id；同一 id 跨调用累积历史
  --max-turns <n>          最多发起 n 次请求（n>0 生效）；不给或 <=0 表示不设上限
  --system-prompt <text>   系统提示词（与 --system-prompt-file 互斥）
  --system-prompt-file <f> 系统提示词文件
                           两者都不给时用内置默认提示词（src/system_prompt.md）；
                           三种来源都支持 {{date}} / {{cwd}} / {{os}} 占位符
  --list-sessions          列出已有会话（id、更新时间、消息数），随后退出
  --quiet                  stderr 只保留错误
  --debug                  stderr 额外打印原始请求/响应（密钥已脱敏）
  --no-color               关闭 stderr 颜色
  -h, --help               打印本帮助

退出码：
  0  成功
  1  网络/API/协议错误
  2  用法/参数错误
  3  循环未收敛（无最终答案）
  130 被使用者中断（Ctrl+C / Ctrl+Break；进行中的子进程会被一并终止）

示例：
  llmcli --model gpt-4o-mini --api-key $KEY "用一句话解释什么是快排"
  cat README.md | llmcli --model gpt-4o-mini --api-key $KEY
  llmcli --model gpt-4o-mini --api-key $KEY --system-prompt-file sys.md \
         --input-file article.md --session-id work

注意：位置参数 / stdin 管道 / --input-file 严格三选一。stdin 是管道时不能再写位置参数
      （cat x.md 接管道再写 "总结一下" 会报用法错误）。要让模型既看内容又听指令，请把指令
      写进 --system-prompt / --system-prompt-file，内容走 stdin 或 --input-file。

会话存储：
  默认 %USERPROFILE%\.llmcli\sessions\<id>.jsonl（可用 LLMCLI_HOME 覆盖根目录）。
  文件按行记录完整对话（含工具输出与 reasoning_content），v1 不提供清理功能，
  请自行删除对应文件。落盘内容可能含敏感信息，注意存放位置。

风险提示：
  内置 Bash 工具默认放行任意命令，提示注入或模型误判可导致任意代码执行。
  每次调用的命令原文都会打印到 stderr 供审计。默认不设 turn 上限、不设超时、
  不截断工具输出；不设 --max-turns 时失控请用 Ctrl+C 中断，CI 中请用外部超时
  （如 timeout 60 llmcli ... 或 job timeout）包裹。

CI/脚本集成：
  无需任何交互输入；stdout 只包含最终答案，可直接重定向或交给 jq。
  输出不是终端时不使用 ANSI 颜色。

文档：docs/tools.md（如何新增工具）`;

struct Options
{
	String api_key;
	String api_url;
	String model;
	String session_id;
	String system_prompt;
	String system_prompt_file;
	String input_file;
	String prompt;
	String user_input;
	int max_turns;   // 0 或负数 = 不设上限
	bool quiet;
	bool debug;
	bool no_color;
	bool list_sessions;
	bool help;
}

struct ParseResult
{
	Options opts;
	String error;
}

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

// 解析 flags 并补齐运行所需的一切：系统提示词与用户输入也在这里读取。
// 注意有 I/O 副作用：stdin 是管道时会阻塞到 EOF，--input-file / --system-prompt-file 会读文件。
fn ParseResult resolve(String[] args)
{
	ParseResult res;
	Options* o = &res.opts;
	o.api_url = DEFAULT_API_URL;
	bool seen_prompt = false;

	usz i = 1;
	while (i < args.len)
	{
		String arg = args[i];
		if (!arg.starts_with("--"))
		{
			if (seen_prompt)
			{
				res.error = "只接受一个位置参数 prompt";
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

		if (name == "-h" || name == "--help") { o.help = true; i++; continue; }
		if (name == "--quiet") { o.quiet = true; i++; continue; }
		if (name == "--debug") { o.debug = true; i++; continue; }
		if (name == "--no-color") { o.no_color = true; i++; continue; }
		if (name == "--list-sessions") { o.list_sessions = true; i++; continue; }

		if (name == "--max-turns")
		{
			String value;
			if (!take_value(args, &i, name, inline_value, has_inline, &value, &res.error)) return res;
			int? parsed = value.to_int();
			if (catch err = parsed)
			{
				res.error = string::tformat("--max-turns 需要整数，收到 %s", value);
				return res;
			}
			// <=0 视为不设上限（与"没给这个参数"等价）
			if (parsed > 0) o.max_turns = parsed;
			i++;
			continue;
		}

		String* slot = null;
		if (name == "--api-key") slot = &o.api_key;
		if (name == "--api-url") slot = &o.api_url;
		if (name == "--model") slot = &o.model;
		if (name == "--session-id") slot = &o.session_id;
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

	// --help / --list-sessions 不需要 api-key、model 与输入
	if (o.help || o.list_sessions) return res;

	// session-id 会直接当文件名用，在读任何输入之前先挡住路径穿越与非法字符
	if (o.session_id.len && !session::valid_id(o.session_id))
	{
		res.error = "--session-id 只能包含文件名安全字符，且不能含 ..";
		return res;
	}

	if (o.system_prompt.len && o.system_prompt_file.len)
	{
		res.error = "--system-prompt 与 --system-prompt-file 互斥";
		return res;
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

	// 输入三选一：位置参数 / stdin 管道 / --input-file
	bool stdin_pipe = !io::stdin().isatty();
	String sources = "";
	if (o.prompt.len) sources = "位置参数";
	if (o.input_file.len) sources = sources.len ? sources.tconcat(" + --input-file") : "--input-file";
	if (stdin_pipe) sources = sources.len ? sources.tconcat(" + stdin 管道") : "stdin 管道";

	usz source_count = (usz)((o.prompt.len ? 1 : 0) + (o.input_file.len ? 1 : 0) + (stdin_pipe ? 1 : 0));
	if (source_count > 1)
	{
		res.error = string::tformat("输入必须三选一（位置参数 / stdin 管道 / --input-file），"
		                            "当前同时给了：%s", sources);
		return res;
	}
	if (source_count == 0)
	{
		res.error = "缺少输入：请用位置参数、stdin 管道或 --input-file 提供 prompt";
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
		buf::ByteBuf raw;
		defer raw.free();
		buf::read_all(io::stdin(), &raw);
		o.user_input = raw.to_string(mem);
	}

	if (!o.user_input.len)
	{
		res.error = "输入为空";
		return res;
	}

	// 系统提示词：没给就用编译期嵌入的默认提示词（src/system_prompt.md），再展开环境占位符。
	// 放在最后，让参数错误路径不产生 mem 分配。
	if (!o.system_prompt.len) o.system_prompt = $embed("system_prompt.md");
	o.system_prompt = expand_prompt_placeholders(o.system_prompt);
	return res;
}
