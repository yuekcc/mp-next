module llmcli::test_session;

import std::io, std::os::env;
import llmcli::chat, llmcli::session;

const String TEST_HOME = "build/test_session_home";
// 固定时间戳：断言落盘内容时不受当前时钟影响
const String FIXED_TS = "2026-09-29T20:00:00+08:00";

fn void use_test_home() @private
{
	(void)env::set_var(session::HOME_ENV, TEST_HOME);
}

fn void test_session_id_validation() @test
{
	test::eq(session::valid_id("work-1"), true);
	test::eq(session::valid_id(""), false);
	test::eq(session::valid_id(".."), false);
	test::eq(session::valid_id("../escape"), false);
	test::eq(session::valid_id("a/b"), false);
	test::eq(session::valid_id("a\\b"), false);
	test::eq(session::valid_id("a:b"), false);
}

fn void test_home_override_changes_path() @test
{
	use_test_home();
	@pool()
	{
		session::Session store = session::open("x");
		test::@check(store.path.contains("test_session_home"),
		             "LLMCLI_HOME 应改变会话路径，实际：%s", store.path);
		test::@check(store.path.ends_with("x.jsonl"), "文件名应以 id 命名，实际：%s", store.path);
	};
}

fn void test_append_and_load_roundtrip() @test
{
	use_test_home();
	session::Session store = session::open("roundtrip");
	(void)file::save(store.path, "");

	@pool()
	{
		session::Record[] batch = {
			{ .message = { .role = "user", .content = "问题" }, .turn = 1, .ts = session::timestamp(tmem) },
			{ .message = { .role = "assistant", .content = "回答", .reasoning = "思考过程" }, .turn = 1, .ts = session::timestamp(tmem) },
			{ .message = { .role = "tool", .content = "工具输出", .tool_call_id = "call_1" }, .turn = 1, .ts = session::timestamp(tmem) },
		};
		session::append(&store, batch);
	};

	@pool()
	{
		Message[] loaded = session::load(tmem, &store);
		test::eq((int)loaded.len, 3);
		test::eq(loaded[0].role, "user");
		test::eq(loaded[0].content, "问题");
		test::eq(loaded[1].reasoning, "思考过程");
		test::eq(loaded[2].tool_call_id, "call_1");
		test::eq(loaded[2].content, "工具输出");
	};
}

// 每条记录保留自己的 turn：输入与它触发的工具回填记 1，最终答案记 2。
// 逐行断言而不是全文子串——整批共用一个 turn 时，第一行就会红。
fn void test_append_keeps_per_message_turn() @test
{
	use_test_home();
	session::Session store = session::open("turns");
	(void)file::save(store.path, "");

	@pool()
	{
		session::Record[] batch = {
			{ .message = { .role = "user", .content = "问" }, .turn = 1, .ts = FIXED_TS },
			{ .message = { .role = "tool", .content = "工具输出", .tool_call_id = "call_1" }, .turn = 1, .ts = FIXED_TS },
			{ .message = { .role = "assistant", .content = "答" }, .turn = 2, .ts = FIXED_TS },
		};
		session::append(&store, batch);
	};

	char[] data = file::load(tmem, store.path)!!;
	// skip_empty：append 每条记录都以 \n 收尾，末尾空段不算一行
	String[] lines = ((String)data).split(tmem, "\n", 0, true);
	test::eq((int)lines.len, 3);
	test::@check(lines[0].contains("\"turn\":1") && lines[0].contains("问"),
	             "第 1 行（user）应记 turn 1，实际：%s", lines[0]);
	test::@check(lines[1].contains("\"turn\":1") && lines[1].contains("工具输出"),
	             "第 2 行（tool）应记 turn 1，实际：%s", lines[1]);
	test::@check(lines[2].contains("\"turn\":2") && lines[2].contains("答"),
	             "第 3 行（assistant）应记 turn 2，实际：%s", lines[2]);
}

