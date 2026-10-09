module llmcli::test_cli;

import std::io;
import llmcli::buf, llmcli::cli;

fn void test_help_wins_over_missing_required_flags() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--help" });
	test::eq(parsed.ctx.help, true);
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
	test::eq(parsed.ctx.model, "m");
	test::eq(parsed.ctx.api_key, "k");
	test::eq(parsed.ctx.input_file, path);
	test::eq(parsed.ctx.user_input, "内容");
	test::eq(parsed.ctx.api_url, cli::DEFAULT_API_URL);

	// system_prompt / user_input 归调用方（mem 堆串）
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
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
	test::eq(parsed.ctx.max_iterations, 3);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);

	// 空格形式
	parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k", "--input-file", path,
	                      "--max-turns", "7" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.max_iterations, 7);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
}

fn void test_max_turns_zero_or_negative_means_unlimited() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       "--input-file", path, "--max-turns", "0" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.max_iterations, 0);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);

	parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k", "--input-file", path,
	                      "--max-turns", "-5" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.max_iterations, 0);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
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
	test::eq(parsed.ctx.max_iterations, 0);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
}

fn void test_list_sessions_skips_required_flags() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--list-sessions" });
	test::eq(parsed.ctx.list_trajectories, true);
	test::eq(parsed.error.len, 0);
}

fn void test_invalid_session_id_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--traj", "../escape" });
	test::@check(parsed.error.contains("--traj"), "应提示 traj id 非法，实际：%s", parsed.error);
}

fn void test_default_system_prompt_is_embedded_and_expanded() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       string::tformat("--input-file=%s", path) });
	test::eq(parsed.error, "");
	test::@check(parsed.ctx.system_prompt.len > 0, "应回填内置默认提示词");
	test::@check(!parsed.ctx.system_prompt.contains("{{"),
	             "占位符应已展开，实际：%s", buf::truncate(parsed.ctx.system_prompt, 120));

	// system_prompt / user_input 都是 mem 堆串
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
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
	test::@check(parsed.ctx.system_prompt.starts_with("自定义 "),
	             "应使用指定的提示词，实际：%s", parsed.ctx.system_prompt);
	test::@check(!parsed.ctx.system_prompt.contains("{{"),
	             "占位符应已展开，实际：%s", parsed.ctx.system_prompt);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
}

// ---- T7.3 纯解析路径 ------------------------------------------------------
// parse 只吃 argv：不读 stdin、不读任何文件。下面这些用例一个字节的 I/O 都不需要
// （同类场景走 resolve 就得先准备文件、先喂 stdin）。

fn void test_parse_flags_without_io() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model=m", "--api-key=k",
	                                     "--traj=work", "--max-iterations=3",
	                                     "--quiet", "--debug", "--no-color", "问题" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.model, "m");
	test::eq(parsed.ctx.api_key, "k");
	test::eq(parsed.ctx.traj_id, "work");
	test::eq(parsed.ctx.max_iterations, 3);
	test::eq(parsed.ctx.prompt, "问题");
	test::eq(parsed.ctx.quiet, true);
	test::eq(parsed.ctx.debug, true);
	test::eq(parsed.ctx.no_color, true);
	test::eq(parsed.ctx.api_url, cli::DEFAULT_API_URL);
	test::eq(parsed.ctx.user_input, "");
}

fn void test_parse_unknown_flag_is_usage_error() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model=m", "--api-key=k", "--url=x" });
	test::@check(parsed.error.contains("未知参数"), "应提示未知参数，实际：%s", parsed.error);
	test::eq(parsed.ctx.user_input, "");
}

fn void test_parse_leaves_input_reading_to_resolve() @test
{
	// 位置参数原样留在 prompt 里，user_input 是 resolve 才填的
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model=m", "--api-key=k", "问题" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.prompt, "问题");
	test::eq(parsed.ctx.user_input, "");
	test::eq(parsed.ctx.system_prompt, "");
}

// --help 必须在碰 stdin 之前结束，否则 `llmcli --help` 在终端里会挂住
fn void test_parse_help_returns_immediately() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--help" });
	test::eq(parsed.ctx.help, true);
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.user_input, "");
	test::eq(parsed.ctx.system_prompt, "");
}

// -h 不以 -- 开头，会被位置参数分支当 prompt 吃掉——必须单独认（HELP 里写了 `-h, --help`）
fn void test_parse_dash_h_is_help() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "-h" });
	test::eq(parsed.ctx.help, true);
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.prompt, "");
	test::eq(parsed.ctx.user_input, "");
}

// --list-sessions 同理，且不要求 --model / --api-key（与 001 的 AC 一致）
fn void test_parse_list_sessions_returns_immediately() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--list-sessions" });
	test::eq(parsed.ctx.list_trajectories, true);
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.user_input, "");
}

// ---- --print-system-prompt -------------------------------------------------

// 动作开关：纯解析即完成，不要求 --model / --api-key，也不读输入
fn void test_parse_print_system_prompt_returns_immediately() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--print-system-prompt" });
	test::eq(parsed.ctx.print_system_prompt, true);
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.user_input, "");
	test::eq(parsed.ctx.system_prompt, "");
}

// 与其它动作开关同用属用法错误
fn void test_parse_print_system_prompt_conflicts_with_actions() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--print-system-prompt", "--list-skills" });
	test::@check(parsed.error.contains("--print-system-prompt"),
	             "应提示与动作开关冲突，实际：%s", parsed.error);

	parsed = cli::parse({ "llmcli", "--print-system-prompt", "--list-sessions" });
	test::@check(parsed.error.len != 0, "与 --list-sessions 同用应报错，实际：%s", parsed.error);
}

