//
// room_presence.odin - Room Presence Management
//
// This file handles room presence functionality by leveraging existing subscription
// data structures to determine who is currently in each room (conversation).
// It provides notifications when users join/leave rooms and can query current occupants.
//
package main

import "core:log"
import "core:net"

import "byte_pool"
import pr "protocol"

// Maximum users per room/conversation for presence updates
MAX_ROOM_USERS :: 1200

// Bound staged presence payloads to 256 KiB per worker (excluding recipient
// outboxes and in-flight sends). Buffers contain complete WebSocket frames,
// not a new application message or fragmented WebSocket frame.
PRESENCE_BATCH_BYTES :: 16 * 1024
PRESENCE_BATCH_ROOMS :: 16

Presence_Batch :: struct {
	conv:   ^Conversation_State,
	buffer: ^Broadcast_Buffer,
	used:   int,
}

begin_presence_batch_wave :: proc() {
	assert(!td.collect_presence_updates && td.presence_batch_count == 0)
	td.collect_presence_updates = true
}

flush_presence_batch :: proc(conv: ^Conversation_State) -> bool {
	for i in 0 ..< td.presence_batch_count {
		if td.presence_batches[i].conv != conv do continue
		batch := td.presence_batches[i]
		// Detach before fanout: queue overflow can close subscribers and produce
		// further UserLeft events, which must enter a new batch.
		for j in i ..< td.presence_batch_count - 1 {
			td.presence_batches[j] = td.presence_batches[j + 1]
		}
		td.presence_batch_count -= 1
		td.presence_batches[td.presence_batch_count] = {}
		batch.buffer.data = batch.buffer.data[:batch.used]
		_ = send_shared_presence_to_subscribers(conv, batch.buffer)
		return true
	}
	return false
}

finish_presence_batch_wave :: proc() -> bool {
	did_work := td.presence_batch_count > 0
	for td.presence_batch_count > 0 {
		flush_presence_batch(td.presence_batches[0].conv)
	}
	td.collect_presence_updates = false
	return did_work
}

// Takes ownership of frame. The enclosing shared-fanout scope postpones any
// reentrant UserLeft until this earlier event has been appended or sent.
enqueue_presence_frame :: proc(conv: ^Conversation_State, frame: ^Broadcast_Buffer) {
	if !td.collect_presence_updates || len(frame.data) > PRESENCE_BATCH_BYTES {
		flush_presence_batch(conv)
		_ = send_shared_presence_to_subscribers(conv, frame)
		return
	}
	for i in 0 ..< td.presence_batch_count {
		batch := &td.presence_batches[i]
		if batch.conv != conv do continue
		needed := batch.used + len(frame.data)
		if needed > PRESENCE_BATCH_BYTES {
			flush_presence_batch(conv)
			break
		}
		if needed > len(batch.buffer.data) {
			data, err := byte_pool.alloc(td.spool, PRESENCE_BATCH_BYTES)
			if err != .None {
				// Retain delivery on allocation failure using the existing frames.
				flush_presence_batch(conv)
				break
			}
			copy(data, batch.buffer.data[:batch.used])
			byte_pool.release(td.spool, batch.buffer.data)
			batch.buffer.data = data
		}
		copy(batch.buffer.data[batch.used:needed], frame.data)
		batch.used = needed
		shared_frame_release(frame)
		return
	}
	if td.presence_batch_count == PRESENCE_BATCH_ROOMS {
		flush_presence_batch(td.presence_batches[0].conv)
	}
	td.presence_batches[td.presence_batch_count] = {conv, frame, len(frame.data)}
	td.presence_batch_count += 1
}

Deferred_Presence_Update :: struct {
	ws:               ^Workspace_State,
	workspace_id:     string,
	conv_id:          pr.ConversationID,
	username:         string,
	is_authenticated: bool,
	user_type:        pr.User_Type,
}

shared_fanout_begin :: #force_inline proc() {
	td.shared_fanout_depth += 1
}

