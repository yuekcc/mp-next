// llm — 极简 LLM CLI（C3 版，复刻 headlong/bin/llm）
// 仅支持 chat-completions 接口（OpenAI wire format：OpenAI / OpenRouter /
// openai-compatible 共用同一条 wire 路径）。HTTP 走项目内 libcurl 绑定，
// JSON 走 cjson；流式解析 SSE，非流式按 http_code 处理。
module llm_cli;

import std::io, std::io::file, std::io::path, std::os, std::os::env,
       std::collections::list, std::core::string, std::time::datetime,
       std::thread, libc, curl, cjson;

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
+++ "  -t, --max-tokens N       Max output tokens. Default: model-specific cap\n"
+++ "  -M, --messages JSON      Messages array JSON, e.g. [{\"role\":\"user\",\"content\":\"hi\"}]\n"
+++ "  --messages-file F        Read messages array JSON from file\n"
+++ "  --stream                 Enable streaming (default)\n"
+++ "  --no-stream              Disable streaming\n"
+++ "  --thinking [LEVEL]       Reasoning effort for o-series / gpt-5+ models\n"
+++ "                           (low/medium/high/xhigh; sent as reasoning.effort)\n"
+++ "  --raw                    Print raw non-streaming API response JSON\n"
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
+++ "  LLM_USAGE_FILE                One-line JSON usage record written after the call\n"
+++ "  LLM_ASSUME_THINKING=1         Send --thinking to unlisted models\n"
+++ "  LLM_EXTRA_BODY                JSON object merged into the request body\n"
+++ "                                (keys override defaults; e.g. llama-server:\n"
+++ "                                '{\"chat_template_kwargs\":{\"enable_thinking\":false}}')\n"
+++ "  LLM_PROVIDER                  Label only (health/ledger records); no behavior\n"
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

// ===========================================================================
// 全局配置（CLI 进程，一次赋值即可）
// ===========================================================================

String g_model = "";
String g_system = "";
String g_messages = "";
String g_prompt = "";
String g_max_tokens = "";
int g_max_tokens_n = 0;
bool g_stream = true;
bool g_raw = false;
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
DString g_resp;
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

fn bool pfx(String s, String p) => s.starts_with(p);

