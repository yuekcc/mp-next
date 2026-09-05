// test_llm — api 模块（src/api/，module api）的内部 seam 单测。
//
// 覆盖规格 docs/2026-09-05-llm-module-refactor.md Testing Decisions 里的
// 「内部 seam（后续立项）」：模型 JSON 往返 / 编解码（含 cJSON bool ABI 防护与
// json_override 保真）与 SSE 分帧/聚合（不进 HTTP，直接驱动 sse_handle_line）。
//
// 黑盒原则：只断言输入 → 输出的行为（字段/文案/错误类别），不断言模块内部状态。

import std::io;
import std::collections::list;
import api;
import cjson;

// ===========================================================================
// 小工具
// ===========================================================================

// 断言 parse_response 成功并取回响应（意外 MALFORMED_JSON 直接判失败）
fn api::ChatResponse resp_of(String json)
{
	api::ChatResponse? r = api::parse_response(tmem, json);
	if (catch r)
	{
		test::@check(false, "parse_response unexpectedly faulted");
		return {};
	}
	api::ChatResponse resp = r;
	return resp;
}

// 断言 parse_stream_chunk 成功并取回 chunk
fn api::ChatStreamChunk chunk_of(String json)
{
	api::ChatStreamChunk? r = api::parse_stream_chunk(tmem, json);
	if (catch r)
	{
		test::@check(false, "parse_stream_chunk unexpectedly faulted");
		return {};
	}
	api::ChatStreamChunk chunk = r;
	return chunk;
}

// 请求体序列化（stream 语义由调用方给定；仅构造+序列化，不发起 HTTP）
fn String req_json(api::ChatRequest* req, bool streaming)
{
	req.stream = streaming;
	req.stream_include_usage = streaming;
	CJsonItem* body = api::request_to_cjson(tmem, req);
	defer body.free();
	return api::json_to_string(tmem, body);
}

fn CJsonItem* parse_json(String s)
{
	CJsonItem* o = cjson::parse(s.zstr_tcopy());
	test::@check(o != null, "serialized JSON must parse: %s", s);
	return o;
}

// ===========================================================================
// 请求序列化：cJSON bool ABI 防护 / reasoning / tokens 字段名
// ===========================================================================

fn void test_llm_req_bool_stream_false() @test
{
	api::ChatRequest req;
	req.model = "m";
	req.messages.init(tmem);
	req.messages.push(api::new_message(tmem, "user", "hi"));
	req.max_tokens_key = "";
	req.max_tokens = 0;
	req.reasoning = false;

	CJsonItem* o = parse_json(req_json(&req, false));
	defer o.free();

	// ABI 防护回归：stream:false 不能经 bool 传参缺陷变成 true
	test::eq(false, o.get_key_bool("stream") ?? true);
	// stream 关闭时不应出现 stream_options
	test::eq(false, o.has_key("stream_options"));
	// reasoning 未开启时不应出现该键
	test::eq(false, o.has_key("reasoning"));
}

fn void test_llm_req_stream_and_reasoning() @test
{
	api::ChatRequest req;
	req.model = "m";
	req.messages.init(tmem);
	req.messages.push(api::new_message(tmem, "user", "hi"));
	req.max_tokens_key = "";
	req.reasoning = true;
	req.reasoning_effort = "high";
	req.reasoning_summary = "auto";

	CJsonItem* o = parse_json(req_json(&req, true));
	defer o.free();

	test::eq(true, o.get_key_bool("stream") ?? false);
	test::eq(true, o.has_key("stream_options"));
	CJsonItem* so = o.get_key("stream_options");
	test::@check(so != null, "stream_options present");
	test::eq(true, so.get_key_bool("include_usage") ?? false);

	CJsonItem* r = o.get_key("reasoning");
	test::@check(r != null, "reasoning present");
	test::eq("high", r.get_key_string("effort", tmem) ?? "");
	test::eq("auto", r.get_key_string("summary", tmem) ?? "");
}

fn void test_llm_req_tokens_key() @test
{
	api::ChatRequest req;
	req.model = "o3-mini";
	req.messages.init(tmem);
	req.messages.push(api::new_message(tmem, "user", "hi"));
	req.max_tokens_key = "max_completion_tokens";
	req.max_tokens = 321;

	CJsonItem* o = parse_json(req_json(&req, false));
	defer o.free();

	test::eq(true, o.has_key("max_completion_tokens"));
	test::eq(false, o.has_key("max_tokens"));
	test::eq(321, o.get_key_int("max_completion_tokens") ?? 0);
}

