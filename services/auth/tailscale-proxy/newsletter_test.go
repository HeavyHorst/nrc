package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestNewsletterGatewayPermissionsAndScope(t *testing.T) {
	old := jwtSecret
	jwtSecret = []byte("fixture-signing-secret-not-production")
	t.Cleanup(func() { jwtSecret = old })
	var calls atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/api/state" || r.Header.Get("Authorization") != "" {
			t.Error("wrong route or leaked authorization")
		}
		parts := strings.Split(r.Header.Get("X-NRC-Newsletter-Auth"), ".")
		if len(parts) != 3 {
			t.Error("missing signed assertion")
			return
		}
		body, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var claims proxyJWTClaims
		if json.Unmarshal(body, &claims) != nil || claims.Sub != "alice@example.com" || claims.Workspace != "alice-private" || claims.Aud != "nrc-newsletter" {
			t.Error("wrong newsletter identity assertion")
		}
		w.WriteHeader(204)
	}))
	t.Cleanup(backend.Close)
	t.Setenv("NRC_NEWSLETTER_BACKEND", backend.URL)
	t.Setenv("NRC_NEWSLETTER_WORKSPACE", "alice-private")
	t.Setenv("NRC_NEWSLETTER_USERS", "alice@example.com,bob@example.com")
	for _, tc := range []struct {
		identity, workspace, path, origin string
		want                              int
	}{
		{"alice@example.com", "alice-private", "/newsletter/api/state", "", 204},
		{"alice@example.com", "other", "/newsletter/api/state", "", 403},
		{"alice@example.com", "", "/newsletter/api/state", "", 403},
		{"bob@example.com", "alice-private", "/newsletter/api/state", "", 403},
		{"eve@example.com", "alice-private", "/newsletter/api/state", "", 403},
		{"alice@example.com", "alice-private", "/newsletter/api/state", "https://evil.example", 403},
		{"alice@example.com", "alice-private", "/newsletter/api/state?workspace=other", "", 400},
		{"alice@example.com", "alice-private", "/newsletter/api/events", "", 404},
	} {
		h := proxyHandler(http.NotFoundHandler(), workspaceTestIdentity(tc.identity), workspaceTestPolicy(t))
		r := httptest.NewRequest("GET", "http://nrc"+tc.path, nil)
		r.Header.Set("X-NRC-Workspace", tc.workspace)
		r.Header.Set("X-NRC-Newsletter-Auth", "forged")
		r.Header.Set("Authorization", "Bearer must-not-forward")
		if tc.origin != "" {
			r.Header.Set("Origin", tc.origin)
		}
		before := calls.Load()
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want || (tc.want != 204 && calls.Load() != before) {
			t.Fatalf("%+v: status %d, forwarded %v", tc, w.Code, calls.Load() != before)
		}
	}
	// Feature discovery must not advertise a sending module to a workspace outsider.
	for _, identity := range []string{"alice@example.com", "bob@example.com"} {
		w := httptest.NewRecorder()
		h := proxyHandler(http.NotFoundHandler(), workspaceTestIdentity(identity), workspaceTestPolicy(t))
		h.ServeHTTP(w, httptest.NewRequest("GET", "http://nrc/api/features", nil))
		var features struct {
			Newsletter bool   `json:"newsletter"`
			Workspace  string `json:"newsletter_workspace"`
		}
		if json.Unmarshal(w.Body.Bytes(), &features) != nil || features.Newsletter != (identity == "alice@example.com") || (features.Newsletter && features.Workspace != "alice-private") {
			t.Fatalf("feature access for %s: %s", identity, w.Body.String())
		}
	}
}

func TestNewsletterServiceAndImportRoutes(t *testing.T) {
	old := jwtSecret
	jwtSecret = []byte("fixture-signing-secret-not-production")
	t.Cleanup(func() { jwtSecret = old })
	var calls atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != "POST" || r.Header.Get("X-NRC-Newsletter-Auth") == "forged" || r.Header.Get("Authorization") != "" {
			t.Error("untrusted credentials or method forwarded")
		}
		w.WriteHeader(204)
	}))
	t.Cleanup(backend.Close)
	t.Setenv("NRC_NEWSLETTER_USERS", "alice@example.com")
	t.Setenv("NRC_NEWSLETTER_BACKEND", backend.URL)
	t.Setenv("NRC_NEWSLETTER_WORKSPACE", "alice-private")
	for _, path := range []string{"/newsletter/api/consents/import", "/newsletter/api/subscribers/search", "/newsletter/api/campaigns/" + strings.Repeat("a", 64) + "/audience"} {
		for _, identity := range []string{"alice@example.com", "eve@example.com"} {
			for _, method := range []string{"POST", "GET", "PUT"} {
				r := httptest.NewRequest(method, "http://nrc"+path, nil)
				r.Header.Set("X-NRC-Workspace", "alice-private")
				r.Header.Set("X-NRC-Newsletter-Auth", "forged")
				r.Header.Set("Authorization", "Bearer must-not-forward")
				// Exercise the real identity/workspace middleware, including origin checks.
				h := proxyHandler(http.NotFoundHandler(), workspaceTestIdentity(identity), workspaceTestPolicy(t))
				before := calls.Load()
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				want := 404
				if identity != "alice@example.com" {
					want = 403
				} else if method == "POST" {
					want = 204
				}
				if w.Code != want || (want != 204 && calls.Load() != before) {
					t.Fatalf("%s %s %s: status %d expected %d", identity, method, path, w.Code, want)
				}
			}
		}
	}
}
