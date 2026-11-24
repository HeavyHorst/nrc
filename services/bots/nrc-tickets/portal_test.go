package main

import (
	"context"
	"encoding/json"
	"errors"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
	"golang.org/x/crypto/bcrypt"
)

func TestPublicHealth(t *testing.T) {
	s := &portal{}
	for _, path := range []string{"/health", "/health/private", "/"} {
		w := httptest.NewRecorder()
		s.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if path == "/health" {
			if w.Code != 200 || w.Body.String() != "{\"status\":\"ok\"}\n" || w.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("health: %d %s", w.Code, w.Body.String())
			}
		} else if w.Code != 303 || w.Header().Get("WWW-Authenticate") != "" {
			t.Fatalf("unauthenticated portal access: %d", w.Code)
		}
	}
}

func TestStaffSchedulingIsPrivate(t *testing.T) {
	s := &portal{}
	for _, extra := range []string{"", `,"priority":"urgent","follow_up_at":"123"`} {
		a := p.Asset{AssetID: 1, AssetType: ticketType, Preview: `{"version":1,"title":"Help","requester":"ada","status":"open"` + extra + `}`, Payload: "original"}
		v, ok, err := s.project(t.Context(), a, account{Requester: "ada"}, nil)
		if !ok || err != nil {
			t.Fatal("optional scheduling broke projection")
		}
		b, err := json.Marshal(v)
		if err != nil || strings.Contains(string(b), "priority") || strings.Contains(string(b), "follow_up") {
			t.Fatalf("private schedule leaked: %s %v", b, err)
		}
	}
}

type fakeSource struct {
	mu     sync.Mutex
	assets map[uint64]p.Asset
	links  []p.Edge
	next   uint64
	writes int
	fail   bool
}

func (f *fakeSource) edges(_ context.Context, company uint64) ([]p.Edge, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		return nil, errors.New("unavailable")
	}
	var out []p.Edge
	for _, e := range f.links {
		if e.SourceID == company || e.TargetID == company {
			out = append(out, e)
		}
	}
	return out, nil
}

