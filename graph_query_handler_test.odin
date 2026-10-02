package main

// Production graph handler tests over in-memory conversation state. Each test
// invokes the handler and decodes the captured WebSocket protocol response.

import "core:testing"

import pr "protocol"

when !NRC_SIMULATION {
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	GRAPH_HANDLER_TEST_CONV_ID :: pr.WORKSPACE_DATA_ID

	Graph_Handler_Test_Context :: struct {
		sim:  Sim_Test_Context,
		conn: ^NRC_Connection,
		conv: ^Conversation_State,
	}

	graph_handler_test_begin :: proc(ctx: ^Graph_Handler_Test_Context) -> bool {
		ctx^ = {}
		simulation_test_begin(&ctx.sim, 130)
		ctx.conn = simulation_test_install_client(&ctx.sim.sim, 1, "graph-handler-tests", "tester")
		ctx.sim.conns[1] = ctx.conn
		if ctx.conn == nil do return false
		ws := get_connection_workspace(ctx.conn)
		if ws == nil do return false
		ctx.conv = get_or_create_conversation(ws, GRAPH_HANDLER_TEST_CONV_ID)
		return ctx.conv != nil
	}

	graph_handler_test_end :: proc(ctx: ^Graph_Handler_Test_Context) {
		simulation_test_end(&ctx.sim)
		ctx^ = {}
	}

	graph_handler_test_add_edge :: proc(
		ctx: ^Graph_Handler_Test_Context,
		id: pr.EdgeID,
		source_type: pr.TargetType,
		source_id: u64,
		target_type: pr.TargetType,
		target_id: u64,
		relation: pr.RelationType,
	) {
		edge := new(pr.Edge)
		edge^ = {
			edge_id     = id,
			conv_id     = GRAPH_HANDLER_TEST_CONV_ID,
			source_type = source_type,
			source_id   = source_id,
			target_type = target_type,
			target_id   = target_id,
			relation    = relation,
		}
		ctx.conv.edges[id] = edge

		source_key := Edge_Entity_Key {
			target_type = source_type,
			target_id   = source_id,
		}
		target_key := Edge_Entity_Key {
			target_type = target_type,
			target_id   = target_id,
		}
		if source_key not_in ctx.conv.edges_by_entity {
			ctx.conv.edges_by_entity[source_key] = make([dynamic]pr.EdgeID, 0, 4)
		}
		append(&ctx.conv.edges_by_entity[source_key], id)
		if target_key not_in ctx.conv.edges_by_entity {
			ctx.conv.edges_by_entity[target_key] = make([dynamic]pr.EdgeID, 0, 4)
		}
		append(&ctx.conv.edges_by_entity[target_key], id)
	}

	graph_handler_test_add_stale_adjacency :: proc(ctx: ^Graph_Handler_Test_Context, target_type: pr.TargetType, target_id: u64, edge_id: pr.EdgeID) {
		key := Edge_Entity_Key {
			target_type = target_type,
			target_id   = target_id,
		}
		if key not_in ctx.conv.edges_by_entity {
			ctx.conv.edges_by_entity[key] = make([dynamic]pr.EdgeID, 0, 1)
		}
		append(&ctx.conv.edges_by_entity[key], edge_id)
	}

	graph_handler_test_payload :: proc(t: ^testing.T, ctx: ^Graph_Handler_Test_Context, expected: pr.Opcode) -> (payload: []u8, ok: bool) {
		frame_count := nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock)
		testing.expect_value(t, frame_count, 1)
		if frame_count != 1 do return
		payload, ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, 0))
		testing.expect(t, ok, "captured graph response should be a complete WebSocket frame")
		if !ok do return
		testing.expect_value(t, pr.get_opcode(payload), expected)
		return
	}

	graph_query_test_run :: proc(
		t: ^testing.T,
		ctx: ^Graph_Handler_Test_Context,
		req: pr.GraphQueryRequest,
		nodes: []pr.GraphQueryNode,
		edges: []pr.Edge,
	) -> (
		pr.GraphQueryResultMessage,
		bool,
	) {
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		handle_graph_query(ctx.conn, req)
		payload, ok := graph_handler_test_payload(t, ctx, .S_GraphQueryResult)
		if !ok do return {}, false
		result, parse_err := pr.parseGraphQueryResult(payload, nodes, edges)
		testing.expect(t, parse_err == nil, "GraphQueryResult should parse")
		return result, parse_err == nil
	}

	shortest_path_test_run :: proc(
		t: ^testing.T,
		ctx: ^Graph_Handler_Test_Context,
		req: pr.GraphShortestPathRequest,
		nodes: []pr.GraphPathNode,
		edges: []pr.Edge,
	) -> (
		pr.GraphShortestPathResultMessage,
		bool,
	) {
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		handle_shortest_path(ctx.conn, req)
		payload, ok := graph_handler_test_payload(t, ctx, .S_GraphShortestPathResult)
		if !ok do return {}, false
		result, parse_err := pr.parseGraphShortestPathResult(payload, nodes, edges)
		testing.expect(t, parse_err == nil, "GraphShortestPathResult should parse")
		return result, parse_err == nil
	}

	degree_query_test_run :: proc(
		t: ^testing.T,
		ctx: ^Graph_Handler_Test_Context,
		req: pr.GraphDegreeRequest,
		entries: []pr.GraphDegreeEntry,
	) -> (
		pr.GraphDegreeResultMessage,
		bool,
	) {
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		handle_degree_query(ctx.conn, req)
		payload, ok := graph_handler_test_payload(t, ctx, .S_GraphDegreeResult)
		if !ok do return {}, false
		result, parse_err := pr.parseGraphDegreeResult(payload, entries)
		testing.expect(t, parse_err == nil, "GraphDegreeResult should parse")
		return result, parse_err == nil
	}

	common_neighbors_test_run :: proc(
		t: ^testing.T,
		ctx: ^Graph_Handler_Test_Context,
		req: pr.GraphCommonNeighborsRequest,
		nodes: []pr.GraphPathNode,
		edges: []pr.Edge,
	) -> (
		pr.GraphCommonNeighborsResultMessage,
		bool,
	) {
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		handle_common_neighbors(ctx.conn, req)
		payload, ok := graph_handler_test_payload(t, ctx, .S_GraphCommonNeighborsResult)
		if !ok do return {}, false
		result, parse_err := pr.parseGraphCommonNeighborsResult(payload, nodes, edges)
		testing.expect(t, parse_err == nil, "GraphCommonNeighborsResult should parse")
		return result, parse_err == nil
	}
}

