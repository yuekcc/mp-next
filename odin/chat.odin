package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// ---- 分节 ----
// 一次会话里的消息与 OpenAI chat completions 的请求/响应序列化。
//
// 两条序列化路径必须分开（安全与协议正确）：
//   - 回传端点：**不带** reasoning_content（DeepSeek 等收到会报错）；
//   - 会话存档：**带** reasoning_content。
// 请求体**不含** tools：RLM 不用 tools 协议，bash 是唯一工具。
//
// 归属：请求体/解析结果的字符串都在 context.temp_allocator 上，属本轮 scratch。

// ---- 类型 ----

// 会话里的一条消息。RLM 循环实际只产生 system / user / assistant 三类角色。
Message :: struct {
	role:      string, // system / user / assistant
	content:   string,
	reasoning: string, // reasoning_content 原文；空串表示没有
}

// 一次 chat completions 响应的解析结果。
ChatResponse :: struct {
	ok:            bool,
	error:         string,
	content:       string,
	reasoning:     string,
	finish_reason: string,
	usage:         string,
}

// ---- 请求组装 ----

// 组装一次 chat completions 请求体（结果在 context.temp_allocator 上）。
// 回传端点时不带 reasoning_content；不带 tools；stream 默认 false（--stream 时为 true）。
build_request :: proc(model: string, messages: []Message, stream: bool = false) -> string {
	root := make(json.Object, allocator = context.temp_allocator)
	root["model"] = model
	root["stream"] = json.Boolean(stream)

	arr := make(json.Array, 0, len(messages), context.temp_allocator)
	for m in messages {
		obj := make(json.Object, allocator = context.temp_allocator)
		obj["role"] = m.role
		obj["content"] = m.content
		// reasoning_content 只入会话存档，绝不回传端点。
		append(&arr, json.Value(obj))
	}
	root["messages"] = json.Value(arr)

	// 用自写的 json_encode：非 ASCII（中文）原样输出 UTF-8，不写成 \uXXXX。
	return json_encode(root)
}

// ---- 响应解析 ----

// 解析 choices[0].message.{content, reasoning_content} 与 choices[0].finish_reason，
// 并把 usage 的 token 数拼成展示串；任一必需结构缺失即 ok=false 并给出原因。
parse_response :: proc(body: string) -> ChatResponse {
	res: ChatResponse

	v, err := json.parse_string(body, .JSON, allocator = context.temp_allocator)
	if err != nil {
		res.error = fmt.aprintf("响应不是合法 JSON：%v", err, allocator = context.temp_allocator)
		return res
	}
	root, is_obj := v.(json.Object)
	if !is_obj {
		res.error = "响应顶层不是 JSON 对象"
		return res
	}

	choices, has_choices := root["choices"].(json.Array)
	if !has_choices {
		res.error = "响应缺少 choices 数组"
		return res
	}
	if len(choices) == 0 {
		res.error = "响应 choices 为空"
		return res
	}
	choice, is_choice := choices[0].(json.Object)
	if !is_choice {
		res.error = "响应 choices[0] 不是对象"
		return res
	}
	message, has_message := choice["message"].(json.Object)
	if !has_message {
		res.error = "响应缺少 choices[0].message"
		return res
	}

	res.content = json_string(message, "content")
	res.reasoning = json_string(message, "reasoning_content")
	res.finish_reason = json_string(choice, "finish_reason")
	if usage, uok := root["usage"].(json.Object); uok {
		res.usage = format_usage(usage)
	}
	res.ok = true
	return res
}

// ---- 流式（SSE）增量解析 ----

// 累积一次 chat completions 流式响应（text/event-stream）的状态机。
// 逐网络分片喂养（sse_accumulator_feed），把 `data:` 事件里的 delta 增量拼成完整回复；
// 结果与 parse_response 对齐（content / reasoning / finish_reason / usage）。
//
// 生命周期：所有 builder 都在 context.temp_allocator 上，属本轮 scratch。
SseAccumulator :: struct {
	line:      strings.Builder, // 尚未收到换行的当前行（分片可能落在行中间）
	event:     strings.Builder, // 当前事件的 data 负载（多行以 \n 连接）
	content:   strings.Builder,
	reasoning: strings.Builder,
	finish:    string,
	usage:     string,
	saw_chunk: bool, // 是否解出过至少一个合法 chunk（区分"空流"与"非 SSE 响应"）
	done:      bool, // 收到 `data: [DONE]`
}

sse_accumulator_init :: proc(a: ^SseAccumulator) {
	a.line = strings.builder_make(context.temp_allocator)
	a.event = strings.builder_make(context.temp_allocator)
	a.content = strings.builder_make(context.temp_allocator)
	a.reasoning = strings.builder_make(context.temp_allocator)
}