func (f *fakeSource) list(_ context.Context, typ uint16) ([]p.Asset, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []p.Asset
	for _, a := range f.assets {
		if a.AssetType == typ {
			out = append(out, a)
		}
	}
	return out, nil
}
func (f *fakeSource) get(_ context.Context, id uint64) (p.Asset, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	a, ok := f.assets[id]
	if !ok {
		return a, errors.New("missing")
	}
	return a, nil
}
func (f *fakeSource) create(_ context.Context, a p.Asset) (p.Asset, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.writes++
	if f.fail {
		return p.Asset{}, errors.New("uncertain")
	}
	f.next++
	a.AssetID = f.next
	if a.CreatedAt == 0 {
		a.CreatedAt = time.Date(2026, 11, 24, 9, 50, 0, 0, time.UTC).UnixNano()
	}
	f.assets[a.AssetID] = a
	return a, nil
}
func fixture(t *testing.T) (*portal, *fakeSource) {
	t.Helper()
	h, e := bcrypt.GenerateFromPassword([]byte("fixture-password-only"), bcrypt.MinCost)
	if e != nil {
		t.Fatal(e)
	}
	f := &fakeSource{assets: map[uint64]p.Asset{}, next: 20}
	add := func(id uint64, requester, title string) {
		v, _ := json.Marshal(ticketPreview{Version: 1, Title: title, CompanyID: "123", Requester: requester, RequesterName: "Kundin", Status: "open", Assignee: "HIDDEN_ASSIGNEE"})
		f.assets[id] = p.Asset{AssetID: id, AssetType: ticketType, Preview: string(v), Payload: "Originalanfrage <script>alert(1)</script>", CreatedAt: time.Date(2026, 7, 3, 21, 48, 12, 0, time.UTC).UnixNano()}
	}
	add(1, "anna@example.test", "Meine Rechnung")
	add(2, "bea@example.test", "PRIVATE_OTHER_TITLE")
	for i, kind := range []string{"public_reply", "internal_note", "customer_reply"} {
		author := "Serviceteam"
		if kind == "customer_reply" {
			author = "Anna"
		}
		v, _ := json.Marshal(entryPreview{1, kind, author})
		body := "Vielen Dank für Ihre Nachricht."
		if kind == "internal_note" {
			body = "HIDDEN_INTERNAL_NOTE"
		}
		id := uint64(10 + i)
		f.assets[id] = p.Asset{AssetID: id, AssetType: entryType, ParentType: 2, ParentID: 1, Preview: string(v), Payload: body, Attachments: []p.Attachment{{Filename: "HIDDEN_FILENAME"}}, CreatedAt: time.Date(2026, 11, 24, 8, 41+i, 15, 0, time.UTC).UnixNano()}
	}
	return &portal{source: f, accounts: fileAccounts{{Login: "anna", PasswordHash: string(h), Requester: "anna@example.test", Name: "Anna", CompanyID: "123"}}, origin: "https://portal.example.test"}, f
}
func call(s *portal, method, path, form, origin, login, password string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(form))
	if login != "" && strings.HasPrefix(path, "/api/") {
		r.SetBasicAuth(login, password)
	} else if login != "" {
		addLoginCookie(s, r)
	}
	if method == "POST" {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func addLoginCookie(s *portal, r *http.Request) {
	w := call(s, "POST", "/login", "login=anna&password=fixture-password-only", s.origin, "", "")
	for _, c := range w.Result().Cookies() {
		r.AddCookie(c)
	}
}
func own(s *portal, method, path, form string) *httptest.ResponseRecorder {
	return call(s, method, path, form, s.origin, "anna", "fixture-password-only")
}

func TestPortalBrowserSession(t *testing.T) {
	s, _ := fixture(t)
	credentials := "login=anna&password=fixture-password-only"
	if w := call(s, "POST", "/login", credentials, "https://evil.test", "", ""); w.Code != 403 || len(w.Result().Cookies()) != 0 {
		t.Fatal("cross-origin login accepted")
	}
	if w := call(s, "POST", "/login", "login=anna&password=wrong", s.origin, "", ""); w.Code != 401 || w.Header().Get("WWW-Authenticate") != "" || len(w.Result().Cookies()) != 0 {
		t.Fatal("failed login must neither challenge nor issue a cookie")
	}
	w := call(s, "POST", "/login", credentials+"&next="+url.QueryEscape("/tickets/1?tab=details"), s.origin, "", "")
	cookies := w.Result().Cookies()
	if w.Code != 303 || w.Header().Get("Location") != "/tickets/1?tab=details" || len(cookies) != 1 {
		t.Fatal("login did not restore the original path and query")
	}
	c := cookies[0]
	if c.Name != accountCookie || c.Domain != "" || c.Path != "/" || !c.Secure || !c.HttpOnly || c.SameSite != http.SameSiteLaxMode || c.MaxAge != 28800 {
		t.Fatal("incorrect session cookie policy")
	}
	for _, target := range []string{"https://evil.test", "//evil.test", "/%2Fevil.test", `/\evil.test`} {
		w := call(s, "POST", "/login", credentials+"&next="+url.QueryEscape(target), s.origin, "", "")
		if w.Code != 303 || w.Header().Get("Location") != "/" {
			t.Fatalf("accepted external return target %q", target)
		}
	}
	request := func(method, path, origin string, cookie *http.Cookie, want int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, nil)
		r.Header.Set("Origin", origin)
		r.SetBasicAuth("anna", "fixture-password-only")
		if cookie != nil {
			r.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Code != want || w.Header().Get("WWW-Authenticate") != "" {
			t.Fatalf("%s %s: got %d, want %d without a challenge", method, path, w.Code, want)
		}
		return w
	}
	request("GET", "/tickets/1", "", nil, 303) // Cached Basic credentials do not log the browser back in.
	request("GET", "/logout", "", c, 405)
	request("POST", "/logout", "https://evil.test", c, 403)
	request("GET", "/tickets/1", "", c, 200)
	out := request("POST", "/logout", s.origin, c, 303).Result().Cookies()
	if len(out) != 1 || out[0].Name != c.Name || out[0].MaxAge >= 0 {
		t.Fatal("logout did not clear the session cookie")
	}
	request("GET", "/tickets/1", "", c, 303) // Even a copied cookie no longer works.
}

func TestLostSessionReturnsToUnsubmittedForm(t *testing.T) {
	s, f := reviewFixture(t)
	login := "login=anna&password=fixture-password-only"
	old := call(s, "POST", "/login", login, s.origin, "", "").Result().Cookies()[0]
	// A restarted portal has the same accounts and records, but no old sessions.
	s = &portal{source: s.source, accounts: s.accounts, origin: s.origin}
	const warning = "Ihre Eingaben wurden nicht gespeichert."
	for path, destination := range map[string]string{
		"/tickets": "/new", "/tickets/1/reply": "/tickets/1",
		"/tickets/1/reply?status=waiting&q=%232&scope=team&sort=oldest&ignored=discard": "/tickets/1?q=%232&scope=team&sort=oldest&status=waiting",
		"/tickets/1/reply?q=" + strings.Repeat("x", 2048):                               "/tickets/1",
		"/abnahmen/71/answer": "/abnahmen/71", "/abnahmen/71/preview": "/abnahmen/71", "/abnahmen/71/close": "/abnahmen/71",
	} {
		r := httptest.NewRequest(http.MethodPost, path, strings.NewReader("body=UNSAVED_DRAFT&comment=UNSAVED_DRAFT"))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", s.origin)
		r.AddCookie(old)
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		location := w.Header().Get("Location")
		if w.Code != 303 || !strings.HasPrefix(location, "/login?") || strings.Contains(location, "UNSAVED_DRAFT") {
			t.Fatalf("%s: expected redirect to login without draft, got %d %q", path, w.Code, location)
		}
		page := call(s, "GET", location, "", "", "", "")
		if page.Code != 200 || !strings.Contains(page.Body.String(), warning) || strings.Contains(page.Body.String(), "UNSAVED_DRAFT") {
			t.Fatalf("%s: missing warning or exposed draft", path)
		}
		form := "&unsaved=1&next=" + url.QueryEscape(destination)
		bad := call(s, "POST", "/login", "login=anna&password=wrong"+form, s.origin, "", "")
		if bad.Code != 401 || !strings.Contains(bad.Body.String(), warning) {
			t.Fatal("unsaved warning lost after failed login")
		}
		fresh := call(s, "POST", "/login", login+form, s.origin, "", "")
		if fresh.Code != 303 || fresh.Header().Get("Location") != destination || !strings.Contains(page.Body.String(), `name="next" value="`+html.EscapeString(destination)+`"`) {
			t.Fatalf("%s: did not return to %s", path, destination)
		}
	}
	if f.writes != 0 || len(f.run.Answers) != 1 || f.run.Decision != "" {
		t.Fatal("unauthenticated submission modified records")
	}
}

func TestTicketCategorySelection(t *testing.T) {
	for _, category := range []string{"", "bug", "support", "feature", "unclear", "invalid", "bug&category=support"} {
		t.Run(category, func(t *testing.T) {
			s, f := fixture(t)
			w := own(s, "POST", "/tickets", "title=Export&body=Hilfe&category="+category)
			if category == "invalid" || strings.Contains(category, "&") {
				if w.Code != 400 || f.writes != 0 {
					t.Fatal("invalid category accepted", w.Code)
				}
				return
			}
			if w.Code != 303 || f.writes != 1 {
				t.Fatal("create failed", w.Code, w.Body)
			}
			var v ticketPreview
			if json.Unmarshal([]byte(f.assets[f.next].Preview), &v) != nil || v.Category != category {
				t.Fatalf("selection lost: %+v", v)
			}
			if category == "unclear" {
				if body := own(s, "GET", w.Header().Get("Location"), "").Body.String(); !strings.Contains(body, "<dt>Kategorie</dt><dd>Unklar</dd>") {
					t.Fatal("manual Unklar not displayed")
				}
			}
		})
	}
}

func TestRequestsOverview(t *testing.T) {
	s, f := fixture(t)
	for _, hasTickets := range []bool{true, false} {
		if !hasTickets {
			delete(f.assets, 1) // The other customer's ticket must not count.
		}
		w := own(s, "GET", "/", "")
		body := w.Body.String()
		if w.Code != 200 || !strings.Contains(body, `href="/" aria-current="page"`) ||
			strings.Contains(body, "<table") != hasTickets ||
			strings.Contains(body, "Noch keine Anfragen") == hasTickets {
			t.Fatalf("unexpected overview with hasTickets=%t: %d %s", hasTickets, w.Code, body)
		}
	}
}

func TestStaffReplyDisplayNames(t *testing.T) {
	s, f := fixture(t)
	for _, tc := range []struct{ author, display, kind string }{
		{"rene.michaelis", "Rene Michaelis", "public_reply"},
		{"özlem.öztürk", "Özlem Öztürk", "public_reply"},
		{"Rene Michaelis", "Rene Michaelis", "public_reply"},
		{"support@example.test", "support@example.test", "public_reply"},
		{"rene.michaelis", "rene.michaelis", "customer_reply"},
	} {
		a := f.assets[10]
		preview, _ := json.Marshal(entryPreview{1, tc.kind, tc.author})
		a.Preview = string(preview)
		f.assets[10] = a
		w := own(s, "GET", "/tickets/1", "")
		if w.Code != 200 || !strings.Contains(w.Body.String(), "<strong>"+tc.display+"</strong>") {
			t.Fatalf("%s %q: expected display name %q, status %d", tc.kind, tc.author, tc.display, w.Code)
		}
		w = own(s, "GET", "/api/tickets/1", "")
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"author":"`+tc.author+`"`) {
			t.Fatalf("API no longer returns original author %q: %d", tc.author, w.Code)
		}
	}
}

func TestTicketMessageCreationTimes(t *testing.T) {
	s, f := fixture(t)
	a := f.assets[12]
	a.UpdatedAt = time.Date(2026, 11, 25, 9, 10, 0, 0, time.UTC).UnixNano()
	f.assets[12] = a
	w := own(s, "GET", "/tickets/1", "")
	for _, want := range []string{
		`datetime="2026-07-03T23:48:12&#43;02:00">03.07.2026, 23:48 Uhr`,
		`datetime="2026-11-24T09:41:15&#43;01:00">24.11.2026, 09:41 Uhr`,
		`datetime="2026-11-24T09:43:15&#43;01:00">24.11.2026, 09:43 Uhr`,
	} {
		if w.Code != 200 || !strings.Contains(w.Body.String(), want) {
			t.Fatalf("ticket detail is missing creation time %q (HTTP %d)", want, w.Code)
		}
	}
	if strings.Count(w.Body.String(), "message-time") != 3 {
		t.Fatal("expected timestamps for the original request and both public replies only")
	}
	a.CreatedAt = 0
	f.assets[12] = a
	if w = own(s, "GET", "/tickets/1", ""); w.Code != 200 || strings.Count(w.Body.String(), "message-time") != 2 {
		t.Fatal("missing timestamps should not render a date")
	}
	if w = own(s, "GET", "/api/tickets/1", ""); w.Code != 200 || strings.Contains(w.Body.String(), "created_at") || strings.Contains(w.Body.String(), "CreatedAt") {
		t.Fatal("HTML timestamps should not change the JSON API")
	}
}

func TestPrivacyAndRendering(t *testing.T) {
	s, f := fixture(t)
	privateEntry := f.assets[11]
	privateEntry.Preview = `{"version":1,"kind":"internal_note","author":"Staff","Kind":"public_reply"}`
	f.assets[11] = privateEntry
	otherTicket := f.assets[2]
	otherTicket.Preview = `{"version":1,"title":"PRIVATE_OTHER_TITLE","requester":"bea@example.test","Requester":"anna@example.test","status":"open"}`
	f.assets[2] = otherTicket
	for _, path := range []string{"/", "/tickets", "/tickets/1", "/new", "/api/tickets", "/api/tickets/1"} {
		w := own(s, "GET", path, "")
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body)
		}
		body := w.Body.String()
		for _, secret := range []string{"HIDDEN_INTERNAL_NOTE", "HIDDEN_ASSIGNEE", "HIDDEN_FILENAME", "PRIVATE_OTHER_TITLE", "company_id", "requester", "<script>"} {
			if strings.Contains(body, secret) {
				t.Fatalf("%s leaked %s", path, secret)
			}
		}
		if !strings.HasPrefix(path, "/api/") && !strings.Contains(body, "</html>") {
			t.Fatalf("incomplete template %s: %s", path, body)
		}
		if w.Header().Get("Referrer-Policy") != "same-origin" {
			t.Fatal("form navigations must retain their Origin for CSRF validation")
		}
	}
	for _, path := range []string{"/tickets/2", "/api/tickets/2", "/tickets/11", "/api/tickets/11", "/files/HIDDEN_FILENAME", "/assets/1", "/api/assets/1"} {
		if w := own(s, "GET", path, ""); w.Code != 404 {
			t.Fatalf("guessed %s: %d", path, w.Code)
		}
	}
	for _, path := range []string{"/tickets/2/reply", "/api/tickets/2/reply", "/tickets/11/reply"} {
		if w := own(s, "POST", path, "body=forged"); w.Code != 404 {
			t.Fatal(path, w.Code)
		}
	}
}
func TestAuthenticationCSRFAndForgery(t *testing.T) {
	s, f := fixture(t)
	for _, creds := range [][2]string{{"", ""}, {"anna", "wrong"}, {"unknown", "fixture-password-only"}} {
		if w := call(s, "GET", "/api/tickets", "", "", creds[0], creds[1]); w.Code != 401 {
			t.Fatal(w.Code)
		}
	}
	for _, origin := range []string{"", "null", "https://evil.example", "http://portal.example.test"} {
		w := call(s, "POST", "/tickets", "title=x&body=y", origin, "anna", "fixture-password-only")
		if w.Code != 403 {
			t.Fatal(w.Code)
		}
	}
	r := httptest.NewRequest("POST", "/tickets", strings.NewReader("title=x&body=y"))
	r.SetBasicAuth("anna", "fixture-password-only")
	r.Header.Set("Origin", s.origin)
	r.Header.Set("Sec-Fetch-Site", "cross-site")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("accepted cross-site fetch metadata")
	}
	for _, key := range []string{"requester", "company_id", "assignee", "kind", "parent_id"} {
		if w := own(s, "POST", "/api/tickets", "title=x&body=y&"+key+"=forged"); w.Code != 400 {
			t.Fatal(key, w.Code)
		}
	}
	if f.writes != 0 {
		t.Fatal("unauthorized write")
	}
	s.accounts = nil
	if w := own(s, "GET", "/", ""); w.Code != 303 {
		t.Fatal("empty accounts allowed")
	}
}
func TestPersistedWrites(t *testing.T) {
	s, f := fixture(t)
	w := own(s, "POST", "/api/tickets", url.Values{"title": {"Hilfe"}, "body": {"Mein Anliegen"}}.Encode())
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
	a := f.assets[21]
	var preview ticketPreview
	if e := json.Unmarshal([]byte(a.Preview), &preview); e != nil {
		t.Fatal(e)
	}
	if a.AssetType != 13 || a.ConvID != 0 || a.ParentType != 0 || a.Payload != "Mein Anliegen" || preview.Requester != "anna@example.test" || preview.CompanyID != "123" || preview.Status != "open" || preview.Assignee != "" {
		t.Fatalf("bad persisted ticket %#v %#v", a, preview)
	}
	w = own(s, "POST", "/tickets/21/reply", "body=Weitere+Informationen")
	if w.Code != 303 {
		t.Fatal(w.Code, w.Body)
	}
	a = f.assets[22]
	var entry entryPreview
	json.Unmarshal([]byte(a.Preview), &entry)
	if a.ParentID != 21 || a.ParentType != 2 || a.AssetType != 14 || a.Payload != "Weitere Informationen" || entry.Kind != "customer_reply" || entry.Author != "Anna" {
		t.Fatal(a, entry)
	}
	// A fresh handler reads NRC, not a local ticket database/cache.
	fresh := &portal{source: f, accounts: s.accounts, origin: s.origin}
	w = own(fresh, "GET", "/api/tickets/21", "")
	if !strings.Contains(w.Body.String(), "Weitere Informationen") {
		t.Fatal(w.Body)
	}
	f.fail = true
	before := f.writes
	w = own(s, "POST", "/tickets", "title=x&body=y")
	if w.Code != 503 || f.writes != before+1 {
		t.Fatal("mutation retried or claimed success")
	}
}
func TestEncodedFormByteLimits(t *testing.T) {
	s, f := fixture(t)
	body := strings.Repeat("ü", 16000)
	w := own(s, "POST", "/api/tickets", url.Values{"title": {strings.Repeat("ü", 100)}, "body": {body}}.Encode())
	if w.Code != 201 || f.assets[21].Payload != body {
		t.Fatal("valid decoded byte limit rejected", w.Code)
	}
	w = own(s, "POST", "/api/tickets/21/reply", url.Values{"body": {body}}.Encode())
	if w.Code != 201 || f.assets[22].Payload != body {
		t.Fatal("valid reply byte limit rejected", w.Code)
	}
	w = own(s, "POST", "/api/tickets/21/reply", url.Values{"body": {body + "x"}}.Encode())
	if w.Code != 400 || f.writes != 2 {
		t.Fatal("oversized decoded body accepted", w.Code)
	}
}
func TestAccountsFailClosed(t *testing.T) {
	for _, body := range []string{"", "[]", "null", "{}", `[{"login":"admin","password_hash":"plaintext"}]`} {
		path := filepath.Join(t.TempDir(), "accounts.json")
		os.WriteFile(path, []byte(body), 0600)
		if _, e := loadAccounts(path); e == nil {
			t.Fatal("accepted invalid config", body)
		}
	}
	h, _ := bcrypt.GenerateFromPassword([]byte("long-random-test-password"), 12)
	a := []account{{Login: "anna", PasswordHash: string(h), Requester: "anna@example.test", Name: "Anna", CompanyID: "123"}}
	b, _ := json.Marshal(a)
	path := filepath.Join(t.TempDir(), "accounts.json")
	os.WriteFile(path, b, 0600)
	if _, e := loadAccounts(path); e != nil {
		t.Fatal(e)
	}
	os.Chmod(path, 0644)
	if _, e := loadAccounts(path); e == nil {
		t.Fatal("world readable accepted")
	}
}

func TestProvisionPrivateFile(t *testing.T) {
	input := filepath.Join(t.TempDir(), "private-input.json")
	if e := os.WriteFile(input, []byte(`[{"login":"anna","password":"a-long-unique-test-password","requester":"anna@example.test","name":"Anna","company_id":"123"}]`), 0600); e != nil {
		t.Fatal(e)
	}
	f, e := os.Open(input)
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	old := os.Stdin
	os.Stdin = f
	defer func() { os.Stdin = old }()
	output := filepath.Join(t.TempDir(), "accounts.json")
	if e := provision(output); e != nil {
		t.Fatal(e)
	}
	a, e := loadAccounts(output)
	if e != nil || len(a) != 1 {
		t.Fatal(a, e)
	}
	if e := bcrypt.CompareHashAndPassword([]byte(a[0].PasswordHash), []byte("a-long-unique-test-password")); e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(output)
	if strings.Contains(string(b), "a-long-unique-test-password") {
		t.Fatal("plaintext password persisted")
	}
	f.Seek(0, 0)
	if e := provision(output); e == nil {
		t.Fatal("overwrote existing accounts")
	}
	if after, _ := os.ReadFile(output); string(after) != string(b) {
		t.Fatal("existing account file changed")
	}
}

// Opt-in browser fixture; no production flag can activate fake storage.
// Run TICKETS_TEST_ADDR=127.0.0.1:18096 go test -run TestBrowserFixture -v.
func TestBrowserFixture(t *testing.T) {
	addr := os.Getenv("TICKETS_TEST_ADDR")
	if addr == "" {
		t.Skip("opt-in rendering fixture")
	}
	s, _ := fixture(t)
	if mode := os.Getenv("TICKETS_TEST_SHARING"); mode == "1" || mode == "unavailable" {
		var f *fakeSource
		s, f = sharingFixture(t)
		f.fail = mode == "unavailable"
	}
	if os.Getenv("TICKETS_TEST_PASSWORD") == "1" {
		var f *fakeSource
		s, f = sharingFixture(t)
		company := f.assets[123]
		company.Preview = `{"version":1,"title":"Nordwerk GmbH","ticket_groups":[{"id":"tech","name":"Technik","contact_ids":["51","52"]},{"id":"project","name":"Projektteam","contact_ids":["51","54"]}]}`
		f.assets[123] = company
		// This fixture peer serves only Anna's account, not legacy requester mappings.
		delete(f.assets, 2)
		s.accounts = passwordAccountPeer(t)
	}
	s.files = testFiles(t)
	var err error
	s.brand, err = loadBranding()
	if err != nil {
		t.Fatal(err)
	}
	s.origin = os.Getenv("TICKETS_TEST_ORIGIN")
	if s.origin == "" {
		s.origin = "http://" + addr
	}
	t.Log("Fixture only: anna / fixture-password-only")
	t.Fatal(http.ListenAndServe(addr, s))
}
