# llmcli

面向 coding agent 的说明。本仓库是用 C3 写的单二进制 CLI，把 LLM 接进 shell 流水线。

面向开发者的说明（构建、用法、参数、测试命令、风险提示）在 [README.md](README.md)，这里不重复。
动手前先读 README，再读你真正要改的那几个文件。

## 本仓库的额外约定

- **协议字段查参考资料**：改请求/响应解析前查 `docs/references/chat-completion-api.md`（接口原文，近 5000 行），不要凭记忆写字段名。
- **平台范围**：v1 只在 Windows/x64 上验证，Linux 是兼容目标而非验证目标；`lib/*.c3l` 只带了 windows-x64 的预编译库，别指望在别的平台上能直接链上。
- **`scripts/mock_llm.py` 是回归用的假端点**：一个本地 OpenAI chat completions 服务，只实现 `POST /v1/chat/completions` 与 `GET /health`，响应按"脚本"逐轮回放（脚本用完后重复最后一条）。llmcli 是 shellm 式 RLM 循环，脚本每条就是"该轮模型的回复文本"（含或不含 ```bash 代码块、可带思维链、可返回非法 JSON / 500 / 空内容）；能用 `--script <file.json>` 喂自定义脚本、`--replace k=v` 替换占位串——复现某种 LLM 行为请在这里加 scenario，不要改回归脚本去适配。
- **端到端回归不碰真实端点**：`scripts/regress.py` 会自己拉起上面的 mock（并额外用 `/control/reset`、`/control/requests` 重置与回收请求记录），不需要 API key，可以放心跑。
- **行为变更要连着文档一起改**：flag、退出码、默认行为一改，`src/cli.c3` 里的 `HELP`、`README.md` 与 `docs/` 都要同步——`--help` 就是这个 CLI 的产品文档。
- **`tmp/` 是草稿区**：里面的 md 是需求初稿和随手记录，不是规格，别当依据。
- **提交信息**沿用仓库现有风格：简短一句话，中文为主。

## 改完自查

1. 编译与测试通过（命令见 README）。
2. 端到端回归通过（离线 mock，见上）。
3. 改了 CLI 行为 → `--help` / README / docs 已同步。
