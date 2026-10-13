package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// ---- S9：runtime 执行器（进程集成，需 bash） ----

no_watch_executor :: proc() -> Executor {
	ex := default_executor()
	ex.inactivity_timeout = 0
	ex.max_output_size = 0
	ex.max_exec_time = 0
	return ex
}

@(test)
runtime_captures_final_string :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ex := no_watch_executor()
	res := executor_run(&ex, "FINAL=\"hello world\"\n")
	testing.expect_value(t, res.exit_code, 0)
	testing.expect(t, res.has_final, "FINAL must be captured")
	testing.expect_value(t, res.final_answer, "hello world")
}

@(test)
runtime_empty_final_counts_as_set :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ex := no_watch_executor()
	res := executor_run(&ex, "FINAL=\"\"\n")
	testing.expect(t, res.has_final, "FINAL=\"\" must count as set")
	testing.expect_value(t, res.final_answer, "")
}

@(test)
runtime_captures_final_file :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ex := no_watch_executor()
	fname := fmt.aprintf("llmcli_final_test_%d.txt", time.now()._nsec, allocator = context.temp_allocator)
	defer _ = os.remove(fname)
	code := fmt.aprintf("printf 'from file' > %s\nFINAL_FILE=%s\n", fname, fname,
	                    allocator = context.temp_allocator)
	res := executor_run(&ex, code)
	testing.expect(t, res.has_final, "FINAL_FILE must be captured")
	testing.expect_value(t, res.final_answer, "from file")
}

@(test)
runtime_reports_nonzero_exit_and_strips_xtrace :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ex := no_watch_executor()
	res := executor_run(&ex, "echo hello\nexit 7\n")
	testing.expect_value(t, res.exit_code, 7)
	testing.expect(t, strings.contains(res.output, "hello"), res.output)
	testing.expect(t, !strings.contains(res.output, "+ echo hello"), "xtrace must be stripped")
	testing.expect(t, strings.contains(res.output, "[exit 7]"), res.output)
}

@(test)
runtime_truncates_to_last_2000_lines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ex := no_watch_executor()
	res := executor_run(&ex, "for i in $(seq 1 2100); do echo \"line$i\"; done\n")
	testing.expect(t, strings.contains(res.output, "... (truncated"), "must note truncation")
	testing.expect(t, strings.contains(res.output, "line2100"), "must keep the newest lines")
	testing.expect(t, !strings.contains(res.output, "line1\n"), "oldest lines must be dropped")
}

@(test)
runtime_inactivity_watchdog_kills_interactive_like_command :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ex := default_executor()
	ex.inactivity_timeout = 1
	ex.max_exec_time = 0
	ex.max_output_size = 0
	res := executor_run(&ex, "sleep 10\n")
	testing.expect(t, res.exit_code != 0, "killed command must be non-zero")
	testing.expect(t, len(res.feedback) > 0, "watchdog must give structured feedback")
	testing.expect(t, strings.contains(res.feedback, "空闲看门狗"), res.feedback)
}
