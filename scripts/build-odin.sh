#!/usr/bin/env bash
# 构建 Odin 版 llmcli：Odin 只编译不链接（-build-mode:obj），再由 zig cc 链接成 exe。
#
# 为什么链接不用 gcc：
#   Odin 的 windows_amd64 目标只有 MSVC ABI 一种，产物里用 __chkstk、__GSHandlerCheck
#   这类 MSVC 符号，vendor:curl 的 libcurl.lib 又是 MSVC 静态库（.drectve 里写着
#   /DEFAULTLIB:LIBCMT /DEFAULTLIB:OLDNAMES）。GNU ld 既过不了 Odin 的
#   IMAGE_REL_AMD64_SECREL 重定位，也没有 MSVC CRT；MinGW/llvm-mingw 的 gnu 目标同样
#   会挂在 libLIBCMT.a / libOLDNAMES.a 上。
#   zig cc 内部是 clang + lld，自带 MSVC CRT 导入库，配 `-target x86_64-windows-msvc`
#   即可原样吃掉 Odin 产物和 libcurl.lib。
#
# 依赖：odin、zig。
#
# 环境变量覆盖：
#   ODIN      odin 可执行文件（默认 odin）
#   ZIG       zig 可执行文件（默认 zig）
#   OBJ_DIR   目标文件目录（默认 <repo>/build/obj-odin）
#   OUTPUT    产物路径（默认 <repo>/build/llmcli-odin.exe）
#   ZIG_LIBS  链接库列表，空格分隔（默认见下；以 `odin build odin -print-linker-flags`
#             打印出的库清单为准）

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"

ODIN="${ODIN:-odin}"
ZIG="${ZIG:-zig}"
obj_dir="${OBJ_DIR:-$root/build/obj-odin}"
output="${OUTPUT:-$root/build/llmcli-odin.exe}"

command -v "$ODIN" >/dev/null 2>&1 || { echo "找不到 odin：$ODIN" >&2; exit 1; }
command -v "$ZIG" >/dev/null 2>&1 || { echo "找不到 zig：$ZIG" >&2; exit 1; }

# Odin 发行版里的 curl 库。`odin root` 在 Windows 上返回 `D:\app\odin-dist\`：先统一成
# 正斜杠、再去掉尾部分隔符，避免拼出 `.../vendor\curl/lib/...` 这种混合路径。
odin_root="$("$ODIN" root)"          # 形如 D:\app\odin-dist\
odin_root="${odin_root//\\//}"       # 反斜杠 -> 正斜杠
odin_root="${odin_root%/}"           # 去掉尾部分隔符
curl_lib="$odin_root/vendor/curl/lib/libcurl.lib"
[ -f "$curl_lib" ] || { echo "找不到 libcurl.lib：$curl_lib" >&2; exit 1; }

# Windows 系统库 + curl。清单来自 `odin build odin -print-linker-flags`。
read -r -a libs <<<"${ZIG_LIBS:-kernel32 bcrypt ntdll advapi32 ole32 shell32 user32 \
    crypt32 normaliz secur32 wldap32 ws2_32 iphlpapi}"

# 1. Odin 只编译不链接。-o:speed 隐含 -use-single-module，整个程序出一个 .obj，
#    链接这一步就只有一个输入文件。产物仍含 Odin 运行时（含入口）。
mkdir -p "$obj_dir"
obj="$obj_dir/llmcli.obj"
"$ODIN" build "$root/odin" \
    -build-mode:obj -o:speed -use-single-module \
    -out:"$obj"

# 2. zig cc 链接。注意几点：
#    - `-target x86_64-windows-msvc` 是必须的：默认的 gnu 目标没有 MSVC CRT。
#    - 在 obj 目录里链接，pdb 用相对名落地，避免 zig 的 /pdb: 参数被 Git Bash
#      当成路径改写（绝对路径会被 MSYS 拆坏）。ld 仍会写出一个几 MB 的 .pdb，
#      这里把它关进 obj 目录。
#    - output 用绝对路径，MSYS 会把它转成 Windows 路径。
(
    cd "$obj_dir"
    "$ZIG" cc -target x86_64-windows-msvc \
        "$(basename "$obj")" -o "$output" \
        -Wl,/pdb:llmcli-odin.pdb \
        "${libs[@]/#/-l}" \
        "$curl_lib"
)

echo "生成 $output（链接器：zig cc，目标 x86_64-windows-msvc）"

# 3. 自检：确认链接进来的是静态 libcurl，产物不依赖 libcurl DLL。
if command -v objdump >/dev/null 2>&1; then
    if objdump -p "$output" | grep -qi "DLL Name:.*libcurl"; then
        echo "错误：产物仍依赖 libcurl DLL" >&2
        exit 1
    fi
fi
