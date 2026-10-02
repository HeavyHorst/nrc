package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

func searchFilterTestCommand() *cobra.Command {
	cmd := &cobra.Command{}
	for _, name := range []string{"status", "assignee", "project", "priority", "color", "creator", "completer", "task-id", "external-ref", "blocked-by"} {
		cmd.Flags().StringSlice(name, nil, "")
	}
	cmd.Flags().String("blocked", "", "")
	cmd.Flags().Int64("overdue-before", 0, "")
	return cmd
}

func TestParseSearchFiltersTaskFacetsAndUnifiedEntities(t *testing.T) {
	cmd := searchFilterTestCommand()
	for name, value := range map[string]string{
		"status": "done,todo", "assignee": "Alice", "project": "NRC", "priority": "3", "color": "4", "task-id": "27", "external-ref": "NRC-27",
		"blocked": "true", "blocked-by": "99", "overdue-before": "1000",
	} {
		if err := cmd.Flags().Set(name, value); err != nil {
			t.Fatal(err)
		}
	}
	filters, used, err := parseSearchFilters(cmd, []string{"asset,task"}, []uint16{protocol.AssetTypeNote})
	if err != nil {
		t.Fatal(err)
	}
	if !used || len(filters.EntityTypes) != 2 || filters.Task == nil {
		t.Fatalf("typed filters = %#v, used=%v", filters, used)
	}
	if len(filters.Task.Statuses) != 2 || filters.Task.Statuses[0] != protocol.TaskStatusDone || filters.Task.TaskIDs[0] != 27 || filters.Task.ExternalRefs[0] != "NRC-27" ||
		filters.Task.Colors[0] != 4 || filters.Task.Blocked == nil || !*filters.Task.Blocked || filters.Task.BlockedBy[0] != 99 || *filters.Task.OverdueBefore != 1000 {
		t.Fatalf("task facets = %#v", filters.Task)
	}
}

func TestTaskFacetImpliesTaskEntityWhileNoFlagsRemainLegacy(t *testing.T) {
	legacy, used, err := parseSearchFilters(searchFilterTestCommand(), nil, []uint16{protocol.AssetTypeNote})
	if err != nil || used || legacy != nil {
		t.Fatalf("legacy filters = %#v, used=%v, err=%v", legacy, used, err)
	}
	cmd := searchFilterTestCommand()
	_ = cmd.Flags().Set("project", "nrc")
	filters, used, err := parseSearchFilters(cmd, nil, nil)
	if err != nil || !used || len(filters.EntityTypes) != 1 || filters.EntityTypes[0] != protocol.SearchEntityTask {
		t.Fatalf("implied task filters = %#v, used=%v, err=%v", filters, used, err)
	}
}

func TestLegacySearchJSONShapeDoesNotGainTypedFields(t *testing.T) {
	typed := &searchResponse{Results: []searchResult{{
		Entity:   protocol.SearchEntityIdentity{Workspace: "ws", EntityType: protocol.SearchEntityAsset, EntityID: 42, ConvID: 7},
		Metadata: protocol.SearchMetadata{AssetType: protocol.AssetTypeNote}, AssetID: 42, AssetType: protocol.AssetTypeNote,
		Score: 0.5, Preview: "note",
	}}}
	data, err := json.Marshal(asLegacySearchResponse(typed))
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	result := decoded["results"].([]any)[0].(map[string]any)
	if result["asset_id"] != "42" || result["asset_type"] != float64(protocol.AssetTypeNote) {
		t.Fatalf("legacy fields changed: %s", data)
	}
	if _, ok := result["entity"]; ok {
		t.Fatalf("legacy output gained entity: %s", data)
	}
	if _, ok := result["metadata"]; ok {
		t.Fatalf("legacy output gained metadata: %s", data)
	}
}

