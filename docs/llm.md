# llm

极简 LLM 命令行工具（C3 实现，复刻 `headlong/bin/llm`）。

支持 **且仅支持** OpenAI chat-completions wire format：OpenAI、OpenRouter、llama-server、vLLM
等 openai-compatible 端点共用同一条路径。Anthropic messages / Gemini / adapter / OpenRouter
路由分发**未实现**。

默认一次请求即结束；加 `--tools` 打开 agent loop，让模型连续调用工具直到给出最终答复。

---

## 构建

```bash
c3c build llm          # 单个目标
./build-all.sh         # 构建 project.json 里所有 target
```

产物输出到 `build/`。需要仓库自带的 `lib/curl.c3l`（libcurl 绑定）与 `lib/cjson.c3l`
（cJSON 绑定），随仓库提供，无需额外安装。

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
| `-m, --model MODEL` | 模型名。未给 `-m` 且未给 `--api-url` 时报错退出；只给 `--api-url` 时请求不带 model 字段，交给服务器默认模型 |
| `--api-url URL` | chat-completions 端点覆盖，默认 `https://api.openai.com/v1/chat/completions` |
| `--api-key KEY` | Bearer token；省略时不发 Authorization 头（本地服务场景） |
| `--extra-body JSON` | JSON object 合并进请求体（同名键覆盖默认值）；值不是合法 JSON object 时报错 |
| `-s, --system-prompt TEXT` | system prompt 文本（作为 messages[0] 前置插入） |
| `--system-prompt-file F` | 从文件读 system prompt；文件不存在报错 |
| `-M, --messages JSON` | messages 数组 JSON；非法 JSON / 非数组 / 元素非对象都报错 |
| `--messages-file F` | 从文件读 messages 数组 JSON |
| `--thinking [LEVEL]` | 打开推理。LEVEL 取 `low/medium/high/xhigh`；**只有后一个参数正好是这四个词之一时才被当作 LEVEL**，否则视为普通 prompt |
| `--tools LIST` | 逗号分隔的工具名单，打开 agent loop。缺省不发 `tools` 字段（单次请求）。详见「agent loop」 |
| `--usage-file F` | usage 记录写入路径；缺省临时文件，成功后删除 |
| `--ledger F` | usage 台账路径；缺省 `~/.headlong/usage/llm.jsonl`，父目录自动创建 |
| `--debug` | 请求体、reasoning 增量、工具调用过程打到 stderr（stdout 仍只有答案） |
| `-h, --help` | 打印帮助 |

未知 `-` 开头参数直接报错退出（`llm: error: Unknown option: --nope (try llm --help)`）。

**恒为流式**：请求总是 `stream:true`，响应按 SSE 打字机输出，没有 `--stream` /
`--no-stream` / `--raw` 之类的开关。

本 CLI **不读任何环境变量**，配置全部走命令行开关（见
[docs/adr/0002-llm-cli-settings-cli-only.md](adr/0002-llm-cli-settings-cli-only.md)）。

### 输出上限（max_tokens）

本 CLI **不发送** `max_tokens` / `max_completion_tokens`，输出上限由服务端及其默认值决定。
需要上限时用 `--extra-body` 显式加（键名按端点要求选）：

```bash
llm --extra-body '{"max_tokens":4096}' -m any "hi"
```

`finish_reason == "length"`（输出被截断）时打印 warning，提示经 `--extra-body` 上调。

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

**要真正关掉思考，只能走服务端私有参数**（`--extra-body`）：本 CLI 不发送
`reasoning` 时，llama-server / vLLM 上的 Qwen3.5、DeepSeek 等默认就是开思考的，
此时推理 token 会占用服务端的输出上限。

```bash
llm --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' -m any "hi"
# 部分端点也接受顶层 reasoning_effort:
llm --extra-body '{"reasoning_effort":"none"}' -m any "hi"
```

另注：`--thinking` 发的是 Responses API 风格的 `reasoning{effort,summary}` 对象，
不是 chat-completions 的顶层 `reasoning_effort` 字段。新网关/OpenRouter 通常兼容前者，
严格的 OpenAI `/v1/chat/completions` 可能直接忽略。

---

## agent loop（--tools）

不给 `--tools` 时是一次性问答：发一个不带 `tools` 字段的请求，输出答复即结束。

给 `--tools LIST` 后进入循环，每轮（turn）流程：

1. 把当前消息历史（`system` + `user` + 已累积的 `assistant` / `tool` 消息）连同工具
   schema 一起发给模型。
2. 响应**不带** `tool_calls` → 输出答复，循环结束（唯一正常出口）。
3. 响应**带** `tool_calls` → 逐个执行工具，把每个结果追加成一条 `role:"tool"` 消息，
   回到第 1 步。

约定与边界：

- **可用工具**：`ReadFile`、`Bash`、`EditFile`、`WriteFile`、`Grep`、`Glob`、`ListDir`、
  `HashEditFile`。
