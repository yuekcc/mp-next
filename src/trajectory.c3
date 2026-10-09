module llmcli::trajectory;

import std::io, std::io::path, std::math::uuid, std::os::env, std::time::datetime;
import std::collections::list;
import cjson;
import llmcli::buf, llmcli::log;

// ---- 分节 ----
// 本模块是 RLM 引擎的唯一真相源：append-only 的步骤日志（Step），持久化为 jsonl。
// 取代旧 session.c3 的「每 turn 一次写」模型；每轮 messages 由 context.c3 从这里重渲染。
//
// 目录与文件（doc 8）：
//   <traj-dir>/<hex8>-<slug>/trajectory.jsonl
// 首行是头 {"type":"trajectory"}，其后每行一个 Step。整步一次 write、append 原子——
// 中断/报错后文件末尾永远是完整步骤。
//
// 大字段（超 SPILL_THRESHOLD 字节）spill 到同目录 blobs/，步骤里存 <field>_ref 而不是
// 原文；读取时按需取回。旧 .llmcli/sessions/<id>.jsonl 的 {ts,turn,message} 行在读取时
// 一次性映射为 prompt/reasoning/shell-output 步骤（不强制迁移）。

// ---- 常量 ----

const String HEADER_TYPE = "trajectory";
const String FILE_NAME = "trajectory.jsonl";
const String BLOBS_DIR = "blobs";
const String DEFAULT_SLUG = "run";

// 字段超过这个字节数就 spill 到 blob 文件（对应 shellm 的 blob 机制）
const usz SPILL_THRESHOLD = 8192;

// 步骤类型（与 shellm 对齐，见 doc 4.1）
const String T_PROMPT = "prompt";
const String T_REASONING = "reasoning";
const String T_SHELL_OUTPUT = "shell-output";
const String T_FEEDBACK = "feedback";
const String T_FINAL = "final";
const String T_ERROR = "error";
const String T_FORK = "fork";
const String T_MERGE = "merge";
const String T_SHELLM_RUN = "shellm-run";
const String T_RUN_SUMMARY = "run-summary";

// ---- 类型 ----

// 轨迹的一步。字段按 type 使用，未使用的留空；序列化时按 type 决定写哪些键，
// 所以「空串」对相关字段是合法值（如 FINAL=""），不需要额外的 presence 位。
struct Step
{
	String step_id;   // UUID
	String ts;        // 本地时区 RFC3339，秒级；步骤发生时刻
	String type;      // 见上面 T_* 常量
	String run_id;    // 产生它的 run；空 = 当前轨迹的主 run

	String content;   // prompt / feedback / final / error / run-summary 的正文
	String thought;   // reasoning：渲染用的推理散文（进上下文）
	String cmd;       // reasoning：模型写回的代码原文
	// reasoning_content（DeepSeek 等返回的思维链）：只入存档、绝不回传端点，
	// 所以渲染（context.c3）不使用这个字段。为空表示模型没返回。
	String reasoning_content;

	String stdout;    // shell-output：执行输出
	int exit;         // shell-output：退出码
	String feedback;  // shell-output：看门狗杀进程时的结构化反馈
	String reason;    // error：中止原因（stall 等）
	String child;     // fork：子轨迹 id（hex8）
	String slug;      // fork：子轨迹 slug
	String from_traj; // merge：来源轨迹 id

	String command;      // shellm-run：触发本次 run 的输入
	String workdir;      // shellm-run：生成代码的工作目录
	String model;        // shellm-run：模型 id
	String env;          // shellm-run：传入生成代码的环境变量（k=v，空格分隔）
	int max_iterations;  // shellm-run：循环上限（0=不限）
}

// 一条轨迹：目录名 <hex8>-<slug>，文件 <root>/<name>/trajectory.jsonl。
struct Trajectory
{
	String root;  // 轨迹根目录（--traj-dir / 默认）
	String name;  // 目录名 <hex8>-<slug>
	String id;    // hex8（首步 UUID 的前 8 位）
	String path;  // <root>/<name>/trajectory.jsonl
}

// 轨迹根目录来源。只由 cmd 层在解析参数后设置一次（沿用 session 的约定：
// 存放位置只由命令行决定，不读环境变量）。
String traj_dir_opt @private;    // --traj-dir：直接作为根
String config_dir_opt @private;  // --config-dir：根为 <config-dir>/traj

fn void configure(String traj_dir, String config_dir)
{
	traj_dir_opt = traj_dir;
	config_dir_opt = config_dir;
}

