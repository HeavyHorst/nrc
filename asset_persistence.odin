//
// asset_persistence.odin - Asset Persistence Layer
//
// This file implements persistence for generic assets using the WAL infrastructure.
// Each worker thread maintains its own log file, matching the thread-per-core model.
//
// Assets use a fixed-order format (like agenda, not tagged like tasks):
// v1: workspace_id, asset_type, asset_id, parent_type, parent_id, owner,
//     created_at, updated_at, conv_id, preview, payload
// v2: workspace_id, asset_type, asset_id, parent_type, parent_id, owner,
//     created_at, updated_at, conv_id, payload_encoding, payload_raw_len,
//     preview, payload
//
// Design philosophy: Server stores opaque payloads; frontend owns the schema.
//
package main

import "core:encoding/endian"
import "core:log"
import "core:mem"
import "core:net"

import "persistence"
import pr "protocol"

// ============================================================================
// Constants
// ============================================================================

ASSET_LOG_MAGIC :: 0x4E524353 // "NRCS" (NRC asSets)
ASSET_LOG_VERSION :: u16(3)
// Maximum asset record size for stack allocation (zero-alloc write path).
// Calculation:
//   Header:           48  (LOG_HEADER_SIZE)
//   workspace:       130  (2 + 128)
//   asset_type:        2  (u16)
//   asset_id:          8  (u64)
//   parent_type:       2  (u16)
//   parent_id:         8  (u64)
//   owner:            66  (2 + 64)
//   created_at:        8  (i64)
//   updated_at:        8  (i64)
//   conv_id:           8  (u64)
//   preview:        4098  (2 + 4096)
//   payload:       65538  (2 + 65536)
// Total: 48 + 130 + 2 + 8 + 2 + 8 + 66 + 8 + 8 + 8 + 4098 + 65538 = 69,924 bytes
// Rounded to 72KB for safety
ASSET_MAX_RECORD_SIZE :: 72 * 1024

// ============================================================================
// Types
// ============================================================================

Asset_Log_Op :: enum u8 {
	Create = 1,
	Update = 2,
	Delete = 3,
}

// ============================================================================
// Write Path
// ============================================================================

persist_asset_created :: proc(workspace_id: string, asset: ^pr.Asset) -> bool {
	return persist_shard_asset_mutation(workspace_id, .Create, asset)
}

persist_asset_updated :: proc(workspace_id: string, asset: ^pr.Asset) -> bool {
	return persist_shard_asset_mutation(workspace_id, .Update, asset)
}

persist_asset_deleted :: proc(workspace_id: string, conv_id: pr.ConversationID, asset_id: pr.AssetID) -> bool {
	return persist_shard_asset_delete_mutation(workspace_id, conv_id, asset_id)
}

persist_asset_deleted_kernel_accepted :: proc(workspace_id: string, conv_id: pr.ConversationID, asset_id: pr.AssetID) -> bool {
	if !persist_asset_deleted(workspace_id, conv_id, asset_id) {
		return false
	}
	return true
}

asset_persistence_lengths_supported :: proc(asset: ^pr.Asset) -> bool {
	if asset == nil {
		return false
	}
	return(
		len(asset.owner) <= int(max(u16)) &&
		len(asset.preview) <= int(max(u16)) &&
		len(asset.payload) <= int(max(u16)) &&
		pr.validateAssetAttachments(asset.attachments) \
	)
}

calculate_asset_payload_size :: proc(workspace_id: string, asset: ^pr.Asset) -> int {
	return 2 + len(workspace_id) + calculate_asset_fields_size(asset)
}

calculate_asset_fields_size :: proc(asset: ^pr.Asset) -> int {
	return(
		2 +
		8 +
		2 +
		8 +
		2 +
		len(asset.owner) +
		8 +
		8 +
		8 +
		1 +
		4 +
		2 +
		len(asset.preview) +
		2 +
		len(asset.payload) +
		pr.getSizeAssetAttachments(asset.attachments) \
	) // asset_type// asset_id// parent_type// parent_id// owner// created_at// updated_at// conv_id// payload_encoding// payload_raw_len// preview// payload// attachments
}

serialize_asset_to_record :: proc(record: []byte, workspace_id: string, asset: ^pr.Asset) {
	payload := record[persistence.LOG_HEADER_SIZE:]
	offset := persistence.write_workspace_prefix(payload, workspace_id)
	offset += serialize_asset_fields(payload[offset:], asset)
	assert(offset == len(payload))
}

