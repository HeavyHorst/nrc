package nbio

import "core:container/queue"
import "core:net"
import "core:sys/linux"
import "core:time"

import ulid "../ulid"
import io_uring "_io_uring"

REQUIRED_RING_FLAGS :: io_uring.IORING_SETUP_COOP_TASKRUN | io_uring.IORING_SETUP_SINGLE_ISSUER

set_start_time_disabled :: #force_inline proc(completion: ^Completion) {
	completion.start_time = 0
	completion.sampled = false
}

// Record start_time purely for deadline tracking (clamping linked timeouts on
// retry), never for latency sampling. Used by operations like writev that carry
// send deadlines but are not part of the latency-sampling population.
set_start_time_for_deadline :: #force_inline proc(completion: ^Completion, has_timeout: bool) {
	completion.sampled = false
	completion.start_time = time.to_unix_nanoseconds(ulid.time_now_monotonic()) if has_timeout else 0
}

should_sample_send_latency :: #force_inline proc(io: ^IO) -> bool {
	when ENABLE_STATS {
		seq := io.send_sample_seq
		io.send_sample_seq = seq + 1
		return (seq & u64(STATS_SEND_SAMPLE_MASK)) == 0
	} else {
		return false
	}
}

set_start_time_for_send :: #force_inline proc(io: ^IO, completion: ^Completion, has_timeout: bool) {
	// Record the operation start time when either a send deadline is being
	// tracked (so re-enqueues can clamp the linked timeout to the remaining
	// budget) or for stats sampling. `start_time` is read by
	// `clamp_remaining_send_timeout` on every partial-send / EWOULDBLOCK retry.
	//
	// `should_sample_send_latency` advances the sampling sequence counter as a
	// side effect, so it is evaluated unconditionally (not short-circuited by
	// has_timeout) to keep the 1-in-N sampling cadence stable. Only sends
	// selected by sampling set `sampled = true`; deadline-only sends record
	// start_time without feeding the latency accumulator.
	completion.sampled = should_sample_send_latency(io)
	if has_timeout || completion.sampled {
		completion.start_time = time.to_unix_nanoseconds(ulid.time_now_monotonic())
	} else {
		completion.start_time = 0
	}
}

/*
Initializes the IO type, allocates different things per platform needs

*Allocates Using Provided Allocator*

Inputs:
- io:        The IO struct to initialize
- allocator: (default: context.allocator)
- ring_entries: Optional exact SQ size for constrained tests; zero uses production backoff sizes

Returns:
- err: An error code when something went wrong with the setup of the platform's IO API, 0 otherwise
*/
init :: proc(io: ^IO, alloc := context.allocator, ring_entries: u32 = 0) -> (err: linux.Errno) {
	default_ring_entry_attempts: [7]u32 = {4096, 2048, 1024, 512, 256, 128, 64}
	requested_ring_entry_attempt: [1]u32 = {ring_entries}
	ring_entry_attempts := default_ring_entry_attempts[:]
	if ring_entries > 0 {
		if ring_entries & (ring_entries - 1) != 0 do return .EINVAL
		ring_entry_attempts = requested_ring_entry_attempt[:]
	}

	io.allocator = alloc

	if pool_err := pool_init(&io.completion_pool, allocator = alloc); pool_err != nil {
		return .ENOMEM
	}

	ring: io_uring.IO_Uring
	ring_ready := false
	rerr := io_uring.IO_Uring_Error.None

	// A large ring is ideal, but under parallel load (notably parallel test
	// threads, each holding its own io_uring ring against a shared
	// RLIMIT_MEMLOCK budget) the kernel can refuse ring creation transiently
	// with a resource-exhaustion error. Two layers of backoff are applied:
	//   1. Inner: try progressively smaller rings (entries sweep).
	//   2. Outer: if every ring size is refused for resource reasons, yield
	//      briefly and retry, since sibling rings are typically freed within
	//      milliseconds. Only resource-class errors are retried; structural
	//      errors fail fast.
	RING_INIT_RETRY_ATTEMPTS :: 8
	RING_INIT_RETRY_BACKOFF :: 2 * time.Millisecond

	outer: for _ in 0 ..< RING_INIT_RETRY_ATTEMPTS {
		for entries in ring_entry_attempts {
			params: io_uring.io_uring_params
			params.cq_entries = entries * 2

			ring, rerr = io_uring.io_uring_make(&params, entries, REQUIRED_RING_FLAGS | io_uring.IORING_SETUP_CQSIZE)
			if rerr == .None {
				ring_ready = true
				break outer
			}

			if rerr != .System_Resources && rerr != .Completion_Queue_Overcommitted {
				pool_destroy(&io.completion_pool)
				return ring_err_to_os_err(rerr)
			}
		}

		// Every ring size was refused for resource reasons; let sibling rings
		// drain before retrying the full sweep.
		time.sleep(RING_INIT_RETRY_BACKOFF)
	}

	if !ring_ready {
		pool_destroy(&io.completion_pool)
		return ring_err_to_os_err(rerr)
	}

	io.ring = ring

	if qerr := queue.init(&io.unqueued, allocator = alloc); qerr != nil {
		io_uring.io_uring_destroy(&io.ring)
		pool_destroy(&io.completion_pool)
		return .ENOMEM
	}

	if qerr := queue.init(&io.completed, allocator = alloc); qerr != nil {
		queue.destroy(&io.unqueued)
		io_uring.io_uring_destroy(&io.ring)
		pool_destroy(&io.completion_pool)
		return .ENOMEM
	}

	return
}

