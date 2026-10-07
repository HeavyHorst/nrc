#+private
package nbio

import "base:runtime"

import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:sync"
import "core:sys/linux"
import "core:time"

import ulid "../ulid"
import io_uring "_io_uring"

NANOSECONDS_PER_SECOND :: 1e+9

_IO :: struct {
	ring:                 io_uring.IO_Uring,
	completion_pool:      Pool(Completion),
	cqe_scratch:          [4096]io_uring.io_uring_cqe,
	// Deferred after SQ saturation. FIFO ordering is preserved among entries in
	// this queue; it is not a global ordering barrier for newly scheduled I/O.
	unqueued:             queue.Queue(^Completion),
	// Ready to run callbacks.
	completed:            queue.Queue(^Completion),
	ios_queued:           u64,
	ios_in_kernel:        u64,
	allocator:            mem.Allocator,

	// Statistics
	total_completions:    u64,
	total_latency_ns:     u64,
	latency_sample_count: u64,
	send_sample_seq:      u64,

	// Provided buffer ring management
	pbuf_ring:            Provided_Buffer_Ring,
}

// Buffer pool configuration
_BUFFER_POOL_SIZE :: 2048 // Full io_uring queue capacity - requires increased memlock limit
_BUFFER_SIZE :: 8192 // 8KB per buffer

// Provided buffer ring (PBUF_RING) for efficient buffer management
Provided_Buffer_Ring :: struct {
	// Ring state
	br:                ^io_uring.io_uring_buf_ring,
	entries:           u32,
	mask:              u32,
	bgid:              u16,

	// Memory management
	ring_memory:       rawptr,
	ring_size:         uint,
	data_buffers:      [][]byte,

	// Statistics
	produced:          u64,
	consumed:          u64,
	enobufs:           u64,
	enobufs_last_warn: u64, // Last threshold at which we warned
}

_Completion :: struct {
	result:     i32,
	flags:      u32, // CQE flags (for BUFFER_SELECT operations)
	operation:  Operation,
	ctx:        runtime.Context,
	start_time: i64,
	// True only when this completion was selected for latency sampling.
	// `start_time` is also set for deadline-tracked sends (to clamp linked
	// timeouts on retry), so this flag distinguishes "timed for stats" from
	// "timed for deadline" — only sampled sends feed the latency accumulator.
	sampled:    bool,
}

Op_Accept :: struct {
	callback:    On_Accept,
	socket:      net.TCP_Socket,
	sockaddr:    linux.Sock_Addr_Any,
	sockaddrlen: c.int,
	multishot:   bool,
}

Op_Close :: struct {
	callback: On_Close,
	fd:       linux.Fd,
	file:     bool,
}

Op_Shutdown :: struct {
	callback: On_Shutdown,
	fd:       linux.Fd,
	how:      linux.Shutdown_How,
}

Op_Send :: struct {
	callback:     On_Sent,
	socket:       net.Any_Socket,
	buf:          []byte,
	len:          int,
	sent:         int,
	all:          bool,
	timeout_nsec: Maybe(i64), // timeout in nanoseconds, if specified
	timeout_spec: linux.Time_Spec, // stable storage for linked timeout SQE
}

Op_Recv_Provided :: struct {
	callback:       On_Recv_Provided,
	socket:         net.Any_Socket,
	bid:            u16, // Buffer ID from CQE
	buf:            []byte, // Buffer slice from data_buffers[bid]
	aggregate:      []byte, // Accumulation buffer for all=true semantics
	all:            bool,
	cancelled:      bool, // Terminalize instead of retrying transient CQEs after cancellation
	// A submitted async-cancel retains this Completion until both CQEs retire,
	// preventing its raw user_data address from being reused as an ABA target.
	cancel_pending: bool,
	terminal_done:  bool,
	received:       int,
	len:            int,
}

Op_Recv_Cancel :: struct {
	target: ^Completion,
}

Op_Timeout :: struct {
	callback: On_Timeout,
	expires:  linux.Time_Spec,
}

Op_Writev :: struct {
	callback:     On_Writev,
	socket:       net.TCP_Socket,
	iov:          []io_uring.iovec, // Full iovec array (owned externally)
	iov_offset:   int, // Starting offset into iov for partial writes
	len:          int, // Total bytes to send
	sent:         int, // Bytes sent so far
	all:          bool, // Use send_all semantics (retry on partial writes)
	timeout_nsec: Maybe(i64), // timeout in nanoseconds, if specified
	timeout_spec: linux.Time_Spec, // stable storage for linked timeout SQE
}

Op_File_Read :: struct {
	callback: On_File_Read,
	fd:       linux.Fd,
	buf:      []byte,
	offset:   u64,
}

Op_File_Open :: struct {
	callback: On_File_Open,
	path:     cstring,
}

Op_File_Write :: struct {
	callback: On_File_Write,
	fd:       linux.Fd,
	buf:      []byte,
	offset:   u64,
}

Op_File_Sync :: struct {
	callback: On_File_Sync,
	fd:       linux.Fd,
}

sq_capacity_remaining :: #force_inline proc(io: ^IO) -> u32 {
	depth := u32(len(io.ring.sq.sqes))
	ready := io_uring.sq_ready(&io.ring)
	if ready >= depth do return 0
	return depth - ready
}

