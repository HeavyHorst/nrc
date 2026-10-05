package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:testing"
import "core:time"

import "byte_pool"
import hgl "hegel"
import nbio "nbio/poly"
import "ulid"

@(thread_local)
connection_completion_callback_count: int
@(thread_local)
connection_completion_nil_count: int
@(thread_local)
connection_completion_new_conn_count: int
@(thread_local)
connection_completion_unexpected_target_count: int
@(thread_local)
connection_completion_expected_handle: Connection_Handle

connection_completion_test_callback :: proc(c: ^NRC_Connection, ctx: rawptr, sent: int, err: net.Network_Error) {
	connection_completion_callback_count += 1
	if c == nil {
		connection_completion_nil_count += 1
		return
	}
	if c.verified_username == "new" {
		connection_completion_new_conn_count += 1
	}
}

connection_lifetime_track_callback_target :: proc(c: ^NRC_Connection) {
	connection_completion_callback_count += 1
	if c == nil {
		connection_completion_nil_count += 1
		return
	}
	if connection_completion_expected_handle != {} && c.handle != connection_completion_expected_handle {
		connection_completion_unexpected_target_count += 1
	}
	if c.verified_username == "new" {
		connection_completion_new_conn_count += 1
	}
}

connection_lifetime_tracking_ack_sent :: proc(c: ^NRC_Connection, ctx: rawptr, sent: int, err: net.Network_Error) {
	connection_lifetime_track_callback_target(c)
}

connection_completion_test_reset :: proc() {
	connection_completion_callback_count = 0
	connection_completion_nil_count = 0
	connection_completion_new_conn_count = 0
	connection_completion_unexpected_target_count = 0
	connection_completion_expected_handle = {}
}

@(test)
test_connection_fixture_releases_queues_at_final_reclamation :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 123)
	defer worker_state_destroy_core_for_test()
	cases := [?]bool{false, true}
	for pending in cases {
		sock := connection_lifetime_test_sock(123)
		conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, init_send_queue = true})
		if !testing.expect(t, conn != nil) do return
		handle := conn.handle
		baseline := td.spool.release_count
		normal, normal_err := byte_pool.alloc(td.spool, 31)
		priority, priority_err := byte_pool.alloc(td.spool, 64)
		testing.expect(t, normal_err == nil && priority_err == nil)
		send_queue_push(conn, Send_Item{lease = Frame_Lease(Pooled_Frame_Lease{data = normal, pool = td.spool}), handle = handle})
		send_queue_push_priority(conn, Send_Item{lease = Frame_Lease(Pooled_Frame_Lease{data = priority, pool = td.spool}), handle = handle})
		io := connection_io_context_make(conn)
		if pending {
			testing.expect(t, connection_io_pin(conn))
			io.pinned = true
		}
		connection_test_uninstall(conn)
		testing.expect(t, connection_get(sock) == nil)
		if pending {
			testing.expect(t, connection_get_by_handle(handle) == conn)
			testing.expect_value(t, send_queue_len(conn), 2)
			testing.expect_value(t, td.spool.release_count, baseline)
			connection_io_unpin(io)
		}
		testing.expect(t, connection_get_by_handle(handle) == nil)
		testing.expect_value(t, td.spool.release_count, baseline + 2)
	}
}

@(test)
test_unpinned_send_completion_cannot_consume_close_pin :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 119)
	defer worker_state_destroy_core_for_test()

	conn := connection_test_install_fake(Fake_Connection_Options{sock = connection_lifetime_test_sock(119), state = .Closing, init_send_queue = true})
	testing.expect(t, conn != nil, "expected retained closing connection")
	if conn == nil do return
	conn.pending_io = 1 // Physical-close submission owns this pin.
	item := Send_Item {
		observer = Send_Completion_Observer{callback = connection_completion_test_callback},
	}
	nrc_io_send_all(conn, nil, item)
	testing.expect_value(t, conn.pending_io, u32(1))
	conn.pending_io = 0
	connection_test_uninstall(conn)
}

@(test)
test_reused_batch_state_failed_submission_cannot_consume_close_pin :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 122)
	defer worker_state_destroy_core_for_test()

	stale_state := alloc_batch_state(Batch_Queue_Threshold)
	testing.expect(t, stale_state != nil, "expected initial pooled batch state")
	if stale_state == nil do return
	stale_state.io_pinned = true
	free_batch_state(stale_state)

	state := alloc_batch_state(Batch_Queue_Threshold)
	testing.expect(t, state == stale_state, "expected batch state reuse")
	if state == nil do return
	testing.expect(t, !state.io_pinned, "reused batch state must not retain prior pin ownership")

	conn := connection_test_install_fake(Fake_Connection_Options{sock = connection_lifetime_test_sock(122), state = .Closing, init_send_queue = true})
	testing.expect(t, conn != nil, "expected retained closing connection")
	if conn == nil {
		free_batch_state(state)
		return
	}
	conn.pending_io = 1 // Physical-close submission owns this pin.
	state.count = 1
	state.items = state.items[:1]
	state.iovec = state.iovec[:1]
	state.items[0] = Batch_Item {
		observer = Send_Completion_Observer{callback = connection_completion_test_callback},
	}

	nrc_io_writev_all(conn, state)
	testing.expect_value(t, conn.pending_io, u32(1))
	conn.pending_io = 0
	connection_test_uninstall(conn)
}

Connection_Lifetime_Pending_Kind :: enum {
	Send,
	Batch,
	Close_Frame,
	Graceful_Delay,
	Graceful_Shutdown,
	Recv,
	Recv_Error,
	Physical_Close,
}

connection_lifetime_test_sock :: proc(slot: int) -> net.TCP_Socket {
	return net.TCP_Socket(491_000 + slot * 16 + 1)
}

connection_lifetime_assert_reused_socket_intact :: proc(sock: net.TCP_Socket, new_conn: ^NRC_Connection) -> bool {
	return new_conn != nil && connection_get(sock) == new_conn && new_conn.state == .Idle && new_conn.verified_username == "new"
}

connection_lifetime_make_stale_pair :: proc(
	sock: net.TCP_Socket,
	old_state: Connection_State = .Idle,
	track_active_socket: bool = false,
) -> (
	old_handle: Connection_Handle,
	old_ctx: Connection_IO_Context,
	new_conn: ^NRC_Connection,
	ok: bool,
) {
	old_conn := connection_test_install_fake(
		Fake_Connection_Options{sock = sock, state = old_state, verified_username = "old", init_send_queue = true, track_active_socket = track_active_socket},
	)
	if old_conn == nil {
		return
	}

	old_handle = old_conn.handle
	old_ctx = connection_io_context_make(old_conn)
	connection_test_uninstall(old_conn)

	new_conn = connection_test_install_fake(
		Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true, track_active_socket = track_active_socket},
	)
	if new_conn == nil {
		return
	}

	ok = true
	return
}

@(test)
test_io_context_rejects_stale_handle_after_socket_reuse :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 103)
	defer worker_state_destroy_core_for_test()

	sock := connection_lifetime_test_sock(0)
	_, old_ctx, new_conn, ok := connection_lifetime_make_stale_pair(sock)
	if !testing.expect(t, ok, "expected stale/reused connection pair") do return
	defer connection_test_uninstall(new_conn)

	testing.expect(t, old_ctx.handle != new_conn.handle)
	testing.expect(t, connection_get(sock) == new_conn, "socket lookup must see the replacement")
	testing.expect(t, connection_from_io_context(old_ctx) == nil, "stale context must not resolve to the replacement")
	testing.expect(t, connection_from_io_context(connection_io_context_make(new_conn)) == new_conn, "current context must resolve")
}

connection_lifetime_run_stale_completion_case :: proc(kind: Connection_Lifetime_Pending_Kind, slot: int) -> bool {
	sock := connection_lifetime_test_sock(slot)
	connection_completion_test_reset()

	switch kind {
	case .Send:
		old_handle, _, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		item := Send_Item {
			lease = Frame_Lease(Pooled_Frame_Lease{}),
			handle = old_handle,
			observer = Send_Completion_Observer{callback = connection_completion_test_callback},
		}
		on_queued_send_complete(sock, item, len(frame_lease_data(item.lease)), nil)
		return(
			connection_completion_callback_count == 1 &&
			connection_completion_nil_count == 1 &&
			connection_completion_new_conn_count == 0 &&
			connection_lifetime_assert_reused_socket_intact(sock, new_conn) \
		)

	case .Batch:
		old_handle, _, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		state := alloc_batch_state(3)
		if state == nil do return false
		state.count = 3
		state.items = state.items[:3]
		state.iovec = state.iovec[:3]
		for i in 0 ..< state.count {
			buf := []u8{byte(10 + i), byte(20 + i)}
			state.items[i] = Batch_Item {
				observer = Send_Completion_Observer{callback = connection_completion_test_callback},
				handle = old_handle,
				lease = Frame_Lease(Connection_Stable_Frame_Lease{data = buf, owner = old_handle}),
			}
			state.iovec[i] = nbio.iovec {
				iov_base = raw_data(buf),
				iov_len  = uint(len(buf)),
			}
		}

		on_batch_send_complete(sock, state, 6, nil)
		return(
			connection_completion_callback_count == 3 &&
			connection_completion_nil_count == 3 &&
			connection_completion_new_conn_count == 0 &&
			connection_lifetime_assert_reused_socket_intact(sock, new_conn) \
		)

	case .Close_Frame:
		old_handle, _, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		item := Send_Item {
			lease  = Frame_Lease(Pooled_Frame_Lease{}),
			handle = old_handle,
			action = .Close_After_Send,
		}
		on_queued_send_complete(sock, item, len(frame_lease_data(item.lease)), nil)
		return connection_lifetime_assert_reused_socket_intact(sock, new_conn)

	case .Graceful_Delay:
		_, old_ctx, new_conn, ok := connection_lifetime_make_stale_pair(sock, .Will_Close)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		ctx := new(Graceful_Close_Context)
		ctx.sock = old_ctx.sock
		ctx.handle = old_ctx.handle
		on_graceful_close_delay_elapsed(ctx)
		return connection_lifetime_assert_reused_socket_intact(sock, new_conn)

	case .Graceful_Shutdown:
		_, old_ctx, new_conn, ok := connection_lifetime_make_stale_pair(sock, .Will_Close)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		ctx := new(Graceful_Close_Context)
		ctx.sock = old_ctx.sock
		ctx.handle = old_ctx.handle
		on_graceful_close_shutdown_complete(ctx, .Connection_Closed)
		return connection_lifetime_assert_reused_socket_intact(sock, new_conn)

	case .Recv:
		_, old_ctx, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		old_last_activity := new_conn.last_activity
		on_recv_websocket_fixed(old_ctx, 1, []u8{0}, {}, nil)
		return connection_lifetime_assert_reused_socket_intact(sock, new_conn) && new_conn.last_activity == old_last_activity

	case .Recv_Error:
		_, old_ctx, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		on_recv_websocket_fixed(old_ctx, 0, {}, {}, net.TCP_Recv_Error(.Connection_Closed))
		return connection_lifetime_assert_reused_socket_intact(sock, new_conn)

	case .Physical_Close:
		_, old_ctx, new_conn, ok := connection_lifetime_make_stale_pair(sock, .Closing, true)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		connection_count_before := td.connection_count
		on_connection_close_complete(old_ctx, false, true)
		return connection_lifetime_assert_reused_socket_intact(sock, new_conn) && td.connection_count == connection_count_before
	}

	return false
}

