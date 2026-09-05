// llmcmd — 极简 LLM CLI（C3 版，复刻 headlong/bin/llm）
// 仅支持 chat-completions 接口（OpenAI wire format：OpenAI / OpenRouter /
// openai-compatible 共用同一条 wire 路径）。HTTP 传输/SSE 分帧/重试/错误折叠已
// 抽到独立 llm 模块（src/llm/，见 LLM 模块化重构规格 2026-09-05）；本文件只保留
// CLI 交互层职责：.env 加载、参数解析、提示词组装、逐 chunk 打印（打字机）、
// usage/ledger、die/warn。恒为流式请求（打字机效果）。
//
// agent loop（2026-09-05 立项）在 cmd/agent.c3：agent 级 AppContext（trace 数据
// 中心）+ run_trace 循环 + ToolHub 工具派发（--tools 显式 opt-in）。本文件不再
// 直接发送请求，组装初始消息后交给 run_trace。
//
// 模块名 llm_cli → llmcmd（二进制/target 名仍为 llm，mem/脚本/文档示例零改动）。
module llmcmd;

import std::io, std::io::file, std::io::path, std::os, std::os::env,
       std::collections::list, std::core::string, std::time::datetime,
       libc, cjson, llm, tool, util;

// Windows 当前进程 PID / TTY 探测
extern fn uint win_current_pid() @cname("GetCurrentProcessId") @feat(WIN32);
extern fn int posix_getpid() @cname("getpid") @feat(!WIN32);
extern fn int win_isatty(int fd) @cname("_isatty") @feat(WIN32);

const String USAGE =
    "llm — minimal LLM CLI (C3 replica of headlong/bin/llm, chat-completions only)\n"
+++ "\n"
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
+++ "  -t, --max-tokens N       Max output tokens. Default: 16384\n"
+++ "  -M, --messages JSON      Messages array JSON, e.g. [{\"role\":\"user\",\"content\":\"hi\"}]\n"
+++ "  --messages-file F        Read messages array JSON from file\n"
+++ "  --thinking [LEVEL]       Enable reasoning (sent as reasoning.effort).\n"
+++ "                           LEVEL: low/medium/high/xhigh; omitted when not\n"
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
+++ "  LLM_MAX_TOKENS                Default output cap (same as -t)\n"
+++ "  LLM_EXTRA_BODY                JSON object merged into the request body\n"
+++ "                                (keys override defaults; e.g. llama-server:\n"
+++ "                                '{\"chat_template_kwargs\":{\"enable_thinking\":false}}')\n"
+++ "  LLM_PROVIDER                  Label only (ledger records); no behavior\n"
+++ "\n"
+++ ".env:\n"
+++ "  Loaded layered: ./.env first, then $HEADLONG_HOME|$SHELLM_HOME|~/.headlong/.env.\n"
+++ "  The real environment always wins; simple KEY=VALUE / export KEY=VALUE lines\n"
+++ "  (optionally quoted) are supported.\n"
+++ "\n"
+++ "Examples:\n"
+++ "  llm -m gpt-5.5 \"explain quicksort\"\n"
+++ "  echo \"summarize this\" | llm -m gpt-4o\n"
+++ "  LLM_API_URL=http://localhost:11434/v1/chat/completions \\\n"
+++ "    llm -m qwen3:8b \"explain quicksort\"\n";

// 未在命令行/环境里显式指定时的输出 token 上限。
const int DEFAULT_MAX_TOKENS = 16384;

// ===========================================================================
// 全局配置（CLI 进程，一次赋值即可）
// ===========================================================================
// 传输/策略配置见 LlmOption 构造（cli_context_from_env，env 属 CLI 交互层；
// llm 模块只定义数据结构，不感知配置来源）。

String g_model = "";
String g_system = "";
String g_messages = "";
String g_prompt = "";
String g_max_tokens = "";
int g_max_tokens_n = 0;
bool g_thinking = false;
bool g_debug = false;
String g_thinking_level = "";
String g_tools = "";
String g_usage_file = "";
bool g_usage_file_own = false;
String g_home = "";
String g_provider_label = "chat-completions";
int g_tmp_counter = 0;

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

