module llmcli::log;

import std::io;

// v1 没有 logger 模块，所有过程信息在这里集中打印到 stderr。
// 后续要换 logger 时只改这一处（PRD「可观测性」）。
const String C_RESET = "\e[0m";
const String C_DIM = "\e[2m";
const String C_RED = "\e[31m";
const String C_YELLOW = "\e[33m";
const String C_CYAN = "\e[36m";

struct Logger
{
	bool quiet;
	bool debug;
	bool color;
}

Logger logger;

fn void init(bool quiet, bool debug, bool no_color)
{
	logger.quiet = quiet;
	logger.debug = debug;
	// 只有 stderr 是终端才上色：重定向到文件/管道时不能出现 ANSI 转义。
	logger.color = !no_color && io::stderr().isatty();
}

// 密钥脱敏：形如 sk-1234 -> sk-***234。短于 6 位直接全遮。
fn String mask_secret(String secret)
{
	if (secret.len <= 6) return "***";
	return secret[:3].tconcat("***").tconcat(secret[^3..^1]);
}

fn String redact(String text, String secret)
{
	if (!secret.len) return text;
	return text.replace(tmem, secret, mask_secret(secret));
}

fn void tag(String name, String color)
{
	if (logger.color)
	{
		io::eprintf("%s%s%s ", color, name, C_RESET);
	}
	else
	{
		io::eprintf("%s ", name);
	}
}

fn void error(String format, args...)
{
	tag("error:", C_RED);
	io::eprintfn(format, ...args);
}

fn void warn(String format, args...)
{
	if (logger.quiet) return;
	tag("warn:", C_YELLOW);
	io::eprintfn(format, ...args);
}

// 每轮 turn 摘要与 Trace 起止走这里
fn void info(String format, args...)
{
	if (logger.quiet) return;
	if (logger.color) io::eprintf("%s", C_DIM);
	io::eprintfn(format, ...args);
	if (logger.color) io::eprintf("%s", C_RESET);
}

fn void debug(String format, args...)
{
	if (!logger.debug) return;
	tag("debug:", C_CYAN);
	io::eprintfn(format, ...args);
}
