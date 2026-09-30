# 新增一个工具

`llmcli` 内置 Bash、EditFile、ReadFile、WriteFile、ListDir 五个工具。工具源码在 `src/tools/`（一个工具一个文件），
工具定义在 `src/tool_schemas/*.json`，经 `src/tools/tools.c3` 里的注册表接入，**agent loop
不需要任何改动**：注册表里有什么，LLM 就看得见什么。

## 工具定义：一个工具一个自包含 JSON

每个工具的**名字、用途说明、参数 schema** 都在同一个文件里，那是它的单一事实源。
c3 侧只负责把定义绑到实现上。`src/tool_schemas/bash.json`：

```json
{
  "name": "bash",
  "description": "- Executes a system command in a controlled environment\n- Runs the command synchronously and returns stdout/stderr and the exit code\n- Use this tool when you need to run shell commands, build scripts or run tests",
  "parameters": {
    "type": "object",
    "properties": {
      "command": { "type": "string", "description": "The exact bash command to execute." }
    },
    "required": ["command"]
  }
}
```

`description` 与 `parameters` 分别是 OpenAI tools 协议里的 `function.description`（**字符串**，
多行用 `\n`）和 `function.parameters`（JSON Schema 对象），字段类型查
`docs/references/chat-completion-api.md`。写法沿用上层工具的格式：一行一条 `- `，
最后一条是 "Use this tool when…"。

## 工具接口

```c3
struct ToolResult
{
	String content;   // 回填给 LLM 的文本；必须是 mem 上的堆串，调用方负责释放
	bool is_error;    // true 表示这次调用失败（错误文本照样回填，让 LLM 自我修正）
}

alias ToolFn = fn ToolResult(Ctx* ctx, CJsonItem* args);

struct Tool
{
	String name;         // LLM 看到的函数名
	String description;  // 给 LLM 看的用途说明
	String parameters;   // 参数 JSON Schema 原文（由 register_from_schema 从定义里取出）
	ToolFn execute;
}
```

调用方（agent）保证：

- `args` 一定是个 JSON 对象（参数非法时不会进到 `execute`，而是直接回填错误文本）；
- `ctx` 是**本次运行的配置**（`llmcli::cli::Ctx`：`model` / `api_url` / `session_id` / `max_turns` …），
  由 `run_tool` 原样透传。工具想按本次运行调模型（比如 subagent），从这里拿参数，
  不要去够全局——一次运行一个 `Ctx`，全局对象没有服务对象；
- 你返回的 `content` 由调用方释放，所以**必须**用 `ok(...)` / `fail(...)` 构造
  （它们会 `copy(mem)` 一份），不要把指向 `tmem` 或字符串常量的切片直接塞进去。

## 照抄示例：加一个 `grep` 工具

假设要新增一个在文件里搜关键字的 `grep` 工具。新建 `src/tools/grep.c3`（一个工具一个文件）加实现函数：

```c3
import std::io::file;   // file::load 在这个模块里

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

它不关心本次运行的配置，就在 `src/tools/tools.c3` 里再写一行适配器：注册表要的是带 `ctx` 的
`ToolFn`，而实现只想要 `args`，这一层就是把多出来的那个参数丢掉。这样实现函数保持原样，
将来真要用 `ctx` 的工具再把签名写全，互不影响。

```c3
fn ToolResult run_grep(Ctx* ctx, CJsonItem* args) @private => tool_grep(args);
```

要用 `ctx` 的话就别绕这一层，直接把 `ToolFn` 的签名写全：

```c3
fn ToolResult tool_recall(Ctx* ctx, CJsonItem* args)
{
	// 例如按本次运行的配置去读历史；参数照旧从 args 取
	String session_id = ctx.session_id;
	...
	return ok(...);
}
```

（`Ctx` 在本模块里就是 `llmcli::tools` 所在的同一个 `llmcli` 包，不用额外限定；
`ctx` 只读，别往里写东西。）

再新建 `src/tool_schemas/grep.json` 放工具定义（注意 `description` 是**字符串**，多行用 `\n`；
`parameters` 是 JSON Schema 子对象）：

```json
{
  "name": "grep",
  "description": "- Searches for lines matching a pattern in a file\n- Use this tool when you need to find text without reading the whole file",
  "parameters": {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "The path to the file to search." },
      "pattern": { "type": "string", "description": "The substring to search for." }
    },
    "required": ["path", "pattern"]
  }
}
```

在 `register_builtin_tools()` 里加一行绑定（定义文件由 `$embed` 编译期嵌入，路径相对源文件，
`src/tools/` 下的文件要用 `../tool_schemas/...`；`content` 必须用 `ok`/`fail` 构造）：

```c3
	register_from_schema(&run_grep, $embed("../tool_schemas/grep.json"));
```

编译即可用：

```bash
c3c build
llmcli --model ... --api-key ... "在 src/cli.c3 里搜 parse"
```

已有的五个工具的定义都在 `src/tool_schemas/`，注册方式可直接参考源码。

## 注意

- 定义文件是工具的单一事实源：`name` / `description` / `parameters` 三件套缺一不可（`name` 缺失会拒绝注册）。
  `register_from_schema` 在启动时解析定义，任何一处坏了都会**告警并拒绝注册**，而不是让一个
  没有参数约束的工具悄悄上线——所以定义写错时，`c3c test` 里
  `test_builtin_tool_schemas_are_valid_json` 会直接红（它断言注册表里正好 5 个工具且形状完整）。
- 工具在 `tools.c3` 的 `@init` 里注册一次（先于 `main`，也先于 `c3c test` 的用例）。
  注册会把定义里的字符串留在注册表里，注册表活到进程结束——放在 `@init` 是为了让
  `c3c test` 的泄漏检测不把这些"有意长存"的分配算成某个用例的残留。**别把注册挪进用例**。
- 工具注册表是固定 32 槽（`MAX_TOOLS`），超了会告警并忽略。
- `ctx` 是只读约定：工具想按本次运行换行为，就照它读参数，**不要**改它——
  `Ctx` 的一份配置服务一整次运行（C3 没有 const 成员约束，只能靠这条约定）。
- 单个工具内部要读写的临时字符串用 `tmem`，只有返回给调用方的 `content` 走 `ok`/`fail`（mem）。
- 一次工具调用失败不是致命错误：把原因写进 `content` 并设 `is_error = true`，agent 会原样回填给
  LLM 继续下一 turn（PRD T3.8）。
- 想验证新工具，把 `test/tools_test.c3` 里的用例复制一份改改即可；`c3c test` 会检查内存泄漏，
  记得用 `release(&result)` 释放返回值。
