// llm — 极简 LLM CLI（C3 版，复刻 headlong/bin/llm）
// 仅支持 chat-completions 接口（OpenAI wire format：OpenAI / OpenRouter /
// openai-compatible 共用同一条 wire 路径）。HTTP 走项目内 libcurl 绑定；
// 请求体/响应体的结构体定义与 JSON 编解码集中在 src/model/model.c3（本文件只
// 负责组装结构体、按字段消费解析结果）。恒为流式请求，SSE 边收边打印（打字机效果）。
module llm_cli;

import std::io, std::io::file, std::io::path, std::os, std::os::env,
       std::collections::list, std::core::string, std::time::datetime,
       std::thread, libc, curl, cjson, model;

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
+++ "  LLM_RETRIES                   Transient-failure retries (default: 2; 0 disables).\n"
+++ "                                Never retries after partial streamed output.\n"
+++ "  LLM_RETRY_BACKOFF             Backoff base seconds between retries (default: 1)\n"
+++ "  LLM_CONNECT_TIMEOUT           Seconds to establish connection (default: 10; 0 off)\n"
+++ "  LLM_MAX_TIME                  Hard ceiling on one HTTP attempt (default: 600; 0 off)\n"
+++ "  LLM_SPEED_LIMIT               Abort a transfer slower than this many bytes/s...\n"
+++ "  LLM_SPEED_TIME                ...for this many consecutive seconds (100/60; 0 off)\n"
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

String g_model = "";
String g_system = "";
String g_messages = "";
String g_prompt = "";
String g_max_tokens = "";
int g_max_tokens_n = 0;
bool g_thinking = false;
String g_thinking_level = "";
int g_retries = 2;
int g_backoff = 1;
int g_connect_timeout = 10;
int g_max_time = 600;
int g_speed_limit = 100;
int g_speed_time = 60;
String g_usage_file = "";
bool g_usage_file_own = false;
String g_home = "";
String g_provider_label = "chat-completions";
int g_tmp_counter = 0;

// HTTP 传输状态（write callback 与主流程共享）
struct StreamState
{
	bool saw_data;
	bool emitted;
	long u_in;
	long u_out;
	long u_think;
	DString pending;
	DString err_buf;
}

StreamState g_ss;
char[256] g_errbuf @noinit;

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

