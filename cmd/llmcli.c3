module llmcli;

import std::io;
import llmcli::agent, llmcli::cli, llmcli::http, llmcli::log, llmcli::runtime, llmcli::session, llmcli::skill;

fn int list_sessions()
{
	session::SessionSummary[] items = session::list_all(mem);
	if (!items.len)
	{
		io::printn("(没有会话)");
		return cli::EXIT_OK;
	}
	foreach (item : items)
	{
		io::printfn("%s\t%s\t%d 条消息", item.id, item.updated, (int)item.count);
	}
	return cli::EXIT_OK;
}

fn int list_skills()
{
	skill::SkillHub hub;
	hub.init(mem, cli::SKILLS_ASSETS_DIR);
	defer hub.free();

	String brief = hub.print_brief(tmem);
	io::print(brief);
	if (!brief.ends_with("\n")) io::printn("");
	return cli::EXIT_OK;
}

// 打印实际会作为 messages[0] 发给端点的系统提示词（resolve 已装配好）。
fn int print_system_prompt(cli::Ctx* ctx)
{
	io::print(ctx.system_prompt);
	if (!ctx.system_prompt.ends_with("\n")) io::printn("");
	return cli::EXIT_OK;
}

fn int main(String[] args)
{
	// 解析与初始化：先解析，再据开关初始化日志与密钥脱敏，
	// 然后短路处理 --help / 用法错误 / --list-sessions。
	cli::ParseResult parsed = cli::resolve(args);
	session::set_config_dir(parsed.ctx.config_dir);
	log::init(parsed.ctx.quiet, parsed.ctx.debug, parsed.ctx.no_color);
	log::add_secret(parsed.ctx.api_key);

	if (parsed.ctx.help)
	{
		io::printn(cli::HELP);
		return cli::EXIT_OK;
	}
	if (parsed.error.len)
	{
		log::error("%s", parsed.error);
		io::eprintfn("%s", cli::USAGE);
		io::eprintfn("运行 llmcli --help 查看全部 flags");
		return cli::EXIT_USAGE;
	}
	if (parsed.ctx.list_sessions) return list_sessions();
	if (parsed.ctx.list_skills) return list_skills();
	if (parsed.ctx.print_system_prompt) return print_system_prompt(&parsed.ctx);

	// 一次真实运行：装中断处理器、起 libcurl，然后交给 Trace 循环。
	runtime::install_interrupt_handler();

	http::http_init();
	defer http::http_deinit();

	return agent::run(&parsed.ctx);
}
