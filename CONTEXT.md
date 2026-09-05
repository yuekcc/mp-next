# mp-next — llmcmd agent loop

llm CLI（chat-completions）的领域词汇表：围绕 agent loop 的 trace/turn 概念与两层上下文结构。

## Language

### 会话结构

**Trace**:
一次 `llm` 进程运行内、从用户 prompt 到最终输出的完整对话过程；与进程同生命周期，不落盘、不跨进程恢复。
_Avoid_: session, conversation, run（`run_id` 只是台账字段名）

**Turn**:
一次"发起请求并得到响应"的往返；一个 trace 由 1 个或多个 turn 组成。
_Avoid_: step, round, call

**Stop**:
响应不带 tool_calls 的 turn 结果；trace 唯一正常出口（本 CLI 不设 turn 上限）。
_Avoid_: done, finish（`finish_reason` 是 wire 字段，不是领域词）

### 上下文

**AppContext**:
agent 级的 trace 数据中心：持有接口设置、请求参数、消息历史与工具注册表引用；贯穿整个 trace。
_Avoid_: 把 llm 模块的接口设置结构（LlmOption）混称为 AppContext

**LlmOption**:
llm 模块的接口设置（端点、鉴权、extra body 等）；无状态，不含任何会话数据。
_Avoid_: 旧称 AppContext（已从 llm 模块移出该名号）

### 工具

**ToolHub**:
宿主侧的工具注册表：管理已启用工具及其 schema，串行执行工具调用。
_Avoid_: tool registry, toolset

**ToolContext**:
工具执行时的轻量只读视图，由 AppContext 在派发前构建；工具不得反向感知 AppContext。
_Avoid_: 执行上下文的其他变体叫法
