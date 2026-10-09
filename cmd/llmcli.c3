module llmcli;

import std::io;
import std::collections::list;
import llmcli::agent, llmcli::cli, llmcli::context, llmcli::http, llmcli::log, llmcli::runtime,
	llmcli::skill, llmcli::trajectory;

// ---- 分节 ----
// main：识别子命令（第一个参数是命令名时）→ 否则走一次真实运行。
// 真实运行：resolve → 初始化日志/脱敏 → 动作短路（help / 用法错误 / list-* /
// print-system-prompt）→ 装中断处理器、起 libcurl → RLM 主循环。

// ---- 动作 ----

fn int list_trajectories()
{
	trajectory::TrajectorySummary[] items = trajectory::list_all(mem);
	if (!items.len)
	{
		io::printn("(没有轨迹)");
		return cli::EXIT_OK;
	}
	foreach (item : items)
	{
		io::printfn("%s\t%s\t%d 步", item.name, item.updated, (int)item.count);
	}
	return cli::EXIT_OK;
}

fn int list_skills()
{
	skill::SkillHub hub;
	hub.init(mem, cli::SKILLS_ASSETS_DIR);
	defer hub.free();

	String brief = hub.print_brief(tmem);
	io::print(brief);
	if (!brief.ends_with("\n")) io::printn("");
	return cli::EXIT_OK;
}

fn int print_system_prompt(cli::Ctx* ctx)
{
	io::print(ctx.system_prompt);
	if (!ctx.system_prompt.ends_with("\n")) io::printn("");
	return cli::EXIT_OK;
}

// ---- 一次真实运行 ----

fn int run_entry(String[] args, bool stdin_ok = true)
{
	cli::ParseResult parsed = cli::resolve(args, stdin_ok);
	trajectory::configure(parsed.ctx.traj_dir, parsed.ctx.config_dir);
	log::init(parsed.ctx.quiet, parsed.ctx.debug, parsed.ctx.no_color);
	log::add_secret(parsed.ctx.api_key);

	if (parsed.ctx.help)
	{
		io::printn(cli::HELP);
		return cli::EXIT_OK;
	}
	if (parsed.error.len)
	{
		log::error("%s", parsed.error);
		io::eprintfn("%s", cli::USAGE);
		io::eprintfn("运行 llmcli --help 查看全部 flags");
		return cli::EXIT_USAGE;
	}
	if (parsed.ctx.list_trajectories) return list_trajectories();
	if (parsed.ctx.list_skills) return list_skills();
	if (parsed.ctx.print_system_prompt) return print_system_prompt(&parsed.ctx);

	runtime::install_interrupt_handler();
	http::http_init();
	defer http::http_deinit();

	return agent::run(&parsed.ctx);
}

// ---- 子命令（doc 7）：单二进制靠第一个参数派发 ----

// 子命令名集合（doc 7）。shellm 等价 bin/shellm；traj/context/skills 是自省工具。
const String[] COMMANDS = { "shellm", "traj", "context", "skills" };

// 命令名位置：跳过子命令也认的全局 flag（目录 / 日志开关）后的第一个 token 才是命令名。
// 这样 `llmcli --traj-dir X traj list` 与 `llmcli traj list` 都成立，而一个恰好叫 "traj"
// 的位置参数 prompt（`llmcli --model m "traj"`）不会被误当命令——它的前一个 token 是
// `--model` 的值，不在允许前缀里。
fn sz command_index(String[] args)
{
	usz i = 1;
	while (i < args.len)
	{
		String a = args[i];
		if (a == "--traj-dir" || a == "--config-dir")
		{
			i += 2;
			continue;
		}
		if (a.starts_with("--traj-dir=") || a.starts_with("--config-dir="))
		{
			i += 1;
			continue;
		}
		if (a == "--quiet" || a == "--debug" || a == "--no-color")
		{
			i += 1;
			continue;
		}
		break;
	}
	if (i >= args.len) return -1;
	foreach (cmd : COMMANDS)
	{
		if (args[i] == cmd) return (sz)i;
	}
	return -1;
}

// llmcli traj list [--children] / show <name> [--full] / tail <name> [n] / search <name> <pattern>
fn int run_traj(String[] args)
{
	if (args.len < 2 || args[1] == "list")
	{
		bool children = false;
		for (usz i = 1; i < args.len; i++)
		{
			if (args[i] == "--children") children = true;
		}
		if (children) return list_children();
		return list_trajectories();
	}
	String verb = args[1];
	bool full = false;
	foreach (a : args)
	{
		if (a == "--full") full = true;
	}
	if (verb == "show" && args.len >= 3)
	{
		trajectory::Trajectory traj = trajectory::open_resume(args[2]);
		traj_print_steps(trajectory::read_all(mem, &traj), full);
		return cli::EXIT_OK;
	}
	if (verb == "tail" && args.len >= 3)
	{
		int n = args.len >= 4 ? (args[3].to_int() ?? 10) : 10;
		trajectory::Trajectory traj = trajectory::open_resume(args[2]);
		traj_print_steps(trajectory::tail(mem, &traj, n), full);
		return cli::EXIT_OK;
	}
	if (verb == "search" && args.len >= 4)
	{
		trajectory::Trajectory traj = trajectory::open_resume(args[2]);
		traj_print_steps(trajectory::search(mem, &traj, args[3]), full);
		return cli::EXIT_OK;
	}
	log::error("traj 用法：traj list [--children]|show <name> [--full]|tail <name> [n]|search <name> <pattern>");
	return cli::EXIT_USAGE;
}

