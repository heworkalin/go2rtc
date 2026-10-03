# Android 4 架构交叉编译工具链（脱离 Android 运行时）

在**任意普通 Linux**（x86_64 / arm64，无需 Android、无需 Termux、无需 root）上，
交叉编译 go2rtc 等 Go 项目的 4 个 Android ABI。

---

## 快速开始

```bash
# 1. 一键准备环境（补丁源 + 官方 Go + 校验 NDK）
./setup-android-toolchain.sh -n ~/Android/Sdk/ndk/29.0.14206865 -o ./android-toolchain

# 2. 编译 4 架构
./android-cross-build.sh -n ~/Android/Sdk/ndk/29.0.14206865 \
    -g ./android-toolchain/goroot -o ./android-out --tags no_ui
```

产物直接放进 APK：

```
android-out/libgo2rtc_arm64-v8a.so   -> jniLibs/arm64-v8a/
android-out/libgo2rtc_armeabi-v7a.so -> jniLibs/armeabi-v7a/
android-out/libgo2rtc_x86.so         -> jniLibs/x86/
android-out/libgo2rtc_x86_64.so      -> jniLibs/x86_64/
```

---

## 脚本说明

| 脚本 | 作用 |
|---|---|
| `setup-android-toolchain.sh` | 一键：取补丁源 → 下官方 Go → 打补丁 → 校验 NDK |
| `termux-go-fetch.sh` | 只取 Termux 补丁源（10 个 src 文件，36 KB） |
| `patch-goroot-termux.sh` | 把 Termux stdlib 补丁打到任意 GOROOT（支持 `--revert`） |
| `android-cross-build.sh` | NDK 4 架构交叉编译（支持 `--check` 环境自检） |

---

## 必下 / 不必下

### ✅ 必下（3 样，约 100 MB + NDK）

| 内容 | 体积 | 说明 |
|---|---|---|
| Termux golang deb（**1 个架构即可**） | 36 MB | 仅提取 10 个 src 文件 |
| 官方 Go 工具链（Linux host 版） | 67 MB | **必须是官方版，不是 Termux 版** |
| Android NDK | 用户自备 | 版本不同，sysroot/clang 内容不同 |

### ❌ 不必下（避免浪费 ~600 MB）

| 内容 | 原因 |
|---|---|
| 另外 3 个架构的 Termux 包 | **4 架构 `src/` 完全相同**（129 MB，`net/` 目录 0 差异） |
| Termux 的 `bin/go`、`pkg/tool/android_*/` | bionic ELF（`/system/bin/linker64`），纯 Linux 无法执行 |
| Termux 的 clang / llvm / libc++ / ndk-sysroot | NDK 已提供，且 Termux 版是 bionic |
| Termux `bootstrap-*.zip` | Termux 根文件系统，与本方案无关 |

> **为什么 1 个架构的 src 就够？**
> 实测对比 aarch64 / arm / i686 / x86_64 四份 `src/`，129 MB 内容几乎完全一致。
> 仅 3 个「架构相关」文件不同，且本方案都不使用：
> - `src/cmd/cgo/zdefaultcc.go` — 默认 CC 名（我们用 `CC=` 显式指定）
> - `src/cmd/go/internal/cfg/zdefaultcc.go` — 同上
> - `src/internal/buildcfg/zbootstrap.go` — `defaultGO_LDSO`（NDK 自动设置）
>
> 其余架构差异全部由 NDK 的 clang + sysroot 补足。

---

## 核心原理

### Go 对 android/* 的链接规则（硬编码）

| 目标 | `CGO_ENABLED=0` | 说明 |
|---|---|---|
| `android/arm64` | ✅ 允许 | 唯一能纯静态的架构 |
| `android/arm` | ❌ 报 `cannot find runtime/cgo` | 强制 external linking |
| `android/386` | ❌ 同上 | 强制 external linking |
| `android/amd64` | ❌ 同上 | 强制 external linking |

来源：`cmd/go/internal/work/init.go` 的 `mustUseExternalLinker`。
**这是 Go 设计，不是环境缺失。**

结论：要编 4 架构，**一律 `CGO_ENABLED=1` + Android NDK clang**。

### 为什么用 NDK 而不是 Termux 工具链

