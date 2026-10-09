<!-- Managed by agent: keep sections and order; edit content, not structure. Last updated: 2026-10-09 -->

# AGENTS.md — src/

## Overview

`src/` 是 llmcli 的实现主体（`cmd/llmcli.c3` 只做 main 分发）。一次运行 = 一条 Trace：
模型回复一个 ```python 代码块，本地以子进程 Python 执行，输出作为下一条 user 消息回填，
循环直到代码里设置 `FINAL` / `FINAL_FILE`，或回复里不再有代码块。Python 是唯一的工具。
语义与验收口径见 [../docs/arch.md](../docs/arch.md)。

## Key Files (module map)

| File | Role |
|------|------|
| `src/cli.c3` | `Ctx`（一次 Trace 的全部配置）、`parse`/`resolve`、`HELP` 文本 |
| `src/agent.c3` | Trace 主循环：`extract_code`、`chat_once`、逐 turn 落盘 |
| `src/chat.c3` | 消息结构、请求/存档序列化、响应解析 |
| `src/runtime.c3` | `run_python`：执行代码块、捕获 FINAL / FINAL_FILE、中断处理 |
| `src/session.c3` | 会话落盘（逐 turn 追加）与读回 |
| `src/skill.c3` | 技能发现（`~/.agents/skills` 与 `./.agents/skills`）与系统提示词注入 |
| `src/http.c3` | libcurl 封装（`http_post_json`，非流式） |
| `src/log.c3` | stderr 分级日志与密钥脱敏 |
| `src/winjob.c3` | Windows Job Object：中断时连孙进程一起杀（仅 Windows 分支调用） |
| `src/buf.c3` | 共享小工具：C 串转换、UTF-8 安全截断 |
| `src/system_prompt.md` | 内置默认系统提示词（`$embed` 编译期嵌入） |

## Setup & environment

- c3c ≥ 0.8.4；`project.json` 定义目标 `llmcli`（`src/**` + `cmd/llmcli.c3`）与测试源 `test/**`。
- 平台范围：v1 只在 Windows/x64 上验证，Linux/macOS 是兼容目标而非验证目标。`lib/curl.c3l`
  只带 windows-x64 的预编译 libcurl（linux/macOS 链系统 curl）；`lib/cjson.c3l` 在 windows-x64
  用预编译 .lib，其它平台编译自带 C 源码。

## Commands

- `c3c build` — 产物 `build/llmcli(.exe)`。
- `c3c test` — 跑 `test/*_test.c3` 里的 `@test`（c3c 无按名筛选，整包一起跑）。
- `python scripts/regress.py` — 端到端回归，用离线 mock 端点，需先 `c3c build`。

## Code style & conventions

- 缩进用 tab（`.c3fmt`：tab_size 4）；大括号 ALLMAN、`else` 另起一行；行长上限 120。
- 每个模块顶部用 `// ---- 分节 ----` 分区；`Ctx` 新增字段必须先归入五节之一（见下）。
- 行为变更连着文档一起改：`src/cli.c3` 的 `HELP`、`README.md`、`docs/` 三处同步——`--help` 就是产品文档。
- 改请求/响应解析前查 `docs/references/chat-completion-api.md`（OpenRouter 接口原文），不要凭记忆写字段名。

## Security & safety

- 密钥只在 `main` 里 `log::add_secret` 注册一次：日志统一自动脱敏，调用方不必手动 redact；API key 不落盘。
- stdout 只有最终答案，过程日志全走 stderr（`src/log.c3` 是唯一出口）；回归对 stdout 纯净度有断言。
- 模型生成的 Python 默认放行任意命令（含 subprocess）：提示注入可致任意代码执行。每轮执行的代码
  原文都打印到 stderr 供审计；风险提示同步在 `--help` 与 README。

## Design hard constraints

这些是代码注释与 PRD 都强调过的取舍，改坏了会让回归挂掉：

- **`parse()` 是纯解析**：只看 argv，不读 stdin、不读文件；`--help` / `--list-sessions` / `--list-skills`
  必须在碰 stdin 之前短路返回，否则在终端里会阻塞等输入。I/O（读文件、读管道）只在 `resolve()` 里发生。
- **`Ctx` 字段必须归入五节之一**：初始设置 / 本次运行边界 / 解析中间量 / 日志开关 / 动作开关。
- **`reasoning_content` 只入会话存档，绝不回传端点**（`chat.c3` 的 request / archive 两条序列化路径已分开）。
- **RLM 不用 tools 协议**：请求体不带 `tools` 字段；Python 是唯一工具。
- **生成代码统一经子进程 Python 3 执行**：Windows 优先 `py` 启动器、回退 PATH 里的 `python`，POSIX 用
  `python3`；`-X utf8` 统一编码。执行输出合并 stdout+stderr，超 2000 行截断为末 2000 行、完整输出落临时文件。
- **每个 turn 完整结束才整轮落盘**（一次 write）：中断/报错后文件末尾永远是完整 turn，续话读到的必定是合法前缀。

## Patterns to Follow

- 新增/修改 CLI 行为：先改 `src/cli.c3` 的 `parse` 与 `HELP`，再让 `resolve` 补齐 I/O，最后动 `agent`/`runtime`。
- 复现某种 LLM 行为：在 `scripts/mock_llm.py` 加 scenario（`--replace` 可替换占位符；条目结构与内置
  scenario 见文件顶部 docstring），不要改 `scripts/regress.py` 去适配。

## PR/commit checklist

- [ ] `c3c build` 与 `c3c test` 通过。
- [ ] `python scripts/regress.py` 通过（离线 mock）。
- [ ] 改了 CLI 行为 → `--help` / README / docs 已同步。
- [ ] 提交信息：简短一句话，中文为主。

## When stuck

- 先读 `README.md`、`docs/arch.md`，再读你真正要改的那几个文件。
- 协议问题查 `docs/references/chat-completion-api.md`；会话/落盘语义查 `docs/sessions.md`。
- `tmp/` 里的 md 是草稿，不是规格，别当依据。