// 系统提示词来源互斥对 print 模式同样成立（不能在动作短路处漏检）
fn void test_parse_print_system_prompt_still_checks_source_conflict() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--print-system-prompt",
	                                     "--system-prompt", "a", "--system-prompt-file", "b" });
	test::@check(parsed.error.contains("互斥"), "print 模式也要查来源互斥，实际：%s", parsed.error);
}

// resolve 在 print 模式下补齐系统提示词，但不要求 api-key / model
fn void test_resolve_print_system_prompt_needs_no_credentials() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--print-system-prompt" });
	test::eq(parsed.error, "");
	test::@check(parsed.ctx.system_prompt.len > 0, "应装配出系统提示词");
	test::@check(!parsed.ctx.system_prompt.contains("{{"), "占位符应已展开");
	test::eq(parsed.ctx.user_input, "");
	free(parsed.ctx.system_prompt.ptr);
}

// print 模式用的是显式 --system-prompt（而不是内置默认），保证打印的就是实际会发的内容
fn void test_resolve_print_system_prompt_uses_explicit_source() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--print-system-prompt",
	                                       "--system-prompt", "自定义 {{os}} 提示" });
	test::eq(parsed.error, "");
	test::@check(parsed.ctx.system_prompt.starts_with("自定义 "), "应使用指定提示词，实际：%s",
	             parsed.ctx.system_prompt);
	test::@check(!parsed.ctx.system_prompt.contains("{{"), "占位符应已展开");
	free(parsed.ctx.system_prompt.ptr);
}

// 用法错误同样不读输入：--input-file 指向不存在的文件也不该被打开
fn void test_parse_usage_error_needs_no_input() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model", "m", "--api-key", "k",
	                                     "--input-file", "build/no-such-file.txt", "位置参数" });
	test::@check(parsed.error.contains("三选一"), "应在读输入前先报冲突，实际：%s", parsed.error);
	test::eq(parsed.ctx.user_input, "");

	parsed = cli::parse({ "llmcli", "--model", "m", "--api-key", "k",
	                    "--system-prompt", "a", "--system-prompt-file", "b" });
	test::@check(parsed.error.contains("互斥"), "应在读输入前先报互斥，实际：%s", parsed.error);

	parsed = cli::parse({ "llmcli", "--api-key", "k" });
	test::@check(parsed.error.contains("缺少输入"),
	             "缺输入也应在纯解析里报错，实际：%s", parsed.error);
}

// session-id 会直接当文件名用，校验必须在读任何输入之前——parse 里就挡住。
// 这里给一个不存在的 --input-file：真去读会报「无法读取」，报的是 session-id 才说明校验在前。
fn void test_parse_rejects_invalid_session_id_without_reading_input() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--model=m", "--api-key=k",
	                                     "--traj=../escape",
	                                     "--input-file", "build/no-such-file.txt" });
	test::@check(parsed.error.contains("--traj"), "应提示 traj id 非法，实际：%s", parsed.error);
	test::eq(parsed.ctx.user_input, "");
}

// resolve 在 parse 之上只多做三件事：读 --system-prompt-file、按三选一取 user_input、展开默认提示词。
fn void test_resolve_fills_what_parse_leaves_empty() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	String[] args = { "llmcli", "--model=m", "--api-key=k",
	                  string::tformat("--input-file=%s", path) };
	cli::ParseResult parsed = cli::parse(args);
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.user_input, "");
	test::eq(parsed.ctx.system_prompt, "");

	cli::ParseResult resolved = cli::resolve(args);
	test::eq(resolved.error, "");
	test::eq(resolved.ctx.model, parsed.ctx.model);
	test::eq(resolved.ctx.input_file, parsed.ctx.input_file);
	test::eq(resolved.ctx.api_url, parsed.ctx.api_url);
	test::eq(resolved.ctx.user_input, "内容");
	test::@check(resolved.ctx.system_prompt.len > 0, "应回填内置默认提示词");
	free(resolved.ctx.system_prompt.ptr);
	if (resolved.ctx.user_input.ptr) free(resolved.ctx.user_input.ptr);
}

// parse 出来的 Ctx 就是 resolve 的起点：parse 已经定下的字段 resolve 一个都不改
fn void test_resolve_keeps_every_parsed_field() @test
{
	String[] args = { "llmcli", "--model=m", "--api-key=k", "--api-url=http://x/v1",
	                  "--config-dir=build/cfg", "--traj=s1", "--max-iterations=4",
	                  "--quiet", "--no-color", "问题" };
	cli::ParseResult parsed = cli::parse(args);
	test::eq(parsed.error, "");

	cli::ParseResult resolved = cli::resolve(args);
	test::eq(resolved.error, "");
	test::eq(resolved.ctx.model, parsed.ctx.model);
	test::eq(resolved.ctx.api_key, parsed.ctx.api_key);
	test::eq(resolved.ctx.api_url, parsed.ctx.api_url);
	test::eq(resolved.ctx.config_dir, parsed.ctx.config_dir);
	test::eq(resolved.ctx.traj_id, parsed.ctx.traj_id);
	test::eq(resolved.ctx.max_iterations, parsed.ctx.max_iterations);
	test::eq(resolved.ctx.quiet, parsed.ctx.quiet);
	test::eq(resolved.ctx.no_color, parsed.ctx.no_color);
	test::eq(resolved.ctx.debug, parsed.ctx.debug);
	test::eq(resolved.ctx.list_trajectories, parsed.ctx.list_trajectories);
	test::eq(resolved.ctx.help, parsed.ctx.help);

	// 位置参数路径：prompt 原样搬运成 user_input（同一个切片，不复制）
	test::eq(resolved.ctx.prompt, "问题");
	test::eq(resolved.ctx.user_input, "问题");
	free(resolved.ctx.system_prompt.ptr);
}
