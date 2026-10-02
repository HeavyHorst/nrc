package main

import "core:mem/virtual"
import "core:slice"

import "byte_pool"
import pr "protocol"

MAX_GRAPH_RANK_UNION_NODES :: MAX_RESULT_NODES * pr.MAX_GRAPH_RANK_ANCHORS
GRAPH_RANK_DAMPING :: 0.85
GRAPH_RANK_ITERATIONS :: 20
GRAPH_RANK_TOLERANCE :: 1e-10

Graph_Rank_Path_List :: [dynamic]pr.GraphRankPath
Graph_Rank_Ordered_Adjacency :: map[Edge_Entity_Key][]pr.EdgeID

graph_rank_key :: proc(entity: pr.GraphEntityKey) -> Edge_Entity_Key {
	return {target_type = entity.target_type, target_id = entity.target_id}
}

graph_rank_entry_less :: proc(a, b: pr.GraphRankEntry) -> bool {
	if a.score != b.score do return a.score > b.score
	if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
	return a.target_id < b.target_id
}

graph_rank_ordered_edge_ids :: proc(
	conv: ^Conversation_State,
	key: Edge_Entity_Key,
	ordered_adjacency: ^Graph_Rank_Ordered_Adjacency,
	allocator := context.allocator,
) -> []pr.EdgeID {
	if ordered, ok := ordered_adjacency[key]; ok do return ordered
	edge_ids, ok := conv.edges_by_entity[key]
	if !ok do return nil
	ordered := make([]pr.EdgeID, len(edge_ids), allocator = allocator)
	copy(ordered, edge_ids[:])
	slice.sort_by(ordered, proc(a, b: pr.EdgeID) -> bool {return a < b})
	ordered_adjacency[key] = ordered
	return ordered
}

graph_rank_collect_anchor :: proc(
	conv: ^Conversation_State,
	req: pr.GraphRankRequest,
	anchor_index: int,
	union_nodes: ^map[Edge_Entity_Key]bool,
	union_edges: ^map[pr.EdgeID]bool,
	paths: ^map[Edge_Entity_Key]Graph_Rank_Path_List,
	ordered_adjacency: ^Graph_Rank_Ordered_Adjacency,
	allocator := context.allocator,
) -> (
	truncated: bool,
) {
	BFS_Entry :: struct {
		key:   Edge_Entity_Key,
		depth: u8,
	}
	anchor := graph_rank_key(req.anchors[anchor_index])
	visited := make(map[Edge_Entity_Key]u8, MAX_RESULT_NODES, allocator = allocator)
	defer delete(visited)
	parent := make(map[Edge_Entity_Key]Edge_Entity_Key, MAX_RESULT_NODES, allocator = allocator)
	defer delete(parent)
	parent_edge := make(map[Edge_Entity_Key]pr.EdgeID, MAX_RESULT_NODES, allocator = allocator)
	defer delete(parent_edge)
	queue := make([dynamic]BFS_Entry, 0, MAX_RESULT_NODES, allocator = allocator)
	defer delete(queue)

	visited[anchor] = 0
	parent[anchor] = anchor
	union_nodes[anchor] = true
	append(&queue, BFS_Entry{anchor, 0})
	qi := 0
	bfs: for qi < len(queue) {
		current := queue[qi]
		qi += 1
		if current.depth >= req.max_depth do continue
		for edge_id in graph_rank_ordered_edge_ids(conv, current.key, ordered_adjacency, allocator) {
			edge := conv.edges[edge_id]
			if edge == nil || !pr.relation_matches_mask(edge.relation, req.relation_mask) do continue
			neighbor, resolved := pr.resolve_neighbor(edge, current.key.target_type, current.key.target_id, req.direction)
			if !resolved do continue
			key := Edge_Entity_Key {
				target_type = neighbor.target_type,
				target_id   = neighbor.target_id,
			}
			if key not_in visited {
				if len(visited) >= MAX_RESULT_NODES {
					truncated = true
					break bfs
				}
				visited[key] = current.depth + 1
				parent[key] = current.key
				parent_edge[key] = edge_id
				union_nodes[key] = true
				append(&queue, BFS_Entry{key, current.depth + 1})
			}
			if key in visited do union_edges[edge_id] = true
		}
	}

	for key, depth in visited {
		if key == anchor do continue
		reversed: [pr.MAX_GRAPH_RANK_DEPTH]pr.EdgeID
		count := 0
		current := key
		for current != anchor && count < len(reversed) {
			edge_id, ok := parent_edge[current]
			if !ok do break
			reversed[count] = edge_id
			count += 1
			current = parent[current]
		}
		if current != anchor || count == 0 do continue
		edge_path := make([]pr.EdgeID, count, allocator = allocator)
		for i := 0; i < count; i += 1 do edge_path[i] = reversed[count - i - 1]
		if key not_in paths do paths[key] = make(Graph_Rank_Path_List, 0, pr.MAX_GRAPH_RANK_ANCHORS, allocator = allocator)
		append(&paths[key], pr.GraphRankPath{anchor_index = u8(anchor_index), depth = depth, edge_ids = edge_path})
	}
	return
}