func TestLegacySearchJSONPreservesNullResults(t *testing.T) {
	data, err := json.Marshal(asLegacySearchResponse(&searchResponse{}))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"results":null}` {
		t.Fatalf("empty legacy response changed: %s", data)
	}
}

func TestLegacyNoteSearchProjectionExposesDecodedPreviewFields(t *testing.T) {
	response := &searchResponse{Results: []searchResult{{
		AssetID: 42, AssetType: protocol.AssetTypeNote, Score: 0.5,
		Preview: makeNotePreview("Projection contract", "Decoded teaser", "heavyhorst/nrc", []string{"cli", "notes"}, "markdown"),
	}}}
	if err := output.Configure(false, false, "id,title,project,tags,teaser"); err != nil {
		t.Fatal(err)
	}
	data, err := output.RenderJSON(asLegacySearchProjectionResponse(response), false)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	result := decoded["results"].([]any)[0].(map[string]any)
	if result["id"] != float64(42) || result["title"] != "Projection contract" || result["project"] != "heavyhorst/nrc" || result["teaser"] != "Decoded teaser" {
		t.Fatalf("decoded projection = %s", data)
	}
	tags := result["tags"].([]any)
	if len(tags) != 2 || tags[0] != "cli" || tags[1] != "notes" {
		t.Fatalf("decoded projection tags = %s", data)
	}
}

func TestLegacyNoteSearchProjectionValidatesEmptyResults(t *testing.T) {
	response := asLegacySearchProjectionResponse(&searchResponse{})
	if err := output.Configure(false, false, "title"); err != nil {
		t.Fatal(err)
	}
	data, err := output.RenderJSON(response, false)
	if err != nil {
		t.Fatalf("valid empty projection failed: %v", err)
	}
	if string(data) != `{"results":[]}` {
		t.Fatalf("empty projection = %s, want non-nil projected collection", data)
	}
	if err := output.Configure(false, false, "unknown"); err != nil {
		t.Fatal(err)
	}
	if _, err := output.RenderJSON(response, false); err == nil {
		t.Fatal("unknown field accepted for empty search results")
	}
}

func TestLegacyNoteSearchProjectionOmitsDecodedFieldsForNonNotes(t *testing.T) {
	response := &searchResponse{Results: []searchResult{{
		AssetID: 42, AssetType: protocol.AssetTypeDocument, Preview: "document preview",
	}}}
	if err := output.Configure(false, false, "asset_id,id,title"); err != nil {
		t.Fatal(err)
	}
	data, err := output.RenderJSON(asLegacySearchProjectionResponse(response), false)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	result := decoded["results"].([]any)[0].(map[string]any)
	if result["asset_id"] != "42" {
		t.Fatalf("legacy asset identity changed: %s", data)
	}
	if _, exists := result["id"]; exists {
		t.Fatalf("non-note result gained id alias: %s", data)
	}
	if _, exists := result["title"]; exists {
		t.Fatalf("non-note result gained decoded title: %s", data)
	}
}

func TestTypedTaskJSONKeepsEntityIdentitySeparateFromAssetIdentity(t *testing.T) {
	response := searchResponse{Results: []searchResult{{
		Entity:   protocol.SearchEntityIdentity{Workspace: "ws", EntityType: protocol.SearchEntityTask, EntityID: 27, ConvID: 7},
		Metadata: protocol.SearchMetadata{Task: &protocol.SearchTaskMetadata{Status: protocol.TaskStatusDone, ExternalRef: "NRC-27"}},
		Score:    1, Preview: "task",
	}}}
	data, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	_ = json.Unmarshal(data, &decoded)
	result := decoded["results"].([]any)[0].(map[string]any)
	if _, ok := result["asset_id"]; ok {
		t.Fatalf("task result conflated asset identity: %s", data)
	}
	entity := result["entity"].(map[string]any)
	if entity["type"] != "task" || entity["id"] != "27" {
		t.Fatalf("typed identity changed: %s", data)
	}
}

func TestSearchHTTPMachineOutputAndTypedCapability(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/search" || r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("unexpected request: %s %s content-type=%q", r.Method, r.URL.Path, r.Header.Get("Content-Type"))
		}
		var req searchRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		if req.Workspace != "smoke-workspace" || req.ConvID != 0 || req.TopN != 10 {
			t.Errorf("search context/defaults not serialized: %#v", req)
		}

		switch req.Query {
		case "task query":
			if req.Filters == nil || len(req.Filters.EntityTypes) != 1 || req.Filters.EntityTypes[0] != protocol.SearchEntityTask {
				t.Errorf("task filters not serialized: %#v", req.Filters)
			}
			w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
			_, _ = w.Write([]byte(`{"results":[{"entity":{"workspace":"smoke-workspace","type":"task","id":"27","conv_id":"0"},"metadata":{"task":{"status":3,"order_index":4,"priority":2,"color":1,"external_ref":"NRC-27"}},"score":0.75,"preview":"indexed task"}]}`))
		case "unified query":
			if req.Filters == nil || len(req.Filters.EntityTypes) != 2 {
				t.Errorf("unified filters not serialized: %#v", req.Filters)
			}
			w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
			_, _ = w.Write([]byte(`{"results":[{"entity":{"type":"asset","id":"42"},"metadata":{"asset_type":4},"asset_id":"42","score":1,"preview":"indexed asset","asset_type":4}]}`))
		case "legacy query":
			if req.Filters != nil {
				t.Errorf("legacy request gained typed filters: %#v", req.Filters)
			}
			_, _ = w.Write([]byte(`{"results":[{"entity":{"type":"asset","id":"42"},"metadata":{"asset_type":4},"asset_id":"42","score":1,"preview":"indexed asset","asset_type":4}]}`))
		case "unsupported":
			_, _ = w.Write([]byte(`{"results":[]}`))
		default:
			t.Errorf("unexpected query %q", req.Query)
		}
	}))
	defer server.Close()

	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{Server: "ws://unused", ProxyURL: server.URL, WorkspaceID: "smoke-workspace", RoomID: 17}).Save(); err != nil {
		t.Fatal(err)
	}
	if err := output.Configure(false, false, ""); err != nil {
		t.Fatal(err)
	}

	typed := func(query string, entities ...protocol.SearchEntityType) *searchResponse {
		t.Helper()
		resp, err := runSearch(searchRequest{Query: query, Filters: &protocol.SearchFilters{EntityTypes: entities}}, "")
		if err != nil {
			t.Fatalf("runSearch(%q): %v", query, err)
		}
		return resp
	}

	taskOutput := captureStdout(t, func() { outputSearchResults(typed("task query", protocol.SearchEntityTask), true, false, false) })
	if want := `{"results":[{"entity":{"workspace":"smoke-workspace","type":"task","id":"27","conv_id":"0"},"metadata":{"task":{"status":3,"order_index":4,"priority":2,"color":1,"external_ref":"NRC-27"}},"score":0.75,"preview":"indexed task"}]}` + "\n"; taskOutput != want {
		t.Fatalf("task machine output changed:\n got %s want %s", taskOutput, want)
	}

	unifiedOutput := captureStdout(t, func() {
		outputSearchResults(typed("unified query", protocol.SearchEntityAsset, protocol.SearchEntityTask), true, false, false)
	})
	if want := `{"results":[{"entity":{"type":"asset","id":"42","conv_id":"0"},"metadata":{"asset_type":4},"asset_id":"42","score":1,"preview":"indexed asset","asset_type":4}]}` + "\n"; unifiedOutput != want {
		t.Fatalf("unified machine output changed:\n got %s want %s", unifiedOutput, want)
	}

	legacyResp, err := runSearch(searchRequest{Query: "legacy query"}, "")
	if err != nil {
		t.Fatal(err)
	}
	legacyOutput := captureStdout(t, func() { outputSearchResults(legacyResp, true, false, true) })
	if legacyOutput != `{"results":[{"asset_id":"42","score":1,"preview":"indexed asset","asset_type":4}]}`+"\n" {
		t.Fatalf("legacy asset machine output changed: %s", legacyOutput)
	}

	_, err = runSearch(searchRequest{Query: "unsupported", Filters: &protocol.SearchFilters{EntityTypes: []protocol.SearchEntityType{protocol.SearchEntityTask}}}, "")
	if err == nil || !strings.Contains(err.Error(), "does not support typed entity search") {
		t.Fatalf("missing typed capability header returned %v", err)
	}
}
