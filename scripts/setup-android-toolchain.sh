#!/usr/bin/env bash
#
# setup-android-toolchain.sh — 一键准备「脱离 Android 运行时」的 4 架构编译环境
# setup-android-toolchain.sh — One-shot setup for Android 4-ABI cross-compilation
#                              without any Android runtime
#
# ───────────────────────────────────────────────────────────────────────────
# 它会依次做三件事 / It performs three steps
# ───────────────────────────────────────────────────────────────────────────
#   1. 取 Termux 补丁源（仅 10 个 src 文件，约 36 KB）    [termux-go-fetch.sh]
#   2. 下载官方 Go 工具链（Linux host 版）并打上 Termux 补丁  [patch-goroot-termux.sh]
#   3. 校验 NDK 可用性（不下载，由用户自备）
#
# 然后你就可以用 android-cross-build.sh 编 4 架构。
#
# ───────────────────────────────────────────────────────────────────────────
# 必下 / 不必下（核心结论）/ What to fetch and what to skip
# ───────────────────────────────────────────────────────────────────────────
#
#   ✅ 必下 / Required
#      • Termux golang deb（1 个架构即可）→ 仅提取 10 个 src 文件（36 KB）
#      • 官方 Go 工具链（go.dev 的 linux-<arch> 包，非 Termux 版）
#      • Android NDK —— 用户自备（不同版本内容不同，不予预设）
#
#   ❌ 不必下 / Not needed
#      • 另外 3 个架构的 Termux src        → 4 架构 src 完全相同（129 MB 零差异）
#      • Termux 的 bin/go、pkg/tool/*      → bionic ELF，纯 Linux 下无法执行
#      • Termux 的 clang/llvm/libc++/sysroot → NDK 已提供，且 Termux 版是 bionic
#      • Termux bootstrap-*.zip            → Termux 根文件系统，与本方案无关
#
# ───────────────────────────────────────────────────────────────────────────
# 用法 / Usage
# ───────────────────────────────────────────────────────────────────────────
#
#   ./setup-android-toolchain.sh [选项]
#
#   -o, --out DIR      工作目录（默认 ./android-toolchain）
#   -n, --ndk DIR      NDK 路径（仅用于校验；不指定则自动探测）
#   -G, --go-version V Go 版本（默认自动取 Termux 包同版本，例如 1.27.1）
#   -a, --arch ABI     取补丁源的架构（默认 aarch64，行为等价）
#   -m, --mirror URL   Go 下载镜像（默认 https://dl.google.com/go）
#   --skip-termux      不打 Termux 补丁（用官方原生 stdlib）
#   --skip-go          不下载 Go（复用环境里已有的）
#   --check            只做环境检查
#   -h, --help         帮助
#
set -euo pipefail

OUT_DIR="./android-toolchain"
NDK_DIR="${ANDROID_NDK_HOME:-}"
GO_VERSION=""
PATCH_ARCH="aarch64"
GO_MIRROR="https://dl.google.com/go"
SKIP_TERMUX=0
SKIP_GO=0
CHECK_ONLY=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)          OUT_DIR="$2"; shift 2 ;;
        -n|--ndk)          NDK_DIR="$2"; shift 2 ;;
        -G|--go-version)   GO_VERSION="$2"; shift 2 ;;
        -a|--arch)         PATCH_ARCH="$2"; shift 2 ;;
        -m|--mirror)       GO_MIRROR="${2%/}"; shift 2 ;;
        --skip-termux)     SKIP_TERMUX=1; shift ;;
        --skip-go)         SKIP_GO=1; shift ;;
        --check)           CHECK_ONLY=1; shift ;;
        -h|--help)         usage ;;
        *) die "未知参数: $1（-h 查看帮助）" ;;
    esac
done

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# host 架构判定 / determine host arch
case "$(uname -m)" in
    x86_64|amd64)  HOST_GOARCH="amd64" ;;
    aarch64|arm64) HOST_GOARCH="arm64" ;;
    armv7l|armv6l) HOST_GOARCH="armv6l" ;;
    *) die "不支持的构建机架构: $(uname -m)" ;;
esac
case "$(uname -s)" in
    Linux)  GOOS_PART="linux" ;;
    Darwin) GOOS_PART="darwin" ;;
    *) die "不支持的系统: $(uname -s)" ;;
esac

log "构建机 / host : $(uname -s) $(uname -m)  ->  go ${GOOS_PART}-${HOST_GOARCH}"
log "工作目录 / out: $OUT_DIR"
echo

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 1：取 Termux 补丁源 / Step 1: fetch Termux patch sources
# ═══════════════════════════════════════════════════════════════════════════
PATCH_SRC="$OUT_DIR/patch-src"

if [[ $SKIP_TERMUX -eq 1 ]]; then
    log "步骤 1/3  跳过 Termux 补丁（--skip-termux）"
    warn "不加补丁：产物会读 /etc/resolv.conf，在 Android 上 DNS 可能失败"
else
    log "步骤 1/3  获取 Termux 补丁源（仅 10 个文件）"
    if [[ -f "$PATCH_SRC/net/dnsclient_android.go" ]]; then
        ok "补丁源已存在 / already present: $PATCH_SRC"
    else
        if [[ -x "$SCRIPT_DIR/termux-go-fetch.sh" ]]; then
            bash "$SCRIPT_DIR/termux-go-fetch.sh" -a "$PATCH_ARCH" -o "$OUT_DIR" 2>&1 \
                | sed 's/^/    /'
            # termux-go-fetch.sh 把结果放在 <out>/patch-src
            [[ -f "$PATCH_SRC/net/dnsclient_android.go" ]] \
                || die "补丁源生成失败"
            ok "补丁源就绪 / patch sources ready"
        else
            die "缺少 termux-go-fetch.sh（应与本脚本同目录）"
        fi
    fi
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 2：准备官方 Go 并打补丁 / Step 2: official Go + patches
# ═══════════════════════════════════════════════════════════════════════════
GOROOT_DST="$OUT_DIR/goroot"

