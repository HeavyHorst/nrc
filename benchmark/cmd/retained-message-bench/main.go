// Retained-message ingestion and fan-out benchmark.
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/HdrHistogram/hdrhistogram-go"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const payloadHeaderSize = 32
const maxTrackedDeliveries = 10_000_000

func token(user string) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{"sub": user, "username": user, "iss": "nrc-tailscale-proxy", "aud": "nrc", "exp": time.Now().Add(time.Hour).Unix()})
	unsigned := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	mac := hmac.New(sha256.New, []byte("dev-insecure-nrc-jwt-secret"))
	mac.Write([]byte(unsigned))
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

type messageKey struct {
	worker  uint64
	request uint32
}
type expectedMessage struct {
	measured bool
	sentNS   int64
	writeNS  int64
	seen     []bool
}
type deliveryTracker struct {
	mu                  sync.Mutex
	expected            map[messageKey]*expectedMessage
	subscribers, sent   int
	payloadSize         int
	delivered           int64
	measuredSent        int64
	measuredDelivered   int64
	outstanding         int64
	measuredOutstanding int64
	maxOutstanding      int64
	latency             *hdrhistogram.Histogram
}

func newDeliveryTracker(subscribers, payloadSize int) *deliveryTracker {
	return &deliveryTracker{subscribers: subscribers, payloadSize: payloadSize, expected: make(map[messageKey]*expectedMessage), latency: hdrhistogram.New(1, 60_000_000, 3)}
}

func (t *deliveryTracker) add(key messageKey, measured bool, sentNS int64) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if (len(t.expected)+1)*t.subscribers > maxTrackedDeliveries {
		return fmt.Errorf("tracked delivery limit %d exceeded", maxTrackedDeliveries)
	}
	if _, exists := t.expected[key]; exists {
		return fmt.Errorf("duplicate published identity %+v", key)
	}
	t.expected[key] = &expectedMessage{measured: measured, sentNS: sentNS, seen: make([]bool, t.subscribers)}
	t.sent++
	t.outstanding += int64(t.subscribers)
	if measured {
		t.measuredSent++
		t.measuredOutstanding += int64(t.subscribers)
	}
	if t.outstanding > t.maxOutstanding {
		t.maxOutstanding = t.outstanding
	}
	return nil
}

func (t *deliveryTracker) setWriteStart(key messageKey, writeNS int64) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.expected[key]
	if e == nil || e.writeNS != 0 {
		return fmt.Errorf("cannot set write start for %+v", key)
	}
	e.writeNS = writeNS
	return nil
}

func (t *deliveryTracker) observe(subscriber int, m protocol.RetainedMessage, arrivedNS int64) error {
	if len(m.Content) != t.payloadSize {
		return fmt.Errorf("invalid retained benchmark payload length: got %d, want %d", len(m.Content), t.payloadSize)
	}
	key, measured, sentNS, err := decodeBenchmarkPayload(m)
	if err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.expected[key]
	if e == nil {
		return fmt.Errorf("subscriber %d received unknown message %+v", subscriber, key)
	}
	if e.measured != measured || e.sentNS != sentNS {
		return fmt.Errorf("subscriber %d payload metadata mismatch for %+v", subscriber, key)
	}
	if e.writeNS == 0 {
		return fmt.Errorf("subscriber %d observed message before write start %+v", subscriber, key)
	}
	if e.seen[subscriber] {
		return fmt.Errorf("subscriber %d duplicate message %+v", subscriber, key)
	}
	e.seen[subscriber] = true
	t.delivered++
	t.outstanding--
	if measured {
		t.measuredDelivered++
		t.measuredOutstanding--
		if err := t.latency.RecordValue(max(1, (arrivedNS-e.writeNS)/1000)); err != nil {
			return err
		}
	}
	return nil
}

