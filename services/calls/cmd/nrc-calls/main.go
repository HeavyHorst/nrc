package main

import (
	"log"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/heavyhorst/nrc/services/calls"
)

func env(k, v string) string {
	if s := os.Getenv(k); s != "" {
		return s
	}
	return v
}
func main() {
	secret := os.Getenv("NRC_JWT_SECRET")
	if len(secret) < 32 || secret == "dev-insecure-nrc-jwt-secret" {
		log.Fatal("nondefault >=32-byte NRC_JWT_SECRET required")
	}
	issuer := env("NRC_JWT_ISSUER", "nrc-tailscale-proxy")
	p, e := calls.NewJitsi(os.Getenv("JITSI_URL"), os.Getenv("JITSI_APP_ID"), os.Getenv("JITSI_SECRET"))
	if e != nil {
		log.Fatal(e)
	}
	upstream := env("NRC_SERVER", "ws://server:8080")
	u, e := url.Parse(upstream)
	if e != nil || (u.Scheme != "ws" && u.Scheme != "wss") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		log.Fatal("NRC_SERVER must be a ws/wss origin")
	}
	s := calls.NewServer(p, calls.NRCAuthorizer{Server: upstream, Secret: secret, Issuer: issuer, Audience: env("NRC_JWT_AUDIENCE", "nrc")}, secret, issuer)
	s.Meetings, e = calls.NewScheduledMeetings(env("CALLS_DATA_DIR", "data/calls"))
	if e != nil {
		log.Fatal(e)
	}
	h := &http.Server{Addr: env("CALLS_LISTEN", ":8090"), Handler: s, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	log.Fatal(h.ListenAndServe())
}
