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
	memory "nrc-ai/personal_memory"
)

func TestVoiceCoalescesPublicTranscriptEvents(t *testing.T) {
	_, ctx, access := personalFixture(t)
	connections := make(chan *websocket.Conn, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/live/sessions" {
			w.WriteHeader(201)
			fmt.Fprint(w, `{"session":{"id":"coalescing"},"transport":{"sdp":"answer"}}`)
			return
		}
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		connections <- conn
	}))
	defer upstream.Close()
	v := newVoiceService("fixture", "", func(w http.ResponseWriter, r *http.Request) {}, nil)
	v.baseURL = upstream.URL
	mux := http.NewServeMux()
	v.register(mux)
	call := func(op, body string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("POST", "/voice/"+op, strings.NewReader(body)).WithContext(ctx))
		return w
	}
	created := call("create", `{"workspace":"ws","sdp":"offer","execution_policy":"private"}`)
	if created.Code != 200 {
		t.Fatal(created.Code, created.Body)
	}
	var result struct{ ID string }
	if err := json.Unmarshal(created.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	conn := <-connections
	defer conn.Close()
	write := func(event any) {
		t.Helper()
		if err := conn.WriteJSON(event); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 174; i++ {
		text := " x"
		if i == 0 {
			text = " Lavendel"
		}
		if i == 1 {
			text = " Otto"
		}
		event := map[string]any{"type": "session.input_transcript.delta", "event_id": fmt.Sprint(i), "delta": text, "start_ms": i, "end_ms": i + 1}
		write(event)
		write(event) // Provider replay must not duplicate records or transcript.
	}
	write(map[string]any{"type": "session.output_transcript.delta", "event_id": "answer", "delta": "ja"})
	write(map[string]any{"type": "session.output_transcript.done"})
	write(map[string]any{"type": "session.output_transcript.delta", "event_id": "next", "delta": "weiter"})
	write(map[string]any{"type": "session.closed", "reason": "close_requested"})
	// Race-instrumented SQLite still commits all 176 events individually.
	_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("expected closed listener")
	} else if timeout, ok := err.(interface{ Timeout() bool }); ok && timeout.Timeout() {
		t.Fatal(err)
	}
	seg, err := access.scope.Read(ctx, 0)
	if err != nil || seg.State != "complete" || len(seg.Records) != 174 || seg.Revision != 175 {
		t.Fatal(seg, err)
	}
	if seg.Records[0].Text != " Lavendel" || seg.Records[1].Text != " Otto" || seg.Records[1].EventID != "1" || *seg.Records[1].StartMS != 1 || *seg.Records[1].EndMS != 2 {
		t.Fatal("lost exact evidence", seg)
	}
	ids, err := access.scope.Search(ctx, "Lavendel AND Otto", 10)
	if err != nil || len(ids) != 1 || ids[0] != 0 {
		t.Fatal(ids, err)
	}
	for i := int64(1); i <= 2; i++ {
		seg, err := access.scope.Read(ctx, i)
		if err != nil || seg.State != "complete" || len(seg.Records) != 1 {
			t.Fatal(seg, err)
		}
	}
	policy, err := access.scope.Retention(ctx)
	if err != nil || policy.Segments != 3 {
		t.Fatal(policy, err)
	}
	body := fmt.Sprintf(`{"workspace":"ws","id":%q}`, result.ID)
	for i := 0; i < 2; i++ {
		if w := call("close", body); w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
	}
	if err := v.shutdown(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestVoiceCaptureSplitsAtEncodedBound(t *testing.T) {
	_, ctx, access := personalFixture(t)
	s := &voiceSession{id: "bounded", memory: access}
	for i := 0; i < 3; i++ {
		if err := s.captureFragment(ctx, memory.Record{Role: "user", Text: strings.Repeat("\x00", 5000), EventID: fmt.Sprint(i)}); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.memoryCaptures) != 2 || s.memoryCaptures[0].segment.State != "complete" || len(s.memoryCaptures[0].segment.Records) != 2 || s.memoryCaptures[1].segment.State != "active" {
		t.Fatal("incorrect split", s.memoryCaptures)
	}
	for _, capture := range s.memoryCaptures {
		body, err := json.Marshal(capture.segment.Records)
		if err != nil || len(body) > memory.MaxOriginalBytes {
			t.Fatal(len(body), err)
		}
	}
}

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
		if string(request.Session["store"]) != "false" || !strings.Contains(string(request.Session["instructions"]), "PRIVATE EXECUTION POLICY") {
			t.Error("voice session lost privacy configuration")
		}
		received.Store(true)
		// Only inspect creation; no billed provider session or sideband is needed.
		http.Error(w, "fixture stops after inspecting creation", http.StatusBadRequest)
	}))
	defer upstream.Close()
	v := newVoiceService("test-key", "", func(http.ResponseWriter, *http.Request) {}, nil)
	v.baseURL = upstream.URL
	r := httptest.NewRequest("POST", "/voice/create", strings.NewReader(`{"workspace":"support","sdp":"offer"}`))
	r.Header.Set("X-NRC-AI-Auth", testAIToken(testAIIdentity("support")))
	authenticate, err := newAIAuthentication(testAIKey, "test-issuer")
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	authenticate(http.HandlerFunc(v.handle)).ServeHTTP(w, r)
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
		if req.ExecutionPolicy != "temporary" {
			t.Error("voice delegation lost temporary policy")
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
	authenticate, err := newAIAuthentication(testAIKey, "test-issuer")
	if err != nil {
		t.Fatal(err)
	}
	handler := authenticate(mux)
	call := func(op, owner string, req voiceRequest) *httptest.ResponseRecorder {
		b, _ := json.Marshal(req)
		r := httptest.NewRequest("POST", "/voice/"+op, bytes.NewReader(b))
		identity := testAIIdentity(req.Workspace)
		if owner != "alice" {
			identity.Subject = "tailscale:user:99"
		}
		if owner != "" {
			r.Header.Set("X-NRC-AI-Auth", testAIToken(identity))
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
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
	contextEvents := make(chan string, 32)
	// Drain appends so the service can always finish sending.
	go func() {
		for {
			var event struct {
				Type string `json:"type"`
				ID   string `json:"event_id"`
			}
			if err := ws.ReadJSON(&event); err != nil {
				return
			}
			if event.Type == "session.commentary.append" {
				contextEvents <- event.ID
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
		ApplyResult            json.RawMessage                 `json:"apply_result"`
		FinalUsage             bool                            `json:"final_usage"`
		ContextDelivery        map[string]voiceContextDelivery `json:"context_delivery"`
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
	var contextID string
	select {
	case contextID = <-contextEvents:
	case <-time.After(3 * time.Second):
		t.Fatal("no context append")
	}
	if contextID == "" || status().ContextDelivery[contextID].State != "pending" {
		t.Fatal("send treated as acknowledged")
	}
	emit(map[string]any{"type": "session.commentary.appended", "client_event_id": "foreign", "start_ms": 10, "end_ms": 20})
	emit(map[string]any{"type": "session.usage.updated", "usage": map[string]any{"seconds": 7}})
	wait(func() bool { return status().Seconds == 7 })
	if status().ContextDelivery[contextID].State != "pending" {
		t.Fatal("unrelated acknowledgment accepted")
	}
	emit(map[string]any{"type": "session.commentary.appended", "client_event_id": contextID, "start_ms": 125, "end_ms": 375})
	wait(func() bool { return status().ContextDelivery[contextID].State == "acknowledged" })
	delivery := status().ContextDelivery[contextID]
	if delivery.StartMS == nil || *delivery.StartMS != 125 || delivery.EndMS == nil || *delivery.EndMS != 375 {
		t.Fatal(delivery)
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
	var rejectedID string
	for id, delivery := range status().ContextDelivery {
		if delivery.State == "pending" {
			rejectedID = id
			break
		}
	}
	if rejectedID == "" {
		t.Fatal("missing pending delivery")
	}
	emit(map[string]any{"type": "error", "error": map[string]any{"client_event_id": rejectedID}})
	wait(func() bool { return status().ContextDelivery[rejectedID].State == "rejected" })
	emit(map[string]any{"type": "session.usage.updated", "usage": map[string]any{"seconds": 10}})
	emit(map[string]any{"type": "session.usage.updated", "usage": map[string]any{"seconds": 20}})
	emit(map[string]any{"type": "session.closed", "usage": map[string]any{"seconds": 21}})
	wait(func() bool { return status().FinalUsage })
	if !status().FinalUsage || status().Seconds != 21 {
		t.Fatal("usage snapshots were added or lost")
	}
	wait(func() bool {
		for _, d := range status().ContextDelivery {
			if d.State == "pending" {
				return false
			}
		}
		return true
	})
	if status().ContextDelivery[contextID].State != "acknowledged" || status().ContextDelivery[rejectedID].State != "rejected" {
		t.Fatal("terminal delivery evidence lost")
	}
}
