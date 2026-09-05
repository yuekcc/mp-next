// llm — 极简 LLM CLI（C3 版，复刻 headlong/bin/llm）+ agent loop（同文件）
// 仅支持 chat-completions 接口（OpenAI wire format：OpenAI / OpenRouter /
// openai-compatible 共用同一条 wire 路径）。HTTP 传输/SSE 分帧/重试/错误折叠已
// 抽到独立 api 模块（src/api/，见 LLM 模块化重构规格 2026-09-05）；本文件只保留
// CLI 交互层职责：参数解析、提示词组装、逐 chunk 打印（打字机）、
// usage/ledger、die/warn，以及 agent loop（2026-09-05 立项，原 cmd/agent.c3
// 并入）：agent 级 AppContext（trace 数据中心）+ run_trace 循环 + ToolHub
// 工具派发（--tools 显式 opt-in，null hub = 纯 chat）。
// 
// 领域词汇见 CONTEXT.md：Trace = 一次进程运行；Turn = 一次请求-响应往返；loop
// 唯一出口 = 响应不带 tool_calls（不设 turn 上限）。工具调用与结果只上 stderr
// --debug。
// 
// 模块名与二进制/target 名一致：llm（演进 llm_cli → llmcmd → llm）。
module llm;

import std::io, std::io::file, std::io::path, std::os, std::os::env, std::collections::list, std::core::string, std::time::datetime, libc, cjson, api, tool, util;

// Windows 当前进程 PID / TTY 探测
extern fn uint win_current_pid() @cname("GetCurrentProcessId") @feat(WIN32);
extern fn int posix_getpid() @cname("getpid") @feat(!WIN32);
extern fn int win_isatty(int fd) @cname("_isatty") @feat(WIN32);

const String USAGE = "llm — minimal LLM CLI (C3 replica of headlong/bin/llm, chat-completions only)\n" +++ "\n"
	+++ "Usage:\n"
	+++ "  llm [options] prompt...\n"
	+++ "  echo prompt | llm [options]\n"
	+++ "  llm [options] -M MESSAGES_JSON\n"
	+++ "\n"
	+++ "Options:\n"
	+++ "  -m, --model MODEL        Model to use. Default: $SHELLM_MODEL, else\n"
	+++ "                           gpt-5.5 when OPENAI_API_KEY is set\n"
	+++ "  -s, --system-prompt TEXT System prompt text\n"
	+++ "  --system-prompt-file F   Read system prompt from file\n"
	+++ "  -M, --messages JSON      Messages array JSON, e.g. [{\"role\":\"user\",\"content\":\"hi\"}]\n"
	+++ "  --messages-file F        Read messages array JSON from file\n"
	+++ "  --thinking [LEVEL]       Enable reasoning (sent as reasoning.effort).\n"
	+++ "                           LEVEL: low/high/max; omitted when not\n"
	+++ "                           given, leaving the effort to the server default.\n"
	+++ "  --tools LIST             Comma-separated tools for the agent loop\n"
	+++ "                           (ReadFile, Bash, EditFile, WriteFile, Grep,\n"
	+++ "                           Glob, ListDir, HashEditFile). Default: none\n"
	+++ "                           (plain chat, single request).\n"
	+++ "  --debug                  Debug: print request body, then stream reasoning\n"
	+++ "                           as it arrives — both to stderr, so stdout keeps\n"
	+++ "                           only the assistant's answer\n"
	+++ "  -h, --help               Show this help\n"
	+++ "\n"
	+++ "Wire format:\n"
	+++ "  Only the OpenAI chat-completions endpoint is supported. Anthropic\n"
	+++ "  messages / Gemini / adapter / OpenRouter routing are NOT implemented.\n"
	+++ "\n"
	+++ "Environment:\n"
	+++ "  OPENAI_API_KEY / LLM_API_KEY  Bearer token (LLM_API_KEY wins; when neither\n"
	+++ "                                is set no auth header is sent — local servers)\n"
	+++ "  LLM_API_URL                   Endpoint override\n"
	+++ "                                (default: https://api.openai.com/v1/chat/completions)\n"
	+++ "  LLM_MODEL                     Default model (same as -m)\n"
	+++ "  SHELLM_MODEL                  Fallback default model\n"
	+++ "  LLM_EXTRA_BODY                JSON object merged into the request body\n"
	+++ "                                (keys override defaults; e.g. llama-server:\n"
	+++ "                                '{\"chat_template_kwargs\":{\"enable_thinking\":false}}')\n"
	+++ "  LLM_PROVIDER                  Label only (ledger records); no behavior\n"
	+++ "\n"
	+++ "Examples:\n"
	+++ "  llm -m gpt-5.5 \"explain quicksort\"\n"
	+++ "  echo \"summarize this\" | llm -m gpt-4o\n"
	+++ "  LLM_API_URL=http://localhost:11434/v1/chat/completions \\\n"
	+++ "    llm -m qwen3:8b \"explain quicksort\"\n";

