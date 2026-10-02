package e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestLargeBoundaryPayloads(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-boundary-%d", time.Now().UnixNano())

	clientA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect client A: %v", err)
	}
	defer clientA.Close()

	clientB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect client B: %v", err)
	}
	defer clientB.Close()

	mustSetReadDeadline(t, clientA, 10*time.Second)
	mustSetReadDeadline(t, clientB, 10*time.Second)

	mustExpectServerReady(t, clientA)
	mustExpectServerReady(t, clientB)

	const roomID int64 = 1
	if err := sendProtocolMessage(clientA, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client A: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientA, 16)
	if err := sendProtocolMessage(clientB, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client B: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientB, 16)

	boundaryMessageLen := protocol.MaxAllowedContentLength - 1
	content := strings.Repeat("m", boundaryMessageLen)
	const reqID uint32 = 9001
	if err := sendProtocolMessage(clientA, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID, content, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send boundary C_SendMessage: %v", err)
	}

	mustSetReadDeadline(t, clientA, 30*time.Second)
	mustSetReadDeadline(t, clientB, 30*time.Second)

	ackPayload := mustReadUntilOpcode(t, clientA, protocol.S_AckSendMessage, 128)
	ack, err := protocol.DecodeAckSendMessage(ackPayload)
	if err != nil {
		t.Fatalf("failed to decode boundary AckSendMessage: %v payload=%x", err, ackPayload)
	}
	if ack.ClientReqID != reqID {
		t.Fatalf("boundary ack req id mismatch: got %d want %d", ack.ClientReqID, reqID)
	}

	newMessagePayload := mustReadUntilOpcode(t, clientB, protocol.S_NewMessage, 128)
	newMessage, err := protocol.DecodeChatMessage(newMessagePayload)
	if err != nil {
		t.Fatalf("failed to decode boundary S_NewMessage: %v payload=%x", err, newMessagePayload)
	}
	if len(newMessage.Content) != boundaryMessageLen {
		t.Fatalf("boundary message length mismatch: got %d want %d", len(newMessage.Content), boundaryMessageLen)
	}
	if newMessage.Content != content {
		t.Fatalf("boundary message content mismatch")
	}

	taskTitle := strings.Repeat("t", protocol.MaxTaskTitleLength)
	taskDescription := strings.Repeat("d", protocol.MaxTaskDescriptionLength)
	if err := sendProtocolMessage(clientA, protocol.C_CreateTask, protocol.EncodeTaskCreate(protocol.WorkspaceDataConvID, taskTitle, taskDescription, 1)); err != nil {
		t.Fatalf("failed to send boundary C_CreateTask: %v", err)
	}
	taskCreatedPayload := mustReadUntilOpcode(t, clientA, protocol.S_TaskCreated, 128)
	taskCreated, err := protocol.DecodeTaskCreated(taskCreatedPayload)
	if err != nil {
		t.Fatalf("failed to decode boundary S_TaskCreated: %v payload=%x", err, taskCreatedPayload)
	}
	if len(taskCreated.Task.Title) != protocol.MaxTaskTitleLength {
		t.Fatalf("boundary task title length mismatch: got %d want %d", len(taskCreated.Task.Title), protocol.MaxTaskTitleLength)
	}
	if len(taskCreated.Task.Description) != protocol.MaxTaskDescriptionLength {
		t.Fatalf("boundary task description length mismatch: got %d want %d", len(taskCreated.Task.Description), protocol.MaxTaskDescriptionLength)
	}

	assetPreview := strings.Repeat("p", protocol.MaxPreviewLength)
	boundaryAssetPayloadLen := protocol.MaxPayloadLength - 1
	assetPayload := strings.Repeat("x", boundaryAssetPayloadLen)
	if err := sendProtocolMessage(clientA, protocol.C_CreateAsset, protocol.EncodeCreateAsset(protocol.WorkspaceDataConvID, protocol.AssetTypeDocument, protocol.ParentTypeNone, 0, assetPreview, assetPayload)); err != nil {
		t.Fatalf("failed to send boundary C_CreateAsset: %v", err)
	}
	assetCreatedPayload := mustReadUntilOpcode(t, clientA, protocol.S_AssetCreated, 128)
	assetCreated, err := protocol.DecodeAssetCreated(assetCreatedPayload)
	if err != nil {
		t.Fatalf("failed to decode boundary S_AssetCreated: %v payload=%x", err, assetCreatedPayload)
	}
	if len(assetCreated.Asset.Preview) != protocol.MaxPreviewLength {
		t.Fatalf("boundary asset preview length mismatch: got %d want %d", len(assetCreated.Asset.Preview), protocol.MaxPreviewLength)
	}
	if len(assetCreated.Asset.Payload) != boundaryAssetPayloadLen {
		t.Fatalf("boundary asset payload length mismatch: got %d want %d", len(assetCreated.Asset.Payload), boundaryAssetPayloadLen)
	}
}
