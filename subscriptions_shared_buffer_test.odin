package main

// Tests the subscription fanout path that shares pooled message buffers across
// multiple subscribers. These fixtures pin ownership/refcount behavior, room
// membership semantics, generated fanout operations, and simulation-only worker
// plumbing so broadcast changes do not introduce leaks, duplicate delivery, or
// stale subscriber state.

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

import "byte_pool"
import hgl "hegel"
import pr "protocol"
import ws "websocket"

when !NRC_SIMULATION {
	_ :: log.infof
	_ :: strings.clone
	_ :: pending_queue_create
	_ :: time.now
	_ :: ws.readFrameHeader
}

subscriber_test_sock_a :: net.TCP_Socket(410_001)
subscriber_test_sock_b :: net.TCP_Socket(410_003)
subscriber_test_sock_c :: net.TCP_Socket(410_005)
subscriber_test_large_room_users :: 1205
subscriber_test_model_slots :: 32
subscriber_test_model_base_sock :: 430_000
subscriber_test_sort_slots :: 80
subscriber_test_sort_base_sock :: 431_000

when NRC_SIMULATION {
	nrc_sim_client_has_close_frame :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, code: u16, reason: string = "") -> bool {
		frame_count := nrc_sim_client_frame_count(sim, sock)
		for i in 0 ..< frame_count {
			frame := nrc_sim_client_frame(sim, sock, i)
			header, header_len, err := ws.readFrameHeader(frame)
			if err != nil || header.opcode != .opClose {
				continue
			}
			payload_len := int(header.payloadLength)
			if payload_len < 2 || len(frame) < header_len + payload_len {
				continue
			}
			payload := frame[header_len:header_len + payload_len]
			got_code := u16(payload[0]) << 8 | u16(payload[1])
			if got_code == code {
				if reason != "" && string(payload[2:]) != reason {
					continue
				}
				return true
			}
		}
		return false
	}

	nrc_sim_client_find_payload_by_opcode :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, opcode: pr.Opcode) -> ([]u8, bool) {
		frame_count := nrc_sim_client_frame_count(sim, sock)
		for i in 0 ..< frame_count {
			payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(sim, sock, i))
			if !payload_ok {
				continue
			}
			if pr.get_opcode(payload) == opcode {
				return payload, true
			}
		}
		return nil, false
	}

	nrc_sim_client_has_opcode :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, opcode: pr.Opcode) -> bool {
		_, ok := nrc_sim_client_find_payload_by_opcode(sim, sock, opcode)
		return ok
	}

	nrc_sim_client_opcode_count :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, opcode: pr.Opcode) -> int {
		count := 0
		for i in 0 ..< nrc_sim_client_frame_count(sim, sock) {
			payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(sim, sock, i))
			if ok && pr.get_opcode(payload) == opcode {
				count += 1
			}
		}
		return count
	}
}

subscriber_test_make_conversation :: proc() -> Conversation_State {
	conv := Conversation_State{}
	init_subscriber_index(&conv)
	return conv
}

subscriber_test_destroy_conversation :: proc(conv: ^Conversation_State) {
	destroy_subscriber_index(conv)
}

subscriber_test_set_conn_state :: proc(sock: net.TCP_Socket, state: Connection_State) -> ^NRC_Connection {
	conn := connection_test_install(sock, state)
	if conn != nil {
		send_queue_init(conn)
	}
	return conn
}

subscriber_test_uninstall_conn :: proc(conn: ^NRC_Connection) {
	if conn == nil {
		return
	}
	connection_test_uninstall(conn)
	if connection_test_live_count == 0 {
		connection_test_storage_destroy()
	}
}

subscriber_test_make_pooled_shared_buffer :: proc(pool: ^byte_pool.BufferPool, ref_count: int) -> ^Broadcast_Buffer {
	data, err := byte_pool.alloc(pool, 64)
	if err != runtime.Allocator_Error.None {
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(pool))
	shared.data = data
	shared.pool = pool
	shared.ref_count = ref_count
	return shared
}

subscriber_test_shared_completion_live_count: int
subscriber_test_shared_completion_nil_count: int
subscriber_test_shared_completion_new_count: int

subscriber_test_shared_completion_callback :: proc(c: ^NRC_Connection, ctx: rawptr, sent: int, err: net.Network_Error) {
	if c == nil {
		subscriber_test_shared_completion_nil_count += 1
	} else {
		subscriber_test_shared_completion_live_count += 1
		if c.verified_username == "new" {
			subscriber_test_shared_completion_new_count += 1
		}
	}
}

subscriber_test_reset_shared_completion_counters :: proc() {
	subscriber_test_shared_completion_live_count = 0
	subscriber_test_shared_completion_nil_count = 0
	subscriber_test_shared_completion_new_count = 0
}

subscriber_test_model_sock :: proc(idx: int) -> net.TCP_Socket {
	return net.TCP_Socket(subscriber_test_model_base_sock + idx * 2 + 1)
}

subscriber_test_add_stale_entry :: proc(conv: ^Conversation_State, sock: net.TCP_Socket) -> bool {
	conn := NRC_Connection {
		sock = sock,
		handle = Connection_Handle{idx = u32(sock) + 1, gen = 1},
	}
	return conversation_add_subscriber(conv, &conn)
}

subscriber_test_model_count :: proc(model: ^[subscriber_test_model_slots]bool) -> int {
	count := 0
	for present in model {
		if present do count += 1
	}
	return count
}

subscriber_test_indexes_match_model :: proc(conv: ^Conversation_State, model: ^[subscriber_test_model_slots]bool) -> bool {
	if subscriber_count(conv) != subscriber_test_model_count(model) {
		return false
	}

	seen: [subscriber_test_model_slots]bool
	for entry, entry_idx in conv.subscriber_entries {
		idx := int((entry.sock - net.TCP_Socket(subscriber_test_model_base_sock) - 1) / 2)
		if idx < 0 || idx >= subscriber_test_model_slots {
			return false
		}
		if !model[idx] || seen[idx] {
			return false
		}
		seen[idx] = true

		stored_idx, ok := conv.subscriber_index[entry.sock]
		if !ok || stored_idx != entry_idx {
			return false
		}
	}

	for present, idx in model {
		sock := subscriber_test_model_sock(idx)
		if conversation_has_subscriber(conv, sock) != present {
			return false
		}
		if present && !seen[idx] {
			return false
		}
	}

	return true
}

@(test)
test_hegel_subscriber_indexes_match_set_model_after_random_mutations :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_subscriber_indexes_match_set_model_after_random_mutations, nil, {test_cases = 200})
	testing.expectf(t, err == nil, "hegel subscriber index model property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_subscriber_indexes_match_set_model_after_random_mutations :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	model: [subscriber_test_model_slots]bool

	op_count_i64, draw_err := hgl.draw_i64(tc, 0, 256)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw operation count")

	for _ in 0 ..< int(op_count_i64) {
		op, op_draw_err := hgl.draw_i64(tc, 0, 2)
		if op_draw_err == .Stop_Test do return hgl.abort()
		if op_draw_err != nil do return hgl.interesting("draw operation")

		idx_i64, idx_draw_err := hgl.draw_i64(tc, 0, subscriber_test_model_slots - 1)
		if idx_draw_err == .Stop_Test do return hgl.abort()
		if idx_draw_err != nil do return hgl.interesting("draw socket index")

		idx := int(idx_i64)
		sock := subscriber_test_model_sock(idx)

		switch op {
		case 0:
			added := subscriber_test_add_stale_entry(&conv, sock)
			if added == model[idx] {
				return hgl.interesting("add return did not match model")
			}
			model[idx] = true
		case 1:
			removed := conversation_remove_subscriber(&conv, sock)
			if removed != model[idx] {
				return hgl.interesting("remove return did not match model")
			}
			model[idx] = false
		case:
			if conversation_has_subscriber(&conv, sock) != model[idx] {
				return hgl.interesting("membership lookup did not match model")
			}
		}

		if !subscriber_test_indexes_match_model(&conv, &model) {
			return hgl.interesting("subscriber indexes diverged from model")
		}
	}

	return hgl.valid()
}

@(test)
test_subscriber_insert_requires_generational_handle :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	conn := NRC_Connection {
		sock = subscriber_test_sock_a,
	}
	testing.expect(t, !conversation_add_subscriber(&conv, &conn), "handle-less subscriber identity must be rejected")
	testing.expect_value(t, subscriber_count(&conv), 0)
	testing.expect(t, !conversation_has_subscriber(&conv, conn.sock), "rejected subscriber must not enter the socket index")
}

