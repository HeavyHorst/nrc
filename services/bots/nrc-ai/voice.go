package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Voice owns a separate plan store: /ask/apply cannot bypass voice revisions.
// Only the authenticated HTTP apply route can execute writes, never Live events.
type voiceService struct {
	mu           sync.Mutex
	key, baseURL string
	voiceID      string
	client       *http.Client
	ask, apply   http.HandlerFunc
	sessions     map[string]*voiceSession
}

type voiceSession struct {
	mu, sendMu                      sync.Mutex
	id, owner, workspace            string
	conn                            *websocket.Conn
	created, lastPoll               time.Time
	closed, closing, busy, applying bool
	blocked                         bool
	revision                        uint64
	transcript                      string
	lastRole                        string
	result                          *askResponse
	previous                        *askResponse
	resultRevision                  uint64
	applyResult                     json.RawMessage
	applyRevision                   uint64
	err                             string
	seconds                         float64
	finalUsage                      bool
	delegations                     map[string]bool
	pending                         string
	latestDelegation                string
	delegationOffset                *int64
	ctx                             context.Context
	cancel                          context.CancelFunc
}

type voiceRequest struct {
	Workspace string   `json:"workspace"`
	ID        string   `json:"id"`
	SDP       string   `json:"sdp"`
	Revision  uint64   `json:"revision"`
	PlanID    string   `json:"plan_id"`
	ActionIDs []string `json:"action_ids"`
}

func newVoiceService(key, voiceID string, ask, apply http.HandlerFunc) *voiceService {
	return &voiceService{key: key, voiceID: voiceID, baseURL: "https://api.openai.com/v1", client: &http.Client{Timeout: 20 * time.Second}, ask: ask, apply: apply, sessions: make(map[string]*voiceSession)}
}

func (v *voiceService) register(mux *http.ServeMux) {
	for _, op := range []string{"create", "status", "apply", "close"} {
		mux.HandleFunc("POST /voice/"+op, v.handle)
	}
}

func voiceJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(value)
}

func (v *voiceService) handle(w http.ResponseWriter, r *http.Request) {
	// This service, like Ask, is private. The auth proxy strips forged identity headers.
	owner := strings.TrimSpace(r.Header.Get("X-Tailscale-User"))
	if owner == "" {
		http.Error(w, "authentication required", 401)
		return
	}
	var req voiceRequest
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req) != nil || strings.TrimSpace(req.Workspace) == "" {
		http.Error(w, "invalid voice request", 400)
		return
	}
	if r.URL.Path == "/voice/create" {
		v.create(w, r, owner, req)
		return
	}
	v.mu.Lock()
	s := v.sessions[req.ID]
	v.mu.Unlock()
	if s == nil || s.owner != owner || s.workspace != req.Workspace {
		http.Error(w, "voice session not found", 404)
		return
	}
	s.mu.Lock()
	s.lastPoll = time.Now()
	switch r.URL.Path {
	case "/voice/status":
		defer s.mu.Unlock()
		var result *askResponse
		if s.result != nil && s.resultRevision == s.revision {
			result = s.result
		}
		voiceJSON(w, map[string]any{"id": s.id, "revision": s.revision, "busy": s.busy, "applying": s.applying,
			"closed": s.closed || s.closing, "transcript": s.transcript, "result": result, "apply_result": s.applyResult,
			"apply_revision": s.applyRevision, "error": s.err, "seconds": s.seconds, "final_usage": s.finalUsage})
	case "/voice/close":
		s.mu.Unlock()
		s.close()
		voiceJSON(w, map[string]bool{"ok": true})
	case "/voice/apply":
		v.confirm(w, s, req) // releases s.mu before executing writes
	default:
		s.mu.Unlock()
		http.NotFound(w, r)
	}
}

