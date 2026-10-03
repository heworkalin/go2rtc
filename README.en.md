<h1 align="center">go2rtc</h1>

<p align="center">
  <b>Android embedding branch</b> · <code>feature/android-embedded</code>
</p>

<p align="center">
  <a href="README.md">中文说明</a> ·
  <a href="https://github.com/AlexxIT/go2rtc">Upstream project</a> ·
  <a href="LICENSE">MIT License</a>
</p>

---

> [!WARNING]
> **This branch is AI-assisted.**
>
> Most of the branch's code, docs and commit messages were produced or
> rewritten by AI. They can contain hallucinated statements, claims that were
> never reproduced, and source line numbers that no longer point where they
> say. Do not trust any of it without checking.
>
> Worth verifying in particular:
> - the quoted measurements, versions and file/line references in this file
>   and in `scripts/ANDROID-4ARCH.md`
> - the characterisation of the ported QR login flow in `LICENSE-ANDROID`
> - the Xiaomi protocol notes (compare against the Python source yourself)
>
> This branch is not maintained by the go2rtc upstream and is not kept in
> sync with it. Provided **AS IS**, with no warranty of correctness.

---

## What this branch is

Upstream [go2rtc](https://github.com/AlexxIT/go2rtc) is a zero-dependency
camera streaming service that runs as a standalone process with a built-in
web UI. It cannot simply be dropped into an Android app:

- An Android app has no writable working directory, so the config file and
  logs have nowhere to live.
- Android provides no `/etc/resolv.conf`, so a child process falls back to
  `[::1]:53` and every lookup fails.
- Exposing the HTTP API on the device means opening a TCP port to the whole
  device.
- The bundled web UI costs several MB of APK size for nothing.

This branch turns go2rtc into something you can **embed in an Android app as
a background service**, while **leaving the existing usage untouched** (pass
none of the new flags and it behaves exactly like upstream).

> The original upstream documentation is in
> [docs/upstream/README.upstream.md](docs/upstream/README.upstream.md).
> For features, protocols, codecs and configuration, refer to that file and
> to [website/](website/).

---

## Positioning of this branch

To be explicit: **this branch's feature is Android embedding, not new
platform support.**

| | Upstream `master` | This branch |
|---|---|---|
| Platforms in `scripts/build.sh` | win / linux / darwin / freebsd (13 targets) | **unchanged, identical** |
| Code changes | — | 11 files only (`api` / `app` / `rtsp` / `xiaomi`) |
| Intended use | standalone service, all platforms | **embedded in an Android app** |

In other words, the upstream code remains cross-platform (the Windows,
macOS, Linux and FreeBSD build scripts are all still there and usable); this
branch only **layers** Android embedding on top. If you want the standalone
service, use upstream directly — you do not need this branch.

---

## What upstream provides

Kept intact by this branch (details in the
[upstream README](docs/upstream/README.upstream.md)):

- zero-dependency **single binary**, upstream supports Windows / macOS /
  Linux / FreeBSD
- **dozens of input and output protocols**, with zero delay where supported
- on-demand transcoding through [FFmpeg](internal/ffmpeg/README.md)
- **two-way audio** in many formats
- mixing tracks from different sources into one stream
- automatic negotiation of the formats and codecs a client supports
- **streaming stats** for all active connections
- embeddable in any project, or usable as a **standalone app**

---

## What we changed

| Area | Change | Why |
|---|---|---|
| `-work-dir` flag | New; also via the `GO2RTC_WORK_DIR` environment variable | Android has no writable CWD, so every runtime file must live in the app's private directory |
| `go2rtc.yaml` / `go2rtc.log` | Relative paths are **anchored to `-work-dir`** when it is set | Config and logs must not depend on the process CWD |
| `api.unix_listens` | New: a list of Unix sockets, supporting the `@name` abstract namespace | Talk to the service without opening a TCP port to the whole device |
| `g2.ready` handshake file | New: written into `-work-dir` once the listeners are up | The host discovers the sockets and ports instead of parsing stdout |
| `-dns a,b` flag | New: installs a `net.Resolver` that queries those servers | Android ships **no** `/etc/resolv.conf`; without it lookups fell back to `[::1]:53` and every request failed |
| `no_ui` build tag | New: `go build -tags no_ui` drops the bundled web UI | Saves ~4 MB of APK size; the host provides its own UI |
| `g2.ready` port fields | `api_port` and `rtsp_port` are reported **separately** | An earlier build put the API port in a single `tcp_port`, so hosts advertised 1984 as the RTSP endpoint |
| Xiaomi cloud support | QR login, a file-exchange mode for QR/captcha images, shared-home enumeration | See [`internal/xiaomi/README.md`](internal/xiaomi/README.md) |

### Layout

```
go2rtc/
├── internal/
│   ├── api/            # Unix socket listeners, the g2.ready handshake
│   ├── app/            # -work-dir / -dns, path anchoring
│   └── xiaomi/         # Xiaomi cloud integration
├── scripts/            # Android 4-ABI cross-compilation toolchain
│   ├── setup-android-toolchain.sh    # one-shot setup
│   ├── termux-go-fetch.sh            # fetch the Termux patch sources
│   ├── patch-goroot-termux.sh        # pat them onto an official GOROOT
│   ├── android-cross-build.sh        # build the four ABIs
│   └── ANDROID-4ARCH.md              # full write-up
└── docs/
    └── upstream/       # archived upstream documentation
```

---

## What you need for Android development

| # | Item | Notes | Required |
|---|---|---|---|
| 1 | **Android app project** | An ordinary Android project with a foreground service and UI | yes |
| 2 | **Android NDK** | r26+ recommended. **Not** included with the SDK by default | yes |
| 3 | **Official Go toolchain** | The Linux/macOS build from go.dev. **Not** the Termux build | yes |
| 4 | **Termux Go patch sources** | Ten standard-library files, about 36 KB | recommended |

> No Android device, no Termux and no root are required. A plain Linux host
> (x86_64 or arm64) can build all four ABIs.

### Why not the Termux toolchain

Termux's `go` and `clang` are **bionic ELF** binaries (interpreter
`/system/bin/linker64`). They only run where the Android system libraries and
linker exist, so they cannot be used on plain Linux, in a chroot, in a
container, or in CI.