Connection_Lifetime_Buffer_Kind :: enum {
	Pooled_Send,
	Pooled_Batch,
	Shared_Broadcast,
}

Connection_Lifetime_Stateful_Pending :: struct {
	active: bool,
	kind:   Connection_Lifetime_Buffer_Kind,
	sock:   net.TCP_Socket,
	handle: Connection_Handle,
	buf:    []byte,
	state:  ^Batch_Send_State,
	shared: ^Broadcast_Buffer,
}

CONNECTION_LIFETIME_STATEFUL_MAX_PENDING :: 64

connection_lifetime_pool_drained :: proc(pool: ^byte_pool.BufferPool) -> bool {
	if pool == nil || pool.used != 0 {
		return false
	}
	return pool.live_allocs == 0
}

connection_lifetime_pool_live_alloc_count :: proc(pool: ^byte_pool.BufferPool) -> uint {
	if pool == nil {
		return 0
	}
	return pool.live_allocs
}

connection_lifetime_pending_count :: proc(pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending) -> int {
	count := 0
	for item in pending {
		if item.active do count += 1
	}
	return count
}

connection_lifetime_first_free_pending_slot :: proc(pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending) -> int {
	for item, i in pending {
		if !item.active do return i
	}
	return -1
}

connection_lifetime_nth_active_pending_slot :: proc(
	pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
	active_index: int,
) -> int {
	seen := 0
	for item, i in pending {
		if !item.active do continue
		if seen == active_index do return i
		seen += 1
	}
	return -1
}

connection_lifetime_shared_has_active_refs :: proc(
	pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
	shared: ^Broadcast_Buffer,
) -> bool {
	if shared == nil {
		return false
	}
	for item in pending {
		if item.active && item.shared == shared {
			return true
		}
	}
	return false
}

connection_lifetime_stateful_invariants_hold :: proc(current_conn: ^NRC_Connection, model_live_allocs: int) -> bool {
	if model_live_allocs < 0 {
		return false
	}
	if int(connection_lifetime_pool_live_alloc_count(td.spool)) != model_live_allocs {
		return false
	}
	if int(td.spool.allocation_count - td.spool.release_count) != model_live_allocs {
		return false
	}
	if model_live_allocs == 0 && !connection_lifetime_pool_drained(td.spool) {
		return false
	}
	if current_conn != nil && connection_get(current_conn.sock) != current_conn {
		return false
	}
	if connection_completion_new_conn_count != 0 || connection_completion_unexpected_target_count != 0 {
		return false
	}
	return true
}

connection_lifetime_shared_completion_callback :: proc(c: ^NRC_Connection, ctx: rawptr, sent: int, err: net.Network_Error) {
	connection_lifetime_track_callback_target(c)
}

connection_lifetime_make_shared_buffer :: proc(ref_count: int) -> ^Broadcast_Buffer {
	data, data_err := byte_pool.alloc(td.spool, 64)
	if data_err != .None {
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = data
	shared.pool = td.spool
	shared.ref_count = ref_count
	return shared
}

connection_lifetime_add_stateful_pooled_send :: proc(
	pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
	conn: ^NRC_Connection,
	model_live_allocs: ^int,
) -> bool {
	if conn == nil {
		return false
	}
	slot := connection_lifetime_first_free_pending_slot(pending)
	if slot < 0 {
		return false
	}

	buf, buf_err := byte_pool.alloc(td.spool, 32)
	if buf_err != .None {
		return false
	}
	pending[slot] = Connection_Lifetime_Stateful_Pending {
		active = true,
		kind   = .Pooled_Send,
		sock   = conn.sock,
		handle = conn.handle,
		buf    = buf,
	}
	model_live_allocs^ += 1
	return true
}

connection_lifetime_add_stateful_pooled_batch :: proc(
	pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
	conn: ^NRC_Connection,
	item_count: int,
	model_live_allocs: ^int,
) -> bool {
	if conn == nil || item_count <= 0 {
		return false
	}
	slot := connection_lifetime_first_free_pending_slot(pending)
	if slot < 0 {
		return false
	}

	state := alloc_batch_state(item_count)
	if state == nil {
		return false
	}
	state.count = item_count
	state.items = state.items[:item_count]
	state.iovec = state.iovec[:item_count]

	for i in 0 ..< item_count {
		buf, buf_err := byte_pool.alloc(td.spool, uint(16 + i))
		if buf_err != .None {
			for j in 0 ..< i {
				frame_lease_dispose(&state.items[j].lease)
			}
			free_batch_state(state)
			return false
		}
		state.items[i] = Batch_Item {
			observer = Send_Completion_Observer{callback = connection_lifetime_tracking_ack_sent},
			handle = conn.handle,
			lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
		}
		state.iovec[i] = nbio.iovec {
			iov_base = raw_data(buf),
			iov_len  = uint(len(buf)),
		}
	}

	pending[slot] = Connection_Lifetime_Stateful_Pending {
		active = true,
		kind   = .Pooled_Batch,
		sock   = conn.sock,
		handle = conn.handle,
		state  = state,
	}
	model_live_allocs^ += item_count
	return true
}

connection_lifetime_add_stateful_shared_broadcast :: proc(
	pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
	conn: ^NRC_Connection,
	ref_count: int,
	model_live_allocs: ^int,
) -> bool {
	if conn == nil || ref_count <= 0 {
		return false
	}
	if connection_lifetime_pending_count(pending) + ref_count > CONNECTION_LIFETIME_STATEFUL_MAX_PENDING {
		return false
	}

	shared := connection_lifetime_make_shared_buffer(ref_count)
	if shared == nil {
		return false
	}

	for _ in 0 ..< ref_count {
		slot := connection_lifetime_first_free_pending_slot(pending)
		if slot < 0 {
			for shared.ref_count > 0 do shared_frame_release(shared)
			return false
		}
		pending[slot] = Connection_Lifetime_Stateful_Pending {
			active = true,
			kind   = .Shared_Broadcast,
			sock   = conn.sock,
			handle = conn.handle,
			shared = shared,
		}
	}
	model_live_allocs^ += 2
	return true
}

connection_lifetime_complete_stateful_pending :: proc(
	pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
	slot: int,
	model_live_allocs: ^int,
	err: net.Network_Error = nil,
) -> bool {
	if slot < 0 || slot >= len(pending) || !pending[slot].active {
		return false
	}

	item := pending[slot]
	pending[slot] = {}
	previous_expected_handle := connection_completion_expected_handle
	connection_completion_expected_handle = item.handle
	defer {
		connection_completion_expected_handle = previous_expected_handle
	}

	switch item.kind {
	case .Pooled_Send:
		sent := len(item.buf)
		if err != nil do sent = 0
		send_item := Send_Item {
			lease = Frame_Lease(Pooled_Frame_Lease{data = item.buf, pool = td.spool}),
			handle = item.handle,
			observer = Send_Completion_Observer{callback = connection_lifetime_tracking_ack_sent},
		}
		on_queued_send_complete(item.sock, send_item, sent, err)
		model_live_allocs^ -= 1

	case .Pooled_Batch:
		if item.state == nil {
			return false
		}
		batch_count := item.state.count
		on_batch_send_complete(item.sock, item.state, 0, err)
		model_live_allocs^ -= batch_count

	case .Shared_Broadcast:
		if item.shared == nil {
			return false
		}
		shared := item.shared
		sent := len(shared.data)
		if err != nil do sent = 0
		send_item := Send_Item {
			lease = Frame_Lease(Shared_Frame_Lease{buffer = shared}),
			handle = item.handle,
			observer = Send_Completion_Observer{callback = connection_lifetime_shared_completion_callback, ctx = shared},
		}
		on_queued_send_complete(item.sock, send_item, sent, err)
		if !connection_lifetime_shared_has_active_refs(pending, shared) {
			model_live_allocs^ -= 2
		}
	}

	return true
}

connection_lifetime_cleanup_stateful_pending :: proc(
	pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
	current_conn: ^^NRC_Connection,
	model_live_allocs: ^int,
) {
	for connection_lifetime_pending_count(pending) > 0 {
		slot := connection_lifetime_nth_active_pending_slot(pending, 0)
		if slot < 0 {
			break
		}
		if !connection_lifetime_complete_stateful_pending(pending, slot, model_live_allocs) {
			break
		}
	}
	if current_conn^ != nil {
		connection_test_uninstall(current_conn^)
		current_conn^ = nil
	}
}

when NRC_SIMULATION {
	connection_lifetime_cleanup_sim_stateful_pending :: proc(
		sim: ^Sim_Runtime,
		pending: ^[CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending,
		current_conn: ^^NRC_Connection,
		model_live_allocs: ^int,
	) {
		for connection_lifetime_pending_count(pending) > 0 {
			slot := connection_lifetime_nth_active_pending_slot(pending, 0)
			if slot < 0 {
				break
			}
			if !connection_lifetime_complete_stateful_pending(pending, slot, model_live_allocs, net.TCP_Send_Error(.Connection_Closed)) {
				break
			}
			nrc_sim_run_all_timers(sim)
			connection_lifetime_cleanup_closed_sim_connection(current_conn)
		}
		if current_conn^ != nil {
			connection_test_uninstall(current_conn^)
			current_conn^ = nil
		}
	}
}

connection_lifetime_run_buffer_ownership_case :: proc(kind: Connection_Lifetime_Buffer_Kind, slot: int, count: int) -> bool {
	if count <= 0 {
		return false
	}
	sock := connection_lifetime_test_sock(slot)
	connection_completion_test_reset()
	allocs_before := td.spool.allocation_count
	releases_before := td.spool.release_count

	switch kind {
	case .Pooled_Send:
		old_handle, _, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		buf, buf_err := byte_pool.alloc(td.spool, 32)
		if buf_err != .None do return false
		item := Send_Item {
			lease  = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			handle = old_handle,
		}
		on_queued_send_complete(sock, item, len(frame_lease_data(item.lease)), nil)

		return(
			connection_lifetime_assert_reused_socket_intact(sock, new_conn) &&
			td.spool.allocation_count == allocs_before + 1 &&
			td.spool.release_count == releases_before + 1 &&
			connection_lifetime_pool_drained(td.spool) \
		)

	case .Pooled_Batch:
		old_handle, _, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		state := alloc_batch_state(count)
		if state == nil do return false
		state.count = count
		state.items = state.items[:count]
		state.iovec = state.iovec[:count]

		for i in 0 ..< count {
			buf, buf_err := byte_pool.alloc(td.spool, uint(16 + i))
			if buf_err != .None {
				for j in 0 ..< i {
					frame_lease_dispose(&state.items[j].lease)
				}
				free_batch_state(state)
				return false
			}
			state.items[i] = Batch_Item {
				handle = old_handle,
				lease  = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			}
			state.iovec[i] = nbio.iovec {
				iov_base = raw_data(buf),
				iov_len  = uint(len(buf)),
			}
		}

		on_batch_send_complete(sock, state, 0, nil)
		return(
			connection_lifetime_assert_reused_socket_intact(sock, new_conn) &&
			td.spool.allocation_count == allocs_before + u64(count) &&
			td.spool.release_count == releases_before + u64(count) &&
			connection_lifetime_pool_drained(td.spool) \
		)

	case .Shared_Broadcast:
		old_handle, _, new_conn, ok := connection_lifetime_make_stale_pair(sock)
		if !ok do return false
		defer connection_test_uninstall(new_conn)

		shared := connection_lifetime_make_shared_buffer(count)
		if shared == nil do return false

		for _ in 0 ..< count {
			item := Send_Item {
				lease = Frame_Lease(Shared_Frame_Lease{buffer = shared}),
				handle = old_handle,
				observer = Send_Completion_Observer{callback = connection_lifetime_shared_completion_callback, ctx = shared},
			}
			on_queued_send_complete(sock, item, len(frame_lease_data(item.lease)), nil)
		}

		return(
			connection_completion_callback_count == count &&
			connection_completion_nil_count == count &&
			connection_completion_new_conn_count == 0 &&
			connection_lifetime_assert_reused_socket_intact(sock, new_conn) &&
			td.spool.allocation_count == allocs_before + 2 &&
			td.spool.release_count == releases_before + 2 &&
			connection_lifetime_pool_drained(td.spool) \
		)
	}

	return false
}

@(test)
test_direct_batch_completion_releases_pooled_buffers_and_ignores_reused_socket :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 107)
	defer worker_state_destroy_core_for_test()

	sock := connection_lifetime_test_sock(14)
	old_handle, _, new_conn, ok := connection_lifetime_make_stale_pair(sock)
	testing.expect(t, ok, "expected stale/reused connection pair")
	defer connection_test_uninstall(new_conn)

	connection_completion_test_reset()
	connection_completion_expected_handle = old_handle
	allocs_before := td.spool.allocation_count
	releases_before := td.spool.release_count
	batch_releases_before := td.batch_state_pool.pooled_releases

	count := 3
	state := alloc_batch_state(count)
	testing.expect(t, state != nil, "expected batch state allocation")
	state.count = count
	state.items = state.items[:count]
	state.iovec = state.iovec[:count]
	for i in 0 ..< count {
		buf, buf_err := byte_pool.alloc(td.spool, uint(24 + i))
		testing.expect(t, buf_err == .None, "expected pooled buffer allocation")
		state.items[i] = Batch_Item {
			observer = Send_Completion_Observer{callback = connection_lifetime_tracking_ack_sent},
			handle = old_handle,
			lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
		}
		state.iovec[i] = nbio.iovec {
			iov_base = raw_data(buf),
			iov_len  = uint(len(buf)),
		}
	}

	on_batch_send_complete(sock, state, 0, nil)
	testing.expect_value(t, connection_completion_callback_count, count)
	testing.expect_value(t, connection_completion_nil_count, count)
	testing.expect_value(t, connection_completion_new_conn_count, 0)
	testing.expect_value(t, connection_completion_unexpected_target_count, 0)
	testing.expect(t, connection_lifetime_assert_reused_socket_intact(sock, new_conn), "stale direct batch completion must not target reused socket")
	testing.expect_value(t, td.spool.allocation_count, allocs_before + u64(count))
	testing.expect_value(t, td.spool.release_count, releases_before + u64(count))
	testing.expect_value(t, td.batch_state_pool.pooled_releases, batch_releases_before + 1)
	testing.expect(t, connection_lifetime_pool_drained(td.spool), "expected pooled buffers to drain after direct batch completion")
}

