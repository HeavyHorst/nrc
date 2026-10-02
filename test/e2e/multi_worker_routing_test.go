package e2e

import (
	"fmt"
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestStatsThreadIDMatchesWorkspaceHashRouting(t *testing.T) {
	const expectedThreadCount uint32 = 4
	server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{
		"NRC_THREAD_COUNT": strconv.FormatUint(uint64(expectedThreadCount), 10),
	})
	defer server.stop(t)

	bootstrapWorkspace := fmt.Sprintf("e2e-routing-bootstrap-%d", time.Now().UnixNano())
	bootstrapConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(bootstrapWorkspace), mustAuthHeader(t, "e2e-routing-bootstrap"))
	if err != nil {
		t.Fatalf("failed to connect bootstrap websocket client: %v", err)
	}
	defer bootstrapConn.Close()

	mustSetReadDeadline(t, bootstrapConn, 5*time.Second)
	mustExpectServerReady(t, bootstrapConn)
	bootstrapStats := requestStatsResponse(t, bootstrapConn, time.Now().UnixNano())
	if bootstrapStats.TotalThreads == 0 {
		t.Fatal("bootstrap stats reported zero total threads")
	}
	if bootstrapStats.ThreadID >= bootstrapStats.TotalThreads {
		t.Fatalf("bootstrap thread_id out of range: thread_id=%d total_threads=%d", bootstrapStats.ThreadID, bootstrapStats.TotalThreads)
	}
	if bootstrapStats.TotalThreads != expectedThreadCount {
		t.Fatalf("stats total_threads mismatch: got %d want %d", bootstrapStats.TotalThreads, expectedThreadCount)
	}
	expectedConnectionsByThread := map[uint32]uint32{
		bootstrapStats.ThreadID: 1,
	}

	targetCount := bootstrapStats.TotalThreads

	for targetThread := uint32(0); targetThread < targetCount; targetThread++ {
		workspace := mustFindE2EWorkspaceForThread(t, fmt.Sprintf("e2e-routing-%d", time.Now().UnixNano()), targetThread, bootstrapStats.TotalThreads)
		connA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, fmt.Sprintf("e2e-routing-user-a-%d", targetThread)))
		if err != nil {
			t.Fatalf("failed to connect routing client A for target thread %d workspace %q: %v", targetThread, workspace, err)
		}
		defer connA.Close()
		connB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, fmt.Sprintf("e2e-routing-user-b-%d", targetThread)))
		if err != nil {
			t.Fatalf("failed to connect routing client B for target thread %d workspace %q: %v", targetThread, workspace, err)
		}
		defer connB.Close()

		mustSetReadDeadline(t, connA, 5*time.Second)
		mustSetReadDeadline(t, connB, 5*time.Second)
		mustExpectServerReady(t, connA)
		mustExpectServerReady(t, connB)
		expectedConnectionsByThread[targetThread] += 2

		statsA := requestStatsResponse(t, connA, time.Now().UnixNano())
		statsB := requestStatsResponse(t, connB, time.Now().UnixNano())
		if statsA.TotalThreads != bootstrapStats.TotalThreads {
			t.Fatalf("client A total_threads changed: got %d want %d", statsA.TotalThreads, bootstrapStats.TotalThreads)
		}
		if statsB.TotalThreads != bootstrapStats.TotalThreads {
			t.Fatalf("client B total_threads changed: got %d want %d", statsB.TotalThreads, bootstrapStats.TotalThreads)
		}
		if statsA.ThreadID != targetThread {
			t.Fatalf("client A workspace %q routed to thread %d, want %d", workspace, statsA.ThreadID, targetThread)
		}
		if statsB.ThreadID != targetThread {
			t.Fatalf("client B same workspace %q routed to thread %d, want %d", workspace, statsB.ThreadID, targetThread)
		}
		expectedConnections := expectedConnectionsByThread[targetThread]
		if statsA.Connections < expectedConnections {
			t.Fatalf("client A thread %d reported %d connections, want at least %d", targetThread, statsA.Connections, expectedConnections)
		}
		if statsB.Connections < expectedConnections {
			t.Fatalf("client B thread %d reported %d connections, want at least %d", targetThread, statsB.Connections, expectedConnections)
		}
	}
}

