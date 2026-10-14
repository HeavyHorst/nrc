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

func TestBatchReads(t *testing.T) {
	server := startServerInWorkDir(t, t.TempDir())
	defer server.stop(t)
	workspace := fmt.Sprintf("batch-%d", time.Now().UnixNano())
	alice := workspaceDataClient(t, workspace, "alice", 31)
	defer alice.Close()
	taskA := createQueryTask(t, alice, 0, "first")
	taskB := createQueryTask(t, alice, 0, "second")
	createQueryTask(t, alice, 0, "not requested")
	assets := make([]protocol.Asset, 3)
	for i := range assets {
		// Three legal full records exceed a single response's byte budget.
		body := protocol.EncodeCreateAsset(0, protocol.AssetTypeNote, 0, 0,
			fmt.Sprintf(`{"title":"Note %d"}`, i), strings.Repeat(string(rune('a'+i)), 60000))
		if err := sendProtocolMessage(alice, protocol.C_CreateAsset, body); err != nil {
			t.Fatal(err)
		}
		created, err := protocol.DecodeAssetCreated(mustReadUntilOpcode(t, alice, protocol.S_AssetCreated, 12))
		if err != nil {
			t.Fatal(err)
		}
		assets[i] = created.Asset
	}
	personal := `{"title":"private","visibility":"personal","deadline_at":"100"}`
	if err := sendProtocolMessage(alice, protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeReminder, 0, 0, personal, personal)); err != nil {
		t.Fatal(err)
	}
	privateCreated, err := protocol.DecodeAssetCreated(mustReadUntilOpcode(t, alice, protocol.S_AssetCreated, 12))
	if err != nil {
		t.Fatal(err)
	}
	private := privateCreated.Asset
	bob := workspaceDataClient(t, workspace, "bob", 31)
	defer bob.Close()
	send := func(c *websocket.Conn, opcode uint16, ids []uint64, full bool, correlation uint32) {
		t.Helper()
		body, err := protocol.EncodeGetRecordsByIDs(ids, full, correlation)
		if err != nil {
			t.Fatal(err)
		}
		if err = sendProtocolMessage(c, opcode, body); err != nil {
			t.Fatal(err)
		}
	}
	send(bob, protocol.C_GetTasksByIDs, []uint64{taskB.ID, 999999, taskA.ID, taskB.ID}, true, 701)
	tasks, err := protocol.DecodeTaskListPage(mustReadUntilOpcode(t, bob, protocol.S_TaskListPage, 12))
	if err != nil {
		t.Fatal(err)
	}
	if !tasks.Success || tasks.HasMore || tasks.CorrelationID != 701 || len(tasks.Tasks) != 2 ||
		tasks.Tasks[0].Title != "second" || tasks.Tasks[1].Title != "first" {
		t.Fatalf("wrong task set: %+v", tasks)
	}
	for _, full := range []bool{false, true} {
		send(bob, protocol.C_GetAssetsByIDs, []uint64{assets[2].AssetID, private.AssetID, assets[0].AssetID, 999999, assets[1].AssetID, assets[0].AssetID}, full, 702)
		var found []protocol.Asset
		chunks := 0
		for {
			payload := mustReadUntilOpcode(t, bob, protocol.S_AssetListPage, 12)
			if len(payload)+2 > 131072 {
				t.Fatal("response exceeds transport budget")
			}
			page, err := protocol.DecodeAssetListPage(payload)
			if err != nil {
				t.Fatal(err)
			}
			if page.CorrelationID != 702 || page.FullContent != full || page.TotalCount != 3 {
				t.Fatalf("wrong asset page: %+v", page)
			}
			found = append(found, page.Assets...)
			chunks++
			if !page.HasMore {
				break
			}
		}
		if len(found) != 3 || found[0].AssetID != assets[2].AssetID || found[1].AssetID != assets[0].AssetID || found[2].AssetID != assets[1].AssetID {
			t.Fatalf("wrong asset set: %v", found)
		}
		if full && (chunks != 2 || found[0].Payload != assets[2].Payload) {
			t.Fatal("full contents not chunked or preserved")
		}
		if !full && (chunks != 1 || found[0].Payload != "") {
			t.Fatal("preview read included bodies")
		}
	}
	send(alice, protocol.C_GetAssetsByIDs, []uint64{private.AssetID}, false, 703)
	ownerPage, err := protocol.DecodeAssetListPage(mustReadUntilOpcode(t, alice, protocol.S_AssetListPage, 24))
	if err != nil || len(ownerPage.Assets) != 1 {
		t.Fatalf("owner cannot read private asset: %v", err)
	}
	for _, opcode := range []uint16{protocol.C_GetTasksByIDs, protocol.C_GetAssetsByIDs} {
		send(bob, opcode, nil, false, 704)
		response := protocol.S_TaskListPage
		if opcode == protocol.C_GetAssetsByIDs {
			response = protocol.S_AssetListPage
		}
		mustReadUntilOpcode(t, bob, response, 12)
		body, _ := protocol.EncodeGetRecordsByIDs(nil, false, 705)
		binary.BigEndian.PutUint16(body[13:], 65)
		if err := sendProtocolMessage(bob, opcode, body); err != nil {
			t.Fatal(err)
		}
		mustReadErrorResponse(t, bob, opcode, 705)
		body, _ = protocol.EncodeGetRecordsByIDs(nil, false, 706)
		binary.BigEndian.PutUint64(body, 123)
		if err := sendProtocolMessage(bob, opcode, body); err != nil {
			t.Fatal(err)
		}
		mustReadErrorResponse(t, bob, opcode, 0) // Scope rejection precedes request parsing.
	}
}
