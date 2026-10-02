package e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func workspaceDataClient(t *testing.T, workspace, username string, chatRoom int64) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, username))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	mustSetReadDeadline(t, conn, 15*time.Second)
	mustExpectServerReady(t, conn)
	if err := sendProtocolMessage(conn, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(chatRoom)); err != nil {
		t.Fatal(err)
	}
	mustWaitForPresenceUpdate(t, conn, 16)
	mustSubscribeWorkspaceData(t, conn)
	return conn
}

func TestWorkspaceDataSharedAcrossChatRooms(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)
	workspace := fmt.Sprintf("e2e-workspace-data-%d", time.Now().UnixNano())
	alice := workspaceDataClient(t, workspace, "alice", 11)
	bob := workspaceDataClient(t, workspace, "bob", 22)
	isolated := workspaceDataClient(t, workspace+"-isolated", "carol", 11)

	if err := sendProtocolMessage(alice, protocol.C_CreateTask, protocol.EncodeTaskCreate(protocol.WorkspaceDataConvID, "shared task", "workspace task", 2)); err != nil {
		t.Fatal(err)
	}
	var taskID uint64
	for i, conn := range []*websocket.Conn{alice, bob} {
		created, err := protocol.DecodeTaskCreated(mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 16))
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			taskID = created.Task.ID
		}
		if taskID == 0 || created.Task.ID != taskID || created.Task.ConvID != 0 || created.Task.Title != "shared task" {
			t.Fatalf("cross-room task create mismatch: %+v", created.Task)
		}
	}
	if err := sendProtocolMessage(bob, protocol.C_UpdateTask, protocol.EncodeTaskUpdate(protocol.WorkspaceDataConvID, int64(taskID), "updated from other room", "workspace task", 2, 3, 0)); err != nil {
		t.Fatal(err)
	}
	for _, conn := range []*websocket.Conn{bob, alice} {
		updated, err := protocol.DecodeTaskUpdated(mustReadUntilOpcode(t, conn, protocol.S_TaskUpdated, 16))
		if err != nil || updated.Task.ID != taskID || updated.Task.ConvID != 0 || updated.Task.Title != "updated from other room" {
			t.Fatalf("cross-room task update mismatch: %+v err=%v", updated, err)
		}
	}

	for _, assetType := range []uint16{protocol.AssetTypeCustomerCompany, protocol.AssetTypeNote} {
		preview := mustNotePreviewJSON(t, "shared record", "workspace-project", "shared-tag")
		if assetType == protocol.AssetTypeCustomerCompany {
			preview = `{"version":1,"title":"shared record"}`
		}
		if err := sendProtocolMessage(alice, protocol.C_CreateAsset, protocol.EncodeCreateAsset(protocol.WorkspaceDataConvID, assetType, protocol.ParentTypeNone, 0, preview, "shared content")); err != nil {
			t.Fatal(err)
		}
		var assetID uint64
		for i, conn := range []*websocket.Conn{alice, bob} {
			created, err := protocol.DecodeAssetCreated(mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 16))
			if err != nil {
				t.Fatal(err)
			}
			if i == 0 {
				assetID = created.Asset.AssetID
			}
			if assetID == 0 || created.Asset.AssetID != assetID || created.Asset.ConvID != 0 || created.Asset.AssetType != assetType || created.Asset.Payload != "shared content" {
				t.Fatalf("cross-room asset create mismatch: %+v", created.Asset)
			}
		}
		if err := sendProtocolMessage(bob, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(protocol.WorkspaceDataConvID, assetID, preview, "updated content")); err != nil {
			t.Fatal(err)
		}
		for _, conn := range []*websocket.Conn{bob, alice} {
			updated, err := protocol.DecodeAssetUpdated(mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 16))
			if err != nil || updated.Asset.AssetID != assetID || updated.Asset.ConvID != 0 || updated.Asset.Payload != "updated content" {
				t.Fatalf("cross-room asset update mismatch: %+v err=%v", updated, err)
			}
		}
	}
	// Do not silently discard leaked mutation broadcasts while reading lists.
	if err := sendProtocolMessage(isolated, protocol.C_Ping, protocol.EncodePing(76)); err != nil {
		t.Fatal(err)
	}
	if message := mustReadProtocolMessage(t, isolated); message.Opcode != protocol.S_Pong {
		t.Fatalf("workspace mutation leaked to isolated subscriber: opcode=%d", message.Opcode)
	}
	// Read APIs share the same workspace data, not the active chat room.
	if tasks := listTasks(t, bob, protocol.WorkspaceDataConvID).Tasks; len(tasks) != 1 || tasks[0].ID != taskID || tasks[0].Title != "updated from other room" {
		t.Fatalf("cross-room task read: %+v", tasks)
	}
	if page := listNotesPage(t, bob, protocol.WorkspaceDataConvID, 10, false, 0, 0); len(page.Assets) != 1 || page.Assets[0].AssetType != protocol.AssetTypeNote {
		t.Fatalf("cross-room notes read: %+v", page)
	}
	for _, check := range []struct {
		conn *websocket.Conn
		want int
	}{{bob, 1}, {isolated, 0}} {
		payload, err := protocol.EncodeSearchCustomers(protocol.WorkspaceDataConvID, 10, 0, false, "shared record", 77)
		if err != nil {
			t.Fatal(err)
		}
		if err := sendProtocolMessage(check.conn, protocol.C_SearchCustomers, payload); err != nil {
			t.Fatal(err)
		}
		page, err := protocol.DecodeCustomerSearchPage(mustReadUntilOpcode(t, check.conn, protocol.S_CustomerSearchPage, 16))
		if err != nil || len(page.Assets) != check.want || page.ConvID != 0 {
			t.Fatalf("workspace customer read: %+v err=%v want=%d", page, err, check.want)
		}
	}
	if tasks := listTasks(t, isolated, protocol.WorkspaceDataConvID).Tasks; len(tasks) != 0 {
		t.Fatalf("tasks leaked across workspaces: %+v", tasks)
	}
	if assets := listAssetsFull(t, isolated, protocol.WorkspaceDataConvID); len(assets) != 0 {
		t.Fatalf("assets leaked across workspaces: %+v", assets)
	}
	// Shared data subscriptions must not broaden chat delivery.
	if err := sendProtocolMessage(alice, protocol.C_SendMessage, protocol.EncodeSendMessage(11, 88, "room eleven only", protocol.ContentTypePlainText)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, alice, protocol.S_AckSendMessage, 16)
	mustNotReceiveOpcodeWithin(t, bob, protocol.S_NewMessage, 250*time.Millisecond)
	mustNotReceiveOpcodeWithin(t, isolated, protocol.S_NewMessage, 250*time.Millisecond)
}

