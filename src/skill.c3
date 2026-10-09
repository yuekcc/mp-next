module llmcli::skill;

import std::io, std::io::path, std::io::file;
import std::collections::list;

// 技能的发现与列表组装（从 mini_pi 的 SkillHub 移植）。
//
// 技能即一个目录：目录里放 SKILL.md，front matter 给出 name/description，正文是技能内容。
// 从两处发现：全局 `~/.agents/skills/<name>/`，项目 `<cwd>/.agents/skills/<name>/`；
// 同名时项目级覆盖全局级。
//
// 本模块产出的两样东西：
//   - print_installed()：拼进系统提示词的 `<available_skills>` 块（模型据此决定读哪个）；
//   - print_brief()：`--list-skills` 的简表，供人查看。
//
// llmcli 里 Python 是唯一工具，所以提示词让模型用 Python（open/pathlib）去读 SKILL.md，
// 而不是 mini_pi 里的 ReadFile 工具。

// ---- 常量 ----

const String SKILL_FILE = "SKILL.md";
const String SKILLS_SUBDIR = "skills";
const String ASSETS_DIR = ".agents";

// 拼进系统提示词的开场说明：告诉模型何时读、怎么读、相对路径怎么解析。
// 用不含反引号的原文，避免 C3 原始字符串里出现反引号。
const String INSTALLED_HEADER = `若 <available_skills> 里有明显适用于当前任务的 skill，用 Python（open / pathlib）读取其 <location> 指向的 SKILL.md，再照其执行。
若多个都沾边，选最贴切的那个；若都不贴切，一个都不要读。
skill 文件里引用相对路径时，以该 SKILL.md 所在目录为基准解析成绝对路径再使用。`;

// ---- 类型 ----

// 一个已安装 skill：SKILL.md 的 front matter（name/description）+ 正文 + 位置。
// 全部字段都由 SkillHub 的 allocator 持有，由 SkillHub.free 统一释放（allocator 为 tmem 时跳过）。
struct Skill
{
	String name;        // front matter: name
	String description; // front matter: description
	String content;     // front matter 之后的正文（Markdown body）
	String location;    // SKILL.md 的路径
}

struct SkillHub
{
	List{Skill} skills;
	Allocator allocator;
}

// ---- 装配入口 ----

// 从默认两处（~/.agents/skills、<cwd>/.agents/skills）发现并加载。
// allocator 传 mem 时是长期持有、用完需 free()；传 tmem 时随 pool 回收、不要 free()。
fn void SkillHub.init(&self, Allocator allocator, String assets_dir)
{
	List{Path} dirs;
	dirs.init(tmem);
	defer dirs.free();
	collect_candidate_dirs(&dirs, assets_dir);
	self.load_dirs(allocator, dirs.to_array(tmem));
}

// 从显式目录列表加载（init 与单元测试共用）。同名去重，项目级后加载者覆盖先加载者。
fn void SkillHub.load_dirs(&self, Allocator allocator, Path[] dirs)
{
	self.allocator = allocator;
	self.skills.init(allocator);

	foreach (dir : dirs)
	{
		Skill skill;
		if (!load_skill(allocator, &skill, dir))
		{
			// 未通过校验：释放解析中已分配的字段（空字段的 free 有 ptr 守卫）
			skill.free(allocator);
			continue;
		}

		if (try index = find_skill(&self.skills, skill.name))
		{
			Skill old = self.skills.get(index);
			old.free(allocator);
			self.skills.set_at(index, skill);
		}
		else
		{
			self.skills.push(skill);
		}
	}

	sort_skills(&self.skills);
}

// ---- 列表组装 ----

// 系统提示词注入块：无 skill 时返回空串（不要往提示词里塞“没有技能”这种噪音）。
fn String SkillHub.print_installed(&self, Allocator allocator)
{
	if (!self.skills.len()) return "";

	DString buf = dstring::new(tmem);
	buf.append(INSTALLED_HEADER);
	buf.append("\n\n<available_skills>\n");
	foreach (skill : self.skills)
	{
		buf.appendf("  <skill>\n");
		buf.appendf("    <name>%s</name>\n", escape_xml(skill.name));
		buf.appendf("    <description>%s</description>\n", escape_xml(skill.description));
		buf.appendf("    <location>%s</location>\n", escape_xml(slashify(skill.location)));
		buf.appendf("  </skill>\n");
	}
	buf.append("</available_skills>");

	return buf.copy_str(allocator);
}

// 简表：每行 `<序号>. <name>: <description>`，供 --list-skills 打印、便于 grep。
fn String SkillHub.print_brief(&self, Allocator allocator)
{
	if (!self.skills.len()) return "No skill found";

	DString buf = dstring::new(tmem);
	sz index = 1;
	foreach (skill : self.skills)
	{
		buf.appendf("%d. %s: %s\n", index, skill.name, skill.description);
		index++;
	}

	return buf.copy_str(allocator);
}

// ---- 释放 ----

