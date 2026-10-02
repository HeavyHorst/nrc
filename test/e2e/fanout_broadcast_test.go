package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestTaskAssetEdgeBroadcastsReachOtherSubscribers(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-fanout-entities-%d", time.Now().UnixNano())

	connA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "fanout-alice"))
	if err != nil {
		t.Fatalf("failed to connect websocket client A: %v", err)
	}
	defer connA.Close()

	connB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "fanout-bob"))
	if err != nil {
		t.Fatalf("failed to connect websocket client B: %v", err)
	}
	defer connB.Close()

	mustSetReadDeadline(t, connA, 20*time.Second)
	mustSetReadDeadline(t, connB, 20*time.Second)
	mustExpectServerReady(t, connA)
	mustExpectServerReady(t, connB)

	const roomID int64 = protocol.WorkspaceDataConvID
	mustSubscribeWorkspaceData(t, connA)
	mustSubscribeWorkspaceData(t, connB)

	if err := sendProtocolMessage(connA, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, "fanout-task", "fanout task description", 1, 0x10010001)); err != nil {
		t.Fatalf("failed to send CreateTask: %v", err)
	}

	taskCreatedAData := mustReadUntilOpcode(t, connA, protocol.S_TaskCreated, 24)
	taskCreatedA, err := protocol.DecodeTaskCreated(taskCreatedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_TaskCreated payload: %v payload=%x", err, taskCreatedAData)
	}
	if taskCreatedA.CorrelationID != 0x10010001 {
		t.Fatalf("sender task create correlation_id mismatch: got 0x%08X want 0x10010001", taskCreatedA.CorrelationID)
	}

	taskCreatedBData := mustReadUntilOpcode(t, connB, protocol.S_TaskCreated, 24)
	taskCreatedB, err := protocol.DecodeTaskCreated(taskCreatedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_TaskCreated payload: %v payload=%x", err, taskCreatedBData)
	}
	if taskCreatedB.CorrelationID != 0 {
		t.Fatalf("broadcast task create correlation_id mismatch: got 0x%08X want 0x00000000", taskCreatedB.CorrelationID)
	}
	if taskCreatedB.Task.ID != taskCreatedA.Task.ID {
		t.Fatalf("broadcast task create id mismatch: got %d want %d", taskCreatedB.Task.ID, taskCreatedA.Task.ID)
	}

	taskID := int64(taskCreatedA.Task.ID)

	if err := sendProtocolMessage(connA, protocol.C_UpdateTask, protocol.EncodeTaskUpdateWithCorrelation(roomID, taskID, "fanout-task-updated", "fanout task description updated", int32(protocol.TaskStatusInProgress), 2, 0, 0x10010002)); err != nil {
		t.Fatalf("failed to send UpdateTask: %v", err)
	}

	taskUpdatedAData := mustReadUntilOpcode(t, connA, protocol.S_TaskUpdated, 24)
	taskUpdatedA, err := protocol.DecodeTaskUpdated(taskUpdatedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_TaskUpdated payload: %v payload=%x", err, taskUpdatedAData)
	}
	if taskUpdatedA.CorrelationID != 0x10010002 {
		t.Fatalf("sender task update correlation_id mismatch: got 0x%08X want 0x10010002", taskUpdatedA.CorrelationID)
	}

	taskUpdatedBData := mustReadUntilOpcode(t, connB, protocol.S_TaskUpdated, 24)
	taskUpdatedB, err := protocol.DecodeTaskUpdated(taskUpdatedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_TaskUpdated payload: %v payload=%x", err, taskUpdatedBData)
	}
	if taskUpdatedB.CorrelationID != 0 {
		t.Fatalf("broadcast task update correlation_id mismatch: got 0x%08X want 0x00000000", taskUpdatedB.CorrelationID)
	}
	if taskUpdatedB.Task.ID != taskUpdatedA.Task.ID {
		t.Fatalf("broadcast task update id mismatch: got %d want %d", taskUpdatedB.Task.ID, taskUpdatedA.Task.ID)
	}
	if taskUpdatedB.Task.Title != "fanout-task-updated" {
		t.Fatalf("broadcast task update title mismatch: got %q", taskUpdatedB.Task.Title)
	}

	if err := sendProtocolMessage(connA, protocol.C_MoveTask, protocol.EncodeTaskMoveWithCorrelation(roomID, taskID, protocol.TaskStatusDone, 7, 0x10010003)); err != nil {
		t.Fatalf("failed to send MoveTask: %v", err)
	}

	taskMovedAData := mustReadUntilOpcode(t, connA, protocol.S_TaskMoved, 24)
	taskMovedA, err := protocol.DecodeTaskMoved(taskMovedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_TaskMoved payload: %v payload=%x", err, taskMovedAData)
	}
	if taskMovedA.CorrelationID != 0x10010003 {
		t.Fatalf("sender task moved correlation_id mismatch: got 0x%08X want 0x10010003", taskMovedA.CorrelationID)
	}

	taskMovedBData := mustReadUntilOpcode(t, connB, protocol.S_TaskMoved, 24)
	taskMovedB, err := protocol.DecodeTaskMoved(taskMovedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_TaskMoved payload: %v payload=%x", err, taskMovedBData)
	}
	if taskMovedB.CorrelationID != 0 {
		t.Fatalf("broadcast task moved correlation_id mismatch: got 0x%08X want 0x00000000", taskMovedB.CorrelationID)
	}
	if taskMovedB.TaskID != taskMovedA.TaskID {
		t.Fatalf("broadcast task moved id mismatch: got %d want %d", taskMovedB.TaskID, taskMovedA.TaskID)
	}
	if taskMovedB.Status != protocol.TaskStatusDone {
		t.Fatalf("broadcast task moved status mismatch: got %d want %d", taskMovedB.Status, protocol.TaskStatusDone)
	}

	if err := sendProtocolMessage(connA, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "fanout-asset", "fanout-asset-payload", 0x20020001)); err != nil {
		t.Fatalf("failed to send CreateAsset: %v", err)
	}

	assetCreatedAData := mustReadUntilOpcode(t, connA, protocol.S_AssetCreated, 24)
	assetCreatedA, err := protocol.DecodeAssetCreated(assetCreatedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_AssetCreated payload: %v payload=%x", err, assetCreatedAData)
	}
	if assetCreatedA.CorrelationID != 0x20020001 {
		t.Fatalf("sender asset create correlation_id mismatch: got 0x%08X want 0x20020001", assetCreatedA.CorrelationID)
	}

	assetCreatedBData := mustReadUntilOpcode(t, connB, protocol.S_AssetCreated, 24)
	assetCreatedB, err := protocol.DecodeAssetCreated(assetCreatedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_AssetCreated payload: %v payload=%x", err, assetCreatedBData)
	}
	if assetCreatedB.CorrelationID != 0 {
		t.Fatalf("broadcast asset create correlation_id mismatch: got 0x%08X want 0x00000000", assetCreatedB.CorrelationID)
	}
	if assetCreatedB.Asset.AssetID != assetCreatedA.Asset.AssetID {
		t.Fatalf("broadcast asset create id mismatch: got %d want %d", assetCreatedB.Asset.AssetID, assetCreatedA.Asset.AssetID)
	}

	assetID := assetCreatedA.Asset.AssetID

	if err := sendProtocolMessage(connA, protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(roomID, assetID, "fanout-asset-updated", "fanout-asset-updated-payload", 0x20020002)); err != nil {
		t.Fatalf("failed to send UpdateAsset: %v", err)
	}

	assetUpdatedAData := mustReadUntilOpcode(t, connA, protocol.S_AssetUpdated, 24)
	assetUpdatedA, err := protocol.DecodeAssetUpdated(assetUpdatedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_AssetUpdated payload: %v payload=%x", err, assetUpdatedAData)
	}
	if assetUpdatedA.CorrelationID != 0x20020002 {
		t.Fatalf("sender asset update correlation_id mismatch: got 0x%08X want 0x20020002", assetUpdatedA.CorrelationID)
	}

	assetUpdatedBData := mustReadUntilOpcode(t, connB, protocol.S_AssetUpdated, 24)
	assetUpdatedB, err := protocol.DecodeAssetUpdated(assetUpdatedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_AssetUpdated payload: %v payload=%x", err, assetUpdatedBData)
	}
	if assetUpdatedB.CorrelationID != 0 {
		t.Fatalf("broadcast asset update correlation_id mismatch: got 0x%08X want 0x00000000", assetUpdatedB.CorrelationID)
	}
	if assetUpdatedB.Asset.AssetID != assetUpdatedA.Asset.AssetID {
		t.Fatalf("broadcast asset update id mismatch: got %d want %d", assetUpdatedB.Asset.AssetID, assetUpdatedA.Asset.AssetID)
	}
	if assetUpdatedB.Asset.Preview != "fanout-asset-updated" {
		t.Fatalf("broadcast asset update preview mismatch: got %q", assetUpdatedB.Asset.Preview)
	}

	if err := sendProtocolMessage(connA, protocol.C_CreateEdge, protocol.EncodeCreateEdgeWithCorrelation(roomID, protocol.TargetTypeTask, uint64(taskID), protocol.TargetTypeAsset, assetID, protocol.RelationRelatedTo, 0x30030001)); err != nil {
		t.Fatalf("failed to send CreateEdge: %v", err)
	}

	edgeCreatedAData := mustReadUntilOpcode(t, connA, protocol.S_EdgeCreated, 24)
	edgeCreatedA, err := protocol.DecodeEdgeCreated(edgeCreatedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_EdgeCreated payload: %v payload=%x", err, edgeCreatedAData)
	}
	if edgeCreatedA.CorrelationID != 0x30030001 {
		t.Fatalf("sender edge create correlation_id mismatch: got 0x%08X want 0x30030001", edgeCreatedA.CorrelationID)
	}

	edgeCreatedBData := mustReadUntilOpcode(t, connB, protocol.S_EdgeCreated, 24)
	edgeCreatedB, err := protocol.DecodeEdgeCreated(edgeCreatedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_EdgeCreated payload: %v payload=%x", err, edgeCreatedBData)
	}
	if edgeCreatedB.CorrelationID != 0 {
		t.Fatalf("broadcast edge create correlation_id mismatch: got 0x%08X want 0x00000000", edgeCreatedB.CorrelationID)
	}
	if edgeCreatedB.Edge.EdgeID != edgeCreatedA.Edge.EdgeID {
		t.Fatalf("broadcast edge create id mismatch: got %d want %d", edgeCreatedB.Edge.EdgeID, edgeCreatedA.Edge.EdgeID)
	}

	edgeID := edgeCreatedA.Edge.EdgeID

	if err := sendProtocolMessage(connA, protocol.C_DeleteEdge, protocol.EncodeDeleteEdgeWithCorrelation(roomID, edgeID, 0x30030002)); err != nil {
		t.Fatalf("failed to send DeleteEdge: %v", err)
	}

	edgeDeletedAData := mustReadUntilOpcode(t, connA, protocol.S_EdgeDeleted, 24)
	edgeDeletedA, err := protocol.DecodeEdgeDeleted(edgeDeletedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_EdgeDeleted payload: %v payload=%x", err, edgeDeletedAData)
	}
	if edgeDeletedA.CorrelationID != 0x30030002 {
		t.Fatalf("sender edge delete correlation_id mismatch: got 0x%08X want 0x30030002", edgeDeletedA.CorrelationID)
	}

	edgeDeletedBData := mustReadUntilOpcode(t, connB, protocol.S_EdgeDeleted, 24)
	edgeDeletedB, err := protocol.DecodeEdgeDeleted(edgeDeletedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_EdgeDeleted payload: %v payload=%x", err, edgeDeletedBData)
	}
	if edgeDeletedB.CorrelationID != 0 {
		t.Fatalf("broadcast edge delete correlation_id mismatch: got 0x%08X want 0x00000000", edgeDeletedB.CorrelationID)
	}
	if edgeDeletedB.EdgeID != edgeDeletedA.EdgeID {
		t.Fatalf("broadcast edge delete id mismatch: got %d want %d", edgeDeletedB.EdgeID, edgeDeletedA.EdgeID)
	}

	if err := sendProtocolMessage(connA, protocol.C_DeleteAsset, protocol.EncodeDeleteAssetWithCorrelation(roomID, assetID, 0x20020003)); err != nil {
		t.Fatalf("failed to send DeleteAsset: %v", err)
	}

	assetDeletedAData := mustReadUntilOpcode(t, connA, protocol.S_AssetDeleted, 24)
	assetDeletedA, err := protocol.DecodeAssetDeleted(assetDeletedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_AssetDeleted payload: %v payload=%x", err, assetDeletedAData)
	}
	if assetDeletedA.CorrelationID != 0x20020003 {
		t.Fatalf("sender asset delete correlation_id mismatch: got 0x%08X want 0x20020003", assetDeletedA.CorrelationID)
	}

	assetDeletedBData := mustReadUntilOpcode(t, connB, protocol.S_AssetDeleted, 24)
	assetDeletedB, err := protocol.DecodeAssetDeleted(assetDeletedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_AssetDeleted payload: %v payload=%x", err, assetDeletedBData)
	}
	if assetDeletedB.CorrelationID != 0 {
		t.Fatalf("broadcast asset delete correlation_id mismatch: got 0x%08X want 0x00000000", assetDeletedB.CorrelationID)
	}
	if assetDeletedB.AssetID != assetDeletedA.AssetID {
		t.Fatalf("broadcast asset delete id mismatch: got %d want %d", assetDeletedB.AssetID, assetDeletedA.AssetID)
	}

	if err := sendProtocolMessage(connA, protocol.C_DeleteTask, protocol.EncodeTaskDeleteWithCorrelation(roomID, taskID, 0x10010004)); err != nil {
		t.Fatalf("failed to send DeleteTask: %v", err)
	}

	taskDeletedAData := mustReadUntilOpcode(t, connA, protocol.S_TaskDeleted, 24)
	taskDeletedA, err := protocol.DecodeTaskDeleted(taskDeletedAData)
	if err != nil {
		t.Fatalf("failed to decode sender S_TaskDeleted payload: %v payload=%x", err, taskDeletedAData)
	}
	if taskDeletedA.CorrelationID != 0x10010004 {
		t.Fatalf("sender task delete correlation_id mismatch: got 0x%08X want 0x10010004", taskDeletedA.CorrelationID)
	}

	taskDeletedBData := mustReadUntilOpcode(t, connB, protocol.S_TaskDeleted, 24)
	taskDeletedB, err := protocol.DecodeTaskDeleted(taskDeletedBData)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_TaskDeleted payload: %v payload=%x", err, taskDeletedBData)
	}
	if taskDeletedB.CorrelationID != 0 {
		t.Fatalf("broadcast task delete correlation_id mismatch: got 0x%08X want 0x00000000", taskDeletedB.CorrelationID)
	}
	if taskDeletedB.TaskID != taskDeletedA.TaskID {
		t.Fatalf("broadcast task delete id mismatch: got %d want %d", taskDeletedB.TaskID, taskDeletedA.TaskID)
	}
}
