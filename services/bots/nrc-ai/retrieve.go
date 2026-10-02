package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const (
	retrieveDefaultTopN            = 10
	retrieveMaxTopN                = 50
	retrieveMaxAnchors             = 5
	retrieveMaxHydrate             = retrieveMaxTopN
	retrieveDefaultPayloadTop      = 3
	retrieveDefaultMaxPayloadBytes = 30_000
	retrieveMaxPayloadBytes        = 1 << 20
)

type retrievalSearch interface {
	Search(context.Context, string, string, uint64, int, bool, ...uint16) ([]SearchResult, error)
	SearchEntities(context.Context, protocol.SearchRequest) (protocol.SearchResponse, error)
}

type retrievalClient interface {
	IsSubscribed(uint64) bool
	SubscribeRoom(uint64) error
	WaitForTasks(context.Context, uint64) error
	GetTasks(uint64) []protocol.Task
	GetGraphRank(context.Context, uint64, []protocol.GraphRankEntity, []protocol.GraphRankEntity, uint8, uint16, uint8, uint8) (protocol.GraphRankResult, error)
	GetAsset(context.Context, uint64, uint64) (protocol.Asset, error)
}

type retrieveEntityKey struct {
	entityType protocol.SearchEntityType
	id         uint64
}

type retrieveCandidate struct {
	result     protocol.RetrieveResult
	entity     protocol.SearchEntityIdentity
	preview    string
	searchRank int
	pageRank   float64
	paths      []protocol.RetrievePath
}

func handleRetrieve(wm *WorkspaceManager, search *SearchClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var request protocol.RetrieveRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
			writeRetrieveError(w, http.StatusBadRequest, fmt.Sprintf("invalid request: %v", err))
			return
		}
		if strings.TrimSpace(request.Workspace) == "" || request.ConvID != protocol.WorkspaceDataConvID || strings.TrimSpace(request.Query) == "" {
			writeRetrieveError(w, http.StatusBadRequest, "workspace and query are required; conv_id must be 0 (workspace scope)")
			return
		}

		client, err := wm.GetOrCreateClient(strings.TrimSpace(request.Workspace))
		if err != nil {
			writeRetrieveError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		response, err := retrieveRoom(r.Context(), client, search, request)
		if err != nil {
			writeRetrieveError(w, http.StatusBadRequest, err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response)
	}
}

func writeRetrieveError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}

