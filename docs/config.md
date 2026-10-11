# llmcli 配置文件（llmcli.json）

## Problem Statement

用户每次跑 `llmcli` 都要在命令行重复输入一长串 flag：`--model`、`--api-url`、`--api-key`、看门狗阈值、`--traj-dir` 等。这些是"偏好/环境"，不是"这一次运行的内容"，却只能靠命令行传，既啰嗦又容易漏。子命令（`traj`/`context`/`skills`）也需要知道轨迹根在哪，目前只能靠 `--traj-dir`/`--config-dir` 临时指定。用户需要一个持久的配置文件，把这些偏好一次写好，命令行只在需要时覆盖。

## Solution

在配置目录根下引入 `llmcli.json` 作为持久配置文件。一次运行/子命令启动时，程序自动读取该文件，把里面的值当作"高于内置默认、低于命令行 flag"的中间层。优先级固定为：

```
内置默认值  <  llmcli.json  <  命令行 flag
```

用户把不常变的偏好写进 `llmcli.json`，日常只给 `-p`/位置参数/`--input-file` 等"本次输入"即可；偶尔想临时改某个值，就在命令行加对应 flag 覆盖。配置文件不存在就静默跳过，存在则自动生效，可用 `--no-config` 整份关闭。

## User Stories

1. As a 日常用户, I want 把常用模型写进 `llmcli.json` 的 `model` 键, so that 每次运行不必再敲 `--model`。
2. As a 使用非 OpenAI 兼容端点的用户, I want 把 `api_url` 写进配置文件, so that 不用每条命令都带 `--api-url`。
3. As a 用户, I want 把 `api_key` 写进配置文件, so that 不必每次运行都传 `--api-key`（同时知晓这是明文落盘的显式选择）。
4. As a 用户, I want 用 `traj_dir` 指定轨迹根目录, so that 所有轨迹统一落到自定义位置。
5. As a 用户, I want 用 `workdir` 指定生成代码的工作目录, so that 模型写的 bash 默认在我的项目目录里跑。
6. As a 用户, I want 用 `system_prompt` 固化一套系统提示词, so that 每次运行都带上我的自定义指令。
7. As a 用户, I want 用 `system_prompt_file` 指向一个共享提示词文件, so that 多台机器/多个脚本共用同一份提示词。
8. As a 用户, I want 用 `max_iterations`/`inactivity_timeout`/`max_output_size`/`max_exec_time` 设定默认看门狗与循环上限, so that 不用每次手动防失控。
9. As a 用户, I want 用 `max_bytes`/`context_scope` 设定默认上下文渲染预算与作用域, so that 长轨迹自动按我的预算截断。
10. As a 用户, I want 用 `var` 对象注入默认环境变量, so that 生成代码里能读到我的固定环境。
11. As a 用户, I want 用 `debug`/`no_color` 固化日志偏好, so that 每次运行都按我的口味输出过程日志。
12. As a 命令行用户, I want flag 能覆盖配置文件里的同名值, so that 单次运行可以临时换模型/端点/阈值而不改配置文件。
13. As a 用户, I want 某个键既没写进配置也没给 flag 时回落到内置默认, so that 行为与今天"只给 flag"完全一致。
14. As a 用户, I want 用 `--config-dir <dir>` 让程序读 `<dir>/llmcli.json`, so that 不同项目/环境各自维护一份配置。
15. As a 用户, I want 配置文件不存在时静默跳过, so that 全新环境不会因缺文件报错。
16. As a 用户, I want 用 `--no-config` 关闭整份配置, so that 偶尔想用纯默认+flag 跑一次时不改文件也不搬文件。
17. As a 用户, I want JSON 语法错误时立刻报错（退出码 2）并指出文件, so that 我能快速定位坏掉的配置。
18. As a 用户, I want 配置值类型不符时立刻报错, so that 不会把 `"max_iterations": "abc"` 静默当成某个默认值。
19. As a 用户, I want 未知/多余键只告警不失败, so that 未来的新键或我多写的东西不会让旧配置崩掉。
20. As a 子命令用户（`traj`/`context`/`skills`）, I want 子命令也吃配置里的 `traj_dir`, so that `traj list`/`context` 能找到正确的轨迹根。
21. As a 用户, I want `--print-system-prompt` 打印出配置里 `system_prompt` 的效果, so that 打印的就是实际会发给端点的内容。
22. As a 用户, I want `--help` 不读配置文件, so that 查看帮助永远是瞬时且无副作用的。
23. As a 被 llmcli 派生的子代理, I want 显式 flag 在存在配置文件时依然生效, so that 子代理用 `--model`/`--api-url` 等覆盖父级配置不会出错。
24. As a 用户, I want 配置里的 `api_key` 与 flag 给的 key 一样被日志脱敏, so that 不会在 stderr 泄漏密钥。
25. As a 用户, I want 优先级规则（默认<配置<flag）写进 `--help` 与 README, so that 不用猜配置何时被覆盖。
26. As a 开发者, I want 配置文件解析不进入纯解析路径, so that `--help`/`--print-system-prompt` 之外的一切仍在"碰 stdin 前短路"的约束内。

