# llmcli

把 LLM 接进 shell 流水线的单二进制 CLI：OpenAI chat completions 兼容，内置 agent loop 与工具调用（Bash、EditFile），stdout 只输出最终答案，过程日志全部走 stderr。

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

# 带工具调用 + 会话续话
llmcli --model gpt-4o-mini --api-key $KEY --session-id work "把 src/cli.c3 里的拼写错误修掉"
```

输入来源（位置参数 / stdin / `--input-file`）严格三选一；完整参数、退出码与示例见 `llmcli --help`。

## 测试

```bash
c3c test                       # 单元测试
python scripts/regress.py      # 端到端回归（需先 c3c build）
```

## 文档

- [docs/tools.md](docs/tools.md) — 如何新增一个内置工具
- [docs/sessions-and-ci.md](docs/sessions-and-ci.md) — 会话存储与 CI 集成
- [docs/prds/001.md](docs/prds/001.md) — 产品需求文档

## 注意

内置 Bash 工具默认放行任意命令，提示注入或模型误判可导致任意代码执行（每次调用的命令原文会打印到 stderr 供审计）。默认不设 turn 上限与超时，失控时用 Ctrl+C 中断或加 `--max-turns <n>`。
