package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

type aiIdentity struct {
	Subject   string `json:"sub"`
	Issuer    string `json:"iss"`
	Audience  string `json:"aud"`
	Workspace string `json:"workspace"`
	NotBefore int64  `json:"nbf"`
	ExpiresAt int64  `json:"exp"`
}

type aiIdentityKey struct{}

var aiWorkspacePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
var aiSubjectPattern = regexp.MustCompile(`^tailscale:user:[1-9][0-9]*$`)

func (i aiIdentity) owner() string { return i.Issuer + "/" + i.Subject }

func requireAIIdentity(w http.ResponseWriter, r *http.Request, workspace string) (aiIdentity, bool) {
	i, ok := r.Context().Value(aiIdentityKey{}).(aiIdentity)
	if !ok || i.ExpiresAt <= time.Now().Unix() {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return aiIdentity{}, false
	}
	if workspace != i.Workspace {
		http.Error(w, "workspace access denied", http.StatusForbidden)
		return aiIdentity{}, false
	}
	return i, true
}

// The assertion is created only after the proxy authenticates a human account
// and authorizes the request workspace. Raw identity headers are not trusted.
func newAIAuthentication(key, issuer string) (func(http.Handler) http.Handler, error) {
	if len(key) < 32 || key == "dev-insecure-nrc-jwt-secret" || strings.TrimSpace(issuer) == "" {
		return nil, errors.New("AI authentication requires NRC_JWT_SECRET (at least 32 bytes) and an issuer")
	}
	verify := func(token string) (aiIdentity, bool) {
		var identity aiIdentity
		parts := strings.Split(token, ".")
		if len(token) > 8192 || len(parts) != 3 {
			return identity, false
		}
		headerBytes, err := base64.RawURLEncoding.Strict().DecodeString(parts[0])
		if err != nil {
			return identity, false
		}
		var header struct {
			Alg string `json:"alg"`
			Typ string `json:"typ"`
		}
		decoder := json.NewDecoder(bytes.NewReader(headerBytes))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&header) != nil || decoder.Decode(new(any)) != io.EOF || header.Alg != "HS256" || header.Typ != "JWT" {
			return identity, false
		}
		mac := hmac.New(sha256.New, []byte(key))
		mac.Write([]byte(parts[0] + "." + parts[1]))
		signature, err := base64.RawURLEncoding.Strict().DecodeString(parts[2])
		if err != nil || !hmac.Equal(signature, mac.Sum(nil)) {
			return identity, false
		}
		payload, err := base64.RawURLEncoding.Strict().DecodeString(parts[1])
		if err != nil || json.Unmarshal(payload, &identity) != nil {
			return identity, false
		}
		now := time.Now().Unix()
		valid := identity.Issuer == issuer && identity.Audience == "nrc-ai" &&
			aiSubjectPattern.MatchString(identity.Subject) && aiWorkspacePattern.MatchString(identity.Workspace) &&
			identity.NotBefore > 0 && identity.NotBefore <= now && identity.ExpiresAt > now && identity.ExpiresAt > identity.NotBefore
		return identity, valid
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/ask" && !strings.HasPrefix(r.URL.Path, "/ask/") && !strings.HasPrefix(r.URL.Path, "/voice/") {
				next.ServeHTTP(w, r)
				return
			}
			w.Header().Set("Cache-Control", "no-store")
			tokens := r.Header.Values("X-NRC-AI-Auth")
			if len(tokens) != 1 {
				http.Error(w, "authentication required", http.StatusUnauthorized)
				return
			}
			identity, ok := verify(tokens[0])
			if !ok {
				http.Error(w, "authentication required", http.StatusUnauthorized)
				return
			}
			workspace := ""
			if r.Method == http.MethodGet {
				values := r.URL.Query()["workspace"]
				if len(values) == 1 {
					workspace = values[0]
				}
			} else {
				body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 2<<20))
				var scope struct {
					Workspace string `json:"workspace"`
				}
				if err != nil || json.Unmarshal(body, &scope) != nil {
					http.Error(w, "invalid request body", http.StatusBadRequest)
					return
				}
				workspace = scope.Workspace
				r.Body = io.NopCloser(bytes.NewReader(body))
			}
			if workspace != identity.Workspace {
				http.Error(w, "workspace access denied", http.StatusForbidden)
				return
			}
			ctx, cancel := context.WithDeadline(context.WithValue(r.Context(), aiIdentityKey{}, identity), time.Unix(identity.ExpiresAt, 0))
			defer cancel()
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}, nil
}
