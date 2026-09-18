module llmcli::tools;

import std::io, std::io::path, std::os::env, std::os::process, std::thread, std::sort, std::time, std::collections::list, libc;
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
// ponytail: 只 terminate 直接子进程（bash）。终端里的 Ctrl+C 会由控制台把事件
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

// 执行一条 shell 命令，回填 stdout/stderr 与退出码。
// 输出合并后截断到末 2000 行（与 mini_pi 的 Bash 一致）；截断前的完整输出落盘到临时文件，
// 便于模型在需要时读取完整结果。
const usz BASH_LINE_LIMIT = 2000;

// 定位 bash：各平台统一用 bash 执行。Git for Windows 默认只把 Git\cmd 加进 PATH（不含 bash.exe），
// 所以 Windows 先按常见安装位置探测，找不到再退回 PATH 里的 bash。
// ponytail: 退回的若是 WSL 的 System32\bash.exe，命令会跑在 WSL 环境而非当前文件系统；
// 要排除它得解析 PATH 找到的实际路径，暂时不做。
fn String find_bash()
{
	$if env::WIN32:
		String[] env_names = { "ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA" };
		String[] rel_paths = {
			"\\Git\\bin\\bash.exe",
			"\\Git\\bin\\bash.exe",
			"\\Programs\\Git\\bin\\bash.exe",
		};
		for (usz i = 0; i < env_names.len; i++)
		{
			if (try root = env::tget_var(env_names[i]))
			{
				String exe = string::tformat("%s%s", root, rel_paths[i]);
				if (try p = path::new(tmem, exe))
				{
					if (path::exists(p)) return exe;
				}
			}
		}
	$endif
	return "bash";
}

