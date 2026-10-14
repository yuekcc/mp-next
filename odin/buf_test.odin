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

// 按字节截前缀也必须落在字符边界上（轨迹 slug、traj tail 展示都依赖它）。
@(test)
utf8_cut_backs_off_to_boundary :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// "统计当前目录下有多少个文件"：前 10 个字 30 字节，"个" 占第 31..33 字节；
	// limit=32 落进"个"中间，应回退到 30。
	s := "统计当前目录下有多少个文件"
	testing.expect_value(t, utf8_cut(s, 32), 30)
	testing.expect_value(t, s[:utf8_cut(s, 32)], "统计当前目录下有多少")

	// limit 已在边界上，或超出长度时，原样返回
	testing.expect_value(t, utf8_cut(s, 30), 30)
	testing.expect_value(t, utf8_cut("abc", 10), 3)
}
