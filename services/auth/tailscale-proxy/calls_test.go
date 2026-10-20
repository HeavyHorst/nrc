package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestCallsGatewayIdentityWorkspaceAndUpgrade(t *testing.T) {
	old := jwtSecret
	jwtSecret = []byte("fixture-calls-signing-key-not-production")
	t.Cleanup(func() { jwtSecret = old })
	var forwarded atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		parts := strings.Split(r.Header.Get("X-NRC-Calls-Auth"), ".")
		if len(parts) != 3 {
			t.Error("missing assertion")
			return
		}
		body, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var claims proxyJWTClaims
		mac := hmac.New(sha256.New, jwtSecret)
		mac.Write([]byte(parts[0] + "." + parts[1]))
		sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
		if !hmac.Equal(sig, mac.Sum(nil)) || json.Unmarshal(body, &claims) != nil || claims.Username != "alice" || claims.Sub != "alice" || claims.Workspace != "alice-private" || claims.Aud != "nrc-calls" || claims.Iss != jwtIssuer || claims.Exp-claims.Nbf != 7202 {
			t.Errorf("incorrect signed calls assertion: %+v", claims)
			return
		}
		if r.URL.Path != "/ws" || r.Header.Get("Authorization") != "" || r.Header.Get("X-NRC-Auth") != "" {
			t.Error("incorrect forwarding boundary")
			return
		}
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			t.Error(err)
			return
		}
		defer c.CloseNow()
		_ = c.Write(r.Context(), websocket.MessageText, []byte(`{"type":"ready"}`))
		_, _, _ = c.Read(r.Context())
	}))
	defer backend.Close()
	t.Setenv("NRC_CALLS_BACKEND", backend.URL)
	for _, tc := range []struct {
		identity, path, origin string
		status                 int
	}{
		{"alice@example.com", "/calls/ws/alice-private", "", 101},
		{"bob@example.com", "/calls/ws/alice-private", "", 403},
		{"alice@example.com", "/calls/ws/alice-private", "https://evil.example", 403},
		{"alice@example.com", "/calls/ws/alice-private?workspace=other", "", 400},
		{"alice@example.com", "/calls/ws/a/b", "", 400},
	} {
		h := httptest.NewServer(proxyHandler(http.NotFoundHandler(), workspaceTestIdentity(tc.identity), workspaceTestPolicy(t)))
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		headers := http.Header{"X-Nrc-Calls-Auth": {"forged"}, "Authorization": {"Bearer forged"}}
		if tc.origin != "" {
			headers.Set("Origin", tc.origin)
		} else {
			headers.Set("Origin", h.URL)
		}
		before := forwarded.Load()
		c, response, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+tc.path, &websocket.DialOptions{HTTPHeader: headers})
		if response == nil || response.StatusCode != tc.status {
			t.Fatalf("%+v: response %v error %v", tc, response, err)
		}
		if tc.status == 101 {
			_, body, err := c.Read(ctx)
			if err != nil || string(body) != `{"type":"ready"}` {
				t.Fatalf("upgrade roundtrip: %s %v", body, err)
			}
			c.CloseNow()
		} else if forwarded.Load() != before {
			t.Fatal("denied request reached backend")
		}
		cancel()
		h.Close()
	}
	t.Setenv("NRC_CALLS_BACKEND", "")
	w := httptest.NewRecorder()
	proxyHandler(http.NotFoundHandler(), workspaceTestIdentity("alice@example.com"), nil).ServeHTTP(w, httptest.NewRequest("GET", "http://nrc/api/features", nil))
	var features map[string]any
	if json.Unmarshal(w.Body.Bytes(), &features) != nil || features["calls"] == true {
		t.Fatal("unconfigured calls advertised")
	}
}
