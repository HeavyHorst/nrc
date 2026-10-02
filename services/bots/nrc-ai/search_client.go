package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type SearchClient struct {
	baseURL string
	client  *http.Client
}

type SearchResult = protocol.SearchResult

func NewSearchClient(baseURL string) *SearchClient {
	return &SearchClient{
		baseURL: baseURL,
		client:  &http.Client{Timeout: 30 * time.Second},
	}
}

func (s *SearchClient) Search(ctx context.Context, workspace, query string, convID uint64, topN int, includePayload bool, assetTypes ...uint16) ([]SearchResult, error) {
	body := protocol.SearchRequest{
		Workspace:      workspace,
		Query:          query,
		ConvID:         convID,
		TopN:           topN,
		IncludePayload: includePayload,
		AssetTypes:     assetTypes,
	}

	return s.doSearch(ctx, body)
}

func (s *SearchClient) Similar(ctx context.Context, workspace string, seedAssetID uint64, convID uint64, topN int, includePayload bool, assetTypes ...uint16) ([]SearchResult, error) {
	body := protocol.SearchRequest{
		Workspace:      workspace,
		SimilarAssetID: &seedAssetID,
		ConvID:         convID,
		TopN:           topN,
		IncludePayload: includePayload,
		AssetTypes:     assetTypes,
	}

	return s.doSearch(ctx, body)
}

func (s *SearchClient) SearchTasks(ctx context.Context, workspace, query string, convID uint64, topN int, filters protocol.SearchTaskFilters) (protocol.SearchResponse, error) {
	body := protocol.SearchRequest{Workspace: workspace, Query: query, ConvID: convID, TopN: topN, IncludePayload: true,
		Filters: &protocol.SearchFilters{EntityTypes: []protocol.SearchEntityType{protocol.SearchEntityTask}}}
	if !filters.Empty() {
		body.Filters.Task = &filters
	}
	return s.doSearchResponse(ctx, body, true)
}

func (s *SearchClient) SearchEntities(ctx context.Context, request protocol.SearchRequest) (protocol.SearchResponse, error) {
	return s.doSearchResponse(ctx, request, true)
}

func (s *SearchClient) doSearch(ctx context.Context, body protocol.SearchRequest) ([]SearchResult, error) {
	response, err := s.doSearchResponse(ctx, body, false)
	return response.Results, err
}

func (s *SearchClient) doSearchResponse(ctx context.Context, body protocol.SearchRequest, requireTypedAPI bool) (protocol.SearchResponse, error) {
	if body.ConvID != protocol.WorkspaceDataConvID {
		return protocol.SearchResponse{}, errWorkspaceDataScope
	}

	data, err := json.Marshal(body)
	if err != nil {
		return protocol.SearchResponse{}, fmt.Errorf("marshal search request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", s.baseURL+"/search", bytes.NewReader(data))
	if err != nil {
		return protocol.SearchResponse{}, fmt.Errorf("create search request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.client.Do(req)
	if err != nil {
		return protocol.SearchResponse{}, fmt.Errorf("search request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return protocol.SearchResponse{}, fmt.Errorf("read search response: %w", err)
	}

	if resp.StatusCode != 200 {
		return protocol.SearchResponse{}, fmt.Errorf("search API error (status %d): %s", resp.StatusCode, string(respBody))
	}
	if requireTypedAPI && resp.Header.Get(protocol.SearchAPIVersionHeader) != protocol.SearchAPIVersion {
		return protocol.SearchResponse{}, fmt.Errorf("nrc-search does not advertise typed task search %q", protocol.SearchAPIVersion)
	}

	var result protocol.SearchResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return protocol.SearchResponse{}, fmt.Errorf("decode search response: %w", err)
	}

	return result, nil
}
