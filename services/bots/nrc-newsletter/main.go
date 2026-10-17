package main

import (
	"context"
	"log"
	"net/http"
	"net/mail"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type config struct {
	Workspace, JWTSecret, JWTIssuer, PublicURL, FromEmail, FromName, ReplyTo, EventSecret string
	SearchURL                                                                             string
	TemplateIDs                                                                           []string
}
type app struct {
	cfg      config
	s        *store
	source   source
	provider provider
}

func normalize(s string) string { return strings.ToLower(strings.TrimSpace(s)) }
func validEmail(s string) bool {
	a, e := mail.ParseAddress(s)
	return e == nil && a.Address == s && !strings.ContainsAny(s, "\r\n") && len(s) <= 254
}
func (a *app) configured() bool {
	u, e := url.Parse(a.cfg.PublicURL)
	return e == nil && u.Scheme == "https" && u.Host != "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && a.provider.key != "" && a.provider.secret != "" && validEmail(a.cfg.FromEmail) && validEmail(a.cfg.ReplyTo) && len(a.cfg.TemplateIDs) > 0
}
func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func main() {
	cfg := config{Workspace: os.Getenv("NRC_WORKSPACE"), JWTSecret: os.Getenv("NRC_JWT_SECRET"), JWTIssuer: env("NRC_JWT_ISSUER", "nrc-tailscale-proxy"), PublicURL: strings.TrimRight(os.Getenv("NEWSLETTER_PUBLIC_URL"), "/"), FromEmail: os.Getenv("NEWSLETTER_FROM_EMAIL"), FromName: os.Getenv("NEWSLETTER_FROM_NAME"), ReplyTo: os.Getenv("NEWSLETTER_REPLY_TO"), EventSecret: os.Getenv("NEWSLETTER_EVENT_SECRET"), TemplateIDs: []string{}}
	cfg.SearchURL = env("NEWSLETTER_SEARCH_URL", "http://search:8090/search")
	for _, id := range strings.Split(os.Getenv("NEWSLETTER_TEMPLATE_IDS"), ",") {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		n, e := strconv.ParseUint(id, 10, 64)
		if e != nil || n == 0 {
			log.Fatal("invalid approved template ID")
		}
		cfg.TemplateIDs = append(cfg.TemplateIDs, id)
	}
	if cfg.Workspace == "" || cfg.JWTSecret == "" || cfg.JWTSecret == "dev-insecure-nrc-jwt-secret" || os.Getenv("NRC_BOT_SECRET") == "" || os.Getenv("NRC_SERVER") == "" {
		log.Fatal("NRC workspace, secure JWT secret, bot secret and server required")
	}
	dir := env("NEWSLETTER_DATA_DIR", "/data")
	if e := os.MkdirAll(dir, 0700); e != nil {
		log.Fatal("cannot create data directory")
	}
	s, e := openStore(filepath.Join(dir, "newsletter.db"), cfg.Workspace)
	if e != nil {
		log.Fatal("cannot open durable newsletter state")
	}
	defer s.db.Close()
	a := &app{cfg: cfg, s: s, source: nrcSource{os.Getenv("NRC_SERVER"), cfg.Workspace, os.Getenv("NRC_BOT_SECRET")}, provider: provider{client: &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, base: "https://api.mailjet.com", key: os.Getenv("MAILJET_API_KEY"), secret: os.Getenv("MAILJET_SECRET_KEY")}}
	go a.worker(context.Background())
	serve := func(addr string, h http.Handler) {
		srv := &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 25 * time.Second, WriteTimeout: 120 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
		if e := srv.ListenAndServe(); e != nil {
			log.Fatal("newsletter listener stopped")
		}
	}
	go serve(env("NEWSLETTER_PUBLIC_ADDR", ":8097"), a.publicHandler())
	serve(env("NEWSLETTER_ADMIN_ADDR", ":8096"), a.adminHandler())
}
