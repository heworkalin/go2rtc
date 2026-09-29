package xiaomi

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/AlexxIT/go2rtc/internal/api"
	"github.com/AlexxIT/go2rtc/internal/app"
	"github.com/AlexxIT/go2rtc/internal/streams"
	"github.com/AlexxIT/go2rtc/pkg/core"
	"github.com/AlexxIT/go2rtc/pkg/xiaomi"
	"github.com/AlexxIT/go2rtc/pkg/xiaomi/crypto"
	"github.com/rs/zerolog"
)

func Init() {
	var v struct {
		Cfg map[string]string `yaml:"xiaomi"`
	}
	app.LoadConfig(&v)

	tokens = v.Cfg

	log = app.GetLogger("xiaomi")

	streams.HandleFunc("xiaomi", func(rawURL string) (core.Producer, error) {
		u, err := url.Parse(rawURL)
		if err != nil {
			return nil, err
		}

		if u.User != nil {
			rawURL, err = getCameraURL(u)
			if err != nil {
				return nil, err
			}
		}

		log.Debug().Msgf("xiaomi: dial %s", rawURL)

		return xiaomi.Dial(rawURL)
	})

	api.HandleFunc("api/xiaomi", apiXiaomi)
}

var log zerolog.Logger

var tokens map[string]string
var clouds map[string]*xiaomi.Cloud
var cloudsMu sync.Mutex

func getCloud(userID string) (*xiaomi.Cloud, error) {
	cloudsMu.Lock()
	defer cloudsMu.Unlock()

	if cloud := clouds[userID]; cloud != nil {
		return cloud, nil
	}

	cloud := xiaomi.NewCloud(AppXiaomiHome)
	if err := cloud.LoginWithToken(userID, tokens[userID]); err != nil {
		return nil, err
	}
	if clouds == nil {
		clouds = map[string]*xiaomi.Cloud{userID: cloud}
	} else {
		clouds[userID] = cloud
	}
	return cloud, nil
}

func cloudRequest(userID, region, apiURL, params string) ([]byte, error) {
	cloud, err := getCloud(userID)
	if err != nil {
		return nil, err
	}
	return cloud.Request(GetBaseURL(region), apiURL, params, nil)
}

func cloudUserRequest(user *url.Userinfo, apiURL, params string) ([]byte, error) {
	userID := user.Username()
	region, _ := user.Password()
	return cloudRequest(userID, region, apiURL, params)
}

func getCameraURL(url *url.URL) (string, error) {
	model := url.Query().Get("model")

	// It is not known which models need to be awakened.
	// Probably all the doorbells and all the battery cameras.
	if strings.Contains(model, ".cateye.") {
		_ = wakeUpCamera(url)
	}

	// The getMissURL request has a fallback to getP2PURL.
	// But for known models we can save one request to the cloud.
	if xiaomi.IsLegacy(model) {
		return getLegacyURL(url)
	}
	return getMissURL(url)
}

func getLegacyURL(url *url.URL) (string, error) {
	query := url.Query()

	clientPublic, clientPrivate, err := crypto.GenerateKey()
	if err != nil {
		return "", err
	}

	params := fmt.Sprintf(`{"did":"%s","toSignAppData":"%x"}`, query.Get("did"), clientPublic)

	userID := url.User.Username()
	region, _ := url.User.Password()
	res, err := cloudRequest(userID, region, "/device/devicepass", params)
	if err != nil {
		return "", err
	}

	var v struct {
		UID       string `json:"p2p_id"`
		Password  string `json:"password"`
		PublicKey string `json:"p2p_dev_public_key"`
		Sign      string `json:"signForAppData"`
	}
	if err = json.Unmarshal(res, &v); err != nil {
		return "", err
	}

	query.Set("uid", v.UID)

	if v.Sign != "" {
		query.Set("client_public", hex.EncodeToString(clientPublic))
		query.Set("client_private", hex.EncodeToString(clientPrivate))
		query.Set("device_public", v.PublicKey)
		query.Set("sign", v.Sign)
	} else {
		query.Set("password", v.Password)
	}

	url.RawQuery = query.Encode()
	return url.String(), nil
}

