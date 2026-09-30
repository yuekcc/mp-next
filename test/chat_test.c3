module llmcli::test_chat;

import std::io;
import cjson;
import llmcli::buf, llmcli::chat, llmcli::cli, llmcli::agent, llmcli::tools;

fn void test_parse_stop_with_content() @test
{
	@pool()
	{
		String body = `{"choices":[{"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}]}`;
		ChatResponse parsed = chat::parse_response(tmem, body);
		test::eq(parsed.ok, true);
		test::eq(parsed.content, "hello");
		test::eq(parsed.finish_reason, "stop");
		test::eq((int)parsed.tool_calls.len, 0);
	};
}

fn void test_parse_tool_calls() @test
{
	@pool()
	{
		String body = `{"choices":[{"message":{"role":"assistant","content":null,` +++
		              `"tool_calls":[{"id":"call_1","type":"function","function":` +++
		              `{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]},` +++
		              `"finish_reason":"tool_calls"}]}`;
		ChatResponse parsed = chat::parse_response(tmem, body);
		test::eq(parsed.ok, true);
		test::eq(parsed.finish_reason, "tool_calls");
		test::eq((int)parsed.tool_calls.len, 1);
		test::eq(parsed.tool_calls[0].id, "call_1");
		test::eq(parsed.tool_calls[0].name, "bash");
		test::eq(parsed.tool_calls[0].arguments, `{"command":"ls"}`);
	};
}

// 分片形态：一次调用被拆成多元素、name/arguments 分散、靠 index=0 关联。
fn void test_parse_merges_fragmented_tool_call() @test
{
	@pool()
	{
		String body = `{"choices":[{"message":{"role":"assistant","tool_calls":[` +++
		              `{"id":"call_1","type":"function","index":0,` +++
		              `"function":{"name":"list_dir","arguments":""}},` +++
		              `{"index":0,"function":{"arguments":"{\"path\": \""}},` +++
		              `{"index":0,"function":{"arguments":"Z:\\\\proj"}},` +++
		              `{"index":0,"function":{"arguments":"\"}"}}]},` +++
		              `"finish_reason":"tool_calls"}]}`;
		ChatResponse parsed = chat::parse_response(tmem, body);
		test::eq(parsed.ok, true);
		test::eq((int)parsed.tool_calls.len, 1);
		test::eq(parsed.tool_calls[0].name, "list_dir");
		test::eq(parsed.tool_calls[0].arguments, `{"path": "Z:\\proj"}`);
	};
}

// 并行分片：两个 index 各自归并，互不串联。
fn void test_parse_merges_parallel_fragmented_tool_calls() @test
{
	@pool()
	{
		String body = `{"choices":[{"message":{"role":"assistant","tool_calls":[` +++
		              `{"id":"call_a","index":0,"function":{"name":"bash","arguments":"{\"comm"}},` +++
		              `{"id":"call_b","index":1,"function":{"name":"bash","arguments":"{\"comm"}},` +++
		              `{"index":0,"function":{"arguments":"and\": \"echo A\"}"}},` +++
		              `{"index":1,"function":{"arguments":"and\": \"echo B\"}"}}]},` +++
		              `"finish_reason":"tool_calls"}]}`;
		ChatResponse parsed = chat::parse_response(tmem, body);
		test::eq(parsed.ok, true);
		test::eq((int)parsed.tool_calls.len, 2);
		test::eq(parsed.tool_calls[0].id, "call_a");
		test::eq(parsed.tool_calls[0].arguments, `{"command": "echo A"}`);
		test::eq(parsed.tool_calls[1].id, "call_b");
		test::eq(parsed.tool_calls[1].arguments, `{"command": "echo B"}`);
	};
}

