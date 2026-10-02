package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type agentDraft struct {
	NoteID   uint64 `json:"note_id,string"`
	Slug     string `json:"slug"`
	Title    string `json:"title"`
	Summary  string `json:"summary"`
	Category string `json:"category"`
	Kind     string `json:"kind"`
}

type agentRevision struct {
	ID          string                `json:"id"`
	NoteID      string                `json:"note_id"`
	Slug        string                `json:"slug"`
	Title       string                `json:"title"`
	Summary     string                `json:"summary"`
	Category    string                `json:"category"`
	Kind        string                `json:"kind"`
	CreatedAt   time.Time             `json:"created_at"`
	CreatedBy   string                `json:"created_by"`
	Markdown    string                `json:"markdown,omitempty"`
	Attachments []protocol.Attachment `json:"attachments,omitempty"`
}

func agentView(r revision, content bool) agentRevision {
	v := agentRevision{ID: r.ID, NoteID: strconv.FormatUint(r.SourceID, 10), Slug: r.Slug, Title: r.Title, Summary: r.Summary, Category: r.Category, Kind: r.Kind, CreatedAt: r.CreatedAt, CreatedBy: r.CreatedBy}
	if content {
		v.Markdown, v.Attachments = r.Markdown, r.Attachments
	}
	return v
}

func (a *app) prepareDraft(ctx context.Context, r revision) (revision, error) {
	if r.SourceID == 0 {
		return r, errors.New("Ungültige Notiz-ID")
	}
	asset, err := a.source.get(ctx, r.SourceID)
	if err != nil {
		return r, err
	}
	_, _, format := noteMetadata(asset)
	if format != "markdown" {
		return r, errors.New("Nur Markdown-Notizen können veröffentlicht werden.")
	}
	r.SourceUpdated, r.Markdown, r.Attachments = asset.UpdatedAt, asset.Payload, asset.Attachments
	return a.store.create(r, a.cfg.FilesDir)
}

func agentJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}

// A separate credential and route allowlist: no approval, withdrawal or HTML access.
func (a *app) agentAPI() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/publications", func(w http.ResponseWriter, r *http.Request) {
		result := map[string][]agentRevision{"published": {}, "drafts": {}}
		for _, bucket := range []string{"published", "drafts"} {
			rows, err := a.store.entries(bucket)
			if err != nil {
				agentJSON(w, 500, map[string]string{"error": "Speicher nicht verfügbar"})
				return
			}
			for _, row := range rows {
				result[bucket] = append(result[bucket], agentView(row, false))
			}
		}
		agentJSON(w, 200, result)
	})
	mux.HandleFunc("POST /api/drafts", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 128<<10)
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var input agentDraft
		if err := decoder.Decode(&input); err != nil {
			agentJSON(w, 400, map[string]string{"error": "Ungültiger Entwurf"})
			return
		}
		if err := decoder.Decode(new(any)); err != io.EOF {
			agentJSON(w, 400, map[string]string{"error": "Genau ein JSON-Dokument erwartet"})
			return
		}
		draft, err := a.prepareDraft(r.Context(), revision{SourceID: input.NoteID, Slug: input.Slug, Title: input.Title, Summary: input.Summary, Category: input.Category, Kind: input.Kind, CreatedBy: r.Header.Get("X-Tailscale-User")})
		if err != nil {
			agentJSON(w, 400, map[string]string{"error": err.Error()})
			return
		}
		agentJSON(w, 201, map[string]any{"draft": agentView(draft, true), "review_path": "/drafts/" + draft.ID, "review_url": a.cfg.ReviewURL + "/drafts/" + draft.ID})
	})
	mux.HandleFunc("GET /api/drafts/{id}", func(w http.ResponseWriter, r *http.Request) {
		rows, err := a.store.entries("drafts")
		if err != nil {
			agentJSON(w, 500, map[string]string{"error": "Speicher nicht verfügbar"})
			return
		}
		for _, draft := range rows {
			if draft.ID != r.PathValue("id") {
				continue
			}
			previous, err := a.store.current(draft.Slug)
			if err != nil && !errors.Is(err, errNotFound) {
				agentJSON(w, 500, map[string]string{"error": "Speicher nicht verfügbar"})
				return
			}
			head, err := a.store.head(draft.Slug)
			if err != nil {
				agentJSON(w, 500, map[string]string{"error": "Speicher nicht verfügbar"})
				return
			}
			var published *agentRevision
			if previous.ID != "" {
				view := agentView(previous, true)
				published = &view
			}
			agentJSON(w, 200, map[string]any{"draft": agentView(draft, true), "published": published, "stale": head != draft.Base, "review_path": "/drafts/" + draft.ID, "review_url": a.cfg.ReviewURL + "/drafts/" + draft.ID})
			return
		}
		agentJSON(w, 404, map[string]string{"error": "Entwurf nicht gefunden"})
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		identity := a.proxyIdentity(r.Header.Get("X-NRC-Publish-Auth"))
		if identity == "" {
			agentJSON(w, 401, map[string]string{"error": "Verifizierter Tailscale-Proxy erforderlich"})
			return
		}
		r.Header.Set("X-Tailscale-User", identity)
		mux.ServeHTTP(w, r)
	})
}
