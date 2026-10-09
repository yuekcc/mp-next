module llmcli::test_agent;

import llmcli::agent;

// extract_code / extract_reasoning 的 code 是 mem 上的堆串，测试里统一释放
fn void release(agent::Extract* ex) @private
{
	if (ex.code.ptr) free(ex.code.ptr);
}

// 标准形态：散文 + 一个 ```bash 代码块
fn void test_extract_first_bash_block() @test
{
	@pool()
	{
		String response = "让我看看状态。\n```bash\nls -la\n```\n";
		agent::Extract ex = agent::extract_code(response);
		test::eq(ex.has_code, true);
		test::eq(ex.truncated, false);
		test::eq(ex.code, "ls -la\n");
		release(&ex);
	};
}

// 裸围栏、```bash 与 ```sh 都算代码块
fn void test_extract_bare_and_bash_fences() @test
{
	@pool()
	{
		agent::Extract bare = agent::extract_code("```\necho hi\n```");
		test::eq(bare.code, "echo hi\n");
		release(&bare);

		agent::Extract bash = agent::extract_code("```bash\necho hi\n```");
		test::eq(bash.code, "echo hi\n");
		release(&bash);

		agent::Extract sh = agent::extract_code("```sh\necho hi\n```");
		test::eq(sh.code, "echo hi\n");
		release(&sh);
	};
}

// 只执行第一个代码块，之后再有围栏只置 truncated
fn void test_extract_only_first_block_and_flags_truncation() @test
{
	@pool()
	{
		String response = "```bash\necho one\n```\n说明\n```bash\necho two\n```\n";
		agent::Extract ex = agent::extract_code(response);
		test::eq(ex.has_code, true);
		test::eq(ex.code, "echo one\n");
		test::eq(ex.truncated, true);
		release(&ex);
	};
}

// 没有围栏：has_code=false，整段回复由调用方当最终答案（单轮问答走这条）
fn void test_extract_no_block() @test
{
	@pool()
	{
		agent::Extract ex = agent::extract_code("这就是答案，没有代码。");
		test::eq(ex.has_code, false);
		test::eq(ex.code, "");
		test::eq(ex.truncated, false);
	};
}

// 空代码块：has_code=true 但 code 为空，不能与"没有块"混为一谈
fn void test_extract_empty_block() @test
{
	@pool()
	{
		agent::Extract ex = agent::extract_code("```bash\n```");
		test::eq(ex.has_code, true);
		test::eq(ex.code, "");
		release(&ex);
	};
}

// 围栏可带缩进；末尾空行会被去掉
fn void test_extract_indented_fence_and_trims_trailing_blank() @test
{
	@pool()
	{
		agent::Extract ex = agent::extract_code("  ```bash\n  echo hi\n\n\n  ```");
		test::eq(ex.has_code, true);
		test::eq(ex.code, "  echo hi\n");
		release(&ex);
	};
}

// 标记围栏缀在散文行末（模型偶尔写成"……这样。```bash"）也要认
fn void test_extract_fence_appended_to_prose() @test
{
	@pool()
	{
		agent::Extract ex = agent::extract_code("先看看。\n这样。```bash\necho hi\n```\n");
		test::eq(ex.has_code, true);
		test::eq(ex.code, "echo hi\n");
		release(&ex);
	};
}

// heredoc 内的 ``` 行不提前闭块（doc 5.2）
fn void test_extract_heredoc_aware() @test
{
	@pool()
	{
		String response = "```bash\ncat <<EOF\n```\nthis is inside heredoc\nEOF\necho done\n```\n";
		agent::Extract ex = agent::extract_code(response);
		test::eq(ex.has_code, true);
		test::@check(ex.code.contains("this is inside heredoc"),
		             "heredoc 内容应完整保留，实际：%s", ex.code);
		test::@check(ex.code.contains("echo done"),
		             "闭围栏后的代码也应保留，实际：%s", ex.code);
		release(&ex);
	};
}

// extract_reasoning 取第一个代码块之前的散文
fn void test_extract_reasoning() @test
{
	@pool()
	{
		test::eq(agent::extract_reasoning("先看看。\n```bash\nls\n```"), "先看看。");
		test::eq(agent::extract_reasoning("没有代码块"), "没有代码块");
	};
}
