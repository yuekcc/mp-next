module llmcli::config;

import std::io, std::os::env;
import std::collections::list;
import cjson;
import llmcli::log;

// ---- 分节 ----
// 持久配置文件 llmcli.json：定位 / 读取 / 解析成独立于 Ctx 的中间结构。
// 本模块只回答"文件里写了什么"，不做合并——把设置回填进 Ctx（默认 < 配置 < flag）由 cli 层负责。
// 解析复用 cjson；路径固定 <config-dir>/llmcli.json（config-dir 缺省 ~/.llmcli）。
//
// 排除的键（不是持久偏好，一律不认，出现即当未知键告警）：help / print_system_prompt /
// prompt / input_file / traj / config_dir / resume / quiet / no_config。

// ---- 常量 ----

const String FILE_NAME = "llmcli.json";
const String DEFAULT_DIR = ".llmcli";

// 已知键集合，用于识别"未知/多余键"。键名 = 同名 flag 去掉 -- 并把连字符换成下划线。
const String[] KNOWN_KEYS = {
	"api_key", "api_url", "model", "traj_dir", "workdir",
	"system_prompt", "system_prompt_file", "max_iterations", "context_scope", "max_bytes",
	"inactivity_timeout", "max_output_size", "max_exec_time", "var", "debug", "no_color",
};

// ---- 类型 ----

// var 对象的一项（string -> string）。
struct Var
{
	String name;
	String value;
}

// 从 llmcli.json 解析出的设置。h_<key> 表示该键在文件里出现且已过类型校验；
// false = 文件没写，不参与回填。与 Ctx 无关，是独立的中间结构。
struct Settings
{
	bool h_api_key; String api_key;
	bool h_api_url; String api_url;
	bool h_model; String model;
	bool h_traj_dir; String traj_dir;
	bool h_workdir; String workdir;
	bool h_system_prompt; String system_prompt;
	bool h_system_prompt_file; String system_prompt_file;
	bool h_max_iterations; int max_iterations;
	bool h_context_scope; String context_scope;
	bool h_max_bytes; int max_bytes;
	bool h_inactivity_timeout; int inactivity_timeout;
	bool h_max_output_size; int max_output_size;
	bool h_max_exec_time; int max_exec_time;
	bool h_var; Var[] vars;
	bool h_debug; bool debug;
	bool h_no_color; bool no_color;
}

// load 的结果：error 非空 = 硬错误（无法读取 / 语法错 / 顶层非对象 / 类型不符 / 来源互斥）。
struct LoadResult
{
	Settings settings;
	String error;
}

// ---- 定位 ----

// 配置文件路径：<config-dir>/llmcli.json；config-dir 空 = ~/.llmcli/llmcli.json。
// --traj-dir 不影响配置文件位置；文件里也不认 config_dir（避免自指）。
fn String path_for(String config_dir, Allocator allocator)
{
	if (config_dir.len) return string::format(allocator, "%s/%s", config_dir, FILE_NAME);
	String home = env::get_home_dir(allocator) ?? ".";
	return string::format(allocator, "%s/%s/%s", home, DEFAULT_DIR, FILE_NAME);
}

// ---- 读取 + 解析 ----

// 定位并解析配置文件。文件不存在 = 静默跳过（返回空 Settings、无 error）。
// 其余硬错误（读失败 / 语法错 / 类型不符 / 来源互斥）写进 error，调用方按退出码 2 处理。
fn LoadResult load(String config_dir)
{
	LoadResult res;
	String path = path_for(config_dir, tmem);
	if (!file::exists(path)) return res;

	char[]? data = file::load(tmem, path);
	if (catch err = data)
	{
		res.error = string::tformat("无法读取配置文件 %s（%s）", path, err);
		return res;
	}
	return parse_json((String)data, path);
}

