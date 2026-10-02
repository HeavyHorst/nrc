//
// send_queue_test.odin - Tests for hybrid inline+spill send queue
//
package main

import "base:runtime"

import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:net"
import "core:testing"
import "core:time"

import "byte_pool"
import hgl "hegel"
import nbio "nbio/poly"
import pr "protocol"
import "ulid"

when !NRC_SIMULATION {
	_ :: hgl.run
	_ :: log.nil_logger
}

@(test)
test_deferred_outbox_drain_removes_bounded_fifo_batches :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 120)
	defer worker_state_destroy_core_for_test()

	testing.expect_value(t, queue.cap(td.deferred_outbox_handles), Deferred_Outbox_Max_Handles)

	queued_count := Deferred_Outbox_Publish_Batch * 2 + 1
	for i in 0 ..< queued_count {
		handle := Connection_Handle {
			idx = u32(i + 1),
			gen = 1,
		}
		if ok, _ := queue.push_back(&td.deferred_outbox_handles, handle); !ok {
			testing.expect(t, false, "failed to grow deferred outbox queue")
			return
		}
	}

	testing.expect_value(t, deferred_outbox_pump_count(), queued_count)
	testing.expect_value(t, drain_deferred_outbox_pumps(), true)
	testing.expect_value(t, deferred_outbox_pump_count(), Deferred_Outbox_Publish_Batch + 1)
	testing.expect_value(t, drain_deferred_outbox_pumps(), true)
	testing.expect_value(t, deferred_outbox_pump_count(), 1)
	testing.expect_value(t, drain_deferred_outbox_pumps(), true)
	testing.expect_value(t, deferred_outbox_pump_count(), 0)
	testing.expect_value(t, drain_deferred_outbox_pumps(), false)
}

@(test)
test_deferred_outbox_stale_handle_does_not_target_reused_socket :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 126)
	defer worker_state_destroy_core_for_test()

	sock := connection_test_fake_socket(930)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Active})
	testing.expect(t, old_conn != nil, "expected old deferred-outbox connection")
	if old_conn == nil do return
	old_handle := old_conn.handle
	old_conn.outbox_pump_deferred = true
	if ok, _ := queue.push_back(&td.deferred_outbox_handles, old_handle); !ok {
		testing.expect(t, false, "expected deferred handle enqueue")
		connection_test_uninstall(old_conn)
		return
	}

	connection_test_uninstall(old_conn)
	replacement := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Active})
	testing.expect(t, replacement != nil, "expected replacement deferred-outbox connection")
	if replacement == nil {
		discard_deferred_outbox_pumps()
		return
	}
	defer connection_test_uninstall(replacement)

	testing.expect(t, replacement.handle != old_handle, "replacement must have a new generation")
	testing.expect(t, !replacement.outbox_pump_deferred, "replacement must not inherit deferred state")
	testing.expect_value(t, drain_deferred_outbox_pumps(), true)
	testing.expect_value(t, deferred_outbox_pump_count(), 0)
	testing.expect(t, connection_get(sock) == replacement, "stale deferred handle must not target replacement")
	testing.expect(t, !replacement.outbox_pump_deferred, "stale deferred handle must not mutate replacement")
}

@(test)
test_deferred_outbox_full_queue_compacts_stale_generations :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 127)
	defer worker_state_destroy_core_for_test()

	sock := connection_test_fake_socket(931)
	old_conn := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Active})
	testing.expect(t, old_conn != nil, "expected old capacity-test connection")
	if old_conn == nil do return
	old_handle := old_conn.handle
	old_conn.outbox_pump_deferred = true
	if ok, _ := queue.push_back(&td.deferred_outbox_handles, old_handle); !ok {
		testing.expect(t, false, "expected old generation enqueue")
		connection_test_uninstall(old_conn)
		return
	}
	connection_test_uninstall(old_conn)

	for i in 1 ..< Deferred_Outbox_Max_Handles {
		stale := Connection_Handle {
			idx = u32(i + 10_000),
			gen = 777,
		}
		if ok, _ := queue.push_back(&td.deferred_outbox_handles, stale); !ok {
			testing.expect(t, false, "expected stale capacity filler enqueue")
			discard_deferred_outbox_pumps()
			return
		}
	}
	testing.expect_value(t, deferred_outbox_pump_count(), Deferred_Outbox_Max_Handles)

	replacement := connection_test_install_fake(Fake_Connection_Options{sock = sock, state = .Active})
	testing.expect(t, replacement != nil, "expected replacement capacity-test connection")
	if replacement == nil {
		discard_deferred_outbox_pumps()
		return
	}
	defer connection_test_uninstall(replacement)

	deferred_outbox_enqueue(replacement)
	testing.expect(t, replacement.handle != old_handle, "replacement must use a new generation")
	testing.expect(t, replacement.outbox_pump_deferred, "replacement should own the surviving deferred entry")
	testing.expect_value(t, deferred_outbox_pump_count(), 1)
	testing.expect_value(t, drain_deferred_outbox_pumps(), true)
	testing.expect(t, !replacement.outbox_pump_deferred, "drain should clear replacement deferred state")
}

Fast_Ack_Test_Accept_Context :: struct {
	accepted: bool,
	failed:   bool,
	sock:     net.TCP_Socket,
}

fast_ack_test_on_accept :: proc(ctx: ^Fast_Ack_Test_Accept_Context, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted = true
	ctx.sock = client
}

Fast_Ack_Test_Send_Context :: struct {
	callback_count: int,
	failed:         bool,
}

fast_ack_test_on_sent :: proc(_: ^NRC_Connection, ctx: rawptr, _: int, err: net.Network_Error) {
	send_ctx := cast(^Fast_Ack_Test_Send_Context)ctx
	send_ctx.callback_count += 1
	if err != nil {
		send_ctx.failed = true
	}
}

