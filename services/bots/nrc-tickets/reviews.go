package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	p "github.com/heavyhorst/nrc/protocol-go"
)

const guestCookie = "__Host-nrc-review"

// Authenticated encryption keeps both the invitation and guest identity out of
// the URL, browser-readable storage and HTML. There is no second database.
// The key is operator-provisioned; no fallback to the bot secret or random keys.
type guestSession struct {
	Token, ID, Name, RunID, ParticipantID, CSRF string
	Expires                                     int64
}

func randomReviewSecret() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("secure randomness unavailable")
	}
	return hex.EncodeToString(b[:])
}

func (s *portal) guestCipher() (cipher.AEAD, error) {
	if len(s.guestKey) != 32 {
		return nil, fmt.Errorf("guest sessions unavailable")
	}
	b, err := aes.NewCipher(s.guestKey)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}

func guestInvitationCookie(token string) string {
	return fmt.Sprintf("%s-%x", guestCookie, sha256.Sum256([]byte(token)))
}

func (s *portal) saveGuest(w http.ResponseWriter, g guestSession) error {
	if err := s.saveGuestCookie(w, g, guestCookie); err != nil {
		return err
	}
	return s.saveGuestCookie(w, g, guestInvitationCookie(g.Token))
}

func (s *portal) saveGuestCookie(w http.ResponseWriter, g guestSession, name string) error {
	aead, err := s.guestCipher()
	if err != nil {
		return err
	}
	b, err := json.Marshal(g)
	if err != nil {
		return err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	b = aead.Seal(nonce, nonce, b, []byte(name+"|"+s.origin))
	http.SetCookie(w, &http.Cookie{Name: name, Value: base64.RawURLEncoding.EncodeToString(b), Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, Expires: time.Unix(g.Expires, 0), MaxAge: int(g.Expires - time.Now().Unix())})
	return nil
}

func (s *portal) readGuest(r *http.Request) (g guestSession, err error) {
	return s.readGuestCookie(r, guestCookie)
}

func (s *portal) readGuestCookie(r *http.Request, name string) (g guestSession, err error) {
	aead, err := s.guestCipher()
	if err != nil {
		return g, err
	}
	c, err := r.Cookie(name)
	if err != nil || len(c.Value) > 4096 {
		return g, fmt.Errorf("missing session")
	}
	b, err := base64.RawURLEncoding.DecodeString(c.Value)
	if err != nil || len(b) < aead.NonceSize() {
		return g, fmt.Errorf("invalid session")
	}
	b, err = aead.Open(nil, b[:aead.NonceSize()], b[aead.NonceSize():], []byte(name+"|"+s.origin))
	if err != nil {
		return g, err
	}
	if err = json.Unmarshal(b, &g); err != nil || g.Expires <= time.Now().Unix() || g.Expires > time.Now().Add(8*time.Hour).Unix()+60 || g.Token == "" || g.ID == "" || g.CSRF == "" {
		return g, fmt.Errorf("expired session")
	}
	return g, nil
}

func reviewFields(w http.ResponseWriter, r *http.Request, allowed ...string) (url.Values, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	if err := r.ParseForm(); err != nil || len(r.URL.RawQuery) != 0 {
		http.Error(w, "Ungültiges Formular.", 400)
		return nil, false
	}
	for k, values := range r.PostForm {
		valid := false
		for _, a := range allowed {
			valid = valid || k == a
		}
		if !valid || len(values) != 1 || !utf8.ValidString(values[0]) || strings.ContainsRune(values[0], 0) {
			http.Error(w, "Ungültige Formularfelder.", 400)
			return nil, false
		}
	}
	return r.PostForm, true
}

func (s *portal) guestReview(w http.ResponseWriter, r *http.Request) {
	// Never reflect the initial token into a page, redirect or error message.
	if _, err := s.guestCipher(); err != nil {
		http.Error(w, "Gastzugang nicht konfiguriert.", 503)
		return
	}
	if r.Method != "GET" && r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/abnahmen/einladung.js" {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Write(invitationJS)
		return
	}
	if r.URL.Path == "/abnahmen/einladung" {
		if r.Method == "GET" {
			if r.URL.RawQuery != "" {
				w.Header().Set("Referrer-Policy", "no-referrer")
				http.Error(w, "Einladungen verwenden ausschließlich URL-Fragmente.", 400)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Content-Security-Policy", w.Header().Get("Content-Security-Policy")+"; connect-src 'self'")
			w.Write([]byte(`<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Einladung zur Abnahme</title><script src="/abnahmen/einladung.js" defer></script></head><body><p id="status">Einladung wird geöffnet…</p><noscript>Zum sicheren Öffnen der Einladung ist JavaScript erforderlich.</noscript></body></html>`))
			return
		}
		if r.Header.Get("Origin") != s.origin || r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			http.Error(w, "Ungültiger Formularursprung.", 403)
			return
		}
		values, ok := reviewFields(w, r, "token")
		if !ok {
			return
		}
		token := values.Get("token")
		_, hexErr := hex.DecodeString(token)
		if len(token) != 64 || hexErr != nil {
			http.Error(w, "Ungültige Einladung.", 400)
			return
		}
		g := guestSession{Token: token, ID: randomReviewSecret(), CSRF: randomReviewSecret(), Expires: time.Now().Add(8 * time.Hour).Unix()}
		current, currentErr := s.readGuest(r)
		if currentErr == nil && current.Token == token {
			g = current
		} else if previous, err := s.readGuestCookie(r, guestInvitationCookie(token)); err == nil && previous.Token == token {
			g = previous
		}
		// Check live revocation and expiry before changing any cookie, even
		// when restoring a previously accepted invitation's identity.
		if _, ok := s.callReview(w, r, p.ReviewRequest{Op: "invitation_info", Source: "guest", Token: token, GuestID: g.ID}); !ok {
			return
		}
		// Preserve active sessions issued before per-invitation cookies existed.
		if currentErr == nil && current.Token != token {
			if err := s.saveGuestCookie(w, current, guestInvitationCookie(current.Token)); err != nil {
				http.Error(w, "Sitzung nicht verfügbar.", 503)
				return
			}
		}
		if err := s.saveGuest(w, g); err != nil {
			http.Error(w, "Sitzung nicht verfügbar.", 503)
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	g, err := s.readGuest(r)
	if err != nil {
		http.SetCookie(w, &http.Cookie{Name: guestCookie, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: -1})
		http.Error(w, "Gastsitzung abgelaufen. Öffnen Sie eine gültige Einladung erneut.", 403)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/abnahmen/gast/style.css" {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		w.Write(portalCSS)
		w.Write(s.brand.ThemeCSS)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/abnahmen/gast/logo" {
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
	if g.Name == "" {
		if r.URL.Path != "/abnahmen/gast" {
			http.NotFound(w, r)
			return
		}
		if r.Method == "GET" {
			res, ok := s.callReview(w, r, p.ReviewRequest{Op: "invitation_info", Source: "guest", Token: g.Token, GuestID: g.ID})
			if !ok {
				return
			}
			s.renderReview(w, reviewView{Guest: true, Join: true, Title: res.Form.Title, CSRF: g.CSRF, Base: "/abnahmen/gast"})
			return
		}
		v, ok := reviewFields(w, r, "name", "csrf")
		if !ok {
			return
		}
		if subtle.ConstantTimeCompare([]byte(v.Get("csrf")), []byte(g.CSRF)) != 1 {
			http.Error(w, "Ungültige Sitzung.", 403)
			return
		}
		name := strings.TrimSpace(v.Get("name"))
		if name == "" || len(name) > 256 {
			http.Error(w, "Bitte einen Namen angeben (maximal 256 Byte).", 400)
			return
		}
		q := p.ReviewRequest{Op: "guest_join", Source: "guest", Token: g.Token, GuestID: g.ID, Name: name}
		res, ok := s.callReview(w, r, q)
		if !ok {
			return
		}
		if res.Run.ID == "" || res.ParticipantID == "" {
			http.Error(w, "Ungültige Serverantwort.", 502)
			return
		}
		g.Name, g.RunID, g.ParticipantID = name, res.Run.ID, res.ParticipantID
		if err := s.saveGuest(w, g); err != nil {
			http.Error(w, "Sitzung nicht verfügbar.", 503)
			return
		}
		http.Redirect(w, r, "/abnahmen/gast", http.StatusSeeOther)
		return
	}
	action := strings.TrimPrefix(r.URL.Path, "/abnahmen/gast")
	q := p.ReviewRequest{RunID: g.RunID, Source: "guest", Token: g.Token, GuestID: g.ID, Name: g.Name}
	s.reviewRun(w, r, q, "/abnahmen/gast", action, g.CSRF, g.ParticipantID, false)
}

func (s *portal) callReview(w http.ResponseWriter, r *http.Request, q p.ReviewRequest) (*p.ReviewResponse, bool) {
	src, ok := s.source.(reviewSource)
	if !ok {
		http.Error(w, "Abnahmen nicht verfügbar.", 503)
		return nil, false
	}
	res, err := src.review(r.Context(), q)
	if err != nil || res == nil {
		// Do not retry uncertain writes or include upstream errors (tokens).
		http.Error(w, "Serverantwort nicht bestätigt. Bitte aktuellen Stand prüfen; nicht blind erneut senden.", 502)
		return nil, false
	}
	if res.Status != "ok" {
		if res.Status == "conflict" || res.Status == "revision_conflict" {
			http.Error(w, "Abnahme wurde geändert. Neu laden und Abschlussvorschau erneut prüfen.", 409)
		} else {
			http.Error(w, "Abnahme nicht verfügbar oder Zugriff abgelaufen.", 404)
		}
		return nil, false
	}
	return res, true
}

func (s *portal) accountReview(w http.ResponseWriter, r *http.Request, who account) {
	q := p.ReviewRequest{Source: "portal", Identity: who.Requester, Name: who.Name}
	if r.URL.Path == "/abnahmen" {
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		q.Op = "run_list"
		v := reviewView{Base: "/abnahmen"}
		for pages := 0; ; pages++ {
			if pages >= 1000 {
				http.Error(w, "Zu viele Abnahmen.", 502)
				return
			}
			res, ok := s.callReview(w, r, q)
			if !ok {
				return
			}
			for _, run := range res.Runs {
				v.Runs = append(v.Runs, reviewSummary{ID: run.ID, Label: run.Label, Title: run.Title, Decision: run.Decision, Kind: run.Kind, Answered: run.AnsweredPoints})
			}
			if !res.HasMore {
				break
			}
			if !decimal(res.Cursor) || res.Cursor == "" || len(res.Runs) == 0 || len(res.Cursor) < len(q.Cursor) || len(res.Cursor) == len(q.Cursor) && res.Cursor <= q.Cursor {
				http.Error(w, "Ungültiger Abnahmecursor.", 502)
				return
			}
			q.Cursor = res.Cursor
		}
		s.renderReview(w, v)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/abnahmen/"), "/")
	if len(parts) > 2 || !decimal(parts[0]) || parts[0] == "" {
		http.NotFound(w, r)
		return
	}
	q.RunID = parts[0]
	action := ""
	if len(parts) == 2 {
		action = "/" + parts[1]
	}
	if r.Method == "POST" && (action == "/answer" || action == "/close") {
		q.PortalProof = s.writeProof(who)
	}
	s.reviewRun(w, r, q, "/abnahmen/"+q.RunID, action, "", "", false)
}

// Only this deliberately public view reaches templates: no raw assets, tokens,
// participant account identities or staff graph records.
type reviewSummary struct {
	ID, Label, Title, Decision, Kind string
	Answered                         int
}
type reviewContribution struct{ ID, Name, Source, Result, Comment, UpdatedAt string }
type reviewPointView struct {
	ID, Question, Instruction, Expected, Result, Comment string
	Section, Classification, Next                        string
	SavedResult, SavedComment                            string
	Number                                               int
	Active, Visible, Changed, Unanswered, Unable         bool
	Contributions                                        []reviewContribution
	Contradicting                                        bool
}
type reviewSection struct {
	Name, First     string
	Answered, Total int
	Active          bool
}
type reviewView struct {
	Branding                                                                                                                                        branding
	Guest, Join, Preview, CanClose                                                                                                                  bool
	Base, CSRF, Label, Title, Build, Environment, ReleasedAt, Revision, Decision, Comment, ClosedName, ClosedSource, ClosedAt, PreviousRun, Message string
	Runs                                                                                                                                            []reviewSummary
	Points                                                                                                                                          []reviewPointView
	Answered, Total, Contradicting, TeamUnable                                                                                                      int
	Kind                                                                                                                                            string
	Long                                                                                                                                            bool
	Sections                                                                                                                                        []reviewSection
	ActiveSection                                                                                                                                   string
	Snapshot, DraftDecision, DraftComment                                                                                                           string
	ReviewAgain                                                                                                                                     bool
	Passed, Deviating, Unable, Unanswered                                                                                                           int
	UnableStart, UnansweredStart                                                                                                                    int
}

// More than eight points uses server-rendered navigation. Legacy forms are
// batched in groups of eight in the view only; immutable form JSON is untouched.
func (v *reviewView) navigate(pointID string) {
	v.Long = v.Total > 8 && !v.Preview && !v.ReviewAgain && v.Decision == ""
	active := 0
	if pointID == "" {
		for i, p := range v.Points {
			if p.Result == "" {
				active = i
				break
			}
		}
	} else {
		for i, p := range v.Points {
			if p.ID == pointID {
				active = i
				break
			}
		}
	}
	v.Sections = nil
	for i := range v.Points {
		p := &v.Points[i]
		p.Number = i + 1
		if strings.TrimSpace(p.Section) == "" {
			p.Section = fmt.Sprintf("Prüfpunkte %d–%d", i/8*8+1, min(i/8*8+8, v.Total))
		}
		p.Active = i == active
		p.Next = p.ID
		if i+1 < len(v.Points) {
			p.Next = v.Points[i+1].ID
		}
		if p.Active {
			v.ActiveSection = p.Section
		}
		idx := -1
		for j := range v.Sections {
			if v.Sections[j].Name == p.Section {
				idx = j
				break
			}
		}
		if idx < 0 {
			v.Sections = append(v.Sections, reviewSection{Name: p.Section, First: p.ID})
			idx = len(v.Sections) - 1
		}
		v.Sections[idx].Total++
		if p.Result != "" {
			v.Sections[idx].Answered++
		}
	}
	for i := range v.Points {
		v.Points[i].Visible = !v.Long || v.Points[i].Section == v.ActiveSection
	}
	for i := range v.Sections {
		v.Sections[i].Active = v.Sections[i].Name == v.ActiveSection
	}
}

func reviewResult(s string) string {
	switch s {
	case "yes":
		return "Ja"
	case "no":
		return "Nein"
	case "unable":
		return "Nicht prüfbar"
	}
	return s
}

func reviewDecision(s string) string {
	switch s {
	case "accepted":
		return "Abgenommen"
	case "conditional":
		return "Mit Vorbehalt abgenommen"
	case "rejected":
		return "Abgelehnt"
	case "completed":
		return "QA abgeschlossen"
	}
	return "Noch keine Abschlussentscheidung"
}

// Fingerprints identify changed points without echoing team comments into hidden
// fields. They are a comparison aid, never an authorization or revision token.
func reviewSnapshot(points []reviewPointView) string {
	hashes := map[string]string{}
	for _, point := range points {
		data, _ := json.Marshal(point.Contributions)
		hash := sha256.Sum256(data)
		hashes[point.ID] = hex.EncodeToString(hash[:])
	}
	data, _ := json.Marshal(hashes)
	return string(data)
}

func reviewChanges(v *reviewView, previous string) {
	var old, current map[string]string
	_ = json.Unmarshal([]byte(previous), &old)
	_ = json.Unmarshal([]byte(v.Snapshot), &current)
	for i := range v.Points {
		v.Points[i].Changed = old[v.Points[i].ID] != current[v.Points[i].ID]
	}
}

func reviewTime(value string) string {
	ns, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return ""
	}
	return time.Unix(0, ns).UTC().Format("02.01.2006 15:04:05 UTC")
}

func reviewProvenance(source string) string {
	switch source {
	case "guest":
		return "Gastname (Selbstangabe)"
	case "portal":
		return "Portalkonto"
	case "staff":
		return "NRC-Konto"
	}
	return source
}

func (s *portal) reviewRun(w http.ResponseWriter, r *http.Request, q p.ReviewRequest, base, action, csrf, participantID string, closeConflict bool) {
	if action != "" && action != "/answer" && action != "/preview" && action != "/close" || r.Method == "GET" && action != "" {
		http.NotFound(w, r)
		return
	}
	if r.Method == "POST" && action == "" {
		w.WriteHeader(405)
		return
	}
	read := q
	read.Op, read.PortalProof = "run_get", nil
	res, ok := s.callReview(w, r, read)
	if !ok {
		return
	}
	if res.Run.ID != q.RunID || p.ValidateReviewForm(res.Form, true) != nil {
		http.Error(w, "Ungültige Serverantwort.", 502)
		return
	}
	v := reviewView{Guest: q.Source == "guest", Base: base, CSRF: csrf, Label: res.Run.Label, Title: res.Form.Title, Build: res.Form.Build, Environment: res.Form.Environment, ReleasedAt: reviewTime(res.Form.ReleasedAt), Revision: res.Run.Revision, Decision: res.Run.Decision, Comment: res.Run.Comment, ClosedName: res.Run.ClosedName, ClosedSource: reviewProvenance(res.Run.ClosedSource), ClosedAt: reviewTime(res.Run.ClosedAt), PreviousRun: res.Run.PreviousRun}
	v.Kind = res.Run.Kind
	if res.ParticipantID != "" {
		participantID = res.ParticipantID
	}
	sources := map[string]string{}
	for _, person := range res.Run.Participants {
		sources[person.ID] = person.Source
		if person.Source == q.Source && person.ID == participantID {
			participantID = person.ID
			v.CanClose = person.CanClose
		}
	}
	v.CanClose = v.CanClose && res.Run.ClosedAt == "" && res.Run.Decision == ""
	for _, point := range res.Form.Points {
		pv := reviewPointView{ID: point.ID, Section: point.Section, Question: point.Question, Instruction: point.Instruction, Expected: point.Expected}
		results := map[string]bool{}
		for _, answer := range res.Run.Answers {
			if answer.PointID != point.ID {
				continue
			}
			pv.Contributions = append(pv.Contributions, reviewContribution{ID: answer.ID, Name: answer.Name, Source: reviewProvenance(sources[answer.ParticipantID]), Result: reviewResult(answer.Result), Comment: answer.Comment, UpdatedAt: answer.UpdatedAt})
			results[answer.Result] = true
			if answer.ParticipantID == participantID {
				pv.Result, pv.Comment = answer.Result, answer.Comment
				pv.SavedResult, pv.SavedComment = answer.Result, answer.Comment
			}
		}
		pv.Unanswered, pv.Unable = len(results) == 0, results["unable"]
		if pv.Unable {
			v.TeamUnable++
		}
		pv.Contradicting = results["yes"] && results["no"]
		switch {
		case results["no"]:
			pv.Classification = "Mit Abweichung"
			v.Deviating++
		case results["unable"]:
			pv.Classification = "Nicht prüfbar"
			v.Unable++
		case results["yes"]:
			pv.Classification = "Bestanden"
			v.Passed++
		default:
			pv.Classification = "Unbeantwortet"
			v.Unanswered++
		}
		if pv.Contradicting {
			v.Contradicting++
		}
		if pv.Result != "" {
			v.Answered++
		}
		v.Points = append(v.Points, pv)
	}
	v.Total = len(v.Points)
	v.UnableStart = v.Passed + v.Deviating
	v.UnansweredStart = v.UnableStart + v.Unable
	v.Snapshot = reviewSnapshot(v.Points)
	v.navigate(r.URL.Query().Get("point"))
	if r.Method == "POST" {
		values, ok := reviewFields(w, r, "point_id", "result", "comment", "decision", "if_revision", "csrf", "snapshot", "reviewed")
		if !ok {
			return
		}
		if csrf != "" && subtle.ConstantTimeCompare([]byte(values.Get("csrf")), []byte(csrf)) != 1 {
			http.Error(w, "Ungültige Sitzung.", 403)
			return
		}
		q.Comment = values.Get("comment")
		if action == "/answer" {
			v.navigate(values.Get("point_id"))
			for i := range v.Points {
				if v.Points[i].ID == values.Get("point_id") {
					v.Points[i].Result = values.Get("result")
					v.Points[i].Comment = q.Comment
				}
			}
		}
		if len(q.Comment) > 4096 {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(400)
			v.Message = "Kommentar zu lang (maximal 4096 UTF-8-Byte)."
			s.renderReview(w, v)
			return
		}
		if action == "/answer" {
			q.Op, q.PointID, q.Result = "answer", values.Get("point_id"), values.Get("result")
			found := false
			for _, point := range v.Points {
				found = found || point.ID == q.PointID
			}
			if !found || q.Result != "yes" && q.Result != "no" && q.Result != "unable" || v.Decision != "" {
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(400)
				v.Message = "Ungültige Antwort oder bereits abgeschlossen."
				s.renderReview(w, v)
				return
			}
			// Preserve the selected point and draft on a failed acknowledgement.
			ack, err := s.source.(reviewSource).review(r.Context(), q)
			if err != nil || ack == nil || ack.Status != "ok" {
				status := 502
				v.Message = "Serverantwort nicht bestätigt. Bitte aktuellen Stand prüfen; nicht blind erneut senden."
				if ack != nil && (ack.Status == "conflict" || ack.Status == "revision_conflict") {
					status = 409
					v.Message = "Abnahme wurde geändert. Bitte aktuellen Stand neu laden."
				}
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(status)
				s.renderReview(w, v)
				return
			}
			target := base
			if v.Long {
				for _, p := range v.Points {
					if p.ID == q.PointID {
						target += "?point=" + url.QueryEscape(p.Next) + "#point-" + p.Next
						break
					}
				}
			}
			http.Redirect(w, r, target, http.StatusSeeOther)
			return
		}
		if !v.CanClose {
			http.Error(w, "Keine Abschlussberechtigung.", 403)
			return
		}
		q.Decision = values.Get("decision")
		if q.Decision != "accepted" && q.Decision != "conditional" && q.Decision != "rejected" && !(v.Kind == "qa" && q.Decision == "completed") {
			http.Error(w, "Ungültige Entscheidung.", 400)
			return
		}
		v.DraftDecision, v.DraftComment = q.Decision, q.Comment
		if closeConflict || values.Get("if_revision") != "" && values.Get("if_revision") != v.Revision {
			v.ReviewAgain = true
			v.Message = "Die Abnahme wurde seit Ihrer Durchsicht geändert. Entscheidung und Kommentar bleiben als Entwurf erhalten. Prüfen Sie die markierten Punkte und öffnen Sie die aktualisierte Vorschau."
			reviewChanges(&v, values.Get("snapshot"))
			v.navigate("")
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(409)
			s.renderReview(w, v)
			return
		}
		if action == "/close" {
			q.Op, q.IfRevision = "close", values.Get("if_revision")
			if q.IfRevision != v.Revision || values.Get("reviewed") != "yes" {
				http.Error(w, "Bitte die aktuelle Abschlussvorschau prüfen und ausdrücklich bestätigen.", 400)
				return
			}
			ack, err := s.source.(reviewSource).review(r.Context(), q)
			if ack != nil && (ack.Status == "conflict" || ack.Status == "revision_conflict") {
				// An answer may arrive between our read and the transactional close.
				// Re-read and compare against the very same submitted preview.
				s.reviewRun(w, r, q, base, "/preview", csrf, participantID, true)
				return
			}
			if err != nil || ack == nil || ack.Status != "ok" {
				v.ReviewAgain = true
				v.Message = "Abschluss nicht bestätigt. Entwurf erhalten; prüfen Sie den aktuellen Stand, bevor Sie erneut bestätigen."
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(502)
				s.renderReview(w, v)
				return
			}
			http.Redirect(w, r, base, http.StatusSeeOther)
			return
		}
		v.Preview, v.Decision, v.Comment = true, q.Decision, q.Comment
		v.navigate("")
	}
	s.renderReview(w, v)
}

//go:embed web/reviews.html
var reviewHTML string

//go:embed web/invitation.js
var invitationJS []byte
var reviewPage = template.Must(template.New("reviews").Funcs(template.FuncMap{
	"decisionLabel": reviewDecision, "resultLabel": reviewResult, "reviewTime": reviewTime,
	"subtract": func(a, b int) int { return a - b },
}).Parse(reviewHTML))

func (s *portal) renderReview(w http.ResponseWriter, v reviewView) {
	v.Branding = s.brand
	if v.Branding.Brand == "" {
		v.Branding.Brand = "Ihr Kundenportal"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	reviewPage.Execute(w, v)
}
