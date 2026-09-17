# 新增一个工具

`llmcli` 内置 Bash、EditFile、ReadFile、WriteFile、ListDir 五个工具。工具经 `src/tools.c3` 里的注册表接入，**agent loop
不需要任何改动**：注册表里有什么，LLM 就看得见什么。

## 工具接口

```c3
struct ToolResult
{
	String content;   // 回填给 LLM 的文本；必须是 mem 上的堆串，调用方负责释放
	bool is_error;    // true 表示这次调用失败（错误文本照样回填，让 LLM 自我修正）
}

alias ToolFn = fn ToolResult(CJsonItem* args);   // args 是已解析好的参数 JSON 对象

struct Tool
{
	String name;         // LLM 看到的函数名
	String description;  // 给 LLM 看的用途说明
	String parameters;   // 参数 JSON Schema 原文
	ToolFn execute;
}
```

调用方（agent）保证：

- `args` 一定是个 JSON 对象（参数非法时不会进到 `execute`，而是直接回填错误文本）；
- 你返回的 `content` 由调用方释放，所以**必须**用 `ok(...)` / `fail(...)` 构造
  （它们会 `copy(mem)` 一份），不要把指向 `tmem` 或字符串常量的切片直接塞进去。

## 照抄示例：加一个 `grep` 工具

假设要新增一个在文件里搜关键字的 `grep` 工具。在 `src/tools.c3` 里加一个实现函数：

```c3
fn ToolResult tool_grep(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	String pattern = args.get_key_string("pattern", tmem) ?? "";
	if (!path.len) return fail("缺少必填参数 path（字符串）");
	if (!pattern.len) return fail("缺少必填参数 pattern（字符串）");

	char[]? loaded = file::load(tmem, path);
	if (catch err = loaded) return fail(string::tformat("无法读取 %s：%s", path, err));

	DString buf = dstring::new(tmem);
	usz n = 0;
	foreach (line : ((String)loaded).split(tmem, "\n"))
	{
		if (line.contains(pattern)) { buf.appendf("%s\n", line); n++; }
	}
	return ok(string::tformat("在 %s 中命中 %d 行：\n%s", path, n, buf.str_view()));
}
```

再在 `register_builtin_tools()` 里注册（注意 `parameters` 是合法 JSON Schema，`content` 必须用 `ok`/`fail` 构造）：

```c3
	register_tool({
		.name = "grep",
		.description = "在文件里搜索包含指定模式的行。",
		.parameters = `{"type":"object","properties":{` +++
			`"path":{"type":"string","description":"文件路径"},` +++
			`"pattern":{"type":"string","description":"要搜索的子串"}},` +++
			`"required":["path","pattern"]}`,
		.execute = &tool_grep,
	});
```

编译即可用：

```bash
c3c build
llmcli --model ... --api-key ... "在 src/cli.c3 里搜 parse"
```

已有的 `read_file` / `write_file` / `list_dir` 也是按这个套路注册的，可直接参考源码。

## 注意

- `parameters` 必须是合法 JSON Schema；解析失败时该工具的参数会被跳过（LLM 仍能调用，只是没有参数约束）。
- 工具注册表是固定 32 槽（`MAX_TOOLS`），超了会告警并忽略。
- 单个工具内部要读写的临时字符串用 `tmem`，只有返回给调用方的 `content` 走 `ok`/`fail`（mem）。
- 一次工具调用失败不是致命错误：把原因写进 `content` 并设 `is_error = true`，agent 会原样回填给
  LLM 继续下一 turn（PRD T3.8）。
- 想验证新工具，把 `test/tools_test.c3` 里的用例复制一份改改即可；`c3c test` 会检查内存泄漏，
  记得用 `release(&result)` 释放返回值。
