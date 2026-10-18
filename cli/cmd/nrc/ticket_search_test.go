package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestTicketSearchHTTPContract(t *testing.T) {
	var requests []p.SearchRequest
	result := p.SearchResult{Entity: p.SearchEntityIdentity{EntityType: p.SearchEntityAsset, EntityID: 42}, AssetID: 42, AssetType: 13,
		Metadata: p.SearchMetadata{Ticket: &p.SearchTicketMetadata{Title: "Invoice"}}, Score: 0.9, Preview: "Invoice", Payload: "Original body"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/search" || r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var req p.SearchRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Error(err)
		}
		requests = append(requests, req)
		w.Header().Set(p.SearchAPIVersionHeader, p.SearchAPIVersion)
		_ = json.NewEncoder(w).Encode(p.SearchResponse{Results: []p.SearchResult{result}})
	}))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{Server: "ws://unused", ProxyURL: server.URL, WorkspaceID: "staff-workspace", RoomID: 17}).Save(); err != nil {
		t.Fatal(err)
	}
	if err := output.Configure(false, false, ""); err != nil {
		t.Fatal(err)
	}
	for _, human := range []bool{false, true} {
		cmd := ticketSearchCommand()
		cmd.Flags().Bool("human", human, "")
		args := []string{"  invoice conversation  ", "--status", "open", "--assignee", "Alice", "--company", "0041", "--payload"}
		if human {
			args = append(args, "--top", "7")
		}
		cmd.SetArgs(args)
		got := captureStdout(t, func() {
			if err := cmd.Execute(); err != nil {
				t.Fatal(err)
			}
		})
		if !strings.Contains(got, "Original body") || !strings.Contains(got, "42") {
			t.Fatalf("missing search output: %s", got)
		}
		if !human && !json.Valid([]byte(got)) {
			t.Fatalf("invalid JSON output: %s", got)
		}
	}
	for i, req := range requests {
		top := 100
		if i == 1 {
			top = 7
		}
		want := p.SearchRequest{Workspace: "staff-workspace", Query: "invoice conversation", TopN: top, IncludePayload: true,
			Filters: &p.SearchFilters{EntityTypes: []p.SearchEntityType{p.SearchEntityAsset}, AssetTypes: []uint16{13},
				Ticket: &p.SearchTicketFilters{Status: "open", Assignee: "Alice", CompanyID: "0041"}}}
		if !reflect.DeepEqual(req, want) {
			t.Errorf("request = %#v, want %#v", req, want)
		}
	}
	for _, args := range [][]string{{" "}, {"query", "--top", "0"}, {"query", "--top", "101"}} {
		cmd := ticketSearchCommand()
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Errorf("accepted invalid arguments: %v", args)
		}
	}
	if len(requests) != 2 {
		t.Fatalf("expected only two valid HTTP requests, got %d", len(requests))
	}
	valid := result
	for _, change := range []func(){
		func() { result.Metadata.Ticket = nil },
		func() { result.AssetType = 14 },
		func() { result.Entity.ConvID = 7 },
		func() { result.Entity.Workspace = "another-workspace" },
	} {
		result = valid
		change()
		cmd := ticketSearchCommand()
		cmd.SetArgs([]string{"query"})
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "invalid parent-ticket") {
			t.Fatalf("invalid response accepted: %#v %v", result, err)
		}
	}
}
