module llmcli::tools;

import std::io;
import cjson;
import llmcli::log;

fn ToolResult tool_edit_file(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	String old_text = args.get_key_string("old_string", tmem) ?? "";
	String new_text = args.get_key_string("new_string", tmem) ?? "";
	bool allow_multiple = args.get_key_bool("allow_multiple") ?? false;

	if (!path.len) return fail("缺少必填参数 path（字符串）");
	if (!old_text.len) return fail("缺少必填参数 old_string（字符串）");
	if (old_text == new_text) return fail("old_string 与 new_string 相同，无需修改");

	char[]? loaded = file::load(tmem, path);
	if (catch err = loaded) return fail(string::tformat("无法读取 %s：%s", path, err));
	String text = (String)loaded;

	// 唯一匹配才动手（除非显式 allow_multiple），避免改坏文件
	usz hits = count_occurrences(text, old_text);
	if (hits == 0) { return fail(string::tformat("在 %s 中找不到 old_string（不做修改）", path)); }
	if (hits > 1 && !allow_multiple)
	{
		return fail(string::tformat("old_string 在 %s 中出现 %d 次，不唯一（不做修改）。"
		                            "需多处替换请设 allow_multiple=true", path, hits));
	}

	// 从头扫描，按非重叠出现依次替换；allow_multiple=false 只换第一处。
	DString buf = dstring::new(tmem);
	usz i = 0;
	usz replaced = 0;
	while (i <= text.len - old_text.len)
	{
		if (text[i : old_text.len] == old_text)
		{
			buf.append(new_text);
			i += old_text.len;
			replaced++;
			if (!allow_multiple) break;
		}
		else
		{
			buf.append(text[i : 1]);
			i++;
		}
	}
	buf.append(text[i : text.len - i]);

	if (catch err = file::save(path, buf.str_view()))
	{
		return fail(string::tformat("写入 %s 失败：%s", path, err));
	}

	log::info("[edit_file] %s 替换 %d 处", path, replaced);
	return ok(string::tformat("已修改 %s：替换 %d 处", path, replaced));
}

fn usz count_occurrences(String haystack, String needle)
{
	if (!needle.len || haystack.len < needle.len) return 0;
	usz count = 0;
	usz last = haystack.len - needle.len;
	for (usz i = 0; i <= last; i++)
	{
		if (haystack[i : needle.len] == needle) count++;
	}
	return count;
}
