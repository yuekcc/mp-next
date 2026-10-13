package main

import "core:c"
import "core:strings"
import curl "vendor:curl"

// ---- 分节 ----
// libcurl 封装（非流式 POST）。写回调把响应体追加到 temp 上的 Builder。
// 生命周期：http_init / http_deinit 管 curl 全局；每次请求自建 easy handle。

// ---- 类型 ----

// 一次非流式 HTTP POST 的结果。
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

// 回调在 libcurl 的 C 栈上执行；这里只用 temp 分配器（同一线程内），不跨线程。
http_write_cb :: proc(buffer: [^]u8, size: u64, nitems: u64, outstream: rawptr) -> u64 {
	total := size * nitems
	strings.write_bytes((^strings.Builder)(outstream), buffer[:total])
	return total
}

http_post_json :: proc(url: string, headers: []string, body: string) -> HttpResponse {
	res: HttpResponse
	sink := strings.builder_make(context.temp_allocator)

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
	curl.easy_setopt(handle, .WRITEDATA, &sink)

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
