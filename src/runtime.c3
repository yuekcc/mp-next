module llmcli::runtime;

import std::io, std::io::path, std::os::env, std::os::process, std::thread, std::time, libc;
import std::core::mem::allocators;
import llmcli::winjob;
import llmcli::log;

// ---- 常量 ----

// 输出合并后截断到末 2000 行；截断前的完整输出落盘到临时文件，
// 便于模型在需要时读取完整结果。
const usz OUTPUT_LINE_LIMIT = 2000;

// ---- 中断处理 ----

// 当前运行中的子进程，供中断处理器终止，避免留下孤儿进程。
// 不能是 tlocal：Windows 上信号处理器跑在另一个线程。
Process* active_child;

// 当前子进程挂的 Job Object（仅 Windows）。中断处理器关掉句柄即可把子进程
// 连同孙进程一起杀（KILL_ON_JOB_CLOSE）；控制台事件杀不掉孙进程，原因见 winjob.c3。
void* active_job;

fn void on_interrupt(int sig)
{
	$if env::WIN32:
		if (active_job)
		{
			(void)winjob::terminate(active_job);
			active_job = null;
		}
	$endif
	if (active_child) (void)active_child.terminate();
	libc::exit(130);
}

// 中断时先杀掉正在跑的子进程再退出，避免留下孤儿进程把 CI job 拖住。
// Windows：Ctrl+C 走 SIGINT，Ctrl+Break 走 CRT 的 SIGBREAK（不是 SIGTERM）；
// 杀整棵进程树靠 Job Object（见 active_job）。POSIX：Ctrl+C 走 SIGINT，
// CI 的 timeout 默认发 SIGTERM；只 terminate 直接子进程，进程组 kill 需要
// spawn 前 setpgid，v1 不做（ponytail：程序化发信号时孙进程可能漏杀）。
fn void install_interrupt_handler()
{
	libc::signal(libc::SIGINT, &on_interrupt);
	$if env::WIN32:
		libc::signal(libc::SIGBREAK, &on_interrupt);
	$else
		libc::signal(libc::SIGTERM, &on_interrupt);
	$endif
}

// ---- 类型 ----

struct StreamReader
{
	Process* process;
	DString* out;
	bool want_stderr;
}

// 一次生成代码执行的结果。output 与 final_answer 都是 mem 上的堆串，由调用方释放。
struct Execution
{
	String output;       // 回填给模型的执行输出（stdout+stderr，必要时截断）
	int exit_code;
	bool has_final;      // 生成代码里设了 FINAL / FINAL_FILE
	String final_answer; // has_final 时的最终答案
}

// ---- 进程 I/O ----

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

// ---- 执行一段生成代码 ----

// 定位 Python：各平台统一用 Python 3 执行。
// Windows：python.org 安装器默认不把 python 加进 PATH，py 启动器（%WINDIR%\py.exe）是
// 官方标准入口，有它最稳；找不到再退回 PATH 里的 python。POSIX：python3 是标准名。
fn String find_python()
{
	$if env::WIN32:
		if (try w = env::tget_var("WINDIR"))
		{
			String exe = string::tformat("%s\\py.exe", w);
			if (try p = path::new(tmem, exe))
			{
				if (path::exists(p)) return exe;
			}
		}
		return "python";
	$else
		return "python3";
	$endif
}

// 临时文件路径（每次执行一个，跑完即删）。stem 区分用途，ext 带扩展名。
// mem 上的堆串，调用方释放。
fn String make_temp_path(Allocator allocator, String stem, String ext) @private
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
	return string::format(allocator, "%s/llmcli_%s_%d.%s", dir, stem, (long)time::now(), ext);
}

// 包装脚本：模型代码以模块顶层运行（顶层赋值即模块全局变量），之后在同一进程里
// 捕获 FINAL / FINAL_FILE 写入 final_path（经 sys.argv[1] 传入，免转义）。
// 与 shellm 的 bash 包装同构：代码先跑、捕获逻辑在后；模型代码异常时脚本自然
// 中止（traceback 即本轮输出），捕获逻辑不执行——未设 FINAL 的轮次自然续环。
// 与 bash 版一致，以"是否设置"判断而非真假值：FINAL_FILE 优先，FINAL = "" 也算设过
// （答案为空串），只有两者都未定义时才视作本轮没给最终答案。
fn void build_python_script(DString* script, String code)
{
	// 标记围栏：模型代码跑在脚本顶层，reconfigure 必须在代码之前——Windows 上子进程的
	// stdout/stderr 管道是文本模式，\n 会被翻译成 \r\n，观察输出就不再与代码实际打印
	// 的字节一致（模型照观察结果写文件会引入 \r）。newline="\n" 关掉翻译；POSIX 上本就
	// 不翻译，此调用无副作用。
	script.append("import sys\n");
	script.append("_llmcli_final_path = sys.argv[1]\n");
	script.append(
		"try:\n"
		"    sys.stdout.reconfigure(newline=\"\\n\")\n"
		"    sys.stderr.reconfigure(newline=\"\\n\")\n"
		"except Exception:\n"
		"    pass\n");
	script.append_string(code);
	if (!code.ends_with("\n")) script.append("\n");
	script.append(
		"try:\n"
		"    _llmcli_globals = globals()\n"
		"    _llmcli_final = None\n"
		"    _llmcli_has_final = False\n"
		"    if \"FINAL_FILE\" in _llmcli_globals:\n"
		"        with open(str(_llmcli_globals[\"FINAL_FILE\"]), \"rb\") as _llmcli_src:\n"
		"            _llmcli_final = _llmcli_src.read()\n"
		"        _llmcli_has_final = True\n"
		"    elif \"FINAL\" in _llmcli_globals:\n"
		"        _llmcli_final = str(_llmcli_globals[\"FINAL\"])\n"
		"        _llmcli_has_final = True\n"
		"    if _llmcli_has_final:\n"
		"        with open(_llmcli_final_path, \"wb\") as _llmcli_f:\n"
		"            _llmcli_f.write(_llmcli_final.encode(\"utf-8\") if isinstance(_llmcli_final, str) else _llmcli_final)\n"
		"except Exception:\n"
		"    pass\n");
}