if [[ $SKIP_GO -eq 1 ]]; then
    log "步骤 2/3  跳过 Go 下载（--skip-go）"
    if [[ -n "${GOROOT:-}" && -d "$GOROOT" ]]; then
        ok "复用现有 GOROOT: $GOROOT"
    else
        warn "环境里没有 GOROOT，后续需手动指定 GOROOT="
    fi
else
    # 若未指定版本，尝试从 Termux 包的 VERSION 推断
    if [[ -z "$GO_VERSION" && -f "$OUT_DIR/../MANIFEST.txt" ]]; then
        GO_VERSION="$(sed -n 's/^包版本 \/ pkg version : [0-9]*:\(.*\)$/\1/p' "$OUT_DIR/../MANIFEST.txt" 2>/dev/null | head -1)"
    fi
    if [[ -z "$GO_VERSION" && -f "$OUT_DIR/MANIFEST.txt" ]]; then
        GO_VERSION="$(sed -n 's/^包版本 \/ pkg version : [0-9]*:\(.*\)$/\1/p' "$OUT_DIR/MANIFEST.txt" 2>/dev/null | head -1)"
    fi
    if [[ -z "$GO_VERSION" ]]; then
        warn "无法自动确定 Go 版本，回退到 1.27.1（应为 Termux 包同版本）"
        GO_VERSION="1.27.1"
    fi

    log "步骤 2/3  准备官方 Go $GO_VERSION（${GOOS_PART}-${HOST_GOARCH}）"
    TARBALL="go${GO_VERSION}.${GOOS_PART}-${HOST_GOARCH}.tar.gz"
    TARBALL_PATH="$OUT_DIR/$TARBALL"

    if [[ -x "$GOROOT_DST/bin/go" ]] && "$GOROOT_DST/bin/go" version >/dev/null 2>&1; then
        ok "GOROOT 已就绪 / already prepared: $("$GOROOT_DST/bin/go" version)"
    else
        if [[ ! -s "$TARBALL_PATH" ]]; then
            log "下载 / downloading: $GO_MIRROR/$TARBALL"
            curl -fL --retry 3 --connect-timeout 30 \
                 "$GO_MIRROR/$TARBALL" -o "$TARBALL_PATH.part" \
                || die "Go 下载失败（可换 --mirror，如 https://golang.google.cn/dl）"
            mv "$TARBALL_PATH.part" "$TARBALL_PATH"
        fi
        ok "已下载 / downloaded: $(du -h "$TARBALL_PATH" | cut -f1)"

        rm -rf "$GOROOT_DST"
        mkdir -p "$GOROOT_DST"
        tar -xzf "$TARBALL_PATH" -C "$GOROOT_DST" --strip-components=1
        chmod -R u+w "$GOROOT_DST" 2>/dev/null || true
        ok "解压完成 / extracted: $("$GOROOT_DST/bin/go" version)"
    fi
fi
echo

# 打补丁 / apply patches
if [[ $SKIP_TERMUX -eq 0 && $SKIP_GO -eq 0 ]]; then
    if [[ -f "$GOROOT_DST/.termux-patch-applied" ]]; then
        ok "补丁已应用 / patches already applied"
    else
        log "应用 Termux 补丁 / applying Termux patches"
        bash "$SCRIPT_DIR/patch-goroot-termux.sh" \
            -g "$GOROOT_DST" -s "$PATCH_SRC" 2>&1 | sed 's/^/    /'
        ok "补丁完成 / patched"
    fi
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 3：校验 NDK / Step 3: validate NDK
# ═══════════════════════════════════════════════════════════════════════════
log "步骤 3/3  校验 Android NDK（不下载，用户自备）"

if [[ -x "$SCRIPT_DIR/android-cross-build.sh" ]]; then
    chk_args=(--check)
    [[ -n "$NDK_DIR" ]] && chk_args+=(-n "$NDK_DIR")
    [[ -n "${GOROOT_DST:-}" && -d "$GOROOT_DST" ]] && chk_args+=(-g "$GOROOT_DST")
    bash "$SCRIPT_DIR/android-cross-build.sh" "${chk_args[@]}" 2>&1 | sed 's/^/    /' || {
        warn "NDK 校验未通过 —— 请准备 NDK 后用 -n 指定路径"
    }
else
    warn "缺少 android-cross-build.sh"
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
# 完成提示 / Done
# ═══════════════════════════════════════════════════════════════════════════
if [[ $CHECK_ONLY -eq 1 ]]; then
    log "仅检查模式完成 / check-only finished"
    exit 0
fi

log "环境准备完成 / setup complete"
echo
echo "  补丁源 / patch src : $PATCH_SRC"
echo "  GOROOT / goroot    : $GOROOT_DST"
echo "  NDK    / ndk       : ${NDK_DIR:-<请用 -n 指定>}"
echo
echo "  编译 4 架构 / build all 4 ABIs:"
echo "    $SCRIPT_DIR/android-cross-build.sh \\"
echo "        -n <NDK路径> -g \"$GOROOT_DST\" -o ./android-out --tags no_ui"
echo
echo "  提示 / tips:"
echo "    • Go 版本必须与 Termux 补丁同版本，否则可能缺 internal 包"
echo "    • NDK 版本由用户自行选择；不同版本 sysroot/clang 内容不同"
echo "    • arm64 若不需要 Termux 补丁，可加 --static-arm64 出纯静态产物"
