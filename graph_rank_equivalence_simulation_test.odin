package main

import "core:encoding/endian"
import "core:math"
import "core:testing"

import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: endian.get_u64
	_ :: hgl.run
	_ :: math.abs
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	GRAPH_RANK_EQ_MAX_ENTRIES :: 9
	GRAPH_RANK_EQ_DAMPING :: 0.85
	GRAPH_RANK_EQ_ITERATIONS :: 20
	GRAPH_RANK_EQ_TOLERANCE :: 1e-10

	Graph_Rank_EQ_Path :: struct {
		anchor_index: u8,
		depth:        u8,
		edge_ids:     [pr.MAX_GRAPH_RANK_DEPTH]pr.EdgeID,
		edge_count:   int,
	}

	Graph_Rank_EQ_Entry :: struct {
		target_type: pr.TargetType,
		target_id:   u64,
		score:       f64,
		paths:       [pr.MAX_GRAPH_RANK_ANCHORS]Graph_Rank_EQ_Path,
		path_count:  int,
	}

	Graph_Rank_EQ_Result :: struct {
		response:     [4_096]byte,
		response_len: int,
		state:        Graph_Query_Equivalence_State,
	}

	graph_rank_eq_entity_index :: proc(target_type: pr.TargetType, target_id: u64) -> int {
		entities := graph_query_equivalence_entities()
		for entity, entity_index in entities {
			if entity.target_type == target_type && entity.target_id == target_id do return entity_index
		}
		return -1
	}

	graph_rank_eq_relation_matches :: proc(relation: pr.RelationType, mask: u16) -> bool {
		if mask == 0 do return true
		raw := u16(relation)
		return raw >= 1 && raw <= 16 && mask & (u16(1) << (raw - 1)) != 0
	}

	graph_rank_eq_neighbor_index :: proc(edge: Graph_Query_Equivalence_Edge, entity_index: int, direction: pr.Direction) -> int {
		entities := graph_query_equivalence_entities()
		entity := entities[entity_index]
		if edge.source_type == entity.target_type && edge.source_id == entity.target_id && direction != .Incoming {
			return graph_rank_eq_entity_index(edge.target_type, edge.target_id)
		}
		if edge.target_type == entity.target_type && edge.target_id == entity.target_id && direction != .Outgoing {
			return graph_rank_eq_entity_index(edge.source_type, edge.source_id)
		}
		return -1
	}

	graph_rank_eq_entry_less :: proc(a, b: Graph_Rank_EQ_Entry) -> bool {
		if a.score != b.score do return a.score > b.score
		if a.target_type != b.target_type do return u16(a.target_type) < u16(b.target_type)
		return a.target_id < b.target_id
	}

	graph_rank_eq_expected :: proc(
		req: pr.GraphRankRequest,
		edge_mask: u8,
	) -> (
		entries: [GRAPH_RANK_EQ_MAX_ENTRIES]Graph_Rank_EQ_Entry,
		entry_count: int,
		used_edges: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]bool,
	) {
		entities := graph_query_equivalence_entities()
		edges := graph_query_equivalence_edges()
		union_nodes: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]bool
		union_edges: [GRAPH_QUERY_EQUIVALENCE_EDGE_COUNT]bool
		paths: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT][pr.MAX_GRAPH_RANK_ANCHORS]Graph_Rank_EQ_Path
		path_counts: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int

		for anchor_index in 0 ..< int(req.anchor_count) {
			anchor := graph_rank_eq_entity_index(req.anchors[anchor_index].target_type, req.anchors[anchor_index].target_id)
			if anchor < 0 do continue
			visited: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]bool
			depths: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]u8
			parents: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
			parent_edges: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
			for index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
				parents[index] = -1
				parent_edges[index] = -1
			}
			queue: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
			visited[anchor] = true
			parents[anchor] = anchor
			union_nodes[anchor] = true
			queue[0] = anchor
			queue_count := 1
			for queue_index := 0; queue_index < queue_count; queue_index += 1 {
				current := queue[queue_index]
				if depths[current] >= req.max_depth do continue
				for edge, edge_index in edges {
					if edge_mask & (u8(1) << u8(edge_index)) == 0 || !graph_rank_eq_relation_matches(edge.relation, req.relation_mask) {
						continue
					}
					neighbor := graph_rank_eq_neighbor_index(edge, current, req.direction)
					if neighbor < 0 do continue
					if !visited[neighbor] {
						visited[neighbor] = true
						depths[neighbor] = depths[current] + 1
						parents[neighbor] = current
						parent_edges[neighbor] = edge_index
						union_nodes[neighbor] = true
						queue[queue_count] = neighbor
						queue_count += 1
					}
					union_edges[edge_index] = true
				}
			}

			for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
				if !visited[entity_index] || entity_index == anchor do continue
				reversed: [pr.MAX_GRAPH_RANK_DEPTH]pr.EdgeID
				count := 0
				current := entity_index
				for current != anchor && count < len(reversed) {
					edge_index := parent_edges[current]
					if edge_index < 0 do break
					reversed[count] = pr.EdgeID(edge_index + 1)
					count += 1
					current = parents[current]
				}
				if current != anchor || count == 0 do continue
				path := &paths[entity_index][path_counts[entity_index]]
				path.anchor_index = u8(anchor_index)
				path.depth = depths[entity_index]
				path.edge_count = count
				for edge_index in 0 ..< count do path.edge_ids[edge_index] = reversed[count - edge_index - 1]
				path_counts[entity_index] += 1
			}
		}

		ranks: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]f64
		has_union_edge := false
		for present in union_edges do has_union_edge = has_union_edge || present
		if has_union_edge {
			personalization: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]f64
			weight_sum := 0.0
			for anchor_index in 0 ..< int(req.anchor_count) {
				weight := 1.0 / f64(anchor_index + 1)
				entity_index := graph_rank_eq_entity_index(req.anchors[anchor_index].target_type, req.anchors[anchor_index].target_id)
				if entity_index >= 0 do personalization[entity_index] = weight
				weight_sum += weight
			}
			if weight_sum > 0 do for &weight in personalization do weight /= weight_sum
			ranks = personalization
			degrees: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]int
			for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
				if !union_nodes[entity_index] do continue
				for edge, edge_index in edges {
					if !union_edges[edge_index] do continue
					if graph_rank_eq_neighbor_index(edge, entity_index, req.direction) >= 0 do degrees[entity_index] += 1
				}
			}
			for _ in 0 ..< GRAPH_RANK_EQ_ITERATIONS {
				next: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]f64
				for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
					next[entity_index] = (1.0 - GRAPH_RANK_EQ_DAMPING) * personalization[entity_index]
				}
				dangling := 0.0
				for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
					if !union_nodes[entity_index] do continue
					if degrees[entity_index] == 0 {
						dangling += ranks[entity_index]
						continue
					}
					share := GRAPH_RANK_EQ_DAMPING * ranks[entity_index] / f64(degrees[entity_index])
					for edge, edge_index in edges {
						if !union_edges[edge_index] do continue
						neighbor := graph_rank_eq_neighbor_index(edge, entity_index, req.direction)
						if neighbor >= 0 do next[neighbor] += share
					}
				}
				for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT {
					next[entity_index] += GRAPH_RANK_EQ_DAMPING * dangling * personalization[entity_index]
				}
				delta := 0.0
				for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT do delta += math.abs(next[entity_index] - ranks[entity_index])
				ranks = next
				if delta < GRAPH_RANK_EQ_TOLERANCE do break
			}
			max_score := 0.0
			for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT do if union_nodes[entity_index] do max_score = max(max_score, ranks[entity_index])
			if max_score > 0 {
				for entity_index in 0 ..< GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT do ranks[entity_index] = ranks[entity_index] / max_score * f64(req.anchor_count)
			}
		}

		requested: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]bool
		for candidate_index in 0 ..< int(req.candidate_count) {
			candidate := req.candidates[candidate_index]
			entity_index := graph_rank_eq_entity_index(candidate.target_type, candidate.target_id)
			entry := &entries[entry_count]
			entry.target_type = candidate.target_type
			entry.target_id = candidate.target_id
			if entity_index >= 0 {
				requested[entity_index] = true
				entry.score = ranks[entity_index]
				entry.path_count = path_counts[entity_index]
				copy(entry.paths[:], paths[entity_index][:])
			}
			entry_count += 1
		}
		graph_entries: [GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]Graph_Rank_EQ_Entry
		graph_count := 0
		for entity, entity_index in entities {
			if !union_nodes[entity_index] || requested[entity_index] do continue
			entry := Graph_Rank_EQ_Entry {
				target_type = entity.target_type,
				target_id   = entity.target_id,
				score       = ranks[entity_index],
				path_count  = path_counts[entity_index],
			}
			copy(entry.paths[:], paths[entity_index][:])
			insert_at := graph_count
			for existing, existing_index in graph_entries[:graph_count] {
				if graph_rank_eq_entry_less(entry, existing) {
					insert_at = existing_index
					break
				}
			}
			for index := graph_count; index > insert_at; index -= 1 do graph_entries[index] = graph_entries[index - 1]
			graph_entries[insert_at] = entry
			graph_count += 1
		}
		append_count := min(graph_count, int(req.top_n))
		copy(entries[entry_count:], graph_entries[:append_count])
		entry_count += append_count
		for entry_index in 0 ..< entry_count {
			for path_index in 0 ..< entries[entry_index].path_count {
				for edge_index in 0 ..< entries[entry_index].paths[path_index].edge_count {
					edge_id := entries[entry_index].paths[path_index].edge_ids[edge_index]
					used_edges[int(edge_id) - 1] = true
				}
			}
		}
		return
	}

	graph_rank_eq_read_response :: proc(payload: []byte, req: pr.GraphRankRequest, edge_mask: u8) -> bool {
		expected, expected_count, expected_edges := graph_rank_eq_expected(req, edge_mask)
		if len(payload) < 19 || pr.get_opcode(payload) != .S_GraphRankResult do return false
		offset := 2
		conv_id, conv_ok := endian.get_u64(payload[offset:], .Big)
		if !conv_ok || pr.ConversationID(conv_id) != req.conv_id do return false
		offset += 8
		if payload[offset] != 0 do return false
		offset += 1
		entry_count, count_ok := endian.get_u16(payload[offset:], .Big)
		if !count_ok || int(entry_count) != expected_count do return false
		offset += 2
		for expected_index in 0 ..< expected_count {
			expected_entry := &expected[expected_index]
			if offset + 19 > len(payload) do return false
			type_raw, type_ok := endian.get_u16(payload[offset:], .Big)
			id, id_ok := endian.get_u64(payload[offset + 2:], .Big)
			score_bits, score_ok := endian.get_u64(payload[offset + 10:], .Big)
			actual_score := transmute(f64)score_bits
			path_count := int(payload[offset + 18])
			if !type_ok ||
			   !id_ok ||
			   !score_ok ||
			   pr.TargetType(type_raw) != expected_entry.target_type ||
			   id != expected_entry.target_id ||
			   !(math.abs(actual_score - expected_entry.score) <= 1e-12) ||
			   path_count != expected_entry.path_count {
				return false
			}
			offset += 19
			for path_index in 0 ..< expected_entry.path_count {
				expected_path := &expected_entry.paths[path_index]
				if offset + 3 > len(payload) ||
				   payload[offset] != expected_path.anchor_index ||
				   payload[offset + 1] != expected_path.depth ||
				   int(payload[offset + 2]) != expected_path.edge_count {
					return false
				}
				offset += 3
				for edge_index in 0 ..< expected_path.edge_count {
					expected_edge_id := expected_path.edge_ids[edge_index]
					edge_id, edge_ok := endian.get_u64(payload[offset:], .Big)
					if !edge_ok || pr.EdgeID(edge_id) != expected_edge_id do return false
					offset += 8
				}
			}
		}
		if offset + 2 > len(payload) do return false
		edge_count, edge_count_ok := endian.get_u16(payload[offset:], .Big)
		if !edge_count_ok do return false
		offset += 2
		expected_edge_count := 0
		for present in expected_edges do if present do expected_edge_count += 1
		if int(edge_count) != expected_edge_count do return false
		edge_specs := graph_query_equivalence_edges()
		for edge, edge_index in edge_specs {
			if !expected_edges[edge_index] do continue
			if offset + 30 > len(payload) do return false
			edge_id, id_ok := endian.get_u64(payload[offset:], .Big)
			source_type, source_type_ok := endian.get_u16(payload[offset + 8:], .Big)
			source_id, source_id_ok := endian.get_u64(payload[offset + 10:], .Big)
			target_type, target_type_ok := endian.get_u16(payload[offset + 18:], .Big)
			target_id, target_id_ok := endian.get_u64(payload[offset + 20:], .Big)
			relation, relation_ok := endian.get_u16(payload[offset + 28:], .Big)
			if !id_ok ||
			   !source_type_ok ||
			   !source_id_ok ||
			   !target_type_ok ||
			   !target_id_ok ||
			   !relation_ok ||
			   pr.EdgeID(edge_id) != pr.EdgeID(edge_index + 1) ||
			   pr.TargetType(source_type) != edge.source_type ||
			   source_id != edge.source_id ||
			   pr.TargetType(target_type) != edge.target_type ||
			   target_id != edge.target_id ||
			   pr.RelationType(relation) != edge.relation {
				return false
			}
			offset += 30
		}
		if offset + 4 != len(payload) do return false
		correlation, correlation_ok := endian.get_u32(payload[offset:], .Big)
		return correlation_ok && correlation == req.correlation_id
	}

	graph_rank_eq_serialize_request :: proc(req: pr.GraphRankRequest, buf: []byte) -> int {
		size := 21 + (int(req.anchor_count) + int(req.candidate_count)) * 10
		if len(buf) < size do return -1
		offset := 0
		endian.put_u16(buf[offset:], .Big, u16(pr.Opcode.C_GraphRank)); offset += 2
		endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
		buf[offset] = req.anchor_count; offset += 1
		for entity_index in 0 ..< int(req.anchor_count) {
			entity := req.anchors[entity_index]
			endian.put_u16(buf[offset:], .Big, u16(entity.target_type)); offset += 2
			endian.put_u64(buf[offset:], .Big, entity.target_id); offset += 8
		}
		buf[offset] = req.candidate_count; offset += 1
		for entity_index in 0 ..< int(req.candidate_count) {
			entity := req.candidates[entity_index]
			endian.put_u16(buf[offset:], .Big, u16(entity.target_type)); offset += 2
			endian.put_u64(buf[offset:], .Big, entity.target_id); offset += 8
		}
		buf[offset] = req.max_depth; offset += 1
		endian.put_u16(buf[offset:], .Big, req.relation_mask); offset += 2
		buf[offset] = u8(req.direction); offset += 1
		buf[offset] = req.top_n; offset += 1
		endian.put_u32(buf[offset:], .Big, req.correlation_id); offset += 4
		return offset
	}

	graph_rank_eq_run :: proc(req: pr.GraphRankRequest, edge_mask: u8, through_wire: bool, split_a, split_b: int) -> (Graph_Rank_EQ_Result, string, bool) {
		ctx: Graph_Handler_Test_Context
		if !graph_handler_test_begin(&ctx) do return {}, "initialize graph rank equivalence fixture", false
		defer graph_handler_test_end(&ctx)
		graph_query_equivalence_setup(&ctx, edge_mask)
		// Stored adjacency is deliberately noncanonical. Production must sort a copy for
		// deterministic paths without mutating the conversation-owned slice.
		for entity in graph_query_equivalence_entities() {
			key := Edge_Entity_Key {
				target_type = entity.target_type,
				target_id   = entity.target_id,
			}
			adjacent := ctx.conv.edges_by_entity[key]
			for left, right := 0, len(adjacent) - 1; left < right; left, right = left + 1, right - 1 {
				adjacent[left], adjacent[right] = adjacent[right], adjacent[left]
			}
		}
		td.task_seq, td.asset_seq, td.edge_seq = 1_011, 1_022, 1_033
		before, before_ok := graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok do return {}, "capture graph rank baseline", false
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		if through_wire {
			request: [640]byte
			request_len := graph_rank_eq_serialize_request(req, request[:])
			if request_len <= 0 do return {}, "serialize graph rank request", false
			if !handler_equivalence_deliver_wire(&ctx.sim.sim, ctx.conn, request[:request_len], split_a, split_b) {
				return {}, "deliver split graph rank request", false
			}
		} else {
			handle_graph_rank(ctx.conn, req)
		}
		result: Graph_Rank_EQ_Result
		if nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock) != 1 do return result, "unexpected graph rank response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture graph rank response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		if !graph_rank_eq_read_response(payload, req, edge_mask) do return result, "graph rank response differs from independent model", false
		result.state, before_ok = graph_query_equivalence_capture_state(ctx.conv)
		if !before_ok || !graph_query_equivalence_states_equal(before, result.state) do return result, "graph rank query mutated server state", false
		return result, "", true
	}

	graph_rank_eq_results_equal :: proc(a, b: Graph_Rank_EQ_Result) -> bool {
		if a.response_len != b.response_len do return false
		for index in 0 ..< a.response_len do if a.response[index] != b.response[index] do return false
		return graph_query_equivalence_states_equal(a.state, b.state)
	}

	graph_rank_eq_request :: proc(edge_seed, anchor_seed, candidate_seed, options, correlation: i64) -> (pr.GraphRankRequest, u8) {
		entities := graph_query_equivalence_entities()
		anchor_count := int(anchor_seed % 5) + 1
		candidate_count := int(candidate_seed % 4)
		remaining_options := options
		max_depth := u8(remaining_options % 4 + 1)
		remaining_options /= 4
		relation_mask := u16(remaining_options % 64)
		remaining_options /= 64
		direction := pr.Direction(remaining_options % 3)
		remaining_options /= 3
		req := pr.GraphRankRequest {
			conv_id         = GRAPH_HANDLER_TEST_CONV_ID,
			anchor_count    = u8(anchor_count),
			candidate_count = u8(candidate_count),
			max_depth       = max_depth,
			relation_mask   = relation_mask,
			direction       = direction,
			top_n           = u8(remaining_options % 6 + 1),
			correlation_id  = u32(correlation),
		}
		start := int(anchor_seed / 5) % GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT
		for anchor_index in 0 ..< anchor_count {
			entity := entities[(start + anchor_index) % GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]
			req.anchors[anchor_index] = {
				target_type = entity.target_type,
				target_id   = entity.target_id,
			}
		}
		start = int(candidate_seed / 4) % GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT
		for candidate_index in 0 ..< candidate_count {
			entity := entities[(start + candidate_index) % GRAPH_QUERY_EQUIVALENCE_ENTITY_COUNT]
			req.candidates[candidate_index] = {
				target_type = entity.target_type,
				target_id   = entity.target_id,
			}
		}
		return req, u8(edge_seed)
	}

	prop_graph_rank_parser_direct_semantic_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		edge_seed, edge_err := hgl.draw_i64(tc, 0, 63)
		if edge_err == .Stop_Test do return hgl.abort()
		if edge_err != nil do return hgl.interesting("graph rank edge mask draw failed")
		anchor_seed, anchor_err := hgl.draw_i64(tc, 0, 89)
		if anchor_err == .Stop_Test do return hgl.abort()
		if anchor_err != nil do return hgl.interesting("graph rank anchor draw failed")
		candidate_seed, candidate_err := hgl.draw_i64(tc, 0, 95)
		if candidate_err == .Stop_Test do return hgl.abort()
		if candidate_err != nil do return hgl.interesting("graph rank candidate draw failed")
		options, options_err := hgl.draw_i64(tc, 0, 4_607)
		if options_err == .Stop_Test do return hgl.abort()
		if options_err != nil do return hgl.interesting("graph rank options draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("graph rank correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("graph rank first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("graph rank second split draw failed")
		req, edge_mask := graph_rank_eq_request(edge_seed, anchor_seed, candidate_seed, options, correlation)
		direct, direct_reason, direct_ok := graph_rank_eq_run(req, edge_mask, false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := graph_rank_eq_run(req, edge_mask, true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !graph_rank_eq_results_equal(direct, wire) do return hgl.interesting("direct and split-wire graph rank semantics differ")
		return hgl.valid()
	}

	graph_rank_eq_mandatory_cases :: proc(t: ^testing.T) -> bool {
		cases := [4]struct {
			edge_seed, anchor_seed, candidate_seed, options, correlation: i64,
		} {


			// Five weighted anchors, multiple candidates, both directions, maximum depth and top-N.
			{63, 4, 11, 3_843, 0x7101},
			// Empty graph: zero scores, no evidence paths, and stable requested-entry ordering.
			{0, 25, 3, 0, 0x7102},
			// References-only outgoing traversal.
			{63, 0, 22, 4_103, 0x7103},
			// DerivedFrom-or-Supersedes incoming traversal with distinct candidate ordering.
			{63, 0, 71, 2_241, 0x7104},
		}
		for values, case_index in cases {
			req, edge_mask := graph_rank_eq_request(values.edge_seed, values.anchor_seed, values.candidate_seed, values.options, values.correlation)
			direct, direct_reason, direct_ok := graph_rank_eq_run(req, edge_mask, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory graph rank case=%d direct failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			if case_index == 0 {
				corrupt := direct.response
				// First entry score starts after opcode, room, truncation, count, type, and ID.
				endian.put_u64(corrupt[23:], .Big, 0x7ff8_0000_0000_0000)
				rejects_nan := !graph_rank_eq_read_response(corrupt[:direct.response_len], req, edge_mask)
				testing.expect(t, rejects_nan, "graph rank response model should reject NaN scores")
				if !rejects_nan do return false
			}
			wire, wire_reason, wire_ok := graph_rank_eq_run(req, edge_mask, true, case_index + 5, case_index + 19)
			testing.expectf(t, wire_ok, "mandatory graph rank case=%d wire failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := graph_rank_eq_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory graph rank case=%d semantics should match", case_index)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_graph_rank_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !graph_rank_eq_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_graph_rank_parser_direct_semantic_equivalence, nil, {test_cases = 128})
		testing.expectf(t, err == nil, "generated graph rank parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
