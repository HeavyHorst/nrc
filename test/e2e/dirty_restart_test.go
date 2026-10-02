package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestDirtyRestartRecoversKernelAcceptedTaskAssetEdgeState(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-dirty-restart-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)
	servers := []*serverProcess{server}
	t.Cleanup(func() { cleanupFaultTestServers(t, servers) })

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-dirty-restart-writer"))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client before dirty restart: %v", err)
	}

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	const taskTitle = "dirty restart task"
	const taskDescription = "task survives abrupt process kill"
	const assetPreviewA = "dirty restart asset A"
	const assetPayloadA = "asset A survives abrupt process kill"
	const assetPreviewB = "dirty restart asset B"
	const assetPayloadB = "asset B survives abrupt process kill"

	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateFullWithCorrelation(roomID, taskTitle, taskDescription, 3, "dirty", nil, 0xD1170001)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateTask before dirty restart: %v", err)
	}
	taskCreatedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	taskCreated, err := protocol.DecodeTaskCreated(taskCreatedPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_TaskCreated before dirty restart: %v payload=%x", err, taskCreatedPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, assetPreviewA, assetPayloadA, 0xD1170002)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send first CreateAsset before dirty restart: %v", err)
	}
	assetAPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	assetA, err := protocol.DecodeAssetCreated(assetAPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode first S_AssetCreated before dirty restart: %v payload=%x", err, assetAPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(roomID, protocol.AssetTypeDocument, protocol.ParentTypeNone, 0, assetPreviewB, assetPayloadB, 0xD1170003)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send second CreateAsset before dirty restart: %v", err)
	}
	assetBPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	assetB, err := protocol.DecodeAssetCreated(assetBPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode second S_AssetCreated before dirty restart: %v payload=%x", err, assetBPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdgeWithCorrelation(roomID, protocol.TargetTypeAsset, assetA.Asset.AssetID, protocol.TargetTypeTask, taskCreated.Task.ID, protocol.RelationRelatedTo, 0xD1170004)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateEdge before dirty restart: %v", err)
	}
	edgePayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 12)
	edgeCreated, err := protocol.DecodeEdgeCreated(edgePayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_EdgeCreated before dirty restart: %v payload=%x", err, edgePayload)
	}

	_ = conn.Close()

	server.killAndWait(t)

	server = startServerInWorkDir(t, serverWorkDir)
	servers = append(servers, server)

	connAfterRestart, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-dirty-restart-reader"))
	if err != nil {
		t.Fatalf("failed to connect websocket client after dirty restart: %v", err)
	}
	defer connAfterRestart.Close()

	mustSetReadDeadline(t, connAfterRestart, 5*time.Second)
	mustExpectServerReady(t, connAfterRestart)

	if err := sendProtocolMessage(connAfterRestart, protocol.C_GetTasks, protocol.EncodeGetTasks(roomID)); err != nil {
		t.Fatalf("failed to send GetTasks after dirty restart: %v", err)
	}
	taskListPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_TaskListResponse, 12)
	taskList, err := protocol.DecodeTaskListResponse(taskListPayload)
	if err != nil {
		t.Fatalf("failed to decode TaskListResponse after dirty restart: %v payload=%x", err, taskListPayload)
	}
	foundTask := false
	for _, task := range taskList.Tasks {
		if task.ID == taskCreated.Task.ID {
			foundTask = true
			if task.Title != taskTitle || task.Description != taskDescription || task.Project != "dirty" {
				t.Fatalf("restored dirty-restart task mismatch: %+v", task)
			}
		}
	}
	if !foundTask {
		t.Fatalf("task id %d missing after dirty restart", taskCreated.Task.ID)
	}

	if err := sendProtocolMessage(connAfterRestart, protocol.C_ListAssets, protocol.EncodeListAssets(roomID, false, 0, true)); err != nil {
		t.Fatalf("failed to send ListAssets after dirty restart: %v", err)
	}
	assetsPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AssetList, 12)
	assets, err := protocol.DecodeAssetList(assetsPayload, true)
	if err != nil {
		t.Fatalf("failed to decode S_AssetList after dirty restart: %v payload=%x", err, assetsPayload)
	}
	foundAssetA, foundAssetB := false, false
	for _, asset := range assets {
		switch asset.AssetID {
		case assetA.Asset.AssetID:
			foundAssetA = true
			if asset.Preview != assetPreviewA || asset.Payload != assetPayloadA {
				t.Fatalf("restored dirty-restart asset A mismatch: %+v", asset)
			}
		case assetB.Asset.AssetID:
			foundAssetB = true
			if asset.Preview != assetPreviewB || asset.Payload != assetPayloadB {
				t.Fatalf("restored dirty-restart asset B mismatch: %+v", asset)
			}
		}
	}
	if !foundAssetA || !foundAssetB {
		t.Fatalf("assets missing after dirty restart: foundA=%t foundB=%t total=%d", foundAssetA, foundAssetB, len(assets))
	}

	if err := sendProtocolMessage(connAfterRestart, protocol.C_ListAllEdges, protocol.EncodeListAllEdges(roomID)); err != nil {
		t.Fatalf("failed to send ListAllEdges after dirty restart: %v", err)
	}
	edgesPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AllEdgeList, 12)
	_, edges, err := protocol.DecodeAllEdgeList(edgesPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AllEdgeList after dirty restart: %v payload=%x", err, edgesPayload)
	}
	foundEdge := false
	for _, edge := range edges {
		if edge.EdgeID == edgeCreated.Edge.EdgeID {
			foundEdge = true
			if edge.SourceID != assetA.Asset.AssetID || edge.TargetID != taskCreated.Task.ID || edge.Relation != protocol.RelationRelatedTo {
				t.Fatalf("restored dirty-restart edge mismatch: %+v", edge)
			}
		}
	}
	if !foundEdge {
		t.Fatalf("edge id %d missing after dirty restart", edgeCreated.Edge.EdgeID)
	}
}

