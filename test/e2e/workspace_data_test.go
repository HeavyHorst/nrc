package e2e

import (
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestPersonalRemindersWorkspacePrivacy(t *testing.T) {
	dir := t.TempDir()
	server := startServerInWorkDir(t, dir)
	defer func() { server.stop(t) }()
	workspace := fmt.Sprintf("e2e-personal-reminders-%d", time.Now().UnixNano())
	connect := func(username string) *websocket.Conn {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, username))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		mustSetReadDeadline(t, conn, 20*time.Second)
		mustExpectServerReady(t, conn)
		mustSubscribeWorkspaceData(t, conn)
		return conn
	}
	alice, aliceOther, bob := connect("alice"), connect("alice"), connect("bob")
	send := func(c *websocket.Conn, op uint16, body []byte) {
		t.Helper()
		if err := sendProtocolMessage(c, op, body); err != nil {
			t.Fatal(err)
		}
	}
	quiet := func(c *websocket.Conn) {
		t.Helper()
		send(c, protocol.C_Ping, protocol.EncodePing(77))
		if msg := mustReadProtocolMessage(t, c); msg.Opcode != protocol.S_Pong {
			t.Fatalf("private mutation leaked: opcode=%d", msg.Opcode)
		}
	}
	personal := `{"title":"Update my Xcode","deadline_at":"100","visibility":"personal"}`
	team := `{"title":"Team maintenance","deadline_at":"200","visibility":"team"}`
	legacy := `{"title":"Legacy team reminder","deadline_at":"300"}`
	compressed, err := protocol.EncodeCreateAssetZstdWithCorrelation(0, protocol.AssetTypeReminder, protocol.ParentTypeNone, 0, personal, personal, 1)
	if err != nil {
		t.Fatal(err)
	}
	send(alice, protocol.C_CreateAsset, compressed)
	created, err := protocol.DecodeAssetCreated(mustReadUntilOpcode(t, alice, protocol.S_AssetCreated, 12))
	if err != nil {
		t.Fatal(err)
	}
	privateID := created.Asset.AssetID
	otherCreated, err := protocol.DecodeAssetCreated(mustReadUntilOpcode(t, aliceOther, protocol.S_AssetCreated, 12))
	if err != nil || otherCreated.Asset.AssetID != privateID {
		t.Fatalf("owner's other session missing reminder: %v", err)
	}
	quiet(bob)
	for _, record := range []string{team, legacy} {
		send(alice, protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeReminder, protocol.ParentTypeNone, 0, record, record))
		for _, c := range []*websocket.Conn{alice, aliceOther, bob} {
			mustReadUntilOpcode(t, c, protocol.S_AssetCreated, 12)
		}
	}
	checkReads := func() {
		t.Helper()
		for _, check := range []struct {
			c    *websocket.Conn
			want int
		}{{alice, 3}, {bob, 2}} {
			if assets := listAssetsFull(t, check.c, 0); len(assets) != check.want {
				t.Fatalf("visible assets=%d want=%d", len(assets), check.want)
			}
			send(check.c, protocol.C_ListAssetsPaged, protocol.EncodeListAssetsPaged(0, protocol.AssetTypeReminder, true, 1, false, 0, 0))
			page, err := protocol.DecodeAssetListPage(mustReadUntilOpcode(t, check.c, protocol.S_AssetListPage, 12))
			if err != nil || page.TotalCount != uint32(check.want) || len(page.Assets) != 1 || !page.HasMore {
				t.Fatalf("visible page/count: %+v %v", page, err)
			}
			// The private reminder is earlier than team reminders: filtering after
			// pagination would incorrectly return an empty page or a private cursor.
			body := make([]byte, 52)
			binary.BigEndian.PutUint64(body[16:], 400)
			binary.BigEndian.PutUint16(body[24:], 1)
			send(check.c, protocol.C_QueryCalendar, body)
			calendar := mustReadUntilOpcode(t, check.c, protocol.S_CalendarPage, 12)
			wantTitle := "Update my Xcode"
			if check.c == bob {
				wantTitle = "Team maintenance"
			}
			if binary.BigEndian.Uint16(calendar[8:]) != 1 || !strings.Contains(string(calendar), wantTitle) {
				t.Fatalf("wrong visible calendar page: %q", calendar)
			}
		}
		send(alice, protocol.C_GetAsset, protocol.EncodeGetAsset(0, privateID))
		mustReadUntilOpcode(t, alice, protocol.S_AssetFull, 12)
		send(bob, protocol.C_GetAsset, protocol.EncodeGetAsset(0, privateID))
		mustReadErrorResponse(t, bob, protocol.C_GetAsset, 0)
	}
	checkReads()
	for _, request := range []struct {
		op   uint16
		body []byte
	}{
		{protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(0, privateID, personal, personal)},
		{protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(0, privateID)},
	} {
		send(bob, request.op, request.body)
		mustReadErrorResponse(t, bob, request.op, 0)
	}
	// Privacy cannot be weakened by clearing preview metadata or converting it
	// to Team, and inconsistent/duplicate metadata must not claim false privacy.
	for _, record := range []string{team, legacy} {
		send(alice, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(0, privateID, record, record))
		mustReadErrorResponse(t, alice, protocol.C_UpdateAsset, 0)
	}
	for _, preview := range []string{team, `{"visibility":"team","visibility":"personal"}`} {
		send(alice, protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeReminder, protocol.ParentTypeNone, 0, preview, personal))
		mustReadErrorResponse(t, alice, protocol.C_CreateAsset, 0)
	}
	// Shared relations/children must not provide an indirect private-record path.
	send(alice, protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeNote, protocol.ParentTypeAsset, privateID, "child", "child"))
	mustReadErrorResponse(t, alice, protocol.C_CreateAsset, 0)
	send(alice, protocol.C_CreateEdge, protocol.EncodeCreateEdge(0, protocol.TargetTypeAsset, privateID, protocol.TargetTypeAsset, privateID+1, protocol.RelationRelatedTo))
	mustReadErrorResponse(t, alice, protocol.C_CreateEdge, 0)
	// Hidden records must be indistinguishable from missing IDs, including
	// source/target-specific errors and ownership parent checks.
	for _, source := range []bool{true, false} {
		var messages []string
		for _, id := range []uint64{privateID, privateID + 1000} {
			src, dst := privateID+1, id
			if source {
				src, dst = id, privateID+1
			}
			send(bob, protocol.C_CreateEdge, protocol.EncodeCreateEdge(0, protocol.TargetTypeAsset, src, protocol.TargetTypeAsset, dst, protocol.RelationRelatedTo))
			messages = append(messages, mustReadErrorResponse(t, bob, protocol.C_CreateEdge, 0).ErrorMessage)
		}
		if messages[0] != messages[1] {
			t.Fatalf("edge error reveals private existence: %v", messages)
		}
	}
	var parentErrors []string
	for _, id := range []uint64{privateID, privateID + 4} {
		send(bob, protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeNote, protocol.ParentTypeAsset, id, "child", "child"))
		parentErrors = append(parentErrors, mustReadErrorResponse(t, bob, protocol.C_CreateAsset, 0).ErrorMessage)
	}
	if parentErrors[0] != parentErrors[1] {
		t.Fatalf("parent error reveals private existence: %v", parentErrors)
	}
	attached, err := protocol.EncodeCreateAssetWithAttachments(0, protocol.AssetTypeReminder, protocol.ParentTypeNone, 0, personal, personal, []protocol.Attachment{{FileId: "private-file", Filename: "private.txt", Size: 1, MimeType: "text/plain"}})
	if err != nil {
		t.Fatal(err)
	}
	send(alice, protocol.C_CreateAsset, attached)
	mustReadErrorResponse(t, alice, protocol.C_CreateAsset, 0)
	apply := func(c *websocket.Conn, ops []protocol.TransactionOperation, want uint8) *protocol.TransactionResult {
		t.Helper()
		body, err := protocol.EncodeApplyTransaction(88, ops)
		if err != nil {
			t.Fatal(err)
		}
		send(c, protocol.C_ApplyTransaction, body)
		result, err := protocol.DecodeTransactionResult(mustReadUntilOpcode(t, c, protocol.S_TransactionResult, 12))
		if err != nil || result.Status != want {
			t.Fatalf("transaction status: %+v %v", result, err)
		}
		return result
	}
	patch, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{Asset: protocol.Existing(protocol.TransactionEntityAsset, privateID), Present: protocol.TransactionAssetPatchPreview, Preview: []byte(personal)})
	if err != nil {
		t.Fatal(err)
	}
	apply(bob, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: patch}}, protocol.TransactionStatusRejected)
	deletion, err := protocol.EncodeTransactionDelete(protocol.TransactionDelete{Entity: protocol.Existing(protocol.TransactionEntityAsset, privateID)}, protocol.TransactionEntityAsset)
	if err != nil {
		t.Fatal(err)
	}
	apply(bob, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetDelete, Body: deletion}}, protocol.TransactionStatusRejected)
	// Projected-state validation also covers a private reminder and edge created
	// in the same atomic transaction, not just pre-existing endpoints.
	creation, err := protocol.EncodeTransactionAssetCreate(protocol.TransactionAssetCreate{AssetType: protocol.AssetTypeReminder, PayloadRawLen: uint32(len(personal)), Preview: []byte(personal), Payload: []byte(personal)})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []uint64{privateID, privateID + 1000} {
		for _, guard := range []int64{0, created.Asset.UpdatedAt, created.Asset.UpdatedAt + 1} {
			deleteBody, err := protocol.EncodeTransactionDelete(protocol.TransactionDelete{Entity: protocol.Existing(protocol.TransactionEntityAsset, id), IfUpdatedAt: guard}, protocol.TransactionEntityAsset)
			if err != nil {
				t.Fatal(err)
			}
			result := apply(bob, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetCreate, Body: creation}, {Type: protocol.TransactionOpAssetDelete, Body: deleteBody}}, protocol.TransactionStatusRejected)
			if result.FailedOperation != 1 || len(result.Results) != 0 {
				t.Fatalf("hidden/missing delete must reject at operation 1: %+v", result)
			}
		}
	}
	for _, rawLen := range []uint32{protocol.MaxPayloadLength + 1, ^uint32(0)} {
		oversized, err := protocol.EncodeTransactionAssetCreate(protocol.TransactionAssetCreate{AssetType: protocol.AssetTypeReminder, PayloadEncoding: 1, PayloadRawLen: rawLen, Preview: []byte(personal), Payload: []byte("invalid zstd")})
		if err != nil {
			t.Fatal(err)
		}
		apply(alice, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetCreate, Body: oversized}}, protocol.TransactionStatusRejected)
		oversizedPatch, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{Asset: protocol.Existing(protocol.TransactionEntityAsset, privateID), Present: protocol.TransactionAssetPatchPayload, PayloadEncoding: 1, PayloadRawLen: rawLen, Payload: []byte("invalid zstd")})
		if err != nil {
			t.Fatal(err)
		}
		apply(alice, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: oversizedPatch}}, protocol.TransactionStatusRejected)
	}
	child, err := protocol.EncodeTransactionAssetCreate(protocol.TransactionAssetCreate{AssetType: protocol.AssetTypeNote, ParentType: protocol.ParentTypeAsset, Parent: protocol.CreatedBy(protocol.TransactionEntityAsset, 1)})
	if err != nil {
		t.Fatal(err)
	}
	apply(alice, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetCreate, Body: child}, {Type: protocol.TransactionOpAssetCreate, Body: creation}}, protocol.TransactionStatusRejected)
	edge, err := protocol.EncodeTransactionEdgeCreate(protocol.TransactionEdgeCreate{Source: protocol.CreatedBy(protocol.TransactionEntityAsset, 0), Target: protocol.Existing(protocol.TransactionEntityAsset, privateID+1), Relation: protocol.RelationRelatedTo})
	if err != nil {
		t.Fatal(err)
	}
	apply(alice, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetCreate, Body: creation}, {Type: protocol.TransactionOpEdgeCreate, Body: edge}}, protocol.TransactionStatusRejected)
	quiet(bob)
	send(alice, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(0, privateID, personal, personal))
	for _, c := range []*websocket.Conn{alice, aliceOther} {
		mustReadUntilOpcode(t, c, protocol.S_AssetUpdated, 12)
	}
	quiet(bob)
	alice.Close()
	aliceOther.Close()
	bob.Close()
	server.stop(t)
	server = startServerInWorkDir(t, dir)
	alice, aliceOther, bob = connect("alice"), connect("alice"), connect("bob")
	checkReads() // Privacy survives actual WAL recovery.
	apply(alice, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetDelete, Body: deletion}}, protocol.TransactionStatusCommitted)
	mustReadUntilOpcode(t, aliceOther, protocol.S_AssetDeleted, 12)
	quiet(bob)
	if assets := listAssetsFull(t, alice, 0); len(assets) != 2 {
		t.Fatalf("owner deletion failed: %+v", assets)
	}
	result := apply(alice, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetCreate, Body: creation}}, protocol.TransactionStatusCommitted)
	newPrivateID := result.Results[0].EntityID
	mustReadUntilOpcode(t, aliceOther, protocol.S_AssetCreated, 12)
	quiet(bob)
	send(alice, protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(0, newPrivateID))
	for _, c := range []*websocket.Conn{alice, aliceOther} {
		mustReadUntilOpcode(t, c, protocol.S_AssetDeleted, 12)
	}
	quiet(bob)
}

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
