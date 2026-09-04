# llm

极简 LLM 命令行工具（C3 实现，复刻 `headlong/bin/llm`）。

支持 **且仅支持** OpenAI chat-completions wire format：OpenAI、OpenRouter、llama-server、vLLM
等 openai-compatible 端点共用同一条路径。Anthropic messages / Gemini / adapter / OpenRouter
路由分发**未实现**。

| 项 | 位置 |
|---|---|
| CLI 入口 | `cmd/llm.c3`（`module llm_cli`） |
| wire 模型 | `src/model/model.c3`（`module model`，请求/响应结构体 + JSON 编解码） |
| 构建目标 | `llm` |

---

## 构建

```bash
c3c build llm          # 单个目标
./build-all.sh         # 构建 project.json 里所有 target
```

产物输出到 `build/`（`project.json` 的 `output`）。依赖 `lib/curl.c3l`（libcurl 绑定）
和 `lib/cjson.c3l`（cJSON 绑定）。

分层约定：`cmd/llm.c3` 只组装 `ChatRequest` 结构体、按字段消费 `ChatResponse` /
`ChatStreamChunk`，不拼 JSON 字符串、不用点路径取字段；所有 wire 结构与编解码在
`src/model/model.c3`。

---

## 用法

三种提示词输入方式：

```bash
llm [options] prompt...           # 位置参数
echo prompt | llm [options]       # stdin
llm [options] -M MESSAGES_JSON    # 完整 messages 数组
```

- 优先级：`-M` / `--messages-file` > 位置参数 > stdin。三者都为空时报错退出。
- stdin 仅在 **无位置参数、无 `-M` 且 stdin 非 TTY** 时读取（交互式终端不会挂住等你输入）。
- 位置参数一旦开始（第一个非 `-` 开头的参数），**其后所有参数包括 `-x` 形式都并入
  prompt**，不再当选项解析。`llm --debug "dump --thinking high"` 里的 `--thinking high`
  是 prompt 正文。

---

## 选项

| 选项 | 说明 |
|---|---|
| `-m, --model MODEL` | 模型名。缺省取 `$LLM_MODEL` → `$SHELLM_MODEL` →（有 key 时）`gpt-5.5` → 报错 |
| `-s, --system-prompt TEXT` | system prompt 文本（作为 messages[0] 前置插入） |
| `--system-prompt-file F` | 从文件读 system prompt；文件不存在报错 |
| `-t, --max-tokens N` | 最大输出 token；缺省 `16384` |
| `-M, --messages JSON` | messages 数组 JSON；非法 JSON / 非数组 / 元素非对象都报错 |
| `--messages-file F` | 从文件读 messages 数组 JSON |
| `--thinking [LEVEL]` | 打开推理。LEVEL 取 `low/medium/high/xhigh`；**只有后一个参数正好是这四个词之一时才被当作 LEVEL**，否则视为普通 prompt |
| `--debug` | 请求体与 reasoning 流式打到 stderr（stdout 仍只有答案） |
| `-h, --help` | 打印帮助 |

未知 `-` 开头参数直接报错退出（`llm: error: Unknown option: --nope (try llm --help)`）。

**恒为流式**：请求总是 `stream:true`，响应按 SSE 打字机输出，没有 `--stream` /
`--no-stream` / `--raw` 之类的开关。

`--help` 是精简版，未列全环境变量（如 `LLM_MODEL`、`LLM_USAGE_*`），以本文为准。

### max_tokens

常量 `DEFAULT_MAX_TOKENS = 16384`。没有按模型名的内建默认值表。

`LLM_MAX_TOKENS` / `-t` 的值必须能解析成整数，否则打印 warning 并回退到 16384：

```
llm: warning: ignoring non-numeric max-tokens='abc', using 16384
```

### tokens 字段名

请求体里该字段按模型前缀自动选名（`model.c3` 的 `tokens_field()`）：

- `max_completion_tokens`：`o1` / `o3` / `o4` / `gpt-5` 前缀
- `max_tokens`：其他

除此之外模型名不参与任何决策（推理开关、端点、重试都不看模型名）。

### 推理（--thinking）

无条件开关，不看模型名、不看环境变量：

