//
// broadcast.odin - Message Broadcasting System
//
// This file handles efficient message broadcasting to multiple subscribers including:
// - Shared buffer management for broadcast operations to minimize allocations
// - NewMessage event broadcasting to conversation subscribers
// - Agenda update broadcasting with workspace isolation
// - Reference counting for shared broadcast buffers
// - Memory pool integration for high-performance message distribution
//
package main

import "core:log"
import "core:net"

import "byte_pool"
import pr "protocol"

// Shared buffer for broadcast operations
// MOVED TO connection.odin to resolve circular dependency

// Send S_NewMessage to subscribers (excluding sender) - optimized single buffer version
broadcast_new_message_by_id :: proc(msg: pr.NewMessageEvent, sender_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_new_message_with_workspace(msg, sender_sock, get_workspace(workspace_id))
}

broadcast_new_message_with_workspace :: proc(msg: pr.NewMessageEvent, sender_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, msg.conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	// Create shared buffer with single allocation and serialization
	shared_buf := create_shared_broadcast_buffer(msg)
	if shared_buf == nil {
		log.errorf("[T%d] Failed to create shared buffer for broadcast", td.thread_index)
		return
	}

	// Send to all valid subscribers and count successful enqueues.
	// Keep normal fanout queued until the current completion wave finishes. ACKs
	// use the priority outbox and can therefore reach io_uring without sharing
	// their submit with all of this message's fanout sends.
	defer_normal_outbox_pumps_begin()
	defer defer_normal_outbox_pumps_end()
	when ODIN_DEBUG {
		sent_count := send_shared_to_subscriber_entries(conv, sender_sock, shared_buf)
		debug_log("[T%d] Broadcasted message to %d subscribers for conv_id %v", td.thread_index, sent_count, msg.conv_id)
	} else {
		_ = send_shared_to_subscriber_entries(conv, sender_sock, shared_buf)
	}
}

broadcast_new_message :: proc {
	broadcast_new_message_by_id,
	broadcast_new_message_with_workspace,
}

// Create shared buffer for broadcast (single allocation and serialization)
create_shared_broadcast_buffer :: proc(msg: pr.NewMessageEvent) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeNewMessageEvent(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "broadcast")
	if buf == nil do return nil

	// Serialize protocol data directly at correct offset (zero-copy)
	protocol_len := pr.serializeNewMessageEvent(msg, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	// Validate frame before sending
	final_frame_size := header_len + protocol_len
	when ODIN_DEBUG do debug_log(
		"[T%d] Created broadcast frame: header_len=%d, protocol_len=%d, total=%d",
		td.thread_index,
		header_len,
		protocol_len,
		final_frame_size,
	)

	// Create shared buffer wrapper (allocated from same pool as data)
	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:final_frame_size]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}
