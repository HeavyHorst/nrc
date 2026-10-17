package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"mime"
	"net/http"
	"sort"
	"strconv"
	"strings"

	p "github.com/heavyhorst/nrc/protocol-go"
	"golang.org/x/crypto/bcrypt"
)

type ticketPreview struct {
	Version       int    `json:"version"`
	Title         string `json:"title"`
	CompanyID     string `json:"company_id"`
	ContactID     string `json:"contact_id"`
	Requester     string `json:"requester"`
	RequesterName string `json:"requester_name"`
	Status        string `json:"status"`
	Assignee      string `json:"assignee"`
}
type entryPreview struct {
	Version int    `json:"version"`
	Kind    string `json:"kind"`
	Author  string `json:"author"`
}

// encoding/json's struct matching is case-insensitive; NRC metadata is not.
// In particular, an extra "Kind" must never turn an internal_note public.
func decodePreviewFields(data []byte, fields map[string]any) error {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil {
		return err
	}
	if object == nil {
		return fmt.Errorf("expected metadata object")
	}
	for key, dst := range fields {
		if raw, ok := object[key]; ok {
			if err := json.Unmarshal(raw, dst); err != nil {
				return err
			}
		}
	}
	return nil
}
func (v *ticketPreview) UnmarshalJSON(data []byte) error {
	return decodePreviewFields(data, map[string]any{
		"version": &v.Version, "title": &v.Title, "company_id": &v.CompanyID,
		"contact_id": &v.ContactID, "requester": &v.Requester,
		"requester_name": &v.RequesterName, "status": &v.Status, "assignee": &v.Assignee,
	})
}
func (v *entryPreview) UnmarshalJSON(data []byte) error {
	return decodePreviewFields(data, map[string]any{
		"version": &v.Version, "kind": &v.Kind, "author": &v.Author,
	})
}

// Public DTOs are deliberately separate from authoritative assets/previews.
// Never serialize an asset or pass one to a template. Only validated public
// attachments get ticket-scoped download URLs, not generic blob-service URLs.
type publicTicket struct {
	ID          uint64             `json:"id"`
	Title       string             `json:"title"`
	Status      string             `json:"status"`
	Body        string             `json:"body,omitempty"`
	Entries     []publicEntry      `json:"entries,omitempty"`
	Attachments []publicAttachment `json:"attachments,omitempty"`
}
type publicEntry struct {
	Author      string             `json:"author"`
	Body        string             `json:"body"`
	Attachments []publicAttachment `json:"attachments,omitempty"`
}
type view struct {
	Branding branding       `json:"-"`
	New      bool           `json:"-"`
	Ticket   *publicTicket  `json:"ticket,omitempty"`
	Tickets  []publicTicket `json:"tickets,omitempty"`
}
type portal struct {
	source   source
	files    fileStore
	brand    branding
	accounts []account
	origin   string
}

