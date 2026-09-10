#!/bin/sh
# 用 Android NDK 交叉编译本仓库为 Android 可执行文件（dhcp6c）。
#
# 本脚本位于 fork 内，构建产物是给「Android DHCPv6 客户端模块」用的二进制。
# 之所以不用 autotools：
#   1) 仓库自带的 config.sub 是 2008 年的，不认识 aarch64-*，--host 直接报
#      "Invalid configuration"；
#   2) configure 依赖 AC_PROG_YACC/LEX 生成 cfparse.c / cftoken.c。
# 与其修 autotools，不如把 configure 探测出的结果直接写成 -D 传给 clang。
# 这些宏的含义见本仓库的 configure.ac，改动时请对照更新。
#
# 用法:
#   sh android/build.sh                                  # 默认 arm64-v8a
#   sh android/build.sh --abi arm64-v8a,armeabi-v7a
#   sh android/build.sh --out /tmp/out                   # 指定产物目录
#   sh android/build.sh --prefix /data/adb/dhcp6c        # 编译期 sysconfdir/localdbdir
#   sh android/build.sh --ndk /path/to/ndk --wfb /path/to/winflexbison
#
# 依赖:
#   - Android NDK (r25+ 均可)。优先取 $ANDROID_NDK_HOME，其次自动探测常见位置，
#     也可以用 --ndk 指定。
#   - bison / flex：仓库不提交预生成的 parser。优先用 PATH 里的，
#     否则找 WinFlexBison 便携版（https://github.com/lexxmark/winflexbison/releases），
#     可用 --wfb 指定目录。

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)		# 仓库根目录，源码就在这里
SRC="$ROOT"

# --- 默认值（全部可被命令行/环境变量覆盖，仓库里不写死个人路径）---
NDK=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
WFB=${WFB:-}
API=24
ABIS="arm64-v8a"
OUTDIR="$ROOT/android/dist"
PREFIX="/data/adb/dhcp6c"
PUSH=0
ADB=${ADB:-adb}

while [ $# -gt 0 ]; do
    case "$1" in
        --ndk)    NDK="$2";    shift 2 ;;
        --wfb)    WFB="$2";    shift 2 ;;
        --api)    API="$2";    shift 2 ;;
        --abi)    ABIS="$2";   shift 2 ;;
        --out)    OUTDIR="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --push)   PUSH=1;      shift ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

abort() { echo "错误: $*" >&2; exit 1; }

# 自动探测 NDK：常见安装位置都试一遍，找不到再报错
if [ -z "$NDK" ]; then
    for c in /f/Programs/android-ndk-r* \
             "$HOME/Android/Sdk/ndk/"* \
             "$HOME/Library/Android/sdk/ndk/"* \
             /opt/android-ndk* /usr/local/android-ndk*; do
        if [ -d "$c" ]; then NDK="$c"; break; fi
    done
fi
[ -n "$NDK" ] && [ -d "$NDK" ] \
    || abort "找不到 NDK。请设 ANDROID_NDK_HOME 或用 --ndk 指定"

# clang 在 Windows 下是原生程序，不认 Git Bash 的 /f/... 形式路径，
# 统一经 cygpath -m 转成 F:/...。真实 Linux/macOS 上没有 cygpath，原样用。
winpath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# --- 定位 NDK 工具链 ---
TC=""
for p in windows-x86_64 linux-x86_64 darwin-x86_64; do
    if [ -d "$NDK/toolchains/llvm/prebuilt/$p/bin" ]; then
        TC="$NDK/toolchains/llvm/prebuilt/$p/bin"; break
    fi
done
[ -n "$TC" ] || abort "在 $NDK 下找不到工具链目录"

# --- 生成 cfparse.c / cftoken.c / y.tab.h（仓库不提交生成物）---
gen_parser() {
    [ -f "$SRC/cfparse.c" ] && [ -f "$SRC/cftoken.c" ] && [ -f "$SRC/y.tab.h" ] && return 0

    if command -v bison >/dev/null 2>&1; then
        BISON=$(command -v bison); FLEX=$(command -v flex)
    else
        [ -n "$WFB" ] || for c in /f/Programs/winflexbison "$HOME/winflexbison"; do
            [ -x "$c/win_bison.exe" ] && { WFB="$c"; break; }
        done
    fi
    if [ -z "${BISON:-}" ] && [ -n "$WFB" ] && [ -x "$WFB/win_bison.exe" ]; then
        BISON="$WFB/win_bison.exe"; FLEX="$WFB/win_flex.exe"
    fi
    [ -n "${BISON:-}" ] \
        || abort "需要 bison/flex。可下载 WinFlexBison 便携版并用 --wfb 指定目录"

    echo "生成 config parser ..."
    # -y 走 POSIX 兼容模式，输出 y.tab.c / y.tab.h，与 Makefile.in 的规则一致
    ( cd "$SRC" && "$BISON" -y -d cfparse.y 2>/dev/null && mv -f y.tab.c cfparse.c \
      && "$FLEX" cftoken.l 2>/dev/null && mv -f lex.yy.c cftoken.c )
    echo "  完成"
}

