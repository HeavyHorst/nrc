package e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestFragmentedSendMessageAckAndDelivery(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-fragmented-send-%d", time.Now().UnixNano())

	fragmentDialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
		ReadBufferSize:   256,
		WriteBufferSize:  64,
	}

	clientA, _, err := fragmentDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
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

	content := strings.Repeat("f", protocol.MaxAllowedContentLength-1)
	const reqID uint32 = 77701
	if err := sendProtocolMessageChunked(clientA, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID, content, protocol.ContentTypePlainText), 32); err != nil {
		t.Fatalf("failed to send chunked fragmented C_SendMessage: %v", err)
	}

	mustSetReadDeadline(t, clientA, 30*time.Second)
	mustSetReadDeadline(t, clientB, 30*time.Second)

	ackPayload := mustReadUntilOpcode(t, clientA, protocol.S_AckSendMessage, 128)
	ack, err := protocol.DecodeAckSendMessage(ackPayload)
	if err != nil {
		t.Fatalf("failed to decode ack from fragmented send: %v payload=%x", err, ackPayload)
	}
	if ack.ClientReqID != reqID {
		t.Fatalf("fragmented ack req id mismatch: got %d want %d", ack.ClientReqID, reqID)
	}

	newMessagePayload := mustReadUntilOpcode(t, clientB, protocol.S_NewMessage, 128)
	newMessage, err := protocol.DecodeChatMessage(newMessagePayload)
	if err != nil {
		t.Fatalf("failed to decode S_NewMessage from fragmented send: %v payload=%x", err, newMessagePayload)
	}
	if newMessage.Content != content {
		t.Fatalf("fragmented delivered message content mismatch")
	}
}
