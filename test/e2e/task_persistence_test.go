package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestCreateTaskCrashAtCommitBoundary(t *testing.T) {
	lib := buildCommitFault(t)
	for _, phase := range []string{"before", "after"} {
		t.Run(phase, func(t *testing.T) {
			const workspace, title = "task-crash", "commit candidate"
			dir := t.TempDir()
			path := filepath.Join(dir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", xxhash.Sum64String(workspace)%256), "workspace.sqlite3")
			arm, reached := filepath.Join(dir, "arm"), filepath.Join(dir, "reached")
			server := startServerInWorkDirWithEnv(t, dir, map[string]string{
				"NRC_THREAD_COUNT": "1", "LD_PRELOAD": lib, "NRC_TEST_COMMIT_KIND": "task",
				"NRC_TEST_COMMIT_DB": path, "NRC_TEST_COMMIT_ARM": arm, "NRC_TEST_COMMIT_REACHED": reached,
			})
			t.Cleanup(func() { server.killAndWait(t) })
			connect := func() *websocket.Conn {
				t.Helper()
				c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "writer"))
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { c.Close() })
				mustSetReadDeadline(t, c, 15*time.Second)
				mustExpectServerReady(t, c)
				return c
			}
			c := connect()
			attachment := protocol.Attachment{FileId: "file-73", Filename: "notes.txt", Size: 327, MimeType: "text/plain", UploadedAt: 173}
			if err := os.WriteFile(arm, []byte(phase), 0600); err != nil {
				t.Fatal(err)
			}
			if err := sendProtocolMessage(c, protocol.C_CreateTask, protocol.EncodeTaskCreateFullWithCorrelation(protocol.WorkspaceDataConvID, title, "", 1, "", []protocol.Attachment{attachment}, 73)); err != nil {
				t.Fatal(err)
			}
			waitForCommitBoundary(t, reached, phase)
			server.killAndWait(t)
			// Drain bytes already delivered to the client, including any premature reply.
			for {
				msg, err := readFaultCampaignMessage(c)
				if websocket.IsCloseError(err, websocket.CloseAbnormalClosure) {
					break
				}
				if err != nil {
					t.Fatal(err)
				}
				if msg.Opcode == protocol.S_TaskCreated || msg.Opcode == protocol.S_TaskListResponse {
					t.Fatalf("unexpected reply at %s COMMIT: %+v", phase, msg)
				}
			}
			server = startServerInWorkDirWithEnv(t, dir, map[string]string{"NRC_THREAD_COUNT": "1"})
			tasks, err := listFaultCampaignTasks(connect())
			if err != nil {
				t.Fatal(err)
			}
			var id uint64
			if phase == "after" {
				if len(tasks) != 1 || tasks[0].Title != title || tasks[0].ID == 0 || len(tasks[0].Attachments) != 1 || tasks[0].Attachments[0] != attachment {
					t.Fatalf("recovered tasks: %+v", tasks)
				}
				id = tasks[0].ID
			} else if len(tasks) != 0 {
				t.Fatalf("uncommitted tasks: %+v", tasks)
			}
			// A public task read cannot expose orphan attachments or stray history.
			check := exec.Command("python3", "-c", `
import json, sqlite3, sys
path, workspace, title, identity = sys.argv[1:]
with sqlite3.connect(path) as db:
    n = int(int(identity) != 0)
    for table in ('tasks', 'task_attachments', 'history'):
        count = db.execute('SELECT count(*) FROM ' + table).fetchone()[0]
        assert count == n, (table, count, n)
    if n:
        scope, kind, entity, body = db.execute('SELECT workspace, entity_kind, entity_id, body FROM history').fetchone()
        event = json.loads(body)
        assert (scope, kind, int.from_bytes(entity, 'big')) == (workspace.encode(), 1, int(identity))
        assert (event['entityType'], event['entityId'], event['action'], event['entityLabel']) == ('task', identity, 'created', title), event
`, path, workspace, title, fmt.Sprint(id))
			if out, err := check.CombinedOutput(); err != nil {
				t.Fatalf("recovered rows: %v\n%s", err, out)
			}
		})
	}
}

func TestTaskPersistenceAcrossRestart(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-task-persist-%d", time.Now().UnixNano())

	server := startServerInWorkDirWithEnv(t, serverWorkDir, map[string]string{"NRC_THREAD_COUNT": "5"})
	t.Cleanup(func() {
		server.stop(t)
		if t.Failed() {
			t.Logf("server logs:\n%s", server.logs.String())
		}
	})
	generation := filepath.Join(serverWorkDir, "data", "sharded-00000000000000000001")
	for shard := 0; shard < 256; shard++ {
		dir := filepath.Join(generation, fmt.Sprintf("shard_%03d", shard))
		if _, err := os.Stat(filepath.Join(dir, "workspace.sqlite3")); err != nil {
			t.Fatalf("missing SQLite shard: %v", err)
		}
		if _, err := os.Stat(filepath.Join(dir, "active.wal")); !os.IsNotExist(err) {
			t.Fatalf("unexpected legacy workspace WAL: %v", err)
		}
	}

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

	server = startServerInWorkDirWithEnv(t, serverWorkDir, map[string]string{"NRC_THREAD_COUNT": "3"})
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
