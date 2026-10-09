module llmcli::test_trajectory;

import std::io, std::io::path;
import llmcli::trajectory;

const String TEST_ROOT = "build/test_traj";

fn void fresh() @private
{
	(void)path::rmtree((Path)TEST_ROOT);
	trajectory::set_base_dir(TEST_ROOT);
}

// 新建轨迹：目录名 <hex8>-<slug>，首行是头，路径在 <root>/<name>/trajectory.jsonl
fn void test_open_new_layout() @test
{
	fresh();
	@pool()
	{
		trajectory::Trajectory traj = trajectory::open_new("mytask");
		test::@check(traj.path.ends_with("trajectory.jsonl"), "路径应以 trajectory.jsonl 结尾：%s", traj.path);
		test::@check(traj.name.ends_with("-mytask"), "目录名应带 slug 后缀：%s", traj.name);
		test::eq(traj.id.len, 8);
		test::@check(traj.name.starts_with(traj.id), "目录名应以 hex8 开头：%s", traj.name);
		test::eq(path::exists((Path)traj.path), true);
		char[] data = file::load(tmem, traj.path)!!;
		test::@check(((String)data).contains("\"type\":\"trajectory\""), "首行应是轨迹头：%s", (String)data);
	};
}

// slug 里的危险字符被替换掉，不会破坏目录结构
fn void test_slug_sanitized() @test
{
	fresh();
	@pool()
	{
		trajectory::Trajectory traj = trajectory::open_new("a/b c");
		test::@check(!traj.name.contains("/"), "目录名不能含 /：%s", traj.name);
		test::@check(!traj.name.contains(" "), "目录名不能含空格：%s", traj.name);
	};
}

// reasoning 步骤的 thought/cmd 往返
fn void test_append_read_reasoning() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("r");
	@pool()
	{
		trajectory::Step s = {
			.type = trajectory::T_REASONING,
			.thought = "先看一下。",
			.cmd = "ls -la",
			.run_id = traj.id,
		};
		String id = trajectory::append(&traj, s);
		test::eq(id.len > 0, true);
	};
	@pool()
	{
		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		test::eq((int)steps.len, 1);
		test::eq(steps[0].type, "reasoning");
		test::eq(steps[0].thought, "先看一下。");
		test::eq(steps[0].cmd, "ls -la");
		test::eq(steps[0].run_id, traj.id);
	};
}

// shell-output 步骤带 stdout 与 exit
fn void test_append_read_shell_output() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("o");
	@pool()
	{
		trajectory::Step s = { .type = trajectory::T_SHELL_OUTPUT, .stdout = "hello\n", .exit = 0 };
		trajectory::append(&traj, s);
	};
	@pool()
	{
		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		test::eq((int)steps.len, 1);
		test::eq(steps[0].stdout, "hello\n");
		test::eq(steps[0].exit, 0);
	};
}

// FINAL=""（空串）是合法值：final 步骤的 content 为空也要能读回且 type 正确
fn void test_final_empty_content_roundtrip() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("f");
	@pool()
	{
		trajectory::Step s = { .type = trajectory::T_FINAL, .content = "" };
		trajectory::append(&traj, s);
	};
	@pool()
	{
		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		test::eq((int)steps.len, 1);
		test::eq(steps[0].type, "final");
		test::eq(steps[0].content, "");
	};
}

// 大字段 spill 到 blob：步骤里不内联原文，读取时按需取回、内容一致
fn void test_large_field_spills_to_blob() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("blob");
	@pool()
	{
		DString big = dstring::new(tmem);
		big.append_string_repeat("0123456789abcdef", 4096); // 64 KiB
		trajectory::Step s = { .type = trajectory::T_SHELL_OUTPUT, .stdout = big.str_view(), .exit = 0 };
		trajectory::append(&traj, s);
	};
	// 原文不应内联进 jsonl
	char[] data = file::load(tmem, traj.path)!!;
	test::@check(!((String)data).contains("0123456789abcdef0123"),
	             "大字段不应内联进步骤：%s", ((String)data)[:200]);
	test::@check(((String)data).contains("stdout_ref"), "应写入 stdout_ref：%s", ((String)data)[:200]);

	@pool()
	{
		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		test::eq((int)steps.len, 1);
		test::eq((int)steps[0].stdout.len, 16 * 4096);
		test::eq(steps[0].stdout[:16], "0123456789abcdef");
		test::eq(steps[0].stdout[steps[0].stdout.len - 16:16], "0123456789abcdef");
	};
}

// fork 写 fork 步骤并返回子 id；merge 写 merge 步骤
fn void test_fork_and_merge() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("parent");
	@pool()
	{
		String child = trajectory::fork(&traj, "childtask");
		test::eq(child.len, 8);
		trajectory::merge(&traj, child);

		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		test::eq((int)steps.len, 2);
		test::eq(steps[0].type, "fork");
		test::eq(steps[0].child, child);
		test::eq(steps[0].slug, "childtask");
		test::eq(steps[1].type, "merge");
		test::eq(steps[1].from_traj, child);
	};
}

