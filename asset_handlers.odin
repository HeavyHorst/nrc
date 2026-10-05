//
// asset_handlers.odin - Asset Message Handlers
//
// This file implements the WebSocket message handlers for asset CRUD operations.
// Assets are generic, frontend-defined entities with opaque preview/payload.
//
package main

import "btree"
import "core:log"
import "core:net"
import "core:slice"

import "byte_pool"
import pr "protocol"

// ============================================================================
// Create Asset
// ============================================================================

handle_create_asset :: proc(c: ^NRC_Connection, req: pr.CreateAssetRequest) {
	workspace_id := c.workspace_id
	if !validate_appointment_asset(req.asset_type, req.payload_encoding, req.payload_raw_len, req.preview, req.payload, context.temp_allocator) {
		send_error_response(c, .C_CreateAsset, "Invalid appointment record", req.correlation_id)
		return
	}

	if req.asset_type == .RoomMapping {
		handle_create_room_mapping_asset(c, req)
		return
	}

	ws := get_or_create_connection_workspace(c)
	conv := get_or_create_conversation(ws, req.conv_id)

	// Legacy public rooms can contribute several agendas. Preserve each until
	// the caller explicitly chooses an asset ID; map iteration is not a choice.
	if req.asset_type == .Agenda {
		agenda_id: pr.AssetID
		for existing_id, existing in conv.assets {
			if existing.asset_type == .Agenda {
				if agenda_id != 0 {
					send_error_response(c, .C_CreateAsset, "Multiple migrated agendas: update an explicit asset ID", req.correlation_id)
					return
				}
				agenda_id = existing_id
			}
		}
		if agenda_id != 0 {
			update_req := pr.UpdateAssetRequest {
				conv_id          = req.conv_id,
				asset_id         = agenda_id,
				payload_encoding = req.payload_encoding,
				payload_raw_len  = req.payload_raw_len,
				preview          = req.preview,
				payload          = req.payload,
				attachments      = req.attachments,
				correlation_id   = req.correlation_id,
			}
			handle_update_asset(c, update_req)
			return
		}
	}

	// A slice is addressed by its name: the register selects by it, `slice get`
	// resolves by it and `slice assign` takes it. Two slices with one name would
	// make all three ambiguous, so the name is unique per conversation.
	if req.asset_type == .Slice {
		name, ok := slice_preview_name(req.preview, context.temp_allocator)
		if !ok {
			send_error_response(c, .C_CreateAsset, "Slice record must carry a version and a name", req.correlation_id)
			return
		}
		if slice_name_taken(conv, name, 0) {
			send_error_response(c, .C_CreateAsset, "A slice with that name already exists", req.correlation_id)
			return
		}
	}

	asset_id := pr.AssetID(td.asset_seq + 1)
	if asset_parent_would_cycle(conv, asset_id, req.parent_type, req.parent_id) {
		send_error_response(c, .C_CreateAsset, "Asset parent cycle not allowed", req.correlation_id)
		return
	}

	// Get owner from connection (use nickname as user identifier)
	owner := get_connection_nickname(c)
	now := nrc_time_unix_nanos()

	// Allocate asset with single-alloc pattern
	new_asset := alloc_asset(transmute([]byte)owner, req.preview, req.payload, req.attachments)
	if new_asset == nil {
		log.errorf("[T%d] Failed to allocate asset", td.thread_index)
		send_error_response(c, .C_CreateAsset, "Failed to allocate asset", req.correlation_id)
		return
	}

	new_asset.asset_type = req.asset_type
	new_asset.asset_id = asset_id
	new_asset.parent_type = req.parent_type
	new_asset.parent_id = req.parent_id
	new_asset.created_at = now
	new_asset.updated_at = now
	new_asset.conv_id = req.conv_id
	new_asset.payload_encoding = req.payload_encoding
	new_asset.payload_raw_len = req.payload_raw_len

	// Stage the WAL transaction before changing speculative in-memory state.
	// The outbox holds responses and broadcasts until the batch is fsynced.
	if !persist_asset_created(workspace_id, new_asset) {
		persistent_mutation_failed("asset", "create", workspace_id)
		free_asset(new_asset)
		return
	}
	td.asset_seq = u64(asset_id)

	// Store in conversation
	asset_store_put(ws, workspace_id, conv, new_asset)

	// Send to requester (with correlation_id for request/response matching)
	send_asset_created(c, new_asset^, req.correlation_id)

	// Broadcast to other subscribers (correlation_id=0)
	broadcast_asset_created(new_asset^, c.sock, ws)

	log.debugf("[T%d] Created asset %d (type=%d) in conv %d", td.thread_index, asset_id, req.asset_type, req.conv_id)
}

// ============================================================================
// Update Asset
// ============================================================================

