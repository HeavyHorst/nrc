package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestAgentAPIReviewBoundary(t *testing.T) {
	a := testApp(t)
	a.cfg.JWTSecret, a.cfg.JWTIssuer, a.cfg.Workspace = "fixture-signing-secret-not-production", "nrc-tailscale-proxy", "test-workspace"
	token := testProxyAssertion(a.cfg.JWTSecret, testProxyClaims())
	admin, public := a.admin(), a.public()
	call := func(handler http.Handler, method, path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("X-NRC-Publish-Auth", token)
		r.Header.Set("X-Tailscale-User", "forged@example.com")
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	for _, token := range []string{"", "wrong", a.cfg.Password} {
		if w := call(admin, "GET", "/api/publications", "", token); w.Code != 401 {
			t.Fatalf("wrong credential accepted: %d", w.Code)
		}
	}
	if w := request(admin, "GET", "/api/publications", nil, true); w.Code != 401 {
		t.Fatal("reviewer credential accepted by agent API")
	}
	input := `{"note_id":"41","slug":"agent-guide","title":"Agent guide","category":"API","kind":"Anleitung","summary":"Prepared privately"}`
	for _, body := range []string{strings.TrimSuffix(input, "}") + `,"markdown":"injected"}`, input + ` {}`, strings.Replace(input, `"41"`, `"0"`, 1)} {
		if w := call(admin, "POST", "/api/drafts", body, token); w.Code != 400 {
			t.Fatalf("invalid draft accepted: %d %s", w.Code, w.Body.String())
		}
	}
	w := call(admin, "POST", "/api/drafts", input, token)
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	var created struct {
		Draft      agentRevision `json:"draft"`
		ReviewPath string        `json:"review_path"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Draft.NoteID != "41" || created.Draft.CreatedBy != "tag:amp" || created.ReviewPath != "/drafts/"+created.Draft.ID {
		t.Fatalf("bad draft response: %+v", created)
	}
	note := a.source.(*fixtureSource).assets[41]
	note.Payload = "Later agent edit must not enter this draft"
	a.source.(*fixtureSource).assets[41] = note
	w = call(admin, "GET", "/api/drafts/"+created.Draft.ID, "", token)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Freigegebener Inhalt.") || strings.Contains(w.Body.String(), "Later agent edit") {
		t.Fatalf("inspect is not the stored snapshot: %s", w.Body.String())
	}
	if !strings.Contains(w.Body.String(), `"published":null`) || !strings.Contains(w.Body.String(), `"stale":false`) {
		t.Fatalf("unexpected initial publication status: %s", w.Body.String())
	}
	w = call(admin, "GET", "/api/publications", "", token)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"published":[]`) || !strings.Contains(w.Body.String(), created.Draft.ID) {
		t.Fatalf("list: %s", w.Body.String())
	}
	for _, path := range []string{"/api/publications", "/api/drafts/" + created.Draft.ID, "/articles/agent-guide"} {
		if w := call(public, "GET", path, "", token); w.Code != 404 {
			t.Fatalf("public disclosure: %s %d", path, w.Code)
		}
	}
	for _, path := range []string{"/drafts/" + created.Draft.ID + "/approve", "/articles/agent-guide/withdraw", "/", "/notes", created.ReviewPath} {
		if w := call(admin, "POST", path, `{"confirmed":"yes"}`, token); w.Code != 401 {
			t.Fatalf("agent accessed human route: %s %d", path, w.Code)
		}
	}
	for _, path := range []string{"/api/drafts/" + created.Draft.ID + "/approve", "/api/articles/agent-guide/withdraw"} {
		if w := call(admin, "POST", path, `{}`, token); w.Code != 404 {
			t.Fatalf("unexpected agent mutation: %s %d", path, w.Code)
		}
	}
	if w := request(admin, "GET", created.ReviewPath, nil, true); w.Code != 200 {
		t.Fatal("reviewer cannot review agent draft")
	}
	form := url.Values{"csrf": {a.csrf}, "confirmed": {"yes"}}
	// A second agent draft shares the initial base and must become stale.
	w = call(admin, "POST", "/api/drafts", input, token)
	var competing struct {
		Draft agentRevision `json:"draft"`
	}
	if w.Code != 201 {
		t.Fatalf("second draft: %d", w.Code)
	}
	if err := json.Unmarshal(w.Body.Bytes(), &competing); err != nil {
		t.Fatal(err)
	}
	if w := request(admin, "POST", created.ReviewPath+"/approve", form, true); w.Code != 303 {
		t.Fatalf("human approval failed: %d %s", w.Code, w.Body.String())
	}
	w = call(admin, "GET", "/api/drafts/"+competing.Draft.ID, "", token)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"stale":true`) || !strings.Contains(w.Body.String(), created.Draft.ID) {
		t.Fatalf("competing draft status incorrect: %s", w.Body.String())
	}
	if w := request(admin, "POST", "/drafts/"+competing.Draft.ID+"/approve", form, true); w.Code != 409 {
		t.Fatal("stale agent draft overwrote approved version")
	}
	if w := call(admin, "GET", "/api/drafts/"+created.Draft.ID, "", token); w.Code != 404 {
		t.Fatal("approved revision still reported as draft")
	}
	if w := call(public, "GET", "/articles/agent-guide", "", ""); w.Code != 200 || strings.Contains(w.Body.String(), "Later agent edit") {
		t.Fatal("approved snapshot incorrect")
	}
	a.cfg.JWTSecret = ""
	if w := call(admin, "GET", "/api/publications", "", "old-token"); w.Code != 401 {
		t.Fatal("disabled agent API accessible")
	}
}
