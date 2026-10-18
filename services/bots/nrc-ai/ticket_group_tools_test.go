package main

import (
	"bytes"
	"charm.land/fantasy"
	"encoding/binary"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"strings"
	"testing"
	"time"
)

func TestTicketGroupApplyRevalidatesMembership(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	name := "Team"
	members := []string{"8"}
	a := ticketAction{Operation: "group", Group: &ticketGroupAction{Operation: "create", CompanyID: "7", ExpectedVersion: "456", GroupID: "team", Name: &name, ContactIDs: &members}}
	done := make(chan error, 1)
	go func() { _, err := c.applyTicket(t.Context(), a); done <- err }()
	if m := nextTicketRequest(t, requests); m.Opcode != protocol.C_GetAsset {
		t.Fatal(m.Opcode)
	}
	deliverTicketAsset(c, protocol.Asset{AssetID: 7, AssetType: protocol.AssetTypeCustomerCompany, UpdatedAt: 456, Preview: `{"version":1}`})
	m := nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_ListEdgesPaged {
		t.Fatal("expected scoped company links", m.Opcode)
	}
	c.settleDataRead(binary.BigEndian.Uint32(m.Data[len(m.Data)-4:]), protocol.C_ListEdgesPaged, &protocol.EdgeListPageResponse{TargetType: 1, TargetID: 7}, nil)
	if m := nextTicketRequest(t, requests); m.Opcode != protocol.C_GetAsset {
		t.Fatal(m.Opcode)
	}
	deliverTicketAsset(c, protocol.Asset{AssetID: 8, AssetType: protocol.AssetTypeCustomerContact})
	if err := <-done; err == nil || !strings.Contains(err.Error(), "not a company member") {
		t.Fatal(err)
	}
	select {
	case m := <-requests:
		t.Fatal("write despite revoked membership", m.Opcode)
	default:
	}
}

