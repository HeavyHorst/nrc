package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	bolt "go.etcd.io/bbolt"
)

type fixtureSource struct{ assets map[uint64]protocol.Asset }

func (s *fixtureSource) get(_ context.Context, id uint64) (protocol.Asset, error) {
	a, ok := s.assets[id]
	if !ok {
		return a, errNotFound
	}
	return a, nil
}
func (s *fixtureSource) list(_ context.Context, _ int64, _ uint64, _ bool) (*protocol.AssetListPageResponse, error) {
	p := &protocol.AssetListPageResponse{}
	for _, a := range s.assets {
		p.Assets = append(p.Assets, a)
	}
	return p, nil
}

func testApp(t *testing.T) *app {
	t.Helper()
	s, err := openStore(filepath.Join(t.TempDir(), "publish.db"), "test-workspace")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.db.Close() })
	return newApp(s, &fixtureSource{map[uint64]protocol.Asset{41: {AssetType: 5, AssetID: 41, UpdatedAt: 100, Preview: `{"title":"Interner Titel","format":"markdown"}`, Payload: "## Einrichtung\n\nFreigegebener Inhalt."}}}, config{User: "reviewer", Password: "only-for-tests-not-a-secret", Brand: "NRC"})
}

func candidate() revision {
	return revision{SourceID: 41, SourceUpdated: 100, Slug: "einrichtung", Title: "Einrichtung", Category: "Erste Schritte", Kind: "Anleitung", Markdown: "## Einrichtung\n\nFreigegebener Inhalt.", CreatedBy: "reviewer"}
}