// ===========================================================================
// extra body 合并（make_payload：request 序列化 + 合并 + extra body 校验）
// ===========================================================================

fn void test_llm_req_extra_body_merge() @test
{
	api::LlmOption ctx;
	ctx.extra_body = "{\"temperature\":0.2,\"max_tokens\":99}";
	api::ChatRequest req;
	req.model = "m";
	req.messages.init(tmem);
	req.messages.push(api::new_message(tmem, "user", "hi"));
	req.max_tokens_key = "max_tokens";
	req.max_tokens = 123;

	api::LlmError err;
	String payload = "";
	bool ok = api::make_payload(tmem, &ctx, &req, &payload, &err);
	test::eq(true, ok);

	CJsonItem* o = parse_json(payload);
	defer o.free();
	int mt = o.get_key_int("max_tokens") ?? 0; // extra body 同名键覆盖默认值
	test::@check(99 == mt, "max_tokens override failed: got %d, payload=%s", mt, payload);
	test::eq(true, o.has_key("temperature"));
}

// temperature 是浮点：单独断言数值存在且非整型路径
fn void test_llm_req_extra_body_temperature_float() @test
{
	api::LlmOption ctx;
	ctx.extra_body = "{\"temperature\":0.2}";
	api::ChatRequest req;
	req.model = "m";
	req.messages.init(tmem);
	req.messages.push(api::new_message(tmem, "user", "hi"));

	api::LlmError err;
	String payload = "";
	bool ok = api::make_payload(tmem, &ctx, &req, &payload, &err);
	test::eq(true, ok);

	CJsonItem* o = parse_json(payload);
	defer o.free();
	CJsonItem* t = o.get_key("temperature");
	test::@check(t != null && t.is_number(), "temperature key present and numeric");
	test::eq(0.2, (double)t.valuedouble);
}

fn void test_llm_req_extra_body_invalid() @test
{
	api::LlmOption ctx;
	ctx.extra_body = "{oops";
	api::ChatRequest req;
	req.model = "m";
	req.messages.init(tmem);
	req.messages.push(api::new_message(tmem, "user", "hi"));

	api::LlmError err;
	String payload = "";
	bool ok = api::make_payload(tmem, &ctx, &req, &payload, &err);
	test::eq(false, ok);
	test::eq(0, err.http_code);
	test::eq("LLM_EXTRA_BODY must be a JSON object", err.message);
}

// ===========================================================================
// -M messages 解析与 json_override 保真透传
// ===========================================================================

fn void test_llm_messages_fidelity() @test
{
	String input = "["
		+++ "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\","
		+++ "\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},"
		+++ "{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"42\"},"
		+++ "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"multi\"}]},"
		+++ "{\"role\":\"user\",\"content\":\"plain\"},"
		+++ "{\"role\":\"user\",\"content\":\"x\",\"meta\":{\"a\":1}}]";

	List{api::ChatMessage} list;
	list.init(tmem);
	int rc = api::parse_messages_json(tmem, &list, input);
	test::eq(0, rc);
	test::eq((int)5, (int)list.len());

	// assistant(多模态结构) 与带未知扩展键的消息整体落入 json_override
	test::eq(true, list.get_ref(0).json_override.len > 0);
	test::eq(false, list.get_ref(1).json_override.len > 0); // tool 消息可无损表达
	test::eq(true, list.get_ref(2).json_override.len > 0);  // content 数组
	test::eq(false, list.get_ref(3).json_override.len > 0); // 标准 user
	test::eq(true, list.get_ref(4).json_override.len > 0);  // meta 扩展键

	// tool 消息按字段重排序列化（键序可变，语义等价）
	CJsonItem* m1 = api::message_to_json(tmem, list.get_ref(1));
	defer m1.free();
	test::eq("tool", m1.get_key_string("role", tmem) ?? "");
	test::eq("42", m1.get_key_string("content", tmem) ?? "");
	test::eq("c1", m1.get_key_string("tool_call_id", tmem) ?? "");
	int keys1 = 0;
	for (CJsonItem* it = m1.child; it != null; it = it.next) { keys1++; }
	test::eq(3, keys1);

	// assistant 原样透传：content:null + tool_calls 完整保留
	CJsonItem* m0 = api::message_to_json(tmem, list.get_ref(0));
	defer m0.free();
	CJsonItem* tcs = m0.get_key("tool_calls");
	test::@check(tcs != null, "tool_calls preserved");
	CJsonItem* tc0 = tcs.get_at(0);
	test::eq("c1", tc0.get_key_string("id", tmem) ?? "");
	test::eq("function", tc0.get_key_string("type", tmem) ?? "");
	test::eq("f", tc0.get_key("function").get_key_string("name", tmem) ?? "");
	test::eq(false, m0.get_key("content").is_string()); // content:null 原样

	// 未知扩展键原样保留
	CJsonItem* m4 = api::message_to_json(tmem, list.get_ref(4));
	defer m4.free();
	test::eq(true, m4.has_key("meta"));
}

