module llmcli::test_buf;

import llmcli::buf;

// 截断点必须落在 UTF-8 字符边界上，否则 stderr 会出现非法字节（下游按 UTF-8 解码会直接失败）
fn void test_truncate_keeps_utf8_boundary() @test
{
	// "你好世界" 共 12 字节；limit=4 会切进"好"的中间，应回退到"你"之后（3 字节）
	String out = buf::truncate("你好世界", 4);
	test::eq(out[:3], "你");
	test::eq(out[3:3], "…");

	// 未超限时原样返回
	test::eq(buf::truncate("short", 10), "short");
}
