package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestDMMessageDeliveryUsesDMConversationID(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-dm-delivery-%d", time.Now().UnixNano())
	const aliceUsername = "e2e-dm-delivery-alice"
	const bobUsername = "e2e-dm-delivery-bob"

	aliceConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to connect alice websocket client: %v", err)
	}
	defer aliceConn.Close()

	bobConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to connect bob websocket client: %v", err)
	}
	defer bobConn.Close()

	mustSetReadDeadline(t, aliceConn, 30*time.Second)
	mustSetReadDeadline(t, bobConn, 30*time.Second)
	mustExpectServerReady(t, aliceConn)
	mustExpectServerReady(t, bobConn)

	if err := sendProtocolMessage(aliceConn, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation(bobUsername, 0xD0010001)); err != nil {
		t.Fatalf("failed to send StartDM from alice: %v", err)
	}

	dmStartedAlicePayload := mustReadUntilOpcode(t, aliceConn, protocol.S_DMStarted, 32)
	dmStartedAlice, err := protocol.DecodeDMStarted(dmStartedAlicePayload)
	if err != nil {
		t.Fatalf("failed to decode alice S_DMStarted payload: %v payload=%x", err, dmStartedAlicePayload)
	}
	if dmStartedAlice.CorrelationID != 0xD0010001 {
		t.Fatalf("alice dm started correlation_id mismatch: got 0x%08X want 0xD0010001", dmStartedAlice.CorrelationID)
	}
	if dmStartedAlice.Username != bobUsername {
		t.Fatalf("alice dm started partner mismatch: got %q want %q", dmStartedAlice.Username, bobUsername)
	}
	if !dmStartedAlice.Authenticated || !dmStartedAlice.Online {
		t.Fatalf("alice dm started partner status mismatch: authenticated=%v online=%v", dmStartedAlice.Authenticated, dmStartedAlice.Online)
	}
	if !dmStartedAlice.IsInitiator {
		t.Fatalf("alice should be DM initiator")
	}
	if dmStartedAlice.ConvID&protocol.DMConvFlag == 0 {
		t.Fatalf("dm started conv_id missing DM flag: conv_id=%d", dmStartedAlice.ConvID)
	}

	dmStartedBobPayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMStarted, 32)
	dmStartedBob, err := protocol.DecodeDMStarted(dmStartedBobPayload)
	if err != nil {
		t.Fatalf("failed to decode bob S_DMStarted payload: %v payload=%x", err, dmStartedBobPayload)
	}
	if dmStartedBob.ConvID != dmStartedAlice.ConvID {
		t.Fatalf("bob dm started conv_id mismatch: got %d want %d", dmStartedBob.ConvID, dmStartedAlice.ConvID)
	}
	if dmStartedBob.Username != aliceUsername {
		t.Fatalf("bob dm started partner mismatch: got %q want %q", dmStartedBob.Username, aliceUsername)
	}
	if dmStartedBob.IsInitiator {
		t.Fatalf("bob should not be DM initiator")
	}

	const reqID uint32 = 0xD0010002
	const dmContent = "dm payload should route through dm conv_id"
	if err := sendProtocolMessage(aliceConn, protocol.C_SendMessage, protocol.EncodeSendMessage(int64(dmStartedAlice.ConvID), reqID, dmContent, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send C_SendMessage to DM conversation: %v", err)
	}

	ackPayload := mustReadUntilOpcode(t, aliceConn, protocol.S_AckSendMessage, 32)
	ack, err := protocol.DecodeAckSendMessage(ackPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AckSendMessage payload: %v payload=%x", err, ackPayload)
	}
	if ack.ClientReqID != reqID {
		t.Fatalf("ack client_req_id mismatch: got %d want %d", ack.ClientReqID, reqID)
	}

	newMessagePayload := mustReadUntilOpcode(t, bobConn, protocol.S_NewMessage, 32)
	delivered, err := protocol.DecodeChatMessage(newMessagePayload)
	if err != nil {
		t.Fatalf("failed to decode S_NewMessage payload: %v payload=%x", err, newMessagePayload)
	}
	if uint64(delivered.ConvID) != dmStartedAlice.ConvID {
		t.Fatalf("dm message conv_id mismatch: got %d want %d", uint64(delivered.ConvID), dmStartedAlice.ConvID)
	}
	if delivered.Username != aliceUsername {
		t.Fatalf("dm message author mismatch: got %q want %q", delivered.Username, aliceUsername)
	}
	if delivered.Content != dmContent {
		t.Fatalf("dm message content mismatch: got %q want %q", delivered.Content, dmContent)
	}
}