@(test)
test_graph_query_handler_depth_direction_relation_cycle_and_ordering :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Graph_Handler_Test_Context
		testing.expect(t, graph_handler_test_begin(&ctx), "graph handler fixture should initialize")
		defer graph_handler_test_end(&ctx)
		if ctx.conv == nil do return

		// T0 -> T1 -> T2 -> T3 -> T1, plus T1 --References--> Asset:10.
		graph_handler_test_add_edge(&ctx, 30, .Task, 0, .Task, 1, .Blocks)
		graph_handler_test_add_edge(&ctx, 20, .Task, 1, .Task, 2, .Blocks)
		graph_handler_test_add_edge(&ctx, 10, .Task, 2, .Task, 3, .Blocks)
		graph_handler_test_add_edge(&ctx, 40, .Task, 3, .Task, 1, .Blocks)
		graph_handler_test_add_edge(&ctx, 50, .Task, 1, .Asset, 10, .References)
		graph_handler_test_add_stale_adjacency(&ctx, .Task, 1, 999)

		nodes: [16]pr.GraphQueryNode
		edges: [16]pr.Edge
		base := pr.GraphQueryRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			start_type     = .Task,
			start_id       = 1,
			max_depth      = 2,
			direction      = .Both,
			correlation_id = 0x10203040,
		}
		result, ok := graph_query_test_run(t, &ctx, base, nodes[:], edges[:])
		if !ok do return
		testing.expect(t, !result.truncated, "small cyclic graph should not truncate")
		testing.expect_value(t, result.correlation_id, base.correlation_id)
		testing.expect_value(t, len(result.nodes), 5)
		// Production ordering is depth, then type, then ID.
		testing.expect_value(t, result.nodes[0], pr.GraphQueryNode{target_type = .Task, target_id = 1, depth = 0})
		testing.expect_value(t, result.nodes[1], pr.GraphQueryNode{target_type = .Asset, target_id = 10, depth = 1})
		testing.expect_value(t, result.nodes[2], pr.GraphQueryNode{target_type = .Task, target_id = 0, depth = 1})
		testing.expect_value(t, result.nodes[3], pr.GraphQueryNode{target_type = .Task, target_id = 2, depth = 1})
		testing.expect_value(t, result.nodes[4], pr.GraphQueryNode{target_type = .Task, target_id = 3, depth = 1})
		testing.expect_value(t, len(result.edges), 5)
		for i in 1 ..< len(result.edges) do testing.expect(t, result.edges[i - 1].edge_id < result.edges[i].edge_id, "graph edges should be ordered by ID")

		depth_two := base
		depth_two.start_id = 0
		depth_two.direction = .Outgoing
		result, ok = graph_query_test_run(t, &ctx, depth_two, nodes[:], edges[:])
		if !ok do return
		testing.expect_value(t, len(result.nodes), 4)
		testing.expect_value(t, result.nodes[0], pr.GraphQueryNode{target_type = .Task, target_id = 0, depth = 0})
		testing.expect_value(t, result.nodes[1], pr.GraphQueryNode{target_type = .Task, target_id = 1, depth = 1})
		testing.expect_value(t, result.nodes[2], pr.GraphQueryNode{target_type = .Asset, target_id = 10, depth = 2})
		testing.expect_value(t, result.nodes[3], pr.GraphQueryNode{target_type = .Task, target_id = 2, depth = 2})

		outgoing := base
		outgoing.direction = .Outgoing
		outgoing.max_depth = 1
		result, ok = graph_query_test_run(t, &ctx, outgoing, nodes[:], edges[:])
		if !ok do return
		testing.expect_value(t, len(result.nodes), 3)
		testing.expect_value(t, result.nodes[1].target_type, pr.TargetType.Asset)
		testing.expect_value(t, result.nodes[2].target_id, u64(2))

		incoming := base
		incoming.direction = .Incoming
		result, ok = graph_query_test_run(t, &ctx, incoming, nodes[:], edges[:])
		if !ok do return
		testing.expect_value(t, len(result.nodes), 4)
		testing.expect_value(t, result.nodes[1].target_id, u64(0))

		blocks_only := base
		blocks_only.relation_mask = 0b001000
		result, ok = graph_query_test_run(t, &ctx, blocks_only, nodes[:], edges[:])
		if !ok do return
		testing.expect_value(t, len(result.nodes), 4)
		for node in result.nodes do testing.expect(t, node.target_type == .Task, "relation mask should exclude reference asset")
	}
}

