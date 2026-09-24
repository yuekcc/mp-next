module llmcli::tools;

import std::io;
import cjson;

// 读取文本文件并按行回填。offset 是 1-based 起始行（<=0 表示从头），limit 是最多行数（<=0 表示不限制）。
// 行号前缀 `N\t` 便于模型在 EditFile 时定位；不引入 hash 机制（mp-next 无对应 util）。
fn ToolResult tool_read_file(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	if (!path.len) return fail("缺少必填参数 path（字符串）");

	int offset = args.get_key_int("offset") ?? 0;
	int limit = args.get_key_int("limit") ?? 0;

	char[]? loaded = file::load(tmem, path);
	if (catch err = loaded) return fail(string::tformat("无法读取 %s：%s", path, err));
	String text = (String)loaded;

	String[] lines = text.split(tmem, "\n");
	usz total = lines.len;
	usz start = offset > 0 ? (usz)(offset - 1) : 0;
	if (start >= total) return fail(string::tformat("文件共 %d 行，offset %d 越界", total, offset));

	usz end = total;
	if (limit > 0)
	{
		end = start + (usz)limit;
		if (end > total) end = total;
	}

	DString buf = dstring::new(tmem);
	for (usz i = start; i < end; i++)
	{
		buf.appendf("%d\t%s\n", i + 1, lines[i]);
	}
	buf.appendf("(读取 %s：共 %d 行，显示 %d-%d)", path, total, start + 1, end);
	return ok(buf.str_view());
}
