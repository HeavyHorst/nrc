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

func TestTicketSearchContract(t *testing.T) {
	for _, limit := range []int{0, 1, 99} {
		want := limit
		if want == 0 {
			want = 6
		}
		if want > 12 {
			want = 12
		}
		calls := 0
		fixture := protocol.SearchResult{Entity: protocol.SearchEntityIdentity{Workspace: "ws", EntityType: protocol.SearchEntityAsset, EntityID: ^uint64(0)}, Metadata: protocol.SearchMetadata{AssetType: 13, Ticket: &protocol.SearchTicketMetadata{Title: "Printer", Status: "open", CompanyID: "9007199254740993"}}, Preview: "Internal note evidence"}
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			var req protocol.SearchRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Error(err)
				return
			}
			if r.Method != "POST" || r.URL.Path != "/search" || req.Workspace != "ws" || req.ConvID != 0 || req.Query != "printer" || req.TopN != want || req.IncludePayload || req.Filters == nil {
				t.Errorf("bad request: %+v", req)
				return
			}
			f := req.Filters
			if len(f.EntityTypes) != 1 || f.EntityTypes[0] != protocol.SearchEntityAsset || len(f.AssetTypes) != 1 || f.AssetTypes[0] != 13 || f.Ticket == nil || *f.Ticket != (protocol.SearchTicketFilters{Status: "open", Assignee: "Alice", CompanyID: "9007199254740993"}) {
				t.Errorf("bad filters: %+v", f)
			}
			w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
			_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Stale: true, Results: []protocol.SearchResult{fixture}})
		}))
		cache := newADKAssetSourceCache(time.Minute, 10)
		traces := newToolTraceCollector()
		listing, err := newADKSearchTicketsTool(NewSearchClient(server.URL), cache)
		if err != nil {
			t.Fatal(err)
		}
		wrapped, err := wrapADKToolsForFantasy(listing)
		if err != nil {
			t.Fatal(err)
		}
		ctx := context.WithValue(context.WithValue(context.WithValue(t.Context(), workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0)), toolTraceCollectorKey{}, traces)
		input, _ := json.Marshal(map[string]any{"query": " printer ", "limit": limit, "status": "open", "assignee": "Alice", "company_id": "9007199254740993"})
		result, err := wrapped[0].Run(ctx, fantasy.ToolCall{ID: "tickets", Input: string(input)})
		if err != nil || result.IsError {
			t.Fatalf("%+v %v", result, err)
		}
		var out adkSearchAssetsOutput
		if err := json.Unmarshal([]byte(result.Content), &out); err != nil {
			t.Fatal(err)
		}
		if out.Count != 1 || !out.Stale || out.Warning == "" || out.Complete || out.LimitReached != (want == 1) || out.Results[0].AssetID != "18446744073709551615" || out.Results[0].Ticket.CompanyID != "9007199254740993" || !strings.Contains(out.RankingHint, "read_tickets") {
			t.Fatalf("bad output: %s", result.Content)
		}
		if result, err := wrapped[0].Run(ctx, fantasy.ToolCall{ID: "blank", Input: `{"query":" "}`}); err != nil || !result.IsError || calls != 1 {
			t.Fatal("blank query reached HTTP")
		}
		if result, err := wrapped[0].Run(context.WithValue(ctx, convIDContextKey{}, uint64(1)), fantasy.ToolCall{ID: "scope", Input: string(input)}); err != nil || !result.IsError || calls != 1 {
			t.Fatal("foreign scope reached HTTP")
		}
		if len(traces.snapshot()) != 3 || cache.get("ws", 0)[^uint64(0)] != "Printer" {
			t.Fatal("missing trace/source cache")
		}
		fixture.Metadata.AssetType = 14
		if result, err := wrapped[0].Run(ctx, fantasy.ToolCall{ID: "invalid", Input: string(input)}); err != nil || !result.IsError {
			t.Fatal("accepted entry instead of parent ticket")
		}
		fixture.Metadata.AssetType = 13
		fixture.Metadata.Ticket = nil
		if result, err := wrapped[0].Run(ctx, fantasy.ToolCall{ID: "metadata", Input: string(input)}); err != nil || !result.IsError {
			t.Fatal("accepted missing metadata")
		}
		server.Close()
	}
}
