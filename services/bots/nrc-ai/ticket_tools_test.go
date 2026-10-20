package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func ticketTestContext(t *testing.T, s AgentSession, p ActionPlan) context.Context {
	ctx := context.WithValue(t.Context(), workspaceContextKey{}, "ws")
	ctx = context.WithValue(ctx, convIDContextKey{}, uint64(0))
	ctx = context.WithValue(ctx, agentModeContextKey{}, agentModePlan)
	ctx = context.WithValue(ctx, agentSessionContextKey{}, s.ID)
	return context.WithValue(ctx, actionPlanContextKey{}, p.ID)
}
func deliverTicketAsset(c *NRCClient, a protocol.Asset) {
	c.pendingAssetsMu.Lock()
	key := assetRequestKey{convID: 0, assetID: a.AssetID}
	chs := c.pendingAssets[key]
	delete(c.pendingAssets, key)
	c.pendingAssetsMu.Unlock()
	for _, ch := range chs {
		ch <- a
	}
}
func nextTicketRequest(t *testing.T, ch <-chan *protocol.Message) *protocol.Message {
	t.Helper()
	select {
	case m := <-ch:
		return m
	case <-time.After(2 * time.Second):
		t.Fatal("missing protocol request")
		return nil
	}
}
func TestTicketTypesAndPrivacy(t *testing.T) {
	for _, wire := range []string{`{"metadata":{"priority":null}}`, `{"metadata":{"priority":""}}`, `{"metadata":{"follow_up_at":null}}`, `{"metadata":{"follow_up_at":"01"}}`} {
		var a ticketAction
		if json.Unmarshal([]byte(wire), &a) == nil {
			t.Fatalf("accepted invalid schedule: %s", wire)
		}
	}
	a := ticketAction{Operation: "create", Metadata: map[string]string{"title": "Help", "priority": "urgent", "follow_up_at": "123"}}
	if err := validateTicketAction(&a); err != nil {
		t.Fatal(err)
	}
	preview, err := ticketPreview(a, protocol.Asset{})
	if err != nil || !bytes.Contains(preview, []byte(`"follow_up_at":"123"`)) {
		t.Fatalf("schedule preview: %s %v", preview, err)
	}
	r := ticketRecord(protocol.Asset{AssetType: protocol.AssetTypeTicket, Preview: `{}`, Payload: "original"}, true)
	if r["metadata"].(map[string]any)["priority"] != "normal" || r["payload"] != "original" {
		t.Fatalf("legacy read: %#v", r)
	}
	for name, want := range map[string]uint16{"ticket": 13, "tickets": 13, "13": 13, "entry": 14, "ticket_entry": 14, "entries": 14, "14": 14} {
		got, err := parseListAssetType(name)
		if err != nil || got != want {
			t.Fatalf("%s: %d %v", name, got, err)
		}
		types, err := parseAssetTypeFilters([]string{name})
		if err != nil || len(types) != 1 || types[0] != want {
			t.Fatal(types, err)
		}
	}
	if assetTypeName(13) != "Ticket" || assetTypeName(14) != "TicketEntry" {
		t.Fatal("missing names")
	}
	a = ticketAction{Operation: "entry", TicketID: "9007199254740993", ExpectedVersion: "456", Content: "staff only"}
	if err := validateTicketAction(&a); err != nil || a.Kind != "internal_note" {
		t.Fatal(a, err)
	}
	for _, kind := range []string{"customer_reply", "public_reply"} {
		a.Kind = kind
		if validateTicketAction(&a) == nil {
			t.Fatal("accepted unsafe kind/recipient", kind)
		}
	}
	a = ticketAction{Operation: "update_metadata", TicketID: "1", ExpectedVersion: "2", Content: "replace original"}
	if validateTicketAction(&a) == nil {
		t.Fatal("original writable")
	}
}