// 喂入一段网络分片：按 `\n` 切行，行边界与分片边界无关（跨分片的半行留在 line 里）。
sse_accumulator_feed :: proc(a: ^SseAccumulator, chunk: string) {
	rest := chunk
	for {
		nl := strings.index_byte(rest, '\n')
		if nl < 0 {
			strings.write_string(&a.line, rest)
			return
		}
		strings.write_string(&a.line, rest[:nl])
		sse_handle_line(a, strings.to_string(a.line))
		strings.builder_reset(&a.line)
		rest = rest[nl + 1:]
	}
}

sse_handle_line :: proc(a: ^SseAccumulator, raw: string) {
	line := strings.trim_right(raw, "\r")
	if line == "" {
		sse_dispatch(a) // 空行 = 事件边界
		return
	}
	if strings.has_prefix(line, ":") {
		return // SSE 注释 / 心跳
	}
	if strings.has_prefix(line, "data:") {
		payload := line[len("data:"):]
		if strings.has_prefix(payload, " ") {
			payload = payload[1:]
		}
		if len(a.event.buf) > 0 {
			strings.write_byte(&a.event, '\n')
		}
		strings.write_string(&a.event, payload)
	}
	// event: / id: / retry: 等字段对 chat completions 无意义，忽略。
}

sse_dispatch :: proc(a: ^SseAccumulator) {
	if len(a.event.buf) == 0 {
		return
	}
	// payload 别名 a.event 的底层缓冲：先消费再 reset，避免后续 append 覆盖它。
	payload := strings.to_string(a.event)
	if payload == "[DONE]" {
		a.done = true
		strings.builder_reset(&a.event)
		return
	}
	sse_apply_chunk(a, payload)
	strings.builder_reset(&a.event)
}

// 解析单个 SSE chunk：choices[0].delta.{content, reasoning_content|reasoning} 与 finish_reason，
// 以及顶层 usage。结构缺失或 JSON 非法都静默跳过（坏帧不该打断整条流）。
sse_apply_chunk :: proc(a: ^SseAccumulator, payload: string) {
	v, err := json.parse_string(payload, .JSON, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	root, is_obj := v.(json.Object)
	if !is_obj {
		return
	}
	if usage, uok := root["usage"].(json.Object); uok {
		a.usage = format_usage(usage)
	}
	choices, has_choices := root["choices"].(json.Array)
	if !has_choices || len(choices) == 0 {
		// 末尾 usage 帧常带空 choices：流依然有效，只是没有内容 delta。
		a.saw_chunk = true
		return
	}
	choice, is_choice := choices[0].(json.Object)
	if !is_choice {
		return
	}
	// delta 优先；个别端点在某些帧里缺 delta，退回 message 兜底。
	delta, has_delta := choice["delta"].(json.Object)
	if !has_delta {
		delta, has_delta = choice["message"].(json.Object)
	}
	if has_delta {
		strings.write_string(&a.content, json_string(delta, "content"))
		reason := json_string(delta, "reasoning_content")
		if reason == "" {
			reason = json_string(delta, "reasoning")
		}
		strings.write_string(&a.reasoning, reason)
	}
	if fr := json_string(choice, "finish_reason"); fr != "" {
		a.finish = fr
	}
	a.saw_chunk = true
}

// 流结束后取解析结果。saw_chunk/done 皆无 → ok=false，调用方据此判断"这不是 SSE 流"。
sse_accumulator_result :: proc(a: ^SseAccumulator) -> ChatResponse {
	res: ChatResponse
	if !a.saw_chunk && !a.done {
		res.error = "响应不是 SSE 流"
		return res
	}
	res.ok = true
	res.content = strings.to_string(a.content)
	res.reasoning = strings.to_string(a.reasoning)
	res.finish_reason = a.finish
	res.usage = a.usage
	return res
}

// usage 展示串：`prompt=N completion=N total=N`（缺项跳过），与 C3 版口径一致。
format_usage :: proc(usage: json.Object) -> string {
	sb := strings.builder_make(context.temp_allocator)
	wrote := false
	append_usage_field(&sb, &wrote, "prompt", "prompt_tokens", usage)
	append_usage_field(&sb, &wrote, "completion", "completion_tokens", usage)
	append_usage_field(&sb, &wrote, "total", "total_tokens", usage)
	return strings.to_string(sb)
}

append_usage_field :: proc(sb: ^strings.Builder, wrote: ^bool, label, key: string, usage: json.Object) {
	n, ok := json_int(usage, key)
	if !ok {
		return
	}
	if wrote^ {
		strings.write_byte(sb, ' ')
	}
	fmt.sbprintf(sb, "%s=%d", label, n)
	wrote^ = true
}

json_string :: proc(obj: json.Object, key: string) -> string {
	if v, ok := obj[key].(json.String); ok {
		return string(v)
	}
	return ""
}

json_int :: proc(obj: json.Object, key: string) -> (value: int, ok: bool) {
	if i, iok := obj[key].(json.Integer); iok {
		return int(i), true
	}
	if f, fok := obj[key].(json.Float); fok {
		return int(f), true
	}
	return 0, false
}
