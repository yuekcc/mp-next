module llmcli::runtime;

import std::io, std::io::path, std::os::env, std::os::process, std::thread, std::time, std::time::clock, libc;
import std::atomic, std::core::mem::allocators;
import llmcli::winjob;
import llmcli::log;

// ---- 分节 ----
// 生成代码执行器（doc 4.4）。对齐 shellm：模型写的 bash 落到临时脚本后执行，包装
// `set -e` → 代码 → `set +e` → 按「是否设置」捕获 FINAL / FINAL_FILE → `exit 原 rc`。
// 附带三个止损看门狗（空闲 / 输出量 / 墙钟），命中即杀进程并给出结构化反馈。
//
// Python 执行（run_python）作为可选实现保留备查，主循环默认走 run_bash（见 Executor）。

// ---- 常量 ----

// 输出合并后截断到末 2000 行；截断前的完整输出落盘到临时文件，便于模型按需读取。
const usz OUTPUT_LINE_LIMIT = 2000;

// 看门狗默认阈值（可用 Ctx 覆盖）。
const int DEFAULT_INACTIVITY_TIMEOUT = 120;      // 秒：无输出即视为卡死
const usz DEFAULT_MAX_OUTPUT_SIZE = 10 * 1024 * 1024; // 字节
const int DEFAULT_MAX_EXEC_TIME = 1800;          // 秒

// ---- 中断处理 ----

// 当前运行中的子进程，供中断处理器终止，避免留下孤儿进程。
// 不能是 tlocal：Windows 上信号处理器跑在另一个线程。
Process* active_child;

// 当前子进程挂的 Job Object（仅 Windows）。中断处理器关掉句柄即可把子进程
// 连同孙进程一起杀（KILL_ON_JOB_CLOSE）。
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
fn void install_interrupt_handler()
{
	libc::signal(libc::SIGINT, &on_interrupt);
	$if env::WIN32:
		libc::signal(libc::SIGBREAK, &on_interrupt);
	$else
		libc::signal(libc::SIGTERM, &on_interrupt);
	$endif
}

// ---- 看门狗共享状态 ----

// 看门狗线程与读取线程共享的计数。必须跨线程原子访问。
// stop：主线程读完后置位，看门狗退出；killed/reason：看门狗命中止损时记录。
struct WatchState
{
	Atomic{ulong} last_output_ms; // 最近一次产生输出的墙钟（毫秒）
	Atomic{ulong} total_bytes;    // 累计输出字节
	Atomic{bool} stop;            // 主线程结束，看门狗退出
	Atomic{bool} killed;          // 看门狗已杀进程
	int reason;                   // 命中的止损（WatchReason），仅在 killed 后有意义
	int inactivity_ms;            // 阈值：空闲（毫秒），<=0 关闭
	usz max_output;               // 阈值：输出字节，0 关闭
	int max_exec_ms;              // 阈值：墙钟（毫秒），<=0 关闭
	Process* process;             // 被监视的子进程
	void* job;                    // Windows Job 句柄；非 null 时杀整棵进程树
	Clock start;                  // 开始时刻
}

// 看门狗命中的止损类型
const int WATCH_NONE = 0;
const int WATCH_INACTIVITY = 1;
const int WATCH_OUTPUT = 2;
const int WATCH_WALL = 3;

fn ulong now_ms() @private => (ulong)((long)clock::now() / 1_000_000);

fn int watchdog_worker(void* arg) @private
{
	// 看门狗跑在独立线程：只能用原子量与 LIBC/固定内存，不能用 tmem（thread-local）。
	WatchState* st = (WatchState*)arg;
	while (!st.stop.load())
	{
		thread::sleep_ms(50);
		if (st.stop.load()) break;
		ulong elapsed = now_ms() - (ulong)st.start / 1_000_000;
		int hit = WATCH_NONE;
		if (st.max_exec_ms > 0 && elapsed > (ulong)st.max_exec_ms)
		{
			hit = WATCH_WALL;
		}
		else if (st.inactivity_ms > 0 && (long)(now_ms() - st.last_output_ms.load()) > st.inactivity_ms)
		{
			hit = WATCH_INACTIVITY;
		}
		else if (st.max_output > 0 && st.total_bytes.load() > st.max_output)
		{
			hit = WATCH_OUTPUT;
		}
		if (hit != WATCH_NONE)
		{
			st.reason = hit;
			st.killed.store(true);
			// 关掉 Job 句柄即杀整棵进程树（bash + 孙进程），否则孙进程仍持有管道，
			// 主线程的 read 不会返回 EOF，join 也就永远等不到。
			$if env::WIN32:
				if (st.job) (void)winjob::terminate(st.job);
			$endif
			if (st.process) (void)st.process.terminate();
			return 0;
		}
	}
	return 0;
}

