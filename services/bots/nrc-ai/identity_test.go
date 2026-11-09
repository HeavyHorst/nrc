package main

import (
	"context"
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

const testAIKey = "fixture-ai-signing-secret-not-production"
const testAIOwner = "test-issuer/tailscale:user:17"

func testAIIdentity(workspace string) aiIdentity {
	return aiIdentity{Subject: "tailscale:user:17", Issuer: "test-issuer", Audience: "nrc-ai", Workspace: workspace, NotBefore: time.Now().Add(-time.Second).Unix(), ExpiresAt: time.Now().Add(5 * time.Minute).Unix()}
}

func testAIToken(identity aiIdentity) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	claims, _ := json.Marshal(identity)
	data := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	mac := hmac.New(sha256.New, []byte(testAIKey))
	mac.Write([]byte(data))
	return data + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func TestAIAuthentication(t *testing.T) {
	authenticate, err := newAIAuthentication(testAIKey, "test-issuer")
	if err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []string{"valid", "missing", "duplicate", "forged", "expired", "future", "issuer", "audience", "tag", "zero-user", "workspace", "duplicate-scope", "trailing-json", "get", "get-wrong-scope"} {
		t.Run(scenario, func(t *testing.T) {
			identity := testAIIdentity("team")
			body, path, method := `{"workspace":"team","question":"private"}`, "/ask", "POST"
			want := http.StatusUnauthorized
			switch scenario {
			case "valid":
				want = http.StatusOK
			case "expired":
				identity.ExpiresAt = time.Now().Unix()
			case "future":
				identity.NotBefore = time.Now().Add(time.Hour).Unix()
			case "issuer":
				identity.Issuer = "another-issuer"
			case "audience":
				identity.Audience = "nrc"
			case "tag":
				identity.Subject = "tag:agent"
			case "zero-user":
				identity.Subject = "tailscale:user:0"
			case "workspace":
				body, want = `{"workspace":"other"}`, http.StatusForbidden
			case "duplicate-scope":
				body, want = `{"workspace":"team","Workspace":"other"}`, http.StatusForbidden
			case "trailing-json":
				body, want = `{"workspace":"team"} {}`, http.StatusBadRequest
			case "get":
				method, path, body, want = "GET", "/ask/session/known?workspace=team", "", http.StatusOK
			case "get-wrong-scope":
				method, path, body, want = "GET", "/ask/session/known?workspace=other", "", http.StatusForbidden
			}
			r := httptest.NewRequest(method, path, strings.NewReader(body))
			r.Header.Set("X-Tailscale-User", "forged@example.com")
			r.Header.Set("X-NRC-Denied-Workspaces", "[]")
			if scenario != "missing" {
				r.Header.Set("X-NRC-AI-Auth", testAIToken(identity))
			}
			if scenario == "duplicate" {
				r.Header.Add("X-NRC-AI-Auth", testAIToken(identity))
			}
			if scenario == "forged" {
				r.Header.Set("X-NRC-AI-Auth", testAIToken(identity)+"x")
			}
			w := httptest.NewRecorder()
			authenticate(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if want != http.StatusOK {
					t.Fatal("unauthorized request reached handler")
				}
				got, ok := requireAIIdentity(w, r, "team")
				if !ok || got.owner() != testAIOwner {
					t.Fatal("lost verified owner")
				}
				deadline, ok := r.Context().Deadline()
				if !ok || deadline.Unix() != identity.ExpiresAt {
					t.Fatal("request outlives its authorization")
				}
				payload, _ := io.ReadAll(r.Body)
				if string(payload) != body {
					t.Fatal("authentication changed request body")
				}
				w.WriteHeader(http.StatusOK)
			})).ServeHTTP(w, r)
			if w.Code != want {
				t.Fatalf("HTTP %d: %s; want %d", w.Code, w.Body, want)
			}
		})
	}
	for _, key := range []string{"", "short", "dev-insecure-nrc-jwt-secret"} {
		if _, err := newAIAuthentication(key, "test-issuer"); err == nil {
			t.Fatal("accepted unsafe signing key")
		}
	}
}

func TestVoiceCallCarriesVerifiedIdentity(t *testing.T) {
	identity := testAIIdentity("team")
	var result map[string]bool
	err := voiceCall(context.Background(), identity, func(w http.ResponseWriter, r *http.Request) {
		got, ok := requireAIIdentity(w, r, "team")
		if !ok || got.owner() != testAIOwner {
			t.Fatal("voice delegation lost owner")
		}
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	}, map[string]string{"workspace": "team"}, &result)
	if err != nil || !result["ok"] {
		t.Fatalf("delegation failed: %v", err)
	}
	identity.ExpiresAt = time.Now().Add(-time.Second).Unix()
	err = voiceCall(context.Background(), identity, func(http.ResponseWriter, *http.Request) { t.Fatal("expired delegation executed") }, nil, &result)
	if err == nil {
		t.Fatal("expired delegation succeeded")
	}
}