func TestRoomAndDMDurableRequestsRejectedWithoutPublicWrites(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)
	workspace := fmt.Sprintf("e2e-reject-dm-data-%d", time.Now().UnixNano())
	alice := workspaceDataClient(t, workspace, "alice", 11)
	bob := workspaceDataClient(t, workspace, "bob", 22)
	if err := sendProtocolMessage(alice, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation("bob", 91)); err != nil {
		t.Fatal(err)
	}
	dm, err := protocol.DecodeDMStarted(mustReadUntilOpcode(t, alice, protocol.S_DMStarted, 16))
	if err != nil || dm.ConvID&protocol.DMConvFlag == 0 {
		t.Fatalf("start DM: %+v %v", dm, err)
	}
	mustReadUntilOpcode(t, bob, protocol.S_DMStarted, 16)
	for _, scope := range []uint64{11, dm.ConvID} {
		for _, request := range []struct {
			opcode  uint16
			payload []byte
		}{
			{protocol.C_CreateTask, protocol.EncodeTaskCreate(int64(scope), "must not become public", "private input", 1)},
			{protocol.C_CreateAsset, protocol.EncodeCreateAsset(int64(scope), protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "private note", "private input")},
			{protocol.C_CreateAsset, protocol.EncodeCreateAsset(int64(scope), protocol.AssetTypeCustomerCompany, protocol.ParentTypeNone, 0, "private company", "private input")},
			{protocol.C_CreateEdge, protocol.EncodeCreateEdge(int64(scope), protocol.TargetTypeTask, 1, protocol.TargetTypeAsset, 2, protocol.RelationReferences)},
			{protocol.C_GetTasks, protocol.EncodeGetTasks(int64(scope))},
			{protocol.C_ListNoteProjects, protocol.EncodeListNoteProjects(int64(scope))},
		} {
			if err := sendProtocolMessage(alice, request.opcode, request.payload); err != nil {
				t.Fatal(err)
			}
			response := mustReadErrorResponse(t, alice, request.opcode, 0)
			if !strings.Contains(response.ErrorMessage, "scope 0") {
				t.Fatalf("expected scope rejection, got %+v", response)
			}
		}
		// A valid first operation cannot be committed when a later operation has room/DM scope.
		var operations []protocol.TransactionOperation
		for _, operationScope := range []uint64{protocol.WorkspaceDataConvID, scope} {
			body, err := protocol.EncodeTransactionTaskCreate(protocol.TransactionTaskCreate{ConvID: operationScope, Title: "atomic scope rejection", BlockedBy: protocol.Existing(protocol.TransactionEntityTask, 0)})
			if err != nil {
				t.Fatal(err)
			}
			operations = append(operations, protocol.TransactionOperation{Type: protocol.TransactionOpTaskCreate, Body: body})
		}
		payload, err := protocol.EncodeApplyTransaction(92, operations)
		if err != nil {
			t.Fatal(err)
		}
		if err := sendProtocolMessage(alice, protocol.C_ApplyTransaction, payload); err != nil {
			t.Fatal(err)
		}
		mustReadErrorResponse(t, alice, protocol.C_ApplyTransaction, 92)
	}
	if tasks := listTasks(t, alice, protocol.WorkspaceDataConvID).Tasks; len(tasks) != 0 {
		t.Fatalf("rejected room/DM transaction leaked public tasks: %+v", tasks)
	}
	if assets := listAssetsFull(t, alice, protocol.WorkspaceDataConvID); len(assets) != 0 {
		t.Fatalf("rejected room/DM requests leaked public assets: %+v", assets)
	}
	if err := sendProtocolMessage(alice, protocol.C_SendMessage, protocol.EncodeSendMessage(int64(dm.ConvID), 93, "DM chat still works", protocol.ContentTypePlainText)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, alice, protocol.S_AckSendMessage, 16)
	message, err := protocol.DecodeChatMessage(mustReadUntilOpcode(t, bob, protocol.S_NewMessage, 16))
	if err != nil || uint64(message.ConvID) != dm.ConvID || message.Content != "DM chat still works" {
		t.Fatalf("DM chat changed by data scope: %+v %v", message, err)
	}
}