func TestTicketAndLinkedTaskProposalDependencies(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
	p, _ := store.startPlan(s.ID)
	ticket, err := store.addTicketAction(s.ID, p.ID, ticketAction{Operation: "create", Metadata: map[string]string{"title": "Ticket"}})
	if err != nil {
		t.Fatal(err)
	}
	_, task, err := store.addCreateTaskAction(s.ID, p.ID, "Follow up", "No status sync", 0)
	if err != nil {
		t.Fatal(err)
	}
	_, edge, err := store.addCreateEdgeAction(s.ID, p.ID, "Task", 0, task.ID, "Ticket", 0, ticket.ID, "related-to")
	if err != nil || edge.Relation != "related-to" {
		t.Fatal(edge, err)
	}
	store.completeAction(s.ID, p.ID, ticket.ID, nil, func(a *ProposedAction) { a.TicketResultID = "9007199254740993" })
	store.completeCreateTaskAction(s.ID, p.ID, task.ID, &protocol.Task{ID: 9}, nil)
	plan, _ := store.getPlan(s.ID, p.ID)
	typ, id, err := resolveActionEndpoint(edge.TargetType, 0, edge.TargetActionID, plan)
	if err != nil || typ != protocol.TargetTypeAsset || id != 9007199254740993 {
		t.Fatal(typ, id, err)
	}
}
func TestTicketSliceProposalAndApprovedApply(t *testing.T) {
	for _, scenario := range []string{"existing", "staged", "reverse_membership"} {
		t.Run(scenario, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			store := newAgentSessionStore(time.Hour, 5)
			s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
			p, _ := store.startPlan(s.ID)
			var sourceAction string
			sourceID := uint64(41)
			if scenario == "staged" {
				ticket, err := store.addTicketAction(s.ID, p.ID, ticketAction{Operation: "create", Metadata: map[string]string{"title": "Ticket"}})
				if err != nil {
					t.Fatal(err)
				}
				sourceID, sourceAction = 0, ticket.ID
				store.completeAction(s.ID, p.ID, ticket.ID, nil, func(a *ProposedAction) { a.TicketResultID = "41" })
			}
			_, edge, err := store.addCreateEdgeAction(s.ID, p.ID, "Ticket", sourceID, sourceAction, "Slice", 72, "", "member-of")
			if err != nil {
				t.Fatal(err)
			}
			_, _, pending, _, failures, err := store.prepareApply(s.ID, p.ID, []string{edge.ID})
			if err != nil || len(failures) != 0 || len(pending) != 1 {
				t.Fatal(pending, failures, err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			var result askApplyResponse
			done := make(chan struct{})
			go func() { defer close(done); applyCreateEdgeAction(ctx, c, store, 0, pending[0], &result) }()
			for _, asset := range []protocol.Asset{{AssetID: 41, AssetType: protocol.AssetTypeTicket}, {AssetID: 72, AssetType: protocol.AssetTypeSlice}} {
				m := nextTicketRequest(t, requests)
				if m.Opcode != protocol.C_GetAsset || binary.BigEndian.Uint64(m.Data[8:]) != asset.AssetID {
					t.Fatal(m)
				}
				deliverTicketAsset(c, asset)
			}
			m := nextTicketRequest(t, requests)
			if m.Opcode != protocol.C_ListAllEdges {
				t.Fatal(m.Opcode)
			}
			var edges []protocol.Edge
			if scenario == "reverse_membership" {
				edges = []protocol.Edge{{EdgeID: 99, SourceType: 1, SourceID: 72, TargetType: 1, TargetID: 41, Relation: protocol.RelationMemberOf}}
			}
			c.pendingEdgesMu.Lock()
			waiters := c.pendingEdges[0]
			delete(c.pendingEdges, 0)
			c.pendingEdgesMu.Unlock()
			for _, ch := range waiters {
				ch <- edges
			}
			if scenario != "reverse_membership" {
				m = nextTicketRequest(t, requests)
				id := binary.BigEndian.Uint32(m.Data[len(m.Data)-4:])
				want := protocol.EncodeCreateEdgeWithCorrelation(0, 1, 41, 1, 72, 7, id)
				if m.Opcode != protocol.C_CreateEdge || !bytes.Equal(m.Data, want) {
					t.Fatal("incorrect membership write", m)
				}
				c.pendingEdgeCreatesMu.Lock()
				acks := c.pendingEdgeCreates[id]
				delete(c.pendingEdgeCreates, id)
				c.pendingEdgeCreatesMu.Unlock()
				for _, ch := range acks {
					ch <- edgeCreateResult{Edge: &protocol.Edge{EdgeID: 99, SourceType: 1, SourceID: 41, TargetType: 1, TargetID: 72, Relation: 7}}
				}
			}
			<-done
			if len(result.Failed) != 0 || len(result.Applied) != 1 || result.Applied[0].AlreadyApplied != (scenario == "reverse_membership") {
				t.Fatal(result)
			}
			select {
			case m := <-requests:
				t.Fatal("unexpected extra write", m)
			default:
			}
		})
	}
}

func TestTicketProposalAndApprovedApply(t *testing.T) {
	for _, operation := range []string{"create", "entry", "update_metadata", "delete"} {
		t.Run(operation, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			c.subscribedRooms[0] = true
			c.taskSnapshots[0] = true
			store := newAgentSessionStore(time.Hour, 5)
			session, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
			plan, _ := store.startPlan(session.ID)
			ctx := ticketTestContext(t, session, plan)
			tools := newTicketTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, store)
			a := ticketAction{Operation: operation, TicketID: "9007199254740993", ExpectedVersion: "456"}
			if operation == "create" {
				a.Metadata = map[string]string{"title": "new ticket", "requester": "customer"}
				a.Content = "original request"
			} else if operation == "entry" {
				a.Content = "private reply"
			} else if operation == "update_metadata" {
				a.Metadata = map[string]string{"status": "resolved"}
			}
			current := protocol.Asset{AssetID: 9007199254740993, AssetType: 13, UpdatedAt: 456, Preview: `{"version":1,"title":"old","company_id":"","contact_id":"","requester":"customer","requester_name":"","status":"open","assignee":"","extra":"preserve"}`, Payload: "immutable body", Attachments: []protocol.Attachment{{FileId: "att_0123456789abcdef0123456789abcdef", Filename: "original.txt"}}}
			b, _ := json.Marshal(a)
			done := make(chan fantasy.ToolResponse, 1)
			go func() {
				r, err := tools[1].Run(ctx, fantasy.ToolCall{Input: string(b)})
				if err != nil {
					t.Error(err)
				}
				done <- r
			}()
			if operation != "create" {
				m := nextTicketRequest(t, requests)
				if m.Opcode != protocol.C_GetAsset {
					t.Fatal("proposal mutated NRC", m.Opcode)
				}
				deliverTicketAsset(c, current)
			}
			r := <-done
			if r.IsError {
				t.Fatal(r.Content)
			}
			select {
			case m := <-requests:
				t.Fatal("staging wrote", m.Opcode)
			default:
			}
			_, _, pending, _, _, err := store.prepareApply(session.ID, plan.ID, nil)
			if err != nil || len(pending) != 1 {
				t.Fatal(pending, err)
			}
			result := askApplyResponse{}
			applied := make(chan struct{})
			go func() { defer close(applied); applyTicketAction(ctx, c, store, pending[0], &result) }()
			if operation != "create" {
				m := nextTicketRequest(t, requests)
				if m.Opcode != protocol.C_GetAsset {
					t.Fatal(m.Opcode)
				}
				deliverTicketAsset(c, current)
			}
			m := nextTicketRequest(t, requests)
			if operation == "create" || operation == "entry" {
				if m.Opcode != protocol.C_CreateAsset {
					t.Fatal(m.Opcode)
				}
				typ, parent, parentID := uint16(13), uint16(0), uint64(0)
				preview := `{"assignee":"","company_id":"","contact_id":"","requester":"customer","requester_name":"","status":"open","title":"new ticket","version":1}`
				if operation == "entry" {
					typ = 14
					parent = 2
					parentID = current.AssetID
					preview = `{"author":"Sullivan","kind":"internal_note","version":1}`
				}
				id := binary.BigEndian.Uint32(m.Data[len(m.Data)-4:])
				want, e := protocol.EncodeCreateAssetWithAttachmentsAndCorrelation(0, typ, parent, parentID, preview, a.Content, nil, id)
				if e != nil || !bytes.Equal(m.Data, want) {
					t.Fatalf("wrong create contract: %x %v", m.Data, e)
				}
				c.settleAssetWrite(id, protocol.Asset{AssetID: 99}, nil)
			} else {
				if m.Opcode != protocol.C_ApplyTransaction {
					t.Fatal("blind write", m.Opcode)
				}
				id := binary.BigEndian.Uint32(m.Data[4:])
				var body []byte
				op := uint8(protocol.TransactionOpAssetPatch)
				if operation == "delete" {
					op = protocol.TransactionOpAssetDelete
					body, err = protocol.EncodeTransactionDelete(protocol.TransactionDelete{Entity: protocol.Existing(protocol.TransactionEntityAsset, current.AssetID), IfUpdatedAt: 456}, protocol.TransactionEntityAsset)
				} else {
					body, err = protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{Asset: protocol.Existing(protocol.TransactionEntityAsset, current.AssetID), IfUpdatedAt: 456, Present: protocol.TransactionAssetPatchPreview, Preview: []byte(`{"assignee":"","company_id":"","contact_id":"","extra":"preserve","requester":"customer","requester_name":"","status":"resolved","title":"old","version":1}`)})
				}
				want, e := protocol.EncodeApplyTransaction(id, []protocol.TransactionOperation{{Type: op, Body: body}})
				if err != nil || e != nil || !bytes.Equal(m.Data, want) {
					t.Fatal("version/payload/attachment preservation contract changed", err, e)
				}
				c.settleDataRead(id, protocol.C_ApplyTransaction, &protocol.TransactionResult{Status: 0}, nil)
			}
			<-applied
			if len(result.Applied) != 1 || len(result.Failed) != 0 {
				t.Fatal(result)
			}
			_, _, again, already, _, err := store.prepareApply(session.ID, plan.ID, nil)
			if err != nil || len(again) != 0 || len(already) != 1 {
				t.Fatal("approval replay", again, already, err)
			}
		})
	}
}
func TestTicketOptimisticConflictAndRecipient(t *testing.T) {
	for _, mode := range []string{"version", "recipient", "transaction"} {
		t.Run(mode, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			a := ticketAction{Operation: "update_metadata", TicketID: "7", ExpectedVersion: "456", Metadata: map[string]string{"status": "closed"}}
			current := protocol.Asset{AssetID: 7, AssetType: 13, UpdatedAt: 456, Preview: `{"version":1,"title":"old","company_id":"","contact_id":"","requester":"other","requester_name":"","status":"open","assignee":""}`}
			if mode == "version" {
				current.UpdatedAt++
			}
			if mode == "recipient" {
				a.Operation = "entry"
				a.Kind = "public_reply"
				a.Recipient = "customer"
				a.Content = "public"
				a.Metadata = nil
			}
			done := make(chan error, 1)
			go func() { _, e := c.applyTicket(ctx, a); done <- e }()
			m := nextTicketRequest(t, requests)
			if m.Opcode != protocol.C_GetAsset {
				t.Fatal(m.Opcode)
			}
			deliverTicketAsset(c, current)
			if mode == "transaction" {
				m = nextTicketRequest(t, requests)
				if m.Opcode != protocol.C_ApplyTransaction {
					t.Fatal(m.Opcode)
				}
				c.settleDataRead(binary.BigEndian.Uint32(m.Data[4:]), protocol.C_ApplyTransaction, &protocol.TransactionResult{Status: 1}, nil)
			}
			if e := <-done; e == nil {
				t.Fatal("unsafe apply accepted")
			}
			select {
			case m := <-requests:
				t.Fatal("write after failed precondition", m.Opcode)
			default:
			}
		})
	}
}
func TestPublicTicketProposalDisclosesValidatedAttachments(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	c.subscribedRooms[0] = true
	c.taskSnapshots[0] = true
	store := newAgentSessionStore(time.Hour, 5)
	s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
	p, _ := store.startPlan(s.ID)
	ctx := ticketTestContext(t, s, p)
	tools := newTicketTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, store)
	done := make(chan fantasy.ToolResponse, 1)
	go func() {
		r, _ := tools[1].Run(ctx, fantasy.ToolCall{Input: `{"operation":"entry","ticket_id":"7","expected_updated_at":"456","kind":"public_reply","recipient":"customer","content":"hello","attachments":[{"entity_type":"file","entity_id":"8"}]}`})
		done <- r
	}()
	m := nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_GetAsset {
		t.Fatal(m.Opcode)
	}
	deliverTicketAsset(c, protocol.Asset{AssetID: 7, AssetType: 13, UpdatedAt: 456, Preview: `{"requester":"customer"}`})
	m = nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_GetAsset {
		t.Fatal(m.Opcode)
	}
	deliverTicketAsset(c, protocol.Asset{AssetID: 8, AssetType: 3, Attachments: []protocol.Attachment{{FileId: "att_0123456789abcdef0123456789abcdef", Filename: "invoice.pdf"}}})
	r := <-done
	if r.IsError || !strings.Contains(r.Content, "PUBLIC REPLY") || !strings.Contains(r.Content, "customer portal") || !strings.Contains(r.Content, "invoice.pdf") || !strings.Contains(r.Content, "customer") {
		t.Fatal(r)
	}
	select {
	case m := <-requests:
		t.Fatal("proposal wrote", m.Opcode)
	default:
	}
	// API snapshots cannot mutate the approved recipient or metadata.
	plan, _ := store.getPlan(s.ID, p.ID)
	plan.Actions[0].Ticket.Recipient = "attacker"
	plan, _ = store.getPlan(s.ID, p.ID)
	if plan.Actions[0].Ticket.Recipient != "customer" {
		t.Fatal("shared approval state")
	}
	_, _, pending, _, _, err := store.prepareApply(s.ID, p.ID, nil)
	if err != nil || len(pending) != 1 {
		t.Fatal(err)
	}
	result := askApplyResponse{}
	applied := make(chan struct{})
	go func() { defer close(applied); applyTicketAction(ctx, c, store, pending[0], &result) }()
	for _, id := range []uint64{7, 8, 7} {
		m = nextTicketRequest(t, requests)
		if m.Opcode != protocol.C_GetAsset || binary.BigEndian.Uint64(m.Data[8:]) != id {
			t.Fatal("missing recipient/source revalidation", m.Opcode)
		}
		if id == 7 {
			deliverTicketAsset(c, protocol.Asset{AssetID: 7, AssetType: 13, UpdatedAt: 456, Preview: `{"requester":"customer"}`})
		} else {
			deliverTicketAsset(c, protocol.Asset{AssetID: 8, AssetType: 3, Attachments: []protocol.Attachment{{FileId: "att_0123456789abcdef0123456789abcdef", Filename: "invoice.pdf"}}})
		}
	}
	m = nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_CreateAsset {
		t.Fatal(m.Opcode)
	}
	id := binary.BigEndian.Uint32(m.Data[len(m.Data)-12:])
	want, e := protocol.EncodeCreateAssetWithParentVersionAndCorrelation(0, 14, 2, 7, `{"author":"Sullivan","kind":"public_reply","recipient":"customer","version":1}`, "hello", []protocol.Attachment{{FileId: "att_0123456789abcdef0123456789abcdef", Filename: "invoice.pdf"}}, 456, id)
	if e != nil || !bytes.Equal(m.Data, want) {
		t.Fatal("wrong public entry contract", e)
	}
	c.settleAssetWrite(id, protocol.Asset{AssetID: 99}, nil)
	<-applied
	if len(result.Applied) != 1 || len(result.Failed) != 0 {
		t.Fatal(result)
	}
}

