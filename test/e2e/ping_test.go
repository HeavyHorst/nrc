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
	if stats.Database != nil {
		t.Fatal("legacy request unexpectedly received SQLite extension")
	}
	if err := sendProtocolMessage(conn, protocol.C_GetTasks, protocol.EncodeGetTasks(0)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, conn, protocol.S_TaskListResponse, 12)
	if err := sendProtocolMessage(conn, protocol.C_Stats, protocol.EncodeDatabaseStats(statsTS)); err != nil {
		t.Fatal(err)
	}
	dbStats, err := protocol.DecodeStatsResponse(mustReadUntilOpcode(t, conn, protocol.S_StatsResponse, 12))
	if err != nil {
		t.Fatal(err)
	}
	if dbStats.Database == nil || dbStats.Database.Counters[2] != 64 || dbStats.Database.Counters[6] != 16 || dbStats.Database.Counters[21] == 0 {
		t.Fatalf("missing SQLite capacity/read metrics: %+v", dbStats.Database)
	}
	var readSamples uint64
	for _, bucket := range dbStats.Database.Histograms[5].Buckets {
		readSamples += bucket
	}
	if readSamples != dbStats.Database.Counters[21] {
		t.Fatalf("read publication samples=%d, completions=%d", readSamples, dbStats.Database.Counters[21])
	}
	v1Request := protocol.EncodeDatabaseStats(statsTS)
	v1Request[8] = 1
	if err := sendProtocolMessage(conn, protocol.C_Stats, v1Request); err != nil {
		t.Fatal(err)
	}
	v1, err := protocol.DecodeStatsResponse(mustReadUntilOpcode(t, conn, protocol.S_StatsResponse, 12))
	if err != nil {
		t.Fatal(err)
	}
	if v1.Database == nil || v1.Database.Generation != [2]uint64{} || v1.Database.Sequence != 0 || v1.Database.Counters[21] < readSamples {
		t.Fatalf("v1 compatibility: stats=%+v err=%v", v1.Database, err)
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

func TestDatabaseStatsProcessGeneration(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)
	workspace := fmt.Sprintf("e2e-stats-generation-%d", time.Now().UnixNano())
	snapshot := func() *protocol.DatabaseStats {
		t.Helper()
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		mustSetReadDeadline(t, conn, 5*time.Second)
		mustExpectServerReady(t, conn)
		if err := sendProtocolMessage(conn, protocol.C_Stats, protocol.EncodeDatabaseStats(123)); err != nil {
			t.Fatal(err)
		}
		stats, err := protocol.DecodeStatsResponse(mustReadUntilOpcode(t, conn, protocol.S_StatsResponse, 12))
		if err != nil || stats.Timestamp != 123 || stats.Database == nil || stats.Database.Generation == [2]uint64{} || stats.Database.Sequence == 0 {
			t.Fatalf("invalid ordered sample: %+v err=%v", stats, err)
		}
		return stats.Database
	}
	first, second := snapshot(), snapshot()
	if first.Generation != second.Generation || second.Sequence <= first.Sequence {
		t.Fatalf("order must span WebSocket connections: first=%+v second=%+v", first, second)
	}
	stopSharedServerIfRunning()
	server = startServer(t)
	defer server.stop(t)
	restarted := snapshot()
	if restarted.Generation == first.Generation || restarted.Sequence != 1 {
		t.Fatalf("restart must change generation and reset worker sequence: %+v", restarted)
	}
}
