package main

import "core:bytes"
import "core:fmt"
import "core:net"
import "core:testing"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: bytes.equal
	_ :: fmt.tprintf
	_ :: net.TCP_Recv_Error
	_ :: pr.serializeSendMessageRequest
}

@(test)
test_receive_admission_coalesced_split_and_rearm :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 0, "admission", "reader", true)
		ctx.conns[0] = c
		// Masked pings with asymmetric payloads detect double unmasking and reordering.
		ping := [?]byte{0x89, 0x83, 1, 2, 3, 4, 'a' ~ 1, 'b' ~ 2, 'z' ~ 3}
		count := INPUT_FRAME_BUDGET + 3
		data := make([]byte, count * len(ping) + 2)
		defer delete(data)
		for i in 0 ..< count {
			copy(data[i * len(ping):], ping[:])
			data[i * len(ping) + 6] = byte(i) ~ 1
		}
		copy(data[count * len(ping):], ping[:2])
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, c, data))
		ids := [1]u64{ctx.sim.world.events[0].id}
		testing.expect(t, sim_world_dispatch_callback_wave(&ctx.sim.world, ids[:]))
		testing.expect(t, c.deferred_input != nil)
		testing.expect_value(t, td.input_frames_remaining, 0)
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, c, ping[2:]))
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 0)
		_, result := sim_world_drain_bounded(&ctx.sim.world, 1000)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Reached)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), count + 1)
		for i in 0 ..< count + 1 {
			expected := [?]byte{0x8a, 3, 'a', 'b', 'z'}
			if i < count do expected[2] = byte(i)
			testing.expect(t, bytes.equal(nrc_sim_client_frame(&ctx.sim, c.sock, i), expected[:]))
		}
		testing.expect_value(t, td.deferred_input_bytes, 0)
		testing.expect(t, c.deferred_input == nil && c.receive_accumulator.buf == nil)
	}
}

@(test)
test_receive_admission_close_reuse_discards_owned_suffix :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 0, "admission", "old", true)
		old := c.handle
		ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		begin_input_turn()
		td.input_frames_remaining = 0
		receive_websocket_input(c, ping[:])
		testing.expect(t, td.deferred_input_bytes > 0)
		simulation_test_uninstall_client(c)
		c = simulation_test_install_client(&ctx.sim, 0, "admission", "new", true)
		ctx.conns[0] = c
		testing.expect(t, c.handle != old)
		begin_input_turn()
		_ = drain_deferred_input()
		testing.expect_value(t, td.deferred_input_bytes, 0)
		testing.expect(t, c.deferred_input == nil)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 0)
	}
}

@(test)
test_receive_admission_1025_publishers_one_callback_wave :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		for publisher_count in ([2]int{1025, 4097}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			reader := simulation_test_install_client(&ctx.sim, 0, "admission", "reader", true)
			ctx.conns[0] = reader
			subscribe_to_conversation(reader, 78)
			nrc_sim_run_all_send_completions(&ctx.sim)
			nrc_sim_clear_inboxes(&ctx.sim)
			publishers := make([]^NRC_Connection, publisher_count)
			defer delete(publishers)
			defer for c in publishers do simulation_test_uninstall_client(c)
			ids := make([]u64, len(publishers))
			defer delete(ids)
			for &c, i in publishers {
				// The standard fixture reserves 16 FDs per ID near the FD ceiling.
				// Keep this larger population in a disjoint, valid numeric FD range.
				c = simulation_test_install_client(&ctx.sim, i - 10000, "admission", "publisher", true)
				buf: [64]byte
				n := pr.serializeSendMessageRequest(78, u32(i + 1), .PlainText, transmute([]byte)fmt.tprintf("burst-%d", i), buf[:])
				frame := make_test_ws_frame(buf[:n], .opBinary, true)
				testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, c, frame))
				delete(frame)
				ids[i] = ctx.sim.world.events[len(ctx.sim.world.events) - 1].id
			}
			testing.expect(t, sim_world_dispatch_callback_wave(&ctx.sim.world, ids))
			testing.expect(t, reader.state < .Will_Close)
			testing.expect(t, td.deferred_input_bytes > 0)
			_, result := sim_world_drain_bounded(&ctx.sim.world, 30000)
			testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Reached)
			testing.expect(t, reader.state < .Will_Close)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, reader.sock, .S_NewMessage), len(publishers))
			previous_seq: pr.MessageSeq
			for c, i in publishers {
				testing.expect(t, c.state < .Will_Close)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, c.sock, .S_AckSendMessage), 1)
				payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, c.sock, 0))
				testing.expect(t, valid)
				ack, err := pr.parseAckSendMessageMessage(payload)
				testing.expect(t, err == nil && ack.client_req_id == u32(i + 1))
				payload, valid = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, reader.sock, i))
				testing.expect(t, valid)
				message, message_err := pr.parseNewMessageEventMessage(payload)
				testing.expect(t, message_err == nil)
				testing.expect_value(t, string(message.content), fmt.tprintf("burst-%d", i))
				testing.expect(t, message.seq > previous_seq && message.seq == ack.assigned_seq)
				previous_seq = message.seq
			}
			testing.expect_value(t, td.deferred_input_bytes, 0)
		}
	}
}

@(test)
test_receive_admission_forced_error_preserves_dependencies :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 0, "admission", "error", true)
		defer {connection_test_live_count -= 1} 	// Reclaimed by the production close path.
		h := c.handle
		ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		begin_input_turn()
		td.input_frames_remaining = 0
		receive_websocket_input(c, ping[:])
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, c, ping[:]))
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, c, ping[:]))
		testing.expect(t, !nrc_sim_run_receive_at(&ctx.sim, 1, net.TCP_Recv_Error(.Connection_Closed)))
		testing.expect(t, !nrc_sim_run_next_receive(&ctx.sim))
		testing.expect(t, nrc_sim_run_receive_at(&ctx.sim, 0, net.TCP_Recv_Error(.Connection_Closed)))
		testing.expect(t, nrc_sim_run_receive_at(&ctx.sim, 0, net.TCP_Recv_Error(.Connection_Closed)))
		nrc_sim_run_all_close_completions(&ctx.sim)
		discard_deferred_input()
		testing.expect(t, connection_get_by_handle(h) == nil)
		testing.expect_value(t, td.deferred_input_bytes, 0)
		testing.expect_value(t, td.spool.invalid_release_count, 0)
	}
}