// ===========================================================================
// agent 级 AppContext（trace 数据中心）
// ===========================================================================
// 贯穿整个 trace 的 CLI 侧数据中心：接口设置（env/CLI 来源的字段级值）、请求
// 参数、消息历史、工具注册表引用与运行期接线（usage_file）。不持有 api 模块的
// LlmOption——run_trace 调用 api 入口前现场组装（api 模块只定义数据结构、不感知
// 配置来源，也不感知 AppContext）。

struct AppContext
{
	// 接口设置（与 api::LlmOption 字段同义；url 空 = api 模块默认端点）
	String url;
	String api_key; // Bearer token；空则不发送 Authorization（本地服务）
	String extra_body; // 原样 JSON 对象字符串；序列化时合并进请求体（同名覆盖）
	bool debug; // 请求体 dump 到 stderr 等诊断（stdout 不受影响）
	String provider_label; // provider 台账标签（CLI 写 ledger 用；api 模块不消费）
	String model;
	bool thinking; // --thinking（reasoning 对象开关）
	String thinking_level; // low/high/max，空 = 服务端默认
	List{ChatMessage} messages; // trace 消息历史（每 turn 追加 assistant/tool）
	ToolHub* hub; // null = 无工具（纯 chat）
	String usage_file; // usage/ledger 落盘目标（CLI 接线；空 = 关闭）
	// ponytail: session_id/request_id 是 mini_pi 对齐留位（v1 恒空串）；升级路径
	// = llm 接入 session 基础设施时填充（同时解锁 Task 工具注册）。
	String session_id;
	String request_id;
	String config_dir;
	bool transcript_enabled;
}

// ===========================================================================
// 小工具
// ===========================================================================

fn void die(String msg)
{
	io::eprintfn("llm: error: %s", msg);
	libc::exit(1);
}

fn void warn_msg(String s)
{
	io::eprintfn("llm: warning: %s", s);
}

// 注：trim / trim_right / to_int / starts_with / zstr_tcopy 等均直接用 std 库
// （std::core::string），不再手写等价函数。

fn String env_str(String name)
{
	String? v = env::tget_var(name);
	return v ?? "";
}

// 把 env 中的接口设置读进 AppContext 字段（env 读取属 CLI 交互层；api 模块只
// 消费数据）。url 留空 = api 模块默认端点。
fn void context_from_env(AppContext* actx)
{
	actx.url = env_str("LLM_API_URL");
	actx.api_key = env_str("LLM_API_KEY");
	if (actx.api_key.len == 0)
	{
		actx.api_key = env_str("OPENAI_API_KEY");
	}
	actx.extra_body = env_str("LLM_EXTRA_BODY");
	actx.provider_label = env_str("LLM_PROVIDER");
	if (actx.provider_label.len == 0)
	{
		actx.provider_label = "chat-completions";
	}
}