The NDK's clang is an ordinary Linux ELF binary (interpreter
`/lib/ld-linux-*.so`) with a self-contained sysroot, so it runs anywhere.

### What the Termux patches solve

Android has no `/etc/resolv.conf`, `/etc/ssl/certs` and so on. A program built
with stock Go reads those nonexistent paths, so DNS and HTTPS fail. Termux's
Go patches the standard library for Android; this branch **ports those patches
onto official Go**:

| File | Change |
|---|---|
| `net/conf.go` | add `//go:build !android` |
| `net/dnsclient_unix.go` | add `//go:build !android` |
| `net/interface_linux.go` | add `!android` (netlink fallback, works around an Android 11+ restriction) |
| `syscall/netlink_linux.go` | add `!android` |
| `os/file_unix.go` | temp dir → `<PREFIX>/tmp` |
| `crypto/x509/root_linux.go` | CA path → `<PREFIX>/etc/tls/cert.pem` |
| **4 new files** | `net/conf_android.go`, `net/dnsclient_android.go`, `net/interface_android.go`, `syscall/netlink_android.go` |

`<PREFIX>` defaults to `/data/data/com.termux/files/usr`; change it with
`--prefix`.

> If the `-dns` flag is enough for you, you can skip the patches
> (`--skip-termux`).

---

## Building all four ABIs

```bash
# 1. one-shot setup: fetch patch sources, download official Go, check the NDK
./scripts/setup-android-toolchain.sh \
    -n ~/Android/Sdk/ndk/29.0.14206865 \
    -o ./android-toolchain

# 2. build the four ABIs
./scripts/android-cross-build.sh \
    -n ~/Android/Sdk/ndk/29.0.14206865 \
    -g ./android-toolchain/goroot \
    -o ./android-out --tags no_ui
```

Place the artifacts into the APK:

```
android-out/libgo2rtc_arm64-v8a.so   -> jniLibs/arm64-v8a/
android-out/libgo2rtc_armeabi-v7a.so -> jniLibs/armeabi-v7a/
android-out/libgo2rtc_x86.so         -> jniLibs/x86/
android-out/libgo2rtc_x86_64.so      -> jniLibs/x86_64/
```

### Two pitfalls that matter on Android

1. **File name and location**
   The file must be named `lib*.so` and live in `jniLibs/<abi>/`, and
   `build.gradle` must set `useLegacyPackaging = true`. Otherwise Android
   never unpacks it into `nativeLibraryDir`, which is the only place it may
   be executed from.

