package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/oauth2"
)

func TestMailOAuthRefreshAndFailure(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		if r.Method != "POST" {
			t.Error("token request must be POST")
		}
		r.ParseForm()
		if r.Form.Get("grant_type") != "client_credentials" || r.Form.Get("client_id") != "nrc" || r.Form.Get("client_secret") != "fixture-secret" || r.Form.Get("scope") != "mail" {
			t.Error("wrong OAuth request")
		}
		w.Header().Set("Content-Type", "application/json")
		if call >= 3 {
			w.WriteHeader(401)
			fmt.Fprint(w, `{"error":"invalid_client","error_description":"fixture-secret must not escape"}`)
			return
		}
		fmt.Fprintf(w, `{"access_token":"fixture-token-%d","token_type":"Bearer","expires_in":3600}`, call)
	}))
	defer server.Close()
	c := &mailOAuthConfig{TokenURL: server.URL, ClientID: "nrc", ClientSecret: "fixture-secret", Scopes: []string{"mail"}}
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	ctx := context.WithValue(context.Background(), oauth2.HTTPClient, server.Client())
	for i := 0; i < 2; i++ {
		token, err := c.token(ctx)
		if err != nil || token != "fixture-token-1" {
			t.Fatal("wrong cached token", err)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("token not reused")
	}
	c.cached.Expiry = time.Now().Add(-time.Second)
	if token, err := c.token(ctx); err != nil || token != "fixture-token-2" {
		t.Fatal("expired token not renewed", err)
	}
	c.cached.Expiry = time.Now().Add(-time.Second)
	if token, err := c.token(ctx); err == nil || token != "" || strings.Contains(err.Error(), "fixture-secret") {
		t.Fatal("OAuth failure leaked provider response or fell back")
	}
	c.TokenURL = "http://example.test/token"
	if c.validate() == nil {
		t.Fatal("accepted insecure token endpoint")
	}
}

func TestIMAPConfigurationRejectsAmbiguousCredentials(t *testing.T) {
	for _, config := range []*mailIMAPConfig{
		{Address: "imap.test:993", Username: "support@test"},
		{Address: "imap.test:993", Username: "support@test", Password: "password", OAuth2: &mailOAuthConfig{}},
		{Address: "imap.test:993", Username: "support@test\x01auth=Bearer injected", Password: "password"},
	} {
		if config.validate() == nil {
			t.Fatal("accepted invalid IMAP configuration")
		}
	}
	valid := &mailIMAPConfig{Address: "imap.test:993", Username: "support@test", Password: "password"}
	if err := valid.validate(); err != nil || valid.Mailbox != "INBOX" {
		t.Fatal("valid password config rejected", err)
	}
}
