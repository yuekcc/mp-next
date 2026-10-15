package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

// ---- 分节 ----
// 持久配置文件 llmcli.json：定位 / 读取 / 解析成独立于 Ctx 的中间结构。
// 本模块只回答"文件里写了什么"，不做合并——把设置回填进 Ctx（默认 < 配置 < flag）由 cli 层负责。
// 路径固定 <config-dir>/llmcli.json（config-dir 缺省 ~/.llmcli）。
//
// 排除的键（不是持久偏好，一律不认，出现即当未知键告警）：help / print_system_prompt /
// prompt / input_file / traj / config_dir / resume / quiet / no_config。

// ---- 常量 ----

CONFIG_FILE_NAME :: "llmcli.json"
CONFIG_DEFAULT_DIR :: ".llmcli"

// 已知键集合，用于识别"未知/多余键"。键名 = 同名 flag 去掉 -- 并把连字符换成下划线。
config_known_keys := [?]string{
	"api_key", "api_url", "model", "traj_dir", "workdir",
	"system_prompt", "system_prompt_file", "max_iterations", "context_scope", "max_bytes",
	"inactivity_timeout", "max_output_size", "max_exec_time", "var", "debug", "no_color", "stream",
}

// ---- 类型 ----

// var 对象的一项（string -> string）。
ConfigVar :: struct {
	name:  string,
	value: string,
}

// 从 llmcli.json 解析出的设置。h_<key> 表示该键在文件里出现且已过类型校验；
// false = 文件没写，不参与回填。与 Ctx 无关，是独立的中间结构。
ConfigSettings :: struct {
	h_api_key:            bool,
	api_key:              string,
	h_api_url:            bool,
	api_url:              string,
	h_model:              bool,
	model:                string,
	h_traj_dir:           bool,
	traj_dir:             string,
	h_workdir:            bool,
	workdir:              string,
	h_system_prompt:      bool,
	system_prompt:        string,
	h_system_prompt_file: bool,
	system_prompt_file:   string,
	h_max_iterations:     bool,
	max_iterations:       int,
	h_context_scope:      bool,
	context_scope:        string,
	h_max_bytes:          bool,
	max_bytes:            int,
	h_inactivity_timeout: bool,
	inactivity_timeout:   int,
	h_max_output_size:    bool,
	max_output_size:      int,
	h_max_exec_time:      bool,
	max_exec_time:        int,
	h_var:                bool,
	vars:                 []ConfigVar,
	h_debug:              bool,
	debug:                bool,
	h_no_color:           bool,
	no_color:             bool,
	h_stream:             bool,
	stream:               bool,
}

// load 的结果：error 非空 = 硬错误（无法读取 / 语法错 / 顶层非对象 / 类型不符 / 来源互斥）。
ConfigLoadResult :: struct {
	settings: ConfigSettings,
	error:    string,
}

// ---- 定位 ----

// 配置文件路径：<config-dir>/llmcli.json；config-dir 空 = ~/.llmcli/llmcli.json。
// --traj-dir 不影响配置文件位置；文件里也不认 config_dir（避免自指）。
config_path_for :: proc(config_dir: string) -> string {
	if config_dir != "" {
		return fmt.aprintf("%s/%s", slashify(config_dir), CONFIG_FILE_NAME,
		                   allocator = context.temp_allocator)
	}
	home := os.user_home_dir(context.temp_allocator) or_else "."
	return fmt.aprintf("%s/%s/%s", slashify(home), CONFIG_DEFAULT_DIR, CONFIG_FILE_NAME,
	                   allocator = context.temp_allocator)
}

// ---- 读取 + 解析 ----

// 定位并解析配置文件。文件不存在 = 静默跳过（返回空 Settings、无 error）。
// 其余硬错误写进 error，调用方按退出码 2 处理。
config_load :: proc(config_dir: string) -> ConfigLoadResult {
	res: ConfigLoadResult
	path := config_path_for(config_dir)
	if !os.exists(path) {
		return res
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		res.error = fmt.aprintf("无法读取配置文件 %s（%v）", path, err, allocator = context.temp_allocator)
		return res
	}
	return config_parse(string(data), path)
}

