# LLM 调用模块化重构规格

- 日期：2026-09-05
- 状态：设计已确认，待实施
- 范围：`cmd/llm`（CLI）中 LLM 请求/响应处理逻辑抽取为独立模块，wire 模型层随迁
- 关联：docs/llm.md（CLI 使用说明）、src/model/model.c3（现 wire 模型）、cmd/mem.c3（外部调用 `llm` 二进制）

---

## Problem Statement

`cmd/llm` 单体 CLI（782 行）把职责揉在一起：.env 分层加载、参数解析、提示词组装、
payload 序列化（含 LLM_EXTRA_BODY 合并）、auth header、libcurl 传输、SSE 分帧与打字机
打印、重试退避、错误折叠、usage 落盘、ledger 台账、进程退出。LLM 的「发送请求、处理
请求」逻辑（约一半代码）与 CLI 的交互面（argv/env/stdio）深度纠缠：

- 无法被非 CLI 调用方复用 —— mp-next 的 tool 工具集已就位，agent 主循环是必然的下一个
  消费者，届时只能复制粘贴或把 CLI 当库用。
- 模块内处处 `die()`（exit 1），复用方（未来 agent）无法接管错误处理。
- 重试语义有缺陷：未吐任何内容时连 HTTP 4xx 的 API 错误体也傻重试满次数。

目标形态（初步设想）：上层传入一个 `ChatRequest` 对象，模块返回 `ChatResponse` 对象。
该设想与现状有一个硬冲突：CLI 恒为流式、SSE 边收边打印，纯同步返回会让打字机效果消失
—— 本规格通过双入口设计解决。

## Solution

把 LLM 发送/处理逻辑抽成独立的 `llm` 模块（放在 `src/llm/`，wire 模型 `src/model` 迁入并
折叠为同一模块命名空间），对外提供两条入口：

1. 非流式：`ChatRequest` 进，聚合 `ChatResponse` 出。
2. 流式：`ChatRequest` 进，逐 chunk 回调（供打字机/推理流输出），返回聚合 `ChatResponse`。

调用方通过一个 `AppContext` 对象传入传输与策略配置（url、api key、超时、重试、额外 body、
调试开关等）；该对象支持从环境变量初始化，后续可扩展从配置文件装载。模块内不再有进程级
`exit`；错误用 fault 分类 + 附带细节（HTTP code、文案）的结构表达，由调用方决定如何处理。
重试与退避收进模块，语义修正为：仅传输层错误与 HTTP 429/5xx 重试，4xx 立即失败，
已输出任何内容则永不重试。

CLI 保留其交互层职责：.env 加载、参数解析、提示词组装、打印、usage/ledger、die/warn。
仅源码文件名与模块名变化，**二进制名 `llm` 不变**（`cmd/mem` 经外部命令调用 `llm`，
脚本与文档零改动）。

## User Stories

1. 作为 CLI 用户，我希望流式对话仍逐字输出（打字机效果），以便保持现有交互体验。
2. 作为 CLI 用户，我希望 `--thinking` 的推理内容在 debug 模式走 stderr、正常模式不混入
   stdout，以便 stdout 只含最终答案。
3. 作为 CLI 用户，我希望截断告警（max_tokens 用尽）与现有行为一致。
4. 作为 CLI 用户，我希望 4xx API 错误（参数错误、鉴权失败）立即失败并展示 API 返回的
   error message，而不是空等重试。
5. 作为 CLI 用户，我希望 429/5xx/网络抖动在未输出任何内容时按现有次数重试、指数退避。
6. 作为 CLI 用户，我希望已输出部分内容后的断流立即报错不重试（避免重复尾巴）。
7. 作为 CLI 用户，我希望 usage 文件（LLM_USAGE_FILE）与 ledger 台账（LLM_USAGE_LEDGER）
   行为与现在完全一致。
8. 作为 CLI 用户，我希望 `-M/--messages-file` 超出标准字段的消息仍原样透传（json_override
   保真策略不回归）。
9. 作为 CLI 用户，我希望 LLM_EXTRA_BODY 仍能合入请求体并覆盖同名键（如 llama-server 的
   chat_template_kwargs）。
10. 作为 mem 用户，我希望 `mem search` 仍能拉起 `llm` 命令（二进制名不变）。
11. 作为未来 agent 主循环的开发者，我希望调用 LLM 不触发进程退出，以便错误由 agent 层
    接管并继续运行。