fn String now_iso_utc()
{
	DateTime dt = datetime::now();
	return string::tformat(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		(int)dt.year,
		(int)dt.month + 1,
		(int)dt.day,
		(int)dt.hour,
		(int)dt.min,
		(int)dt.sec
	);
}

fn uint current_pid()
{
	$if env::WIN32:
		return win_current_pid();
	$else
		return (uint)posix_getpid();
	$endif
}

fn bool stdin_is_tty()
{
	$if env::WIN32:
		return win_isatty(0) == 1;
	$else
		return libc::isatty(0) == 1;
	$endif
}

fn String temp_dir()
{
	String t = env_str("TEMP");
	if (t.len == 0)
	{
		t = env_str("TMPDIR");
	}
	if (t.len > 0)
	{
		return t;
	}
	Path? td = path::temp_directory(tmem);
	if (catch td)
	{
		return ".";
	}
	return (String)td;
}

fn void rm_file(String path)
{
	(void)file::delete(path);
}

fn String load_file_or_empty(String path)
{
	char[]? content_r = file::load(tmem, path);
	if (catch content_r)
	{
		return "";
	}
	return (String)content_r;
}

fn bool path_exists(String p)
{
	Path? pp = path::new(tmem, p);
	if (catch pp)
	{
		return false;
	}
	return path::exists(pp);
}

fn String load_file_arg(String path, String err_label)
{
	String content = load_file_or_empty(path);
	if (content.len == 0 && !path_exists(path))
	{
		die(string::tformat("%s: %s", err_label, path));
	}
	return content;
}

fn void mkdir_p(String dir)
{
	Path? d = path::new(tmem, dir);
	if (catch d)
	{
		return;
	}
	if (!path::is_dir(d))
	{
		(void)path::mkdir(d, true);
	}
}

fn String basename(String p)
{
	usz i = p.len;
	while (i > 0 && p[i - 1] != '/' && p[i - 1] != '\\') i--;
	return p[i:p.len - i];
}

fn String state_home()
{
	String h = env_str("HEADLONG_HOME");
	if (h.len == 0)
	{
		h = env_str("SHELLM_HOME");
	}
	if (h.len > 0)
	{
		return h;
	}
	Path? hd = path::home_directory(tmem);
	if (catch hd)
	{
		return "";
	}
	return string::tformat("%s/.headlong", (String)hd);
}

// ===========================================================================
// ChatRequest 组装（wire 结构体 / 消息解析 / JSON 序列化都在 api 模块内）
// ===========================================================================

// 组装 trace 的初始消息：system 前置；-M/--messages-file 整段结构化解析（超出
// 字段表达能力的消息原样透传）；否则单条 user prompt。追加进 agent 级
// AppContext.messages（分配在 tmem，main 生命周期内有效）。
fn void push_initial_messages(List{ChatMessage}* out, String system, String messages, String prompt)
{
	if (system.len > 0)
	{
		out.push(api::new_message(tmem, "system", system));
	}
	if (messages.len > 0)
	{
		int rc = api::parse_messages_json(tmem, out, messages);
		if (rc == -1)
		{
			die("Invalid JSON in --messages / --messages-file");
		}
		if (rc != 0)
		{
			die("--messages must be a JSON array of {role, content} objects");
		}
	}
	else
	{
		out.push(api::new_message(tmem, "user", prompt));
	}
}

// ===========================================================================
// usage / ledger（属 CLI 交互层，api 模块不感知）
// ===========================================================================

fn void write_usage(AppContext* actx, long u_in, long u_out, long u_think)
{
	if (actx.usage_file.len == 0)
	{
		return;
	}
	if (u_in < 0 && u_out < 0 && u_think < 0)
	{
		return;
	}
	DString b = dstring::new(tmem);
	b.append_char('{');
	bool first = true;
	if (u_in >= 0)
	{
		b.appendf("\"in_tok\":%d", (int)u_in);
		first = false;
	}
	if (u_out >= 0)
	{
		if (!first)
		{
			b.append_char(',');
		}
		b.appendf("\"out_tok\":%d", (int)u_out);
		first = false;
	}
	if (u_think >= 0)
	{
		if (!first)
		{
			b.append_char(',');
		}
		b.appendf("\"think_tok\":%d", (int)u_think);
	}
	b.append_char('}');
	(void)file::save(actx.usage_file, b.str_view());
}

