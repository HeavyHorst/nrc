package protocol

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"unicode/utf8"
)

const MaxMonitorInstances = 1024

type MonitorState struct {
	CorrelationID uint32
	MonitorID     uint64
	Revision      int64
	Sequence      uint64
}

func EncodeGetMonitorState(id uint64, correlation uint32) ([]byte, error) {
	if id == 0 {
		return nil, fmt.Errorf("invalid monitor ID")
	}
	b := make([]byte, 14)
	binary.BigEndian.PutUint16(b, C_GetMonitorState)
	binary.BigEndian.PutUint32(b[2:], correlation)
	binary.BigEndian.PutUint64(b[6:], id)
	return b, nil
}

func DecodeMonitorState(b []byte) (MonitorState, error) {
	if len(b) != 28 {
		return MonitorState{}, fmt.Errorf("invalid monitor state length")
	}
	r := MonitorState{binary.BigEndian.Uint32(b), binary.BigEndian.Uint64(b[4:]), int64(binary.BigEndian.Uint64(b[12:])), binary.BigEndian.Uint64(b[20:])}
	if r.MonitorID == 0 || r.Revision <= 0 {
		return MonitorState{}, fmt.Errorf("invalid monitor state")
	}
	return r, nil
}

// MonitorSnapshotPage is a fenced, complete-set page of non-retired instances.
// States describe observed check health, not qualified Incident episodes.
type MonitorSnapshotPage struct {
	MonitorState
	At, Horizon int64
	Next        uint64
	Instances   []MonitorAvailability
}

type MonitorAvailability struct {
	ID         uint64
	Identity   string
	State      uint8 // 0 healthy, 1 failing, 2 unknown, 3 paused
	ValidUntil int64
}

func EncodeGetMonitorSnapshot(state MonitorState, cursor uint64, at int64) ([]byte, error) {
	if state.MonitorID == 0 || state.Revision <= 0 || at < 0 || cursor != 0 && at == 0 {
		return nil, fmt.Errorf("invalid monitor snapshot request")
	}
	b := make([]byte, 46)
	binary.BigEndian.PutUint16(b, C_GetMonitorState)
	binary.BigEndian.PutUint32(b[2:], state.CorrelationID)
	binary.BigEndian.PutUint64(b[6:], state.MonitorID)
	binary.BigEndian.PutUint64(b[14:], cursor)
	binary.BigEndian.PutUint64(b[22:], uint64(state.Revision))
	binary.BigEndian.PutUint64(b[30:], state.Sequence)
	binary.BigEndian.PutUint64(b[38:], uint64(at))
	return b, nil
}

func DecodeMonitorSnapshotPage(b []byte) (MonitorSnapshotPage, error) {
	var r MonitorSnapshotPage
	if len(b) < 54 {
		return r, fmt.Errorf("short monitor snapshot")
	}
	var err error
	r.MonitorState, err = DecodeMonitorState(b[:28])
	if err != nil {
		return r, err
	}
	r.At = int64(binary.BigEndian.Uint64(b[28:]))
	r.Horizon = int64(binary.BigEndian.Uint64(b[36:]))
	r.Next = binary.BigEndian.Uint64(b[44:])
	count := int(binary.BigEndian.Uint16(b[52:]))
	if count > 16 || r.At <= 0 || r.Horizon <= 0 || r.At > math.MaxInt64-r.Horizon {
		return r, fmt.Errorf("invalid snapshot bounds")
	}
	offset := 54
	var previous uint64
	for range count {
		if len(b)-offset < 19 {
			return r, fmt.Errorf("short availability row")
		}
		id := binary.BigEndian.Uint64(b[offset:])
		n := int(binary.BigEndian.Uint16(b[offset+8:]))
		offset += 10
		if n == 0 || n > 4096 || len(b)-offset < n+9 || id <= previous {
			return r, fmt.Errorf("invalid availability identity")
		}
		identity := string(b[offset : offset+n])
		offset += n
		state := b[offset]
		until := int64(binary.BigEndian.Uint64(b[offset+1:]))
		offset += 9
		if !utf8.ValidString(identity) || state > 3 || until < r.At || until > r.At+r.Horizon || state == 2 && until != r.At {
			return r, fmt.Errorf("invalid availability state")
		}
		r.Instances = append(r.Instances, MonitorAvailability{id, identity, state, until})
		previous = id
	}
	if offset != len(b) || r.Next != 0 && (count != 16 || r.Next != previous) {
		return r, fmt.Errorf("invalid availability cursor")
	}
	return r, nil
}

