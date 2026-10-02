//
// dm_handlers.odin - Direct Message Handlers
//
// This file handles DM (Direct Message) operations including:
// - Starting a DM conversation with another user
// - Listing active DM conversations
// - Leaving a DM conversation
// - Partner online/offline status notifications
// - User connection tracking for online detection
//
package main

import "core:net"

import pr "protocol"

// Get the username for a connection.
// Authenticated users resolve to verified_username
// (JWT username for humans, validated service nickname for bots/system/admin).
get_connection_username :: proc(c: ^NRC_Connection) -> string {
	if c.authenticated && c.verified_username != "" {
		return c.verified_username
	}
	return ""
}

// Check if a user exists in the workspace (has any active connection)
find_user_in_workspace :: proc(ws: ^Workspace_State, username: string) -> bool {
	count, ok := ws.user_connection_count[username]
	return ok && count > 0
}

// Check if a user is currently online (has at least one active connection)
is_user_online :: proc(ws: ^Workspace_State, username: string) -> bool {
	count, ok := ws.user_connection_count[username]
	return ok && count > 0
}

// Check if a user is authenticated (any of their connections in this workspace)
is_user_authenticated :: proc(ws: ^Workspace_State, username: string) -> bool {
	count, ok := ws.user_authenticated_connection_count[username]
	return ok && count > 0
}

// Track active connection generations by workspace/user so DM start/leave work
// scales with the user's device count rather than every connection on the worker.
// Generational handles prevent a stale index entry from targeting a reused FD.
track_user_connection :: proc(c: ^NRC_Connection) {
	username := get_connection_username(c)
	ws := get_connection_workspace(c)
	if ws == nil || username == "" {
		return
	}

	head := ws.user_connection_head[username]
	for handle := head; handle != {}; handle = ws.user_connection_next[handle] {
		if handle == c.handle do return
	}
	if head != {} {
		ws.user_connection_next[c.handle] = head
	}
	ws.user_connection_head[username] = c.handle
}

untrack_user_connection :: proc(c: ^NRC_Connection) {
	if c == nil do return
	username := get_connection_username(c)
	ws := get_connection_workspace(c)
	if ws == nil || username == "" {
		return
	}

	handle, ok := ws.user_connection_head[username]
	if !ok {
		return
	}
	previous := Connection_Handle{}
	for handle != {} {
		indexed := connection_get_by_handle(handle)
		assert(indexed != nil, "user connection index contains stale handle")
		if indexed == nil do break
		next := ws.user_connection_next[handle]
		if handle == c.handle {
			if previous == {} {
				if next == {} {
					delete_key(&ws.user_connection_head, username)
				} else {
					ws.user_connection_head[username] = next
				}
			} else {
				if next == {} {
					delete_key(&ws.user_connection_next, previous)
				} else {
					ws.user_connection_next[previous] = next
				}
			}
			delete_key(&ws.user_connection_next, handle)
			return
		}
		previous = handle
		handle = next
	}
}

// Get all live sockets for a user in a workspace from the per-user index.
get_user_sockets :: proc(ws: ^Workspace_State, username: string, allocator := context.allocator) -> [dynamic]net.TCP_Socket {
	sockets := make([dynamic]net.TCP_Socket, 0, 4, allocator)
	if ws == nil || username == "" {
		return sockets
	}

	handle, ok := ws.user_connection_head[username]
	if !ok {
		return sockets
	}
	for handle != {} {
		conn := connection_get_by_handle(handle)
		assert(conn != nil, "user connection index contains stale handle")
		if conn == nil do break
		next := ws.user_connection_next[handle]
		if conn.state >= .Will_Close {
			handle = next
			continue
		}
		if get_connection_workspace(conn) != ws {
			handle = next
			continue
		}
		if get_connection_username(conn) == username {
			append(&sockets, conn.sock)
		}
		handle = next
	}
	return sockets
}

// Increment user connection count (call on connect/auth)
// Note: username should already be interned by caller
on_user_connect :: proc(ws: ^Workspace_State, username: string, authenticated: bool) {
	if username == "" {
		return
	}

	prev_count := ws.user_connection_count[username]
	ws.user_connection_count[username] = prev_count + 1
	if authenticated {
		ws.user_authenticated_connection_count[username] = ws.user_authenticated_connection_count[username] + 1
	}

	if prev_count == 0 {
		now := nrc_time_unix_seconds()
		notify_dm_partners_status(ws, username, true, now)
	}
}

