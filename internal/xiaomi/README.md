# Xiaomi Mi Home

[`new in v1.9.13`](https://github.com/AlexxIT/go2rtc/releases/tag/v1.9.13)

This source allows you to view cameras from the [Xiaomi Mi Home](https://home.mi.com/) ecosystem.

Since 2020, Xiaomi has introduced a unified protocol for cameras called `miss`. I think it means **Mi Secure Streaming**. Until this point, the camera protocols were in chaos. Almost every model had different authorization, encryption, command lists, and media packet formats.

go2rtc supports two formats: `xiaomi/mess` and `xiaomi/legacy`.
And multiple P2P protocols: `cs2+udp`, `cs2+tcp`, several versions of `tutk+udp`.

Almost all cameras in the `xiaomi/mess` format and the `cs2` protocol work well.
Older `xiaomi/legacy` format cameras may have support issues.
The `tutk` protocol is the worst thing that's ever happened to the P2P world. It works terribly.

**Important:**

1. **Not all cameras are supported**. The list of supported cameras is collected in [this issue](https://github.com/AlexxIT/go2rtc/issues/1982).
2. Each time you connect to the camera, you need Internet access to obtain encryption keys.
3. Connection to the camera is local only.

**Features:**

- Multiple Xiaomi accounts supported
- Cameras from multiple regions are supported for a single account
- Two-way audio is supported
- Cameras with multiple lenses are supported

## Setup

1. Go to go2rtc WebUI > Add > Xiaomi > Login with username and password
2. Receive verification code by email or phone if required.
3. Complete the captcha if required.
4. If everything is OK, your account will be added, and you can load cameras from it.

**Example**

```yaml
xiaomi:
  1234567890: V1:***

streams:
  xiaomi1: xiaomi://1234567890:cn@192.168.1.123?did=9876543210&model=isa.camera.hlc7
```

## Configuration

Quality in the `miss` protocol is specified by a number from 0 to 5. Usually 0 means auto, 1 - sd, 2 - hd.
Go2rtc by default sets quality to 2. But some new cameras have HD quality at number 3.
Old cameras may have broken codec settings at number 3, so this number should not be set for all cameras.

You can change camera quality: `subtype=hd/sd/auto/0-5`.

```yaml
streams:
  xiaomi1: xiaomi://***&subtype=sd
```

You can use a second channel for dual cameras: `channel=2`.

```yaml
streams:
  xiaomi1: xiaomi://***&channel=2
```

### Dual-lens cameras

Some models have **two lenses** (two physical cameras facing different
directions) that are streamed over a single P2P connection. Stock go2rtc
used to request and decode only the first lens.

To get **both lenses as two independent streams**, start the stream with
`channel=dual` and select the lens with the new `lens=1|2` parameter:

```yaml
streams:
  cam_lens1: xiaomi://<uid>@<ip>?did=<did>&model=<model>&channel=dual&lens=1
  cam_lens2: xiaomi://<uid>@<ip>?did=<did>&model=<model>&channel=dual&lens=2
```

- `channel=dual` sends `{"videoquality":q,"videoquality2":q,"enableaudio":a}`
  so the camera starts streaming both lenses.
- `lens=1` / `lens=2` filters the interleaved video packets to a single lens
  (the camera multiplexes both lenses on one channel and tags the packets in
  the high 16 bits of the frame flags).
- Omitting `lens` keeps the old behaviour (all frames, may look garbled when
  both lenses are on). Omitting `channel=dual` keeps the classic single-lens
  stream unchanged.

**Verified model**

| Name | Notes |
|------|-------|
| 小米智能室外摄像机 4 双摄版 (Xiaomi Outdoor Camera 4 Dual / Dual-Cam Edition) | dual-lens, local device id `isa.camera.cw501d`, codename `MJSXJ10HL` (from public sources, not officially confirmed) |

The Chinese name is kept as seen in the Mi Home app; the English name and the
model code come from public sources and may not be exact.

## Shared homes (shared devices)

A Mi Home account can be a member of a **shared home** owned by someone else.
The shared cameras appear in a different API than the owned devices.

go2rtc can enumerate shared homes and their devices with the debug endpoint:

```
GET /api/xiaomi?shared=1&id=<userID>&region=
```

It returns the shared homes and their devices as `api.Source` entries that can
be added to go2rtc directly.

> ⚠️ **China mainland only.** This was only tested and verified against the
> China Mainland Mi Home ecosystem (`region` must be empty). Whether the
> international Mi Home ecosystem exposes an equivalent shared-home flow is
> unknown, so the endpoint currently **rejects any non-empty `region`**.
> If you successfully test another region, the check can be relaxed.

Implementation notes (endpoints used):

- `POST /v2/homeroom/gethome_merged` with
  `fetch_share=true&fetch_share_dev=true` — returns shared homes
  (`/homeroom/gethome` returns only owned homes).
- `POST /v2/home/home_device_list` with `home_owner` / `home_id` — returns the
  devices of a given home.