fn bool env_has(String name)
{
	String? v = env::tget_var(name);
	if (catch v) { return false; }
	return true;
}

// 从环境变量构造 LlmOption（env 读取属 CLI 交互层；llm 模块只消费数据）。
// 必须在 .env 分层加载之后调用；返回后再按本 CLI 场景接 debug。
fn llm::LlmOption cli_context_from_env()
{
	llm::LlmOption c = llm::default_options();
	String url = env_str("LLM_API_URL");
	if (url.len > 0) { c.url = url; }
	c.api_key = env_str("LLM_API_KEY");
	if (c.api_key.len == 0) { c.api_key = env_str("OPENAI_API_KEY"); }
	c.extra_body = env_str("LLM_EXTRA_BODY");
	c.provider_label = env_str("LLM_PROVIDER");
	if (c.provider_label.len == 0) { c.provider_label = "chat-completions"; }
	return c;
}

fn String now_iso_utc()
{
	DateTime dt = datetime::now();
	return string::tformat("%04d-%02d-%02dT%02d:%02d:%02dZ",
		(int)dt.year, (int)dt.month + 1, (int)dt.day,
		(int)dt.hour, (int)dt.min, (int)dt.sec);
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
	if (t.len == 0) { t = env_str("TMPDIR"); }
	if (t.len > 0) { return t; }
	Path? td = path::temp_directory(tmem);
	if (catch td) { return "."; }
	return (String)td;
}

fn String temp_path(String prefix)
{
	g_tmp_counter++;
	return string::tformat("%s/%s-%d-%d.tmp", temp_dir(), prefix, current_pid(), g_tmp_counter);
}

fn void rm_file(String path)
{
	(void)file::delete(path);
}

fn String load_file_or_empty(String path)
{
	char[]? content_r = file::load(tmem, path);
	if (catch content_r) { return ""; }
	return (String)content_r;
}

fn bool path_exists(String p)
{
	Path? pp = path::new(tmem, p);
	if (catch pp) { return false; }
	return path::exists(pp);
}

fn String load_file_arg(String path, String err_label)
{
	String content = load_file_or_empty(path);
	if (content.len == 0 && !path_exists(path)) {
		die(string::tformat("%s: %s", err_label, path));
	}
	return content;
}

fn void mkdir_p(String dir)
{
	Path? d = path::new(tmem, dir);
	if (catch d) { return; }
	if (!path::is_dir(d)) { (void)path::mkdir(d, true); }
}

fn String basename(String p)
{
	usz i = p.len;
	while (i > 0 && p[i - 1] != '/' && p[i - 1] != '\\') i--;
	return p[i : p.len - i];
}

// ===========================================================================
// .env 分层加载（简化版：KEY=VALUE / export KEY=VALUE，值可带引号）
// 真实环境始终优先于文件。
// ===========================================================================

fn void parse_env_line(String raw)
{
	String line = raw.trim();
	if (line.starts_with("export ")) { line = line[7 : line.len - 7].trim(); }
	if (line.len == 0) { return; }
	char c0 = line[0];
	if (!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_')) { return; }
	sz? eq_r = line.index_of("=");
	if (catch eq_r) { return; }
	usz eq = (usz)eq_r;
	String name = line[0 : eq];
	foreach (c : name) {
		if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) { return; }
	}
	String value = line[eq + 1 : line.len - eq - 1].trim();
	if (value.len >= 2 && ((value[0] == '"' && value[value.len - 1] == '"')
		|| (value[0] == '\'' && value[value.len - 1] == '\''))) {
		value = value[1 : value.len - 2];
	}
	if (!env_has(name)) { (void)env::set_var(name, value, false); }
}

fn void load_env_file(String path)
{
	String content = load_file_or_empty(path);
	if (content.len == 0) { return; }
	usz start = 0;
	for (usz i = 0; i <= content.len; i++) {
		if (i == content.len || content[i] == '\n') {
			parse_env_line(content[start : i - start]);
			start = i + 1;
		}
	}
}

