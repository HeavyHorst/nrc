package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
)

func TestParseServerReadyLegacyPayload(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(S_ServerReady))
	writeString(buf, "dev-2026-03:abc1234")
	binary.Write(buf, binary.BigEndian, uint32(1))
	writeString(buf, "AMD Ryzen")

	ready, err := ParseServerReady(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if ready.BuildVersion != "dev-2026-03:abc1234" {
		t.Fatalf("BuildVersion = %q, want %q", ready.BuildVersion, "dev-2026-03:abc1234")
	}
	if ready.ProtocolVersion != 1 {
		t.Fatalf("ProtocolVersion = %d, want 1", ready.ProtocolVersion)
	}
	if ready.CPUModel != "AMD Ryzen" {
		t.Fatalf("CPUModel = %q, want %q", ready.CPUModel, "AMD Ryzen")
	}
	if ready.Username != "" {
		t.Fatalf("Username = %q, want empty", ready.Username)
	}
	if ready.IsAuthenticated {
		t.Fatal("IsAuthenticated = true, want false")
	}
}

func TestParseServerReadyWithAuthFields(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(S_ServerReady))
	writeString(buf, "dev-2026-03:def5678")
	binary.Write(buf, binary.BigEndian, uint32(2))
	writeString(buf, "Intel Xeon")
	writeString(buf, "rene")
	buf.WriteByte(1)

	ready, err := ParseServerReady(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if ready.Username != "rene" {
		t.Fatalf("Username = %q, want %q", ready.Username, "rene")
	}
	if !ready.IsAuthenticated {
		t.Fatal("IsAuthenticated = false, want true")
	}
}

func TestParseServerReadyTooShort(t *testing.T) {
	_, err := ParseServerReady([]byte{0})
	if err == nil {
		t.Fatal("expected error for short server ready message")
	}
}

func TestParseServerReadyTrailingData(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(S_ServerReady))
	writeString(buf, "dev")
	binary.Write(buf, binary.BigEndian, uint32(1))
	writeString(buf, "cpu")
	writeString(buf, "user")
	buf.WriteByte(1)
	buf.WriteByte(0xFF)

	_, err := ParseServerReady(buf.Bytes())
	if err == nil {
		t.Fatal("expected error for trailing bytes")
	}
}

func TestChatMessageRoundTrip(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, int64(42))     // conv_id
	binary.Write(buf, binary.BigEndian, int64(1))      // sequence
	writeString(buf, "alice")                          // username
	binary.Write(buf, binary.BigEndian, int64(170000)) // timestamp
	buf.WriteByte(byte(ContentTypeMarkdown))           // content_type
	writeString(buf, "**hello**")                      // content

	got, err := DecodeChatMessage(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if got.ConvID != 42 {
		t.Errorf("ConvID = %d, want 42", got.ConvID)
	}
	if got.Username != "alice" {
		t.Errorf("Username = %q, want %q", got.Username, "alice")
	}
	if got.ContentType != ContentTypeMarkdown {
		t.Errorf("ContentType = %d, want %d", got.ContentType, ContentTypeMarkdown)
	}
	if got.Content != "**hello**" {
		t.Errorf("Content = %q, want %q", got.Content, "**hello**")
	}
}

func TestDecodeStats(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, int64(123)) // timestamp
	binary.Write(buf, binary.BigEndian, int64(456)) // server_timestamp
	binary.Write(buf, binary.BigEndian, uint32(1))
	binary.Write(buf, binary.BigEndian, uint32(4))
	binary.Write(buf, binary.BigEndian, uint32(5)) // connections
	binary.Write(buf, binary.BigEndian, uint32(512))
	binary.Write(buf, binary.BigEndian, uint32(75))
	binary.Write(buf, binary.BigEndian, uint32(10))
	binary.Write(buf, binary.BigEndian, uint32(256))
	binary.Write(buf, binary.BigEndian, uint32(200))
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(50000))
	binary.Write(buf, binary.BigEndian, uint64(1000000))
	binary.Write(buf, binary.BigEndian, uint64(500))
	binary.Write(buf, binary.BigEndian, uint32(50))
	binary.Write(buf, binary.BigEndian, uint32(1000))
	buf.WriteByte(0)
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(10))
	binary.Write(buf, binary.BigEndian, uint64(20))
	binary.Write(buf, binary.BigEndian, uint64(30))
	binary.Write(buf, binary.BigEndian, uint64(40))
	binary.Write(buf, binary.BigEndian, uint64(50))
	binary.Write(buf, binary.BigEndian, uint64(60))
	binary.Write(buf, binary.BigEndian, uint64(70))
	got, err := DecodeStats(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if got.ActiveConnections != 5 {
		t.Errorf("ActiveConnections = %d, want 5", got.ActiveConnections)
	}
	if got.ServerTimestamp != 456 {
		t.Errorf("ServerTimestamp = %d, want 456", got.ServerTimestamp)
	}
}