| | 解释器 | 纯 Linux 可运行 |
|---|---|---|
| Termux clang/go | `/system/bin/linker64` | ❌ |
| NDK clang | `/lib/ld-linux-aarch64.so.1` | ✅ |
| NDK sysroot | 自带 `libc.so`/`liblog.so`/`libdl.so` | ✅ 自包含 |

两者链接出的产物 ABI 完全一致（都是 bionic + `/system/bin/linker`），
所以用 NDK 不会有兼容性差异。

### Termux 补丁做了什么（6 处改动）

Termux 版 Go 对标准库做了 Android 适配，让程序读正确的路径：

| 文件 | 改动 |
|---|---|
| `net/conf.go` | 加 `//go:build !android` |
| `net/dnsclient_unix.go` | 加 `//go:build !android` |
| `net/interface_linux.go` | 加 `!android`（netlink 回退） |
| `syscall/netlink_linux.go` | 加 `!android` |
| `os/file_unix.go` | tmp → `<PREFIX>/tmp` |
| `crypto/x509/root_linux.go` | CA → `<PREFIX>/etc/tls/cert.pem` |
| **新增** | `net/conf_android.go`、`net/dnsclient_android.go`、`net/interface_android.go`、`syscall/netlink_android.go` |

其中 `<PREFIX>` 默认 `/data/data/com.termux/files/usr`，可用 `--prefix` 改。

**不打补丁的后果**：产物会读 `/etc/resolv.conf`、`/etc/ssl/...`，
在 Android 上这些路径不存在或被 SELinux 拒绝 → DNS / HTTPS 失败。

---

## 选项速查

### setup-android-toolchain.sh

```
-n, --ndk DIR        NDK 路径
-o, --out DIR        工作目录
-G, --go-version V   Go 版本（默认取 Termux 包同版本）
-m, --mirror URL     Go 镜像（如 https://golang.google.cn/dl）
--skip-termux        不打补丁
--skip-go            不下载 Go
--check              只检查
```

### android-cross-build.sh

```
-n, --ndk DIR        NDK 路径（默认自动探测）
-o, --out DIR        输出目录
-t, --api NUM        API level（默认 24）
-a, --arch LIST      目标 ABI（默认全部 4 个）
-g, --goroot DIR     指定 GOROOT
-p, --package SPEC   要编译的包（默认 .）
--tags TAGS          build tags
--static-arm64       arm64 用 CGO_ENABLED=0 纯静态
--check              只检查环境
```

### patch-goroot-termux.sh

```
-g, --goroot DIR    目标 GOROOT（就地修改，自动备份）
-P, --prefix PATH   $PREFIX（默认 /data/data/com.termux/files/usr）
-s, --source DIR    补丁来源（GOROOT 或 patch-src 目录）
-n, --dry-run       只预览
-R, --revert        撤销
```

---

## 已知限制

1. **Go 版本必须与 Termux 补丁同版本**
   Termux 1.27.1 的 `dnsclient_android.go` 用到 `internal/strconv`（Go 1.26+ 才有）。
   用 Go 1.25 打包会报 `package internal/strconv is not in std`。

2. **NDK 版本由用户自备**
   不同 NDK 版本的 sysroot / clang 内容不同，本方案不预设。NDK r26+ 均可。

3. **arm/386/amd64 无法纯静态**
   这是 Go 的硬编码限制。若必须静态，只能牺牲 android/arm64 之外的架构。

---

## 实测记录

| 环境 | Go | NDK | 4 架构 |
|---|---|---|---|
| 本机 proot Ubuntu 24.04 / arm64 | 1.25.0 + 1.27.1 | r29 | ✅ |
| 远端 Debian 12 / arm64（chroot） | 1.19.8 + 1.27.1 | r29（推送） | ✅ |

产物校验（4 架构）：
```
ELF 64-bit LSB pie executable, ARM aarch64     NEEDED=liblog.so+libdl.so+libc.so
ELF 32-bit LSB pie executable, ARM             NEEDED=liblog.so+libdl.so+libc.so
ELF 32-bit LSB pie executable, Intel 80386     NEEDED=liblog.so+libdl.so+libc.so
ELF 64-bit LSB pie executable, x86-64          NEEDED=liblog.so+libdl.so+libc.so
```

Termux 补丁生效校验（4 架构产物内均含）：
`/data/data/com.termux/files/usr/etc/resolv.conf`、`.../etc/tls/cert.pem`、`.../tmp`