fn String state_home()
{
	String h = env_str("HEADLONG_HOME");
	if (h.len == 0) { h = env_str("SHELLM_HOME"); }
	if (h.len > 0) { return h; }
	Path? hd = path::home_directory(tmem);
	if (catch hd) { return ""; }
	return string::tformat("%s/.headlong", (String)hd);
}

// ===========================================================================
// ChatRequest 组装（wire 结构体 / 消息解析 / JSON 序列化都在 llm 模块内）
// ===========================================================================

fn String tokens_field()
{
	if (g_model.starts_with("o1") || g_model.starts_with("o3") || g_model.starts_with("o4") || g_model.starts_with("gpt-5")) {
		return "max_completion_tokens";
	}
	return "max_tokens";
}

// 组装 trace 的初始消息：system 前置；-M/--messages-file 整段结构化解析（超出
// 字段表达能力的消息原样透传）；否则单条 user prompt。追加进 agent 级
// AppContext.messages（分配在 tmem，main 生命周期内有效）。
fn void push_initial_messages(List{ChatMessage}* out)
{
	if (g_system.len > 0) {
		out.push(llm::new_message(tmem, "system", g_system));
	}
	if (g_messages.len > 0) {
		int rc = llm::parse_messages_json(tmem, out, g_messages);
		if (rc == -1) { die("Invalid JSON in --messages / --messages-file"); }
		if (rc != 0) {
			die("--messages must be a JSON array of {role, content} objects");
		}
	} else {
		out.push(llm::new_message(tmem, "user", g_prompt));
	}
}

// ===========================================================================
// usage / ledger（属 CLI 交互层，llm 模块不感知）
// ===========================================================================

fn void write_usage(long u_in, long u_out, long u_think)
{
	if (g_usage_file.len == 0) { return; }
	if (u_in < 0 && u_out < 0 && u_think < 0) { return; }
	DString b = dstring::new(tmem);
	b.append_char('{');
	bool first = true;
	if (u_in >= 0) {
		b.appendf("\"in_tok\":%d", (int)u_in);
		first = false;
	}
	if (u_out >= 0) {
		if (!first) { b.append_char(','); }
		b.appendf("\"out_tok\":%d", (int)u_out);
		first = false;
	}
	if (u_think >= 0) {
		if (!first) { b.append_char(','); }
		b.appendf("\"think_tok\":%d", (int)u_think);
	}
	b.append_char('}');
	(void)file::save(g_usage_file, b.str_view());
}

// usage 台账：每次成功调用追加一行 JSON
fn void ledger_append()
{
	if (g_usage_file.len == 0) { return; }
	String content = load_file_or_empty(g_usage_file).trim();
	if (content.len == 0) { return; }
	CJsonItem* rec = cjson::parse(content.zstr_tcopy());
	if (!rec || !cjson::is_object(rec) || cjson::get_array_size(rec) == 0) {
		if (rec) { cjson::delete(rec); }
		return;
	}

	String ledger = env_str("LLM_USAGE_LEDGER");
	if (ledger.len == 0) {
		String idir = env_str("IDENTITY_DIR");
		if (idir.len > 0) {
			ledger = string::tformat("%s/usage/llm.jsonl", idir);
		} else {
			ledger = string::tformat("%s/usage/llm.jsonl", g_home);
		}
	}
	usz cut = 0;
	for (usz i = 0; i < ledger.len; i++) {
		if (ledger[i] == '/' || ledger[i] == '\\') { cut = i; }
	}
	if (cut > 0) { mkdir_p(ledger[0 : cut]); }

	// 直接用 cjson 构造台账 JSON（字符串转义交给序列化），不再手工拼串。
	CJsonItem* entry = cjson::new_object(tmem);
	entry.set("ts", now_iso_utc());
	entry.set("provider", g_provider_label);
	entry.set("model", g_model);
	for (CJsonItem* m = rec.child; m != null; m = m.next) {
		if (m.string != null && cjson::is_number(m)) {
			entry.set(((ZString)m.string).str_view(), (int)m.valuedouble);
		}
	}
	String identity = env_str("IDENTITY_NAME");
	if (identity.len == 0) {
		String idir = env_str("IDENTITY_DIR");
		if (idir.len > 0) { identity = basename(idir); }
	}
	if (identity.len > 0) { entry.set("identity", identity); }
	String run_id = env_str("LLM_RUN_ID");
	if (run_id.len == 0) { run_id = env_str("SHELLM_RUN_STEP_ID"); }
	if (run_id.len > 0) { entry.set("run_id", run_id); }
	cjson::delete(rec);

	String json_line = llm::json_to_string(tmem, entry);
	cjson::delete(entry);

	File? fr = file::open(ledger, "a");
	if (catch fr) { return; }
	File f = fr;
	(void)io::fprintf(&f, "%s\n", json_line);
	(void)f.close();
}