fn void traj_print_steps(trajectory::Step[] steps, bool full) @private
{
	foreach (s : steps)
	{
		String body = s.content.len ? s.content
			: (s.cmd.len ? s.cmd : (s.stdout.len ? s.stdout : s.thought));
		if (full)
		{
			io::printfn("%s  %-12s  %s", s.ts, s.type, body);
		}
		else
		{
			io::printfn("%s  %-12s  %s", s.ts, s.type, io_truncate(body));
		}
	}
}

// 列轨迹并标注 fork/merge 子关系（供父 run 观察子 run）。
fn int list_children()
{
	trajectory::TrajectorySummary[] items = trajectory::list_all(mem);
	if (!items.len)
	{
		io::printn("(没有轨迹)");
		return cli::EXIT_OK;
	}
	foreach (item : items)
	{
		trajectory::Trajectory traj = trajectory::open_resume(item.name);
		trajectory::Step[] steps = trajectory::read_all(tmem, &traj);
		String relation = "";
		foreach (s : steps)
		{
			if (s.type == trajectory::T_FORK) relation = string::tformat("  fork->%s", s.child);
			if (s.type == trajectory::T_MERGE) relation = string::tformat("  <-merge:%s", s.from_traj);
		}
		io::printfn("%s\t%d 步%s", item.name, (int)item.count, relation);
	}
	return cli::EXIT_OK;
}

fn String io_truncate(String text) @private
{
	String one = text.treplace("\n", " / ");
	return one.len > 120 ? one[:120] : one;
}

// llmcli context [--traj <name>]：打印渲染出的 messages（默认最近一条轨迹）。
fn int run_context(String[] args)
{
	for (usz i = 1; i < args.len; i++)
	{
		if (args[i] == "--traj" && i + 1 < args.len) return run_context_for(args[i + 1]);
	}
	trajectory::TrajectorySummary[] all = trajectory::list_all(mem);
	if (!all.len)
	{
		io::printn("(没有轨迹)");
		return cli::EXIT_OK;
	}
	return run_context_for(all[all.len - 1].name);
}

fn int run_context_for(String name) @private
{
	trajectory::Trajectory traj = trajectory::open_resume(name);
	context::RenderPolicy policy = context::default_policy();
	Message[] messages = context::render(mem, &traj, &policy);
	foreach (m : messages)
	{
		io::printfn("--- %s ---", m.role);
		io::printn(m.content);
	}
	return cli::EXIT_OK;
}

fn int main(String[] args)
{
	configure_dirs(args);
	sz ci = command_index(args);
	if (ci >= 0)
	{
		String cmd = args[ci];
		// 命令名之后的 token 是子命令参数；之前的全局 flag 保留给同一次运行。
		String[] tail = after(args, (usz)ci);
		if (cmd == "traj") return run_traj(prepend_argv0(tail));
		if (cmd == "context") return run_context(prepend_argv0(tail));
		if (cmd == "skills") return list_skills();
		// 子 run：等价 bin/shellm；带上命令名前的全局 flag（--model/--api-key/--traj-dir…）。
		// stdin 已被父进程接 /dev/null，不再作为输入来源。
		return run_entry(concat(head(args, (usz)ci), tail), false);
	}
	return run_entry(args);
}

// args[index+1..]（命令名之后的 token）
fn String[] after(String[] args, usz index) @private
{
	List{String} out;
	out.init(mem);
	for (usz i = index + 1; i < args.len; i++) out.push(args[i]);
	return out.to_array(mem);
}

// [argv0] + args[1..index]（argv0 占位 + 命令名之前的全局 flag）
fn String[] head(String[] args, usz index) @private
{
	List{String} out;
	out.init(mem);
	out.push(args[0]);
	for (usz i = 1; i < index; i++) out.push(args[i]);
	return out.to_array(mem);
}

// [argv0] + tail：给 run_traj/run_context 用（它们从 args[1] 起读 verb）
fn String[] prepend_argv0(String[] tail) @private
{
	List{String} out;
	out.init(mem);
	out.push("llmcli");
	foreach (t : tail) out.push(t);
	return out.to_array(mem);
}

fn String[] concat(String[] a, String[] b) @private
{
	List{String} out;
	out.init(mem);
	foreach (x : a) out.push(x);
	foreach (x : b) out.push(x);
	return out.to_array(mem);
}

// 子命令也要认 --traj-dir / --config-dir：在派发前扫一遍 argv 配置轨迹根。
fn void configure_dirs(String[] args) @private
{
	String traj_dir = "";
	String config_dir = "";
	for (usz i = 1; i < args.len; i++)
	{
		if (args[i] == "--traj-dir" && i + 1 < args.len) traj_dir = args[i + 1];
		if (args[i] == "--config-dir" && i + 1 < args.len) config_dir = args[i + 1];
		if (args[i].starts_with("--traj-dir=")) traj_dir = args[i][11..];
		if (args[i].starts_with("--config-dir=")) config_dir = args[i][13..];
	}
	if (traj_dir.len || config_dir.len) trajectory::configure(traj_dir, config_dir);
}