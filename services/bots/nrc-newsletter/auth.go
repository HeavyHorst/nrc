package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"
)

func (a *app) authorized(token string) bool {
	if a.cfg.JWTSecret == "" || a.cfg.JWTSecret == "dev-insecure-nrc-jwt-secret" || len(token) > 8192 {
		return false
	}
	p := strings.Split(token, ".")
	if len(p) != 3 {
		return false
	}
	sig, e := base64.RawURLEncoding.DecodeString(p[2])
	if e != nil {
		return false
	}
	m := hmac.New(sha256.New, []byte(a.cfg.JWTSecret))
	m.Write([]byte(p[0] + "." + p[1]))
	if !hmac.Equal(sig, m.Sum(nil)) {
		return false
	}
	h, e := base64.RawURLEncoding.DecodeString(p[0])
	if e != nil {
		return false
	}
	var header struct{ Alg, Typ string }
	if json.Unmarshal(h, &header) != nil || header.Alg != "HS256" || header.Typ != "JWT" {
		return false
	}
	b, e := base64.RawURLEncoding.DecodeString(p[1])
	if e != nil {
		return false
	}
	var c struct {
		Sub, Workspace, Iss, Aud string
		Exp, Nbf                 int64
	}
	if json.Unmarshal(b, &c) != nil {
		return false
	}
	return c.Sub != "" && c.Workspace == a.cfg.Workspace && c.Iss == a.cfg.JWTIssuer && c.Aud == "nrc-newsletter" && c.Exp > time.Now().Unix() && c.Nbf <= time.Now().Unix()
}
