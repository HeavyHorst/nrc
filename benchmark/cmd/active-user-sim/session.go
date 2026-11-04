package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type actor struct {
	id, local int
	room      uint64
	ws        *workspace
	session   *session
	next      uint32
	action    uint64
	readyHigh uint64 // Last subscription boundary; actor-owned.
	// Protected by workspace.mu, including writes from the continuous reader.
	subscribed bool
	cache      map[uint64]taskState
	assets     map[uint64]assetState
	edges      map[uint64]protocol.Edge
}

type reply struct {
	opcode uint16
	data   any
	err    error
}
type session struct {
	conn          *websocket.Conn
	done          chan struct{}
	heartbeatDone chan struct{}
	closing       atomic.Bool
	mu            sync.Mutex
	pending       map[uint32]chan reply
	expired       map[uint32]bool
}

func authToken(user string, ttl time.Duration) string {
	h := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	c, _ := json.Marshal(map[string]any{"sub": user, "username": user, "iss": "nrc-tailscale-proxy", "aud": "nrc", "exp": time.Now().Add(ttl).Unix(), "nbf": time.Now().Add(-time.Minute).Unix()})
	u := h + "." + base64.RawURLEncoding.EncodeToString(c)
	m := hmac.New(sha256.New, []byte(os.Getenv("NRC_SIM_JWT_SECRET")))
	m.Write([]byte(u))
	return u + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (a *actor) connect(ctx context.Context) error {
	c := a.ws.sim.c
	dial := net.Dialer{Timeout: c.Deadline}
	if c.SourceIP != "" {
		ips := strings.Split(c.SourceIP, ",")
		ip := net.ParseIP(ips[(a.id/c.Partitions)%len(ips)])
		if ip == nil {
			return fmt.Errorf("invalid source IP")
		}
		dial.LocalAddr = &net.TCPAddr{IP: ip}
	}
	d := websocket.Dialer{NetDialContext: dial.DialContext, HandshakeTimeout: c.Deadline, ReadBufferSize: 4096, WriteBufferSize: 1024, WriteBufferPool: writeBuffers}
	conn, _, err := d.DialContext(ctx, strings.TrimRight(c.Server, "/")+"/"+a.ws.name, http.Header{"X-Nrc-Auth": {authToken(fmt.Sprintf("sim-%d", a.id), c.Ramp+c.Duration+time.Hour)}})
	if err != nil {
		return err
	}
	conn.SetReadLimit(4 << 20)
	conn.SetReadDeadline(time.Now().Add(c.Deadline))
	_, wire, err := conn.ReadMessage()
	if err != nil {
		conn.Close()
		return err
	}
	m, err := protocol.ReadMessage(wire)
	if err != nil || m.Opcode != protocol.S_ServerReady {
		conn.Close()
		return fmt.Errorf("expected ServerReady: %v", err)
	}
	conn.SetReadDeadline(time.Time{})
	s := &session{conn: conn, done: make(chan struct{}), heartbeatDone: make(chan struct{}), pending: make(map[uint32]chan reply)}
	a.session = s
	go a.readLoop(s)
	// Keep early connections alive during a long ramp and post-run audits.
	// Gorilla permits WriteControl alongside the actor's single data writer.
	go func() {
		defer close(s.heartbeatDone)
		ticker := time.NewTicker(20 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-s.done:
				return
			case <-ticker.C:
				if err := s.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(c.Deadline)); err != nil {
					if !s.closing.Load() {
						a.ws.sim.metrics.fail("reliability", "transport keepalive: "+err.Error())
					}
					return
				}
				a.ws.sim.metrics.count("transport_keepalives", 1)
			}
		}
	}()
	if err = a.subscribe(ctx); err != nil {
		a.close()
		return err
	}
	a.ws.sim.metrics.count("connections", 1)
	return nil
}

var writeBuffers = &sync.Pool{}

func (a *actor) close() {
	if a.session == nil {
		return
	}
	s := a.session
	s.closing.Store(true)
	s.conn.Close()
	<-s.done
	<-s.heartbeatDone
	a.ws.mu.Lock()
	a.subscribed = false
	a.ws.mu.Unlock()
}

func pingRequest(id uint32) (uint16, []byte, error) {
	return protocol.C_Ping, protocol.EncodePing(int64(id)), nil
}

