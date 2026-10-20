package e2e

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestPersonListsCompleteAndRecovered(t *testing.T) {
	dir := t.TempDir()
	server := startServerInWorkDir(t, dir)
	defer func() { server.stop(t) }()
	connect := func(workspace string) *websocket.Conn {
		t.Helper()
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "organizer"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 60*time.Second)
		mustExpectServerReady(t, c)
		return c
	}
	c := connect("person-lists")
	send := func(op uint16, body []byte) {
		t.Helper()
		if err := sendProtocolMessage(c, op, body); err != nil {
			t.Fatal(err)
		}
	}
	check := func(op uint16, want []string) {
		t.Helper()
		send(op, p.EncodeListTaskProjects(0, 431))
		var got []string
		for {
			body := mustReadUntilOpcode(t, c, op+106, 10)
			var page *p.StringList
			var err error
			switch op {
			case p.C_ListSliceOwners:
				page, err = p.DecodeSliceOwners(body)
			case p.C_ListTicketAssignees:
				page, err = p.DecodeTicketAssignees(body)
			case p.C_ListCalendarPeople:
				page, err = p.DecodeCalendarPeople(body)
			}
			if err != nil {
				t.Fatal(err)
			}
			if page.ConvID != 0 || page.CorrelationID != 431 {
				t.Fatalf("wrong scope/correlation: %+v", page)
			}
			got = append(got, page.Values...)
			if !page.HasMore {
				break
			}
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("opcode %d: got %q want %q", op, got, want)
		}
	}
	create := func(kind uint16, preview string) uint64 {
		t.Helper()
		send(p.C_CreateAsset, p.EncodeCreateAsset(0, kind, p.ParentTypeNone, 0, preview, ""))
		created, err := p.DecodeAssetCreated(mustReadUntilOpcode(t, c, p.S_AssetCreated, 10))
		if err != nil {
			t.Fatal(err)
		}
		return created.Asset.AssetID
	}
	check(p.C_ListSliceOwners, nil)
	// The oldest, closed slice would be absent from the first 100-row register
	// page. No record pages are fetched by this connection at all.
	old := create(p.AssetTypeSlice, `{"version":1,"name":"Old","owner":"old-only","closed":true}`)
	for i := 0; i < 103; i++ {
		create(p.AssetTypeSlice, fmt.Sprintf(`{"version":1,"name":"Slice %d","owner":"common"}`, i))
	}
	create(p.AssetTypeTicket, `{"version":1,"title":"Closed","status":"closed","assignee":"ticket-only","company_id":"","contact_id":"","requester":"","requester_name":""}`)
	create(p.AssetTypeAppointment, `{"version":2,"title":"Series","start_at":"1792404000000000000","end_at":"","timezone":"UTC","repeat":"daily","weekdays":[],"until":"","assignee":"alice","participants":["bob"],"conference":"none","exceptions":[{"at":"1792490400000000000","cancelled":false,"participants":["carol"]}]}`)
	checkAll := func() {
		check(p.C_ListSliceOwners, []string{"common", "old-only"})
		check(p.C_ListTicketAssignees, []string{"ticket-only"})
		check(p.C_ListCalendarPeople, []string{"alice", "bob", "carol", "organizer"})
	}
	checkAll()
	// Scope zero still isolates workspaces, and nonzero conversation IDs are
	// rejected rather than exposing room/DM metadata.
	original := c
	c = connect("person-lists-other")
	check(p.C_ListSliceOwners, nil)
	check(p.C_ListTicketAssignees, nil)
	check(p.C_ListCalendarPeople, nil)
	c = original
	send(p.C_ListSliceOwners, p.EncodeListSliceOwners(7, 431))
	mustReadUntilOpcode(t, c, p.S_ErrorResponse, 10)
	c.Close()
	server.stop(t)
	server = startServerInWorkDir(t, dir)
	c = connect("person-lists")
	checkAll()
	send(p.C_UpdateAsset, p.EncodeUpdateAsset(0, old, `{"version":1,"name":"Old","owner":"renamed","closed":true}`, ""))
	mustReadUntilOpcode(t, c, p.S_AssetUpdated, 10)
	check(p.C_ListSliceOwners, []string{"common", "renamed"})
	send(p.C_DeleteAsset, p.EncodeDeleteAsset(0, old))
	mustReadUntilOpcode(t, c, p.S_AssetDeleted, 10)
	check(p.C_ListSliceOwners, []string{"common"})
}