func TestTicketConversationReadsFullRecordsAndAttachments(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	c.subscribedRooms[0] = true
	c.taskSnapshots[0] = true
	store := newAgentSessionStore(time.Hour, 5)
	s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
	p, _ := store.startPlan(s.ID)
	ctx := ticketTestContext(t, s, p)
	tools := newTicketTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, store)
	done := make(chan fantasy.ToolResponse, 1)
	go func() {
		r, _ := tools[0].Run(ctx, fantasy.ToolCall{Input: `{"ticket_id":"7","include_payload":true,"limit":2}`})
		done <- r
	}()
	m := nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_GetAsset {
		t.Fatal(m.Opcode)
	}
	deliverTicketAsset(c, protocol.Asset{AssetID: 7, AssetType: 13, Preview: `{"title":"original"}`, Payload: "original body"})
	m = nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_ListAssetsPaged || binary.BigEndian.Uint16(m.Data[8:]) != 14 {
		t.Fatal(m.Opcode)
	}
	id := binary.BigEndian.Uint32(m.Data[14:])
	c.settleAssetPage(id, &protocol.AssetListPageResponse{HasMore: true, NextCursorAssetID: 9, NextCursorUpdatedAt: 123, Assets: []protocol.Asset{
		{AssetID: 8, AssetType: 14, ParentType: 2, ParentID: 999},
		{AssetID: 9, AssetType: 14, ParentType: 2, ParentID: 7, Preview: `{"kind":"internal_note"}`},
	}}, nil)
	m = nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_GetAsset || binary.BigEndian.Uint64(m.Data[8:]) != 9 {
		t.Fatal("did not load full matching entry")
	}
	deliverTicketAsset(c, protocol.Asset{AssetID: 9, AssetType: 14, ParentType: 2, ParentID: 7, Preview: `{"kind":"internal_note"}`, Payload: "private body", Attachments: []protocol.Attachment{{FileId: "att_0123456789abcdef0123456789abcdef", Filename: "evidence.txt"}}})
	r := <-done
	for _, value := range []string{"original body", "private body", "evidence.txt", `"has_more":true`, `"cursor_id":"9"`} {
		if r.IsError || !strings.Contains(r.Content, value) {
			t.Fatal(r)
		}
	}
	if strings.Contains(r.Content, "999") {
		t.Fatal("cross-ticket entry leaked", r.Content)
	}
	// Read-only mode rejects staging before any backend access.
	ctx = context.WithValue(ctx, agentModeContextKey{}, agentModeAsk)
	r, err := tools[1].Run(ctx, fantasy.ToolCall{Input: `{"operation":"create","metadata":{"title":"no"}}`})
	if err == nil && !r.IsError {
		t.Fatal("ask mode staged mutation")
	}
	select {
	case m := <-requests:
		t.Fatal("unexpected request", m.Opcode)
	default:
	}
}

