#!/usr/bin/env bash
#
# setup-android-toolchain.sh - one-shot setup for Android 4-ABI cross
#                              compilation without any Android runtime
#
# ---------------------------------------------------------------------------
# It performs three steps
# ---------------------------------------------------------------------------
#   1. Fetch the Termux patch sources (ten src files, about 36 KB)
#      -> termux-go-fetch.sh
#   2. Download the official Go toolchain (Linux host build) and apply the
#      Termux patches to it
#      -> patch-goroot-termux.sh
#   3. Validate the NDK (it is not downloaded; the user provides it)
#
#   Afterwards, build with android-cross-build.sh.
#
# ---------------------------------------------------------------------------
# What to fetch and what to skip
# ---------------------------------------------------------------------------
#
#   Required:
#     * Termux golang deb (ONE architecture is enough) - ten src files, 36 KB
#     * Official Go toolchain (the go.dev linux-<arch> build, not Termux's)
#     * Android NDK - user-provided; releases differ, nothing is assumed
#
#   NOT needed:
#     * the other three architectures' Termux src - identical (129 MB, no diff)
#     * Termux bin/go and pkg/tool/* - bionic ELF, cannot run on plain Linux
#     * Termux clang/llvm/libc++/sysroot - the NDK provides these
#     * the Termux bootstrap zip - a Termux rootfs, unrelated here
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   ./setup-android-toolchain.sh [options]
#
#   -o, --out DIR        working directory (default ./android-toolchain)
#   -n, --ndk DIR        NDK path (validated only; auto-detected if omitted)
#   -G, --go-version V   Go version (default: match the Termux package)
#   -a, --arch ABI       architecture for the patch source (default aarch64)
#   -m, --mirror URL     Go download mirror (default https://dl.google.com/go)
#   --skip-termux        do not apply the Termux patches (upstream stdlib)
#   --skip-go            do not download Go (reuse one already present)
#   --check              check the environment only
#   -h, --help           show this help
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
        *) die "unknown argument: $1 (use -h for help)" ;;
    esac
done

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# determine the host arch
case "$(uname -m)" in
    x86_64|amd64)  HOST_GOARCH="amd64" ;;
    aarch64|arm64) HOST_GOARCH="arm64" ;;
    armv7l|armv6l) HOST_GOARCH="armv6l" ;;
    *) die "unsupported host architecture: $(uname -m)" ;;
esac
case "$(uname -s)" in
    Linux)  GOOS_PART="linux" ;;
    Darwin) GOOS_PART="darwin" ;;
    *) die "unsupported operating system: $(uname -s)" ;;
esac

log "host : $(uname -s) $(uname -m)  ->  go ${GOOS_PART}-${HOST_GOARCH}"
log "out  : $OUT_DIR"
echo

# ═══════════════════════════════════════════════════════════════════════════
# ---- step 1: fetch the Termux patch sources ----
# ═══════════════════════════════════════════════════════════════════════════
PATCH_SRC="$OUT_DIR/patch-src"

if [[ $SKIP_TERMUX -eq 1 ]]; then
    log "step 1/3  skipping the Termux patches (--skip-termux)"
    warn "without the patches the binary reads /etc/resolv.conf, which does" 
    warn "not exist on Android, so DNS lookups are likely to fail"
else
    log "step 1/3  fetching the Termux patch sources (10 files)"
    if [[ -f "$PATCH_SRC/net/dnsclient_android.go" ]]; then
        ok "patch sources already present: $PATCH_SRC"
    else
        if [[ -x "$SCRIPT_DIR/termux-go-fetch.sh" ]]; then
            bash "$SCRIPT_DIR/termux-go-fetch.sh" -a "$PATCH_ARCH" -o "$OUT_DIR" 2>&1 \
                | sed 's/^/    /'
            # termux-go-fetch.sh puts its result in <out>/patch-src
            [[ -f "$PATCH_SRC/net/dnsclient_android.go" ]] \
                || die "failed to produce the patch sources"
            ok "patch sources ready"
        else
            die "termux-go-fetch.sh is missing (it should sit next to this script)"
        fi
    fi
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
# ---- step 2: official Go plus the patches ----
# ═══════════════════════════════════════════════════════════════════════════
GOROOT_DST="$OUT_DIR/goroot"

if [[ $SKIP_GO -eq 1 ]]; then
    log "step 2/3  skipping the Go download (--skip-go)"
    if [[ -n "${GOROOT:-}" && -d "$GOROOT" ]]; then
        ok "reusing the existing GOROOT: $GOROOT"
    else
        warn "no GOROOT in the environment; you will have to pass GOROOT= yourself"
    fi