fast_ack_test_accept_loopback_pair :: proc(t: ^testing.T, io: ^nbio.IO) -> (listen_sock, client_sock, accepted_sock: net.TCP_Socket, ok: bool) {
	listen_err: net.Network_Error
	listen_sock, listen_err = nbio.open_and_listen_tcp(io, {net.IP4_Loopback, 0})
	if listen_err != nil {
		testing.expect(t, false, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
		return
	}

	server_ep, ep_err := net.bound_endpoint(listen_sock)
	if ep_err != nil {
		testing.expect(t, false, fmt.tprintf("net.bound_endpoint error: %v", ep_err))
		net.close(listen_sock)
		return
	}

	accept_ctx: Fast_Ack_Test_Accept_Context
	nbio.accept(io, listen_sock, &accept_ctx, fast_ack_test_on_accept)

	dial_err: net.Network_Error
	client_sock, dial_err = net.dial_tcp_from_endpoint(server_ep)
	if dial_err != nil {
		testing.expect(t, false, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
		net.close(listen_sock)
		return
	}
	blocking_err := net.set_blocking(client_sock, false)
	if blocking_err != nil {
		testing.expect(t, false, fmt.tprintf("net.set_blocking(false) error: %v", blocking_err))
		net.close(client_sock)
		net.close(listen_sock)
		return
	}

	start := ulid.time_now()
	for !accept_ctx.accepted && !accept_ctx.failed && time.since(start) < time.Second {
		terr := nbio.tick(io, time.Millisecond * 2)
		testing.expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during accept: %v", terr))
	}

	if !accept_ctx.accepted || accept_ctx.failed {
		testing.expect(t, false, "loopback accept did not complete")
		net.close(client_sock)
		net.close(listen_sock)
		return
	}

	accepted_sock = accept_ctx.sock
	ok = true
	return
}

fast_ack_test_recv_until :: proc(t: ^testing.T, client_sock: net.TCP_Socket, buf: []byte, min_bytes: int, deadline: time.Duration, io: ^nbio.IO = nil) -> int {
	total := 0
	start := ulid.time_now()
	for total < min_bytes && time.since(start) < deadline {
		if io != nil {
			terr := nbio.tick(io, time.Millisecond)
			testing.expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while receiving: %v", terr))
		}

		n_recv, recv_err := net.recv_tcp(client_sock, buf[total:])
		if recv_err == nil {
			total += n_recv
			continue
		}

		#partial switch recv_err {
		case .Would_Block:
			time.sleep(time.Millisecond)
		case .Connection_Closed:
			testing.expect(t, false, "connection closed before expected bytes were received")
			return total
		case:
			testing.expect(t, false, fmt.tprintf("unexpected net.recv_tcp error: %v", recv_err))
			return total
		}
	}

	return total
}

// Helper to create a test Send_Item with a unique identifier
// Uses ctx field to store the ID since it's a rawptr (8 bytes = int)
make_test_item :: proc(id: int) -> Send_Item {
	return Send_Item{observer = {ctx = rawptr(uintptr(id))}}
}

// Extract the ID from a test item
get_item_id :: proc(item: Send_Item) -> int {
	return int(uintptr(item.observer.ctx))
}

@(test)
test_send_queue_empty :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	testing.expect_value(t, send_queue_len(&c), 0)
	testing.expect(t, send_queue_peek(&c) == nil, "peek on empty queue should return nil")
}

@(test)
test_send_queue_single_item :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	item := make_test_item(42)
	send_queue_push(&c, item)

	testing.expect_value(t, send_queue_len(&c), 1)
	testing.expect_value(t, c.inline_len, 1)

	// Peek should return the item
	peeked := send_queue_peek(&c)
	testing.expect(t, peeked != nil, "peek should return item")
	testing.expect_value(t, get_item_id(peeked^), 42)

	// Pop should return the item
	popped := send_queue_pop(&c)
	testing.expect_value(t, get_item_id(popped), 42)
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_fill_inline :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Fill exactly Inline_Queue_Size items
	for i in 0 ..< int(Inline_Queue_Size) {
		send_queue_push(&c, make_test_item(i))
	}

	testing.expect_value(t, send_queue_len(&c), int(Inline_Queue_Size))
	testing.expect_value(t, c.inline_len, Inline_Queue_Size)

	// Verify FIFO order
	for i in 0 ..< int(Inline_Queue_Size) {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}

	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_spill_to_heap :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Push more than inline capacity
	total_items := int(Inline_Queue_Size) + 5

	for i in 0 ..< total_items {
		send_queue_push(&c, make_test_item(i))
	}

	testing.expect_value(t, send_queue_len(&c), total_items)
	testing.expect_value(t, c.inline_len, Inline_Queue_Size) // Inline should be full

	// Verify FIFO order across inline and spill
	for i in 0 ..< total_items {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}

	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_refill_from_spill :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Push 2x inline capacity (inline full + same amount in spill)
	total_items := int(Inline_Queue_Size) * 2
	for i in 0 ..< total_items {
		send_queue_push(&c, make_test_item(i))
	}

	testing.expect_value(t, c.inline_len, Inline_Queue_Size)

	// Pop all initial inline items
	for i in 0 ..< int(Inline_Queue_Size) {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}

	// After popping all inline, refill should have happened
	// Inline should now contain the first spill block
	testing.expect_value(t, c.inline_len, Inline_Queue_Size)
	testing.expect_value(t, c.inline_head, 0) // Reset to 0 after refill

	// Verify remaining items are correct
	for i in int(Inline_Queue_Size) ..< total_items {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}

	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_partial_refill :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Push inline capacity + a small spill tail
	spill_items :: 3
	total_items := int(Inline_Queue_Size) + spill_items
	for i in 0 ..< total_items {
		send_queue_push(&c, make_test_item(i))
	}

	// Pop all initial inline items
	for i in 0 ..< int(Inline_Queue_Size) {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}

	// After refill, inline should have only spill_items remaining
	testing.expect_value(t, c.inline_len, spill_items)
	testing.expect_value(t, send_queue_len(&c), spill_items)

	// Verify remaining items
	for i in int(Inline_Queue_Size) ..< total_items {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}

	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_wrap_around :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Push and pop to advance head
	for i in 0 ..< 5 {
		send_queue_push(&c, make_test_item(i))
	}
	for _ in 0 ..< 5 {
		send_queue_pop(&c)
	}

	// Now head should be at position 5
	testing.expect_value(t, c.inline_head, 5)
	testing.expect_value(t, c.inline_len, 0)

	// Push inline capacity items - should wrap around
	for offset in 0 ..< int(Inline_Queue_Size) {
		i := 100 + offset
		send_queue_push(&c, make_test_item(i))
	}

	testing.expect_value(t, c.inline_len, Inline_Queue_Size)

	// Verify FIFO order
	for offset in 0 ..< int(Inline_Queue_Size) {
		i := 100 + offset
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}
}

@(test)
test_send_queue_peek_inline :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	send_queue_push(&c, make_test_item(1))
	send_queue_push(&c, make_test_item(2))

	// Peek should return first item without removing
	peeked := send_queue_peek(&c)
	testing.expect(t, peeked != nil, "peek should return item")
	testing.expect_value(t, get_item_id(peeked^), 1)
	testing.expect_value(t, send_queue_len(&c), 2) // Length unchanged

	// Pop and verify
	popped := send_queue_pop(&c)
	testing.expect_value(t, get_item_id(popped), 1)

	// Peek should now return second item
	peeked = send_queue_peek(&c)
	testing.expect_value(t, get_item_id(peeked^), 2)
}