func getMissURL(url *url.URL) (string, error) {
	clientPublic, clientPrivate, err := crypto.GenerateKey()
	if err != nil {
		return "", err
	}

	query := url.Query()
	params := fmt.Sprintf(
		`{"app_pubkey":"%x","did":"%s","support_vendors":"TUTK_CS2_MTP"}`,
		clientPublic, query.Get("did"),
	)

	res, err := cloudUserRequest(url.User, "/v2/device/miss_get_vendor", params)
	if err != nil {
		if strings.Contains(err.Error(), "no available vendor support") {
			return getLegacyURL(url)
		}
		return "", err
	}

	var v struct {
		Vendor struct {
			ID     byte `json:"vendor"`
			Params struct {
				UID string `json:"p2p_id"`
			} `json:"vendor_params"`
		} `json:"vendor"`
		PublicKey string `json:"public_key"`
		Sign      string `json:"sign"`
	}
	if err = json.Unmarshal(res, &v); err != nil {
		return "", err
	}

	query.Set("client_public", hex.EncodeToString(clientPublic))
	query.Set("client_private", hex.EncodeToString(clientPrivate))
	query.Set("device_public", v.PublicKey)
	query.Set("sign", v.Sign)
	query.Set("vendor", getVendorName(v.Vendor.ID))

	if v.Vendor.ID == 1 {
		query.Set("uid", v.Vendor.Params.UID)
	}

	url.RawQuery = query.Encode()
	return url.String(), nil
}

func getVendorName(i byte) string {
	switch i {
	case 1:
		return "tutk"
	case 3:
		return "agora"
	case 4:
		return "cs2"
	case 6:
		return "mtp"
	}
	return fmt.Sprintf("%d", i)
}

func wakeUpCamera(url *url.URL) error {
	const params = `{"id":1,"method":"wakeup","params":{"video":"1"}}`
	did := url.Query().Get("did")
	_, err := cloudUserRequest(url.User, "/home/rpc/"+did, params)
	return err
}

func apiXiaomi(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		if r.URL.Query().Get("shared") != "" {
			apiSharedHomes(w, r)
			return
		}
		apiDeviceList(w, r)
	case "POST":
		switch r.URL.Query().Get("action") {
		case "qr_start":
			apiQRStart(w, r)
		case "qr_wait":
			apiQRWait(w, r)
		default:
			apiAuth(w, r)
		}
	}
}

// apiSharedHomes enumerates shared homes and their devices (read-only).
//
// It returns api.Source entries that can be added to go2rtc directly.
//
// NOTE (risk):
//
//	This uses fetch_share / fetch_share_dev, which the Mi Home app sends in its
//	internal calls. A third-party client (go2rtc) sending them is imitating the
//	app: we hold a cloud account authorization (sid=xiaomiio) but not the app's
//	full identity, so it may be flagged by risk control. Use it only for your
//	own account, read-only and at low frequency; stop if any account warning
//	appears.
//
// NOTE (region):
//
//	Only the China Mainland Mi Home ecosystem has been tested and verified so
//	far (region == ""). The shared-home API surface
//	(/v2/homeroom/gethome_merged with fetch_share, and
//	/v2/home/home_device_list) has not been tested against the international
//	(global) Mi Home ecosystem.
//
//	As a conservative default, non-empty regions are rejected so that we do not
//	send unverified requests. This is a safety default, not a hard limitation:
//	relax it once another region is confirmed to work.
//
// Usage: GET /api/xiaomi?shared=1&id=<userID>&region=
func apiSharedHomes(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()

	user := query.Get("id")
	if user == "" {
		http.Error(w, "xiaomi: id required", http.StatusBadRequest)
		return
	}

	region := query.Get("region")
	if region != "" {
		// Conservative default: shared homes are only verified for China mainland.
		http.Error(w, "xiaomi: shared homes are only verified for China mainland; non-empty region is disabled by default", http.StatusBadRequest)
		return
	}

	cloud, err := getCloud(user)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	homes, err := cloud.ListSharedHomes(GetBaseURL(region))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var items []*api.Source
	for _, h := range homes {
		for _, d := range h.Devices {
			// Shared devices may only be reachable through the Miss/cs2 path.
			// Build the same URL shape used by the regular Xiaomi flow so it
			// can be resolved later by getCameraURL().
			u := &url.URL{
				Scheme: "xiaomi",
				Host:   d.LocalIP,
				User:   url.UserPassword(user, region),
			}
			q := url.Values{}
			q.Set("did", d.DID)
			q.Set("model", d.Model)
			u.RawQuery = q.Encode()

			items = append(items, &api.Source{
				Name: d.Name,
				Info: fmt.Sprintf("shared home: %s, model: %s, permit: %d", h.Home.Name, d.Model, d.PermitLevel),
				URL:  u.String(),
			})
		}
	}

	api.ResponseSources(w, items)
}

