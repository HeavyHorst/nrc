package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	memory "nrc-ai/personal_memory"
)

// Voice owns a separate plan store: /ask/apply cannot bypass voice revisions.
// Only the authenticated HTTP apply route can execute writes, never Live events.
type voiceService struct {
	mu           sync.Mutex
	work         sync.WaitGroup
	stopping     bool
	ctx          context.Context
	cancel       context.CancelFunc
	key, baseURL string
	voiceID      string
	client       *http.Client
	ask, apply   http.HandlerFunc
	sessions     map[string]*voiceSession
}

type voiceSession struct {
	mu, sendMu                      sync.Mutex
	contextDelivery                 map[string]*voiceContextDelivery
	id, owner, workspace            string
	identity                        aiIdentity
	memory                          *personalMemoryAccess
	memoryCaptures                  []*personalCapture
	memoryEvents                    map[string]bool
	providerSession                 string
	conn                            *websocket.Conn
	created, lastPoll               time.Time
	closed, closing, busy, applying bool
	blocked                         bool
	memoryInvalidated               bool
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
	captureComplete                 bool
	delegations                     map[string]bool
	pending                         string
	latestDelegation                string
	delegationOffset                *int64
	ctx                             context.Context
	cancel                          context.CancelFunc
}

// Provider timeline acknowledgment is not proof of speech or audio playback.
type voiceContextDelivery struct {
	State   string `json:"state"`
	StartMS *int64 `json:"start_ms,omitempty"`
	EndMS   *int64 `json:"end_ms,omitempty"`
}

type voiceRequest struct {
	RequireMemory   bool     `json:"require_memory,omitempty"`
	ExecutionPolicy string   `json:"execution_policy,omitempty"`
	Workspace       string   `json:"workspace"`
	ID              string   `json:"id"`
	SDP             string   `json:"sdp"`
	Revision        uint64   `json:"revision"`
	PlanID          string   `json:"plan_id"`
	ActionIDs       []string `json:"action_ids"`
}

func newVoiceService(key, voiceID string, ask, apply http.HandlerFunc) *voiceService {
	ctx, cancel := context.WithCancel(context.Background())
	return &voiceService{ctx: ctx, cancel: cancel, key: key, voiceID: voiceID, baseURL: "https://api.openai.com/v1", client: &http.Client{Timeout: 20 * time.Second}, ask: ask, apply: apply, sessions: make(map[string]*voiceSession)}
}

