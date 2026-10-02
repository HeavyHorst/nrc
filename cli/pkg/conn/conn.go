package conn

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/heavyhorst/nrc/cli/pkg/client"
	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const DefaultTimeout = 10 * time.Second

const (
	dmConvFlag               uint64 = 0x8000_0000_0000_0000
	maxRoomMappingNameLength        = 32
)

// Room name to ID mapping
var RoomMap = map[string]int64{
	"engineering": protocol.EngineeringRoomID,
	"operations":  protocol.OperationsRoomID,
	"system":      protocol.SystemRoomID,
}

// Room ID to name mapping
var RoomNames = map[int64]string{
	protocol.EngineeringRoomID: "ENGINEERING",
	protocol.OperationsRoomID:  "OPERATIONS",
	protocol.SystemRoomID:      "SYSTEM",
}

// ResolveRoom converts a room name or numeric string to a room ID.
// Only handles built-in names and numeric IDs. For dynamic rooms, use
// ResolveRoomDynamic which computes the ID via the same xxhash as the server.
func ResolveRoom(roomStr string) (int64, error) {
	roomStr = strings.ToLower(strings.TrimSpace(roomStr))
	if id, ok := RoomMap[roomStr]; ok {
		return id, nil
	}
	id, err := strconv.ParseInt(roomStr, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid room: '%s' (use room name like 'engineering' or numeric ID)", roomStr)
	}
	return id, nil
}

// GetRoomName returns the display name for a room ID
func GetRoomName(roomID int64) string {
	if roomID == protocol.WorkspaceDataConvID {
		return "WORKSPACE"
	}
	if name, ok := RoomNames[roomID]; ok {
		return name
	}
	return fmt.Sprintf("ROOM_%d", roomID)
}

