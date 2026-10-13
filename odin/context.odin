package main

import "core:fmt"
import "core:strings"

// ---- 分节 ----
// 把 Trajectory 渲染为 Message[]（送端点的投影）。无业务副作用（读 blob 除外）。
// 「消息是投影，不是状态」：改渲染策略不改数据，每轮从 trajectory 重渲染。
//
// 对应 shellm 的 bin/context：head/tail/pin 窗口、角色映射、最新波段更大截断、中间截断
// （保留首尾、打截断桩）、max_bytes 预算二分、run 作用域。

// ---- 常量 ----

DEFAULT_PROMPT_LIMIT :: 2048
DEFAULT_BLOCK_LIMIT :: 8192
TRUNCATE_FLOOR :: 64 // 预算收紧时的下限，避免无限二分

// 默认角色/预算分类。用模块级变量：default_policy 返回结构体，字段若是函数内临时数组
// 会随函数返回而悬垂。这些数组需要可寻址才能切片，故为变量而非常量。
default_assistant_types := [?]string{T_REASONING, T_FINAL}
default_user_types := [?]string{T_PROMPT, T_SHELL_OUTPUT, T_FEEDBACK}
default_exclude_types := [?]string{T_SHELLM_RUN, T_RUN_SUMMARY}
default_full_types := [?]string{T_PROMPT}

// ---- 类型 ----

// 渲染策略。字段都有默认值（见 default_policy）。
RenderPolicy :: struct {
	assistant_types: []string, // 映射为 assistant 的步骤类型
	user_types:      []string, // 映射为 user 的步骤类型
	exclude_types:   []string, // 永不进上下文（记账步骤）
	full_types:      []string, // 永不截断的类型
	head:            int, // 保留首 N 步
	tail:            int, // 保留末 N 步
	tail_block:      int, // 尾窗起点按 N 步对齐（缓存友好；1 = 不对齐）
	prompt_limit:    int, // 普通步骤字段上限（字节）
	block_limit:     int, // 最新波段字段上限
	whole_blocks:    int, // 最新几个波段用 block_limit
	pins:            []string, // 强制包含的 step_id
	run:             string, // 非空：只保留该 run 的步骤
	max_bytes:       int, // 总预算；0 = 不限
}

// 默认策略，与 arch.md 4.3 一致。
default_policy :: proc() -> RenderPolicy {
	policy: RenderPolicy
	policy.assistant_types = default_assistant_types[:]
	policy.user_types = default_user_types[:]
	policy.exclude_types = default_exclude_types[:]
	policy.full_types = default_full_types[:]
	policy.head = 1
	policy.tail = 50
	policy.tail_block = 1
	policy.prompt_limit = DEFAULT_PROMPT_LIMIT
	policy.block_limit = DEFAULT_BLOCK_LIMIT
	policy.whole_blocks = 1
	policy.max_bytes = 0
	return policy
}

// ---- 渲染 ----

// 从 trajectory 渲染 messages。每轮调用都会重新读 trajectory 并重建投影。
// 结果在 context.temp_allocator 上。
context_render :: proc(traj: ^Trajectory, policy: ^RenderPolicy) -> [dynamic]Message {
	all := traj_read_all(traj)

	// 1) 过滤（exclude / run 作用域）
	kept := make([dynamic]Step, 0, len(all), context.temp_allocator)
	for s in all {
		if str_in(policy.exclude_types, s.type) {
			continue
		}
		if policy.run != "" && s.run_id != policy.run {
			continue
		}
		append(&kept, s)
	}

	// 2) 窗口：head + tail + pins
	window := select_window(kept, policy)

	// 3) 渲染 + 分层截断；超 max_bytes 时折半收紧 limit，到下限即停。
	prompt_limit := policy.prompt_limit
	block_limit := policy.block_limit
	messages: [dynamic]Message
	for {
		messages = render_window(window, policy, prompt_limit, block_limit)
		if policy.max_bytes == 0 || total_bytes(messages) <= policy.max_bytes {
			break
		}
		if prompt_limit <= TRUNCATE_FLOOR && block_limit <= TRUNCATE_FLOOR {
			break
		}
		prompt_limit = max_int(prompt_limit / 2, TRUNCATE_FLOOR)
		block_limit = max_int(block_limit / 2, TRUNCATE_FLOOR)
	}
	return messages
}

