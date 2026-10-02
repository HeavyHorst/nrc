//
// edge_handlers.odin - Edge/Knowledge Graph Message Handlers
//
// This file implements the WebSocket message handlers for edge CRUD operations.
// Edges are non-ownership links between entities (assets or tasks).
// Deleting either endpoint deletes all incident edges (but not the other endpoint).
//
package main

import "core:log"
import "core:mem"
import "core:net"
import "core:slice"

import "byte_pool"
import pr "protocol"

// ============================================================================
// Create Edge
// ============================================================================

handle_create_edge :: proc(c: ^NRC_Connection, req: pr.CreateEdgeRequest) {
	workspace_id := c.workspace_id

	ws := get_or_create_connection_workspace(c)
	conv := get_or_create_conversation(ws, req.conv_id)

	if req.relation < min(pr.RelationType) || req.relation > max(pr.RelationType) {
		log.warnf("[T%d] Invalid edge relation: %d", td.thread_index, req.relation)
		send_error_response(c, .C_CreateEdge, "Invalid edge relation", req.correlation_id)
		return
	}

	// Validate source exists
	if !entity_exists(conv, req.source_type, req.source_id) {
		log.warnf("[T%d] Edge source entity not found: type=%d id=%d", td.thread_index, req.source_type, req.source_id)
		send_error_response(c, .C_CreateEdge, "Edge source entity not found", req.correlation_id)
		return
	}

	// Validate target exists
	if !entity_exists(conv, req.target_type, req.target_id) {
		log.warnf("[T%d] Edge target entity not found: type=%d id=%d", td.thread_index, req.target_type, req.target_id)
		send_error_response(c, .C_CreateEdge, "Edge target entity not found", req.correlation_id)
		return
	}

	// Disallow self-edges
	if req.source_type == req.target_type && req.source_id == req.target_id {
		log.warnf("[T%d] Self-edge not allowed", td.thread_index)
		send_error_response(c, .C_CreateEdge, "Self-edge not allowed", req.correlation_id)
		return
	}

	// Membership is a set, not a list: a second MemberOf edge between one member
	// and one slice would count that member twice in the register and render it
	// twice in the record. Generic relations may repeat; membership may not.
	if duplicate_membership_edge(conv, req) {
		log.warnf("[T%d] Member is already assigned to the slice", td.thread_index)
		send_error_response(c, .C_CreateEdge, "Member is already assigned to this slice", req.correlation_id)
		return
	}

	// Check edge limit
	if len(conv.edges) >= pr.MAX_EDGES_PER_CONVERSATION {
		log.warnf("[T%d] Edge limit reached for conversation %d", td.thread_index, req.conv_id)
		send_error_response(c, .C_CreateEdge, "Edge limit reached", req.correlation_id)
		return
	}

	// Generate an ID candidate; publish the high-water only after WAL acceptance.
	edge_id := pr.EdgeID(td.edge_seq + 1)

	// Get creator from connection
	created_by := get_connection_nickname(c)
	now := nrc_time_unix_nanos()

	// Allocate edge
	new_edge := alloc_edge(transmute([]byte)created_by)
	if new_edge == nil {
		log.errorf("[T%d] Failed to allocate edge", td.thread_index)
		send_error_response(c, .C_CreateEdge, "Failed to allocate edge", req.correlation_id)
		return
	}

	new_edge.edge_id = edge_id
	new_edge.conv_id = req.conv_id
	new_edge.source_type = req.source_type
	new_edge.source_id = req.source_id
	new_edge.target_type = req.target_type
	new_edge.target_id = req.target_id
	new_edge.relation = req.relation
	new_edge.created_at = now

	// Stage the WAL transaction before changing speculative in-memory state.
	// The outbox holds responses and broadcasts until the batch is fsynced.
	if !persist_edge_created(workspace_id, new_edge) {
		persistent_mutation_failed("edge", "create", workspace_id)
		free_edge(new_edge)
		return
	}
	td.edge_seq = u64(edge_id)

	// Store in conversation
	edge_store_put(conv, new_edge)

	// Send to requester
	send_edge_created(c, new_edge^, req.correlation_id)

	// Broadcast to other subscribers
	broadcast_edge_created(new_edge^, c.sock, ws)

	log.infof(
		"[T%d] Created edge %d (%d:%d -> %d:%d, rel=%d) in conv %d",
		td.thread_index,
		edge_id,
		req.source_type,
		req.source_id,
		req.target_type,
		req.target_id,
		req.relation,
		req.conv_id,
	)
}

