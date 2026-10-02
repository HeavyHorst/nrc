package main

import "core:testing"

import "btree"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: hgl.run
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT :: 6
	GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT :: 6

	Graph_Query_Equivalence_Edge :: struct {
		source_type: pr.TargetType,
		source_id:   u64,
		target_type: pr.TargetType,
		target_id:   u64,
		relation:    pr.RelationType,
	}

	Graph_Query_Equivalence_Entity :: struct {
		target_type: pr.TargetType,
		target_id:   u64,
	}

	Graph_Query_Equivalence_State :: struct {
		edge_payloads:         [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT][128]byte,
		edge_payload_lens:     [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]int,
		adjacency_edge_ids:    [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT][GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]pr.EdgeID,
		adjacency_edge_counts: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int,
		task_count:            int,
		asset_count:           int,
		edge_count:            int,
		adjacency_key_count:   int,
		task_index_count:      int,
		task_btree_count:      int,
		note_index_count:      int,
		note_btree_count:      int,
		task_seq:              u64,
		asset_seq:             u64,
		edge_seq:              u64,
	}

	Graph_Query_Equivalence_Result :: struct {
		response:     [1_024]byte,
		response_len: int,
		state:        Graph_Query_Equivalence_State,
	}

	graph_query_equivalence_edges :: proc() -> [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]Graph_Query_Equivalence_Edge {
		return {
			{source_type = .Task, source_id = 1, target_type = .Task, target_id = 2, relation = .References},
			{source_type = .Task, source_id = 2, target_type = .Asset, target_id = 1, relation = .RelatedTo},
			{source_type = .Asset, source_id = 1, target_type = .Task, target_id = 3, relation = .DependsOn},
			{source_type = .Task, source_id = 3, target_type = .Task, target_id = 1, relation = .Blocks},
			{source_type = .Asset, source_id = 2, target_type = .Task, target_id = 1, relation = .DerivedFrom},
			{source_type = .Task, source_id = 2, target_type = .Asset, target_id = 2, relation = .Supersedes},
		}
	}

	graph_query_equivalence_expected_edge :: proc(edge_index: int) -> pr.Edge {
		edge := graph_query_equivalence_edges()[edge_index]
		return pr.Edge {
			edge_id = pr.EdgeID(edge_index + 1),
			conv_id = GRAPH_HANDLER_TEST_CONV_ID,
			source_type = edge.source_type,
			source_id = edge.source_id,
			target_type = edge.target_type,
			target_id = edge.target_id,
			relation = edge.relation,
		}
	}

	graph_query_equivalence_entities :: proc() -> [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]Graph_Query_Equivalence_Entity {
		return {
			{target_type = .Task, target_id = 1},
			{target_type = .Task, target_id = 2},
			{target_type = .Task, target_id = 3},
			{target_type = .Asset, target_id = 1},
			{target_type = .Asset, target_id = 2},
			{target_type = .Task, target_id = 99},
		}
	}

	graph_query_equivalence_setup :: proc(ctx: ^Graph_Handler_Test_Context, edge_mask: u8) {
		edges := graph_query_equivalence_edges()
		for edge, edge_index in edges {
			if edge_mask & (u8(1) << u8(edge_index)) == 0 do continue
			graph_handler_test_add_edge(ctx, pr.EdgeID(edge_index + 1), edge.source_type, edge.source_id, edge.target_type, edge.target_id, edge.relation)
		}
	}

	graph_query_equivalence_capture_state :: proc(conv: ^Conversation_State) -> (Graph_Query_Equivalence_State, bool) {
		result: Graph_Query_Equivalence_State
		if conv == nil do return result, false
		for edge_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT {
			edge := conv.edges[pr.EdgeID(edge_index + 1)]
			if edge == nil do continue
			result.edge_payload_lens[edge_index] = pr.serializeEdge(edge^, result.edge_payloads[edge_index][:])
			if result.edge_payload_lens[edge_index] <= 0 do return result, false
		}
		entities := graph_query_equivalence_entities()
		for entity, entity_index in entities {
			adjacent := conv.edges_by_entity[Edge_Entity_Key{target_type = entity.target_type, target_id = entity.target_id}]
			if len(adjacent) > GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT do return result, false
			result.adjacency_edge_counts[entity_index] = len(adjacent)
			copy(result.adjacency_edge_ids[entity_index][:], adjacent[:])
		}
		result.task_count = len(conv.tasks)
		result.asset_count = len(conv.assets)
		result.edge_count = len(conv.edges)
		result.adjacency_key_count = len(conv.edges_by_entity)
		result.task_index_count = len(conv.task_index_keys)
		result.task_btree_count = btree.count(&conv.task_index)
		result.note_index_count = len(conv.note_index_keys)
		result.note_btree_count = btree.count(&conv.note_index)
		result.task_seq = td.task_seq
		result.asset_seq = td.asset_seq
		result.edge_seq = td.edge_seq
		return result, true
	}

	graph_query_equivalence_states_equal :: proc(a, b: Graph_Query_Equivalence_State) -> bool {
		if a.edge_payload_lens != b.edge_payload_lens || a.adjacency_edge_counts != b.adjacency_edge_counts do return false
		for edge_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT {
			for byte_index in 0 ..< a.edge_payload_lens[edge_index] {
				if a.edge_payloads[edge_index][byte_index] != b.edge_payloads[edge_index][byte_index] do return false
			}
		}
		for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
			for edge_index in 0 ..< a.adjacency_edge_counts[entity_index] {
				if a.adjacency_edge_ids[entity_index][edge_index] != b.adjacency_edge_ids[entity_index][edge_index] do return false
			}
		}
		return(
			a.task_count == b.task_count &&
			a.asset_count == b.asset_count &&
			a.edge_count == b.edge_count &&
			a.adjacency_key_count == b.adjacency_key_count &&
			a.task_index_count == b.task_index_count &&
			a.task_btree_count == b.task_btree_count &&
			a.note_index_count == b.note_index_count &&
			a.note_btree_count == b.note_btree_count &&
			a.task_seq == b.task_seq &&
			a.asset_seq == b.asset_seq &&
			a.edge_seq == b.edge_seq \
		)
	}

	graph_query_equivalence_node_less :: proc(a, b: pr.GraphQueryNode) -> bool {
		if a.depth != b.depth do return a.depth < b.depth
		if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
		return a.target_id < b.target_id
	}

	graph_query_equivalence_expected :: proc(
		req: pr.GraphQueryRequest,
		edge_mask: u8,
	) -> (
		nodes: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphQueryNode,
		node_count: int,
		edge_present: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]bool,
	) {
		entities := graph_query_equivalence_entities()
		edges := graph_query_equivalence_edges()
		start_index := 0
		for entity, entity_index in entities {
			if entity.target_type == req.start_type && entity.target_id == req.start_id {
				start_index = entity_index
				break
			}
		}
		visited: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]bool
		depths: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]u8
		queue: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
		visited[start_index] = true
		queue[0] = start_index
		queue_count := 1
		for queue_index := 0; queue_index < queue_count; queue_index += 1 {
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
				neighbor_index := -1
				for candidate, candidate_index in entities {
					if candidate.target_type == neighbor_type && candidate.target_id == neighbor_id {
						neighbor_index = candidate_index
						break
					}
				}
				if neighbor_index < 0 do continue
				if !visited[neighbor_index] {
					visited[neighbor_index] = true
					depths[neighbor_index] = depths[entity_index] + 1
					queue[queue_count] = neighbor_index
					queue_count += 1
				}
				edge_present[edge_index] = true
			}
		}
		for entity, entity_index in entities {
			if !visited[entity_index] do continue
			node := pr.GraphQueryNode {
				target_type = entity.target_type,
				target_id   = entity.target_id,
				depth       = depths[entity_index],
			}
			insert_at := node_count
			for existing, existing_index in nodes[:node_count] {
				if graph_query_equivalence_node_less(node, existing) {
					insert_at = existing_index
					break
				}
			}
			for index := node_count; index > insert_at; index -= 1 do nodes[index] = nodes[index - 1]
			nodes[insert_at] = node
			node_count += 1
		}
		return
	}

	graph_query_equivalence_response_matches_model :: proc(payload: []byte, req: pr.GraphQueryRequest, edge_mask: u8) -> bool {
		parsed_nodes: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphQueryNode
		parsed_edges: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]pr.Edge
		parsed, parse_err := pr.parseGraphQueryResult(payload, parsed_nodes[:], parsed_edges[:])
		if parse_err != nil ||
		   parsed.conv_id != req.conv_id ||
		   parsed.start_type != req.start_type ||
		   parsed.start_id != req.start_id ||
		   parsed.truncated ||
		   parsed.correlation_id != req.correlation_id {
			return false
		}
		expected_nodes, expected_node_count, expected_edges := graph_query_equivalence_expected(req, edge_mask)
		if len(parsed.nodes) != expected_node_count do return false
		for node, node_index in parsed.nodes {
			if node != expected_nodes[node_index] do return false
		}
		expected_edge_count := 0
		for present in expected_edges do if present do expected_edge_count += 1
		if len(parsed.edges) != expected_edge_count do return false
		edges := graph_query_equivalence_edges()
		expected_edge_storage: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]pr.Edge
		parsed_index := 0
		for expected, edge_index in edges {
			if !expected_edges[edge_index] do continue
			actual := parsed.edges[parsed_index]
			expected_edge_storage[parsed_index] = {
				edge_id     = pr.EdgeID(edge_index + 1),
				conv_id     = GRAPH_HANDLER_TEST_CONV_ID,
				source_type = expected.source_type,
				source_id   = expected.source_id,
				target_type = expected.target_type,
				target_id   = expected.target_id,
				relation    = expected.relation,
			}
			if actual.edge_id != pr.EdgeID(edge_index + 1) ||
			   actual.conv_id != GRAPH_HANDLER_TEST_CONV_ID ||
			   actual.source_type != expected.source_type ||
			   actual.source_id != expected.source_id ||
			   actual.target_type != expected.target_type ||
			   actual.target_id != expected.target_id ||
			   actual.relation != expected.relation ||
			   actual.created_at != 0 ||
			   len(actual.created_by) != 0 {
				return false
			}
			parsed_index += 1
		}
		expected_message := pr.GraphQueryResultMessage {
			conv_id        = req.conv_id,
			start_type     = req.start_type,
			start_id       = req.start_id,
			truncated      = false,
			nodes          = expected_nodes[:expected_node_count],
			edges          = expected_edge_storage[:expected_edge_count],
			correlation_id = req.correlation_id,
		}
		expected_payload: [1_024]byte
		expected_len := pr.serializeGraphQueryResult(expected_message, expected_payload[:])
		if expected_len != len(payload) do return false
		for byte_value, byte_index in payload do if byte_value != expected_payload[byte_index] do return false
		return true
	}

	graph_query_equivalence_run :: proc(
		req: pr.GraphQueryRequest,
		edge_mask: u8,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Graph_Query_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Graph_Handler_Test_Context
		if !graph_handler_test_begin(&ctx) do return {}, "initialize graph query equivalence fixture", false
		defer graph_handler_test_end(&ctx)
		graph_query_equivalence_setup(&ctx, edge_mask)
		td.task_seq, td.asset_seq, td.edge_seq = 101, 202, 303
		before, before_ok := graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok do return {}, "capture graph query baseline", false
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		if through_wire {
			request_buf: [64]byte
			request_len := pr.serializeGraphQueryRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize graph query request", false
			if !handler_equivalence_deliver_wire(&ctx.sim.sim, ctx.conn, request_buf[:request_len], split_a, split_b) {
				return {}, "deliver split graph query request", false
			}
		} else {
			handle_graph_query(ctx.conn, req)
		}

		result: Graph_Query_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock) != 1 do return result, "unexpected graph query response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture graph query response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		if !graph_query_equivalence_response_matches_model(payload, req, edge_mask) {
			return result, "graph query response differs from independent model", false
		}
		result.state, before_ok = graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok || !graph_query_equivalence_states_equal(before, result.state) {
			return result, "graph query mutated server state", false
		}
		return result, "", true
	}

	graph_query_equivalence_results_equal :: proc(a, b: Graph_Query_Equivalence_Result) -> bool {
		if a.response_len != b.response_len do return false
		for index in 0 ..< a.response_len do if a.response[index] != b.response[index] do return false
		return graph_query_equivalence_states_equal(a.state, b.state)
	}

	prop_graph_query_parser_direct_semantic_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		edge_mask, edge_mask_err := hgl.draw_i64(tc, 0, 63)
		if edge_mask_err == .Stop_Test do return hgl.abort()
		if edge_mask_err != nil do return hgl.interesting("graph edge mask draw failed")
		start_index, start_err := hgl.draw_i64(tc, 0, GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT - 1)
		if start_err == .Stop_Test do return hgl.abort()
		if start_err != nil do return hgl.interesting("graph start entity draw failed")
		max_depth, depth_err := hgl.draw_i64(tc, 1, 4)
		if depth_err == .Stop_Test do return hgl.abort()
		if depth_err != nil do return hgl.interesting("graph depth draw failed")
		relation_mask, relation_err := hgl.draw_i64(tc, 0, 63)
		if relation_err == .Stop_Test do return hgl.abort()
		if relation_err != nil do return hgl.interesting("graph relation mask draw failed")
		direction, direction_err := hgl.draw_i64(tc, 0, 2)
		if direction_err == .Stop_Test do return hgl.abort()
		if direction_err != nil do return hgl.interesting("graph direction draw failed")
		flags, flags_err := hgl.draw_i64(tc, 0, 255)
		if flags_err == .Stop_Test do return hgl.abort()
		if flags_err != nil do return hgl.interesting("graph flags draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("graph correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("graph first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("graph second split draw failed")
		entities := graph_query_equivalence_entities()
		start := entities[start_index]
		req := pr.GraphQueryRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			start_type     = start.target_type,
			start_id       = start.target_id,
			max_depth      = u8(max_depth),
			relation_mask  = u16(relation_mask),
			direction      = pr.Direction(direction),
			flags          = u8(flags),
			correlation_id = u32(correlation),
		}
		direct, direct_reason, direct_ok := graph_query_equivalence_run(req, u8(edge_mask), false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := graph_query_equivalence_run(req, u8(edge_mask), true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !graph_query_equivalence_results_equal(direct, wire) do return hgl.interesting("direct and split-wire graph query semantics differ")
		return hgl.valid()
	}

	graph_query_equivalence_mandatory_cases :: proc(t: ^testing.T) -> bool {
		entities := graph_query_equivalence_entities()
		requests := [5]pr.GraphQueryRequest {
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, start_type = .Task, start_id = 1, max_depth = 4, direction = .Both, correlation_id = 0x7800},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, start_type = .Task, start_id = 1, max_depth = 2, direction = .Outgoing, correlation_id = 0x7801},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, start_type = .Asset, start_id = 2, max_depth = 3, direction = .Incoming, correlation_id = 0x7802},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				start_type = .Task,
				start_id = 2,
				max_depth = 4,
				relation_mask = 0b001000,
				direction = .Both,
				correlation_id = 0x7803,
			},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				start_type = entities[5].target_type,
				start_id = entities[5].target_id,
				max_depth = 1,
				relation_mask = 0b111111,
				direction = .Both,
				correlation_id = 0x7804,
			},
		}
		edge_masks := [5]u8{0b111111, 0b111111, 0b111111, 0b111111, 0}
		for req, case_index in requests {
			direct, direct_reason, direct_ok := graph_query_equivalence_run(req, edge_masks[case_index], false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory graph query case=%d direct failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := graph_query_equivalence_run(req, edge_masks[case_index], true, case_index + 2, case_index + 17)
			testing.expectf(t, wire_ok, "mandatory graph query case=%d wire failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := graph_query_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory graph query case=%d semantics should match", case_index)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_graph_query_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !graph_query_equivalence_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_graph_query_parser_direct_semantic_equivalence, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated graph query parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