handle_update_asset :: proc(c: ^NRC_Connection, req: pr.UpdateAssetRequest) {
	workspace_id := c.workspace_id

	ws := get_connection_workspace(c)
	if ws == nil {
		send_error_response(c, .C_UpdateAsset, "Workspace not found", req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_error_response(c, .C_UpdateAsset, "Conversation not found", req.correlation_id)
		return
	}

	existing := conv.assets[req.asset_id]
	if existing == nil {
		log.warnf("[T%d] Asset %d not found for update", td.thread_index, req.asset_id)
		send_error_response(c, .C_UpdateAsset, "Asset not found", req.correlation_id)
		return
	}
	if existing.asset_type == .RoomMapping {
		send_error_response(c, .C_UpdateAsset, "Room mappings are immutable", req.correlation_id)
		return
	}
	if !validate_appointment_asset(existing.asset_type, req.payload_encoding, req.payload_raw_len, req.preview, req.payload, context.temp_allocator) {
		send_error_response(c, .C_UpdateAsset, "Invalid appointment record", req.correlation_id)
		return
	}

	// A slice's name is its identity: the register selects by it, `slice get`
	// resolves by it and `slice assign` takes it. The name is fixed at creation,
	// so an update carries the record forward and cannot rename the slice or empty
	// the identity that every command addresses it by.
	if existing.asset_type == .Slice {
		name, ok := slice_preview_name(req.preview, context.temp_allocator)
		if !ok {
			send_error_response(c, .C_UpdateAsset, "Slice record must carry a version and a name", req.correlation_id)
			return
		}
		if current, has_current := slice_preview_name(existing.preview, context.temp_allocator); has_current && current != name {
			send_error_response(c, .C_UpdateAsset, "A slice name is fixed at creation", req.correlation_id)
			return
		}
	}

	// Preserve immutable fields from existing asset
	now := nrc_time_unix_nanos()

	// Allocate new asset with updated content
	new_asset := alloc_asset(existing.owner, req.preview, req.payload, req.attachments)
	if new_asset == nil {
		log.errorf("[T%d] Failed to allocate asset for update", td.thread_index)
		send_error_response(c, .C_UpdateAsset, "Failed to allocate asset", req.correlation_id)
		return
	}

	// Copy immutable fields
	new_asset.asset_type = existing.asset_type
	new_asset.asset_id = existing.asset_id
	new_asset.parent_type = existing.parent_type
	new_asset.parent_id = existing.parent_id
	new_asset.created_at = existing.created_at
	new_asset.updated_at = now
	new_asset.conv_id = existing.conv_id
	new_asset.payload_encoding = req.payload_encoding
	new_asset.payload_raw_len = req.payload_raw_len

	// Persist before replacing indexes/map ownership or acknowledging.
	if !persist_asset_updated(workspace_id, new_asset) {
		persistent_mutation_failed("asset", "update", workspace_id)
		free_asset(new_asset)
		return
	}

	// Free old and store new
	asset_store_put(ws, workspace_id, conv, new_asset)

	// Send to requester
	send_asset_updated(c, new_asset^, req.correlation_id)

	// Broadcast to other subscribers
	broadcast_asset_updated(new_asset^, c.sock, ws)

	log.debugf("[T%d] Updated asset %d in conv %d", td.thread_index, req.asset_id, req.conv_id)
}

asset_parent_would_cycle :: proc(conv: ^Conversation_State, asset_id: pr.AssetID, parent_type: pr.ParentType, parent_id: u64) -> bool {
	if conv == nil || parent_type != .Asset {
		return false
	}

	current_id := pr.AssetID(parent_id)
	visited := 0
	for current_id != 0 {
		if current_id == asset_id {
			return true
		}

		parent := conv.assets[current_id]
		if parent == nil || parent.parent_type != .Asset {
			return false
		}

		visited += 1
		if visited > len(conv.assets) {
			return true
		}

		current_id = pr.AssetID(parent.parent_id)
	}

	return false
}

// ============================================================================
// Delete Asset
// ============================================================================

handle_delete_asset :: proc(c: ^NRC_Connection, req: pr.DeleteAssetRequest) {
	workspace_id := c.workspace_id

	ws := get_connection_workspace(c)
	if ws == nil {
		send_error_response(c, .C_DeleteAsset, "Workspace not found", req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_error_response(c, .C_DeleteAsset, "Conversation not found", req.correlation_id)
		return
	}

	asset := conv.assets[req.asset_id]
	if asset == nil {
		log.warnf("[T%d] Asset %d not found for delete", td.thread_index, req.asset_id)
		send_error_response(c, .C_DeleteAsset, "Asset not found", req.correlation_id)
		return
	}
	if asset.asset_type == .RoomMapping {
		send_error_response(c, .C_DeleteAsset, "Room mappings are immutable", req.correlation_id)
		return
	}

	assets_to_delete := make([dynamic]pr.AssetID, 0, 16)
	defer delete(assets_to_delete)
	collect_child_asset_delete_ids(conv, req.asset_id, &assets_to_delete)

	child_edges_to_delete: Edge_Delete_Plan
	edge_delete_plan_init(&child_edges_to_delete)
	defer edge_delete_plan_destroy(&child_edges_to_delete)
	for child_id in assets_to_delete {
		collect_edges_for_entity_delete(conv, &child_edges_to_delete, pr.TargetType.Asset, u64(child_id))
	}
	parent_edges_to_delete: Edge_Delete_Plan
	edge_delete_plan_init(&parent_edges_to_delete)
	defer edge_delete_plan_destroy(&parent_edges_to_delete)
	collect_edges_for_entity_delete_excluding(conv, &parent_edges_to_delete, pr.TargetType.Asset, u64(req.asset_id), &child_edges_to_delete)

	if td.shard_writers.mode == .Active {
		if 1 + len(assets_to_delete) + len(child_edges_to_delete.edge_ids) + len(parent_edges_to_delete.edge_ids) > SHARD_TRANSACTION_MAX_MUTATIONS {
			send_error_response(c, .C_DeleteAsset, "Asset deletion exceeds atomic transaction size limit", req.correlation_id)
			return
		}
		workspace := transmute([]byte)workspace_id
		writer := shard_writer_for_workspace(&td.shard_writers, workspace)
		if writer == nil {
			persistent_mutation_failed("shard", "asset delete owner", workspace_id)
			return
		}
		asset_ids := make([]pr.AssetID, len(assets_to_delete) + 1)
		defer delete(asset_ids)
		copy(asset_ids, assets_to_delete[:])
		asset_ids[len(assets_to_delete)] = req.asset_id
		cascade, built := build_shard_asset_delete_transaction(
			workspace,
			req.conv_id,
			asset_ids,
			child_edges_to_delete.edge_ids[:],
			parent_edges_to_delete.edge_ids[:],
			writer.floors,
		)
		if !built || !append_shard_transaction(writer, &cascade.tx) {
			destroy_shard_asset_delete_transaction(&cascade)
			persistent_mutation_failed("shard", "asset delete", workspace_id)
			return
		}
		destroy_shard_asset_delete_transaction(&cascade)
		for edge_id in child_edges_to_delete.edge_ids do apply_edge_delete_id(conv, ws, req.conv_id, edge_id, net.TCP_Socket(-1))
		for edge_id in parent_edges_to_delete.edge_ids do apply_edge_delete_id(conv, ws, req.conv_id, edge_id, c.sock)
		for child_id in assets_to_delete do apply_asset_delete_id(conv, ws, req.conv_id, child_id)
	} else {
		// Apply the durable prefix as each tombstone is accepted. If a later tombstone
		// fails, RAM/client state reflects the already-persisted prefix and the server
		// fails closed.
		if !persist_and_apply_edge_delete_plan(workspace_id, conv, ws, req.conv_id, &child_edges_to_delete, net.TCP_Socket(-1)) {
			return
		}
		if !persist_and_apply_edge_delete_plan(workspace_id, conv, ws, req.conv_id, &parent_edges_to_delete, c.sock) {
			return
		}
		if !persist_and_apply_asset_delete_ids(workspace_id, conv, ws, req.conv_id, assets_to_delete[:]) {
			return
		}
		if !persist_asset_deleted_kernel_accepted(workspace_id, req.conv_id, req.asset_id) {
			persistent_mutation_failed("asset", "delete", workspace_id)
			return
		}
	}

	asset_store_remove(ws, conv, req.asset_id)

	// Send to requester
	send_asset_deleted(c, req.conv_id, req.asset_id, req.correlation_id)

	// Broadcast to other subscribers
	broadcast_asset_deleted_to_room(req.conv_id, req.asset_id, c.sock, ws)

	log.debugf("[T%d] Deleted asset %d from conv %d", td.thread_index, req.asset_id, req.conv_id)
}

// cascade_delete_child_assets deletes all assets with parent_type=ASSET and parent_id=asset_id
cascade_delete_child_assets_by_id :: proc(workspace_id: string, conv_id: pr.ConversationID, parent_asset_id: pr.AssetID) -> bool {
	return cascade_delete_child_assets_with_workspace(get_workspace(workspace_id), workspace_id, conv_id, parent_asset_id)
}

asset_delete_ids_add :: proc(asset_ids: ^[dynamic]pr.AssetID, asset_id: pr.AssetID) {
	for existing in asset_ids^ {
		if existing == asset_id {
			return
		}
	}
	if _, err := append(asset_ids, asset_id); err != nil do panic("failed to collect asset cascade")
}

collect_child_asset_delete_ids :: proc(conv: ^Conversation_State, parent_asset_id: pr.AssetID, asset_ids: ^[dynamic]pr.AssetID) {
	if conv == nil {
		return
	}

	children := make([dynamic]pr.AssetID, 0, 16)
	defer delete(children)
	it := btree.iter(&conv.asset_parents)
	defer btree.iter_destroy(&it)
	start := Entity_Reference_Key {
		kind      = u8(pr.ParentType.Asset),
		parent_id = u64(parent_asset_id),
	}
	for ok := btree.iter_seek(&it, start); ok; ok = btree.iter_next(&it) {
		key := btree.item(&it)
		if key.kind != start.kind || key.parent_id != start.parent_id do break
		asset_delete_ids_add(&children, pr.AssetID(key.entity_id))
	}

	for child_id in children {
		collect_child_asset_delete_ids(conv, child_id, asset_ids)
		asset_delete_ids_add(asset_ids, child_id)
	}
}

collect_task_asset_delete_ids :: proc(conv: ^Conversation_State, task_id: pr.TaskID, asset_ids: ^[dynamic]pr.AssetID) {
	if conv == nil {
		return
	}

	roots := make([dynamic]pr.AssetID, 0, 16)
	defer delete(roots)
	it := btree.iter(&conv.asset_parents)
	defer btree.iter_destroy(&it)
	start := Entity_Reference_Key {
		kind      = u8(pr.ParentType.Task),
		parent_id = u64(task_id),
	}
	for ok := btree.iter_seek(&it, start); ok; ok = btree.iter_next(&it) {
		key := btree.item(&it)
		if key.kind != start.kind || key.parent_id != start.parent_id do break
		asset_delete_ids_add(&roots, pr.AssetID(key.entity_id))
	}

	for root_id in roots {
		collect_child_asset_delete_ids(conv, root_id, asset_ids)
		asset_delete_ids_add(asset_ids, root_id)
	}
}

persist_and_apply_asset_delete_ids :: proc(
	workspace_id: string,
	conv: ^Conversation_State,
	ws: ^Workspace_State,
	conv_id: pr.ConversationID,
	asset_ids: []pr.AssetID,
) -> bool {
	for asset_id in asset_ids {
		if !persist_asset_deleted_kernel_accepted(workspace_id, conv_id, asset_id) {
			persistent_mutation_failed("asset", "delete", workspace_id)
			return false
		}
		apply_asset_delete_id(conv, ws, conv_id, asset_id)
	}
	return true
}

apply_asset_delete_id :: proc(conv: ^Conversation_State, ws: ^Workspace_State, conv_id: pr.ConversationID, asset_id: pr.AssetID) {
	if conv == nil {
		return
	}

	asset := conv.assets[asset_id]
	if asset == nil {
		return
	}
	asset_store_remove(ws, conv, asset_id)
	broadcast_asset_deleted_to_room(conv_id, asset_id, net.TCP_Socket(-1), ws)
}

cascade_delete_child_assets_with_workspace :: proc(
	ws: ^Workspace_State,
	workspace_id: string,
	conv_id: pr.ConversationID,
	parent_asset_id: pr.AssetID,
) -> bool {
	if ws == nil {
		return true
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return true
	}

	assets_to_delete := make([dynamic]pr.AssetID, 0, 16)
	defer delete(assets_to_delete)
	collect_child_asset_delete_ids(conv, parent_asset_id, &assets_to_delete)

	edges_to_delete: Edge_Delete_Plan
	edge_delete_plan_init(&edges_to_delete)
	defer edge_delete_plan_destroy(&edges_to_delete)
	for asset_id in assets_to_delete {
		collect_edges_for_entity_delete(conv, &edges_to_delete, pr.TargetType.Asset, u64(asset_id))
	}

	if td.shard_writers.mode == .Active {
		workspace := transmute([]byte)workspace_id
		writer := shard_writer_for_workspace(&td.shard_writers, workspace)
		if writer == nil do return false
		cascade, built := build_shard_asset_delete_transaction(workspace, conv_id, assets_to_delete[:], edges_to_delete.edge_ids[:], nil, writer.floors)
		if !built do return false
		defer destroy_shard_asset_delete_transaction(&cascade)
		if !append_shard_transaction(writer, &cascade.tx) do return false
		for edge_id in edges_to_delete.edge_ids do apply_edge_delete_id(conv, ws, conv_id, edge_id, net.TCP_Socket(-1))
		for asset_id in assets_to_delete do apply_asset_delete_id(conv, ws, conv_id, asset_id)
		return true
	}

	if !persist_and_apply_edge_delete_plan(workspace_id, conv, ws, conv_id, &edges_to_delete, net.TCP_Socket(-1)) do return false
	if !persist_and_apply_asset_delete_ids(workspace_id, conv, ws, conv_id, assets_to_delete[:]) do return false
	return true
}

cascade_delete_child_assets :: proc {
	cascade_delete_child_assets_by_id,
	cascade_delete_child_assets_with_workspace,
}

// ============================================================================
// Get Asset (fetch full payload)
// ============================================================================

handle_get_asset :: proc(c: ^NRC_Connection, req: pr.GetAssetRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_error_response(c, .C_GetAsset, "Workspace not found", req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_error_response(c, .C_GetAsset, "Conversation not found", req.correlation_id)
		return
	}

	asset := conv.assets[req.asset_id]
	if asset == nil {
		log.warnf("[T%d] Asset %d not found for get", td.thread_index, req.asset_id)
		send_error_response(c, .C_GetAsset, "Asset not found", req.correlation_id)
		return
	}

	// Send full asset to requester
	send_asset_full(c, asset^, req.correlation_id)
}

// ============================================================================
// List Assets
// ============================================================================

handle_list_assets :: proc(c: ^NRC_Connection, req: pr.ListAssetsRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_asset_list(c, req.conv_id, nil, req.full_content, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_asset_list(c, req.conv_id, nil, req.full_content, req.correlation_id)
		return
	}

	// Collect assets (optionally filtered by type)
	assets := make([dynamic]pr.Asset, 0, len(conv.assets))
	defer delete(assets)

	for _, asset in conv.assets {
		if asset == nil {
			continue
		}
		if req.filter_by_type && asset.asset_type != req.asset_type {
			continue
		}
		append(&assets, asset^)
	}

	send_asset_list(c, req.conv_id, assets[:], req.full_content, req.correlation_id)
}

DEFAULT_ASSET_PAGE_LIMIT :: u16(50)
MAX_ASSET_PAGE_LIMIT :: u16(250)

is_note_after_cursor_desc :: proc(key: Note_Sort_Key, cursor_updated_at: i64, cursor_asset_id: pr.AssetID) -> bool {
	if key.updated_at < cursor_updated_at {
		return true
	}
	if key.updated_at > cursor_updated_at {
		return false
	}
	return key.asset_id < cursor_asset_id
}

Note_Page_Scope :: enum {
	Global,
	Project,
	Tag,
}

Note_Page_Collection :: struct {
	has_more:               bool,
	next_cursor_updated_at: i64,
	next_cursor_asset_id:   pr.AssetID,
	total_count:            u32,
}

collect_note_page :: proc(
	conv: ^Conversation_State,
	scope: Note_Page_Scope,
	filter: string,
	page_limit: u16,
	has_cursor: bool,
	cursor_updated_at: i64,
	cursor_asset_id: pr.AssetID,
	assets: ^[dynamic]pr.Asset,
) -> Note_Page_Collection {
	result: Note_Page_Collection
	if conv == nil || assets == nil do return result

	if scope == .Global {
		result.total_count = u32(len(conv.note_index_keys))
		it := btree.iter(&conv.note_index)
		defer btree.iter_destroy(&it)
		has_item := false
		if has_cursor {
			cursor_key := Note_Sort_Key {
				updated_at = cursor_updated_at,
				asset_id   = cursor_asset_id,
			}
			has_item = btree.iter_seek(&it, cursor_key)
			if has_item {
				if note_sort_key_compare(cursor_key, btree.item(&it)) <= 0 do has_item = btree.iter_prev(&it)
			} else {
				has_item = btree.iter_last(&it)
			}
		} else {
			has_item = btree.iter_last(&it)
		}

		for has_item {
			key := btree.item(&it)
			if has_cursor && key.asset_id == cursor_asset_id {
				has_item = btree.iter_prev(&it)
				continue
			}
			asset := conv.assets[key.asset_id]
			if asset == nil {
				has_item = btree.iter_prev(&it)
				continue
			}
			if has_cursor && !is_note_after_cursor_desc(key, cursor_updated_at, cursor_asset_id) {
				has_item = btree.iter_prev(&it)
				continue
			}
			if len(assets) < int(page_limit) {
				append(assets, asset^)
				result.next_cursor_updated_at = asset.updated_at
				result.next_cursor_asset_id = asset.asset_id
				has_item = btree.iter_prev(&it)
				continue
			}
			result.has_more = true
			break
		}
	} else {
		index := conv.note_project_assets[filter]
		if scope == .Tag do index = conv.note_tag_assets[filter]
		if index == nil do return result
		result.total_count = u32(btree.count(&index.tree))
		it := btree.iter(&index.tree)
		defer btree.iter_destroy(&it)
		has_item := false
		if has_cursor {
			cursor_key := Note_Sort_Key {
				updated_at = cursor_updated_at,
				asset_id   = cursor_asset_id,
			}
			has_item = btree.iter_seek(&it, cursor_key)
			if has_item {
				if note_sort_key_compare(cursor_key, btree.item(&it)) <= 0 do has_item = btree.iter_prev(&it)
			} else {
				has_item = btree.iter_last(&it)
			}
		} else {
			has_item = btree.iter_last(&it)
		}
		for has_item {
			key := btree.item(&it)
			id := key.asset_id
			has_item = btree.iter_prev(&it)
			if has_cursor && id == cursor_asset_id do continue
			asset := conv.assets[id]
			if asset == nil do continue
			indexed_key, indexed := conv.note_index_keys[id]
			if !indexed || indexed_key != key do continue
			if has_cursor && !is_note_after_cursor_desc(key, cursor_updated_at, cursor_asset_id) do continue
			if len(assets) < int(page_limit) {
				append(assets, asset^)
				result.next_cursor_updated_at = asset.updated_at
				result.next_cursor_asset_id = asset.asset_id
				continue
			}
			result.has_more = true
			break
		}
	}

	if len(assets) == 0 {
		result.next_cursor_updated_at = 0
		result.next_cursor_asset_id = 0
	}
	return result
}

// Non-note assets use the same descending (updated_at, asset_id) cursor as notes.
// Only references are sorted; previews and payloads remain conversation-owned.
collect_typed_asset_page :: proc(conv: ^Conversation_State, req: pr.ListAssetsPagedRequest, limit: u16, assets: ^[dynamic]pr.Asset) -> Note_Page_Collection {
	result: Note_Page_Collection
	candidates := make([dynamic]^pr.Asset, 0, len(conv.assets))
	defer delete(candidates)
	for _, asset in conv.assets {
		if asset == nil || asset.asset_type != req.asset_type do continue
		result.total_count += 1
		if req.has_cursor && !is_note_after_cursor_desc({asset.updated_at, asset.asset_id}, req.cursor_updated_at, req.cursor_asset_id) do continue
		append(&candidates, asset)
	}
	slice.sort_by(candidates[:], proc(a, b: ^pr.Asset) -> bool {
		return a.updated_at > b.updated_at || (a.updated_at == b.updated_at && a.asset_id > b.asset_id)
	})
	for asset in candidates {
		if len(assets) == int(limit) {
			result.has_more = true
			break
		}
		append(assets, asset^)
		result.next_cursor_updated_at = asset.updated_at
		result.next_cursor_asset_id = asset.asset_id
	}
	return result
}

handle_list_assets_paged :: proc(c: ^NRC_Connection, req: pr.ListAssetsPagedRequest) {
	if req.asset_type < min(pr.AssetType) || req.asset_type > max(pr.AssetType) {
		send_error_response(c, .C_ListAssetsPaged, "Invalid asset type", req.correlation_id)
		return
	}

	page_limit := req.limit
	if page_limit == 0 {
		page_limit = DEFAULT_ASSET_PAGE_LIMIT
	}
	if page_limit > MAX_ASSET_PAGE_LIMIT {
		page_limit = MAX_ASSET_PAGE_LIMIT
	}

	ws := get_connection_workspace(c)
	if ws == nil {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	assets := make([dynamic]pr.Asset, 0, int(page_limit))
	defer delete(assets)
	result: Note_Page_Collection
	if req.asset_type == .Note {
		result = collect_note_page(conv, .Global, "", page_limit, req.has_cursor, req.cursor_updated_at, req.cursor_asset_id, &assets)
	} else {
		result = collect_typed_asset_page(conv, req, page_limit, &assets)
	}
	send_asset_list_page(
		c,
		req.conv_id,
		assets[:],
		req.full_content,
		result.has_more,
		result.next_cursor_updated_at,
		result.next_cursor_asset_id,
		result.total_count,
		req.correlation_id,
	)
}

// ============================================================================
// List Assets Paged By Project
// ============================================================================

handle_list_assets_paged_by_project :: proc(c: ^NRC_Connection, req: pr.ListAssetsPagedByProjectRequest) {
	if req.asset_type != .Note {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	page_limit := req.limit
	if page_limit == 0 {
		page_limit = DEFAULT_ASSET_PAGE_LIMIT
	}
	if page_limit > MAX_ASSET_PAGE_LIMIT {
		page_limit = MAX_ASSET_PAGE_LIMIT
	}

	ws := get_connection_workspace(c)
	if ws == nil {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	assets := make([dynamic]pr.Asset, 0, int(page_limit))
	defer delete(assets)
	result := collect_note_page(conv, .Project, req.project, page_limit, req.has_cursor, req.cursor_updated_at, req.cursor_asset_id, &assets)
	send_asset_list_page(
		c,
		req.conv_id,
		assets[:],
		req.full_content,
		result.has_more,
		result.next_cursor_updated_at,
		result.next_cursor_asset_id,
		result.total_count,
		req.correlation_id,
	)
}

// ============================================================================
// List Assets Paged By Tag
// ============================================================================

handle_list_assets_paged_by_tag :: proc(c: ^NRC_Connection, req: pr.ListAssetsPagedByTagRequest) {
	if req.asset_type != .Note {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	page_limit := req.limit
	if page_limit == 0 {
		page_limit = DEFAULT_ASSET_PAGE_LIMIT
	}
	if page_limit > MAX_ASSET_PAGE_LIMIT {
		page_limit = MAX_ASSET_PAGE_LIMIT
	}

	ws := get_connection_workspace(c)
	if ws == nil {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_asset_list_page(c, req.conv_id, nil, req.full_content, false, 0, 0, 0, req.correlation_id)
		return
	}

	assets := make([dynamic]pr.Asset, 0, int(page_limit))
	defer delete(assets)
	result := collect_note_page(conv, .Tag, req.tag, page_limit, req.has_cursor, req.cursor_updated_at, req.cursor_asset_id, &assets)
	send_asset_list_page(
		c,
		req.conv_id,
		assets[:],
		req.full_content,
		result.has_more,
		result.next_cursor_updated_at,
		result.next_cursor_asset_id,
		result.total_count,
		req.correlation_id,
	)
}

// ============================================================================
// List Note Projects
// ============================================================================

handle_list_note_projects :: proc(c: ^NRC_Connection, req: pr.ListNoteProjectsRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_note_project_list(c, req.conv_id, nil, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_note_project_list(c, req.conv_id, nil, req.correlation_id)
		return
	}

	projects := make([dynamic]string, 0, len(conv.note_project_assets))
	defer delete(projects)

	for project, _ in conv.note_project_assets {
		append(&projects, project)
	}

	// Sort alphabetically for consistent dropdown ordering
	slice.sort(projects[:])

	send_note_project_list(c, req.conv_id, projects[:], req.correlation_id)
}

// ============================================================================
// List Note Tags
// ============================================================================

handle_list_note_tags :: proc(c: ^NRC_Connection, req: pr.ListNoteTagsRequest) {
	ws := get_connection_workspace(c)
	if ws == nil {
		send_note_tag_list(c, req.conv_id, nil, req.correlation_id)
		return
	}

	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_note_tag_list(c, req.conv_id, nil, req.correlation_id)
		return
	}

	tags := make([dynamic]string, 0, len(conv.note_tag_assets))
	defer delete(tags)

	for tag, _ in conv.note_tag_assets {
		append(&tags, tag)
	}

	slice.sort(tags[:])

	send_note_tag_list(c, req.conv_id, tags[:], req.correlation_id)
}

// ============================================================================
// Response Senders
// ============================================================================

send_asset_created :: proc(c: ^NRC_Connection, asset: pr.Asset, correlation_id: u32 = 0) {
	msg := pr.AssetCreatedMessage {
		asset          = asset,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeAssetCreatedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset created")
	if buf == nil do return

	protocol_len := pr.serializeAssetCreatedMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize AssetCreated for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_asset_updated :: proc(c: ^NRC_Connection, asset: pr.Asset, correlation_id: u32 = 0) {
	msg := pr.AssetUpdatedMessage {
		asset          = asset,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeAssetUpdatedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset updated")
	if buf == nil do return

	protocol_len := pr.serializeAssetUpdatedMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize AssetUpdated for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_asset_deleted :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, asset_id: pr.AssetID, correlation_id: u32 = 0) {
	msg := pr.AssetDeletedMessage {
		conv_id        = conv_id,
		asset_id       = asset_id,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeAssetDeletedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset deleted")
	if buf == nil do return

	protocol_len := pr.serializeAssetDeletedMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize AssetDeleted for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_asset_full :: proc(c: ^NRC_Connection, asset: pr.Asset, correlation_id: u32 = 0) {
	msg := pr.AssetFullMessage {
		asset          = asset,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeAssetFullMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset full")
	if buf == nil do return

	protocol_len := pr.serializeAssetFullMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize AssetFull for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_asset_list :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, assets: []pr.Asset, full_content: bool, correlation_id: u32 = 0) {
	msg := pr.AssetListMessage {
		conv_id        = conv_id,
		assets         = assets,
		full_content   = full_content,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeAssetListMessage(msg)
	if protocol_size > MAX_PROTOCOL_PAYLOAD_SIZE {
		send_error_response(c, .C_ListAssets, "Asset list too large; use ListAssetsPaged", correlation_id)
		return
	}
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset list")
	if buf == nil do return

	protocol_len := pr.serializeAssetListMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize AssetList for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

// Keep the cursor on the last serialized record when the byte budget, rather
// than the item limit, cuts a page short. Legal individual assets fit this budget.
bound_asset_list_page :: proc(msg: ^pr.AssetListPageMessage) {
	size := pr.getSizeAssetListPageMessage(pr.AssetListPageMessage{})
	for asset, i in msg.assets {
		item_size := pr.getSizeAsset(asset) if msg.full_content else pr.getSizeAssetHeader(asset)
		if size + item_size > MAX_PROTOCOL_PAYLOAD_SIZE {
			msg.assets = msg.assets[:i]
			msg.has_more = true
			if i > 0 {
				last := msg.assets[i - 1]
				msg.next_cursor_updated_at = last.updated_at
				msg.next_cursor_asset_id = last.asset_id
			}
			return
		}
		size += item_size
	}
}

send_asset_list_page :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	assets: []pr.Asset,
	full_content: bool,
	has_more: bool,
	next_cursor_updated_at: i64,
	next_cursor_asset_id: pr.AssetID,
	total_count: u32,
	correlation_id: u32 = 0,
) {
	msg := pr.AssetListPageMessage {
		conv_id                = conv_id,
		assets                 = assets,
		full_content           = full_content,
		has_more               = has_more,
		next_cursor_updated_at = next_cursor_updated_at,
		next_cursor_asset_id   = next_cursor_asset_id,
		total_count            = total_count,
		correlation_id         = correlation_id,
	}

	bound_asset_list_page(&msg)
	if len(assets) > 0 && len(msg.assets) == 0 {
		send_error_response(c, .C_ListAssetsPaged, "Asset exceeds page byte limit", correlation_id)
		return
	}
	protocol_size := pr.getSizeAssetListPageMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset list page")
	if buf == nil do return

	protocol_len := pr.serializeAssetListPageMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize AssetListPage for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_note_project_list :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, projects: []string, correlation_id: u32 = 0) {
	msg := pr.NoteProjectListMessage {
		conv_id        = conv_id,
		projects       = projects,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeNoteProjectListMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "note project list")
	if buf == nil do return

	protocol_len := pr.serializeNoteProjectListMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize NoteProjectList for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_note_tag_list :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, tags: []string, correlation_id: u32 = 0) {
	msg := pr.NoteTagListMessage {
		conv_id        = conv_id,
		tags           = tags,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeNoteTagListMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "note tag list")
	if buf == nil do return

	protocol_len := pr.serializeNoteTagListMessage(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize NoteTagList for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

// ============================================================================
// Broadcast Helpers
// ============================================================================

broadcast_asset_created_by_id :: proc(asset: pr.Asset, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_asset_created_with_workspace(asset, excluded_sock, get_workspace(workspace_id))
}

broadcast_asset_created_with_workspace :: proc(asset: pr.Asset, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, asset.conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	// Create shared buffer
	msg := pr.AssetCreatedMessage {
		asset = asset,
	}
	shared_buf := create_shared_asset_created_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_asset_created :: proc {
	broadcast_asset_created_by_id,
	broadcast_asset_created_with_workspace,
}

broadcast_asset_updated_by_id :: proc(asset: pr.Asset, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_asset_updated_with_workspace(asset, excluded_sock, get_workspace(workspace_id))
}

broadcast_asset_updated_with_workspace :: proc(asset: pr.Asset, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, asset.conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	msg := pr.AssetUpdatedMessage {
		asset = asset,
	}
	shared_buf := create_shared_asset_updated_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_asset_updated :: proc {
	broadcast_asset_updated_by_id,
	broadcast_asset_updated_with_workspace,
}

broadcast_asset_deleted_to_room_by_id :: proc(conv_id: pr.ConversationID, asset_id: pr.AssetID, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_asset_deleted_to_room_with_workspace(conv_id, asset_id, excluded_sock, get_workspace(workspace_id))
}

broadcast_asset_deleted_to_room_with_workspace :: proc(conv_id: pr.ConversationID, asset_id: pr.AssetID, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	msg := pr.AssetDeletedMessage {
		conv_id  = conv_id,
		asset_id = asset_id,
	}
	shared_buf := create_shared_asset_deleted_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_asset_deleted_to_room :: proc {
	broadcast_asset_deleted_to_room_by_id,
	broadcast_asset_deleted_to_room_with_workspace,
}

// ============================================================================
// Shared Buffer Creation (for broadcasts)
// ============================================================================

create_shared_asset_created_buffer :: proc(msg: pr.AssetCreatedMessage) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeAssetCreatedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset created broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeAssetCreatedMessage(msg, buf[header_len:])
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

create_shared_asset_updated_buffer :: proc(msg: pr.AssetUpdatedMessage) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeAssetUpdatedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset updated broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeAssetUpdatedMessage(msg, buf[header_len:])
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

create_shared_asset_deleted_buffer :: proc(msg: pr.AssetDeletedMessage) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeAssetDeletedMessage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "asset deleted broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeAssetDeletedMessage(msg, buf[header_len:])
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
