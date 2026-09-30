module llmcli::test_tools;

import std::io;
import cjson;
import llmcli::cli, llmcli::tools;

// 一次运行的配置。工具接口要求传 ctx，这里给的是测试用的空配置——
// 五个内置工具都不读它，真正的消费者（subagent 之类的后续工具）才会。
fn cli::Ctx test_ctx() @private
{
	cli::Ctx ctx;
	ctx.model = "test-model";
	ctx.api_url = "http://127.0.0.1:1/v1/chat/completions";
	return ctx;
}

// ToolResult.content 归调用方所有（mem 上的堆串），测试里统一释放
fn void release(ToolResult* result) @private
{
	if (result.content.ptr) free(result.content.ptr);
}

// 内置工具由 tools.c3 的 @init 在进程启动时注册，测试跑起来时注册表已经就绪；
// 这里只兜底断言它确实注册上了（@init 漏掉时每个用例都会红）。
fn void setup() @private
{
	if (!tools::find_tool("bash")) tools::register_builtin_tools();
}

// 工具接口带了 ctx：注册表里的每个工具都得能被 run_tool 用 ctx 调起来，
// 漏改签名的工具会在这里被编译期挡住（函数指针类型不匹配）。
fn void test_all_builtin_tools_are_registered() @test
{
	setup();
	test::eq((int)tools::registry_len, 5);
	String[] expected = { "bash", "edit_file", "read_file", "write_file", "list_dir" };
	for (usz i = 0; i < expected.len; i++)
	{
		test::eq(tools::registry[i].name, expected[i]);
	}
}

// 内置工具的 name / description / parameters 由 $embed 从 src/tool_schemas/*.json 嵌入。
// 定义写坏时 register_from_schema 会拒绝注册（并告警），注册表就会少工具——
// 这里兜底校验注册表的形状：数量、名字、参数 schema 都还合法。
fn void test_builtin_tool_schemas_are_valid_json() @test
{
	setup();
	test::eq((int)tools::registry_len, 5);
	foreach (tool : tools::registry[0 : tools::registry_len])
	{
		test::@check(tool.name.len > 0, "工具缺少 name");
		test::@check(tool.description.len > 0, "%s 缺少 description", tool.name);
		CJsonItem* parsed = cjson::parse_with_length((ZString)tool.parameters.ptr,
		                                             tool.parameters.len);
		test::@check(parsed != null, "%s 的 parameters 不是合法 JSON：%s", tool.name, tool.parameters);
		if (parsed) parsed.free();
	}
}

// description 在 JSON 里是带 \n 的字符串（协议要求 string，不是数组），
// 注册后应当仍是可读的多行文本。
fn void test_description_is_multiline_string() @test
{
	setup();
	Tool* bash = tools::find_tool("bash");
	test::@check(bash != null, "找不到 bash 工具");
	if (!bash) return;
	test::@check(bash.description.contains("\n"), "bash 的 description 没有换行");
	test::@check(!bash.description.contains("\\n"), "description 里出现了字面 \\n 转义");
	test::@check(bash.description.starts_with("- Executes a system command"), "description 首行不对");
}

// 注册表 -> OpenAI tools 字段：每个工具都带上 name / description / parameters 三件套。
// agent 每次请求都走这条路径，形状坏了模型就看不见工具。
fn void test_to_json_shape() @test
{
	setup();
	CJsonItem* json = tools::to_json();
	test::eq((int)json.get_len(), 5);

	for (usz i = 0; i < json.get_len(); i++)
	{
		CJsonItem* item = json.get_at((sz)i);
		test::@check(item != null, "第 %d 项为空", i);
		if (!item) continue;
		String type = item.get_key_string("type", tmem) ?? "";
		test::eq(type, "function");
		CJsonItem* function = item.get_key("function");
		test::@check(function != null, "缺少 function 字段");
		if (!function) continue;
		test::@check((function.get_key_string("name", tmem) ?? "").len > 0, "function 缺 name");
		test::@check((function.get_key_string("description", tmem) ?? "").len > 0, "function 缺 description");
		CJsonItem* parameters = function.get_key("parameters");
		test::@check(parameters != null, "function 缺 parameters");
		// parameters 挂在 function 上，随 json.free() 一起释放，这里不能单独 free
	}
	json.free();
}

fn void test_bash_echo() @test
{
	setup();
	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "bash", `{"command":"echo hello"}`);
	io::printfn("bash content=%s", result.content);
	test::eq(result.is_error, false);
	test::@check(result.content.contains("hello"), "应回填 stdout 内容，实际：%s", result.content);
	test::@check(result.content.contains("$ echo hello"), "应回显执行的命令，实际：%s", result.content);
	release(&result);
}

fn void test_bash_stderr_and_exit_code() @test
{
	setup();
	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "bash", `{"command":"echo oops 1>&2 & exit 3"}`);
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

	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "bash",
		string::tformat(`{"command":"%s"}`, command));
	io::printfn("bash content=%s", result.content);
	test::@check(result.content.contains("cmd.exe"),
	             "子进程应继承环境变量（PATH），实际：%s", result.content);
	release(&result);
}

fn void test_unknown_tool_reports_error() @test
{
	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "nope", "{}");
	test::eq(result.is_error, true);
	test::@check(result.content.contains("未知工具"), "应提示未知工具，实际：%s", result.content);
	release(&result);
}

fn void test_invalid_arguments_reports_error() @test
{
	setup();
	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "bash", "{not json");
	test::eq(result.is_error, true);
	test::@check(result.content.contains("合法 JSON"), "应提示参数非法，实际：%s", result.content);
	release(&result);
}

fn void test_edit_file_unique_match() @test
{
	setup();
	String path = "build/test_edit_file.txt";
	(void)file::save(path, "alpha\nold-text\nomega\n");

	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "edit_file",
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

	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "edit_file",
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

	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "edit_file",
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

	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "edit_file",
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

	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "read_file",
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
	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "read_file", `{"path":"build/does_not_exist_xyz.txt"}`);
	test::eq(result.is_error, true);
	release(&result);
}

fn void test_list_dir_lists_entries() @test
{
	setup();
	// 用 build 目录自身，至少应列得出来且含 Summary
	cli::Ctx ctx = test_ctx();
	tools::ToolResult result = tools::run_tool(&ctx, "list_dir", `{"path":"build"}`);
	test::eq(result.is_error, false);
	test::@check(result.content.contains("Summary:"), "应含 Summary 行，实际：%s", result.content);
	release(&result);
}
