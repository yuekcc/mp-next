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

// 已注册的敏感串：注册一次，所有日志输出前自动脱敏，不再依赖调用方记得调 redact。
// ponytail: 固定 8 槽（一个 CLI 进程只注册 api_key），满了静默忽略。
const usz MAX_SECRETS = 8;
String[MAX_SECRETS] secrets;
usz secret_count;

fn void add_secret(String secret)
{
	if (!secret.len || secret_count >= MAX_SECRETS) return;
	secrets[secret_count++] = secret;
}

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

// 把文本里所有已注册密钥替换成脱敏形态
fn String redact(String text)
{
	for (usz i = 0; i < secret_count; i++)
	{
		text = text.replace(tmem, secrets[i], mask_secret(secrets[i]));
	}
	return text;
}

// 先格式化再脱敏，四级日志共用。格式化走 tmem，与 redact 同生命周期。
fn String fmt_redacted(String format, args...) @private
{
	return redact(string::tformat(format, ...args));
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
	io::eprintfn("%s", fmt_redacted(format, ...args));
}

fn void warn(String format, args...)
{
	if (logger.quiet) return;
	tag("warn:", C_YELLOW);
	io::eprintfn("%s", fmt_redacted(format, ...args));
}

// 每轮 turn 摘要与 Trace 起止走这里
fn void info(String format, args...)
{
	if (logger.quiet) return;
	if (logger.color) io::eprintf("%s", C_DIM);
	io::eprintfn("%s", fmt_redacted(format, ...args));
	if (logger.color) io::eprintf("%s", C_RESET);
}

fn void debug(String format, args...)
{
	if (!logger.debug) return;
	tag("debug:", C_CYAN);
	io::eprintfn("%s", fmt_redacted(format, ...args));
}
