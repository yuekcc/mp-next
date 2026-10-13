# llmcli Odin 重写 — TODO / 开发计划

> 状态：进行中（分支 `odin-port`）。本文是本次重写的工作计划，随进度更新；
> 稳定后其结论（模块地图、构建命令）再并入 `README.md` / `docs/`。

## 1. 目标与范围

用 Odin 重新实现 llmcli，**运行时行为与现有 C3 版等价**：

- 单二进制 CLI，把 LLM 接进 shell 流水线；OpenAI chat completions 兼容（非流式）。
- shellm 式 RLM loop：模型回一个 ```` ```bash ```` 代码块 → 本地 bash 执行 → 输出回填，
  循环到 `FINAL` / `FINAL_FILE` 或回复无代码块。
- trajectory 是唯一真相源；每轮 messages 由 context 从 trajectory 重渲染。
- stdout 只出最终答案，过程日志全走 stderr；退出码 0/1/2/3/130。
- 子命令：`traj` / `context` / `skills`；子代理 = 再跑一次本二进制。
- 持久配置 `llmcli.json`（默认 < 配置 < flag）。

**非目标（沿用 rlm.md）**：SSE 流式、多 provider 抽象、Docker 沙箱、`mem` 持久记忆。

**验收口径**：以现有 `docs/arch.md`、`docs/rlm.md`、`docs/config.md`、`docs/sessions.md`、
`docs/skills.md`、`docs/ci.md` 为规格；端到端复用离线 mock 端点。

## 2. 技术选型（内置库优先）

| 关注点 | 选型 | 说明 |
|--------|------|------|
| HTTP | `vendor:curl` | Odin 自带 libcurl 绑定；Windows 用 `vendor/curl/lib/libcurl.lib`，已探针验证可编可跑 |
| JSON | `core:encoding/json` | `Value`/`Object`/`Array`；替代 cjson |
| 进程 | `core:os`（`process_start`/`process_wait`/`process_terminate` + `pipe`） | bash 执行器 |
| 线程 | `core:thread` + `core:sync`（`atomic_load/store`、`Mutex`） | 三看门狗 + stderr 读取线程 |
| 时间 | `core:time` | 墙钟/耗时；RFC3339 时间戳 |
| 日志/终端 | `core:fmt`（`eprintfln`）、`core:terminal.is_terminal` | stderr 分级 + tty 上色 |
| UUID | `core:encoding/uuid` | step_id / run_id（hex8 取前缀） |
| 信号 | `core:c/libc`（`signal`、`SIGINT`/`SIGTERM`） | 中断处理 |
| Windows Job | 自声明 `foreign import`（kernel32） | `core:sys/windows` 无 Job Object API；照搬 C3 的 winjob |

**分配器策略**：长期数据用 `context.allocator`；每轮 scratch 用 `context.temp_allocator`
并在每轮 `free_all`。**看门狗/读取线程只用原子量，绝不用 temp allocator**（线程本地）。

## 3. 目录与构建

Odin 一个目录 = 一个包。实现放在仓库根的新目录 `odin/`，**单包 `main`**（多文件按关注点拆分）：
`odin build odin` / `odin test odin` 无需额外 collection 参数，最简单可靠。

```
odin/
  main.odin          # 入口：子命令派发 + 一次运行编排（≈ cmd/llmcli.c3）
  cli.odin           # Ctx / parse / resolve / HELP（≈ src/cli.c3）
  config.odin        # llmcli.json 定位/读取/解析（≈ src/config.c3）
  agent.odin         # RLM 主循环 / extract_code / stall guard / fork-merge（≈ src/agent.c3）
  context.odin       # Trajectory -> Message[]（≈ src/context.c3）
  trajectory.odin    # 步骤日志：append/read/fork/merge/spill/旧格式（≈ src/trajectory.c3）
  llm.odin           # OpenAI 兼容调用入口（≈ src/llm.c3）
  chat.odin          # Message、请求/存档序列化、响应解析（≈ src/chat.c3）
  runtime.odin       # bash Executor + 三看门狗 + FINAL 捕获（≈ src/runtime.c3）
  skill.odin         # 技能发现与注入（≈ src/skill.c3）
  http.odin          # vendor:curl 非流式 POST（≈ src/http.c3）
  log.odin           # stderr 分级 + 密钥脱敏（≈ src/log.c3）
  winjob.odin        # Windows Job Object（≈ src/winjob.c3）
  buf.odin           # 小工具：UTF-8 安全截断等（≈ src/buf.c3）
  system_prompt.md   # 内置默认系统提示词，`#load("system_prompt.md", string)` 编译期嵌入
  *_test.odin        # 单元测试（同包，@(test)）