shared_fanout_end :: proc() {
	assert(td.shared_fanout_depth > 0, "shared fanout depth underflow")
	td.shared_fanout_depth -= 1
	if td.shared_fanout_depth != 0 || td.draining_presence_updates {
		return
	}

	td.draining_presence_updates = true
	defer td.draining_presence_updates = false
	update_index := 0
	for update_index < len(td.deferred_presence_updates) {
		update := td.deferred_presence_updates[update_index]
		update_index += 1
		broadcast_presence_update(update.ws, update.workspace_id, update.conv_id, .UserLeft, update.username, "", update.is_authenticated, update.user_type)
	}
	resize(&td.deferred_presence_updates, 0)
}

send_or_defer_user_left :: proc(
	ws: ^Workspace_State,
	workspace_id: string,
	conv_id: pr.ConversationID,
	username: string,
	is_authenticated: bool,
	user_type: pr.User_Type,
) {
	if td.shared_fanout_depth > 0 {
		append(
			&td.deferred_presence_updates,
			Deferred_Presence_Update {
				ws = ws,
				workspace_id = workspace_id,
				conv_id = conv_id,
				username = username,
				is_authenticated = is_authenticated,
				user_type = user_type,
			},
		)
		return
	}
	broadcast_presence_update(ws, workspace_id, conv_id, .UserLeft, username, "", is_authenticated, user_type)
}

// =============================================================================
// ROOM MEMBERSHIP HELPERS (stored directly on Echo_Connection)
// =============================================================================

// Add a room to connection's membership
add_socket_room :: proc(conn: ^NRC_Connection, conv_id: pr.ConversationID) {
	if conn == nil do return
	conn.rooms[conv_id] = true
}

// Remove a specific room from connection's membership
remove_socket_room :: proc(conn: ^NRC_Connection, conv_id: pr.ConversationID) {
	if conn == nil do return
	delete_key(&conn.rooms, conv_id)
}

// Remove all rooms from connection's membership and free allocations
remove_all_rooms :: proc(conn: ^NRC_Connection) {
	if conn == nil do return
	delete(conn.rooms)
	conn.rooms = {}
}

// =============================================================================
// ROOM PRESENCE QUERIES
// =============================================================================

// Get username for a specific socket in a workspace
get_socket_username :: proc(workspace_id: string, socket: net.TCP_Socket) -> string {
	// Presence identity is always derived from authenticated user/service connection state.
	if conn := connection_get(socket); conn != nil && conn.workspace_id == workspace_id {
		return get_connection_nickname(conn)
	}

	return ""
}

Subscriber_User_List_Scan_State :: struct {
	workspace_id:   string,
	byte_users_buf: ^[MAX_ROOM_USERS][]byte,
	auth_flags_buf: ^[MAX_ROOM_USERS]bool,
	user_types_buf: ^[MAX_ROOM_USERS]pr.User_Type,
	user_idx:       int,
	truncated:      bool,
}

subscriber_collect_user_list_entry :: proc(ctx: ^Subscriber_User_List_Scan_State, entry: Subscriber_Entry) -> bool {
	if ctx.user_idx >= MAX_ROOM_USERS {
		ctx.truncated = true
		return false
	}

	conn := connection_get_by_handle(entry.handle)
	if conn == nil || conn.sock != entry.sock || conn.workspace_id != ctx.workspace_id {
		return true
	}
	if conn.state >= .Will_Close {
		return true
	}

	uname := get_connection_nickname(conn)
	if uname != "" {
		ctx.byte_users_buf[ctx.user_idx] = transmute([]byte)uname
		ctx.auth_flags_buf[ctx.user_idx] = conn.authenticated
		ctx.user_types_buf[ctx.user_idx] = conn.user_type
		ctx.user_idx += 1
	}

	return true
}

// Broadcast room presence update to all subscribers of a conversation
broadcast_presence_update_by_id :: proc(
	workspace_id: string,
	conv_id: pr.ConversationID,
	event_type: pr.PresenceEventType,
	username: string = "",
	old_username: string = "",
	is_authenticated: bool = false,
	user_type: pr.User_Type = .User,
) {
	broadcast_presence_update_with_workspace(
		get_workspace(workspace_id),
		workspace_id,
		conv_id,
		event_type,
		username,
		old_username,
		is_authenticated,
		user_type,
	)
}

