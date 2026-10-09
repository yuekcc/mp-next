<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: keep sections and order; edit content, not structure. Last updated: 2026-10-09 -->

# llmcli

把 LLM 接进 shell 流水线的单二进制 CLI（C3 写）：OpenAI chat completions 兼容，内置
shellm 式 RLM loop。用法、参数、构建/测试命令与风险提示见 [README.md](README.md) 与
`llmcli --help`；本文件只放给 agent 的导航与硬约束，不重复 README 内容。

**Precedence:** the closest `AGENTS.md` wins — root 只有全局默认，`src/` 下有更具体的一份。

## Commands

构建、单元测试与端到端回归的完整命令见 [README.md](README.md#测试)。
回归用离线 mock（`scripts/mock_llm.py`），不碰真实端点，无需 API key，但需先构建。

## File Map

```
cmd/llmcli.c3     → main：子命令派发（shellm/traj/context/skills）+ 一次 run
src/              → 实现模块，逐文件地图见 src/AGENTS.md
test/*_test.c3    → @test 单元测试（命令见 README）
scripts/          → mock_llm.py（离线假端点）、regress.py（端到端回归）
docs/arch.md      → 架构设计（RLM loop、模块结构与设计取舍）
docs/rlm.md       → RLM 引擎设计（shellm 等价实现；现状已落地）
docs/sessions.md  → 轨迹存储（文件格式、落盘时机与清理）
docs/ci.md        → CI 集成（非交互用法与超时止损）
docs/skills.md    → 技能发现与注入
docs/references/  → 端点协议字段原文（chat-completion-api.md）
lib/              → c3l 预编译依赖：curl、cjson
```

## Scoped AGENTS.md

- [src/AGENTS.md](./src/AGENTS.md) — 模块地图、设计硬约束、协议/平台约定；改 `src/` 前必读。

## 全局约定

- **`--help` 就是这个 CLI 的产品文档**：改 flag、退出码或默认行为时，`src/cli.c3` 的 `HELP`、`README.md` 与 `docs/` 三处同步改。
- **协议字段查参考资料**：改请求/响应解析前查 `docs/references/chat-completion-api.md`，不要凭记忆写字段名。
- **`tmp/` 是草稿区**：里面的 md 是需求初稿与随手记录，不是规格，别当依据。
- **提交信息**沿用仓库风格：简短一句话，中文为主。

## 自查

按 [README.md](README.md) 跑完构建与测试（含端到端回归），并确认 CLI 行为变更已同步 `--help` / README / docs。
