package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

//go:embed web/*
var web embed.FS

type config struct{ PublicAddr, AdminAddr, User, Password, Workspace, FilesDir, Brand, DataDir, NRCServer, BotSecret, JWTSecret, JWTIssuer, ReviewURL string }

type app struct {
	store     *store
	source    noteSource
	cfg       config
	csrf      string
	templates *template.Template
}

type category struct {
	Name     string
	Articles []revision
}
type page struct {
	Brand, Title, Mode, Query, Category, Error, CSRF string
	Categories                                       []category
	Articles, Drafts                                 []revision
	Article, Previous                                revision
	HTML, PreviousHTML                               template.HTML
	Sections                                         []section
	Notes                                            []protocol.Asset
	Next                                             string
	Changed, IsDraft                                 bool
}

func newApp(s *store, source noteSource, cfg config) *app {
	funcs := template.FuncMap{
		"date":      func(t time.Time) string { return t.In(time.FixedZone("UTC", 0)).Format("02.01.2006") },
		"noteTitle": func(a protocol.Asset) string { title, _, _ := noteMetadata(a); return title },
		"mediaURL":  func(r revision, a protocol.Attachment) string { return "/media/" + r.ID + "/" + a.FileId },
	}
	return &app{s, source, cfg, randomID(), template.Must(template.New("pages").Funcs(funcs).ParseFS(web, "web/*.html"))}
}

func noteMetadata(asset protocol.Asset) (string, string, string) {
	var meta struct{ Title, Teaser, Format string }
	if json.Unmarshal([]byte(asset.Preview), &meta) != nil {
		meta.Title = asset.Preview
	}
	if meta.Format == "" {
		meta.Format = "markdown"
	}
	return meta.Title, meta.Teaser, meta.Format
}

