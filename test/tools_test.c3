module llmcli::test_tools;

import std::io;
import llmcli::tools;

// ToolResult.content 归调用方所有（mem 上的堆串），测试里统一释放
fn void release(ToolResult* result) @private
{
	if (result.content.ptr) free(result.content.ptr);
}

fn void setup() @private
{
	if (!tools::find_tool("bash")) tools::register_builtin_tools();
}

fn void test_bash_echo() @test
{
	setup();
	tools::ToolResult result = tools::run_tool("bash", `{"command":"echo hello"}`);
	io::printfn("bash content=%s", result.content);
	test::eq(result.is_error, false);
	test::@check(result.content.contains("hello"), "应回填 stdout 内容，实际：%s", result.content);
	test::@check(result.content.contains("exit_code: 0"), "应回填退出码 0，实际：%s", result.content);
	release(&result);
}

fn void test_bash_stderr_and_exit_code() @test
{
	setup();
	tools::ToolResult result = tools::run_tool("bash", `{"command":"echo oops 1>&2 & exit 3"}`);
	io::printfn("bash content=%s", result.content);
	test::eq(result.is_error, false);
	test::@check(result.content.contains("oops"), "应回填 stderr 内容，实际：%s", result.content);
	test::@check(result.content.contains("exit_code: 3"), "应回填退出码 3，实际：%s", result.content);
	release(&result);
}

fn void test_bash_inherits_environment_path() @test
{
	setup();
	String command;
	$if env::WIN32:
		command = "where cmd";
	$else
		command = "command -v sh";
	$endif

	tools::ToolResult result = tools::run_tool("bash",
		string::tformat(`{"command":"%s"}`, command));
	io::printfn("bash content=%s", result.content);
	test::@check(result.content.contains("exit_code: 0"),
	             "子进程应继承环境变量（PATH），实际：%s", result.content);
	release(&result);
}

fn void test_unknown_tool_reports_error() @test
{
	tools::ToolResult result = tools::run_tool("nope", "{}");
	test::eq(result.is_error, true);
	test::@check(result.content.contains("未知工具"), "应提示未知工具，实际：%s", result.content);
	release(&result);
}

fn void test_invalid_arguments_reports_error() @test
{
	setup();
	tools::ToolResult result = tools::run_tool("bash", "{not json");
	test::eq(result.is_error, true);
	test::@check(result.content.contains("合法 JSON"), "应提示参数非法，实际：%s", result.content);
	release(&result);
}

fn void test_edit_file_unique_match() @test
{
	setup();
	String path = "build/test_edit_file.txt";
	(void)file::save(path, "alpha\nold-text\nomega\n");

	tools::ToolResult result = tools::run_tool("edit_file",
		string::tformat(`{"path":"%s","old":"old-text","new":"new-text"}`, path));
	test::eq(result.is_error, false);
	release(&result);

	@pool()
	{
		char[]? updated = file::load(tmem, path);
		if (catch err = updated)
		{
			test::@check(false, "回读文件失败");
		}
		else
		{
			test::eq((String)updated, "alpha\nnew-text\nomega\n");
		}
	};
}

fn void test_edit_file_missing_match_leaves_file_alone() @test
{
	setup();
	String path = "build/test_edit_missing.txt";
	(void)file::save(path, "alpha\n");

	tools::ToolResult result = tools::run_tool("edit_file",
		string::tformat(`{"path":"%s","old":"nope","new":"x"}`, path));
	test::eq(result.is_error, true);
	test::@check(result.content.contains("找不到"), "应提示找不到，实际：%s", result.content);
	release(&result);

	@pool()
	{
		if (try content = file::load(tmem, path)) test::eq((String)content, "alpha\n");
	};
}

fn void test_edit_file_ambiguous_match_leaves_file_alone() @test
{
	setup();
	String path = "build/test_edit_ambiguous.txt";
	(void)file::save(path, "dup\ndup\n");

	tools::ToolResult result = tools::run_tool("edit_file",
		string::tformat(`{"path":"%s","old":"dup","new":"x"}`, path));
	test::eq(result.is_error, true);
	test::@check(result.content.contains("不唯一"), "应提示不唯一，实际：%s", result.content);
	release(&result);

	@pool()
	{
		if (try content = file::load(tmem, path)) test::eq((String)content, "dup\ndup\n");
	};
}
