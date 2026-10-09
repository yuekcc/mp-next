module llmcli::agent;

import std::io, std::os::env, std::time, std::time::clock;
import std::collections::list;
import llmcli::buf, llmcli::chat, llmcli::cli, llmcli::context, llmcli::llm, llmcli::log,
	llmcli::runtime, llmcli::trajectory;

// ---- 分节 ----
// 本模块是 RLM 主循环（doc 5）：trajectory 是唯一真相源，每轮从它重渲染 messages，
// 调 Llm，从回复取代码块，交 Executor 执行，把输出写回 trajectory，直到代码设了
// FINAL / FINAL_FILE（或回复里没有代码块，则整段回复即答案）。
//
// 内存：消息是投影不是状态——每轮 Context.render 从 trajectory 重建，进度不保存在内存。
// 每轮临时数据走 tmem，由循环上的 @pool() 回收。

// ---- 常量 ----

// 空响应重试上限（doc 5.1）：--thinking 时模型可能把预算花在思维链上、可见文本为空。
const int EMPTY_RETRY_LIMIT = 8;

// stall guard（doc 5.3）：连续 N 次非零退出，或同一条失败命令重复 M 次，即中止。
const int STALL_CONSECUTIVE = 5;
const int STALL_REPEAT = 3;

// ---- 类型 ----

// 从模型回复里取出的第一个代码块。code 在 mem 上，由调用方释放。
struct Extract
{
	String code;      // 第一个代码块的内容；没有代码块时为空
	bool has_code;    // 是否真的找到了代码块（与 code 为空区分：空代码块 has_code=true）
	bool truncated;   // 第一个代码块之后还有其他代码块（只执行第一个）
}

// 一次运行的可变会话状态。run 内创建一次，随 Ctx 进、随本次 Trace 出。
struct RunState
{
	trajectory::Trajectory traj;
	String run_id;             // 本次 run 的 id（与 traj.id 不同：同一轨迹可续跑多次 run）
	context::RenderPolicy policy;
	runtime::Executor executor;
	llm::Llm llm;
	int iteration;             // 已发起的请求数（与 stderr 的 [iter N] 一致）
	int consecutive_failures;  // 连续非零退出计数（stall guard）
	int repeat_count;          // 同一条失败命令重复计数
	String last_failing_code;
	int empty_retries;         // 空响应重试计数
}

// ---- 主循环 ----

// 一次运行（一条 trajectory）。traj_id 非空则续接既有轨迹，否则新建。
fn int run(cli::Ctx* ctx)
{
	RunState st;
	st.policy = context::default_policy();
	apply_policy_overrides(&st.policy, ctx);
	st.executor = runtime::default_executor();
	apply_executor_overrides(&st.executor, ctx);
	st.llm = {
		.api_url = ctx.api_url,
		.api_key = ctx.api_key,
		.model = ctx.model,
		.effort = ctx.effort,
	};

	st.traj = open_trajectory(ctx);
	if (!st.traj.path.len)
	{
		log::error("无法建立轨迹");
		return cli::EXIT_FAILURE;
	}
	// 主循环每轮 @pool 会回收 tmem；轨迹坐标必须活过整个 run，拷到 mem。
	st.traj.root = st.traj.root.copy(mem);
	st.traj.name = st.traj.name.copy(mem);
	st.traj.id = st.traj.id.copy(mem);
	st.traj.path = st.traj.path.copy(mem);
	// 本次 run 的 id 独立于轨迹 id：续跑同一轨迹时是新的 run，用于 run 作用域渲染。
	st.run_id = trajectory::new_run_id(mem);
	if (ctx.context_scope == "run") st.policy.run = st.run_id;

	// 轨迹头两步：shellm-run（元数据）+ prompt（本次输入）。
	trajectory::append(&st.traj, {
		.type = trajectory::T_SHELLM_RUN,
		.run_id = st.run_id,
		.command = ctx.user_input,
		.workdir = ctx.workdir,
		.model = ctx.model,
		.max_iterations = ctx.max_iterations,
	});
	trajectory::append(&st.traj, {
		.type = trajectory::T_PROMPT,
		.run_id = st.run_id,
		.content = ctx.user_input,
	});

	// 把轨迹坐标作为环境变量暴露给生成代码（$TRAJ_DIR/$TRAJ_ID），供自省与起子 run。
	st.executor.vars = prepend_traj_vars(&st.traj, ctx.vars);

	// 子 run（doc 7）：若父进程通过 LLMCLI_PARENT_TRAJ_* 交代了父轨迹，则本进程是一条
	// 子 run——在父轨迹上写 fork 步骤，结束时写 merge。
	register_parent(&st);

	String scope_note = ctx.context_scope.len ? string::tformat("，scope=%s", ctx.context_scope) : "";
	String limit_note = ctx.max_iterations > 0 ? string::tformat("，max-iterations=%d", ctx.max_iterations) : "";
	log::info("Trace 开始 traj=%s，model=%s%s%s", st.traj.name, ctx.model, limit_note, scope_note);

	int rc = loop(&st, ctx);
	trajectory::append(&st.traj, {
		.type = trajectory::T_RUN_SUMMARY,
		.run_id = st.run_id,
		.content = string::format(tmem, "iterations=%d exit=%d", st.iteration, rc),
	});
	write_merge(&st);
	return rc;
}

