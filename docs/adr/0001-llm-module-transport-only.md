# llm 模块保持无状态传输层；agent loop 与会话状态留在 CLI 层

2026-09-05 llmcmd 立项 agent loop（trace/turn）。决定：原 `llm::AppContext` 改名  
`LlmOption` 继续住在 `src/llm/context.c3`，只承载接口设置（url/api_key/extra_body/  
debug/provider_label），`llm::stream()/complete()` 只接收 `LlmOption*`；  
贯穿 trace 的数据中心是 agent 级 `AppContext`（`cmd/agent.c3`，module llmcmd），  
内嵌 `LlmOption` 并持有消息历史、请求参数与 `ToolHub*`。工具执行与 loop 编排全部  
留在 CLI 层。

为什么：llm 模块的重试/传输语义依赖无状态可重入；`tool` 模块 import 了 `log`/`cmd`/  
`util`，llm 模块若感知工具或会话，模块边界与依赖方向都无法成立。曾考虑把 trace 状态  
直接塞进模块侧上下文（会话状态进模块，模块从传输层变编排层）——否决。

后续读者注意：不要为"方便"把 `ToolHub`、消息历史或 turn 计数移入 `src/llm/`；那是  
有意的边界，不是遗漏。工具注册必须显式 opt-in（`--tools`，init 前校验名单），`Task`  
工具因依赖子 agent session 基础设施而不可注册。

