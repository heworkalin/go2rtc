#!/usr/bin/env bash
#
# android-cross-build.sh — 完全脱离 Android 运行时，交叉编译 4 架构 Android 产物
# android-cross-build.sh — Cross-compile 4 Android ABIs without any Android runtime
#
# ═══════════════════════════════════════════════════════════════════════════
# 结论 / Conclusion（已在本机与远端 arm64 Linux 双重实测）
# ═══════════════════════════════════════════════════════════════════════════
#
#   Go 工具链对 android/* 的链接方式有一条硬编码规则
#   （见 cmd/go/internal/work/init.go: mustUseExternalLinker）：
#
#     GOOS=android GOARCH=arm64  -> 允许 CGO_ENABLED=0（纯静态，NEEDED 为空）
#     GOOS=android GOARCH=arm    -> 必须 CGO_ENABLED=1（external linking）
#     GOOS=android GOARCH=386    -> 必须 CGO_ENABLED=1
#     GOOS=android GOARCH=amd64  -> 必须 CGO_ENABLED=1
#
#   因此 **只有 arm64 能纯 Go 编**；其余 3 个架构若 CGO_ENABLED=0 会直接报：
#       loadinternal: cannot find runtime/cgo
#       link: running gcc failed
#   这是 Go 设计如此，不是环境缺失。
#
#   要编 4 架构，唯一稳妥做法：**一律 CGO_ENABLED=1 + Android NDK clang**。
#
# ─── 为什么用 NDK 而不是 Termux 工具链 ───────────────────────────────────
#
#   Termux 的 go / clang 是 bionic ELF：
#       interpreter = /system/bin/linker64
#       NEEDED      = libc.so(bionic), libLLVM.so, libclang-cpp.so ...
#   → 只能在「有 Android 系统库 + linker」的环境跑；
#     纯 Linux / chroot / 容器 / CI 里无法执行（即便能跑也需要 /system 可见）。
#
#   NDK 的 clang 是普通 Linux ELF：
#       interpreter = /lib/ld-linux-aarch64.so.1（或 x86_64 对应）
#       NEEDED      = libc.so.6, libm.so.6 ...（标准 glibc）
#       且自带 sysroot（含 libc.so / liblog.so / libdl.so / libm.so）
#   → 在任何 Linux 上都能跑，**完全不需要 Android 运行时**。
#
#   两种途径链接出的产物 ABI 完全一致（都是 bionic 动态链接 +
#   /system/bin/linker），所以 NDK 方案不会有兼容性差异。
#
# ─── 关于“与 Termux 原始运行时相似度” ───────────────────────────────────
#
#   产物层面：两者都产出 Android ELF，运行时都依赖设备 /system 的 bionic，
#   因此运行行为一致。
#   唯一差别是「编译期 sysroot 来自谁」：
#     NDK sysroot   : 自包含、可离线、跨机器可复现  ← 推荐
#     Termux sysroot: 不含 libc.so（靠设备提供），只适合在 Termux 内编译
#   若确实需要 Termux 那 4 处 stdlib 补丁（resolv.conf/cert.pem/mdns/tmp），
#   用 --termux-goroot 指定 Termux 的 GOROOT 即可（见下）。
#
# ═══════════════════════════════════════════════════════════════════════════
# 用法 / Usage
# ═══════════════════════════════════════════════════════════════════════════
#
#   ./android-cross-build.sh [选项] -- [额外 go build 参数]
#
#   -n, --ndk DIR        NDK 路径（默认自动探测 ANDROID_NDK_HOME / ~/Android/Sdk/ndk/*）
#   -o, --out DIR        输出目录（默认 ./android-out）
#   -t, --api NUM        Android API level（默认 24）
#   -a, --arch LIST      目标 ABI，逗号分隔（默认全部 4 个）
#   -g, --goroot DIR     指定 GOROOT（如 Termux 的 lib/go）；默认用 PATH 里的 go
#   -p, --package SPEC   要编译的包（默认 .）
#   -b, --basename NAME  产物前缀（默认取包名或 app）
#   -P, --prefix NAME    .so 文件名前缀（默认 lib）
#   --tags TAGS          传给 go build 的 tags
#   --ldflags FLAGS      覆盖默认 ldflags
#   --static-arm64       arm64 用 CGO_ENABLED=0 纯静态（其余仍 cgo）
#   --check              只做环境检查，不编译
#   -h, --help           帮助
#
# 例 / Examples:
#   ./android-cross-build.sh -n ~/ndk -o out --tags no_ui
#   ./android-cross-build.sh --static-arm64 -o out
#   ./android-cross-build.sh -a arm64-v8a,armeabi-v7a
#
set -euo pipefail

