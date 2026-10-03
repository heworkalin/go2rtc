#!/usr/bin/env bash
#
# patch-goroot-termux.sh - port the Termux Go stdlib patches onto any GOROOT
#
# ===========================================================================
# Why this exists
# ===========================================================================
#
#   Termux's Go carries six Android adaptations in the standard library
#   (four new files and six edits), so that a compiled program finds DNS,
#   mDNS, CA certificates and a temporary directory on Android. Official
#   Linux Go builds instead read /etc/resolv.conf and /etc/ssl/..., paths
#   that do not exist on Android, so DNS and HTTPS fail.
#
#   The Termux GOROOT itself cannot be used for cross-compilation away from
#   Android, because:
#     - pkg/tool/android_*/ holds bionic ELF binaries (interpreter
#       /system/bin/linker64) that will not run on plain Linux, in a chroot,
#       or in CI;
#     - official Go cannot see them anyway and reports
#       "no such tool compile", since it looks under pkg/tool/linux_*/.
#
#   So: keep the toolchain of any official GOROOT, but apply Termux's stdlib
#   patches to that GOROOT's src/. That preserves Termux behaviour while
#   staying independent of the Android runtime.
#
# ---------------------------------------------------------------------------
# What the patches change (mirrors termux-packages/packages/golang)
# ---------------------------------------------------------------------------
#
#   New files:
#     src/net/conf_android.go          (copied from net/conf.go)
#     src/net/dnsclient_android.go     (copied from net/dnsclient_unix.go)
#     src/net/interface_android.go     (netlink fallback for Android 11+)
#     src/syscall/netlink_android.go   (same)
#
#   Edits:
#     src/net/conf.go                  add !android to the build constraint
#     src/net/dnsclient_unix.go        add !android
#     src/net/interface_linux.go       add !android
#     src/syscall/netlink_linux.go     add !android
#     src/os/file_unix.go              temp dir -> <PREFIX>/tmp
#     src/crypto/x509/root_linux.go    CA path  -> <PREFIX>/etc/tls/cert.pem
#
#   <PREFIX> defaults to /data/data/com.termux/files/usr and can be changed
#   with --prefix.
#
#   Note: official Go files carry no //go:build line at all (the _linux.go
#   suffix is the only constraint), so a line has to be INSERTED rather than
#   edited. This script handles that.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   ./patch-goroot-termux.sh --goroot <GOROOT> [options]
#
#   -g, --goroot DIR   GOROOT to patch (required; edited in place, backed up)
#   -P, --prefix PATH  runtime $PREFIX (default /data/data/com.termux/files/usr)
#   -s, --source DIR   patch source: a Termux GOROOT or a patch-src directory
#                      (default: auto-detect, else derived from local src/)
#   -n, --dry-run      show what would change, write nothing
#   -R, --revert       undo the patches (restore files, drop the new ones)
#   -b, --backup DIR   backup location (default <GOROOT>/.termux-patch-backup)
#   -f, --force        re-apply even if the marker says it is already patched
#   -h, --help         show this help
#
# Examples:
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
        *) die "unknown argument: $1 (use -h for help)" ;;
    esac
done

[[ -n "$GOROOT_TARGET" ]] || die "-g/--goroot is required"
[[ -d "$GOROOT_TARGET/src" ]] || die "not a valid GOROOT (no src/): $GOROOT_TARGET"
GOROOT_TARGET="$(cd "$GOROOT_TARGET" && pwd)"
SRC="$GOROOT_TARGET/src"

GOVER="$(head -1 "$GOROOT_TARGET/VERSION" 2>/dev/null || echo unknown)"
log "target GOROOT: $GOROOT_TARGET ($GOVER)"
log "runtime prefix : $PREFIX"
echo

