#!/usr/bin/env bash
#
# termux-go-fetch.sh - fetch only the ESSENTIAL Termux Go resources
#
# ===========================================================================
# Design rationale
# ===========================================================================
#
#   Goal: supply the Termux standard-library patches needed to cross-compile
#         for Android with "official Go + NDK clang".
#         (DNS / CA / tmp / mDNS paths, patched for Android by Termux.)
#
#   Verified facts:
#
#   1. The src/ tree is IDENTICAL across all four architectures.
#      Compared aarch64 / arm / i686 / x86_64: the 129 MB of content matches,
#      with zero diff under net/. Only three architecture-specific files
#      differ, and this approach uses none of them:
#        src/cmd/cgo/zdefaultcc.go              default CC name (we pass CC=)
#        src/cmd/go/internal/cfg/zdefaultcc.go  same
#        src/internal/buildcfg/zbootstrap.go    defaultGO_LDSO (NDK sets it)
#      => Downloading ONE architecture is enough. The other three come from
#         the NDK toolchain and sysroot.
#
#   2. Termux's bin/go and pkg/tool/android_*/ are bionic ELF binaries
#      (interpreter /system/bin/linker64). They cannot run on plain Linux,
#      in a chroot, or in CI, so they are NOT downloaded at all.
#
#   3. What this approach actually needs is ten files under src/:
#        net/conf.go                   (modify: add !android constraint)
#        net/dnsclient_unix.go         (modify: add !android constraint)
#        net/interface_linux.go        (modify: add !android constraint)
#        syscall/netlink_linux.go      (modify: add !android constraint)
#        os/file_unix.go               (modify: tmp path)
#        crypto/x509/root_linux.go     (modify: CA path)
#      plus the four android-only files Termux adds:
#        net/conf_android.go
#        net/dnsclient_android.go
#        net/interface_android.go
#        syscall/netlink_android.go
#
#   So by default this script downloads ONE architecture's golang deb and
#   extracts only those ten files.
#
# ---------------------------------------------------------------------------
# What must and must not be downloaded
# ---------------------------------------------------------------------------
#
#   Required:
#     * Termux golang deb (one architecture) - source of the ten patch files
#     * Official Go toolchain (Linux host build) - from go.dev, NOT Termux
#       (the Termux build is bionic and cannot run outside Android)
#     * Android NDK - supplied by the user; releases differ, nothing assumed
#
#   NOT needed:
#     * the other three architectures' packages (identical src/, ~110 MB wasted)
#     * Termux bin/go and pkg/tool/android_*/ (bionic ELF; the NDK replaces them)
#     * Termux clang / llvm / libc++ (the NDK provides these)
#     * Termux ndk-sysroot (the NDK ships its own sysroot)
#     * the bootstrap zip (that is a Termux rootfs, unrelated here)
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   ./termux-go-fetch.sh [options]
#
#   -a, --arch ABI     architecture to pull (default aarch64; the src is the
#                      same either way, so this only affects download size)
#   -o, --out DIR      output directory (default ./termux-go-patch)
#   -m, --mirror URL   apt mirror (default the official one)
#   -c, --cache DIR    .deb cache (default ~/.cache/termux-go/debs)
#   --full-src         keep the whole src/ tree (default: only the ten files)
#   --print-files      list the required files and exit, without downloading
#   -h, --help         show this help
#
# Output:
#   <out>/patch-src/          the ten patch source files
#   <out>/goroot-src.tar.gz   archive of the above, ready for
#                             patch-goroot-termux.sh
#   <out>/MANIFEST.txt        file list and provenance notes
#
set -euo pipefail

ARCH="aarch64"
OUT_DIR="./termux-go-patch"
MIRROR="https://packages.termux.dev/apt/termux-main"
DEB_CACHE=""
FULL_SRC=0
PRINT_ONLY=0

PKG_NAME="golang"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,75p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--arch)     ARCH="$2"; shift 2 ;;
        -o|--out)      OUT_DIR="$2"; shift 2 ;;
        -m|--mirror)   MIRROR="${2%/}"; shift 2 ;;
        -c|--cache)    DEB_CACHE="$2"; shift 2 ;;
        --full-src)    FULL_SRC=1; shift ;;
        --print-files) PRINT_ONLY=1; shift ;;
        -h|--help)     usage ;;
        *) die "未知参数: $1（-h 查看帮助）" ;;
    esac
done

case "$ARCH" in
    aarch64|arm|i686|x86_64) ;;
    arm64) ARCH=aarch64 ;;
    *) die "不支持的架构: $ARCH（仅 aarch64/arm/i686/x86_64）" ;;
esac

# ---------- required file list ----------
# two groups: official files to modify, and the android files Termux adds
MODIFY_FILES=(
    "net/conf.go"
    "net/dnsclient_unix.go"
    "net/interface_linux.go"
    "syscall/netlink_linux.go"
    "os/file_unix.go"
    "crypto/x509/root_linux.go"
)
NEW_FILES=(
    "net/conf_android.go"
    "net/dnsclient_android.go"
    "net/interface_android.go"
    "syscall/netlink_android.go"
)
ALL_FILES=("${MODIFY_FILES[@]}" "${NEW_FILES[@]}")

