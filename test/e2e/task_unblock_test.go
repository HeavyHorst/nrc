package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestTaskCompletionUnblocksDependents(t *testing.T) {
	for _, mode := range []string{"update", "move", "transaction", "transaction_with_dependent_patch"} {
		t.Run(mode, func(t *testing.T) {
			workDir := t.TempDir()
			workspace := fmt.Sprintf("e2e-unblock-%s-%d", mode, time.Now().UnixNano())
			server := startServerInWorkDir(t, workDir)
			defer func() { server.stop(t) }()
			connect := func(username string) *websocket.Conn {
				conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, username))
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { conn.Close() })
				mustSetReadDeadline(t, conn, 20*time.Second)
				mustExpectServerReady(t, conn)
				return conn
			}
			requester := connect("unblock-requester")
			const roomID = protocol.WorkspaceDataConvID
			a := createQueryTask(t, requester, roomID, "blocker A")
			b := createQueryTask(t, requester, roomID, "dependent B")
			c := createQueryTask(t, requester, roomID, "dependent C")
			for _, pair := range [][2]uint64{{b.ID, a.ID}, {c.ID, b.ID}} {
				if err := sendProtocolMessage(requester, protocol.C_UpdateTask, protocol.EncodeTaskUpdate(roomID, int64(pair[0]), "", "", 255, 255, pair[1])); err != nil {
					t.Fatal(err)
				}
				mustReadUntilOpcode(t, requester, protocol.S_TaskUpdated, 12)
			}
			b = readTask(t, requester, roomID, b.ID)
			if b.BlockedBy != a.ID {
				t.Fatalf("fixture B blocker = %d, want %d", b.BlockedBy, a.ID)
			}
			peer := connect("unblock-observer")
			mustSubscribeWorkspaceData(t, requester)
			mustSubscribeWorkspaceData(t, peer)

			assertBlockedQuery := func(conn *websocket.Conn, ids ...uint64) {
				t.Helper()
				body, err := protocol.EncodeTaskQuery(protocol.TaskQuery{ConvID: roomID, StatusMask: 0x0f, Limit: 10, Color: 255, Blocked: 1, CorrelationID: 91})
				if err != nil {
					t.Fatal(err)
				}
				if err := sendProtocolMessage(conn, protocol.C_QueryTasks, body); err != nil {
					t.Fatal(err)
				}
				page, err := protocol.DecodeTaskQueryPage(mustReadUntilOpcode(t, conn, protocol.S_TaskQueryPage, 16))
				if err != nil {
					t.Fatal(err)
				}
				if int(page.TotalCount) != len(ids) || len(page.Tasks) != len(ids) || page.HasMore {
					t.Fatalf("blocked query = %+v, want IDs %v", page, ids)
				}
				seen := make(map[uint64]bool)
				for _, task := range page.Tasks {
					seen[task.ID] = true
				}
				for _, id := range ids {
					if !seen[id] {
						t.Fatalf("blocked query missing task %d: %v", id, seen)
					}
				}
			}
			assertBlockedQuery(requester, b.ID, c.ID)

			const correlation = 73
			opcode := protocol.C_UpdateTask
			body := protocol.EncodeTaskUpdateWithCorrelation(roomID, int64(a.ID), "", "", int32(protocol.TaskStatusDone), 255, 0, correlation)
			wantBStatus := uint8(protocol.TaskStatusBacklog)
			if mode == "move" {
				opcode = protocol.C_MoveTask
				body = protocol.EncodeTaskMoveWithCorrelation(roomID, int64(a.ID), protocol.TaskStatusDone, 7, correlation)
			} else if mode == "transaction" || mode == "transaction_with_dependent_patch" {
				opcode = protocol.C_ApplyTransaction
				patch, err := protocol.EncodeTransactionTaskPatch(protocol.TransactionTaskPatch{ConvID: roomID, Task: protocol.Existing(protocol.TransactionEntityTask, a.ID), Present: protocol.TransactionTaskPatchStatus, Status: protocol.TaskStatusDone})
				if err != nil {
					t.Fatal(err)
				}
				ops := []protocol.TransactionOperation{{Type: protocol.TransactionOpTaskPatch, Body: patch}}
				if mode == "transaction_with_dependent_patch" {
					wantBStatus = protocol.TaskStatusTodo
					patchB, err := protocol.EncodeTransactionTaskPatch(protocol.TransactionTaskPatch{ConvID: roomID, Task: protocol.Existing(protocol.TransactionEntityTask, b.ID), Present: protocol.TransactionTaskPatchStatus, Status: wantBStatus})
					if err != nil {
						t.Fatal(err)
					}
					ops = append([]protocol.TransactionOperation{{Type: protocol.TransactionOpTaskPatch, Body: patchB}}, ops...)
				}
				body, err = protocol.EncodeApplyTransaction(correlation, ops)
				if err != nil {
					t.Fatal(err)
				}
			}
			if err := sendProtocolMessage(requester, opcode, body); err != nil {
				t.Fatal(err)
			}

			// Wait for the durable mutation messages, not a Pong: control replies
			// may overtake messages waiting for the WAL group commit. Then drain
			// through a Pong and check for duplicate dependent notifications.
			for _, conn := range []*websocket.Conn{requester, peer} {
				unblocks, acknowledged := 0, false
				waitingForPong := false
				for {
					if !waitingForPong && unblocks > 0 && (conn != requester || acknowledged) {
						if err := sendProtocolMessage(conn, protocol.C_Ping, protocol.EncodePing(99)); err != nil {
							t.Fatal(err)
						}
						waitingForPong = true
					}
					message := mustReadProtocolMessage(t, conn)
					if message.Opcode == protocol.S_Pong && waitingForPong {
						break
					}
					switch message.Opcode {
					case protocol.S_TaskUpdated:
						update, err := protocol.DecodeTaskUpdated(message.Data)
						if err != nil {
							t.Fatal(err)
						}
						if update.Task.ID == b.ID {
							unblocks++
							if update.Task.BlockedBy != 0 || update.Task.Status != wantBStatus || update.Task.UpdatedAt <= b.UpdatedAt || update.CorrelationID != 0 {
								t.Fatalf("incorrect dependent broadcast: %+v task=%+v", update, update.Task)
							}
						}
						acknowledged = acknowledged || update.Task.ID == a.ID && update.Task.Status == protocol.TaskStatusDone && update.CorrelationID == correlation
					case protocol.S_TaskMoved:
						move, err := protocol.DecodeTaskMoved(message.Data)
						if err != nil {
							t.Fatal(err)
						}
						acknowledged = move.TaskID == a.ID && move.Status == protocol.TaskStatusDone && move.CorrelationID == correlation
					case protocol.S_TransactionResult:
						result, err := protocol.DecodeTransactionResult(message.Data)
						if err != nil {
							t.Fatal(err)
						}
						acknowledged = result.Status == protocol.TransactionStatusCommitted && result.CorrelationID == correlation
					}
				}
				if unblocks != 1 || conn == requester && !acknowledged {
					t.Fatalf("completion delivery: unblocks=%d acknowledged=%v requester=%v", unblocks, acknowledged, conn == requester)
				}
			}
			assertBlockedQuery(requester, c.ID)
			assertBlockedQuery(peer, c.ID)
			requester.Close()
			peer.Close()
			server.stop(t)
			server = startServerInWorkDir(t, workDir)
			restored := connect("unblock-restored")
			if task := readTask(t, restored, roomID, a.ID); task.Status != protocol.TaskStatusDone {
				t.Fatalf("blocker completion lost after restart: %+v", task)
			}
			if task := readTask(t, restored, roomID, b.ID); task.BlockedBy != 0 || task.Status != wantBStatus || task.Description != b.Description {
				t.Fatalf("dependent state lost after restart: %+v", task)
			}
			assertBlockedQuery(restored, c.ID)
			moveQueryTask(t, restored, roomID, a, protocol.TaskStatusBacklog)
			if task := readTask(t, restored, roomID, b.ID); task.BlockedBy != 0 {
				t.Fatalf("reopening A restored B's consumed dependency: %+v", task)
			}
			assertBlockedQuery(restored, c.ID)
		})
	}
}
