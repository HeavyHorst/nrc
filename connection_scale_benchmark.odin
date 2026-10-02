//
// connection_scale_benchmark.odin - Synthetic per-worker connection scale probe
//
// Populates one worker to its hard connection limit without opening real sockets,
// then times connection-count-sensitive control paths. This is opt-in because the
// fixture intentionally retains tens of thousands of full NRC_Connection values.
//
// Run with:
//   BENCH_MAX_CONNECTION_SCALE=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false \
//     -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_max_connection_scale
//
package main

import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:testing"
import "core:time"

@(test)
benchmark_max_connection_scale :: proc(t: ^testing.T) {
	enabled, ok := os.lookup_env_alloc("BENCH_MAX_CONNECTION_SCALE", context.allocator)
	defer delete(enabled)
	if !ok || enabled == "0" || enabled == "false" {
		return
	}

	worker_state_init_core(nil, 128)
	defer worker_state_destroy_core_for_test()

	connections := make([dynamic]^NRC_Connection, 0, MAX_CONNECTIONS_PER_THREAD)
	defer delete(connections)
	workspace := get_or_create_workspace("max-connection-scale")
	baseline_rss_mb := get_rss_memory_mb()

	setup_started_at := nrc_time_now_monotonic()
	for i in 0 ..< MAX_CONNECTIONS_PER_THREAD {
		username := intern_username(fmt.tprintf("scale-user-%d", i))
		conn := connection_test_install_fake(
			Fake_Connection_Options {
				sock = net.TCP_Socket(10_000 + i),
				state = .Active,
				workspace_id = "max-connection-scale",
				verified_username = username,
				authenticated = true,
				track_active_socket = true,
			},
		)
		if conn == nil {
			testing.expectf(t, false, "connection allocation failed at %d of %d", i, MAX_CONNECTIONS_PER_THREAD)
			break
		}
		conn.workspace = workspace
		append(&connections, conn)
	}
	connection_setup_elapsed := time.diff(setup_started_at, nrc_time_now_monotonic())
	testing.expect_value(t, len(connections), MAX_CONNECTIONS_PER_THREAD)
	testing.expect_value(t, td.connection_count, MAX_CONNECTIONS_PER_THREAD)
	connections_rss_mb := get_rss_memory_mb()

	index_started_at := nrc_time_now_monotonic()
	for conn in connections {
		track_user_connection(conn)
	}
	index_elapsed := time.diff(index_started_at, nrc_time_now_monotonic())
	indexed_rss_mb := get_rss_memory_mb()

	// Idle maintenance must inspect exactly one fixed socket-table slice no matter
	// how many connections exist. Repeating it amortizes timer noise in the probe.
	IDLE_ITERATIONS :: 1_000
	td.idle_scan_cursor = 0
	maintenance_now := nrc_time_now_monotonic()
	idle_started_at := nrc_time_now_monotonic()
	for _ in 0 ..< IDLE_ITERATIONS {
		check_idle_connections(maintenance_now)
	}
	idle_elapsed := time.diff(idle_started_at, nrc_time_now_monotonic())

	// An empty watchdog should remain independent of total connection count.
	WATCHDOG_EMPTY_ITERATIONS :: 100_000
	watchdog_empty_started_at := nrc_time_now_monotonic()
	for _ in 0 ..< WATCHDOG_EMPTY_ITERATIONS {
		check_stalled_sends(maintenance_now)
	}
	watchdog_empty_elapsed := time.diff(watchdog_empty_started_at, nrc_time_now_monotonic())

	// A saturated watchdog is legitimately O(in-flight), not O(connections). Time
	// the hard upper bound separately from the common empty-index check.
	send_started_at := nrc_time_now_monotonic()
	for conn in connections {
		conn.is_sending = true
		conn.send_started_at = send_started_at
		send_watchdog_track(conn)
	}
	watchdog_full_started_at := nrc_time_now_monotonic()
	check_stalled_sends(nrc_time_now_monotonic())
	watchdog_full_elapsed := time.diff(watchdog_full_started_at, nrc_time_now_monotonic())
	for conn in connections {
		send_watchdog_untrack(conn)
		conn.is_sending = false
		conn.send_started_at = {}
	}

	// This lookup is intentionally included to expose any worker-wide user/socket
	// scan. The requested user is absent, forcing its worst case.
	USER_LOOKUP_ITERATIONS :: 100
	user_lookup_results := 0
	user_lookup_started_at := nrc_time_now_monotonic()
	for _ in 0 ..< USER_LOOKUP_ITERATIONS {
		sockets := get_user_sockets(workspace, "absent-user")
		user_lookup_results += len(sockets)
		delete(sockets)
	}
	user_lookup_elapsed := time.diff(user_lookup_started_at, nrc_time_now_monotonic())
	testing.expect_value(t, user_lookup_results, 0)

	// Queue all connections, then prove one worker turn drains only the configured
	// batch. The remaining full drain measures aggregate work, not turn latency.
	for conn in connections {
		deferred_outbox_enqueue(conn)
	}
	testing.expect_value(t, deferred_outbox_pump_count(), MAX_CONNECTIONS_PER_THREAD)
	deferred_batch_started_at := nrc_time_now_monotonic()
	deferred_batch_drained := drain_deferred_outbox_pumps()
	deferred_batch_elapsed := time.diff(deferred_batch_started_at, nrc_time_now_monotonic())
	testing.expect_value(t, deferred_batch_drained, true)
	testing.expect_value(t, deferred_outbox_pump_count(), MAX_CONNECTIONS_PER_THREAD - Deferred_Outbox_Publish_Batch)

	deferred_full_started_at := nrc_time_now_monotonic()
	deferred_turns := 1
	for drain_deferred_outbox_pumps() {
		deferred_turns += 1
	}
	deferred_full_elapsed := time.diff(deferred_full_started_at, nrc_time_now_monotonic())
	testing.expect_value(t, deferred_turns, (MAX_CONNECTIONS_PER_THREAD + Deferred_Outbox_Publish_Batch - 1) / Deferred_Outbox_Publish_Batch)

	// Closed generations can temporarily occupy the fixed ring. Filling it with
	// stale handles exercises the rare allocation-free capacity-recovery scan.
	for i in 0 ..< Deferred_Outbox_Max_Handles {
		stale := Connection_Handle {
			idx = u32(100_000 + i),
			gen = 777,
		}
		if pushed, _ := queue.push_back(&td.deferred_outbox_handles, stale); !pushed {
			testing.expect(t, false, "failed to fill deferred queue with stale handles")
			break
		}
	}
	compaction_started_at := nrc_time_now_monotonic()
	deferred_outbox_enqueue(connections[0])
	compaction_elapsed := time.diff(compaction_started_at, nrc_time_now_monotonic())
	testing.expect_value(t, deferred_outbox_pump_count(), 1)
	testing.expect_value(t, drain_deferred_outbox_pumps(), true)

	log.infof("=== Max Connection Scale Probe ===")
	log.infof(
		"connections=%d connection_struct=%dB close_frame_offset=%d connection_rss_delta=%dMB setup=%v",
		len(connections),
		size_of(NRC_Connection),
		offset_of(NRC_Connection, close_frame_buf),
		connections_rss_mb - baseline_rss_mb,
		connection_setup_elapsed,
	)
	log.infof(
		"user_index_rss_delta=%dMB index_build=%v total_rss_delta=%dMB",
		indexed_rss_mb - connections_rss_mb,
		index_elapsed,
		indexed_rss_mb - baseline_rss_mb,
	)
	log.infof(
		"idle_slice=%dns/tick slots=%d empty_watchdog=%dns/check full_watchdog=%v",
		time.duration_nanoseconds(idle_elapsed) / IDLE_ITERATIONS,
		Idle_Scan_Slots_Per_Tick,
		time.duration_nanoseconds(watchdog_empty_elapsed) / WATCHDOG_EMPTY_ITERATIONS,
		watchdog_full_elapsed,
	)
	log.infof(
		"absent_user_lookup=%dns/lookup deferred_batch_%d=%v deferred_remaining=%v turns=%d stale_compaction=%v",
		time.duration_nanoseconds(user_lookup_elapsed) / USER_LOOKUP_ITERATIONS,
		Deferred_Outbox_Publish_Batch,
		deferred_batch_elapsed,
		deferred_full_elapsed,
		deferred_turns,
		compaction_elapsed,
	)

	for conn in connections {
		connection_test_uninstall(conn)
	}
	testing.expect_value(t, td.connection_count, 0)
}
