package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type fakeSource struct{ rows []contact }

func (s *fakeSource) contacts(context.Context) ([]contact, error) { return s.rows, nil }
func assertion(a *app, workspace string) string {
	h := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	b, _ := json.Marshal(map[string]any{"sub": "admin", "workspace": workspace, "iss": a.cfg.JWTIssuer, "aud": "nrc-newsletter", "exp": time.Now().Unix() + 60})
	p := h + "." + base64.RawURLEncoding.EncodeToString(b)
	m := hmac.New(sha256.New, []byte(a.cfg.JWTSecret))
	m.Write([]byte(p))
	return p + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

type fixture struct {
	a             *app
	src           *fakeSource
	calls         []map[string]any
	outcome       string
	path          string
	transportDone chan struct{}
}

func setup(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{outcome: "success", path: filepath.Join(t.TempDir(), "state.db"), transportDone: make(chan struct{})}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || u != "key" || p != "secret" {
			t.Error("provider credentials absent")
		}
		if r.Method == "GET" {
			if strings.HasSuffix(r.URL.Path, "detailcontent") {
				w.Write([]byte(`{"Data":[{"Html-part":"<p>Hello {{var:name}}</p>","Text-part":"Hello {{var:name}}"}]}`))
			} else {
				w.Write([]byte(`{"Data":[{"Name":"Approved"}]}`))
			}
			return
		}
		var v map[string]any
		json.NewDecoder(r.Body).Decode(&v)
		f.calls = append(f.calls, v)
		if f.outcome == "ambiguous" {
			w.WriteHeader(503)
			return
		}
		if f.outcome == "transport" {
			conn, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			close(f.transportDone)
			conn.Close() // Request received, response lost: acceptance is unknowable.
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"Messages": []any{map[string]string{"Status": f.outcome}}})
	}))
	t.Cleanup(srv.Close)
	s, e := openStore(f.path, "w")
	if e != nil {
		t.Fatal(e)
	}
	f.src = &fakeSource{[]contact{{"1", "One", "one@example.com"}, {"2", "Duplicate", "ONE@example.com"}, {"3", "Three", "three@example.com"}}}
	f.a = &app{cfg: config{Workspace: "w", JWTSecret: "secure-test", JWTIssuer: "issuer", PublicURL: "https://newsletter.example", FromEmail: "from@example.com", ReplyTo: "reply@example.com", TemplateIDs: []string{"42"}, EventSecret: "events"}, s: s, source: f.src, provider: provider{client: srv.Client(), base: srv.URL, key: "key", secret: "secret"}}
	t.Cleanup(func() { f.a.s.db.Close() })
	return f
}
func (f *fixture) req(method, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("X-NRC-Newsletter-Auth", assertion(f.a, "w"))
	w := httptest.NewRecorder()
	f.a.adminHandler().ServeHTTP(w, r)
	return w
}
func public(a *app, method, path string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	a.publicHandler().ServeHTTP(w, httptest.NewRequest(method, path, nil))
	return w
}
func expect(t *testing.T, w *httptest.ResponseRecorder, status int) {
	t.Helper()
	if w.Code != status {
		t.Fatalf("status %d expected %d: %s", w.Code, status, w.Body.String())
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("cacheable response")
	}
}
func (f *fixture) create(t *testing.T) campaign {
	w := f.req("POST", "/api/campaigns", `{"title":"News","template_id":"42","subject":"Update","variables":{"name":"Friend"}}`)
	expect(t, w, 201)
	var c campaign
	json.Unmarshal(w.Body.Bytes(), &c)
	return c
}
func TestAuthAndValidation(t *testing.T) {
	f := setup(t)
	r := httptest.NewRequest("GET", "/api/state", nil)
	r.Header.Set("X-NRC-Newsletter-Auth", assertion(f.a, "other"))
	w := httptest.NewRecorder()
	f.a.adminHandler().ServeHTTP(w, r)
	expect(t, w, 401)
	expect(t, public(f.a, "GET", "/api/state"), 404)
	for _, body := range []string{`null`, `{}`, `{"title":"x","template_id":"99","subject":"s","variables":{}}`, `{"title":"x","template_id":"42","subject":"s\r\nx","variables":{}}`, `{"title":"x","template_id":"42","subject":"s","variables":{},"extra":true}`} {
		expect(t, f.req("POST", "/api/campaigns", body), 400)
	}
	c := f.create(t)
	expect(t, f.req("PUT", "/api/campaigns/"+c.ID, `{"title":"News","template_id":"42","subject":"Update","variables":{},"revision":9}`), 409)
	preview := f.req("POST", "/api/campaigns/"+c.ID+"/preview", `{"revision":1}`)
	expect(t, preview, 200)
	var view struct {
		HTML  string `json:"html"`
		Exact bool   `json:"exact"`
	}
	if json.Unmarshal(preview.Body.Bytes(), &view) != nil || view.Exact || view.HTML != "<p>Hello {{var:name}}</p>" {
		t.Fatal("template source preview misrepresented as provider-rendered output")
	}
	if len(f.calls) != 0 {
		t.Fatal("preview sent mail")
	}
}
func TestConsentEmailChangeAndOptout(t *testing.T) {
	f := setup(t)
	expect(t, f.req("POST", "/api/subscribers/1/invite", `{}`), 400)
	expect(t, f.req("POST", "/api/subscribers/1/invite", `{"source":"Requested on support call 123"}`), 200)
	expect(t, f.req("POST", "/api/subscribers/1/invite", `{"source":"call"}`), 429)
	msg := f.calls[0]["Messages"].([]any)[0].(map[string]any)
	text := msg["TextPart"].(string)
	token := regexp.MustCompile(`confirm\?token=([a-f0-9]+)`).FindStringSubmatch(text)[1]
	path := "/confirm?token=" + token
	expect(t, public(f.a, "GET", path), 200)
	if f.a.status("one@example.com") != "pending" {
		t.Fatal("scanner subscribed")
	}
	f.src.rows[0].Email = "changed@example.com"
	expect(t, public(f.a, "POST", path), 200)
	if f.a.status("changed@example.com") != "not_subscribed" || f.a.status("one@example.com") != "subscribed" {
		t.Fatal("consent transferred to new address")
	}
	expect(t, public(f.a, "POST", path), 400)
	u, _ := url.Parse(f.a.unsubscribeLink("one@example.com"))
	expect(t, public(f.a, "GET", u.RequestURI()), 200)
	if f.a.status("one@example.com") != "subscribed" {
		t.Fatal("scanner opted out")
	}
	expect(t, public(f.a, "POST", u.RequestURI()), 200)
	if f.a.status("one@example.com") != "unsubscribed" {
		t.Fatal("optout failed")
	}
	expect(t, f.req("POST", "/api/subscribers/1/unsubscribe", `{}`), 200)
	if f.a.status("changed@example.com") != "unsubscribed" {
		t.Fatal("local optout failed")
	}
}
func TestTestMailHonorsSuppression(t *testing.T) {
	for _, event := range []string{"bounce", "spam", "unsub"} {
		t.Run(event, func(t *testing.T) {
			f := setup(t)
			c := f.create(t)
			path := "/api/campaigns/" + c.ID + "/test"
			// Tests can reach an explicitly chosen address without enrolling it.
			expect(t, f.req("POST", path, `{"revision":1,"email":"test@example.com"}`), 200)
			r := httptest.NewRequest("POST", "/events", strings.NewReader(`{"event":"`+event+`","hard_bounce":true,"email":"test@example.com"}`))
			r.SetBasicAuth("mailjet", "events")
			w := httptest.NewRecorder()
			f.a.publicHandler().ServeHTTP(w, r)
			expect(t, w, 200)
			attempts := len(f.calls)
			expect(t, f.req("POST", path, `{"revision":1,"email":"TEST@example.com"}`), 422)
			if len(f.calls) != attempts {
				t.Fatal("test mail bypassed address suppression")
			}
		})
	}
}