// A dispatched write without a response is ambiguous for every ticket operation.
// Definite wire-level server rejection, unlike timeout, permits another attempt.
func TestTicketCommittedWithoutACKBlocksReplay(t *testing.T) {
	for _, operation := range []string{"create", "entry", "update_metadata", "delete"} {
		for _, reject := range []bool{false, true} {
			t.Run(operation+map[bool]string{false: "/lost_ack", true: "/rejected"}[reject], func(t *testing.T) {
				c, requests := connectedListingTestClient(t)
				store := newAgentSessionStore(time.Hour, 5)
				s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
				p, _ := store.startPlan(s.ID)
				a := ticketAction{Operation: operation, Metadata: map[string]string{"title": "test"}}
				if operation != "create" {
					a.TicketID = "7"
					a.ExpectedVersion = "456"
				}
				if operation == "entry" {
					a.Metadata = nil
					a.Content = "note"
				}
				if _, err := store.addTicketAction(s.ID, p.ID, a); err != nil {
					t.Fatal(err)
				}
				_, _, pending, _, _, _ := store.prepareApply(s.ID, p.ID, nil)
				ctx, cancel := context.WithTimeout(t.Context(), 250*time.Millisecond)
				defer cancel()
				done := make(chan struct{})
				var result askApplyResponse
				go func() { defer close(done); applyTicketAction(ctx, c, store, pending[0], &result) }()
				if operation != "create" {
					m := nextTicketRequest(t, requests)
					if m.Opcode != protocol.C_GetAsset {
						t.Fatal(m.Opcode)
					}
					deliverTicketAsset(c, protocol.Asset{AssetID: 7, AssetType: 13, UpdatedAt: 456, Preview: `{"version":1,"title":"old","company_id":"","contact_id":"","requester":"","requester_name":"","status":"open","assignee":""}`})
				}
				m := nextTicketRequest(t, requests)
				if reject {
					var id uint32
					if m.Opcode == protocol.C_CreateAsset {
						id = binary.BigEndian.Uint32(m.Data[len(m.Data)-4:])
					} else {
						id = binary.BigEndian.Uint32(m.Data[4:])
					}
					payload := make([]byte, 12)
					binary.BigEndian.PutUint16(payload, m.Opcode)
					binary.BigEndian.PutUint16(payload[2:], 4)
					copy(payload[4:], "nope")
					binary.BigEndian.PutUint32(payload[8:], id)
					c.handleErrorResponse(payload)
				}
				<-done
				plan, _ := store.getPlan(s.ID, p.ID)
				want := "outcome_unknown"
				if reject {
					want = actionStatusFailed
				}
				if plan.Actions[0].Status != want || len(result.Failed) != 1 {
					t.Fatal(plan, result)
				}
				if !reject && !strings.Contains(plan.Actions[0].Error, "context deadline exceeded") {
					t.Fatal("expected post-dispatch timeout", plan.Actions[0].Error)
				}
				_, _, again, _, failures, err := store.prepareApply(s.ID, p.ID, nil)
				if err != nil {
					t.Fatal(err)
				}
				if reject {
					if len(again) != 1 {
						t.Fatal("rejection not retryable")
					}
				} else if len(again) != 0 || len(failures) != 1 {
					t.Fatal("unknown outcome replayed", again, failures)
				}
				select {
				case m := <-requests:
					t.Fatal("duplicate write", m.Opcode)
				default:
				}
			})
		}
	}
}

