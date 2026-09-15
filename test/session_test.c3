module llmcli::test_session;

import std::io, std::os::env;
import llmcli::chat, llmcli::session;

const String TEST_HOME = "build/test_session_home";

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
		Message[] batch = {
			{ .role = "user", .content = "问题" },
			{ .role = "assistant", .content = "回答", .reasoning = "思考过程" },
			{ .role = "tool", .content = "工具输出", .tool_call_id = "call_1" },
		};
		session::append(&store, 1, batch);
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

fn void test_broken_lines_are_skipped() @test
{
	use_test_home();
	session::Session store = session::open("broken");
	(void)file::save(store.path, "");

	@pool()
	{
		Message[] batch = { { .role = "user", .content = "good" } };
		session::append(&store, 1, batch);
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
		Message[] batch = {
			{ .role = "user", .content = "a" },
			{ .role = "assistant", .content = "b" },
		};
		session::append(&store, 1, batch);
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
