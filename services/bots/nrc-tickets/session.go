package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"html/template"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
)

const (
	accountCookie      = "__Host-nrc-ticket-session"
	accountSessionTTL  = 8 * time.Hour
	maxAccountSessions = 4096
)

type accountSession struct {
	login, id, revision string
	password            [sha256.Size]byte
	expires             time.Time
}

type accountSessions struct {
	mu     sync.Mutex
	active map[string]accountSession
}

func (s *accountSessions) lookup(token string) (accountSession, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.active[token]
	if ok && !time.Now().Before(v.expires) {
		delete(s.active, token)
		return accountSession{}, false
	}
	return v, ok
}

func (s *accountSessions) revoke(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.active, token)
}

func (s *accountSessions) start(a account, previous string) (*http.Cookie, bool) {
	token := rand.Text()
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.active, previous)
	for k, v := range s.active {
		if !now.Before(v.expires) {
			delete(s.active, k)
		}
	}
	if len(s.active) >= maxAccountSessions {
		return nil, false
	}
	if s.active == nil {
		s.active = make(map[string]accountSession)
	}
	expires := now.Add(accountSessionTTL)
	s.active[token] = accountSession{a.Login, a.PortalID, a.PortalRevision, sha256.Sum256([]byte(a.PasswordHash)), expires}
	c := accountSessionCookie(token)
	c.Expires = expires
	c.MaxAge = int(accountSessionTTL.Seconds())
	return c, true
}

func accountSessionCookie(token string) *http.Cookie {
	return &http.Cookie{Name: accountCookie, Value: token, Path: "/", HttpOnly: true, Secure: true, SameSite: http.SameSiteLaxMode}
}

func accountSessionToken(r *http.Request) string {
	c, err := r.Cookie(accountCookie)
	if err != nil {
		return ""
	}
	return c.Value
}

func (s *portal) endSession(w http.ResponseWriter, r *http.Request) {
	s.sessions.revoke(accountSessionToken(r))
	cookie := accountSessionCookie("")
	cookie.MaxAge = -1
	http.SetCookie(w, cookie)
}

func (s *portal) verifyPassword(ctx context.Context, login, password string) (account, bool, error) {
	if s.accounts == nil || !validAccountLogin(login) || len(password) == 0 || len(password) > 72 {
		return account{}, false, nil
	}
	a, found, err := s.accounts.login(ctx, login)
	if err != nil || !found || a.Disabled || bcrypt.CompareHashAndPassword([]byte(a.PasswordHash), []byte(password)) != nil {
		return account{}, false, err
	}
	return a, true, nil
}

func (s *portal) loggedIn(r *http.Request, api, attachment bool) (account, bool, error) {
	// API clients follow attachment URLs outside /api. On those URLs a browser
	// presenting a session cookie must use it, even if the cookie is stale.
	if api || (attachment && accountSessionToken(r) == "") {
		if login, password, ok := r.BasicAuth(); ok {
			a, found, err := s.verifyPassword(r.Context(), login, password)
			a.PasswordHash = ""
			return a, found, err
		}
	}
	token := accountSessionToken(r)
	v, ok := s.sessions.lookup(token)
	if !ok || s.accounts == nil {
		return account{}, false, nil
	}
	a, found, err := s.accounts.login(r.Context(), v.login)
	if err != nil {
		return account{}, false, err
	}
	if !found || a.Disabled || a.PortalID != v.id || a.PortalRevision != v.revision || sha256.Sum256([]byte(a.PasswordHash)) != v.password {
		s.sessions.revoke(token)
		return account{}, false, nil
	}
	a.PasswordHash = ""
	return a, true, nil
}

type passwordAccountStore interface {
	changePassword(context.Context, account, string) error
}

