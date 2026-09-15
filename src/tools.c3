module llmcli::tools;

import std::io, std::os::process, std::thread, libc;
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

// ---- Bash -----------------------------------------------------------------

// 当前运行中的子进程，供中断处理器终止，避免留下孤儿进程。
// 不能是 tlocal：Windows 上信号处理器跑在另一个线程。
Process* active_child;

fn void on_interrupt(int sig)
{
	if (active_child) (void)active_child.terminate();
	libc::exit(130);
}

// 中断时先杀掉正在跑的子进程再退出，避免留下孤儿进程把 CI job 拖住。
// Windows：Ctrl+C 走 SIGINT，Ctrl+Break 走 CRT 的 SIGBREAK（不是 SIGTERM）。
// POSIX：Ctrl+C 走 SIGINT，CI 的 timeout 默认发 SIGTERM。
// ponytail: 只 terminate 直接子进程（cmd.exe / sh）。终端里的 Ctrl+C 会由控制台把事件
// 发给整个进程组，孙进程（如 ping）同样会收到；只有程序化发信号（CI）才可能漏掉孙进程。
// 要彻底覆盖得上 Windows Job Object / POSIX 进程组 kill，v1 不做。
fn void install_interrupt_handler()
{
	libc::signal(libc::SIGINT, &on_interrupt);
	$if env::WIN32:
		libc::signal(libc::SIGBREAK, &on_interrupt);
	$else
		libc::signal(libc::SIGTERM, &on_interrupt);
	$endif
}

struct StreamReader
{
	Process* process;
	buf::ByteBuf* out;
	bool want_stderr;
}

fn int read_stream_worker(void* arg)
{
	StreamReader* reader = (StreamReader*)arg;
	char[8192] chunk;
	while (true)
	{
		sz n = reader.want_stderr
			? (reader.process.read_stderr(&chunk, (sz)chunk[..].len) ?? -1)
			: (reader.process.read_stdout(&chunk, (sz)chunk[..].len) ?? -1);
		if (n <= 0) break;
		if (!reader.out.append(chunk[:n])) break;
	}
	return 0;
}

// 执行一条 shell 命令，回填完整 stdout/stderr 与退出码（v1 不截断）。
fn ToolResult bash_run(String command)
{
	log::info("[bash] %s", command);

	String[] command_line;
	$if env::WIN32:
		command_line = { "cmd.exe", "/C", command };
	$else
		command_line = { "/bin/sh", "-c", command };
	$endif

	// INHERIT_ENV 必须开：c3 的 process::spawn 在不指定环境时给子进程一个空环境块，
	// 没有 PATH 连 ping/ls 这类外部命令都找不到。
	Process? spawned = process::spawn(command_line, SpawnOptions.INHERIT_ENV);
	if (catch err = spawned) return fail(string::tformat("启动子进程失败：%s", err));
	Process* process = &spawned;
	defer (void)process.destroy();

	// 命令可能跑很久，必须在开始读输出之前就登记，中断处理器才杀得到它
	active_child = process;
	defer active_child = null;

	// 子进程的 stdin 是管道，不关掉的话读 stdin 的命令会一直等。
	if (process.stdin_file)
	{
		libc::fclose(process.stdin_file);
		process.stdin_file = null;
	}

	buf::ByteBuf out;
	buf::ByteBuf err;
	defer out.free();
	defer err.free();

	// stdout 在本线程读，stderr 交给工作线程：两边都不堵管道才不会互相死锁。
	StreamReader err_reader = { .process = process, .out = &err, .want_stderr = true };
	Thread err_thread;
	bool err_thread_started = true;
	if (catch thread_error = err_thread.create(&read_stream_worker, &err_reader))
	{
		err_thread_started = false;
		log::warn("无法启动 stderr 读取线程：%s", thread_error);
	}

	StreamReader out_reader = { .process = process, .out = &out, .want_stderr = false };
	(void)read_stream_worker(&out_reader);

	int code = process.join() ?? -1;
	if (err_thread_started) (void)err_thread.join();

	return ok(string::tformat("exit_code: %d\n--- stdout ---\n%s%s\n--- stderr ---\n%s%s",
	                          code,
	                          out.to_string(tmem), out.len && out.ptr[out.len - 1] != '\n' ? "\n" : "",
	                          err.to_string(tmem), err.len && err.ptr[err.len - 1] != '\n' ? "\n" : ""));
}

fn ToolResult tool_bash(CJsonItem* args)
{
	String? command = args.get_key_string("command", tmem);
	if (catch err = command) return fail("缺少必填参数 command（字符串）");
	return bash_run(command);
}

// ---- EditFile -------------------------------------------------------------

fn ToolResult tool_edit_file(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	String old_text = args.get_key_string("old", tmem) ?? "";
	String new_text = args.get_key_string("new", tmem) ?? "";

	if (!path.len) return fail("缺少必填参数 path（字符串）");
	if (!old_text.len) return fail("缺少必填参数 old（字符串）");

	char[]? loaded = file::load(tmem, path);
	if (catch err = loaded) return fail(string::tformat("无法读取 %s：%s", path, err));
	String text = (String)loaded;

	// 唯一匹配才动手，避免改坏文件
	usz hits = count_occurrences(text, old_text);
	if (hits == 0) return fail(string::tformat("在 %s 中找不到 old 文本（不做修改）", path));
	if (hits > 1) return fail(string::tformat("old 文本在 %s 中出现 %d 次，不唯一（不做修改）",
	                                          path, hits));

	usz at = (usz)(text.index_of(old_text) ?? 0);
	String updated = string::tformat("%s%s%s", text[:at], new_text, text[at + old_text.len .. ^1]);
	if (catch err = file::save(path, updated)) return fail(string::tformat("写入 %s 失败：%s", path, err));

	log::info("[edit_file] %s (-%d +%d 行)", path, line_count(old_text), line_count(new_text));
	return ok(string::tformat("已修改 %s：替换 1 处，- %d 行 / + %d 行",
	                          path, line_count(old_text), line_count(new_text)));
}

fn usz count_occurrences(String haystack, String needle)
{
	if (!needle.len || haystack.len < needle.len) return 0;
	usz count = 0;
	usz last = haystack.len - needle.len;
	for (usz i = 0; i <= last; i++)
	{
		if (haystack[i : needle.len] == needle) count++;
	}
	return count;
}

fn usz line_count(String text)
{
	usz count = text.len ? 1 : 0;
	foreach (c : text)
	{
		if (c == '\n') count++;
	}
	return count;
}

// ---- 注册 -----------------------------------------------------------------

fn void register_builtin_tools()
{
	register_tool({
		.name = "bash",
		.description = "在用户机器上执行一条 shell 命令，回填完整 stdout/stderr 与退出码。"
		               "Windows 下经 cmd.exe /C 执行，其它平台经 /bin/sh -c。",
		.parameters =
			`{"type":"object","properties":{"command":{"type":"string","description":"要执行的命令"}},` +++
			`"required":["command"]}`,
		.execute = &tool_bash,
	});
	register_tool({
		.name = "edit_file",
		.description = "把文件中的一段文本替换成另一段。old 必须在文件中唯一匹配，否则不做任何修改并返回错误。",
		.parameters =
			`{"type":"object","properties":{` +++
			`"path":{"type":"string","description":"目标文件路径"},` +++
			`"old":{"type":"string","description":"要被替换的原文（需唯一）"},` +++
			`"new":{"type":"string","description":"替换后的新文本"}},` +++
			`"required":["path","old","new"]}`,
		.execute = &tool_edit_file,
	});
}