func apiDeviceList(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()

	user := query.Get("id")
	if user == "" {
		cloudsMu.Lock()
		users := make([]string, 0, len(tokens))
		for s := range tokens {
			users = append(users, s)
		}
		cloudsMu.Unlock()

		api.ResponseJSON(w, users)
		return
	}

	err := func() error {
		region := query.Get("region")
		res, err := cloudRequest(user, region, "/v2/home/device_list_page", "{}")
		if err != nil {
			return err
		}
		var v struct {
			List []*Device `json:"list"`
		}

		log.Trace().Str("user", user).Msgf("[xiaomi] devices list: %s", res)

		if err = json.Unmarshal(res, &v); err != nil {
			return err
		}

		var items []*api.Source

		for _, device := range v.List {
			if !device.HasCamera() {
				continue
			}
			items = append(items, &api.Source{
				Name: device.Name,
				Info: fmt.Sprintf("ip: %s, mac: %s", device.IP, device.MAC),
				URL:  fmt.Sprintf("xiaomi://%s:%s@%s?did=%s&model=%s", user, region, device.IP, device.Did, device.Model),
			})
		}

		api.ResponseSources(w, items)
		return nil
	}()

	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

type Device struct {
	Did   string `json:"did"`
	Name  string `json:"name"`
	Model string `json:"model"`
	MAC   string `json:"mac"`
	IP    string `json:"localip"`
}

func (d *Device) HasCamera() bool {
	return strings.Contains(d.Model, ".camera.") ||
		strings.Contains(d.Model, ".cateye.") ||
		strings.Contains(d.Model, ".feeder.")
}

var auth *xiaomi.Cloud

// qrLogin keeps the state of the in-flight QR login. It is a package-level
// singleton for the same reason `auth` is: the browser drives the handshake
// with two separate requests and go2rtc is a single-user local tool.
var qrLogin *xiaomi.QRLogin

// apiQRStart handles POST /api/xiaomi?action=qr_start.
//
// It performs QR login step 1 and returns the QR image. Two delivery modes:
//
//   - default: inline data URL {"qr_image":"data:..."}
//   - as_file=1: the PNG is written into <work-dir>/exchange/qr.png and only its
//     path is returned {"qr_image_path":"..."}. This is what the Android app
//     uses: pushing megabytes of base64 through a socket is wasteful when both
//     sides already share the work dir.
func apiQRStart(w http.ResponseWriter, r *http.Request) {
	auth = xiaomi.NewCloud(AppXiaomiHome)

	state, err := auth.LoginQR()
	if err != nil {
		auth = nil
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	image, err := auth.QRImage(state)
	if err != nil {
		auth = nil
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	qrLogin = state

	w.Header().Set("Content-Type", api.MimeJSON)

	if r.URL.Query().Get("as_file") != "" {
		path, err := writeExchangeFile("qr.png", image)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"qr_image_path": path,
			"qr_image_type": "png",
			"login_url":     state.LoginURL,
			"timeout":       state.Timeout,
		})
		return
	}

	_ = json.NewEncoder(w).Encode(map[string]string{
		"qr_image":  "data:image/png;base64," + base64.StdEncoding.EncodeToString(image),
		"login_url": state.LoginURL,
	})
}

// exchangeDirName is the sub directory of the work dir shared with the host app
// for image and payload exchange.
const exchangeDirName = "exchange"

// writeExchangeFile stores bytes under <work-dir>/exchange/name and returns the
// absolute path. It fails when no work dir is configured (non-Android build),
// which is fine: such builds use the inline response instead.
func writeExchangeFile(name string, data []byte) (string, error) {
	if app.WorkDir == "" {
		return "", errors.New("xiaomi: as_file requires a work dir")
	}

	dir := filepath.Join(app.WorkDir, exchangeDirName)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}

	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0600); err != nil {
		return "", err
	}
	return path, nil
}

