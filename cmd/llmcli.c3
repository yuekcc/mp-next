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

fn int run_entry(String[] args)
{
	cli::ParseResult parsed = cli::resolve(args);
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
	if (parsed.ctx.print_system_prompt) return print_system_prompt(&parsed.ctx);

	runtime::install_interrupt_handler();
	http::http_init();
	defer http::http_deinit();

	return agent::run(&parsed.ctx);
}

// ---- 子命令（doc 7）：单二进制靠第一个参数派发 ----

// 子命令名集合。命令名必须是第一个参数（args[1]）。
const String[] COMMANDS = { "traj", "context", "skills" };

fn bool is_command(String arg) @private
{
	foreach (cmd : COMMANDS)
	{
		if (arg == cmd) return true;
	}
	return false;
}

// llmcli traj list [--children] / show <name> [--full] / tail <name> [n] / search <name> <pattern>
// args 是命令名之后的参数（verb 在 args[0]）。
fn int run_traj(String[] args)
{
	if (!args.len || args[0] == "list")
	{
		bool children = false;
		foreach (a : args) { if (a == "--children") children = true; }
		if (children) return list_children();
		return list_trajectories();
	}
	String verb = args[0];
	bool full = false;
	foreach (a : args) { if (a == "--full") full = true; }
	if (verb == "show" && args.len >= 2)
	{
		trajectory::Trajectory traj = trajectory::open_resume(args[1]);
		traj_print_steps(trajectory::read_all(mem, &traj), full);
		return cli::EXIT_OK;
	}
	if (verb == "tail" && args.len >= 2)
	{
		int n = args.len >= 3 ? (args[2].to_int() ?? 10) : 10;
		trajectory::Trajectory traj = trajectory::open_resume(args[1]);
		traj_print_steps(trajectory::tail(mem, &traj, n), full);
		return cli::EXIT_OK;
	}
	if (verb == "search" && args.len >= 3)
	{
		trajectory::Trajectory traj = trajectory::open_resume(args[1]);
		traj_print_steps(trajectory::search(mem, &traj, args[2]), full);
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
// args 是命令名之后的参数。
fn int run_context(String[] args)
{
	for (usz i = 0; i < args.len; i++)
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
	// 命令名必须是第一个参数：`llmcli traj list`。命中则派发，其余都是一次运行
	// （生成代码起子 run 就是 `llmcli -p "<task>"`）。
	if (args.len >= 2 && is_command(args[1]))
	{
		String cmd = args[1];
		// 子命令也认 --traj-dir / --config-dir（CLI flag 知识集中在 cli.c3）；这两个 flag
		// 及值从子命令参数里摘掉，剩下的才是 verb 与位置参数。
		String[] tail = cli::configure_trajectory(args[2..]);
		if (cmd == "traj") return run_traj(tail);
		if (cmd == "context") return run_context(tail);
		return list_skills();
	}
	return run_entry(args);
}
