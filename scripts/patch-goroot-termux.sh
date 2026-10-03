#!/usr/bin/env bash
#
# patch-goroot-termux.sh — 把 Termux 的 Go 标准库补丁移植到任意 GOROOT
# patch-goroot-termux.sh — Port Termux's Go stdlib patches onto any GOROOT
#
# ═══════════════════════════════════════════════════════════════════════════
# 为什么需要这个脚本 / Why this exists
# ═══════════════════════════════════════════════════════════════════════════
#
#   Termux 版 Go 对标准库做了 6 处 Android 适配（3 项新增文件 + 3 项改动，
#   见下），使编译出的程序在 Android 上能正确解析 DNS、mDNS、CA 证书与临时目录。
#   而官方 Linux 版 Go 编出的程序会去读 /etc/resolv.conf、/etc/ssl/... 等
#   Android 上不存在（或被 SELinux 拒绝）的路径，导致 DNS/HTTPS 失败。
#
#   Termux 的 GOROOT 无法直接用于「脱离 Android 运行时」的交叉编译，因为：
#     - pkg/tool/android_*/ 里的工具链是 bionic ELF（interpreter=/system/bin/linker64），
#       在纯 Linux / chroot / 容器里无法执行；
#     - 官方 Go 找不到对应的 linux_* 工具链（报 "no such tool compile"）。
#
#   解法：用官方（或任意）GOROOT 的工具链，但把 Termux 的 stdlib 补丁
#   应用到该 GOROOT 的 src/ 上。这样既保留 Termux 的行为，又能脱离 Android 运行时。
#
# ─── 补丁内容（对照 Termux packages/golang/patch-script/）──────────────────
#
#   新增文件 / New files：
#     src/net/conf_android.go          （由 net/conf.go 复制并加 //go:build android）
#     src/net/dnsclient_android.go     （由 net/dnsclient_unix.go 复制）
#     src/net/interface_android.go     （由 net/interface_linux.go 复制，netlink 回退）
#     src/syscall/netlink_android.go    （由 syscall/netlink_linux.go 复制）
#
#   修改文件 / Modified files：
#     src/net/conf.go                  build 约束加 !android
#     src/net/dnsclient_unix.go        build 约束加 !android
#     src/net/interface_linux.go       build 约束加 !android
#     src/syscall/netlink_linux.go     build 约束加 !android
#     src/os/file_unix.go              临时目录 -> <PREFIX>/tmp
#     src/crypto/x509/root_linux.go    证书路径 -> <PREFIX>/etc/tls/cert.pem
#
#   其中 <PREFIX> 默认 /data/data/com.termux/files/usr（用 --prefix 可改）。
#
# ═══════════════════════════════════════════════════════════════════════════
# 用法 / Usage
# ═══════════════════════════════════════════════════════════════════════════
#
#   ./patch-goroot-termux.sh --goroot <GOROOT> [选项]
#
#   -g, --goroot DIR   要打补丁的 GOROOT（必需；会就地修改，建议先备份）
#   -P, --prefix PATH  运行时的 $PREFIX（默认 /data/data/com.termux/files/usr）
#   -s, --source DIR   提供补丁来源的 Termux GOROOT（默认自动探测/自动生成）
#   -n, --dry-run      只显示将要做的改动，不实际写入
#   -R, --revert       撤销补丁（还原修改的文件、删除新增文件）
#   -b, --backup DIR   修改前备份到该目录（默认 <GOROOT>/.termux-patch-backup）
#   -f, --force        已打过补丁时仍然继续
#   -h, --help         帮助
#
# 例 / Examples:
#   ./patch-goroot-termux.sh -g /usr/local/go
#   ./patch-goroot-termux.sh -g ~/goroot -P /data/data/com.termux/files/usr
#   ./patch-goroot-termux.sh -g ~/goroot --dry-run
#   ./patch-goroot-termux.sh -g ~/goroot --revert
#
set -euo pipefail

