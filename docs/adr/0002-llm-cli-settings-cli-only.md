# llm CLI 配置面收口为纯命令行开关（删除环境变量读取）

2026-09-05 llm CLI（`cmd/llm.c3`）删除全部环境变量读取，配置只来自命令行开关。

决定：

- 接口设置全部开关化：`--api-url`（完整 chat-completions 端点，缺省 OpenAI）、
  `--api-key`（可省略，本地服务不发 Authorization）、`--extra-body`、`-m/--model`。
- 默认模型链（LLM_MODEL / SHELLM_MODEL / 有 key 则 gpt-5.5）删除；无 `-m` 且无
  `--api-url` 直接报错，只给 `--api-url` 时请求不带 model 字段（服务器默认模型兜底）。
- usage/ledger 落盘开关化：`--usage-file`（缺省临时文件，成功后删除）、`--ledger`
  （缺省固定 `~/.headlong/usage/llm.jsonl`，HEADLONG_HOME/SHELLM_HOME/IDENTITY_DIR/
  LLM_USAGE_LEDGER 不再参与）。
- ledger 行元数据裁剪：provider 写死 `chat-completions`；identity/run_id 字段随
  LLM_PROVIDER/IDENTITY_NAME/LLM_RUN_ID/SHELLM_RUN_STEP_ID 一并删除。
- 系统级读取也清掉：TEMP/TMPDIR 交给 std `path::temp_directory`，HOME 交给
  `path::home_directory`。`cmd/llm.c3` 不再调用 `env::tget_var`。

为什么：llm 常被当作子进程拉起（`mem search`、run_llm.sh、agent 化的演进方向）。
配置经环境变量隐式继承时，调用方无法从命令行看出一次调用打到哪个端点/模型，也无从
为同进程内的多次调用切换配置；env 与 CLI 双轨并存时优先级规则藏在代码里。收口后配置
流单一显式：谁拉起 llm，谁用开关说清楚。`mem search` 随之改造——把自身配置（.memrc
/环境变量的 LLM_API_URL/LLM_API_KEY/SHELLM_FAST_MODEL）翻译成开关再 spawn，与
task_tool spawn mp 传 `--api-key`/`--base-url` 同一形态。

后续读者注意：

- 不要为"方便"恢复环境变量兜底（LLM_MODEL、OPENAI_API_KEY 等）——那是本决策明确
  否决的隐式配置源；需要时由调用方显式传开关。
- 旧 env 契约名（LLM_API_URL/LLM_EXTRA_BODY/LLM_USAGE_* 等）已全部失效，代码文案
  与文档不再引用。
- 收口的边界是 `llm` 二进制自身：`mem` 仍读自己的环境变量（MEM_DIR 等），
  `scripts/mock_llm.py` 仍用 LLM_MOCK_PORT，均不受影响。
