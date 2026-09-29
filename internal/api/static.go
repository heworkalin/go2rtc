//go:build !no_ui

package api

import (
	"net/http"

	"github.com/AlexxIT/go2rtc/www"
)

// initStatic registers the embedded web UI handler.
//
// The Android embedded build is compiled with `-tags no_ui`, which swaps this
// file for static_no_ui.go so the 190 KB web assets are not linked in at all.
func initStatic(staticDir string) {
	var root http.FileSystem
	if staticDir != "" {
		log.Info().Str("dir", staticDir).Msg("[api] serve static")
		root = http.Dir(staticDir)
	} else {
		root = http.FS(www.Static)
	}

	base := len(basePath)
	fileServer := http.FileServer(root)

	HandleFunc("", func(w http.ResponseWriter, r *http.Request) {
		if base > 0 {
			r.URL.Path = r.URL.Path[base:]
		}
		fileServer.ServeHTTP(w, r)
	})
}
