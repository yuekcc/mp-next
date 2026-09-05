// chat — api 模块唯一入口（恒流式）：payload 序列化（extra body 合并）、重试、错误折叠。
// stdout 零输出、chunk 打印走 ChunkCb、失败经 LlmError；语义详见 docs/llm.md。
module api;

import std::io;
import std::thread;
import std::core::string;
import std::collections::list;
import cjson;

faultdef TRANSPORT_FAILED, HTTP_STATUS, EMPTY_STREAM;

// 失败详情（fault 只承载类别，细节在此带出）：http_code 为本次 HTTP 状态
// （0 = 无 HTTP 层，如请求序列化失败）；message 为可展示文案（分配在调用方 allocator）。
struct LlmError
{
	int http_code;
	String message;
}

// 失败类别（模块内部分类用，返回时映射到 faultdef）
enum AttemptCat
{
	TRANSPORT,
	HTTP_STATUS,
	EMPTY_STREAM,
}

const String EMPTY_RESPONSE_TEXT = "empty response: stream ended without emitting anything";

// 序列化请求体（恒 stream）；extra body 同名键覆盖；非法时填 err.message 返回 false。
fn bool make_payload(Allocator allocator, LlmOption* ctx, ChatRequest* req, String* out, LlmError* err)
{
	req.stream = true;
	req.stream_include_usage = true;

	CJsonItem* body = request_to_cjson(allocator, req);
	if (ctx.extra_body.len > 0)
	{
		CJsonItem* x = cjson::parse(ctx.extra_body.zstr_tcopy());
		if (!x || !cjson::is_object(x))
		{
			if (x)
			{
				cjson::delete(x);
			}
			err.http_code = 0;
			err.message = string::format(allocator, "%s", "LLM_EXTRA_BODY must be a JSON object");
			return false;
		}
		for (CJsonItem* m = x.child; m != null;)
		{
			CJsonItem* next = m.next;
			CJsonItem* detached = cjson::detach_item_via_pointer(x, m);
			// 键必须先从节点拷成独立缓冲（zstr_tcopy）：add/replace 会接管并释放
			// 被挂载节点自身的 m.string（改写节点键缓冲），直接传 (ZString)m.string
			// 是 use-after-free（旧实现同样潜伏，靠内存未被覆写碰巧可用）。
			// 同名键覆盖（用户故事 9 / docs/llm.md）：cJSON Add 只追加、遇同名键会
			// 生成重复键且 get_key 取到旧值，命中已有键必须先 ReplaceItemInObject。
			String name = ((ZString)m.string).str_view();
			if (body.has_key(name))
			{
				(void)cjson::replace_item_in_object(body, name.zstr_tcopy(), detached);
			}
			else
			{
				(void)cjson::add_item_to_object(body, name.zstr_tcopy(), detached);
			}
			m = next;
		}
		cjson::delete(x);
	}
	*out = json_to_string(allocator, body);
	cjson::delete(body);
	return true;
}

// 尝试总次数：retries 次重试 + 初次尝试（常量；负数兜底为 0）。
fn int attempt_budget()
{
	int retries = DEFAULT_RETRIES;
	if (retries < 0)
	{
		retries = 0;
	}
	return retries + 1;
}

// 记录失败并返回对应 fault：msg 统一拷贝进调用方 allocator（本调用内的唯一拷贝点）。
fn ChatResponse? fail_attempt(Allocator allocator, LlmError* err, int http_code, String msg, AttemptCat cat)
{
	err.http_code = http_code;
	err.message = msg.copy(allocator);
	switch (cat)
	{
		case AttemptCat.TRANSPORT: return TRANSPORT_FAILED~;
		case AttemptCat.HTTP_STATUS: return HTTP_STATUS~;
		default: return EMPTY_STREAM~;
	}
}

// 可重试时：指数退避。attempt >= max_attempts 返回 false（不再等待）。
fn bool retry_wait(int attempt, int max_attempts)
{
	if (attempt >= max_attempts) return false;
	thread::sleep_ms((long)DEFAULT_BACKOFF * attempt * 1000);
	return true;
}

// 从任意响应正文折叠 API error 文案（顶层 error/message + choice 级 + finish
// reason error 全覆盖，见 response_error_message）。无错误返回 ""。
fn String fold_body_error(String body)
{
	if (body.trim().len == 0) return "";
	if (try er = parse_response(tmem, body))
	{
		String em = er.error_message;
		if (em.len == 0)
		{
			em = response_error_message(&er);
		}
		if (em.len > 0) return string::tformat("API error: %s", em);
	}
	return "";
}

// 流式尝试的错误体折叠：只取首个 data: 事件之前缓冲的行（其后为正文，不再收集）。
fn String stream_fold_error(StreamRecv* st)
{
	if (st.saw_data || st.err_buf.len() == 0) return "";
	return fold_body_error(st.err_buf.str_view());
}

// ============================== 流式入口 ==============================
fn ChatResponse? stream(Allocator allocator, LlmOption* ctx, ChatRequest* req, LlmError* err, ChunkCb cb, void* cb_ud)
{
	String payload = "";
	if (!make_payload(allocator, ctx, req, &payload, err))
	{
		return MALFORMED_JSON~;
	}
	if (ctx.debug)
	{
		io::eprintfn("---\n%s\n---", payload);
	}

	int max_attempts = attempt_budget();
	int attempt = 1;
	while (true)
	{
		StreamRecv st;
		st.allocator = allocator;
		st.cb = cb;
		st.cb_ud = cb_ud;
		stream_reset(&st);

		int http_code = 0;
		String terr = http_attempt(ctx, payload, &http_code, &sse_write_cb, &st);

		// 流结束：处理最后一段没有换行符的内容（read-until-EOF 语义）
		String tail = st.pending.str_view();
		if (tail.len > 0)
		{
			sse_handle_line(&st, tail.trim_right("\r"));
			st.pending.clear();
		}

		// 传输成功且已输出内容 = 成功（与旧 CLI 判定一致；usage 可能缺席，
		// 由调用方按 -1 处理）
		if (terr.len == 0 && st.emitted)
		{
			return stream_result(&st);
		}

		AttemptCat cat;
		String msg = "";
		bool retryable = false;
		if (terr.len > 0)
		{
			cat = AttemptCat.TRANSPORT;
			msg = terr;
			retryable = !st.emitted;
		}
		else if (http_code >= 500 || http_code == 429)
		{
			cat = AttemptCat.HTTP_STATUS;
			msg = stream_fold_error(&st);
			if (msg.len == 0)
			{
				msg = string::tformat("HTTP %d", http_code);
			}
			retryable = !st.emitted;
		}
		else if (http_code >= 400)
		{
			cat = AttemptCat.HTTP_STATUS;
			msg = stream_fold_error(&st);
			if (msg.len == 0)
			{
				msg = string::tformat("HTTP %d", http_code);
			}
			retryable = false;
		}
		else
		{
			// 2xx/3xx 但没有任何输出：优先折叠错误体（200+error），否则空流
			cat = AttemptCat.EMPTY_STREAM;
			msg = stream_fold_error(&st);
			if (msg.len == 0)
			{
				msg = EMPTY_RESPONSE_TEXT;
			}
			retryable = false;
		}

		if (retryable && retry_wait(attempt, max_attempts))
		{
			attempt++;
			continue;
		}
		return fail_attempt(allocator, err, http_code, msg, cat);
	}
}