func TestDMReconnectListAndDelivery(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-dm-reconnect-%d", time.Now().UnixNano())
	const aliceUsername = "e2e-dm-reconnect-alice"
	const bobUsername = "e2e-dm-reconnect-bob"

	aliceConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to connect alice websocket client: %v", err)
	}
	defer aliceConn.Close()

	bobPrimaryConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to connect bob primary websocket client: %v", err)
	}

	mustSetReadDeadline(t, aliceConn, 30*time.Second)
	mustSetReadDeadline(t, bobPrimaryConn, 30*time.Second)
	mustExpectServerReady(t, aliceConn)
	mustExpectServerReady(t, bobPrimaryConn)

	if err := sendProtocolMessage(aliceConn, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation(bobUsername, 0xD0020001)); err != nil {
		t.Fatalf("failed to send StartDM from alice: %v", err)
	}

	dmStartedAlicePayload := mustReadUntilOpcode(t, aliceConn, protocol.S_DMStarted, 32)
	dmStartedAlice, err := protocol.DecodeDMStarted(dmStartedAlicePayload)
	if err != nil {
		t.Fatalf("failed to decode alice S_DMStarted payload: %v payload=%x", err, dmStartedAlicePayload)
	}
	if dmStartedAlice.CorrelationID != 0xD0020001 {
		t.Fatalf("alice dm started correlation_id mismatch: got 0x%08X want 0xD0020001", dmStartedAlice.CorrelationID)
	}

	bobStartedPayload := mustReadUntilOpcode(t, bobPrimaryConn, protocol.S_DMStarted, 32)
	bobStarted, err := protocol.DecodeDMStarted(bobStartedPayload)
	if err != nil {
		t.Fatalf("failed to decode bob S_DMStarted payload: %v payload=%x", err, bobStartedPayload)
	}
	if bobStarted.ConvID != dmStartedAlice.ConvID {
		t.Fatalf("initial dm conv_id mismatch: alice=%d bob=%d", dmStartedAlice.ConvID, bobStarted.ConvID)
	}

	if err := bobPrimaryConn.Close(); err != nil {
		t.Fatalf("failed to close bob primary websocket client: %v", err)
	}

	bobReconnectConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to reconnect bob websocket client: %v", err)
	}
	defer bobReconnectConn.Close()

	mustSetReadDeadline(t, bobReconnectConn, 30*time.Second)
	mustExpectServerReady(t, bobReconnectConn)

	if err := sendProtocolMessage(bobReconnectConn, protocol.C_ListDMs, protocol.EncodeListDMsWithCorrelation(0xD0020002)); err != nil {
		t.Fatalf("failed to send ListDMs from bob reconnect: %v", err)
	}

	dmListPayload := mustReadUntilOpcode(t, bobReconnectConn, protocol.S_DMList, 32)
	dmList, err := protocol.DecodeDMList(dmListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_DMList payload: %v payload=%x", err, dmListPayload)
	}
	if dmList.CorrelationID != 0xD0020002 {
		t.Fatalf("dm list correlation_id mismatch: got 0x%08X want 0xD0020002", dmList.CorrelationID)
	}

	foundEntry := false
	for _, entry := range dmList.Entries {
		if entry.ConvID == dmStartedAlice.ConvID && entry.Username == aliceUsername {
			foundEntry = true
			if !entry.Online {
				t.Fatalf("dm list expected alice to be online after bob reconnect")
			}
			if !entry.Authenticated {
				t.Fatalf("dm list expected alice to be authenticated after bob reconnect")
			}
			break
		}
	}
	if !foundEntry {
		t.Fatalf("dm list missing expected DM entry for partner %q and conv_id %d", aliceUsername, dmStartedAlice.ConvID)
	}

	const reqID uint32 = 0xD0020003
	const dmContent = "post-reconnect dm delivery"
	if err := sendProtocolMessage(aliceConn, protocol.C_SendMessage, protocol.EncodeSendMessage(int64(dmStartedAlice.ConvID), reqID, dmContent, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send DM message after bob reconnect: %v", err)
	}

	ackPayload := mustReadUntilOpcode(t, aliceConn, protocol.S_AckSendMessage, 32)
	ack, err := protocol.DecodeAckSendMessage(ackPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AckSendMessage payload: %v payload=%x", err, ackPayload)
	}
	if ack.ClientReqID != reqID {
		t.Fatalf("ack client_req_id mismatch after reconnect: got %d want %d", ack.ClientReqID, reqID)
	}

	newMessagePayload := mustReadUntilOpcode(t, bobReconnectConn, protocol.S_NewMessage, 32)
	delivered, err := protocol.DecodeChatMessage(newMessagePayload)
	if err != nil {
		t.Fatalf("failed to decode reconnect S_NewMessage payload: %v payload=%x", err, newMessagePayload)
	}
	if uint64(delivered.ConvID) != dmStartedAlice.ConvID {
		t.Fatalf("reconnect dm message conv_id mismatch: got %d want %d", uint64(delivered.ConvID), dmStartedAlice.ConvID)
	}
	if delivered.Content != dmContent {
		t.Fatalf("reconnect dm message content mismatch: got %q want %q", delivered.Content, dmContent)
	}
}

