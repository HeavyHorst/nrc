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
	return newApp(s, &fixtureSource{map[uint64]protocol.Asset{41: {AssetType: 5, AssetID: 41, UpdatedAt: 100, Preview: `{"title":"Interner Titel","format":"markdown"}`, Payload: "## Einrichtung\n\nFreigegebener Inhalt."}}}, config{User: "reviewer", Password: "only-for-tests-not-a-secret", Brand: "Dokumentation"})
}

func TestBrandingHTTP(t *testing.T) {
	a := testApp(t)
	plain := request(a.public(), "GET", "/", nil, false).Body.String()
	if strings.Contains(plain, "NRC") || strings.Contains(plain, "Wissen") || strings.Contains(plain, `<footer`) {
		t.Fatal("default site contains fixed branding or footer")
	}
	a.cfg.Brand = "Example & Co"
	a.cfg.FooterText = "© Example <Team>"
	a.cfg.ImprintURL = "https://example.org/impressum"
	a.cfg.PrivacyURL = "/articles/datenschutz"
	a.cfg.TermsURL = "https://example.org/terms"
	a.cfg.ContactURL = "https://example.org/contact"
	a.cfg.ThemeCSS = []byte(":root { --accent: #123456; }")
	for _, handler := range []http.Handler{a.public(), a.admin()} {
		got := request(handler, "GET", "/", nil, true)
		for _, want := range []string{"Example &amp; Co", "© Example &lt;Team&gt;", `href="https://example.org/impressum"`, `href="/articles/datenschutz"`, `href="https://example.org/terms"`, `href="https://example.org/contact"`} {
			if !strings.Contains(got.Body.String(), want) {
				t.Fatalf("branding missing %q", want)
			}
		}
		css := request(handler, "GET", "/style.css", nil, true)
		if !strings.HasSuffix(css.Body.String(), string(a.cfg.ThemeCSS)) {
			t.Fatal("theme does not override base stylesheet")
		}
	}
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

func TestDashboardLatestArticleHTTP(t *testing.T) {
	a := testApp(t)
	create := func(sourceID uint64, slug, title string) revision {
		t.Helper()
		r := candidate()
		r.SourceID = sourceID
		r.Slug, r.Title = slug, title
		draft, err := a.store.create(r, "")
		if err != nil {
			t.Fatal(err)
		}
		return draft
	}
	live := create(41, "einrichtung", "Veröffentlichter Titel")
	if err := a.store.approve(live.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	old := create(41, "einrichtung", "Alter Entwurf")
	oldURL := create(41, "alte-url", "Frühere URL-Variante")
	latest := create(41, "neue-url", "Zweiter Titel")
	// Same title, different source: this remains a separate article.
	other := create(99, "zweite-url", "Zweiter Titel")
	body := request(a.admin(), "GET", "/", nil, true).Body.String()
	for _, id := range []string{latest.ID, other.ID} {
		if strings.Count(body, `href="/drafts/`+id+`"`) != 1 {
			t.Fatalf("latest draft %s missing or duplicated", id)
		}
	}
	if strings.Contains(body, `href="/drafts/`+old.ID+`"`) || strings.Contains(body, oldURL.ID) || strings.Count(body, `href="/drafts/`) != 2 {
		t.Fatal("dashboard includes superseded drafts")
	}
	for _, label := range []string{`class="pill">Update`, `class="pill">Neuer Artikel`, `class="count">2`} {
		if !strings.Contains(body, label) {
			t.Fatalf("dashboard missing %s", label)
		}
	}
	for _, tc := range []struct{ id, label string }{{latest.ID, "Update"}, {other.ID, "Neuer Artikel"}} {
		body := request(a.admin(), "GET", "/drafts/"+tc.id, nil, true).Body.String()
		if !strings.Contains(body, `class="pill">`+tc.label) {
			t.Fatalf("review missing %s", tc.label)
		}
	}
	if err := a.store.approve(latest.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	body = request(a.admin(), "GET", "/", nil, true).Body.String()
	if strings.Count(body, `href="/drafts/`) != 1 || strings.Contains(body, old.ID) {
		t.Fatal("older draft reappeared after publication")
	}
}

func TestPublishedSourceIdentityHTTP(t *testing.T) {
	a := testApp(t)
	public, admin := a.public(), a.admin()
	create := func(sourceID uint64, slug, body string) revision {
		t.Helper()
		r := candidate()
		r.SourceID, r.Slug, r.Markdown = sourceID, slug, body
		draft, err := a.store.create(r, "")
		if err != nil {
			t.Fatal(err)
		}
		return draft
	}
	old := create(5351, "alte-statistiken", "Ursprünglicher Artikel")
	for _, id := range []string{"5351", "0", "nope", "18446744073709551616"} {
		if got := request(public, "GET", "/articles/by-note/"+id, nil, false); got.Code != 404 {
			t.Fatal("invalid or unpublished source ID is publicly reachable")
		}
	}
	if err := a.store.approve(old.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	reader := create(41, "anleitung", "Siehe [note:5351].")
	if err := a.store.approve(reader.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	latest := create(5351, "neue-statistiken", "Aktueller Artikel")
	stale := create(5351, "dritte-url", "Überholter Entwurf")
	if _, err := a.store.createReview([]string{latest.ID, stale.ID}); err == nil {
		t.Fatal("two URLs for the same source accepted in a group")
	}
	preview := request(admin, "GET", "/drafts/"+latest.ID, nil, true)
	if preview.Code != 200 || !strings.Contains(preview.Body.String(), "Ursprünglicher Artikel") || !strings.Contains(preview.Body.String(), `class="pill">Update`) {
		t.Fatal("URL change not shown as update to the same public article")
	}
	if err := a.store.approve(latest.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	if err := a.store.approve(stale.ID, "reviewer"); !errors.Is(err, errConflict) {
		t.Fatalf("stale alternate URL bypassed source-level conflict: %v", err)
	}
	rows, err := a.store.entries("published")
	if err != nil || len(rows) != 2 {
		t.Fatalf("publication duplicated source or removed unrelated article: %+v %v", rows, err)
	}
	for _, row := range rows {
		if row.SourceID == 5351 && row.ID != latest.ID {
			t.Fatal("old source version still published")
		}
	}
	for _, path := range []string{"/articles/by-note/5351", "/articles/alte-statistiken"} {
		got := request(public, "GET", path, nil, false)
		if got.Code != 302 || got.Header().Get("Location") != "/articles/neue-statistiken" || got.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("source URL does not redirect to current article: %d %v", got.Code, got.Header())
		}
	}
	got := request(public, "GET", "/articles/anleitung", nil, false)
	if got.Code != 200 || !strings.Contains(got.Body.String(), `href="/articles/by-note/5351"`) {
		t.Fatal("published reference lost its stable source URL")
	}
	if err := a.store.withdraw(old.Slug, old.ID, "reviewer"); !errors.Is(err, errConflict) {
		t.Fatal("stale withdrawal removed moved article")
	}
	if err := a.store.withdraw(latest.Slug, latest.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/articles/by-note/5351", "/articles/alte-statistiken", "/articles/neue-statistiken"} {
		if got := request(public, "GET", path, nil, false); got.Code != 404 {
			t.Fatal("withdrawn source is still publicly reachable")
		}
	}
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
	if article := request(a.public(), "GET", "/articles/einrichtung", nil, false); strings.Contains(article.Body.String(), "Dateien zum Artikel") {
		t.Fatal("article repeats its inline download in an attachment list")
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
	body, toc, _, err := renderMarkdown(r)
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
		if _, _, _, err := renderMarkdown(r); err == nil {
			t.Fatalf("unsafe link accepted: %s", markdown)
		}
	}
	for _, markdown := range []string{"[Website](https://example.com/docs)", "[Artikel](/articles/anderer-artikel)", "[Mail](mailto:help@example.com)"} {
		r.Markdown = markdown
		if _, _, _, err := renderMarkdown(r); err != nil {
			t.Fatal(err)
		}
	}
}

func TestIndexedAttachmentReferences(t *testing.T) {
	r := candidate()
	r.ID = "snapshot"
	r.Attachments = []protocol.Attachment{{FileId: "att_manual"}, {FileId: "att_unused"}, {FileId: "att_image"}}
	r.Markdown = "[Manual](att:0)\n\n![Diagram](att:2)"
	body, _, additional, err := renderMarkdown(r)
	if err != nil {
		t.Fatal(err)
	}
	if len(additional) != 1 || additional[0].FileId != "att_unused" {
		t.Fatalf("embedded attachments listed again: %+v", additional)
	}
	if !strings.Contains(string(body), `href="/media/snapshot/att_manual"`) || !strings.Contains(string(body), `src="/media/snapshot/att_image"`) {
		t.Fatalf("incorrect attachment indices: %s", body)
	}
	r.Markdown = "![Diagram](/files/att_image?inline=true#preview)\n\n[Manual](/files/att_manual)\n\n`[Unused](att:1)`\n\n```markdown\n![Unused](/files/att_unused)\n```"
	_, _, additional, err = renderMarkdown(r)
	if err != nil || len(additional) != 1 || additional[0].FileId != "att_unused" {
		t.Fatalf("rendered links and code examples distinguished incorrectly: %+v %v", additional, err)
	}
	for _, target := range []string{"att:3", "att:-1", "att:+1", "att:", "att:1.0", "att:99999999999999999999999", "att:0?x=1", "att:0#fragment", "att://0", "att:%30", "att:01"} {
		for _, prefix := range []string{"[File]", "![Image]"} {
			r.Markdown = prefix + "(" + target + ")"
			if _, _, _, err := renderMarkdown(r); err == nil {
				t.Fatalf("invalid attachment reference accepted: %s", r.Markdown)
			}
		}
	}
}

func TestPublishedNoteReferences(t *testing.T) {
	a := testApp(t)
	// Simulate a snapshot written before reference resolution existed.
	legacy := candidate()
	legacy.ID, legacy.Slug, legacy.Markdown = "legacy", "legacy", "Siehe [note:999]."
	if err := a.store.db.Update(func(tx *bolt.Tx) error {
		if err := putJSON(tx.Bucket([]byte("revisions")), legacy.ID, legacy); err != nil {
			return err
		}
		if err := tx.Bucket([]byte("published")).Put([]byte(legacy.Slug), []byte(legacy.ID)); err != nil {
			return err
		}
		return tx.Bucket([]byte("drafts")).Put([]byte(legacy.ID), []byte(legacy.ID))
	}); err != nil {
		t.Fatal(err)
	}
	if got := request(a.public(), "GET", "/articles/legacy", nil, false); got.Code != 200 || !strings.Contains(got.Body.String(), "Siehe [note:999].") {
		t.Fatal("legacy article no longer readable")
	}
	if err := a.store.approve(legacy.ID, "human"); err == nil {
		t.Fatal("legacy unresolved draft approved")
	}
	target := candidate()
	target.SourceID, target.Slug, target.Title = 18446744073709551615, "ziel-artikel", "Öffentlich & geprüft"
	published, err := a.store.create(target, "")
	if err != nil {
		t.Fatal(err)
	}
	source := a.source.(*fixtureSource)
	note := source.assets[41]
	note.Payload = "Siehe [note:18446744073709551615] und **[note:18446744073709551615]**.\n\n`[note:999]`\n\n```text\n[note:998]\n```"
	source.assets[41] = note
	unresolved, err := a.prepareDraft(context.Background(), candidate())
	if err != nil {
		t.Fatalf("unpublished target blocked draft creation: %v", err)
	}
	if err := a.store.approve(unresolved.ID, "human"); err == nil {
		t.Fatal("unresolved target accepted at approval")
	}
	if got := request(a.admin(), "GET", "/drafts/"+unresolved.ID, nil, true); got.Code != 200 || !strings.Contains(got.Body.String(), "Linkziele fehlen:") {
		t.Fatal("missing target not shown in review")
	}
	if err := a.store.approve(published.ID, "human"); err != nil {
		t.Fatal(err)
	}
	resolvedReview := request(a.admin(), "POST", "/reviews", url.Values{"csrf": {a.csrf}, "draft": {unresolved.ID}}, true)
	if resolvedReview.Code != 303 {
		t.Fatal("draft could not resolve a newly published target")
	}
	if got := request(a.admin(), "GET", resolvedReview.Header().Get("Location"), nil, true); got.Code != 200 || !strings.Contains(got.Body.String(), `href="/articles/by-note/18446744073709551615">Öffentlich &amp; geprüft</a>`) {
		t.Fatal("newly published target missing from review")
	}
	draft, err := a.prepareDraft(context.Background(), candidate())
	if err != nil {
		t.Fatal(err)
	}
	link := `<a href="/articles/by-note/18446744073709551615">Öffentlich &amp; geprüft</a>`
	preview := request(a.admin(), "GET", "/drafts/"+draft.ID, nil, true)
	if preview.Code != 200 || strings.Count(preview.Body.String(), link) != 2 || !strings.Contains(preview.Body.String(), "<code>[note:999]</code>") {
		t.Fatalf("incorrect review links: %d %s", preview.Code, preview.Body.String())
	}
	if got := request(a.admin(), "GET", "/articles/ziel-artikel", nil, true); got.Code != 200 || !strings.Contains(got.Body.String(), "Öffentlich &amp; geprüft") {
		t.Fatalf("review target unavailable: %d %s", got.Code, got.Body.String())
	}
	if got := request(a.admin(), "GET", "/articles/ziel-artikel", nil, false); got.Code != 401 {
		t.Fatal("review article accessible without authentication")
	}
	if got := request(a.admin(), "GET", "/articles/einrichtung", nil, true); got.Code != 404 {
		t.Fatal("unpublished draft accessible as review article")
	}
	// Changing the public target title cannot alter links already reviewed.
	target.Title = "Neuer Titel"
	updated, err := a.store.create(target, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := a.store.approve(updated.ID, "human"); err != nil {
		t.Fatal(err)
	}
	approve := url.Values{"csrf": {a.csrf}, "confirmed": {"yes"}}
	if got := request(a.admin(), "POST", "/drafts/"+draft.ID+"/approve", approve, true); got.Code != 303 {
		t.Fatalf("approve: %d %s", got.Code, got.Body.String())
	}
	article := request(a.public(), "GET", "/articles/einrichtung", nil, false)
	if article.Code != 200 || strings.Count(article.Body.String(), link) != 2 {
		t.Fatalf("published links changed: %d %s", article.Code, article.Body.String())
	}
	second, err := a.prepareDraft(context.Background(), candidate())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.store.withdraw(updated.Slug, updated.ID, "human"); err != nil {
		t.Fatal(err)
	}
	if got := request(a.admin(), "POST", "/drafts/"+second.ID+"/approve", approve, true); got.Code != 400 {
		t.Fatal("withdrawn target accepted at approval")
	}
	note.Payload = "[note:999]"
	source.assets[41] = note
	missing, err := a.prepareDraft(context.Background(), candidate())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.store.createReview([]string{missing.ID}); err == nil {
		t.Fatal("unknown link target accepted in final review")
	}
	for _, token := range []string{"[note:0]", "[note:18446744073709551616]"} {
		note.Payload = token
		source.assets[41] = note
		if _, err := a.prepareDraft(context.Background(), candidate()); err == nil {
			t.Fatalf("invalid/missing reference accepted: %s", token)
		}
	}
	for _, slug := range []string{"ziel-artikel", "zweites-ziel"} {
		target.Slug = slug
		r, err := a.store.create(target, "")
		if err != nil {
			t.Fatal(err)
		}
		if err := a.store.approve(r.ID, "human"); err != nil {
			t.Fatal(err)
		}
	}
	note.Payload = "[note:18446744073709551615]"
	source.assets[41] = note
	resolved, err := a.prepareDraft(context.Background(), candidate())
	if err != nil || resolved.NoteReferences["18446744073709551615"].URL != "/articles/by-note/18446744073709551615" {
		t.Fatalf("source-ID link failed after URL change: %v", err)
	}
}

func TestGroupPublishingHTTP(t *testing.T) {
	a := testApp(t)
	admin, public := a.admin(), a.public()
	source := a.source.(*fixtureSource)
	for id, body := range map[uint64]string{41: "Alpha verweist auf [note:5348].", 5348: "Beta verweist auf [note:41]."} {
		note := source.assets[41]
		note.AssetID, note.Payload = id, body
		source.assets[id] = note
	}
	create := func(id, slug, title string) string {
		t.Helper()
		got := request(admin, "POST", "/drafts", url.Values{"csrf": {a.csrf}, "source": {id}, "slug": {slug}, "title": {title}, "category": {"Test"}, "kind": {"Anleitung"}}, true)
		if got.Code != 303 {
			t.Fatalf("draft: %d %s", got.Code, got.Body.String())
		}
		return strings.TrimPrefix(got.Header().Get("Location"), "/drafts/")
	}
	alpha := create("41", "alpha", "Alpha")
	beta := create("5348", "beta", "Beta & Details")
	form := url.Values{"csrf": {a.csrf}, "draft": {alpha, beta}}
	if got := request(admin, "POST", "/reviews", form, false); got.Code != 401 {
		t.Fatal("anonymous group preparation accepted")
	}
	if got := request(admin, "POST", "/reviews", url.Values{"draft": {alpha, beta}}, true); got.Code != 403 {
		t.Fatal("group preparation without CSRF accepted")
	}
	for _, ids := range [][]string{nil, {alpha}, {alpha, alpha}} {
		got := request(admin, "POST", "/reviews", url.Values{"csrf": {a.csrf}, "draft": ids}, true)
		if got.Code != 400 {
			t.Fatalf("invalid/incomplete selection accepted: %v", ids)
		}
	}
	got := request(admin, "POST", "/reviews", form, true)
	if got.Code != 303 {
		t.Fatalf("prepare review: %d %s", got.Code, got.Body.String())
	}
	path := got.Header().Get("Location")
	for _, slug := range []string{"alpha", "beta"} {
		if got := request(public, "GET", "/articles/"+slug, nil, false); got.Code != 404 {
			t.Fatal("group preparation published an article")
		}
	}
	got = request(admin, "GET", path, nil, true)
	for _, link := range []string{`href="/articles/by-note/5348">Beta &amp; Details</a>`, `href="/articles/by-note/41">Alpha</a>`} {
		if got.Code != 200 || !strings.Contains(got.Body.String(), link) {
			t.Fatalf("review missing resolved link %s: %s", link, got.Body.String())
		}
	}
	if got := request(public, "GET", path, nil, false); got.Code != 404 {
		t.Fatal("public listener exposes group review")
	}
	if got := request(admin, "POST", path+"/approve", form, true); got.Code != 400 {
		t.Fatal("unconfirmed group approved")
	}
	// A newer pending draft must not change the already-reviewed title or body.
	create("5348", "beta", "Ungeprüfter neuer Titel")
	// The stored review must survive a restart without resolving links again.
	dbPath := a.store.db.Path()
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := openStore(dbPath, "test-workspace")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reopened.db.Close() })
	a = newApp(reopened, a.source, a.cfg)
	admin, public = a.admin(), a.public()
	if got := request(admin, "GET", path, nil, true); got.Code != 200 || !strings.Contains(got.Body.String(), `href="/articles/by-note/5348">Beta &amp; Details</a>`) {
		t.Fatal("stored review changed after restart")
	}
	approve := url.Values{"csrf": {a.csrf}, "confirmed": {"yes"}}
	if got := request(admin, "POST", path+"/approve", approve, true); got.Code != 303 {
		t.Fatalf("group approve: %d %s", got.Code, got.Body.String())
	}
	for slug, link := range map[string]string{"alpha": `href="/articles/by-note/5348">Beta &amp; Details</a>`, "beta": `href="/articles/by-note/41">Alpha</a>`} {
		got := request(public, "GET", "/articles/"+slug, nil, false)
		if got.Code != 200 || !strings.Contains(got.Body.String(), link) || strings.Contains(got.Body.String(), "Ungeprüfter neuer Titel") {
			t.Fatalf("published content differs from review: %s", got.Body.String())
		}
	}
	// If one selected article is published elsewhere, no other member may commit.
	alpha = create("41", "alpha", "Alpha Update")
	beta = create("5348", "beta", "Beta Update")
	got = request(admin, "POST", "/reviews", url.Values{"csrf": {a.csrf}, "draft": {alpha, beta}}, true)
	if got.Code != 303 {
		t.Fatal(got.Body.String())
	}
	path = got.Header().Get("Location")
	concurrent := create("5348", "beta", "Separat veröffentlicht")
	if err := a.store.approve(concurrent, "human"); err != nil {
		t.Fatal(err)
	}
	if got := request(admin, "POST", path+"/approve", approve, true); got.Code != 409 {
		t.Fatalf("stale group: %d %s", got.Code, got.Body.String())
	}
	current, err := a.store.current("alpha")
	if err != nil || current.Title != "Alpha" {
		t.Fatal("stale group partially committed")
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
		"/articles/by-note/0",
		"/articles/by-note/123/extra",
		"/articles/by-note/18446744073709551616",
	} {
		t.Run(target, func(t *testing.T) {
			r := candidate()
			r.Markdown = "[Artikel](" + target + ")"
			if _, _, _, err := renderMarkdown(r); err == nil {
				t.Fatalf("invalid article link accepted: %s", target)
			}
		})
	}
	for _, target := range []string{
		"/articles/example-2",
		"/articles/example#section",
		"/articles/example?q=guide#section",
		"/articles/" + strings.Repeat("a", 100),
		"/articles/by-note/5351",
		"/articles/by-note/18446744073709551615",
		"#section",
	} {
		t.Run(target, func(t *testing.T) {
			r := candidate()
			r.Markdown = "[Artikel](" + target + ")"
			body, _, _, err := renderMarkdown(r)
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