// duplicate_membership_edge reports whether the member is already joined to the
// slice. Membership is a set, so the edge is matched as an unordered pair: a
// client that writes slice -> member instead of member -> slice is asking for
// the same membership, and it is refused the same way.
duplicate_membership_edge :: proc(conv: ^Conversation_State, req: pr.CreateEdgeRequest) -> bool {
	if conv == nil || req.relation != .MemberOf do return false
	key := Edge_Entity_Key {
		target_type = req.source_type,
		target_id   = req.source_id,
	}
	edge_ids, ok := conv.edges_by_entity[key]
	if !ok do return false
	for edge_id in edge_ids {
		edge := conv.edges[edge_id]
		if edge == nil || edge.relation != .MemberOf do continue
		same_direction :=
			edge.source_type == req.source_type && edge.source_id == req.source_id && edge.target_type == req.target_type && edge.target_id == req.target_id
		reversed :=
			edge.source_type == req.target_type && edge.source_id == req.target_id && edge.target_type == req.source_type && edge.target_id == req.source_id
		if same_direction || reversed do return true
	}
	return false
}

// ============================================================================
// Delete Edge
// ============================================================================

handle_delete_edge :: proc(c: ^NRC_Connection, req: pr.DeleteEdgeRequest) {
	workspace_id := c.workspace_id

	ws := get_connection_workspace(c)
	if ws == nil {
		send_error_response(c, .C_DeleteEdge, "Workspace not found", req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_error_response(c, .C_DeleteEdge, "Conversation not found", req.correlation_id)
		return
	}

	edge := conv.edges[req.edge_id]
	if edge == nil {
		log.warnf("[T%d] Edge %d not found for delete", td.thread_index, req.edge_id)
		send_error_response(c, .C_DeleteEdge, "Edge not found", req.correlation_id)
		return
	}

	// Persist deletion before mutating adjacency/map ownership or acknowledging.
	if !persist_edge_deleted_kernel_accepted(workspace_id, req.conv_id, req.edge_id) {
		persistent_mutation_failed("edge", "delete", workspace_id)
		return
	}

	edge_store_remove(conv, req.edge_id)

	// Send to requester
	send_edge_deleted(c, req.conv_id, req.edge_id, req.correlation_id)

	// Broadcast to other subscribers
	broadcast_edge_deleted(req.conv_id, req.edge_id, c.sock, ws)

	log.infof("[T%d] Deleted edge %d in conv %d", td.thread_index, req.edge_id, req.conv_id)
}

// ============================================================================
// List Edges (for an entity)
// ============================================================================

handle_list_edges :: proc(c: ^NRC_Connection, req: pr.ListEdgesRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_edge_list(c, req.conv_id, req.target_type, req.target_id, nil, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_edge_list(c, req.conv_id, req.target_type, req.target_id, nil, req.correlation_id)
		return
	}

	// Look up incident edges
	key := Edge_Entity_Key {
		target_type = req.target_type,
		target_id   = req.target_id,
	}
	edge_ids, ok := conv.edges_by_entity[key]
	if !ok {
		send_edge_list(c, req.conv_id, req.target_type, req.target_id, nil, req.correlation_id)
		return
	}

	// Collect edges
	edges := make([dynamic]pr.Edge, 0, len(edge_ids))
	defer delete(edges)

	for edge_id in edge_ids {
		if edge := conv.edges[edge_id]; edge != nil {
			append(&edges, edge^)
		}
	}

	send_edge_list(c, req.conv_id, req.target_type, req.target_id, edges[:], req.correlation_id)
}

// ============================================================================
// List ALL Edges for Room (C_ListAllEdges = 43)
// ============================================================================

handle_list_all_edges :: proc(c: ^NRC_Connection, req: pr.ListAllEdgesRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_all_edge_list(c, req.conv_id, nil, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_all_edge_list(c, req.conv_id, nil, req.correlation_id)
		return
	}

	// Collect all edges for this conversation
	edges := make([dynamic]pr.Edge, 0, len(conv.edges))
	defer delete(edges)

	for _, edge in conv.edges {
		if edge != nil {
			append(&edges, edge^)
		}
	}

	send_all_edge_list(c, req.conv_id, edges[:], req.correlation_id)
}

DEFAULT_EDGE_PAGE_LIMIT :: 250
MAX_EDGE_PAGE_LIMIT :: 1000

collect_edge_page :: proc(conv: ^Conversation_State, req: pr.ListAllEdgesPagedRequest, edges: ^[dynamic]pr.Edge) -> pr.AllEdgeListPageMessage {
	msg := pr.AllEdgeListPageMessage {
		conv_id        = req.conv_id,
		correlation_id = req.correlation_id,
	}
	if conv == nil do return msg
	limit := int(req.limit)
	if limit == 0 do limit = DEFAULT_EDGE_PAGE_LIMIT
	limit = min(limit, MAX_EDGE_PAGE_LIMIT)
	ids := make([dynamic]pr.EdgeID, 0, len(conv.edges))
	defer delete(ids)
	for id, edge in conv.edges {
		if edge == nil do continue
		msg.total_count += 1
		if id > req.after_edge_id do append(&ids, id)
	}
	slice.sort(ids[:])
	size := pr.getSizeAllEdgeListPageMessage(msg)
	for id in ids {
		edge := conv.edges[id]
		item_size := pr.getSizeEdge(edge^)
		if len(edges) == limit || size + item_size > MAX_PROTOCOL_PAYLOAD_SIZE {
			msg.has_more = true
			break
		}
		append(edges, edge^)
		size += item_size
		msg.next_edge_id = id
	}
	msg.edges = edges[:]
	return msg
}

handle_list_all_edges_paged :: proc(c: ^NRC_Connection, req: pr.ListAllEdgesPagedRequest) {
	ws := get_connection_workspace(c)
	conv: ^Conversation_State
	if ws != nil do conv = get_conversation(ws, req.conv_id)
	edges := make([dynamic]pr.Edge, 0, MAX_EDGE_PAGE_LIMIT)
	defer delete(edges)
	msg := collect_edge_page(conv, req, &edges)
	if msg.has_more && len(msg.edges) == 0 {
		send_error_response(c, .C_ListAllEdgesPaged, "Edge exceeds page byte limit", req.correlation_id)
		return
	}
	buf, header_len := allocate_websocket_frame_buffer(pr.getSizeAllEdgeListPageMessage(msg), "edge list page")
	if buf == nil do return
	written := pr.serializeAllEdgeListPageMessage(msg, buf[header_len:])
	if written < 0 {
		byte_pool.release(td.spool, buf)
		send_error_response(c, .C_ListAllEdgesPaged, "Failed to serialize edge page", req.correlation_id)
		return
	}
	_ = send_pooled_buffer(c, buf[:header_len + written])
}

// ============================================================================
// Delete Edges for Entity (called when asset/task is deleted)
// ============================================================================

Edge_Delete_Plan :: struct {
	edge_ids: [dynamic]pr.EdgeID,
}

edge_delete_plan_init :: proc(plan: ^Edge_Delete_Plan, capacity: int = 8) {
	plan.edge_ids = make([dynamic]pr.EdgeID, 0, capacity)
}

edge_delete_plan_destroy :: proc(plan: ^Edge_Delete_Plan) {
	delete(plan.edge_ids)
	plan.edge_ids = nil
}

edge_delete_plan_add :: proc(plan: ^Edge_Delete_Plan, edge_id: pr.EdgeID) {
	for existing in plan.edge_ids {
		if existing == edge_id {
			return
		}
	}
	if _, err := append(&plan.edge_ids, edge_id); err != nil do panic("failed to collect edge cascade")
}

edge_delete_plan_contains :: proc(plan: ^Edge_Delete_Plan, edge_id: pr.EdgeID) -> bool {
	for existing in plan.edge_ids {
		if existing == edge_id {
			return true
		}
	}
	return false
}

collect_edges_for_entity_delete :: proc(conv: ^Conversation_State, plan: ^Edge_Delete_Plan, target_type: pr.TargetType, target_id: u64) {
	collect_edges_for_entity_delete_excluding(conv, plan, target_type, target_id, nil)
}

collect_edges_for_entity_delete_excluding :: proc(
	conv: ^Conversation_State,
	plan: ^Edge_Delete_Plan,
	target_type: pr.TargetType,
	target_id: u64,
	excluded_plan: ^Edge_Delete_Plan,
) {
	if conv == nil {
		return
	}

	key := Edge_Entity_Key {
		target_type = target_type,
		target_id   = target_id,
	}
	edge_ids, ok := conv.edges_by_entity[key]
	if !ok {
		return
	}

	for edge_id in edge_ids {
		if conv.edges[edge_id] != nil && (excluded_plan == nil || !edge_delete_plan_contains(excluded_plan, edge_id)) {
			edge_delete_plan_add(plan, edge_id)
		}
	}
}

apply_edge_delete_id :: proc(conv: ^Conversation_State, ws: ^Workspace_State, conv_id: pr.ConversationID, edge_id: pr.EdgeID, excluded_sock: net.TCP_Socket) {
	if conv == nil {
		return
	}

	edge := conv.edges[edge_id]
	if edge == nil {
		return
	}

	edge_store_remove(conv, edge_id)

	broadcast_edge_deleted(conv_id, edge_id, excluded_sock, ws)
}

persist_and_apply_edge_delete_plan :: proc(
	workspace_id: string,
	conv: ^Conversation_State,
	ws: ^Workspace_State,
	conv_id: pr.ConversationID,
	plan: ^Edge_Delete_Plan,
	excluded_sock: net.TCP_Socket,
) -> bool {
	for edge_id in plan.edge_ids {
		if !persist_edge_deleted_kernel_accepted(workspace_id, conv_id, edge_id) {
			persistent_mutation_failed("edge", "delete", workspace_id)
			return false
		}
		apply_edge_delete_id(conv, ws, conv_id, edge_id, excluded_sock)
	}
	return true
}

// delete_edges_for_entity removes all edges incident to the given entity.
// Called before deleting an asset or task to maintain graph integrity.
delete_edges_for_entity_by_id :: proc(
	workspace_id: string,
	conv_id: pr.ConversationID,
	target_type: pr.TargetType,
	target_id: u64,
	excluded_sock: net.TCP_Socket,
) -> bool {
	return delete_edges_for_entity_with_workspace(get_workspace(workspace_id), workspace_id, conv_id, target_type, target_id, excluded_sock)
}

delete_edges_for_entity_with_workspace :: proc(
	ws: ^Workspace_State,
	workspace_id: string,
	conv_id: pr.ConversationID,
	target_type: pr.TargetType,
	target_id: u64,
	excluded_sock: net.TCP_Socket,
) -> bool {
	if ws == nil {
		return true
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return true
	}

	plan: Edge_Delete_Plan
	edge_delete_plan_init(&plan)
	defer edge_delete_plan_destroy(&plan)
	collect_edges_for_entity_delete(conv, &plan, target_type, target_id)

	if !persist_and_apply_edge_delete_plan(workspace_id, conv, ws, conv_id, &plan, excluded_sock) {
		return false
	}

	if len(plan.edge_ids) > 0 {
		log.infof("[T%d] Cascade deleted %d edges for entity %d:%d in conv %d", td.thread_index, len(plan.edge_ids), target_type, target_id, conv_id)
	}
	return true
}

delete_edges_for_entity :: proc {
	delete_edges_for_entity_by_id,
	delete_edges_for_entity_with_workspace,
}

// ============================================================================
// Helper Functions
// ============================================================================

// entity_exists checks if an entity (asset or task) exists in the conversation
entity_exists :: proc(conv: ^Conversation_State, target_type: pr.TargetType, target_id: u64) -> bool {
	switch target_type {
	case .Asset:
		return conv.assets[pr.AssetID(target_id)] != nil
	case .Task:
		return conv.tasks[pr.TaskID(target_id)] != nil
	}
	return false
}

// add_edge_to_adjacency adds an edge to an entity's adjacency list
add_edge_to_adjacency :: proc(conv: ^Conversation_State, target_type: pr.TargetType, target_id: u64, edge_id: pr.EdgeID) {
	key := Edge_Entity_Key {
		target_type = target_type,
		target_id   = target_id,
	}
	if key not_in conv.edges_by_entity {
		state_map_set(&conv.edges_by_entity, key, make([dynamic]pr.EdgeID, 0, 8))
	}
	if _, err := append(&conv.edges_by_entity[key], edge_id); err != nil do panic("failed to append edge adjacency")
}

// remove_edge_from_adjacency removes an edge from an entity's adjacency list
remove_edge_from_adjacency :: proc(conv: ^Conversation_State, target_type: pr.TargetType, target_id: u64, edge_id: pr.EdgeID) {
	key := Edge_Entity_Key {
		target_type = target_type,
		target_id   = target_id,
	}
	edge_list, ok := &conv.edges_by_entity[key]
	if !ok {
		return
	}

	// Find and remove (unordered, swap with last)
	for i := 0; i < len(edge_list); i += 1 {
		if edge_list[i] == edge_id {
			unordered_remove(edge_list, i)
			break
		}
	}

	// Clean up empty lists
	if len(edge_list^) == 0 {
		delete(edge_list^)
		delete_key(&conv.edges_by_entity, key)
	}
}

// ============================================================================
// Memory Management
// ============================================================================

// alloc_edge allocates an edge with a single allocation for the struct + created_by string
alloc_edge :: proc(created_by: []byte) -> ^pr.Edge {
	// Single allocation: Edge struct + created_by bytes
	total_size := size_of(pr.Edge) + len(created_by)
	block, err := mem.alloc_bytes(total_size)
	if err != nil {
		return nil
	}

	edge := cast(^pr.Edge)raw_data(block)
	edge^ = pr.Edge{}

	// Point created_by to inline data after struct
	if len(created_by) > 0 {
		created_by_offset := size_of(pr.Edge)
		edge.created_by = block[created_by_offset:created_by_offset + len(created_by)]
		copy(edge.created_by, created_by)
	}

	return edge
}

// free_edge frees an edge allocated with alloc_edge
free_edge :: proc(edge: ^pr.Edge) {
	if edge == nil {
		return
	}

	// Calculate original allocation size and free as raw bytes
	total_size := size_of(pr.Edge) + len(edge.created_by)
	mem.free(edge)
	_ = total_size // unused after switching to direct free
}

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
