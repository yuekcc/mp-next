package main

import "core:crypto"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ---- 分节 ----
// RLM 引擎的唯一真相源：append-only 的步骤日志（Step），持久化为 jsonl。
//
// 目录与文件：<traj-dir>/<hex8>-<slug>/trajectory.jsonl
// 首行是头 {"type":"trajectory"}，其后每行一个 Step。整步一次 write、append 原子——
// 中断/报错后文件末尾永远是完整步骤。
//
// 大字段（超 SPILL_THRESHOLD 字节）spill 到同目录 blobs/，步骤里存 <field>_ref 而不是
// 原文；读取时按需取回。旧 .llmcli/sessions/<id>.jsonl 的 {ts,turn,message} 行在读取时
// 一次性映射为 prompt/reasoning/shell-output 步骤（不强制迁移）。

// ---- 常量 ----

TRAJ_HEADER_TYPE :: "trajectory"
TRAJ_FILE_NAME :: "trajectory.jsonl"
TRAJ_BLOBS_DIR :: "blobs"
TRAJ_DEFAULT_SLUG :: "run"

// 字段超过这个字节数就 spill 到 blob 文件。
SPILL_THRESHOLD :: 8192

// 步骤类型（与 shellm 对齐）。
T_PROMPT :: "prompt"
T_REASONING :: "reasoning"
T_SHELL_OUTPUT :: "shell-output"
T_FEEDBACK :: "feedback"
T_FINAL :: "final"
T_ERROR :: "error"
T_FORK :: "fork"
T_MERGE :: "merge"
T_SHELLM_RUN :: "shellm-run"
T_RUN_SUMMARY :: "run-summary"

// ---- 类型 ----

// 轨迹的一步。字段按 type 使用，未使用的留空；序列化时按 type 决定写哪些键。
Step :: struct {
	step_id: string,
	ts: string, // 本地时区 RFC3339，秒级；步骤发生时刻
	type: string,
	run_id: string, // 产生它的 run；空 = 当前轨迹的主 run

	content: string, // prompt / feedback / final / error / run-summary 的正文
	thought: string, // reasoning：渲染用的推理散文（进上下文）
	cmd: string, // reasoning：模型写回的代码原文
	// reasoning_content：只入存档、绝不回传端点，渲染不使用这个字段。
	reasoning_content: string,

	stdout: string, // shell-output：执行输出
	exit: int, // shell-output：退出码
	feedback: string, // shell-output：看门狗杀进程时的结构化反馈
	reason: string, // error：中止原因（stall 等）
	child: string, // fork：子轨迹 id（hex8）
	slug: string, // fork：子轨迹 slug
	from_traj: string, // merge：来源轨迹 id

	command: string, // shellm-run：触发本次 run 的输入
	workdir: string, // shellm-run：生成代码的工作目录
	model: string, // shellm-run：模型 id
	env: string, // shellm-run：传入生成代码的环境变量（k=v，空格分隔）
	max_iterations: int, // shellm-run：循环上限（0=不限）
}

// 一条轨迹：目录名 <hex8>-<slug>，文件 <root>/<name>/trajectory.jsonl。
Trajectory :: struct {
	root: string, // 轨迹根目录（--traj-dir / 默认）
	name: string, // 目录名 <hex8>-<slug>
	id: string, // hex8（首步 UUID 的前 8 位）
	path: string, // <root>/<name>/trajectory.jsonl
}

// ---- 轨迹根目录配置 ----
// 只由 cmd 层在解析参数后设置一次：存放位置只由命令行/配置决定，不读环境变量。
// thread_local：生产路径单线程设置并读取；单元测试并行跑时各线程互不干扰。
@(thread_local)
g_traj_dir: string // --traj-dir：直接作为根
@(thread_local)
g_config_dir: string // --config-dir：用来派生 <config-dir>/traj

traj_configure :: proc(traj_dir, config_dir: string) {
	g_traj_dir = traj_dir
	g_config_dir = config_dir
}

// 测试用：直接指定根目录。
traj_set_base_dir :: proc(dir: string) {
	g_traj_dir = dir
	g_config_dir = ""
}