func TestGatingDedupSnapshotAndRecovery(t *testing.T) {
	f := setup(t)
	c := f.create(t)
	path := "/api/campaigns/" + c.ID
	expect(t, f.req("POST", path+"/send", `{"revision":1,"confirmation":"Update"}`), 409)
	f.outcome = "ambiguous"
	expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 502)
	if f.a.s.Campaigns[c.ID].TestedRevision != 0 {
		t.Fatal("ambiguous test passed")
	}
	f.outcome = "success"
	expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 200)
	msg := f.calls[len(f.calls)-1]["Messages"].([]any)[0].(map[string]any)
	if !strings.Contains(msg["HTMLPart"].(string), "/unsubscribe?token=") || msg["TemplateLanguage"] != true || msg["Variables"].(map[string]any)["name"] != "Friend" {
		t.Fatal("unsafe provider payload")
	}
	expect(t, f.req("POST", path+"/send", `{"revision":1,"confirmation":"Update"}`), 409)
	f.a.s.Consent["one@example.com"] = &consent{Status: "subscribed"}
	f.a.s.Consent["three@example.com"] = &consent{Status: "subscribed"}
	view := f.req("GET", "/api/state", "")
	expect(t, view, 200)
	var audience struct {
		Audience map[string]int `json:"audience"`
	}
	if json.Unmarshal(view.Body.Bytes(), &audience) != nil || audience.Audience["total"] != 3 || audience.Audience["eligible"] != 2 || audience.Audience["duplicates"] != 1 {
		t.Fatal("audience counts did not account for duplicate addresses")
	}
	expect(t, f.req("POST", path+"/send", `{"revision":1,"confirmation":"wrong"}`), 409)
	expect(t, f.req("POST", path+"/send", `{"revision":1,"confirmation":"Update"}`), 202)
	job := f.a.s.Campaigns[c.ID]
	if len(job.Recipients) != 2 {
		t.Fatalf("dedup recipients: %d", len(job.Recipients))
	}
	expect(t, f.req("PUT", path, `{"title":"News","template_id":"42","subject":"Update","variables":{},"revision":1}`), 409)
	// Crash with one uncertain recipient and one never attempted. New email must not receive snapshot mail.
	job.Recipients[0].Status = "inflight"
	f.a.s.mustSave()
	f.a.s.db.Close()
	s, e := openStore(f.path, "w")
	if e != nil {
		t.Fatal(e)
	}
	f.a.s = s
	f.src.rows[2].Email = "new@example.com"
	n := len(f.calls)
	f.a.dispatch(context.Background())
	f.a.dispatch(context.Background())
	if len(f.calls) != n {
		t.Fatal("recovery resent uncertain or changed address")
	}
	job = f.a.s.Campaigns[c.ID]
	if job.Recipients[0].Status != "unknown" || job.Recipients[1].Status != "skipped" || job.Status != "completed_with_errors" {
		t.Fatalf("recovery: %+v", job)
	}
}
func TestWebhookAndDispatchAmbiguity(t *testing.T) {
	f := setup(t)
	c := f.create(t)
	path := "/api/campaigns/" + c.ID
	expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 200)
	f.a.s.Consent["one@example.com"] = &consent{Status: "subscribed"}
	expect(t, f.req("POST", path+"/send", `{"revision":1,"confirmation":"Update"}`), 202)
	f.outcome = "transport"
	f.a.dispatch(context.Background())
	<-f.transportDone // A hijacked close has no HTTP response synchronization.
	n := len(f.calls)
	f.a.dispatch(context.Background())
	if len(f.calls) != n || f.a.s.Campaigns[c.ID].Recipients[0].Status != "unknown" {
		t.Fatal("ambiguous resend")
	}
	body := `[{"event":"bounce","hard_bounce":true,"email":"ONE@example.com"},{"event":"spam","email":"stranger@example.com"}]`
	r := httptest.NewRequest("POST", "/events", strings.NewReader(body))
	w := httptest.NewRecorder()
	f.a.publicHandler().ServeHTTP(w, r)
	expect(t, w, 401)
	r = httptest.NewRequest("POST", "/events", strings.NewReader(body))
	r.SetBasicAuth("mailjet", "events")
	w = httptest.NewRecorder()
	f.a.publicHandler().ServeHTTP(w, r)
	expect(t, w, 200)
	if f.a.status("one@example.com") != "blocked" || f.a.status("stranger@example.com") != "not_subscribed" {
		t.Fatal("suppression mismatch")
	}
}

