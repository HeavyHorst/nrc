package main

import "core:math"
import "core:slice"
import pr "protocol"

// Independent edge-list oracle for worker_db_test_graph_walks. This deliberately
// has no Conversation_State, adjacency index, SQLite, or production traversal
// dependency. Fixed arrays bound it to that six-entity, eight-edge fixture.
GRAPH_RANK_TEST_ENTITIES :: [6]pr.GraphEntityKey{{.Asset, 1}, {.Asset, 2}, {.Asset, 999}, {.Task, 10}, {.Task, 20}, {.Task, max(u64)}}

graph_rank_test_index :: proc(entity: pr.GraphEntityKey) -> int {
	for key, i in GRAPH_RANK_TEST_ENTITIES do if key == entity do return i
	panic("entity outside rank reference fixture")
}

graph_rank_test_neighbor :: proc(edge: pr.Edge, current: int, direction: pr.Direction) -> int {
	entities := GRAPH_RANK_TEST_ENTITIES
	key := entities[current]
	if direction != .Incoming && edge.source_type == key.target_type && edge.source_id == key.target_id {
		return graph_rank_test_index({edge.target_type, edge.target_id})
	}
	if direction != .Outgoing && edge.target_type == key.target_type && edge.target_id == key.target_id {
		return graph_rank_test_index({edge.source_type, edge.source_id})
	}
	return -1
}

graph_rank_test_reference :: proc(req: pr.GraphRankRequest, edges: []pr.Edge, buffer: []byte) -> int {
	req := req
	assert(len(edges) <= 8 && req.anchor_count <= 2 && req.candidate_count <= 2 && req.max_depth <= 4)
	live: [6]bool; included: [8]bool
	paths: [6][2]pr.GraphRankPath; path_ids: [6][2][4]pr.EdgeID; path_counts: [6]int
	for anchor_index in 0 ..< int(req.anchor_count) {
		anchor := graph_rank_test_index(req.anchors[anchor_index])
		visited: [6]bool; depths: [6]u8; parents, parent_edges: [6]int; queue: [6]int
		visited[anchor] = true; live[anchor] = true; queue[0] = anchor; count := 1
		for qi := 0; qi < count; qi += 1 {
			current := queue[qi]
			if depths[current] >= req.max_depth do continue
			for edge, ei in edges {
				if req.relation_mask != 0 && req.relation_mask & (u16(1) << (u16(edge.relation) - 1)) == 0 do continue
				neighbor := graph_rank_test_neighbor(edge, current, req.direction)
				if neighbor < 0 do continue
				included[ei] = true
				if visited[neighbor] do continue
				visited[neighbor] = true; live[neighbor] = true
				depths[neighbor] = depths[current] + 1; parents[neighbor] = current; parent_edges[neighbor] = ei
				queue[count] = neighbor; count += 1
			}
		}
		for present, i in visited {
			if !present || i == anchor do continue
			pi := path_counts[i]; depth := int(depths[i]); current := i
			for step := depth - 1; step >= 0; step -= 1 {
				path_ids[i][pi][step] = edges[parent_edges[current]].edge_id
				current = parents[current]
			}
			paths[i][pi] = {
				anchor_index = u8(anchor_index),
				depth        = depths[i],
				edge_ids     = path_ids[i][pi][:depth],
			}
			path_counts[i] += 1
		}
	}
	scores, personalization: [6]f64
	has_edges := false
	for included_edge in included do has_edges = has_edges || included_edge
	if has_edges {
		weight_sum := 0.0
		for i in 0 ..< int(req.anchor_count) {
			weight := 1.0 / f64(i + 1)
			personalization[graph_rank_test_index(req.anchors[i])] = weight; weight_sum += weight
		}
		for &weight in personalization do weight /= weight_sum
		scores = personalization
		for _ in 0 ..< 20 {
			next: [6]f64
			for weight, i in personalization do next[i] = (1.0 - 0.85) * weight
			dangling := 0.0
			// Canonical entity/edge order makes floating-point ties reproducible.
			for present, i in live {
				if !present do continue
				degree := 0
				for edge, ei in edges do if included[ei] && graph_rank_test_neighbor(edge, i, req.direction) >= 0 do degree += 1
				if degree == 0 {dangling += scores[i]; continue}
				share := 0.85 * scores[i] / f64(degree)
				for edge, ei in edges {
					if !included[ei] do continue
					neighbor := graph_rank_test_neighbor(edge, i, req.direction)
					if neighbor >= 0 do next[neighbor] += share
				}
			}
			for weight, i in personalization do next[i] += 0.85 * dangling * weight
			delta := 0.0
			for score, i in scores do delta += math.abs(next[i] - score)
			scores = next
			if delta < 1e-10 do break
		}
		peak := 0.0
		for score in scores do peak = max(peak, score)
		if peak > 0 do for &score in scores do score = score / peak * f64(req.anchor_count)
	}
	entries, others: [6]pr.GraphRankEntry; requested: [6]bool
	count, other_count := 0, 0
	for candidate in req.candidates[:req.candidate_count] {
		i := graph_rank_test_index(candidate); requested[i] = true
		entries[count] = {
			target_type = candidate.target_type,
			target_id   = candidate.target_id,
			score       = scores[i],
			paths       = paths[i][:path_counts[i]],
		}
		count += 1
	}
	for key, i in GRAPH_RANK_TEST_ENTITIES {
		if !live[i] || requested[i] do continue
		others[other_count] = {
			target_type = key.target_type,
			target_id   = key.target_id,
			score       = scores[i],
			paths       = paths[i][:path_counts[i]],
		}
		other_count += 1
	}
	slice.sort_by(others[:other_count], proc(a, b: pr.GraphRankEntry) -> bool {
		if a.score != b.score do return a.score > b.score
		if a.target_type != b.target_type do return a.target_type < b.target_type
		return a.target_id < b.target_id
	})
	added := min(other_count, int(req.top_n)); copy(entries[count:], others[:added]); count += added
	used: [8]bool
	for entry in entries[:count] do for path in entry.paths do for id in path.edge_ids {
		for edge, ei in edges do if edge.edge_id == id do used[ei] = true
	}
	result_edges: [8]pr.GraphRankEdge; edge_count := 0
	for edge, ei in edges {
		if !used[ei] do continue
		result_edges[edge_count] = {
			edge_id     = edge.edge_id,
			source_type = edge.source_type,
			source_id   = edge.source_id,
			target_type = edge.target_type,
			target_id   = edge.target_id,
			relation    = edge.relation,
		}
		edge_count += 1
	}
	return pr.serializeGraphRankResult(
		{conv_id = req.conv_id, entries = entries[:count], edges = result_edges[:edge_count], correlation_id = req.correlation_id},
		buffer,
	)
}
