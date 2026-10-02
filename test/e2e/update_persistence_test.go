package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestTaskAssetEdgeUpdatePersistenceAcrossRestart(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-update-persist-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client before restart: %v", err)
	}

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	taskAttachment := protocol.Attachment{
		FileId:     "e2e-preserve-att-1",
		Filename:   "trace.txt",
		Size:       64,
		MimeType:   "text/plain",
		UploadedAt: 123456789,
	}

	if err := sendProtocolMessage(
		conn,
		protocol.C_CreateTask,
		protocol.EncodeTaskCreateWithAttachments(
			roomID,
			"task-before",
			"desc-before",
			1,
			[]protocol.Attachment{taskAttachment},
		),
	); err != nil {
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
	requireSingleTaskAttachment(t, createdTask.Task, taskAttachment, "created task")

	if err := sendProtocolMessage(
		conn,
		protocol.C_UpdateTask,
		protocol.EncodeTaskUpdate(
			roomID,
			int64(createdTask.Task.ID),
			"task-after",
			"desc-after",
			int32(protocol.TaskStatusDone),
			int32(protocol.TaskColorGold),
			0,
		),
	); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send UpdateTask: %v", err)
	}
	updatedTaskPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskUpdated, 12)
	updatedTask, err := protocol.DecodeTaskUpdated(updatedTaskPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_TaskUpdated payload: %v payload=%x", err, updatedTaskPayload)
	}
	requireSingleTaskAttachment(t, updatedTask.Task, taskAttachment, "updated task")

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "asset-before", "payload-before")); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateAsset: %v", err)
	}
	createdAssetPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	createdAsset, err := protocol.DecodeAssetCreated(createdAssetPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_AssetCreated payload: %v payload=%x", err, createdAssetPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(roomID, createdAsset.Asset.AssetID, "asset-after", "payload-after")); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send UpdateAsset: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 12)

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeDocument, protocol.ParentTypeNone, 0, "asset-peer", "peer-payload")); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send peer CreateAsset: %v", err)
	}
	peerAssetPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	peerAsset, err := protocol.DecodeAssetCreated(peerAssetPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode peer S_AssetCreated payload: %v payload=%x", err, peerAssetPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdge(roomID, protocol.TargetTypeAsset, createdAsset.Asset.AssetID, protocol.TargetTypeAsset, peerAsset.Asset.AssetID, protocol.RelationRelatedTo)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateEdge: %v", err)
	}
	createdEdgePayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 12)
	createdEdge, err := protocol.DecodeEdgeCreated(createdEdgePayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_EdgeCreated payload: %v payload=%x", err, createdEdgePayload)
	}

	// Edge protocol has no C_UpdateEdge; mutate by delete+recreate with a different relation.
	if err := sendProtocolMessage(conn, protocol.C_DeleteEdge, protocol.EncodeDeleteEdge(roomID, createdEdge.Edge.EdgeID)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send DeleteEdge for edge mutation: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_EdgeDeleted, 12)

	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdge(roomID, protocol.TargetTypeAsset, createdAsset.Asset.AssetID, protocol.TargetTypeAsset, peerAsset.Asset.AssetID, protocol.RelationDependsOn)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send recreated CreateEdge: %v", err)
	}
	mutatedEdgePayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 12)
	mutatedEdge, err := protocol.DecodeEdgeCreated(mutatedEdgePayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode recreated S_EdgeCreated payload: %v payload=%x", err, mutatedEdgePayload)
	}

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

	var restoredTask *protocol.Task
	for _, task := range taskList.Tasks {
		if task.ID == createdTask.Task.ID {
			restoredTask = task
			break
		}
	}
	if restoredTask == nil {
		t.Fatalf("updated task id %d missing after restart", createdTask.Task.ID)
	}
	if restoredTask.Title != "task-after" || restoredTask.Description != "desc-after" {
		t.Fatalf("updated task content mismatch after restart: title=%q desc=%q", restoredTask.Title, restoredTask.Description)
	}
	if restoredTask.Status != protocol.TaskStatusDone {
		t.Fatalf("updated task status mismatch after restart: got %d want %d", restoredTask.Status, protocol.TaskStatusDone)
	}
	requireSingleTaskAttachment(t, restoredTask, taskAttachment, "restored task")

	if err := sendProtocolMessage(connAfterRestart, protocol.C_GetAsset, protocol.EncodeGetAsset(roomID, createdAsset.Asset.AssetID)); err != nil {
		t.Fatalf("failed to send GetAsset after restart: %v", err)
	}
	assetPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AssetFull, 12)
	restoredAsset, err := protocol.DecodeAssetFull(assetPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetFull payload after restart: %v payload=%x", err, assetPayload)
	}
	if restoredAsset.Preview != "asset-after" || restoredAsset.Payload != "payload-after" {
		t.Fatalf("updated asset content mismatch after restart: preview=%q payload=%q", restoredAsset.Preview, restoredAsset.Payload)
	}

	if err := sendProtocolMessage(connAfterRestart, protocol.C_ListAllEdges, protocol.EncodeListAllEdges(roomID)); err != nil {
		t.Fatalf("failed to send ListAllEdges after restart: %v", err)
	}
	edgesPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AllEdgeList, 12)
	_, edges, err := protocol.DecodeAllEdgeList(edgesPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AllEdgeList payload after restart: %v payload=%x", err, edgesPayload)
	}

	foundMutatedEdge := false
	foundOldEdge := false
	for i := range edges {
		edge := edges[i]
		if edge.EdgeID == mutatedEdge.Edge.EdgeID {
			foundMutatedEdge = true
			if edge.Relation != protocol.RelationDependsOn {
				t.Fatalf("mutated edge relation mismatch after restart: got %d want %d", edge.Relation, protocol.RelationDependsOn)
			}
		}
		if edge.EdgeID == createdEdge.Edge.EdgeID {
			foundOldEdge = true
		}
	}
	if !foundMutatedEdge {
		t.Fatalf("mutated edge id %d missing after restart", mutatedEdge.Edge.EdgeID)
	}
	if foundOldEdge {
		t.Fatalf("old edge id %d should not exist after restart", createdEdge.Edge.EdgeID)
	}
}

func requireSingleTaskAttachment(t *testing.T, task *protocol.Task, want protocol.Attachment, context string) {
	t.Helper()
	if task == nil {
		t.Fatalf("%s is nil", context)
	}
	if len(task.Attachments) != 1 {
		t.Fatalf("%s attachment count = %d, want 1", context, len(task.Attachments))
	}
	got := task.Attachments[0]
	if got != want {
		t.Fatalf("%s attachment mismatch: got %+v want %+v", context, got, want)
	}
}
