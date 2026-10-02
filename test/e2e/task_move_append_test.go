package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// moveTaskAppend moves a task and asks the server for the end of the target
// column, answering with the acknowledgement so a case can read the position the
// server folded.
func moveTaskAppend(t *testing.T, conn *websocket.Conn, roomID int64, task *protocol.Task, status uint8) *protocol.TaskMovedResponse {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_MoveTask, protocol.EncodeTaskMoveAppend(roomID, int64(task.ID), status)); err != nil {
		t.Fatalf("move task %d to status %d with append: %v", task.ID, status, err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskMoved, 12)
	moved, err := protocol.DecodeTaskMoved(payload)
	if err != nil {
		t.Fatalf("decode moved task %d: %v payload=%x", task.ID, err, payload)
	}
	if moved.TaskID != task.ID || moved.Status != status {
		t.Fatalf("unexpected moved response: got task=%d status=%d, want task=%d status=%d", moved.TaskID, moved.Status, task.ID, status)
	}
	task.Status = moved.Status
	task.OrderIndex = moved.OrderIndex
	task.CompletedAt = moved.CompletedAt
	return moved
}

// readTask reads one task back through C_GetTask, so a case can assert what the
// server holds rather than what it acknowledged.
func readTask(t *testing.T, conn *websocket.Conn, roomID int64, taskID uint64) *protocol.Task {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_GetTask, protocol.EncodeGetTask(uint64(roomID), taskID, 0)); err != nil {
		t.Fatalf("read task %d: %v", taskID, err)
	}
	full, err := protocol.DecodeTaskFull(mustReadUntilOpcode(t, conn, protocol.S_TaskFull, 12))
	if err != nil {
		t.Fatalf("decode task %d: %v", taskID, err)
	}
	return full.Task
}

