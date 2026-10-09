# 会话存储

`--session-id <id>` 把整条 Trace 的消息按行追加到本地会话文件，实现跨调用续话。本文说明
文件位置、内容格式、落盘时机与清理方式。

## 会话文件在哪

```
默认根目录    %USERPROFILE%\.llmcli        （Linux/macOS: ~/.llmcli）
会话目录      <根目录>/sessions
文件          <根目录>/sessions/<id>.jsonl
```

`--config-dir` 可以覆盖根目录（默认 `~/.llmcli`，Windows 为 `%USERPROFILE%\.llmcli`）：

```bash
llmcli --config-dir ./.local --session-id work --model ... --api-key ... "..."
# 落到 ./.local/sessions/work.jsonl
```

存放位置只由命令行决定，不读任何环境变量。

查看已有会话（stdout，一行一个）：

```bash
llmcli --list-sessions
```

## 文件里有什么

一行一条 JSON：

```json
{"ts":"2026-09-14T23:53:19+08:00","turn":3,"message":{"role":"assistant","content":"...","reasoning_content":"..."}}
```

- **全量落盘**：user / assistant 两类消息都存，模型回复与代码执行输出原样入库，不截断。
- **落盘时机**：每个 turn 完整结束后立刻追加（整轮一次 write）。所以 Trace 报错、`--max-turns` 止损或
  Ctrl+C 中断时，**已完成的 turn 已经在文件里**；没攒齐的那个 turn 不写（不会留下没有执行输出的
  代码轮），续话读到的必定是完整的历史前缀。没给 `--session-id` 时全程不落盘。
- `ts` 是这条消息发生的时刻（本地时区 RFC3339，秒级），不是落盘那一刻：用户输入记本次运行开始，
  assistant 记响应到达，执行输出记代码跑完。
- `turn` 是这条消息所属的那一轮请求：用户输入记 1，模型决策与其执行输出记发起它的那一轮，
  最终答案记最后一次请求的轮次（与 stderr 每轮的 `[turn N]` 摘要编号一致）。
- assistant 消息的 `reasoning_content`（思维链，DeepSeek 等模型会返回）**原样保存**；
  组装下一次请求时会被剥离，不会回传给端点。
- 系统提示词（`--system-prompt` / `--system-prompt-file`；都不给时用内置默认提示词 `src/system_prompt.md`）
  不入库，每次运行重新注入。

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

- 会话文件包含完整对话、思维链与代码执行输出，**可能含敏感数据**；注意存放位置与磁盘权限。
- `--quiet` 只影响 stderr 打印，**不改变落盘**。
- API key 不落盘，stderr 上出现时一律脱敏（`sk-***abc`）。
- 模型生成的 Python 代码默认放行任意命令：提示注入或模型误判会导致任意代码执行。每轮代码原文都会
  打印到 stderr 供审计，`--help` 里也有警示。