type MonitorObservation struct {
	Identity  string
	Condition uint8 // 0 passing, 1 failing, 2 hysteresis band
	Value     float64
}

// ApplyMonitorRun describes one complete result, or a failed/incomplete query
// with no observations. Omitted known instances are absent only on success.
type ApplyMonitorRun struct {
	CorrelationID uint32
	MonitorID     uint64
	Revision      int64
	Sequence      uint64
	Failed        bool
	Observations  []MonitorObservation
}

func EncodeApplyMonitorRun(r ApplyMonitorRun) ([]byte, error) {
	if r.MonitorID == 0 || r.Revision <= 0 || r.Sequence == 0 || len(r.Observations) > MaxMonitorInstances || r.Failed && len(r.Observations) != 0 {
		return nil, fmt.Errorf("invalid monitor run")
	}
	size := 33
	seen := make(map[string]bool, len(r.Observations))
	for _, row := range r.Observations {
		if len(row.Identity) == 0 || len(row.Identity) > 4096 || seen[row.Identity] || row.Condition > 2 || math.IsNaN(row.Value) || math.IsInf(row.Value, 0) {
			return nil, fmt.Errorf("invalid or duplicate monitor observation")
		}
		seen[row.Identity] = true
		size += 11 + len(row.Identity)
	}
	if size > 131072 {
		return nil, fmt.Errorf("monitor run exceeds frame limit")
	}
	b := make([]byte, size)
	binary.BigEndian.PutUint16(b, C_ApplyMonitorRun)
	binary.BigEndian.PutUint32(b[2:], r.CorrelationID)
	binary.BigEndian.PutUint64(b[6:], r.MonitorID)
	binary.BigEndian.PutUint64(b[14:], uint64(r.Revision))
	binary.BigEndian.PutUint64(b[22:], r.Sequence)
	if r.Failed {
		b[30] = 1
	}
	binary.BigEndian.PutUint16(b[31:], uint16(len(r.Observations)))
	offset := 33
	for _, row := range r.Observations {
		binary.BigEndian.PutUint16(b[offset:], uint16(len(row.Identity)))
		offset += 2
		copy(b[offset:], row.Identity)
		offset += len(row.Identity)
		b[offset] = row.Condition
		offset++
		binary.BigEndian.PutUint64(b[offset:], math.Float64bits(row.Value))
		offset += 8
	}
	return b, nil
}

type MonitorRunApplied struct {
	CorrelationID       uint32
	MonitorID, Sequence uint64
	Replayed            bool
}

// DecodeMonitorRunApplied accepts the response body without its opcode.
func DecodeMonitorRunApplied(b []byte) (MonitorRunApplied, error) {
	if len(b) != 21 || b[20] > 1 {
		return MonitorRunApplied{}, fmt.Errorf("invalid monitor run receipt")
	}
	return MonitorRunApplied{binary.BigEndian.Uint32(b), binary.BigEndian.Uint64(b[4:]), binary.BigEndian.Uint64(b[12:]), b[20] == 1}, nil
}

type MonitorInstanceAction uint8

const (
	PauseMonitorInstance MonitorInstanceAction = iota
	ResumeMonitorInstance
	RetireMonitorInstance
)

type ControlMonitorInstance struct {
	CorrelationID uint32
	MonitorID     uint64
	Revision      int64
	InstanceID    uint64
	Action        MonitorInstanceAction
}

