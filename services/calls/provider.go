package calls

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"
	"time"
)

type Meeting struct {
	Room    string
	Expires time.Time
}
type Join struct {
	// URL is a participant-specific HTTPS entry point. No provider code runs in NRC.
	URL string `json:"url"`
	// Filled by signaling, never by the adapter. Not a provider room identifier.
	ConferenceID string `json:"conference_id,omitempty"`
	Title        string `json:"title,omitempty"`
	ExpiresAt    int64  `json:"expires_at,omitempty"`
}

// Implementations must honor context cancellation. Create and Join run outside state locks.
// Join's Meeting.Expires is the requested ticket expiry and may be shorter than
// the room lifetime given to Create (scheduled appointments use five minutes).
type Provider interface {
	Create(context.Context, time.Time) (Meeting, error)
	Join(context.Context, Meeting, string) (Join, error)
}

// EndProvider cleans up failed or cancelled provisioning only. Successfully
// delivered conferences belong to the provider and are never ended by NRC.
type EndProvider interface {
	End(context.Context, Meeting) error
}
type Jitsi struct{ domain, subject, app, secret string }

func NewJitsi(raw, app, secret string) (*Jitsi, error) {
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" || app == "" || len(secret) < 32 {
		return nil, fmt.Errorf("JITSI_URL must be an HTTPS origin; app ID and >=32-byte secret required")
	}
	return &Jitsi{u.Host, strings.ToLower(u.Hostname()), app, secret}, nil
}
func randomID() string {
	var b [24]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b[:])
}
func (*Jitsi) Create(ctx context.Context, expiry time.Time) (Meeting, error) {
	if e := ctx.Err(); e != nil {
		return Meeting{}, e
	}
	return Meeting{"nrc" + randomID(), expiry}, nil
}
func (j *Jitsi) Join(ctx context.Context, m Meeting, user string) (Join, error) {
	if e := ctx.Err(); e != nil {
		return Join{}, e
	}
	claims := map[string]any{"iss": j.app, "aud": "jitsi", "sub": j.subject, "room": m.Room, "nbf": time.Now().Unix() - 2, "exp": m.Expires.Unix(), "context": map[string]any{"user": map[string]string{"id": user, "name": user}}}
	u := url.URL{Scheme: "https", Host: j.domain, Path: "/" + m.Room}
	u.RawQuery = url.Values{"jwt": {sign(j.secret, claims)}}.Encode()
	return Join{URL: u.String()}, nil
}
