package protocol

import (
	"encoding/json"
	"fmt"
	"strconv"
)

// SearchEntityType identifies an entity stored in nrc-search's typed index.
type SearchEntityType string

const (
	SearchEntityAsset      SearchEntityType = "asset"
	SearchEntityTask       SearchEntityType = "task"
	SearchAPIVersion                        = "typed-v1"
	SearchAPIVersionHeader                  = "X-NRC-Search-Version"
)

func (t SearchEntityType) Valid() bool {
	return t == SearchEntityAsset || t == SearchEntityTask
}

type SearchEntityIdentity struct {
	Workspace  string           `json:"workspace,omitempty"`
	EntityType SearchEntityType `json:"type"`
	EntityID   uint64           `json:"id,string"`
	ConvID     uint64           `json:"conv_id,string"`
}

type SearchTaskMetadata struct {
	Status      uint8  `json:"status"`
	OrderIndex  uint16 `json:"order_index"`
	Assignee    string `json:"assignee,omitempty"`
	Priority    uint8  `json:"priority"`
	Color       uint8  `json:"color"`
	CreatedBy   string `json:"created_by,omitempty"`
	CreatedAt   int64  `json:"created_at,omitempty"`
	UpdatedAt   int64  `json:"updated_at,omitempty"`
	ExternalRef string `json:"external_ref,omitempty"`
	DueAt       int64  `json:"due_at,omitempty"`
	BlockedBy   uint64 `json:"blocked_by,string,omitempty"`
	CompletedAt int64  `json:"completed_at,omitempty"`
	CompletedBy string `json:"completed_by,omitempty"`
	Project     string `json:"project,omitempty"`
}

type SearchMetadata struct {
	AssetType uint16              `json:"asset_type,omitempty"`
	Task      *SearchTaskMetadata `json:"task,omitempty"`
}

// SearchIDs encodes uint64 entity IDs as decimal JSON strings (and accepts
// either strings or numbers) so browser clients do not lose integer precision.
type SearchIDs []uint64

func (ids SearchIDs) MarshalJSON() ([]byte, error) {
	values := make([]string, len(ids))
	for i, id := range ids {
		values[i] = strconv.FormatUint(id, 10)
	}
	return json.Marshal(values)
}

func (ids *SearchIDs) UnmarshalJSON(data []byte) error {
	var values []json.RawMessage
	if err := json.Unmarshal(data, &values); err != nil {
		return err
	}
	parsed := make(SearchIDs, len(values))
	for i, raw := range values {
		var text string
		if len(raw) > 0 && raw[0] == '"' {
			if err := json.Unmarshal(raw, &text); err != nil {
				return err
			}
		} else {
			text = string(raw)
		}
		id, err := strconv.ParseUint(text, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid search entity ID %q: %w", text, err)
		}
		parsed[i] = id
	}
	*ids = parsed
	return nil
}

// SearchTaskFilters are exact, case-insensitive filters. Values within one
// field are ORed; different fields are ANDed before semantic ranking.
type SearchTaskFilters struct {
	Statuses      []uint8   `json:"statuses,omitempty"`
	Assignees     []string  `json:"assignees,omitempty"`
	Projects      []string  `json:"projects,omitempty"`
	Priorities    []uint8   `json:"priorities,omitempty"`
	Colors        []uint8   `json:"colors,omitempty"`
	CreatedBy     []string  `json:"created_by,omitempty"`
	CompletedBy   []string  `json:"completed_by,omitempty"`
	TaskIDs       SearchIDs `json:"task_ids,omitempty"`
	ExternalRefs  []string  `json:"external_refs,omitempty"`
	Blocked       *bool     `json:"blocked,omitempty"`
	BlockedBy     SearchIDs `json:"blocked_by,omitempty"`
	OverdueBefore *int64    `json:"overdue_before,omitempty"`
}

func (f SearchTaskFilters) Empty() bool {
	return len(f.Statuses) == 0 && len(f.Assignees) == 0 && len(f.Projects) == 0 &&
		len(f.Priorities) == 0 && len(f.Colors) == 0 && len(f.CreatedBy) == 0 && len(f.CompletedBy) == 0 &&
		len(f.TaskIDs) == 0 && len(f.ExternalRefs) == 0 && f.Blocked == nil && len(f.BlockedBy) == 0 && f.OverdueBefore == nil
}

type SearchFilters struct {
	EntityTypes []SearchEntityType `json:"entity_types,omitempty"`
	AssetTypes  []uint16           `json:"asset_types,omitempty"`
	Task        *SearchTaskFilters `json:"task,omitempty"`
}

// SearchRequest is the HTTP POST /search contract. AssetTypes and
// SimilarAssetID are retained for legacy asset-only clients.
type SearchRequest struct {
	Workspace      string                `json:"workspace"`
	Query          string                `json:"query,omitempty"`
	SimilarAssetID *uint64               `json:"similar_asset_id,string,omitempty"`
	SimilarEntity  *SearchEntityIdentity `json:"similar_entity,omitempty"`
	ConvID         uint64                `json:"conv_id,string"`
	TopN           int                   `json:"top_n"`
	AssetTypes     []uint16              `json:"asset_types,omitempty"`
	Filters        *SearchFilters        `json:"filters,omitempty"`
	IncludePayload bool                  `json:"include_payload"`
}

type SearchResult struct {
	Entity     SearchEntityIdentity `json:"entity"`
	Metadata   SearchMetadata       `json:"metadata"`
	AssetID    uint64               `json:"asset_id,string,omitempty"`
	Score      float64              `json:"score"`
	Similarity float32              `json:"similarity,omitempty"`
	Preview    string               `json:"preview"`
	AssetType  uint16               `json:"asset_type,omitempty"`
	Payload    string               `json:"payload,omitempty"`
}

type SearchResponse struct {
	Results []SearchResult `json:"results"`
	Stale   bool           `json:"stale,omitempty"`
}