| 调用 | 请求体里的 `reasoning` |
|---|---|
| 不加 `--thinking` | **不发送该字段** —— 等于"不表态"，推理开或关完全由服务端/模型默认决定，**不是关闭推理** |
| `--thinking` | `{"summary":"auto"}` — 强度交给服务端默认 |
| `--thinking high` | `{"effort":"high","summary":"auto"}` |

LEVEL 只在恰好匹配四个合法词时才被消费，所以 `llm --thinking "讲个笑话"` 不会把笑话
当成强度（它仍是 prompt）。`none` / `off` 不在白名单里，无法通过 `--thinking` 表达
"显式关闭"。

**要真正关掉思考，只能走服务端私有参数**（`LLM_EXTRA_BODY`）：本 CLI 不发送
`reasoning` 时，llama-server / vLLM 上的 Qwen3.5、DeepSeek 等默认就是开思考的，
此时推理 token 会计入 `max_tokens`。

```bash
LLM_EXTRA_BODY='{"chat_template_kwargs":{"enable_thinking":false}}' llm -m any "hi"
# 部分端点也接受顶层 reasoning_effort:
LLM_EXTRA_BODY='{"reasoning_effort":"none"}' llm -m any "hi"
```

另注：`--thinking` 发的是 Responses API 风格的 `reasoning{effort,summary}` 对象，
不是 chat-completions 的顶层 `reasoning_effort` 字段。新网关/OpenRouter 通常兼容前者，
严格的 OpenAI `/v1/chat/completions` 可能直接忽略。

---

## 请求体构成

`--debug` 实测（mock `dump` 场景回显）：

```json
{"model":"any","messages":[{"role":"user","content":"dump hi"}],"stream":true,
 "stream_options":{"include_usage":true},"max_tokens":100,
 "reasoning":{"effort":"high","summary":"auto"}}
```

- 键顺序固定：`model` → `messages` → `stream` → `stream_options` →
  `max_tokens`|`max_completion_tokens` → `reasoning` →（`LLM_EXTRA_BODY` 的键追加在末尾）。
- `stream:true` 与 `stream_options.include_usage:true` 恒发送，不可关；所以服务端必须支持
  chat-completions 流式，且 usage 随流回传。
- `reasoning` 只在 `--thinking` 时出现；`effort` 空则省略，`summary` 恒为 `auto`。

### messages 保真透传

`-M` / `--messages-file` 的每条消息走 `model::parse_message`：

- 能用 `ChatMessage` 字段无损表达（键集属于
  `role/content/name/tool_call_id/reasoning/tool_calls`，且值都是字符串、`tool_calls` 是标准
  `{id,type:"function",function:{name,arguments}}`）→ 按字段重新序列化（**键顺序可能与输入
  不同**，语义等价）。
- 否则（多模态 `content` 数组、`content:null`、未知扩展键、非标准 tool_call 结构）→ 整段落入
  `json_override`，序列化时**原样透传，一个字段都不丢**。

实测：

```bash
llm --debug -M '[{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function",
  "function":{"name":"f","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"42"},
  {"role":"user","content":[{"type":"text","text":"multi"}]}]'
# → messages 三元素：assistant 与多模态 user 原样保留；tool 消息按字段重排为
#   {"role":"tool","content":"42","tool_call_id":"c1"}
```

`-s` / `--system-prompt-file` 的 system 消息始终插在 messages[0]，可与 `-M` 共存。

### LLM_EXTRA_BODY

JSON object，合并进请求体（同名键覆盖默认值，追加在末尾）。值不是合法 JSON object 时报错退出。

```bash
LLM_EXTRA_BODY='{"chat_template_kwargs":{"enable_thinking":false},"temperature":0.2}' \
  llm -m any "explain quicksort"
```

llama-server 关闭思考的典型用法（Qwen3.5 默认开思考会把 reasoning token 吃满 `max_tokens`，
导致正文为空）：

```bash
LLM_EXTRA_BODY='{"chat_template_kwargs":{"enable_thinking":false}}' llm -m any "hi"
```

---

## 环境变量

