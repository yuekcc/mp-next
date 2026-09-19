module llmcli::test_cli;

import std::io;
import llmcli::buf, llmcli::cli;

fn void test_help_wins_over_missing_required_flags() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--help" });
	test::eq(parsed.opts.help, true);
	test::eq(parsed.error.len, 0);
}

fn void test_missing_api_key_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model", "m", "--input-file", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("--api-key"), "应提示缺少 --api-key，实际：%s", parsed.error);
}

fn void test_missing_model_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--api-key", "k", "--input-file", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("--model"), "应提示缺少 --model，实际：%s", parsed.error);
}

fn void test_unknown_flag_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--nope" });
	test::@check(parsed.error.contains("未知参数"), "应提示未知参数，实际：%s", parsed.error);
}

fn void test_flag_without_value_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model" });
	test::@check(parsed.error.contains("缺少参数值"), "应提示缺少参数值，实际：%s", parsed.error);
}

fn void test_flag_equals_form() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       string::tformat("--input-file=%s", path) });
	test::eq(parsed.error, "");
	test::eq(parsed.opts.model, "m");
	test::eq(parsed.opts.api_key, "k");
	test::eq(parsed.opts.input_file, path);
	test::eq(parsed.opts.user_input, "内容");
	test::eq(parsed.opts.api_url, cli::DEFAULT_API_URL);

	// system_prompt / user_input 归调用方（mem 堆串）
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);
}

fn void test_prompt_and_input_file_conflict() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--input-file", "build/e2e/in.txt", "位置参数" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("三选一"), "应提示输入来源冲突，实际：%s", parsed.error);
}

fn void test_system_prompt_and_file_conflict() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--system-prompt", "a", "--system-prompt-file", "b",
	                                       "--input-file", "build/e2e/in.txt" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("互斥"), "应提示互斥，实际：%s", parsed.error);
}

fn void test_two_positionals_are_rejected() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model", "m", "--api-key", "k", "a", "b" });
	test::@check(parsed.error.contains("位置参数"), "应提示位置参数过多，实际：%s", parsed.error);
}

fn void test_input_file_missing_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--input-file", "build/no-such-file.txt" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("build/no-such-file.txt"),
	             "应指明路径，实际：%s", parsed.error);
}

fn void test_max_turns_parsing() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       string::tformat("--input-file=%s", path), "--max-turns=3" });
	test::eq(parsed.error, "");
	test::eq(parsed.opts.max_turns, 3);
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);

	// 空格形式
	parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k", "--input-file", path,
	                      "--max-turns", "7" });
	test::eq(parsed.error, "");
	test::eq(parsed.opts.max_turns, 7);
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);
}

fn void test_max_turns_zero_or_negative_means_unlimited() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       "--input-file", path, "--max-turns", "0" });
	test::eq(parsed.error, "");
	test::eq(parsed.opts.max_turns, 0);
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);

	parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k", "--input-file", path,
	                      "--max-turns", "-5" });
	test::eq(parsed.error, "");
	test::eq(parsed.opts.max_turns, 0);
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);
}

fn void test_max_turns_non_integer_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--max-turns", "abc", "--input-file", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("--max-turns 需要整数"),
	             "应提示需要整数，实际：%s", parsed.error);
}

fn void test_max_turns_defaults_to_unlimited() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       "--input-file", path });
	test::eq(parsed.opts.max_turns, 0);
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);
}

fn void test_list_sessions_skips_required_flags() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--list-sessions" });
	test::eq(parsed.opts.list_sessions, true);
	test::eq(parsed.error.len, 0);
}

fn void test_invalid_session_id_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--session-id", "../escape" });
	test::@check(parsed.error.contains("--session-id"), "应提示 session-id 非法，实际：%s", parsed.error);
}

fn void test_default_system_prompt_is_embedded_and_expanded() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       string::tformat("--input-file=%s", path) });
	test::eq(parsed.error, "");
	test::@check(parsed.opts.system_prompt.len > 0, "应回填内置默认提示词");
	test::@check(!parsed.opts.system_prompt.contains("{{"),
	             "占位符应已展开，实际：%s", buf::truncate(parsed.opts.system_prompt, 120));

	// system_prompt / user_input 都是 mem 堆串
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);
}

// 占位符替换是字节级操作，验证多字节内容（中文/emoji）不被破坏
fn void test_placeholder_expansion_preserves_utf8() @test
{
	String out = cli::expand_prompt_placeholders("中文{{os}}🙂{{cwd}}—结尾");
	test::@check(out.starts_with("中文"), "开头中文应保留，实际：%s", out);
	test::@check(out.ends_with("—结尾"), "结尾中文应保留，实际：%s", out);
	test::@check(!out.contains("{{"), "占位符应已替换，实际：%s", out);
	free(out.ptr);
}

fn void test_explicit_system_prompt_wins_and_expands() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       "--system-prompt", "自定义 {{os}} 提示词",
	                                       string::tformat("--input-file=%s", path) });
	test::eq(parsed.error, "");
	test::@check(parsed.opts.system_prompt.starts_with("自定义 "),
	             "应使用指定的提示词，实际：%s", parsed.opts.system_prompt);
	test::@check(!parsed.opts.system_prompt.contains("{{"),
	             "占位符应已展开，实际：%s", parsed.opts.system_prompt);
	free(parsed.opts.system_prompt.ptr);
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);
}
