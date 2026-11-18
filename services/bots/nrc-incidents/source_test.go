package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestSourceSharesAdmissionAndCancelsQueuedRequests(t *testing.T) {
	entered := make(chan struct{}, 24)
	cancelEntered := make(chan struct{}, 1)
	release := make(chan struct{})
	var active atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		up := websocket.Upgrader{}
		ws, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		ready, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
		ws.WriteMessage(websocket.BinaryMessage, ready)
		_, wire, err := ws.ReadMessage()
		if err != nil {
			return
		}
		if binary.BigEndian.Uint64(wire[6:14]) == 100 {
			return // A lost acknowledgement must not consume admission forever.
		}
		if binary.BigEndian.Uint64(wire[6:14]) == 102 {
			cancelEntered <- struct{}{}
			ws.ReadMessage() // Hold an admitted RPC until its caller cancels it.
			return
		}
		inFlight := active.Add(1)
		if inFlight > 7 {
			active.Add(-1)
			body := make([]byte, 8)
			binary.BigEndian.PutUint16(body, p.C_ApplyMonitorRun)
			binary.BigEndian.PutUint32(body[4:], 1)
			reply, _ := (&p.Message{Opcode: p.S_ErrorResponse, Data: body}).Write()
			ws.WriteMessage(websocket.BinaryMessage, reply)
			return
		}
		entered <- struct{}{}
		<-release
		active.Add(-1)
		body := make([]byte, 21)
		binary.BigEndian.PutUint32(body, 1)
		copy(body[4:12], wire[6:14])
		binary.BigEndian.PutUint64(body[12:], 1)
		reply, _ := (&p.Message{Opcode: p.S_MonitorRunApplied, Data: body}).Write()
		ws.WriteMessage(websocket.BinaryMessage, reply)
	}))
	defer server.Close()
	defer close(release)
	source := newNRCSource("ws"+strings.TrimPrefix(server.URL, "http"), "test", "checker", "secret")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	results := make(chan error, 24)
	for i := range 7 {
		copy := source
		go func() {
			_, err := copy.apply(ctx, p.ApplyMonitorRun{CorrelationID: 1, MonitorID: uint64(i + 1), Revision: 1, Sequence: 1})
			results <- err
		}()
	}
	for range 7 {
		select {
		case <-entered:
		case <-ctx.Done():
			t.Fatal("requests did not reach the peer")
		}
	}
	queuedCtx, stop := context.WithTimeout(ctx, 25*time.Millisecond)
	defer stop()
	_, err := source.apply(queuedCtx, p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 99, Revision: 1, Sequence: 1})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("queued request should expire without submission, got %v", err)
	}
	// Three independent groups use copies of the same source. The peer rejects
	// excess work rather than buffering it, just like NRC's bounded executor.
	for i := range 17 {
		copy := source
		go func() {
			_, err := copy.apply(ctx, p.ApplyMonitorRun{CorrelationID: 1, MonitorID: uint64(i + 8), Revision: 1, Sequence: 1})
			results <- err
		}()
	}
	for range 24 {
		select {
		case release <- struct{}{}:
		case <-ctx.Done():
			t.Fatal("admitted work stopped progressing")
		}
		select {
		case err := <-results:
			if err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("admitted work did not finish")
		}
	}
	// Both cancellation of admitted work and lost acknowledgements must release
	// every slot. No failed write is retried automatically.
	for range 7 {
		admittedCtx, stop := context.WithCancel(ctx)
		go func() {
			_, err := source.apply(admittedCtx, p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 102, Revision: 1, Sequence: 1})
			results <- err
		}()
		select {
		case <-cancelEntered:
		case <-ctx.Done():
			stop()
			t.Fatal("canceled request leaked admission")
		}
		stop()
		if err := <-results; err == nil {
			t.Fatal("canceled request unexpectedly succeeded")
		}
	}
	for range 7 {
		_, err = source.apply(ctx, p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 100, Revision: 1, Sequence: 1})
		if err == nil {
			t.Fatal("lost acknowledgement unexpectedly succeeded")
		}
	}
	go func() {
		_, err := source.apply(ctx, p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 101, Revision: 1, Sequence: 1})
		results <- err
	}()
	select {
	case release <- struct{}{}:
	case <-ctx.Done():
		t.Fatal("failed request leaked admission")
	}
	if err := <-results; err != nil {
		t.Fatal(err)
	}
}