12. 作为未来 agent 主循环的开发者，我希望非流式调用一次拿到完整响应（含 usage、finish
    reason），以便做工具循环与记账。
13. 作为未来 agent 主循环的开发者，我希望流式调用能拿到逐 chunk 回调 + 聚合结果，以便
    实现自己的打字机 UI 而不依赖 CLI。
14. 作为模块调用方，我希望失败时能拿到结构化错误（类别 + HTTP code + 人类可读文案），
    以便决定重试、降级或展示。
15. 作为库使用方，我希望模块可独立初始化/收尾 libcurl（幂等），以便 CLI 与 agent 各自
    控制生命周期。
16. 作为维护者，我希望 wire 模型与传输/SSE/重试同处一个模块命名空间，以便单次 import
    即可使用（延续 tool/* 多文件单模块惯例）。
17. 作为维护者，我希望模型层 JSON 编解码的既有 ABI 处理（cJSON bool 走 int 转发、String
    NUL 结尾）原样保留，以免踩已知坑。
18. 作为验证者，我希望用现有 mock 服务器跑通 stream/thinking/echo/4xx 场景，以便确认
    重构无行为回归。

## Implementation Decisions

### 决策总表（grill 各轮结论）

| # | 决策点 | 结论 | 否决的替代 |
|---|---|---|---|
| D1 | API 形状 | 双入口：非流式 + 流式（chunk 回调），内部共享传输/重试 | 单入口回调可空（语义隐式）；纯同步单入口（丢打字机） |
| D2 | 模块边界 | 进模块：序列化胶水、extra body 合并、auth header、curl 生命周期、SSE 分帧、重试退避、错误折叠、env 默认值；留 CLI：.env 加载、提示词组装、打印、usage/ledger、die | 把 usage/ledger/.env 也搬入（过度耦合） |
| D3 | 配置传递 | 模块内定义 `AppContext`（传输 + 策略字段），调用方显式传入；提供 env 工厂 | 塞进 ChatRequest（wire 与传输混淆）；模块级全局 setter（多调用方互踩）；照抄 mini_pi「api 收 app 层 AppContext」（反向依赖，模块不自洽） |
| D4 | 错误处理 | fault 分类（TRANSPORT_FAILED / HTTP_STATUS / EMPTY_STREAM / MALFORMED_JSON）+ out 参数带 `http_code` 与文案；模块内永不 exit | 纯 fault（丢细节，UX 回退）；模块级 last_error 全局（将来多线程要再改造） |
| D5 | 聚合结果 | 复用 `ChatResponse`，流式累积进 `choices[0]`，新增顶层 `reasoning` 字段 | 新设独立 completion 类型（破坏「模块只产出 wire 类型」约定） |
| D6 | model 归属 | `src/model` 迁入 `src/llm/` 并折叠进 `module llm`（wire 层保持独立文件） | 保留 `module model` 顶层命名（同目录混居两命名空间）；`llm::model` 子模块（引用变长） |
| D7 | CLI 改名 | 源码文件与模块名改为 llmcmd；**二进制/target 名保持 `llm`** | 二进制一并改名（牵动 mem.c3、run_llm.sh、build-all.sh、docs） |
| D8 | 重试语义 | 仅传输层错误 / HTTP 429 / 5xx 且未输出任何 chunk 才重试（指数退避）；4xx 立即失败；已输出部分内容永不重试 | 维持现状（未输出即重试，含 4xx） |
| D9 | curl 生命周期 | 模块暴露幂等 init()/shutdown()，由 main 调用 | 模块内 lazy init（隐藏全局，mem target 也会莫名初始化 libcurl） |
| D10 | 验证 | 构建全绿 + mock 冒烟（stream/think/echo/4xx） | 本期另起模型编解码单测基建（记为后续） |

### D1/D5 语义细节

- 非流式入口固定 `stream:false`；流式入口固定 `stream:true`，逐 chunk 解析后先回调、再聚合。
- 流式聚合：累积 `delta.content` 进 `choices[0].content`，累积 `delta.reasoning`（含 DeepSeek
  `reasoning_content` 兼容回退）进顶层 `reasoning`；finish_reason 取终止帧；usage 跨帧合并
  （缺省 -1 保持旧值语义）。
- 回调的 chunk 只存活到回调返回：其字符串为解析层临时分配；需要跨回调保存的调用方自行拷贝。
- reasoning 是否打印、debug 通道选择由 CLI 回调决定，模块不感知。

### D3 `AppContext` 字段边界

进：url、api_key（LLM_API_KEY 优先，OPENAI_API_KEY 回退）、connect_timeout、max_time、
speed_limit/speed_time、retries、backoff、extra_body（原样 JSON 字符串，序列化时解析合并）、
debug、provider_label。

不进（属 CLI 交互层）：.env 文件加载、默认模型/默认 max_tokens 解析、usage 文件路径、
ledger 路径、临时文件、提示词组装。

env 工厂在调用方完成 .env 分层加载**之后**调用，保证 env::set_var 的覆盖被观察到。

### 模块/文件职责（命名空间 `llm`）

- wire 模型与 JSON 编解码（现 src/model/model.c3 内容，含 cJSON bool 走 int 转发、String
  NUL 结尾等既有处理，逐字节保留）。
- `AppContext` 定义与 env 工厂。
- curl 传输（easy handle、headers、超时/speed 选项、错误缓冲）。
- SSE 分帧与逐行解析（CRLF 剥除、`data: ` 前缀、`[DONE]`、非 data 行进错误缓冲）。
- 入口函数与重试循环（含错误折叠：API error 体、空流、HTTP code）。

具体文件划分与函数签名以实施时的代码为准；上述决策点不因文件摆布改变。

## Testing Decisions

### 测试原则

- 只测外部行为：给定同一 ChatRequest/环境配置，观察「输出了什么 chunk、返回的聚合
  ChatResponse、产生的错误（类别/code/文案）、发起了几次 HTTP 请求」。
- 不测实现细节：不断言模块内部状态、不 mock 模块私有函数。
- 已知坑（cJSON bool ABI、String NUL 结尾）的既有防护保持「模型层内聚」，
  不以测试复制防御。

### 验证 seam（最高可行点）

- **外部 seam：`scripts/mock_llm.py`（HTTP 服务器，场景由最后一条 user 消息首词控制）**。
  流式/非流式两条入口都打到真实 HTTP 层。本轮验证 = 构建全绿 + mock 冒烟回归：
  - `stream`：打字机输出、usage 跨帧合并、截断告警路径。
  - `think`：reasoning 走 stderr（debug）与 stdout 纯净（非 debug）。
  - `echo` / `dump`：请求体字段（stream_options、extra body 合并、messages 保真）抽查。
  - `err400`：立即失败、不重试、文案含 API error message（验证 D8 行为修正）。
  - `length`：max_tokens 截断告警文案与数值正确。
- **内部 seam（后续立项）**：`c3c test` 对模型 JSON 往返 / SSE 分帧加单测 —— 当前
  test/ 只有 cmd 模块的既有用例，无模型测试基建，本期不新建。

## Out of Scope

- 给模型编解码 / SSE 分帧建 `c3c test` 单测基建（后续）。
- `cmd/mem` 迁移或改造；mem search 对 `llm` 二进制的外部调用保持现状。
- mini_pi 侧代码同步（mp-next 的 lib/cjson wrapper 修复等已知差异已在库注释记录，不在本期）。
- 非 chat-completions 通道（Anthropic / Gemini / OpenRouter 路由）—— 沿用现状说明，仍不支持。
- 应用层/agent 主循环 AppContext（mini_pi 式 app 层上下文）—— 未来 app 层出现时内嵌
  `llm::AppContext` 字段，方向为 app → llm。
- 配置文件装载 AppContext 的机制 —— 本期仅环境变量工厂，接口留好扩展位。

## Further Notes

- 行为变更清单（相对现状，全部有意的）：
  1. HTTP 4xx 不再重试（原为未输出即重试，含 4xx）。
  2. 命名空间：wire 类型从 `model::` 迁到 `llm::`；CLI 模块名 `llm_cli` → `llmcmd`。
  3. 其余输出语义逐字节保持。
- 二进制名 `llm` 与新增库模块名 `llm` 并存：前者是构建产物（project.json target 键），
  后者是源码模块命名空间，无符号冲突。
- 编译实验已验证：文件位于 `src/llm/` 下声明不同模块名合法（本规格采用折叠方案，
  目录内所有文件统一声明 `module llm`，延续 tool/* 与 mini_pi api/* 惯例）。
- curl 依赖为项目级（project.json dependencies），`mem` target 一并链接，本轮无依赖变更。
- 交付前回归入口：`./build-all.sh`（mem + llm 两 target）+ docs/llm.md 中的 mock 场景命令。
