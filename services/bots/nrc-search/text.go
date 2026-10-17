package main

import (
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Text retrieval has no embedding dependency. Customer records come from the
// live durable inventory, even before their embedding jobs have completed.
// Identity order is stable; the HTTP layer pages after projection/deduplication.
func (idx *Index) SearchText(workspace, query string, convID uint64, filters SearchFilters) ([]SearchResult, error) {
	query = strings.ToLower(strings.TrimSpace(query))
	results := map[entityKey]SearchResult{}
	wantsAssets := len(filters.EntityTypes) == 0 || slices.Contains(filters.EntityTypes, EntityTypeAsset)
	wantsCustomer := wantsAssets && (filters.Customer != nil || len(filters.AssetTypes) == 0 || slices.Contains(filters.AssetTypes, uint16(protocol.AssetTypeCustomerCompany)) || slices.Contains(filters.AssetTypes, uint16(protocol.AssetTypeCustomerContact)))
	if wantsCustomer {
		idx.mu.RLock()
		storage := idx.storage
		idx.mu.RUnlock()
		if storage == nil {
			return nil, fmt.Errorf("customer inventory unavailable")
		}
		inventory, err := storage.customerInventory(workspace, convID, nil)
		if err != nil {
			return nil, err
		}
		assets := map[uint64]protocol.Asset{}
		for id, asset := range inventory.Assets {
			if asset.ConvID != convID || (asset.AssetType != protocol.AssetTypeCustomerCompany && asset.AssetType != protocol.AssetTypeCustomerContact) || customerPreview(asset.Preview) == nil {
				continue
			}
			var preview struct {
				Archived bool `json:"archived"`
			}
			_ = json.Unmarshal([]byte(asset.Preview), &preview)
			if preview.Archived && (filters.Customer == nil || !filters.Customer.IncludeArchived) {
				continue
			}
			assets[id] = asset
		}
		memberships := map[uint64]map[uint64]bool{}
		for _, edge := range inventory.Edges {
			if edge.ConvID != convID || edge.Relation != protocol.RelationMemberOf || edge.SourceType != protocol.TargetTypeAsset || edge.TargetType != protocol.TargetTypeAsset {
				continue
			}
			member, company := edge.SourceID, edge.TargetID
			if assets[member].AssetType == protocol.AssetTypeCustomerCompany {
				member, company = company, member
			}
			if assets[member].AssetType != protocol.AssetTypeCustomerContact || assets[company].AssetType != protocol.AssetTypeCustomerCompany {
				continue
			}
			if memberships[member] == nil {
				memberships[member] = map[uint64]bool{}
			}
			memberships[member][company] = true
		}
		resultFor := func(asset protocol.Asset) SearchResult {
			return SearchResult{Entity: assetIdentity(workspace, asset.AssetID, convID), AssetID: asset.AssetID, AssetType: asset.AssetType, Preview: asset.Preview, Payload: asset.Payload, Score: 1,
				Metadata: SearchMetadata{AssetType: asset.AssetType, Customer: customerPreview(asset.Preview)}}
		}
		for id, asset := range assets {
			if len(filters.AssetTypes) > 0 && !slices.Contains(filters.AssetTypes, asset.AssetType) {
				continue
			}
			text := customerText(asset.Preview, asset.Payload)
			companies := []protocol.SearchCompany{}
			companyIDs := make([]uint64, 0, len(memberships[id]))
			for companyID := range memberships[id] {
				companyIDs = append(companyIDs, companyID)
			}
			slices.Sort(companyIDs)
			for _, companyID := range companyIDs {
				var preview struct {
					Title string `json:"title"`
				}
				_ = json.Unmarshal([]byte(assets[companyID].Preview), &preview)
				companies = append(companies, protocol.SearchCompany{CustomerID: strconv.FormatUint(companyID, 10), Name: preview.Title})
				if filters.Customer == nil {
					text += "\n" + preview.Title
				}
			}
			if !strings.Contains(strings.ToLower(text), query) {
				continue
			}
			if filters.Customer != nil {
				if asset.AssetType == protocol.AssetTypeCustomerCompany {
					results[assetIdentity(workspace, id, convID).key()] = resultFor(asset)
				}
				for companyID := range memberships[id] {
					results[assetIdentity(workspace, companyID, convID).key()] = resultFor(assets[companyID])
				}
			} else {
				result := resultFor(asset)
				result.Companies = companies
				results[result.Entity.key()] = result
			}
		}
	}
	if filters.Customer == nil {
		for _, candidate := range idx.collectCandidates(workspace, convID, filters) {
			if candidate.identity.EntityType == EntityTypeAsset && (candidate.entry.AssetType == protocol.AssetTypeCustomerCompany || candidate.entry.AssetType == protocol.AssetTypeCustomerContact) {
				continue
			}
			if strings.Contains(candidate.entry.PayloadLower, query) || strings.Contains(candidate.entry.PreviewLower, query) {
				results[candidate.identity.key()] = SearchResult{Entity: candidate.identity, AssetID: candidate.assetID, AssetType: candidate.entry.AssetType, Preview: candidate.entry.Preview, Payload: candidate.entry.Payload, Metadata: candidate.entry.Metadata, Score: 1}
			}
		}
	}
	out := make([]SearchResult, 0, len(results))
	for _, result := range results {
		out = append(out, result)
	}
	sort.Slice(out, func(i, j int) bool { return identityLess(out[i].Entity, out[j].Entity) })
	return out, nil
}
