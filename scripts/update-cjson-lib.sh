#!/bin/bash
# 重新生成 cJSON 的 MSVC 静态库 lib/cjson.c3l/windows-x64/cjson.lib。
#
# 只用 lib/cjson.c3l/src/ 下的 cJSON.c / cJSON.h 编译：
#   zig cc -target x86_64-windows-msvc   # 借本机 VS 的头文件，产出 MSVC COFF 目标文件
#   zig lib                              # 打包成 MSVC 兼容的 .lib
# 供 `c3c build`（windows-x64，内部是 lld-link）静态链接使用。
#
# 依赖：zig；目标是 windows-msvc，需要本机装有 Visual Studio（Zig 会自动探测）。
#
# 可用环境变量覆盖：
#   ZIG       zig 可执行文件（默认 zig）
#   OUT_LIB   产物路径（默认 lib/cjson.c3l/windows-x64/cjson.lib）

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"

ZIG="${ZIG:-zig}"
src_dir="$root/lib/cjson.c3l/src"
out_lib="${OUT_LIB:-$root/lib/cjson.c3l/windows-x64/cjson.lib}"
out_dir="$(dirname "$out_lib")"

src="$src_dir/cJSON.c"
hdr="$src_dir/cJSON.h"

[ -f "$src" ] && [ -f "$hdr" ] || { echo "找不到 cJSON 源码：$src_dir" >&2; exit 1; }
command -v "$ZIG" >/dev/null 2>&1 || { echo "找不到 zig：$ZIG" >&2; exit 1; }
mkdir -p "$out_dir"

# zig 是原生 Windows 程序：路径要 Windows 风格；MSYS 的 /out: 参数转换要关掉。
to_win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

# 工作目录放在产物旁边，保证 zig 能访问（不要用 mktemp 的 /tmp）。
work="$out_dir/.cjson-lib-work"
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

# 1. 编译 cJSON.c。缺省就是 CJSON_EXPORT_SYMBOLS（__declspec(dllexport)），
#    与原库一致；要更干净可加 -DCJSON_HIDE_SYMBOLS。
"$ZIG" cc -target x86_64-windows-msvc -O3 \
    -c "$(to_win "$src")" \
    -I "$(to_win "$src_dir")" \
    -o "$(to_win "$work/cJSON.obj")"

# 2. 打包成静态库。在 obj 目录里跑，让成员名保持 cJSON.obj（不带路径）。
tmp_lib="$work/cjson.lib"
( cd "$work" && MSYS2_ARG_CONV_EXCL='*' "$ZIG" lib "/out:$(to_win "$tmp_lib")" cJSON.obj )

# 3. 自检：成员在、导出符号在。
if command -v objdump >/dev/null 2>&1; then
    syms="$(objdump -t "$tmp_lib" 2>/dev/null || true)"
    grep -q "cJSON_Version" <<<"$syms" || {
        echo "生成结果里找不到 cJSON_Version，库不对" >&2
        exit 1
    }
fi

# 4. 替换并报告。
mv -f "$tmp_lib" "$out_lib"
echo "已更新 $out_lib"
echo "  源码：$src（+ cJSON.h）"