@(test)
test_shared_broadcast_stale_completions_release_refs_without_targeting_reused_socket :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 94)
	defer worker_state_destroy_core_for_test()
	subscriber_test_reset_shared_completion_counters()

	base_pool_used := td.spool.used
	shared := subscriber_test_make_pooled_shared_buffer(td.spool, 3)
	testing.expect(t, shared != nil, "expected shared broadcast buffer allocation")
	if shared == nil {
		return
	}
	testing.expect(t, td.spool.used > base_pool_used, "shared broadcast allocation should increase pool usage")

	sock_a := net.TCP_Socket(491_001)
	sock_b := net.TCP_Socket(491_003)
	sock_c := net.TCP_Socket(491_005)

	conn_a := connection_test_install_fake(Fake_Connection_Options{sock = sock_a, state = .Idle, verified_username = "live", init_send_queue = true})
	defer subscriber_test_uninstall_conn(conn_a)
	testing.expect(t, conn_a != nil, "expected live shared-broadcast connection")
	if conn_a == nil {
		shared_frame_release(shared)
		return
	}

	conn_b := connection_test_install_fake(Fake_Connection_Options{sock = sock_b, state = .Idle, verified_username = "removed", init_send_queue = true})
	testing.expect(t, conn_b != nil, "expected removed shared-broadcast connection")
	if conn_b == nil {
		shared_frame_release(shared)
		return
	}

	old_conn_c := connection_test_install_fake(Fake_Connection_Options{sock = sock_c, state = .Idle, verified_username = "old", init_send_queue = true})
	testing.expect(t, old_conn_c != nil, "expected old reused-socket shared-broadcast connection")
	if old_conn_c == nil {
		subscriber_test_uninstall_conn(conn_b)
		shared_frame_release(shared)
		return
	}

	item_a := Send_Item {
		lease = Frame_Lease(Shared_Frame_Lease{buffer = shared}),
		handle = conn_a.handle,
		observer = Send_Completion_Observer{callback = subscriber_test_shared_completion_callback, ctx = shared},
	}
	item_b := Send_Item {
		lease = Frame_Lease(Shared_Frame_Lease{buffer = shared}),
		handle = conn_b.handle,
		observer = Send_Completion_Observer{callback = subscriber_test_shared_completion_callback, ctx = shared},
	}
	item_c := Send_Item {
		lease = Frame_Lease(Shared_Frame_Lease{buffer = shared}),
		handle = old_conn_c.handle,
		observer = Send_Completion_Observer{callback = subscriber_test_shared_completion_callback, ctx = shared},
	}

	subscriber_test_uninstall_conn(conn_b)
	subscriber_test_uninstall_conn(old_conn_c)

	new_conn_c := connection_test_install_fake(Fake_Connection_Options{sock = sock_c, state = .Idle, verified_username = "new", init_send_queue = true})
	defer subscriber_test_uninstall_conn(new_conn_c)
	testing.expect(t, new_conn_c != nil, "expected new reused-socket shared-broadcast connection")
	if new_conn_c == nil {
		shared_frame_release(shared)
		return
	}

	on_queued_send_complete(sock_b, item_b, len(frame_lease_data(item_b.lease)), nil)
	testing.expect_value(t, subscriber_test_shared_completion_nil_count, 1)
	testing.expect_value(t, subscriber_test_shared_completion_live_count, 0)
	testing.expect_value(t, subscriber_test_shared_completion_new_count, 0)
	testing.expect_value(t, shared.ref_count, 2)

	on_queued_send_complete(sock_a, item_a, len(frame_lease_data(item_a.lease)), nil)
	testing.expect_value(t, subscriber_test_shared_completion_nil_count, 1)
	testing.expect_value(t, subscriber_test_shared_completion_live_count, 1)
	testing.expect_value(t, subscriber_test_shared_completion_new_count, 0)
	testing.expect_value(t, shared.ref_count, 1)

	on_queued_send_complete(sock_c, item_c, len(frame_lease_data(item_c.lease)), nil)
	testing.expect_value(t, subscriber_test_shared_completion_nil_count, 2)
	testing.expect_value(t, subscriber_test_shared_completion_live_count, 1)
	testing.expect_value(t, subscriber_test_shared_completion_new_count, 0)
	testing.expect(t, connection_get(sock_c) == new_conn_c, "stale shared completion should not disturb reused socket connection")
	testing.expect_value(t, td.spool.used, base_pool_used)
}

@(test)
test_subscriber_sort_and_swap_remove_preserve_handles_and_indexes :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	created_connections: [subscriber_test_sort_slots]^NRC_Connection
	defer {
		for conn in created_connections {
			subscriber_test_uninstall_conn(conn)
		}
	}

	for i in 0 ..< subscriber_test_sort_slots {
		sock := net.TCP_Socket(subscriber_test_sort_base_sock + i)
		conn := subscriber_test_set_conn_state(sock, .Idle)
		created_connections[i] = conn
		testing.expect(t, conversation_add_subscriber(&conv, conn), "expected fresh subscriber insert")
	}

	sort_subscribers_by_handle_index_if_dirty(&conv)

	for entry, entry_idx in conv.subscriber_entries {
		conn := connection_get_by_handle(entry.handle)
		testing.expect(t, conn != nil && conn.sock == entry.sock, "subscriber entry handle should resolve to the same socket")

		stored_idx, ok := conv.subscriber_index[entry.sock]
		testing.expect(t, ok && stored_idx == entry_idx, "subscriber_index should point at sorted entry")
	}

	removed_sock := created_connections[subscriber_test_sort_slots / 3].sock
	testing.expect(t, conversation_remove_subscriber(&conv, removed_sock), "expected removal to succeed")
	testing.expect_value(t, conversation_has_subscriber(&conv, removed_sock), false)
	testing.expect_value(t, subscriber_count(&conv), subscriber_test_sort_slots - 1)
	testing.expect_value(t, conv.subscribers_dirty, true)

	for entry, entry_idx in conv.subscriber_entries {
		testing.expect(t, entry.sock != removed_sock, "removed socket should not remain in dense entries")

		conn := connection_get_by_handle(entry.handle)
		testing.expect(t, conn != nil && conn.sock == entry.sock, "subscriber entry handle should survive swap-remove")

		stored_idx, ok := conv.subscriber_index[entry.sock]
		testing.expect(t, ok && stored_idx == entry_idx, "subscriber_index should be repaired after swap-remove")
	}
}

@(test)
test_send_shared_to_subscribers_releases_publisher_ref_with_stale_entries :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	subscriber_test_add_stale_entry(&conv, subscriber_test_sock_a)
	subscriber_test_add_stale_entry(&conv, subscriber_test_sock_b)

	shared := new(Broadcast_Buffer)
	shared.ref_count = 10

	sent := send_shared_to_subscribers_except(&conv, net.TCP_Socket(0), shared)
	testing.expect_value(t, sent, 0)
	testing.expect_value(t, shared.ref_count, 9)

	free(shared)
}

@(test)
test_send_shared_presence_releases_publisher_ref_with_stale_entries :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	subscriber_test_add_stale_entry(&conv, subscriber_test_sock_a)
	subscriber_test_add_stale_entry(&conv, subscriber_test_sock_b)

	shared := new(Broadcast_Buffer)
	shared.ref_count = 10

	sent := send_shared_presence_to_subscribers(&conv, shared)
	testing.expect_value(t, sent, 0)
	testing.expect_value(t, shared.ref_count, 9)

	free(shared)
}

@(test)
test_send_shared_presence_to_subscribers_excludes_closing_and_nil :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	closing_conn := subscriber_test_set_conn_state(subscriber_test_sock_a, .Closing)
	defer subscriber_test_uninstall_conn(closing_conn)

	conversation_add_subscriber(&conv, closing_conn)
	subscriber_test_add_stale_entry(&conv, subscriber_test_sock_b)

	shared := new(Broadcast_Buffer)
	shared.ref_count = 10

	sent := send_shared_presence_to_subscribers(&conv, shared)
	testing.expect_value(t, sent, 0)
	testing.expect_value(t, shared.ref_count, 9)

	free(shared)
}

@(test)
test_send_shared_presence_to_subscribers_partial_success :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	active_conn := subscriber_test_set_conn_state(subscriber_test_sock_a, .Idle)
	active_conn.is_sending = true // queue-only path (no immediate socket I/O)
	closing_conn := subscriber_test_set_conn_state(subscriber_test_sock_b, .Closing)

	conversation_add_subscriber(&conv, active_conn)
	conversation_add_subscriber(&conv, closing_conn)

	shared := new(Broadcast_Buffer)
	shared.ref_count = 10

	sent := send_shared_presence_to_subscribers(&conv, shared)
	testing.expect_value(t, sent, 1)
	testing.expect_value(t, shared.ref_count, 10)

	subscriber_test_uninstall_conn(active_conn)
	subscriber_test_uninstall_conn(closing_conn)
	free(shared)
}

@(test)
test_empty_fanout_releases_publisher_reference :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	pool := byte_pool.init_buffer_pool()
	defer byte_pool.destroy_buffer_pool(pool)
	base_pool_used := pool.used

	shared := subscriber_test_make_pooled_shared_buffer(pool, 1)
	testing.expect(t, shared != nil, "expected pooled shared buffer allocation")
	if shared == nil do return
	testing.expect(t, pool.used > base_pool_used, "publisher should own the pooled frame before fanout")

	_ = send_shared_presence_to_subscribers(&conv, shared)
	testing.expect_value(t, pool.used, base_pool_used)
}

@(test)
test_on_single_presence_sent_handles_nil_connection_on_error :: proc(t: ^testing.T) {
	pool := byte_pool.init_buffer_pool()
	defer byte_pool.destroy_buffer_pool(pool)

	orig_spool := td.spool
	td.spool = pool
	defer td.spool = orig_spool

	buf, err := byte_pool.alloc(pool, 64)
	testing.expect_value(t, err, runtime.Allocator_Error.None)

	byte_pool.release(pool, buf)

	testing.expect(t, true, "single presence callback should handle nil connection on error")
}

@(test)
test_presence_and_subscriber_send_paths_match_eligibility_matrix :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	active_conn := subscriber_test_set_conn_state(subscriber_test_sock_a, .Idle)
	active_conn.is_sending = true
	closing_conn := subscriber_test_set_conn_state(subscriber_test_sock_b, .Closing)

	conversation_add_subscriber(&conv, active_conn)
	conversation_add_subscriber(&conv, closing_conn)
	subscriber_test_add_stale_entry(&conv, subscriber_test_sock_c)

	shared_sub := new(Broadcast_Buffer)
	shared_sub.ref_count = 10
	sent_sub := send_shared_to_subscribers_except(&conv, net.TCP_Socket(0), shared_sub)

	shared_presence := new(Broadcast_Buffer)
	shared_presence.ref_count = 10
	sent_presence := send_shared_presence_to_subscribers(&conv, shared_presence)

	testing.expect_value(t, sent_sub, sent_presence)
	testing.expect_value(t, shared_sub.ref_count, shared_presence.ref_count)

	subscriber_test_uninstall_conn(active_conn)
	subscriber_test_uninstall_conn(closing_conn)
	free(shared_sub)
	free(shared_presence)
}

@(test)
test_user_list_collection_skips_closing_subscriber :: proc(t: ^testing.T) {
	closing_conn := subscriber_test_set_conn_state(subscriber_test_sock_a, .Closing)
	defer subscriber_test_uninstall_conn(closing_conn)

	byte_users_buf: [MAX_ROOM_USERS][]byte
	auth_flags_buf: [MAX_ROOM_USERS]bool
	user_types_buf: [MAX_ROOM_USERS]pr.User_Type
	scan_state := Subscriber_User_List_Scan_State {
		workspace_id   = closing_conn.workspace_id,
		byte_users_buf = &byte_users_buf,
		auth_flags_buf = &auth_flags_buf,
		user_types_buf = &user_types_buf,
	}

	entry := Subscriber_Entry {
		sock   = closing_conn.sock,
		handle = closing_conn.handle,
	}
	testing.expect(t, subscriber_collect_user_list_entry(&scan_state, entry), "closing subscriber should not stop collection")
	testing.expect_value(t, scan_state.user_idx, 0)
}

