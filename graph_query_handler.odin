package main

import "core:log"
import "core:mem/virtual"
import "core:slice"

import "byte_pool"
import pr "protocol"

MAX_RESULT_NODES :: 500
MAX_SHORTESTPATH_VISITED :: 2000

graph_query_node_less :: proc(a, b: pr.GraphQueryNode) -> bool {
	if a.depth != b.depth do return a.depth < b.depth
	if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
	return a.target_id < b.target_id
}

graph_path_node_less :: proc(a, b: pr.GraphPathNode) -> bool {
	if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
	return a.target_id < b.target_id
}

graph_edge_less :: proc(a, b: pr.Edge) -> bool {
	return a.edge_id < b.edge_id
}

graph_degree_entry_less :: proc(a, b: pr.GraphDegreeEntry) -> bool {
	if a.degree != b.degree do return a.degree > b.degree
	if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
	return a.target_id < b.target_id
}

// ============================================================================
// BFS Neighborhood (C_GraphQuery = 44)
// ============================================================================

collect_graph_query :: proc(
	conv: ^Conversation_State,
	req: pr.GraphQueryRequest,
	allocator := context.allocator,
) -> (
	nodes: [dynamic]pr.GraphQueryNode,
	edges: [dynamic]pr.Edge,
	truncated: bool,
) {
	start_key := Edge_Entity_Key {
		target_type = req.start_type,
		target_id   = req.start_id,
	}

	BFS_Entry :: struct {
		key:   Edge_Entity_Key,
		depth: u8,
	}

	visited := make(map[Edge_Entity_Key]u8, MAX_RESULT_NODES, allocator = allocator)
	defer delete(visited)
	queue := make([dynamic]BFS_Entry, 0, MAX_RESULT_NODES, allocator = allocator)
	defer delete(queue)
	result_edges := make(map[pr.EdgeID]bool, MAX_RESULT_NODES, allocator = allocator)
	defer delete(result_edges)

	visited[start_key] = 0
	append(&queue, BFS_Entry{start_key, 0})

	qi := 0
	bfs_outer: for qi < len(queue) {
		entry := queue[qi]
		qi += 1

		if entry.depth >= req.max_depth {
			continue
		}

		edge_ids, ok := conv.edges_by_entity[entry.key]
		if !ok {
			continue
		}

		for edge_id in edge_ids {
			edge := conv.edges[edge_id]
			if edge == nil do continue

			if !pr.relation_matches_mask(edge.relation, req.relation_mask) do continue

			neighbor, resolved := pr.resolve_neighbor(edge, entry.key.target_type, entry.key.target_id, pr.Direction(req.direction))
			if !resolved do continue

			neighbor_key := Edge_Entity_Key {
				target_type = neighbor.target_type,
				target_id   = neighbor.target_id,
			}

			if neighbor_key not_in visited {
				if len(visited) >= MAX_RESULT_NODES {
					truncated = true
					break bfs_outer
				}
				visited[neighbor_key] = entry.depth + 1
				append(&queue, BFS_Entry{neighbor_key, entry.depth + 1})
			}

			if neighbor_key in visited {
				result_edges[edge_id] = true
			}
		}
	}

	nodes = make([dynamic]pr.GraphQueryNode, 0, len(visited), allocator = allocator)
	for key, depth in visited {
		append(&nodes, pr.GraphQueryNode{target_type = key.target_type, target_id = key.target_id, depth = depth})
	}
	slice.sort_by(nodes[:], graph_query_node_less)

	edges = make([dynamic]pr.Edge, 0, len(result_edges), allocator = allocator)
	for edge_id in result_edges {
		if edge := conv.edges[edge_id]; edge != nil {
			append(&edges, edge^)
		}
	}
	slice.sort_by(edges[:], graph_edge_less)
	return
}

