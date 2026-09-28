package xiaomi

import (
	"encoding/json"
	"fmt"
	"strconv"
)

// This file implements pure client-side enumeration of shared homes and their devices.
//
// Static evidence (see docs/auth/shared-family-enumeration-go2rtc.md):
//
//	Homes list:   POST /v2/homeroom/gethome_merged
//	              requires fetch_share=true & fetch_share_dev=true, otherwise the
//	              server will NOT return shared homes.
//	              -> result.homelist[] (plus result.cariot_home_list[])
//	Home devices: POST /v2/home/home_device_list -> result.device_info[]
//	Home.isOwner() == (shareflag == 0); home_owner = Home.uid, home_id = int64(Home.id)
//
// Live-verified (2026-09-28, China Mainland region):
//
//	- /homeroom/gethome returns only owned homes (no shared homes).
//	- /v2/homeroom/gethome_merged without limit fails; with fetch_share it returns
//	  shared homes.
//	- Shared home permit_level=9 (manager); device permitLevel=68 (64|4 -> isHomeShared).
//
// NOTE (region limitation):
//
//	This code and its APIs have ONLY been tested and verified against the China
//	Mainland Mi Home ecosystem (region == ""). Whether the international (global)
//	Mi Home ecosystem exposes an equivalent shared-home flow is UNKNOWN.
//	Do not assume the same endpoints/parameters work for non-China regions.
//
// Scope: this file only enumerates. It does NOT trigger any devicepass/live auth.
// Whether the server accepts a shared token for streaming is a runtime unknown here.

// Home 对应 gethome_merged 返回的家庭条目（字段名对齐 App 的 Home.java）。
type Home struct {
	ID          string `json:"id"`           // 家庭 ID（String）
	Name        string `json:"name"`         // 家庭名称
	ShareFlag   int    `json:"shareflag"`    // 0 = 自有；!=0 = 共享
	OwnerUID    int64  `json:"uid"`          // 所有者 UID（long）
	PermitLevel int    `json:"permit_level"` // 家庭级权限（10=房主, 9=管理员, 2=成员, 1=只读）
	Status      int    `json:"status"`       // 状态
	RoomList    []Room `json:"roomlist"`     // 房间（含 did 列表）
	CarDID      string `json:"car_did"`      // 车家 did（可空）
}

// IsShared 对应 App 侧 Home.isOwner() 的反面。
func (h Home) IsShared() bool { return h.ShareFlag != 0 }

// Room 家庭房间（仅取枚举所需字段）。
type Room struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	ParentID string   `json:"parentid"`
	DIDs     []string `json:"dids"`
}

// SharedDevice corresponds to a device_info entry of home_device_list
// (only the fields needed for enumeration are kept).
//
// Observed shape (2026-09-28, redacted):
//
//	{"did":"<DID>","uid":<OWNER_UID>,"token":"<TOKEN>","name":"<NAME>",
//	 "model":"<VENDOR>.camera.<MODEL>","permitLevel":68,"isOnline":true,
//	 "localip":"<IP>","mac":"<MAC>",
//	 "owner":{"userid":<OWNER_UID>,"nickname":"<NAME>"},
//	 "extra":{"fw_version":"<FW>"}}
type SharedDevice struct {
	DID         string      `json:"did"`
	UID         int64       `json:"uid"`
	Token       string      `json:"token"`
	Name        string      `json:"name"`
	Model       string      `json:"model"`
	PermitLevel int         `json:"permitLevel"`
	IsOnline    bool        `json:"isOnline"`
	LocalIP     string      `json:"localip"`
	MAC         string      `json:"mac"`
	Owner       DeviceOwner `json:"owner"`
	Extra       DeviceExtra `json:"extra"`
}

// DeviceOwner 对应 device_info[].owner（注意是嵌套对象，不是平铺的 owner_name）。
type DeviceOwner struct {
	UserID   int64  `json:"userid"`
	Nickname string `json:"nickname"`
}

// DeviceExtra 对应 device_info[].extra。
type DeviceExtra struct {
	FwVersion string `json:"fw_version"`
}

// HasCamera 与 App 侧判定一致：model 含 .camera. / .cateye. / .feeder.。
func (d SharedDevice) HasCamera() bool {
	return contains(d.Model, ".camera.") ||
		contains(d.Model, ".cateye.") ||
		contains(d.Model, ".feeder.")
}

