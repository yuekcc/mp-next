package main

import "core:fmt"
import "core:os"
import "core:testing"

// ---- S6：cli.parse / cli.resolve / cli.apply_config ----

parse_argv :: proc(args: ..string) -> []string {
	out := make([]string, len(args), context.temp_allocator)
	for a, i in args {
		out[i] = a
	}
	return out
}

@(test)
parse_help_short_circuits_without_credentials :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--help"))
	testing.expect_value(t, res.error, "")
	testing.expect(t, res.ctx.help)
}

@(test)
parse_rejects_multiple_input_sources :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "-p", "a", "--input-file", "b"))
	testing.expect(t, len(res.error) > 0, "two input sources must be a usage error")
}

@(test)
parse_rejects_two_positionals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "one", "two"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_rejects_positional_and_prompt :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "-p", "a", "b"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_rejects_unknown_flag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--nope", "x"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_rejects_non_integer_iterations :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--max-iterations", "abc", "-p", "x"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_rejects_bad_context_scope :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--context-scope", "nope", "-p", "x"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_rejects_var_without_equals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--var", "NOEQ", "-p", "x"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_rejects_two_prompt_sources :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--system-prompt", "a", "--system-prompt-file", "b", "-p", "x"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_rejects_unsafe_traj_id :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--traj", "../evil", "-p", "x"))
	testing.expect(t, len(res.error) > 0)
}

@(test)
parse_accepts_and_fills_fields :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--api-key", "k", "--model", "m", "-p", "hi",
	                            "--max-iterations", "3", "--context-scope", "run", "--var", "A=1"))
	testing.expect_value(t, res.error, "")
	testing.expect_value(t, res.ctx.api_key, "k")
	testing.expect_value(t, res.ctx.model, "m")
	testing.expect_value(t, res.ctx.prompt, "hi")
	testing.expect_value(t, res.ctx.max_iterations, 3)
	testing.expect_value(t, res.ctx.context_scope, "run")
	testing.expect_value(t, len(res.ctx.vars), 1)
	testing.expect_value(t, res.ctx.vars[0], "A=1")
	testing.expect(t, res.seen.model)
	testing.expect(t, res.seen.max_iterations)
}

@(test)
parse_accepts_inline_flag_values :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--model=m", "--api-key=k", "-p", "hi"))
	testing.expect_value(t, res.error, "")
	testing.expect_value(t, res.ctx.model, "m")
	testing.expect_value(t, res.ctx.api_key, "k")
}

// ---- apply_config 优先级 ----

@(test)
apply_config_flag_beats_config :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--model", "cli-model", "-p", "hi"))
	settings := ConfigSettings{h_model = true, model = "cfg-model", h_api_url = true, api_url = "cfg-url"}
	cli_apply_config(&res.ctx, &res.seen, &settings)
	testing.expect_value(t, res.ctx.model, "cli-model")
	testing.expect_value(t, res.ctx.api_url, "cfg-url")
}

@(test)
apply_config_merges_vars_config_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--var", "B=2", "-p", "hi"))
	settings := ConfigSettings{h_var = true, vars = []ConfigVar{{name = "A", value = "1"}}}
	cli_apply_config(&res.ctx, &res.seen, &settings)
	testing.expect_value(t, len(res.ctx.vars), 2)
	testing.expect_value(t, res.ctx.vars[0], "A=1")
	testing.expect_value(t, res.ctx.vars[1], "B=2")
}

@(test)
apply_config_ignores_prompt_file_when_flag_gave_prompt :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_parse(parse_argv("llmcli", "--system-prompt", "flag prompt", "-p", "hi"))
	settings := ConfigSettings{h_system_prompt_file = true, system_prompt_file = "cfg.md"}
	cli_apply_config(&res.ctx, &res.seen, &settings)
	testing.expect_value(t, res.ctx.system_prompt, "flag prompt")
	testing.expect_value(t, res.ctx.system_prompt_file, "")
}

// ---- resolve（文件 I/O） ----

@(test)
resolve_reads_config_and_input_file :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	config_path := fmt.aprintf("%s/%s", slashify(dir), CONFIG_FILE_NAME, allocator = context.temp_allocator)
	_ = os.write_entire_file_from_string(config_path, `{"model":"cfg-model","context_scope":"run"}`)
	input_path := fmt.aprintf("%s/in.txt", slashify(dir), allocator = context.temp_allocator)
	_ = os.write_entire_file_from_string(input_path, "hello from file")

	res := cli_resolve(parse_argv("llmcli", "--api-key", "k", "--config-dir", dir,
	                              "--input-file", input_path))
	testing.expect_value(t, res.error, "")
	testing.expect_value(t, res.ctx.model, "cfg-model")
	testing.expect_value(t, res.ctx.context_scope, "run")
	testing.expect_value(t, res.ctx.user_input, "hello from file")
	testing.expect(t, len(res.ctx.system_prompt) > 0, "system prompt must be assembled")
}

@(test)
resolve_no_config_without_model_is_usage_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := cli_resolve(parse_argv("llmcli", "--api-key", "k", "--no-config", "-p", "hi"))
	testing.expect(t, len(res.error) > 0)
}
