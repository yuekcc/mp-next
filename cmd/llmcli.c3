module llmcli;

import std::io;
import llmcli::agent, llmcli::cli, llmcli::http, llmcli::log, llmcli::session, llmcli::tools;

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

fn int main(String[] args)
{
	cli::ParseResult parsed = cli::parse(args);
	log::init(parsed.opts.quiet, parsed.opts.debug, parsed.opts.no_color);

	if (parsed.opts.help)
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
	if (parsed.opts.list_sessions) return list_sessions();

	if (!session::valid_id(parsed.opts.session_id) && parsed.opts.session_id.len)
	{
		log::error("--session-id 只能包含文件名安全字符，且不能含 ..");
		return cli::EXIT_USAGE;
	}

	tools::install_interrupt_handler();
	tools::register_builtin_tools();

	http::http_init();
	defer http::http_deinit();

	return agent::run(&parsed.opts);
}
