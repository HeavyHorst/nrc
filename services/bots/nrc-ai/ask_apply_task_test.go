package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestApplyStopsUndispatchedActionsAtAuthorizationExpiry(t *testing.T) {
	_, memoryCtx, personal := personalFixture(t)
	c, requests := connectedListingTestClient(t)
	c.subscribedRooms[0] = true
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate(testAIOwner, "ws", 0, 0, "", agentModePlan)
	store.setExecutionPolicy(session.ID, "private", true)
	plan, _ := store.startPlan(session.ID)
	_, first, err := store.addCreateTaskAction(session.ID, plan.ID, "first", "", 1)
	if err != nil {
		t.Fatal(err)
	}
	_, second, err := store.addCreateTaskAction(session.ID, plan.ID, "second", "", 1)
	if err != nil {
		t.Fatal(err)
	}
	identity := testAIIdentity("ws")
	identity.ExpiresAt = time.Now().Add(2 * time.Second).Unix()
	body, _ := json.Marshal(askApplyRequest{Workspace: "ws", AgentSessionID: session.ID, PlanID: plan.ID, ActionIDs: []string{first.ID, second.ID}})
	r := httptest.NewRequest("POST", "/ask/apply", bytes.NewReader(body)).WithContext(memoryCtx)
	r.Header.Set("X-NRC-AI-Auth", testAIToken(identity))
	authenticate, err := newAIAuthentication(testAIKey, "test-issuer")
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		defer close(done)
		authenticate(handleAskApply(&WorkspaceManager{ctx: t.Context(), clients: map[string]*NRCClient{"ws": c}}, store)).ServeHTTP(w, r)
	}()
	select {
	case msg := <-requests:
		if msg.Opcode != protocol.C_CreateTask {
			t.Fatal("expected first write", msg.Opcode)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("first write missing")
	}
	// Do not acknowledge the first write: its outcome is unknown at expiry.
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("apply did not stop")
	}
	if w.Code != http.StatusOK {
		t.Fatal(w.Code, w.Body)
	}
	c.sendPing() // A wire-order barrier: no second mutation may precede this ping.
	select {
	case msg := <-requests:
		if msg.Opcode != protocol.C_Ping {
			t.Fatal("write dispatched after expiry", msg.Opcode)
		}
	case <-time.After(time.Second):
		t.Fatal("missing barrier")
	}
	got, _ := store.getPlan(session.ID, plan.ID)
	if len(got.Actions) != 2 || got.Actions[0].Status != "outcome_unknown" || got.Actions[1].Status != actionStatusFailed || !strings.Contains(got.Actions[1].Error, "not dispatched") {
		t.Fatalf("incorrect terminal outcomes: %+v", got.Actions)
	}
	_, _, retry, _, _, err := store.prepareApply(session.ID, plan.ID, []string{first.ID})
	if err != nil || len(retry) != 0 {
		t.Fatal("ambiguous write became replayable", retry, err)
	}
	receipt, err := personal.scope.ReadReceipt(t.Context(), "chat", session.ID, plan.ID, first.ID)
	if err != nil || receipt.State != "outcome_unknown" {
		t.Fatal("ambiguous write not durable", receipt, err)
	}
}

func TestApplyTaskUsesAuthoritativeRecordAndBlocker(t *testing.T) {
	for _, mode := range []string{"uncached", "stale-cache", "server-changed", "missing-blocker"} {
		t.Run(mode, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			if mode != "uncached" {
				c.taskCache[0] = map[uint64]*protocol.Task{7: {ID: 7, UpdatedAt: 123, Assignee: "stale-assignee"}}
			}
			store := newAgentSessionStore(time.Hour, 5)
			session, _ := store.getOrCreate(testAIOwner, "ws", 0, 0, "", agentModePlan)
			plan, _ := store.startPlan(session.ID)
			plan, action, err := store.addUpdateTaskAction(session.ID, plan.ID, 7, 456, "new title", "new description", "done", 27, 8)
			if err != nil {
				t.Fatal(err)
			}
			_, _, pending, _, _, err := store.prepareApply(session.ID, plan.ID, []string{action.ID})
			if err != nil || len(pending) != 1 {
				t.Fatalf("prepare: %v %+v", err, pending)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			nextRequest := func() *protocol.Message {
				select {
				case msg := <-requests:
					return msg
				case <-ctx.Done():
					t.Fatal("missing protocol request")
					return nil
				}
			}
			result := askApplyResponse{}
			done := make(chan struct{})
			go func() { defer close(done); applyUpdateTaskAction(ctx, c, store, 0, pending[0], &result) }()
			msg := nextRequest()
			if msg.Opcode != protocol.C_GetTask || binary.BigEndian.Uint64(msg.Data[8:]) != 7 {
				t.Fatal("apply did not load exact task")
			}
			id := binary.BigEndian.Uint32(msg.Data[16:])
			current := protocol.Task{ID: 7, ConvID: 0, UpdatedAt: 456, Assignee: "fresh-assignee", Color: 9, ExternalRef: "REF-7", DueAt: 987}
			if mode == "server-changed" {
				current.UpdatedAt = 457
			}
			c.settleDataRead(id, protocol.C_GetTask, &protocol.TaskFull{Success: true, Task: &current}, nil)
			if mode != "server-changed" {
				msg = nextRequest()
				if msg.Opcode != protocol.C_GetTask || binary.BigEndian.Uint64(msg.Data[8:]) != 8 {
					t.Fatal("blocker wasn't loaded authoritatively")
				}
				id = binary.BigEndian.Uint32(msg.Data[16:])
				if mode == "missing-blocker" {
					c.settleDataRead(id, protocol.C_GetTask, nil, context.Canceled)
				} else {
					c.settleDataRead(id, protocol.C_GetTask, &protocol.TaskFull{Success: true, Task: &protocol.Task{ID: 8}}, nil)
					msg = nextRequest()
					if msg.Opcode != protocol.C_UpdateTask {
						t.Fatalf("unexpected opcode %d", msg.Opcode)
					}
					id = binary.BigEndian.Uint32(msg.Data[len(msg.Data)-6:])
					want := protocol.EncodeTaskUpdateFullWithCorrelation(0, 7, "new title", "new description", protocol.TaskStatusDone, "fresh-assignee", 27, 9, "REF-7", 987, 8, nil, id)
					if !bytes.Equal(msg.Data, want) {
						t.Fatalf("update used stale/patched fields: %x", msg.Data)
					}
					c.settleTaskUpdate(id, &protocol.Task{ID: 7, Title: "new title", UpdatedAt: 789}, nil)
				}
			}
			select {
			case <-done:
			case <-ctx.Done():
				t.Fatal("apply hung")
			}
			if mode == "server-changed" || mode == "missing-blocker" {
				if len(result.Failed) != 1 || len(result.Applied) != 0 {
					t.Fatalf("unsafe apply: %+v", result)
				}
				if mode == "server-changed" && !strings.Contains(result.Failed[0].Error, "stale task precondition") {
					t.Fatal(result.Failed)
				}
				select {
				case <-requests:
					t.Fatal("unexpected update after failed precondition")
				default:
				}
			} else if len(result.Applied) != 1 || len(result.Failed) != 0 {
				t.Fatalf("valid fresh task rejected: %+v", result)
			}
		})
	}
}