```

命令（Windows，odin 在 `D:\app\odin-dist\odin.exe`，按需加 PATH）：

```bash
odin build odin -out:build/llmcli-odin.exe     # 构建
bash scripts/odin-test.sh                      # 单元测试（cd build/ 再跑，见下）
bash scripts/regress-odin.sh                   # 端到端回归（对接 mock_llm.py，待补）
```

> **测试运行位置的坑**：某些沙箱环境里，当被测包目录位于当前工作目录子树内时，测试进程会被
> 限制文件写入，导致轨迹/配置/技能测试报 `Permission_Denied`。`scripts/odin-test.sh` 先 `cd build/`
> 再以 `odin test ../odin` 运行，规避该限制；普通环境下等价于 `odin test odin -vet`。

## 4. 模块地图与职责

| Odin 文件 | 职责 | 关键接口 |
|-----------|------|----------|
| `main.odin` | 子命令派发 → run；动作短路；列轨迹/skill、`traj`/`context` | `main` |
| `cli.odin` | `Ctx`、`parse`（纯解析）、`resolve`（补 I/O）、`assemble_system_prompt`、`HELP`、退出码 | `parse`, `resolve` |
| `config.odin` | 持久配置定位/读取/解析（只产出中间结构，不合并） | `load` |
| `agent.odin` | RLM 全部：主循环、`extract_code`、空响应重试、stall guard、子代理 fork/merge | `run`, `extract_code` |
| `context.odin` | `Trajectory -> Message[]`：角色映射、head/tail/pin、分层截断、max_bytes、run 作用域 | `render`, `default_policy` |
| `trajectory.odin` | 步骤日志：`Step`/`Trajectory`、append、读回、fork/merge、blob spill、旧格式映射 | `open_new`, `append`, `read_all` |
| `llm.odin` | OpenAI 兼容调用入口（system + messages → POST → 解析） | `Llm.call` |
| `chat.odin` | `Message`、请求体组装、响应解析、两种序列化 | `build_request`, `parse_response` |
| `runtime.odin` | bash 包装、捕获 `FINAL`、三看门狗、合并/截断输出、中断处理 | `Executor.run` |
| `skill.odin` | 技能发现（`~/.agents/skills`、`<cwd>/.agents/skills`）与两种列表 | `SkillHub` |
| `http.odin` | curl 生命周期与非流式 POST | `http_init`, `http_post_json` |
| `log.odin` | stderr 四级日志、密钥自动脱敏 | `init`, `add_secret`, `info/warn/error/debug` |
| `winjob.odin` | Windows Job Object：中断/看门狗时连孙进程一起杀 | `create_and_assign`, `terminate` |
| `buf.odin` | C 串转换、UTF-8 安全截断、format | `truncate` 等 |

## 5. TDD 接缝（待确认）

只在下列**公共接缝**写测试（纯函数优先，文件/进程/网络做集成测试）：

| # | 接缝 | 类型 | 断言什么 |
|---|------|------|----------|
| S1 | `buf.truncate(text, limit)` | 纯 | 不截断多字节 UTF-8；超限追加提示 |
| S2 | `chat.build_request` / `parse_response` | 纯 | 请求体不含 `reasoning_content`、含 `stream:false`；解析 content/reasoning/usage；坏 JSON 报错 |
| S3 | `agent.extract_code` | 纯 | 第一个块、裸围栏、块内围栏不早闭、heredoc 不早闭、空代码块 `has_code=true`、`truncated` |
| S4 | `trajectory`（append/read/fork/merge/spill/legacy） | 文件集成（temp dir） | 原子 append、读回一致、>8KiB spill 往返、旧 `{ts,turn,message}` 映射 |
| S5 | `context.render` | 文件集成 | 角色映射、head/tail 窗口、分层截断桩、`max_bytes` 收紧、run 作用域、reasoning_content 不参与 |
| S6 | `cli.parse` / `cli.resolve` | 纯 + 文件集成 | 输入三选一互斥、`--help` 不碰 stdin、flag 冲突、`TrajArgs` 扫描 |
| S7 | `config.load` + `cli.apply_config` | 文件集成 | 默认<配置<flag；类型不符报错、未知键告警；var 合并；system_prompt 来源互斥 |
| S8 | `skill`（发现/解析/排序/注入） | 文件集成（temp dir） | front matter 解析、项目级覆盖全局、name 升序、XML 转义、无 skill 返回空 |
| S9 | `runtime.Executor.run` | 进程集成 | `FINAL`/`FINAL_FILE` 按「是否设置」捕获、xtrace 剥离、>2000 行截断、`[exit N]`、看门狗杀进程并给反馈 |
| S10 | `agent.run` 主循环 | 集成（mock 端点） | 无代码块→final、多轮 bash→FINAL、空响应重试、max-iterations 退出码 3 |
| S11 | E2E | `scripts/regress-odin.sh` + `mock_llm.py` | stdout 纯净、退出码、轨迹落盘、子代理 fork/merge、看门狗、`traj`/`context` 子命令 |

> 复用 `scripts/mock_llm.py`（离线假端点）与其 scenario；E2E 只加一个指向 Odin 产物的 runner，
> 不改动现有 C3 回归。

## 6. 任务清单（垂直切片，红→绿逐条推进）

### 阶段 0：脚手架
- [x] `odin/` 目录 + `system_prompt.md`（从 C3 版原样搬）
- [x] `main.odin` 最小入口（仅 `--help` 打印 + 退出码），`odin build`/`odin test` 跑通
- [x] 确认 odin 可用路径与命令，写入本文件

### 阶段 1：纯函数（无 I/O）
- [x] S1 `buf.truncate`
- [x] S2 `chat`：`Message`、`build_request`（system+user/assistant，不含 tools）、`parse_response`
- [x] S3 `agent.extract_code`（bash + heredoc）

### 阶段 2：trajectory（唯一真相源）
- [x] S4 `Step`/`Trajectory`、`open_new`/`open_resume`/`open_at`、`append`（整步一次写）
- [x] blob spill（>8 KiB → `blobs/<step>-<field>.blob`）
- [x] `read_all` / `last` / `find` / `search` / `tail`
- [x] `fork`/`merge`、`list_all`、旧格式映射
- [x] 轨迹根目录优先级：`--traj-dir` > 配置 `traj_dir` > `<config-dir>/traj` > `~/.llmcli/traj`

### 阶段 3：context 渲染
- [x] S5 `RenderPolicy` + `default_policy`
- [x] `render`：过滤（exclude/run 作用域）、head/tail/pin 窗口、角色映射、分层截断、max_bytes 折半

### 阶段 4：配置 + CLI 解析
- [x] S7 `config.load`（JSON→Settings，含已知键/类型校验/未知键告警）
- [x] S6 `cli.parse`（纯解析：输入三选一、动作短路、flag 校验、`TrajArgs` 扫描）
- [x] `cli.resolve`（配置合并、读文件、读 stdin、装配系统提示词）
- [x] `HELP` 文本（与现有 `--help` 等价）

### 阶段 5：HTTP + LLM
- [x] `http`：`http_init`/`http_deinit`/`http_post_json`（vendor:curl）
- [x] `llm.call`：system 前置 + 请求 + 解析 + 错误可读

### 阶段 6：bash 执行器
- [x] S9 `Executor`：脚本包装（set -e、cd、export、set -x、FINAL/FINAL_FILE 捕获、exit rc）
- [x] 定位 bash（Windows Git Bash / POSIX `/bin/bash`）；stdin 接 /dev/null
- [x] 输出合并、xtrace 剥离、2000 行截断 + 完整输出落盘
- [x] 三看门狗（空闲/输出量/墙钟）+ 结构化反馈；Windows Job Object 杀树
- [x] 中断处理器（SIGINT/SIGBREAK/SIGTERM → 杀子进程 + 退出 130）

### 阶段 7：RLM 主循环
- [x] S10 `agent.run`：建轨迹、写 shellm-run/prompt、每轮 render→call→extract→exec→append（由 S11 端到端覆盖）
- [x] 空响应重试（≤8）、stall guard（连续 5 / 重复 3）、max-iterations → 退出码 3
- [x] 子代理：`LLMCLI_PARENT_TRAJ_*` → 父轨迹写 fork/merge；注入 `$TRAJ_DIR`/`$TRAJ_ID`/`$MODEL`/`$API_KEY`/`$API_URL`

### 阶段 8：skill + 子命令
- [x] S8 `skill`：发现、front matter 解析、排序、`print_installed`/`print_brief`
- [x] `main` 子命令派发：`traj list/show/tail/search [--children/--full]`、`context [--traj]`、`skills`

### 阶段 9：端到端与文档
- [x] S11 复用 `scripts/regress.py`（`LLMCLI_BIN` 指向 Odin 产物）跑通全部 146 项检查
- [ ] 更新 `README.md`（新增 Odin 构建/测试段）、`docs/`（构建语言与目录）、根 `AGENTS.md`
- [ ] 新增 `odin/AGENTS.md`（模块地图与硬约束）
- [ ] 提交信息：简短一句话，中文为主

## 7. 风险与备注

- **`vendor:curl` 链接**：Windows 目标用自带 `libcurl.lib`（已探针跑通 HTTPS）。需确认
  `-vet`、不同 odin nightly 下 stable；如换机器缺 lib 则退回系统 curl。
- **线程 + 分配器**：Odin 线程有独立 context；看门狗线程禁用 temp allocator。读取线程向
  `[dynamic]byte` 追加时须绑显式 allocator（heap），不能用 loop 的 temp。
- **Windows 退出码**：被 `process_terminate` 杀死的进程 exit_code 是 Windows 状态码（如
  `0xC0000142`），需统一映射为「非零/被杀」语义。
- **信号**：Windows 无 `SIGBREAK` 常量于 `core:c/libc`（仅 SIGINT/SIGTERM），需按平台声明。
- **行为等价**：轨迹 JSONL 字段名、`--help` 文本、退出码必须与 C3 版一致，回归才有意义。
- **时间戳**：本地时区 RFC3339 秒级；`core:time` 的本地时区获取需实测（timezone 包接口有限）。
- `tmp/` 是草稿区；本文不进入 `docs/` 规格，结论稳定后再迁移。

## 8. 已确认决策（2026-10-13）

1. **等价程度 = 可观测面逐字等价**：`--help` 文本、轨迹 JSONL 字段、退出码、stdout 纯净度、
   stderr「已生成代码 100% 可见」的断言与 C3 版一致；内部实现（数据结构、日志措辞细节）自由。
2. **包结构 = 单包 `odin/`**（一个 `package main`，多文件按关注点拆）；构建/测试不带 collection 参数。
3. **测试接缝 = S1–S11 全部保留**。
4. **交付顺序**：先打通最小端到端闭环（单轮问答 + bash 循环），再补齐 context/config/子命令；
   阶段顺序仅作参考，以「能跑通一条垂直切片」为先。