// 默认轨迹根目录：--traj-dir > <config-dir>/traj > ~/.llmcli/traj。
traj_root_dir :: proc() -> string {
	if g_traj_dir != "" {
		return slashify(g_traj_dir)
	}
	if g_config_dir != "" {
		return fmt.aprintf("%s/traj", slashify(g_config_dir), allocator = context.temp_allocator)
	}
	home := os.user_home_dir(context.temp_allocator) or_else "."
	return fmt.aprintf("%s/.llmcli/traj", slashify(home), allocator = context.temp_allocator)
}

// ---- 打开/创建 ----

// 派生一个全新的轨迹：生成 UUID，目录名 <hex8>-<slug>，写头行。
traj_open_new :: proc(slug: string) -> Trajectory {
	t: Trajectory
	t.root = traj_root_dir()
	t.id = new_hex8()
	t.name = fmt.aprintf("%s-%s", t.id, sanitize_slug(slug), allocator = context.temp_allocator)
	t.path = fmt.aprintf("%s/%s/%s", t.root, t.name, TRAJ_FILE_NAME, allocator = context.temp_allocator)
	ensure_dirs(&t)
	write_header(&t)
	return t
}

// 续接/写入既有轨迹：name 是目录名（--traj <name>）；不存在则创建。
traj_open_resume :: proc(name: string) -> Trajectory {
	t: Trajectory
	t.root = traj_root_dir()
	t.name = name
	t.id = len(name) >= 8 ? name[:8] : name
	t.path = fmt.aprintf("%s/%s/%s", t.root, name, TRAJ_FILE_NAME, allocator = context.temp_allocator)
	existed := os.exists(t.path)
	ensure_dirs(&t)
	if !existed {
		write_header(&t)
	}
	return t
}

// 从父 run 的轨迹目录直接打开（子代理用它写 fork/merge）。
traj_open_at :: proc(root, name: string) -> Trajectory {
	t: Trajectory
	t.root = slashify(root)
	t.name = name
	t.id = len(name) >= 8 ? name[:8] : name
	t.path = fmt.aprintf("%s/%s/%s", t.root, name, TRAJ_FILE_NAME, allocator = context.temp_allocator)
	return t
}

// 生成一个 UUID 字符串（标准 8-4-4-4-12）。uuid.generate_v4 要求 CSPRNG，
// 而 odin test 的测试线程上下文只给非加密 RNG，会 assert 失败；这里显式装一个加密生成器。
crypto_uuid_string :: proc() -> string {
	context.random_generator = crypto.random_generator()
	return uuid.to_string_allocated(uuid.generate_v4(), context.temp_allocator) or_else ""
}

new_hex8 :: proc() -> string {
	full := crypto_uuid_string()
	if len(full) < 8 {
		return full
	}
	return full[:8]
}

// 一次 run 的 id：与轨迹 id 不同，同一轨迹续跑多次是多次 run。
traj_new_run_id :: proc() -> string {
	return new_hex8()
}

// traj 目录名直接当路径用，必须是安全的一段名字（挡掉路径穿越与非法字符）。
traj_valid_id :: proc(id: string) -> bool {
	if id == "" || id == "." || id == ".." {
		return false
	}
	if strings.contains(id, "..") {
		return false
	}
	for c in id {
		switch c {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|':
			return false
		}
	}
	return true
}

// slug 直接进目录名：挡掉路径分隔与非法字符，空则用默认。
sanitize_slug :: proc(slug: string) -> string {
	if slug == "" {
		return TRAJ_DEFAULT_SLUG
	}
	sb := strings.builder_make(context.temp_allocator)
	for c in slug {
		switch c {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', ' ':
			strings.write_byte(&sb, '_')
		case:
			_, _ = strings.write_rune(&sb, c)
		}
	}
	return strings.to_string(sb)
}

traj_string :: proc(traj: ^Trajectory, sub: string) -> string {
	return fmt.aprintf("%s/%s/%s", traj.root, traj.name, sub, allocator = context.temp_allocator)
}

ensure_dirs :: proc(traj: ^Trajectory) {
	dir := fmt.aprintf("%s/%s", traj.root, traj.name, allocator = context.temp_allocator)
	if !os.exists(dir) {
		_ = os.make_directory_all(dir)
	}
	blobs := traj_string(traj, TRAJ_BLOBS_DIR)
	if !os.exists(blobs) {
		_ = os.make_directory_all(blobs)
	}
}