func TestWorkspaceDataScopeIsNotChat(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)
	workspace := fmt.Sprintf("e2e-data-not-chat-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "alice"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	mustSetReadDeadline(t, conn, 15*time.Second)
	mustExpectServerReady(t, conn)
	if err := sendProtocolMessage(conn, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(protocol.WorkspaceDataConvID)); err != nil {
		t.Fatal(err)
	}
	if err := sendProtocolMessage(conn, protocol.C_Ping, protocol.EncodePing(100)); err != nil {
		t.Fatal(err)
	}
	// Read directly, not with a filtering helper: no presence event may precede Pong.
	if message := mustReadProtocolMessage(t, conn); message.Opcode != protocol.S_Pong {
		t.Fatalf("V1 scope-zero subscription emitted presence/error: opcode=%d", message.Opcode)
	}
	mustPayload := func(payload []byte, err error) []byte {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return payload
	}
	for _, request := range []struct {
		opcode      uint16
		correlation uint32
		payload     []byte
	}{
		{protocol.C_SendMessage, 101, protocol.EncodeSendMessage(protocol.WorkspaceDataConvID, 101, "not a room", protocol.ContentTypePlainText)},
		{protocol.C_SendMessageV2, 102, mustPayload(protocol.EncodeSendMessageV2(protocol.WorkspaceDataConvID, protocol.ClientMessageID{1}, 102, protocol.ContentTypePlainText, "not retained chat"))},
		{protocol.C_SubscribeConvsV2, 103, mustPayload(protocol.EncodeSubscribeConvsV2(103, protocol.WorkspaceDataConvID))},
		{protocol.C_ListMessagesBefore, 104, mustPayload(protocol.EncodeListMessagesBefore(protocol.WorkspaceDataConvID, 0, 10, 104))},
		{protocol.C_ReplayMessagesAfter, 105, mustPayload(protocol.EncodeReplayMessagesAfter(protocol.WorkspaceDataConvID, 0, 10, 105))},
	} {
		if err := sendProtocolMessage(conn, request.opcode, request.payload); err != nil {
			t.Fatal(err)
		}
		response := mustReadErrorResponse(t, conn, request.opcode, request.correlation)
		if !strings.Contains(response.ErrorMessage, "chat") {
			t.Fatalf("expected chat-scope rejection: %+v", response)
		}
	}
}
