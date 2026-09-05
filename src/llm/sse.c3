// sse — llm 模块的流式接收层：SSE 分帧、逐 chunk 解析、先回调后聚合。
//
// 每尝试（attempt）一个 StreamRecv，curl 写回调把原始字节累积到 pending 后逐行
// pump；整包字节不在此处理（见 chat.c3 的 BodyRecv）。chunk 回调收到的结构体
// 只存活到回调返回（解析层 tmem 临时分配）；需要跨回调保存的调用方自行拷贝。
// reasoning 是否打印、debug 通道选择由调用方回调决定，本层不感知。
module llm;

import std::core::string;
import std::collections::list;

// 流式 chunk 回调：每次成功解析出一个 data 帧即调用一次（先回调、再聚合）。
// ud 为调用方透传。可空（null = 只聚合不通知）。
alias ChunkCb = fn void(ChatStreamChunk* chunk, void* ud);

// 单个 tool_call 的聚合槽（按 delta.index 对位；name/arguments 为流式增量累积，
// id 只在首帧出现故整段替换）。持久化到调用方 allocator。
struct ToolAcc
{
	String id;
	DString name; // function.name 累积（OpenAI 实际首帧全量，按增量处理以兼容分片）
	DString args; // function.arguments 增量片段累积
}

// 单次流式尝试的接收状态（替换原 CLI 模块级全局 StreamState；userdata 随
// WRITEDATA 传入，一次尝试一个实例，天然支持将来并发/重入）。
struct StreamRecv
{
	// 分帧状态（scratch）
	bool saw_data;    // 是否已见过 data: 事件（首个 data 之前的非 data 行进 err_buf）
	bool emitted;     // 是否已输出过 delta.content 或任一 tool_call 增量（重试判定与成功判定依据）
	DString pending;  // 未分帧的原始字节缓冲
	DString err_buf;  // 首个 data 事件前的非 data 行（HTTP/API 错误体）
	// 聚合输出（string 持久化到调用方 allocator）
	Allocator allocator;
	Usage usage;       // 跨帧合并；缺省字段保持 -1
	bool has_usage;    // 任一帧带 usage
	String finish_reason; // 最后一个非空 finish_reason（arena 拷贝）
	DString acc_content;  // choices[0].content 累积
	DString acc_reasoning; // 顶层 reasoning 累积
	List{ToolAcc} acc_tools; // delta.tool_calls 按 index 对位聚合
	// 回调
	ChunkCb cb;
	void* cb_ud;
}

// 每尝试重置一次：分帧缓冲与聚合全部从零开始（重试只在未输出内容时发生，失败
// 尝试的聚合结果直接丢弃，无需保留）。
fn void stream_reset(StreamRecv* st)
{
	st.saw_data = false;
	st.emitted = false;
	st.pending = dstring::new(tmem);
	st.err_buf = dstring::new(tmem);
	st.usage.prompt_tokens = -1;
	st.usage.completion_tokens = -1;
	st.usage.reasoning_tokens = -1;
	st.has_usage = false;
	st.finish_reason = "";
	st.acc_content = dstring::new(st.allocator);
	st.acc_reasoning = dstring::new(st.allocator);
	st.acc_tools.init(st.allocator);
}

fn usz sse_write_cb(char* buffer, usz size, usz nitems, void* userdata)
{
	StreamRecv* st = (StreamRecv*)userdata;
	usz len = size * nitems;
	for (usz i = 0; i < len; i++) { st.pending.append_char(buffer[i]); }
	pump_stream(st);
	return len;
}

// 把 pending 里已完整的事件行（\n 结尾）逐行交给 handle；剩余半行保留等待后续字节。
fn void pump_stream(StreamRecv* st)
{
	String view = st.pending.str_view();
	usz consumed = 0;
	for (usz i = 0; i < view.len; i++)
	{
		if (view[i] == '\n')
		{
			// CRLF：行尾 \r 一并剥掉（SSE 事件行按 \n 分割）
			sse_handle_line(st, view[consumed : i - consumed].trim_right("\r"));
			consumed = i + 1;
		}
	}
	if (consumed > 0)
	{
		// rest 是 pending 自身缓冲的视图：clear+append 会自我覆盖/悬垂，
		// 必须先拷进新 DString 再整体替换。
		DString np = dstring::new(tmem);
		np.append(view[consumed : view.len - consumed]);
		st.pending = np;
	}
}

