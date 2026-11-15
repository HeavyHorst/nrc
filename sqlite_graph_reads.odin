package main

import "core:c"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_graph_degree :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseGraphDegreeRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	s: ^sql.Statement
	rc := sql.prepare_v2(
		store.db,
		`SELECT kind,id,count(*) AS degree FROM (
 SELECT source_type AS kind,source_id AS id FROM edges WHERE workspace=?1 AND (?2=0 OR (?2 & (1 << (relation-1)))!=0)
 UNION ALL SELECT target_type,target_id FROM edges WHERE workspace=?1 AND (?2=0 OR (?2 & (1 << (relation-1)))!=0))
 WHERE (?3!=1 OR kind=?4) AND (?3!=2 OR kind=?5)
 GROUP BY kind,id ORDER BY degree DESC,kind,id LIMIT ?6`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	for value, i in ([5]i64{i64(req.relation_mask), i64(req.type_filter), i64(pr.TargetType.Asset), i64(pr.TargetType.Task), i64(normalize_graph_degree_top_n(req.top_n))}) {
		if rc = sql.bind_int64(s, c.int(i + 2), value); rc != sql.OK do return rc
	}
	entries: [100]pr.GraphDegreeEntry
	count := 0
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		degree := sql.column_int64(s, 2)
		// The wire field is u16. Refuse overflow instead of inventing a low rank.
		if degree > i64(max(u16)) do return sql.TOOBIG
		id, id_rc := sql.column_id(s, 1); if id_rc != sql.OK do return id_rc
		entries[count] = {
			target_type = pr.TargetType(sql.column_int64(s, 0)),
			target_id   = id,
			degree      = u16(degree),
		}
		count += 1
	}
	msg := pr.GraphDegreeResultMessage {
		entries        = entries[:count],
		correlation_id = req.correlation_id,
	}
	buf, frame_rc := db.command_frame(output, pr.getSizeGraphDegreeResult(msg)); if frame_rc != sql.OK do return frame_rc
	return pr.serializeGraphDegreeResult(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_graph_common :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseGraphCommonNeighborsRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	msg := pr.GraphCommonNeighborsResultMessage {
		a_type         = req.a_type,
		a_id           = req.a_id,
		b_type         = req.b_type,
		b_id           = req.b_id,
		correlation_id = req.correlation_id,
	}
	if u8(req.direction) > 2 {
		buf, rc := db.command_frame(output, pr.getSizeGraphCommonNeighborsResult(msg)); if rc != sql.OK do return rc
		return pr.serializeGraphCommonNeighborsResult(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	defer sql.exec(store.db, "DROP TABLE IF EXISTS temp.nrc_neighbors; DROP TABLE IF EXISTS temp.nrc_common", nil, nil, nil)
	rc := sql.exec(
		store.db,
		`CREATE TEMP TABLE nrc_neighbors(side INTEGER,edge BLOB,kind INTEGER,id BLOB,PRIMARY KEY(side,edge)) WITHOUT ROWID;
 CREATE INDEX temp.nrc_neighbors_entity ON nrc_neighbors(side,kind,id);
 CREATE TEMP TABLE nrc_common(kind INTEGER,id BLOB,PRIMARY KEY(kind,id)) WITHOUT ROWID;`,
		nil,
		nil,
		nil,
	)
	if rc != sql.OK do return rc
	neighbors: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`INSERT INTO temp.nrc_neighbors
 SELECT ?7,id,target_type,target_id FROM edges INDEXED BY edges_source
 WHERE workspace=?1 AND source_type=?2 AND source_id=?3 AND ?4!=2 AND (?5=0 OR (?5 & (1 << (relation-1)))!=0)
 UNION ALL SELECT ?7,id,source_type,source_id FROM edges INDEXED BY edges_target
 WHERE workspace=?1 AND target_type=?2 AND target_id=?3 AND ?4!=1 AND (?5=0 OR (?5 & (1 << (relation-1)))!=0)
 AND NOT(source_type=?2 AND source_id=?3)`,
		-1,
		&neighbors,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(neighbors)
	if rc = sql.bind_bytes(neighbors, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_int64(neighbors, 4, i64(req.direction)); rc != sql.OK do return rc
	if rc = sql.bind_int64(neighbors, 5, i64(req.relation_mask)); rc != sql.OK do return rc
	for endpoint, i in ([2]pr.GraphPathNode{{req.a_type, req.a_id}, {req.b_type, req.b_id}}) {
		if rc = sql.bind_int64(neighbors, 2, i64(endpoint.target_type)); rc != sql.OK do return rc
		if rc = sql.bind_id(neighbors, 3, endpoint.target_id); rc != sql.OK do return rc
		if rc = sql.bind_int64(neighbors, 7, i64(i)); rc != sql.OK do return rc
		if rc = sql.step(neighbors); rc != sql.DONE do return rc
		if rc = sql.reset(neighbors); rc != sql.OK do return rc
	}
	common: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`INSERT INTO temp.nrc_common
 SELECT a.kind,a.id FROM temp.nrc_neighbors a INDEXED BY nrc_neighbors_entity
 WHERE a.side=0 AND NOT(a.kind=?1 AND a.id=?2)
 AND EXISTS(SELECT 1 FROM temp.nrc_neighbors b INDEXED BY nrc_neighbors_entity WHERE b.side=1 AND b.kind=a.kind AND b.id=a.id)
 GROUP BY a.kind,a.id`,
		-1,
		&common,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(common)
	if rc = sql.bind_int64(common, 1, i64(req.b_type)); rc != sql.OK do return rc
	if rc = sql.bind_id(common, 2, req.b_id); rc != sql.OK do return rc
	if rc = sql.step(common); rc != sql.DONE do return rc
	nodes := make([dynamic]pr.GraphPathNode); defer delete(nodes)
	edges := make([dynamic]pr.Edge)
	defer {for edge in edges do delete(edge.created_by); delete(edges)}
	size := pr.getSizeGraphCommonNeighborsResult(msg)
	budget := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	rows: ^sql.Statement
	rc = sql.prepare_v2(store.db, "SELECT kind,id FROM temp.nrc_common ORDER BY kind,id", -1, &rows, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(rows)
	for {
		rc = sql.step(rows); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if size + 10 > budget || len(nodes) == 65535 do return sql.TOOBIG
		id, id_rc := sql.column_id(rows, 1); if id_rc != sql.OK do return id_rc
		append(&nodes, pr.GraphPathNode{pr.TargetType(sql.column_int64(rows, 0)), id}); size += 10
	}
	edge_rows: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT e.id,e.source_type,e.source_id,e.target_type,e.target_id,e.relation,e.created_at,e.created_by
 FROM (SELECT DISTINCT n.edge FROM temp.nrc_neighbors n
 INNER JOIN temp.nrc_common c ON c.kind=n.kind AND c.id=n.id) selected
 CROSS JOIN edges e ON e.workspace=?1 AND e.id=selected.edge ORDER BY e.id`,
		-1,
		&edge_rows,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(edge_rows)
	if rc = sql.bind_bytes(edge_rows, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	for {
		rc = sql.step(edge_rows); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		edge, edge_rc := sqlite_edge_row(edge_rows); if edge_rc != sql.OK do return edge_rc
		if size + pr.getSizeEdge(edge) > budget || len(edges) == 65535 do return sql.TOOBIG
		edge.created_by = transmute([]byte)strings.clone(string(edge.created_by))
		append(&edges, edge); size += pr.getSizeEdge(edge)
	}
	msg.nodes = nodes[:]; msg.edges = edges[:]
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	return pr.serializeGraphCommonNeighborsResult(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