fn void SkillHub.free(&self)
{
	if (self.allocator == null) return;
	for (sz i = 0; i < self.skills.len(); i++)
	{
		Skill skill = self.skills.get(i);
		skill.free(self.allocator);
	}
	self.skills.free();
	self.allocator = null;
}

fn void Skill.free(&self, Allocator allocator)
{
	self.name.free(allocator);
	self.description.free(allocator);
	self.content.free(allocator);
	self.location.free(allocator);
}

// ---- 目录发现 ----

fn void collect_candidate_dirs(List{Path}* dirs, String assets_dir) @private
{
	// 全局：~/.agents/skills
	if (try home = path::home_directory(tmem))
	{
		collect_from_dir(dirs, home.tappend(assets_dir, SKILLS_SUBDIR)!!);
	}

	// 项目：<cwd>/.agents/skills
	if (try cwd = path::tcwd())
	{
		collect_from_dir(dirs, cwd.tappend(assets_dir, SKILLS_SUBDIR)!!);
	}
}

fn void collect_from_dir(List{Path}* dirs, Path skills_home) @private
{
	if (!path::exists(skills_home)) return;

	PathList? entries = path::ls(tmem, skills_home);
	if (catch entries) return;

	foreach (entry : entries)
	{
		Path dir = skills_home.tappend(entry)!!;
		if (path::is_dir(dir)) dirs.push(dir);
	}
}

// ---- 单个 skill 解析 ----

// 读 <dir>/SKILL.md，解析 front matter 与正文。name/description/content 三者齐全才算有效。
fn bool load_skill(Allocator allocator, Skill* skill, Path dir) @private
{
	String skill_file = dir.tappend(SKILL_FILE)!!;
	Path skill_path = (Path)skill_file;
	if (!path::exists(skill_path)) return false;

	char[]? data = file::load_path(tmem, skill_path);
	if (catch data) return false;
	String text = (String)data;

	String[] lines = text.tsplit("\n", skip_empty: false);

	// front matter 以首行 --- 开始、下一行 --- 结束；结束前的行按 `key: value` 解析，
	// 只取首个别名（name / description）。front matter 之后才是正文。
	bool in_front = false;
	bool front_done = false;
	DString body = dstring::new(tmem);

	foreach (line : lines)
	{
		String trimmed = line.trim();

		if (!front_done && trimmed == "---")
		{
			if (!in_front)
			{
				in_front = true;
				continue;
			}
			in_front = false;
			front_done = true;
			continue;
		}

		if (in_front)
		{
			if (try colon = line.index_of(":"))
			{
				if (colon == 0) continue;
				String key = line[:colon].trim();
				String value = try_unescape(line[colon + 1..]);
				if (key == "name" && !skill.name.len)
				{
					skill.name = value.copy(allocator);
				}
				else if (key == "description" && !skill.description.len)
				{
					skill.description = value.copy(allocator);
				}
			}
			continue;
		}

		if (front_done) body.append(line);
		if (front_done) body.append("\n");
	}

	// body 目前是 tmem 视图，trim 后再 copy 到 allocator，得到可安全 free 的独立串
	String content = body.str_view().trim();
	if (content.len) skill.content = content.copy(allocator);

	skill.location = skill_file.copy(allocator);

	// name、description、content 三者非空才是一个可用的 skill
	return skill.name.len != 0 && skill.description.len != 0 && skill.content.len != 0;
}

// front matter 值：去掉包裹的引号并还原转义（多行/单行皆然）。
fn String try_unescape(String value) @private
{
	String trimmed = value.trim();
	bool double_quoted = trimmed.len >= 2 && trimmed[0] == '"' && trimmed[^1] == '"';
	bool single_quoted = trimmed.len >= 2 && trimmed[0] == '\'' && trimmed[^1] == '\'';
	if (double_quoted || single_quoted)
	{
		if (try unescaped = trimmed.tunescape()) return unescaped;
	}
	return trimmed;
}

// ---- 小工具 ----

fn sz? find_skill(List{Skill}* skills, String name) @private
{
	for (sz i = 0; i < skills.len(); i++)
	{
		if (skills.get(i).name == name) return i;
	}
	return NOT_FOUND~;
}

// 按 name 升序插入排序：数量小（每处目录几个），稳定且无需引入 sort 依赖。
fn void sort_skills(List{Skill}* skills) @private
{
	for (sz i = 1; i < skills.len(); i++)
	{
		Skill key = skills.get(i);
		sz j = i;
		while (j > 0 && skills.get(j - 1).name.compare_to(key.name) > 0)
		{
			skills.set_at(j, skills.get(j - 1));
			j--;
		}
		skills.set_at(j, key);
	}
}

fn String escape_xml(String str) @private
{
	return str.treplace("&", "&amp;").treplace("<", "&lt;").treplace(">", "&gt;")
		.treplace("\"", "&quot;").treplace("'", "&apos;");
}

// 路径统一成正斜杠：Windows 的反斜杠在提示词里容易被当转义符
fn String slashify(String path) @private
{
	return path.treplace("\\", "/");
}
