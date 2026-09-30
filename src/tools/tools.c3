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

// 从一份自包含的工具定义 JSON（name / description / parameters 三件套）注册一个工具。
// 定义文件是工具的单一事实源：名字、用途说明、参数 schema 全在一个文件里，c3 侧只留"名字 -> 实现"的绑定。
// 任何一处不合规都拒绝注册并告警——工具定义是编译期嵌入的常量，坏了应当在启动时就嚷嚷，
// 而不是让一个没有参数约束的工具悄悄上线（旧实现用 `if (parameters)` 静默吞掉解析失败）。
fn void register_from_schema(ToolFn execute, String definition) @private
{
	// 解析用的中间量（cjson 树、序列化缓冲）都在这个池里随用随弃；
	// 只有要留在注册表里的 name / description / parameters 拷到 mem
	// （注册表活到进程结束，用 tmem 会在池回收后悬空）。
	@pool()
	{
		CJsonItem* root = cjson::parse_with_length((ZString)definition.ptr, definition.len);
		if (!root) { log::warn("工具定义不是合法 JSON，忽略：%s", buf::truncate(definition, 120)); return; }
		defer root.free();

		String name = root.get_key_string("name", tmem) ?? "";
		if (!name.len) { log::warn("工具定义缺少 name，忽略：%s", buf::truncate(definition, 120)); return; }
		if (find_tool(name)) { log::warn("工具 %s 重复注册，忽略", name); return; }

		String description = root.get_key_string("description", tmem) ?? "";
		String parameters = "";
		if (CJsonItem* schema = root.get_key("parameters"))
		{
			// print_unformatted 走 cJSON 自己的分配器：先拷到 mem，再立刻归还，
			// 否则这段 JSON 文本会随解析池一起漏掉（agent.c3 同款处理）。
			ZString printed = cjson::print_unformatted(schema);
			parameters = buf::cstr(mem, printed);
			cjson::free(printed);
		}

		register_tool({
			.name = name.copy(mem),
			.description = description.copy(mem),
			.parameters = parameters,
			.execute = execute,
		});
	};
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

// 五个内置工具都不看本次运行的配置（ctx 参数留给后续的 subagent / skill），
// 所以适配器丢掉 ctx 直接转到各自的实现上：不改 tool_* 的签名，将来真要用 ctx 的工具
// 只管把 ToolFn 的签名写全，这五个不用跟着再动一遍。
//
// 每个工具的 name / description / parameters 都在 src/tool_schemas/*.json 里，这里只绑实现。
fn void register_builtin_tools()
{
	register_from_schema(&run_bash, $embed("../tool_schemas/bash.json"));
	register_from_schema(&run_edit_file, $embed("../tool_schemas/edit_file.json"));
	register_from_schema(&run_read_file, $embed("../tool_schemas/read_file.json"));
	register_from_schema(&run_write_file, $embed("../tool_schemas/write_file.json"));
	register_from_schema(&run_list_dir, $embed("../tool_schemas/list_dir.json"));
}

fn ToolResult run_bash(cli::Ctx* ctx, CJsonItem* args) @private => tool_bash(args);
fn ToolResult run_edit_file(cli::Ctx* ctx, CJsonItem* args) @private => tool_edit_file(args);
fn ToolResult run_read_file(cli::Ctx* ctx, CJsonItem* args) @private => tool_read_file(args);
fn ToolResult run_write_file(cli::Ctx* ctx, CJsonItem* args) @private => tool_write_file(args);
fn ToolResult run_list_dir(cli::Ctx* ctx, CJsonItem* args) @private => tool_list_dir(args);

// 内置工具在进程启动时注册一次（@init 先于 main，也先于 c3c test 的用例）。
// 注册要把 JSON 里的 name/description/parameters 留在注册表里，注册表活到进程结束，
// 所以这几笔分配是"有意长存"的——放在 @init 里，c3c test 的泄漏检测就不会把它们
// 当成某个用例的残留（检测器只在用例执行期间替换分配器）。
fn void register_builtin_tools_at_startup() @init
{
	register_builtin_tools();
}
