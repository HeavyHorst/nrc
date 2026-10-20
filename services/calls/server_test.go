package calls

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const testKey = "0123456789abcdef0123456789abcdef"
const dmID = "9223372036854775809"

type authFake struct{}

func (authFake) Partner(_ context.Context, id Identity, _ string) (string, error) {
	switch id.Username {
	case "alice":
		return "bob", nil
	case "bob":
		return "alice", nil
	}
	return "", denied
}

type providerFake struct {
	entered, release chan struct{}
	fail             bool
	failJoin         bool
	ends             atomic.Int32
}

func (p *providerFake) Create(ctx context.Context, exp time.Time) (Meeting, error) {
	if p.entered != nil {
		close(p.entered)
		select {
		case <-p.release:
		case <-ctx.Done():
		}
	}
	if p.fail {
		return Meeting{}, denied
	}
	return Meeting{"room", exp}, nil
}
func (p *providerFake) Join(_ context.Context, m Meeting, u string) (Join, error) {
	if p.failJoin {
		return Join{}, denied
	}
	return Join{URL: "https://fixture.invalid/session/" + m.Room + "?ticket=" + u}, nil
}
func (p *providerFake) End(context.Context, Meeting) error { p.ends.Add(1); return nil }
func identity(u, w string) Identity {
	return Identity{u, u, w, "nrc-proxy", "nrc-calls", time.Now().Unix() - 2, time.Now().Add(time.Minute).Unix()}
}
func setup(t *testing.T, p Provider, ring time.Duration) (*Server, string) {
	t.Helper()
	s := NewServer(p, authFake{}, testKey, "nrc-proxy")
	s.RingTimeout = ring
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return s, "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
}
func dial(t *testing.T, u, user, w string) *websocket.Conn {
	t.Helper()
	conn, _ := dialReady(t, u, user, w)
	return conn
}
func dialReady(t *testing.T, u, user, w string) (*websocket.Conn, Event) {
	t.Helper()
	ctx, c := context.WithTimeout(context.Background(), time.Second)
	defer c()
	conn, _, e := websocket.Dial(ctx, u, &websocket.DialOptions{HTTPHeader: http.Header{"X-Nrc-Calls-Auth": {sign(testKey, identity(user, w))}, "Origin": {"https://forwarded.example"}}})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { conn.CloseNow() })
	ev := read(t, conn)
	if ev.Type != "ready" || ev.Username != user {
		t.Fatalf("ready: %+v", ev)
	}
	return conn, ev
}
func read(t *testing.T, c *websocket.Conn) Event {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, b, e := c.Read(ctx)
	if e != nil {
		t.Fatal(e)
	}
	var ev Event
	if e = json.Unmarshal(b, &ev); e != nil {
		t.Fatal(e)
	}
	return ev
}
func send(t *testing.T, c *websocket.Conn, action, id string) {
	t.Helper()
	b, _ := json.Marshal(Command{Action: action, DM: dmID, ID: id})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if e := c.Write(ctx, websocket.MessageText, b); e != nil {
		t.Fatal(e)
	}
}
func start(t *testing.T, a, b *websocket.Conn) string {
	t.Helper()
	send(t, a, "start", "")
	ev := read(t, a)
	if ev.Call == nil || ev.Call.State != "ringing" {
		t.Fatalf("ring: %+v", ev)
	}
	if read(t, b).Call.ID != ev.Call.ID {
		t.Fatal("different call")
	}
	return ev.Call.ID
}
func ended(t *testing.T, c *websocket.Conn, reason string) {
	t.Helper()
	e := read(t, c)
	if e.Call == nil || e.Call.State != "ended" || e.Call.Reason != reason || e.Join != nil {
		t.Fatalf("ended: %+v", e)
	}
}
func wait(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !f() {
		if time.Now().After(deadline) {
			t.Fatal("condition timed out")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestMultipleDevicesIsolation(t *testing.T) {
	p := &providerFake{}
	s, u := setup(t, p, time.Second)
	a := dial(t, u, "alice", "w")
	a2 := dial(t, u, "alice", "w")
	b := dial(t, u, "bob", "w")
	b2 := dial(t, u, "bob", "w")
	outsider := dial(t, u, "mallory", "w")
	other := dial(t, u, "alice", "other")
	id := start(t, a, b)
	read(t, a2)
	read(t, b2)
	for _, c := range []*websocket.Conn{outsider, other} {
		send(t, c, "accept", id)
		if ev := read(t, c); ev.Type != "error" || ev.Call != nil {
			t.Fatalf("leak %+v", ev)
		}
	}
	send(t, b, "accept", id)
	for _, c := range []*websocket.Conn{a, a2, b, b2} {
		ev := read(t, c)
		if ev.Call == nil || ev.Call.State != "accepted" || ((ev.Join != nil) != (c == a || c == b)) {
			t.Fatalf("credentials %+v", ev)
		}
		if ev.Join != nil {
			want := "alice"
			if c == b {
				want = "bob"
			}
			if ev.Join.URL != "https://fixture.invalid/session/room?ticket="+want {
				t.Fatal("provider-specific credentials were changed or sent to the wrong participant")
			}
		}
	}
	b2.CloseNow()
	wait(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.devices) == 5 })
	send(t, a2, "hangup", id)
	if read(t, a2).Type != "error" {
		t.Fatal("idle hangup")
	}
	b.CloseNow()
	wait(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.calls) == 0 && len(s.busy) == 0 })
	// Acceptance releases both identities. A new device can call immediately;
	// closing the old device must not terminate the delivered conference.
	b3 := dial(t, u, "bob", "w")
	next := start(t, b3, a)
	read(t, a2)
	send(t, b3, "cancel", next)
	ended(t, b3, "cancel")
	ended(t, a, "cancel")
	ended(t, a2, "cancel")
	if p.ends.Load() != 0 {
		t.Fatal("terminated a delivered conference")
	}
}
func TestAcceptCancelCleanup(t *testing.T) {
	p := &providerFake{entered: make(chan struct{}), release: make(chan struct{})}
	s, u := setup(t, p, time.Second)
	a := dial(t, u, "alice", "w")
	b := dial(t, u, "bob", "w")
	b2 := dial(t, u, "bob", "w")
	id := start(t, a, b)
	read(t, b2)
	send(t, b, "accept", id)
	<-p.entered
	send(t, b2, "accept", id)
	if read(t, b2).Type != "error" {
		t.Fatal("second accept won")
	}
	send(t, a, "cancel", id)
	ended(t, a, "cancel")
	ended(t, b, "cancel")
	ended(t, b2, "cancel")
	close(p.release)
	wait(t, func() bool { return p.ends.Load() == 1 })
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.calls) != 0 {
		t.Fatal("resurrected call")
	}
}
func TestTimeoutErrorsDisconnect(t *testing.T) {
	for _, mode := range []string{"timeout", "provider", "disconnect", "decline"} {
		t.Run(mode, func(t *testing.T) {
			p := &providerFake{fail: mode == "provider"}
			s, u := setup(t, p, 80*time.Millisecond)
			s.Lifetime = 80 * time.Millisecond
			a := dial(t, u, "alice", "w")
			send(t, a, "start", "")
			if read(t, a).Type != "error" {
				t.Fatal("offline")
			}
			b := dial(t, u, "bob", "w")
			id := start(t, a, b)
			switch mode {
			case "timeout":
				ended(t, a, "timeout")
				ended(t, b, "timeout")
			case "provider":
				send(t, b, "accept", id)
				ended(t, a, "unavailable")
				ended(t, b, "unavailable")
			case "disconnect":
				a.CloseNow()
				ended(t, b, "disconnect")
			case "decline":
				send(t, b, "decline", id)
				ended(t, a, "decline")
				ended(t, b, "decline")
			}
			wait(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.calls) == 0 && len(s.busy) == 0 })
		})
	}
}
func TestAuthHTTP(t *testing.T) {
	s, u := setup(t, &providerFake{}, time.Second)
	httpURL := "http" + strings.TrimPrefix(u, "ws")
	resp, e := http.Get(strings.TrimSuffix(httpURL, "/ws") + "/health")
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatal(resp.StatusCode)
	}
	for _, mutate := range []func(*Identity){func(c *Identity) { c.Aud = "nrc-server" }, func(c *Identity) { c.Iss = "wrong" }, func(c *Identity) { c.Sub = "other" }, func(c *Identity) { c.Exp = time.Now().Unix() }, func(c *Identity) { c.Nbf = time.Now().Add(time.Hour).Unix() }, func(c *Identity) { c.Workspace = "../x" }, func(c *Identity) { c.Username = "long@identity" }} {
		id := identity("alice", "w")
		mutate(&id)
		r, _ := http.NewRequest("GET", httpURL, nil)
		r.Header.Set("X-NRC-Calls-Auth", sign(testKey, id))
		resp, e := http.DefaultClient.Do(r)
		if e != nil {
			t.Fatal(e)
		}
		resp.Body.Close()
		if resp.StatusCode != 401 {
			t.Fatal(resp.StatusCode)
		}
	}
	for _, token := range []string{"", sign("wrong", identity("alice", "w")), "a.b.c", "eyJhbGciOiJub25lIn0.e30."} {
		r, _ := http.NewRequest("GET", httpURL, nil)
		r.Header.Set("X-NRC-Calls-Auth", token)
		resp, _ := http.DefaultClient.Do(r)
		resp.Body.Close()
		if resp.StatusCode != 401 {
			t.Fatal(resp.StatusCode)
		}
	}
	r, _ := http.NewRequest("GET", httpURL, nil)
	r.Header["X-Nrc-Calls-Auth"] = []string{sign(testKey, identity("alice", "w")), sign(testKey, identity("alice", "w"))}
	resp, e = http.DefaultClient.Do(r)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatal("duplicate assertion headers accepted")
	}
	s.MaxDevices = 1
	a := dial(t, u, "alice", "w")
	_ = a
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, resp, e = websocket.Dial(ctx, u, &websocket.DialOptions{HTTPHeader: http.Header{"X-Nrc-Calls-Auth": {sign(testKey, identity("alice", "w"))}}})
	if e == nil || resp.StatusCode != 503 {
		t.Fatal("capacity")
	}
}
func TestJitsiClaims(t *testing.T) {
	if _, e := NewJitsi("http://meet.example", "app", testKey); e == nil {
		t.Fatal("insecure URL")
	}
	j, e := NewJitsi("https://meet.example:8443", "app", testKey)
	if e != nil {
		t.Fatal(e)
	}
	m, _ := j.Create(context.Background(), time.Now().Add(time.Hour))
	join, e := j.Join(context.Background(), m, "alice")
	if e != nil {
		t.Fatal(e)
	}
	entry, e := url.Parse(join.URL)
	if e != nil || entry.Scheme != "https" || entry.Host != "meet.example:8443" || entry.Path != "/"+m.Room {
		t.Fatalf("invalid participant link: %v", e)
	}
	parts := strings.Split(entry.Query().Get("jwt"), ".")
	b, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var c map[string]any
	json.Unmarshal(b, &c)
	mac := hmac.New(sha256.New, []byte(testKey))
	mac.Write([]byte(parts[0] + "." + parts[1]))
	signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if c["aud"] != "jitsi" || c["iss"] != "app" || c["sub"] != "meet.example" || c["room"] != m.Room || c["exp"] != float64(m.Expires.Unix()) || !hmac.Equal(signature, mac.Sum(nil)) {
		t.Fatalf("claims %+v", c)
	}
	if c["context"].(map[string]any)["user"].(map[string]any)["id"] != "alice" {
		t.Fatal("identity")
	}
}
func TestNRCAuthorization(t *testing.T) {
	var reverse atomic.Bool
	reverse.Store(true)
	var requests atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, e := verify(r.Header.Get("X-NRC-Auth"), testKey, "nrc-proxy", "nrc-server")
		if e != nil || r.URL.Path != "/w" || id.Exp-time.Now().Unix() > 30 {
			http.Error(w, "unauthorized", 401)
			return
		}
		requests.Add(1)
		c, e := websocket.Accept(w, r, nil)
		if e != nil {
			return
		}
		defer c.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		_, b, e := c.Read(ctx)
		if e != nil {
			return
		}
		m, _ := protocol.ReadMessage(b)
		if m.Opcode != protocol.C_ListDMs || binary.BigEndian.Uint32(m.Data) != 1 {
			return
		}
		partner := "bob"
		if id.Username == "bob" {
			partner = "alice"
		}
		payload := make([]byte, 6)
		binary.BigEndian.PutUint32(payload[2:], 1)
		if id.Username != "bob" || reverse.Load() {
			binary.BigEndian.PutUint16(payload, 1)
			entry := make([]byte, 10)
			binary.BigEndian.PutUint64(entry, 0x8000000000000001)
			binary.BigEndian.PutUint16(entry[8:], uint16(len(partner)))
			payload = append(payload, entry...)
			payload = append(payload, partner...)
			payload = append(payload, 1, 1)
			payload = append(payload, make([]byte, 8)...)
		}
		b, _ = (&protocol.Message{Opcode: protocol.S_DMList, Data: payload}).Write()
		_ = c.Write(ctx, websocket.MessageBinary, b)
		_, _, _ = c.Read(ctx)
	}))
	defer ts.Close()
	a := NRCAuthorizer{"ws" + strings.TrimPrefix(ts.URL, "http"), testKey, "nrc-proxy", "nrc-server"}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	p, e := a.Partner(ctx, identity("alice", "w"), dmID)
	if e != nil || p != "bob" || requests.Load() != 2 {
		t.Fatalf("partner %s %v", p, e)
	}
	reverse.Store(false)
	if _, e = a.Partner(ctx, identity("alice", "w"), dmID); e == nil {
		t.Fatal("accepted unilateral membership")
	}
	if _, e = a.Partner(ctx, identity("alice", "w"), "9223372036854775810"); e == nil {
		t.Fatal("accepted unrelated DM")
	}
	if _, e = a.Partner(ctx, identity("alice", "w"), "1"); e == nil {
		t.Fatal("non-DM accepted")
	}
}

