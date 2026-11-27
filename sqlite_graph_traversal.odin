package main

import "core:c"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

SQLite_Graph_Visit :: struct {
	key:    Edge_Entity_Key,
	depth:  u8,
	parent: int,
	edge:   pr.EdgeID,
}

// Count adjacency rows, not new nodes or distinct edges. GraphRank shares the
// budget between anchors, so the arc table is bounded even with repeated scans.
SQLITE_GRAPH_EDGE_SCAN_LIMIT :: 4096

sqlite_graph_walk :: proc(
	store: ^db.Store,
	workspace: string,
	start: Edge_Entity_Key,
	direction: pr.Direction,
	mask: u16,
	depth: u8,
	limit: int,
	edge_rows_left: ^int,
	stop: Edge_Entity_Key = {},
) -> (
	visits: [dynamic]SQLite_Graph_Visit,
	truncated: bool,
	rc: c.int,
) {
	visits = make([dynamic]SQLite_Graph_Visit, 0, limit)
	seen := make(map[Edge_Entity_Key]int, limit); defer delete(seen)
	append(&visits, SQLite_Graph_Visit{key = start, parent = -1}); seen[start] = 0
	if start == stop do return visits, false, sql.OK
	s: ^sql.Statement
	// Project the filter instead of putting it in WHERE: step must yield even
	// rejected adjacency rows so the caller can charge them to the budget.
	rc = sql.prepare_v2(
		store.db,
		`SELECT id,target_type,target_id,(?5=0 OR (?5 & (1 << (relation-1)))!=0) FROM edges INDEXED BY edges_source_page
 WHERE workspace=?1 AND source_type=?2 AND source_id=?3 AND ?4!=2
 UNION ALL SELECT id,source_type,source_id,(?5=0 OR (?5 & (1 << (relation-1)))!=0) AND NOT(source_type=?2 AND source_id=?3)
 FROM edges INDEXED BY edges_target_page WHERE workspace=?1 AND target_type=?2 AND target_id=?3 AND ?4!=1 ORDER BY id`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_int64(s, 4, i64(direction)); rc != sql.OK do return
	if rc = sql.bind_int64(s, 5, i64(mask)); rc != sql.OK do return
	insert: ^sql.Statement
	rc = sql.prepare_v2(store.db, "INSERT INTO temp.nrc_graph_edges VALUES(?1) ON CONFLICT DO NOTHING", -1, &insert, nil)
	if rc != sql.OK do return
	defer sql.finalize(insert)
	for index := 0; index < len(visits); index += 1 {
		current := visits[index]
		if current.depth >= depth do continue
		if rc = sql.bind_int64(s, 2, i64(current.key.target_type)); rc != sql.OK do return
		if rc = sql.bind_id(s, 3, current.key.target_id); rc != sql.OK do return
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return
			// Only reject on an extra row; an exact fit can still reach DONE.
			if edge_rows_left^ == 0 do return visits, false, sql.INTERRUPT
			edge_rows_left^ -= 1
			if sql.column_int64(s, 3) == 0 do continue
			edge: u64; id: u64
			edge, rc = sql.column_id(s, 0); if rc != sql.OK do return
			id, rc = sql.column_id(s, 2); if rc != sql.OK do return
			key := Edge_Entity_Key{pr.TargetType(sql.column_int64(s, 1)), id}
			if key not_in seen {
				if len(visits) == limit do return visits, true, sql.OK
				seen[key] = len(visits)
				append(&visits, SQLite_Graph_Visit{key = key, depth = current.depth + 1, parent = index, edge = edge})
				if key == stop do return visits, false, sql.OK
			}
			if rc = sql.bind_id(insert, 1, edge); rc != sql.OK do return
			if rc = sql.step(insert); rc != sql.DONE do return
			if rc = sql.reset(insert); rc != sql.OK do return
		}
		if rc = sql.reset(s); rc != sql.OK do return
	}
	return visits, false, sql.OK
}

// The caller owns an arena bounded by the output budget.
sqlite_graph_read_edge :: proc(store: ^db.Store, workspace: string, id: u64, copy_creator := true) -> (edge: pr.Edge, rc: c.int) {
	s: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		"SELECT id,source_type,source_id,target_type,target_id,relation,created_at,created_by FROM edges WHERE workspace=?1 AND id=?2",
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_id(s, 2, id); rc != sql.OK do return
	if rc = sql.step(s); rc != sql.ROW do return {}, rc == sql.DONE ? sql.CORRUPT : rc
	edge, rc = sqlite_edge_row(s)
	if rc == sql.OK do edge.created_by = copy_creator ? transmute([]byte)strings.clone(string(edge.created_by)) : nil
	return
}