func TestDMMultiDeviceDeliveryFanout(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-dm-multi-device-%d", time.Now().UnixNano())
	const aliceUsername = "e2e-dm-multi-device-alice"
	const bobUsername = "e2e-dm-multi-device-bob"

	aliceConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to connect alice websocket client: %v", err)
	}
	defer aliceConn.Close()

	bobDesktopConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to connect bob desktop websocket client: %v", err)
	}
	defer bobDesktopConn.Close()

	bobMobileConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to connect bob mobile websocket client: %v", err)
	}
	defer bobMobileConn.Close()

	mustSetReadDeadline(t, aliceConn, 30*time.Second)
	mustSetReadDeadline(t, bobDesktopConn, 30*time.Second)
	mustSetReadDeadline(t, bobMobileConn, 30*time.Second)
	mustExpectServerReady(t, aliceConn)
	mustExpectServerReady(t, bobDesktopConn)
	mustExpectServerReady(t, bobMobileConn)

	if err := sendProtocolMessage(aliceConn, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation(bobUsername, 0xD0030001)); err != nil {
		t.Fatalf("failed to send StartDM for multi-device test: %v", err)
	}

	dmStartedAlicePayload := mustReadUntilOpcode(t, aliceConn, protocol.S_DMStarted, 32)
	dmStartedAlice, err := protocol.DecodeDMStarted(dmStartedAlicePayload)
	if err != nil {
		t.Fatalf("failed to decode alice S_DMStarted payload: %v payload=%x", err, dmStartedAlicePayload)
	}
	if dmStartedAlice.CorrelationID != 0xD0030001 {
		t.Fatalf("alice dm started correlation_id mismatch: got 0x%08X want 0xD0030001", dmStartedAlice.CorrelationID)
	}

	bobDesktopStartedPayload := mustReadUntilOpcode(t, bobDesktopConn, protocol.S_DMStarted, 32)
	bobDesktopStarted, err := protocol.DecodeDMStarted(bobDesktopStartedPayload)
	if err != nil {
		t.Fatalf("failed to decode bob desktop S_DMStarted payload: %v payload=%x", err, bobDesktopStartedPayload)
	}

	bobMobileStartedPayload := mustReadUntilOpcode(t, bobMobileConn, protocol.S_DMStarted, 32)
	bobMobileStarted, err := protocol.DecodeDMStarted(bobMobileStartedPayload)
	if err != nil {
		t.Fatalf("failed to decode bob mobile S_DMStarted payload: %v payload=%x", err, bobMobileStartedPayload)
	}

	if bobDesktopStarted.ConvID != dmStartedAlice.ConvID || bobMobileStarted.ConvID != dmStartedAlice.ConvID {
		t.Fatalf("multi-device dm conv_id mismatch: alice=%d desktop=%d mobile=%d", dmStartedAlice.ConvID, bobDesktopStarted.ConvID, bobMobileStarted.ConvID)
	}

	const reqID uint32 = 0xD0030002
	const dmContent = "multi-device dm broadcast"
	if err := sendProtocolMessage(aliceConn, protocol.C_SendMessage, protocol.EncodeSendMessage(int64(dmStartedAlice.ConvID), reqID, dmContent, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send DM message for multi-device test: %v", err)
	}

	ackPayload := mustReadUntilOpcode(t, aliceConn, protocol.S_AckSendMessage, 32)
	ack, err := protocol.DecodeAckSendMessage(ackPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AckSendMessage payload: %v payload=%x", err, ackPayload)
	}
	if ack.ClientReqID != reqID {
		t.Fatalf("ack client_req_id mismatch for multi-device test: got %d want %d", ack.ClientReqID, reqID)
	}

	desktopMessagePayload := mustReadUntilOpcode(t, bobDesktopConn, protocol.S_NewMessage, 32)
	desktopMessage, err := protocol.DecodeChatMessage(desktopMessagePayload)
	if err != nil {
		t.Fatalf("failed to decode desktop S_NewMessage payload: %v payload=%x", err, desktopMessagePayload)
	}
	if uint64(desktopMessage.ConvID) != dmStartedAlice.ConvID {
		t.Fatalf("desktop dm message conv_id mismatch: got %d want %d", uint64(desktopMessage.ConvID), dmStartedAlice.ConvID)
	}
	if desktopMessage.Username != aliceUsername {
		t.Fatalf("desktop dm message author mismatch: got %q want %q", desktopMessage.Username, aliceUsername)
	}
	if desktopMessage.Content != dmContent {
		t.Fatalf("desktop dm message content mismatch: got %q want %q", desktopMessage.Content, dmContent)
	}

	mobileMessagePayload := mustReadUntilOpcode(t, bobMobileConn, protocol.S_NewMessage, 32)
	mobileMessage, err := protocol.DecodeChatMessage(mobileMessagePayload)
	if err != nil {
		t.Fatalf("failed to decode mobile S_NewMessage payload: %v payload=%x", err, mobileMessagePayload)
	}
	if uint64(mobileMessage.ConvID) != dmStartedAlice.ConvID {
		t.Fatalf("mobile dm message conv_id mismatch: got %d want %d", uint64(mobileMessage.ConvID), dmStartedAlice.ConvID)
	}
	if mobileMessage.Username != aliceUsername {
		t.Fatalf("mobile dm message author mismatch: got %q want %q", mobileMessage.Username, aliceUsername)
	}
	if mobileMessage.Content != dmContent {
		t.Fatalf("mobile dm message content mismatch: got %q want %q", mobileMessage.Content, dmContent)
	}
}

