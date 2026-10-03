#!/bin/bash
# llmcli 实际用法示例：用 shellm 式 RLM 循环完成一个真实任务。
#
# 模型会写 ```bash 代码块，llmcli 执行后把输出回填，循环直到代码里设置
# FINAL / FINAL_FILE 才收尾——bash 就是它唯一的工具。
#
# 配置走环境变量，均可覆盖：
#   LLMCLI_API_KEY   必填，端点密钥
#   LLMCLI_API_URL   选填，默认 OpenAI 官方端点
#   LLMCLI_MODEL     选填，默认 gpt-4o-mini
#   LLMCLI_CONFIG    选填，会话根目录（默认 ./build/demo）

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exe="$script_dir/build/llmcli"
[ -x "$exe" ] || exe="$script_dir/build/llmcli.exe"
if [ ! -x "$exe" ]; then
    echo "找不到 build/llmcli，请先 c3c build" >&2
    exit 1
fi

: "${LLMCLI_API_KEY:?请设置 LLMCLI_API_KEY（例如 export LLMCLI_API_KEY=sk-...）}"
api_url="${LLMCLI_API_URL:-https://api.openai.com/v1/chat/completions}"
model="${LLMCLI_MODEL:-gpt-4o-mini}"
config="${LLMCLI_CONFIG:-$script_dir/build/demo}"

session_id="demo_$(date +%s)"
echo "会话 $session_id，模型 $model，会话文件 $config/sessions/$session_id.jsonl" >&2

# 任务：先让模型自己数清 src 目录里有多少个 C3 源文件，再设 FINAL 收尾。
# 它得先跑 find/wc 之类的命令拿到真实数字——单轮问答给不出这个数。
"$exe" \
    --config-dir "$config" \
    --api-url "$api_url" \
    --model "$model" \
    --api-key "$LLMCLI_API_KEY" \
    --session-id "$session_id" \
    --debug \
    "统计 $script_dir/src 目录下 .c3 源文件的个数，用 FINAL=\"数量是 N 个\" 给出答案"