// 非流式的并行完整调用没有 index，必须保持逐元素语义，不能被错误归并。
fn void test_parse_keeps_indexless_parallel_tool_calls() @test
{
	@pool()
	{
		String body = `{"choices":[{"message":{"role":"assistant","tool_calls":[` +++
		              `{"id":"call_a","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo A\"}"}},` +++
		              `{"id":"call_b","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo B\"}"}}]},` +++
		              `"finish_reason":"tool_calls"}]}`;
		ChatResponse parsed = chat::parse_response(tmem, body);
		test::eq(parsed.ok, true);
		test::eq((int)parsed.tool_calls.len, 2);
		test::eq(parsed.tool_calls[0].id, "call_a");
		test::eq(parsed.tool_calls[1].id, "call_b");
		test::eq(parsed.tool_calls[0].arguments, `{"command":"echo A"}`);
		test::eq(parsed.tool_calls[1].arguments, `{"command":"echo B"}`);
	};
}

fn void test_parse_captures_reasoning_and_usage() @test
{
	@pool()
	{
		String body = `{"choices":[{"message":{"role":"assistant","content":"a",` +++
		              `"reasoning_content":"think"},"finish_reason":"stop"}],` +++
		              `"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}`;
		ChatResponse parsed = chat::parse_response(tmem, body);
		test::eq(parsed.ok, true);
		test::eq(parsed.reasoning, "think");
		test::@check(parsed.usage.contains("total=3"), "应带上 usage，实际：%s", parsed.usage);
	};
}

fn void test_parse_rejects_broken_json() @test
{
	@pool()
	{
		ChatResponse parsed = chat::parse_response(tmem, "not json at all");
		test::eq(parsed.ok, false);
		test::@check(parsed.error.contains("合法 JSON"), "应提示非法 JSON，实际：%s", parsed.error);
	};
}

fn void test_parse_rejects_missing_choices() @test
{
	@pool()
	{
		ChatResponse parsed = chat::parse_response(tmem, `{"error":{"message":"boom"}}`);
		test::eq(parsed.ok, false);
		test::@check(parsed.error.contains("choices"), "应提示缺少 choices，实际：%s", parsed.error);
	};
}

fn void test_request_strips_reasoning_content() @test
{
	@pool()
	{
		cli::Ctx ctx;
		ctx.model = "m";
		Message assistant = {
			.role = "assistant",
			.content = "answer",
			.reasoning = "secret chain of thought",
		};
		Message[] messages = { assistant };

		String body = agent::build_request(&ctx, messages, false);
		test::@check(!body.contains("reasoning_content"),
		             "请求体不能带 reasoning_content，实际：%s", body);
		test::@check(body.contains(`"stream":false`), "stream 必须是 false，实际：%s", body);

		CJsonItem* root = cjson::parse_with_length((ZString)body.ptr, body.len);
		CJsonItem* array = root.get_key("messages");
		test::eq((int)array.get_len(), 1);
		test::eq(root.has_key("tools"), false);
		root.free();
	};
}

fn void test_request_includes_tools_when_registered() @test
{
	@pool()
	{
		if (!tools::find_tool("bash")) tools::register_builtin_tools();
		cli::Ctx ctx;
		ctx.model = "m";
		Message user = { .role = "user", .content = "hi" };
		Message[] messages = { user };

		String body = agent::build_request(&ctx, messages, true);
		test::@check(body.contains(`"tools"`), "启用工具时应带 tools 字段，实际：%s", body);
		test::@check(body.contains(`"bash"`), "应包含 bash 工具定义，实际：%s", body);
	};
}

fn void test_message_json_roundtrip_keeps_reasoning_and_tool_calls() @test
{
	@pool()
	{
		ToolCall[] calls = { { .id = "call_9", .name = "bash", .arguments = "{}" } };
		Message original = {
			.role = "assistant",
			.content = "c",
			.reasoning = "r",
			.tool_calls = calls,
		};

		CJsonItem* json = chat::message_to_archive_json(&original);
		defer json.free();
		String printed = buf::cstr(tmem, cjson::print_unformatted(json));

		CJsonItem* back = cjson::parse_with_length((ZString)printed.ptr, printed.len);
		defer back.free();
		Message restored = chat::message_from_json(tmem, back);

		test::eq(restored.role, "assistant");
		test::eq(restored.content, "c");
		test::eq(restored.reasoning, "r");
		test::eq((int)restored.tool_calls.len, 1);
		test::eq(restored.tool_calls[0].name, "bash");
	};
}
