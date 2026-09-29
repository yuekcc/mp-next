module llmcli::session;

import std::io, std::os::env, std::time::datetime;
import std::collections::list;
import cjson;
import llmcli::buf, llmcli::chat, llmcli::log;

const String SUFFIX = ".jsonl";

// --config-dir 指定的配置目录，也就是会话根目录；空串 = 用默认 ~/.llmcli。
// 只由 cmd 层在解析参数后设置一次，指向 argv 或常量内存（活到进程结束）。
String config_dir @private;

fn void set_config_dir(String dir)
{
	config_dir = dir;
}

// 会话根目录：--config-dir 优先，未指定则 ~/.llmcli（Windows 为 %USERPROFILE%\.llmcli）。
// 不读环境变量：存放位置只由命令行决定。
fn String root_dir(Allocator allocator)
{
	if (config_dir.len) return config_dir;
	String home = env::get_home_dir(tmem) ?? ".";
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

// 会话文件的一行：一条消息 + 它所属的 turn + 它发生的时刻。
// user 消息是触发本次 Trace 的输入，属 turn 1；assistant/tool 属产生它的那一轮请求。
struct Record
{
	Message message;
	usz turn;
	String ts;   // 消息发生的时刻（timestamp() 的产物），不是落盘那一刻
}

// 消息发生的时刻，格式就是记录里的 ts（本地时区 RFC3339，秒级）。
// 在消息产生时取一次写进 Record，落盘时原样写入。
fn String timestamp(Allocator allocator)
{
	return datetime::now().to_local().format(allocator, DateTimeFormat.RFC3339Z);
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

// 追加一批记录：调用方按 turn 攒齐后调用，一次 write 写完一整轮。
// 整块一次 write，既避免并发写下多行交错，也不会留下半截 turn（assistant 的 tool_calls
// 与它的 tool 结果同批写入）。
// turn 与 ts 都随每条记录传进来（消息产生时就记下），不整批共用一个值：同一次 Trace 里
// 用户输入、工具回填、最终答案分属不同轮、不同时刻，共用一个值会把归属全写成最后一轮、
// 把时间全写成落盘那一刻。
// ponytail: 依赖 OS 的 append 语义保证单次写原子；跨机器共享目录场景没覆盖。
fn void append(Session* session, Record[] records)
{
	if (!records.len) return;

	DString payload = dstring::new(mem);
	defer payload.free();

	foreach (record : records)
	{
		CJsonItem* item = cjson::create_object();
		item.set("ts", record.ts);
		item.set("turn", (int)record.turn);
		item.set_item("message", chat::message_to_archive_json(&record.message));
		ZString line = cjson::print_unformatted(item);
		payload.append_string(buf::cstr(tmem, line));
		payload.append_bytes("\n");
		cjson::free(line);
		item.free();
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
		// ponytail: 元数据只看非空行：逐行数数、只解析最后一条非空行取 ts，不再全量 JSON 解析。
		// 代价：手工掺入的非空坏行也会计入 count（append 写出的记录都是合法 JSON）。
		foreach (line : lines)
		{
			if (line.len) summary.count++;
		}
		for (usz i = lines.len; i > 0; i--)
		{
			if (!lines[i - 1].len) continue;
			CJsonItem* root = cjson::parse_with_length((ZString)lines[i - 1].ptr, lines[i - 1].len);
			if (root)
			{
				if (try stamp = root.get_key_string("ts", allocator)) summary.updated = stamp;
				root.free();
			}
			break;
		}
		list.push(summary);
	}

	SessionSummary[] result = list.to_array(allocator);
	list.free();
	return result;
}