serialize_asset_fields :: proc(payload: []byte, asset: ^pr.Asset) -> int {
	offset := 0

	endian.put_u16(payload[offset:], .Big, u16(asset.asset_type))
	offset += 2

	endian.put_u64(payload[offset:], .Big, u64(asset.asset_id))
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(asset.parent_type))
	offset += 2

	endian.put_u64(payload[offset:], .Big, asset.parent_id)
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(len(asset.owner)))
	offset += 2
	if len(asset.owner) > 0 {
		copy(payload[offset:], asset.owner)
		offset += len(asset.owner)
	}

	endian.put_u64(payload[offset:], .Big, cast(u64)asset.created_at)
	offset += 8

	endian.put_u64(payload[offset:], .Big, cast(u64)asset.updated_at)
	offset += 8

	endian.put_u64(payload[offset:], .Big, u64(asset.conv_id))
	offset += 8

	payload_encoding := asset.payload_encoding
	payload_raw_len := asset.payload_raw_len
	if payload_raw_len == 0 {
		payload_raw_len = u32(len(asset.payload))
	}

	payload[offset] = u8(payload_encoding)
	offset += 1

	endian.put_u32(payload[offset:], .Big, payload_raw_len)
	offset += 4

	endian.put_u16(payload[offset:], .Big, u16(len(asset.preview)))
	offset += 2
	if len(asset.preview) > 0 {
		copy(payload[offset:], asset.preview)
		offset += len(asset.preview)
	}

	endian.put_u16(payload[offset:], .Big, u16(len(asset.payload)))
	offset += 2
	if len(asset.payload) > 0 {
		copy(payload[offset:], asset.payload)
		offset += len(asset.payload)
	}

	offset += pr.serializeAssetAttachments(asset.attachments, payload[offset:])
	return offset
}

// ============================================================================
// Read Path (Replay)
// ============================================================================

apply_asset_log_record :: proc(op: Asset_Log_Op, version: u16, payload: []byte) -> (asset_id: u64) {
	workspace_id, offset, ok := persistence.parse_workspace_prefix(payload)
	if !ok {
		return 0
	}
	return apply_asset_log_record_for_workspace(workspace_id, op, version, payload[offset:])
}

apply_asset_log_record_for_workspace :: proc(workspace_id: string, op: Asset_Log_Op, version: u16, payload: []byte) -> (asset_id: u64) {
	#partial switch op {
	case .Create, .Update:
		parsed, parse_ok := parse_asset_from_payload(payload, 0, version)
		if !parse_ok {
			return 0
		}
		parsed.conv_id = workspace_data_replay_scope(parsed.conv_id)
		if !apply_persisted_asset(workspace_id, &parsed) do return 0
		return u64(parsed.asset_id)

	case .Delete:
		if len(payload) < 16 {
			return 0
		}
		conv_id, _ := endian.get_u64(payload, .Big)
		id, _ := endian.get_u64(payload[8:], .Big)
		apply_persisted_asset_delete(workspace_id, workspace_data_replay_scope(pr.ConversationID(conv_id)), pr.AssetID(id))
		return id
	}

	return 0
}