config_parse :: proc(body, path: string) -> ConfigLoadResult {
	res: ConfigLoadResult
	v, err := json.parse_string(body, .JSON, allocator = context.temp_allocator)
	if err != nil {
		res.error = fmt.aprintf("配置文件 %s 不是合法 JSON", path, allocator = context.temp_allocator)
		return res
	}
	root, is_obj := v.(json.Object)
	if !is_obj {
		res.error = fmt.aprintf("配置文件 %s 顶层必须是 JSON 对象", path, allocator = context.temp_allocator)
		return res
	}

	for key, _ in root {
		if !config_is_known_key(key) {
			log_warn("配置文件 %s 含未知键 %s，已忽略", path, key)
		}
	}

	s := &res.settings
	if !config_take_string(root, "api_key", path, &s.h_api_key, &s.api_key, &res.error) { return res }
	if !config_take_string(root, "api_url", path, &s.h_api_url, &s.api_url, &res.error) { return res }
	if !config_take_string(root, "model", path, &s.h_model, &s.model, &res.error) { return res }
	if !config_take_string(root, "traj_dir", path, &s.h_traj_dir, &s.traj_dir, &res.error) { return res }
	if !config_take_string(root, "workdir", path, &s.h_workdir, &s.workdir, &res.error) { return res }
	if !config_take_string(root, "system_prompt", path, &s.h_system_prompt, &s.system_prompt, &res.error) { return res }
	if !config_take_string(root, "system_prompt_file", path, &s.h_system_prompt_file,
	                       &s.system_prompt_file, &res.error) { return res }

	if !config_take_int(root, "max_iterations", path, &s.h_max_iterations, &s.max_iterations, &res.error) { return res }
	if !config_take_int(root, "max_bytes", path, &s.h_max_bytes, &s.max_bytes, &res.error) { return res }
	if !config_take_int(root, "inactivity_timeout", path, &s.h_inactivity_timeout,
	                    &s.inactivity_timeout, &res.error) { return res }
	if !config_take_int(root, "max_output_size", path, &s.h_max_output_size, &s.max_output_size, &res.error) { return res }
	if !config_take_int(root, "max_exec_time", path, &s.h_max_exec_time, &s.max_exec_time, &res.error) { return res }

	// context_scope 只接受 traj / run：与同名 flag 的校验口径一致。
	if !config_take_string(root, "context_scope", path, &s.h_context_scope, &s.context_scope, &res.error) { return res }
	if s.h_context_scope && s.context_scope != "traj" && s.context_scope != "run" {
		res.error = fmt.aprintf("配置文件 %s 的 context_scope 只能是 traj 或 run，收到 %s",
		                        path, s.context_scope, allocator = context.temp_allocator)
		return res
	}

	if !config_take_bool(root, "debug", path, &s.h_debug, &s.debug, &res.error) { return res }
	if !config_take_bool(root, "no_color", path, &s.h_no_color, &s.no_color, &res.error) { return res }
	if !config_take_bool(root, "stream", path, &s.h_stream, &s.stream, &res.error) { return res }

	if !config_take_vars(root, path, s, &res.error) { return res }

	// 配置里 system_prompt 与 system_prompt_file 也互斥（沿用 flag 层的口径）。
	if s.h_system_prompt && s.h_system_prompt_file {
		res.error = fmt.aprintf("配置文件 %s 的 system_prompt 与 system_prompt_file 互斥", path,
		                        allocator = context.temp_allocator)
		return res
	}
	return res
}

// ---- 取值（缺失 = no-op；类型不符 = 设 error 返回 false） ----

config_take_string :: proc(root: json.Object, key, path: string,
                           has: ^bool, out: ^string, error: ^string) -> bool {
	v, present := root[key]
	if !present {
		return true
	}
	s, ok := v.(json.String)
	if !ok {
		error^ = fmt.aprintf("配置文件 %s 的 %s 必须是字符串", path, key,
		                     allocator = context.temp_allocator)
		return false
	}
	has^ = true
	out^ = string(s)
	return true
}

config_take_int :: proc(root: json.Object, key, path: string,
                        has: ^bool, out: ^int, error: ^string) -> bool {
	v, present := root[key]
	if !present {
		return true
	}
	// JSON 数字：整数解析为 Float（parse_integers=false）；20.5 这类非整数也判类型不符。
	value: f64
	#partial switch n in v {
	case json.Integer:
		value = f64(n)
	case json.Float:
		value = f64(n)
	case:
		error^ = fmt.aprintf("配置文件 %s 的 %s 必须是整数", path, key,
		                     allocator = context.temp_allocator)
		return false
	}
	if value != f64(i64(value)) {
		error^ = fmt.aprintf("配置文件 %s 的 %s 必须是整数", path, key,
		                     allocator = context.temp_allocator)
		return false
	}
	has^ = true
	out^ = int(value)
	return true
}

config_take_bool :: proc(root: json.Object, key, path: string,
                         has: ^bool, out: ^bool, error: ^string) -> bool {
	v, present := root[key]
	if !present {
		return true
	}
	b, ok := v.(json.Boolean)
	if !ok {
		error^ = fmt.aprintf("配置文件 %s 的 %s 必须是布尔值", path, key,
		                     allocator = context.temp_allocator)
		return false
	}
	has^ = true
	out^ = bool(b)
	return true
}

// var 是 string -> string 的对象；逐项拷贝到 context.temp_allocator。
config_take_vars :: proc(root: json.Object, path: string,
                         s: ^ConfigSettings, error: ^string) -> bool {
	v, present := root["var"]
	if !present {
		return true
	}
	obj, ok := v.(json.Object)
	if !ok {
		error^ = fmt.aprintf("配置文件 %s 的 var 必须是对象", path, allocator = context.temp_allocator)
		return false
	}
	s.h_var = true
	vars := make([dynamic]ConfigVar, 0, len(obj), context.temp_allocator)
	for name, value in obj {
		str, is_str := value.(json.String)
		if !is_str {
			error^ = fmt.aprintf("配置文件 %s 的 var 值必须是字符串", path,
			                     allocator = context.temp_allocator)
			return false
		}
		append(&vars, ConfigVar{name = name, value = string(str)})
	}
	s.vars = vars[:]
	return true
}

config_is_known_key :: proc(key: string) -> bool {
	for k in config_known_keys {
		if k == key {
			return true
		}
	}
	return false
}

// 供 cli 层复用：把配置里的 var 项拼成 "NAME=VALUE"。
config_var_assignment :: proc(v: ConfigVar) -> string {
	return fmt.aprintf("%s=%s", v.name, v.value, allocator = context.temp_allocator)
}
