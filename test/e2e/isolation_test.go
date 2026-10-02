package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestWorkspaceIsolationForMessages(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspaceX := fmt.Sprintf("e2e-iso-x-%d", time.Now().UnixNano())
	workspaceY := fmt.Sprintf("e2e-iso-y-%d", time.Now().UnixNano())

	clientA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspaceX), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect client A: %v", err)
	}
	defer clientA.Close()

	clientB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspaceX), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect client B: %v", err)
	}
	defer clientB.Close()

	clientC, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspaceY), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect client C: %v", err)
	}
	defer clientC.Close()

	mustSetReadDeadline(t, clientA, 5*time.Second)
	mustSetReadDeadline(t, clientB, 5*time.Second)
	mustSetReadDeadline(t, clientC, 5*time.Second)

	mustExpectServerReady(t, clientA)
	mustExpectServerReady(t, clientB)
	mustExpectServerReady(t, clientC)

	const roomID int64 = 1
	if err := sendProtocolMessage(clientA, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client A: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientA, 12)
	if err := sendProtocolMessage(clientB, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client B: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientB, 12)
	if err := sendProtocolMessage(clientC, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client C: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientC, 12)

	const reqID uint32 = 77
	content := "workspace scoped message"
	if err := sendProtocolMessage(clientA, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID, content, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send message from client A: %v", err)
	}

	payloadA := mustReadUntilOpcode(t, clientA, protocol.S_AckSendMessage, 12)
	ack, ackErr := protocol.DecodeAckSendMessage(payloadA)
	if ackErr != nil {
		t.Fatalf("failed parsing AckSendMessage payload: %v payload=%x", ackErr, payloadA)
	}
	if ack.ClientReqID != reqID {
		t.Fatalf("ack client_req_id mismatch: got %d want %d", ack.ClientReqID, reqID)
	}

	payloadB := mustReadUntilOpcode(t, clientB, protocol.S_NewMessage, 12)
	msgB, parseErr := protocol.DecodeChatMessage(payloadB)
	if parseErr != nil {
		t.Fatalf("failed parsing NewMessage payload for client B: %v", parseErr)
	}
	if msgB.Content != content {
		t.Fatalf("client B message content mismatch: got %q want %q", msgB.Content, content)
	}

	mustNotReceiveOpcodeWithin(t, clientC, protocol.S_NewMessage, 750*time.Millisecond)
}
