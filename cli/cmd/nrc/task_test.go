package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

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
