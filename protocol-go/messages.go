package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// User represents an online user
type User struct {
	ID       string
	Nickname string
	Status   string
}

// ServerMetrics represents legacy server status info.
type ServerMetrics struct {
	ActiveConnections int32
	ServerTimestamp   int64
}

// ServerReady represents a decoded S_ServerReady payload.
type ServerReady struct {
	BuildVersion    string
	ProtocolVersion uint32
	CPUModel        string
	Username        string
	IsAuthenticated bool
}

const (
	StatsWALKindTask uint8 = iota
	StatsWALKindAsset
	StatsWALKindEdge
)

type StatsWALDetail struct {
	Kind               uint8
	Enabled            bool
	CompactionMode     uint8
	CompactionBGStatus uint8
	Generation         uint64
	SnapshotEnd        uint64
	CompactCount       uint64
	InstallCursor      uint64
	InstallLastBacklog uint64
	InstallBudgetUS    uint32
	FileSize           uint64
	PendingBytes       uint64
	RecordCount        uint64
	FsyncCount         uint64
	TotalFsyncNS       uint64
	WriteCount         uint64
	TotalWriteNS       uint64
}

// StatsShardSweep contains cumulative shard sweep counters from the optional
// version 1 StatsResponse extension.
type StatsShardSweep struct {
	RunsTotal                 uint64
	OrdinaryRunsTotal         uint64
	RawRunsTotal              uint64
	InputBytesTotal           uint64
	DirtyBytesTotal           uint64
	PrefixReadBytesTotal      uint64
	LatestReadBytesTotal      uint64
	MeasureReadBytesTotal     uint64
	CopyReadBytesTotal        uint64
	ReplayReadBytesTotal      uint64
	MetadataFallbacksTotal    uint64
	MetadataWrittenBytesTotal uint64
}

// StatsResponse represents a decoded S_StatsResponse payload.
type StatsResponse struct {
	Timestamp          int64
	ServerTimestamp    int64
	ThreadID           uint32
	TotalThreads       uint32
	Connections        uint32
	MemoryTotalMB      uint32
	BufferPoolPercent  uint32
	IOPending          uint32
	IORingDepth        uint32
	IORingAvailable    uint32
	IOSQOverflow       uint32
	IOTotalCompletions uint64
	IOTotalLatencyNS   uint64
	IOLatencyCount     uint64
	SendQueueDepth     uint32
	SendQueueLimit     uint32
	SendBackpressure   bool
	SendDropped        uint32
	WALFileSize        uint64
	WALPendingBytes    uint64
	WALRecordCount     uint64
	WALFsyncCount      uint64
	WALTotalFsyncNS    uint64
	WALTotalWriteNS    uint64
	WALWriteCount      uint64
	WALDetailsVersion  uint8
	WALDetails         []StatsWALDetail
	ShardSweepVersion  uint8
	ShardSweep         *StatsShardSweep
}

// PongResponse represents a decoded lightweight S_Pong payload.
type PongResponse struct {
	Timestamp       int64
	ServerTimestamp int64
}

// AckUnsubscribeConvs represents a decoded S_AckUnsubscribeConvs payload.
type AckUnsubscribeConvs struct {
	CorrelationID uint32
}

const statsPayloadBaseSize = 145
const statsWALDetailSize = 104
const statsShardSweepExtensionSize = 97
const pongPayloadSize = 16

// PresenceUser represents a user in a presence update
type PresenceUser struct {
	Username        string
	IsAuthenticated bool
}

// PresenceUpdate represents S_RoomPresenceUpdate data
type PresenceUpdate struct {
	ConvID      int64
	EventType   uint8
	Sequence    int64
	Username    string
	IsAuth      bool
	OldUsername string
	Users       []PresenceUser
}

// ChatMessage represents a decoded S_NewMessage
type ChatMessage struct {
	ConvID      int64
	Sequence    int64
	Username    string
	Timestamp   int64
	ContentType uint8
	Content     string
}