func (v *voiceService) create(w http.ResponseWriter, r *http.Request, owner string, req voiceRequest) {
	if v.key == "" || v.ask == nil {
		http.Error(w, "GPT-Live is not configured", 503)
		return
	}
	if strings.TrimSpace(req.SDP) == "" {
		http.Error(w, "SDP required", 400)
		return
	}
	// Reserve before the upstream call; parallel clicks cannot create billed duplicates.
	v.mu.Lock()
	for _, s := range v.sessions {
		s.mu.Lock()
		active := !s.closed
		s.mu.Unlock()
		if s.owner == owner && active {
			v.mu.Unlock()
			http.Error(w, "voice session already exists; end it first", 409)
			return
		}
	}
	id := newAgentSessionID()
	ctx, cancel := context.WithCancel(context.Background())
	s := &voiceSession{id: id, owner: owner, workspace: req.Workspace, created: time.Now(), lastPoll: time.Now(), ctx: ctx, cancel: cancel, delegations: make(map[string]bool)}
	v.sessions[id] = s
	v.mu.Unlock()
	ok := false
	defer func() {
		if !ok {
			cancel()
			v.mu.Lock()
			delete(v.sessions, id)
			v.mu.Unlock()
		}
	}()
	session := map[string]any{"model": "gpt-live-1", "delegation": map[string]string{"type": "client"},
		"instructions": `Du bist Sullivan. Sprich kurz und natürlich auf Deutsch.
Deine Stimme ist eigenständig, erwachsen und männlich, mit tiefem bis mittlerem Register, leicht rauer und trockener Stimmtextur und dezenter norddeutscher Färbung. Sprich ruhig, sachlich, direkt und kollegial, mit präziser Artikulation, bedächtigem, aber flüssigem Tempo, kurzen natürlichen Denkpausen, normaler Lautstärke und zurückhaltender Wärme. Keine pathetische Rednerstimme, keine Karikatur und keine Nachahmung einer realen Person.
Dein Charakter: norddeutsches Understatement, trockener Charme, wenig Theater. Antworte klar statt mit Servicefloskeln, übertriebenem Lob oder ständigen Begrüßungen. Sei herzlich und aufmerksam, ohne aufgesetzte Vertraulichkeit oder Unterwürfigkeit. Ein gelegentlicher kurzer, trockener Kommentar passt, wenn er sich natürlich ergibt; erzwinge keine Pointe und mache keine Witze auf Kosten des Nutzers. Bei Fehlern, Frust und ernsten Themen lässt du den Humor weg.
Denke im Gespräch mit: Benenne Widersprüche in den vorliegenden Informationen, frage gezielt nach, wenn etwas Entscheidendes fehlt, und widersprich freundlich, wenn die belegten Fakten dagegen sprechen. Gib zuerst die hilfreiche Antwort, statt Suchergebnisse bloß vorzulesen. Nimm Korrekturen ohne Rechtfertigung an. Erfinde für deinen Charme weder Fakten noch gemeinsame Erinnerungen, persönliche Erlebnisse oder Erfolgsmeldungen. Sage offen, was unklar ist; Charakter und Humor ändern nichts an Backend-Delegation, Faktentreue oder Freigaberegeln.
Titel und technische Bezeichner sind wörtliche Zitate aus dem Backend, keine Zusammenfassungen. Übersetze, korrigiere oder ersetze darin keine Wörter. Lies einen Titel einmal flüssig und etwas langsamer vor, ohne Anläufe, wiederholte Wortfragmente oder Pausen innerhalb eines Wortes. Sprich englische Titelwörter auf Englisch, auch in einer deutschen Antwort, mit vollständigen Wortenden.
Lies Großbuchstaben-Abkürzungen als einzelne deutsche Buchstabennamen. Sprich bei Pfaden, Repository-Namen und anderen technischen Bezeichnern die Trennzeichen ausdrücklich: / als Schrägstrich, _ als Unterstrich, - als Bindestrich und . als Punkt. Wenn der Nutzer einen technischen Bezeichner exakt verlangt oder seine Aussprache unklar ist, buchstabiere ihn mit diesen Trennzeichen, statt ähnlich klingende Wörter zu erfinden.
Beim Buchstabieren verwende ausschließlich deutsche Buchstabennamen, auch für englische Bezeichner: A = A, B = Be, C = Ze, D = De, E = E, F = Eff, G = Ge, H = Ha, I = I, J = Jot, K = Ka, L = Ell, M = Em, N = En, O = O, P = Pe, Q = Ku, R = Er, S = Es, T = Te, U = U, V = Vau, W = We, X = Iks, Y = Ypsilon, Z = Zett. Sprich jeden Namen vollständig mit einer kurzen Pause danach. Lass keinen Buchstaben aus und fasse keine benachbarten Buchstaben zu einem Wort zusammen. Erhalte den Originaltext im Client; Aussprachehilfen sind keine geänderten Daten.
Delegiere alle NRC-Fragen und Änderungswünsche an das Backend. Erfinde keine Workspace-Fakten. Änderungen sind nur Vorschläge, bis der Nutzer sie im Client per Klick bestätigt. Gesprochene Zustimmung ist KEINE Freigabe. Behaupte niemals eine Speicherung ohne bestätigtes Backend-Ergebnis. Bei Korrekturen delegiere den aktualisierten Auftrag erneut.`}
	if v.voiceID != "" {
		session["audio"] = map[string]any{"output": map[string]any{"voice": map[string]string{"id": v.voiceID}}}
	}
	body, _ := json.Marshal(map[string]any{
		"session":   session,
		"transport": map[string]string{"type": "webrtc", "sdp": req.SDP},
	})
	up, _ := http.NewRequestWithContext(r.Context(), "POST", v.baseURL+"/live/sessions", bytes.NewReader(body))
	up.Header.Set("Authorization", "Bearer "+v.key)
	up.Header.Set("Content-Type", "application/json")
	res, err := v.client.Do(up) // Deliberately no retry: creation is billable.
	if err != nil {
		http.Error(w, "Live creation failed; upstream outcome unknown", 502)
		return
	}
	defer res.Body.Close()
	var created struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
		Transport struct {
			SDP string `json:"sdp"`
		} `json:"transport"`
	}
	if res.StatusCode != 201 || json.NewDecoder(io.LimitReader(res.Body, 128<<10)).Decode(&created) != nil || created.Session.ID == "" || created.Transport.SDP == "" {
		http.Error(w, "Live session unavailable; check model access and server configuration", 502)
		return
	}
	attach := strings.Replace(v.baseURL, "http", "ws", 1) + "/live/sessions/" + url.PathEscape(created.Session.ID) + "/attach"
	headers := http.Header{"Authorization": []string{"Bearer " + v.key}}
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	s.conn, _, err = dialer.DialContext(r.Context(), attach, headers)
	if err != nil {
		// Return the SDP so the browser can send session.close on the primary channel.
		voiceJSON(w, map[string]any{"id": id, "sdp": created.Transport.SDP, "close_only": true})
		return
	}
	ok = true
	go v.listen(s)
	go v.watch(s)
	voiceJSON(w, map[string]any{"id": id, "sdp": created.Transport.SDP, "max_seconds": 600})
}