func TestDirtyRestartTruncatesTrailingShardWALGarbage(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-dirty-tail-%d", time.Now().UnixNano())
	server := startServerInWorkDir(t, serverWorkDir)
	servers := []*serverProcess{server}
	t.Cleanup(func() { cleanupFaultTestServers(t, servers) })

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-dirty-tail-writer"))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect before trailing WAL corruption: %v", err)
	}
	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)
	const roomID int64 = protocol.WorkspaceDataConvID
	const taskTitle = "valid task before trailing garbage"
	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateFullWithCorrelation(roomID, taskTitle, "valid durable prefix", 2, "fault-suite", nil, 0xD1171001)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to create task before trailing WAL corruption: %v", err)
	}
	createdPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	created, err := protocol.DecodeTaskCreated(createdPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode task before trailing WAL corruption: %v", err)
	}
	_ = conn.Close()

	server.killAndWait(t)

	shard := xxhash.Sum64String(workspace) % 256
	walPath := filepath.Join(serverWorkDir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", shard), "active.wal")
	validInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("failed to stat owning shard WAL %q: %v", walPath, err)
	}
	if validInfo.Size() == 0 {
		t.Fatalf("owning shard WAL %q has no durable prefix", walPath)
	}
	const trailingGarbage = "incomplete-real-environment-wal-record"
	wal, err := os.OpenFile(walPath, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatalf("failed to open shard WAL for trailing corruption: %v", err)
	}
	if _, err := wal.WriteString(trailingGarbage); err != nil {
		_ = wal.Close()
		t.Fatalf("failed to append trailing WAL garbage: %v", err)
	}
	if err := wal.Sync(); err != nil {
		_ = wal.Close()
		t.Fatalf("failed to fsync trailing WAL garbage: %v", err)
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("failed to close corrupted shard WAL: %v", err)
	}

	server = startServerInWorkDir(t, serverWorkDir)
	servers = append(servers, server)

	recoveredConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-dirty-tail-reader"))
	if err != nil {
		t.Fatalf("failed to connect after trailing WAL recovery: %v", err)
	}
	defer recoveredConn.Close()
	mustSetReadDeadline(t, recoveredConn, 5*time.Second)
	mustExpectServerReady(t, recoveredConn)

	recoveredInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("failed to stat recovered shard WAL: %v", err)
	}
	if recoveredInfo.Size() != validInfo.Size() {
		t.Fatalf("recovery did not truncate exactly to durable prefix: got=%d want=%d", recoveredInfo.Size(), validInfo.Size())
	}

	if err := sendProtocolMessage(recoveredConn, protocol.C_GetTasks, protocol.EncodeGetTasks(roomID)); err != nil {
		t.Fatalf("failed to list tasks after trailing WAL recovery: %v", err)
	}
	listPayload := mustReadUntilOpcode(t, recoveredConn, protocol.S_TaskListResponse, 12)
	list, err := protocol.DecodeTaskListResponse(listPayload)
	if err != nil {
		t.Fatalf("failed to decode tasks after trailing WAL recovery: %v", err)
	}
	for _, task := range list.Tasks {
		if task.ID == created.Task.ID && task.Title == taskTitle {
			return
		}
	}
	t.Fatalf("durable task %d missing after trailing WAL recovery", created.Task.ID)
}