// Clamp a send/writev linked-timeout to the *remaining* per-operation deadline.
//
// io_uring linked timeouts are per-SQE: each re-enqueue (partial send or
// EWOULDBLOCK retry) would otherwise get a fresh full-budget timeout, letting a
// stalled peer pin a send SQE for N * timeout instead of `timeout`. To honor the
// documented hard-deadline semantics, we record the operation start time on the
// first enqueue (see set_start_time_for_send / _writev) and, on every retry,
// recompute the linked-timeout spec as `full_timeout_ns - elapsed`.
//
// `start_time`       : unix-ns recorded at first enqueue (0 if no deadline tracked)
// `full_timeout_ns`  : the original per-operation budget in nanoseconds
// `timeout_spec`     : stable storage read by send_enqueue/writev_enqueue; updated
//                      in place to the remaining budget
//
// Returns true if time remains (timeout_spec updated), false if the deadline is
// already exhausted (caller must complete the operation with .Timeout).
clamp_remaining_send_timeout :: #force_inline proc(start_time: i64, full_timeout_ns: i64, timeout_spec: ^linux.Time_Spec) -> bool {
	if start_time <= 0 do return true
	now := time.to_unix_nanoseconds(ulid.time_now_monotonic())
	elapsed := now - start_time
	remaining := full_timeout_ns - elapsed
	if remaining <= 0 do return false
	timeout_spec^ = linux.Time_Spec {
		time_sec  = uint(remaining / NANOSECONDS_PER_SECOND),
		time_nsec = uint(remaining % NANOSECONDS_PER_SECOND),
	}
	return true
}

// Before re-enqueuing a partial/EWOULDBLOCK send or writev, clamp its linked
// timeout to the remaining per-operation budget. If the deadline is already
// exhausted, complete the operation with .Timeout and recycle the completion.
//
// `timeout_nsec`/`timeout_spec` are the op's deadline fields (see
// clamp_remaining_send_timeout). `callback` is the op's On_Sent/On_Writev (same
// signature). Returns true if the op was completed (caller must `return`), false
// if budget remains and the caller should proceed to re-enqueue.
send_deadline_exhausted :: #force_inline proc(
	io: ^IO,
	completion: ^Completion,
	timeout_nsec: Maybe(i64),
	timeout_spec: ^linux.Time_Spec,
	sent: int,
	callback: On_Sent,
) -> bool {
	tn, has_t := timeout_nsec.?
	if !has_t do return false
	if clamp_remaining_send_timeout(completion.start_time, tn, timeout_spec) do return false

	callback(completion.user_data, sent, net.TCP_Send_Error(.Timeout))
	pool_put(&io.completion_pool, completion)
	return true
}

unqueued_sqe_requirement :: #force_inline proc(completion: ^Completion) -> u32 {
	needed: u32 = 1

	#partial switch &op in completion.operation {
	case Op_Send:
		if _, has_timeout := op.timeout_nsec.?; has_timeout {
			needed = 2
		}
	case Op_Writev:
		if _, has_timeout := op.timeout_nsec.?; has_timeout {
			needed = 2
		}
	}

	return needed
}

drain_unqueued :: proc(io: ^IO) {
	// Store length at this time, so we don't infinite loop if any of the enqueue
	// procs below then add to the queue again.
	n := queue.len(io.unqueued)
	
	// odinfmt: disable
	for _ in 0 ..< n {
		// Avoid pop/requeue churn when the SQ ring cannot accept this operation.
		front := queue.front_ptr(&io.unqueued)
		if front == nil do break

		needed_sqe := unqueued_sqe_requirement(front^)
		if sq_capacity_remaining(io) < needed_sqe {
			break
		}

		unqueued := queue.pop_front(&io.unqueued)
		#partial switch &op in unqueued.operation {
		case Op_Accept:        accept_enqueue        (io, unqueued, &op)
		case Op_Close:         close_enqueue         (io, unqueued, &op)
		case Op_Shutdown:      shutdown_enqueue      (io, unqueued, &op)
		case Op_Recv_Provided: recv_provided_enqueue (io, unqueued, &op)
		case Op_Send:
			if timeout_nsec, has_timeout := op.timeout_nsec.?; has_timeout &&
			   !clamp_remaining_send_timeout(unqueued.start_time, timeout_nsec, &op.timeout_spec) {
				unqueued.result = -i32(linux.Errno.ETIME)
				queue.push_back(&io.completed, unqueued)
				continue
			}
			send_enqueue(io, unqueued, &op)
		case Op_Timeout:       timeout_enqueue       (io, unqueued, &op)
		case Op_Writev:
			if timeout_nsec, has_timeout := op.timeout_nsec.?; has_timeout &&
			   !clamp_remaining_send_timeout(unqueued.start_time, timeout_nsec, &op.timeout_spec) {
				unqueued.result = -i32(linux.Errno.ETIME)
				queue.push_back(&io.completed, unqueued)
				continue
			}
			writev_enqueue(io, unqueued, &op)
		case Op_File_Read:     file_read_enqueue      (io, unqueued, &op)
		case Op_File_Open:     file_open_enqueue      (io, unqueued, &op)
		case Op_File_Write:    file_write_enqueue     (io, unqueued, &op)
		case Op_File_Sync:     file_sync_enqueue      (io, unqueued, &op)
		}
	}
	// odinfmt: enable
}

submit_all_pending_internal :: proc(io: ^IO) -> linux.Errno {
	for {
		queued_before := io.ios_queued
		unqueued_before := queue.len(io.unqueued)
		err := flush_submissions(io, 0)
		if err != .NONE do return err
		if queue.len(io.unqueued) > 0 do drain_unqueued(io)
		if io.ios_queued == 0 && queue.len(io.unqueued) == 0 do return .NONE
		if io.ios_queued >= queued_before && queue.len(io.unqueued) >= unqueued_before do return .EBUSY
	}
}

cancel_unqueued_timeout :: proc(io: ^IO, target: ^Completion) -> bool {
	n := queue.len(io.unqueued)
	found := false
	for _ in 0 ..< n {
		completion := queue.pop_front(&io.unqueued)
		if !found && completion == target {
			_, is_timeout := completion.operation.(Op_Timeout)
			if is_timeout {
				found = true
				continue
			}
		}
		queue.push_back(&io.unqueued, completion)
	}
	if !found do return false

	target.result = -i32(linux.Errno.ECANCELED)
	queue.push_back(&io.completed, target)
	return true
}

cancel_unqueued_recv_provided :: proc(io: ^IO, target: ^Completion) -> bool {
	n := queue.len(io.unqueued)
	found := false
	for _ in 0 ..< n {
		completion := queue.pop_front(&io.unqueued)
		if !found && completion == target {
			_, is_recv := completion.operation.(Op_Recv_Provided)
			if is_recv {
				found = true
				continue
			}
		}
		queue.push_back(&io.unqueued, completion)
	}
	if !found do return false

	target.result = -i32(linux.Errno.ECANCELED)
	queue.push_back(&io.completed, target)
	return true
}

