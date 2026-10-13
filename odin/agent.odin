package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ---- 分节 ----
// RLM 主循环（后续阶段填充）。当前只放代码块提取，其余见 tmp/odin-port-todo.md。

// ---- 类型 ----

// 从模型回复里取出的第一个代码块。code 在 context.temp_allocator 上。
Extract :: struct {
	code:      string, // 第一个代码块的内容；没有代码块时为空
	has_code:  bool,   // 是否真的找到了代码块（与 code 为空区分：空代码块 has_code=true）
	truncated: bool,   // 第一个代码块之后还有其他代码块（只执行第一个）
}

// ---- 代码块提取 ----

// 行级扫描：围栏行开块，之后第一条 trim 后恰为 ``` 的行闭块（heredoc 内除外）。
// 围栏形态：整行以 ``` 开头（含裸 ```、```bash、```sh），或 ```bash/```sh 缀在散文行末。
// 代码块内以 ``` 开头的行不当作闭块（避免代码里嵌 markdown 时早闭）。
// heredoc 感知：块内 `<<EOF` 开启、直到分隔符行结束，其间的 ``` 不闭块。
extract_code :: proc(response: string) -> Extract {
	out: Extract
	collected := make([dynamic]string, 0, 16, context.temp_allocator)
	lines := strings.split(response, "\n", context.temp_allocator)

	in_block := false
	closed := false
	heredoc := ""
	for line in lines {
		trimmed := strings.trim_space(line)
		rtrimmed := strings.trim_right_space(line)
		fence := strings.has_prefix(trimmed, "```") ||
			strings.has_suffix(rtrimmed, "```bash") || strings.has_suffix(rtrimmed, "```sh")

		if closed {
			if fence {
				out.truncated = true
			}
			continue
		}

		if !in_block {
			if fence {
				in_block = true
				out.has_code = true
			}
			continue
		}

		// heredoc 内：直到分隔符行，一律当代码
		if heredoc != "" {
			if trimmed == heredoc {
				heredoc = ""
			}
			append(&collected, line)
			continue
		}
		marker := heredoc_marker(line)
		if marker != "" {
			heredoc = marker
			append(&collected, line)
			continue
		}

		// 精确的闭围栏才收尾；块内其他 ``` 行当代码原样保留
		if trimmed == "```" {
			in_block = false
			closed = true
			continue
		}
		append(&collected, line)
	}

	if out.has_code {
		for len(collected) > 0 && strings.trim_space(collected[len(collected) - 1]) == "" {
			pop(&collected)
		}
		body := strings.builder_make(context.temp_allocator)
		for line in collected {
			strings.write_string(&body, line)
			strings.write_byte(&body, '\n')
		}
		out.code = strings.to_string(body)
	}
	return out
}

// 从一行里识别 heredoc 起始标记（`<<EOF` / `<<-EOF` / `<<"EOF"` / `<<'EOF'`）。
heredoc_marker :: proc(line: string) -> string {
	pos := strings.index(line, "<<")
	if pos < 0 {
		return ""
	}
	i := pos + 2
	if i < len(line) && line[i] == '-' {
		i += 1
	}
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	if i >= len(line) {
		return ""
	}
	rest := line[i:]
	first := rest[0]
	if first == '\'' || first == '"' {
		close := strings.index_byte(rest[1:], first)
		if close >= 0 {
			return rest[1:1 + close]
		}
		return ""
	}
	end := 0
	for end < len(rest) && rest[end] != ' ' && rest[end] != '\t' {
		end += 1
	}
	if end == 0 {
		return ""
	}
	return rest[:end]
}

// ---- 主循环 ----

// 空响应重试上限：--thinking 时模型可能把预算花在思维链上、可见文本为空。
EMPTY_RETRY_LIMIT :: 8

// stall guard：连续 N 次非零退出，或同一条失败命令重复 M 次，即中止。
STALL_CONSECUTIVE :: 5
STALL_REPEAT :: 3

// 一次运行的可变会话状态。
RunState :: struct {
	traj:                Trajectory,
	run_id:              string, // 本次 run 的 id（同一轨迹可续跑多次 run）
	policy:              RenderPolicy,
	executor:            Executor,
	llm:                 Llm,
	iteration:           int,
	consecutive_failures: int,
	repeat_count:        int,
	last_failing_code:   string,
	empty_retries:       int,
}

