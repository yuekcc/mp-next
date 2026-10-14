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

// 按字节截前缀也必须落在字符边界上（轨迹 slug、traj tail 展示都依赖它）
fn void test_utf8_cut_backs_off_to_boundary() @test
{
	// "统计当前目录下有多少个文件"：前 10 个字 30 字节，"个" 占第 31..33 字节；
	// limit=32 落进"个"中间，应回退到 30。
	String s = "统计当前目录下有多少个文件";
	test::eq((int)buf::utf8_cut(s, 32), 30);
	test::eq(s[:buf::utf8_cut(s, 32)], "统计当前目录下有多少");

	// limit 已在边界上，或超出长度时，原样返回
	test::eq((int)buf::utf8_cut(s, 30), 30);
	test::eq((int)buf::utf8_cut("abc", 10), 3);
}