func request(h http.Handler, method, path string, form url.Values, auth bool) *httptest.ResponseRecorder {
	body := strings.NewReader(form.Encode())
	r := httptest.NewRequest(method, path, body)
	if method == http.MethodPost {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if auth {
		r.SetBasicAuth("reviewer", "only-for-tests-not-a-secret")
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestPublishingLifecycleHTTP(t *testing.T) {
	a := testApp(t)
	public, admin := a.public(), a.admin()
	form := url.Values{"csrf": {a.csrf}, "source": {"41"}, "slug": {"einrichtung"}, "title": {"Öffentlicher Titel"}, "category": {"Erste Schritte"}, "kind": {"Anleitung"}, "summary": {"Kurze Anleitung"}}
	w := request(admin, "POST", "/drafts", form, true)
	if w.Code != 303 {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	id := strings.TrimPrefix(w.Header().Get("Location"), "/drafts/")
	for _, path := range []string{"/articles/einrichtung", "/drafts/" + id, "/notes"} {
		if got := request(public, "GET", path, nil, false); got.Code != 404 {
			t.Fatalf("private route %s exposed: %d", path, got.Code)
		}
	}
	if got := request(public, "GET", "/?q=Freigegebener", nil, false); strings.Contains(got.Body.String(), "Öffentlicher Titel") {
		t.Fatal("draft leaked into search")
	}
	preview := request(admin, "GET", "/drafts/"+id, nil, true)
	if preview.Code != 200 || !strings.Contains(preview.Body.String(), "Freigegebener Inhalt.") {
		t.Fatalf("preview: %d %s", preview.Code, preview.Body.String())
	}
	// Editing the live source during review must never change the approved snapshot.
	src := a.source.(*fixtureSource)
	note := src.assets[41]
	note.Payload = "Agentenänderung darf nicht durchrutschen"
	note.UpdatedAt = 200
	src.assets[41] = note
	preview = request(admin, "GET", "/drafts/"+id, nil, true)
	if !strings.Contains(preview.Body.String(), "inzwischen geändert") {
		t.Fatal("changed source not flagged")
	}
	approvePath := "/drafts/" + id + "/approve"
	if got := request(admin, "POST", approvePath, nil, true); got.Code != 403 {
		t.Fatal("missing CSRF accepted")
	}
	if got := request(admin, "POST", approvePath, url.Values{"csrf": {a.csrf}}, false); got.Code != 401 {
		t.Fatal("unauthenticated approval accepted")
	}
	if got := request(public, "POST", approvePath, url.Values{"csrf": {a.csrf}}, true); got.Code != 404 {
		t.Fatal("approval reachable on public listener")
	}
	if got := request(admin, "POST", approvePath, url.Values{"csrf": {a.csrf}}, true); got.Code != 400 {
		t.Fatal("approval without explicit confirmation accepted")
	}
	if got := request(admin, "POST", approvePath, url.Values{"csrf": {a.csrf}, "confirmed": {"yes"}}, true); got.Code != 303 {
		t.Fatalf("approve: %d %s", got.Code, got.Body.String())
	}
	article := request(public, "GET", "/articles/einrichtung", nil, false)
	if article.Code != 200 || !strings.Contains(article.Body.String(), "Freigegebener Inhalt.") || strings.Contains(article.Body.String(), "Agentenänderung") {
		t.Fatal("approval did not publish exact snapshot")
	}
	if !strings.Contains(article.Body.String(), `aria-current="page"`) || !strings.Contains(article.Body.String(), `href="#einrichtung"`) {
		t.Fatal("article navigation missing")
	}
	if article.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("withdrawal cache boundary absent")
	}
	if got := request(public, "GET", "/?category=Erste+Schritte&q=Freigegebener", nil, false); !strings.Contains(got.Body.String(), "Öffentlicher Titel") {
		t.Fatal("published content not searchable")
	}
	if got := request(public, "GET", "/?category=Andere&q=Freigegebener", nil, false); strings.Contains(got.Body.String(), "Öffentlicher Titel") {
		t.Fatal("category filter ignored")
	}
	if got := request(admin, "GET", "/?source=41", nil, true); !strings.Contains(got.Body.String(), `value="einrichtung"`) {
		t.Fatal("update metadata not prefilled")
	}
	if got := request(admin, "POST", "/articles/einrichtung/withdraw", url.Values{"csrf": {a.csrf}, "revision": {id}}, true); got.Code != 303 {
		t.Fatal("withdraw failed")
	}
	if got := request(public, "GET", "/articles/einrichtung", nil, false); got.Code != 404 {
		t.Fatal("withdrawn article still public")
	}
	if got := request(public, "GET", "/?q=Freigegebener", nil, false); strings.Contains(got.Body.String(), "Öffentlicher Titel") {
		t.Fatal("withdrawn article searchable")
	}
}

func TestApprovalConflictsAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "publish.db")
	s, err := openStore(path, "test-workspace")
	if err != nil {
		t.Fatal(err)
	}
	first, err := s.create(candidate(), "")
	if err != nil {
		t.Fatal(err)
	}
	stale, err := s.create(candidate(), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.approve(first.ID, "human-a"); err != nil {
		t.Fatal(err)
	}
	if err := s.approve(stale.ID, "human-b"); !errors.Is(err, errConflict) {
		t.Fatalf("stale approve: %v", err)
	}
	if err := s.withdraw(first.Slug, first.ID, "human-a"); err != nil {
		t.Fatal(err)
	}
	// Publishing then withdrawing is NOT the same state as never published.
	if err := s.approve(stale.ID, "human-b"); !errors.Is(err, errConflict) {
		t.Fatalf("ABA after withdrawal: %v", err)
	}
	changed := candidate()
	changed.Markdown = "Neue freigegebene Version"
	changed.Category = "API & Integrationen"
	latest, err := s.create(changed, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.approve(latest.ID, "human-c"); err != nil {
		t.Fatal(err)
	}
	if err := s.withdraw(latest.Slug, first.ID, "human-a"); !errors.Is(err, errConflict) {
		t.Fatal("stale withdrawal accepted")
	}
	if err := s.db.Close(); err != nil {
		t.Fatal(err)
	}
	if wrong, err := openStore(path, "other-workspace"); err == nil {
		wrong.db.Close()
		t.Fatal("publishing DB reclassified to another workspace")
	}
	s, err = openStore(path, "test-workspace")
	if err != nil {
		t.Fatal(err)
	}
	defer s.db.Close()
	got, err := s.current("einrichtung")
	if err != nil || got.Markdown != "Neue freigegebene Version" || got.Category != "API & Integrationen" {
		t.Fatalf("restart lost exact snapshot: %+v %v", got, err)
	}
	err = s.db.View(func(tx *bolt.Tx) error {
		count := 0
		err := tx.Bucket([]byte("audit")).ForEach(func(_, data []byte) error {
			var event publication
			if err := json.Unmarshal(data, &event); err != nil {
				return err
			}
			if event.Actor == "" || event.At.IsZero() {
				t.Fatal("missing audit identity")
			}
			count++
			return nil
		})
		if count != 3 {
			t.Fatalf("audit records: %d", count)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestAttachmentSnapshotAndPublicBoundary(t *testing.T) {
	a := testApp(t)
	dir := t.TempDir()
	file := filepath.Join(dir, "att_example")
	if err := os.WriteFile(file, []byte("approved bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	r := candidate()
	r.Markdown = "[Download](att:0)"
	r.Attachments = []protocol.Attachment{{FileId: "att_example", Filename: "manual.txt"}}
	if _, err := a.store.create(r, dir); err == nil {
		t.Fatal("unscoped blob copied")
	}
	grantDir := filepath.Join(dir, ".workspace-access", "att_example")
	if err := os.MkdirAll(grantDir, 0700); err != nil {
		t.Fatal(err)
	}
	otherHash := sha256.Sum256([]byte("other-workspace"))
	if err := os.WriteFile(filepath.Join(grantDir, hex.EncodeToString(otherHash[:])), []byte("other-workspace"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := a.store.create(r, dir); err == nil {
		t.Fatal("other workspace blob copied")
	}
	hash := sha256.Sum256([]byte("test-workspace"))
	grantPath := filepath.Join(grantDir, hex.EncodeToString(hash[:]))
	if err := os.WriteFile(grantPath, []byte("other-workspace"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := a.store.create(r, dir); err == nil {
		t.Fatal("invalid marker content accepted")
	}
	if err := os.WriteFile(grantPath, []byte("test-workspace"), 0600); err != nil {
		t.Fatal(err)
	}
	a.cfg.FilesDir = dir
	source := a.source.(*fixtureSource)
	note := source.assets[41]
	note.Payload, note.Attachments = r.Markdown, r.Attachments
	source.assets[41] = note
	draft, err := a.prepareDraft(context.Background(), candidate())
	if err != nil {
		t.Fatal(err)
	}
	if draft.Markdown != "[Download](att:0)" {
		t.Fatal("stored Markdown was rewritten")
	}
	path := "/media/" + draft.ID + "/att_example"
	if w := request(a.public(), "GET", path, nil, false); w.Code != 404 {
		t.Fatal("draft attachment public")
	}
	if w := request(a.admin(), "GET", path, nil, true); w.Code != 200 || w.Body.String() != "approved bytes" {
		t.Fatal("preview media unavailable")
	}
	if err := os.WriteFile(file, []byte("live file changed"), 0600); err != nil {
		t.Fatal(err)
	}
	note.Payload, note.Attachments = "Changed source", nil
	source.assets[41] = note
	if err := a.store.approve(draft.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	if article := request(a.public(), "GET", "/articles/einrichtung", nil, false); article.Code != 200 || !strings.Contains(article.Body.String(), `href="`+path+`"`) {
		t.Fatal("published attachment reference did not use the stored snapshot")
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	w := request(a.public(), "GET", path, nil, false)
	if w.Code != 200 || w.Body.String() != "approved bytes" {
		t.Fatal("media not independently retained")
	}
	if !strings.HasPrefix(w.Header().Get("Content-Disposition"), "attachment") {
		t.Fatal("unsafe file inline")
	}
	if w := request(a.public(), "GET", "/media/"+draft.ID+"/att_other", nil, false); w.Code != 404 {
		t.Fatal("unlisted media exposed")
	}
	if err := a.store.withdraw(draft.Slug, draft.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	if w := request(a.public(), "GET", path, nil, false); w.Code != 404 {
		t.Fatal("withdrawn attachment remains public")
	}
	r.Attachments[0].FileId = "att_../../outside"
	if _, err := a.store.create(r, dir); err == nil {
		t.Fatal("traversal attachment accepted")
	}
	r.Attachments[0].FileId = "att_example"
	r.Markdown = "No links"
	outside := filepath.Join(t.TempDir(), "private")
	os.WriteFile(outside, []byte("private"), 0600)
	os.Symlink(outside, file)
	if _, err := a.store.create(r, dir); err == nil {
		t.Fatal("symlink escape accepted")
	}
}

func TestRenderingSafetyAndLinks(t *testing.T) {
	r := candidate()
	r.ID = "snapshot"
	r.Markdown = "## Erste Schritte\n\n[Abschnitt](#erste-schritte)\n\n<script>alert(1)</script>\n\n![Bild](/files/att_image?inline=true)\n\n| A | B |\n| - | - |\n| 1 | 2 |"
	r.Attachments = []protocol.Attachment{{FileId: "att_image"}}
	body, toc, err := renderMarkdown(r)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), "<script") || !strings.Contains(string(body), `src="/media/snapshot/att_image"`) || !strings.Contains(string(body), "<table>") {
		t.Fatalf("unsafe/incomplete rendering: %s", body)
	}
	if len(toc) != 1 || toc[0].ID != "erste-schritte" || toc[0].Title != "Erste Schritte" {
		t.Fatalf("toc: %+v", toc)
	}
	for _, markdown := range []string{"[Intern](/notes/41)", "![Remote](https://example.com/tracker.png)", "[Missing](/files/att_unknown)", "[Bad](javascript:alert%281%29)", "[Protocol relative](//example.com/path)"} {
		r.Markdown = markdown
		if _, _, err := renderMarkdown(r); err == nil {
			t.Fatalf("unsafe link accepted: %s", markdown)
		}
	}
	for _, markdown := range []string{"[Website](https://example.com/docs)", "[Artikel](/articles/anderer-artikel)", "[Mail](mailto:help@example.com)"} {
		r.Markdown = markdown
		if _, _, err := renderMarkdown(r); err != nil {
			t.Fatal(err)
		}
	}
}

func TestIndexedAttachmentReferences(t *testing.T) {
	r := candidate()
	r.ID = "snapshot"
	r.Attachments = []protocol.Attachment{{FileId: "att_manual"}, {FileId: "att_unused"}, {FileId: "att_image"}}
	r.Markdown = "[Manual](att:0)\n\n![Diagram](att:2)"
	body, _, err := renderMarkdown(r)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `href="/media/snapshot/att_manual"`) || !strings.Contains(string(body), `src="/media/snapshot/att_image"`) {
		t.Fatalf("incorrect attachment indices: %s", body)
	}
	for _, target := range []string{"att:3", "att:-1", "att:+1", "att:", "att:1.0", "att:99999999999999999999999", "att:0?x=1", "att:0#fragment", "att://0", "att:%30", "att:01"} {
		for _, prefix := range []string{"[File]", "![Image]"} {
			r.Markdown = prefix + "(" + target + ")"
			if _, _, err := renderMarkdown(r); err == nil {
				t.Fatalf("invalid attachment reference accepted: %s", r.Markdown)
			}
		}
	}
}

func TestArticleLinkBoundary(t *testing.T) {
	for _, target := range []string{
		"/articles/../notes",
		"/articles/%2e%2e/notes",
		"/articles/example/extra",
		"/articles/example%2fextra",
		"/articles/",
		"/articles/Example",
		"/articles/" + strings.Repeat("a", 101),
	} {
		t.Run(target, func(t *testing.T) {
			r := candidate()
			r.Markdown = "[Artikel](" + target + ")"
			if _, _, err := renderMarkdown(r); err == nil {
				t.Fatalf("invalid article link accepted: %s", target)
			}
		})
	}
	for _, target := range []string{
		"/articles/example-2",
		"/articles/example#section",
		"/articles/example?q=guide#section",
		"/articles/" + strings.Repeat("a", 100),
		"#section",
	} {
		t.Run(target, func(t *testing.T) {
			r := candidate()
			r.Markdown = "[Artikel](" + target + ")"
			body, _, err := renderMarkdown(r)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(body), `href="`+target+`"`) {
				t.Fatalf("valid link was changed: %s", body)
			}
		})
	}
}

func TestInvalidDraftsFailClosed(t *testing.T) {
	a := testApp(t)
	for _, alter := range []func(*revision){func(r *revision) { r.Slug = "../escape" }, func(r *revision) { r.Category = " " }, func(r *revision) { r.Kind = "Unknown" }, func(r *revision) { r.Summary = strings.Repeat("x", 501) }} {
		r := candidate()
		alter(&r)
		if _, err := a.store.create(r, ""); err == nil {
			t.Fatal("invalid draft accepted")
		}
	}
	r, err := a.store.create(candidate(), "")
	if err != nil {
		t.Fatal(err)
	}
	other := candidate()
	other.SourceID = 99
	if _, err := a.store.create(other, ""); err == nil {
		t.Fatal("slug hijack accepted")
	}
	unicodeDraft := candidate()
	unicodeDraft.Summary = strings.Repeat("ä", 500)
	if _, err := a.store.create(unicodeDraft, ""); err != nil {
		t.Fatalf("500 multibyte characters rejected: %v", err)
	}
	unicodeDraft.Summary += "ä"
	if _, err := a.store.create(unicodeDraft, ""); err == nil {
		t.Fatal("501 characters accepted")
	}
	if err := a.store.discard(r.ID); err != nil {
		t.Fatal(err)
	}
	if err := a.store.approve(r.ID, "reviewer"); !errors.Is(err, errNotFound) {
		t.Fatal("discarded draft approved")
	}
	if w := request(a.admin(), "GET", "/", nil, false); w.Code != 401 {
		t.Fatal("admin not authenticated")
	}
	if w := request(a.public(), "GET", "/?q=%3Cscript%3E", nil, false); strings.Contains(w.Body.String(), "<script>") {
		t.Fatal("search XSS")
	}
}