func TestProvisioningFailureCleanup(t *testing.T) {
	for _, mode := range []string{"join", "deadline", "disconnect"} {
		t.Run(mode, func(t *testing.T) {
			p := &providerFake{failJoin: mode == "join"}
			if mode != "join" {
				p.entered = make(chan struct{})
				p.release = make(chan struct{})
			}
			s, u := setup(t, p, time.Second)
			if mode == "deadline" {
				s.OperationTimeout = 40 * time.Millisecond
			}
			a := dial(t, u, "alice", "w")
			b := dial(t, u, "bob", "w")
			id := start(t, a, b)
			send(t, b, "accept", id)
			if mode == "disconnect" {
				<-p.entered
				b.CloseNow()
				ended(t, a, "disconnect")
				close(p.release)
			} else {
				ended(t, a, "unavailable")
				ended(t, b, "unavailable")
			}
			wait(t, func() bool { return p.ends.Load() == 1 })
		})
	}
}

type mutableAuth struct{ revoked atomic.Bool }

type conferenceAuth struct{}

func (conferenceAuth) Partner(_ context.Context, id Identity, dm string) (string, error) {
	pairs := map[string][2]string{dmID: {"alice", "bob"}, "9223372036854775810": {"bob", "charlie"}, "9223372036854775811": {"charlie", "dave"}, "9223372036854775812": {"mallory", "bob"}}
	pair := pairs[dm]
	if id.Username == pair[0] {
		return pair[1], nil
	}
	if id.Username == pair[1] {
		return pair[0], nil
	}
	return "", denied
}