@(test)
test_hegel_generated_stale_callback_completions_do_not_target_reused_sockets :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_generated_stale_callback_completions_do_not_target_reused_sockets, nil, {test_cases = 500})
	testing.expectf(t, err == nil, "hegel generated stale callback lifetime property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_generated_stale_callback_completions_do_not_target_reused_sockets :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	worker_state_init_core(nil, 103)
	defer worker_state_destroy_core_for_test()

	op_count_raw, op_count_err := hgl.draw_i64(tc, 1, 128)
	if op_count_err == .Stop_Test do return hgl.abort()
	if op_count_err != nil do return hgl.interesting("draw stale callback op count")

	for op_index in 0 ..< int(op_count_raw) {
		kind_raw, kind_err := hgl.draw_i64(tc, 0, i64(len(Connection_Lifetime_Pending_Kind) - 1))
		if kind_err == .Stop_Test do return hgl.abort()
		if kind_err != nil do return hgl.interesting("draw stale callback kind")

		slot_raw, slot_err := hgl.draw_i64(tc, 0, 7)
		if slot_err == .Stop_Test do return hgl.abort()
		if slot_err != nil do return hgl.interesting("draw stale callback socket slot")

		kind := Connection_Lifetime_Pending_Kind(kind_raw)
		if !connection_lifetime_run_stale_completion_case(kind, int(slot_raw)) {
			hgl.note(tc, fmt.tprintf("stale callback op_index=%d kind=%v slot=%d", op_index, kind, slot_raw))
			return hgl.interesting("stale callback completion targeted reused socket or skipped cleanup")
		}
	}

	return {}
}

@(test)
test_hegel_generated_stale_callback_buffer_ownership_is_released_once :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_generated_stale_callback_buffer_ownership_is_released_once, nil, {test_cases = 500})
	testing.expectf(
		t,
		err == nil,
		"hegel generated stale callback buffer ownership property failed: err=%v interesting=%v",
		err,
		result.interesting_test_cases,
	)
}

prop_generated_stale_callback_buffer_ownership_is_released_once :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	worker_state_init_core(nil, 104)
	defer worker_state_destroy_core_for_test()

	op_count_raw, op_count_err := hgl.draw_i64(tc, 1, 128)
	if op_count_err == .Stop_Test do return hgl.abort()
	if op_count_err != nil do return hgl.interesting("draw stale callback buffer op count")

	for op_index in 0 ..< int(op_count_raw) {
		kind_raw, kind_err := hgl.draw_i64(tc, 0, i64(len(Connection_Lifetime_Buffer_Kind) - 1))
		if kind_err == .Stop_Test do return hgl.abort()
		if kind_err != nil do return hgl.interesting("draw stale callback buffer kind")

		slot_raw, slot_err := hgl.draw_i64(tc, 0, 7)
		if slot_err == .Stop_Test do return hgl.abort()
		if slot_err != nil do return hgl.interesting("draw stale callback buffer socket slot")

		count_raw, count_err := hgl.draw_i64(tc, 1, 8)
		if count_err == .Stop_Test do return hgl.abort()
		if count_err != nil do return hgl.interesting("draw stale callback buffer count")

		kind := Connection_Lifetime_Buffer_Kind(kind_raw)
		if !connection_lifetime_run_buffer_ownership_case(kind, int(slot_raw), int(count_raw)) {
			hgl.note(
				tc,
				fmt.tprintf(
					"stale buffer op_index=%d kind=%v slot=%d count=%d used=%d allocs=%d releases=%d",
					op_index,
					kind,
					slot_raw,
					count_raw,
					td.spool.used,
					td.spool.allocation_count,
					td.spool.release_count,
				),
			)
			return hgl.interesting("stale callback buffer ownership leaked, double-freed, or targeted reused socket")
		}
	}

	return {}
}

@(test)
test_hegel_generated_pending_callback_interleavings_match_pool_model :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_generated_pending_callback_interleavings_match_pool_model, nil, {test_cases = 300})
	testing.expectf(t, err == nil, "hegel pending callback interleaving property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_generated_pending_callback_interleavings_match_pool_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	worker_state_init_core(nil, 105)
	defer worker_state_destroy_core_for_test()

	sock := connection_lifetime_test_sock(12)
	current_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "live", init_send_queue = true})
	if current_conn == nil {
		return hgl.interesting("initial stateful connection install failed")
	}

	pending: [CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending
	model_live_allocs := 0
	connection_completion_test_reset()
	defer connection_lifetime_cleanup_stateful_pending(&pending, &current_conn, &model_live_allocs)

	op_count_raw, op_count_err := hgl.draw_i64(tc, 1, 128)
	if op_count_err == .Stop_Test do return hgl.abort()
	if op_count_err != nil do return hgl.interesting("draw pending interleaving op count")

	for op_index in 0 ..< int(op_count_raw) {
		action_raw, action_err := hgl.draw_i64(tc, 0, 4)
		if action_err == .Stop_Test do return hgl.abort()
		if action_err != nil do return hgl.interesting("draw pending interleaving action")

		switch action_raw {
		case 0:
			_ = connection_lifetime_add_stateful_pooled_send(&pending, current_conn, &model_live_allocs)

		case 1:
			batch_count_raw, batch_count_err := hgl.draw_i64(tc, 1, 4)
			if batch_count_err == .Stop_Test do return hgl.abort()
			if batch_count_err != nil do return hgl.interesting("draw stateful batch count")
			_ = connection_lifetime_add_stateful_pooled_batch(&pending, current_conn, int(batch_count_raw), &model_live_allocs)

		case 2:
			ref_count_raw, ref_count_err := hgl.draw_i64(tc, 1, 4)
			if ref_count_err == .Stop_Test do return hgl.abort()
			if ref_count_err != nil do return hgl.interesting("draw stateful shared ref count")
			_ = connection_lifetime_add_stateful_shared_broadcast(&pending, current_conn, int(ref_count_raw), &model_live_allocs)

		case 3:
			if current_conn != nil {
				connection_test_uninstall(current_conn)
				current_conn = nil
			}
			current_conn = connection_test_install_fake(
				Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "live", init_send_queue = true},
			)
			if current_conn == nil {
				hgl.note(tc, fmt.tprintf("pending interleaving op_index=%d", op_index))
				return hgl.interesting("stateful socket reuse install failed")
			}

		case:
			active_count := connection_lifetime_pending_count(&pending)
			if active_count > 0 {
				active_raw, active_err := hgl.draw_i64(tc, 0, i64(active_count - 1))
				if active_err == .Stop_Test do return hgl.abort()
				if active_err != nil do return hgl.interesting("draw active pending completion")

				slot := connection_lifetime_nth_active_pending_slot(&pending, int(active_raw))
				if !connection_lifetime_complete_stateful_pending(&pending, slot, &model_live_allocs) {
					hgl.note(tc, fmt.tprintf("pending interleaving op_index=%d slot=%d", op_index, slot))
					return hgl.interesting("stateful pending completion failed")
				}
			}
		}

		if !connection_lifetime_stateful_invariants_hold(current_conn, model_live_allocs) {
			hgl.note(
				tc,
				fmt.tprintf(
					"pending interleaving invariant failed op_index=%d action=%d active_pending=%d model_live=%d pool_live=%d allocs=%d releases=%d used=%d",
					op_index,
					action_raw,
					connection_lifetime_pending_count(&pending),
					model_live_allocs,
					connection_lifetime_pool_live_alloc_count(td.spool),
					td.spool.allocation_count,
					td.spool.release_count,
					td.spool.used,
				),
			)
			return hgl.interesting("stateful pending interleaving diverged from pool/connection model")
		}
	}

	for connection_lifetime_pending_count(&pending) > 0 {
		slot := connection_lifetime_nth_active_pending_slot(&pending, 0)
		if !connection_lifetime_complete_stateful_pending(&pending, slot, &model_live_allocs) {
			return hgl.interesting("final stateful pending drain failed")
		}
	}

	if !connection_lifetime_stateful_invariants_hold(current_conn, model_live_allocs) || model_live_allocs != 0 {
		return hgl.interesting("final stateful pending model did not drain")
	}

	if current_conn != nil {
		connection_test_uninstall(current_conn)
		current_conn = nil
	}

	if !connection_lifetime_pool_drained(td.spool) {
		return hgl.interesting("stateful pending pool not drained after uninstall")
	}

	return {}
}