Parsed_Asset_Data :: struct {
	asset_type:       pr.AssetType,
	asset_id:         pr.AssetID,
	parent_type:      pr.ParentType,
	parent_id:        u64,
	owner:            []byte,
	created_at:       i64,
	updated_at:       i64,
	conv_id:          pr.ConversationID,
	payload_encoding: pr.PayloadEncoding,
	payload_raw_len:  u32,
	preview:          []byte,
	payload:          []byte,
	attachments:      [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment,
	attachment_count: int,
}

parse_asset_from_payload :: proc(payload: []byte, start_offset: int, version: u16) -> (Parsed_Asset_Data, bool) {
	parsed := Parsed_Asset_Data{}
	offset := start_offset

	// asset_type
	if len(payload) < offset + 2 {
		return parsed, false
	}
	asset_type, _ := endian.get_u16(payload[offset:], .Big)
	parsed.asset_type = pr.AssetType(asset_type)
	offset += 2

	// asset_id
	if len(payload) < offset + 8 {
		return parsed, false
	}
	asset_id, _ := endian.get_u64(payload[offset:], .Big)
	parsed.asset_id = pr.AssetID(asset_id)
	offset += 8

	// parent_type
	if len(payload) < offset + 2 {
		return parsed, false
	}
	parent_type, _ := endian.get_u16(payload[offset:], .Big)
	parsed.parent_type = pr.ParentType(parent_type)
	offset += 2

	// parent_id
	if len(payload) < offset + 8 {
		return parsed, false
	}
	parsed.parent_id, _ = endian.get_u64(payload[offset:], .Big)
	offset += 8

	// owner
	if len(payload) < offset + 2 {
		return parsed, false
	}
	owner_len, _ := endian.get_u16(payload[offset:], .Big)
	offset += 2
	if len(payload) < offset + int(owner_len) {
		return parsed, false
	}
	parsed.owner = payload[offset:][:owner_len]
	offset += int(owner_len)

	// created_at
	if len(payload) < offset + 8 {
		return parsed, false
	}
	created_at_u64, _ := endian.get_u64(payload[offset:], .Big)
	parsed.created_at = cast(i64)created_at_u64
	offset += 8

	// updated_at
	if len(payload) < offset + 8 {
		return parsed, false
	}
	updated_at_u64, _ := endian.get_u64(payload[offset:], .Big)
	parsed.updated_at = cast(i64)updated_at_u64
	offset += 8

	// conv_id
	if len(payload) < offset + 8 {
		return parsed, false
	}
	conv_id, _ := endian.get_u64(payload[offset:], .Big)
	parsed.conv_id = pr.ConversationID(conv_id)
	offset += 8

	if version >= 2 {
		if len(payload) < offset + 1 + 4 {
			return parsed, false
		}
		parsed.payload_encoding = pr.PayloadEncoding(payload[offset])
		offset += 1

		parsed.payload_raw_len, _ = endian.get_u32(payload[offset:], .Big)
		offset += 4
	} else {
		parsed.payload_encoding = .Plain
		parsed.payload_raw_len = 0
	}

	// preview
	if len(payload) < offset + 2 {
		return parsed, false
	}
	preview_len, _ := endian.get_u16(payload[offset:], .Big)
	offset += 2
	if len(payload) < offset + int(preview_len) {
		return parsed, false
	}
	parsed.preview = payload[offset:][:preview_len]
	offset += int(preview_len)

	// payload
	if len(payload) < offset + 2 {
		return parsed, false
	}
	payload_len, _ := endian.get_u16(payload[offset:], .Big)
	offset += 2
	if len(payload) < offset + int(payload_len) {
		return parsed, false
	}
	parsed.payload = payload[offset:][:payload_len]
	offset += int(payload_len)

	if version >= 3 {
		attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		att_slice, new_offset, att_err := pr.parseAssetAttachmentsFromPayload(payload, offset, attachments[:])
		if att_err != nil do return parsed, false
		parsed.attachments = attachments
		parsed.attachment_count = len(att_slice)
		offset = new_offset
	}

	if parsed.payload_raw_len == 0 {
		parsed.payload_raw_len = u32(len(parsed.payload))
	}

	return parsed, true
}

// ============================================================================
// Apply Helpers (Map-only, no network side effects)
// ============================================================================

apply_persisted_asset :: proc(workspace_id: string, parsed: ^Parsed_Asset_Data) -> bool {
	ws := get_or_create_workspace(workspace_id)
	conv := get_or_create_conversation(ws, parsed.conv_id)

	// Allocate new asset
	new_asset := alloc_asset(parsed.owner, parsed.preview, parsed.payload, parsed.attachments[:parsed.attachment_count])
	if new_asset == nil {
		log.errorf("[T%d] Failed to allocate asset", td.thread_index)
		return false
	}

	new_asset.asset_type = parsed.asset_type
	new_asset.asset_id = parsed.asset_id
	new_asset.parent_type = parsed.parent_type
	new_asset.parent_id = parsed.parent_id
	new_asset.created_at = parsed.created_at
	new_asset.updated_at = parsed.updated_at
	new_asset.conv_id = parsed.conv_id
	new_asset.payload_encoding = parsed.payload_encoding
	new_asset.payload_raw_len = parsed.payload_raw_len

	asset_store_put(ws, workspace_id, conv, new_asset)
	return true
}

apply_persisted_asset_delete :: proc(workspace_id: string, conv_id: pr.ConversationID, asset_id: pr.AssetID) {
	ws := get_workspace(workspace_id)
	if ws == nil {
		return
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return
	}

	asset_store_remove(ws, conv, asset_id)
}

// ============================================================================
// Asset Allocation (Single-Alloc Pattern)
// ============================================================================

alloc_asset :: proc {
	alloc_asset_no_attachments,
	alloc_asset_with_attachments,
}

alloc_asset_no_attachments :: proc(owner: []byte, preview: []byte, payload: []byte) -> ^pr.Asset {
	return alloc_asset_with_attachments(owner, preview, payload, nil)
}

alloc_asset_with_attachments :: proc(owner: []byte, preview: []byte, payload: []byte, attachments: []pr.Attachment) -> ^pr.Asset {
	attachments_size := size_of(pr.Attachment) * len(attachments)
	attachment_strings_size := 0
	for att in attachments {
		attachment_strings_size += len(att.file_id) + len(att.filename) + len(att.mime_type)
	}
	attachment_alignment_padding := align_of(pr.Attachment) - 1 if len(attachments) > 0 else 0
	total_size := size_of(pr.Asset) + len(owner) + len(preview) + len(payload) + attachment_alignment_padding + attachments_size + attachment_strings_size
	block, err := mem.alloc_bytes(total_size)
	if err != nil {
		return nil
	}

	asset := (^pr.Asset)(raw_data(block))
	trailing := block[size_of(pr.Asset):]

	// Copy owner
	offset := 0
	if len(owner) > 0 {
		copy(trailing[offset:], owner)
		asset.owner = trailing[offset:][:len(owner)]
		offset += len(owner)
	}

	// Copy preview
	if len(preview) > 0 {
		copy(trailing[offset:], preview)
		asset.preview = trailing[offset:][:len(preview)]
		offset += len(preview)
	}

	// Copy payload
	if len(payload) > 0 {
		copy(trailing[offset:], payload)
		asset.payload = trailing[offset:][:len(payload)]
		offset += len(payload)
	}

	if len(attachments) > 0 {
		offset = mem.align_forward_int(offset, align_of(pr.Attachment))
		asset.attachments = transmute([]pr.Attachment)mem.Raw_Slice{raw_data(trailing[offset:]), len(attachments)}
		offset += attachments_size

		for i := 0; i < len(attachments); i += 1 {
			src := &attachments[i]
			dst := &asset.attachments[i]
			dst.size = src.size
			dst.uploaded_at = src.uploaded_at
			if len(src.file_id) > 0 {
				copy(trailing[offset:], src.file_id)
				dst.file_id = trailing[offset:][:len(src.file_id)]
				offset += len(src.file_id)
			}
			if len(src.filename) > 0 {
				copy(trailing[offset:], src.filename)
				dst.filename = trailing[offset:][:len(src.filename)]
				offset += len(src.filename)
			}
			if len(src.mime_type) > 0 {
				copy(trailing[offset:], src.mime_type)
				dst.mime_type = trailing[offset:][:len(src.mime_type)]
				offset += len(src.mime_type)
			}
		}
	}

	return asset
}

free_asset :: proc(asset: ^pr.Asset) {
	if asset != nil {
		free(asset)
	}
}

// ============================================================================
// Cascade Delete
// ============================================================================

// cascade_delete_assets_for_task deletes all assets that have parent_type=TASK
// and parent_id=task_id. Called when a task is deleted.
cascade_delete_assets_for_task_by_id :: proc(workspace_id: string, conv_id: pr.ConversationID, task_id: pr.TaskID) -> bool {
	return cascade_delete_assets_for_task_with_workspace(get_workspace(workspace_id), workspace_id, conv_id, task_id)
}

cascade_delete_assets_for_task_with_workspace :: proc(ws: ^Workspace_State, workspace_id: string, conv_id: pr.ConversationID, task_id: pr.TaskID) -> bool {
	if ws == nil {
		return true
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return true
	}

	assets_to_delete := make([dynamic]pr.AssetID, 0, 16)
	defer delete(assets_to_delete)
	collect_task_asset_delete_ids(conv, task_id, &assets_to_delete)

	edges_to_delete: Edge_Delete_Plan
	edge_delete_plan_init(&edges_to_delete)
	defer edge_delete_plan_destroy(&edges_to_delete)
	for asset_id in assets_to_delete {
		collect_edges_for_entity_delete(conv, &edges_to_delete, pr.TargetType.Asset, u64(asset_id))
	}

	if !persist_and_apply_edge_delete_plan(workspace_id, conv, ws, conv_id, &edges_to_delete, net.TCP_Socket(-1)) do return false
	if !persist_and_apply_asset_delete_ids(workspace_id, conv, ws, conv_id, assets_to_delete[:]) do return false

	if len(assets_to_delete) > 0 {
		log.infof("[T%d] Cascade deleted %d task-root assets (plus descendants) for task %d", td.thread_index, len(assets_to_delete), task_id)
	}
	return true
}

cascade_delete_assets_for_task :: proc {
	cascade_delete_assets_for_task_by_id,
	cascade_delete_assets_for_task_with_workspace,
}