[[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$GOROOT_TARGET/.termux-patch-backup"

# marker, used for the idempotence check
MARKER="$GOROOT_TARGET/.termux-patch-applied"

# ---------- revert mode ----------
if [[ $REVERT -eq 1 ]]; then
    log "reverting the Termux patches"
    [[ -d "$BACKUP_DIR" ]] || die "backup directory not found: $BACKUP_DIR"

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
        log "revert complete"
    fi
    exit 0
fi

# ---------- idempotence check ----------
if [[ -f "$MARKER" && $FORCE -eq 0 ]]; then
    if grep -q "^prefix=$PREFIX$" "$MARKER" 2>/dev/null; then
        ok "already patched with PREFIX=$PREFIX, skipping. Use -f to redo."
        exit 0
    else
        warn "patched earlier with a different PREFIX; --revert first is safer"
    fi
fi

# ---------- determine the patch source ----------
# Priority: explicit --source, then a local Termux GOROOT, then derive
detect_termux_goroot() {
    local c
    # form 1: a full Termux GOROOT
    # form 1: a full Termux GOROOT
    for c in "$HOME/.cache/termux-go"/*/goroot \
             /tmp/tgofetch-*/*/goroot \
             "$HOME/termux-go"/*/goroot \
             "$HOME/.termux-go"/*/goroot; do
        [[ -f "$c/src/net/dnsclient_android.go" ]] || continue
        echo "goroot:$c"; return 0
    done
    # form 2: a patch-src directory from termux-go-fetch.sh
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
PATCH_SRC=""   # normalised patch source directory
normalize_source() {
    local s="$1"
    if [[ -f "$s/src/net/dnsclient_android.go" ]]; then
        PATCH_SRC="$s/src"                                # a full GOROOT
    elif [[ -f "$s/net/dnsclient_android.go" ]]; then
        PATCH_SRC="$s"                                    # a patch-src directory
    elif [[ -f "$s/patch-src/net/dnsclient_android.go" ]]; then
        PATCH_SRC="$s/patch-src"                          # an output directory
    else
        return 1
    fi
    return 0
}

if [[ -n "$SRC_GOROOT" ]]; then
    normalize_source "$SRC_GOROOT" \
        || die "--source is neither a Termux GOROOT nor a patch-src dir: $SRC_GOROOT"
    HAVE_SOURCE=1
    log "patch source: $PATCH_SRC"
elif detected="$(detect_termux_goroot)"; then
    SRC_GOROOT="${detected#*:}"
    normalize_source "$SRC_GOROOT" || die "auto-detected source is invalid: $SRC_GOROOT"
    HAVE_SOURCE=1
    log "auto-detected patch source: $PATCH_SRC"
else
    warn "no Termux patch source found; deriving from the local src/ instead"
    warn "(this omits the netlink fallback and other Termux-only changes)"
    warn "recommended: run ./termux-go-fetch.sh -o ./termux-go-patch first"
fi

# ---------- backup ----------
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

# ---------- helper: append a build constraint ----------
# usage: add_build_constraint <file> <extra-expr>
# e.g.   add_build_constraint net/conf.go "!android"
add_build_constraint() {
    local rel="$1" extra="$2" path="$SRC/$1" line new
    [[ -f "$path" ]] || { warn "missing file, skipping: src/$rel"; return 1; }

    line="$(grep -m1 '^//go:build ' "$path" || true)"

    if [[ -z "$line" ]]; then
        # Official files rely on the *_linux.go suffix and have no //go:build
        # line, so insert one just before the package clause.
        # Official files rely on the *_linux.go suffix and carry no //go:build
        # line, so we insert one before the package clause.
        if grep -q "//go:build.*$extra" "$path" 2>/dev/null; then
            info "src/$rel already has $extra, skipping"
            return 0
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            info "src/$rel: inserting '//go:build $extra' (no build line; the file\n              suffix was the only constraint)"
            return 0
        fi
        backup_file "$rel"
        # insert //go:build, followed by a blank line, right before package
        awk -v c="//go:build $extra" '
            !done && /^package / {
                print c
                print ""
                done = 1
            }
            { print }
        ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
        ok "src/$rel: inserted build constraint '//go:build $extra'"
        return 0
    fi

    if [[ "$line" == *"$extra"* ]]; then
        info "src/$rel already has $extra, skipping"
        return 0
    fi

    # "//go:build linux && amd64" -> "//go:build (linux && amd64) && !android"
    local expr="${line#//go:build }"
    new="//go:build ($expr) && $extra"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "src/$rel: '$line' -> '$new'"
        return 0
    fi
    backup_file "$rel"
    # Replace the first //go:build line with awk, avoiding sed escaping
    awk -v old="$line" -v new="$new" '
        !done && $0 == old { print new; done=1; next } { print }
    ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    ok "src/$rel: build constraint -> $new"
}

# ---------- helper: derive an *_android.go from an official file ----------
# usage: create_android_file <src rel> <dst rel> <build constraint>
create_android_file() {
    local src_rel="$1" dst_rel="$2" constraint="$3"
    local src_path="$SRC/$src_rel" dst_path="$SRC/$dst_rel"

    [[ -f "$src_path" ]] || { warn "missing source file, skipping: src/$src_rel"; return 1; }
    [[ -f "$dst_path" ]] && { info "src/$dst_rel already exists, skipping"; return 0; }

    if [[ $DRY_RUN -eq 1 ]]; then
        info "would create src/$dst_rel  (from $src_rel, build: $constraint)"
        return 0
    fi

    # Prefer copying the Termux source outright, extra changes included
    if [[ $HAVE_SOURCE -eq 1 && -f "$PATCH_SRC/$dst_rel" ]]; then
        # Copy it, swapping the prefix for the target one
        sed "s|/data/data/com\.termux/files/usr|$PREFIX|g" \
            "$PATCH_SRC/$dst_rel" > "$dst_path"
        ok "src/$dst_rel  (copied from Termux source)"
        return 0
    fi

    # Otherwise derive it: drop the old //go:build, set the given one
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

# ---------- helper: replace a path literal ----------
replace_literal() {
    local rel="$1" from="$2" to="$3" path="$SRC/$1"
    [[ -f "$path" ]] || { warn "missing file: src/$rel"; return 1; }

    if ! grep -qF "$from" "$path"; then
        info "src/$rel does not contain '$from', skipping"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "src/$rel: replace '$from' -> '$to'"
        return 0
    fi
    backup_file "$rel"
    # escape the sed delimiter and metacharacters
    local f_esc t_esc
    f_esc="$(printf '%s' "$from" | sed 's/[&|\\]/\\&/g')"
    t_esc="$(printf '%s' "$to"   | sed 's/[&|\\]/\\&/g')"
    sed -i "s|$f_esc|$t_esc|g" "$path"
    ok "src/$rel  '$from' -> '$to'"
}

# ===========================================================================
# apply the patches
# ===========================================================================

log "1/3  adjusting build constraints so android uses its own files"
add_build_constraint "net/conf.go"              "!android" || true
add_build_constraint "net/dnsclient_unix.go"    "!android" || true
add_build_constraint "net/interface_linux.go"   "!android" || true
add_build_constraint "syscall/netlink_linux.go" "!android" || true
echo

log "2/3  adding the android-only implementations"
create_android_file "net/conf.go"              "net/conf_android.go"            "android"
create_android_file "net/dnsclient_unix.go"    "net/dnsclient_android.go"       "android"
create_android_file "net/interface_linux.go"   "net/interface_android.go"       "android"
create_android_file "syscall/netlink_linux.go" "syscall/netlink_android.go"     "android"
echo

log "3/3  rewriting the runtime paths (DNS / CA / tmp / mDNS)"

# 3.1 DNS: point the android resolv.conf paths at PREFIX
#     handle the official paths in the generated android files
for rel in net/dnsclient_android.go net/conf_android.go; do
    [[ -f "$SRC/$rel" ]] || continue
    # /etc/resolv.conf -> $PREFIX/etc/resolv.conf
    if grep -q '"/etc/resolv.conf"' "$SRC/$rel" 2>/dev/null; then
        replace_literal "$rel" '"/etc/resolv.conf"' "\"$PREFIX/etc/resolv.conf\"" || true
    fi
    # /etc/nsswitch.conf, when present
    if grep -q '"/etc/nsswitch.conf"' "$SRC/$rel" 2>/dev/null; then
        replace_literal "$rel" '"/etc/nsswitch.conf"' "\"$PREFIX/etc/nsswitch.conf\"" || true
    fi
    # mdns.allow
    if grep -q '"/etc/mdns.allow"' "$SRC/$rel" 2>/dev/null; then
        replace_literal "$rel" '"/etc/mdns.allow"' "\"$PREFIX/etc/mdns.allow\"" || true
    fi
done

# 3.2 os/file_unix.go: the temp directory
#     /data/local/tmp in the android branch -> $PREFIX/tmp
if [[ -f "$SRC/os/file_unix.go" ]]; then
    if ! grep -q "$PREFIX/tmp" "$SRC/os/file_unix.go"; then
        replace_literal "os/file_unix.go" '"/data/local/tmp"' "\"$PREFIX/tmp\"" || true
    else
        info "src/os/file_unix.go already uses $PREFIX/tmp, skipping"
    fi
fi

# 3.3 crypto/x509/root_linux.go: the CA bundle path
if [[ -f "$SRC/crypto/x509/root_linux.go" ]]; then
    if grep -q "$PREFIX/etc/tls/cert.pem" "$SRC/crypto/x509/root_linux.go"; then
        info "src/crypto/x509/root_linux.go already has the Termux cert path, skipping"
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
        ok "src/crypto/x509/root_linux.go: prepended the Termux cert path"
    fi
fi
echo

# ---------- verify ----------
if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run finished, nothing was written"
    exit 0
fi

log "verifying the patch result"
FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else printf '\033[1;31m  ✗\033[0m %s\n' "$1"; FAIL=1; fi; }

check "added net/conf_android.go"        "[[ -f '$SRC/net/conf_android.go' ]]"
check "added net/dnsclient_android.go"   "[[ -f '$SRC/net/dnsclient_android.go' ]]"
check "added net/interface_android.go"   "[[ -f '$SRC/net/interface_android.go' ]]"
check "added syscall/netlink_android.go" "[[ -f '$SRC/syscall/netlink_android.go' ]]"
check "conf.go excludes android"         "grep -q '!android' '$SRC/net/conf.go'"
check "dnsclient_unix.go excludes android" "grep -q '!android' '$SRC/net/dnsclient_unix.go'"
check "netlink_linux.go excludes android" "grep -q '!android' '$SRC/syscall/netlink_linux.go'"
check "resolv.conf points at PREFIX"     "grep -rq '$PREFIX/etc/resolv.conf' '$SRC/net/'"
check "tmp points at PREFIX"             "grep -q '$PREFIX/tmp' '$SRC/os/file_unix.go'"
check "CA cert points at PREFIX"         "grep -q '$PREFIX/etc/tls/cert.pem' '$SRC/crypto/x509/root_linux.go'"

# write the marker
{
    echo "prefix=$PREFIX"
    echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "goroot=$GOROOT_TARGET"
    echo "source=${SRC_GOROOT:-<derived>}"
} > "$MARKER"

echo
if [[ $FAIL -eq 0 ]]; then
    log "all patches applied"
    echo
    echo "  backup : $BACKUP_DIR"
    echo "  revert : $0 -g \"$GOROOT_TARGET\" --revert"
    echo
    echo "  next:"
    echo "    cross-compile with this GOROOT and the NDK clang:"
    echo "      GOROOT=\"$GOROOT_TARGET\" ./android-cross-build.sh -n <NDK> -o out"
else
    die "some checks failed (use --revert to undo)"
fi