// AckSendMessage represents a decoded S_AckSendMessage.
type AckSendMessage struct {
	ClientReqID uint32
	AssignedSeq uint64
	Timestamp   int64
}

// ErrorResponse represents a decoded S_ErrorResponse.
// Format: origin_opcode(2) + error_len(2) + error + correlation_id(4)
type ErrorResponse struct {
	OriginOpcode  uint16
	ErrorMessage  string
	CorrelationID uint32
}

// EncodeChatMessage encodes a chat message for C_SendMessage.
// Format: roomID(8) + clientReqID(4) + contentType(1) + contentLength(2) + message
func EncodeChatMessage(roomID int64, message string, contentType byte) []byte {
	return EncodeSendMessage(roomID, 1, message, contentType)
}

// EncodeSendMessage encodes a C_SendMessage request payload.
// Format: roomID(8) + clientReqID(4) + contentType(1) + contentLength(2) + message
func EncodeSendMessage(roomID int64, clientReqID uint32, message string, contentType byte) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, roomID)
	binary.Write(buf, binary.BigEndian, clientReqID)
	buf.WriteByte(contentType)
	binary.Write(buf, binary.BigEndian, uint16(len(message)))
	buf.WriteString(message)
	return buf.Bytes()
}

// EncodeChatMessagePlainText encodes a plain text chat message.
func EncodeChatMessagePlainText(roomID int64, message string) []byte {
	return EncodeChatMessage(roomID, message, byte(ContentTypePlainText))
}

// EncodeStats encodes a C_Stats request payload.
// Format: timestamp(8)
func EncodeStats(timestamp int64) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, timestamp)
	return buf.Bytes()
}

// EncodePing encodes a lightweight C_Ping request payload.
// Format: timestamp(8)
func EncodePing(timestamp int64) []byte {
	return EncodeStats(timestamp)
}

// ParseServerReady decodes S_ServerReady from a full wire message.
// Wire format: opcode(2) + build_version_len(2) + build_version + protocol_version(4) + cpu_model_len(2) + cpu_model + [username_len(2) + username + is_authenticated(1)]
func ParseServerReady(data []byte) (*ServerReady, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("server ready message too short: need at least 2 bytes for opcode, got %d", len(data))
	}

	payload := data[2:] // Skip opcode
	offset := 0

	if len(payload) < offset+2 {
		return nil, fmt.Errorf("server ready payload missing build version length")
	}
	buildLen := int(binary.BigEndian.Uint16(payload[offset:]))
	offset += 2

	if len(payload) < offset+buildLen {
		return nil, fmt.Errorf("server ready payload truncated in build version: payload=%d build_len=%d", len(payload), buildLen)
	}
	buildVersion := string(payload[offset : offset+buildLen])
	offset += buildLen

	if len(payload) < offset+4 {
		return nil, fmt.Errorf("server ready payload missing protocol version")
	}
	protocolVersion := binary.BigEndian.Uint32(payload[offset:])
	offset += 4

	if len(payload) < offset+2 {
		return nil, fmt.Errorf("server ready payload missing CPU model length")
	}
	cpuLen := int(binary.BigEndian.Uint16(payload[offset:]))
	offset += 2

	if len(payload) < offset+cpuLen {
		return nil, fmt.Errorf("server ready payload truncated in CPU model: payload=%d cpu_len=%d", len(payload), cpuLen)
	}
	cpuModel := string(payload[offset : offset+cpuLen])
	offset += cpuLen

	result := &ServerReady{
		BuildVersion:    buildVersion,
		ProtocolVersion: protocolVersion,
		CPUModel:        cpuModel,
	}

	if len(payload) == offset {
		return result, nil
	}

	if len(payload) < offset+2 {
		return nil, fmt.Errorf("server ready payload missing username length")
	}
	usernameLen := int(binary.BigEndian.Uint16(payload[offset:]))
	offset += 2

	if len(payload) < offset+usernameLen+1 {
		return nil, fmt.Errorf("server ready payload truncated in username/auth fields: payload=%d username_len=%d", len(payload), usernameLen)
	}
	result.Username = string(payload[offset : offset+usernameLen])
	offset += usernameLen

	result.IsAuthenticated = payload[offset] == 1
	offset++

	if len(payload) != offset {
		return nil, fmt.Errorf("unexpected trailing bytes in server ready payload: %d", len(payload)-offset)
	}

	return result, nil
}