@(test)
test_graph_query_handler_truncates_without_dangling_or_stale_edges :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Graph_Handler_Test_Context
		testing.expect(t, graph_handler_test_begin(&ctx), "graph handler fixture should initialize")
		defer graph_handler_test_end(&ctx)
		if ctx.conv == nil do return

		for i in u64(2) ..= u64(MAX_RESULT_NODES + 1) {
			graph_handler_test_add_edge(&ctx, pr.EdgeID(i - 1), .Task, 1, .Task, i, .Blocks)
		}
		graph_handler_test_add_stale_adjacency(&ctx, .Task, 1, 9999)
		nodes: [MAX_RESULT_NODES]pr.GraphQueryNode
		edges: [MAX_RESULT_NODES]pr.Edge
		result, ok := graph_query_test_run(
			t,
			&ctx,
			pr.GraphQueryRequest{conv_id = GRAPH_HANDLER_TEST_CONV_ID, start_type = .Task, start_id = 1, max_depth = 1, direction = .Both},
			nodes[:],
			edges[:],
		)
		if !ok do return
		testing.expect(t, result.truncated, "node limit should set truncated")
		testing.expect_value(t, len(result.nodes), MAX_RESULT_NODES)
		testing.expect_value(t, len(result.edges), MAX_RESULT_NODES - 1)
		for edge in result.edges {
			testing.expect(t, edge.edge_id != 9999, "stale adjacency must not produce an edge")
			testing.expect(t, edge.target_id <= u64(MAX_RESULT_NODES), "truncated response must not contain a dangling endpoint")
		}
	}
}

