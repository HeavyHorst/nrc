//
// asset_handlers.odin - Asset Response and Broadcast Helpers
//
// Workspace record commands and queries are handled by SQLite.
// Assets are generic, frontend-defined entities with opaque preview/payload.
//
package main

import "core:log"
import "core:net"

import "byte_pool"
import pr "protocol"

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

	asset_copy := asset
	owner := reminder_is_personal(&asset_copy) ? string(asset.owner) : ""
	send_shared_to_subscriber_entries(conv, excluded_sock, shared_buf, personal_owner = owner)
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

	asset_copy := asset
	owner := reminder_is_personal(&asset_copy) ? string(asset.owner) : ""
	send_shared_to_subscriber_entries(conv, excluded_sock, shared_buf, personal_owner = owner)
}

broadcast_asset_updated :: proc {
	broadcast_asset_updated_by_id,
	broadcast_asset_updated_with_workspace,
}

broadcast_asset_deleted_to_room_by_id :: proc(
	conv_id: pr.ConversationID,
	asset_id: pr.AssetID,
	excluded_sock: net.TCP_Socket,
	workspace_id: string,
	personal_owner := "",
) {
	broadcast_asset_deleted_to_room_with_workspace(conv_id, asset_id, excluded_sock, get_workspace(workspace_id), personal_owner)
}

broadcast_asset_deleted_to_room_with_workspace :: proc(
	conv_id: pr.ConversationID,
	asset_id: pr.AssetID,
	excluded_sock: net.TCP_Socket,
	ws: ^Workspace_State,
	personal_owner := "",
) {
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

	send_shared_to_subscriber_entries(conv, excluded_sock, shared_buf, personal_owner = personal_owner)
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