// 默认轨迹根目录：--traj-dir > <config-dir>/traj > ~/.llmcli/traj。
fn String root_dir(Allocator allocator)
{
	if (traj_dir_opt.len) return traj_dir_opt;
	if (config_dir_opt.len) return string::format(allocator, "%s/traj", config_dir_opt);
	String home = env::get_home_dir(tmem) ?? ".";
	return string::format(allocator, "%s/.llmcli/traj", home);
}

// 测试用：直接指定根目录。
fn void set_base_dir(String dir)
{
	traj_dir_opt = dir;
	config_dir_opt = "";
}

// ---- 打开/创建 ----

// 派生一个全新的轨迹：生成 UUID，目录名 <hex8>-<slug>，写头行。
fn Trajectory open_new(String slug)
{
	Trajectory traj;
	traj.root = root_dir(tmem);
	traj.id = new_hex8(tmem);
	traj.name = string::format(tmem, "%s-%s", traj.id, sanitize_slug(slug));
	traj.path = string::format(tmem, "%s/%s/%s", traj.root, traj.name, FILE_NAME);
	ensure_dirs(&traj);
	write_header(&traj);
	return traj;
}

// 续接/写入既有轨迹：name 是目录名（--traj <name>）；不存在则创建。
fn Trajectory open_resume(String name)
{
	Trajectory traj;
	traj.root = root_dir(tmem);
	traj.name = name;
	traj.id = name.len >= 8 ? name[:8] : name;
	traj.path = string::format(tmem, "%s/%s/%s", traj.root, name, FILE_NAME);
	bool existed = path::exists((Path)traj.path);
	ensure_dirs(&traj);
	if (!existed) write_header(&traj);
	return traj;
}

// 从父 run 的轨迹目录直接打开（子 run 用它写 fork/merge）。
fn Trajectory open_at(String root, String name)
{
	Trajectory traj;
	traj.root = root;
	traj.name = name;
	traj.id = name.len >= 8 ? name[:8] : name;
	traj.path = string::format(tmem, "%s/%s/%s", root, name, FILE_NAME);
	return traj;
}

fn String new_hex8(Allocator allocator) @private
{
	Uuid id = uuid::generate();
	String full = id.to_string(tmem);
	return full[:8].copy(allocator);
}

// 一次 run 的 id（doc 4.1：run_id 用于 run 作用域渲染）。
// 与轨迹 id 不同：同一轨迹续跑多次是多次 run。返回 mem 堆串，调用方负责释放。
fn String new_run_id(Allocator allocator) => new_hex8(allocator);

// traj 目录名直接当路径用，必须是安全的一段名字（挡掉路径穿越与非法字符）
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

// slug 直接进目录名：挡掉路径分隔与非法字符，空则用默认。
fn String sanitize_slug(String slug) @private
{
	if (!slug.len) return DEFAULT_SLUG;
	DString out = dstring::new(tmem);
	foreach (c : slug)
	{
		if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"'
		    || c == '<' || c == '>' || c == '|' || c == ' ')
		{
			out.append_char('_');
		}
		else
		{
			out.append_char(c);
		}
	}
	return out.tcopy_str();
}

fn void ensure_dirs(Trajectory* traj) @private
{
	String dir = string::format(tmem, "%s/%s", traj.root, traj.name);
	if (!path::exists((Path)dir)) (void)path::mkdir((Path)dir, true);
	String blobs = string::format(tmem, "%s/%s", dir, BLOBS_DIR);
	if (!path::exists((Path)blobs)) (void)path::mkdir((Path)blobs, true);
}

fn void write_header(Trajectory* traj) @private
{
	File? file = file::open(traj.path, "ab");
	if (catch err = file)
	{
		log::warn("无法创建轨迹文件 %s：%s", traj.path, err);
		return;
	}
	defer (void)file.close();
	(void)file.write(string::tformat("{\"type\":\"%s\"}\n", HEADER_TYPE));
	(void)file.flush();
}

// ---- 追加 ----