// ts 是消息发生的时刻，按记录写入：整批共用一个落盘时间时，第 2 行就会红。
fn void test_append_keeps_per_message_ts() @test
{
	use_test_home();
	session::Session store = session::open("stamps");
	(void)file::save(store.path, "");

	@pool()
	{
		session::Record[] batch = {
			{ .message = { .role = "user", .content = "问" }, .turn = 1,
			  .ts = "2026-09-29T20:00:00+08:00" },
			{ .message = { .role = "assistant", .content = "答" }, .turn = 2,
			  .ts = "2026-09-29T20:00:07+08:00" },
		};
		session::append(&store, batch);
	};

	char[] data = file::load(tmem, store.path)!!;
	String[] lines = ((String)data).split(tmem, "\n", 0, true);
	test::eq((int)lines.len, 2);
	test::@check(lines[0].contains("\"ts\":\"2026-09-29T20:00:00+08:00\""),
	             "第 1 行应写记录自带的 ts，实际：%s", lines[0]);
	test::@check(lines[1].contains("\"ts\":\"2026-09-29T20:00:07+08:00\""),
	             "第 2 行应写记录自带的 ts，实际：%s", lines[1]);
}

// docs 承诺工具输出原样入库、不截断：64 KiB 内容要整条落盘并能原样读回。
fn void test_append_keeps_large_content() @test
{
	use_test_home();
	session::Session store = session::open("large");
	(void)file::save(store.path, "");

	@pool()
	{
		DString big = dstring::new(tmem);
		big.append_string_repeat("0123456789abcdef", 4096);
		session::Record[] batch = {
			{ .message = { .role = "tool", .content = big.str_view(), .tool_call_id = "call_big" }, .turn = 1, .ts = FIXED_TS },
		};
		session::append(&store, batch);
	};

	@pool()
	{
		Message[] loaded = session::load(tmem, &store);
		test::eq((int)loaded.len, 1);
		test::eq((int)loaded[0].content.len, 16 * 4096);
		test::eq(loaded[0].content[:16], "0123456789abcdef");
		test::eq(loaded[0].content[32768:16], "0123456789abcdef");
		test::eq(loaded[0].content[loaded[0].content.len - 16:16], "0123456789abcdef");
	};
}

fn void test_broken_lines_are_skipped() @test
{
	use_test_home();
	session::Session store = session::open("broken");
	(void)file::save(store.path, "");

	@pool()
	{
		session::Record[] batch = { { .message = { .role = "user", .content = "good" }, .turn = 1, .ts = FIXED_TS } };
		session::append(&store, batch);
	};
	// 手动写入一行坏数据
	@pool()
	{
		File file = file::open(store.path, "ab")!!;
		file.write("{ this is not json }\n")!!;
		file.close()!!;
	};

	@pool()
	{
		Message[] loaded = session::load(tmem, &store);
		test::eq((int)loaded.len, 1);
		test::eq(loaded[0].content, "good");
	};
}

fn void test_missing_session_file_loads_empty() @test
{
	use_test_home();
	session::Session store = session::open("does-not-exist");
	@pool()
	{
		test::eq(session::load(tmem, &store).len, 0);
	};
}

fn void test_list_all_reports_counts() @test
{
	use_test_home();
	session::Session store = session::open("listed");
	(void)file::save(store.path, "");
	@pool()
	{
		session::Record[] batch = {
			{ .message = { .role = "user", .content = "a" }, .turn = 1, .ts = FIXED_TS },
			{ .message = { .role = "assistant", .content = "b" }, .turn = 1, .ts = FIXED_TS },
		};
		session::append(&store, batch);
	};

	@pool()
	{
		session::SessionSummary[] items = session::list_all(tmem);
		bool found = false;
		foreach (item : items)
		{
			if (item.id == "listed")
			{
				found = true;
				test::eq((int)item.count, 2);
				test::@check(item.updated != "-", "应记录更新时间，实际：%s", item.updated);
			}
		}
		test::eq(found, true);
	};
}