type conferenceProvider struct {
	providerFake
	joinFailure atomic.Bool
}

func (p *conferenceProvider) Create(_ context.Context, expiry time.Time) (Meeting, error) {
	return Meeting{Room: randomID(), Expires: expiry}, nil
}
func (p *conferenceProvider) Join(ctx context.Context, m Meeting, user string) (Join, error) {
	if p.joinFailure.Load() {
		return Join{}, denied
	}
	return p.providerFake.Join(ctx, m, user)
}

func TestInviteExistingConference(t *testing.T) {
	p := &conferenceProvider{}
	s, u := setup(t, p, time.Second)
	s.Auth = conferenceAuth{}
	a, b, c := dial(t, u, "alice", "w"), dial(t, u, "bob", "w"), dial(t, u, "charlie", "w")
	id := start(t, a, b)
	send(t, b, "accept", id)
	first, second := read(t, a), read(t, b)
	if first.Join == nil || second.Join == nil || first.Join.ConferenceID == "" || first.Join.ConferenceID != second.Join.ConferenceID {
		t.Fatal("missing conference identity")
	}
	conf := first.Join.ConferenceID
	request := func(conn *websocket.Conn, cmd Command) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		body, _ := json.Marshal(cmd)
		if err := conn.Write(ctx, websocket.MessageText, body); err != nil {
			t.Fatal(err)
		}
	}
	// Knowing the conference ID is insufficient, even with a valid target DM.
	mallory := dial(t, u, "mallory", "w")
	other := dial(t, u, "bob", "other")
	for _, attempt := range []struct {
		conn     *websocket.Conn
		dm, conf string
	}{{mallory, "9223372036854775812", conf}, {other, "9223372036854775810", conf}, {b, "9223372036854775811", conf}, {b, "9223372036854775810", "unknown"}} {
		request(attempt.conn, Command{Action: "start", DM: attempt.dm, ConferenceID: attempt.conf})
		if ev := read(t, attempt.conn); ev.Type != "error" || ev.Call != nil {
			t.Fatalf("unauthorized conference disclosure: %+v", ev)
		}
	}
	invite := func(action string) {
		t.Helper()
		request(b, Command{Action: "start", DM: "9223372036854775810", ConferenceID: conf})
		out, in := read(t, b), read(t, c)
		if out.Call == nil || in.Call == nil || in.Call.State != "ringing" || in.Join != nil {
			t.Fatalf("invitation: %+v", in)
		}
		request(c, Command{Action: action, DM: "9223372036854775810", ID: in.Call.ID})
	}
	invite("decline")
	ended(t, b, "decline")
	ended(t, c, "decline")
	p.joinFailure.Store(true)
	invite("accept")
	ended(t, b, "unavailable")
	ended(t, c, "unavailable")
	p.joinFailure.Store(false)
	invite("accept")
	bJoin, cJoin := read(t, b), read(t, c)
	if bJoin.Join == nil || cJoin.Join == nil || bJoin.Join.URL != second.Join.URL || cJoin.Join.ConferenceID != conf {
		t.Fatal("created another conference")
	}
	want := strings.TrimSuffix(second.Join.URL, "bob") + "charlie"
	if cJoin.Join.URL != want {
		t.Fatal("not a fresh participant-specific link for the same room")
	}
	if cJoin.Join.Title != first.Join.Title || cJoin.Join.ExpiresAt != first.Join.ExpiresAt || cJoin.Join.ExpiresAt <= time.Now().Unix() {
		t.Fatal("invitation changed conference identity or expiry")
	}
	// Reconnect restores only this identity's own ticket in the same workspace.
	for _, check := range []struct {
		user, workspace string
		want            *Join
	}{{"alice", "w", first.Join}, {"charlie", "w", cJoin.Join}, {"mallory", "w", nil}, {"alice", "other", nil}} {
		conn, ready := dialReady(t, u, check.user, check.workspace)
		conn.CloseNow()
		if check.want == nil {
			if len(ready.Conferences) != 0 {
				t.Fatal("conference leaked")
			}
			continue
		}
		if len(ready.Conferences) != 1 || ready.Conferences[0] != *check.want {
			t.Fatal("wrong restored conference credentials")
		}
	}
	// A newly accepted participant can invite onward, without a creator-only gate.
	d := dial(t, u, "dave", "w")
	request(c, Command{Action: "start", DM: "9223372036854775811", ConferenceID: conf})
	read(t, c)
	incoming := read(t, d)
	request(c, Command{Action: "cancel", DM: "9223372036854775811", ID: incoming.Call.ID})
	ended(t, c, "cancel")
	ended(t, d, "cancel")
	if p.ends.Load() != 0 {
		t.Fatal("failure/cancellation destroyed existing conference")
	}
}

