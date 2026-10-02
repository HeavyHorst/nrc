package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/HdrHistogram/hdrhistogram-go"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestPhaseCorrelatesACKs(t *testing.T) {
	for _, tc := range []struct {
		name      string
		ids       []uint32
		wantError bool
	}{
		{"reversed", []uint32{4, 3, 2, 1}, false},
		{"duplicate", []uint32{4, 4, 2, 1}, true},
		{"unknown", []uint32{5, 3, 2, 1}, true},
		{"missing", []uint32{4, 3, 2}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			deadline := make(chan time.Time, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer conn.Close()
				until := <-deadline
				for range 4 {
					if _, _, err := conn.ReadMessage(); err != nil {
						t.Error(err)
						return
					}
				}
				// Finish exactly one wave, after the phase stops accepting new sends.
				time.Sleep(time.Until(until))
				for _, id := range tc.ids {
					payload := make([]byte, 20)
					binary.BigEndian.PutUint32(payload, id)
					binary.BigEndian.PutUint64(payload[4:], uint64(id))
					wire, err := (&protocol.Message{Opcode: protocol.S_AckSendMessage, Data: payload}).Write()
					if err != nil {
						t.Error(err)
						return
					}
					if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
						return
					}
				}
			}))
			defer server.Close()
			conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			worker := worker{conn: conn, id: 1, hist: hdrhistogram.New(1, 10000000, 3)}
			until := time.Now().Add(100 * time.Millisecond)
			deadline <- until
			err = worker.phase(until, 4, 4, true, nil, nil)
			if (err != nil) != tc.wantError {
				t.Fatalf("error = %v; want error %v", err, tc.wantError)
			}
			if !tc.wantError && (worker.count != 4 || worker.hist.TotalCount() != 4) {
				t.Fatalf("count=%d histogram=%d", worker.count, worker.hist.TotalCount())
			}
		})
	}
}

