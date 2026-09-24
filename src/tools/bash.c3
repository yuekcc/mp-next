module llmcli::tools;

import std::io, std::io::path, std::os::env, std::os::process, std::thread, std::time, libc;
import cjson;
import llmcli::buf, llmcli::log;

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