// normalizeRoomName mimics the server's normalize_room_mapping_name.
// Uppercases a-z, strips leading '#', trims whitespace, validates chars,
// and caps at MAX_ROOM_MAPPING_NAME_LENGTH (32).
func normalizeRoomName(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if len(raw) > 0 && raw[0] == '#' {
		raw = raw[1:]
		raw = strings.TrimSpace(raw)
	}
	if len(raw) == 0 {
		return "", false
	}

	var buf [maxRoomMappingNameLength]byte
	count := 0
	for i := 0; i < len(raw) && count < maxRoomMappingNameLength; i++ {
		b := raw[i]
		if b >= 'a' && b <= 'z' {
			b -= 'a' - 'A'
		}
		if !((b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b == '-') {
			return "", false
		}
		buf[count] = b
		count++
	}
	if count == 0 {
		return "", false
	}
	return string(buf[:count]), true
}

// isReservedRoomID mirrors the server's is_reserved_room_id.
// Reserved ids: 0, built-in rooms (2, 3, 7), and any DM conversation.
func isReservedRoomID(convID uint64) bool {
	return convID == 0 ||
		convID == uint64(protocol.EngineeringRoomID) ||
		convID == uint64(protocol.OperationsRoomID) ||
		convID == uint64(protocol.SystemRoomID) ||
		(convID&dmConvFlag) != 0
}

// makeRoomMappingConvID computes the deterministic conversation ID for a
// dynamic room, mirroring the server's make_room_mapping_conv_id.
// Key = workspace_id + \x00 + normalized_name, hashed with XXH64, with
// the DM_CONV_FLAG masked off and collision avoidance for reserved IDs.
func makeRoomMappingConvID(workspaceID, normalizedName string) int64 {
	key := workspaceID + "\x00" + normalizedName
	if len(key) > 256 {
		key = key[:256]
	}
	h := xxhash.Sum64String(key) & ^dmConvFlag
	for isReservedRoomID(h) {
		h = (h + 1) & ^dmConvFlag
	}
	return int64(h)
}

// ResolveRoomDynamic resolves a room name to a numeric ID using the same
// deterministic xxhash the server uses, without any network round-trip.
func ResolveRoomDynamic(workspaceID, roomName string) (int64, error) {
	normalized, ok := normalizeRoomName(roomName)
	if !ok {
		return 0, fmt.Errorf("invalid room name: '%s'", roomName)
	}
	return makeRoomMappingConvID(workspaceID, normalized), nil
}

// ListRooms returns a formatted string of available rooms
func ListRooms() string {
	var rooms []string
	for name, id := range RoomMap {
		rooms = append(rooms, fmt.Sprintf("  %-15s %d", name, id))
	}
	return strings.Join(rooms, "\n")
}

// Session holds a connected client + resolved config for a single command invocation.
type Session struct {
	Client *client.Client
	Config *config.Config
	RoomID int64 // WorkspaceDataConvID for Dial; chat conversation for DialChat.
	cancel context.CancelFunc
}

type ServerError struct{ Message string }

func (e *ServerError) Error() string { return "server error: " + e.Message }

type ConnectionError struct{ Err error }

func (e *ConnectionError) Error() string { return e.Err.Error() }
func (e *ConnectionError) Unwrap() error { return e.Err }

type InvalidArgumentError struct{ Err error }

func (e *InvalidArgumentError) Error() string { return e.Err.Error() }
func (e *InvalidArgumentError) Unwrap() error { return e.Err }

type CommandError struct{ Err error }

func (e *CommandError) Error() string { return e.Err.Error() }
func (e *CommandError) Unwrap() error { return e.Err }

// resolveRoomFlag resolves a --room flag value to a numeric ID.
// Tries built-in names and numeric IDs first (offline), then falls back to
// local deterministic hash for dynamic room names.
func ResolveRoomFlag(workspaceID, roomFlag string) (int64, error) {
	id, err := ResolveRoom(roomFlag)
	if err == nil {
		return id, nil
	}
	id, err = ResolveRoomDynamic(workspaceID, roomFlag)
	if err != nil {
		return id, fmt.Errorf("invalid room: '%s' (use room name like 'engineering' or numeric ID)", roomFlag)
	}
	return id, nil
}

// Dial connects to workspace-wide durable data. The legacy room argument must
// be empty: silently redirecting a private conversation could publish its data.
// Caller MUST defer s.Close().
func Dial(roomFlag string) (*Session, error) {
	if roomFlag != "" {
		return nil, &InvalidArgumentError{Err: fmt.Errorf("--room is only supported for chat; durable data is workspace-wide")}
	}
	s, err := DialChat("")
	if err == nil {
		s.RoomID = protocol.WorkspaceDataConvID
	}
	return s, err
}

// DialChat connects using the configured chat room or an explicit override.
func DialChat(roomFlag string) (*Session, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, &CommandError{Err: fmt.Errorf("loading config: %w", err)}
	}

	roomID := cfg.RoomID
	if roomFlag != "" {
		id, err := ResolveRoomFlag(cfg.WorkspaceID, roomFlag)
		if err != nil {
			return nil, &InvalidArgumentError{Err: err}
		}
		roomID = id
	}

	c := client.New(cfg.Server, cfg.WorkspaceID)
	ctx, cancel := context.WithTimeout(context.Background(), DefaultTimeout)

	if err := c.Connect(ctx); err != nil {
		cancel()
		return nil, &ConnectionError{Err: fmt.Errorf("connecting: %w", err)}
	}

	return &Session{
		Client: c,
		Config: cfg,
		RoomID: roomID,
		cancel: cancel,
	}, nil
}

// DialLongRunning is like DialChat but without a timeout (for chat watch).
func DialLongRunning(roomFlag string) (*Session, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, &CommandError{Err: fmt.Errorf("loading config: %w", err)}
	}

	roomID := cfg.RoomID
	if roomFlag != "" {
		id, err := ResolveRoomFlag(cfg.WorkspaceID, roomFlag)
		if err != nil {
			return nil, &InvalidArgumentError{Err: err}
		}
		roomID = id
	}

	c := client.New(cfg.Server, cfg.WorkspaceID)
	ctx, cancel := context.WithCancel(context.Background())

	if err := c.Connect(ctx); err != nil {
		cancel()
		return nil, &ConnectionError{Err: fmt.Errorf("connecting: %w", err)}
	}

	return &Session{
		Client: c,
		Config: cfg,
		RoomID: roomID,
		cancel: cancel,
	}, nil
}

