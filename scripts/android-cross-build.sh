#!/usr/bin/env bash
#
# android-cross-build.sh - cross-compile for four Android ABIs without any
#                          Android runtime
#
# ===========================================================================
# Conclusion (verified on two hosts: proot Ubuntu 24.04 arm64 and a chroot
# Debian 12 arm64)
# ===========================================================================
#
#   Go hardcodes how android/* targets are linked (see
#   cmd/go/internal/work/init.go, mustUseExternalLinker):
#
#     GOOS=android GOARCH=arm64  -> CGO_ENABLED=0 is allowed (fully static)
#     GOOS=android GOARCH=arm    -> CGO_ENABLED=1 is mandatory
#     GOOS=android GOARCH=386    -> CGO_ENABLED=1 is mandatory
#     GOOS=android GOARCH=amd64  -> CGO_ENABLED=1 is mandatory
#
#   With CGO_ENABLED=0 the last three fail with:
#       loadinternal: cannot find runtime/cgo
#       link: running gcc failed
#   That is a design decision in Go, not a missing dependency.
#
#   So building all four ABIs means CGO_ENABLED=1 plus the Android NDK clang.
#
# ---------------------------------------------------------------------------
# Why the NDK and not the Termux toolchain
# ---------------------------------------------------------------------------
#
#   Termux's go and clang are bionic ELF binaries:
#       interpreter = /system/bin/linker64
#       NEEDED      = libc.so(bionic), libLLVM.so, libclang-cpp.so ...
#   They only run where the Android system libraries and linker exist, which
#   rules out plain Linux, chroots, containers and CI.
#
#   The NDK's clang is an ordinary Linux binary:
#       interpreter = /lib/ld-linux-aarch64.so.1 (or the x86_64 equivalent)
#       NEEDED      = libc.so.6, libm.so.6 ... (standard glibc)
#   and it ships a self-contained sysroot (libc.so, liblog.so, libdl.so,
#   libm.so), so it runs anywhere.
#
#   Both routes produce the same ABI: a bionic binary whose interpreter is
#   /system/bin/linker. Using the NDK costs nothing in compatibility.
#
# ---------------------------------------------------------------------------
# Similarity to the Termux runtime
# ---------------------------------------------------------------------------
#
#   Output: both routes yield an Android ELF that depends on the device's
#   bionic at run time, so behaviour is the same.
#   The only difference is where the compile-time sysroot comes from:
#     NDK sysroot    : self-contained, offline, reproducible across machines
#     Termux sysroot : lacks libc.so (the device supplies it), so it only
#                      works when building inside Termux
#   If you do want the four Termux stdlib patches (resolv.conf, cert.pem,
#   mdns, tmp), pass a patched GOROOT with -g; see patch-goroot-termux.sh.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   ./android-cross-build.sh [options] -- [extra go build args]
#
#   -n, --ndk DIR        NDK path (default: auto-detect ANDROID_NDK_HOME,
#                        ~/Android/Sdk/ndk/*, ...)
#   -o, --out DIR        output directory (default ./android-out)
#   -t, --api NUM        Android API level (default 24)
#   -a, --arch LIST      comma-separated ABIs (default all four)
#   -g, --goroot DIR     GOROOT to use (e.g. a patched one); default: go on PATH
#   -p, --package SPEC   package to build (default .)
#   -b, --basename NAME  artifact name (default: the package or "app")
#   -P, --prefix NAME    .so file prefix (default lib)
#   --tags TAGS          build tags passed to go build
#   --ldflags FLAGS      override the default ldflags
#   --static-arm64       build arm64 with CGO_ENABLED=0 (the rest still cgo)
#   --check              check the environment and exit, no build
#   -h, --help           show this help
#
# Examples:
#   ./android-cross-build.sh -n ~/ndk -o out --tags no_ui
#   ./android-cross-build.sh --static-arm64 -o out
#   ./android-cross-build.sh -a arm64-v8a,armeabi-v7a
#
set -euo pipefail

# ---------- Defaults ----------
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

# ---------- 1. locate Go ----------
log "checking the Go toolchain"
if [[ -n "$GOROOT_OVERRIDE" ]]; then
    GO_BIN="$GOROOT_OVERRIDE/bin/go"
    [[ -x "$GO_BIN" ]] || die "no bin/go inside that GOROOT: $GOROOT_OVERRIDE"
    export GOROOT="$GOROOT_OVERRIDE"
