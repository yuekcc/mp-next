package main

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ---- 分节 ----
// 生成代码执行器。对齐 shellm：模型写的 bash 落到临时脚本后执行，包装
// `set -e` → 代码 → `set +x`/`set +e` → 按「是否设置」捕获 FINAL / FINAL_FILE。
// 附带三个止损看门狗（空闲 / 输出量 / 墙钟），命中即杀进程并给出结构化反馈。

// ---- 常量 ----

// 输出合并后截断到末 2000 行；截断前的完整输出落盘到临时文件，便于模型按需读取。
OUTPUT_LINE_LIMIT :: 2000

// 看门狗默认阈值（可用 Ctx 覆盖）。
DEFAULT_INACTIVITY_TIMEOUT :: 120 // 秒：无输出即视为卡死
DEFAULT_MAX_OUTPUT_SIZE :: 10 * 1024 * 1024 // 字节
DEFAULT_MAX_EXEC_TIME :: 1800 // 秒

// 看门狗命中的止损类型。
WATCH_NONE :: 0
WATCH_INACTIVITY :: 1
WATCH_OUTPUT :: 2
WATCH_WALL :: 3

// Windows 上 Ctrl+Break 的信号号（libc 绑定未导出）。
SIGBREAK :: 21

// ---- 中断处理 ----

// 当前运行中的子进程，供中断处理器终止，避免留下孤儿进程。
// 不能是线程局部：Windows 上信号处理器跑在另一个线程。
g_active_process: os.Process
g_active_has_process: bool
g_active_job: rawptr

on_interrupt :: proc "c" (sig: i32) {
	context = runtime.default_context()
	if g_active_job != nil {
		winjob_terminate(g_active_job)
		g_active_job = nil
	}
	if g_active_has_process {
		_ = os.process_terminate(g_active_process)
	}
	os.exit(EXIT_INTERRUPTED)
}

// 中断时先杀掉正在跑的子进程再退出，避免留下孤儿进程把 CI job 拖住。
install_interrupt_handler :: proc() {
	libc.signal(libc.SIGINT, on_interrupt)
	when ODIN_OS == .Windows {
		libc.signal(SIGBREAK, on_interrupt)
	} else {
		libc.signal(libc.SIGTERM, on_interrupt)
	}
}

// ---- 类型 ----

// 看门狗线程与读取线程共享的计数。必须跨线程原子访问。
WatchState :: struct {
	last_output_ms: i64, // 最近一次产生输出的耗时（毫秒）
	total_bytes:    i64, // 累计输出字节
	stop:           bool, // 主线程结束，看门狗退出
	killed:         bool, // 看门狗已杀进程
	reason:         int, // 命中的止损（killed 后有意义）
	inactivity_ms:  i64, // 阈值：空闲（毫秒），<=0 关闭
	max_output:     i64, // 阈值：输出字节，0 关闭
	max_exec_ms:    i64, // 阈值：墙钟（毫秒），<=0 关闭
	process:        os.Process, // 被监视的子进程
	job:            rawptr, // Windows Job 句柄
	start_tick:     time.Tick, // 开始时刻
}

// 一次生成代码执行的结果。
ExecResult :: struct {
	output:       string, // 回填给模型的执行输出（stdout+stderr，必要时截断）
	exit_code:    int,
	has_final:    bool, // 生成代码里设了 FINAL / FINAL_FILE
	final_answer: string, // has_final 时的最终答案
	feedback:     string, // 看门狗命中时的结构化反馈（空 = 未命中）
}

// 生成代码执行器。字段来自 Ctx；接口固定，未来可换 SandboxExecutor。
Executor :: struct {
	workdir:            string, // 生成代码的工作目录（空 = 继承当前目录）
	vars:               []string, // 额外环境变量（k=v），经 wrapper export 传入
	inactivity_timeout: int, // 秒；<=0 关闭
	max_output_size:    int, // 字节；0 关闭
	max_exec_time:      int, // 秒；<=0 关闭
}

default_executor :: proc() -> Executor {
	ex: Executor
	ex.inactivity_timeout = DEFAULT_INACTIVITY_TIMEOUT
	ex.max_output_size = DEFAULT_MAX_OUTPUT_SIZE
	ex.max_exec_time = DEFAULT_MAX_EXEC_TIME
	return ex
}

// ---- 看门狗 ----

