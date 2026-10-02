package nbio

import "core:net"
import "core:sys/linux"
import "core:time"

import io_uring "_io_uring"

/*
The main IO type that holds the platform dependant implementation state passed around most procedures in this package
*/
IO :: _IO

// Compile-time toggle for internal latency accounting.
// Set with: `-define:NBIO_ENABLE_STATS=false`
ENABLE_STATS :: #config(NBIO_ENABLE_STATS, true)

// Sample mask for send latency measurements.
// Use power-of-two-minus-one values for best performance:
// 0 => sample every send, 1 => every 2 sends, 3 => every 4 sends, 63 => every 64 sends.
STATS_SEND_SAMPLE_MASK :: #config(NBIO_STATS_SEND_SAMPLE_MASK, 63)

/*
The callback for non blocking `timeout` calls

Inputs:
- user: A passed through pointer from initiation to its callback
*/
On_Timeout :: #type proc(user: rawptr)

/*
Creates a socket, sets non blocking mode, relates it to the given IO, binds the socket to the given endpoint and starts listening

Inputs:
- io:       The IO instance to initialize the socket on/with
- endpoint: Where to bind the socket to

Returns:
- socket: The opened, bound and listening socket
- err:    A network error that happened while opening
*/
open_and_listen_tcp :: proc(io: ^IO, ep: net.Endpoint) -> (socket: net.TCP_Socket, err: net.Network_Error) {
	family := net.family_from_endpoint(ep)
	sock := open_socket(io, family, .TCP) or_return
	socket = sock.(net.TCP_Socket)

	if err = net.bind(socket, ep); err != nil {
		close(io, socket)
		return
	}

	if err = listen(socket, 4096); err != nil {
		close(io, socket)
	}
	return
}

/*
The callback for non blocking `close` requests

Inputs:
- user: A passed through pointer from initiation to its callback
- ok:   Whether the operation suceeded sucessfully
*/
On_Close :: #type proc(user: rawptr, ok: bool)

@(private)
empty_on_close :: proc(_: rawptr, _: bool) {}

/*
The callback for non blocking `shutdown` requests

Inputs:
- user: A passed through pointer from initiation to its callback
- err:  A shutdown error if one occurred
*/
On_Shutdown :: #type proc(user: rawptr, err: net.Shutdown_Error)

@(private)
empty_on_shutdown :: proc(_: rawptr, _: net.Shutdown_Error) {}

/*
A union of types that are `close`'able by this package
*/
Closable :: union #no_nil {
	net.TCP_Socket,
	net.UDP_Socket,
	net.Socket,
	linux.Fd,
}

/*
The callback for non blocking `accept` requests

Inputs:
- user:   A passed through pointer from initiation to its callback
- client: The socket to communicate through with the newly accepted client
- source: The origin of the client
- err:    A network error that occured during the accept process
*/
On_Accept :: #type proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)

/*
The callback for non blocking `recv_provided` requests using registered buffers

Inputs:
- user:       A passed through pointer from initiation to its callback
- received:   The amount of bytes that were read
- buf:        The registered buffer slice containing the received data
- udp_client: If the given socket was a `net.UDP_Socket`, this will be the client that was received from
- err:        A network error if it occured
*/
On_Recv_Provided :: #type proc(user: rawptr, received: int, buf: []byte, udp_client: Maybe(net.Endpoint), err: net.Network_Error)

/*
Initialize the provided buffer ring for this IO instance

Inputs:
- io: The IO instance to initialize buffer ring for
- entries: Number of buffers (must be power of 2, max 32768)
- bgid: Buffer group ID (default: 1)

Returns:
- linux.Errno: NONE on success, error code on failure
*/
pbuf_ring_init :: proc(io: ^IO, entries: u32 = _BUFFER_POOL_SIZE, bgid: u16 = 1, allocator := context.allocator) -> linux.Errno {
	return _pbuf_ring_init(io, entries, bgid, allocator)
}

/*
Destroy the provided buffer ring for this IO instance

Inputs:
- io: The IO instance to destroy buffer ring for
*/
pbuf_ring_destroy :: proc(io: ^IO, allocator := context.allocator) {
	_pbuf_ring_destroy(io, allocator)
}

// Buffer pool configuration constants (exported from internal)
BUFFER_POOL_SIZE :: _BUFFER_POOL_SIZE
BUFFER_SIZE :: _BUFFER_SIZE

/*
Receives from the given socket using a provided buffer (PBUF_RING), and calls the given callback

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use (must have initialized pbuf_ring)
- socket:   Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Recv_Fixed` for its arguments
*/
recv_provided :: proc(io: ^IO, socket: net.Any_Socket, user: rawptr, callback: On_Recv_Provided, all := false) -> ^Completion {
	return _recv_provided(io, socket, user, callback, all)
}

/*
The callback for non blocking `send` and `send_all` requests

Inputs:
- user: A passed through pointer from initiation to its callback
- sent: The amount of bytes that were sent over the connection
- err:  A network error if it occured
*/
On_Sent :: #type proc(user: rawptr, sent: int, err: net.Network_Error)

/*
The callback for non blocking `writev` and `writev_all` requests

Inputs:
- user: A passed through pointer from initiation to its callback
- sent: The total amount of bytes that were sent
- err:  A network error if it occured
*/
On_Writev :: #type proc(user: rawptr, sent: int, err: net.Network_Error)