func (t *deliveryTracker) waitDrained(measured bool, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		t.mu.Lock()
		n := t.outstanding
		if measured {
			n = t.measuredOutstanding
		}
		t.mu.Unlock()
		if n == 0 {
			return nil
		}
		time.Sleep(time.Millisecond)
	}
	t.mu.Lock()
	n := t.outstanding
	if measured {
		n = t.measuredOutstanding
	}
	t.mu.Unlock()
	return fmt.Errorf("broadcast drain timeout: %d deliveries missing", n)
}

func encodeBenchmarkContent(size int, key messageKey, measured bool, sentNS int64) string {
	b := []byte(strings.Repeat("x", size))
	copy(b, "RMB1")
	binary.BigEndian.PutUint64(b[4:12], key.worker)
	binary.BigEndian.PutUint32(b[12:16], key.request)
	if measured {
		b[16] = 1
	} else {
		b[16] = 0
	}
	binary.BigEndian.PutUint64(b[20:28], uint64(sentNS))
	binary.BigEndian.PutUint32(b[28:32], uint32(key.worker)^key.request^uint32(sentNS)^uint32(uint64(sentNS)>>32))
	return string(b)
}

func decodeBenchmarkPayload(m protocol.RetainedMessage) (messageKey, bool, int64, error) {
	var zero messageKey
	b := []byte(m.Content)
	if m.ConvID != 1 || m.ContentType != protocol.ContentTypePlainText || len(b) < payloadHeaderSize || string(b[:4]) != "RMB1" {
		return zero, false, 0, fmt.Errorf("invalid retained benchmark payload")
	}
	key := messageKey{binary.BigEndian.Uint64(b[4:12]), binary.BigEndian.Uint32(b[12:16])}
	measured := b[16] == 1
	if b[16] > 1 || b[17] != 'x' || b[18] != 'x' || b[19] != 'x' {
		return zero, false, 0, fmt.Errorf("invalid payload flags")
	}
	sentNS := int64(binary.BigEndian.Uint64(b[20:28]))
	want := uint32(key.worker) ^ key.request ^ uint32(sentNS) ^ uint32(uint64(sentNS)>>32)
	if binary.BigEndian.Uint32(b[28:32]) != want {
		return zero, false, 0, fmt.Errorf("invalid payload checksum")
	}
	for _, c := range b[32:] {
		if c != 'x' {
			return zero, false, 0, fmt.Errorf("invalid payload padding")
		}
	}
	var id protocol.ClientMessageID
	binary.BigEndian.PutUint64(id[:8], key.worker)
	binary.BigEndian.PutUint64(id[8:], uint64(key.request))
	if m.ClientMessageID != id {
		return zero, false, 0, fmt.Errorf("payload/client ID mismatch")
	}
	return key, measured, sentNS, nil
}

type pacer struct {
	mu        sync.Mutex
	next      int64
	start     time.Time
	interval  time.Duration
	lateTotal time.Duration
	lateMax   time.Duration
}

func (p *pacer) wait(until time.Time) (bool, time.Duration) {
	if p == nil {
		return time.Now().Before(until), 0
	}
	p.mu.Lock()
	target := p.start.Add(time.Duration(p.next) * p.interval)
	p.next++
	p.mu.Unlock()
	if !target.Before(until) {
		return false, 0
	}
	if d := time.Until(target); d > 0 {
		time.Sleep(d)
	}
	late := time.Since(target)
	if late < 0 {
		late = 0
	}
	p.mu.Lock()
	p.lateTotal += late
	if late > p.lateMax {
		p.lateMax = late
	}
	p.mu.Unlock()
	return true, late
}

type worker struct {
	conn  *websocket.Conn
	id    uint64
	next  uint32
	hist  *hdrhistogram.Histogram
	count int64
}

