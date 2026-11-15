package main

// Public graph requests run through the dispatcher and SQLite worker.
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_graph_response :: proc(t: ^testing.T, c: ^NRC_Connection, request, expected: []byte) {
	process_protocol_payload(c, request); worker_db_test_pump(t)
	if !testing.expect_value(t, send_queue_len(c), 1) do return
	item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
	testing.expect_value(t, string(frame[offset:]), string(expected))
}

worker_db_test_graph_walks :: proc(t: ^testing.T, c: ^NRC_Connection, edges: []pr.Edge, store: ^db.Store) {
	buffer: [1024]byte; expected: [4096]byte
	query := pr.GraphQueryRequest {
		start_type     = .Asset,
		start_id       = 1,
		max_depth      = 2,
		correlation_id = 950,
	}
	msg := pr.GraphQueryResultMessage {
		start_type     = .Asset,
		start_id       = 1,
		correlation_id = 950,
		nodes          = {{.Asset, 1, 0}, {.Asset, 2, 1}, {.Task, 10, 1}, {.Task, 20, 1}, {.Task, max(u64), 1}},
		edges          = edges,
	}
	n := pr.serializeGraphQueryRequest(query, buffer[:]); size := pr.serializeGraphQueryResult(msg, expected[:])
	worker_db_test_graph_response(t, c, buffer[:n], expected[:size])
	path := pr.GraphShortestPathRequest {
		from_type      = .Task,
		from_id        = 20,
		to_type        = .Task,
		to_id          = 10,
		max_depth      = 2,
		direction      = .Outgoing,
		correlation_id = 951,
	}
	for mode in 0 ..< 4 {
		want := pr.GraphShortestPathResultMessage {
			from_type      = path.from_type,
			from_id        = path.from_id,
			to_type        = path.to_type,
			to_id          = path.to_id,
			correlation_id = 951,
		}
		if mode == 0 {want.found = true; want.path_length = 2; want.nodes = {{.Task, 20}, {.Asset, 1}, {.Task, 10}}; want.edges = {edges[3], edges[0]}}
		if mode == 1 {path.max_depth = 1}
		if mode == 2 {path.max_depth = 4; path.direction = .Incoming}
		if mode == 3 {path.to_id = 20; want.to_id = 20; want.found = true; want.nodes = {{.Task, 20}}}
		n = pr.serializeGraphShortestPathRequest(path, buffer[:]); size = pr.serializeGraphShortestPathResult(want, expected[:])
		worker_db_test_graph_response(t, c, buffer[:n], expected[:size])
	}
	// An independent, bounded edge-list model lives only in test code.
	rank := pr.GraphRankRequest {
		anchor_count    = 2,
		candidate_count = 2,
		max_depth       = 3,
		top_n           = 5,
		correlation_id  = 952,
	}
	rank.anchors[0] = {.Asset, 1}; rank.anchors[1] = {.Task, 20}
	rank.candidates[0] = {.Task, max(u64)}; rank.candidates[1] = {.Asset, 999}
	for mode in 0 ..< 4 {
		rank.direction = pr.Direction(mode % 3)
		if mode == 3 {rank.anchor_count = 1; rank.anchors[0] = {.Asset, 999}}
		n = pr.serializeGraphRankRequest(rank, buffer[:])
		size = graph_rank_test_reference(rank, edges, expected[:])
		worker_db_test_graph_response(t, c, buffer[:n], expected[:size])
	}
	rank.anchors[0] = {.Asset, 1}; rank.direction = .Both
	n = pr.serializeGraphRankRequest(rank, buffer[:])
	request := db.Request {
		workspace = c.workspace_id,
		opcode    = .C_GraphRank,
		body      = buffer[2:n],
	}
	for budget in ([2]int{1, 4096}) {
		output := db.Command_Output {
			limit = budget,
		}; defer db.destroy_command_output(&output)
		testing.expect_value(t, db.begin(store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(store, &request, &output), budget == 1 ? sql.TOOBIG : sql.OK)
		testing.expect_value(t, output.count, budget == 1 ? 0 : 1)
		sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM sqlite_temp_master WHERE name IN ('nrc_graph_edges','nrc_rank_arcs')")
		testing.expect_value(t, db.commit(store), sql.OK)
	}
}

worker_db_test_graph_reads :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges", nil, nil, nil), sql.OK)
	edges := [8]pr.Edge {
		{source_type = .Asset, source_id = 1, target_type = .Task, target_id = 10, relation = .References},
		{source_type = .Asset, source_id = 2, target_type = .Task, target_id = 10, relation = .References},
		{source_type = .Asset, source_id = 1, target_type = .Task, target_id = 10, relation = .RelatedTo},
		{source_type = .Task, source_id = 20, target_type = .Asset, target_id = 1, relation = .References},
		{source_type = .Task, source_id = 20, target_type = .Asset, target_id = 2, relation = .References},
		{source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 2, relation = .References},
		{source_type = .Asset, source_id = 2, target_type = .Task, target_id = max(u64), relation = .MemberOf},
		{source_type = .Asset, source_id = 1, target_type = .Task, target_id = max(u64), relation = .MemberOf},
	}
	for &edge, i in edges {
		edge.edge_id = u64(i + 1); edge.created_at = i64(100 + i); edge.created_by = transmute([]byte)string("alice")
		key := pr.Asset {
			asset_id = edge.edge_id,
		}
		for workspace in ([2]string{c.workspace_id, "foreign-graph"}) {
			testing.expect_value(
				t,
				sqlite_projection_write(
					&store,
					"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
					workspace,
					&key,
					{
						i64(edge.source_type),
						edge.source_id,
						i64(edge.target_type),
						edge.target_id,
						i64(edge.relation),
						edge.created_at,
						string(edge.created_by),
					},
				),
				sql.OK,
			)
		}
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	request_buffer: [64]byte; expected_buffer: [4096]byte
	degree := pr.GraphDegreeRequest {
		correlation_id = 940,
	}
	all := [5]pr.GraphDegreeEntry{{.Asset, 1, 5}, {.Asset, 2, 4}, {.Task, 10, 3}, {.Task, 20, 2}, {.Task, max(u64), 2}}
	for mode in 0 ..< 4 {
		want := pr.GraphDegreeResultMessage {
			entries        = all[:],
			correlation_id = degree.correlation_id,
		}
		if mode == 1 {degree.top_n = 2; want.entries = all[:2]}
		if mode == 2 {degree.top_n = 101; degree.type_filter = 2; want.entries = all[2:]}
		filtered := [3]pr.GraphDegreeEntry{{.Task, max(u64), 2}, {.Asset, 1, 1}, {.Asset, 2, 1}}
		if mode == 3 {degree.type_filter = 0; degree.relation_mask = 1 << (u16(pr.RelationType.MemberOf) - 1); want.entries = filtered[:]}
		n := pr.serializeGraphDegreeRequest(degree, request_buffer[:]); written := pr.serializeGraphDegreeResult(want, expected_buffer[:])
		worker_db_test_graph_response(t, c, request_buffer[:n], expected_buffer[:written])
	}
	common := pr.GraphCommonNeighborsRequest {
		a_type         = .Asset,
		a_id           = 1,
		b_type         = .Asset,
		b_id           = 2,
		correlation_id = 941,
	}
	for mode in 0 ..< 5 {
		common.direction = pr.Direction(mode % 3); common.relation_mask = 0
		ids: []int; nodes: []pr.GraphPathNode
		switch mode {
		case 0:
			ids = {0, 1, 2, 3, 4, 6, 7}; nodes = {{.Task, 10}, {.Task, 20}, {.Task, max(u64)}}
		case 1:
			ids = {0, 1, 2, 6, 7}; nodes = {{.Task, 10}, {.Task, max(u64)}}
		case 2:
			ids = {3, 4}; nodes = {{.Task, 20}}
		case 3:
			common.relation_mask = 1 << (u16(pr.RelationType.References) - 1); ids = {0, 1, 3, 4}; nodes = {{.Task, 10}, {.Task, 20}}
		case 4:
			common.b_id = 1; ids = {0, 2, 5, 7}; nodes = {{.Asset, 2}, {.Task, 10}, {.Task, max(u64)}}
		}
		selected: [8]pr.Edge
		for index, i in ids do selected[i] = edges[index]
		want := pr.GraphCommonNeighborsResultMessage {
			a_type         = common.a_type,
			a_id           = common.a_id,
			b_type         = common.b_type,
			b_id           = common.b_id,
			nodes          = nodes,
			edges          = selected[:len(ids)],
			correlation_id = common.correlation_id,
		}
		n := pr.serializeGraphCommonNeighborsRequest(common, request_buffer[:]); written := pr.serializeGraphCommonNeighborsResult(want, expected_buffer[:])
		worker_db_test_graph_response(t, c, request_buffer[:n], expected_buffer[:written])
	}
	// Exact output-budget boundary and scratch-table cleanup on the same connection.
	n := pr.serializeGraphCommonNeighborsRequest(common, request_buffer[:])
	request := db.Request {
		opcode    = .C_GraphCommonNeighbors,
		workspace = c.workspace_id,
		body      = request_buffer[2:n],
	}
	for budget in ([2]int{279, 280}) {
		output := db.Command_Output {
			limit = budget + size_of(db.Command_Frame),
		}; defer db.destroy_command_output(&output)
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), budget == 279 ? sql.TOOBIG : sql.OK)
		testing.expect_value(t, output.count, budget == 279 ? 0 : 1)
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM sqlite_temp_master WHERE name IN ('nrc_neighbors','nrc_common')")
		testing.expect_value(t, db.rollback(&store), sql.OK)
	}
	worker_db_test_graph_walks(t, c, edges[:], &store)
	// Exercise the u16 degree boundary through the executor and error envelope.
	insert: ^sql.Statement
	testing.expect_value(
		t,
		sql.prepare_v2(
			store.db,
			`INSERT INTO edges
 SELECT workspace,?1,source_type,source_id,target_type,target_id,relation,created_at,created_by
 FROM edges WHERE workspace=?2 AND id=x'0000000000000001'`,
			-1,
			&insert,
			nil,
		),
		sql.OK,
	)
	defer sql.finalize(insert)
	testing.expect_value(t, sql.bind_bytes(insert, 2, transmute([]byte)c.workspace_id), sql.OK)
	degree = {
		top_n          = 1,
		correlation_id = 942,
	}
	n = pr.serializeGraphDegreeRequest(degree, request_buffer[:])
	next_id: u64 = 100
	for count in ([2]int{65530, 1}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		for _ in 0 ..< count {
			testing.expect_value(t, sql.bind_id(insert, 1, next_id), sql.OK)
			testing.expect_value(t, sql.step(insert), sql.DONE)
			testing.expect_value(t, sql.reset(insert), sql.OK)
			next_id += 1
		}
		testing.expect_value(t, db.commit(&store), sql.OK)
		written := 0
		if count == 65530 {
			written = pr.serializeGraphDegreeResult({entries = {{.Asset, 1, 65535}}, correlation_id = 942}, expected_buffer[:])
		} else {
			written = pr.serializeErrorResponse(
				{
					origin_opcode = .C_GraphDegree,
					error_msg = transmute([]byte)string("Graph result exceeds response limit; narrow the query"),
					correlation_id = 942,
				},
				expected_buffer[:],
			)
		}
		worker_db_test_graph_response(t, c, request_buffer[:n], expected_buffer[:written])
	}
}