watchdog_worker :: proc(state: ^WatchState) {
	// 看门狗跑在独立线程：只能用原子量，不能用 temp allocator（线程本地）。
	for !sync.atomic_load(&state.stop) {
		time.sleep(50 * time.Millisecond)
		if sync.atomic_load(&state.stop) {
			break
		}
		elapsed := i64(time.duration_milliseconds(time.tick_since(state.start_tick)))
		hit := WATCH_NONE
		if state.max_exec_ms > 0 && elapsed > state.max_exec_ms {
			hit = WATCH_WALL
		} else if state.inactivity_ms > 0 &&
		   elapsed - sync.atomic_load(&state.last_output_ms) > state.inactivity_ms {
			hit = WATCH_INACTIVITY
		} else if state.max_output > 0 && sync.atomic_load(&state.total_bytes) > state.max_output {
			hit = WATCH_OUTPUT
		}
		if hit != WATCH_NONE {
			state.reason = hit
			sync.atomic_store(&state.killed, true)
			// 关掉 Job 句柄即杀整棵进程树，否则孙进程仍持有管道、读取不返回 EOF。
			if state.job != nil {
				winjob_terminate(state.job)
			}
			_ = os.process_terminate(state.process)
			return
		}
	}
}

// 看门狗反馈文本（中文，回填给模型，帮助它改变策略）。
watch_feedback :: proc(reason: int) -> string {
	switch reason {
	case WATCH_INACTIVITY:
		return "命令长时间没有任何输出，已被空闲看门狗终止。若命令在等待输入（密码、确认）或交互式运行，" +
			"请改为非交互方式（例如给命令加 --yes / -y，或显式用 </dev/null 重定向 stdin）；" +
			"若命令确实很慢，请分步执行或后台运行后轮询。"
	case WATCH_OUTPUT:
		return "命令输出量超过上限，已被看门狗终止。请缩小输出（例如 head/tail/grep 过滤）后重试。"
	case WATCH_WALL:
		return "命令运行超过墙钟上限，已被看门狗终止。请分步执行或后台运行后轮询。"
	case:
		return ""
	}
}

// ---- 定位解释器 ----

// 定位 bash：Windows 用 Git Bash，POSIX 用 /bin/bash；找不到回退 PATH 里的 bash。
find_bash :: proc() -> string {
	when ODIN_OS == .Windows {
		candidates := [?]string{
			"C:/Program Files/Git/bin/bash.exe",
			"C:/Program Files/Git/usr/bin/bash.exe",
			"C:/Program Files (x86)/Git/bin/bash.exe",
		}
		for c in candidates {
			if os.exists(c) {
				return c
			}
		}
		return "bash"
	} else {
		if os.exists("/bin/bash") {
			return "/bin/bash"
		}
		return "bash"
	}
}

// 临时文件路径（每次执行一个）。
make_temp_path :: proc(stem, ext: string) -> string {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	return fmt.aprintf("%s/llmcli_%s_%d.%s", dir, stem, time.now()._nsec, ext,
	                   allocator = context.temp_allocator)
}

// 单引号字符串转义（用于 export NAME='...'）。
shell_single_quote :: proc(value: string) -> string {
	escaped, _ := strings.replace_all(value, "'", "'\\''", context.temp_allocator)
	return fmt.aprintf("'%s'", escaped, allocator = context.temp_allocator)
}

// ---- bash 包装脚本 ----

// 结构：set -e → exec </dev/null → 可选 cd → 可选 export → set -x → 模型代码 →
//       set +x → set +e → 按「是否设置」捕获 FINAL_FILE（优先）/ FINAL。
build_bash_script :: proc(ex: ^Executor, code, final_path: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "set -e\n")
	// 子进程 stdin 接 /dev/null：交互式命令（input/read/密码提示）立即 EOF，不挂。
	strings.write_string(&sb, "exec < /dev/null\n")
	if ex.workdir != "" {
		fmt.sbprintf(&sb, "cd %s || exit 1\n", shell_single_quote(slashify(ex.workdir)))
	}
	for v in ex.vars {
		name := v
		value := ""
		if eq := strings.index_byte(v, '='); eq >= 0 {
			name = v[:eq]
			value = v[eq + 1:]
		}
		fmt.sbprintf(&sb, "export %s=%s\n", name, shell_single_quote(value))
	}
	strings.write_string(&sb, "set -x\n")
	strings.write_string(&sb, code)
	if !strings.has_suffix(code, "\n") {
		strings.write_byte(&sb, '\n')
	}
	// 关闭 xtrace 再捕获，避免捕获逻辑自身的 trace 混进输出
	strings.write_string(&sb, "set +x\n")
	strings.write_string(&sb, "set +e\n")
	fmt.sbprintf(&sb, "_llmcli_final=%s\n", shell_single_quote(slashify(final_path)))
	strings.write_string(&sb,
		"if [ -n \"${FINAL_FILE+x}\" ]; then\n" +
		"  if [ -f \"$FINAL_FILE\" ]; then cat \"$FINAL_FILE\" > \"$_llmcli_final\"; fi\n" +
		"elif [ -n \"${FINAL+x}\" ]; then\n" +
		"  printf '%s' \"$FINAL\" > \"$_llmcli_final\"\n" +
		"fi\n")
	return strings.to_string(sb)
}