if [[ $PRINT_ONLY -eq 1 ]]; then
    cat <<EOF
Termux Go source files needed by this approach (${#ALL_FILES[@]} total)

[files to modify]
$(for f in "${MODIFY_FILES[@]}"; do echo "  src/$f"; done)

[android-only files added by Termux]
$(for f in "${NEW_FILES[@]}"; do echo "  src/$f"; done)

[NOT needed]
  x bin/go, pkg/tool/android_*/      bionic ELF; the NDK replaces these
  x lib/, misc/                      unrelated to the patches
  x the other three ABI packages     src/ is identical across ABIs (129 MB)
  x Termux clang/llvm/libc++/sysroot the NDK provides these
  x bootstrap-*.zip                  a Termux rootfs, unrelated here
EOF
    exit 0
fi

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"; done; }
need curl tar ar

# ---------- cache directory ----------
if [[ -n "$DEB_CACHE" ]]; then
    DEB_CACHE="${DEB_CACHE%/}"
elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    DEB_CACHE="$XDG_CACHE_HOME/termux-go/debs"
else
    DEB_CACHE="${HOME:-/tmp}/.cache/termux-go/debs"
fi
mkdir -p "$DEB_CACHE"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

log "arch           : $ARCH (used only to pick src; all ABI trees are identical)"
log "cache          : $DEB_CACHE"
log "output         : $OUT_DIR"
echo

# ---------- 1. resolve the package URL from the apt index ----------
log "querying the apt index"
INDEX_URL="$MIRROR/dists/stable/main/binary-$ARCH/Packages"
INDEX_FILE="$DEB_CACHE/.Packages.$ARCH"

if [[ -s "$INDEX_FILE" ]] && [[ -n "$(grep -m1 '^Package: golang$' "$INDEX_FILE" 2>/dev/null)" ]]; then
    ok "index already cached"
else
    curl -fsSL --retry 3 --connect-timeout 20 "$INDEX_URL" -o "$INDEX_FILE.part" \
        || die "索引下载失败: $INDEX_URL"
    mv "$INDEX_FILE.part" "$INDEX_FILE"
    ok "index fetched"
fi

# parse Filename / SHA256 / Version / Size for golang
# Split on blank lines and pick the stanza for the target package.
parse_index() {
    awk -v want="$PKG_NAME" '
        BEGIN { RS = ""; }
        {
            lines = split($0, L, "\n")
            if (L[1] != "Package: " want) next
            for (i = 1; i <= lines; i++) {
                line = L[i]
                if (line ~ /^Filename: /)  { fn = substr(line, 11) }
                else if (line ~ /^SHA256: /) { sh = substr(line, 9) }
                else if (line ~ /^Version: /) { vr = substr(line, 10) }
                else if (line ~ /^Size: /)    { sz = substr(line, 7) }
            }
        }
        END { print fn "\t" sh "\t" vr "\t" sz }
    ' "$INDEX_FILE"
}

IFS=$'\t' read -r REL_PATH SHA256 VERSION SIZE < <(parse_index)
[[ -n "$REL_PATH" ]] || die "索引里找不到 $PKG_NAME 包"
ok "package        : golang $VERSION  ($(echo "$SIZE/1048576" | bc -l 2>/dev/null || echo '?') MB)"
echo

# ---------- 2. download the deb (cache and checksum) ----------
DEB_FILE="$DEB_CACHE/$(basename "$REL_PATH")"

if [[ -s "$DEB_FILE" ]] && echo "$SHA256  $DEB_FILE" | sha256sum -c --quiet 2>/dev/null; then
    ok "deb already cached and verified"
else
    log "downloading the golang deb"
    curl -fsSL --retry 3 --connect-timeout 30 "$MIRROR/$REL_PATH" -o "$DEB_FILE.part" \
        || die "deb 下载失败"
    mv "$DEB_FILE.part" "$DEB_FILE"
    echo "$SHA256  $DEB_FILE" | sha256sum -c --quiet 2>/dev/null \
        || die "SHA256 校验失败 / checksum mismatch"
    ok "downloaded and verified"
fi
echo

# ---------- 3. extract only the files we need ----------
log "extracting the selected files"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

( cd "$WORK" && ar x "$DEB_FILE" ) || die "ar 解包失败"
PAYLOAD="$(ls "$WORK"/data.tar.* 2>/dev/null | head -1)"
[[ -n "$PAYLOAD" ]] || die "deb 内没有 data.tar.*"

# check whether the deb carries a full src/ tree
# Note: do not use `tar -tf | grep -q`; grep exiting early raises
# SIGPIPE, which pipefail treats as failure. Write a listing first.
# Avoid `tar -tf | grep -q`: SIGPIPE under pipefail breaks the pipeline.
LIST_FILE="$WORK/list.txt"
tar -tf "$PAYLOAD" > "$LIST_FILE" 2>/dev/null || true
if ! grep -q 'lib/go/src/net/conf.go$' "$LIST_FILE"; then
    die "unexpected package layout: no lib/go/src/ in this deb"
fi

PATCH_SRC="$OUT_DIR/patch-src"
rm -rf "$PATCH_SRC"; mkdir -p "$PATCH_SRC"

# Paths inside the deb: ./data/data/com.termux/files/usr/lib/go/src/<rel>
# Components: . / data / data / com.termux / files / usr / lib / go / src
# => strip 9 yields <rel> (strip 8 would keep the src/ prefix)
DEB_PREFIX="./data/data/com.termux/files/usr/lib/go/src"
STRIP_LEVEL=9

mkdir -p "$WORK/pick"
# Extract every needed member in one tar pass instead of rescanning
# Extract all members in a single tar pass (avoids re-scanning the big archive).
MEMBERS=()
for rel in "${ALL_FILES[@]}"; do
    MEMBERS+=("$DEB_PREFIX/$rel")
done

tar -xf "$PAYLOAD" -C "$WORK/pick" --strip-components=$STRIP_LEVEL "${MEMBERS[@]}" 2>/dev/null || true

extracted=0
for rel in "${ALL_FILES[@]}"; do
    if [[ -f "$WORK/pick/$rel" ]]; then
        mkdir -p "$PATCH_SRC/$(dirname "$rel")"
        cp "$WORK/pick/$rel" "$PATCH_SRC/$rel"
        extracted=$((extracted+1))
    else
        warn "not extracted: src/$rel"
    fi
done

ok "extracted $extracted of ${#ALL_FILES[@]} files"
echo

# ---------- 4. optional: the full src/ tree ----------
if [[ $FULL_SRC -eq 1 ]]; then
    log "extracting the full src/ tree (slow, about 129 MB)"
    mkdir -p "$OUT_DIR/full-src"
    # Whole-tree extract: strip 8 leaves a src/ prefix, as intended.
    # Full tree: strip 8 leaves a 'src/' prefix, which is exactly what we want.
    tar -xf "$PAYLOAD" -C "$OUT_DIR/full-src" --strip-components=8 \
        "$DEB_PREFIX" 2>/dev/null || true
    ok "full src at: $OUT_DIR/full-src/src"
fi

# ---------- 5. archive and manifest ----------
log "archiving the patch sources"
ARCHIVE="$OUT_DIR/goroot-src.tar.gz"
( cd "$PATCH_SRC" && tar -czf "$ARCHIVE" . ) 2>/dev/null
ok "archive        : $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))"

cat > "$OUT_DIR/MANIFEST.txt" <<EOF
Termux Go patch source manifest
generated   : $(date '+%Y-%m-%d %H:%M:%S')
arch        : $ARCH
pkg version : $VERSION
apt mirror  : $MIRROR
deb sha256  : $SHA256

-- Files required by this approach --
$(for f in "${MODIFY_FILES[@]}"; do printf '  [modify]  src/%s\n' "$f"; done)
$(for f in "${NEW_FILES[@]}"; do printf '  [new]     src/%s\n' "$f"; done)

-- Explicitly NOT needed --
  x bin/go, pkg/tool/android_*/      bionic ELF (interpreter=/system/bin/linker64)
  x lib/, misc/                      unrelated to the patches
  x the other three ABI packages     src/ is identical (129 MB, no diff in net/)
  x Termux clang / llvm / libc++ / ndk-sysroot   the NDK provides these
  x bootstrap-*.zip                  a Termux rootfs, unrelated here

-- Why one ABI's src suffices --
  Comparing the src/ trees of aarch64 / arm / i686 / x86_64: the 129 MB of
  content is essentially identical. Only three architecture-specific files
  differ, and this approach uses none of them:
    src/cmd/cgo/zdefaultcc.go              default CC name (we pass CC=)
    src/cmd/go/internal/cfg/zdefaultcc.go  same
    src/internal/buildcfg/zbootstrap.go    defaultGO_LDSO (the NDK sets it)
  So any one ABI's src/ works; the NDK clang and sysroot supply the rest.

-- Next steps --
  1) Get an official Go toolchain (Linux host build, not the Termux one):
       curl -LO https://go.dev/dl/go<VER>.linux-<ARCH>.tar.gz
       tar -xzf go<VER>.linux-<ARCH>.tar.gz -C <GOROOT> --strip-components=1
  2) Apply the patches:
       ./patch-goroot-termux.sh -g <GOROOT> -s $OUT_DIR
  3) Build the four ABIs with the NDK:
       ./android-cross-build.sh -n <NDK> -g <GOROOT> -o out
EOF

ok "manifest       : $OUT_DIR/MANIFEST.txt"
echo
log "done"
echo
echo "  patch src : $PATCH_SRC  (${#ALL_FILES[@]} files)"
echo "  archive   : $ARCHIVE"
echo "  manifest  : $OUT_DIR/MANIFEST.txt"
echo
echo "  note:"
echo "    - the Go version must match the official toolchain: the patches may"
echo "      depend on internal packages that only exist in that release"
echo "    - the NDK is provided by the user; different NDK releases ship"
echo "      different sysroots and clang builds, so none is assumed here"