## Implementation Decisions

- **优先级三层的合并语义**：默认值作为 `Ctx` 的初始值；配置只在"对应 flag 未被显式给出"时才回填；flag 显式给出则完全由 flag 决定。这意味着纯解析函数需要额外记录"哪些 flag 被显式给出"（presence 集合），而真正的配置合并发生在有 I/O 的解析补齐阶段。
- **纯解析不变**：配置文件是文件 I/O，读取必须发生在补齐阶段（`resolve`），绝不进纯解析函数。`--help` 因此在解析阶段就短路、完全不读配置；`--print-system-prompt` 需要读配置（`system_prompt` 可能来自配置），故其配置读取发生在补齐阶段。
- **新配置加载单元**：引入一个专门负责"定位/读取/解析/应用 `llmcli.json`"的单元（模块或分节），解析复用项目已有的 cjson 依赖，不引入新 JSON 库。解析得到的中间结构独立于 `Ctx`，应用时只改 `Ctx` 上"flag 未显式给出"的字段。
- **文件定位**：配置文件路径固定为 `<config-dir>/llmcli.json`。`config_dir` 只来自 `--config-dir` flag 或默认 `~/.llmcli`，配置文件中不认 `config_dir` 键（避免自指）。`--traj-dir` 不影响配置文件位置。
- **配置键 schema**（顶层为扁平 JSON 对象，键名 snake_case，与 flag 名一一对应、仅去掉 `--` 并把连字符转下划线）：

  ```jsonc
  {
    "api_key": "…",            // string
    "api_url": "…",            // string
    "model": "…",              // string
    "traj_dir": "…",           // string
    "workdir": "…",            // string
    "system_prompt": "…",      // string（与 system_prompt_file 互斥）
    "system_prompt_file": "…", // string（与 system_prompt 互斥）
    "max_iterations": 0,       // int，<=0 = 不限
    "context_scope": "traj",   // "traj" | "run"
    "max_bytes": 0,            // int，0 = 不限
    "inactivity_timeout": 120, // int，0 = 用默认，<0 = 关
    "max_output_size": 10485760, // int，0 = 用默认
    "max_exec_time": 1800,     // int，0 = 用默认，<0 = 关
    "var": { "NAME": "value" }, // object，string -> string
    "debug": false,            // bool
    "no_color": false          // bool
  }
  ```