run_completed_callbacks :: proc(io: ^IO) {
	n := queue.len(io.completed)
	
	// odinfmt: disable
	for _ in 0 ..< n {
		completed := queue.pop_front(&io.completed)
		context = completed.ctx

		#partial switch &op in completed.operation {
		case Op_Accept:        accept_callback        (io, completed, &op)
		case Op_Close:         close_callback         (io, completed, &op)
		case Op_Shutdown:      shutdown_callback      (io, completed, &op)
		case Op_Recv_Provided: recv_provided_callback (io, completed, &op)
			case Op_Recv_Cancel:   recv_cancel_callback   (io, completed, &op)
		case Op_Send:          send_callback          (io, completed, &op)
		case Op_Timeout:       timeout_callback       (io, completed, &op)
		case Op_Writev:        writev_callback        (io, completed, &op)
		case Op_File_Read:     file_read_callback     (io, completed, &op)
		case Op_File_Open:     file_open_callback     (io, completed, &op)
		case Op_File_Write:    file_write_callback    (io, completed, &op)
		case Op_File_Sync:     file_sync_callback     (io, completed, &op)
		case: unreachable()
		}
	}
	// odinfmt: enable
}

file_open_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Open) {
	sqe, err := io_uring.openat(&io.ring, u64(uintptr(completion)), linux.AT_FDCWD, op.path, 0, u32(linux.Open_Flags{.CLOEXEC}))
	if err == .Submission_Queue_Full {queue.push_back(&io.unqueued, completion); return}
	assert(err == .None)
	sqe.flags |= u8(io_uring.IOSQE_ASYNC)
	io.ios_queued += 1
}

file_open_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Open) {
	if completion.result < 0 {
		op.callback(completion.user_data, -1, linux.Errno(-completion.result))
	} else {
		op.callback(completion.user_data, linux.Fd(completion.result), .NONE)
	}
	pool_put(&io.completion_pool, completion)
}

file_read_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Read) {
	sqe, err := io_uring.read(&io.ring, u64(uintptr(completion)), op.fd, op.buf, op.offset)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}
	sqe.flags |= u8(io_uring.IOSQE_ASYNC)
	io.ios_queued += 1
}

file_read_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Read) {
	if completion.result < 0 {
		op.callback(completion.user_data, 0, linux.Errno(-completion.result))
	} else {
		op.callback(completion.user_data, int(completion.result), .NONE)
	}
	pool_put(&io.completion_pool, completion)
}

file_write_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Write) {
	sqe, err := io_uring.write(&io.ring, u64(uintptr(completion)), op.fd, op.buf, op.offset)
	if err == .Submission_Queue_Full {queue.push_back(&io.unqueued, completion); return}
	assert(err == .None)
	// Force io-wq execution rather than allowing a buffered write inline.
	sqe.flags |= u8(io_uring.IOSQE_ASYNC)
	io.ios_queued += 1
}

file_write_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Write) {
	if completion.result < 0 {
		op.callback(completion.user_data, 0, linux.Errno(-completion.result))
	} else {
		op.callback(completion.user_data, int(completion.result), .NONE)
	}
	pool_put(&io.completion_pool, completion)
}

file_sync_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Sync) {
	_, err := io_uring.fsync(&io.ring, u64(uintptr(completion)), op.fd, 0)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}
	io.ios_queued += 1
}

file_sync_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_File_Sync) {
	err := linux.Errno.NONE
	if completion.result < 0 do err = linux.Errno(-completion.result)
	op.callback(completion.user_data, err)
	pool_put(&io.completion_pool, completion)
}

flush :: proc(io: ^IO, wait_nr: u32) -> (linux.Errno, bool) {
	// Publish SQEs that were prepared in the previous callback wave.
	err := flush_submissions(io, 0)
	if err != .NONE do return err, false

	// Retry anything that previously hit SQ capacity and submit it as a single batch.
	drain_unqueued(io)
	err = flush_submissions(io, wait_nr)
	if err != .NONE do return err, false

	err = flush_completions(io, 0)
	if err != .NONE do return err, false

	had_callbacks := queue.len(io.completed) > 0
	run_completed_callbacks(io)
	return .NONE, had_callbacks
}

dispatch_cqe :: proc(io: ^IO, cqe: io_uring.io_uring_cqe) {
	assert(io.ios_in_kernel > 0, "CQE received without a matching in-kernel operation")
	io.ios_in_kernel -= 1

	if cqe.user_data == 0 {
		return
	}

	// Linked timeout completions use the primary Completion address plus one.
	// They are accounting-only: the primary operation CQE owns callback delivery
	// and Completion release regardless of which CQE arrives first.
	completion_addr := uintptr(cqe.user_data)
	if completion_addr & 1 == 1 {
		return
	}

	completion := cast(^Completion)completion_addr

	// Handle multishot accept by snapshotting per-CQE data.
	#partial switch &op in completion.operation {
	case Op_Accept:
		if op.multishot && cqe.res >= 0 {
			child := pool_get(&io.completion_pool)
			child.ctx = completion.ctx
			child.user_data = completion.user_data
			child.result = cqe.res
			child.flags = cqe.flags
			child.operation = Op_Accept {
				callback    = op.callback,
				socket      = op.socket,
				sockaddr    = op.sockaddr,
				sockaddrlen = op.sockaddrlen,
				multishot   = false,
			}

			op.sockaddrlen = c.int(size_of(linux.Sock_Addr_Any))
			queue.push_back(&io.completed, child)

			if (cqe.flags & u32(io_uring.IORING_CQE_F_MORE)) == 0 {
				pool_put(&io.completion_pool, completion)
			} else {
				io.ios_in_kernel += 1
			}
			return
		}
	}

	completion.result = cqe.res
	completion.flags = cqe.flags

	when ENABLE_STATS {
		io.total_completions += 1
		#partial switch &op in completion.operation {
		case Op_Send:
			if completion.sampled && completion.start_time > 0 {
				now := time.to_unix_nanoseconds(ulid.time_now_monotonic())
				latency := u64(now - completion.start_time)
				io.total_latency_ns += latency
				io.latency_sample_count += 1
			}
		}
	}

	queue.push_back(&io.completed, completion)
}