/*
Returns the number of in-progress IO to be completed.
*/
num_waiting :: #force_inline proc(io: ^IO) -> int {
	return io.completion_pool.num_waiting
}

/*
Deallocates anything that was allocated when calling init()

Inputs:
- io: The IO instance to deallocate

*Deallocates with the allocator that was passed with the init() call*
*/
destroy :: proc(io: ^IO) {
	context.allocator = io.allocator

	// Destroy provided buffer ring if initialized
	if io.pbuf_ring.br != nil {
		_pbuf_ring_destroy(io)
	}

	queue.destroy(&io.unqueued)
	queue.destroy(&io.completed)
	pool_destroy(&io.completion_pool)
	io_uring.io_uring_destroy(&io.ring)
}

/*
The place where the magic happens, each time you call this the IO implementation checks its state
and calls any callbacks which are ready. You would typically call this in a loop

Inputs:
- io: The IO instance to tick

Returns:
- err: An error code when something went when retrieving events, 0 otherwise
*/
has_userspace_work :: #force_inline proc(io: ^IO) -> bool {
	return queue.len(io.unqueued) > 0 || queue.len(io.completed) > 0 || io.ios_queued > 0 || io_uring.cq_ready(&io.ring) > 0
}

wait_for_ring_events :: proc(io: ^IO, timeout_nsec: time.Duration, wake_fd: linux.Fd, timed_out, externally_woken: ^bool) -> linux.Errno {
	if timeout_nsec <= 0 {
		timed_out^ = true
		return .NONE
	}

	wait_started_at := ulid.time_now_monotonic()
	remaining := timeout_nsec
	poll_fds: [2]linux.Poll_Fd = {{fd = io.ring.fd, events = {.IN, .ERR, .HUP}}, {fd = wake_fd, events = {.IN, .ERR, .HUP}}}
	poll_count := 1
	if wake_fd >= 0 do poll_count = 2

	for {
		remaining_ns := time.duration_nanoseconds(remaining)
		timeout_spec := linux.Time_Spec {
			time_sec  = uint(remaining_ns / NANOSECONDS_PER_SECOND),
			time_nsec = uint(remaining_ns % NANOSECONDS_PER_SECOND),
		}

		n, err := linux.ppoll(poll_fds[:poll_count], &timeout_spec, nil)
		if err == .NONE {
			timed_out^ = n == 0
			if poll_count == 2 && poll_fds[1].revents != {} {
				value: u64
				for {
					_, read_err := linux.read(wake_fd, ([^]byte)(&value)[:size_of(value)])
					if read_err == .EINTR do continue
					if read_err != .NONE && read_err != .EAGAIN do return read_err
					break
				}
				externally_woken^ = true
			}
			return .NONE
		}

		if err != .EINTR {
			return err
		}

		elapsed := time.diff(wait_started_at, ulid.time_now_monotonic())
		if elapsed >= timeout_nsec {
			timed_out^ = true
			return .NONE
		}

		remaining = timeout_nsec - elapsed
	}
}