func TestDecodeStatsTooShort(t *testing.T) {
	_, err := DecodeStats([]byte{0, 0, 0})
	if err == nil {
		t.Error("expected error for short stats data")
	}
}

func TestEncodeStats(t *testing.T) {
	data := EncodeStats(1234)
	if len(data) != 8 {
		t.Fatalf("stats payload length = %d, want 8", len(data))
	}
	if got := int64(binary.BigEndian.Uint64(data)); got != 1234 {
		t.Fatalf("stats timestamp = %d, want 1234", got)
	}
}

func TestEncodePing(t *testing.T) {
	data := EncodePing(1234)
	if len(data) != 8 {
		t.Fatalf("ping payload length = %d, want 8", len(data))
	}
	if got := int64(binary.BigEndian.Uint64(data)); got != 1234 {
		t.Fatalf("ping timestamp = %d, want 1234", got)
	}
}

func TestDecodeStatsResponse(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, int64(111))
	binary.Write(buf, binary.BigEndian, int64(222))
	binary.Write(buf, binary.BigEndian, uint32(3))
	binary.Write(buf, binary.BigEndian, uint32(8))
	binary.Write(buf, binary.BigEndian, uint32(12))
	binary.Write(buf, binary.BigEndian, uint32(1024))
	binary.Write(buf, binary.BigEndian, uint32(5))
	binary.Write(buf, binary.BigEndian, uint32(1))
	binary.Write(buf, binary.BigEndian, uint32(256))
	binary.Write(buf, binary.BigEndian, uint32(255))
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(10))
	binary.Write(buf, binary.BigEndian, uint64(20))
	binary.Write(buf, binary.BigEndian, uint64(30))
	binary.Write(buf, binary.BigEndian, uint32(2))
	binary.Write(buf, binary.BigEndian, uint32(128))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(101))
	binary.Write(buf, binary.BigEndian, uint64(102))
	binary.Write(buf, binary.BigEndian, uint64(103))
	binary.Write(buf, binary.BigEndian, uint64(104))
	binary.Write(buf, binary.BigEndian, uint64(105))
	binary.Write(buf, binary.BigEndian, uint64(106))
	binary.Write(buf, binary.BigEndian, uint64(107))

	stats, err := DecodeStatsResponse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if stats.Timestamp != 111 || stats.ServerTimestamp != 222 {
		t.Fatalf("unexpected timestamps: %+v", stats)
	}
	if !stats.SendBackpressure {
		t.Fatal("expected send backpressure true")
	}
}

