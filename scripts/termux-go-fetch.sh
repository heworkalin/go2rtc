#!/usr/bin/env bash
#
# termux-go-fetch.sh — 只下载"必要"的 Termux Go 资源（轻量版）
# termux-go-fetch.sh — Fetch only the ESSENTIAL Termux Go resources (lightweight)
#
# ═══════════════════════════════════════════════════════════════════════════
# 设计原则 / Design rationale
# ═══════════════════════════════════════════════════════════════════════════
#
#   目标：为「官方 Go + NDK clang」的 4 架构 Android 交叉编译提供
#         Termux 的标准库补丁（DNS / CA / tmp / mDNS 的 Android 适配）。
#
#   关键事实（已实测验证）：
#
#   1. **4 个架构的 Termux src/ 完全相同**（129 MB，net 目录 0 差异）。
#      仅 3 个架构相关文件不同，且本方案都不需要：
#        src/cmd/cgo/zdefaultcc.go            默认 CC 名（我们用 CC= 显式指定）
#        src/cmd/go/internal/cfg/zdefaultcc.go 同上
#        src/internal/buildcfg/zbootstrap.go  defaultGO_LDSO（NDK 自动设置）
#      => **只下一个架构的 src 就够**，其余 3 个架构靠 NDK 的 sysroot/clang 补足。
#
#   2. Termux 的 bin/go 与 pkg/tool/android_*/ 是 **bionic ELF**
#      （interpreter = /system/bin/linker64），在纯 Linux / chroot / CI 中
#      无法执行 —— 所以 **完全不需要下载它们**。
#
#   3. 本方案真正需要的，只有 src/ 里这 6 个文件：
#        net/conf.go                   （改：加 !android 约束）
#        net/dnsclient_unix.go         （改：加 !android 约束）
#        net/interface_linux.go        （改：加 !android 约束）
#        syscall/netlink_linux.go      （改：加 !android 约束）
#        os/file_unix.go               （改：tmp 路径）
#        crypto/x509/root_linux.go     （改：CA 路径）
#      外加 Termux 新增的 4 个 android 专用文件（从 Termux src 直接复制）：
#        net/conf_android.go
#        net/dnsclient_android.go
#        net/interface_android.go
#        syscall/netlink_android.go
#
#   因此本脚本默认只下载 **1 个架构** 的 golang deb，并只解出 src/。
#
# ─── 什么必下、什么不必下 ──────────────────────────────────────────────────
#
#   必下 / Required:
#     ✓ Termux golang deb（1 个架构）—— 仅用于提取 src/ 里的 9 个补丁相关文件
#     ✓ 官方 Go 工具链（Linux host 版）—— go.dev 下载，非 Termux（bionic 跑不了）
#     ✓ Android NDK —— 由用户自备（版本不同，文件内容也不同，不要预设）
#
#   不必下 / NOT needed:
#     ✗ 另外 3 个架构的 Termux 包（src 相同，纯浪费 ~110 MB）
#     ✗ Termux 的 bin/go、pkg/tool/android_*/（bionic ELF，本方案用不到）
#     ✗ Termux 的 clang / llvm / libc++（NDK 已提供，且 Termux 版是 bionic）
#     ✗ Termux 的 ndk-sysroot（NDK 自带 sysroot）
#     ✗ bootstrap zip（那是 Termux 根文件系统，本方案无关）
#
#   可选 / Optional:
#     ○ --with-appendix：额外保留整个 src/（如需自行改其他标准库）
#
# ═══════════════════════════════════════════════════════════════════════════
# 用法 / Usage
# ═══════════════════════════════════════════════════════════════════════════
#
#   ./termux-go-fetch.sh [选项]
#
#   -a, --arch ABI     取的架构（默认 aarch64；仅影响 src，行为等价）
#   -o, --out DIR      输出目录（默认 ./termux-go-patch）
#   -m, --mirror URL   apt 仓库镜像（默认官方）
#   -c, --cache DIR    .deb 缓存目录（默认 ~/.cache/termux-go/debs）
#   --full-src         保留完整 src/（默认只保留补丁相关文件）
#   --print-files      只打印需要的文件清单，不下载
#   -h, --help         帮助
#
# 产物 / Output:
#   <out>/patch-src/          提供的补丁源文件（9 个）
#   <out>/goroot-src.tar.gz   打包好的补丁源（可直接喂给 patch-goroot-termux.sh）
#   <out>/MANIFEST.txt        文件清单与来源说明
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

