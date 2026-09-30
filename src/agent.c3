module llmcli::agent;

import std::io, std::time, std::time::clock;
import std::collections::list;
import cjson;
import llmcli::buf, llmcli::chat, llmcli::cli, llmcli::http, llmcli::log, llmcli::session, llmcli::tools;

// 内存策略：一次 Trace 的消息（含工具结果）在进程生命周期内保留——CLI 跑完即退出，
// 不做逐轮释放（v1 也不设 turn/长度上限，见 PRD 风险表）；每轮的临时数据走 tmem，
// 由循环上的 @pool() 回收。
const usz DEBUG_PREVIEW = 4000;

// 组装一次 chat completions 请求体（tmem，属本轮 scratch）。
// include_reasoning 恒为 false：reasoning_content 只入会话存档，绝不回传给端点。
fn String build_request(cli::Ctx* ctx, Message[] messages, bool with_tools)
{
	CJsonItem* root = cjson::create_object();
	defer root.free();

	root.set("model", ctx.model);
	CJsonItem* array = cjson::create_array();
	foreach (message : messages)
	{
		cjson::add_item_to_array(array, chat::message_to_request_json(&message));
	}
	root.set_item("messages", array);
	// 用 add_false_to_object 而不是 set("stream", false)：cJSON 的 cJSON_bool 是 int，
	// 与 C3 的 bool 宽度不同，走 C 变参/值传递会得到 true。
	cjson::add_false_to_object(root, "stream");
	if (with_tools) root.set_item("tools", tools::to_json());

	ZString printed = cjson::print_unformatted(root);
	String body = buf::cstr(tmem, printed);
	cjson::free(printed);
	return body;
}

fn ChatResponse chat_once(cli::Ctx* ctx, Message[] messages, bool with_tools)
{
	ChatResponse response;

	String request_body = build_request(ctx, messages, with_tools);
	String[] headers = {
		"Content-Type: application/json",
		string::format(tmem, "Authorization: Bearer %s", ctx.api_key),
	};

	log::debug("POST %s", ctx.api_url);
	// 密钥由 log 统一脱敏（main 里 add_secret 注册过一次），这里直接打原文即可
	log::debug("headers: Content-Type: application/json, Authorization: Bearer %s", ctx.api_key);
	log::debug("request: %s", buf::truncate(request_body, DEBUG_PREVIEW));

	http::HttpResponse res = http::http_post_json(ctx.api_url, headers, request_body);
	if (res.error.len)
	{
		response.error = string::format(mem, "网络错误：%s", res.error);
		return response;
	}
	log::debug("response(%d): %s", res.status, buf::truncate(res.body, DEBUG_PREVIEW));

	if (res.status < 200 || res.status >= 300)
	{
		response.error = string::format(mem, "HTTP %d：%s", res.status, buf::truncate(res.body, 2000));
		return response;
	}

	response = chat::parse_response(mem, res.body);
	if (!response.ok) response.error = string::format(mem, "%s；原始响应：%s",
	                                                  response.error, buf::truncate(res.body, 2000));
	return response;
}

fn void print_answer(String content)
{
	io::print(content);
	if (!content.ends_with("\n"))
	{
		io::printn("");
	}
}

// 一个 turn 攒齐后立刻落盘并清空缓冲（没给 --session-id 时只清空）。
// 整轮一次 write：既不会与其他进程的行交错，也不会留下半截 turn——
// assistant 的 tool_calls 一定和它的 tool 结果同批写入，所以中断/报错后
// 文件末尾永远是完整 turn，load 读到的必定是合法前缀。
fn void flush_turn(session::Session* store, List{session::Record}* pending, bool persist) @private
{
	if (persist && pending.len()) session::append(store, pending.to_array(mem));
	pending.clear();
}