fn void warn_truncated()
{
	// 用解析后的数值 g_max_tokens_n：未显式给 -t 时 g_max_tokens 是空串，
	// 会打印出 max_tokens= 这样的空值。
	io::eprintfn("llm: warning: output truncated at max_tokens=%d (reasoning tokens count against it) — raise with -t", g_max_tokens_n);
}

// ===========================================================================
// 流式 chunk 回调（打字机打印属 CLI 职责；模块不感知输出通道）
// ===========================================================================

fn void chunk_cb(llm::ChatStreamChunk* chunk, void* ud)
{
	(void)ud;
	if (chunk.delta_content.len > 0) {
		io::print(chunk.delta_content);
		File* so = io::stdout();
		(void)so.flush();
	}
	if (g_debug && chunk.delta_reasoning.len > 0) {
		// debug：reasoning 走 stderr，stdout 仍只含最终答案
		io::eprint(chunk.delta_reasoning);
		File* se = io::stderr();
		(void)se.flush();
	}
	if (chunk.finish_reason == "length") { warn_truncated(); }
}

// ===========================================================================
// main
// ===========================================================================

fn usz opt_value(String[] args, usz i, String opt)
{
	if (i + 1 >= args.len) { die(string::tformat("%s requires a value", opt)); }
	return i + 1;
}

fn void append_prompt(String part)
{
	if (g_prompt.len == 0) {
		g_prompt = part;
	} else {
		g_prompt = string::tformat("%s %s", g_prompt, part);
	}
}

fn bool is_thinking_level(String s)
{
	return s == "low" || s == "medium" || s == "high" || s == "xhigh";
}

