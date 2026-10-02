// Opt-in comparison of the former five-neighborhood retrieval graph stage and
// the single server-ranked graph stage.
//
// Run with:
//   BENCH_GRAPH_RANK=1 odin test . -o:speed -define:NRC_SIMULATION=true \
//     -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 \
//     -define:ODIN_TEST_NAMES=main.benchmark_graph_rank_retrieval_stage
package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import pr "protocol"

GRAPH_RANK_BENCH_ANCHORS :: 5
GRAPH_RANK_BENCH_SHARED :: 40
GRAPH_RANK_BENCH_LEAVES_PER_SHARED :: 4

when !NRC_SIMULATION {
	_ :: fmt.printf
	_ :: os.lookup_env_alloc
	_ :: time.now
	_ :: pr.GraphRankRequest
}

when NRC_SIMULATION {
	graph_rank_benchmark_run_baseline :: proc(ctx: ^Graph_Handler_Test_Context, requests: ^[GRAPH_RANK_BENCH_ANCHORS]pr.GraphQueryRequest) -> int {
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		for request in requests do handle_graph_query(ctx.conn, request)
		nrc_sim_run_all_send_completions(&ctx.sim.sim)
		return nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock)
	}

	graph_rank_benchmark_run_proposed :: proc(ctx: ^Graph_Handler_Test_Context, request: pr.GraphRankRequest) -> int {
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		handle_graph_rank(ctx.conn, request)
		nrc_sim_run_all_send_completions(&ctx.sim.sim)
		return nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock)
	}

	graph_rank_benchmark_response_bytes :: proc(ctx: ^Graph_Handler_Test_Context) -> int {
		total := 0
		for i in 0 ..< nrc_sim_client_frame_count(&ctx.sim.sim, ctx.conn.sock) {
			total += len(nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, i))
		}
		return total
	}
}