else
    GO_BIN="$(command -v go || true)"
    [[ -n "$GO_BIN" ]] || die "go not found; install Go or point -g at a GOROOT"
fi

GO_VER="$("$GO_BIN" version 2>/dev/null || echo unknown)"
log "  $GO_VER"

# Go version requirement (go2rtc needs 1.24+; most projects 1.21+)
GOVER_NUM="$(echo "$GO_VER" | sed -n 's/.*go\([0-9]*\.[0-9]*\).*/\1/p')"
if [[ -n "$GOVER_NUM" ]]; then
    major="${GOVER_NUM%%.*}"; minor="${GOVER_NUM##*.}"
    if (( major == 1 && minor < 21 )); then
        warn "Go $GOVER_NUM is old: no -checklinkname support, and it may not" 
        warn "understand a go 1.24 go.mod"
    fi
fi

# ---------- 2. locate the NDK ----------
log "checking the Android NDK"
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
    NDK_DIR="$(find_ndk)" || die "no Android NDK found. Set ANDROID_NDK_HOME or pass -n."
fi
[[ -d "$NDK_DIR/toolchains/llvm/prebuilt" ]] || die "not a valid NDK: $NDK_DIR"

# host toolchain
case "$(uname -s)" in
    Linux)  HOST_OS="linux" ;;
    Darwin) HOST_OS="darwin" ;;
    *)      die "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  HOST_ARCH="x86_64" ;;
    aarch64|arm64) HOST_ARCH="arm64" ;;
    *)             die "unsupported host architecture: $(uname -m)" ;;
esac

PREBUILT="$NDK_DIR/toolchains/llvm/prebuilt/${HOST_OS}-${HOST_ARCH}"
if [[ ! -d "$PREBUILT/bin" ]]; then
    for alt in "${HOST_OS}-${HOST_ARCH}" "${HOST_OS}-x86_64" "${HOST_OS}-arm64"; do
        [[ -d "$NDK_DIR/toolchains/llvm/prebuilt/$alt/bin" ]] && PREBUILT="$NDK_DIR/toolchains/llvm/prebuilt/$alt" && break
    done
fi
[[ -d "$PREBUILT/bin" ]] || die "the NDK lacks this host toolchain: $PREBUILT"

CLANG="$PREBUILT/bin/clang"
[[ -x "$CLANG" ]] || die "clang not present: $CLANG"

# key check: clang must be an ordinary Linux ELF that runs here
if ! "$CLANG" --version >/dev/null 2>&1; then
    bad "clang is not executable: $CLANG"
    die "this NDK host toolchain does not run here (use one matching uname -m)"
fi
ok "NDK     : $NDK_DIR"
ok "host    : ${HOST_OS}-${HOST_ARCH}"
ok "clang   : $("$CLANG" --version 2>/dev/null | head -1)"

