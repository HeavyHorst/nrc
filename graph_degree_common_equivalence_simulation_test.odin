package main

import "core:testing"

import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: hgl.run
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	graph_degree_entry_less_expected :: proc(a, b: pr.GraphDegreeEntry) -> bool {
		if a.degree != b.degree do return a.degree > b.degree
		if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
		return a.target_id < b.target_id
	}

	graph_degree_expected :: proc(req: pr.GraphDegreeRequest, edge_mask: u8) -> ([GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphDegreeEntry, int) {
		result: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphDegreeEntry
		result_count := 0
		entities := graph_query_equivalence_entities()
		edges := graph_query_equivalence_edges()
		for entity in entities {
			if req.type_filter == 1 && entity.target_type != .Asset do continue
			if req.type_filter == 2 && entity.target_type != .Task do continue
			degree: u16
			for edge, edge_index in edges {
				if edge_mask & (u8(1) << u8(edge_index)) == 0 do continue
				relation_bit := u16(1) << (u16(edge.relation) - 1)
				if req.relation_mask != 0 && req.relation_mask & relation_bit == 0 do continue
				if (edge.source_type == entity.target_type && edge.source_id == entity.target_id) ||
				   (edge.target_type == entity.target_type && edge.target_id == entity.target_id) {
					degree += 1
				}
			}
			if degree == 0 do continue
			entry := pr.GraphDegreeEntry {
				target_type = entity.target_type,
				target_id   = entity.target_id,
				degree      = degree,
			}
			insert_at := result_count
			for existing, existing_index in result[:result_count] {
				if graph_degree_entry_less_expected(entry, existing) {
					insert_at = existing_index
					break
				}
			}
			for index := result_count; index > insert_at; index -= 1 do result[index] = result[index - 1]
			result[insert_at] = entry
			result_count += 1
		}
		top_n := req.top_n
		if top_n == 0 || top_n > 100 do top_n = 100
		return result, min(result_count, int(top_n))
	}

	graph_degree_response_matches_model :: proc(payload: []byte, req: pr.GraphDegreeRequest, edge_mask: u8) -> bool {
		expected, expected_count := graph_degree_expected(req, edge_mask)
		parsed_entries: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphDegreeEntry
		parsed, parse_err := pr.parseGraphDegreeResult(payload, parsed_entries[:])
		if parse_err != nil || parsed.conv_id != req.conv_id || parsed.correlation_id != req.correlation_id || len(parsed.entries) != expected_count {
			return false
		}
		for entry, entry_index in parsed.entries do if entry != expected[entry_index] do return false
		expected_message := pr.GraphDegreeResultMessage {
			conv_id        = req.conv_id,
			entries        = expected[:expected_count],
			correlation_id = req.correlation_id,
		}
		expected_payload: [1_024]byte
		expected_len := pr.serializeGraphDegreeResult(expected_message, expected_payload[:])
		if expected_len != len(payload) do return false
		for byte_value, byte_index in payload do if byte_value != expected_payload[byte_index] do return false
		return true
	}

	graph_degree_equivalence_run :: proc(
		req: pr.GraphDegreeRequest,
		edge_mask: u8,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Graph_Query_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Graph_Handler_Test_Context
		if !graph_handler_test_begin(&ctx) do return {}, "initialize degree equivalence fixture", false
		defer graph_handler_test_end(&ctx)
		graph_query_equivalence_setup(&ctx, edge_mask)
		td.task_seq, td.asset_seq, td.edge_seq = 707, 808, 909
		before, before_ok := graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok do return {}, "capture degree baseline", false
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		if through_wire {
			request_buf: [32]byte
			request_len := pr.serializeGraphDegreeRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize degree request", false
			parsed_req, parse_err := pr.parseGraphDegreeRequest(request_buf[2:request_len])
			if parse_err != nil ||
			   parsed_req.conv_id != req.conv_id ||
			   parsed_req.top_n != req.top_n ||
			   parsed_req.type_filter != req.type_filter ||
			   parsed_req.relation_mask != req.relation_mask ||
			   parsed_req.correlation_id != req.correlation_id {
				return {}, "degree request parser changed serialized fields", false
			}
			if !handler_equivalence_deliver_wire(&ctx.sim.sim, ctx.conn, request_buf[:request_len], split_a, split_b) {
				return {}, "deliver split degree request", false
			}
		} else {
			handle_degree_query(ctx.conn, req)
		}

		result: Graph_Query_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock) != 1 do return result, "unexpected degree response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture degree response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		if !graph_degree_response_matches_model(payload, req, edge_mask) {
			return result, "degree response differs from independent model", false
		}
		result.state, before_ok = graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok || !graph_query_equivalence_states_equal(before, result.state) {
			return result, "degree query mutated server state", false
		}
		return result, "", true
	}

	graph_common_neighbor_index :: proc(edge: Graph_Query_Equivalence_Edge, entity_index: int, direction: pr.Direction) -> int {
		entities := graph_query_equivalence_entities()
		entity := entities[entity_index]
		if edge.source_type == entity.target_type && edge.source_id == entity.target_id && direction != .Incoming {
			return graph_shortest_path_entity_index(edge.target_type, edge.target_id)
		}
		if edge.target_type == entity.target_type && edge.target_id == entity.target_id && direction != .Outgoing {
			return graph_shortest_path_entity_index(edge.source_type, edge.source_id)
		}
		return -1
	}

	graph_common_neighbors_expected :: proc(
		req: pr.GraphCommonNeighborsRequest,
		edge_mask: u8,
	) -> (
		nodes: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphPathNode,
		node_count: int,
		edges: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]pr.Edge,
		edge_count: int,
		ok: bool,
	) {
		a_index := graph_shortest_path_entity_index(req.a_type, req.a_id)
		b_index := graph_shortest_path_entity_index(req.b_type, req.b_id)
		if a_index < 0 || b_index < 0 do return
		edge_specs := graph_query_equivalence_edges()
		a_neighbors: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]bool
		for edge, edge_index in edge_specs {
			if edge_mask & (u8(1) << u8(edge_index)) == 0 do continue
			relation_bit := u16(1) << (u16(edge.relation) - 1)
			if req.relation_mask != 0 && req.relation_mask & relation_bit == 0 do continue
			neighbor_index := graph_common_neighbor_index(edge, a_index, req.direction)
			if neighbor_index >= 0 && neighbor_index != b_index do a_neighbors[neighbor_index] = true
		}
		common: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]bool
		edge_present: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]bool
		for edge, edge_index in edge_specs {
			if edge_mask & (u8(1) << u8(edge_index)) == 0 do continue
			relation_bit := u16(1) << (u16(edge.relation) - 1)
			if req.relation_mask != 0 && req.relation_mask & relation_bit == 0 do continue
			neighbor_index := graph_common_neighbor_index(edge, b_index, req.direction)
			if neighbor_index >= 0 && a_neighbors[neighbor_index] {
				common[neighbor_index] = true
				edge_present[edge_index] = true
			}
		}
		for edge, edge_index in edge_specs {
			if edge_mask & (u8(1) << u8(edge_index)) == 0 do continue
			relation_bit := u16(1) << (u16(edge.relation) - 1)
			if req.relation_mask != 0 && req.relation_mask & relation_bit == 0 do continue
			neighbor_index := graph_common_neighbor_index(edge, a_index, req.direction)
			if neighbor_index >= 0 && common[neighbor_index] do edge_present[edge_index] = true
		}
		entities := graph_query_equivalence_entities()
		for entity, entity_index in entities {
			if !common[entity_index] do continue
			node := pr.GraphPathNode {
				target_type = entity.target_type,
				target_id   = entity.target_id,
			}
			insert_at := node_count
			for existing, existing_index in nodes[:node_count] {
				if node.target_type < existing.target_type || (node.target_type == existing.target_type && node.target_id < existing.target_id) {
					insert_at = existing_index
					break
				}
			}
			for index := node_count; index > insert_at; index -= 1 do nodes[index] = nodes[index - 1]
			nodes[insert_at] = node
			node_count += 1
		}
		for present, edge_index in edge_present {
			if !present do continue
			edges[edge_count] = graph_query_equivalence_expected_edge(edge_index)
			edge_count += 1
		}
		ok = true
		return
	}

	graph_common_neighbors_response_matches_model :: proc(payload: []byte, req: pr.GraphCommonNeighborsRequest, edge_mask: u8) -> bool {
		expected_nodes, expected_node_count, expected_edges, expected_edge_count, expected_ok := graph_common_neighbors_expected(req, edge_mask)
		if !expected_ok do return false
		parsed_nodes: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]pr.GraphPathNode
		parsed_edges: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]pr.Edge
		parsed, parse_err := pr.parseGraphCommonNeighborsResult(payload, parsed_nodes[:], parsed_edges[:])
		if parse_err != nil ||
		   parsed.conv_id != req.conv_id ||
		   parsed.a_type != req.a_type ||
		   parsed.a_id != req.a_id ||
		   parsed.b_type != req.b_type ||
		   parsed.b_id != req.b_id ||
		   parsed.correlation_id != req.correlation_id ||
		   len(parsed.nodes) != expected_node_count ||
		   len(parsed.edges) != expected_edge_count {
			return false
		}
		for node, node_index in parsed.nodes do if node != expected_nodes[node_index] do return false
		for edge, edge_index in parsed.edges {
			expected := expected_edges[edge_index]
			if edge.edge_id != expected.edge_id ||
			   edge.conv_id != expected.conv_id ||
			   edge.source_type != expected.source_type ||
			   edge.source_id != expected.source_id ||
			   edge.target_type != expected.target_type ||
			   edge.target_id != expected.target_id ||
			   edge.relation != expected.relation ||
			   edge.created_at != 0 ||
			   len(edge.created_by) != 0 {
				return false
			}
		}
		expected_message := pr.GraphCommonNeighborsResultMessage {
			conv_id        = req.conv_id,
			a_type         = req.a_type,
			a_id           = req.a_id,
			b_type         = req.b_type,
			b_id           = req.b_id,
			nodes          = expected_nodes[:expected_node_count],
			edges          = expected_edges[:expected_edge_count],
			correlation_id = req.correlation_id,
		}
		expected_payload: [1_024]byte
		expected_len := pr.serializeGraphCommonNeighborsResult(expected_message, expected_payload[:])
		if expected_len != len(payload) do return false
		for byte_value, byte_index in payload do if byte_value != expected_payload[byte_index] do return false
		return true
	}

	graph_common_neighbors_equivalence_run :: proc(
		req: pr.GraphCommonNeighborsRequest,
		edge_mask: u8,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Graph_Query_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Graph_Handler_Test_Context
		if !graph_handler_test_begin(&ctx) do return {}, "initialize common-neighbor equivalence fixture", false
		defer graph_handler_test_end(&ctx)
		graph_query_equivalence_setup(&ctx, edge_mask)
		td.task_seq, td.asset_seq, td.edge_seq = 710, 820, 930
		before, before_ok := graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok do return {}, "capture common-neighbor baseline", false
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		if through_wire {
			request_buf: [64]byte
			request_len := pr.serializeGraphCommonNeighborsRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize common-neighbor request", false
			parsed_req, parse_err := pr.parseGraphCommonNeighborsRequest(request_buf[2:request_len])
			if parse_err != nil ||
			   parsed_req.conv_id != req.conv_id ||
			   parsed_req.a_type != req.a_type ||
			   parsed_req.a_id != req.a_id ||
			   parsed_req.b_type != req.b_type ||
			   parsed_req.b_id != req.b_id ||
			   parsed_req.relation_mask != req.relation_mask ||
			   parsed_req.direction != req.direction ||
			   parsed_req.correlation_id != req.correlation_id {
				return {}, "common-neighbor request parser changed serialized fields", false
			}
			if !handler_equivalence_deliver_wire(&ctx.sim.sim, ctx.conn, request_buf[:request_len], split_a, split_b) {
				return {}, "deliver split common-neighbor request", false
			}
		} else {
			handle_common_neighbors(ctx.conn, req)
		}

		result: Graph_Query_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock) != 1 do return result, "unexpected common-neighbor response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture common-neighbor response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		if !graph_common_neighbors_response_matches_model(payload, req, edge_mask) {
			return result, "common-neighbor response differs from independent model", false
		}
		result.state, before_ok = graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok || !graph_query_equivalence_states_equal(before, result.state) {
			return result, "common-neighbor query mutated server state", false
		}
		return result, "", true
	}

	prop_graph_degree_parser_direct_semantic_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		edge_mask, edge_mask_err := hgl.draw_i64(tc, 0, 63)
		if edge_mask_err == .Stop_Test do return hgl.abort()
		if edge_mask_err != nil do return hgl.interesting("degree edge mask draw failed")
		top_n, top_n_err := hgl.draw_i64(tc, 0, 105)
		if top_n_err == .Stop_Test do return hgl.abort()
		if top_n_err != nil do return hgl.interesting("degree top-n draw failed")
		type_filter, type_err := hgl.draw_i64(tc, 0, 3)
		if type_err == .Stop_Test do return hgl.abort()
		if type_err != nil do return hgl.interesting("degree type filter draw failed")
		relation_mask, relation_err := hgl.draw_i64(tc, 0, 63)
		if relation_err == .Stop_Test do return hgl.abort()
		if relation_err != nil do return hgl.interesting("degree relation mask draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("degree correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("degree first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("degree second split draw failed")
		req := pr.GraphDegreeRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			top_n          = u16(top_n),
			type_filter    = u16(type_filter),
			relation_mask  = u16(relation_mask),
			correlation_id = u32(correlation),
		}
		direct, direct_reason, direct_ok := graph_degree_equivalence_run(req, u8(edge_mask), false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := graph_degree_equivalence_run(req, u8(edge_mask), true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !graph_query_equivalence_results_equal(direct, wire) do return hgl.interesting("direct and split-wire degree semantics differ")
		return hgl.valid()
	}

	prop_graph_common_neighbors_parser_direct_semantic_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		edge_mask, edge_mask_err := hgl.draw_i64(tc, 0, 63)
		if edge_mask_err == .Stop_Test do return hgl.abort()
		if edge_mask_err != nil do return hgl.interesting("common-neighbor edge mask draw failed")
		a_index, a_err := hgl.draw_i64(tc, 0, GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT - 1)
		if a_err == .Stop_Test do return hgl.abort()
		if a_err != nil do return hgl.interesting("common-neighbor first endpoint draw failed")
		b_index, b_err := hgl.draw_i64(tc, 0, GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT - 1)
		if b_err == .Stop_Test do return hgl.abort()
		if b_err != nil do return hgl.interesting("common-neighbor second endpoint draw failed")
		relation_mask, relation_err := hgl.draw_i64(tc, 0, 63)
		if relation_err == .Stop_Test do return hgl.abort()
		if relation_err != nil do return hgl.interesting("common-neighbor relation mask draw failed")
		direction, direction_err := hgl.draw_i64(tc, 0, 2)
		if direction_err == .Stop_Test do return hgl.abort()
		if direction_err != nil do return hgl.interesting("common-neighbor direction draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("common-neighbor correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("common-neighbor first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("common-neighbor second split draw failed")
		entities := graph_query_equivalence_entities()
		a, b := entities[a_index], entities[b_index]
		req := pr.GraphCommonNeighborsRequest {
			conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
			a_type         = a.target_type,
			a_id           = a.target_id,
			b_type         = b.target_type,
			b_id           = b.target_id,
			relation_mask  = u16(relation_mask),
			direction      = pr.Direction(direction),
			correlation_id = u32(correlation),
		}
		direct, direct_reason, direct_ok := graph_common_neighbors_equivalence_run(req, u8(edge_mask), false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := graph_common_neighbors_equivalence_run(req, u8(edge_mask), true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !graph_query_equivalence_results_equal(direct, wire) {
			return hgl.interesting("direct and split-wire common-neighbor semantics differ")
		}
		return hgl.valid()
	}

	graph_degree_mandatory_cases :: proc(t: ^testing.T) -> bool {
		testing.expect_value(t, normalize_graph_degree_top_n(0), u16(100))
		testing.expect_value(t, normalize_graph_degree_top_n(100), u16(100))
		testing.expect_value(t, normalize_graph_degree_top_n(101), u16(100))
		testing.expect_value(t, normalize_graph_degree_top_n(max(u16)), u16(100))
		requests := [6]pr.GraphDegreeRequest {
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, top_n = 1, correlation_id = 0x7A00},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, top_n = 0, correlation_id = 0x7A01},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, top_n = 100, type_filter = 1, correlation_id = 0x7A02},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, top_n = 100, type_filter = 2, correlation_id = 0x7A03},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, top_n = 100, relation_mask = 0b001000, correlation_id = 0x7A04},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, top_n = 101, type_filter = 3, relation_mask = 0b111111, correlation_id = 0x7A05},
		}
		for req, case_index in requests {
			direct, direct_reason, direct_ok := graph_degree_equivalence_run(req, 0b111111, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory degree case=%d direct failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := graph_degree_equivalence_run(req, 0b111111, true, case_index + 5, case_index + 23)
			testing.expectf(t, wire_ok, "mandatory degree case=%d wire failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := graph_query_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory degree case=%d semantics should match", case_index)
			if !equal do return false
		}
		return true
	}

	graph_common_neighbors_mandatory_cases :: proc(t: ^testing.T) -> bool {
		requests := [9]pr.GraphCommonNeighborsRequest {
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Task, a_id = 1, b_type = .Asset, b_id = 1, direction = .Both, correlation_id = 0x7B00},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Task, a_id = 1, b_type = .Asset, b_id = 1, direction = .Outgoing, correlation_id = 0x7B01},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Task, a_id = 1, b_type = .Asset, b_id = 1, direction = .Incoming, correlation_id = 0x7B02},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Task, a_id = 1, b_type = .Task, b_id = 2, direction = .Both, correlation_id = 0x7B03},
			{
				conv_id = GRAPH_HANDLER_TEST_CONV_ID,
				a_type = .Task,
				a_id = 1,
				b_type = .Asset,
				b_id = 1,
				relation_mask = 0b001000,
				direction = .Both,
				correlation_id = 0x7B04,
			},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Task, a_id = 99, b_type = .Task, b_id = 1, direction = .Both, correlation_id = 0x7B05},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Task, a_id = 1, b_type = .Task, b_id = 1, direction = .Both, correlation_id = 0x7B06},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Task, a_id = 3, b_type = .Asset, b_id = 2, direction = .Outgoing, correlation_id = 0x7B07},
			{conv_id = GRAPH_HANDLER_TEST_CONV_ID, a_type = .Asset, a_id = 1, b_type = .Asset, b_id = 2, direction = .Incoming, correlation_id = 0x7B08},
		}
		for req, case_index in requests {
			direct, direct_reason, direct_ok := graph_common_neighbors_equivalence_run(req, 0b111111, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory common-neighbor case=%d direct failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := graph_common_neighbors_equivalence_run(req, 0b111111, true, case_index + 7, case_index + 29)
			testing.expectf(t, wire_ok, "mandatory common-neighbor case=%d wire failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := graph_query_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory common-neighbor case=%d semantics should match", case_index)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_graph_degree_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !graph_degree_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_graph_degree_parser_direct_semantic_equivalence, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated degree parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_graph_common_neighbors_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !graph_common_neighbors_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_graph_common_neighbors_parser_direct_semantic_equivalence, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated common-neighbor parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