// 剥离 xtrace 行（`+ ` 前缀）——只是 `set -x` 的调试噪音，不进 trajectory。
strip_xtrace :: proc(text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	lines := strings.split(text, "\n", context.temp_allocator)
	first := true
	for line in lines {
		if len(line) >= 2 && line[0] == '+' && line[1] == ' ' {
			continue
		}
		if !first {
			strings.write_byte(&sb, '\n')
		}
		first = false
		strings.write_string(&sb, line)
	}
	return strings.to_string(sb)
}

// ---- 执行 ----

// 一次子进程执行的原始采集结果。
Collected :: struct {
	raw:       string, // stdout+stderr 合并原始输出（未剥离 xtrace、未截断）
	exit_code: int,
	failed:    bool, // 管道/启动失败（区别于命令自身非零退出）
	killed:    bool,
	reason:    int,
}

// 子进程执行与采集：spawn → 关 stdin → 挂 Job → 起看门狗 → 读合并输出 → join → 等退出。
collect_process :: proc(command: []string, ex: ^Executor) -> Collected {
	c: Collected
	r, w, perr := os.pipe()
	if perr != nil {
		c.raw = fmt.aprintf("创建管道失败：%v", perr, allocator = context.temp_allocator)
		c.failed = true
		c.exit_code = -1
		return c
	}

	desc := os.Process_Desc{
		command = command,
		env     = nil, // nil = 继承当前进程环境（子进程需要 PATH）
		stdin   = nil, // 关掉 stdin（等效 /dev/null）
		stdout  = w,
		stderr  = w, // 合并 stdout+stderr 到同一条管道
	}
	process, serr := os.process_start(desc)
	if serr != nil {
		os.close(r)
		os.close(w)
		c.raw = fmt.aprintf("启动 bash 失败（%s）：%v", command[0], serr, allocator = context.temp_allocator)
		c.failed = true
		c.exit_code = -1
		return c
	}
	os.close(w)

	job := winjob_create_and_assign(process.handle)
	if job == nil {
		when ODIN_OS == .Windows {
			log_warn("无法把子进程挂进 Job Object，中断时可能留下孙进程")
		}
	}

	g_active_process = process
	g_active_has_process = true
	g_active_job = job

	state: WatchState
	sync.atomic_store(&state.stop, false)
	sync.atomic_store(&state.killed, false)
	sync.atomic_store(&state.total_bytes, i64(0))
	sync.atomic_store(&state.last_output_ms, i64(0))
	state.reason = WATCH_NONE
	state.inactivity_ms = ex.inactivity_timeout > 0 ? i64(ex.inactivity_timeout) * 1000 : 0
	state.max_output = ex.max_output_size > 0 ? i64(ex.max_output_size) : 0
	state.max_exec_ms = ex.max_exec_time > 0 ? i64(ex.max_exec_time) * 1000 : 0
	state.process = process
	state.job = job
	state.start_tick = time.tick_now()

	watcher := thread.create_and_start_with_poly_data(&state, watchdog_worker)

	// 读合并输出（本线程）。每读到一块就刷新看门狗的“最近输出”与“累计字节”。
	out := make([dynamic]byte, 0, 8192, context.temp_allocator)
	buf: [8192]byte
	for {
		n, _ := os.read(r, buf[:])
		if n <= 0 {
			break
		}
		append(&out, ..buf[:n])
		sync.atomic_store(&state.last_output_ms,
		                  i64(time.duration_milliseconds(time.tick_since(state.start_tick))))
		sync.atomic_add(&state.total_bytes, i64(n))
	}
	os.close(r)

	sync.atomic_store(&state.stop, true)
	thread.join(watcher)
	thread.destroy(watcher)

	ws, _ := os.process_wait(process)
	g_active_has_process = false
	if g_active_job != nil {
		winjob_terminate(g_active_job)
		g_active_job = nil
	}

	c.exit_code = ws.exit_code
	c.killed = sync.atomic_load(&state.killed)
	c.reason = state.reason
	// Windows 上被 Job 关闭杀死的进程可能报 exit 0；看门狗命中一律按失败处理。
	if c.killed && c.exit_code == 0 {
		c.exit_code = -1
	}
	c.raw = string(out[:])
	return c
}