// When yield_after_callbacks is set, wait up to timeout_nsec only while no
// callback work is available. This lets event-loop callers publish work staged
// outside nbio before the original idle wait budget expires.
tick :: proc(io: ^IO, timeout_nsec: time.Duration, wake_fd: linux.Fd = -1, yield_after_callbacks := false) -> linux.Errno {
	if ferr, had_callbacks := flush(io, 0); ferr != .NONE {
		return ferr
	} else if yield_after_callbacks && had_callbacks {
		return .NONE
	}

	if timeout_nsec <= 0 {
		return .NONE
	}

	started_at := ulid.time_now_monotonic()
	for {
		if has_userspace_work(io) {
			if ferr, had_callbacks := flush(io, 0); ferr != .NONE {
				return ferr
			} else if yield_after_callbacks && had_callbacks {
				return .NONE
			}
		}

		elapsed := time.diff(started_at, ulid.time_now_monotonic())
		if elapsed >= timeout_nsec do break

		if has_userspace_work(io) {
			continue
		}

		remaining := timeout_nsec - elapsed
		if io.ios_in_kernel == 0 && wake_fd < 0 {
			time.sleep(remaining)
			break
		}

		wait_timed_out := false
		externally_woken := false
		if werr := wait_for_ring_events(io, remaining, wake_fd, &wait_timed_out, &externally_woken); werr != .NONE do return werr
		if wait_timed_out do break
		if externally_woken do break

		// Wakeups must drain immediately; deferring to the deadline adds ~1ms
		// of latency per protocol step in the worker loop.
		if ferr, had_callbacks := flush(io, 0); ferr != .NONE {
			return ferr
		} else if yield_after_callbacks && had_callbacks {
			return .NONE
		}
	}

	// Final non-blocking pass to pick up CQEs that raced with timeout expiry.
	ferr, _ := flush(io, 0)
	return ferr
}

// Submit any SQEs prepared by callbacks without running completion callbacks.
// This is used by latency-sensitive control paths that want an already-queued
// send handed to the kernel before doing more userspace fanout work.
submit_pending :: proc(io: ^IO) -> linux.Errno {
	return flush_submissions(io, 0)
}

// Submit all prepared and SQ-capacity-deferred operations without running
// completion callbacks. Useful for publishing a userspace batch at one explicit
// boundary even when the kernel accepted a reduced-size ring at startup.
submit_all_pending :: proc(io: ^IO) -> linux.Errno {
	return submit_all_pending_internal(io)
}

/*
Starts listening on the given socket

Inputs:
- socket:  The socket to start listening
- backlog: The amount of events to keep in the backlog when they are not consumed

Returns:
- err: A network error that happened when starting listening
*/
listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	errno := linux.listen(linux.Fd(socket), i32(backlog))
	if errno != .NONE {
		return net.Listen_Error(errno)
	}
	return nil
}

/*
Using the given socket, accepts incoming connections, calling the callback when connections are accepted

*Due to platform limitations, you must pass a socket that was opened using the `open_socket` and related procedures from this package*

Inputs:
- io:        The IO instance to use
- socket:    A bound and listening socket *that was created using this package*
- user:      A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback:  The callback that is called when the operation completes, see docs for `On_Accept` for its arguments
- multishot: If true, accepts multiple connections with a single operation. The callback will be called for each accepted connection until an error occurs. If false (default), accepts one connection per call.
*/
accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept, multishot := false) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	set_start_time_disabled(completion)
	completion.operation = Op_Accept {
		callback    = callback,
		socket      = socket,
		sockaddrlen = i32(size_of(linux.Sock_Addr_Any)),
		multishot   = multishot,
	}

	accept_enqueue(io, completion, &completion.operation.(Op_Accept))
	return completion
}

/*
Closes the given `Closable` socket or file handle that was originally created by this package.

Close does not cancel operations already submitted against the descriptor. Callers that
require retirement before reuse must stop new I/O, make pending operations terminal, and
observe every terminal callback before calling close. Shutting down both socket directions
prompts pending socket I/O to terminate but is not itself a completion barrier. Callers that
close earlier must keep callback state valid and generation-check late completions.

*Due to platform limitations, you must pass a `Closable` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The `Closable` socket or handle (created using/by this package) to close
- user:     An optional pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: An optional callback that is called when the operation completes, see docs for `On_Close` for its arguments
*/
close :: proc(io: ^IO, fd: Closable, user: rawptr = nil, callback: On_Close = empty_on_close) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	set_start_time_disabled(completion)

	handle: linux.Fd


	


	//odinfmt:disable
	switch h in fd {
	case net.TCP_Socket: handle = linux.Fd(h)
	case net.UDP_Socket: handle = linux.Fd(h)
	case net.Socket:     handle = linux.Fd(h)
	case linux.Fd:       handle = h
	} //odinfmt:enable

	completion.operation = Op_Close {
		callback = callback,
		fd       = handle,
	}

	close_enqueue(io, completion, &completion.operation.(Op_Close))
	return completion
}