sqlite_graph_traverse :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer sql.exec(store.db, "DROP TABLE IF EXISTS temp.nrc_graph_edges", nil, nil, nil)
	rc := sql.exec(store.db, "CREATE TEMP TABLE nrc_graph_edges(id BLOB PRIMARY KEY) WITHOUT ROWID", nil, nil, nil)
	if rc != sql.OK do return rc
	if request.opcode == .C_GraphRank do return sqlite_graph_rank(store, request, output, backing)
	shortest := request.opcode == .C_GraphShortestPath
	query: pr.GraphQueryRequest
	path: pr.GraphShortestPathRequest
	start, stop: Edge_Entity_Key
	direction: pr.Direction; depth: u8; mask: u16
	if shortest {
		err: pr.ProtocolParseError
		path, err = pr.parseGraphShortestPathRequest(request.body)
		if err != nil || path.conv_id != 0 do return sql.CONSTRAINT
		start = {
			path.from_type,
			path.from_id,
		}; stop = {path.to_type, path.to_id}; direction = path.direction; depth = path.max_depth; mask = path.relation_mask
	} else {
		err: pr.ProtocolParseError
		query, err = pr.parseGraphQueryRequest(request.body)
		if err != nil || query.conv_id != 0 do return sql.CONSTRAINT
		start = {query.start_type, query.start_id}; direction = query.direction; depth = query.max_depth; mask = query.relation_mask
	}
	visits: [dynamic]SQLite_Graph_Visit; truncated := false
	if depth >= 1 && depth <= 4 && u8(direction) <= 2 {
		edge_rows_left := SQLITE_GRAPH_EDGE_SCAN_LIMIT
		visits, truncated, rc = sqlite_graph_walk(
			store,
			request.workspace,
			start,
			direction,
			mask,
			depth,
			shortest ? MAX_SHORTESTPATH_VISITED : MAX_RESULT_NODES,
			&edge_rows_left,
			stop,
		)
		if rc != sql.OK do return rc
	}
	budget := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	edges := make([dynamic]pr.Edge)
	if shortest {
		msg := pr.GraphShortestPathResultMessage {
			from_type      = path.from_type,
			from_id        = path.from_id,
			to_type        = path.to_type,
			to_id          = path.to_id,
			correlation_id = path.correlation_id,
		}
		nodes := make([dynamic]pr.GraphPathNode)
		if len(visits) > 0 && visits[len(visits) - 1].key == stop {
			msg.found = true
			for i := len(visits) - 1; i >= 0; i = visits[i].parent {
				v := visits[i]; append(&nodes, pr.GraphPathNode{v.key.target_type, v.key.target_id})
				if v.parent < 0 do break
				e, edge_rc := sqlite_graph_read_edge(store, request.workspace, v.edge); if edge_rc != sql.OK do return edge_rc
				append(&edges, e)
			}
			slice.reverse(nodes[:]); slice.reverse(edges[:])
		}
		msg.nodes = nodes[:]; msg.edges = edges[:]; msg.path_length = u8(len(edges))
		size := pr.getSizeGraphShortestPathResult(msg); if size > budget do return sql.TOOBIG
		context.allocator = backing
		buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
		return pr.serializeGraphShortestPathResult(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	nodes := make([]pr.GraphQueryNode, len(visits))
	for v, i in visits do nodes[i] = {v.key.target_type, v.key.target_id, v.depth}
	slice.sort_by(nodes, graph_query_node_less)
	msg := pr.GraphQueryResultMessage {
		start_type     = query.start_type,
		start_id       = query.start_id,
		nodes          = nodes,
		truncated      = truncated,
		correlation_id = query.correlation_id,
	}
	size := pr.getSizeGraphQueryResult(msg)
	s: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT e.id,e.source_type,e.source_id,e.target_type,e.target_id,e.relation,e.created_at,e.created_by
 FROM temp.nrc_graph_edges g CROSS JOIN edges e ON e.workspace=?1 AND e.id=g.id ORDER BY g.id`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		e, edge_rc := sqlite_edge_row(s); if edge_rc != sql.OK do return edge_rc
		if size + pr.getSizeEdge(e) > budget do return sql.TOOBIG
		e.created_by = transmute([]byte)strings.clone(string(e.created_by)); append(&edges, e); size += pr.getSizeEdge(e)
	}
	msg.edges = edges[:]
	context.allocator = backing
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	return pr.serializeGraphQueryResult(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