func (s *portal) passwordPage(w http.ResponseWriter, r *http.Request, who account) {
	store, ok := s.accounts.(passwordAccountStore)
	if !ok {
		http.NotFound(w, r)
		return
	}
	show := func(status int, message string) {
		s.render(w, false, view{Password: true, PasswordError: message, Status: status})
	}
	if r.Method == http.MethodGet {
		show(http.StatusOK, "")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if err := r.ParseForm(); err != nil {
		show(http.StatusBadRequest, "Das Formular konnte nicht verarbeitet werden.")
		return
	}
	current, password := r.PostForm.Get("current"), r.PostForm.Get("new")
	if len(password) < 14 || len(password) > 72 || !utf8.ValidString(password) || strings.ContainsFunc(password, unicode.IsControl) {
		show(http.StatusBadRequest, "Das neue Passwort muss 14 bis 72 Bytes lang sein und darf keine Steuerzeichen enthalten.")
		return
	}
	if password != r.PostForm.Get("repeat") || password == current {
		show(http.StatusBadRequest, "Wählen Sie ein anderes Passwort und wiederholen Sie es exakt.")
		return
	}
	checked, valid, err := s.verifyPassword(r.Context(), who.Login, current)
	if err != nil {
		show(http.StatusServiceUnavailable, "Die Passwortprüfung ist vorübergehend nicht verfügbar.")
		return
	}
	if !valid {
		show(http.StatusBadRequest, "Das aktuelle Passwort ist falsch.")
		return
	}
	if checked.PortalID != who.PortalID || checked.PortalRevision != who.PortalRevision || checked.Requester != who.Requester {
		s.endSession(w, r)
		http.Redirect(w, r, "/login?unsaved=1&next=%2Fkonto%2Fpasswort", http.StatusSeeOther)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), 12)
	if err != nil {
		show(http.StatusServiceUnavailable, "Das Passwort konnte nicht geändert werden.")
		return
	}
	switch store.changePassword(r.Context(), who, string(hash)) {
	case nil:
		s.endSession(w, r)
		http.Redirect(w, r, "/login?password_changed=1", http.StatusSeeOther)
	case errAccountChanged:
		s.endSession(w, r)
		http.Redirect(w, r, "/login?unsaved=1&next=%2Fkonto%2Fpasswort", http.StatusSeeOther)
	default:
		show(http.StatusServiceUnavailable, "Die Änderung konnte nicht bestätigt werden. Prüfen Sie bei der nächsten Anmeldung, welches Passwort gilt.")
	}
}

func loginDestination(target string) string {
	if len(target) > 2048 || !strings.HasPrefix(target, "/") {
		return "/"
	}
	u, err := url.ParseRequestURI(target)
	if err != nil || u.IsAbs() || u.Host != "" || strings.HasPrefix(u.Path, "//") || strings.ContainsAny(u.Path, "\\\r\n\t") || u.Path == "/login" || u.Path == "/logout" {
		return "/"
	}
	return target
}

// A rejected POST is never retried. Return to the associated GET form without
// reading the original body (which may contain a draft or large attachments).
func formReturnPath(path string) string {
	if path == "/tickets" {
		return "/new"
	}
	if path == "/konto/passwort" {
		return path
	}
	parts := strings.Split(path, "/")
	if len(parts) == 4 && parts[2] != "" && decimal(parts[2]) {
		if (parts[1] == "tickets" && parts[3] == "reply") ||
			(parts[1] == "abnahmen" && (parts[3] == "answer" || parts[3] == "preview" || parts[3] == "close")) {
			return "/" + parts[1] + "/" + parts[2]
		}
	}
	return ""
}

//go:embed web/login.html
var loginHTML string
var loginPage = template.Must(template.New("login").Parse(loginHTML))

func (s *portal) renderLogin(w http.ResponseWriter, status int, target, message string, unsaved bool) {
	b := s.brand
	if b.Brand == "" {
		b.Brand = "Ihr Kundenportal"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_ = loginPage.Execute(w, struct {
		Branding         branding
		Next, Message    string
		Unsaved, Success bool
	}{b, loginDestination(target), message, unsaved, status == http.StatusOK})
}

func (s *portal) login(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		q := r.URL.Query()
		message := ""
		if q.Get("password_changed") == "1" {
			message = "Passwort geändert. Melden Sie sich mit dem neuen Passwort an."
		}
		s.renderLogin(w, http.StatusOK, q.Get("next"), message, q.Get("unsaved") == "1")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if err := r.ParseForm(); err != nil {
		s.renderLogin(w, http.StatusBadRequest, "/", "Die Anmeldung konnte nicht verarbeitet werden.", false)
		return
	}
	next := loginDestination(r.PostForm.Get("next"))
	unsaved := r.PostForm.Get("unsaved") == "1"
	a, valid, err := s.verifyPassword(r.Context(), r.PostForm.Get("login"), r.PostForm.Get("password"))
	if err != nil {
		s.renderLogin(w, http.StatusServiceUnavailable, next, "Die Anmeldung ist vorübergehend nicht verfügbar.", unsaved)
		return
	}
	if !valid {
		s.renderLogin(w, http.StatusUnauthorized, next, "Benutzername oder Passwort ist falsch.", unsaved)
		return
	}
	cookie, ok := s.sessions.start(a, accountSessionToken(r))
	if !ok {
		s.renderLogin(w, http.StatusServiceUnavailable, next, "Die Anmeldung ist vorübergehend nicht verfügbar.", unsaved)
		return
	}
	http.SetCookie(w, cookie)
	http.Redirect(w, r, next, http.StatusSeeOther)
}