func retrieveRoom(ctx context.Context, client retrievalClient, search retrievalSearch, request protocol.RetrieveRequest) (protocol.RetrieveResponse, error) {
	request.Workspace = strings.TrimSpace(request.Workspace)
	request.Query = strings.TrimSpace(request.Query)
	if request.Workspace == "" {
		return protocol.RetrieveResponse{}, fmt.Errorf("workspace is required")
	}
	if request.ConvID != protocol.WorkspaceDataConvID {
		return protocol.RetrieveResponse{}, errWorkspaceDataScope
	}
	if request.Query == "" {
		return protocol.RetrieveResponse{}, fmt.Errorf("query is required")
	}
	if request.TopN <= 0 {
		request.TopN = retrieveDefaultTopN
	}
	if request.TopN > retrieveMaxTopN {
		request.TopN = retrieveMaxTopN
	}
	if request.Depth == 0 {
		request.Depth = 1
	}
	if request.Depth > 4 {
		return protocol.RetrieveResponse{}, fmt.Errorf("depth must be between 1 and 4")
	}
	if request.PayloadMode == "" {
		request.PayloadMode = protocol.RetrievePayloadTop
	}
	if request.PayloadMode != protocol.RetrievePayloadNone && request.PayloadMode != protocol.RetrievePayloadTop && request.PayloadMode != protocol.RetrievePayloadAll {
		return protocol.RetrieveResponse{}, fmt.Errorf("payload must be none, top, or all")
	}
	if request.PayloadTop <= 0 {
		request.PayloadTop = retrieveDefaultPayloadTop
	}
	if request.MaxPayloadBytes <= 0 {
		request.MaxPayloadBytes = retrieveDefaultMaxPayloadBytes
	}
	if request.MaxPayloadBytes > retrieveMaxPayloadBytes {
		return protocol.RetrieveResponse{}, fmt.Errorf("max_payload_bytes must not exceed %d", retrieveMaxPayloadBytes)
	}
	if request.PathMode == "" {
		request.PathMode = protocol.RetrievePathsBest
	}
	if request.PathMode != protocol.RetrievePathsNone && request.PathMode != protocol.RetrievePathsBest && request.PathMode != protocol.RetrievePathsAll {
		return protocol.RetrieveResponse{}, fmt.Errorf("paths must be none, best, or all")
	}
	relationMask, err := parseRelationMask(request.Relations)
	if err != nil {
		return protocol.RetrieveResponse{}, err
	}
	direction, err := parseRetrieveDirection(request.Direction)
	if err != nil {
		return protocol.RetrieveResponse{}, err
	}

	response := protocol.RetrieveResponse{
		Workspace:    request.Workspace,
		ConvID:       request.ConvID,
		Query:        request.Query,
		GraphEnabled: !request.NoGraph,
		Results:      []protocol.RetrieveResult{},
		Edges:        []protocol.RetrieveEdge{},
	}

	searchLimit := max(request.TopN, retrieveMaxAnchors)
	searchResponse, searchErr := search.SearchEntities(ctx, protocol.SearchRequest{
		Workspace:      request.Workspace,
		Query:          request.Query,
		ConvID:         request.ConvID,
		TopN:           searchLimit,
		IncludePayload: true,
		Filters: &protocol.SearchFilters{EntityTypes: []protocol.SearchEntityType{
			protocol.SearchEntityAsset,
			protocol.SearchEntityTask,
		}},
	})
	if searchErr != nil {
		response.Stale = true
		response.Warnings = append(response.Warnings, "typed search unavailable; using asset search and loaded-task fallback")
		if !client.IsSubscribed(request.ConvID) {
			if err := client.SubscribeRoom(request.ConvID); err != nil {
				response.Warnings = append(response.Warnings, "room subscription unavailable; loaded-task fallback may be incomplete")
			} else {
				waitCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
				if err := client.WaitForTasks(waitCtx, request.ConvID); err != nil {
					response.Warnings = append(response.Warnings, "task cache did not become ready; loaded-task fallback may be incomplete")
				}
				cancel()
			}
		}
		searchResponse.Results = fallbackRetrieveSearch(ctx, client, search, request, searchLimit)
	} else if searchResponse.Stale {
		response.Stale = true
		response.Warnings = append(response.Warnings, "search index reports stale results")
	}

	candidates := make(map[retrieveEntityKey]*retrieveCandidate, len(searchResponse.Results))
	for i, result := range searchResponse.Results {
		identity := normalizeRetrieveIdentity(result, request)
		if !identity.EntityType.Valid() || identity.EntityID == 0 {
			continue
		}
		key := retrieveEntityKey{identity.EntityType, identity.EntityID}
		if _, exists := candidates[key]; exists {
			continue
		}
		candidates[key] = &retrieveCandidate{
			entity: identity, preview: result.Preview, searchRank: i + 1,
			result: protocol.RetrieveResult{Metadata: retrieveMetadata(result.Metadata), Origins: []string{"search"}, Payload: result.Payload},
		}
	}

	edgeByID := make(map[uint64]protocol.Edge)
	var anchors []protocol.SearchEntityIdentity
	if !request.NoGraph && len(candidates) > 0 {
		anchors = retrieveAnchors(candidates)
		anchorEntities := make([]protocol.GraphRankEntity, len(anchors))
		for i, anchor := range anchors {
			anchorEntities[i] = protocol.GraphRankEntity{Type: searchTypeToGraphType(anchor.EntityType), ID: anchor.EntityID}
		}
		searchCandidates := retrieveSearchCandidates(candidates)
		graphResult, graphErr := client.GetGraphRank(ctx, request.ConvID, anchorEntities, searchCandidates, request.Depth, relationMask, direction, uint8(retrieveMaxHydrate))
		if graphErr != nil {
			response.Warnings = append(response.Warnings, "server graph ranking unavailable")
		} else {
			response.Truncation.Graph = graphResult.Truncated
			mergeGraphRankResult(candidates, anchors, graphResult, request)
			for _, edge := range graphResult.Edges {
				edgeByID[edge.EdgeID] = edge
			}
		}
	}

	selected := selectRetrieveCandidates(candidates, retrieveMaxHydrate)
	if len(selected) < len(candidates) {
		response.Truncation.Results = true
	}
	hydrateRetrieveCandidates(ctx, client, search, request, selected, &response)

	for _, candidate := range selected {
		candidate.result.Score = retrieveRankScore(candidate)
	}
	sort.Slice(selected, func(i, j int) bool {
		a, b := selected[i], selected[j]
		if a.result.Score != b.result.Score {
			return a.result.Score > b.result.Score
		}
		if a.searchRank != b.searchRank {
			if a.searchRank == 0 {
				return false
			}
			if b.searchRank == 0 {
				return true
			}
			return a.searchRank < b.searchRank
		}
		return retrieveIdentityLess(a.entity, b.entity)
	})
	if len(selected) > request.TopN {
		response.Truncation.Results = true
		selected = selected[:request.TopN]
	}

	usedEdgeIDs := make(map[uint64]bool)
	for i, candidate := range selected {
		candidate.result.Rank = i + 1
		prepareRetrieveResult(candidate)
		candidate.result.Evidence = selectRetrievePaths(candidate.paths, request.PathMode)
		response.Results = append(response.Results, candidate.result)
		for _, path := range candidate.result.Evidence {
			for _, edgeID := range path.EdgeIDs {
				usedEdgeIDs[edgeID] = true
			}
		}
	}
	applyRetrievePayloadPolicy(response.Results, request, &response.Truncation)
	for _, result := range response.Results {
		if containsString(result.Origins, "graph") {
			response.GraphContributed = true
			break
		}
	}
	for edgeID := range usedEdgeIDs {
		if edge, ok := edgeByID[edgeID]; ok {
			if resultEdge, valid := retrieveEdge(edge); valid {
				response.Edges = append(response.Edges, resultEdge)
			}
		}
	}
	sort.Slice(response.Edges, func(i, j int) bool { return response.Edges[i].ID < response.Edges[j].ID })
	return response, nil
}