// 看门狗反馈文本（中文，回填给模型，帮助它改变策略）。
fn String watch_feedback(int reason) @private
{
	switch (reason)
	{
		case WATCH_INACTIVITY:
			return "命令长时间没有任何输出，已被空闲看门狗终止。若命令在等待输入（密码、确认）或交互式运行，"
				"请改为非交互方式（例如给命令加 --yes / -y，或显式用 </dev/null 重定向 stdin）；"
				"若命令确实很慢，请分步执行或后台运行后轮询。";
		case WATCH_OUTPUT:
			return "命令输出量超过上限，已被看门狗终止。请缩小输出（例如 head/tail/grep 过滤）后重试。";
		case WATCH_WALL:
			return "命令运行超过墙钟上限，已被看门狗终止。请分步执行或后台运行后轮询。";
		default:
			return "";
	}
}

// ---- 类型 ----

struct StreamReader
{
	Process* process;
	DString* out;
	bool want_stderr;
	WatchState* watch; // 非 null：读取时刷新看门狗计数
}

// 一次生成代码执行的结果。output 与 final_answer 都是 mem 上的堆串，由调用方释放。
struct ExecResult
{
	String output;       // 回填给模型的执行输出（stdout+stderr，必要时截断）
	int exit_code;
	bool has_final;      // 生成代码里设了 FINAL / FINAL_FILE
	String final_answer; // has_final 时的最终答案
	String feedback;     // 看门狗命中时的结构化反馈（空 = 未命中）
}

// 生成代码执行器（doc 4.4）。字段来自 Ctx；接口固定，未来可换 SandboxExecutor。
struct Executor
{
	String workdir;          // 生成代码的工作目录（空 = 继承当前目录）
	String[] vars;           // 额外环境变量（k=v），经 wrapper export 传入
	int inactivity_timeout;  // 秒；<=0 关闭
	usz max_output_size;     // 字节；0 关闭
	int max_exec_time;       // 秒；<=0 关闭
}

fn Executor default_executor()
{
	Executor ex;
	ex.inactivity_timeout = DEFAULT_INACTIVITY_TIMEOUT;
	ex.max_output_size = DEFAULT_MAX_OUTPUT_SIZE;
	ex.max_exec_time = DEFAULT_MAX_EXEC_TIME;
	return ex;
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
		if (reader.watch)
		{
			reader.watch.last_output_ms.store(now_ms());
			(void)reader.watch.total_bytes.add((ulong)n);
		}
	}
	return 0;
}

// ---- 定位解释器 ----

// 定位 bash：Windows 用 Git Bash（含 WSL 的 bash 兼容），POSIX 用 /bin/bash。
// Windows 上优先常见安装路径；找不到再回退 PATH 里的 bash。
fn String find_bash()
{
	$if env::WIN32:
		String[] candidates = {
			"C:/Program Files/Git/bin/bash.exe",
			"C:/Program Files/Git/usr/bin/bash.exe",
			"C:/Program Files (x86)/Git/bin/bash.exe",
		};
		foreach (c : candidates)
		{
			if (try p = path::new(tmem, c))
			{
				if (path::exists(p)) return c;
			}
		}
		return "bash";
	$else
		if (try p = path::new(tmem, "/bin/bash"))
		{
			if (path::exists(p)) return "/bin/bash";
		}
		return "bash";
	$endif
}

// 定位 Python（run_python 备查路径用）：各平台统一用 Python 3 执行。
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

// 临时文件路径（每次执行一个，跑完即删）。
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

// 把路径转成 bash 友好的正斜杠形态。
fn String slashify(String path) @private
{
	return path.treplace("\\", "/");
}

// 单引号字符串转义（用于 export NAME='...'）。
fn String shell_single_quote(String value) @private
{
	return string::tformat("'%s'", value.treplace("'", "'\\''"));
}

// ---- bash 包装脚本 ----

