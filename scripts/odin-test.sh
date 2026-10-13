#!/usr/bin/env bash
# 跑 Odin 单元测试。
#
# 说明：某些沙箱环境里，当被测包目录位于当前工作目录子树内时，测试进程会被限制文件写入
# （轨迹/配置/技能测试需要写临时目录）。因此这里先 cd 到 build/ 再以相对路径跑测试，
# 让包目录不在 cwd 子树内。普通环境下等价于 `odin test odin -vet`。
#
# 用法：bash scripts/odin-test.sh [额外的 odin test 参数]
#       ODIN=/path/to/odin bash scripts/odin-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
cd build

ODIN_BIN="${ODIN:-odin}"
exec "$ODIN_BIN" test ../odin -vet "$@"