/*
Shuts down part or all communication on the given socket.

*Due to platform limitations, you must pass a `Closable` socket or handle that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The `Closable` socket or handle to shutdown
- manner:   Which direction to shutdown (`Receive`, `Send`, or `Both`)
- user:     An optional pointer passed through to the callback
- callback: An optional callback called when the operation completes, see docs for `On_Shutdown`
*/
shutdown :: proc(io: ^IO, fd: Closable, manner: net.Shutdown_Manner = .Both, user: rawptr = nil, callback: On_Shutdown = empty_on_shutdown) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	set_start_time_disabled(completion)

	handle: linux.Fd


	


	//odinfmt:disable
	switch h in fd {
	case net.TCP_Socket: handle = linux.Fd(h)
	case net.UDP_Socket: handle = linux.Fd(h)
	case net.Socket:     handle = linux.Fd(h)
	case linux.Fd:       handle = h
	} //odinfmt:enable

	completion.operation = Op_Shutdown {
		callback = callback,
		fd       = handle,
		how      = linux.Shutdown_How(manner),
	}

	shutdown_enqueue(io, completion, &completion.operation.(Op_Shutdown))
	return completion
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	_: Maybe(net.Endpoint) = nil,
	all := false,
	timeout: Maybe(time.Duration) = nil,
) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	timeout_nsec: Maybe(i64) = nil
	timeout_spec := linux.Time_Spec{}
	has_timeout := false
	if dur, ok := timeout.?; ok {
		has_timeout = true
		dur_nsec := time.duration_nanoseconds(dur)
		timeout_nsec = dur_nsec
		timeout_spec = linux.Time_Spec {
			time_sec  = uint(dur_nsec / NANOSECONDS_PER_SECOND),
			time_nsec = uint(dur_nsec % NANOSECONDS_PER_SECOND),
		}
	}

	completion.ctx = context
	completion.user_data = user
	set_start_time_for_send(io, completion, has_timeout)
	completion.operation = Op_Send {
		callback     = callback,
		socket       = socket,
		buf          = buf,
		all          = all,
		len          = len(buf),
		timeout_nsec = timeout_nsec,
		timeout_spec = timeout_spec,
	}

	send_enqueue(io, completion, &completion.operation.(Op_Send))
	return completion
}

_read_file_at :: proc(io: ^IO, fd: linux.Fd, buf: []byte, offset: u64, user: rawptr, callback: On_File_Read) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	set_start_time_disabled(completion)
	completion.operation = Op_File_Read {
		callback = callback,
		fd       = fd,
		buf      = buf,
		offset   = offset,
	}
	file_read_enqueue(io, completion, &completion.operation.(Op_File_Read))
	return completion
}

_sync_file :: proc(io: ^IO, fd: linux.Fd, user: rawptr, callback: On_File_Sync) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	set_start_time_disabled(completion)
	completion.operation = Op_File_Sync {
		callback = callback,
		fd       = fd,
	}
	file_sync_enqueue(io, completion, &completion.operation.(Op_File_Sync))
	return completion
}

_writev :: proc(
	io: ^IO,
	socket: net.TCP_Socket,
	iov: []iovec,
	user: rawptr,
	callback: On_Writev,
	all := false,
	timeout: Maybe(time.Duration) = nil,
) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	timeout_nsec: Maybe(i64) = nil
	timeout_spec := linux.Time_Spec{}
	has_timeout := false
	if dur, ok := timeout.?; ok {
		has_timeout = true
		dur_nsec := time.duration_nanoseconds(dur)
		timeout_nsec = dur_nsec
		timeout_spec = linux.Time_Spec {
			time_sec  = uint(dur_nsec / NANOSECONDS_PER_SECOND),
			time_nsec = uint(dur_nsec % NANOSECONDS_PER_SECOND),
		}
	}

	// Calculate total bytes to send
	total_len := 0
	for entry in iov {
		total_len += int(entry.iov_len)
	}

	completion.ctx = context
	completion.user_data = user
	set_start_time_for_deadline(completion, has_timeout)
	completion.operation = Op_Writev {
		callback     = callback,
		socket       = socket,
		iov          = iov,
		iov_offset   = 0,
		len          = total_len,
		sent         = 0,
		all          = all,
		timeout_nsec = timeout_nsec,
		timeout_spec = timeout_spec,
	}

	writev_enqueue(io, completion, &completion.operation.(Op_Writev))
	return completion
}

