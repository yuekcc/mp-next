package main

import "core:fmt"

// ---- 分节 ----
// OpenAI chat completions 兼容调用。只做 OpenAI 兼容，不做 provider 抽象；
// 内部复用 chat.odin（build_request/parse_response）与 http.odin（http_post_json）。
//
// reasoning_content 硬约束：只入存档、绝不回传端点——request / archive 两条序列化路径
// 在 chat.odin 里已分开，本模块只走 request 路径。

// ---- 类型 ----

Llm :: struct {
	api_url:    string,
	api_key:    string,
	model:      string,
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
llm_call :: proc(llm: ^Llm, system_prompt: string, messages: []Message) -> LlmResponse {
	response: LlmResponse
	request_body := build_request_with_system(llm, system_prompt, messages)

	headers := []string{
		"Content-Type: application/json",
		fmt.aprintf("Authorization: Bearer %s", llm.api_key, allocator = context.temp_allocator),
	}

	log_debug("POST %s", llm.api_url)
	log_debug("headers: Content-Type: application/json, Authorization: Bearer %s", llm.api_key)
	log_debug("request: %s", truncate(request_body, DEBUG_PREVIEW))

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
	response.ok = true
	response.text = parsed.content
	response.reasoning = parsed.reasoning
	response.usage = parsed.usage
	response.finish_reason = parsed.finish_reason
	return response
}

// 把 system 提示词拼在 messages 前面再组装请求体。
build_request_with_system :: proc(llm: ^Llm, system_prompt: string, messages: []Message) -> string {
	if system_prompt == "" {
		return build_request(llm.model, messages)
	}
	all := make([dynamic]Message, 0, len(messages) + 1, context.temp_allocator)
	append(&all, Message{role = "system", content = system_prompt})
	append(&all, ..messages)
	return build_request(llm.model, all[:])
}
