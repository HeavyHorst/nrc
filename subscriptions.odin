//
// subscriptions.odin - Conversation Subscription Management
//
// This file handles client subscription management for conversations including:
// - Adding and removing client subscriptions to conversations
// - Workspace-scoped conversation tracking
// - Subscription validation and cleanup
// - Dynamic array management for subscriber lists
// - Integration with broadcasting system for message delivery
//
package main

import "core:log"
import "core:net"
import "core:slice"

import "base:intrinsics"
import "byte_pool"
import pr "protocol"

Subscriber_Entry :: struct {
	sock:   net.TCP_Socket,
	handle: Connection_Handle,
}

SUBSCRIBER_SORT_THRESHOLD :: 64

sort_subscribers_by_handle_index_if_dirty :: proc(conv: ^Conversation_State) {
	if conv == nil || !conv.subscribers_dirty || len(conv.subscriber_entries) < SUBSCRIBER_SORT_THRESHOLD {
		return
	}

	slice.sort_by(conv.subscriber_entries[:], proc(a, b: Subscriber_Entry) -> bool {
		return a.handle.idx < b.handle.idx
	})

	clear(&conv.subscriber_index)
	for entry, i in conv.subscriber_entries {
		conv.subscriber_index[entry.sock] = i
	}
	conv.subscribers_dirty = false
}

init_subscriber_index :: proc(conv: ^Conversation_State) {
	conv.subscriber_entries = make([dynamic]Subscriber_Entry, 0, 64)
	conv.subscriber_index = make(map[net.TCP_Socket]int, 64)
}

destroy_subscriber_index :: proc(conv: ^Conversation_State) {
	delete(conv.subscriber_entries)
	delete(conv.subscriber_index)
}

subscriber_count :: #force_inline proc(conv: ^Conversation_State) -> int {
	return len(conv.subscriber_entries)
}

conversation_has_subscriber :: #force_inline proc(conv: ^Conversation_State, sock: net.TCP_Socket) -> bool {
	_, ok := conv.subscriber_index[sock]
	return ok
}

// conversation_add_subscriber inserts a generational connection identity into
// the conversation subscriber indexes.
conversation_add_subscriber :: proc(conv: ^Conversation_State, c: ^NRC_Connection) -> bool {
	if c == nil || c.handle == {} do return false
	// Existing pending events belong only to the old subscriber population.
	handle := c.handle
	for flush_presence_batch(conv) {
		if connection_get_by_handle(handle) != c || c.state >= .Will_Close do return false
	}
	sock := c.sock
	if idx, ok := conv.subscriber_index[sock]; ok {
		if conv.subscriber_entries[idx].handle != c.handle {
			conv.subscriber_entries[idx].handle = c.handle
			conv.subscribers_dirty = true
			return true
		}
		return false
	}

	idx := len(conv.subscriber_entries)
	if idx > 0 && c.handle.idx < conv.subscriber_entries[idx - 1].handle.idx {
		conv.subscribers_dirty = true
	}
	append(&conv.subscriber_entries, Subscriber_Entry{sock = sock, handle = c.handle})
	conv.subscriber_index[sock] = idx

	return true
}

// conversation_remove_subscriber removes a socket from the conversation subscriber indexes.
conversation_remove_subscriber :: proc(conv: ^Conversation_State, sock: net.TCP_Socket) -> bool {
	idx, ok := conv.subscriber_index[sock]
	if !ok {
		return false
	}

	last_idx := len(conv.subscriber_entries) - 1
	if idx != last_idx {
		moved := conv.subscriber_entries[last_idx]
		conv.subscriber_entries[idx] = moved
		conv.subscriber_index[moved.sock] = idx
		conv.subscribers_dirty = true
	}
	pop(&conv.subscriber_entries)
	delete_key(&conv.subscriber_index, sock)

	return true
}

send_shared_to_subscriber_entries :: proc(
	conv: ^Conversation_State,
	excluded_sock: net.TCP_Socket,
	shared_buf: ^Broadcast_Buffer,
	excluded_handle: Connection_Handle = {},
) -> int {
	shared_fanout_begin()
	defer shared_fanout_end()
	sort_subscribers_by_handle_index_if_dirty(conv)
	stack_handles: [MAX_ROOM_USERS]Connection_Handle
	handles := stack_handles[:0]
	oversized: [dynamic]Connection_Handle
	oversized_room := len(conv.subscriber_entries) > MAX_ROOM_USERS
	if oversized_room {
		oversized = make([dynamic]Connection_Handle, 0, len(conv.subscriber_entries))
		handles = oversized[:]
		defer delete(oversized)
	}
	for entry in conv.subscriber_entries {
		if excluded_handle != {} {
			if entry.handle == excluded_handle do continue
		} else if entry.sock == excluded_sock do continue
		conn := connection_get_by_handle(entry.handle)
		if conn == nil || conn.sock != entry.sock || conn.state >= .Will_Close do continue
		if oversized_room {
			append(&oversized, entry.handle)
			handles = oversized[:]
		} else {
			handles = stack_handles[:len(handles) + 1]
			handles[len(handles) - 1] = entry.handle
		}
	}

	sent_count := 0
	for handle, i in handles {
		if i + 1 < len(handles) {
			if next_conn := connection_get_by_handle(handles[i + 1]); next_conn != nil {
				intrinsics.prefetch_read_data(next_conn, 3)
			}
		}
		conn := connection_get_by_handle(handle)
		if conn != nil && conn.state < .Will_Close {
			shared_frame_retain(shared_buf)
			if nrc_send_frame(conn, Frame_Lease(Shared_Frame_Lease{buffer = shared_buf})) {
				sent_count += 1
			}
		}
	}
	shared_frame_release(shared_buf)

	return sent_count
}