// Zero/odd tags are accounting-only and never dereferenced. Even user_data must
// identify a live, uniquely outstanding Completion; duplicate/stale even
// one-shot primaries are unsupported by the raw-pointer contract.
dispatch_cqe_batch :: proc(io: ^IO, cqes: []io_uring.io_uring_cqe) {
	queue.reserve(&io.completed, len(cqes))
	for cqe in cqes {
		dispatch_cqe(io, cqe)
	}
}

flush_completions :: proc(io: ^IO, wait_nr: u32) -> linux.Errno {
	wait_remaining := wait_nr
	for {
		completed, err := io_uring.copy_cqes(&io.ring, io.cqe_scratch[:], wait_remaining)
		if err != .None do return ring_err_to_os_err(err)

		if wait_remaining < completed {
			wait_remaining = 0
		} else {
			wait_remaining = max(0, wait_remaining - completed)
		}

		if completed > 0 {
			dispatch_cqe_batch(io, io.cqe_scratch[:completed])
		}

		// A full CQ may have more completions on the kernel overflow list even
		// though this batch is smaller than the much larger scratch buffer.
		// Keep advancing the CQ and entering the kernel until that list (and any
		// cooperative task work) has been flushed.
		if completed < len(io.cqe_scratch) && !io_uring.cq_ring_needs_flush(&io.ring) do break
	}

	return .NONE
}

flush_submissions :: proc(io: ^IO, wait_nr: u32) -> linux.Errno {
	if io.ios_queued == 0 && wait_nr == 0 {
		return .NONE
	}

	for {
		submitted, err := io_uring.submit(&io.ring, wait_nr)
		#partial switch err {
		case .None:
			break
		case .Signal_Interrupt:
			continue
		case .Completion_Queue_Overcommitted, .System_Resources:
			ferr := flush_completions(io, 1)
			if ferr != .NONE do return ferr
			continue
		case:
			return ring_err_to_os_err(err)
		}

		io.ios_queued -= u64(submitted)
		io.ios_in_kernel += u64(submitted)
		break
	}

	return .NONE
}

accept_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	ioprio := op.multishot ? u16(io_uring.IORING_ACCEPT_MULTISHOT) : 0
	_, err := io_uring.accept(&io.ring, u64(uintptr(completion)), linux.Fd(op.socket), cast(^linux.Sock_Addr)&op.sockaddr, &op.sockaddrlen, 0, ioprio)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

accept_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		if op.multishot {
			// Multishot accept failed, this is terminal
			op.callback(completion.user_data, 0, {}, net.Accept_Error(errno))
			pool_put(&io.completion_pool, completion)
		} else {
			// Single-shot accept: re-enqueue on transient errors
			#partial switch errno {
			case .EINTR, .EWOULDBLOCK:
				accept_enqueue(io, completion, op)
			case:
				op.callback(completion.user_data, 0, {}, net.Accept_Error(errno))
				pool_put(&io.completion_pool, completion)
			}
		}
		return
	}

	client := net.TCP_Socket(completion.result)
	err := _prepare_socket(client)
	source := sockaddr_storage_to_endpoint(&op.sockaddr)

	op.callback(completion.user_data, client, source, err)

	if op.multishot {
		// Check if more CQEs will arrive (IORING_CQE_F_MORE flag)
		has_more := (completion.flags & io_uring.IORING_CQE_F_MORE) != 0
		if !has_more {
			// Terminal CQE, release the completion
			pool_put(&io.completion_pool, completion)
		}
		// If has_more is true, keep the completion alive for subsequent CQEs
	} else {
		// Single-shot: always release after callback
		pool_put(&io.completion_pool, completion)
	}
}

close_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	sqe, err := io_uring.close(&io.ring, u64(uintptr(completion)), op.fd)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	if op.file do sqe.flags |= u8(io_uring.IOSQE_ASYNC)
	io.ios_queued += 1
}

close_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	errno := linux.Errno(-completion.result)

	// In particular close() should not be retried after an EINTR
	// since this may cause a reused descriptor from another thread to be closed.
	op.callback(completion.user_data, errno == .NONE || errno == .EINTR)
	pool_put(&io.completion_pool, completion)
}

shutdown_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Shutdown) {
	_, err := io_uring.shutdown(&io.ring, u64(uintptr(completion)), op.fd, op.how)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

shutdown_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Shutdown) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			shutdown_enqueue(io, completion, op)
			return
		case:
			op.callback(completion.user_data, net._shutdown_error(errno))
			pool_put(&io.completion_pool, completion)
			return
		}
	}

	op.callback(completion.user_data, .None)
	pool_put(&io.completion_pool, completion)
}

recv_provided_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv_Provided) {
	tcpsock, ok := op.socket.(net.TCP_Socket)
	if !ok {
		unimplemented("UDP recv_provided is unimplemented for linux nbio")
	}

	// Kernel will select buffer from the ring.
	sqe, err := io_uring.recv(&io.ring, u64(uintptr(completion)), linux.Fd(tcpsock), nil, 0)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	// Set BUFFER_SELECT flag and buffer group ID
	sqe.flags |= u8(io_uring.IOSQE_BUFFER_SELECT)
	sqe.buf_group = io.pbuf_ring.bgid

	io.ios_queued += 1
}

recv_provided_release :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv_Provided) {
	assert(!op.terminal_done, "recv Completion terminalized twice")
	op.terminal_done = true
	if !op.cancel_pending {
		pool_put(&io.completion_pool, completion)
	}
}