// Decrement user connection count (call on disconnect)
// Note: username should already be interned by caller
on_user_disconnect :: proc(ws: ^Workspace_State, username: string, authenticated: bool) {
	if username == "" {
		return
	}

	if authenticated {
		auth_count := ws.user_authenticated_connection_count[username]
		if auth_count > 1 {
			ws.user_authenticated_connection_count[username] = auth_count - 1
		} else if auth_count == 1 {
			delete_key(&ws.user_authenticated_connection_count, username)
		}
	}

	count, ok := ws.user_connection_count[username]
	if !ok || count <= 0 {
		return
	}

	if count == 1 {
		delete_key(&ws.user_connection_count, username)
		now := nrc_time_unix_seconds()
		ws.user_last_seen[username] = now
		notify_dm_partners_status(ws, username, false, now)
	} else {
		ws.user_connection_count[username] = count - 1
	}
}

// Notify all DM partners about a user's online/offline status change
notify_dm_partners_status :: proc(ws: ^Workspace_State, username: string, online: bool, timestamp: u64) {
	dms, ok := ws.user_dms[username]
	if !ok {
		return
	}

	for conv_id in dms {
		conv := get_conversation(ws, conv_id)
		if conv == nil || conv.dm_participants == nil {
			continue
		}

		partner := conv.dm_participants.user_a
		if partner == username {
			partner = conv.dm_participants.user_b
		}

		sort_subscribers_by_handle_index_if_dirty(conv)
		for entry in conv.subscriber_entries {
			conn := connection_get_by_handle(entry.handle)
			if conn == nil || conn.sock != entry.sock || conn.state >= .Will_Close {
				continue
			}
			if get_connection_username(conn) == partner {
				send_dm_partner_status(conn, conv_id, online, username, timestamp)
			}
		}
	}
}

// Add a DM to a user's list (idempotent)
add_user_dm :: proc(ws: ^Workspace_State, username: string, conv_id: pr.ConversationID) {
	interned := intern_username(username)
	if interned not_in ws.user_dms {
		ws.user_dms[interned] = make([dynamic]pr.ConversationID, 0, 4)
	}
	dms := &ws.user_dms[interned]
	for existing in dms^ {
		if existing == conv_id {
			return
		}
	}
	append(dms, conv_id)
}

// Remove a DM from a user's list
remove_user_dm :: proc(ws: ^Workspace_State, username: string, conv_id: pr.ConversationID) {
	dms, ok := &ws.user_dms[username]
	if !ok {
		return
	}
	for i := 0; i < len(dms); i += 1 {
		if dms[i] == conv_id {
			ordered_remove(dms, i)
			break
		}
	}
	if len(dms^) == 0 {
		delete(dms^)
		delete_key(&ws.user_dms, username)
	}
}

// Check if a user is a participant in a DM
is_user_in_dm :: proc(ws: ^Workspace_State, username: string, conv_id: pr.ConversationID) -> bool {
	dms, ok := ws.user_dms[username]
	if !ok {
		return false
	}
	for existing in dms {
		if existing == conv_id {
			return true
		}
	}
	return false
}

// Validate DM access for subscription
validate_dm_access :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID) -> bool {
	ws := get_connection_workspace(c)
	if ws == nil {
		return false
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil || conv.dm_participants == nil {
		return false
	}

	username := get_connection_username(c)
	is_participant := username == conv.dm_participants.user_a || username == conv.dm_participants.user_b
	return is_participant && is_user_in_dm(ws, username, conv_id)
}

// Subscribe a user's connection to a DM (internal, bypasses access check)
subscribe_to_dm_internal :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID) {
	ws := get_or_create_connection_workspace(c)
	conv := get_or_create_conversation(ws, conv_id)

	if conversation_add_subscriber(conv, c) {
		add_socket_room(c, conv_id)
	}
}