@(test)
test_hegel_generated_pending_callback_error_interleavings_match_pool_model :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_generated_pending_callback_error_interleavings_match_pool_model, nil, {test_cases = 200})
		testing.expectf(t, err == nil, "hegel pending callback error interleaving property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_graceful_close_lifetime_orderings :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_generated_graceful_close_lifetime_orderings, nil, {test_cases = 120})
		testing.expectf(t, err == nil, "hegel graceful close lifetime property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_stale_recv_parser_state_lifetimes :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_generated_stale_recv_parser_state_lifetimes, nil, {test_cases = 160})
		testing.expectf(t, err == nil, "hegel stale recv parser-state lifetime property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

when NRC_SIMULATION {
	Connection_Lifetime_Close_Mode :: enum {
		Immediate_Success,
		Immediate_Error,
		Queued_Success,
		Queued_Error,
	}

	Connection_Lifetime_Close_Stale_Point :: enum {
		None,
		Before_Queued_Drain,
		Before_Timer,
	}

	Connection_Lifetime_Recv_State_Model :: enum {
		None,
		Accumulator_Header,
		Accumulator_Target,
		Fragment,
		Accumulator_Header_And_Fragment,
		Accumulator_Target_And_Fragment,
	}

	Connection_Lifetime_Recv_Completion :: enum {
		Data,
		Zero_Bytes,
		Connection_Closed_Error,
		Other_Error,
	}

	connection_lifetime_error_for_index :: proc(index: i64) -> net.Network_Error {
		switch index % 3 {
		case 0:
			return net.TCP_Send_Error(.Timeout)
		case 1:
			return net.TCP_Send_Error(.Connection_Closed)
		case:
			return net.TCP_Send_Error(.Not_Connected)
		}
	}

	connection_lifetime_install_sim_connection :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, username: string) -> ^NRC_Connection {
		nrc_sim_register_client(sim, sock)
		return connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = username, init_send_queue = true, track_active_socket = true},
		)
	}

	connection_lifetime_noop_sent :: proc(c: ^NRC_Connection, ctx: rawptr, sent: int, err: net.Network_Error) {}

	connection_lifetime_complete_in_flight_send :: proc(sock: net.TCP_Socket, handle: Connection_Handle) {
		buf := []u8{0x82, 0x00}
		item := Send_Item {
			lease = Frame_Lease(Connection_Stable_Frame_Lease{data = buf, owner = handle}),
			handle = handle,
			observer = Send_Completion_Observer{callback = connection_lifetime_noop_sent},
		}
		on_queued_send_complete(sock, item, len(buf), nil)
	}

	connection_lifetime_active_socket_model_holds :: proc(sock: net.TCP_Socket, expected_count: int, expect_sock_present: bool) -> bool {
		if td.connection_count != expected_count {
			return false
		}
		if len(td.active_sockets) != expected_count {
			return false
		}
		_, present := td.active_sockets[sock]
		return present == expect_sock_present
	}

	connection_lifetime_install_recv_state_model :: proc(conn: ^NRC_Connection, model: Connection_Lifetime_Recv_State_Model) -> (pool_allocs: u64, ok: bool) {
		switch model {
		case .None:
			return 0, true

		case .Accumulator_Header:
			buf, err := byte_pool.alloc(td.spool, 14)
			if err != .None do return 0, false
			buf[0] = 0x81
			conn.receive_accumulator = Receive_Accumulator {
				buf  = buf,
				used = 1,
			}
			return 1, true

		case .Accumulator_Target:
			buf, err := byte_pool.alloc(td.spool, 64)
			if err != .None do return 0, false
			conn.receive_accumulator = Receive_Accumulator {
				buf    = buf,
				used   = 8,
				target = 64,
			}
			return 1, true

		case .Fragment:
			buf, err := byte_pool.alloc(td.spool, 64)
			if err != .None do return 0, false
			conn.fragment_buf = buf
			conn.fragment_len = 8
			return 1, true

		case .Accumulator_Header_And_Fragment:
			partial_buf, partial_err := byte_pool.alloc(td.spool, 14)
			if partial_err != .None do return 0, false
			fragment_buf, fragment_err := byte_pool.alloc(td.spool, 64)
			if fragment_err != .None {
				byte_pool.release(td.spool, partial_buf)
				return 0, false
			}
			partial_buf[0] = 0x81
			conn.receive_accumulator = Receive_Accumulator {
				buf  = partial_buf,
				used = 1,
			}
			conn.fragment_buf = fragment_buf
			conn.fragment_len = 8
			return 2, true

		case .Accumulator_Target_And_Fragment:
			large_buf, large_err := byte_pool.alloc(td.spool, 64)
			if large_err != .None do return 0, false
			fragment_buf, fragment_err := byte_pool.alloc(td.spool, 64)
			if fragment_err != .None {
				byte_pool.release(td.spool, large_buf)
				return 0, false
			}
			conn.receive_accumulator = Receive_Accumulator {
				buf    = large_buf,
				used   = 8,
				target = 64,
			}
			conn.fragment_buf = fragment_buf
			conn.fragment_len = 8
			return 2, true
		}
		return 0, false
	}

	connection_lifetime_cleanup_closed_sim_connection :: proc(current_conn: ^^NRC_Connection) {
		if current_conn^ == nil {
			return
		}
		if current_conn^^.state >= .Will_Close || connection_get(current_conn^^.sock) == nil {
			connection_test_uninstall(current_conn^)
			current_conn^ = nil
		}
	}

	prop_generated_graceful_close_lifetime_orderings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		worker_state_init_core(nil, 112)
		defer worker_state_destroy_core_for_test()

		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)

		mode_raw, mode_err := hgl.draw_i64(tc, 0, i64(len(Connection_Lifetime_Close_Mode) - 1))
		if mode_err == .Stop_Test do return hgl.abort()
		if mode_err != nil do return hgl.interesting("draw graceful close mode")

		stale_raw, stale_err := hgl.draw_i64(tc, 0, i64(len(Connection_Lifetime_Close_Stale_Point) - 1))
		if stale_err == .Stop_Test do return hgl.abort()
		if stale_err != nil do return hgl.interesting("draw graceful close stale point")

		error_raw, error_err := hgl.draw_i64(tc, 0, 2)
		if error_err == .Stop_Test do return hgl.abort()
		if error_err != nil do return hgl.interesting("draw graceful close error kind")

		mode := Connection_Lifetime_Close_Mode(mode_raw)
		stale_point := Connection_Lifetime_Close_Stale_Point(stale_raw)
		sock := connection_lifetime_test_sock(30)
		current_conn := connection_lifetime_install_sim_connection(&sim, sock, "old")
		if current_conn == nil {
			return hgl.interesting("generated graceful close connection install failed")
		}
		old_handle := current_conn.handle
		new_conn: ^NRC_Connection
		allocs_before := td.spool.allocation_count
		releases_before := td.spool.release_count
		defer {
			nrc_sim_run_all_timers(&sim)
			if current_conn != nil {
				connection_test_uninstall(current_conn)
				current_conn = nil
			}
			if new_conn != nil {
				connection_test_uninstall(new_conn)
				new_conn = nil
			}
		}

		queued_mode := mode == .Queued_Success || mode == .Queued_Error
		error_mode := mode == .Immediate_Error || mode == .Queued_Error
		if queued_mode {
			current_conn.is_sending = true
		}
		if mode == .Immediate_Error {
			nrc_sim_inject_next_close_frame_error(&sim, connection_lifetime_error_for_index(error_raw))
		} else if mode == .Queued_Error {
			nrc_sim_inject_next_queued_send_error(&sim, connection_lifetime_error_for_index(error_raw))
		}

		send_websocket_close_frame_and_close(current_conn, 1013, "Generated close")
		if !queued_mode {
			nrc_sim_run_all_send_completions(&sim)
			if !error_mode do nrc_sim_run_all_shutdown_sends(&sim)
		}
		if mode == .Immediate_Error {
			nrc_sim_run_all_close_completions(&sim)
			old_reclaimed := connection_get_by_handle(old_handle) == nil
			if old_reclaimed {
				connection_test_live_count -= 1
				current_conn = nil
			}
			if !old_reclaimed ||
			   connection_get(sock) != nil ||
			   !connection_lifetime_active_socket_model_holds(sock, 0, false) ||
			   nrc_sim_timer_event_count(&sim) != 0 ||
			   nrc_sim_client_frame_count(&sim, sock) != 0 {
				hgl.note(
					tc,
					fmt.tprintf(
						"immediate close error reclaimed=%v conn=%v frames=%d timers=%d",
						old_reclaimed,
						connection_get(sock),
						nrc_sim_client_frame_count(&sim, sock),
						nrc_sim_timer_event_count(&sim),
					),
				)
				return hgl.interesting("generated immediate graceful close error did not close cleanly")
			}
		} else if current_conn.state != .Will_Close {
			hgl.note(tc, fmt.tprintf("close mode=%v state=%v", mode, current_conn.state))
			return hgl.interesting("generated graceful close did not enter Will_Close")
		}

		if queued_mode {
			if nrc_sim_client_frame_count(&sim, sock) != 0 || nrc_sim_timer_event_count(&sim) != 0 || send_queue_priority_len(current_conn) != 1 {
				hgl.note(
					tc,
					fmt.tprintf(
						"queued close pre-drain mode=%v frames=%d timers=%d priority=%d",
						mode,
						nrc_sim_client_frame_count(&sim, sock),
						nrc_sim_timer_event_count(&sim),
						send_queue_priority_len(current_conn),
					),
				)
				return hgl.interesting("queued graceful close emitted frame or timer before in-flight send completion")
			}

			if stale_point == .Before_Queued_Drain {
				connection_test_uninstall(current_conn)
				current_conn = nil

				new_conn = connection_lifetime_install_sim_connection(&sim, sock, "new")
				if new_conn == nil {
					return hgl.interesting("generated graceful close queued stale reuse install failed")
				}

				connection_lifetime_complete_in_flight_send(sock, old_handle)
				nrc_sim_run_all_timers(&sim)
				if !connection_lifetime_assert_reused_socket_intact(sock, new_conn) ||
				   !connection_lifetime_active_socket_model_holds(sock, 1, true) ||
				   nrc_sim_timer_event_count(&sim) != 0 {
					hgl.note(
						tc,
						fmt.tprintf(
							"queued stale mode=%v conn_count=%d active=%d timers=%d",
							mode,
							td.connection_count,
							len(td.active_sockets),
							nrc_sim_timer_event_count(&sim),
						),
					)
					return hgl.interesting("stale queued graceful close completion affected reused socket")
				}
			} else {
				connection_lifetime_complete_in_flight_send(sock, old_handle)
				nrc_sim_run_all_send_completions(&sim)
				if !error_mode do nrc_sim_run_all_shutdown_sends(&sim)
			}
		}

		if current_conn != nil && stale_point != .Before_Queued_Drain {
			if error_mode {
				nrc_sim_run_all_close_completions(&sim)
				old_reclaimed := connection_get_by_handle(old_handle) == nil
				if old_reclaimed {
					connection_test_live_count -= 1
					current_conn = nil
				}
				if nrc_sim_timer_event_count(&sim) != 0 ||
				   nrc_sim_client_frame_count(&sim, sock) != 0 ||
				   connection_get(sock) != nil ||
				   !connection_lifetime_active_socket_model_holds(sock, 0, false) ||
				   !old_reclaimed {
					hgl.note(
						tc,
						fmt.tprintf(
							"close error mode=%v frames=%d timers=%d reclaimed=%v conn=%v",
							mode,
							nrc_sim_client_frame_count(&sim, sock),
							nrc_sim_timer_event_count(&sim),
							old_reclaimed,
							connection_get(sock),
						),
					)
					return hgl.interesting("generated graceful close error path did not close cleanly")
				}
			} else {
				if nrc_sim_client_frame_count(&sim, sock) != 1 || nrc_sim_timer_event_count(&sim) != 1 {
					hgl.note(
						tc,
						fmt.tprintf(
							"close success mode=%v frames=%d timers=%d",
							mode,
							nrc_sim_client_frame_count(&sim, sock),
							nrc_sim_timer_event_count(&sim),
						),
					)
					return hgl.interesting("generated graceful close success did not emit one close frame and timer")
				}

				if stale_point == .Before_Timer {
					connection_test_uninstall(current_conn)
					current_conn = nil

					new_conn = connection_lifetime_install_sim_connection(&sim, sock, "new")
					if new_conn == nil {
						return hgl.interesting("generated graceful close timer stale reuse install failed")
					}
					nrc_sim_run_all_timers(&sim)
					if !connection_lifetime_assert_reused_socket_intact(sock, new_conn) || !connection_lifetime_active_socket_model_holds(sock, 1, true) {
						hgl.note(tc, fmt.tprintf("timer stale mode=%v conn_count=%d active=%d", mode, td.connection_count, len(td.active_sockets)))
						return hgl.interesting("stale graceful close timer affected reused socket")
					}
				} else {
					nrc_sim_run_all_timers(&sim)
					nrc_sim_run_all_close_completions(&sim)
					old_reclaimed := connection_get_by_handle(old_handle) == nil
					if old_reclaimed {
						connection_test_live_count -= 1
						current_conn = nil
					}
					if connection_get(sock) != nil || !old_reclaimed || !connection_lifetime_active_socket_model_holds(sock, 0, false) {
						hgl.note(
							tc,
							fmt.tprintf(
								"live timer mode=%v reclaimed=%v conn=%v count=%d active=%d",
								mode,
								old_reclaimed,
								connection_get(sock),
								td.connection_count,
								len(td.active_sockets),
							),
						)
						return hgl.interesting("live graceful close timer did not close old connection")
					}
				}
			}
		}

		if td.spool.allocation_count != allocs_before || td.spool.release_count != releases_before || !connection_lifetime_pool_drained(td.spool) {
			hgl.note(
				tc,
				fmt.tprintf(
					"graceful close pool mode=%v stale=%v allocs=%d/%d releases=%d/%d used=%d",
					mode,
					stale_point,
					td.spool.allocation_count,
					allocs_before,
					td.spool.release_count,
					releases_before,
					td.spool.used,
				),
			)
			return hgl.interesting("generated graceful close touched pooled send buffers")
		}

		return {}
	}

	prop_generated_stale_recv_parser_state_lifetimes :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		worker_state_init_core(nil, 113)
		defer worker_state_destroy_core_for_test()

		state_raw, state_err := hgl.draw_i64(tc, 0, i64(len(Connection_Lifetime_Recv_State_Model) - 1))
		if state_err == .Stop_Test do return hgl.abort()
		if state_err != nil do return hgl.interesting("draw stale recv parser state model")

		completion_raw, completion_err := hgl.draw_i64(tc, 0, i64(len(Connection_Lifetime_Recv_Completion) - 1))
		if completion_err == .Stop_Test do return hgl.abort()
		if completion_err != nil do return hgl.interesting("draw stale recv completion kind")

		model := Connection_Lifetime_Recv_State_Model(state_raw)
		completion := Connection_Lifetime_Recv_Completion(completion_raw)
		sock := connection_lifetime_test_sock(31)
		old_conn := connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true, track_active_socket = true},
		)
		if old_conn == nil {
			return hgl.interesting("generated stale recv old connection install failed")
		}

		old_ctx := connection_io_context_make(old_conn)
		allocs_before := td.spool.allocation_count
		releases_before := td.spool.release_count
		pool_allocs, state_ok := connection_lifetime_install_recv_state_model(old_conn, model)
		if !state_ok {
			connection_test_uninstall(old_conn)
			return hgl.interesting("generated stale recv parser state setup failed")
		}

		if td.spool.allocation_count != allocs_before + pool_allocs || td.spool.release_count != releases_before {
			connection_test_uninstall(old_conn)
			return hgl.interesting("generated stale recv parser state setup had unexpected pool accounting")
		}

		connection_test_uninstall(old_conn)
		if td.spool.release_count != releases_before + pool_allocs || !connection_lifetime_pool_drained(td.spool) {
			hgl.note(
				tc,
				fmt.tprintf(
					"stale recv cleanup model=%v allocs=%d/%d releases=%d/%d used=%d",
					model,
					td.spool.allocation_count,
					allocs_before + pool_allocs,
					td.spool.release_count,
					releases_before + pool_allocs,
					td.spool.used,
				),
			)
			return hgl.interesting("generated stale recv parser buffers were not released on uninstall")
		}

		new_conn := connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true, track_active_socket = true},
		)
		if new_conn == nil {
			return hgl.interesting("generated stale recv reused connection install failed")
		}
		defer {
			connection_test_uninstall(new_conn)
		}

		new_handle_before := new_conn.handle
		last_activity_before := new_conn.last_activity
		data := []u8{0x81}
		switch completion {
		case .Data:
			on_recv_websocket_fixed(old_ctx, len(data), data, {}, nil)
		case .Zero_Bytes:
			on_recv_websocket_fixed(old_ctx, 0, {}, {}, nil)
		case .Connection_Closed_Error:
			on_recv_websocket_fixed(old_ctx, 0, {}, {}, net.TCP_Recv_Error(.Connection_Closed))
		case .Other_Error:
			on_recv_websocket_fixed(old_ctx, 0, {}, {}, net.TCP_Recv_Error(.Not_Connected))
		}

		parser_touched := new_conn.receive_accumulator.buf != nil || new_conn.fragment_buf != nil || new_conn.fragment_len != 0

		if new_conn.handle != new_handle_before ||
		   !connection_lifetime_assert_reused_socket_intact(sock, new_conn) ||
		   !connection_lifetime_active_socket_model_holds(sock, 1, true) ||
		   new_conn.last_activity != last_activity_before ||
		   parser_touched {
			hgl.note(
				tc,
				fmt.tprintf(
					"stale recv affected new conn model=%v completion=%v state=%v count=%d active=%d handle_changed=%v activity_changed=%v parser_touched=%v",
					model,
					completion,
					new_conn.state,
					td.connection_count,
					len(td.active_sockets),
					new_conn.handle != new_handle_before,
					new_conn.last_activity != last_activity_before,
					parser_touched,
				),
			)
			return hgl.interesting("generated stale recv completion affected reused socket")
		}

		if td.spool.allocation_count != allocs_before + pool_allocs ||
		   td.spool.release_count != releases_before + pool_allocs ||
		   !connection_lifetime_pool_drained(td.spool) {
			hgl.note(
				tc,
				fmt.tprintf(
					"stale recv final pool model=%v completion=%v allocs=%d/%d releases=%d/%d used=%d",
					model,
					completion,
					td.spool.allocation_count,
					allocs_before + pool_allocs,
					td.spool.release_count,
					releases_before + pool_allocs,
					td.spool.used,
				),
			)
			return hgl.interesting("generated stale recv completion changed parser buffer ownership")
		}

		return {}
	}

	prop_generated_pending_callback_error_interleavings_match_pool_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		previous_logger := context.logger
		context.logger = log.nil_logger()
		defer {
			context.logger = previous_logger
		}

		worker_state_init_core(nil, 106)
		defer worker_state_destroy_core_for_test()

		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)

		sock := connection_lifetime_test_sock(13)
		current_conn := connection_lifetime_install_sim_connection(&sim, sock, "live")
		if current_conn == nil {
			return hgl.interesting("initial error-interleaving connection install failed")
		}

		pending: [CONNECTION_LIFETIME_STATEFUL_MAX_PENDING]Connection_Lifetime_Stateful_Pending
		model_live_allocs := 0
		connection_completion_test_reset()
		defer connection_lifetime_cleanup_sim_stateful_pending(&sim, &pending, &current_conn, &model_live_allocs)

		op_count_raw, op_count_err := hgl.draw_i64(tc, 1, 128)
		if op_count_err == .Stop_Test do return hgl.abort()
		if op_count_err != nil do return hgl.interesting("draw pending error interleaving op count")

		for op_index in 0 ..< int(op_count_raw) {
			action_raw, action_err := hgl.draw_i64(tc, 0, 5)
			if action_err == .Stop_Test do return hgl.abort()
			if action_err != nil do return hgl.interesting("draw pending error interleaving action")

			switch action_raw {
			case 0:
				_ = connection_lifetime_add_stateful_pooled_send(&pending, current_conn, &model_live_allocs)

			case 1:
				batch_count_raw, batch_count_err := hgl.draw_i64(tc, 1, 4)
				if batch_count_err == .Stop_Test do return hgl.abort()
				if batch_count_err != nil do return hgl.interesting("draw error stateful batch count")
				_ = connection_lifetime_add_stateful_pooled_batch(&pending, current_conn, int(batch_count_raw), &model_live_allocs)

			case 2:
				ref_count_raw, ref_count_err := hgl.draw_i64(tc, 1, 4)
				if ref_count_err == .Stop_Test do return hgl.abort()
				if ref_count_err != nil do return hgl.interesting("draw error stateful shared ref count")
				_ = connection_lifetime_add_stateful_shared_broadcast(&pending, current_conn, int(ref_count_raw), &model_live_allocs)

			case 3:
				if current_conn != nil {
					connection_test_uninstall(current_conn)
					current_conn = nil
				}
				current_conn = connection_lifetime_install_sim_connection(&sim, sock, "live")
				if current_conn == nil {
					hgl.note(tc, fmt.tprintf("pending error interleaving op_index=%d", op_index))
					return hgl.interesting("error stateful socket reuse install failed")
				}

			case 4, 5:
				active_count := connection_lifetime_pending_count(&pending)
				if active_count > 0 {
					active_raw, active_err := hgl.draw_i64(tc, 0, i64(active_count - 1))
					if active_err == .Stop_Test do return hgl.abort()
					if active_err != nil do return hgl.interesting("draw active error pending completion")

					slot := connection_lifetime_nth_active_pending_slot(&pending, int(active_raw))
					send_err: net.Network_Error
					if action_raw == 5 {
						err_raw, err_draw := hgl.draw_i64(tc, 0, 2)
						if err_draw == .Stop_Test do return hgl.abort()
						if err_draw != nil do return hgl.interesting("draw send error kind")
						send_err = connection_lifetime_error_for_index(err_raw)
					}

					if !connection_lifetime_complete_stateful_pending(&pending, slot, &model_live_allocs, send_err) {
						hgl.note(tc, fmt.tprintf("pending error interleaving op_index=%d slot=%d", op_index, slot))
						return hgl.interesting("error stateful pending completion failed")
					}

					nrc_sim_run_all_timers(&sim)
					connection_lifetime_cleanup_closed_sim_connection(&current_conn)
				}
			}

			if !connection_lifetime_stateful_invariants_hold(current_conn, model_live_allocs) {
				hgl.note(
					tc,
					fmt.tprintf(
						"pending error invariant failed op_index=%d action=%d active_pending=%d model_live=%d pool_live=%d allocs=%d releases=%d used=%d current_state=%v",
						op_index,
						action_raw,
						connection_lifetime_pending_count(&pending),
						model_live_allocs,
						connection_lifetime_pool_live_alloc_count(td.spool),
						td.spool.allocation_count,
						td.spool.release_count,
						td.spool.used,
						current_conn != nil ? current_conn.state : Connection_State.Closed,
					),
				)
				return hgl.interesting("error stateful pending interleaving diverged from pool/connection model")
			}
		}

		for connection_lifetime_pending_count(&pending) > 0 {
			slot := connection_lifetime_nth_active_pending_slot(&pending, 0)
			if !connection_lifetime_complete_stateful_pending(&pending, slot, &model_live_allocs, net.TCP_Send_Error(.Connection_Closed)) {
				return hgl.interesting("final error stateful pending drain failed")
			}
			nrc_sim_run_all_timers(&sim)
			connection_lifetime_cleanup_closed_sim_connection(&current_conn)
		}

		if !connection_lifetime_stateful_invariants_hold(current_conn, model_live_allocs) || model_live_allocs != 0 {
			return hgl.interesting("final error stateful pending model did not drain")
		}

		if current_conn != nil {
			connection_test_uninstall(current_conn)
			current_conn = nil
		}

		if !connection_lifetime_pool_drained(td.spool) {
			return hgl.interesting("error stateful pending pool not drained after uninstall")
		}

		return {}
	}
}

