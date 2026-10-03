# llmcli

把 LLM 接进 shell 流水线的单二进制 CLI：OpenAI chat completions 兼容，内置 shellm 式 RLM agent loop（模型写 bash 代码、本地执行、输出回填，直到代码设置 `FINAL` / `FINAL_FILE`），stdout 只输出最终答案，过程日志全部走 stderr。

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

# shellm 式 RLM：模型写 ```bash 代码块，本地执行后把输出回填，直到 FINAL / FINAL_FILE
llmcli --model gpt-4o-mini --api-key $KEY --session-id work "把 src/cli.c3 里的拼写错误修掉"
```

输入来源（位置参数 / stdin / `--input-file`）严格三选一；完整参数、退出码与示例见 `llmcli --help`。

## 测试

```bash
c3c test                       # 单元测试
python scripts/regress.py      # 端到端回归（需先 c3c build）
```

## 文档

- [docs/sessions-and-ci.md](docs/sessions-and-ci.md) — 会话存储与 CI 集成
- [docs/prds/001.md](docs/prds/001.md) — 产品需求文档（v1 基线）
- [docs/prds/002.md](docs/prds/002.md) — 会话落盘语义修订（`turn`/`ts` 归属、逐 turn 落盘）
- [docs/prds/003.md](docs/prds/003.md) — 运行配置上下文与工具接口重构（`Options` → `Ctx`）
- [docs/prds/004.md](docs/prds/004.md) — Agent Loop 重构为 shellm 式 RLM（bash 代码块循环）

## 注意

模型生成的 bash 代码默认放行任意命令，提示注入或模型误判可导致任意代码执行（每轮执行的代码原文会打印到 stderr 供审计）。默认不设 turn 上限与超时，失控时用 Ctrl+C 中断或加 `--max-turns <n>`。

代码在所有平台都经 `bash -e -c` 执行。Windows 上要求安装 Git for Windows（自动探测常见安装位置，找不到时回退到 PATH 里的 `bash`）。
