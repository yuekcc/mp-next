# 轨迹（trajectory）存储

`--traj <name>` 把一次运行的全部步骤按行追加到本地 trajectory 文件，实现跨调用续话与自省。
本文说明文件位置、内容格式、落盘时机与清理方式；设计意图见 [rlm.md](rlm.md) 第 8 节。

## 轨迹文件在哪

```
默认根目录    %USERPROFILE%\.llmcli\traj   （Linux/macOS: ~/.llmcli/traj）
轨迹目录      <根目录>/<hex8>-<slug>/
文件          <根目录>/<hex8>-<slug>/trajectory.jsonl
blobs         <根目录>/<hex8>-<slug>/blobs/
```

- `hex8` 是首步 UUID 的前 8 位，`slug` 来自输入的首行（截断到 32 字符并做文件名安全化）。
- 根目录的优先级：`--traj-dir` > `<--config-dir>/traj` > `~/.llmcli/traj`。
- 存放位置只由命令行决定，不读任何环境变量。

```bash
llmcli --traj-dir ./.local/traj --traj work --model ... --api-key ... "..."
# 落到 ./.local/traj/work/trajectory.jsonl（--traj 指定目录名）
```

查看已有轨迹（stdout，一行一个）：

```bash
llmcli --list-sessions          # 别名：--list-trajectories
llmcli traj list
```

## 文件里有什么

首行是头 `{"type":"trajectory"}`，其后每行一个 Step。步骤类型：

| type | 角色（默认渲染） | 字段 | 说明 |
|------|------------------|------|------|
| `prompt` | user | `content` | 触发本次 run 的输入；永不截断 |
| `reasoning` | assistant | `thought`, `cmd`, `reasoning_content?` | 模型推理散文 + bash 代码原文；`reasoning_content` 只入存档、绝不回传端点 |
| `shell-output` | user | `stdout`, `exit`, `feedback?` | 生成代码的执行输出 |
| `feedback` | user | `content` | 看门狗杀进程时给出的结构化反馈 |
| `final` | assistant | `content` | 最终答案 |
| `error` | — | `content`, `reason` | 中止原因（stall / max-iterations 等） |
| `fork` / `merge` | — | `child` / `from_traj` | 子 run 的 DAG 引用 |
| `shellm-run` / `run-summary` | 排除 | — | 记账步骤，永不进上下文 |
```json
{"step_id":"1f3a...","ts":"2026-10-10T12:00:00+08:00","type":"reasoning","run_id":"9c2b...","thought":"先看一下。","cmd":"ls -la"}
```

- **全量落盘**：模型回复、代码原文、执行输出与 `reasoning_content` 都入库，不截断。
- **落盘时机**：每步 append（整步一次 write、append 原子）。中断/报错后文件末尾永远是完整步骤，
  续话读到的必定是合法前缀。`--traj` 缺省时仍是新建一条轨迹（trajectory 是唯一真相源，始终落盘）。
- **大字段 spill**：单字段超 8 KiB 时落 `blobs/<step_id>-<field>.blob`，步骤里存 `<field>_ref` +
  `<field>_bytes`，读取时按需取回。
- `ts` 是这一步发生的时刻（本地时区 RFC3339，秒级），不是落盘那一刻。
- `run_id` 标记产生该步的 run（每次 `Agent.run` 一个新 id）；`--context-scope run` 时只渲染当前 run。
- 系统提示词（`--system-prompt` / `--system-prompt-file`；都不给时用内置默认 `src/system_prompt.md`）
  不入库，每次运行重新注入。

## 兼容旧会话格式

旧的 `.llmcli/sessions/<id>.jsonl`（`{ts,turn,message}` 行）在读取时会被识别并一次性映射成
`prompt` / `reasoning` 步骤，不强制迁移。

## 手动清理

v1 **不提供**清理功能，请自行删除目录：

```bash
rm -rf ~/.llmcli/traj/<hex8>-<slug>    # 单条轨迹
rm -rf ~/.llmcli/traj                   # 全部
```

## 隐私与风险

- 轨迹文件包含完整对话、思维链与代码执行输出，**可能含敏感数据**；注意存放位置与磁盘权限。
- `--quiet` 只影响 stderr 打印，**不改变落盘**。
- API key 不落盘，stderr 上出现时一律脱敏（`sk-***abc`）。
- 模型生成的 bash 代码默认放行任意命令：提示注入或模型误判会导致任意代码执行。每轮代码原文都会
  打印到 stderr 供审计，`--help` 里也有警示。