handle_graph_query :: proc(c: ^NRC_Connection, req: pr.GraphQueryRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_graph_query_result(c, req.conv_id, req.start_type, req.start_id, false, nil, nil, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_graph_query_result(c, req.conv_id, req.start_type, req.start_id, false, nil, nil, req.correlation_id)
		return
	}

	if req.max_depth < 1 || req.max_depth > 4 {
		log.warnf("[T%d] GraphQuery invalid max_depth %d", td.thread_index, req.max_depth)
		send_graph_query_result(c, req.conv_id, req.start_type, req.start_id, false, nil, nil, req.correlation_id)
		return
	}

	if u8(req.direction) > 2 {
		log.warnf("[T%d] GraphQuery invalid direction %d", td.thread_index, req.direction)
		send_graph_query_result(c, req.conv_id, req.start_type, req.start_id, false, nil, nil, req.correlation_id)
		return
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		send_graph_query_result(c, req.conv_id, req.start_type, req.start_id, false, nil, nil, req.correlation_id)
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	nodes, edges, truncated := collect_graph_query(conv, req, alloc)

	send_graph_query_result(c, req.conv_id, req.start_type, req.start_id, truncated, nodes[:], edges[:], req.correlation_id)
}

// ============================================================================
// Shortest Path (C_GraphShortestPath = 45)
// ============================================================================

handle_shortest_path :: proc(c: ^NRC_Connection, req: pr.GraphShortestPathRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_shortest_path_not_found(c, req)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_shortest_path_not_found(c, req)
		return
	}

	if req.max_depth < 1 || req.max_depth > 4 {
		log.warnf("[T%d] ShortestPath invalid max_depth %d", td.thread_index, req.max_depth)
		send_shortest_path_not_found(c, req)
		return
	}

	if u8(req.direction) > 2 {
		log.warnf("[T%d] ShortestPath invalid direction %d", td.thread_index, req.direction)
		send_shortest_path_not_found(c, req)
		return
	}

	from_key := Edge_Entity_Key {
		target_type = req.from_type,
		target_id   = req.from_id,
	}
	to_key := Edge_Entity_Key {
		target_type = req.to_type,
		target_id   = req.to_id,
	}

	if from_key == to_key {
		path_nodes := [1]pr.GraphPathNode{{target_type = req.from_type, target_id = req.from_id}}
		send_shortest_path_result(c, req, true, 0, path_nodes[:], nil, req.correlation_id)
		return
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		send_shortest_path_not_found(c, req)
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	parent := make(map[Edge_Entity_Key]Edge_Entity_Key, MAX_SHORTESTPATH_VISITED, allocator = alloc)
	parent_edge := make(map[Edge_Entity_Key]pr.EdgeID, MAX_SHORTESTPATH_VISITED, allocator = alloc)
	depth_tracker := make(map[Edge_Entity_Key]u8, MAX_SHORTESTPATH_VISITED, allocator = alloc)
	queue := make([dynamic]Edge_Entity_Key, 0, MAX_SHORTESTPATH_VISITED, allocator = alloc)

	parent[from_key] = from_key
	depth_tracker[from_key] = 0
	append(&queue, from_key)

	found := false
	qi := 0

	sp_outer: for qi < len(queue) {
		node := queue[qi]
		qi += 1
		depth := depth_tracker[node]

		if depth >= req.max_depth {
			continue
		}

		edge_ids, ok := conv.edges_by_entity[node]
		if !ok {
			continue
		}

		for edge_id in edge_ids {
			edge := conv.edges[edge_id]
			if edge == nil do continue

			if !pr.relation_matches_mask(edge.relation, req.relation_mask) do continue

			neighbor, resolved := pr.resolve_neighbor(edge, node.target_type, node.target_id, pr.Direction(req.direction))
			if !resolved do continue

			neighbor_key := Edge_Entity_Key {
				target_type = neighbor.target_type,
				target_id   = neighbor.target_id,
			}

			if neighbor_key not_in parent {
				if len(parent) >= MAX_SHORTESTPATH_VISITED {
					break sp_outer
				}
				parent[neighbor_key] = node
				parent_edge[neighbor_key] = edge_id
				depth_tracker[neighbor_key] = depth + 1

				if neighbor_key == to_key {
					found = true
					break sp_outer
				}

				append(&queue, neighbor_key)
			}
		}
	}

	if !found {
		send_shortest_path_not_found(c, req)
		return
	}

	path_nodes := make([dynamic]pr.GraphPathNode, 0, 8, allocator = alloc)
	path_edge_ids := make([dynamic]pr.EdgeID, 0, 8, allocator = alloc)

	cur := to_key
	for cur != from_key {
		append(&path_nodes, pr.GraphPathNode{target_type = cur.target_type, target_id = cur.target_id})
		append(&path_edge_ids, parent_edge[cur])
		cur = parent[cur]
	}
	append(&path_nodes, pr.GraphPathNode{target_type = from_key.target_type, target_id = from_key.target_id})

	slice.reverse(path_nodes[:])
	slice.reverse(path_edge_ids[:])

	path_edges := make([dynamic]pr.Edge, 0, len(path_edge_ids), allocator = alloc)
	for eid in path_edge_ids {
		if edge := conv.edges[eid]; edge != nil {
			append(&path_edges, edge^)
		}
	}

	send_shortest_path_result(c, req, true, u8(len(path_edge_ids)), path_nodes[:], path_edges[:], req.correlation_id)
}

// ============================================================================
// Degree Query (C_GraphDegree = 46)
// ============================================================================

normalize_graph_degree_top_n :: proc(top_n: u16) -> u16 {
	if top_n == 0 || top_n > 100 do return 100
	return top_n
}

handle_degree_query :: proc(c: ^NRC_Connection, req: pr.GraphDegreeRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_degree_result(c, req.conv_id, nil, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_degree_result(c, req.conv_id, nil, req.correlation_id)
		return
	}

	top_n := normalize_graph_degree_top_n(req.top_n)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		send_degree_result(c, req.conv_id, nil, req.correlation_id)
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	results := make([dynamic]pr.GraphDegreeEntry, 0, 64, allocator = alloc)

	for key, edge_ids in conv.edges_by_entity {
		if req.type_filter == 1 && key.target_type != .Asset do continue
		if req.type_filter == 2 && key.target_type != .Task do continue

		degree: u16 = 0
		for edge_id in edge_ids {
			edge := conv.edges[edge_id]
			if edge == nil do continue
			if pr.relation_matches_mask(edge.relation, req.relation_mask) {
				degree += 1
			}
		}

		if degree > 0 {
			append(&results, pr.GraphDegreeEntry{target_type = key.target_type, target_id = key.target_id, degree = degree})
		}
	}

	slice.sort_by(results[:], graph_degree_entry_less)

	count := min(len(results), int(top_n))
	send_degree_result(c, req.conv_id, results[:count], req.correlation_id)
}

// ============================================================================
// Common Neighbors (C_GraphCommonNeighbors = 47)
// ============================================================================

handle_common_neighbors :: proc(c: ^NRC_Connection, req: pr.GraphCommonNeighborsRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_common_neighbors_result(c, req, nil, nil)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_common_neighbors_result(c, req, nil, nil)
		return
	}

	if u8(req.direction) > 2 {
		log.warnf("[T%d] CommonNeighbors invalid direction %d", td.thread_index, req.direction)
		send_common_neighbors_result(c, req, nil, nil)
		return
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		send_common_neighbors_result(c, req, nil, nil)
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	a_key := Edge_Entity_Key {
		target_type = req.a_type,
		target_id   = req.a_id,
	}
	b_key := Edge_Entity_Key {
		target_type = req.b_type,
		target_id   = req.b_id,
	}

	a_neighbors := make(map[Edge_Entity_Key]bool, MAX_RESULT_NODES, allocator = alloc)

	a_edge_ids, a_ok := conv.edges_by_entity[a_key]
	if a_ok {
		for edge_id in a_edge_ids {
			edge := conv.edges[edge_id]
			if edge == nil do continue
			if !pr.relation_matches_mask(edge.relation, req.relation_mask) do continue

			neighbor, resolved := pr.resolve_neighbor(edge, a_key.target_type, a_key.target_id, pr.Direction(req.direction))
			if !resolved do continue

			neighbor_key := Edge_Entity_Key {
				target_type = neighbor.target_type,
				target_id   = neighbor.target_id,
			}
			if neighbor_key != b_key {
				a_neighbors[neighbor_key] = true
			}
		}
	}

	common := make(map[Edge_Entity_Key]bool, MAX_RESULT_NODES, allocator = alloc)
	result_edge_ids := make(map[pr.EdgeID]bool, MAX_RESULT_NODES, allocator = alloc)

	b_edge_ids, b_ok := conv.edges_by_entity[b_key]
	if b_ok {
		for edge_id in b_edge_ids {
			edge := conv.edges[edge_id]
			if edge == nil do continue
			if !pr.relation_matches_mask(edge.relation, req.relation_mask) do continue

			neighbor, resolved := pr.resolve_neighbor(edge, b_key.target_type, b_key.target_id, pr.Direction(req.direction))
			if !resolved do continue

			neighbor_key := Edge_Entity_Key {
				target_type = neighbor.target_type,
				target_id   = neighbor.target_id,
			}
			if neighbor_key in a_neighbors {
				common[neighbor_key] = true
				result_edge_ids[edge_id] = true
			}
		}
	}

	if a_ok {
		for edge_id in a_edge_ids {
			edge := conv.edges[edge_id]
			if edge == nil do continue
			if !pr.relation_matches_mask(edge.relation, req.relation_mask) do continue

			neighbor, resolved := pr.resolve_neighbor(edge, a_key.target_type, a_key.target_id, pr.Direction(req.direction))
			if !resolved do continue

			neighbor_key := Edge_Entity_Key {
				target_type = neighbor.target_type,
				target_id   = neighbor.target_id,
			}
			if neighbor_key in common {
				result_edge_ids[edge_id] = true
			}
		}
	}

	nodes := make([dynamic]pr.GraphPathNode, 0, len(common), allocator = alloc)
	for key in common {
		append(&nodes, pr.GraphPathNode{target_type = key.target_type, target_id = key.target_id})
	}
	slice.sort_by(nodes[:], graph_path_node_less)

	edges := make([dynamic]pr.Edge, 0, len(result_edge_ids), allocator = alloc)
	for edge_id in result_edge_ids {
		if edge := conv.edges[edge_id]; edge != nil {
			append(&edges, edge^)
		}
	}
	slice.sort_by(edges[:], graph_edge_less)

	send_common_neighbors_result(c, req, nodes[:], edges[:])
}

// ============================================================================
// Response Senders
// ============================================================================

send_graph_query_result :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	start_type: pr.TargetType,
	start_id: u64,
	truncated: bool,
	nodes: []pr.GraphQueryNode,
	edges: []pr.Edge,
	correlation_id: u32 = 0,
) {
	msg := pr.GraphQueryResultMessage {
		conv_id        = conv_id,
		start_type     = start_type,
		start_id       = start_id,
		truncated      = truncated,
		nodes          = nodes if nodes != nil else []pr.GraphQueryNode{},
		edges          = edges if edges != nil else []pr.Edge{},
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeGraphQueryResult(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "graph query result")
	if buf == nil do return

	protocol_len := pr.serializeGraphQueryResult(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize GraphQueryResult for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_shortest_path_not_found :: proc(c: ^NRC_Connection, req: pr.GraphShortestPathRequest) {
	send_shortest_path_result(c, req, false, 0, nil, nil, req.correlation_id)
}

send_shortest_path_result :: proc(
	c: ^NRC_Connection,
	req: pr.GraphShortestPathRequest,
	found: bool,
	path_length: u8,
	nodes: []pr.GraphPathNode,
	edges: []pr.Edge,
	correlation_id: u32 = 0,
) {
	msg := pr.GraphShortestPathResultMessage {
		conv_id        = req.conv_id,
		from_type      = req.from_type,
		from_id        = req.from_id,
		to_type        = req.to_type,
		to_id          = req.to_id,
		found          = found,
		path_length    = path_length,
		nodes          = nodes if nodes != nil else []pr.GraphPathNode{},
		edges          = edges if edges != nil else []pr.Edge{},
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeGraphShortestPathResult(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "shortest path result")
	if buf == nil do return

	protocol_len := pr.serializeGraphShortestPathResult(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize ShortestPathResult for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_degree_result :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, entries: []pr.GraphDegreeEntry, correlation_id: u32 = 0) {
	msg := pr.GraphDegreeResultMessage {
		conv_id        = conv_id,
		entries        = entries if entries != nil else []pr.GraphDegreeEntry{},
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeGraphDegreeResult(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "degree result")
	if buf == nil do return

	protocol_len := pr.serializeGraphDegreeResult(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize DegreeResult for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_common_neighbors_result :: proc(c: ^NRC_Connection, req: pr.GraphCommonNeighborsRequest, nodes: []pr.GraphPathNode, edges: []pr.Edge) {
	msg := pr.GraphCommonNeighborsResultMessage {
		conv_id        = req.conv_id,
		a_type         = req.a_type,
		a_id           = req.a_id,
		b_type         = req.b_type,
		b_id           = req.b_id,
		nodes          = nodes if nodes != nil else []pr.GraphPathNode{},
		edges          = edges if edges != nil else []pr.Edge{},
		correlation_id = req.correlation_id,
	}

	protocol_size := pr.getSizeGraphCommonNeighborsResult(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "common neighbors result")
	if buf == nil do return

	protocol_len := pr.serializeGraphCommonNeighborsResult(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize CommonNeighborsResult for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}