broadcast_presence_update_with_workspace :: proc(
	ws: ^Workspace_State,
	workspace_id: string,
	conv_id: pr.ConversationID,
	event_type: pr.PresenceEventType,
	username: string = "",
	old_username: string = "",
	is_authenticated: bool = false,
	user_type: pr.User_Type = .User,
) {
	if ws == nil || conv_id == pr.WORKSPACE_DATA_ID {
		return
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return
	}

	if subscriber_count(conv) == 0 {
		return
	}

	// Get next sequence number using the existing message sequence counter
	sequence := u64(generate_message_seq())

	// Prepare presence update message
	presence_update := pr.RoomPresenceUpdate {
		conv_id          = conv_id,
		event_type       = event_type,
		sequence         = sequence,
		username         = nil,
		is_authenticated = false,
		user_type        = .User,
		old_username     = nil,
		user_list        = nil,
		user_auth_flags  = nil,
		user_types       = nil,
	}

	// Set username for join/leave/renamed events
	if event_type == .UserJoined || event_type == .UserLeft || event_type == .UserRenamed {
		if username != "" {
			presence_update.username = transmute([]byte)username
			presence_update.is_authenticated = is_authenticated
			presence_update.user_type = user_type
		}
	}

	// Set old_username for renamed events
	if event_type == .UserRenamed {
		if old_username != "" {
			presence_update.old_username = transmute([]byte)old_username
		}
	}

	// For sync events, include full user list with auth flags and user types
	if event_type == .UserListSync {
		// Single pass: collect usernames, auth flags, and user types directly into stack buffers.
		// NOTE: ~22KB stack allocation (MAX_ROOM_USERS=1200). Cannot use temp_allocator because
		// there's no safe free_all point in the event loop. Consider replacing with a virtual
		// arena if MAX_ROOM_USERS grows significantly.
		byte_users_buf: [MAX_ROOM_USERS][]byte
		auth_flags_buf: [MAX_ROOM_USERS]bool
		user_types_buf: [MAX_ROOM_USERS]pr.User_Type
		scan_state := Subscriber_User_List_Scan_State {
			workspace_id   = workspace_id,
			byte_users_buf = &byte_users_buf,
			auth_flags_buf = &auth_flags_buf,
			user_types_buf = &user_types_buf,
		}
		sort_subscribers_by_handle_index_if_dirty(conv)
		for entry in conv.subscriber_entries {
			if !subscriber_collect_user_list_entry(&scan_state, entry) do break
		}

		if scan_state.truncated {
			log.warnf("[T%d] Room has more than %d users, truncating presence update", td.thread_index, MAX_ROOM_USERS)
		}

		if scan_state.user_idx > 0 {
			presence_update.user_list = byte_users_buf[:scan_state.user_idx]
			presence_update.user_auth_flags = auth_flags_buf[:scan_state.user_idx]
			presence_update.user_types = user_types_buf[:scan_state.user_idx]
		}
	}

	// Send to all subscribers
	send_presence_update_to_subscribers(conv, presence_update)

	when ODIN_DEBUG do debug_log(
		"[T%d] Broadcast presence update: workspace='%s' conv_id=%v type=%v username='%s' subscriber_count=%d",
		td.thread_index,
		workspace_id,
		conv_id,
		event_type,
		username,
		subscriber_count(conv),
	)
}

broadcast_presence_update :: proc {
	broadcast_presence_update_by_id,
	broadcast_presence_update_with_workspace,
}

// Create shared buffer for presence update broadcast (single allocation and serialization)
create_shared_presence_broadcast_buffer :: proc(update: pr.RoomPresenceUpdate) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeRoomPresenceUpdate(update)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "presence broadcast")
	if buf == nil do return nil

	// Serialize protocol data directly at correct offset (zero-copy)
	protocol_len := pr.serializeRoomPresenceUpdate(update, buf[header_len:])

	// No cleanup needed - user_list uses stack allocation

	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	// Create shared buffer wrapper (allocated from same pool as data)
	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:header_len + protocol_len]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}