fn ToolResult bash_run(String command)
{
	log::info("[bash] %s", command);

	// 统一经 `bash -c` 执行（Windows 上是 Git Bash）。INHERIT_ENV 必须开：c3 的 process::spawn
	// 在不指定环境时给子进程一个空环境块，没有 PATH 连 ping/ls 这类外部命令都找不到。
	String bash = find_bash();
	String[] command_line = { bash, "-c", command };
	Process? spawned = process::spawn(command_line, SpawnOptions.INHERIT_ENV);
	if (catch err = spawned)
	{
		return fail(string::tformat("启动 bash 失败（%s）：%s（需要系统已安装 bash，Windows 上为 Git for Windows）",
		                            bash, err));
	}
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

	// 合并 stdout + stderr 为单一输出流（按源 Bash 的"全部输出"语义）。
	DString combined = dstring::new(tmem);
	combined.append(out.to_string(tmem));
	if (err.len)
	{
		if (!combined.str_view().ends_with("\n")) combined.append("\n");
		combined.append(err.to_string(tmem));
	}
	if (!combined.str_view().ends_with("\n")) combined.append("\n");

	String full = combined.str_view();
	String output_file = "";
	bool truncated = false;
	String[] lines = full.split(tmem, "\n");
	if (lines.len > BASH_LINE_LIMIT)
	{
		truncated = true;
		// 完整输出落盘（临时目录），截断只保留末 2000 行。
		if (try tmp = path::temp_directory(tmem))
		{
			Path dump = tmp.append(tmem, string::tformat("llmcli_bash_%d.txt", (long)time::now()))!!;
			if (catch save_err = file::save((String)dump, full))
			{
				log::warn("bash 输出落盘失败：%s", save_err);
			}
			else
			{
				output_file = (String)dump;
			}
		}
	}

	DString result = dstring::new(tmem);
	result.appendf("$ %s\n\n", command);
	usz start = truncated ? lines.len - BASH_LINE_LIMIT : 0;
	for (usz i = start; i < lines.len; i++) result.appendf("%s\n", lines[i]);
	if (truncated)
	{
		result.appendf("... (truncated, full output stored at %s)\n", output_file);
	}
	if (code != 0)
	{
		result.appendf("\n\nCommand exited with code %d", code);
	}

	return ok(result.str_view());
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
	String old_text = args.get_key_string("old_string", tmem) ?? "";
	String new_text = args.get_key_string("new_string", tmem) ?? "";
	bool allow_multiple = args.get_key_bool("allow_multiple") ?? false;

	if (!path.len) return fail("缺少必填参数 path（字符串）");
	if (!old_text.len) return fail("缺少必填参数 old_string（字符串）");
	if (old_text == new_text) return fail("old_string 与 new_string 相同，无需修改");

	char[]? loaded = file::load(tmem, path);
	if (catch err = loaded) return fail(string::tformat("无法读取 %s：%s", path, err));
	String text = (String)loaded;

	// 唯一匹配才动手（除非显式 allow_multiple），避免改坏文件
	usz hits = count_occurrences(text, old_text);
	if (hits == 0) { return fail(string::tformat("在 %s 中找不到 old_string（不做修改）", path)); }
	if (hits > 1 && !allow_multiple)
	{
		return fail(string::tformat("old_string 在 %s 中出现 %d 次，不唯一（不做修改）。"
		                            "需多处替换请设 allow_multiple=true", path, hits));
	}

	// 从头扫描，按非重叠出现依次替换；allow_multiple=false 只换第一处。
	DString buf = dstring::new(tmem);
	usz i = 0;
	usz replaced = 0;
	while (i <= text.len - old_text.len)
	{
		if (text[i : old_text.len] == old_text)
		{
			buf.append(new_text);
			i += old_text.len;
			replaced++;
			if (!allow_multiple) break;
		}
		else
		{
			buf.append(text[i : 1]);
			i++;
		}
	}
	buf.append(text[i : text.len - i]);

	if (catch err = file::save(path, buf.str_view()))
	{
		return fail(string::tformat("写入 %s 失败：%s", path, err));
	}

	log::info("[edit_file] %s 替换 %d 处", path, replaced);
	return ok(string::tformat("已修改 %s：替换 %d 处", path, replaced));
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

// ---- ReadFile --------------------------------------------------------------

// 读取文本文件并按行回填。offset 是 1-based 起始行（<=0 表示从头），limit 是最多行数（<=0 表示不限制）。
// 行号前缀 `N\t` 便于模型在 EditFile 时定位；不引入 hash 机制（mp-next 无对应 util）。
fn ToolResult tool_read_file(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	if (!path.len) return fail("缺少必填参数 path（字符串）");

	int offset = args.get_key_int("offset") ?? 0;
	int limit = args.get_key_int("limit") ?? 0;

	char[]? loaded = file::load(tmem, path);
	if (catch err = loaded) return fail(string::tformat("无法读取 %s：%s", path, err));
	String text = (String)loaded;

	String[] lines = text.split(tmem, "\n");
	usz total = lines.len;
	usz start = offset > 0 ? (usz)(offset - 1) : 0;
	if (start >= total) return fail(string::tformat("文件共 %d 行，offset %d 越界", total, offset));

	usz end = total;
	if (limit > 0)
	{
		end = start + (usz)limit;
		if (end > total) end = total;
	}

	DString buf = dstring::new(tmem);
	for (usz i = start; i < end; i++)
	{
		buf.appendf("%d\t%s\n", i + 1, lines[i]);
	}
	buf.appendf("(读取 %s：共 %d 行，显示 %d-%d)", path, total, start + 1, end);
	return ok(buf.str_view());
}

// ---- WriteFile -------------------------------------------------------------

fn ToolResult tool_write_file(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	String content = args.get_key_string("content", tmem) ?? "";
	if (!path.len) return fail("缺少必填参数 path（字符串）");

	// file::save 不建父目录：手动补一层，对齐 mini_pi 的 WriteFile 语义。
	if (try p = path::new(tmem, path))
	{
		if (try parent = p.parent())
		{
			if (!path::exists(parent))
			{
				if (try made = path::mkdir(parent, true)) { /* ok */ }
				else { return fail(string::tformat("无法创建父目录 %s", (String)parent)); }
			}
		}
	}

	if (catch err = file::save(path, content))
	{
		return fail(string::tformat("写入 %s 失败：%s", path, err));
	}

	log::info("[write_file] %s (%d 字节)", path, content.len);
	return ok(string::tformat("已写入 %s（%d 字节）", path, content.len));
}

// ---- ListDir ---------------------------------------------------------------

struct LsEntry
{
	String name;
	bool is_dir;
	long size;
}

fn int _ls_entry_cmp(LsEntry a, LsEntry b)
{
	if (a.is_dir != b.is_dir) return a.is_dir ? -1 : 1;
	return a.name.compare_to(b.name);
}

// 纯 c3 列举目录：目录在前、文件在后，各自按名升序；文件附人类可读大小；
// 末行输出 Summary（文件/目录计数）。limit<=0 表示不限制（对齐 mini_pi 默认 500）。
fn ToolResult tool_list_dir(CJsonItem* args)
{
	String dir_path = args.get_key_string("path", tmem) ?? ".";
	int limit = args.get_key_int("limit") ?? 500;

	Path dir;
	if (try d = path::new(tmem, dir_path)) { dir = d; }
	else { return fail(string::tformat("非法路径 %s", dir_path)); }
	if (!path::exists(dir)) return fail(string::tformat("目录不存在：%s", dir_path));
	if (!path::is_dir(dir)) return fail(string::tformat("不是目录：%s", dir_path));

	PathList? maybe = path::ls(tmem, dir);
	if (catch err = maybe) return fail(string::tformat("列举 %s 失败：%s", dir_path, err));
	PathList entries = maybe;

	list::List{LsEntry} list;
	list.init(tmem);
	foreach (entry : entries)
	{
		LsEntry e;
		e.name = entry.basename();
		Path full = dir.tappend(entry.basename())!!;
		e.is_dir = path::is_dir(full);
		e.size = e.is_dir ? 0 : (path::file_size(full) ?? 0);
		list.push(e);
	}
	sort::quicksort(list.array_view(), &_ls_entry_cmp);

	int files = 0;
	int dirs = 0;
	int shown = 0;
	DString buf = dstring::new(tmem);
	foreach (&e : list)
	{
		if (e.is_dir) { dirs++; } else { files++; }
		if (limit > 0 && shown >= limit) { continue; }
		if (e.is_dir)
		{
			buf.appendf("%s/\n", e.name);
		}
		else
		{
			buf.appendf("%s\t%s\n", e.name, human_size(e.size));
		}
		shown++;
	}
	if (limit > 0 && shown < (int)list.len())
	{
		buf.appendf("... (%d more entries)\n", (int)list.len() - shown);
	}
	buf.appendf("Summary: %d files, %d dirs", files, dirs);

	return ok(buf.str_view());
}

// 字节数 -> 人类可读：193B / 3.2K / 3.3M / 1.0G
fn String human_size(long size)
{
	if (size < 1024) return string::tformat("%dB", size);
	double b = (double)size;
	if (b < 1024.0 * 1024.0) return string::tformat("%.1fK", b / 1024.0);
	if (b < 1024.0 * 1024.0 * 1024.0) return string::tformat("%.1fM", b / (1024.0 * 1024.0));
	return string::tformat("%.1fG", b / (1024.0 * 1024.0 * 1024.0));
}

fn void register_builtin_tools()
{
	register_tool({
		.name = "bash",
		.description = "在用户机器上执行一条 bash 命令，回填 stdout/stderr 与退出码。"
		               "输出截断到末 2000 行，截断前完整输出落盘到临时文件。各平台统一经 bash -c 执行，"
		               "Windows 上使用 Git Bash。",
		.parameters = $embed("tool_schemas/bash.json"),
		.execute = &tool_bash,
	});
	register_tool({
		.name = "edit_file",
		.description = "把文件中的一段文本精确替换成另一段。old_string 必须精确匹配（含空白与换行）。"
		               "默认要求唯一匹配，出现多次会报错且不修改；设 allow_multiple=true 可替换全部。",
		.parameters = $embed("tool_schemas/edit_file.json"),
		.execute = &tool_edit_file,
	});
	register_tool({
		.name = "read_file",
		.description = "读取一个文本文件并按行回填（行号前缀便于定位）。大文件用 offset/limit 分页。",
		.parameters = $embed("tool_schemas/read_file.json"),
		.execute = &tool_read_file,
	});
	register_tool({
		.name = "write_file",
		.description = "把内容写入文件。文件不存在则创建，存在则覆盖；自动创建父目录。",
		.parameters = $embed("tool_schemas/write_file.json"),
		.execute = &tool_write_file,
	});
	register_tool({
		.name = "list_dir",
		.description = "列举目录内容：目录在前、文件在后各按名排序，文件附大小；末行输出 Summary。"
		               "默认最多 500 条，可用 limit 调整（<=0 不限制）。",
		.parameters = $embed("tool_schemas/list_dir.json"),
		.execute = &tool_list_dir,
	});
}