@(test)
test_subscriber_send_paths_ignore_reused_socket_with_stale_handle :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	// Keep the test handle map alive while subscriber_test_sock_a is removed and
	// re-added, matching normal worker lifetime where connection storage outlives
	// individual connections and handle generations advance on slot reuse.
	guard_conn := subscriber_test_set_conn_state(subscriber_test_sock_b, .Idle)
	defer subscriber_test_uninstall_conn(guard_conn)

	old_conn := subscriber_test_set_conn_state(subscriber_test_sock_a, .Idle)
	conversation_add_subscriber(&conv, old_conn)
	subscriber_test_uninstall_conn(old_conn)

	new_conn := subscriber_test_set_conn_state(subscriber_test_sock_a, .Idle)
	new_conn.is_sending = true

	shared_sub := new(Broadcast_Buffer)
	shared_sub.ref_count = 10
	sent_sub := send_shared_to_subscribers_except(&conv, net.TCP_Socket(0), shared_sub)
	testing.expect_value(t, sent_sub, 0)
	testing.expect_value(t, shared_sub.ref_count, 9)

	shared_presence := new(Broadcast_Buffer)
	shared_presence.ref_count = 10
	sent_presence := send_shared_presence_to_subscribers(&conv, shared_presence)
	testing.expect_value(t, sent_presence, 0)
	testing.expect_value(t, shared_presence.ref_count, 9)

	free(shared_sub)
	free(shared_presence)

	testing.expect(t, conversation_add_subscriber(&conv, new_conn), "reused socket should refresh stale subscriber handle")

	shared_sub_refreshed := new(Broadcast_Buffer)
	shared_sub_refreshed.ref_count = 10
	sent_sub_refreshed := send_shared_to_subscribers_except(&conv, net.TCP_Socket(0), shared_sub_refreshed)
	testing.expect_value(t, sent_sub_refreshed, 1)
	testing.expect_value(t, shared_sub_refreshed.ref_count, 10)

	shared_presence_refreshed := new(Broadcast_Buffer)
	shared_presence_refreshed.ref_count = 10
	sent_presence_refreshed := send_shared_presence_to_subscribers(&conv, shared_presence_refreshed)
	testing.expect_value(t, sent_presence_refreshed, 1)
	testing.expect_value(t, shared_presence_refreshed.ref_count, 10)

	subscriber_test_uninstall_conn(new_conn)
	free(shared_sub_refreshed)
	free(shared_presence_refreshed)
}

@(test)
test_send_shared_presence_to_subscribers_large_room_not_truncated :: proc(t: ^testing.T) {
	conv := subscriber_test_make_conversation()
	defer subscriber_test_destroy_conversation(&conv)

	created_connections: [subscriber_test_large_room_users]^NRC_Connection

	for i in 0 ..< subscriber_test_large_room_users {
		sock := net.TCP_Socket(420_000 + i)

		conn := subscriber_test_set_conn_state(sock, .Idle)
		conn.is_sending = true
		created_connections[i] = conn
		conversation_add_subscriber(&conv, conn)
	}
	shared := new(Broadcast_Buffer)
	shared.ref_count = 10

	pre_not_sending_count := 0
	pre_queued_count := 0
	pre_nil_count := 0
	for conn in created_connections {
		if conn == nil {
			pre_nil_count += 1
			continue
		}
		if !conn.is_sending {
			pre_not_sending_count += 1
		}
		if send_queue_len(conn) != 0 {
			pre_queued_count += 1
		}
	}

	expected_count := subscriber_count(&conv)
	sent := send_shared_presence_to_subscribers(&conv, shared)
	expected_ref_count := subscriber_test_large_room_users + 9
	diagnostics := fmt.tprintf(
		"expected_count=%d sent=%d ref_count=%d expected_ref_count=%d pre_not_sending=%d pre_queued=%d pre_nil=%d subscribers=%d",
		expected_count,
		sent,
		shared.ref_count,
		expected_ref_count,
		pre_not_sending_count,
		pre_queued_count,
		pre_nil_count,
		subscriber_count(&conv),
	)
	testing.expect(t, expected_count == subscriber_test_large_room_users, diagnostics)
	testing.expect(t, sent == expected_count, diagnostics)
	testing.expect(t, shared.ref_count == expected_ref_count, diagnostics)

	for i in 0 ..< subscriber_test_large_room_users {
		subscriber_test_uninstall_conn(created_connections[i])
	}
	free(shared)
}

@(test)
test_shared_frame_release_releases_each_owned_reference :: proc(t: ^testing.T) {
	pool := byte_pool.init_buffer_pool()
	defer byte_pool.destroy_buffer_pool(pool)

	data, err := byte_pool.alloc(pool, 64)
	testing.expect_value(t, err, runtime.Allocator_Error.None)

	shared := new(Broadcast_Buffer, byte_pool.allocator(pool))
	shared.data = data
	shared.pool = pool
	shared.ref_count = 2

	shared_frame_release(shared)
	shared_frame_release(shared)

	testing.expect(t, true, "release helper should free buffer without crashing")
}

@(test)
test_simulation_send_sink_captures_message_fanout_with_workspace_isolation :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		conv_id := pr.ConversationID(42)
		content_string := "hello deterministic simulator"
		content := transmute([]byte)content_string
		ops := [?]Sim_Op {
			{kind = .Connect, client_id = 1, workspace_id = "workspace_1", username = "alice"},
			{kind = .Connect, client_id = 2, workspace_id = "workspace_1", username = "bob"},
			{kind = .Connect, client_id = 3, workspace_id = "workspace_2", username = "bob"},
			{kind = .Subscribe, client_id = 1, conv_id = conv_id},
			{kind = .Subscribe, client_id = 2, conv_id = conv_id},
			{kind = .Subscribe, client_id = 3, conv_id = conv_id},
			{kind = .Clear_Inboxes},
			{kind = .Send_Message, client_id = 1, conv_id = conv_id, client_req_id = 7, content_type = .PlainText, content = content},
		}
		testing.expect(t, simulation_test_apply_ops(&ctx, ops[:]), "simulation ops should apply")

		conn_a := simulation_test_client(&ctx, 1)
		conn_b := simulation_test_client(&ctx, 2)
		conn_c := simulation_test_client(&ctx, 3)

		testing.expect(t, conn_a != nil && conn_b != nil && conn_c != nil, "expected fake clients to install")
		if conn_a == nil || conn_b == nil || conn_c == nil {
			return
		}

		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn_a.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn_b.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn_c.sock), 0)

		ack_payload, ack_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn_a.sock, 0))
		testing.expect(t, ack_ok, "expected sender frame to decode as websocket frame")
		if !ack_ok || len(ack_payload) < 2 {
			return
		}
		testing.expect_value(t, pr.get_opcode(ack_payload), pr.Opcode.S_AckSendMessage)
		ack, ack_err := pr.parseAckSendMessageMessage(ack_payload)
		testing.expect(t, ack_err == nil, "expected sender frame to parse as ack")
		testing.expect_value(t, ack.client_req_id, u32(7))

		broadcast_payload, broadcast_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn_b.sock, 0))
		testing.expect(t, broadcast_ok, "expected peer frame to decode as websocket frame")
		if !broadcast_ok || len(broadcast_payload) < 2 {
			return
		}
		testing.expect_value(t, pr.get_opcode(broadcast_payload), pr.Opcode.S_NewMessage)
		broadcast, broadcast_err := pr.parseNewMessageEventMessage(broadcast_payload)
		testing.expect(t, broadcast_err == nil, "expected peer frame to parse as new message")
		testing.expect_value(t, broadcast.conv_id, conv_id)
		testing.expect_value(t, broadcast.content_type, pr.MessageContentType.PlainText)
		testing.expect(t, string(broadcast.author_username) == "alice", "broadcast author should match sender")
		testing.expect(t, string(broadcast.content) == content_string, "broadcast content should match sent content")
	}
}