func fallbackRetrieveSearch(ctx context.Context, client retrievalClient, search retrievalSearch, request protocol.RetrieveRequest, limit int) []protocol.SearchResult {
	assets, _ := search.Search(ctx, request.Workspace, request.Query, request.ConvID, limit, true)
	results := append([]protocol.SearchResult(nil), assets...)
	tasks := rankTasksForContext(client.GetTasks(request.ConvID), classifyAskIntent(request.Query), request.Query)
	for _, task := range tasks {
		if len(results) >= limit {
			break
		}
		results = append(results, searchResultFromTask(request.Workspace, request.ConvID, task))
	}
	return results
}

func normalizeRetrieveIdentity(result protocol.SearchResult, request protocol.RetrieveRequest) protocol.SearchEntityIdentity {
	identity := result.Entity
	if !identity.EntityType.Valid() && result.AssetID != 0 {
		identity.EntityType = protocol.SearchEntityAsset
		identity.EntityID = result.AssetID
	}
	if identity.Workspace == "" {
		identity.Workspace = request.Workspace
	}
	if identity.ConvID == 0 {
		identity.ConvID = request.ConvID
	}
	return identity
}

func retrieveAnchors(candidates map[retrieveEntityKey]*retrieveCandidate) []protocol.SearchEntityIdentity {
	ordered := make([]*retrieveCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.searchRank > 0 {
			ordered = append(ordered, candidate)
		}
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].searchRank < ordered[j].searchRank })
	if len(ordered) > retrieveMaxAnchors {
		ordered = ordered[:retrieveMaxAnchors]
	}
	anchors := make([]protocol.SearchEntityIdentity, len(ordered))
	for i, candidate := range ordered {
		anchors[i] = candidate.entity
	}
	return anchors
}

func retrieveSearchCandidates(candidates map[retrieveEntityKey]*retrieveCandidate) []protocol.GraphRankEntity {
	ordered := make([]*retrieveCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.searchRank > 0 {
			ordered = append(ordered, candidate)
		}
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].searchRank < ordered[j].searchRank })
	entities := make([]protocol.GraphRankEntity, len(ordered))
	for i, candidate := range ordered {
		entities[i] = protocol.GraphRankEntity{Type: searchTypeToGraphType(candidate.entity.EntityType), ID: candidate.entity.EntityID}
	}
	return entities
}

