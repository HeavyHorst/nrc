//
// edge_handlers.odin - Edge Response and Broadcast Helpers
//
// Workspace record commands and queries are handled by SQLite.
// Edges are non-ownership links between entities (assets or tasks).
// Deleting either endpoint deletes all incident edges (but not the other endpoint).
//
package main

import "core:log"
import "core:net"

import "byte_pool"
import pr "protocol"

DEFAULT_EDGE_PAGE_LIMIT :: 250
MAX_EDGE_PAGE_LIMIT :: 1000

// ============================================================================
// Response Senders
// ============================================================================

send_edge_created :: proc(c: ^NRC_Connection, edge: pr.Edge, correlation_id: u32 = 0) {
	msg := pr.EdgeCreatedMessage {
		edge           = edge,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeEdgeCreatedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "edge created")
	if buf == nil do return

	protocol_len := pr.serializeEdgeCreatedMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize EdgeCreated for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_edge_deleted :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, edge_id: pr.EdgeID, correlation_id: u32 = 0) {
	msg := pr.EdgeDeletedMessage {
		conv_id        = conv_id,
		edge_id        = edge_id,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeEdgeDeletedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "edge deleted")
	if buf == nil do return

	protocol_len := pr.serializeEdgeDeletedMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize EdgeDeleted for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_edge_list :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, target_type: pr.TargetType, target_id: u64, edges: []pr.Edge, correlation_id: u32 = 0) {
	msg := pr.EdgeListMessage {
		conv_id        = conv_id,
		target_type    = target_type,
		target_id      = target_id,
		edges          = edges if edges != nil else []pr.Edge{},
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeEdgeListMessage(msg)
	if protocol_size > MAX_PROTOCOL_PAYLOAD_SIZE {
		send_error_response(c, .C_ListEdges, "Edge list too large; use ListAllEdgesPaged", correlation_id)
		return
	}
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "edge list")
	if buf == nil do return

	protocol_len := pr.serializeEdgeListMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize EdgeList for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_all_edge_list :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, edges: []pr.Edge, correlation_id: u32 = 0) {
	msg := pr.AllEdgeListMessage {
		conv_id        = conv_id,
		edges          = edges if edges != nil else []pr.Edge{},
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeAllEdgeListMessage(msg)
	if protocol_size > MAX_PROTOCOL_PAYLOAD_SIZE {
		send_error_response(c, .C_ListAllEdges, "Edge list too large; use ListAllEdgesPaged", correlation_id)
		return
	}
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "all edge list")
	if buf == nil do return

	protocol_len := pr.serializeAllEdgeListMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize AllEdgeList for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

// ============================================================================
// Broadcast Functions
// ============================================================================

broadcast_edge_created_by_id :: proc(edge: pr.Edge, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_edge_created_with_workspace(edge, excluded_sock, get_workspace(workspace_id))
}

broadcast_edge_created_with_workspace :: proc(edge: pr.Edge, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, edge.conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	msg := pr.EdgeCreatedMessage {
		edge = edge,
	}
	shared_buf := create_shared_edge_created_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_edge_created :: proc {
	broadcast_edge_created_by_id,
	broadcast_edge_created_with_workspace,
}

broadcast_edge_deleted_by_id :: proc(conv_id: pr.ConversationID, edge_id: pr.EdgeID, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_edge_deleted_with_workspace(conv_id, edge_id, excluded_sock, get_workspace(workspace_id))
}

broadcast_edge_deleted_with_workspace :: proc(conv_id: pr.ConversationID, edge_id: pr.EdgeID, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	msg := pr.EdgeDeletedMessage {
		conv_id = conv_id,
		edge_id = edge_id,
	}
	shared_buf := create_shared_edge_deleted_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_edge_deleted :: proc {
	broadcast_edge_deleted_by_id,
	broadcast_edge_deleted_with_workspace,
}

// ============================================================================
// Shared Buffer Creation (for broadcasts)
// ============================================================================

create_shared_edge_created_buffer :: proc(msg: pr.EdgeCreatedMessage) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeEdgeCreatedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "edge created broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeEdgeCreatedMessage(msg, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:header_len + protocol_len]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}

create_shared_edge_deleted_buffer :: proc(msg: pr.EdgeDeletedMessage) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeEdgeDeletedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "edge deleted broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeEdgeDeletedMessage(msg, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:header_len + protocol_len]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}