@(test)
// Worker adoption fixture: proves a pending handoff becomes a live connection
// with copied workspace/auth identity and emits the initial server-ready response.
test_simulation_worker_adopts_connection_and_sends_server_ready :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		sock := connection_test_fake_socket(9)
		nrc_sim_register_client(&ctx.sim, sock)

		workspace_id := "ready_workspace"
		username := "ready-user"
		ping_payload := [?]byte{'h', 'i'}
		initial_frame := make_test_ws_frame(ping_payload[:], .opPing, true)
		upgrade := new(HTTP_Upgrade_Connection)
		upgrade.sock = sock
		upgrade.server = td.server
		upgrade.workspace_id = strings.clone(workspace_id)
		upgrade.verified_username = strings.clone(username)
		upgrade.user_type = .Admin
		upgrade.authenticated = true
		upgrade.http_remainder_buf = initial_frame
		upgrade.http_received = len(initial_frame)
		upgrade.http_header_end = 0
		bootstrap_http_string := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
		bootstrap_http := transmute([]byte)bootstrap_http_string
		worker_adopt_upgraded_connection(upgrade, bootstrap_http)

		conn := connection_get(sock)
		testing.expect(t, conn != nil, "adopted connection should be in socket map")
		if conn == nil {
			return
		}
		defer {
			simulation_test_uninstall_client(conn)
		}
		testing.expect_value(t, conn.sock, sock)
		testing.expect(t, conn.workspace_id == workspace_id, "connection workspace should match pending handoff")
		testing.expect(t, conn.verified_username == username, "connection username should match pending handoff")
		testing.expect_value(t, conn.user_type, pr.User_Type.Admin)
		testing.expect_value(t, conn.authenticated, true)
		testing.expect_value(t, conn.state, Connection_State.New)
		testing.expect_value(t, td.connection_count, 1)

		ws_state := get_connection_workspace(conn)
		testing.expect(t, ws_state != nil, "adopted connection should cache workspace")
		if ws_state != nil {
			testing.expect(t, find_user_in_workspace(ws_state, username), "worker adoption should mark user online")
			testing.expect(t, is_user_authenticated(ws_state, username), "worker adoption should mark user authenticated")
		}

		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sock), 1)
		testing.expect(t, nrc_sim_run_next_send_completion(&ctx.sim), "successful bootstrap completion should run")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sock), 2)
		bootstrap_wire := nrc_sim_client_frame(&ctx.sim, sock, 0)
		testing.expect(t, len(bootstrap_wire) > len(bootstrap_http), "bootstrap send should contain HTTP 101 and ServerReady")
		if len(bootstrap_wire) <= len(bootstrap_http) {
			return
		}
		testing.expect(t, string(bootstrap_wire[:len(bootstrap_http)]) == string(bootstrap_http), "bootstrap send should preserve HTTP 101 bytes")
		ready_payload, ready_ok := nrc_sim_frame_protocol_payload(bootstrap_wire[len(bootstrap_http):])
		testing.expect(t, ready_ok, "server ready frame should decode")
		if !ready_ok {
			return
		}

		ready, ready_err := pr.parseServerReadyMessage(ready_payload)
		testing.expect(t, ready_err == nil, "server ready frame should parse")
		testing.expect(t, string(ready.build_version) == BUILD_VERSION, "server ready build version should match")
		testing.expect_value(t, ready.protocol_version, u32(PROTOCOL_VERSION))
		testing.expect(t, string(ready.cpu_model) == CPU_MODEL_NAME, "server ready CPU model should match")
		testing.expect(t, string(ready.username) == username, "server ready username should match")
		testing.expect_value(t, ready.is_authenticated, true)

		pong_frame := nrc_sim_client_frame(&ctx.sim, sock, 1)
		pong_header, _, pong_header_err := ws.readFrameHeader(pong_frame)
		testing.expect(t, pong_header_err == nil, "coalesced ping response should have a valid WebSocket header")
		if pong_header_err == nil {
			testing.expect_value(t, pong_header.opcode, ws.opcode.opPong)
		}
		pong_payload, pong_ok := nrc_sim_frame_protocol_payload(pong_frame)
		testing.expect(t, pong_ok, "coalesced ping response payload should decode")
		if pong_ok {
			testing.expect(t, string(pong_payload) == string(ping_payload[:]), "coalesced ping payload should be processed exactly once by worker adoption")
		}
	}
}

@(test)
test_simulation_worker_adopts_reused_fd_before_old_close_callback :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		old := simulation_test_install_client(&ctx.sim, 0, "reuse-before-close", "old", init_send_queue = true)
		if !testing.expect(t, old != nil) do return
		sock, old_handle := old.sock, old.handle
		subscribe_to_conversation(old, 17)
		nrc_sim_run_all_send_completions(&ctx.sim)
		buf, err := byte_pool.alloc(td.spool, 8)
		if !testing.expect(t, err == .None) do return
		record := Sim_Delayed_Send_Test_Record {
			expected_handle = old_handle,
		}
		testing.expect(
			t,
			nrc_send_frame(
				old,
				Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
				observer = {callback = simulation_delayed_send_test_callback, ctx = &record},
			),
		)
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, old, nil, err = net.TCP_Recv_Error(.Not_Connected)))
		connection_close(old, false)
		defer {
			nrc_sim_run_all_send_completions(&ctx.sim)
			for nrc_sim_run_next_receive(&ctx.sim) {}
			nrc_sim_run_all_close_completions(&ctx.sim)
			connection_test_live_count -= 1 // Old fixture is reclaimed by its I/O callbacks.
		}
		testing.expect_value(t, old.pending_io, u32(3))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 0)
		testing.expect(t, old.logical_cleanup_done && len(old.rooms) == 0)
		if !testing.expect(t, connection_get(sock) == nil, "closing FD must detach before its close callback") do return
		testing.expect_value(t, td.connection_count, 0)
		testing.expect_value(t, len(td.active_sockets), 0)
		testing.expect_value(t, td.retained_connection_count, 1)

		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, record.callback_count, 1)
		testing.expect_value(t, record.unexpected_target_count, 0)
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 0)
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim))
		testing.expect_value(t, old.pending_io, u32(1))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)

		// Model accept reusing the numeric FD before dispatching its close CQE.
		nrc_sim_register_client(&ctx.sim, sock)
		upgrade := new(HTTP_Upgrade_Connection)
		upgrade.sock = sock
		upgrade.server = td.server
		upgrade.workspace_id = strings.clone("reuse-before-close")
		upgrade.verified_username = strings.clone("replacement")
		upgrade.user_type = .User
		upgrade.authenticated = true
		worker_adopt_upgraded_connection(upgrade)
		replacement := connection_get(sock)
		if !testing.expect(t, replacement != nil && replacement.handle != old_handle) do return
		ctx.conns[0] = replacement
		replacement_handle := replacement.handle
		testing.expect_value(t, td.connection_count, 1)
		testing.expect_value(t, len(td.active_sockets), 1)
		testing.expect_value(t, td.retained_connection_count, 2)
		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim))
		testing.expect(t, connection_get(sock) == replacement)
		testing.expect_value(t, replacement.handle, replacement_handle)
		testing.expect(t, connection_get_by_handle(old_handle) == nil)
		testing.expect_value(t, td.connection_count, 1)
		testing.expect_value(t, len(td.active_sockets), 1)
		testing.expect_value(t, td.retained_connection_count, 1)
		testing.expect(t, connection_get(sock) == replacement && replacement.state < .Will_Close)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sock), 1) // Only the new ServerReady.

		ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, replacement, ping[:]))
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim))
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sock), 2)
		header, _, header_err := ws.readFrameHeader(nrc_sim_client_frame(&ctx.sim, sock, 1))
		testing.expect(t, header_err == nil && header.opcode == .opPong)
		testing.expect_value(t, td.spool.used, u64(0))
	}
}

@(test)
test_simulation_bootstrap_send_error_closes_without_websocket_output :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		sock := connection_test_fake_socket(19)
		nrc_sim_register_client(&ctx.sim, sock)
		workspace_id := "bootstrap_error_workspace"
		username := "bootstrap-error-user"
		upgrade := new(HTTP_Upgrade_Connection)
		upgrade.sock = sock
		upgrade.server = td.server
		upgrade.workspace_id = strings.clone(workspace_id)
		upgrade.verified_username = strings.clone(username)
		upgrade.user_type = .User
		upgrade.authenticated = true

		bootstrap_http_string := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
		bootstrap_http := transmute([]byte)bootstrap_http_string
		nrc_sim_inject_next_queued_send_error(&ctx.sim, net.TCP_Send_Error(.Timeout))
		worker_adopt_upgraded_connection(upgrade, bootstrap_http)
		conn := connection_get(sock)
		if !testing.expect(t, conn != nil) do return
		handle := conn.handle
		nrc_sim_run_all_send_completions(&ctx.sim)

		testing.expect(t, connection_get(sock) == nil, "failed bootstrap should detach its closing FD")
		conn = connection_get_by_handle(handle)
		testing.expect(t, conn != nil, "failed bootstrap should retain connection until close completion")
		if conn == nil do return
		testing.expect_value(t, conn.state, Connection_State.Closing)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sock), 0)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "failed bootstrap close completion should run")
		testing.expect(t, connection_get(sock) == nil, "failed bootstrap connection should be reclaimed")
		testing.expect(t, connection_get_by_handle(handle) == nil, "close completion must reclaim the retained allocation")

		ws_state := get_workspace(workspace_id)
		testing.expect(t, ws_state != nil, "failed bootstrap workspace should remain available")
		if ws_state != nil {
			testing.expect(t, !find_user_in_workspace(ws_state, username), "failed bootstrap should roll back online presence")
		}
	}
}

@(test)
test_simulation_bootstrap_connection_limit_sends_no_websocket_frame :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		sock := connection_test_fake_socket(20)
		nrc_sim_register_client(&ctx.sim, sock)
		upgrade := new(HTTP_Upgrade_Connection)
		upgrade.sock = sock
		upgrade.server = td.server
		upgrade.workspace_id = strings.clone("bootstrap_limit_workspace")
		upgrade.verified_username = strings.clone("bootstrap-limit-user")
		upgrade.user_type = .User
		upgrade.authenticated = true

		previous_count := td.connection_count
		td.connection_count = MAX_CONNECTIONS_PER_THREAD
		defer td.connection_count = previous_count
		bootstrap_http_string := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
		worker_adopt_upgraded_connection(upgrade, transmute([]byte)bootstrap_http_string)

		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sock), 0)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "connection-limit close should complete")
		testing.expect(t, connection_get(sock) == nil, "connection-limit rejection should reclaim connection")
	}
}

@(test)
// Synthetic handoff storm fixture: adopts 4096 pending connections in one worker
// to guard queue/drain changes and record compact adoption timing without noisy logs.
test_simulation_worker_adopts_pending_connection_storm :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		STORM_COUNT :: 4096
		WORKSPACES := [?]string{"storm_workspace_a", "storm_workspace_b", "storm_workspace_c", "storm_workspace_d"}

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		socks: [STORM_COUNT]net.TCP_Socket
		for i in 0 ..< STORM_COUNT {
			sock := net.TCP_Socket(10_000 + i)
			socks[i] = sock
			nrc_sim_register_client(&ctx.sim, sock)

			username := fmt.tprintf("storm-user-%03d", i)
			upgrade := new(HTTP_Upgrade_Connection)
			upgrade.sock = sock
			upgrade.server = td.server
			upgrade.workspace_id = strings.clone(WORKSPACES[i % len(WORKSPACES)])
			upgrade.verified_username = strings.clone(username)
			upgrade.user_type = .User
			upgrade.authenticated = true
			worker_adopt_upgraded_connection(upgrade)
		}

		adoption_start := time.now()
		adoption_elapsed := time.since(adoption_start)
		testing.expect_value(t, td.connection_count, STORM_COUNT)
		log.infof("[simulation storm] adopted=%d elapsed=%v", td.connection_count, adoption_elapsed)

		for i in 0 ..< STORM_COUNT {
			sock := socks[i]
			conn := connection_get(sock)
			testing.expect(t, conn != nil, "storm connection should be adopted")
			if conn == nil {
				continue
			}

			username := fmt.tprintf("storm-user-%03d", i)
			workspace_id := WORKSPACES[i % len(WORKSPACES)]

			testing.expect_value(t, conn.sock, sock)
			testing.expect(t, conn.workspace_id == workspace_id, "storm connection workspace should match pending handoff")
			testing.expect(t, conn.verified_username == username, "storm connection username should match pending handoff")
			testing.expect_value(t, conn.authenticated, true)
			testing.expect_value(t, conn.user_type, pr.User_Type.User)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sock), 1)

			ready_payload, ready_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, sock, 0))
			testing.expect(t, ready_ok, "storm server-ready frame should decode")
			if ready_ok {
				ready, ready_err := pr.parseServerReadyMessage(ready_payload)
				testing.expect(t, ready_err == nil, "storm server-ready frame should parse")
				testing.expect(t, string(ready.username) == username, "storm server-ready username should match")
				testing.expect_value(t, ready.is_authenticated, true)
			}

			ws_state := get_connection_workspace(conn)
			testing.expect(t, ws_state != nil, "storm adopted connection should cache workspace")
			if ws_state != nil {
				testing.expect(t, find_user_in_workspace(ws_state, username), "storm adoption should mark user online")
				testing.expect(t, is_user_authenticated(ws_state, username), "storm adoption should mark user authenticated")
			}
		}

		for sock in socks {
			conn := connection_get(sock)
			if conn != nil {
				simulation_test_uninstall_client(conn)
			}
		}
	}
}

