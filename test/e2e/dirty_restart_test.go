package e2e

import (
	"fmt"
	"os"
	"path/filepath"
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

func TestDirtyRestartIgnoresIncompleteSQLiteWALTail(t *testing.T) {
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
	walPath := filepath.Join(serverWorkDir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", shard), "workspace.sqlite3-wal")
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
