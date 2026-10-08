package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	"google.golang.org/adk/tool"
	"google.golang.org/adk/tool/functiontool"
)

type adkSearchCustomersInput struct {
	Query           string `json:"query"`
	Limit           uint8  `json:"limit,omitempty"`
	IncludeArchived bool   `json:"include_archived,omitempty"`
}

func newADKSearchCustomersTool(search *SearchClient, cache *adkAssetSourceCache) (tool.Tool, error) {
	return functiontool.New(functiontool.Config{Name: "search_customers", Description: "Read-only hybrid company-register search. Requires nonblank query; limit defaults to 6, maximum 12. Matching contacts contribute to company matches before ranking/top-N; returns companies only with full customer metadata and decimal-string asset_id. Archived companies excluded unless include_archived=true. Ranked evidence is never a complete inventory; inspect stale, warning and limit_reached."}, func(ctx tool.Context, input adkSearchCustomersInput) (out adkSearchAssetsOutput, err error) {
		started := time.Now()
		workspace, convID, err := adkSessionScope(ctx)
		defer func() {
			recordToolTrace(ctx, "search_customers", started, workspace, convID, map[string]any{"query": input.Query, "limit": input.Limit, "include_archived": input.IncludeArchived}, map[string]any{"result_count": out.Count, "stale": out.Stale, "limit": out.Limit, "limit_reached": out.LimitReached}, err)
		}()
		if err != nil {
			return adkSearchAssetsOutput{}, err
		}
		query := strings.TrimSpace(input.Query)
		if query == "" {
			return adkSearchAssetsOutput{}, fmt.Errorf("query is required")
		}
		limit := int(input.Limit)
		if limit == 0 {
			limit = 6
		}
		if limit > 12 {
			limit = 12
		}
		response, err := search.SearchEntities(ctx, protocol.SearchRequest{Workspace: workspace, ConvID: convID, Query: query, TopN: limit, Filters: &protocol.SearchFilters{EntityTypes: []protocol.SearchEntityType{protocol.SearchEntityAsset}, AssetTypes: []uint16{protocol.AssetTypeCustomerCompany, protocol.AssetTypeCustomerContact}, Customer: &protocol.SearchCustomerFilters{IncludeArchived: input.IncludeArchived}}})
		if err != nil {
			return adkSearchAssetsOutput{}, err
		}
		out, err = assetSearchOutput(response, workspace, convID, query, limit, false, []uint16{protocol.AssetTypeCustomerCompany}, true)
		if err == nil && cache != nil {
			cache.put(workspace, convID, assetTitlesFromSearchResults(response.Results))
		}
		return out, err
	})
}

func customerToolMetadata(raw string) (map[string]any, error) {
	var obj map[string]any
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&obj); err != nil || !json.Valid([]byte(raw)) {
		return nil, fmt.Errorf("invalid customer metadata")
	}
	if obj["version"] != json.Number("1") {
		return nil, fmt.Errorf("unsupported customer metadata version")
	}
	if title, ok := obj["title"].(string); !ok || strings.TrimSpace(title) == "" {
		return nil, fmt.Errorf("customer metadata requires title")
	}
	// ADK converts callback outputs through float64. Keep extensible metadata
	// numbers exact as decimal strings; the fixed schema version remains numeric.
	for key, value := range obj {
		if key != "version" {
			obj[key] = customerToolNumberStrings(value)
		}
	}
	return obj, nil
}

func customerToolNumberStrings(value any) any {
	switch v := value.(type) {
	case json.Number:
		return v.String()
	case map[string]any:
		for key, item := range v {
			v[key] = customerToolNumberStrings(item)
		}
	case []any:
		for i, item := range v {
			v[i] = customerToolNumberStrings(item)
		}
	}
	return value
}

func assetSearchOutput(response protocol.SearchResponse, workspace string, convID uint64, query string, limit int, includePayload bool, types []uint16, companiesOnly bool) (adkSearchAssetsOutput, error) {
	out := adkSearchAssetsOutput{Query: query, Count: len(response.Results), Results: make([]adkSearchAssetResult, 0, len(response.Results)), Stale: response.Stale, Complete: false, Limit: limit, LimitReached: len(response.Results) >= limit, RankingHint: "Ranked top-N evidence, not a complete inventory; limit_reached indicates possible additional matches, not a total count."}
	if response.Stale {
		out.Warning = "nrc-search reconciliation failed; indexed results may be stale"
	}
	for _, r := range response.Results {
		t := r.Metadata.AssetType
		if r.Entity.EntityType != protocol.SearchEntityAsset || r.Entity.EntityID == 0 || r.Entity.ConvID != convID || r.Entity.Workspace != workspace || t == 0 || (r.AssetType != 0 && r.AssetType != t) || (r.AssetID != 0 && r.AssetID != r.Entity.EntityID) {
			return adkSearchAssetsOutput{}, fmt.Errorf("nrc-search returned invalid or foreign asset result")
		}
		allowed := len(types) == 0
		for _, typ := range types {
			if typ == t {
				allowed = true
			}
		}
		if !allowed || (companiesOnly && t != protocol.AssetTypeCustomerCompany) {
			return adkSearchAssetsOutput{}, fmt.Errorf("nrc-search returned unexpected asset type")
		}
		item := adkSearchAssetResult{AssetID: strconv.FormatUint(r.Entity.EntityID, 10), AssetType: assetTypeName(t), Score: r.Score, Similarity: r.Similarity, Preview: trimForTool(strings.TrimSpace(r.Preview), 320)}
		if includePayload {
			item.Payload = trimForTool(strings.TrimSpace(r.Payload), adkSearchAssetPayloadMaxChars)
		}
		item.PayloadOmitted = !includePayload
		item.PayloadTruncated = includePayload && len(strings.TrimSpace(r.Payload)) > adkSearchAssetPayloadMaxChars
		if t >= protocol.AssetTypeCustomerCompany && t <= protocol.AssetTypeCustomerActivity {
			raw := r.Metadata.Customer
			if companiesOnly && len(raw) == 0 {
				return adkSearchAssetsOutput{}, fmt.Errorf("nrc-search returned incomplete company metadata")
			}
			if len(raw) == 0 {
				raw = json.RawMessage(r.Preview)
			}
			obj, err := customerToolMetadata(string(raw))
			if err != nil {
				if companiesOnly {
					return adkSearchAssetsOutput{}, err
				}
				item.MetadataWarning = err.Error()
			}
			item.Customer = obj
		} else {
			note := parseNotePreviewJSON(strings.TrimSpace(r.Preview))
			item.NoteTitle = note.Title
			item.NoteTeaser = note.Teaser
			item.Project = note.Project
			item.Tags = cloneStringSlice(note.Tags)
		}
		out.Results = append(out.Results, item)
	}
	return out, nil
}