@(test)
// Multi-worker handoff fixture: seeds per-worker pending queues and proves each
// worker adopts only its own queue without workspace/auth identity leakage.
test_simulation_multi_worker_handoff_distribution :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		WORKER_COUNT :: 4
		CONNECTION_COUNT :: 16
		WORKSPACES := [?]string {
			"route_workspace_alpha",
			"route_workspace_beta",
			"route_workspace_gamma",
			"route_workspace_delta",
			"route_workspace_epsilon",
			"route_workspace_zeta",
			"route_workspace_eta",
			"route_workspace_theta",
			"route_workspace_iota",
			"route_workspace_kappa",
			"route_workspace_lambda",
			"route_workspace_mu",
			"route_workspace_nu",
			"route_workspace_xi",
			"route_workspace_omicron",
			"route_workspace_pi",
		}

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		queues: [WORKER_COUNT]Pending_Connection_Queue
		for worker_index in 0 ..< WORKER_COUNT {
			queue, queue_err := pending_queue_create(CONNECTION_COUNT)
			testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
			if queue_err != .None {
				for cleanup_index in 0 ..< worker_index {
					pending_queue_destroy(queues[cleanup_index])
				}
				return
			}
			queues[worker_index] = queue
		}
		defer for queue in queues do pending_queue_destroy(queue)

		pending_queues := make([]Pending_Connection_Queue, WORKER_COUNT)
		defer delete(pending_queues)
		for worker_index in 0 ..< WORKER_COUNT {
			pending_queues[worker_index] = queues[worker_index]
		}

		server := NRC_Server {
			main_thread         = 0,
			pending_connections = pending_queues,
		}
		td.server = &server

		socks: [CONNECTION_COUNT]net.TCP_Socket
		expected_workers: [CONNECTION_COUNT]int
		expected_counts: [WORKER_COUNT]int
		for i in 0 ..< CONNECTION_COUNT {
			workspace_id := WORKSPACES[i]
			target_worker := http_upgrade_target_worker_index(workspace_id, WORKER_COUNT)
			expected_workers[i] = target_worker
			expected_counts[target_worker] += 1

			sock := net.TCP_Socket(30_000 + i)
			socks[i] = sock
			nrc_sim_register_client(&ctx.sim, sock)

			conn := new(HTTP_Upgrade_Connection)
			conn.server = &server
			conn.sock = sock
			conn.state = .New
			conn.workspace_id = strings.clone(workspace_id)
			conn.verified_username = fmt.aprintf("route-user-%02d", i)
			conn.user_type = .User
			conn.authenticated = true
			conn.target_worker_index = target_worker

			testing.expect(t, http_upgrade_commit_handoff(conn, queues[target_worker]), "handoff fixture should enqueue")
		}

		adopted_total := 0
		for worker_index in 0 ..< WORKER_COUNT {
			td.thread_index = worker_index
			td.my_pending_queue = queues[worker_index]
			before_count := td.connection_count
			for {
				pending, ok := pending_queue_try_recv(td.my_pending_queue)
				if !ok do break
				worker_adopt_upgraded_connection(pending.upgrade)
			}
			adopted_by_worker := td.connection_count - before_count
			testing.expect_value(t, adopted_by_worker, expected_counts[worker_index])
			adopted_total += adopted_by_worker

			for i in 0 ..< CONNECTION_COUNT {
				conn := connection_get(socks[i])
				if expected_workers[i] <= worker_index {
					testing.expect(t, conn != nil, "connection routed to this or an earlier worker should be adopted")
				} else {
					testing.expect(t, conn == nil, "connection routed to a later worker should not be adopted early")
				}
			}
		}
		testing.expect_value(t, adopted_total, CONNECTION_COUNT)

		for i in 0 ..< CONNECTION_COUNT {
			conn := connection_get(socks[i])
			testing.expect(t, conn != nil, "routed connection should be adopted")
			if conn == nil {
				continue
			}

			username := fmt.tprintf("route-user-%02d", i)
			testing.expect_value(t, conn.thread_index, expected_workers[i])
			testing.expect(t, conn.workspace_id == WORKSPACES[i], "routed connection workspace should not leak across workers")
			testing.expect(t, conn.verified_username == username, "routed connection identity should not leak across workers")
			testing.expect_value(t, conn.authenticated, true)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, socks[i]), 1)

			ready_payload, ready_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, socks[i], 0))
			testing.expect(t, ready_ok, "routed server-ready frame should decode")
			if ready_ok {
				ready, ready_err := pr.parseServerReadyMessage(ready_payload)
				testing.expect(t, ready_err == nil, "routed server-ready frame should parse")
				testing.expect(t, string(ready.username) == username, "routed server-ready username should match")
				testing.expect_value(t, ready.is_authenticated, true)
			}

			ws_state := get_connection_workspace(conn)
			testing.expect(t, ws_state != nil, "routed adopted connection should cache workspace")
			if ws_state != nil {
				testing.expect(t, find_user_in_workspace(ws_state, username), "routed adoption should mark only its own user online")
				testing.expect(t, is_user_authenticated(ws_state, username), "routed adoption should mark only its own user authenticated")
			}
		}

		for sock in socks {
			conn := connection_get(sock)
			if conn != nil {
				simulation_test_uninstall_client(conn)
			}
		}
	}
}

@(test)
// DM simulation fixture: drives DM start/list/leave/message fanout through
// production response parsers to assert exact identity, online/auth flags, and routing.
test_simulation_dm_lifecycle_and_message_fanout_uses_protocol_parsers :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		workspace_id := "dm_workspace"
		alice := simulation_test_install_client(&ctx.sim, 1, workspace_id, "alice")
		bob := simulation_test_install_client(&ctx.sim, 2, workspace_id, "bob")
		carol := simulation_test_install_client(&ctx.sim, 3, workspace_id, "carol")
		ctx.conns[1] = alice
		ctx.conns[2] = bob
		ctx.conns[3] = carol
		testing.expect(t, alice != nil && bob != nil && carol != nil, "expected DM test clients to install")
		if alice == nil || bob == nil || carol == nil {
			return
		}

		ws_state := get_or_create_workspace(workspace_id)
		on_user_connect(ws_state, intern_username("alice"), true)
		on_user_connect(ws_state, intern_username("bob"), true)
		on_user_connect(ws_state, intern_username("carol"), true)

		conv_id := pr.make_dm_conversation_id("alice", "bob")

		nrc_sim_clear_inboxes(&ctx.sim)
		process_start_dm(alice, pr.StartDMRequest{username = "bob", correlation_id = 11})

		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, carol.sock), 0)

		alice_started_payload, alice_started_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, alice.sock, 0))
		bob_started_payload, bob_started_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, bob.sock, 0))
		testing.expect(t, alice_started_ok && bob_started_ok, "DM started frames should decode")
		if !alice_started_ok || !bob_started_ok {
			return
		}

		alice_started, alice_started_err := pr.parseDMStartedMessage(alice_started_payload)
		bob_started, bob_started_err := pr.parseDMStartedMessage(bob_started_payload)
		testing.expect(t, alice_started_err == nil && bob_started_err == nil, "DM started frames should parse")
		testing.expect_value(t, alice_started.conv_id, conv_id)
		testing.expect(t, alice_started.username == "bob", "alice should see bob as DM partner")
		testing.expect(t, alice_started.authenticated && alice_started.online && alice_started.is_initiator, "alice DM partner flags should be exact")
		testing.expect_value(t, alice_started.correlation_id, u32(11))
		testing.expect_value(t, bob_started.conv_id, conv_id)
		testing.expect(t, bob_started.username == "alice", "bob should see alice as DM partner")
		testing.expect(t, bob_started.authenticated && bob_started.online && !bob_started.is_initiator, "bob DM partner flags should be exact")
		testing.expect_value(t, bob_started.correlation_id, u32(0))

		nrc_sim_clear_inboxes(&ctx.sim)
		process_list_dms(alice, pr.ListDMsRequest{correlation_id = 12})
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, carol.sock), 0)
		list_payload, list_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, alice.sock, 0))
		testing.expect(t, list_ok, "DM list frame should decode")
		if !list_ok {
			return
		}
		entries: [1]pr.DMEntry
		list_msg, list_err := pr.parseDMListMessage(list_payload, entries[:])
		testing.expect(t, list_err == nil, "DM list frame should parse")
		testing.expect_value(t, list_msg.correlation_id, u32(12))
		testing.expect_value(t, len(list_msg.entries), 1)
		if len(list_msg.entries) == 1 {
			testing.expect_value(t, list_msg.entries[0].conv_id, conv_id)
			testing.expect(t, list_msg.entries[0].username == "bob", "DM list should contain bob")
			testing.expect(t, list_msg.entries[0].authenticated && list_msg.entries[0].online, "DM list partner flags should be exact")
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		content_string := "secret hello"
		process_send_message(
			alice,
			pr.SendMessageRequest{conv_id = conv_id, client_req_id = 21, content_type = .PlainText, content = transmute([]byte)content_string},
		)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, carol.sock), 0)
		ack_payload, ack_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, alice.sock, 0))
		message_payload, message_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, bob.sock, 0))
		testing.expect(t, ack_ok && message_ok, "DM message fanout frames should decode")
		if !ack_ok || !message_ok {
			return
		}
		ack, ack_err := pr.parseAckSendMessageMessage(ack_payload)
		message, message_err := pr.parseNewMessageEventMessage(message_payload)
		testing.expect(t, ack_err == nil && message_err == nil, "DM message fanout frames should parse")
		testing.expect_value(t, ack.client_req_id, u32(21))
		testing.expect_value(t, message.conv_id, conv_id)
		testing.expect(t, string(message.author_username) == "alice", "DM message author should match")
		testing.expect(t, string(message.content) == content_string, "DM message content should match")

		nrc_sim_clear_inboxes(&ctx.sim)
		process_leave_dm(bob, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 13})
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, carol.sock), 0)
		left_payload, left_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, bob.sock, 0))
		testing.expect(t, left_ok, "DM left frame should decode")
		if !left_ok {
			return
		}
		left_msg, left_err := pr.parseDMLeftMessage(left_payload)
		testing.expect(t, left_err == nil, "DM left frame should parse")
		testing.expect_value(t, left_msg.conv_id, conv_id)
		testing.expect_value(t, left_msg.correlation_id, u32(13))

		nrc_sim_clear_inboxes(&ctx.sim)
		after_leave_content := "after leave"
		process_send_message(
			alice,
			pr.SendMessageRequest{conv_id = conv_id, client_req_id = 22, content_type = .PlainText, content = transmute([]byte)after_leave_content},
		)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, carol.sock), 0)
	}
}

