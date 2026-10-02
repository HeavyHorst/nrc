package main

import "core:testing"
import "core:time"
import pr "protocol"
import "storage_io"

when !NRC_SIMULATION {
	_ :: time.Hour
	_ :: pr.SendMessageRequest
	_ :: storage_io.make_directory
}

@(test)
test_receive_admission_transport_pressure_retires_send_fsync_and_close :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		sender := simulation_test_install_client(&ctx.sim, 0, "pressure", "sender", true)
		reader := simulation_test_install_client(&ctx.sim, 1, "pressure", "reader", true)
		durable := simulation_test_install_client(&ctx.sim, 2, "durable", "durable", true)
		victim := simulation_test_install_client(&ctx.sim, 3, "closing", "victim", true)
		defer {connection_test_live_count -= 1} 	// Victim uses the production close path.
		ctx.conns[0] = sender; ctx.conns[1] = reader; ctx.conns[2] = durable
		subscribe_to_conversation(reader, 78)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		// Hold a genuine transport operation in flight and fill its waiting queue.
		for i in 0 ..< Max_Queue_Size / 2 {
			process_send_message(
				sender,
				pr.SendMessageRequest{conv_id = 78, client_req_id = u32(i), content_type = .PlainText, content = transmute([]byte)string("pending")},
			)
		}
		testing.expect(t, reader.is_sending)
		testing.expect_value(t, send_queue_len(reader), Max_Queue_Size / 2 - 1)
		storage := sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, storage_io.make_directory(storage, "/admission-durable") == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		shard := int(shard_for_workspace(transmute([]byte)string("durable")))
		testing.expect(t, init_message_store_with_storage(store, storage, "/admission-durable", shard, time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		req := pr.SendMessageV2Request {
			conv_id        = 78,
			correlation_id = 17,
			content_type   = .PlainText,
			content        = transmute([]byte)string("durable"),
		}
		req.client_message_id[0] = 1
		process_send_message_v2(durable, req)
		_, ok := flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok)
		testing.expect(t, durable.outbox_waiting_durability)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, durable.sock), 0)
		store.commit_started = {}
		testing.expect(t, schedule_retained_message_fsync(store))
		h := victim.handle
		connection_close(victim, false)
		// Put receive first, followed by all already-ready retirement callbacks.
		buf: [64]byte
		n := pr.serializeSendMessageRequest(78, 9999, .PlainText, transmute([]byte)string("pressure"), buf[:])
		frame := make_test_ws_frame(buf[:n], .opBinary, true)
		defer delete(frame)
		data := make([]byte, 2 * len(frame))
		defer delete(data)
		copy(data, frame); copy(data[len(frame):], frame)
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, sender, data))
		ids := make([dynamic]u64)
		defer delete(ids)
		append(&ids, ctx.sim.world.events[len(ctx.sim.world.events) - 1].id)
		for event in ctx.sim.world.events[:len(ctx.sim.world.events) - 1] {
			if sim_event_is_io_callback(event.domain) do append(&ids, event.id)
		}
		testing.expect(t, sim_world_dispatch_callback_wave(&ctx.sim.world, ids[:]))
		testing.expect_value(t, td.input_pressure_yields, 0)
		testing.expect_value(t, len(sender.deferred_input), 0)
		testing.expect_value(t, td.input_frames_remaining, INPUT_FRAME_BUDGET - 2)
		testing.expect(t, connection_get_by_handle(h) == nil)
		testing.expect(t, store.wal.durable_record_count > 0)
		testing.expect(t, nrc_sim_client_frame_count(&ctx.sim, durable.sock) > 0)
		testing.expect(t, send_queue_len(reader) < Max_Queue_Size / 2)
		_, result := sim_world_drain_bounded(&ctx.sim.world, 1000)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Reached)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, reader.sock, .S_NewMessage), Max_Queue_Size / 2 + 2)
		testing.expect_value(t, td.deferred_input_bytes, 0)
	}
}

