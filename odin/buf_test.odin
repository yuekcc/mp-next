package main

import "core:testing"

// ---- S1：buf.truncate（纯函数，仅为 stderr 展示） ----

@(test)
truncate_leaves_short_text_untouched :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, truncate("hello", 10), "hello")
}

@(test)
truncate_appends_stub_with_total_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, truncate("hello", 3), "hel…（已截断，共 5 字节）")
}

@(test)
truncate_backs_off_to_utf8_boundary :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// "你好世界" 12 字节；limit=4 落在第 2 个字的中间，应回退到 3 字节边界。
	testing.expect_value(t, truncate("你好世界", 4), "你…（已截断，共 12 字节）")
}