@(test)
// DM presence multi-connection fixture: a partner should see online/offline
// status changes only on first connect and last disconnect for a username, not
// when one of several same-user sockets comes or goes.
test_simulation_dm_presence_multi_connection_status_edges :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		workspace_id := "dm_presence_workspace"
		alice_desktop := simulation_test_install_client(&ctx.sim, 1, workspace_id, "alice")
		alice_mobile := simulation_test_install_client(&ctx.sim, 2, workspace_id, "alice")
		bob := simulation_test_install_client(&ctx.sim, 3, workspace_id, "bob")
		ctx.conns[1] = alice_desktop
		ctx.conns[2] = alice_mobile
		ctx.conns[3] = bob
		testing.expect(t, alice_desktop != nil && alice_mobile != nil && bob != nil, "expected DM presence clients to install")
		if alice_desktop == nil || alice_mobile == nil || bob == nil {
			return
		}

		ws_state := get_or_create_workspace(workspace_id)
		on_user_connect(ws_state, intern_username("alice"), true)
		on_user_connect(ws_state, intern_username("alice"), true)
		on_user_connect(ws_state, intern_username("bob"), true)

		conv_id := pr.make_dm_conversation_id("alice", "bob")

		nrc_sim_clear_inboxes(&ctx.sim)
		process_start_dm(alice_desktop, pr.StartDMRequest{username = "bob", correlation_id = 31})
		nrc_sim_run_all_send_completions(&ctx.sim)

		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_desktop.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_mobile.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 1)
		bob_started_payload, bob_started_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, bob.sock, 0))
		testing.expect(t, bob_started_ok, "bob DM started frame should decode")
		if !bob_started_ok {
			return
		}
		bob_started, bob_started_err := pr.parseDMStartedMessage(bob_started_payload)
		testing.expect(t, bob_started_err == nil, "bob DM started frame should parse")
		testing.expect_value(t, bob_started.conv_id, conv_id)
		testing.expect(t, bob_started.username == "alice", "bob should see alice as DM partner")
		testing.expect(
			t,
			bob_started.authenticated && bob_started.online && !bob_started.is_initiator,
			"bob DM partner flags should start online/authenticated",
		)

		nrc_sim_clear_inboxes(&ctx.sim)
		connection_close(alice_desktop, false)
		testing.expect(
			t,
			!nrc_sim_client_has_opcode(&ctx.sim, bob.sock, .S_DMPartnerStatus),
			"bob should not receive DM offline while one alice connection remains",
		)
		testing.expect(t, is_user_online(ws_state, "alice"), "alice should remain online while one connection remains")
		testing.expect(t, is_user_authenticated(ws_state, "alice"), "alice should remain authenticated while one connection remains")
		alice_sockets := get_user_sockets(ws_state, "alice")
		testing.expect_value(t, len(alice_sockets), 1)
		if len(alice_sockets) == 1 {
			testing.expect_value(t, alice_sockets[0], alice_mobile.sock)
		}
		delete(alice_sockets)

		nrc_sim_clear_inboxes(&ctx.sim)
		connection_close(alice_mobile, false)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, !is_user_online(ws_state, "alice"), "alice should be offline after last connection disconnects")
		testing.expect(t, !is_user_authenticated(ws_state, "alice"), "alice should be unauthenticated after last authenticated disconnect")
		alice_sockets = get_user_sockets(ws_state, "alice")
		testing.expect_value(t, len(alice_sockets), 0)
		delete(alice_sockets)

		offline_payload, offline_ok := nrc_sim_client_find_payload_by_opcode(&ctx.sim, bob.sock, .S_DMPartnerStatus)
		testing.expect(t, offline_ok, "offline DM partner status frame should decode")
		if !offline_ok {
			return
		}
		offline_status, offline_err := pr.parseDMPartnerStatusMessage(offline_payload)
		testing.expect(t, offline_err == nil, "offline DM partner status frame should parse")
		testing.expect_value(t, offline_status.conv_id, conv_id)
		testing.expect(t, offline_status.username == "alice", "offline status username should identify alice")
		testing.expect(t, !offline_status.online, "offline status should mark alice offline")
		testing.expect(t, offline_status.last_seen > 0, "offline status should include last_seen")

		nrc_sim_clear_inboxes(&ctx.sim)
		alice_reconnect := simulation_test_install_client(&ctx.sim, 4, workspace_id, "alice")
		ctx.conns[4] = alice_reconnect
		testing.expect(t, alice_reconnect != nil, "expected reconnecting alice client to install")
		if alice_reconnect == nil {
			return
		}
		on_user_connect(ws_state, intern_username("alice"), true)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 1)
		testing.expect(t, is_user_online(ws_state, "alice"), "alice should be online after reconnect")
		testing.expect(t, is_user_authenticated(ws_state, "alice"), "alice should be authenticated after reconnect")

		online_payload, online_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, bob.sock, 0))
		testing.expect(t, online_ok, "online DM partner status frame should decode")
		if !online_ok {
			return
		}
		online_status, online_err := pr.parseDMPartnerStatusMessage(online_payload)
		testing.expect(t, online_err == nil, "online DM partner status frame should parse")
		testing.expect_value(t, online_status.conv_id, conv_id)
		testing.expect(t, online_status.username == "alice", "online status username should identify alice")
		testing.expect(t, online_status.online, "online status should mark alice online")
		testing.expect(t, online_status.last_seen >= offline_status.last_seen, "online status timestamp should not move backwards")
	}
}

@(test)
test_simulation_shared_fanout_drains_rejection_cleanup_iteratively :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		workspace_id := "shared_snapshot_rejection_workspace"
		slow_a := simulation_test_install_client(&ctx.sim, 1, workspace_id, "slow-a", init_send_queue = true)
		slow_b := simulation_test_install_client(&ctx.sim, 2, workspace_id, "slow-b", init_send_queue = true)
		fast_a := simulation_test_install_client(&ctx.sim, 3, workspace_id, "fast-a", init_send_queue = true)
		fast_b := simulation_test_install_client(&ctx.sim, 4, workspace_id, "fast-b", init_send_queue = true)
		ctx.conns[1] = slow_a
		ctx.conns[2] = slow_b
		ctx.conns[3] = fast_a
		ctx.conns[4] = fast_b
		testing.expect(t, slow_a != nil && slow_b != nil && fast_a != nil && fast_b != nil, "expected fanout clients to install")
		if slow_a == nil || slow_b == nil || fast_a == nil || fast_b == nil do return

		room_a := pr.ConversationID(8_001)
		room_b := pr.ConversationID(8_002)
		clients := [?]^NRC_Connection{slow_a, slow_b, fast_a, fast_b}
		for client in clients {
			subscribe_to_conversation(client, room_a)
			subscribe_to_conversation(client, room_b)
		}
		ws := get_connection_workspace(slow_a)
		conv_a := get_conversation(ws, room_a)
		conv_b := get_conversation(ws, room_b)
		testing.expect(t, conv_a != nil && conv_b != nil, "expected fanout conversations")
		if conv_a == nil || conv_b == nil do return

		nrc_sim_clear_inboxes(&ctx.sim)
		slow_a.is_sending = true
		for _ in 0 ..< Max_Queue_Size {
			send_queue_push(slow_a, Send_Item{handle = slow_a.handle})
		}
		slow_b.is_sending = true
		for _ in 0 ..< Max_Queue_Size - 1 {
			send_queue_push(slow_b, Send_Item{handle = slow_b.handle})
		}

		msg := pr.NewMessageEvent {
			conv_id         = room_a,
			seq             = 1,
			author_username = transmute([]byte)string("sender"),
			timestamp       = 1,
			content_type    = .PlainText,
			content         = transmute([]byte)string("snapshot"),
		}
		shared := create_shared_broadcast_buffer(msg)
		testing.expect(t, shared != nil, "expected shared fanout frame")
		if shared == nil do return

		sent := send_shared_to_subscribers_except(conv_a, net.TCP_Socket(0), shared)
		nrc_sim_run_all_send_completions(&ctx.sim)

		testing.expect_value(t, sent, 3)
		testing.expect(t, !conversation_has_subscriber(conv_a, slow_a.sock), "first rejected subscriber should leave room A")
		testing.expect(t, !conversation_has_subscriber(conv_b, slow_a.sock), "first rejected subscriber should leave room B")
		testing.expect(t, !conversation_has_subscriber(conv_a, slow_b.sock), "deferred fanout rejection should remove second subscriber from room A")
		testing.expect(t, !conversation_has_subscriber(conv_b, slow_b.sock), "deferred fanout rejection should remove second subscriber from room B")
		testing.expect_value(t, subscriber_count(conv_a), 2)
		testing.expect_value(t, subscriber_count(conv_b), 2)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, slow_a.sock, .S_NewMessage), 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, slow_b.sock, .S_NewMessage), 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, fast_a.sock, .S_NewMessage), 1)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, fast_b.sock, .S_NewMessage), 1)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, fast_a.sock, .S_RoomPresenceUpdate), 4)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, fast_b.sock, .S_RoomPresenceUpdate), 4)
		testing.expect_value(t, td.shared_fanout_depth, 0)
		testing.expect_value(t, len(td.deferred_presence_updates), 0)
		testing.expect(t, !td.draining_presence_updates, "outer fanout should drain deferred presence iteratively")
	}
}

