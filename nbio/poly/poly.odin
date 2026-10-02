// Package nbio/poly contains variants of the nbio procedures that use generic/poly data
// so users can avoid casts and use multiple arguments.
//
// Please reference the documentation in `nbio`.
//
// Intention is to import this like so `import nbio "nbio/poly"`
package poly

import "core:mem"
import "core:net"
import "core:sys/linux"
import "core:time"

import nbio ".."

// Because mem is only used inside the poly procs, the checker thinks we aren't using it.
_ :: mem

/// Re-export `nbio` stuff that is not wrapped in this package.

Completion :: nbio.Completion
IO :: nbio.IO
init :: nbio.init
tick :: nbio.tick
submit_pending :: nbio.submit_pending
submit_all_pending :: nbio.submit_all_pending
num_waiting :: nbio.num_waiting
destroy :: nbio.destroy
cancel :: nbio.cancel
cancel_recv_provided :: nbio.cancel_recv_provided
shutdown :: nbio.shutdown
pbuf_ring_init :: nbio.pbuf_ring_init
pbuf_ring_destroy :: nbio.pbuf_ring_destroy
open_socket :: nbio.open_socket
open_and_listen_tcp :: nbio.open_and_listen_tcp
listen :: nbio.listen
Closable :: nbio.Closable
BUFFER_SIZE :: nbio.BUFFER_SIZE
get_stats :: nbio.get_stats
iovec :: nbio.iovec

/// Positional regular-file read. The buffer remains caller-owned and pinned
/// through callback delivery; see nbio.read_file_at for result semantics.
read_file_at :: proc {
	read_file_at1,
	read_file_at2,
}

read_file_at1 :: proc(
	io: ^nbio.IO,
	fd: linux.Fd,
	buf: []byte,
	offset: u64,
	p: $T,
	callback: $C/proc(p: T, read: int, err: linux.Errno),
) -> ^nbio.Completion where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.read_file_at(io, fd, buf, offset, nil, proc(raw: rawptr, read: int, err: linux.Errno) {
		completion := (^nbio.Completion)(raw)
		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		cb(p, read, err)
	})
	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	completion.user_data = completion
	return completion
}

read_file_at2 :: proc(
	io: ^nbio.IO,
	fd: linux.Fd,
	buf: []byte,
	offset: u64,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, read: int, err: linux.Errno),
) -> ^nbio.Completion where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.read_file_at(io, fd, buf, offset, nil, proc(raw: rawptr, read: int, err: linux.Errno) {
		completion := (^nbio.Completion)(raw)
		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		cb(p, p2, read, err)
	})
	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	completion.user_data = completion
	return completion
}

/// Regular-file durability synchronization.
sync_file :: proc(
	io: ^nbio.IO,
	fd: linux.Fd,
	p: $T,
	callback: $C/proc(p: T, err: linux.Errno),
) -> ^nbio.Completion where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.sync_file(io, fd, nil, proc(raw: rawptr, err: linux.Errno) {
		completion := (^nbio.Completion)(raw)
		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		cb(p, err)
	})
	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	completion.user_data = completion
	return completion
}

/// Timeout

timeout :: proc {
	timeout1,
	timeout2,
	timeout3,
}

timeout1 :: proc(io: ^nbio.IO, dur: time.Duration, p: $T, callback: $C/proc(p: T)) -> ^nbio.Completion where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio.timeout(io, dur, nil, proc(completion: rawptr) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

timeout2 :: proc(
	io: ^nbio.IO,
	dur: time.Duration,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2),
) -> ^nbio.Completion where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.timeout(io, dur, nil, proc(completion: rawptr) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

timeout3 :: proc(
	io: ^nbio.IO,
	dur: time.Duration,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.timeout(io, dur, nil, proc(completion: rawptr) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
}

/// Close

close :: proc {
	close_no_cb,
	close1,
	close2,
	close3,
}

close_no_cb :: proc(io: ^nbio.IO, fd: nbio.Closable) {
	nbio.close(io, fd)
}

close1 :: proc(io: ^nbio.IO, fd: nbio.Closable, p: $T, callback: $C/proc(p: T, ok: bool)) where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio.close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, ok)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
}