@(test)
test_connection_aba_protection :: proc(t: ^testing.T) {
	// Ensure connection storage is initialized
	connection_storage_init()
	defer {
		connection_test_storage_destroy()
	}

	sock1 := net.TCP_Socket(12345)

	// Create a new connection
	conn1, ok1 := connection_alloc()
	testing.expect(t, ok1, "expected to allocate connection")
	conn1.sock = sock1

	// Set socket handle
	connection_set_socket_handle(sock1, conn1.handle)

	// Verify we can get it back
	fetched1 := connection_get_by_handle(conn1.handle)
	testing.expect(t, fetched1 == conn1, "expected fetched connection to match original")

	fetched_by_sock1 := connection_get(sock1)
	testing.expect(t, fetched_by_sock1 == conn1, "expected fetched connection by sock to match original")

	// Save the old handle
	old_handle := conn1.handle

	// Remove the connection (simulating a close)
	connection_remove(conn1)

	// Verify we can't get it by the old handle
	fetched_old := connection_get_by_handle(old_handle)
	testing.expect(t, fetched_old == nil, "expected fetched connection by old handle to be nil")

	// Verify we can't get it by the socket
	fetched_by_sock_old := connection_get(sock1)
	testing.expect(t, fetched_by_sock_old == nil, "expected fetched connection by old sock to be nil")

	// Allocate a new connection (it might reuse the same slot)
	conn2, ok2 := connection_alloc()
	testing.expect(t, ok2, "expected to allocate second connection")

	// The handle should be different (different generation) even if it reuses the slot
	testing.expect(t, conn2.handle != old_handle, "expected new handle to be different from old handle")

	// Trying to fetch by old handle should STILL be nil
	fetched_old_after_reuse := connection_get_by_handle(old_handle)
	testing.expect(t, fetched_old_after_reuse == nil, "expected fetched connection by old handle to be nil after slot reuse")

	connection_remove(conn2)
}