func TestPacedPhaseDrainsSlotsAfterLateACK(t *testing.T) {
	deadline := make(chan time.Time, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		until := <-deadline
		for id := uint32(1); id <= 3; id++ {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
			if id == 1 {
				time.Sleep(time.Until(until) + time.Millisecond)
			}
			payload := make([]byte, 20)
			binary.BigEndian.PutUint32(payload, id)
			binary.BigEndian.PutUint64(payload[4:], uint64(id))
			wire, _ := (&protocol.Message{Opcode: protocol.S_AckSendMessage, Data: payload}).Write()
			if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	start := time.Now()
	until := start.Add(30 * time.Millisecond)
	deadline <- until
	worker := worker{conn: conn, id: 1, hist: hdrhistogram.New(1, 10000000, 3)}
	pace := &pacer{start: start, interval: 10 * time.Millisecond}
	if err := worker.phase(until, 1, 4, true, nil, pace); err != nil {
		t.Fatal(err)
	}
	if worker.count != 3 || worker.hist.TotalCount() != 3 {
		t.Fatalf("scheduled 3 messages, got %d ACKs and %d samples", worker.count, worker.hist.TotalCount())
	}
}

func retainedMessage(key messageKey, measured bool, sentNS int64) protocol.RetainedMessage {
	var id protocol.ClientMessageID
	binary.BigEndian.PutUint64(id[:8], key.worker)
	binary.BigEndian.PutUint64(id[8:], uint64(key.request))
	return protocol.RetainedMessage{ConvID: 1, ClientMessageID: id, ContentType: protocol.ContentTypePlainText, Content: encodeBenchmarkContent(40, key, measured, sentNS)}
}

func TestDeliveryTrackerOutOfOrderDuplicateAndMissing(t *testing.T) {
	t.Run("out of order", func(t *testing.T) {
		tracker := newDeliveryTracker(2, 40)
		now := time.Now().UnixNano()
		keys := []messageKey{{1, 1}, {2, 1}}
		for _, key := range keys {
			if err := tracker.add(key, true, now); err != nil {
				t.Fatal(err)
			}
			if err := tracker.setWriteStart(key, now); err != nil {
				t.Fatal(err)
			}
		}
		for _, event := range []struct {
			sub int
			key messageKey
		}{{1, keys[1]}, {0, keys[0]}, {1, keys[0]}, {0, keys[1]}} {
			if err := tracker.observe(event.sub, retainedMessage(event.key, true, now), now+1000); err != nil {
				t.Fatal(err)
			}
		}
		if tracker.measuredDelivered != 4 || tracker.measuredOutstanding != 0 {
			t.Fatalf("delivered=%d outstanding=%d", tracker.measuredDelivered, tracker.measuredOutstanding)
		}
	})
	t.Run("duplicate", func(t *testing.T) {
		tracker := newDeliveryTracker(1, 40)
		key := messageKey{1, 1}
		now := time.Now().UnixNano()
		_ = tracker.add(key, true, now)
		_ = tracker.setWriteStart(key, now)
		if err := tracker.observe(0, retainedMessage(key, true, now), now+1000); err != nil {
			t.Fatal(err)
		}
		if err := tracker.observe(0, retainedMessage(key, true, now), now+1000); err == nil {
			t.Fatal("duplicate accepted")
		}
	})
	t.Run("missing", func(t *testing.T) {
		tracker := newDeliveryTracker(2, 40)
		key := messageKey{1, 1}
		now := time.Now().UnixNano()
		_ = tracker.add(key, false, now)
		_ = tracker.setWriteStart(key, now)
		if err := tracker.observe(0, retainedMessage(key, false, now), now+1000); err != nil {
			t.Fatal(err)
		}
		if err := tracker.waitDrained(false, 2*time.Millisecond); err == nil {
			t.Fatal("missing delivery not detected")
		}
	})
}

func TestDeliveryTrackerRejectsWrongPayloadLength(t *testing.T) {
	key := messageKey{1, 1}
	now := time.Now().UnixNano()
	for _, delta := range []int{-1, 1} {
		t.Run(fmt.Sprintf("delta_%d", delta), func(t *testing.T) {
			tracker := newDeliveryTracker(1, 40)
			if err := tracker.add(key, true, now); err != nil {
				t.Fatal(err)
			}
			if err := tracker.setWriteStart(key, now); err != nil {
				t.Fatal(err)
			}
			message := retainedMessage(key, true, now)
			message.Content = message.Content[:len(message.Content)+min(delta, 0)]
			if delta > 0 {
				message.Content += "x"
			}
			if err := tracker.observe(0, message, now+1000); err == nil {
				t.Fatalf("payload length %d accepted", len(message.Content))
			}
		})
	}
}

func encodeBroadcastPageForTest(m protocol.RetainedMessage) []byte {
	b := bytes.NewBuffer(make([]byte, 0, 41+45+len(m.Content)))
	binary.Write(b, binary.BigEndian, uint64(1))
	b.WriteByte(1)
	b.Write([]byte{0, 0})
	binary.Write(b, binary.BigEndian, uint64(1))
	binary.Write(b, binary.BigEndian, uint64(0))
	binary.Write(b, binary.BigEndian, uint64(1))
	binary.Write(b, binary.BigEndian, uint32(0))
	binary.Write(b, binary.BigEndian, uint16(1))
	binary.Write(b, binary.BigEndian, m.ConvID)
	binary.Write(b, binary.BigEndian, uint64(1))
	b.Write(m.ClientMessageID[:])
	binary.Write(b, binary.BigEndian, uint16(0))
	binary.Write(b, binary.BigEndian, m.Timestamp)
	b.WriteByte(m.ContentType)
	binary.Write(b, binary.BigEndian, uint16(len(m.Content)))
	b.WriteString(m.Content)
	return b.Bytes()
}

func TestReceiverUnsubscribeFence(t *testing.T) {
	for _, tc := range []struct {
		name             string
		ackCorrelation   uint32
		delayedDuplicate bool
		wantError        bool
	}{
		{name: "success", ackCorrelation: 7},
		{name: "wrong correlation", ackCorrelation: 8, wantError: true},
		{name: "delayed duplicate", ackCorrelation: 7, delayedDuplicate: true, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			key := messageKey{1, 1}
			now := time.Now().UnixNano()
			message := retainedMessage(key, true, now)
			tracker := newDeliveryTracker(1, 40)
			if err := tracker.add(key, true, now); err != nil {
				t.Fatal(err)
			}
			if err := tracker.setWriteStart(key, now); err != nil {
				t.Fatal(err)
			}
			if err := tracker.observe(0, message, now+1000); err != nil {
				t.Fatal(err)
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer conn.Close()
				_, data, err := conn.ReadMessage()
				if err != nil {
					t.Error(err)
					return
				}
				request, err := protocol.ReadMessage(data)
				if err != nil || request.Opcode != protocol.C_UnsubscribeConvs || binary.BigEndian.Uint32(request.Data[len(request.Data)-4:]) != 7 {
					t.Errorf("invalid fence request: opcode=%d err=%v", request.Opcode, err)
					return
				}
				if tc.delayedDuplicate {
					time.Sleep(40 * time.Millisecond)
					wire, _ := (&protocol.Message{Opcode: protocol.S_MessagePage, Data: encodeBroadcastPageForTest(message)}).Write()
					if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
						return
					}
				}
				payload := make([]byte, 4)
				binary.BigEndian.PutUint32(payload, tc.ackCorrelation)
				wire, _ := (&protocol.Message{Opcode: protocol.S_AckUnsubscribeConvs, Data: payload}).Write()
				_ = conn.WriteMessage(websocket.BinaryMessage, wire)
			}))
			defer server.Close()
			conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			fence := &receiverFence{correlation: 7}
			done := make(chan error, 1)
			go func() { done <- receiverLoop(0, conn, tracker, fence) }()
			if err := sendReceiverFence(conn, fence); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if (err != nil) != tc.wantError {
					t.Fatalf("error=%v, wantError=%v", err, tc.wantError)
				}
			case <-time.After(time.Second):
				t.Fatal("receiver fence timed out")
			}
		})
	}
}