// 父轨迹坐标（子代理用）：非空则本进程是子代理。
g_parent_root: string
g_parent_name: string

// 一次运行（一条 trajectory）。traj_id 非空则续接既有轨迹，否则新建。
agent_run :: proc(ctx: ^Ctx) -> int {
	st: RunState
	st.policy = default_policy()
	apply_policy_overrides(&st.policy, ctx)
	st.executor = default_executor()
	apply_executor_overrides(&st.executor, ctx)
	st.llm = Llm{api_url = ctx.api_url, api_key = ctx.api_key, model = ctx.model}

	st.traj = open_trajectory(ctx)
	if st.traj.path == "" {
		log_error("无法建立轨迹")
		return EXIT_FAILURE
	}
	// 轨迹坐标活过整个 run：拷到 context.allocator（默认堆），不随临时分配回收。
	st.traj.root = clone_heap(st.traj.root)
	st.traj.name = clone_heap(st.traj.name)
	st.traj.id = clone_heap(st.traj.id)
	st.traj.path = clone_heap(st.traj.path)
	// 本次 run 的 id 独立于轨迹 id：续跑同一轨迹时是新的 run，用于 run 作用域渲染。
	st.run_id = clone_heap(traj_new_run_id())
	if ctx.context_scope == "run" {
		st.policy.run = st.run_id
	}

	// 轨迹头两步：shellm-run（元数据）+ prompt（本次输入）。
	traj_append(&st.traj, Step{
		type = T_SHELLM_RUN, run_id = st.run_id, command = ctx.user_input,
		workdir = ctx.workdir, model = ctx.model, max_iterations = ctx.max_iterations,
	})
	traj_append(&st.traj, Step{type = T_PROMPT, run_id = st.run_id, content = ctx.user_input})

	// 把轨迹坐标作为环境变量暴露给生成代码（$TRAJ_DIR/$TRAJ_ID 等）。
	st.executor.vars = prepend_traj_vars(&st.traj, ctx)

	register_parent(&st)

	scope_note := ctx.context_scope != "" ? fmt.aprintf("，scope=%s", ctx.context_scope) : ""
	limit_note := ctx.max_iterations > 0 ? fmt.aprintf("，max-iterations=%d", ctx.max_iterations) : ""
	log_info("Trace 开始 traj=%s，model=%s%s%s", st.traj.name, ctx.model, limit_note, scope_note)

	rc := agent_loop(&st, ctx)
	traj_append(&st.traj, Step{
		type = T_RUN_SUMMARY, run_id = st.run_id,
		content = fmt.aprintf("iterations=%d exit=%d", st.iteration, rc, allocator = context.temp_allocator),
	})
	write_merge(&st)
	return rc
}