func TestDecodeStatsResponseWithWALDetails(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, int64(111))
	binary.Write(buf, binary.BigEndian, int64(222))
	binary.Write(buf, binary.BigEndian, uint32(3))
	binary.Write(buf, binary.BigEndian, uint32(8))
	binary.Write(buf, binary.BigEndian, uint32(12))
	binary.Write(buf, binary.BigEndian, uint32(1024))
	binary.Write(buf, binary.BigEndian, uint32(5))
	binary.Write(buf, binary.BigEndian, uint32(1))
	binary.Write(buf, binary.BigEndian, uint32(256))
	binary.Write(buf, binary.BigEndian, uint32(255))
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(10))
	binary.Write(buf, binary.BigEndian, uint64(20))
	binary.Write(buf, binary.BigEndian, uint64(30))
	binary.Write(buf, binary.BigEndian, uint32(2))
	binary.Write(buf, binary.BigEndian, uint32(128))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(101))
	binary.Write(buf, binary.BigEndian, uint64(102))
	binary.Write(buf, binary.BigEndian, uint64(103))
	binary.Write(buf, binary.BigEndian, uint64(104))
	binary.Write(buf, binary.BigEndian, uint64(105))
	binary.Write(buf, binary.BigEndian, uint64(106))
	binary.Write(buf, binary.BigEndian, uint64(107))

	buf.WriteByte(1) // wal details version
	buf.WriteByte(3) // detail count

	for _, kind := range []uint8{StatsWALKindTask, StatsWALKindAsset, StatsWALKindEdge} {
		buf.WriteByte(kind)
		buf.WriteByte(1)
		buf.WriteByte(1)
		buf.WriteByte(2)
		binary.Write(buf, binary.BigEndian, uint64(9))
		binary.Write(buf, binary.BigEndian, uint64(99))
		binary.Write(buf, binary.BigEndian, uint64(7))
		binary.Write(buf, binary.BigEndian, uint64(5))
		binary.Write(buf, binary.BigEndian, uint64(44))
		binary.Write(buf, binary.BigEndian, uint32(1500))
		binary.Write(buf, binary.BigEndian, uint64(4096))
		binary.Write(buf, binary.BigEndian, uint64(88))
		binary.Write(buf, binary.BigEndian, uint64(77))
		binary.Write(buf, binary.BigEndian, uint64(66))
		binary.Write(buf, binary.BigEndian, uint64(55))
		binary.Write(buf, binary.BigEndian, uint64(33))
		binary.Write(buf, binary.BigEndian, uint64(22))
	}

	stats, err := DecodeStatsResponse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if stats.WALDetailsVersion != 1 {
		t.Fatalf("WALDetailsVersion = %d, want 1", stats.WALDetailsVersion)
	}
	if len(stats.WALDetails) != 3 {
		t.Fatalf("len(WALDetails) = %d, want 3", len(stats.WALDetails))
	}
	if stats.WALDetails[0].Kind != StatsWALKindTask {
		t.Fatalf("WALDetails[0].Kind = %d, want %d", stats.WALDetails[0].Kind, StatsWALKindTask)
	}
	if stats.WALDetails[0].InstallBudgetUS != 1500 {
		t.Fatalf("WALDetails[0].InstallBudgetUS = %d, want 1500", stats.WALDetails[0].InstallBudgetUS)
	}
}

func TestDecodeStatsResponseWithTruncatedWALDetails(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, int64(111))
	binary.Write(buf, binary.BigEndian, int64(222))
	binary.Write(buf, binary.BigEndian, uint32(3))
	binary.Write(buf, binary.BigEndian, uint32(8))
	binary.Write(buf, binary.BigEndian, uint32(12))
	binary.Write(buf, binary.BigEndian, uint32(1024))
	binary.Write(buf, binary.BigEndian, uint32(5))
	binary.Write(buf, binary.BigEndian, uint32(1))
	binary.Write(buf, binary.BigEndian, uint32(256))
	binary.Write(buf, binary.BigEndian, uint32(255))
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(10))
	binary.Write(buf, binary.BigEndian, uint64(20))
	binary.Write(buf, binary.BigEndian, uint64(30))
	binary.Write(buf, binary.BigEndian, uint32(2))
	binary.Write(buf, binary.BigEndian, uint32(128))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint32(0))
	binary.Write(buf, binary.BigEndian, uint64(101))
	binary.Write(buf, binary.BigEndian, uint64(102))
	binary.Write(buf, binary.BigEndian, uint64(103))
	binary.Write(buf, binary.BigEndian, uint64(104))
	binary.Write(buf, binary.BigEndian, uint64(105))
	binary.Write(buf, binary.BigEndian, uint64(106))
	binary.Write(buf, binary.BigEndian, uint64(107))

	buf.WriteByte(1) // wal details version
	buf.WriteByte(1) // detail count, but no detail payload follows

	_, err := DecodeStatsResponse(buf.Bytes())
	if err == nil {
		t.Fatal("expected error for truncated wal details")
	}
}

func statsShardSweepFixture() []byte {
	buf := bytes.NewBuffer(nil)
	for _, value := range []any{
		int64(111), int64(222), uint32(3), uint32(8), uint32(12), uint32(1024),
		uint32(5), uint32(1), uint32(256), uint32(255), uint32(0), uint64(10),
		uint64(20), uint64(30), uint32(2), uint32(128),
	} {
		binary.Write(buf, binary.BigEndian, value)
	}
	buf.WriteByte(1)
	for _, value := range []any{
		uint32(0), uint64(101), uint64(102), uint64(103), uint64(104), uint64(105),
		uint64(106), uint64(107),
	} {
		binary.Write(buf, binary.BigEndian, value)
	}
	buf.WriteByte(1) // WAL details version
	buf.WriteByte(0) // WAL details count
	buf.WriteByte(1) // shard sweep extension version
	for value := uint64(1); value <= 12; value++ {
		binary.Write(buf, binary.BigEndian, value)
	}
	return buf.Bytes()
}