func mergeGraphRankResult(candidates map[retrieveEntityKey]*retrieveCandidate, anchors []protocol.SearchEntityIdentity, graphResult protocol.GraphRankResult, request protocol.RetrieveRequest) {
	for _, entry := range graphResult.Entries {
		entityType, ok := graphTypeToSearchType(entry.Entity.Type)
		if !ok {
			continue
		}
		key := retrieveEntityKey{entityType, entry.Entity.ID}
		candidate := candidates[key]
		if candidate == nil {
			candidate = &retrieveCandidate{
				entity: protocol.SearchEntityIdentity{Workspace: request.Workspace, EntityType: key.entityType, EntityID: key.id, ConvID: request.ConvID},
				result: protocol.RetrieveResult{Origins: []string{"graph"}},
			}
			candidates[key] = candidate
		}
		candidate.pageRank = entry.Score
		for _, path := range entry.Paths {
			if int(path.AnchorIndex) >= len(anchors) {
				continue
			}
			anchor := anchors[path.AnchorIndex]
			candidate.paths = append(candidate.paths, protocol.RetrievePath{
				Anchor: protocol.RetrieveEntityRef{Type: anchor.EntityType, ID: anchor.EntityID},
				Depth:  path.Depth, EdgeIDs: protocol.SearchIDs(path.EdgeIDs),
			})
		}
		if len(candidate.paths) > 0 && !containsString(candidate.result.Origins, "graph") {
			candidate.result.Origins = append(candidate.result.Origins, "graph")
		}
	}
}

func selectRetrieveCandidates(candidates map[retrieveEntityKey]*retrieveCandidate, limit int) []*retrieveCandidate {
	selected := make([]*retrieveCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		candidate.result.Score = retrieveRankScore(candidate)
		selected = append(selected, candidate)
	}
	sort.Slice(selected, func(i, j int) bool {
		if selected[i].result.Score != selected[j].result.Score {
			return selected[i].result.Score > selected[j].result.Score
		}
		return retrieveIdentityLess(selected[i].entity, selected[j].entity)
	})
	if len(selected) > limit {
		selected = selected[:limit]
	}
	return selected
}

func hydrateRetrieveCandidates(ctx context.Context, client retrievalClient, search retrievalSearch, request protocol.RetrieveRequest, candidates []*retrieveCandidate, response *protocol.RetrieveResponse) {
	tasks := client.GetTasks(request.ConvID)
	taskByID := make(map[uint64]protocol.Task, len(tasks))
	for _, task := range tasks {
		taskByID[task.ID] = task
	}
	missingTaskIDs := make(protocol.SearchIDs, 0)
	assetCandidates := make([]*retrieveCandidate, 0)
	for _, candidate := range candidates {
		if candidate.preview != "" || candidate.result.Payload != "" {
			continue
		}
		switch candidate.entity.EntityType {
		case protocol.SearchEntityTask:
			if task, ok := taskByID[candidate.entity.EntityID]; ok {
				hydrateRetrieveTask(candidate, task)
			} else {
				missingTaskIDs = append(missingTaskIDs, candidate.entity.EntityID)
			}
		case protocol.SearchEntityAsset:
			assetCandidates = append(assetCandidates, candidate)
		}
	}

	if len(missingTaskIDs) > 0 {
		result, err := search.SearchEntities(ctx, protocol.SearchRequest{
			Workspace: request.Workspace, ConvID: request.ConvID, TopN: len(missingTaskIDs), IncludePayload: true,
			Filters: &protocol.SearchFilters{EntityTypes: []protocol.SearchEntityType{protocol.SearchEntityTask}, Task: &protocol.SearchTaskFilters{TaskIDs: missingTaskIDs}},
		})
		if err != nil {
			response.Warnings = append(response.Warnings, "some graph-linked tasks could not be hydrated")
		} else {
			byID := make(map[uint64]protocol.SearchResult, len(result.Results))
			for _, item := range result.Results {
				byID[item.Entity.EntityID] = item
			}
			for _, candidate := range candidates {
				if item, ok := byID[candidate.entity.EntityID]; ok && candidate.entity.EntityType == protocol.SearchEntityTask {
					candidate.result.Metadata = retrieveMetadata(item.Metadata)
					candidate.preview = item.Preview
					candidate.result.Payload = item.Payload
				}
			}
		}
	}

	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	var failedMu sync.Mutex
	failed := 0
	for _, candidate := range assetCandidates {
		wg.Add(1)
		go func(candidate *retrieveCandidate) {
			defer wg.Done()
			sem <- struct{}{}
			asset, err := client.GetAsset(ctx, request.ConvID, candidate.entity.EntityID)
			<-sem
			if err != nil {
				failedMu.Lock()
				failed++
				failedMu.Unlock()
				return
			}
			candidate.result.Metadata = &protocol.SearchMetadata{AssetType: asset.AssetType}
			candidate.preview = asset.Preview
			candidate.result.Payload = asset.Payload
		}(candidate)
	}
	wg.Wait()
	if failed > 0 {
		response.Warnings = append(response.Warnings, fmt.Sprintf("%d graph-linked assets could not be hydrated", failed))
	}
}

