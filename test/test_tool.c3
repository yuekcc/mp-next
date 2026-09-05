// test_tool — 工具层纯逻辑 seam 单测（AGENTS「非平凡逻辑留一个可运行检查」）。
//
// 覆盖此前零检查的高风险逻辑：
//   - hashline 锚点管线（util::line_hash / util::load_lines）：read 与 hash_edit
//     共享的字节一致契约（含 CRLF 归一化），哈希确定性；
//   - hash_edit 原子语义：锚点失配整批拒绝且文件不动，锚点正确才应用；
//   - memstore 文件名解析（新/旧格式）。
// 全部走本地临时文件与纯函数，无网络依赖，离线可跑。

import std::io::file;
import std::io::path;
import std::core::string;
import util;
import tool;
import memstore;

// 唯一临时文件路径（timestamp_id 含 pid+序号，多测试/进程不撞车）
fn String tmp_file_path()
{
	Path tmp_dir = path::temp_directory(tmem)!!;
	return string::tformat("%s/%s.md", (String)tmp_dir, util::timestamp_id(tmem));
}

fn String read_file_string(String p)
{
	return (String)((char[])file::load(tmem, p)!!);
}

// ===========================================================================
// hashline 锚点：确定性 + 行尾空白/\r 剥离 + 无字母数字行的位置敏感
// ===========================================================================

fn void test_util_line_hash_anchor() @test
{
	// 确定性：同输入同输出
	test::eq(util::line_hash(tmem, "hello", 3), util::line_hash(tmem, "hello", 3));

	// 行尾空白（空格/tab）与 \r 不参与哈希（读侧显示已剥，锚点必须一致）
	test::eq(util::line_hash(tmem, "abc  \t", 1), util::line_hash(tmem, "abc", 1));
	test::eq(util::line_hash(tmem, "abc\r", 1), util::line_hash(tmem, "abc", 1));

	// 无字母数字行把行号折叠进哈希：同内容不同位置必须得到不同锚点
	test::@check(util::line_hash(tmem, "}", 5) != util::line_hash(tmem, "}", 6),
		"non-alnum line must be position-sensitive");
	test::@check(util::line_hash(tmem, "", 1) != util::line_hash(tmem, "", 2),
		"empty line must be position-sensitive");
}

// read/hash_edit 同源管线（load_lines）：CRLF 文件与 \n 文件得到同一套锚点
fn void test_util_load_lines_crlf_contract() @test
{
	String p = tmp_file_path();
	(void)file::save(p, "a\r\nb\n");
	defer (void)file::delete(p);

	String[] lines = util::load_lines(tmem, p)!!;
	// "a\nb\n" split("\n") 得 ["a","b",""]（结尾空段是 load_lines 的既定约定，
	// read 与 hash_edit 同源，两侧一致）
	test::eq((int)3, (int)lines.len);
	test::eq("a", lines[0]);
	test::eq("b", lines[1]);
	test::eq(util::line_hash(tmem, "a", 1), util::line_hash(tmem, lines[0], 1));
	test::eq(util::line_hash(tmem, "b", 2), util::line_hash(tmem, lines[1], 2));
}

// ===========================================================================
// hash_edit 原子语义：锚点失配 → 整批拒绝、零写入；锚点正确 → 应用替换
// ===========================================================================

fn void test_tool_hash_edit_reject_stale() @test
{
	String p = tmp_file_path();
	(void)file::save(p, "one\ntwo");
	defer (void)file::delete(p);

	// 锚点失配（哪怕只错一个）：整批拒绝，文件字节不动
	tool::EditOp[] stale = { { .line = 1, .hash = "ZZ", .content = "UNO", .end_line = 0 } };
	DString out = dstring::new(tmem);
	tool::hash_edit(tmem, &out, p, stale)!!;
	String report = out.str_view();
	test::@check(report.contains("HashEdit rejected"),
		"stale anchor must reject the whole batch: %s", report);
	test::eq("one\ntwo", read_file_string(p));
}

fn void test_tool_hash_edit_apply_replace() @test
{
	String p = tmp_file_path();
	(void)file::save(p, "one\ntwo");
	defer (void)file::delete(p);

	// 锚点正确：按行替换，多行 content 折成多行
	String[] lines = util::load_lines(tmem, p)!!;
	tool::EditOp[] op = {
		{ .line = 1, .hash = util::line_hash(tmem, lines[0], 1), .content = "uno\nuno2", .end_line = 0 }
	};
	DString out = dstring::new(tmem);
	tool::hash_edit(tmem, &out, p, op)!!;
	test::eq("uno\nuno2\ntwo", read_file_string(p));
}

// ===========================================================================
// memstore 文件名解析（纯逻辑，此前无测试）
// ===========================================================================

fn void test_memstore_parse_filename() @test
{
	// 新格式：YYYY-MM-DD-HH-MM-SS_hex8_slug
	memstore::NameParts np1 = memstore::parse_filename("2026-09-05-10-20-30_1a2b3c4d_hello-world");
	test::eq("2026-09-05-10-20-30", np1.ts);
	test::eq("1a2b3c4d", np1.id);
	test::eq("hello-world", np1.slug);

	// 旧格式：无 hex id
	memstore::NameParts np2 = memstore::parse_filename("2026-09-05-10-20-30_no-id");
	test::eq("", np2.id);
	test::eq("no-id", np2.slug);

	// hex id 边界：4-8 位小写十六进制
	test::eq(true, memstore::is_hex_id("abcd"));
	test::eq(true, memstore::is_hex_id("abcdef12"));
	test::eq(false, memstore::is_hex_id("abc"));
	test::eq(false, memstore::is_hex_id("abcdef123"));
	test::eq(false, memstore::is_hex_id("abcdeg"));
}
