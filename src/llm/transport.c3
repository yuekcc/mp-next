// transport — llm 模块的 libcurl 传输层：全局生命周期（幂等 init/shutdown）
// 与单次流式/整包 HTTP POST。不感知 SSE 语义，仅负责把响应字节交给调用方提供的
// 写回调（WRITEDATA 携带每尝试的接收状态，替换原 CLI 的模块级全局 StreamState）。
module llm;

import std::core::string;
import libc, curl;

// curl 全局生命周期引用计数：幂等 init/shutdown（D9），main 负责成对调用。
// 模块内不再有任何进程级 exit——init 失败以返回值表达，由调用方决定处理。
int g_curl_refs = 0;

fn bool init()
{
	if (g_curl_refs > 0)
	{
		g_curl_refs++;
		return true;
	}
	if (curl::global_init(curl::CurlGlobal.DEFAULT) != curl::CurlResult.OK) return false;
	g_curl_refs = 1;
	return true;
}

fn void shutdown()
{
	if (g_curl_refs == 0) return;
	g_curl_refs--;
	if (g_curl_refs == 0) curl::global_cleanup();
}

// 单次流式/整包 POST。成功返回 ""；失败返回人类可读的 curl 错误描述（tmem 临时
// 视图）。http_code 恒带出（0 = 未拿到响应头）。写回调与 userdata 由调用方按
// 接收模式提供（流式走 SSE 分帧，整包只累积字节）。
fn String http_attempt(LlmOption* ctx, String payload, int* http_code, curl::CurlWriteCallback wfn, void* wdata)
{
	curl::Curl* h = curl::easy_init();
	if (h == null) return "curl: failed to init easy handle";
	defer curl::easy_cleanup(h);

	char[256] errbuf @noinit;
	libc::memset(&errbuf, 0, (usz)errbuf.len);

	curl::easy_setopt(h, curl::CurlOption.NOPROGRESS, (CLong)1);
	curl::easy_setopt(h, curl::CurlOption.ERRORBUFFER, &errbuf);
	curl::easy_setopt(h, curl::CurlOption.URL, ctx.url.zstr_tcopy());
	curl::easy_setopt(h, curl::CurlOption.POSTFIELDS, payload.zstr_tcopy());
	curl::easy_setopt(h, curl::CurlOption.POSTFIELDSIZE, (CLong)payload.len);
	if (DEFAULT_CONNECT_TIMEOUT > 0)
	{
		curl::easy_setopt(h, curl::CurlOption.CONNECTTIMEOUT, (CLong)DEFAULT_CONNECT_TIMEOUT);
	}
	if (DEFAULT_MAX_TIME > 0)
	{
		curl::easy_setopt(h, curl::CurlOption.TIMEOUT, (CLong)DEFAULT_MAX_TIME);
	}
	if (DEFAULT_SPEED_LIMIT > 0 && DEFAULT_SPEED_TIME > 0)
	{
		curl::easy_setopt(h, curl::CurlOption.LOW_SPEED_LIMIT, (CLong)DEFAULT_SPEED_LIMIT);
		curl::easy_setopt(h, curl::CurlOption.LOW_SPEED_TIME, (CLong)DEFAULT_SPEED_TIME);
	}
	curl::CurlSlist* hdrs = null;
	hdrs = curl::slist_append(hdrs, (ZString)"Content-Type: application/json");
	if (ctx.api_key.len > 0)
	{
		String auth = string::tformat("Authorization: Bearer %s", ctx.api_key);
		hdrs = curl::slist_append(hdrs, auth.zstr_tcopy());
	}
	curl::easy_setopt(h, curl::CurlOption.HTTPHEADER, hdrs);
	curl::easy_setopt(h, curl::CurlOption.WRITEFUNCTION, wfn);
	curl::easy_setopt(h, curl::CurlOption.WRITEDATA, wdata);

	curl::CurlResult res = curl::easy_perform(h);
	CLong code = 0;
	curl::easy_getinfo(h, curl::CurlInfoType.RESPONSE_CODE, &code);
	*http_code = (int)code;
	curl::slist_free_all(hdrs);

	if (res != curl::CurlResult.OK)
	{
		String detail = ((ZString)&errbuf[0]).str_view();
		if (detail.len == 0) { detail = ((ZString)curl::easy_strerror(res)).str_view(); }
		return string::tformat("curl error: %s", detail);
	}
	return "";
}
