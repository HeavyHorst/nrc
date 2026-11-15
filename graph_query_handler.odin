package main

import pr "protocol"

// Shared bounds and ordering for the SQLite graph readers.
MAX_RESULT_NODES :: 500
MAX_SHORTESTPATH_VISITED :: 2000

graph_query_node_less :: proc(a, b: pr.GraphQueryNode) -> bool {
	if a.depth != b.depth do return a.depth < b.depth
	if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
	return a.target_id < b.target_id
}

normalize_graph_degree_top_n :: proc(top_n: u16) -> u16 {
	if top_n == 0 || top_n > 100 do return 100
	return top_n
}
