module llmcli::test_skill;

import std::io::path, std::io::file;
import std::collections::list;
import llmcli::skill;

// ---- 夹具 ----

const String WORK = "build/skill_test";

fn String skill_md(String name, String description, String body) @private
{
	return string::tformat("---\nname: %s\ndescription: %s\n---\n\n%s\n", name, description, body);
}

// 在 <root>/<dir_name>/SKILL.md 写一个技能目录，返回该目录。
fn Path make_skill(String root, String dir_name, String name, String description, String body) @private
{
	Path dir = (Path)string::tformat("%s/%s", root, dir_name);
	(void)path::mkdir(dir, true);
	(void)file::save(string::tformat("%s/SKILL.md", dir), skill_md(name, description, body));
	return dir;
}

fn Path work_dir(String name) @private
{
	Path dir = (Path)string::tformat("%s/%s", WORK, name);
	(void)path::mkdir(dir, true);
	return dir;
}

fn void release(skill::SkillHub* hub) @private
{
	if (hub.allocator != null) hub.free();
}

// ---- 加载与校验 ----

fn void test_loads_valid_skills_and_skips_invalid() @test
{
	@pool()
	{
		make_skill(WORK, "alpha", "alpha", "Alpha 简介", "# Alpha\n\n正文 A");
		make_skill(WORK, "beta", "beta", "\"Beta, 带逗号\"", "正文 B");
		// 无 SKILL.md 的目录、缺正文的 SKILL.md，都应被跳过
		(void)path::mkdir(work_dir("empty"), true);
		make_skill(WORK, "bad", "bad", "只有名字和描述", "");

		List{Path} dirs;
		dirs.init(tmem);
		dirs.push((Path)string::tformat("%s/alpha", WORK));
		dirs.push((Path)string::tformat("%s/beta", WORK));
		dirs.push((Path)string::tformat("%s/empty", WORK));
		dirs.push((Path)string::tformat("%s/bad", WORK));

		skill::SkillHub hub;
		hub.load_dirs(mem, dirs.to_array(tmem));
		defer release(&hub);

		test::eq(hub.skills.len(), 2);
		// 按 name 升序
		test::eq(hub.skills.get(0).name, "alpha");
		test::eq(hub.skills.get(1).name, "beta");
		test::eq(hub.skills.get(0).description, "Alpha 简介");
		test::eq(hub.skills.get(0).content, "# Alpha\n\n正文 A");
		// 引号包裹的 description 应去引号
		test::eq(hub.skills.get(1).description, "Beta, 带逗号");
		test::eq(hub.skills.get(1).content, "正文 B");
	};
}

fn void test_print_installed_xml() @test
{
	@pool()
	{
		make_skill(WORK, "x", "x", "带 <尖括号> & 的简介", "内容");

		List{Path} dirs;
		dirs.init(tmem);
		dirs.push((Path)string::tformat("%s/x", WORK));

		skill::SkillHub hub;
		hub.load_dirs(mem, dirs.to_array(tmem));
		defer release(&hub);

		String out = hub.print_installed(tmem);
		test::@check(out.contains("<available_skills>"), "应含 <available_skills>，实际：%s", out);
		test::@check(out.contains("<name>x</name>"), "应含 name，实际：%s", out);
		test::@check(out.contains("&lt;尖括号&gt; &amp; 的简介"), "description 应转义，实际：%s", out);
		// location 统一正斜杠
		test::@check(out.contains("build/skill_test/x/SKILL.md"), "location 应为正斜杠，实际：%s", out);
	};
}

fn void test_no_skills_is_empty() @test
{
	@pool()
	{
		skill::SkillHub hub;
		hub.load_dirs(mem, {});
		defer release(&hub);

		test::eq(hub.skills.len(), 0);
		test::eq(hub.print_installed(tmem), "");
		test::eq(hub.print_brief(tmem), "No skill found");
	};
}

fn void test_print_brief_lines() @test
{
	@pool()
	{
		make_skill(WORK, "a", "a", "A 简介", "内容");
		make_skill(WORK, "b", "b", "B 简介", "内容");

		List{Path} dirs;
		dirs.init(tmem);
		dirs.push((Path)string::tformat("%s/a", WORK));
		dirs.push((Path)string::tformat("%s/b", WORK));

		skill::SkillHub hub;
		hub.load_dirs(mem, dirs.to_array(tmem));
		defer release(&hub);

		test::eq(hub.print_brief(tmem), "1. a: A 简介\n2. b: B 简介\n");
	};
}

// 同名时后加载者覆盖先加载者（项目级覆盖全局级）
fn void test_duplicate_name_last_wins() @test
{
	@pool()
	{
		Path global = make_skill(WORK, "global", "dup", "旧简介", "旧内容");
		Path project = make_skill(WORK, "project", "dup", "新简介", "新内容");

		skill::SkillHub hub;
		hub.load_dirs(mem, { global, project });
		defer release(&hub);

		test::eq(hub.skills.len(), 1);
		test::eq(hub.skills.get(0).description, "新简介");
		test::eq(hub.skills.get(0).content, "新内容");
	};
}

// init 从默认两处发现；这里只验证不崩、且 default 路径下没有 skill 时是空表
fn void test_init_default_dirs_runs() @test
{
	@pool()
	{
		skill::SkillHub hub;
		hub.init(mem, ".agents");
		defer release(&hub);
		// 环境里有没有 skill 不确定，只断言能安全拿到字符串
		String installed = hub.print_installed(tmem);
		test::eq(installed.len == 0 || installed.contains("<available_skills>"), true);
	};
}
