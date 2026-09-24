module llmcli::http;

import libc, std::io;
import std::core::mem::allocators;
import curl;
import llmcli::buf;

// 一次非流式 HTTP POST 的结果。body/error 归 mem 所有，由调用方决定何时释放。
struct HttpResponse
{
	CLong status;   // HTTP 状态码；传输失败时为 0
	String body;    // 响应体原文
	String error;   // 传输层错误（curl result string），成功时为空
}

// sink 绑定 LIBC_ALLOCATOR（脱离 @pool/context），增长发生在 libcurl 的 C 回调里也安全。
// ponytail: append_bytes OOM 时直接 abort，而不再走原来的"短写让 curl 报 WRITE_ERROR"优雅路径；
// CLI 读取 MB 级响应体，OOM 不可达，v1 不做降级。
fn usz http_write_cb(char* buffer, usz size, usz nitems, void* outstream)
{
	usz total = size * nitems;
	((DString*)outstream).append_bytes(buffer[:total]);
	return total;
}

fn void http_init()
{
	curl::global_init(CurlGlobal.DEFAULT);
}

fn void http_deinit()
{
	curl::global_cleanup();
}

fn HttpResponse http_post_json(String url, String[] headers, String body)
{
	HttpResponse res;
	DString sink;
	sink.init(&allocators::LIBC_ALLOCATOR, 8192);
	defer sink.free();

	Curl* handle = curl::easy_init();
	if (!handle)
	{
		res.error = "curl_easy_init failed";
		return res;
	}
	defer curl::easy_cleanup(handle);

	// curl_slist_append 会复制字符串，但整个 list 必须活到 perform 之后。
	CurlSlist* list = null;
	defer curl::slist_free_all(list);
	foreach (h : headers)
	{
		list = curl::slist_append(list, h.zstr_tcopy());
	}

	// URL 与 WRITEDATA 只是被 libcurl 记下指针，需活到 perform 之后；
	// body 用 COPYPOSTFIELDS 让 libcurl 自己复制一份。
	ZString url_z = url.zstr_copy(mem);
	defer free(url_z);

	curl::easy_setopt(handle, CurlOption.URL, url_z);
	curl::easy_setopt(handle, CurlOption.HTTPHEADER, list);
	curl::easy_setopt(handle, CurlOption.COPYPOSTFIELDS, body.zstr_tcopy());
	curl::easy_setopt(handle, CurlOption.WRITEFUNCTION, &http_write_cb);
	curl::easy_setopt(handle, CurlOption.WRITEDATA, &sink);

	CurlResult result = curl::easy_perform(handle);
	if (result != CurlResult.OK)
	{
		res.error = buf::cstr(mem, (ZString)curl::easy_strerror(result));
		return res;
	}

	CLong status @noinit;
	if (curl::easy_getinfo(handle, CurlInfoType.RESPONSE_CODE, &status) != CurlResult.OK)
	{
		res.error = "curl_easy_getinfo(RESPONSE_CODE) failed";
		return res;
	}
	res.status = status;
	res.body = sink.copy_str(mem);
	return res;
}
