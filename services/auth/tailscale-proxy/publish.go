package main

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"
)

// Only the restricted API is exposed; reviewer HTML never passes this gateway.
func publishGateway(backend, workspace string) http.Handler {
	u, err := url.Parse(backend)
	configured := err == nil && u.Host != "" && (u.Scheme == "http" || u.Scheme == "https") && u.User == nil && u.RawQuery == "" && u.Fragment == "" && u.Path == "" && workspaceNamePattern.MatchString(workspace)
	var proxy *httputil.ReverseProxy
	if configured {
		proxy = httputil.NewSingleHostReverseProxy(u)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		access := requestWorkspaceAccess(r)
		if access.identity == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if !configured || len(jwtSecret) == 0 || string(jwtSecret) == "dev-insecure-nrc-jwt-secret" {
			http.Error(w, "publishing gateway is not configured", http.StatusServiceUnavailable)
			return
		}
		if r.URL.RawPath != "" || strings.Contains(r.URL.Path, "//") || strings.Contains(r.URL.Path, "/./") || strings.Contains(r.URL.Path, "/../") || r.URL.RawQuery != "" {
			http.Error(w, "invalid publishing path", http.StatusBadRequest)
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/publish")
		allowed := (r.Method == "GET" && path == "/api/publications") || (r.Method == "POST" && path == "/api/drafts")
		if r.Method == "GET" && strings.HasPrefix(path, "/api/drafts/") {
			id := strings.TrimPrefix(path, "/api/drafts/")
			allowed = len(id) == 32 && strings.Trim(id, "0123456789abcdef") == ""
		}
		if !allowed {
			http.NotFound(w, r)
			return
		}
		if !access.policy.allows(workspace, access.identity) {
			http.Error(w, "workspace access denied", http.StatusForbidden)
			return
		}
		token, err := buildProxyAuthToken(r.Header.Get("X-Tailscale-Login"), access.identity, workspace, "nrc-publish-agent", time.Now())
		if err != nil {
			http.Error(w, "identity assertion failed", 500)
			return
		}
		r.Header.Del("Authorization")
		r.Header.Set("X-NRC-Publish-Auth", token)
		r.URL.Path = path
		proxy.ServeHTTP(w, r)
	})
}
