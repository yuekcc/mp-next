package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

// ---- S2：chat 请求/响应序列化（纯函数） ----

parse_object :: proc(body: string) -> (obj: json.Object, ok: bool) {
	v, err := json.parse_string(body, .JSON, allocator = context.temp_allocator)
	if err != nil {
		return {}, false
	}
	obj, ok = v.(json.Object)
	return
}

@(test)
build_request_carries_model_messages_and_stream_false :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msgs := []Message{{role = "user", content = "hi"}}
	obj, ok := parse_object(build_request("gpt-4o-mini", msgs))
	testing.expect(t, ok, "request must be a JSON object")
	if !ok {
		return
	}

	model, mok := obj["model"].(json.String)
	testing.expect(t, mok, "model must be a string")
	testing.expect_value(t, string(model), "gpt-4o-mini")

	stream, sok := obj["stream"].(json.Boolean)
	testing.expect(t, sok, "stream must be a boolean")
	testing.expect_value(t, bool(stream), false)

	arr, aok := obj["messages"].(json.Array)
	testing.expect(t, aok, "messages must be an array")
	if !aok {
		return
	}
	testing.expect_value(t, len(arr), 1)
	m, mok2 := arr[0].(json.Object)
	testing.expect(t, mok2, "message must be an object")
	role, rok := m["role"].(json.String)
	content, cok := m["content"].(json.String)
	testing.expect_value(t, string(role), "user")
	testing.expect_value(t, string(content), "hi")
	_ = rok
	_ = cok
}

@(test)
build_request_omits_reasoning_and_tools :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msgs := []Message{{role = "assistant", content = "answer", reasoning = "secret chain of thought"}}
	body := build_request("m", msgs)

	// 硬约束：reasoning_content 绝不回传端点；RLM 不使用 tools 协议。
	testing.expect(t, !strings.contains(body, "reasoning_content"),
	               "request must not carry reasoning_content")
	obj, ok := parse_object(body)
	testing.expect(t, ok, "request must be a JSON object")
	if !ok {
		return
	}
	_, has_tools := obj["tools"]
	testing.expect(t, !has_tools, "request must not carry tools")
	arr, aok := obj["messages"].(json.Array)
	testing.expect(t, aok)
	if !aok {
		return
	}
	m, mok := arr[0].(json.Object)
	testing.expect(t, mok)
	if !mok {
		return
	}
	_, has_reasoning := m["reasoning_content"]
	testing.expect(t, !has_reasoning, "message must not carry reasoning_content")
}

@(test)
build_request_keeps_non_ascii_unescaped :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := build_request("中文模型", []Message{{role = "user", content = "系统令·你好"}})
	testing.expect(t, strings.contains(body, "系统令·你好"), body)
	testing.expect(t, strings.contains(body, "中文模型"), body)
	testing.expect(t, !strings.contains(body, "\\u"), "non-ASCII must not be \\u-escaped: %s", body)
}

@(test)
parse_response_reads_content_reasoning_usage_finish :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"choices":[{"message":{"content":"hello","reasoning_content":"think"},` +
		`"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}`
	res := parse_response(body)
	testing.expect(t, res.ok, res.error)
	testing.expect_value(t, res.content, "hello")
	testing.expect_value(t, res.reasoning, "think")
	testing.expect_value(t, res.finish_reason, "stop")
	testing.expect_value(t, res.usage, "prompt=1 completion=2 total=3")
}

@(test)
build_request_stream_true_sets_flag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	obj, ok := parse_object(build_request("m", []Message{{role = "user", content = "hi"}}, true))
	testing.expect(t, ok, "request must be a JSON object")
	if !ok {
		return
	}
	stream, sok := obj["stream"].(json.Boolean)
	testing.expect(t, sok, "stream must be a boolean")
	testing.expect_value(t, bool(stream), true)
}

// ---- S2：流式（SSE）增量解析 ----

@(test)
sse_accumulator_assembles_split_chunks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	acc: SseAccumulator
	sse_accumulator_init(&acc)
	// 故意在事件 / JSON / 多字节边界附近切断，验证跨分片的行缓冲。
	parts := []string{
		"data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n",
		"data: {\"cho",
		"ices\":[{\"delta\":{\"content\":\"hel",
		"lo\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish",
		"_reason\":\"stop\"}]}\n\n",
		": keep-alive comment\n\n",
		"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}\n\n",
		"data: [DONE]\n\n",
	}
	for p in parts {
		sse_accumulator_feed(&acc, p)
	}
	res := sse_accumulator_result(&acc)
	testing.expect(t, res.ok, res.error)
	testing.expect_value(t, res.content, "hello world")
	testing.expect_value(t, res.finish_reason, "stop")
	testing.expect_value(t, res.usage, "prompt=1 completion=2 total=3")
	testing.expect(t, acc.done, "[DONE] must mark the stream complete")
}

@(test)
sse_accumulator_reads_reasoning_delta :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	acc: SseAccumulator
	sse_accumulator_init(&acc)
	sse_accumulator_feed(&acc, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think \"}}]}\n\n")
	sse_accumulator_feed(&acc, "data: {\"choices\":[{\"delta\":{\"reasoning\":\"more\"}}]}\n\n")
	sse_accumulator_feed(&acc, "data: [DONE]\n\n")
	res := sse_accumulator_result(&acc)
	testing.expect(t, res.ok, res.error)
	testing.expect_value(t, res.reasoning, "think more")
	testing.expect_value(t, res.content, "")
}

@(test)
sse_accumulator_handles_crlf_frames :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	acc: SseAccumulator
	sse_accumulator_init(&acc)
	sse_accumulator_feed(&acc, "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\r\n\r\n")
	sse_accumulator_feed(&acc, "data: [DONE]\r\n\r\n")
	res := sse_accumulator_result(&acc)
	testing.expect(t, res.ok, res.error)
	testing.expect_value(t, res.content, "a")
}

@(test)
sse_accumulator_rejects_non_sse_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	acc: SseAccumulator
	sse_accumulator_init(&acc)
	sse_accumulator_feed(&acc, "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}")
	res := sse_accumulator_result(&acc)
	testing.expect(t, !res.ok, "a plain JSON body is not an SSE stream")
}

@(test)
parse_response_rejects_non_json :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := parse_response("this is not json")
	testing.expect(t, !res.ok)
	testing.expect(t, len(res.error) > 0, "error must explain the failure")
}

@(test)
parse_response_rejects_missing_choices :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := parse_response(`{"id":"x"}`)
	testing.expect(t, !res.ok)
	testing.expect(t, len(res.error) > 0)
}
