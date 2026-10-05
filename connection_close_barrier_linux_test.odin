package main

import "core:c/libc"
import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:sys/linux"
import "core:testing"
import "core:time"

import "byte_pool"
import io_uring "nbio/_io_uring"
import nbio "nbio/poly"
import "ulid"
import tlsf "vendor/tlsf"

Connection_Close_Barrier_Kind :: enum {
	Send,
	Writev,
	Shutdown,
	Partial_Send,
	Partial_Writev,
}

Connection_Close_Barrier_Context :: struct {
	terminal_callbacks: int,
	io_ctx:             Connection_IO_Context,
}

connection_close_barrier_on_timeout :: proc(_: ^Connection_Close_Barrier_Context) {}

connection_close_barrier_on_sent :: proc(_: ^NRC_Connection, user: rawptr, _: int, _: net.Network_Error) {
	ctx := cast(^Connection_Close_Barrier_Context)user
	ctx.terminal_callbacks += 1
}

connection_close_barrier_on_shutdown :: proc(user: rawptr, _: net.Shutdown_Error) {
	ctx := cast(^Connection_Close_Barrier_Context)user
	ctx.terminal_callbacks += 1
	connection_io_unpin(ctx.io_ctx)
}

connection_close_barrier_run :: proc(t: ^testing.T, kind: Connection_Close_Barrier_Kind) {
	// Suite-wide policy matching server startup. Per-test signal restore would
	// race with concurrent tests; io_uring writes to shut-down sockets raise PIPE.
	libc.signal(13, transmute(proc "cdecl" (_: i32))uintptr(1))
	backing := context.allocator
	orig_backing := td.backing_allocator
	defer td.backing_allocator = orig_backing
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &backing, mem.Megabyte))
	defer tlsf.destroy(&heap)
	td.backing_allocator = backing
	context.allocator = worker_heap_allocator(&heap)
	ierr := nbio.init(&td.io, ring_entries = 8, alloc = backing)
	testing.expect(t, ierr == .NONE, fmt.tprintf("nbio.init small ring error: %v", ierr))
	if ierr != .NONE do return
	defer nbio.destroy(&td.io)
	init_batch_state_pool()
	defer destroy_batch_state_pool()

	orig_spool := td.spool
	td.spool = byte_pool.init_buffer_pool()
	defer {
		byte_pool.destroy_buffer_pool(td.spool)
		td.spool = orig_spool
	}
	defer connection_test_storage_destroy()

	listen_sock, peer_sock, server_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(peer_sock)

	// Prefer a range away from concurrent tests' low-FD traffic. Actual reuse
	// below must still atomically acquire a free FD, never overwrite an owner.
	high_fd, high_err := linux.fcntl_dupfd_cloexec(linux.Fd(server_sock), linux.F_DUPFD_CLOEXEC, linux.Fd(768 + int(kind) * 32))
	net.close(server_sock)
	if !testing.expect(t, high_err == .NONE, "reserve isolated descriptor for forced reuse") do return
	server_sock = net.TCP_Socket(high_fd)

	// Allocate the replacement before closing the original to keep its listener
	// and peer out of the descriptor slot we will try to reacquire.
	replacement_listener, replacement_peer, replacement_source, replacement_ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !replacement_ok {
		net.close(server_sock)
		return
	}
	defer net.close(replacement_listener)
	defer net.close(replacement_peer)
	defer net.close(replacement_source)

	conn := connection_test_install(server_sock, .Idle)
	testing.expect(t, conn != nil, "expected connection allocation")
	if conn == nil {
		net.close(server_sock)
		return
	}
	send_queue_init(conn)
	td.active_sockets = make(map[net.TCP_Socket]struct{}, 1)
	defer delete(td.active_sockets)
	td.active_sockets[server_sock] = {}
	td.connection_count += 1
	handle := conn.handle
	ctx: Connection_Close_Barrier_Context
	counted := true
	defer {
		if remaining := connection_get_by_handle(handle); remaining != nil {
			connection_close(remaining, false)
		}
		start := ulid.time_now()
		for nbio.num_waiting(&td.io) > 0 && time.since(start) < 2 * time.Second {
			if nbio.tick(&td.io, time.Millisecond) != .NONE {
				testing.fail_now(t, "cannot drain fixture I/O safely")
			}
		}
		if connection_get_by_handle(handle) != nil || nbio.num_waiting(&td.io) != 0 {
			// fail_now deliberately skips defers: do not free live I/O storage.
			testing.fail_now(t, "fixture must reach terminal quiescence before teardown")
		}
		if counted do connection_test_mark_removed(server_sock)
	}

	partial := kind == .Partial_Send || kind == .Partial_Writev
	if partial {
		send_buffer := i32(4096)
		testing.expect(t, linux.setsockopt(linux.Fd(server_sock), linux.SOL_SOCKET, linux.Socket_Option.SNDBUF, &send_buffer) == .NONE)
	} else {
		// Fill the SQ so the transport enters nbio's deferred queue.
		for _ in 0 ..< 8 {
			nbio.timeout(&td.io, time.Millisecond * 10, &ctx, connection_close_barrier_on_timeout)
		}
	}
	payload_a := []u8{'o', 'l', 'd', '-', 'a'}
	payload_b := []u8{'o', 'l', 'd', '-', 'b'}

	switch kind {
	case .Send, .Partial_Send:
		buf, alloc_err := byte_pool.alloc(td.spool, partial ? 1024 * 1024 : uint(len(payload_a)))
		testing.expect(t, alloc_err == .None, "send payload allocation failed")
		if alloc_err != .None do return
		for &b in buf do b = 'a'
		copy(buf, payload_a)
		item := Send_Item {
			lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			handle = handle,
			observer = Send_Completion_Observer{callback = connection_close_barrier_on_sent, ctx = &ctx},
		}
		nrc_io_send_all(conn, buf, item)

	case .Writev, .Partial_Writev:
		state := alloc_batch_state(2)
		testing.expect(t, state != nil, "batch allocation failed")
		if state == nil do return
		state.count = 0
		state.items = state.items[:2]
		state.iovec = state.iovec[:2]
		batch_submitted := false
		defer if !batch_submitted {
			for i in 0 ..< state.count do frame_lease_dispose(&state.items[i].lease)
			free_batch_state(state)
		}
		payloads := [2][]u8{payload_a, payload_b}
		for i in 0 ..< 2 {
			buf, alloc_err := byte_pool.alloc(td.spool, partial ? 1024 * 1024 : uint(len(payloads[i])))
			testing.expect(t, alloc_err == .None, "writev payload allocation failed")
			if alloc_err != .None do return
			for &b in buf do b = byte('a' + i)
			copy(buf, payloads[i])
			state.items[i] = Batch_Item {
				handle = handle,
				lease  = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			}
			state.count += 1
			if i == 0 {
				state.items[i].observer = Send_Completion_Observer {
					callback = connection_close_barrier_on_sent,
					ctx      = &ctx,
				}
			}
			state.iovec[i] = nbio.iovec {
				iov_base = raw_data(buf),
				iov_len  = uint(len(buf)),
			}
		}
		batch_submitted = true
		nrc_io_writev_all(conn, state)

	case .Shutdown:
		testing.expect(t, connection_io_pin(conn), "shutdown must acquire an I/O pin")
		ctx.io_ctx = Connection_IO_Context {
			sock   = server_sock,
			handle = handle,
			pinned = true,
		}
		nrc_io_shutdown_send(ctx.io_ctx, &ctx, connection_close_barrier_on_shutdown)
	}

	testing.expect_value(t, queue.len(td.io.unqueued), partial ? 0 : 1)
	testing.expect_value(t, conn.pending_io, u32(1))

	// Publish only the filled SQ, leaving the older transport in the backlog.
	// An immediate close could now take a free SQ slot and overtake it.
	nbio.submit_pending(&td.io)
	if partial {
		// Observe but do not consume the real kernel CQE. Close is requested before
		// nbio dispatches this partial success and submits the remainder.
		start := ulid.time_now()
		for io_uring.cq_ready(&td.io.ring) == 0 && time.since(start) < time.Second {
			time.sleep(time.Millisecond)
		}
		if testing.expect(t, io_uring.cq_ready(&td.io.ring) > 0, "kernel must produce a partial send CQE") {
			cqe := td.io.ring.cq.cqes[td.io.ring.cq.head^ & td.io.ring.cq.mask]
			testing.expect(t, cqe.res > 0 && cqe.res < 1024 * 1024, "must exercise positive partial success, not only an error or full send")
		}
	}
	connection_close(conn, false)
	testing.expect_value(t, conn.state, Connection_State.Closing)
	testing.expect(t, connection_get(server_sock) == nil, "close must detach active lookup immediately")
	testing.expect_value(t, conn.pending_io, u32(2))
	testing.expect(t, !conn.close_submitted, "physical close must wait for the final non-close I/O pin")
	testing.expect_value(t, ctx.terminal_callbacks, 0)
	_, fd_err := linux.fcntl_getfd(linux.Fd(server_sock), linux.F_GETFD)
	testing.expect(t, fd_err == .NONE, "server FD must remain owned while a non-close pin is pending")

	start := ulid.time_now()
	for ctx.terminal_callbacks == 0 && time.since(start) < time.Second {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	testing.expect_value(t, ctx.terminal_callbacks, 1)
	retained := connection_get_by_handle(handle)
	if retained != nil {
		testing.expect(t, retained.close_submitted, "terminal transport callback must submit the reserved close")
	}

	for connection_get_by_handle(handle) != nil && time.since(start) < time.Second * 2 {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, fmt.tprintf("nbio.tick close error: %v", terr))
	}
	if connection_get_by_handle(handle) != nil {
		testing.fail_now(t, "physical close must reclaim connection before FD reuse")
	}
	testing.expect_value(t, td.connection_count, 0)
	connection_test_mark_removed(server_sock)
	counted = false

	// Rebind the old descriptor number to a fresh TCP connection. Any old SQE
	// which survived its terminal callback can now corrupt or shut down this
	// replacement, so verify both directions after draining another CQ wave.
	reused_fd, dup_err := linux.fcntl_dupfd_cloexec(linux.Fd(replacement_source), linux.F_DUPFD_CLOEXEC, linux.Fd(server_sock))
	if !testing.expect(t, dup_err == .NONE, fmt.tprintf("replacement FD allocation error: %v", dup_err)) do return
	replacement := net.TCP_Socket(reused_fd)
	defer net.close(replacement)
	if !testing.expect(t, replacement == server_sock, "old FD must be free for atomic reuse; never overwrite another test's FD") do return
	for _ in 0 ..< 4 {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, fmt.tprintf("nbio.tick replacement error: %v", terr))
	}

	unexpected: [32]byte
	n_unexpected, unexpected_err := net.recv_tcp(replacement_peer, unexpected[:])
	testing.expect(t, n_unexpected == 0, "replacement peer received bytes from the old send/writev")
	testing.expect(t, unexpected_err == net.TCP_Recv_Error(.Would_Block), fmt.tprintf("replacement peer unexpectedly changed state: %v", unexpected_err))
	probe := []u8{'n', 'e', 'w'}
	n_sent, send_err := net.send_tcp(replacement, probe)
	testing.expect(t, send_err == nil && n_sent == len(probe), fmt.tprintf("replacement FD was unexpectedly shut down: sent=%d err=%v", n_sent, send_err))
	got: [3]byte
	n_got := fast_ack_test_recv_until(t, replacement_peer, got[:], len(probe), time.Millisecond * 100)
	testing.expect(t, n_got == len(probe) && got == [3]byte{'n', 'e', 'w'}, "replacement connection did not remain independent")
}

@(test)
test_linux_connection_close_barrier_deferred_send :: proc(t: ^testing.T) {
	connection_close_barrier_run(t, .Send)
}

@(test)
test_linux_connection_close_barrier_deferred_writev :: proc(t: ^testing.T) {
	connection_close_barrier_run(t, .Writev)
}

@(test)
test_linux_connection_close_barrier_deferred_shutdown :: proc(t: ^testing.T) {
	connection_close_barrier_run(t, .Shutdown)
}

@(test)
test_linux_connection_close_barrier_partial_send :: proc(t: ^testing.T) {
	connection_close_barrier_run(t, .Partial_Send)
}

@(test)
test_linux_connection_close_barrier_partial_writev :: proc(t: ^testing.T) {
	connection_close_barrier_run(t, .Partial_Writev)
}
