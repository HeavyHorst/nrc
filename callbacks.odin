//
// callbacks.odin - Async I/O Callback Handlers
//
// This file centralizes all async I/O callbacks with clear safety documentation.
// Understanding callback safety is critical to prevent use-after-free bugs.
//
// BACKGROUND:
// When nbio schedules async I/O (send, recv, close), it stores a callback and
// user data. The I/O may complete milliseconds later. During that time, OTHER
// callbacks may fire and close/free the connection. When our callback finally
// runs, any connection pointer we captured may point to freed memory.
//
// Send completions carry a generational connection handle and a Frame_Lease.
// The handle selects the original retained connection allocation; the lease is
// consumed centrally even when the connection is no longer addressable.
//
package main

import "base:intrinsics"
import "core:log"
import "core:net"

// =============================================================================
// CATEGORY 1: RAW NBIO CALLBACKS - CONNECTION POINTER MAY BE STALE
// =============================================================================
//
// These callbacks are invoked directly by nbio after async I/O completes.
// The connection pointer passed may point to freed memory if the connection
// was closed by another callback during the async wait.
//
// SAFETY PATTERN FOR SEND CALLBACKS:
// 1. Pass socket as separate parameter to nbio (using multi-param variants)
// 2. Look up live connection via connection_get(sock)
// 3. If not found: connection was freed, release resources and return
// 4. If found: pointer is valid, proceed with normal handling
//
// SAFETY PATTERN FOR RECV CALLBACKS (on_recv_websocket_fixed):
// 1. Pass socket as user_data to nbio (not the connection pointer)
// 2. Look up live connection via connection_get(sock)
// 3. If not found: connection was freed, return early
// 4. If found: pointer is valid, proceed with normal handling
//
// The socket is a simple integer that remains valid even if the connection
// struct is freed, making it safe to use for map lookups.
// =============================================================================

// on_recv_websocket_fixed handles incoming WebSocket data from clients.
//
// SAFETY: This is a Category 1 callback. We receive the socket directly as user_data
// (not a connection pointer), then look up the live connection from the handle table.
// The buffer is io_uring provided and auto-freed.
//
// Complete frames are parsed directly from the provided receive buffer. One
// incomplete wire frame may be retained in the connection's byte-pool-backed
// Receive_Accumulator. Once it completes, only its required prefix is consumed;
// any untouched receive suffix returns immediately to the direct parser.
//
on_recv_websocket_fixed :: proc(ctx: Connection_IO_Context, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	// Buffer is automatically freed by nbio after this callback returns
	defer connection_io_unpin(ctx)

	c := connection_from_io_context(ctx)
	if c == nil {
		// Connection was closed/freed during async I/O - nothing to do
		return
	}
	// This callback terminalizes the connection's sole receive Completion. Clear
	// the one-shot handle before parsing can schedule the next receive or close.
	c.recv_completion = nil
	sock := ctx.sock

	if err != nil {
		// Don't log normal client disconnections
		if tcp_err, is_tcp := err.(net.TCP_Recv_Error); is_tcp {
			#partial switch tcp_err {
			case .Connection_Closed:
			// Silent - normal disconnection
			case:
				log.warnf("[T%d] Error receiving from client %v: %v", td.thread_index, sock, err)
			}
		} else {
			log.warnf("[T%d] Error receiving from client %v: %v", td.thread_index, sock, err)
		}
		connection_close(c, false)
		return
	}

	if c.state >= .Will_Close {
		return
	}

	if received > 0 {
		// Update last activity timestamp for idle timeout detection
		c.last_activity = nrc_time_now_monotonic()
		receive_websocket_input(c, buf[:received])
	} else {
		// received == 0 indicates client closed connection gracefully
		log.infof("[T%d] Client %v disconnected (received 0 bytes).", td.thread_index, c.sock)
		connection_close(c, false)
		return
	}
}

// on_queued_send_complete is the central send completion handler.
//
// SAFETY: The socket and generational handle must both select the submitted
// connection. The observer receives that validated connection or nil and never
// owns the frame payload.
//
// OPTIMIZATION: Uses prefetching to hide cache latency for next queue item.
Queued_Send_Completion :: struct {
	sock: net.TCP_Socket,
	item: Send_Item,
}

on_queued_send_complete_context :: proc(ctx: ^Queued_Send_Completion, sent: int, err: net.Network_Error) {
	if ctx == nil {
		return
	}
	sock := ctx.sock
	item := ctx.item
	free(ctx)
	on_queued_send_complete(sock, item, sent, err)
}

on_queued_send_complete :: proc(sock: net.TCP_Socket, completed_item: Send_Item, sent: int, err: net.Network_Error) {
	item := completed_item
	frame_lease_validate_owner(item.lease, item.handle)
	io_ctx := Connection_IO_Context {
		sock   = sock,
		handle = item.handle,
		pinned = item.io_pinned,
	}
	conn := outbox_connection(sock, item.handle)

	if conn != nil {
		// Prefetch next queue item before the observer and lease release.
		if next_item := send_queue_peek(conn); next_item != nil {
			intrinsics.prefetch_read_data(next_item, 3)
		}
	}

	complete_outbox_frame(conn, &item.lease, item.observer, sent, err)
	finish_outbox_operation(io_ctx, item.action, sent, err)
}

