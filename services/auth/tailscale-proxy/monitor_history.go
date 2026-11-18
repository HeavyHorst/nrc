package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

// One gateway deployment is pinned to one sidecar workspace. Neither endpoint
// nor service credentials may be selected by a browser request.
func monitorHistoryGateway(backend, workspace, secret string) http.Handler {
	u, err := url.Parse(backend)
	configured := err == nil && u.Host != "" && (u.Scheme == "http" || u.Scheme == "https") && u.User == nil && u.Path == "" && u.RawQuery == "" && !u.ForceQuery && u.Fragment == "" && workspaceNamePattern.MatchString(workspace) && len(secret) >= 32 && !strings.ContainsAny(secret, " \t\r\n")
	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	readers := make(chan struct{}, 2)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Bound downstream writes too: slow browsers must not retain read slots.
		// Native net/http writers support this; in-memory recorders need no deadline.
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(5 * time.Second))
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		access := requestWorkspaceAccess(r)
		if access.identity == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if !configured {
			http.Error(w, "monitor history is not configured", http.StatusServiceUnavailable)
			return
		}
		if r.Header.Get("X-NRC-Workspace") != workspace || !access.policy.allows(workspace, access.identity) {
			http.Error(w, "workspace access denied", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/monitoring/history/"), "/")
		if r.URL.RawPath != "" || !strings.HasPrefix(r.URL.Path, "/monitoring/history/") || len(parts) != 2 || isWebSocketUpgrade(r) || len(r.URL.RawQuery) > 8192 {
			http.Error(w, "invalid history request", http.StatusBadRequest)
			return
		}
		id, err := strconv.ParseUint(parts[0], 10, 64)
		batch := parts[0] == "batch" && parts[1] == "uptime"
		if !batch && (err != nil || id == 0 || strconv.FormatUint(id, 10) != parts[0] || (parts[1] != "samples" && parts[1] != "runs" && parts[1] != "uptime" && parts[1] != "inspector")) {
			http.NotFound(w, r)
			return
		}
		query, err := url.ParseQuery(r.URL.RawQuery)
		if err != nil {
			http.Error(w, "invalid history query", http.StatusBadRequest)
			return
		}
		for key, values := range query {
			if len(values) != 1 || (key != "from" && key != "to" && key != "resolution" && key != "identity" && key != "acceptance" && !(batch && key == "ids") && !(parts[1] == "inspector" && (key == "view" || key == "revision" || key == "sequence"))) {
				http.Error(w, "invalid history query", http.StatusBadRequest)
				return
			}
		}
		var ids []string
		if batch {
			ids = strings.Split(query.Get("ids"), ",")
			seen := make(map[string]bool)
			if len(ids) > 16 || query.Has("identity") || query.Has("acceptance") {
				http.Error(w, "invalid history batch", http.StatusBadRequest)
				return
			}
			for _, text := range ids {
				value, err := strconv.ParseUint(text, 10, 64)
				if err != nil || value == 0 || strconv.FormatUint(value, 10) != text || seen[text] {
					http.Error(w, "invalid history batch", http.StatusBadRequest)
					return
				}
				seen[text] = true
			}
		}
		target := *u
		target.Path = "/v1/history/" + parts[0] + "/" + parts[1]
		target.RawQuery = r.URL.RawQuery
		request, err := http.NewRequestWithContext(r.Context(), http.MethodGet, target.String(), nil)
		if err != nil {
			http.Error(w, "history unavailable", http.StatusBadGateway)
			return
		}
		// Build headers from scratch: no browser cookies or credentials escape.
		request.Header.Set("Authorization", "Bearer "+secret)
		select {
		case readers <- struct{}{}:
			defer func() { <-readers }()
		default:
			http.Error(w, "history busy", http.StatusServiceUnavailable)
			return
		}
		response, err := client.Do(request)
		if err != nil {
			http.Error(w, "history unavailable", http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			switch response.StatusCode {
			case 400, 404, 422, 503:
				http.Error(w, http.StatusText(response.StatusCode), response.StatusCode)
			default:
				http.Error(w, "history unavailable", http.StatusBadGateway)
			}
			return
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, (4<<20)+1))
		if err != nil || len(body) > 4<<20 || response.Header.Get("Content-Type") != "application/json" {
			http.Error(w, "invalid history response", http.StatusBadGateway)
			return
		}
		var scope struct {
			Version    int      `json:"version"`
			Workspace  string   `json:"workspace"`
			MonitorID  string   `json:"monitor_id"`
			Kind       string   `json:"kind"`
			Identity   string   `json:"identity"`
			MonitorIDs []string `json:"monitor_ids"`
			Results    []struct {
				MonitorID string `json:"monitor_id"`
			} `json:"results"`
		}
		if json.Unmarshal(body, &scope) != nil || scope.Version != 1 || scope.Workspace != workspace || scope.MonitorID != parts[0] {
			http.Error(w, "invalid history scope", http.StatusBadGateway)
			return
		}
		if parts[1] == "inspector" && (scope.Kind != "inspector" || scope.Identity != query.Get("identity") || scope.Identity == "") {
			http.Error(w, "invalid history scope", http.StatusBadGateway)
			return
		}
		if batch {
			if !slices.Equal(scope.MonitorIDs, ids) || len(scope.Results) != len(ids) {
				http.Error(w, "invalid history scope", http.StatusBadGateway)
				return
			}
			for i, result := range scope.Results {
				if result.MonitorID != ids[i] {
					http.Error(w, "invalid history scope", http.StatusBadGateway)
					return
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	})
}