@(test)
test_send_queue_peek_spill :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Fill inline
	for i in 0 ..< int(Inline_Queue_Size) {
		send_queue_push(&c, make_test_item(i))
	}

	// Pop all inline
	for _ in 0 ..< int(Inline_Queue_Size) {
		send_queue_pop(&c)
	}

	// Now add items to spill (inline is empty, no refill triggered yet)
	// Actually after popping all, if spill was empty, we just have empty queue
	// Let's test differently: push to spill first, then peek after inline empty

	// Reset
	send_queue_destroy(&c)
	send_queue_init(&c)

	// Push inline capacity + 2 spill items
	total_items := int(Inline_Queue_Size) + 2
	for i in 0 ..< total_items {
		send_queue_push(&c, make_test_item(i))
	}

	// Pop inline items, triggering refill from spill
	for _ in 0 ..< int(Inline_Queue_Size) {
		send_queue_pop(&c)
	}

	// Now peek should return first spill item
	peeked := send_queue_peek(&c)
	testing.expect(t, peeked != nil, "peek should return item")
	testing.expect_value(t, get_item_id(peeked^), int(Inline_Queue_Size))
}

@(test)
test_send_queue_large_spill :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Push many items to stress spill queue
	total := 100

	for i in 0 ..< total {
		send_queue_push(&c, make_test_item(i))
	}

	testing.expect_value(t, send_queue_len(&c), total)

	// Verify all items in FIFO order
	for i in 0 ..< total {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), i)
	}

	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_interleaved_push_pop :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	// Interleave pushes and pops
	next_push := 0
	next_pop := 0

	// Push 3, pop 1, push 3, pop 1, etc.
	for _ in 0 ..< 10 {
		for _ in 0 ..< 3 {
			send_queue_push(&c, make_test_item(next_push))
			next_push += 1
		}
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), next_pop)
		next_pop += 1
	}

	// Drain remaining
	remaining := send_queue_len(&c)
	testing.expect_value(t, remaining, 20) // 30 pushed, 10 popped

	for _ in 0 ..< remaining {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), next_pop)
		next_pop += 1
	}
}

@(test)
test_send_queue_priority_before_normal :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	send_queue_push(&c, make_test_item(1))
	send_queue_push(&c, make_test_item(2))
	send_queue_push_priority(&c, make_test_item(100))
	send_queue_push_priority(&c, make_test_item(101))
	send_queue_push(&c, make_test_item(3))

	testing.expect_value(t, send_queue_len(&c), 5)
	testing.expect_value(t, send_queue_priority_len(&c), 2)
	testing.expect_value(t, send_queue_normal_len(&c), 3)

	peeked := send_queue_peek(&c)
	testing.expect(t, peeked != nil, "priority item should be visible at queue front")
	testing.expect_value(t, get_item_id(peeked^), 100)

	expected := [?]int{100, 101, 1, 2, 3}
	for want in expected {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), want)
	}

	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_normal_pop_ignores_priority :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	send_queue_push(&c, make_test_item(1))
	send_queue_push(&c, make_test_item(2))
	send_queue_push_priority(&c, make_test_item(100))

	normal := send_queue_pop_normal(&c)
	testing.expect_value(t, get_item_id(normal), 1)
	testing.expect_value(t, send_queue_priority_len(&c), 1)
	testing.expect_value(t, send_queue_normal_len(&c), 1)

	priority := send_queue_pop_priority(&c)
	testing.expect_value(t, get_item_id(priority), 100)

	last := send_queue_pop(&c)
	testing.expect_value(t, get_item_id(last), 2)
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_send_queue_priority_depth_counters_track_total :: proc(t: ^testing.T) {
	c: NRC_Connection
	send_queue_init(&c)
	defer send_queue_destroy(&c)

	send_queue_push(&c, make_test_item(1))
	testing.expect_value(t, send_queue_len(&c), 1)
	testing.expect_value(t, send_queue_normal_len(&c), 1)
	testing.expect_value(t, send_queue_priority_len(&c), 0)

	send_queue_push(&c, make_test_item(2))
	send_queue_push_priority(&c, make_test_item(100))
	send_queue_push(&c, make_test_item(3))
	testing.expect_value(t, send_queue_len(&c), 4)
	testing.expect_value(t, send_queue_normal_len(&c), 3)
	testing.expect_value(t, send_queue_priority_len(&c), 1)

	priority := send_queue_pop(&c)
	testing.expect_value(t, get_item_id(priority), 100)
	testing.expect_value(t, send_queue_len(&c), 3)
	testing.expect_value(t, send_queue_normal_len(&c), 3)
	testing.expect_value(t, send_queue_priority_len(&c), 0)

	expected := [?]int{1, 2, 3}
	for want in expected {
		item := send_queue_pop(&c)
		testing.expect_value(t, get_item_id(item), want)
	}
	testing.expect_value(t, send_queue_len(&c), 0)
	testing.expect_value(t, send_queue_normal_len(&c), 0)
	testing.expect_value(t, send_queue_priority_len(&c), 0)
}

@(test)
test_send_queue_destroy_releases_queued_pooled_buffers :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 95)
	defer worker_state_destroy_core_for_test()

	base_pool_used := td.spool.used
	conn := connection_test_install_fake(Fake_Connection_Options{sock = net.TCP_Socket(492_001), state = .Idle, init_send_queue = true})
	testing.expect(t, conn != nil, "expected fake connection")
	if conn == nil {
		return
	}
	defer connection_test_uninstall(conn)

	normal_buf, normal_err := byte_pool.alloc(td.spool, 64)
	testing.expect(t, normal_err == runtime.Allocator_Error.None, "expected normal pooled buffer allocation")
	if normal_err != runtime.Allocator_Error.None {
		return
	}
	priority_buf, priority_err := byte_pool.alloc(td.spool, 64)
	testing.expect(t, priority_err == runtime.Allocator_Error.None, "expected priority pooled buffer allocation")
	if priority_err != runtime.Allocator_Error.None {
		byte_pool.release(td.spool, normal_buf)
		return
	}
	testing.expect(t, td.spool.used > base_pool_used, "queued pooled buffers should increase pool usage")

	send_queue_push(conn, Send_Item{lease = Frame_Lease(Pooled_Frame_Lease{data = normal_buf, pool = td.spool}), handle = conn.handle})
	send_queue_push_priority(conn, Send_Item{lease = Frame_Lease(Pooled_Frame_Lease{data = priority_buf, pool = td.spool}), handle = conn.handle})
	testing.expect_value(t, send_queue_len(conn), 2)
	testing.expect_value(t, send_queue_normal_len(conn), 1)
	testing.expect_value(t, send_queue_priority_len(conn), 1)

	send_queue_destroy(conn)
	testing.expect_value(t, send_queue_len(conn), 0)
	testing.expect_value(t, td.spool.used, base_pool_used)
	// This test consumed the queue storage; uninstall still owns the connection.
	conn.priority_queue = {}
	conn.spill_queue = {}
}

