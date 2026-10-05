package main

import "byte_pool"
import "core:bytes"
import "core:fmt"
import "core:net"
import "core:testing"
import "core:time"
import nbio "nbio/poly"
import pr "protocol"
import "storage_io"
import ws "websocket"

when !NRC_SIMULATION {
	_ :: fmt.tprintf
	_ :: net.TCP_Socket
	_ :: testing.expect
	_ :: pr.RoomPresenceUpdate
	_ :: ws.readFrameHeader
	_ :: time.Hour
	_ :: bytes.equal
	_ :: byte_pool.alloc
	_ :: nbio.init
	_ :: storage_io.make_directory
} else {
	// The simulated transport captures send buffers. Decode every complete WS
	// frame within them, just as a real WebSocket peer does on its byte stream.
	presence_test_events :: proc(t: ^testing.T, sim: ^Sim_Runtime, sock: net.TCP_Socket) -> [dynamic]pr.RoomPresenceUpdate {
		result := make([dynamic]pr.RoomPresenceUpdate, 0, 16, context.temp_allocator)
		for chunk in sim.clients[sock].inbox {
			offset := 0
			for offset < len(chunk) {
				header, size, err := ws.readFrameHeader(chunk[offset:])
				if !testing.expect(t, err == nil && header.fin && !header.mask) do return result
				end := offset + size + int(header.payloadLength)
				if !testing.expect(t, end <= len(chunk)) do return result
				payload := chunk[offset + size:end]
				if header.opcode == .opBinary && pr.get_opcode(payload) == .S_RoomPresenceUpdate {
					event, parse_err := pr.parseRoomPresenceUpdateMessage(payload, context.temp_allocator)
					if !testing.expect(t, parse_err == nil) do return result
					append(&result, event)
				}
				offset = end
			}
		}
		return result
	}

	@(test)
	test_presence_batch_lossless_order_and_byte_limit :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "presence-batch", "observer", init_send_queue = true)
		ctx.conns[1] = c
		subscribe_to_conversation(c, 17)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		pool_before := td.spool.used
		begin_presence_batch_wave()
		for i in 0 ..< 1000 {
			kind := pr.PresenceEventType.UserLeft
			if i % 2 == 1 do kind = .UserJoined
			// Adjacent leave/rejoin of the same identity must not coalesce away.
			name := fmt.tprintf("user-%04d", i / 2)
			broadcast_presence_update("presence-batch", 17, kind, name)
			testing.expect(t, td.presence_batch_count <= PRESENCE_BATCH_ROOMS)
			for batch in td.presence_batches[:td.presence_batch_count] {
				testing.expect(t, batch.used <= PRESENCE_BATCH_BYTES)
			}
		}
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		nrc_sim_run_all_send_completions(&ctx.sim)
		events := presence_test_events(t, &ctx.sim, c.sock)
		if !testing.expect_value(t, len(events), 1000) do return
		for event, i in events {
			expected := pr.PresenceEventType.UserLeft
			if i % 2 == 1 do expected = .UserJoined
			testing.expect_value(t, event.event_type, expected)
			testing.expect_value(t, string(event.username), fmt.tprintf("user-%04d", i / 2))
			testing.expect_value(t, event.conv_id, pr.ConversationID(17))
			if i > 0 do testing.expect(t, event.sequence > events[i - 1].sequence)
		}
		testing.expect(t, len(ctx.sim.clients[c.sock].inbox) < 10, "1000 events should require only a few send buffers")
		testing.expect_value(t, td.presence_batch_count, 0)
		testing.expect_value(t, td.spool.used, pool_before)
	}

	@(test)
	test_presence_batch_join_sync_and_unsubscribe_boundaries :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		a := simulation_test_install_client(&ctx.sim, 1, "presence-order", "alice", init_send_queue = true)
		b := simulation_test_install_client(&ctx.sim, 2, "presence-order", "bob", init_send_queue = true)
		ctx.conns[1], ctx.conns[2] = a, b
		subscribe_to_conversation(a, 19)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		begin_presence_batch_wave()
		broadcast_presence_update_by_id("presence-order", 19, .UserLeft, "before-bob")
		subscribe_to_conversation(b, 19)
		broadcast_presence_update_by_id("presence-order", 19, .UserJoined, "after-bob")
		send_user_list_sync(a, "presence-order", 19)
		broadcast_presence_update_by_id("presence-order", 19, .UserLeft, "before-unsubscribe")
		unsubscribe_from_conversation(b, 19)
		broadcast_presence_update_by_id("presence-order", 19, .UserLeft, "after-unsubscribe")
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		nrc_sim_run_all_send_completions(&ctx.sim)
		a_events := presence_test_events(t, &ctx.sim, a.sock)
		b_events := presence_test_events(t, &ctx.sim, b.sock)
		if !testing.expect_value(t, len(a_events), 7) || !testing.expect_value(t, len(b_events), 4) do return
		testing.expect_value(t, string(a_events[0].username), "before-bob")
		testing.expect_value(t, string(a_events[1].username), "bob")
		testing.expect_value(t, string(a_events[2].username), "after-bob")
		testing.expect_value(t, a_events[3].event_type, pr.PresenceEventType.UserListSync)
		testing.expect_value(t, len(a_events[3].user_list), 2)
		testing.expect_value(t, string(a_events[4].username), "before-unsubscribe")
		testing.expect_value(t, string(a_events[5].username), "bob")
		testing.expect_value(t, string(a_events[6].username), "after-unsubscribe")
		testing.expect_value(t, b_events[0].event_type, pr.PresenceEventType.UserListSync)
		testing.expect_value(t, string(b_events[1].username), "bob")
		testing.expect_value(t, string(b_events[2].username), "after-bob")
		testing.expect_value(t, string(b_events[3].username), "before-unsubscribe")
		for event, i in a_events {
			if i > 0 do testing.expect(t, event.sequence > a_events[i - 1].sequence)
		}
	}

	@(test)
	test_presence_batch_room_limit_and_workspace_isolation :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		a := simulation_test_install_client(&ctx.sim, 1, "presence-many", "alice", init_send_queue = true)
		b := simulation_test_install_client(&ctx.sim, 2, "presence-other", "bob", init_send_queue = true)
		ctx.conns[1], ctx.conns[2] = a, b
		for i in 0 ..< PRESENCE_BATCH_ROOMS + 1 do subscribe_to_conversation(a, pr.ConversationID(i + 1))
		subscribe_to_conversation(b, 1)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		begin_presence_batch_wave()
		for i in 0 ..< PRESENCE_BATCH_ROOMS + 1 {
			broadcast_presence_update_by_id("presence-many", pr.ConversationID(i + 1), .UserLeft, "departed")
			testing.expect(t, td.presence_batch_count <= PRESENCE_BATCH_ROOMS)
		}
		broadcast_presence_update_by_id("presence-other", 1, .UserJoined, "separate")
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		nrc_sim_run_all_send_completions(&ctx.sim)
		a_events := presence_test_events(t, &ctx.sim, a.sock)
		b_events := presence_test_events(t, &ctx.sim, b.sock)
		if !testing.expect_value(t, len(a_events), PRESENCE_BATCH_ROOMS + 1) || !testing.expect_value(t, len(b_events), 1) do return
		for event, i in a_events {
			testing.expect_value(t, event.conv_id, pr.ConversationID(i + 1))
			testing.expect_value(t, string(event.username), "departed")
		}
		testing.expect_value(t, string(b_events[0].username), "separate")
	}

	@(test)
	test_presence_batch_actual_disconnect_wave :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		for i in 1 ..< 5 {
			ctx.conns[i] = simulation_test_install_client(&ctx.sim, i, "presence-eof", fmt.tprintf("user-%d", i), init_send_queue = true)
			subscribe_to_conversation(ctx.conns[i], 7)
		}
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		ids: [2]u64
		for i in 0 ..< 2 {
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, ctx.conns[i + 1], nil))
			ids[i] = ctx.sim.world.next_event_id
		}
		testing.expect(t, sim_world_dispatch_callback_wave(&ctx.sim.world, ids[:]))
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_run_all_close_completions(&ctx.sim)
		ctx.conns[1], ctx.conns[2] = nil, nil
		connection_test_live_count -= 2
		for i in 3 ..< 5 {
			c := ctx.conns[i]
			events := presence_test_events(t, &ctx.sim, c.sock)
			if !testing.expect_value(t, len(events), 2) do return
			testing.expect_value(t, string(events[0].username), "user-1")
			testing.expect_value(t, string(events[1].username), "user-2")
			testing.expect(t, events[1].sequence > events[0].sequence)
			testing.expect_value(t, len(ctx.sim.clients[c.sock].inbox), 1)
			testing.expect(t, c.state < .Will_Close)
		}
		testing.expect_value(t, td.spool.used, u64(0))
	}

	@(test)
	test_presence_batch_dm_leave_and_destruction :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		desktop := simulation_test_install_client(&ctx.sim, 1, "presence-dm", "bob", init_send_queue = true)
		mobile := simulation_test_install_client(&ctx.sim, 2, "presence-dm", "bob", init_send_queue = true)
		ctx.conns[1], ctx.conns[2] = desktop, mobile
		workspace := get_connection_workspace(mobile)
		conv_id := pr.ConversationID((u64(1) << 63) | 42)
		conv := get_or_create_conversation(workspace, conv_id)
		conv.dm_participants = new(DM_Participants)
		conv.dm_participants^ = {
			user_a = "alice",
			user_b = "bob",
		}
		add_user_dm(workspace, "bob", conv_id) // Alice has already left.
		subscribe_to_dm_internal(desktop, conv_id)
		subscribe_to_dm_internal(mobile, conv_id)
		begin_presence_batch_wave()
		connection_close(desktop, false)
		testing.expect_value(t, td.presence_batch_count, 1)
		process_leave_dm(mobile, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 9})
		testing.expect(t, get_conversation(workspace, conv_id) == nil)
		testing.expect_value(t, td.presence_batch_count, 0)
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_run_all_close_completions(&ctx.sim)
		ctx.conns[1] = nil
		connection_test_live_count -= 1
		events := presence_test_events(t, &ctx.sim, mobile.sock)
		if !testing.expect_value(t, len(events), 1) do return
		testing.expect_value(t, events[0].event_type, pr.PresenceEventType.UserLeft)
		testing.expect_value(t, string(events[0].username), "bob")
		testing.expect_value(t, td.spool.used, u64(0))
	}

	@(test)
	test_presence_batch_retained_publication_rejections :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect(t, nbio.init(&td.io) == .NONE)
		defer nbio.destroy(&td.io)
		workspace := "presence-retained"
		for i in 1 ..< 5 {
			ctx.conns[i] = simulation_test_install_client(&ctx.sim, i, workspace, fmt.tprintf("user-%d", i), init_send_queue = true)
			subscribe_to_conversation(ctx.conns[i], 42)
		}
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		storage := sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, storage_io.make_directory(storage, "/presence-retained") == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, "/presence-retained", shard, time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		for i in 1 ..< 3 {
			c := ctx.conns[i]
			c.is_sending = true
			for _ in 0 ..< Max_Queue_Size do send_queue_push(c, Send_Item{handle = c.handle})
		}
		req := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = 3,
			content        = transmute([]byte)string("retained"),
			content_type   = .PlainText,
		}
		req.client_message_id[0] = 1
		begin_presence_batch_wave()
		process_send_message_v2(ctx.conns[3], req)
		testing.expect_value(t, td.presence_batch_count, 0)
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		// One retained page plus one batch of two departures, all durability-blocked.
		testing.expect_value(t, send_queue_len(ctx.conns[4]), 2)
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
		events := presence_test_events(t, &ctx.sim, ctx.conns[4].sock)
		if !testing.expect_value(t, len(events), 2) do return
		testing.expect_value(t, string(events[0].username), "user-1")
		testing.expect_value(t, string(events[1].username), "user-2")
		testing.expect(t, ctx.conns[4].state < .Will_Close)
	}

	@(test)
	test_presence_batch_inflight_bytes_survive_later_waves :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		for i in 1 ..< 3 {
			ctx.conns[i] = simulation_test_install_client(&ctx.sim, i, "presence-lease", fmt.tprintf("user-%d", i), init_send_queue = true)
			subscribe_to_conversation(ctx.conns[i], 3)
		}
		nrc_sim_run_all_send_completions(&ctx.sim)
		begin_presence_batch_wave()
		broadcast_presence_update_by_id("presence-lease", 3, .UserLeft, "old-a")
		broadcast_presence_update_by_id("presence-lease", 3, .UserJoined, "old-b")
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		held: []byte
		for event in ctx.sim.world.events {
			completion, is_send := event.payload.(Sim_Send_Completion)
			if is_send && completion.sock == ctx.conns[2].sock && completion.kind == .Queued_Send {
				held = frame_lease_data(completion.item.lease)
				break
			}
		}
		if !testing.expect(t, len(held) > 0) do return
		expected := make([]byte, len(held), context.temp_allocator)
		copy(expected, held)
		testing.expect(t, nrc_sim_run_next_send_completion(&ctx.sim)) // Other recipient releases its reference.
		allocations_before := td.spool.allocation_count
		begin_presence_batch_wave()
		for i in 0 ..< 100 do broadcast_presence_update_by_id("presence-lease", 3, .UserLeft, fmt.tprintf("new-%d", i))
		_, ok = worker_finish_callback_wave()
		testing.expect(t, ok)
		testing.expect(t, bytes.equal(held, expected), "in-flight bytes must not be mutated or recycled")
		testing.expect(t, td.spool.allocation_count > allocations_before)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, td.spool.used, u64(0))
		testing.expect_value(t, td.spool.invalid_release_count, u64(0))
	}

	@(test)
	test_presence_batch_capacity_flush_orders_reentrant_departure :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		for i in 1 ..< 4 {
			ctx.conns[i] = simulation_test_install_client(&ctx.sim, i, "presence-capacity", fmt.tprintf("user-%d", i), init_send_queue = true)
			subscribe_to_conversation(ctx.conns[i], 5)
		}
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		slow := ctx.conns[1]
		slow.is_sending = true
		for _ in 0 ..< Max_Queue_Size do send_queue_push(slow, Send_Item{handle = slow.handle})
		begin_presence_batch_wave()
		generated := 0
		for i in 0 ..< 1000 {
			broadcast_presence_update_by_id("presence-capacity", 5, .UserJoined, fmt.tprintf("event-%04d", i))
			generated += 1
			if slow.state >= .Will_Close do break
		}
		testing.expect(t, slow.state >= .Will_Close, "capacity flush must reject the full recipient")
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		nrc_sim_run_all_send_completions(&ctx.sim)
		for i in 2 ..< 4 {
			events := presence_test_events(t, &ctx.sim, ctx.conns[i].sock)
			if !testing.expect_value(t, len(events), generated + 1) do return
			for j in 0 ..< generated {
				testing.expect_value(t, string(events[j].username), fmt.tprintf("event-%04d", j))
				testing.expect_value(t, events[j].event_type, pr.PresenceEventType.UserJoined)
			}
			testing.expect_value(t, string(events[generated].username), "user-1")
			testing.expect_value(t, events[generated].event_type, pr.PresenceEventType.UserLeft)
			for event, j in events {
				if j > 0 do testing.expect(t, event.sequence > events[j - 1].sequence)
			}
			testing.expect(t, ctx.conns[i].state < .Will_Close)
		}
	}
}