// 非标准 tool_call 元素（缺 type/function/arguments 等）必须整体落 json_override
// 原样透传，不得被序列化层补造 type:"function"/function:{name:"",arguments:""} 等
// 原输入没有的字段（保真承诺回归：docs/llm.md「非标准 tool_call 结构 → 原样透传」）。
fn void test_llm_messages_toolcall_strict() @test
{
	String[] nonstandard = {
		"[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\"}]}]",
		"[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\"}]}]",
		"[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\","
			+++ "\"function\":{\"name\":\"f\"}}]}]"
	};
	// json_override 记的是单条消息对象；对应原样透传的期望值 = 数组输入剥掉外层 []。
	String[] expected = {
		"{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\"}]}",
		"{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\"}]}",
		"{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\","
			+++ "\"function\":{\"name\":\"f\"}}]}"
	};
	foreach (i, input : nonstandard)
	{
		List{api::ChatMessage} list;
		list.init(tmem);
		int rc = api::parse_messages_json(tmem, &list, input);
		test::eq(0, rc);
		test::eq(true, list.get_ref(0).json_override.len > 0);
		CJsonItem* m = api::message_to_json(tmem, list.get_ref(0));
		defer m.free();
		ZString out = cjson::print_unformatted(m);
		defer cjson::free((void*)out);
		String s = string::tformat("%s", out);
		// 原样透传：序列化结果 == 输入消息（字段、键顺序、缺失字段均保留，零补造）
		test::eq(expected[i], s);
	}

	// 完整标准 tool_call 仍走字段序列化（可无损表达路径不受影响）
	String standard = "[{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":"
		+++ "[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}]";
	List{api::ChatMessage} ok_list;
	ok_list.init(tmem);
	int rc2 = api::parse_messages_json(tmem, &ok_list, standard);
	test::eq(0, rc2);
	test::eq(false, ok_list.get_ref(0).json_override.len > 0);
	CJsonItem* m2 = api::message_to_json(tmem, ok_list.get_ref(0));
	defer m2.free();
	CJsonItem* tcs = m2.get_key("tool_calls");
	test::@check(tcs != null, "tool_calls serialized");
	test::eq("c1", tcs.get_at(0).get_key_string("id", tmem) ?? "");
	test::eq("f", tcs.get_at(0).get_key("function").get_key_string("name", tmem) ?? "");
}

// ===========================================================================
// 非流式响应解析（含 reasoning 顶层字段与错误折叠）
// ===========================================================================
fn void test_llm_response_parse_full() @test
{
	api::ChatResponse resp = resp_of(
		"{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hi\","
		+++ "\"reasoning\":\"thought\"},\"finish_reason\":\"stop\"}],"
		+++ "\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":5,"
		+++ "\"completion_tokens_details\":{\"reasoning_tokens\":2}}}");

	test::eq((int)1, (int)resp.choices.len());
	api::ChatChoice* c = resp.choices.get_ref(0);
	test::eq("hi", c.content);
	test::eq(true, c.has_content);
	test::eq("stop", c.finish_reason);
	test::eq("thought", resp.reasoning); // message.reasoning → 顶层
	test::eq(true, resp.has_usage);
	test::eq((int)11, (int)resp.usage.prompt_tokens);
	test::eq((int)5, (int)resp.usage.completion_tokens);
	test::eq((int)2, (int)resp.usage.reasoning_tokens);
}