outbox_connection :: proc(sock: net.TCP_Socket, handle: Connection_Handle) -> ^NRC_Connection {
	assert(handle != {}, "outbox completion missing connection handle")
	if handle == {} do return nil
	conn := connection_get_by_handle(handle)
	if conn == nil || conn.sock != sock {
		return nil
	}
	return conn
}

complete_outbox_frame :: proc(conn: ^NRC_Connection, lease: ^Frame_Lease, observer: Send_Completion_Observer, sent: int, err: net.Network_Error) {
	if observer.callback != nil do observer.callback(conn, observer.ctx, sent, err)
	frame_lease_dispose(lease)
}

finish_outbox_operation :: proc(io_ctx: Connection_IO_Context, action: Send_Completion_Action, sent: int, err: net.Network_Error) {
	conn := outbox_connection(io_ctx.sock, io_ctx.handle)
	if conn != nil {
		handle_outbox_result(conn, action, sent, err)
		resume_outbox(conn)
	}
	connection_io_unpin(io_ctx)
}

handle_outbox_result :: proc(c: ^NRC_Connection, action: Send_Completion_Action, sent: int, err: net.Network_Error) {
	if err != nil {
		if c.state < .Will_Close {
			if tcp_err, ok := err.(net.TCP_Send_Error); ok {
				#partial switch tcp_err {
				case .Timeout:
					send_websocket_close_frame_and_close(c, 1011, "Send timeout")
				case .Connection_Closed, .Not_Connected:
					connection_close(c, false)
				}
			}
		} else if action != .None && c.state < .Closing {
			connection_close(c, false)
		}
		return
	}
	if action == .Peer_Close_After_Send {
		connection_close(c, false)
	} else if action == .Close_After_Send && connection_io_pin(c) {
		nrc_io_shutdown_send(
			Connection_IO_Context{sock = c.sock, handle = c.handle, pinned = true},
			graceful_close_context_new(c),
			on_graceful_close_shutdown_complete,
			graceful_close_context_discard,
		)
	}
}

resume_outbox :: proc(conn: ^NRC_Connection) {
	// The completed transport send no longer owns the connection's send state.
	// Keep the dense watchdog slot only when this callback immediately starts the
	// next eligible send; no timer callback can interleave on the worker thread.
	conn.is_sending = false
	conn.send_started_at = {}

	// Once physical close has begun, never submit more sends.
	if conn.state >= .Closing {
		send_watchdog_untrack(conn)
		return
	}

	// Graceful logical close may enqueue one terminal priority/control frame
	// while a data frame is still in flight. Drain that frame, but do not resume
	// normal application sends after .Will_Close.
	if conn.state >= .Will_Close && send_queue_priority_len(conn) == 0 {
		send_watchdog_untrack(conn)
		return
	}

	if conn.outbox_pump_deferred && send_queue_priority_len(conn) == 0 {
		send_watchdog_untrack(conn)
		return
	}

	// Consecutive sends retain the existing watchdog slot and refresh the start
	// timestamp in pump_outbox. An empty queue removes the slot there.
	pump_outbox(conn)
}

// on_batch_send_complete handles completion of a batch writev operation.
//
// writev_all guarantees all bytes sent or an error before this callback. Every
// item lease is consumed, then one operation-level action resumes or closes the
// connection while the writev I/O pin is still held.
on_batch_send_complete :: proc(sock: net.TCP_Socket, state: ^Batch_Send_State, sent: int, err: net.Network_Error) {
	io_ctx := Connection_IO_Context{}
	conn: ^NRC_Connection
	if state != nil && state.count > 0 {
		io_ctx = Connection_IO_Context {
			sock   = sock,
			handle = state.items[0].handle,
			pinned = state.io_pinned,
		}
		conn = outbox_connection(sock, io_ctx.handle)
	}
	completion_action := Send_Completion_Action.None
	for i in 0 ..< state.count {
		item := &state.items[i]
		assert(item.handle == io_ctx.handle, "writev outbox operation mixed connection handles")
		frame_lease_validate_owner(item.lease, item.handle)
		if item.action == .Peer_Close_After_Send || (item.action == .Close_After_Send && completion_action == .None) {
			completion_action = item.action
		}
		item_sent := 0
		if err == nil do item_sent = len(frame_lease_data(item.lease))
		complete_outbox_frame(conn, &item.lease, item.observer, item_sent, err)
	}

	// Free batch state (single free for entire allocation)
	free_batch_state(state)

	if io_ctx.handle != {} {
		finish_outbox_operation(io_ctx, completion_action, sent, err)
	} else {
		connection_io_unpin(io_ctx)
	}
}