/*
Schedules a callback to be called after the given duration elapses.

The accuracy depends on the time between calls to `tick`.
When you call it in a loop with no blocks or very expensive calculations in other scheduled event callbacks
it is reliable to about a ms of difference (so timeout of 10ms would almost always be ran between 10ms and 11ms).

Inputs:
- io:       The IO instance to use
- dur:      The minimum duration to wait before calling the given callback
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Timeout` for its arguments
*/
timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	set_start_time_disabled(completion)

	nsec := time.duration_nanoseconds(dur)
	completion.operation = Op_Timeout {
		callback = callback,
		expires = linux.Time_Spec{time_sec = uint(nsec / NANOSECONDS_PER_SECOND), time_nsec = uint(nsec % NANOSECONDS_PER_SECOND)},
	}

	timeout_enqueue(io, completion, &completion.operation.(Op_Timeout))
	return completion
}

// CANCEL_MARKER is the user_data value used for cancellation operations.
//
// This value is chosen specifically to be safely ignored in flush_completions:
//
// 1. Non-zero: user_data == 0 is reserved for system timeouts (tick loop timing).
//    The completion loop checks for this first and decrements the timeout counter.
//
// 2. Odd (bit 0 set): Valid Completion pointers are always word-aligned (even addresses).
//    Linked timeout CQEs use (completion_addr + 1) as user_data, making them odd.
//    The completion loop skips any odd user_data to avoid double-processing linked
//    timeout results (the main operation's CQE carries the actual result).
//
// By using 1, the cancel CQE is silently discarded while the original operation's
// callback still receives its terminal result, allowing proper cleanup.
CANCEL_MARKER :: 1

/*
Cancels a pending timeout operation. Callback delivery remains asynchronous: the
terminal callback runs during a subsequent tick even when the timeout had not yet
entered the kernel.

The original timeout callback will run once, allowing cleanup. `On_Timeout` has no
error argument, so cancellation and expiry have the same callback shape. The returned
Completion handle is one-shot and valid only while pending; discard it when canceling
or when its terminal callback runs.

Inputs:
- io:     The IO instance to use
- target: The completion handle returned by the original timeout() call

Note: The cancel operation itself does not have a callback. The original timeout
callback will fire with the cancellation result.
*/
cancel :: proc(io: ^IO, target: ^Completion) {
	if target == nil do return
	if cancel_unqueued_timeout(io, target) do return

	// Use TIMEOUT_REMOVE to cancel a pending timeout
	// The user_data is CANCEL_MARKER (odd, non-zero) so we can identify and skip it
	// The addr field contains the user_data of the timeout to cancel
	_, err := io_uring.timeout_remove(&io.ring, CANCEL_MARKER, u64(uintptr(target)), 0)
	if err == .Submission_Queue_Full {
		// Publish the already-prepared SQEs to free userspace SQ capacity, then
		// reserve the cancellation SQE. The target remains in kernel ownership
		// until its normal ECANCELED completion is dispatched.
		if flush_err := flush_submissions(io, 0); flush_err != .NONE do return
		_, err = io_uring.timeout_remove(&io.ring, CANCEL_MARKER, u64(uintptr(target)), 0)
		if err != .None do return
	}

	// The cancel SQE still needs to be submitted even though its CQE is skipped.
	io.ios_queued += 1
}

/*
Cancels a pending recv_provided operation. Its callback is delivered exactly once
with a terminal receive error. Cancellation also disables ENOBUFS/EWOULDBLOCK
retries immediately, including when the original CQE was already awaiting dispatch.

The Completion handle is one-shot and valid only while pending. Discard it when
cancelling or when its terminal callback runs.
*/
cancel_recv_provided :: proc(io: ^IO, target: ^Completion) {
	if target == nil do return

	is_recv := false
	#partial switch &op in target.operation {
	case Op_Recv_Provided:
		if op.cancelled do return
		op.cancelled = true
		is_recv = true
	case:
		return
	}
	if !is_recv do return
	if cancel_unqueued_recv_provided(io, target) do return

	cancel_completion := pool_get(&io.completion_pool)
	cancel_completion.ctx = context
	cancel_completion.user_data = nil
	set_start_time_disabled(cancel_completion)
	cancel_completion.operation = Op_Recv_Cancel {
		target = target,
	}

	_, err := io_uring.async_cancel(&io.ring, u64(uintptr(cancel_completion)), u64(uintptr(target)))
	if err == .Submission_Queue_Full {
		if flush_err := flush_submissions(io, 0); flush_err == .NONE {
			_, err = io_uring.async_cancel(&io.ring, u64(uintptr(cancel_completion)), u64(uintptr(target)))
		}
	}
	if err != .None {
		pool_put(&io.completion_pool, cancel_completion)
		return
	}

	#partial switch &op in target.operation {
	case Op_Recv_Provided:
		op.cancel_pending = true
	case:
		unreachable()
	}
	io.ios_queued += 1
}
