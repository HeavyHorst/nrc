package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestTaskPersistenceAcrossRestart(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-task-persist-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client before restart: %v", err)
	}

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	const taskTitle = "persisted task title"
	const taskDescription = "task should survive restart"
	const taskProject = "e2e-project"
	const taskPriority int32 = 4

	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateFullWithCorrelation(roomID, taskTitle, taskDescription, taskPriority, taskProject, nil, 0)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateTask: %v", err)
	}

	taskCreatedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	taskCreated, err := protocol.DecodeTaskCreated(taskCreatedPayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_TaskCreated payload: %v payload=%x", err, taskCreatedPayload)
	}
	if taskCreated.CorrelationID != 0 {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("unexpected CreateTask correlation_id for helper payload: got %d want 0", taskCreated.CorrelationID)
	}
	createdTask := taskCreated.Task
	if createdTask.ID == 0 {
		_ = conn.Close()
		server.stop(t)
		t.Fatal("created task id is zero")
	}
	if createdTask.Title != taskTitle {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("created task title mismatch: got %q want %q", createdTask.Title, taskTitle)
	}
	if createdTask.Project != taskProject {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("created task project mismatch: got %q want %q", createdTask.Project, taskProject)
	}

	_ = conn.Close()
	server.stop(t)

	server = startServerInWorkDir(t, serverWorkDir)
	defer server.stop(t)

	connAfterRestart, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client after restart: %v", err)
	}
	defer connAfterRestart.Close()

	mustSetReadDeadline(t, connAfterRestart, 5*time.Second)
	mustExpectServerReady(t, connAfterRestart)

	if err := sendProtocolMessage(connAfterRestart, protocol.C_GetTasks, protocol.EncodeGetTasks(roomID)); err != nil {
		t.Fatalf("failed to send GetTasks after restart: %v", err)
	}

	taskListPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_TaskListResponse, 12)
	taskList, err := protocol.DecodeTaskListResponse(taskListPayload)
	if err != nil {
		t.Fatalf("failed to decode TaskListResponse after restart: %v payload=%x", err, taskListPayload)
	}
	if taskList.ConvID != uint64(roomID) {
		t.Fatalf("task list conv_id mismatch: got %d want %d", taskList.ConvID, roomID)
	}

	var restoredTask *protocol.Task
	for _, task := range taskList.Tasks {
		if task.ID == createdTask.ID {
			restoredTask = task
			break
		}
	}
	if restoredTask == nil {
		t.Fatalf("created task id %d missing after restart; got %d tasks", createdTask.ID, len(taskList.Tasks))
	}
	if restoredTask.Title != taskTitle {
		t.Fatalf("restored task title mismatch: got %q want %q", restoredTask.Title, taskTitle)
	}
	if restoredTask.Description != taskDescription {
		t.Fatalf("restored task description mismatch: got %q want %q", restoredTask.Description, taskDescription)
	}
	if restoredTask.Priority != uint8(taskPriority) {
		t.Fatalf("restored task priority mismatch: got %d want %d", restoredTask.Priority, taskPriority)
	}
	if restoredTask.Project != taskProject {
		t.Fatalf("restored task project mismatch: got %q want %q", restoredTask.Project, taskProject)
	}
}
