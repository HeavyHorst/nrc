package nbio

// Integration-style tests for the Linux non-blocking I/O layer. They exercise
// accept/connect/read/write/tick behavior with real sockets and deterministic
// workloads so server-level handler tests can rely on nbio preserving completion
// ordering, drain semantics, and close/error behavior.

import "core:bytes"
import "core:container/queue"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

import hgl "../hegel"
import ulid "../ulid"
import io_uring "_io_uring"

expect :: testing.expect

File_Read_Test_Result :: struct {
	done: bool,
	read: int,
	err:  linux.Errno,
}

file_read_test_callback :: proc(user: rawptr, read: int, err: linux.Errno) {
	result := (^File_Read_Test_Result)(user)
	result.read = read
	result.err = err
	result.done = true
}

File_Sync_Test_Result :: struct {
	done: bool,
	err:  linux.Errno,
}

file_sync_test_callback :: proc(user: rawptr, err: linux.Errno) {
	result := (^File_Sync_Test_Result)(user)
	result.err = err
	result.done = true
}

@(test)
test_async_read_only_file_open_and_close :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/nrc-nbio-open-%d", linux.getpid())
	defer delete(path)
	defer os.remove(path)
	expect(t, os.write_entire_file(path, transmute([]byte)string("asymmetric")) == nil)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	missing := strings.clone_to_cstring(fmt.tprintf("%s.missing", path))
	defer delete(missing)
	io: IO
	expect(t, init(&io) == .NONE)
	defer destroy(&io)
	Result :: struct {
		done: bool,
		fd:   linux.Fd,
		err:  linux.Errno,
	}
	results: [2]Result
	callback := proc(user: rawptr, fd: linux.Fd, err: linux.Errno) {
		result := (^Result)(user)
		result^ = {true, fd, err}
	}
	open_read_file(&io, cpath, &results[0], callback)
	open_read_file(&io, missing, &results[1], callback)
	expect(t, !results[0].done && !results[1].done, "open completed synchronously")
	drain_and_expect_empty(t, &io)
	expect(t, results[0].done && results[0].err == .NONE && results[0].fd >= 0)
	expect(t, results[1].done && results[1].err == .ENOENT && results[1].fd == -1)
	if results[0].err != .NONE do return
	buffer: [4]byte
	read: File_Read_Test_Result
	read_file_at(&io, results[0].fd, buffer[:], 3, &read, file_read_test_callback)
	drain_and_expect_empty(t, &io)
	expect(t, read.done && read.err == .NONE && read.read == 4)
	expect(t, string(buffer[:]) == "mmet")
	_, write_err := linux.write(results[0].fd, buffer[:])
	expect(t, write_err == .EBADF, "async open must be read-only")
	close(&io, results[0].fd)
	drain_and_expect_empty(t, &io)
	_, read_err := linux.pread(results[0].fd, buffer[:], 0)
	expect(t, read_err == .EBADF, "descriptor was not closed")
}

@(test)
test_positional_regular_file_reads :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/nrc-nbio-read-%d", linux.getpid())
	defer delete(path)
	defer os.remove(path)
	payload := transmute([]byte)string("0123456789abcdef")
	expect(t, os.write_entire_file(path, payload) == nil)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	fd, open_err := linux.open(cpath, {})
	expect(t, open_err == .NONE)
	defer linux.close(fd)

	io: IO
	expect(t, init(&io) == .NONE)
	defer destroy(&io)

	buffers: [5][8]byte
	results: [5]File_Read_Test_Result
	read_file_at(&io, fd, buffers[0][:], 0, &results[0], file_read_test_callback)
	read_file_at(&io, fd, buffers[1][:4], 6, &results[1], file_read_test_callback)
	read_file_at(&io, fd, buffers[2][:8], 13, &results[2], file_read_test_callback)
	read_file_at(&io, fd, buffers[3][:8], 99, &results[3], file_read_test_callback)
	read_file_at(&io, -1, buffers[4][:], 0, &results[4], file_read_test_callback)

	deadline := time.now()
	for num_waiting(&io) > 0 && time.since(deadline) < time.Second {
		expect(t, tick(&io, time.Millisecond) == .NONE)
	}
	expect(t, num_waiting(&io) == 0, "concurrent file reads did not complete")
	expect(t, results[0].done && results[0].err == .NONE && results[0].read == 8)
	expect(t, bytes.equal(buffers[0][:], payload[:8]))
	expect(t, results[1].done && results[1].err == .NONE && results[1].read == 4)
	expect(t, bytes.equal(buffers[1][:4], payload[6:10]))
	expect(t, results[2].done && results[2].err == .NONE && results[2].read == 3)
	expect(t, bytes.equal(buffers[2][:3], payload[13:]))
	expect(t, results[3].done && results[3].err == .NONE && results[3].read == 0)
	expect(t, results[4].done && results[4].read == 0 && results[4].err == .EBADF)
}

@(test)
test_regular_file_sync :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/nrc-nbio-sync-%d", linux.getpid())
	defer delete(path)
	defer os.remove(path)
	expect(t, os.write_entire_file(path, transmute([]byte)string("durable")) == nil)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	fd, open_err := linux.open(cpath, {.RDWR})
	expect(t, open_err == .NONE)
	defer linux.close(fd)

	io: IO
	expect(t, init(&io) == .NONE)
	defer destroy(&io)

	results: [2]File_Sync_Test_Result
	sync_file(&io, fd, &results[0], file_sync_test_callback)
	sync_file(&io, -1, &results[1], file_sync_test_callback)
	deadline := time.now()
	for num_waiting(&io) > 0 && time.since(deadline) < time.Second {
		expect(t, tick(&io, time.Millisecond) == .NONE)
	}
	expect(t, num_waiting(&io) == 0, "file sync completions did not drain")
	expect(t, results[0].done && results[0].err == .NONE)
	expect(t, results[1].done && results[1].err == .EBADF)
}

WORKLOAD_DEFAULT_SEED: u64 : #config(NBIO_TEST_WORKLOAD_SEED, u64(0x4d595df4d0f33173))

drain_and_expect_empty :: proc(t: ^testing.T, io: ^IO, budget: time.Duration = time.Millisecond * 250) {
	start := time.now()
	for (num_waiting(io) > 0 || io.ios_queued > 0 || io.ios_in_kernel > 0 || has_userspace_work(io)) && time.since(start) < budget {
		terr := tick(io, time.Millisecond)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while draining: %v", terr))
	}
	expect(t, num_waiting(io) == 0, fmt.tprintf("nbio pending completions not drained: %d", num_waiting(io)))
	expect(t, io.ios_queued == 0, fmt.tprintf("nbio queued submissions not drained: %d", io.ios_queued))
	expect(t, io.ios_in_kernel == 0, fmt.tprintf("nbio kernel operations not drained: %d", io.ios_in_kernel))
	expect(t, !has_userspace_work(io), "nbio userspace or CQ work not drained")
}

Echo_Context :: struct {
	io:            ^IO,
	accepted_sock: net.TCP_Socket,
	accept_calls:  int,
	recv_len:      int,
	sent_len:      int,
	recv_copy:     [256]byte,
	done:          bool,
	failed:        bool,
}

echo_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Echo_Context)user
	ctx.accept_calls += 1

	if err != nil {
		ctx.failed = true
		ctx.done = true
		return
	}

	ctx.accepted_sock = client
	recv_provided(ctx.io, client, ctx, echo_on_recv)
}

echo_on_recv :: proc(user: rawptr, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^Echo_Context)user

	if err != nil || received <= 0 {
		ctx.failed = true
		ctx.done = true
		return
	}

	copy(ctx.recv_copy[:], buf[:received])
	ctx.recv_len = received

	// recv_provided buffers are recycled when the callback returns,
	// so send from an owned snapshot.
	send_all(ctx.io, ctx.accepted_sock, ctx.recv_copy[:received], ctx, echo_on_sent)
}

echo_on_sent :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^Echo_Context)user
	if err != nil {
		ctx.failed = true
		ctx.done = true
		return
	}

	ctx.sent_len = sent
	ctx.done = true
}

Multishot_Accept_Context :: struct {
	server_sock:     net.TCP_Socket,
	accepted:        [8]net.TCP_Socket,
	accepted_count:  int,
	target_count:    int,
	listener_closed: bool,
	failed:          bool,
}

multishot_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Multishot_Accept_Context)user

	if err != nil {
		if ctx.accepted_count < ctx.target_count {
			ctx.failed = true
		}
		return
	}

	if ctx.accepted_count < len(ctx.accepted) {
		ctx.accepted[ctx.accepted_count] = client
	} else {
		net.close(client)
	}
	ctx.accepted_count += 1

	if ctx.accepted_count == ctx.target_count && !ctx.listener_closed {
		net.close(ctx.server_sock)
		ctx.listener_closed = true
	}
}

Timeout_Cancel_Context :: struct {
	callback_count: int,
}

on_timeout_cancelled :: proc(user: rawptr) {
	ctx := cast(^Timeout_Cancel_Context)user
	ctx.callback_count += 1
}

Timeout_Burst_Context :: struct {
	callback_count: int,
}

on_timeout_burst :: proc(user: rawptr) {
	ctx := cast(^Timeout_Burst_Context)user
	ctx.callback_count += 1
}

Workload_Context :: struct {
	io:             ^IO,
	accepted_sock:  net.TCP_Socket,
	accepted:       bool,
	failed:         bool,
	bytes_received: int,
	timeouts_fired: int,
}

workload_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Workload_Context)user
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
	recv_provided(ctx.io, client, ctx, workload_on_recv)
}

workload_on_recv :: proc(user: rawptr, received: int, _: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^Workload_Context)user
	if err != nil || received <= 0 {
		ctx.failed = true
		return
	}

	ctx.bytes_received += received
	recv_provided(ctx.io, ctx.accepted_sock, ctx, workload_on_recv)
}

workload_on_timeout :: proc(user: rawptr) {
	ctx := cast(^Workload_Context)user
	ctx.timeouts_fired += 1
}

next_rand_u64 :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1
	return state^
}

Writev_Timeout_Context :: struct {
	accepted_sock:       net.TCP_Socket,
	accepted:            bool,
	done:                bool,
	callback_count:      int,
	callback_user_index: int,
	timed_out:           bool,
	failed:              bool,
	sent:                int,
	total:               int,
}

writev_timeout_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Writev_Timeout_Context)user
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

writev_timeout_on_sent :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^Writev_Timeout_Context)user
	ctx.callback_count += 1
	ctx.callback_user_index = context.user_index
	ctx.sent = sent

	if err == nil {
		ctx.done = true
		return
	}

	tcp_err, ok := err.(net.TCP_Send_Error)
	if ok && tcp_err == .Timeout {
		ctx.timed_out = true
	} else {
		ctx.failed = true
	}
	ctx.done = true
}

Recv_All_Context :: struct {
	io:             ^IO,
	accepted_sock:  net.TCP_Socket,
	accepted:       bool,
	done:           bool,
	failed:         bool,
	callback_count: int,
	received:       int,
	payload_copy:   [BUFFER_SIZE]byte,
}

recv_all_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Recv_All_Context)user
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

recv_all_on_recv :: proc(user: rawptr, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^Recv_All_Context)user
	ctx.callback_count += 1

	if err != nil || received <= 0 {
		ctx.failed = true
		ctx.done = true
		return
	}

	ctx.received = received
	if received > len(ctx.payload_copy) {
		ctx.failed = true
		ctx.done = true
		return
	}
	copy(ctx.payload_copy[:received], buf[:received])
	ctx.done = true
}

Recv_All_Partial_Close_Context :: struct {
	done:           bool,
	failed:         bool,
	saw_error:      bool,
	callback_count: int,
	received:       int,
	payload_copy:   [BUFFER_SIZE]byte,
}

recv_all_partial_close_on_recv :: proc(user: rawptr, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^Recv_All_Partial_Close_Context)user
	ctx.callback_count += 1

	if received < 0 || received > len(ctx.payload_copy) {
		ctx.failed = true
		ctx.done = true
		return
	}

	ctx.received = received
	if received > 0 {
		copy(ctx.payload_copy[:received], buf[:received])
	}

	ctx.saw_error = err != nil
	ctx.done = true
}

Writev_Boundary_Context :: struct {
	accepted_sock:  net.TCP_Socket,
	accepted:       bool,
	done:           bool,
	failed:         bool,
	callback_count: int,
	sent:           int,
}

Writev_Peer_Close_Context :: struct {
	accepted_sock:  net.TCP_Socket,
	accepted:       bool,
	done:           bool,
	callback_count: int,
	saw_error:      bool,
	sent:           int,
}

writev_peer_close_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Writev_Peer_Close_Context)user
	if err != nil {
		ctx.done = true
		ctx.saw_error = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

writev_peer_close_on_sent :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^Writev_Peer_Close_Context)user
	ctx.callback_count += 1
	ctx.sent = sent
	ctx.saw_error = err != nil
	ctx.done = true
}

writev_boundary_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Writev_Boundary_Context)user
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

writev_boundary_on_sent :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^Writev_Boundary_Context)user
	ctx.callback_count += 1
	if err != nil {
		ctx.failed = true
		ctx.done = true
		return
	}

	ctx.sent = sent
	ctx.done = true
}

Stats_Send_Context :: struct {
	accepted_sock: net.TCP_Socket,
	accepted:      bool,
	done:          bool,
	failed:        bool,
}

Shutdown_Context :: struct {
	accepted_sock:   net.TCP_Socket,
	accepted:        bool,
	shutdown_done:   bool,
	shutdown_failed: bool,
	callback_count:  int,
}

Close_Pending_Recv_Context :: struct {
	accepted_sock:        net.TCP_Socket,
	accepted:             bool,
	recv_done:            bool,
	recv_callback_count:  int,
	recv_saw_error:       bool,
	close_done:           bool,
	close_callback_count: int,
	close_succeeded:      bool,
}

close_pending_recv_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Close_Pending_Recv_Context)user
	if err != nil {
		ctx.recv_done = true
		ctx.recv_saw_error = true
		return
	}
	ctx.accepted_sock = client
	ctx.accepted = true
}

close_pending_recv_on_recv :: proc(user: rawptr, _: int, _: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^Close_Pending_Recv_Context)user
	ctx.recv_callback_count += 1
	ctx.recv_saw_error = err != nil
	ctx.recv_done = true
}

close_pending_recv_on_close :: proc(user: rawptr, succeeded: bool) {
	ctx := cast(^Close_Pending_Recv_Context)user
	ctx.close_callback_count += 1
	ctx.close_succeeded = succeeded
	ctx.close_done = true
}

shutdown_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Shutdown_Context)user
	if err != nil {
		ctx.shutdown_failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

shutdown_on_complete :: proc(user: rawptr, err: net.Shutdown_Error) {
	ctx := cast(^Shutdown_Context)user
	ctx.callback_count += 1
	if err != .None {
		ctx.shutdown_failed = true
	}
	ctx.shutdown_done = true
}

Recv_ENOBUFS_Accept_Context :: struct {
	accepted_sock: net.TCP_Socket,
	accepted:      bool,
	failed:        bool,
}

recv_enobufs_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Recv_ENOBUFS_Accept_Context)user
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

Recv_ENOBUFS_Context :: struct {
	io:               ^IO,
	callback_count:   int,
	bytes_received:   int,
	seen_bids:        [2]int,
	bid_sequence:     [16]int,
	expected_payload: [16]byte,
	failed:           bool,
}

Recv_Cancel_Context :: struct {
	callback_count: int,
	received:       int,
	saw_error:      bool,
}

recv_cancel_on_recv :: proc(user: rawptr, received: int, _: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^Recv_Cancel_Context)user
	ctx.callback_count += 1
	ctx.received += received
	ctx.saw_error = err != nil
}

recv_enobufs_on_recv :: proc(user: rawptr, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^Recv_ENOBUFS_Context)user
	if err != nil || received <= 0 {
		ctx.failed = true
		return
	}

	matched_bid := false
	for backing, bid in ctx.io.pbuf_ring.data_buffers {
		if raw_data(backing) == raw_data(buf) {
			if bid < len(ctx.seen_bids) {
				ctx.seen_bids[bid] += 1
				ctx.bid_sequence[ctx.callback_count] = bid
			}
			matched_bid = true
			break
		}
	}
	if !matched_bid {
		ctx.failed = true
		return
	}
	if received != len(ctx.expected_payload) {
		ctx.failed = true
		return
	}
	for value, i in buf[:received] {
		if value != ctx.expected_payload[i] {
			ctx.failed = true
			return
		}
	}

	ctx.callback_count += 1
	ctx.bytes_received += received
}

Send_Timeout_Guard_Context :: struct {
	accepted_sock:       net.TCP_Socket,
	accepted:            bool,
	done:                bool,
	callback_count:      int,
	callback_user_index: int,
	timed_out:           bool,
	failed:              bool,
	sent:                int,
}