fn void test_llm_response_reasoning_fallback() @test
{
	// DeepSeek 私有 reasoning_content 回退
	api::ChatResponse a = resp_of(
		"{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hi\","
		+++ "\"reasoning_content\":\"ds thought\"},\"finish_reason\":\"stop\"}]}");
	test::eq("ds thought", a.reasoning);

	// 无 reasoning / reasoning_content → 空
	api::ChatResponse b = resp_of(
		"{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},"
		+++ "\"finish_reason\":\"stop\"}]}");
	test::eq("", b.reasoning);
}

fn void test_llm_response_error_folding() @test
{
	// 顶层 {"error":{...}}.message
	api::ChatResponse a = resp_of("{\"error\":{\"message\":\"boom\"}}");
	test::eq("boom", a.error_message);
	test::eq("", a.reasoning);
	test::eq("boom", api::response_error_message(&a));

	// 兼容根键 {"message":...}
	api::ChatResponse b = resp_of("{\"message\":\"boom2\"}");
	test::eq("boom2", b.error_message);
	test::eq("boom2", api::response_error_message(&b));

	// choice 级 error.message（非标准扩展）
	api::ChatResponse c = resp_of(
		"{\"choices\":[{\"index\":0,\"message\":{\"content\":\"\"},"
		+++ "\"error\":{\"message\":\"choice err\"},\"finish_reason\":\"stop\"}]}");
	test::eq("", c.error_message);
	test::eq("choice err", api::response_error_message(&c));

	// finish_reason == "error"
	api::ChatResponse d = resp_of(
		"{\"choices\":[{\"index\":0,\"message\":{\"content\":\"\"},\"finish_reason\":\"error\"}]}");
	test::eq("finish_reason \"error\" (provider failed mid-generation)", api::response_error_message(&d));
}

fn void test_llm_response_malformed() @test
{
	test::@error(api::parse_response(tmem, "not json"));
	test::@error(api::parse_response(tmem, ""));
}

// ===========================================================================
// 流式单帧解析（delta content / reasoning 回退 / usage / malformed）
// ===========================================================================

fn void test_llm_chunk_parse_fields() @test
{
	api::ChatStreamChunk c = chunk_of(
		"{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\",\"reasoning\":\"t\"},"
		+++ "\"finish_reason\":\"length\"}],"
		+++ "\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,"
		+++ "\"completion_tokens_details\":{\"reasoning_tokens\":9}}}");

	test::eq("x", c.delta_content);
	test::eq("t", c.delta_reasoning);
	test::eq("length", c.finish_reason);
	test::eq(true, c.has_usage);
	test::eq((int)3, (int)c.usage.prompt_tokens);
	test::eq((int)1, (int)c.usage.completion_tokens);
	test::eq((int)9, (int)c.usage.reasoning_tokens);
}

fn void test_llm_chunk_reasoning_fallback() @test
{
	// DeepSeek 私有 delta.reasoning_content 回退
	api::ChatStreamChunk a = chunk_of(
		"{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"ds\"}}]}");
	test::eq("", a.delta_content);
	test::eq("ds", a.delta_reasoning);

	// 空对象帧：无 content / reasoning / usage / finish
	api::ChatStreamChunk b = chunk_of("{}");
	test::eq("", b.delta_content);
	test::eq("", b.delta_reasoning);
	test::eq("", b.finish_reason);
	test::eq(false, b.has_usage);
	test::eq((int)-1, (int)b.usage.prompt_tokens);

	// malformed JSON → MALFORMED_JSON fault
	test::@error(api::parse_stream_chunk(tmem, "not json"));
}

// ===========================================================================
// SSE 分帧 / 聚合（不进 HTTP：直接驱动模块的 line 处理器）
// ===========================================================================

struct CbCount
{
	int n;
}

fn void sse_agg_cb(api::ChatStreamChunk* chunk, void* cb_ud)
{
	(void)chunk;
	CbCount* c = (CbCount*)cb_ud;
	c.n++;
}