func TestDeliveryProtocol(t *testing.T) {
	for _, wrongCorrelation := range []bool{false, true} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			up := websocket.Upgrader{}
			ws, err := up.Upgrade(w, r, nil)
			if err != nil {
				t.Error(err)
				return
			}
			defer ws.Close()
			ready, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
			_ = ws.WriteMessage(websocket.BinaryMessage, ready)
			_, wire, err := ws.ReadMessage()
			if err != nil {
				t.Error(err)
				return
			}
			if binary.BigEndian.Uint16(wire) != p.C_MonitorDelivery || binary.BigEndian.Uint64(wire[6:]) != 7 || wire[14] != 1 || wire[15] != 6 || len(wire) != 33 {
				t.Error("invalid discovery request")
			}
			result := p.MonitorDeliveryResult{Version: 1, State: 5, ID: "0", Generation: "0", CreatedAt: "0", AvailableAt: "0", LeaseUntil: "0", Routes: []string{"9"}}
			body, _ := json.Marshal(result)
			data := make([]byte, 4, len(body)+4)
			binary.BigEndian.PutUint32(data, 1)
			if wrongCorrelation {
				binary.BigEndian.PutUint32(data, 2)
			}
			data = append(data, body...)
			reply, _ := (&p.Message{Opcode: p.S_MonitorDelivery, Data: data}).Write()
			_ = ws.WriteMessage(websocket.BinaryMessage, reply)
		}))
		source := newNRCSource("ws"+strings.TrimPrefix(s.URL, "http"), "test", "checker", "secret")
		result, err := source.delivery(context.Background(), p.MonitorDelivery{MonitorID: 7, Stream: 1, Action: 6})
		s.Close()
		if (err != nil) != wrongCorrelation || err == nil && (len(result.Routes) != 1 || result.Routes[0] != "9") {
			t.Fatalf("result %+v, error %v", result, err)
		}
	}
}

func TestApplyDistinguishesRejectionFromLostAcknowledgement(t *testing.T) {
	for _, mode := range []string{"confirmed", "replayed", "rejected", "lost", "wrong-correlation", "malformed"} {
		t.Run(mode, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("X-NRC-Bot-Secret") != "test-secret" || r.URL.Path != "/test" {
					t.Error("authentication envelope")
				}
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
				if binary.BigEndian.Uint16(wire) != p.C_ApplyMonitorRun {
					t.Error("wrong request")
				}
				if mode == "lost" {
					return
				}
				opcode := p.S_ErrorResponse
				body := make([]byte, 8)
				binary.BigEndian.PutUint16(body, p.C_ApplyMonitorRun)
				binary.BigEndian.PutUint32(body[4:], 1)
				if mode == "wrong-correlation" {
					binary.BigEndian.PutUint32(body[4:], 2)
				}
				if mode == "malformed" {
					body = []byte{0}
				}
				if mode == "confirmed" || mode == "replayed" {
					opcode = p.S_MonitorRunApplied
					body = make([]byte, 21)
					binary.BigEndian.PutUint32(body, 1)
					binary.BigEndian.PutUint64(body[4:], 2)
					binary.BigEndian.PutUint64(body[12:], 4)
					if mode == "replayed" {
						body[20] = 1
					}
				}
				reply, _ := (&p.Message{Opcode: opcode, Data: body}).Write()
				c.WriteMessage(websocket.BinaryMessage, reply)
			}))
			defer s.Close()
			source := newNRCSource("ws"+strings.TrimPrefix(s.URL, "http"), "test", "checker", "test-secret")
			acceptance, err := source.apply(context.Background(), p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 4})
			want := mode
			if mode != "confirmed" && mode != "rejected" {
				want = "unknown"
			}
			if mode == "replayed" {
				want = "rejected"
			}
			if acceptance != want || (err == nil) != (mode == "confirmed") {
				t.Fatalf("%s %v", acceptance, err)
			}
		})
	}
}