// Close closes the session.
func (s *Session) Close() {
	s.Client.Close()
	s.cancel()
}

// DecodeServerError decodes an S_ErrorResponse payload into a printable error.
func DecodeServerError(data []byte) error {
	resp, err := protocol.DecodeErrorResponse(data)
	if err != nil {
		return fmt.Errorf("decoding server error response: %w", err)
	}
	return &ServerError{Message: resp.ErrorMessage}
}

// SendAndRecv sends a message and waits for the response, skipping S_ServerReady.
// Returns an error if the response is S_ErrorResponse or connection closes.
func (s *Session) SendAndRecv(msg *protocol.Message) (*protocol.Message, error) {
	if err := s.Client.Send(msg); err != nil {
		return nil, &ConnectionError{Err: fmt.Errorf("sending: %w", err)}
	}

	resp, ok := s.Client.RecvSkipServerReady(0)
	if !ok {
		return nil, &ConnectionError{Err: fmt.Errorf("connection closed")}
	}

	if resp.Opcode == protocol.S_ErrorResponse {
		return nil, DecodeServerError(resp.Data)
	}

	return resp, nil
}

// Fatal prints an error and exits.
func Fatal(format string, args ...interface{}) {
	for _, arg := range args {
		if err, ok := arg.(error); ok {
			classification := Classify(err)
			if classification.Code != "unexpected_response" {
				output.Error(classification.Code, fmt.Sprintf(format, args...), classification.Retryable)
			}
		}
	}
	message := fmt.Sprintf(format, args...)
	for _, prefix := range []string{"Invalid ", "Both ", "Use ", "Unknown ", "Missing ", "Cannot ", "Must ", "Too many ", "Refusing ", "Asset "} {
		if strings.HasPrefix(message, prefix) {
			output.Error("invalid_argument", message, false)
		}
	}
	FatalUnexpected("%s", message)
}

func FatalInvalid(format string, args ...any) {
	output.Error("invalid_argument", fmt.Sprintf(format, args...), false)
}
func FatalNotFound(format string, args ...any) {
	output.Error("not_found", fmt.Sprintf(format, args...), false)
}
func FatalConnection(format string, args ...any) {
	output.Error("connection_failed", fmt.Sprintf(format, args...), true)
}
func FatalServer(format string, args ...any) {
	output.Error("server_error", fmt.Sprintf(format, args...), false)
}
func FatalUnexpected(format string, args ...any) {
	output.Error("unexpected_response", fmt.Sprintf(format, args...), false)
}

// Classification is the stable machine error classification for an error.
type Classification struct {
	Code      string
	Retryable bool
}

func Classify(err error) Classification {
	var invalidErr *InvalidArgumentError
	if errors.As(err, &invalidErr) {
		return Classification{Code: "invalid_argument"}
	}
	var commandErr *CommandError
	if errors.As(err, &commandErr) {
		return Classification{Code: "command_failed"}
	}
	var serverErr *ServerError
	if errors.As(err, &serverErr) {
		return Classification{Code: "server_error"}
	}
	var connectionErr *ConnectionError
	var netErr net.Error
	if errors.As(err, &connectionErr) || errors.As(err, &netErr) || errors.Is(err, context.DeadlineExceeded) {
		return Classification{Code: "connection_failed", Retryable: true}
	}
	return Classification{Code: "unexpected_response"}
}

// Fail renders an error using its concrete server/connection classification.
func Fail(err error) {
	c := Classify(err)
	output.Error(c.Code, err.Error(), c.Retryable)
}
