# 新增一个工具

`llmcli` 内置 Bash 与 EditFile 两个工具。工具经 `src/tools.c3` 里的注册表接入，**agent loop
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

## 照抄示例：加一个 `read_file` 工具

在 `src/tools.c3` 里加一个实现函数：

```c3
fn ToolResult tool_read_file(CJsonItem* args)
{
	String path = args.get_key_string("path", tmem) ?? "";
	if (!path.len) return fail("缺少必填参数 path（字符串）");

	char[]? loaded = file::load(tmem, path);
	if (catch err = loaded) return fail(string::tformat("无法读取 %s：%s", path, err));

	return ok(string::tformat("已读取 %s（%d 字节）：\n%s", path, loaded.len, (String)loaded));
}
```

再在 `register_builtin_tools()` 里注册：

```c3
	register_tool({
		.name = "read_file",
		.description = "读取一个文本文件并返回内容。",
		.parameters = `{"type":"object","properties":{"path":{"type":"string","description":"文件路径"}},"required":["path"]}`,
		.execute = &tool_read_file,
	});
```

编译即可用：

```bash
c3c build
llmcli --model ... --api-key ... "读一下 README.md 的开头"
```

## 注意

- `parameters` 必须是合法 JSON Schema；解析失败时该工具的参数会被跳过（LLM 仍能调用，只是没有参数约束）。
- 工具注册表是固定 32 槽（`MAX_TOOLS`），超了会告警并忽略。
- 单个工具内部要读写的临时字符串用 `tmem`，只有返回给调用方的 `content` 走 `ok`/`fail`（mem）。
- 一次工具调用失败不是致命错误：把原因写进 `content` 并设 `is_error = true`，agent 会原样回填给
  LLM 继续下一 turn（PRD T3.8）。
- 想验证新工具，把 `test/tools_test.c3` 里的用例复制一份改改即可；`c3c test` 会检查内存泄漏，
  记得用 `release(&result)` 释放返回值。