func TestDecodeStatsResponseWithShardSweepExtension(t *testing.T) {
	stats, err := DecodeStatsResponse(statsShardSweepFixture())
	if err != nil {
		t.Fatal(err)
	}
	if stats.ShardSweepVersion != 1 || stats.ShardSweep == nil {
		t.Fatalf("unexpected shard sweep extension: version=%d value=%+v", stats.ShardSweepVersion, stats.ShardSweep)
	}
	if stats.ShardSweep.RunsTotal != 1 || stats.ShardSweep.ReplayReadBytesTotal != 10 ||
		stats.ShardSweep.MetadataWrittenBytesTotal != 12 {
		t.Fatalf("unexpected shard sweep values: %+v", stats.ShardSweep)
	}
}

func TestDecodeStatsResponseRejectsMalformedShardSweepExtension(t *testing.T) {
	fixture := statsShardSweepFixture()
	for _, remove := range []int{1, 48, 96} {
		t.Run(fmt.Sprintf("truncated_by_%d", remove), func(t *testing.T) {
			if _, err := DecodeStatsResponse(fixture[:len(fixture)-remove]); err == nil {
				t.Fatal("expected truncated shard sweep extension error")
			}
		})
	}

	t.Run("trailing", func(t *testing.T) {
		if _, err := DecodeStatsResponse(append(append([]byte(nil), fixture...), 0)); err == nil {
			t.Fatal("expected trailing shard sweep extension error")
		}
	})

	t.Run("unknown_version", func(t *testing.T) {
		unknown := append([]byte(nil), fixture...)
		unknown[len(unknown)-statsShardSweepExtensionSize] = 2
		_, err := DecodeStatsResponse(unknown)
		if err == nil || !strings.Contains(err.Error(), "unsupported stats shard sweep extension version 2") {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}

func TestDecodePongResponse(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, int64(111))
	binary.Write(buf, binary.BigEndian, int64(222))

	pong, err := DecodePongResponse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if pong.Timestamp != 111 || pong.ServerTimestamp != 222 {
		t.Fatalf("unexpected pong payload: %+v", pong)
	}
}

func TestDecodePongResponseTrailingData(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, int64(111))
	binary.Write(buf, binary.BigEndian, int64(222))
	buf.WriteByte(0xFF)

	_, err := DecodePongResponse(buf.Bytes())
	if err == nil {
		t.Fatal("expected error for trailing bytes in lightweight pong payload")
	}
}

func TestEncodeSendMessageWithClientReqID(t *testing.T) {
	data := EncodeSendMessage(7, 42, "hello", ContentTypePlainText)
	if len(data) < 15 {
		t.Fatalf("encoded send message too short: %d", len(data))
	}

	roomID := int64(binary.BigEndian.Uint64(data[0:8]))
	if roomID != 7 {
		t.Fatalf("roomID = %d, want 7", roomID)
	}
	clientReqID := binary.BigEndian.Uint32(data[8:12])
	if clientReqID != 42 {
		t.Fatalf("clientReqID = %d, want 42", clientReqID)
	}
}

func TestDecodeAckSendMessage(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint32(42))
	binary.Write(buf, binary.BigEndian, uint64(99))
	binary.Write(buf, binary.BigEndian, int64(1234567890))

	ack, err := DecodeAckSendMessage(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if ack.ClientReqID != 42 {
		t.Fatalf("ClientReqID = %d, want 42", ack.ClientReqID)
	}
	if ack.AssignedSeq != 99 {
		t.Fatalf("AssignedSeq = %d, want 99", ack.AssignedSeq)
	}
}

func TestDecodeAckSendMessageTooShort(t *testing.T) {
	_, err := DecodeAckSendMessage([]byte{1, 2, 3})
	if err == nil {
		t.Fatal("expected error for short ack payload")
	}
}

func TestDecodeAckSendMessageRejectsTrailingData(t *testing.T) {
	_, err := DecodeAckSendMessage(make([]byte, 21))
	if err == nil {
		t.Fatal("expected error for trailing ack payload data")
	}
}

func TestReadMessageReturnsPayloadOnly(t *testing.T) {
	payload := bytes.NewBuffer(nil)
	binary.Write(payload, binary.BigEndian, int64(42))
	binary.Write(payload, binary.BigEndian, int64(99))
	writeString(payload, "alice")
	binary.Write(payload, binary.BigEndian, int64(1234567890))
	payload.WriteByte(byte(ContentTypePlainText))
	writeString(payload, "hello")

	msg := &Message{Opcode: S_NewMessage, Data: payload.Bytes()}
	wire, err := msg.Write()
	if err != nil {
		t.Fatalf("write message: %v", err)
	}

	parsed, err := ReadMessage(wire)
	if err != nil {
		t.Fatalf("read message: %v", err)
	}
	if parsed.Opcode != S_NewMessage {
		t.Fatalf("opcode = %d, want %d", parsed.Opcode, S_NewMessage)
	}
	if !bytes.Equal(parsed.Data, payload.Bytes()) {
		t.Fatalf("payload mismatch: got %d bytes, want %d", len(parsed.Data), len(payload.Bytes()))
	}

	decoded, err := DecodeChatMessage(parsed.Data)
	if err != nil {
		t.Fatalf("decode chat payload: %v", err)
	}
	if decoded.ConvID != 42 || decoded.Sequence != 99 || decoded.Timestamp != 1234567890 || decoded.Content != "hello" {
		t.Fatalf("unexpected decoded chat message: %+v", decoded)
	}

	// Ensure passing full wire payload still fails as expected.
	_, err = DecodeChatMessage(wire)
	if err == nil {
		t.Fatal("expected DecodeChatMessage to reject full wire payload with opcode")
	}

}

func TestDecodeErrorResponse(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(C_Stats))
	binary.Write(buf, binary.BigEndian, uint16(5))
	buf.WriteString("error")
	binary.Write(buf, binary.BigEndian, uint32(0xAABBCCDD))

	resp, err := DecodeErrorResponse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if resp.OriginOpcode != C_Stats {
		t.Fatalf("OriginOpcode = %d, want %d", resp.OriginOpcode, C_Stats)
	}
	if resp.ErrorMessage != "error" {
		t.Fatalf("ErrorMessage = %q, want %q", resp.ErrorMessage, "error")
	}
	if resp.CorrelationID != 0xAABBCCDD {
		t.Fatalf("CorrelationID = 0x%08X, want 0xAABBCCDD", resp.CorrelationID)
	}
}

