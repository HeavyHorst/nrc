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

// Uses the disposable server from test/customer-workspace-dev.mjs.
func TestAtomicNoteContentPreviewEndToEnd(t *testing.T) {
	url := os.Getenv("NRC_CUSTOMER_CLI_TEST_URL")
	if url == "" {
		t.Skip("requires disposable customer fixture")
	}
	dir := t.TempDir()
	binary := filepath.Join(dir, "nrc")
	if b, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, b)
	}
	configDir := filepath.Join(dir, ".config", "nrc")
	if err := os.MkdirAll(configDir, 0700); err != nil {
		t.Fatal(err)
	}
	config := fmt.Sprintf("server: %q\nworkspace_id: cli-batch-%d\n", strings.TrimRight(url, "/")+"/", time.Now().UnixNano())
	if err := os.WriteFile(filepath.Join(configDir, "config.yaml"), []byte(config), 0600); err != nil {
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
			t.Fatalf("decode: %v %s", err, b)
		}
		return result
	}
	for _, format := range []string{"markdown", "html"} {
		t.Run(format, func(t *testing.T) {
			created := run("note", "create", "Stable title", "--content", "Old text", "--format", format, "--project", "test/project", "--tag", "search")
			id := string(created["id"])
			content := "New body"
			if format == "html" {
				content = "<p>New <b>body</b></p>"
			}
			for _, tc := range []struct{ op, content, explicit, want string }{
				{"note.update", content, "", "New body"},
				{"note.update", "", "", ""},
				{"note.update", "Custom body", `{"title":"Custom","teaser":"Intentional preview"}`, "Intentional preview"},
				{"asset.update", "Raw body", "", "Intentional preview"},
			} {
				before := run("note", "get", id, "--related=false")
				op := map[string]any{"op": tc.op, "id": json.RawMessage(id), "content": tc.content, "if_updated_at": before["updated_at"]}
				if tc.explicit != "" {
					op["preview"] = tc.explicit
				}
				b, err := json.Marshal(map[string]any{"operations": []any{op}})
				if err != nil {
					t.Fatal(err)
				}
				path := filepath.Join(dir, "batch.json")
				if err := os.WriteFile(path, b, 0600); err != nil {
					t.Fatal(err)
				}
				result := run("batch", "apply", "--atomic", "--input", path)
				if string(result["committed"]) != "true" {
					t.Fatalf("not committed: %s", result)
				}
				asset := run("asset", "get", id)
				var preview string
				if err := json.Unmarshal(asset["preview"], &preview); err != nil {
					t.Fatal(err)
				}
				var meta notePreview
				if err := json.Unmarshal([]byte(preview), &meta); err != nil || meta.Teaser != tc.want {
					t.Fatalf("preview = %s, want teaser %q: %v", preview, tc.want, err)
				}
				if tc.want != "Intentional preview" && (meta.Title != "Stable title" || meta.Project != "test/project" || meta.Format != format || strings.Join(meta.Tags, ",") != "search") {
					t.Fatalf("metadata lost: %s", preview)
				}
				after := run("note", "get", id, "--related=false")
				var got string
				if err := json.Unmarshal(after["content"], &got); err != nil || got != tc.content {
					t.Fatalf("content = %q, want %q: %v", got, tc.content, err)
				}
			}
		})
	}
}
