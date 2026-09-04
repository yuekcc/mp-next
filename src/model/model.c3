// model — chat-completions wire 模型（请求体 / 响应体结构体 + JSON 编解码）。
//
// 对应 mini_pi/src/api/api.c3 一侧的概念模型：Message/ToolCall/Usage 等内部
// 类型负责把 /chat/completions 的 wire JSON 变成强类型数据；本模块把这个职责
// 抽到独立叶子模块（只依赖 std + cjson），供 cmd/llm.c3 这类轻量 CLI 使用。
//
// 结构体只描述本 CLI 用到的 OpenAI chat-completions 标准字段：
//   - ChatRequest/ChatMessage/ChatToolCall  —— 请求侧（含 reasoning、tool_calls）
//   - ChatResponse/ChatChoice/ChatStreamChunk/Usage —— 响应侧（非流式 + 流式帧）
//
// 保真策略：-M/--messages-file 传入的任意消息若超出 ChatMessage 字段能无损表达的
// 范围（多模态 content 数组、未知扩展键、非标准 tool_call 结构），解析时整体落入
// json_override，序列化时原样透传，绝不丢字段。
module model;

import std::core::string;
import std::collections::list;
import cjson;

faultdef MALFORMED_JSON;

// cJSON 绑定以 C3 bool 传参存在 ABI 缺陷：false 也会被生成为 True 节点（本机实测
// create_bool(false).type == cJSON_True）。统一经 int 转发，确保 true/false 语义正确。
extern fn CJsonItem* json_create_bool(int boolean) @cname("cJSON_CreateBool");

// ===========================================================================
// 类型
// ===========================================================================

// 一条对话消息（标准 ChatMessage 字段）。role 取值与 wire 一致。
struct ChatMessage
{
	String role;                  // "system" | "user" | "assistant" | "tool" | "developer"
	String content;               // 文本内容
	String name;                  // 可选 display name
	String tool_call_id;          // role == "tool"：回指 assistant 的 tool_call
	String reasoning;             // role == "assistant"：推理内容（标准字段 "reasoning"）
	List{ChatToolCall} tool_calls; // role == "assistant"：需要继续对话时回传模型产生的调用
	String json_override;         // 非空 => 该消息整体原样透传（绕过字段序列化）
}

// assistant 消息里的工具调用（序列化时包成标准 {id,type,function:{name,arguments}}）
struct ChatToolCall
{
	String id;
	String name;      // function.name
	String arguments; // function.arguments（JSON 对象字符串）
}

// /chat/completions 请求体（只覆盖 CLI 用到的字段子集）
struct ChatRequest
{
	String model;                 // 必填
	List{ChatMessage} messages;   // 必填，>=1
	bool stream;                  // 是否流式
	String max_tokens_key;        // "max_tokens" 或 "max_completion_tokens"（请求方按模型选择）
	long max_tokens;
	bool stream_include_usage;    // stream 时额外携带 stream_options.include_usage
	bool reasoning;               // 携带 reasoning 对象
	String reasoning_effort;      // 非空才写 effort
	String reasoning_summary;     // 非空才写 summary
}

// usage 计量（-1 表示缺省/非数字）
struct Usage
{
	long prompt_tokens;
	long completion_tokens;
	long reasoning_tokens; // usage.completion_tokens_details.reasoning_tokens
}

// 非流式响应里单个 choice（只保留 CLI 消费的字段）
struct ChatChoice
{
	String content;       // message.content（assistant 正文）
	bool has_content;     // message.content 键存在且为字符串（含空串）
	String finish_reason; // "" = 缺省
	String error_message; // choice 级 error.message（非标准扩展）
}

// 非流式响应体
struct ChatResponse
{
	List{ChatChoice} choices;
	Usage usage;
	bool has_usage;
	String error_message; // 顶层 {"error":{...}}.message；兼容 {"message":...} 根键
}

// 流式单帧（SSE "data:" 后的 JSON）
struct ChatStreamChunk
{
	String delta_content;    // choices[0].delta.content（字符串值，缺省为空）
	String delta_reasoning;  // choices[0].delta.reasoning（标准字段，字符串）；
	                         // DeepSeek 私有扩展 reasoning_content 作兼容回退
	String finish_reason;
	Usage usage;
	bool has_usage;          // 本帧带 usage（OpenAI 在终止帧/独立 chunk 下发）
}

// ===========================================================================
// 小工具
// ===========================================================================

// String（非 NUL 结尾视图）→ NUL 结尾 ZString（tmem 中转，供 cjson 立即消费）
fn ZString znul(String s)
{
	DString d = dstring::new(tmem);
	d.append(s);
	return d.zstr_view();
}