// 一次运行（一个 Trace）：上下文从 ctx 进，turn/messages/pending/store 都只活在这个函数里。
fn int run(cli::Ctx* ctx)
{
	List{Message} messages;
	messages.init(mem);
	defer messages.free();

	session::Session store;
	bool persist = ctx.session_id.len != 0;
	if (persist)
	{
		store = session::open(ctx.session_id);
		// 系统提示词不进会话文件，每次运行重新注入（flag 或内置默认提示词）
		foreach (message : session::load(mem, &store)) messages.push(message);
	}
	if (ctx.system_prompt.len)
	{
		Message system = { .role = "system", .content = ctx.system_prompt };
		messages.push_front(system);
	}
	Message user = { .role = "user", .content = ctx.user_input };
	messages.push(user);

	// 本 turn 待落盘的记录：turn 记它在哪一轮，ts 记它发生的时刻。
	// 整个 turn 攒齐后一次 write 落盘（见 flush_turn），落到文件里的永远是完整 turn。
	List{session::Record} pending;
	pending.init(mem);
	defer pending.free();
	pending.push({ .message = user, .turn = 1, .ts = session::timestamp(mem) });

	bool with_tools = tools::registry_len != 0;
	String session_note = persist ? string::format(tmem, " session=%s", ctx.session_id) : "";
	String limit_note = ctx.max_turns > 0 ? string::format(tmem, "，max-turns=%d", ctx.max_turns) : "";
	log::info("Trace 开始%s，model=%s，tools=%d%s",
	          session_note, ctx.model, (int)tools::registry_len, limit_note);

	usz turn = 0;
	while LOOP: (true) @pool()
	{
		turn++;
		// --max-turns：n>0 时最多发起 n 次请求；没给或 <=0 则不设上限
		if (ctx.max_turns > 0 && turn > (usz)ctx.max_turns)
		{
			log::error("已达到 --max-turns=%d 上限，停止循环（本轮没有最终答案）", ctx.max_turns);
			return cli::EXIT_UNCONVERGED;
		}
		Clock mark = clock::now();
		ChatResponse response = chat_once(ctx, messages.to_array(tmem), with_tools);
		if (!response.ok)
		{
			log::error("%s", response.error);
			return cli::EXIT_FAILURE;
		}

		// 每轮一行摘要：turn 序号、assistant 决策、耗时、reasoning 字符数、token 用量
		String decision = response.finish_reason.len
			? response.finish_reason
			: (response.tool_calls.len ? "tool_calls" : "stop");
		log::info("[turn %d] assistant -> %s, %dms%s", turn, decision, elapsed_ms(&mark),
		          format_reasoning(response.reasoning, response.usage));
		if (response.reasoning.len) log::debug("reasoning_content: %s", response.reasoning);

		if (response.tool_calls.len)
		{
			Message assistant = {
				.role = "assistant",
				.content = response.content,
				.reasoning = response.reasoning,
				.tool_calls = response.tool_calls,
			};
			messages.push(assistant);
			pending.push({ .message = assistant, .turn = turn, .ts = session::timestamp(mem) });

			foreach (call : response.tool_calls)
			{
				Clock tool_mark = clock::now();
				tools::ToolResult result = tools::run_tool(ctx, call.name, call.arguments);
				log::info("[turn %d] %s(%s) -> %s, %dms",
				          turn, call.name, buf::truncate(call.arguments, 120),
				          result.is_error ? "error" : "ok", elapsed_ms(&tool_mark));

				Message tool_message = {
					.role = "tool",
					.tool_call_id = call.id,
					.content = result.content,
				};
				messages.push(tool_message);
				pending.push({ .message = tool_message, .turn = turn, .ts = session::timestamp(mem) });
			}
			// 这一轮的决策与全部工具结果都攒齐了，整轮落盘
			flush_turn(&store, &pending, persist);
			continue LOOP;
		}
		if (response.content.len)
		{
			print_answer(response.content);

			Message assistant = {
				.role = "assistant",
				.content = response.content,
				.reasoning = response.reasoning,
			};
			pending.push({ .message = assistant, .turn = turn, .ts = session::timestamp(mem) });
			flush_turn(&store, &pending, persist);
			log::info("Trace 结束，共 %d turn", turn);
			return cli::EXIT_OK;
		}

		log::error("第 %d turn 既没有工具调用也没有最终答案，循环未收敛", turn);
		return cli::EXIT_UNCONVERGED;
	};
}

fn long elapsed_ms(Clock* mark) @private
{
	return mark.mark().to_ms();
}

fn String format_reasoning(String reasoning, String usage) @private
{
	if (!reasoning.len && !usage.len) return "";
	return string::format(tmem, "%s%s%s",
	                      reasoning.len ? string::tformat("，reasoning %d 字符", reasoning.len) : "",
	                      usage.len ? "，" : "",
	                      usage);
}
