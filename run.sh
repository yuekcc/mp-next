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
#   LLMCLI_CONFIG    选填，轨迹根目录（默认 ./build/demo/traj）
#   LLMCLI_IMPL      选填，实现：c3（默认）| odin
#   LLMCLI_BIN       选填，直接指定二进制路径（优先于 LLMCLI_IMPL）

set -exo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 选实现：LLMCLI_BIN 直接指定；否则按 LLMCLI_IMPL 在 build/ 下找对应产物。
if [ -n "${LLMCLI_BIN:-}" ]; then
    exe="$LLMCLI_BIN"
elif [ "${LLMCLI_IMPL:-c3}" = "odin" ]; then
    exe="$script_dir/build/llmcli-odin.exe"
    [ -x "$exe" ] || exe="$script_dir/build/llmcli-odin"
else
    exe="$script_dir/build/llmcli"
    [ -x "$exe" ] || exe="$script_dir/build/llmcli.exe"
fi
if [ ! -x "$exe" ]; then
    echo "找不到可执行文件 $exe（LLMCLI_IMPL=${LLMCLI_IMPL:-c3}）" >&2
    echo "  C3：  c3c build" >&2
    echo "  Odin：odin build odin -out:build/llmcli-odin.exe" >&2
    exit 1
fi

: "${LLMCLI_API_KEY:?请设置 LLMCLI_API_KEY（例如 export LLMCLI_API_KEY=sk-...）}"
api_url="${LLMCLI_API_URL:-http://localhost:8788/v1/chat/completions}"
model="${LLMCLI_MODEL:-hy3}"
config="${LLMCLI_CONFIG:-$script_dir/build/demo}"
api_key="${LLMCLI_API_KEYL:-sk-1234}"

traj_id="demo_$(date +%s)"
echo "轨迹 $traj_id，模型 $model，轨迹目录 $config/traj/$traj_id" >&2

# 任务：先让模型自己数清 src 目录里有多少个 C3 源文件，再设 FINAL 收尾。
# 它得先跑 find/wc 之类的命令拿到真实数字——单轮问答给不出这个数。
"$exe" \
    --traj-dir "$config/traj" \
    --api-url "$api_url" \
    --model "$model" \
    --api-key "$api_key" \
    --traj "$traj_id" \
    --debug \
    "统计 $script_dir/src 目录下 .c3 源文件的个数，用 FINAL=\"数量是 N 个\" 给出答案"
