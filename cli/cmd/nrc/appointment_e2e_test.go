package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Uses the real server behind test/customer-workspace-dev.mjs, never production.
func TestAppointmentCLIEndToEnd(t *testing.T) {
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
	if err := os.WriteFile(filepath.Join(config, "config.yaml"), []byte(fmt.Sprintf("server: %q\nworkspace_id: cli-appointments-%d\n", strings.TrimRight(url, "/")+"/", time.Now().UnixNano())), 0600); err != nil {
		t.Fatal(err)
	}
	run := func(ok bool, args ...string) []byte {
		t.Helper()
		cmd := exec.Command(binary, args...)
		cmd.Env = append(os.Environ(), "HOME="+dir)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		b, err := cmd.Output()
		if ok && err != nil {
			t.Fatalf("%v: %v %s", args, err, stderr.String())
		}
		if !ok {
			if err == nil {
				t.Fatalf("unexpected success: %v", args)
			}
			if len(b) != 0 {
				t.Fatalf("error polluted stdout: %s", b)
			}
			return stderr.Bytes()
		}
		return b
	}
	object := func(b []byte) map[string]json.RawMessage {
		t.Helper()
		var result map[string]json.RawMessage
		if err := json.Unmarshal(b, &result); err != nil {
			t.Fatalf("invalid JSON: %s %v", b, err)
		}
		return result
	}
	created := object(run(true, "appointment", "create", "CLI meeting", "--start", "2026-09-28T14:00:00+02:00", "--end", "2026-09-28T15:00:00+02:00", "--project", "NRC", "--assignee", "rene", "--description", "keep me"))
	id := string(created["id"])
	if id == "" || id == "0" {
		t.Fatal(created)
	}
	run(true, "appointment", "update", id, "--title", "Renamed", "--end", "")
	shown := object(run(true, "appointment", "show", id))
	if string(shown["description"]) != `"keep me"` || string(shown["project"]) != `"NRC"` || string(shown["start_at"]) != `"1790596800000000000"` || string(shown["title"]) != `"Renamed"` || shown["end_at"] != nil {
		t.Fatalf("patch: %s", shown)
	}
	run(false, "appointment", "update", id, "--end", "2026-09-28T10:00:00Z")
	args := []string{"appointment", "list", "--from", "2026-09-28T00:00:00Z", "--to", "2026-09-29T00:00:00Z", "--assignee", "rene", "--project", "NRC"}
	listed := object(run(true, append(args, "--fields", "id,title,start_at")...))
	var rows []map[string]json.RawMessage
	if err := json.Unmarshal(listed["appointments"], &rows); err != nil || len(rows) != 1 || len(rows[0]) != 3 || string(rows[0]["id"]) != id {
		t.Fatalf("projection: %s %v", listed, err)
	}
	human := string(run(true, append(args, "--human")...))
	if !strings.Contains(human, "Renamed") || !strings.Contains(human, "START") || strings.HasPrefix(human, "{") {
		t.Fatal(human)
	}
	note := object(run(true, "note", "create", "Not an appointment", "--content", "preserve"))
	run(false, "appointment", "delete", string(note["id"]))
	run(true, "note", "show", string(note["id"]))
	// Force > one server page; all appointments tie on start so the ID cursor matters.
	for i := 0; i < 101; i++ {
		run(true, "appointment", "create", fmt.Sprintf("Paged %03d", i), "--start", "2026-09-28T12:00:00Z", "--assignee", "rene", "--project", "NRC")
	}
	listed = object(run(true, args...))
	rows = nil
	if err := json.Unmarshal(listed["appointments"], &rows); err != nil || len(rows) != 102 {
		t.Fatalf("pagination length=%d err=%v", len(rows), err)
	}
	ids := map[string]bool{}
	for _, r := range rows {
		ids[string(r["id"])] = true
	}
	if len(ids) != 102 {
		t.Fatal("duplicate paged IDs")
	}
	run(true, "appointment", "delete", id)
	run(false, "appointment", "show", id)
	empty := object(run(true, "appointment", "list", "--from", "2026-10-01T00:00:00Z", "--to", "2026-10-02T00:00:00Z", "--fields", "id,title"))
	if string(empty["appointments"]) != "[]" {
		t.Fatal(empty)
	}
	// Exercise the Go transaction encoder and server's warmed calendar index.
	batch := func(operations []map[string]any) map[string]json.RawMessage {
		t.Helper()
		body, err := json.Marshal(map[string]any{"operations": operations})
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "batch.json")
		if err := os.WriteFile(path, body, 0600); err != nil {
			t.Fatal(err)
		}
		result := object(run(true, "batch", "apply", "--atomic", "--input", path))
		if string(result["committed"]) != "true" {
			t.Fatal(result)
		}
		return result
	}
	p := `{"version":1,"title":"Atomic appointment","start_at":"1790812800000000000","assignee":"rene"}`
	result := batch([]map[string]any{{"op": "asset.create", "ref": "meeting", "asset_type": 12, "preview": p, "content": ""}})
	var refs map[string]uint64
	if err := json.Unmarshal(result["refs"], &refs); err != nil || refs["meeting"] == 0 {
		t.Fatalf("refs: %s %v", result, err)
	}
	atomicID := refs["meeting"]
	shown = object(run(true, "appointment", "show", fmt.Sprint(atomicID)))
	if string(shown["title"]) != `"Atomic appointment"` {
		t.Fatal(shown)
	}
	listOctober := func() []map[string]json.RawMessage {
		t.Helper()
		result := object(run(true, "appointment", "list", "--from", "2026-10-01T00:00:00Z", "--to", "2026-10-02T00:00:00Z"))
		var items []map[string]json.RawMessage
		if err := json.Unmarshal(result["appointments"], &items); err != nil {
			t.Fatal(err)
		}
		return items
	}
	if len(listOctober()) != 1 {
		t.Fatal("atomic create missing in warmed index")
	}
	p = `{"version":1,"title":"Moved atomically","start_at":"1790899200000000000","assignee":"rene"}`
	batch([]map[string]any{{"op": "asset.update", "id": atomicID, "preview": p}})
	if len(listOctober()) != 0 {
		t.Fatal("atomic patch left stale calendar entry")
	}
	batch([]map[string]any{{"op": "asset.delete", "id": atomicID}})
	run(false, "appointment", "show", fmt.Sprint(atomicID))
}