// append-only：写入一步，返回它的 step_id。整步一次 write。
// 超过阈值的字段自动 spill 到 blobs/，步骤里存 <field>_ref。
fn String append(Trajectory* traj, Step step)
{
	// 生成字段走 tmem：随调用方的 @pool 回收，避免逐 append 泄漏（返回的 step_id 仅在
	// 当前 pool 内有效，调用方需要长期持有请自行 copy）。
	if (!step.step_id.len) step.step_id = uuid::generate().to_string(tmem);
	if (!step.ts.len) step.ts = timestamp(tmem);

	CJsonItem* obj = step_to_json(traj, &step);
	ZString line = cjson::print_unformatted(obj);
	String payload = buf::cstr(tmem, line);
	cjson::free(line);
	obj.free();

	File? file = file::open(traj.path, "ab");
	if (catch err = file)
	{
		log::warn("无法写入轨迹 %s：%s", traj.path, err);
		return step.step_id;
	}
	defer (void)file.close();
	if (catch err = file.write(payload.tconcat("\n")))
	{
		log::warn("轨迹 %s 写入失败：%s", traj.name, err);
		return step.step_id;
	}
	(void)file.flush();
	return step.step_id;
}

// 步骤发生的时刻（本地时区 RFC3339，秒级）。
fn String timestamp(Allocator allocator)
{
	return datetime::now().to_local().format(allocator, DateTimeFormat.RFC3339Z);
}

// ---- 序列化 ----

fn CJsonItem* step_to_json(Trajectory* traj, Step* s) @private
{
	CJsonItem* obj = cjson::create_object();
	obj.set("step_id", s.step_id);
	obj.set("ts", s.ts);
	obj.set("type", s.type);
	if (s.run_id.len) obj.set("run_id", s.run_id);

	String type = s.type;
	if (type == T_PROMPT || type == T_FINAL || type == T_FEEDBACK || type == T_RUN_SUMMARY
	    || type == T_ERROR)
	{
		put_text(obj, traj, s.step_id, "content", s.content);
	}
	if (type == T_ERROR && s.reason.len) obj.set("reason", s.reason);
	if (type == T_REASONING)
	{
		put_text(obj, traj, s.step_id, "thought", s.thought);
		put_text(obj, traj, s.step_id, "cmd", s.cmd);
	}
	// reasoning_content 只入存档、绝不回传端点：context 渲染时不读它（不限于 reasoning 步骤）。
	if (s.reasoning_content.len) put_text(obj, traj, s.step_id, "reasoning_content", s.reasoning_content);
	if (type == T_SHELL_OUTPUT)
	{
		put_text(obj, traj, s.step_id, "stdout", s.stdout);
		obj.set("exit", s.exit);
		if (s.feedback.len) put_text(obj, traj, s.step_id, "feedback", s.feedback);
	}
	if (type == T_FORK)
	{
		obj.set("child", s.child);
		if (s.slug.len) obj.set("slug", s.slug);
	}
	if (type == T_MERGE) obj.set("from_traj", s.from_traj);
	if (type == T_SHELLM_RUN)
	{
		put_text(obj, traj, s.step_id, "command", s.command);
		put_text(obj, traj, s.step_id, "workdir", s.workdir);
		put_text(obj, traj, s.step_id, "model", s.model);
		if (s.env.len) put_text(obj, traj, s.step_id, "env", s.env);
		obj.set("max_iterations", s.max_iterations);
	}
	return obj;
}

// 写一个文本字段：超过阈值就落 blob，键写成 <name>_ref + <name>_bytes。
fn void put_text(CJsonItem* obj, Trajectory* traj, String step_id, String name, String value) @private
{
	if (value.len < SPILL_THRESHOLD)
	{
		obj.set(name, value);
		return;
	}
	String blob_name = string::format(tmem, "%s-%s.blob", step_id, name);
	String blob_path = string::format(tmem, "%s/%s/%s/%s", traj.root, traj.name, BLOBS_DIR, blob_name);
	if (catch err = file::save(blob_path, value))
	{
		log::warn("轨迹 blob 落盘失败（%s），字段内联：%s", blob_path, err);
		obj.set(name, value);
		return;
	}
	obj.set(string::tformat("%s_ref", name), blob_name);
	obj.set(string::tformat("%s_bytes", name), (int)value.len);
}

// ---- 读取 ----

// 读回全部步骤（含头行与 shellm-run）。
// 旧格式（{ts,turn,message}）行也在这里识别并映射为 prompt/reasoning/shell-output。
fn Step[] read_all(Allocator allocator, Trajectory* traj)
{
	List{Step} list;
	list.init(allocator);
	char[]? data = file::load(allocator, traj.path);
	if (catch err = data) return list.to_array(allocator); // 没有文件是正常的

	String[] lines = ((String)data).split(tmem, "\n", 0, true);
	foreach (line : lines)
	{
		if (!line.len) continue;
		CJsonItem* root = cjson::parse_with_length((ZString)line.ptr, line.len);
		if (!root) continue;
		String type = root.get_key_string("type", tmem) ?? "";
		if (type == HEADER_TYPE)
		{
			root.free();
			continue;
		}
		if (!type.len && root.has_key("message"))
		{
			step_from_legacy(allocator, &list, root);
			root.free();
			continue;
		}
		list.push(step_from_json(allocator, traj, root));
		root.free();
	}
	return list.to_array(allocator);
}