func (a *app) render(w http.ResponseWriter, status int, p page) {
	p.Brand = a.cfg.Brand
	p.CSRF = a.csrf
	var buf bytes.Buffer
	if err := a.templates.ExecuteTemplate(&buf, "page", p); err != nil {
		slog.Error("template", "error", err)
		http.Error(w, "Darstellung fehlgeschlagen", 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	w.Write(buf.Bytes())
}

func group(rows []revision) []category {
	m := map[string][]revision{}
	for _, r := range rows {
		m[r.Category] = append(m[r.Category], r)
	}
	names := []string{}
	for name := range m {
		names = append(names, name)
	}
	sort.Strings(names)
	groups := []category{}
	for _, name := range names {
		groups = append(groups, category{name, m[name]})
	}
	return groups
}

func (a *app) public() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("GET /style.css", style)
	mux.HandleFunc("GET /{$}", a.home)
	mux.HandleFunc("GET /articles/{slug}", a.article)
	mux.HandleFunc("GET /media/{revision}/{file}", func(w http.ResponseWriter, r *http.Request) { a.media(w, r, true) })
	return headers(mux, false)
}

func (a *app) admin() http.Handler {
	mux := http.NewServeMux()
	agent := a.agentAPI()
	mux.HandleFunc("GET /style.css", style)
	mux.HandleFunc("GET /{$}", a.dashboard)
	mux.HandleFunc("GET /notes", a.notes)
	mux.HandleFunc("GET /drafts/{id}", a.draft)
	mux.HandleFunc("POST /drafts", a.createDraft)
	mux.HandleFunc("POST /drafts/{id}/approve", func(w http.ResponseWriter, r *http.Request) {
		if r.PostForm.Get("confirmed") != "yes" {
			a.action(w, r, errors.New("Bitte Text, Links und Anhänge ausdrücklich bestätigen."))
			return
		}
		a.action(w, r, a.store.approve(r.PathValue("id"), a.cfg.User))
	})
	mux.HandleFunc("POST /drafts/{id}/discard", func(w http.ResponseWriter, r *http.Request) { a.action(w, r, a.store.discard(r.PathValue("id"))) })
	mux.HandleFunc("POST /articles/{slug}/withdraw", func(w http.ResponseWriter, r *http.Request) {
		a.action(w, r, a.store.withdraw(r.PathValue("slug"), r.FormValue("revision"), a.cfg.User))
	})
	mux.HandleFunc("GET /media/{revision}/{file}", func(w http.ResponseWriter, r *http.Request) { a.media(w, r, false) })
	return headers(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			agent.ServeHTTP(w, r)
			return
		}
		user, password, ok := r.BasicAuth()
		u, p := sha256.Sum256([]byte(user)), sha256.Sum256([]byte(password))
		wantU, wantP := sha256.Sum256([]byte(a.cfg.User)), sha256.Sum256([]byte(a.cfg.Password))
		if !ok || a.cfg.User == "" || a.cfg.Password == "" || subtle.ConstantTimeCompare(u[:], wantU[:])&subtle.ConstantTimeCompare(p[:], wantP[:]) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="Knowledge publishing", charset="UTF-8"`)
			http.Error(w, "Anmeldung erforderlich", http.StatusUnauthorized)
			return
		}
		if r.Method == http.MethodPost {
			r.Body = http.MaxBytesReader(w, r.Body, 128<<10)
			if err := r.ParseForm(); err != nil || subtle.ConstantTimeCompare([]byte(r.PostForm.Get("csrf")), []byte(a.csrf)) != 1 {
				http.Error(w, "Ungültige Freigabeanfrage. Seite neu laden.", 403)
				return
			}
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
				http.Error(w, "Cross-site request denied", 403)
				return
			}
		}
		mux.ServeHTTP(w, r)
	}), true)
}

func headers(next http.Handler, admin bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
		// Withdrawal must not leave a browser/CDN copy available from this origin.
		w.Header().Set("Cache-Control", "no-store")
		if admin {
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
		}
		next.ServeHTTP(w, r)
	})
}

func style(w http.ResponseWriter, r *http.Request) {
	data, _ := web.ReadFile("web/style.css")
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	w.Write(data)
}

func (a *app) home(w http.ResponseWriter, r *http.Request) {
	rows, err := a.store.entries("published")
	if err != nil {
		http.Error(w, "Knowledge Base nicht verfügbar", 503)
		return
	}
	q, cat := strings.TrimSpace(r.URL.Query().Get("q")), r.URL.Query().Get("category")
	p := page{Title: "Knowledge Base", Mode: "home", Query: q, Category: cat, Categories: group(rows)}
	for _, row := range rows {
		if cat != "" && row.Category != cat {
			continue
		}
		if q != "" && !strings.Contains(strings.ToLower(row.Title+" "+row.Summary+" "+row.Markdown), strings.ToLower(q)) {
			continue
		}
		p.Articles = append(p.Articles, row)
	}
	a.render(w, 200, p)
}

func (a *app) article(w http.ResponseWriter, r *http.Request) {
	article, err := a.store.current(r.PathValue("slug"))
	if errors.Is(err, errNotFound) {
		a.render(w, 404, page{Mode: "error", Title: "Artikel nicht gefunden", Error: "Dieser Artikel ist nicht veröffentlicht oder wurde zurückgezogen."})
		return
	}
	if err != nil {
		http.Error(w, "Knowledge Base nicht verfügbar", 503)
		return
	}
	content, sections, err := renderMarkdown(article)
	if err != nil {
		http.Error(w, "Artikel nicht verfügbar", 500)
		return
	}
	rows, err := a.store.entries("published")
	if err != nil {
		http.Error(w, "Knowledge Base nicht verfügbar", 503)
		return
	}
	a.render(w, 200, page{Title: article.Title, Mode: "article", Article: article, HTML: content, Sections: sections, Categories: group(rows)})
}

func (a *app) dashboard(w http.ResponseWriter, r *http.Request) {
	rows, err := a.store.entries("published")
	if err != nil {
		http.Error(w, "Speicher nicht verfügbar", 500)
		return
	}
	drafts, err := a.store.entries("drafts")
	if err != nil {
		http.Error(w, "Speicher nicht verfügbar", 500)
		return
	}
	p := page{Title: "Veröffentlichungen", Mode: "admin", Articles: rows, Drafts: drafts, Categories: group(rows)}
	if value := r.URL.Query().Get("source"); value != "" {
		id, err := strconv.ParseUint(value, 10, 64)
		if err != nil || id == 0 {
			a.action(w, r, errors.New("Ungültige Notiz-ID"))
			return
		}
		asset, err := a.source.get(r.Context(), id)
		if err != nil {
			a.render(w, 502, page{Mode: "error", Title: "Notiz nicht verfügbar", Error: err.Error()})
			return
		}
		title, summary, format := noteMetadata(asset)
		if format != "markdown" {
			a.action(w, r, errors.New("Nur Markdown-Notizen können veröffentlicht werden."))
			return
		}
		p.Article = revision{SourceID: id, Title: title, Summary: summary, Kind: "Anleitung"}
		for _, row := range rows {
			if row.SourceID == id {
				p.Article = row
				break
			}
		}
	}
	a.render(w, 200, p)
}

func (a *app) notes(w http.ResponseWriter, r *http.Request) {
	updated, _ := strconv.ParseInt(r.URL.Query().Get("updated"), 10, 64)
	id, _ := strconv.ParseUint(r.URL.Query().Get("id"), 10, 64)
	notes, err := a.source.list(r.Context(), updated, id, r.URL.Query().Has("id"))
	if err != nil {
		a.render(w, 502, page{Mode: "error", Title: "NRC nicht erreichbar", Error: err.Error()})
		return
	}
	var next string
	if notes.HasMore {
		next = fmt.Sprintf("/notes?updated=%d&id=%d", notes.NextCursorUpdatedAt, notes.NextCursorAssetID)
	}
	a.render(w, 200, page{Title: "Notiz auswählen", Mode: "notes", Notes: notes.Assets, Next: next})
}

func (a *app) createDraft(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseUint(r.FormValue("source"), 10, 64)
	if err != nil || id == 0 {
		a.action(w, r, errors.New("Ungültige Notiz-ID"))
		return
	}
	draft, err := a.prepareDraft(r.Context(), revision{SourceID: id, Slug: r.FormValue("slug"), Title: r.FormValue("title"), Summary: r.FormValue("summary"), Category: r.FormValue("category"), Kind: r.FormValue("kind"), CreatedBy: a.cfg.User})
	if err != nil {
		a.action(w, r, err)
		return
	}
	http.Redirect(w, r, "/drafts/"+draft.ID, http.StatusSeeOther)
}

func (a *app) draft(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	draft, err := a.store.revision(id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	drafts, err := a.store.entries("drafts")
	if err != nil {
		http.Error(w, "Speicher nicht verfügbar", 500)
		return
	}
	active := false
	for _, d := range drafts {
		if d.ID == id {
			active = true
		}
	}
	if !active {
		http.NotFound(w, r)
		return
	}
	content, sections, err := renderMarkdown(draft)
	if err != nil {
		a.action(w, r, err)
		return
	}
	previous, err := a.store.current(draft.Slug)
	if err != nil && !errors.Is(err, errNotFound) {
		http.Error(w, "Speicher nicht verfügbar", 500)
		return
	}
	previousHTML := template.HTML("")
	if previous.ID != "" {
		previousHTML, _, err = renderMarkdown(previous)
		if err != nil {
			a.action(w, r, err)
			return
		}
	}
	p := page{Title: "Entwurf prüfen", Mode: "draft", Article: draft, Previous: previous, HTML: content, PreviousHTML: previousHTML, Sections: sections, IsDraft: true}
	if asset, err := a.source.get(r.Context(), draft.SourceID); err == nil {
		p.Changed = asset.UpdatedAt != draft.SourceUpdated || asset.Payload != draft.Markdown
	} else {
		p.Error = "Aktueller NRC-Stand konnte nicht gelesen werden. Die Vorschau zeigt weiterhin den gespeicherten Entwurf."
	}
	head, err := a.store.head(draft.Slug)
	if err != nil {
		http.Error(w, "Speicher nicht verfügbar", 500)
		return
	}
	if draft.Base != head {
		p.Error = "Seit Erstellung wurde eine andere Version veröffentlicht oder der Artikel zurückgezogen. Diesen Entwurf verwerfen und neu erstellen."
		p.IsDraft = false
	}
	a.render(w, 200, p)
}

func (a *app) action(w http.ResponseWriter, r *http.Request, err error) {
	if err != nil {
		status := 400
		if errors.Is(err, errConflict) {
			status = 409
		}
		a.render(w, status, page{Mode: "error", Title: "Aktion nicht ausgeführt", Error: err.Error()})
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *app) media(w http.ResponseWriter, r *http.Request, public bool) {
	data, attachment, err := a.store.media(r.PathValue("revision"), r.PathValue("file"), public)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	contentType := http.DetectContentType(data)
	disposition := "attachment"
	switch contentType {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		disposition = "inline"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
	w.Header().Set("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": attachment.Filename}))
	http.ServeContent(w, r, attachment.Filename, time.Time{}, bytes.NewReader(data))
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	cfg := config{PublicAddr: env("PUBLISH_ADDR", ":8093"), AdminAddr: env("PUBLISH_ADMIN_ADDR", "127.0.0.1:8094"), User: os.Getenv("PUBLISH_ADMIN_USER"), Password: os.Getenv("PUBLISH_ADMIN_PASSWORD"), Workspace: os.Getenv("NRC_WORKSPACE"), FilesDir: os.Getenv("PUBLISH_FILES_DIR"), Brand: env("PUBLISH_BRAND", "NRC"), DataDir: env("PUBLISH_DATA_DIR", "data"), NRCServer: env("NRC_SERVER", "ws://localhost:8080"), BotSecret: os.Getenv("NRC_BOT_SECRET")}
	cfg.JWTSecret = os.Getenv("NRC_JWT_SECRET")
	cfg.JWTIssuer = env("NRC_JWT_ISSUER", "nrc-tailscale-proxy")
	cfg.ReviewURL = strings.TrimRight(os.Getenv("PUBLISH_REVIEW_URL"), "/")
	if cfg.JWTSecret == "dev-insecure-nrc-jwt-secret" {
		slog.Error("publishing requires a non-default NRC_JWT_SECRET")
		os.Exit(1)
	}
	if cfg.User == "" || len(cfg.Password) < 16 || cfg.Workspace == "" || cfg.BotSecret == "" {
		slog.Error("NRC_WORKSPACE, NRC_BOT_SECRET, PUBLISH_ADMIN_USER and PUBLISH_ADMIN_PASSWORD (at least 16 characters) are required")
		os.Exit(1)
	}
	if err := os.MkdirAll(cfg.DataDir, 0700); err != nil {
		slog.Error("data directory", "error", err)
		os.Exit(1)
	}
	s, err := openStore(filepath.Join(cfg.DataDir, "publish.db"), cfg.Workspace)
	if err != nil {
		slog.Error("open store", "error", err)
		os.Exit(1)
	}
	defer s.db.Close()
	a := newApp(s, nrcSource{cfg.NRCServer, cfg.Workspace, cfg.BotSecret}, cfg)
	servers := []*http.Server{{Addr: cfg.PublicAddr, Handler: a.public(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}, {Addr: cfg.AdminAddr, Handler: a.admin(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	errorsCh := make(chan error, 2)
	for _, server := range servers {
		go func() { slog.Info("listening", "address", server.Addr); errorsCh <- server.ListenAndServe() }()
	}
	select {
	case <-ctx.Done():
	case err := <-errorsCh:
		if !errors.Is(err, http.ErrServerClosed) {
			slog.Error("HTTP server", "error", err)
		}
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, server := range servers {
		server.Shutdown(shutdown)
	}
}
