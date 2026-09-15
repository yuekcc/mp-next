module llmcli::session;

import std::io, std::os::env, std::time::datetime;
import std::collections::list;
import cjson;
import llmcli::buf, llmcli::chat, llmcli::log;

const String HOME_ENV = "LLMCLI_HOME";
const String SUFFIX = ".jsonl";

// 会话根目录：LLMCLI_HOME 优先，否则 ~/.llmcli（Windows 为 %USERPROFILE%\.llmcli）
fn String root_dir(Allocator allocator)
{
	String home = env::get_home_dir(tmem) ?? ".";
	if (try custom = env::get_var(tmem, HOME_ENV)) home = custom;
	return string::format(allocator, "%s/.llmcli", home);
}

fn String sessions_dir(Allocator allocator) => string::format(allocator, "%s/sessions", root_dir(allocator));

// session-id 会直接当文件名用，必须是安全的一段名字（挡掉路径穿越与非法字符）
fn bool valid_id(String id)
{
	if (!id.len || id == "." || id == "..") return false;
	if (id.contains("..")) return false;
	foreach (c : id)
	{
		if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?') return false;
		if (c == '"' || c == '<' || c == '>' || c == '|') return false;
	}
	return true;
}

struct Session
{
	String id;
	String path;
}

fn Session open(String id)
{
	Session session;
	session.id = id;
	// 路径字符串是 scratch，用 tmem；会话 id 与文件内容才是长期数据
	session.path = string::format(tmem, "%s/%s%s", sessions_dir(tmem), id, SUFFIX);
	return session;
}

// 读历史；坏行跳过并告警，不中断本次运行。
fn Message[] load(Allocator allocator, Session* session)
{
	List{Message} list;
	list.init(allocator);

	char[]? data = file::load(allocator, session.path);
	if (catch err = data) return list.to_array(allocator); // 没有历史文件是正常的

	String[] lines = ((String)data).split(tmem, "\n", 0, true);
	usz broken = 0;
	foreach (line : lines)
	{
		CJsonItem* root = cjson::parse_with_length((ZString)line.ptr, line.len);
		if (!root)
		{
			broken++;
			continue;
		}
		CJsonItem* message = root.get_key("message");
		if (!message)
		{
			broken++;
			root.free();
			continue;
		}
		list.push(chat::message_from_json(allocator, message));
		root.free();
	}
	if (broken) log::warn("会话 %s 有 %d 行无法解析，已跳过", session.id, broken);

	Message[] messages = list.to_array(allocator);
	list.free();
	return messages;
}

// 一次 Trace 的全部消息一次性追加。整块一次 write，避免并发写下多行交错。
// ponytail: 依赖 OS 的 append 语义保证单次写原子；跨机器共享目录场景没覆盖。
fn void append(Session* session, usz turn, Message[] messages)
{
	if (!messages.len) return;

	String stamp = datetime::now().to_local().format(tmem, DateTimeFormat.RFC3339Z);
	DString payload = dstring::new(mem);
	defer payload.free();

	foreach (message : messages)
	{
		CJsonItem* record = cjson::create_object();
		record.set("ts", stamp);
		record.set("turn", (int)turn);
		record.set_item("message", chat::message_to_json(&message, true));
		ZString line = cjson::print_unformatted(record);
		payload.append_string(buf::cstr(tmem, line));
		payload.append_bytes("\n");
		cjson::free(line);
		record.free();
	}

	String dir = sessions_dir(tmem);
	if (!path::exists((Path)dir)) (void)path::mkdir((Path)dir, true);

	File? file = file::open(session.path, "ab");
	if (catch err = file)
	{
		log::warn("无法写入会话文件 %s：%s", session.path, err);
		return;
	}
	defer (void)file.close();
	if (catch err = file.write(payload.str_view()))
	{
		log::warn("会话 %s 写入失败：%s", session.id, err);
		return;
	}
	(void)file.flush();
}

// 会话文件一行一条记录；解析失败返回 null（调用方决定跳过还是告警）。
fn CJsonItem* parse_record(String line) @private
{
	return cjson::parse_with_length((ZString)line.ptr, line.len);
}

struct SessionSummary
{
	String id;
	String updated;
	usz count;
}

fn SessionSummary[] list_all(Allocator allocator)
{
	List{SessionSummary} list;
	list.init(allocator);

	String dir = sessions_dir(tmem);
	if (!path::exists((Path)dir)) return list.to_array(allocator);

	PathList? listed = path::ls(allocator, (Path)dir, true, true, "*" +++ SUFFIX);
	if (catch err = listed)
	{
		log::warn("无法列出会话目录 %s：%s", dir, err);
		return list.to_array(allocator);
	}

	foreach (entry : listed)
	{
		String name = ((String)entry).file_basename(tmem) ?? "";
		if (!name.ends_with(SUFFIX)) continue;
		String id = name[:name.len - SUFFIX.len].copy(allocator);

		SessionSummary summary = { .id = id, .updated = "-", .count = 0 };
		char[]? data = file::load(allocator, string::format(tmem, "%s/%s", dir, name));
		if (catch err = data)
		{
			list.push(summary);
			continue;
		}
		String[] lines = ((String)data).split(tmem, "\n", 0, true);
		foreach (line : lines)
		{
			CJsonItem* root = cjson::parse_with_length((ZString)line.ptr, line.len);
			if (!root) continue;
			if (try stamp = root.get_key_string("ts", allocator)) summary.updated = stamp;
			summary.count++;
			root.free();
		}
		list.push(summary);
	}

	SessionSummary[] result = list.to_array(allocator);
	list.free();
	return result;
}
