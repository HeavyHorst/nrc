package main

import "core:testing"

import pr "protocol"

when !NRC_SIMULATION {
	_ :: pr.Opcode
}

@(test)
test_rss_memory_mb_from_statm_handles_metric_and_page_size_failures :: proc(t: ^testing.T) {
	valid_statm := "2048 1024 0 0 0 0 0\n"
	valid := transmute([]byte)valid_statm
	testing.expect_value(t, rss_memory_mb_from_statm(valid, 4096), u32(4))
	testing.expect_value(t, rss_memory_mb_from_statm(nil, 4096), u32(0))
	invalid_statm := "2048 invalid 0\n"
	testing.expect_value(t, rss_memory_mb_from_statm(transmute([]byte)invalid_statm, 4096), u32(0))
	testing.expect_value(t, rss_memory_mb_from_statm(valid, 0), u32(0))
	testing.expect_value(t, rss_memory_mb_from_statm(valid, -1), u32(0))
}

@(test)
test_simulation_process_stats_and_ping_protocol_responses :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 117)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 1, "stats-ping", "observer", true)
		testing.expect(t, conn != nil, "stats/ping client should install")
		if conn == nil do return
		ctx.conns[1] = conn

		// Keep this response deterministic and cover an empty metric snapshot.
		td.cached_rss_mb = 0
		td.last_rss_update = nrc_time_now()

		stats_correlation_token :: i64(0x1122_3344_5566_7788)
		process_stats(conn, pr.StatsRequest{timestamp = stats_correlation_token})

		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
		stats_payload, stats_payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, 0))
		testing.expect(t, stats_payload_ok, "stats response should be a complete WebSocket frame")
		if !stats_payload_ok do return
		testing.expect_value(t, pr.get_opcode(stats_payload), pr.Opcode.S_StatsResponse)
		stats, stats_err := pr.parseStatsResponseMessage(stats_payload)
		testing.expect(t, stats_err == nil, "stats response should parse")
		if stats_err != nil do return

		testing.expect_value(t, stats.timestamp, stats_correlation_token)
		testing.expect_value(t, stats.server_timestamp, NRC_SIM_TIME_EPOCH_NANOS)
		testing.expect_value(t, stats.thread_id, u32(117))
		testing.expect_value(t, stats.connections, u32(1))
		testing.expect_value(t, stats.memory_total_mb, u32(0))
		testing.expect_value(t, stats.buffer_pool_percent, u32(0))
		testing.expect_value(t, stats.io_pending, u32(0))
		testing.expect_value(t, stats.io_total_completions, u64(0))
		testing.expect_value(t, stats.io_total_latency_ns, u64(0))
		testing.expect_value(t, stats.io_latency_count, u64(0))
		testing.expect_value(t, stats.send_queue_depth, u32(0))
		testing.expect(t, !stats.send_backpressure, "empty send queue should not report backpressure")
		testing.expect_value(t, stats.send_dropped, u32(0))
		testing.expect_value(t, stats.wal_file_size, u64(0))
		testing.expect_value(t, stats.wal_pending_bytes, u64(0))
		testing.expect_value(t, stats.wal_record_count, u64(0))
		testing.expect_value(t, stats.wal_fsync_count, u64(0))
		testing.expect_value(t, stats.wal_total_fsync_ns, u64(0))
		testing.expect_value(t, stats.wal_total_write_ns, u64(0))
		testing.expect_value(t, stats.wal_write_count, u64(0))
		testing.expect_value(t, stats.wal_details_count, pr.PONG_WAL_DETAIL_MAX_COUNT)
		testing.expect_value(t, stats.shard_sweep_version, pr.PONG_SHARD_SWEEP_VERSION)
		testing.expect_value(t, stats.shard_sweep.runs_total, u64(0))
		testing.expect_value(t, stats.shard_sweep.replay_read_bytes_total, u64(0))
		testing.expect_value(t, stats.shard_sweep.metadata_fallbacks_total, u64(0))
		for detail in stats.wal_details {
			testing.expect(t, !detail.enabled, "empty WAL detail should be disabled")
			testing.expect_value(t, detail.file_size, u64(0))
			testing.expect_value(t, detail.pending_bytes, u64(0))
			testing.expect_value(t, detail.record_count, u64(0))
		}

		ping_correlation_token :: i64(0x0102_0304_0506_0708)
		process_ping(conn, pr.PingRequest{timestamp = ping_correlation_token})
		nrc_sim_run_all_send_completions(&ctx.sim)

		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 2)
		pong_payload, pong_payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, 1))
		testing.expect(t, pong_payload_ok, "pong response should be a complete WebSocket frame")
		if !pong_payload_ok do return
		testing.expect_value(t, pr.get_opcode(pong_payload), pr.Opcode.S_Pong)
		pong, pong_err := pr.parsePongResponseMessage(pong_payload)
		testing.expect(t, pong_err == nil, "pong response should parse")
		if pong_err != nil do return
		testing.expect_value(t, pong.timestamp, ping_correlation_token)
		testing.expect_value(t, pong.server_timestamp, NRC_SIM_TIME_EPOCH_NANOS)
	}
}