func (a *actor) subscribe(ctx context.Context) error {
	if err := a.write(protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(protocol.WorkspaceDataConvID)); err != nil {
		return err
	}
	if _, err := a.request(ctx, "barrier", false, pingRequest); err != nil {
		return err
	}
	r, err := a.request(ctx, "subscribe", false, func(id uint32) (uint16, []byte, error) {
		b, e := protocol.EncodeSubscribeConvsV2(id, a.room)
		return protocol.C_SubscribeConvsV2, b, e
	})
	if err != nil {
		return err
	}
	ready := r.data.(*protocol.SubscriptionReady)
	if len(ready.Entries) != 1 || ready.Entries[0].ConvID != a.room {
		a.ws.sim.metrics.fail("correctness", "incorrect retained subscription scope")
		return fmt.Errorf("incorrect retained subscription scope")
	}
	a.ws.mu.Lock()
	defer a.ws.mu.Unlock()
	entry := ready.Entries[0]
	// High-water is shard-wide, not room-local; other workspaces may advance it.
	var acknowledged uint64
	for _, e := range a.ws.messages {
		acknowledged = max(acknowledged, e.ack)
	}
	if entry.HighWaterSeq < acknowledged || entry.HighWaterSeq < a.readyHigh || entry.RetentionCutoffSeq != 0 {
		a.ws.sim.metrics.fail("correctness", "invalid retained subscription boundary")
		return fmt.Errorf("invalid retained subscription boundary")
	}
	a.readyHigh = entry.HighWaterSeq
	a.subscribed = true
	return nil
}

func (a *actor) write(op uint16, b []byte) error {
	wire, err := (&protocol.Message{Opcode: op, Data: b}).Write()
	if err != nil {
		return err
	}
	a.session.conn.SetWriteDeadline(time.Now().Add(a.ws.sim.c.Deadline))
	err = a.session.conn.WriteMessage(websocket.BinaryMessage, wire)
	a.ws.sim.metrics.count("bytes_sent", int64(len(wire)))
	return err
}

func expectedReply(op uint16) uint16 {
	switch op {
	case protocol.C_Ping:
		return protocol.S_Pong
	case protocol.C_SubscribeConvsV2:
		return protocol.S_SubscriptionReady
	case protocol.C_UnsubscribeConvs:
		return protocol.S_AckUnsubscribeConvs
	case protocol.C_CreateTask:
		return protocol.S_TaskCreated
	case protocol.C_UpdateTask:
		return protocol.S_TaskUpdated
	case protocol.C_DeleteTask:
		return protocol.S_TaskDeleted
	case protocol.C_CreateAsset:
		return protocol.S_AssetCreated
	case protocol.C_UpdateAsset:
		return protocol.S_AssetUpdated
	case protocol.C_DeleteAsset:
		return protocol.S_AssetDeleted
	case protocol.C_GetAsset:
		return protocol.S_AssetFull
	case protocol.C_CreateEdge:
		return protocol.S_EdgeCreated
	case protocol.C_DeleteEdge:
		return protocol.S_EdgeDeleted
	case protocol.C_ListAllEdges:
		return protocol.S_AllEdgeList
	case protocol.C_GetTask:
		return protocol.S_TaskFull
	case protocol.C_SendMessageV2:
		return protocol.S_AckSendMessage
	case protocol.C_ReplayMessagesAfter:
		return protocol.S_MessagePage
	}
	panic("unsupported request opcode")
}

func (a *actor) request(ctx context.Context, kind string, measured bool, encode func(uint32) (uint16, []byte, error)) (reply, error) {
	a.next++
	if a.next == 0 {
		panic("request correlation exhausted")
	}
	id := a.next
	op, b, err := encode(id)
	if err != nil {
		return reply{}, err
	}
	s := a.session
	ch := make(chan reply, 1)
	s.mu.Lock()
	s.pending[id] = ch
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.pending[id] != nil {
			if s.expired == nil {
				s.expired = make(map[uint32]bool)
			}
			s.expired[id] = true
			delete(s.pending, id)
		}
	}()
	start := time.Now()
	a.ws.sim.log(map[string]any{"user": a.id, "request": id, "operation": kind, "measured": measured, "time": start})
	err = a.write(op, b)
	if err == nil {
		timer := time.NewTimer(max(0, a.ws.sim.c.Deadline-time.Since(start)))
		defer timer.Stop()
		var r reply
		select {
		case r = <-ch:
			if r.err != nil {
				a.ws.sim.metrics.fail("reliability", r.err.Error())
				return r, r.err
			}
			if r.opcode != expectedReply(op) {
				err = fmt.Errorf("request %d got opcode %d, expected %d", id, r.opcode, expectedReply(op))
				a.ws.sim.metrics.fail("correctness", err.Error())
				return r, err
			}
			elapsed := time.Since(start)
			if elapsed > a.ws.sim.c.Deadline {
				a.ws.sim.metrics.fail("performance", "response arrived after request deadline: "+kind)
			}
			if measured {
				a.ws.sim.metrics.record(kind, elapsed)
				a.ws.sim.metrics.count("measured_"+kind, 1)
			}
			return r, nil
		case <-s.done:
			err = fmt.Errorf("connection closed waiting for %s", kind)
		case <-timer.C:
			err = fmt.Errorf("request deadline exceeded: %s", kind)
			a.ws.sim.metrics.fail("performance", err.Error())
		case <-ctx.Done():
			err = ctx.Err()
		}
	}
	a.ws.sim.metrics.fail("unknown", fmt.Sprintf("user %d %s: %v", a.id, kind, err))
	return reply{}, err
}