fn String now_iso_utc()
{
	// copy 补尾部 NUL（cjson .set 需要 NUL 结尾的 String）
	DateTime dt = datetime::now();
	String s = string::tformat("%04d-%02d-%02dT%02d:%02d:%02dZ",
		(int)dt.year, (int)dt.month + 1, (int)dt.day,
		(int)dt.hour, (int)dt.min, (int)dt.sec);
	return s.copy(tmem);
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

fn String read_stdin_all()
{
	DString buf = dstring::new(tmem);
	char[4096] tmp @noinit;
	File* in = io::stdin();
	while (true) {
		sz? n = in.read(&tmp);
		if (catch n) { break; }
		if (n == 0) { break; }
		buf.append_bytes(tmp[:(usz)n]);
	}
	return buf.str_view();
}

// C 字符串 → C3 String（copy 补尾部 NUL，可安全交给 cjson .set 等 C 侧）
fn String zcopy(char* c)
{
	if (!c) { return ""; }
	usz n = libc::strlen((ZString)c);
	DString d = dstring::new(tmem);
	for (usz i = 0; i < n; i++) { d.append_char(c[i]); }
	return d.str_view().copy(tmem);
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
// payload 构建（OpenAI chat-completions）
// 请求结构体定义 / 消息解析 / JSON 序列化都在 src/model/model.c3（module model）。
// ===========================================================================

fn String tokens_field()
{
	if (g_model.starts_with("o1") || g_model.starts_with("o3") || g_model.starts_with("o4") || g_model.starts_with("gpt-5")) {
		return "max_completion_tokens";
	}
	return "max_tokens";
}

// 返回 tmem 视图，调用方立即使用
fn String build_payload()
{
	model::ChatRequest req;
	req.model = g_model;
	req.messages.init(tmem);
	// 全流式：请求恒为 stream:true（打字机效果），并请求 usage 随流返回
	req.stream = true;
	req.max_tokens_key = tokens_field();
	req.max_tokens = g_max_tokens_n;
	req.stream_include_usage = true;
	req.reasoning = g_thinking;
	req.reasoning_effort = g_thinking_level;
	req.reasoning_summary = "auto";

	// messages：-M/--messages-file 整段结构化解析（超出字段表达能力的消息原样
	// 透传）；否则单条 user prompt。system prompt 始终前置。
	if (g_system.len > 0) {
		req.messages.push(model::new_message(tmem, "system", g_system));
	}
	if (g_messages.len > 0) {
		int rc = model::parse_messages_json(&req.messages, tmem, g_messages);
		if (rc == -1) { die("Invalid JSON in --messages / --messages-file"); }
		if (rc != 0) {
			die("--messages must be a JSON array of {role, content} objects");
		}
	} else {
		req.messages.push(model::new_message(tmem, "user", g_prompt));
	}

	CJsonItem* payload = model::request_to_cjson(&req, tmem);

	// LLM_EXTRA_BODY：JSON object 合并进请求体，同名键覆盖默认值（如
	// llama-server 的 chat_template_kwargs）
	String extra = env_str("LLM_EXTRA_BODY");
	if (extra.len > 0) {
		CJsonItem* x = cjson::parse(extra.zstr_tcopy());
		if (!x || !cjson::is_object(x)) { die("LLM_EXTRA_BODY must be a JSON object"); }
		for (CJsonItem* m = x.child; m != null; ) {
			CJsonItem* next = m.next;
			CJsonItem* detached = cjson::detach_item_via_pointer(x, m);
			(void)cjson::add_item_to_object(payload, (ZString)m.string, detached);
			m = next;
		}
		cjson::delete(x);
	}

	String s = model::json_to_string(payload, tmem);
	cjson::delete(payload);
	return s;
}

fn String auth_header()
{
	String key = env_str("LLM_API_KEY");
	if (key.len == 0) { key = env_str("OPENAI_API_KEY"); }
	if (key.len == 0) { return ""; }
	return string::tformat("Authorization: Bearer %s", key);
}

// ===========================================================================
// HTTP 传输（libcurl）
// ===========================================================================

fn usz stream_write_cb(char* buffer, usz size, usz nitems, void* userdata)
{
	usz len = size * nitems;
	for (usz i = 0; i < len; i++) { g_ss.pending.append_char(buffer[i]); }
	pump_stream();
	return len;
}

// 单次流式 POST。成功返回 ""，失败返回错误描述；http_code 经指针带出。
fn String http_attempt(String url, String payload, int* http_code)
{
	curl::Curl* h = curl::easy_init();
	if (h == null) { die("curl: failed to init easy handle"); }
	defer curl::easy_cleanup(h);

	libc::memset(&g_errbuf, 0, (usz)g_errbuf.len);

	curl::easy_setopt(h, curl::CurlOption.NOPROGRESS, (CLong)1);
	curl::easy_setopt(h, curl::CurlOption.ERRORBUFFER, &g_errbuf);
	curl::easy_setopt(h, curl::CurlOption.URL, url.zstr_tcopy());
	curl::easy_setopt(h, curl::CurlOption.POSTFIELDS, payload.zstr_tcopy());
	curl::easy_setopt(h, curl::CurlOption.POSTFIELDSIZE, (CLong)payload.len);
	if (g_connect_timeout > 0) {
		curl::easy_setopt(h, curl::CurlOption.CONNECTTIMEOUT, (CLong)g_connect_timeout);
	}
	if (g_max_time > 0) {
		curl::easy_setopt(h, curl::CurlOption.TIMEOUT, (CLong)g_max_time);
	}
	if (g_speed_limit > 0 && g_speed_time > 0) {
		curl::easy_setopt(h, curl::CurlOption.LOW_SPEED_LIMIT, (CLong)g_speed_limit);
		curl::easy_setopt(h, curl::CurlOption.LOW_SPEED_TIME, (CLong)g_speed_time);
	}
	curl::CurlSlist* hdrs = null;
	hdrs = curl::slist_append(hdrs, (ZString)"Content-Type: application/json");
	String auth = auth_header();
	if (auth.len > 0) { hdrs = curl::slist_append(hdrs, auth.zstr_tcopy()); }
	curl::easy_setopt(h, curl::CurlOption.HTTPHEADER, hdrs);
	curl::easy_setopt(h, curl::CurlOption.WRITEFUNCTION, &stream_write_cb);
	curl::easy_setopt(h, curl::CurlOption.WRITEDATA, (void*)&g_ss);

	curl::CurlResult res = curl::easy_perform(h);
	CLong code = 0;
	curl::easy_getinfo(h, curl::CurlInfoType.RESPONSE_CODE, &code);
	*http_code = (int)code;
	curl::slist_free_all(hdrs);

	if (res != curl::CurlResult.OK) {
		String detail = zcopy(&g_errbuf[0]);
		if (detail.len == 0) { detail = zcopy(curl::easy_strerror(res)); }
		return string::tformat("curl error: %s", detail);
	}
	return "";
}

// ===========================================================================
// usage / ledger
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
			entry.set(zcopy(m.string), (int)m.valuedouble);
		}
	}
	String identity = env_str("IDENTITY_NAME");
	if (identity.len == 0) {
		String idir = env_str("IDENTITY_DIR");
		if (idir.len > 0) { identity = basename(idir).copy(tmem); }
	}
	if (identity.len > 0) { entry.set("identity", identity); }
	String run_id = env_str("LLM_RUN_ID");
	if (run_id.len == 0) { run_id = env_str("SHELLM_RUN_STEP_ID"); }
	if (run_id.len > 0) { entry.set("run_id", run_id); }
	cjson::delete(rec);

	String json_line = model::json_to_string(entry, tmem);
	cjson::delete(entry);

	File? fr = file::open(ledger, "a");
	if (catch fr) { return; }
	File f = fr;
	(void)io::fprintf(&f, "%s\n", json_line);
	(void)f.close();
}

