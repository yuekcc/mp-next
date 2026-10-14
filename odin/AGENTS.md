<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: keep sections and order; edit content, not structure. Last updated: 2026-10-13 -->

# AGENTS.md — odin/

## Overview

`odin/` 是 llmcli 的 **Odin 重写实现**（与根目录的 C3 版并存）。运行时行为与可观测面
（`--help` 文本、轨迹 JSONL 字段、退出码、stdout 纯净度）与 C3 版一致；模块划分与 C3 版一一对应，
但按 Odin 惯例收在**单包 `main`**（一个目录 = 一个包，多文件按关注点拆分）。

规格仍以 `../docs/arch.md`、`../docs/rlm.md`、`../docs/config.md` 等为准；本文件只放给 agent
的模块地图、命令与硬约束。工作计划见 [TODO.md](./TODO.md)。

## Key Files (module map)

| File | Role | 对应 C3 |
|------|------|---------|
| `main.odin` | 入口：子命令派发（traj/context/skills）+ 一次 run 编排 | `cmd/llmcli.c3` |
| `cli.odin` | `Ctx`（五节）、`cli_parse`（纯解析）、`cli_resolve`、`cli_apply_config`、`HELP`、退出码 | `src/cli.c3` |
| `config.odin` | `llmcli.json` 定位/读取/解析（`ConfigSettings`，不合并） | `src/config.c3` |
| `agent.odin` | RLM 主循环：`extract_code`（bash + heredoc）、空响应重试、stall guard、子代理 fork/merge | `src/agent.c3` |
| `context.odin` | `Trajectory -> Message[]`：`RenderPolicy`、角色映射、head/tail/pin、分层截断、max_bytes、run 作用域 | `src/context.c3` |
| `trajectory.odin` | 步骤日志（唯一真相源）：append、读回、fork/merge、blob spill、旧格式映射、list/search/tail | `src/trajectory.c3` |
| `llm.odin` | OpenAI 兼容调用入口（system + messages → POST → 解析） | `src/llm.c3` |
| `chat.odin` | `Message`、请求体组装、响应解析、request/archive 序列化 | `src/chat.c3` |
| `runtime.odin` | `Executor`：bash 包装、`FINAL`/`FINAL_FILE` 捕获、三看门狗、合并/截断、中断处理 | `src/runtime.c3` |
| `http.odin` | `vendor:curl` 非流式 POST（`http_post_json`） | `src/http.c3` |
| `skill.odin` | 技能发现（`~/.agents/skills`、`<cwd>/.agents/skills`）与注入 | `src/skill.c3` |
| `log.odin` | stderr 四级日志、密钥脱敏、`is_stdin_terminal` | `src/log.c3` |
| `winjob.odin` | Windows Job Object（自声明 kernel32 外部函数） | `src/winjob.c3` |
| `buf.odin` | `truncate`（UTF-8 安全截断）、`slashify` | `src/buf.c3` |
| `system_prompt.md` | 内置默认系统提示词，`#load` 编译期嵌入 | `src/system_prompt.md` |
| `*_test.odin` | 单元测试（同包 `@(test)`） | `test/*_test.c3` |

## Setup & environment

- Odin：本机在 `D:\app\odin-dist\odin.exe`（nightly dev-2026-09）。构建/测试命令见下。
- JSON 用 `core:encoding/json`（替代 cjson）；HTTP 用自带的 `vendor:curl`（替代 `lib/curl.c3l`）；
  进程/线程/原子用 `core:os`、`core:thread`、`core:sync`。
- 运行需一个可用的 bash：Windows 用 Git Bash，POSIX 用 `/bin/bash`。

## Commands

- `odin build odin -out:build/llmcli-odin.exe` — 构建。
- `bash scripts/build-odin.sh` — 等价构建，但 Odin 只出 `.obj`、链接交给 zig cc
  （`-target x86_64-windows-msvc`）。Odin 的 Windows 目标是 MSVC ABI，GNU 工具链链不动，
  别把那一步换成 gcc。
- `bash scripts/odin-test.sh` — 单元测试（从 `tmp/` 跑，并强制单线程；原因见下。
  普通环境等价于 `odin test odin -vet`）。
- 端到端回归（复用 C3 的脚本，需先构建；把二进制放到 `tmp/` 再跑）：`cp build/llmcli-odin.exe tmp/ && LLMCLI_BIN="$(pwd)/tmp/llmcli-odin.exe" python scripts/regress.py`。