recv_cancel_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv_Cancel) {
	target := op.target
	assert(target != nil, "recv cancel missing target Completion")
	if target != nil {
		#partial switch &recv_op in target.operation {
		case Op_Recv_Provided:
			assert(recv_op.cancel_pending, "recv cancel CQE without pending cancellation")
			recv_op.cancel_pending = false
			if recv_op.terminal_done {
				pool_put(&io.completion_pool, target)
			}
		case:
			unreachable()
		}
	}
	pool_put(&io.completion_pool, completion)
}

recv_provided_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv_Provided) {
	// Check if a buffer was actually selected by the kernel
	has_buffer := (completion.flags & io_uring.IORING_CQE_F_BUFFER) != 0

	// Handle connection close (result=0) - no buffer is selected
	if completion.result == 0 {
		err_buf := op.buf
		if op.all && op.aggregate != nil {
			err_buf = op.aggregate[:min(op.received, len(op.aggregate))]
		}
		op.callback(completion.user_data, op.received, err_buf, {}, net._tcp_recv_error(.ECONNRESET))
		if op.aggregate != nil {
			delete(op.aggregate, io.allocator)
			op.aggregate = nil
		}
		recv_provided_release(io, completion, op)
		return
	}

	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		if op.cancelled {
			err_buf := op.buf
			if op.all && op.aggregate != nil {
				err_buf = op.aggregate[:min(op.received, len(op.aggregate))]
			}
			op.callback(completion.user_data, op.received, err_buf, {}, net._tcp_recv_error(.ECONNRESET))
			if op.buf != nil {
				_pbuf_ring_recycle(io, op.bid)
				op.buf = nil
				op.bid = 0
			}
			if op.aggregate != nil {
				delete(op.aggregate, io.allocator)
				op.aggregate = nil
			}
			recv_provided_release(io, completion, op)
			return
		}
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			if op.buf != nil {
				_pbuf_ring_recycle(io, op.bid)
				op.buf = nil
				op.bid = 0
			}
			recv_provided_enqueue(io, completion, op)
			return
		case .ENOBUFS:
			io.pbuf_ring.enobufs += 1
			// Warn at exponential thresholds: 1, 10, 100, 1000, ...
			count := io.pbuf_ring.enobufs
			if count == 1 || (count >= 10 * io.pbuf_ring.enobufs_last_warn && count >= 10) {
				io.pbuf_ring.enobufs_last_warn = count
				fmt.printf("WARNING: ENOBUFS on recv (count: %d) - provided buffer ring exhausted, consider increasing _BUFFER_POOL_SIZE\n", count)
			}
			recv_provided_enqueue(io, completion, op)
			return
		case .ECANCELED:
			// Operation was canceled (e.g., socket closed while recv pending)
			err_buf := op.buf
			if op.all && op.aggregate != nil {
				err_buf = op.aggregate[:min(op.received, len(op.aggregate))]
			}
			op.callback(completion.user_data, op.received, err_buf, {}, net._tcp_recv_error(.ECONNRESET))
			if op.buf != nil {
				_pbuf_ring_recycle(io, op.bid)
				op.buf = nil
				op.bid = 0
			}
			if op.aggregate != nil {
				delete(op.aggregate, io.allocator)
				op.aggregate = nil
			}
			recv_provided_release(io, completion, op)
			return
		case:
			err_buf := op.buf
			if op.all && op.aggregate != nil {
				err_buf = op.aggregate[:min(op.received, len(op.aggregate))]
			}
			op.callback(completion.user_data, op.received, err_buf, {}, net._tcp_recv_error(linux.Errno(errno)))
			// Only recycle if we previously had a valid buffer from an earlier recv
			if op.buf != nil {
				_pbuf_ring_recycle(io, op.bid)
				op.buf = nil
				op.bid = 0
			}
			if op.aggregate != nil {
				delete(op.aggregate, io.allocator)
				op.aggregate = nil
			}
			recv_provided_release(io, completion, op)
			return
		}
	}

	// Buffer flag must be set for successful recv with provided buffers
	if !has_buffer {
		fmt.printf("ERROR: IORING_CQE_F_BUFFER not set in successful recv (flags: 0x%x, result: %d)\n", completion.flags, completion.result)
		op.callback(completion.user_data, 0, nil, {}, net._tcp_recv_error(.EIO))
		recv_provided_release(io, completion, op)
		return
	}

	// Extract buffer ID from CQE flags (has_buffer already validated above)
	bid := u16(completion.flags >> u32(io_uring.IORING_CQE.BUFFER_SHIFT))
	bytes_received := completion.result

	// Get buffer from data_buffers
	if int(bid) >= len(io.pbuf_ring.data_buffers) {
		fmt.printf(
			"ERROR: Invalid buffer ID %d from kernel (flags: 0x%x, result: %d, produced: %d, consumed: %d)\n",
			bid,
			completion.flags,
			completion.result,
			io.pbuf_ring.produced,
			io.pbuf_ring.consumed,
		)
		op.callback(completion.user_data, 0, nil, {}, net._tcp_recv_error(.EIO))
		recv_provided_release(io, completion, op)
		return
	}

	op.bid = bid
	op.buf = io.pbuf_ring.data_buffers[bid][:bytes_received]
	received_before := op.received
	op.received += int(bytes_received)
	io.pbuf_ring.consumed += 1

	if op.all {
		if op.aggregate == nil {
			op.aggregate = make([]byte, max(op.len, op.received), io.allocator)
		} else if len(op.aggregate) < op.received {
			grown := make([]byte, op.received, io.allocator)
			copy(grown[:min(received_before, len(op.aggregate))], op.aggregate[:min(received_before, len(op.aggregate))])
			delete(op.aggregate, io.allocator)
			op.aggregate = grown
		}

		copy(op.aggregate[received_before:op.received], op.buf[:bytes_received])
	}

	if op.all && op.received < op.len {
		// Continue with new buffer - recycle current one first
		_pbuf_ring_recycle(io, op.bid)
		op.buf = nil
		op.bid = 0
		recv_provided_enqueue(io, completion, op)
		return
	}

	// Success case - call callback then recycle
	if op.all {
		op.callback(completion.user_data, op.received, op.aggregate[:op.received], {}, nil)
		delete(op.aggregate, io.allocator)
		op.aggregate = nil
	} else {
		op.callback(completion.user_data, op.received, op.buf, {}, nil)
	}
	_pbuf_ring_recycle(io, op.bid)
	op.buf = nil
	op.bid = 0
	recv_provided_release(io, completion, op)
}

