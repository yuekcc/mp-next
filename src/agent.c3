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
fn String build_request(cli::Options* options, Message[] messages, bool with_tools)
{
	CJsonItem* root = cjson::create_object();
	defer root.free();

	root.set("model", options.model);
	CJsonItem* array = cjson::create_array();
	foreach (message : messages)
	{
		cjson::add_item_to_array(array, chat::message_to_json(&message, false));
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

fn ChatResponse chat_once(cli::Options* options, Message[] messages, bool with_tools)
{
	ChatResponse response;

	String request_body = build_request(options, messages, with_tools);
	String[] headers = {
		"Content-Type: application/json",
		string::format(tmem, "Authorization: Bearer %s", options.api_key),
	};

	log::debug("POST %s", options.api_url);
	log::debug("headers: Content-Type: application/json, Authorization: Bearer %s",
	           log::mask_secret(options.api_key));
	log::debug("request: %s", log::redact(buf::truncate(request_body, DEBUG_PREVIEW), options.api_key));

	http::HttpResponse res = http::http_post_json(options.api_url, headers, request_body);
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

fn int run(cli::Options* options)
{
	List{Message} messages;
	messages.init(mem);
	defer messages.free();

	session::Session store;
	bool persist = options.session_id.len != 0;
	if (persist)
	{
		store = session::open(options.session_id);
		// 系统提示词不进会话文件，每次运行重新注入（flag 或内置默认提示词）
		foreach (message : session::load(mem, &store)) messages.push(message);
	}
	if (options.system_prompt.len)
	{
		Message system = { .role = "system", .content = options.system_prompt };
		messages.push_front(system);
	}
	Message user = { .role = "user", .content = options.user_input };
	messages.push(user);

	// 本次 Trace 新增的消息，成功后一次性落盘
	List{Message} fresh;
	fresh.init(mem);
	defer fresh.free();
	fresh.push(user);

	bool with_tools = tools::registry_len != 0;
	String session_note = persist ? string::format(tmem, " session=%s", options.session_id) : "";
	String limit_note = options.max_turns > 0 ? string::format(tmem, "，max-turns=%d", options.max_turns) : "";
	log::info("Trace 开始%s，model=%s，tools=%d%s",
	          session_note, options.model, (int)tools::registry_len, limit_note);

	usz turn = 0;
	while LOOP: (true) @pool()
	{
		turn++;
		// --max-turns：n>0 时最多发起 n 次请求；没给或 <=0 则不设上限
		if (options.max_turns > 0 && turn > (usz)options.max_turns)
		{
			log::error("已达到 --max-turns=%d 上限，停止循环（本轮没有最终答案）", options.max_turns);
			return cli::EXIT_UNCONVERGED;
		}
		Clock mark = clock::now();
		ChatResponse response = chat_once(options, messages.to_array(tmem), with_tools);
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
			fresh.push(assistant);

			foreach (call : response.tool_calls)
			{
				Clock tool_mark = clock::now();
				tools::ToolResult result = tools::run_tool(call.name, call.arguments);
				log::info("[turn %d] %s(%s) -> %s, %dms",
				          turn, call.name, buf::truncate(call.arguments, 120),
				          result.is_error ? "error" : "ok", elapsed_ms(&tool_mark));

				Message tool_message = {
					.role = "tool",
					.tool_call_id = call.id,
					.content = result.content,
				};
				messages.push(tool_message);
				fresh.push(tool_message);
			}
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
			fresh.push(assistant);
			if (persist) session::append(&store, turn, fresh.to_array(mem));
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