send_timeout_guard_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Send_Timeout_Guard_Context)user
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

send_timeout_guard_on_sent :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^Send_Timeout_Guard_Context)user
	ctx.callback_count += 1
	ctx.callback_user_index = context.user_index
	ctx.sent = sent

	if err == nil {
		ctx.done = true
		return
	}

	tcp_err, ok := err.(net.TCP_Send_Error)
	if ok && tcp_err == .Timeout {
		ctx.timed_out = true
	} else {
		ctx.failed = true
	}
	ctx.done = true
}

Timeout_Race_Context :: struct {
	callback_count: int,
	done:           bool,
}

timeout_race_on_timeout :: proc(user: rawptr) {
	ctx := cast(^Timeout_Race_Context)user
	ctx.callback_count += 1
	ctx.done = true
}

Accept_Retry_Context :: struct {
	accepted_sock:  net.TCP_Socket,
	callback_count: int,
	success_count:  int,
	error_count:    int,
	done:           bool,
}

accept_retry_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Accept_Retry_Context)user
	ctx.callback_count += 1

	if err != nil {
		ctx.error_count += 1
		ctx.done = true
		return
	}

	ctx.accepted_sock = client
	ctx.success_count += 1
	ctx.done = true
}

stats_send_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^Stats_Send_Context)user
	if err != nil {
		ctx.failed = true
		return
	}

	ctx.accepted_sock = client
	ctx.accepted = true
}

stats_send_on_sent :: proc(user: rawptr, _: int, err: net.Network_Error) {
	ctx := cast(^Stats_Send_Context)user
	if err != nil {
		ctx.failed = true
	}
	ctx.done = true
}

@(test)
test_recv_provided_injected_enobufs_recovery_cycles :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	perr := pbuf_ring_init(&io, 2)
	expect(t, perr == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", perr))
	defer pbuf_ring_destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	accept_ctx: Recv_ENOBUFS_Accept_Context
	accept(&io, server_sock, &accept_ctx, recv_enobufs_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !accept_ctx.accepted && !accept_ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, accept_ctx.accepted, "recv ENOBUFS test did not accept client")

	recv_ctx := Recv_ENOBUFS_Context {
		io = &io,
	}
	cycles :: 16
	payload: [16]byte
	for cycle in 0 ..< cycles {
		for i in 0 ..< len(payload) {
			payload[i] = byte(cycle * len(payload) + i)
		}
		copy(recv_ctx.expected_payload[:], payload[:])

		// Inject ENOBUFS into an unsubmitted completion. Its retry is therefore the
		// only real SQE targeting this Completion and must recover once data arrives.
		recv_handle := pool_get(&io.completion_pool)
		recv_handle.ctx = context
		recv_handle.user_data = &recv_ctx
		recv_handle.operation = Op_Recv_Provided {
			callback = recv_enobufs_on_recv,
			socket   = accept_ctx.accepted_sock,
		}
		recv_handle.result = -i32(linux.Errno.ENOBUFS)
		recv_provided_callback(&io, recv_handle, &recv_handle.operation.(Op_Recv_Provided))

		expect(t, recv_ctx.callback_count == cycle, "recv callback should not fire on ENOBUFS retry path")
		expect(t, num_waiting(&io) == 1, fmt.tprintf("cycle %d should retain one pending recv", cycle))

		n_sent, send_err := net.send_tcp(client_sock, payload[:])
		expect(t, send_err == nil, fmt.tprintf("net.send_tcp error in ENOBUFS recovery cycle %d: %v", cycle, send_err))
		expect(t, n_sent == len(payload), fmt.tprintf("ENOBUFS recovery cycle %d short write", cycle))

		run_start := time.now()
		for !recv_ctx.failed && recv_ctx.callback_count == cycle && time.since(run_start) < time.Second {
			terr := tick(&io, time.Millisecond * 2)
			expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in ENOBUFS recovery cycle %d: %v", cycle, terr))
		}
		expect(t, recv_ctx.callback_count == cycle + 1, fmt.tprintf("ENOBUFS recovery cycle %d did not complete", cycle))
		expect(
			t,
			io.pbuf_ring.produced - io.pbuf_ring.consumed == u64(io.pbuf_ring.entries),
			fmt.tprintf("provided-buffer ownership imbalance after cycle %d", cycle),
		)
	}

	expect(t, !recv_ctx.failed, "recv_provided under repeated ENOBUFS pressure failed")
	expect(t, recv_ctx.callback_count == cycles, fmt.tprintf("recv_provided callback count mismatch: got=%d expected=%d", recv_ctx.callback_count, cycles))
	expect(
		t,
		recv_ctx.bytes_received == cycles * len(payload),
		fmt.tprintf("recv_provided byte mismatch: got=%d expected=%d", recv_ctx.bytes_received, cycles * len(payload)),
	)
	expect(t, recv_ctx.seen_bids[0] + recv_ctx.seen_bids[1] == cycles, fmt.tprintf("provided-buffer ID accounting mismatch: %v", recv_ctx.seen_bids))
	expect(t, recv_ctx.seen_bids[0] > 0 && recv_ctx.seen_bids[1] > 0, fmt.tprintf("both provided-buffer IDs should be recycled: %v", recv_ctx.seen_bids))
	for bid, cycle in recv_ctx.bid_sequence {
		expect(t, bid == cycle & 1, fmt.tprintf("provided-buffer FIFO sequence mismatch at cycle %d: got=%d expected=%d", cycle, bid, cycle & 1))
	}
	expect(t, io.pbuf_ring.enobufs == cycles, fmt.tprintf("unexpected ENOBUFS count: %d", io.pbuf_ring.enobufs))

	net.close(accept_ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_cancel_recv_provided_delivers_one_terminal_callback :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	perr := pbuf_ring_init(&io, 2)
	expect(t, perr == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", perr))

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	accept_ctx: Recv_ENOBUFS_Accept_Context
	accept(&io, server_sock, &accept_ctx, recv_enobufs_on_accept)
	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !accept_ctx.accepted && !accept_ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during accept: %v", terr))
	}
	expect(t, accept_ctx.accepted, "recv cancellation test did not accept client")

	recv_ctx: Recv_Cancel_Context
	recv_handle := recv_provided(&io, accept_ctx.accepted_sock, &recv_ctx, recv_cancel_on_recv)
	terr := tick(&io, time.Millisecond)
	expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while submitting recv: %v", terr))
	expect(t, recv_ctx.callback_count == 0, "recv completed before cancellation")

	cancel_recv_provided(&io, recv_handle)
	cancel_start := time.now()
	for recv_ctx.callback_count == 0 && time.since(cancel_start) < time.Second {
		terr = tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while cancelling recv: %v", terr))
	}

	expect(t, recv_ctx.callback_count == 1, fmt.tprintf("recv cancellation callback count mismatch: %d", recv_ctx.callback_count))
	expect(t, recv_ctx.received == 0, fmt.tprintf("cancelled recv reported bytes: %d", recv_ctx.received))
	expect(t, recv_ctx.saw_error, "cancelled recv did not report a terminal error")

	net.close(accept_ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_cancelled_recv_provided_enobufs_is_not_retried :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	perr := pbuf_ring_init(&io, 2)
	expect(t, perr == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", perr))

	ctx: Recv_Cancel_Context
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = &ctx
	completion.operation = Op_Recv_Provided {
		callback  = recv_cancel_on_recv,
		socket    = net.TCP_Socket(-1),
		cancelled = true,
	}
	completion.result = -i32(linux.Errno.ENOBUFS)
	recv_provided_callback(&io, completion, &completion.operation.(Op_Recv_Provided))

	expect(t, ctx.callback_count == 1, fmt.tprintf("cancelled ENOBUFS callback count mismatch: %d", ctx.callback_count))
	expect(t, ctx.saw_error, "cancelled ENOBUFS did not report a terminal error")
	expect(t, io.pbuf_ring.enobufs == 0, "cancelled ENOBUFS should terminalize before retry accounting")
	expect(t, io.ios_queued == 0, "cancelled ENOBUFS queued another recv")
	expect(t, num_waiting(&io) == 0, "cancelled ENOBUFS retained its Completion")
}

@(test)
test_recv_cancel_retains_target_until_cancel_cqe :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	pool_destroy(&io.completion_pool)
	pool_err := pool_init(&io.completion_pool, 1)
	expect(t, pool_err == nil, fmt.tprintf("completion pool init error: %v", pool_err))
	defer destroy(&io)

	ctx: Recv_Cancel_Context
	target := pool_get(&io.completion_pool)
	target.ctx = context
	target.user_data = &ctx
	target.operation = Op_Recv_Provided {
		callback       = recv_cancel_on_recv,
		socket         = net.TCP_Socket(-1),
		cancelled      = true,
		cancel_pending = true,
	}
	cancel_completion := pool_get(&io.completion_pool)
	cancel_completion.ctx = context
	cancel_completion.operation = Op_Recv_Cancel {
		target = target,
	}

	target_cqe := io_uring.io_uring_cqe {
		user_data = u64(uintptr(target)),
		res       = -i32(linux.Errno.ENOBUFS),
	}
	cancel_cqe := io_uring.io_uring_cqe {
		user_data = u64(uintptr(cancel_completion)),
		res       = 0,
	}
	io.ios_in_kernel = 2

	dispatch_cqe(&io, target_cqe)
	run_completed_callbacks(&io)
	expect(t, ctx.callback_count == 1, fmt.tprintf("target callback count mismatch: %d", ctx.callback_count))
	expect(t, num_waiting(&io) == 2, "target or cancel Completion released before cancel CQE")

	replacement := pool_get(&io.completion_pool)
	expect(t, replacement != target, "cancel target address was reused before cancel CQE")
	pool_put(&io.completion_pool, replacement)

	dispatch_cqe(&io, cancel_cqe)
	run_completed_callbacks(&io)
	expect(t, io.ios_in_kernel == 0, fmt.tprintf("cancel kernel count mismatch: %d", io.ios_in_kernel))
	expect(t, num_waiting(&io) == 0, fmt.tprintf("cancel Completion leak: %d", num_waiting(&io)))

	first := pool_get(&io.completion_pool)
	second := pool_get(&io.completion_pool)
	expect(t, first == target || second == target, "cancel target was not returned after both CQEs retired")
	pool_put(&io.completion_pool, second)
	pool_put(&io.completion_pool, first)
}

@(test)
test_send_all_timeout_small_payload_no_false_positive :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Send_Timeout_Guard_Context
	accept(&io, server_sock, &ctx, send_timeout_guard_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !ctx.accepted && !ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, ctx.accepted, "send timeout guard test did not accept client")

	payload: []byte = {'s', 'm', 'a', 'l', 'l', '-', 't', 'x'}
	send_all_tcp_timeout(&io, ctx.accepted_sock, payload, time.Millisecond * 100, &ctx, send_timeout_guard_on_sent)

	run_start := time.now()
	for !ctx.done && !ctx.failed && time.since(run_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in send timeout guard test: %v", terr))
	}

	expect(t, ctx.done, "send_all_tcp_timeout callback did not fire")
	expect(t, !ctx.failed, "send_all_tcp_timeout callback returned unexpected error")
	expect(t, !ctx.timed_out, "send_all_tcp_timeout timed out unexpectedly for small payload")
	expect(t, ctx.callback_count == 1, fmt.tprintf("send_all_tcp_timeout callback count mismatch: %d", ctx.callback_count))
	expect(t, ctx.sent == len(payload), fmt.tprintf("send_all_tcp_timeout sent mismatch: got=%d expected=%d", ctx.sent, len(payload)))

	recv_buf: [32]byte
	n_recv, recv_err := net.recv_tcp(client_sock, recv_buf[:])
	expect(t, recv_err == nil, fmt.tprintf("net.recv_tcp error in send timeout guard test: %v", recv_err))
	expect(t, n_recv == len(payload), "send timeout guard payload size mismatch")
	for i in 0 ..< n_recv {
		expect(t, recv_buf[i] == payload[i], "send timeout guard payload mismatch")
	}

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_accept_transient_retry_semantics :: proc(t: ^testing.T) {
	transient_errnos: [2]linux.Errno = {.EINTR, .EWOULDBLOCK}

	for transient_errno in transient_errnos {
		io: IO
		ierr := init(&io)
		expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))

		server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
		expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))

		server_ep, ep_err := net.bound_endpoint(server_sock)
		expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

		ctx: Accept_Retry_Context
		completion := pool_get(&io.completion_pool)
		completion.ctx = context
		completion.user_data = &ctx
		completion.operation = Op_Accept {
			callback    = accept_retry_on_accept,
			socket      = server_sock,
			sockaddrlen = i32(size_of(linux.Sock_Addr_Any)),
			multishot   = false,
		}
		completion.result = -i32(transient_errno)

		accept_callback(&io, completion, &completion.operation.(Op_Accept))

		expect(t, ctx.callback_count == 0, fmt.tprintf("accept callback should not fire for transient errno=%v", transient_errno))
		expect(
			t,
			num_waiting(&io) == 1,
			fmt.tprintf("accept completion should remain pending after transient errno=%v, waiting=%d", transient_errno, num_waiting(&io)),
		)

		client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
		expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))

		run_start := time.now()
		for !ctx.done && time.since(run_start) < time.Second {
			terr := tick(&io, time.Millisecond * 2)
			expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in accept retry test: %v", terr))
		}

		expect(t, ctx.done, fmt.tprintf("accept retry did not complete for transient errno=%v", transient_errno))
		expect(t, ctx.callback_count == 1, fmt.tprintf("accept callback count mismatch for transient errno=%v", transient_errno))
		expect(t, ctx.success_count == 1, fmt.tprintf("accept success count mismatch for transient errno=%v", transient_errno))
		expect(t, ctx.error_count == 0, fmt.tprintf("accept error count mismatch for transient errno=%v", transient_errno))

		net.close(client_sock)
		net.close(ctx.accepted_sock)
		net.close(server_sock)
		drain_and_expect_empty(t, &io)
		destroy(&io)
	}
}

@(test)
test_timeout_cancel_race_windows_callback_once :: proc(t: ^testing.T) {
	Case :: struct {
		name:             string,
		timeout:          time.Duration,
		pre_cancel_ticks: int,
		prime_submit:     bool,
	}

	cases: [3]Case = {
		{"immediate_cancel", time.Millisecond * 80, 0, false},
		{"cancel_after_submit", time.Millisecond * 80, 0, true},
		{"cancel_midflight", time.Millisecond * 80, 20, true},
	}

	for c in cases {
		io: IO
		ierr := init(&io)
		expect(t, ierr == .NONE, fmt.tprintf("nbio.init error (%s): %v", c.name, ierr))

		ctx: Timeout_Race_Context
		handle := timeout(&io, c.timeout, &ctx, timeout_race_on_timeout)
		expect(t, handle != nil, fmt.tprintf("timeout handle nil (%s)", c.name))

		if c.prime_submit {
			terr := tick(&io, time.Millisecond)
			expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during prime submit (%s): %v", c.name, terr))
		}

		if c.pre_cancel_ticks > 0 {
			for _ in 0 ..< c.pre_cancel_ticks {
				if ctx.done do break
				terr := tick(&io, time.Millisecond)
				expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during pre-cancel wait (%s): %v", c.name, terr))
			}
		}

		if !ctx.done {
			cancel(&io, handle)
		}

		run_start := time.now()
		for !ctx.done && time.since(run_start) < time.Second {
			terr := tick(&io, time.Millisecond * 2)
			expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during race settle (%s): %v", c.name, terr))
		}

		expect(t, ctx.done, fmt.tprintf("timeout race case did not settle: %s", c.name))
		expect(t, ctx.callback_count == 1, fmt.tprintf("timeout callback count mismatch (%s): %d", c.name, ctx.callback_count))

		drain_and_expect_empty(t, &io)
		destroy(&io)
	}
}

