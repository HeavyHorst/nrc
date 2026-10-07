package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestCustomerSearchContract(t *testing.T) {
	for _, archived := range []bool{false, true} {
		calls := 0
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			var req protocol.SearchRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatal(err)
			}
			if req.Workspace != "ws" || req.ConvID != 0 || req.Query != "acme" || req.TopN != 12 || req.IncludePayload || req.Filters.Customer == nil || req.Filters.Customer.IncludeArchived != archived || len(req.Filters.AssetTypes) != 2 || req.Filters.AssetTypes[0] != 8 || req.Filters.AssetTypes[1] != 9 || len(req.Filters.EntityTypes) != 1 || req.Filters.EntityTypes[0] != protocol.SearchEntityAsset {
				t.Errorf("bad request: %+v", req)
			}
			w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
			json.NewEncoder(w).Encode(protocol.SearchResponse{Stale: true, Results: []protocol.SearchResult{customerFixture()}})
		}))
		cache := newADKAssetSourceCache(time.Minute, 10)
		traces := newToolTraceCollector()
		tool, err := newADKSearchCustomersTool(NewSearchClient(server.URL), cache)
		if err != nil {
			t.Fatal(err)
		}
		wrapped, err := wrapADKToolsForFantasy(tool)
		if err != nil || len(wrapped) != 1 {
			t.Fatalf("registry: %v", err)
		}
		ctx := context.WithValue(context.WithValue(context.WithValue(t.Context(), workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0)), toolTraceCollectorKey{}, traces)
		input, _ := json.Marshal(map[string]any{"query": " acme ", "limit": 99, "include_archived": archived})
		result, err := wrapped[0].Run(ctx, fantasy.ToolCall{ID: "customers", Input: string(input)})
		if err != nil || result.IsError {
			t.Fatal(err)
		}
		data := []byte(result.Content)
		if !strings.Contains(string(data), `"id":"9007199254740993"`) || !strings.Contains(string(data), `"values":["18446744073709551615","1.234567890123456789"]`) {
			t.Fatalf("numeric customer metadata lost precision: %s", data)
		}
		if !strings.Contains(string(data), `"asset_id":"18446744073709551615"`) || !strings.Contains(string(data), strings.Repeat("x", 500)) || !strings.Contains(string(data), `"stale":true`) || strings.Contains(string(data), `note_title`) {
			t.Fatalf("incomplete output: %s", data)
		}
		if result, err := wrapped[0].Run(ctx, fantasy.ToolCall{ID: "blank", Input: `{"query":"   "}`}); err != nil || !result.IsError || calls != 1 {
			t.Fatal("blank query reached backend")
		}
		entries := traces.snapshot()
		sources := sourcesFromAnswerRefs("[Asset:18446744073709551615]", nil, cache.get("ws", 0))
		if len(entries) != 2 || entries[0].Status != "ok" || entries[1].Status != "error" || entries[0].Outcome["limit"] != 12 || entries[0].Outcome["stale"] != true || len(sources) != 1 || sources[0].Title != "Acme" {
			t.Fatalf("missing trace/citation integration: %+v %+v", entries, sources)
		}
		server.Close()
	}
}

func customerFixture() protocol.SearchResult {
	return protocol.SearchResult{Entity: protocol.SearchEntityIdentity{Workspace: "ws", EntityType: protocol.SearchEntityAsset, EntityID: ^uint64(0), ConvID: 0}, Metadata: protocol.SearchMetadata{AssetType: 8, Customer: json.RawMessage(`{"version":1,"title":"Acme","custom":{"id":9007199254740993,"values":[18446744073709551615,1.234567890123456789]},"details":"` + strings.Repeat("x", 500) + `","archived":true}`)}, Preview: `{"version":1,"title":"Acme"}`}
}

func TestRawCustomerMetadataFailureIsPerRecord(t *testing.T) {
	contact := customerFixture()
	contact.Metadata.AssetType = protocol.AssetTypeCustomerContact
	contact.Metadata.Customer = json.RawMessage(`{"title":"Malformed contact"}`)
	contact.Preview = string(contact.Metadata.Customer)
	contact.Payload = "Still usable body"
	note := protocol.SearchResult{Entity: protocol.SearchEntityIdentity{Workspace: "ws", ConvID: 0, EntityType: protocol.SearchEntityAsset, EntityID: 7}, Metadata: protocol.SearchMetadata{AssetType: protocol.AssetTypeNote}, Preview: `{"title":"Useful note"}`}
	out, err := assetSearchOutput(protocol.SearchResponse{Results: []protocol.SearchResult{note, contact}}, "ws", 0, "query", 6, true, nil, false)
	if err != nil || len(out.Results) != 2 || out.Results[0].NoteTitle != "Useful note" || out.Results[1].Customer != nil || out.Results[1].MetadataWarning == "" || out.Results[1].Payload != contact.Payload || out.Results[1].Preview != contact.Preview {
		t.Fatalf("raw search lost evidence: %+v %v", out, err)
	}
	for _, kind := range []uint16{8, 9, 10} {
		asset := protocol.Asset{AssetID: ^uint64(0), AssetType: kind, CreatedAt: 123, UpdatedAt: 456, Preview: string(customerFixture().Metadata.Customer)}
		listed := adkAssetResultFromAsset(asset, false, 1000)
		if listed.CreatedAt != "123" || listed.UpdatedAt != "456" || listed.Customer["details"] != strings.Repeat("x", 500) || listed.NoteTitle != "" || listed.MetadataWarning != "" {
			t.Fatalf("listing clipped or misformatted customer: %+v", listed)
		}
		asset.Preview = contact.Preview
		listed = adkAssetResultFromAsset(asset, false, 1000)
		if listed.Customer != nil || listed.MetadataWarning == "" {
			t.Fatalf("listing hid malformed metadata: %+v", listed)
		}
	}
}