// DecodeChatMessage decodes S_NewMessage.
func DecodeChatMessage(data []byte) (*ChatMessage, error) {
	buf := bytes.NewReader(data)
	msg := &ChatMessage{}

	if err := binary.Read(buf, binary.BigEndian, &msg.ConvID); err != nil {
		return nil, fmt.Errorf("failed to read conv_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &msg.Sequence); err != nil {
		return nil, fmt.Errorf("failed to read seq: %w", err)
	}
	username, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read username: %w", err)
	}
	msg.Username = username

	if err := binary.Read(buf, binary.BigEndian, &msg.Timestamp); err != nil {
		return nil, fmt.Errorf("failed to read timestamp: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &msg.ContentType); err != nil {
		return nil, fmt.Errorf("failed to read content type: %w", err)
	}
	content, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read content: %w", err)
	}
	msg.Content = content

	return msg, nil
}

// DecodeAckSendMessage decodes S_AckSendMessage.
// Format: clientReqID(4) + assignedSeq(8) + timestamp(8)
func DecodeAckSendMessage(data []byte) (*AckSendMessage, error) {
	if len(data) != 20 {
		return nil, fmt.Errorf("ack data must be exactly 20 bytes, got %d", len(data))
	}

	buf := bytes.NewReader(data)
	ack := &AckSendMessage{}

	if err := binary.Read(buf, binary.BigEndian, &ack.ClientReqID); err != nil {
		return nil, fmt.Errorf("failed to read client_req_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &ack.AssignedSeq); err != nil {
		return nil, fmt.Errorf("failed to read assigned_seq: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &ack.Timestamp); err != nil {
		return nil, fmt.Errorf("failed to read timestamp: %w", err)
	}

	return ack, nil
}

// DecodeErrorResponse decodes S_ErrorResponse.
// Format: origin_opcode(2) + error_len(2) + error + correlation_id(4)
func DecodeErrorResponse(data []byte) (*ErrorResponse, error) {
	if len(data) < 4 {
		return nil, fmt.Errorf("error response too short: need at least 4 bytes, got %d", len(data))
	}

	originOpcode := binary.BigEndian.Uint16(data[0:2])
	errorLen := int(binary.BigEndian.Uint16(data[2:4]))
	if len(data) < 4+errorLen {
		return nil, fmt.Errorf("error response content length mismatch: header=%d bytes payload=%d", errorLen, len(data)-4)
	}

	errorMessage := string(data[4 : 4+errorLen])
	offset := 4 + errorLen

	if len(data) < offset+4 {
		return nil, fmt.Errorf("error response missing correlation_id")
	}
	correlationID := binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if len(data) != offset {
		return nil, fmt.Errorf("unexpected trailing bytes in error response: %d", len(data)-offset)
	}

	return &ErrorResponse{
		OriginOpcode:  originOpcode,
		ErrorMessage:  errorMessage,
		CorrelationID: correlationID,
	}, nil
}

// EncodeSubscribeConvs encodes a C_SubscribeConvs request. Format: count(2) + [room_id(8) ...]
func EncodeSubscribeConvs(roomIDs ...int64) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(len(roomIDs)))
	for _, roomID := range roomIDs {
		binary.Write(buf, binary.BigEndian, roomID)
	}
	return buf.Bytes()
}

// EncodeUnsubscribeConvs encodes a C_UnsubscribeConvs request. Format: count(2) + [room_id(8) ...]
func EncodeUnsubscribeConvs(roomIDs ...int64) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(len(roomIDs)))
	for _, roomID := range roomIDs {
		binary.Write(buf, binary.BigEndian, roomID)
	}
	return buf.Bytes()
}

