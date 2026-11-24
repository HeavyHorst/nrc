package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"mime"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"
	"unicode"
	"unicode/utf8"

	p "github.com/heavyhorst/nrc/protocol-go"
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
	Category      string `json:"category,omitempty"`
}
type entryPreview struct {
	Version int    `json:"version"`
	Kind    string `json:"kind"`
	Author  string `json:"author"`
}

// Format staff login names for display without rewriting stored attribution.
func staffReplyDisplayName(author string) string {
	parts := strings.Split(author, ".")
	if len(parts) < 2 {
		return author
	}
	for i, part := range parts {
		if part == "" || strings.ContainsFunc(part, func(r rune) bool { return !unicode.IsLower(r) }) {
			return author
		}
		first, size := utf8.DecodeRuneInString(part)
		parts[i] = string(unicode.ToTitle(first)) + part[size:]
	}
	return strings.Join(parts, " ")
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
		"category": &v.Category,
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
	Category    string             `json:"category,omitempty"`
	Shared      bool               `json:"shared"`
	SubmittedBy string             `json:"submitted_by,omitempty"`
	Body        string             `json:"body,omitempty"`
	Entries     []publicEntry      `json:"entries,omitempty"`
	Attachments []publicAttachment `json:"attachments,omitempty"`
	CreatedAt   int64              `json:"-"`
	StatusKey   string             `json:"-"`
}
type publicEntry struct {
	Author      string             `json:"author"`
	Body        string             `json:"body"`
	Attachments []publicAttachment `json:"attachments,omitempty"`
	CreatedAt   int64              `json:"-"`
	FromSupport bool               `json:"-"`
}
type view struct {
	Branding          branding       `json:"-"`
	New               bool           `json:"-"`
	Ticket            *publicTicket  `json:"ticket,omitempty"`
	Tickets           []publicTicket `json:"tickets,omitempty"`
	Filters           ticketFilters  `json:"-"`
	Waiting           int            `json:"-"`
	HasTickets        bool           `json:"-"`
	Password          bool           `json:"-"`
	CanChangePassword bool           `json:"-"`
	PasswordError     string         `json:"-"`
	Status            int            `json:"-"`
}

type ticketFilters struct{ Search, Status, Scope, Sort string }

func readTicketFilters(q url.Values) ticketFilters {
	f := ticketFilters{Search: strings.TrimSpace(q.Get("q"))}
	switch s := q.Get("status"); s {
	case "waiting", "active", "done":
		f.Status = s
	}
	switch s := q.Get("scope"); s {
	case "own", "team":
		f.Scope = s
	}
	if q.Get("sort") == "oldest" {
		f.Sort = "oldest"
	}
	return f
}

func (f ticketFilters) Query(status string) string {
	q := url.Values{}
	for key, value := range map[string]string{"q": f.Search, "status": status, "scope": f.Scope, "sort": f.Sort} {
		if value != "" {
			q.Set(key, value)
		}
	}
	if len(q) == 0 {
		return ""
	}
	return "?" + q.Encode()
}

func (f ticketFilters) Matches(t publicTicket) bool {
	if (f.Scope == "own" && t.Shared) || (f.Scope == "team" && !t.Shared) {
		return false
	}
	switch f.Status {
	case "waiting":
		if t.StatusKey != "waiting_customer" {
			return false
		}
	case "active":
		if t.StatusKey != "open" && t.StatusKey != "in_progress" {
			return false
		}
	case "done":
		if t.StatusKey != "resolved" && t.StatusKey != "closed" {
			return false
		}
	}
	if f.Search == "" {
		return true
	}
	if id, err := strconv.ParseUint(strings.TrimPrefix(f.Search, "#"), 10, 64); err == nil {
		return t.ID == id || (!strings.HasPrefix(f.Search, "#") && strings.Contains(t.Title, f.Search))
	}
	return strings.Contains(strings.ToLower(t.Title), strings.ToLower(f.Search))
}

type portal struct {
	source   source
	files    fileStore
	brand    branding
	accounts accountStore
	origin   string
	guestKey []byte
	sessions accountSessions
}

