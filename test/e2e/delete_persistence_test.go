package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestDeletePersistenceAcrossRestart(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-delete-persist-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client before restart: %v", err)
	}

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID

	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreate(roomID, "task-to-delete", "task-desc", 1)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateTask: %v", err)
	}
	createdTaskPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	createdTask, err := protocol.DecodeTaskCreated(createdTaskPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_TaskCreated payload: %v payload=%x", err, createdTaskPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "asset-a", "payload-a")); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send first CreateAsset: %v", err)
	}
	assetAPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	assetA, err := protocol.DecodeAssetCreated(assetAPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode first S_AssetCreated payload: %v payload=%x", err, assetAPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeDocument, protocol.ParentTypeNone, 0, "asset-b", "payload-b")); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send second CreateAsset: %v", err)
	}
	assetBPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	assetB, err := protocol.DecodeAssetCreated(assetBPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode second S_AssetCreated payload: %v payload=%x", err, assetBPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdge(roomID, protocol.TargetTypeAsset, assetA.Asset.AssetID, protocol.TargetTypeAsset, assetB.Asset.AssetID, protocol.RelationReferences)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateEdge: %v", err)
	}
	edgePayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 12)
	createdEdge, err := protocol.DecodeEdgeCreated(edgePayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_EdgeCreated payload: %v payload=%x", err, edgePayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_DeleteEdge, protocol.EncodeDeleteEdge(roomID, createdEdge.Edge.EdgeID)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send DeleteEdge: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_EdgeDeleted, 12)

	if err := sendProtocolMessage(conn, protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(roomID, assetA.Asset.AssetID)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send first DeleteAsset: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_AssetDeleted, 12)

	if err := sendProtocolMessage(conn, protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(roomID, assetB.Asset.AssetID)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send second DeleteAsset: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_AssetDeleted, 12)

	if err := sendProtocolMessage(conn, protocol.C_DeleteTask, protocol.EncodeTaskDelete(roomID, int64(createdTask.Task.ID))); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send DeleteTask: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_TaskDeleted, 12)

	_ = conn.Close()
	server.stop(t)

	server = startServerInWorkDir(t, serverWorkDir)
	defer server.stop(t)

	connAfterRestart, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client after restart: %v", err)
	}
	defer connAfterRestart.Close()

	mustSetReadDeadline(t, connAfterRestart, 5*time.Second)
	mustExpectServerReady(t, connAfterRestart)

	if err := sendProtocolMessage(connAfterRestart, protocol.C_GetTasks, protocol.EncodeGetTasks(roomID)); err != nil {
		t.Fatalf("failed to send GetTasks after restart: %v", err)
	}
	taskListPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_TaskListResponse, 12)
	taskList, err := protocol.DecodeTaskListResponse(taskListPayload)
	if err != nil {
		t.Fatalf("failed to decode TaskListResponse after restart: %v payload=%x", err, taskListPayload)
	}
	for _, task := range taskList.Tasks {
		if task.ID == createdTask.Task.ID {
			t.Fatalf("deleted task id %d still present after restart", createdTask.Task.ID)
		}
	}

	if err := sendProtocolMessage(connAfterRestart, protocol.C_ListAssets, protocol.EncodeListAssets(roomID, false, 0, true)); err != nil {
		t.Fatalf("failed to send ListAssets after restart: %v", err)
	}
	assetsPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AssetList, 12)
	assets, err := protocol.DecodeAssetList(assetsPayload, true)
	if err != nil {
		t.Fatalf("failed to decode S_AssetList payload after restart: %v payload=%x", err, assetsPayload)
	}
	for _, asset := range assets {
		if asset.AssetID == assetA.Asset.AssetID || asset.AssetID == assetB.Asset.AssetID {
			t.Fatalf("deleted asset still present after restart: asset_id=%d", asset.AssetID)
		}
	}

	if err := sendProtocolMessage(connAfterRestart, protocol.C_ListAllEdges, protocol.EncodeListAllEdges(roomID)); err != nil {
		t.Fatalf("failed to send ListAllEdges after restart: %v", err)
	}
	edgesPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AllEdgeList, 12)
	_, edges, err := protocol.DecodeAllEdgeList(edgesPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AllEdgeList payload after restart: %v payload=%x", err, edgesPayload)
	}
	for i := range edges {
		if edges[i].EdgeID == createdEdge.Edge.EdgeID {
			t.Fatalf("deleted edge id %d still present after restart", createdEdge.Edge.EdgeID)
		}
	}
}