// EncodeUnsubscribeConvsWithCorrelation encodes the new request shape with a trailing correlation ID.
func EncodeUnsubscribeConvsWithCorrelation(correlationID uint32, roomIDs ...int64) []byte {
	buf := bytes.NewBuffer(EncodeUnsubscribeConvs(roomIDs...))
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// DecodeAckUnsubscribeConvs decodes the correlation-only S_AckUnsubscribeConvs payload.
func DecodeAckUnsubscribeConvs(data []byte) (*AckUnsubscribeConvs, error) {
	if len(data) != 4 {
		return nil, fmt.Errorf("invalid AckUnsubscribeConvs payload length: got %d, want 4", len(data))
	}
	return &AckUnsubscribeConvs{CorrelationID: binary.BigEndian.Uint32(data)}, nil
}

// DecodeStats decodes S_StatsResponse into legacy status metrics.
// ActiveConnections is sourced from stats.connections.
// ServerTimestamp is sourced from stats.server_timestamp in Unix nanoseconds.
func DecodeStats(data []byte) (*ServerMetrics, error) {
	stats, err := DecodeStatsResponse(data)
	if err != nil {
		return nil, err
	}

	return &ServerMetrics{
		ActiveConnections: int32(stats.Connections),
		ServerTimestamp:   stats.ServerTimestamp,
	}, nil
}

// DecodeStatsResponse decodes the full S_StatsResponse payload.
func DecodeStatsResponse(data []byte) (*StatsResponse, error) {
	if len(data) < statsPayloadBaseSize {
		return nil, fmt.Errorf("stats data too short: need %d bytes, got %d", statsPayloadBaseSize, len(data))
	}

	buf := bytes.NewReader(data)
	stats := &StatsResponse{}

	if err := binary.Read(buf, binary.BigEndian, &stats.Timestamp); err != nil {
		return nil, fmt.Errorf("failed to read timestamp: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.ServerTimestamp); err != nil {
		return nil, fmt.Errorf("failed to read server_timestamp: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.ThreadID); err != nil {
		return nil, fmt.Errorf("failed to read thread_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.TotalThreads); err != nil {
		return nil, fmt.Errorf("failed to read total_threads: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.Connections); err != nil {
		return nil, fmt.Errorf("failed to read connections: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.MemoryTotalMB); err != nil {
		return nil, fmt.Errorf("failed to read memory_total_mb: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.BufferPoolPercent); err != nil {
		return nil, fmt.Errorf("failed to read buffer_pool_percent: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.IOPending); err != nil {
		return nil, fmt.Errorf("failed to read io_pending: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.IORingDepth); err != nil {
		return nil, fmt.Errorf("failed to read io_ring_depth: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.IORingAvailable); err != nil {
		return nil, fmt.Errorf("failed to read io_ring_available: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.IOSQOverflow); err != nil {
		return nil, fmt.Errorf("failed to read io_sq_overflow: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.IOTotalCompletions); err != nil {
		return nil, fmt.Errorf("failed to read io_total_completions: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.IOTotalLatencyNS); err != nil {
		return nil, fmt.Errorf("failed to read io_total_latency_ns: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.IOLatencyCount); err != nil {
		return nil, fmt.Errorf("failed to read io_latency_count: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.SendQueueDepth); err != nil {
		return nil, fmt.Errorf("failed to read send_queue_depth: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.SendQueueLimit); err != nil {
		return nil, fmt.Errorf("failed to read send_queue_limit: %w", err)
	}
	var sendBackpressure uint8
	if err := binary.Read(buf, binary.BigEndian, &sendBackpressure); err != nil {
		return nil, fmt.Errorf("failed to read send_backpressure: %w", err)
	}
	stats.SendBackpressure = sendBackpressure == 1
	if err := binary.Read(buf, binary.BigEndian, &stats.SendDropped); err != nil {
		return nil, fmt.Errorf("failed to read send_dropped: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.WALFileSize); err != nil {
		return nil, fmt.Errorf("failed to read wal_file_size: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.WALPendingBytes); err != nil {
		return nil, fmt.Errorf("failed to read wal_pending_bytes: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.WALRecordCount); err != nil {
		return nil, fmt.Errorf("failed to read wal_record_count: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.WALFsyncCount); err != nil {
		return nil, fmt.Errorf("failed to read wal_fsync_count: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.WALTotalFsyncNS); err != nil {
		return nil, fmt.Errorf("failed to read wal_total_fsync_ns: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.WALTotalWriteNS); err != nil {
		return nil, fmt.Errorf("failed to read wal_total_write_ns: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.WALWriteCount); err != nil {
		return nil, fmt.Errorf("failed to read wal_write_count: %w", err)
	}

	if buf.Len() == 0 {
		return stats, nil
	}

	if buf.Len() < 2 {
		return nil, fmt.Errorf("stats wal details header too short: need 2 bytes, got %d", buf.Len())
	}

	if err := binary.Read(buf, binary.BigEndian, &stats.WALDetailsVersion); err != nil {
		return nil, fmt.Errorf("failed to read wal_details_version: %w", err)
	}

	var walDetailsCount uint8
	if err := binary.Read(buf, binary.BigEndian, &walDetailsCount); err != nil {
		return nil, fmt.Errorf("failed to read wal_details_count: %w", err)
	}

	expectedBytes := int(walDetailsCount) * statsWALDetailSize
	if buf.Len() < expectedBytes {
		return nil, fmt.Errorf("stats wal details truncated: need %d bytes, got %d", expectedBytes, buf.Len())
	}

	stats.WALDetails = make([]StatsWALDetail, 0, int(walDetailsCount))
	for i := 0; i < int(walDetailsCount); i++ {
		detail := StatsWALDetail{}

		if err := binary.Read(buf, binary.BigEndian, &detail.Kind); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].kind: %w", i, err)
		}

		var enabled uint8
		if err := binary.Read(buf, binary.BigEndian, &enabled); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].enabled: %w", i, err)
		}
		detail.Enabled = enabled == 1

		if err := binary.Read(buf, binary.BigEndian, &detail.CompactionMode); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].compaction_mode: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.CompactionBGStatus); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].compaction_bg_status: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.Generation); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].generation: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.SnapshotEnd); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].snapshot_end: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.CompactCount); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].compact_count: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.InstallCursor); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].install_cursor: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.InstallLastBacklog); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].install_last_backlog: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.InstallBudgetUS); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].install_budget_us: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.FileSize); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].file_size: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.PendingBytes); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].pending_bytes: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.RecordCount); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].record_count: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.FsyncCount); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].fsync_count: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.TotalFsyncNS); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].total_fsync_ns: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.WriteCount); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].write_count: %w", i, err)
		}
		if err := binary.Read(buf, binary.BigEndian, &detail.TotalWriteNS); err != nil {
			return nil, fmt.Errorf("failed to read wal_detail[%d].total_write_ns: %w", i, err)
		}

		stats.WALDetails = append(stats.WALDetails, detail)
	}

	if buf.Len() == 0 {
		return stats, nil
	}
	if buf.Len() < statsShardSweepExtensionSize {
		return nil, fmt.Errorf("stats shard sweep extension truncated: need %d bytes, got %d", statsShardSweepExtensionSize, buf.Len())
	}
	if buf.Len() > statsShardSweepExtensionSize {
		return nil, fmt.Errorf("unexpected trailing bytes after stats shard sweep extension: %d", buf.Len()-statsShardSweepExtensionSize)
	}
	if err := binary.Read(buf, binary.BigEndian, &stats.ShardSweepVersion); err != nil {
		return nil, fmt.Errorf("failed to read shard_sweep_version: %w", err)
	}
	if stats.ShardSweepVersion != 1 {
		return nil, fmt.Errorf("unsupported stats shard sweep extension version %d", stats.ShardSweepVersion)
	}
	stats.ShardSweep = &StatsShardSweep{}
	fields := []struct {
		name  string
		value *uint64
	}{
		{"runs_total", &stats.ShardSweep.RunsTotal},
		{"ordinary_runs_total", &stats.ShardSweep.OrdinaryRunsTotal},
		{"raw_runs_total", &stats.ShardSweep.RawRunsTotal},
		{"input_bytes_total", &stats.ShardSweep.InputBytesTotal},
		{"dirty_bytes_total", &stats.ShardSweep.DirtyBytesTotal},
		{"prefix_read_bytes_total", &stats.ShardSweep.PrefixReadBytesTotal},
		{"latest_read_bytes_total", &stats.ShardSweep.LatestReadBytesTotal},
		{"measure_read_bytes_total", &stats.ShardSweep.MeasureReadBytesTotal},
		{"copy_read_bytes_total", &stats.ShardSweep.CopyReadBytesTotal},
		{"replay_read_bytes_total", &stats.ShardSweep.ReplayReadBytesTotal},
		{"metadata_fallbacks_total", &stats.ShardSweep.MetadataFallbacksTotal},
		{"metadata_written_bytes_total", &stats.ShardSweep.MetadataWrittenBytesTotal},
	}
	for _, field := range fields {
		if err := binary.Read(buf, binary.BigEndian, field.value); err != nil {
			return nil, fmt.Errorf("failed to read shard_sweep_%s: %w", field.name, err)
		}
	}

	return stats, nil
}

