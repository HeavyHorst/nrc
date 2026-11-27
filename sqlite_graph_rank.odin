package main

import "core:c"
import "core:mem"
import "core:slice"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Called inside the traversal's scoped arena. Node vectors are bounded by five
// 500-node searches; the potentially much larger arc set remains in SQLite.
sqlite_graph_rank :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output, backing: mem.Allocator) -> c.int {
	req, err := pr.parseGraphRankRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	msg := pr.GraphRankResultMessage {
		correlation_id = req.correlation_id,
	}
	if req.max_depth < 1 ||
	   req.max_depth > pr.MAX_GRAPH_RANK_DEPTH ||
	   u8(req.direction) > 2 ||
	   req.top_n == 0 ||
	   int(req.top_n) > pr.MAX_GRAPH_RANK_CANDIDATES {
		context.allocator = backing
		buf, rc := db.command_frame(output, pr.getSizeGraphRankResult(msg)); if rc != sql.OK do return rc
		return pr.serializeGraphRankResult(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	paths := make(map[Edge_Entity_Key]Graph_Rank_Path_List, MAX_GRAPH_RANK_UNION_NODES)
	keys := make([dynamic]Edge_Entity_Key, 0, MAX_GRAPH_RANK_UNION_NODES)
	indices := make(map[Edge_Entity_Key]int, MAX_GRAPH_RANK_UNION_NODES)
	edge_rows_left := SQLITE_GRAPH_EDGE_SCAN_LIMIT
	for anchor in 0 ..< int(req.anchor_count) {
		visits, truncated, rc := sqlite_graph_walk(
			store,
			request.workspace,
			graph_rank_key(req.anchors[anchor]),
			req.direction,
			req.relation_mask,
			req.max_depth,
			MAX_RESULT_NODES,
			&edge_rows_left,
		)
		if rc != sql.OK do return rc
		msg.truncated = msg.truncated || truncated
		for v, i in visits {
			if v.key not_in indices {indices[v.key] = len(keys); append(&keys, v.key)}
			if i == 0 do continue
			edges := make([]pr.EdgeID, int(v.depth))
			at := i
			for j := len(edges) - 1; j >= 0; j -= 1 {edges[j] = visits[at].edge; at = visits[at].parent}
			list, ok := paths[v.key]
			if !ok do list = make(Graph_Rank_Path_List, 0, int(req.anchor_count))
			append(&list, pr.GraphRankPath{anchor_index = u8(anchor), depth = v.depth, edge_ids = edges}); paths[v.key] = list
		}
	}
	slice.sort_by(keys[:], proc(a, b: Edge_Entity_Key) -> bool {if a.target_type != b.target_type do return a.target_type < b.target_type; return a.target_id < b.target_id})
	for key, i in keys do indices[key] = i
	defer sql.exec(store.db, "DROP TABLE IF EXISTS temp.nrc_rank_arcs", nil, nil, nil)
	rc := sql.exec(
		store.db,
		"CREATE TEMP TABLE nrc_rank_arcs(source_type INTEGER,source BLOB,target_type INTEGER,target BLOB,edge BLOB, PRIMARY KEY(source_type,source,edge)) WITHOUT ROWID",
		nil,
		nil,
		nil,
	)
	if rc != sql.OK do return rc
	arcs: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`INSERT INTO temp.nrc_rank_arcs
 SELECT e.source_type,e.source_id,e.target_type,e.target_id,e.id FROM temp.nrc_graph_edges g CROSS JOIN edges e ON e.workspace=?1 AND e.id=g.id WHERE ?2!=2
 UNION ALL SELECT e.target_type,e.target_id,e.source_type,e.source_id,e.id FROM temp.nrc_graph_edges g CROSS JOIN edges e ON e.workspace=?1 AND e.id=g.id
 WHERE ?2!=1 AND NOT(e.source_type=e.target_type AND e.source_id=e.target_id)`,
		-1,
		&arcs,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(arcs)
	if rc = sql.bind_bytes(arcs, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_int64(arcs, 2, i64(req.direction)); rc != sql.OK do return rc
	if rc = sql.step(arcs); rc != sql.DONE do return rc
	degree := make([]i64, len(keys))
	counts: ^sql.Statement
	rc = sql.prepare_v2(store.db, "SELECT source_type,source,count(*) FROM temp.nrc_rank_arcs GROUP BY source_type,source", -1, &counts, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(counts)
	for {
		rc = sql.step(counts); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(counts, 1); if id_rc != sql.OK do return id_rc
		degree[indices[Edge_Entity_Key{pr.TargetType(sql.column_int64(counts, 0)), id}]] = sql.column_int64(counts, 2)
	}
	personalization := make([]f64, len(keys)); rank := make([]f64, len(keys)); next := make([]f64, len(keys))
	weight_sum := 0.0
	for i in 0 ..< int(req.anchor_count) {
		weight := 1.0 / f64(i + 1); personalization[indices[graph_rank_key(req.anchors[i])]] = weight; weight_sum += weight
	}
	for &weight in personalization do weight /= weight_sum
	copy(rank, personalization)
	rows: ^sql.Statement
	rc = sql.prepare_v2(store.db, "SELECT source_type,source,target_type,target FROM temp.nrc_rank_arcs ORDER BY source_type,source,edge", -1, &rows, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(rows)
	any_edges := false
	for d in degree do if d > 0 {any_edges = true; break}
	if any_edges {
		for _ in 0 ..< GRAPH_RANK_ITERATIONS {
			for weight, i in personalization do next[i] = (1.0 - GRAPH_RANK_DAMPING) * weight
			dangling := 0.0
			for d, i in degree do if d == 0 do dangling += rank[i]
			for {
				rc = sql.step(rows); if rc == sql.DONE do break
				if rc != sql.ROW do return rc
				source, source_rc := sql.column_id(rows, 1); if source_rc != sql.OK do return source_rc
				target, target_rc := sql.column_id(rows, 3); if target_rc != sql.OK do return target_rc
				i := indices[Edge_Entity_Key{pr.TargetType(sql.column_int64(rows, 0)), source}]
				j := indices[Edge_Entity_Key{pr.TargetType(sql.column_int64(rows, 2)), target}]
				next[j] += GRAPH_RANK_DAMPING * rank[i] / f64(degree[i])
			}
			if rc = sql.reset(rows); rc != sql.OK do return rc
			for weight, i in personalization do next[i] += GRAPH_RANK_DAMPING * dangling * weight
			delta := 0.0
			for value, i in next {diff := value - rank[i]; if diff < 0 do diff = -diff; delta += diff}
			rank, next = next, rank
			if delta < GRAPH_RANK_TOLERANCE do break
		}
		maximum := 0.0; for value in rank do maximum = max(maximum, value)
		if maximum > 0 do for &value in rank do value = value / maximum * f64(req.anchor_count)
	} else {for &value in rank do value = 0}
	entries := make([dynamic]pr.GraphRankEntry)
	requested := make(map[Edge_Entity_Key]bool, int(req.candidate_count))
	for i in 0 ..< int(req.candidate_count) {
		key := graph_rank_key(req.candidates[i]); requested[key] = true
		score := 0.0; if index, ok := indices[key]; ok do score = rank[index]
		list, _ := paths[key]
		append(&entries, pr.GraphRankEntry{target_type = key.target_type, target_id = key.target_id, score = score, paths = list[:]})
	}
	others := make([dynamic]pr.GraphRankEntry, 0, len(keys))
	for key, i in keys {
		if key in requested do continue
		list, _ := paths[key]
		append(&others, pr.GraphRankEntry{target_type = key.target_type, target_id = key.target_id, score = rank[i], paths = list[:]})
	}
	slice.sort_by(others[:], graph_rank_entry_less)
	append(&entries, ..others[:min(len(others), int(req.top_n))])
	used := make(map[pr.EdgeID]bool)
	edges := make([dynamic]pr.GraphRankEdge)
	for entry in entries do for path in entry.paths do for id in path.edge_ids {
		if id in used do continue
		used[id] = true
		e, edge_rc := sqlite_graph_read_edge(store, request.workspace, id, copy_creator = false); if edge_rc != sql.OK do return edge_rc
		append(&edges, pr.GraphRankEdge{e.edge_id, e.source_type, e.source_id, e.target_type, e.target_id, e.relation})
	}
	slice.sort_by(edges[:], proc(a, b: pr.GraphRankEdge) -> bool {return a.edge_id < b.edge_id})
	msg.entries = entries[:]; msg.edges = edges[:]
	size := pr.getSizeGraphRankResult(msg)
	if size > pr.MAX_PROTOCOL_PAYLOAD_SIZE do return sql.TOOBIG
	context.allocator = backing
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	return pr.serializeGraphRankResult(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