func (s *portal) writeProof(who account) *p.PortalWriteProof {
	db, ok := s.accounts.(dbAccounts)
	if !ok {
		return nil
	}
	// Use the account snapshot from authentication, never a fresh lookup after
	// uploading files or reading the review run. A missing snapshot fails
	// encoding instead of falling back to the file-mode write.
	return &p.PortalWriteProof{ID: who.PortalID, Revision: who.PortalRevision, ServiceKey: db.key}
}

func (s *portal) sharedContacts(ctx context.Context, who account) map[string]bool {
	if who.Disabled || who.ContactID == "" || who.CompanyID == "" {
		return nil
	}
	id, _ := strconv.ParseUint(who.CompanyID, 10, 64)
	company, err := s.source.get(ctx, id)
	if err != nil || company.AssetID != id || company.ConvID != 0 || company.AssetType != p.AssetTypeCustomerCompany {
		return nil
	}
	groups, err := p.DecodeTicketGroups(company.Preview)
	if err != nil {
		return nil
	}
	peers := map[string]bool{}
	for _, group := range groups {
		member := false
		for _, contact := range group.ContactIDs {
			member = member || contact == who.ContactID
		}
		if member {
			for _, contact := range group.ContactIDs {
				peers[contact] = true
			}
		}
	}
	if len(peers) == 0 {
		return nil
	}
	edges, err := s.source.edges(ctx, id)
	if err != nil {
		return nil
	}
	linked := map[string]bool{}
	for _, edge := range edges {
		if edge.ConvID != 0 || edge.Relation != p.RelationMemberOf || edge.SourceType != p.TargetTypeAsset || edge.TargetType != p.TargetTypeAsset {
			continue
		}
		if edge.TargetID == id {
			linked[strconv.FormatUint(edge.SourceID, 10)] = true
		} else if edge.SourceID == id {
			linked[strconv.FormatUint(edge.TargetID, 10)] = true
		}
	}
	// Re-read actual contacts: deleted contacts or removed company edges cannot
	// leave a stale grant behind. This set lives for one HTTP request only.
	for contact := range peers {
		cid, _ := strconv.ParseUint(contact, 10, 64)
		a, err := s.source.get(ctx, cid)
		if !linked[contact] || err != nil || a.AssetID != cid || a.ConvID != 0 || a.AssetType != p.AssetTypeCustomerContact {
			delete(peers, contact)
		}
	}
	if !peers[who.ContactID] {
		return nil
	}
	return peers
}