func (w *worker) phase(until time.Time, depth, size int, measured bool, tracker *deliveryTracker, pace *pacer) error {
	starts := make([]time.Time, depth)
	plainContent := strings.Repeat("x", size)
	// Paced runs drain every scheduled slot, even when an ACK crosses the
	// deadline. Include that catch-up in elapsed time rather than dropping work.
	for pace != nil || time.Now().Before(until) {
		first := w.next + 1
		sent := 0
		for i := range starts {
			ok, _ := pace.wait(until)
			if !ok {
				break
			}
			w.next++
			key := messageKey{w.id, w.next}
			var id protocol.ClientMessageID
			binary.BigEndian.PutUint64(id[:8], w.id)
			binary.BigEndian.PutUint64(id[8:], uint64(w.next))
			sentNS := time.Now().UnixNano()
			content := plainContent
			if tracker != nil {
				content = encodeBenchmarkContent(size, key, measured, sentNS)
				if err := tracker.add(key, measured, sentNS); err != nil {
					return err
				}
			}
			payload, err := protocol.EncodeSendMessageV2(1, id, w.next, protocol.ContentTypePlainText, content)
			if err != nil {
				return err
			}
			wire, err := (&protocol.Message{Opcode: protocol.C_SendMessageV2, Data: payload}).Write()
			if err != nil {
				return err
			}
			w.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			starts[i] = time.Now()
			if tracker != nil {
				if err := tracker.setWriteStart(key, starts[i].UnixNano()); err != nil {
					return err
				}
			}
			if err := w.conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return err
			}
			sent++
		}
		if sent == 0 {
			break
		}
		for j := 0; j < sent; j++ {
			w.conn.SetReadDeadline(time.Now().Add(10 * time.Second))
			_, data, err := w.conn.ReadMessage()
			if err != nil {
				return err
			}
			arrived := time.Now()
			msg, err := protocol.ReadMessage(data)
			if err != nil {
				return err
			}
			if msg.Opcode != protocol.S_AckSendMessage {
				return fmt.Errorf("unexpected opcode %d: %x", msg.Opcode, msg.Data)
			}
			ack, err := protocol.DecodeAckSendMessage(msg.Data)
			if err != nil {
				return err
			}
			if ack.ClientReqID < first || ack.ClientReqID >= first+uint32(sent) || ack.AssignedSeq == 0 {
				return fmt.Errorf("invalid ACK: %+v", ack)
			}
			i := int(ack.ClientReqID - first)
			if starts[i].IsZero() {
				return fmt.Errorf("duplicate ACK: %+v", ack)
			}
			elapsed := arrived.Sub(starts[i])
			starts[i] = time.Time{}
			if measured {
				if err := w.hist.RecordValue(max(1, elapsed.Microseconds())); err != nil {
					return err
				}
				w.count++
			}
		}
	}
	return nil
}

func connect(server, user string) (*websocket.Conn, error) {
	header := http.Header{"X-Nrc-Auth": []string{token(user)}}
	conn, _, err := websocket.DefaultDialer.Dial(server+"/retained-bench", header)
	if err != nil {
		return nil, err
	}
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	_, data, err := conn.ReadMessage()
	if err != nil {
		conn.Close()
		return nil, err
	}
	msg, err := protocol.ReadMessage(data)
	if err != nil || msg.Opcode != protocol.S_ServerReady {
		conn.Close()
		return nil, fmt.Errorf("missing server ready: %v", err)
	}
	return conn, nil
}

func subscribe(conn *websocket.Conn, correlation uint32) error {
	payload, err := protocol.EncodeSubscribeConvsV2(correlation, 1)
	if err != nil {
		return err
	}
	wire, err := (&protocol.Message{Opcode: protocol.C_SubscribeConvsV2, Data: payload}).Write()
	if err != nil {
		return err
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
		return err
	}
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		msg, err := protocol.ReadMessage(data)
		if err != nil {
			return err
		}
		if msg.Opcode == protocol.S_RoomPresenceUpdate {
			continue
		}
		if msg.Opcode != protocol.S_SubscriptionReady {
			return fmt.Errorf("missing subscription ready: opcode=%d data=%x", msg.Opcode, msg.Data)
		}
		r, err := protocol.DecodeSubscriptionReady(msg.Data)
		if err != nil || r.CorrelationID != correlation || len(r.Entries) != 1 || r.Entries[0].ConvID != 1 {
			return fmt.Errorf("invalid subscription ready: %+v: %v", r, err)
		}
		return nil
	}
}

