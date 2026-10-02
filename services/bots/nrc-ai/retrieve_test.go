package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type retrieveSearchStub struct {
	response protocol.SearchResponse
	err      error
	requests []protocol.SearchRequest
}

func (s *retrieveSearchStub) Search(_ context.Context, _, _ string, _ uint64, _ int, _ bool, _ ...uint16) ([]SearchResult, error) {
	return s.response.Results, s.err
}

func (s *retrieveSearchStub) SearchEntities(_ context.Context, request protocol.SearchRequest) (protocol.SearchResponse, error) {
	s.requests = append(s.requests, request)
	return s.response, s.err
}

type retrieveClientStub struct {
	subscribed      bool
	subscribeErr    error
	tasks           []protocol.Task
	graphResult     protocol.GraphRankResult
	graphErr        error
	assets          map[uint64]protocol.Asset
	graphCalls      int
	graphAnchors    []protocol.GraphRankEntity
	graphCandidates []protocol.GraphRankEntity
	subscribeCalls  int
}

func (c *retrieveClientStub) IsSubscribed(uint64) bool { return c.subscribed }
func (c *retrieveClientStub) SubscribeRoom(uint64) error {
	c.subscribeCalls++
	if c.subscribeErr != nil {
		return c.subscribeErr
	}
	c.subscribed = true
	return nil
}
func (c *retrieveClientStub) WaitForTasks(context.Context, uint64) error { return nil }
func (c *retrieveClientStub) GetTasks(uint64) []protocol.Task            { return c.tasks }
func (c *retrieveClientStub) GetGraphRank(_ context.Context, _ uint64, anchors, candidates []protocol.GraphRankEntity, _ uint8, _ uint16, _ uint8, _ uint8) (protocol.GraphRankResult, error) {
	c.graphCalls++
	c.graphAnchors = append([]protocol.GraphRankEntity(nil), anchors...)
	c.graphCandidates = append([]protocol.GraphRankEntity(nil), candidates...)
	return c.graphResult, c.graphErr
}
func (c *retrieveClientStub) GetAsset(_ context.Context, _ uint64, assetID uint64) (protocol.Asset, error) {
	asset, ok := c.assets[assetID]
	if !ok {
		return protocol.Asset{}, errors.New("missing asset fixture")
	}
	return asset, nil
}

func TestRetrieveRoomAlwaysExpandsAndHydratesGraphEvidence(t *testing.T) {
	search := &retrieveSearchStub{response: protocol.SearchResponse{Results: []protocol.SearchResult{{
		Entity:   protocol.SearchEntityIdentity{Workspace: "ws", EntityType: protocol.SearchEntityAsset, EntityID: 1, ConvID: protocol.WorkspaceDataConvID},
		Metadata: protocol.SearchMetadata{AssetType: 5}, Score: 0.9, Preview: "anchor", Payload: "anchor evidence",
	}}}}
	edge := protocol.Edge{EdgeID: 70, ConvID: protocol.WorkspaceDataConvID, SourceType: entityTypeAsset, SourceID: 1, TargetType: entityTypeAsset, TargetID: 3, Relation: 1, CreatedBy: "alice"}
	client := &retrieveClientStub{
		subscribed: true,
		graphResult: protocol.GraphRankResult{
			Entries: []protocol.GraphRankEntry{{Entity: protocol.GraphRankEntity{Type: entityTypeAsset, ID: 1}, Score: 1}, {Entity: protocol.GraphRankEntity{Type: entityTypeAsset, ID: 3}, Score: 0.5, Paths: []protocol.GraphRankPath{{AnchorIndex: 0, Depth: 1, EdgeIDs: []uint64{70}}}}},
			Edges:   []protocol.Edge{edge},
		},
		assets: map[uint64]protocol.Asset{3: {AssetID: 3, AssetType: 5, Preview: "linked", Payload: "hydrated linked evidence"}},
	}

	response, err := retrieveRoom(context.Background(), client, search, protocol.RetrieveRequest{
		Workspace: "ws", ConvID: protocol.WorkspaceDataConvID, Query: "ordinary wording", TopN: 10, Depth: 1,
		PayloadMode: protocol.RetrievePayloadAll, PathMode: protocol.RetrievePathsBest,
	})
	if err != nil {
		t.Fatal(err)
	}
	if client.graphCalls != 1 {
		t.Fatalf("generic query graph calls = %d, want 1", client.graphCalls)
	}
	if len(client.graphAnchors) != 1 || len(client.graphCandidates) != 1 || client.graphAnchors[0].ID != 1 || client.graphCandidates[0].ID != 1 {
		t.Fatalf("graph rank request did not preserve search inputs: anchors=%v candidates=%v", client.graphAnchors, client.graphCandidates)
	}
	if len(search.requests) == 0 || search.requests[0].Filters == nil || len(search.requests[0].Filters.EntityTypes) != 2 {
		t.Fatalf("retrieve did not issue unified typed search: %#v", search.requests)
	}
	if !response.GraphContributed || len(response.Results) != 2 || len(response.Results[1].Evidence) != 1 ||
		len(response.Edges) != 1 || response.Results[1].Evidence[0].EdgeIDs[0] != 70 {
		t.Fatalf("graph evidence missing: %#v", response)
	}
	var linked *protocol.RetrieveResult
	for i := range response.Results {
		if response.Results[i].ID == 3 {
			linked = &response.Results[i]
		}
	}
	if linked == nil || linked.Payload != "hydrated linked evidence" || linked.Title != "linked" || linked.Evidence[0].Depth != 1 {
		t.Fatalf("linked result was not hydrated: %#v", linked)
	}
}