GOROOT_TARGET=""
PREFIX="/data/data/com.termux/files/usr"
SRC_GOROOT=""
DRY_RUN=0
REVERT=0
FORCE=0
BACKUP_DIR=""

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
info() { printf '\033[1;36m  ·\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--goroot) GOROOT_TARGET="$2"; shift 2 ;;
        -P|--prefix) PREFIX="${2%/}"; shift 2 ;;
        -s|--source) SRC_GOROOT="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -R|--revert)  REVERT=1; shift ;;
        -b|--backup)  BACKUP_DIR="$2"; shift 2 ;;
        -f|--force)   FORCE=1; shift ;;
        -h|--help)    usage ;;
        *) die "未知参数: $1（-h 查看帮助）" ;;
    esac
done

[[ -n "$GOROOT_TARGET" ]] || die "必须用 -g/--goroot 指定目标 GOROOT"
[[ -d "$GOROOT_TARGET/src" ]] || die "不是有效的 GOROOT（缺 src/）: $GOROOT_TARGET"
GOROOT_TARGET="$(cd "$GOROOT_TARGET" && pwd)"
SRC="$GOROOT_TARGET/src"

GOVER="$(head -1 "$GOROOT_TARGET/VERSION" 2>/dev/null || echo unknown)"
log "目标 GOROOT / target GOROOT: $GOROOT_TARGET ($GOVER)"
log "运行时 PREFIX / runtime prefix: $PREFIX"
echo