// apiQRWait handles POST /api/xiaomi?action=qr_wait.
//
// It blocks in QR login steps 3 and 4 until the user scans the code (or the
// polling budget runs out) and, on success, persists the account token exactly
// like apiAuth does.
func apiQRWait(w http.ResponseWriter, r *http.Request) {
	if auth == nil || qrLogin == nil {
		http.Error(w, "xiaomi: qr login not started", http.StatusBadRequest)
		return
	}

	state := qrLogin

	if err := auth.QRWait(state); err != nil {
		auth, qrLogin = nil, nil
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if err := auth.QRFinish(state); err != nil {
		auth, qrLogin = nil, nil
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	userID, token := auth.UserToken()
	auth, qrLogin = nil, nil

	cloudsMu.Lock()
	if tokens == nil {
		tokens = map[string]string{userID: token}
	} else {
		tokens[userID] = token
	}
	cloudsMu.Unlock()

	if err := app.PatchConfig([]string{"xiaomi", userID}, token); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func apiAuth(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	username := r.Form.Get("username")
	password := r.Form.Get("password")
	captcha := r.Form.Get("captcha")
	verify := r.Form.Get("verify")

	var err error

	switch {
	case username != "" || password != "":
		auth = xiaomi.NewCloud(AppXiaomiHome)
		err = auth.Login(username, password)
	case captcha != "":
		err = auth.LoginWithCaptcha(captcha)
	case verify != "":
		err = auth.LoginWithVerify(verify)
	default:
		http.Error(w, "wrong request", http.StatusBadRequest)
		return
	}

	if err == nil {
		userID, token := auth.UserToken()
		auth = nil

		cloudsMu.Lock()
		if tokens == nil {
			tokens = map[string]string{userID: token}
		} else {
			tokens[userID] = token
		}
		cloudsMu.Unlock()

		err = app.PatchConfig([]string{"xiaomi", userID}, token)
	}

	if err != nil {
		var login *xiaomi.LoginError
		if errors.As(err, &login) {
			// as_file=1: write the captcha image to the exchange dir and return
			// its path instead of inlining base64 (Android app contract).
			if r.URL.Query().Get("as_file") != "" && len(login.Captcha) != 0 {
				if path, werr := writeExchangeFile("captcha.jpg", login.Captcha); werr == nil {
					w.Header().Set("Content-Type", api.MimeJSON)
					w.WriteHeader(http.StatusUnauthorized)
					_ = json.NewEncoder(w).Encode(map[string]any{
						"captcha_path": path,
						"captcha_type": "jpg",
						"verify_phone": login.VerifyPhone,
						"verify_email": login.VerifyEmail,
					})
					return
				}
			}

			w.Header().Set("Content-Type", api.MimeJSON)
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(err)
			return
		}

		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

const AppXiaomiHome = "xiaomiio"

func GetBaseURL(region string) string {
	switch region {
	case "de", "i2", "ru", "sg", "us":
		return "https://" + region + ".api.io.mi.com/app"
	}
	return "https://api.io.mi.com/app"
}