- **`Task` 不可用**：它依赖子 agent 会话基础设施，本 CLI 没有，传了直接报错退出。
- 名单里有未知名 → 报错退出；名单为空串 → 打印 warning 后按无工具运行。
- **无轮次上限、无 token/费用上限**：模型一直要调工具就一直跑，Ctrl+C 是唯一的硬刹车。
- **工具失败不退出**：参数不是合法 JSON、工具执行出错、结果为空，都把错误文本当作
  tool 结果回给模型（空结果回 `(no output)`），让它自行纠正。
- 工具都在**当前工作目录**下工作，没有 chroot 或沙箱；`Bash` 拿到的是你的 shell 权限。
- `--debug` 下 stderr 逐条打印工具调用过程：

  ```
  [turn 1] tool Bash({"command":"ls"})
  [turn 1] tool result: docs
  ```

- 每一轮成功调用都会各写一条 usage 记录与一行台账（见「输出与副作用」）。

```bash
llm --tools ReadFile,Grep -m gpt-5 "这个项目里 llm 的错误前缀是怎么拼的？"
```

---

## 请求体（--debug 可看）

`--debug` 实测（mock `dump` 场景回显）：

```json
{"model":"any","messages":[{"role":"user","content":"dump hi"}],"stream":true,
 "stream_options":{"include_usage":true},"reasoning":{"effort":"high","summary":"auto"}}
```

- `stream:true` 与 `stream_options.include_usage:true` 恒发送，不可关；所以服务端必须支持
  chat-completions 流式，且 usage 随流回传。
- **不发送 `max_tokens` / `max_completion_tokens`**（输出上限交给服务端默认；需要时走
  `--extra-body`）。
- `reasoning` 只在 `--thinking` 时出现；`effort` 空则省略，`summary` 恒为 `auto`。
- `--tools` 非空时请求体才带 `tools` 数组。

### messages 保真透传

`-M` / `--messages-file` 的每条消息：

- 能用标准字段无损表达（`role/content/name/tool_call_id/reasoning/tool_calls`，且值都是
  字符串、`tool_calls` 是标准 `{id,type:"function",function:{name,arguments}}`）→ 按字段
  重新序列化（**键顺序可能与输入不同**，语义等价）。
- 否则（多模态 `content` 数组、`content:null`、未知扩展键、非标准 tool_call 结构）→ 整段
  **原样透传，一个字段都不丢**。

实测：

```bash
llm --debug -M '[{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function",
  "function":{"name":"f","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"42"},
  {"role":"user","content":[{"type":"text","text":"multi"}]}]'
# → messages 三元素：assistant 与多模态 user 原样保留；tool 消息按字段重排为
#   {"role":"tool","content":"42","tool_call_id":"c1"}
```

`-s` / `--system-prompt-file` 的 system 消息始终插在 messages[0]，可与 `-M` 共存。

### --extra-body（合并额外请求体键）

JSON object，合并进请求体（同名键覆盖默认值）。值不是合法 JSON object 时报错退出。

```bash
llm --extra-body '{"chat_template_kwargs":{"enable_thinking":false},"temperature":0.2}' \
  -m any "explain quicksort"
```

llama-server 关闭思考的典型用法（Qwen3.5 默认开思考会把 reasoning token 吃满服务端输出上限，
导致正文为空）：

```bash
llm --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' -m any "hi"
```

---

## 配置面

**本 CLI 不读任何环境变量**，也没有 `.env` / rc 文件——接口设置全部由命令行开关给出
（`-m` / `--api-url` / `--api-key` / `--extra-body` / `--usage-file` / `--ledger`），
见 [docs/adr/0002-llm-cli-settings-cli-only.md](adr/0002-llm-cli-settings-cli-only.md)。
从 shell 或脚本调用时，把原环境变量写法换成开关即可；`mem search` 会从自身配置
（`.memrc` / 环境变量 `LLM_API_URL` / `LLM_API_KEY`）自动翻译成开关再拉起 `llm`
（见 docs/mem.md）。

`scripts/mock_llm.py` 服务端口仍可用环境变量 `LLM_MOCK_PORT` 覆盖（默认 8123）——
那是 mock 服务器自己的配置，与 llm 无关。

传输/重试策略是内置常量，**不提供任何覆盖**：建连超时 10s、单次尝试硬上限 600s、
低速中止 100 B/s 持续 60s、瞬时失败重试 2 次（即最多 3 次尝试）、退避基数 1s
（第 n 次等待 `n` 秒）。

---

## 输出与副作用

**stdout**：只打印正文增量，边收边 flush（打字机效果）。无换行结尾。

**stderr**：`--debug` 下打印请求体（`---` 包裹）、reasoning 增量与工具调用过程；
reasoning 兼容标准字段 `delta.reasoning`，回退 DeepSeek 私有 `delta.reasoning_content`。

**usage 文件**（`--usage-file`，缺省临时文件）：成功输出后写入单行 JSON，缺省字段省略——

```json
{"in_tok":37,"out_tok":3,"think_tok":0}
```

