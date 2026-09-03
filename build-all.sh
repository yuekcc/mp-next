#!/usr/bin/env bash
set -euo pipefail

# 切到脚本所在目录，无论从哪调用都能找到 project.json
cd "$(dirname "$0")"

# 提取 project.json 中 targets 下的所有目标名（用 jq 稳健解析 JSON）
mapfile -t TARGETS < <(jq -r '.targets | keys[]' project.json)

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "No targets found in project.json" >&2
  exit 1
fi

for t in "${TARGETS[@]}"; do
  echo ">> building target: $t"
  c3c build "$t"
done

echo "All targets built."