@(test)
test_send_completion_after_connection_removed_is_cleanup_only :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 91)
	defer worker_state_destroy_core_for_test()
	connection_completion_test_reset()

	sock := net.TCP_Socket(490_001)
	conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true})
	testing.expect(t, conn != nil, "expected fake connection")
	if conn == nil {
		return
	}

	item := Send_Item {
		lease = Frame_Lease(Pooled_Frame_Lease{}),
		handle = conn.handle,
		observer = Send_Completion_Observer{callback = connection_completion_test_callback},
	}
	connection_test_uninstall(conn)

	on_queued_send_complete(sock, item, len(frame_lease_data(item.lease)), nil)

	testing.expect_value(t, connection_completion_callback_count, 1)
	testing.expect_value(t, connection_completion_nil_count, 1)
	testing.expect_value(t, connection_completion_new_conn_count, 0)
}

@(test)
test_send_completion_after_socket_reuse_does_not_target_new_connection :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 92)
	defer worker_state_destroy_core_for_test()
	connection_completion_test_reset()

	sock := net.TCP_Socket(490_017)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true})
	testing.expect(t, old_conn != nil, "expected old fake connection")
	if old_conn == nil {
		return
	}

	old_item := Send_Item {
		lease = Frame_Lease(Pooled_Frame_Lease{}),
		handle = old_conn.handle,
		observer = Send_Completion_Observer{callback = connection_completion_test_callback},
	}
	connection_test_uninstall(old_conn)

	new_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true})
	defer connection_test_uninstall(new_conn)
	testing.expect(t, new_conn != nil, "expected new fake connection")
	if new_conn == nil {
		return
	}

	on_queued_send_complete(sock, old_item, len(frame_lease_data(old_item.lease)), nil)

	testing.expect_value(t, connection_completion_callback_count, 1)
	testing.expect_value(t, connection_completion_nil_count, 1)
	testing.expect_value(t, connection_completion_new_conn_count, 0)
	testing.expect(t, connection_get(sock) == new_conn, "new connection should remain installed after stale completion")
}

@(test)
test_batch_send_completion_after_socket_reuse_does_not_target_new_connection :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 93)
	defer worker_state_destroy_core_for_test()
	connection_completion_test_reset()

	sock := net.TCP_Socket(490_033)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true})
	testing.expect(t, old_conn != nil, "expected old fake connection")
	if old_conn == nil {
		return
	}

	state := alloc_batch_state(1)
	testing.expect(t, state != nil, "expected batch state allocation")
	if state == nil {
		connection_test_uninstall(old_conn)
		return
	}
	state.count = 1
	state.items = state.items[:1]
	state.iovec = state.iovec[:1]
	state.items[0] = Batch_Item {
		observer = Send_Completion_Observer{callback = connection_completion_test_callback},
		handle = old_conn.handle,
		lease = Frame_Lease(Pooled_Frame_Lease{}),
	}
	state.iovec[0] = nbio.iovec {
		iov_base = raw_data(frame_lease_data(state.items[0].lease)),
		iov_len  = uint(len(frame_lease_data(state.items[0].lease))),
	}

	connection_test_uninstall(old_conn)

	new_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true})
	defer connection_test_uninstall(new_conn)
	testing.expect(t, new_conn != nil, "expected new fake connection")
	if new_conn == nil {
		free_batch_state(state)
		return
	}

	on_batch_send_complete(sock, state, len(frame_lease_data(state.items[0].lease)), nil)

	testing.expect_value(t, connection_completion_callback_count, 1)
	testing.expect_value(t, connection_completion_nil_count, 1)
	testing.expect_value(t, connection_completion_new_conn_count, 0)
	testing.expect(t, connection_get(sock) == new_conn, "new connection should remain installed after stale batch completion")
}