- **数值哨兵语义**：配置里的数值与其同名 flag 的语义完全一致（含 0/负数的"不限/用默认/关闭"哨兵含义）；键缺失才落到硬编码默认。不做"配置里禁止 0"之类特殊处理。
- **布尔开关**：`debug`/`no_color` 配置可设 true；本次不新增 `--no-*` 反义 flag，接受"配置能开、命令行关不掉"。
- **`var` 合并**：配置的 `var` 对象提供基础环境变量，命令行 `--var` 在其上逐键追加/覆盖同名项（配置先、CLI 后），符合"配置 < flag"的逐键语义。
- **`system_prompt` 与 `system_prompt_file` 在配置里也互斥**：两者同时出现按硬错误处理，沿用 flag 层的互斥精神。
- **排除项**：以下 flag 不进配置：`--help`/`-h`、`--print-system-prompt`、`-p`/`--prompt`/位置参数、`--input-file`、`--traj`、`--config-dir`、`--resume`、`--quiet`。它们分别是动作开关、单次输入选择器或单次运行标识，不是持久配置。
- **错误处理**：JSON 语法错误 → 硬报错退出码 2 并指路径；值类型不符 → 硬报错退出码 2；未知键（含被排除的 `resume`/`quiet`/`traj`/`config_dir` 等）→ 告警到 stderr 后忽略。
- **逃生舱**：新增 `--no-config` flag，真实运行与子命令都认，跳过整份配置文件。
- **子命令生效范围**：子命令（`traj`/`context`/`skills`）读配置但只吃 `traj_dir`（决定轨迹根）；`context` 暂保持既有默认渲染策略，不新接 `context_scope`/`max_bytes` 管线。
- **密钥脱敏**：配置读出的 `api_key` 与 flag 给的 key 同等对待，注册进统一脱敏通道；程序自身绝不把任何密钥写回磁盘。
- **文档同步**：`--help`（产品文档）、README、相关架构/会话文档三处同步此行为变更。

## Testing Decisions

- **好测试的标准**：只测外部行为——给定 argv（+ 一个临时 `llmcli.json`），断言 `resolve` 返回的 `Ctx` 字段与 `error`，不测内部实现（不测 presence 集合长什么样、不测解析中间结构）。
- **单一最高接缝**：所有配置行为通过 `resolve` 这一个入口测试，与既有单元测试"写临时文件 → 调 `resolve` → 断言 Ctx"的写法一致。测试覆盖：16 个键各自"配置回填默认、flag 覆盖配置"；数值哨兵；布尔；`var` 对象与逐键覆盖；`system_prompt`/`system_prompt_file` 互斥；语法错/类型错/未知键三种错误路径；`--no-config`；配置文件缺失静默跳过。
- **子命令接缝（既有，扩展用）**：在既有目录 flag 扫描函数的用例上，补 `traj_dir` 来自配置与 `--no-config` 两条。
- **被测试模块**：CLI 解析/补齐单元（核心），配置加载单元（解析边界，视其是否独立成模块决定是否直接测）。优先级合并的端到端效果由 `resolve` 覆盖，不必单独测 agent 层。
- **先例**：现有 CLI 单元测试（用 `build/` 下临时输入文件驱动 `resolve`，覆盖 flag 解析、互斥、动作短路等）；轨迹单元测试（用 `set_base_dir` 注入根目录测落盘）；端到端回归脚本（起离线 mock 端点，断言 stdout 纯净度）——配置优先级可加一条"仅靠配置文件 + 少量 flag"跑通的场景。
- **回归约束**：stdout 纯净度断言不得破坏——配置加载的告警/错误一律走 stderr。

## Out of Scope

- 不新增 `--no-quiet` 等反义 flag（布尔开关仍只能开、不能关）。
- 不提供生成/编辑配置文件的子命令（用户手写 JSON）。
- 不引入 schema 版本号与迁移机制（`llmcli.json` 无版本字段）。
- 不做项目级配置自动发现（不扫描当前目录的 `llmcli.json`；只有 `--config-dir` 或默认 `~/.llmcli` 一处）。
- 不支持多份配置文件合并（单文件）。
- `context` 子命令不接 `context_scope`/`max_bytes` 渲染管线（保持默认策略）。
- `--resume` 与 `--quiet` 不进入配置。
- `config_dir` 不进入配置（只能由 flag 或默认决定）。

## Further Notes

- 密钥明文落盘是用户显式选择：README 与 `--help` 需加醒目风险提示，且程序自身仍绝不写盘。
- 本文件与 `--help` 的产品文档地位一致：新增/改动 flag、退出码、默认行为时，`--help`、README、`docs/` 三处需同步。
- 配置加载复用既有 cjson 依赖，JSON 解析边界集中在配置加载单元，避免散落各处的手写解析。