fn void sse_handle_line(StreamRecv* st, String line)
{
	if (!line.starts_with("data: "))
	{
		if (!st.saw_data && line.len > 0)
		{
			st.err_buf.append(line);
			st.err_buf.append_char('\n');
		}
		return;
	}
	st.saw_data = true;
	String json = line[6 : line.len - 6];
	if (json == "[DONE]") { return; }

	ChatStreamChunk? chunk_r = parse_stream_chunk(tmem, json);
	if (catch chunk_r) { return; }
	ChatStreamChunk chunk = chunk_r;

	// 先回调、再聚合（D1/D5 语义）
	if (st.cb != null) { st.cb(&chunk, st.cb_ud); }
	if (chunk.delta_content.len > 0)
	{
		st.emitted = true;
		st.acc_content.append(chunk.delta_content);
	}
	if (chunk.delta_reasoning.len > 0)
	{
		st.acc_reasoning.append(chunk.delta_reasoning);
	}
	// tool_call 增量：按 index 对位聚合（缺口补空槽）；任一增量视为已输出，
	// 使纯 tool_calls 流（无 content）不被误判为空流。
	foreach (&d : &chunk.tool_calls)
	{
		// index 缺省（负值）时并入最后一个槽：部分 provider 不发 index，
		// 单调用场景下碎片应续接而非新开槽位。
		sz idx;
		if (d.index >= 0) { idx = (sz)d.index; }
		else if (st.acc_tools.len() > 0) { idx = st.acc_tools.len() - 1; }
		else { idx = 0; }
		while (st.acc_tools.len() <= idx)
		{
			ToolAcc slot;
			slot.id = "";
			slot.name = dstring::new(st.allocator);
			slot.args = dstring::new(st.allocator);
			st.acc_tools.push(slot);
		}
		ToolAcc* t = st.acc_tools.get_ref(idx);
		if (d.id.len > 0) { t.id = d.id.copy(st.allocator); }
		if (d.name.len > 0) { t.name.append(d.name); }
		if (d.arguments.len > 0) { t.args.append(d.arguments); }
		st.emitted = true;
	}
	if (chunk.finish_reason.len > 0)
	{
		st.finish_reason = chunk.finish_reason.copy(st.allocator);
	}
	if (chunk.has_usage)
	{
		st.has_usage = true;
		// 缺省 -1：保持旧值（usage 可能跨帧下发，每帧只带部分计数）
		if (chunk.usage.prompt_tokens >= 0) { st.usage.prompt_tokens = chunk.usage.prompt_tokens; }
		if (chunk.usage.completion_tokens >= 0) { st.usage.completion_tokens = chunk.usage.completion_tokens; }
		if (chunk.usage.reasoning_tokens >= 0) { st.usage.reasoning_tokens = chunk.usage.reasoning_tokens; }
	}
}

// 尝试结束时把聚合结果折叠成 ChatResponse（choices[0] 单元素）。
// content/reasoning 视图指向各自累积缓冲（arena 分配，调用方 allocator 存续期内有效）。
fn ChatResponse stream_result(StreamRecv* st)
{
	ChatResponse resp;
	resp.choices.init(st.allocator);
	ChatChoice c;
	c.content = st.acc_content.str_view();
	c.has_content = st.emitted;
	c.finish_reason = st.finish_reason;
	c.error_message = "";
	c.tool_calls.init(st.allocator);
	foreach (&t : &st.acc_tools)
	{
		ChatToolCall tc;
		tc.id = t.id;
		tc.name = t.name.str_view();
		tc.arguments = t.args.str_view();
		c.tool_calls.push(tc);
	}
	resp.choices.push(c);
	resp.usage = st.usage;
	resp.has_usage = st.has_usage;
	resp.error_message = "";
	resp.reasoning = st.acc_reasoning.str_view();
	return resp;
}