// Send presence update to a single connection (no shared buffer needed)
send_presence_update_to_single :: proc(conn: ^NRC_Connection, update: pr.RoomPresenceUpdate) {
	if conn == nil || conn.state >= .Will_Close {
		return
	}
	shared_fanout_begin()
	defer shared_fanout_end()
	if workspace := get_connection_workspace(conn); workspace != nil {
		flush_presence_batch(get_conversation(workspace, update.conv_id))
	}
	if conn.state >= .Will_Close do return

	protocol_size := pr.getSizeRoomPresenceUpdate(update)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "presence single")
	if buf == nil do return

	protocol_len := pr.serializeRoomPresenceUpdate(update, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return
	}

	_ = send_pooled_buffer(conn, buf[:header_len + protocol_len])
}

// Send presence update message to subscribers using shared buffer
send_presence_update_to_subscribers :: proc(conv: ^Conversation_State, update: pr.RoomPresenceUpdate) {
	if subscriber_count(conv) == 0 do return
	shared_fanout_begin()
	defer shared_fanout_end()
	shared_buf := create_shared_presence_broadcast_buffer(update)
	if shared_buf == nil {
		log.errorf("[T%d] Failed to create shared buffer for presence update", td.thread_index)
		return
	}

	if update.event_type == .UserListSync {
		flush_presence_batch(conv)
		_ = send_shared_presence_to_subscribers(conv, shared_buf)
	} else {
		enqueue_presence_frame(conv, shared_buf)
	}
}

send_shared_presence_to_subscribers_conv :: proc(conv: ^Conversation_State, shared_buf: ^Broadcast_Buffer) -> int {
	return send_shared_to_subscriber_entries(conv, net.TCP_Socket(0), shared_buf)
}

send_shared_presence_to_subscribers :: send_shared_presence_to_subscribers_conv

// Send user list sync to a single connection (for when they join a room)
send_user_list_sync_by_id :: proc(conn: ^NRC_Connection, workspace_id: string, conv_id: pr.ConversationID) {
	send_user_list_sync_with_workspace(conn, get_workspace(workspace_id), workspace_id, conv_id)
}

send_user_list_sync_with_workspace :: proc(conn: ^NRC_Connection, ws: ^Workspace_State, workspace_id: string, conv_id: pr.ConversationID) {
	if ws == nil do return
	conv := get_conversation(ws, conv_id)
	if conv == nil || subscriber_count(conv) == 0 {
		return
	}
	handle := conn.handle
	for flush_presence_batch(conv) {
		if connection_get_by_handle(handle) != conn || conn.state >= .Will_Close do return
	}

	// Single pass: collect usernames, auth flags, and user types directly into stack buffers
	byte_users_buf: [MAX_ROOM_USERS][]byte
	auth_flags_buf: [MAX_ROOM_USERS]bool
	user_types_buf: [MAX_ROOM_USERS]pr.User_Type
	scan_state := Subscriber_User_List_Scan_State {
		workspace_id   = workspace_id,
		byte_users_buf = &byte_users_buf,
		auth_flags_buf = &auth_flags_buf,
		user_types_buf = &user_types_buf,
	}
	sort_subscribers_by_handle_index_if_dirty(conv)
	for entry in conv.subscriber_entries {
		if !subscriber_collect_user_list_entry(&scan_state, entry) do break
	}

	if scan_state.truncated {
		log.warnf("[T%d] Room has more than %d users, truncating user list sync", td.thread_index, MAX_ROOM_USERS)
	}

	if scan_state.user_idx == 0 {
		return
	}

	// Get next sequence number using the existing message sequence counter
	sequence := u64(generate_message_seq())

	update := pr.RoomPresenceUpdate {
		conv_id          = conv_id,
		event_type       = .UserListSync,
		sequence         = sequence,
		username         = nil,
		is_authenticated = false,
		user_type        = .User,
		old_username     = nil,
		user_list        = byte_users_buf[:scan_state.user_idx],
		user_auth_flags  = auth_flags_buf[:scan_state.user_idx],
		user_types       = user_types_buf[:scan_state.user_idx],
	}

	// Send directly to this connection
	send_presence_update_to_single(conn, update)

	when ODIN_DEBUG do debug_log(
		"[T%d] Sent user list sync to %v for workspace='%s' conv_id=%v (%d users)",
		td.thread_index,
		conn.sock,
		workspace_id,
		conv_id,
		scan_state.user_idx,
	)
}

send_user_list_sync :: proc {
	send_user_list_sync_by_id,
	send_user_list_sync_with_workspace,
}
