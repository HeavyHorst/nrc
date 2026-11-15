package main

import pr "protocol"

// Shared ranking contract used by the SQLite graph implementation.
MAX_GRAPH_RANK_UNION_NODES :: MAX_RESULT_NODES * pr.MAX_GRAPH_RANK_ANCHORS
GRAPH_RANK_DAMPING :: 0.85
GRAPH_RANK_ITERATIONS :: 20
GRAPH_RANK_TOLERANCE :: 1e-10

Graph_Rank_Path_List :: [dynamic]pr.GraphRankPath

graph_rank_key :: proc(entity: pr.GraphEntityKey) -> Edge_Entity_Key {
	return {target_type = entity.target_type, target_id = entity.target_id}
}

graph_rank_entry_less :: proc(a, b: pr.GraphRankEntry) -> bool {
	if a.score != b.score do return a.score > b.score
	if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
	return a.target_id < b.target_id
}
