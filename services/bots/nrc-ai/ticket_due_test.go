package main

import (
	"encoding/binary"
	"strings"
	"testing"
	"time"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestReadTicketsServerDuePreservesCursor(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	c.subscribedRooms[0] = true
	c.taskSnapshots[0] = true
	store := newAgentSessionStore(time.Hour, 5)
	s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
	p, _ := store.startPlan(s.ID)
	ctx := ticketTestContext(t, s, p)
	tools := newTicketTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, store)
	done := make(chan fantasy.ToolResponse, 1)
	go func() { r, _ := tools[0].Run(ctx, fantasy.ToolCall{Input: `{"follow_up_due":true}`}); done <- r }()
	m := nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_ListAssetsPaged {
		t.Fatal(m.Opcode)
	}
	c.settleAssetPage(binary.BigEndian.Uint32(m.Data[14:]), &protocol.AssetListPageResponse{HasMore: true, NextCursorAssetID: 9, NextCursorUpdatedAt: 123, Assets: []protocol.Asset{
		{AssetID: 8, AssetType: 13, Preview: `{"follow_up_at":"9223372036854775807"}`},
		{AssetID: 9, AssetType: 13, Preview: `{"follow_up_at":"1"}`},
	}}, nil)
	m = nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_QueryTickets || !strings.Contains(string(m.Data[4:]), `"follow_up":"due"`) {
		t.Fatal(m)
	}
	// Settle through the correlated transport with the server-confirmed membership.
	c.settleDataRead(binary.BigEndian.Uint32(m.Data), protocol.C_QueryTickets, &protocol.TicketPage{Metadata: []byte(`{}`), Assets: []protocol.Asset{{AssetID: 8}}}, nil)
	m = nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_GetAsset || binary.BigEndian.Uint64(m.Data[8:]) != 8 {
		t.Fatal(m)
	}
	deliverTicketAsset(c, protocol.Asset{AssetID: 8, AssetType: 13, Preview: `{"follow_up_at":"9223372036854775807"}`})
	r := <-done
	for _, want := range []string{`"asset_id":"8"`, `"has_more":true`, `"cursor_id":"9"`, `"cursor_updated_at":"123"`} {
		if r.IsError || !strings.Contains(r.Content, want) {
			t.Fatal(r)
		}
	}
}

func TestTicketQueryResponseCorrelationAndErrors(t *testing.T) {
	c := NewNRCClient(Config{}, "ws")
	ch := make(chan dataReadResult, 1)
	c.dataReads = map[uint32]pendingDataRead{42: {protocol.C_QueryTickets, ch}}
	b := make([]byte, 13)
	binary.BigEndian.PutUint32(b, 41)
	binary.BigEndian.PutUint32(b[4:], 2)
	copy(b[8:], `{}`)
	c.handleDataRead(protocol.S_TicketPage, b)
	if len(ch) != 0 {
		t.Fatal("wrong correlation settled request")
	}
	binary.BigEndian.PutUint32(b, 42)
	c.handleDataRead(protocol.S_TicketPage, b[:12])
	if len(ch) != 0 {
		t.Fatal("malformed response settled request")
	}
	c.handleDataRead(protocol.S_TicketPage, b)
	if r := <-ch; r.err != nil || r.value.(*protocol.TicketPage).CorrelationID != 42 {
		t.Fatal(r)
	}
	c.dataReads[42] = pendingDataRead{protocol.C_QueryTickets, ch}
	b = make([]byte, 12)
	binary.BigEndian.PutUint16(b, protocol.C_QueryTickets)
	binary.BigEndian.PutUint16(b[2:], 4)
	copy(b[4:], "nope")
	binary.BigEndian.PutUint32(b[8:], 42)
	c.handleErrorResponse(b)
	if r := <-ch; r.err == nil || r.err.Error() != "nope" {
		t.Fatal(r)
	}
}