// Process C_StartDM request
process_start_dm :: proc(c: ^NRC_Connection, req: pr.StartDMRequest) {
	username := get_connection_username(c)
	target := req.username

	if username == "" {
		send_dm_error(c, .Not_Authenticated, target, "Not authenticated", req.correlation_id)
		return
	}

	if target == username {
		send_dm_error(c, .Cannot_DM_Self, target, "Cannot start DM with yourself", req.correlation_id)
		return
	}

	ws := get_or_create_connection_workspace(c)

	if !find_user_in_workspace(ws, target) {
		send_dm_error(c, .User_Not_Found, target, "User not found", req.correlation_id)
		return
	}

	conv_id := pr.make_dm_conversation_id(username, target)
	conv := get_or_create_conversation(ws, conv_id)

	already_tracked_target := is_user_in_dm(ws, target, conv_id)

	if conv.dm_participants == nil {
		conv.dm_participants = new(DM_Participants)
		a, b := username, target
		if a > b {
			a, b = b, a
		}
		conv.dm_participants.user_a = intern_username(a)
		conv.dm_participants.user_b = intern_username(b)
	}

	add_user_dm(ws, username, conv_id)
	add_user_dm(ws, target, conv_id)

	my_sockets := get_user_sockets(ws, username)
	defer delete(my_sockets)
	for sock in my_sockets {
		if conn := connection_get(sock); conn != nil {
			subscribe_to_dm_internal(conn, conv_id)
		}
	}

	target_sockets := get_user_sockets(ws, target)
	defer delete(target_sockets)
	for sock in target_sockets {
		if conn := connection_get(sock); conn != nil {
			subscribe_to_dm_internal(conn, conv_id)
		}
	}

	target_online := is_user_online(ws, target)
	target_authenticated := is_user_authenticated(ws, target)
	self_online := is_user_online(ws, username)
	self_authenticated := c.authenticated

	for sock in my_sockets {
		if conn := connection_get(sock); conn != nil {
			corr := conn.sock == c.sock ? req.correlation_id : u32(0)
			send_dm_started(conn, conv_id, target, target_authenticated, target_online, true, corr)
		}
	}

	if !already_tracked_target {
		for sock in target_sockets {
			if conn := connection_get(sock); conn != nil {
				send_dm_started(conn, conv_id, username, self_authenticated, self_online, false)
			}
		}
	}
}

// Process C_ListDMs request
process_list_dms :: proc(c: ^NRC_Connection, req: pr.ListDMsRequest) {
	username := get_connection_username(c)
	if username == "" {
		send_dm_error(c, .Not_Authenticated, "", "Not authenticated", req.correlation_id)
		return
	}

	ws := get_or_create_connection_workspace(c)
	dms, ok := ws.user_dms[username]
	if !ok {
		send_dm_list(c, {}, req.correlation_id)
		return
	}

	entries := make([dynamic]pr.DMEntry, 0, len(dms))
	defer delete(entries)

	for conv_id in dms {
		conv := get_conversation(ws, conv_id)
		if conv == nil || conv.dm_participants == nil {
			continue
		}

		subscribe_to_dm_internal(c, conv_id)

		partner := conv.dm_participants.user_a
		if partner == username {
			partner = conv.dm_participants.user_b
		}

		online := is_user_online(ws, partner)
		authenticated := is_user_authenticated(ws, partner)
		last_seen := ws.user_last_seen[partner]

		append(&entries, pr.DMEntry{conv_id = conv_id, username = partner, authenticated = authenticated, online = online, last_seen = last_seen})
	}

	send_dm_list(c, entries[:], req.correlation_id)
}

// Process C_LeaveDM request
process_leave_dm :: proc(c: ^NRC_Connection, req: pr.LeaveDMRequest) {
	username := get_connection_username(c)
	if username == "" {
		send_dm_error(c, .Not_Authenticated, "", "Not authenticated", req.correlation_id)
		return
	}

	conv_id := req.conv_id
	if !pr.is_dm_conversation(conv_id) {
		send_dm_error(c, .DM_Not_Found, "", "Not a DM conversation", req.correlation_id)
		return
	}

	ws := get_or_create_connection_workspace(c)

	if !is_user_in_dm(ws, username, conv_id) {
		send_dm_error(c, .DM_Not_Found, "", "Not in this DM", req.correlation_id)
		return
	}

	remove_user_dm(ws, username, conv_id)

	my_sockets := get_user_sockets(ws, username)
	defer delete(my_sockets)
	for sock in my_sockets {
		if conn := connection_get(sock); conn != nil {
			unsubscribe_from_dm_internal(conn, conv_id)
			corr := conn.sock == c.sock ? req.correlation_id : u32(0)
			send_dm_left(conn, conv_id, corr)
		}
	}

	maybe_cleanup_orphaned_dm(ws, conv_id)
}