func TestWorkerCountResizeReassignsReplaysAndContinuesWrites(t *testing.T) {
	serverWorkDir := t.TempDir()
	logicalShards := []uint64{2, 3, 4}
	workspaces := make([]string, len(logicalShards))
	for i, shard := range logicalShards {
		workspaces[i] = mustFindE2EWorkspaceForLogicalShard(t, fmt.Sprintf("e2e-resize-%d", time.Now().UnixNano()), shard)
	}

	server := startServerInWorkDirWithEnv(t, serverWorkDir, map[string]string{"NRC_THREAD_COUNT": "2"})
	servers := []*serverProcess{server}
	t.Cleanup(func() { cleanupFaultTestServers(t, servers) })
	const roomID int64 = protocol.WorkspaceDataConvID
	taskIDs := make([]uint64, len(workspaces))
	titles := make([]string, len(workspaces))
	expectedTasks := make([]map[uint64]protocol.Task, len(workspaces))

	for i, workspace := range workspaces {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, fmt.Sprintf("e2e-resize-create-%d", i)))
		if err != nil {
			t.Fatalf("failed to connect before resize for shard %d: %v", logicalShards[i], err)
		}
		mustSetReadDeadline(t, conn, 5*time.Second)
		mustExpectServerReady(t, conn)
		stats := requestStatsResponse(t, conn, time.Now().UnixNano())
		if stats.TotalThreads != 2 || stats.ThreadID != uint32(logicalShards[i]%2) {
			_ = conn.Close()
			t.Fatalf("initial owner mismatch for shard %d: thread=%d total=%d", logicalShards[i], stats.ThreadID, stats.TotalThreads)
		}
		titles[i] = fmt.Sprintf("resize shard %d initial", logicalShards[i])
		if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreate(roomID, titles[i], "before worker resize", 1)); err != nil {
			_ = conn.Close()
			t.Fatalf("failed to create task for shard %d: %v", logicalShards[i], err)
		}
		payload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
		created, err := protocol.DecodeTaskCreated(payload)
		_ = conn.Close()
		if err != nil {
			t.Fatalf("failed to decode task for shard %d: %v", logicalShards[i], err)
		}
		taskIDs[i] = created.Task.ID
		expectedTasks[i] = map[uint64]protocol.Task{created.Task.ID: *created.Task}
	}

	server.stopGracefully(t)
	server = startServerInWorkDirWithEnv(t, serverWorkDir, map[string]string{"NRC_THREAD_COUNT": "3"})
	servers = append(servers, server)
	for i, workspace := range workspaces {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, fmt.Sprintf("e2e-resize-update-%d", i)))
		if err != nil {
			t.Fatalf("failed to connect after resize to 3 for shard %d: %v", logicalShards[i], err)
		}
		mustSetReadDeadline(t, conn, 5*time.Second)
		mustExpectServerReady(t, conn)
		stats := requestStatsResponse(t, conn, time.Now().UnixNano())
		if stats.TotalThreads != 3 || stats.ThreadID != uint32(logicalShards[i]%3) {
			_ = conn.Close()
			t.Fatalf("resized owner mismatch for shard %d: thread=%d total=%d", logicalShards[i], stats.ThreadID, stats.TotalThreads)
		}
		mustRequireExactTaskState(t, conn, roomID, expectedTasks[i])
		titles[i] = fmt.Sprintf("resize shard %d updated", logicalShards[i])
		if err := sendProtocolMessage(conn, protocol.C_UpdateTask, protocol.EncodeTaskUpdate(roomID, int64(taskIDs[i]), titles[i], "after resize to three", int32(protocol.TaskStatusInProgress), 2, 0)); err != nil {
			_ = conn.Close()
			t.Fatalf("failed continued write for shard %d: %v", logicalShards[i], err)
		}
		updatedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskUpdated, 12)
		updated, err := protocol.DecodeTaskUpdated(updatedPayload)
		if err != nil || updated.Task.Title != titles[i] {
			_ = conn.Close()
			t.Fatalf("continued write mismatch for shard %d: response=%+v err=%v", logicalShards[i], updated, err)
		}
		expectedTasks[i][updated.Task.ID] = *updated.Task
		continuedTitle := fmt.Sprintf("resize shard %d new high water", logicalShards[i])
		if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreate(roomID, continuedTitle, "created after resize", 1)); err != nil {
			_ = conn.Close()
			t.Fatalf("failed post-resize create for shard %d: %v", logicalShards[i], err)
		}
		continuedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
		continued, err := protocol.DecodeTaskCreated(continuedPayload)
		_ = conn.Close()
		if err != nil || continued.Task.ID <= taskIDs[i] {
			t.Fatalf("high-water did not advance for shard %d: previous=%d response=%+v err=%v", logicalShards[i], taskIDs[i], continued, err)
		}
		expectedTasks[i][continued.Task.ID] = *continued.Task
	}

	server.stopGracefully(t)
	server = startServerInWorkDirWithEnv(t, serverWorkDir, map[string]string{"NRC_THREAD_COUNT": "4"})
	servers = append(servers, server)
	for i, workspace := range workspaces {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, fmt.Sprintf("e2e-resize-final-%d", i)))
		if err != nil {
			t.Fatalf("failed final restart for shard %d: %v", logicalShards[i], err)
		}
		mustSetReadDeadline(t, conn, 5*time.Second)
		mustExpectServerReady(t, conn)
		stats := requestStatsResponse(t, conn, time.Now().UnixNano())
		if stats.TotalThreads != 4 || stats.ThreadID != uint32(logicalShards[i]%4) {
			_ = conn.Close()
			t.Fatalf("final owner mismatch for shard %d: thread=%d total=%d", logicalShards[i], stats.ThreadID, stats.TotalThreads)
		}
		mustRequireExactTaskState(t, conn, roomID, expectedTasks[i])
		_ = conn.Close()
	}
}