fn void warn_truncated()
{
	io::eprintfn("llm: warning: output truncated at max_tokens=%s (reasoning tokens count against it) — raise with -t", g_max_tokens);
}

// ===========================================================================
// 流式路径
// ===========================================================================

fn void pump_stream()
{
	String view = g_ss.pending.str_view();
	usz consumed = 0;
	for (usz i = 0; i < view.len; i++) {
		if (view[i] == '\n') {
			// CRLF：行尾 \r 一并剥掉（SSE 各事件行按 \n 分割）
			handle_sse_line(view[consumed : i - consumed].trim_right("\r"));
			consumed = i + 1;
		}
	}
	if (consumed > 0) {
		// rest 是 pending 自身缓冲的视图：clear+append 会自我覆盖/悬垂，
		// 必须先拷进新 DString 再整体替换。
		DString np = dstring::new(tmem);
		np.append(view[consumed : view.len - consumed]);
		g_ss.pending = np;
	}
}

fn void handle_sse_line(String line)
{
	if (!line.starts_with("data: ")) {
		if (!g_ss.saw_data && line.len > 0) {
			g_ss.err_buf.append(line);
			g_ss.err_buf.append_char('\n');
		}
		return;
	}
	g_ss.saw_data = true;
	String json = line[6 : line.len - 6];
	if (json == "[DONE]") { return; }
	model::ChatStreamChunk? chunk_r = model::parse_stream_chunk(tmem, json);
	if (catch chunk_r) { return; }
	model::ChatStreamChunk chunk = chunk_r;
	if (chunk.delta_content.len > 0) {
		g_ss.emitted = true;
		io::print(chunk.delta_content);
		File* so = io::stdout();
		(void)so.flush();
	}
	if (chunk.finish_reason == "length") { warn_truncated(); }
	if (chunk.has_usage) {
		// 字段缺省为 -1：保持旧值（usage 可能跨帧下发，每帧只带部分计数）
		if (chunk.usage.prompt_tokens >= 0) { g_ss.u_in = chunk.usage.prompt_tokens; }
		if (chunk.usage.completion_tokens >= 0) { g_ss.u_out = chunk.usage.completion_tokens; }
		if (chunk.usage.reasoning_tokens >= 0) { g_ss.u_think = chunk.usage.reasoning_tokens; }
	}
}