func (s *voiceSession) send(kind, delegation, message string) {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if s.conn == nil {
		return
	}
	event := map[string]any{"type": kind}
	if message != "" {
		event["content"] = message
		event["delegation_id"] = nil
		if delegation != "" {
			event["delegation_id"] = delegation
		}
	}
	_ = s.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_ = s.conn.WriteJSON(event)
}

func (s *voiceSession) close() {
	s.mu.Lock()
	if s.closed || s.closing {
		s.mu.Unlock()
		return
	}
	s.closing = true
	s.result = nil
	s.cancel()
	s.mu.Unlock()
	s.send("session.close", "", "")
	// Preserve the socket long enough to collect final usage.
	time.AfterFunc(15*time.Second, func() { _ = s.conn.Close() })
}

func (v *voiceService) watch(s *voiceSession) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for range ticker.C {
		s.mu.Lock()
		closed := s.closed
		expired := time.Since(s.created) >= 10*time.Minute || time.Since(s.lastPoll) > 20*time.Second
		s.mu.Unlock()
		if closed {
			break
		}
		if expired {
			s.close()
		}
	}
	// Keep the terminal result briefly available after a lost Apply HTTP response.
	time.Sleep(time.Minute)
	v.mu.Lock()
	delete(v.sessions, s.id)
	v.mu.Unlock()
}