// 父轨迹坐标（子 run 用）：非空则本进程是子 run。
String parent_root @private;
String parent_name @private;

fn void register_parent(RunState* st) @private
{
	String proot = env_var("LLMCLI_PARENT_TRAJ_DIR");
	String pname = env_var("LLMCLI_PARENT_TRAJ_ID");
	if (!proot.len || !pname.len) return;
	parent_root = proot.copy(mem);
	parent_name = pname.copy(mem);

	// 在父轨迹写 fork 步骤，child = 本子 run 的 id。
	trajectory::Trajectory parent = trajectory::open_at(parent_root, parent_name);
	trajectory::append(&parent, {
		.type = trajectory::T_FORK,
		.child = st.traj.id,
		.slug = st.traj.name,
	});
	log::info("本进程为子 run，已在父轨迹 %s 写 fork 步骤", parent_name);
}

fn void write_merge(RunState* st) @private
{
	if (!parent_root.len) return;
	trajectory::Trajectory parent = trajectory::open_at(parent_root, parent_name);
	trajectory::append(&parent, {
		.type = trajectory::T_MERGE,
		.from_traj = st.traj.id,
	});
}

fn String env_var(String name) @private
{
	if (try v = env::tget_var(name)) return v;
	return "";
}

// 主循环体。
fn int loop(RunState* st, cli::Ctx* ctx)
{
	while LOOP: (true) @pool()
	{
		st.iteration++;
		if (ctx.max_iterations > 0 && st.iteration > ctx.max_iterations)
		{
			exit_with_error(st, "max_iterations", "达到 --max-iterations=%d 上限，停止循环（未收敛）",
			                ctx.max_iterations);
			return cli::EXIT_UNCONVERGED;
		}

		Clock mark = clock::now();
		// 每轮从 trajectory 重渲染 messages
		chat::Message[] messages = context::render(tmem, &st.traj, &st.policy);
		llm::Response resp = st.llm.call(ctx.system_prompt, messages);
		if (!resp.ok)
		{
			exit_with_error(st, "api", "%s", resp.error);
			return cli::EXIT_FAILURE;
		}

		log::info("[iter %d] 响应, %dms%s", st.iteration, elapsed_ms(&mark),
		          format_reasoning(resp.reasoning, resp.usage));
		if (resp.reasoning.len) log::debug("reasoning_content: %s", resp.reasoning);

		// 空响应重试（doc 5.1）：把 thinking 回填 + 一句「继续」
		if (!resp.text.len)
		{
			st.empty_retries++;
			if (st.empty_retries > EMPTY_RETRY_LIMIT)
			{
				exit_with_error(st, "empty_response",
				                "连续 %d 次空响应，循环未收敛", EMPTY_RETRY_LIMIT);
				return cli::EXIT_UNCONVERGED;
			}
			log::warn("响应内容为空（第 %d 次），回填上下文后重试", st.empty_retries);
			// doc 5.1：把 thinking 作为 assistant 上下文回填（渲染为 thought 散文），
			// 再加一句「继续」的 user 提示，推动模型产出可见文本。
			// reasoning_content 仍只入存档、绝不作为协议字段回传（渲染只读 thought）。
			// 无 thinking 时只追加反馈，避免落一条空 reasoning（会渲染成空 assistant 消息）。
			if (resp.reasoning.len)
			{
				trajectory::append(&st.traj, {
					.type = trajectory::T_REASONING,
					.run_id = st.run_id,
					.thought = resp.reasoning,
					.reasoning_content = resp.reasoning,
				});
			}
			trajectory::append(&st.traj, {
				.type = trajectory::T_FEEDBACK,
				.run_id = st.run_id,
				.content = "继续。",
			});
			continue;
		}
		st.empty_retries = 0;

		Extract extracted = extract_code(resp.text);

		// 没有代码块：整个回复就是最终答案（单轮问答走这条兜底）
		if (!extracted.has_code)
		{
			// reasoning_content 只入存档、绝不回传；trajectory 就是存档，落一条 reasoning 步骤。
			if (resp.reasoning.len)
			{
				trajectory::append(&st.traj, {
					.type = trajectory::T_REASONING,
					.run_id = st.run_id,
					.reasoning_content = resp.reasoning,
				});
			}
			trajectory::append(&st.traj, {
				.type = trajectory::T_FINAL,
				.run_id = st.run_id,
				.content = resp.text,
			});
			print_answer(resp.text);
			log::info("Trace 结束，共 %d iter", st.iteration);
			return cli::EXIT_OK;
		}
		if (extracted.truncated)
		{
			log::warn("回复含多个代码块，只执行第一个（其余丢弃）");
		}

		// 决策入 trajectory：reasoning（散文 + 代码原文 + 模型思维链存档）
		trajectory::append(&st.traj, {
			.type = trajectory::T_REASONING,
			.run_id = st.run_id,
			.thought = extract_reasoning(resp.text),
			.cmd = extracted.code,
			.reasoning_content = resp.reasoning,
		});

		Clock exec_mark = clock::now();
		runtime::ExecResult exec = st.executor.run(extracted.code);
		log::info("[iter %d] 执行 -> exit %d, %dms", st.iteration, exec.exit_code, elapsed_ms(&exec_mark));

		trajectory::append(&st.traj, {
			.type = trajectory::T_SHELL_OUTPUT,
			.run_id = st.run_id,
			.stdout = exec.output.len ? exec.output : "（无输出）",
			.exit = exec.exit_code,
			.feedback = exec.feedback,
		});

		if (exec.has_final)
		{
			trajectory::append(&st.traj, {
				.type = trajectory::T_FINAL,
				.run_id = st.run_id,
				.content = exec.final_answer,
			});
			print_answer(exec.final_answer);
			log::info("Trace 结束，共 %d iter", st.iteration);
			return cli::EXIT_OK;
		}

		// stall guard（doc 5.3）
		if (stall_guard(st, &exec, extracted.code))
		{
			exit_with_error(st, "stall",
			                "连续失败（%d 次非零退出 / 同一失败命令重复 %d 次），中止以避免空转",
			                st.consecutive_failures, st.repeat_count);
			return cli::EXIT_UNCONVERGED;
		}
	};
}