agent_loop :: proc(st: ^RunState, ctx: ^Ctx) -> int {
	for {
		st.iteration += 1
		if ctx.max_iterations > 0 && st.iteration > ctx.max_iterations {
			exit_with_error(st, "max_iterations", "达到 --max-iterations=%d 上限，停止循环（未收敛）",
			                ctx.max_iterations)
			return EXIT_UNCONVERGED
		}

		mark := time.tick_now()
		// 每轮从 trajectory 重渲染 messages
		messages := context_render(&st.traj, &st.policy)
		resp := llm_call(&st.llm, ctx.system_prompt, messages[:])
		if !resp.ok {
			exit_with_error(st, "api", "%s", resp.error)
			return EXIT_FAILURE
		}

		log_info("[iter %d] 响应, %dms%s", st.iteration, elapsed_ms(&mark),
		         format_reasoning(resp.reasoning, resp.usage))
		if resp.reasoning != "" {
			log_debug("reasoning_content: %s", resp.reasoning)
		}

		// 空响应重试：把 thinking 回填 + 一句「继续」
		if resp.text == "" {
			st.empty_retries += 1
			if st.empty_retries > EMPTY_RETRY_LIMIT {
				exit_with_error(st, "empty_response", "连续 %d 次空响应，循环未收敛", EMPTY_RETRY_LIMIT)
				return EXIT_UNCONVERGED
			}
			log_warn("响应内容为空（第 %d 次），回填上下文后重试", st.empty_retries)
			if resp.reasoning != "" {
				traj_append(&st.traj, Step{
					type = T_REASONING, run_id = st.run_id,
					thought = resp.reasoning, reasoning_content = resp.reasoning,
				})
			}
			traj_append(&st.traj, Step{type = T_FEEDBACK, run_id = st.run_id, content = "继续。"})
			continue
		}
		st.empty_retries = 0

		extracted := extract_code(resp.text)

		// 没有代码块：整个回复就是最终答案（单轮问答走这条兜底）
		if !extracted.has_code {
			if resp.reasoning != "" {
				traj_append(&st.traj, Step{
					type = T_REASONING, run_id = st.run_id, reasoning_content = resp.reasoning,
				})
			}
			traj_append(&st.traj, Step{type = T_FINAL, run_id = st.run_id, content = resp.text})
			print_answer(resp.text)
			log_info("Trace 结束，共 %d iter", st.iteration)
			return EXIT_OK
		}
		if extracted.truncated {
			log_warn("回复含多个代码块，只执行第一个（其余丢弃）")
		}

		// 决策入 trajectory：reasoning（散文 + 代码原文 + 模型思维链存档）
		traj_append(&st.traj, Step{
			type = T_REASONING, run_id = st.run_id, thought = extract_reasoning(resp.text),
			cmd = extracted.code, reasoning_content = resp.reasoning,
		})

		exec_mark := time.tick_now()
		exec := executor_run(&st.executor, extracted.code)
		log_info("[iter %d] 执行 -> exit %d, %dms", st.iteration, exec.exit_code, elapsed_ms(&exec_mark))

		traj_append(&st.traj, Step{
			type = T_SHELL_OUTPUT, run_id = st.run_id,
			stdout = exec.output != "" ? exec.output : "（无输出）",
			exit = exec.exit_code, feedback = exec.feedback,
		})

		if exec.has_final {
			traj_append(&st.traj, Step{type = T_FINAL, run_id = st.run_id, content = exec.final_answer})
			print_answer(exec.final_answer)
			log_info("Trace 结束，共 %d iter", st.iteration)
			return EXIT_OK
		}

		if stall_guard(st, &exec, extracted.code) {
			exit_with_error(st, "stall", "连续失败（%d 次非零退出 / 同一失败命令重复 %d 次），中止以避免空转",
			                st.consecutive_failures, st.repeat_count)
			return EXIT_UNCONVERGED
		}
	}
}

// stall guard：更新计数并在越界时返回 true。
stall_guard :: proc(st: ^RunState, exec: ^ExecResult, code: string) -> bool {
	if exec.exit_code == 0 {
		st.consecutive_failures = 0
		st.repeat_count = 0
		st.last_failing_code = ""
		return false
	}
	st.consecutive_failures += 1
	if code == st.last_failing_code {
		st.repeat_count += 1
	} else {
		st.repeat_count = 1
		st.last_failing_code = clone_heap(code)
	}
	return st.consecutive_failures >= STALL_CONSECUTIVE || st.repeat_count >= STALL_REPEAT
}

// ---- 轨迹打开 ----

open_trajectory :: proc(ctx: ^Ctx) -> Trajectory {
	if ctx.traj_id != "" {
		return traj_open_resume(ctx.traj_id)
	}
	if ctx.resume {
		all := traj_list_all()
		if len(all) > 0 {
			return traj_open_resume(all[len(all) - 1].name)
		}
	}
	return traj_open_new(slug_from(ctx.user_input))
}

// 用输入的首行做一个可读 slug。
slug_from :: proc(input: string) -> string {
	first := strings.trim_space(input)
	if nl := strings.index_byte(first, '\n'); nl >= 0 {
		first = first[:nl]
	}
	if len(first) > 32 {
		first = first[:32]
	}
	if first == "" {
		return "run"
	}
	return first
}

// ---- 策略/执行器覆盖 ----