func TestDMMultiConnectionPresenceStatusEdges(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-dm-presence-%d", time.Now().UnixNano())
	const aliceUsername = "e2e-dm-presence-alice"
	const bobUsername = "e2e-dm-presence-bob"

	aliceDesktopConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to connect alice desktop websocket client: %v", err)
	}
	defer aliceDesktopConn.Close()

	aliceMobileConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to connect alice mobile websocket client: %v", err)
	}

	bobConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to connect bob websocket client: %v", err)
	}
	defer bobConn.Close()

	mustSetReadDeadline(t, aliceDesktopConn, 30*time.Second)
	mustSetReadDeadline(t, aliceMobileConn, 30*time.Second)
	mustSetReadDeadline(t, bobConn, 30*time.Second)
	mustExpectServerReady(t, aliceDesktopConn)
	mustExpectServerReady(t, aliceMobileConn)
	mustExpectServerReady(t, bobConn)

	if err := sendProtocolMessage(bobConn, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation(aliceUsername, 0xD0040001)); err != nil {
		t.Fatalf("failed to send StartDM from bob: %v", err)
	}

	bobStartedPayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMStarted, 32)
	bobStarted, err := protocol.DecodeDMStarted(bobStartedPayload)
	if err != nil {
		t.Fatalf("failed to decode bob S_DMStarted payload: %v payload=%x", err, bobStartedPayload)
	}
	if bobStarted.CorrelationID != 0xD0040001 {
		t.Fatalf("bob dm started correlation_id mismatch: got 0x%08X want 0xD0040001", bobStarted.CorrelationID)
	}
	if bobStarted.Username != aliceUsername || !bobStarted.Online || !bobStarted.Authenticated {
		t.Fatalf("bob dm started partner mismatch: username=%q online=%v authenticated=%v", bobStarted.Username, bobStarted.Online, bobStarted.Authenticated)
	}

	_ = mustReadUntilOpcode(t, aliceDesktopConn, protocol.S_DMStarted, 32)
	_ = mustReadUntilOpcode(t, aliceMobileConn, protocol.S_DMStarted, 32)

	mustCloseWebSocketClient(t, aliceDesktopConn, "alice desktop")
	mustListDMsAndRejectPartnerStatus(t, bobConn, 0xD0040002, bobStarted.ConvID, aliceUsername, true, "bob should not receive Alice offline while Alice mobile remains connected")

	mustCloseWebSocketClient(t, aliceMobileConn, "alice mobile")
	offlinePayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMPartnerStatus, 32)
	offlineStatus, err := protocol.DecodeDMPartnerStatus(offlinePayload)
	if err != nil {
		t.Fatalf("failed to decode offline S_DMPartnerStatus payload: %v payload=%x", err, offlinePayload)
	}
	if offlineStatus.ConvID != bobStarted.ConvID {
		t.Fatalf("offline partner status conv_id mismatch: got %d want %d", offlineStatus.ConvID, bobStarted.ConvID)
	}
	if offlineStatus.Username != aliceUsername {
		t.Fatalf("offline partner status username mismatch: got %q want %q", offlineStatus.Username, aliceUsername)
	}
	if offlineStatus.Online {
		t.Fatalf("offline partner status should mark alice offline")
	}
	if offlineStatus.LastSeen == 0 {
		t.Fatalf("offline partner status should include last_seen")
	}

	aliceReconnectConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to reconnect alice websocket client: %v", err)
	}
	defer aliceReconnectConn.Close()
	mustSetReadDeadline(t, aliceReconnectConn, 30*time.Second)
	mustExpectServerReady(t, aliceReconnectConn)

	onlinePayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMPartnerStatus, 32)
	onlineStatus, err := protocol.DecodeDMPartnerStatus(onlinePayload)
	if err != nil {
		t.Fatalf("failed to decode online S_DMPartnerStatus payload: %v payload=%x", err, onlinePayload)
	}
	if onlineStatus.ConvID != bobStarted.ConvID {
		t.Fatalf("online partner status conv_id mismatch: got %d want %d", onlineStatus.ConvID, bobStarted.ConvID)
	}
	if onlineStatus.Username != aliceUsername {
		t.Fatalf("online partner status username mismatch: got %q want %q", onlineStatus.Username, aliceUsername)
	}
	if !onlineStatus.Online {
		t.Fatalf("online partner status should mark alice online")
	}
	if onlineStatus.LastSeen < offlineStatus.LastSeen {
		t.Fatalf("online partner status timestamp moved backwards: online=%d offline=%d", onlineStatus.LastSeen, offlineStatus.LastSeen)
	}
}