func (s *portal) project(ctx context.Context, a p.Asset, who account, peers map[string]bool) (publicTicket, bool, error) {
	var v ticketPreview
	if a.ConvID != 0 || a.AssetType != ticketType || a.ParentType != 0 || a.ParentID != 0 || json.Unmarshal([]byte(a.Preview), &v) != nil || v.Version != 1 {
		return publicTicket{}, false, nil
	}
	shared := v.Requester != who.Requester
	if shared {
		if who.Disabled || v.CompanyID == "" || v.CompanyID != who.CompanyID || len(peers) == 0 {
			return publicTicket{}, false, nil
		}
		contact := v.ContactID
		// Older tickets have no contact_id. Only explicit account bindings in the
		// same company can resolve them, even after the requester is disabled.
		if contact == "" && v.Requester != "" {
			mapped, found, err := s.accounts.mapping(ctx, v.Requester)
			if err != nil {
				return publicTicket{}, false, err
			}
			if found && mapped.CompanyID == v.CompanyID {
				contact = mapped.ContactID
			}
		}
		if !peers[contact] {
			return publicTicket{}, false, nil
		}
	}
	status := map[string]string{"open": "Offen", "in_progress": "In Bearbeitung", "waiting_customer": "Ihre Antwort wird erwartet", "resolved": "Gelöst", "closed": "Geschlossen"}[v.Status]
	if status == "" {
		return publicTicket{}, false, nil
	}
	category := map[string]string{"bug": "Bug", "support": "Support", "feature": "Feature", "unclear": "Unklar"}[v.Category]
	return publicTicket{ID: a.AssetID, Title: v.Title, Status: status, Category: category, Body: a.Payload, Shared: shared, SubmittedBy: v.RequesterName, CreatedAt: a.CreatedAt, StatusKey: v.Status}, true, nil
}
func (s *portal) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// HTML form POSTs need their same-origin Origin header for CSRF validation.
	// no-referrer makes Chromium send Origin: null for these navigations.
	w.Header().Set("Referrer-Policy", "same-origin")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
	// Process reachability only; no customer data or backend operations.
	if r.URL.Path == "/health" && r.Method == http.MethodGet {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
		return
	}
	if r.URL.Path == "/abnahmen/einladung" || r.URL.Path == "/abnahmen/einladung.js" || r.URL.Path == "/abnahmen/gast" || strings.HasPrefix(r.URL.Path, "/abnahmen/gast/") {
		s.guestReview(w, r)
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
		if len(s.brand.FontRegular) > 0 {
			io.WriteString(w, "@font-face{font-family:Portal Brand;src:url(/branding/font-regular.woff2) format('woff2');font-weight:400;font-display:swap}\n")
		}
		if len(s.brand.FontBold) > 0 {
			io.WriteString(w, "@font-face{font-family:Portal Brand;src:url(/branding/font-bold.woff2) format('woff2');font-weight:700;font-display:swap}\n")
		}
		w.Write(s.brand.ThemeCSS)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/attachments.js" {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Write(portalAttachmentsJS)
		return
	}
	if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/branding/") {
		var asset []byte
		var mime string
		switch r.URL.Path {
		case "/branding/logo":
			asset = s.brand.Logo
		case "/branding/login-image":
			asset = s.brand.LoginImage
		case "/branding/font-regular.woff2":
			asset, mime = s.brand.FontRegular, "font/woff2"
		case "/branding/font-bold.woff2":
			asset, mime = s.brand.FontBold, "font/woff2"
		}
		if len(asset) == 0 {
			http.NotFound(w, r)
			return
		}
		if mime == "" {
			mime = http.DetectContentType(asset)
		}
		w.Header().Set("Content-Type", mime)
		w.Write(asset)
		return
	}
	if r.Method == "POST" && (s.origin == "" || r.Header.Get("Origin") != s.origin || r.Header.Get("Sec-Fetch-Site") == "cross-site") {
		http.Error(w, "Ungültiger Formularursprung.", 403)
		return
	}
	switch r.URL.Path {
	case "/login":
		s.login(w, r)
		return
	case "/logout":
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		s.endSession(w, r)
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	api := strings.HasPrefix(r.URL.Path, "/api/")
	path := r.URL.Path
	if api {
		path = strings.TrimPrefix(path, "/api")
	}
	ticketPath, isTicket := strings.CutPrefix(path, "/tickets/")
	var parts []string
	if isTicket {
		parts = strings.Split(ticketPath, "/")
	}
	who, valid, err := s.loggedIn(r, api, r.Method == http.MethodGet && attachmentRoute(parts))
	if err != nil {
		s.unavailable(w)
		return
	}
	if !valid {
		if api {
			w.Header().Set("WWW-Authenticate", `Basic realm="Kundenportal", charset="UTF-8"`)
			http.Error(w, "Bitte melden Sie sich mit Ihrem Kundenkonto an.", http.StatusUnauthorized)
		} else if r.Method == http.MethodGet {
			http.Redirect(w, r, "/login?next="+url.QueryEscape(loginDestination(r.URL.RequestURI())), http.StatusSeeOther)
		} else if target := formReturnPath(r.URL.Path); target != "" {
			if strings.HasPrefix(target, "/tickets/") {
				f := readTicketFilters(r.URL.Query())
				if filtered := loginDestination(target + f.Query(f.Status)); filtered != "/" {
					target = filtered
				}
			}
			http.Redirect(w, r, "/login?unsaved=1&next="+url.QueryEscape(target), http.StatusSeeOther)
		} else {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
		}
		return
	}
	if r.URL.Path == "/abnahmen" || strings.HasPrefix(r.URL.Path, "/abnahmen/") {
		s.accountReview(w, r, who)
		return
	}
	if r.URL.Path == "/konto/passwort" {
		s.passwordPage(w, r, who)
		return
	}
	if path == "/tickets" && r.Method == "POST" {
		s.write(w, r, who, 0, api)
		return
	}
	if isTicket {
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
		var peers map[string]bool
		var preview ticketPreview
		if json.Unmarshal([]byte(a.Preview), &preview) == nil && preview.Requester != who.Requester {
			peers = s.sharedContacts(r.Context(), who)
		}
		v, owned, err := s.project(r.Context(), a, who, peers)
		if err != nil {
			s.unavailable(w)
			return
		}
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
			if !api && preview.Kind == "public_reply" {
				preview.Author = staffReplyDisplayName(preview.Author)
			}
			v.Entries = append(v.Entries, publicEntry{Author: preview.Author, Body: full.Payload, Attachments: publicAttachments(id, full.AssetID, full.Attachments), CreatedAt: full.CreatedAt, FromSupport: preview.Kind == "public_reply"})
		}
		s.render(w, api, view{Ticket: &v, Filters: readTicketFilters(r.URL.Query())})
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
	peers := s.sharedContacts(r.Context(), who)
	for _, a := range assets {
		v, ok, err := s.project(r.Context(), a, who, peers)
		if err != nil {
			s.unavailable(w)
			return
		}
		if ok {
			v.Body = ""
			list = append(list, v)
		}
	}
	if api {
		sort.Slice(list, func(i, j int) bool { return list[i].ID > list[j].ID })
		s.render(w, true, view{Tickets: list})
		return
	}
	f := readTicketFilters(r.URL.Query())
	v := view{Filters: f, HasTickets: len(list) > 0}
	for _, t := range list {
		if t.StatusKey == "waiting_customer" {
			v.Waiting++
		}
		if f.Matches(t) {
			v.Tickets = append(v.Tickets, t)
		}
	}
	sort.Slice(v.Tickets, func(i, j int) bool {
		a, b := v.Tickets[i], v.Tickets[j]
		if a.CreatedAt == b.CreatedAt || (a.CreatedAt <= 0 && b.CreatedAt <= 0) {
			return a.ID > b.ID
		}
		if a.CreatedAt <= 0 || b.CreatedAt <= 0 {
			return a.CreatedAt > 0
		}
		if f.Sort == "oldest" {
			return a.CreatedAt < b.CreatedAt
		}
		return a.CreatedAt > b.CreatedAt
	})
	s.render(w, false, v)
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
		if key != "title" && key != "body" && !(parent == 0 && key == "category") {
			http.Error(w, "Unbekanntes Formularfeld.", 400)
			return
		}
	}
	body, title := strings.TrimSpace(r.PostForm.Get("body")), strings.TrimSpace(r.PostForm.Get("title"))
	category := r.PostForm.Get("category")
	if len(r.PostForm["category"]) > 1 || !p.ValidTicketCategory(category) {
		http.Error(w, "Ungültige Kategorie.", 400)
		return
	}
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
		b, _ := json.Marshal(ticketPreview{Version: 1, Title: title, CompanyID: who.CompanyID, ContactID: who.ContactID, Requester: who.Requester, RequesterName: who.Name, Status: "open", Category: category})
		a.Preview = string(b)
	} else {
		// File uploads can take minutes. Recheck a team grant immediately before
		// storing the reply rather than retaining access from the initial GET.
		current, err := s.source.get(r.Context(), parent)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		_, ok, err := s.project(r.Context(), current, who, s.sharedContacts(r.Context(), who))
		if err != nil {
			s.unavailable(w)
			return
		}
		if !ok {
			http.NotFound(w, r)
			return
		}
		a.AssetType = entryType
		a.ParentType = 2
		a.ParentID = parent
		b, _ := json.Marshal(entryPreview{1, "customer_reply", who.Name})
		a.Preview = string(b)
	}
	var saved p.Asset
	var e error
	if proof := s.writeProof(who); proof != nil {
		src, ok := s.source.(interface {
			createPortalTicket(context.Context, p.Asset, string, p.PortalWriteProof) (p.Asset, error)
		})
		if !ok {
			s.unavailable(w)
			return
		}
		saved, e = src.createPortalTicket(r.Context(), a, who.Requester, *proof)
	} else {
		saved, e = s.source.create(r.Context(), a)
	}
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
	f := readTicketFilters(r.URL.Query())
	http.Redirect(w, r, fmt.Sprintf("/tickets/%d%s", id, f.Query(f.Status)), http.StatusSeeOther)
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
	_, v.CanChangePassword = s.accounts.(passwordAccountStore)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if v.Status != 0 {
		w.WriteHeader(v.Status)
	}
	page.Execute(w, v)
}

