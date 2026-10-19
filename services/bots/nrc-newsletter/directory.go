package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type contactCursor struct {
	UpdatedAt int64  `json:"updated_at,string"`
	AssetID   uint64 `json:"asset_id,string"`
}

type contactPageSource interface {
	contactPage(context.Context, int, *contactCursor) (protocol.SearchResponse, *contactCursor, error)
}

func (s nrcSource) contactPage(ctx context.Context, limit int, cursor *contactCursor) (protocol.SearchResponse, *contactCursor, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var out protocol.SearchResponse
	var at contactCursor
	if cursor != nil {
		at = *cursor
	}
	c, close, err := s.connect(ctx)
	if err != nil {
		return out, nil, err
	}
	defer close()
	m, err := c.exchange(protocol.C_ListAssetsPaged, protocol.EncodeListActiveContactsPaged(0, uint16(limit), cursor != nil, at.UpdatedAt, at.AssetID, 1), protocol.S_AssetListPage)
	if err != nil {
		return out, nil, err
	}
	page, err := protocol.DecodeAssetListPage(m.Data)
	if err != nil {
		return out, nil, err
	}
	if page.ConvID != 0 || page.CorrelationID != 1 || page.FullContent || len(page.Assets) > limit || (page.HasMore && len(page.Assets) == 0) {
		return out, nil, errors.New("invalid contact page")
	}
	out.TotalCount, out.HasMore = int(page.TotalCount), page.HasMore
	for _, asset := range page.Assets {
		if asset.ConvID != 0 || asset.AssetType != protocol.AssetTypeCustomerContact || asset.AssetID == 0 ||
			(cursor != nil && (asset.UpdatedAt > at.UpdatedAt || asset.UpdatedAt == at.UpdatedAt && asset.AssetID >= at.AssetID)) {
			return out, nil, errors.New("invalid contact page order")
		}
		at = contactCursor{asset.UpdatedAt, asset.AssetID}
		cursor = &at
		out.Results = append(out.Results, protocol.SearchResult{Entity: protocol.SearchEntityIdentity{Workspace: s.workspace, EntityType: protocol.SearchEntityAsset, EntityID: asset.AssetID}, AssetType: asset.AssetType, Preview: asset.Preview})
	}
	if len(page.Assets) > 0 && (page.NextCursorUpdatedAt != at.UpdatedAt || page.NextCursorAssetID != at.AssetID) {
		return out, nil, errors.New("invalid contact page cursor")
	}
	if err := c.contactCompanies(out.Results); err != nil {
		return out, nil, err
	}
	if page.HasMore {
		return out, &at, nil
	}
	return out, nil, nil
}

// Resolve only this page's memberships, then batch all distinct related assets.
// Missing companies can disappear between reads; archived/non-company assets are omitted.
func (c sourceConnection) contactCompanies(rows []protocol.SearchResult) error {
	owners := map[uint64][]int{}
	ids := []uint64{}
	for i, row := range rows {
		id := row.Entity.EntityID
		seen := map[uint64]bool{}
		var after uint64
		for {
			m, err := c.exchange(protocol.C_ListEdgesPaged, protocol.EncodeListEdgesPaged(0, protocol.TargetTypeAsset, id, 250, after, 1), protocol.S_EdgeListPage)
			if err != nil {
				return err
			}
			page, err := protocol.DecodeEdgeListPage(m.Data)
			if err != nil {
				return err
			}
			if page.ConvID != 0 || page.TargetType != protocol.TargetTypeAsset || page.TargetID != id || page.CorrelationID != 1 {
				return errors.New("invalid contact membership page")
			}
			for _, edge := range page.Edges {
				if edge.ConvID != 0 {
					return errors.New("foreign contact membership")
				}
				if edge.Relation != protocol.RelationMemberOf || edge.SourceType != protocol.TargetTypeAsset || edge.TargetType != protocol.TargetTypeAsset {
					continue
				}
				other := edge.TargetID
				if edge.TargetID == id {
					other = edge.SourceID
				} else if edge.SourceID != id {
					return errors.New("foreign contact membership")
				}
				if seen[other] {
					continue
				}
				seen[other] = true
				if _, ok := owners[other]; !ok {
					ids = append(ids, other)
				}
				owners[other] = append(owners[other], i)
			}
			if !page.HasMore {
				break
			}
			if len(page.Edges) == 0 || page.NextEdgeID <= after {
				return errors.New("stalled membership cursor")
			}
			after = page.NextEdgeID
		}
	}
	for start := 0; start < len(ids); start += protocol.MaxIDBatchSize {
		batch := ids[start:min(start+protocol.MaxIDBatchSize, len(ids))]
		data, err := protocol.EncodeGetRecordsByIDs(batch, false, 1)
		if err != nil {
			return err
		}
		pending := map[uint64]bool{}
		for _, id := range batch {
			pending[id] = true
		}
		m, err := c.exchange(protocol.C_GetAssetsByIDs, data, protocol.S_AssetListPage)
		if err != nil {
			return err
		}
		total, received := -1, 0
		for {
			page, err := protocol.DecodeAssetListPage(m.Data)
			if err != nil {
				return err
			}
			if page.ConvID != 0 || page.CorrelationID != 1 || page.FullContent || (page.HasMore && len(page.Assets) == 0) {
				return errors.New("invalid company batch")
			}
			if total == -1 {
				total = int(page.TotalCount)
			}
			received += len(page.Assets)
			if int(page.TotalCount) != total || total > len(batch) || received > total || page.HasMore != (received < total) {
				return errors.New("incomplete or inconsistent company batch")
			}
			for _, asset := range page.Assets {
				if asset.ConvID != 0 || !pending[asset.AssetID] {
					return errors.New("foreign or repeated company")
				}
				delete(pending, asset.AssetID)
				if asset.AssetType != protocol.AssetTypeCustomerCompany {
					continue
				}
				var archive struct{ Archived bool }
				if json.Unmarshal([]byte(asset.Preview), &archive) != nil {
					return errors.New("invalid company metadata")
				}
				if archive.Archived {
					continue
				}
				var preview struct {
					Version int
					Title   string
				}
				if json.Unmarshal([]byte(asset.Preview), &preview) != nil || preview.Version != 1 || strings.TrimSpace(preview.Title) == "" {
					return errors.New("invalid company metadata")
				}
				company := protocol.SearchCompany{CustomerID: strconv.FormatUint(asset.AssetID, 10), Name: preview.Title}
				for _, i := range owners[asset.AssetID] {
					rows[i].Companies = append(rows[i].Companies, company)
				}
			}
			if !page.HasMore {
				break
			}
			m, err = c.read(protocol.S_AssetListPage)
			if err != nil {
				return err
			}
		}
	}
	for i := range rows {
		companies := rows[i].Companies
		sort.Slice(companies, func(i, j int) bool {
			if companies[i].Name == companies[j].Name {
				return companies[i].CustomerID < companies[j].CustomerID
			}
			return companies[i].Name < companies[j].Name
		})
	}
	return nil
}

