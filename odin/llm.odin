package main

import "core:fmt"

// ---- 分节 ----
// OpenAI chat completions 兼容调用。只做 OpenAI 兼容，不做 provider 抽象；
// 内部复用 chat.odin（build_request/parse_response/SSE 增量解析）与 http.odin。
//
// 默认非流式（一次 POST，整包 JSON）；stream=true（--stream）时请求体带 stream:true，
// 按 text/event-stream 增量收，逐 chunk 拼成完整回复——对外可观测结果与非流式一致。
//
// reasoning_content 硬约束：只入存档、绝不回传端点——request / archive 两条序列化路径
// 在 chat.odin 里已分开，本模块只走 request 路径。

// ---- 类型 ----

Llm :: struct {
	api_url:    string,
	api_key:    string,
	model:      string,
	stream:     bool, // --stream：用 SSE 增量接收响应
	max_tokens: int, // 0 = 不限制
}

// Response 语义与 ChatResponse 对齐，另加 ok/error 便于主循环判断。
LlmResponse :: struct {
	ok:            bool,
	error:         string,
	text:          string,
	reasoning:     string,
	usage:         string,
	finish_reason: string,
}

// ---- 调用 ----

// 只用于 stderr 展示（--debug / 错误摘要）的请求/响应预览长度。
DEBUG_PREVIEW :: 4000

// 一次 chat completion 往返：组装请求 → POST → 解析响应。
// stream=true 时走 SSE 增量路径，否则整包 JSON（默认）。
llm_call :: proc(llm: ^Llm, system_prompt: string, messages: []Message) -> LlmResponse {
	request_body := build_request_with_system(llm, system_prompt, messages)

	headers := []string{
		"Content-Type: application/json",
		fmt.aprintf("Authorization: Bearer %s", llm.api_key, allocator = context.temp_allocator),
	}

	log_debug("POST %s", llm.api_url)
	log_debug("headers: Content-Type: application/json, Authorization: Bearer %s", llm.api_key)
	log_debug("request: %s", truncate(request_body, DEBUG_PREVIEW))

	if llm.stream {
		return llm_call_stream(llm, headers, request_body)
	}
	return llm_call_buffered(llm, headers, request_body)
}

// 非流式：一次 POST，响应是整包 JSON。
llm_call_buffered :: proc(llm: ^Llm, headers: []string, request_body: string) -> LlmResponse {
	response: LlmResponse
	res := http_post_json(llm.api_url, headers, request_body)
	if res.error != "" {
		response.error = fmt.aprintf("网络错误：%s", res.error, allocator = context.temp_allocator)
		return response
	}
	log_debug("response(%d): %s", res.status, truncate(res.body, DEBUG_PREVIEW))

	if res.status < 200 || res.status >= 300 {
		response.error = fmt.aprintf("HTTP %d：%s", res.status, truncate(res.body, 2000),
		                             allocator = context.temp_allocator)
		return response
	}

	parsed := parse_response(res.body)
	if !parsed.ok {
		response.error = fmt.aprintf("%s；原始响应：%s", parsed.error, truncate(res.body, 2000),
		                             allocator = context.temp_allocator)
		return response
	}
	return llm_response_from(parsed)
}

// 流式：请求体已带 stream:true，按 SSE 逐分片增量解析，拼成完整回复。
llm_call_stream :: proc(llm: ^Llm, headers: []string, request_body: string) -> LlmResponse {
	response: LlmResponse
	acc: SseAccumulator
	sse_accumulator_init(&acc)

	res := http_post_json_stream(llm.api_url, headers, request_body, sse_on_chunk, &acc)
	if res.error != "" {
		response.error = fmt.aprintf("网络错误：%s", res.error, allocator = context.temp_allocator)
		return response
	}
	log_debug("response(%d, stream): %s", res.status, truncate(res.body, DEBUG_PREVIEW))

	if res.status < 200 || res.status >= 300 {
		response.error = fmt.aprintf("HTTP %d：%s", res.status, truncate(res.body, 2000),
		                             allocator = context.temp_allocator)
		return response
	}

	parsed := sse_accumulator_result(&acc)
	if !parsed.ok {
		// 端点无视 stream:true、仍按整包 JSON 回：兜底走非流式解析。
		parsed = parse_response(res.body)
	}
	if !parsed.ok {
		response.error = fmt.aprintf("%s；原始响应：%s", parsed.error, truncate(res.body, 2000),
		                             allocator = context.temp_allocator)
		return response
	}
	return llm_response_from(parsed)
}

// SSE 分片回调：把每个网络分片喂给增量解析器。
sse_on_chunk :: proc(chunk: string, user: rawptr) {
	sse_accumulator_feed((^SseAccumulator)(user), chunk)
}

// ChatResponse -> LlmResponse 的成功路径复制。
llm_response_from :: proc(parsed: ChatResponse) -> LlmResponse {
	return LlmResponse{
		ok = true,
		text = parsed.content,
		reasoning = parsed.reasoning,
		usage = parsed.usage,
		finish_reason = parsed.finish_reason,
	}
}

// 把 system 提示词拼在 messages 前面再组装请求体。
build_request_with_system :: proc(llm: ^Llm, system_prompt: string, messages: []Message) -> string {
	if system_prompt == "" {
		return build_request(llm.model, messages, llm.stream)
	}
	all := make([dynamic]Message, 0, len(messages) + 1, context.temp_allocator)
	append(&all, Message{role = "system", content = system_prompt})
	append(&all, ..messages)
	return build_request(llm.model, all[:], llm.stream)
}
