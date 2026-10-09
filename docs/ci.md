# CI 集成

`llmcli` 面向 shell 流水线设计：非交互、stdout 只出最终答案，可直接重定向或交给 `jq`。
本文说明在 CI 中的推荐用法与超时止损策略。

## 基础约定

- 不需要任何交互输入，可无人值守运行。
- 输出不是终端时不会出现 ANSI 颜色（也可显式加 `--no-color`）。
- stdout 只有最终答案，过程日志全部走 stderr，重定向 stdout 即可拿到干净结果。

## 超时止损

执行器自带三看门狗（空闲 / 输出量 / 墙钟），单条命令失控会被杀并回填结构化反馈；但整个 run 仍可能
多轮空转。CI 中建议**外部超时 + `--max-iterations`** 双保险：

```bash
timeout 120 llmcli --model "$MODEL" --api-key "$KEY" --quiet \
    --input-file task.md --traj "$CI_JOB_ID" \
    --max-iterations 20 \
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

- 加 `--debug`：会打印原始请求/响应（密钥脱敏、长文本仅为可读性截断）。
- 看轨迹：`llmcli traj tail <name> [n]` / `llmcli traj show <name>` / `llmcli traj search <name> <pat>`
  （轨迹根由 `--traj-dir` / `--config-dir` 决定）。
- 看渲染：`llmcli context --traj <name>`。

## 相关风险

- 模型生成的 bash 代码默认放行任意命令：提示注入或模型误判会导致任意代码执行。每轮代码原文都会
  打印到 stderr 供审计。
- 默认不设 iteration 上限。需要止损就加 `--max-iterations <n>`（n>0 生效，达到上限时 stderr 说明
  原因、stdout 为空、退出码 3）；执行器三个看门狗阈值分别用
  `--inactivity-timeout` / `--max-output-size` / `--max-exec-time` 调整；或用外部超时包裹。
