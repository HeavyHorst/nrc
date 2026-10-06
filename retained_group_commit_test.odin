package main

import "core:log"
import "core:testing"
import "core:time"

import nbio "nbio/poly"
import pr "protocol"
import "storage_io"

@(test)
test_retained_group_commit_deadline_and_prefix :: proc(t: ^testing.T) {
	store := Message_Store {
		enabled = true,
	}
	store.wal.enabled = true
	store.wal.get_time = group_commit_test_clock
	group_commit_test_now = time.Time {
		_nsec = i64(time.Hour),
	}
	store.wal.pending_bytes = 1
	testing.expect(t, !schedule_retained_message_fsync(&store))
	testing.expect(t, store.commit_pending)
	started := store.commit_started
	group_commit_test_now._nsec += i64(RETAINED_COMMIT_WINDOW - time.Nanosecond)
	testing.expect(t, !retained_message_commit_due(&store))
	testing.expect(t, !schedule_retained_message_fsync(&store))
	testing.expect_value(t, store.commit_started, started)
	group_commit_test_now._nsec += 1
	testing.expect(t, retained_message_commit_due(&store))
	store.commit_started = group_commit_test_now
	store.wal.pending_bytes = RETAINED_COMMIT_MAX_BYTES
	testing.expect(t, retained_message_commit_due(&store))
	store.fsync_in_flight = true
	testing.expect(t, !retained_message_commit_due(&store))

	item := Send_Item {
		message_store      = &store,
		message_generation = 2,
		message_record     = 5,
	}
	store.active_generation = 2
	store.wal.durable_record_count = 4
	testing.expect(t, !outbox_item_is_durable(&item))
	store.wal.durable_record_count = 5
	testing.expect(t, outbox_item_is_durable(&item))
	store.active_generation = 4
	store.wal.durable_record_count = 0
	testing.expect(t, outbox_item_is_durable(&item))
	writer := Shard_Transaction_Writer{}
	writer.wal.enabled = true
	item.durability_writer = &writer
	item.durability_record = 1
	testing.expect(t, !outbox_item_is_durable(&item), "both stores must be durable")
	writer.wal.durable_record_count = 1
	testing.expect(t, outbox_item_is_durable(&item))
	store.poisoned = true
	testing.expect(t, !outbox_item_is_durable(&item), "rotation never bypasses a poisoned store")
}

when !NRC_SIMULATION {_ :: log.nil_logger; _ :: nbio.init; _ :: pr.SendMessageV2Request; _ :: storage_io.Context}

