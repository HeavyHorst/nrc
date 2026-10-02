package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"
)

// These assertions are infrastructure credentials, never exposed to CLI callers.
// A normal NRC/WebSocket JWT has a different audience and cannot authorize this API.
func (a *app) proxyIdentity(token string) string {
	if a.cfg.JWTSecret == "" || a.cfg.JWTSecret == "dev-insecure-nrc-jwt-secret" || len(token) > 8192 {
		return ""
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ""
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return ""
	}
	mac := hmac.New(sha256.New, []byte(a.cfg.JWTSecret))
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return ""
	}
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return ""
	}
	var h struct{ Alg, Typ string }
	if json.Unmarshal(header, &h) != nil || h.Alg != "HS256" || h.Typ != "JWT" {
		return ""
	}
	body, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Sub, Workspace, Iss, Aud string
		Exp, Nbf                 int64
	}
	if json.Unmarshal(body, &claims) != nil {
		return ""
	}
	now := time.Now().Unix()
	if claims.Sub == "" || claims.Workspace != a.cfg.Workspace || claims.Iss != a.cfg.JWTIssuer || claims.Aud != "nrc-publish-agent" || claims.Exp <= now || claims.Nbf > now {
		return ""
	}
	return claims.Sub
}
