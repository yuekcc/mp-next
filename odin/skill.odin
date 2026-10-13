package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// ---- 分节 ----
// 技能的发现与列表组装。
//
// 技能即一个目录：目录里放 SKILL.md，front matter 给出 name/description，正文是技能内容。
// 从两处发现：全局 `~/.agents/skills/<name>/`，项目 `<cwd>/.agents/skills/<name>/`；
// 同名时项目级覆盖全局级。
//
// 本模块产出两样东西：
//   - skill_hub_print_installed()：拼进系统提示词的 `<available_skills>` 块；
//   - skill_hub_print_brief()：`skills` 子命令的简表，供人查看。
//
// llmcli 里 bash 是唯一工具，所以提示词让模型用 bash 去读 SKILL.md。

// ---- 常量 ----

SKILL_FILE :: "SKILL.md"
SKILLS_SUBDIR :: "skills"

// 拼进系统提示词的开场说明。
INSTALLED_HEADER :: `若 <available_skills> 里有明显适用于当前任务的 skill，用 bash（cat / sed 等）读取其 <location> 指向的 SKILL.md，再照其执行。
若多个都沾边，选最贴切的那个；若都不贴切，一个都不要读。
skill 文件里引用相对路径时，以该 SKILL.md 所在目录为基准解析成绝对路径再使用。`

// ---- 类型 ----

// 一个已安装 skill：front matter（name/description）+ 正文 + 位置。
Skill :: struct {
	name:        string,
	description: string,
	content:     string,
	location:    string,
}

SkillHub :: struct {
	skills: [dynamic]Skill,
}

// ---- 装配入口 ----

// 从默认两处（~/.agents/skills、<cwd>/.agents/skills）发现并加载。
// 结果字符串都在 context.temp_allocator 上。
skill_hub_init :: proc(assets_dir: string) -> SkillHub {
	dirs := make([dynamic]string, 0, 8, context.temp_allocator)
	if home, _ := os.user_home_dir(context.temp_allocator); home != "" {
		collect_skill_dirs(&dirs, fmt.aprintf("%s/%s/%s", slashify(home), assets_dir, SKILLS_SUBDIR,
		                                       allocator = context.temp_allocator))
	}
	if cwd, _ := os.get_working_directory(context.temp_allocator); cwd != "" {
		collect_skill_dirs(&dirs, fmt.aprintf("%s/%s/%s", slashify(cwd), assets_dir, SKILLS_SUBDIR,
		                                      allocator = context.temp_allocator))
	}
	return skill_hub_load_dirs(dirs[:])
}

// 从显式目录列表加载（init 与单元测试共用）。同名去重，项目级后加载者覆盖先加载者。
skill_hub_load_dirs :: proc(dirs: []string) -> SkillHub {
	hub: SkillHub
	hub.skills = make([dynamic]Skill, 0, 8, context.temp_allocator)
	for dir in dirs {
		skill, ok := load_skill(dir)
		if !ok {
			continue
		}
		replaced := false
		for i in 0 ..< len(hub.skills) {
			if hub.skills[i].name == skill.name {
				hub.skills[i] = skill
				replaced = true
				break
			}
		}
		if !replaced {
			append(&hub.skills, skill)
		}
	}
	slice.sort_by(hub.skills[:], proc(a, b: Skill) -> bool { return a.name < b.name })
	return hub
}

// ---- 列表组装 ----

// 系统提示词注入块：无 skill 时返回空串（不往提示词里塞“没有技能”这种噪音）。
skill_hub_print_installed :: proc(hub: ^SkillHub) -> string {
	if len(hub.skills) == 0 {
		return ""
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, INSTALLED_HEADER)
	strings.write_string(&sb, "\n\n<available_skills>\n")
	for skill in hub.skills {
		strings.write_string(&sb, "  <skill>\n")
		fmt.sbprintf(&sb, "    <name>%s</name>\n", escape_xml(skill.name))
		fmt.sbprintf(&sb, "    <description>%s</description>\n", escape_xml(skill.description))
		fmt.sbprintf(&sb, "    <location>%s</location>\n", escape_xml(slashify(skill.location)))
		strings.write_string(&sb, "  </skill>\n")
	}
	strings.write_string(&sb, "</available_skills>")
	return strings.to_string(sb)
}

// 简表：每行 `<序号>. <name>: <description>`。
skill_hub_print_brief :: proc(hub: ^SkillHub) -> string {
	if len(hub.skills) == 0 {
		return "No skill found"
	}
	sb := strings.builder_make(context.temp_allocator)
	index := 1
	for skill in hub.skills {
		fmt.sbprintf(&sb, "%d. %s: %s\n", index, skill.name, skill.description)
		index += 1
	}
	return strings.to_string(sb)
}

// ---- 目录发现 ----

collect_skill_dirs :: proc(dirs: ^[dynamic]string, skills_home: string) {
	if !os.exists(skills_home) {
		return
	}
	entries, err := os.read_all_directory_by_path(skills_home, context.temp_allocator)
	if err != nil {
		return
	}
	for entry in entries {
		if entry.type == .Directory {
			append(dirs, fmt.aprintf("%s/%s", skills_home, entry.name, allocator = context.temp_allocator))
		}
	}
}

// ---- 单个 skill 解析 ----

// 读 <dir>/SKILL.md，解析 front matter 与正文。name/description/content 三者齐全才算有效。
load_skill :: proc(dir: string) -> (skill: Skill, ok: bool) {
	path := fmt.aprintf("%s/%s", dir, SKILL_FILE, allocator = context.temp_allocator)
	if !os.exists(path) {
		return {}, false
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	text := string(data)
	lines := strings.split(text, "\n", context.temp_allocator)

	in_front := false
	front_done := false
	body := strings.builder_make(context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if !front_done && trimmed == "---" {
			if !in_front {
				in_front = true
			} else {
				in_front = false
				front_done = true
			}
			continue
		}
		if in_front {
			if colon := strings.index_byte(line, ':'); colon > 0 {
				key := strings.trim_space(line[:colon])
				value := front_value(line[colon + 1:])
				if key == "name" && skill.name == "" {
					skill.name = value
				} else if key == "description" && skill.description == "" {
					skill.description = value
				}
			}
			continue
		}
		if front_done {
			strings.write_string(&body, line)
			strings.write_byte(&body, '\n')
		}
	}
	skill.location = path
	content := strings.trim_space(strings.to_string(body))
	if content != "" {
		skill.content = content
	}
	return skill, skill.name != "" && skill.description != "" && skill.content != ""
}

// front matter 值：去掉包裹的引号。
front_value :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	if len(trimmed) >= 2 {
		if (trimmed[0] == '"' && trimmed[len(trimmed) - 1] == '"') ||
		   (trimmed[0] == '\'' && trimmed[len(trimmed) - 1] == '\'') {
			return trimmed[1 : len(trimmed) - 1]
		}
	}
	return trimmed
}

escape_xml :: proc(s: string) -> string {
	out := s
	out, _ = strings.replace_all(out, "&", "&amp;", context.temp_allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.temp_allocator)
	out, _ = strings.replace_all(out, ">", "&gt;", context.temp_allocator)
	out, _ = strings.replace_all(out, "\"", "&quot;", context.temp_allocator)
	out, _ = strings.replace_all(out, "'", "&apos;", context.temp_allocator)
	return out
}
