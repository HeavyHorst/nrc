package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

// Fixed, operator-configured health targets only. Never proxy service payloads,
// credentials, redirects, workspace names or arbitrary client-supplied URLs.
func subsystemHealth(targets map[string]string) http.Handler {
	client := &http.Client{
		Timeout:       3 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if requestWorkspaceAccess(r).identity == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet || isWebSocketUpgrade(r) {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		target, ok := targets[strings.TrimPrefix(r.URL.Path, "/api/subsystems/")]
		if !ok || r.URL.RawQuery != "" || r.URL.RawPath != "" {
			http.NotFound(w, r)
			return
		}
		status := "not_configured"
		if target != "" {
			status = "unavailable"
			req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, target, nil)
			if err == nil {
				resp, err := client.Do(req)
				if err == nil {
					defer resp.Body.Close()
					if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusNotFound {
						status = "unknown"
					}
					if resp.StatusCode == http.StatusOK {
						body, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024+1))
						status = "unknown"
						if err == nil && len(body) <= 16*1024 {
							var health struct {
								Status string `json:"status"`
							}
							if strings.TrimSpace(string(body)) == "ok" {
								status = "ok" // Publish exposes plain-text process health.
							} else if json.Unmarshal(body, &health) == nil && (health.Status == "ok" || health.Status == "degraded") {
								status = health.Status
							}
						}
					}
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(struct {
			Status string `json:"status"`
		}{status})
	})
}