func (v *voiceService) listen(s *voiceSession) {
	defer func() {
		s.cancel()
		s.mu.Lock()
		s.closed = true
		s.result = nil
		s.mu.Unlock()
		_ = s.conn.Close()
	}()
	s.conn.SetReadLimit(2 << 20)
	for {
		var event struct {
			Type       string                      `json:"type"`
			Delta      string                      `json:"delta"`
			StartMS    *int64                      `json:"start_ms"`
			OffsetMS   *int64                      `json:"offset_ms"`
			Delegation struct{ ID, Target string } `json:"delegation"`
			Usage      struct {
				Seconds float64 `json:"seconds"`
			} `json:"usage"`
		}
		if s.conn.ReadJSON(&event) != nil {
			return
		}
		s.mu.Lock()
		switch event.Type {
		case "session.input_transcript.delta", "session.output_transcript.delta":
			if event.Type == "session.input_transcript.delta" {
				s.revision++
				s.result = nil // invalidate on speech, not only on the next delegation
				// A delayed fragment recorded before the delegation still belongs to
				// that task, even after its answer was published. Newer utterances
				// require a new delegation; never revive an already consumed approval.
				if s.latestDelegation != "" && s.delegationOffset != nil && event.StartMS != nil && *event.StartMS <= *s.delegationOffset && !s.applying && !s.closing && !s.blocked {
					s.pending = s.latestDelegation
					if !s.busy {
						go v.run(s)
					}
				}
			}
			role := "Sullivan"
			if event.Type == "session.input_transcript.delta" {
				role = "Nutzer"
			}
			if role != s.lastRole {
				s.transcript += "\n" + role + ": "
				s.lastRole = role
			}
			s.transcript += event.Delta
			if len(s.transcript) > 24000 {
				// Do not silently lose corrections or confirmed mutation outcomes.
				s.err = "Gesprächskontext voll. Bitte Gespräch beenden."
				s.mu.Unlock()
				s.close()
				continue
			}
		case "session.delegation.created":
			id := event.Delegation.ID
			if id != "" && event.Delegation.Target == "client" && !s.delegations[id] && !s.closing && !s.blocked {
				if len(s.delegations) >= 64 {
					s.mu.Unlock()
					s.close()
					continue
				}
				s.delegations[id] = true
				s.revision++ // a newer delegation supersedes even without another transcript delta
				s.latestDelegation, s.delegationOffset = id, event.OffsetMS
				s.pending = id
				s.result = nil
				if !s.busy && !s.applying {
					go v.run(s)
				}
			}
		case "session.usage.updated":
			s.seconds = event.Usage.Seconds
		case "session.closed":
			s.seconds, s.finalUsage = event.Usage.Seconds, true
			s.mu.Unlock()
			return
		case "error":
			s.err = "GPT-Live meldet einen Fehler. Gespräch beenden und Konfiguration prüfen."
		}
		s.mu.Unlock()
	}
}

// Adapt the existing HTTP handlers without a second network/authentication hop.
// Voice requests and their private plan store never enter the public Ask routes.
type voiceResponse struct {
	bytes.Buffer
	header http.Header
	status int
}

func (w *voiceResponse) Header() http.Header    { return w.header }
func (w *voiceResponse) WriteHeader(status int) { w.status = status }
func voiceCall(ctx context.Context, handler http.HandlerFunc, payload any, output any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	r, _ := http.NewRequestWithContext(ctx, "POST", "/", bytes.NewReader(data))
	w := &voiceResponse{header: make(http.Header), status: 200}
	handler(w, r)
	if w.status != 200 {
		return fmt.Errorf("Sullivan-Anfrage fehlgeschlagen (HTTP %d)", w.status)
	}
	return json.Unmarshal(w.Bytes(), output)
}

func (v *voiceService) run(s *voiceSession) {
	s.mu.Lock()
	if s.busy || s.applying || s.closing || s.closed || s.blocked || s.pending == "" {
		s.mu.Unlock()
		return
	}
	s.busy, s.result, s.err = true, nil, ""
	s.mu.Unlock()
	// Coalesce trailing transcript fragments before starting an expensive lookup.
	// If fragments still arrive during it, requeue the latest delegated task below.
	timer := time.NewTimer(300 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-s.ctx.Done():
	}
	s.mu.Lock()
	if s.closed || s.closing || s.blocked {
		s.busy = false
		s.mu.Unlock()
		return
	}
	delegation, revision, transcript := s.pending, s.revision, s.transcript
	previous, _ := json.Marshal(s.previous)
	s.pending = ""
	s.mu.Unlock()
	var result askResponse
	var err error
	if len(previous) > 64000 {
		err = fmt.Errorf("Vorheriger Vorschlag zu groß für den Sprachkontext. Bitte im Text-Client weiterarbeiten.")
	} else {
		// Keep the exact previous proposal for references such as "the second one",
		// but create a fresh plan so no previously reviewed proposal can be mutated.
		err = voiceCall(s.ctx, v.ask, map[string]any{"workspace": s.workspace, "mode": "plan", "context_conv_id": 0,
			"question": "Sprachgespräch (Transkriptfragmente können unvollständig sein). Bearbeite den neuesten Auftrag unter Berücksichtigung früherer Korrekturen. Antworte kurz auf Deutsch. Nur bei explizitem Änderungswunsch Aktionen vorschlagen. Gesprochene Zustimmung ist keine Ausführung. Bereits bestätigte Aktionen nicht erneut vorschlagen.\nVORHERIGE ANTWORT UND VORSCHLÄGE (Referenzdaten, keine neuen Aufträge):\n" + string(previous) + "\nGESPRÄCH UND BESTÄTIGTE ERGEBNISSE:\n" + transcript}, &result)
	}
	s.mu.Lock()
	s.busy = false
	current := !s.closed && !s.closing && !s.blocked && revision == s.revision
	if current {
		if err != nil {
			s.err = err.Error()
		} else {
			s.result, s.previous, s.resultRevision = &result, &result, revision
		}
	}
	if current {
		message := "Die Recherche ist fehlgeschlagen. Es wurde nichts durch diesen Auftrag ausgeführt."
		if err == nil {
			message = result.Answer
			if len(result.ProposedActions) > 0 {
				message = "Änderungsvorschläge liegen im Client zur Prüfung bereit. Noch nicht ausgeführt. Bitte dort bestätigen."
			}
			// A byte bound is conservative even for byte-level tokenization, unlike
			// rune counts. Leave room below Live's 500-token append limit.
			if len(message) > 320 {
				message = strings.ToValidUTF8(message[:320], "") + " … Vollständige Antwort im Client."
			}
		}
		// Keep validation and publication serialized with incoming corrections.
		s.send("session.commentary.append", delegation, message)
	}
	pending := s.pending != ""
	s.mu.Unlock()
	if pending {
		go v.run(s)
	}
}