fn LoadResult parse_json(String body, String path) @private
{
	LoadResult res;
	CJsonItem* root = cjson::parse_with_length((ZString)body.ptr, body.len);
	if (!root)
	{
		res.error = string::tformat("配置文件 %s 不是合法 JSON", path);
		return res;
	}
	defer root.free();

	if (!root.is_object())
	{
		res.error = string::tformat("配置文件 %s 顶层必须是 JSON 对象", path);
		return res;
	}

	foreach (key : root.keys(tmem))
	{
		if (!is_known_key(key)) log::warn("配置文件 %s 含未知键 %s，已忽略", path, key);
	}

	Settings* s = &res.settings;
	if (!take_string(root, "api_key", path, &s.h_api_key, &s.api_key, &res.error)) return res;
	if (!take_string(root, "api_url", path, &s.h_api_url, &s.api_url, &res.error)) return res;
	if (!take_string(root, "model", path, &s.h_model, &s.model, &res.error)) return res;
	if (!take_string(root, "traj_dir", path, &s.h_traj_dir, &s.traj_dir, &res.error)) return res;
	if (!take_string(root, "workdir", path, &s.h_workdir, &s.workdir, &res.error)) return res;
	if (!take_string(root, "system_prompt", path, &s.h_system_prompt, &s.system_prompt, &res.error)) return res;
	if (!take_string(root, "system_prompt_file", path, &s.h_system_prompt_file,
	                 &s.system_prompt_file, &res.error)) return res;

	if (!take_int(root, "max_iterations", path, &s.h_max_iterations, &s.max_iterations, &res.error)) return res;
	if (!take_int(root, "max_bytes", path, &s.h_max_bytes, &s.max_bytes, &res.error)) return res;
	if (!take_int(root, "inactivity_timeout", path, &s.h_inactivity_timeout,
	              &s.inactivity_timeout, &res.error)) return res;
	if (!take_int(root, "max_output_size", path, &s.h_max_output_size, &s.max_output_size, &res.error)) return res;
	if (!take_int(root, "max_exec_time", path, &s.h_max_exec_time, &s.max_exec_time, &res.error)) return res;

	// context_scope 只接受 traj / run：与同名 flag 的校验口径一致。
	if (!take_string(root, "context_scope", path, &s.h_context_scope, &s.context_scope, &res.error)) return res;
	if (s.h_context_scope && s.context_scope != "traj" && s.context_scope != "run")
	{
		res.error = string::tformat("配置文件 %s 的 context_scope 只能是 traj 或 run，收到 %s",
		                            path, s.context_scope);
		return res;
	}

	if (!take_bool(root, "debug", path, &s.h_debug, &s.debug, &res.error)) return res;
	if (!take_bool(root, "no_color", path, &s.h_no_color, &s.no_color, &res.error)) return res;

	if (!take_vars(root, path, s, &res.error)) return res;

	// 配置里 system_prompt 与 system_prompt_file 也互斥（沿用 flag 层的口径）。
	if (s.h_system_prompt && s.h_system_prompt_file)
	{
		res.error = string::tformat("配置文件 %s 的 system_prompt 与 system_prompt_file 互斥", path);
		return res;
	}
	return res;
}

// ---- 取值（缺失 = no-op；类型不符 = 设 error 返回 false） ----

fn bool take_string(CJsonItem* root, String key, String path,
                    bool* has, String* out, String* error) @private
{
	CJsonItem* item = root.get_key(key);
	if (!item) return true;
	if (!item.is_string())
	{
		*error = string::tformat("配置文件 %s 的 %s 必须是字符串", path, key);
		return false;
	}
	*has = true;
	*out = item.get_string(tmem);
	return true;
}

fn bool take_int(CJsonItem* root, String key, String path,
                 bool* has, int* out, String* error) @private
{
	CJsonItem* item = root.get_key(key);
	if (!item) return true;
	if (!item.is_number())
	{
		*error = string::tformat("配置文件 %s 的 %s 必须是整数", path, key);
		return false;
	}
	// JSON 数字都是 double：20.5 这类非整数也判类型不符，不能静默截断成 20。
	double d = cjson::get_number_value(item);
	if (d != (double)(int)d)
	{
		*error = string::tformat("配置文件 %s 的 %s 必须是整数", path, key);
		return false;
	}
	*has = true;
	*out = (int)d;
	return true;
}

fn bool take_bool(CJsonItem* root, String key, String path,
                  bool* has, bool* out, String* error) @private
{
	CJsonItem* item = root.get_key(key);
	if (!item) return true;
	bool? value = item.get_bool();
	if (catch exc = value)
	{
		*error = string::tformat("配置文件 %s 的 %s 必须是布尔值", path, key);
		return false;
	}
	*has = true;
	*out = value;
	return true;
}

// var 是 string -> string 的对象；逐项拷贝到 tmem（随调用方 @pool 回收）。
fn bool take_vars(CJsonItem* root, String path, Settings* s, String* error) @private
{
	CJsonItem* item = root.get_key("var");
	if (!item) return true;
	if (!item.is_object())
	{
		*error = string::tformat("配置文件 %s 的 var 必须是对象", path);
		return false;
	}
	s.h_var = true;
	List{Var} vars;
	vars.init(tmem);
	for (CJsonItem* child = item.child; child; child = child.next)
	{
		if (!child.is_string())
		{
			*error = string::tformat("配置文件 %s 的 var 值必须是字符串", path);
			return false;
		}
		vars.push({ .name = string::format(tmem, "%s", (ZString)child.string),
		            .value = child.get_string(tmem) });
	}
	s.vars = vars.to_array(tmem);
	return true;
}

fn bool is_known_key(String key) @private
{
	foreach (k : KNOWN_KEYS)
	{
		if (k == key) return true;
	}
	return false;
}
