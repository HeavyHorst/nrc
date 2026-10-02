package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const (
	activeTaskStatusMask = uint8(1<<protocol.TaskStatusBacklog | 1<<protocol.TaskStatusTodo | 1<<protocol.TaskStatusInProgress)
	doneTaskStatusMask   = uint8(1 << protocol.TaskStatusDone)
)

func createQueryTask(t *testing.T, conn *websocket.Conn, roomID int64, title string) *protocol.Task {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreate(roomID, title, "query e2e", 1)); err != nil {
		t.Fatalf("create task %q: %v", title, err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	created, err := protocol.DecodeTaskCreated(payload)
	if err != nil {
		t.Fatalf("decode created task %q: %v payload=%x", title, err, payload)
	}
	return created.Task
}

func moveQueryTask(t *testing.T, conn *websocket.Conn, roomID int64, task *protocol.Task, status uint8) {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_MoveTask, protocol.EncodeTaskMove(roomID, int64(task.ID), status, 0)); err != nil {
		t.Fatalf("move task %d to status %d: %v", task.ID, status, err)
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
	task.CompletedAt = moved.CompletedAt
}

func listTaskQueryPage(t *testing.T, conn *websocket.Conn, roomID int64, statusMask uint8, limit uint16, cursor *protocol.TaskPageCursor) *protocol.TaskListPage {
	t.Helper()
	request, err := protocol.EncodeListTasksPaged(uint64(roomID), statusMask, limit, cursor, 0)
	if err != nil {
		t.Fatalf("encode ListTasksPaged: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_ListTasksPaged, request); err != nil {
		t.Fatalf("send ListTasksPaged: %v", err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskListPage, 12)
	page, err := protocol.DecodeTaskListPage(payload)
	if err != nil {
		t.Fatalf("decode S_TaskListPage: %v payload=%x", err, payload)
	}
	if page.ConvID != uint64(roomID) {
		t.Fatalf("task page conv_id=%d, want %d", page.ConvID, roomID)
	}
	return page
}

func drainTaskQuery(t *testing.T, conn *websocket.Conn, roomID int64, mask uint8, cursorTime func(*protocol.Task) int64) []*protocol.Task {
	t.Helper()
	var all []*protocol.Task
	seen := make(map[uint64]bool)
	var cursor *protocol.TaskPageCursor
	for pageNumber := 0; pageNumber < 20; pageNumber++ {
		page := listTaskQueryPage(t, conn, roomID, mask, 2, cursor)
		for _, task := range page.Tasks {
			if seen[task.ID] {
				t.Fatalf("task %d duplicated across cursor boundary on page %d", task.ID, pageNumber+1)
			}
			seen[task.ID] = true
			all = append(all, task)
		}
		if !page.HasMore {
			return all
		}
		if len(page.Tasks) == 0 {
			t.Fatalf("page %d claims has_more with no tasks", pageNumber+1)
		}
		last := page.Tasks[len(page.Tasks)-1]
		if page.NextCursor.SortAt != cursorTime(last) || page.NextCursor.TaskID != last.ID {
			t.Fatalf("page %d cursor (%d,%d) does not match last task (%d,%d)", pageNumber+1, page.NextCursor.SortAt, page.NextCursor.TaskID, cursorTime(last), last.ID)
		}
		next := page.NextCursor
		cursor = &next
	}
	t.Fatal("task paging did not terminate")
	return nil
}

func assertTaskOrderDesc(t *testing.T, tasks []*protocol.Task, timestamp func(*protocol.Task) int64) {
	t.Helper()
	for i := 1; i < len(tasks); i++ {
		previousAt, currentAt := timestamp(tasks[i-1]), timestamp(tasks[i])
		if previousAt < currentAt || (previousAt == currentAt && tasks[i-1].ID < tasks[i].ID) {
			t.Fatalf("tasks not ordered timestamp/task_id descending at %d: (%d,%d) then (%d,%d)", i, previousAt, tasks[i-1].ID, currentAt, tasks[i].ID)
		}
	}
}

func TestTaskQueryActiveDefaultMaskPagesWithoutDuplicates(t *testing.T) {
	_ = startServer(t)
	workspace := fmt.Sprintf("e2e-task-query-active-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "task-query-active"))
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer conn.Close()
	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	tasks := make([]*protocol.Task, 6)
	for i := range tasks {
		tasks[i] = createQueryTask(t, conn, roomID, fmt.Sprintf("active-page-%d", i))
	}
	moveQueryTask(t, conn, roomID, tasks[1], protocol.TaskStatusTodo)
	moveQueryTask(t, conn, roomID, tasks[2], protocol.TaskStatusInProgress)
	moveQueryTask(t, conn, roomID, tasks[5], protocol.TaskStatusDone)

	active := drainTaskQuery(t, conn, roomID, activeTaskStatusMask, func(task *protocol.Task) int64 { return task.UpdatedAt })
	if len(active) != 5 {
		t.Fatalf("active query returned %d tasks, want 5", len(active))
	}
	for _, task := range active {
		if task.Status == protocol.TaskStatusDone {
			t.Fatalf("active default mask returned Done task %d", task.ID)
		}
	}
	assertTaskOrderDesc(t, active, func(task *protocol.Task) int64 { return task.UpdatedAt })
}

func TestTaskQueryDoneHistoryDirectGetAndRestart(t *testing.T) {
	workDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-task-query-done-%d", time.Now().UnixNano())
	server := startServerInWorkDir(t, workDir)
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "task-query-done"))
	if err != nil {
		server.stop(t)
		t.Fatalf("connect: %v", err)
	}
	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	done := make([]*protocol.Task, 4)
	for i := range done {
		done[i] = createQueryTask(t, conn, roomID, fmt.Sprintf("done-history-%d", i))
		moveQueryTask(t, conn, roomID, done[i], protocol.TaskStatusDone)
	}
	history := drainTaskQuery(t, conn, roomID, doneTaskStatusMask, func(task *protocol.Task) int64 { return task.CompletedAt })
	if len(history) != len(done) {
		t.Fatalf("Done history returned %d tasks, want %d", len(history), len(done))
	}
	assertTaskOrderDesc(t, history, func(task *protocol.Task) int64 { return task.CompletedAt })

	requested := done[1]
	if err := sendProtocolMessage(conn, protocol.C_GetTask, protocol.EncodeGetTask(uint64(roomID), requested.ID, 0)); err != nil {
		t.Fatalf("send GetTask: %v", err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskFull, 12)
	full, err := protocol.DecodeTaskFull(payload)
	if err != nil {
		t.Fatalf("decode S_TaskFull: %v payload=%x", err, payload)
	}
	if full.Task.ID != requested.ID || full.Task.Status != protocol.TaskStatusDone || full.Task.CompletedAt == 0 {
		t.Fatalf("direct completed task mismatch: %+v", full.Task)
	}

	_ = conn.Close()
	server.stop(t)
	server = startServerInWorkDir(t, workDir)
	defer server.stop(t)
	conn, _, err = websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "task-query-done-reader"))
	if err != nil {
		t.Fatalf("reconnect after restart: %v", err)
	}
	defer conn.Close()
	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	restored := drainTaskQuery(t, conn, roomID, doneTaskStatusMask, func(task *protocol.Task) int64 { return task.CompletedAt })
	if len(restored) != len(done) {
		t.Fatalf("Done history after restart returned %d tasks, want %d", len(restored), len(done))
	}
	assertTaskOrderDesc(t, restored, func(task *protocol.Task) int64 { return task.CompletedAt })
}
