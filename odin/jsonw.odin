package main

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// ---- 分节 ----
// 自写的 JSON 序列化，只用于「我们构造的输出」（请求体、轨迹步骤）。
//
// 与 core:encoding/json 的关键差异：**不转义非 ASCII**——中文原样输出 UTF-8，只转义
// JSON 必需的字符（`"`、`\`、控制字符）。core 的 is_printable 只认 Latin-1，会把 CJK
// 写成 `\uXXXX`；C3 版用 cjson 也是原样 UTF-8，故这里对齐可观测面（更小、更可读）。
//
// 解析仍走 core:encoding/json（`\uXXXX` 与 UTF-8 都能读）。键按字典序输出以求稳定。

json_encode :: proc(v: json.Value) -> string {
	sb := strings.builder_make(context.temp_allocator)
	json_encode_value(&sb, v)
	return strings.to_string(sb)
}

json_encode_value :: proc(sb: ^strings.Builder, v: json.Value) {
	switch val in v {
	case json.Null:
		strings.write_string(sb, "null")
	case json.Boolean:
		strings.write_string(sb, val ? "true" : "false")
	case json.Integer:
		fmt.sbprintf(sb, "%d", i64(val))
	case json.Float:
		fmt.sbprintf(sb, "%v", f64(val))
	case json.String:
		json_encode_string(sb, string(val))
	case json.Array:
		strings.write_byte(sb, '[')
		for elem, i in val {
			if i > 0 {
				strings.write_byte(sb, ',')
			}
			json_encode_value(sb, elem)
		}
		strings.write_byte(sb, ']')
	case json.Object:
		keys := make([dynamic]string, 0, len(val), context.temp_allocator)
		for key, _ in val {
			append(&keys, key)
		}
		slice.sort(keys[:])
		strings.write_byte(sb, '{')
		for key, i in keys {
			if i > 0 {
				strings.write_byte(sb, ',')
			}
			json_encode_string(sb, key)
			strings.write_byte(sb, ':')
			json_encode_value(sb, val[key])
		}
		strings.write_byte(sb, '}')
	}
}

// JSON 字符串：只转义 `"`、`\` 与控制字符；其余字节（含 UTF-8 多字节）原样写出。
json_encode_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		b := s[i]
		switch b {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\b':
			strings.write_string(sb, "\\b")
		case '\f':
			strings.write_string(sb, "\\f")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case:
			if b < 0x20 {
				fmt.sbprintf(sb, "\\u%04x", b)
			} else {
				strings.write_byte(sb, b)
			}
		}
	}
	strings.write_byte(sb, '"')
}