[[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$GOROOT_TARGET/.termux-patch-backup"

# 补丁标记，用于幂等判断 / Marker for idempotence
MARKER="$GOROOT_TARGET/.termux-patch-applied"

# ---------- 撤销模式 / Revert ----------
if [[ $REVERT -eq 1 ]]; then
    log "撤销 Termux 补丁 / reverting Termux patches"
    [[ -d "$BACKUP_DIR" ]] || die "找不到备份目录: $BACKUP_DIR"

    NEW_FILES=(
        net/conf_android.go net/dnsclient_android.go
        net/interface_android.go syscall/netlink_android.go
    )
    for f in "${NEW_FILES[@]}"; do
        if [[ -f "$SRC/$f" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                info "would remove: src/$f"
            else
                rm -f "$SRC/$f"; ok "removed src/$f"
            fi
        fi
    done

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        if [[ -f "$BACKUP_DIR/files/$rel" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                info "would restore: src/$rel"
            else
                cp -a "$BACKUP_DIR/files/$rel" "$SRC/$rel"
                ok "restored src/$rel"
            fi
        fi
    done < <(cat "$BACKUP_DIR/manifest.txt" 2>/dev/null || true)

    if [[ $DRY_RUN -eq 0 ]]; then
        rm -f "$MARKER"; rm -rf "$BACKUP_DIR"
        log "撤销完成 / revert complete"
    fi
    exit 0
fi

# ---------- 幂等检查 / Idempotence check ----------
if [[ -f "$MARKER" && $FORCE -eq 0 ]]; then
    if grep -q "^prefix=$PREFIX$" "$MARKER" 2>/dev/null; then
        ok "补丁已应用（PREFIX=$PREFIX），跳过。用 -f 强制重打。"
        exit 0
    else
        warn "已用不同 PREFIX 打过补丁，重打前先 --revert 更安全"
    fi
fi

# ---------- 确定补丁来源 / Determine patch source ----------
# 三种来源，优先级：显式 --source > 本地 Termux GOROOT > 现场从官方 src 生成
detect_termux_goroot() {
    local c
    # 形式 1：完整 Termux GOROOT（含 src/net/dnsclient_android.go）
    # form 1: a full Termux GOROOT
    for c in "$HOME/.cache/termux-go"/*/goroot \
             /tmp/tgofetch-*/*/goroot \
             "$HOME/termux-go"/*/goroot \
             "$HOME/.termux-go"/*/goroot; do
        [[ -f "$c/src/net/dnsclient_android.go" ]] || continue
        echo "goroot:$c"; return 0
    done
    # 形式 2：termux-go-fetch.sh 产出的 patch-src 目录（10 个文件）
    # form 2: a patch-src dir produced by termux-go-fetch.sh
    for c in "$HOME/.cache/termux-go/patch-src" \
             /tmp/tgf-*/patch-src \
             ./termux-go-patch/patch-src \
             "$HOME/termux-go-patch/patch-src"; do
        [[ -f "$c/net/dnsclient_android.go" ]] || continue
        echo "patchsrc:$c"; return 0
    done
    return 1
}

HAVE_SOURCE=0
PATCH_SRC=""   # 归一化后的补丁源目录（内含 net/conf_android.go 等）
normalize_source() {
    local s="$1"
    if [[ -f "$s/src/net/dnsclient_android.go" ]]; then
        PATCH_SRC="$s/src"                                   # 完整 GOROOT
    elif [[ -f "$s/net/dnsclient_android.go" ]]; then
        PATCH_SRC="$s"                                       # patch-src 目录
    elif [[ -f "$s/patch-src/net/dnsclient_android.go" ]]; then
        PATCH_SRC="$s/patch-src"                              # 输出目录
    else
        return 1
    fi
    return 0
}

if [[ -n "$SRC_GOROOT" ]]; then
    normalize_source "$SRC_GOROOT" \
        || die "--source 无效：既非完整 Termux GOROOT，也非 patch-src 目录: $SRC_GOROOT"
    HAVE_SOURCE=1
    log "补丁来源 / source: $PATCH_SRC"
elif detected="$(detect_termux_goroot)"; then
    SRC_GOROOT="${detected#*:}"
    normalize_source "$SRC_GOROOT" || die "自动探测的源无效: $SRC_GOROOT"
    HAVE_SOURCE=1
    log "自动探测到补丁来源 / auto-detected: $PATCH_SRC"
else
    warn "未找到 Termux 补丁源，将从当前 src/ 自行生成（不含 netlink 回退等额外改动）"
    warn "建议先运行: ./termux-go-fetch.sh -o ./termux-go-patch"
fi

# ---------- 备份 / Backup ----------
if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$BACKUP_DIR/files"
    : > "$BACKUP_DIR/manifest.txt"
fi

backup_file() {
    local rel="$1"
    [[ -f "$SRC/$rel" ]] || return 0
    grep -qxF "$rel" "$BACKUP_DIR/manifest.txt" 2>/dev/null && return 0
    if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$BACKUP_DIR/files/$(dirname "$rel")"
        cp -a "$SRC/$rel" "$BACKUP_DIR/files/$rel"
        echo "$rel" >> "$BACKUP_DIR/manifest.txt"
    fi
}

# ---------- 工具：安全地给 build 约束追加条件 / Append build constraint ----------
# 用法: add_build_constraint <file> <extra-expr>
# 例:   add_build_constraint net/conf.go "!android"
add_build_constraint() {
    local rel="$1" extra="$2" path="$SRC/$1" line new
    [[ -f "$path" ]] || { warn "缺文件，跳过: src/$rel"; return 1; }

    line="$(grep -m1 '^//go:build ' "$path" || true)"

    if [[ -z "$line" ]]; then
        # 官方文件靠 *_linux.go 文件名后缀做约束，没有 //go:build 行。
        # 需要新增一行，并插到 package 声明之前（注释块之后）。
        # Official files rely on the *_linux.go suffix and carry no //go:build
        # line, so we insert one before the package clause.
        if grep -q "//go:build.*$extra" "$path" 2>/dev/null; then
            info "src/$rel 已含 $extra，跳过"
            return 0
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            info "src/$rel: 插入 '//go:build $extra'（原无 build 行，靠文件名后缀约束）"
            return 0
        fi
        backup_file "$rel"
        # 插入 //go:build，后面跟一个空行，紧靠 package 行之前
        awk -v c="//go:build $extra" '
            !done && /^package / {
                print c
                print ""
                done = 1
            }
            { print }
        ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
        ok "src/$rel  插入 build 约束: //go:build $extra"
        return 0
    fi

    if [[ "$line" == *"$extra"* ]]; then
        info "src/$rel 已含 $extra，跳过"
        return 0
    fi

    # 形如 "//go:build linux && amd64" -> "//go:build (linux && amd64) && !android"
    local expr="${line#//go:build }"
    new="//go:build ($expr) && $extra"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "src/$rel: '$line' -> '$new'"
        return 0
    fi
    backup_file "$rel"
    # 用 awk 精确替换第一处 //go:build 行，避免 sed 特殊字符问题
    awk -v old="$line" -v new="$new" '
        !done && $0 == old { print new; done=1; next } { print }
    ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    ok "src/$rel  build 约束 -> $new"
}

# ---------- 工具：从官方文件派生 android 版本 / Derive *_android.go ----------
# 用法: create_android_file <源相对路径> <目标相对路径> <build约束>
create_android_file() {
    local src_rel="$1" dst_rel="$2" constraint="$3"
    local src_path="$SRC/$src_rel" dst_path="$SRC/$dst_rel"

    [[ -f "$src_path" ]] || { warn "缺源文件，跳过: src/$src_rel"; return 1; }
    [[ -f "$dst_path" ]] && { info "src/$dst_rel 已存在，跳过"; return 0; }

    if [[ $DRY_RUN -eq 1 ]]; then
        info "would create src/$dst_rel  (from $src_rel, build: $constraint)"
        return 0
    fi

    # 若提供了 Termux 源，优先直接复制它（含它自己的额外改动，如 netlink 回退）
    if [[ $HAVE_SOURCE -eq 1 && -f "$PATCH_SRC/$dst_rel" ]]; then
        # 复制内容，但把里面的 PREFIX 换成目标 PREFIX
        sed "s|/data/data/com\.termux/files/usr|$PREFIX|g" \
            "$PATCH_SRC/$dst_rel" > "$dst_path"
        ok "src/$dst_rel  (copied from Termux source)"
        return 0
    fi

    # 否则：从官方文件派生 —— 去除原有 //go:build，替换为指定约束
    awk -v c="//go:build $constraint" '
        BEGIN { injected = 0 }
        /^\/\/go:build / {
            if (!injected) { print c; injected = 1 }
            next
        }
        { print }
        END { if (!injected) print c }
    ' "$src_path" > "$dst_path"
    ok "src/$dst_rel  (derived from $src_rel, build: $constraint)"
}

# ---------- 工具：替换路径 / Replace a path literal ----------
replace_literal() {
    local rel="$1" from="$2" to="$3" path="$SRC/$1"
    [[ -f "$path" ]] || { warn "缺文件: src/$rel"; return 1; }

    if ! grep -qF "$from" "$path"; then
        info "src/$rel 未含 '$from'，跳过"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "src/$rel: replace '$from' -> '$to'"
        return 0
    fi
    backup_file "$rel"
    # 转义 sed 分隔符与特殊字符
    local f_esc t_esc
    f_esc="$(printf '%s' "$from" | sed 's/[&|\\]/\\&/g')"
    t_esc="$(printf '%s' "$to"   | sed 's/[&|\\]/\\&/g')"
    sed -i "s|$f_esc|$t_esc|g" "$path"
    ok "src/$rel  '$from' -> '$to'"
}

# ═══════════════════════════════════════════════════════════════════════════
# 应用补丁 / Apply patches
# ═══════════════════════════════════════════════════════════════════════════

log "1/3  修改 build 约束（让 android 走独立实现）"
add_build_constraint "net/conf.go"              "!android" || true
add_build_constraint "net/dnsclient_unix.go"    "!android" || true
add_build_constraint "net/interface_linux.go"   "!android" || true
add_build_constraint "syscall/netlink_linux.go" "!android" || true
echo

log "2/3  新增 android 专用实现"
create_android_file "net/conf.go"              "net/conf_android.go"            "android"
create_android_file "net/dnsclient_unix.go"    "net/dnsclient_android.go"       "android"
create_android_file "net/interface_linux.go"   "net/interface_android.go"       "android"
create_android_file "syscall/netlink_linux.go" "syscall/netlink_android.go"     "android"
echo

log "3/3  替换运行期路径（DNS / CA / tmp / mDNS）"

# 3.1 DNS：把 android 实现里的 resolv.conf 路径指向 PREFIX
#     - 优先处理新生成的 conf_android.go / dnsclient_android.go 里的官方路径
for rel in net/dnsclient_android.go net/conf_android.go; do
    [[ -f "$SRC/$rel" ]] || continue
    # /etc/resolv.conf -> $PREFIX/etc/resolv.conf
    if grep -q '"/etc/resolv.conf"' "$SRC/$rel" 2>/dev/null; then
        replace_literal "$rel" '"/etc/resolv.conf"' "\"$PREFIX/etc/resolv.conf\"" || true
    fi
    # /etc/nsswitch.conf（若存在）
    if grep -q '"/etc/nsswitch.conf"' "$SRC/$rel" 2>/dev/null; then
        replace_literal "$rel" '"/etc/nsswitch.conf"' "\"$PREFIX/etc/nsswitch.conf\"" || true
    fi
    # mdns.allow
    if grep -q '"/etc/mdns.allow"' "$SRC/$rel" 2>/dev/null; then
        replace_literal "$rel" '"/etc/mdns.allow"' "\"$PREFIX/etc/mdns.allow\"" || true
    fi
done

# 3.2 os/file_unix.go：临时目录
#     Android 分支里的 /data/local/tmp -> $PREFIX/tmp
if [[ -f "$SRC/os/file_unix.go" ]]; then
    if ! grep -q "$PREFIX/tmp" "$SRC/os/file_unix.go"; then
        replace_literal "os/file_unix.go" '"/data/local/tmp"' "\"$PREFIX/tmp\"" || true
    else
        info "src/os/file_unix.go 已含 $PREFIX/tmp，跳过"
    fi
fi

# 3.3 crypto/x509/root_linux.go：CA 证书路径
if [[ -f "$SRC/crypto/x509/root_linux.go" ]]; then
    if grep -q "$PREFIX/etc/tls/cert.pem" "$SRC/crypto/x509/root_linux.go"; then
        info "src/crypto/x509/root_linux.go 已含 Termux 证书路径，跳过"
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "src/crypto/x509/root_linux.go: prepend \"$PREFIX/etc/tls/cert.pem\""
    else
        backup_file "crypto/x509/root_linux.go"
        local_line='	"'$PREFIX'/etc/tls/cert.pem",                  // Termux'
        awk -v ins="$local_line" '
            !done && /^var certFiles = \[\]string\{/ { print; print ins; done=1; next }
            { print }
        ' "$SRC/crypto/x509/root_linux.go" > "$SRC/crypto/x509/root_linux.go.tmp" \
            && mv "$SRC/crypto/x509/root_linux.go.tmp" "$SRC/crypto/x509/root_linux.go"
        ok "src/crypto/x509/root_linux.go  已前置 Termux 证书路径"
    fi
fi
echo

# ---------- 校验 / Verify ----------
if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run 结束，未做任何修改 / dry-run finished, nothing written"
    exit 0
fi

log "校验补丁结果 / verifying patch result"
FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else printf '\033[1;31m  ✗\033[0m %s\n' "$1"; FAIL=1; fi; }

check "新增 net/conf_android.go"        "[[ -f '$SRC/net/conf_android.go' ]]"
check "新增 net/dnsclient_android.go"   "[[ -f '$SRC/net/dnsclient_android.go' ]]"
check "新增 net/interface_android.go"   "[[ -f '$SRC/net/interface_android.go' ]]"
check "新增 syscall/netlink_android.go" "[[ -f '$SRC/syscall/netlink_android.go' ]]"
check "conf.go 排除 android"            "grep -q '!android' '$SRC/net/conf.go'"
check "dnsclient_unix.go 排除 android"  "grep -q '!android' '$SRC/net/dnsclient_unix.go'"
check "netlink_linux.go 排除 android"   "grep -q '!android' '$SRC/syscall/netlink_linux.go'"
check "resolv.conf 指向 PREFIX"         "grep -rq '$PREFIX/etc/resolv.conf' '$SRC/net/'"
check "tmp 指向 PREFIX"                 "grep -q '$PREFIX/tmp' '$SRC/os/file_unix.go'"
check "CA 证书指向 PREFIX"              "grep -q '$PREFIX/etc/tls/cert.pem' '$SRC/crypto/x509/root_linux.go'"

# 写标记 / Write marker
{
    echo "prefix=$PREFIX"
    echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "goroot=$GOROOT_TARGET"
    echo "source=${SRC_GOROOT:-<derived>}"
} > "$MARKER"

echo
if [[ $FAIL -eq 0 ]]; then
    log "补丁全部应用成功 / all patches applied"
    echo
    echo "  备份 / backup : $BACKUP_DIR"
    echo "  撤销 / revert : $0 -g \"$GOROOT_TARGET\" --revert"
    echo
    echo "  下一步 / next:"
    echo "    用该 GOROOT + NDK clang 交叉编译："
    echo "      GOROOT=\"$GOROOT_TARGET\" ./android-cross-build.sh -n <NDK> -o out"
else
    die "部分补丁校验失败 / some checks failed（可用 --revert 还原）"
fi
