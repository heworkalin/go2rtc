<h1 align="center">
  <a href="https://github.com/AlexxIT/go2rtc">
    <img src="./website/images/logo.gif" alt="go2rtc - GitHub">
  </a>
</h1>

<p align="center">
  <b>Android 嵌入分支</b> · <code>feature/android-embedded</code>
</p>

<p align="center">
  <a href="docs/upstream/README.upstream.md">English README</a> ·
  <a href="https://github.com/AlexxIT/go2rtc">上游项目</a> ·
  <a href="LICENSE">MIT License</a>
</p>

---

> [!WARNING]
> **本分支由 AI 辅助维护。**
>
> 分支新增的代码、文档与提交信息，绝大部分由 AI 生成或改写，
> **可能包含幻觉内容、未经验证的结论，或与实际上游行为不符的描述**。
> 请勿不加验证地全部相信。
>
> 尤其请注意以下部分：
> - 本文档与 `scripts/ANDROID-4ARCH.md` 中引用的「实测结果」「版本号」「文件行号」
> - `LICENSE-ANDROID` 中对移植范围与许可的定性描述
> - 小米 QR 登录流程的协议细节说明（需对照 Python 源码自行核实）
>
> 本分支不是 go2rtc 上游官方维护，也不保证与上游同步。
> 按 **AS IS** 提供，不对正确性作任何担保。

---

## 这个分支是什么

