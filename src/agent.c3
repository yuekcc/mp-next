module llmcli::agent;

import std::io, std::time, std::time::clock;
import std::collections::list;
import llmcli::buf, llmcli::chat, llmcli::cli, llmcli::http, llmcli::log, llmcli::runtime,
	llmcli::session;

// 本模块是 Trace 的全部：主循环、从回复里取代码块、一次 API 往返、逐 turn 落盘。
// 内存策略：一次 Trace 的消息（含执行输出）在进程生命周期内保留——CLI 跑完即退出，
// 不做逐轮释放（v1 也不设 turn/长度上限，见 PRD 风险表）；每轮的临时数据走 tmem，
// 由循环上的 @pool() 回收。

// ---- 常量 ----

// 只用于 stderr 展示（--debug / 错误摘要）的请求/响应预览长度。
const usz DEBUG_PREVIEW = 4000;

// ---- 类型 ----

// 从模型回复里取出的第一个代码块。code 在 mem 上，由调用方释放。
struct Extract
{
	String code;      // 第一个代码块的内容；没有代码块时为空
	bool has_code;    // 是否真的找到了代码块（与 code 为空区分：空代码块 has_code=true）
	bool truncated;   // 第一个代码块之后还有其他代码块（只执行第一个）
}

// ---- Trace 主循环 ----

// 一次运行（一个 Trace）：上下文从 ctx 进，turn/messages/pending/store 都只活在这个函数里。
// 循环：请求 → 取 ```bash 代码块 → 本地执行 → 输出作为下一条 user 回填，直到代码设了
// FINAL / FINAL_FILE（或回复里没有代码块，则整段回复即答案）。
fn int run(cli::Ctx* ctx)
{
	List{chat::Message} messages;
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
		chat::Message system = { .role = "system", .content = ctx.system_prompt };
		messages.push_front(system);
	}
	chat::Message user = { .role = "user", .content = ctx.user_input };
	messages.push(user);

	// 本 turn 待落盘的记录：turn 记它在哪一轮，ts 记它发生的时刻。
	// 整个 turn 攒齐后一次 write 落盘（见 flush_turn），落到文件里的永远是完整 turn。
	List{session::Record} pending;
	pending.init(mem);
	defer pending.free();
	pending.push({ .message = user, .turn = 1, .ts = session::timestamp(mem) });

	String session_note = persist ? string::format(tmem, " session=%s", ctx.session_id) : "";
	String limit_note = ctx.max_turns > 0 ? string::format(tmem, "，max-turns=%d", ctx.max_turns) : "";
	log::info("Trace 开始%s，model=%s%s", session_note, ctx.model, limit_note);

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
		chat::ChatResponse response = chat_once(ctx, messages.to_array(tmem));
		if (!response.ok)
		{
			log::error("%s", response.error);
			return cli::EXIT_FAILURE;
		}

		// 每轮一行摘要：turn 序号、耗时、reasoning 字符数、token 用量
		log::info("[turn %d] 响应, %dms%s", turn, elapsed_ms(&mark),
		          format_reasoning(response.reasoning, response.usage));
		if (response.reasoning.len) log::debug("reasoning_content: %s", response.reasoning);

		// 空响应：既无内容也无代码块，循环无法推进
		if (!response.content.len)
		{
			log::error("第 %d turn 响应内容为空，循环未收敛", turn);
			return cli::EXIT_UNCONVERGED;
		}

		Extract extracted = extract_code(response.content);

		// 没有代码块：整个回复就是最终答案（shellm 同款兜底，单轮问答即走这条路）
		if (!extracted.has_code)
		{
			print_answer(response.content);
			chat::Message assistant = {
				.role = "assistant",
				.content = response.content,
				.reasoning = response.reasoning,
			};
			pending.push({ .message = assistant, .turn = turn, .ts = session::timestamp(mem) });
			flush_turn(&store, &pending, persist);
			log::info("Trace 结束，共 %d turn", turn);
			return cli::EXIT_OK;
		}
		if (extracted.truncated)
		{
			log::warn("回复含多个代码块，只执行第一个（其余丢弃）");
		}

		// 决策入历史：assistant 的回复原文（散文 + 代码块）与思维链
		chat::Message assistant = {
			.role = "assistant",
			.content = response.content,
			.reasoning = response.reasoning,
		};
		messages.push(assistant);
		pending.push({ .message = assistant, .turn = turn, .ts = session::timestamp(mem) });

		Clock exec_mark = clock::now();
		runtime::Execution exec = runtime::run_bash(extracted.code);
		log::info("[turn %d] 执行 -> exit %d, %dms", turn, exec.exit_code, elapsed_ms(&exec_mark));

		// 执行输出作为下一条 user 消息回填（shellm 的 shell-output 语义）
		String observation = exec.output.len ? exec.output : "（无输出）";
		chat::Message observation_message = { .role = "user", .content = observation };
		messages.push(observation_message);
		pending.push({ .message = observation_message, .turn = turn, .ts = session::timestamp(mem) });

		// 这一轮的决策与执行输出都攒齐了，整轮落盘
		flush_turn(&store, &pending, persist);

		if (exec.has_final)
		{
			print_answer(exec.final_answer);
			// 最终答案补一条 assistant 记录，会话以 assistant 收尾、续话读来自然
			chat::Message final_message = { .role = "assistant", .content = exec.final_answer };
			pending.push({ .message = final_message, .turn = turn, .ts = session::timestamp(mem) });
			flush_turn(&store, &pending, persist);
			log::info("Trace 结束，共 %d turn", turn);
			return cli::EXIT_OK;
		}
	};
}

