package protocol

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strconv"
	"unicode/utf8"
)

const (
	ChronicleAccessRead      uint8 = 1
	ChronicleAccessService   uint8 = 2
	ChronicleAccessDelete    uint8 = 4
	ChronicleConsumerVersion       = "chronicle-v1"
)

// ChronicleRequest multiplexes the chronicle operations. IDs are decimal strings
// rather than JSON numbers, including values above JavaScript's safe integer range.
type ChronicleRequest struct {
	Op            string   `json:"op"`
	Consumer      string   `json:"consumer,omitempty"`
	NoteID        string   `json:"note_id,omitempty"`
	Cursor        string   `json:"cursor,omitempty"`
	Epoch         string   `json:"epoch,omitempty"`
	Generation    string   `json:"generation,omitempty"`
	Limit         uint16   `json:"limit,omitempty"`
	Sources       []string `json:"sources,omitempty"`
	Field         uint8    `json:"field,omitempty"`
	Offset        uint32   `json:"offset,omitempty"`
	Length        uint16   `json:"length,omitempty"`
	InputTokens   uint32   `json:"input_tokens,omitempty"`
	OutputTokens  uint32   `json:"output_tokens,omitempty"`
	Outcome       string   `json:"outcome,omitempty"`
	Summary       string   `json:"summary,omitempty"`
	Model         string   `json:"model,omitempty"`
	PromptVersion string   `json:"prompt_version,omitempty"`
	SchemaVersion string   `json:"schema_version,omitempty"`
	Reason        string   `json:"reason,omitempty"`
}

type ChronicleInput struct {
	SourceID      string  `json:"source_id"`
	NoteID        string  `json:"note_id"`
	CapturedAt    string  `json:"captured_at"`
	ExpiresAt     string  `json:"expires_at"`
	BeforeVersion string  `json:"before_version"`
	AfterVersion  string  `json:"after_version"`
	Operation     uint32  `json:"operation"`
	Attempts      uint32  `json:"attempts"`
	BeforePresent bool    `json:"before_present"`
	AfterPresent  bool    `json:"after_present"`
	BeforeHash    string  `json:"before_hash"`
	AfterHash     string  `json:"after_hash"`
	Lengths       []int64 `json:"lengths"`
	ActorID       string  `json:"actor_id"`
	ActorName     string  `json:"actor_name"`
}

type ChronicleEntry struct {
	Generation      string   `json:"generation"`
	NoteID          string   `json:"note_id"`
	NoteTitle       string   `json:"note_title"`
	CreatedAt       string   `json:"created_at"`
	FirstAt         string   `json:"first_at"`
	LastAt          string   `json:"last_at"`
	Sources         []string `json:"sources"`
	Summary         string   `json:"summary"`
	Model           string   `json:"model"`
	PromptVersion   string   `json:"prompt_version"`
	SchemaVersion   string   `json:"schema_version"`
	SourceAvailable bool     `json:"source_available"`
}

// ChronicleGap describes a range of inputs that could not produce AI results.
type ChronicleGap struct {
	FirstSource     string `json:"first_source"`
	LastSource      string `json:"last_source"`
	NoteID          string `json:"note_id"`
	NoteTitle       string `json:"note_title"`
	FirstAt         string `json:"first_at"`
	LastAt          string `json:"last_at"`
	Reason          string `json:"reason"`
	InputCount      uint64 `json:"input_count"`
	SourceAvailable bool   `json:"source_available"`
}