func TestTicketGroupNonemptyRevocationWithPagedCompanyLinks(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	members := []string{"8"}
	a := ticketAction{Operation: "group", Group: &ticketGroupAction{Operation: "update", CompanyID: "7", ExpectedVersion: "456", GroupID: "tech", ContactIDs: &members}}
	done := make(chan error, 1)
	go func() { _, err := c.applyTicket(t.Context(), a); done <- err }()
	nextTicketRequest(t, requests)
	deliverTicketAsset(c, protocol.Asset{AssetID: 7, AssetType: protocol.AssetTypeCustomerCompany, UpdatedAt: 456, Preview: `{"version":1,"ticket_groups":[{"id":"tech","name":"Tech","contact_ids":["8","9"]}]}`})
	// Membership is on the second company page; unrelated workspace edges must
	// not require a global, response-size-limited ListAllEdges request.
	for page := 0; page < 2; page++ {
		m := nextTicketRequest(t, requests)
		if m.Opcode != protocol.C_ListEdgesPaged || binary.BigEndian.Uint64(m.Data[10:]) != 7 || binary.BigEndian.Uint64(m.Data[20:]) != uint64(page*100) {
			t.Fatal("not a paged company query", m.Opcode)
		}
		edges := []protocol.Edge{{EdgeID: 101, SourceType: 1, SourceID: 8, TargetType: 1, TargetID: 7, Relation: protocol.RelationMemberOf}}
		if page == 0 {
			edges = make([]protocol.Edge, 100)
			for i := range edges {
				edges[i] = protocol.Edge{EdgeID: uint64(i + 1), SourceType: 1, SourceID: 7, TargetType: 1, TargetID: uint64(i + 1000), Relation: protocol.RelationRelatedTo}
			}
		}
		c.settleDataRead(binary.BigEndian.Uint32(m.Data[len(m.Data)-4:]), protocol.C_ListEdgesPaged, &protocol.EdgeListPageResponse{TargetType: 1, TargetID: 7, HasMore: page == 0, NextEdgeID: 100, Edges: edges}, nil)
	}
	nextTicketRequest(t, requests)
	deliverTicketAsset(c, protocol.Asset{AssetID: 8, AssetType: protocol.AssetTypeCustomerContact})
	m := nextTicketRequest(t, requests)
	if m.Opcode != protocol.C_ApplyTransaction || !strings.Contains(string(m.Data), `"contact_ids":["8"]`) || strings.Contains(string(m.Data), `"9"`) {
		t.Fatal("partial revocation not preserved", m.Opcode, string(m.Data))
	}
	c.settleDataRead(binary.BigEndian.Uint32(m.Data[4:]), protocol.C_ApplyTransaction, &protocol.TransactionResult{Status: protocol.TransactionStatusCommitted}, nil)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestTicketGroupProposalRejectsConflictingCompanyChanges(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	c.subscribedRooms[0], c.taskSnapshots[0] = true, true
	store := newAgentSessionStore(time.Hour, 5)
	s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
	plan, _ := store.startPlan(s.ID)
	ctx := ticketTestContext(t, s, plan)
	tools := newTicketGroupTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, store)
	company := protocol.Asset{AssetID: 7, AssetType: protocol.AssetTypeCustomerCompany, UpdatedAt: 456, Preview: `{"version":1,"ticket_groups":[{"id":"tech","name":"Tech","contact_ids":[]},{"id":"project","name":"Project","contact_ids":[]}]}`}
	for i, group := range []string{"tech", "tech", "project"} {
		done := make(chan error, 1)
		go func() {
			_, err := tools[1].Run(ctx, fantasy.ToolCall{Input: `{"operation":"delete","company_id":"7","group_id":"` + group + `","expected_updated_at":"456"}`})
			done <- err
		}()
		if m := nextTicketRequest(t, requests); m.Opcode != protocol.C_GetAsset {
			t.Fatal(m.Opcode)
		}
		deliverTicketAsset(c, company)
		err := <-done
		if i < 2 && err != nil {
			t.Fatal("first proposal or identical retry rejected", err)
		}
		if i == 2 && (err == nil || !strings.Contains(err.Error(), "apply it and read the company again")) {
			t.Fatal("inherently conflicting approval accepted", err)
		}
	}
	staged, _ := store.getPlan(s.ID, plan.ID)
	if len(staged.Actions) != 1 || staged.Actions[0].Ticket.Group.GroupID != "tech" {
		t.Fatal("rejection changed the approved plan", staged.Actions)
	}
}

func TestTicketGroupTextApprovalIdentifiesExactChange(t *testing.T) {
	for _, operation := range []string{"create", "update", "delete"} {
		t.Run(operation, func(t *testing.T) {
			g := &ticketGroupAction{Operation: operation, CompanyID: "71", GroupID: "tech", ExpectedVersion: "456"}
			if operation != "delete" {
				name := "Technik"
				contacts := []string{"81", "92"}
				g.Name, g.ContactIDs = &name, &contacts
			}
			a := ProposedAction{ID: "1", Type: "ticket_group", Ticket: &ticketAction{Operation: "group", Group: g}}
			for _, text := range []string{ensureProposedActionsInAnswer("Ready for approval.", []ProposedAction{a}), formatActionPlanSummary(a)} {
				for _, want := range []string{operation, `group "tech"`, "company #71", "read and reply", "existing and future tickets", "public attachments", "No transitive sharing"} {
					if !strings.Contains(text, want) {
						t.Fatal("approval omitted exact change/disclosure", want, text)
					}
				}
				if operation != "delete" && (!strings.Contains(text, "Technik") || !strings.Contains(text, "81, 92")) {
					t.Fatal("approval omitted replacement members", text)
				}
			}
		})
	}
}