@(test)
test_receive_admission_accumulator_fragment_and_pinned_close :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 0, "fragment", "reader", true)
		defer {connection_test_live_count -= 1} 	// Reclaimed by the production close path.
		h := c.handle
		baseline := td.spool.allocation_count - td.spool.release_count
		buf: [16]byte
		n := pr.serializePingRequest(1234, buf[:])
		first := make_test_ws_frame(buf[:3], .opBinary, false)
		last := make_test_ws_frame(buf[3:n], .opContinuation, true)
		control := make_test_ws_frame(nil, .opPing, true)
		close := make_test_ws_frame(nil, .opClose, true)
		defer delete(first); defer delete(last); defer delete(control); defer delete(close)
		receive_websocket_input(c, first[:2])
		begin_input_turn()
		td.input_frames_remaining = 1
		data := make([dynamic]byte)
		defer delete(data)
		append(&data, ..first[2:]); append(&data, ..control); append(&data, ..last); append(&data, ..close)
		receive_websocket_input(c, data[:])
		testing.expect(t, c.receive_accumulator.buf == nil && c.fragment_len == 3)
		testing.expect_value(t, len(c.deferred_input), len(control) + len(last) + len(close))
		begin_input_turn()
		td.input_frames_remaining = 1
		_ = drain_deferred_input()
		testing.expect(t, c.fragment_len == 3)
		begin_input_turn()
		_ = drain_deferred_input()
		_, result := sim_world_drain_bounded(&ctx.sim.world, 1000)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Reached)
		testing.expect(t, connection_get_by_handle(h) == nil)
		testing.expect_value(t, td.deferred_input_bytes, 0)
		testing.expect_value(t, td.spool.invalid_release_count, 0)
		testing.expect_value(t, td.spool.allocation_count - td.spool.release_count, baseline)
	}
}

@(test)
test_receive_admission_fifo_and_stalled_receiver_limit :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		hot := simulation_test_install_client(&ctx.sim, 0, "fifo", "hot", true)
		peer := simulation_test_install_client(&ctx.sim, 1, "fifo", "peer", true)
		defer {connection_test_live_count -= 1} 	// Hot socket uses the production close path.
		ctx.conns[1] = peer
		h := hot.handle
		ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		data := make([]byte, (Max_Queue_Size + 20) * len(ping))
		defer delete(data)
		for i in 0 ..< len(data) / len(ping) do copy(data[i * len(ping):], ping[:])
		begin_input_turn()
		td.input_frames_remaining = 0
		receive_websocket_input(hot, data)
		receive_websocket_input(peer, ping[:])
		begin_input_turn()
		td.input_frames_remaining = 1
		_ = drain_deferred_input()
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, hot.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 0)
		begin_input_turn()
		td.input_frames_remaining = 1
		_ = drain_deferred_input()
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 1)
		testing.expect(t, hot.deferred_input != nil)
		// Never retire the hot socket's send. Admission still must not remove the
		// hard queue cap or retain unbounded output on a genuinely stalled peer.
		for _ in 0 ..< Max_Queue_Size + 20 {
			if hot.state >= .Will_Close do break
			begin_input_turn()
			_ = drain_deferred_input()
			testing.expect(t, send_queue_len(hot) <= Max_Queue_Size)
		}
		testing.expect(t, hot.state >= .Will_Close)
		discard_deferred_input()
		_, result := sim_world_drain_bounded(&ctx.sim.world, 2000)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Reached)
		testing.expect(t, connection_get_by_handle(h) == nil)
		// Also exercise shutdown discard while a live peer still owns input.
		begin_input_turn()
		td.input_frames_remaining = 0
		receive_websocket_input(peer, ping[:])
		discard_deferred_input()
		testing.expect(t, peer.deferred_input == nil && !peer.input_queued)
		testing.expect_value(t, td.deferred_input_bytes, 0)
		testing.expect_value(t, td.spool.invalid_release_count, 0)
	}
}