else
    # no version given: try to infer it from the Termux package version
    if [[ -z "$GO_VERSION" && -f "$OUT_DIR/../MANIFEST.txt" ]]; then
        GO_VERSION="$(sed -n 's/^包版本 \/ pkg version : [0-9]*:\(.*\)$/\1/p' "$OUT_DIR/../MANIFEST.txt" 2>/dev/null | head -1)"
    fi
    if [[ -z "$GO_VERSION" && -f "$OUT_DIR/MANIFEST.txt" ]]; then
        GO_VERSION="$(sed -n 's/^包版本 \/ pkg version : [0-9]*:\(.*\)$/\1/p' "$OUT_DIR/MANIFEST.txt" 2>/dev/null | head -1)"
    fi
    if [[ -z "$GO_VERSION" ]]; then
        warn "could not determine the Go version; falling back to 1.27.1"
        warn "(it should match the version of the Termux package)"
        GO_VERSION="1.27.1"
    fi

    log "step 2/3  preparing official Go $GO_VERSION (${GOOS_PART}-${HOST_GOARCH})"
    TARBALL="go${GO_VERSION}.${GOOS_PART}-${HOST_GOARCH}.tar.gz"
    TARBALL_PATH="$OUT_DIR/$TARBALL"

    if [[ -x "$GOROOT_DST/bin/go" ]] && "$GOROOT_DST/bin/go" version >/dev/null 2>&1; then
        ok "GOROOT already prepared: $("$GOROOT_DST/bin/go" version)"
    else
        if [[ ! -s "$TARBALL_PATH" ]]; then
            log "downloading: $GO_MIRROR/$TARBALL"
            curl -fL --retry 3 --connect-timeout 30 \
                 "$GO_MIRROR/$TARBALL" -o "$TARBALL_PATH.part" \
                || die "Go download failed (try --mirror, e.g. https://golang.google.cn/dl)"
            mv "$TARBALL_PATH.part" "$TARBALL_PATH"
        fi
        ok "downloaded: $(du -h "$TARBALL_PATH" | cut -f1)"

        rm -rf "$GOROOT_DST"
        mkdir -p "$GOROOT_DST"
        tar -xzf "$TARBALL_PATH" -C "$GOROOT_DST" --strip-components=1
        chmod -R u+w "$GOROOT_DST" 2>/dev/null || true
        ok "extracted: $("$GOROOT_DST/bin/go" version)"
    fi
fi
echo

# apply the patches
if [[ $SKIP_TERMUX -eq 0 && $SKIP_GO -eq 0 ]]; then
    if [[ -f "$GOROOT_DST/.termux-patch-applied" ]]; then
        ok "patches already applied"
    else
        log "applying the Termux patches"
        bash "$SCRIPT_DIR/patch-goroot-termux.sh" \
            -g "$GOROOT_DST" -s "$PATCH_SRC" 2>&1 | sed 's/^/    /'
        ok "patched"
    fi
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
# ---- step 3: validate the NDK ----
# ═══════════════════════════════════════════════════════════════════════════
log "step 3/3  validating the Android NDK (not downloaded; user-provided)"

if [[ -x "$SCRIPT_DIR/android-cross-build.sh" ]]; then
    chk_args=(--check)
    [[ -n "$NDK_DIR" ]] && chk_args+=(-n "$NDK_DIR")
    [[ -n "${GOROOT_DST:-}" && -d "$GOROOT_DST" ]] && chk_args+=(-g "$GOROOT_DST")
    bash "$SCRIPT_DIR/android-cross-build.sh" "${chk_args[@]}" 2>&1 | sed 's/^/    /' || {
        warn "NDK validation failed; prepare an NDK and point -n at it"
    }
else
    warn "android-cross-build.sh is missing"
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
# ---- done ----
# ═══════════════════════════════════════════════════════════════════════════
if [[ $CHECK_ONLY -eq 1 ]]; then
    log "check-only run finished"
    exit 0
fi

log "setup complete"
echo
echo "  patch src : $PATCH_SRC"
echo "  GOROOT / goroot    : $GOROOT_DST"
echo "  ndk       : ${NDK_DIR:-<pass -n to set it>}"
echo
echo "  build all four ABIs:"
echo "    $SCRIPT_DIR/android-cross-build.sh \\"
echo "        -n <NDK> -g \"$GOROOT_DST\" -o ./android-out --tags no_ui"
echo
echo "  tips:"
echo "    - the Go version must match the Termux patch source, or internal"
echo "      packages it relies on may be missing"
echo "    - pick any NDK you like; different releases ship different sysroots"
echo "      and clang builds"
echo "    - arm64 can be built without the patches via --static-arm64, which"
echo "      produces a fully static binary"