@(test)
test_timeout_link_race_success_precedes_timeout :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	// Phase 1: send_all_tcp_timeout should complete once without false timeout.
	send_ctx: Send_Timeout_Guard_Context
	accept(&io, server_sock, &send_ctx, send_timeout_guard_on_accept)

	client_send_sock, dial_send_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_send_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint send phase error: %v", dial_send_err))
	defer net.close(client_send_sock)

	accept_send_start := time.now()
	for !send_ctx.accepted && !send_ctx.failed && time.since(accept_send_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in send phase accept: %v", terr))
	}
	expect(t, send_ctx.accepted, "send phase did not accept client")

	send_payload := make([]byte, 256 * 1024)
	defer delete(send_payload)
	for i in 0 ..< len(send_payload) {
		send_payload[i] = byte((i * 11) & 0xff)
	}

	send_all_tcp_timeout(&io, send_ctx.accepted_sock, send_payload, time.Millisecond * 150, &send_ctx, send_timeout_guard_on_sent)

	send_recv_total := 0
	send_recv_buf := make([]byte, 64 * 1024)
	defer delete(send_recv_buf)

	send_run_start := time.now()
	for (!send_ctx.done || send_recv_total < len(send_payload)) && !send_ctx.failed && time.since(send_run_start) < time.Second * 2 {
		terr := tick(&io, time.Millisecond)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in send phase run: %v", terr))

		if send_recv_total >= len(send_payload) {
			continue
		}

		n_recv, recv_err := net.recv_tcp(client_send_sock, send_recv_buf)
		if recv_err == nil {
			send_recv_total += n_recv
			continue
		}

		#partial switch recv_err {
		case .Would_Block:
		case .Connection_Closed:
			if !send_ctx.done {
				expect(t, false, "send phase connection closed before completion")
			}
		case:
			expect(t, false, fmt.tprintf("unexpected net.recv_tcp error in send phase: %v", recv_err))
		}
	}

	expect(t, send_ctx.done, "send phase callback did not fire")
	expect(t, !send_ctx.failed, "send phase callback failed")
	expect(t, !send_ctx.timed_out, "send phase unexpectedly timed out")
	expect(t, send_ctx.callback_count == 1, fmt.tprintf("send phase callback count mismatch: %d", send_ctx.callback_count))
	expect(t, send_ctx.sent == len(send_payload), fmt.tprintf("send phase sent mismatch: got=%d expected=%d", send_ctx.sent, len(send_payload)))
	expect(t, send_recv_total == len(send_payload), fmt.tprintf("send phase recv mismatch: got=%d expected=%d", send_recv_total, len(send_payload)))

	net.close(send_ctx.accepted_sock)
	drain_and_expect_empty(t, &io)

	// Phase 2: writev_all_tcp_timeout should also complete once without timeout.
	writev_ctx: Writev_Timeout_Context
	accept(&io, server_sock, &writev_ctx, writev_timeout_on_accept)

	client_writev_sock, dial_writev_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_writev_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint writev phase error: %v", dial_writev_err))
	defer net.close(client_writev_sock)

	accept_writev_start := time.now()
	for !writev_ctx.accepted && !writev_ctx.failed && time.since(accept_writev_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in writev phase accept: %v", terr))
	}
	expect(t, writev_ctx.accepted, "writev phase did not accept client")

	part_a := make([]byte, 96 * 1024)
	defer delete(part_a)
	part_b := make([]byte, 64 * 1024)
	defer delete(part_b)
	for i in 0 ..< len(part_a) {
		part_a[i] = byte((i * 3) & 0xff)
	}
	for i in 0 ..< len(part_b) {
		part_b[i] = byte((i * 7) & 0xff)
	}

	writev_iov: [2]iovec
	writev_iov[0] = iovec {
		iov_base = rawptr(&part_a[0]),
		iov_len  = uint(len(part_a)),
	}
	writev_iov[1] = iovec {
		iov_base = rawptr(&part_b[0]),
		iov_len  = uint(len(part_b)),
	}
	writev_total := len(part_a) + len(part_b)

	writev_all_tcp_timeout(&io, writev_ctx.accepted_sock, writev_iov[:], time.Millisecond * 150, &writev_ctx, writev_timeout_on_sent)

	writev_recv_total := 0
	writev_recv_buf := make([]byte, 64 * 1024)
	defer delete(writev_recv_buf)

	writev_run_start := time.now()
	for (!writev_ctx.done || writev_recv_total < writev_total) && !writev_ctx.failed && time.since(writev_run_start) < time.Second * 2 {
		terr := tick(&io, time.Millisecond)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in writev phase run: %v", terr))

		if writev_recv_total >= writev_total {
			continue
		}

		n_recv, recv_err := net.recv_tcp(client_writev_sock, writev_recv_buf)
		if recv_err == nil {
			writev_recv_total += n_recv
			continue
		}

		#partial switch recv_err {
		case .Would_Block:
		case .Connection_Closed:
			if !writev_ctx.done {
				expect(t, false, "writev phase connection closed before completion")
			}
		case:
			expect(t, false, fmt.tprintf("unexpected net.recv_tcp error in writev phase: %v", recv_err))
		}
	}

	expect(t, writev_ctx.done, "writev phase callback did not fire")
	expect(t, !writev_ctx.failed, "writev phase callback failed")
	expect(t, !writev_ctx.timed_out, "writev phase unexpectedly timed out")
	expect(t, writev_ctx.callback_count == 1, fmt.tprintf("writev phase callback count mismatch: %d", writev_ctx.callback_count))
	expect(t, writev_ctx.sent == writev_total, fmt.tprintf("writev phase sent mismatch: got=%d expected=%d", writev_ctx.sent, writev_total))
	expect(t, writev_recv_total == writev_total, fmt.tprintf("writev phase recv mismatch: got=%d expected=%d", writev_recv_total, writev_total))

	net.close(writev_ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_dispatch_linked_timeout_cqe_orderings :: proc(t: ^testing.T) {
	Case :: struct {
		name:             string,
		is_writev:        bool,
		primary_result:   i32,
		timeout_first:    bool,
		run_between_cqes: bool,
		expect_timeout:   bool,
		expected_sent:    int,
	}

	cases: [8]Case = {
		{"send_success_then_timeout_same_batch", false, 8, false, false, false, 8},
		{"send_success_callback_then_late_timeout", false, 8, false, true, false, 8},
		{"send_timeout_then_canceled_primary", false, -i32(linux.Errno.ECANCELED), true, false, true, 0},
		{"send_canceled_primary_then_timeout", false, -i32(linux.Errno.ECANCELED), false, false, true, 0},
		{"writev_success_then_timeout_same_batch", true, 8, false, false, false, 8},
		{"writev_success_callback_then_late_timeout", true, 8, false, true, false, 8},
		{"writev_timeout_then_canceled_primary", true, -i32(linux.Errno.ECANCELED), true, false, true, 0},
		{"writev_canceled_primary_then_timeout", true, -i32(linux.Errno.ECANCELED), false, false, true, 0},
	}

	for c in cases {
		io: IO
		ierr := init(&io)
		expect(t, ierr == .NONE, fmt.tprintf("nbio.init error (%s): %v", c.name, ierr))
		pool_destroy(&io.completion_pool)
		pool_err := pool_init(&io.completion_pool, 1)
		expect(t, pool_err == nil, fmt.tprintf("completion pool init error (%s): %v", c.name, pool_err))

		ctx: Send_Timeout_Guard_Context
		payload: [8]byte = {'d', 'i', 's', 'p', 'a', 't', 'c', 'h'}
		iov: [2]iovec = {{iov_base = rawptr(&payload[0]), iov_len = 4}, {iov_base = rawptr(&payload[4]), iov_len = 4}}
		completion := pool_get(&io.completion_pool)
		completion.ctx = context
		completion.user_data = &ctx
		if c.is_writev {
			completion.operation = Op_Writev {
				callback = send_timeout_guard_on_sent,
				iov = iov[:],
				len = len(payload),
				all = true,
				timeout_nsec = i64(time.Second),
				timeout_spec = linux.Time_Spec{time_sec = 1},
			}
		} else {
			completion.operation = Op_Send {
				callback = send_timeout_guard_on_sent,
				buf = payload[:],
				len = len(payload),
				all = true,
				timeout_nsec = i64(time.Second),
				timeout_spec = linux.Time_Spec{time_sec = 1},
			}
		}

		primary := io_uring.io_uring_cqe {
			user_data = u64(uintptr(completion)),
			res       = c.primary_result,
		}
		linked_timeout := io_uring.io_uring_cqe {
			user_data = u64(uintptr(completion)) + 1,
			res       = c.expect_timeout ? -i32(linux.Errno.ETIME) : -i32(linux.Errno.ECANCELED),
		}
		io.ios_in_kernel = 2

		if c.timeout_first {
			dispatch_cqe(&io, linked_timeout)
			dispatch_cqe(&io, primary)
		} else {
			dispatch_cqe(&io, primary)
			if c.run_between_cqes {
				run_completed_callbacks(&io)
				replacement := pool_get(&io.completion_pool)
				expect(t, replacement == completion, "single-slot pool did not reuse the primary completion")
				replacement.result = 12345
				dispatch_cqe(&io, linked_timeout)
				expect(t, replacement.result == 12345, "late linked-timeout CQE mutated a replacement completion")
				pool_put(&io.completion_pool, replacement)
			} else {
				dispatch_cqe(&io, linked_timeout)
			}
		}
		run_completed_callbacks(&io)

		expect(t, ctx.done, fmt.tprintf("dispatch case did not complete: %s", c.name))
		expect(t, ctx.callback_count == 1, fmt.tprintf("dispatch callback count mismatch (%s): %d", c.name, ctx.callback_count))
		expect(t, ctx.timed_out == c.expect_timeout, fmt.tprintf("dispatch timeout result mismatch: %s", c.name))
		expect(t, !ctx.failed, fmt.tprintf("dispatch reported unexpected error: %s", c.name))
		expect(t, ctx.sent == c.expected_sent, fmt.tprintf("dispatch sent mismatch (%s): got=%d expected=%d", c.name, ctx.sent, c.expected_sent))
		expect(t, io.ios_in_kernel == 0, fmt.tprintf("dispatch kernel count mismatch (%s): %d", c.name, io.ios_in_kernel))
		expect(t, num_waiting(&io) == 0, fmt.tprintf("dispatch completion leak (%s): %d", c.name, num_waiting(&io)))
		expect(t, !has_userspace_work(&io), fmt.tprintf("dispatch userspace work remained: %s", c.name))

		destroy(&io)
	}
}

@(test)
test_timeout :: proc(t: ^testing.T) {
	io: IO

	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))

	defer destroy(&io)

	timeout_fired: bool

	timeout(&io, time.Millisecond * 10, &timeout_fired, proc(t_: rawptr) {
		timeout_fired := cast(^bool)t_
		timeout_fired^ = true
	})

	deadline := time.Millisecond * 11

	start := time.now()
	for {
		terr := tick(&io, time.Millisecond)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))

		if time.since(start) > deadline {
			expect(t, timeout_fired, "timeout did not run in time")
			break
		}
	}

	drain_and_expect_empty(t, &io)
}

@(test)
test_tick_returns_after_callback_wave_before_wait_budget :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	timeout_fired := false
	timeout(&io, time.Millisecond, &timeout_fired, proc(ctx: rawptr) {
		fired := cast(^bool)ctx
		fired^ = true
	})

	started_at := time.now()
	terr := tick(&io, 300 * time.Millisecond, yield_after_callbacks = true)
	elapsed := time.since(started_at)
	expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	expect(t, timeout_fired, "tick should execute the ready timeout callback")
	expect(t, elapsed < 100 * time.Millisecond, fmt.tprintf("tick held completed callback until wait budget elapsed: %v", elapsed))

	drain_and_expect_empty(t, &io)
}

@(test)
test_accept_recv_provided_send_all_echo :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	perr := pbuf_ring_init(&io)
	expect(t, perr == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", perr))
	defer pbuf_ring_destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx := Echo_Context {
		io = &io,
	}
	accept(&io, server_sock, &ctx, echo_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	payload: []byte = {'n', 'b', 'i', 'o', '-', 'e', 'c', 'h', 'o', '-', 't', 'e', 's', 't'}
	n_sent, send_err := net.send_tcp(client_sock, payload)
	expect(t, send_err == nil, fmt.tprintf("net.send_tcp error: %v", send_err))
	expect(t, n_sent == len(payload), "client did not send full payload")

	start := time.now()
	for !ctx.done && !ctx.failed && time.since(start) < time.Second {
		terr := tick(&io, time.Millisecond * 5)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}

	expect(t, ctx.done, "server echo flow did not finish before timeout")
	expect(t, !ctx.failed, "server echo callbacks failed")
	expect(t, ctx.accept_calls == 1, "unexpected accept callback count")
	expect(t, ctx.recv_len == len(payload), "server received unexpected payload size")
	expect(t, ctx.sent_len == ctx.recv_len, "server send size mismatch")

	echoed: [256]byte
	n_recv, recv_err := net.recv_tcp(client_sock, echoed[:])
	expect(t, recv_err == nil, fmt.tprintf("net.recv_tcp error: %v", recv_err))
	expect(t, n_recv == len(payload), "client did not receive full echo payload")
	for i in 0 ..< n_recv {
		expect(t, echoed[i] == payload[i], "echo payload mismatch")
	}

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_multishot_accept_lifecycle :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx := Multishot_Accept_Context {
		server_sock  = server_sock,
		target_count = 3,
	}
	defer if !ctx.listener_closed do net.close(server_sock)

	accept(&io, server_sock, &ctx, multishot_on_accept, true)

	clients: [3]net.TCP_Socket
	for i in 0 ..< len(clients) {
		client, dial_err := net.dial_tcp_from_endpoint(server_ep)
		expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint #%d error: %v", i, dial_err))
		clients[i] = client
	}

	start := time.now()
	for ctx.accepted_count < ctx.target_count && !ctx.failed && time.since(start) < time.Second {
		terr := tick(&io, time.Millisecond * 5)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}

	expect(t, !ctx.failed, "multishot accept failed before target connections")
	expect(t, ctx.accepted_count == ctx.target_count, "multishot accept count mismatch")
	expect(t, ctx.listener_closed, "listener was not closed after target accepts")

	for c in clients {
		net.close(c)
	}
	for i in 0 ..< ctx.accepted_count {
		net.close(ctx.accepted[i])
	}
}

@(test)
test_timeout_cancel_invokes_callback_once :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	ctx: Timeout_Cancel_Context

	handle := timeout(&io, time.Second * 10, &ctx, on_timeout_cancelled)
	expect(t, handle != nil, "timeout did not return a completion handle")

	// Submit timeout to kernel before canceling.
	terr := tick(&io, time.Millisecond)
	expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))

	cancel(&io, handle)

	start := time.now()
	for ctx.callback_count == 0 && time.since(start) < time.Millisecond * 250 {
		terr = tick(&io, time.Millisecond * 5)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}

	expect(t, ctx.callback_count == 1, "canceled timeout callback count mismatch")
	drain_and_expect_empty(t, &io)
}

@(test)
test_timeout_submission_pressure :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	count :: 4096
	ctx: Timeout_Burst_Context

	for _ in 0 ..< count {
		timeout(&io, time.Millisecond * 8, &ctx, on_timeout_burst)
	}

	start := time.now()
	for ctx.callback_count < count && time.since(start) < time.Second * 5 {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}

	expect(t, ctx.callback_count == count, "not all queued timeouts completed")
	drain_and_expect_empty(t, &io)
}

@(test)
test_submit_all_pending_publishes_small_ring_overflow_without_callbacks :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io, ring_entries = 8)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init small ring error: %v", ierr))
	defer destroy(&io)

	ctx: Timeout_Burst_Context
	count :: 32
	for _ in 0 ..< count {
		timeout(&io, time.Millisecond * 50, &ctx, on_timeout_burst)
	}
	expect(t, queue.len(io.unqueued) > 0, "timeout burst should overflow the small SQ ring")

	err := submit_all_pending(&io)
	expect(t, err == .NONE, fmt.tprintf("submit_all_pending error: %v", err))
	expect(t, queue.len(io.unqueued) == 0, "submit_all_pending should publish every deferred operation")
	expect(t, io.ios_queued == 0, "submit_all_pending should submit every prepared SQE")
	expect(t, ctx.callback_count == 0, "submit_all_pending must not run completion callbacks")

	drain_and_expect_empty(t, &io, time.Second)
	expect(t, ctx.callback_count == count, "all published operations should complete")
}

