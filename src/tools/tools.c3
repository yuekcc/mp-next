module llmcli::tools;

import cjson;
import llmcli::buf, llmcli::log;

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

alias ToolFn = fn ToolResult(CJsonItem* args);

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
fn ToolResult run_tool(String name, String arguments)
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
	return tool.execute(args);
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
	register_tool({
		.name = "bash",
		.description = "在用户机器上执行一条 bash 命令，回填 stdout/stderr 与退出码。"
		               "输出截断到末 2000 行，截断前完整输出落盘到临时文件。各平台统一经 bash -c 执行，"
		               "Windows 上使用 Git Bash。",
		.parameters = $embed("../tool_schemas/bash.json"),
		.execute = &tool_bash,
	});
	register_tool({
		.name = "edit_file",
		.description = "把文件中的一段文本精确替换成另一段。old_string 必须精确匹配（含空白与换行）。"
		               "默认要求唯一匹配，出现多次会报错且不修改；设 allow_multiple=true 可替换全部。",
		.parameters = $embed("../tool_schemas/edit_file.json"),
		.execute = &tool_edit_file,
	});
	register_tool({
		.name = "read_file",
		.description = "读取一个文本文件并按行回填（行号前缀便于定位）。大文件用 offset/limit 分页。",
		.parameters = $embed("../tool_schemas/read_file.json"),
		.execute = &tool_read_file,
	});
	register_tool({
		.name = "write_file",
		.description = "把内容写入文件。文件不存在则创建，存在则覆盖；自动创建父目录。",
		.parameters = $embed("../tool_schemas/write_file.json"),
		.execute = &tool_write_file,
	});
	register_tool({
		.name = "list_dir",
		.description = "列举目录内容：目录在前、文件在后各按名排序，文件附大小；末行输出 Summary。"
		               "默认最多 500 条，可用 limit 调整（<=0 不限制）。",
		.parameters = $embed("../tool_schemas/list_dir.json"),
		.execute = &tool_list_dir,
	});
}
