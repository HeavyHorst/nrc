package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestSearchTasksUsesTypedIndexContractAndReturnsDoneTask(t *testing.T) {
	var request protocol.SearchRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Results: []protocol.SearchResult{{
			Entity:   protocol.SearchEntityIdentity{Workspace: "ws", EntityType: protocol.SearchEntityTask, EntityID: 27, ConvID: protocol.WorkspaceDataConvID},
			Metadata: protocol.SearchMetadata{Task: &protocol.SearchTaskMetadata{Status: protocol.TaskStatusDone, Priority: 3, Assignee: "alice", UpdatedAt: 99}},
			Score:    1.2, Preview: "Unify search", Payload: "Search every task",
		}}})
	}))
	defer server.Close()

	input := adkSearchTasksInput{Statuses: []string{"done"}, Assignees: []string{"alice"}, Projects: []string{"nrc"}, CreatedBy: []string{"bob"}, CompletedBy: []string{"alice"}, TaskIDs: []uint64{27}, ExternalRefs: []string{"NRC-27"}}
	out, err := searchTasksForTool(context.Background(), nil, NewSearchClient(server.URL), "ws", protocol.WorkspaceDataConvID, "#27", 5, input)
	if err != nil {
		t.Fatal(err)
	}
	if !out.Complete || out.Source != "nrc-search" || out.Count != 1 || out.Results[0].TaskID != 27 || out.Results[0].Status != "Done" {
		t.Fatalf("tool output = %#v", out)
	}
	if request.Filters == nil || len(request.Filters.EntityTypes) != 1 || request.Filters.EntityTypes[0] != protocol.SearchEntityTask || request.Filters.Task == nil {
		t.Fatalf("typed request = %#v", request)
	}
	if request.ConvID != 0 || request.TopN != 5 || request.Filters.Task.Statuses[0] != protocol.TaskStatusDone || request.Filters.Task.TaskIDs[0] != 27 || request.Filters.Task.ExternalRefs[0] != "NRC-27" {
		t.Fatalf("request filters/limit = %#v", request)
	}
	if request.Filters.Task.CreatedBy[0] != "bob" || request.Filters.Task.CompletedBy[0] != "alice" {
		t.Fatalf("creator/completer filters missing: %#v", request.Filters.Task)
	}
}

func TestSearchTasksUnavailableFallbackIsExplicitlyIncomplete(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
	}))
	defer server.Close()

	out, err := searchTasksForTool(context.Background(), nil, NewSearchClient(server.URL), "ws", protocol.WorkspaceDataConvID, "task", 8, adkSearchTasksInput{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Complete || out.Source != "loaded-task-cache" || out.Count != 0 {
		t.Fatalf("fallback output = %#v", out)
	}
	if !strings.Contains(out.Warning, "may omit unloaded or completed tasks") {
		t.Fatalf("fallback warning is not honest: %q", out.Warning)
	}
}

func TestSearchTasksStaleIndexIsNotMarkedComplete(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
		_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Stale: true, Results: []protocol.SearchResult{}})
	}))
	defer server.Close()
	out, err := searchTasksForTool(context.Background(), nil, NewSearchClient(server.URL), "ws", protocol.WorkspaceDataConvID, "task", 8, adkSearchTasksInput{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Complete || out.Source != "nrc-search" || !strings.Contains(out.Warning, "stale") {
		t.Fatalf("stale output = %#v", out)
	}
}

func TestFallbackTaskFacetsRemainExact(t *testing.T) {
	blocked := true
	cutoff := int64(100)
	tasks := []protocol.Task{
		{ID: 1, Project: "nrc", ExternalRef: "NRC-1", Priority: 2, Color: 4, CreatedBy: "bob", CompletedBy: "alice", BlockedBy: 9, DueAt: 80},
		{ID: 2, Project: "other", ExternalRef: "NRC-2", Priority: 2, Color: 4, BlockedBy: 9, DueAt: 80},
		{ID: 3, Project: "nrc", ExternalRef: "NRC-3", Priority: 1, Color: 3},
	}
	filtered := filterFallbackTasks(tasks, adkSearchTasksInput{Projects: []string{"NRC"}, Priorities: []uint8{2}, Colors: []uint8{4}, TaskIDs: []uint64{1},
		ExternalRefs: []string{"nrc-1"}, CreatedBy: []string{"BOB"}, CompletedBy: []string{"Alice"}, Blocked: &blocked, BlockedBy: []uint64{9}, OverdueBefore: &cutoff})
	if len(filtered) != 1 || filtered[0].ID != 1 {
		t.Fatalf("fallback exact filters = %#v", filtered)
	}
}

func TestSearchTasksDefaultStatusesExcludeLegacyNotes(t *testing.T) {
	var request protocol.SearchRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
		_ = json.NewDecoder(r.Body).Decode(&request)
		_ = json.NewEncoder(w).Encode(protocol.SearchResponse{})
	}))
	defer server.Close()
	_, _ = searchTasksForTool(context.Background(), nil, NewSearchClient(server.URL), "ws", protocol.WorkspaceDataConvID, "task", 8, adkSearchTasksInput{})
	if request.Filters == nil || request.Filters.Task == nil || len(request.Filters.Task.Statuses) != 4 {
		t.Fatalf("default task statuses = %#v", request.Filters)
	}
	for _, status := range request.Filters.Task.Statuses {
		if status == protocol.TaskStatusNote {
			t.Fatalf("legacy Note status included by default: %#v", request.Filters.Task.Statuses)
		}
	}
}

func TestSearchTasksRejectsUnknownStatusInsteadOfBroadening(t *testing.T) {
	_, err := searchTasksForTool(context.Background(), nil, nil, "ws", protocol.WorkspaceDataConvID, "task", 8, adkSearchTasksInput{Statuses: []string{"mystery"}})
	if err == nil || !strings.Contains(err.Error(), "unsupported task status") {
		t.Fatalf("unknown status error = %v", err)
	}
}

func TestSearchTasksMalformedTypedResponseFallsBackIncomplete(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
		_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Results: []protocol.SearchResult{{
			Entity: protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityAsset, EntityID: 9},
		}}})
	}))
	defer server.Close()
	out, err := searchTasksForTool(context.Background(), nil, NewSearchClient(server.URL), "ws", protocol.WorkspaceDataConvID, "task", 8, adkSearchTasksInput{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Complete || out.Source != "loaded-task-cache" {
		t.Fatalf("malformed response was trusted: %#v", out)
	}
}

func TestSearchTasksOldServiceWithoutTypedCapabilityFallsBackIncomplete(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(protocol.SearchResponse{})
	}))
	defer server.Close()
	out, err := searchTasksForTool(context.Background(), nil, NewSearchClient(server.URL), "ws", protocol.WorkspaceDataConvID, "task", 8, adkSearchTasksInput{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Complete || out.Source != "loaded-task-cache" {
		t.Fatalf("old service response was trusted: %#v", out)
	}
}