/*
The callback for a positional regular-file read. `err == .NONE` means the read
completed successfully; `read` may be smaller than the buffer length (including
zero at EOF). A short read is not an error. On error, `read` is zero.
*/
On_File_Read :: #type proc(user: rawptr, read: int, err: linux.Errno)

// The callback for a regular-file durability synchronization.
On_File_Sync :: #type proc(user: rawptr, err: linux.Errno)

// Maximum buffer length representable by an io_uring READ SQE.
MAX_FILE_READ_SIZE :: int(max(u32))

/*
Reads at most len(buf) bytes from an already-open regular file at `offset`.
This is one positional read, not a read-exactly operation, and does not change
the file descriptor's current position. The descriptor and caller-owned buffer
must remain valid and untouched until the callback runs. Empty buffers are
allowed. The returned Completion is a pending-operation handle and is invalid
after callback delivery.
*/
read_file_at :: proc(io: ^IO, fd: linux.Fd, buf: []byte, offset: u64, user: rawptr, callback: On_File_Read) -> ^Completion {
	assert(len(buf) <= MAX_FILE_READ_SIZE, "read_file_at buffer exceeds io_uring's u32 length bound")
	return _read_file_at(io, fd, buf, offset, user, callback)
}

// Synchronizes an already-open regular file without blocking the submitting thread.
// The descriptor must remain valid until the callback runs.
sync_file :: proc(io: ^IO, fd: linux.Fd, user: rawptr, callback: On_File_Sync) -> ^Completion {
	return _sync_file(io, fd, user, callback)
}

// Re-export iovec type from io_uring
iovec :: io_uring.iovec

/*
Sends the bytes from the given buffer over the socket connection, and calls the given callback

This will keep sending until either an error or the full buffer is sent

*Prefer using the `send` proc group*

*Due to platform limitations, you must pass a `net.TCP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- socket:   a `net.TCP_Socket` (that was opened/returned by this package) to send to
- buf:      The buffer send
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Sent` for its arguments
*/
send_all_tcp :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent) {
	_send(io, socket, buf, user, callback, all = true)
}

send_all_tcp_timeout :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, timeout: time.Duration, user: rawptr, callback: On_Sent) {
	_send(io, socket, buf, user, callback, all = true, timeout = timeout)
}

/*
Sends the bytes from the given buffer over the socket connection to the given endpoint, and calls the given callback

This will keep sending until either an error or the full buffer is sent

*Prefer using the `send` proc group*

*Due to platform limitations, you must pass a `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- endpoint: The endpoint to send bytes to over the socket
- socket:   a `net.UDP_Socket` (that was opened/returned by this package) to send to
- buf:      The buffer send
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Sent` for its arguments
*/
send_all_udp :: proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, user: rawptr, callback: On_Sent) {
	_send(io, socket, buf, user, callback, endpoint, all = true)
}

/*
Sends the bytes from the given buffer over the socket connection, and calls the given callback

This will keep sending until either an error or the full buffer is sent

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*
*/
send_all :: proc {
	send_all_udp,
	send_all_tcp,
	send_all_tcp_timeout,
}

/*
Sends multiple buffers over the socket using writev (scatter-gather I/O), and calls the callback

This will keep sending until either an error or all bytes are sent (writev_all semantics).
The iov slice and its payloads must remain valid until the callback is invoked. Partial
progress advances iov_base/iov_len in place; callers must treat that metadata as owned
by nbio until completion and rebuild it before reuse.

*Due to platform limitations, you must pass a `net.TCP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- socket:   a `net.TCP_Socket` (that was opened/returned by this package) to send to
- iov:      The iovec array to send (must remain valid and untouched until callback)
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Writev` for its arguments
*/
writev_all_tcp :: proc(io: ^IO, socket: net.TCP_Socket, iov: []iovec, user: rawptr, callback: On_Writev) {
	_writev(io, socket, iov, user, callback, all = true)
}

writev_all_tcp_timeout :: proc(io: ^IO, socket: net.TCP_Socket, iov: []iovec, timeout: time.Duration, user: rawptr, callback: On_Writev) {
	_writev(io, socket, iov, user, callback, all = true, timeout = timeout)
}

/*
Sends multiple buffers over the socket using writev (scatter-gather I/O)

This will keep sending until either an error or all bytes are sent (writev_all semantics).

*Due to platform limitations, you must pass a `net.TCP_Socket` that was opened/returned using/by this package*
*/
writev_all :: proc {
	writev_all_tcp,
	writev_all_tcp_timeout,
}

MAX_USER_ARGUMENTS :: size_of(rawptr) * 5

Completion :: struct {
	// Implementation specifics, don't use outside of implementation/os.
	using _:   _Completion,
	user_data: rawptr,

	// Callback pointer and user args passed in poly variants.
	user_args: [MAX_USER_ARGUMENTS + size_of(rawptr)]byte,
}

@(private)
Operation :: union #no_nil {
	Op_Accept,
	Op_Close,
	Op_Shutdown,
	Op_Recv_Provided,
	Op_Recv_Cancel,
	Op_Send,
	Op_Timeout,
	Op_Writev,
	Op_File_Read,
	Op_File_Sync,
}

IO_Stats :: struct {
	ring_depth:           u32,
	ring_available:       u32,
	unqueued_depth:       u32, // Number of operations waiting for SQ slot
	total_completions:    u64,
	total_latency_ns:     u64,
	latency_sample_count: u64,
}

get_stats :: proc(io: ^IO) -> IO_Stats {
	return _get_stats(io)
}