func TestDMReconnectListReportsPartnerPresenceEdges(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-dm-list-presence-%d", time.Now().UnixNano())
	const aliceUsername = "e2e-dm-list-presence-alice"
	const bobUsername = "e2e-dm-list-presence-bob"

	aliceConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to connect alice websocket client: %v", err)
	}

	bobConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to connect bob websocket client: %v", err)
	}
	defer bobConn.Close()

	mustSetReadDeadline(t, aliceConn, 30*time.Second)
	mustSetReadDeadline(t, bobConn, 30*time.Second)
	mustExpectServerReady(t, aliceConn)
	mustExpectServerReady(t, bobConn)

	if err := sendProtocolMessage(bobConn, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation(aliceUsername, 0xD0050001)); err != nil {
		t.Fatalf("failed to send StartDM from bob: %v", err)
	}

	bobStartedPayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMStarted, 32)
	bobStarted, err := protocol.DecodeDMStarted(bobStartedPayload)
	if err != nil {
		t.Fatalf("failed to decode bob S_DMStarted payload: %v payload=%x", err, bobStartedPayload)
	}
	_ = mustReadUntilOpcode(t, aliceConn, protocol.S_DMStarted, 32)

	mustCloseWebSocketClient(t, aliceConn, "alice")
	offlineStatusPayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMPartnerStatus, 32)
	offlineStatus, err := protocol.DecodeDMPartnerStatus(offlineStatusPayload)
	if err != nil {
		t.Fatalf("failed to decode offline S_DMPartnerStatus payload: %v payload=%x", err, offlineStatusPayload)
	}
	if offlineStatus.ConvID != bobStarted.ConvID || offlineStatus.Username != aliceUsername || offlineStatus.Online || offlineStatus.LastSeen == 0 {
		t.Fatalf("unexpected offline status after alice close: %+v", offlineStatus)
	}

	offlineEntry := mustListDMEntry(t, bobConn, 0xD0050002, bobStarted.ConvID, aliceUsername)
	if offlineEntry.Online {
		t.Fatalf("DM list should report alice offline after disconnect")
	}
	if offlineEntry.Authenticated {
		t.Fatalf("DM list should report alice unauthenticated after her last connection disconnects")
	}
	if offlineEntry.LastSeen < offlineStatus.LastSeen {
		t.Fatalf("DM list last_seen moved backwards: list=%d status=%d", offlineEntry.LastSeen, offlineStatus.LastSeen)
	}

	aliceReconnectConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to reconnect alice websocket client: %v", err)
	}
	defer aliceReconnectConn.Close()
	mustSetReadDeadline(t, aliceReconnectConn, 30*time.Second)
	mustExpectServerReady(t, aliceReconnectConn)

	onlineStatusPayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMPartnerStatus, 32)
	onlineStatus, err := protocol.DecodeDMPartnerStatus(onlineStatusPayload)
	if err != nil {
		t.Fatalf("failed to decode online S_DMPartnerStatus payload: %v payload=%x", err, onlineStatusPayload)
	}
	if onlineStatus.ConvID != bobStarted.ConvID || onlineStatus.Username != aliceUsername || !onlineStatus.Online {
		t.Fatalf("unexpected online status after alice reconnect: %+v", onlineStatus)
	}

	onlineEntry := mustListDMEntry(t, bobConn, 0xD0050003, bobStarted.ConvID, aliceUsername)
	if !onlineEntry.Online {
		t.Fatalf("DM list should report alice online after reconnect")
	}
	if !onlineEntry.Authenticated {
		t.Fatalf("DM list should report alice authenticated after reconnect")
	}
	if onlineEntry.LastSeen < offlineEntry.LastSeen {
		t.Fatalf("DM list last_seen moved backwards across reconnect: online=%d offline=%d", onlineEntry.LastSeen, offlineEntry.LastSeen)
	}
}