// usage 台账：每次成功调用追加一行 JSON
fn void ledger_append(AppContext* actx)
{
	if (actx.usage_file.len == 0)
	{
		return;
	}
	String content = load_file_or_empty(actx.usage_file).trim();
	if (content.len == 0)
	{
		return;
	}
	CJsonItem* rec = cjson::parse(content.zstr_tcopy());
	if (!rec || !cjson::is_object(rec) || cjson::get_array_size(rec) == 0)
	{
		if (rec)
		{
			cjson::delete(rec);
		}
		return;
	}

	String ledger = env_str("LLM_USAGE_LEDGER");
	if (ledger.len == 0)
	{
		String idir = env_str("IDENTITY_DIR");
		if (idir.len > 0)
		{
			ledger = string::tformat("%s/usage/llm.jsonl", idir);
		}
		else
		{
			ledger = string::tformat("%s/usage/llm.jsonl", state_home());
		}
	}
	usz cut = 0;
	for (usz i = 0; i < ledger.len; i++)
	{
		if (ledger[i] == '/' || ledger[i] == '\\')
		{
			cut = i;
		}
	}
	if (cut > 0)
	{
		mkdir_p(ledger[0:cut]);
	}

	// 直接用 cjson 构造台账 JSON（字符串转义交给序列化），不再手工拼串。
	CJsonItem* entry = cjson::new_object(tmem);
	entry.set("ts", now_iso_utc());
	entry.set("provider", actx.provider_label);
	entry.set("model", actx.model);
	for (CJsonItem* m = rec.child; m != null; m = m.next)
	{
		if (m.string != null && cjson::is_number(m))
		{
			entry.set(((ZString)m.string).str_view(), (int)m.valuedouble);
		}
	}
	String identity = env_str("IDENTITY_NAME");
	if (identity.len == 0)
	{
		String idir = env_str("IDENTITY_DIR");
		if (idir.len > 0)
		{
			identity = basename(idir);
		}
	}
	if (identity.len > 0)
	{
		entry.set("identity", identity);
	}
	String run_id = env_str("LLM_RUN_ID");
	if (run_id.len == 0)
	{
		run_id = env_str("SHELLM_RUN_STEP_ID");
	}
	if (run_id.len > 0)
	{
		entry.set("run_id", run_id);
	}
	cjson::delete(rec);

	String json_line = api::json_to_string(tmem, entry);
	cjson::delete(entry);

	File? fr = file::open(ledger, "a");
	if (catch fr)
	{
		return;
	}
	File f = fr;
	(void)io::fprintf(&f, "%s\n", json_line);
	(void)f.close();
}

fn void warn_truncated()
{
	// 上限由服务端（或其默认值）决定：本 CLI 不发 max_tokens，只能提示走 extra body。
	io::eprintfn(
		"llm: warning: output truncated (finish_reason=length) — the output cap "
			"was hit; raise it with LLM_EXTRA_BODY (e.g. '{\"max_tokens\":32768}')"
	);
}

// ===========================================================================
// 流式 chunk 回调（打字机打印属 CLI 职责；模块不感知输出通道）
// ===========================================================================

fn void chunk_cb(api::ChatStreamChunk* chunk, void* cb_ud)
{
	AppContext* actx = (AppContext*)cb_ud;
	if (chunk.delta_content.len > 0)
	{
		io::print(chunk.delta_content);
		File* so = io::stdout();
		(void)so.flush();
	}
	if (actx.debug && chunk.delta_reasoning.len > 0)
	{
		// debug：reasoning 走 stderr，stdout 仍只含最终答案
		io::eprint(chunk.delta_reasoning);
		File* se = io::stderr();
		(void)se.flush();
	}
	if (chunk.finish_reason == "length")
	{
		warn_truncated();
	}
}