// 生成 bash 包装脚本（doc 4.4）。final_path 经环境变量传入，避免路径转义。
// 结构：set -e → 可选 cd → 可选 export → set -x → 模型代码 → set +x → set +e →
//       按「是否设置」捕获 FINAL_FILE（优先）/ FINAL → exit 原 rc。
fn void build_bash_script(DString* script, Executor* ex, String code, String final_path)
{
	script.append("set -e\n");
	// 子进程 stdin 接 /dev/null（doc 4.4）：交互式命令（input/read/密码提示）立即 EOF，不挂。
	script.append("exec < /dev/null\n");
	if (ex.workdir.len)
	{
		script.appendf("cd %s || exit 1\n", shell_single_quote(slashify(ex.workdir)));
	}
	foreach (v : ex.vars)
	{
		String name = v;
		String value = "";
		if (try eq = v.index_of_char('='))
		{
			name = v[:eq];
			value = v[(usz)eq + 1..];
		}
		script.appendf("export %s=%s\n", name, shell_single_quote(value));
	}
	script.append("set -x\n");
	script.append_string(code);
	if (!code.ends_with("\n")) script.append("\n");
	// 关闭 xtrace 再捕获，避免捕获逻辑自身的 trace 混进输出
	script.append("set +x\n");
	script.append("set +e\n");
	script.appendf("_llmcli_final=%s\n", shell_single_quote(slashify(final_path)));
	script.append(
		"if [ -n \"${FINAL_FILE+x}\" ]; then\n"
		"  if [ -f \"$FINAL_FILE\" ]; then cat \"$FINAL_FILE\" > \"$_llmcli_final\"; fi\n"
		"elif [ -n \"${FINAL+x}\" ]; then\n"
		"  printf '%s' \"$FINAL\" > \"$_llmcli_final\"\n"
		"fi\n");
}

// 剥离 xtrace 行（`+ ` 前缀）——它们只是 `set -x` 的调试噪音，不进 trajectory。
// 是"丢弃"而不是"置空"：置空会在合并输出里留下多余空行。
fn String strip_xtrace(String text) @private
{
	DString out = dstring::new(tmem);
	String[] lines = text.split(tmem, "\n", 0, false);
	bool first = true;
	foreach (line : lines)
	{
		if (line.len >= 2 && line[0] == '+' && line[1] == ' ') continue;
		if (!first) out.append_char('\n');
		first = false;
		out.append(line);
	}
	return out.str_view();
}

// ---- 执行 ----

// Executor 入口：执行一段生成代码，返回结果。默认走 bash（doc 4.4）。
fn ExecResult Executor.run(Executor* ex, String code)
{
	return run_bash(ex, code);
}

// 一次子进程执行的原始采集结果（tmem 上的临时数据）。
struct Collected
{
	String raw;       // stdout+stderr 合并原始输出（未剥离 xtrace、未截断）
	int exit_code;
	bool killed;      // 看门狗命中
	int kill_reason;  // WatchReason
}

// 子进程执行与采集：spawn → 关 stdin → 挂 Job → 起看门狗/读取线程 → join → 合并两流。
// 看门狗阈值来自 ex（<=0 关闭）；无看门狗时（如 python 备查路径）传全 0 的 Executor。
// 这是 bash / python 两条执行路径的公共骨架，避免大段重复。
fn Collected collect_process(String[] command_line, Executor* ex, String spawn_label) @private
{
	Collected c;
	Process? spawned = process::spawn(command_line, SpawnOptions.INHERIT_ENV);
	if (catch err = spawned)
	{
		c.raw = string::format(tmem, "启动 %s 失败（%s）：%s", spawn_label, command_line[0], err);
		c.exit_code = -1;
		return c;
	}
	Process* process = &spawned;
	defer (void)process.destroy();

	active_child = process;
	defer active_child = null;

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

	// stdin 关掉：交互式命令立即 EOF，不会一直等输入
	if (process.stdin_file)
	{
		libc::fclose(process.stdin_file);
		process.stdin_file = null;
	}

	DString out;
	out.init(&allocators::LIBC_ALLOCATOR);
	defer out.free();
	DString err;
	err.init(&allocators::LIBC_ALLOCATOR);
	defer err.free();

	WatchState watch;
	watch.last_output_ms.store(now_ms());
	watch.total_bytes.store(0);
	watch.stop.store(false);
	watch.killed.store(false);
	watch.reason = WATCH_NONE;
	watch.inactivity_ms = ex.inactivity_timeout > 0 ? ex.inactivity_timeout * 1000 : 0;
	watch.max_output = ex.max_output_size;
	watch.max_exec_ms = ex.max_exec_time > 0 ? ex.max_exec_time * 1000 : 0;
	watch.process = process;
	watch.job = null;
	$if env::WIN32:
		watch.job = active_job;
	$endif
	watch.start = clock::now();

	Thread watcher;
	bool watcher_started = true;
	if (catch te = watcher.create(&watchdog_worker, &watch)) watcher_started = false;

	// stdout 在本线程读，stderr 交给工作线程：两边都不堵管道才不会互相死锁。
	// 两个流都接看门狗：输出量/空闲是"累计输出"（stdout+stderr）的口径。
	StreamReader err_reader = { .process = process, .out = &err, .want_stderr = true, .watch = &watch };
	Thread err_thread;
	bool err_thread_started = true;
	if (catch thread_error = err_thread.create(&read_stream_worker, &err_reader))
	{
		err_thread_started = false;
		log::warn("无法启动 stderr 读取线程：%s", thread_error);
	}

	StreamReader out_reader = { .process = process, .out = &out, .want_stderr = false, .watch = &watch };
	(void)read_stream_worker(&out_reader);

	c.exit_code = process.join() ?? -1;
	if (err_thread_started) (void)err_thread.join();

	watch.stop.store(true);
	if (watcher_started) (void)watcher.join();
	c.killed = watch.killed.load();
	c.kill_reason = watch.reason;

	DString combined = dstring::new(tmem);
	combined.append(out.str_view());
	if (err.len())
	{
		if (!combined.str_view().ends_with("\n")) combined.append("\n");
		combined.append(err.str_view());
	}
	c.raw = combined.str_view();
	return c;
}