write_header :: proc(traj: ^Trajectory) {
	f, err := os.open(traj.path, {.Append, .Create, .Write})
	if err != nil {
		log_warn("无法创建轨迹文件 %s：%v", traj.path, err)
		return
	}
	defer os.close(f)
	line := fmt.aprintf("{{\"type\":\"%s\"}}\n", TRAJ_HEADER_TYPE, allocator = context.temp_allocator)
	_, _ = os.write(f, transmute([]byte)line)
}

// ---- 追加 ----

// append-only：写入一步，返回它的 step_id。整步一次 write。
// 超过阈值的字段自动 spill 到 blobs/，步骤里存 <field>_ref。
traj_append :: proc(traj: ^Trajectory, step_in: Step) -> string {
	step := step_in
	if step.step_id == "" {
		step.step_id = crypto_uuid_string()
	}
	if step.ts == "" {
		step.ts = traj_timestamp()
	}

	obj := step_to_json(traj, &step)
	data, err := json.marshal(obj, json.Marshal_Options{spec = .JSON, sort_maps_by_key = true},
	                          context.temp_allocator)
	if err != nil {
		log_warn("轨迹步骤序列化失败：%v", err)
		return step.step_id
	}
	payload := fmt.aprintf("%s\n", string(data), allocator = context.temp_allocator)

	f, oerr := os.open(traj.path, {.Append, .Create, .Write})
	if oerr != nil {
		log_warn("无法写入轨迹 %s：%v", traj.path, oerr)
		return step.step_id
	}
	defer os.close(f)
	if _, werr := os.write(f, transmute([]byte)payload); werr != nil {
		log_warn("轨迹 %s 写入失败：%v", traj.name, werr)
	}
	return step.step_id
}

// 步骤发生的时刻（RFC3339，秒级）。
traj_timestamp :: proc() -> string {
	s, ok := time_to_rfc3339_seconds()
	if !ok {
		return ""
	}
	return s
}

// RFC3339 秒级时间戳。注：v1 用 UTC（offset 0）；本机无 tzdata 时取不到本地偏移，
// 形状与 C3 版一致（`2026-10-13T15:30:18Z`）。
time_to_rfc3339_seconds :: proc() -> (string, bool) {
	return time.time_to_rfc3339(time.now(), 0, false, context.temp_allocator)
}

// ---- 序列化 ----

step_to_json :: proc(traj: ^Trajectory, s: ^Step) -> json.Object {
	obj := make(json.Object, allocator = context.temp_allocator)
	obj["step_id"] = s.step_id
	obj["ts"] = s.ts
	obj["type"] = s.type
	if s.run_id != "" {
		obj["run_id"] = s.run_id
	}

	typ := s.type
	if typ == T_PROMPT || typ == T_FINAL || typ == T_FEEDBACK || typ == T_RUN_SUMMARY || typ == T_ERROR {
		put_text(&obj, traj, s.step_id, "content", s.content)
	}
	if typ == T_ERROR && s.reason != "" {
		obj["reason"] = s.reason
	}
	if typ == T_REASONING {
		put_text(&obj, traj, s.step_id, "thought", s.thought)
		put_text(&obj, traj, s.step_id, "cmd", s.cmd)
	}
	// reasoning_content 只入存档、绝不回传端点。
	if s.reasoning_content != "" {
		put_text(&obj, traj, s.step_id, "reasoning_content", s.reasoning_content)
	}
	if typ == T_SHELL_OUTPUT {
		put_text(&obj, traj, s.step_id, "stdout", s.stdout)
		obj["exit"] = i64(s.exit)
		if s.feedback != "" {
			put_text(&obj, traj, s.step_id, "feedback", s.feedback)
		}
	}
	if typ == T_FORK {
		obj["child"] = s.child
		if s.slug != "" {
			obj["slug"] = s.slug
		}
	}
	if typ == T_MERGE {
		obj["from_traj"] = s.from_traj
	}
	if typ == T_SHELLM_RUN {
		put_text(&obj, traj, s.step_id, "command", s.command)
		put_text(&obj, traj, s.step_id, "workdir", s.workdir)
		put_text(&obj, traj, s.step_id, "model", s.model)
		if s.env != "" {
			put_text(&obj, traj, s.step_id, "env", s.env)
		}
		obj["max_iterations"] = i64(s.max_iterations)
	}
	return obj
}