@(test)
test_sqlite_graph_visit_limits :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-graph-limits-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	for i in 0 ..< 2000 {
		key := pr.Asset {
			asset_id = u64(i + 1),
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,1,0,x'')",
				"limits",
				&key,
				{i64(pr.TargetType.Asset), u64(1), i64(pr.TargetType.Task), u64(i + 1)},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	for mode in 0 ..< 4 {
		buffer: [128]byte; n := 0; opcode := pr.Opcode.C_GraphQuery
		if mode == 0 {
			n = pr.serializeGraphQueryRequest({start_type = .Asset, start_id = 1, max_depth = 1, direction = .Outgoing}, buffer[:])
		} else {
			opcode = .C_GraphShortestPath
			n = pr.serializeGraphShortestPathRequest(
				{from_type = .Asset, from_id = 1, to_type = .Task, to_id = u64(1998 + mode - 1), max_depth = 1, direction = .Outgoing},
				buffer[:],
			)
		}
		request := db.Request {
			workspace = "limits",
			opcode    = opcode,
			body      = buffer[2:n],
		}
		for budget in ([2]int{1, pr.MAX_PROTOCOL_PAYLOAD_SIZE + size_of(db.Command_Frame)}) {
			output := db.Command_Output {
				limit = budget,
			}; defer db.destroy_command_output(&output)
			testing.expect_value(t, db.begin(&store), sql.OK)
			testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), budget == 1 ? sql.TOOBIG : sql.OK)
			testing.expect_value(t, output.count, budget == 1 ? 0 : 1)
			sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM sqlite_temp_master WHERE name='nrc_graph_edges'")
			testing.expect_value(t, db.commit(&store), sql.OK)
			if budget == 1 || output.count != 1 do continue
			nodes: [500]pr.GraphQueryNode; path_nodes: [5]pr.GraphPathNode; edges: [500]pr.Edge
			if mode == 0 {
				msg, parse_err := pr.parseGraphQueryResult(output.frames[0].payload, nodes[:], edges[:])
				testing.expect(t, parse_err == nil && msg.truncated)
				testing.expect_value(t, len(msg.nodes), 500); testing.expect_value(t, len(msg.edges), 499)
				testing.expect_value(t, msg.nodes[499].target_id, u64(499))
			} else {
				msg, parse_err := pr.parseGraphShortestPathResult(output.frames[0].payload, path_nodes[:], edges[:])
				testing.expect(t, parse_err == nil)
				testing.expect_value(t, msg.found, mode != 3)
				if mode != 3 {testing.expect_value(t, msg.path_length, u8(1)); testing.expect_value(t, msg.edges[0].edge_id, u64(1998 + mode - 1))}
			}
		}
	}
}
