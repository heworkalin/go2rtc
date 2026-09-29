# 迁移指南：引入 QR Code 扫码登录

> **日期**：2026-09-29
> **作者**：[heworkalin](https://github.com/heworkalin)
> **来源参考**：[Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) Python 项目
> **定位**：我们不是小米官方团队，也不是 go2rtc 上游维护者，只是一个第三方 fork/分支的维护者
> **目标**：让自己的分支更好用一点点，用户扫码登录更简单，不是要合进上游官方项目

---

## 一、背景

### 1.1 现状

go2rtc 目前仅支持以下认证方式：

| 方式 | API | 说明 |
|------|-----|------|
| Token 登录 | `LoginWithToken()` | 预置 userID + passToken，适合已有凭据 |
| 密码登录 | `Login()` → `LoginWithCaptcha()` → `LoginWithVerify()` | 三步密码认证，支持图形验证码和手机/邮箱 2FA |

### 1.2 缺口

**缺少 QR Code 扫码登录**，这是米家 APP 用户最常用的登录方式。
Python 项目已验证该流程可用，需要迁移到 go2rtc。

### 1.3 为什么参考 Python 项目而非自己实现

> 我们只是第三方分支维护者，不想从头造轮子，就想让用户用起来简单一点

- Python 项目的 QR 登录流程已在多区域验证过
- 处理了 `&&&START&&&` 前缀、重定向链、cookie 传递等细节
- 直接搬运比重写好，少踩坑

---

## 二、QR Code 登录机制详解

> **本章所有细节均对照 Python 源码 `token_extractor.py` 的
> `QrCodeXiaomiCloudConnector`（L605–755）逐行核实。**
> 上一版本文档中的若干描述与实际代码不符，已在修复版中更正，并在
> §十一 列出勘误表。

### 2.1 完整流程图

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Phase 1: 获取登录 URL / 二维码 / 轮询 URL（login_step_1）                │
│                                                                         │
│  1. GET https://account.xiaomi.com/longPolling/loginUrl                 │
│     → 返回 loginUrl（手机端可打开的链接，用于手动兜底）                    │
│     → 返回 qr（二维码图片 URL）                                          │
│     → 返回 lp（longPolling URL，用于等待扫码）                            │
│     → 返回 timeout（轮询总时长上限，秒）                                  │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│  Phase 2: 展示二维码（login_step_2）                                     │
│                                                                         │
│  2. GET qr（获取二维码图片字节，展示给用户；不假设图片格式）               │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│  Phase 3: 长轮询等待扫码（login_step_3）                                  │
│                                                                         │
│  3. GET lp（原样使用 step1 返回的 URL，不追加任何参数）                    │
│     → 循环轮询直到 200 或累计耗时超过 timeout                             │
│     → 200 时返回 userId, ssecurity, passToken, location, cUserId         │
│     → 超时则失败（不自动重新获取二维码）                                   │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│  Phase 4: 完成认证，获取 serviceToken（login_step_4）                     │
│                                                                         │
│  4. GET location（小米账号的终点重定向，自动跟随重定向链）                 │
│     → 从 cookie 提取 serviceToken                                       │
│     → 同时可提取 userId, cUserId, passToken                             │
│     → 从 Extension-Pragma 头提取 ssecurity（QR/密码路径通用）             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 每个步骤的 HTTP 细节

#### Step 1: 获取登录 URL、二维码 URL 和轮询 URL（`login_step_1`）

```http
GET https://account.xiaomi.com/longPolling/loginUrl
    ?_qrsize=480
    &qs=%3Fsid%3Dxiaomiio%26_json%3Dtrue
    &callback=https%3A%2F%2Fsts.api.io.mi.com%2Fsts
    &_hasLogo=false
    &sid=xiaomiio
    &serviceParam=
    &_locale=en_GB
    &_dc=1696000000000

Response (JSON with &&&START&&& prefix):
&&&START&&&
{
    "loginUrl": "https://account.xiaomi.com/fe/service/oauth2/authLink",
    "qr": "https://account.xiaomi.com/fe/service/oauth2/qrcodeGenerate?sid=xiaomiio...",
    "lp": "https://account.xiaomi.com/longPolling/...",
    "timeout": 300
}
```

> 参数名是 `serviceParam`（无前导下划线），`_qrsize` / `_hasLogo` / `_locale` / `_dc` 有下划线。

#### Step 2: 获取二维码图片（`login_step_2`）

```http
GET <login_step_1 返回的 qr URL>

Response: 二维码图片字节流
```

> Python 仅检查 HTTP 200 并直接把 `response.content` 交给展示层，**不假设 Content-Type**。
> Go 侧同样只取字节，由前端以合适的方式渲染。

#### Step 3: 长轮询等待扫码（`login_step_3`）

```http
GET <login_step_1 返回的 lp URL>   (原样使用，不追加参数)

Response (JSON with &&&START&&& prefix):
&&&START&&&
{
    "userId": "123456789",
    "ssecurity": "base64Encoded...",
    "passToken": "base64Encoded...",
    "location": "https://account.xiaomi.com/.../end",
    "cUserId": "987654321"
}
```

**轮询语义（严格对齐 Python L694–715）**：

1. 记录 `start_time`
2. 循环：`GET lp`，单次请求 `timeout=10s`
3. 单次请求超时（`requests.Timeout`）→ 不退出，重试
4. 若 `now - start_time > timeout` → 退出并判失败（**不自动重取二维码**）
5. 其他网络异常 → 退出并判失败
6. 非 200 → 记录错误并重试

#### Step 4: 获取 serviceToken（`login_step_4`）

```http
GET <step3 返回的 location>   (自动跟随重定向)
    Header: content-type: application/x-www-form-urlencoded

Response:
Set-Cookie: serviceToken=xxx; ...
Set-Cookie: userId=123456789; ...
Set-Cookie: cUserId=987654321; ...
```

> Go 侧无需自己写：`finishAuth(location)` 已经实现了 cookie（`userId` /
> `cUserId` / `serviceToken` / `passToken`）以及 `Extension-Pragma` 头中的
> `ssecurity` 提取，并组装后续 API 调用所需的 `c.cookies` 字符串。

### 2.3 关键协议要点

| 要点 | 说明 |
|------|------|
| `&&&START&&&` 前缀 | 登录相关响应基本都带，必须剥离（Password 与 QR 路径共用） |
| `sid=xiaomiio` | 固定值，表示小米家庭应用 |
| `callback` 参数 | 重定向终点，必须是 `https://sts.api.io.mi.com/sts` |
| longPolling | 客户端轮询，非服务器推送 |
| `timeout` | 轮询**总时长上限**（秒），超时判失败，不会自动重取二维码 |
| 单次轮询超时 | Python 用 10s/次，超时后重试，累计受 `timeout` 约束 |
| 2FA / 图形验证码 | **QR 流程 Go 侧无需处理**：身份验证在已登录的米家 APP 内完成，服务端轮询直接返回结果 |
| 二维码图片格式 | 不做假设，按字节透传给前端 |

---

## 三、与现有认证流程的对比

| 对比项 | 现有密码登录 | QR Code 扫码登录 |
|--------|-------------|-----------------|
| 登录步骤 | 3 步（serviceLogin → Auth2 → finish） | 4 步（loginUrl → qr → poll → finish） |
| 用户交互 | 输入用户名密码 | 打开米家 APP 扫码 |
| 2FA 支持 | 内置（手机/邮箱验证码），Go 侧需处理 | 由米家 APP 侧完成，Go 侧**不处理** |
| 图形验证码 | 支持（Go 侧需处理） | 不适用 |
| 适用场景 | 自动化、后台服务 | 用户手动登录、首次配置 |

---

## 四、迁移方案设计

### 4.1 架构设计

```
internal/xiaomi/
└── xiaomi.go         # apiXiaomi 扩展 POST 分支（action 路由）

pkg/xiaomi/
├── cloud.go          # 现有：Cloud + Login/Verify/Captcha/Token + finishAuth()
├── cloud_qr.go       # 新增：QR Code 扫码登录 4 步
└── shared_home.go    # 现有：共享家庭枚举
```

> 不改动 `cloud.go`，新增独立文件 `cloud_qr.go`，并复用 `finishAuth()` 与
> `readLoginResponse()`。

### 4.2 新增方法（最终实现，严格对齐 Python 4 步）

```go
// QRLogin 对应 Python login_step_1 的返回状态。
type QRLogin struct {
    QRImageURL string // 二维码图片 URL
    LoginURL   string // 手机端可打开的登录链接（手动兜底）
    PollURL    string // 长轮询 URL
    Timeout    int64  // 轮询总时长上限（秒）
}

// LoginQR 对应 Python login_step_1：获取 QR / 轮询 URL。
func (c *Cloud) LoginQR() (*QRLogin, error)

// QRImage 对应 Python login_step_2：获取二维码图片字节（不假设格式）。
func (c *Cloud) QRImage(qr *QRLogin) ([]byte, error)

// QRWait 对应 Python login_step_3：阻塞长轮询，直到扫码成功或超时。
// 成功时写入 userID / ssecurity / passToken，但尚未获取 serviceToken。
func (c *Cloud) QRWait(qr *QRLogin) error

// QRFinish 对应 Python login_step_4：走 finishAuth 获取 serviceToken，
// 并组装 c.cookies。
func (c *Cloud) QRFinish(location string) error
```

> **与上一版文档的差异**：不再虚构 `QRCheck()`「未完成时返回新轮询 URL」的语义。
> Python 是**阻塞式轮询**；Go 侧保持同样的阻塞语义，由前端负责"开始/等待/显示结果"。

### 4.3 API 端点设计（复用现有路由）

go2rtc 的 `apiXiaomi` 已把 `POST /api/xiaomi` 分给 `apiAuth`。为避免新增路由，
QR 流程复用同一 POST 端点，用 `action` 字段区分：

```
POST /api/xiaomi  action=qr_start  → 生成二维码，返回 {qr_image, login_url}
POST /api/xiaomi  action=qr_wait   → 阻塞等待扫码；成功则保存 token 并返回空
```

状态用包级单例保存（与现有 `var auth *xiaomi.Cloud` 的写法一致）。

### 4.4 Web UI 交互流程

```
1. 用户点击 "Xiaomi" 展开面板
2. 点击 "scan QR" 按钮 → POST /api/xiaomi (action=qr_start)
3. 后端返回 qr_image（base64 data URL）与 login_url
4. 前端 <img> 展示二维码
5. 前端 POST /api/xiaomi (action=qr_wait)（浏览器侧等待结果）
6. 用户用米家 APP 扫码
7. 后端保存 userID/passToken 到 tokens 并 PatchConfig，返回成功
8. 前端 alert OK 并刷新账号下拉框
```

---

## 五、Python 项目对照实现

### 5.1 QrCodeXiaomiCloudConnector 方法映射（已核对源码）

| Python 方法 | Go 对应方法 | 功能 |
|-------------|-------------|------|
| `__init__()` | `NewCloud()` | 初始化会话 |
| `login()` | 由 API 层 `action` 编排 | 串联 4 步 |
| `login_step_1()` | `LoginQR()` | 获取 loginUrl、qr URL、lp URL、timeout |
| `login_step_2()` | `QRImage()` | 获取二维码图片字节 |
| `login_step_3()` | `QRWait()` | 阻塞长轮询等待扫码 |
| `login_step_4()` | `QRFinish()` | GET location，取 serviceToken |

### 5.2 关键差异处理

| 差异 | Python 实现 | Go 迁移处理 |
|------|-------------|-------------|
| `&&&START&&&` 剥离 | `to_json()` 用 `str.replace` | 复用现有 `readLoginResponse()` |
| 随机 agent | 拼接 `random_text-agent_id` | 复用现有 `genNonce()` 中的随机生成思路 |
| device_id | 6 位随机字母 | 复用现有 `core.RandString()`（密码路径 L72 已用） |
| cookie domain | `requests` session 自动处理 | **Go client 无 CookieJar**，依赖 `finishAuth()` 手动提取 |
| 轮询超时 | 10s/次，累计 `timeout` | 用 `http.Client` 超时 + 循环计时 |
| 2FA | 不处理 | 不处理（见 §2.3） |

---

## 六、区域支持

| 区域 | Python 项目 | go2rtc 现有 | QR 登录预期 |
|------|-------------|-------------|-------------|
| cn (中国大陆) | ✅ 验证通过 | ✅ 验证通过 | ✅ 应可用 |
| de (德国) | ✅ 验证通过 | ✅ 验证通过 | ✅ 应可用 |
| us (美国) | ✅ 支持 | ✅ 支持 | ✅ 应可用 |
| ru (俄罗斯) | ✅ 支持 | ✅ 支持 | ✅ 应可用 |
| tw (台湾) | ✅ 支持 | ✅ 支持 | ✅ 应可用 |
| sg (新加坡) | ✅ 支持 | ✅ 支持 | ✅ 应可用 |
| in (印度) | ✅ 支持 | ✅ 支持 | ✅ 应可用 |
| i2 (国际) | ✅ 支持 | ✅ 支持 | ✅ 应可用 |

> **注意**：QR Code 登录的端点是 `account.xiaomi.com`，这是全局域名，不区分区域。
> 区域差异仅在后续 API 调用时体现（`api.io.mi.com` vs `{region}.api.io.mi.com`）。
> 扫码得到的 `userID/passToken` 与区域无关，可配合任意 region 使用。

---

## 七、验证清单

### 7.1 功能验证

- [ ] QR 二维码生成成功，米家 APP 可正常扫码
- [ ] 扫码后轮询正常返回 userId / passToken / ssecurity
- [ ] serviceToken 获取正确（经 `finishAuth`）
- [ ] userID 和 passToken 正确写入 `tokens` 并 PatchConfig
- [ ] 扫码超时后报错（**不**自动重取二维码，需用户重新点击）
- [ ] 手动兜底链接（loginUrl）可用

### 7.2 场景验证

- [ ] 首次登录（无预置 token）
- [ ] Token 过期后重新扫码登录
- [ ] 多账号切换（不同 userID）

> **移除项**：「扫码后触发 2FA（手机/邮箱验证码）」——QR 流程 Go 侧无 2FA
> 处理逻辑，扫码时的身份验证由米家 APP 完成。

### 7.3 兼容性验证

- [ ] 与现有密码登录互不冲突
- [ ] 与现有 Token 登录互不冲突
- [ ] QR 登录结果可存入 `tokens map[string]string`
- [ ] QR 登录后的 API 调用正常（设备列表、视频流、共享家庭）

---

## 八、风险评估

### 8.1 已知风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| QR 登录被风控 | 中 | 扫码后提示"设备异常" | 使用米家 APP 同款 agent 字符串 |
| 轮询超时 | 中 | 用户需重新扫码 | 前端提示重新点击；不做自动重取 |
| cookie 丢失 | 中 | serviceToken 未获取 | 复用 `finishAuth()` 的多层 cookie 提取 |

### 8.2 与 Python 项目的差异风险

| 差异点 | 风险 | 验证方法 |
|--------|------|----------|
| Go `http.Client` 自动重定向 | 中 | `finishAuth()` 已按 `res.Request.Response` 遍历重定向链，QR 复用即可 |
| Go **无 CookieJar** | **中—高** | 所有跨请求 cookie 依赖 `finishAuth()` 手动提取；QR 流程不能依赖自动 cookie |
| `&&&START&&&` 处理 | 低 | 复用现有 `readLoginResponse()` |
| 阻塞轮询占用 HTTP 连接 | 中 | 前端需容忍长时间请求；必要时前端拆分多次 `qr_wait` 短轮询 |

---

## 九、实施计划

### Phase 1: 核心方法（P0）
- [x] `LoginQR()` — 获取 QR / 登录 / 轮询 URL
- [x] `QRImage()` — 获取二维码图片字节
- [x] `QRWait()` — 阻塞长轮询（10s/次，累计 timeout）
- [x] `QRFinish()` — 复用 `finishAuth()` 获取 serviceToken

### Phase 2: API 端点（P0）
- [x] `POST /api/xiaomi` + `action=qr_start`
- [x] `POST /api/xiaomi` + `action=qr_wait`
- [x] 状态管理（包级 `qrLogin` 单例）

### Phase 3: Web UI（P1）
- [x] 添加 "scan QR" 按钮
- [x] 展示二维码
- [x] 等待结果并提示成功/失败

### Phase 4: 测试验证（P1）
- [ ] 中国大陆区域验证
- [ ] 其他区域验证（至少 de/us）
- [ ] 超时和重试验证

> **移除项**：Phase 4 的「2FA 场景验证」（QR 流程 Go 侧不处理 2FA）。

---

## 十、参考链接

- [Xiaomi-cloud-tokens-extractor - QrCodeXiaomiCloudConnector](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor/blob/master/token_extractor.py#L605)
- [go2rtc - cloud.go (现有登录逻辑)](https://github.com/AlexxIT/go2rtc/blob/master/pkg/xiaomi/cloud.go)
- [go2rtc - xiaomi.go (API 端点)](https://github.com/AlexxIT/go2rtc/blob/master/internal/xiaomi/xiaomi.go)

---

## 十一、勘误表（对照 Python 源码）

上一版本文档的以下描述与 `token_extractor.py` 实际代码不符，本版已更正：

| # | 上一版说法 | 实际情况（源码位置） |
|---|-----------|---------------------|
| 1 | `Step 1` 参数 `_serviceParam=` | 实际是 `serviceParam`（无下划线），`token_extractor.py` L646 |
| 2 | `Step 1` 参数 `_qrsize`、`_locale`、`_dc` 未提 | 确有下划线，L641–L648 |
| 3 | `Step 3` URL 带 `loginType=1&callback=` | 实际原样使用 `lp`，**不追加任何参数**，L694 |
| 4 | 「超时后需重新获取二维码」 | 实际超时即失败退出，**不自动重取**，L700–L706 |
| 5 | 「2FA 支持：内置（扫码后自动触发 2FA）」 | QR 连接器无任何 2FA/captcha 逻辑，L605–L755 |
| 6 | 「QR 有效期约 5 分钟（与 timeout 一致）」 | `timeout` 仅为轮询总时长上限，与二维码有效期无代码关联 |
| 7 | `QRLoginState.Token`「轮询用的 token」 | 不存在该字段，L607–L613 |
| 8 | 方法映射 `login_step_2 → getQRImage`、`login_step_3 → QRCheck` | 实际为 `login_step_1/2/3/4` 四步，无 `getQRImage`/`QRCheck` |
| 9 | `QRCheck` 未完成时「返回新的轮询 URL」 | 实际是阻塞循环，不返回新 URL，L696–L715 |
| 10 | Step 2 响应为 JPEG | Python 不假设格式，仅取 `response.content`，L663–L688 |

---

**作者**：[heworkalin](https://github.com/heworkalin)（第三方 fork 维护者，仅用于自有分支，非上游官方 PR）
**最后更新**：2026-09-29