2. **DNS**
   Android has no `/etc/resolv.conf`. Pick one:
   - pass `-dns` at runtime, with the values from
     `ConnectivityManager.getLinkProperties().getDnsServers()`; or
   - build with the Termux patch sources so the binary reads
     `<PREFIX>/etc/resolv.conf`.

Full details, including why only `android/arm64` can be built with
`CGO_ENABLED=0`, in [`scripts/ANDROID-4ARCH.md`](scripts/ANDROID-4ARCH.md).

---

## How the host talks to it

```
┌─────────────────────────────────────────────┐
│        Android app (UI + foreground service)│
│                                             │
│   1. spawn child      2. read g2.ready      │
└──────────┬──────────────────┬───────────────┘
           │                  │
           ▼                  │
┌──────────────────────────┐  │
│   go2rtc child process   │◄─┘
│                          │
│  ├─ Unix socket @go2rtc_api              (abstract, uid-isolated)
│  ├─ Unix socket <workdir>/http.sock      (filesystem, chmod 0600)
│  ├─ TCP :1984                            (optional; needs api.listen)
│  └─ RTSP :8554                           (players connect here)
└──────────────────────────┘
```

The flow:

1. the app spawns `libgo2rtc.so` with `--work-dir <private dir>` and
   `--dns <resolvers from ConnectivityManager>`;
2. go2rtc creates the directory, writes its config, and starts listening;
3. the host polls `g2.ready` to learn the socket paths, `api_port` and
   `rtsp_port`;
4. HTTP requests go over the Unix socket (plain HTTP, no TLS) or over TCP;
5. the player connects to `rtsp://127.0.0.1:<rtsp_port>/<stream>`.

### `g2.ready` format

Written once the API listener is up. Poll for it, or use a `FileObserver`:

```json
{
  "pid": 12345,
  "listen": ":1984",
  "api_port": 1984,
  "rtsp_listen": ":8554",
  "rtsp_port": 8554,
  "unix": ["@go2rtc_api", "/data/user/0/com.example.app/files/go2rtc/http.sock"],
  "version": "1.9.4",
  "config": "/data/user/0/com.example.app/files/go2rtc/go2rtc.yaml",
  "started_at": 1730000000
}
```

> `api_port` and `rtsp_port` are deliberately separate. Earlier builds
> reported only `tcp_port`, which made hosts treat the API port 1984 as the
> RTSP endpoint.

### Minimal config for an embedded host

```yaml
api:
  unix_listens:
    - "@go2rtc_api"                          # abstract: no leftover file, no 108-byte limit
    - "/data/user/0/com.example.app/files/go2rtc/http.sock"
  # listen: "127.0.0.1:1984"                 # optional: only if you need TCP
log:
  level: info
```

Add `streams:` as usual. Because `-work-dir` is set, a relative
`-c go2rtc.yaml` resolves to `<work-dir>/go2rtc.yaml`.

### New flags in this branch

```
      --work-dir DIR   directory for config, logs and cache (Android embedding)
      --dns a,b,c      DNS servers (required on Android, which has no resolv.conf)
```

New config key:

```yaml
api:
  unix_listen: "..."      # pre-existing: a single socket
  unix_listens: [...]     # new in this branch: several at once
```

---

## Script options

### setup-android-toolchain.sh

```
-n, --ndk DIR        NDK path
-o, --out DIR        working directory
-G, --go-version V   Go version (default: match the Termux package)
-m, --mirror URL     Go mirror (e.g. https://golang.google.cn/dl)
--skip-termux        do not apply the Termux patches
--skip-go            do not download Go
--check              check the environment only
```

### android-cross-build.sh

```
-n, --ndk DIR        NDK path (auto-detected by default)
-o, --out DIR        output directory
-t, --api NUM        Android API level (default 24)
-a, --arch LIST      target ABIs (default all four)
-g, --goroot DIR     GOROOT to use
-p, --package SPEC   package to build (default .)
--tags TAGS          build tags (use no_ui for Android)
--static-arm64       build arm64 with CGO_ENABLED=0
--check              check the environment only
```

---

## Known limitations

1. **The Go version must match the Termux patch source.**
   Termux 1.27.1's `dnsclient_android.go` imports `internal/strconv`, which
   only exists from Go 1.26. Patching a Go 1.25 GOROOT fails with
   `package internal/strconv is not in std`.