func (a *actor) readLoop(s *session) {
	defer close(s.done)
	for {
		_, wire, err := s.conn.ReadMessage()
		if err != nil {
			if !s.closing.Load() {
				a.ws.sim.metrics.fail("reliability", fmt.Sprintf("user %d unexpected disconnect: %v", a.id, err))
			}
			return
		}
		a.ws.sim.metrics.count("bytes_received", int64(len(wire)))
		m, err := protocol.ReadMessage(wire)
		if err != nil {
			a.ws.sim.metrics.fail("correctness", err.Error())
			continue
		}
		id, r, err := a.dispatch(m)
		if err != nil {
			a.ws.sim.metrics.fail("correctness", fmt.Sprintf("user %d: %v", a.id, err))
			continue
		}
		if id != 0 {
			s.mu.Lock()
			ch := s.pending[id]
			if ch != nil {
				// Retire on receipt, not when the actor eventually consumes the channel.
				delete(s.pending, id)
				ch <- r
			} else if s.expired[id] {
				a.ws.sim.metrics.count("late_responses", 1)
			} else {
				a.ws.sim.metrics.fail("correctness", "duplicate or unsolicited response")
			}
			s.mu.Unlock()
		}
	}
}

func (a *actor) dispatch(m *protocol.Message) (uint32, reply, error) {
	r := reply{opcode: m.Opcode}
	switch m.Opcode {
	case protocol.S_RoomPresenceUpdate:
		return 0, r, nil
	case protocol.S_Pong:
		v, e := protocol.DecodePongResponse(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return uint32(v.Timestamp), r, nil
	case protocol.S_SubscriptionReady:
		v, e := protocol.DecodeSubscriptionReady(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.CorrelationID, r, nil
	case protocol.S_AckUnsubscribeConvs:
		v, e := protocol.DecodeAckUnsubscribeConvs(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.CorrelationID, r, nil
	case protocol.S_ErrorResponse:
		v, e := protocol.DecodeErrorResponse(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.err = fmt.Errorf("server rejected opcode %d: %s", v.OriginOpcode, v.ErrorMessage)
		return v.CorrelationID, r, nil
	case protocol.S_TaskCreated:
		v, e := protocol.DecodeTaskCreated(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v.Task
		return v.CorrelationID, r, a.observeTask(v.Task)
	case protocol.S_TaskUpdated:
		v, e := protocol.DecodeTaskUpdated(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v.Task
		return v.CorrelationID, r, a.observeTask(v.Task)
	case protocol.S_TaskFull:
		v, e := protocol.DecodeTaskFull(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.CorrelationID, r, nil
	case protocol.S_TaskDeleted:
		v, e := protocol.DecodeTaskDeleted(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.CorrelationID, r, a.observeDelete("task", v.ConvID, v.TaskID)
	case protocol.S_AssetCreated:
		v, e := protocol.DecodeAssetCreated(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v.Asset
		return v.CorrelationID, r, a.observeAsset(v.Asset)
	case protocol.S_AssetUpdated:
		v, e := protocol.DecodeAssetUpdated(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v.Asset
		return v.CorrelationID, r, a.observeAsset(v.Asset)
	case protocol.S_AssetFull:
		v, e := protocol.DecodeAssetFullResponse(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v.Asset
		return v.CorrelationID, r, nil
	case protocol.S_AssetDeleted:
		v, e := protocol.DecodeAssetDeleted(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.CorrelationID, r, a.observeDelete("asset", v.ConvID, v.AssetID)
	case protocol.S_EdgeCreated:
		v, e := protocol.DecodeEdgeCreated(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v.Edge
		return v.CorrelationID, r, a.observeEdge(v.Edge)
	case protocol.S_EdgeDeleted:
		v, e := protocol.DecodeEdgeDeleted(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.CorrelationID, r, a.observeDelete("edge", v.ConvID, v.EdgeID)
	case protocol.S_AllEdgeList:
		v, e := protocol.DecodeAllEdgeListResponse(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.CorrelationID, r, nil
	case protocol.S_AckSendMessage:
		v, e := protocol.DecodeAckSendMessage(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		return v.ClientReqID, r, nil
	case protocol.S_MessagePage:
		v, e := protocol.DecodeMessagePage(m.Data)
		if e != nil {
			return 0, r, e
		}
		r.data = v
		if v.CorrelationID == 0 {
			if v.ConvID != a.room || !v.Ascending || v.HasMore || v.Truncated || len(v.Messages) != 1 || v.RetentionCutoffSeq != 0 {
				return 0, r, fmt.Errorf("live message wrong scope/direction")
			}
			if v.HighWaterSeq != v.Messages[0].Sequence || v.ContinuationCursor != v.Messages[0].Sequence {
				return 0, r, fmt.Errorf("invalid live message boundary")
			}
			for _, msg := range v.Messages {
				if e := a.observeMessage(msg); e != nil {
					return 0, r, e
				}
			}
		}
		return v.CorrelationID, r, nil
	default:
		return 0, r, fmt.Errorf("unexpected opcode %d", m.Opcode)
	}
}