// A timed send and its linked timeout are one submission unit. If only one SQE
// remains, the primary is not reserved and the whole operation waits
// until both entries fit; the requested deadline must never be silently dropped.
@(test)
test_timed_send_defers_when_only_primary_sqe_fits :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io, ring_entries = 8)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init small ring error: %v", ierr))
	defer destroy(&io)

	filler_ctx: Timeout_Burst_Context
	for _ in 0 ..< 7 {
		timeout(&io, time.Millisecond, &filler_ctx, on_timeout_burst)
	}
	expect(t, sq_capacity_remaining(&io) == 1, fmt.tprintf("expected one free SQE before timed send, got %d", sq_capacity_remaining(&io)))

	ctx: Send_Timeout_Guard_Context
	payload: []byte = {'s', 'e', 'n', 'd'}
	sqe_index := io.ring.sq.sqe_tail & io.ring.sq.mask
	queued_before := io.ios_queued
	completion := _send(&io, net.TCP_Socket(-1), payload, &ctx, send_timeout_guard_on_sent, all = true, timeout = time.Second)

	expect(t, sq_capacity_remaining(&io) == 1, "timed send preflight must leave the final SQE unused")
	expect(t, io.ios_queued == queued_before, "deferred timed send must not count an unpublished primary SQE")
	expect(t, queue.len(io.unqueued) == 1, "timed send must defer as a unit when only one SQE remains")
	sqe := &io.ring.sq.sqes[sqe_index]
	expect(t, sqe^ == io_uring.io_uring_sqe{}, "deferred timed send must not prepare an unlinked primary SQE")
	expect(t, ctx.callback_count == 0, "deferred timed send must not complete synchronously")

	expect(t, submit_all_pending(&io) == .NONE, "timed send should publish after two SQEs become available")
	expect(t, queue.len(io.unqueued) == 0, "timed send should leave the deferred queue after linked publication")
	expect(t, sqe.flags & u8(io_uring.IOSQE_IO_LINK) != 0, "retried send must retain its linked timeout")
	timeout_sqe := &io.ring.sq.sqes[(sqe_index + 1) & io.ring.sq.mask]
	expect(t, timeout_sqe.opcode == io_uring.IORING_OP.LINK_TIMEOUT, "retried send should be followed by a linked-timeout SQE")
	expect(t, timeout_sqe.user_data == u64(uintptr(completion)) + 1, "retried send timeout should use the primary completion's odd tag")
	drain_and_expect_empty(t, &io, time.Second)
	expect(t, filler_ctx.callback_count == 7, "all SQ-filling timeouts should complete")
	expect(t, ctx.callback_count == 1, fmt.tprintf("timed send callback count mismatch: %d", ctx.callback_count))
}

// Mirrors the timed-send pressure case for writev.
@(test)
test_timed_writev_defers_when_only_primary_sqe_fits :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io, ring_entries = 8)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init small ring error: %v", ierr))
	defer destroy(&io)

	filler_ctx: Timeout_Burst_Context
	for _ in 0 ..< 7 {
		timeout(&io, time.Millisecond, &filler_ctx, on_timeout_burst)
	}
	expect(t, sq_capacity_remaining(&io) == 1, fmt.tprintf("expected one free SQE before timed writev, got %d", sq_capacity_remaining(&io)))

	ctx: Writev_Timeout_Context
	payload: []byte = {'w', 'r', 'i', 't', 'e', 'v'}
	iov: [1]iovec
	iov[0] = iovec {
		iov_base = rawptr(&payload[0]),
		iov_len  = uint(len(payload)),
	}
	sqe_index := io.ring.sq.sqe_tail & io.ring.sq.mask
	queued_before := io.ios_queued
	completion := _writev(&io, net.TCP_Socket(-1), iov[:], &ctx, writev_timeout_on_sent, all = true, timeout = time.Second)

	expect(t, sq_capacity_remaining(&io) == 1, "timed writev preflight must leave the final SQE unused")
	expect(t, io.ios_queued == queued_before, "deferred timed writev must not count an unpublished primary SQE")
	expect(t, queue.len(io.unqueued) == 1, "timed writev must defer as a unit when only one SQE remains")
	sqe := &io.ring.sq.sqes[sqe_index]
	expect(t, sqe^ == io_uring.io_uring_sqe{}, "deferred timed writev must not prepare an unlinked primary SQE")
	expect(t, ctx.callback_count == 0, "deferred timed writev must not complete synchronously")

	expect(t, submit_all_pending(&io) == .NONE, "timed writev should publish after two SQEs become available")
	expect(t, queue.len(io.unqueued) == 0, "timed writev should leave the deferred queue after linked publication")
	expect(t, sqe.flags & u8(io_uring.IOSQE_IO_LINK) != 0, "retried writev must retain its linked timeout")
	timeout_sqe := &io.ring.sq.sqes[(sqe_index + 1) & io.ring.sq.mask]
	expect(t, timeout_sqe.opcode == io_uring.IORING_OP.LINK_TIMEOUT, "retried writev should be followed by a linked-timeout SQE")
	expect(t, timeout_sqe.user_data == u64(uintptr(completion)) + 1, "retried writev timeout should use the primary completion's odd tag")
	drain_and_expect_empty(t, &io, time.Second)
	expect(t, filler_ctx.callback_count == 7, "all SQ-filling timeouts should complete")
	expect(t, ctx.callback_count == 1, fmt.tprintf("timed writev callback count mismatch: %d", ctx.callback_count))
}

@(test)
test_deferred_timed_send_expiration_uses_normal_callback_wave :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io, ring_entries = 8)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init small ring error: %v", ierr))
	defer destroy(&io)

	filler_ctx: Timeout_Burst_Context
	for _ in 0 ..< 7 {
		timeout(&io, time.Millisecond, &filler_ctx, on_timeout_burst)
	}

	ctx: Send_Timeout_Guard_Context
	payload: []byte = {'e', 'x', 'p', 'i', 'r', 'e'}
	original_user_index := context.user_index
	context.user_index = 4101
	completion := _send(&io, net.TCP_Socket(-1), payload, &ctx, send_timeout_guard_on_sent, all = true, timeout = time.Millisecond * 10)
	context.user_index = original_user_index
	expect(t, queue.len(io.unqueued) == 1, "timed send should begin deferred")
	completion.start_time = time.to_unix_nanoseconds(ulid.time_now_monotonic()) - i64(20 * time.Millisecond)

	expect(t, submit_all_pending(&io) == .NONE, "expired deferred send should leave submission queues cleanly")
	expect(t, queue.len(io.unqueued) == 0, "expired send should leave the deferred queue")
	expect(t, queue.len(io.completed) == 1, "expired send should await the normal callback wave")
	expect(t, queue.front_ptr(&io.completed)^ == completion, "completed queue should retain the deferred send completion")
	expect(t, ctx.callback_count == 0, "submission-only drain must not invoke the expired send callback")

	context.user_index = -1
	run_completed_callbacks(&io)
	context.user_index = original_user_index
	expect(t, ctx.callback_count == 1 && ctx.timed_out && !ctx.failed, "deferred send should report timeout exactly once")
	expect(t, ctx.sent == 0, "deferred send timeout should preserve zero progress")
	expect(t, ctx.callback_user_index == 4101, "deferred send callback should restore its captured context")
	expect(t, queue.len(io.completed) == 0, "send callback wave should consume the completed entry")

	drain_and_expect_empty(t, &io)
	expect(t, filler_ctx.callback_count == 7, "all SQ-filling timeouts should complete")
	expect(t, ctx.callback_count == 1, "draining must not repeat the expired send callback")
}

@(test)
test_deferred_timed_writev_expiration_uses_normal_callback_wave :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io, ring_entries = 8)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init small ring error: %v", ierr))
	defer destroy(&io)

	filler_ctx: Timeout_Burst_Context
	for _ in 0 ..< 7 {
		timeout(&io, time.Millisecond, &filler_ctx, on_timeout_burst)
	}

	ctx: Writev_Timeout_Context
	payload: []byte = {'e', 'x', 'p', 'i', 'r', 'e'}
	iov: [1]iovec = {{iov_base = rawptr(&payload[0]), iov_len = uint(len(payload))}}
	original_user_index := context.user_index
	context.user_index = 4102
	completion := _writev(&io, net.TCP_Socket(-1), iov[:], &ctx, writev_timeout_on_sent, all = true, timeout = time.Millisecond * 10)
	context.user_index = original_user_index
	expect(t, queue.len(io.unqueued) == 1, "timed writev should begin deferred")
	completion.start_time = time.to_unix_nanoseconds(ulid.time_now_monotonic()) - i64(20 * time.Millisecond)

	expect(t, submit_all_pending(&io) == .NONE, "expired deferred writev should leave submission queues cleanly")
	expect(t, queue.len(io.unqueued) == 0, "expired writev should leave the deferred queue")
	expect(t, queue.len(io.completed) == 1, "expired writev should await the normal callback wave")
	expect(t, queue.front_ptr(&io.completed)^ == completion, "completed queue should retain the deferred writev completion")
	expect(t, ctx.callback_count == 0, "submission-only drain must not invoke the expired writev callback")

	context.user_index = -1
	run_completed_callbacks(&io)
	context.user_index = original_user_index
	expect(t, ctx.callback_count == 1 && ctx.timed_out && !ctx.failed, "deferred writev should report timeout exactly once")
	expect(t, ctx.sent == 0, "deferred writev timeout should preserve zero progress")
	expect(t, ctx.callback_user_index == 4102, "deferred writev callback should restore its captured context")
	expect(t, queue.len(io.completed) == 0, "writev callback wave should consume the completed entry")

	drain_and_expect_empty(t, &io)
	expect(t, filler_ctx.callback_count == 7, "all SQ-filling timeouts should complete")
	expect(t, ctx.callback_count == 1, "draining must not repeat the expired writev callback")
}

@(test)
test_small_ring_defers_and_resumes_timeout_burst :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io, ring_entries = 8)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init small ring error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("small-ring listen error: %v", listen_err))

	ctx: Timeout_Burst_Context
	close_ctx: Close_Pending_Recv_Context
	timeout_count :: 64
	handles: [timeout_count]^Completion
	for i in 0 ..< timeout_count {
		duration := i == 0 ? time.Second * 10 : time.Millisecond
		handles[i] = timeout(&io, duration, &ctx, on_timeout_burst)
	}
	close_handle := close(&io, server_sock, &close_ctx, close_pending_recv_on_close)

	before := get_stats(&io)
	expect(t, before.ring_depth == 8, fmt.tprintf("small ring depth mismatch: %d", before.ring_depth))
	expect(t, before.unqueued_depth > 0, "timeout burst should overflow into deferred queue")
	expect(t, num_waiting(&io) == timeout_count + 1, fmt.tprintf("timeout burst pending mismatch: %d", num_waiting(&io)))

	// Remove a timeout from the middle of the deferred FIFO. Cancellation must
	// preserve survivor order and deliver the callback in the normal callback wave.
	canceled_index :: 32
	cancel(&io, handles[canceled_index])
	expect(t, ctx.callback_count == 0, "deferred cancellation callback must not run synchronously")
	expect(t, num_waiting(&io) == timeout_count + 1, fmt.tprintf("deferred cancellation should remain pending until callback: %d", num_waiting(&io)))
	after_cancel := get_stats(&io)
	expect(
		t,
		after_cancel.unqueued_depth == before.unqueued_depth - 1,
		fmt.tprintf("deferred cancellation queue depth mismatch: before=%d after=%d", before.unqueued_depth, after_cancel.unqueued_depth),
	)

	deferred_count := queue.len(io.unqueued)
	expected_index := 8
	for position in 0 ..< deferred_count {
		deferred := queue.pop_front(&io.unqueued)
		if expected_index == canceled_index {
			expected_index += 1
		}
		if expected_index < timeout_count {
			expect(t, deferred == handles[expected_index], fmt.tprintf("deferred FIFO order mismatch at position %d", position))
			expected_index += 1
		} else {
			expect(t, deferred == close_handle, "deferred close should remain at FIFO tail")
		}
		queue.push_back(&io.unqueued, deferred)
	}
	run_completed_callbacks(&io)
	expect(t, ctx.callback_count == 1, fmt.tprintf("deferred cancellation callback count mismatch: %d", ctx.callback_count))
	expect(t, num_waiting(&io) == timeout_count, fmt.tprintf("deferred cancellation pending mismatch: %d", num_waiting(&io)))

	// The first timeout occupies the already-full prepared SQ. Cancellation must
	// submit that SQ wave, enqueue TIMEOUT_REMOVE, and complete promptly rather
	// than waiting for the ten-second natural expiry.
	cancel(&io, handles[0])
	expect(t, ctx.callback_count == 1, "prepared-SQ cancellation callback must remain asynchronous")

	run_start := time.now()
	for (ctx.callback_count < timeout_count || !close_ctx.close_done) && time.since(run_start) < time.Second * 2 {
		terr := tick(&io, time.Millisecond)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error draining small-ring burst: %v", terr))
	}

	expect(t, ctx.callback_count == timeout_count, fmt.tprintf("small-ring callback count mismatch: got=%d expected=%d", ctx.callback_count, timeout_count))
	expect(t, close_ctx.close_done, "deferred close callback did not fire")
	expect(t, close_ctx.close_succeeded, "deferred close reported failure")
	expect(t, close_ctx.close_callback_count == 1, fmt.tprintf("deferred close callback count mismatch: %d", close_ctx.close_callback_count))
	drain_and_expect_empty(t, &io)
	after := get_stats(&io)
	expect(t, after.unqueued_depth == 0, fmt.tprintf("small-ring deferred queue not drained: %d", after.unqueued_depth))
}

@(test)
test_init_rejects_invalid_exact_ring_size :: proc(t: ^testing.T) {
	io: IO
	err := init(&io, ring_entries = 7)
	expect(t, err == .EINVAL, fmt.tprintf("invalid exact ring size should return EINVAL: %v", err))

	post_pool_io: IO
	post_pool_err := init(&post_pool_io, ring_entries = 8192)
	expect(t, post_pool_err == .EINVAL, fmt.tprintf("oversized exact ring should return EINVAL after setup validation: %v", post_pool_err))
}

@(test)
test_randomized_mixed_workload_seeded :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	perr := pbuf_ring_init(&io)
	expect(t, perr == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", perr))
	defer pbuf_ring_destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx := Workload_Context {
		io = &io,
	}
	accept(&io, server_sock, &ctx, workload_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !ctx.accepted && !ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, ctx.accepted, "workload accept did not complete")
	expect(t, !ctx.failed, "workload accept/recv failed early")

	seed: u64 = WORKLOAD_DEFAULT_SEED
	seed_initial := seed
	expected_bytes := 0
	expected_timeouts := 0
	iterations :: 220

	for _ in 0 ..< iterations {
		r := next_rand_u64(&seed)
		op := r % 3

		if op == 0 {
			payload_len := int(r % 48) + 1
			payload: [64]byte
			for i in 0 ..< payload_len {
				payload[i] = byte((r >> (u64(i % 8) * 8)) & 0xff)
			}

			n_sent, send_err := net.send_tcp(client_sock, payload[:payload_len])
			expect(t, send_err == nil, fmt.tprintf("net.send_tcp error during workload: %v", send_err))
			expect(t, n_sent == payload_len, "workload client send short write")
			expected_bytes += payload_len
		} else if op == 1 {
			timeout_ms := time.Duration(int(r % 5) + 1)
			timeout(&io, timeout_ms * time.Millisecond, &ctx, workload_on_timeout)
			expected_timeouts += 1
		}

		tick_ms := time.Duration(int((r >> 8) % 3) + 1)
		terr := tick(&io, tick_ms * time.Millisecond)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during workload: %v", terr))
		expect(t, !ctx.failed, "workload recv callback failed")
	}

	drain_start := time.now()
	for (!ctx.failed) && (ctx.bytes_received < expected_bytes || ctx.timeouts_fired < expected_timeouts) && time.since(drain_start) < time.Second * 4 {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during workload drain: %v", terr))
	}

	expect(t, !ctx.failed, "workload failed during drain")
	expect(
		t,
		ctx.bytes_received == expected_bytes,
		fmt.tprintf("workload bytes mismatch: got=%d expected=%d seed=0x%x", ctx.bytes_received, expected_bytes, seed_initial),
	)
	expect(
		t,
		ctx.timeouts_fired == expected_timeouts,
		fmt.tprintf("workload timeouts mismatch: got=%d expected=%d seed=0x%x", ctx.timeouts_fired, expected_timeouts, seed_initial),
	)

	net.close(ctx.accepted_sock)
}