close2 :: proc(
	io: ^nbio.IO,
	fd: nbio.Closable,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, ok: bool),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, ok)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
}

close3 :: proc(
	io: ^nbio.IO,
	fd: nbio.Closable,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, ok: bool),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T3):]))^

		cb(p, p2, p3, ok)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
}

/// Accept

accept :: proc {
	accept1,
	accept2,
	accept3,
}

accept1 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	p: $T,
	callback: $C/proc(p: T, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error),
	multishot := false,
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)
			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^

			cb(p, client, source, err)
		}, multishot)

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
}

accept2 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error),
	multishot := false,
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^
			p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

			cb(p, p2, client, source, err)
		}, multishot)

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
}

accept3 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error),
	multishot := false,
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^
			p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
			p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

			cb(p, p2, p3, client, source, err)
		}, multishot)

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
}

/// Connect

connect :: proc {
	connect1,
	connect2,
	connect3,
}

connect1 :: proc(
	io: ^nbio.IO,
	endpoint: net.Endpoint,
	p: $T,
	callback: $C/proc(p: T, socket: net.TCP_Socket, err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion, err := nbio.connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, socket, err)
	})
	if err != nil {
		callback(p, {}, err)
		return
	}

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
}

connect2 :: proc(
	io: ^nbio.IO,
	endpoint: net.Endpoint,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, socket: net.TCP_Socket, err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion, err := nbio.connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, socket, err)
	})
	if err != nil {
		callback(p, p2, {}, err)
		return
	}

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
}

connect3 :: proc(
	io: ^nbio.IO,
	endpoint: net.Endpoint,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, socket: net.TCP_Socket, err: net.Network_Error),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	completion, err := nbio.connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, socket, err)
	})
	if err != nil {
		callback(p, p2, p3, {}, err)
		return
	}

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
}

/// Internal Recv

_recv :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	all: bool,
	p: $T,
	callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, received, udp_client, err)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
}

_recv2 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	all: bool,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, received, udp_client, err)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
}

_recv3 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	all: bool,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, received, udp_client, err)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
}

/// Recv

recv :: proc {
	recv1,
	recv2,
	recv3,
}

/// Recv Provided

recv_provided :: proc {
	recv_provided1,
}

recv_provided1 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	p: $T,
	callback: $C/proc(p: T, received: int, buf: []byte, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) -> ^nbio.Completion where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio.recv_provided(
		io,
		socket,
		nil,
		proc(completion: rawptr, received: int, buf: []byte, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^

			cb(p, received, buf, udp_client, err)
		},
	)

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

recv1 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_recv(io, socket, buf, false, p, callback)
}

recv2 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_recv2(io, socket, buf, false, p, p2, callback)
}

recv3 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_recv3(io, socket, buf, false, p, p2, p3, callback)
}

/// Recv All

recv_all :: proc {
	recv_all1,
	recv_all2,
	recv_all3,
}

recv_all1 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_recv(io, socket, buf, true, p, callback)
}

recv_all2 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_recv_all2(io, socket, buf, false, p, p2, callback)
}

recv_all3 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	_recv_all2(io, socket, buf, false, p, p2, p3, callback)
}

/// Send

send :: proc {
	send_tcp1,
	send_tcp2,
	send_tcp3,
	send_tcp1_timeout,
	send_tcp2_timeout,
	send_tcp3_timeout,
}

/// Send Internal

_send :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
	endpoint: Maybe(net.Endpoint) = nil,
	all := false,
	timeout: Maybe(time.Duration) = nil,
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^

			cb(p, sent, err)
		}, endpoint, all, timeout)

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
}

_send2 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
	endpoint: Maybe(net.Endpoint) = nil,
	all := false,
	timeout: Maybe(time.Duration) = nil,
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^
			p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

			cb(p, p2, sent, err)
		}, endpoint, all, timeout)

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
}