# ---------- 必需文件清单 / Required file list ----------
# 两类：待修改的官方文件 / Termux 新增的 android 实现
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
本方案需要的 Termux Go 源文件（共 ${#ALL_FILES[@]} 个）
Required Termux Go source files (${#ALL_FILES[@]} total)

【待修改的官方文件 / files to modify】
$(for f in "${MODIFY_FILES[@]}"; do echo "  src/$f"; done)

【Termux 新增的 android 实现 / Termux-added android impls】
$(for f in "${NEW_FILES[@]}"; do echo "  src/$f"; done)

【不需要 / NOT needed】
  ✗ bin/go, pkg/tool/android_*/      bionic ELF，本方案用 NDK 替代
  ✗ lib/, misc/                       非必需
  ✗ 另外 3 个架构的包                  src/ 与架构无关（129 MB 完全相同）
  ✗ Termux clang/llvm/libc++/sysroot  NDK 已提供
  ✗ bootstrap-*.zip                   Termux 根文件系统，与本方案无关
EOF
    exit 0
fi

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"; done; }
need curl tar ar

# ---------- 缓存目录 / Cache dir ----------
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

log "架构 / arch     : $ARCH （仅用于取 src，4 架构等价）"
log "缓存 / cache    : $DEB_CACHE"
log "输出 / out      : $OUT_DIR"
echo

# ---------- 1. 查索引拿下载地址 / Resolve package URL ----------
log "查询 apt 索引 / querying apt index"
INDEX_URL="$MIRROR/dists/stable/main/binary-$ARCH/Packages"
INDEX_FILE="$DEB_CACHE/.Packages.$ARCH"

if [[ -s "$INDEX_FILE" ]] && [[ -n "$(grep -m1 '^Package: golang$' "$INDEX_FILE" 2>/dev/null)" ]]; then
    ok "索引已缓存 / index cached"
else
    curl -fsSL --retry 3 --connect-timeout 20 "$INDEX_URL" -o "$INDEX_FILE.part" \
        || die "索引下载失败: $INDEX_URL"
    mv "$INDEX_FILE.part" "$INDEX_FILE"
    ok "索引已下载 / index fetched"
fi

# 解析 golang 记录的 Filename / SHA256 / Version / Size
# 按空行分段；用 flag 标记是否进入目标包段落。
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
ok "包 / package   : golang $VERSION  ($(echo "$SIZE/1048576" | bc -l 2>/dev/null || echo '?') MB)"
echo

# ---------- 2. 下载 deb（带缓存与校验）/ Download deb ----------
DEB_FILE="$DEB_CACHE/$(basename "$REL_PATH")"

if [[ -s "$DEB_FILE" ]] && echo "$SHA256  $DEB_FILE" | sha256sum -c --quiet 2>/dev/null; then
    ok "deb 已缓存且校验通过 / cached & verified"
else
    log "下载 golang deb / downloading"
    curl -fsSL --retry 3 --connect-timeout 30 "$MIRROR/$REL_PATH" -o "$DEB_FILE.part" \
        || die "deb 下载失败"
    mv "$DEB_FILE.part" "$DEB_FILE"
    echo "$SHA256  $DEB_FILE" | sha256sum -c --quiet 2>/dev/null \
        || die "SHA256 校验失败 / checksum mismatch"
    ok "下载并校验完成 / downloaded & verified"
fi
echo

# ---------- 3. 只解出需要的文件 / Extract only needed files ----------
log "解包并挑选文件 / extracting selected files"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

( cd "$WORK" && ar x "$DEB_FILE" ) || die "ar 解包失败"
PAYLOAD="$(ls "$WORK"/data.tar.* 2>/dev/null | head -1)"
[[ -n "$PAYLOAD" ]] || die "deb 内没有 data.tar.*"

# 先看是否含完整 src/（大包）还是只有精选（小包）
# 注意：不能用 `tar -tf | grep -q`——grep 提前退出会产生 SIGPIPE，
# 在 set -o pipefail 下会让管道判定为失败。改为先写清单文件再 grep。
# Avoid `tar -tf | grep -q`: SIGPIPE under pipefail breaks the pipeline.
LIST_FILE="$WORK/list.txt"
tar -tf "$PAYLOAD" > "$LIST_FILE" 2>/dev/null || true
if ! grep -q 'lib/go/src/net/conf.go$' "$LIST_FILE"; then
    die "该 deb 不含 lib/go/src/（意外的包结构）"
fi

PATCH_SRC="$OUT_DIR/patch-src"
rm -rf "$PATCH_SRC"; mkdir -p "$PATCH_SRC"

# deb 内路径： ./data/data/com.termux/files/usr/lib/go/src/<rel>
# 段数： . / data / data / com.termux / files / usr / lib / go / src
# => strip 9 得到 <rel>（strip 8 会保留 src/ 前缀）
DEB_PREFIX="./data/data/com.termux/files/usr/lib/go/src"
STRIP_LEVEL=9

mkdir -p "$WORK/pick"
# 一次性解出所有需要的文件（tar 会单趟完成，避免逐文件重复遍历大包）
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
        warn "未提取到: src/$rel"
    fi
done

ok "提取 $extracted/${#ALL_FILES[@]} 个文件 / extracted"
echo

# ---------- 4. 可选：完整 src / Optional full src ----------
if [[ $FULL_SRC -eq 1 ]]; then
    log "解出完整 src/（较慢、约 129 MB）/ extracting full src"
    mkdir -p "$OUT_DIR/full-src"
    # 整目录提取：strip 8 得到 src/ 前缀，再包一层以还原 src/ 结构
    # Full tree: strip 8 leaves a 'src/' prefix, which is exactly what we want.
    tar -xf "$PAYLOAD" -C "$OUT_DIR/full-src" --strip-components=8 \
        "$DEB_PREFIX" 2>/dev/null || true
    ok "完整 src 位于 / full src at: $OUT_DIR/full-src/src"
fi

# ---------- 5. 打包 + 清单 / Archive + manifest ----------
log "打包补丁源 / archiving patch sources"
ARCHIVE="$OUT_DIR/goroot-src.tar.gz"
( cd "$PATCH_SRC" && tar -czf "$ARCHIVE" . ) 2>/dev/null
ok "归档 / archive: $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))"

cat > "$OUT_DIR/MANIFEST.txt" <<EOF
Termux Go 补丁源清单 / Termux Go patch source manifest
生成时间 / generated : $(date '+%Y-%m-%d %H:%M:%S')
架构 / arch          : $ARCH
包版本 / pkg version : $VERSION
apt 仓库 / mirror    : $MIRROR
deb sha256           : $SHA256

── 本方案需要的文件 / Files required by this approach ──
$(for f in "${MODIFY_FILES[@]}"; do printf '  [改/modify]  src/%s\n' "$f"; done)
$(for f in "${NEW_FILES[@]}"; do printf '  [新增/new]   src/%s\n' "$f"; done)

── 明确不需要 / Explicitly NOT needed ──
  ✗ bin/go, pkg/tool/android_*/       bionic ELF（interpreter=/system/bin/linker64）
  ✗ lib/, misc/                        与补丁无关
  ✗ 另外 3 个架构的包                  src/ 完全相同（129 MB，net 目录 0 差异）
  ✗ Termux clang / llvm / libc++ / ndk-sysroot   NDK 提供，且 Termux 版是 bionic
  ✗ bootstrap-*.zip                    Termux 根文件系统，与本方案无关

── 为什么 4 架构只需 1 份 src / Why one arch suffices ──
  实测对比 aarch64 / arm / i686 / x86_64 四份 src/：129 MB 内容几乎完全一致，
  仅 3 个「架构相关」文件不同，且本方案均不使用：
    src/cmd/cgo/zdefaultcc.go              默认 CC 名（本方案用 CC= 显式指定）
    src/cmd/go/internal/cfg/zdefaultcc.go  同上
    src/internal/buildcfg/zbootstrap.go    defaultGO_LDSO（NDK 自动设置）
  因此取任一架构的 src/ 即可，其余架构由 NDK 的 clang + sysroot 补足。

── 下一步 / Next step ──
  1) 准备官方 Go 工具链（Linux host 版，非 Termux）:
       curl -LO https://go.dev/dl/go<VER>.linux-<ARCH>.tar.gz
       tar -xzf go<VER>.linux-<ARCH>.tar.gz -C <GOROOT> --strip-components=1
  2) 应用补丁:
       ./patch-goroot-termux.sh -g <GOROOT> -s $OUT_DIR
  3) 用 NDK 编 4 架构:
       ./android-cross-build.sh -n <NDK> -g <GOROOT> -o out
EOF

ok "清单 / manifest: $OUT_DIR/MANIFEST.txt"
echo
log "完成 / done"
echo
echo "  补丁源 / patch src : $PATCH_SRC  （${#ALL_FILES[@]} 个文件）"
echo "  归档   / archive   : $ARCHIVE"
echo "  清单   / manifest  : $OUT_DIR/MANIFEST.txt"
echo
echo "  注意 / note:"
echo "    • 版本必须与官方 Go 一致（补丁可能依赖同版本 internal 包）"
echo "    • NDK 由用户自备：不同 NDK 版本产生的 sysroot/clang 不同，不予预设"