fn void run_streaming(String url, String payload)
{
	int max_attempts = g_retries + 1;
	for (int attempt = 1; ; attempt++) {
		g_ss.saw_data = false;
		g_ss.emitted = false;
		g_ss.u_in = -1;
		g_ss.u_out = -1;
		g_ss.u_think = -1;
		g_ss.pending = dstring::new(tmem);
		g_ss.err_buf = dstring::new(tmem);

		int http_code = 0;
		String err = http_attempt(url, payload, &http_code);
		// 流结束：处理最后一段没有换行符的内容（read-until-EOF 语义）
		String tail = g_ss.pending.str_view();
		if (tail.len > 0) {
			handle_sse_line(tail.trim_right("\r"));
			g_ss.pending.clear();
		}

		if (err.len == 0 && g_ss.emitted) {
			write_usage(g_ss.u_in, g_ss.u_out, g_ss.u_think);
			ledger_append();
			return;
		}

		String retry_msg = "";
		if (err.len == 0 && !g_ss.emitted) {
			// 没有任何 data 事件时，缓冲行是 API 错误体（优先于 empty response）
			if (!g_ss.saw_data && g_ss.err_buf.len() > 0) {
				if (try err_r = model::parse_response(tmem, g_ss.err_buf.str_view())) {
					if (err_r.error_message.len > 0) {
						retry_msg = string::tformat("API error: %s", err_r.error_message);
					}
				}
			}
			if (retry_msg.len == 0) {
				retry_msg = "empty response: stream ended without emitting anything";
			}
		}
		if (err.len > 0 && retry_msg.len == 0) { retry_msg = err; }

		if (g_ss.emitted == false && attempt < max_attempts) {
			String cause = retry_msg;
			if (cause.len == 0) { cause = string::tformat("HTTP %d", http_code); }
			io::eprintfn("llm: transient API failure (attempt %d/%d): %s — retrying", attempt, max_attempts, cause);
			thread::sleep_ms((long)g_backoff * attempt * 1000);
			continue;
		}
		String shown = retry_msg.len > 0 ? retry_msg : string::tformat("HTTP %d", http_code);
		die(shown);
	}
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

	// 2) 环境默认值
	g_model = env_str("LLM_MODEL");
	g_max_tokens = env_str("LLM_MAX_TOKENS");
	g_usage_file = env_str("LLM_USAGE_FILE");
	String prov = env_str("LLM_PROVIDER");
	if (prov.len > 0) { g_provider_label = prov; }
	if (try v = env_str("LLM_RETRIES").to_int()) { g_retries = v; }
	if (try v = env_str("LLM_RETRY_BACKOFF").to_int()) { g_backoff = v; }
	if (try v = env_str("LLM_CONNECT_TIMEOUT").to_int()) { g_connect_timeout = v; }
	if (try v = env_str("LLM_MAX_TIME").to_int()) { g_max_time = v; }
	if (try v = env_str("LLM_SPEED_LIMIT").to_int()) { g_speed_limit = v; }
	if (try v = env_str("LLM_SPEED_TIME").to_int()) { g_speed_time = v; }

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
		g_prompt = read_stdin_all();
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

	// 7) endpoint
	String url = env_str("LLM_API_URL");
	if (url.len == 0) { url = "https://api.openai.com/v1/chat/completions"; }

	// 8) 私有 usage 临时文件兜底
	if (g_usage_file.len == 0) {
		g_usage_file = temp_path("llm-usage");
		g_usage_file_own = true;
	}

	// 9) libcurl 全局初始化
	if (curl::global_init(curl::CurlGlobal.DEFAULT) != curl::CurlResult.OK) {
		die("curl: global_init failed");
	}

	// 10) 构建并发送（全流式：SSE 打字机输出）
	String payload = build_payload();
	run_streaming(url, payload);

	if (g_usage_file_own) { rm_file(g_usage_file); }
	curl::global_cleanup();
	return 0;
}