graph_rank_scores :: proc(
	conv: ^Conversation_State,
	req: pr.GraphRankRequest,
	union_nodes: map[Edge_Entity_Key]bool,
	union_edges: map[pr.EdgeID]bool,
	allocator := context.allocator,
) -> map[Edge_Entity_Key]f64 {
	if len(union_edges) == 0 do return make(map[Edge_Entity_Key]f64, len(union_nodes), allocator = allocator)
	keys := make([dynamic]Edge_Entity_Key, 0, len(union_nodes), allocator = allocator)
	for key in union_nodes do append(&keys, key)
	slice.sort_by(keys[:], proc(a, b: Edge_Entity_Key) -> bool {
		if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
		return a.target_id < b.target_id
	})
	personalization := make(map[Edge_Entity_Key]f64, int(req.anchor_count), allocator = allocator)
	weight_sum := 0.0
	for i := 0; i < int(req.anchor_count); i += 1 {
		weight := 1.0 / f64(i + 1)
		personalization[graph_rank_key(req.anchors[i])] = weight
		weight_sum += weight
	}
	for key, weight in personalization do personalization[key] = weight / weight_sum
	rank := make(map[Edge_Entity_Key]f64, len(keys), allocator = allocator)
	next := make(map[Edge_Entity_Key]f64, len(keys), allocator = allocator)
	for key, weight in personalization do rank[key] = weight
	degree_by_key := make(map[Edge_Entity_Key]int, len(keys), allocator = allocator)
	for key in keys {
		if edge_ids, ok := conv.edges_by_entity[key]; ok {
			for edge_id in edge_ids {
				if edge_id not_in union_edges do continue
				edge := conv.edges[edge_id]
				if edge == nil do continue
				_, resolved := pr.resolve_neighbor(edge, key.target_type, key.target_id, req.direction)
				if resolved do degree_by_key[key] += 1
			}
		}
	}

	for _ in 0 ..< GRAPH_RANK_ITERATIONS {
		clear(&next)
		for key, weight in personalization do next[key] = (1.0 - GRAPH_RANK_DAMPING) * weight
		dangling := 0.0
		for key in keys {
			degree := degree_by_key[key]
			if degree == 0 {
				dangling += rank[key]
				continue
			}
			share := GRAPH_RANK_DAMPING * rank[key] / f64(degree)
			for edge_id in conv.edges_by_entity[key] {
				if edge_id not_in union_edges do continue
				edge := conv.edges[edge_id]
				if edge == nil do continue
				neighbor, resolved := pr.resolve_neighbor(edge, key.target_type, key.target_id, req.direction)
				if resolved do next[Edge_Entity_Key{target_type = neighbor.target_type, target_id = neighbor.target_id}] += share
			}
		}
		for key, weight in personalization do next[key] += GRAPH_RANK_DAMPING * dangling * weight
		delta := 0.0
		for key in keys {
			difference := next[key] - rank[key]
			if difference < 0 do difference = -difference
			delta += difference
		}
		rank, next = next, rank
		if delta < GRAPH_RANK_TOLERANCE do break
	}
	max_score := 0.0
	for key in keys do max_score = max(max_score, rank[key])
	if max_score > 0 {
		for key in keys do rank[key] = rank[key] / max_score * f64(req.anchor_count)
	}
	delete(keys)
	delete(personalization)
	delete(next)
	delete(degree_by_key)
	return rank
}

