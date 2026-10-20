package calls

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// AppointmentAccess is an authoritative, effective occurrence, not a client
// supplied time or participant list. Assignees alone do not grant media access.
type AppointmentAccess struct {
	Title      string
	Start, End time.Time
}

type AppointmentAuthorizer interface {
	Appointment(context.Context, Identity, string, string) (AppointmentAccess, error)
}

func (a NRCAuthorizer) Appointment(ctx context.Context, id Identity, assetID, occurrence string) (AppointmentAccess, error) {
	var deniedAccess AppointmentAccess
	n, e := strconv.ParseUint(assetID, 10, 64)
	at, err := strconv.ParseInt(occurrence, 10, 64)
	if e != nil || err != nil || n == 0 || at <= 0 || strconv.FormatUint(n, 10) != assetID || strconv.FormatInt(at, 10) != occurrence {
		return deniedAccess, denied
	}
	u, e := url.Parse(a.Server)
	if e != nil {
		return deniedAccess, denied
	}
	u.Path = "/" + id.Workspace
	assertion := id
	assertion.Iss, assertion.Aud = a.Issuer, a.Audience
	assertion.Nbf, assertion.Exp = time.Now().Unix()-2, time.Now().Add(30*time.Second).Unix()
	c, _, e := websocket.Dial(ctx, u.String(), &websocket.DialOptions{HTTPHeader: http.Header{"X-Nrc-Auth": {sign(a.Secret, assertion)}}})
	if e != nil {
		return deniedAccess, denied
	}
	defer c.CloseNow()
	c.SetReadLimit(1 << 20)
	rpc := func(op uint16, data []byte, response uint16) ([]byte, error) {
		b, err := (&protocol.Message{Opcode: op, Data: data}).Write()
		if err != nil {
			return nil, err
		}
		if err = c.Write(ctx, websocket.MessageBinary, b); err != nil {
			return nil, err
		}
		for {
			_, b, err = c.Read(ctx)
			if err != nil {
				return nil, err
			}
			m, err := protocol.ReadMessage(b)
			if err != nil {
				return nil, err
			}
			if m.Opcode == response {
				return m.Data, nil
			}
			if m.Opcode == protocol.S_ErrorResponse {
				return nil, denied
			}
		}
	}
	getAsset := func() (protocol.Asset, error) {
		data, err := rpc(protocol.C_GetAsset, protocol.EncodeGetAsset(0, n), protocol.S_AssetFull)
		if err != nil {
			return protocol.Asset{}, err
		}
		return protocol.DecodeAssetFull(data)
	}
	asset, e := getAsset()
	if e != nil || asset.AssetID != n || asset.AssetType != protocol.AssetTypeAppointment {
		return deniedAccess, denied
	}
	var record struct {
		Version      int      `json:"version"`
		Conference   string   `json:"conference"`
		Start        string   `json:"start_at"`
		Repeat       string   `json:"repeat"`
		Participants []string `json:"participants"`
		Exceptions   []struct {
			At           string    `json:"at"`
			Start        string    `json:"start_at"`
			Cancelled    bool      `json:"cancelled"`
			Participants *[]string `json:"participants"`
		} `json:"exceptions"`
	}
	if json.Unmarshal([]byte(asset.Preview), &record) != nil || record.Version != 2 || record.Conference != "nrc" {
		return deniedAccess, denied
	}
	start := occurrence
	people := record.Participants
	storedStart, err := strconv.ParseInt(strings.TrimSpace(record.Start), 10, 64)
	if err != nil || storedStart <= 0 || record.Repeat == "" && storedStart != at {
		return deniedAccess, denied
	}
	for _, ex := range record.Exceptions {
		exAt, err := strconv.ParseInt(strings.TrimSpace(ex.At), 10, 64)
		if err != nil || exAt <= 0 {
			return deniedAccess, denied
		}
		if exAt != at {
			continue
		}
		if ex.Cancelled {
			return deniedAccess, denied
		}
		if ex.Start != "" {
			start = ex.Start
		}
		if ex.Participants != nil {
			people = *ex.Participants
		}
	}
	if asset.Owner != id.Username && !slices.Contains(people, id.Username) {
		return deniedAccess, denied
	}
	from, e := strconv.ParseInt(strings.TrimSpace(start), 10, 64)
	if e != nil || from <= 0 || from == 1<<63-1 {
		return deniedAccess, denied
	}
	// Ask NRC to establish that this original occurrence actually exists. Do not
	// duplicate timezone/recurrence rules in the conferencing adapter service.
	q := protocol.CalendarQuery{Start: from, End: from + 1, Limit: 100}
	for {
		data, err := protocol.EncodeCalendarQuery(q)
		if err != nil {
			return deniedAccess, denied
		}
		data, err = rpc(protocol.C_QueryCalendar, data, protocol.S_CalendarPage)
		if err != nil {
			return deniedAccess, denied
		}
		page, err := protocol.DecodeCalendarPage(data)
		if err != nil {
			return deniedAccess, denied
		}
		for _, row := range page.Rows {
			if !row.MatchesAppointmentOccurrence(n, at) {
				continue
			}
			// A concurrent edit between the preview and calendar reads must not
			// combine membership from one revision with times from another.
			after, err := getAsset()
			if err != nil || after.UpdatedAt != asset.UpdatedAt || after.Preview != asset.Preview || after.Owner != asset.Owner {
				return deniedAccess, denied
			}
			end := time.Unix(0, row.EndAt)
			if row.EndAt == 0 {
				end = time.Unix(0, row.ActualStartAt).Add(time.Hour)
			}
			return AppointmentAccess{Title: row.Title, Start: time.Unix(0, row.ActualStartAt), End: end}, nil
		}
		if !page.HasMore || len(page.Rows) == 0 || q.Cursor != nil && page.Cursor == *q.Cursor {
			return deniedAccess, denied
		}
		q.Cursor = &page.Cursor
	}
}

