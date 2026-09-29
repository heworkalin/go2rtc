package xiaomi

import (
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// This file implements QR-code login, ported from the Python project
// Xiaomi-cloud-tokens-extractor (QrCodeXiaomiCloudConnector, token_extractor.py
// L605-L755). The four steps map one-to-one onto the Python methods:
//
//	login_step_1 -> LoginQR    fetch loginUrl / qr / lp / timeout
//	login_step_2 -> QRImage    fetch the QR image bytes
//	login_step_3 -> QRWait     blocking long-poll until scanned or timeout
//	login_step_4 -> QRFinish   follow location, collect serviceToken
//
// Notes on the port:
//
//   - The `lp` URL is used verbatim. Python does NOT append loginType or
//     callback parameters, so neither do we.
//   - Polling is blocking, not a "check" that returns a fresh URL. On timeout
//     we fail; the caller must restart from LoginQR (Python L696-L715).
//   - Step 4 is delegated to the existing finishAuth(), which already walks the
//     redirect chain and extracts userId / cUserId / serviceToken / passToken
//     cookies plus the ssecurity from the Extension-Pragma header.
//   - There is no captcha / 2FA handling here: the Mi Home app performs the
//     identity check while scanning, the long poll simply returns the result.

// qrPollTimeout is the per-request timeout used while long polling.
// Python uses `timeout=10` on each requests.get call.
const qrPollTimeout = 10 * time.Second

// QRLogin holds the state returned by the first QR login step.
//
// It corresponds to the fields Python stores in QrCodeXiaomiCloudConnector:
// _qr_image_url, _login_url, _long_polling_url and _timeout.
type QRLogin struct {
	QRImageURL string // qr image URL
	LoginURL   string // login link, can be opened manually as a fallback
	PollURL    string // long polling URL
	Timeout    int64  // total polling budget, in seconds

	location string // filled by QRWait, consumed by QRFinish
}

// LoginQR performs step 1: it asks the account server for a QR code to scan.
//
// Unlike the other requests this one must not mutate the shared client timeout,
// because the long poll in QRWait needs its own deadline, so it goes through a
// dedicated request instead of c.client.Get.
func (c *Cloud) LoginQR() (*QRLogin, error) {
	query := url.Values{
		"_qrsize":      {"480"},
		"qs":           {"?sid=" + c.sid + "&_json=true"},
		"callback":     {"https://sts.api.io.mi.com/sts"},
		"_hasLogo":     {"false"},
		"sid":          {c.sid},
		"serviceParam": {""},
		"_locale":      {"en_GB"},
		// milliseconds, matching Python's int(time.time() * 1000)
		"_dc": {strconv.FormatInt(time.Now().UnixMilli(), 10)},
	}

	res, err := c.client.Get("https://account.xiaomi.com/longPolling/loginUrl?" + query.Encode())
	if err != nil {
		return nil, err
	}

	var v struct {
		LoginURL string `json:"loginUrl"`
		QR       string `json:"qr"`
		LP       string `json:"lp"`
		Timeout  int64  `json:"timeout"`
	}
	if _, err = readLoginResponse(res.Body, &v); err != nil {
		return nil, err
	}
	if v.QR == "" || v.LP == "" {
		return nil, errors.New("xiaomi: qr login: empty qr/lp in response")
	}

	return &QRLogin{
		QRImageURL: v.QR,
		LoginURL:   v.LoginURL,
		PollURL:    v.LP,
		Timeout:    v.Timeout,
	}, nil
}

// QRImage performs step 2: it downloads the QR image bytes.
//
// No content type is assumed, matching Python which passes response.content
// through untouched. The caller decides how to render it.
func (c *Cloud) QRImage(qr *QRLogin) ([]byte, error) {
	if qr == nil || qr.QRImageURL == "" {
		return nil, errors.New("xiaomi: qr login: no qr image url")
	}

	res, err := c.client.Get(qr.QRImageURL)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()

	if res.StatusCode != http.StatusOK {
		return nil, errors.New("xiaomi: qr login: " + res.Status)
	}

	return io.ReadAll(res.Body)
}

// QRWait performs step 3: it blocks until the user scans the code.
//
// Polling semantics follow Python L694-L715 exactly:
//
//  1. remember the start time
//  2. GET the lp URL, each attempt limited to qrPollTimeout
//  3. a per-request timeout is retried, not fatal
//  4. once the elapsed time exceeds qr->Timeout, give up
//  5. any other transport error is fatal
//  6. a non-200 response is logged and retried
//
// On success it stores userID, ssecurity, passToken and location on the Cloud
// (and qr->location for QRFinish). It deliberately does not fetch the service
// token yet, that is step 4.
func (c *Cloud) QRWait(qr *QRLogin) error {
	if qr == nil || qr.PollURL == "" {
		return errors.New("xiaomi: qr login: no polling url")
	}

	timeout := qr.Timeout
	if timeout <= 0 {
		timeout = 300 // Python default observed value
	}

	// The shared client has a 15s deadline; temporarily shorten it to the
	// per-request poll timeout so a stalled poll does not block for long.
	orig := c.client.Timeout
	c.client.Timeout = qrPollTimeout
	defer func() { c.client.Timeout = orig }()

	start := time.Now()

	for {
		res, err := c.client.Get(qr.PollURL)
		if err != nil {
			// Only a per-request deadline is retryable (Python catches
			// requests.Timeout and keeps going).
			if isTimeout(err) {
				if time.Since(start) > time.Duration(timeout)*time.Second {
					return errors.New("xiaomi: qr login: long polling timed out")
				}
				continue
			}
			return err
		}

		if res.StatusCode != http.StatusOK {
			res.Body.Close()
			if time.Since(start) > time.Duration(timeout)*time.Second {
				return errors.New("xiaomi: qr login: long polling timed out")
			}
			continue
		}

		// The account server returns userId as a JSON number here (unlike the
		// cookies used by finishAuth, where it is always a string). Accept both
		// shapes so a server-side change cannot break login.
		var v struct {
			UserID    jsonID `json:"userId"`
			Ssecurity []byte `json:"ssecurity"`
			PassToken string `json:"passToken"`
			Location  string `json:"location"`
		}
		_, err = readLoginResponse(res.Body, &v)
		if err != nil {
			return err
		}
		if v.Location == "" {
			return errors.New("xiaomi: qr login: empty location in response")
		}

		c.userID = v.UserID.String()
		c.ssecurity = v.Ssecurity
		c.passToken = v.PassToken
		qr.location = v.Location

		return nil
	}
}

// QRFinish performs step 4: it follows the location from QRWait and collects
// the service token, finishing the authentication.
//
// All cookie/header handling is reused from finishAuth().
func (c *Cloud) QRFinish(qr *QRLogin) error {
	if qr == nil || qr.location == "" {
		return errors.New("xiaomi: qr login: not scanned yet")
	}
	return c.finishAuth(qr.location)
}

// jsonID unmarshals a JSON value that may arrive either as a number or as a
// string, and always yields a string. The Xiaomi account server sends userId
// as a number on the QR long-poll endpoint, while other endpoints/cookies use
// the string form.
type jsonID string

func (j *jsonID) UnmarshalJSON(b []byte) error {
	s := string(b)
	if s == "null" {
		*j = ""
		return nil
	}
	// strip surrounding quotes if it is a JSON string
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		s = s[1 : len(s)-1]
	}
	*j = jsonID(s)
	return nil
}

func (j jsonID) String() string { return string(j) }

// isTimeout reports whether err is a deadline/timeout error.
func isTimeout(err error) bool {
	type timeouter interface{ Timeout() bool }
	var t timeouter
	if errors.As(err, &t) {
		return t.Timeout()
	}
	return false
}