// stall guard：更新计数并在越界时返回 true。
fn bool stall_guard(RunState* st, runtime::ExecResult* exec, String code)
{
	if (exec.exit_code == 0)
	{
		st.consecutive_failures = 0;
		st.repeat_count = 0;
		st.last_failing_code = "";
		return false;
	}
	st.consecutive_failures++;
	if (code == st.last_failing_code)
	{
		st.repeat_count++;
	}
	else
	{
		st.repeat_count = 1;
		st.last_failing_code = code.copy(mem);
	}
	return st.consecutive_failures >= STALL_CONSECUTIVE || st.repeat_count >= STALL_REPEAT;
}

// ---- 轨迹打开 ----

fn trajectory::Trajectory open_trajectory(cli::Ctx* ctx) @private
{
	// 存放位置只由命令行决定（--traj-dir / --config-dir，见 doc 8），不因环境变量改根。
	// 子 run 的父指针（$LLMCLI_PARENT_TRAJ_*）只用于在父轨迹写 fork/merge，见 register_parent。
	if (ctx.traj_id.len)
	{
		return trajectory::open_resume(ctx.traj_id);
	}
	if (ctx.resume)
	{
		// --resume 未指定 --traj：续接最近一条轨迹（按目录名降序，hex8 近似时间序）。
		trajectory::TrajectorySummary[] all = trajectory::list_all(tmem);
		if (all.len) return trajectory::open_resume(all[all.len - 1].name);
	}
	return trajectory::open_new(slug_from(ctx.user_input));
}

// 用输入的首行做一个可读 slug。
fn String slug_from(String input) @private
{
	String first = input.trim();
	if (try nl = first.index_of_char('\n')) first = first[:nl];
	if (first.len > 32) first = first[:32];
	if (!first.len) return "run";
	return first;
}

// ---- 策略/执行器覆盖 ----

fn void apply_policy_overrides(context::RenderPolicy* policy, cli::Ctx* ctx) @private
{
	if (ctx.max_bytes) policy.max_bytes = ctx.max_bytes;
}

fn void apply_executor_overrides(runtime::Executor* ex, cli::Ctx* ctx) @private
{
	if (ctx.workdir.len) ex.workdir = ctx.workdir;
	if (ctx.inactivity_timeout != 0) ex.inactivity_timeout = ctx.inactivity_timeout;
	if (ctx.max_output_size != 0) ex.max_output_size = ctx.max_output_size;
	if (ctx.max_exec_time != 0) ex.max_exec_time = ctx.max_exec_time;
}