// ChronicleResponse retains exact IDs and counters. Chunk is base64 text, not
// decoded bytes. Status is intentionally open to future server status values.
type ChronicleResponse struct {
	CorrelationID  uint32           `json:"-"`
	Status         string           `json:"status"`
	Error          string           `json:"error"`
	Epoch          string           `json:"epoch"`
	Generation     string           `json:"generation"`
	LeaseUntil     string           `json:"lease_until"`
	NoteID         string           `json:"note_id"`
	Cursor         string           `json:"cursor"`
	Summary        string           `json:"summary"`
	Outcome        string           `json:"outcome"`
	DeletedThrough string           `json:"deleted_through"`
	Pending        uint64           `json:"pending"`
	Processing     uint64           `json:"processing"`
	Failed         uint64           `json:"failed"`
	Acknowledged   uint64           `json:"acknowledged"`
	GapCount       uint64           `json:"gap_count"`
	Expired        uint64           `json:"expired"`
	CanDelete      bool             `json:"can_delete"`
	RawBytes       uint64           `json:"raw_bytes"`
	Calls          uint64           `json:"calls"`
	InputTokens    uint64           `json:"input_tokens"`
	OutputTokens   uint64           `json:"output_tokens"`
	Enabled        bool             `json:"enabled"`
	More           bool             `json:"more"`
	Sources        []string         `json:"sources"`
	Inputs         []ChronicleInput `json:"inputs"`
	Entries        []ChronicleEntry `json:"entries"`
	Gaps           []ChronicleGap   `json:"gaps"`
	Chunk          string           `json:"chunk"`
}

func chronicleDecimal(s string) (uint64, bool) {
	if s == "" || len(s) > 20 || (len(s) > 1 && s[0] == '0') {
		return 0, false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseUint(s, 10, 64)
	return n, err == nil
}

func EncodeChronicleRequest(request ChronicleRequest, correlationID uint32) ([]byte, error) {
	switch request.Op {
	case "list", "claim", "chunk", "reserve", "commit", "retry", "status", "history", "gaps", "delete":
	default:
		return nil, fmt.Errorf("chronicle: unknown operation %q", request.Op)
	}
	for _, s := range []string{request.NoteID, request.Cursor, request.Epoch, request.Generation} {
		if s != "" {
			if _, ok := chronicleDecimal(s); !ok {
				return nil, fmt.Errorf("chronicle: noncanonical decimal ID")
			}
		}
	}
	for _, s := range []string{request.Consumer, request.Model, request.PromptVersion, request.SchemaVersion, request.Outcome, request.Reason} {
		if len(s) > 128 || !utf8.ValidString(s) {
			return nil, fmt.Errorf("chronicle: invalid string or string exceeds 128 bytes")
		}
	}
	if len(request.Summary) > 4096 || !utf8.ValidString(request.Summary) {
		return nil, fmt.Errorf("chronicle: invalid summary")
	}
	if len(request.Sources) > 32 {
		return nil, fmt.Errorf("chronicle: too many sources")
	}
	var previous uint64
	for _, s := range request.Sources {
		n, ok := chronicleDecimal(s)
		if !ok || n <= previous {
			return nil, fmt.Errorf("chronicle: sources must be nonzero and strictly increasing")
		}
		previous = n
	}
	data, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if len(data)+6 > MaxProtocolPayloadSize {
		return nil, fmt.Errorf("chronicle: frame too large")
	}
	frame := make([]byte, len(data)+6)
	binary.BigEndian.PutUint16(frame, C_Chronicle)
	copy(frame[2:], data)
	binary.BigEndian.PutUint32(frame[len(frame)-4:], correlationID)
	return frame, nil
}

// DecodeChronicleResponse expects the opcode to have already been removed.
func DecodeChronicleResponse(payload []byte) (*ChronicleResponse, error) {
	if len(payload) < 6 || len(payload)+2 > MaxProtocolPayloadSize {
		return nil, fmt.Errorf("chronicle: invalid response length")
	}
	data := bytes.TrimSpace(payload[4:])
	if len(data) < 2 || data[0] != '{' || !utf8.Valid(data) {
		return nil, fmt.Errorf("chronicle: response must be a UTF-8 JSON object")
	}
	var response ChronicleResponse
	if err := json.Unmarshal(data, &response); err != nil {
		return nil, err
	}
	response.CorrelationID = binary.BigEndian.Uint32(payload)
	return &response, nil
}
