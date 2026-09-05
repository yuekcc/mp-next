module tool;

import std::io;
import std::io::path;
import std::collections::list;

import cjson;
import cmd;

// schema（glob_tool_schema.json）声明：pattern 恒为 glob、大小写敏感、limit 1..1000。
const int FIND_LIMIT_MIN = 1;
const int FIND_LIMIT_MAX = 1000;

// fd 无命中时退出码仍是 0，输出为空；空 tool_result 对模型没有信息量。
const String FIND_NO_FILES = "No files found.";

// 拆出 pattern 的前导字面目录（不含 glob 元字符的路径片段），剩余部分回写到 remainder。
// fd 的 glob 不接受 'src/**/*.json' 这种带目录前缀的写法——即使加 --full-path，
// Windows 上 fd 也是拿绝对路径在比，照样匹配不到。所以把前导目录拆出来当搜索根：
//   'src/**/*.json' → 返回 'src'，remainder = '**/*.json'
//   'tool/*.json'   → 返回 'tool'，remainder = '*.json'
// 不可拆（'*.ts'、'**/*.ts'、'src' 这类）时 remainder 不变、返回 ""。
fn String split_leading_dir(String pattern, String* remainder)
{
	char[] metachars = { '*', '?', '[', '{' };
	String[] parts = pattern.split(tmem, "/");
	if (parts.len < 2) return "";

	DString dir = dstring::new(tmem);
	usz consumed = 0; // 已吞掉的字符数（含分隔符）
	foreach (part : parts)
	{
		if (part == "" || (part.index_of_chars(metachars) ?? -1) >= 0) break;
		if (consumed > 0) dir.append("/");
		dir.append(part);
		consumed += part.len + 1;
	}
	// 一个字面片段都没吞，或吞完没有剩余（'src'、'src/app'）→ 保持原样
	if (consumed == 0 || consumed >= pattern.len) return "";

	*remainder = pattern[consumed..];
	return dir.str_view();
}

fn void? find(Allocator allocator, DString* out, String pattern, String file_path = "", int limit = 500)
{
	if (pattern == "") return INVALID_COMMAND_PARAM~;

	if (limit < FIND_LIMIT_MIN) limit = FIND_LIMIT_MIN;
	if (limit > FIND_LIMIT_MAX) limit = FIND_LIMIT_MAX;

	List{String} final_command;
	final_command.init(tmem);

	final_command.push("fd");
	// --glob：pattern 恒为 glob（不再按「含元字符才切 glob」猜测，正则模式下
	//   '*.c3' 是非法正则、'a.b' 里的 '.' 会当通配符）。
	// --case-sensitive：fd 默认 smart case（pattern 无大写字母就忽略大小写），
	//   而 schema 明确要求大小写敏感。
	final_command.push("--glob");
	final_command.push("--case-sensitive");
	final_command.push("--color");
	final_command.push("never");
	final_command.push("--path-separator");
	final_command.push("/");

	String search_path = file_path;
	String glob_pattern = pattern;
	String leading_dir = split_leading_dir(pattern, &glob_pattern);
	if (leading_dir != "")
	{
		search_path = search_path == "" ? leading_dir : string::tformat("%s/%s", search_path, leading_dir);
	}

	// fd 的 glob 默认只匹配文件名，且 pattern 里出现 '/' 会直接报错退出
	// （"contains a path-separation character"）。拆掉前导目录后仍含分隔符的
	// pattern 一律加 --full-path，'**/*.ts' 这类路径 glob 才可用。
	// TODO '**/tool/*.json'（'**' 后跟具体目录）在 Windows 上仍是 0 命中：--full-path
	//   下 fd 疑似按绝对路径匹配，而这里没有前导目录可拆，绕不过去（'src/**/*.json'
	//   靠 split_leading_dir 绕过）。要根治只能放弃 fd 的 glob，像 ListDir 那样纯 c3
	//   遍历目录并按相对路径匹配。
	char[] path_separators = { '/', '\\' };
	if ((glob_pattern.index_of_chars(path_separators) ?? -1) >= 0)
	{
		final_command.push("--full-path");
	}

	final_command.push(glob_pattern);

	if (search_path != "")
	{
		final_command.push("--search-path");
		final_command.push(search_path);
	}

	// 多取 1 条：fd 到量即停止遍历，据此判断「还有更多」，同时输出量仍有上界。
	final_command.push("--max-results");
	final_command.push(string::format(tmem, "%d", limit + 1));

	CommandResult result = cmd::execute(allocator, final_command.to_array(tmem))!;
	if (result.code != 0) return EXECUTE_FD_COMMAND_ERROR~;

	String trimmed = result.output.trim();
	if (trimmed == "")
	{
		out.append(FIND_NO_FILES);
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
	out.appendf("\n... (truncated: showing %d files, more matched)", limit);
}

const String FIND_SCHEMA = (String)$embed("glob_tool_schema.json");

struct GlobTool (Tool)
{
	bool _pad;
}

fn String GlobTool.name(&self) @dynamic
{
	return "Glob";
}

fn String GlobTool.description(&self) @dynamic
{
	return "Find files by glob pattern (case-sensitive). Patterns without a '/' match file names at any depth. Patterns containing '/' match the path: a leading directory scopes the search ('src/**/*.json') and '**/' matches any number of directories ('**/*.ts'). Returns file paths. Respects .gitignore. At most `limit` results (1-1000, default 500).";
}

fn String GlobTool.schema(&self) @dynamic
{
	return FIND_SCHEMA;
}

fn void? GlobTool.execute(&self, ToolContext* ctx, Allocator allocator, DString* out, CJsonItem* args, ToolResultMeta* meta) @dynamic
{
	String pattern   = args.get_key_string("pattern", tmem) ?? "";
	String file_path = args.get_key_string("path", tmem) ?? "";
	int limit = args.get_key_int("limit") ?? 500;
	find(allocator, out, pattern, file_path, limit)!;
}
