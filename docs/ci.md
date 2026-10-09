# CI 集成

`llmcli` 面向 shell 流水线设计：非交互、stdout 只出最终答案，可直接重定向或交给 `jq`。
本文说明在 CI 中的推荐用法与超时止损策略。

## 基础约定

- 不需要任何交互输入，可无人值守运行。
- 输出不是终端时不会出现 ANSI 颜色（也可显式加 `--no-color`）。
- stdout 只有最终答案，过程日志全部走 stderr，重定向 stdout 即可拿到干净结果。

## 外部超时包裹

因为 v1 没有内置超时，**CI 中请用外部超时包裹**：

```bash
timeout 120 llmcli --model "$MODEL" --api-key "$KEY" --quiet \
    --input-file task.md --session-id "$CI_JOB_ID" \
  > answer.txt
```

GitHub Actions 里可以再叠加 job 级超时：

```yaml
jobs:
  ask:
    timeout-minutes: 5
    steps:
      - run: timeout 120 llmcli --model "$MODEL" --api-key "${{ secrets.KEY }}" --quiet --input-file task.md
```

## 排查问题

加 `--debug`：会打印原始请求/响应（密钥脱敏、长文本仅为可读性截断）。

## 相关风险

- 模型生成的 Python 代码默认放行任意命令：提示注入或模型误判会导致任意代码执行。每轮代码原文都会
  打印到 stderr 供审计。
- 默认不设 turn 上限、不设 HTTP/命令超时、不截断代码输出。需要止损就加 `--max-turns <n>`
  （n>0 生效，达到上限时 stderr 说明原因、stdout 为空、退出码 3）；或用上面的外部超时包裹。