@(test)
test_writev_all_timeout_partial_progress :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Writev_Timeout_Context
	accept(&io, server_sock, &ctx, writev_timeout_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !ctx.accepted && !ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, ctx.accepted, "writev timeout test did not accept client")

	// Keep the first entry tiny so any meaningful partial socket write must cross
	// an iovec boundary before the deliberately blocked peer causes a timeout.
	part_a := make([]byte, 17)
	defer delete(part_a)
	part_b := make([]byte, 8 * 1024 * 1024)
	defer delete(part_b)

	for i in 0 ..< len(part_a) {
		part_a[i] = byte(i & 0xff)
	}
	for i in 0 ..< len(part_b) {
		part_b[i] = byte((i * 3) & 0xff)
	}

	iov: [2]iovec
	iov[0] = iovec {
		iov_base = rawptr(&part_a[0]),
		iov_len  = uint(len(part_a)),
	}
	iov[1] = iovec {
		iov_base = rawptr(&part_b[0]),
		iov_len  = uint(len(part_b)),
	}
	ctx.total = len(part_a) + len(part_b)

	writev_all_tcp_timeout(&io, ctx.accepted_sock, iov[:], time.Millisecond, &ctx, writev_timeout_on_sent)

	run_start := time.now()
	for !ctx.done && !ctx.failed && time.since(run_start) < time.Second * 3 {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}

	expect(t, ctx.done, "writev timeout callback did not fire")
	expect(t, !ctx.failed, "writev timeout callback returned unexpected error")
	expect(t, ctx.timed_out, "writev timeout was expected but not observed")
	expect(t, ctx.callback_count == 1, fmt.tprintf("writev timeout callback count mismatch: %d", ctx.callback_count))
	expect(t, ctx.sent > 0, "writev timeout should report partial progress")
	expect(t, ctx.sent < ctx.total, "writev timeout should not report full send")
	expect(t, ctx.sent > len(part_a), fmt.tprintf("writev partial progress should cross the first iovec boundary: sent=%d boundary=%d", ctx.sent, len(part_a)))
	expect(t, iov[0].iov_len == uint(len(part_a)), "fully consumed iovec metadata should remain stable")
	expected_remaining := len(part_b) - (ctx.sent - len(part_a))
	expect(t, iov[1].iov_len == uint(expected_remaining), fmt.tprintf("second iovec remaining length mismatch: got=%d sent=%d", iov[1].iov_len, ctx.sent))
	expect(
		t,
		uintptr(iov[1].iov_base) == uintptr(rawptr(&part_b[0])) + uintptr(ctx.sent - len(part_a)),
		"second iovec base did not advance by partial progress",
	)

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_writev_iov_cursor_repeated_partial_progress :: proc(t: ^testing.T) {
	part_a: [13]byte
	part_b: [11]byte
	part_c: [17]byte
	iov: [3]iovec = {
		{iov_base = rawptr(&part_a[0]), iov_len = uint(len(part_a))},
		{iov_base = rawptr(&part_b[0]), iov_len = uint(len(part_b))},
		{iov_base = rawptr(&part_c[0]), iov_len = uint(len(part_c))},
	}
	op := Op_Writev {
		iov = iov[:],
		len = len(part_a) + len(part_b) + len(part_c),
		all = true,
	}

	// First retry ends inside the first iovec.
	writev_advance_iov(&op, 7)
	expect(t, op.iov_offset == 0, fmt.tprintf("first partial offset mismatch: %d", op.iov_offset))
	expect(t, iov[0].iov_len == 6, fmt.tprintf("first partial remaining mismatch: %d", iov[0].iov_len))
	expect(t, uintptr(iov[0].iov_base) == uintptr(rawptr(&part_a[0])) + 7, "first partial base mismatch")

	// A second retry consumes the rest of the first entry and enters the second.
	writev_advance_iov(&op, 10)
	expect(t, op.iov_offset == 1, fmt.tprintf("cross-boundary offset mismatch: %d", op.iov_offset))
	expect(t, iov[1].iov_len == 7, fmt.tprintf("second iovec remaining mismatch: %d", iov[1].iov_len))
	expect(t, uintptr(iov[1].iov_base) == uintptr(rawptr(&part_b[0])) + 4, "second iovec base mismatch")

	// A third retry crosses another boundary and leaves the final entry active.
	writev_advance_iov(&op, 9)
	expect(t, op.iov_offset == 2, fmt.tprintf("second boundary offset mismatch: %d", op.iov_offset))
	expect(t, iov[2].iov_len == 15, fmt.tprintf("final iovec remaining mismatch: %d", iov[2].iov_len))
	expect(t, uintptr(iov[2].iov_base) == uintptr(rawptr(&part_c[0])) + 2, "final iovec base mismatch")
}

@(test)
test_writev_all_peer_close_after_partial_progress :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Writev_Peer_Close_Context
	accept(&io, server_sock, &ctx, writev_peer_close_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))

	accept_start := time.now()
	for !ctx.accepted && !ctx.done && time.since(accept_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during accept: %v", terr))
	}
	expect(t, ctx.accepted, "writev peer-close test did not accept client")

	part_a: [17]byte
	part_b := make([]byte, 8 * 1024 * 1024)
	defer delete(part_b)
	for i in 0 ..< len(part_a) {
		part_a[i] = byte(i)
	}
	for i in 0 ..< len(part_b) {
		part_b[i] = byte((i * 5) & 0xff)
	}

	iov: [2]iovec = {{iov_base = rawptr(&part_a[0]), iov_len = uint(len(part_a))}, {iov_base = rawptr(&part_b[0]), iov_len = uint(len(part_b))}}
	completion := _writev(&io, ctx.accepted_sock, iov[:], &ctx, writev_peer_close_on_sent, all = true)

	progress_start := time.now()
	for !ctx.done && completion.operation.(Op_Writev).sent <= len(part_a) && time.since(progress_start) < time.Second {
		terr := tick(&io, time.Millisecond)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error awaiting partial write: %v", terr))
	}
	if ctx.done {
		expect(t, false, "writev unexpectedly completed before peer close")
		net.close(client_sock)
		net.close(ctx.accepted_sock)
		drain_and_expect_empty(t, &io)
		return
	}
	partial_sent := completion.operation.(Op_Writev).sent
	if partial_sent <= len(part_a) {
		expect(t, false, fmt.tprintf("writev did not cross iovec boundary before peer close: sent=%d", partial_sent))
		net.close(client_sock)
		net.close(ctx.accepted_sock)
		drain_and_expect_empty(t, &io)
		return
	}

	net.close(client_sock)
	settle_start := time.now()
	for !ctx.done && time.since(settle_start) < time.Second * 3 {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error after peer close: %v", terr))
	}

	expect(t, ctx.done, "writev peer-close callback did not fire")
	expect(t, ctx.saw_error, "writev peer-close callback should report an error")
	expect(t, ctx.callback_count == 1, fmt.tprintf("writev peer-close callback count mismatch: %d", ctx.callback_count))
	expect(t, ctx.sent >= partial_sent, fmt.tprintf("writev peer-close progress regressed: callback=%d observed=%d", ctx.sent, partial_sent))
	expect(t, ctx.sent < len(part_a) + len(part_b), "writev peer-close unexpectedly reported full success progress")

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_recv_provided_all_assembles_until_threshold :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	perr := pbuf_ring_init(&io)
	expect(t, perr == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", perr))
	defer pbuf_ring_destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx := Recv_All_Context {
		io = &io,
	}
	accept(&io, server_sock, &ctx, recv_all_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !ctx.accepted && !ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, ctx.accepted, "recv_all test did not accept client")

	recv_provided(&io, ctx.accepted_sock, &ctx, recv_all_on_recv, true)

	total_sent := 0
	chunk: [512]byte
	start_send := time.now()
	for !ctx.done && !ctx.failed && time.since(start_send) < time.Second * 2 {
		for i in 0 ..< len(chunk) {
			chunk[i] = byte((total_sent + i) & 0xff)
		}

		n_sent, send_err := net.send_tcp(client_sock, chunk[:])
		expect(t, send_err == nil, fmt.tprintf("net.send_tcp error in recv_all test: %v", send_err))
		expect(t, n_sent == len(chunk), "recv_all client send short write")
		total_sent += n_sent

		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in recv_all test: %v", terr))
	}

	expect(t, ctx.done, "recv_provided(all=true) callback did not fire")
	expect(t, !ctx.failed, "recv_provided(all=true) failed")
	expect(t, ctx.callback_count == 1, "recv_provided(all=true) callback count mismatch")
	expect(t, ctx.received == total_sent, fmt.tprintf("recv_provided(all=true) byte mismatch: got=%d sent=%d", ctx.received, total_sent))
	expect(t, ctx.received >= int(BUFFER_SIZE), "recv_provided(all=true) did not accumulate to buffer threshold")
	for i in 0 ..< ctx.received {
		expected := byte(i & 0xff)
		expect(
			t,
			ctx.payload_copy[i] == expected,
			fmt.tprintf("recv_provided(all=true) payload mismatch at byte %d: got=%d expected=%d", i, ctx.payload_copy[i], expected),
		)
	}

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_recv_provided_all_partial_then_close :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	perr := pbuf_ring_init(&io)
	expect(t, perr == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", perr))
	defer pbuf_ring_destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	accept_ctx := Recv_All_Context {
		io = &io,
	}
	accept(&io, server_sock, &accept_ctx, recv_all_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))

	start_accept := time.now()
	for !accept_ctx.accepted && !accept_ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, accept_ctx.accepted, "recv_all partial-close test did not accept client")

	ctx: Recv_All_Partial_Close_Context
	recv_provided(&io, accept_ctx.accepted_sock, &ctx, recv_all_partial_close_on_recv, true)

	partial_len := int(BUFFER_SIZE) / 2 + 17
	payload := make([]byte, partial_len)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = byte((i * 9) & 0xff)
	}

	sent := 0
	for sent < len(payload) {
		n_sent, send_err := net.send_tcp(client_sock, payload[sent:])
		expect(t, send_err == nil, fmt.tprintf("net.send_tcp error in partial-close test: %v", send_err))
		expect(t, n_sent > 0, "partial-close send made no progress")
		sent += n_sent
	}
	net.close(client_sock)

	run_start := time.now()
	for !ctx.done && !ctx.failed && time.since(run_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in partial-close test: %v", terr))
	}

	expect(t, ctx.done, "recv_provided(all=true) partial-close callback did not fire")
	expect(t, !ctx.failed, "recv_provided(all=true) partial-close callback failed")
	expect(t, ctx.callback_count == 1, fmt.tprintf("partial-close callback count mismatch: %d", ctx.callback_count))
	expect(t, ctx.saw_error, "partial-close callback should report an error")
	expect(t, ctx.received == partial_len, fmt.tprintf("partial-close received mismatch: got=%d expected=%d", ctx.received, partial_len))
	for i in 0 ..< partial_len {
		expect(t, ctx.payload_copy[i] == payload[i], fmt.tprintf("partial-close payload mismatch at byte %d", i))
	}

	net.close(accept_ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_writev_all_boundary_data_integrity :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Writev_Boundary_Context
	accept(&io, server_sock, &ctx, writev_boundary_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	nb_err := net.set_blocking(client_sock, false)
	expect(t, nb_err == nil, fmt.tprintf("net.set_blocking error: %v", nb_err))

	start_accept := time.now()
	for !ctx.accepted && !ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, ctx.accepted, "writev boundary test did not accept client")

	part_a := make([]byte, 65537)
	defer delete(part_a)
	part_b := make([]byte, 131071)
	defer delete(part_b)
	part_c := make([]byte, 98317)
	defer delete(part_c)

	for i in 0 ..< len(part_a) {
		part_a[i] = byte((i * 1) & 0xff)
	}
	for i in 0 ..< len(part_b) {
		part_b[i] = byte((i * 3) & 0xff)
	}
	for i in 0 ..< len(part_c) {
		part_c[i] = byte((i * 7) & 0xff)
	}

	total := len(part_a) + len(part_b) + len(part_c)
	expected := make([]byte, total)
	defer delete(expected)
	copy(expected[:len(part_a)], part_a)
	copy(expected[len(part_a):len(part_a) + len(part_b)], part_b)
	copy(expected[len(part_a) + len(part_b):], part_c)

	iov: [3]iovec
	iov[0] = iovec {
		iov_base = rawptr(&part_a[0]),
		iov_len  = uint(len(part_a)),
	}
	iov[1] = iovec {
		iov_base = rawptr(&part_b[0]),
		iov_len  = uint(len(part_b)),
	}
	iov[2] = iovec {
		iov_base = rawptr(&part_c[0]),
		iov_len  = uint(len(part_c)),
	}

	writev_all_tcp(&io, ctx.accepted_sock, iov[:], &ctx, writev_boundary_on_sent)

	received := make([]byte, total)
	defer delete(received)
	recv_total := 0

	run_start := time.now()
	for (!ctx.done || recv_total < total) && !ctx.failed && time.since(run_start) < time.Second * 5 {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in writev boundary test: %v", terr))

		if recv_total >= total {
			continue
		}

		n_recv, recv_err := net.recv_tcp(client_sock, received[recv_total:])
		if recv_err == nil {
			recv_total += n_recv
			continue
		}

		#partial switch recv_err {
		case .Would_Block:
		case .Connection_Closed:
			if !ctx.done {
				expect(t, false, "writev boundary connection closed before send completion")
			}
		case:
			expect(t, false, fmt.tprintf("unexpected net.recv_tcp error in writev boundary test: %v", recv_err))
		}
	}

	expect(t, !ctx.failed, "writev boundary send callback failed")
	expect(t, ctx.done, "writev boundary send callback did not fire")
	expect(t, ctx.callback_count == 1, fmt.tprintf("writev boundary callback count mismatch: %d", ctx.callback_count))
	expect(t, ctx.sent == total, fmt.tprintf("writev boundary sent mismatch: got=%d expected=%d", ctx.sent, total))
	expect(t, recv_total == total, fmt.tprintf("writev boundary recv mismatch: got=%d expected=%d", recv_total, total))

	for i in 0 ..< total {
		expect(t, received[i] == expected[i], fmt.tprintf("writev boundary payload mismatch at byte %d", i))
	}

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_shutdown_send_reports_peer_eof :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Shutdown_Context
	accept(&io, server_sock, &ctx, shutdown_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	nb_err := net.set_blocking(client_sock, false)
	expect(t, nb_err == nil, fmt.tprintf("net.set_blocking error: %v", nb_err))

	accept_start := time.now()
	for !ctx.accepted && !ctx.shutdown_failed && time.since(accept_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while waiting for accept: %v", terr))
	}
	expect(t, ctx.accepted, "shutdown test did not accept client")

	shutdown(&io, ctx.accepted_sock, .Send, &ctx, shutdown_on_complete)

	shutdown_start := time.now()
	for !ctx.shutdown_done && !ctx.shutdown_failed && time.since(shutdown_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while waiting for shutdown: %v", terr))
	}

	expect(t, ctx.shutdown_done, "shutdown callback did not fire")
	expect(t, !ctx.shutdown_failed, "shutdown callback reported failure")
	expect(t, ctx.callback_count == 1, fmt.tprintf("shutdown callback count mismatch: %d", ctx.callback_count))

	recv_buf: [16]byte
	saw_eof := false
	saw_unexpected_result := false
	eof_wait_start := time.now()
	for !saw_eof && !saw_unexpected_result && time.since(eof_wait_start) < time.Second {
		n_recv, recv_err := net.recv_tcp(client_sock, recv_buf[:])
		if recv_err == nil {
			if n_recv == 0 {
				saw_eof = true
			} else {
				saw_unexpected_result = true
			}
			continue
		}

		#partial switch recv_err {
		case .Would_Block:
			terr := tick(&io, time.Millisecond * 2)
			expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while waiting for peer EOF: %v", terr))
		case:
			saw_unexpected_result = true
		}
	}

	expect(t, !saw_unexpected_result, "client observed unexpected recv result after shutdown(Send)")
	expect(t, saw_eof, "client did not observe EOF after shutdown(Send)")

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

@(test)
test_shutdown_retires_pending_recv_before_close :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)
	pbuf_err := pbuf_ring_init(&io)
	expect(t, pbuf_err == .NONE, fmt.tprintf("nbio.pbuf_ring_init error: %v", pbuf_err))

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Close_Pending_Recv_Context
	accept(&io, server_sock, &ctx, close_pending_recv_on_accept)
	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	accept_start := time.now()
	for !ctx.accepted && time.since(accept_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error during accept: %v", terr))
	}
	expect(t, ctx.accepted, "pending-recv close test did not accept client")

	recv_provided(&io, ctx.accepted_sock, &ctx, close_pending_recv_on_recv)
	terr := tick(&io, time.Millisecond)
	expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while submitting recv: %v", terr))
	expect(t, !ctx.recv_done, "recv unexpectedly completed before shutdown")

	shutdown(&io, ctx.accepted_sock, .Both)
	settle_start := time.now()
	for !ctx.recv_done && time.since(settle_start) < time.Second {
		terr = tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while retiring pending recv: %v", terr))
	}

	expect(t, ctx.recv_done, "pending recv callback did not fire after shutdown")
	expect(t, ctx.recv_saw_error, "pending recv should report an error after shutdown")
	expect(t, ctx.recv_callback_count == 1, fmt.tprintf("pending recv callback count mismatch: %d", ctx.recv_callback_count))

	close(&io, ctx.accepted_sock, &ctx, close_pending_recv_on_close)
	close_start := time.now()
	for !ctx.close_done && time.since(close_start) < time.Second {
		terr = tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while closing retired socket: %v", terr))
	}
	expect(t, ctx.close_done, "asynchronous close callback did not fire")
	expect(t, ctx.close_succeeded, "asynchronous close reported failure")
	expect(t, ctx.close_callback_count == 1, fmt.tprintf("close callback count mismatch: %d", ctx.close_callback_count))
	drain_and_expect_empty(t, &io)
}

