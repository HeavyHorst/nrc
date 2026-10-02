package e2e

import (
	"encoding/binary"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestRetainedMessageSurvivesRestartAndDeduplicates(t *testing.T) {
	workDir := t.TempDir()
	retentionEnv := map[string]string{"NRC_MESSAGE_RETENTION": "24h", "NRC_MESSAGE_DEDUP_WINDOW": "5m"}
	server := startServerInWorkDirWithEnv(t, workDir, retentionEnv)

	const workspace = "e2e-retained-messages"
	const roomID uint64 = 2
	var clientID protocol.ClientMessageID
	copy(clientID[:], []byte("stable-message-1"))

	connect := func() *websocket.Conn {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "retained-alice"))
		if err != nil {
			t.Fatalf("connect retained client: %v", err)
		}
		mustSetReadDeadline(t, conn, 20*time.Second)
		mustExpectServerReady(t, conn)
		subscribe, err := protocol.EncodeSubscribeConvsV2(0x1001, roomID)
		if err != nil {
			t.Fatalf("encode retained subscription: %v", err)
		}
		if err := sendProtocolMessage(conn, protocol.C_SubscribeConvsV2, subscribe); err != nil {
			t.Fatalf("send retained subscription: %v", err)
		}
		readyPayload := mustReadUntilOpcode(t, conn, protocol.S_SubscriptionReady, 16)
		ready, err := protocol.DecodeSubscriptionReady(readyPayload)
		if err != nil || len(ready.Entries) != 1 || ready.Entries[0].ConvID != roomID {
			t.Fatalf("invalid subscription-ready payload: ready=%+v err=%v", ready, err)
		}
		return conn
	}

	conn := connect()
	sendPayload, err := protocol.EncodeSendMessageV2(roomID, clientID, 0x2001, protocol.ContentTypePlainText, "retained hello")
	if err != nil {
		t.Fatalf("encode retained message: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_SendMessageV2, sendPayload); err != nil {
		t.Fatalf("send retained message: %v", err)
	}
	ackPayload := mustReadUntilOpcode(t, conn, protocol.S_AckSendMessage, 16)
	ack, err := protocol.DecodeAckSendMessage(ackPayload)
	if err != nil || ack.AssignedSeq == 0 {
		t.Fatalf("invalid retained message ack: ack=%+v err=%v", ack, err)
	}
	originalSeq := ack.AssignedSeq
	var secondID protocol.ClientMessageID
	copy(secondID[:], []byte("stable-message-2"))
	secondPayload, err := protocol.EncodeSendMessageV2(roomID, secondID, 0x2002, protocol.ContentTypePlainText, "retained second")
	if err != nil {
		t.Fatalf("encode second retained message: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_SendMessageV2, secondPayload); err != nil {
		t.Fatalf("send second retained message: %v", err)
	}
	secondAckPayload := mustReadUntilOpcode(t, conn, protocol.S_AckSendMessage, 16)
	secondAck, err := protocol.DecodeAckSendMessage(secondAckPayload)
	if err != nil || secondAck.AssignedSeq <= originalSeq {
		t.Fatalf("invalid second retained ack: ack=%+v err=%v", secondAck, err)
	}
	_ = conn.Close()
	server.stop(t)

	server = startServerInWorkDirWithEnv(t, workDir, retentionEnv)
	defer server.stop(t)
	conn = connect()
	defer conn.Close()

	historyPayload, err := protocol.EncodeListMessagesBefore(roomID, 0, 100, 0x3001)
	if err != nil {
		t.Fatalf("encode retained history request: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_ListMessagesBefore, historyPayload); err != nil {
		t.Fatalf("send retained history request: %v", err)
	}
	pagePayload := mustReadUntilOpcode(t, conn, protocol.S_MessagePage, 16)
	page, err := protocol.DecodeMessagePage(pagePayload)
	if err != nil || len(page.Messages) != 2 || page.Messages[0].Content != "retained second" || page.Messages[1].Sequence != uint64(originalSeq) || page.Messages[1].Content != "retained hello" || page.Messages[1].ClientMessageID != clientID {
		t.Fatalf("unexpected retained page: page=%+v err=%v logs=%s", page, err, server.logs.String())
	}

	// Retry after recovery: the original sequence is acknowledged and no second record is appended.
	if err := sendProtocolMessage(conn, protocol.C_SendMessageV2, sendPayload); err != nil {
		t.Fatalf("retry retained message: %v", err)
	}
	retryAckPayload := mustReadUntilOpcode(t, conn, protocol.S_AckSendMessage, 16)
	retryAck, err := protocol.DecodeAckSendMessage(retryAckPayload)
	if err != nil || retryAck.AssignedSeq != originalSeq || binary.BigEndian.Uint32(retryAckPayload[:4]) != 0x2001 {
		t.Fatalf("retry did not return original identity: ack=%+v err=%v", retryAck, err)
	}
}
