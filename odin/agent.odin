package main

import "core:strings"

// ---- 分节 ----
// RLM 主循环（后续阶段填充）。当前只放代码块提取，其余见 tmp/odin-port-todo.md。

// ---- 类型 ----

// 从模型回复里取出的第一个代码块。code 在 context.temp_allocator 上。
Extract :: struct {
	code:      string, // 第一个代码块的内容；没有代码块时为空
	has_code:  bool,   // 是否真的找到了代码块（与 code 为空区分：空代码块 has_code=true）
	truncated: bool,   // 第一个代码块之后还有其他代码块（只执行第一个）
}

// ---- 代码块提取 ----

// 行级扫描：围栏行开块，之后第一条 trim 后恰为 ``` 的行闭块（heredoc 内除外）。
// 围栏形态：整行以 ``` 开头（含裸 ```、```bash、```sh），或 ```bash/```sh 缀在散文行末。
// 代码块内以 ``` 开头的行不当作闭块（避免代码里嵌 markdown 时早闭）。
// heredoc 感知：块内 `<<EOF` 开启、直到分隔符行结束，其间的 ``` 不闭块。
extract_code :: proc(response: string) -> Extract {
	out: Extract
	collected := make([dynamic]string, 0, 16, context.temp_allocator)
	lines := strings.split(response, "\n", context.temp_allocator)

	in_block := false
	closed := false
	heredoc := ""
	for line in lines {
		trimmed := strings.trim_space(line)
		rtrimmed := strings.trim_right_space(line)
		fence := strings.has_prefix(trimmed, "```") ||
			strings.has_suffix(rtrimmed, "```bash") || strings.has_suffix(rtrimmed, "```sh")

		if closed {
			if fence {
				out.truncated = true
			}
			continue
		}

		if !in_block {
			if fence {
				in_block = true
				out.has_code = true
			}
			continue
		}

		// heredoc 内：直到分隔符行，一律当代码
		if heredoc != "" {
			if trimmed == heredoc {
				heredoc = ""
			}
			append(&collected, line)
			continue
		}
		marker := heredoc_marker(line)
		if marker != "" {
			heredoc = marker
			append(&collected, line)
			continue
		}

		// 精确的闭围栏才收尾；块内其他 ``` 行当代码原样保留
		if trimmed == "```" {
			in_block = false
			closed = true
			continue
		}
		append(&collected, line)
	}

	if out.has_code {
		for len(collected) > 0 && strings.trim_space(collected[len(collected) - 1]) == "" {
			pop(&collected)
		}
		body := strings.builder_make(context.temp_allocator)
		for line in collected {
			strings.write_string(&body, line)
			strings.write_byte(&body, '\n')
		}
		out.code = strings.to_string(body)
	}
	return out
}

// 从一行里识别 heredoc 起始标记（`<<EOF` / `<<-EOF` / `<<"EOF"` / `<<'EOF'`）。
heredoc_marker :: proc(line: string) -> string {
	pos := strings.index(line, "<<")
	if pos < 0 {
		return ""
	}
	i := pos + 2
	if i < len(line) && line[i] == '-' {
		i += 1
	}
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	if i >= len(line) {
		return ""
	}
	rest := line[i:]
	first := rest[0]
	if first == '\'' || first == '"' {
		close := strings.index_byte(rest[1:], first)
		if close >= 0 {
			return rest[1:1 + close]
		}
		return ""
	}
	end := 0
	for end < len(rest) && rest[end] != ' ' && rest[end] != '\t' {
		end += 1
	}
	if end == 0 {
		return ""
	}
	return rest[:end]
}