@(test)
benchmark_graph_rank_retrieval_stage :: proc(t: ^testing.T) {
	enabled, found := os.lookup_env_alloc("BENCH_GRAPH_RANK", context.allocator)
	defer delete(enabled)
	if !found || enabled == "0" || enabled == "false" do return
	when !NRC_SIMULATION {
		testing.expect(t, false, "graph rank benchmark requires NRC_SIMULATION=true")
		return
	} else {
		ctx: Graph_Handler_Test_Context
		testing.expect(t, graph_handler_test_begin(&ctx), "graph rank benchmark fixture should initialize")
		defer graph_handler_test_end(&ctx)

		edge_id: pr.EdgeID = 1
		for anchor in 1 ..= GRAPH_RANK_BENCH_ANCHORS {
			for shared in 0 ..< GRAPH_RANK_BENCH_SHARED {
				graph_handler_test_add_edge(&ctx, edge_id, .Task, u64(anchor), .Asset, u64(1000 + shared), .References)
				edge_id += 1
			}
		}
		for shared in 0 ..< GRAPH_RANK_BENCH_SHARED {
			for leaf in 0 ..< GRAPH_RANK_BENCH_LEAVES_PER_SHARED {
				graph_handler_test_add_edge(
					&ctx,
					edge_id,
					.Asset,
					u64(1000 + shared),
					.Task,
					u64(2000 + shared * GRAPH_RANK_BENCH_LEAVES_PER_SHARED + leaf),
					.RelatedTo,
				)
				edge_id += 1
			}
		}

		baseline_requests: [GRAPH_RANK_BENCH_ANCHORS]pr.GraphQueryRequest
		proposed_request := pr.GraphRankRequest {
			conv_id         = GRAPH_HANDLER_TEST_CONV_ID,
			anchor_count    = GRAPH_RANK_BENCH_ANCHORS,
			candidate_count = pr.MAX_GRAPH_RANK_CANDIDATES,
			max_depth       = 2,
			direction       = .Both,
			top_n           = pr.MAX_GRAPH_RANK_CANDIDATES,
			correlation_id  = 1,
		}
		for i in 0 ..< GRAPH_RANK_BENCH_ANCHORS {
			anchor := pr.GraphEntityKey {
				target_type = .Task,
				target_id   = u64(i + 1),
			}
			proposed_request.anchors[i] = anchor
			proposed_request.candidates[i] = anchor
			baseline_requests[i] = {
				conv_id        = GRAPH_HANDLER_TEST_CONV_ID,
				start_type     = anchor.target_type,
				start_id       = anchor.target_id,
				max_depth      = 2,
				direction      = .Both,
				correlation_id = u32(i + 1),
			}
		}
		for i in GRAPH_RANK_BENCH_ANCHORS ..< 45 {
			proposed_request.candidates[i] = {
				target_type = .Asset,
				target_id   = u64(1000 + i - GRAPH_RANK_BENCH_ANCHORS),
			}
		}
		for i in 45 ..< pr.MAX_GRAPH_RANK_CANDIDATES {
			proposed_request.candidates[i] = {
				target_type = .Task,
				target_id   = u64(2000 + i - 45),
			}
		}

		_ = graph_rank_benchmark_run_baseline(&ctx, &baseline_requests)
		baseline_response_bytes := graph_rank_benchmark_response_bytes(&ctx)
		_ = graph_rank_benchmark_run_proposed(&ctx, proposed_request)
		proposed_response_bytes := graph_rank_benchmark_response_bytes(&ctx)
		payload_path, payload_path_found := os.lookup_env_alloc("NRC_GRAPH_RANK_BENCH_PAYLOAD", context.allocator)
		defer delete(payload_path)
		if payload_path_found && payload_path != "" {
			frame := nrc_sim_client_frame(&ctx.sim.sim, ctx.conn.sock, 0)
			payload, payload_ok := nrc_sim_frame_protocol_payload(frame)
			testing.expect(t, payload_ok && len(payload) > 2, "proposed graph rank payload should decode for export")
			if payload_ok && len(payload) > 2 {
				testing.expect(t, os.write_entire_file(payload_path, payload[2:]) == nil, "proposed graph rank payload should export")
			}
		}
		// Client WebSocket requests include protocol payloads and masking-frame overhead.
		baseline_request_bytes := GRAPH_RANK_BENCH_ANCHORS * (pr.getSizeGraphQueryRequest() + 6)
		proposed_protocol_bytes := 2 + 19 + (pr.MAX_GRAPH_RANK_ANCHORS + pr.MAX_GRAPH_RANK_CANDIDATES) * 10
		proposed_request_bytes := proposed_protocol_bytes + 8

		rounds := message_store_benchmark_env_int("NRC_GRAPH_RANK_BENCH_ROUNDS", 2000)
		order, _ := os.lookup_env_alloc("NRC_GRAPH_RANK_BENCH_ORDER", context.allocator)
		defer delete(order)
		baseline_elapsed: time.Duration
		proposed_elapsed: time.Duration
		checksum := 0
		if order == "proposed-first" {
			started := time.now()
			for _ in 0 ..< rounds do checksum += graph_rank_benchmark_run_proposed(&ctx, proposed_request)
			proposed_elapsed = time.since(started)
			started = time.now()
			for _ in 0 ..< rounds do checksum += graph_rank_benchmark_run_baseline(&ctx, &baseline_requests)
			baseline_elapsed = time.since(started)
		} else {
			started := time.now()
			for _ in 0 ..< rounds do checksum += graph_rank_benchmark_run_baseline(&ctx, &baseline_requests)
			baseline_elapsed = time.since(started)
			started = time.now()
			for _ in 0 ..< rounds do checksum += graph_rank_benchmark_run_proposed(&ctx, proposed_request)
			proposed_elapsed = time.since(started)
		}
		nrc_sim_clear_inboxes(&ctx.sim.sim)
		testing.expect_value(t, checksum, rounds * (GRAPH_RANK_BENCH_ANCHORS + 1))
		fmt.printf(
			"GRAPH_RANK_BENCH_RESULT rounds=%d nodes=%d edges=%d anchors=%d candidates=%d depth=2 order=%s baseline_total_ns=%d proposed_total_ns=%d baseline_request_bytes=%d baseline_response_bytes=%d proposed_request_bytes=%d proposed_response_bytes=%d\n",
			rounds,
			GRAPH_RANK_BENCH_ANCHORS + GRAPH_RANK_BENCH_SHARED + GRAPH_RANK_BENCH_SHARED * GRAPH_RANK_BENCH_LEAVES_PER_SHARED,
			int(edge_id - 1),
			GRAPH_RANK_BENCH_ANCHORS,
			pr.MAX_GRAPH_RANK_CANDIDATES,
			order,
			baseline_elapsed,
			proposed_elapsed,
			baseline_request_bytes,
			baseline_response_bytes,
			proposed_request_bytes,
			proposed_response_bytes,
		)
	}
}