type receiverFence struct {
	correlation uint32
	armed       atomic.Bool
}

func receiverLoop(index int, conn *websocket.Conn, tracker *deliveryTracker, fence *receiverFence) error {
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		arrived := time.Now().UnixNano()
		msg, err := protocol.ReadMessage(data)
		if err != nil {
			return err
		}
		if msg.Opcode == protocol.S_RoomPresenceUpdate {
			continue
		}
		if msg.Opcode == protocol.S_AckUnsubscribeConvs {
			ack, err := protocol.DecodeAckUnsubscribeConvs(msg.Data)
			if err != nil {
				return fmt.Errorf("subscriber %d invalid unsubscribe ACK: %w", index, err)
			}
			if !fence.armed.Load() {
				return fmt.Errorf("subscriber %d unsolicited unsubscribe ACK", index)
			}
			if ack.CorrelationID != fence.correlation {
				return fmt.Errorf("subscriber %d unsubscribe ACK correlation %d, want %d", index, ack.CorrelationID, fence.correlation)
			}
			return nil
		}
		if msg.Opcode != protocol.S_MessagePage {
			return fmt.Errorf("subscriber %d unexpected opcode %d", index, msg.Opcode)
		}
		page, err := protocol.DecodeMessagePage(msg.Data)
		if err != nil {
			return err
		}
		if !page.Ascending || page.ConvID != 1 || len(page.Messages) != 1 {
			return fmt.Errorf("subscriber %d invalid broadcast page", index)
		}
		if err := tracker.observe(index, page.Messages[0], arrived); err != nil {
			return err
		}
	}
}

func sendReceiverFence(conn *websocket.Conn, fence *receiverFence) error {
	payload := protocol.EncodeUnsubscribeConvsWithCorrelation(fence.correlation, 1)
	wire, err := (&protocol.Message{Opcode: protocol.C_UnsubscribeConvs, Data: payload}).Write()
	if err != nil {
		return err
	}
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	fence.armed.Store(true)
	return conn.WriteMessage(websocket.BinaryMessage, wire)
}

// Probe RTT includes client scheduling and socket work, not just worker stalls.
func probeLoop(conn *websocket.Conn, stop <-chan struct{}, start time.Time) (map[string]any, error) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	hist := hdrhistogram.New(1, 60_000_000, 3)
	var samples []map[string]float64
	for {
		select {
		case <-stop:
			return map[string]any{"samples": samples, "p99_ms": float64(hist.ValueAtQuantile(99)) / 1000, "max_ms": float64(hist.Max()) / 1000}, nil
		case <-ticker.C:
			sent := time.Now()
			wire, err := (&protocol.Message{Opcode: protocol.C_Ping, Data: protocol.EncodePing(sent.UnixNano())}).Write()
			if err != nil {
				return nil, err
			}
			conn.SetWriteDeadline(sent.Add(10 * time.Second))
			conn.SetReadDeadline(sent.Add(10 * time.Second))
			if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return nil, err
			}
			_, data, err := conn.ReadMessage()
			elapsed := time.Since(sent)
			if err != nil {
				return nil, err
			}
			msg, err := protocol.ReadMessage(data)
			if err != nil || msg.Opcode != protocol.S_Pong {
				return nil, fmt.Errorf("invalid probe response: %v", err)
			}
			pong, err := protocol.DecodePongResponse(msg.Data)
			if err != nil || pong.Timestamp != sent.UnixNano() {
				return nil, fmt.Errorf("invalid probe correlation: %v", err)
			}
			if err := hist.RecordValue(max(1, elapsed.Microseconds())); err != nil {
				return nil, err
			}
			samples = append(samples, map[string]float64{"at_ms": float64(sent.Sub(start)) / float64(time.Millisecond), "rtt_ms": float64(elapsed) / float64(time.Millisecond)})
		}
	}
}