func TestDMIdleTimeoutSendsCloseAndPartnerOffline(t *testing.T) {
	_ = startServerWithDefines(t, map[string]int64{
		"NRC_IDLE_TIMEOUT_MS":       200,
		"NRC_HEARTBEAT_INTERVAL_MS": 50,
		"NRC_CONN_CLOSE_DELAY_MS":   20,
	})

	workspace := fmt.Sprintf("e2e-dm-idle-timeout-%d", time.Now().UnixNano())
	const aliceUsername = "e2e-dm-idle-timeout-alice"
	const bobUsername = "e2e-dm-idle-timeout-bob"

	aliceConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, aliceUsername))
	if err != nil {
		t.Fatalf("failed to connect alice websocket client: %v", err)
	}
	defer aliceConn.Close()

	bobConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, bobUsername))
	if err != nil {
		t.Fatalf("failed to connect bob websocket client: %v", err)
	}
	defer bobConn.Close()

	mustSetReadDeadline(t, aliceConn, 5*time.Second)
	mustSetReadDeadline(t, bobConn, 5*time.Second)
	mustExpectServerReady(t, aliceConn)
	mustExpectServerReady(t, bobConn)

	if err := sendProtocolMessage(bobConn, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation(aliceUsername, 0xD0060001)); err != nil {
		t.Fatalf("failed to send StartDM from bob: %v", err)
	}

	bobStartedPayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMStarted, 32)
	bobStarted, err := protocol.DecodeDMStarted(bobStartedPayload)
	if err != nil {
		t.Fatalf("failed to decode bob S_DMStarted payload: %v payload=%x", err, bobStartedPayload)
	}
	_ = mustReadUntilOpcode(t, aliceConn, protocol.S_DMStarted, 32)
	stopBobKeepalive := make(chan struct{})
	bobKeepaliveDone := make(chan struct{})
	go func() {
		defer close(bobKeepaliveDone)
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stopBobKeepalive:
				return
			case <-ticker.C:
				_ = sendProtocolMessage(bobConn, protocol.C_Ping, protocol.EncodePing(time.Now().UnixNano()))
			}
		}
	}()

	offlinePayload := mustReadUntilOpcode(t, bobConn, protocol.S_DMPartnerStatus, 64)
	close(stopBobKeepalive)
	<-bobKeepaliveDone
	offlineStatus, err := protocol.DecodeDMPartnerStatus(offlinePayload)
	if err != nil {
		t.Fatalf("failed to decode idle-timeout S_DMPartnerStatus payload: %v payload=%x", err, offlinePayload)
	}
	if offlineStatus.ConvID != bobStarted.ConvID || offlineStatus.Username != aliceUsername || offlineStatus.Online || offlineStatus.LastSeen == 0 {
		t.Fatalf("unexpected idle-timeout offline status: %+v", offlineStatus)
	}

	closeErr := mustReadWebSocketClose(t, aliceConn, 5*time.Second)
	if closeErr.Code != websocket.CloseNormalClosure {
		t.Fatalf("expected idle timeout close code %d, got %d text=%q", websocket.CloseNormalClosure, closeErr.Code, closeErr.Text)
	}
	if closeErr.Text != "Idle timeout" {
		t.Fatalf("expected idle timeout close reason %q, got %q", "Idle timeout", closeErr.Text)
	}

	entry := mustListDMEntry(t, bobConn, 0xD0060002, bobStarted.ConvID, aliceUsername)
	if entry.Online || entry.Authenticated || entry.LastSeen == 0 {
		t.Fatalf("DM list should report alice offline after idle timeout: %+v", entry)
	}
}

