package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

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
		} else if w.Code != 401 {
			t.Fatalf("unauthenticated portal access: %d", w.Code)
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
		f.assets[id] = p.Asset{AssetID: id, AssetType: ticketType, Preview: string(v), Payload: "Originalanfrage <script>alert(1)</script>"}
	}
	add(1, "anna@example.test", "Meine Rechnung")
	add(2, "bea@example.test", "PRIVATE_OTHER_TITLE")
	for i, kind := range []string{"public_reply", "internal_note", "customer_reply"} {
		v, _ := json.Marshal(entryPreview{1, kind, "Serviceteam"})
		body := "Vielen Dank für Ihre Nachricht."
		if kind == "internal_note" {
			body = "HIDDEN_INTERNAL_NOTE"
		}
		id := uint64(10 + i)
		f.assets[id] = p.Asset{AssetID: id, AssetType: entryType, ParentType: 2, ParentID: 1, Preview: string(v), Payload: body, Attachments: []p.Attachment{{Filename: "HIDDEN_FILENAME"}}}
	}
	return &portal{source: f, accounts: []account{{Login: "anna", PasswordHash: string(h), Requester: "anna@example.test", Name: "Anna", CompanyID: "123"}}, origin: "https://portal.example.test"}, f
}
func call(s *portal, method, path, form, origin, login, password string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(form))
	if login != "" {
		r.SetBasicAuth(login, password)
	}
	if method == "POST" {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func own(s *portal, method, path, form string) *httptest.ResponseRecorder {
	return call(s, method, path, form, s.origin, "anna", "fixture-password-only")
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
	if w := own(s, "GET", "/", ""); w.Code != 401 {
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
	a := []account{{"anna", string(h), "anna@example.test", "Anna", "123", ""}}
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
	if os.Getenv("TICKETS_TEST_SHARING") == "1" {
		s, _ = sharingFixture(t)
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
