//
// edge_persistence.odin - Edge/Knowledge Graph Persistence Layer
//
// This file implements persistence for edges using the WAL infrastructure.
// Each worker thread maintains its own log file, matching the thread-per-core model.
//
// Edges use a fixed-order format:
//   workspace_id, edge_id, conv_id, source_type, source_id, target_type, target_id,
//   relation, created_at, created_by
//
package main

import "core:encoding/endian"
import "core:log"

import "persistence"
import pr "protocol"

// ============================================================================
// Constants
// ============================================================================

EDGE_LOG_MAGIC :: 0x4E524345 // "NRCE" (NRC Edges)
EDGE_LOG_VERSION :: u16(1)
// Maximum edge record size for stack allocation.
// Calculation:
//   Header:          48  (LOG_HEADER_SIZE)
//   workspace:      130  (2 + 128)
//   edge_id:          8  (u64)
//   conv_id:          8  (u64)
//   source_type:      2  (u16)
//   source_id:        8  (u64)
//   target_type:      2  (u16)
//   target_id:        8  (u64)
//   relation:         2  (u16)
//   created_at:       8  (i64)
//   created_by:      66  (2 + 64)
// Total: 48 + 130 + 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 66 = 290 bytes
// Rounded to 512 for safety
EDGE_MAX_RECORD_SIZE :: 512

// ============================================================================
// Types
// ============================================================================

Edge_Log_Op :: enum u8 {
	Create = 1,
	Delete = 2,
}

@(thread_local)
edge_replay_max_task_ref_id: u64

@(thread_local)
edge_replay_max_asset_ref_id: u64

// ============================================================================
// Write Path
// ============================================================================

persist_edge_created :: proc(workspace_id: string, edge: ^pr.Edge) -> bool {
	return persist_shard_edge_mutation(workspace_id, .Create, edge)
}

persist_edge_deleted :: proc(workspace_id: string, conv_id: pr.ConversationID, edge_id: pr.EdgeID) -> bool {
	return persist_shard_edge_delete_mutation(workspace_id, conv_id, edge_id)
}

persist_edge_deleted_kernel_accepted :: proc(workspace_id: string, conv_id: pr.ConversationID, edge_id: pr.EdgeID) -> bool {
	if !persist_edge_deleted(workspace_id, conv_id, edge_id) {
		return false
	}
	return true
}

calculate_edge_payload_size :: proc(workspace_id: string, edge: ^pr.Edge) -> int {
	// workspace_id(2+len) + edge_id(8) + conv_id(8) + source_type(2) + source_id(8) +
	// target_type(2) + target_id(8) + relation(2) + created_at(8) + created_by(2+len)
	return 2 + len(workspace_id) + 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + len(edge.created_by)
}

serialize_edge_to_record :: proc(record: []byte, workspace_id: string, edge: ^pr.Edge) {
	payload := record[persistence.LOG_HEADER_SIZE:]
	offset := persistence.write_workspace_prefix(payload, workspace_id)

	endian.put_u64(payload[offset:], .Big, u64(edge.edge_id))
	offset += 8

	endian.put_u64(payload[offset:], .Big, u64(edge.conv_id))
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(edge.source_type))
	offset += 2

	endian.put_u64(payload[offset:], .Big, edge.source_id)
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(edge.target_type))
	offset += 2

	endian.put_u64(payload[offset:], .Big, edge.target_id)
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(edge.relation))
	offset += 2

	endian.put_u64(payload[offset:], .Big, cast(u64)edge.created_at)
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(len(edge.created_by)))
	offset += 2
	if len(edge.created_by) > 0 {
		copy(payload[offset:], edge.created_by)
	}
}

// ============================================================================
// Read Path (Replay)
// ============================================================================

note_edge_replay_entity_ref :: proc(target_type: pr.TargetType, target_id: u64) {
	switch target_type {
	case .Task:
		if target_id > edge_replay_max_task_ref_id do edge_replay_max_task_ref_id = target_id
	case .Asset:
		if target_id > edge_replay_max_asset_ref_id do edge_replay_max_asset_ref_id = target_id
	case:
	}
}

edge_replay_referenced_high_water :: proc() -> (task_id, asset_id: u64) {
	return edge_replay_max_task_ref_id, edge_replay_max_asset_ref_id
}

reconcile_edge_replay_referenced_high_water :: proc() {
	if edge_replay_max_task_ref_id > td.task_seq {
		td.task_seq = edge_replay_max_task_ref_id
	}
	if edge_replay_max_asset_ref_id > td.asset_seq {
		td.asset_seq = edge_replay_max_asset_ref_id
	}
}

apply_edge_log_record :: proc(op: Edge_Log_Op, version: u16, payload: []byte) -> (edge_id: u64) {
	_ = version
	workspace_id, offset, ok := persistence.parse_workspace_prefix(payload)
	if !ok {
		return 0
	}
	return apply_edge_log_record_for_workspace(workspace_id, op, payload[offset:])
}