**usage 台账**：每次成功调用追加一行 JSONL（ts / provider / model / usage 字段）——
agent loop 每轮各写一行。provider 固定 `chat-completions`（原 `LLM_PROVIDER` 标签与
identity/run_id 元数据已随环境变量删除）。

```json
{"ts":"2026-09-04T16:00:15Z","provider":"chat-completions","model":"any","in_tok":37,"out_tok":3,"think_tok":0}
```

两者都要求 usage 帧非空；usage 文件写失败会静默跳过。临时 usage 文件**仅在成功路径删除**，
失败退出时会残留。

---

## 重试与错误处理

单次尝试：`HTTP POST` → SSE 按行解析 → 流尾没有换行符的残余内容也会处理。重试期间静默
（不输出任何通知）。

| 触发 | 行为 |
|---|---|
| 连接/超时/低速等传输错误 | 若还没输出任何内容，按退避重试 |
| HTTP 429 / 5xx | 若还没输出任何内容，按退避重试 |
| HTTP 4xx（参数错误、鉴权失败等确定性错误） | **立即失败，不再重试** |
| 已输出任何内容后失败 | 直接终止，**不再重试**（避免重复尾巴） |
| HTTP 2xx 但一个 `data:` 事件都没发出 | 视为失败：先从错误缓冲里解析 `error.message`（200+error），否则报空流；不重试 |

- 重试次数固定 2（最多 3 次尝试），退避基数 1s，无外部开关。
- 4xx 立即失败并展示 API 返回的 error message，不再空等重试。实测：

  ```
  llm: error: API error: mock 400: invalid request
  ```

- 错误文案优先级：传输错误 → 响应体里的 API `error.message`（顶层 `error` / 兼容根键
  `message`，choice 级 `error` 与 `finish_reason=="error"` 也算）→ 空流文案
  `empty response: stream ended without emitting anything` → `HTTP <code>`。错误体为空
  或非 JSON 时（如无响应体的 4xx/5xx）直接回退 `HTTP <code>`。
- 错误信息只从**第一个 `data:` 事件之前**的内容里累积，之后的正文不再当错误看待。
- `finish_reason == "length"` 时打印截断 warning（输出上限由服务端决定，需上调走
  `--extra-body`）。
- 错误输出前缀 `llm: error:` / `llm: warning:`，退出码 1。

---

## 示例

```bash
llm -m gpt-5.5 "explain quicksort"
echo "summarize this" | llm -m gpt-4o
llm -m gpt-5 --thinking high "prove sqrt(2) is irrational"
llm -s "You are a terse assistant" -m gpt-4o "hi"

# agent loop：让模型自己翻代码
llm --tools ReadFile,Grep,Glob -m gpt-5 "找出 llm 的错误前缀在哪拼装"

# 本地 llama-server
llm --api-url http://127.0.0.1:8001/v1/chat/completions -m any "hello"

# 本地 mock server（无真实服务时的冒烟验证）
python scripts/mock_llm.py                    # 默认 http://127.0.0.1:8123
llm --api-url http://127.0.0.1:8123/v1/chat/completions -m any \
  --debug --thinking "think 1+1"

# OpenRouter
llm --api-url https://openrouter.ai/api/v1/chat/completions \
  -m openai/gpt-4o "hi"

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
| `dump` | 把收到的请求体原样回显（验证 payload：透传 / reasoning / `--extra-body`） |
| `err400` | HTTP 400 + `{"error":{...}}`（4xx 立即失败、不重试） |
| `embed` | HTTP 200 但响应体是 `{"error":{...}}`（200+error） |

---

## 已知限制

- 恒为流式：`stream:true` + `stream_options.include_usage:true` 不可关，端点必须支持
  chat-completions 流式。
- 只有 chat-completions 一条 wire 路径；无 Anthropic / Gemini / adapter / OpenRouter 路由。
- 工具只在 `--tools` 下可用，`Task` 工具不支持（依赖子 agent 会话基础设施）。
- agent loop **没有轮次上限，也没有 token/费用上限**；模型不停要调工具就会一直跑。
- 工具在当前工作目录执行，`Bash` 拥有你的 shell 权限，无沙箱。
- 无多模态输入、无 attachments。但 `-M` 里携带的 assistant `tool_calls` / `tool` 消息
  会原样透传，可用于回放多轮对话。
- 思考型模型默认把 reasoning 计入 token 上限，且只在 `--debug` 下可见；要彻底关思考用
  `--extra-body`（如 llama-server `{"chat_template_kwargs":{"enable_thinking":false}}`）。
- 重试只看瞬时错误：仅传输层错误与 HTTP 429/5xx 且未输出内容时重试，4xx 等确定性错误
  立即失败；重试与超时策略都是内置常量，无外部开关。
- 非 2xx 且无 `error.message` 时只报 `HTTP <code>`。
- usage 临时文件只在成功路径删除，失败退出时会在临时目录残留一个 `llm-usage-*.tmp`。
