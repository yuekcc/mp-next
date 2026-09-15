# 会话存储与 CI 集成

## 会话文件在哪

`--session-id <id>` 会把整轮 Trace 的消息按行追加到：

```
默认根目录    %USERPROFILE%\.llmcli        （Linux/macOS: ~/.llmcli）
会话目录      <根目录>/sessions
文件          <根目录>/sessions/<id>.jsonl
```

`LLMCLI_HOME` 可以覆盖根目录：

```bash
LLMCLI_HOME=./.local llmcli --session-id work --model ... --api-key ... "..."
# 落到 ./.local/.llmcli/sessions/work.jsonl
```

查看已有会话（stdout，一行一个）：

```bash
llmcli --list-sessions
```

## 文件里有什么

一行一条 JSON：

```json
{"ts":"2026-09-14T23:53:19+08:00","turn":3,"message":{"role":"assistant","content":"...","reasoning_content":"..."}}
```

- **全量落盘**：user / assistant / tool 三类消息都存，工具输出原样入库，不截断。
- assistant 消息的 `reasoning_content`（思维链，DeepSeek 等模型会返回）**原样保存**；
  组装下一次请求时会被剥离，不会回传给端点。
- 系统提示词（`--system-prompt` / `--system-prompt-file`）不入库，每次运行由 flag 重新给。

## 手动清理

v1 **不提供**清理功能，请自行删除文件：

```bash
rm ~/.llmcli/sessions/<id>.jsonl        # 单会话
rm -rf ~/.llmcli/sessions               # 全部
```

Windows PowerShell：

```powershell
Remove-Item "$env:USERPROFILE\.llmcli\sessions\work.jsonl"
```

## 隐私与风险

- 会话文件包含完整对话、思维链与工具输出，**可能含敏感数据**；注意存放位置与磁盘权限。
- `--quiet` 只影响 stderr 打印，**不改变落盘**。
- API key 不落盘，stderr 上出现时一律脱敏（`sk-***abc`）。
- 内置 Bash 工具默认放行任意命令：提示注入或模型误判会导致任意代码执行。每次命令原文都会
  打印到 stderr 供审计，`--help` 里也有警示。
- v1 不设 turn 上限、不设 HTTP/命令超时、不截断工具输出、不设失败阈值（PRD 已确认）。失控时
  用 Ctrl+C 中断——正在执行的子进程会被一并终止，不留孤儿，退出码 130。

## CI 里的用法

`llmcli` 不需要任何交互输入，stdout 只有最终答案，可直接重定向或交给 `jq`；
输出不是终端时不会出现 ANSI 颜色（也可显式加 `--no-color`）。

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

排查问题时加 `--debug`：会打印原始请求/响应（密钥脱敏、长文本仅为可读性截断）。
