package main

import "core:testing"

import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: hgl.run
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	Graph_Shortest_Path_Expected :: struct {
		found:       bool,
		path_length: u8,
		nodes:       [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphPathNode,
		node_count:  int,
		edges:       [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]pr.Edge,
		edge_count:  int,
	}

	Graph_Shortest_Path_Equivalence_Result :: struct {
		response:     [1_024]byte,
		response_len: int,
		state:        Graph_Query_Equivalence_State,
	}

	graph_shortest_path_entity_index :: proc(target_type: pr.TargetType, target_id: u64) -> int {
		entities := graph_query_equivalence_entities()
		for entity, entity_index in entities {
			if entity.target_type == target_type && entity.target_id == target_id do return entity_index
		}
		return -1
	}

	graph_shortest_path_expected :: proc(req: pr.GraphShortestPathRequest, edge_mask: u8) -> (Graph_Shortest_Path_Expected, bool) {
		result: Graph_Shortest_Path_Expected
		entities := graph_query_equivalence_entities()
		from_index := graph_shortest_path_entity_index(req.from_type, req.from_id)
		to_index := graph_shortest_path_entity_index(req.to_type, req.to_id)
		if from_index < 0 || to_index < 0 do return result, false
		if from_index == to_index {
			result.found = true
			result.nodes[0] = {
				target_type = req.from_type,
				target_id   = req.from_id,
			}
			result.node_count = 1
			return result, true
		}

		parents: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
		parent_edges: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
		depths: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]u8
		for index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
			parents[index] = -1
			parent_edges[index] = -1
		}
		queue: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
		parents[from_index] = from_index
		queue[0] = from_index
		queue_count := 1
		found := false
		edges := graph_query_equivalence_edges()
		bfs: for queue_index := 0; queue_index < queue_count; queue_index += 1 {
			entity_index := queue[queue_index]
			entity := entities[entity_index]
			if depths[entity_index] >= req.max_depth do continue
			for edge, edge_index in edges {
				if edge_mask & (u8(1) << u8(edge_index)) == 0 do continue
				relation_bit := u16(1) << (u16(edge.relation) - 1)
				if req.relation_mask != 0 && req.relation_mask & relation_bit == 0 do continue
				neighbor_type: pr.TargetType
				neighbor_id: u64
				resolved := false
				if edge.source_type == entity.target_type && edge.source_id == entity.target_id && req.direction != .Incoming {
					neighbor_type, neighbor_id, resolved = edge.target_type, edge.target_id, true
				} else if edge.target_type == entity.target_type && edge.target_id == entity.target_id && req.direction != .Outgoing {
					neighbor_type, neighbor_id, resolved = edge.source_type, edge.source_id, true
				}
				if !resolved do continue
				neighbor_index := graph_shortest_path_entity_index(neighbor_type, neighbor_id)
				if neighbor_index < 0 || parents[neighbor_index] >= 0 do continue
				parents[neighbor_index] = entity_index
				parent_edges[neighbor_index] = edge_index
				depths[neighbor_index] = depths[entity_index] + 1
				if neighbor_index == to_index {
					found = true
					break bfs
				}
				queue[queue_count] = neighbor_index
				queue_count += 1
			}
		}
		if !found do return result, true

		reverse_nodes: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
		reverse_edges: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]int
		current := to_index
		for current != from_index {
			reverse_nodes[result.node_count] = current
			result.node_count += 1
			reverse_edges[result.edge_count] = parent_edges[current]
			result.edge_count += 1
			current = parents[current]
		}
		reverse_nodes[result.node_count] = from_index
		result.node_count += 1
		for output_index in 0 ..< result.node_count {
			entity := entities[reverse_nodes[result.node_count - output_index - 1]]
			result.nodes[output_index] = {
				target_type = entity.target_type,
				target_id   = entity.target_id,
			}
		}
		for output_index in 0 ..< result.edge_count {
			result.edges[output_index] = graph_query_equivalence_expected_edge(reverse_edges[result.edge_count - output_index - 1])
		}
		result.found = true
		result.path_length = u8(result.edge_count)
		return result, true
	}

	graph_shortest_path_response_matches_model :: proc(payload: []byte, req: pr.GraphShortestPathRequest, edge_mask: u8) -> bool {
		expected, expected_ok := graph_shortest_path_expected(req, edge_mask)
		if !expected_ok do return false
		parsed_nodes: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphPathNode
		parsed_edges: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]pr.Edge
		parsed, parse_err := pr.parseGraphShortestPathResult(payload, parsed_nodes[:], parsed_edges[:])
		if parse_err != nil ||
		   parsed.conv_id != req.conv_id ||
		   parsed.from_type != req.from_type ||
		   parsed.from_id != req.from_id ||
		   parsed.to_type != req.to_type ||
		   parsed.to_id != req.to_id ||
		   parsed.found != expected.found ||
		   parsed.path_length != expected.path_length ||
		   parsed.correlation_id != req.correlation_id ||
		   len(parsed.nodes) != expected.node_count ||
		   len(parsed.edges) != expected.edge_count {
			return false
		}
		for node, node_index in parsed.nodes do if node != expected.nodes[node_index] do return false
		for edge, edge_index in parsed.edges {
			expected_edge := expected.edges[edge_index]
			if edge.edge_id != expected_edge.edge_id ||
			   edge.conv_id != expected_edge.conv_id ||
			   edge.source_type != expected_edge.source_type ||
			   edge.source_id != expected_edge.source_id ||
			   edge.target_type != expected_edge.target_type ||
			   edge.target_id != expected_edge.target_id ||
			   edge.relation != expected_edge.relation ||
			   edge.created_at != 0 ||
			   len(edge.created_by) != 0 {
				return false
			}
		}
		expected_message := pr.GraphShortestPathResultMessage {
			conv_id        = req.conv_id,
			from_type      = req.from_type,
			from_id        = req.from_id,
			to_type        = req.to_type,
			to_id          = req.to_id,
			found          = expected.found,
			path_length    = expected.path_length,
			nodes          = expected.nodes[:expected.node_count],
			edges          = expected.edges[:expected.edge_count],
			correlation_id = req.correlation_id,
		}
		expected_payload: [1_024]byte
		expected_len := pr.serializeGraphShortestPathResult(expected_message, expected_payload[:])
		if expected_len != len(payload) do return false
		for byte_value, byte_index in payload do if byte_value != expected_payload[byte_index] do return false
		return true
	}

	graph_shortest_path_equivalence_run :: proc(
		req: pr.GraphShortestPathRequest,
		edge_mask: u8,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Graph_Shortest_Path_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Graph_Handler_Test_Context
		if !graph_handler_test_begin(&ctx) do return {}, "initialize shortest-path equivalence fixture", false
		defer graph_handler_test_end(&ctx)
		graph_query_equivalence_setup(&ctx, edge_mask)
		td.task_seq, td.asset_seq, td.edge_seq = 404, 505, 606
		before, before_ok := graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok do return {}, "capture shortest-path baseline", false
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		if through_wire {
			request_buf: [64]byte
			request_len := pr.serializeGraphShortestPathRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize shortest-path request", false
			parsed_req, parse_err := pr.parseGraphShortestPathRequest(request_buf[2:request_len])
			if parse_err != nil ||
			   parsed_req.conv_id != req.conv_id ||
			   parsed_req.from_type != req.from_type ||
			   parsed_req.from_id != req.from_id ||
			   parsed_req.to_type != req.to_type ||
			   parsed_req.to_id != req.to_id ||
			   parsed_req.relation_mask != req.relation_mask ||
			   parsed_req.direction != req.direction ||
			   parsed_req.max_depth != req.max_depth ||
			   parsed_req.flags != req.flags ||
			   parsed_req.correlation_id != req.correlation_id {
				return {}, "shortest-path request parser changed serialized fields", false
			}
			if !handler_equivalence_deliver_wire(&ctx.sim.sim, ctx.conn, request_buf[:request_len], split_a, split_b) {
				return {}, "deliver split shortest-path request", false
			}
		} else {
			handle_shortest_path(ctx.conn, req)
		}

		result: Graph_Shortest_Path_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock) != 1 do return result, "unexpected shortest-path response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture shortest-path response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		if !graph_shortest_path_response_matches_model(payload, req, edge_mask) {
			return result, "shortest-path response differs from independent model", false
		}
		result.state, before_ok = graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok || !graph_query_equivalence_states_equal(before, result.state) {
			return result, "shortest-path query mutated server state", false
		}
		return result, "", true
	}

	graph_shortest_path_equivalence_results_equal :: proc(a, b: Graph_Shortest_Path_Equivalence_Result) -> bool {
		if a.response_len != b.response_len do return false
		for index in 0 ..< a.response_len do if a.response[index] != b.response[index] do return false
		return graph_query_equivalence_states_equal(a.state, b.state)
	}

	prop_graph_shortest_path_parser_direct_semantic_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		edge_mask, edge_mask_err := hgl.draw_i64(tc, 0, 63)
		if edge_mask_err == .Stop_Test do return hgl.abort()
		if edge_mask_err != nil do return hgl.interesting("shortest-path edge mask draw failed")
		from_index, from_err := hgl.draw_i64(tc, 0, GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT - 1)
		if from_err == .Stop_Test do return hgl.abort()
		if from_err != nil do return hgl.interesting("shortest-path source draw failed")
		to_index, to_err := hgl.draw_i64(tc, 0, GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT - 1)
		if to_err == .Stop_Test do return hgl.abort()
		if to_err != nil do return hgl.interesting("shortest-path target draw failed")
		relation_mask, relation_err := hgl.draw_i64(tc, 0, 63)
		if relation_err == .Stop_Test do return hgl.abort()
		if relation_err != nil do return hgl.interesting("shortest-path relation mask draw failed")
		direction, direction_err := hgl.draw_i64(tc, 0, 2)
		if direction_err == .Stop_Test do return hgl.abort()
		if direction_err != nil do return hgl.interesting("shortest-path direction draw failed")
		max_depth, depth_err := hgl.draw_i64(tc, 1, 4)
		if depth_err == .Stop_Test do return hgl.abort()
		if depth_err != nil do return hgl.interesting("shortest-path depth draw failed")
		flags, flags_err := hgl.draw_i64(tc, 0, 255)
		if flags_err == .Stop_Test do return hgl.abort()
		if flags_err != nil do return hgl.interesting("shortest-path flags draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("shortest-path correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("shortest-path first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("shortest-path second split draw failed")
		entities := graph_query_equivalence_entities()
		from, to := entities[from_index], entities[to_index]
		req := pr.GraphShortestPathRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			from_type      = from.target_type,
			from_id        = from.target_id,
			to_type        = to.target_type,
			to_id          = to.target_id,
			relation_mask  = u16(relation_mask),
			direction      = pr.Direction(direction),
			max_depth      = u8(max_depth),
			flags          = u8(flags),
			correlation_id = u32(correlation),
		}
		direct, direct_reason, direct_ok := graph_shortest_path_equivalence_run(req, u8(edge_mask), false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := graph_shortest_path_equivalence_run(req, u8(edge_mask), true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !graph_shortest_path_equivalence_results_equal(direct, wire) {
			return hgl.interesting("direct and split-wire shortest-path semantics differ")
		}
		return hgl.valid()
	}

	graph_shortest_path_mandatory_cases :: proc(t: ^testing.T) -> bool {
		requests := [7]pr.GraphShortestPathRequest {
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				from_type = .Task,
				from_id = 1,
				to_type = .Asset,
				to_id = 1,
				direction = .Both,
				max_depth = 4,
				correlation_id = 0x7900,
			},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				from_type = .Task,
				from_id = 1,
				to_type = .Asset,
				to_id = 1,
				direction = .Outgoing,
				max_depth = 4,
				correlation_id = 0x7901,
			},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				from_type = .Asset,
				from_id = 1,
				to_type = .Task,
				to_id = 1,
				direction = .Incoming,
				max_depth = 4,
				correlation_id = 0x7902,
			},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				from_type = .Task,
				from_id = 1,
				to_type = .Asset,
				to_id = 1,
				direction = .Both,
				max_depth = 1,
				correlation_id = 0x7903,
			},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				from_type = .Task,
				from_id = 1,
				to_type = .Asset,
				to_id = 1,
				relation_mask = 0b001000,
				direction = .Both,
				max_depth = 4,
				correlation_id = 0x7904,
			},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				from_type = .Task,
				from_id = 2,
				to_type = .Task,
				to_id = 2,
				relation_mask = 0b111111,
				direction = .Outgoing,
				max_depth = 1,
				correlation_id = 0x7905,
			},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				from_type = .Task,
				from_id = 99,
				to_type = .Task,
				to_id = 1,
				direction = .Both,
				max_depth = 4,
				correlation_id = 0x7906,
			},
		}
		for req, case_index in requests {
			direct, direct_reason, direct_ok := graph_shortest_path_equivalence_run(req, 0b111111, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory shortest-path case=%d direct failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := graph_shortest_path_equivalence_run(req, 0b111111, true, case_index + 3, case_index + 19)
			testing.expectf(t, wire_ok, "mandatory shortest-path case=%d wire failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := graph_shortest_path_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory shortest-path case=%d semantics should match", case_index)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_graph_shortest_path_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !graph_shortest_path_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_graph_shortest_path_parser_direct_semantic_equivalence, nil, {test_cases = 128})
		testing.expectf(t, err == nil, "generated shortest-path parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
