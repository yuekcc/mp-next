package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// ---- S4：trajectory（文件集成，temp dir） ----

// 建一个临时轨迹根目录。调用方负责 os.remove_all。
// 基准目录优先取 LLMCLI_TEST_TMP（沙箱环境里系统 temp 不可写时用），否则系统 temp。
make_temp_traj_dir :: proc(t: ^testing.T) -> (string, bool) {
	base := os.get_env_alloc("LLMCLI_TEST_TMP", context.temp_allocator)
	if base == "" {
		base = os.temp_directory(context.temp_allocator) or_else "."
	}
	dir := fmt.aprintf("%s/llmcli-odin-test-%d", slashify(base), time.now()._nsec,
	                   allocator = context.temp_allocator)
	if err := os.make_directory_all(dir); err != nil {
		testing.expectf(t, false, "make temp dir %s: %v", dir, err)
		return "", false
	}
	return dir, true
}

@(test)
trajectory_append_read_roundtrip :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)
	traj_set_base_dir(dir)

	traj := traj_open_new("hello world")
	testing.expect(t, traj_valid_id(traj.name), "generated name must be filesystem safe")
	testing.expect(t, strings.has_prefix(traj.name, traj.id), "name must start with id")

	id := traj_append(&traj, Step{type = T_PROMPT, run_id = "r1", content = "hi there"})
	testing.expect(t, len(id) > 0)

	steps := traj_read_all(&traj)
	testing.expect_value(t, len(steps), 1)
	testing.expect_value(t, steps[0].type, T_PROMPT)
	testing.expect_value(t, steps[0].content, "hi there")
	testing.expect_value(t, steps[0].run_id, "r1")
	testing.expect_value(t, steps[0].step_id, id)
}

@(test)
trajectory_file_starts_with_valid_header :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)
	traj_set_base_dir(dir)

	traj := traj_open_new("header")
	raw, _ := os.read_entire_file_from_path(traj.path, context.temp_allocator)
	first_line := strings.split(string(raw), "\n", context.temp_allocator)[0]
	testing.expect_value(t, first_line, `{"type":"trajectory"}`)
}

@(test)
trajectory_spills_large_fields_to_blob :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)
	traj_set_base_dir(dir)

	traj := traj_open_new("spill")
	big := strings.repeat("x", SPILL_THRESHOLD + 100, context.temp_allocator) or_else ""
	traj_append(&traj, Step{type = T_SHELL_OUTPUT, run_id = "r", stdout = big, exit = 0})

	raw, _ := os.read_entire_file_from_path(traj.path, context.temp_allocator)
	testing.expect(t, strings.contains(string(raw), "stdout_ref"), "large field must spill to blob")
	testing.expect(t, !strings.contains(string(raw), big), "large field must not be inlined")

	steps := traj_read_all(&traj)
	testing.expect_value(t, len(steps), 1)
	testing.expect_value(t, steps[0].stdout, big)
}

@(test)
trajectory_fork_merge_records_dag :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)
	traj_set_base_dir(dir)

	traj := traj_open_new("parent")
	child := traj_fork(&traj, "child-slug")
	testing.expect_value(t, len(child), 8)
	traj_merge(&traj, child)

	steps := traj_read_all(&traj)
	testing.expect_value(t, len(steps), 2)
	testing.expect_value(t, steps[0].type, T_FORK)
	testing.expect_value(t, steps[0].child, child)
	testing.expect_value(t, steps[0].slug, "child-slug")
	testing.expect_value(t, steps[1].type, T_MERGE)
	testing.expect_value(t, steps[1].from_traj, child)
}

@(test)
trajectory_maps_legacy_session_lines :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)
	traj_set_base_dir(dir)

	traj := traj_open_new("legacy")
	legacy := `{"ts":"2026-01-01T00:00:00Z","turn":1,"message":{"role":"user","content":"hi"}}` + "\n" +
		`{"ts":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":"think","reasoning_content":"chain"}}` + "\n" +
		`{"ts":"2026-01-01T00:00:02Z","message":{"role":"user","content":"output"}}` + "\n"
	must_write(t, traj.path, legacy)

	steps := traj_read_all(&traj)
	testing.expect_value(t, len(steps), 3)
	testing.expect_value(t, steps[0].type, T_PROMPT)
	testing.expect_value(t, steps[0].content, "hi")
	testing.expect_value(t, steps[1].type, T_REASONING)
	testing.expect_value(t, steps[1].thought, "think")
	testing.expect_value(t, steps[1].reasoning_content, "chain")
	testing.expect_value(t, steps[2].type, T_SHELL_OUTPUT)
	testing.expect_value(t, steps[2].stdout, "output")
}

@(test)
trajectory_query_helpers :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)
	traj_set_base_dir(dir)

	traj := traj_open_new("query")
	traj_append(&traj, Step{type = T_PROMPT, run_id = "r", content = "alpha"})
	id2 := traj_append(&traj, Step{type = T_SHELL_OUTPUT, run_id = "r", stdout = "beta out", exit = 0})
	traj_append(&traj, Step{type = T_FINAL, run_id = "r", content = "gamma"})

	tail := traj_tail(&traj, 2)
	testing.expect_value(t, len(tail), 2)
	testing.expect_value(t, tail[0].type, T_SHELL_OUTPUT)

	hits := traj_search(&traj, "beta")
	testing.expect_value(t, len(hits), 1)
	testing.expect_value(t, hits[0].type, T_SHELL_OUTPUT)

	_, found := traj_find(&traj, id2)
	testing.expect(t, found, "find by step_id")
	testing.expect_value(t, traj_last(&traj).type, T_FINAL)

	summaries := traj_list_all()
	testing.expect_value(t, len(summaries), 1)
	testing.expect_value(t, summaries[0].name, traj.name)
	testing.expect_value(t, summaries[0].count, 3)
}

// 写文件（测试用；失败即报错）。
must_write :: proc(t: ^testing.T, path, content: string) {
	if err := os.write_entire_file_from_string(path, content); err != nil {
		testing.expectf(t, false, "write %s: %v", path, err)
	}
}
