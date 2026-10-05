# llmcli

面向 coding agent 的说明。本仓库是用 C3 写的单二进制 CLI，把 LLM 接进 shell 流水线。

面向开发者的说明（构建、用法、参数、测试命令、风险提示）在 [README.md](README.md)，这里不重复。
动手前先读 README、[docs/prds/001.md](docs/prds/001.md)（产品需求，Trace/Turn 语义与验收口径），
再读你真正要改的那几个文件。

## 源码地图

- `cmd/llmcli.c3` — `main`：解析 → 日志/脱敏初始化 → help / list-sessions / run 分发
- `src/cli.c3` — `Ctx`（一次 Trace 的全部配置）、`parse`/`resolve`、`HELP`
- `src/agent.c3` — Trace 主循环：`extract_code`（取代码块）、`chat_once`（API 往返）、逐 turn 落盘
- `src/chat.c3` — 消息结构、请求/存档序列化、响应解析
- `src/runtime.c3` — `run_python`：执行代码块、捕获 FINAL / FINAL_FILE、中断处理
- `src/winjob.c3` — Windows Job Object 封装（中断时连孙进程一起杀，仅 Windows 分支调用）
- `src/http.c3` — libcurl 封装（`http_post_json`，非流式）
- `src/session.c3` — 会话落盘（逐 turn 追加）与读回
- `src/log.c3` — stderr 分级日志与密钥脱敏
- `src/buf.c3` — 共享小工具：C 串转换、UTF-8 安全截断
- `src/system_prompt.md` — 内置默认系统提示词（`$embed` 编译期嵌入）
- `test/*_test.c3` — `@test` 单元测试（经 `c3c test` 跑）

## 本仓库的额外约定

- **协议字段查参考资料**：改请求/响应解析前查 `docs/references/chat-completion-api.md`（OpenRouter 的接口原文），不要凭记忆写字段名。
- **平台范围**：v1 只在 Windows/x64 上验证，Linux/macOS 是兼容目标而非验证目标。`lib/curl.c3l` 只带 windows-x64 的预编译 libcurl（linux/macos 链系统 curl）；`lib/cjson.c3l` 在 windows-x64 用预编译 .lib，其它平台编译自带 C 源码。
- **`scripts/mock_llm.py` 是回归用的假端点**：本地 chat completions 服务，按脚本逐轮回放；llmcli 是 shellm 式 RLM 循环，脚本条目就是"该轮模型的回复文本"。复现某种 LLM 行为时在 mock 里加 scenario，不要改 `regress.py` 去适配。脚本条目可用 `--replace k=v` 替换占位符；条目结构、内置 scenario 与 `__raw__` / `__status__` 特殊键见文件顶部的 docstring。
- **端到端回归不碰真实端点**：`scripts/regress.py` 自己拉起 mock（`/control/reset`、`/control/requests` 重置与回收请求记录），不需要 API key；需先 `c3c build`。
- **行为变更要连着文档一起改**：flag、退出码、默认行为一改，`src/cli.c3` 里的 `HELP`、`README.md` 与 `docs/` 都要同步——`--help` 就是这个 CLI 的产品文档。
- **`tmp/` 是草稿区**：里面的 md 是需求初稿和随手记录，不是规格，别当依据。
- **提交信息**沿用仓库现有风格：简短一句话，中文为主。

## 设计上的硬约束（改代码前先过一遍）

这些是代码注释与 PRD 都强调过的取舍，改坏了会让回归挂掉：

- **`parse()` 是纯解析**：只看 argv，不读 stdin、不读文件。`--help` / `--list-sessions` 必须在碰 stdin 之前结束，否则在终端里会阻塞等输入。I/O（读文件、读管道）只在 `resolve()` 里发生。
- **`Ctx` 字段必须归入五节之一**：初始设置 / 本次运行边界 / 解析中间量 / 日志开关 / 动作开关，别让它退化回"什么都往里塞"。
- **stdout 只有最终答案**：过程日志全走 stderr（`src/log.c3` 集中出口），回归对 stdout 纯净度有断言。
- **密钥只在 `main` 里 `log::add_secret` 注册一次**：日志输出统一自动脱敏，调用方不用记得手动 redact；API key 不落盘。
- **`reasoning_content` 只入会话存档，绝不回传端点**（`chat.c3` 的 request/archive 两条序列化路径已分开）。
- **RLM 不用 tools 协议**：请求体不带 `tools` 字段；Python 是唯一工具，模型写 ```python 代码块、执行输出作为下一条 user 消息回填，直到设置 `FINAL` / `FINAL_FILE` 或无代码块回复收尾。
- **生成代码统一经子进程 Python 3 执行**（Windows 优先 py 启动器、回退 PATH 里的 python，POSIX 用 python3；`-X utf8` 统一编码）；执行输出合并 stdout+stderr，超 2000 行截断为末 2000 行、完整输出落临时文件。
- **每个 turn 完整结束才整轮落盘**（一次 write）：中断/报错后文件末尾永远是完整 turn，续话读到的必定是合法前缀。

## 改完自查

1. `c3c build` 与 `c3c test` 通过。
2. `python scripts/regress.py` 通过（离线 mock）。
3. 改了 CLI 行为 → `--help` / README / docs 已同步。
