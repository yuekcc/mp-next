# llm

极简 LLM 命令行工具（C3 实现，复刻 `headlong/bin/llm`）。

支持 **且仅支持** OpenAI chat-completions wire format：OpenAI、OpenRouter、llama-server、vLLM
等 openai-compatible 端点共用同一条路径。Anthropic messages / Gemini / adapter / OpenRouter
路由分发**未实现**。

源码：`cmd/llm.c3`，构建目标 `llm`。

---

## 构建

```bash
c3c build llm          # 单个目标
./build-all.sh         # 构建 project.json 里所有 target
```

产物输出到 `build/`（`project.json` 的 `output` 字段）。依赖 `lib/curl.c3l`（libcurl 绑定）
和 `lib/cjson.c3l`（cJSON 绑定）。

chat-completions 的请求体/响应体结构体与 JSON 编解码集中在 `src/model/model.c3`
（`module model`），`cmd/llm.c3` 只负责组装 `ChatRequest` 结构体、按字段消费
`ChatResponse`/`ChatStreamChunk` 的解析结果，不做字符串拼 JSON。

---

## 用法

三种互斥的提示词输入方式：

```bash
llm [options] prompt...           # 位置参数（第一个非 `-` 开头的参数之后全部并入 prompt）
echo prompt | llm [options]       # stdin（无位置参数、无 -M 且 stdin 非 TTY 时读取）
llm [options] -M MESSAGES_JSON    # 完整 messages 数组
```

优先级：`-M` / `--messages-file` > 位置参数 > stdin。三者都为空时报错退出。

---

## 选项

| 选项 | 说明 |
|---|---|
| `-m, --model MODEL` | 模型名。缺省取 `$LLM_MODEL` → `$SHELLM_MODEL` →（有 key 时）`gpt-5.5` → 报错 |
| `-s, --system-prompt TEXT` | system prompt 文本（作为 messages[0] 前置插入） |
| `--system-prompt-file F` | 从文件读 system prompt；文件不存在报错 |
| `-t, --max-tokens N` | 最大输出 token；缺省 `16384` |
| `-M, --messages JSON` | messages 数组 JSON，形如 `[{"role":"user","content":"hi"}]`；必须是数组否则报错 |
| `--messages-file F` | 从文件读 messages 数组 JSON |
| `--thinking [LEVEL]` | 打开推理。LEVEL 取 `low/medium/high/xhigh`；**只有后一个参数正好是这四个词之一时才被当作 LEVEL**，否则视为普通 prompt |
| `-h, --help` | 打印帮助 |

未知 `-` 开头参数直接报错退出。

**恒为流式**：请求总是 `stream:true`，响应按 SSE 打字机输出，没有 `--stream` /
`--no-stream` / `--raw` 之类的开关。

### max_tokens

常量 `DEFAULT_MAX_TOKENS = 16384`。没有按模型名的内建默认值表。

`LLM_MAX_TOKENS` / `-t` 的值必须能解析成整数，否则打印 warning 并回退到 16384：

```
llm: warning: ignoring non-numeric max-tokens='abc', using 16384
```

### tokens 字段名

请求体里该字段会按模型自动选名：

- `max_completion_tokens`：`o1` / `o3` / `o4` / `gpt-5` 前缀
- `max_tokens`：其他

### 推理（--thinking）

无条件开关，不看模型名、不看环境变量：

| 调用 | 请求体里的 `reasoning` |
|---|---|
| 不加 `--thinking` | 不发送该字段（默认关闭推理） |
| `--thinking` | `{"summary":"auto"}` — 强度交给服务端默认 |
| `--thinking high` | `{"effort":"high","summary":"auto"}` |