// DecodePongResponse decodes the lightweight S_Pong payload.
func DecodePongResponse(data []byte) (*PongResponse, error) {
	if len(data) < pongPayloadSize {
		return nil, fmt.Errorf("pong data too short: need %d bytes, got %d", pongPayloadSize, len(data))
	}
	if len(data) > pongPayloadSize {
		return nil, fmt.Errorf("unexpected trailing bytes in pong payload: %d", len(data)-pongPayloadSize)
	}

	return &PongResponse{
		Timestamp:       int64(binary.BigEndian.Uint64(data[0:8])),
		ServerTimestamp: int64(binary.BigEndian.Uint64(data[8:16])),
	}, nil
}

// DecodePresenceUpdate decodes S_RoomPresenceUpdate.
func DecodePresenceUpdate(data []byte) (*PresenceUpdate, error) {
	buf := bytes.NewReader(data)
	update := &PresenceUpdate{}

	if err := binary.Read(buf, binary.BigEndian, &update.ConvID); err != nil {
		return nil, err
	}
	if err := binary.Read(buf, binary.BigEndian, &update.EventType); err != nil {
		return nil, err
	}
	if err := binary.Read(buf, binary.BigEndian, &update.Sequence); err != nil {
		return nil, err
	}
	username, err := readString(buf)
	if err != nil {
		return nil, err
	}
	update.Username = username

	var isAuth uint8
	if err := binary.Read(buf, binary.BigEndian, &isAuth); err != nil {
		return nil, err
	}
	update.IsAuth = isAuth == 1

	var userType uint8
	if err := binary.Read(buf, binary.BigEndian, &userType); err != nil {
		return nil, err
	}

	oldUsername, err := readString(buf)
	if err != nil {
		return nil, err
	}
	update.OldUsername = oldUsername

	var userListLen uint16
	if err := binary.Read(buf, binary.BigEndian, &userListLen); err != nil {
		return nil, err
	}

	update.Users = make([]PresenceUser, 0, userListLen)
	for i := 0; i < int(userListLen); i++ {
		name, err := readString(buf)
		if err != nil {
			return nil, err
		}
		var auth uint8
		if err := binary.Read(buf, binary.BigEndian, &auth); err != nil {
			return nil, err
		}
		var uType uint8
		if err := binary.Read(buf, binary.BigEndian, &uType); err != nil {
			return nil, err
		}
		update.Users = append(update.Users, PresenceUser{
			Username:        name,
			IsAuthenticated: auth == 1,
		})
	}

	return update, nil
}