var ticketTimeZone = func() *time.Location {
	zone, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		panic(err)
	}
	return zone
}()

var page = template.Must(template.New("portal").Funcs(template.FuncMap{
	"ticketTime": func(ns int64) time.Time { return time.Unix(0, ns).In(ticketTimeZone) },
}).Parse(`{{define "date"}}{{with ticketTime .}}<time datetime="{{.Format "2006-01-02T15:04:05Z07:00"}}">{{.Format "02.01.2006, 15:04"}} Uhr</time>{{end}}{{end}}
{{define "created"}}{{if gt . 0}} <small class="muted message-time">· {{template "date" .}}</small>{{end}}{{end}}
{{define "status"}}<span class="ticket-status {{.StatusKey}}">{{.Status}}</span>{{end}}
{{define "file-links"}}{{range .}}<li><a href="{{.URL}}" download>{{.Filename}}</a> <small class="muted">({{.Size}} Byte)</small></li>{{end}}{{end}}<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Branding.Brand}}</title><link rel="stylesheet" href="/style.css"><script src="/attachments.js" defer></script></head><body class="account-page">
<header><a class="brand" href="/">{{if .Branding.Logo}}<img src="/branding/logo" alt="">{{end}}<span>{{.Branding.Brand}}</span></a>
<nav class="account-nav" aria-label="Hauptnavigation"><a href="/"{{if not .Password}} aria-current="{{if or .New .Ticket}}true{{else}}page{{end}}"{{end}}>Meine Anfragen</a><a href="/abnahmen">Meine Abnahmen</a>{{if .CanChangePassword}}<a href="/konto/passwort"{{if .Password}} aria-current="page"{{end}}>Mein Konto</a>{{end}}<form method="post" action="/logout"><button>Abmelden</button></form></nav></header><main>
{{if .Password}}
<h1>Passwort ändern</h1><p>Nach dem Wechsel werden alle bisherigen Sitzungen abgemeldet.</p>
<form class="password-form" method="post" action="/konto/passwort" aria-label="Passwort ändern">
{{if .PasswordError}}<p class="login-error" role="alert">{{.PasswordError}}</p>{{end}}
<label>Aktuelles Passwort<input type="password" name="current" autocomplete="current-password" required></label>
<label>Neues Passwort<input type="password" name="new" autocomplete="new-password" aria-describedby="password-hint" required></label>
<p class="muted" id="password-hint">14 bis 72 Bytes. Umlaute und andere Sonderzeichen können mehr als ein Byte belegen.</p>
<label>Neues Passwort wiederholen<input type="password" name="repeat" autocomplete="new-password" required></label>
<button>Passwort ändern</button></form>
{{else if .New}}
<h1>Wie können wir Ihnen helfen?</h1><p>Schildern Sie uns Ihr Anliegen. Wir kümmern uns darum.</p>
<form method="post" action="/tickets" enctype="multipart/form-data">
<label>Betreff<input name="title" maxlength="200" required></label>
<label>Kategorie (optional)<select name="category"><option value="">Automatisch einordnen</option><option value="bug">Bug</option><option value="support">Support</option><option value="feature">Feature</option><option value="unclear">Unklar</option></select></label>
<label>Ihre Nachricht<textarea name="body" rows="8" maxlength="32000" required></textarea></label>
{{template "upload"}}<button>Anfrage senden</button></form>
{{else if .Ticket}}
{{$query := .Filters.Query .Filters.Status}}
<div class="ticket-heading"><a href="/{{$query}}">← Zur Anfragenliste</a><p class="muted">Anfrage #{{.Ticket.ID}} · {{if .Ticket.Shared}}Teamanfrage{{else}}Eigene Anfrage{{end}}</p><h1>{{.Ticket.Title}}</h1></div>
{{if eq .Ticket.StatusKey "waiting_customer"}}<div class="ticket-callout ticket-callout-waiting"><strong>Ihre Antwort wird erwartet</strong><a class="button" href="#reply-body">Antwort schreiben</a></div>{{end}}
<div class="ticket-layout">
<aside class="ticket-aside"><details open><summary>Zur Anfrage</summary>
<dl><dt>Status</dt><dd>{{template "status" .Ticket}}</dd>{{if .Ticket.Category}}<dt>Kategorie</dt><dd>{{.Ticket.Category}}</dd>{{end}}{{if gt .Ticket.CreatedAt 0}}<dt>Erstellt</dt><dd>{{template "date" .Ticket.CreatedAt}}</dd>{{end}}</dl>
<h3>Dateien in dieser Anfrage</h3><ul class="ticket-files">{{template "file-links" .Ticket.Attachments}}{{range .Ticket.Entries}}{{template "file-links" .Attachments}}{{end}}</ul><p class="ticket-no-files muted">Keine Dateien angehängt.</p>
<button class="ticket-copy" type="button" hidden>Link zur Anfrage kopieren</button><a class="ticket-direct-link" href="/tickets/{{.Ticket.ID}}">Direktlink zur Anfrage</a><div class="ticket-copy-status muted" role="status"></div>
</details></aside>
<section class="ticket-thread" aria-labelledby="ticket-thread-title">
<h2 id="ticket-thread-title">Verlauf</h2>
<article><h3>{{if .Ticket.Shared}}Teamanfrage{{if .Ticket.SubmittedBy}} von {{.Ticket.SubmittedBy}}{{end}}{{else}}Ihre Anfrage{{end}}{{template "created" .Ticket.CreatedAt}}</h3><div class="body">{{.Ticket.Body}}</div>{{template "attachments" .Ticket.Attachments}}</article>
{{range .Ticket.Entries}}<article><p class="ticket-byline"><strong>{{.Author}}</strong>{{if .FromSupport}} <small class="muted">· Support</small>{{end}}{{template "created" .CreatedAt}}</p><div class="body">{{.Body}}</div>{{template "attachments" .Attachments}}</article>{{end}}
<form method="post" action="/tickets/{{.Ticket.ID}}/reply{{$query}}" enctype="multipart/form-data">
<label for="reply-body">Ihre Antwort</label><textarea id="reply-body" name="body" rows="5" maxlength="32000" required></textarea>
{{template "upload"}}<button>Antwort senden</button></form>
</section></div>
{{else}}
<div class="requests-heading"><div><h1>Meine Anfragen</h1><p>Hier behalten Sie Ihre Anliegen und unsere Antworten im Blick.</p></div><a class="button" href="/new">+ Neue Anfrage</a></div>
{{if .Waiting}}<div class="ticket-callout"><strong>{{if eq .Waiting 1}}1 Anfrage wartet auf Ihre Antwort{{else}}{{.Waiting}} Anfragen warten auf Ihre Antwort{{end}}</strong><a href="/?status=waiting">Anzeigen <span aria-hidden="true">→</span></a></div>{{end}}
{{if .HasTickets}}
<nav class="ticket-tabs" aria-label="Anfragen nach Status filtern"><a href="/{{.Filters.Query ""}}"{{if not .Filters.Status}} aria-current="page"{{end}}>Alle</a><a href="/{{.Filters.Query "waiting"}}"{{if eq .Filters.Status "waiting"}} aria-current="page"{{end}}>Antwort von Ihnen</a><a href="/{{.Filters.Query "active"}}"{{if eq .Filters.Status "active"}} aria-current="page"{{end}}>Offen / In Bearbeitung</a><a href="/{{.Filters.Query "done"}}"{{if eq .Filters.Status "done"}} aria-current="page"{{end}}>Erledigt</a></nav>
<form class="ticket-filters" method="get" action="/">
{{if .Filters.Status}}<input type="hidden" name="status" value="{{.Filters.Status}}">{{end}}
<label>Suche<input type="search" name="q" value="{{.Filters.Search}}" placeholder="Betreff oder Ticketnummer"></label>
<label>Sichtbarkeit<select name="scope"><option value="">Eigene und Teamanfragen</option><option value="own"{{if eq .Filters.Scope "own"}} selected{{end}}>Nur eigene Anfragen</option><option value="team"{{if eq .Filters.Scope "team"}} selected{{end}}>Nur Teamanfragen</option></select></label>
<label>Sortierung<select name="sort"><option value="">Neueste zuerst</option><option value="oldest"{{if eq .Filters.Sort "oldest"}} selected{{end}}>Älteste zuerst</option></select></label><button>Filtern</button>
</form>
{{if .Tickets}}{{$query := .Filters.Query .Filters.Status}}<table class="ticket-table"><thead><tr><th scope="col">Anfrage</th><th scope="col">Status</th><th scope="col" class="ticket-date">Erstellt</th></tr></thead><tbody>{{range .Tickets}}<tr><td><span class="ticket-number muted">#{{.ID}} · </span><a href="/tickets/{{.ID}}{{$query}}">{{.Title}}</a><br><small class="muted">{{if .Shared}}Teamanfrage{{if .SubmittedBy}} · {{.SubmittedBy}}{{end}}{{else}}Meine Anfrage{{end}}</small>{{if gt .CreatedAt 0}}<small class="ticket-date-compact muted">Erstellt: {{template "date" .CreatedAt}}</small>{{end}}</td><td>{{template "status" .}}</td><td class="ticket-date">{{if gt .CreatedAt 0}}{{template "date" .CreatedAt}}{{else}}—{{end}}</td></tr>{{end}}</tbody></table>
{{else}}<section class="requests-empty"><h2>Keine passenden Anfragen</h2><p><a href="/">Filter zurücksetzen</a></p></section>{{end}}
{{else}}<section class="requests-empty"><h2>Noch keine Anfragen</h2><p>Sobald Sie eine Anfrage stellen, erscheint sie hier.</p></section>{{end}}
{{end}}</main>
{{with .Branding}}{{if or .FooterText .ImprintURL .PrivacyURL .TermsURL .ContactURL}}
<footer>{{if .FooterText}}<span>{{.FooterText}}</span>{{end}}<nav aria-label="Rechtliches und Kontakt">
{{if .ImprintURL}}<a href="{{.ImprintURL}}">Impressum</a>{{end}}{{if .PrivacyURL}}<a href="{{.PrivacyURL}}">Datenschutz</a>{{end}}
{{if .TermsURL}}<a href="{{.TermsURL}}">Nutzungsbedingungen</a>{{end}}{{if .ContactURL}}<a href="{{.ContactURL}}">Kontakt</a>{{end}}
</nav></footer>{{end}}{{end}}</body></html>
{{define "upload"}}<div class="attachment-upload"><p>Anhänge (optional)</p><label class="file-upload"><span class="button">Dateien hinzufügen</span><input type="file" name="files" multiple aria-describedby="attachment-hint selected-files"></label><p class="muted" id="selected-files" aria-live="polite"></p><p class="muted attachment-hint" id="attachment-hint">Bis zu 10 Dateien, insgesamt maximal 100 MiB je Nachricht. Bitte keine Passwörter oder Zugangsdaten anhängen.</p></div>{{end}}
{{define "attachments"}}{{if .}}<ul class="attachments" aria-label="Anhänge">{{range .}}<li>{{if .PreviewURL}}<a class="attachment-preview" href="{{.PreviewURL}}" target="_blank" rel="noopener" aria-label="Bild {{.Filename}} öffnen"><img src="{{.PreviewURL}}" alt="Vorschau: {{.Filename}}" loading="lazy" decoding="async"></a>{{end}}<a href="{{.URL}}" download>{{.Filename}}</a> <small class="muted">({{.Size}} Byte)</small></li>{{end}}</ul>{{end}}{{end}}`))