// 截断与回填文本：剥 xtrace（可选）→ 超 2000 行截断为末 2000 行、完整输出落盘 →
// 前面可加反馈 → 非零退出码附 [exit N]。返回 mem 堆串。
fn String finalize_output(Collected* c, bool strip_trace, String feedback) @private
{
	String full = strip_trace ? strip_xtrace(c.raw) : c.raw;
	// 剥掉 xtrace 后只剩空行，视作"无输出"（agent 的"（无输出）"兜底才走得到）。
	if (!full.trim().len) full = "";

	String output_file = "";
	bool truncated = false;
	String[] lines = full.split(tmem, "\n", 0, false);
	usz line_count = lines.len;
	if (line_count && lines[line_count - 1].len == 0) line_count--;
	if (line_count > OUTPUT_LINE_LIMIT)
	{
		truncated = true;
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
	if (feedback.len) result.appendf("[%s]\n", feedback);
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
	if (c.exit_code != 0) result.appendf("[exit %d]\n", c.exit_code);
	return result.str_view().copy(mem);
}

// 读回 FINAL 临时文件（存在即 has_final），随后删除。
fn void read_final(ExecResult* exec, String final_path) @private
{
	if (!path::exists((Path)final_path)) return;
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

fn ExecResult run_bash(Executor* ex, String code)
{
	ExecResult exec;
	String final_path = make_temp_path(mem, "final", "txt");
	defer free(final_path.ptr);

	String script_path = make_temp_path(mem, "script", "sh");
	defer
	{
		(void)path::delete((Path)script_path);
		free(script_path.ptr);
	};

	DString script = dstring::new(tmem);
	build_bash_script(&script, ex, code, final_path);
	if (catch save_err = file::save(script_path, script.str_view()))
	{
		exec.output = string::format(mem, "写入临时脚本失败：%s", save_err);
		exec.exit_code = -1;
		return exec;
	}

	log::info("[bash] 执行生成代码：\n%s", code);

	// bash 定位见 find_bash：Windows 用 Git Bash，POSIX 用 /bin/bash。
	String[] command_line = { find_bash(), script_path };
	Collected c = collect_process(command_line, ex, "bash");
	if (c.exit_code == -1)
	{
		exec.output = string::format(mem, "%s（Windows 需安装 Git Bash；POSIX 需 /bin/bash）", c.raw);
		exec.exit_code = -1;
		return exec;
	}
	if (c.killed) exec.feedback = watch_feedback(c.kill_reason);
	exec.output = finalize_output(&c, true, exec.feedback);
	exec.exit_code = c.exit_code;
	read_final(&exec, final_path);
	return exec;
}

// ---- Python 执行（可选实现，备查；主循环默认走 run_bash） ----

// 包装脚本：模型代码以模块顶层运行（顶层赋值即模块全局变量），之后在同一进程里
// 捕获 FINAL / FINAL_FILE 写入 final_path（经 sys.argv[1] 传入，免转义）。
fn void build_python_script(DString* script, String code)
{
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

fn ExecResult run_python(String code)
{
	ExecResult exec;
	String final_path = make_temp_path(mem, "final", "txt");
	defer free(final_path.ptr);

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

	// python 备查路径不设看门狗（阈值全 0）。
	Executor no_watch;
	String[] command_line = { find_python(), "-X", "utf8", script_path, final_path };
	Collected c = collect_process(command_line, &no_watch, "python");
	if (c.exit_code == -1)
	{
		exec.output = string::format(mem, "%s", c.raw);
		exec.exit_code = -1;
		return exec;
	}
	exec.output = finalize_output(&c, false, "");
	exec.exit_code = c.exit_code;
	read_final(&exec, final_path);
	return exec;
}