send_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	tcpsock, ok := op.socket.(net.TCP_Socket)
	if !ok {
		// TODO: figure out and implement.
		unimplemented("UDP send is unimplemented for linux nbio")
	}

	if _, has_timeout := op.timeout_nsec.?; has_timeout {
		if sq_capacity_remaining(io) < 2 {
			queue.push_back(&io.unqueued, completion)
			return
		}
		// The ring is SINGLE_ISSUER, so this preflight reserves the pair atomically
		// with respect to other producers.
		sqe, err := io_uring.send(&io.ring, u64(uintptr(completion)), linux.Fd(tcpsock), op.buf, 0)
		assert(err == .None, "preflighted timed send SQE reservation failed")

		// Set link flag on the send operation
		sqe.flags |= u8(io_uring.IOSQE_IO_LINK)

		// Add linked timeout with unique user_data (using completion address + 1 to distinguish)
		_, timeout_err := io_uring.link_timeout(&io.ring, u64(uintptr(completion)) + 1, &op.timeout_spec, 0)
		assert(timeout_err == .None, "preflighted send timeout SQE reservation failed")
		// Both send and timeout operations are queued.
		io.ios_queued += 2
	} else {
		// Send without timeout (current implementation)
		_, err := io_uring.send(&io.ring, u64(uintptr(completion)), linux.Fd(tcpsock), op.buf, 0)
		if err == .Submission_Queue_Full {
			queue.push_back(&io.unqueued, completion)
			return
		}

		io.ios_queued += 1
	}
}

send_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			if send_deadline_exhausted(io, completion, op.timeout_nsec, &op.timeout_spec, op.sent, op.callback) {
				return
			}
			send_enqueue(io, completion, op)
		case .ECANCELED:
			// Send was canceled due to timeout
			op.callback(completion.user_data, op.sent, net.TCP_Send_Error(.Timeout))
			pool_put(&io.completion_pool, completion)
		case .ETIME:
			// Timeout occurred (should be rare since timeout goes to different user_data)
			op.callback(completion.user_data, op.sent, net.TCP_Send_Error(.Timeout))
			pool_put(&io.completion_pool, completion)
		case:
			op.callback(completion.user_data, op.sent, net._tcp_send_error(linux.Errno(errno)))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.sent += int(completion.result)

	if op.all && op.sent < op.len {
		op.buf = op.buf[completion.result:]
		if send_deadline_exhausted(io, completion, op.timeout_nsec, &op.timeout_spec, op.sent, op.callback) {
			return
		}
		send_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.sent, nil)
	pool_put(&io.completion_pool, completion)
}

timeout_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	_, err := io_uring.timeout(&io.ring, u64(uintptr(completion)), &op.expires, 0, 0)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

timeout_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .ETIME: // Timeout expired normally
		case .ECANCELED: // Timeout was canceled/removed
		case .EINTR, .EWOULDBLOCK:
			timeout_enqueue(io, completion, op)
			return
		case .EBADF:
			// EBADF indicates timeout SQE was submitted with incorrect flags (e.g., IOSQE_FIXED_FILE)
			// This is a submission bug, not a runtime error - log and continue gracefully
			fmt.printf("WARNING: Timeout operation completed with EBADF - check SQE flags\n")
		case:
			// Don't panic in production - log unexpected errors
			fmt.printf("WARNING: Unexpected timeout error: %v\n", errno)
		}
	}

	op.callback(completion.user_data)
	pool_put(&io.completion_pool, completion)
}

writev_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Writev) {
	// Get the iovec slice starting at current offset
	current_iov := op.iov[op.iov_offset:]

	if _, has_timeout := op.timeout_nsec.?; has_timeout {
		if sq_capacity_remaining(io) < 2 {
			queue.push_back(&io.unqueued, completion)
			return
		}
		// The ring is SINGLE_ISSUER, so no producer can consume the second slot
		// between this preflight and the linked timeout reservation.
		sqe, err := io_uring.writev(&io.ring, u64(uintptr(completion)), linux.Fd(op.socket), current_iov, 0)
		assert(err == .None, "preflighted timed writev SQE reservation failed")

		// Set link flag on the writev operation
		sqe.flags |= u8(io_uring.IOSQE_IO_LINK)

		// Add linked timeout with unique user_data (using completion address + 1 to distinguish)
		_, timeout_err := io_uring.link_timeout(&io.ring, u64(uintptr(completion)) + 1, &op.timeout_spec, 0)
		assert(timeout_err == .None, "preflighted writev timeout SQE reservation failed")
		// Both writev and timeout operations are queued.
		io.ios_queued += 2
	} else {
		// Writev without timeout
		_, err := io_uring.writev(&io.ring, u64(uintptr(completion)), linux.Fd(op.socket), current_iov, 0)
		if err == .Submission_Queue_Full {
			queue.push_back(&io.unqueued, completion)
			return
		}

		io.ios_queued += 1
	}
}

writev_advance_iov :: proc(op: ^Op_Writev, bytes_written: int) {
	remaining := bytes_written
	for remaining > 0 && op.iov_offset < len(op.iov) {
		current := &op.iov[op.iov_offset]
		current_len := int(current.iov_len)

		if remaining >= current_len {
			remaining -= current_len
			op.iov_offset += 1
		} else {
			current.iov_base = rawptr(uintptr(current.iov_base) + uintptr(remaining))
			current.iov_len = uint(current_len - remaining)
			remaining = 0
		}
	}
}