// 最后一步；空轨迹返回一个空 Step（type 为空）。
fn Step last(Allocator allocator, Trajectory* traj)
{
	Step empty;
	Step[] steps = read_all(allocator, traj);
	if (!steps.len) return empty;
	return steps[steps.len - 1];
}

// 按 step_id 查找；找到返回 true 并写入 out。
fn bool find(Allocator allocator, Trajectory* traj, String step_id, Step* out)
{
	Step[] steps = read_all(allocator, traj);
	foreach (s : steps)
	{
		if (s.step_id == step_id)
		{
			*out = s;
			return true;
		}
	}
	return false;
}

// 子串搜索：匹配 thought / cmd / stdout / content 任一字段。
fn Step[] search(Allocator allocator, Trajectory* traj, String pattern)
{
	List{Step} hits;
	hits.init(allocator);
	foreach (s : read_all(tmem, traj))
	{
		if (s.thought.contains(pattern) || s.cmd.contains(pattern)
		    || s.stdout.contains(pattern) || s.content.contains(pattern))
		{
			hits.push(copy_step(allocator, &s));
		}
	}
	return hits.to_array(allocator);
}

// 末尾 n 步。
fn Step[] tail(Allocator allocator, Trajectory* traj, int n)
{
	Step[] all = read_all(allocator, traj);
	if (n <= 0 || (usz)n >= all.len) return all;
	usz start = all.len - (usz)n;
	List{Step} out;
	out.init(allocator);
	for (usz i = start; i < all.len; i++) out.push(all[i]);
	return out.to_array(allocator);
}

fn Step copy_step(Allocator allocator, Step* s) @private
{
	Step out = *s;
	out.step_id = s.step_id.copy(allocator);
	out.ts = s.ts.copy(allocator);
	out.type = s.type.copy(allocator);
	out.run_id = s.run_id.copy(allocator);
	out.content = s.content.copy(allocator);
	out.thought = s.thought.copy(allocator);
	out.cmd = s.cmd.copy(allocator);
	out.reasoning_content = s.reasoning_content.copy(allocator);
	out.stdout = s.stdout.copy(allocator);
	out.feedback = s.feedback.copy(allocator);
	out.reason = s.reason.copy(allocator);
	out.child = s.child.copy(allocator);
	out.slug = s.slug.copy(allocator);
	out.from_traj = s.from_traj.copy(allocator);
	out.command = s.command.copy(allocator);
	out.workdir = s.workdir.copy(allocator);
	out.model = s.model.copy(allocator);
	out.env = s.env.copy(allocator);
	return out;
}

fn Step step_from_json(Allocator allocator, Trajectory* traj, CJsonItem* root) @private
{
	Step s;
	s.step_id = root.get_key_string("step_id", allocator) ?? "";
	s.ts = root.get_key_string("ts", allocator) ?? "";
	s.type = root.get_key_string("type", allocator) ?? "";
	s.run_id = root.get_key_string("run_id", allocator) ?? "";
	s.content = get_text(allocator, traj, root, "content");
	s.thought = get_text(allocator, traj, root, "thought");
	s.cmd = get_text(allocator, traj, root, "cmd");
	s.reasoning_content = get_text(allocator, traj, root, "reasoning_content");
	s.stdout = get_text(allocator, traj, root, "stdout");
	s.feedback = get_text(allocator, traj, root, "feedback");
	s.reason = root.get_key_string("reason", allocator) ?? "";
	s.child = root.get_key_string("child", allocator) ?? "";
	s.slug = root.get_key_string("slug", allocator) ?? "";
	s.from_traj = root.get_key_string("from_traj", allocator) ?? "";
	s.command = get_text(allocator, traj, root, "command");
	s.workdir = get_text(allocator, traj, root, "workdir");
	s.model = get_text(allocator, traj, root, "model");
	s.env = get_text(allocator, traj, root, "env");
	if (try exit_code = root.get_key_int("exit")) s.exit = exit_code;
	if (try max_iter = root.get_key_int("max_iterations")) s.max_iterations = max_iter;
	return s;
}

