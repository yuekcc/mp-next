module llmcli::test_agent;

import llmcli::agent;

// extract_code 的 code 是 mem 上的堆串，测试里统一释放
fn void release(agent::Extract* ex) @private
{
	if (ex.code.ptr) free(ex.code.ptr);
}

// 标准形态：散文 + 一个 ```bash 代码块
fn void test_extract_first_bash_block() @test
{
	@pool()
	{
		String response = "让我看看状态。\n```bash\nls -la\necho done\n```\n";
		agent::Extract ex = agent::extract_code(response);
		test::eq(ex.has_code, true);
		test::eq(ex.truncated, false);
		test::eq(ex.code, "ls -la\necho done\n");
		release(&ex);
	};
}

// 裸围栏与 ```sh 都算代码块
fn void test_extract_bare_and_sh_fence() @test
{
	@pool()
	{
		agent::Extract bare = agent::extract_code("```\necho hi\n```");
		test::eq(bare.code, "echo hi\n");
		release(&bare);

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