fn String str_trim(String s)
{
	usz start = 0;
	usz end = s.len;
	while (start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\r' || s[start] == '\n')) start++;
	while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\r' || s[end - 1] == '\n')) end--;
	return s[start : end - start];
}

fn String trim_cr(String s)
{
	if (s.len > 0 && s[s.len - 1] == '\r') { return s[0 : s.len - 1]; }
	return s;
}

fn bool parse_int(String s, int* out)
{
	String t = str_trim(s);
	if (t.len == 0) { return false; }
	int v = 0;
	usz i = 0;
	bool neg = false;
	if (t[0] == '-') { neg = true; i = 1; }
	if (i >= t.len) { return false; }
	for (; i < t.len; i++) {
		char c = t[i];
		if (c < '0' || c > '9') { return false; }
		v = v * 10 + (c - '0');
	}
	*out = neg ? -v : v;
	return true;
}

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

fn bool is_blank(String s)
{
	foreach (c : s) {
		if (c != ' ' && c != '\t' && c != '\r' && c != '\n') { return false; }
	}
	return true;
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

// C3 String → \0 结尾的 ZString（tmem 视图，立即传给 C 接口用）
fn ZString zof(String s)
{
	DString d = dstring::new(tmem);
	d.append(s);
	return d.zstr_view();
}

// C 字符串 → C3 String
fn String zcopy(char* c)
{
	if (!c) { return ""; }
	usz n = libc::strlen((ZString)c);
	DString d = dstring::new(tmem);
	for (usz i = 0; i < n; i++) { d.append_char(c[i]); }
	return d.str_view();
}

// ===========================================================================
// .env 分层加载（简化版：KEY=VALUE / export KEY=VALUE，值可带引号）
// 真实环境始终优先于文件。
// ===========================================================================

fn void parse_env_line(String raw)
{
	String line = str_trim(raw);
	if (line.starts_with("export ")) { line = str_trim(line[7 : line.len - 7]); }
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
	String value = str_trim(line[eq + 1 : line.len - eq - 1]);
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
// JSON 访问辅助（cjson 之上的一层点路径语法糖）
// ===========================================================================

// 点路径访问："choices.0.message.content"，数字段为数组下标
fn CJsonItem* jwalk(CJsonItem* root, String dotted)
{
	CJsonItem* cur = root;
	usz start = 0;
	for (usz i = 0; i <= dotted.len; i++) {
		if (i == dotted.len || dotted[i] == '.') {
			if (!cur) { return null; }
			String seg = dotted[start : i - start];
			if (seg.len == 0) { return null; }
			bool numeric = true;
			foreach (c : seg) {
				if (c < '0' || c > '9') { numeric = false; break; }
			}
			if (numeric) {
				int? n = seg.to_int();
				if (catch n) { return null; }
				cur = cjson::get_array_item(cur, n);
			} else {
				cur = cjson::get_object_item(cur, zof(seg));
			}
			start = i + 1;
		}
	}
	return cur;
}

fn String jtext(CJsonItem* root, String path)
{
	CJsonItem* v = jwalk(root, path);
	if (!v || !cjson::is_string(v)) { return ""; }
	return zcopy(v.valuestring);
}

fn bool jtext_eq(CJsonItem* root, String path, String expect)
{
	CJsonItem* v = jwalk(root, path);
	if (!v || !cjson::is_string(v)) { return false; }
	return zcopy(v.valuestring) == expect;
}

fn long jnum_child(CJsonItem* obj, String key, long def)
{
	CJsonItem* v = cjson::get_object_item(obj, zof(key));
	if (!v || !cjson::is_number(v)) { return def; }
	return (long)v.valuedouble;
}

// JSON 字符串转义（仅用于手工拼接的 usage/health 记录）
fn String jescape(String s)
{
	DString b = dstring::new(tmem);
	foreach (c : s) {
		switch (c) {
			case '"': b.append_string("\\\"");
			case '\\': b.append_string("\\\\");
			case '\n': b.append_string("\\n");
			case '\r': b.append_string("\\r");
			case '\t': b.append_string("\\t");
			default: {
				if ((uint)c < 0x20) {
					b.appendf("\\u%04x", (uint)c);
				} else {
					b.append_char(c);
				}
			}
		}
	}
	return b.str_view();
}

// ===========================================================================
// payload 构建（OpenAI chat-completions）
// ===========================================================================

fn bool supports_reasoning()
{
	if (env_str("LLM_ASSUME_THINKING") == "1") { return true; }
	if (pfx(g_model, "gpt-") && g_model.len >= 5 && g_model[4] >= '5' && g_model[4] <= '9') { return true; }
	if (pfx(g_model, "o") && g_model.len >= 2 && g_model[1] >= '1' && g_model[1] <= '9') { return true; }
	return false;
}

fn String tokens_field()
{
	if (pfx(g_model, "o1") || pfx(g_model, "o3") || pfx(g_model, "o4") || pfx(g_model, "gpt-5")) {
		return "max_completion_tokens";
	}
	return "max_tokens";
}

fn String default_max_tokens()
{
	if (pfx(g_model, "o1") || pfx(g_model, "o3") || pfx(g_model, "o4")) { return "100000"; }
	if (pfx(g_model, "gpt-5")) { return "128000"; }
	if (pfx(g_model, "gpt-4o")) { return "16384"; }
	if (pfx(g_model, "gpt-4-turbo")) { return "4096"; }
	if (pfx(g_model, "gpt-4")) { return "8192"; }
	if (pfx(g_model, "gpt-3.5")) { return "4096"; }
	// 未知模型走保守大值（openai-compatible 场景为主）
	return "16384";
}

// 返回 tmem 视图，调用方立即使用
fn String build_payload()
{
	CJsonItem* messages;
	if (g_messages.len > 0) {
		messages = cjson::parse(zof(g_messages));
		if (!messages) { die("Invalid JSON in --messages / --messages-file"); }
		if (!cjson::is_array(messages)) {
			die("--messages must be a JSON array of {role, content} objects");
		}
	} else {
		messages = cjson::create_array();
		CJsonItem* m = cjson::create_object();
		(void)cjson::add_item_to_object(m, "role", cjson::create_string(zof("user")));
		(void)cjson::add_item_to_object(m, "content", cjson::create_string(zof(g_prompt)));
		(void)cjson::add_item_to_array(messages, m);
	}
	if (g_system.len > 0) {
		CJsonItem* sys = cjson::create_object();
		(void)cjson::add_item_to_object(sys, "role", cjson::create_string(zof("system")));
		(void)cjson::add_item_to_object(sys, "content", cjson::create_string(zof(g_system)));
		(void)cjson::insert_item_in_array(messages, 0, sys);
	}
	CJsonItem* payload = cjson::create_object();
	(void)cjson::add_item_to_object(payload, "model", cjson::create_string(zof(g_model)));
	(void)cjson::add_item_to_object(payload, "messages", messages); // 所有权随之转移
	(void)cjson::add_item_to_object(payload, "stream", g_stream ? cjson::create_true() : cjson::create_false());
	(void)cjson::add_item_to_object(payload, zof(tokens_field()), cjson::create_number((double)g_max_tokens_n));
	if (g_stream) {
		CJsonItem* so = cjson::create_object();
		(void)cjson::add_item_to_object(so, "include_usage", cjson::create_true());
		(void)cjson::add_item_to_object(payload, "stream_options", so);
	}
	if (g_thinking && g_thinking_level.len > 0) {
		if (supports_reasoning()) {
			CJsonItem* r = cjson::create_object();
			(void)cjson::add_item_to_object(r, "effort", cjson::create_string(zof(g_thinking_level)));
			(void)cjson::add_item_to_object(r, "summary", cjson::create_string(zof("auto")));
			(void)cjson::add_item_to_object(payload, "reasoning", r);
		} else {
			io::eprintfn("llm: --thinking ignored: %s not in the known-reasoning model list (LLM_ASSUME_THINKING=1 to send anyway)", g_model);
		}
	}
	// LLM_EXTRA_BODY：JSON object 合并进请求体，同名键覆盖默认值（如
	// llama-server 的 chat_template_kwargs）
	String extra = env_str("LLM_EXTRA_BODY");
	if (extra.len > 0) {
		CJsonItem* x = cjson::parse(zof(extra));
		if (!x || !cjson::is_object(x)) { die("LLM_EXTRA_BODY must be a JSON object"); }
		for (CJsonItem* m = x.child; m != null; ) {
			CJsonItem* next = m.next;
			CJsonItem* detached = cjson::detach_item_via_pointer(x, m);
			(void)cjson::add_item_to_object(payload, (ZString)m.string, detached);
			m = next;
		}
		cjson::delete(x);
	}
	ZString out = cjson::print_unformatted(payload);
	String s = zcopy(out);
	cjson::free((void*)out);
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

fn usz collect_cb(char* buffer, usz size, usz nitems, void* userdata)
{
	usz len = size * nitems;
	for (usz i = 0; i < len; i++) { g_resp.append_char(buffer[i]); }
	return len;
}

// 单次 POST。成功返回 ""，失败返回错误描述；http_code 经指针带出。
fn String http_attempt(String url, String payload, bool stream, int* http_code)
{
	curl::Curl* h = curl::easy_init();
	if (h == null) { die("curl: failed to init easy handle"); }
	defer curl::easy_cleanup(h);

	libc::memset(&g_errbuf, 0, (usz)g_errbuf.len);

	curl::easy_setopt(h, curl::CurlOption.NOPROGRESS, (CLong)1);
	curl::easy_setopt(h, curl::CurlOption.ERRORBUFFER, &g_errbuf);
	curl::easy_setopt(h, curl::CurlOption.URL, zof(url));
	curl::easy_setopt(h, curl::CurlOption.POSTFIELDS, zof(payload));
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
	if (auth.len > 0) { hdrs = curl::slist_append(hdrs, zof(auth)); }
	curl::easy_setopt(h, curl::CurlOption.HTTPHEADER, hdrs);
	if (stream) {
		curl::easy_setopt(h, curl::CurlOption.WRITEFUNCTION, &stream_write_cb);
		curl::easy_setopt(h, curl::CurlOption.WRITEDATA, (void*)&g_ss);
	} else {
		curl::easy_setopt(h, curl::CurlOption.WRITEFUNCTION, &collect_cb);
		curl::easy_setopt(h, curl::CurlOption.WRITEDATA, (void*)&g_resp);
	}

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
// usage / health / ledger
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

fn String classify_error(String http_code, String message)
{
	if (http_code == "402") { return "credit"; }
	if (http_code == "401" || http_code == "403") { return "auth"; }
	if (http_code == "429") { return "rate"; }
	String m = message.to_lower_tcopy();
	if (m.contains("credit") || m.contains("billing") || m.contains("insufficient")
		|| m.contains("quota") || m.contains("balance") || m.contains("payment")
		|| m.contains("funds") || m.contains("budget")) { return "credit"; }
	if ((m.contains("invalid") && m.contains("key")) || m.contains("authentication")
		|| m.contains("unauthorized") || m.contains("api key") || m.contains("forbidden")
		|| m.contains("permission")) { return "auth"; }
	if ((m.contains("rate") && m.contains("limit")) || m.contains("too many requests")
		|| m.contains("overloaded")) { return "rate"; }
	return "other";
}

// Last-call health marker：每次调用后重写，供外部状态页读
fn void note_health(bool ok, String http_code, String message)
{
	if (g_home.len == 0) { return; }
	mkdir_p(string::tformat("%s/run", g_home));
	DString b = dstring::new(tmem);
	b.appendf("{\"ok\":%s,\"ts\":\"%s\",\"provider\":\"%s\",\"model\":\"%s\"",
		ok ? "true" : "false", now_iso_utc(), jescape(g_provider_label), jescape(g_model));
	if (!ok) {
		b.appendf(",\"kind\":\"%s\",\"http_code\":", classify_error(http_code, message));
		int code;
		if (parse_int(http_code, &code) && code > 0) {
			b.appendf("%d", code);
		} else {
			b.append_string("null");
		}
		b.appendf(",\"message\":\"%s\"", jescape(message));
	}
	b.append_char('}');
	(void)file::save(string::tformat("%s/run/llm_health.json", g_home), b.str_view());
}

// usage 台账：每次成功调用追加一行 JSON
fn void ledger_append()
{
	if (g_usage_file.len == 0) { return; }
	String content = str_trim(load_file_or_empty(g_usage_file));
	if (content.len == 0) { return; }
	CJsonItem* rec = cjson::parse(zof(content));
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

	DString b = dstring::new(tmem);
	b.appendf("{\"ts\":\"%s\",\"provider\":\"%s\",\"model\":\"%s\"",
		now_iso_utc(), jescape(g_provider_label), jescape(g_model));
	for (CJsonItem* m = rec.child; m != null; m = m.next) {
		if (m.string != null && cjson::is_number(m)) {
			b.appendf(",\"%s\":%d", jescape(zcopy(m.string)), (int)m.valuedouble);
		}
	}
	String identity = env_str("IDENTITY_NAME");
	if (identity.len == 0) {
		String idir = env_str("IDENTITY_DIR");
		if (idir.len > 0) { identity = basename(idir); }
	}
	if (identity.len > 0) { b.appendf(",\"identity\":\"%s\"", jescape(identity)); }
	String run_id = env_str("LLM_RUN_ID");
	if (run_id.len == 0) { run_id = env_str("SHELLM_RUN_STEP_ID"); }
	if (run_id.len > 0) { b.appendf(",\"run_id\":\"%s\"", jescape(run_id)); }
	b.append_char('}');
	cjson::delete(rec);

	File? fr = file::open(ledger, "a");
	if (catch fr) { return; }
	File f = fr;
	(void)io::fprintf(&f, "%s\n", b.str_view());
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
			handle_sse_line(trim_cr(view[consumed : i - consumed]));
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
	CJsonItem* root = cjson::parse(zof(json));
	if (!root) { return; }
	CJsonItem* content = jwalk(root, "choices.0.delta.content");
	if (content && cjson::is_string(content)) {
		String delta = zcopy(content.valuestring);
		if (delta.len > 0) {
			g_ss.emitted = true;
			io::print(delta);
			File* so = io::stdout();
			(void)so.flush();
		}
	}
	if (jtext_eq(root, "choices.0.finish_reason", "length")) { warn_truncated(); }
	CJsonItem* usage = cjson::get_object_item(root, "usage");
	if (usage && cjson::is_object(usage)) {
		g_ss.u_in = jnum_child(usage, "prompt_tokens", g_ss.u_in);
		g_ss.u_out = jnum_child(usage, "completion_tokens", g_ss.u_out);
		CJsonItem* det = cjson::get_object_item(usage, "completion_tokens_details");
		if (det) { g_ss.u_think = jnum_child(det, "reasoning_tokens", g_ss.u_think); }
	}
	cjson::delete(root);
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
		String err = http_attempt(url, payload, true, &http_code);
		// 流结束：处理最后一段没有换行符的内容（read-until-EOF 语义）
		String tail = g_ss.pending.str_view();
		if (tail.len > 0) {
			handle_sse_line(trim_cr(tail));
			g_ss.pending.clear();
		}

		if (err.len == 0 && g_ss.emitted) {
			note_health(true, "", "");
			write_usage(g_ss.u_in, g_ss.u_out, g_ss.u_think);
			ledger_append();
			return;
		}

		String retry_msg = "";
		if (err.len == 0 && !g_ss.emitted) {
			// 没有任何 data 事件时，缓冲行是 API 错误体（优先于 empty response）
			if (!g_ss.saw_data && g_ss.err_buf.len() > 0) {
				CJsonItem* err_root = cjson::parse(zof(g_ss.err_buf.str_view()));
				if (err_root) {
					String em = jtext(err_root, "error.message");
					if (em.len > 0) { retry_msg = string::tformat("API error: %s", em); }
					cjson::delete(err_root);
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
		note_health(false, string::tformat("%d", http_code), shown);
		die(shown);
	}
}

// ===========================================================================
// 非流式路径
// ===========================================================================

fn String check_embedded_error(String body)
{
	CJsonItem* root = cjson::parse(zof(body));
	if (!root) { return ""; }
	String em = jtext(root, "error.message");
	if (em.len == 0) { em = jtext(root, "choices.0.error.message"); }
	if (em.len == 0 && jtext_eq(root, "choices.0.finish_reason", "error")) {
		em = "finish_reason \"error\" (provider failed mid-generation)";
	}
	cjson::delete(root);
	return em;
}

fn void run_blocking(String url, String payload)
{
	int max_attempts = g_retries + 1;
	int http_code = 0;
	int attempt = 1;
	for (; ; attempt++) {
		g_resp = dstring::new(tmem);
		String err = http_attempt(url, payload, false, &http_code);

		bool transient = err.len > 0 || http_code == 408 || http_code == 429
			|| (http_code >= 500 && http_code <= 599);
		if (transient && attempt < max_attempts) {
			String cause = err.len > 0 ? err : string::tformat("HTTP %d", http_code);
			io::eprintfn("llm: transient API failure (attempt %d/%d): %s — retrying",
				attempt, max_attempts, cause);
			thread::sleep_ms((long)g_backoff * attempt * 1000);
			continue;
		}

		// 2xx 里也可能内嵌失败（OpenRouter 风格的 200 + error）
		if (err.len == 0 && http_code > 0 && http_code < 400) {
			String body = g_resp.str_view();
			String embedded_err = is_blank(body)
				? "whitespace-only response body"
				: check_embedded_error(body);
			if (embedded_err.len > 0) {
				if (attempt < max_attempts) {
					io::eprintfn("llm: transient API failure (attempt %d/%d): %s — retrying",
						attempt, max_attempts, embedded_err);
					thread::sleep_ms((long)g_backoff * attempt * 1000);
					continue;
				}
				note_health(false, string::tformat("%d", http_code), embedded_err);
				die(string::tformat("API error: %s", embedded_err));
			}
		}
		break;
	}

	if (http_code >= 400 || http_code == 0) {
		String body = g_resp.str_view();
		CJsonItem* root = cjson::parse(zof(body));
		String msg = "";
		if (root) {
			msg = jtext(root, "error.message");
			if (msg.len == 0) { msg = jtext(root, "message"); }
			cjson::delete(root);
		}
		String shown = msg.len > 0 ? msg : string::tformat("HTTP %d", http_code);
		note_health(false, string::tformat("%d", http_code), shown);
		if (msg.len > 0) { die(string::tformat("API error (HTTP %d): %s", http_code, msg)); }
		die(string::tformat("API error (HTTP %d)", http_code));
	}
	note_health(true, "", "");

	String body = g_resp.str_view();
	CJsonItem* root = cjson::parse(zof(body));

	long u_in = -1;
	long u_out = -1;
	long u_think = -1;
	if (root) {
		CJsonItem* usage = cjson::get_object_item(root, "usage");
		if (usage && cjson::is_object(usage)) {
			u_in = jnum_child(usage, "prompt_tokens", -1);
			u_out = jnum_child(usage, "completion_tokens", -1);
			CJsonItem* det = cjson::get_object_item(usage, "completion_tokens_details");
			if (det) { u_think = jnum_child(det, "reasoning_tokens", -1); }
		}
		if (jtext_eq(root, "choices.0.finish_reason", "length")) { warn_truncated(); }
	}
	write_usage(u_in, u_out, u_think);
	ledger_append();

	if (g_raw) {
		io::print(body);
	} else if (root) {
		CJsonItem* c = jwalk(root, "choices.0.message.content");
		if (c && cjson::is_string(c)) { io::printfn("%s", zcopy(c.valuestring)); }
	}
	if (root) { cjson::delete(root); }
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
	int v;
	if (parse_int(env_str("LLM_RETRIES"), &v)) { g_retries = v; }
	if (parse_int(env_str("LLM_RETRY_BACKOFF"), &v)) { g_backoff = v; }
	if (parse_int(env_str("LLM_CONNECT_TIMEOUT"), &v)) { g_connect_timeout = v; }
	if (parse_int(env_str("LLM_MAX_TIME"), &v)) { g_max_time = v; }
	if (parse_int(env_str("LLM_SPEED_LIMIT"), &v)) { g_speed_limit = v; }
	if (parse_int(env_str("LLM_SPEED_TIME"), &v)) { g_speed_time = v; }

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
		} else if (a == "--stream") {
			g_stream = true;
		} else if (a == "--no-stream") {
			g_stream = false;
		} else if (a == "--raw") {
			g_raw = true;
		} else if (a == "--thinking") {
			g_thinking = true;
			if (i + 1 < args.len && !args[i + 1].starts_with("-")) {
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

	// 6) max tokens 校验与默认表
	int mt;
	if (!parse_int(g_max_tokens, &mt)) {
		if (g_max_tokens.len > 0) {
			warn_msg(string::tformat("ignoring non-numeric LLM_MAX_TOKENS='%s'", g_max_tokens));
		}
		g_max_tokens = default_max_tokens();
		if (!parse_int(g_max_tokens, &mt)) { mt = 16384; }
	}
	g_max_tokens_n = mt;

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

	// 10) 构建并发送
	String payload = build_payload();
	if (g_stream) {
		run_streaming(url, payload);
	} else {
		run_blocking(url, payload);
	}

	if (g_usage_file_own) { rm_file(g_usage_file); }
	curl::global_cleanup();
	return 0;
}
