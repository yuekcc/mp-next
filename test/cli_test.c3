module llmcli::test_cli;

import std::io;
import llmcli::cli;

fn void test_help_wins_over_missing_required_flags() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--help" });
	test::eq(parsed.opts.help, true);
	test::eq(parsed.error.len, 0);
}

fn void test_missing_api_key_is_usage_error() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model", "m", "--input-file", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("--api-key"), "应提示缺少 --api-key，实际：%s", parsed.error);
}

fn void test_missing_model_is_usage_error() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--api-key", "k", "--input-file", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("--model"), "应提示缺少 --model，实际：%s", parsed.error);
}

fn void test_unknown_flag_is_usage_error() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--nope" });
	test::@check(parsed.error.contains("未知参数"), "应提示未知参数，实际：%s", parsed.error);
}

fn void test_flag_without_value_is_usage_error() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model" });
	test::@check(parsed.error.contains("缺少参数值"), "应提示缺少参数值，实际：%s", parsed.error);
}

fn void test_flag_equals_form() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::parse({ "llmcli", "--model=m", "--api-key=k",
	                                       string::tformat("--input-file=%s", path) });
	test::eq(parsed.error, "");
	test::eq(parsed.opts.model, "m");
	test::eq(parsed.opts.api_key, "k");
	test::eq(parsed.opts.input_file, path);
	test::eq(parsed.opts.user_input, "内容");
	test::eq(parsed.opts.api_url, cli::DEFAULT_API_URL);

	// user_input 归调用方（mem 堆串）
	if (parsed.opts.user_input.ptr) free(parsed.opts.user_input.ptr);
}

fn void test_prompt_and_input_file_conflict() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--input-file", "build/e2e/in.txt", "位置参数" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("三选一"), "应提示输入来源冲突，实际：%s", parsed.error);
}

fn void test_system_prompt_and_file_conflict() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--system-prompt", "a", "--system-prompt-file", "b",
	                                       "--input-file", "build/e2e/in.txt" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("互斥"), "应提示互斥，实际：%s", parsed.error);
}

fn void test_two_positionals_are_rejected() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model", "m", "--api-key", "k", "a", "b" });
	test::@check(parsed.error.contains("位置参数"), "应提示位置参数过多，实际：%s", parsed.error);
}

fn void test_input_file_missing_is_usage_error() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--input-file", "build/no-such-file.txt" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("build/no-such-file.txt"),
	             "应指明路径，实际：%s", parsed.error);
}

fn void test_list_sessions_skips_required_flags() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--list-sessions" });
	test::eq(parsed.opts.list_sessions, true);
	test::eq(parsed.error.len, 0);
}
