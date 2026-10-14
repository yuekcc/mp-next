package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ---- 分节 ----
// main：识别子命令（第一个参数是命令名时）→ 否则走一次真实运行。
// 真实运行：resolve → 初始化日志/脱敏 → 动作短路（help / 用法错误 / print-system-prompt）
// → 装中断处理器、起 libcurl → RLM 主循环。

// ---- 动作 ----

list_trajectories :: proc() -> int {
	items := traj_list_all()
	if len(items) == 0 {
		fmt.println("(没有轨迹)")
		return EXIT_OK
	}
	for item in items {
		fmt.printfln("%s\t%s\t%d 步", item.name, item.updated, item.count)
	}
	return EXIT_OK
}

list_skills :: proc() -> int {
	hub := skill_hub_init(SKILLS_ASSETS_DIR)
	brief := skill_hub_print_brief(&hub)
	fmt.print(brief)
	if !strings.has_suffix(brief, "\n") {
		fmt.println("")
	}
	return EXIT_OK
}

print_system_prompt :: proc(ctx: ^Ctx) -> int {
	fmt.print(ctx.system_prompt)
	if !strings.has_suffix(ctx.system_prompt, "\n") {
		fmt.println("")
	}
	return EXIT_OK
}

// ---- 一次真实运行 ----

run_entry :: proc(args: []string) -> int {
	parsed := cli_resolve(args)
	traj_configure(parsed.ctx.traj_dir, parsed.ctx.config_dir)
	// resolve 里已按 flag 初始化过日志；这里用配置回填后的最终值再初始化一次。
	log_init(parsed.ctx.quiet, parsed.ctx.debug, parsed.ctx.no_color)
	log_add_secret(parsed.ctx.api_key)

	if parsed.ctx.help {
		fmt.println(HELP)
		return EXIT_OK
	}
	if parsed.error != "" {
		log_error("%s", parsed.error)
		fmt.eprintln(USAGE)
		fmt.eprintln("运行 llmcli --help 查看全部 flags")
		return EXIT_USAGE
	}
	if parsed.ctx.print_system_prompt {
		return print_system_prompt(&parsed.ctx)
	}

	install_interrupt_handler()
	http_init()
	defer http_deinit()

	return agent_run(&parsed.ctx)
}

// ---- 子命令：单二进制靠第一个参数派发 ----

COMMANDS := [?]string{"traj", "context", "skills"}

is_command :: proc(arg: string) -> bool {
	for cmd in COMMANDS {
		if arg == cmd {
			return true
		}
	}
	return false
}

// llmcli traj list [--children] / show <name> [--full] / tail <name> [n] / search <name> <pattern>
// args 是命令名之后的参数（verb 在 args[0]）。
run_traj :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] == "list" {
		children := false
		for a in args {
			if a == "--children" {
				children = true
			}
		}
		if children {
			return list_children()
		}
		return list_trajectories()
	}
	verb := args[0]
	full := false
	for a in args {
		if a == "--full" {
			full = true
		}
	}
	if verb == "show" && len(args) >= 2 {
		traj := traj_open_resume(args[1])
		traj_print_steps(traj_read_all(&traj), full)
		return EXIT_OK
	}
	if verb == "tail" && len(args) >= 2 {
		n := 10
		if len(args) >= 3 {
			if parsed, ok := strconv.parse_int(args[2]); ok {
				n = parsed
			}
		}
		traj := traj_open_resume(args[1])
		traj_print_steps(traj_tail(&traj, n), full)
		return EXIT_OK
	}
	if verb == "search" && len(args) >= 3 {
		traj := traj_open_resume(args[1])
		traj_print_steps(traj_search(&traj, args[2]), full)
		return EXIT_OK
	}
	log_error("traj 用法：traj list [--children]|show <name> [--full]|tail <name> [n]|search <name> <pattern>")
	return EXIT_USAGE
}

traj_print_steps :: proc(steps: [dynamic]Step, full: bool) {
	for s in steps {
		body := s.content
		if body == "" {
			body = s.cmd
		}
		if body == "" {
			body = s.stdout
		}
		if body == "" {
			body = s.thought
		}
		if full {
			fmt.printfln("%s  %-12s  %s", s.ts, s.type, body)
		} else {
			fmt.printfln("%s  %-12s  %s", s.ts, s.type, io_truncate(body))
		}
	}
}

// 列轨迹并标注 fork/merge 子关系（供父 run 观察子代理）。
list_children :: proc() -> int {
	items := traj_list_all()
	if len(items) == 0 {
		fmt.println("(没有轨迹)")
		return EXIT_OK
	}
	for item in items {
		traj := traj_open_resume(item.name)
		steps := traj_read_all(&traj)
		relation := ""
		for s in steps {
			if s.type == T_FORK {
				relation = fmt.aprintf("  fork->%s", s.child, allocator = context.temp_allocator)
			}
			if s.type == T_MERGE {
				relation = fmt.aprintf("  <-merge:%s", s.from_traj, allocator = context.temp_allocator)
			}
		}
		fmt.printfln("%s\t%d 步%s", item.name, item.count, relation)
	}
	return EXIT_OK
}

io_truncate :: proc(text: string) -> string {
	one, _ := strings.replace_all(text, "\n", " / ", context.temp_allocator)
	if len(one) > 120 {
		return one[:utf8_cut(one, 120)]
	}
	return one
}

// llmcli context [--traj <name>]：打印渲染出的 messages（默认最近一条轨迹）。
run_context :: proc(args: []string) -> int {
	for i in 0 ..< len(args) {
		if args[i] == "--traj" && i + 1 < len(args) {
			return run_context_for(args[i + 1])
		}
	}
	all := traj_list_all()
	if len(all) == 0 {
		fmt.println("(没有轨迹)")
		return EXIT_OK
	}
	return run_context_for(all[len(all) - 1].name)
}

run_context_for :: proc(name: string) -> int {
	traj := traj_open_resume(name)
	policy := default_policy()
	messages := context_render(&traj, &policy)
	for m in messages {
		fmt.printfln("--- %s ---", m.role)
		fmt.println(m.content)
	}
	return EXIT_OK
}

main :: proc() {
	args := os.args
	// 命令名必须是第一个参数：`llmcli traj list`。命中则派发，其余都是一次运行。
	if len(args) >= 2 && is_command(args[1]) {
		cmd := args[1]
		cfg := cli_configure_trajectory(args[2:])
		if cfg.error != "" {
			log_error("%s", cfg.error)
			os.exit(EXIT_USAGE)
		}
		switch cmd {
		case "traj":
			os.exit(run_traj(cfg.rest))
		case "context":
			os.exit(run_context(cfg.rest))
		case:
			os.exit(list_skills())
		}
	}
	os.exit(run_entry(args))
}