select_window :: proc(kept: [dynamic]Step, policy: ^RenderPolicy) -> [dynamic]Step {
	out := make([dynamic]Step, 0, len(kept), context.temp_allocator)
	n := len(kept)

	// 尾窗起点：tail>0 时保留末 tail 步；整表不超 tail 则全保留；tail<=0 只保留 head。
	tail_start := n
	if policy.tail > 0 {
		if n <= policy.tail {
			tail_start = 0
		} else {
			raw := n - policy.tail
			if policy.tail_block > 1 {
				raw = (raw / policy.tail_block) * policy.tail_block
			}
			tail_start = raw
		}
	}

	for i in 0 ..< n {
		in_head := policy.head > 0 && i < policy.head
		in_tail := i >= tail_start
		pinned := is_pinned(policy.pins, kept[i].step_id)
		if in_head || in_tail || pinned {
			append(&out, kept[i])
		}
	}
	return out
}

render_window :: proc(window: [dynamic]Step, policy: ^RenderPolicy,
                     prompt_limit, block_limit: int) -> [dynamic]Message {
	// 波段：prompt 起新波段；记录每步的波段序号。
	block_of := make([dynamic]int, 0, len(window), context.temp_allocator)
	block_count := 0
	for s in window {
		if s.type == T_PROMPT && len(block_of) > 0 {
			block_count += 1
		}
		append(&block_of, block_count)
	}
	newest := policy.whole_blocks < 0 ? 0 : policy.whole_blocks
	first_new := block_count + 1 - newest

	messages := make([dynamic]Message, 0, len(window), context.temp_allocator)
	for s, i in window {
		role := role_for(policy, s.type)
		if role == "" {
			continue
		}
		full := str_in(policy.full_types, s.type)
		limit := block_of[i] >= first_new ? block_limit : prompt_limit
		content := render_content(s, full ? 0 : limit)
		append(&messages, Message{role = role, content = content})
	}
	return messages
}

// 步骤 -> assistant/user 角色；未映射的类型（应已被 exclude 拦下）返回空。
role_for :: proc(policy: ^RenderPolicy, type: string) -> string {
	if str_in(policy.assistant_types, type) {
		return "assistant"
	}
	if str_in(policy.user_types, type) {
		return "user"
	}
	return ""
}

// 按类型重建一条消息的正文。limit=0 表示不截断。
render_content :: proc(s: Step, limit: int) -> string {
	type := s.type
	if type == T_PROMPT || type == T_FINAL || type == T_FEEDBACK {
		return trunc_middle(s.content, limit)
	}
	if type == T_REASONING {
		// 还原模型回复的形态：散文 + bash 代码块（cmd 是代码原文）。
		sb := strings.builder_make(context.temp_allocator)
		if s.thought != "" {
			strings.write_string(&sb, s.thought)
		}
		if s.cmd != "" {
			strings.write_string(&sb, "\n```bash\n")
			strings.write_string(&sb, s.cmd)
			if !strings.has_suffix(s.cmd, "\n") {
				strings.write_byte(&sb, '\n')
			}
			strings.write_string(&sb, "```")
		}
		return trunc_middle(strings.to_string(sb), limit)
	}
	if type == T_SHELL_OUTPUT {
		sb := strings.builder_make(context.temp_allocator)
		if s.feedback != "" {
			strings.write_string(&sb, s.feedback)
			if !strings.has_suffix(s.feedback, "\n") {
				strings.write_byte(&sb, '\n')
			}
		}
		strings.write_string(&sb, s.stdout)
		return trunc_middle(strings.to_string(sb), limit)
	}
	return ""
}

// ---- 截断 ----

// 中间截断：保留首尾，中间打桩 `[... truncated: N bytes total ...]`。
// limit==0 表示不截断。截断点回退到 UTF-8 边界。结果在 context.temp_allocator 上。
trunc_middle :: proc(text: string, limit: int) -> string {
	if limit == 0 || len(text) <= limit {
		return text
	}
	keep := limit / 2
	head := utf8_back(text, keep)
	tail := utf8_back(text, keep)
	stub := fmt.aprintf("\n[... truncated: %d bytes total ...]\n", len(text),
	                    allocator = context.temp_allocator)
	return fmt.aprintf("%s%s%s", text[:head], stub, text[len(text) - tail:],
	                   allocator = context.temp_allocator)
}

// 从 end 向前回退到 UTF-8 字符边界。
utf8_back :: proc(text: string, end_in: int) -> int {
	end := min(end_in, len(text))
	for end > 0 && end < len(text) && (text[end] & 0xC0) == 0x80 {
		end -= 1
	}
	return end
}

// ---- 小工具 ----

str_in :: proc(list: []string, value: string) -> bool {
	for item in list {
		if item == value {
			return true
		}
	}
	return false
}

is_pinned :: proc(pins: []string, step_id: string) -> bool {
	if len(pins) == 0 {
		return false
	}
	return str_in(pins, step_id)
}

total_bytes :: proc(messages: [dynamic]Message) -> int {
	total := 0
	for m in messages {
		total += len(m.content)
	}
	return total
}

max_int :: proc(a, b: int) -> int {
	return a > b ? a : b
}
