// chat — llm 模块的调用入口：双入口（complete 非流式 / stream 流式）、payload
// 序列化（extra body 合并）、重试退避、错误折叠。模块内无任何进程级 exit；
// 失败以 fault 分类 + LlmError（HTTP code / 文案）表达，由调用方决定处理。
//
// 输出通道约定：模块对 stdout 零输出；唯一直接写 stderr 的是 ctx.debug 为真时
// 的请求体 dump（`---\n<json>\n---`，诊断用途，同 curl VERBOSE 惯例）。逐 chunk
// 内容/推理打印经回调交给调用方（ChunkCb）。
//
// 重试语义（D8，相对旧 CLI 的行为修正）：
//   仅「传输层错误 / HTTP 429 / 5xx」且未输出任何 chunk 才重试（指数退避）；
//   HTTP 4xx 立即失败；已输出部分内容永不重试（避免重复尾巴）。
//
// 错误文案优先级与旧 CLI 一致：curl 错误 → 响应体 API error.message（complete
//  还折叠 choice 级 error / finish_reason=="error"）→ 空流文案 → HTTP <code>。
// 所有需要跨出本调用的字符串（聚合响应、err.message）都分配在调用方传入的
// allocator 内；临时解析缓冲一律走 tmem。
module llm;

import std::io;
import std::thread;
import std::core::string;
import std::collections::list;
import cjson;

faultdef TRANSPORT_FAILED, HTTP_STATUS, EMPTY_STREAM;

// 失败详情（fault 只承载类别，细节在此带出）：http_code 为本次 HTTP 状态
//（0 = 无 HTTP 层，如请求序列化失败）；message 为可展示文案（分配在调用方 allocator）。
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
	MALFORMED_JSON,
}

// 非流式尝试的接收缓冲（整包字节；解析在尝试结束后进行）
struct BodyRecv
{
	DString buf;
}

const String EMPTY_RESPONSE_TEXT = "empty response: stream ended without emitting anything";

fn usz body_write_cb(char* buffer, usz size, usz nitems, void* userdata)
{
	BodyRecv* recv = (BodyRecv*)userdata;
	usz len = size * nitems;
	for (usz i = 0; i < len; i++) { recv.buf.append_char(buffer[i]); }
	return len;
}

// 序列化请求体：固定 stream 语义（入口决定）、合并 LLM_EXTRA_BODY（同名键覆盖）。
// 返回 false 时 err.message 已填（extra body 非法）。payload 分配在 allocator。
fn bool make_payload(Allocator allocator, LlmOption* ctx, ChatRequest* req, bool streaming, String* out, LlmError* err)
{
	req.stream = streaming;
	req.stream_include_usage = streaming;

	CJsonItem* body = request_to_cjson(allocator, req);
	if (ctx.extra_body.len > 0)
	{
		CJsonItem* x = cjson::parse(ctx.extra_body.zstr_tcopy());
		if (!x || !cjson::is_object(x))
		{
			if (x) { cjson::delete(x); }
			err.http_code = 0;
			err.message = string::format(allocator, "%s", "LLM_EXTRA_BODY must be a JSON object");
			return false;
		}
		for (CJsonItem* m = x.child; m != null; )
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
	if (retries < 0) { retries = 0; }
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
		case AttemptCat.MALFORMED_JSON: return MALFORMED_JSON~;
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
		if (em.len == 0) { em = response_error_message(&er); }
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

// ===========================================================================
// 非流式入口：ChatRequest 进，聚合 ChatResponse 出（含 usage、finish_reason、
// reasoning）。HTTP 200 + 合法 JSON + 无 error 信号即成功。
// ===========================================================================
fn ChatResponse? complete(Allocator allocator, LlmOption* ctx, ChatRequest* req, LlmError* err)
{
	String payload = "";
	if (!make_payload(allocator, ctx, req, false, &payload, err)) { return MALFORMED_JSON~; }
	if (ctx.debug) { io::eprintfn("---\n%s\n---", payload); }

	int max_attempts = attempt_budget();
	int attempt = 1;
	while (true)
	{
		BodyRecv recv;
		recv.buf = dstring::new(tmem);
		int http_code = 0;
		String terr = http_attempt(ctx, payload, &http_code, &body_write_cb, &recv);
		String body = recv.buf.str_view();

		if (terr.len == 0 && http_code >= 200 && http_code < 300)
		{
			if (body.trim().len == 0)
			{
				// 2xx 空响应：非可重试类别（修正后的重试语义），立即失败
				return fail_attempt(allocator, err, http_code, EMPTY_RESPONSE_TEXT, AttemptCat.EMPTY_STREAM);
			}
			ChatResponse? pr = parse_response(allocator, body);
			if (catch pr)
			{
				return fail_attempt(allocator, err, http_code,
					"malformed JSON response from server", AttemptCat.MALFORMED_JSON);
			}
			ChatResponse resp = pr;
			String em = response_error_message(&resp);
			if (em.len > 0)
			{
				// 200 + error 体（OpenRouter 式）或 finish_reason=="error"：不重试
				return fail_attempt(allocator, err, http_code,
					string::tformat("API error: %s", em), AttemptCat.EMPTY_STREAM);
			}
			return resp;
		}

		AttemptCat cat;
		String msg = "";
		bool retryable = false;
		if (terr.len > 0)
		{
			cat = AttemptCat.TRANSPORT;
			msg = terr;
			retryable = true;
		}
		else if (http_code >= 500 || http_code == 429)
		{
			cat = AttemptCat.HTTP_STATUS;
			msg = fold_body_error(body);
			if (msg.len == 0) { msg = string::tformat("HTTP %d", http_code); }
			retryable = true;
		}
		else if (http_code >= 400)
		{
			cat = AttemptCat.HTTP_STATUS;
			msg = fold_body_error(body);
			if (msg.len == 0) { msg = string::tformat("HTTP %d", http_code); }
			retryable = false;
		}
		else
		{
			// 3xx / 其它未覆盖路径
			cat = AttemptCat.HTTP_STATUS;
			msg = string::tformat("HTTP %d", http_code);
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

// ===========================================================================
// 流式入口：ChatRequest 进，逐 chunk 先回调后聚合（打字机/推理流由调用方回调
// 决定输出），HTTP 传输成功且输出过 content 即返回聚合 ChatResponse。
// ===========================================================================
fn ChatResponse? stream(Allocator allocator, LlmOption* ctx, ChatRequest* req, LlmError* err, ChunkCb cb, void* ud)
{
	String payload = "";
	if (!make_payload(allocator, ctx, req, true, &payload, err)) { return MALFORMED_JSON~; }
	if (ctx.debug) { io::eprintfn("---\n%s\n---", payload); }

	int max_attempts = attempt_budget();
	int attempt = 1;
	while (true)
	{
		StreamRecv st;
		st.allocator = allocator;
		st.cb = cb;
		st.cb_ud = ud;
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
			if (msg.len == 0) { msg = string::tformat("HTTP %d", http_code); }
			retryable = !st.emitted;
		}
		else if (http_code >= 400)
		{
			cat = AttemptCat.HTTP_STATUS;
			msg = stream_fold_error(&st);
			if (msg.len == 0) { msg = string::tformat("HTTP %d", http_code); }
			retryable = false;
		}
		else
		{
			// 2xx/3xx 但没有任何输出：优先折叠错误体（200+error），否则空流
			cat = AttemptCat.EMPTY_STREAM;
			msg = stream_fold_error(&st);
			if (msg.len == 0) { msg = EMPTY_RESPONSE_TEXT; }
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
