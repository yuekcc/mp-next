# llmcli

把 LLM 接进 shell 流水线的单二进制 CLI：OpenAI chat completions 兼容，内置 shellm 式 RLM agent loop（模型写 Python 代码、本地执行、输出回填，直到代码设置 `FINAL` / `FINAL_FILE`），stdout 只输出最终答案，过程日志全部走 stderr。

## 构建

需要 [c3c](https://c3-lang.org/) ≥ 0.8.4。

```bash
c3c build        # 产物：build/llmcli(.exe)
```

## 快速上手

```bash
# 单轮问答
llmcli --model gpt-4o-mini --api-key $KEY "用一句话解释什么是快排"

# 管道输入
cat x.md | llmcli --model gpt-4o-mini --api-key $KEY

# shellm 式 RLM：模型写 ```python 代码块，本地执行后把输出回填，直到 FINAL / FINAL_FILE
llmcli --model gpt-4o-mini --api-key $KEY --session-id work "把 src/cli.c3 里的拼写错误修掉"
```

输入来源（位置参数 / stdin / `--input-file`）严格三选一；完整参数、退出码与示例见 `llmcli --help`。

## 技能（skills）

本工具会自动发现本机技能，把可用列表追加进系统提示词，模型据此自行用 Python 读取对应
`SKILL.md` 并照其执行。发现两处目录（同名时项目级覆盖全局级）：

- 全局：`~/.agents/skills/<name>/SKILL.md`
- 项目：`<当前目录>/.agents/skills/<name>/SKILL.md`

每个 `SKILL.md` 以 front matter 给出 `name` 与 `description`，其后为技能正文；三者齐全才算
一个有效 skill。用 `--list-skills` 查看当前发现的结果：

```bash
llmcli --list-skills
```

想看某次运行实际会发给端点的系统提示词（含已注入的 skill 列表），用：

```bash
llmcli --print-system-prompt
```

它不要求 `--model` / `--api-key`，也不读输入；可与 `--system-prompt` / `--system-prompt-file`
组合，验证自定义提示词与技能列表拼接后的最终结果。

## 测试

```bash
c3c test                       # 单元测试
python scripts/regress.py      # 端到端回归（需先 c3c build）
```

## 文档

- [docs/sessions-and-ci.md](docs/sessions-and-ci.md) — 会话存储与 CI 集成
- [docs/prds/001.md](docs/prds/001.md) — 产品需求文档（shellm 式 RLM agent loop 基线）
- [docs/references/chat-completion-api.md](docs/references/chat-completion-api.md) — 端点协议字段参考资料

## 注意

模型生成的 Python 代码默认放行任意命令（含 subprocess），提示注入或模型误判可导致任意代码执行（每轮执行的代码原文会打印到 stderr 供审计）。默认不设 turn 上限与超时，失控时用 Ctrl+C 中断或加 `--max-turns <n>`。

代码在所有平台都经 Python 3 执行（`-X utf8`，输出与文件默认编码统一 UTF-8）。Windows 上优先用 py 启动器（`%WINDIR%\py.exe`），找不到时回退到 PATH 里的 `python`；Linux/macOS 用 `python3`。
