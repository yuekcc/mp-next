package main

import "core:os"
import "core:strings"
import "core:testing"

// ---- S5：context 渲染（文件集成） ----

new_test_trajectory :: proc(t: ^testing.T, slug: string) -> (Trajectory, string, bool) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return {}, "", false
	}
	traj_set_base_dir(dir)
	return traj_open_new(slug), dir, true
}

@(test)
context_maps_roles_and_excludes_bookkeeping :: proc(t: ^testing.T) {
	traj, dir, ok := new_test_trajectory(t, "roles")
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	traj_append(&traj, Step{type = T_SHELLM_RUN, run_id = "r", command = "go"})
	traj_append(&traj, Step{type = T_PROMPT, run_id = "r", content = "P"})
	traj_append(&traj, Step{type = T_REASONING, run_id = "r", thought = "T", cmd = "echo hi"})
	traj_append(&traj, Step{type = T_SHELL_OUTPUT, run_id = "r", stdout = "OUT", exit = 0})
	traj_append(&traj, Step{type = T_FINAL, run_id = "r", content = "F"})
	traj_append(&traj, Step{type = T_RUN_SUMMARY, run_id = "r", content = "iterations=1"})

	policy := default_policy()
	msgs := context_render(&traj, &policy)
	testing.expect_value(t, len(msgs), 4)
	testing.expect_value(t, msgs[0].role, "user")
	testing.expect_value(t, msgs[0].content, "P")
	testing.expect_value(t, msgs[1].role, "assistant")
	testing.expect_value(t, msgs[1].content, "T\n```bash\necho hi\n```")
	testing.expect_value(t, msgs[2].role, "user")
	testing.expect_value(t, msgs[2].content, "OUT")
	testing.expect_value(t, msgs[3].role, "assistant")
	testing.expect_value(t, msgs[3].content, "F")
}

@(test)
context_applies_head_tail_window :: proc(t: ^testing.T) {
	traj, dir, ok := new_test_trajectory(t, "window")
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	for _ in 0 ..< 5 {
		traj_append(&traj, Step{type = T_PROMPT, run_id = "r", content = "m"})
	}

	policy := default_policy()
	policy.head = 1
	policy.tail = 2
	msgs := context_render(&traj, &policy)
	// 保留首 1 + 末 2 = 3 步
	testing.expect_value(t, len(msgs), 3)
}

@(test)
context_truncates_old_blocks_but_not_full_types :: proc(t: ^testing.T) {
	traj, dir, ok := new_test_trajectory(t, "trunc")
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	long_a := strings.repeat("a", 300, context.temp_allocator) or_else ""
	long_b := strings.repeat("b", 300, context.temp_allocator) or_else ""
	traj_append(&traj, Step{type = T_PROMPT, run_id = "r", content = long_a}) // block 0, full type
	traj_append(&traj, Step{type = T_SHELL_OUTPUT, run_id = "r", stdout = long_a, exit = 0}) // block 0
	traj_append(&traj, Step{type = T_PROMPT, run_id = "r", content = "x"}) // block 1
	traj_append(&traj, Step{type = T_SHELL_OUTPUT, run_id = "r", stdout = long_b, exit = 0}) // block 1 (newest)

	policy := default_policy()
	policy.prompt_limit = 50
	policy.block_limit = 8000
	policy.whole_blocks = 1
	msgs := context_render(&traj, &policy)

	testing.expect_value(t, len(msgs), 4)
	// prompt 是 full_types：永不截断
	testing.expect_value(t, len(msgs[0].content), 300)
	// 旧波段的 shell-output：按 prompt_limit 中间截断
	testing.expect(t, strings.contains(msgs[1].content, "[... truncated: 300 bytes total ...]"),
	               "old block must be truncated")
	// 最新波段的 shell-output：按 block_limit，不截断
	testing.expect_value(t, msgs[3].content, long_b)
}

@(test)
context_scopes_to_run :: proc(t: ^testing.T) {
	traj, dir, ok := new_test_trajectory(t, "scope")
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	traj_append(&traj, Step{type = T_PROMPT, run_id = "r1", content = "first"})
	traj_append(&traj, Step{type = T_PROMPT, run_id = "r2", content = "second"})
	traj_append(&traj, Step{type = T_SHELL_OUTPUT, run_id = "r2", stdout = "out", exit = 0})

	policy := default_policy()
	policy.run = "r2"
	msgs := context_render(&traj, &policy)
	testing.expect_value(t, len(msgs), 2)
	testing.expect_value(t, msgs[0].content, "second")
	testing.expect_value(t, msgs[1].content, "out")
}

@(test)
context_tightens_under_max_bytes :: proc(t: ^testing.T) {
	traj, dir, ok := new_test_trajectory(t, "budget")
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	big := strings.repeat("z", 4000, context.temp_allocator) or_else ""
	traj_append(&traj, Step{type = T_PROMPT, run_id = "r", content = "P"})
	traj_append(&traj, Step{type = T_SHELL_OUTPUT, run_id = "r", stdout = big, exit = 0})

	unlimited := default_policy()
	msgs_unlimited := context_render(&traj, &unlimited)

	limited := default_policy()
	limited.max_bytes = 200
	msgs_limited := context_render(&traj, &limited)

	testing.expect(t, total_bytes(msgs_limited) < total_bytes(msgs_unlimited),
	               "max_bytes must tighten the rendered budget")
}

@(test)
context_never_renders_reasoning_content :: proc(t: ^testing.T) {
	traj, dir, ok := new_test_trajectory(t, "reasoning")
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	traj_append(&traj, Step{type = T_REASONING, run_id = "r", thought = "T", cmd = "echo hi",
	                        reasoning_content = "SECRET-CHAIN"})
	traj_append(&traj, Step{type = T_FINAL, run_id = "r", content = "F",
	                        reasoning_content = "SECRET-CHAIN-2"})

	policy := default_policy()
	msgs := context_render(&traj, &policy)
	testing.expect_value(t, len(msgs), 2)
	testing.expect_value(t, msgs[0].content, "T\n```bash\necho hi\n```")
	testing.expect_value(t, msgs[1].content, "F")
	testing.expect(t, !strings.contains(msgs[0].content, "SECRET"), "reasoning_content must not render")
	testing.expect(t, !strings.contains(msgs[1].content, "SECRET"), "reasoning_content must not render")
}