@(test)
test_shortest_path_handler_depth_direction_relation_order_and_correlation :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Graph_Handler_Test_Context
		testing.expect(t, graph_handler_test_begin(&ctx), "graph handler fixture should initialize")
		defer graph_handler_test_end(&ctx)
		if ctx.conv == nil do return

		graph_handler_test_add_edge(&ctx, 20, .Task, 1, .Task, 2, .Blocks)
		graph_handler_test_add_edge(&ctx, 10, .Task, 2, .Task, 3, .Blocks)
		graph_handler_test_add_edge(&ctx, 30, .Task, 1, .Task, 3, .References)
		graph_handler_test_add_stale_adjacency(&ctx, .Task, 1, 999)
		nodes: [8]pr.GraphPathNode
		edges: [8]pr.Edge
		req := pr.GraphShortestPathRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			from_type      = .Task,
			from_id        = 1,
			to_type        = .Task,
			to_id          = 3,
			relation_mask  = 0b001000,
			direction      = .Outgoing,
			max_depth      = 4,
			correlation_id = 0x50607080,
		}
		result, ok := shortest_path_test_run(t, &ctx, req, nodes[:], edges[:])
		if !ok do return
		testing.expect(t, result.found, "filtered two-hop path should be found")
		testing.expect_value(t, result.path_length, u8(2))
		testing.expect_value(t, result.correlation_id, req.correlation_id)
		testing.expect_value(t, len(result.nodes), 3)
		testing.expect_value(t, result.nodes[0].target_id, u64(1))
		testing.expect_value(t, result.nodes[1].target_id, u64(2))
		testing.expect_value(t, result.nodes[2].target_id, u64(3))
		testing.expect_value(t, result.edges[0].edge_id, pr.EdgeID(20))
		testing.expect_value(t, result.edges[1].edge_id, pr.EdgeID(10))

		too_shallow := req
		too_shallow.max_depth = 1
		result, ok = shortest_path_test_run(t, &ctx, too_shallow, nodes[:], edges[:])
		if !ok do return
		testing.expect(t, !result.found, "path beyond max depth should not be found")

		wrong_direction := req
		wrong_direction.direction = .Incoming
		result, ok = shortest_path_test_run(t, &ctx, wrong_direction, nodes[:], edges[:])
		if !ok do return
		testing.expect(t, !result.found, "path in the wrong direction should not be found")

		same := req
		same.to_id = same.from_id
		result, ok = shortest_path_test_run(t, &ctx, same, nodes[:], edges[:])
		if !ok do return
		testing.expect(t, result.found, "same-node path should be found")
		testing.expect_value(t, result.path_length, u8(0))
		testing.expect_value(t, len(result.nodes), 1)
	}
}

@(test)
test_degree_handler_filters_orders_truncates_and_ignores_stale_adjacency :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Graph_Handler_Test_Context
		testing.expect(t, graph_handler_test_begin(&ctx), "graph handler fixture should initialize")
		defer graph_handler_test_end(&ctx)
		if ctx.conv == nil do return

		graph_handler_test_add_edge(&ctx, 1, .Task, 2, .Task, 20, .Blocks)
		graph_handler_test_add_edge(&ctx, 2, .Task, 2, .Task, 21, .Blocks)
		graph_handler_test_add_edge(&ctx, 3, .Task, 1, .Task, 10, .Blocks)
		graph_handler_test_add_edge(&ctx, 4, .Task, 1, .Task, 11, .Blocks)
		graph_handler_test_add_edge(&ctx, 5, .Task, 1, .Asset, 5, .References)
		graph_handler_test_add_stale_adjacency(&ctx, .Task, 99, 999)
		graph_handler_test_add_stale_adjacency(&ctx, .Task, 1, 998)

		entries: [16]pr.GraphDegreeEntry
		req := pr.GraphDegreeRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			top_n          = 2,
			type_filter    = 2,
			relation_mask  = 0b001000,
			correlation_id = 0x90A0B0C0,
		}
		result, ok := degree_query_test_run(t, &ctx, req, entries[:])
		if !ok do return
		testing.expect_value(t, result.correlation_id, req.correlation_id)
		testing.expect_value(t, len(result.entries), 2)
		// Equal degrees use type then ID as deterministic tie breakers.
		testing.expect_value(t, result.entries[0], pr.GraphDegreeEntry{target_type = .Task, target_id = 1, degree = 2})
		testing.expect_value(t, result.entries[1], pr.GraphDegreeEntry{target_type = .Task, target_id = 2, degree = 2})

		all_relations := req
		all_relations.top_n = 100
		all_relations.relation_mask = 0
		result, ok = degree_query_test_run(t, &ctx, all_relations, entries[:])
		if !ok do return
		testing.expect_value(t, len(result.entries), 6)
		task_one_found := false
		for entry in result.entries {
			testing.expect(t, entry.target_id != 99, "stale-only adjacency must not produce a degree entry")
			if entry.target_type == .Task && entry.target_id == 1 {
				task_one_found = true
				testing.expect_value(t, entry.degree, u16(3))
			}
		}
		testing.expect(t, task_one_found, "mask-zero result should contain Task:1")
	}
}