// 写一个文本字段：超过阈值就落 blob，键写成 <name>_ref + <name>_bytes。
put_text :: proc(obj: ^json.Object, traj: ^Trajectory, step_id, name, value: string) {
	if len(value) < SPILL_THRESHOLD {
		obj[name] = value
		return
	}
	blob_name := fmt.aprintf("%s-%s.blob", step_id, name, allocator = context.temp_allocator)
	blob_path := fmt.aprintf("%s/%s/%s/%s", traj.root, traj.name, TRAJ_BLOBS_DIR, blob_name,
	                         allocator = context.temp_allocator)
	if err := os.write_entire_file_from_string(blob_path, value); err != nil {
		log_warn("轨迹 blob 落盘失败（%s），字段内联：%v", blob_path, err)
		obj[name] = value
		return
	}
	obj[fmt.aprintf("%s_ref", name, allocator = context.temp_allocator)] = blob_name
	obj[fmt.aprintf("%s_bytes", name, allocator = context.temp_allocator)] = i64(len(value))
}

// ---- 读取 ----

// 读回全部步骤（含头行与 shellm-run）。旧格式行也在这里识别并映射。
traj_read_all :: proc(traj: ^Trajectory) -> [dynamic]Step {
	steps := make([dynamic]Step, 0, 32, context.temp_allocator)
	data, err := os.read_entire_file_from_path(traj.path, context.temp_allocator)
	if err != nil {
		return steps // 没有文件是正常的
	}
	lines := strings.split(string(data), "\n", context.temp_allocator)
	for line in lines {
		if line == "" {
			continue
		}
		v, perr := json.parse_string(line, .JSON, allocator = context.temp_allocator)
		if perr != nil {
			continue
		}
		obj, is_obj := v.(json.Object)
		if !is_obj {
			continue
		}
		typ := json_string(obj, "type")
		if typ == TRAJ_HEADER_TYPE {
			continue
		}
		if typ == "" {
			if _, has_message := obj["message"]; has_message {
				step_from_legacy(&steps, obj)
				continue
			}
		}
		append(&steps, step_from_json(traj, obj))
	}
	return steps
}

step_from_json :: proc(traj: ^Trajectory, obj: json.Object) -> Step {
	s: Step
	s.step_id = json_string(obj, "step_id")
	s.ts = json_string(obj, "ts")
	s.type = json_string(obj, "type")
	s.run_id = json_string(obj, "run_id")
	s.content = get_text(traj, obj, "content")
	s.thought = get_text(traj, obj, "thought")
	s.cmd = get_text(traj, obj, "cmd")
	s.reasoning_content = get_text(traj, obj, "reasoning_content")
	s.stdout = get_text(traj, obj, "stdout")
	s.feedback = get_text(traj, obj, "feedback")
	s.reason = json_string(obj, "reason")
	s.child = json_string(obj, "child")
	s.slug = json_string(obj, "slug")
	s.from_traj = json_string(obj, "from_traj")
	s.command = get_text(traj, obj, "command")
	s.workdir = get_text(traj, obj, "workdir")
	s.model = get_text(traj, obj, "model")
	s.env = get_text(traj, obj, "env")
	if v, ok := json_int(obj, "exit"); ok {
		s.exit = v
	}
	if v, ok := json_int(obj, "max_iterations"); ok {
		s.max_iterations = v
	}
	return s
}

// 读文本字段：优先 <name>_ref（blob），否则内联的 <name>。
get_text :: proc(traj: ^Trajectory, obj: json.Object, name: string) -> string {
	ref_key := fmt.aprintf("%s_ref", name, allocator = context.temp_allocator)
	blob_name := json_string(obj, ref_key)
	if blob_name != "" {
		blob_path := fmt.aprintf("%s/%s/%s/%s", traj.root, traj.name, TRAJ_BLOBS_DIR, blob_name,
		                         allocator = context.temp_allocator)
		data, err := os.read_entire_file_from_path(blob_path, context.temp_allocator)
		if err != nil {
			log_warn("轨迹 blob 读取失败 %s：%v", blob_path, err)
			return ""
		}
		return string(data)
	}
	return json_string(obj, name)
}

