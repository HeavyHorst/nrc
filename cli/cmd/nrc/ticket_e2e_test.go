package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Uses the identity-bypassing staff fixture, never a customer portal account.
func TestTicketCLIEndToEnd(t *testing.T) {
	url := os.Getenv("NRC_CUSTOMER_CLI_TEST_URL")
	if url == "" {
		t.Skip("requires disposable staff proxy")
	}
	dir := t.TempDir()
	binary := filepath.Join(dir, "nrc")
	if b, e := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); e != nil {
		t.Fatalf("build: %v %s", e, b)
	}
	cfg := filepath.Join(dir, ".config", "nrc")
	if e := os.MkdirAll(cfg, 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(cfg, "config.yaml"), []byte(fmt.Sprintf("server: %q\nworkspace_id: cli-ticket-%d\n", strings.TrimRight(url, "/")+"/", time.Now().UnixNano())), 0600); e != nil {
		t.Fatal(e)
	}
	run := func(ok bool, args ...string) map[string]json.RawMessage {
		t.Helper()
		c := exec.Command(binary, args...)
		c.Env = append(os.Environ(), "HOME="+dir)
		b, e := c.CombinedOutput()
		if (e == nil) != ok {
			t.Fatalf("%v: %v %s", args, e, b)
		}
		var m map[string]json.RawMessage
		if e = json.Unmarshal(b, &m); e != nil {
			t.Fatalf("%v JSON: %s", args, b)
		}
		return m
	}
	id := func(m map[string]json.RawMessage) string {
		t.Helper()
		if len(m["id"]) == 0 {
			t.Fatalf("no id: %v", m)
		}
		return string(m["id"])
	}
	company := id(run(true, "customer", "create", "--title", "Company"))
	other := id(run(true, "customer", "create", "--title", "Other"))
	contact := id(run(true, "contact", "create", "--company", company, "--title", "Contact"))
	file := filepath.Join(dir, "source.txt")
	if e := os.WriteFile(file, []byte("ticket attachment evidence\n"), 0600); e != nil {
		t.Fatal(e)
	}
	ticket := id(run(true, "ticket", "create", "--title", "Original", "--requester", "user@example.test", "--body", "original immutable body", "--contact", contact, "--attach", file))
	read := run(true, "ticket", "get", ticket)
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(read["metadata"], &raw)
	if string(raw["company_id"]) != fmt.Sprintf("%q", company) {
		t.Fatalf("company not inferred: %s", read["metadata"])
	}
	run(false, "ticket", "update", ticket, "--company", other)
	run(false, "ticket", "update", ticket, "--expect-updated-at", "1", "--status", "resolved")
	run(false, "ticket", "update", ticket, "--body", "no")
	run(true, "ticket", "update", ticket, "--status", "in_progress", "--assignee", "staff")
	run(true, "edge", "create", "--source-type", "asset", "--source-id", other, "--target-type", "asset", "--target-id", contact, "--relation", "member-of")
	run(false, "ticket", "create", "--title", "Ambiguous", "--requester", "user@example.test", "--body", "body", "--contact", contact)
	// Explicit selection is accepted even with memberships in both directions.
	ambiguous := id(run(true, "ticket", "create", "--title", "Explicit", "--requester", "user@example.test", "--body", "body", "--contact", contact, "--company", other))
	run(true, "ticket", "delete", ambiguous)
	entry := id(run(true, "ticket", "reply", ticket, "--body", "internal by default", "--attach", file))
	run(true, "ticket", "reply", ticket, "--public", "--body", "explicitly public")
	run(true, "ticket", "internal-note", ticket, "--body", "last internal")
	read = run(true, "ticket", "get", ticket)
	if string(read["body"]) != `"original immutable body"` {
		t.Fatalf("original changed: %v", read)
	}
	var original []json.RawMessage
	if e := json.Unmarshal(read["attachments"], &original); e != nil || len(original) != 1 {
		t.Fatalf("original attachments not preserved: %s", read["attachments"])
	}
	var entries []ticketResource
	if e := json.Unmarshal(read["entries"], &entries); e != nil || len(entries) != 3 {
		t.Fatalf("entries: %v %s", e, read["entries"])
	}
	for i, kind := range []string{"internal_note", "public_reply", "internal_note"} {
		if ticketString(entries[i].Metadata, "kind") != kind {
			t.Fatalf("wrong entry kind: %+v", entries)
		}
		wantRecipient := ""
		if kind == "public_reply" {
			wantRecipient = "user@example.test"
		}
		if ticketString(entries[i].Metadata, "recipient") != wantRecipient {
			t.Fatalf("wrong recipient snapshot: %+v", entries[i])
		}
	}
	destination := filepath.Join(dir, "download.txt")
	run(true, "ticket", "download-attachment", ticket, "0", destination)
	b, e := os.ReadFile(destination)
	if e != nil || string(b) != "ticket attachment evidence\n" {
		t.Fatalf("original download: %v %s", e, b)
	}
	run(true, "ticket", "download-attachment", ticket, "0", destination, "--entry", entry)
	run(false, "ticket", "download-attachment", ticket, "0", destination, "--entry", ticket)
	for _, args := range [][]string{{"ticket", "attachments", ticket}, {"ticket", "attachments", ticket, "--entry", entry}} {
		c := exec.Command(binary, args...)
		c.Env = append(os.Environ(), "HOME="+dir)
		b, e := c.CombinedOutput()
		var attachments []json.RawMessage
		if e != nil || json.Unmarshal(b, &attachments) != nil || len(attachments) != 1 {
			t.Fatalf("attachment listing %v: %v %s", args, e, b)
		}
	}
	for _, args := range [][]string{{"ticket", "get", ticket, "--human"}, {"ticket", "list", "--human"}} {
		c := exec.Command(binary, args...)
		c.Env = append(os.Environ(), "HOME="+dir)
		b, e := c.CombinedOutput()
		if e != nil || !strings.Contains(string(b), "Original") {
			t.Fatalf("human output %v: %v %s", args, e, b)
		}
	}
	created := run(true, "ticket", "create-task", ticket, "--title", "Linked task")
	var details map[string]json.RawMessage
	_ = json.Unmarshal(created["details"], &details)
	var taskID uint64
	_ = json.Unmarshal(details["task_id"], &taskID)
	if taskID == 0 {
		t.Fatalf("task missing: %v", created)
	}
	task := fmt.Sprint(taskID)
	run(true, "ticket", "unlink", ticket, "--task", task)
	run(true, "ticket", "link", ticket, "--task", task)
	run(false, "ticket", "link", ticket, "--task", task)
	slice := id(run(true, "slice", "create", "Work"))
	run(true, "ticket", "link", ticket, "--slice", slice)
	run(false, "ticket", "link", ticket, "--slice", slice)
	checkSlice := func(count uint16) {
		t.Helper()
		got := run(true, "slice", "get", slice)
		var row sliceEntry
		b, _ := json.Marshal(got)
		if e := json.Unmarshal(b, &row); e != nil || row.Tickets != count || row.Members != uint32(count) || row.Tasks != 0 {
			t.Fatalf("slice get counters: %s (%v)", b, e)
		}
		listing := run(true, "slice", "list")
		var rows []sliceEntry
		if e := json.Unmarshal(listing["slices"], &rows); e != nil || len(rows) != 1 || rows[0].Tickets != count || rows[0].Members != uint32(count) {
			t.Fatalf("slice list counters: %s (%v)", listing["slices"], e)
		}
		result := run(true, "slice", "members", slice)
		var members []sliceMember
		if e := json.Unmarshal(result["members"], &members); e != nil || len(members) != int(count) {
			t.Fatalf("slice members: %s (%v)", result["members"], e)
		}
		if count != 0 && (members[0].Kind != "ticket" || members[0].Title != "Original" || members[0].Status != "in_progress" || members[0].Assignee != "staff") {
			t.Fatalf("ticket member details: %+v", members[0])
		}
	}
	checkSlice(1)
	links := run(true, "ticket", "links", ticket)
	var members []sliceMember
	_ = json.Unmarshal(links["members"], &members)
	if len(members) != 2 {
		t.Fatalf("links: %s", links["members"])
	}
	run(true, "ticket", "unlink", ticket, "--slice", slice)
	checkSlice(0)
	// Reverse memberships are also removable and refuse a second assignment.
	run(true, "edge", "create", "--source-type", "asset", "--source-id", slice, "--target-type", "asset", "--target-id", ticket, "--relation", "member-of")
	checkSlice(1)
	run(false, "ticket", "link", ticket, "--slice", slice)
	run(true, "ticket", "unlink", ticket, "--slice", slice)
	checkSlice(0)
	list := run(true, "ticket", "list", "--status", "in_progress", "--assignee", "staff", "--contact", contact, "--company", company, "--requester", "user@example.test", "--search", "original")
	var listed []ticketResource
	_ = json.Unmarshal(list["entries"], &listed)
	if len(listed) != 1 {
		t.Fatalf("filtered list: %v", list)
	}
	projected := run(true, "ticket", "list", "--fields", "id")
	if !strings.Contains(string(projected["entries"]), ticket) {
		t.Fatalf("projection: %v", projected)
	}
	run(true, "ticket", "delete", ticket)
	run(false, "ticket", "get", ticket)
	run(false, "asset", "get", entry)
	run(true, "task", "get", task)
	run(true, "slice", "get", slice)
	t.Log("verified ticket lifecycle, original preservation, conditional rejection, internal/public entries, upload/download, filters, projection, task and slice links")
}