# ---------- 默认值 / Defaults ----------
OUT_DIR="./android-out"
NDK_DIR="${ANDROID_NDK_HOME:-}"
API=24
ARCHES="arm64-v8a,armeabi-v7a,x86,x86_64"
GOROOT_OVERRIDE=""
PKG_SPEC="."
BASENAME=""
SO_PREFIX="lib"
TAGS=""
LDFLAGS_OVERRIDE=""
STATIC_ARM64=0
CHECK_ONLY=0
EXTRA_ARGS=()

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }

usage() { sed -n '2,90p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--ndk)      NDK_DIR="$2"; shift 2 ;;
        -o|--out)      OUT_DIR="$2"; shift 2 ;;
        -t|--api)      API="$2"; shift 2 ;;
        -a|--arch)     ARCHES="$2"; shift 2 ;;
        -g|--goroot)   GOROOT_OVERRIDE="$2"; shift 2 ;;
        -p|--package)  PKG_SPEC="$2"; shift 2 ;;
        -b|--basename) BASENAME="$2"; shift 2 ;;
        -P|--prefix)   SO_PREFIX="$2"; shift 2 ;;
        --tags)        TAGS="$2"; shift 2 ;;
        --ldflags)     LDFLAGS_OVERRIDE="$2"; shift 2 ;;
        --static-arm64) STATIC_ARM64=1; shift ;;
        --check)       CHECK_ONLY=1; shift ;;
        -h|--help)     usage ;;
        --)            shift; EXTRA_ARGS=("$@"); break ;;
        *)             EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# ---------- 1. 定位 Go / Locate Go ----------
log "检查 Go 工具链 / checking Go toolchain"
if [[ -n "$GOROOT_OVERRIDE" ]]; then
    GO_BIN="$GOROOT_OVERRIDE/bin/go"
    [[ -x "$GO_BIN" ]] || die "GOROOT 里没有 bin/go: $GOROOT_OVERRIDE"
    export GOROOT="$GOROOT_OVERRIDE"
else
    GO_BIN="$(command -v go || true)"
    [[ -n "$GO_BIN" ]] || die "找不到 go，请安装 Go 或用 -g 指定 GOROOT"
fi

GO_VER="$("$GO_BIN" version 2>/dev/null || echo unknown)"
log "  $GO_VER"

# Go 版本要求（go2rtc 需要 1.24+；一般项目 1.21+）
GOVER_NUM="$(echo "$GO_VER" | sed -n 's/.*go\([0-9]*\.[0-9]*\).*/\1/p')"
if [[ -n "$GOVER_NUM" ]]; then
    major="${GOVER_NUM%%.*}"; minor="${GOVER_NUM##*.}"
    if (( major == 1 && minor < 21 )); then
        warn "Go $GOVER_NUM 较老：不支持 -checklinkname，且可能无法处理 go 1.24 的 go.mod"
    fi
fi

