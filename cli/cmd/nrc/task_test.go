package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/client"
	"github.com/heavyhorst/nrc/cli/pkg/conn"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestFetchTasksBeyondFormerQuota(t *testing.T) {
	const total = 10037
	pageSize := int(protocol.MaxTaskPageSize)
	pageCount := (total + pageSize - 1) / pageSize
	pages := make([][]byte, 0, pageCount)
	requests := make([][]byte, 0, pageCount)
	var cursor *protocol.TaskPageCursor
	for offset := 0; offset < total; offset += pageSize {
		request, err := protocol.EncodeListTasksPaged(7, 0x1f, protocol.MaxTaskPageSize, cursor, 0)
		if err != nil {
			t.Fatal(err)
		}
		requests = append(requests, request)
		var tasks []*protocol.Task
		for i := offset; i < total && i < offset+pageSize; i++ {
			id := uint64(total - i)
			// Groups exercise both timestamp advancement and the ID tie-breaker.
			tasks = append(tasks, &protocol.Task{ID: id, ConvID: 7, Title: fmt.Sprintf("task-%d", id), UpdatedAt: int64(id / 1000)})
		}
		last := tasks[len(tasks)-1]
		next := protocol.TaskPageCursor{SortAt: last.UpdatedAt, TaskID: last.ID}
		pages = append(pages, testTaskListPage(tasks, offset+len(tasks) < total, next, total))
		cursor = &next
	}
	s, received := testTaskPageSession(t, pages)
	tasks, err := fetchTasks(s, 0x1f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != total {
		t.Fatalf("got %d tasks, want %d", len(tasks), total)
	}
	seen := make(map[uint64]bool, total)
	for i, task := range tasks {
		id := uint64(total - i)
		if seen[task.ID] || task.ID != id || task.Title != fmt.Sprintf("task-%d", id) || task.UpdatedAt != int64(id/1000) {
			t.Fatalf("task %d: duplicate or incorrect record: %#v", i, task)
		}
		seen[task.ID] = true
	}
	if len(received) != pageCount {
		t.Fatalf("got %d requests, want exactly %d", len(received), pageCount)
	}
	for i, want := range requests {
		got := <-received
		if got.Opcode != protocol.C_ListTasksPaged || !bytes.Equal(got.Data, want) {
			t.Fatalf("request %d: opcode %d data %x, want %x", i, got.Opcode, got.Data, want)
		}
	}
}

func TestFetchTasksRejectsNonDescendingCursor(t *testing.T) {
	a := protocol.TaskPageCursor{SortAt: 20, TaskID: 10}
	for _, tc := range []struct {
		name    string
		cursors []protocol.TaskPageCursor
	}{
		{"cycle", []protocol.TaskPageCursor{a, {SortAt: 20, TaskID: 9}, a}},
		{"equal", []protocol.TaskPageCursor{a, a}},
		{"backwards_timestamp", []protocol.TaskPageCursor{a, {SortAt: 21, TaskID: 1}}},
		{"backwards_id", []protocol.TaskPageCursor{a, {SortAt: 20, TaskID: 11}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var pages [][]byte
			for _, cursor := range tc.cursors {
				pages = append(pages, testTaskListPage([]*protocol.Task{{ID: cursor.TaskID, ConvID: 7, UpdatedAt: cursor.SortAt}}, true, cursor, 1))
			}
			s, received := testTaskPageSession(t, pages)
			tasks, err := fetchTasks(s, 0x1f)
			if err == nil || !strings.Contains(err.Error(), "cursor did not advance") || tasks != nil {
				t.Fatalf("tasks = %v, error = %v; want cursor rejection", tasks, err)
			}
			if len(received) != len(pages) {
				t.Fatalf("got %d requests, want %d before rejection", len(received), len(pages))
			}
		})
	}
}

func testTaskPageSession(t *testing.T, pages [][]byte) (*conn.Session, <-chan *protocol.Message) {
	t.Helper()
	requests := make(chan *protocol.Message, len(pages)+1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		for i := 0; ; i++ {
			_, wire, err := ws.ReadMessage()
			if err != nil {
				return
			}
			request, err := protocol.ReadMessage(wire)
			if err != nil {
				t.Error(err)
				return
			}
			requests <- request
			if i >= len(pages) {
				t.Error("unexpected extra task page request")
				return
			}
			wire, err = (&protocol.Message{Opcode: protocol.S_TaskListPage, Data: pages[i]}).Write()
			if err != nil {
				t.Error(err)
				return
			}
			if err := ws.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				t.Error(err)
				return
			}
		}
	}))
	t.Cleanup(server.Close)
	c := client.New("ws"+strings.TrimPrefix(server.URL, "http")+"/", "workspace")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return &conn.Session{Client: c, RoomID: 7}, requests
}

