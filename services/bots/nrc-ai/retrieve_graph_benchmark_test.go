package main

import (
	"math"
	"os"
	"sort"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type benchmarkGraphOutcome struct {
	anchor protocol.SearchEntityIdentity
	result graphQueryResult
}

type benchmarkGraphPath struct {
	target retrieveEntityKey
	path   protocol.RetrievePath
}

func benchmarkRetrieveGraphFixture() []benchmarkGraphOutcome {
	edges := make([]protocol.Edge, 0, 360)
	edgeID := uint64(1)
	for anchor := uint64(1); anchor <= 5; anchor++ {
		for shared := uint64(1000); shared < 1040; shared++ {
			edges = append(edges, protocol.Edge{EdgeID: edgeID, ConvID: 100, SourceType: entityTypeTask, SourceID: anchor, TargetType: entityTypeAsset, TargetID: shared, Relation: protocol.RelationReferences})
			edgeID++
		}
	}
	for shared := uint64(1000); shared < 1040; shared++ {
		for leaf := uint64(0); leaf < 4; leaf++ {
			edges = append(edges, protocol.Edge{EdgeID: edgeID, ConvID: 100, SourceType: entityTypeAsset, SourceID: shared, TargetType: entityTypeTask, TargetID: 2000 + (shared-1000)*4 + leaf, Relation: protocol.RelationRelatedTo})
			edgeID++
		}
	}
	nodes := make([]protocol.GraphNode, 0, 205)
	for id := uint64(1); id <= 5; id++ {
		nodes = append(nodes, protocol.GraphNode{Type: entityTypeTask, ID: id, Depth: 2})
	}
	for id := uint64(1000); id < 1040; id++ {
		nodes = append(nodes, protocol.GraphNode{Type: entityTypeAsset, ID: id, Depth: 1})
	}
	for id := uint64(2000); id < 2160; id++ {
		nodes = append(nodes, protocol.GraphNode{Type: entityTypeTask, ID: id, Depth: 2})
	}
	outcomes := make([]benchmarkGraphOutcome, 5)
	for i := range outcomes {
		outcomes[i] = benchmarkGraphOutcome{
			anchor: protocol.SearchEntityIdentity{EntityType: protocol.SearchEntityTask, EntityID: uint64(i + 1)},
			result: graphQueryResult{Nodes: nodes, Edges: edges},
		}
	}

	return outcomes
}

func benchmarkLoadGraphRankResult(b *testing.B) protocol.GraphRankResult {
	path := os.Getenv("NRC_GRAPH_RANK_BENCH_PAYLOAD")
	if path == "" {
		b.Skip("set NRC_GRAPH_RANK_BENCH_PAYLOAD to the payload exported by the Odin benchmark")
	}
	payload, err := os.ReadFile(path)
	if err != nil {
		b.Fatalf("read Odin graph rank payload: %v", err)
	}
	ranked, err := protocol.DecodeGraphRankResult(payload)
	if err != nil {
		b.Fatalf("decode Odin graph rank payload: %v", err)
	}
	if len(ranked.Entries) != 100 || len(ranked.Edges) != 255 {
		b.Fatalf("unexpected Odin result dimensions: entries=%d edges=%d", len(ranked.Entries), len(ranked.Edges))
	}
	edges := make(map[uint64]bool, len(ranked.Edges))
	for _, edge := range ranked.Edges {
		edges[edge.EdgeID] = true
	}
	used := make(map[uint64]bool, len(ranked.Edges))
	scoreSum := 0.0
	sharedPathFound := false
	for _, entry := range ranked.Entries {
		scoreSum += entry.Score
		for _, path := range entry.Paths {
			if entry.Entity.Type == entityTypeAsset && entry.Entity.ID == 1000 && path.Depth == 1 {
				sharedPathFound = true
			}
			for _, edgeID := range path.EdgeIDs {
				if !edges[edgeID] {
					b.Fatalf("path references missing edge %d", edgeID)
				}
				used[edgeID] = true
			}
		}
	}
	if !sharedPathFound || scoreSum <= 0 || math.IsNaN(scoreSum) || len(used) != len(edges) {
		b.Fatalf("Odin result failed path/rank coverage: shared_path=%t score_sum=%f used=%d edges=%d", sharedPathFound, scoreSum, len(used), len(edges))
	}
	return *ranked
}

func benchmarkInitialCandidates() map[retrieveEntityKey]*retrieveCandidate {
	candidates := make(map[retrieveEntityKey]*retrieveCandidate, 205)
	for id := uint64(1); id <= 5; id++ {
		key := retrieveEntityKey{protocol.SearchEntityTask, id}
		candidates[key] = &retrieveCandidate{entity: protocol.SearchEntityIdentity{EntityType: key.entityType, EntityID: id}, searchRank: int(id)}
	}
	for id := uint64(1000); id < 1040; id++ {
		key := retrieveEntityKey{protocol.SearchEntityAsset, id}
		candidates[key] = &retrieveCandidate{entity: protocol.SearchEntityIdentity{EntityType: key.entityType, EntityID: id}, searchRank: int(id - 994)}
	}
	for id := uint64(2000); id < 2005; id++ {
		key := retrieveEntityKey{protocol.SearchEntityTask, id}
		candidates[key] = &retrieveCandidate{entity: protocol.SearchEntityIdentity{EntityType: key.entityType, EntityID: id}, searchRank: int(id - 1954)}
	}
	return candidates
}

func BenchmarkRetrieveGraphPostprocessing(b *testing.B) {
	outcomes := benchmarkRetrieveGraphFixture()
	ranked := benchmarkLoadGraphRankResult(b)
	anchors := make([]protocol.SearchEntityIdentity, len(outcomes))
	for i := range outcomes {
		anchors[i] = outcomes[i].anchor
	}
	request := protocol.RetrieveRequest{Workspace: "benchmark", ConvID: 100, Depth: 2}

	b.Run("previous_go_paths_and_pagerank", func(b *testing.B) {
		checksum := 0.0
		for range b.N {
			candidates := benchmarkInitialCandidates()
			edgeByID := make(map[uint64]protocol.Edge, 360)
			for _, outcome := range outcomes {
				for _, edge := range outcome.result.Edges {
					edgeByID[edge.EdgeID] = edge
				}
				for _, graphPath := range benchmarkGraphPaths(request, outcome) {
					candidate := candidates[graphPath.target]
					if candidate == nil {
						candidate = &retrieveCandidate{entity: protocol.SearchEntityIdentity{EntityType: graphPath.target.entityType, EntityID: graphPath.target.id}}
						candidates[graphPath.target] = candidate
					}
					candidate.paths = append(candidate.paths, graphPath.path)
				}
			}
			benchmarkPersonalizedPageRank(candidates, anchors, edgeByID, 0)
			checksum += candidates[retrieveEntityKey{protocol.SearchEntityTask, 1}].pageRank
		}
		if checksum == 0 {
			b.Fatal("PageRank checksum was not observed")
		}
	})

	b.Run("proposed_go_merge", func(b *testing.B) {
		checksum := 0.0
		for range b.N {
			candidates := benchmarkInitialCandidates()
			mergeGraphRankResult(candidates, anchors, ranked, request)
			edgeByID := make(map[uint64]protocol.Edge, len(ranked.Edges))
			for _, edge := range ranked.Edges {
				edgeByID[edge.EdgeID] = edge
			}
			checksum += candidates[retrieveEntityKey{protocol.SearchEntityTask, 1}].pageRank + float64(len(edgeByID))
		}
		if checksum == 0 {
			b.Fatal("merge checksum was not observed")
		}
	})
}

func benchmarkGraphPaths(request protocol.RetrieveRequest, outcome benchmarkGraphOutcome) []benchmarkGraphPath {
	type parentEntry struct {
		parent retrieveEntityKey
		edgeID uint64
	}
	anchorKey := retrieveEntityKey{outcome.anchor.EntityType, outcome.anchor.EntityID}
	parents := map[retrieveEntityKey]parentEntry{anchorKey: {parent: anchorKey}}
	queue := []retrieveEntityKey{anchorKey}
	edges := append([]protocol.Edge(nil), outcome.result.Edges...)
	sort.Slice(edges, func(i, j int) bool { return edges[i].EdgeID < edges[j].EdgeID })
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		for _, edge := range edges {
			neighbor, ok := benchmarkEdgeNeighbor(edge, current, 0)
			if !ok {
				continue
			}
			if _, seen := parents[neighbor]; seen {
				continue
			}
			parents[neighbor] = parentEntry{parent: current, edgeID: edge.EdgeID}
			queue = append(queue, neighbor)
		}
	}
	paths := make([]benchmarkGraphPath, 0, len(parents)-1)
	for target := range parents {
		if target == anchorKey {
			continue
		}
		edgeIDs := make([]uint64, 0, request.Depth)
		for current := target; current != anchorKey; {
			entry := parents[current]
			edgeIDs = append(edgeIDs, entry.edgeID)
			current = entry.parent
		}
		for i, j := 0, len(edgeIDs)-1; i < j; i, j = i+1, j-1 {
			edgeIDs[i], edgeIDs[j] = edgeIDs[j], edgeIDs[i]
		}
		paths = append(paths, benchmarkGraphPath{target: target, path: protocol.RetrievePath{Anchor: protocol.RetrieveEntityRef{Type: outcome.anchor.EntityType, ID: outcome.anchor.EntityID}, Depth: uint8(len(edgeIDs)), EdgeIDs: protocol.SearchIDs(edgeIDs)}})
	}
	return paths
}