# ---------- 2. 定位 NDK / Locate NDK ----------
log "检查 Android NDK / checking NDK"
find_ndk() {
    local best="" ver=-1 cand v
    local cands=(
        "$NDK_DIR" "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"
        "${ANDROID_HOME:-}/ndk/"* "${ANDROID_SDK_ROOT:-}/ndk/"*
        "$HOME/Android/Sdk/ndk/"* "$HOME/Library/Android/sdk/ndk/"*
        /opt/android-ndk* /usr/local/android-ndk* "$HOME/android-ndk"*
    )
    for cand in "${cands[@]}"; do
        [[ -n "$cand" && -d "$cand/toolchains/llvm/prebuilt" ]] || continue
        v="$(basename "$cand" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        v="${v:-0}"
        if [[ -z "$best" ]] || [[ "$(printf '%s\n%s\n' "$ver" "$v" | sort -V | tail -1)" == "$v" ]]; then
            best="$cand"; ver="$v"
        fi
    done
    [[ -n "$best" ]] && { echo "$best"; return 0; }
    return 1
}

if [[ -z "$NDK_DIR" ]]; then
    NDK_DIR="$(find_ndk)" || die "找不到 Android NDK。设置 ANDROID_NDK_HOME，或用 -n 指定。"
fi
[[ -d "$NDK_DIR/toolchains/llvm/prebuilt" ]] || die "无效的 NDK: $NDK_DIR"

# host 工具链
case "$(uname -s)" in
    Linux)  HOST_OS="linux" ;;
    Darwin) HOST_OS="darwin" ;;
    *)      die "不支持的系统: $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  HOST_ARCH="x86_64" ;;
    aarch64|arm64) HOST_ARCH="arm64" ;;
    *)             die "不支持的构建机架构: $(uname -m)" ;;
esac

PREBUILT="$NDK_DIR/toolchains/llvm/prebuilt/${HOST_OS}-${HOST_ARCH}"
if [[ ! -d "$PREBUILT/bin" ]]; then
    for alt in "${HOST_OS}-${HOST_ARCH}" "${HOST_OS}-x86_64" "${HOST_OS}-arm64"; do
        [[ -d "$NDK_DIR/toolchains/llvm/prebuilt/$alt/bin" ]] && PREBUILT="$NDK_DIR/toolchains/llvm/prebuilt/$alt" && break
    done
fi
[[ -d "$PREBUILT/bin" ]] || die "NDK 缺少 host 工具链: $PREBUILT"

CLANG="$PREBUILT/bin/clang"
[[ -x "$CLANG" ]] || die "clang 不存在: $CLANG"

# 关键检查：clang 必须是普通 Linux ELF 且能在本机执行
if ! "$CLANG" --version >/dev/null 2>&1; then
    bad "clang 无法执行: $CLANG"
    die "该 NDK 的 host 工具链与本机不兼容（请用匹配 uname -m 的 NDK）"
fi
ok "NDK     : $NDK_DIR"
ok "host    : ${HOST_OS}-${HOST_ARCH}"
ok "clang   : $("$CLANG" --version 2>/dev/null | head -1)"

