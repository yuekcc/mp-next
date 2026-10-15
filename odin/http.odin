package main

import "base:runtime"
import "core:c"
import "core:strings"
import curl "vendor:curl"

// ---- 分节 ----
// libcurl 封装。写回调把响应体追加到 temp 上的 Builder；流式模式额外把每个网络分片
// 增量转交 on_chunk（SSE 逐事件解析在回调里做）。
// 生命周期：http_init / http_deinit 管 curl 全局；每次请求自建 easy handle。

// ---- 类型 ----

// 一次 HTTP POST 的结果（非流式与流式共用）。
HttpResponse :: struct {
	status: int, // HTTP 状态码；传输失败时为 0
	body:   string, // 响应体原文
	error:  string, // 传输层错误（curl result string），成功时为空
}

// ---- 生命周期 ----

http_init :: proc() {
	curl.global_init(curl.GLOBAL_DEFAULT)
}

http_deinit :: proc() {
	curl.global_cleanup()
}

// ---- 请求 ----

// 流式模式下每个网络分片的回调（chunk 的生命周期只到回调返回）。
HttpChunkFn :: proc(chunk: string, user: rawptr)

// 写回调的上下文：sink 累积完整原文；on_chunk 非空时把分片增量转交出去。
http_stream_ctx :: struct {
	sink:           ^strings.Builder,
	on_chunk:       HttpChunkFn,
	user:           rawptr,
	caller_context: runtime.Context, // 回调里要还原：C 调用不会传 Odin 的隐式 context
}

// 回调在 libcurl 的 C 栈上执行，必须是 "c" 调用约定：C 不会传 Odin 的隐式 context 参数，
// 若用默认约定，context 会被当成写缓冲指针（第一个整型参数）读出垃圾 → 一碰分配器就崩。
// 所以这里先还原发起请求时捕获的 caller_context，再调用任何会用 context 的 Odin 过程。
http_write_cb :: proc "c" (buffer: [^]u8, size: u64, nitems: u64, outstream: rawptr) -> u64 {
	ctx := (^http_stream_ctx)(outstream)
	context = ctx.caller_context

	total := size * nitems
	chunk := buffer[:total]
	strings.write_bytes(ctx.sink, chunk)
	if ctx.on_chunk != nil {
		ctx.on_chunk(string(chunk), ctx.user)
	}
	return total
}

// 非流式 POST：等价于不挂 on_chunk 的流式 POST（响应原文一次收齐）。
http_post_json :: proc(url: string, headers: []string, body: string) -> HttpResponse {
	return http_post_json_stream(url, headers, body, nil, nil)
}

// POST 并把响应分片增量交给 on_chunk；返回体仍带完整原文，供非 2xx 错误摘要与
// "端点无视 stream:true、仍回整包 JSON" 的兜底。
http_post_json_stream :: proc(url: string, headers: []string, body: string,
                             on_chunk: HttpChunkFn, user: rawptr) -> HttpResponse {
	res: HttpResponse
	sink := strings.builder_make(context.temp_allocator)
	ctx := http_stream_ctx{
		sink = &sink,
		on_chunk = on_chunk,
		user = user,
		caller_context = context,
	}

	handle := curl.easy_init()
	if handle == nil {
		res.error = "curl_easy_init failed"
		return res
	}
	defer curl.easy_cleanup(handle)

	// curl_slist_append 会复制字符串，但整个 list 必须活到 perform 之后。
	list: ^curl.slist = nil
	defer curl.slist_free_all(list)
	for h in headers {
		list = curl.slist_append(list, strings.clone_to_cstring(h, context.temp_allocator) or_else "")
	}

	// URL 与 WRITEDATA 只是被 libcurl 记下指针，需活到 perform 之后；
	// body 用 COPYPOSTFIELDS 让 libcurl 自己复制一份。
	url_z := strings.clone_to_cstring(url, context.temp_allocator) or_else ""
	body_z := strings.clone_to_cstring(body, context.temp_allocator) or_else ""

	curl.easy_setopt(handle, .URL, url_z)
	curl.easy_setopt(handle, .HTTPHEADER, list)
	curl.easy_setopt(handle, .COPYPOSTFIELDS, body_z)
	curl.easy_setopt(handle, .WRITEFUNCTION, http_write_cb)
	curl.easy_setopt(handle, .WRITEDATA, &ctx)

	code := curl.easy_perform(handle)
	if code != .E_OK {
		res.error = cstring_to_string(curl.easy_strerror(code))
		return res
	}

	status: c.long
	if curl.easy_getinfo(handle, .RESPONSE_CODE, &status) != .E_OK {
		res.error = "curl_easy_getinfo(RESPONSE_CODE) failed"
		return res
	}
	res.status = int(status)
	res.body = strings.to_string(sink)
	return res
}

// cstring -> Odin string（复制到 temp）。
cstring_to_string :: proc(s: cstring) -> string {
	if s == nil {
		return ""
	}
	return strings.clone_from_cstring(s, context.temp_allocator) or_else ""
}