LEVEL 只在恰好匹配 `low` / `medium` / `high` / `xhigh` 时才被消费，所以
`llm --thinking "讲个笑话"` 不会把笑话当成强度（它仍是 prompt）。

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
| `LLM_USAGE_FILE` | usage 记录写入路径；未设时写临时文件并在结束时删除 |
| `LLM_USAGE_LEDGER` | usage 台账路径，默认 `$IDENTITY_DIR/usage/llm.jsonl`，无 `IDENTITY_DIR` 时 `$HOME/.headlong/usage/llm.jsonl` |
| `LLM_EXTRA_BODY` | JSON object，合并进请求体（同名键覆盖默认值） |
| `LLM_PROVIDER` | 仅作标签写入 ledger，不影响行为 |
| `LLM_RUN_ID` / `SHELLM_RUN_STEP_ID` | 写入 ledger 的 run_id |
| `IDENTITY_DIR` / `IDENTITY_NAME` | 写 ledger 的 identity；`IDENTITY_NAME` 缺省取 `IDENTITY_DIR` 的 basename |
| `HEADLONG_HOME` / `SHELLM_HOME` | 状态目录，缺省 `~/.headlong` |

### LLM_EXTRA_BODY 示例

透传服务端专有参数。llama-server 关闭思考（Qwen3.5 默认开思考会把 reasoning token 吃满
`max_tokens`，导致正文为空）：

```bash
LLM_EXTRA_BODY='{"chat_template_kwargs":{"enable_thinking":false}}' \
  llm -m any "explain quicksort"
```

值不是合法 JSON object 时报错退出。

---

## .env 加载

分层加载，**真实环境变量始终优先**：

1. `./.env`
2. `$HEADLONG_HOME/.env`（或 `$SHELLM_HOME`、或 `~/.headlong/.env`）

支持 `KEY=VALUE` 和 `export KEY=VALUE`，值可带成对单/双引号。识别到的键若环境中已存在则跳过。

---

## 输出与副作用

**正文（恒为流式）**：只打印 `choices.0.delta.content` 增量，边收边 flush（打字机效果）。
没有非流式路径，无法拿到原始整段响应 JSON。

**usage 文件**（`LLM_USAGE_FILE`）：调用结束后写入单行 JSON，如
`{"in_tok":12,"out_tok":48,"think_tok":0}`；未返回的字段省略。

**usage 台账**：每次成功调用追加一行 JSONL（ts / provider / model / usage 字段 / identity / run_id）。

---

## 重试与错误处理

| 触发 | 行为 |
|---|---|
| curl 错误 | 若还没发出任何内容，按退避重试 |
| 一个 `data:` 事件都没发出 | 视为失败可重试：空响应、HTTP 错误体、内嵌 error 都会先从缓冲里解析 `error.message` |
| 已输出任何内容后失败 | 直接终止，**不再重试** |

`finish_reason == "length"` 时打印截断 warning（推理 token 也计入 `max_tokens`，需 `-t` 上调）。

错误输出前缀 `llm: error:` / `llm: warning:`，退出码 1。

---

## 示例

```bash
llm -m gpt-5.5 "explain quicksort"
echo "summarize this" | llm -m gpt-4o
llm -m gpt-5 --thinking high -t 32000 "prove sqrt(2) is irrational"
llm -s "You are a terse assistant" -m gpt-4o "hi"

# 本地 llama-server
LLM_API_URL=http://127.0.0.1:8001/v1/chat/completions llm -m any "hello"

# OpenRouter
LLM_API_URL=https://openrouter.ai/api/v1/chat/completions \
  llm -m openai/gpt-4o "hi"

# 完整 messages 数组
llm -M '[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"},{"role":"user","content":"again"}]'
```

---

## 已知限制

- 恒为流式：请求总是 `stream:true`，SSE 打字机输出；端点必须支持 chat-completions 流式。
- 只有 chat-completions 一条 wire 路径；无 Anthropic / Gemini / adapter / OpenRouter 路由。
- 无工具调用（function calling）、无多模态输入、无 attachments。
- 不解析 `reasoning_content`，只取 `delta.content`；思考型模型需自行用 `LLM_EXTRA_BODY` 关思考。
- 非 2xx 且无 `error.message` 时只报 `HTTP <code>`。
- `max_tokens` / `max_completion_tokens` 的字段名仍按模型前缀切换（`o1`/`o3`/`o4`/`gpt-5`
  → `max_completion_tokens`）。除此之外模型名不参与任何决策。