fn bool is_message_key(String k)
{
	return k == "role" || k == "content" || k == "name"
		|| k == "tool_call_id" || k == "reasoning" || k == "tool_calls";
}

fn bool is_tool_call_key(String k)
{
	return k == "id" || k == "type" || k == "function";
}

fn bool is_function_key(String k)
{
	return k == "name" || k == "arguments";
}

fn bool key_is_string_or_absent(CJsonItem* obj, String key)
{
	CJsonItem* v = obj.get_key(key);
	if (!v) return true;
	return v.is_string();
}

// 判断一条 JSON 消息对象是否能用 ChatMessage 字段无损表达。
// content/role 等若存在必须是字符串；键集合必须是标准集；tool_calls 元素必须是
// 标准 {id,type:"function",function:{name,arguments}} 结构。
fn bool message_representable(CJsonItem* obj)
{
	if (!key_is_string_or_absent(obj, "role")) return false;
	if (!key_is_string_or_absent(obj, "content")) return false;
	if (!key_is_string_or_absent(obj, "name")) return false;
	if (!key_is_string_or_absent(obj, "tool_call_id")) return false;
	if (!key_is_string_or_absent(obj, "reasoning")) return false;

	foreach (String k : obj.keys(tmem)) {
		if (!is_message_key(k)) return false;
	}

	CJsonItem* tcs = obj.get_key("tool_calls");
	if (!tcs) return true;
	if (!tcs.is_array()) return false;
	usz n = tcs.get_len();
	for (usz i = 0; i < n; i++) {
		CJsonItem* tc = tcs.get_at((sz)i);
		if (!tc || !tc.is_object()) return false;
		if (!key_is_string_or_absent(tc, "id")) return false;
		foreach (String k : tc.keys(tmem)) {
			if (!is_tool_call_key(k)) return false;
		}
		String ty = tc.get_key_string("type", tmem) ?? "";
		if (ty.len > 0 && ty != "function") return false;
		CJsonItem* fnobj = tc.get_key("function");
		if (fnobj) {
			if (!fnobj.is_object()) return false;
			foreach (String k : fnobj.keys(tmem)) {
				if (!is_function_key(k)) return false;
			}
			if (!key_is_string_or_absent(fnobj, "name")) return false;
			if (!key_is_string_or_absent(fnobj, "arguments")) return false;
		}
	}
	return true;
}

// ===========================================================================
// 请求侧：构造与序列化
// ===========================================================================

// 构造一条纯文本消息（其余扩展字段留空）
fn ChatMessage new_message(Allocator allocator, String role, String content)
{
	ChatMessage m;
	m.role = role;
	m.content = content;
	m.name = "";
	m.tool_call_id = "";
	m.reasoning = "";
	m.tool_calls.init(allocator);
	m.json_override = "";
	return m;
}

// 解析一条 JSON 消息对象到 ChatMessage。返回 false 表示不是合法消息对象；
// 超出字段表达能力的对象会整体记入 json_override（调用方无需感知，序列化时透传）。
fn bool parse_message(ChatMessage* out, Allocator allocator, CJsonItem* obj)
{
	if (!obj || !obj.is_object()) return false;

	ChatMessage m;
	m.role = "";
	m.content = "";
	m.name = "";
	m.tool_call_id = "";
	m.reasoning = "";
	m.tool_calls.init(allocator);
	m.json_override = "";

	if (!message_representable(obj)) {
		ZString raw = cjson::print_unformatted(obj);
		m.json_override = string::format(allocator, "%s", raw);
		cjson::free((void*)raw);
		*out = m;
		return true;
	}

	m.role = obj.get_key_string("role", allocator) ?? "";
	m.content = obj.get_key_string("content", allocator) ?? "";
	m.name = obj.get_key_string("name", allocator) ?? "";
	m.tool_call_id = obj.get_key_string("tool_call_id", allocator) ?? "";
	m.reasoning = obj.get_key_string("reasoning", allocator) ?? "";
	if (CJsonItem* tcs = obj.get_key("tool_calls")) {
		usz n = tcs.get_len();
		for (usz i = 0; i < n; i++) {
			CJsonItem* tc = tcs.get_at((sz)i);
			if (!tc || !tc.is_object()) continue;
			ChatToolCall c;
			c.id = tc.get_key_string("id", allocator) ?? "";
			c.name = "";
			c.arguments = "";
			if (CJsonItem* fnobj = tc.get_key("function")) {
				c.name = fnobj.get_key_string("name", allocator) ?? "";
				c.arguments = fnobj.get_key_string("arguments", allocator) ?? "";
			}
			m.tool_calls.push(c);
		}
	}
	*out = m;
	return true;
}