| 变量 | 说明 |
|---|---|
| `LLM_API_KEY` / `OPENAI_API_KEY` | Bearer token。**`LLM_API_KEY` 优先**。两者都没有时不发 Authorization 头（本地服务场景） |
| `LLM_API_URL` | 端点覆盖，默认 `https://api.openai.com/v1/chat/completions` |
| `LLM_MODEL` | 默认模型（等价于 `-m`） |
| `SHELLM_MODEL` | 兜底默认模型 |
| `LLM_MAX_TOKENS` | 默认输出上限（等价于 `-t`） |
| `LLM_RETRIES` | 瞬时失败重试次数，默认 2；`0` 关闭。**已输出部分内容后永不重试** |
| `LLM_RETRY_BACKOFF` | 退避基数（秒），默认 1；第 n 次等待 `backoff * n` 秒 |
| `LLM_CONNECT_TIMEOUT` | 建连超时秒数，默认 10；`0` 关闭 |
| `LLM_MAX_TIME` | 单次 HTTP 尝试总时长上限（秒），默认 600；`0` 关闭 |
| `LLM_SPEED_LIMIT` | 速度下限（bytes/s），默认 100；`0` 关闭 |
| `LLM_SPEED_TIME` | 持续低于限速的秒数，默认 60；`0` 关闭 |
| `LLM_EXTRA_BODY` | JSON object，合并进请求体（同名键覆盖默认值） |
| `LLM_USAGE_FILE` | usage 记录写入路径；未设时用临时文件，成功后删除 |
| `LLM_USAGE_LEDGER` | usage 台账路径，默认 `$IDENTITY_DIR/usage/llm.jsonl`，无 `IDENTITY_DIR` 时 `$HOME/.headlong/usage/llm.jsonl`；父目录自动创建 |
| `LLM_PROVIDER` | 仅作标签写入 ledger（`provider` 字段），默认 `chat-completions`，不影响行为 |
| `LLM_RUN_ID` / `SHELLM_RUN_STEP_ID` | 写入 ledger 的 run_id（前者优先） |
| `IDENTITY_DIR` / `IDENTITY_NAME` | 写 ledger 的 identity；`IDENTITY_NAME` 缺省取 `IDENTITY_DIR` 的 basename |
| `HEADLONG_HOME` / `SHELLM_HOME` | 状态目录，缺省 `~/.headlong`（影响第二层 `.env` 与 ledger 默认路径） |
| `LLM_MOCK_PORT` | 仅 `scripts/mock_llm.py` 使用，默认 8123 |

数值型变量解析失败（含空串）时静默沿用代码默认值。

---

## .env 加载

分层加载，**真实环境变量始终优先**：

1. `./.env`（当前工作目录）
2. `$HEADLONG_HOME/.env`（或 `$SHELLM_HOME`、或 `~/.headlong/.env`）

支持 `KEY=VALUE` 和 `export KEY=VALUE`；键名须为 `[A-Za-z_][A-Za-z0-9_]*`，值可带成对单/双
引号。识别到的键若环境中已存在则跳过。

---

## 输出与副作用

**stdout**：只打印 `choices[0].delta.content` 增量，边收边 flush（打字机效果）。无换行结尾。

**stderr**：`--debug` 下打印请求体（`---` 包裹）与 reasoning 增量；reasoning 兼容标准字段
`delta.reasoning`，回退 DeepSeek 私有 `delta.reasoning_content`。

**usage 文件**（`LLM_USAGE_FILE`）：成功输出后写入单行 JSON，缺省字段省略——

```json
{"in_tok":37,"out_tok":3,"think_tok":0}
```

**usage 台账**：每次成功调用追加一行 JSONL（ts / provider / model / usage 字段 / identity / run_id）——

```json
{"ts":"2026-09-04T16:00:15Z","provider":"openrouter","model":"any","in_tok":37,"out_tok":3,"think_tok":0,"identity":"agent-7","run_id":"r1"}
```

两者都要求 usage 帧非空；usage 文件写失败会静默跳过。临时 usage 文件**仅在成功路径删除**，
失败退出时会残留。

---

## 重试与错误处理

单次尝试的流程：`HTTP POST` → SSE 按行解析 → 流尾没有换行符的残余内容也会处理（read-until-EOF）。

| 触发 | 行为 |
|---|---|
| curl 错误（连接/超时/低速） | 若还没输出任何内容，按退避重试 |
| 一个 `data:` 事件都没发出 | 视为失败可重试：空响应、HTTP 错误体、200+error 都先从缓冲里解析 `error.message` |
| 已输出任何内容后失败 | 直接终止，**不再重试** |