2. **Only `android/arm64` can be built fully static.**
   Go hardcodes external linking (that is, `CGO_ENABLED=1`) for
   `android/arm`, `386` and `amd64`, failing otherwise with
   `cannot find runtime/cgo`. That is a Go design decision, not a missing
   dependency. All four ABIs therefore go through `CGO_ENABLED=1` + NDK.

3. **The NDK is supplied by the user.**
   Different NDK releases ship different sysroots and clang builds, so none
   is assumed here. NDK r26+ all work.

---

## Licensing

This repository is a third-party fork. Its code comes in three layers:

| Layer | Content | Copyright | License |
|---|---|---|---|
| 1 | Upstream go2rtc code | © 2022 Alexey Khit | MIT ([LICENSE](LICENSE)) |
| 2 | Ported Xiaomi QR login flow | © 2020 Piotr Machowski | MIT |
| 3 | **This branch's Android changes** | © 2026 heworkalin | MIT |

All three use the same MIT terms: use, modify and redistribute freely, but
**keep all of the copyright notices above**.

Full details in [`LICENSE-ANDROID`](LICENSE-ANDROID), which covers:
- a file-by-file list of this branch's changes
- the mapping of the ported QR login flow
  ([Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor), MIT)
- the licenses of third-party build components

### Positioning

We are **not** the Xiaomi official team, and **not** the go2rtc upstream
maintainers — just the maintainers of a third-party fork, trying to make it a
little more usable for our own case.

---

## Build components and their upstream declarations

### 1. Termux golang package (only the 10 patch files are taken)

From `termux-packages/packages/golang/build.sh` and the apt metadata:

| Field | Value |
|---|---|
| `TERMUX_PKG_LICENSE` | **BSD 3-Clause** |
| `TERMUX_PKG_HOMEPAGE` | `https://go.dev/` |
| `TERMUX_PKG_SRCURL` | `https://go.dev/dl/go1.27.1.src.tar.gz` (official source) |
| `TERMUX_PKG_DEPENDS` | **`clang`** |
| `TERMUX_PKG_ANTI_BUILD_DEPENDS` | `clang` |
| `TERMUX_PKG_RECOMMENDS` | **`resolv-conf`** |
| `TERMUX_PKG_MAINTAINER` | `@termux` |
| apt `Depends` / `Recommends` | `clang` / `resolv-conf` |

What those declarations mean here:

| Requirement | Do we need it? | Why |
|---|---|---|
| `Depends: clang` | no | It is a Termux *runtime* dependency. We never execute Termux's `go`; we use official Go plus the NDK clang |
| `Recommends: resolv-conf` | **relevant** | That package provides `<PREFIX>/etc/resolv.conf`, which our patches read. So the embedding host must write that file itself, or use `-dns` |
| `License: BSD 3-Clause` | **yes** | See below |

Note on the patch scripts: `termux-packages/LICENSE.md` states that "the
scripts and patches to build each package is licensed under the same license
as the actual package", so the golang patch scripts are **BSD 3-Clause**, not
GPL (the GPL-3.0 applies only to `root-packages/` and `disabled-packages/`,
which this project does not touch).

We did not copy those scripts; we implemented equivalent logic ourselves.

The ten extracted files keep their original headers:

```go
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
```

If you commit and redistribute them, keep those headers.

### 2. Official Go toolchain

Downloaded from `go.dev/dl/`, also **BSD 3-Clause**, © The Go Authors.

### 3. Android NDK

Installed by the user and governed by its own license (`$NDK/NOTICE`). Not
redistributed here.

---

## Credits

Built on **[AlexxIT/go2rtc](https://github.com/AlexxIT/go2rtc)**
(MIT, © 2022 Alexey Khit).

The Xiaomi QR login flow is **ported from**
**[Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)**
(MIT, © 2020 Piotr Machowski), specifically its `QrCodeXiaomiCloudConnector`
(`token_extractor.py`, lines 605–755). The mapping and the differences are
recorded in
[`docs/migration/qr-login-migration-guide.md`](docs/migration/qr-login-migration-guide.md).

- Upstream repository: <https://github.com/AlexxIT/go2rtc>
- Upstream README: [`docs/upstream/README.upstream.md`](docs/upstream/README.upstream.md)
- Upstream branch: `upstream/master`

Licensing details: [LICENSE](LICENSE) and [LICENSE-ANDROID](LICENSE-ANDROID).