// IsHomeShared 复刻 App Device.isHomeShared()：
//
//	(permitLevel & PERMISSION_SHARE(4)) != 0 && (permitLevel & PERMISSION_AGGREGATE(64)) != 0
func (d SharedDevice) IsHomeShared() bool {
	return d.PermitLevel&4 != 0 && d.PermitLevel&64 != 0
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// SharedHomeResult 聚合一个共享家庭及其设备。
type SharedHomeResult struct {
	Home    Home           `json:"home"`
	Devices []SharedDevice `json:"devices"`
}

// gethomeMergedParams matches App HomeListApi.getHomeFromServer1 byte-for-byte.
//
// Source: _m_j/t5.java (real App-side construction). Live-verified 2026-09-28 for
// China Mainland region. The fetch_share / fetch_share_dev flags are the switches
// that make the server return shared homes / shared devices.
//
// NOTE: only verified for the China Mainland ecosystem.
const gethomeMergedParams = `{"fg":true,"fetch_share":true,"fetch_share_dev":true,"limit":300,"app_ver":12,"fetch_cariot":true,"plat_form":0}`

// GetHomes 拉取账号的完整家庭列表（含共享家庭）。
//
// baseURL 由调用方通过 GetBaseURL(region) 生成；仅支持中国大陆 region=""。
// 使用 /v2/homeroom/gethome_merged + fetch_share=true，否则拿不到共享家庭。
func (c *Cloud) GetHomes(baseURL string) ([]Home, error) {
	res, err := c.Request(baseURL, "/v2/homeroom/gethome_merged", gethomeMergedParams, nil)
	if err != nil {
		return nil, err
	}

	var v struct {
		HomeList     []Home `json:"homelist"`
		CariotHomes  []Home `json:"cariot_home_list"` // 车家，与 homelist 并列
	}
	if err = json.Unmarshal(res, &v); err != nil {
		return nil, fmt.Errorf("xiaomi: gethome_merged parse: %w", err)
	}
	return append(v.HomeList, v.CariotHomes...), nil
}

// GetHomeDevices 拉取指定家庭的设备列表（自动分页）。
//
// home_owner = home.OwnerUID，home_id = int64(home.ID)，
// 与 App 侧 ShareHomeDeviceRepo.startUpdate 的转换一致。
func (c *Cloud) GetHomeDevices(baseURL string, home Home) ([]SharedDevice, error) {
	homeID, err := strconv.ParseInt(home.ID, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("xiaomi: home id not numeric: %q", home.ID)
	}

	var devices []SharedDevice
	startDID := ""

	for {
		params := map[string]any{
			"home_owner":         home.OwnerUID,
			"home_id":            homeID,
			"limit":              200,
			"get_split_device":   true,
			"support_smart_home": true,
			"get_cariot_device":  true,
			"get_third_device":   true,
		}
		if startDID != "" {
			params["start_did"] = startDID
		}

		raw, err := json.Marshal(params)
		if err != nil {
			return nil, err
		}

		res, err := c.Request(baseURL, "/v2/home/home_device_list", string(raw), nil)
		if err != nil {
			return nil, err
		}

		var v struct {
			DeviceInfo []SharedDevice `json:"device_info"`
			HasMore    bool           `json:"has_more"`
			MaxDID     string         `json:"max_did"`
		}
		if err = json.Unmarshal(res, &v); err != nil {
			return nil, fmt.Errorf("xiaomi: home_device_list parse: %w", err)
		}

		devices = append(devices, v.DeviceInfo...)

		// 注意：实测服务端可能给出 max_did 但 has_more=false（用于分页游标），
		// 因此以 has_more 为准，避免死循环。
		if !v.HasMore || v.MaxDID == "" {
			break
		}
		startDID = v.MaxDID
	}

	return devices, nil
}

// ListSharedHomes 枚举所有【共享】家庭及其设备。
//
// 返回顺序与家庭列表一致，便于与自有账号结果做对照。
// 只包含 shareflag != 0 的家庭；调用方可对 Devices 再按 HasCamera() 过滤摄像头。
func (c *Cloud) ListSharedHomes(baseURL string) ([]SharedHomeResult, error) {
	homes, err := c.GetHomes(baseURL)
	if err != nil {
		return nil, err
	}

	out := make([]SharedHomeResult, 0)
	for _, home := range homes {
		if !home.IsShared() {
			continue
		}
		devices, err := c.GetHomeDevices(baseURL, home)
		if err != nil {
			return nil, fmt.Errorf("xiaomi: shared home %s (%s): %w", home.Name, home.ID, err)
		}
		out = append(out, SharedHomeResult{Home: home, Devices: devices})
	}
	return out, nil
}