writev_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Writev) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			if send_deadline_exhausted(io, completion, op.timeout_nsec, &op.timeout_spec, op.sent, op.callback) {
				return
			}
			writev_enqueue(io, completion, op)
			return
		case .ECANCELED:
			// Writev was canceled due to timeout
			op.callback(completion.user_data, op.sent, net.TCP_Send_Error(.Timeout))
			pool_put(&io.completion_pool, completion)
			return
		case .ETIME:
			// Timeout occurred
			op.callback(completion.user_data, op.sent, net.TCP_Send_Error(.Timeout))
			pool_put(&io.completion_pool, completion)
			return
		case:
			op.callback(completion.user_data, op.sent, net._tcp_send_error(linux.Errno(errno)))
			pool_put(&io.completion_pool, completion)
			return
		}
	}

	bytes_written := int(completion.result)
	op.sent += bytes_written

	if op.all && op.sent < op.len {
		writev_advance_iov(op, bytes_written)

		if send_deadline_exhausted(io, completion, op.timeout_nsec, &op.timeout_spec, op.sent, op.callback) {
			return
		}
		writev_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.sent, nil)
	pool_put(&io.completion_pool, completion)
}

ring_err_to_os_err :: proc(err: io_uring.IO_Uring_Error) -> linux.Errno {
	switch err {
	case .None:
		return .NONE
	case .Params_Outside_Accessible_Address_Space, .Buffer_Invalid, .File_Descriptor_Invalid, .Submission_Queue_Entry_Invalid, .Ring_Shutting_Down:
		return .EFAULT
	case .Arguments_Invalid, .Entries_Zero, .Entries_Too_Large, .Entries_Not_Power_Of_Two, .Opcode_Not_Supported:
		return .EINVAL
	case .Process_Fd_Quota_Exceeded:
		return .EMFILE
	case .System_Fd_Quota_Exceeded:
		return .ENFILE
	case .System_Resources, .Completion_Queue_Overcommitted:
		return .ENOMEM
	case .Permission_Denied:
		return .EPERM
	case .System_Outdated:
		return .ENOSYS
	case .Submission_Queue_Full:
		return .EOVERFLOW
	case .Signal_Interrupt:
		return .EINTR
	case .Unexpected:
		fallthrough
	case:
		return linux.Errno(-1)
	}
}

// verbatim copy of net._sockaddr_storage_to_endpoint.
sockaddr_storage_to_endpoint :: proc(native_addr: ^linux.Sock_Addr_Any) -> (ep: net.Endpoint) {
	#partial switch native_addr.family {
	case .INET:
		addr := cast(^linux.Sock_Addr_In)native_addr
		port := int(addr.sin_port)
		ep = net.Endpoint {
			address = net.IP4_Address(addr.sin_addr),
			port    = port,
		}
	case .INET6:
		addr := cast(^linux.Sock_Addr_In6)native_addr
		port := int(addr.sin6_port)
		ep = net.Endpoint {
			address = net.IP6_Address(transmute([8]u16be)addr.sin6_addr),
			port    = port,
		}
	case:
		panic("native_addr is neither IP4 or IP6 address")
	}
	return
}

// verbatim copy of net._endpoint_to_sockaddr.
endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: linux.Sock_Addr_Any) {
	switch a in ep.address {
	case net.IP4_Address:
		(^linux.Sock_Addr_In)(&sockaddr)^ = linux.Sock_Addr_In {
			sin_family = .INET,
			sin_port   = u16be(ep.port),
			sin_addr   = cast([4]u8)a,
		}
		return
	case net.IP6_Address:
		(^linux.Sock_Addr_In6)(&sockaddr)^ = linux.Sock_Addr_In6 {
			sin6_family = .INET6,
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute([16]u8)a,
		}
		return
	}
	unreachable()
}

// ============================================================================
// Provided Buffer Ring Implementation (PBUF_RING)
// ============================================================================

// Initialize the provided buffer ring tail to 0
_buf_ring_init :: proc(br: ^io_uring.io_uring_buf_ring) {
	sync.atomic_store_explicit(&br.tail, 0, .Release)
}

// Add a buffer to the ring (does not advance tail yet)
// NOTE: This function is currently unused - we use inline buffer addition in _pbuf_ring_init
_buf_ring_add :: proc(br: ^io_uring.io_uring_buf_ring, mask: u32, addr: u64, len: u32, bid: u16) {
	idx := br.tail & u16(mask)
	// IMPORTANT: bufs array is at offset 0 due to union, not offset 16!
	bufs_base := cast([^]io_uring.io_uring_buf)(br)
	buf := &bufs_base[idx]
	buf.addr = addr
	buf.len = len
	buf.bid = bid
	// NOTE: Do NOT write buf.resv! When idx==0, resv overlays with tail field!
}

// Advance the ring tail by count (publishes buffers to kernel)
_buf_ring_advance :: proc(br: ^io_uring.io_uring_buf_ring, count: u16) {
	new_tail := br.tail + count
	// Use atomic store with release semantics to ensure visibility to kernel
	sync.atomic_store_explicit(&br.tail, new_tail, .Release)
}