fn void test_llm_sse_aggregate() @test
{
	api::StreamRecv st;
	st.allocator = tmem;
	CbCount count = { .n = 0 };
	st.cb = &sse_agg_cb;
	st.cb_ud = &count;
	api::stream_reset(&st);

	// reasoning 帧（DeepSeek 扩展字段）→ 顶层 reasoning 累积
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"let me \"}}]}");
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}");
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"}}]}");
	// usage 跨帧合并：帧1带 prompt+completion，帧2只带 reasoning（缺省保持旧值）
	api::sse_handle_line(&st, "data: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2,"
		+++ "\"completion_tokens_details\":{\"reasoning_tokens\":0}}}");
	api::sse_handle_line(&st, "data: {\"usage\":{\"completion_tokens_details\":{\"reasoning_tokens\":7}}}");
	api::sse_handle_line(&st, "data: [DONE]");
	// 非 data 行（data 事件后）不进入错误缓冲、不影响聚合
	api::sse_handle_line(&st, ": keep-alive comment");

	api::ChatResponse resp = api::stream_result(&st);
	test::eq("Hello", resp.choices.get_ref(0).content);
	test::eq(true, resp.choices.get_ref(0).has_content);
	test::eq("let me ", resp.reasoning);
	test::eq("", resp.choices.get_ref(0).finish_reason);
	test::eq(true, resp.has_usage);
	test::eq((int)5, (int)resp.usage.prompt_tokens);
	test::eq((int)2, (int)resp.usage.completion_tokens);
	test::eq((int)7, (int)resp.usage.reasoning_tokens);
	// [DONE] 不算帧；5 个 data 帧各回调一次
	test::eq(5, count.n);
}

fn void test_llm_sse_finish_reason() @test
{
	api::StreamRecv st;
	st.allocator = tmem;
	st.cb = null;
	api::stream_reset(&st);

	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},"
		+++ "\"finish_reason\":\"stop\"}]}");
	// 终止帧 finish_reason 以最后一个非空为准（length 截断场景）
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}");
	api::sse_handle_line(&st, "data: [DONE]");

	api::ChatResponse resp = api::stream_result(&st);
	test::eq("partial", resp.choices.get_ref(0).content);
	test::eq("length", resp.choices.get_ref(0).finish_reason);
	test::eq(true, resp.choices.get_ref(0).has_content);
}

fn void test_llm_sse_error_buffer() @test
{
	// data 事件前的非 data 行 = 错误体缓冲，可折叠出 API error
	api::StreamRecv st;
	st.allocator = tmem;
	st.cb = null;
	api::stream_reset(&st);

	api::sse_handle_line(&st, "{\"error\":{\"message\":\"mock fail\"}}");
	api::sse_handle_line(&st, "");
	api::sse_handle_line(&st, "some html line");
	test::eq("API error: mock fail", api::stream_fold_error(&st));
	// 未输出任何内容 → 空响应
	api::ChatResponse resp = api::stream_result(&st);
	test::eq(false, resp.choices.get_ref(0).has_content);
	test::eq("", resp.reasoning);
	test::eq(false, resp.has_usage);

	// 见过 data 后，后续非 data 行不再收集（返回 ""）
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"}}]}");
	api::sse_handle_line(&st, "{\"error\":{\"message\":\"late fail\"}}");
	test::eq("", api::stream_fold_error(&st));
}

// CRLF / 无换行收尾由 pump_stream 承担（write 回调路径），此处验证 handle 前的
// 分帧行为：带 \r 的行剥除后再进入 line 处理不会破坏 data 前缀匹配。
fn void test_llm_sse_crlf_line() @test
{
	api::StreamRecv st;
	st.allocator = tmem;
	st.cb = null;
	api::stream_reset(&st);

	// 模拟 pump_stream 已剥除 \r 后交付的行
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}");
	api::ChatResponse resp = api::stream_result(&st);
	test::eq("ok", resp.choices.get_ref(0).content);
	test::eq(true, st.emitted);
}

// ===========================================================================
// tools_json / tool_calls（agent loop wire 扩展）
// ===========================================================================

