module llmcli::context;

import std::collections::list;
import llmcli::chat, llmcli::trajectory;

// ---- 分节 ----
// 本模块把 Trajectory 渲染为 Message[]（送端点的投影）。无业务副作用（读 blob 除外）。
// 「消息是投影，不是状态」：改渲染策略不改数据，每轮从 trajectory 重渲染。
//
// 对应 shellm 的 bin/context：head/tail/pin 窗口、角色映射、最新波段更大截断、中间截断
// （保留首尾、打截断桩）、max_bytes 预算二分、run 作用域。

// ---- 常量 ----

const usz DEFAULT_PROMPT_LIMIT = 2048;
const usz DEFAULT_BLOCK_LIMIT = 8192;
const usz TRUNCATE_FLOOR = 64;   // 预算收紧时的下限，避免无限二分

// 默认角色/预算分类。用模块级常量：default_policy 返回结构体，字段若是函数内临时数组
// 会随函数返回而悬垂（切片头被复制，底层内存已失效）。
const String[] DEFAULT_ASSISTANT_TYPES = { trajectory::T_REASONING, trajectory::T_FINAL };
const String[] DEFAULT_USER_TYPES = { trajectory::T_PROMPT, trajectory::T_SHELL_OUTPUT,
                                       trajectory::T_FEEDBACK };
const String[] DEFAULT_EXCLUDE_TYPES = { trajectory::T_SHELLM_RUN, trajectory::T_RUN_SUMMARY };
const String[] DEFAULT_FULL_TYPES = { trajectory::T_PROMPT };

// ---- 类型 ----

// 渲染策略。字段都有默认值（见 default_policy）。
struct RenderPolicy
{
	String[] assistant_types; // 映射为 assistant 的步骤类型
	String[] user_types;      // 映射为 user 的步骤类型
	String[] exclude_types;   // 永不进上下文（记账步骤）
	String[] full_types;      // 永不截断的类型
	int head;                 // 保留首 N 步
	int tail;                 // 保留末 N 步
	int tail_block;           // 尾窗起点按 N 步对齐（缓存友好；1 = 不对齐）
	usz prompt_limit;         // 普通步骤字段上限（字节）
	usz block_limit;          // 最新波段字段上限
	int whole_blocks;         // 最新几个波段用 block_limit
	String[] pins;            // 强制包含的 step_id
	String run;               // 非空：只保留该 run 的步骤
	usz max_bytes;            // 总预算；0 = 不限
}

// 默认策略，与 doc 4.2 一致。
fn RenderPolicy default_policy()
{
	RenderPolicy policy;
	policy.assistant_types = DEFAULT_ASSISTANT_TYPES;
	policy.user_types = DEFAULT_USER_TYPES;
	policy.exclude_types = DEFAULT_EXCLUDE_TYPES;
	policy.full_types = DEFAULT_FULL_TYPES;
	policy.head = 1;
	policy.tail = 50;
	policy.tail_block = 1;
	policy.prompt_limit = DEFAULT_PROMPT_LIMIT;
	policy.block_limit = DEFAULT_BLOCK_LIMIT;
	policy.whole_blocks = 1;
	policy.max_bytes = 0;
	return policy;
}

// ---- 渲染 ----

// 从 trajectory 渲染 messages。每轮调用都会重新读 trajectory 并重建投影。
fn chat::Message[] render(Allocator allocator, trajectory::Trajectory* traj, RenderPolicy* policy)
{
	trajectory::Step[] all = trajectory::read_all(tmem, traj);

	// 1) 过滤（exclude / run 作用域）
	List{trajectory::Step} kept;
	kept.init(tmem);
	foreach (s : all)
	{
		if (contains(policy.exclude_types, s.type)) continue;
		if (policy.run.len && s.run_id != policy.run) continue;
		kept.push(s);
	}

	// 2) 窗口：head + tail + pins
	List{trajectory::Step} window;
	window.init(tmem);
	select_window(&window, &kept, policy);

	// 3) 波段索引：prompt 起新波段；最新 whole_blocks 个波段标记为「新」。
	// 4) 渲染 + 分层截断。
	usz prompt_limit = policy.prompt_limit;
	usz block_limit = policy.block_limit;
	chat::Message[] messages;
	while (true)
	{
		messages = render_window(allocator, &window, policy, prompt_limit, block_limit);
		if (policy.max_bytes == 0 || total_bytes(messages) <= policy.max_bytes) break;
		// 超预算：二分收紧（这里简化为折半），到下限就停。
		if (prompt_limit <= TRUNCATE_FLOOR && block_limit <= TRUNCATE_FLOOR) break;
		prompt_limit = max(prompt_limit / 2, TRUNCATE_FLOOR);
		block_limit = max(block_limit / 2, TRUNCATE_FLOOR);
	}
	return messages;
}