_send3 :: proc(
	io: ^nbio.IO,
	socket: net.Any_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error),
	endpoint: Maybe(net.Endpoint) = nil,
	all := false,
	timeout: Maybe(time.Duration) = nil,
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^
			p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
			p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

			cb(p, p2, p3, sent, err)
		}, endpoint, all, timeout)

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
}

/// Send TCP

send_tcp1 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_send(io, socket, buf, p, callback)
}

send_tcp2 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_send2(io, socket, buf, p, p2, callback)
}

send_tcp3 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	_send3(io, socket, buf, p, p2, p3, callback)
}

/// Send TCP with timeout

send_tcp1_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	timeout: time.Duration,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_send(io, socket, buf, p, callback, timeout = timeout)
}

send_tcp2_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	timeout: time.Duration,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_send2(io, socket, buf, p, p2, callback, timeout = timeout)
}

send_tcp3_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	timeout: time.Duration,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	_send3(io, socket, buf, p, p2, p3, callback, timeout = timeout)
}

/// Send All

send_all :: proc {
	send_all_tcp1,
	send_all_tcp2,
	send_all_tcp3,
	send_all_tcp1_timeout,
	send_all_tcp2_timeout,
	send_all_tcp3_timeout,
}

/// Send All TCP

send_all_tcp1 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_send(io, socket, buf, p, callback, all = true)
}

send_all_tcp2 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_send2(io, socket, buf, p, p2, callback, all = true)
}

send_all_tcp3 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	_send3(io, socket, buf, p, p2, p3, callback, all = true)
}

/// Send All TCP with timeout

send_all_tcp1_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	timeout: time.Duration,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_send(io, socket, buf, p, callback, all = true, timeout = timeout)
}

send_all_tcp2_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	timeout: time.Duration,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_send2(io, socket, buf, p, p2, callback, all = true, timeout = timeout)
}

send_all_tcp3_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	buf: []byte,
	timeout: time.Duration,
	p: $T,
	p2: $T2,
	p3: $T3,
	callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) + size_of(T3) <=
	nbio.MAX_USER_ARGUMENTS {
	_send3(io, socket, buf, p, p2, p3, callback, all = true, timeout = timeout)
}

/// Writev All - scatter-gather I/O for batch sends

writev_all :: proc {
	writev_all_tcp1,
	writev_all_tcp2,
	writev_all_tcp1_timeout,
	writev_all_tcp2_timeout,
}

/// Writev Internal

_writev :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	iov: []iovec,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
	all := false,
	timeout: Maybe(time.Duration) = nil,
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._writev(io, socket, iov, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^

			cb(p, sent, err)
		}, all, timeout)

	callback, p := callback, p
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
}

_writev2 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	iov: []iovec,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
	all := false,
	timeout: Maybe(time.Duration) = nil,
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	completion := nbio._writev(io, socket, iov, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
			completion := (^nbio.Completion)(completion)

			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^
			p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

			cb(p, p2, sent, err)
		}, all, timeout)

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
}

/// Writev All TCP

writev_all_tcp1 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	iov: []iovec,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_writev(io, socket, iov, p, callback, all = true)
}

writev_all_tcp2 :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	iov: []iovec,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_writev2(io, socket, iov, p, p2, callback, all = true)
}

/// Writev All TCP with timeout

writev_all_tcp1_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	iov: []iovec,
	timeout: time.Duration,
	p: $T,
	callback: $C/proc(p: T, sent: int, err: net.Network_Error),
) where size_of(T) <=
	nbio.MAX_USER_ARGUMENTS {
	_writev(io, socket, iov, p, callback, all = true, timeout = timeout)
}

writev_all_tcp2_timeout :: proc(
	io: ^nbio.IO,
	socket: net.TCP_Socket,
	iov: []iovec,
	timeout: time.Duration,
	p: $T,
	p2: $T2,
	callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error),
) where size_of(T) + size_of(T2) <=
	nbio.MAX_USER_ARGUMENTS {
	_writev2(io, socket, iov, p, p2, callback, all = true, timeout = timeout)
}