// ScheduledMeetings stores provider room identities, never personal tickets.
// A synced atomic file per occurrence survives calls-service restarts. Run one
// service instance per directory; the gate serializes room creation in-process.
type ScheduledMeetings struct {
	dir  string
	gate chan struct{}
}

func NewScheduledMeetings(dir string) (*ScheduledMeetings, error) {
	if dir == "" {
		return nil, errors.New("CALLS_DATA_DIR is required for scheduled conferences")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	return &ScheduledMeetings{dir: dir, gate: make(chan struct{}, 1)}, nil
}

func (m *ScheduledMeetings) meeting(ctx context.Context, s *Server, identity string, expires time.Time) (Meeting, error) {
	select {
	case m.gate <- struct{}{}:
		defer func() { <-m.gate }()
	case <-ctx.Done():
		return Meeting{}, ctx.Err()
	}
	hash := sha256.Sum256([]byte(identity))
	path := filepath.Join(m.dir, hex.EncodeToString(hash[:])+".json")
	data, err := os.ReadFile(path)
	if err == nil {
		var meeting Meeting
		if json.Unmarshal(data, &meeting) != nil || meeting.Room == "" || meeting.Expires.IsZero() {
			return Meeting{}, denied // Corruption must not split an existing conference.
		}
		if time.Now().Before(meeting.Expires) {
			return meeting, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return Meeting{}, err
	}
	meeting, err := s.Provider.Create(ctx, expires)
	if err != nil {
		return Meeting{}, err
	}
	if meeting.Room == "" || meeting.Expires.After(expires) || !time.Now().Before(meeting.Expires) || ctx.Err() != nil {
		s.cleanup(meeting)
		return Meeting{}, denied
	}
	data, err = json.Marshal(meeting)
	if err != nil {
		s.cleanup(meeting)
		return Meeting{}, err
	}
	f, err := os.CreateTemp(m.dir, ".meeting-")
	if err != nil {
		s.cleanup(meeting)
		return Meeting{}, err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(f.Name(), path)
	}
	if err != nil {
		s.cleanup(meeting)
		return Meeting{}, err
	}
	dir, err := os.Open(m.dir)
	if err == nil {
		err = dir.Sync()
		dir.Close()
	}
	// After rename the meeting may be visible. Never destroy it on a sync error.
	return meeting, err
}

func (s *Server) joinAppointment(ctx context.Context, d *device, cmd Command) {
	respond := func(j *Join) {
		s.mu.Lock()
		defer s.mu.Unlock()
		e := Event{Type: "appointment", RequestID: cmd.RequestID, Join: j}
		if j == nil {
			e.Message = "Conference unavailable: check participants, appointment time and provider"
		}
		s.emit(d, e)
	}
	a, ok := s.Auth.(AppointmentAuthorizer)
	if !ok || s.Meetings == nil || len(cmd.RequestID) == 0 || len(cmd.RequestID) > 64 {
		respond(nil)
		return
	}
	access, err := a.Appointment(ctx, d.id, cmd.AppointmentID, cmd.OccurrenceAt)
	eligible := func(a AppointmentAccess) bool {
		now := time.Now()
		return !now.Before(a.Start.Add(-15*time.Minute)) && now.Before(a.End.Add(15*time.Minute)) && a.End.After(a.Start)
	}
	if err != nil || !eligible(access) {
		respond(nil)
		return
	}
	identity := d.id.Workspace + "/" + cmd.AppointmentID + "/" + cmd.OccurrenceAt
	m, err := s.Meetings.meeting(ctx, s, identity, access.End.Add(15*time.Minute))
	if err != nil {
		respond(nil)
		return
	}
	// Join receives a short ticket deadline, never the whole series lifetime.
	// Removal stops new tickets; providers may retain already joined attendees.
	m.Expires = minTime(m.Expires, minTime(access.End.Add(15*time.Minute), time.Now().Add(5*time.Minute)))
	j, err := s.Provider.Join(ctx, m, d.id.Username)
	u, urlError := url.Parse(j.URL)
	if err != nil || urlError != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		respond(nil)
		return
	}
	after, err := a.Appointment(ctx, d.id, cmd.AppointmentID, cmd.OccurrenceAt)
	if err != nil || !eligible(after) || after.Start != access.Start || after.End != access.End || !time.Now().Before(m.Expires) || ctx.Err() != nil {
		respond(nil)
		return
	}
	j.ExpiresAt = m.Expires.Unix()
	// Scheduled tickets are not put in the DM conference registry. Every prepare
	// rechecks membership, including after reconnect and participant removal.
	j.ConferenceID = ""
	j.Title = after.Title
	respond(&j)
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}