// Unsubscribe from DM (internal)
unsubscribe_from_dm_internal :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID) {
	ws := get_connection_workspace(c)
	if ws == nil {
		return
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return
	}

	handle := c.handle
	for flush_presence_batch(conv) {
		if connection_get_by_handle(handle) != c || c.state >= .Will_Close do return
	}

	if conversation_remove_subscriber(conv, c.sock) {
		remove_socket_room(c, conv_id)
	}
}

// Clean up orphaned DM if both users have left
maybe_cleanup_orphaned_dm :: proc(ws: ^Workspace_State, conv_id: pr.ConversationID) {
	conv := get_conversation(ws, conv_id)
	if conv == nil || conv.dm_participants == nil {
		return
	}

	user_a := conv.dm_participants.user_a
	user_b := conv.dm_participants.user_b

	a_in := is_user_in_dm(ws, user_a, conv_id)
	b_in := is_user_in_dm(ws, user_b, conv_id)

	if !a_in && !b_in {
		delete_key(&ws.conversations, conv_id)
		destroy_conversation(conv)
	}
}

// Cleanup DM state when connection closes
cleanup_dm_on_disconnect :: proc(c: ^NRC_Connection) {
	username := get_connection_username(c)
	if username == "" {
		return
	}

	ws := get_connection_workspace(c)
	if ws == nil {
		return
	}

	untrack_user_connection(c)
	on_user_disconnect(ws, username, c.authenticated)
}

// Send helpers

send_dm_started :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	username: string,
	authenticated: bool,
	online: bool,
	is_initiator: bool,
	correlation_id: u32 = 0,
) {
	protocol_size := pr.dm_started_size(username)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "S_DMStarted")
	if buf == nil {
		return
	}

	pr.write_dm_started(buf[header_len:], conv_id, username, authenticated, online, is_initiator, correlation_id)
	_ = send_pooled_buffer(c, buf)
}

send_dm_list :: proc(c: ^NRC_Connection, entries: []pr.DMEntry, correlation_id: u32 = 0) {
	protocol_size := pr.dm_list_header_size()
	for entry in entries {
		protocol_size += pr.dm_entry_size(entry.username)
	}

	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "S_DMList")
	if buf == nil {
		return
	}

	pr.write_dm_list_header(buf[header_len:], u16(len(entries)), correlation_id)
	offset := header_len + pr.dm_list_header_size()
	for entry in entries {
		written := pr.write_dm_entry(buf[offset:], entry)
		offset += written
	}

	_ = send_pooled_buffer(c, buf)
}

send_dm_error :: proc(c: ^NRC_Connection, code: pr.DM_Error_Code, target_username: string, message: string, correlation_id: u32 = 0) {
	protocol_size := pr.dm_error_size(target_username, message)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "S_DMError")
	if buf == nil {
		return
	}

	pr.write_dm_error(buf[header_len:], code, target_username, message, correlation_id)
	_ = send_pooled_buffer(c, buf)
}

send_dm_left :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, correlation_id: u32 = 0) {
	protocol_size := pr.dm_left_size()
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "S_DMLeft")
	if buf == nil {
		return
	}

	pr.write_dm_left(buf[header_len:], conv_id, correlation_id)
	_ = send_pooled_buffer(c, buf)
}

send_dm_partner_status :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, online: bool, username: string, last_seen: u64) {
	protocol_size := pr.dm_partner_status_size(username)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "S_DMPartnerStatus")
	if buf == nil {
		return
	}

	pr.write_dm_partner_status(buf[header_len:], conv_id, online, username, last_seen)
	_ = send_pooled_buffer(c, buf)
}
