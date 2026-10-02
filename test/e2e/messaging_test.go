package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestTwoClientMessageDeliveryAndAck(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-chat-%d", time.Now().UnixNano())
	const userA = "e2e-alice"
	const userB = "e2e-bob"

	clientA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, userA))
	if err != nil {
		t.Fatalf("failed to connect client A: %v", err)
	}
	defer clientA.Close()

	clientB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, userB))
	if err != nil {
		t.Fatalf("failed to connect client B: %v", err)
	}
	defer clientB.Close()

	mustSetReadDeadline(t, clientA, 5*time.Second)
	mustSetReadDeadline(t, clientB, 5*time.Second)

	mustExpectServerReady(t, clientA)
	mustExpectServerReady(t, clientB)

	const roomID int64 = 1
	if err := sendProtocolMessage(clientA, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client A: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientA, 12)
	if err := sendProtocolMessage(clientB, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client B: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientB, 12)

	const reqID uint32 = 42
	testContent := "hello from e2e two-client test"
	if err := sendProtocolMessage(clientA, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID, testContent, protocol.ContentTypePlainText)); err != nil {
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
	if ack.AssignedSeq == 0 {
		t.Fatalf("ack assigned sequence is zero; expected a valid sequence")
	}

	payloadB := mustReadUntilOpcode(t, clientB, protocol.S_NewMessage, 12)
	gotMessage, msgErr := protocol.DecodeChatMessage(payloadB)
	if msgErr != nil {
		t.Fatalf("failed parsing NewMessage payload: %v payload=%x", msgErr, payloadB)
	}
	if gotMessage.ConvID != int64(roomID) {
		t.Fatalf("new message conv_id mismatch: got %d want %d", gotMessage.ConvID, roomID)
	}
	if gotMessage.Username != userA {
		t.Fatalf("new message author mismatch: got %q want %q", gotMessage.Username, userA)
	}
	if gotMessage.Content != testContent {
		t.Fatalf("new message content mismatch: got %q want %q", gotMessage.Content, testContent)
	}
}

func TestUnsubscribeStopsDelivery(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-unsub-%d", time.Now().UnixNano())
	clientA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-unsub-alice"))
	if err != nil {
		t.Fatalf("failed to connect client A: %v", err)
	}
	defer clientA.Close()

	clientB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-unsub-bob"))
	if err != nil {
		t.Fatalf("failed to connect client B: %v", err)
	}
	defer clientB.Close()

	mustSetReadDeadline(t, clientA, 5*time.Second)
	mustSetReadDeadline(t, clientB, 5*time.Second)

	mustExpectServerReady(t, clientA)
	mustExpectServerReady(t, clientB)

	const roomID int64 = 1
	if err := sendProtocolMessage(clientA, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client A: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientA, 12)
	if err := sendProtocolMessage(clientB, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe client B: %v", err)
	}
	mustWaitForPresenceUpdate(t, clientB, 12)

	const reqID1 uint32 = 100
	msg1 := "message before unsubscribe"
	if err := sendProtocolMessage(clientA, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID1, msg1, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send first message from client A: %v", err)
	}

	payloadAck1 := mustReadUntilOpcode(t, clientA, protocol.S_AckSendMessage, 12)
	ack1, ackErr := protocol.DecodeAckSendMessage(payloadAck1)
	if ackErr != nil {
		t.Fatalf("failed parsing first AckSendMessage payload: %v payload=%x", ackErr, payloadAck1)
	}
	if ack1.ClientReqID != reqID1 {
		t.Fatalf("first ack client_req_id mismatch: got %d want %d", ack1.ClientReqID, reqID1)
	}

	payloadB1 := mustReadUntilOpcode(t, clientB, protocol.S_NewMessage, 12)
	decodedB1, parseErr := protocol.DecodeChatMessage(payloadB1)
	if parseErr != nil {
		t.Fatalf("failed parsing first NewMessage for client B: %v", parseErr)
	}
	if decodedB1.Content != msg1 {
		t.Fatalf("first message content mismatch for client B: got %q want %q", decodedB1.Content, msg1)
	}

	const unsubscribeCorrelation uint32 = 0x554e5355
	if err := sendProtocolMessage(clientB, protocol.C_UnsubscribeConvs, protocol.EncodeUnsubscribeConvsWithCorrelation(unsubscribeCorrelation, roomID)); err != nil {
		t.Fatalf("failed to unsubscribe client B: %v", err)
	}
	payloadUnsubscribeAck := mustReadUntilOpcode(t, clientB, protocol.S_AckUnsubscribeConvs, 12)
	unsubAck, err := protocol.DecodeAckUnsubscribeConvs(payloadUnsubscribeAck)
	if err != nil {
		t.Fatalf("failed parsing unsubscribe acknowledgment: %v payload=%x", err, payloadUnsubscribeAck)
	}
	if unsubAck.CorrelationID != unsubscribeCorrelation {
		t.Fatalf("unsubscribe correlation mismatch: got %d want %d", unsubAck.CorrelationID, unsubscribeCorrelation)
	}

	const reqID2 uint32 = 101
	msg2 := "message after unsubscribe"
	if err := sendProtocolMessage(clientA, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID2, msg2, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send second message from client A: %v", err)
	}

	payloadAck2 := mustReadUntilOpcode(t, clientA, protocol.S_AckSendMessage, 12)
	ack2, ackErr := protocol.DecodeAckSendMessage(payloadAck2)
	if ackErr != nil {
		t.Fatalf("failed parsing second AckSendMessage payload: %v payload=%x", ackErr, payloadAck2)
	}
	if ack2.ClientReqID != reqID2 {
		t.Fatalf("second ack client_req_id mismatch: got %d want %d", ack2.ClientReqID, reqID2)
	}

	mustNotReceiveOpcodeWithin(t, clientB, protocol.S_NewMessage, 750*time.Millisecond)
}
