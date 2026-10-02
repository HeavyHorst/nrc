package main

import "core:mem/virtual"
import "core:testing"

import pr "protocol"

when !NRC_SIMULATION {
	_ :: virtual.Arena
	_ :: pr.Opcode
}

@(test)
test_graph_rank_selective_links_paths_and_normalization :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Graph_Handler_Test_Context
		if !graph_handler_test_begin(&ctx) {
			testing.expect(t, false, "graph rank fixture should initialize")
			return
		}
		defer graph_handler_test_end(&ctx)
		graph_handler_test_add_edge(&ctx, 1, .Task, 1, .Asset, 3, .References)
		graph_handler_test_add_edge(&ctx, 2, .Task, 1, .Asset, 5, .References)
		graph_handler_test_add_edge(&ctx, 3, .Task, 1, .Asset, 6, .References)
		graph_handler_test_add_edge(&ctx, 4, .Task, 1, .Asset, 7, .References)
		graph_handler_test_add_edge(&ctx, 5, .Task, 2, .Asset, 4, .References)

		req := pr.GraphRankRequest {
			conv_id      = GRAPH_HANDLER_TEST_CONV_ID,
			anchor_count = 2,
			max_depth    = 1,
			direction    = .Outgoing,
			top_n        = 10,
		}
		req.anchors[0] = {
			target_type = .Task,
			target_id   = 1,
		}
		req.anchors[1] = {
			target_type = .Task,
			target_id   = 2,
		}

		arena: virtual.Arena
		testing.expect(t, virtual.arena_init_growing(&arena) == nil, "graph rank arena should initialize")
		defer virtual.arena_destroy(&arena)
		alloc := virtual.arena_allocator(&arena)
		nodes := make(map[Edge_Entity_Key]bool, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
		edges := make(map[pr.EdgeID]bool, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
		paths := make(map[Edge_Entity_Key]Graph_Rank_Path_List, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
		ordered_adjacency := make(Graph_Rank_Ordered_Adjacency, MAX_GRAPH_RANK_UNION_NODES, allocator = alloc)
		for i := 0; i < int(req.anchor_count); i += 1 {
			truncated := graph_rank_collect_anchor(ctx.conv, req, i, &nodes, &edges, &paths, &ordered_adjacency, alloc)
			testing.expect(t, !truncated, "small graph should not truncate")
		}
		ranks := graph_rank_scores(ctx.conv, req, nodes, edges, alloc)
		broad := Edge_Entity_Key {
			target_type = .Asset,
			target_id   = 3,
		}
		selective := Edge_Entity_Key {
			target_type = .Asset,
			target_id   = 4,
		}
		testing.expect(t, ranks[selective] > ranks[broad], "selective link should outrank broad link")
		max_score := 0.0
		for _, score in ranks do max_score = max(max_score, score)
		testing.expect_value(t, max_score, 2.0)
		testing.expect_value(t, len(paths[broad]), 1)
		if len(paths[broad]) == 1 {
			testing.expect_value(t, paths[broad][0].anchor_index, u8(0))
			testing.expect_value(t, paths[broad][0].depth, u8(1))
			testing.expect_value(t, paths[broad][0].edge_ids[0], pr.EdgeID(1))
		}

		incoming_req := req
		incoming_req.anchor_count = 1
		incoming_req.direction = .Incoming
		incoming_nodes := make(map[Edge_Entity_Key]bool, MAX_RESULT_NODES, allocator = alloc)
		incoming_edges := make(map[pr.EdgeID]bool, MAX_RESULT_NODES, allocator = alloc)
		incoming_paths := make(map[Edge_Entity_Key]Graph_Rank_Path_List, MAX_RESULT_NODES, allocator = alloc)
		incoming_ordered_adjacency := make(Graph_Rank_Ordered_Adjacency, MAX_RESULT_NODES, allocator = alloc)
		_ = graph_rank_collect_anchor(ctx.conv, incoming_req, 0, &incoming_nodes, &incoming_edges, &incoming_paths, &incoming_ordered_adjacency, alloc)
		incoming_ranks := graph_rank_scores(ctx.conv, incoming_req, incoming_nodes, incoming_edges, alloc)
		testing.expect_value(t, len(incoming_nodes), 1)
		testing.expect_value(t, incoming_ranks[Edge_Entity_Key{target_type = .Task, target_id = 1}], 0.0)
	}
}

@(test)
test_graph_rank_handler_emits_single_bounded_response :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Graph_Handler_Test_Context
		if !graph_handler_test_begin(&ctx) {
			testing.expect(t, false, "graph rank fixture should initialize")
			return
		}
		defer graph_handler_test_end(&ctx)
		graph_handler_test_add_edge(&ctx, 10, .Task, 1, .Asset, 2, .RelatedTo)
		req := pr.GraphRankRequest {
			conv_id         = GRAPH_HANDLER_TEST_CONV_ID,
			anchor_count    = 1,
			candidate_count = 1,
			max_depth       = 1,
			direction       = .Both,
			top_n           = 10,
			correlation_id  = 77,
		}
		req.anchors[0] = {
			target_type = .Task,
			target_id   = 1,
		}
		req.candidates[0] = req.anchors[0]
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		handle_graph_rank(ctx.conn, req)
		payload, ok := graph_handler_test_payload(t, &ctx, .S_GraphRankResult)
		testing.expect(t, ok, "graph rank response should be captured")
		if ok {
			testing.expect(t, len(payload) < pr.MAX_ALLOWED_CONTENT_LENGTH, "bounded graph rank response should fit one protocol message")
		}
	}
}