func TestTicketFinalPreviewValidatedBeforeUpload(t *testing.T) {
	uploads := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { uploads++; w.WriteHeader(500) }))
	defer srv.Close()
	c, requests := connectedListingTestClient(t)
	c.filesURL = srv.URL
	c.botSecret = "test"
	// The input patch fits, but the complete schema does not.
	a := ticketAction{Operation: "create", Metadata: map[string]string{"title": strings.Repeat("x", protocol.MaxPreviewLength-100)}, GeneratedFiles: []ticketGeneratedFile{{Filename: "x.txt", Content: "x"}}}
	if err := validateTicketAction(&a); err != nil {
		t.Fatal("fixture must pass input validation", err)
	}
	if _, err := c.applyTicket(t.Context(), a); err == nil || !strings.Contains(err.Error(), "preview limit") {
		t.Fatal(err)
	}
	if uploads != 0 {
		t.Fatal("uploaded before final preview validation")
	}
	select {
	case m := <-requests:
		t.Fatal("write before validation", m.Opcode)
	default:
	}
}

func TestTicketRealWorkerCreateAndSuppressedACK(t *testing.T) {
	serverURL := os.Getenv("NRC_AI_TICKET_TEST_URL")
	if serverURL == "" {
		t.Skip("requires disposable authenticated staff WebSocket fixture: NRC_AI_TICKET_TEST_URL")
	}
	for _, suppress := range []bool{false, true} {
		t.Run(fmt.Sprintf("suppress_ack=%t", suppress), func(t *testing.T) {
			c := NewNRCClient(Config{NRCServer: serverURL}, fmt.Sprintf("ai-ticket-%d", time.Now().UnixNano()))
			upload := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				file, header, err := r.FormFile("file")
				if err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				defer file.Close()
				data, _ := io.ReadAll(file)
				if header.Filename != "worker.txt" || string(data) != "generated evidence" {
					t.Error("unexpected generated upload")
				}
				json.NewEncoder(w).Encode(map[string]any{"fileId": "att_0123456789abcdef0123456789abcdef", "filename": "worker.txt", "mimeType": "text/plain", "size": len(data), "uploadedAt": 123})
			}))
			defer upload.Close()
			c.filesURL, c.botSecret = upload.URL, "test-only-upload"
			if err := c.connect(t.Context()); err != nil {
				t.Fatal(err)
			}
			ack := make(chan protocol.Asset, 8)
			readerDone := make(chan struct{})
			go func() {
				defer close(readerDone)
				for {
					_, b, err := c.conn.ReadMessage()
					if err != nil {
						return
					}
					m, err := protocol.ReadMessage(b)
					if err != nil {
						continue
					}
					switch m.Opcode {
					case protocol.S_AssetCreated:
						r, err := protocol.DecodeAssetCreated(m.Data)
						if err != nil {
							t.Error(err)
							return
						}
						ack <- r.Asset
						if !suppress {
							c.handleAssetCreated(m.Data)
						}
					case protocol.S_AssetFull:
						c.handleAssetFull(m.Data)
					case protocol.S_TransactionResult:
						c.handleDataRead(m.Opcode, m.Data)
					case protocol.S_ErrorResponse:
						c.handleErrorResponse(m.Data)
					}
				}
			}()
			t.Cleanup(func() { c.conn.Close(); <-readerDone })
			store := newAgentSessionStore(time.Hour, 5)
			s, _ := store.getOrCreate(c.workspace, 0, 0, "", agentModePlan)
			p, _ := store.startPlan(s.ID)
			if _, err := store.addTicketAction(s.ID, p.ID, ticketAction{Operation: "create", Metadata: map[string]string{"title": "AI real worker", "requester": "ada@example.test"}, Content: "original body", GeneratedFiles: []ticketGeneratedFile{{Filename: "worker.txt", Content: "generated evidence"}}}); err != nil {
				t.Fatal(err)
			}
			_, _, pending, _, _, _ := store.prepareApply(s.ID, p.ID, nil)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			done := make(chan struct{})
			var result askApplyResponse
			go func() { defer close(done); applyTicketAction(ctx, c, store, pending[0], &result) }()
			var committed protocol.Asset
			select {
			case committed = <-ack:
			case <-ctx.Done():
				t.Fatal("worker did not commit", ctx.Err())
			}
			if suppress {
				cancel()
			}
			<-done
			readCtx, stop := context.WithTimeout(t.Context(), 5*time.Second)
			defer stop()
			got, err := c.GetAsset(readCtx, 0, committed.AssetID)
			if err != nil || got.Payload != "original body" || got.AssetType != 13 {
				t.Fatal(got, err)
			}
			if len(got.Attachments) != 1 || got.Attachments[0].Filename != "worker.txt" || got.Attachments[0].Size != 18 {
				t.Fatal("generated file not persisted with real ticket", got.Attachments)
			}
			metadata, err := ticketMetadata(got)
			if err != nil || len(metadata) != 8 || metadata["company_id"] != "" || metadata["status"] != "open" {
				t.Fatal(metadata, err)
			}
			plan, _ := store.getPlan(s.ID, p.ID)
			_, _, again, already, failures, err := store.prepareApply(s.ID, p.ID, nil)
			if err != nil || len(again) != 0 {
				t.Fatal("write replay", again, err)
			}
			if suppress {
				if plan.Actions[0].Status != "outcome_unknown" || len(failures) != 1 || len(result.Failed) != 1 {
					t.Fatal(plan, result, failures)
				}
			} else if len(already) != 1 || len(result.Applied) != 1 || result.Applied[0].TicketAssetID != strconv.FormatUint(got.AssetID, 10) {
				t.Fatal(result, already)
			}
			if !suppress {
				id := strconv.FormatUint(got.AssetID, 10)
				_, err := c.applyTicket(readCtx, ticketAction{Operation: "update_metadata", TicketID: id, ExpectedVersion: strconv.FormatInt(got.UpdatedAt, 10), Metadata: map[string]string{"requester": "bob@example.test"}})
				if err != nil {
					t.Fatal(err)
				}
				preview := `{"version":1,"kind":"public_reply","author":"Sullivan"}`
				_, err = c.createAssetAttachments(readCtx, 0, 14, 2, got.AssetID, preview, "Approved for Ada", got.Attachments, got.UpdatedAt)
				if _, rejected := err.(*ticketWriteRejection); !rejected || !strings.Contains(err.Error(), "version conflict") {
					t.Fatal("stale public reply was not rejected by actual worker", err)
				}
				fresh, err := c.GetAsset(readCtx, 0, got.AssetID)
				if err != nil || fresh.UpdatedAt <= got.UpdatedAt {
					t.Fatal(fresh, err)
				}
				entry, err := c.createAssetAttachments(readCtx, 0, 14, 2, got.AssetID, preview, "Approved for Bob", got.Attachments, fresh.UpdatedAt)
				if err != nil || len(entry.Attachments) != 1 || entry.Payload != "Approved for Bob" {
					t.Fatal("guarded public reply and attachment not committed together", entry, err)
				}
				t.Logf("real worker rejected stale recipient version, accepted current version with attachment (entry %d)", entry.AssetID)
			}
			t.Logf("worker persisted ticket %d; suppressed_ack=%t; status=%s; replay_dispatches=%d", got.AssetID, suppress, plan.Actions[0].Status, len(again))
		})
	}
}