@(test)
test_send_queue_destroy_releases_queued_shared_broadcast_refs :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 96)
	defer worker_state_destroy_core_for_test()

	base_pool_used := td.spool.used
	conn := connection_test_install_fake(Fake_Connection_Options{sock = net.TCP_Socket(492_017), state = .Idle, init_send_queue = true})
	testing.expect(t, conn != nil, "expected fake connection")
	if conn == nil {
		return
	}
	defer connection_test_uninstall(conn)

	shared := subscriber_test_make_pooled_shared_buffer(td.spool, 2)
	testing.expect(t, shared != nil, "expected shared broadcast buffer allocation")
	if shared == nil {
		return
	}
	testing.expect(t, td.spool.used > base_pool_used, "queued shared buffer should increase pool usage")

	send_queue_push(conn, Send_Item{lease = Frame_Lease(Shared_Frame_Lease{buffer = shared}), handle = conn.handle})
	send_queue_push_priority(conn, Send_Item{lease = Frame_Lease(Shared_Frame_Lease{buffer = shared}), handle = conn.handle})
	testing.expect_value(t, send_queue_len(conn), 2)
	testing.expect_value(t, send_queue_normal_len(conn), 1)
	testing.expect_value(t, send_queue_priority_len(conn), 1)

	send_queue_destroy(conn)
	testing.expect_value(t, send_queue_len(conn), 0)
	testing.expect_value(t, td.spool.used, base_pool_used)
	conn.priority_queue = {}
	conn.spill_queue = {}
}

@(test)
test_simulation_process_send_queue_batch_path_captures_writev_and_releases_buffers :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		worker_state_init_core(nil, 108)
		defer worker_state_destroy_core_for_test()

		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)

		defer {
			connection_completion_test_reset()
		}

		sock := connection_test_fake_socket(310)
		nrc_sim_register_client(&sim, sock)
		conn := connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "batch-live", init_send_queue = true, track_active_socket = true},
		)
		testing.expect(t, conn != nil, "expected simulated batch connection")
		if conn == nil {
			return
		}
		defer connection_test_uninstall(conn)

		connection_completion_test_reset()
		connection_completion_expected_handle = conn.handle

		allocs_before := td.spool.allocation_count
		releases_before := td.spool.release_count
		batch_releases_before := td.batch_state_pool.pooled_releases
		for i in 0 ..< Batch_Queue_Threshold {
			buf, buf_err := byte_pool.alloc(td.spool, uint(32 + i))
			testing.expect(t, buf_err == .None, "expected pooled send buffer")
			if buf_err != .None {
				return
			}
			buf[0] = byte('A' + i)
			send_queue_push(
				conn,
				Send_Item {
					lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
					handle = conn.handle,
					observer = {callback = connection_lifetime_tracking_ack_sent},
				},
			)
		}

		pump_outbox(conn)
		nrc_sim_run_all_send_completions(&sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&sim, sock), Batch_Queue_Threshold)
		previous_received_at: time.Time
		for i in 0 ..< Batch_Queue_Threshold {
			frame := nrc_sim_client_frame(&sim, sock, i)
			testing.expect_value(t, len(frame), 32 + i)
			if len(frame) > 0 {
				testing.expect_value(t, frame[0], byte('A' + i))
			}
			received_at, received_at_ok := nrc_sim_client_frame_submitted_at(&sim, sock, i)
			testing.expect(t, received_at_ok, "captured frame should have a submission timestamp")
			if i > 0 do testing.expect(t, time.diff(previous_received_at, received_at) >= 0, "frame submission timestamps should be ordered")
			previous_received_at = received_at
		}
		testing.expect_value(t, connection_completion_callback_count, Batch_Queue_Threshold)
		testing.expect_value(t, connection_completion_nil_count, 0)
		testing.expect_value(t, connection_completion_unexpected_target_count, 0)
		testing.expect_value(t, send_queue_len(conn), 0)
		testing.expect(t, !conn.is_sending, "batch completion should resume and clear send state")
		testing.expect_value(t, td.spool.allocation_count, allocs_before + u64(Batch_Queue_Threshold))
		testing.expect_value(t, td.spool.release_count, releases_before + u64(Batch_Queue_Threshold))
		testing.expect_value(t, td.batch_state_pool.pooled_releases, batch_releases_before + 1)
		testing.expect(t, connection_lifetime_pool_drained(td.spool), "pooled batch send buffers should drain")
		nrc_sim_clear_inboxes(&sim)
		_, cleared_timestamp_found := nrc_sim_client_frame_submitted_at(&sim, sock, 0)
		testing.expect(t, !cleared_timestamp_found, "clearing captured frames should clear submission timestamps")

		queued_buf, queued_buf_err := byte_pool.alloc(td.spool, 32)
		testing.expect(t, queued_buf_err == .None, "expected queued-send timestamp buffer")
		if queued_buf_err != .None do return
		testing.expect(t, send_pooled_buffer(conn, queued_buf), "queued send should be captured")
		nrc_sim_run_all_send_completions(&sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&sim, sock), 1)
		_, queued_received_at_ok := nrc_sim_client_frame_submitted_at(&sim, sock, 0)
		testing.expect(t, queued_received_at_ok, "queued send should have a submission timestamp")
		testing.expect(t, connection_lifetime_pool_drained(td.spool), "queued send timestamp buffer should drain")
	}
}