// Stop admission before waiting. Every background memory consumer is launched
// by an already-counted handler/listener/run, so the count cannot hit zero while
// new work is being registered. Approved writes retain their own bounded context.
func (v *voiceService) shutdown(ctx context.Context) error {
	v.mu.Lock()
	v.stopping = true
	v.cancel()
	v.mu.Unlock()
	done := make(chan struct{})
	go func() { v.work.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (v *voiceService) startRun(s *voiceSession) {
	v.work.Add(1)
	go func() { defer v.work.Done(); v.run(s) }()
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
	v.mu.Lock()
	if v.stopping {
		v.mu.Unlock()
		http.Error(w, "voice service shutting down", http.StatusServiceUnavailable)
		return
	}
	v.work.Add(1)
	v.mu.Unlock()
	defer v.work.Done()
	var req voiceRequest
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req) != nil || strings.TrimSpace(req.Workspace) == "" {
		http.Error(w, "invalid voice request", 400)
		return
	}
	identity, authorized := requireAIIdentity(w, r, req.Workspace)
	if !authorized {
		return
	}
	if r.URL.Path == "/voice/create" {
		v.create(w, r, identity, req)
		return
	}
	v.mu.Lock()
	s := v.sessions[req.ID]
	v.mu.Unlock()
	if s == nil || s.owner != identity.owner() || s.workspace != req.Workspace {
		http.Error(w, "voice session not found", 404)
		return
	}
	if s.memory != nil {
		policy, err := s.memory.scope.Retention(r.Context())
		if err != nil || !policy.Enabled || policy.Epoch != s.memory.scope.Epoch() {
			s.close()
			s.mu.Lock()
			s.invalidateMemory()
			if r.URL.Path == "/voice/status" {
				defer s.mu.Unlock()
				voiceJSON(w, map[string]any{"closed": true, "memory_invalidated": true, "applying": s.applying,
					"apply_revision": s.applyRevision, "apply_result": s.applyResult, "error": s.err})
				return
			}
			s.mu.Unlock()
			http.Error(w, "personal memory changed; voice session ended", 409)
			return
		}
	}
	s.mu.Lock()
	s.lastPoll = time.Now()
	s.identity = identity // Fresh proxy authorization renews the background lease.
	switch r.URL.Path {
	case "/voice/status":
		defer s.mu.Unlock()
		var result *askResponse
		if s.result != nil && s.resultRevision == s.revision {
			result = s.result
		}
		voiceJSON(w, map[string]any{"id": s.id, "revision": s.revision, "busy": s.busy, "applying": s.applying,
			"closed": s.closed || s.closing, "memory_invalidated": s.memoryInvalidated, "transcript": s.transcript, "result": result, "apply_result": s.applyResult,
			"apply_revision": s.applyRevision, "error": s.err, "seconds": s.seconds, "final_usage": s.finalUsage,
			"context_delivery": s.contextDelivery})
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

func (v *voiceService) create(w http.ResponseWriter, r *http.Request, identity aiIdentity, req voiceRequest) {
	if v.key == "" || v.ask == nil {
		http.Error(w, "GPT-Live is not configured", 503)
		return
	}
	if strings.TrimSpace(req.SDP) == "" {
		http.Error(w, "SDP required", 400)
		return
	}
	policy, err := executionPolicy(req.ExecutionPolicy)
	if err != nil || policy == "workspace" {
		http.Error(w, "voice requires private or temporary execution", 400)
		return
	}
	personal, err := personalMemoryFor(r.Context(), identity, policy)
	if err != nil {
		http.Error(w, "personal memory access denied", 403)
		return
	}
	if req.RequireMemory && personal == nil {
		http.Error(w, "personal memory unavailable; voice not started", 409)
		return
	}
	ctx, cancel := context.WithCancel(v.ctx)
	keep := false
	defer func() {
		if !keep {
			cancel()
		}
	}()
	if personal != nil {
		var release func()
		var leaseCtx context.Context
		personal, leaseCtx, release, err = personal.execution(ctx)
		if err != nil {
			http.Error(w, "personal retention unavailable", 409)
			return
		}
		parentCancel := cancel
		ctx, cancel = leaseCtx, func() { release(); parentCancel() }
	}
	creationCtx, creationCancel := context.WithCancel(r.Context())
	stopCreation := context.AfterFunc(ctx, creationCancel)
	defer stopCreation()
	defer creationCancel()
	r = r.WithContext(creationCtx)
	var history string
	if personal != nil {
		history, err = personal.overview(r.Context())
		if err != nil {
			http.Error(w, "personal memory unavailable", 503)
			return
		}
	}
	// Reserve before the upstream call; parallel clicks cannot create billed duplicates.
	v.mu.Lock()
	for _, s := range v.sessions {
		s.mu.Lock()
		active := !s.closed
		s.mu.Unlock()
		if s.owner == identity.owner() && active {
			v.mu.Unlock()
			http.Error(w, "voice session already exists; end it first", 409)
			return
		}
	}
	id := newAgentSessionID()
	s := &voiceSession{id: id, owner: identity.owner(), identity: identity, workspace: req.Workspace, created: time.Now(), lastPoll: time.Now(), ctx: ctx, cancel: cancel, delegations: make(map[string]bool)}
	s.memory = personal
	if personal != nil {
		s.memoryEvents = make(map[string]bool)
	}
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
	session := map[string]any{"model": "gpt-live-1", "store": false, "delegation": map[string]string{"type": "client"},
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
	session["instructions"] = session["instructions"].(string) + privateExecutionInstructions
	if personal != nil {
		session["instructions"] = session["instructions"].(string) + personalMemoryInstructions + "\nDelegate personal historical questions to the backend for tree expansion and exact original reads."
		session["input"] = []any{map[string]any{"type": "message", "role": "user", "content": []any{map[string]string{"type": "input_text", "text": history}}}}
	} else {
		session["instructions"] = session["instructions"].(string) + temporaryMemoryInstructions
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
	s.providerSession = created.Session.ID
	headers := http.Header{"Authorization": []string{"Bearer " + v.key}}
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	s.conn, _, err = dialer.DialContext(r.Context(), attach, headers)
	if err != nil {
		// Creation already succeeded. Forgetting or a lost HTTP request must not
		// leave cleanup dependent on a browser receiving the response. Attach only
		// to close this existing session; never retry billable creation.
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		conn, _, cleanupErr := dialer.DialContext(cleanupCtx, attach, headers)
		if cleanupErr == nil {
			deadline, _ := cleanupCtx.Deadline()
			_ = conn.SetWriteDeadline(deadline)
			cleanupErr = conn.WriteJSON(map[string]string{"type": "session.close"})
			_ = conn.Close()
		}
		if cleanupErr != nil {
			slog.Warn("Live startup cleanup failed; provider closure unconfirmed")
		}
		// Keep the primary-channel close as a fallback if server cleanup fails.
		voiceJSON(w, map[string]any{"id": id, "sdp": created.Transport.SDP, "close_only": true})
		return
	}
	ok = true
	keep = true
	v.work.Add(2)
	go func() {
		defer v.work.Done()
		<-s.ctx.Done()
		if personal != nil {
			checkCtx, checkCancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer checkCancel()
			policy, err := s.memory.scope.Retention(checkCtx)
			if err != nil || !policy.Enabled || policy.Epoch != s.memory.scope.Epoch() {
				s.mu.Lock()
				s.invalidateMemory()
				s.mu.Unlock()
			}
		}
		s.close()
	}()
	go func() { defer v.work.Done(); v.listen(s) }()
	go v.watch(s)
	voiceJSON(w, map[string]any{"id": id, "sdp": created.Transport.SDP, "max_seconds": 600})
}

func (s *voiceSession) send(event map[string]any) bool {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if s.conn == nil {
		return false
	}
	_ = s.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return s.conn.WriteJSON(event) == nil
}

// Caller holds s.mu so an early acknowledgment cannot precede registration.
func (s *voiceSession) appendCommentary(delegation, message string) {
	if s.contextDelivery == nil {
		s.contextDelivery = make(map[string]*voiceContextDelivery)
	}
	id := fmt.Sprintf("nrc-context-%d", len(s.contextDelivery)+1)
	delivery := &voiceContextDelivery{State: "pending"}
	s.contextDelivery[id] = delivery
	if s.closed || s.closing {
		delivery.State = "unconfirmed"
		return
	}
	event := map[string]any{"type": "session.commentary.append", "event_id": id, "delegation_id": nil, "content": message}
	if delegation != "" {
		event["delegation_id"] = delegation
	}
	if !s.send(event) {
		delivery.State = "unconfirmed"
	}
}

// Caller holds s.mu. Keep only receipt identifiers after history invalidation,
// including when cancellation races with completion of an approved write.
func (s *voiceSession) invalidateMemory() {
	s.memoryInvalidated, s.blocked = true, true
	s.transcript, s.pending, s.err = "", "", "Personal memory changed; check approval outcome before retrying."
	s.previous, s.result, s.memoryCaptures = nil, nil, nil
	s.applyResult = minimalVoiceReceipt(s.applyResult)
}

func minimalVoiceReceipt(raw json.RawMessage) json.RawMessage {
	// Decode into an allowlist: never retain titles, raw errors, or edge fields.
	type entity struct {
		ID uint64 `json:"id"`
	}
	type action struct {
		ActionID      string  `json:"action_id"`
		Entity        *entity `json:"entity,omitempty"`
		CreatedEntity *entity `json:"created_entity,omitempty"`
		DeletedEntity *entity `json:"deleted_entity,omitempty"`
	}
	var receipt struct {
		OK      bool     `json:"ok"`
		Applied []action `json:"applied"`
		Failed  []struct {
			ActionID string `json:"action_id"`
		} `json:"failed"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &receipt) != nil {
		return nil
	}
	result, _ := json.Marshal(receipt)
	return result
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
	s.send(map[string]any{"type": "session.close"})
	// Preserve the socket long enough to collect final usage.
	time.AfterFunc(15*time.Second, func() { _ = s.conn.Close() })
}

func (v *voiceService) watch(s *voiceSession) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for range ticker.C {
		s.mu.Lock()
		closed := s.closed
		expired := time.Since(s.created) >= 10*time.Minute || time.Since(s.lastPoll) > 20*time.Second || time.Now().Unix() >= s.identity.ExpiresAt
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
		for _, delivery := range s.contextDelivery {
			if delivery.State == "pending" {
				delivery.State = "unconfirmed"
			}
		}
		captures := append([]*personalCapture{}, s.memoryCaptures...)
		state := "incomplete"
		if s.captureComplete && s.err == "" {
			state = "complete"
		}
		s.mu.Unlock()
		sealCtx, sealCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer sealCancel()
		for _, capture := range captures {
			if capture.segment.State != "active" {
				continue
			}
			if err := capture.scope.Finish(sealCtx, capture.segment.Sequence, capture.segment.Revision, state, capture.segment.Records); err != nil {
				s.mu.Lock()
				s.err = "Persönlicher Verlauf konnte nicht vollständig abgeschlossen werden."
				s.mu.Unlock()
				break
			}
		}
		_ = s.conn.Close()
	}()
	s.conn.SetReadLimit(2 << 20)
	for {
		var event struct {
			Type          string `json:"type"`
			EventID       string `json:"event_id"`
			ClientEventID string `json:"client_event_id"`
			Error         struct {
				ClientEventID string `json:"client_event_id"`
			} `json:"error"`
			Delta      string                      `json:"delta"`
			StartMS    *int64                      `json:"start_ms"`
			EndMS      *int64                      `json:"end_ms"`
			Reason     string                      `json:"reason"`
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
		case "session.commentary.appended":
			if delivery := s.contextDelivery[event.ClientEventID]; delivery != nil && delivery.State == "pending" {
				delivery.State, delivery.StartMS, delivery.EndMS = "acknowledged", event.StartMS, event.EndMS
			}
		case "session.input_transcript.delta", "session.output_transcript.delta":
			if s.memory != nil {
				if s.memoryEvents[event.EventID] {
					s.mu.Unlock()
					continue
				}
				role := "assistant"
				if event.Type == "session.input_transcript.delta" {
					role = "user"
				}
				if event.EventID == "" || len(s.memoryEvents) >= 4096 || time.Now().Unix() >= s.identity.ExpiresAt {
					s.err = "Persönlicher Verlauf unvollständig. Gespräch beendet."
					s.mu.Unlock()
					s.close()
					continue
				}
				captureCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				err := s.captureFragment(captureCtx, memory.Record{Role: role, Text: event.Delta, EventID: event.EventID, ProviderSession: s.providerSession, StartMS: event.StartMS, EndMS: event.EndMS})
				cancel()
				if err != nil {
					s.err = "Persönlicher Verlauf konnte nicht gespeichert werden."
					s.mu.Unlock()
					s.close()
					continue
				}
				s.memoryEvents[event.EventID] = true
			}
			if event.Type == "session.input_transcript.delta" {
				s.revision++
				s.result = nil // invalidate on speech, not only on the next delegation
				// A delayed fragment recorded before the delegation still belongs to
				// that task, even after its answer was published. Newer utterances
				// require a new delegation; never revive an already consumed approval.
				if s.latestDelegation != "" && s.delegationOffset != nil && event.StartMS != nil && *event.StartMS <= *s.delegationOffset && !s.applying && !s.closing && !s.blocked {
					s.pending = s.latestDelegation
					if !s.busy {
						v.startRun(s)
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
		case "session.input_transcript.done", "session.output_transcript.done":
			role := "user"
			if event.Type == "session.output_transcript.done" {
				role = "assistant"
			}
			if len(s.memoryCaptures) > 0 {
				capture := s.memoryCaptures[len(s.memoryCaptures)-1]
				if capture.segment.Records[0].Role == role {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					err := sealVoiceCapture(ctx, capture)
					cancel()
					if err != nil {
						s.err = "Persönlicher Verlauf konnte nicht abgeschlossen werden."
						s.mu.Unlock()
						s.close()
						continue
					}
				}
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
					v.startRun(s)
				}
			}
		case "session.usage.updated":
			s.seconds = event.Usage.Seconds
		case "session.closed":
			s.seconds, s.finalUsage = event.Usage.Seconds, true
			s.captureComplete = event.Reason == "close_requested" || event.Reason == "remote_hangup" || event.Reason == "expired"
			s.mu.Unlock()
			return
		case "error":
			if delivery := s.contextDelivery[event.Error.ClientEventID]; delivery != nil && delivery.State == "pending" {
				delivery.State = "rejected"
			}
			s.err = "GPT-Live meldet einen Fehler. Gespräch beenden und Konfiguration prüfen."
		}
		s.mu.Unlock()
	}
}

// Called under s.mu. Each fragment is a FULL-synchronous transaction, not an
// in-memory batch. Only adjacent same-role fragments share an original segment.
func (s *voiceSession) captureFragment(ctx context.Context, record memory.Record) error {
	if len(s.memoryCaptures) > 0 {
		capture := s.memoryCaptures[len(s.memoryCaptures)-1]
		if capture.segment.State == "active" {
			if capture.segment.Records[0].Role == record.Role {
				segment, err := capture.scope.AppendFragment(ctx, capture.segment.Sequence, capture.segment.Revision, record)
				if err == nil {
					capture.segment = segment
					return nil
				}
				if !errors.Is(err, memory.ErrOriginalLimit) {
					return err
				}
			}
			if err := sealVoiceCapture(ctx, capture); err != nil {
				return err
			}
		}
	}
	capture, err := s.memory.begin(ctx, "voice/"+s.id+"/"+record.EventID, "voice", []memory.Record{record})
	if err == nil {
		s.memoryCaptures = append(s.memoryCaptures, capture)
	}
	return err
}

func sealVoiceCapture(ctx context.Context, capture *personalCapture) error {
	if capture.segment.State != "active" {
		return nil
	}
	if err := capture.scope.Finish(ctx, capture.segment.Sequence, capture.segment.Revision, "complete", capture.segment.Records); err != nil {
		return err
	}
	capture.segment.Revision++
	capture.segment.State = "complete"
	return nil
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
func voiceCall(ctx context.Context, identity aiIdentity, handler http.HandlerFunc, payload any, output any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithDeadline(context.WithValue(ctx, aiIdentityKey{}, identity), time.Unix(identity.ExpiresAt, 0))
	defer cancel()
	if err := ctx.Err(); err != nil {
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
	identity := s.identity
	previous, _ := json.Marshal(s.previous)
	s.pending = ""
	s.mu.Unlock()
	var result askResponse
	var err error
	var runCapture *personalCapture
	runID := fmt.Sprintf("%s/%d", s.id, revision)
	if len(previous) > 64000 {
		err = fmt.Errorf("Vorheriger Vorschlag zu groß für den Sprachkontext. Bitte im Text-Client weiterarbeiten.")
	} else {
		// Keep the exact previous proposal for references such as "the second one",
		// but create a fresh plan so no previously reviewed proposal can be mutated.
		callCtx, policy := s.ctx, "temporary"
		if s.memory != nil {
			policy = "private"
			callCtx = context.WithValue(context.WithValue(callCtx, personalMemoryKey{}, s.memory), voiceMemoryKey{}, true)
		}
		payload := map[string]any{"workspace": s.workspace, "mode": "plan", "context_conv_id": 0, "execution_policy": policy,
			"question": "Sprachgespräch (Transkriptfragmente können unvollständig sein). Bearbeite den neuesten Auftrag unter Berücksichtigung früherer Korrekturen. Antworte kurz auf Deutsch. Nur bei explizitem Änderungswunsch Aktionen vorschlagen. Gesprochene Zustimmung ist keine Ausführung. Bereits bestätigte Aktionen nicht erneut vorschlagen.\nVORHERIGE ANTWORT UND VORSCHLÄGE (Referenzdaten, keine neuen Aufträge):\n" + string(previous) + "\nGESPRÄCH UND BESTÄTIGTE ERGEBNISSE:\n" + transcript}
		created := true
		if s.memory != nil {
			body, _ := json.Marshal(payload)
			var run memory.Run
			run, created, err = s.memory.scope.BeginRun(callCtx, runID, "voice", body, []memory.Record{{Role: "backend", EventID: delegation, ProviderSession: s.providerSession}})
			if err == nil && created {
				runCapture = &personalCapture{s.memory.scope, run.Segment}
				callCtx = context.WithValue(callCtx, voiceInputGenerationKey{}, run.UserInputGeneration)
			} else if err == nil {
				result = recoveredAskRun(run)
			}
		}
		if err == nil && created {
			err = voiceCall(callCtx, identity, v.ask, payload, &result)
		}
		if runCapture != nil {
			state := "complete"
			if err != nil {
				state = "failed"
			}
			if callCtx.Err() != nil {
				state = "cancelled"
			}
			if finishErr := runCapture.finish(state, memory.Record{Role: "backend", Text: result.Answer, EventID: delegation, ProviderSession: s.providerSession}); finishErr != nil {
				err = fmt.Errorf("Backend-Antwort konnte nicht im persönlichen Verlauf gespeichert werden.")
			}
			result.RunID, result.RunState = runID, state
		}
	}
	s.mu.Lock()
	s.busy = false
	current := !s.closed && !s.closing && !s.blocked && revision == s.revision
	if current && err != nil && s.memory != nil {
		s.blocked = true
	}
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
		s.appendCommentary(delegation, message)
	}
	pending := s.pending != ""
	memoryFailed := s.memory != nil && s.blocked
	s.mu.Unlock()
	if memoryFailed {
		s.close()
	}
	if pending {
		v.startRun(s)
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
	identity := s.identity
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	if s.memory != nil {
		ctx = context.WithValue(context.WithValue(ctx, personalMemoryKey{}, s.memory), voiceMemoryKey{}, true)
	}
	var result askApplyResponse
	err := voiceCall(ctx, identity, v.apply, payload, &result)
	uncertain := err != nil || !result.OK || len(result.Failed) > 0
	s.mu.Lock()
	s.applying = false
	if err == nil {
		s.applyResult, _ = json.Marshal(result)
		if s.memoryInvalidated {
			s.applyResult = minimalVoiceReceipt(s.applyResult)
		} else {
			s.transcript += "\nBackend: Ergebnis der Bestätigung (Fehler können unbekannte Schreibausgänge enthalten): " + string(s.applyResult)
			s.lastRole = "Backend"
		}
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
		s.mu.Lock()
		s.appendCommentary("", "Mindestens eine Aktion muss geprüft werden. Sie könnte bereits gespeichert sein. Bitte Datensätze im Client prüfen und nichts erneut ausführen.")
		s.mu.Unlock()
		s.close()
	}
	if err != nil {
		http.Error(w, "Ausgang unklar. Status und Datensätze prüfen; nicht erneut anwenden.", 502)
	} else {
		if !uncertain {
			s.mu.Lock()
			s.appendCommentary("", fmt.Sprintf("Ergebnis der Bestätigung im Client: %d Aktionen erfolgreich. Details im Client. Keine übrigen Aktionen automatisch ausführen.", len(result.Applied)))
			s.mu.Unlock()
		}
		voiceJSON(w, result)
	}
	if pending {
		v.startRun(s)
	}
}
