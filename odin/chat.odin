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
// 回传端点时不带 reasoning_content；不带 tools；stream 固定 false。
build_request :: proc(model: string, messages: []Message) -> string {
	root := make(json.Object, allocator = context.temp_allocator)
	root["model"] = model
	root["stream"] = false

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