@(test)
test_graceful_close_delay_after_socket_reuse_does_not_close_new_connection :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 97)
	defer worker_state_destroy_core_for_test()

	sock := net.TCP_Socket(490_049)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Will_Close, verified_username = "old", init_send_queue = true})
	testing.expect(t, old_conn != nil, "expected old graceful-close connection")
	if old_conn == nil {
		return
	}

	ctx := graceful_close_context_new(old_conn)
	connection_test_uninstall(old_conn)

	new_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true})
	defer connection_test_uninstall(new_conn)
	testing.expect(t, new_conn != nil, "expected new graceful-close socket-reuse connection")
	if new_conn == nil {
		free(ctx)
		return
	}

	on_graceful_close_delay_elapsed(ctx)

	testing.expect(t, connection_get(sock) == new_conn, "stale graceful close delay should not remove reused socket connection")
	testing.expect_value(t, new_conn.state, Connection_State.Idle)
}

@(test)
test_graceful_shutdown_completion_after_socket_reuse_does_not_close_new_connection :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 98)
	defer worker_state_destroy_core_for_test()

	sock := net.TCP_Socket(490_065)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Will_Close, verified_username = "old", init_send_queue = true})
	testing.expect(t, old_conn != nil, "expected old graceful-shutdown connection")
	if old_conn == nil {
		return
	}

	ctx := graceful_close_context_new(old_conn)
	connection_test_uninstall(old_conn)

	new_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true})
	defer connection_test_uninstall(new_conn)
	testing.expect(t, new_conn != nil, "expected new graceful-shutdown socket-reuse connection")
	if new_conn == nil {
		free(ctx)
		return
	}

	on_graceful_close_shutdown_complete(ctx, .Connection_Closed)

	testing.expect(t, connection_get(sock) == new_conn, "stale graceful shutdown completion should not remove reused socket connection")
	testing.expect_value(t, new_conn.state, Connection_State.Idle)
}

@(test)
test_recv_completion_after_socket_reuse_does_not_target_new_connection :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 99)
	defer worker_state_destroy_core_for_test()

	sock := net.TCP_Socket(490_081)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true})
	testing.expect(t, old_conn != nil, "expected old recv connection")
	if old_conn == nil {
		return
	}

	ctx := connection_io_context_make(old_conn)
	connection_test_uninstall(old_conn)

	new_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true})
	defer connection_test_uninstall(new_conn)
	testing.expect(t, new_conn != nil, "expected new recv socket-reuse connection")
	if new_conn == nil {
		return
	}
	old_last_activity := new_conn.last_activity
	recv_buf := []u8{0}

	on_recv_websocket_fixed(ctx, len(recv_buf), recv_buf, {}, nil)

	testing.expect(t, connection_get(sock) == new_conn, "stale recv completion should not remove reused socket connection")
	testing.expect_value(t, new_conn.state, Connection_State.Idle)
	testing.expect(t, new_conn.last_activity == old_last_activity, "stale recv completion should not update reused connection activity")
}

@(test)
test_recv_error_after_socket_reuse_does_not_close_new_connection :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 100)
	defer worker_state_destroy_core_for_test()

	sock := net.TCP_Socket(490_097)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true})
	testing.expect(t, old_conn != nil, "expected old recv-error connection")
	if old_conn == nil {
		return
	}

	ctx := connection_io_context_make(old_conn)
	connection_test_uninstall(old_conn)

	new_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true})
	defer connection_test_uninstall(new_conn)
	testing.expect(t, new_conn != nil, "expected new recv-error socket-reuse connection")
	if new_conn == nil {
		return
	}

	on_recv_websocket_fixed(ctx, 0, {}, {}, net.TCP_Recv_Error(.Connection_Closed))

	testing.expect(t, connection_get(sock) == new_conn, "stale recv error should not remove reused socket connection")
	testing.expect_value(t, new_conn.state, Connection_State.Idle)
}

@(test)
test_physical_close_completion_after_socket_reuse_does_not_remove_new_connection :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 101)
	defer worker_state_destroy_core_for_test()

	sock := net.TCP_Socket(490_113)
	old_conn := connection_test_install_fake(
		Fake_Connection_Options{sock = sock, state = .Closing, verified_username = "old", init_send_queue = true, track_active_socket = true},
	)
	testing.expect(t, old_conn != nil, "expected old physical-close connection")
	if old_conn == nil {
		return
	}

	ctx := connection_io_context_make(old_conn)
	connection_test_uninstall(old_conn)

	new_conn := connection_test_install_fake(
		Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true, track_active_socket = true},
	)
	defer {
		connection_test_uninstall(new_conn)
	}
	testing.expect(t, new_conn != nil, "expected new physical-close socket-reuse connection")
	if new_conn == nil {
		return
	}
	connection_count_before := td.connection_count

	on_connection_close_complete(ctx, false, true)

	testing.expect(t, connection_get(sock) == new_conn, "stale physical close completion should not remove reused socket connection")
	testing.expect_value(t, new_conn.state, Connection_State.Idle)
	testing.expect_value(t, td.connection_count, connection_count_before)
}

@(test)
test_physical_close_completion_does_not_clear_new_mapping_when_old_handle_still_live :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 102)
	defer worker_state_destroy_core_for_test()

	sock := net.TCP_Socket(490_129)
	old_conn := connection_test_install_fake(
		Fake_Connection_Options{sock = sock, state = .Closing, verified_username = "old", init_send_queue = true, track_active_socket = true},
	)
	testing.expect(t, old_conn != nil, "expected old live-handle physical-close connection")
	if old_conn == nil {
		return
	}

	ctx := connection_io_context_make(old_conn)
	connection_clear_socket_handle(sock)
	delete_key(&td.active_sockets, sock)
	if td.connection_count > 0 {
		td.connection_count -= 1
	}

	new_conn := connection_test_install_fake(
		Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true, track_active_socket = true},
	)
	defer {
		connection_test_uninstall(new_conn)
	}
	testing.expect(t, new_conn != nil, "expected new mapping physical-close socket-reuse connection")
	if new_conn == nil {
		send_queue_destroy(old_conn)
		connection_remove(old_conn)
		return
	}
	connection_count_before := td.connection_count
	old_handle := old_conn.handle

	on_connection_close_complete(ctx, false, true)

	testing.expect(t, connection_get(sock) == new_conn, "old live-handle close completion should not clear reused socket mapping")
	testing.expect_value(t, new_conn.state, Connection_State.Idle)
	testing.expect_value(t, td.connection_count, connection_count_before)
	testing.expect(t, connection_get_by_handle(old_handle) == nil, "old live handle should be removed by stale close completion")
	if connection_test_live_count > 0 {
		connection_test_live_count -= 1
	}
}

@(test)
test_physical_close_completion_releases_parser_buffers_once :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		worker_state_init_core(nil, 114)
		defer worker_state_destroy_core_for_test()

		cases := [?]struct {
			name:  string,
			model: Connection_Lifetime_Recv_State_Model,
		} {
			{name = "accumulator header", model = .Accumulator_Header},
			{name = "accumulator target", model = .Accumulator_Target},
			{name = "fragment", model = .Fragment},
			{name = "accumulator header and fragment", model = .Accumulator_Header_And_Fragment},
			{name = "accumulator target and fragment", model = .Accumulator_Target_And_Fragment},
		}

		for test_case, case_index in cases {
			sock := connection_lifetime_test_sock(80 + case_index)
			conn := connection_test_install_fake(
				Fake_Connection_Options{sock = sock, state = .Closing, verified_username = "closing", init_send_queue = true, track_active_socket = true},
			)
			testing.expectf(t, conn != nil, "case %d (%s) should install closing connection", case_index, test_case.name)
			if conn == nil {
				continue
			}

			allocs_before := td.spool.allocation_count
			releases_before := td.spool.release_count
			used_before := td.spool.used
			pool_allocs, setup_ok := connection_lifetime_install_recv_state_model(conn, test_case.model)
			testing.expectf(t, setup_ok, "case %d (%s) should set up parser state", case_index, test_case.name)
			if !setup_ok {
				connection_test_uninstall(conn)
				continue
			}
			testing.expect_value(t, td.spool.allocation_count, allocs_before + pool_allocs)
			testing.expect_value(t, td.spool.release_count, releases_before)

			ctx := connection_io_context_make(conn)
			old_handle := conn.handle
			on_connection_close_complete(ctx, false, true)
			if connection_test_live_count > 0 {
				connection_test_live_count -= 1
			}

			testing.expectf(t, connection_get(sock) == nil, "case %d (%s) should clear socket mapping", case_index, test_case.name)
			testing.expectf(t, connection_get_by_handle(old_handle) == nil, "case %d (%s) should remove handle", case_index, test_case.name)
			testing.expectf(
				t,
				connection_lifetime_active_socket_model_holds(sock, 0, false),
				"case %d (%s) should clear active socket model",
				case_index,
				test_case.name,
			)
			testing.expectf(
				t,
				td.spool.allocation_count == allocs_before + pool_allocs,
				"case %d (%s) should not allocate during close completion",
				case_index,
				test_case.name,
			)
			testing.expectf(
				t,
				td.spool.release_count == releases_before + pool_allocs,
				"case %d (%s) should release parser buffers once",
				case_index,
				test_case.name,
			)
			testing.expectf(t, td.spool.used == used_before, "case %d (%s) should drain parser pool bytes", case_index, test_case.name)

			releases_after_first := td.spool.release_count
			on_connection_close_complete(ctx, false, true)
			testing.expectf(
				t,
				td.spool.release_count == releases_after_first,
				"case %d (%s) duplicate close completion should not release again",
				case_index,
				test_case.name,
			)
			testing.expectf(
				t,
				connection_lifetime_active_socket_model_holds(sock, 0, false),
				"case %d (%s) duplicate close completion should keep active model empty",
				case_index,
				test_case.name,
			)
		}
	}
}

@(test)
test_connection_thread_guard :: proc(t: ^testing.T) {
	// Suppress error logs so the test framework doesn't interpret the logged error as a test failure
	previous_logger := context.logger
	context.logger = log.Logger {
		procedure = log.nil_logger_proc,
	}

	conn := connection_test_install(net.TCP_Socket(12345), .Idle)
	defer connection_test_storage_destroy()
	defer connection_test_uninstall(conn)

	// Pretend this connection belongs to a different thread
	td.thread_index = 1
	conn.thread_index = 2

	// Attempt to close it. It should log an error and return without changing state.
	// Since we can't easily capture the log, we verify the state doesn't change to .Closing.
	connection_close(conn, false)
	context.logger = previous_logger

	testing.expect_value(t, conn.state, Connection_State.Idle)

	// Restore so defer doesn't break
	td.thread_index = 0
	conn.thread_index = 0
}