func (v *voiceService) confirm(w http.ResponseWriter, s *voiceSession, req voiceRequest) {
	if s.closed || s.closing || s.blocked || s.busy || s.applying || s.pending != "" || s.result == nil || s.revision != req.Revision || s.resultRevision != req.Revision || req.PlanID == "" || req.PlanID != s.result.PlanID || len(req.ActionIDs) == 0 {
		s.mu.Unlock()
		http.Error(w, "Plan veraltet, beschäftigt oder keine Auswahl. Erneut prüfen.", 409)
		return
	}
	allowed := make(map[string]bool)
	for _, action := range s.result.ProposedActions {
		allowed[action.ID] = true
	}
	for _, id := range req.ActionIDs {
		if !allowed[id] {
			s.mu.Unlock()
			http.Error(w, "invalid action selection", 400)
			return
		}
	}
	payload := askApplyRequest{Workspace: s.workspace, AgentSessionID: s.result.AgentSessionID, PlanID: req.PlanID, ActionIDs: req.ActionIDs}
	// Consume the approval before releasing the lock. Never retry even if HTTP
	// delivery fails; status retains the result for recovery. A new plan is needed
	// for remaining actions. Spoken corrections cannot cancel committed writes.
	s.applying, s.result, s.applyResult = true, nil, nil
	s.latestDelegation, s.delegationOffset = "", nil
	s.applyRevision, s.err = req.Revision, ""
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	var result askApplyResponse
	err := voiceCall(ctx, v.apply, payload, &result)
	uncertain := err != nil || !result.OK || len(result.Failed) > 0
	s.mu.Lock()
	s.applying = false
	if err == nil {
		s.applyResult, _ = json.Marshal(result)
		s.transcript += "\nBackend: Ergebnis der Bestätigung (Fehler können unbekannte Schreibausgänge enthalten): " + string(s.applyResult)
		s.lastRole = "Backend"
	}
	if uncertain {
		// Existing Apply failures can include writes that committed without an ack.
		// Conservatively stop on *any* failure, even HTTP 200, until reconciled.
		s.blocked, s.pending = true, ""
		s.err = "Ausgang mindestens einer Aktion unbestätigt oder abgelehnt. Datensätze prüfen; nichts erneut anwenden."
	}
	pending := s.pending != ""
	s.mu.Unlock()
	if uncertain {
		s.send("session.commentary.append", "", "Mindestens eine Aktion muss geprüft werden. Sie könnte bereits gespeichert sein. Bitte Datensätze im Client prüfen und nichts erneut ausführen.")
		s.close()
	}
	if err != nil {
		http.Error(w, "Ausgang unklar. Status und Datensätze prüfen; nicht erneut anwenden.", 502)
	} else {
		if !uncertain {
			s.send("session.commentary.append", "", fmt.Sprintf("Ergebnis der Bestätigung im Client: %d Aktionen erfolgreich. Details im Client. Keine übrigen Aktionen automatisch ausführen.", len(result.Applied)))
		}
		voiceJSON(w, result)
	}
	if pending {
		go v.run(s)
	}
}