@(test)
test_stats_sanity_after_work :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	before := get_stats(&io)
	expect(t, before.ring_depth > 0, "stats ring depth should be positive")

	timeout_count :: 32
	timeout_ctx: Timeout_Burst_Context
	for _ in 0 ..< timeout_count {
		timeout(&io, time.Millisecond * 5, &timeout_ctx, on_timeout_burst)
	}

	timeout_start := time.now()
	for timeout_ctx.callback_count < timeout_count && time.since(timeout_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in stats timeout phase: %v", terr))
	}
	expect(t, timeout_ctx.callback_count == timeout_count, "stats timeout phase did not complete")

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	send_ctx: Stats_Send_Context
	accept(&io, server_sock, &send_ctx, stats_send_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	accept_start := time.now()
	for !send_ctx.accepted && !send_ctx.failed && time.since(accept_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in stats accept phase: %v", terr))
	}
	expect(t, send_ctx.accepted, "stats send phase did not accept client")

	payload: []byte = {'s', 't', 'a', 't', 's', '-', 's', 'e', 'n', 'd'}
	send_all(&io, send_ctx.accepted_sock, payload, &send_ctx, stats_send_on_sent)

	send_start := time.now()
	for !send_ctx.done && !send_ctx.failed && time.since(send_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error in stats send phase: %v", terr))
	}
	expect(t, send_ctx.done, "stats send callback did not fire")
	expect(t, !send_ctx.failed, "stats send callback failed")

	recv_buf: [64]byte
	n_recv, recv_err := net.recv_tcp(client_sock, recv_buf[:])
	expect(t, recv_err == nil, fmt.tprintf("net.recv_tcp error in stats send phase: %v", recv_err))
	expect(t, n_recv == len(payload), "stats send payload size mismatch")

	net.close(send_ctx.accepted_sock)
	drain_and_expect_empty(t, &io)

	after := get_stats(&io)
	when ENABLE_STATS {
		expect(
			t,
			after.total_completions >= before.total_completions + u64(timeout_count + 2),
			fmt.tprintf("stats total_completions did not increase enough: before=%d after=%d", before.total_completions, after.total_completions),
		)
		expect(
			t,
			after.latency_sample_count >= before.latency_sample_count + 1,
			fmt.tprintf("stats latency_sample_count did not increase: before=%d after=%d", before.latency_sample_count, after.latency_sample_count),
		)
	} else {
		expect(t, after.total_completions == 0, fmt.tprintf("disabled completion stats changed: %d", after.total_completions))
		expect(t, after.latency_sample_count == 0, fmt.tprintf("disabled latency stats changed: %d", after.latency_sample_count))
	}
	expect(t, after.unqueued_depth == 0, fmt.tprintf("stats unqueued_depth not drained: %d", after.unqueued_depth))
	expect(t, after.ring_depth > 0, "stats ring_depth must stay positive")
	expect(
		t,
		after.ring_available <= after.ring_depth,
		fmt.tprintf("stats ring_available invalid: available=%d depth=%d", after.ring_available, after.ring_depth),
	)
}

// time_spec_to_ns folds a linux.Time_Spec back into a single nanosecond budget so
// the deadline-clamp tests can compare remaining budgets with simple integer math.
time_spec_to_ns :: proc(ts: linux.Time_Spec) -> i64 {
	return i64(ts.time_sec) * i64(NANOSECONDS_PER_SECOND) + i64(ts.time_nsec)
}

// Unit test for the core remaining-budget math behind the send/writev deadline
// fix. io_uring linked timeouts are per-SQE, so without clamping each re-enqueue
// (partial send / EWOULDBLOCK retry) would get a fresh full-budget timeout,
// letting a stalled peer pin a send for N * timeout. clamp_remaining_send_timeout
// must instead return the *remaining* budget (full_timeout - elapsed) and report
// exhaustion once the deadline passes.
@(test)
test_clamp_remaining_send_timeout_semantics :: proc(t: ^testing.T) {
	full_budget: i64 = 100 * i64(time.Millisecond)

	// start_time <= 0 means "no deadline tracked": helper is a no-op and leaves
	// the spec untouched (sampling-only sends take this path).
	spec_untouched := linux.Time_Spec {
		time_sec  = 7,
		time_nsec = 7,
	}
	expect(t, clamp_remaining_send_timeout(0, full_budget, &spec_untouched), "no-deadline clamp should report time remaining")
	expect(t, spec_untouched.time_sec == 7 && spec_untouched.time_nsec == 7, "no-deadline clamp must not modify the timeout spec")

	// Simulate an operation that started in the past by anchoring start_time
	// relative to the current monotonic clock. As "elapsed" grows the remaining
	// budget must shrink monotonically and stay strictly below the full budget.
	now := time.to_unix_nanoseconds(ulid.time_now_monotonic())

	elapsed_a: i64 = 10 * i64(time.Millisecond)
	spec_a := linux.Time_Spec{}
	ok_a := clamp_remaining_send_timeout(now - elapsed_a, full_budget, &spec_a)
	expect(t, ok_a, "clamp with budget remaining should report time remaining")
	remaining_a := time_spec_to_ns(spec_a)
	expect(t, remaining_a < full_budget, fmt.tprintf("clamped budget must be below full budget: remaining=%d full=%d", remaining_a, full_budget))
	expect(t, remaining_a > 0, fmt.tprintf("clamped budget must be positive while time remains: remaining=%d", remaining_a))

	// A larger elapsed must yield a strictly smaller remaining budget: this is the
	// property that prevents the "fresh full timeout per retry" bug.
	elapsed_b: i64 = 60 * i64(time.Millisecond)
	spec_b := linux.Time_Spec{}
	ok_b := clamp_remaining_send_timeout(now - elapsed_b, full_budget, &spec_b)
	expect(t, ok_b, "clamp with smaller budget remaining should still report time remaining")
	remaining_b := time_spec_to_ns(spec_b)
	expect(t, remaining_b < remaining_a, fmt.tprintf("remaining budget must shrink as elapsed grows: remaining_b=%d remaining_a=%d", remaining_b, remaining_a))

	// Once elapsed meets or exceeds the full budget, the helper must report
	// exhaustion (false) so the caller completes the op with .Timeout instead of
	// re-enqueuing with another full-budget linked timeout.
	spec_exhausted := linux.Time_Spec{}
	elapsed_exhausted := full_budget + 5 * i64(time.Millisecond)
	expect(t, !clamp_remaining_send_timeout(now - elapsed_exhausted, full_budget, &spec_exhausted), "clamp past the deadline must report exhaustion")
}

// Drives send_callback through one injected EWOULDBLOCK, then lets its sole
// re-enqueued SQE complete through the kernel. Repeated budget shrinking is
// covered by test_clamp_remaining_send_timeout_semantics without creating
// multiple simultaneous SQEs that target one Completion.
@(test)
test_send_timeout_budget_clamped_on_retry :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Send_Timeout_Guard_Context
	accept(&io, server_sock, &ctx, send_timeout_guard_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !ctx.accepted && !ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, ctx.accepted, "retry-budget test did not accept client")

	full_budget: i64 = 500 * i64(time.Millisecond)
	payload: []byte = {'r', 'e', 't', 'r', 'y', '-', 'b', 'u', 'd', 'g', 'e', 't'}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = &ctx
	completion.operation = Op_Send {
		callback     = send_timeout_guard_on_sent,
		socket       = ctx.accepted_sock,
		buf          = payload,
		len          = len(payload),
		sent         = 0,
		all          = true,
		timeout_nsec = full_budget,
		timeout_spec = linux.Time_Spec{},
	}
	op := &completion.operation.(Op_Send)

	// Anchor the operation start time 100ms in the past so the first retry has a
	// clearly-reduced remaining budget. clamp_remaining_send_timeout reads
	// completion.start_time on every retry.
	first_elapsed: i64 = 100 * i64(time.Millisecond)
	completion.start_time = time.to_unix_nanoseconds(ulid.time_now_monotonic()) - first_elapsed

	// First injected EWOULDBLOCK: should clamp (not reset) and re-enqueue.
	completion.result = -i32(linux.Errno.EWOULDBLOCK)
	send_callback(&io, completion, op)

	expect(t, ctx.callback_count == 0, "send retry should not fire callback while budget remains")
	expect(t, num_waiting(&io) == 1, fmt.tprintf("send retry should leave completion pending, waiting=%d", num_waiting(&io)))
	remaining_first := time_spec_to_ns(op.timeout_spec)
	expect(
		t,
		remaining_first < full_budget,
		fmt.tprintf("first retry must clamp below full budget (no reset): remaining=%d full=%d", remaining_first, full_budget),
	)
	expect(t, remaining_first > 0, fmt.tprintf("first retry budget should be positive: remaining=%d", remaining_first))

	run_start := time.now()
	for !ctx.done && time.since(run_start) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error while completing send retry: %v", terr))
	}
	expect(t, ctx.done, "re-enqueued send did not complete")
	expect(t, !ctx.timed_out, "re-enqueued send unexpectedly timed out")
	expect(t, !ctx.failed, "re-enqueued send reported an error")
	expect(t, ctx.callback_count == 1, fmt.tprintf("send retry callback count mismatch: %d", ctx.callback_count))
	expect(t, ctx.sent == len(payload), fmt.tprintf("send retry byte count mismatch: got=%d expected=%d", ctx.sent, len(payload)))

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

// Confirms an already-exhausted deadline on the writev retry path completes once
// with .Timeout rather than re-arming another full-budget linked timeout.
@(test)
test_writev_timeout_deadline_exhausted_fires_once :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	defer destroy(&io)

	server_sock, listen_err := open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	expect(t, listen_err == nil, fmt.tprintf("nbio.open_and_listen_tcp error: %v", listen_err))
	defer net.close(server_sock)

	server_ep, ep_err := net.bound_endpoint(server_sock)
	expect(t, ep_err == nil, fmt.tprintf("net.bound_endpoint error: %v", ep_err))

	ctx: Writev_Timeout_Context
	accept(&io, server_sock, &ctx, writev_timeout_on_accept)

	client_sock, dial_err := net.dial_tcp_from_endpoint(server_ep)
	expect(t, dial_err == nil, fmt.tprintf("net.dial_tcp_from_endpoint error: %v", dial_err))
	defer net.close(client_sock)

	start_accept := time.now()
	for !ctx.accepted && !ctx.failed && time.since(start_accept) < time.Second {
		terr := tick(&io, time.Millisecond * 2)
		expect(t, terr == .NONE, fmt.tprintf("nbio.tick error: %v", terr))
	}
	expect(t, ctx.accepted, "writev exhausted-deadline test did not accept client")

	full_budget: i64 = 250 * i64(time.Millisecond)
	part := make([]byte, 4096)
	defer delete(part)
	for i in 0 ..< len(part) {
		part[i] = byte(i & 0xff)
	}

	iov: [1]iovec
	iov[0] = iovec {
		iov_base = rawptr(&part[0]),
		iov_len  = uint(len(part)),
	}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = &ctx
	completion.operation = Op_Writev {
		callback     = writev_timeout_on_sent,
		socket       = ctx.accepted_sock,
		iov          = iov[:],
		iov_offset   = 0,
		len          = len(part),
		sent         = 0,
		all          = true,
		timeout_nsec = full_budget,
		timeout_spec = linux.Time_Spec{},
	}
	ctx.total = len(part)
	op := &completion.operation.(Op_Writev)

	// Record start time well beyond the budget so the very first EWOULDBLOCK retry
	// observes an exhausted deadline.
	completion.start_time = time.to_unix_nanoseconds(ulid.time_now_monotonic()) - (full_budget + 20 * i64(time.Millisecond))
	completion.result = -i32(linux.Errno.EWOULDBLOCK)
	writev_callback(&io, completion, op)

	expect(t, ctx.done, "exhausted writev deadline should complete the operation")
	expect(t, ctx.timed_out, "exhausted writev deadline should report .Timeout")
	expect(t, !ctx.failed, "exhausted writev deadline should not report a non-timeout error")
	expect(t, ctx.callback_count == 1, fmt.tprintf("exhausted writev deadline should fire callback exactly once: %d", ctx.callback_count))
	expect(t, num_waiting(&io) == 0, fmt.tprintf("exhausted writev deadline should not leave completions pending: %d", num_waiting(&io)))

	net.close(ctx.accepted_sock)
	drain_and_expect_empty(t, &io)
}

P3_Scratch_Batch_Context :: struct {
	callbacks:       int,
	accept_error:    net.Network_Error,
	close_ok:        bool,
	shutdown_error:  net.Shutdown_Error,
	recv_error:      net.Network_Error,
	recv_count:      int,
	recv_buf_nil:    bool,
	send_error:      net.Network_Error,
	send_progress:   int,
	writev_error:    net.Network_Error,
	writev_progress: int,
	timeouts:        int,
}

p3_scratch_accept :: proc(user: rawptr, _: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^P3_Scratch_Batch_Context)user; ctx.callbacks += 1; ctx.accept_error = err
}
p3_scratch_close :: proc(user: rawptr, ok: bool) {
	ctx := cast(^P3_Scratch_Batch_Context)user; ctx.callbacks += 1; ctx.close_ok = ok
}
p3_scratch_shutdown :: proc(user: rawptr, err: net.Shutdown_Error) {
	ctx := cast(^P3_Scratch_Batch_Context)user; ctx.callbacks += 1; ctx.shutdown_error = err
}
p3_scratch_recv :: proc(user: rawptr, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^P3_Scratch_Batch_Context)user; ctx.callbacks += 1; ctx.recv_count = received; ctx.recv_buf_nil = buf == nil; ctx.recv_error = err
}
p3_scratch_send :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^P3_Scratch_Batch_Context)user; ctx.callbacks += 1; ctx.send_progress = sent; ctx.send_error = err
}
p3_scratch_writev :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^P3_Scratch_Batch_Context)user; ctx.callbacks += 1; ctx.writev_progress = sent; ctx.writev_error = err
}
p3_scratch_timeout :: proc(user: rawptr) {
	ctx := cast(^P3_Scratch_Batch_Context)user; ctx.callbacks += 1; ctx.timeouts += 1
}

@(test)
test_dispatch_cqe_scratch_batch_terminal_contract :: proc(t: ^testing.T) {
	io: IO
	ierr := init(&io, ring_entries = 8)
	expect(t, ierr == .NONE, fmt.tprintf("nbio.init error: %v", ierr))
	if ierr != .NONE do return
	defer destroy(&io)

	ctx: P3_Scratch_Batch_Context
	completions: [7]^Completion
	for &completion in completions {
		completion = pool_get(&io.completion_pool)
		completion.ctx = context
		completion.user_data = &ctx
	}
	completions[0].operation = Op_Accept {
		callback  = p3_scratch_accept,
		multishot = true,
	}
	completions[1].operation = Op_Close {
		callback = p3_scratch_close,
	}
	completions[2].operation = Op_Shutdown {
		callback = p3_scratch_shutdown,
	}
	completions[3].operation = Op_Recv_Provided {
		callback  = p3_scratch_recv,
		buf       = nil,
		aggregate = nil,
	}
	completions[4].operation = Op_Send {
		callback = p3_scratch_send,
		sent     = 3,
		len      = 9,
		all      = true,
	}
	iov: [2]iovec = {{iov_base = rawptr(uintptr(0x1000)), iov_len = 4}, {iov_base = rawptr(uintptr(0x2000)), iov_len = 5}}
	completions[5].operation = Op_Writev {
		callback   = p3_scratch_writev,
		iov        = iov[:],
		iov_offset = 1,
		sent       = 4,
		len        = 9,
		all        = true,
	}
	completions[6].operation = Op_Timeout {
		callback = p3_scratch_timeout,
	}

	cqes: [9]io_uring.io_uring_cqe
	cqes[0] = {
		user_data = 0,
		res       = 0,
	}
	cqes[1] = {
		user_data = CANCEL_MARKER,
		res       = -i32(linux.Errno.ENOENT),
	}
	errors := [7]linux.Errno{.ECANCELED, .EINTR, .ENOTCONN, .ECANCELED, .EPIPE, .EPIPE, .ETIME}
	for completion, index in completions {
		cqes[index + 2] = {
			user_data = u64(uintptr(completion)),
			res       = -i32(errors[index]),
		}
	}
	io.ios_in_kernel = u64(len(cqes))
	dispatch_cqe_batch(&io, cqes[:])

	expect(t, ctx.callbacks == 0, "batch dispatch must not run callbacks")
	expect(t, queue.len(io.completed) == 7, fmt.tprintf("queued primaries=%d expected=7", queue.len(io.completed)))
	expect(t, io.ios_in_kernel == 0, "batch accounting did not consume every CQE")
	expect(t, completions[5].operation.(Op_Writev).iov_offset == 1, "terminal writev error moved the cursor before callback")
	for completion, index in completions {
		queued := queue.pop_front(&io.completed)
		expect(t, queued == completion, fmt.tprintf("scratch batch order mismatch at index=%d", index))
		queue.push_back(&io.completed, queued)
	}
	run_completed_callbacks(&io)

	expect(t, ctx.callbacks == 7 && ctx.timeouts == 1, fmt.tprintf("callback wave mismatch: callbacks=%d timeouts=%d", ctx.callbacks, ctx.timeouts))
	accept_error, accept_ok := ctx.accept_error.(net.Accept_Error)
	expect(
		t,
		accept_ok && accept_error == net.Accept_Error(linux.Errno.ECANCELED),
		fmt.tprintf("multishot accept cancellation mismatch: %v", ctx.accept_error),
	)
	expect(t, ctx.close_ok, "close EINTR must be terminal success")
	expect(t, ctx.shutdown_error == .Invalid_Argument, fmt.tprintf("shutdown terminal error mismatch: %v", ctx.shutdown_error))
	recv_error, recv_ok := ctx.recv_error.(net.TCP_Recv_Error)
	expect(
		t,
		recv_ok && recv_error == .Connection_Closed && ctx.recv_count == 0 && ctx.recv_buf_nil,
		fmt.tprintf("recv cancellation result mismatch: count=%d nil=%v error=%v", ctx.recv_count, ctx.recv_buf_nil, ctx.recv_error),
	)
	send_errno, send_ok := ctx.send_error.(net.TCP_Send_Error)
	writev_errno, writev_ok := ctx.writev_error.(net.TCP_Send_Error)
	expect(
		t,
		send_ok && send_errno == net.TCP_Send_Error(.Connection_Closed) && ctx.send_progress == 3,
		fmt.tprintf("send terminal state mismatch: progress=%d error=%v", ctx.send_progress, ctx.send_error),
	)
	expect(
		t,
		writev_ok && writev_errno == net.TCP_Send_Error(.Connection_Closed) && ctx.writev_progress == 4,
		fmt.tprintf("writev terminal state mismatch: progress=%d error=%v", ctx.writev_progress, ctx.writev_error),
	)
	expect(t, iov[1].iov_base == rawptr(uintptr(0x2000)) && iov[1].iov_len == 5, "terminal writev error moved iovec metadata")
	expect(t, io.completion_pool.num_waiting == 0, fmt.tprintf("completions not released: %d", io.completion_pool.num_waiting))
	expect(
		t,
		num_waiting(&io) == 0 &&
		io.ios_queued == 0 &&
		io.ios_in_kernel == 0 &&
		queue.len(io.completed) == 0 &&
		queue.len(io.unqueued) == 0 &&
		!has_userspace_work(&io),
		"scratch batch left accounting/userspace work",
	)
}

