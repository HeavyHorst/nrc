package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestKnowledgeGapOffer(t *testing.T) {
	slices, err := parseKnowledgeGapSlices(`{"alpha":"9007199254740993","beta":"42"}`)
	if err != nil {
		t.Fatal(err)
	}
	collector := newToolTraceCollector()
	ctx := context.WithValue(t.Context(), toolTraceCollectorKey{}, collector)
	_, err = newKnowledgeGapTool().Run(ctx, fantasy.ToolCall{ID: "gap", Input: `{"missing_knowledge":"No documented recovery procedure"}`})
	if err != nil {
		t.Fatal(err)
	}
	trace := collector.snapshot()
	for _, tc := range []struct{ workspace, want string }{{"alpha", "9007199254740993"}, {"beta", "42"}, {"other", ""}} {
		if got := knowledgeGapSlice(slices, tc.workspace, trace); got != tc.want {
			t.Fatalf("workspace %s: got %q, want %q", tc.workspace, got, tc.want)
		}
	}
	if got := knowledgeGapSlice(slices, "alpha", nil); got != "" {
		t.Fatal("ordinary answer offered a gap task")
	}
	collector.add(ToolTraceEntry{Tool: "search_assets", Status: "error", Error: "permission denied"})
	if got := knowledgeGapSlice(slices, "alpha", collector.snapshot()); got != "" {
		t.Fatal("failed research offered a gap task")
	}
}

func TestKnowledgeGapRetrievalHealth(t *testing.T) {
	for _, scenario := range []string{"healthy-empty", "search-offline", "stale-index", "graph-unavailable"} {
		t.Run(scenario, func(t *testing.T) {
			var calls atomic.Int32
			search := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if scenario == "search-offline" {
					http.Error(w, "unavailable", http.StatusServiceUnavailable)
					return
				}
				w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
				response := protocol.SearchResponse{Results: []protocol.SearchResult{}, Stale: scenario == "stale-index"}
				if scenario == "graph-unavailable" {
					response.Results = append(response.Results, protocol.SearchResult{
						Entity:  protocol.SearchEntityIdentity{Workspace: "alpha", EntityType: protocol.SearchEntityAsset, EntityID: 9},
						Preview: "Known note", Payload: "Evidence", Metadata: protocol.SearchMetadata{AssetType: 5},
					})
				}
				json.NewEncoder(w).Encode(response)
			}))
			defer search.Close()
			collector := newToolTraceCollector()
			ctx := context.WithValue(t.Context(), toolTraceCollectorKey{}, collector)
			buildContext(ctx, &NRCClient{}, NewSearchClient(search.URL), askRequest{Workspace: "alpha", Question: "Recovery procedure?"}, 4096)
			if scenario == "search-offline" && calls.Load() < 2 {
				t.Fatal("did not exercise both typed search and fallback failure")
			}
			_, err := newKnowledgeGapTool().Run(ctx, fantasy.ToolCall{ID: "gap", Input: `{"missing_knowledge":"Recovery steps"}`})
			if err != nil {
				t.Fatal(err)
			}
			want := ""
			if scenario == "healthy-empty" {
				want = "51"
			}
			if got := knowledgeGapSlice(map[string]string{"alpha": "51"}, "alpha", collector.snapshot()); got != want {
				t.Fatalf("got slice %q, want %q", got, want)
			}
		})
	}
}

func TestKnowledgeGapConfiguration(t *testing.T) {
	for _, raw := range []string{"", "{}", "null"} {
		if _, err := parseKnowledgeGapSlices(raw); err != nil {
			t.Fatal(err)
		}
	}
	for _, raw := range []string{`{"a":42}`, `{"a":"0"}`, `{"a":"01"}`, `{"a":"18446744073709551616"}`, `{"a":"-1"}`, `{" ":"7"}`, `[]`, `broken`} {
		if _, err := parseKnowledgeGapSlices(raw); err == nil {
			t.Fatalf("accepted invalid configuration %s", raw)
		}
	}
}