send_shared_to_subscribers_except :: proc(conv: ^Conversation_State, excluded_sock: net.TCP_Socket, shared_buf: ^Broadcast_Buffer) -> int {
	return send_shared_to_subscriber_entries(conv, excluded_sock, shared_buf)
}

// Subscribe connection to conversations
subscribe_to_conversation :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID) {
	// Workspace data has a delivery subscription, not chat membership. It has
	// neither room capacity nor presence events; cleanup still tracks the scope.
	if conv_id == pr.WORKSPACE_DATA_ID {
		ws := get_or_create_connection_workspace(c)
		data := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
		if conversation_add_subscriber(data, c) do add_socket_room(c, conv_id)
		return
	}
	// DM conversations require access validation
	if pr.is_dm_conversation(conv_id) {
		if !validate_dm_access(c, conv_id) {
			log.warnf("[T%d] Socket %v denied access to DM conv_id %v", td.thread_index, c.sock, conv_id)
			return
		}
	}

	workspace_id := c.workspace_id
	ws := get_or_create_connection_workspace(c)
	conv := get_or_create_conversation(ws, conv_id)

	already_subscribed := conversation_has_subscriber(conv, c.sock)

	if !already_subscribed {
		// Check room user limit before allowing join
		current_user_count := subscriber_count(conv)
		if current_user_count >= MAX_ROOM_USERS {
			log.warnf(
				"[T%d] Room full: workspace '%s' conv_id %v has %d users (max %d), rejecting join for socket %v",
				td.thread_index,
				workspace_id,
				conv_id,
				current_user_count,
				MAX_ROOM_USERS,
				c.sock,
			)
			return
		}

		if !conversation_add_subscriber(conv, c) do return
		when ODIN_DEBUG do debug_log("[T%d] Socket %v subscribed to workspace '%s' conv_id %v", td.thread_index, c.sock, workspace_id, conv_id)

		// Update connection's room membership
		add_socket_room(c, conv_id)

		// Send full user list to the new subscriber (now includes themselves)
		send_user_list_sync(c, ws, workspace_id, conv_id)

		// Notify other subscribers that someone joined the room
		username := get_socket_username(workspace_id, c.sock)
		if username != "" {
			broadcast_presence_update(ws, workspace_id, conv_id, .UserJoined, username, "", c.authenticated, c.user_type)
		}
	} else {
		if conversation_add_subscriber(conv, c) {
			add_socket_room(c, conv_id)
		}

		// Already subscribed, just send user list sync
		send_user_list_sync(c, ws, workspace_id, conv_id)
	}
}

// Unsubscribe connection from conversations
unsubscribe_from_conversation :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID) {
	workspace_id := c.workspace_id
	ws := get_connection_workspace(c)
	if ws == nil {
		return
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return
	}

	if !conversation_has_subscriber(conv, c.sock) {
		return
	}

	// Explicit unsubscribe is a delivery boundary; disconnect cleanup instead
	// removes dead recipients without flushing so their departure wave can batch.
	handle := c.handle
	for flush_presence_batch(conv) {
		if connection_get_by_handle(handle) != c || c.state >= .Will_Close do return
	}

	// Get username before removing the socket (for presence notification)
	username := get_socket_username(workspace_id, c.sock)

	conversation_remove_subscriber(conv, c.sock)
	when ODIN_DEBUG do debug_log("[T%d] Socket %v unsubscribed from workspace '%s' conv_id %v", td.thread_index, c.sock, workspace_id, conv_id)

	// Update connection's room membership
	remove_socket_room(c, conv_id)

	// Notify remaining subscribers that someone left the room
	if username != "" && subscriber_count(conv) > 0 {
		broadcast_presence_update(ws, workspace_id, conv_id, .UserLeft, username, "", c.authenticated, c.user_type)
	}
}

send_ack_unsubscribe_convs :: proc(c: ^NRC_Connection, correlation_id: u32) {
	ack := pr.AckUnsubscribeConvs {
		correlation_id = correlation_id,
	}
	protocol_len := pr.getSizeAckUnsubscribeConvs(ack)
	buf, header_len := allocate_websocket_frame_buffer(protocol_len, "unsubscribe acknowledgment")
	if buf == nil do return

	written := pr.serializeAckUnsubscribeConvs(ack, buf[header_len:])
	if written < 0 {
		byte_pool.release(td.spool, buf)
		return
	}
	total_len := header_len + written
	_ = send_pooled_buffer(c, buf[:total_len])
}
