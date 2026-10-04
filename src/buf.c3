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

// 只用于 stderr 展示（--debug / 错误摘要）：仅为可读性截断，不影响落盘与回填。
// 截断点回退到 UTF-8 字符边界（续字节特征 10xxxxxx），否则半个多字节字符写进 stderr 就是非法 UTF-8。
// 被 client / runtime 等多处使用，保留在此共享。
fn String truncate(String text, usz limit)
{
	if (text.len <= limit) return text;
	usz cut = limit;
	while (cut > 0 && (text[cut] & 0xC0) == 0x80) cut--;
	return string::tformat("%s…（已截断，共 %d 字节）", text[:cut], text.len);
}