func hydrateRetrieveTask(candidate *retrieveCandidate, task protocol.Task) {
	candidate.preview = task.Title
	candidate.result.Payload = task.Description
	candidate.result.Metadata = &protocol.SearchMetadata{Task: &protocol.SearchTaskMetadata{
		Status: task.Status, OrderIndex: task.OrderIndex, Assignee: task.Assignee, Priority: task.Priority, Color: task.Color,
		CreatedBy: task.CreatedBy, CreatedAt: task.CreatedAt, UpdatedAt: task.UpdatedAt, ExternalRef: task.ExternalRef,
		DueAt: task.DueAt, BlockedBy: task.BlockedBy, CompletedAt: task.CompletedAt, CompletedBy: task.CompletedBy, Project: task.Project,
	}}
}

func searchResultFromTask(workspace string, convID uint64, task protocol.Task) protocol.SearchResult {
	candidate := &retrieveCandidate{entity: protocol.SearchEntityIdentity{Workspace: workspace, EntityType: protocol.SearchEntityTask, EntityID: task.ID, ConvID: convID}}
	hydrateRetrieveTask(candidate, task)
	metadata := protocol.SearchMetadata{}
	if candidate.result.Metadata != nil {
		metadata = *candidate.result.Metadata
	}
	return protocol.SearchResult{
		Entity: candidate.entity, Metadata: metadata, Preview: candidate.preview, Payload: candidate.result.Payload,
	}
}

func retrieveRankScore(candidate *retrieveCandidate) float64 {
	score := 0.0
	if candidate.searchRank > 0 {
		score += 1 / float64(candidate.searchRank)
	}
	score += 0.1 * candidate.pageRank
	return score
}

func parseRetrieveDirection(value string) (uint8, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "both":
		return 0, nil
	case "out", "outgoing":
		return 1, nil
	case "in", "incoming":
		return 2, nil
	default:
		return 0, fmt.Errorf("unsupported direction %q (expected both, outgoing, or incoming)", value)
	}
}

func searchTypeToGraphType(entityType protocol.SearchEntityType) uint16 {
	if entityType == protocol.SearchEntityTask {
		return entityTypeTask
	}
	return entityTypeAsset
}

func graphTypeToSearchType(entityType uint16) (protocol.SearchEntityType, bool) {
	switch entityType {
	case entityTypeTask:
		return protocol.SearchEntityTask, true
	case entityTypeAsset:
		return protocol.SearchEntityAsset, true
	default:
		return "", false
	}
}

func retrieveIdentityLess(a, b protocol.SearchEntityIdentity) bool {
	if a.EntityType != b.EntityType {
		return a.EntityType < b.EntityType
	}
	return a.EntityID < b.EntityID
}

