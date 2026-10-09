module llmcli::llm;

import std::io;
import std::collections::list;
import llmcli::buf, llmcli::chat, llmcli::http, llmcli::log;

// ---- 分节 ----
// OpenAI chat completions 兼容调用（doc 4.3）。只做 OpenAI 兼容，不做 provider 抽象；
// 内部复用 chat.c3（build_request/parse_response）与 http.c3（http_post_json）。
//
// reasoning_content 硬约束：只入存档、绝不回传端点——request / archive 两条序列化路径
// 在 chat.c3 里已分开，本模块只走 request 路径。

struct Llm
{
	String api_url;
	String api_key;
	String model;
	String effort;     // 思考强度（OpenAI 兼容侧透传/可忽略）
	int max_tokens;    // 0 = 不限制
}

// ---- 调用 ----

// 只用于 stderr 展示（--debug / 错误摘要）的请求/响应预览长度。
const usz DEBUG_PREVIEW = 4000;

// Response 语义与 chat::ChatResponse 对齐，另加 ok/error 便于主循环判断。
struct Response
{
	bool ok;
	String error;
	String text;
	String reasoning;
	String usage;
	String finish_reason;
}

// 一次 chat completion 往返：组装请求 → POST → 解析响应。
// 任一环节失败都在 error 里给出可读原因（mem 上的堆串）。
fn Response Llm.call(Llm* llm, String system_prompt, chat::Message[] messages)
{
	Response response;
	String request_body = build_request_with_system(llm, system_prompt, messages);

	String[] headers = {
		"Content-Type: application/json",
		string::format(tmem, "Authorization: Bearer %s", llm.api_key),
	};

	log::debug("POST %s", llm.api_url);
	log::debug("headers: Content-Type: application/json, Authorization: Bearer %s", llm.api_key);
	log::debug("request: %s", buf::truncate(request_body, DEBUG_PREVIEW));

	http::HttpResponse res = http::http_post_json(llm.api_url, headers, request_body);
	if (res.error.len)
	{
		response.error = string::format(mem, "网络错误：%s", res.error);
		return response;
	}
	log::debug("response(%d): %s", res.status, buf::truncate(res.body, DEBUG_PREVIEW));

	if (res.status < 200 || res.status >= 300)
	{
		response.error = string::format(mem, "HTTP %d：%s", res.status, buf::truncate(res.body, 2000));
		return response;
	}

	chat::ChatResponse parsed = chat::parse_response(mem, res.body);
	if (!parsed.ok)
	{
		response.error = string::format(mem, "%s；原始响应：%s",
		                                parsed.error, buf::truncate(res.body, 2000));
		return response;
	}
	response.ok = true;
	response.text = parsed.content;
	response.reasoning = parsed.reasoning;
	response.usage = parsed.usage;
	response.finish_reason = parsed.finish_reason;
	return response;
}

// 把 system 提示词拼在 messages 前面再组装请求体。
fn String build_request_with_system(Llm* llm, String system_prompt, chat::Message[] messages) @private
{
	if (!system_prompt.len) return chat::build_request(llm.model, messages);
	List{chat::Message} all;
	all.init(tmem);
	all.push({ .role = "system", .content = system_prompt });
	foreach (m : messages) all.push(m);
	return chat::build_request(llm.model, all.to_array(tmem));
}
