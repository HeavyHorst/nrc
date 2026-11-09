package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

// Set only from WhoIs, never from a caller's headers or a machine tag.
type aiSubjectKey struct{}

// The nginx hop preserves /ai paths; it does not establish user identity.
func aiBoundary(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/ai/ask" && !strings.HasPrefix(r.URL.Path, "/ai/ask/") && !strings.HasPrefix(r.URL.Path, "/ai/voice/") {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		subject, _ := r.Context().Value(aiSubjectKey{}).(string)
		if subject == "" {
			http.Error(w, "a verified human account is required", http.StatusUnauthorized)
			return
		}
		if len(jwtSecret) < 32 || string(jwtSecret) == "dev-insecure-nrc-jwt-secret" {
			http.Error(w, "AI authentication is not configured", http.StatusServiceUnavailable)
			return
		}
		if r.URL.RawPath != "" || strings.Contains(r.URL.Path, "//") || strings.Contains(r.URL.Path, "/./") || strings.Contains(r.URL.Path, "/../") {
			http.Error(w, "invalid AI path", http.StatusBadRequest)
			return
		}
		workspace := ""
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/ai/ask/session/") {
			values := r.URL.Query()["workspace"]
			if len(values) == 1 {
				workspace = values[0]
			}
		} else if r.Method == http.MethodPost && r.URL.RawQuery == "" {
			body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 2<<20))
			var scope struct {
				Workspace string `json:"workspace"`
			}
			if err != nil || json.Unmarshal(body, &scope) != nil {
				http.Error(w, "invalid request body", http.StatusBadRequest)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			workspace = scope.Workspace
		} else {
			http.Error(w, "invalid AI route", http.StatusBadRequest)
			return
		}
		if !workspaceNamePattern.MatchString(workspace) {
			http.Error(w, "workspace is required", http.StatusBadRequest)
			return
		}
		access := requestWorkspaceAccess(r)
		if !access.policy.allows(workspace, access.identity) {
			http.Error(w, "workspace access denied", http.StatusForbidden)
			return
		}
		token, err := buildProxyAuthToken(r.Header.Get("X-Tailscale-Login"), subject, workspace, "nrc-ai", time.Now())
		if err != nil {
			http.Error(w, "identity assertion failed", http.StatusInternalServerError)
			return
		}
		r.Header.Del("Authorization")
		r.Header.Del("X-NRC-Auth")
		r.Header.Set("X-NRC-AI-Auth", token)
		next.ServeHTTP(w, r)
	})
}