func TestDecodeErrorResponseTooShort(t *testing.T) {
	_, err := DecodeErrorResponse([]byte{0, 1, 0})
	if err == nil {
		t.Fatal("expected error for short error response")
	}
}

func TestDecodeErrorResponseTrailingData(t *testing.T) {
	data := []byte{0, 1, 0, 1, 'x', 0, 0, 0, 1, 0xff}
	_, err := DecodeErrorResponse(data)
	if err == nil {
		t.Fatal("expected error for trailing bytes")
	}
}

func TestEncodeUnsubscribeConvs(t *testing.T) {
	data := EncodeUnsubscribeConvs(1, 9)
	if len(data) != 2+8+8 {
		t.Fatalf("unexpected unsubscribe payload length: got %d", len(data))
	}

	count := binary.BigEndian.Uint16(data[0:2])
	if count != 2 {
		t.Fatalf("unsubscribe count = %d, want 2", count)
	}
	room1 := int64(binary.BigEndian.Uint64(data[2:10]))
	room2 := int64(binary.BigEndian.Uint64(data[10:18]))
	if room1 != 1 || room2 != 9 {
		t.Fatalf("unexpected unsubscribe rooms: got [%d, %d], want [1, 9]", room1, room2)
	}
}

func TestEncodeUnsubscribeConvsWithCorrelation(t *testing.T) {
	data := EncodeUnsubscribeConvsWithCorrelation(0x12345678, 1, 9)
	if len(data) != 2+8+8+4 {
		t.Fatalf("unexpected correlated unsubscribe payload length: got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[18:22]); got != 0x12345678 {
		t.Fatalf("correlation ID = %#x, want %#x", got, uint32(0x12345678))
	}
}

func TestDecodeAckUnsubscribeConvs(t *testing.T) {
	ack, err := DecodeAckUnsubscribeConvs([]byte{0x12, 0x34, 0x56, 0x78})
	if err != nil {
		t.Fatalf("DecodeAckUnsubscribeConvs error: %v", err)
	}
	if ack.CorrelationID != 0x12345678 {
		t.Fatalf("correlation ID = %#x, want %#x", ack.CorrelationID, uint32(0x12345678))
	}
	if _, err = DecodeAckUnsubscribeConvs([]byte{0, 1, 2}); err == nil {
		t.Fatal("expected error for invalid acknowledgment length")
	}
}
