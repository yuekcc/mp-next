module tool;

import std::io;
import std::io::path;
import std::collections::list;

import cjson;
import cmd;

// schema（grep_tool_schema.json）声明的输入范围，越界一律夹紧：context 0..20、limit 1..200。
// LLM 可能给出越界值，rg 自身不做边界保护（context=9999 会把整个文件吐出来）。
const int GREP_CONTEXT_MAX = 20;
const int GREP_LIMIT_MIN = 1;
const int GREP_LIMIT_MAX = 200;

// 无命中时的工具输出：rg 用退出码 1 表示「没找到」，那是正常结果不是错误，
// 但空字符串会被当成空 tool_result 塞进消息列表，这里给一句明确的话。
const String GREP_NO_MATCH = "No matches found.";

fn void? grep(
	Allocator allocator,
	DString* out,
	String pattern,
	String file_path = "",
	String glob = "",
	bool ignore_case = false,
	bool literal = false,
	int context = 0,
	int limit = 100
)
{
	if (pattern == "") return INVALID_COMMAND_PARAM~;

	if (context < 0) context = 0;
	if (context > GREP_CONTEXT_MAX) context = GREP_CONTEXT_MAX;
	if (limit < GREP_LIMIT_MIN) limit = GREP_LIMIT_MIN;
	if (limit > GREP_LIMIT_MAX) limit = GREP_LIMIT_MAX;

	List{String} final_command;
	final_command.init(tmem);

	final_command.push("rg");
	final_command.push("--vimgrep");
	// --color never：输出走管道，但若环境设了 RIPGREP_CONFIG_PATH/NO_COLOR 之外的配色配置，
	//   ANSI 转义会混进 tool_result。
	// --path-separator /：Windows 上 rg 默认拼 '\'，工具结果里的路径分隔符要统一成 '/'。
	final_command.push("--color");
	final_command.push("never");
	final_command.push("--path-separator");
	final_command.push("/");
	final_command.push(pattern);
	if (file_path != "")
	{
		final_command.push(file_path);
	}
	if (glob != "")
	{
		final_command.push("--glob");
		final_command.push(glob);
	}
	if (ignore_case)
	{
		final_command.push("--ignore-case");
	}
	if (literal)
	{
		final_command.push("--fixed-strings");
	}
	if (context > 0)
	{
		final_command.push("-C");
		final_command.push(string::format(tmem, "%d", context));
	}

	CommandResult result = cmd::execute(allocator, final_command.to_array(tmem))!;
	// rg 退出码：0 = 有命中，1 = 无命中，2 = 错误（正则非法、路径不存在等）。
	if (result.code == 2) return EXECUTE_RIPGREP_COMMAND_ERROR~;

	String trimmed = result.output.trim();
	if (trimmed == "")
	{
		out.append(GREP_NO_MATCH);
		return;
	}

	String[] lines = trimmed.split(tmem, "\n");
	if ((int)lines.len <= limit)
	{
		out.append(trimmed);
		return;
	}

	for (int i = 0; i < limit; i++)
	{
		if (i > 0) out.append("\n");
		out.append(lines[i]);
	}
	// 静默截断会让模型误以为结果完整，必须显式告知。
	out.appendf("\n... (truncated: showing %d of %d lines)", limit, lines.len);
}

const String GREP_SCHEMA = (String)$embed("grep_tool_schema.json");

struct GrepTool (Tool)
{
	bool _pad;
}

fn String GrepTool.name(&self) @dynamic
{
	return "Grep";
}

fn String GrepTool.description(&self) @dynamic
{
	return "Search file contents for a pattern (regex by default, literal when `literal` is true). Returns matching lines with file path, line and column numbers. Respects .gitignore. Supports `glob` filter, `ignoreCase`, `context` (0-20) and `limit` (1-200, default 100).";
}

fn String GrepTool.schema(&self) @dynamic
{
	return GREP_SCHEMA;
}

fn void? GrepTool.execute(&self, ToolContext* ctx, Allocator allocator, DString* out, CJsonItem* args, ToolResultMeta* meta) @dynamic
{
	String pattern   = args.get_key_string("pattern", tmem) ?? "";
	String file_path = args.get_key_string("path", tmem) ?? "";
	String glob      = args.get_key_string("glob", tmem) ?? "";
	bool ignore_case = args.get_key_bool("ignoreCase") ?? false;
	bool literal     = args.get_key_bool("literal") ?? false;
	int context      = args.get_key_int("context") ?? 0;
	int limit        = args.get_key_int("limit") ?? 100;
	grep(allocator, out, pattern, file_path, glob, ignore_case, literal, context, limit)!;
}