func TestCustomerSearchOutputValidation(t *testing.T) {
	for _, mutate := range []func(*protocol.SearchResult){
		func(r *protocol.SearchResult) { r.Entity.Workspace = "foreign" },
		func(r *protocol.SearchResult) { r.Entity.Workspace = "" },
		func(r *protocol.SearchResult) { r.Entity.ConvID = 2 },
		func(r *protocol.SearchResult) { r.Entity.EntityType = protocol.SearchEntityTask },
		func(r *protocol.SearchResult) { r.Entity.EntityID = 0 },
		func(r *protocol.SearchResult) { r.Metadata.AssetType = 9 },
		func(r *protocol.SearchResult) { r.Metadata.Customer = json.RawMessage(`[]`) },
		func(r *protocol.SearchResult) { r.Metadata.Customer = json.RawMessage(`{"title":"Acme"}`) },
		func(r *protocol.SearchResult) { r.Metadata.Customer = json.RawMessage(`{"version":1,"title":null}`) },
		func(r *protocol.SearchResult) { r.Metadata.Customer = json.RawMessage(`{"version":1,"title":" "}`) },
		func(r *protocol.SearchResult) { r.Metadata.Customer = nil },
		func(r *protocol.SearchResult) { r.AssetID = 42 },
	} {
		r := customerFixture()
		mutate(&r)
		if _, err := assetSearchOutput(protocol.SearchResponse{Results: []protocol.SearchResult{r}}, "ws", 0, "acme", 1, false, []uint16{8}, true); err == nil {
			t.Fatalf("accepted invalid result: %+v", r)
		}
	}
	r := customerFixture()
	out, err := assetSearchOutput(protocol.SearchResponse{Results: []protocol.SearchResult{r}}, "ws", 0, "acme", 1, false, []uint16{8, 9, 10}, false)
	if err != nil || out.Complete || !out.LimitReached || out.RankingHint == "" || out.Warning != "" {
		t.Fatalf("ranking semantics: %+v %v", out, err)
	}
	r.Metadata.Customer = nil
	r.Preview = `{"version":1,"title":"` + strings.Repeat("y", 500) + `"}`
	out, err = assetSearchOutput(protocol.SearchResponse{Results: []protocol.SearchResult{r}}, "ws", 0, "acme", 6, false, nil, false)
	if err != nil || len(out.Results[0].Customer["title"].(string)) < 500 || out.LimitReached {
		t.Fatalf("raw preview: %+v %v", out, err)
	}
	for _, name := range []string{"company", "companies", "CustomerCompany", "contacts", "CustomerContact", "activities", "CustomerActivity"} {
		if _, err := parseAssetTypeFilters([]string{name}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestCustomerToolScopeVersionAndDefault(t *testing.T) {
	for _, version := range []string{"", protocol.SearchAPIVersion} {
		calls := 0
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			var req protocol.SearchRequest
			_ = json.NewDecoder(r.Body).Decode(&req)
			if req.TopN != 6 || req.Filters.Customer.IncludeArchived {
				t.Errorf("bad defaults: %+v", req)
			}
			w.Header().Set(protocol.SearchAPIVersionHeader, version)
			_, _ = w.Write([]byte(`{"results":[]}`))
		}))
		listing, err := newADKSearchCustomersTool(NewSearchClient(server.URL), nil)
		if err != nil {
			t.Fatal(err)
		}
		for _, conv := range []uint64{0, 1} {
			ctx := newFantasyADKToolContext(context.WithValue(context.WithValue(t.Context(), workspaceContextKey{}, "ws"), convIDContextKey{}, conv), "customers")
			_, err := listing.(adkRunnableTool).Run(ctx, map[string]any{"query": "acme"})
			if (err != nil) != (version == "" || conv != 0) {
				t.Fatalf("version/scope error: %v", err)
			}
		}
		if calls != 1 {
			t.Fatalf("foreign scope reached HTTP: %d", calls)
		}
		server.Close()
	}
}