// ===========================================================================
// 工具注册与派发
// ===========================================================================

// llm 可注册的工具白名单（ToolHub 支持的 minus Task：Task 依赖子 agent
// session 基础设施，llm 未提供，注册即坏）。
// ponytail: 与 ToolHub.init 的 switch 重复维护同一注册表，新增工具需两处同步；
// 升级路径 = ToolHub 暴露注册表查询（如 known_tools()）后由这里直接消费。
const String[] KNOWN_TOOLS = { "ReadFile", "Bash", "EditFile", "WriteFile", "Grep", "Glob", "ListDir", "HashEditFile" };

fn bool is_known_tool(String name)
{
	foreach (t : KNOWN_TOOLS)
	{
		if (t == name)
		{
			return true;
		}
	}
	return false;
}

// --tools 名单校验 + ToolHub 初始化。必须在 init 前校验：ToolHub.init 对未知
// 工具名直接 unreachable（abort），此处提前 die 出友好错误。hub 由调用方持有
// （main 局部），返回其指针供 AppContext 引用；tools 为空返回 null。
fn ToolHub* agent_setup_tools(ToolHub* hub, String tools_arg)
{
	if (tools_arg.len == 0)
	{
		return null;
	}
	List{String} allowed;
	allowed.init(tmem);
	usz start = 0;
	for (usz i = 0; i <= tools_arg.len; i++)
	{
		if (i == tools_arg.len || tools_arg[i] == ',')
		{
			String name = tools_arg[start:i - start].trim();
			if (name.len > 0)
			{
				if (name == "Task")
				{
					die("Task tool is not supported by llm (requires sub-agent session infrastructure)");
				}
				if (!is_known_tool(name))
				{
					die(string::tformat("Unknown tool: %s (try llm --help)", name));
				}
				allowed.push(name);
			}
			start = i + 1;
		}
	}
	if (allowed.len() == 0)
	{
		warn_msg("empty --tools list, running without tools");
		return null;
	}
	return hub.init(tmem, allowed.to_array(tmem));
}

fn ToolContext build_tool_context(AppContext* actx)
{
	ToolContext tc;
	tc.session_id = actx.session_id;
	tc.request_id = actx.request_id;
	Path? cd = path::new(tmem, actx.config_dir);
	if (try cdp = cd)
	{
		tc.config_dir = cdp;
	}
	else
	{
		die(string::tformat("invalid config_dir: %s", actx.config_dir));
	}
	tc.transcript_enabled = actx.transcript_enabled;
	tc.base_url = actx.url;
	tc.model = actx.model;
	tc.api_key = actx.api_key;
	return tc;
}

// 执行单个 tool_call 并把结果（或错误文本）作为 role:"tool" 消息追加进历史。
// 失败不 die：错误文本回传给模型自愈（agent loop 的意义所在）。
fn void execute_tool_call(AppContext* actx, ChatToolCall* tc, int turn)
{
	String result;

	CJsonItem* args = cjson::parse(tc.arguments.zstr_tcopy());
	if (!args)
	{
		result = string::tformat("Error: tool '%s' arguments are not valid JSON", tc.name);
	}
	else
	{
		defer args.free();
		ToolContext tctx = build_tool_context(actx);
		DString out = dstring::new(tmem);
		ToolResultMeta meta;
		if (catch dispatch_err = actx.hub.do_dispatch(&tctx, tmem, &out, tc.name, args, &meta))
		{
			result = string::tformat("Error: tool '%s' dispatch failed (fault %s)", tc.name, dispatch_err);
		}
		else
		{
			result = out.str_view();
			if (result.trim().len == 0)
			{
				result = "(no output)";
			}
		}
	}

	if (actx.debug)
	{
		io::eprintfn("[turn %d] tool %s(%s)", turn, tc.name, tc.arguments);
		io::eprintfn("[turn %d] tool result: %s", turn, result);
	}

	ChatMessage tm = api::new_message(tmem, "tool", result);
	tm.tool_call_id = tc.id;
	actx.messages.push(tm);
}

