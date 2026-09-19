module llmcli::chat;

import cjson;

struct ToolCall
{
	String id;
	String name;
	String arguments; // OpenAI 协议里 arguments 是 JSON 字符串，这里保持原文
}

struct Message
{
	String role;         // system / user / assistant / tool
	String content;
	String reasoning;    // reasoning_content 原文；空串表示没有
	ToolCall[] tool_calls;
	String tool_call_id; // 仅 role=tool
}

struct ChatResponse
{
	bool ok;
	String error;
	String content;
	String reasoning;
	ToolCall[] tool_calls;
	String finish_reason;
	String usage;
}

// ---- 序列化 ---------------------------------------------------------------

// 回传给端点的形态：reasoning_content 槽位为空（DeepSeek 等端点收到会报错）
fn CJsonItem* message_to_request_json(Message* msg) => message_to_json(msg, false);

// 会话存档的形态：带上 reasoning_content
fn CJsonItem* message_to_archive_json(Message* msg) => message_to_json(msg, true);

fn CJsonItem* message_to_json(Message* msg, bool include_reasoning) @private
{
	CJsonItem* obj = cjson::create_object();
	obj.set("role", msg.role);

	if (msg.tool_calls.len)
	{
		CJsonItem* calls = cjson::create_array();
		foreach (call : msg.tool_calls)
		{
			CJsonItem* item = cjson::create_object();
			item.set("id", call.id);
			item.set("type", "function");
			CJsonItem* function = cjson::add_object_to_object(item, "function");
			function.set("name", call.name);
			function.set("arguments", call.arguments);
			cjson::add_item_to_array(calls, item);
		}
		obj.set_item("tool_calls", calls);
		if (msg.content.len)
		{
			obj.set("content", msg.content);
		}
		else
		{
			cjson::add_null_to_object(obj, "content");
		}
	}
	else
	{
		obj.set("content", msg.content);
	}

	if (msg.tool_call_id.len) obj.set("tool_call_id", msg.tool_call_id);
	// reasoning_content 只入会话存档，绝不回传给端点（DeepSeek 等会报错）
	if (include_reasoning && msg.reasoning.len) obj.set("reasoning_content", msg.reasoning);
	return obj;
}

fn Message message_from_json(Allocator allocator, CJsonItem* obj)
{
	Message msg;
	msg.role = obj.get_key_string("role", allocator) ?? "";
	msg.content = obj.get_key_string("content", allocator) ?? "";
	msg.reasoning = obj.get_key_string("reasoning_content", allocator) ?? "";
	msg.tool_call_id = obj.get_key_string("tool_call_id", allocator) ?? "";

	msg.tool_calls = tool_calls_from_json(allocator, obj.get_key("tool_calls"));
	return msg;
}

// 从 message 对象里取 tool_calls 数组；字段缺失/类型不对都退化成空数组。
fn ToolCall[] tool_calls_from_json(Allocator allocator, CJsonItem* calls)
{
	if (!calls || !calls.is_array()) return {};
	usz count = calls.get_len();
	if (!count) return {};

	ToolCall[] list = alloc::alloc_array(allocator, ToolCall, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		CJsonItem* item = calls.get_at((sz)i);
		if (!item) continue;
		CJsonItem* function = item.get_key("function");
		list[i] = {
			.id = item.get_key_string("id", allocator) ?? "",
			.name = function ? (function.get_key_string("name", allocator) ?? "") : "",
			.arguments = function ? (function.get_key_string("arguments", allocator) ?? "") : "",
		};
	}
	return list;
}

// ---- 响应解析 -------------------------------------------------------------

fn ChatResponse parse_response(Allocator allocator, String body)
{
	ChatResponse res;
	CJsonItem* root = cjson::parse_with_length((ZString)body.ptr, body.len);
	if (!root)
	{
		res.error = "响应不是合法 JSON";
		return res;
	}
	defer root.free();

	CJsonItem* choices = root.get_key("choices");
	if (!choices || !choices.is_array())
	{
		res.error = "响应缺少 choices 数组";
		return res;
	}
	CJsonItem* choice = choices.get_at(0);
	if (!choice)
	{
		res.error = "响应 choices 为空";
		return res;
	}
	CJsonItem* message = choice.get_key("message");
	if (!message)
	{
		res.error = "响应缺少 choices[0].message";
		return res;
	}

	res.content = message.get_key_string("content", allocator) ?? "";
	res.reasoning = message.get_key_string("reasoning_content", allocator) ?? "";
	res.finish_reason = choice.get_key_string("finish_reason", allocator) ?? "";

	res.tool_calls = tool_calls_from_json(allocator, message.get_key("tool_calls"));

	CJsonItem* usage = root.get_key("usage");
	if (usage)
	{
		String parts = "";
		if (try prompt = usage.get_key_int("prompt_tokens"))
		{
			parts = string::tformat("prompt=%d", prompt);
		}
		if (try completion = usage.get_key_int("completion_tokens"))
		{
			parts = parts.tconcat(" completion=").tconcat(string::tformat("%d", completion));
		}
		if (try total = usage.get_key_int("total_tokens"))
		{
			parts = parts.tconcat(" total=").tconcat(string::tformat("%d", total));
		}
		if (parts.len) res.usage = parts.copy(allocator);
	}
	res.ok = true;
	return res;
}
