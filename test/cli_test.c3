module llmcli::test_cli;

import std::io;
import std::io::path;
import llmcli::buf, llmcli::cli, llmcli::trajectory;

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

fn void test_max_iterations_parsing() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       string::tformat("--input-file=%s", path), "--max-iterations=3" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.max_iterations, 3);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);

	// 空格形式
	parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k", "--input-file", path,
	                      "--max-iterations", "7" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.max_iterations, 7);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
}

fn void test_max_iterations_zero_or_negative_means_unlimited() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");

	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       "--input-file", path, "--max-iterations", "0" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.max_iterations, 0);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);

	parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k", "--input-file", path,
	                      "--max-iterations", "-5" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.max_iterations, 0);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
}

fn void test_max_iterations_non_integer_is_usage_error() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model", "m", "--api-key", "k",
	                                       "--max-iterations", "abc", "--input-file", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("--max-iterations 需要整数"),
	             "应提示需要整数，实际：%s", parsed.error);
}

fn void test_max_iterations_defaults_to_unlimited() @test
{
	String path = "build/test_cli_input.txt";
	(void)file::save(path, "内容");
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--model=m", "--api-key=k",
	                                       "--input-file", path });
	test::eq(parsed.ctx.max_iterations, 0);
	free(parsed.ctx.system_prompt.ptr);
	if (parsed.ctx.user_input.ptr) free(parsed.ctx.user_input.ptr);
}

fn void test_invalid_traj_id_is_usage_error() @test
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

// --help 是最高优先级的动作：与 --print-system-prompt 同用时 --help 胜出（不报错）
fn void test_parse_help_wins_over_print_system_prompt() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "--print-system-prompt", "--help" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.help, true);
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

// traj 会直接当目录名用，校验必须在读任何输入之前——parse 里就挡住。
// 这里给一个不存在的 --input-file：真去读会报「无法读取」，报的是 traj id 才说明校验在前。
fn void test_parse_rejects_invalid_traj_id_without_reading_input() @test
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
	                  "--traj=s1", "--max-iterations=4",
	                  "--quiet", "--no-color", "问题" };
	cli::ParseResult parsed = cli::parse(args);
	test::eq(parsed.error, "");

	cli::ParseResult resolved = cli::resolve(args);
	test::eq(resolved.error, "");
	test::eq(resolved.ctx.model, parsed.ctx.model);
	test::eq(resolved.ctx.api_key, parsed.ctx.api_key);
	test::eq(resolved.ctx.api_url, parsed.ctx.api_url);
	test::eq(resolved.ctx.traj_id, parsed.ctx.traj_id);
	test::eq(resolved.ctx.max_iterations, parsed.ctx.max_iterations);
	test::eq(resolved.ctx.quiet, parsed.ctx.quiet);
	test::eq(resolved.ctx.no_color, parsed.ctx.no_color);
	test::eq(resolved.ctx.debug, parsed.ctx.debug);
	test::eq(resolved.ctx.print_system_prompt, parsed.ctx.print_system_prompt);
	test::eq(resolved.ctx.help, parsed.ctx.help);

	// 位置参数路径：prompt 原样搬运成 user_input（同一个切片，不复制）
	test::eq(resolved.ctx.prompt, "问题");
	test::eq(resolved.ctx.user_input, "问题");
	free(resolved.ctx.system_prompt.ptr);
}

// ---- -p / --prompt 显式 prompt ----

fn void test_parse_prompt_flag() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "-p", "任务", "--model=m", "--api-key=k" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.prompt, "任务");

	parsed = cli::parse({ "llmcli", "--prompt=另一个任务", "--model=m", "--api-key=k" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.prompt, "另一个任务");
}

// -p 与位置参数互斥
fn void test_prompt_flag_and_positional_conflict() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "-p", "a", "--model=m", "--api-key=k", "b" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("只接受一个"), "应提示 prompt 重复，实际：%s", parsed.error);
}