func TestAvailabilitySnapshotPagingAndFences(t *testing.T) {
	for _, mode := range []string{"complete", "pause", "revision", "time", "capture-kind", "lost-page", "duplicate", "budget"} {
		t.Run(mode, func(t *testing.T) {
			var calls atomic.Int64
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				up := websocket.Upgrader{}
				ws, err := up.Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer ws.Close()
				ready, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
				ws.WriteMessage(websocket.BinaryMessage, ready)
				_, wire, err := ws.ReadMessage()
				if err != nil {
					t.Error(err)
					return
				}
				calls.Add(1)
				if len(wire) != 39 || binary.BigEndian.Uint16(wire) != p.C_MonitorHistory || binary.BigEndian.Uint64(wire[6:]) != 7 || wire[38] != 0 {
					t.Error("invalid snapshot request")
					return
				}
				cursor := binary.BigEndian.Uint64(wire[22:])
				if cursor == 0 && (binary.BigEndian.Uint64(wire[14:]) != 0 || binary.BigEndian.Uint64(wire[30:]) != 0) || cursor != 0 && (binary.BigEndian.Uint64(wire[14:]) != 11 || binary.BigEndian.Uint64(wire[30:]) != 100) {
					t.Error("missing fixed snapshot time")
					return
				}
				if mode == "lost-page" && cursor != 0 {
					return
				}
				body := make([]byte, 54)
				binary.BigEndian.PutUint32(body, 1)
				for offset, value := range map[int]uint64{4: 7, 12: 9, 20: 11, 28: 100, 36: 190} {
					binary.BigEndian.PutUint64(body[offset:], value)
				}
				count := 16
				if cursor != 0 && mode != "budget" {
					count = 1
				} else {
					binary.BigEndian.PutUint64(body[44:], cursor+16)
				}
				if cursor != 0 && mode == "revision" {
					binary.BigEndian.PutUint64(body[12:], 10)
				}
				if cursor != 0 && mode == "time" {
					binary.BigEndian.PutUint64(body[28:], 101)
				}
				binary.BigEndian.PutUint16(body[52:], uint16(count))
				for i := range count {
					id := cursor + uint64(i) + 1
					identity := "disk-" + strconv.FormatUint(id, 10)
					if mode == "duplicate" && cursor != 0 {
						identity = "disk-1"
					}
					if mode == "budget" {
						identity = strings.Repeat("x", 4090) + strconv.FormatUint(id, 10)
					}
					row := make([]byte, 19+len(identity))
					binary.BigEndian.PutUint64(row, id)
					binary.BigEndian.PutUint16(row[8:], uint16(len(identity)))
					copy(row[10:], identity)
					if mode == "pause" {
						row[10+len(identity)] = 3
					}
					binary.BigEndian.PutUint64(row[11+len(identity):], 200)
					body = append(body, row...)
				}
				var kind byte
				if mode == "pause" || mode == "capture-kind" && cursor != 0 {
					kind = 1
				}
				body = binary.BigEndian.AppendUint64(body, 11)
				body = append(body, kind)
				response, _ := (&p.Message{Opcode: p.S_MonitorState, Data: body}).Write()
				ws.WriteMessage(websocket.BinaryMessage, response)
			}))
			defer server.Close()
			source := newNRCSource("ws"+strings.TrimPrefix(server.URL, "http"), "ops", "checker", "test-secret")
			snapshot, found, err := source.pendingSnapshot(context.Background(), 7)
			if mode == "complete" || mode == "pause" {
				if err != nil || !found || len(snapshot.Instances) != 17 || snapshot.Instances[16].Identity != "disk-17" || snapshot.At != 100 || snapshot.PauseObservation != (mode == "pause") || calls.Load() != 2 {
					t.Fatalf("snapshot %+v calls %d: %v", snapshot, calls.Load(), err)
				}
			} else if err == nil {
				t.Fatal("invalid or incomplete snapshot published")
			}
		})
	}
}
