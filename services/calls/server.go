package calls

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type Command struct {
	Action        string `json:"action"`
	DM            string `json:"dm_id"`
	ID            string `json:"call_id"`
	ConferenceID  string `json:"conference_id,omitempty"`
	AppointmentID string `json:"appointment_id,omitempty"`
	OccurrenceAt  string `json:"occurrence_at,omitempty"`
	RequestID     string `json:"request_id,omitempty"`
}
type Call struct {
	ID     string `json:"id"`
	DM     string `json:"dm_id"`
	Caller string `json:"caller"`
	Callee string `json:"callee"`
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
}
type Event struct {
	Type        string `json:"type"`
	RequestID   string `json:"request_id,omitempty"`
	Username    string `json:"username,omitempty"`
	Call        *Call  `json:"call,omitempty"`
	Join        *Join  `json:"join,omitempty"`
	Message     string `json:"message,omitempty"`
	Conferences []Join `json:"conferences,omitempty"`
}
type device struct {
	id     Identity
	conn   *websocket.Conn
	out    chan Event
	done   chan struct{}
	closed bool
	online bool
}
type session struct {
	call           Call
	workspace      string
	caller, callee *device
	timer          *time.Timer
	cancel         context.CancelFunc
	provisioning   bool
	conference     *conference
}
type conference struct {
	id, workspace string
	meeting       Meeting
	participants  map[string]Join
	title         string
}
type Server struct {
	mu                                      sync.Mutex
	devices                                 map[*device]bool
	calls                                   map[string]*session
	busy                                    map[string]*session
	conferences                             map[string]*conference
	Provider                                Provider
	Auth                                    Authorizer
	Meetings                                *ScheduledMeetings
	Secret, Issuer                          string
	RingTimeout, Lifetime, OperationTimeout time.Duration
	MaxConnections, MaxDevices              int
	operations                              chan struct{}
}

func NewServer(p Provider, a Authorizer, secret, issuer string) *Server {
	return &Server{devices: map[*device]bool{}, calls: map[string]*session{}, busy: map[string]*session{}, conferences: map[string]*conference{}, Provider: p, Auth: a, Secret: secret, Issuer: issuer, RingTimeout: 30 * time.Second, Lifetime: time.Hour, OperationTimeout: 5 * time.Second, MaxConnections: 1024, MaxDevices: 8, operations: make(chan struct{}, 128)}
}
func key(w, u string) string { return w + "/" + u }
func (s *Server) emit(d *device, e Event) {
	if d.closed {
		return
	}
	select {
	case d.out <- e:
	default:
		d.closed = true
		close(d.done)
	}
}
func (s *Server) broadcast(c *session, j1, j2 *Join) {
	for d := range s.devices {
		if d.online && d.id.Workspace == c.workspace && (d.id.Username == c.call.Caller || d.id.Username == c.call.Callee) {
			v := c.call
			e := Event{Type: "state", Call: &v}
			if d == c.caller {
				e.Join = j1
			}
			if d == c.callee {
				e.Join = j2
			}
			s.emit(d, e)
		}
	}
}
func (s *Server) cleanup(m Meeting) {
	if m.Room == "" {
		return
	}
	if p, ok := s.Provider.(EndProvider); ok {
		ctx, cancel := context.WithTimeout(context.Background(), s.OperationTimeout)
		defer cancel()
		_ = p.End(ctx, m)
	}
}

