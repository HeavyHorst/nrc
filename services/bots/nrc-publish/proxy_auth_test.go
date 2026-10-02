package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

func testProxyAssertion(secret string, claims map[string]any) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	data, _ := json.Marshal(claims)
	payload := header + "." + base64.RawURLEncoding.EncodeToString(data)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func testProxyClaims() map[string]any {
	return map[string]any{"sub": "tag:amp", "workspace": "test-workspace", "iss": "nrc-tailscale-proxy", "aud": "nrc-publish-agent", "nbf": time.Now().Unix() - 2, "exp": time.Now().Unix() + 300}
}

func TestProxyAssertionScope(t *testing.T) {
	a := testApp(t)
	a.cfg.JWTSecret, a.cfg.JWTIssuer, a.cfg.Workspace = "fixture-signing-secret-not-production", "nrc-tailscale-proxy", "test-workspace"
	if got := a.proxyIdentity(testProxyAssertion(a.cfg.JWTSecret, testProxyClaims())); got != "tag:amp" {
		t.Fatalf("identity: %q", got)
	}
	for key, value := range map[string]any{"workspace": "other", "aud": "nrc", "iss": "other", "sub": "", "exp": time.Now().Unix() - 1, "nbf": time.Now().Unix() + 60} {
		claims := testProxyClaims()
		claims[key] = value
		if a.proxyIdentity(testProxyAssertion(a.cfg.JWTSecret, claims)) != "" {
			t.Fatalf("accepted invalid %s", key)
		}
	}
	if a.proxyIdentity(testProxyAssertion("wrong-key", testProxyClaims())) != "" {
		t.Fatal("forged signature accepted")
	}
}
