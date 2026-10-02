package main

import "core:container/queue"
import "core:net"

import "byte_pool"
import pr "protocol"

@(thread_local)
connection_test_live_count: int

connection_test_storage_destroy :: proc() {
	assert(connection_test_live_count == 0)
	assert(len(td.inflight_send_handles) == 0)
	delete(td.inflight_send_handles)
	td.inflight_send_handles = nil
	connection_test_live_count = 0
	connection_storage_destroy()
}

connection_test_send_queue_backing_len :: proc(conn: ^NRC_Connection) -> int {
	if conn == nil do return 0
	return int(conn.inline_len) + queue.len(conn.spill_queue) + queue.len(conn.priority_queue)
}

connection_test_mutate_queue_backing_without_count :: proc(conn: ^NRC_Connection, priority, push: bool) {
	if priority {
		if push do queue.push_back(&conn.priority_queue, Send_Item{})
		else do _ = queue.pop_front(&conn.priority_queue)
	} else {
		if push do queue.push_back(&conn.spill_queue, Send_Item{})
		else do _ = queue.pop_front(&conn.spill_queue)
	}
}

connection_test_mark_removed :: proc(sock: net.TCP_Socket) {
	assert(connection_test_live_count > 0)
	assert(connection_get(sock) == nil)
	connection_test_live_count -= 1
}

CONNECTION_TEST_FAKE_SOCKET_BASE :: 500_000

Fake_Connection_Options :: struct {
	sock:                net.TCP_Socket,
	state:               Connection_State,
	workspace_id:        string,
	verified_username:   string,
	authenticated:       bool,
	user_type:           pr.User_Type,
	server:              ^NRC_Server,
	track_active_socket: bool,
	cache_workspace:     bool,
	init_send_queue:     bool,
}

connection_test_fake_socket :: proc(client_id: int, generation: int = 0) -> net.TCP_Socket {
	return net.TCP_Socket(CONNECTION_TEST_FAKE_SOCKET_BASE + client_id * 16 + generation)
}

// connection_test_install_fake is a testing/simulation helper that creates and
// binds a connection with enough runtime state to exercise production handlers.
connection_test_install_fake :: proc(options: Fake_Connection_Options) -> ^NRC_Connection {
	c, ok := connection_alloc()
	if !ok {
		return nil
	}
	c.sock = options.sock
	c.state = options.state
	c.thread_index = td.thread_index
	if options.init_send_queue {
		send_queue_init(c)
	}
	c.server = options.server
	if c.server == nil {
		c.server = td.server
	}
	c.workspace_id = options.workspace_id
	c.verified_username = options.verified_username
	c.authenticated = options.authenticated
	c.user_type = options.user_type
	c.last_activity = nrc_time_now_monotonic()
	if options.cache_workspace && options.workspace_id != "" {
		c.workspace = get_or_create_workspace(options.workspace_id)
	}
	connection_set_socket_handle(options.sock, c.handle)
	if options.track_active_socket && td.active_sockets != nil {
		td.active_sockets[options.sock] = {}
		td.connection_count += 1
	}
	connection_test_live_count += 1
	return c
}

// connection_test_install is a testing helper that creates and binds a new
// connection instance to the specified socket FD.
connection_test_install :: proc(sock: net.TCP_Socket, state: Connection_State) -> ^NRC_Connection {
	return connection_test_install_fake(Fake_Connection_Options{sock = sock, state = state})
}

// connection_test_uninstall is a testing helper that cleans up a connection instance.
connection_test_uninstall :: proc(conn: ^NRC_Connection) {
	if conn == nil {
		return
	}
	untrack_user_connection(conn)
	// A submitted operation owns the handle allocation. Model a completed close
	// without violating that ownership; its final completion will reclaim it.
	if conn.pending_io > 0 {
		if td.connection_handles[conn.sock] == conn.handle {
			connection_clear_socket_handle(conn.sock)
		}
		if td.active_sockets != nil {
			if _, tracked := td.active_sockets[conn.sock]; tracked {
				delete_key(&td.active_sockets, conn.sock)
				if td.connection_count > 0 do td.connection_count -= 1
			}
		}
		conn.state = .Closed
		conn.close_completed = true
		if connection_test_live_count > 0 do connection_test_live_count -= 1
		return
	}
	// Match final callback reclamation; immediate fixture removal owns the queues.
	send_queue_destroy(conn)
	reset_deferred_input(conn)
	if conn.receive_accumulator.buf != nil {
		byte_pool.release(td.spool, conn.receive_accumulator.buf)
	}
	conn.receive_accumulator = {}

	if conn.fragment_buf != nil {
		byte_pool.release(td.spool, conn.fragment_buf)
		conn.fragment_buf = nil
		conn.fragment_len = 0
	}

	if td.active_sockets != nil {
		_, tracked := td.active_sockets[conn.sock]
		if !tracked {
			connection_remove(conn)
			if connection_test_live_count > 0 {
				connection_test_live_count -= 1
			}
			return
		}
		delete_key(&td.active_sockets, conn.sock)
		if td.connection_count > 0 {
			td.connection_count -= 1
		}
	}
	connection_remove(conn)
	if connection_test_live_count > 0 {
		connection_test_live_count -= 1
	}
}