func TestRevisionInvalidationAndPendingRecovery(t *testing.T) {
	f := setup(t)
	c := f.create(t)
	path := "/api/campaigns/" + c.ID
	expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 200)
	expect(t, f.req("PUT", path, `{"title":"Edited","template_id":"42","subject":"Update","variables":{},"revision":1}`), 200)
	expect(t, f.req("POST", path+"/send", `{"revision":2,"confirmation":"Update"}`), 409)
	expect(t, f.req("POST", path+"/test", `{"revision":2,"email":"test@example.com"}`), 200)
	f.a.s.Consent["one@example.com"] = &consent{Status: "subscribed"}
	f.a.s.Consent["three@example.com"] = &consent{Status: "subscribed"}
	expect(t, f.req("GET", "/api/state", ""), 200)
	expect(t, f.req("POST", path+"/send", `{"revision":2,"confirmation":"Update"}`), 202)
	f.a.s.db.Close()
	s, e := openStore(f.path, "w")
	if e != nil {
		t.Fatal(e)
	}
	f.a.s = s
	// A new optout after queueing must be honored, even after restart.
	expect(t, f.req("POST", "/api/subscribers/3/unsubscribe", `{}`), 200)
	n := len(f.calls)
	f.a.dispatch(context.Background())
	f.a.dispatch(context.Background())
	job := f.a.s.Campaigns[c.ID]
	if len(f.calls) != n+1 || job.Status != "sent" || job.Recipients[0].Status != "sent" || job.Recipients[1].Status != "skipped" {
		t.Fatalf("pending recovery/optout: %+v", job)
	}
	expect(t, f.req("POST", path+"/preview", `{"revision":2}`), 200)
}