// ===========================================================================
// agent loop
// ===========================================================================

fn void run_trace(AppContext* actx)
{
	// api 模块入口只接收 LlmOption*：trace 期间接口设置不变，进循环前从
	// AppContext 现场组装一份（AppContext 自身不持有 api 类型）。
	api::LlmOption opt = api::default_options();
	if (actx.url.len > 0)
	{
		opt.url = actx.url;
	} // 空 = 模块默认端点
	opt.api_key = actx.api_key;
	opt.extra_body = actx.extra_body;
	opt.debug = actx.debug;
	opt.provider_label = actx.provider_label;

	int turn = 0;
	while (true)
	{
		turn++;
		api::ChatRequest req;
		req.model = actx.model;
		req.messages = actx.messages; // List 句柄共享（stream 不改写 messages）
		req.reasoning = actx.thinking;
		req.reasoning_effort = actx.thinking_level;
		req.reasoning_summary = "auto";
		if (actx.hub != null)
		{
			req.tools_json = actx.hub.schema(tmem);
		}

		api::LlmError err;
		api::ChatResponse? r = api::stream(tmem, &opt, &req, &err, &chunk_cb, actx);
		if (try resp = r)
		{
			write_usage(actx, resp.usage.prompt_tokens, resp.usage.completion_tokens, resp.usage.reasoning_tokens);
			ledger_append(actx);

			// 聚合 assistant 消息入历史（tool_calls 句柄从 choice 移交）
			api::ChatChoice* ch = resp.choices.get_ref(0);
			ChatMessage assistant = api::new_message(tmem, "assistant", ch.content);
			assistant.tool_calls = ch.tool_calls;
			if (resp.reasoning.len > 0)
			{
				assistant.reasoning = resp.reasoning;
			}
			actx.messages.push(assistant);

			// stop：无 tool_calls = trace 唯一正常出口（无 turn 上限，Ctrl+C 兜底）
			if (assistant.tool_calls.len() == 0)
			{
				return;
			}

			foreach (&tc : &assistant.tool_calls)
			{
				execute_tool_call(actx, tc, turn);
			}
		}
		else
		{
			die(err.message);
		}
	}
}

// ===========================================================================
// main
// ===========================================================================

fn usz opt_value(String[] args, usz i, String opt)
{
	if (i + 1 >= args.len)
	{
		die(string::tformat("%s requires a value", opt));
	}
	return i + 1;
}

fn void append_prompt(String* prompt, String part)
{
	if (prompt.len == 0)
	{
		*prompt = part;
	}
	else
	{
		*prompt = string::tformat("%s %s", *prompt, part);
	}
}

fn bool is_thinking_level(String s)
{
	return s == "low" || s == "high" || s == "max";
}

