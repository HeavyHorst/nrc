package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestStatsAndPingPong(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-ping-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	statsTS := time.Now().UnixNano()
	if err := sendProtocolMessage(conn, protocol.C_Stats, protocol.EncodeStats(statsTS)); err != nil {
		t.Fatalf("failed to send C_Stats: %v", err)
	}

	statsPayload := mustReadUntilOpcode(t, conn, protocol.S_StatsResponse, 12)
	stats, err := protocol.DecodeStatsResponse(statsPayload)
	if err != nil {
		t.Fatalf("failed to decode S_StatsResponse: %v payload=%x", err, statsPayload)
	}

	if stats.Timestamp != statsTS {
		t.Fatalf("stats timestamp echo mismatch: got %d want %d", stats.Timestamp, statsTS)
	}
	if stats.ServerTimestamp <= 0 {
		t.Fatalf("server timestamp must be positive, got %d", stats.ServerTimestamp)
	}
	if stats.TotalThreads == 0 {
		t.Fatalf("total_threads must be > 0, got %d", stats.TotalThreads)
	}
	if stats.IORingDepth == 0 {
		t.Fatalf("io_ring_depth must be > 0, got %d", stats.IORingDepth)
	}
	if stats.IORingAvailable > stats.IORingDepth {
		t.Fatalf("io_ring_available cannot exceed ring depth: available=%d depth=%d", stats.IORingAvailable, stats.IORingDepth)
	}
	if stats.SendQueueDepth > stats.SendQueueLimit {
		t.Fatalf("send_queue_depth cannot exceed send_queue_limit: depth=%d limit=%d", stats.SendQueueDepth, stats.SendQueueLimit)
	}

	if stats.WALDetailsVersion != 1 {
		t.Fatalf("wal_details_version must be 1, got %d", stats.WALDetailsVersion)
	}
	if len(stats.WALDetails) != 3 {
		t.Fatalf("expected 3 wal detail entries (task/asset/edge), got %d", len(stats.WALDetails))
	}

	seenKinds := map[uint8]bool{}
	for _, detail := range stats.WALDetails {
		seenKinds[detail.Kind] = true
	}
	for _, kind := range []uint8{protocol.StatsWALKindTask, protocol.StatsWALKindAsset, protocol.StatsWALKindEdge} {
		if !seenKinds[kind] {
			t.Fatalf("missing wal detail kind %d", kind)
		}
	}

	pingTS := time.Now().UnixNano()
	if err := sendProtocolMessage(conn, protocol.C_Ping, protocol.EncodePing(pingTS)); err != nil {
		t.Fatalf("failed to send C_Ping: %v", err)
	}

	pongPayload := mustReadUntilOpcode(t, conn, protocol.S_Pong, 12)
	pong, err := protocol.DecodePongResponse(pongPayload)
	if err != nil {
		t.Fatalf("failed to decode S_Pong: %v payload=%x", err, pongPayload)
	}

	if pong.Timestamp != pingTS {
		t.Fatalf("pong timestamp echo mismatch: got %d want %d", pong.Timestamp, pingTS)
	}
	if pong.ServerTimestamp <= 0 {
		t.Fatalf("pong server timestamp must be positive, got %d", pong.ServerTimestamp)
	}
}