@(test)
test_simulation_process_send_queue_stale_writev_completion_ignores_reused_socket :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		worker_state_init_core(nil, 109)
		defer worker_state_destroy_core_for_test()

		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)

		connection_completion_test_reset()
		defer {
			connection_completion_test_reset()
		}

		sock := connection_test_fake_socket(311)
		nrc_sim_register_client(&sim, sock)
		old_conn := connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true, track_active_socket = true},
		)
		testing.expect(t, old_conn != nil, "expected old simulated batch connection")
		if old_conn == nil {
			return
		}

		old_handle := old_conn.handle
		allocs_before := td.spool.allocation_count
		releases_before := td.spool.release_count
		batch_releases_before := td.batch_state_pool.pooled_releases
		for i in 0 ..< Batch_Queue_Threshold {
			buf, buf_err := byte_pool.alloc(td.spool, uint(40 + i))
			testing.expect(t, buf_err == .None, "expected stale pooled send buffer")
			if buf_err != .None {
				connection_test_uninstall(old_conn)
				return
			}
			buf[0] = byte('a' + i)
			send_queue_push(
				old_conn,
				Send_Item {
					lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
					handle = old_handle,
					observer = {callback = connection_lifetime_tracking_ack_sent},
				},
			)
		}

		partial_sent := 43 // Cross the 40-byte first iovec and enter the second.
		nrc_sim_inject_next_writev_partial(&sim, partial_sent)
		pump_outbox(old_conn)
		testing.expect_value(t, nrc_sim_send_completion_count(&sim), 1)
		progress, progress_ok := nrc_sim_send_completion_at(&sim, 0)
		testing.expect(t, progress_ok && progress.kind == .Writev && progress.continues, "expected partial writev progress event")
		if progress_ok {
			testing.expect_value(t, progress.sent, partial_sent)
			testing.expect_value(t, progress.final_sent, 81)
		}
		started_at := old_conn.send_started_at
		watchdog_slot := old_conn.send_watchdog_slot
		testing.expect(t, nrc_sim_run_next_send_completion(&sim), "partial writev progress should run")
		testing.expect_value(t, nrc_sim_send_completion_count(&sim), 1)
		terminal, terminal_ok := nrc_sim_send_completion_at(&sim, 0)
		testing.expect(t, terminal_ok && terminal.kind == .Writev && !terminal.continues, "expected terminal writev continuation")
		if terminal_ok do testing.expect_value(t, terminal.sent, 81)
		testing.expect_value(t, connection_completion_callback_count, 0)
		testing.expect_value(t, old_conn.pending_io, u32(1))
		testing.expect(t, old_conn.is_sending, "partial writev should retain send ownership")
		testing.expect_value(t, old_conn.send_started_at, started_at)
		testing.expect_value(t, old_conn.send_watchdog_slot, watchdog_slot)
		testing.expect(t, watchdog_slot > 0 && td.inflight_send_handles[int(watchdog_slot - 1)] == old_handle, "partial writev should remain watchdog-indexed")
		testing.expect_value(t, nrc_sim_client_frame_count(&sim, sock), Batch_Queue_Threshold)
		for i in 0 ..< Batch_Queue_Threshold {
			frame := nrc_sim_client_frame(&sim, sock, i)
			testing.expect_value(t, len(frame), 40 + i)
			if len(frame) > 0 {
				testing.expect_value(t, frame[0], byte('a' + i))
			}
		}
		testing.expect_value(t, td.spool.release_count, releases_before)

		connection_test_uninstall(old_conn)
		nrc_sim_register_client(&sim, sock)
		new_conn := connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true, track_active_socket = true},
		)
		testing.expect(t, new_conn != nil, "expected reused simulated batch connection")
		if new_conn == nil {
			nrc_sim_run_all_send_completions(&sim)
			return
		}
		defer connection_test_uninstall(new_conn)
		testing.expect_value(t, nrc_sim_client_frame_count(&sim, sock), 0)

		connection_completion_test_reset()
		connection_completion_expected_handle = old_handle
		nrc_sim_run_all_send_completions(&sim)
		connection_completion_expected_handle = {}

		testing.expect_value(t, connection_completion_callback_count, Batch_Queue_Threshold)
		testing.expect_value(t, connection_completion_nil_count, 0)
		testing.expect_value(t, connection_completion_new_conn_count, 0)
		testing.expect_value(t, connection_completion_unexpected_target_count, 0)
		testing.expect(t, connection_lifetime_assert_reused_socket_intact(sock, new_conn), "stale simulated writev completion must not target reused socket")
		testing.expect_value(t, nrc_sim_client_frame_count(&sim, sock), 0)
		testing.expect_value(t, td.spool.allocation_count, allocs_before + u64(Batch_Queue_Threshold))
		testing.expect_value(t, td.spool.release_count, releases_before + u64(Batch_Queue_Threshold))
		testing.expect_value(t, td.batch_state_pool.pooled_releases, batch_releases_before + 1)
		testing.expect(t, connection_lifetime_pool_drained(td.spool), "stale simulated writev buffers should drain")
	}
}