func TestPacerSchedulesAggregateSlots(t *testing.T) {
	start := time.Now().Add(-time.Second)
	p := &pacer{start: start, interval: 10 * time.Millisecond}
	for range 3 {
		if ok, _ := p.wait(start.Add(25 * time.Millisecond)); !ok {
			t.Fatal("slot unexpectedly rejected")
		}
	}
	if ok, _ := p.wait(start.Add(25 * time.Millisecond)); ok {
		t.Fatal("slot past phase end accepted")
	}
	if p.next != 4 {
		t.Fatalf("claimed slots=%d", p.next)
	}
}

func TestSubscribeAcceptsPresenceBeforeReady(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		if _, _, err := conn.ReadMessage(); err != nil {
			t.Error(err)
			return
		}
		ready := make([]byte, 30)
		binary.BigEndian.PutUint32(ready, 7)
		binary.BigEndian.PutUint16(ready[4:], 1)
		binary.BigEndian.PutUint64(ready[6:], 1)
		for _, msg := range []protocol.Message{{Opcode: protocol.S_RoomPresenceUpdate}, {Opcode: protocol.S_SubscriptionReady, Data: ready}} {
			wire, err := msg.Write()
			if err != nil {
				t.Error(err)
				return
			}
			if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				t.Error(err)
				return
			}
		}
	}))
	defer server.Close()
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := subscribe(conn, 7); err != nil {
		t.Fatal(err)
	}
}

func TestProbeValidatesCorrelation(t *testing.T) {
	for _, valid := range []bool{true, false} {
		stop := make(chan struct{}, 1)
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
			if err != nil {
				t.Error(err)
				return
			}
			defer conn.Close()
			_, data, err := conn.ReadMessage()
			if err != nil {
				t.Error(err)
				return
			}
			msg, err := protocol.ReadMessage(data)
			if err != nil {
				t.Error(err)
				return
			}
			payload := make([]byte, 16)
			copy(payload, msg.Data)
			if !valid {
				payload[0] ^= 1
			}
			wire, err := (&protocol.Message{Opcode: protocol.S_Pong, Data: payload}).Write()
			if err != nil {
				t.Error(err)
				return
			}
			if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				t.Error(err)
				return
			}
			stop <- struct{}{}
		}))
		conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
		if err != nil {
			t.Fatal(err)
		}
		result, err := probeLoop(conn, stop, time.Now())
		conn.Close()
		server.Close()
		if (err == nil) != valid {
			t.Fatalf("valid=%v error=%v", valid, err)
		}
		if valid && len(result["samples"].([]map[string]float64)) != 1 {
			t.Fatal("missing probe sample")
		}
	}
}