func mustListDMsAndRejectPartnerStatus(t *testing.T, conn *websocket.Conn, correlationID uint32, convID uint64, partnerUsername string, wantPartnerOnline bool, reason string) {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListDMs, protocol.EncodeListDMsWithCorrelation(correlationID)); err != nil {
		t.Fatalf("failed to send ListDMs while checking partner status absence: %v", err)
	}

	for i := 0; i < 32; i++ {
		frameType, payload, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("failed to read ListDMs response while checking partner status absence: %v", err)
		}
		if frameType != websocket.BinaryMessage {
			continue
		}
		msg, parseErr := protocol.ReadMessage(payload)
		if parseErr != nil {
			continue
		}
		if msg.Opcode == protocol.S_DMPartnerStatus {
			status, decodeErr := protocol.DecodeDMPartnerStatus(msg.Data)
			if decodeErr != nil {
				t.Fatalf("%s; received malformed DM partner status payload=%x err=%v", reason, msg.Data, decodeErr)
			}
			t.Fatalf("%s; unexpectedly received DM partner status: username=%q online=%v conv_id=%d", reason, status.Username, status.Online, status.ConvID)
		}
		if msg.Opcode == protocol.S_DMList {
			dmList, decodeErr := protocol.DecodeDMList(msg.Data)
			if decodeErr != nil {
				t.Fatalf("failed to decode DM list while checking partner status absence: %v payload=%x", decodeErr, msg.Data)
			}
			if dmList.CorrelationID != correlationID {
				t.Fatalf("DM list correlation_id mismatch while checking partner status absence: got 0x%08X want 0x%08X", dmList.CorrelationID, correlationID)
			}
			for _, entry := range dmList.Entries {
				if entry.ConvID == convID && entry.Username == partnerUsername {
					if entry.Online != wantPartnerOnline {
						t.Fatalf("DM list partner online mismatch while checking partner status absence: got %v want %v", entry.Online, wantPartnerOnline)
					}
					return
				}
			}
			t.Fatalf("DM list missing expected partner %q conv_id=%d while checking partner status absence", partnerUsername, convID)
		}
	}
	t.Fatalf("did not receive DM list response while checking partner status absence")
}

