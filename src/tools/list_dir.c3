module llmcli::tools;

import std::io, std::io::path, std::sort, std::collections::list;
import cjson;

struct LsEntry
{
	String name;
	bool is_dir;
	long size;
}

fn int _ls_entry_cmp(LsEntry a, LsEntry b)
{
	if (a.is_dir != b.is_dir) return a.is_dir ? -1 : 1;
	return a.name.compare_to(b.name);
}

// 纯 c3 列举目录：目录在前、文件在后，各自按名升序；文件附人类可读大小；
// 末行输出 Summary（文件/目录计数）。limit<=0 表示不限制（对齐 mini_pi 默认 500）。
fn ToolResult tool_list_dir(CJsonItem* args)
{
	String dir_path = args.get_key_string("path", tmem) ?? ".";
	int limit = args.get_key_int("limit") ?? 500;

	Path dir;
	if (try d = path::new(tmem, dir_path)) { dir = d; }
	else { return fail(string::tformat("非法路径 %s", dir_path)); }
	if (!path::exists(dir)) return fail(string::tformat("目录不存在：%s", dir_path));
	if (!path::is_dir(dir)) return fail(string::tformat("不是目录：%s", dir_path));

	PathList? maybe = path::ls(tmem, dir);
	if (catch err = maybe) return fail(string::tformat("列举 %s 失败：%s", dir_path, err));
	PathList entries = maybe;

	list::List{LsEntry} list;
	list.init(tmem);
	foreach (entry : entries)
	{
		LsEntry e;
		e.name = entry.basename();
		Path full = dir.tappend(entry.basename())!!;
		e.is_dir = path::is_dir(full);
		e.size = e.is_dir ? 0 : (path::file_size(full) ?? 0);
		list.push(e);
	}
	sort::quicksort(list.array_view(), &_ls_entry_cmp);

	int files = 0;
	int dirs = 0;
	int shown = 0;
	DString buf = dstring::new(tmem);
	foreach (&e : list)
	{
		if (e.is_dir) { dirs++; } else { files++; }
		if (limit > 0 && shown >= limit) { continue; }
		if (e.is_dir)
		{
			buf.appendf("%s/\n", e.name);
		}
		else
		{
			buf.appendf("%s\t%s\n", e.name, human_size(e.size));
		}
		shown++;
	}
	if (limit > 0 && shown < (int)list.len())
	{
		buf.appendf("... (%d more entries)\n", (int)list.len() - shown);
	}
	buf.appendf("Summary: %d files, %d dirs", files, dirs);

	return ok(buf.str_view());
}

// 字节数 -> 人类可读：193B / 3.2K / 3.3M / 1.0G
fn String human_size(long size)
{
	if (size < 1024) return string::tformat("%dB", size);
	double b = (double)size;
	if (b < 1024.0 * 1024.0) return string::tformat("%.1fK", b / 1024.0);
	if (b < 1024.0 * 1024.0 * 1024.0) return string::tformat("%.1fM", b / (1024.0 * 1024.0));
	return string::tformat("%.1fG", b / (1024.0 * 1024.0 * 1024.0));
}