gen_parser

# --- 平台宏 ---
# 逐条对应 configure.ac 的探测结果，注释里给出"为什么是这个值"。
DEFS="-D_GNU_SOURCE"
DEFS="$DEFS -DTIME_WITH_SYS_TIME=1"   # AC_HEADER_TIME：两套 time 头都在，都要进
DEFS="$DEFS -DHAVE_ANSI_FUNC"         # C99 __func__
DEFS="$DEFS -DHAVE_CLOCK_GETTIME"     # AC_CHECK_FUNCS(clock_gettime)
DEFS="$DEFS -DHAVE_STDARG_H"
DEFS="$DEFS -DHAVE_STRLCPY -DHAVE_STRLCAT"   # bionic 自带
DEFS="$DEFS -DHAVE_SYS_TIME_H"
# 刻意不定义：
#   HAVE_SA_LEN          —— Linux 的 sockaddr 没有 sa_len 字段
#   HAVE_SCOPELIB        —— inet_zoneid() 是 BSD 专有；不定义则 if.c 走 linkid=ifindex，
#                           正好就是 AF_PACKET 需要的 sll_ifindex
#   HAVE_TAILQ_FOREACH_REVERSE* —— 由 common.h 自带兜底实现
#   INET6 / __KAME__     —— KAME 专有分支

CFLAGS="-O2 -Wall -Wno-unused-variable $DEFS"

OBJS="dhcp6c.o common.o config.o prefixconf.o dhcp6c_ia.o timer.o \
dhcp6c_script.o if.o base64.o auth.o addrconf.o lease.o cfparse.o cftoken.o"

echo "NDK      : $NDK"
echo "工具链   : $TC"
echo "API 级别 : $API"
echo "ABI      : $ABIS"
echo "产物目录 : $OUTDIR"
echo "前缀     : $PREFIX"
echo

mkdir -p "$OUTDIR"

for ABI in $(echo "$ABIS" | tr ',' ' '); do
    case "$ABI" in
        arm64-v8a)   TRIPLE=aarch64-linux-android ;;
        armeabi-v7a) TRIPLE=armv7a-linux-androideabi ;;
        x86_64)      TRIPLE=x86_64-linux-android ;;
        x86)         TRIPLE=i686-linux-android ;;
        *) abort "不支持的 ABI: $ABI" ;;
    esac
    CC="$TC/${TRIPLE}${API}-clang"
    [ -x "$CC" ] || CC="$TC/${TRIPLE}${API}-clang.cmd"
    [ -x "$CC" ] || abort "找不到编译器 $TRIPLE$API-clang"

    OUT="$ROOT/android/build/$ABI"
    mkdir -p "$OUT"

    SRC_W=$(winpath "$SRC")
    OUT_W=$(winpath "$OUT")

    echo "[$ABI] 编译中 ..."
    FAILED=0
    NAMES=$(echo "$OBJS" | sed 's/\.o//g')
    for f in $NAMES; do
        if ! "$CC" -c "$SRC_W/$f.c" -o "$OUT_W/$f.o" $CFLAGS -I"$SRC_W" \
             -DSYSCONFDIR="\"$PREFIX\"" -DLOCALDBDIR="\"$PREFIX\"" \
             -fPIE 2>"$OUT/$f.log"; then
            echo "  $f 失败:"
            grep -m5 "error:" "$OUT/$f.log" | sed 's/^/    /'
            FAILED=1
        fi
    done
    [ "$FAILED" = 0 ] || abort "$ABI 编译失败"

    OBJLIST=""
    for f in $NAMES; do OBJLIST="$OBJLIST $OUT_W/$f.o"; done
    "$CC" -o "$(winpath "$OUTDIR")/dhcp6c-$ABI" $OBJLIST -pie
    echo "  完成: $OUTDIR/dhcp6c-$ABI ($(wc -c < "$OUTDIR/dhcp6c-$ABI") 字节)"
done

if [ "$PUSH" = 1 ]; then
    for ABI in $(echo "$ABIS" | tr ',' ' '); do
        echo "推送 $OUTDIR/dhcp6c-$ABI -> /data/local/tmp/dhcp6c"
        "$ADB" push "$OUTDIR/dhcp6c-$ABI" /data/local/tmp/dhcp6c
        "$ADB" shell "chmod 755 /data/local/tmp/dhcp6c"
    done
fi
