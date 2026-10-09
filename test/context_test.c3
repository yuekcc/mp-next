module llmcli::test_context;

import std::io, std::io::path;
import llmcli::chat, llmcli::context, llmcli::trajectory;

const String TEST_ROOT = "build/test_ctx";

fn void fresh() @private
{
	(void)path::rmtree((Path)TEST_ROOT);
	trajectory::set_base_dir(TEST_ROOT);
}

fn void put(trajectory::Trajectory* traj, trajectory::Step step) @private
{
	trajectory::append(traj, step);
}

// prompt -> user，reasoning -> assistant（还原 bash 围栏），shell-output -> user，
// final -> assistant；shellm-run 永不进上下文
fn void test_default_role_mapping() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("roles");
	@pool()
	{
		put(&traj, { .type = trajectory::T_SHELLM_RUN, .command = "task" });
		put(&traj, { .type = trajectory::T_PROMPT, .content = "任务" });
		put(&traj, { .type = trajectory::T_REASONING, .thought = "先看", .cmd = "ls" });
		put(&traj, { .type = trajectory::T_SHELL_OUTPUT, .stdout = "out\n", .exit = 0 });
		put(&traj, { .type = trajectory::T_FINAL, .content = "答案" });
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		Message[] messages = context::render(tmem, &traj, &policy);
		test::eq((int)messages.len, 4);
		test::eq(messages[0].role, "user");
		test::eq(messages[0].content, "任务");
		test::eq(messages[1].role, "assistant");
		test::@check(messages[1].content.contains("```bash"), "reasoning 应还原 bash 围栏：%s", messages[1].content);
		test::@check(messages[1].content.contains("ls"), "reasoning 应含代码：%s", messages[1].content);
		test::eq(messages[2].role, "user");
		test::eq(messages[2].content, "out\n");
		test::eq(messages[3].role, "assistant");
		test::eq(messages[3].content, "答案");
	};
}

// head/tail 窗口：保留首 1 步 + 末 N 步
fn void test_head_tail_window() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("window");
	@pool()
	{
		put(&traj, { .type = trajectory::T_PROMPT, .content = "开头" });
		for (int i = 0; i < 20; i++)
		{
			put(&traj, { .type = trajectory::T_SHELL_OUTPUT, .stdout = "row", .exit = 0 });
		}
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		policy.tail = 3;
		Message[] messages = context::render(tmem, &traj, &policy);
		test::eq((int)messages.len, 4); // head 1 + tail 3
		test::eq(messages[0].content, "开头");
	};
}

// pins 强制包含窗口外的步骤
fn void test_pins_force_include() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("pins");
	String mid_id = "";
	@pool()
	{
		put(&traj, { .type = trajectory::T_PROMPT, .content = "开头" });
		mid_id = trajectory::append(&traj, { .type = trajectory::T_FINAL, .content = "中间" });
		for (int i = 0; i < 20; i++)
		{
			put(&traj, { .type = trajectory::T_SHELL_OUTPUT, .stdout = "row", .exit = 0 });
		}
		context::RenderPolicy policy = context::default_policy();
		policy.tail = 2;
		policy.pins = { mid_id };
		Message[] messages = context::render(tmem, &traj, &policy);
		bool has_mid = false;
		foreach (m : messages)
		{
			if (m.content == "中间") has_mid = true;
		}
		test::eq(has_mid, true);
	};
}

// run 作用域：只保留该 run 的步骤
fn void test_run_scope() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("scope");
	@pool()
	{
		put(&traj, { .type = trajectory::T_PROMPT, .content = "runA", .run_id = "aaaa" });
		put(&traj, { .type = trajectory::T_FINAL, .content = "runB", .run_id = "bbbb" });
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		policy.run = "bbbb";
		Message[] messages = context::render(tmem, &traj, &policy);
		test::eq((int)messages.len, 1);
		test::eq(messages[0].content, "runB");
	};
}

// 普通字段超上限：中间截断并打桩，保留首尾
fn void test_truncation_stub() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("trunc");
	@pool()
	{
		put(&traj, { .type = trajectory::T_PROMPT, .content = "任务" });
		DString big = dstring::new(tmem);
		for (int i = 0; i < 300; i++) big.append("abcdefghij"); // 3000 字节
		put(&traj, { .type = trajectory::T_SHELL_OUTPUT, .stdout = big.str_view(), .exit = 0 });
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		policy.prompt_limit = 512;   // 旧波段（prompt 步）用这个
		policy.block_limit = 512;
		Message[] messages = context::render(tmem, &traj, &policy);
		String out = messages[1].content;
		test::@check(out.contains("truncated"), "应打截断桩：%s", out);
		test::@check(out.contains("3000 bytes total"), "桩里应记总字节数：%s", out);
		test::@check(out.starts_with("abcdefghij"), "应保留首部：%s", out[:40]);
		test::@check(out.ends_with("abcdefghij"), "应保留尾部：%s", out[out.len - 40..]);
	};
}

// full_types（prompt）永不截断，即便超过 limit
fn void test_full_types_never_truncated() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("full");
	@pool()
	{
		DString big = dstring::new(tmem);
		for (int i = 0; i < 500; i++) big.append("0123456789"); // 5000 字节
		put(&traj, { .type = trajectory::T_PROMPT, .content = big.str_view() });
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		policy.prompt_limit = 128;
		policy.block_limit = 128;
		Message[] messages = context::render(tmem, &traj, &policy);
		test::eq((int)messages[0].content.len, 5000);
	};
}

// exclude_types 永不进上下文
fn void test_exclude_types() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("excl");
	@pool()
	{
		put(&traj, { .type = trajectory::T_RUN_SUMMARY, .content = "记账" });
		put(&traj, { .type = trajectory::T_PROMPT, .content = "任务" });
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		Message[] messages = context::render(tmem, &traj, &policy);
		test::eq((int)messages.len, 1);
		test::eq(messages[0].content, "任务");
	};
}

// max_bytes 预算：超了收紧截断，结果不超预算
fn void test_max_bytes_budget() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("budget");
	@pool()
	{
		put(&traj, { .type = trajectory::T_PROMPT, .content = "任务" });
		DString big = dstring::new(tmem);
		for (int i = 0; i < 200; i++) big.append("abcdefghij"); // 2000 字节
		put(&traj, { .type = trajectory::T_SHELL_OUTPUT, .stdout = big.str_view(), .exit = 0 });
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		policy.max_bytes = 400;  // prompt 不截断（3 字节），shell-output 必须被压到预算内
		Message[] messages = context::render(tmem, &traj, &policy);
		usz total = 0;
		foreach (m : messages) total += m.content.len;
		test::@check(total <= 400 + 64, "渲染总量应压进预算，实际 %d", total);
	};
}

// reasoning_content 只入存档、绝不回传端点：渲染出的 assistant 消息里不能出现它
fn void test_reasoning_content_not_rendered() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("rc");
	@pool()
	{
		put(&traj, { .type = trajectory::T_REASONING, .thought = "散文", .reasoning_content = "秘密思维链" });
	};
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		Message[] messages = context::render(tmem, &traj, &policy);
		test::eq((int)messages.len, 1);
		test::@check(!messages[0].content.contains("秘密思维链"),
		             "reasoning_content 不应进上下文：%s", messages[0].content);
	};
}

// 空轨迹 -> 空 messages
fn void test_empty_trajectory() @test
{
	fresh();
	trajectory::Trajectory traj = trajectory::open_new("empty");
	@pool()
	{
		context::RenderPolicy policy = context::default_policy();
		Message[] messages = context::render(tmem, &traj, &policy);
		test::eq((int)messages.len, 0);
	};
}