# 验证 clang 是纯 Linux（脱离 Android 运行时）
CLANG_INTERP="$(readelf -l "$(readlink -f "$CLANG")" 2>/dev/null | sed -n 's/.*interpreter: \([^]]*\)\]/\1/p' | head -1)"
if [[ -n "$CLANG_INTERP" ]]; then
    if [[ "$CLANG_INTERP" == /system/* ]]; then
        warn "clang 解释器是 Android linker ($CLANG_INTERP) —— 未脱离 Android 运行时"
    else
        ok "clang 解释器: $CLANG_INTERP （纯 Linux，无需 Android）"
    fi
fi

# 确认 sysroot 自包含（NDK 自带 libc.so）
SYSROOT="$PREBUILT/sysroot"
if [[ -f "$SYSROOT/usr/lib/aarch64-linux-android/$API/libc.so" ]]; then
    ok "sysroot : $SYSROOT （自包含，含 libc.so/liblog.so/libdl.so）"
else
    warn "sysroot 缺少 API $API 的 libc.so，可能影响链接"
fi

# ---------- 3. 架构映射 / ABI mapping ----------
# 输出: goarch|goarm|ndk_triple_prefix
arch_spec() {
    case "$1" in
        arm64-v8a)    echo "arm64||aarch64-linux-android" ;;
        armeabi-v7a)  echo "arm|7|armv7a-linux-androideabi" ;;
        arm)          echo "arm|7|armv7a-linux-androideabi" ;;
        x86)          echo "386||i686-linux-android" ;;
        i686)         echo "386||i686-linux-android" ;;
        x86_64)       echo "amd64||x86_64-linux-android" ;;
        amd64)        echo "amd64||x86_64-linux-android" ;;
        *)            return 1 ;;
    esac
}

# ---------- 4. 检查模式 / Check-only mode ----------
if [[ $CHECK_ONLY -eq 1 ]]; then
    echo
    log "环境检查完成 / environment check complete"
    echo
    echo "  构建机 : $(uname -s) $(uname -m)"
    echo "  Go     : $GO_VER"
    echo "  NDK    : $NDK_DIR"
    echo "  工具链 : $PREBUILT"
    echo "  sysroot: $SYSROOT"
    echo
    echo "  ABI            Go 目标        编译器"
    echo "  -------------  -------------  ------------------------------------"
    IFS=',' read -r -a _al <<< "$ARCHES"
    for abi in "${_al[@]}"; do
        spec="$(arch_spec "$abi" 2>/dev/null)" || { printf '  %-13s  (未知 ABI)\n' "$abi"; continue; }
        ga="${spec%%|*}"; r="${spec#*|}"; garm="${r%%|*}"; triple="${r##*|}"
        cc="${triple}${API}-clang"
        # 检查模式也应加上 NDK bin 再查找编译器
        ccp="$(PATH="$PREBUILT/bin:$PATH" command -v "$cc" 2>/dev/null || echo '未找到')"
        printf '  %-13s  %-13s  %s\n' "$abi" "android/${ga}${garm:+ GOARM=$garm}" "$ccp"
    done
    exit 0
fi

# ---------- 5. 准备输出 / Prepare output ----------
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
export PATH="$PREBUILT/bin:$PATH"

[[ -n "$BASENAME" ]] || BASENAME="$(basename "$(cd "$PKG_SPEC" 2>/dev/null && pwd || echo app)")"
[[ "$PKG_SPEC" == "." ]] && [[ -z "${BASENAME:-}" ]] && BASENAME="app"

if [[ -z "$LDFLAGS_OVERRIDE" ]]; then
    LDFLAGS_VAL="-checklinkname=0 -s -w"
    # Go < 1.23 不支持 -checklinkname
    if [[ -n "${GOVER_NUM:-}" ]] && (( ${GOVER_NUM##*.} < 23 )); then
        LDFLAGS_VAL="-s -w"
    fi
else
    LDFLAGS_VAL="$LDFLAGS_OVERRIDE"
fi

echo
log "配置 / Configuration"
echo "  输出目录 / out   : $OUT_DIR"
echo "  API level        : $API"
echo "  Go binary        : $GO_BIN"
echo "  ldflags          : $LDFLAGS_VAL"
echo "  tags             : ${TAGS:-<none>}"
echo "  arm64 纯静态     : $([[ $STATIC_ARM64 -eq 1 ]] && echo yes || echo no)"
echo

# ---------- 6. 编译 / Build ----------
RESULT=()
FAILED=0

IFS=',' read -r -a ARCH_LIST <<< "$ARCHES"
for abi in "${ARCH_LIST[@]}"; do
    spec="$(arch_spec "$abi")" || { warn "未知 ABI: $abi，跳过"; FAILED=1; continue; }
    goarch="${spec%%|*}"; rest="${spec#*|}"; goarm="${rest%%|*}"; triple="${rest##*|}"

    # 选择编译器（arm32 的 triple 前缀在不同 NDK 里有差异）
    cc=""
    for cand in "${triple}${API}-clang" \
                "${triple}${API}-clang.exe" \
                "arm-linux-androideabi${API}-clang" \
                "armv7a-linux-androideabi${API}-clang"; do
        if command -v "$cand" >/dev/null 2>&1; then cc="$cand"; break; fi
    done
    if [[ -z "$cc" ]]; then
        bad "$abi: 找不到编译器 (${triple}${API}-clang)"
        FAILED=1; continue
    fi

    out_path="$OUT_DIR/${SO_PREFIX}${BASENAME}_${abi}.so"
    err_file="$OUT_DIR/.err_$abi"

    # 决定 CGO 与静态策略
    cgo=1
    if [[ $STATIC_ARM64 -eq 1 && "$goarch" == "arm64" ]]; then
        cgo=0
    fi

    env_args=(GOOS=android GOARCH="$goarch")
    [[ -n "$goarm" ]] && env_args+=(GOARM="$goarm")
    if [[ $cgo -eq 1 ]]; then
        env_args+=(CGO_ENABLED=1 CC="$cc")
        cxx="${cc}++"
        command -v "$cxx" >/dev/null 2>&1 && env_args+=(CXX="$cxx")
    else
        env_args+=(CGO_ENABLED=0)
    fi

    build_args=(-trimpath)
    [[ -n "$TAGS" ]] && build_args+=(-tags "$TAGS")
    build_args+=(-ldflags="$LDFLAGS_VAL")
    build_args+=("${EXTRA_ARGS[@]}")
    build_args+=(-o "$out_path" "$PKG_SPEC")

    printf '  %-13s [%s] android/%-5s CGO=%s ... ' "$abi" "$(basename "$cc")" "$goarch" "$cgo"
    if env "${env_args[@]}" "$GO_BIN" build "${build_args[@]}" 2>"$err_file"; then
        size=$(stat -c%s "$out_path" 2>/dev/null || stat -f%z "$out_path")
        elf="$(file -b "$out_path" | cut -d, -f1-2)"
        need="$(readelf -d "$out_path" 2>/dev/null | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | tr '\n' '+' | sed 's/+$//')"
        printf '\033[1;32mOK\033[0m  %.2f MB\n' "$(echo "$size/1048576" | bc -l)"
        printf '                %s\n' "$elf"
        printf '                NEEDED=%s\n' "${need:-<none, 纯静态>}"
        RESULT+=("$abi|$out_path|$size|${need:-static}")
        rm -f "$err_file"
    else
        printf '\033[1;31mFAIL\033[0m\n'
        sed 's/^/                /' "$err_file" | head -10
        FAILED=1
    fi
done

# ---------- 7. 汇总 / Summary ----------
echo
log "汇总 / Summary"
echo "  ┌────────────────┬──────────────────────────────────────────────┐"
printf '  │ %-14s │ %-44s │\n' "ABI" "产物 / Artifact"
echo "  ├────────────────┼──────────────────────────────────────────────┤"
for r in "${RESULT[@]:-}"; do
    [[ -n "$r" ]] || continue
    IFS='|' read -r abi path size need <<< "$r"
    name="$(basename "$path")"
    printf '  │ %-14s │ %-44s │\n' "$abi" "$name"
done
echo "  └────────────────┴──────────────────────────────────────────────┘"
echo
echo "  嵌入 APK / Embed into APK:"
for r in "${RESULT[@]:-}"; do
    [[ -n "$r" ]] || continue
    IFS='|' read -r abi path size need <<< "$r"
    printf '    %-13s -> jniLibs/%s/\n' "$abi" "$abi"
done

if [[ $FAILED -ne 0 ]]; then
    die "部分架构失败 / some ABIs failed"
fi
log "全部成功 / all ABIs built OK"
