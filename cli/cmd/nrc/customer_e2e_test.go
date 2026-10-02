package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Opt-in only: point at the disposable test/customer-workspace-dev.mjs proxy.
// NRC_CUSTOMER_CLI_TEST_URL=ws://127.0.0.1:8091 go test ./cmd/nrc -run TestCustomerCLIEndToEnd -v
func TestCustomerCLIEndToEnd(t *testing.T) {
	url := os.Getenv("NRC_CUSTOMER_CLI_TEST_URL")
	if url == "" {
		t.Skip("requires disposable customer fixture")
	}
	dir := t.TempDir()
	binary := filepath.Join(dir, "nrc")
	if data, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, data)
	}
	configDir := filepath.Join(dir, ".config", "nrc")
	if err := os.MkdirAll(configDir, 0700); err != nil {
		t.Fatal(err)
	}
	// Unique workspace keeps every invocation independent of other fixture tests.
	config := fmt.Sprintf("server: %q\nworkspace_id: cli-customer-%d\nroom_id: 2\n", strings.TrimRight(url, "/")+"/", time.Now().UnixNano())
	if err := os.WriteFile(filepath.Join(configDir, "config.yaml"), []byte(config), 0600); err != nil {
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
				t.Fatalf("%v unexpectedly succeeded: %s", args, data)
			}
			data = stderr.Bytes()
		}
		var result map[string]json.RawMessage
		if err := json.Unmarshal(data, &result); err != nil {
			t.Fatalf("%v invalid JSON: %s", args, data)
		}
		if ok && len(args) > 2 && args[0] == "customer" {
			if operation, exists := map[string]string{"create": "created", "update": "updated", "delete": "deleted", "archive": "archived", "restore": "restored"}[args[2]]; exists && string(result["operation"]) != strconv.Quote(operation) {
				t.Fatalf("incorrect mutation operation: %s", data)
			}
		}
		return result
	}
	id := func(result map[string]json.RawMessage) string {
		t.Helper()
		value := string(result["id"])
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			t.Fatalf("missing ID: %v", result)
		}
		return value
	}
	company := id(run(true, "customer", "company", "create", "--title", "First", "--city", "Berlin"))
	other := id(run(true, "customer", "company", "create", "--title", "Second"))
	contact := id(run(true, "customer", "contact", "create", "--company", company, "--title", "Alice", "--email", "rare@example.test"))
	activity := id(run(true, "customer", "activity", "create", "--company", company, "--title", "Decision", "--kind", "Decision", "--body", "Keep the existing API."))
	contact2 := id(run(true, "customer", "contact", "create", "--company", other, "--title", "Bob"))
	readEntries := func(result map[string]json.RawMessage) []customerRecord {
		t.Helper()
		var entries []customerRecord
		if err := json.Unmarshal(result["entries"], &entries); err != nil {
			t.Fatal(err)
		}
		return entries
	}
	page := run(true, "customer", "company", "list", "--page-size", "1")
	if len(readEntries(page)) != 1 || string(page["has_more"]) != "true" || string(page["total_count"]) != "2" {
		t.Fatalf("company page: %s", page)
	}
	var cursor string
	_ = json.Unmarshal(page["next_cursor"], &cursor)
	if next := run(true, "customer", "company", "list", "--page-size", "1", "--cursor", cursor); len(readEntries(next)) != 1 || string(next["has_more"]) != "false" {
		t.Fatalf("company cursor: %s", next)
	}
	if all := run(true, "customer", "company", "list", "--page-size", "1", "--all"); len(readEntries(all)) != 2 {
		t.Fatalf("company all: %s", all)
	}
	search := readEntries(run(true, "customer", "company", "list", "--search", "rare@example.test"))
	if len(search) != 1 || strconv.FormatUint(search[0].ID, 10) != company {
		t.Fatalf("contact search: %+v", search)
	}
	if all := readEntries(run(true, "customer", "contact", "list", "--all", "--page-size", "1")); len(all) != 2 {
		t.Fatalf("typed paging: %+v", all)
	}
	links := run(true, "customer", "links", company, "--page-size", "1")
	if string(links["has_more"]) != "true" || string(links["total_count"]) != "2" {
		t.Fatalf("edge paging: %s", links)
	}
	var edges []edgeEntry
	_ = json.Unmarshal(run(true, "customer", "links", company, "--all", "--page-size", "1")["edges"], &edges)
	if len(edges) != 2 {
		t.Fatalf("incident edges: %+v", edges)
	}
	if page := run(true, "customer", "links", company, "--after", string(links["next_edge_id"])); string(page["has_more"]) != "false" {
		t.Fatalf("edge cursor: %s", page)
	}
	// A metadata-only activity edit must not clear its durable record body.
	run(true, "customer", "activity", "update", activity, "--title", "Renamed")
	got := run(true, "customer", "activity", "get", activity)
	if string(got["body"]) != `"Keep the existing API."` {
		t.Fatalf("body lost: %s", got)
	}
	run(true, "customer", "company", "archive", company)
	if list := readEntries(run(true, "customer", "company", "list")); len(list) != 1 || strconv.FormatUint(list[0].ID, 10) != other {
		t.Fatalf("archive visibility: %+v", list)
	}
	if list := readEntries(run(true, "customer", "company", "list", "--archived")); len(list) != 2 {
		t.Fatal("archived record missing")
	}
	run(true, "customer", "company", "restore", company)
	// Reverse direction membership must work, and unlink must retain its endpoint.
	reverse := id(run(true, "edge", "create", "--source-type", "asset", "--source-id", company, "--target-type", "asset", "--target-id", contact2, "--relation", "member-of"))
	run(false, "customer", "unlink", other, reverse)
	run(true, "customer", "unlink", company, reverse)
	run(true, "customer", "contact", "get", contact2)
	link := id(run(true, "customer", "link", other, "asset", contact))
	run(true, "customer", "unlink", other, link)
	// Partial edit preserves extension metadata, including integers beyond float64.
	preview := `{"version":1,"title":"Extended","custom":18446744073709551615,"city":"Berlin"}`
	run(true, "asset", "update", company, preview, "private payload")
	run(true, "customer", "company", "update", company, "--city", "")
	got = run(true, "customer", "company", "get", company)
	var metadata map[string]json.RawMessage
	_ = json.Unmarshal(got["metadata"], &metadata)
	if string(metadata["custom"]) != "18446744073709551615" || string(metadata["city"]) != `""` || string(got["body"]) != `"private payload"` {
		t.Fatalf("partial edit lost data: %s", got)
	}
	projected := run(true, "customer", "company", "get", company, "--fields", "metadata,updated_at")
	if !bytes.Equal(projected["metadata"], got["metadata"]) || !bytes.Equal(projected["updated_at"], got["updated_at"]) {
		t.Fatalf("projection changed numeric values: %s", projected)
	}
	// Deterministic transaction boundary: another writer changes the fetched asset.
	t.Setenv("HOME", dir)
	s, err := conn.Dial("")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	companyID, _ := strconv.ParseUint(company, 10, 64)
	before, err := customerAsset(s, companyID, protocol.AssetTypeCustomerCompany)
	if err != nil {
		t.Fatal(err)
	}
	run(true, "customer", "company", "update", company, "--city", "Concurrent")
	patch, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{ConvID: 2, Asset: protocol.Existing(protocol.TransactionEntityAsset, companyID), IfUpdatedAt: before.UpdatedAt, Present: protocol.TransactionAssetPatchPreview, Preview: []byte(before.Preview)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := customerTransaction(s, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: patch}}); err == nil {
		t.Fatal("stale update committed")
	}
	got = run(true, "customer", "company", "get", company)
	_ = json.Unmarshal(got["metadata"], &metadata)
	if string(metadata["city"]) != `"Concurrent"` || string(got["body"]) != `"private payload"` {
		t.Fatalf("concurrent writer lost: %s", got)
	}
	// A company vanishing after validation must reject both create and link.
	doomed := id(run(true, "customer", "company", "create", "--title", "Temporary"))
	doomedID, _ := strconv.ParseUint(doomed, 10, 64)
	if _, err := customerAsset(s, doomedID, protocol.AssetTypeCustomerCompany); err != nil {
		t.Fatal(err)
	}
	run(true, "customer", "company", "delete", doomed)
	create, err := protocol.EncodeTransactionAssetCreate(protocol.TransactionAssetCreate{ConvID: 2, AssetType: protocol.AssetTypeCustomerContact, Preview: []byte(`{"version":1,"title":"Must not exist"}`)})
	if err != nil {
		t.Fatal(err)
	}
	edge, err := protocol.EncodeTransactionEdgeCreate(protocol.TransactionEdgeCreate{ConvID: 2, Source: protocol.CreatedBy(protocol.TransactionEntityAsset, 0), Target: protocol.Existing(protocol.TransactionEntityAsset, doomedID), Relation: protocol.RelationMemberOf})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := customerTransaction(s, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetCreate, Body: create}, {Type: protocol.TransactionOpEdgeCreate, Body: edge}}); err == nil {
		t.Fatal("missing company transaction committed")
	}
	if entries := readEntries(run(true, "customer", "contact", "list", "--all")); len(entries) != 2 {
		t.Fatalf("orphan contact: %+v", entries)
	}
	run(false, "customer", "contact", "update", company, "--title", "wrong type")
	run(false, "customer", "activity", "create", "--company", company, "--title", "Blank", "--body", " ")
	run(false, "customer", "company", "list", "--page-size", "251")
	run(false, "customer", "company", "create", "--title", "projected", "--fields", "id")
	run(true, "customer", "activity", "delete", activity)
	run(true, "customer", "contact", "delete", contact)
	run(true, "customer", "company", "delete", company)
	run(true, "customer", "company", "delete", other)
	run(true, "customer", "contact", "get", contact2) // Deleting a company does not delete shared contacts.
	t.Log("PASS customer CRUD, contact search, cursor/all paging, incident/reverse edges, archive/restore, partial edits and unlink retention")
}