// 旧会话行 {ts,turn,message} → 步骤：assistant 映射为 reasoning；
// user 消息里，本轮的第一条（前面不是 assistant）当 prompt，其余当 shell-output。
step_from_legacy :: proc(steps: ^[dynamic]Step, obj: json.Object) {
	message, ok := obj["message"].(json.Object)
	if !ok {
		return
	}
	role := json_string(message, "role")
	s: Step
	s.step_id = crypto_uuid_string()
	s.ts = json_string(obj, "ts")
	if role == "assistant" {
		s.type = T_REASONING
		s.thought = json_string(message, "content")
		s.reasoning_content = json_string(message, "reasoning_content")
	} else {
		after_assistant := len(steps) > 0 && steps[len(steps) - 1].type == T_REASONING
		content := json_string(message, "content")
		if after_assistant {
			s.type = T_SHELL_OUTPUT
			s.stdout = content
		} else {
			s.type = T_PROMPT
			s.content = content
		}
	}
	append(steps, s)
}

// ---- 查询 ----

// 最后一步；空轨迹返回零值 Step（type 为空）。
traj_last :: proc(traj: ^Trajectory) -> Step {
	steps := traj_read_all(traj)
	if len(steps) == 0 {
		return {}
	}
	return steps[len(steps) - 1]
}

// 按 step_id 查找。
traj_find :: proc(traj: ^Trajectory, step_id: string) -> (step: Step, found: bool) {
	for s in traj_read_all(traj) {
		if s.step_id == step_id {
			return s, true
		}
	}
	return {}, false
}

// 子串搜索：匹配 thought / cmd / stdout / content 任一字段。
traj_search :: proc(traj: ^Trajectory, pattern: string) -> [dynamic]Step {
	hits := make([dynamic]Step, 0, 8, context.temp_allocator)
	for s in traj_read_all(traj) {
		if strings.contains(s.thought, pattern) || strings.contains(s.cmd, pattern) ||
		   strings.contains(s.stdout, pattern) || strings.contains(s.content, pattern) {
			append(&hits, s)
		}
	}
	return hits
}

// 末尾 n 步。
traj_tail :: proc(traj: ^Trajectory, n: int) -> [dynamic]Step {
	all := traj_read_all(traj)
	if n <= 0 || n >= len(all) {
		return all
	}
	out := make([dynamic]Step, 0, n, context.temp_allocator)
	for i in len(all) - n ..< len(all) {
		append(&out, all[i])
	}
	return out
}

// ---- DAG（fork / merge） ----

// 写 fork 步骤，返回子轨迹 id（新的 hex8）。
traj_fork :: proc(traj: ^Trajectory, slug: string) -> string {
	child := new_hex8()
	traj_append(traj, Step{type = T_FORK, child = child, slug = slug})
	return child
}

// 写 merge 步骤，引用来源（子）轨迹 id。
traj_merge :: proc(traj: ^Trajectory, child_id: string) {
	traj_append(traj, Step{type = T_MERGE, from_traj = child_id})
}

// ---- 列出 ----

TrajectorySummary :: struct {
	name: string,
	updated: string,
	count: int,
}

traj_list_all :: proc() -> [dynamic]TrajectorySummary {
	list := make([dynamic]TrajectorySummary, 0, 16, context.temp_allocator)
	root := traj_root_dir()
	if !os.exists(root) {
		return list
	}
	entries, derr := os.read_all_directory_by_path(root, context.temp_allocator)
	if derr != nil {
		return list
	}
	for entry in entries {
		if entry.type != .Directory {
			continue
		}
		summary := TrajectorySummary{name = entry.name, updated = "-"}
		traj := traj_open_at(root, entry.name)
		data, ferr := os.read_entire_file_from_path(traj.path, context.temp_allocator)
		if ferr != nil {
			continue
		}
		lines := strings.split(string(data), "\n", context.temp_allocator)
		// 头行不是步骤，用是否含 step_id 判定。
		for line in lines {
			if strings.contains(line, "\"step_id\"") {
				summary.count += 1
			}
		}
		// updated：最后一条非空行的 ts。
		for i := len(lines); i > 0; i -= 1 {
			line := lines[i - 1]
			if line == "" {
				continue
			}
			v, perr := json.parse_string(line, .JSON, allocator = context.temp_allocator)
			if perr == nil {
				if obj, ok := v.(json.Object); ok {
					if ts := json_string(obj, "ts"); ts != "" {
						summary.updated = ts
					}
				}
			}
			break
		}
		append(&list, summary)
	}
	return list
}