fn void select_window(List{trajectory::Step}* out, List{trajectory::Step}* kept, RenderPolicy* policy) @private
{
	usz len = (usz)kept.len();
	int head = policy.head;
	int tail = policy.tail;

	// 尾窗起点：tail>0 时保留末 tail 步；整表不超 tail 则全保留；tail<=0 只保留 head。
	usz tail_start = len;
	if (tail > 0)
	{
		if (len <= (usz)tail)
		{
			tail_start = 0;
		}
		else
		{
			usz raw = len - (usz)tail;
			if (policy.tail_block > 1)
			{
				usz block = (usz)policy.tail_block;
				raw = (raw / block) * block;
			}
			tail_start = raw;
		}
	}

	for (usz i = 0; i < len; i++)
	{
		bool in_head = head > 0 && i < (usz)head;
		bool in_tail = i >= tail_start;
		bool pinned = is_pinned(policy.pins, kept.get((sz)i).step_id);
		if (in_head || in_tail || pinned) out.push(kept.get((sz)i));
	}
}

fn chat::Message[] render_window(Allocator allocator, List{trajectory::Step}* window,
                                 RenderPolicy* policy, usz prompt_limit, usz block_limit) @private
{
	// 波段：prompt 起新波段；记录每步的波段序号。
	int block_count = 0;
	List{int} block_of;
	block_of.init(tmem);
	foreach (s : *window)
	{
		if (s.type == trajectory::T_PROMPT && block_of.len() > 0) block_count++;
		block_of.push(block_count);
	}
	int newest_blocks = policy.whole_blocks < 0 ? 0 : policy.whole_blocks;
	int first_new = block_count + 1 - newest_blocks;

	List{chat::Message} messages;
	messages.init(allocator);
	for (usz i = 0; i < (usz)window.len(); i++)
	{
		trajectory::Step* s = window.get_ref((sz)i);
		String role = role_for(policy, s.type);
		if (!role.len) continue;

		bool full = contains(policy.full_types, s.type);
		usz limit = block_of.get((sz)i) >= first_new ? block_limit : prompt_limit;

		String content = render_content(allocator, s, full ? 0 : limit);
		messages.push({ .role = role, .content = content });
	}
	return messages.to_array(allocator);
}

// 步骤 -> assistant/user 角色；未映射的类型（应已被 exclude 拦下）返回空。
fn String role_for(RenderPolicy* policy, String type) @private
{
	if (contains(policy.assistant_types, type)) return "assistant";
	if (contains(policy.user_types, type)) return "user";
	return "";
}

// 按类型重建一条消息的正文。limit=0 表示不截断。
fn String render_content(Allocator allocator, trajectory::Step* s, usz limit) @private
{
	String type = s.type;
	if (type == trajectory::T_PROMPT || type == trajectory::T_FINAL
	    || type == trajectory::T_FEEDBACK)
	{
		return trunc(allocator, s.content, limit);
	}
	if (type == trajectory::T_REASONING)
	{
		// 还原模型回复的形态：散文 + bash 代码块（cmd 是代码原文）。
		DString out = dstring::new(tmem);
		if (s.thought.len) out.append(s.thought);
		if (s.cmd.len)
		{
			out.append("\n```bash\n");
			out.append(s.cmd);
			if (!s.cmd.ends_with("\n")) out.append("\n");
			out.append("```");
		}
		return trunc(allocator, out.str_view(), limit);
	}
	if (type == trajectory::T_SHELL_OUTPUT)
	{
		DString out = dstring::new(tmem);
		if (s.feedback.len)
		{
			out.append(s.feedback);
			if (!s.feedback.ends_with("\n")) out.append("\n");
		}
		out.append(s.stdout);
		return trunc(allocator, out.str_view(), limit);
	}
	return "";
}

// ---- 截断 ----

// 中间截断：保留首尾，中间打桩 `[... truncated: N bytes total ...]`。
// limit==0 表示不截断。截断点回退到 UTF-8 边界。
fn String trunc(Allocator allocator, String text, usz limit) @private
{
	if (limit == 0 || text.len <= limit) return text.copy(allocator);
	usz keep = limit / 2;
	usz head = utf8_back(text, keep);
	usz tail = utf8_back(text, keep);
	String stub = string::tformat("\n[... truncated: %d bytes total ...]\n", text.len);
	return string::format(allocator, "%s%s%s", text[:head], stub, text[text.len - tail..]);
}

// 从 end 向前回退到 UTF-8 字符边界。
fn usz utf8_back(String text, usz end) @private
{
	if (end > text.len) end = text.len;
	while (end > 0 && (text[end] & 0xC0) == 0x80) end--;
	return end;
}

// ---- 小工具 ----

fn bool contains(String[] list, String value) @private
{
	foreach (item : list)
	{
		if (item == value) return true;
	}
	return false;
}

fn bool is_pinned(String[] pins, String step_id) @private
{
	if (!pins.len) return false;
	return contains(pins, step_id);
}

fn usz total_bytes(chat::Message[] messages) @private
{
	usz total = 0;
	foreach (m : messages) total += m.content.len;
	return total;
}

fn usz max(usz a, usz b) @private => a > b ? a : b;