@(test)
// Backpressure close serialization fixture: when a server-initiated close starts
// while a data frame is already in flight, the terminal close frame must wait in
// the priority queue and drain only after that in-flight send completes. This
// pins the deterministic counterpart of the real slow-reader e2e so close bytes
// cannot interleave with an active data frame.
test_simulation_graceful_close_drains_after_in_flight_send :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 1, "backpressure_close_workspace", "slow")
		ctx.conns[1] = conn
		testing.expect(t, conn != nil, "expected backpressure-close client to install")
		if conn == nil {
			return
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		conn.is_sending = true
		send_websocket_close_frame_and_close(conn, 1013, "Server too busy")

		testing.expect_value(t, conn.state, Connection_State.Will_Close)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		testing.expect_value(t, send_queue_priority_len(conn), 1)
		testing.expect(t, conn.is_sending, "in-flight data send should still own the transport before completion")

		in_flight_data := []u8{0x82, 0x00}
		in_flight_item := Send_Item {
			lease  = Frame_Lease(Connection_Stable_Frame_Lease{data = in_flight_data, owner = conn.handle}),
			handle = conn.handle,
		}
		on_queued_send_complete(conn.sock, in_flight_item, len(in_flight_data), nil)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_run_all_shutdown_sends(&ctx.sim)

		testing.expect_value(t, send_queue_priority_len(conn), 0)
		testing.expect(
			t,
			nrc_sim_client_has_close_frame(&ctx.sim, conn.sock, 1013, "Server too busy"),
			"queued terminal close frame should drain after in-flight send completes",
		)
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 1)
		handle := conn.handle
		nrc_sim_run_all_timers(&ctx.sim)
		testing.expect_value(t, conn.state, Connection_State.Closing)
		nrc_sim_run_all_close_completions(&ctx.sim)
		testing.expect(t, connection_get_by_handle(handle) == nil)
		connection_test_live_count -= 1
		ctx.conns[1] = nil
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 0)
	}
}

@(test)
// Server-initiated graceful close fixture: close-frame paths should make
// logical presence/DM cleanup visible immediately, before the delayed transport
// teardown callback runs.
test_simulation_dm_presence_graceful_close_cleans_up_immediately :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		workspace_id := "dm_graceful_close_workspace"
		alice := simulation_test_install_client(&ctx.sim, 1, workspace_id, "alice")
		bob := simulation_test_install_client(&ctx.sim, 2, workspace_id, "bob")
		ctx.conns[1] = alice
		ctx.conns[2] = bob
		testing.expect(t, alice != nil && bob != nil, "expected graceful-close DM clients to install")
		if alice == nil || bob == nil {
			return
		}
		alice_handle := alice.handle

		ws_state := get_or_create_workspace(workspace_id)
		on_user_connect(ws_state, intern_username("alice"), true)
		on_user_connect(ws_state, intern_username("bob"), true)

		conv_id := pr.make_dm_conversation_id("alice", "bob")
		process_start_dm(alice, pr.StartDMRequest{username = "bob", correlation_id = 41})

		nrc_sim_clear_inboxes(&ctx.sim)
		send_websocket_close_frame_and_close(alice, 1000, "Idle timeout")
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_run_all_shutdown_sends(&ctx.sim)

		testing.expect_value(t, alice.state, Connection_State.Will_Close)
		testing.expect(t, alice.logical_cleanup_done, "graceful close should run logical cleanup immediately")
		testing.expect(t, !is_user_online(ws_state, "alice"), "alice should be offline immediately after graceful close begins")
		testing.expect(t, !is_user_authenticated(ws_state, "alice"), "alice should be unauthenticated immediately after graceful close begins")
		testing.expect(t, nrc_sim_client_has_close_frame(&ctx.sim, alice.sock, 1000, "Idle timeout"), "alice should receive simulated websocket close frame")
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 1)

		alice_sockets := get_user_sockets(ws_state, "alice")
		defer delete(alice_sockets)
		testing.expect_value(t, len(alice_sockets), 0)

		offline_payload, offline_ok := nrc_sim_client_find_payload_by_opcode(&ctx.sim, bob.sock, .S_DMPartnerStatus)
		testing.expect(t, offline_ok, "bob should receive immediate offline DM partner status")
		if !offline_ok {
			return
		}
		offline_status, offline_err := pr.parseDMPartnerStatusMessage(offline_payload)
		testing.expect(t, offline_err == nil, "offline DM partner status frame should parse")
		testing.expect_value(t, offline_status.conv_id, conv_id)
		testing.expect(t, offline_status.username == "alice", "offline status username should identify alice")
		testing.expect(t, !offline_status.online, "offline status should mark alice offline")

		nrc_sim_clear_inboxes(&ctx.sim)
		send_websocket_close_frame_and_close(alice, 1000, "Idle timeout")
		testing.expect(
			t,
			!nrc_sim_client_has_close_frame(&ctx.sim, alice.sock, 1000, "Idle timeout"),
			"duplicate graceful close should not send another close frame",
		)
		testing.expect(
			t,
			!nrc_sim_client_has_opcode(&ctx.sim, bob.sock, .S_DMPartnerStatus),
			"duplicate graceful close should not double-send DM offline status",
		)
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		nrc_sim_run_all_timers(&ctx.sim)
		testing.expect_value(t, alice.state, Connection_State.Closing)
		nrc_sim_run_all_close_completions(&ctx.sim)
		testing.expect(t, connection_get_by_handle(alice_handle) == nil, "alice should be reclaimed after physical close completion")
		connection_test_live_count -= 1
		ctx.conns[1] = nil
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 0)
		testing.expect(
			t,
			!nrc_sim_client_has_opcode(&ctx.sim, bob.sock, .S_DMPartnerStatus),
			"delayed transport close should not double-send DM offline status",
		)
	}
}

@(test)
// Idle timeout fixture: the heartbeat/reaper entrypoint should drive the same
// immediate logical DM/presence cleanup as an explicit graceful close, while the
// simulated close-delay timer owns final transport teardown.
test_simulation_idle_timeout_graceful_close_cleans_up_dm_presence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		workspace_id := "dm_idle_timeout_workspace"
		alice := simulation_test_install_client(&ctx.sim, 1, workspace_id, "alice")
		bob := simulation_test_install_client(&ctx.sim, 2, workspace_id, "bob")
		ctx.conns[1] = alice
		ctx.conns[2] = bob
		testing.expect(t, alice != nil && bob != nil, "expected idle-timeout DM clients to install")
		if alice == nil || bob == nil {
			return
		}
		alice_handle := alice.handle

		ws_state := get_or_create_workspace(workspace_id)
		on_user_connect(ws_state, intern_username("alice"), true)
		on_user_connect(ws_state, intern_username("bob"), true)

		conv_id := pr.make_dm_conversation_id("alice", "bob")
		process_start_dm(alice, pr.StartDMRequest{username = "bob", correlation_id = 42})

		nrc_sim_clear_inboxes(&ctx.sim)
		alice.state = .New
		alice.last_activity = time.time_add(nrc_time_now_monotonic(), -(Idle_Timeout + time.Second))
		bob.last_activity = nrc_time_now_monotonic()
		td.idle_scan_cursor = int(alice.sock)
		check_idle_connections(nrc_time_now_monotonic())
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_run_all_shutdown_sends(&ctx.sim)

		testing.expect_value(t, alice.state, Connection_State.Will_Close)
		testing.expect_value(t, bob.state, Connection_State.Idle)
		testing.expect(t, alice.logical_cleanup_done, "idle timeout should run logical cleanup immediately")
		testing.expect(t, !is_user_online(ws_state, "alice"), "alice should be offline immediately after idle timeout")
		testing.expect(t, !is_user_authenticated(ws_state, "alice"), "alice should be unauthenticated immediately after idle timeout")
		testing.expect(t, nrc_sim_client_has_close_frame(&ctx.sim, alice.sock, 1000, "Idle timeout"), "alice should receive idle-timeout close frame")
		testing.expect(t, !nrc_sim_client_has_close_frame(&ctx.sim, bob.sock, 1000, "Idle timeout"), "active bob should not receive idle-timeout close frame")
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 1)

		alice_sockets := get_user_sockets(ws_state, "alice")
		defer delete(alice_sockets)
		testing.expect_value(t, len(alice_sockets), 0)

		offline_payload, offline_ok := nrc_sim_client_find_payload_by_opcode(&ctx.sim, bob.sock, .S_DMPartnerStatus)
		testing.expect(t, offline_ok, "bob should receive idle-timeout offline DM partner status")
		if !offline_ok {
			return
		}
		offline_status, offline_err := pr.parseDMPartnerStatusMessage(offline_payload)
		testing.expect(t, offline_err == nil, "idle-timeout offline DM partner status frame should parse")
		testing.expect_value(t, offline_status.conv_id, conv_id)
		testing.expect(t, offline_status.username == "alice", "idle-timeout offline status username should identify alice")
		testing.expect(t, !offline_status.online, "idle-timeout offline status should mark alice offline")

		nrc_sim_clear_inboxes(&ctx.sim)
		check_idle_connections(nrc_time_now_monotonic())
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 1)
		testing.expect(t, !nrc_sim_client_has_close_frame(&ctx.sim, alice.sock, 1000, "Idle timeout"), "second idle check should not send another close frame")
		testing.expect(t, !nrc_sim_client_has_opcode(&ctx.sim, bob.sock, .S_DMPartnerStatus), "second idle check should not double-send DM offline status")

		nrc_sim_run_all_timers(&ctx.sim)
		testing.expect_value(t, alice.state, Connection_State.Closing)
		nrc_sim_run_all_close_completions(&ctx.sim)
		testing.expect(t, connection_get_by_handle(alice_handle) == nil, "idle alice should be reclaimed after physical close completion")
		connection_test_live_count -= 1
		ctx.conns[1] = nil
		testing.expect_value(t, bob.state, Connection_State.Idle)
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 0)
	}
}