// Listings and search supply display rows, never delivery authority. Invitations and sends
// continue to resolve contacts and permissions against the live NRC source.
func (a *app) searchSubscribers(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Query  string         `json:"query"`
		Offset int            `json:"offset"`
		Limit  int            `json:"limit"`
		Cursor *contactCursor `json:"cursor"`
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
	input.Query = strings.TrimSpace(input.Query)
	if input.Query == "" && input.Offset != 0 {
		fail(w, 400, "contact listing uses cursor, not offset")
		return
	}
	if input.Cursor != nil && (input.Cursor.AssetID == 0 || input.Query != "") {
		fail(w, 400, "invalid contact cursor")
		return
	}
	var page protocol.SearchResponse
	var nextCursor *contactCursor
	if input.Query == "" {
		src, ok := a.source.(contactPageSource)
		if !ok {
			fail(w, 503, "contact listing unavailable")
			return
		}
		var err error
		page, nextCursor, err = src.contactPage(r.Context(), input.Limit, input.Cursor)
		if err != nil {
			fail(w, 503, "contact listing unavailable")
			return
		}
	} else {
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
		err = json.NewDecoder(io.LimitReader(res.Body, 8<<20)).Decode(&page)
		if err != nil || res.StatusCode != 200 || res.Header.Get(protocol.SearchAPIVersionHeader) != protocol.SearchAPIVersion || page.Mode != "text" || page.TotalCount < 0 || len(page.Results) > input.Limit || page.NextOffset != min(input.Offset, page.TotalCount)+len(page.Results) || page.NextOffset > page.TotalCount || page.HasMore != (page.NextOffset < page.TotalCount) || (page.HasMore && len(page.Results) == 0) {
			fail(w, 503, "invalid contact search response")
			return
		}
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
		// Use the same exact field names as Odin's metadata parser. Go's struct
		// decoder otherwise lets unrelated keys such as TITLE override title.
		var fields map[string]json.RawMessage
		valid := json.Unmarshal([]byte(hit.Preview), &fields) == nil
		for key, target := range map[string]any{"version": &preview.Version, "title": &preview.Title, "email": &preview.Email, "archived": &preview.Archived} {
			if raw, exists := fields[key]; exists && json.Unmarshal(raw, target) != nil {
				valid = false
			}
		}
		if hit.Entity.Workspace != a.cfg.Workspace || hit.Entity.ConvID != 0 || hit.Entity.EntityType != protocol.SearchEntityAsset || hit.Entity.EntityID == 0 || seen[hit.Entity.EntityID] || hit.AssetType != protocol.AssetTypeCustomerContact || !valid || preview.Version != 1 || strings.TrimSpace(preview.Title) == "" || preview.Archived {
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
	reply(w, 200, map[string]any{"subscribers": rows, "total_count": page.TotalCount, "has_more": page.HasMore, "next_offset": page.NextOffset, "next_cursor": nextCursor, "stale": page.Stale})
}