@(test)
test_hegel_generated_process_send_queue_batch_lifetime_orderings :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_generated_process_send_queue_batch_lifetime_orderings, nil, {test_cases = 120})
		testing.expectf(t, err == nil, "hegel process_send_queue batch lifetime property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_process_send_queue_error_lifetimes :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_generated_process_send_queue_error_lifetimes, nil, {test_cases = 120})
		testing.expectf(t, err == nil, "hegel process_send_queue error lifetime property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

when NRC_SIMULATION {
	Send_Queue_Generated_Error_Path :: enum {
		Single_Priority,
		Batch_Priority,
		Batch_Normal,
	}

	send_queue_generated_frame_len :: proc(prefix: byte, index: int) -> int {
		if prefix == byte('P') {
			return 30 + index
		}
		return 50 + index
	}

	send_queue_generated_push_buffer :: proc(conn: ^NRC_Connection, prefix: byte, index: int, priority: bool) -> bool {
		buf_len := send_queue_generated_frame_len(prefix, index)
		buf, buf_err := byte_pool.alloc(td.spool, uint(buf_len))
		if buf_err != .None {
			return false
		}
		buf[0] = prefix
		if len(buf) > 1 {
			buf[1] = byte(index)
		}

		item := Send_Item {
			lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			handle = conn.handle,
			observer = Send_Completion_Observer{callback = connection_lifetime_tracking_ack_sent},
		}
		if priority {
			send_queue_push_priority(conn, item)
		} else {
			send_queue_push(conn, item)
		}
		return true
	}

	send_queue_generated_error_for_index :: proc(index: i64) -> net.Network_Error {
		switch index % 3 {
		case 0:
			return net.TCP_Send_Error(.Timeout)
		case 1:
			return net.TCP_Send_Error(.Connection_Closed)
		case:
			return net.TCP_Send_Error(.Not_Connected)
		}
	}

	send_queue_generated_frame_matches :: proc(frame: []u8, prefix: byte, index: int) -> bool {
		if len(frame) != send_queue_generated_frame_len(prefix, index) {
			return false
		}
		if len(frame) == 0 || frame[0] != prefix {
			return false
		}
		if len(frame) > 1 && frame[1] != byte(index) {
			return false
		}
		return true
	}

	send_queue_generated_frames_match_model :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, priority_count, normal_count, expected_count: int) -> bool {
		frame_index := 0
		for i in 0 ..< priority_count {
			if frame_index >= expected_count {
				return true
			}
			if !send_queue_generated_frame_matches(nrc_sim_client_frame(sim, sock, frame_index), byte('P'), i) {
				return false
			}
			frame_index += 1
		}
		for i in 0 ..< normal_count {
			if frame_index >= expected_count {
				return true
			}
			if !send_queue_generated_frame_matches(nrc_sim_client_frame(sim, sock, frame_index), byte('N'), i) {
				return false
			}
			frame_index += 1
		}
		return frame_index == expected_count
	}

	send_queue_generated_flush_all_batches :: proc(sim: ^Sim_Runtime) -> bool {
		nrc_sim_run_all_send_completions(sim)
		return nrc_sim_send_completion_count(sim) == 0
	}

	prop_generated_process_send_queue_batch_lifetime_orderings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		worker_state_init_core(nil, 110)
		defer worker_state_destroy_core_for_test()

		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)

		current_conn: ^NRC_Connection
		new_conn: ^NRC_Connection
		defer {
			_ = send_queue_generated_flush_all_batches(&sim)
			if current_conn != nil {
				connection_test_uninstall(current_conn)
				current_conn = nil
			}
			if new_conn != nil {
				connection_test_uninstall(new_conn)
				new_conn = nil
			}
			connection_completion_test_reset()
		}

		priority_raw, priority_err := hgl.draw_i64(tc, 0, 8)
		if priority_err == .Stop_Test do return hgl.abort()
		if priority_err != nil do return hgl.interesting("draw generated send queue priority count")

		normal_raw, normal_err := hgl.draw_i64(tc, 0, 8)
		if normal_err == .Stop_Test do return hgl.abort()
		if normal_err != nil do return hgl.interesting("draw generated send queue normal count")

		stale_raw, stale_err := hgl.draw_i64(tc, 0, 1)
		if stale_err == .Stop_Test do return hgl.abort()
		if stale_err != nil do return hgl.interesting("draw generated send queue stale-before-flush switch")

		priority_count := int(priority_raw)
		normal_count := int(normal_raw)
		if priority_count < Batch_Queue_Threshold && normal_count < Batch_Queue_Threshold {
			normal_count = Batch_Queue_Threshold
		}
		total_count := priority_count + normal_count

		sock := connection_test_fake_socket(320)
		nrc_sim_register_client(&sim, sock)
		current_conn = connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true, track_active_socket = true},
		)
		if current_conn == nil {
			return hgl.interesting("generated send queue connection install failed")
		}
		old_handle := current_conn.handle
		connection_completion_test_reset()
		connection_completion_expected_handle = old_handle

		allocs_before := td.spool.allocation_count
		releases_before := td.spool.release_count
		batch_releases_before := td.batch_state_pool.pooled_releases
		for i in 0 ..< normal_count {
			if !send_queue_generated_push_buffer(current_conn, byte('N'), i, false) {
				return hgl.interesting("generated send queue normal buffer allocation failed")
			}
		}
		for i in 0 ..< priority_count {
			if !send_queue_generated_push_buffer(current_conn, byte('P'), i, true) {
				return hgl.interesting("generated send queue priority buffer allocation failed")
			}
		}

		pump_outbox(current_conn)
		captured_after_submit := nrc_sim_client_frame_count(&sim, sock)
		if !send_queue_generated_frames_match_model(&sim, sock, priority_count, normal_count, captured_after_submit) {
			hgl.note(
				tc,
				fmt.tprintf(
					"generated send queue captured prefix mismatch priority=%d normal=%d captured=%d",
					priority_count,
					normal_count,
					captured_after_submit,
				),
			)
			return hgl.interesting("generated process_send_queue captured frames out of model order")
		}

		pending_batch_count := 0
		if completion, ok := nrc_sim_send_completion_at(&sim, 0); ok {
			if completion.kind == .Writev && completion.batch_state != nil {
				pending_batch_count = completion.batch_state.count
			}
		}
		callbacks_before_stale := connection_completion_callback_count
		stale_before_flush := stale_raw != 0 && pending_batch_count > 0

		if stale_before_flush {
			queued_leftover_count := total_count - captured_after_submit
			if queued_leftover_count < 0 {
				queued_leftover_count = 0
			}
			connection_test_uninstall(current_conn)
			current_conn = nil

			new_conn = connection_test_install_fake(
				Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true, track_active_socket = true},
			)
			if new_conn == nil {
				return hgl.interesting("generated send queue reused connection install failed")
			}

			if !send_queue_generated_flush_all_batches(&sim) {
				return hgl.interesting("generated stale send queue batch did not flush")
			}
			// Queue destruction consumes leftover leases without manufacturing
			// completion observations. The submitted batch owns a pending-I/O pin,
			// so its old generational connection remains valid through completion.
			expected_callbacks := pending_batch_count
			expected_nil_callbacks := 0
			if connection_completion_callback_count != callbacks_before_stale + expected_callbacks ||
			   connection_completion_nil_count != expected_nil_callbacks ||
			   connection_completion_new_conn_count != 0 ||
			   connection_completion_unexpected_target_count != 0 {
				hgl.note(
					tc,
					fmt.tprintf(
						"generated stale send queue callbacks priority=%d normal=%d captured=%d before=%d pending=%d leftover=%d callbacks=%d nil=%d new=%d unexpected=%d",
						priority_count,
						normal_count,
						captured_after_submit,
						callbacks_before_stale,
						pending_batch_count,
						queued_leftover_count,
						connection_completion_callback_count,
						connection_completion_nil_count,
						connection_completion_new_conn_count,
						connection_completion_unexpected_target_count,
					),
				)
				return hgl.interesting("generated stale process_send_queue completion targeted reused socket or lost callbacks")
			}
			if !connection_lifetime_assert_reused_socket_intact(sock, new_conn) {
				return hgl.interesting("generated stale process_send_queue reused socket was not intact")
			}
		} else {
			if !send_queue_generated_flush_all_batches(&sim) {
				return hgl.interesting("generated live send queue batches did not flush")
			}
			captured_final := nrc_sim_client_frame_count(&sim, sock)
			if captured_final != total_count || !send_queue_generated_frames_match_model(&sim, sock, priority_count, normal_count, captured_final) {
				hgl.note(
					tc,
					fmt.tprintf(
						"generated live send queue frames priority=%d normal=%d captured=%d total=%d",
						priority_count,
						normal_count,
						captured_final,
						total_count,
					),
				)
				return hgl.interesting("generated live process_send_queue did not capture all frames in order")
			}
			if connection_completion_callback_count != total_count ||
			   connection_completion_nil_count != 0 ||
			   connection_completion_new_conn_count != 0 ||
			   connection_completion_unexpected_target_count != 0 {
				return hgl.interesting("generated live process_send_queue callbacks violated target invariants")
			}
			if send_queue_len(current_conn) != 0 || current_conn.is_sending {
				return hgl.interesting("generated live process_send_queue left queue wedged")
			}
		}

		if td.spool.allocation_count != allocs_before + u64(total_count) ||
		   td.spool.release_count != releases_before + u64(total_count) ||
		   !connection_lifetime_pool_drained(td.spool) {
			hgl.note(
				tc,
				fmt.tprintf(
					"generated send queue pool priority=%d normal=%d allocs=%d/%d releases=%d/%d used=%d",
					priority_count,
					normal_count,
					td.spool.allocation_count,
					allocs_before + u64(total_count),
					td.spool.release_count,
					releases_before + u64(total_count),
					td.spool.used,
				),
			)
			return hgl.interesting("generated process_send_queue pooled buffers were not released exactly once")
		}
		if td.batch_state_pool.pooled_releases <= batch_releases_before {
			return hgl.interesting("generated process_send_queue did not release a batch state")
		}

		return {}
	}

	prop_generated_process_send_queue_error_lifetimes :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		previous_logger := context.logger
		context.logger = log.nil_logger()
		defer {
			context.logger = previous_logger
		}

		worker_state_init_core(nil, 111)
		defer worker_state_destroy_core_for_test()

		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)

		current_conn: ^NRC_Connection
		new_conn: ^NRC_Connection
		defer {
			_ = send_queue_generated_flush_all_batches(&sim)
			nrc_sim_run_all_timers(&sim)
			if current_conn != nil {
				connection_test_uninstall(current_conn)
				current_conn = nil
			}
			if new_conn != nil {
				connection_test_uninstall(new_conn)
				new_conn = nil
			}
			connection_completion_test_reset()
		}

		path_raw, path_err := hgl.draw_i64(tc, 0, i64(len(Send_Queue_Generated_Error_Path) - 1))
		if path_err == .Stop_Test do return hgl.abort()
		if path_err != nil do return hgl.interesting("draw generated send queue error path")

		normal_extra_raw, normal_extra_err := hgl.draw_i64(tc, 0, 4)
		if normal_extra_err == .Stop_Test do return hgl.abort()
		if normal_extra_err != nil do return hgl.interesting("draw generated send queue error normal leftovers")

		batch_extra_raw, batch_extra_err := hgl.draw_i64(tc, 0, 4)
		if batch_extra_err == .Stop_Test do return hgl.abort()
		if batch_extra_err != nil do return hgl.interesting("draw generated send queue error batch size")

		err_raw, err_draw_err := hgl.draw_i64(tc, 0, 2)
		if err_draw_err == .Stop_Test do return hgl.abort()
		if err_draw_err != nil do return hgl.interesting("draw generated send queue error kind")

		stale_raw, stale_err := hgl.draw_i64(tc, 0, 1)
		if stale_err == .Stop_Test do return hgl.abort()
		if stale_err != nil do return hgl.interesting("draw generated send queue error stale switch")

		path := Send_Queue_Generated_Error_Path(path_raw)
		priority_count := 0
		normal_count := 0
		selected_count := 0
		switch path {
		case .Single_Priority:
			priority_count = 1
			normal_count = int(normal_extra_raw)
			selected_count = priority_count
		case .Batch_Priority:
			priority_count = Batch_Queue_Threshold + int(batch_extra_raw)
			normal_count = int(normal_extra_raw)
			selected_count = priority_count
		case .Batch_Normal:
			priority_count = 0
			normal_count = Batch_Queue_Threshold + int(batch_extra_raw)
			selected_count = normal_count
		}
		total_count := priority_count + normal_count
		is_batch_path := selected_count >= Batch_Queue_Threshold
		submitted_count := selected_count
		if !is_batch_path {
			submitted_count = 1
		}
		queued_leftover_count := total_count - submitted_count

		sock := connection_test_fake_socket(321)
		nrc_sim_register_client(&sim, sock)
		current_conn = connection_test_install_fake(
			Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "old", init_send_queue = true, track_active_socket = true},
		)
		if current_conn == nil {
			return hgl.interesting("generated error send queue connection install failed")
		}
		old_handle := current_conn.handle
		connection_completion_test_reset()
		connection_completion_expected_handle = old_handle

		allocs_before := td.spool.allocation_count
		releases_before := td.spool.release_count
		batch_releases_before := td.batch_state_pool.pooled_releases
		for i in 0 ..< normal_count {
			if !send_queue_generated_push_buffer(current_conn, byte('N'), i, false) {
				return hgl.interesting("generated error send queue normal buffer allocation failed")
			}
		}
		for i in 0 ..< priority_count {
			if !send_queue_generated_push_buffer(current_conn, byte('P'), i, true) {
				return hgl.interesting("generated error send queue priority buffer allocation failed")
			}
		}

		injected_err := send_queue_generated_error_for_index(err_raw)
		if is_batch_path {
			partial_prefix := byte('N')
			if path == .Batch_Priority do partial_prefix = byte('P')
			partial_sent := send_queue_generated_frame_len(partial_prefix, 0) + 1
			nrc_sim_inject_next_writev_partial(&sim, partial_sent)
			nrc_sim_inject_next_writev_error(&sim, injected_err)
		} else {
			nrc_sim_inject_next_queued_send_error(&sim, injected_err)
		}

		pump_outbox(current_conn)

		pending_batch_count := 0
		if is_batch_path {
			pending_batch_count = submitted_count
			if nrc_sim_send_completion_count(&sim) != 1 || connection_completion_callback_count != 0 {
				hgl.note(
					tc,
					fmt.tprintf(
						"generated error batch was not pending before flush path=%v submitted=%d pending=%d batch_count=%d callbacks=%d",
						path,
						submitted_count,
						pending_batch_count,
						nrc_sim_send_completion_count(&sim),
						connection_completion_callback_count,
					),
				)
				return hgl.interesting("generated error writev completion was not deferred before flush")
			}
			if nrc_sim_client_frame_count(&sim, sock) != 0 {
				return hgl.interesting("generated error writev captured frames before failed completion")
			}
			progress, progress_ok := nrc_sim_send_completion_at(&sim, 0)
			if !progress_ok || !progress.continues || progress.sent <= 0 || progress.final_sent != progress.sent || progress.final_err == nil {
				return hgl.interesting("generated error writev missing partial progress")
			}
			started_at := current_conn.send_started_at
			watchdog_slot := current_conn.send_watchdog_slot
			if !nrc_sim_run_next_send_completion(&sim) ||
			   nrc_sim_send_completion_count(&sim) != 1 ||
			   connection_completion_callback_count != 0 ||
			   current_conn.pending_io != 1 ||
			   !current_conn.is_sending ||
			   current_conn.send_started_at != started_at ||
			   current_conn.send_watchdog_slot != watchdog_slot {
				return hgl.interesting("generated partial error writev released ownership before terminal completion")
			}
		}
		stale_before_flush := stale_raw != 0 && pending_batch_count > 0

		if stale_before_flush {
			connection_test_uninstall(current_conn)
			current_conn = nil

			new_conn = connection_test_install_fake(
				Fake_Connection_Options{sock = sock, state = .Idle, verified_username = "new", init_send_queue = true, track_active_socket = true},
			)
			if new_conn == nil {
				return hgl.interesting("generated error send queue reused connection install failed")
			}

			if !send_queue_generated_flush_all_batches(&sim) {
				return hgl.interesting("generated stale error send queue batch did not flush")
			}

			if connection_completion_callback_count != submitted_count ||
			   connection_completion_nil_count != 0 ||
			   connection_completion_new_conn_count != 0 ||
			   connection_completion_unexpected_target_count != 0 {
				hgl.note(
					tc,
					fmt.tprintf(
						"generated stale error queue path=%v priority=%d normal=%d submitted=%d pending=%d callbacks=%d nil=%d new=%d unexpected=%d err=%v",
						path,
						priority_count,
						normal_count,
						submitted_count,
						pending_batch_count,
						connection_completion_callback_count,
						connection_completion_nil_count,
						connection_completion_new_conn_count,
						connection_completion_unexpected_target_count,
						injected_err,
					),
				)
				return hgl.interesting("generated stale error process_send_queue completion targeted reused socket or lost callbacks")
			}
			if !connection_lifetime_assert_reused_socket_intact(sock, new_conn) {
				return hgl.interesting("generated stale error process_send_queue reused socket was not intact")
			}
		} else {
			if !send_queue_generated_flush_all_batches(&sim) {
				return hgl.interesting("generated live error send queue batches did not flush")
			}
			nrc_sim_run_all_timers(&sim)
			if current_conn != nil {
				send_queue_drain(current_conn)
			}

			if connection_completion_callback_count != submitted_count ||
			   connection_completion_nil_count != 0 ||
			   connection_completion_new_conn_count != 0 ||
			   connection_completion_unexpected_target_count != 0 {
				hgl.note(
					tc,
					fmt.tprintf(
						"generated live error queue path=%v priority=%d normal=%d submitted=%d leftover=%d callbacks=%d nil=%d new=%d unexpected=%d state=%v sending=%v err=%v",
						path,
						priority_count,
						normal_count,
						submitted_count,
						queued_leftover_count,
						connection_completion_callback_count,
						connection_completion_nil_count,
						connection_completion_new_conn_count,
						connection_completion_unexpected_target_count,
						current_conn.state,
						current_conn.is_sending,
						injected_err,
					),
				)
				return hgl.interesting("generated live error process_send_queue callbacks violated target invariants")
			}
		}

		if td.spool.allocation_count != allocs_before + u64(total_count) ||
		   td.spool.release_count != releases_before + u64(total_count) ||
		   !connection_lifetime_pool_drained(td.spool) {
			hgl.note(
				tc,
				fmt.tprintf(
					"generated error send queue pool path=%v priority=%d normal=%d allocs=%d/%d releases=%d/%d used=%d",
					path,
					priority_count,
					normal_count,
					td.spool.allocation_count,
					allocs_before + u64(total_count),
					td.spool.release_count,
					releases_before + u64(total_count),
					td.spool.used,
				),
			)
			return hgl.interesting("generated error process_send_queue pooled buffers were not released exactly once")
		}
		if is_batch_path {
			if td.batch_state_pool.pooled_releases != batch_releases_before + 1 {
				return hgl.interesting("generated error process_send_queue did not release exactly one batch state")
			}
		} else if td.batch_state_pool.pooled_releases != batch_releases_before {
			return hgl.interesting("generated error process_send_queue released unexpected batch state")
		}

		if current_conn != nil {
			connection_test_uninstall(current_conn)
			current_conn = nil
		}

		return {}
	}
}

