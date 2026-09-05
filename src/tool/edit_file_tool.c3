module tool;

import std::io;
import std::io::path;
import std::io::file;
import std::collections::list;

import cjson;
import cmd;
import util;

// 统计 haystack 中 needle 的非重叠出现次数（对齐 Go strings.Count 语义）：
// 匹配成功后从匹配尾继续扫描，重叠出现不重复计数。
fn usz count_occurrences(String haystack, String needle)
{
	if (needle.len == 0 || needle.len > haystack.len) return 0;
	usz count = 0;
	usz i = 0;
	while (i + needle.len <= haystack.len)
	{
		if (haystack[i : needle.len] == needle)
		{
			count++;
			i += needle.len;
		}
		else
		{
			i++;
		}
	}
	return count;
}

// 从 start 开始查找 needle 首次出现的字节偏移，找不到返回 -1。
fn sz find_from(String haystack, String needle, usz start)
{
	if (needle.len == 0 || needle.len > haystack.len) return -1;
	usz max = haystack.len - needle.len;
	for (usz i = start; i <= max; i++)
	{
		if (haystack[i : needle.len] == needle) return (sz)i;
	}
	return -1;
}

fn void? edit_file(Allocator allocator, DString* out, String file_path, String old_string, String new_string, bool allow_multiple)
{
	if (old_string == new_string)
	{
		out.append("EditFile failed: old_string and new_string are identical; nothing to change.");
		return;
	}

	Path path_obj = path::new(tmem, file_path)!;
	if (!path::exists(path_obj))
	{
		out.appendf("EditFile failed: file %s does not exist.", path_obj);
		return;
	}

	// 与 ReadFile 共用行管线（util::load_lines 同款归一化 \r\n -> \n）：
	// read 视图 = edit 匹配视图，CRLF 文件可直接用 \n 匹配；
	// 写回统一 \n 行尾（与 HashEditFile 重建行为一致），不保留原 CRLF。
	String content = util::normalize_line_endings(tmem, (String)file::load_path(tmem, path_obj)!);
	usz count = count_occurrences(content, old_string);

	if (count == 0)
	{
		out.append("EditFile failed: could not find old_string in file. Ensure exact match including whitespace and line endings.");
		return;
	}
	if (count > 1 && !allow_multiple)
	{
		out.appendf(
			"EditFile failed: found %d occurrences of old_string. Please provide more context or set 'allow_multiple' to true.",
			count
		);
		return;
	}

	// 在归一化（\n）内容上做字节精确替换：前缀 + new_string + 后缀。
	// allow_multiple=false 只替换首个出现；否则替换全部非重叠出现。
	DString buf = dstring::new(tmem);
	usz i = 0;
	usz replaced = 0;
	while (true)
	{
		sz pos = find_from(content, old_string, i);
		if (pos < 0)
		{
			buf.append(content[i : content.len - i]);
			break;
		}
		buf.append(content[i : (usz)pos - i]);
		buf.append(new_string);
		replaced++;
		i = (usz)pos + old_string.len;
		if (!allow_multiple)
		{
			buf.append(content[i : content.len - i]);
			break;
		}
	}

	atomic_save(path_obj, buf.str_view())!;
	out.appendf("(Success, replaced %d occurrence(s) in %s)", replaced, path_obj);
}

const String EDIT_FILE_SCHEMA = (String)$embed("edit_file_tool_schema.json");

struct EditFileTool (Tool)
{
	bool _pad;
}

fn String EditFileTool.name(&self) @dynamic
{
	return "EditFile";
}

fn String EditFileTool.description(&self) @dynamic
{
	return "Performs precision string replacement in a file. Requires an exact, unique match for 'old_string' unless 'allow_multiple' is set. Preserves indentation; line endings are normalized to \\n (LF) on write.";
}

fn String EditFileTool.schema(&self) @dynamic
{
	return EDIT_FILE_SCHEMA;
}

fn void? EditFileTool.execute(&self, ToolContext* ctx, Allocator allocator, DString* out, CJsonItem* args, ToolResultMeta* meta) @dynamic
{
	String file_path    = args.get_key_string("file_path", tmem) ?? "";
	String old_string   = args.get_key_string("old_string", tmem) ?? "";
	String new_string   = args.get_key_string("new_string", tmem) ?? "";
	bool allow_multiple = args.get_key_bool("allow_multiple") ?? false;

	if (file_path == "") return INVALID_PATH_PARAM~;
	if (old_string == "") return INVALID_OLD_TEXT_PARAM~;

	edit_file(allocator, out, file_path, old_string, new_string, allow_multiple)!;
}