P3_SOAK_WORKER_COUNT :: 4
P3_SOAK_CYCLES :: 12

P3_Soak_Phase :: enum {
	None,
	Init,
	Pbuf_Init,
	Listen,
	Endpoint,
	Dial,
	Nonblocking,
	Accept,
	Submit,
	Traffic,
	Shutdown,
	Close,
	Ownership,
	Drain,
	Thread_Start,
}

P3_Soak_Result :: struct {
	worker_index:     int,
	ok:               bool,
	failed_cycle:     int,
	phase:            P3_Soak_Phase,
	completed_cycles: int,
	callback_count:   int,
}

P3_Soak_Worker_Data :: struct {
	worker_index: int,
	wg:           ^sync.Wait_Group,
	results:      chan.Chan(P3_Soak_Result),
}

P3_Soak_Context :: struct {
	io:                      ^IO,
	accepted_sock:           net.TCP_Socket,
	accepted:                bool,
	accept_callbacks:        int,
	recv_done:               bool,
	recv_callbacks:          int,
	echo_done:               bool,
	echo_callbacks:          int,
	short_timeout_callbacks: int,
	long_timeout_callbacks:  int,
	shutdown_done:           bool,
	shutdown_callbacks:      int,
	close_callbacks:         int,
	close_successes:         int,
	failed:                  bool,
	use_writev:              bool,
	payload_len:             int,
	received_len:            int,
	echo_received_len:       int,
	payload:                 [64]byte,
	received:                [64]byte,
	echo_received:           [64]byte,
	iov:                     [2]iovec,
}

p3_soak_on_echo :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^P3_Soak_Context)user
	ctx.echo_callbacks += 1
	ctx.echo_done = true
	if err != nil || sent != ctx.payload_len do ctx.failed = true
}

p3_soak_on_recv :: proc(user: rawptr, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	ctx := cast(^P3_Soak_Context)user
	ctx.recv_callbacks += 1
	ctx.recv_done = true
	if err != nil || received != ctx.payload_len || received > len(ctx.received) {
		ctx.failed = true
		return
	}
	ctx.received_len = received
	copy(ctx.received[:received], buf[:received])
	if ctx.use_writev {
		first_len := received / 2
		ctx.iov[0] = {
			iov_base = rawptr(&ctx.received[0]),
			iov_len  = uint(first_len),
		}
		ctx.iov[1] = {
			iov_base = rawptr(&ctx.received[first_len]),
			iov_len  = uint(received - first_len),
		}
		writev_all_tcp(ctx.io, ctx.accepted_sock, ctx.iov[:], ctx, p3_soak_on_echo)
	} else {
		send_all(ctx.io, ctx.accepted_sock, ctx.received[:received], ctx, p3_soak_on_echo)
	}
}

p3_soak_on_accept :: proc(user: rawptr, client: net.TCP_Socket, _: net.Endpoint, err: net.Network_Error) {
	ctx := cast(^P3_Soak_Context)user
	ctx.accept_callbacks += 1
	if err != nil {
		if client != 0 do net.close(client)
		ctx.failed = true
		return
	}
	ctx.accepted_sock = client
	ctx.accepted = true
}

p3_soak_on_short_timeout :: proc(user: rawptr) {
	ctx := cast(^P3_Soak_Context)user
	ctx.short_timeout_callbacks += 1
}

p3_soak_on_long_timeout :: proc(user: rawptr) {
	ctx := cast(^P3_Soak_Context)user
	ctx.long_timeout_callbacks += 1
}

p3_soak_on_shutdown :: proc(user: rawptr, err: net.Shutdown_Error) {
	ctx := cast(^P3_Soak_Context)user
	ctx.shutdown_callbacks += 1
	ctx.shutdown_done = true
	if err != .None do ctx.failed = true
}

p3_soak_on_close :: proc(user: rawptr, ok: bool) {
	ctx := cast(^P3_Soak_Context)user
	ctx.close_callbacks += 1
	if ok {
		ctx.close_successes += 1
	} else {
		ctx.failed = true
	}
}

p3_soak_is_drained :: proc(io: ^IO) -> bool {
	return(
		num_waiting(io) == 0 &&
		io.ios_queued == 0 &&
		io.ios_in_kernel == 0 &&
		queue.len(io.completed) == 0 &&
		queue.len(io.unqueued) == 0 &&
		!has_userspace_work(io) \
	)
}

p3_soak_drive :: proc(io: ^IO, ctx: ^P3_Soak_Context, phase: P3_Soak_Phase, client: net.TCP_Socket = 0) -> bool {
	start := time.now()
	for time.since(start) < time.Second {
		done := false
		#partial switch phase {
		case .Accept:
			done = ctx.accepted
		case .Traffic:
			if client != 0 && ctx.echo_received_len < ctx.payload_len {
				n, recv_err := net.recv_tcp(client, ctx.echo_received[ctx.echo_received_len:ctx.payload_len])
				if recv_err == nil {
					ctx.echo_received_len += n
				} else {
					#partial switch recv_err {
					case .Would_Block:
					case:
						ctx.failed = true
					}
				}
			}
			done =
				ctx.recv_done &&
				ctx.echo_done &&
				ctx.short_timeout_callbacks == 1 &&
				ctx.long_timeout_callbacks == 1 &&
				ctx.echo_received_len == ctx.payload_len
		case .Shutdown:
			done = ctx.shutdown_done
		case .Close:
			done = ctx.close_callbacks == 2
		case .Drain:
			done = p3_soak_is_drained(io)
		case:
		}
		if done do return !ctx.failed
		if ctx.failed do return false
		if tick(io, time.Millisecond * 2) != .NONE do return false
	}
	return false
}

p3_soak_cycle :: proc(worker_index, cycle: int) -> (phase: P3_Soak_Phase, callbacks: int) {
	io: IO
	if init(&io, ring_entries = 8) != .NONE do return .Init, 0

	server_sock: net.TCP_Socket
	server_open := false
	server_close_submitted := false
	client_sock: net.TCP_Socket
	client_open := false
	accepted_close_submitted := false
	ctx := P3_Soak_Context {
		io          = &io,
		use_writev  = cycle & 1 == 1,
		payload_len = 24,
	}
	defer {
		if client_open do net.close(client_sock)
		if server_open && !server_close_submitted do net.close(server_sock)
		accepted_direct_closed := false
		cleanup_start := time.now()
		for {
			// Accept may complete while cleanup is retiring the listener. Close a
			// late accepted descriptor before releasing pbuf/ring memory.
			if ctx.accepted && !accepted_close_submitted && !accepted_direct_closed {
				net.close(ctx.accepted_sock)
				accepted_direct_closed = true
			}
			if p3_soak_is_drained(&io) do break
			if time.since(cleanup_start) >= time.Second || tick(&io, time.Millisecond * 2) != .NONE {
				phase = .Drain
				break
			}
		}
		if p3_soak_is_drained(&io) {
			destroy(&io)
		} else {
			phase = .Drain
		}
	}

	pbuf_err := linux.Errno.NONE
	for _ in 0 ..< 8 {
		pbuf_err = pbuf_ring_init(&io, entries = 8, bgid = u16(worker_index + 1))
		if pbuf_err == .NONE do break
		if pbuf_err != .ENOMEM do break
		time.sleep(time.Millisecond * 2)
	}
	if pbuf_err != .NONE do return .Pbuf_Init, 0

	listen_err: net.Network_Error
	server_sock, listen_err = open_and_listen_tcp(&io, {net.IP4_Loopback, 0})
	if listen_err != nil do return .Listen, 0
	server_open = true

	server_ep, ep_err := net.bound_endpoint(server_sock)
	if ep_err != nil do return .Endpoint, 0
	accept(&io, server_sock, &ctx, p3_soak_on_accept)
	client_sock, listen_err = net.dial_tcp_from_endpoint(server_ep)
	if listen_err != nil do return .Dial, 0
	client_open = true
	if net.set_blocking(client_sock, false) != nil do return .Nonblocking, 0
	if !p3_soak_drive(&io, &ctx, .Accept) do return .Accept, ctx.accept_callbacks

	for i in 0 ..< ctx.payload_len {
		ctx.payload[i] = byte((worker_index * 37 + cycle * 11 + i) & 0xff)
	}
	recv_provided(&io, ctx.accepted_sock, &ctx, p3_soak_on_recv)
	n_sent, send_err := net.send_tcp(client_sock, ctx.payload[:ctx.payload_len])
	if send_err != nil || n_sent != ctx.payload_len do return .Submit, ctx.accept_callbacks
	timeout(&io, time.Millisecond * 3, &ctx, p3_soak_on_short_timeout)
	long_timeout := timeout(&io, time.Second * 10, &ctx, p3_soak_on_long_timeout)
	if submit_pending(&io) != .NONE do return .Submit, ctx.accept_callbacks
	cancel(&io, long_timeout)

	if !p3_soak_drive(&io, &ctx, .Traffic, client_sock) do return .Traffic, ctx.accept_callbacks + ctx.recv_callbacks + ctx.echo_callbacks + ctx.short_timeout_callbacks + ctx.long_timeout_callbacks
	if ctx.accept_callbacks != 1 ||
	   ctx.recv_callbacks != 1 ||
	   ctx.echo_callbacks != 1 ||
	   ctx.short_timeout_callbacks != 1 ||
	   ctx.long_timeout_callbacks != 1 ||
	   ctx.received_len != ctx.payload_len ||
	   ctx.echo_received_len != ctx.payload_len ||
	   !bytes.equal(ctx.received[:ctx.payload_len], ctx.payload[:ctx.payload_len]) ||
	   !bytes.equal(ctx.echo_received[:ctx.payload_len], ctx.payload[:ctx.payload_len]) {
		return .Traffic, ctx.accept_callbacks + ctx.recv_callbacks + ctx.echo_callbacks + ctx.short_timeout_callbacks + ctx.long_timeout_callbacks
	}

	shutdown(&io, ctx.accepted_sock, .Both, &ctx, p3_soak_on_shutdown)
	if !p3_soak_drive(&io, &ctx, .Shutdown) || ctx.shutdown_callbacks != 1 do return .Shutdown, 6
	close(&io, ctx.accepted_sock, &ctx, p3_soak_on_close)
	accepted_close_submitted = true
	close(&io, server_sock, &ctx, p3_soak_on_close)
	server_close_submitted = true
	if !p3_soak_drive(&io, &ctx, .Close) || ctx.close_successes != 2 do return .Close, 6 + ctx.shutdown_callbacks + ctx.close_callbacks
	server_open = false
	net.close(client_sock)
	client_open = false

	if io.pbuf_ring.produced - io.pbuf_ring.consumed != u64(io.pbuf_ring.entries) do return .Ownership, 8
	if !p3_soak_drive(&io, &ctx, .Drain) do return .Drain, 8
	return .None, 8
}

p3_soak_worker :: proc(data: P3_Soak_Worker_Data) {
	result := P3_Soak_Result {
		worker_index = data.worker_index,
		ok           = true,
		failed_cycle = -1,
	}
	defer sync.wait_group_done(data.wg)
	defer _ = chan.try_send(data.results, result)
	// ULID timing state is thread-local. On virtualized CI hosts the first call
	// may perform Odin's two-second fallback TSC calibration, so keep that
	// one-time startup cost outside the lifecycle phase deadlines.
	_ = ulid.time_now_monotonic()
	for cycle in 0 ..< P3_SOAK_CYCLES {
		phase, callbacks := p3_soak_cycle(data.worker_index, cycle)
		if phase != .None {
			result.ok = false
			result.failed_cycle = cycle
			result.phase = phase
			return
		}
		result.completed_cycles += 1
		result.callback_count += callbacks
	}
}

p3_soak_worker_entry :: proc(data_raw: rawptr) {
	p3_soak_worker((^P3_Soak_Worker_Data)(data_raw)^)
}

@(test)
test_multithread_repeated_io_lifecycle_soak :: proc(t: ^testing.T) {
	result_ch, result_err := chan.create_buffered(chan.Chan(P3_Soak_Result), P3_SOAK_WORKER_COUNT, context.allocator)
	expect(t, result_err == nil, fmt.tprintf("result channel init failed: %v", result_err))
	if result_err != nil do return
	defer chan.destroy(result_ch)

	wg: sync.Wait_Group
	threads: [P3_SOAK_WORKER_COUNT]^thread.Thread
	worker_data: [P3_SOAK_WORKER_COUNT]P3_Soak_Worker_Data
	for worker_index in 0 ..< P3_SOAK_WORKER_COUNT {
		worker_data[worker_index] = {
			worker_index = worker_index,
			wg           = &wg,
			results      = result_ch,
		}
		sync.wait_group_add(&wg, 1)
		threads[worker_index] = thread.create_and_start_with_data(&worker_data[worker_index], p3_soak_worker_entry, context)
		if threads[worker_index] == nil {
			_ = chan.try_send(result_ch, P3_Soak_Result{worker_index = worker_index, failed_cycle = -1, phase = .Thread_Start})
			sync.wait_group_done(&wg)
		}
	}
	sync.wait(&wg)
	for worker_thread in threads {
		if worker_thread != nil do thread.destroy(worker_thread)
	}

	seen: [P3_SOAK_WORKER_COUNT]bool
	for _ in 0 ..< P3_SOAK_WORKER_COUNT {
		result, ok := chan.try_recv(result_ch)
		expect(t, ok, "missing lifecycle soak worker result")
		if !ok do continue
		valid_worker := result.worker_index >= 0 && result.worker_index < P3_SOAK_WORKER_COUNT
		expect(t, valid_worker, fmt.tprintf("invalid lifecycle soak worker index: %d", result.worker_index))
		if !valid_worker do continue
		expect(t, !seen[result.worker_index], fmt.tprintf("duplicate lifecycle soak worker result: %d", result.worker_index))
		seen[result.worker_index] = true
		expect(
			t,
			result.ok && result.completed_cycles == P3_SOAK_CYCLES && result.callback_count == P3_SOAK_CYCLES * 8,
			fmt.tprintf(
				"lifecycle soak worker failed: worker=%d cycle=%d phase=%v completed=%d callbacks=%d",
				result.worker_index,
				result.failed_cycle,
				result.phase,
				result.completed_cycles,
				result.callback_count,
			),
		)
	}
}

