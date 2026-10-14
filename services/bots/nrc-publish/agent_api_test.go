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

func TestArticleOrderHTTP(t *testing.T) {
	a := testApp(t)
	a.cfg.JWTSecret, a.cfg.JWTIssuer, a.cfg.Workspace = "fixture-signing-secret-not-production", "nrc-tailscale-proxy", "test-workspace"
	token := testProxyAssertion(a.cfg.JWTSecret, testProxyClaims())
	for _, fixture := range []revision{
		{SourceID: 42, Slug: "z-start", Title: "Z Einstieg", Category: "Thema", Kind: "Anleitung"},
		{SourceID: 43, Slug: "a-detail", Title: "A Detail", Category: "Thema", Kind: "Anleitung"},
		{SourceID: 44, Slug: "b-extra", Title: "B Zusatz", Category: "Thema", Kind: "Anleitung"},
		{SourceID: 45, Slug: "other", Title: "Anderes Thema", Category: "Andere", Kind: "Anleitung"},
	} {
		draft, err := a.store.create(fixture, "")
		if err != nil {
			t.Fatal(err)
		}
		if err := a.store.approve(draft.ID, "reviewer"); err != nil {
			t.Fatal(err)
		}
	}
	call := func(handler http.Handler, credential, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("PUT", "/api/order", strings.NewReader(body))
		r.Header.Set("X-NRC-Publish-Auth", credential)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	input := `{"category":"Thema","note_ids":["42","43"]}`
	if w := call(a.admin(), "", input); w.Code != 401 {
		t.Fatal("unauthenticated sorting accepted")
	}
	if w := call(a.public(), token, input); w.Code != 404 {
		t.Fatal("public sorting exposed")
	}
	if w := call(a.admin(), token, input); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	assertOrder := func(slugs ...string) {
		t.Helper()
		body := request(a.public(), "GET", "/?category=Thema", nil, false).Body.String()
		previous := -1
		for _, slug := range slugs {
			position := strings.Index(body, `class="result" href="/articles/`+slug+`"`)
			if position < 0 || position <= previous {
				t.Fatalf("wrong reading order: %v", slugs)
			}
			previous = position
		}
	}
	assertOrder("z-start", "a-detail", "b-extra")
	for _, body := range []string{
		`{"category":"Thema","note_ids":["43","43"]}`,
		`{"category":"Thema","note_ids":["43","45"]}`,
		`{"category":"Thema","note_ids":["43","999"]}`,
		`{"category":"Thema","note_ids":[42]}`,
		input + ` {}`,
	} {
		if w := call(a.admin(), token, body); w.Code != 400 {
			t.Fatalf("invalid order accepted: %s", body)
		}
		assertOrder("z-start", "a-detail", "b-extra")
	}
	// A new snapshot and slug for the same note retain its position.
	draft, err := a.store.create(revision{SourceID: 42, Slug: "new-start", Title: "ZZ Neuer Einstieg", Category: "Thema", Kind: "Anleitung"}, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := a.store.approve(draft.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	path := a.store.db.Path()
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	s, err := openStore(path, "test-workspace")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.db.Close() })
	a.store = s
	assertOrder("new-start", "a-detail", "b-extra")
	form := url.Values{"csrf": {a.csrf}, "category": {"Thema"}, "position_42": {"3"}, "position_43": {"2"}, "position_44": {"1"}}
	if w := request(a.admin(), "POST", "/order", form, true); w.Code != 303 {
		t.Fatal(w.Body.String())
	}
	assertOrder("b-extra", "a-detail", "new-start")
	if w := call(a.admin(), token, `{"category":"Thema","note_ids":[]}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	assertOrder("a-detail", "b-extra", "new-start")
}

func TestSubtopicsHTTP(t *testing.T) {
	a := testApp(t)
	a.cfg.JWTSecret, a.cfg.JWTIssuer, a.cfg.Workspace = "fixture-signing-secret-not-production", "nrc-tailscale-proxy", "test-workspace"
	token := testProxyAssertion(a.cfg.JWTSecret, testProxyClaims())
	publish := func(id uint64, slug, title, category string) {
		t.Helper()
		draft, err := a.store.create(revision{SourceID: id, Slug: slug, Title: title, Category: category, Kind: "Anleitung"}, "")
		if err != nil {
			t.Fatal(err)
		}
		if err := a.store.approve(draft.ID, "reviewer"); err != nil {
			t.Fatal(err)
		}
	}
	publish(42, "start", "Z Einstieg", "Thema")
	publish(43, "detail", "A Detail", "Thema")
	publish(44, "direct", "B Direkt", "Thema")
	publish(45, "foreign", "Fremd", "Andere")
	if err := a.store.setOrder("Thema", []string{"42", "43", "44"}); err != nil {
		t.Fatal(err)
	}
	call := func(handler http.Handler, credential, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("PUT", "/api/subtopics", strings.NewReader(body))
		r.Header.Set("X-NRC-Publish-Auth", credential)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	input := `{"category":"Thema","assignments":{"42":"Einstieg","43":"Details"}}`
	if w := call(a.admin(), "", input); w.Code != 401 {
		t.Fatal("unauthenticated assignment")
	}
	if w := call(a.public(), token, input); w.Code != 404 {
		t.Fatal("public assignment exposed")
	}
	if w := call(a.admin(), token, input); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	assertGroups := func() {
		t.Helper()
		body := request(a.public(), "GET", "/?category=Thema", nil, false).Body.String()
		if !strings.Contains(body, `class="subtopic-heading">Einstieg`) || !strings.Contains(body, `class="subtopic-heading">Details`) || strings.Index(body, "/articles/start") > strings.Index(body, "/articles/detail") {
			t.Fatal("wrong public groups")
		}
		if !strings.Contains(body, "/articles/direct") {
			t.Fatal("ungrouped article missing")
		}
	}
	assertGroups()
	for _, bad := range []string{
		`{"category":"Thema","assignments":{"42":"Changed","45":"Invalid"}}`,
		`{"category":"Thema","assignments":{"999":"Invalid"}}`,
		`{"category":"Thema","assignments":{"042":"Invalid"}}`,
		`{"category":"Thema","assignments":null}`,
		`{"category":"Thema","assignments":{"42":"Line\nbreak"}}`, input + `{}`,
	} {
		if w := call(a.admin(), token, bad); w.Code != 400 {
			t.Fatalf("invalid assignment accepted: %s", bad)
		}
		assertGroups()
	}
	// Same ID, new slug and approved snapshot retain navigation metadata after restart.
	publish(42, "new-start", "Neuer Einstieg", "Thema")
	path := a.store.db.Path()
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	s, err := openStore(path, "test-workspace")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.db.Close() })
	a.store = s
	rows, err := a.store.entries("published")
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.SourceID == 42 && (row.Subtopic != "Einstieg" || row.Slug != "new-start") {
			t.Fatal("assignment lost on update/restart")
		}
	}
	body := request(a.public(), "GET", "/articles/new-start", nil, false).Body.String()
	if !strings.Contains(body, `class="subtopic" open`) || !strings.Contains(body, "Einstieg") {
		t.Fatal("active group not open")
	}
	form := url.Values{"csrf": {a.csrf}, "category": {"Thema"}, "subtopic_42": {"Details"}, "subtopic_43": {"Details"}, "subtopic_44": {""}}
	if w := request(a.admin(), "POST", "/subtopics", form, true); w.Code != 303 {
		t.Fatal(w.Body.String())
	}
	body = request(a.public(), "GET", "/?category=Thema", nil, false).Body.String()
	if strings.Contains(body, `class="subtopic-heading">Einstieg`) || strings.Count(body, `class="subtopic-heading">Details`) != 1 {
		t.Fatal("human regroup failed")
	}
	if w := call(a.admin(), token, `{"category":"Thema","assignments":{"42":"","43":""}}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if body := request(a.public(), "GET", "/?category=Thema", nil, false).Body.String(); strings.Contains(body, `class="subtopic-heading"`) {
		t.Fatal("clear assignment failed")
	}
}