func project(a p.Asset, who account) (publicTicket, bool) {
	var v ticketPreview
	if a.ConvID != 0 || a.AssetType != ticketType || a.ParentType != 0 || a.ParentID != 0 || json.Unmarshal([]byte(a.Preview), &v) != nil || v.Version != 1 || v.Requester != who.Requester {
		return publicTicket{}, false
	}
	status := map[string]string{"open": "Offen", "in_progress": "In Bearbeitung", "waiting_customer": "Ihre Antwort wird erwartet", "resolved": "Gelöst", "closed": "Geschlossen"}[v.Status]
	if status == "" {
		return publicTicket{}, false
	}
	return publicTicket{ID: a.AssetID, Title: v.Title, Status: status, Body: a.Payload}, true
}
func (s *portal) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// HTML form POSTs need their same-origin Origin header for CSRF validation.
	// no-referrer makes Chromium send Origin: null for these navigations.
	w.Header().Set("Referrer-Policy", "same-origin")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
	login, password, ok := r.BasicAuth()
	var who account
	valid := false
	for _, a := range s.accounts {
		if a.Login == login {
			valid = ok && bcrypt.CompareHashAndPassword([]byte(a.PasswordHash), []byte(password)) == nil
			who = a
			break
		}
	}
	if !valid {
		w.Header().Set("WWW-Authenticate", `Basic realm="Kundenportal", charset="UTF-8"`)
		http.Error(w, "Bitte melden Sie sich mit Ihrem Kundenkonto an.", 401)
		return
	}
	if r.Method != "GET" && r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/style.css" {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		w.Write(portalCSS)
		w.Write([]byte("\n"))
		w.Write(s.brand.ThemeCSS)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/attachments.js" {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Write(portalAttachmentsJS)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/branding/logo" {
		if len(s.brand.Logo) == 0 {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", http.DetectContentType(s.brand.Logo))
		w.Write(s.brand.Logo)
		return
	}
	if r.Method == "POST" && (r.Header.Get("Origin") != s.origin || r.Header.Get("Sec-Fetch-Site") == "cross-site") {
		http.Error(w, "Ungültiger Formularursprung.", 403)
		return
	}
	api := strings.HasPrefix(r.URL.Path, "/api/")
	path := strings.TrimPrefix(r.URL.Path, "/api")
	if path == "/tickets" && r.Method == "POST" {
		s.write(w, r, who, 0, api)
		return
	}
	if strings.HasPrefix(path, "/tickets/") {
		parts := strings.Split(strings.TrimPrefix(path, "/tickets/"), "/")
		id, e := strconv.ParseUint(parts[0], 10, 64)
		if e != nil || id == 0 {
			http.NotFound(w, r)
			return
		}
		a, e := s.source.get(r.Context(), id)
		if e != nil {
			http.NotFound(w, r)
			return
		}
		v, owned := project(a, who)
		if !owned {
			http.NotFound(w, r)
			return
		}
		if len(parts) > 2 {
			s.download(w, r, a, parts)
			return
		}
		if len(parts) == 2 {
			if parts[1] == "reply" && r.Method == "POST" {
				s.write(w, r, who, id, api)
				return
			}
			http.NotFound(w, r)
			return
		}
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		v.Attachments = publicAttachments(id, id, a.Attachments)
		assets, e := s.source.list(r.Context(), entryType)
		if e != nil {
			s.unavailable(w)
			return
		}
		sort.Slice(assets, func(i, j int) bool { return assets[i].AssetID < assets[j].AssetID })
		for _, a := range assets {
			if _, ok := publicReply(a, id); !ok {
				continue
			}
			full, e := s.source.get(r.Context(), a.AssetID)
			if e != nil {
				s.unavailable(w)
				return
			}
			preview, ok := publicReply(full, id)
			if !ok {
				continue
			}
			v.Entries = append(v.Entries, publicEntry{preview.Author, full.Payload, publicAttachments(id, full.AssetID, full.Attachments)})
		}
		s.render(w, api, view{Ticket: &v})
		return
	}
	if r.Method != "GET" {
		http.NotFound(w, r)
		return
	}
	if path != "/" && path != "/tickets" && path != "/new" {
		http.NotFound(w, r)
		return
	}
	if path == "/new" {
		if api {
			http.NotFound(w, r)
			return
		}
		s.render(w, false, view{New: true})
		return
	}
	assets, e := s.source.list(r.Context(), ticketType)
	if e != nil {
		s.unavailable(w)
		return
	}
	list := []publicTicket{}
	for _, a := range assets {
		if v, ok := project(a, who); ok {
			v.Body = ""
			list = append(list, v)
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID > list[j].ID })
	s.render(w, api, view{Tickets: list})
}
func (s *portal) unavailable(w http.ResponseWriter) {
	http.Error(w, "Der Dienst ist vorübergehend nicht verfügbar. Bei Sendeproblemen kann Ihre Nachricht bereits gespeichert sein. Bitte prüfen Sie die Übersicht, bevor Sie erneut senden.", 503)
}
func (s *portal) write(w http.ResponseWriter, r *http.Request, who account, parent uint64, api bool) {
	// Form escaping can expand each UTF-8 byte to three bytes, plus field names.
	contentType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	limit := int64(3*(32000+200) + 1024)
	if contentType == "multipart/form-data" {
		limit = maxUploadBytes + 128*1024
	}
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	var err error
	if contentType == "multipart/form-data" {
		err = r.ParseMultipartForm(1 << 20)
		defer func() {
			if r.MultipartForm != nil {
				r.MultipartForm.RemoveAll()
			}
		}()
	} else if contentType == "application/x-www-form-urlencoded" {
		err = r.ParseForm()
	} else {
		err = fmt.Errorf("unsupported form")
	}
	if err != nil {
		status := 400
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			status = 413
		}
		http.Error(w, "Ungültiges oder zu großes Formular.", status)
		return
	}
	var attachments []p.Attachment
	if r.MultipartForm != nil {
		for key := range r.MultipartForm.File {
			if key != "files" {
				http.Error(w, "Unbekanntes Dateifeld.", 400)
				return
			}
		}
		files := r.MultipartForm.File["files"]
		var total int64
		for _, file := range files {
			total += file.Size
			if !validFilename(file.Filename) || file.Size < 0 || file.Size > maxUploadBytes {
				http.Error(w, "Ungültiger Dateiname oder Dateigröße.", 400)
				return
			}
		}
		if len(files) > 10 || total > maxUploadBytes {
			http.Error(w, "Maximal 10 Anhänge und insgesamt 100 MiB je Nachricht.", 413)
			return
		}
	}
	if len(r.PostForm["body"]) != 1 || (parent == 0 && len(r.PostForm["title"]) != 1) {
		http.Error(w, "Ungültiges Formular.", 400)
		return
	}
	// Reject forged metadata, rather than letting hidden fields influence identity.
	for key := range r.PostForm {
		if key == "files" && contentType == "multipart/form-data" {
			// Browsers send filename="" for an untouched optional file input;
			// Go parses that empty part as a value instead of a FileHeader.
			for _, value := range r.PostForm[key] {
				if value != "" {
					http.Error(w, "Ungültiges Dateifeld.", 400)
					return
				}
			}
			continue
		}
		if key != "title" && key != "body" {
			http.Error(w, "Unbekanntes Formularfeld.", 400)
			return
		}
	}
	body, title := strings.TrimSpace(r.PostForm.Get("body")), strings.TrimSpace(r.PostForm.Get("title"))
	if body == "" || len(body) > 32000 || (parent == 0 && (title == "" || len(title) > 200)) {
		http.Error(w, "Bitte Betreff (max. 200 Byte) und Nachricht (max. 32000 Byte) ausfüllen.", 400)
		return
	}
	// Validate all fields/files first. Browser-provided file IDs are never accepted.
	if r.MultipartForm != nil && len(r.MultipartForm.File["files"]) > 0 {
		if s.files == nil {
			s.unavailable(w)
			return
		}
		for _, file := range r.MultipartForm.File["files"] {
			attachment, err := s.files.upload(r.Context(), file)
			if err != nil {
				s.unavailable(w)
				return
			}
			attachments = append(attachments, attachment)
		}
	}
	a := p.Asset{AssetType: ticketType, Payload: body, Attachments: attachments}
	if parent == 0 {
		b, _ := json.Marshal(ticketPreview{Version: 1, Title: title, CompanyID: who.CompanyID, Requester: who.Requester, RequesterName: who.Name, Status: "open"})
		a.Preview = string(b)
	} else {
		a.AssetType = entryType
		a.ParentType = 2
		a.ParentID = parent
		b, _ := json.Marshal(entryPreview{1, "customer_reply", who.Name})
		a.Preview = string(b)
	}
	saved, e := s.source.create(r.Context(), a)
	if e != nil {
		s.unavailable(w)
		return
	}
	id := parent
	if id == 0 {
		id = saved.AssetID
	}
	if api {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(struct {
			ID uint64 `json:"id"`
		}{id})
		return
	}
	http.Redirect(w, r, fmt.Sprintf("/tickets/%d", id), http.StatusSeeOther)
}
func (s *portal) render(w http.ResponseWriter, api bool, v view) {
	if api {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(v)
		return
	}
	v.Branding = s.brand
	if v.Branding.Brand == "" {
		v.Branding.Brand = "Ihr Kundenportal"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	page.Execute(w, v)
}

var page = template.Must(template.New("portal").Parse(`<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Branding.Brand}}</title><link rel="stylesheet" href="/style.css"><script src="/attachments.js" defer></script></head><body>
<header><a class="brand" href="/">{{if .Branding.Logo}}<img src="/branding/logo" alt="">{{end}}<span>{{.Branding.Brand}}</span></a>
<nav aria-label="Hauptnavigation"><a href="/">Meine Anfragen</a><a href="/new">Neue Anfrage</a></nav></header><main>
{{if .New}}
<h1>Wie können wir Ihnen helfen?</h1><p>Schildern Sie uns Ihr Anliegen. Wir kümmern uns darum.</p>
<form method="post" action="/tickets" enctype="multipart/form-data">
<label>Betreff<input name="title" maxlength="200" required></label>
<label>Ihre Nachricht<textarea name="body" rows="8" maxlength="32000" required></textarea></label>
{{template "upload"}}<button>Anfrage senden</button></form>
{{else if .Ticket}}
<a href="/">← Alle Anfragen</a><h1>{{.Ticket.Title}}</h1><p class="muted">Anfrage #{{.Ticket.ID}} · {{.Ticket.Status}}</p>
<article><h2>Ihre Anfrage</h2><div class="body">{{.Ticket.Body}}</div>{{template "attachments" .Ticket.Attachments}}</article>
{{range .Ticket.Entries}}<article><strong>{{.Author}}</strong><div class="body">{{.Body}}</div>{{template "attachments" .Attachments}}</article>{{end}}
<form method="post" action="/tickets/{{.Ticket.ID}}/reply" enctype="multipart/form-data">
<label>Ihre Antwort<textarea name="body" rows="5" maxlength="32000" required></textarea></label>
{{template "upload"}}<button>Antwort senden</button></form>
{{else}}
<h1>Meine Anfragen</h1><p>Willkommen! Hier behalten Sie Ihre Anliegen und unsere Antworten im Blick.</p>
<p><a class="button" href="/new">+ Neue Anfrage</a></p>
<table><thead><tr><th>Anfrage</th><th>Status</th></tr></thead><tbody>{{range .Tickets}}<tr><td><a href="/tickets/{{.ID}}">{{.Title}}</a><br><small>#{{.ID}}</small></td><td>{{.Status}}</td></tr>{{else}}<tr><td colspan="2">Noch keine Anfragen. Wie können wir Ihnen helfen?</td></tr>{{end}}</tbody></table>
{{end}}<p class="muted">Nur Ihre eigenen Anfragen und öffentliche Antworten sind hier sichtbar.</p></main>
{{with .Branding}}{{if or .FooterText .ImprintURL .PrivacyURL .TermsURL .ContactURL}}
<footer>{{if .FooterText}}<span>{{.FooterText}}</span>{{end}}<nav aria-label="Rechtliches und Kontakt">
{{if .ImprintURL}}<a href="{{.ImprintURL}}">Impressum</a>{{end}}{{if .PrivacyURL}}<a href="{{.PrivacyURL}}">Datenschutz</a>{{end}}
{{if .TermsURL}}<a href="{{.TermsURL}}">Nutzungsbedingungen</a>{{end}}{{if .ContactURL}}<a href="{{.ContactURL}}">Kontakt</a>{{end}}
</nav></footer>{{end}}{{end}}</body></html>
{{define "upload"}}<div class="attachment-upload"><p>Anhänge (optional)</p><label class="file-upload"><span class="button">Dateien hinzufügen</span><input type="file" name="files" multiple aria-describedby="attachment-hint selected-files"></label><p class="muted" id="selected-files" aria-live="polite"></p><p class="muted attachment-hint" id="attachment-hint">Bis zu 10 Dateien, insgesamt maximal 100 MiB je Nachricht. Bitte keine Passwörter oder Zugangsdaten anhängen.</p></div>{{end}}
{{define "attachments"}}{{if .}}<ul class="attachments" aria-label="Anhänge">{{range .}}<li>{{if .PreviewURL}}<a class="attachment-preview" href="{{.PreviewURL}}" target="_blank" rel="noopener" aria-label="Bild {{.Filename}} öffnen"><img src="{{.PreviewURL}}" alt="Vorschau: {{.Filename}}" loading="lazy" decoding="async"></a>{{end}}<a href="{{.URL}}" download>{{.Filename}}</a> <small class="muted">({{.Size}} Byte)</small></li>{{end}}</ul>{{end}}{{end}}`))
