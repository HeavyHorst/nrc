package main

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/heavyhorst/nrc/protocol-go"
)

func ticketMetadata(asset protocol.Asset) SearchMetadata {
	metadata := SearchMetadata{ParentType: asset.ParentType, ParentID: asset.ParentID}
	if asset.AssetType == protocol.AssetTypeTicket {
		var preview struct {
			protocol.SearchTicketMetadata
			Version int `json:"version"`
		}
		if json.Unmarshal([]byte(asset.Preview), &preview) == nil && preview.Version == 1 && strings.TrimSpace(preview.Title) != "" {
			metadata.Ticket = &preview.SearchTicketMetadata
		}
	}
	return metadata
}

// Called under the index read lock. Build one candidate per eligible ticket,
// including its conversation's lexical evidence and independent vector chunks.
// Ranking and top-N therefore operate on tickets, never on individual replies.
func (idx *Index) ticketCandidates(workspace string, convID uint64, filters *protocol.SearchTicketFilters) []candidate {
	entries := idx.entries[workspace]
	tickets := map[uint64]*IndexEntry{}
	texts := map[uint64][]string{}
	for key := range idx.byConvID[workspace][convID] {
		entry := entries[key]
		m := entry.Metadata.Ticket
		if key.EntityType != EntityTypeAsset || entry.AssetType != protocol.AssetTypeTicket || m == nil ||
			(filters.Status != "" && m.Status != filters.Status) ||
			(filters.Assignee != "" && m.Assignee != filters.Assignee) ||
			(filters.CompanyID != "" && m.CompanyID != filters.CompanyID) {
			continue
		}
		copy := *entry
		copy.PreviewLower = strings.ToLower(strings.Join([]string{m.Title, m.Status, m.Assignee, m.CompanyID, m.ContactID, m.Requester, m.RequesterName}, "\n"))
		copy.Chunks = append([]IndexChunk(nil), entry.Chunks...)
		if len(copy.Chunks) == 0 {
			copy.Chunks = append(copy.Chunks, IndexChunk{Vector: entry.Vector})
		}
		texts[key.EntityID] = []string{entry.PayloadLower, "#" + strconv.FormatUint(key.EntityID, 10)}
		tickets[key.EntityID] = &copy
	}
	for key := range idx.byConvID[workspace][convID] {
		entry := entries[key]
		if key.EntityType != EntityTypeAsset || entry.AssetType != protocol.AssetTypeTicketEntry || entry.Metadata.ParentType != protocol.ParentTypeAsset {
			continue
		}
		parent := tickets[entry.Metadata.ParentID]
		if parent == nil {
			continue
		}
		texts[entry.Metadata.ParentID] = append(texts[entry.Metadata.ParentID], entry.PayloadLower)
		if len(entry.Chunks) > 0 {
			parent.Chunks = append(parent.Chunks, entry.Chunks...)
		} else {
			parent.Chunks = append(parent.Chunks, IndexChunk{Vector: entry.Vector})
		}
	}
	out := make([]candidate, 0, len(tickets))
	for id, entry := range tickets {
		entry.PayloadLower = strings.Join(texts[id], "\n")
		entry.Bloom = BigramBloom(entry.PayloadLower) | BigramBloom(entry.PreviewLower)
		out = append(out, candidate{identity: assetIdentity(workspace, id, convID), assetID: id, entry: entry})
	}
	return out
}