// 读文本字段：优先 <name>_ref（blob），否则内联的 <name>。
fn String get_text(Allocator allocator, Trajectory* traj, CJsonItem* root, String name) @private
{
	String key = string::tformat("%s_ref", name);
	String blob_name = root.get_key_string(key, tmem) ?? "";
	if (blob_name.len)
	{
		String blob_path = string::format(tmem, "%s/%s/%s/%s", traj.root, traj.name, BLOBS_DIR, blob_name);
		char[]? data = file::load(allocator, blob_path);
		if (catch err = data)
		{
			log::warn("轨迹 blob 读取失败 %s：%s", blob_path, err);
			return "";
		}
		return (String)data;
	}
	return root.get_key_string(name, allocator) ?? "";
}

// 旧会话行 {ts,turn,message} → 步骤：assistant 映射为 reasoning；
// user 消息里，本轮的第一条（前面不是 assistant）当 prompt，其余（执行输出回填）当 shell-output。
// 旧格式没有 type 语义，这是按 RLM 结构的近似映射。
fn void step_from_legacy(Allocator allocator, List{Step}* list, CJsonItem* root) @private
{
	CJsonItem* message = root.get_key("message");
	if (!message) return;
	String role = message.get_key_string("role", tmem) ?? "";
	Step s;
	s.step_id = uuid::generate().to_string(allocator);
	s.ts = root.get_key_string("ts", allocator) ?? "";
	if (role == "assistant")
	{
		s.type = T_REASONING;
		s.thought = message.get_key_string("content", allocator) ?? "";
		String reasoning = message.get_key_string("reasoning_content", allocator) ?? "";
		s.reasoning_content = reasoning;
	}
	else
	{
		bool after_assistant = list.len() > 0 && list.get((sz)list.len() - 1).type == T_REASONING;
		String content = message.get_key_string("content", allocator) ?? "";
		if (after_assistant)
		{
			s.type = T_SHELL_OUTPUT;
			s.stdout = content;
		}
		else
		{
			s.type = T_PROMPT;
			s.content = content;
		}
	}
	list.push(s);
}

// ---- DAG（fork / merge） ----

// 写 fork 步骤，返回子轨迹 id（新的 hex8）。
// 返回串在 tmem 上，仅当前 pool 内有效（调用方要跨 pool 持有请自行 copy）。
fn String fork(Trajectory* traj, String slug)
{
	String child = new_hex8(tmem);
	Step s = { .type = T_FORK, .child = child, .slug = slug };
	(void)append(traj, s);
	return child;
}

// 写 merge 步骤，引用来源（子）轨迹 id。
fn void merge(Trajectory* traj, String child_id)
{
	Step s = { .type = T_MERGE, .from_traj = child_id };
	(void)append(traj, s);
}

// ---- 列出 ----

struct TrajectorySummary
{
	String name;
	String updated;
	usz count;
}

fn TrajectorySummary[] list_all(Allocator allocator)
{
	List{TrajectorySummary} list;
	list.init(allocator);
	String root = root_dir(tmem);
	if (!path::exists((Path)root)) return list.to_array(allocator);

	PathList? listed = path::ls(tmem, (Path)root);
	if (catch err = listed) return list.to_array(allocator);

	foreach (entry : listed)
	{
		Path dir = ((Path)root).tappend(entry)!!;
		if (!path::is_dir(dir)) continue;
		Trajectory traj = open_at(root, (String)entry);
		char[]? data = file::load(allocator, traj.path);
		if (catch err = data) continue;
		String[] lines = ((String)data).split(tmem, "\n", 0, true);
		TrajectorySummary summary = { .name = (String)entry, .updated = "-", .count = 0 };
		// 元数据只看非空行；头行不是步骤，用是否含 step_id 判定。
		foreach (line : lines)
		{
			if (line.len && line.contains("\"step_id\"")) summary.count++;
		}
		for (usz i = lines.len; i > 0; i--)
		{
			if (!lines[i - 1].len) continue;
			CJsonItem* root_item = cjson::parse_with_length((ZString)lines[i - 1].ptr, lines[i - 1].len);
			if (root_item)
			{
				if (try stamp = root_item.get_key_string("ts", allocator)) summary.updated = stamp;
				root_item.free();
			}
			break;
		}
		list.push(summary);
	}
	return list.to_array(allocator);
}