func retrieveEdge(edge protocol.Edge) (protocol.RetrieveEdge, bool) {
	fromType, fromOK := graphTypeToSearchType(edge.SourceType)
	toType, toOK := graphTypeToSearchType(edge.TargetType)
	if !fromOK || !toOK {
		return protocol.RetrieveEdge{}, false
	}
	return protocol.RetrieveEdge{
		ID:       edge.EdgeID,
		From:     protocol.RetrieveEntityRef{Type: fromType, ID: edge.SourceID},
		To:       protocol.RetrieveEntityRef{Type: toType, ID: edge.TargetID},
		Relation: relationName(edge.Relation),
	}, true
}

func prepareRetrieveResult(candidate *retrieveCandidate) {
	result := &candidate.result
	result.Type = candidate.entity.EntityType
	result.ID = candidate.entity.EntityID
	if result.Type == protocol.SearchEntityTask {
		result.Title = strings.TrimSpace(candidate.preview)
		if result.Metadata != nil && result.Metadata.Task != nil {
			result.Project = result.Metadata.Task.Project
		}
		result.Teaser = noteTeaser(result.Payload, "markdown")
		return
	}

	preview := parseNotePreviewJSON(candidate.preview)
	if preview.Title != "" {
		result.Title = preview.Title
		result.Project = preview.Project
		result.Tags = preview.Tags
		result.Format = preview.Format
		result.Teaser = preview.Teaser
	} else {
		result.Title = strings.TrimSpace(candidate.preview)
	}
	if result.Teaser == "" {
		result.Teaser = noteTeaser(result.Payload, result.Format)
	}
}

func retrieveMetadata(metadata protocol.SearchMetadata) *protocol.SearchMetadata {
	if metadata.AssetType == 0 && metadata.Task == nil {
		return nil
	}
	return &metadata
}

func applyRetrievePayloadPolicy(results []protocol.RetrieveResult, request protocol.RetrieveRequest, truncation *protocol.RetrieveTruncation) {
	remaining := request.MaxPayloadBytes
	for i := range results {
		results[i].PayloadState = protocol.RetrievePayloadStateComplete
		keep := request.PayloadMode == protocol.RetrievePayloadAll ||
			(request.PayloadMode == protocol.RetrievePayloadTop && i < request.PayloadTop)
		if !keep {
			if results[i].Payload != "" {
				truncation.Payloads = true
				results[i].PayloadState = protocol.RetrievePayloadStateOmitted
			}
			results[i].Payload = ""
			continue
		}

		payload, truncated := truncateRetrievePayload(results[i].Payload, remaining)
		results[i].Payload = payload
		if truncated {
			truncation.Payloads = true
			results[i].PayloadState = protocol.RetrievePayloadStateTruncated
			remaining = 0
		} else {
			remaining -= len(payload)
		}
		if payload != "" {
			results[i].Teaser = ""
		}
	}
}

func truncateRetrievePayload(value string, limit int) (string, bool) {
	if len(value) <= limit {
		return value, false
	}
	if limit <= 0 {
		return "", value != ""
	}
	end := limit
	for end > 0 && !utf8.ValidString(value[:end]) {
		end--
	}
	return value[:end], true
}

func selectRetrievePaths(paths []protocol.RetrievePath, mode string) []protocol.RetrievePath {
	if mode == protocol.RetrievePathsNone || len(paths) == 0 {
		return nil
	}
	selected := append([]protocol.RetrievePath(nil), paths...)
	sort.Slice(selected, func(i, j int) bool { return retrievePathLess(selected[i], selected[j]) })
	if mode == protocol.RetrievePathsBest {
		selected = selected[:1]
	}
	return selected
}

func retrievePathLess(a, b protocol.RetrievePath) bool {
	if a.Depth != b.Depth {
		return a.Depth < b.Depth
	}
	if a.Anchor.Type != b.Anchor.Type {
		return a.Anchor.Type < b.Anchor.Type
	}
	if a.Anchor.ID != b.Anchor.ID {
		return a.Anchor.ID < b.Anchor.ID
	}
	for i := 0; i < min(len(a.EdgeIDs), len(b.EdgeIDs)); i++ {
		if a.EdgeIDs[i] != b.EdgeIDs[i] {
			return a.EdgeIDs[i] < b.EdgeIDs[i]
		}
	}
	return len(a.EdgeIDs) < len(b.EdgeIDs)
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