apply_policy_overrides :: proc(policy: ^RenderPolicy, ctx: ^Ctx) {
	if ctx.max_bytes != 0 {
		policy.max_bytes = ctx.max_bytes
	}
}

apply_executor_overrides :: proc(ex: ^Executor, ctx: ^Ctx) {
	if ctx.workdir != "" { ex.workdir = ctx.workdir }
	if ctx.inactivity_timeout != 0 { ex.inactivity_timeout = ctx.inactivity_timeout }
	if ctx.max_output_size != 0 { ex.max_output_size = ctx.max_output_size }
	if ctx.max_exec_time != 0 { ex.max_exec_time = ctx.max_exec_time }
}

prepend_traj_vars :: proc(traj: ^Trajectory, ctx: ^Ctx) -> []string {
	all := make([dynamic]string, 0, 8 + len(ctx.vars), context.allocator)
	append(&all, fmt.aprintf("TRAJ_DIR=%s", traj.root))
	append(&all, fmt.aprintf("TRAJ_ID=%s", traj.name))
	// 父轨迹坐标：生成代码若起子代理，子进程据此在父轨迹写 fork/merge。
	append(&all, fmt.aprintf("LLMCLI_PARENT_TRAJ_DIR=%s", traj.root))
	append(&all, fmt.aprintf("LLMCLI_PARENT_TRAJ_ID=%s", traj.name))
	append(&all, fmt.aprintf("MODEL=%s", ctx.model))
	append(&all, fmt.aprintf("API_KEY=%s", ctx.api_key))
	append(&all, fmt.aprintf("API_URL=%s", ctx.api_url))
	append(&all, ..ctx.vars)
	return all[:]
}

// ---- 子代理 fork/merge ----

register_parent :: proc(st: ^RunState) {
	proot := os.get_env_alloc("LLMCLI_PARENT_TRAJ_DIR", context.temp_allocator)
	pname := os.get_env_alloc("LLMCLI_PARENT_TRAJ_ID", context.temp_allocator)
	if proot == "" || pname == "" {
		return
	}
	g_parent_root = clone_heap(proot)
	g_parent_name = clone_heap(pname)
	parent := traj_open_at(g_parent_root, g_parent_name)
	traj_append(&parent, Step{type = T_FORK, child = st.traj.id, slug = st.traj.name})
	log_info("本进程为子代理，已在父轨迹 %s 写 fork 步骤", g_parent_name)
}

write_merge :: proc(st: ^RunState) {
	if g_parent_root == "" {
		return
	}
	parent := traj_open_at(g_parent_root, g_parent_name)
	traj_append(&parent, Step{type = T_MERGE, from_traj = st.traj.id})
}

// ---- 小工具 ----

clone_heap :: proc(s: string) -> string {
	if s == "" {
		return ""
	}
	return strings.clone(s, context.allocator)
}

exit_with_error :: proc(st: ^RunState, reason, format: string, args: ..any) {
	message := fmt.aprintf(format, ..args, allocator = context.temp_allocator)
	log_error("%s", message)
	traj_append(&st.traj, Step{type = T_ERROR, run_id = st.run_id, content = message, reason = reason})
}

// 回复里的散文部分（第一个代码块之前），作为 reasoning 的 thought。
extract_reasoning :: proc(response: string) -> string {
	if fence := strings.index(response, "```"); fence >= 0 {
		return strings.trim_right_space(response[:fence])
	}
	return strings.trim_right_space(response)
}

print_answer :: proc(content: string) {
	fmt.print(content)
	if !strings.has_suffix(content, "\n") {
		fmt.println("")
	}
}

elapsed_ms :: proc(mark: ^time.Tick) -> int {
	return int(time.duration_milliseconds(time.tick_since(mark^)))
}

format_reasoning :: proc(reasoning, usage: string) -> string {
	if reasoning == "" && usage == "" {
		return ""
	}
	reason := reasoning != "" ? fmt.aprintf("，reasoning %d 字符", len(reasoning), allocator = context.temp_allocator) : ""
	sep := usage != "" ? "，" : ""
	return fmt.aprintf("%s%s%s", reason, sep, usage, allocator = context.temp_allocator)
}
