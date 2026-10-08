package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"strings"
	"testing"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestApplyTaskUsesAuthoritativeRecordAndBlocker(t *testing.T) {
	for _, mode := range []string{"uncached", "stale-cache", "server-changed", "missing-blocker"} {
		t.Run(mode, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			if mode != "uncached" {
				c.taskCache[0] = map[uint64]*protocol.Task{7: {ID: 7, UpdatedAt: 123, Assignee: "stale-assignee"}}
			}
			store := newAgentSessionStore(time.Hour, 5)
			session, _ := store.getOrCreate("ws", 0, 0, "", agentModePlan)
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
