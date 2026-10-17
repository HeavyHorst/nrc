package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Search supplies display rows, never delivery authority. Invitations and sends
// continue to resolve contacts and permissions against the live NRC source.
func (a *app) searchSubscribers(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Query  string `json:"query"`
		Offset int    `json:"offset"`
		Limit  int    `json:"limit"`
	}
	if !decode(w, r, &input) {
		return
	}
	if input.Limit == 0 {
		input.Limit = 25
	}
	if input.Offset < 0 || input.Limit < 1 || input.Limit > 250 || len(input.Query) > 1000 {
		fail(w, 400, "invalid search page")
		return
	}
	query := protocol.SearchRequest{Workspace: a.cfg.Workspace, Mode: "text", Query: input.Query, Offset: input.Offset, TopN: input.Limit,
		Filters: &protocol.SearchFilters{EntityTypes: []protocol.SearchEntityType{protocol.SearchEntityAsset}, AssetTypes: []uint16{protocol.AssetTypeCustomerContact}}}
	body, _ := json.Marshal(query)
	req, err := http.NewRequestWithContext(r.Context(), "POST", a.cfg.SearchURL, bytes.NewReader(body))
	if err != nil {
		fail(w, 503, "contact search unavailable")
		return
	}
	req.Header.Set("Content-Type", "application/json")
	client := http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := client.Do(req)
	if err != nil {
		fail(w, 503, "contact search unavailable")
		return
	}
	defer res.Body.Close()
	var page protocol.SearchResponse
	err = json.NewDecoder(io.LimitReader(res.Body, 8<<20)).Decode(&page)
	if err != nil || res.StatusCode != 200 || res.Header.Get(protocol.SearchAPIVersionHeader) != protocol.SearchAPIVersion || page.Mode != "text" || page.TotalCount < 0 || len(page.Results) > input.Limit || page.NextOffset != min(input.Offset, page.TotalCount)+len(page.Results) || page.NextOffset > page.TotalCount || page.HasMore != (page.NextOffset < page.TotalCount) || (page.HasMore && len(page.Results) == 0) {
		fail(w, 503, "invalid contact search response")
		return
	}
	rows := []map[string]any{}
	seen := map[uint64]bool{}
	a.s.mu.Lock()
	defer a.s.mu.Unlock()
	for _, hit := range page.Results {
		var preview struct {
			Version  int    `json:"version"`
			Title    string `json:"title"`
			Email    string `json:"email"`
			Archived bool   `json:"archived"`
		}
		if hit.Entity.Workspace != a.cfg.Workspace || hit.Entity.ConvID != 0 || hit.Entity.EntityType != protocol.SearchEntityAsset || hit.Entity.EntityID == 0 || seen[hit.Entity.EntityID] || hit.AssetType != protocol.AssetTypeCustomerContact || json.Unmarshal([]byte(hit.Preview), &preview) != nil || preview.Version != 1 || strings.TrimSpace(preview.Title) == "" || preview.Archived {
			fail(w, 503, "invalid contact search response")
			return
		}
		seen[hit.Entity.EntityID] = true
		email := normalize(preview.Email)
		row := map[string]any{"contact_id": strconv.FormatUint(hit.Entity.EntityID, 10), "name": preview.Title, "email": email, "companies": hit.Companies, "status": a.status(email)}
		if c := a.s.Consent[email]; c != nil {
			row["source"], row["confirmed_at"], row["import_proof"] = c.Source, c.ConfirmedAt, c.Imported
		}
		rows = append(rows, row)
	}
	reply(w, 200, map[string]any{"subscribers": rows, "total_count": page.TotalCount, "has_more": page.HasMore, "next_offset": page.NextOffset, "stale": page.Stale})
}
