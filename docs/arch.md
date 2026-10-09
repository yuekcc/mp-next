# llmcli 架构设计

本文是 llmcli 的软件架构设计文档，用于指导人与 AI 理解、维护、扩展本仓库。它描述**代码实际
是什么样**：模块边界、运行时数据流、关键接口、内存模型与设计取舍。用法与参数见
[README.md](../README.md) 与 `llmcli --help`；会话文件格式见 [sessions.md](sessions.md)；CI 集成见
[ci.md](ci.md)；端点协议字段见 [references/chat-completion-api.md](references/chat-completion-api.md)。

> 阅读顺序建议：先读「1. 系统定位」，再读「2. 架构总览」与「3. 一次 Trace 的生命周期」建立整体
> 图景，然后按需进入「4. 模块设计」。改代码前请连同「5. 设计决策与硬约束」一起看。

---

## 1. 系统定位

llmcli 是一个**单二进制命令行工具**，把 LLM 接进 shell 流水线。核心特征：

- **OpenAI chat completions 兼容**：非流式（`stream:false`）POST `/v1/chat/completions`。
- **shellm 式 RLM agent loop**：一次运行 = 一条 **Trace**。模型回复中包含 ```` ```python ```` 代码块，
  本地用 Python 3 执行，把输出作为下一条 `user` 消息回填，循环直到代码里设置 `FINAL` /
  `FINAL_FILE`，或回复里不再有代码块。
- **Python 是唯一的工具**：不使用 OpenAI `tools` 协议，请求体不带 `tools` 字段。文件读写、构建、
  查询全部由模型写 Python 完成。
- **严格的 stdout/stderr 分离**：stdout 只出最终答案，所有过程日志走 stderr。
- **可控、可脚本化、可审计**：非交互、稳定退出码、每轮生成代码原文打印到 stderr。

实现语言为 [C3](https://c3-lang.org/)，依赖 `lib/curl.c3l`（libcurl 绑定）与 `lib/cjson.c3l`（JSON）。
`project.json` 定义可执行目标 `llmcli`（源 `src/**` + `cmd/llmcli.c3`）与测试源 `test/**`。

---

## 2. 架构总览

### 2.1 分层与依赖

代码是单向依赖的有向无环图，无环、无全局可变业务状态（日志/信号的少量全局是受控例外）：

```mermaid
graph TD
  MAIN["cmd/llmcli.c3<br/>main：分发"]
  CLI["src/cli.c3<br/>解析 / Ctx / 提示词装配"]
  AGENT["src/agent.c3<br/>Trace 主循环"]
  CHAT["src/chat.c3<br/>消息与请求/响应序列化"]
  HTTP["src/http.c3<br/>libcurl 封装"]
  RT["src/runtime.c3<br/>Python 子进程执行"]
  SESS["src/session.c3<br/>会话落盘/读回"]
  SKILL["src/skill.c3<br/>技能发现与注入"]
  WINJOB["src/winjob.c3<br/>Windows Job Object"]
  LOG["src/log.c3<br/>stderr 分级日志 + 脱敏"]
  BUF["src/buf.c3<br/>C 串转换 / UTF-8 截断"]

  MAIN --> CLI
  MAIN --> AGENT
  MAIN --> SESS
  MAIN --> SKILL
  MAIN --> LOG
  MAIN --> HTTP
  MAIN --> RT

  AGENT --> CHAT
  AGENT --> HTTP
  AGENT --> RT
  AGENT --> SESS
  AGENT --> CLI
  AGENT --> LOG

  CLI --> SESS
  CLI --> SKILL

  SESS --> CHAT
  SESS --> LOG

  RT --> WINJOB
  RT --> LOG

  HTTP --> BUF
  CHAT --> BUF
  SESS --> BUF
  AGENT --> BUF

  style MAIN fill:#eef
  style AGENT fill:#fee
```

- **`cmd` 层**只做编排：解析 → 初始化日志/信号 → 分发到各动作或 Trace。不含业务逻辑。
- **骨干链路**：`main → agent → {chat, http, runtime, session}`。
- **侧翼**：`cli`（配置与提示词装配）、`log`、`buf`、`skill` 被多处复用；`skill` 由 `cli` 在装配
  系统提示词时调用，**不参与 Trace 循环**。
- `agent` 依赖 `cli` 只为读 `Ctx` 与退出码常量；`session` 不反向依赖 `agent`/`cli`，保证无环。

### 2.2 模块职责一览

| 文件 | 职责 | 关键接口 |
|------|------|----------|
| `cmd/llmcli.c3` | `main`：resolve → 初始化 → 分发 help / 用法错误 / list-sessions / list-skills / print-system-prompt / run | `main` |
| `src/cli.c3` | `Ctx`、`parse`（纯解析）、`resolve`（补 I/O）、`assemble_system_prompt`、`HELP`、退出码常量 | `resolve`, `parse` |
| `src/agent.c3` | Trace 全部：主循环、`extract_code`、`chat_once`、逐 turn 落盘 | `run`, `extract_code` |
| `src/chat.c3` | `Message`/`ChatResponse` 类型、请求体组装、响应解析、两种消息序列化 | `build_request`, `parse_response` |
| `src/http.c3` | libcurl 生命周期与非流式 POST | `http_init`, `http_post_json` |
| `src/runtime.c3` | 生成代码执行：定位 Python、写临时脚本、捕获 `FINAL`、合并/截断输出、中断处理 | `run_python`, `install_interrupt_handler` |
| `src/session.c3` | 会话路径、校验 id、逐 turn 追加、读回、列会话 | `open`, `append`, `load`, `list_all` |
| `src/skill.c3` | 技能发现（`~/.agents/skills` 与 `<cwd>/.agents/skills`）与两种列表组装 | `SkillHub.init/print_installed/print_brief` |
| `src/log.c3` | stderr 四级日志、密钥自动脱敏、仅在 stderr 为 tty 时上色 | `init`, `add_secret`, `info/warn/error/debug` |
| `src/winjob.c3` | Windows Job Object：中断时连孙进程一起杀 | `create_and_assign`, `terminate` |
| `src/buf.c3` | 共享小工具：C 串 → String、按 UTF-8 边界截断 | `cstr`, `truncate` |
| `src/system_prompt.md` | 内置默认系统提示词，`$embed` 编译期嵌入 | — |

---

## 3. 一次 Trace 的生命周期

### 3.1 控制流

`main`（`cmd/llmcli.c3`）的编排顺序：

1. `cli::resolve(args)`——解析 argv 并补齐运行输入（读文件 / 读 stdin）。
2. `session::set_config_dir(ctx.config_dir)`——会话根目录只解析一次，写入 `session` 模块的私有全局。
3. `log::init(quiet, debug, no_color)`、`log::add_secret(api_key)`——脱敏在此一次性注册。
4. **动作开关短路**（不碰网络）：`--help` → 打印 `HELP`；有 `parsed.error` → 打印用法到 stderr、
   退出码 2；`--list-sessions` / `--list-skills` / `--print-system-prompt` → 各自处理并返回。
5. `runtime::install_interrupt_handler()` → `http::http_init()` → `agent::run(&ctx)`（真实 Trace）。
6. `defer http::http_deinit()` 收尾。

### 3.2 Trace 循环状态机

`agent::run(ctx)` 是整套 RLM 逻辑的唯一入口。循环体内的状态：

- `messages`：送端点的消息数组。起始为 `[system?] + 历史（若续话）+ 本次 user 输入`。
- `pending`：**本 turn 待落盘的记录**缓冲，攒齐后整轮一次写。
- `turn`：从 1 开始的请求计数（与 stderr 的 `[turn N]` 一致）。

```mermaid
stateDiagram-v2
  [*] --> 请求
  请求 --> 失败: 网络/HTTP/解析错误
  请求 --> 空响应: content 为空
  请求 --> 取码: 拿到 content
  取码 --> 收尾: 无代码块（整段回复即答案）
  取码 --> 执行: 有代码块
  执行 --> 落盘: 输出回填为下一条 user
  落盘 --> 请求: 未设 FINAL
  落盘 --> 收尾: 设了 FINAL / FINAL_FILE
  收尾 --> [*]: stdout 答案，退出码 0
  失败 --> [*]: 退出码 1
  空响应 --> [*]: 退出码 3
```

关键分支（对应 `agent.c3`）：

- **`--max-turns` 上限**：循环开头判断 `turn > max_turns` 即 `EXIT_UNCONVERGED`（3），且**本轮不发
  请求**。`max_turns <= 0` 表示不设上限。
- **响应为空**（`content` 为空）：`EXIT_UNCONVERGED`（3）。
- **无代码块**：整段 `content` 即最终答案，`print_answer` 到 stdout，把 assistant 记入 `pending`，
  `flush_turn` 落盘，返回 `EXIT_OK`。
- **多代码块**：只执行第一个，`log::warn` 告警。
- **执行后有 `FINAL`**：`print_answer(final_answer)`，再补一条 assistant 记录使会话以 assistant
  收尾，落盘后返回 `EXIT_OK`。
- **执行后无 `FINAL`**：把执行输出作为下一条 `user` 消息（空输出兜底为 `"（无输出）"`），落盘，
  继续下一轮。

### 3.3 落盘时机

`flush_turn` 在每个 turn 的消息攒齐后调用，**整轮一次 write**：

- 用户输入 +（assistant 决策 + 执行输出）的一批记录同批写入，不会与其他进程行交错，也不会留下
  半截 turn。中断/报错后，文件末尾永远是完整 turn，`load` 读到的必定是合法前缀。
- 没给 `--session-id` 时不落盘，`flush_turn` 只清空缓冲。
- 系统提示词**不入库**：每次运行重新注入（`agent` 在加载历史后 `push_front` 一条 system）。

---

## 4. 模块设计

### 4.1 `cli`：配置解析与提示词装配

**`Ctx`** 是一次运行（一个 Trace）的全部配置，经指针向下传递，**不是全局**。字段分五类，新增字段
必须先归入某一类，避免它退化成"什么都往里塞"的篮子：

| 分节 | 语义 | 代表字段 |
|------|------|----------|
| 初始设置 | 本次运行的固定前提，运行期间不变 | `api_key`, `api_url`, `model`, `config_dir` |
| 本次运行边界 | 约束这一次 Trace 的范围 | `session_id`, `max_turns`, `system_prompt`, `user_input` |
| 解析中间量 | 只在 parse/resolve 用，agent 一次都不读 | `system_prompt_file`, `input_file`, `prompt` |
| 日志开关 | 只影响 stderr，与请求/落盘无关 | `quiet`, `debug`, `no_color` |
| 动作开关 | 决定 main 走哪条路，不改运行配置 | `list_sessions`, `list_skills`, `print_system_prompt`, `help` |

**两阶段解析**是本模块的核心结构：

- `parse(args) -> ParseResult`：**纯解析，零 I/O**。只看 argv，不读 stdin、不读文件。所有与
  输入来源冲突、缺失、互斥、`session-id` 合法性相关的用法错误都在这里报出。动作开关
  （`--help` / `--list-sessions` / `--list-skills` / `--print-system-prompt`）在这里就短路返回，
  **必须在碰 stdin 之前结束**，否则 `llmcli --help` 在终端里会阻塞等输入。
- `resolve(args)`：调 `parse` 后补齐运行输入。**唯一的 I/O 发生处**：读 `--system-prompt-file`、
  按三选一取 `user_input`（`--input-file` / 位置参数 / stdin 管道）、读不了报用法错误、最后装配
  系统提示词。`resolve` 会保留 parse 定下的每个字段，只填空着的字段（测试
  `test_resolve_keeps_every_parsed_field` 断言了这一点）。

**输入三选一**在 `parse` 里就校验：靠 `io::stdin().isatty()` 判断是否有管道（isatty 只问一句，不
读内容）。`source_count > 1` 或 `== 0` 都是用法错误。

**系统提示词装配**（`assemble_system_prompt`）是唯一一处，`--print-system-prompt` 与真实运行共用，
保证"打印的就是实际会发给端点的内容"：

```
来源（--system-prompt / --system-prompt-file / $embed 的 system_prompt.md）
  → expand_prompt_placeholders（{{date}} / {{cwd}} / {{os}}）
  → inject_skills（追加本机 skill 的 <available_skills> 块）
```

占位符替换用 `DString.replace` 做字节级替换；占位符全为 ASCII，不会命中多字节 UTF-8 字符内部。
`--api-key` / `--model` 必填（不读环境变量兜底），缺失即用法错误。

### 4.2 `agent`：Trace 主循环

**代码块提取 `extract_code`** 是纯函数（无 I/O），行级扫描：

- 围栏行两种形态：整行以 ``` 开头（含裸 ```），或 ```` ```python ```` 标记围栏缀在散文行末
  （模型偶尔写成"……这样。```python"）。
- 块内以 ``` 开头的行不作闭块，避免代码里嵌 markdown 时早闭；精确的 ``` 行才闭块。
- 只收集第一个块；闭块后再出现围栏只置 `truncated`。`Extract` 用 `has_code` 与 `code` 两个字段
  区分"没有代码块"与"空代码块"（后者 `has_code=true`、`code=""`）。
- 返回的 `code` 在 `mem` 上，由调用方释放；`extract_code` 不做 shellm 那套 heredoc 感知与工具标记
  归一化——v1 只认标准围栏，宁严勿松。

**`chat_once`** 组装请求 → POST → 解析响应，任一环节失败都在 `ChatResponse.error` 里给出可读
原因。密钥在日志中由 `log` 统一脱敏，这里直接打原文。HTTP 非 2xx 与解析失败都附带截断的原始响应。

**内存策略**（见 `agent.c3` 顶部注释）：一条 Trace 的消息（含执行输出）在进程生命周期内保留——
CLI 跑完即退出，不逐轮释放；每轮临时数据走 `tmem`，由循环上的 `@pool()` 回收。

### 4.3 `chat`：消息与序列化

**`Message`** 只有 `role` / `content` / `reasoning` 三字段；RLM 循环实际只产生 `system` / `user` /
`assistant` 三类角色。

**两条序列化路径必须分开**，这是安全与协议正确的关键：

- `message_to_request_json`（回传端点）：**不带** `reasoning_content`（DeepSeek 等端点收到会报错）。
- `message_to_archive_json`（会话存档）：**带** `reasoning_content`。

`build_request` 组装请求体：`model`、`messages`，并用 `cjson::add_false_to_object(root, "stream")`
写 `stream:false`。**不能用 `set("stream", false)`**——cJSON 的 `cJSON_bool` 是 int，与 C3 `bool`
宽度不同，走 C 变参会得到 `true`。请求体**不含 `tools`**。

`parse_response` 解析 `choices[0].message.{content, reasoning_content}` 与
`choices[0].finish_reason`，并把 `usage` 的 token 数拼成展示串；任一必需结构缺失即 `ok=false` 并
给出原因。

### 4.4 `runtime`：生成代码执行

`run_python(code)` 的执行模型：

1. 在临时目录生成脚本文件（`llmcli_script_<ts>.py`），**模型代码原样嵌入、零转义**，不受命令行
   长度限制；同时生成 `final` 临时文件路径，经 `sys.argv[1]` 传给脚本。
2. 包装脚本结构：先 `reconfigure(newline="\n")` 关掉 Windows 文本模式对 `\n` 的 `\r\n` 翻译，
   **再运行模型代码**（以脚本顶层运行，顶层赋值即模块全局变量），**之后**独立捕获 `FINAL` /
   `FINAL_FILE` 写入 `final_path`。模型代码异常时脚本自然中止，traceback 即本轮输出，捕获逻辑不
   执行——这与 shellm 的 bash 包装同构。
3. 定位 Python：Windows 优先 `%WINDIR%\py.exe`（python.org 安装器默认不加 PATH，py 启动器是官方
   标准入口），找不到回退 `python`；POSIX 用 `python3`。
4. `process::spawn(command_line, SpawnOptions.INHERIT_ENV)`，命令为 `python -X utf8 <script>
   <final_path>`。`-X utf8`（PEP 540）让 stdio 与 `open()` 默认 UTF-8，不受本地代码页影响；
   `INHERIT_ENV` 必须开，否则子进程拿到空环境块、连 `subprocess` 都找不到外部命令。
5. **stdout 在本线程读、stderr 交给工作线程**，两边都不堵管道才不会死锁。输出缓冲绑
   `LIBC_ALLOCATOR`（脱离 `@pool`，因为会在工作线程增长）。
6. 合并 stdout+stderr；超过 2000 行则截断为末 2000 行，完整输出落临时文件并把路径写进回填文本；
   非零退出码附加 `[exit N]`。
7. 读回 `final_path`（若存在）作为 `final_answer`，`has_final=true`。

**中断处理**：`active_child`（当前子进程）与 `active_job`（Windows Job 句柄）是 `runtime` 的全局，
**不能是 tlocal**——Windows 上信号处理器跑在另一个线程。`on_interrupt` 先杀子进程再 `exit(130)`。

### 4.5 `session`：会话存储

- 路径：`<config_dir?>/sessions/<id>.jsonl`；`config_dir` 为空则默认 `~/.llmcli`。**只由命令行
  决定，不读任何环境变量**（有过 `LLMCLI_HOME` 的旧实现，已被移除并有测试守）。
- `valid_id` 在 `parse` 阶段就挡住路径穿越与非法字符（`..`、`/`、`\`、`:`、`*`、`?`、`"`、`<`、
  `>`、`|`），因为 session-id 直接当文件名用。
- 一行一条 JSON：`{"ts", "turn", "message"}`。`turn` 与 `ts` **随每条记录传入**，不整批共用——
  同一次 Trace 里用户输入、执行输出、最终答案分属不同轮、不同时刻，`ts` 记的是消息**发生**的时刻，
  不是落盘那一刻。
- `append` 按 turn 攒齐后整块一次 write；`load` 跳过坏行并告警，不中断本次运行。

### 4.6 `skill`：技能发现与注入

技能即一个目录，内含 `SKILL.md`（front matter 给 `name`/`description`，其后是正文）。

- 发现两处：全局 `~/.agents/skills/<name>/` 与项目 `<cwd>/.agents/skills/<name>/`；`load_dirs`
  按顺序加载，**项目级后加载覆盖全局级同名技能**。
- `name` / `description` / 正文三者非空才算有效 skill；按 name 升序排序（插入排序，数量小）。
- 两种产出：`print_installed`（拼进系统提示词的 `<available_skills>` 块，name/description/location
  均做 XML 转义，路径统一成正斜杠）与 `print_brief`（`--list-skills` 的人读简表）。
- 无 skill 时 `print_installed` 返回空串，系统提示词不留任何噪音。
- llmcli 里 Python 是唯一工具，所以注入文本让模型用 Python 读 `SKILL.md`，而不是内置 ReadFile 工具。

### 4.7 `http`：libcurl 封装

`http_init/http_deinit` 管理 curl 全局生命周期。`http_post_json` 完成一次非流式 POST：写回调把响应
体追加到绑 `LIBC_ALLOCATOR` 的 sink（增长发生在 libcurl 的 C 回调里，不能绑 `@pool`）；URL 与
header list 的生命周期需覆盖 `perform`；body 用 `COPYPOSTFIELDS` 让 libcurl 自复制。返回
`HttpResponse{status, body, error}`，传输失败时 `error` 非空、`status` 为 0。

### 4.8 `log`：日志与脱敏

`log` 是 stderr 的**唯一出口**。核心不变量：

- 密钥在 `main` 里 `add_secret` 注册一次，之后所有日志输出前自动 `redact`——调用方不必记得手动
  脱敏，直接打原文即可。脱敏形如 `sk-1234 → sk-***234`，短于 6 位全遮。
- 四级：`error`（quiet 也出）/ `warn` / `info` / `debug`；颜色只在 stderr 是 tty 且未加
  `--no-color` 时输出。
- 这是"未来换 logger 模块"的唯一替换点。

---

## 5. 设计决策与硬约束

这些是代码注释反复强调的取舍，改坏了会让回归挂掉。

### 5.1 行为与协议

- **`parse()` 纯解析，I/O 只在 `resolve()`**：动作开关与用法错误都必须在碰 stdin 前结束，否则在
  终端里阻塞。`--input-file` 指向不存在的文件时，也应先报输入来源冲突而不是先打开文件。
- **RLM 不用 tools 协议**：请求体不带 `tools`；Python 是唯一工具。
- **`reasoning_content` 只入存档、绝不回传端点**：`chat` 的 request / archive 两条序列化路径已分开。
- **`FINAL` / `FINAL_FILE` 按"是否设置"判断，不按真假值**：`FINAL = ""` 也算设置过（空答案收尾）；
  `FINAL_FILE` 优先于 `FINAL`。这与 shellm 的 bash 版 `[ -n "${FINAL+x}" ]` 语义一致。
- **无代码块的回复即最终答案**：单轮问答走这条兜底。

### 5.2 执行与落盘

- **生成代码统一经子进程 Python 3 执行**：Windows 优先 py 启动器、回退 `python`，POSIX 用
  `python3`；`-X utf8` 统一编码；`INHERIT_ENV` 保证子进程有 PATH。
- **输出合并 stdout+stderr，超 2000 行截断为末 2000 行**，完整输出落临时文件并给出路径。
- **每个 turn 完整结束才整轮落盘**（一次 write）：中断/报错后文件末尾永远是完整 turn。
- **会话根目录只由命令行决定**，不读任何环境变量。

### 5.3 内存模型

C3 的内存分配器选择是显式的，本项目用到三种，用途不可混：

| 分配器 | 生命周期 | 用于 |
|--------|----------|------|
| `mem` | 进程生命周期（长期数据） | 一次 Trace 的消息、会话读回、系统提示词、最终答案 |
| `tmem` | 随 `@pool()` 回收（per-iteration scratch） | 每轮请求体、临时格式化、路径拼接 |
| `LIBC_ALLOCATOR` | 显式 `free`，脱离 pool/context | 跨线程增长的输出缓冲、libcurl 回调 sink、stdin 读取 |

规则：跨线程/回调增长的缓冲必须绑 `LIBC_ALLOCATOR`，且**在线程启动前 init**（避免 DString 零值
惰性初始化落到工作线程的 `tmem`）。`mem` 堆串由返回方持有，调用方负责释放。

---

## 6. 平台与运行时差异

- **验证范围**：v1 只在 Windows/x64 上验证，Linux/macOS 是兼容目标而非验证目标。核心链路只用
  可移植 API。
- **唯一的平台专有依赖**是 Windows Job Object（`src/winjob.c3`，`$if env::WIN32` 门控），用于
  Ctrl+C 时连孙进程一起杀。理由：靠控制台事件杀孙进程不可靠（`ping` 收到 `CTRL_BREAK` 只打印统计
  然后继续跑），而 `KILL_ON_JOB_CLOSE` 关句柄即杀整棵进程树。POSIX 上它是未被引用的死代码。
- **信号**：Windows 上 `Ctrl+C` 走 `SIGINT`、`Ctrl+Break` 走 CRT 的 `SIGBREAK`（不是 `SIGTERM`）；
  POSIX 上 `Ctrl+C` 走 `SIGINT`、CI 的 `timeout` 默认发 `SIGTERM`。POSIX 只 terminate 直接子进程
  （进程组 kill 需要 spawn 前 `setpgid`，v1 不做）。
- **Python 定位**：见 4.4。`lib/curl.c3l` 只带 windows-x64 预编译 libcurl（linux/macOS 链系统
  curl）；`lib/cjson.c3l` 在 windows-x64 用预编译 .lib，其它平台编译自带 C 源码。

---

## 7. 错误、退出码与可观测性

**退出码**（常量在 `cli.c3`，同时写入 `HELP`）：`0` 成功；`1` 网络/API/协议错误；`2` 用法/参数错误；
`3` 循环未收敛；`130` 被使用者中断。

**错误传播**：模块间用两种约定——可恢复的用法/解析错误走 `ParseResult.error`（字符串非空即错误，
`main` 打印并返回 2）；运行时错误走返回值字段（`ChatResponse.error`、`HttpResponse.error`、
`Execution.exit_code`），由 `agent` 汇总为 `log::error` + 对应退出码。C3 的 `!` / `catch` 用于文件、
进程等可失败调用。

**可观测性**：v1 是 stderr 人类可读打印，入口集中在 `log`。每轮打印 `[turn N]` 摘要（耗时、
reasoning 字符数、token 用量）；`--debug` 额外打印原始请求/响应（截断、密钥脱敏）；每轮执行的
生成代码原文都打印到 stderr 供审计。

---

## 8. 验证架构

| 层 | 位置 | 覆盖 |
|----|------|------|
| 单元测试 | `test/*_test.c3`（`c3c test`） | `extract_code`、`cli` 解析/resolve、`chat` 序列化与解析、`session` 路径与往返、`skill`、`buf` |
| 端到端回归 | `scripts/regress.py` + `scripts/mock_llm.py` | 真实二进制对着**离线 mock 端点**跑完整 Trace：stdout 纯净度、退出码、落盘、中断、`--max-turns` 等 |

`scripts/mock_llm.py` 是本地 mock OpenAI 服务，按"脚本"依次返回各轮模型回复；内置 scenario
覆盖单轮、代码循环、设置 FINAL、读改文件、reasoning、坏 JSON、HTTP 500、空答案、慢命令、
同一 Trace 两轮代码、永不收敛等。回归对 stdout 纯净度与"已生成代码 100% 在 stderr 可见"有断言。

**约定**：复现某种 LLM 行为时，在 `mock_llm.py` 加 scenario，不要改 `regress.py` 去适配。
回归不碰真实端点、无需 API key，但需先 `c3c build`。

---

## 9. 扩展指南

- **新增/修改 CLI 行为**：先改 `src/cli.c3` 的 `parse` 与 `HELP`，再让 `resolve` 补齐 I/O，最后动
  `agent` / `runtime`。`Ctx` 新字段必须先归入五节之一。
- **行为变更同步文档**：`src/cli.c3` 的 `HELP`、`README.md`、`docs/` 三处同步——`--help` 就是产品
  文档。
- **改请求/响应解析前**：查 `references/chat-completion-api.md`，不要凭记忆写字段名。
- **加新平台**：先确认 `winjob` 门控与 Python 定位路径；`http`/`cjson` 的链接方式见
  `lib/*.c3l` 的平台分支。
- **未来方向（非 v1）**：SSE 流式输出、`--timeout` 与连续失败阈值、代理与自定义 header、
  独立 logger 模块、生成代码沙箱。

---

## 10. 术语表

| 术语 | 含义 |
|------|------|
| **Trace** | 一次运行，即从收到输入到产出最终答案的整条 RLM 循环（`agent::run`）。 |
| **Turn** | Trace 里的一次 API 请求往返；与 stderr 的 `[turn N]` 及会话记录的 `turn` 编号一致。 |
| **RLM** | Recursive Language Model，这里指"模型写代码 → 本地执行 → 输出回填"的循环范式。 |
| **FINAL / FINAL_FILE** | 生成代码里设置完成信号的变量，分别表示以字符串/文件内容作为最终答案。 |
| **Observation** | 代码执行输出，作为下一条 `user` 消息回填给模型（shellm 的 shell-output 语义）。 |