fn int main(String[] args)
{
	// 1) .env 分层加载：cwd 先行，状态目录补缺；真实环境始终优先。
	load_env_file(".env");
	g_home = state_home();
	if (g_home.len > 0) { load_env_file(string::tformat("%s/.env", g_home)); }

	// 2) 环境默认值（仅 CLI 层字段；LlmOption 由 cli_context_from_env 构造，
	//    env 读取属 CLI 交互层）
	g_model = env_str("LLM_MODEL");
	g_max_tokens = env_str("LLM_MAX_TOKENS");
	g_usage_file = env_str("LLM_USAGE_FILE");

	// 3) 参数解析
	usz i = 1;
	bool positional = false;
	while (i < args.len) {
		String a = args[i];
		if (positional) {
			append_prompt(a);
			i++;
			continue;
		}
		if (a == "-h" || a == "--help") {
			io::printn(USAGE);
			return 0;
		} else if (a == "-m" || a == "--model") {
			i = opt_value(args, i, "--model");
			g_model = args[i];
		} else if (a == "-s" || a == "--system-prompt") {
			i = opt_value(args, i, "--system-prompt");
			g_system = args[i];
		} else if (a == "--system-prompt-file") {
			i = opt_value(args, i, "--system-prompt-file");
			g_system = load_file_arg(args[i], "System prompt file not found");
		} else if (a == "-t" || a == "--max-tokens") {
			i = opt_value(args, i, "--max-tokens");
			g_max_tokens = args[i];
		} else if (a == "-M" || a == "--messages") {
			i = opt_value(args, i, "--messages");
			g_messages = args[i];
		} else if (a == "--messages-file") {
			i = opt_value(args, i, "--messages-file");
			g_messages = load_file_arg(args[i], "Messages file not found");
		} else if (a == "--thinking") {
			g_thinking = true;
			// 只吞下合法的 LEVEL，否则 --thinking "问题" 会把问题吃掉当强度。
			if (i + 1 < args.len && is_thinking_level(args[i + 1])) {
				g_thinking_level = args[i + 1];
				i++;
			}
		} else if (a == "--tools") {
			i = opt_value(args, i, "--tools");
			g_tools = args[i];
		} else if (a == "--debug") {
			g_debug = true;
		} else if (a.starts_with("-")) {
			die(string::tformat("Unknown option: %s (try llm --help)", a));
		} else {
			append_prompt(a);
			positional = true;
		}
		i++;
	}

	// 4) 无 prompt 且无 messages 时读 stdin（TTY 交互模式不读）
	if (g_prompt.len == 0 && g_messages.len == 0 && !stdin_is_tty()) {
		g_prompt = util::read_stdin_all();
	}
	if (g_prompt.len == 0 && g_messages.len == 0) { die("No prompt or messages provided"); }

	// 5) 默认模型：SHELLM_MODEL → 有 key 时 gpt-5.5 → 报错
	if (g_model.len == 0) {
		String sm = env_str("SHELLM_MODEL");
		if (sm.len > 0) {
			g_model = sm;
		} else if (env_str("OPENAI_API_KEY").len > 0 || env_str("LLM_API_KEY").len > 0) {
			g_model = "gpt-5.5";
		} else {
			die("No model specified and no API key found. Set OPENAI_API_KEY (or LLM_API_KEY), or pass -m MODEL.");
		}
	}

	// 6) max tokens：仅接受显式数值，非数字/未提供一律用固定默认值
	if (try mt = g_max_tokens.to_int()) {
		g_max_tokens_n = mt;
	} else {
		if (g_max_tokens.len > 0) {
			warn_msg(string::tformat("ignoring non-numeric max-tokens='%s', using %d", g_max_tokens, DEFAULT_MAX_TOKENS));
		}
		g_max_tokens_n = DEFAULT_MAX_TOKENS;
	}

	// 7) LlmOption（url/api key/extra body/provider 来自 env，CLI 交互层）；
	//    debug 按本 CLI 场景接线。provider 标签供 ledger 使用。
	llm::LlmOption opt = cli_context_from_env();
	opt.debug = g_debug;
	g_provider_label = opt.provider_label;

	// 8) 私有 usage 临时文件兜底
	if (g_usage_file.len == 0) {
		g_usage_file = temp_path("llm-usage");
		g_usage_file_own = true;
	}

	// 9) 工具注册（--tools 显式 opt-in；init 前校验名单，未知名 die）
	agent_setup_tools(g_tools);

	// 10) libcurl 全局初始化（幂等）
	if (!llm::init()) {
		die("curl: global_init failed");
	}

	// 11) agent 级 AppContext（trace 数据中心）+ 初始消息 + run_trace 循环
	AppContext actx;
	actx.opt = opt;
	actx.model = g_model;
	actx.max_tokens = g_max_tokens_n;
	actx.thinking = g_thinking;
	actx.thinking_level = g_thinking_level;
	actx.system = g_system;
	actx.messages.init(tmem);
	actx.session_id = "";
	actx.request_id = "";
	actx.config_dir = ".";
	actx.transcript_enabled = true;
	push_initial_messages(&actx.messages);
	actx.hub = g_hub_ptr;

	run_trace(&actx);

	if (g_usage_file_own) { rm_file(g_usage_file); }
	llm::shutdown();
	return 0;
}
