package main

import (
	"context"
	"errors"
	"net/http"
	"net/smtp"
	"net/url"
	"strings"
	"sync"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/clientcredentials"
)

// App-only OAuth works without a browser session or stored refresh token. The
// protected configuration, not a mail sender, owns the token endpoint.
type mailOAuthConfig struct {
	TokenURL     string   `json:"token_url"`
	ClientID     string   `json:"client_id"`
	ClientSecret string   `json:"client_secret"`
	Scopes       []string `json:"scopes"`
	mu           sync.Mutex
	cached       *oauth2.Token
}

func (c *mailOAuthConfig) validate() error {
	if c == nil {
		return nil
	}
	u, err := url.Parse(c.TokenURL)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" || u.RawQuery != "" || c.ClientID == "" || c.ClientSecret == "" || len(c.Scopes) == 0 {
		return errors.New("OAuth requires HTTPS token endpoint, client credentials and scopes")
	}
	return nil
}

func (c *mailOAuthConfig) token(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached.Valid() {
		return c.cached.AccessToken, nil
	}
	if ctx.Value(oauth2.HTTPClient) == nil {
		ctx = context.WithValue(ctx, oauth2.HTTPClient, &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }})
	}
	config := clientcredentials.Config{ClientID: c.ClientID, ClientSecret: c.ClientSecret, TokenURL: c.TokenURL, Scopes: c.Scopes, AuthStyle: oauth2.AuthStyleInParams}
	token, err := config.Token(ctx)
	if err != nil {
		return "", errors.New("OAuth token acquisition failed")
	}
	if token.AccessToken == "" || !safeMailHeader(token.AccessToken) || strings.ContainsAny(token.AccessToken, " \t") || !strings.EqualFold(token.Type(), "Bearer") || token.Expiry.IsZero() || !token.Valid() {
		return "", errors.New("OAuth returned invalid bearer token or expiry")
	}
	c.cached = token
	return token.AccessToken, nil
}

type mailXOAUTH2 struct{ user, token string }

func (a mailXOAUTH2) Start() (string, []byte, error) {
	if !safeMailHeader(a.user) || !safeMailHeader(a.token) {
		return "", nil, errors.New("invalid OAuth credentials")
	}
	return "XOAUTH2", []byte("user=" + a.user + "\x01auth=Bearer " + a.token + "\x01\x01"), nil
}
func (a mailXOAUTH2) Next([]byte) ([]byte, error) { return []byte{}, nil }

type mailSMTPAuth struct{ mailXOAUTH2 }

func (a mailSMTPAuth) Start(server *smtp.ServerInfo) (string, []byte, error) {
	if !server.TLS {
		return "", nil, errors.New("OAuth requires TLS")
	}
	return a.mailXOAUTH2.Start()
}
func (a mailSMTPAuth) Next(challenge []byte, more bool) ([]byte, error) {
	if more {
		return a.mailXOAUTH2.Next(challenge)
	}
	return nil, nil
}