func mustListDMEntry(t *testing.T, conn *websocket.Conn, correlationID uint32, convID uint64, partnerUsername string) protocol.DMEntry {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListDMs, protocol.EncodeListDMsWithCorrelation(correlationID)); err != nil {
		t.Fatalf("failed to send ListDMs: %v", err)
	}
	dmListPayload := mustReadUntilOpcode(t, conn, protocol.S_DMList, 32)
	dmList, err := protocol.DecodeDMList(dmListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_DMList payload: %v payload=%x", err, dmListPayload)
	}
	if dmList.CorrelationID != correlationID {
		t.Fatalf("DM list correlation_id mismatch: got 0x%08X want 0x%08X", dmList.CorrelationID, correlationID)
	}
	for _, entry := range dmList.Entries {
		if entry.ConvID == convID && entry.Username == partnerUsername {
			return entry
		}
	}
	t.Fatalf("DM list missing expected partner %q conv_id=%d entries=%+v", partnerUsername, convID, dmList.Entries)
	return protocol.DMEntry{}
}
func mustCloseWebSocketClient(t *testing.T, conn *websocket.Conn, label string) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	if err := conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), deadline); err != nil {
		t.Fatalf("failed to send %s close frame: %v", label, err)
	}
	time.Sleep(100 * time.Millisecond)
	if err := conn.SetReadDeadline(deadline); err != nil {
		t.Fatalf("failed to set %s close read deadline: %v", label, err)
	}
	_, _, _ = conn.ReadMessage()
	if err := conn.Close(); err != nil {
		t.Fatalf("failed to close %s websocket client: %v", label, err)
	}
}
