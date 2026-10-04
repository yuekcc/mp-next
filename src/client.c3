module llmcli::client;

import llmcli::buf, llmcli::chat, llmcli::cli, llmcli::http, llmcli::log;

// 只用于 stderr 展示（--debug / 错误摘要）的请求/响应预览长度。
const usz DEBUG_PREVIEW = 4000;

// 一次 chat completion 往返：组装请求 → POST → 解析响应。
// 任一环节失败都在返回的 ChatResponse.error 里给出可读原因（mem 上的堆串）。
// 密钥由 log 统一脱敏（main 里 add_secret 注册过一次），这里直接打原文即可。
fn ChatResponse chat_once(cli::Ctx* ctx, chat::Message[] messages)
{
	chat::ChatResponse response;

	String request_body = chat::build_request(ctx.model, messages);
	String[] headers = {
		"Content-Type: application/json",
		string::format(tmem, "Authorization: Bearer %s", ctx.api_key),
	};

	log::debug("POST %s", ctx.api_url);
	log::debug("headers: Content-Type: application/json, Authorization: Bearer %s", ctx.api_key);
	log::debug("request: %s", buf::truncate(request_body, DEBUG_PREVIEW));

	http::HttpResponse res = http::http_post_json(ctx.api_url, headers, request_body);
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

	response = chat::parse_response(mem, res.body);
	if (!response.ok) response.error = string::format(mem, "%s；原始响应：%s",
	                                                  response.error, buf::truncate(res.body, 2000));
	return response;
}
