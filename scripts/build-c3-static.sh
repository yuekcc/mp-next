#!/bin/bash
# 全静态构建：c3c 只出目标文件（.o），再由 C 编译器全静态链接成单个 exe，
# 产物不再依赖 libcurl-x64.dll（仅剩 Windows 自带系统 DLL）。
#
# 默认链接器用 zig cc（内部是 clang + lld，自带 mingw-w64，不需装 MSVC）。
#
# 依赖：c3c、zig，以及仓库根的 curl-8.22.0_3-win64-mingw 预编译库。
#
# 可用环境变量覆盖：
#   C3C        c3c 可执行文件（默认 c3c）
#   CC         链接用 C 编译器命令（默认 "zig cc"，也可 CC=gcc）
#   CURL_DIR   curl 预编译包目录（默认 <repo>/curl-8.22.0_3-win64-mingw）
#   OBJ_DIR    目标文件输出目录（默认 build/obj-static）
#   OUTPUT     产物路径（默认 build/llmcli-static.exe）

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"

C3C="${C3C:-c3c}"
curl_dir="${CURL_DIR:-$root/curl-8.22.0_3-win64-mingw}"
obj_dir="${OBJ_DIR:-$root/build/obj-static}"
output="${OUTPUT:-$root/build/llmcli-static.exe}"

# CC 可能带参数（如 "zig cc"），按词拆成数组再调用。
if [ -n "${CC:-}" ]; then
    read -r -a cc_cmd <<<"$CC"
else
    cc_cmd=(zig cc)
fi
cc_str="${cc_cmd[*]}"

curl_lib="$curl_dir/lib"
if [ ! -d "$curl_lib" ]; then
    echo "找不到 curl 预编译库：$curl_lib" >&2
    exit 1
fi
command -v "$C3C" >/dev/null 2>&1 || { echo "找不到 c3c：$C3C" >&2; exit 1; }
command -v "${cc_cmd[0]}" >/dev/null 2>&1 || { echo "找不到编译器：$cc_str" >&2; exit 1; }

# 1. c3c 只编译，不出可执行文件。-O3 隐含单模块，内联更充分。
#    curl / cjson 的 c3l manifest 没有 mingw-x64 目标，直接喂接口源码绕开 c3l；
#    链接这一环完全交给下面的编译器。
rm -rf "$obj_dir"
mkdir -p "$obj_dir"
"$C3C" compile-only \
    "$root"/src/*.c3 \
    "$root"/cmd/llmcli.c3 \
    "$root"/lib/curl.c3l/curl.c3i \
    "$root"/lib/cjson.c3l/cjson.c3i \
    "$root"/lib/cjson.c3l/wrapper.c3 \
    --target mingw-x64 --single-module=yes -O3 \
    --obj-out "$obj_dir"

# 2. cJSON 是 C 源，单独编成 .o。
"${cc_cmd[@]}" -c "$root/lib/cjson.c3l/src/cJSON.c" -o "$obj_dir/cJSON.obj" \
    -O3 -I "$root/lib/cjson.c3l/src"

# 3. CFG 垫片：curl 的静态库是开着 Control Flow Guard 编的，间接调用都走
#    __guard_dispatch_icall_fptr，需要 __guard_dispatch_icall_dummy 兜底。
#    mingw-w64 自己带这个符号，但 zig 0.17 打包的 mingw-w64 漏了，会报
#    "undefined symbol: __guard_dispatch_icall_dummy"。补一个等价的 `jmp *%rax`
#    （语义与 mingw-w64 的 guard_dispatch.S 一致）；用 gcc 链接时留着也无害。
cat > "$obj_dir/cfguard-shim.S" <<'EOF'
	.text
	.globl	__guard_dispatch_icall_dummy
	.def	__guard_dispatch_icall_dummy;	.scl 2;	.type 32;	.endef
__guard_dispatch_icall_dummy:
	jmp	*%rax
EOF
"${cc_cmd[@]}" -c "$obj_dir/cfguard-shim.S" -o "$obj_dir/cfguard-shim.obj"

# 4. 静态链接。curl 及其依赖一律传 .a 全路径，避免 ld 优先挑到同目录的
#    libcurl.dll.a（DLL 导入库）而悄悄依赖 libcurl-x64.dll。
#    -municode 对应 c3c 生成的 wmain 入口；末尾是 Windows 系统库（系统 DLL 本就动态）。
#    不加 -flto：目标文件都不是 LTO 字节码，加了没用，反而会让 zig cc 链上它自己的
#    LTO runtime 而缺 fdiml / nanl。
"${cc_cmd[@]}" -municode -static \
    -o "$output" \
    -O3 -g0 -Wl,--gc-sections \
    "$obj_dir"/*.obj \
    "$curl_lib/libcurl.a" \
    "$curl_lib/libssh2.a" \
    "$curl_lib/libssl.a" \
    "$curl_lib/libcrypto.a" \
    "$curl_lib/libpsl.a" \
    "$curl_lib/libnghttp2.a" \
    "$curl_lib/libnghttp3.a" \
    "$curl_lib/libngtcp2.a" \
    "$curl_lib/libngtcp2_crypto_libressl.a" \
    "$curl_lib/libz.a" \
    "$curl_lib/libzstd.a" \
    "$curl_lib/libbrotlidec.a" \
    "$curl_lib/libbrotlicommon.a" \
    -ldbghelp -lshlwapi -lws2_32 -lbcrypt -lcrypt32 -lsecur32 -lnormaliz -liphlpapi -lwldap32

echo "生成 $output（链接器：$cc_str）"

# 5. 自检：确认产物没有拖上 libcurl DLL。
if command -v objdump >/dev/null 2>&1; then
    if objdump -p "$output" | grep -qi "DLL Name:.*libcurl"; then
        echo "错误：产物仍依赖 libcurl DLL" >&2
        exit 1
    fi
fi