func testTaskListPage(tasks []*protocol.Task, hasMore bool, cursor protocol.TaskPageCursor, total uint32) []byte {
	buf := new(bytes.Buffer)
	write := func(value any) { _ = binary.Write(buf, binary.BigEndian, value) }
	str := func(value string) { write(uint16(len(value))); buf.WriteString(value) }
	write(uint64(7))
	write(uint8(1))
	write(uint16(len(tasks)))
	for _, task := range tasks {
		write(task.ID)
		write(task.ConvID)
		str(task.Title)
		str(task.Description)
		write(task.Status)
		write(task.OrderIndex)
		str(task.Assignee)
		write(task.Priority)
		write(task.Color)
		str(task.CreatedBy)
		write(task.CreatedAt)
		write(task.UpdatedAt)
		str(task.ExternalRef)
		write(task.DueAt)
		write(task.BlockedBy)
		write(task.CompletedAt)
		str(task.CompletedBy)
		str(task.Project)
		buf.Write(protocol.EncodeAttachments(task.Attachments))
	}
	var more uint8
	if hasMore {
		more = 1
	}
	write(more)
	write(cursor.SortAt)
	write(cursor.TaskID)
	write(total)
	str("")
	write(uint32(0))
	return buf.Bytes()
}

func TestFilterReadyTasks(t *testing.T) {
	tasks := []*protocol.Task{
		{ID: 1, Title: "ready-direct", Status: protocol.TaskStatusTodo},
		{ID: 2, Title: "native-blocked", Status: protocol.TaskStatusTodo, BlockedBy: 5},
		{ID: 3, Title: "native-unblocked-by-done", Status: protocol.TaskStatusTodo, BlockedBy: 6},
		{ID: 4, Title: "edge-blocked-by-depends-on", Status: protocol.TaskStatusTodo},
		{ID: 5, Title: "unfinished-blocker", Status: protocol.TaskStatusInProgress},
		{ID: 6, Title: "done-blocker", Status: protocol.TaskStatusDone},
		{ID: 7, Title: "edge-unblocked-by-done", Status: protocol.TaskStatusTodo},
		{ID: 8, Title: "done-edge-blocker", Status: protocol.TaskStatusDone},
		{ID: 9, Title: "edge-blocked-by-blocks", Status: protocol.TaskStatusTodo},
		{ID: 10, Title: "blocking-task", Status: protocol.TaskStatusTodo},
		{ID: 11, Title: "native-blocked-by-missing-task", Status: protocol.TaskStatusTodo, BlockedBy: 99},
	}

	edges := []protocol.Edge{
		{SourceType: protocol.TargetTypeTask, SourceID: 4, TargetType: protocol.TargetTypeTask, TargetID: 5, Relation: protocol.RelationDependsOn},
		{SourceType: protocol.TargetTypeTask, SourceID: 7, TargetType: protocol.TargetTypeTask, TargetID: 8, Relation: protocol.RelationDependsOn},
		{SourceType: protocol.TargetTypeTask, SourceID: 10, TargetType: protocol.TargetTypeTask, TargetID: 9, Relation: protocol.RelationBlocks},
		{SourceType: protocol.TargetTypeTask, SourceID: 1, TargetType: protocol.TargetTypeAsset, TargetID: 99, Relation: protocol.RelationDependsOn},
	}

	ready := filterReadyTasks(tasks, edges)
	readyIDs := make([]uint64, 0, len(ready))
	for _, task := range ready {
		readyIDs = append(readyIDs, task.ID)
	}

	want := []uint64{1, 3, 5, 6, 7, 8, 10}
	if !reflect.DeepEqual(readyIDs, want) {
		t.Fatalf("ready task IDs = %v, want %v", readyIDs, want)
	}

	blocked := filterBlockedTasks(tasks, edges)
	blockedIDs := make([]uint64, 0, len(blocked))
	for _, task := range blocked {
		blockedIDs = append(blockedIDs, task.ID)
	}

	blockedWant := []uint64{2, 4, 9, 11}
	if !reflect.DeepEqual(blockedIDs, blockedWant) {
		t.Fatalf("blocked task IDs = %v, want %v", blockedIDs, blockedWant)
	}
}