func EncodeControlMonitorInstance(r ControlMonitorInstance) ([]byte, error) {
	if r.MonitorID == 0 || r.Revision <= 0 || r.InstanceID == 0 || r.Action > RetireMonitorInstance {
		return nil, fmt.Errorf("invalid monitor instance action")
	}
	b := make([]byte, 31)
	binary.BigEndian.PutUint16(b, C_ControlMonitorInstance)
	binary.BigEndian.PutUint32(b[2:], r.CorrelationID)
	binary.BigEndian.PutUint64(b[6:], r.MonitorID)
	binary.BigEndian.PutUint64(b[14:], uint64(r.Revision))
	binary.BigEndian.PutUint64(b[22:], r.InstanceID)
	b[30] = byte(r.Action)
	return b, nil
}

type MonitorInstanceControlled struct {
	CorrelationID         uint32
	MonitorID, InstanceID uint64
	Revision              int64
	Replayed              bool
}

// DecodeMonitorInstanceControlled accepts the body without its opcode.
func DecodeMonitorInstanceControlled(b []byte) (MonitorInstanceControlled, error) {
	if len(b) != 29 || b[28] > 1 {
		return MonitorInstanceControlled{}, fmt.Errorf("invalid monitor instance receipt")
	}
	r := MonitorInstanceControlled{binary.BigEndian.Uint32(b), binary.BigEndian.Uint64(b[4:]), binary.BigEndian.Uint64(b[12:]), int64(binary.BigEndian.Uint64(b[20:])), b[28] == 1}
	if r.MonitorID == 0 || r.InstanceID == 0 || r.Revision <= 0 {
		return MonitorInstanceControlled{}, fmt.Errorf("invalid monitor instance receipt")
	}
	return r, nil
}

type IncidentAction uint8

const (
	AcknowledgeIncident IncidentAction = iota
	AssignIncident
)

type ActOnIncident struct {
	CorrelationID uint32
	IncidentID    uint64
	Revision      int64
	Action        IncidentAction
	Assignee      string // Empty clears assignment; acknowledgment requires empty.
}

func EncodeActOnIncident(r ActOnIncident) ([]byte, error) {
	if r.IncidentID == 0 || r.Revision <= 0 || r.Action > AssignIncident || len(r.Assignee) > MaxAssigneeLength || !utf8.ValidString(r.Assignee) || r.Action == AcknowledgeIncident && r.Assignee != "" {
		return nil, fmt.Errorf("invalid incident action")
	}
	b := make([]byte, 25+len(r.Assignee))
	binary.BigEndian.PutUint16(b, C_ActOnIncident)
	binary.BigEndian.PutUint32(b[2:], r.CorrelationID)
	binary.BigEndian.PutUint64(b[6:], r.IncidentID)
	binary.BigEndian.PutUint64(b[14:], uint64(r.Revision))
	b[22] = byte(r.Action)
	binary.BigEndian.PutUint16(b[23:], uint16(len(r.Assignee)))
	copy(b[25:], r.Assignee)
	return b, nil
}

type IncidentActionApplied struct {
	CorrelationID uint32
	IncidentID    uint64
	Revision      int64
	Replayed      bool
}

// DecodeIncidentActionApplied accepts the body without its opcode.
func DecodeIncidentActionApplied(b []byte) (IncidentActionApplied, error) {
	if len(b) != 21 || b[20] > 1 {
		return IncidentActionApplied{}, fmt.Errorf("invalid incident action receipt")
	}
	r := IncidentActionApplied{binary.BigEndian.Uint32(b), binary.BigEndian.Uint64(b[4:]), int64(binary.BigEndian.Uint64(b[12:])), b[20] == 1}
	if r.IncidentID == 0 || r.Revision <= 0 {
		return IncidentActionApplied{}, fmt.Errorf("invalid incident action receipt")
	}
	return r, nil
}

// MonitorDelivery uses stream 1 for a versioned webhook route. Other streams are rejected.
// Actions: peek=0, claim=1, delivered=2, retry=3, fail=4, discard-dead=5, routes=6, resync-page=7.
// For routes, Route is an exclusive cursor; empty starts a new scan.
// For resync-page, ID is the exclusive incident cursor and Generation is SyncVersion.
type MonitorDelivery struct {
	CorrelationID  uint32
	MonitorID      uint64
	Stream, Action uint8
	ID             uint64
	Generation     int64
	Route          string
}