apply_edge_log_record_for_workspace :: proc(workspace_id: string, op: Edge_Log_Op, payload: []byte) -> (edge_id: u64) {
	#partial switch op {
	case .Create:
		parsed, parse_ok := parse_edge_from_payload(payload, 0)
		if !parse_ok {
			return 0
		}
		parsed.conv_id = workspace_data_replay_scope(parsed.conv_id)
		note_edge_replay_entity_ref(parsed.source_type, parsed.source_id)
		note_edge_replay_entity_ref(parsed.target_type, parsed.target_id)
		if !apply_persisted_edge(workspace_id, &parsed) do return 0
		return u64(parsed.edge_id)

	case .Delete:
		if len(payload) < 16 {
			return 0
		}
		conv_id, _ := endian.get_u64(payload, .Big)
		id, _ := endian.get_u64(payload[8:], .Big)
		apply_persisted_edge_delete(workspace_id, workspace_data_replay_scope(pr.ConversationID(conv_id)), pr.EdgeID(id))
		return id
	}

	return 0
}

Parsed_Edge_Data :: struct {
	edge_id:     pr.EdgeID,
	conv_id:     pr.ConversationID,
	source_type: pr.TargetType,
	source_id:   u64,
	target_type: pr.TargetType,
	target_id:   u64,
	relation:    pr.RelationType,
	created_at:  i64,
	created_by:  []byte,
}

parse_edge_from_payload :: proc(payload: []byte, start_offset: int) -> (Parsed_Edge_Data, bool) {
	parsed := Parsed_Edge_Data{}
	offset := start_offset

	// edge_id
	if len(payload) < offset + 8 {
		return parsed, false
	}
	edge_id, _ := endian.get_u64(payload[offset:], .Big)
	parsed.edge_id = pr.EdgeID(edge_id)
	offset += 8

	// conv_id
	if len(payload) < offset + 8 {
		return parsed, false
	}
	conv_id, _ := endian.get_u64(payload[offset:], .Big)
	parsed.conv_id = pr.ConversationID(conv_id)
	offset += 8

	// source_type
	if len(payload) < offset + 2 {
		return parsed, false
	}
	source_type, _ := endian.get_u16(payload[offset:], .Big)
	parsed.source_type = pr.TargetType(source_type)
	offset += 2

	// source_id
	if len(payload) < offset + 8 {
		return parsed, false
	}
	parsed.source_id, _ = endian.get_u64(payload[offset:], .Big)
	offset += 8

	// target_type
	if len(payload) < offset + 2 {
		return parsed, false
	}
	target_type, _ := endian.get_u16(payload[offset:], .Big)
	parsed.target_type = pr.TargetType(target_type)
	offset += 2

	// target_id
	if len(payload) < offset + 8 {
		return parsed, false
	}
	parsed.target_id, _ = endian.get_u64(payload[offset:], .Big)
	offset += 8

	// relation
	if len(payload) < offset + 2 {
		return parsed, false
	}
	relation, _ := endian.get_u16(payload[offset:], .Big)
	parsed.relation = pr.RelationType(relation)
	offset += 2

	// created_at
	if len(payload) < offset + 8 {
		return parsed, false
	}
	created_at_u64, _ := endian.get_u64(payload[offset:], .Big)
	parsed.created_at = cast(i64)created_at_u64
	offset += 8

	// created_by
	if len(payload) < offset + 2 {
		return parsed, false
	}
	created_by_len, _ := endian.get_u16(payload[offset:], .Big)
	offset += 2
	if len(payload) < offset + int(created_by_len) {
		return parsed, false
	}
	parsed.created_by = payload[offset:][:created_by_len]

	return parsed, true
}

// ============================================================================
// Apply Helpers (Map-only, no network side effects)
// ============================================================================

apply_persisted_edge :: proc(workspace_id: string, parsed: ^Parsed_Edge_Data) -> bool {
	ws := get_or_create_workspace(workspace_id)
	conv := get_or_create_conversation(ws, parsed.conv_id)

	// Allocate new edge
	new_edge := alloc_edge(parsed.created_by)
	if new_edge == nil {
		log.errorf("[T%d] Failed to allocate edge during replay", td.thread_index)
		return false
	}

	new_edge.edge_id = parsed.edge_id
	new_edge.conv_id = parsed.conv_id
	new_edge.source_type = parsed.source_type
	new_edge.source_id = parsed.source_id
	new_edge.target_type = parsed.target_type
	new_edge.target_id = parsed.target_id
	new_edge.relation = parsed.relation
	new_edge.created_at = parsed.created_at

	edge_store_put(conv, new_edge)
	return true
}

apply_persisted_edge_delete :: proc(workspace_id: string, conv_id: pr.ConversationID, edge_id: pr.EdgeID) {
	ws := get_workspace(workspace_id)
	if ws == nil {
		return
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return
	}

	edge_store_remove(conv, edge_id)
}