func TestToOutputTasksIncludesAttachmentURLs(t *testing.T) {
	tasks := []*protocol.Task{{
		ID: 7,
		Attachments: []protocol.Attachment{{
			FileId:     "att_one",
			Filename:   "report 1.pdf",
			Size:       42,
			MimeType:   "application/pdf",
			UploadedAt: 123,
		}},
	}}

	got := toOutputTasks(tasks, "https://files.example/")
	if len(got) != 1 || len(got[0].Attachments) != 1 {
		t.Fatalf("toOutputTasks attachments = %#v, want one", got)
	}
	attachment := got[0].Attachments[0]
	if attachment.FileID != "att_one" || attachment.URL != "https://files.example/files/att_one?filename=report+1.pdf" {
		t.Fatalf("attachment = %#v, want metadata and download URL", attachment)
	}
}

// Uses the disposable test/customer-workspace-dev.mjs fixture, never production.
func TestTaskAssigneeCLIEndToEnd(t *testing.T) {
	url := os.Getenv("NRC_CUSTOMER_CLI_TEST_URL")
	if url == "" {
		t.Skip("requires disposable fixture")
	}
	dir := t.TempDir()
	binary := filepath.Join(dir, "nrc")
	if b, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %s %v", b, err)
	}
	config := filepath.Join(dir, ".config", "nrc")
	if err := os.MkdirAll(config, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "config.yaml"), []byte(fmt.Sprintf("server: %q\nworkspace_id: cli-task-assignee-%d\n", strings.TrimRight(url, "/")+"/", time.Now().UnixNano())), 0600); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) map[string]json.RawMessage {
		t.Helper()
		cmd := exec.Command(binary, args...)
		cmd.Env = append(os.Environ(), "HOME="+dir)
		b, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%v: %v %s", args, err, b)
		}
		var result map[string]json.RawMessage
		if err := json.Unmarshal(b, &result); err != nil {
			t.Fatalf("%v: invalid JSON %s: %v", args, b, err)
		}
		return result
	}
	created := run("task", "create", "Assignee test")
	id := string(created["id"])
	if id == "" || id == "0" {
		t.Fatalf("missing task ID: %v", created)
	}
	run("task", "update", id, "--assignee", "florian.ostermaier")
	if got := string(run("task", "get", id)["assignee"]); got != `"florian.ostermaier"` {
		t.Fatalf("assigned = %s", got)
	}
	run("task", "update", id, "--title", "Retitled")
	if got := string(run("task", "get", id)["assignee"]); got != `"florian.ostermaier"` {
		t.Fatalf("unrelated update changed assignee: %s", got)
	}
	run("task", "update", id, "--assignee", "")
	if got := string(run("task", "get", id)["assignee"]); got != "" && got != `""` {
		t.Fatalf("cleared assignee = %s", got)
	}
}