func EncodeMonitorDelivery(r MonitorDelivery) ([]byte, error) {
	validRoute := len(r.Route) > 0 && len(r.Route) <= 64
	for _, c := range r.Route {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			validRoute = false
		}
	}
	if r.Action == 7 {
		if r.MonitorID == 0 || r.Stream != 1 || r.Generation <= 0 || !validRoute {
			return nil, fmt.Errorf("invalid resync page")
		}
	} else if r.Action == 6 {
		if r.MonitorID == 0 || r.Stream != 1 || r.ID != 0 || r.Generation != 0 || r.Route != "" && !validRoute {
			return nil, fmt.Errorf("invalid monitor route discovery")
		}
	} else if r.MonitorID == 0 || r.Stream != 1 || r.Action > 5 || r.Generation < 0 || !validRoute ||
		r.Action < 2 && (r.ID != 0 || r.Generation != 0) || r.Action >= 2 && (r.ID == 0 || r.Generation == 0) {
		return nil, fmt.Errorf("invalid monitor delivery action")
	}
	b := make([]byte, 33+len(r.Route))
	binary.BigEndian.PutUint16(b, C_MonitorDelivery)
	binary.BigEndian.PutUint32(b[2:], r.CorrelationID)
	binary.BigEndian.PutUint64(b[6:], r.MonitorID)
	b[14], b[15] = r.Stream, r.Action
	binary.BigEndian.PutUint64(b[16:], r.ID)
	binary.BigEndian.PutUint64(b[24:], uint64(r.Generation))
	b[32] = byte(len(r.Route))
	copy(b[33:], r.Route)
	return b, nil
}

type MonitorDeliveryResult struct {
	CorrelationID uint32   `json:"-"`
	Version       int      `json:"version"`
	State         uint8    `json:"state"` // empty=0, waiting=1, leased=2, dead=3, settled=4, routes=5
	ID            string   `json:"id"`
	Generation    string   `json:"generation"`
	CreatedAt     string   `json:"created_at"`
	AvailableAt   string   `json:"available_at"`
	LeaseUntil    string   `json:"lease_until"`
	Attempts      int64    `json:"attempts"`
	Payload       string   `json:"payload"`
	Routes        []string `json:"routes"`
	NextRoute     string   `json:"next_route"`
	IncidentIDs   []string `json:"incident_ids"`
	NextID        string   `json:"next_id"`
	SyncVersion   string   `json:"sync_version"`
	Lost          string   `json:"lost"`
	LossFirstAt   string   `json:"loss_first_at"`
	LossLastAt    string   `json:"loss_last_at"`
}

// DecodeMonitorDeliveryResult accepts the response body without its opcode.
func DecodeMonitorDeliveryResult(b []byte) (r MonitorDeliveryResult, err error) {
	if len(b) < 6 || len(b) > MaxProtocolPayloadSize-2 {
		return r, fmt.Errorf("invalid monitor delivery response")
	}
	if err = json.Unmarshal(b[4:], &r); err != nil {
		return r, err
	}
	r.CorrelationID = binary.BigEndian.Uint32(b)
	if r.Version != 1 || r.State > 7 || r.Attempts < 0 || len(r.Routes) > 32 || len(r.IncidentIDs) > 32 {
		return r, fmt.Errorf("invalid delivery state")
	}
	id, e := strconv.ParseUint(r.ID, 10, 64)
	if e != nil || r.State != 0 && r.State != 5 && id == 0 {
		return r, fmt.Errorf("invalid delivery ID")
	}
	for _, value := range []string{r.Generation, r.CreatedAt, r.AvailableAt, r.LeaseUntil} {
		if n, e := strconv.ParseInt(value, 10, 64); e != nil || n < 0 {
			return r, fmt.Errorf("invalid delivery timestamp or generation")
		}
	}
	return r, nil
}