# verify clang is plain Linux (independent of the Android runtime)
CLANG_INTERP="$(readelf -l "$(readlink -f "$CLANG")" 2>/dev/null | sed -n 's/.*interpreter: \([^]]*\)\]/\1/p' | head -1)"
if [[ -n "$CLANG_INTERP" ]]; then
    if [[ "$CLANG_INTERP" == /system/* ]]; then
        warn "clang interpreter is the Android linker ($CLANG_INTERP):"
        warn "this toolchain still depends on the Android runtime"
    else
        ok "clang interpreter: $CLANG_INTERP (plain Linux, no Android needed)"
    fi
fi

# confirm the sysroot is self-contained (the NDK ships libc.so)
SYSROOT="$PREBUILT/sysroot"
if [[ -f "$SYSROOT/usr/lib/aarch64-linux-android/$API/libc.so" ]]; then
    ok "sysroot : $SYSROOT (self-contained: libc.so/liblog.so/libdl.so)"
else
    warn "sysroot has no libc.so for API $API; linking may fail"
fi

# ---------- 3. ABI mapping ----------
# output: goarch|goarm|ndk_triple_prefix
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

# ---------- 4. check-only mode ----------
if [[ $CHECK_ONLY -eq 1 ]]; then
    echo
    log "environment check complete"
    echo
    echo "  host     : $(uname -s) $(uname -m)"
    echo "  Go     : $GO_VER"
    echo "  NDK    : $NDK_DIR"
    echo "  toolchain: $PREBUILT"
    echo "  sysroot: $SYSROOT"
    echo
    echo "  ABI            Go target       compiler"
    echo "  -------------  -------------  ------------------------------------"
    IFS=',' read -r -a _al <<< "$ARCHES"
    for abi in "${_al[@]}"; do
        spec="$(arch_spec "$abi" 2>/dev/null)" || { printf '  %-13s  (unknown ABI)\n' "$abi"; continue; }
        ga="${spec%%|*}"; r="${spec#*|}"; garm="${r%%|*}"; triple="${r##*|}"
        cc="${triple}${API}-clang"
        # the check must also look under the NDK bin directory
        ccp="$(PATH="$PREBUILT/bin:$PATH" command -v "$cc" 2>/dev/null || echo 'not found')"
        printf '  %-13s  %-13s  %s\n' "$abi" "android/${ga}${garm:+ GOARM=$garm}" "$ccp"
    done
    exit 0
fi

# ---------- 5. prepare the output ----------
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
export PATH="$PREBUILT/bin:$PATH"

[[ -n "$BASENAME" ]] || BASENAME="$(basename "$(cd "$PKG_SPEC" 2>/dev/null && pwd || echo app)")"
[[ "$PKG_SPEC" == "." ]] && [[ -z "${BASENAME:-}" ]] && BASENAME="app"

if [[ -z "$LDFLAGS_OVERRIDE" ]]; then
    LDFLAGS_VAL="-checklinkname=0 -s -w"
    # Go before 1.23 does not accept -checklinkname
    if [[ -n "${GOVER_NUM:-}" ]] && (( ${GOVER_NUM##*.} < 23 )); then
        LDFLAGS_VAL="-s -w"
    fi
else
    LDFLAGS_VAL="$LDFLAGS_OVERRIDE"
fi

echo
log "configuration"
echo "  out              : $OUT_DIR"
echo "  API level        : $API"
echo "  Go binary        : $GO_BIN"
echo "  ldflags          : $LDFLAGS_VAL"
echo "  tags             : ${TAGS:-<none>}"
echo "  arm64 static     : $([[ $STATIC_ARM64 -eq 1 ]] && echo yes || echo no)"
echo

# ---------- 6. build ----------
RESULT=()
FAILED=0

IFS=',' read -r -a ARCH_LIST <<< "$ARCHES"
for abi in "${ARCH_LIST[@]}"; do
    spec="$(arch_spec "$abi")" || { warn "unknown ABI: $abi, skipping"; FAILED=1; continue; }
    goarch="${spec%%|*}"; rest="${spec#*|}"; goarm="${rest%%|*}"; triple="${rest##*|}"

    # Pick the compiler; the arm32 triple prefix varies between NDKs.
    cc=""
    for cand in "${triple}${API}-clang" \
                "${triple}${API}-clang.exe" \
                "arm-linux-androideabi${API}-clang" \
                "armv7a-linux-androideabi${API}-clang"; do
        if command -v "$cand" >/dev/null 2>&1; then cc="$cand"; break; fi
    done
    if [[ -z "$cc" ]]; then
        bad "$abi: compiler not found (${triple}${API}-clang)"
        FAILED=1; continue
    fi

    out_path="$OUT_DIR/${SO_PREFIX}${BASENAME}_${abi}.so"
    err_file="$OUT_DIR/.err_$abi"

    # decide the CGO and static strategy
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
        printf '                NEEDED=%s\n' "${need:-<none, fully static>}"
        RESULT+=("$abi|$out_path|$size|${need:-static}")
        rm -f "$err_file"
    else
        printf '\033[1;31mFAIL\033[0m\n'
        sed 's/^/                /' "$err_file" | head -10
        FAILED=1
    fi
done

# ---------- 7. summary ----------
echo
log "summary"
echo "  ┌────────────────┬──────────────────────────────────────────────┐"
printf '  │ %-14s │ %-44s │\n' "ABI" "artifact"
echo "  ├────────────────┼──────────────────────────────────────────────┤"
for r in "${RESULT[@]:-}"; do
    [[ -n "$r" ]] || continue
    IFS='|' read -r abi path size need <<< "$r"
    name="$(basename "$path")"
    printf '  │ %-14s │ %-44s │\n' "$abi" "$name"
done
echo "  └────────────────┴──────────────────────────────────────────────┘"
echo
echo "  embed into an APK:"
for r in "${RESULT[@]:-}"; do
    [[ -n "$r" ]] || continue
    IFS='|' read -r abi path size need <<< "$r"
    printf '    %-13s -> jniLibs/%s/\n' "$abi" "$abi"
done

if [[ $FAILED -ne 0 ]]; then
    die "some ABIs failed"
fi
log "all ABIs built successfully"