// -p 的值可以是子命令名（不会被派发，因为 -p 落在 args[1]，命令名判定只看 args[1]）
fn void test_prompt_flag_value_may_equal_subcommand() @test
{
	cli::ParseResult parsed = cli::parse({ "llmcli", "-p", "traj", "--model=m", "--api-key=k" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.prompt, "traj");
}

// resolve 从 -p 取 user_input
fn void test_resolve_prompt_flag() @test
{
	@pool()
	{
		cli::ParseResult parsed = cli::resolve({ "llmcli", "-p", "显式任务", "--model=m", "--api-key=k" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.user_input, "显式任务");
		free(parsed.ctx.system_prompt.ptr);
	};
}

// ---- configure_trajectory：子命令共用的目录 flag 扫描（唯一一处） ----

// 两个形态（空格 / 等号）都认，并从返回的子命令参数里摘掉 flag 及值
fn void test_configure_trajectory_strips_flags() @test
{
	@pool()
	{
		cli::TrajArgs cfg = cli::configure_trajectory({ "list", "--traj-dir", "build/x", "--children",
		                                              "--config-dir", "build/test_cfg_none" });
		test::eq(cfg.error, "");
		test::eq((int)cfg.rest.len, 2);
		test::eq(cfg.rest[0], "list");
		test::eq(cfg.rest[1], "--children");
	};
	@pool()
	{
		cli::TrajArgs cfg = cli::configure_trajectory({ "show", "abc", "--traj-dir=build/y",
		                                              "--config-dir=build/test_cfg_none" });
		test::eq(cfg.error, "");
		test::eq((int)cfg.rest.len, 2);
		test::eq(cfg.rest[0], "show");
		test::eq(cfg.rest[1], "abc");
	};
}

// 没有目录 flag 时原样返回（--config-dir 指向不存在的目录 → 配置静默跳过）
fn void test_configure_trajectory_passthrough() @test
{
	@pool()
	{
		cli::TrajArgs cfg = cli::configure_trajectory({ "search", "abc", "needle",
		                                               "--config-dir", "build/test_cfg_none" });
		test::eq(cfg.error, "");
		test::eq((int)cfg.rest.len, 3);
	};
}

// --config-dir 也认，且不影响其余参数
fn void test_configure_trajectory_config_dir() @test
{
	@pool()
	{
		cli::TrajArgs cfg = cli::configure_trajectory({ "--config-dir", "build/cfg", "list" });
		test::eq(cfg.error, "");
		test::eq((int)cfg.rest.len, 1);
		test::eq(cfg.rest[0], "list");
	};
}

// ---- llmcli.json 配置（单测接缝：resolve + 临时 llmcli.json） ----
// 好测试的标准：只断言 resolve 返回的 Ctx 字段与 error，不碰 presence/解析中间结构。

const String CFG_DIR = "build/test_cfg";

fn void write_config(String json) @private
{
	(void)path::mkdir((Path)CFG_DIR, true);
	(void)file::save(CFG_DIR +++ "/llmcli.json", json);
}

// 释放 apply_config 落在 mem 上的 --var 结果（数组 + 每个 "NAME=VALUE" 串）。
fn void free_vars(String[] vars) @private
{
	foreach (v : vars)
	{
		if (v.ptr) free(v.ptr);
	}
	if (vars.ptr) free(vars.ptr);
}

// 配置回填常用偏好：命令行只给本次输入即可跑
fn void test_config_backfills_credentials_and_paths() @test
{
	@pool()
	{
		write_config(`{"model":"cfg-model","api_key":"cfg-key","api_url":"http://cfg/v1",
		               "traj_dir":"build/cfg-traj","workdir":"build/cfg-wd"}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.model, "cfg-model");
		test::eq(parsed.ctx.api_key, "cfg-key");
		test::eq(parsed.ctx.api_url, "http://cfg/v1");
		test::eq(parsed.ctx.traj_dir, "build/cfg-traj");
		test::eq(parsed.ctx.workdir, "build/cfg-wd");
		free(parsed.ctx.system_prompt.ptr);
	};
}

// flag 覆盖配置里的同名值；没给的键仍来自配置
fn void test_flag_overrides_config() @test
{
	@pool()
	{
		write_config(`{"model":"cfg","api_key":"cfg-key","api_url":"http://cfg/v1","max_iterations":9}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR,
		                                       "--model", "cli", "--api-url", "http://cli/v1",
		                                       "--max-iterations", "3", "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.model, "cli");
		test::eq(parsed.ctx.api_url, "http://cli/v1");
		test::eq(parsed.ctx.max_iterations, 3);
		test::eq(parsed.ctx.api_key, "cfg-key");
		free(parsed.ctx.system_prompt.ptr);
	};
}

// 16 个键：配置全量回填
fn void test_config_backfills_all_keys() @test
{
	@pool()
	{
		write_config(`{"api_key":"cfg-key","api_url":"http://cfg/v1","model":"cfg-m",
		               "traj_dir":"build/cfg-traj","workdir":"build/cfg-wd",
		               "system_prompt":"配置提示","max_iterations":7,"context_scope":"run",
		               "max_bytes":2048,"inactivity_timeout":11,"max_output_size":4096,
		               "max_exec_time":22,"var":{"A":"1"},"debug":true,"no_color":true}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.api_key, "cfg-key");
		test::eq(parsed.ctx.api_url, "http://cfg/v1");
		test::eq(parsed.ctx.model, "cfg-m");
		test::eq(parsed.ctx.traj_dir, "build/cfg-traj");
		test::eq(parsed.ctx.workdir, "build/cfg-wd");
		test::eq(parsed.ctx.max_iterations, 7);
		test::eq(parsed.ctx.context_scope, "run");
		test::eq(parsed.ctx.max_bytes, (usz)2048);
		test::eq(parsed.ctx.inactivity_timeout, 11);
		test::eq(parsed.ctx.max_output_size, (usz)4096);
		test::eq(parsed.ctx.max_exec_time, 22);
		test::eq(parsed.ctx.debug, true);
		test::eq(parsed.ctx.no_color, true);
		test::eq((int)parsed.ctx.vars.len, 1);
		test::@check(parsed.ctx.system_prompt.starts_with("配置提示"), "实际：%s",
		             buf::truncate(parsed.ctx.system_prompt, 40));
		free_vars(parsed.ctx.vars);
		free(parsed.ctx.system_prompt.ptr);
	};
}

// 16 个键：flag 全量覆盖配置
fn void test_flag_overrides_all_config_keys() @test
{
	@pool()
	{
		write_config(`{"api_key":"cfg-key","api_url":"http://cfg/v1","model":"cfg-m",
		               "traj_dir":"build/cfg-traj","workdir":"build/cfg-wd",
		               "system_prompt":"配置提示","max_iterations":7,"context_scope":"run",
		               "max_bytes":2048,"inactivity_timeout":11,"max_output_size":4096,
		               "max_exec_time":22,"var":{"A":"1"},"debug":true,"no_color":true}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR,
		                                       "--api-key", "k", "--api-url", "http://cli/v1",
		                                       "--model", "cli-m", "--traj-dir", "build/cli-traj",
		                                       "--workdir", "build/cli-wd",
		                                       "--system-prompt", "flag 提示",
		                                       "--max-iterations", "3", "--context-scope", "traj",
		                                       "--max-bytes", "512", "--inactivity-timeout", "5",
		                                       "--max-output-size", "256", "--max-exec-time", "9",
		                                       "--var", "B=2", "--debug", "--no-color", "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.api_key, "k");
		test::eq(parsed.ctx.api_url, "http://cli/v1");
		test::eq(parsed.ctx.model, "cli-m");
		test::eq(parsed.ctx.traj_dir, "build/cli-traj");
		test::eq(parsed.ctx.workdir, "build/cli-wd");
		test::eq(parsed.ctx.max_iterations, 3);
		test::eq(parsed.ctx.context_scope, "traj");
		test::eq(parsed.ctx.max_bytes, (usz)512);
		test::eq(parsed.ctx.inactivity_timeout, 5);
		test::eq(parsed.ctx.max_output_size, (usz)256);
		test::eq(parsed.ctx.max_exec_time, 9);
		test::@check(parsed.ctx.system_prompt.starts_with("flag 提示"), "实际：%s",
		             buf::truncate(parsed.ctx.system_prompt, 40));
		// var：配置 A 在前，CLI B 在后
		test::eq((int)parsed.ctx.vars.len, 2);
		test::eq(parsed.ctx.vars[0], "A=1");
		test::eq(parsed.ctx.vars[1], "B=2");
		free_vars(parsed.ctx.vars);
		free(parsed.ctx.system_prompt.ptr);
	};
}

// 数值哨兵语义与同名 flag 一致：<=0 / 0 表示不限、用默认或关闭
fn void test_config_numeric_sentinels() @test
{
	@pool()
	{
		write_config(`{"api_key":"k","model":"m","max_bytes":0,"inactivity_timeout":-1,
		               "max_exec_time":-2,"max_output_size":0,"max_iterations":-3}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.max_bytes, (usz)0);
		test::eq(parsed.ctx.inactivity_timeout, -1);
		test::eq(parsed.ctx.max_exec_time, -2);
		test::eq(parsed.ctx.max_output_size, (usz)0);
		test::eq(parsed.ctx.max_iterations, 0);
		free(parsed.ctx.system_prompt.ptr);
	};
	@pool()
	{
		write_config(`{"api_key":"k","model":"m","max_bytes":4096,"inactivity_timeout":30,
		               "max_exec_time":60,"max_output_size":1024,"max_iterations":5,
		               "context_scope":"run"}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.max_bytes, (usz)4096);
		test::eq(parsed.ctx.inactivity_timeout, 30);
		test::eq(parsed.ctx.max_exec_time, 60);
		test::eq(parsed.ctx.max_output_size, (usz)1024);
		test::eq(parsed.ctx.max_iterations, 5);
		test::eq(parsed.ctx.context_scope, "run");
		free(parsed.ctx.system_prompt.ptr);
	};
}

fn void test_config_boolean_switches() @test
{
	@pool()
	{
		write_config(`{"api_key":"k","model":"m","debug":true,"no_color":true}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.debug, true);
		test::eq(parsed.ctx.no_color, true);
		free(parsed.ctx.system_prompt.ptr);
	};
}

// var 对象；命令行 --var 在其上逐键追加/覆盖（配置先、CLI 后）
fn void test_config_var_and_flag_merge() @test
{
	@pool()
	{
		write_config(`{"api_key":"k","model":"m","var":{"A":"1","B":"2"}}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::eq((int)parsed.ctx.vars.len, 2);
		test::eq(parsed.ctx.vars[0], "A=1");
		test::eq(parsed.ctx.vars[1], "B=2");
		free_vars(parsed.ctx.vars);
		free(parsed.ctx.system_prompt.ptr);
	};
	@pool()
	{
		write_config(`{"api_key":"k","model":"m","var":{"A":"1","B":"2"}}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR,
		                                       "--var", "B=cli", "--var", "C=3", "-p", "x" });
		test::eq(parsed.error, "");
		// 配置先、CLI 后：B 出现两次，后者（CLI）胜出
		test::eq((int)parsed.ctx.vars.len, 4);
		test::eq(parsed.ctx.vars[0], "A=1");
		test::eq(parsed.ctx.vars[1], "B=2");
		test::eq(parsed.ctx.vars[2], "B=cli");
		test::eq(parsed.ctx.vars[3], "C=3");
		free_vars(parsed.ctx.vars);
		free(parsed.ctx.system_prompt.ptr);
	};
}

// 配置的 system_prompt：能被 flag 覆盖，也能被 flag 的来源选择抑制
fn void test_config_system_prompt_source() @test
{
	@pool()
	{
		write_config(`{"api_key":"k","model":"m","system_prompt":"来自配置的 {{os}} 提示"}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::@check(parsed.ctx.system_prompt.starts_with("来自配置的 "), "实际：%s",
		             buf::truncate(parsed.ctx.system_prompt, 80));
		test::@check(!parsed.ctx.system_prompt.contains("{{"), "占位符应已展开");
		free(parsed.ctx.system_prompt.ptr);
	};
	@pool()
	{
		// flag 给了来源：配置的来源键被忽略，flag 胜出
		write_config(`{"api_key":"k","model":"m","system_prompt":"配置提示"}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR,
		                                       "--system-prompt", "flag 提示", "-p", "x" });
		test::eq(parsed.error, "");
		test::@check(parsed.ctx.system_prompt.starts_with("flag 提示"), "实际：%s",
		             buf::truncate(parsed.ctx.system_prompt, 80));
		free(parsed.ctx.system_prompt.ptr);
	};
	@pool()
	{
		// 配置给 system_prompt_file，flag 给 --system-prompt：flag 的来源选择不被反覆盖
		(void)file::save(CFG_DIR +++ "/sys.txt", "文件提示");
		write_config(`{"api_key":"k","model":"m","system_prompt_file":"build/test_cfg/sys.txt"}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR,
		                                       "--system-prompt", "flag 提示", "-p", "x" });
		test::eq(parsed.error, "");
		test::@check(parsed.ctx.system_prompt.starts_with("flag 提示"), "实际：%s",
		             buf::truncate(parsed.ctx.system_prompt, 80));
		free(parsed.ctx.system_prompt.ptr);
	};
}

// 配置里两来源同时出现 = 硬错误（沿用 flag 层互斥）
fn void test_config_system_prompt_conflict_is_error() @test
{
	write_config(`{"system_prompt":"a","system_prompt_file":"b"}`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
	test::@check(parsed.error.contains("互斥"), "应提示互斥，实际：%s", parsed.error);
}

// 配置里的 system_prompt_file 会被读取并展开占位符
fn void test_config_system_prompt_file_backfill() @test
{
	@pool()
	{
		(void)path::mkdir((Path)CFG_DIR, true);
		(void)file::save(CFG_DIR +++ "/sys2.txt", "文件里的提示 {{os}}");
		write_config(`{"api_key":"k","model":"m","system_prompt_file":"build/test_cfg/sys2.txt"}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::@check(parsed.ctx.system_prompt.starts_with("文件里的提示 "), "实际：%s",
		             buf::truncate(parsed.ctx.system_prompt, 80));
		test::@check(!parsed.ctx.system_prompt.contains("{{"), "占位符应已展开");
		free(parsed.ctx.system_prompt.ptr);
	};
}

fn void test_config_syntax_error_is_usage_error() @test
{
	write_config(`{"model": }`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("不是合法 JSON"), "实际：%s", parsed.error);
}

fn void test_config_type_error_is_usage_error() @test
{
	write_config(`{"api_key":"k","model":"m","max_iterations":"abc"}`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("max_iterations"), "实际：%s", parsed.error);
}

// JSON 数字都是 double：非整数也算类型不符，不能静默截断
fn void test_config_fractional_int_is_type_error() @test
{
	write_config(`{"api_key":"k","model":"m","max_bytes":20.5}`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("max_bytes"), "实际：%s", parsed.error);
}

fn void test_config_invalid_context_scope_is_error() @test
{
	write_config(`{"api_key":"k","model":"m","context_scope":"nope"}`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
	test::@check(parsed.error.contains("context_scope"), "实际：%s", parsed.error);
}

// 未知/被排除的键只告警不失败
fn void test_config_unknown_key_is_ignored() @test
{
	@pool()
	{
		write_config(`{"api_key":"k","model":"m","resume":true,"nonsense":1}`);
		cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "-p", "x" });
		test::eq(parsed.error, "");
		test::eq(parsed.ctx.model, "m");
		test::eq(parsed.ctx.resume, false);
		free(parsed.ctx.system_prompt.ptr);
	};
}

fn void test_no_config_skips_file() @test
{
	write_config(`{"api_key":"cfg-key","model":"cfg-model"}`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "--no-config", "-p", "x" });
	test::eq(parsed.error.len != 0, true);
	test::@check(parsed.error.contains("--api-key"), "实际：%s", parsed.error);

	parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "--no-config",
	                      "--api-key", "k", "--model", "m", "-p", "x" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.model, "m");
	test::eq(parsed.ctx.api_key, "k");
	free(parsed.ctx.system_prompt.ptr);
}

// 配置文件不存在 = 静默跳过，行为与"没有配置"完全一致
fn void test_missing_config_is_silently_skipped() @test
{
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", "build/test_cfg_none",
	                                       "--api-key", "k", "--model", "m", "-p", "x" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.api_url, cli::DEFAULT_API_URL);
	free(parsed.ctx.system_prompt.ptr);
}

// --help 不读配置：文件坏掉也不影响看帮助
fn void test_help_does_not_read_config() @test
{
	write_config(`{"broken"`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR, "--help" });
	test::eq(parsed.error, "");
	test::eq(parsed.ctx.help, true);
}

// --print-system-prompt 读配置（来源可能来自配置文件）
fn void test_print_system_prompt_uses_config() @test
{
	write_config(`{"system_prompt":"配置提示 {{os}}"}`);
	cli::ParseResult parsed = cli::resolve({ "llmcli", "--config-dir", CFG_DIR,
	                                       "--print-system-prompt" });
	test::eq(parsed.error, "");
	test::@check(parsed.ctx.system_prompt.starts_with("配置提示 "), "实际：%s",
	             buf::truncate(parsed.ctx.system_prompt, 80));
	free(parsed.ctx.system_prompt.ptr);
}

// 子命令接缝：traj_dir 来自配置；--no-config 时不生效
fn void test_configure_trajectory_reads_traj_dir_from_config() @test
{
	@pool()
	{
		(void)path::mkdir((Path)"build/test_cfg_cmd", true);
		(void)file::save("build/test_cfg_cmd/llmcli.json", `{"traj_dir":"build/cfg-cmd-traj"}`);
		cli::TrajArgs cfg = cli::configure_trajectory({ "list", "--config-dir", "build/test_cfg_cmd" });
		test::eq(cfg.error, "");
		test::eq((int)cfg.rest.len, 1);
		test::eq(cfg.rest[0], "list");
		test::eq(trajectory::root_dir(tmem), "build/cfg-cmd-traj");
	};
}

fn void test_configure_trajectory_no_config_ignores_traj_dir() @test
{
	@pool()
	{
		(void)path::mkdir((Path)"build/test_cfg_cmd", true);
		(void)file::save("build/test_cfg_cmd/llmcli.json", `{"traj_dir":"build/cfg-cmd-traj"}`);
		cli::TrajArgs cfg = cli::configure_trajectory({ "list", "--config-dir", "build/test_cfg_cmd",
		                                              "--no-config" });
		test::eq(cfg.error, "");
		test::eq((int)cfg.rest.len, 1);
		// --no-config：配置的 traj_dir 不生效，根目录由 config-dir 派生
		test::eq(trajectory::root_dir(tmem), "build/test_cfg_cmd/traj");
	};
}

// 子命令遇到坏配置：返回 error（main 据此退出码 2）
fn void test_configure_trajectory_reports_broken_config() @test
{
	@pool()
	{
		(void)path::mkdir((Path)"build/test_cfg_bad", true);
		(void)file::save("build/test_cfg_bad/llmcli.json", `{"traj_dir": }`);
		cli::TrajArgs cfg = cli::configure_trajectory({ "list", "--config-dir", "build/test_cfg_bad" });
		test::eq(cfg.error.len != 0, true);
	};
}

// 即使带了 --traj-dir，子命令也读整份配置：坏配置照样报错
fn void test_configure_trajectory_broken_config_with_traj_dir() @test
{
	@pool()
	{
		(void)path::mkdir((Path)"build/test_cfg_bad", true);
		(void)file::save("build/test_cfg_bad/llmcli.json", `{"max_iterations":"abc"}`);
		cli::TrajArgs cfg = cli::configure_trajectory({ "list", "--traj-dir", "build/x",
		                                              "--config-dir", "build/test_cfg_bad" });
		test::eq(cfg.error.len != 0, true);
	};
}