// 解析 -M/--messages-file 的整个 messages 数组 JSON 追加到 out。
// 返回 0 成功；-1 JSON 非法；-2 非数组；-3 存在非对象元素。
fn int parse_messages_json(List{ChatMessage}* out, Allocator allocator, String json)
{
	CJsonItem* root = cjson::parse(znul(json));
	if (!root) return -1;
	defer root.free();

	if (!root.is_array()) return -2;
	usz n = root.get_len();
	for (usz i = 0; i < n; i++) {
		CJsonItem* item = root.get_at((sz)i);
		ChatMessage m;
		if (!parse_message(&m, allocator, item)) return -3;
		out.push(m);
	}
	return 0;
}

// ChatMessage → JSON 对象（json_override 非空时整段原样透传）
fn CJsonItem* message_to_json(ChatMessage* m, Allocator allocator)
{
	if (m.json_override.len > 0) {
		return cjson::parse(znul(m.json_override));
	}
	CJsonItem* obj = cjson::new_object(allocator);
	obj.set("role", m.role);
	obj.set("content", m.content);
	if (m.name.len > 0) obj.set("name", m.name);
	if (m.tool_call_id.len > 0) obj.set("tool_call_id", m.tool_call_id);
	if (m.reasoning.len > 0) obj.set("reasoning", m.reasoning);
	if (m.tool_calls.len() > 0) {
		CJsonItem* arr = cjson::new_array(allocator);
		foreach (&tc : &m.tool_calls) {
			CJsonItem* t = cjson::new_object(allocator);
			t.set("id", tc.id);
			t.set("type", "function");
			CJsonItem* fnobj = cjson::new_object(allocator);
			fnobj.set("name", tc.name);
			fnobj.set("arguments", tc.arguments);
			t.set("function", fnobj);
			arr.push_back(t);
		}
		obj.set("tool_calls", arr);
	}
	return obj;
}

// ChatRequest → cJSON 对象树（调用方可再合并 LLM_EXTRA_BODY 等额外键后打印）
fn CJsonItem* request_to_cjson(ChatRequest* req, Allocator allocator)
{
	CJsonItem* body = cjson::new_object(allocator);
	body.set("model", req.model);

	CJsonItem* msgs = cjson::new_array(allocator);
	foreach (&m : &req.messages) {
		CJsonItem* item = message_to_json(m, allocator);
		if (item) msgs.push_back(item);
	}
	body.set("messages", msgs);

	// stream 字段经 json_create_bool(int) 写入（cJSON 绑定的 C3 bool 传参有 ABI
	// 缺陷：false 也会生成 True 节点，见文件头部说明）。
	body.set_item("stream", json_create_bool(req.stream ? 1 : 0));
	if (req.stream && req.stream_include_usage) {
		CJsonItem* so = cjson::new_object(allocator);
		so.set_item("include_usage", json_create_bool(1));
		body.set("stream_options", so);
	}
	if (req.max_tokens_key.len > 0) {
		body.set(req.max_tokens_key, req.max_tokens);
	}
	if (req.reasoning) {
		CJsonItem* r = cjson::new_object(allocator);
		if (req.reasoning_effort.len > 0) r.set("effort", req.reasoning_effort);
		if (req.reasoning_summary.len > 0) r.set("summary", req.reasoning_summary);
		body.set("reasoning", r);
	}
	return body;
}

// cJSON 对象树 → 紧凑 JSON 字符串（allocator 内；释放 print 缓冲）
fn String json_to_string(CJsonItem* item, Allocator allocator)
{
	ZString out = cjson::print_unformatted(item);
	String s = string::format(allocator, "%s", out);
	cjson::free((void*)out);
	return s;
}

// ===========================================================================
// 响应侧：解析
// ===========================================================================

