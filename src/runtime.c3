module llmcli::runtime;

import std::io, std::io::path, std::os::env, std::os::process, std::thread, std::time, libc;
import std::core::mem::allocators;
import llmcli::log;

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
	DString* out;
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
		reader.out.append_bytes(chunk[:n]);
	}
	return 0;
}

// 输出合并后截断到末 2000 行（沿用原 Bash 工具的额度）；截断前的完整输出落盘到临时文件，
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

// 一次生成代码执行的结果。output 与 final_answer 都是 mem 上的堆串，由调用方释放。
struct Execution
{
	String output;       // 回填给模型的执行输出（stdout+stderr，必要时截断）
	int exit_code;
	bool has_final;      // 生成代码里设了 FINAL / FINAL_FILE
	String final_answer; // has_final 时的最终答案
}

// FINAL / FINAL_FILE 落盘的临时文件路径（每次执行一个，跑完即删）。
// mem 上的堆串，调用方释放。
fn String make_final_path(Allocator allocator) @private
{
	Path dir;
	if (try tmp = path::temp_directory(tmem))
	{
		dir = tmp;
	}
	else
	{
		dir = (Path)".";
	}
	return string::format(allocator, "%s/llmcli_final_%d.txt", dir, (long)time::now());
}

// 包装脚本：先跑生成代码，再在同一个 bash 进程里捕获 FINAL / FINAL_FILE。
// 与 shellm 一致——代码在 `set -e` 下执行；捕获前 `set +e`，否则未设 FINAL 的
// 测试表达式（返回非零）会中断脚本，答案永远写不出去。
fn void append_wrapped(DString* script, String code, String final_path) @private
{
	script.append("set -e\n");
	script.append_string(code);
	if (!code.ends_with("\n")) script.append("\n");
	script.append("__llmcli_rc=$?\n");
	script.append("set +e\n");
	script.appendf("[ -n \"${FINAL+x}\" ] && printf '%%s' \"$FINAL\" > \"%s\"\n", final_path);
	script.appendf("[ -n \"${FINAL_FILE+x}\" ] && cat \"$FINAL_FILE\" > \"%s\"\n", final_path);
	script.append("exit $__llmcli_rc\n");
}

// 执行一段生成代码（shellm 式循环里模型写回的 ```bash 代码块）。
// 输出合并 stdout/stderr 回填给模型；FINAL / FINAL_FILE 的值单独取回。
fn Execution run_bash(String code)
{
	Execution exec;
	String final_path = make_final_path(mem);
	defer free(final_path.ptr);

	DString script = dstring::new(tmem);
	append_wrapped(&script, code, final_path);

	log::info("[bash] 执行生成代码：\n%s", code);

	// 统一经 `bash -e -c` 执行（Windows 上是 Git Bash）。INHERIT_ENV 必须开：c3 的
	// process::spawn 在不指定环境时给子进程一个空环境块，没有 PATH 连 ping/ls 这类外部命令都找不到。
	String bash = find_bash();
	String[] command_line = { bash, "-e", "-c", script.str_view() };
	Process? spawned = process::spawn(command_line, SpawnOptions.INHERIT_ENV);
	if (catch err = spawned)
	{
		exec.output = string::format(mem, "启动 bash 失败（%s）：%s（需要系统已安装 bash，Windows 上为 Git for Windows）",
		                             bash, err);
		exec.exit_code = -1;
		return exec;
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

	// 输出可能从 stderr 工作线程增长，必须绑 LIBC_ALLOCATOR（脱离 @pool/context），
	// 且在线程启动前 init，避免 DString 零值惰性初始化落到工作线程的 tmem 上。
	DString out;
	out.init(&allocators::LIBC_ALLOCATOR);
	defer out.free();
	DString err;
	err.init(&allocators::LIBC_ALLOCATOR);
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

	int code_exit = process.join() ?? -1;
	if (err_thread_started) (void)err_thread.join();

	// 合并 stdout + stderr 为单一输出流
	DString combined = dstring::new(tmem);
	combined.append(out.str_view());
	if (err.len())
	{
		if (!combined.str_view().ends_with("\n")) combined.append("\n");
		combined.append(err.str_view());
	}

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
	usz start = truncated ? lines.len - BASH_LINE_LIMIT : 0;
	for (usz i = start; i < lines.len; i++) result.appendf("%s\n", lines[i]);
	if (truncated)
	{
		result.appendf("... (truncated, full output stored at %s)\n", output_file);
	}
	if (code_exit != 0)
	{
		result.appendf("[exit %d]\n", code_exit);
	}

	exec.output = result.str_view().copy(mem);
	exec.exit_code = code_exit;

	// FINAL / FINAL_FILE 的捕获落在这个临时文件里；有就取回并删除。
	if (path::exists((Path)final_path))
	{
		char[]? data = file::load(mem, final_path);
		if (catch load_err = data)
		{
			log::warn("读取 FINAL 临时文件失败：%s", load_err);
		}
		else
		{
			exec.has_final = true;
			exec.final_answer = (String)data;
		}
		(void)path::delete((Path)final_path);
	}
	return exec;
}