fn String[] prepend_traj_vars(trajectory::Trajectory* traj, String[] vars) @private
{
	List{String} all;
	all.init(mem);
	all.push(string::format(mem, "TRAJ_DIR=%s", traj.root));
	all.push(string::format(mem, "TRAJ_ID=%s", traj.name));
	// 父轨迹坐标：生成代码若调 `llmcli shellm` 起子 run，子进程据此在父轨迹写 fork/merge。
	all.push(string::format(mem, "LLMCLI_PARENT_TRAJ_DIR=%s", traj.root));
	all.push(string::format(mem, "LLMCLI_PARENT_TRAJ_ID=%s", traj.name));
	foreach (v : vars) all.push(v);
	return all.to_array(mem);
}

fn void exit_with_error(RunState* st, String reason, String format, args...) @private
{
	String message = string::tformat(format, ...args);
	log::error("%s", message);
	trajectory::append(&st.traj, {
		.type = trajectory::T_ERROR,
		.run_id = st.run_id,
		.content = message,
		.reason = reason,
	});
}

// ---- 代码块提取 ----

// 行级扫描：围栏行开块，之后第一条 trim 后恰为 ``` 的行闭块（heredoc 内除外）。
// 围栏形态：整行以 ``` 开头（含裸 ```、```bash、```sh），或 ```bash/```sh 缀在散文行末。
// 代码块内以 ``` 开头的行不当作闭块（避免代码里嵌 markdown 时早闭）。
// heredoc 感知：块内 `<<EOF` 开启、直到分隔符行结束，其间的 ``` 不闭块（doc 5.2）。
fn Extract extract_code(String response)
{
	Extract out;
	List{String} body;
	body.init(tmem);

	bool in_block = false;
	bool closed = false;
	String heredoc = "";
	String[] lines = response.split(tmem, "\n");
	foreach (line : lines)
	{
		String trimmed = line.trim();
		String rtrimmed = line.trim_right();
		bool fence = trimmed.starts_with("```")
			|| rtrimmed.ends_with("```bash") || rtrimmed.ends_with("```sh");

		if (closed)
		{
			if (fence) out.truncated = true;
			continue;
		}

		if (!in_block)
		{
			if (fence)
			{
				in_block = true;
				out.has_code = true;
			}
			continue;
		}

		// heredoc 内：直到分隔符行，一律当代码
		if (heredoc.len)
		{
			if (trimmed == heredoc)
			{
				heredoc = "";
			}
			body.push(line);
			continue;
		}
		String marker = heredoc_marker(line);
		if (marker.len)
		{
			heredoc = marker;
			body.push(line);
			continue;
		}

		// 精确的闭围栏才收尾；块内其他 ``` 行当代码原样保留
		if (trimmed == "```")
		{
			in_block = false;
			closed = true;
			continue;
		}
		body.push(line);
	}

	if (out.has_code)
	{
		while (body.len() && body.get((sz)body.len() - 1).trim().len == 0) (void)body.pop();
		DString joined = dstring::new(tmem);
		foreach (line : body)
		{
			joined.append(line);
			joined.append("\n");
		}
		out.code = joined.str_view().copy(mem);
	}

	body.free();
	return out;
}

// 从一行里识别 heredoc 起始标记（`<<EOF` / `<<-EOF` / `<<"EOF"` / `<<'EOF'`）。
fn String heredoc_marker(String line) @private
{
	if (try pos = line.index_of("<<"))
	{
		usz i = (usz)pos + 2;
		if (i < line.len && line[i] == '-') i++;
		while (i < line.len && (line[i] == ' ' || line[i] == '\t')) i++;
		if (i >= line.len) return "";
		String rest = line[i..];
		char first = rest[0];
		if (first == '\'' || first == '"')
		{
			if (try close = rest[1..].index_of_char(first))
			{
				return rest[1..(usz)close + 1];
			}
			return "";
		}
		usz end = 0;
		while (end < rest.len && rest[end] != ' ' && rest[end] != '\t') end++;
		if (!end) return "";
		return rest[:end];
	}
	return "";
}

// 回复里的散文部分（第一个代码块之前），作为 reasoning 的 thought。
fn String extract_reasoning(String response)
{
	if (try fence = response.index_of("```"))
	{
		return response[:fence].trim_right();
	}
	return response.trim_right();
}

// ---- API 往返已并入 llm.c3 ----

// ---- 输出与摘要 ----

fn void print_answer(String content) @private
{
	io::print(content);
	if (!content.ends_with("\n"))
	{
		io::printn("");
	}
}

fn long elapsed_ms(Clock* mark) @private
{
	return mark.mark().to_ms();
}

fn String format_reasoning(String reasoning, String usage) @private
{
	if (!reasoning.len && !usage.len) return "";
	return string::format(tmem, "%s%s%s",
	                      reasoning.len ? string::tformat("，reasoning %d 字符", reasoning.len) : "",
	                      usage.len ? "，" : "",
	                      usage);
}