// 非流式响应体 → ChatResponse。JSON 非法返回 MALFORMED_JSON。
fn ChatResponse? parse_response(Allocator allocator, String json)
{
	CJsonItem* root = cjson::parse(znul(json));
	if (!root) return MALFORMED_JSON~;
	defer root.free();

	ChatResponse resp;
	resp.choices.init(allocator);
	resp.usage.prompt_tokens = -1;
	resp.usage.completion_tokens = -1;
	resp.usage.reasoning_tokens = -1;
	resp.has_usage = false;
	resp.error_message = "";

	if (CJsonItem* err = root.get_key("error")) {
		resp.error_message = err.get_key_string("message", allocator) ?? "";
	}
	if (resp.error_message.len == 0) {
		resp.error_message = root.get_key_string("message", allocator) ?? "";
	}

	if (CJsonItem* u = root.get_key("usage")) {
		resp.has_usage = u.is_object();
		if (u.is_object()) {
			resp.usage.prompt_tokens = (long)(u.get_key_int("prompt_tokens") ?? -1);
			resp.usage.completion_tokens = (long)(u.get_key_int("completion_tokens") ?? -1);
			if (CJsonItem* det = u.get_key("completion_tokens_details")) {
				resp.usage.reasoning_tokens = (long)(det.get_key_int("reasoning_tokens") ?? -1);
			}
		}
	}

	if (CJsonItem* cs = root.get_key("choices")) {
		if (cs.is_array()) {
			usz n = cs.get_len();
			for (usz i = 0; i < n; i++) {
				CJsonItem* ch = cs.get_at((sz)i);
				if (!ch || !ch.is_object()) continue;
				ChatChoice choice;
				choice.content = "";
				choice.has_content = false;
				choice.finish_reason = "";
				choice.error_message = "";
				if (CJsonItem* msg = ch.get_key("message")) {
					if (msg.is_object()) {
						if (CJsonItem* cv = msg.get_key("content")) {
							if (cv.is_string()) {
								choice.content = cv.get_string(allocator);
								choice.has_content = true;
							}
						}
					}
				}
				choice.finish_reason = ch.get_key_string("finish_reason", allocator) ?? "";
				if (CJsonItem* ce = ch.get_key("error")) {
					choice.error_message = ce.get_key_string("message", allocator) ?? "";
				}
				resp.choices.push(choice);
			}
		}
	}
	return resp;
}

// 流式单帧 JSON → ChatStreamChunk。JSON 非法返回 MALFORMED_JSON。
fn ChatStreamChunk? parse_stream_chunk(Allocator allocator, String json)
{
	CJsonItem* root = cjson::parse(znul(json));
	if (!root) return MALFORMED_JSON~;
	defer root.free();

	ChatStreamChunk c;
	c.delta_content = "";
	c.delta_reasoning = "";
	c.finish_reason = "";
	c.usage.prompt_tokens = -1;
	c.usage.completion_tokens = -1;
	c.usage.reasoning_tokens = -1;
	c.has_usage = false;

	if (CJsonItem* u = root.get_key("usage")) {
		c.has_usage = u.is_object();
		if (u.is_object()) {
			c.usage.prompt_tokens = (long)(u.get_key_int("prompt_tokens") ?? -1);
			c.usage.completion_tokens = (long)(u.get_key_int("completion_tokens") ?? -1);
			if (CJsonItem* det = u.get_key("completion_tokens_details")) {
				c.usage.reasoning_tokens = (long)(det.get_key_int("reasoning_tokens") ?? -1);
			}
		}
	}

	if (CJsonItem* cs = root.get_key("choices")) {
		if (cs.is_array() && cs.get_len() > 0) {
			CJsonItem* ch = cs.get_at(0);
			if (ch && ch.is_object()) {
				c.finish_reason = ch.get_key_string("finish_reason", allocator) ?? "";
				if (CJsonItem* d = ch.get_key("delta")) {
					if (d.is_object()) {
						if (CJsonItem* cv = d.get_key("content")) {
							if (cv.is_string()) {
								c.delta_content = cv.get_string(allocator);
							}
						}
						// 标准字段 delta.reasoning（字符串）优先；DeepSeek 私有
						// 扩展 delta.reasoning_content 作兼容回退（与 mini_pi 一致）。
						c.delta_reasoning = d.get_key_string("reasoning", allocator) ?? "";
						if (c.delta_reasoning.len == 0) {
							c.delta_reasoning = d.get_key_string("reasoning_content", allocator) ?? "";
						}
					}
				}
			}
		}
	}
	return c;
}

// 把响应体里的错误信号折叠成一段可展示文本（顶层 error → choice 级 error →
// finish_reason=="error"），与 OpenRouter 式 200+error 兼容。无错误返回 ""。
fn String response_error_message(ChatResponse* resp)
{
	if (resp.error_message.len > 0) return resp.error_message;
	if (resp.choices.len() > 0) {
		ChatChoice* c = resp.choices.get_ref(0);
		if (c.error_message.len > 0) return c.error_message;
		if (c.finish_reason == "error") {
			return "finish_reason \"error\" (provider failed mid-generation)";
		}
	}
	return "";
}