> **沙箱环境坑（本机 agent 沙箱）**：
> 1. **只允许从特定目录执行会派生子进程的二进制**：`tmp/`（或 harness 的 opencode temp）可以，
>    `build/`、仓库根等位置的 exe 起 bash 会 `NtCreateDirectoryObject(\BaseNamedObjects\...) 0xC0000022`。
>    → `scripts/odin-test.sh` 从 `tmp/` 跑；`run.sh` 把二进制暂存到 `tmp/` 再跑（见其注释）。
> 2. **非 `tmp/` 位置的二进制不能写系统 temp**（`Permission_Denied`）→ `Executor` 会探测可写目录，
>    回退到 `<cwd>/.llmcli-tmp`（见 `runtime.pick_scratch_dir`）。
> 3. **测试并行会共享进程级状态**（`context.temp_allocator`、`runtime` 的活动子进程全局）→ 单线程跑。
> 4. **`uuid.generate_v4` 需要 CSPRNG**，`odin test` 线程上下文只给非加密 RNG → `crypto_uuid_string`
>    里显式装 `crypto.random_generator()`。

## Code style & conventions

- 缩进用 tab；`package main` 单包，文件按关注点命名。
- 每模块顶部 `// ---- 分节 ----`；`Ctx` 字段沿用五节（初始设置 / 本次运行边界 / 解析中间量 /
  日志开关 / 动作开关）。
- 行为变更连着文档一起改：`cli.odin` 的 `HELP`、`../README.md`、`../docs/` 三处同步。
- 改请求/响应解析前查 `../docs/references/chat-completion-api.md`。

## Hard constraints（改坏了回归会挂）

- **`cli_parse` 是纯解析**：只看 argv，不读 stdin/文件；`--help`/`--print-system-prompt` 在碰
  stdin 前短路。I/O 只在 `cli_resolve` 与 `cli_configure_trajectory`。
- **输入三选一**：`-p` / 位置参数 / `--input-file` 互斥；都不给读 stdin 管道；显式输入存在时忽略 stdin。
- **命令名必须是第一个参数**：`llmcli traj ...`；命令名是保留字，同名任务用 `-p`。
- **trajectory 是唯一真相源**：每轮 `context_render` 从轨迹重渲染，内存不累加权威副本。
- **`reasoning_content` 只入存档、绝不回传端点**：`chat.build_request` 不写它；`context_render` 不读它。
- **RLM 不用 tools 协议**：请求体不含 `tools`。
- **生成代码统一经子进程 bash 执行**：stdin 关掉；输出合并 stdout+stderr、剥离 xtrace、超 2000 行
  截断为末 2000 行并把完整输出落盘。
- **三看门狗跑独立线程，只用原子量**（不能用 temp allocator）；Windows 上关 Job 句柄杀整棵进程树。
- **每个步骤产生即 append**（整步一次 write）；头行必须是合法 `{"type":"trajectory"}`。

## Odin 特有的坑

- **`fmt` 把 `{`/`}` 当占位符**：写字面大括号要写 `{{`/`}}`（轨迹头行踩过）。
- **JSON 输出用自写的 `json_encode`（`jsonw.odin`）**：`core:encoding/json` 的 `marshal` 会把
  CJK 转义成 `\uXXXX`（其 `is_printable` 只认 Latin-1）。我们要中文原样 UTF-8（对齐 cjson），
  所以请求体/轨迹步骤都走 `json_encode`；**别换回 `json.marshal`**。解析仍用 `core:encoding/json`。
- **路径分隔符不能混用**：Windows `os.make_directory_all` 对 `C:\a/b` 会报 `Permission_Denied`，
  内部路径一律 `slashify` 成 `/` 再拼。
- **`put_text` 等写 map 的辅助函数要收 `^json.Object`**（值传参 + 计算键无法赋值）。
- **UUID/随机**：见上，需显式 CSPRNG。

## PR/commit checklist

- [ ] `odin build odin` 与 `bash scripts/odin-test.sh` 通过。
- [ ] `LLMCLI_BIN=... python scripts/regress.py` 通过（离线 mock，146 项）。
- [ ] 改了 CLI 行为 → `--help` / README / docs 已同步。
- [ ] 提交信息：简短一句话，中文为主。
