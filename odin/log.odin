package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"

// ---- 分节 ----
// stderr 的**唯一出口**：四级日志 + 密钥自动脱敏。调用方不必手动 redact，直接打原文即可。
// 颜色只在 stderr 是 tty 且未加 --no-color 时输出（重定向到文件/管道不能出现 ANSI 转义）。
//
// 这是"未来换 logger 模块"的唯一替换点。

// ---- 常量 ----

C_RESET :: "\e[0m"
C_DIM :: "\e[2m"
C_RED :: "\e[31m"
C_YELLOW :: "\e[33m"
C_CYAN :: "\e[36m"

// 已注册的敏感串上限；一个 CLI 进程只注册 api_key，满了静默忽略。
MAX_SECRETS :: 8

// ---- 状态 ----

Logger :: struct {
	quiet: bool,
	debug: bool,
	color: bool,
}

g_logger: Logger
g_secrets: [MAX_SECRETS]string
g_secret_count: int

// ---- 开关 ----

log_init :: proc(quiet: bool, debug: bool, no_color: bool) {
	g_logger = {quiet = quiet, debug = debug, color = !no_color && terminal.is_terminal(os.stderr)}
}

log_add_secret :: proc(secret: string) {
	if secret == "" || g_secret_count >= MAX_SECRETS {
		return
	}
	g_secrets[g_secret_count] = secret
	g_secret_count += 1
}

// stdin 是否终端（parse 判断“有没有管道输入”时只问这一句，不读内容）。
is_stdin_terminal :: proc() -> bool {
	return terminal.is_terminal(os.stdin)
}

// 密钥脱敏：形如 sk-1234 -> sk-***234。短于/等于 6 位直接全遮。
mask_secret :: proc(secret: string) -> string {
	if len(secret) <= 6 {
		return "***"
	}
	return fmt.aprintf("%s***%s", secret[:3], secret[len(secret) - 3:],
	                   allocator = context.temp_allocator)
}

// 把文本里所有已注册密钥替换成脱敏形态（结果在 context.temp_allocator 上）。
log_redact :: proc(text: string) -> string {
	out := text
	for i in 0 ..< g_secret_count {
		out, _ = strings.replace_all(out, g_secrets[i], mask_secret(g_secrets[i]),
		                             context.temp_allocator)
	}
	return out
}

// ---- 分级输出 ----

log_tag :: proc(name: string, color: string) {
	if g_logger.color {
		fmt.eprintf("%s%s%s ", color, name, C_RESET)
	} else {
		fmt.eprintf("%s ", name)
	}
}

log_error :: proc(format: string, args: ..any) {
	log_tag("error:", C_RED)
	fmt.eprintfln("%s", log_redact(fmt.aprintf(format, ..args, allocator = context.temp_allocator)))
}

log_warn :: proc(format: string, args: ..any) {
	if g_logger.quiet {
		return
	}
	log_tag("warn:", C_YELLOW)
	fmt.eprintfln("%s", log_redact(fmt.aprintf(format, ..args, allocator = context.temp_allocator)))
}

log_info :: proc(format: string, args: ..any) {
	if g_logger.quiet {
		return
	}
	if g_logger.color {
		fmt.eprintf("%s", C_DIM)
	}
	fmt.eprintfln("%s", log_redact(fmt.aprintf(format, ..args, allocator = context.temp_allocator)))
	if g_logger.color {
		fmt.eprintf("%s", C_RESET)
	}
}

log_debug :: proc(format: string, args: ..any) {
	if !g_logger.debug {
		return
	}
	log_tag("debug:", C_CYAN)
	fmt.eprintfln("%s", log_redact(fmt.aprintf(format, ..args, allocator = context.temp_allocator)))
}
