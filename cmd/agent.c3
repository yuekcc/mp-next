// agent — llmcmd 的 agent loop（CLI 交互层；llm 模块保持无状态传输层）。
//
// 领域词汇见 CONTEXT.md：Trace = 一次进程运行（用户 prompt 到最终输出）；Turn =
// 一次请求-响应往返。loop 唯一出口 = 响应不带 tool_calls（不设 turn 上限）。
// 工具经 ToolHub（src/tool/）管理：--tools 显式 opt-in，null hub = 纯 chat，
// 行为与 agent loop 引入前完全一致。工具调用与结果只上 stderr --debug。
//
// AppContext（agent 级）是贯穿整个 trace 的数据中心：接口设置（LlmOption）、
// 请求参数、消息历史与工具注册表引用。llm 模块的 LlmOption 不含任何会话状态。
module llmcmd;

import std::io;
import std::io::path;
import std::core::string;
import std::collections::list;
import llm, tool, cjson;

// ===========================================================================
// agent 级 AppContext（trace 数据中心）
// ===========================================================================

struct AppContext
{
	LlmOption opt;               // 接口设置（url/api_key/extra_body/debug/...）
	String model;
	int max_tokens;
	bool thinking;               // --thinking（reasoning 对象开关）
	String thinking_level;       // low/medium/high/xhigh，空 = 服务端默认
	String system;
	List{ChatMessage} messages;  // trace 消息历史（每 turn 追加 assistant/tool）
	ToolHub* hub;                // null = 无工具（纯 chat）
	// ponytail: session_id/request_id 是 mini_pi 对齐留位（v1 恒空串）；升级路径
	// = llmcmd 接入 session 基础设施时填充（同时解锁 Task 工具注册）。
	String session_id;
	String request_id;
	String config_dir;
	bool transcript_enabled;
}

// ===========================================================================
// 工具注册与派发
// ===========================================================================

ToolHub g_hub;
ToolHub* g_hub_ptr = null;

// llmcmd 可注册的工具白名单（ToolHub 支持的 minus Task：Task 依赖子 agent
// session 基础设施，llmcmd 未提供，注册即坏）。
// ponytail: 与 ToolHub.init 的 switch 重复维护同一注册表，新增工具需两处同步；
// 升级路径 = ToolHub 暴露注册表查询（如 known_tools()）后由这里直接消费。
const String[] KNOWN_TOOLS = { "ReadFile", "Bash", "EditFile", "WriteFile",
	"Grep", "Glob", "ListDir", "HashEditFile" };

fn bool is_known_tool(String name)
{
	foreach (t : KNOWN_TOOLS) {
		if (t == name) { return true; }
	}
	return false;
}

// --tools 名单校验 + ToolHub 初始化。必须在 init 前校验：ToolHub.init 对未知
// 工具名直接 unreachable（abort），此处提前 die 出友好错误。
fn void agent_setup_tools(String tools_arg)
{
	if (tools_arg.len == 0) { return; }
	List{String} allowed;
	allowed.init(tmem);
	usz start = 0;
	for (usz i = 0; i <= tools_arg.len; i++) {
		if (i == tools_arg.len || tools_arg[i] == ',') {
			String name = tools_arg[start : i - start].trim();
			if (name.len > 0) {
				if (name == "Task") { die("Task tool is not supported by llm (requires sub-agent session infrastructure)"); }
				if (!is_known_tool(name)) { die(string::tformat("Unknown tool: %s (try llm --help)", name)); }
				allowed.push(name);
			}
			start = i + 1;
		}
	}
	if (allowed.len() == 0) { warn_msg("empty --tools list, running without tools"); return; }
	g_hub_ptr = g_hub.init(tmem, allowed.to_array(tmem));
}

fn ToolContext build_tool_context(AppContext* actx)
{
	ToolContext tc;
	tc.session_id = actx.session_id;
	tc.request_id = actx.request_id;
	Path? cd = path::new(tmem, actx.config_dir);
	if (try cdp = cd)
	{
		tc.config_dir = cdp;
	}
	else
	{
		die(string::tformat("invalid config_dir: %s", actx.config_dir));
	}
	tc.transcript_enabled = actx.transcript_enabled;
	tc.base_url = actx.opt.url;
	tc.model = actx.model;
	tc.api_key = actx.opt.api_key;
	return tc;
}

// 执行单个 tool_call 并把结果（或错误文本）作为 role:"tool" 消息追加进历史。
// 失败不 die：错误文本回传给模型自愈（agent loop 的意义所在）。
fn void execute_tool_call(AppContext* actx, ChatToolCall* tc, int turn)
{
	String result;

	CJsonItem* args = cjson::parse(tc.arguments.zstr_tcopy());
	if (!args) {
		result = string::tformat("Error: tool '%s' arguments are not valid JSON", tc.name);
	} else {
		defer args.free();
		ToolContext tctx = build_tool_context(actx);
		DString out = dstring::new(tmem);
		ToolResultMeta meta;
		if (catch dispatch_err = actx.hub.do_dispatch(&tctx, tmem, &out, tc.name, args, &meta))
		{
			result = string::tformat("Error: tool '%s' dispatch failed (fault %s)", tc.name, dispatch_err);
		}
		else
		{
			result = out.str_view();
			if (result.trim().len == 0) { result = "(no output)"; }
		}
	}

	if (g_debug) {
		io::eprintfn("[turn %d] tool %s(%s)", turn, tc.name, tc.arguments);
		io::eprintfn("[turn %d] tool result: %s", turn, result);
	}

	ChatMessage tm = llm::new_message(tmem, "tool", result);
	tm.tool_call_id = tc.id;
	actx.messages.push(tm);
}

// ===========================================================================
// agent loop
// ===========================================================================

fn void run_trace(AppContext* actx)
{
	int turn = 0;
	while (true)
	{
		turn++;
		llm::ChatRequest req;
		req.model = actx.model;
		req.messages = actx.messages; // List 句柄共享（stream 不改写 messages）
		req.max_tokens_key = tokens_field();
		req.max_tokens = actx.max_tokens;
		req.reasoning = actx.thinking;
		req.reasoning_effort = actx.thinking_level;
		req.reasoning_summary = "auto";
		if (actx.hub != null) { req.tools_json = actx.hub.schema(tmem); }

		llm::LlmError err;
		llm::ChatResponse? r = llm::stream(tmem, &actx.opt, &req, &err, &chunk_cb, null);
		if (try resp = r)
		{
			write_usage(resp.usage.prompt_tokens, resp.usage.completion_tokens, resp.usage.reasoning_tokens);
			ledger_append();

			// 聚合 assistant 消息入历史（tool_calls 句柄从 choice 移交）
			llm::ChatChoice* ch = resp.choices.get_ref(0);
			ChatMessage assistant = llm::new_message(tmem, "assistant", ch.content);
			assistant.tool_calls = ch.tool_calls;
			if (resp.reasoning.len > 0) { assistant.reasoning = resp.reasoning; }
			actx.messages.push(assistant);

			// stop：无 tool_calls = trace 唯一正常出口（无 turn 上限，Ctrl+C 兜底）
			if (assistant.tool_calls.len() == 0) { return; }

			foreach (&tc : &assistant.tool_calls) {
				execute_tool_call(actx, tc, turn);
			}
		}
		else
		{
			die(err.message);
		}
	}
}