func mustFindE2EWorkspaceForLogicalShard(t *testing.T, prefix string, targetShard uint64) string {
	t.Helper()
	for suffix := 0; suffix < 100_000; suffix++ {
		candidate := fmt.Sprintf("%s-%d-%d", prefix, targetShard, suffix)
		if xxhash.Sum64String(candidate)%256 == targetShard {
			return candidate
		}
	}
	t.Fatalf("failed to find workspace for logical shard %d", targetShard)
	return ""
}

func mustRequireExactTaskState(t *testing.T, conn *websocket.Conn, roomID int64, expected map[uint64]protocol.Task) {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_GetTasks, protocol.EncodeGetTasks(roomID)); err != nil {
		t.Fatalf("failed to list tasks: %v", err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskListResponse, 12)
	list, err := protocol.DecodeTaskListResponse(payload)
	if err != nil {
		t.Fatalf("failed to decode task list: %v", err)
	}
	if len(list.Tasks) != len(expected) {
		t.Fatalf("task set size mismatch: got=%d want=%d tasks=%+v", len(list.Tasks), len(expected), list.Tasks)
	}
	for _, task := range list.Tasks {
		want, found := expected[task.ID]
		if !found {
			t.Fatalf("unexpected task after worker-count resize: %+v", task)
		}
		if !reflect.DeepEqual(*task, want) {
			t.Fatalf("task %d mismatch after worker-count resize:\n got=%+v\nwant=%+v", task.ID, task, want)
		}
	}
}

func requestStatsResponse(t *testing.T, conn *websocket.Conn, timestamp int64) *protocol.StatsResponse {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_Stats, protocol.EncodeStats(timestamp)); err != nil {
		t.Fatalf("failed to send C_Stats: %v", err)
	}
	statsPayload := mustReadUntilOpcode(t, conn, protocol.S_StatsResponse, 12)
	stats, err := protocol.DecodeStatsResponse(statsPayload)
	if err != nil {
		t.Fatalf("failed to decode S_StatsResponse: %v payload=%x", err, statsPayload)
	}
	if stats.Timestamp != timestamp {
		t.Fatalf("stats timestamp echo mismatch: got %d want %d", stats.Timestamp, timestamp)
	}
	return stats
}

func mustFindE2EWorkspaceForThread(t *testing.T, prefix string, targetThread uint32, totalThreads uint32) string {
	t.Helper()

	for suffix := uint32(0); suffix < 100_000; suffix++ {
		candidate := fmt.Sprintf("%s-%d-%d", prefix, targetThread, suffix)
		logicalShard := xxhash.Sum64String(candidate) % 256
		if uint32(logicalShard%uint64(totalThreads)) == targetThread {
			return candidate
		}
	}
	t.Fatalf("failed to find workspace for target thread %d out of %d", targetThread, totalThreads)
	return ""
}