fn void test_llm_req_tools_json() @test
{
	api::ChatRequest req;
	req.model = "m";
	req.messages.init(tmem);
	req.messages.push(api::new_message(tmem, "user", "hi"));
	req.max_tokens_key = "";

	// tools_json 非空 → 序列化为 "tools" 数组（ToolHub.schema() 同构）
	req.tools_json = "[{\"type\":\"function\",\"function\":{\"name\":\"ReadFile\",\"parameters\":{\"type\":\"object\"}}}]";
	CJsonItem* o = parse_json(req_json(&req, true));
	defer o.free();
	test::eq(true, o.has_key("tools"));
	CJsonItem* tools = o.get_key("tools");
	test::@check(tools != null && tools.is_array(), "tools must be an array");
	test::eq(1, (int)tools.get_len());
	CJsonItem* f0 = tools.get_at(0).get_key("function");
	test::@check(f0 != null, "function node present");
	test::eq("ReadFile", f0.get_key_string("name", tmem) ?? "");

	// tools_json 为空 → 不出现 tools 键（纯 chat 行为不变）
	api::ChatRequest bare;
	bare.model = "m";
	bare.messages.init(tmem);
	bare.messages.push(api::new_message(tmem, "user", "hi"));
	CJsonItem* o2 = parse_json(req_json(&bare, true));
	defer o2.free();
	test::eq(false, o2.has_key("tools"));

	// tools_json 非法 → 静默跳过（不产生 tools 键，也不炸序列化）
	api::ChatRequest bad;
	bad.model = "m";
	bad.messages.init(tmem);
	bad.messages.push(api::new_message(tmem, "user", "hi"));
	bad.tools_json = "not json";
	CJsonItem* o3 = parse_json(req_json(&bad, true));
	defer o3.free();
	test::eq(false, o3.has_key("tools"));
}

fn void test_llm_chunk_tool_delta() @test
{
	api::ChatStreamChunk c = chunk_of(
		"{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":["
		+++ "{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"ReadFile\",\"arguments\":\"{\\\"pa\"}},"
		+++ "{\"index\":1,\"id\":\"call_2\",\"function\":{\"name\":\"Grep\",\"arguments\":\"{}\"}}"
		+++ "]}}]}");

	test::eq(2, (int)c.tool_calls.len());
	test::eq((sz)0, c.tool_calls.get_ref(0).index);
	test::eq("call_1", c.tool_calls.get_ref(0).id);
	test::eq("ReadFile", c.tool_calls.get_ref(0).name);
	test::eq("{\"pa", c.tool_calls.get_ref(0).arguments);
	test::eq((sz)1, c.tool_calls.get_ref(1).index);
	test::eq("Grep", c.tool_calls.get_ref(1).name);

	// 无 tool_calls 的帧：列表为空
	api::ChatStreamChunk plain = chunk_of(
		"{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}");
	test::eq(0, (int)plain.tool_calls.len());
}

fn void test_llm_sse_tool_aggregate() @test
{
	api::StreamRecv st;
	st.allocator = tmem;
	st.cb = null;
	api::stream_reset(&st);

	// call_1：id/name 首帧全量，arguments 分两片；call_2 单帧完整。
	// 无任何 content —— 纯 tool_calls 流必须视为已输出（不被误判空流）。
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":["
		+++ "{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"ReadFile\",\"arguments\":\"{\\\"path\\\":\\\"a\"}}"
		+++ "]}}]}");
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":["
		+++ "{\"index\":0,\"function\":{\"arguments\":\".txt\\\"}\"}},"
		+++ "{\"index\":1,\"id\":\"call_2\",\"function\":{\"name\":\"Grep\",\"arguments\":\"{}\"}}"
		+++ "]}}]}");
	api::sse_handle_line(&st, "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}");
	api::sse_handle_line(&st, "data: [DONE]");

	test::eq(true, st.emitted);
	api::ChatResponse resp = api::stream_result(&st);
	test::eq("tool_calls", resp.choices.get_ref(0).finish_reason);
	test::eq("", resp.choices.get_ref(0).content);
	test::eq(2, (int)resp.choices.get_ref(0).tool_calls.len());

	api::ChatToolCall* t0 = resp.choices.get_ref(0).tool_calls.get_ref(0);
	test::eq("call_1", t0.id);
	test::eq("ReadFile", t0.name);
	test::eq("{\"path\":\"a.txt\"}", t0.arguments); // 分片按 index 拼接

	api::ChatToolCall* t1 = resp.choices.get_ref(0).tool_calls.get_ref(1);
	test::eq("call_2", t1.id);
	test::eq("Grep", t1.name);
	test::eq("{}", t1.arguments);
}