@(test)
test_process_send_queue_sends_priority_before_normal :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer nbio.destroy(&td.io)
	init_batch_state_pool()
	defer destroy_batch_state_pool()

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)
	defer net.close(accepted_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "expected test connection allocation")
	send_queue_init(conn)
	defer {
		connection_test_uninstall(conn)
		connection_test_storage_destroy()
	}

	send_ctx: Fast_Ack_Test_Send_Context
	normal_a := [?]byte{'n', 'o', 'r', 'm', 'a', 'l', '-', 'a'}
	normal_b := [?]byte{'n', 'o', 'r', 'm', 'a', 'l', '-', 'b'}
	priority := [?]byte{'a', 'c', 'k', '-', 'p', 'r', 'i', 'o', 'r', 'i', 't', 'y'}

	send_queue_push(
		conn,
		Send_Item {
			lease = Frame_Lease(Connection_Stable_Frame_Lease{data = normal_a[:], owner = conn.handle}),
			handle = conn.handle,
			observer = {callback = fast_ack_test_on_sent, ctx = &send_ctx},
		},
	)
	send_queue_push(
		conn,
		Send_Item {
			lease = Frame_Lease(Connection_Stable_Frame_Lease{data = normal_b[:], owner = conn.handle}),
			handle = conn.handle,
			observer = {callback = fast_ack_test_on_sent, ctx = &send_ctx},
		},
	)
	send_queue_push_priority(
		conn,
		Send_Item {
			lease = Frame_Lease(Connection_Stable_Frame_Lease{data = priority[:], owner = conn.handle}),
			handle = conn.handle,
			observer = {callback = fast_ack_test_on_sent, ctx = &send_ctx},
		},
	)

	pump_outbox(conn)

	recv_buf: [128]byte
	n_recv := fast_ack_test_recv_until(t, client_sock, recv_buf[:], len(priority), time.Second, &td.io)
	testing.expect(t, n_recv >= len(priority), fmt.tprintf("expected at least priority frame bytes, got %d", n_recv))
	testing.expect(t, string(recv_buf[:len(priority)]) == string(priority[:]), "priority frame should be sent before queued normal frames")

	start := ulid.time_now()
	for send_ctx.callback_count < 3 && !send_ctx.failed && time.since(start) < time.Second {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while draining sends: %v", terr))
		_ = fast_ack_test_recv_until(t, client_sock, recv_buf[:], 1, time.Millisecond)
	}
	testing.expect(t, !send_ctx.failed, "send callback failed")
	testing.expect_value(t, send_ctx.callback_count, 3)
}

