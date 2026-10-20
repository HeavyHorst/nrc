package e2e

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/heavyhorst/nrc/services/calls"
)

// Exercise real NRC validation, calendar expansion, WAL recovery, signed calls
// authorization and Jitsi JWT generation. No external media server is contacted.
func TestScheduledConferenceMembershipAndRecovery(t *testing.T) {
	dir, meetingsDir := t.TempDir(), t.TempDir()
	workspace := "e2e-scheduled-calls"
	server := startServerInWorkDir(t, dir)
	defer func() { server.stop(t) }()
	connect := func(user string) *websocket.Conn {
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, user))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 30*time.Second)
		mustExpectServerReady(t, c)
		return c
	}
	owner := connect("organizer")
	start := time.Now().UTC().Truncate(time.Minute)
	at := strconv.FormatInt(start.UnixNano(), 10)
	record := map[string]any{
		"version": 2, "title": "Weekly review", "start_at": strconv.FormatInt(start.AddDate(0, 0, -7).UnixNano(), 10),
		"end_at":   strconv.FormatInt(start.AddDate(0, 0, -7).Add(45*time.Minute).UnixNano(), 10),
		"timezone": "UTC", "repeat": "weekly", "weekdays": []int{(int(start.Weekday())+6)%7 + 1}, "until": "",
		"participants": []string{"bob"}, "conference": "nrc", "exceptions": []any{},
	}
	preview := func() string {
		b, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if err := sendProtocolMessage(owner, protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeAppointment, protocol.ParentTypeNone, 0, preview(), "")); err != nil {
		t.Fatal(err)
	}
	created, err := protocol.DecodeAssetCreated(mustReadUntilOpcode(t, owner, protocol.S_AssetCreated, 20))
	if err != nil {
		t.Fatal(err)
	}
	id := created.Asset.AssetID
	update := func(c *websocket.Conn, accepted bool) {
		t.Helper()
		if err := sendProtocolMessage(c, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(0, id, preview(), "")); err != nil {
			t.Fatal(err)
		}
		op := protocol.S_AssetUpdated
		if !accepted {
			op = protocol.S_ErrorResponse
		}
		mustReadUntilOpcode(t, c, op, 30)
	}
	newCalls := func() *httptest.Server {
		p, err := calls.NewJitsi("https://media.example.invalid", "test-app", "test-only-jitsi-secret-at-least-32-bytes")
		if err != nil {
			t.Fatal(err)
		}
		s := calls.NewServer(p, calls.NRCAuthorizer{Server: wsURLForWorkspace(workspace), Secret: e2eJWTSecret, Issuer: e2eJWTIssuer, Audience: e2eJWTAudience}, e2eJWTSecret, e2eJWTIssuer)
		s.Meetings, err = calls.NewScheduledMeetings(meetingsDir)
		if err != nil {
			t.Fatal(err)
		}
		ts := httptest.NewServer(s)
		t.Cleanup(ts.Close)
		return ts
	}
	backend := newCalls()
	prepare := func(user, scope, occurrence string, allowed bool) string {
		t.Helper()
		header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
		claims, _ := json.Marshal(calls.Identity{Username: user, Sub: user, Workspace: scope, Iss: e2eJWTIssuer, Aud: "nrc-calls", Nbf: time.Now().Unix() - 2, Exp: time.Now().Add(time.Minute).Unix()})
		unsigned := header + "." + base64.RawURLEncoding.EncodeToString(claims)
		mac := hmac.New(sha256.New, []byte(e2eJWTSecret))
		mac.Write([]byte(unsigned))
		token := unsigned + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
		c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(backend.URL, "http")+"/ws", http.Header{"X-Nrc-Calls-Auth": {token}})
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		mustSetReadDeadline(t, c, 10*time.Second)
		var event calls.Event
		if err = c.ReadJSON(&event); err != nil || event.Type != "ready" || len(event.Conferences) != 0 {
			t.Fatalf("ready: %+v, %v", event, err)
		}
		if err = c.WriteJSON(calls.Command{Action: "appointment", AppointmentID: fmt.Sprint(id), OccurrenceAt: occurrence, RequestID: "request-1"}); err != nil {
			t.Fatal(err)
		}
		event = calls.Event{}
		if err = c.ReadJSON(&event); err != nil {
			t.Fatal(err)
		}
		if event.Type != "appointment" || event.RequestID != "request-1" || (event.Join != nil) != allowed {
			t.Fatalf("%s prepare allowed=%v: %+v", user, allowed, event)
		}
		if !allowed {
			return ""
		}
		if event.Join.ConferenceID != "" || event.Join.ExpiresAt > time.Now().Add(5*time.Minute).Unix() || event.Join.ExpiresAt <= time.Now().Unix() {
			t.Fatalf("invalid ticket metadata: %+v", event.Join)
		}
		u, err := url.Parse(event.Join.URL)
		if err != nil {
			t.Fatal(err)
		}
		parts := strings.Split(u.Query().Get("jwt"), ".")
		if len(parts) != 3 {
			t.Fatal("missing JWT")
		}
		body, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var jwt struct {
			Room    string `json:"room"`
			Exp     int64  `json:"exp"`
			Context struct {
				User struct {
					ID string `json:"id"`
				} `json:"user"`
			} `json:"context"`
		}
		if json.Unmarshal(body, &jwt) != nil || jwt.Context.User.ID != user || jwt.Exp != event.Join.ExpiresAt || "/"+jwt.Room != u.Path {
			t.Fatal("wrong personal ticket")
		}
		return jwt.Room
	}
	room := prepare("bob", workspace, at, true)
	if prepare("organizer", workspace, at, true) != room {
		t.Fatal("participants split into different rooms")
	}
	prepare("outsider", workspace, at, false)
	prepare("bob", "other-workspace", at, false)
	prepare("bob", workspace, strconv.FormatInt(start.Add(time.Hour).UnixNano(), 10), false)
	prepare("bob", workspace, strconv.FormatInt(start.AddDate(0, 0, 7).UnixNano(), 10), false)
	for _, encoded := range []string{"+" + at, "000" + at, " \t" + at + "\n "} {
		record["exceptions"] = []any{map[string]any{"at": encoded, "cancelled": false, "start_at": encoded, "participants": []string{}}}
		update(owner, true)
		prepare("bob", workspace, at, false)
		if prepare("organizer", workspace, at, true) != room {
			t.Fatal("equivalent timestamps changed room identity")
		}
	}
	record["exceptions"] = []any{}
	reader := connect("bob")
	record["participants"] = []string{"bob", "outsider"}
	update(reader, false) // Participants cannot grant themselves or others access.
	record["participants"] = []string{"carol"}
	update(owner, true)
	prepare("bob", workspace, at, false)
	if prepare("carol", workspace, at, true) != room {
		t.Fatal("adding someone replaced the room")
	}
	// An occurrence override replaces participants; the series still lists Carol.
	record["exceptions"] = []any{map[string]any{"at": at, "cancelled": false, "start_at": strconv.FormatInt(start.Add(5*time.Minute).UnixNano(), 10), "participants": []string{"bob"}}}
	update(owner, true)
	prepare("carol", workspace, at, false)
	if prepare("bob", workspace, at, true) != room {
		t.Fatal("rescheduling lost stable occurrence identity")
	}
	backend.Close()
	owner.Close()
	reader.Close()
	server.stop(t)
	server = startServerInWorkDir(t, dir)
	owner = connect("organizer")
	backend = newCalls()
	if prepare("bob", workspace, at, true) != room {
		t.Fatal("restart replaced provider room")
	}
	record["exceptions"] = []any{map[string]any{"at": at, "cancelled": true}}
	update(owner, true)
	prepare("bob", workspace, at, false)
	prepare("organizer", workspace, at, false)
}