func TestRetrieveRoomNoGraphProvidesSearchOnlyAblation(t *testing.T) {
	search := &retrieveSearchStub{response: protocol.SearchResponse{Results: []protocol.SearchResult{{
		Entity: protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityTask, EntityID: 2}, Preview: "task",
	}}}}
	client := &retrieveClientStub{subscribed: true}
	response, err := retrieveRoom(context.Background(), client, search, protocol.RetrieveRequest{
		Workspace: "ws", ConvID: protocol.WorkspaceDataConvID, Query: "task", NoGraph: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GraphEnabled || response.GraphContributed || client.graphCalls != 0 || len(response.Results[0].Evidence) != 0 {
		t.Fatalf("search-only ablation used graph: %#v calls=%d", response, client.graphCalls)
	}
	if client.subscribeCalls != 0 {
		t.Fatalf("successful typed search subscribed to room %d times, want 0", client.subscribeCalls)
	}
}

func TestRetrieveRoomReportsServerGraphRankFailure(t *testing.T) {
	search := &retrieveSearchStub{response: protocol.SearchResponse{Results: []protocol.SearchResult{
		{Entity: protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityAsset, EntityID: 1}, Preview: "first"},
		{Entity: protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityAsset, EntityID: 2}, Preview: "second"},
	}}}
	client := &retrieveClientStub{graphErr: errors.New("unavailable")}

	response, err := retrieveRoom(context.Background(), client, search, protocol.RetrieveRequest{
		Workspace: "ws", ConvID: protocol.WorkspaceDataConvID, Query: "task",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(response.Warnings) != 1 || response.Warnings[0] != "server graph ranking unavailable" || client.graphCalls != 1 {
		t.Fatalf("unexpected graph failure response: warnings=%v calls=%d", response.Warnings, client.graphCalls)
	}
}

func TestRetrieveRoomDegradesWhenFallbackSubscriptionFails(t *testing.T) {
	search := &retrieveSearchStub{err: errors.New("search unavailable")}
	client := &retrieveClientStub{subscribeErr: errors.New("not connected")}
	response, err := retrieveRoom(context.Background(), client, search, protocol.RetrieveRequest{
		Workspace: "ws", ConvID: protocol.WorkspaceDataConvID, Query: "task", NoGraph: true,
	})
	if err != nil {
		t.Fatalf("retrieve should degrade instead of failing: %v", err)
	}
	if client.subscribeCalls != 1 || len(response.Warnings) < 2 {
		t.Fatalf("missing degraded fallback warnings: calls=%d response=%#v", client.subscribeCalls, response)
	}
}

func TestRetrieveRoomMarksTopNCutAsTruncated(t *testing.T) {
	search := &retrieveSearchStub{response: protocol.SearchResponse{Results: []protocol.SearchResult{
		{Entity: protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityTask, EntityID: 1}, Preview: "first"},
		{Entity: protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityTask, EntityID: 2}, Preview: "second"},
	}}}
	response, err := retrieveRoom(context.Background(), &retrieveClientStub{}, search, protocol.RetrieveRequest{
		Workspace: "ws", ConvID: protocol.WorkspaceDataConvID, Query: "task", TopN: 1, NoGraph: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !response.Truncation.Results || len(response.Results) != 1 {
		t.Fatalf("top_n cut not reported: %#v", response)
	}
}

func TestRetrieveRoomDefaultsToStructuredTopThreePayloads(t *testing.T) {
	results := make([]protocol.SearchResult, 5)
	for i := range results {
		id := uint64(i + 1)
		results[i] = protocol.SearchResult{
			Entity:   protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityAsset, EntityID: id},
			Metadata: protocol.SearchMetadata{AssetType: 5},
			Preview:  `{"title":"Note ` + string(rune('A'+i)) + `","teaser":"Compact teaser","project":"heavyhorst/nrc","tags":["deployment"]}`,
			Payload:  strings.Repeat(string(rune('a'+i)), 100),
		}
		results[i].Preview = strings.ReplaceAll(results[i].Preview, `\"`, `"`)
	}
	response, err := retrieveRoom(context.Background(), &retrieveClientStub{}, &retrieveSearchStub{response: protocol.SearchResponse{Results: results}}, protocol.RetrieveRequest{
		Workspace: "ws", ConvID: protocol.WorkspaceDataConvID, Query: "deployment", TopN: 5, NoGraph: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(response.Results) != 5 || !response.Truncation.Payloads {
		t.Fatalf("default payload policy = %#v", response)
	}
	for i, result := range response.Results {
		if result.Title == "" || result.Project != "heavyhorst/nrc" || len(result.Tags) != 1 {
			t.Fatalf("result %d metadata = %#v", i, result)
		}
		if (i < 3) != (result.Payload != "") {
			t.Fatalf("result %d payload presence = %t", i, result.Payload != "")
		}
		wantPayloadState := protocol.RetrievePayloadStateComplete
		if i >= 3 {
			wantPayloadState = protocol.RetrievePayloadStateOmitted
		}
		if result.PayloadState != wantPayloadState {
			t.Fatalf("result %d payload state = %q, want %q", i, result.PayloadState, wantPayloadState)
		}
		if i >= 3 && result.Teaser != "Compact teaser" {
			t.Fatalf("result %d teaser = %q", i, result.Teaser)
		}
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), `"preview"`) || strings.Contains(string(encoded), `\"title\"`) {
		t.Fatalf("response retained encoded preview JSON: %s", encoded)
	}
}

func TestRetrievePayloadBudgetPreservesUTF8(t *testing.T) {
	results := []protocol.RetrieveResult{{Payload: "äöü"}, {Payload: "second"}}
	truncation := protocol.RetrieveTruncation{}
	applyRetrievePayloadPolicy(results, protocol.RetrieveRequest{
		PayloadMode: protocol.RetrievePayloadAll, MaxPayloadBytes: 5,
	}, &truncation)
	if results[0].Payload != "äö" || results[1].Payload != "" || !truncation.Payloads {
		t.Fatalf("budgeted payloads = %#v truncation=%#v", results, truncation)
	}
	if results[0].PayloadState != protocol.RetrievePayloadStateTruncated || results[1].PayloadState != protocol.RetrievePayloadStateTruncated {
		t.Fatalf("budgeted payload states = %q, %q", results[0].PayloadState, results[1].PayloadState)
	}
}

func TestSelectRetrievePathsDefaultsToDeterministicBest(t *testing.T) {
	paths := []protocol.RetrievePath{
		{Anchor: protocol.RetrieveEntityRef{Type: protocol.SearchEntityAsset, ID: 9}, Depth: 2, EdgeIDs: protocol.SearchIDs{3, 4}},
		{Anchor: protocol.RetrieveEntityRef{Type: protocol.SearchEntityAsset, ID: 2}, Depth: 1, EdgeIDs: protocol.SearchIDs{8}},
		{Anchor: protocol.RetrieveEntityRef{Type: protocol.SearchEntityAsset, ID: 1}, Depth: 1, EdgeIDs: protocol.SearchIDs{7}},
	}
	best := selectRetrievePaths(paths, protocol.RetrievePathsBest)
	if len(best) != 1 || best[0].Anchor.ID != 1 {
		t.Fatalf("best path = %#v", best)
	}
	if all := selectRetrievePaths(paths, protocol.RetrievePathsAll); len(all) != 3 {
		t.Fatalf("all paths = %#v", all)
	}
	if none := selectRetrievePaths(paths, protocol.RetrievePathsNone); len(none) != 0 {
		t.Fatalf("none paths = %#v", none)
	}
}