handle_graph_rank :: proc(c: ^NRC_Connection, req: pr.GraphRankRequest) {
	ws := get_connection_workspace(c)
	conv := get_conversation(ws, req.conv_id) if ws != nil else nil
	if conv == nil ||
	   req.max_depth < 1 ||
	   req.max_depth > pr.MAX_GRAPH_RANK_DEPTH ||
	   u8(req.direction) > 2 ||
	   req.top_n == 0 ||
	   int(req.top_n) > pr.MAX_GRAPH_RANK_CANDIDATES {
		send_graph_rank_result(c, req.conv_id, false, nil, nil, req.correlation_id)
		return
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		send_graph_rank_result(c, req.conv_id, false, nil, nil, req.correlation_id)
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	union_nodes := make(map[Edge_Entity_Key]bool, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
	union_edges := make(map[pr.EdgeID]bool, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
	paths := make(map[Edge_Entity_Key]Graph_Rank_Path_List, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
	ordered_adjacency := make(Graph_Rank_Ordered_Adjacency, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
	truncated := false
	for i := 0; i < int(req.anchor_count); i += 1 do truncated = graph_rank_collect_anchor(conv, req, i, &union_nodes, &union_edges, &paths, &ordered_adjacency, alloc) || truncated
	ranks := graph_rank_scores(conv, req, union_nodes, union_edges, alloc)

	requested := make(map[Edge_Entity_Key]bool, int(req.candidate_count), allocator = alloc)
	entries := make([dynamic]pr.GraphRankEntry, 0, int(req.candidate_count) + int(req.top_n), allocator = alloc)
	for i := 0; i < int(req.candidate_count); i += 1 {
		key := graph_rank_key(req.candidates[i])
		requested[key] = true
		append(&entries, pr.GraphRankEntry{target_type = key.target_type, target_id = key.target_id, score = ranks[key], paths = paths[key][:]})
	}
	graph_entries := make([dynamic]pr.GraphRankEntry, 0, len(union_nodes), allocator = alloc)
	for key in union_nodes {
		if key in requested do continue
		append(&graph_entries, pr.GraphRankEntry{target_type = key.target_type, target_id = key.target_id, score = ranks[key], paths = paths[key][:]})
	}
	slice.sort_by(graph_entries[:], graph_rank_entry_less)
	graph_count := min(len(graph_entries), int(req.top_n))
	append(&entries, ..graph_entries[:graph_count])

	used_edges := make(map[pr.EdgeID]bool, len(entries) * pr.MAX_GRAPH_RANK_DEPTH, allocator = alloc)
	for entry in entries do for path in entry.paths do for edge_id in path.edge_ids do used_edges[edge_id] = true
	edges := make([dynamic]pr.GraphRankEdge, 0, len(used_edges), allocator = alloc)
	for edge_id in used_edges {
		if edge := conv.edges[edge_id]; edge != nil {
			append(
				&edges,
				pr.GraphRankEdge {
					edge_id = edge.edge_id,
					source_type = edge.source_type,
					source_id = edge.source_id,
					target_type = edge.target_type,
					target_id = edge.target_id,
					relation = edge.relation,
				},
			)
		}
	}
	slice.sort_by(edges[:], proc(a, b: pr.GraphRankEdge) -> bool {return a.edge_id < b.edge_id})
	send_graph_rank_result(c, req.conv_id, truncated, entries[:], edges[:], req.correlation_id)
}

send_graph_rank_result :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	truncated: bool,
	entries: []pr.GraphRankEntry,
	edges: []pr.GraphRankEdge,
	correlation_id: u32,
) {
	msg := pr.GraphRankResultMessage {
		conv_id        = conv_id,
		truncated      = truncated,
		entries        = entries if entries != nil else []pr.GraphRankEntry{},
		edges          = edges if edges != nil else []pr.GraphRankEdge{},
		correlation_id = correlation_id,
	}
	protocol_size := pr.getSizeGraphRankResult(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "graph rank result")
	if buf == nil do return
	protocol_len := pr.serializeGraphRankResult(msg, buf[header_len:])
	if protocol_len > 0 {
		_ = send_pooled_buffer(c, buf[:header_len + protocol_len])
	} else {
		byte_pool.release(td.spool, buf)
	}
}