func benchmarkEdgeNeighbor(edge protocol.Edge, current retrieveEntityKey, direction uint8) (retrieveEntityKey, bool) {
	sourceType, sourceOK := graphTypeToSearchType(edge.SourceType)
	targetType, targetOK := graphTypeToSearchType(edge.TargetType)
	if !sourceOK || !targetOK {
		return retrieveEntityKey{}, false
	}
	source := retrieveEntityKey{sourceType, edge.SourceID}
	target := retrieveEntityKey{targetType, edge.TargetID}
	if current == source && direction != 2 {
		return target, true
	}
	if current == target && direction != 1 {
		return source, true
	}
	return retrieveEntityKey{}, false
}

func benchmarkPersonalizedPageRank(candidates map[retrieveEntityKey]*retrieveCandidate, anchors []protocol.SearchEntityIdentity, edges map[uint64]protocol.Edge, direction uint8) {
	const damping = 0.85
	keys := make([]retrieveEntityKey, 0, len(candidates))
	for key := range candidates {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].entityType != keys[j].entityType {
			return keys[i].entityType < keys[j].entityType
		}
		return keys[i].id < keys[j].id
	})
	personalization := make(map[retrieveEntityKey]float64, len(anchors))
	weightSum := 0.0
	for rank, anchor := range anchors {
		weight := 1 / float64(rank+1)
		personalization[retrieveEntityKey{anchor.EntityType, anchor.EntityID}] = weight
		weightSum += weight
	}
	for key, weight := range personalization {
		personalization[key] = weight / weightSum
	}
	adjacency := make(map[retrieveEntityKey][]retrieveEntityKey, len(candidates))
	edgeIDs := make([]uint64, 0, len(edges))
	for edgeID := range edges {
		edgeIDs = append(edgeIDs, edgeID)
	}
	sort.Slice(edgeIDs, func(i, j int) bool { return edgeIDs[i] < edgeIDs[j] })
	for _, edgeID := range edgeIDs {
		edge := edges[edgeID]
		sourceType, _ := graphTypeToSearchType(edge.SourceType)
		targetType, _ := graphTypeToSearchType(edge.TargetType)
		source := retrieveEntityKey{sourceType, edge.SourceID}
		target := retrieveEntityKey{targetType, edge.TargetID}
		if direction != 2 {
			adjacency[source] = append(adjacency[source], target)
		}
		if direction != 1 {
			adjacency[target] = append(adjacency[target], source)
		}
	}
	rank := make(map[retrieveEntityKey]float64, len(candidates))
	for key, weight := range personalization {
		rank[key] = weight
	}
	for range 20 {
		next := make(map[retrieveEntityKey]float64, len(candidates))
		for key, weight := range personalization {
			next[key] = (1 - damping) * weight
		}
		dangling := 0.0
		for _, key := range keys {
			neighbors := adjacency[key]
			if len(neighbors) == 0 {
				dangling += rank[key]
				continue
			}
			share := damping * rank[key] / float64(len(neighbors))
			for _, neighbor := range neighbors {
				next[neighbor] += share
			}
		}
		for key, weight := range personalization {
			next[key] += damping * dangling * weight
		}
		delta := 0.0
		for _, key := range keys {
			difference := next[key] - rank[key]
			if difference < 0 {
				difference = -difference
			}
			delta += difference
		}
		rank = next
		if delta < 1e-10 {
			break
		}
	}
	maxScore := 0.0
	for _, score := range rank {
		maxScore = max(maxScore, score)
	}
	for key, score := range rank {
		candidates[key].pageRank = score / maxScore * float64(len(anchors))
	}
}
