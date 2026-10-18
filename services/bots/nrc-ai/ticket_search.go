package main

import (
	"fmt"
	"strings"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	"google.golang.org/adk/tool"
	"google.golang.org/adk/tool/functiontool"
)

type adkSearchTicketsInput struct {
	Query     string `json:"query"`
	Limit     uint8  `json:"limit,omitempty"`
	Status    string `json:"status,omitempty"`
	Assignee  string `json:"assignee,omitempty"`
	CompanyID string `json:"company_id,omitempty"`
}

func newADKSearchTicketsTool(search *SearchClient, cache *adkAssetSourceCache) (tool.Tool, error) {
	return functiontool.New(functiontool.Config{Name: "search_tickets", Description: "Read-only INTERNAL STAFF-ONLY ticket conversation search, including internal notes; never expose internal notes to customers. Requires nonblank query; limit defaults to 6, maximum 12. status, assignee and company_id are exact filters. The service combines original requests, customer/public replies and internal notes into one parent Ticket hit before ranking/limit. Approximate ranked evidence, not an inventory: heed stale, warning and limit_reached. Use read_tickets for the authoritative full conversation before writes. No approval required for this read."}, func(ctx tool.Context, input adkSearchTicketsInput) (out adkSearchAssetsOutput, err error) {
		started := time.Now()
		workspace, convID, err := adkSessionScope(ctx)
		defer func() {
			recordToolTrace(ctx, "search_tickets", started, workspace, convID, map[string]any{"query": input.Query, "limit": input.Limit, "status": input.Status, "assignee": input.Assignee, "company_id": input.CompanyID}, map[string]any{"result_count": out.Count, "stale": out.Stale, "limit": out.Limit, "limit_reached": out.LimitReached}, err)
		}()
		if err != nil {
			return out, err
		}
		query := strings.TrimSpace(input.Query)
		if query == "" {
			return out, fmt.Errorf("query is required")
		}
		limit := int(input.Limit)
		if limit == 0 {
			limit = 6
		}
		if limit > 12 {
			limit = 12
		}
		response, err := search.SearchEntities(ctx, protocol.SearchRequest{Workspace: workspace, ConvID: convID, Query: query, TopN: limit, Filters: &protocol.SearchFilters{EntityTypes: []protocol.SearchEntityType{protocol.SearchEntityAsset}, AssetTypes: []uint16{13}, Ticket: &protocol.SearchTicketFilters{Status: input.Status, Assignee: input.Assignee, CompanyID: input.CompanyID}}})
		if err != nil {
			return out, err
		}
		out, err = assetSearchOutput(response, workspace, convID, query, limit, false, []uint16{13}, false)
		if err != nil {
			return adkSearchAssetsOutput{}, err
		}
		titles := make(map[uint64]string, len(response.Results))
		for i, r := range response.Results {
			if r.Metadata.Ticket == nil || strings.TrimSpace(r.Metadata.Ticket.Title) == "" {
				return adkSearchAssetsOutput{}, fmt.Errorf("nrc-search returned incomplete ticket metadata")
			}
			out.Results[i].Ticket = r.Metadata.Ticket
			out.Results[i].NoteTitle = ""
			out.Results[i].NoteTeaser = ""
			out.Results[i].Project = ""
			out.Results[i].Tags = nil
			titles[r.Entity.EntityID] = r.Metadata.Ticket.Title
		}
		out.RankingHint = "Internal staff-only approximate ranked conversation evidence, not a complete inventory. limit_reached indicates possible additional matches. Index may be stale; use read_tickets for authoritative conversation before writes. Never expose internal notes to customers."
		if cache != nil {
			cache.put(workspace, convID, titles)
		}
		return out, nil
	})
}
