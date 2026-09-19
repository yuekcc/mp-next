module llmcli::buf;

import libc, std::io;

// 可变长字节缓冲。用 libc malloc/realloc 而不是 tmem：
// 既要在 libcurl 回调里增长，也要在工作线程里增长，都不便依赖 @pool 生命周期。
struct ByteBuf
{
	char* ptr;
	usz len;
	usz cap;
}

fn bool ByteBuf.append(&self, char[] data)
{
	if (self.len + data.len > self.cap)
	{
		usz cap = self.cap ? self.cap : 8192;
		while (cap < self.len + data.len) cap *= 2;
		char* next = (char*)libc::realloc(self.ptr, cap);
		if (!next) return false;
		self.ptr = next;
		self.cap = cap;
	}
	mem::copy(self.ptr + self.len, data.ptr, (sz)data.len);
	self.len += data.len;
	return true;
}

fn String ByteBuf.to_string(&self, Allocator allocator)
{
	if (!self.len) return "";
	return ((String)self.ptr[:self.len]).copy(allocator);
}

fn void ByteBuf.free(&self)
{
	if (self.ptr) libc::free(self.ptr);
	self.ptr = null;
	self.len = 0;
	self.cap = 0;
}

// 一直读到 EOF。读失败按 EOF 处理（调用方随后能从退出码/空结果看出来）。
fn void read_all(File* file, ByteBuf* out)
{
	char[8192] chunk;
	while (true)
	{
		sz n = file.read(chunk[..]) ?? -1;
		if (n <= 0) break;
		if (!out.append(chunk[:n])) break;
	}
}

// C 字符串 -> 归 allocator 所有的 String。null 视作空串。
fn String cstr(Allocator allocator, ZString z)
{
	if (!z) return "";
	usz len = libc::strlen(z);
	if (!len) return "";
	return ((String)z[:len]).copy(allocator);
}

// 只用于 stderr 展示（--debug / 错误摘要）：仅为可读性截断，不影响落盘与回填。
// 截断点回退到 UTF-8 字符边界（续字节特征 10xxxxxx），否则半个多字节字符写进 stderr 就是非法 UTF-8。
fn String truncate(String text, usz limit)
{
	if (text.len <= limit) return text;
	usz cut = limit;
	while (cut > 0 && (text[cut] & 0xC0) == 0x80) cut--;
	return string::tformat("%s…（已截断，共 %d 字节）", text[:cut], text.len);
}