func TestCompactionCrashBoundariesRecoverExactStateAndContinueWriting(t *testing.T) {
	for _, stage := range []string{"rotation", "checkpoint", "manifest"} {
		t.Run(stage, func(t *testing.T) {
			serverWorkDir := t.TempDir()
			workspace := fmt.Sprintf("e2e-compaction-%s-%d", stage, time.Now().UnixNano())
			server := startServerInWorkDirWithEnv(t, serverWorkDir, map[string]string{
				"NRC_TEST_COMPACTION_PAUSE_STAGE": stage,
			})
			servers := []*serverProcess{server}
			t.Cleanup(func() { cleanupFaultTestServers(t, servers) })

			conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-compaction-writer"))
			if err != nil {
				t.Fatalf("failed to connect before %s crash: %v", stage, err)
			}
			mustSetReadDeadline(t, conn, 10*time.Second)
			mustExpectServerReady(t, conn)

			const roomID int64 = protocol.WorkspaceDataConvID
			if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreate(roomID, "compaction survivor", "initial", 1)); err != nil {
				t.Fatalf("failed to create survivor before %s crash: %v", stage, err)
			}
			createdPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
			created, err := protocol.DecodeTaskCreated(createdPayload)
			if err != nil {
				t.Fatalf("failed to decode survivor before %s crash: %v", stage, err)
			}

			if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreate(roomID, "compaction tombstone", "delete me", 1)); err != nil {
				t.Fatalf("failed to create tombstone before %s crash: %v", stage, err)
			}
			deletedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
			deleted, err := protocol.DecodeTaskCreated(deletedPayload)
			if err != nil {
				t.Fatalf("failed to decode tombstone before %s crash: %v", stage, err)
			}
			if err := sendProtocolMessage(conn, protocol.C_DeleteTask, protocol.EncodeTaskDelete(roomID, int64(deleted.Task.ID))); err != nil {
				t.Fatalf("failed to delete tombstone before %s crash: %v", stage, err)
			}
			_ = mustReadUntilOpcode(t, conn, protocol.S_TaskDeleted, 12)

			markerPath := filepath.Join(serverWorkDir, ".nrc-compaction-fault-stage")
			shard := xxhash.Sum64String(workspace) % 256
			activeWALPath := filepath.Join(serverWorkDir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", shard), "active.wal")
			expectedTitle := "compaction survivor"
			expectedDescription := "initial"
			pendingTitle := ""
			pendingDescription := ""
			thresholdReached := false
			for update := 1; update <= 40; update++ {
				candidateTitle := fmt.Sprintf("compaction survivor %02d", update)
				candidateDescription := fmt.Sprintf("%02d:%s", update, strings.Repeat("x", 1900))
				pendingTitle = candidateTitle
				pendingDescription = candidateDescription
				if err := sendProtocolMessage(conn, protocol.C_UpdateTask, protocol.EncodeTaskUpdate(roomID, int64(created.Task.ID), candidateTitle, candidateDescription, int32(protocol.TaskStatusInProgress), 2, 0)); err != nil {
					t.Fatalf("failed to send churn update %d before %s crash: %v", update, stage, err)
				}
				_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
				updatedPayload, readErr := readUntilOpcode(conn, protocol.S_TaskUpdated, 12)
				if readErr != nil {
					if waitForCompactionFaultMarker(markerPath, stage, 100*time.Millisecond) {
						thresholdReached = true
						break
					}
					t.Fatalf("failed to read churn update %d before %s crash: %v", update, stage, readErr)
				}
				updated, err := protocol.DecodeTaskUpdated(updatedPayload)
				if err != nil || updated.Task.Title != candidateTitle {
					t.Fatalf("invalid churn update %d before %s crash: response=%+v err=%v", update, stage, updated, err)
				}
				expectedTitle = candidateTitle
				expectedDescription = candidateDescription
				pendingTitle = ""
				pendingDescription = ""
				if stage != "rotation" {
					// Let the scheduler durably roll the first batch before writing
					// the second batch that makes the new active WAL eligible to roll.
					if update == 20 {
						time.Sleep(2 * time.Second)
					}
					continue
				}
				activeInfo, statErr := os.Stat(activeWALPath)
				if statErr != nil {
					t.Fatalf("failed to stat active WAL before %s crash: %v", stage, statErr)
				}
				if activeInfo.Size() >= 8192 {
					thresholdReached = true
					break
				}
			}
			if stage != "rotation" {
				thresholdReached = true
			}
			if !thresholdReached {
				t.Fatalf("active WAL did not reach compaction threshold before %s crash", stage)
			}
			if !waitForCompactionFaultMarker(markerPath, stage, 10*time.Second) {
				t.Fatalf("server did not reach compaction %s boundary", stage)
			}

			_ = conn.Close()
			server.killAndWait(t)

			server = startServerInWorkDir(t, serverWorkDir)
			servers = append(servers, server)
			recoveredConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-compaction-reader"))
			if err != nil {
				t.Fatalf("failed to connect after %s crash: %v", stage, err)
			}
			defer recoveredConn.Close()
			mustSetReadDeadline(t, recoveredConn, 10*time.Second)
			mustExpectServerReady(t, recoveredConn)

			if err := sendProtocolMessage(recoveredConn, protocol.C_GetTasks, protocol.EncodeGetTasks(roomID)); err != nil {
				t.Fatalf("failed to list tasks after %s crash: %v", stage, err)
			}
			listPayload := mustReadUntilOpcode(t, recoveredConn, protocol.S_TaskListResponse, 12)
			list, err := protocol.DecodeTaskListResponse(listPayload)
			if err != nil {
				t.Fatalf("failed to decode tasks after %s crash: %v", stage, err)
			}
			stateMatchesAcknowledged := len(list.Tasks) == 1 &&
				list.Tasks[0].ID == created.Task.ID &&
				list.Tasks[0].Title == expectedTitle &&
				list.Tasks[0].Description == expectedDescription &&
				list.Tasks[0].Status == protocol.TaskStatusInProgress
			stateMatchesPending := len(list.Tasks) == 1 &&
				pendingTitle != "" &&
				list.Tasks[0].ID == created.Task.ID &&
				list.Tasks[0].Title == pendingTitle &&
				list.Tasks[0].Description == pendingDescription &&
				list.Tasks[0].Status == protocol.TaskStatusInProgress
			if !stateMatchesAcknowledged && !stateMatchesPending {
				if len(list.Tasks) == 1 {
					t.Fatalf("state after %s crash is not an allowed durable prefix: got_id=%d got_title=%q got_description=%q got_status=%d want_id=%d acknowledged_title=%q pending_title=%q\nrestart logs:\n%s", stage, list.Tasks[0].ID, list.Tasks[0].Title, list.Tasks[0].Description, list.Tasks[0].Status, created.Task.ID, expectedTitle, pendingTitle, server.logs.String())
				}
				t.Fatalf("state after %s crash is not exact: got_count=%d want_id=%d want_title=%q\nrestart logs:\n%s", stage, len(list.Tasks), created.Task.ID, expectedTitle, server.logs.String())
			}
			expectedTitle = list.Tasks[0].Title
			expectedDescription = list.Tasks[0].Description

			continuedTitle := expectedTitle + " continued"
			if err := sendProtocolMessage(recoveredConn, protocol.C_UpdateTask, protocol.EncodeTaskUpdate(roomID, int64(created.Task.ID), continuedTitle, "write after recovery", int32(protocol.TaskStatusDone), 3, 0)); err != nil {
				t.Fatalf("failed continued write after %s crash: %v", stage, err)
			}
			continuedPayload := mustReadUntilOpcode(t, recoveredConn, protocol.S_TaskUpdated, 12)
			continued, err := protocol.DecodeTaskUpdated(continuedPayload)
			if err != nil || continued.Task.Title != continuedTitle {
				t.Fatalf("continued write after %s crash failed: response=%+v err=%v", stage, continued, err)
			}
		})
	}
}

func waitForCompactionFaultMarker(path, stage string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil {
			return string(data) == stage
		}
		time.Sleep(5 * time.Millisecond)
	}
	return false
}

func readUntilOpcode(conn *websocket.Conn, wantOpcode uint16, maxReads int) ([]byte, error) {
	for i := 0; i < maxReads; i++ {
		frameType, wireData, err := conn.ReadMessage()
		if err != nil {
			return nil, err
		}
		if frameType != websocket.BinaryMessage {
			return nil, fmt.Errorf("expected binary frame, got frame type %d", frameType)
		}
		msg, err := protocol.ReadMessage(wireData)
		if err != nil {
			return nil, fmt.Errorf("parse protocol message: %w", err)
		}
		if msg.Opcode == wantOpcode {
			return msg.Data, nil
		}
	}
	return nil, fmt.Errorf("did not receive opcode %d within %d frames", wantOpcode, maxReads)
}

func cleanupFaultTestServers(t *testing.T, servers []*serverProcess) {
	t.Helper()
	for _, server := range servers {
		server.stop(t)
	}
	if t.Failed() {
		for index, server := range servers {
			if server != nil {
				t.Logf("server process %d logs:\n%s", index, server.logs.String())
			}
		}
	}
}