- 重试次数 `LLM_RETRIES`（默认 2，即最多 3 次尝试），退避 `LLM_RETRY_BACKOFF * attempt` 秒。
- **重试不区分 HTTP 状态码**：只要没输出过正文就重试，所以 400 这类确定性错误也会退避重试
  到次数耗尽（`LLM_RETRIES=0` 可关）。实测：

  ```
  llm: transient API failure (attempt 1/3): API error: mock 400: invalid request — retrying
  llm: transient API failure (attempt 2/3): API error: mock 400: invalid request — retrying
  llm: error: API error: mock 400: invalid request
  ```

- 错误文案优先级：curl 错误 → 响应体顶层 `error.message`（兼容根键 `message`）→
  `empty response: stream ended without emitting anything` → `HTTP <code>`。
- 错误信息只从**第一个 `data:` 事件之前**的非 data 行累积，之后的行不再收集。
- `finish_reason == "length"` 时打印截断 warning（推理 token 也计入 `max_tokens`，需 `-t` 上调）。
- 错误输出前缀 `llm: error:` / `llm: warning:`，退出码 1。

---

## 示例

```bash
llm -m gpt-5.5 "explain quicksort"
echo "summarize this" | llm -m gpt-4o
llm -m gpt-5 --thinking high -t 32000 "prove sqrt(2) is irrational"
llm -s "You are a terse assistant" -m gpt-4o "hi"

# 本地 llama-server
LLM_API_URL=http://127.0.0.1:8001/v1/chat/completions llm -m any "hello"

# 本地 mock server（无真实服务时的冒烟验证）
python scripts/mock_llm.py                    # 默认 http://127.0.0.1:8123
LLM_API_URL=http://127.0.0.1:8123/v1/chat/completions LLM_MODEL=any \
  llm --debug --thinking "think 1+1"

# OpenRouter
LLM_API_URL=https://openrouter.ai/api/v1/chat/completions \
  llm -m openai/gpt-4o "hi"

# 完整 messages 数组
llm -M '[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"},{"role":"user","content":"again"}]'
```

`scripts/mock_llm.py` 场景由**最后一条 user 消息的首词**控制（脚本头注释为准）：

| 关键字 | 验证点 |
|---|---|
| `stream`（默认） | SSE 打字机 + usage + `[DONE]` |
| `echo` | 回显最后一条 user 消息（验证 prompt / `-s` 拼接） |
| `think` | 先 reasoning 后 content；请求带 `reasoning` 时用标准 `delta.reasoning`，否则走 `reasoning_content` 回退分支 |
| `length` | `finish_reason="length"` 截断警告 |
| `dump` | 把收到的请求体原样回显（验证 payload：透传 / reasoning / `LLM_EXTRA_BODY`） |
| `err400` | HTTP 400 + `{"error":{...}}`（建议 `LLM_RETRIES=0` 免等退避） |
| `embed` | HTTP 200 但响应体是 `{"error":{...}}`（200+error） |

---

## 已知限制

- 恒为流式：请求总是 `stream:true` + `stream_options.include_usage:true`，SSE 打字机输出；
  端点必须支持 chat-completions 流式，且没有非流式路径可拿原始整段响应 JSON。
- 只有 chat-completions 一条 wire 路径；无 Anthropic / Gemini / adapter / OpenRouter 路由。
- **不主动发 `tools` 参数、不做工具调用**（无 function calling 编排、无多模态输入、
  无 attachments）。但 `-M` 里携带的 assistant `tool_calls` / `tool` 消息会原样透传，
  可用于回放多轮对话。
- 思考型模型默认把 reasoning 计入 token 上限，且只在 `--debug` 下可见；要彻底关思考用
  `LLM_EXTRA_BODY`（如 llama-server `{"chat_template_kwargs":{"enable_thinking":false}}`）。
- 重试不看 HTTP 状态码，确定性错误（400/401）也会被退避重试；`LLM_RETRIES=0` 关闭。
- 非 2xx 且无 `error.message` 时只报 `HTTP <code>`。`model.c3` 里的 `response_error_message()`
  覆盖了 choice 级 `error` 与 `finish_reason=="error"`，但 `cmd/llm.c3` **尚未接线**，
  这两类错误信号目前不会展示。
- `max_tokens` / `max_completion_tokens` 的字段名仍按模型前缀切换（`o1`/`o3`/`o4`/`gpt-5`
  → `max_completion_tokens`）。
- usage 临时文件只在成功路径删除，失败退出时会在临时目录残留一个 `llm-usage-*.tmp`。