// 执行一段生成代码（shellm 式循环里模型写回的 ```python 代码块）。
// 输出合并 stdout/stderr 回填给模型；FINAL / FINAL_FILE 的值单独取回。
fn Execution run_python(String code)
{
	Execution exec;
	String final_path = make_temp_path(mem, "final", "txt");
	defer free(final_path.ptr);

	// 脚本落盘到临时文件再执行：不受命令行长度上限，模型代码原样嵌入（零转义）。
	String script_path = make_temp_path(mem, "script", "py");
	defer
	{
		(void)path::delete((Path)script_path);
		free(script_path.ptr);
	};

	DString script = dstring::new(tmem);
	build_python_script(&script, code);
	if (catch save_err = file::save(script_path, script.str_view()))
	{
		exec.output = string::format(mem, "写入临时脚本失败：%s", save_err);
		exec.exit_code = -1;
		return exec;
	}

	log::info("[python] 执行生成代码：\n%s", code);

	// 统一经 Python 3 执行。-X utf8 是 PEP 540 UTF-8 模式：stdio 与 open() 默认
	// 编码都变 UTF-8，Windows 上不再受本地代码页（如中文系统的 GBK）影响。
	// INHERIT_ENV 必须开：c3 的 process::spawn 在不指定环境时给子进程一个空环境块，
	// 没有 PATH 连模型代码里的 subprocess 都找不到外部命令。
	String python = find_python();
	String[] command_line = { python, "-X", "utf8", script_path, final_path };
	Process? spawned = process::spawn(command_line, SpawnOptions.INHERIT_ENV);
	if (catch err = spawned)
	{
		exec.output = string::format(mem, "启动 python 失败（%s）：%s（需要系统已安装 Python 3；Windows 上可用 python.org 安装包或 py 启动器）",
		                             python, err);
		exec.exit_code = -1;
		return exec;
	}
	Process* process = &spawned;
	defer (void)process.destroy();

	// 命令可能跑很久，必须在开始读输出之前就登记，中断处理器才杀得到它
	active_child = process;
	defer active_child = null;

	// Windows：把子进程挂进 KILL_ON_JOB_CLOSE 的 job，中断时关句柄连孙进程一起杀
	// （理由见 winjob.c3 顶部）。失败则退化。
	$if env::WIN32:
		active_job = winjob::create_and_assign(process.hProcess);
		if (!active_job) log::warn("无法把子进程挂进 Job Object，中断时可能留下孙进程");
		defer
		{
			if (active_job)
			{
				(void)winjob::terminate(active_job);
				active_job = null;
			}
		};
	$endif

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
	// 以 \n 结尾的文本 split 出一个尾部空元素：留着会在拼接时多出一个空行，空输出则
	// 变成 "\n"，agent 的"（无输出）"兜底永远走不到。先去掉它再数真实行数。
	usz line_count = lines.len;
	if (line_count && lines[line_count - 1].len == 0) line_count--;
	if (line_count > OUTPUT_LINE_LIMIT)
	{
		truncated = true;
		// 完整输出落盘（临时目录），截断只保留末 2000 行。
		if (try tmp = path::temp_directory(tmem))
		{
			Path dump = tmp.append(tmem, string::tformat("llmcli_output_%d.txt", (long)time::now()))!!;
			if (catch save_err = file::save((String)dump, full))
			{
				log::warn("执行输出落盘失败：%s", save_err);
			}
			else
			{
				output_file = (String)dump;
			}
		}
	}

	DString result = dstring::new(tmem);
	usz start = truncated ? line_count - OUTPUT_LINE_LIMIT : 0;
	for (usz i = start; i < line_count; i++) result.appendf("%s\n", lines[i]);
	if (truncated)
	{
		if (output_file.len)
		{
			result.appendf("... (truncated, full output stored at %s)\n", output_file);
		}
		else
		{
			result.appendf("... (truncated)\n");
		}
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