@(test)
test_common_neighbors_handler_direction_relation_order_and_correlation :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Graph_Handler_Test_Context
		testing.expect(t, graph_handler_test_begin(&ctx), "graph handler fixture should initialize")
		defer graph_handler_test_end(&ctx)
		if ctx.conv == nil do return

		// Shared outgoing Block neighbors are Task:3 and Asset:4. Task:5 is
		// shared only by incoming edges, and Task:6 only by References edges.
		graph_handler_test_add_edge(&ctx, 40, .Task, 1, .Task, 3, .Blocks)
		graph_handler_test_add_edge(&ctx, 10, .Task, 2, .Task, 3, .Blocks)
		graph_handler_test_add_edge(&ctx, 45, .Task, 1, .Task, 3, .References)
		graph_handler_test_add_edge(&ctx, 30, .Task, 1, .Asset, 4, .Blocks)
		graph_handler_test_add_edge(&ctx, 20, .Task, 2, .Asset, 4, .Blocks)
		graph_handler_test_add_edge(&ctx, 50, .Task, 5, .Task, 1, .Blocks)
		graph_handler_test_add_edge(&ctx, 60, .Task, 5, .Task, 2, .Blocks)
		graph_handler_test_add_edge(&ctx, 70, .Task, 1, .Task, 6, .References)
		graph_handler_test_add_edge(&ctx, 80, .Task, 2, .Task, 6, .References)
		graph_handler_test_add_edge(&ctx, 90, .Task, 1, .Task, 2, .Blocks)
		graph_handler_test_add_stale_adjacency(&ctx, .Task, 1, 999)

		nodes: [16]pr.GraphPathNode
		edges: [16]pr.Edge
		req := pr.GraphCommonNeighborsRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			a_type         = .Task,
			a_id           = 1,
			b_type         = .Task,
			b_id           = 2,
			relation_mask  = 0b001000,
			direction      = .Outgoing,
			correlation_id = 0xD0E0F001,
		}
		result, ok := common_neighbors_test_run(t, &ctx, req, nodes[:], edges[:])
		if !ok do return
		testing.expect_value(t, result.correlation_id, req.correlation_id)
		testing.expect_value(t, len(result.nodes), 2)
		// Production ordering is type then ID.
		testing.expect_value(t, result.nodes[0], pr.GraphPathNode{target_type = .Asset, target_id = 4})
		testing.expect_value(t, result.nodes[1], pr.GraphPathNode{target_type = .Task, target_id = 3})
		testing.expect_value(t, len(result.edges), 4)
		for i in 1 ..< len(result.edges) do testing.expect(t, result.edges[i - 1].edge_id < result.edges[i].edge_id, "common-neighbor edges should be ordered by ID")
		for edge in result.edges do testing.expect_value(t, edge.relation, pr.RelationType.Blocks)

		both := req
		both.direction = .Both
		result, ok = common_neighbors_test_run(t, &ctx, both, nodes[:], edges[:])
		if !ok do return
		testing.expect_value(t, len(result.nodes), 3)
		for node in result.nodes {
			testing.expect(t, node.target_id != 1 && node.target_id != 2, "query endpoints must not be common neighbors")
		}
	}
}