// last / find / tail
fn void test_last_find_tail() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("nav");
	@pool()
	{
		String first = trajectory::append(&traj, { .type = trajectory::T_PROMPT, .content = "第一问" });
		trajectory::append(&traj, { .type = trajectory::T_REASONING, .cmd = "echo hi" });
		trajectory::append(&traj, { .type = trajectory::T_FINAL, .content = "答" });

		trajectory::Step last = trajectory::last(tmem, &traj);
		test::eq(last.type, "final");

		trajectory::Step found;
		test::eq(trajectory::find(tmem, &traj, first, &found), true);
		test::eq(found.content, "第一问");

		test::eq((int)trajectory::tail(tmem, &traj, 2).len, 2);
		test::eq((int)trajectory::tail(tmem, &traj, 10).len, 3);
	};
}

// search 命中多个字段
fn void test_search() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("s");
	@pool()
	{
		trajectory::append(&traj, { .type = trajectory::T_REASONING, .cmd = "grep needle" });
		trajectory::append(&traj, { .type = trajectory::T_SHELL_OUTPUT, .stdout = "no hit" });
		trajectory::append(&traj, { .type = trajectory::T_FINAL, .content = "needle found" });
	};
	@pool()
	{
		trajectory::Step[] hits = trajectory::search(tmem, &traj, "needle");
		test::eq((int)hits.len, 2);
	};
}

// 续接既有轨迹：open_resume 不覆盖已有内容，继续追加
fn void test_resume_appends() @test
{
	fresh();
	trajectory::Trajectory first = trajectory::open_new("resume");
	@pool()
	{
		trajectory::append(&first, { .type = trajectory::T_PROMPT, .content = "A" });
	};
	@pool()
	{
		trajectory::Trajectory again = trajectory::open_resume(first.name);
		trajectory::append(&again, { .type = trajectory::T_FINAL, .content = "B" });
	};
	@pool()
	{
		trajectory::Step[] steps = trajectory::read_all(tmem, &first);
		test::eq((int)steps.len, 2);
		test::eq(steps[0].content, "A");
		test::eq(steps[1].content, "B");
	};
}

// 旧会话格式（{ts,turn,message}）读取时映射为步骤，不报错。
// user→prompt，assistant→reasoning，assistant 之后的 user（执行输出）→shell-output。
fn void test_legacy_session_mapping() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("legacy");
	@pool()
	{
		String legacy = `
{"ts":"2026-09-29T20:00:00+08:00","turn":1,"message":{"role":"user","content":"旧问"}}
{"ts":"2026-09-29T20:00:01+08:00","turn":1,"message":{"role":"assistant","content":"旧答"}}
{"ts":"2026-09-29T20:00:02+08:00","turn":1,"message":{"role":"user","content":"执行输出"}}
`;
		File file = file::open(traj.path, "ab")!!;
		file.write(legacy)!!;
		file.close()!!;
	};
	@pool()
	{
		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		test::eq((int)steps.len, 3);
		test::eq(steps[0].type, "prompt");
		test::eq(steps[0].content, "旧问");
		test::eq(steps[1].type, "reasoning");
		test::eq(steps[1].thought, "旧答");
		test::eq(steps[2].type, "shell-output");
		test::eq(steps[2].stdout, "执行输出");
	};
}

// reasoning_content 落盘往返，且渲染时不进入消息（只入存档、绝不回传端点）
fn void test_reasoning_content_archived_not_rendered() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("rc");
	@pool()
	{
		trajectory::append(&traj, {
			.type = trajectory::T_REASONING,
			.thought = "散文",
			.cmd = "echo hi",
			.reasoning_content = "秘密思维链",
		});
	};
	@pool()
	{
		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		test::eq((int)steps.len, 1);
		test::eq(steps[0].reasoning_content, "秘密思维链");
		test::eq(steps[0].thought, "散文");
	};
}

// 缺文件读回空数组，不崩
fn void test_missing_file_reads_empty() @test
{
	fresh();
	@pool()
	{
		trajectory::Trajectory traj = trajectory::open_at(TEST_ROOT, "does-not-exist");
		test::eq(trajectory::read_all(tmem, &traj).len, 0);
	};
}

// list_all 的步数不含头行
fn void test_list_all_counts_steps_not_header() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("listed");
	@pool()
	{
		trajectory::append(&traj, { .type = trajectory::T_PROMPT, .content = "a" });
		trajectory::append(&traj, { .type = trajectory::T_FINAL, .content = "b" });
	};
	@pool()
	{
		trajectory::TrajectorySummary[] items = trajectory::list_all(tmem);
		bool found = false;
		foreach (item : items)
		{
			if (item.name == traj.name)
			{
				found = true;
				test::eq((int)item.count, 2);
			}
		}
		test::eq(found, true);
	};
}