func TestGeneratedTicketFileUploadsOnlyOnApprovedApply(t *testing.T) {
	uploads := make(chan struct{}, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/upload" || r.URL.Query().Get("workspace") != "ws" || r.Header.Get("Authorization") != "Bearer test-only" {
			t.Error("wrong private upload contract")
		}
		file, header, err := r.FormFile("file")
		if err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		defer file.Close()
		data, _ := io.ReadAll(file)
		if header.Filename != "report.txt" || string(data) != "approved content" {
			t.Error("wrong generated file")
		}
		uploads <- struct{}{}
		json.NewEncoder(w).Encode(map[string]any{"fileId": "att_0123456789abcdef0123456789abcdef", "filename": "report.txt", "mimeType": "text/plain", "size": len(data), "uploadedAt": 123})
	}))
	defer srv.Close()
	c, requests := connectedListingTestClient(t)
	c.filesURL = srv.URL
	c.botSecret = "test-only"
	c.subscribedRooms[0] = true
	c.taskSnapshots[0] = true
	store := newAgentSessionStore(time.Hour, 5)
	s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
	p, _ := store.startPlan(s.ID)
	ctx := ticketTestContext(t, s, p)
	tools := newTicketTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, store)
	r, err := tools[1].Run(ctx, fantasy.ToolCall{Input: `{"operation":"create","metadata":{"title":"Generated report"},"generated_files":[{"filename":"report.txt","content":"approved content"}]}`})
	if err != nil || r.IsError {
		t.Fatal(r, err)
	}
	select {
	case <-uploads:
		t.Fatal("blob uploaded before approval")
	default:
	}
	select {
	case m := <-requests:
		t.Fatal("NRC write before approval", m.Opcode)
	default:
	}
	_, _, pending, _, _, err := store.prepareApply(s.ID, p.ID, nil)
	if err != nil || len(pending) != 1 {
		t.Fatal(err)
	}
	result := askApplyResponse{}
	done := make(chan struct{})
	go func() { defer close(done); applyTicketAction(ctx, c, store, pending[0], &result) }()
	m := nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_CreateAsset || !bytes.Contains(m.Data, []byte("report.txt")) || !bytes.Contains(m.Data, []byte("att_0123456789abcdef0123456789abcdef")) {
		t.Fatal("uploaded file not attached")
	}
	c.settleAssetWrite(binary.BigEndian.Uint32(m.Data[len(m.Data)-4:]), protocol.Asset{AssetID: 9007199254740993}, nil)
	<-done
	if len(result.Applied) != 1 || result.Applied[0].TicketAssetID != "9007199254740993" {
		t.Fatal(result)
	}
	select {
	case <-uploads:
	default:
		t.Fatal("approved blob not uploaded")
	}
	select {
	case <-uploads:
		t.Fatal("duplicate upload")
	default:
	}
}