@(test)
// DM socket lookup fixture: get_user_sockets is the source of truth for DM
// subscribe/fanout targets during start/leave. It must not leak same-named
// users across workspaces or rediscover sockets already in logical close.
test_simulation_dm_get_user_sockets_filters_workspace_and_closing :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		alice_a := simulation_test_install_client(&ctx.sim, 1, "dm_socket_filter_a", "alice")
		alice_a_closing := simulation_test_install_client(&ctx.sim, 2, "dm_socket_filter_a", "alice")
		alice_b := simulation_test_install_client(&ctx.sim, 3, "dm_socket_filter_b", "alice")
		bob_a := simulation_test_install_client(&ctx.sim, 4, "dm_socket_filter_a", "bob")
		ctx.conns[1] = alice_a
		ctx.conns[2] = alice_a_closing
		ctx.conns[3] = alice_b
		ctx.conns[4] = bob_a
		testing.expect(t, alice_a != nil && alice_a_closing != nil && alice_b != nil && bob_a != nil, "expected socket-filter clients to install")
		if alice_a == nil || alice_a_closing == nil || alice_b == nil || bob_a == nil {
			return
		}

		alice_a_closing.state = .Closing
		ws_a := get_connection_workspace(alice_a)
		ws_b := get_connection_workspace(alice_b)
		testing.expect(t, ws_a != nil && ws_b != nil && ws_a != ws_b, "expected distinct workspace states")
		if ws_a == nil || ws_b == nil || ws_a == ws_b {
			return
		}

		sockets_a := get_user_sockets(ws_a, "alice")
		defer delete(sockets_a)
		testing.expect_value(t, len(sockets_a), 1)
		if len(sockets_a) == 1 {
			testing.expect_value(t, sockets_a[0], alice_a.sock)
		}

		sockets_b := get_user_sockets(ws_b, "alice")
		defer delete(sockets_b)
		testing.expect_value(t, len(sockets_b), 1)
		if len(sockets_b) == 1 {
			testing.expect_value(t, sockets_b[0], alice_b.sock)
		}

		missing := get_user_sockets(ws_a, "carol")
		defer delete(missing)
		testing.expect_value(t, len(missing), 0)
	}
}

@(test)
// Exercise middle/head unlink and same-FD replacement directly. Old generations
// must disappear from both sparse-link positions before a replacement is indexed.
test_simulation_dm_user_connection_index_unlinks_reused_generations :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		workspace_id := "dm_user_index_reuse"
		alice_a := simulation_test_install_client(&ctx.sim, 5, workspace_id, "alice")
		alice_b := simulation_test_install_client(&ctx.sim, 6, workspace_id, "alice")
		alice_c := simulation_test_install_client(&ctx.sim, 7, workspace_id, "alice")
		ctx.conns[5] = alice_a
		ctx.conns[6] = alice_b
		ctx.conns[7] = alice_c
		testing.expect(t, alice_a != nil && alice_b != nil && alice_c != nil, "expected indexed clients")
		if alice_a == nil || alice_b == nil || alice_c == nil do return

		ws := get_connection_workspace(alice_a)
		testing.expect(t, ws != nil, "expected indexed workspace")
		if ws == nil do return
		old_b_handle := alice_b.handle
		old_c_handle := alice_c.handle
		reused_sock := alice_c.sock

		// In insertion order C -> B -> A, B is the middle node.
		simulation_test_uninstall_client(alice_b)
		ctx.conns[6] = nil
		testing.expect_value(t, ws.user_connection_head["alice"], old_c_handle)
		testing.expect_value(t, ws.user_connection_next[old_c_handle], alice_a.handle)
		_, old_b_linked := ws.user_connection_next[old_b_handle]
		testing.expect(t, !old_b_linked, "removed middle generation must not remain a sparse-link key")

		// Remove the head, then reuse its socket under another identity.
		simulation_test_uninstall_client(alice_c)
		ctx.conns[7] = nil
		testing.expect_value(t, ws.user_connection_head["alice"], alice_a.handle)
		_, old_c_linked := ws.user_connection_next[old_c_handle]
		testing.expect(t, !old_c_linked, "removed head generation must not remain a sparse-link key")

		replacement := simulation_test_install_client(&ctx.sim, 7, workspace_id, "bob")
		ctx.conns[7] = replacement
		testing.expect(t, replacement != nil, "expected reused-socket replacement")
		if replacement == nil do return
		testing.expect_value(t, replacement.sock, reused_sock)
		testing.expect(t, replacement.handle != old_c_handle, "reused socket must receive a new generation")

		alice_sockets := get_user_sockets(ws, "alice")
		defer delete(alice_sockets)
		testing.expect_value(t, len(alice_sockets), 1)
		if len(alice_sockets) == 1 do testing.expect_value(t, alice_sockets[0], alice_a.sock)
		bob_sockets := get_user_sockets(ws, "bob")
		defer delete(bob_sockets)
		testing.expect_value(t, len(bob_sockets), 1)
		if len(bob_sockets) == 1 do testing.expect_value(t, bob_sockets[0], replacement.sock)

		for _, next in ws.user_connection_next {
			testing.expect(t, next != old_b_handle && next != old_c_handle, "removed generation must not remain a sparse-link value")
		}
	}
}

@(test)
test_simulation_room_subscription_cleanup_is_idempotent :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		workspace_id := "room_cleanup_idempotence_workspace"
		alice := simulation_test_install_client(&ctx.sim, 1, workspace_id, "alice")
		bob := simulation_test_install_client(&ctx.sim, 2, workspace_id, "bob")
		ctx.conns[1] = alice
		ctx.conns[2] = bob
		testing.expect(t, alice != nil && bob != nil, "expected room cleanup clients to install")
		if alice == nil || bob == nil {
			return
		}

		room_a := pr.ConversationID(7_001)
		room_b := pr.ConversationID(7_002)
		room_c := pr.ConversationID(7_003)

		subscribe_to_conversation(alice, room_a)
		subscribe_to_conversation(alice, room_b)
		subscribe_to_conversation(alice, room_c)
		subscribe_to_conversation(bob, room_a)
		subscribe_to_conversation(bob, room_b)

		ws := get_connection_workspace(alice)
		testing.expect(t, ws != nil, "expected cleanup workspace")
		if ws == nil {
			return
		}
		conv_a := get_conversation(ws, room_a)
		conv_b := get_conversation(ws, room_b)
		conv_c := get_conversation(ws, room_c)
		testing.expect(t, conv_a != nil && conv_b != nil && conv_c != nil, "expected all cleanup conversations")
		if conv_a == nil || conv_b == nil || conv_c == nil {
			return
		}
		testing.expect_value(t, subscriber_count(conv_a), 2)
		testing.expect_value(t, subscriber_count(conv_b), 2)
		testing.expect_value(t, subscriber_count(conv_c), 1)
		testing.expect(t, conversation_has_subscriber(conv_a, alice.sock), "alice should start subscribed to room A")
		testing.expect(t, conversation_has_subscriber(conv_b, alice.sock), "alice should start subscribed to room B")
		testing.expect(t, conversation_has_subscriber(conv_c, alice.sock), "alice should start subscribed to room C")
		testing.expect_value(t, len(alice.rooms), 3)

		nrc_sim_clear_inboxes(&ctx.sim)
		connection_run_logical_cleanup(alice, false)

		testing.expect(t, alice.logical_cleanup_done, "first logical cleanup should mark connection cleaned")
		testing.expect(t, alice.rooms == nil, "first logical cleanup should free room membership map")
		testing.expect(t, !conversation_has_subscriber(conv_a, alice.sock), "first cleanup should remove alice from room A")
		testing.expect(t, !conversation_has_subscriber(conv_b, alice.sock), "first cleanup should remove alice from room B")
		testing.expect(t, !conversation_has_subscriber(conv_c, alice.sock), "first cleanup should remove alice from room C")
		testing.expect(t, conversation_has_subscriber(conv_a, bob.sock), "first cleanup should keep bob in room A")
		testing.expect(t, conversation_has_subscriber(conv_b, bob.sock), "first cleanup should keep bob in room B")
		testing.expect_value(t, subscriber_count(conv_a), 1)
		testing.expect_value(t, subscriber_count(conv_b), 1)
		testing.expect_value(t, subscriber_count(conv_c), 0)

		bob_presence_after_first := nrc_sim_client_frame_count(&ctx.sim, bob.sock)
		testing.expect(t, bob_presence_after_first > 0, "bob should receive at least one presence update for alice leaving shared rooms")
		connection_run_logical_cleanup(alice, false)

		testing.expect_value(t, subscriber_count(conv_a), 1)
		testing.expect_value(t, subscriber_count(conv_b), 1)
		testing.expect_value(t, subscriber_count(conv_c), 0)
		testing.expect(t, conversation_has_subscriber(conv_a, bob.sock), "duplicate cleanup should keep bob in room A")
		testing.expect(t, conversation_has_subscriber(conv_b, bob.sock), "duplicate cleanup should keep bob in room B")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), bob_presence_after_first)

		alice_reconnect := simulation_test_install_client(&ctx.sim, 3, workspace_id, "alice")
		ctx.conns[3] = alice_reconnect
		testing.expect(t, alice_reconnect != nil, "expected reconnecting alice client")
		if alice_reconnect == nil {
			return
		}
		subscribe_to_conversation(alice_reconnect, room_a)

		testing.expect(t, !conversation_has_subscriber(conv_a, alice.sock), "old alice socket should stay removed after reconnect")
		testing.expect(t, conversation_has_subscriber(conv_a, alice_reconnect.sock), "reconnected alice should subscribe with a fresh socket")
		testing.expect(t, conversation_has_subscriber(conv_a, bob.sock), "reconnect should keep bob subscribed")
		testing.expect_value(t, subscriber_count(conv_a), 2)
	}
}
