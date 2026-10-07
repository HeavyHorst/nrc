package protocol

import (
	"encoding/json"
	"testing"
)

func TestSearchRequestLegacyAssetFields(t *testing.T) {
	seed := uint64(42)
	data, err := json.Marshal(SearchRequest{Workspace: "ws", SimilarAssetID: &seed, ConvID: 7, TopN: 10, AssetTypes: []uint16{5}})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["similar_asset_id"] != "42" || decoded["conv_id"] != "7" {
		t.Fatalf("legacy string IDs changed: %s", data)
	}
	if _, ok := decoded["filters"]; ok {
		t.Fatalf("empty typed filters should be omitted: %s", data)
	}
}

func TestSearchResponseTypedTaskRoundTrip(t *testing.T) {
	want := SearchResponse{Results: []SearchResult{{
		Entity:   SearchEntityIdentity{Workspace: "ws", EntityType: SearchEntityTask, EntityID: 27, ConvID: 7},
		Metadata: SearchMetadata{Task: &SearchTaskMetadata{Status: TaskStatusDone, ExternalRef: "NRC-27", Project: "nrc"}},
		Score:    1, Preview: "Unify Mixed-Case Search",
	}}}
	data, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	var got SearchResponse
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Results[0].Entity.EntityType != SearchEntityTask || got.Results[0].Entity.EntityID != 27 || got.Results[0].Metadata.Task.ExternalRef != "NRC-27" ||
		got.Results[0].Preview != "Unify Mixed-Case Search" {
		t.Fatalf("typed task response changed: %+v", got)
	}
}

func TestSearchIDsUsePrecisionSafeStringsAndAcceptLegacyNumbers(t *testing.T) {
	var filters SearchTaskFilters
	if err := json.Unmarshal([]byte(`{"task_ids":["18446744073709551615",27],"blocked_by":["9"]}`), &filters); err != nil {
		t.Fatal(err)
	}
	if filters.TaskIDs[0] != ^uint64(0) || filters.TaskIDs[1] != 27 || filters.BlockedBy[0] != 9 {
		t.Fatalf("decoded IDs = %#v / %#v", filters.TaskIDs, filters.BlockedBy)
	}
	data, err := json.Marshal(filters)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"task_ids":["18446744073709551615","27"],"blocked_by":["9"]}` {
		t.Fatalf("precision-safe IDs changed: %s", data)
	}
}

func TestSearchCustomerRegisterContract(t *testing.T) {
	var request SearchRequest
	if err := json.Unmarshal([]byte(`{"workspace":"ws","conv_id":"0","query":"contact","top_n":100,"include_payload":true,"filters":{"entity_types":["asset"],"asset_types":[8,9],"customer":{"include_archived":true}}}`), &request); err != nil {
		t.Fatal(err)
	}
	if request.Filters.Customer == nil || !request.Filters.Customer.IncludeArchived {
		t.Fatal("customer register filter missing")
	}
	preview := `{"version":1,"title":"Company","archived":true}`
	result := SearchResult{Entity: SearchEntityIdentity{EntityType: SearchEntityAsset, EntityID: ^uint64(0)}, Preview: preview, Metadata: SearchMetadata{AssetType: 8, Customer: json.RawMessage(preview)}}
	data, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded SearchResult
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Entity.EntityID != result.Entity.EntityID || string(decoded.Metadata.Customer) != decoded.Preview {
		t.Fatalf("customer projection contract changed: %s", data)
	}
}
