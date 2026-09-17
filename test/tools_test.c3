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
	test::@check(result.content.contains("$ echo hello"), "应回显执行的命令，实际：%s", result.content);
	release(&result);
}

fn void test_bash_stderr_and_exit_code() @test
{
	setup();
	tools::ToolResult result = tools::run_tool("bash", `{"command":"echo oops 1>&2 & exit 3"}`);
	io::printfn("bash content=%s", result.content);
	test::eq(result.is_error, false);
	test::@check(result.content.contains("oops"), "应回填 stderr 内容，实际：%s", result.content);
	test::@check(result.content.contains("Command exited with code 3"), "应回填退出码 3，实际：%s", result.content);
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
	test::@check(result.content.contains("cmd.exe"),
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
		string::tformat(`{"path":"%s","old_string":"old-text","new_string":"new-text"}`, path));
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
		string::tformat(`{"path":"%s","old_string":"nope","new_string":"x"}`, path));
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
		string::tformat(`{"path":"%s","old_string":"dup","new_string":"x"}`, path));
	test::eq(result.is_error, true);
	test::@check(result.content.contains("不唯一"), "应提示不唯一，实际：%s", result.content);
	release(&result);

	@pool()
	{
		if (try content = file::load(tmem, path)) test::eq((String)content, "dup\ndup\n");
	};
}

fn void test_edit_file_allow_multiple() @test
{
	setup();
	String path = "build/test_edit_multi.txt";
	(void)file::save(path, "dup\ndup\n");

	tools::ToolResult result = tools::run_tool("edit_file",
		string::tformat(`{"path":"%s","old_string":"dup","new_string":"x","allow_multiple":true}`, path));
	test::eq(result.is_error, false);
	release(&result);

	@pool()
	{
		if (try content = file::load(tmem, path)) test::eq((String)content, "x\nx\n");
	};
}

fn void test_read_file_paginates() @test
{
	setup();
	String path = "build/test_read.txt";
	(void)file::save(path, "L1\nL2\nL3\nL4\n");

	tools::ToolResult result = tools::run_tool("read_file",
		string::tformat(`{"path":"%s","offset":2,"limit":2}`, path));
	test::eq(result.is_error, false);
	test::@check(result.content.contains("2\tL2"), "应显示第 2 行，实际：%s", result.content);
	test::@check(result.content.contains("3\tL3"), "应显示第 3 行，实际：%s", result.content);
	test::@check(!result.content.contains("1\tL1"), "不应含第 1 行，实际：%s", result.content);
	release(&result);
}

fn void test_read_file_missing_reports_error() @test
{
	setup();
	tools::ToolResult result = tools::run_tool("read_file", `{"path":"build/does_not_exist_xyz.txt"}`);
	test::eq(result.is_error, true);
	release(&result);
}

fn void test_write_file_creates_parent_dirs() @test
{
	setup();
	String path = "build/nested/dir/out.txt";
	tools::ToolResult result = tools::run_tool("write_file",
		string::tformat(`{"path":"%s","content":"hello"}`, path));
	test::eq(result.is_error, false);
	release(&result);

	@pool()
	{
		if (try content = file::load(tmem, path)) test::eq((String)content, "hello");
	};
}

fn void test_list_dir_lists_entries() @test
{
	setup();
	// 用 build 目录自身，至少应列得出来且含 Summary
	tools::ToolResult result = tools::run_tool("list_dir", `{"path":"build"}`);
	test::eq(result.is_error, false);
	test::@check(result.content.contains("Summary:"), "应含 Summary 行，实际：%s", result.content);
	release(&result);
}
