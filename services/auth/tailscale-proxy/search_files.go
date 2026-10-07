package main

import (
	"crypto/subtle"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// Private bot endpoint, never registered on the public Tailscale mux. A blob
// must have an explicit grant for the requested workspace, even in open mode.
func searchFilesHandler(secret string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if secret == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+secret)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		fileID := strings.TrimPrefix(r.URL.Path, "/files/")
		workspace := r.URL.Query().Get("workspace")
		if fileID == r.URL.Path || !exportFileIDPattern.MatchString(fileID) || !workspaceNamePattern.MatchString(workspace) {
			http.Error(w, "invalid file or workspace", http.StatusBadRequest)
			return
		}
		grant, err := os.ReadFile(fileWorkspaceMarker(fileID, workspace))
		if err != nil || string(grant) != workspace {
			http.Error(w, "file access denied", http.StatusForbidden)
			return
		}
		file, err := os.Open(filepath.Join(fileStoragePath, fileID))
		if err != nil {
			http.Error(w, "file unavailable", http.StatusNotFound)
			return
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Size() > maxFileSize {
			http.Error(w, "invalid file", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		http.ServeContent(w, r, fileID, info.ModTime(), file)
	})
}