func TestPersistedWorkspaceCannotBeReassigned(t *testing.T) {
	path := filepath.Join(t.TempDir(), "newsletter.db")
	s, err := openStore(path, "original")
	if err != nil {
		t.Fatal(err)
	}
	s.db.Close()
	if other, err := openStore(path, "different"); err == nil {
		other.db.Close()
		t.Fatal("consent and campaign data reopened in another workspace")
	}
}

func TestContactSearchPageScopeAndConsent(t *testing.T) {
	f := setup(t)
	response := protocol.SearchResponse{Mode: "text", TotalCount: 51, NextOffset: 26, HasMore: true, Stale: true,
		Results: []protocol.SearchResult{{Entity: protocol.SearchEntityIdentity{Workspace: "w", EntityType: protocol.SearchEntityAsset, EntityID: 9007199254740993}, AssetType: 9, Preview: `{"version":1,"title":"Anna","email":"ANNA@example.test"}`, Companies: []protocol.SearchCompany{{CustomerID: "17", Name: "Example GmbH"}}}}}
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req protocol.SearchRequest
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.Mode != "text" || req.Workspace != "w" || req.Offset != 25 || req.TopN != 1 || req.Query != "EXAMPLE" || len(req.Filters.AssetTypes) != 1 || req.Filters.AssetTypes[0] != 9 || r.Header.Get("X-NRC-Newsletter-Auth") != "" {
			t.Error("incorrect scoped text request")
		}
		w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
		json.NewEncoder(w).Encode(response)
	}))
	defer backend.Close()
	f.a.cfg.SearchURL = backend.URL
	f.a.s.Consent["anna@example.test"] = &consent{Status: "subscribed", Source: "DOI"}
	w := f.req("POST", "/api/subscribers/search", `{"query":"EXAMPLE","offset":25,"limit":1}`)
	expect(t, w, 200)
	var got struct {
		Subscribers []map[string]any `json:"subscribers"`
		Total       int              `json:"total_count"`
		Next        int              `json:"next_offset"`
		Stale       bool             `json:"stale"`
	}
	if json.Unmarshal(w.Body.Bytes(), &got) != nil || len(got.Subscribers) != 1 || got.Total != 51 || got.Next != 26 || !got.Stale || got.Subscribers[0]["contact_id"] != "9007199254740993" || got.Subscribers[0]["status"] != "subscribed" {
		t.Fatalf("page: %s", w.Body.String())
	}
	if len(f.calls) != 0 {
		t.Fatal("search sent mail")
	}
	for _, mutate := range []func(){func() { response.Mode = "" }, func() { response.Results[0].Entity.Workspace = "other" }, func() { response.NextOffset = 25 }} {
		original := response
		original.Results = append([]protocol.SearchResult(nil), response.Results...)
		mutate()
		expect(t, f.req("POST", "/api/subscribers/search", `{"query":"EXAMPLE","offset":25,"limit":1}`), 503)
		response = original
	}
	w = f.req("GET", "/api/summary", "")
	expect(t, w, 200)
	var summary struct {
		Subscribers []any          `json:"subscribers"`
		Audience    map[string]int `json:"audience"`
	}
	if json.Unmarshal(w.Body.Bytes(), &summary) != nil || len(summary.Subscribers) != 0 || summary.Audience["total"] != len(f.src.rows) {
		t.Fatalf("summary: %s", w.Body.String())
	}
}
