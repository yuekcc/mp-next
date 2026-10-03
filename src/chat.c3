module llmcli::chat;

import cjson;
import std::collections::list;

// 会话里的一条消息。RLM 循环只有 user / assistant 两种角色：模型的回复是 assistant，
// 执行输出作为下一条 user 消息回填（shellm 的 shell-output 语义）。
struct Message
{
	String role;      // system / user / assistant
	String content;
	String reasoning; // reasoning_content 原文；空串表示没有
}

struct ChatResponse
{
	bool ok;
	String error;
	String content;
	String reasoning;
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
	obj.set("content", msg.content);
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
	return msg;
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