// Initialize provided buffer ring and register with io_uring
_pbuf_ring_init :: proc(io: ^IO, entries: u32, bgid: u16, allocator := context.allocator) -> linux.Errno {
	assert(entries > 0 && (entries & (entries - 1)) == 0, "entries must be power of 2")
	assert(entries <= 32768, "max entries is 32768")

	// IMPORTANT: Ring size is JUST entries * sizeof(io_uring_buf)
	// The kernel's io_uring_buf_ring is a union where the tail field overlays with bufs[0].resv
	// This means the buffer array and the ring header share the same memory space
	// See linux/io_uring.h for the union definition
	buf_size := uint(size_of(io_uring.io_uring_buf))
	ring_size := uint(entries) * buf_size

	// Allocate page-aligned memory for the ring (user-provided approach)
	ring_memory, alloc_err := linux.mmap(0, ring_size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS}, -1, 0)

	if alloc_err != .NONE || uintptr(ring_memory) == ~uintptr(0) {
		return .ENOMEM
	}

	// mlock the ring memory to prevent page faults (low-latency guarantee)
	mlock_err := linux.mlock(ring_memory, ring_size)
	if mlock_err != .NONE {
		// mlock failure is non-fatal but log it
		fmt.printf("WARNING: mlock failed for pbuf_ring (%v), proceeding without page-fault guarantees\n", mlock_err)
	}

	// Register with kernel using user-provided ring memory
	reg := io_uring.io_uring_buf_reg {
		ring_addr    = u64(uintptr(ring_memory)),
		ring_entries = entries,
		bgid         = bgid,
		flags        = 0, // 0 = user-provided memory
		resv         = {0, 0, 0},
	}

	// Register the buffer ring
	err := io_uring.sys_io_uring_register(u32(io.ring.fd), .REGISTER_PBUF_RING, &reg, 1)
	if err != 0 {
		linux.munmap(ring_memory, ring_size)
		return linux.Errno(-err)
	}

	// Initialize ring state
	io.pbuf_ring.br = (^io_uring.io_uring_buf_ring)(ring_memory)
	io.pbuf_ring.entries = entries
	io.pbuf_ring.mask = entries - 1
	io.pbuf_ring.bgid = bgid
	io.pbuf_ring.ring_memory = ring_memory
	io.pbuf_ring.ring_size = ring_size

	// Initialize ring tail
	_buf_ring_init(io.pbuf_ring.br)

	// Allocate data buffers
	io.pbuf_ring.data_buffers = make([][]byte, entries, allocator)
	for i in 0 ..< entries {
		io.pbuf_ring.data_buffers[i] = make([]byte, _BUFFER_SIZE, allocator)
	}

	// Pre-fill ring with all buffers using local tail
	// IMPORTANT: bufs array starts at offset 0, NOT after the "header"
	// Due to the union, io_uring_buf_ring.bufs overlays with the header fields
	bufs_base := cast([^]io_uring.io_uring_buf)(io.pbuf_ring.br)
	tail := io.pbuf_ring.br.tail

	for i in 0 ..< entries {
		idx := tail & u16(io.pbuf_ring.mask)
		buf_desc := &bufs_base[idx]
		buf_data := io.pbuf_ring.data_buffers[i]

		buf_desc.addr = u64(uintptr(raw_data(buf_data)))
		buf_desc.len = u32(len(buf_data))
		buf_desc.bid = u16(i)
		// NOTE: Do NOT write buf_desc.resv! When idx==0, resv overlays with tail field!

		tail += 1
	}

	// Publish all buffers at once with atomic release store
	sync.atomic_store_explicit(&io.pbuf_ring.br.tail, tail, .Release)
	io.pbuf_ring.produced = u64(entries)

	return .NONE
}

// Destroy provided buffer ring and unregister
_pbuf_ring_destroy :: proc(io: ^IO, allocator := context.allocator) {
	if io.pbuf_ring.br == nil {
		return
	}

	// Unregister buffer ring
	reg := io_uring.io_uring_buf_reg {
		ring_addr    = 0,
		ring_entries = 0,
		bgid         = io.pbuf_ring.bgid,
		flags        = 0,
		resv         = {0, 0, 0},
	}
	io_uring.sys_io_uring_register(u32(io.ring.fd), .UNREGISTER_PBUF_RING, &reg, 1)

	// munmap the ring
	if io.pbuf_ring.ring_memory != nil {
		linux.munmap(io.pbuf_ring.ring_memory, io.pbuf_ring.ring_size)
	}
	// Free data buffers
	for buf in io.pbuf_ring.data_buffers {
		delete(buf, allocator)
	}
	delete(io.pbuf_ring.data_buffers, allocator)

	// Print statistics if enabled
	if io.pbuf_ring.enobufs > 0 {
		fmt.printf("PBUF_RING stats - produced: %d, consumed: %d, enobufs: %d\n", io.pbuf_ring.produced, io.pbuf_ring.consumed, io.pbuf_ring.enobufs)
	}

	io.pbuf_ring = {}
}

// Return a buffer to the ring after use
_pbuf_ring_recycle :: proc(io: ^IO, bid: u16) {
	if int(bid) >= len(io.pbuf_ring.data_buffers) {
		fmt.printf(
			"FATAL: Invalid buffer ID %d (max: %d), produced: %d, consumed: %d\n",
			bid,
			len(io.pbuf_ring.data_buffers),
			io.pbuf_ring.produced,
			io.pbuf_ring.consumed,
		)
		panic("Invalid buffer ID in _pbuf_ring_recycle")
	}

	buf := io.pbuf_ring.data_buffers[bid]

	// Add buffer back to ring at current tail position
	bufs_base := cast([^]io_uring.io_uring_buf)(io.pbuf_ring.br)
	idx := io.pbuf_ring.br.tail & u16(io.pbuf_ring.mask)
	buf_desc := &bufs_base[idx]

	buf_desc.addr = u64(uintptr(raw_data(buf)))
	buf_desc.len = u32(len(buf))
	buf_desc.bid = bid
	// NOTE: Do NOT write buf_desc.resv! When idx==0, resv overlays with tail field!

	// Advance tail to publish the recycled buffer
	_buf_ring_advance(io.pbuf_ring.br, 1)
	io.pbuf_ring.produced += 1
}

_recv_provided :: proc(io: ^IO, socket: net.Any_Socket, user: rawptr, callback: On_Recv_Provided, all := false) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	set_start_time_disabled(completion)
	completion.operation = Op_Recv_Provided {
		callback  = callback,
		socket    = socket,
		bid       = 0, // Will be set by kernel
		buf       = nil, // Will be set from data_buffers[bid]
		aggregate = nil,
		all       = all,
		received  = 0,
		len       = _BUFFER_SIZE,
	}

	recv_provided_enqueue(io, completion, &completion.operation.(Op_Recv_Provided))
	return completion
}

_get_stats :: proc(io: ^IO) -> IO_Stats {
	depth := u32(len(io.ring.sq.sqes))
	ready := io_uring.sq_ready(&io.ring)

	return IO_Stats {
		ring_depth = depth,
		ring_available = depth - ready,
		unqueued_depth = u32(queue.len(io.unqueued)),
		total_completions = io.total_completions,
		total_latency_ns = io.total_latency_ns,
		latency_sample_count = io.latency_sample_count,
	}
}
