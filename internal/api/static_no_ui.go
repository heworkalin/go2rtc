//go:build no_ui

package api

import (
	"net/http"

	"github.com/AlexxIT/go2rtc/internal/app"
)

// initStatic is the headless (no embedded web UI) variant, selected with
// `-tags no_ui`.
//
// It is used by the Android embedded build, where the UI is a native app and
// the web assets are dead weight. Two things still work here:
//
//   - an explicit static_dir keeps being served, so a user can point go2rtc at
//     a directory on disk if they really want the browser UI;
//   - without static_dir the root path answers a small JSON banner instead of
//     a 404, which makes it obvious that the binary is alive and headless.
func initStatic(staticDir string) {
	if staticDir != "" {
		log.Info().Str("dir", staticDir).Msg("[api] serve static")
		base := len(basePath)
		fileServer := http.FileServer(http.Dir(staticDir))

		HandleFunc("", func(w http.ResponseWriter, r *http.Request) {
			if base > 0 {
				r.URL.Path = r.URL.Path[base:]
			}
			fileServer.ServeHTTP(w, r)
		})
		return
	}

	HandleFunc("", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != basePath+"/" && r.URL.Path != basePath {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", MimeJSON)
		_, _ = w.Write([]byte(`{"app":"go2rtc","ui":false,"version":"` + app.Version + `"}`))
	})
}