fn int main(String[] args)
{
	// 解析期 CLI 状态（main 局部，仅解析与装配阶段使用；运行期值在装配后经
	// LlmOption / AppContext 传递，无模块级全局）。
	String model = "";
	String system = "";
	String messages = "";
	String prompt = "";
	bool thinking = false;
	String thinking_level = "";
	bool debug = false;
	String tools = "";
	String usage_file = "";
	bool usage_file_own = false;

	// 1) 环境默认值
	model = env_str("LLM_MODEL");
	usage_file = env_str("LLM_USAGE_FILE");

	// 2) 参数解析
	usz i = 1;
	bool positional = false;
	while (i < args.len)
	{
		String a = args[i];
		if (positional)
		{
			append_prompt(&prompt, a);
			i++;
			continue;
		}
		if (a == "-h" || a == "--help")
		{
			io::printn(USAGE);
			return 0;
		}
		else if (a == "-m" || a == "--model")
		{
			i = opt_value(args, i, "--model");
			model = args[i];
		}
		else if (a == "-s" || a == "--system-prompt")
		{
			i = opt_value(args, i, "--system-prompt");
			system = args[i];
		}
		else if (a == "--system-prompt-file")
		{
			i = opt_value(args, i, "--system-prompt-file");
			system = load_file_arg(args[i], "System prompt file not found");
		}
		else if (a == "-M" || a == "--messages")
		{
			i = opt_value(args, i, "--messages");
			messages = args[i];
		}
		else if (a == "--messages-file")
		{
			i = opt_value(args, i, "--messages-file");
			messages = load_file_arg(args[i], "Messages file not found");
		}
		else if (a == "--thinking")
		{
			thinking = true;
			// 只吞下合法的 LEVEL，否则 --thinking "问题" 会把问题吃掉当强度。
			if (i + 1 < args.len && is_thinking_level(args[i + 1]))
			{
				thinking_level = args[i + 1];
				i++;
			}
		}
		else if (a == "--tools")
		{
			i = opt_value(args, i, "--tools");
			tools = args[i];
		}
		else if (a == "--debug")
		{
			debug = true;
		}
		else if (a.starts_with("-"))
		{
			die(string::tformat("Unknown option: %s (try llm --help)", a));
		}
		else
		{
			append_prompt(&prompt, a);
			positional = true;
		}
		i++;
	}

	// 3) 无 prompt 且无 messages 时读 stdin（TTY 交互模式不读）
	if (prompt.len == 0 && messages.len == 0 && !stdin_is_tty())
	{
		prompt = util::read_stdin_all();
	}
	if (prompt.len == 0 && messages.len == 0)
	{
		die("No prompt or messages provided");
	}

	// 4) 默认模型：SHELLM_MODEL → 有 key 时 gpt-5.5 → 报错
	if (model.len == 0)
	{
		String sm = env_str("SHELLM_MODEL");
		if (sm.len > 0)
		{
			model = sm;
		}
		else if (env_str("OPENAI_API_KEY").len > 0 || env_str("LLM_API_KEY").len > 0)
		{
			model = "gpt-5.5";
		}
		else
		{
			die("No model specified and no API key found. Set OPENAI_API_KEY (or LLM_API_KEY), or pass -m MODEL.");
		}
	}

	// 5) 私有 usage 临时文件兜底
	if (usage_file.len == 0)
	{
		usage_file = string::tformat("%s/llm-usage-%d.tmp", temp_dir(), current_pid());
		usage_file_own = true;
	}

	// 6) 工具注册（--tools 显式 opt-in；init 前校验名单，未知名 die）
	ToolHub hub;
	ToolHub* hub_ptr = agent_setup_tools(&hub, tools);

	// 7) libcurl 全局初始化（幂等）
	if (!api::init())
	{
		die("curl: global_init failed");
	}

	// 8) agent 级 AppContext（trace 数据中心）+ 初始消息 + run_trace 循环。
	//     接口设置来自 env（context_from_env）；debug 按本 CLI
	//     场景接线。AppContext 不持有 api 类型，run_trace 里现场组装 LlmOption。
	AppContext actx;
	context_from_env(&actx);
	actx.debug = debug;
	actx.model = model;
	actx.thinking = thinking;
	actx.thinking_level = thinking_level;
	actx.messages.init(tmem);
	actx.hub = hub_ptr;
	actx.usage_file = usage_file;
	actx.session_id = "";
	actx.request_id = "";
	actx.config_dir = ".";
	actx.transcript_enabled = true;
	push_initial_messages(&actx.messages, system, messages, prompt);

	run_trace(&actx);

	if (usage_file_own)
	{
		rm_file(usage_file);
	}
	api::shutdown();
	return 0;
}