// ---- 代码块提取 ----

// 行级扫描：围栏行开块，之后第一条 trim 后恰为 ``` 的行闭块。
// 围栏行两种形态：整行以 ``` 开头（含裸 ```），或带 ```bash / ```sh / ```shell 的
// 标记围栏缀在散文行末（模型偶尔写成"……这样。```bash"）。代码块内以 ``` 开头的行
// 不当作闭块（避免代码里嵌 markdown 时早闭）。闭块后再出现围栏行只置 truncated，
// 不再收集——只有第一个块会被执行。
//
// 不做 shellm 那套 heredoc 感知与工具标记归一化：v1 只认标准围栏，模型按提示词
// 把围栏单独放一行即可；过度宽松地"把整段散文当命令跑"反而更危险。
fn Extract extract_code(String response)
{
	Extract out;
	List{String} body;
	body.init(tmem);

	bool in_block = false;
	bool closed = false;
	String[] lines = response.split(tmem, "\n");
	foreach (line : lines)
	{
		String trimmed = line.trim();
		String rtrimmed = line.trim_right();
		bool fence = trimmed.starts_with("```")
			|| rtrimmed.ends_with("```bash")
			|| rtrimmed.ends_with("```sh")
			|| rtrimmed.ends_with("```shell");

		if (closed)
		{
			// 闭块之后只要再看到围栏行，就说明还有多余代码块
			if (fence) out.truncated = true;
			continue;
		}

		if (!in_block)
		{
			if (fence)
			{
				in_block = true;
				out.has_code = true;
			}
			continue;
		}

		// 块内：精确的闭围栏才收尾；块内其他 ``` 行当代码原样保留
		if (trimmed == "```")
		{
			in_block = false;
			closed = true;
			continue;
		}
		body.push(line);
	}

	if (out.has_code)
	{
		// 去掉块内尾部的空行，避免脚本末尾多出无意义换行（不影响语义，仅整洁）
		while (body.len() && body.get(body.len() - 1).trim().len == 0) (void)body.pop();
		DString joined = dstring::new(tmem);
		foreach (line : body)
		{
			joined.append(line);
			joined.append("\n");
		}
		out.code = joined.str_view().copy(mem);
	}

	body.free();
	return out;
}

// ---- API 往返 ----

// 一次 chat completion 往返：组装请求 → POST → 解析响应。
// 任一环节失败都在返回的 ChatResponse.error 里给出可读原因（mem 上的堆串）。
// 密钥由 log 统一脱敏（main 里 add_secret 注册过一次），这里直接打原文即可。
fn chat::ChatResponse chat_once(cli::Ctx* ctx, chat::Message[] messages)
{
	chat::ChatResponse response;

	String request_body = chat::build_request(ctx.model, messages);
	String[] headers = {
		"Content-Type: application/json",
		string::format(tmem, "Authorization: Bearer %s", ctx.api_key),
	};

	log::debug("POST %s", ctx.api_url);
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

// ---- 落盘 ----

// 一个 turn 攒齐后立刻落盘并清空缓冲（没给 --session-id 时只清空）。
// 整轮一次 write：既不会与其他进程的行交错，也不会留下半截 turn——
// 所以中断/报错后文件末尾永远是完整 turn，load 读到的必定是合法前缀。
fn void flush_turn(session::Session* store, List{session::Record}* pending, bool persist) @private
{
	if (persist && pending.len()) session::append(store, pending.to_array(mem));
	pending.clear();
}

// ---- 输出与摘要 ----

fn void print_answer(String content) @private
{
	io::print(content);
	if (!content.ends_with("\n"))
	{
		io::printn("");
	}
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
