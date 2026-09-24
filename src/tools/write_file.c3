module llmcli::tools;

import std::io, std::io::path;
import cjson;
import llmcli::log;

fn ToolResult tool_write_file(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	String content = args.get_key_string("content", tmem) ?? "";
	if (!path.len) return fail("缺少必填参数 path（字符串）");

	// file::save 不建父目录：手动补一层，对齐 mini_pi 的 WriteFile 语义。
	if (try p = path::new(tmem, path))
	{
		if (try parent = p.parent())
		{
			if (!path::exists(parent))
			{
				if (try made = path::mkdir(parent, true)) { /* ok */ }
				else { return fail(string::tformat("无法创建父目录 %s", (String)parent)); }
			}
		}
	}

	if (catch err = file::save(path, content))
	{
		return fail(string::tformat("写入 %s 失败：%s", path, err));
	}

	log::info("[write_file] %s (%d 字节)", path, content.len);
	return ok(string::tformat("已写入 %s（%d 字节）", path, content.len));
}
