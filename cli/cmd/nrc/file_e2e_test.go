package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Real NRC writes, isolated HTTP upload fixture validating multipart bytes.
func TestFileCLIEndToEnd(t *testing.T) {
	url := os.Getenv("NRC_CUSTOMER_CLI_TEST_URL")
	if url == "" {
		t.Skip("requires disposable customer fixture")
	}
	var uploads atomic.Int32
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/upload" {
			http.NotFound(w, r)
			return
		}
		f, _, err := r.FormFile("file")
		if err != nil {
			t.Error(err)
			http.Error(w, "multipart", 400)
			return
		}
		defer f.Close()
		b, _ := io.ReadAll(f)
		if string(b) != "signed contract bytes" {
			t.Errorf("wrong upload: %q", b)
		}
		uploads.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{"fileId": "att_11111111111111111111111111111111", "filename": "contract.pdf", "mimeType": "application/pdf", "size": len(b), "uploadedAt": 1})
	}))
	defer proxy.Close()
	dir := t.TempDir()
	binary := filepath.Join(dir, "nrc")
	if b, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %s %v", b, err)
	}
	config := filepath.Join(dir, ".config", "nrc")
	if err := os.MkdirAll(config, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "config.yaml"), []byte(fmt.Sprintf("server: %q\nworkspace_id: cli-files-%d\nroom_id: 2\nproxy_url: %q\n", strings.TrimRight(url, "/")+"/", time.Now().UnixNano(), proxy.URL)), 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "contract.pdf")
	if err := os.WriteFile(path, []byte("signed contract bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	run := func(ok bool, args ...string) map[string]json.RawMessage {
		t.Helper()
		cmd := exec.Command(binary, args...)
		cmd.Env = append(os.Environ(), "HOME="+dir)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		data, err := cmd.Output()
		if ok && err != nil {
			t.Fatalf("%v: %v %s", args, err, stderr.String())
		}
		if !ok {
			if err == nil {
				t.Fatalf("unexpected success %v", args)
			}
			data = stderr.Bytes()
		}
		var result map[string]json.RawMessage
		if err := json.Unmarshal(data, &result); err != nil {
			t.Fatalf("invalid JSON: %s %s", data, stderr.String())
		}
		return result
	}
	a := run(true, "file", "upload", path, "--title", "Contract", "--category", "Legal", "--tag", "signed,customer")
	id := string(a["id"])
	if id == "" || id == "0" {
		t.Fatal(a)
	}
	if string(a["operation"]) != `"created"` || string(a["resource_type"]) != `"file"` {
		t.Fatal(a)
	}
	var resource map[string]json.RawMessage
	_ = json.Unmarshal(a["resource"], &resource)
	before := string(resource["attachments"])
	var attachments []struct {
		FileID string `json:"FileId"`
		URL    string `json:"url"`
	}
	if err := json.Unmarshal(resource["attachments"], &attachments); err != nil {
		t.Fatal(err)
	}
	if len(attachments) != 1 || attachments[0].FileID != "att_11111111111111111111111111111111" || attachments[0].URL != proxy.URL+"/files/att_11111111111111111111111111111111?filename=contract.pdf" {
		t.Fatalf("incorrect attachments: %s", before)
	}
	updated := run(true, "file", "update", id, "--description", "Verified", "--tag", "")
	if string(updated["operation"]) != `"updated"` || string(updated["resource_type"]) != `"file"` {
		t.Fatal(updated)
	}
	_ = json.Unmarshal(updated["resource"], &resource)
	if string(resource["attachments"]) != before {
		t.Fatal("metadata update changed attachment")
	}
	var metadata map[string]json.RawMessage
	_ = json.Unmarshal(resource["metadata"], &metadata)
	if string(metadata["description"]) != `"Verified"` || string(metadata["title"]) != `"Contract"` || string(metadata["tags"]) != "[]" {
		t.Fatal(metadata)
	}
	run(false, "file", "upload", path, "--title", " ")
	run(false, "file", "upload", path, "--fields", "id")
	if uploads.Load() != 1 {
		t.Fatal("invalid mutation uploaded binary")
	}
	run(true, "file", "upload", path, "--title", "Second")
	page := run(true, "file", "list", "--page-size", "1")
	if string(page["has_more"]) != "true" || string(page["total_count"]) != "2" {
		t.Fatal(page)
	}
	var cursor string
	_ = json.Unmarshal(page["next_cursor"], &cursor)
	next := run(true, "file", "list", "--page-size", "1", "--cursor", cursor)
	if string(next["has_more"]) != "false" {
		t.Fatal(next)
	}
	all := run(true, "file", "list", "--page-size", "1", "--all")
	var entries []json.RawMessage
	_ = json.Unmarshal(all["entries"], &entries)
	if len(entries) != 2 {
		t.Fatal(all)
	}
	company := run(true, "customer", "create", "--title", "Customer")
	run(true, "customer", "link", string(company["id"]), "asset", id)
	read := run(true, "file", "get", id)
	if string(read["attachments"]) != before {
		t.Fatal("readback changed attachment")
	}
}