// finish removes every index and timer under lock. Network cleanup is always outside it.
func (s *Server) finish(c *session, reason string) {
	if s.calls[c.call.ID] != c {
		return
	}
	delete(s.calls, c.call.ID)
	delete(s.busy, key(c.workspace, c.call.Caller))
	delete(s.busy, key(c.workspace, c.call.Callee))
	c.timer.Stop()
	if c.cancel != nil {
		c.cancel()
	}
	c.call.State = "ended"
	c.call.Reason = reason
	s.broadcast(c, nil, nil)
}
func (s *Server) expire(c *session, reason string) {
	s.mu.Lock()
	if reason == "timeout" && c.call.State != "ringing" {
		s.mu.Unlock()
		return
	}
	s.finish(c, reason)
	s.mu.Unlock()
}
func (s *Server) connected(w, u string) bool {
	for d := range s.devices {
		if d.online && !d.closed && d.id.Workspace == w && d.id.Username == u {
			return true
		}
	}
	return false
}
func (s *Server) command(d *device, cmd Command) {
	select {
	case s.operations <- struct{}{}:
		defer func() { <-s.operations }()
	default:
		s.mu.Lock()
		event := Event{Type: "error", Message: denied.Error()}
		if cmd.Action == "appointment" {
			event.Type = "appointment"
			event.RequestID = cmd.RequestID
		}
		s.emit(d, event)
		s.mu.Unlock()
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.OperationTimeout)
	defer cancel()
	if cmd.Action == "appointment" {
		s.joinAppointment(ctx, d, cmd)
		return
	}
	n, e := strconv.ParseUint(cmd.DM, 10, 64)
	if e != nil || n == 0 || strconv.FormatUint(n, 10) != cmd.DM {
		s.mu.Lock()
		s.emit(d, Event{Type: "error", Message: denied.Error()})
		s.mu.Unlock()
		return
	}
	var partner string
	if cmd.Action == "start" {
		partner, e = s.Auth.Partner(ctx, d.id, cmd.DM)
	}
	s.mu.Lock()
	fail := func() { s.emit(d, Event{Type: "error", Message: denied.Error()}); s.mu.Unlock() }
	if d.closed || !s.devices[d] {
		s.mu.Unlock()
		return
	}
	if cmd.Action == "start" {
		for id, conf := range s.conferences {
			if !time.Now().Before(conf.meeting.Expires) {
				delete(s.conferences, id)
			}
		}
		var conf *conference
		if cmd.ConferenceID != "" {
			conf = s.conferences[cmd.ConferenceID]
			if conf == nil || conf.workspace != d.id.Workspace || conf.participants[d.id.Username].ConferenceID == "" || len(conf.participants) >= 256 {
				fail()
				return
			}
		}
		if e != nil || partner == d.id.Username || !validUsername(partner) || !s.connected(d.id.Workspace, partner) || s.busy[key(d.id.Workspace, d.id.Username)] != nil || s.busy[key(d.id.Workspace, partner)] != nil {
			fail()
			return
		}
		c := &session{call: Call{ID: randomID(), DM: cmd.DM, Caller: d.id.Username, Callee: partner, State: "ringing"}, workspace: d.id.Workspace, caller: d, conference: conf}
		s.calls[c.call.ID] = c
		s.busy[key(c.workspace, c.call.Caller)] = c
		s.busy[key(c.workspace, c.call.Callee)] = c
		c.timer = time.AfterFunc(s.RingTimeout, func() { s.expire(c, "timeout") })
		s.broadcast(c, nil, nil)
		s.mu.Unlock()
		return
	}
	c := s.calls[cmd.ID]
	if c == nil || c.workspace != d.id.Workspace || c.call.DM != cmd.DM || (d.id.Username != c.call.Caller && d.id.Username != c.call.Callee) {
		fail()
		return
	}
	switch cmd.Action {
	case "accept":
		if c.call.State != "ringing" || c.provisioning || d.id.Username != c.call.Callee {
			fail()
			return
		}
		c.provisioning = true
		c.callee = d
		c.cancel = cancel
		s.mu.Unlock()
		partner, e = s.Auth.Partner(ctx, d.id, cmd.DM)
		var m Meeting
		var j1, j2 Join
		if c.conference != nil {
			m = c.conference.meeting
		}
		cleanup := func() {
			if c.conference == nil {
				s.cleanup(m)
			}
		}
		if e == nil && partner != c.call.Caller {
			e = denied
		}
		if e == nil && c.conference == nil {
			m, e = s.Provider.Create(ctx, time.Now().Add(s.Lifetime))
		}
		if e == nil && !time.Now().Before(m.Expires) {
			e = denied
		}
		if e == nil {
			j1, e = s.Provider.Join(ctx, m, c.call.Caller)
		}
		if e == nil {
			j2, e = s.Provider.Join(ctx, m, c.call.Callee)
		}
		s.mu.Lock()
		if s.calls[c.call.ID] != c {
			s.mu.Unlock()
			cleanup()
			return
		}
		if e != nil || ctx.Err() != nil || c.caller.closed || d.closed || !time.Now().Before(m.Expires) || (c.conference == nil && len(s.conferences) >= 1024) || (c.conference != nil && len(c.conference.participants) >= 256) {
			s.finish(c, "unavailable")
			s.mu.Unlock()
			cleanup()
			return
		}
		conf := c.conference
		if conf == nil {
			conf = &conference{id: randomID(), workspace: c.workspace, meeting: m, participants: map[string]Join{}, title: c.call.Caller + " · " + c.call.Callee}
			s.conferences[conf.id] = conf
		}
		j1.ConferenceID, j2.ConferenceID = conf.id, conf.id
		j1.Title, j2.Title = conf.title, conf.title
		j1.ExpiresAt, j2.ExpiresAt = m.Expires.Unix(), m.Expires.Unix()
		conf.participants[c.call.Caller] = j1
		conf.participants[c.call.Callee] = j2
		c.cancel = nil
		c.call.State = "accepted"
		c.timer.Stop()
		// Delivery completes the invitation. The provider owns the conference
		// from here; neither disconnect nor another invitation may terminate it.
		delete(s.calls, c.call.ID)
		delete(s.busy, key(c.workspace, c.call.Caller))
		delete(s.busy, key(c.workspace, c.call.Callee))
		s.broadcast(c, &j1, &j2)
		s.mu.Unlock()
		return
	case "decline":
		if c.call.State != "ringing" || d.id.Username != c.call.Callee {
			fail()
			return
		}
	case "cancel":
		if c.call.State != "ringing" || d != c.caller {
			fail()
			return
		}
	default:
		fail()
		return
	}
	s.finish(c, cmd.Action)
	s.mu.Unlock()
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		http.Error(w, "method not allowed", 405)
		return
	}
	if r.URL.Path == "/health" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"status":"ok"}`)
		return
	}
	if r.URL.Path != "/ws" {
		http.NotFound(w, r)
		return
	}
	values := r.Header.Values("X-NRC-Calls-Auth")
	if len(values) != 1 {
		http.Error(w, "unauthorized", 401)
		return
	}
	id, e := verify(values[0], s.Secret, s.Issuer, "nrc-calls")
	if e != nil {
		http.Error(w, "unauthorized", 401)
		return
	}
	s.mu.Lock()
	count := 0
	for d := range s.devices {
		if d.id.Workspace == id.Workspace && d.id.Username == id.Username {
			count++
		}
	}
	if len(s.devices) >= s.MaxConnections || count >= s.MaxDevices {
		s.mu.Unlock()
		http.Error(w, "capacity", 503)
		return
	}
	// Reserve capacity before upgrading, including concurrently pending upgrades.
	d := &device{id: id, out: make(chan Event, 32), done: make(chan struct{})}
	s.devices[d] = true
	s.mu.Unlock()
	conn, e := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if e != nil {
		s.mu.Lock()
		delete(s.devices, d)
		s.mu.Unlock()
		return
	}
	d.conn = conn
	conn.SetReadLimit(4096)
	defer func() {
		conn.CloseNow()
		s.mu.Lock()
		delete(s.devices, d)
		if !d.closed {
			d.closed = true
			close(d.done)
		}
		c := s.busy[key(id.Workspace, id.Username)]
		if c != nil && (c.caller == d || c.callee == d || (c.call.State == "ringing" && !s.connected(id.Workspace, id.Username))) {
			s.finish(c, "disconnect")
		}
		s.mu.Unlock()
	}()
	s.mu.Lock()
	d.online = true
	var conferences []Join
	for _, conf := range s.conferences {
		if conf.workspace == id.Workspace && time.Now().Before(conf.meeting.Expires) {
			if join, ok := conf.participants[id.Username]; ok {
				conferences = append(conferences, join)
			}
		}
	}
	s.emit(d, Event{Type: "ready", Username: id.Username, Conferences: conferences})
	if c := s.busy[key(id.Workspace, id.Username)]; c != nil {
		v := c.call
		s.emit(d, Event{Type: "state", Call: &v})
	}
	s.mu.Unlock()
	go func() {
		defer conn.CloseNow()
		timer := time.NewTimer(time.Until(time.Unix(id.Exp, 0)))
		defer timer.Stop()
		for {
			select {
			case <-d.done:
				return
			case <-timer.C:
				return
			case ev := <-d.out:
				b, _ := json.Marshal(ev)
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				e := conn.Write(ctx, websocket.MessageText, b)
				cancel()
				if e != nil {
					return
				}
			}
		}
	}()
	commands := make(chan Command, 1)
	go func() {
		for {
			select {
			case <-d.done:
				return
			case cmd := <-commands:
				s.command(d, cmd)
			}
		}
	}()
	for {
		kind, b, e := conn.Read(r.Context())
		if e != nil {
			return
		}
		if kind != websocket.MessageText {
			return
		}
		var cmd Command
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.DisallowUnknownFields()
		if dec.Decode(&cmd) != nil || dec.Decode(new(any)) != io.EOF {
			s.mu.Lock()
			s.emit(d, Event{Type: "error", Message: denied.Error()})
			s.mu.Unlock()
			continue
		}
		select {
		case commands <- cmd:
		default:
			return // Bounded inbound backlog; close abusive/blocked devices.
		}
	}
}
