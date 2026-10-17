package main

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

func newsletterBackend(backend, workspace string) (*url.URL, bool) {
	u, err := url.Parse(backend)
	return u, err == nil && u.Host != "" && (u.Scheme == "http" || u.Scheme == "https") && u.User == nil && u.RawQuery == "" && u.Fragment == "" && u.Path == "" && workspaceNamePattern.MatchString(workspace) && len(jwtSecret) != 0 && string(jwtSecret) != "dev-insecure-nrc-jwt-secret"
}

// This is a sending permission, not just a navigation visibility flag.
func newsletterAllowed(identity, workspace string, policy workspacePolicy) bool {
	_, allowed := parseCustomerUsers(os.Getenv("NRC_NEWSLETTER_USERS"))[identity]
	return allowed && policy.allows(workspace, identity)
}

func newsletterGateway(backend, workspace string) http.Handler {
	u, configured := newsletterBackend(backend, workspace)
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
		if !configured {
			http.Error(w, "newsletter gateway is not configured", http.StatusServiceUnavailable)
			return
		}
		if !newsletterAllowed(access.identity, workspace, access.policy) || r.Header.Get("X-NRC-Workspace") != workspace {
			http.Error(w, "newsletter workspace or sending permission denied", http.StatusForbidden)
			return
		}
		if r.URL.RawPath != "" || strings.Contains(r.URL.Path, "//") || strings.Contains(r.URL.Path, "/./") || strings.Contains(r.URL.Path, "/../") || r.URL.RawQuery != "" || isWebSocketUpgrade(r) {
			http.Error(w, "invalid newsletter path", http.StatusBadRequest)
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/newsletter")
		parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
		allowed := (r.Method == "GET" && path == "/api/state") || (r.Method == "POST" && (path == "/api/campaigns" || path == "/api/consents/import"))
		if len(parts) >= 3 && parts[0] == "api" && parts[1] == "campaigns" && len(parts[2]) == 64 && strings.Trim(parts[2], "0123456789abcdef") == "" {
			allowed = (len(parts) == 3 && r.Method == "PUT") || (len(parts) == 4 && r.Method == "POST" && (parts[3] == "preview" || parts[3] == "test" || parts[3] == "send" || parts[3] == "audience"))
		}
		if len(parts) == 4 && parts[0] == "api" && parts[1] == "subscribers" && len(parts[2]) > 0 && len(parts[2]) <= 20 && strings.Trim(parts[2], "0123456789") == "" {
			allowed = r.Method == "POST" && (parts[3] == "invite" || parts[3] == "unsubscribe")
		}
		if !allowed {
			http.NotFound(w, r)
			return
		}
		token, err := buildProxyAuthToken(r.Header.Get("X-Tailscale-Login"), access.identity, workspace, "nrc-newsletter", time.Now())
		if err != nil {
			http.Error(w, "identity assertion failed", http.StatusInternalServerError)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		r.Header.Del("Authorization")
		r.Header.Set("X-NRC-Newsletter-Auth", token)
		r.URL.Path = path
		proxy.ServeHTTP(w, r)
	})
}
