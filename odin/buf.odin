package main

import "core:fmt"
import "core:strings"

// ---- 分节 ----
// 跨模块共享的小工具：仅为 stderr 展示服务的 UTF-8 安全截断。
// 不影响落盘与回填；截断点回退到 UTF-8 字符边界，避免把半个多字节字符写进 stderr。
//
// 归属：结果可能借用入参（未截断时），也可能新分配（截断时走 context.temp_allocator）。
// 调用方只做即时展示，不必释放；需要长期持有的自行拷贝。

truncate :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	cut := limit
	for cut > 0 && (text[cut] & 0xC0) == 0x80 {
		cut -= 1
	}
	return fmt.aprintf("%s…（已截断，共 %d 字节）", text[:cut], len(text), allocator = context.temp_allocator)
}

// 把反斜杠统一成正斜杠。Windows 的 os.make_directory_all 对「混用分隔符」会报
// Permission_Denied，所以内部路径一律先 slashify 再用 "/" 拼接，保证全为 "/"。
slashify :: proc(path: string) -> string {
	out, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return out
}