func run() error {
	server := flag.String("server", "ws://127.0.0.1:18089", "local benchmark server")
	clients := flag.Int("clients", 16, "publisher connections")
	depth := flag.Int("depth", 1, "requests per wave per publisher (1..4)")
	size := flag.Int("size", 256, "message content bytes")
	duration := flag.Duration("duration", time.Second, "measured phase")
	warmup := flag.Duration("warmup", 200*time.Millisecond, "untimed warmup")
	subscribers := flag.Int("subscribers", 0, "broadcast receiver connections")
	rate := flag.Float64("rate", 0, "aggregate fixed publish messages/sec (0 is unlimited)")
	probe := flag.Bool("probe", false, "sample same-worker ping RTT every 100ms")
	flag.Parse()
	if *clients < 1 || *depth < 1 || *depth > 4 || *size < 1 || *size > protocol.MaxAllowedContentLength || *duration <= 0 || *warmup <= 0 || *subscribers < 0 || *subscribers > 1024 || *rate < 0 || *rate > 1e9 || (*subscribers > 0 && *size < payloadHeaderSize) {
		return fmt.Errorf("invalid benchmark configuration")
	}
	workers := make([]worker, *clients)
	for i := range workers {
		c, err := connect(*server, fmt.Sprintf("retained-bench-publisher-%d", i))
		if err != nil {
			return err
		}
		defer c.Close()
		workers[i] = worker{c, uint64(i + 1), 0, hdrhistogram.New(1, 10000000, 3), 0}
	}
	var tracker *deliveryTracker
	receiverConns := make([]*websocket.Conn, *subscribers)
	receiverFences := make([]receiverFence, *subscribers)
	receiverErrors := make(chan error, max(1, *subscribers))
	if *subscribers > 0 {
		tracker = newDeliveryTracker(*subscribers, *size)
		for i := range receiverConns {
			receiverFences[i].correlation = uint32(i + 1)
			c, err := connect(*server, fmt.Sprintf("retained-bench-subscriber-%d", i))
			if err != nil {
				return err
			}
			if err = subscribe(c, uint32(i+1)); err != nil {
				c.Close()
				return err
			}
			receiverConns[i] = c
			defer c.Close()
			c.SetReadDeadline(time.Time{})
			go func(n int, c *websocket.Conn) { receiverErrors <- receiverLoop(n, c, tracker, &receiverFences[n]) }(i, c)
		}
	}
	phase := func(d time.Duration, measured bool) (time.Duration, *pacer, error) {
		var pace *pacer
		start := time.Now()
		if *rate > 0 {
			pace = &pacer{start: start, interval: time.Duration(float64(time.Second) / *rate)}
		}
		var wg sync.WaitGroup
		errs := make(chan error, len(workers))
		for i := range workers {
			wg.Add(1)
			go func(w *worker) {
				defer wg.Done()
				errs <- w.phase(start.Add(d), *depth, *size, measured, tracker, pace)
			}(&workers[i])
		}
		wg.Wait()
		elapsed := time.Since(start)
		close(errs)
		for err := range errs {
			if err != nil {
				return elapsed, pace, err
			}
		}
		select {
		case err := <-receiverErrors:
			return elapsed, pace, err
		default:
		}
		return elapsed, pace, nil
	}
	if _, _, err := phase(*warmup, false); err != nil {
		return err
	}
	if tracker != nil {
		if err := tracker.waitDrained(false, 15*time.Second); err != nil {
			return err
		}
		tracker.mu.Lock()
		tracker.maxOutstanding = 0
		tracker.mu.Unlock()
	}
	var probeConn *websocket.Conn
	if *probe {
		var err error
		probeConn, err = connect(*server, "retained-bench-probe")
		if err != nil {
			return err
		}
		defer probeConn.Close()
	}
	probeStop := make(chan struct{}, 1)
	defer close(probeStop)
	probeDone := make(chan error, 1)
	var probeResult map[string]any
	measuredStart := time.Now()
	if probeConn != nil {
		go func() {
			var err error
			probeResult, err = probeLoop(probeConn, probeStop, measuredStart)
			probeDone <- err
		}()
	}
	elapsed, pace, err := phase(*duration, true)
	if err != nil {
		return err
	}
	if tracker != nil {
		if err = tracker.waitDrained(true, 15*time.Second); err != nil {
			return err
		}
	}
	deliveryElapsed := time.Since(measuredStart)
	if probeConn != nil {
		probeStop <- struct{}{}
		if err := <-probeDone; err != nil {
			return err
		}
	}
	hist := hdrhistogram.New(1, 10000000, 3)
	var count int64
	for _, w := range workers {
		count += w.count
		if hist.Merge(w.hist) != 0 {
			return fmt.Errorf("dropped histogram samples")
		}
	}
	if count == 0 || count != hist.TotalCount() {
		return fmt.Errorf("invalid sample count")
	}
	result := map[string]any{"ops": count, "ops_per_sec": float64(count) / elapsed.Seconds(), "duration_ms": float64(elapsed) / float64(time.Millisecond), "latency_ms": map[string]float64{"p50": float64(hist.ValueAtQuantile(50)) / 1000, "p99": float64(hist.ValueAtQuantile(99)) / 1000}, "subscribers": *subscribers, "offered_rate": *rate, "achieved_publish_rate": float64(count) / elapsed.Seconds()}
	if probeConn != nil {
		result["probe"] = probeResult
	}
	if pace != nil {
		pace.mu.Lock()
		result["offered_messages"] = int64(math.Ceil(*rate * duration.Seconds()))
		result["publish_pacing_lateness_ms"] = map[string]float64{"mean": float64(pace.lateTotal) / float64(max(int64(1), count)) / float64(time.Millisecond), "max": float64(pace.lateMax) / float64(time.Millisecond)}
		pace.mu.Unlock()
	}
	if tracker != nil {
		for i, conn := range receiverConns {
			if err := sendReceiverFence(conn, &receiverFences[i]); err != nil {
				return err
			}
		}
		receiverTimeout := time.NewTimer(15 * time.Second)
		defer receiverTimeout.Stop()
		for range receiverConns {
			select {
			case err := <-receiverErrors:
				if err != nil {
					return err
				}
			case <-receiverTimeout.C:
				return fmt.Errorf("receiver fence timeout")
			}
		}
		tracker.mu.Lock()
		defer tracker.mu.Unlock()
		expectedDeliveries := count * int64(*subscribers)
		if tracker.measuredSent != count || tracker.measuredDelivered != expectedDeliveries || tracker.latency.TotalCount() != expectedDeliveries || tracker.outstanding != 0 || tracker.measuredOutstanding != 0 {
			return fmt.Errorf("invalid receiver totals: sent=%d/%d delivered=%d/%d histogram=%d backlog=%d measured_backlog=%d", tracker.measuredSent, count, tracker.measuredDelivered, expectedDeliveries, tracker.latency.TotalCount(), tracker.outstanding, tracker.measuredOutstanding)
		}
		result["receiver"] = map[string]any{"expected": tracker.measuredSent * int64(*subscribers), "delivered": tracker.measuredDelivered, "delivery_rate": float64(tracker.measuredDelivered) / deliveryElapsed.Seconds(), "duration_ms": float64(deliveryElapsed) / float64(time.Millisecond), "latency_semantics": "publisher write-start timestamp to receiver ReadMessage completion (same-process wall clock; includes tracker bookkeeping before WriteMessage)", "latency_ms": map[string]float64{"p50": float64(tracker.latency.ValueAtQuantile(50)) / 1000, "p99": float64(tracker.latency.ValueAtQuantile(99)) / 1000}, "max_outstanding_backlog": tracker.maxOutstanding, "final_backlog": tracker.outstanding}
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
