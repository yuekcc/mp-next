package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ---- S8：skill 发现/解析/排序/注入（文件集成） ----

make_skill_dir :: proc(t: ^testing.T, base, dir_name, front_name, description, body: string) -> string {
	dir := fmt.aprintf("%s/%s", slashify(base), dir_name, allocator = context.temp_allocator)
	if err := os.make_directory_all(dir); err != nil {
		testing.expectf(t, false, "make skill dir: %v", err)
		return ""
	}
	content := fmt.aprintf("---\nname: %s\ndescription: %s\n---\n%s\n",
	                       front_name, description, body, allocator = context.temp_allocator)
	if err := os.write_entire_file_from_string(fmt.aprintf("%s/%s", dir, SKILL_FILE,
	                                                       allocator = context.temp_allocator), content); err != nil {
		testing.expectf(t, false, "write SKILL.md: %v", err)
	}
	return dir
}

@(test)
skill_hub_loads_valid_skill :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	skill_dir := make_skill_dir(t, dir, "alpha", "alpha", "does alpha things", "Step 1\nStep 2")
	hub := skill_hub_load_dirs([]string{skill_dir})
	testing.expect_value(t, len(hub.skills), 1)
	testing.expect_value(t, hub.skills[0].name, "alpha")
	testing.expect_value(t, hub.skills[0].description, "does alpha things")
	testing.expect_value(t, hub.skills[0].content, "Step 1\nStep 2")
	testing.expect(t, strings.has_suffix(hub.skills[0].location, SKILL_FILE))
}

@(test)
skill_hub_project_overrides_global :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	global := make_skill_dir(t, dir, "global/dup", "dup", "global version", "g")
	project := make_skill_dir(t, dir, "project/dup", "dup", "project version", "p")
	hub := skill_hub_load_dirs([]string{global, project})
	testing.expect_value(t, len(hub.skills), 1)
	testing.expect_value(t, hub.skills[0].description, "project version")
}

@(test)
skill_hub_sorts_by_name :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	b := make_skill_dir(t, dir, "b", "bravo", "b", "body")
	a := make_skill_dir(t, dir, "a", "alpha", "a", "body")
	hub := skill_hub_load_dirs([]string{b, a})
	testing.expect_value(t, len(hub.skills), 2)
	testing.expect_value(t, hub.skills[0].name, "alpha")
	testing.expect_value(t, hub.skills[1].name, "bravo")
}

@(test)
skill_hub_print_installed_is_empty_without_skills :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	hub := skill_hub_load_dirs([]string{})
	testing.expect_value(t, skill_hub_print_installed(&hub), "")
}

@(test)
skill_hub_print_installed_escapes_xml :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	skill_dir := make_skill_dir(t, dir, "esc", "esc", "a <b> & c", "body")
	hub := skill_hub_load_dirs([]string{skill_dir})
	block := skill_hub_print_installed(&hub)
	testing.expect(t, strings.contains(block, "a &lt;b&gt; &amp; c"), block)
	testing.expect(t, strings.contains(block, "<available_skills>"))
}

@(test)
skill_hub_requires_name_description_and_content :: proc(t: ^testing.T) {
	dir, ok := make_temp_traj_dir(t)
	if !ok {
		return
	}
	defer free_all(context.temp_allocator)
	defer os.remove_all(dir)

	// 缺 description：无效
	skill_dir := fmt.aprintf("%s/incomplete", slashify(dir), allocator = context.temp_allocator)
	_ = os.make_directory_all(skill_dir)
	_ = os.write_entire_file_from_string(fmt.aprintf("%s/%s", skill_dir, SKILL_FILE,
	                                                 allocator = context.temp_allocator),
		"---\nname: x\n---\nbody\n")
	hub := skill_hub_load_dirs([]string{skill_dir})
	testing.expect_value(t, len(hub.skills), 0)
}