@(test)
test_send_ack_message_direct_submits_before_tick :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer nbio.destroy(&td.io)

	orig_spool := td.spool
	td.spool = byte_pool.init_buffer_pool()
	defer {
		byte_pool.destroy_buffer_pool(td.spool)
		td.spool = orig_spool
	}

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)
	defer net.close(accepted_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "expected test connection allocation")
	send_queue_init(conn)
	defer {
		connection_test_uninstall(conn)
		connection_test_storage_destroy()
	}

	ack := pr.AckSendMessage {
		client_req_id = 0xfeed_beef,
		assigned_seq  = 42,
		timestamp     = 123456789,
	}
	send_ack_message_direct(conn, ack)

	// Do not tick td.io here: this must arrive because send_ack_message_direct
	// submits pending SQEs immediately after preparing the ACK send.
	recv_buf: [64]byte
	n_recv := fast_ack_test_recv_until(t, client_sock, recv_buf[:], pr.getSizeAckSendMessage(ack) + 2, time.Millisecond * 250)
	testing.expect(t, n_recv >= pr.getSizeAckSendMessage(ack) + 2, fmt.tprintf("ACK was not readable before nbio.tick; received %d bytes", n_recv))

	testing.expect_value(t, recv_buf[0], byte(0x82))
	testing.expect_value(t, int(recv_buf[1] & 0x7f), pr.getSizeAckSendMessage(ack))
	opcode := u16(recv_buf[2]) << 8 | u16(recv_buf[3])
	testing.expect_value(t, opcode, u16(pr.Opcode.S_AckSendMessage))

	parsed, parse_err := pr.parseAckSendMessageMessage(recv_buf[2:n_recv])
	testing.expect(t, parse_err == nil, fmt.tprintf("parseAckSendMessageMessage error: %v", parse_err))
	testing.expect_value(t, parsed.client_req_id, ack.client_req_id)
	testing.expect_value(t, parsed.assigned_seq, ack.assigned_seq)
	testing.expect_value(t, parsed.timestamp, ack.timestamp)

	start := ulid.time_now()
	for conn.is_sending && time.since(start) < time.Second {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while draining ACK completion: %v", terr))
	}
	testing.expect(t, !conn.is_sending, "ACK send completion did not drain")
}
