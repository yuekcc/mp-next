module llmcli::tools;

import cjson;
import std::io::file;
import llmcli::buf, llmcli::cli, llmcli::log;

// 工具执行结果。content 一律是 mem 上的堆字符串，由调用方释放（agent 会话落盘后释放）。
struct ToolResult
{
	String content;
	bool is_error;
}

fn ToolResult ok(String content)
{
	ToolResult result = { .content = content.copy(mem), .is_error = false };
	return result;
}

fn ToolResult fail(String content)
{
	ToolResult result = { .content = content.copy(mem), .is_error = true };
	return result;
}

// ctx 是本次运行的配置（见 cli::Ctx）。工具不必去够全局就能知道"我在为谁跑"——
// subagent 这类工具需要父运行的 model / api_url，就从这里拿。
// 本次没有工具用它，参数先立在这里：接口一旦落后于需求，工具就会各自去够全局。
alias ToolFn = fn ToolResult(cli::Ctx* ctx, CJsonItem* args);

// 统一工具接口：新增工具只要填这个结构并注册，agent loop 不用改。
struct Tool
{
	String name;
	String description;
	String parameters; // 参数 JSON Schema 原文
	ToolFn execute;
}

// ponytail: 固定槽位注册表，32 个够用；真要超出再换 List。
const usz MAX_TOOLS = 32;
Tool[MAX_TOOLS] registry;
usz registry_len;

fn void register_tool(Tool tool)
{
	if (registry_len >= MAX_TOOLS)
	{
		log::warn("工具注册表已满，忽略 %s", tool.name);
		return;
	}
	registry[registry_len++] = tool;
}

fn Tool* find_tool(String name)
{
	for (usz i = 0; i < registry_len; i++)
	{
		if (registry[i].name == name) return &registry[i];
	}
	return null;
}

fn String tool_names()
{
	if (!registry_len) return "（没有已注册的工具）";
	String names = "";
	for (usz i = 0; i < registry_len; i++)
	{
		names = i ? names.tconcat(", ").tconcat(registry[i].name) : registry[i].name;
	}
	return names;
}

// 工具调用的统一入口：未知工具名 / 参数非法都回填结构化错误，交给 LLM 自我修正。
fn ToolResult run_tool(cli::Ctx* ctx, String name, String arguments)
{
	Tool* tool = find_tool(name);
	if (!tool) return fail(string::tformat("未知工具 %s；可用工具：%s", name, tool_names()));

	CJsonItem* args = cjson::create_object();
	defer args.free();
	if (arguments.len)
	{
		CJsonItem* parsed = cjson::parse_with_length((ZString)arguments.ptr, arguments.len);
		if (!parsed)
		{
			return fail(string::tformat("工具 %s 的参数不是合法 JSON：%s",
			                            name, buf::truncate(arguments, 200)));
		}
		args.free();
		args = parsed;
	}
	return tool.execute(ctx, args);
}

// 注册表 -> OpenAI tools 字段
fn CJsonItem* to_json()
{
	CJsonItem* array = cjson::create_array();
	for (usz i = 0; i < registry_len; i++)
	{
		Tool* tool = &registry[i];
		CJsonItem* item = cjson::create_object();
		item.set("type", "function");
		CJsonItem* function = cjson::add_object_to_object(item, "function");
		function.set("name", tool.name);
		function.set("description", tool.description);
		CJsonItem* parameters = cjson::parse_with_length((ZString)tool.parameters.ptr,
		                                                 tool.parameters.len);
		if (parameters) cjson::add_item_to_object(function, "parameters", parameters);
		cjson::add_item_to_array(array, item);
	}
	return array;
}

fn void register_builtin_tools()
{
	// 五个内置工具都不看本次运行的配置（ctx 参数留给后续的 subagent / skill），
	// 所以适配器丢掉 ctx 直接转到各自的实现上：不改 tool_* 的签名，将来真要用 ctx 的工具
	// 只管把 ToolFn 的签名写全，这五个不用跟着再动一遍。
	register_tool({
		.name = "bash",
		.description = "- Executes a system command in a controlled environment\n"
		               "- Runs the command synchronously and returns stdout/stderr and the exit code\n"
		               "- Automatically truncates large outputs to protect context window (keeps the last 2000 lines; the full output is written to a temp file whose path is reported)\n"
		               "- Commands are always run through `bash -c`; on Windows this is Git Bash\n"
		               "- Use this tool when you need to run shell commands, build scripts, run tests, or perform other system-level operations",
		.parameters = $embed("../tool_schemas/bash.json"),
		.execute = &run_bash,
	});
	register_tool({
		.name = "edit_file",
		.description = "- Performs precision string replacement in a file\n"
		               "- Requires an exact match for 'old_string', including whitespace and line endings\n"
		               "- Requires a unique match unless 'allow_multiple' is set; on multiple matches nothing is modified\n"
		               "- Use this tool when you need to make surgical changes to specific parts of a file without rewriting it entirely",
		.parameters = $embed("../tool_schemas/edit_file.json"),
		.execute = &run_edit_file,
	});
	register_tool({
		.name = "read_file",
		.description = "- Reads and returns the content of a specified file\n"
		               "- Supports line-based slicing for reading specific portions of large files\n"
		               "- Each content line is prefixed with its 1-based line number for reference\n"
		               "- When using 'edit_file', provide the exact text WITHOUT the line-number prefix\n"
		               "- Use this tool when you need to read the contents of a file to understand its logic or data",
		.parameters = $embed("../tool_schemas/read_file.json"),
		.execute = &run_read_file,
	});
	register_tool({
		.name = "write_file",
		.description = "- Writes complete content to a specified file\n"
		               "- Overwrites the file if it already exists; missing parent directories are NOT created\n"
		               "- Use this tool when you need to create a new file or fully overwrite an existing one",
		.parameters = $embed("../tool_schemas/write_file.json"),
		.execute = &run_write_file,
	});
	register_tool({
		.name = "list_dir",
		.description = "- Efficiently explores file system structure\n"
		               "- Lists one directory level: directories first, then files, each sorted by name; files include their size\n"
		               "- The last line reports a Summary with file/dir counts\n"
		               "- Results are limited to 500 items by default; set limit to get more (<=0 means no limit)\n"
		               "- Use this tool when you need to understand the directory structure or find files in a specific path",
		.parameters = $embed("../tool_schemas/list_dir.json"),
		.execute = &run_list_dir,
	});
}

fn ToolResult run_bash(cli::Ctx* ctx, CJsonItem* args) @private => tool_bash(args);
fn ToolResult run_edit_file(cli::Ctx* ctx, CJsonItem* args) @private => tool_edit_file(args);
fn ToolResult run_read_file(cli::Ctx* ctx, CJsonItem* args) @private => tool_read_file(args);
fn ToolResult run_write_file(cli::Ctx* ctx, CJsonItem* args) @private => tool_write_file(args);
fn ToolResult run_list_dir(cli::Ctx* ctx, CJsonItem* args) @private => tool_list_dir(args);
