package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAIIdentityBoundary(t *testing.T) {
	old := jwtSecret
	jwtSecret = []byte("fixture-ai-signing-secret-not-production")
	t.Cleanup(func() { jwtSecret = old })
	for _, scenario := range []string{"human", "renamed", "different-user", "tag", "zero-user", "missing-whois", "denied-workspace", "get", "get-no-scope", "open-no-scope", "duplicate-scope"} {
		t.Run(scenario, func(t *testing.T) {
			whois := workspaceTestIdentity("alice@example.com")
			method, path, body := "POST", "/ai/ask", `{"workspace":"team","question":"private"}`
			policy := workspaceTestPolicy(t)
			want, subject := http.StatusNoContent, "tailscale:user:17"
			switch scenario {
			case "renamed":
				whois.response.UserProfile.LoginName = "alice-renamed@example.com"
				policy = nil
			case "different-user":
				whois.response.UserProfile.ID = 99
				subject = "tailscale:user:99"
			case "tag":
				whois = workspaceTestIdentity("tag:amp")
				policy = nil
				want = http.StatusUnauthorized
			case "zero-user":
				whois.response.UserProfile.ID = 0
				want = http.StatusUnauthorized
			case "missing-whois":
				whois = fakeWhoIsClient{}
				policy = nil
				want = http.StatusUnauthorized
			case "denied-workspace":
				body = `{"workspace":"bob-private"}`
				want = http.StatusForbidden
			case "get":
				method, path, body = "GET", "/ai/ask/session/known?workspace=team", ""
			case "get-no-scope":
				method, path, body, want = "GET", "/ai/ask/session/known", "", http.StatusBadRequest
			case "open-no-scope":
				policy, body, want = nil, `{}`, http.StatusBadRequest
			case "duplicate-scope":
				body, want = `{"workspace":"team","Workspace":"bob-private"}`, http.StatusForbidden
			}
			forwarded := false
			backend := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				forwarded = true
				if want != http.StatusNoContent {
					t.Fatal("denied request forwarded")
				}
				if r.Header.Get("Authorization") != "" || r.Header.Get("X-NRC-Auth") != "" {
					t.Fatal("unrelated credentials forwarded")
				}
				parts := strings.Split(r.Header.Get("X-NRC-AI-Auth"), ".")
				if len(parts) != 3 {
					t.Fatal("missing AI assertion")
				}
				mac := hmac.New(sha256.New, jwtSecret)
				mac.Write([]byte(parts[0] + "." + parts[1]))
				signature, err := base64.RawURLEncoding.DecodeString(parts[2])
				if err != nil || !hmac.Equal(signature, mac.Sum(nil)) {
					t.Fatal("invalid AI signature")
				}
				claims, err := base64.RawURLEncoding.DecodeString(parts[1])
				var identity proxyJWTClaims
				if err != nil || json.Unmarshal(claims, &identity) != nil {
					t.Fatal("invalid AI claims")
				}
				if identity.Sub != subject || identity.Workspace != "team" || identity.Aud != "nrc-ai" || identity.Iss != jwtIssuer || identity.Exp <= time.Now().Unix() || identity.Exp > time.Now().Add(jwtTTL).Unix() {
					t.Fatalf("wrong identity: %+v", identity)
				}
				got, _ := io.ReadAll(r.Body)
				if string(got) != body {
					t.Fatal("changed body")
				}
				w.WriteHeader(http.StatusNoContent)
			})
			r := httptest.NewRequest(method, path, strings.NewReader(body))
			r.Header.Set("X-NRC-AI-Auth", "forged")
			r.Header.Set("X-Tailscale-User", "forged@example.com")
			r.Header.Set("Authorization", "Bearer caller-credential")
			w := httptest.NewRecorder()
			proxyHandler(backend, whois, policy).ServeHTTP(w, r)
			if w.Code != want {
				t.Fatalf("HTTP %d: %s, want %d", w.Code, w.Body, want)
			}
			if !forwarded && want == http.StatusNoContent {
				t.Fatal("authorized request not forwarded")
			}
		})
	}
}
