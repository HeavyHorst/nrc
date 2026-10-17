package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"html"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func hash(s string) string { v := sha256.Sum256([]byte(s)); return hex.EncodeToString(v[:]) }
func (a *app) unsubscribeLink(email string) string {
	payload := base64.RawURLEncoding.EncodeToString([]byte("unsubscribe\n" + email))
	m := hmac.New(sha256.New, []byte(a.s.Key))
	m.Write([]byte(payload))
	return a.cfg.PublicURL + "/unsubscribe?token=" + payload + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
func (a *app) unsubscribeEmail(token string) string {
	p := strings.Split(token, ".")
	if len(p) != 2 || len(token) > 2048 {
		return ""
	}
	sig, e := base64.RawURLEncoding.DecodeString(p[1])
	if e != nil {
		return ""
	}
	m := hmac.New(sha256.New, []byte(a.s.Key))
	m.Write([]byte(p[0]))
	if !hmac.Equal(sig, m.Sum(nil)) {
		return ""
	}
	b, e := base64.RawURLEncoding.DecodeString(p[0])
	if e != nil || !strings.HasPrefix(string(b), "unsubscribe\n") {
		return ""
	}
	return strings.TrimPrefix(string(b), "unsubscribe\n")
}
func (a *app) optout(email, status string) {
	c := a.s.Consent[email]
	if c == nil {
		c = &consent{}
		a.s.Consent[email] = c
	}
	if c.Status != "blocked" {
		c.Status = status
	}
	c.ImportSuppressed = true
	c.TokenHash = ""
	c.Expires = 0
}
func (a *app) subscriberAction(w http.ResponseWriter, r *http.Request, id, action string) {
	var input struct {
		Source string `json:"source"`
	}
	if !decode(w, r, &input) {
		return
	}
	if action != "invite" && action != "unsubscribe" {
		fail(w, 404, "not found")
		return
	}
	contacts, e := a.source.contacts(r.Context())
	if e != nil {
		fail(w, 503, "contact register unavailable")
		return
	}
	var ct contact
	for _, v := range contacts {
		if v.ID == id {
			ct = v
			break
		}
	}
	ct.Email = normalize(ct.Email)
	if ct.ID == "" || !validEmail(ct.Email) {
		fail(w, 400, "contact with valid email required")
		return
	}
	a.s.mu.Lock()
	defer a.s.mu.Unlock()
	if action == "unsubscribe" {
		a.optout(ct.Email, "unsubscribed")
		a.s.mustSave()
		reply(w, 200, map[string]string{"status": a.status(ct.Email)})
		return
	}
	if strings.TrimSpace(input.Source) == "" || len(input.Source) > 1000 || !a.configured() {
		fail(w, 400, "individual request evidence source and sending configuration required")
		return
	}
	c := a.s.Consent[ct.Email]
	if c != nil && (c.Status == "blocked" || c.Status == "subscribed") {
		fail(w, 409, "address already subscribed or suppressed")
		return
	}
	if c != nil && time.Now().Unix()-c.Invited < 3600 {
		fail(w, 429, "invitation cooldown is one hour")
		return
	}
	// Also bound aggregate invitation volume. Never expose a bulk-invite endpoint.
	recent := 0
	for _, v := range a.s.Consent {
		if time.Now().Unix()-v.Invited < 3600 {
			recent++
		}
	}
	if recent >= 20 {
		fail(w, 429, "hourly individual invitation limit reached")
		return
	}
	token := random()
	a.s.Consent[ct.Email] = &consent{Status: "pending", Source: input.Source, TokenHash: hash(token), Expires: time.Now().Add(48 * time.Hour).Unix(), Invited: time.Now().Unix()}
	if c != nil {
		a.s.Consent[ct.Email].Imported = c.Imported
		a.s.Consent[ct.Email].ImportSuppressed = c.ImportSuppressed || c.Status == "unsubscribed"
	}
	a.s.Known[ct.Email] = true
	a.s.mustSave()
	link := a.cfg.PublicURL + "/confirm?token=" + url.QueryEscape(token)
	t := templateInfo{HTML: `<p>Sie haben den Newsletter angefordert. Bitte bestätigen Sie Ihre Anmeldung nur, wenn diese Anfrage von Ihnen stammt:</p><p><a href="` + html.EscapeString(link) + `">Newsletter-Anmeldung bestätigen</a></p>`, Text: "Bitte bestätigen Sie Ihre angeforderte Newsletter-Anmeldung: " + link}
	status := a.mail(r.Context(), ct.Email, ct.Name, "Bitte bestätigen Sie Ihre Newsletter-Anmeldung", t, map[string]any{}, a.unsubscribeLink(ct.Email))
	if e := providerError(status); e != nil {
		fail(w, 502, e.Error())
		return
	}
	reply(w, 200, map[string]string{"status": "pending"})
}
func (a *app) publicHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; form-action 'self'; frame-ancestors 'none'")
		if r.URL.Path == "/events" {
			a.events(w, r)
			return
		}
		if r.URL.Path != "/confirm" && r.URL.Path != "/unsubscribe" {
			fail(w, 404, "not found")
			return
		}
		if r.Method != "GET" && r.Method != "POST" {
			fail(w, 405, "method not allowed")
			return
		}
		token := r.URL.Query().Get("token")
		if token == "" || len(token) > 2048 {
			fail(w, 400, "invalid token")
			return
		}
		a.s.mu.Lock()
		defer a.s.mu.Unlock()
		email := ""
		if r.URL.Path == "/unsubscribe" {
			email = a.unsubscribeEmail(token)
		} else {
			for addr, c := range a.s.Consent {
				if c.TokenHash == hash(token) && c.Status == "pending" && c.Expires > time.Now().Unix() {
					email = addr
					break
				}
			}
		}
		if email == "" {
			fail(w, 400, "invalid or expired token")
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if r.Method == "GET" {
			w.Write([]byte(`<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Newsletter-Einstellungen</title><h1>Newsletter-Einstellungen</h1><p>` + html.EscapeString(email) + `</p><p>Erst mit dem folgenden Button wird Ihre Auswahl gespeichert.</p><form method="post"><button type="submit">` + map[bool]string{true: "Anmeldung bestätigen", false: "Newsletter abmelden"}[r.URL.Path == "/confirm"] + `</button></form></html>`))
			return
		}
		if r.URL.Path == "/unsubscribe" {
			a.optout(email, "unsubscribed")
		} else {
			c := a.s.Consent[email]
			c.Status = "subscribed"
			c.ConfirmedAt = now()
			c.TokenHash = ""
			c.Expires = 0
		}
		a.s.mustSave()
		w.Write([]byte(`<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Newsletter-Einstellungen gespeichert</title><h1>Einstellungen gespeichert</h1><p>Ihre Auswahl für ` + html.EscapeString(email) + ` wurde gespeichert.</p></html>`))
	})
}
func (a *app) events(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	secret := ""
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		secret = strings.TrimPrefix(h, "Bearer ")
	}
	if _, pass, ok := r.BasicAuth(); ok {
		secret = pass
	}
	if a.cfg.EventSecret == "" || !hmac.Equal([]byte(secret), []byte(a.cfg.EventSecret)) {
		fail(w, 401, "event authentication required")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
	var raw json.RawMessage
	d := json.NewDecoder(r.Body)
	if d.Decode(&raw) != nil || d.Decode(new(any)) != io.EOF {
		fail(w, 400, "invalid events")
		return
	}
	type event struct {
		Event string `json:"event"`
		Email string `json:"email"`
		Hard  bool   `json:"hard_bounce"`
	}
	var events []event
	if len(raw) > 0 && raw[0] == '[' {
		if json.Unmarshal(raw, &events) != nil {
			fail(w, 400, "invalid events")
			return
		}
	} else {
		var v event
		if json.Unmarshal(raw, &v) != nil {
			fail(w, 400, "invalid event")
			return
		}
		events = []event{v}
	}
	if len(events) > 1000 {
		fail(w, 400, "too many events")
		return
	}
	a.s.mu.Lock()
	defer a.s.mu.Unlock()
	for _, v := range events {
		email := normalize(v.Email)
		if !a.s.Known[email] {
			continue
		}
		switch {
		case v.Event == "spam" || (v.Event == "bounce" && v.Hard):
			a.optout(email, "blocked")
		case v.Event == "unsub":
			a.optout(email, "unsubscribed")
		}
	}
	a.s.mustSave()
	reply(w, 200, map[string]bool{"ok": true})
}
