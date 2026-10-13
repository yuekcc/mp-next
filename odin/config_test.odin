package main

import "core:fmt"
import "core:os"
import "core:testing"

// ---- S7：config.load（文件集成） ----

write_config_file :: proc(t: ^testing.T, dir, body: string) {
	path := fmt.aprintf("%s/%s", slashify(dir), CONFIG_FILE_NAME, allocator = context.temp_allocator)
	if err := os.write_entire_file_from_string(path, body); err != nil {
		testing.expectf(t, false, "write config %s: %v", path, err)
	}
}

@(test)
config_missing_file_is_silent :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	res := config_load(dir)
	testing.expect_value(t, res.error, "")
	testing.expect(t, !res.settings.h_model)
}

@(test)
config_parses_known_keys :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	write_config_file(t, dir,
		`{"model":"gpt-4o-mini","api_url":"https://x","max_iterations":20,` +
		`"context_scope":"run","var":{"FOO":"bar"},"debug":true}`)
	res := config_load(dir)
	testing.expect_value(t, res.error, "")
	s := res.settings
	testing.expect(t, s.h_model)
	testing.expect_value(t, s.model, "gpt-4o-mini")
	testing.expect(t, s.h_api_url)
	testing.expect_value(t, s.api_url, "https://x")
	testing.expect(t, s.h_max_iterations)
	testing.expect_value(t, s.max_iterations, 20)
	testing.expect(t, s.h_context_scope)
	testing.expect_value(t, s.context_scope, "run")
	testing.expect(t, s.h_debug)
	testing.expect_value(t, s.debug, true)
	testing.expect(t, s.h_var)
	testing.expect_value(t, len(s.vars), 1)
	testing.expect_value(t, s.vars[0].name, "FOO")
	testing.expect_value(t, s.vars[0].value, "bar")
}

@(test)
config_rejects_bad_json :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	write_config_file(t, dir, "{not json")
	res := config_load(dir)
	testing.expect(t, len(res.error) > 0)
}

@(test)
config_rejects_wrong_type :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	write_config_file(t, dir, `{"model":42}`)
	res := config_load(dir)
	testing.expect(t, len(res.error) > 0, "non-string model must be rejected")
}

@(test)
config_unknown_key_is_warn_only :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	write_config_file(t, dir, `{"model":"m","bogus":1}`)
	res := config_load(dir)
	testing.expect_value(t, res.error, "")
	testing.expect(t, res.settings.h_model)
}

@(test)
config_rejects_bad_context_scope :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	write_config_file(t, dir, `{"context_scope":"nope"}`)
	res := config_load(dir)
	testing.expect(t, len(res.error) > 0)
}

@(test)
config_rejects_both_prompt_sources :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	write_config_file(t, dir, `{"system_prompt":"a","system_prompt_file":"b"}`)
	res := config_load(dir)
	testing.expect(t, len(res.error) > 0)
}

@(test)
config_rejects_non_string_var_values :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	write_config_file(t, dir, `{"var":{"A":1}}`)
	res := config_load(dir)
	testing.expect(t, len(res.error) > 0)
}
