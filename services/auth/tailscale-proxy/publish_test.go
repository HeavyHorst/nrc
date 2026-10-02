package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

func TestPublishGatewayAuthorization(t *testing.T) {
	old := jwtSecret
	jwtSecret = []byte("fixture-signing-secret-not-production")
	defer func() { jwtSecret = old }()
	var forwarded atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		if r.URL.Path != "/api/publications" || r.Header.Get("Authorization") != "" {
			t.Error("route or credential forwarding incorrect")
		}
		parts := strings.Split(r.Header.Get("X-NRC-Publish-Auth"), ".")
		if len(parts) != 3 {
			t.Error("missing signed assertion")
			return
		}
		data, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var claims proxyJWTClaims
		if json.Unmarshal(data, &claims) != nil || claims.Sub != r.Header.Get("X-Tailscale-User") || claims.Sub == "forged@example.com" || claims.Workspace != "alice-private" || claims.Aud != "nrc-publish-agent" {
			t.Errorf("wrong assertion: %s", data)
		}
		w.WriteHeader(204)
	}))
	defer backend.Close()
	t.Setenv("NRC_PUBLISH_BACKEND", backend.URL)
	t.Setenv("NRC_PUBLISH_WORKSPACE", "alice-private")
	for _, tc := range []struct {
		identity string
		policy   workspacePolicy
		status   int
	}{
		{"alice@example.com", workspaceTestPolicy(t), 204},
		{"tag:amp", workspaceTestPolicy(t), 204},
		{"bob@example.com", workspaceTestPolicy(t), 403},
		{"", nil, 401},
		{"alice@example.com", nil, 204},
	} {
		client := workspaceTestIdentity(tc.identity)
		if tc.identity == "" {
			client = fakeWhoIsClient{err: fmt.Errorf("WhoIs unavailable")}
		}
		h := proxyHandler(http.NotFoundHandler(), client, tc.policy)
		r := httptest.NewRequest("GET", "http://nrc/publish/api/publications", nil)
		r.Header.Set("X-Tailscale-User", "forged@example.com")
		r.Header.Set("X-NRC-Publish-Auth", "forged")
		r.Header.Set("Authorization", "Bearer old-token")
		before := forwarded.Load()
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("%s: %d %s", tc.identity, w.Code, w.Body.String())
		}
		if tc.status != 204 && forwarded.Load() != before {
			t.Fatal("denied request forwarded")
		}
	}
	h := proxyHandler(http.NotFoundHandler(), workspaceTestIdentity("alice@example.com"), nil)
	for _, path := range []string{"/publish/api/drafts/0123456789abcdef0123456789abcdef/approve", "/publish/notes", "/publish/api/drafts/%2e%2e/notes", "/publish/api/publications?workspace=other"} {
		r := httptest.NewRequest("GET", "http://nrc"+path, nil)
		w := httptest.NewRecorder()
		before := forwarded.Load()
		h.ServeHTTP(w, r)
		if w.Code < 300 || forwarded.Load() != before {
			t.Fatalf("unsafe route forwarded: %s", path)
		}
	}
	r := httptest.NewRequest("POST", "http://nrc/publish/api/drafts", strings.NewReader(`{}`))
	r.Header.Set("Origin", "https://evil.example")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("foreign origin accepted")
	}
}

func TestPublishWorkspaceRouting(t *testing.T) {
	for _, backend := range []string{"", "http://publish:8094"} {
		t.Setenv("NRC_PUBLISH_BACKEND", backend)
		t.Setenv("NRC_PUBLISH_WORKSPACE", "alice-private")
		called := false
		proxy := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			called = true
			if r.URL.Path != "/publish" || !isWebSocketUpgrade(r) {
				t.Error("workspace upgrade changed")
			}
			w.WriteHeader(http.StatusSwitchingProtocols)
		})
		h := proxyHandler(proxy, workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t))
		r := httptest.NewRequest("GET", "http://nrc/publish", nil)
		r.Header.Set("Connection", "Upgrade")
		r.Header.Set("Upgrade", "websocket")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if !called || w.Code != http.StatusSwitchingProtocols || w.Header().Get("Location") != "" {
			t.Fatalf("publish workspace intercepted with backend %q: %d", backend, w.Code)
		}
	}
}

// Real gateway, synthetic WhoIs only: no tailnet account or live customer data.
func TestPublishGatewayPreview(t *testing.T) {
	if os.Getenv("PUBLISH_GATEWAY_PREVIEW") != "1" {
		t.Skip("opt-in integration fixture")
	}
	jwtSecret = []byte("fixture-signing-secret-not-production")
	server := &http.Server{Addr: "127.0.0.1:18195", Handler: proxyHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.Write([]byte("ok"))
			return
		}
		http.NotFound(w, r)
	}), workspaceTestIdentity("tag:amp"), nil)}
	t.Cleanup(func() { server.Close() })
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		t.Fatal(err)
	}
}
