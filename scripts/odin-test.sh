#!/usr/bin/env bash
# 跑 Odin 单元测试。
#
# 说明：某些沙箱环境只允许从特定目录（如仓库 tmp/）执行「会派生子进程」的二进制——运行时
# 测试要起 bash，所以要 cd 到 tmp/ 再跑；同时该目录不在被测包（odin/）子树内，规避了
# 「包目录位于 cwd 子树内时禁止文件写入」的限制。普通环境下等价于 `odin test odin -vet`。
#
# 用法：bash scripts/odin-test.sh [额外的 odin test 参数]
#       ODIN=/path/to/odin bash scripts/odin-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p tmp
cd tmp

ODIN_BIN="${ODIN:-odin}"
# 单线程跑：测试共享进程级状态（temp 分配器、活动子进程等），并行会互相干扰。
exec "$ODIN_BIN" test ../odin -vet -define:ODIN_TEST_THREADS=1 "$@"
