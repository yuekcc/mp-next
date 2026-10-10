#!/bin/bash
# 重新生成 MSVC 兼容的 curl 导入库 libcurl-x64.lib。
#
# 用 `zig lib`（LLVM 的 lib.exe 替代品）从 curl 预编译包里的 DLL 导出表生成，
# 产物与 MSVC `lib.exe` 同格式（带 __IMPORT_DESCRIPTOR_libcurl-x64 那一套），
# 供 `c3c build`（MSVC 动态链接）使用。
#
# .def 来源优先级：环境变量 DEF_SRC > 包内 bin/libcurl-x64.def > gendef 从 DLL 反推。
# 包内那份 def 没有 LIBRARY 行，脚本会补上。
#
# 依赖：zig（提供 `zig lib`）；回退路径需要 gendef。
#
# 可用环境变量覆盖：
#   ZIG       zig 可执行文件（默认 zig）
#   CURL_DIR  curl 预编译包目录（默认 <repo>/curl-8.22.0_3-win64-mingw）
#   DEF_SRC   指定 .def（默认见上）
#   OUT_LIB   产物路径（默认 lib/curl.c3l/windows-x64/libcurl-x64.lib）

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"

ZIG="${ZIG:-zig}"
curl_dir="${CURL_DIR:-$root/curl-8.22.0_3-win64-mingw}"
out_lib="${OUT_LIB:-$root/lib/curl.c3l/windows-x64/libcurl-x64.lib}"

dll="$curl_dir/bin/libcurl-x64.dll"
def_src="${DEF_SRC:-$curl_dir/bin/libcurl-x64.def}"
dll_base="$(basename "$dll" .dll)"          # libcurl-x64
out_dir="$(dirname "$out_lib")"

[ -f "$dll" ] || { echo "找不到 DLL：$dll" >&2; exit 1; }
command -v "$ZIG" >/dev/null 2>&1 || { echo "找不到 zig：$ZIG" >&2; exit 1; }
mkdir -p "$out_dir"

# zig / gendef 都是原生 Windows 程序：路径要 Windows 风格；MSYS 的 /def: 参数转换要关掉。
to_win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

# 工作目录放在产物旁边，保证 zig 能访问（不要用 mktemp 的 /tmp）。
work="$out_dir/.implib-work"
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

# 1. 准备带 LIBRARY 行的 .def。
def="$work/$dll_base.def"
if [ -f "$def_src" ]; then
    if grep -qiE '^[[:space:]]*LIBRARY' "$def_src"; then
        cp "$def_src" "$def"
    else
        { echo "LIBRARY $dll_base"; cat "$def_src"; } > "$def"
    fi
    def_from="$def_src"
else
    command -v gendef >/dev/null 2>&1 || {
        echo "没有 $def_src，也没有 gendef 可从 DLL 反推 .def" >&2
        exit 1
    }
    ( cd "$work" && gendef "$(to_win "$dll")" >/dev/null )
    def_from="gendef（从 $(basename "$dll") 反推）"
fi
grep -qiE '^[[:space:]]*EXPORTS' "$def" || { echo "def 缺少 EXPORTS：$def" >&2; exit 1; }

# 2. 生成导入库（先落工作目录，成功后再替换，避免失败时弄坏现有 .lib）。
tmp_lib="$work/$dll_base.lib"
MSYS2_ARG_CONV_EXCL='*' "$ZIG" lib \
    "/def:$(to_win "$def")" \
    /machine:x64 \
    "/out:$(to_win "$tmp_lib")"

# 3. 自检：确认是 MSVC 长格式（有 __IMPORT_DESCRIPTOR_<dll>）。
if command -v objdump >/dev/null 2>&1; then
    syms="$(objdump -t "$tmp_lib" 2>/dev/null || true)"
    if ! grep -q "__IMPORT_DESCRIPTOR_$dll_base" <<<"$syms"; then
        echo "生成结果缺少 __IMPORT_DESCRIPTOR_$dll_base，格式不对" >&2
        exit 1
    fi
fi

# 4. 替换并报告。
mv -f "$tmp_lib" "$out_lib"
echo "已更新 $out_lib"
echo "  def 来源：$def_from"
echo "  对应 DLL：$dll"
