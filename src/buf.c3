module llmcli::buf;

import libc, std::core::string;

// 跨模块共享的小工具：C 字符串转换与 UTF-8 安全截断。

// ---- 转换 ----

// C 字符串 -> 归 allocator 所有的 String。null 视作空串。
fn String cstr(Allocator allocator, ZString z)
{
	if (!z) return "";
	usz len = libc::strlen(z);
	if (!len) return "";
	return ((String)z[:len]).copy(allocator);
}

// ---- 展示 ----

// 返回不越过 limit、且落在 UTF-8 字符边界上的字节数：若 limit 落在多字节字符中间
// （续字节特征 10xxxxxx），向前回退到该字符起点。所有「按字节截前缀」的调用方都应走这里，
// 否则半个多字节字符写进目录名/日志/终端就是非法 UTF-8（下游解码显示为替换方块）。
fn usz utf8_cut(String text, usz limit)
{
	if (limit >= text.len) return text.len;
	usz cut = limit;
	while (cut > 0 && (text[cut] & 0xC0) == 0x80) cut--;
	return cut;
}

// 只用于 stderr 展示（--debug / 错误摘要）：仅为可读性截断，不影响落盘与回填。
// 被 agent / runtime 等多处使用，保留在此共享。
fn String truncate(String text, usz limit)
{
	if (text.len <= limit) return text;
	usz cut = utf8_cut(text, limit);
	return string::tformat("%s…（已截断，共 %d 字节）", text[:cut], text.len);
}
