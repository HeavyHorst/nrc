package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestVoiceDefaultOmitsAudioOverride(t *testing.T) {
	var received atomic.Bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Session map[string]json.RawMessage `json:"session"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
		}
		if _, present := request.Session["audio"]; present {
			t.Error("default session must omit the audio override")
		}
		if string(request.Session["model"]) != `"gpt-live-1"` {
			t.Error("missing session model")
		}
		received.Store(true)
		// Only inspect creation; no billed provider session or sideband is needed.
		http.Error(w, "fixture stops after inspecting creation", http.StatusBadRequest)
	}))
	defer upstream.Close()
	v := newVoiceService("test-key", "", func(http.ResponseWriter, *http.Request) {}, nil)
	v.baseURL = upstream.URL
	r := httptest.NewRequest("POST", "/voice/create", strings.NewReader(`{"workspace":"support","sdp":"offer"}`))
	r.Header.Set("X-Tailscale-User", "alice")
	w := httptest.NewRecorder()
	v.handle(w, r)
	if !received.Load() || w.Code != http.StatusBadGateway {
		t.Fatalf("creation did not reach fixture: HTTP %d, %s", w.Code, w.Body.String())
	}
}

func TestVoiceApprovalAndCorrections(t *testing.T) {
	// Real HTTP and sideband WebSocket; only provider reasoning and NRC writes
	// are replaced. Assert observable write outcomes, not model tool-call order.
	connection := make(chan *websocket.Conn, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Error("missing server credential")
		}
		if r.URL.Path == "/live/sessions" {
			var request struct {
				Session struct {
					Audio struct {
						Output struct {
							Voice struct{ ID string }
						}
					}
				}
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Error(err)
			}
			if got := request.Session.Audio.Output.Voice.ID; got != "voice_test_configured" {
				t.Errorf("wrong Sullivan voice: %q", got)
			}
			w.WriteHeader(201)
			_, _ = w.Write([]byte(`{"session":{"id":"live_test"},"transport":{"sdp":"answer"}}`))
			return
		}
		if r.URL.Path != "/live/sessions/live_test/attach" {
			http.NotFound(w, r)
			return
		}
		ws, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		connection <- ws
	}))
	defer upstream.Close()
	var writes atomic.Int32
	var questions atomic.Int32
	var appends atomic.Int32
	firstStarted, releaseFirst := make(chan struct{}), make(chan struct{})
	sixthStarted, releaseSixth := make(chan struct{}), make(chan struct{})
	ask := func(w http.ResponseWriter, r *http.Request) {
		var req askRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Error(err)
		}
		n := questions.Add(1)
		if n == 1 {
			close(firstStarted)
			<-releaseFirst
		}
		if n == 6 {
			close(sixthStarted)
			<-releaseSixth
		}
		if req.Mode != "plan" || req.Workspace != "support" {
			t.Error("lost request scope")
		}
		if n == 2 && !strings.Contains(req.Question, "Freitag") {
			t.Error("lost trailing fragment")
		}
		if n == 3 && (!strings.Contains(req.Question, `"content":"Nur im Vorschlag vorhandener Text"`) || !strings.Contains(req.Question, `"id":"b"`)) {
			t.Error("follow-up lost exact previous proposal")
		}
		if n == 5 && !strings.Contains(req.Question, "Verspätetes Detail") {
			t.Error("lost post-publication fragment")
		}
		voiceJSON(w, askResponse{AgentSessionID: "private", PlanID: fmt.Sprintf("plan-%d", n), Answer: fmt.Sprintf("Antwort %d", n), ProposedActions: []ProposedAction{
			{ID: "a", Type: actionTypeCreateTask, Title: "Freitag"}, {ID: "b", Type: actionTypeCreateNote, Title: "Notiz", Content: "Nur im Vorschlag vorhandener Text"},
		}})
	}
	applyStarted, releaseApply := make(chan struct{}), make(chan struct{})
	failedStarted, releaseFailed := make(chan struct{}), make(chan struct{})
	apply := func(w http.ResponseWriter, r *http.Request) {
		var req askApplyRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		if len(req.ActionIDs) != 1 || req.ActionIDs[0] != "b" {
			t.Errorf("wrong selected write: %+v", req)
		}
		if writes.Add(1) == 2 {
			close(failedStarted)
			<-releaseFailed
			voiceJSON(w, map[string]any{"ok": false, "applied": []any{}, "failed": []any{map[string]string{"action_id": "b", "error": "outcome_unknown: write may have committed; do not replay"}}})
			return
		}
		close(applyStarted)
		<-releaseApply
		voiceJSON(w, map[string]any{"ok": true, "applied": []any{map[string]any{"action_id": "b", "created_entity": map[string]any{"type": "note", "id": 81}}}, "failed": []any{}})
	}
	v := newVoiceService("test-key", "voice_test_configured", ask, apply)
	v.baseURL = upstream.URL
	mux := http.NewServeMux()
	v.register(mux)
	call := func(op, owner string, req voiceRequest) *httptest.ResponseRecorder {
		b, _ := json.Marshal(req)
		r := httptest.NewRequest("POST", "/voice/"+op, bytes.NewReader(b))
		r.Header.Set("X-Tailscale-User", owner)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		return w
	}
	created := call("create", "alice", voiceRequest{Workspace: "support", SDP: "offer"})
	if created.Code != 200 {
		t.Fatal(created.Body.String())
	}
	var start struct{ ID, SDP string }
	_ = json.Unmarshal(created.Body.Bytes(), &start)
	if start.ID == "" || start.SDP != "answer" || strings.Contains(created.Body.String(), "test-key") {
		t.Fatal(created.Body.String())
	}
	ws := <-connection
	defer ws.Close()
	// Drain appends so the service can always finish sending.
	go func() {
		for {
			if _, _, err := ws.ReadMessage(); err != nil {
				return
			}
			appends.Add(1)
		}
	}()
	emit := func(value any) {
		t.Helper()
		if err := ws.WriteJSON(value); err != nil {
			t.Fatal(err)
		}
	}
	request := voiceRequest{Workspace: "support", ID: start.ID}
	type voiceStatus struct {
		Revision               uint64
		Result                 *askResponse
		Busy, Applying, Closed bool
		ApplyResult            json.RawMessage `json:"apply_result"`
		FinalUsage             bool            `json:"final_usage"`
		Seconds                float64
	}
	status := func() voiceStatus {
		var out voiceStatus
		w := call("status", "alice", request)
		if w.Code != 200 {
			t.Fatal(w.Body.String())
		}
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	wait := func(predicate func() bool) {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for !predicate() {
			if time.Now().After(deadline) {
				t.Fatal("timed out")
			}
			time.Sleep(time.Millisecond)
		}
	}
	for _, op := range []string{"status", "apply", "close"} {
		if got := call(op, "bob", request); got.Code != 404 {
			t.Fatalf("foreign owner %s: %d", op, got.Code)
		}
		foreign := request
		foreign.Workspace = "other"
		if got := call(op, "alice", foreign); got.Code != 404 {
			t.Fatalf("foreign workspace %s: %d", op, got.Code)
		}
		if got := call(op, "", request); got.Code != 401 {
			t.Fatalf("anonymous %s: %d", op, got.Code)
		}
	}
	if got := call("create", "alice", voiceRequest{Workspace: "support", SDP: "second"}); got.Code != 409 {
		t.Fatal("allowed overlapping billed session")
	}
	emit(map[string]any{"type": "session.input_transcript.delta", "delta": "Erstelle eine Notiz für Donnerstag."})
	emit(map[string]any{"type": "session.delegation.created", "offset_ms": 500, "delegation": map[string]string{"id": "one", "target": "client"}})
	<-firstStarted
	emit(map[string]any{"type": "session.input_transcript.delta", "start_ms": 400, "end_ms": 500, "delta": " Nein, Freitag."})
	wait(func() bool { return status().Revision == 3 })
	close(releaseFirst)
	// No second delegation: a trailing fragment alone must recover the task.
	wait(func() bool { return status().Result != nil })
	if status().Result.Answer != "Antwort 2" {
		t.Fatal("published stale result")
	}
	approval := request
	approval.Revision = 3
	approval.PlanID = "plan-2"
	if got := call("apply", "alice", approval); got.Code != 409 {
		t.Fatal("empty selection accepted")
	}
	approval.ActionIDs = []string{"unknown"}
	if got := call("apply", "alice", approval); got.Code != 400 {
		t.Fatal("unknown action accepted")
	}
	approval.ActionIDs = []string{"b"}
	approval.Revision = 1
	if got := call("apply", "alice", approval); got.Code != 409 {
		t.Fatal("stale revision accepted")
	}
	// Spoken approval can never execute a write and invalidates the old card.
	emit(map[string]any{"type": "session.input_transcript.delta", "delta": " Ja, mach das. Bei der zweiten bitte hohe Priorität."})
	wait(func() bool { return status().Revision == 4 })
	approval.Revision = 3
	if got := call("apply", "alice", approval); got.Code != 409 || writes.Load() != 0 {
		t.Fatal("speech approved a write")
	}
	emit(map[string]any{"type": "session.delegation.created", "delegation": map[string]string{"id": "three", "target": "client"}})
	wait(func() bool { return status().Result != nil })
	approval.Revision = 5
	approval.PlanID = "plan-3"
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- call("apply", "alice", approval) }()
	<-applyStarted
	if got := call("apply", "alice", approval); got.Code != 409 {
		t.Fatal("concurrent approval accepted")
	}
	close(releaseApply)
	if got := <-done; got.Code != 200 {
		t.Fatal(got.Body.String())
	}
	if got := call("apply", "alice", approval); got.Code != 409 {
		t.Fatal("repeated approval accepted")
	}
	if writes.Load() != 1 || !bytes.Contains(status().ApplyResult, []byte(`81`)) {
		t.Fatal("wrong write count or missing recoverable result")
	}
	// HTTP 200 can still mean a committed write with a lost acknowledgment.
	emit(map[string]any{"type": "session.delegation.created", "offset_ms": 1000, "delegation": map[string]string{"id": "four", "target": "client"}})
	wait(func() bool { return status().Result != nil })
	approval.Revision, approval.PlanID = 6, "plan-4"
	// A fragment from before the delegation can arrive after publication.
	emit(map[string]any{"type": "session.input_transcript.delta", "start_ms": 900, "end_ms": 1000, "delta": " Verspätetes Detail."})
	wait(func() bool { return status().Revision == 7 })
	if got := call("apply", "alice", approval); got.Code != 409 {
		t.Fatal("late fragment left old proposal approvable")
	}
	wait(func() bool { return status().Result != nil })
	if status().Result.PlanID != "plan-5" {
		t.Fatal("late fragment did not replace the published proposal")
	}
	// A genuinely later utterance invalidates, but does not reuse the old task.
	emit(map[string]any{"type": "session.input_transcript.delta", "start_ms": 1100, "end_ms": 1200, "delta": " Neuer Auftrag."})
	wait(func() bool { return status().Revision == 8 })
	time.Sleep(350 * time.Millisecond)
	if status().Result != nil || questions.Load() != 5 {
		t.Fatal("new utterance reused an old delegation")
	}
	emit(map[string]any{"type": "session.delegation.created", "offset_ms": 1200, "delegation": map[string]string{"id": "five", "target": "client"}})
	<-sixthStarted
	spoken := appends.Load()
	emit(map[string]any{"type": "session.input_transcript.delta", "start_ms": 1300, "end_ms": 1400, "delta": " Anderer Auftrag während der Recherche."})
	wait(func() bool { return status().Revision == 10 })
	close(releaseSixth)
	wait(func() bool { return !status().Busy })
	time.Sleep(350 * time.Millisecond)
	if status().Result != nil || questions.Load() != 6 || appends.Load() != spoken {
		t.Fatal("in-flight completion revived an obsolete delegation")
	}
	emit(map[string]any{"type": "session.delegation.created", "offset_ms": 1400, "delegation": map[string]string{"id": "six", "target": "client"}})
	wait(func() bool { return status().Result != nil })
	approval.Revision, approval.PlanID = 11, "plan-7"
	go func() { done <- call("apply", "alice", approval) }()
	<-failedStarted
	emit(map[string]any{"type": "session.delegation.created", "delegation": map[string]string{"id": "queued", "target": "client"}})
	wait(func() bool { return status().Revision == 12 })
	close(releaseFailed)
	if got := <-done; got.Code != 200 {
		t.Fatal(got.Body.String())
	}
	wait(func() bool { return status().Closed })
	if questions.Load() != 7 || !bytes.Contains(status().ApplyResult, []byte("outcome_unknown")) {
		t.Fatal("unknown outcome lost or queued task resumed")
	}
	if got := call("apply", "alice", approval); got.Code != 409 || writes.Load() != 2 {
		t.Fatal("unknown write replayed")
	}
	emit(map[string]any{"type": "session.usage.updated", "usage": map[string]any{"seconds": 10}})
	emit(map[string]any{"type": "session.usage.updated", "usage": map[string]any{"seconds": 20}})
	emit(map[string]any{"type": "session.closed", "usage": map[string]any{"seconds": 21}})
	wait(func() bool { return status().FinalUsage })
	if !status().FinalUsage || status().Seconds != 21 {
		t.Fatal("usage snapshots were added or lost")
	}
}