func TestTicketGroupProposalAndApply(t *testing.T) {
	for _, scenario := range []string{"delete", "revoke", "stale", "conflict"} {
		t.Run(scenario, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			c.subscribedRooms[0] = true
			c.taskSnapshots[0] = true
			store := newAgentSessionStore(time.Hour, 5)
			s, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
			p, _ := store.startPlan(s.ID)
			ctx := ticketTestContext(t, s, p)
			tools := newTicketGroupTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, store)
			company := protocol.Asset{AssetID: 7, AssetType: protocol.AssetTypeCustomerCompany, UpdatedAt: 456, Preview: `{"version":1,"unknown":9007199254740993,"ticket_groups":[{"id":"staff","name":"Staff","contact_ids":["999"]}]}`, Payload: "preserved body"}
			input := `{"operation":"delete","company_id":"7","group_id":"staff","expected_updated_at":"456"}`
			if scenario == "revoke" {
				input = `{"operation":"update","company_id":"7","group_id":"staff","expected_updated_at":"456","contact_ids":[]}`
			}
			done := make(chan fantasy.ToolResponse, 1)
			go func() { r, _ := tools[1].Run(ctx, fantasy.ToolCall{Input: input}); done <- r }()
			if m := nextTicketRequest(t, requests); m.Opcode != protocol.C_GetAsset {
				t.Fatal(m.Opcode)
			}
			deliverTicketAsset(c, company)
			r := <-done
			if r.IsError || !strings.Contains(r.Content, "existing and future") || !strings.Contains(r.Content, "reply") {
				t.Fatal(r)
			}
			select {
			case m := <-requests:
				t.Fatal("preapproval write", m.Opcode)
			default:
			}
			plan, _ := store.getPlan(s.ID, p.ID)
			plan.Actions[0].Ticket.Group.GroupID = "tampered"
			plan, _ = store.getPlan(s.ID, p.ID)
			if plan.Actions[0].Ticket.Group.GroupID != "staff" {
				t.Fatal("snapshot alias")
			}
			_, _, pending, _, _, err := store.prepareApply(s.ID, p.ID, nil)
			if err != nil || len(pending) != 1 {
				t.Fatal(err, pending)
			}
			var result askApplyResponse
			applied := make(chan struct{})
			go func() { defer close(applied); applyTicketAction(ctx, c, store, pending[0], &result) }()
			if m := nextTicketRequest(t, requests); m.Opcode != protocol.C_GetAsset {
				t.Fatal(m.Opcode)
			}
			if scenario == "stale" {
				company.UpdatedAt++
			}
			deliverTicketAsset(c, company)
			if scenario != "stale" {
				m := nextTicketRequest(t, requests)
				if m.Opcode != protocol.C_ApplyTransaction {
					t.Fatal(m.Opcode)
				}
				if !strings.Contains(string(m.Data), `9007199254740993`) {
					t.Fatal("unknown metadata lost")
				}
				id := binary.BigEndian.Uint32(m.Data[4:])
				preview := `{"ticket_groups":[],"unknown":9007199254740993,"version":1}`
				if scenario == "revoke" {
					preview = `{"ticket_groups":[{"id":"staff","name":"Staff","contact_ids":[]}],"unknown":9007199254740993,"version":1}`
				}
				body, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{Asset: protocol.Existing(protocol.TransactionEntityAsset, 7), IfUpdatedAt: 456, Present: protocol.TransactionAssetPatchPreview, Preview: []byte(preview)})
				want, encodeErr := protocol.EncodeApplyTransaction(id, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: body}})
				if err != nil || encodeErr != nil || !bytes.Equal(m.Data, want) {
					t.Fatal("conditional preview-only preservation contract", err, encodeErr)
				}
				status := uint8(protocol.TransactionStatusCommitted)
				if scenario == "conflict" {
					status = 1
				}
				c.settleDataRead(id, protocol.C_ApplyTransaction, &protocol.TransactionResult{Status: status}, nil)
			}
			<-applied
			if scenario == "stale" || scenario == "conflict" {
				if len(result.Failed) != 1 {
					t.Fatal(result)
				}
			} else if len(result.Applied) != 1 {
				t.Fatal(result)
			}
			select {
			case m := <-requests:
				t.Fatal("unexpected contact lookup/write after revoke", m.Opcode)
			default:
			}
		})
	}
}
