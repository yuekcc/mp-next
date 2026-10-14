#!/bin/bash
# llmcli 实际用法示例：用 shellm 式 RLM 循环完成一个真实任务。
#
# 模型会写 ```bash 代码块，llmcli 执行后把输出回填，循环直到代码里设置
# FINAL / FINAL_FILE 才收尾——bash 就是它唯一的工具。
#
# 持久偏好默认放仓库根的 llmcli.json（api_key / api_url / model / max_iterations / traj_dir），
# 由 --config-dir 读取。下面的环境变量若设置，则作为本次运行对配置的覆盖（flag 优先级高于配置）：
#   LLMCLI_API_KEY   选填，覆盖配置里的 api_key
#   LLMCLI_API_URL   选填，覆盖 api_url
#   LLMCLI_MODEL     选填，覆盖 model
#   LLMCLI_MAX_ITERATIONS 选填，覆盖 max_iterations
#   LLMCLI_CONFIG_DIR 选填，配置文件所在目录（默认脚本所在仓库根）
#   LLMCLI_TRAJ_DIR  选填，轨迹根目录（默认 <repo>/build/demo/traj）
#   LLMCLI_CONFIG    选填，演示基目录（默认 <repo>/build/demo），其 /traj 即默认轨迹根
#   LLMCLI_IMPL      选填，实现：c3（默认）| odin
#   LLMCLI_BIN       选填，直接指定二进制路径（优先于 LLMCLI_IMPL）
#   LLMCLI_RUN_DIR   选填，把二进制暂存到哪个目录再运行（默认 <repo>/tmp）
#   LLMCLI_NO_STAGE  选填，设 1 表示不暂存、直接运行所选二进制

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

# 执行目录：某些沙箱只允许从特定目录（如仓库 tmp/）执行会派生子进程（bash）的二进制。
# 默认把所选二进制复制到 <repo>/tmp 下再运行；LLMCLI_RUN_DIR 可改，LLMCLI_NO_STAGE=1 关闭。
if [ -z "${LLMCLI_NO_STAGE:-}" ]; then
    run_dir="${LLMCLI_RUN_DIR:-$script_dir/tmp}"
    mkdir -p "$run_dir"
    staged="$run_dir/$(basename "$exe")"
    if [ "$exe" != "$staged" ]; then
        cp -f "$exe" "$staged"
    fi
    exe="$staged"
fi

# 持久偏好默认放仓库根的 llmcli.json；run.sh 用 --config-dir 读它。
# 下面的环境变量若设置，则作为本次运行对配置的覆盖（flag 优先级高于配置）。
config_dir="${LLMCLI_CONFIG_DIR:-$script_dir}"
demo_base="${LLMCLI_CONFIG:-$script_dir/build/demo}"
traj_root="${LLMCLI_TRAJ_DIR:-$demo_base/traj}"
traj_id="demo_$(date +%s)"

args=(--config-dir "$config_dir" --traj-dir "$traj_root" --traj "$traj_id" --debug)
if [ -n "${LLMCLI_API_URL:-}" ]; then args+=(--api-url "$LLMCLI_API_URL"); fi
if [ -n "${LLMCLI_MODEL:-}" ]; then args+=(--model "$LLMCLI_MODEL"); fi
if [ -n "${LLMCLI_API_KEY:-}" ]; then args+=(--api-key "$LLMCLI_API_KEY"); fi
if [ -n "${LLMCLI_MAX_ITERATIONS:-}" ]; then args+=(--max-iterations "$LLMCLI_MAX_ITERATIONS"); fi

echo "轨迹 $traj_id，配置目录 $config_dir，轨迹目录 $traj_root/$traj_id" >&2

# 任务：先让模型自己数清 src 目录里有多少个 C3 源文件，再设 FINAL 收尾。
# 它得先跑 find/wc 之类的命令拿到真实数字——单轮问答给不出这个数。
"$exe" "${args[@]}" \
    "统计 $script_dir/src 目录下 .c3 源文件的个数，用 FINAL=\"数量是 N 个\" 给出答案"