@(test)
test_connection_close_cleanup_and_leaks :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer nbio.destroy(&td.io)

	orig_spool := td.spool
	td.spool = byte_pool.init_buffer_pool()
	defer {
		byte_pool.destroy_buffer_pool(td.spool)
		td.spool = orig_spool
	}

	defer {
		connection_test_storage_destroy()
	}

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	// Since accepted_sock gets closed by connection_close, don't defer net.close(accepted_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "expected test connection allocation")
	send_queue_init(conn)

	td.active_sockets = make(map[net.TCP_Socket]struct{}, 1)
	defer delete(td.active_sockets)

	// Add to active sockets
	td.active_sockets[accepted_sock] = {}
	td.connection_count += 1

	// Allocate dummy buffers in both independent receive state dimensions.
	// Receive accumulation and Fragment can be active together: transport buffering is
	// independent from WebSocket message fragmentation.
	large_buf, _ := byte_pool.alloc(td.spool, 100)
	conn.receive_accumulator = Receive_Accumulator {
		buf    = large_buf,
		target = 100,
	}
	conn.fragment_buf, _ = byte_pool.alloc(td.spool, 100)
	conn.fragment_len = 10

	// Issue the close
	connection_close(conn, false)

	// Tick IO to complete the close
	start := ulid.time_now()
	for td.retained_connection_count > 0 && time.since(start) < time.Second {
		// Trigger peer EOF without releasing the FD before its deferred close.
		// Repeated close calls can close another test's WAL after descriptor reuse.
		if time.since(start) > time.Millisecond * 50 {
			net.shutdown(client_sock, .Both)
		}
		nbio.tick(&td.io, time.Millisecond)
	}

	testing.expect_value(t, td.retained_connection_count, 0)
	testing.expect_value(t, td.connection_count, 0)
	if td.retained_connection_count > 0 {
		// Never bypass reclamation while callbacks still own buffers.
		testing.fail_now(t, "close must drain all I/O and reclaim the connection before teardown")
	}

	testing.expect_value(t, len(td.active_sockets), 0)
	testing.expect(t, connection_get(accepted_sock) == nil, "expected socket mapping to be cleared")
	connection_test_mark_removed(accepted_sock)
}

@(test)
test_check_idle_connections_reaping :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer nbio.destroy(&td.io)

	orig_spool := td.spool
	td.spool = byte_pool.init_buffer_pool()
	defer {
		byte_pool.destroy_buffer_pool(td.spool)
		td.spool = orig_spool
	}

	defer connection_test_storage_destroy()

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "expected test connection allocation")
	send_queue_init(conn)

	td.active_sockets = make(map[net.TCP_Socket]struct{}, 1)
	defer delete(td.active_sockets)

	td.active_sockets[accepted_sock] = {}
	td.connection_count += 1

	// Set last activity to be very old
	conn.last_activity = time.time_add(ulid.time_now_monotonic(), -(Idle_Timeout + time.Second))

	// Position the bounded idle scan over this test socket and run one slice.
	td.idle_scan_cursor = int(accepted_sock)
	check_idle_connections(nrc_time_now_monotonic())

	// Tick IO to complete the close frame send and actual connection close
	start := ulid.time_now()
	for td.connection_count > 0 && time.since(start) < time.Second {
		if time.since(start) > time.Millisecond * 50 {
			net.shutdown(client_sock, .Both)
		}
		nbio.tick(&td.io, time.Millisecond)
	}

	// The connection should have transitioned to Closing
	testing.expect(t, conn.state >= Connection_State.Closing, "expected idle connection to be closed")

	testing.expect_value(t, td.connection_count, 0)
	if td.connection_count > 0 {
		delete_key(&td.active_sockets, conn.sock)
		connection_remove(conn)
		td.connection_count = 0
	}

	testing.expect(t, connection_get(accepted_sock) == nil, "expected idle connection mapping to be cleared")
	connection_test_mark_removed(accepted_sock)
}

@(test)
test_send_watchdog_closes_send_started_after_empty_scan_at_its_deadline :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer nbio.destroy(&td.io)

	defer connection_test_storage_destroy()

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := connection_test_install(accepted_sock, .Active)
	testing.expect(t, conn != nil, "expected test connection allocation")
	send_queue_init(conn)
	handle := conn.handle

	td.active_sockets = make(map[net.TCP_Socket]struct{}, 1)
	defer delete(td.active_sockets)
	td.active_sockets[accepted_sock] = {}
	td.connection_count += 1

	// Model a watchdog pass followed immediately by a new send. Its exact
	// deadline must become the next scan time instead of waiting for a fixed
	// periodic scan that could add almost another full timeout interval.
	started_at := ulid.time_now_monotonic()
	check_stalled_sends(started_at)
	testing.expect(t, td.next_send_watchdog_at == {}, "empty watchdog should have no scheduled deadline")
	send_watchdog_started(conn, time.time_add(started_at, time.Nanosecond))
	deadline := time.time_add(conn.send_started_at, Conn_Send_Timeout)
	testing.expect(t, td.next_send_watchdog_at == deadline, "new send should schedule its exact watchdog deadline")

	check_stalled_sends(time.time_add(deadline, -Worker_Maintenance_Interval))
	testing.expect(t, conn.state < .Closing, "send should remain open before its deadline")
	testing.expect(t, td.next_send_watchdog_at == deadline, "early maintenance should retain the send deadline")

	check_stalled_sends(time.time_add(deadline, Worker_Maintenance_Interval))

	testing.expect(t, conn.state >= .Closing, "send should close within one maintenance tick of its deadline")
	testing.expect(t, connection_get(accepted_sock) == nil, "logical close detaches the socket before reclaiming its allocation")
	// connection_count reaches zero at detach, before the close completion
	// releases the handle and its queues. Wait for that final owner too.
	start := ulid.time_now()
	for connection_get_by_handle(handle) != nil && time.since(start) < time.Second {
		nbio.tick(&td.io, time.Millisecond)
	}
	testing.expect_value(t, td.connection_count, 0)
	testing.expect(t, connection_get_by_handle(handle) == nil, "close completion must reclaim the connection")
	testing.expect_value(t, td.retained_connection_count, 0)
	connection_test_mark_removed(accepted_sock)
}

@(test)
test_send_watchdog_dense_index_swap_remove :: proc(t: ^testing.T) {
	defer connection_test_storage_destroy()

	first := connection_test_install_fake(Fake_Connection_Options{sock = connection_test_fake_socket(910), state = .Active})
	second := connection_test_install_fake(Fake_Connection_Options{sock = connection_test_fake_socket(911), state = .Active})
	testing.expect(t, first != nil && second != nil, "expected watchdog test connections")
	if first == nil || second == nil do return

	send_watchdog_track(first)
	send_watchdog_track(second)
	testing.expect_value(t, len(td.inflight_send_handles), 2)
	testing.expect_value(t, first.send_watchdog_slot, u32(1))
	testing.expect_value(t, second.send_watchdog_slot, u32(2))

	send_watchdog_untrack(first)
	testing.expect_value(t, len(td.inflight_send_handles), 1)
	testing.expect_value(t, first.send_watchdog_slot, u32(0))
	testing.expect_value(t, second.send_watchdog_slot, u32(1))
	testing.expect_value(t, td.inflight_send_handles[0], second.handle)

	send_watchdog_untrack(second)
	testing.expect_value(t, len(td.inflight_send_handles), 0)
	connection_test_uninstall(first)
	connection_test_uninstall(second)
}

send_watchdog_test_invariants_hold :: proc(conns: []^NRC_Connection, tracked: []bool) -> bool {
	if len(conns) != len(tracked) do return false

	tracked_count := 0
	for conn, i in conns {
		if conn == nil do return false
		if tracked[i] {
			tracked_count += 1
			if conn.send_watchdog_slot == 0 do return false
			index := int(conn.send_watchdog_slot - 1)
			if index < 0 || index >= len(td.inflight_send_handles) do return false
			if td.inflight_send_handles[index] != conn.handle do return false
		} else if conn.send_watchdog_slot != 0 {
			return false
		}
	}
	if tracked_count != len(td.inflight_send_handles) do return false

	for handle, i in td.inflight_send_handles {
		conn := connection_get_by_handle(handle)
		if conn == nil || conn.send_watchdog_slot != u32(i + 1) do return false
	}
	return true
}

@(test)
test_hegel_send_watchdog_dense_index_matches_model :: proc(t: ^testing.T) {
	if !hgl.can_run() do return

	result, err := hgl.run(prop_send_watchdog_dense_index_matches_model, nil, {test_cases = 200})
	testing.expectf(t, err == nil, "hegel send watchdog index property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_send_watchdog_dense_index_matches_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	worker_state_init_core(nil, 124, 8)
	defer worker_state_destroy_core_for_test()

	conns: [8]^NRC_Connection
	tracked: [8]bool
	for i in 0 ..< len(conns) {
		conns[i] = connection_test_install_fake(Fake_Connection_Options{sock = connection_test_fake_socket(920 + i), state = .Active})
		if conns[i] == nil do return hgl.interesting("watchdog model connection allocation failed")
	}
	defer {
		for conn in conns {
			send_watchdog_untrack(conn)
			connection_test_uninstall(conn)
		}
	}

	op_count, draw_err := hgl.draw_i64(tc, 1, 256)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw watchdog operation count")

	for op_index in 0 ..< int(op_count) {
		action, action_err := hgl.draw_i64(tc, 0, 2)
		if action_err == .Stop_Test do return hgl.abort()
		if action_err != nil do return hgl.interesting("draw watchdog action")
		slot, slot_err := hgl.draw_i64(tc, 0, i64(len(conns) - 1))
		if slot_err == .Stop_Test do return hgl.abort()
		if slot_err != nil do return hgl.interesting("draw watchdog slot")

		conn := conns[int(slot)]
		switch action {
		case 0:
			conn.is_sending = true
			conn.send_started_at = nrc_time_now_monotonic()
			send_watchdog_track(conn)
			tracked[int(slot)] = true
		case 1:
			send_watchdog_untrack(conn)
			conn.is_sending = false
			conn.send_started_at = {}
			tracked[int(slot)] = false
		case 2:
			check_stalled_sends(nrc_time_now_monotonic())
		}

		if !send_watchdog_test_invariants_hold(conns[:], tracked[:]) {
			hgl.note(tc, fmt.tprintf("watchdog op=%d action=%d slot=%d indexed=%d", op_index, action, slot, len(td.inflight_send_handles)))
			return hgl.interesting("send watchdog dense/reverse indexes diverged from model")
		}
	}

	return {}
}

@(test)
test_idle_scan_cursor_wraps_fixed_socket_table :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 125)
	defer worker_state_destroy_core_for_test()

	start := MAX_SOCK_FD - 3
	td.idle_scan_cursor = start
	check_idle_connections(nrc_time_now_monotonic())
	testing.expect_value(t, td.idle_scan_cursor, (start + Idle_Scan_Slots_Per_Tick) % MAX_SOCK_FD)
}
