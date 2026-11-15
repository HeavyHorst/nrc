package main

import "core:log"
import "core:testing"
import "core:time"

import nbio "nbio/poly"
import pr "protocol"
import "storage_io"

@(thread_local)
group_commit_test_now: time.Time

group_commit_test_clock :: proc "contextless" () -> time.Time {return group_commit_test_now}

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
	store.poisoned = true
	testing.expect(t, !outbox_item_is_durable(&item), "rotation never bypasses a poisoned store")
}

when !NRC_SIMULATION {_ :: log.nil_logger; _ :: nbio.init; _ :: pr.SendMessageV2Request; _ :: storage_io.Context}

when NRC_SIMULATION {
	// Membership is the cache installed by a committed SQLite completion. Only
	// retained-message storage uses the virtual disk in these tests.
	retained_dm_simulation_store :: proc(ctx: ^Sim_Test_Context, workspace: string) -> ^Message_Store {
		storage := sim_world_storage_context(&ctx.sim.world)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		if storage_io.make_directory(storage, "/dm-messages") != nil || storage_io.sync_directory(storage, "/") != nil do return nil
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		if !init_message_store_with_storage(&td.message_stores.stores[0], storage, "/dm-messages", shard, time.Hour, 0) do return nil
		td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
		for name, index in ([2]string{"alice", "bob"}) {
			ctx.conns[index] = simulation_test_install_client(&ctx.sim, index, workspace, name, init_send_queue = true)
			if ctx.conns[index] == nil do return nil
			on_user_connect(get_connection_workspace(ctx.conns[index]), intern_username(name), true)
		}
		return &td.message_stores.stores[0]
	}

	retained_dm_committed_members :: proc(c: ^NRC_Connection, members: u8) {
		worker_db_apply_dm_state(
			get_connection_workspace(c),
			{id = pr.make_dm_conversation_id("alice", "bob"), user_a = "alice", user_b = "bob", members = members},
		)
	}

	@(test)
	test_retained_dm_membership_crash_and_io_failures :: proc(t: ^testing.T) {
		// 0: crash before write; 1: crash after write; 2: successful fsync;
		// 3/4: write EIO/ENOSPC; 5: fsync EIO. Only case 2 commits the body.
		// Start/leave/reopen membership is already committed by SQLite; this
		// matrix tests retained-body recovery, not SQLite crash recovery.
		for operation in 0 ..< 3 {
			for boundary in 0 ..< 6 {
				ctx: Sim_Test_Context
				simulation_test_begin(&ctx)
				defer simulation_test_end(&ctx)
				testing.expect(t, nbio.init(&td.io) == .NONE)
				defer nbio.destroy(&td.io)
				workspace := "dm-crash-failure-matrix"
				store := retained_dm_simulation_store(&ctx, workspace)
				defer shutdown_message_store_registry(&td.message_stores)
				if !testing.expect(t, store != nil) do return
				alice, bob := ctx.conns[0], ctx.conns[1]
				id := pr.make_dm_conversation_id("alice", "bob")
				retained_dm_committed_members(alice, 3)
				subscribe_to_dm_internal(alice, id)
				subscribe_to_dm_internal(bob, id)
				if operation > 0 {
					seed := pr.SendMessageV2Request {
						conv_id      = id,
						content_type = .PlainText,
						content      = transmute([]byte)string("existing private body"),
					}
					seed.client_message_id[0] = 2
					process_send_message_v2(bob, seed)
					testing.expect(t, simulation_test_commit_messages(&ctx.sim))
				}
				if operation == 2 {
					retained_dm_committed_members(alice, 2)
				}
				nrc_sim_clear_inboxes(&ctx.sim)
				expected := operation == 1 ? u8(2) : u8(3)
				retained_dm_committed_members(alice, expected)
				sender := operation == 1 ? bob : alice
				{
					req := pr.SendMessageV2Request {
						conv_id        = id,
						correlation_id = 4,
						content_type   = .PlainText,
						content        = transmute([]byte)string("pending private body"),
					}
					req.client_message_id[0] = 1
					payload := make([]byte, pr.getSizeSendMessageV2Request(req.content))
					pr.serializeSendMessageV2Request(req, payload)
					process_protocol_payload(sender, payload)
					delete(payload)
				}
				_, write_ok := flush_pending_retained_message_writes(&td.message_stores)
				testing.expect(t, write_ok)
				previous_logger := context.logger
				if boundary == 3 {
					context.logger = log.nil_logger()
					testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim, .EIO))
				} else if boundary == 4 {
					context.logger = log.nil_logger()
					testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim, .ENOSPC))
				} else if boundary > 0 {
					testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
				}
				if boundary == 2 || boundary == 5 {
					store.commit_started = {}
					testing.expect(t, schedule_retained_message_fsync(store))
				}
				if boundary == 2 {
					testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
				} else if boundary == 5 {
					context.logger = log.nil_logger()
					testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim, .EIO))
				}
				context.logger = previous_logger
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, sender.sock, .S_AckSendMessage), boundary == 2 ? 1 : 0)
				if boundary >= 3 && boundary <= 5 do testing.expect(t, store.poisoned)
				// No graceful shutdown before the crash: stale writes/fsyncs must not
				// commit the unacknowledged body or release queued replies.
				if !testing.expect(t, nrc_sim_process_crash_discard_connections(&ctx.sim, ctx.conns[:2])) do return
				for conn, index in ctx.conns[:2] {
					simulation_test_uninstall_client(conn)
					ctx.conns[index] = nil
				}
				crash_message_store_for_test(store)
				storage := sim_world_storage_context(&ctx.sim.world)
				shard := int(shard_for_workspace(transmute([]byte)workspace))
				testing.expect(t, init_message_store_with_storage(store, storage, "/dm-messages", shard, time.Hour, 0))
				alice = simulation_test_install_client(&ctx.sim, 0, workspace, "alice", init_send_queue = true)
				bob = simulation_test_install_client(&ctx.sim, 1, workspace, "bob", init_send_queue = true)
				ctx.conns[0] = alice; ctx.conns[1] = bob
				// Model reloading the previously committed SQLite membership.
				retained_dm_committed_members(alice, expected)
				testing.expect_value(t, validate_dm_access(alice, id), expected & 1 != 0)
				testing.expect_value(t, validate_dm_access(bob, id), expected & 2 != 0)
				outsider := NRC_Connection {
					workspace_id      = workspace,
					authenticated     = true,
					verified_username = "mallory",
				}
				testing.expect(t, !validate_dm_access(&outsider, id))
				if expected & 2 != 0 {
					subscribe_to_conversation(bob, id)
					page, ok := retained_history_simulation_page(bob, {conv_id = id, limit = 10, correlation_id = 5}, false)
					count := operation == 0 ? 0 : 1
					if boundary == 2 do count += 1
					if testing.expect(t, ok && len(page.messages) == count) && count > 0 {
						testing.expect_value(t, string(page.messages[0].content), boundary == 2 ? "pending private body" : "existing private body")
						if count == 2 do testing.expect_value(t, string(page.messages[1].content), "existing private body")
					}
				}
			}
		}
	}

	@(test)
	test_retained_dm_committed_membership_and_leave_during_history :: proc(t: ^testing.T) {
		for reopen_before_read in ([2]bool{false, true}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			testing.expect(t, nbio.init(&td.io) == .NONE)
			defer nbio.destroy(&td.io)
			workspace := "retained-dm-fences"
			store := retained_dm_simulation_store(&ctx, workspace)
			defer shutdown_message_store_registry(&td.message_stores)
			if !testing.expect(t, store != nil) do return
			conn, peer := ctx.conns[0], ctx.conns[1]
			id := pr.make_dm_conversation_id("alice", "bob")
			testing.expect(t, !dm_metadata_durable(conn, id))
			retained_dm_committed_members(conn, 3)
			testing.expect(t, dm_metadata_durable(conn, id))
			subscribe_to_dm_internal(conn, id)
			subscribe_to_dm_internal(peer, id)
			req := pr.SendMessageV2Request {
				conv_id        = id,
				correlation_id = 2,
				content_type   = .PlainText,
				content        = transmute([]byte)string("private"),
			}
			req.client_message_id[0] = 1
			payload := make([]byte, pr.getSizeSendMessageV2Request(req.content))
			defer delete(payload)
			pr.serializeSendMessageV2Request(req, payload)
			process_protocol_payload(conn, payload)
			testing.expect(t, simulation_test_flush_message_writes(&ctx.sim))
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
			store.commit_started = {}
			testing.expect(t, schedule_retained_message_fsync(store))
			testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
			nrc_sim_clear_inboxes(&ctx.sim)
			process_message_history(peer, pr.MessageRangeRequest{conv_id = id, limit = 10, correlation_id = 3}, false)
			testing.expect(t, peer.retained_io > 0, "history read must still be in flight")
			retained_dm_committed_members(conn, 1)
			if reopen_before_read {
				retained_dm_committed_members(conn, 3)
			}
			for nrc_sim_run_next_file_read(&ctx.sim) {}
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_MessagePage), reopen_before_read ? 1 : 0)
			testing.expect_value(t, peer.retained_io, 0)
			testing.expect_value(t, validate_dm_access(peer, id), reopen_before_read)
			if !reopen_before_read {
				retained_dm_committed_members(conn, 3)
				process_message_history(peer, pr.MessageRangeRequest{conv_id = id, limit = 10, correlation_id = 6}, false)
				for nrc_sim_run_next_file_read(&ctx.sim) {}
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_MessagePage), 1)
			}
			for index in 0 ..< nrc_sim_client_frame_count(&ctx.sim, peer.sock) {
				payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, peer.sock, index))
				if !ok || pr.get_opcode(payload) != .S_MessagePage do continue
				page, err := pr.parseMessagePage(payload[2:])
				if testing.expect(t, err == nil && len(page.messages) == 1) {
					testing.expect_value(t, page.correlation_id, reopen_before_read ? u32(3) : u32(6))
					testing.expect_value(t, string(page.messages[0].content), "private")
					testing.expect_value(t, page.messages[0].seq, pr.MessageSeq(1))
				}
			}
		}
	}

	@(test)
	test_retained_waiter_rechecks_priority_head_after_inflight_pong :: proc(t: ^testing.T) {
		for message_first in ([2]bool{false, true}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			conn := simulation_test_install_client(&ctx.sim, 0, "dual-store-waiter", "alice", init_send_queue = true)
			ctx.conns[0] = conn
			if !testing.expect(t, conn != nil) do return
			normal_store: Message_Store
			normal_store.wal.enabled = true
			defer delete(normal_store.durability_waiters)
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
					if kind == 0 do item.message_store = &normal_store
				} else {
					buf[0] = 0x8a // An independent empty Pong overtakes the blocked normal frame.
				}
				outbox_enqueue(conn, item, priority = kind != 0)
			}
			testing.expect(t, conn.is_sending && conn.outbox_waiting_durability)
			testing.expect_value(t, len(normal_store.durability_waiters), 1)
			testing.expect_value(t, len(store.durability_waiters), 0)
			if message_first {
				store.wal.durable_record_count = 1
				resume_durable_outboxes(&store.durability_waiters)
			} else {
				normal_store.wal.durable_record_count = 1
				resume_durable_outboxes(&normal_store.durability_waiters)
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), message_first ? 2 : 1)
			testing.expect(t, conn.outbox_waiting_durability && !conn.is_sending)
			if message_first {
				normal_store.wal.durable_record_count = 1
				resume_durable_outboxes(&normal_store.durability_waiters)
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
			// Publish the write callback's fanout before testing its fsync gate.
			testing.expect(t, simulation_test_publish_output(&ctx.sim))
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
			testing.expect(t, simulation_test_publish_output(&ctx.sim))
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
				testing.expect(t, simulation_test_publish_output(&ctx.sim))
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
