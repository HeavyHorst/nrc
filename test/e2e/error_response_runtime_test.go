package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func mustReadErrorResponse(t *testing.T, conn *websocket.Conn, originOpcode uint16, correlationID uint32) *protocol.ErrorResponse {
	t.Helper()

	payload := mustReadUntilOpcode(t, conn, protocol.S_ErrorResponse, 12)
	errResp, err := protocol.DecodeErrorResponse(payload)
	if err != nil {
		t.Fatalf("failed to decode S_ErrorResponse payload: %v payload=%x", err, payload)
	}
	if errResp.OriginOpcode != originOpcode {
		t.Fatalf("error response origin opcode mismatch: got %d want %d", errResp.OriginOpcode, originOpcode)
	}
	if errResp.CorrelationID != correlationID {
		t.Fatalf("error response correlation_id mismatch: got 0x%08X want 0x%08X", errResp.CorrelationID, correlationID)
	}
	if errResp.ErrorMessage == "" {
		t.Fatalf("expected non-empty error message")
	}

	return errResp
}

func TestErrorResponseAssetUpdateNotFound(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-asset-update-not-found-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "alice"))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 15*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "seed", "seed payload", 0xAA110001)); err != nil {
		t.Fatalf("failed to send CreateAsset: %v", err)
	}
	createdPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	created, err := protocol.DecodeAssetCreated(createdPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetCreated payload: %v payload=%x", err, createdPayload)
	}

	missingID := created.Asset.AssetID + 9999
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(roomID, missingID, "upd", "upd payload", 0xAA110002)); err != nil {
		t.Fatalf("failed to send UpdateAsset(missing): %v", err)
	}

	mustReadErrorResponse(t, conn, protocol.C_UpdateAsset, 0xAA110002)
}

func TestErrorResponseAssetUpdateNotFoundStaleCorrelationSafe(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-asset-update-not-found-stale-corr-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "alice"))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 15*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "seed", "seed payload", 0xAA120001)); err != nil {
		t.Fatalf("failed to send CreateAsset: %v", err)
	}
	createdPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	created, err := protocol.DecodeAssetCreated(createdPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetCreated payload: %v payload=%x", err, createdPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(roomID, created.Asset.AssetID, "ok", "ok payload", 0xAA120002)); err != nil {
		t.Fatalf("failed to send UpdateAsset(existing): %v", err)
	}
	updatedPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 12)
	updated, err := protocol.DecodeAssetUpdated(updatedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetUpdated payload: %v payload=%x", err, updatedPayload)
	}
	if updated.CorrelationID != 0xAA120002 {
		t.Fatalf("asset update correlation_id mismatch: got 0x%08X want 0xAA120002", updated.CorrelationID)
	}

	missingID := created.Asset.AssetID + 1_000_000
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(roomID, missingID, "missing", "missing payload", 0xAA120003)); err != nil {
		t.Fatalf("failed to send UpdateAsset(missing): %v", err)
	}

	// Ensure the runtime error uses the latest correlation and doesn't accidentally reuse the prior successful one.
	mustReadErrorResponse(t, conn, protocol.C_UpdateAsset, 0xAA120003)
}

func TestErrorResponseEdgeFailures(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-edge-errors-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "alice"))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 15*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, "edge-self", "edge-self-desc", 1, 0xBB220001)); err != nil {
		t.Fatalf("failed to send CreateTask: %v", err)
	}
	taskCreatedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	taskCreated, err := protocol.DecodeTaskCreated(taskCreatedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskCreated payload: %v payload=%x", err, taskCreatedPayload)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdgeWithCorrelation(roomID, protocol.TargetTypeTask, taskCreated.Task.ID, protocol.TargetTypeTask, taskCreated.Task.ID, protocol.RelationRelatedTo, 0xBB220002)); err != nil {
		t.Fatalf("failed to send CreateEdge(self): %v", err)
	}
	mustReadErrorResponse(t, conn, protocol.C_CreateEdge, 0xBB220002)

	if err := sendProtocolMessage(conn, protocol.C_DeleteEdge, protocol.EncodeDeleteEdgeWithCorrelation(roomID, 0xDEADBEEF, 0xBB220003)); err != nil {
		t.Fatalf("failed to send DeleteEdge(missing): %v", err)
	}
	mustReadErrorResponse(t, conn, protocol.C_DeleteEdge, 0xBB220003)
}

func TestErrorResponseInvalidOpcode(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-invalid-opcode-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "alice"))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 10*time.Second)
	mustExpectServerReady(t, conn)

	if err := sendProtocolMessage(conn, 0xFFFF, nil); err != nil {
		t.Fatalf("failed to send invalid opcode payload: %v", err)
	}

	mustReadErrorResponse(t, conn, 0xFFFF, 0)
}
