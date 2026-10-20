package main

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"
)

func callsBackend(backend string) (*url.URL, bool) {
	u, err := url.Parse(backend)
	return u, err == nil && u.Host != "" && (u.Scheme == "http" || u.Scheme == "https") && u.User == nil && u.RawQuery == "" && u.Fragment == "" && u.Path == "" && len(jwtSecret) >= 32 && string(jwtSecret) != "dev-insecure-nrc-jwt-secret"
}

func callsWorkspace(r *http.Request) string {
	return strings.TrimPrefix(r.URL.Path, "/calls/ws/")
}

func callsGateway(backend string) http.Handler {
	u, configured := callsBackend(backend)
	var proxy *httputil.ReverseProxy
	if configured {
		proxy = httputil.NewSingleHostReverseProxy(u)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		access := requestWorkspaceAccess(r)
		workspace := callsWorkspace(r)
		if access.identity == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if !configured {
			http.Error(w, "calls are not configured", http.StatusServiceUnavailable)
			return
		}
		if r.Method != "GET" || !isWebSocketUpgrade(r) || r.URL.RawQuery != "" || r.URL.RawPath != "" || !workspaceNamePattern.MatchString(workspace) {
			http.Error(w, "invalid calls route", http.StatusBadRequest)
			return
		}
		if !access.policy.allows(workspace, access.identity) {
			http.Error(w, "workspace access denied", http.StatusForbidden)
			return
		}
		username := r.Header.Get("X-Tailscale-Login")
		// Calls outlive the ordinary five-minute request assertion. The service
		// closes this socket after two hours; individual calls last at most one.
		token, err := buildProxyAuthTokenWithTTL(username, username, workspace, "nrc-calls", time.Now(), 2*time.Hour)
		if err != nil {
			http.Error(w, "identity assertion failed", http.StatusInternalServerError)
			return
		}
		r.Header.Del("Authorization")
		r.Header.Del("X-NRC-Auth")
		r.Header.Set("X-NRC-Calls-Auth", token)
		r.URL.Path = "/ws"
		proxy.ServeHTTP(w, r)
	})
}
