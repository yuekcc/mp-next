# llmcli

把 LLM 接进 shell 流水线的单二进制 CLI：OpenAI chat completions 兼容，内置 shellm 式 RLM agent loop（模型写 bash 代码、本地执行、输出回填，直到代码设置 `FINAL` / `FINAL_FILE`），stdout 只输出最终答案，过程日志全部走 stderr。

核心概念：一次运行 = 一条 **trajectory**（append-only 步骤日志，唯一真相源）。每轮 messages 从 trajectory 重渲染，而不是在内存里累加。

## 构建

需要 [c3c](https://c3-lang.org/) ≥ 0.8.4，以及一个可用的 bash（Windows 用 Git Bash）。

```bash
c3c build        # 产物：build/llmcli(.exe)
```

### 全静态构建（Windows）

产物不依赖 `libcurl-x64.dll`（只留 Windows 自带系统 DLL）：

```bash
bash scripts/build-static.sh          # 默认用 zig cc 链接；产物 build/llmcli-static.exe
CC=gcc bash scripts/build-static.sh   # 也可换成 gcc
```

用 c3c 只编译出 `.o`（`--target mingw-x64`），再由 zig cc（clang + lld，自带 mingw-w64）静态链接；
curl 及其依赖来自仓库根的 `curl-8.22.0_3-win64-mingw/`（`CURL_DIR` 可覆盖）。

c3l 里给 MSVC 用的两个预编译库都可从源码 / DLL 重新生成：

```bash
bash scripts/update-curl-implib.sh   # lib/curl.c3l/windows-x64/libcurl-x64.lib（从包内 DLL）
bash scripts/update-cjson-lib.sh     # lib/cjson.c3l/windows-x64/cjson.lib（从 cJSON.c / cJSON.h）
```

## 快速上手

```bash
# 单轮问答（位置参数更顺手）
llmcli --model gpt-4o-mini --api-key $KEY "用一句话解释什么是快排"

# 用 -p 显式给 prompt（脚本 / 任务名可能撞子命令时更稳）
llmcli --model gpt-4o-mini --api-key $KEY -p "traj"

# 管道输入
cat x.md | llmcli --model gpt-4o-mini --api-key $KEY

# shellm 式 RLM：模型写 ```bash 代码块，本地执行后把输出回填，直到 FINAL / FINAL_FILE
llmcli --model gpt-4o-mini --api-key $KEY --traj work "把 src/cli.c3 里的拼写错误修掉"
```

输入来源为 `-p` / 位置参数 / `--input-file` 三选一（不能同时给）；都不给且 stdin 是管道时读管道。子命令名（`traj`/`context`/`skills`）是保留字：要用同名任务请用 `-p traj` 或 stdin/`--input-file`。完整参数、退出码与示例见 `llmcli --help`。

## 子命令

```bash
llmcli traj list                # 列出轨迹
llmcli traj show <name>         # 打印某条轨迹的步骤
llmcli traj tail <name> [n]     # 末尾 n 步
llmcli traj search <name> <pat> # 按子串搜索
llmcli context [--traj <name>]  # 打印渲染出的 messages
llmcli skills                   # 列出本机可用 skill
```

命令名必须是第一个参数，无需软链/别名。

## 子 run

生成代码里再调用一次本二进制就是子 run，用 `-p` 给任务（父轨迹会记 `fork`/`merge`）：

```bash
llmcli -p "<子任务>" --traj-dir "$TRAJ_DIR" --model "$MODEL" \
  --api-key "$API_KEY" --api-url "$API_URL" > 子run.log 2>&1 &
```

## 测试

```bash
c3c test                       # 单元测试
python scripts/regress.py      # 端到端回归（需先 c3c build）
```

## 文档

- [docs/arch.md](docs/arch.md) — 架构设计（RLM loop、模块结构与设计取舍）
- [docs/rlm.md](docs/rlm.md) — RLM 引擎设计（shellm 等价实现；现状已按本文落地）
- [docs/sessions.md](docs/sessions.md) — 轨迹存储（文件格式、落盘时机与清理）
- [docs/ci.md](docs/ci.md) — CI 集成（非交互用法与超时止损）
- [docs/skills.md](docs/skills.md) — 技能（skills）发现与注入
- [docs/references/chat-completion-api.md](docs/references/chat-completion-api.md) — 端点协议字段参考资料

## 注意

模型生成的 bash 代码默认放行任意命令，提示注入或模型误判可导致任意代码执行（每轮执行的代码原文会打印到 stderr 供审计）。执行器带空闲 / 输出量 / 墙钟三看门狗；默认不设 iteration 上限，失控时用 Ctrl+C 中断或加 `--max-iterations <n>`。