// 截断与回填文本：剥 xtrace（可选）→ 超 2000 行截断为末 2000 行、完整输出落盘 →
// 前面可加反馈 → 非零退出码附 [exit N]。返回 temp 上的串。
finalize_output :: proc(c: ^Collected, strip_trace: bool, feedback: string) -> string {
	full := strip_trace ? strip_xtrace(c.raw) : c.raw
	if strings.trim_space(full) == "" {
		full = ""
	}

	output_file := ""
	truncated := false
	lines := strings.split(full, "\n", context.temp_allocator)
	line_count := len(lines)
	if line_count > 0 && lines[line_count - 1] == "" {
		line_count -= 1
	}
	if line_count > OUTPUT_LINE_LIMIT {
		truncated = true
		if tmp, terr := os.temp_directory(context.temp_allocator); terr == nil {
			path := fmt.aprintf("%s/llmcli_output_%d.txt", tmp, time.now()._nsec,
			                    allocator = context.temp_allocator)
			if err := os.write_entire_file_from_string(path, full); err != nil {
				log_warn("执行输出落盘失败：%v", err)
			} else {
				output_file = path
			}
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	if feedback != "" {
		fmt.sbprintf(&sb, "[%s]\n", feedback)
	}
	start := truncated ? line_count - OUTPUT_LINE_LIMIT : 0
	for i in start ..< line_count {
		fmt.sbprintf(&sb, "%s\n", lines[i])
	}
	if truncated {
		if output_file != "" {
			fmt.sbprintf(&sb, "... (truncated, full output stored at %s)\n", output_file)
		} else {
			strings.write_string(&sb, "... (truncated)\n")
		}
	}
	if c.exit_code != 0 {
		fmt.sbprintf(&sb, "[exit %d]\n", c.exit_code)
	}
	return strings.to_string(sb)
}

// 读回 FINAL 临时文件（存在即 has_final），随后删除。
read_final :: proc(exec: ^ExecResult, final_path: string) {
	if !os.exists(final_path) {
		return
	}
	data, err := os.read_entire_file_from_path(final_path, context.temp_allocator)
	if err != nil {
		log_warn("读取 FINAL 临时文件失败：%v", err)
	} else {
		exec.has_final = true
		exec.final_answer = string(data)
	}
	_ = os.remove(final_path)
}

// Executor 入口：执行一段生成代码，返回结果。
executor_run :: proc(ex: ^Executor, code: string) -> ExecResult {
	exec: ExecResult
	final_path := make_temp_path("final", "txt")
	script_path := make_temp_path("script", "sh")
	defer _ = os.remove(script_path)

	script := build_bash_script(ex, code, final_path)
	if err := os.write_entire_file_from_string(script_path, script); err != nil {
		exec.output = fmt.aprintf("写入临时脚本失败：%v", err, allocator = context.temp_allocator)
		exec.exit_code = -1
		return exec
	}

	log_info("[bash] 执行生成代码：\n%s", code)

	command := []string{find_bash(), script_path}
	c := collect_process(command, ex)
	if c.failed {
		exec.output = fmt.aprintf("%s（Windows 需安装 Git Bash；POSIX 需 /bin/bash）", c.raw,
		                          allocator = context.temp_allocator)
		exec.exit_code = -1
		return exec
	}
	if c.killed {
		exec.feedback = watch_feedback(c.reason)
	}
	exec.output = finalize_output(&c, true, exec.feedback)
	exec.exit_code = c.exit_code
	read_final(&exec, final_path)
	_ = os.remove(final_path)
	return exec
}