Hegel_Lifecycle_Callback_Context :: struct {
	done:           bool,
	callback_count: int,
	timed_out:      bool,
	failed:         bool,
	sent:           int,
}

Hegel_Lifecycle_Winner :: enum {
	Undecided,
	Primary,
	Timeout,
}

Hegel_Lifecycle_Action :: enum {
	Submit,
	Deliver_Aux,
	Deliver_Primary_Success,
	Deliver_Primary_Timeout,
	Process_Callbacks,
}

Hegel_Lifecycle_Action_Choice :: struct {
	kind: Hegel_Lifecycle_Action,
	slot: int,
}

hegel_lifecycle_on_terminal :: proc(user: rawptr, sent: int, err: net.Network_Error) {
	ctx := cast(^Hegel_Lifecycle_Callback_Context)user
	ctx.callback_count += 1
	ctx.sent = sent
	if err == nil {
		ctx.done = true
		return
	}
	tcp_err, ok := err.(net.TCP_Send_Error)
	ctx.timed_out = ok && tcp_err == .Timeout
	ctx.failed = !ctx.timed_out
	ctx.done = true
}

Hegel_Lifecycle_Slot :: struct {
	completion:       ^Completion,
	ctx:              Hegel_Lifecycle_Callback_Context,
	iov:              [2]iovec,
	payload:          [64]byte,
	is_writev:        bool,
	active:           bool,
	primary_pending:  bool,
	aux_pending:      bool,
	callback_done:    bool,
	release_observed: bool,
	winner:           Hegel_Lifecycle_Winner,
	expect_timeout:   bool,
	expected_sent:    int,
}

hegel_lifecycle_pool_occurrences :: proc(io: ^IO, target: ^Completion) -> int {
	count := 0
	n := queue.len(io.completion_pool.objects)
	for _ in 0 ..< n {
		completion := queue.pop_front(&io.completion_pool.objects)
		if completion == target do count += 1
		queue.push_back(&io.completion_pool.objects, completion)
	}
	return count
}

hegel_lifecycle_process_callbacks :: proc(tc: ^hgl.Test_Case, io: ^IO, slots: []Hegel_Lifecycle_Slot, release_count: ^int) -> hgl.Body_Result {
	run_completed_callbacks(io)
	for &slot, index in slots {
		if !slot.active || slot.primary_pending || slot.callback_done do continue
		if slot.ctx.callback_count != 1 {
			hgl.note(tc, fmt.tprintf("slot=%d terminal callback count=%d", index, slot.ctx.callback_count))
			return hgl.interesting("terminal callback wave did not invoke exactly once")
		}
		occurrences := hegel_lifecycle_pool_occurrences(io, slot.completion)
		if occurrences != 1 {
			hgl.note(tc, fmt.tprintf("slot=%d pooled occurrences=%d", index, occurrences))
			return hgl.interesting("terminal completion was not released exactly once")
		}
		slot.callback_done = true
		slot.release_observed = true
		release_count^ += 1
		if !slot.aux_pending {
			slot.active = false
		}
	}
	return hgl.valid()
}

hegel_lifecycle_check_invariants :: proc(tc: ^hgl.Test_Case, io: ^IO, slots: []Hegel_Lifecycle_Slot) -> hgl.Body_Result {
	expected_in_kernel: u64
	expected_waiting := 0
	for &slot, index in slots {
		if slot.primary_pending do expected_in_kernel += 1
		if slot.aux_pending do expected_in_kernel += 1
		if slot.active && !slot.callback_done do expected_waiting += 1

		if slot.ctx.callback_count > 1 {
			hgl.note(tc, fmt.tprintf("slot=%d duplicate_callbacks=%d", index, slot.ctx.callback_count))
			return hgl.interesting("completion callback fired more than once")
		}
		if slot.callback_done {
			if !slot.release_observed ||
			   slot.ctx.callback_count != 1 ||
			   !slot.ctx.done ||
			   slot.ctx.failed ||
			   slot.ctx.timed_out != slot.expect_timeout ||
			   slot.ctx.sent != slot.expected_sent {
				hgl.note(
					tc,
					fmt.tprintf(
						"slot=%d callbacks=%d done=%v failed=%v timed_out=%v/%v sent=%d/%d",
						index,
						slot.ctx.callback_count,
						slot.ctx.done,
						slot.ctx.failed,
						slot.ctx.timed_out,
						slot.expect_timeout,
						slot.ctx.sent,
						slot.expected_sent,
					),
				)
				return hgl.interesting("terminal callback disagreed with lifecycle model")
			}
		} else if slot.ctx.callback_count != 0 {
			hgl.note(tc, fmt.tprintf("slot=%d callback arrived before callback wave", index))
			return hgl.interesting("callback arrived before modeled callback wave")
		}
	}

	if io.ios_in_kernel != expected_in_kernel {
		hgl.note(tc, fmt.tprintf("ios_in_kernel=%d expected=%d", io.ios_in_kernel, expected_in_kernel))
		return hgl.interesting("kernel operation accounting diverged from model")
	}
	if num_waiting(io) != expected_waiting {
		hgl.note(tc, fmt.tprintf("num_waiting=%d expected=%d", num_waiting(io), expected_waiting))
		return hgl.interesting("completion ownership diverged from model")
	}
	return hgl.valid()
}

prop_nbio_generated_linked_completion_lifecycle :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	io: IO
	ierr := init(&io, ring_entries = 8)
	if ierr != .NONE {
		hgl.note(tc, fmt.tprintf("nbio.init error: %v", ierr))
		return hgl.invalid()
	}
	defer destroy(&io)
	pool_destroy(&io.completion_pool)
	pool_err := pool_init(&io.completion_pool, 1)
	if pool_err != nil {
		hgl.note(tc, fmt.tprintf("completion pool init error: %v", pool_err))
		return hgl.invalid()
	}

	// Two logical generations over one physical pool object allow an old odd
	// linked-timeout CQE to arrive after the address has been reused.
	slots: [2]Hegel_Lifecycle_Slot
	first_completion: ^Completion
	submit_count := 0
	release_count := 0
	op_count_raw, draw_err := hgl.draw_i64(tc, 12, 30)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.invalid()

	for step in 0 ..< int(op_count_raw) {
		choices: [20]Hegel_Lifecycle_Action_Choice
		choice_count := 0
		for &candidate, slot_index in slots {
			if !candidate.active {
				if num_waiting(&io) == 0 {
					choices[choice_count] = {.Submit, slot_index}
					choice_count += 1
				}
				continue
			}
			if candidate.aux_pending {
				choices[choice_count] = {.Deliver_Aux, slot_index}
				choice_count += 1
			}
			if candidate.primary_pending {
				if candidate.winner != .Timeout {
					choices[choice_count] = {.Deliver_Primary_Success, slot_index}
					choice_count += 1
				}
				choices[choice_count] = {.Deliver_Primary_Timeout, slot_index}
				choice_count += 1
			}
		}
		if queue.len(io.completed) > 0 {
			choices[choice_count] = {.Process_Callbacks, -1}
			choice_count += 1
		}

		choice_raw, choice_err := hgl.draw_i64(tc, 0, i64(choice_count - 1))
		if choice_err == .Stop_Test do return hgl.abort()
		if choice_err != nil do return hgl.invalid()
		choice := choices[int(choice_raw)]
		slot := choice.slot >= 0 ? &slots[choice.slot] : nil

		switch choice.kind {
		case .Submit:
			payload_len_raw, len_err := hgl.draw_i64(tc, 1, 64)
			if len_err == .Stop_Test do return hgl.abort()
			if len_err != nil do return hgl.invalid()
			writev_raw, writev_err := hgl.draw_bool(tc)
			if writev_err == .Stop_Test do return hgl.abort()
			if writev_err != nil do return hgl.invalid()
			payload_len := int(payload_len_raw)
			slot^ = {}
			slot.active = true
			slot.primary_pending = true
			slot.aux_pending = true
			slot.is_writev = writev_raw
			slot.completion = pool_get(&io.completion_pool)
			if first_completion == nil {
				first_completion = slot.completion
			} else if slot.completion != first_completion {
				hgl.note(tc, fmt.tprintf("completion address changed: first=%p current=%p", first_completion, slot.completion))
				return hgl.interesting("single-object completion pool was not reused")
			}
			submit_count += 1
			slot.completion.ctx = context
			slot.completion.user_data = &slot.ctx
			if slot.is_writev {
				first_len := payload_len / 2
				slot.iov[0] = {
					iov_base = rawptr(&slot.payload[0]),
					iov_len  = uint(first_len),
				}
				slot.iov[1] = {
					iov_base = rawptr(&slot.payload[first_len]),
					iov_len  = uint(payload_len - first_len),
				}
				slot.completion.operation = Op_Writev {
					callback = hegel_lifecycle_on_terminal,
					iov = slot.iov[:],
					len = payload_len,
					all = true,
					timeout_nsec = i64(time.Second),
					timeout_spec = linux.Time_Spec{time_sec = 1},
				}
			} else {
				slot.completion.operation = Op_Send {
					callback = hegel_lifecycle_on_terminal,
					buf = slot.payload[:payload_len],
					len = payload_len,
					all = true,
					timeout_nsec = i64(time.Second),
					timeout_spec = linux.Time_Spec{time_sec = 1},
				}
			}
			io.ios_in_kernel += 2

		case .Deliver_Aux:
			if slot.winner == .Undecided do slot.winner = .Timeout
			aux_result := slot.winner == .Timeout ? -i32(linux.Errno.ETIME) : -i32(linux.Errno.ECANCELED)
			current: ^Hegel_Lifecycle_Slot
			for &candidate in slots {
				if &candidate != slot && candidate.active && !candidate.callback_done && candidate.completion == slot.completion {
					current = &candidate
					break
				}
			}
			current_result: i32
			current_user_data: rawptr
			current_callbacks := 0
			current_is_writev := false
			if current != nil {
				current_result = current.completion.result
				current_user_data = current.completion.user_data
				current_callbacks = current.ctx.callback_count
				_, current_is_writev = current.completion.operation.(Op_Writev)
			}
			dispatch_cqe(&io, io_uring.io_uring_cqe{user_data = u64(uintptr(slot.completion)) + 1, res = aux_result})
			if current != nil {
				_, still_writev := current.completion.operation.(Op_Writev)
				if current.completion.result != current_result ||
				   current.completion.user_data != current_user_data ||
				   current.ctx.callback_count != current_callbacks ||
				   still_writev != current_is_writev {
					hgl.note(tc, fmt.tprintf("stale auxiliary CQE mutated reused completion slot=%d", choice.slot))
					return hgl.interesting("stale linked-timeout CQE mutated a reused completion")
				}
			}
			slot.aux_pending = false
			if slot.callback_done do slot.active = false

		case .Deliver_Primary_Success:
			slot.winner = .Primary
			if slot.is_writev {
				slot.expected_sent = slot.completion.operation.(Op_Writev).len
			} else {
				slot.expected_sent = slot.completion.operation.(Op_Send).len
			}
			dispatch_cqe(&io, io_uring.io_uring_cqe{user_data = u64(uintptr(slot.completion)), res = i32(slot.expected_sent)})
			slot.primary_pending = false

		case .Deliver_Primary_Timeout:
			if slot.winner == .Undecided do slot.winner = .Timeout
			slot.expect_timeout = true
			dispatch_cqe(&io, io_uring.io_uring_cqe{user_data = u64(uintptr(slot.completion)), res = -i32(linux.Errno.ECANCELED)})
			slot.primary_pending = false

		case .Process_Callbacks:
			callback_result := hegel_lifecycle_process_callbacks(tc, &io, slots[:], &release_count)
			if callback_result.status != .Valid do return callback_result
		}

		invariant := hegel_lifecycle_check_invariants(tc, &io, slots[:])
		if invariant.status != .Valid {
			hgl.note(tc, fmt.tprintf("failed after generated step=%d action=%v slot=%d", step, choice.kind, choice.slot))
			return invariant
		}
	}

	// Deterministically retire generated live operations so every example proves
	// shutdown leaves no callback, Completion, auxiliary CQE, or kernel count live.
	for &slot in slots {
		if !slot.active do continue
		if slot.aux_pending {
			if slot.winner == .Undecided do slot.winner = .Timeout
			aux_result := slot.winner == .Timeout ? -i32(linux.Errno.ETIME) : -i32(linux.Errno.ECANCELED)
			dispatch_cqe(&io, io_uring.io_uring_cqe{user_data = u64(uintptr(slot.completion)) + 1, res = aux_result})
			slot.aux_pending = false
			if slot.callback_done do slot.active = false
			invariant := hegel_lifecycle_check_invariants(tc, &io, slots[:])
			if invariant.status != .Valid do return invariant
		}
		if slot.primary_pending {
			if slot.winner == .Undecided do slot.winner = .Timeout
			dispatch_cqe(&io, io_uring.io_uring_cqe{user_data = u64(uintptr(slot.completion)), res = -i32(linux.Errno.ECANCELED)})
			slot.primary_pending = false
			slot.expect_timeout = true
			invariant := hegel_lifecycle_check_invariants(tc, &io, slots[:])
			if invariant.status != .Valid do return invariant
		}
	}
	callback_result := hegel_lifecycle_process_callbacks(tc, &io, slots[:], &release_count)
	if callback_result.status != .Valid do return callback_result
	final_invariant := hegel_lifecycle_check_invariants(tc, &io, slots[:])
	if final_invariant.status != .Valid do return final_invariant
	if submit_count < 2 || release_count != submit_count {
		hgl.note(tc, fmt.tprintf("submissions=%d observed_releases=%d", submit_count, release_count))
		return hgl.interesting("generated history did not prove sequential reuse and one release per operation")
	}

	if io.ios_in_kernel != 0 ||
	   io.ios_queued != 0 ||
	   num_waiting(&io) != 0 ||
	   queue.len(io.completed) != 0 ||
	   queue.len(io.unqueued) != 0 ||
	   has_userspace_work(&io) {
		hgl.note(
			tc,
			fmt.tprintf(
				"terminal work remained: kernel=%d queued=%d waiting=%d completed=%d unqueued=%d",
				io.ios_in_kernel,
				io.ios_queued,
				num_waiting(&io),
				queue.len(io.completed),
				queue.len(io.unqueued),
			),
		)
		return hgl.interesting("generated lifecycle did not retire all nbio work")
	}
	for &slot, index in slots {
		if slot.active || slot.primary_pending || slot.aux_pending {
			hgl.note(tc, fmt.tprintf("slot=%d remained active=%v primary=%v auxiliary=%v", index, slot.active, slot.primary_pending, slot.aux_pending))
			return hgl.interesting("generated lifecycle left modeled work live")
		}
	}
	return hgl.valid()
}

@(test)
test_hegel_nbio_generated_linked_completion_lifecycle :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_nbio_generated_linked_completion_lifecycle, nil, {test_cases = 50})
	testing.expectf(t, err == nil, "hegel nbio lifecycle property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

External_Wake_Test_Data :: struct {
	wake_fd: linux.Fd,
}

external_wake_test_writer :: proc(data_raw: rawptr) {
	data := (^External_Wake_Test_Data)(data_raw)
	time.sleep(10 * time.Millisecond)
	value := u64(1)
	_, _ = linux.write(data.wake_fd, ([^]byte)(&value)[:size_of(value)])
}

@(test)
test_tick_external_wake_interrupts_idle_wait :: proc(t: ^testing.T) {
	io: IO
	err := init(&io, ring_entries = 64)
	expect(t, err == .NONE, fmt.tprintf("nbio init failed: %v", err))
	if err != .NONE do return
	defer destroy(&io)

	wake_fd, wake_err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	expect(t, wake_err == .NONE, fmt.tprintf("eventfd init failed: %v", wake_err))
	if wake_err != .NONE do return
	defer linux.close(wake_fd)
	// Keep one-time per-thread TSC calibration outside the measured wait.
	_ = ulid.time_now_monotonic()

	data := External_Wake_Test_Data {
		wake_fd = wake_fd,
	}
	writer := thread.create_and_start_with_data(&data, external_wake_test_writer, context)
	expect(t, writer != nil, "external wake writer thread should start")
	if writer == nil do return
	defer thread.destroy(writer)

	start := time.now()
	tick_err := tick(&io, 500 * time.Millisecond, wake_fd)
	elapsed := time.since(start)
	expect(t, tick_err == .NONE, fmt.tprintf("externally woken tick failed: %v", tick_err))
	testing.expectf(t, elapsed < 200 * time.Millisecond, "external wake took %v instead of interrupting the 500ms wait", elapsed)

	value: u64
	_, read_err := linux.read(wake_fd, ([^]byte)(&value)[:size_of(value)])
	expect(t, read_err == .EAGAIN, "tick should drain the external eventfd before returning")
}
