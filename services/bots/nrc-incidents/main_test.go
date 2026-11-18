package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

type testSource struct {
	mu        sync.Mutex
	asset     p.Asset
	sequence  uint64
	submitted []p.ApplyMonitorRun
}

func (s *testSource) monitor(ctx context.Context, id uint64) (p.Asset, p.MonitorState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.asset, p.MonitorState{MonitorID: id, Revision: 3, Sequence: s.sequence}, nil
}
func (s *testSource) apply(ctx context.Context, r p.ApplyMonitorRun) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.Sequence != s.sequence+1 {
		return "rejected", errors.New("stale sequence")
	}
	s.sequence = r.Sequence
	s.submitted = append(s.submitted, r)
	return "unknown", errors.New("simulated lost ACK after commit")
}
func monitorAsset(url string) p.Asset {
	payload, _ := json.Marshal(checkDefinition{Kind: "http", URL: url, Conditions: []condition{{Field: "status", Op: "==", Value: float64(200)}}})
	return p.Asset{AssetType: p.AssetTypeMonitor, UpdatedAt: 3, Preview: `{"version":1,"name":"test","evaluator":"checker","enabled":true,"interval_ns":1000000000,"timeout_ns":1000000000,"failures":5,"recoveries":5,"missing":3,"webhooks":[]}`, Payload: string(payload)}
}

func TestCycleRereadsCommittedSequenceAfterLostACK(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer server.Close()
	source := &testSource{asset: monitorAsset(server.URL), sequence: 40}
	history := newHistoryWriter()
	for i := 0; i < 2; i++ {
		if _, err := cycle(context.Background(), source, history, "test", "checker", 2); err == nil {
			t.Fatal("lost ACK hidden")
		}
	}
	if len(source.submitted) != 2 || source.submitted[0].Sequence != 41 || source.submitted[1].Sequence != 42 {
		t.Fatalf("wrong sequence: %+v", source.submitted)
	}
	for i := 0; i < 2; i++ {
		r := <-history.queue
		if r.Acceptance != "unknown" || r.Run.Observations[0].Value != 1 || r.Diagnostics == nil || r.Diagnostics.Conditions[0].Actual != "200" || r.Diagnostics.Conditions[0].State != "pass" {
			t.Fatalf("history: %+v", r)
		}
	}
}

func TestScheduleBoundsConcurrencyAndDoesNotSubmitShutdownFailures(t *testing.T) {
	entered := make(chan struct{}, 3)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { entered <- struct{}{}; <-r.Context().Done() }))
	defer server.Close()
	source := &testSource{asset: monitorAsset(server.URL)}
	history := newHistoryWriter()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		schedule(ctx, newMonitorSet([]uint64{1, 2, 3}), 2, source, history, "test", "checker")
	}()
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(3 * time.Second):
			t.Fatal("checks did not start")
		}
	}
	select {
	case <-entered:
		t.Fatal("worker limit exceeded")
	case <-time.After(50 * time.Millisecond):
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown stuck")
	}
	if len(source.submitted) != 0 || len(history.queue) != 0 {
		t.Fatal("shutdown counted as check failure")
	}
}

// Models the read lane seeing sequence 40 while an older write is still pending.
// Apply uses the real transport against a controlled WebSocket peer.
type delayedCommitSource struct {
	nrcSource
	asset    p.Asset
	sequence uint64
}

func (s *delayedCommitSource) monitor(context.Context, uint64) (p.Asset, p.MonitorState, error) {
	return s.asset, p.MonitorState{MonitorID: 2, Revision: 3, Sequence: s.sequence}, nil
}

func TestCycleDoesNotConfirmFreshMeasurementOnReplay(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer target.Close()
	var calls atomic.Int32
	requests := make(chan []byte, 3)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := websocket.Upgrader{}
		c, err := u.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		ready, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
		c.WriteMessage(websocket.BinaryMessage, ready)
		_, wire, err := c.ReadMessage()
		if err != nil {
			t.Error(err)
			return
		}
		requests <- wire
		call := calls.Add(1)
		if call == 1 {
			return
		} // Lost ACK, write commits only after the next state read.
		body := make([]byte, 21)
		binary.BigEndian.PutUint32(body, 1)
		binary.BigEndian.PutUint64(body[4:], 2)
		if call == 2 {
			binary.BigEndian.PutUint64(body[12:], 41)
			body[20] = 1
		} else {
			binary.BigEndian.PutUint64(body[12:], 42)
		}
		reply, _ := (&p.Message{Opcode: p.S_MonitorRunApplied, Data: body}).Write()
		c.WriteMessage(websocket.BinaryMessage, reply)
	}))
	defer server.Close()
	source := &delayedCommitSource{newNRCSource("ws"+strings.TrimPrefix(server.URL, "http"), "test", "checker", "test-secret"), monitorAsset(target.URL), 40}
	history := newHistoryWriter()
	db, err := openHistory(context.Background(), filepath.Join(t.TempDir(), "history.duckdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for i, want := range []string{"unknown", "rejected", "confirmed"} {
		if i == 2 {
			source.sequence = 41
		} // The subsequent read observes the committed first run.
		_, cycleErr := cycle(context.Background(), source, history, "test", "checker", 2)
		if (cycleErr == nil) != (want == "confirmed") {
			t.Fatalf("cycle %d: %v", i, cycleErr)
		}
		r := <-history.queue
		if r.Acceptance != want {
			t.Fatalf("cycle %d stored %s, want %s", i, r.Acceptance, want)
		}
		if err := writeHistory(context.Background(), db, r); err != nil {
			t.Fatal(err)
		}
	}
	first, second, third := <-requests, <-requests, <-requests
	if !bytes.Equal(first, second) || bytes.Equal(second, third) {
		t.Fatal("fixture did not reproduce identical-body sequence collision")
	}
	var confirmed int
	var sequence uint64
	if err := db.QueryRow("SELECT count(*),min(sequence) FROM runs WHERE acceptance='confirmed'").Scan(&confirmed, &sequence); err != nil || confirmed != 1 || sequence != 42 {
		t.Fatalf("confirmed=%d sequence=%d err=%v", confirmed, sequence, err)
	}
}