@(test)
test_receive_admission_retained_pressure_survives_turn_boundary :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		reader := simulation_test_install_client(&ctx.sim, 0, "retained-pressure", "reader", true)
		ctx.conns[0] = reader
		subscribe_to_conversation(reader, 78)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		storage := sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, storage_io.make_directory(storage, "/retained-pressure") == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		shard := int(shard_for_workspace(transmute([]byte)string("retained-pressure")))
		testing.expect(t, init_message_store_with_storage(store, storage, "/retained-pressure", shard, time.Hour, 0))
		store.wal.get_time = proc "contextless" () -> time.Time {
			return time.Time{_nsec = NRC_SIM_TIME_EPOCH_NANOS + i64(nrc_sim_runtime.world.now)}
		}
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		defer for nrc_sim_run_next_fsync_completion(&ctx.sim) {}
		publishers: [640]^NRC_Connection
		defer for c in publishers do simulation_test_uninstall_client(c)
		ids: [640]u64
		for &c, i in publishers {
			c = simulation_test_install_client(&ctx.sim, i + 1, "retained-pressure", "publisher", true)
			req := pr.SendMessageV2Request {
				conv_id        = 78,
				correlation_id = u32(i + 1),
				content_type   = .PlainText,
				content        = transmute([]byte)string("retained"),
			}
			req.client_message_id[0] = byte(i + 1)
			req.client_message_id[1] = byte((i + 1) >> 8)
			buf: [128]byte
			n := pr.serializeSendMessageV2Request(req, buf[:])
			frame := make_test_ws_frame(buf[:n], .opBinary, true)
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, c, frame))
			delete(frame)
			ids[i] = ctx.sim.world.events[len(ctx.sim.world.events) - 1].id
		}
		testing.expect(t, sim_world_dispatch_callback_wave(&ctx.sim.world, ids[:]))
		// Advance beyond the commit deadline and issue a real simulated fsync,
		// but hold its completion for a finite number of input turns.
		ctx.sim.world.now += RETAINED_COMMIT_WINDOW
		_, maintained := maintain_message_store_registry(&td.message_stores)
		testing.expect(t, maintained && store.fsync_in_flight)
		for _ in 0 ..< 3 {
			ctx.sim.world.now += 100 * time.Microsecond
			testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, Sim_Event_Domain.Input_Turn))
			nrc_sim_run_all_send_completions(&ctx.sim)
		}
		testing.expect_value(t, send_queue_len(reader), Max_Queue_Size / 2)
		testing.expect(t, reader.outbox_waiting_durability)
		testing.expect_value(t, td.input_frames_remaining, 0)
		for _ in 0 ..< 5 {
			before := store.wal.record_count
			ctx.sim.world.now += 100 * time.Microsecond
			testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, Sim_Event_Domain.Input_Turn))
			if !testing.expect_value(t, store.wal.record_count - before, u64(1)) do return
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, reader.sock), 0)
		}
		// Release the delayed fsync, then drive time and maintenance explicitly.
		// Input_Turn alone deliberately does not model pre-tick maintenance.
		for _ in 0 ..< 1000 {
			ctx.sim.world.now += RETAINED_COMMIT_WINDOW
			_, maintained = maintain_message_store_registry(&td.message_stores)
			testing.expect(t, maintained)
			for nrc_sim_run_next_fsync_completion(&ctx.sim) {}
			nrc_sim_run_all_send_completions(&ctx.sim)
			if !sim_world_run_runnable_rank(&ctx.sim.world, 0, Sim_Event_Domain.Input_Turn) do break
		}
		testing.expect(t, reader.state < .Will_Close)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, reader.sock), len(publishers))
		for c in publishers do testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 1)
		testing.expect_value(t, td.deferred_input_bytes, 0)
		begin_input_turn()
		testing.expect_value(t, td.input_frames_remaining, INPUT_FRAME_BUDGET)
	}
}

@(test)
test_receive_admission_slow_subscriber_does_not_throttle_fast_subscriber :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		sender := simulation_test_install_client(&ctx.sim, 0, "isolation", "sender", true)
		slow := simulation_test_install_client(&ctx.sim, 1, "isolation", "slow", true)
		fast := simulation_test_install_client(&ctx.sim, 2, "isolation", "fast", true)
		ctx.conns[0] = sender; ctx.conns[1] = slow; ctx.conns[2] = fast
		subscribe_to_conversation(slow, 78)
		subscribe_to_conversation(fast, 78)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		published := 0
		for turn in 0 ..< Max_Queue_Size / INPUT_FRAME_BUDGET + 2 {
			if turn == 5 {
				// A previous durability wait may have left a weak pressure hint.
				// Once transport owns the backlog, that hint must not throttle.
				testing.expect(t, send_queue_len(slow) >= Max_Queue_Size / 2)
				td.input_pressure_handle = slow.handle
			}
			data := make([dynamic]byte)
			defer delete(data)
			for i in 0 ..< INPUT_FRAME_BUDGET {
				buf: [64]byte
				n := pr.serializeSendMessageRequest(78, u32(published + i + 1), .PlainText, transmute([]byte)string("isolated"), buf[:])
				frame := make_test_ws_frame(buf[:n], .opBinary, true)
				append(&data, ..frame)
				delete(frame)
			}
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, sender, data[:]))
			ids := [1]u64{ctx.sim.world.events[len(ctx.sim.world.events) - 1].id}
			testing.expect(t, sim_world_dispatch_callback_wave(&ctx.sim.world, ids[:]))
			// Retire every sender/fast-subscriber send, but never the slow socket's.
			ordinal := 0
			for ordinal < nrc_sim_send_completion_count(&ctx.sim) {
				completion, _ := nrc_sim_send_completion_at(&ctx.sim, ordinal)
				if completion.sock == slow.sock {
					ordinal += 1
				} else {
					testing.expect(t, nrc_sim_run_send_completion_at(&ctx.sim, ordinal))
				}
			}
			published += INPUT_FRAME_BUDGET
			if !testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, fast.sock, .S_NewMessage), published) do return
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, sender.sock, .S_AckSendMessage), published)
			testing.expect(t, sender.deferred_input == nil)
			testing.expect(t, fast.state < .Will_Close && sender.state < .Will_Close)
			testing.expect(t, send_queue_len(slow) <= Max_Queue_Size)
			if turn == 0 do testing.expect(t, slow.is_sending)
		}
		testing.expect(t, slow.state >= .Will_Close)
		testing.expect_value(t, td.deferred_input_bytes, 0)
	}
}