上游 [go2rtc](https://github.com/AlexxIT/go2rtc) 是一个零依赖的摄像头流媒体服务，
以独立进程运行、自带 Web 界面。它很好用，但**无法直接塞进 Android App**：

- Android 应用没有可写的当前目录，配置文件与日志无处安放；
- Android 不提供 `/etc/resolv.conf`，子进程 DNS 解析会退到 `[::1]:53` 然后全军覆没；
- 要在设备上暴露 HTTP API，只能开 TCP 端口，等于对整个设备开放；
- 自带 Web UI 会白白占掉几 MB 的 APK 体积。

本分支把 go2rtc 改造成**可作为后台服务嵌入 Android App** 的形态，
同时**保持原有用法完全不变**（不传新参数时行为与上游一致）。

> 上游原始说明见 [English README](docs/upstream/README.upstream.md)，
> 其余功能文档（协议、编解码、配置项等）请以该文件及 [website/](website/) 为准。

---

## 本分支的定位

需要特别说明：**本分支的「特性」是 Android 嵌入，不是新增平台支持。**

| | 上游 `master` | 本分支 |
|---|---|---|
| `scripts/build.sh` 目标平台 | win / linux / darwin / freebsd（13 个） | **未修改，完全一致** |
| 代码改动 | — | 仅 11 个文件（`api` / `app` / `rtsp` / `xiaomi`） |
| 实际用途 | 独立服务，全平台 | **作为库嵌入 Android App** |

也就是说：上游代码本身仍然是跨平台的（Windows / macOS / Linux / FreeBSD 的构建
脚本都被保留且可用），本分支只是在它之上**叠加**了 Android 嵌入能力。
如果你要的是独立服务，直接看 [英文 README](docs/upstream/README.upstream.md) 即可，
不必用本分支。

---

## 上游项目简介

以下为上游能力概览（各特性的详细说明见
[英文 README](docs/upstream/README.upstream.md)）：

- 零依赖的**单一可执行文件**，上游支持 Windows / macOS / Linux / FreeBSD
- 数十种**输入与输出协议**，多协议下可做到**零延迟**
- 按需转码，仅在必要时调用 [FFmpeg](internal/ffmpeg/README.md)
- 多种格式的**双向语音**支持
- 混合不同来源的音视频轨到同一条流
- 自动匹配客户端支持的格式与编解码器
- 所有活动连接的**流统计**
- 可**集成到任意项目**，也可作为**独立应用**运行

---

## 我们对它做了什么改造

### 改造一览

| 区域 | 改动 | 原因 |
|---|---|---|
| `-work-dir` 参数 | 新增，也可用环境变量 `GO2RTC_WORK_DIR` 传入 | Android 没有可写的当前目录，所有运行期文件必须落在应用私有目录 |
| `go2rtc.yaml` / `go2rtc.log` | 设置 `-work-dir` 后，相对路径**锚定到该目录** | 配置与日志不能依赖进程当前目录 |
| `api.unix_listens` | 新增：Unix socket 列表，支持 `@name` 抽象命名空间 | 不用对整台设备开 TCP 端口即可通信 |
| `g2.ready` 握手文件 | 新增：监听就绪后写入 `-work-dir` | 宿主进程可据此发现套接字与端口，无需解析 stdout |
| `-dns a,b` 参数 | 新增：安装自定义 `net.Resolver` 直连指定 DNS | Android **没有** `/etc/resolv.conf`，原实现会退到 `[::1]:53` 导致全部请求失败 |
| `no_ui` 构建标签 | 新增：`go build -tags no_ui` 去掉内置 Web UI | 省下约 4 MB APK 体积，界面由宿主 App 自己提供 |
| `g2.ready` 端口字段 | `api_port` 与 `rtsp_port` **分开上报** | 早期实现把 API 端口写进 `tcp_port`，导致宿主把 1984 当成 RTSP 端口 |
| 小米云支持 | 新增二维码登录、验证码/二维码文件交换模式、共享家庭枚举 | 见 [`internal/xiaomi/README.md`](internal/xiaomi/README.md) |

### 目录结构

```
go2rtc/
├── internal/
│   ├── api/            # Unix socket 监听、g2.ready 握手文件
│   ├── app/            # -work-dir / -dns、路径锚定
│   └── xiaomi/         # 小米云集成
├── scripts/            # Android 4 架构交叉编译工具链
│   ├── setup-android-toolchain.sh    # 一键准备环境
│   ├── termux-go-fetch.sh            # 取 Termux 补丁源（10 个文件）
│   ├── patch-goroot-termux.sh        # 给官方 Go 打 Termux 补丁
│   ├── android-cross-build.sh        # 编译 4 个 ABI
│   └── ANDROID-4ARCH.md              # 完整技术说明
└── docs/
    └── upstream/       # 上游原始文档存档
```

---

## 要做 Android 开发，需要准备什么

### 四项准备

| # | 项目 | 说明 | 是否必需 |
|---|---|---|---|
| 1 | **Android 应用工程** | 普通 Android 项目，含前台服务与 UI | ✅ |
| 2 | **Android NDK** | r26+ 建议。SDK 默认**不含**，需单独安装 | ✅ |
| 3 | **官方 Go 工具链** | 从 go.dev 下载的 Linux/macOS 版。**不能用 Termux 版** | ✅ |
| 4 | **Termux Go 补丁源** | 仅 10 个标准库文件，约 36 KB | ⭐ 建议 |

> **注意**：不需要 Android 设备、不需要 Termux、不需要 root。
> 一台普通 Linux（x86_64 或 arm64）即可完成全部 4 个架构的编译。

### 为什么不能用 Termux 的 Go

Termux 的 `go` 与 `clang` 是 **bionic ELF**（解释器为 `/system/bin/linker64`），
只能在有 Android 系统库 + linker 的环境里执行。在纯 Linux、chroot、容器或 CI 中
**无法运行**，所以不能当构建工具。

NDK 的 clang 则是普通 Linux ELF（解释器为 `/lib/ld-linux-*.so`），
且自带自包含的 sysroot，任何 Linux 上都能跑。

### Termux 补丁解决什么问题

Android 没有 `/etc/resolv.conf`、`/etc/ssl/certs` 等路径。上游 Go 编译出的程序会去读
这些不存在的路径，导致 DNS 与 HTTPS 失败。Termux 版 Go 对标准库做了 Android 适配，
本分支把这套适配**移植到官方 Go 上**：

| 文件 | 改动 |
|---|---|
| `net/conf.go` | 加 `//go:build !android` |
| `net/dnsclient_unix.go` | 加 `//go:build !android` |
| `net/interface_linux.go` | 加 `!android`（netlink 回退，绕过 Android 11+ 限制） |
| `syscall/netlink_linux.go` | 加 `!android` |
| `os/file_unix.go` | 临时目录 → `<PREFIX>/tmp` |
| `crypto/x509/root_linux.go` | CA 证书 → `<PREFIX>/etc/tls/cert.pem` |
| **新增 4 个文件** | `net/conf_android.go`、`net/dnsclient_android.go`、`net/interface_android.go`、`syscall/netlink_android.go` |

其中 `<PREFIX>` 默认 `/data/data/com.termux/files/usr`，可通过 `--prefix` 修改。

> 若你觉得 `-dns` 参数已经够用，也可以跳过补丁（`--skip-termux`）。

---

## 编译 4 个架构

```bash
# 1. 一键准备环境（取补丁源 + 下载官方 Go + 校验 NDK）
./scripts/setup-android-toolchain.sh \
    -n ~/Android/Sdk/ndk/29.0.14206865 \
    -o ./android-toolchain

# 2. 编译 4 个 ABI
./scripts/android-cross-build.sh \
    -n ~/Android/Sdk/ndk/29.0.14206865 \
    -g ./android-toolchain/goroot \
    -o ./android-out --tags no_ui
```

产物放入 APK：

```
android-out/libgo2rtc_arm64-v8a.so   -> jniLibs/arm64-v8a/
android-out/libgo2rtc_armeabi-v7a.so -> jniLibs/armeabi-v7a/
android-out/libgo2rtc_x86.so         -> jniLibs/x86/
android-out/libgo2rtc_x86_64.so      -> jniLibs/x86_64/
```

### 两个必须注意的坑

1. **文件名与位置**
   必须叫 `lib*.so` 且放在 `jniLibs/<abi>/`，并在 `build.gradle` 设
   `useLegacyPackaging = true`。否则 Android 不会把它解压到 `nativeLibraryDir`，
   而只有那里才允许执行。

2. **DNS**
   Android 没有 `/etc/resolv.conf`。两种解法二选一：
   - 运行时传 `-dns`，值取自 `ConnectivityManager.getLinkProperties().getDnsServers()`；
   - 或用 Termux 补丁源编译，让二进制去读 `<PREFIX>/etc/resolv.conf`。

完整技术说明（含"为什么只有 arm64 能纯静态"等）见
[`scripts/ANDROID-4ARCH.md`](scripts/ANDROID-4ARCH.md)。

---

## 通信机制

### 架构图

```
┌─────────────────────────────────────────────┐
│           Android App（UI + 前台服务）        │
│                                             │
│   ① 拉起子进程       ② 读取 g2.ready         │
└──────────┬──────────────────┬───────────────┘
           │                  │
           ▼                  │
┌──────────────────────────┐  │
│   go2rtc 子进程           │◄─┘
│                          │
│  ├─ Unix socket @go2rtc_api                （抽象命名空间，按 uid 隔离）
│  ├─ Unix socket <workdir>/http.sock        （文件系统，chmod 0600）
│  ├─ TCP :1984                              （可选，需配 api.listen）
│  └─ RTSP :8554                             （播放器连这里）
└──────────────────────────┘
```

### 完整流程

1. App 用 `--work-dir <私有目录>` 与 `--dns <从 ConnectivityManager 读到的 DNS>`
   启动 `libgo2rtc.so`；
2. go2rtc 创建目录、写配置、开始监听；
3. 宿主轮询 `g2.ready`，拿到套接字路径、`api_port`、`rtsp_port`；
4. HTTP 请求走 Unix socket（明文，无 TLS）或 TCP；
5. 播放器连 `rtsp://127.0.0.1:<rtsp_port>/<stream>`。

### g2.ready 文件格式

监听就绪后写入，可用轮询或 `FileObserver` 监听：

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

> `api_port` 与 `rtsp_port` **故意分开**。早期版本只上报 `tcp_port`，
> 宿主会把 API 端口 1984 误当成 RTSP 端点。

### 内嵌场景的最小配置

```yaml
api:
  unix_listens:
    - "@go2rtc_api"                          # 抽象命名空间：重启不残留、无 108 字节路径限制
    - "/data/user/0/com.example.app/files/go2rtc/http.sock"
  # listen: "127.0.0.1:1984"                 # 可选：需要 TCP 时才开
log:
  level: info
```

`streams:` 按上游语法正常配置即可。由于设置了 `-work-dir`，
相对路径 `-c go2rtc.yaml` 会解析为 `<work-dir>/go2rtc.yaml`。

### 命令行参数速查（本分支新增）

```
      --work-dir DIR   配置/日志/缓存的写入目录（Android 嵌入选它）
      --dns a,b,c      DNS 服务器列表（Android 无 resolv.conf 时必传）
```

配置文件新增项：

```yaml
api:
  unix_listen: "..."      # 原来就支持，单个 socket
  unix_listens: [...]     # 本分支新增，可监听多个
```

---

## 编译选项

### setup-android-toolchain.sh

```
-n, --ndk DIR        NDK 路径
-o, --out DIR        工作目录
-G, --go-version V   Go 版本（默认取 Termux 包同版本）
-m, --mirror URL     Go 下载镜像（如 https://golang.google.cn/dl）
--skip-termux        不打 Termux 补丁
--skip-go            不下载 Go
--check              只做环境检查
```

### android-cross-build.sh

```
-n, --ndk DIR        NDK 路径（默认自动探测）
-o, --out DIR        输出目录
-t, --api NUM        Android API level（默认 24）
-a, --arch LIST      目标 ABI（默认全部 4 个）
-g, --goroot DIR     指定 GOROOT
-p, --package SPEC   要编译的包（默认 .）
--tags TAGS          build tags（Android 建议 no_ui）
--static-arm64       arm64 用 CGO_ENABLED=0 出纯静态产物
--check              只检查环境
```

---

## 已知限制

1. **Go 版本必须与 Termux 补丁同版本**
   Termux 1.27.1 的 `dnsclient_android.go` 用到 `internal/strconv`（Go 1.26+ 才有）。
   若用 Go 1.25 打包，会报 `package internal/strconv is not in std`。

2. **只有 `android/arm64` 能纯静态编译**
   Go 工具链对 `android/arm`、`386`、`amd64` 硬编码要求 external linking
   （即 `CGO_ENABLED=1`），否则报 `cannot find runtime/cgo`。这是 Go 的设计，
   不是环境缺失。因此 4 架构统一走 `CGO_ENABLED=1` + NDK。

3. **NDK 版本由使用者自备**
   不同 NDK 版本的 sysroot 与 clang 内容不同，本项目不预设。NDK r26+ 均可。

---

## 许可

本仓库是第三方派生分支，代码分三层，版权与许可分别如下：

| 层 | 内容 | 版权 | 许可 |
|---|---|---|---|
| 1 | 上游 go2rtc 原有代码 | © 2022 Alexey Khit | MIT（[LICENSE](LICENSE)） |
| 2 | 移植的小米 QR 登录流程 | © 2020 Piotr Machowski | MIT |
| 3 | **本分支的 Android 嵌入改动** | © 2026 heworkalin | MIT |

三层许可条款完全相同（均为 MIT），可自由使用、修改、分发，
但**必须保留上述全部版权声明**。

完整说明见 [`LICENSE-ANDROID`](LICENSE-ANDROID)，其中包含：
- 本分支改动的逐文件清单
- QR 登录流程的移植映射关系（[Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)，MIT）
- 第三方组件（Go 标准库补丁、Termux 包、NDK）的许可

### 定位说明

我们**不是小米官方团队，也不是 go2rtc 上游维护者**，
只是第三方 fork 的维护者，目标是让这个分支在自己的场景下更好用。

---

## 依赖组件的上游声明

本分支的构建流程会下载两个外部组件，它们各自的声明如下。

### 1. Termux golang 包（仅用于提取 10 个补丁文件）

来自 `termux-packages/packages/golang/build.sh` 与 apt 元数据的原始声明：

| 字段 | 值 |
|---|---|
| `TERMUX_PKG_LICENSE` | **BSD 3-Clause** |
| `TERMUX_PKG_HOMEPAGE` | `https://go.dev/` |
| `TERMUX_PKG_SRCURL` | `https://go.dev/dl/go1.27.1.src.tar.gz`（官方源码，未改造） |
| `TERMUX_PKG_DEPENDS` | **`clang`** |
| `TERMUX_PKG_ANTI_BUILD_DEPENDS` | `clang` |
| `TERMUX_PKG_RECOMMENDS` | **`resolv-conf`** |
| `TERMUX_PKG_MAINTAINER` | `@termux` |
| apt `Depends` / `Recommends` | `clang` / `resolv-conf` |

**这些声明对本方案的实际影响：**

| 上游要求 | 我们是否需要 | 说明 |
|---|---|---|
| `Depends: clang` | ❌ 不需要 | 这是 Termux 运行时的依赖。我们不执行 Termux 的 `go` 二进制，而是用官方 Go + NDK clang |
| `Recommends: resolv-conf` | ⚠️ **相关** | 这正是 Termux 提供 `<PREFIX>/etc/resolv.conf` 的包。我们的补丁让二进制去读它，因此**宿主 App 需自行写入该文件**，或改用 `-dns` 参数 |
| `License: BSD 3-Clause` | ⚠️ **需遵守** | 见下 |

**关于补丁脚本的许可**：`termux-packages/LICENSE.md` 明确写明
"The scripts and patches to build each package is licensed under the same license
as the actual package"，因此 golang 包的补丁脚本**同样是 BSD 3-Clause**，
并非 GPL（GPL-3.0 仅适用于 `root-packages/`、`disabled-packages/`，本方案不涉及）。

我们**没有复制**这些脚本，而是照着其行为自行实现了等效逻辑。

**关于提取出的源码文件**：`patch-src/` 里的 10 个文件均保留原始版权头：

```go
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
```

若要把它们提交进仓库再分发，需一并保留这些头部。

### 2. 官方 Go 工具链

从 `go.dev/dl/` 下载，同样为 **BSD 3-Clause**，版权归 The Go Authors。
本方案只使用官方包，不做任何修改（除应用上述补丁）。

### 3. Android NDK

由使用者自行安装，受其自带许可约束（`$NDK/NOTICE`），本仓库不再分发。

---

## 致谢

本项目基于 **[AlexxIT/go2rtc](https://github.com/AlexxIT/go2rtc)** 开发（MIT，© 2022 Alexey Khit）。

小米 QR 扫码登录流程**移植自** **[Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)**
（MIT，© 2020 Piotr Machowski），对应其 `QrCodeXiaomiCloudConnector`
（`token_extractor.py` 第 605–755 行）。
移植映射与差异记录见 [`docs/migration/qr-login-migration-guide.md`](docs/migration/qr-login-migration-guide.md)。

- 上游仓库：<https://github.com/AlexxIT/go2rtc>
- 上游 README（英文）：[`docs/upstream/README.upstream.md`](docs/upstream/README.upstream.md)
- 上游分支：`upstream/master`

许可详情见 [LICENSE](LICENSE) 与 [LICENSE-ANDROID](LICENSE-ANDROID)。
