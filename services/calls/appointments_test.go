package calls

import (
	"context"
	"encoding/json"
	"net/url"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

type appointmentAuth struct {
	authFake
	access  AppointmentAccess
	revoked atomic.Bool
}

func (a *appointmentAuth) Appointment(_ context.Context, id Identity, asset, occurrence string) (AppointmentAccess, error) {
	if asset != "42" || occurrence != "123" || id.Workspace != "team" || id.Username == "bob" && a.revoked.Load() {
		return AppointmentAccess{}, denied
	}
	return a.access, nil
}

type delayedAppointmentProvider struct {
	*Jitsi
	entered, release chan struct{}
	once             sync.Once
}

func (p *delayedAppointmentProvider) Join(ctx context.Context, m Meeting, user string) (Join, error) {
	if user == "bob" {
		p.once.Do(func() {
			close(p.entered)
			select {
			case <-p.release:
			case <-ctx.Done():
			}
		})
	}
	return p.Jitsi.Join(ctx, m, user)
}

func TestScheduledConcurrentJoinRechecksRemovalWithoutEndingOtherParticipant(t *testing.T) {
	jitsi, err := NewJitsi("https://meeting.example.invalid", "app", testKey)
	if err != nil {
		t.Fatal(err)
	}
	p := &delayedAppointmentProvider{Jitsi: jitsi, entered: make(chan struct{}), release: make(chan struct{})}
	s, address := setup(t, p, time.Minute)
	auth := &appointmentAuth{access: AppointmentAccess{Title: "Weekly review", Start: time.Now().Add(-time.Minute), End: time.Now().Add(time.Hour)}}
	s.Auth = auth
	s.Meetings, err = NewScheduledMeetings(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	alice := dial(t, address, "alice", "team")
	bob := dial(t, address, "bob", "team")
	sendAppointment := func(c *websocket.Conn, request string) {
		t.Helper()
		b, _ := json.Marshal(Command{Action: "appointment", AppointmentID: "42", OccurrenceAt: "123", RequestID: request})
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if err := c.Write(ctx, websocket.MessageText, b); err != nil {
			t.Fatal(err)
		}
	}
	sendAppointment(bob, "bob-1")
	select {
	case <-p.entered:
	case <-time.After(time.Second):
		t.Fatal("provider not reached")
	}
	sendAppointment(alice, "alice-1")
	accepted := read(t, alice)
	if accepted.Type != "appointment" || accepted.RequestID != "alice-1" || accepted.Join == nil {
		t.Fatalf("Alice: %+v", accepted)
	}
	auth.revoked.Store(true)
	close(p.release)
	rejected := read(t, bob)
	if rejected.Type != "appointment" || rejected.RequestID != "bob-1" || rejected.Join != nil || rejected.Message == "" {
		t.Fatalf("removed Bob: %+v", rejected)
	}
	auth.revoked.Store(false)
	sendAppointment(bob, "bob-2")
	rejoined := read(t, bob)
	if rejoined.Join == nil {
		t.Fatalf("re-added Bob: %+v", rejoined)
	}
	u1, _ := url.Parse(accepted.Join.URL)
	u2, _ := url.Parse(rejoined.Join.URL)
	if u1.Path != u2.Path || u1.RawQuery == u2.RawQuery {
		t.Fatal("must share a room but not a personal ticket")
	}
	if rejoined.Join.ConferenceID != "" || rejoined.Join.ExpiresAt > time.Now().Add(5*time.Minute).Unix() {
		t.Fatal("scheduled ticket leaked into long-lived DM access")
	}
}