// A move may carry the Append flag instead of naming a position: a client that
// draws one page of a register does not hold the column, so the server folds the
// column and the acknowledgement, the broadcast and the durable record carry the
// folded position.
func TestTaskMoveAppendFoldsTheTargetColumn(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-task-append-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()
	// A second subscriber reads the broadcast the folded position travels in.
	observer, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "append-observer"))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect observer: %v", err)
	}
	defer observer.Close()
	mustSetReadDeadline(t, conn, 20*time.Second)
	mustSetReadDeadline(t, observer, 20*time.Second)
	mustExpectServerReady(t, conn)
	mustExpectServerReady(t, observer)
	mustSubscribeWorkspaceData(t, conn)
	mustSubscribeWorkspaceData(t, observer)

	const roomID int64 = protocol.WorkspaceDataConvID
	// The last position a u16 column can name.
	const lastPosition = uint16(0xFFFF)
	first := createQueryTask(t, conn, roomID, "append first")
	second := createQueryTask(t, conn, roomID, "append second")
	third := createQueryTask(t, conn, roomID, "append third")
	// Creation appends to its column, so the fixture holds Backlog orders 0, 1, 2.
	if first.OrderIndex != 0 || second.OrderIndex != 1 || third.OrderIndex != 2 {
		t.Fatalf("unexpected creation order indexes: %d, %d, %d", first.OrderIndex, second.OrderIndex, third.OrderIndex)
	}

	// The end of a column that carries three tasks is 3.
	if moved := moveTaskAppend(t, conn, roomID, first, protocol.TaskStatusBacklog); moved.OrderIndex != 3 {
		t.Fatalf("append to a loaded column: order_index = %d, want 3", moved.OrderIndex)
	}
	// The other subscriber is told the same position, with no correlation id.
	broadcast, err := protocol.DecodeTaskMoved(mustReadUntilOpcode(t, observer, protocol.S_TaskMoved, 12))
	if err != nil {
		t.Fatalf("decode append broadcast: %v", err)
	}
	if broadcast.TaskID != first.ID || broadcast.OrderIndex != 3 || broadcast.CorrelationID != 0 {
		t.Fatalf("append broadcast: got task=%d order=%d correlation=%d, want task=%d order=3 correlation=0",
			broadcast.TaskID, broadcast.OrderIndex, broadcast.CorrelationID, first.ID)
	}

	// An empty column appends at zero, and the next append lands after it.
	if moved := moveTaskAppend(t, conn, roomID, second, protocol.TaskStatusDone); moved.OrderIndex != 0 {
		t.Fatalf("append to an empty column: order_index = %d, want 0", moved.OrderIndex)
	}
	if moved := moveTaskAppend(t, conn, roomID, third, protocol.TaskStatusDone); moved.OrderIndex != 1 {
		t.Fatalf("second append to a column: order_index = %d, want 1", moved.OrderIndex)
	}

	// An explicit position still names one, which is what a drag sends.
	if err := sendProtocolMessage(conn, protocol.C_MoveTask, protocol.EncodeTaskMove(roomID, int64(first.ID), protocol.TaskStatusTodo, 7)); err != nil {
		t.Fatalf("move task %d with an explicit position: %v", first.ID, err)
	}
	explicit, err := protocol.DecodeTaskMoved(mustReadUntilOpcode(t, conn, protocol.S_TaskMoved, 12))
	if err != nil {
		t.Fatalf("decode explicitly positioned move: %v", err)
	}
	if explicit.OrderIndex != 7 {
		t.Fatalf("explicit position: order_index = %d, want 7", explicit.OrderIndex)
	}
	// A flag bit this build does not define is refused as a malformed request
	// instead of being read as a named position.
	unknownFlags := protocol.EncodeTaskMove(roomID, int64(first.ID), protocol.TaskStatusDone, 0)
	unknownFlags[17] = 0x02
	if err := sendProtocolMessage(conn, protocol.C_MoveTask, unknownFlags); err != nil {
		t.Fatalf("move task %d with an unknown flag bit: %v", first.ID, err)
	}
	unknownRefusal, unknownErr := protocol.DecodeErrorResponse(mustReadUntilOpcode(t, conn, protocol.S_ErrorResponse, 12))
	if unknownErr != nil {
		t.Fatalf("decode the answer to an unknown flag bit: %v", unknownErr)
	}
	if unknownRefusal.OriginOpcode != protocol.C_MoveTask {
		t.Fatalf("unknown flag bit answered for opcode %d, want %d", unknownRefusal.OriginOpcode, protocol.C_MoveTask)
	}
	if untouched := readTask(t, conn, roomID, first.ID); untouched.Status != protocol.TaskStatusTodo || untouched.OrderIndex != 7 {
		t.Fatalf("an unknown flag bit must not move the task: status=%d order=%d, want status=%d order=7",
			untouched.Status, untouched.OrderIndex, protocol.TaskStatusTodo)
	}
	if err := sendProtocolMessage(conn, protocol.C_MoveTask, protocol.EncodeTaskMove(roomID, int64(second.ID), protocol.TaskStatusBacklog, lastPosition)); err != nil {
		t.Fatalf("move task %d to the last position: %v", second.ID, err)
	}
	if last, err := protocol.DecodeTaskMoved(mustReadUntilOpcode(t, conn, protocol.S_TaskMoved, 12)); err != nil {
		t.Fatalf("decode last-position move: %v", err)
	} else if last.OrderIndex != lastPosition {
		t.Fatalf("last position: order_index = %d, want %d", last.OrderIndex, lastPosition)
	}
	// The exhausted column refuses the append, names the reason and leaves the task
	// where it was.
	beforeRefusal := *third
	if err := sendProtocolMessage(conn, protocol.C_MoveTask, protocol.EncodeTaskMoveAppend(roomID, int64(third.ID), protocol.TaskStatusBacklog)); err != nil {
		t.Fatalf("append to an exhausted column: %v", err)
	}
	refusal, refusalErr := protocol.DecodeTaskListResponse(mustReadUntilOpcode(t, conn, protocol.S_TaskListResponse, 12))
	if refusal == nil {
		t.Fatalf("append to an exhausted column should be refused: %v", refusalErr)
	}
	if refusal.Success {
		t.Fatalf("append to an exhausted column should not claim success: %+v", refusal)
	}
	if refusal.ErrorMessage != "Status column is full" {
		t.Fatalf("refusal message = %q, want %q", refusal.ErrorMessage, "Status column is full")
	}
	refused := readTask(t, conn, roomID, third.ID)
	if refused.Status != beforeRefusal.Status || refused.OrderIndex != beforeRefusal.OrderIndex {
		t.Fatalf("a refused append must not mutate the task: status=%d order=%d, want status=%d order=%d",
			refused.Status, refused.OrderIndex, beforeRefusal.Status, beforeRefusal.OrderIndex)
	}

	// The folded position is durable: it survives a restart. The task whose last
	// accepted write was an append is read back for the position the server folded
	// (its status moved with it), and the tasks whose last accepted write named a
	// position are read back for theirs — so the case fails when only one kind of
	// write is persisted. `first` carries the later explicit move, not its earlier
	// fold, because the last accepted write is the one the record holds.
	_ = conn.Close()
	_ = observer.Close()
	server.stop(t)
	server = startServerInWorkDir(t, serverWorkDir)
	defer server.stop(t)
	restored, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("reconnect after restart: %v", err)
	}
	defer restored.Close()
	mustSetReadDeadline(t, restored, 20*time.Second)
	mustExpectServerReady(t, restored)
	if folded := readTask(t, restored, roomID, third.ID); folded.Status != protocol.TaskStatusDone || folded.OrderIndex != 1 {
		t.Fatalf("durable append position after restart: task %d status=%d order_index=%d, want status=%d order=1",
			third.ID, folded.Status, folded.OrderIndex, protocol.TaskStatusDone)
	}
	if positioned := readTask(t, restored, roomID, first.ID); positioned.Status != protocol.TaskStatusTodo || positioned.OrderIndex != 7 {
		t.Fatalf("durable explicit position after restart: task %d status=%d order_index=%d, want status=%d order=7",
			first.ID, positioned.Status, positioned.OrderIndex, protocol.TaskStatusTodo)
	}
	if exhausted := readTask(t, restored, roomID, second.ID); exhausted.OrderIndex != lastPosition {
		t.Fatalf("durable explicit position after restart: task %d order_index = %d, want %d", second.ID, exhausted.OrderIndex, lastPosition)
	}
}