when NRC_SIMULATION {
	@(test)
	test_dual_store_waiter_rechecks_priority_head_after_inflight_pong :: proc(t: ^testing.T) {
		for message_first in ([2]bool{false, true}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			conn := simulation_test_install_client(&ctx.sim, 0, "dual-store-waiter", "alice", init_send_queue = true)
			ctx.conns[0] = conn
			if !testing.expect(t, conn != nil) do return
			writer: Shard_Transaction_Writer
			writer.wal.enabled = true
			defer delete(writer.durability_waiters)
			store: Message_Store
			store.wal.enabled = true
			defer delete(store.durability_waiters)
			for kind in 0 ..< 3 {
				buf, header_len := allocate_websocket_frame_buffer(0, "dual-store waiter test")
				if !testing.expect(t, buf != nil) do return
				item := Send_Item {
					handle = conn.handle,
					lease  = Frame_Lease(Pooled_Frame_Lease{data = buf[:header_len], pool = td.spool}),
				}
				if kind != 1 {
					item.message_store = &store
					item.message_record = 1
					if kind == 0 {item.durability_writer = &writer; item.durability_record = 1}
				} else {
					buf[0] = 0x8a // An independent empty Pong overtakes the blocked normal frame.
				}
				outbox_enqueue(conn, item, priority = kind != 0)
			}
			testing.expect(t, conn.is_sending && conn.outbox_waiting_durability)
			testing.expect_value(t, len(writer.durability_waiters), 1)
			testing.expect_value(t, len(store.durability_waiters), 0)
			if message_first {
				store.wal.durable_record_count = 1
				resume_durable_outboxes(&store.durability_waiters)
			} else {
				writer.wal.durable_record_count = 1
				resume_shard_durable_outboxes(&writer)
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), message_first ? 2 : 1)
			testing.expect(t, conn.outbox_waiting_durability && !conn.is_sending)
			if message_first {
				writer.wal.durable_record_count = 1
				resume_shard_durable_outboxes(&writer)
			} else {
				store.wal.durable_record_count = 1
				resume_durable_outboxes(&store.durability_waiters)
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 3)
			testing.expect_value(t, send_queue_len(conn), 0)
			testing.expect_value(t, conn.pending_io, u32(0))
			testing.expect(t, !conn.outbox_waiting_durability)
		}
	}

	@(test)
	test_retained_durability_wait_does_not_block_graceful_close :: proc(t: ^testing.T) {
		for peer_close in ([2]bool{false, true}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			workspace := "retained-close-waiter"
			storage := sim_world_storage_context(&ctx.sim.world)
			dir := "/retained-close-waiter"
			testing.expect(t, storage_io.make_directory(storage, dir) == nil)
			testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
			shard := int(shard_for_workspace(transmute([]byte)workspace))
			for &index in td.message_stores.store_index do index = -1
			append(&td.message_stores.stores, Message_Store{})
			store := &td.message_stores.stores[0]
			testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
			td.message_stores.enabled = true
			td.message_stores.store_index[shard] = 0
			defer shutdown_message_store_registry(&td.message_stores)
			conn := simulation_test_install_client(&ctx.sim, 0, workspace, "closing", init_send_queue = true)
			ctx.conns[0] = conn
			if !testing.expect(t, conn != nil) do return
			handle, sock := conn.handle, conn.sock
			req := pr.SendMessageV2Request {
				conv_id        = 42,
				correlation_id = 1,
				content_type   = .PlainText,
				content        = transmute([]byte)string("pending"),
			}
			req.client_message_id[0] = 1
			process_send_message_v2(conn, req)
			ok := simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok && conn.outbox_waiting_durability && !conn.is_sending)
			testing.expect_value(t, send_queue_priority_len(conn), 1)
			store.commit_started = {}
			testing.expect(t, schedule_retained_message_fsync(store))
			if peer_close {
				payload := [?]byte{0x03, 0xe8, 'b', 'y', 'e'}
				send_websocket_peer_close_reply(conn, payload[:])
			} else {
				send_websocket_close_frame_and_close(conn, 1000, "bye")
			}
			testing.expect(t, conn.is_sending, "close must bypass the undurable ACK without waiting for fsync")
			testing.expect_value(t, send_queue_len(conn), 0)
			// Exercise the wake both before physical close and after reclamation.
			if !peer_close do testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect(t, nrc_sim_client_has_close_frame(&ctx.sim, sock, 1000, "bye"))
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, sock, .S_AckSendMessage), 0)
			if !peer_close {
				nrc_sim_run_all_shutdown_sends(&ctx.sim)
				nrc_sim_run_all_timers(&ctx.sim)
			}
			nrc_sim_run_all_close_completions(&ctx.sim)
			if testing.expect(t, connection_get_by_handle(handle) == nil, "real close path must reclaim the connection") {
				ctx.conns[0] = nil
				connection_test_live_count -= 1
			}
			if peer_close do testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
			testing.expect_value(t, len(store.durability_waiters), 0)
			testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		}
	}

	@(test)
	test_retained_group_commit_ack_history_duplicate_and_failure :: proc(t: ^testing.T) {
		for fail_sync in ([2]bool{false, true}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			testing.expect(t, nbio.init(&td.io) == .NONE)
			defer nbio.destroy(&td.io)
			workspace := "retained-durable-outbox"
			conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
			peer := simulation_test_install_client(&ctx.sim, 2, workspace, "bob", init_send_queue = true)
			ctx.conns[1] = conn; ctx.conns[2] = peer
			testing.expect(t, conn != nil && peer != nil)
			if conn == nil || peer == nil do return
			subscribe_to_conversation(conn, 42)
			subscribe_to_conversation(peer, 42)
			nrc_sim_run_all_send_completions(&ctx.sim)
			nrc_sim_clear_inboxes(&ctx.sim)
			storage := sim_world_storage_context(&ctx.sim.world)
			dir := "/retained-durable-outbox"
			testing.expect(t, storage_io.make_directory(storage, dir) == nil)
			testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
			shard := int(shard_for_workspace(transmute([]byte)workspace))
			for &index in td.message_stores.store_index do index = -1
			append(&td.message_stores.stores, Message_Store{})
			store := &td.message_stores.stores[0]
			testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
			td.message_stores.enabled = true
			td.message_stores.store_index[shard] = 0
			defer shutdown_message_store_registry(&td.message_stores)
			req := pr.SendMessageV2Request {
				conv_id        = 42,
				correlation_id = 1,
				content        = transmute([]byte)string("durable"),
				content_type   = .PlainText,
			}
			req.client_message_id[0] = 1
			process_send_message_v2(conn, req)
			ok := simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok)
			testing.expect_value(t, store.wal.record_count, u64(1))
			testing.expect(t, conn.outbox_waiting_durability && peer.outbox_waiting_durability)
			store.commit_started = {}
			testing.expect(t, schedule_retained_message_fsync(store))
			// A duplicate and a history response must not leak the uncommitted prefix.
			req.correlation_id = 2
			process_send_message_v2(conn, req)
			ok = simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok)
			process_subscribe_conversations_v2(peer, pr.SubscribeConvsV2Request{conv_ids = []pr.ConversationID{42}, correlation_id = 6})
			process_message_history(peer, pr.MessageRangeRequest{conv_id = 42, limit = 10, correlation_id = 3}, true)
			for nrc_sim_run_next_file_read(&ctx.sim) {}
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 0)
			// Append behind the captured prefix: its ACK must need another fsync.
			req.client_message_id[0] = 2; req.correlation_id = 4
			process_send_message_v2(conn, req)
			ok = simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok)
			if fail_sync {
				previous_logger := context.logger
				context.logger = log.nil_logger()
				completed := nrc_sim_run_next_fsync_completion(&ctx.sim, .EIO)
				context.logger = previous_logger
				testing.expect(t, completed)
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect(t, store.poisoned)
				testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
				testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 0)
			} else {
				testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect_value(t, store.wal.durable_record_count, u64(1))
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 2)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_MessagePage), 2)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_SubscriptionReady), 1)
				store.commit_started = {}
				testing.expect(t, schedule_retained_message_fsync(store))
				testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 3)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_MessagePage), 3)
				// Rotation synchronously commits a pending prefix. Closing peers
				// must not be resumed, and waiting outboxes must not pin them.
				req.client_message_id[0] = 3; req.correlation_id = 5
				process_send_message_v2(conn, req)
				ok = simulation_test_flush_message_writes(&ctx.sim)
				testing.expect(t, ok && !store.fsync_in_flight)
				testing.expect_value(t, peer.pending_io, u32(0))
				peer.state = .Will_Close
				generation := store.active_generation
				testing.expect(t, rotate_message_store(store, nrc_time_unix_nanos()))
				testing.expect(t, store.active_generation > generation)
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 4)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_MessagePage), 3)
				testing.expect_value(t, len(store.durability_waiters), 0)
				peer.state = .Idle
			}
			testing.expect_value(t, conn.pending_io, u32(0))
			testing.expect_value(t, peer.pending_io, u32(0))
		}
	}
}