func TestExpiredConferenceInvitation(t *testing.T) {
	p := &conferenceProvider{}
	s, u := setup(t, p, time.Second)
	s.Lifetime = 100 * time.Millisecond
	a, b := dial(t, u, "alice", "w"), dial(t, u, "bob", "w")
	id := start(t, a, b)
	send(t, b, "accept", id)
	ev := read(t, a)
	read(t, b)
	time.Sleep(120 * time.Millisecond)
	reconnected, ready := dialReady(t, u, "alice", "w")
	reconnected.CloseNow()
	if len(ready.Conferences) != 0 {
		t.Fatal("restored expired credentials")
	}
	body, _ := json.Marshal(Command{Action: "start", DM: dmID, ConferenceID: ev.Join.ConferenceID})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := a.Write(ctx, websocket.MessageText, body); err != nil {
		t.Fatal(err)
	}
	if read(t, a).Type != "error" {
		t.Fatal("expired conference accepted")
	}
	if p.ends.Load() != 0 {
		t.Fatal("expiry terminated external media")
	}
}

func (a *mutableAuth) Partner(ctx context.Context, id Identity, dm string) (string, error) {
	if a.revoked.Load() {
		return "", denied
	}
	return (authFake{}).Partner(ctx, id, dm)
}
func TestAcceptanceReauthorizesAndBusy(t *testing.T) {
	auth := &mutableAuth{}
	s := NewServer(&providerFake{}, auth, testKey, "nrc-proxy")
	ts := httptest.NewServer(s)
	defer ts.Close()
	u := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
	a := dial(t, u, "alice", "w")
	b := dial(t, u, "bob", "w")
	id := start(t, a, b)
	send(t, b, "start", "")
	if read(t, b).Type != "error" {
		t.Fatal("busy call replaced")
	}
	auth.revoked.Store(true)
	send(t, b, "accept", id)
	ended(t, a, "unavailable")
	ended(t, b, "unavailable")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	for _, body := range []string{`{"action":"start","dm_id":"9223372036854775809","partner":"bob"}`, `{"action":"start","dm_id":9223372036854775809}`, `{} {}`} {
		if e := a.Write(ctx, websocket.MessageText, []byte(body)); e != nil {
			t.Fatal(e)
		}
		if read(t, a).Type != "error" {
			t.Fatal("malformed command accepted")
		}
	}
}
