//
// task_persistence.odin - Task Persistence Layer
//
// This file implements persistence for tasks using the generic WAL infrastructure.
// Each worker thread maintains its own log file, matching the thread-per-core model.
//
// Features:
// - Per-thread log files (no cross-thread coordination)
// - Tagged field format for forward/backward compatibility
// - Uses generic WAL for hash-chaining, CRC, and fsync
//
package main

import "core:encoding/endian"
import "core:log"

import "persistence"
import pr "protocol"

// ============================================================================
// Constants
// ============================================================================

TASK_LOG_MAGIC :: 0x4E524354 // "NRCT" (NRC Tasks)
TASK_LOG_VERSION :: u16(1)

// ============================================================================
// Types
// ============================================================================

Task_Log_Op :: enum u8 {
	Create = 1,
	Update = 2,
	Move   = 3,
	Delete = 4,
}

Task_Field_Tag :: enum u8 {
	TaskID      = 1,
	ConvID      = 2,
	Title       = 3,
	Description = 4,
	Status      = 5,
	OrderIndex  = 6,
	Assignee    = 7,
	Priority    = 8,
	CreatedBy   = 9,
	CreatedAt   = 10,
	UpdatedAt   = 11,
	ExternalRef = 12,
	Color       = 13,
	DueAt       = 14,
	BlockedBy   = 15,
	CompletedAt = 16,
	CompletedBy = 17,
	Attachments = 18, // New: array of attachments (count + attachment records)
	Project     = 19,
}

// ============================================================================
// Write Path
// ============================================================================

persistence_workspace_id_supported :: proc(workspace_id: string) -> bool {
	return len(workspace_id) <= int(max(u16))
}

persist_task_created :: proc(workspace_id: string, task: ^pr.Task) -> bool {
	return persist_shard_task_mutation(workspace_id, .Create, task)
}

persist_task_updated :: proc(workspace_id: string, task: ^pr.Task) -> bool {
	return persist_shard_task_mutation(workspace_id, .Update, task)
}

persist_task_moved :: proc(workspace_id: string, task: ^pr.Task) -> bool {
	return persist_shard_task_mutation(workspace_id, .Move, task)
}

persist_task_deleted :: proc(workspace_id: string, conv_id: pr.ConversationID, task_id: pr.TaskID) -> bool {
	return persist_shard_task_delete_mutation(workspace_id, conv_id, task_id)
}

persist_task_deleted_kernel_accepted :: proc(workspace_id: string, conv_id: pr.ConversationID, task_id: pr.TaskID) -> bool {
	if !persist_task_deleted(workspace_id, conv_id, task_id) {
		return false
	}
	return true
}

// ============================================================================
// Tagged Field Serialization
// ============================================================================

task_persistence_lengths_supported :: proc(task: ^pr.Task) -> bool {
	if task == nil {
		return false
	}
	if len(task.title) > int(max(u16)) || len(task.description) > int(max(u16)) || len(task.assignee) > int(max(u16)) {
		return false
	}
	if len(task.created_by) > int(max(u16)) ||
	   len(task.external_ref) > int(max(u16)) ||
	   len(task.completed_by) > int(max(u16)) ||
	   len(task.project) > int(max(u16)) {
		return false
	}
	if len(task.attachments) > int(max(u16)) {
		return false
	}

	attachments_payload_size := 2
	for att in task.attachments {
		if len(att.file_id) > int(max(u16)) || len(att.filename) > int(max(u16)) || len(att.mime_type) > int(max(u16)) {
			return false
		}
		attachments_payload_size += 2 + len(att.file_id) + 2 + len(att.filename) + 8 + 2 + len(att.mime_type) + 8
		if attachments_payload_size > int(max(u16)) {
			return false
		}
	}
	return true
}

calculate_task_fields_size :: proc(task: pr.Task) -> int {
	size := 0

	// Each field: tag(1) + len(2) + data
	size += 1 + 2 + 8 // TaskID
	size += 1 + 2 + 8 // ConvID
	size += 1 + 2 + len(task.title) // Title
	size += 1 + 2 + len(task.description) // Description
	size += 1 + 2 + 1 // Status
	size += 1 + 2 + 2 // OrderIndex
	size += 1 + 2 + len(task.assignee) // Assignee
	size += 1 + 2 + 1 // Priority
	size += 1 + 2 + 1 // Color
	size += 1 + 2 + len(task.created_by) // CreatedBy
	size += 1 + 2 + 8 // CreatedAt
	size += 1 + 2 + 8 // UpdatedAt
	size += 1 + 2 + len(task.external_ref) // ExternalRef
	size += 1 + 2 + 8 // DueAt
	size += 1 + 2 + 8 // BlockedBy
	size += 1 + 2 + 8 // CompletedAt
	size += 1 + 2 + len(task.completed_by) // CompletedBy
	size += 1 + 2 + len(task.project) // Project

	// Attachments: tag(1) + len(2) + count(2) + attachments
	att_payload_size := 2 // attachment count
	for att in task.attachments {
		att_payload_size += 2 + len(att.file_id) // file_id
		att_payload_size += 2 + len(att.filename) // filename
		att_payload_size += 8 // size
		att_payload_size += 2 + len(att.mime_type) // mime_type
		att_payload_size += 8 // uploaded_at
	}
	if len(task.attachments) > 0 {
		size += 1 + 2 + att_payload_size // Attachments
	}

	return size
}

serialize_task_fields :: proc(task: pr.Task, buf: []byte) -> int {
	offset := 0

	offset += write_field_u64(buf[offset:], .TaskID, u64(task.id))
	offset += write_field_u64(buf[offset:], .ConvID, u64(task.conv_id))
	offset += write_field_bytes(buf[offset:], .Title, task.title)
	offset += write_field_bytes(buf[offset:], .Description, task.description)
	offset += write_field_u8(buf[offset:], .Status, u8(task.status))
	offset += write_field_u16(buf[offset:], .OrderIndex, task.order_index)
	offset += write_field_bytes(buf[offset:], .Assignee, task.assignee)
	offset += write_field_u8(buf[offset:], .Priority, task.priority)
	offset += write_field_u8(buf[offset:], .Color, u8(task.color))
	offset += write_field_bytes(buf[offset:], .CreatedBy, task.created_by)
	offset += write_field_i64(buf[offset:], .CreatedAt, task.created_at)
	offset += write_field_i64(buf[offset:], .UpdatedAt, task.updated_at)
	offset += write_field_bytes(buf[offset:], .ExternalRef, task.external_ref)
	offset += write_field_i64(buf[offset:], .DueAt, task.due_at)
	offset += write_field_u64(buf[offset:], .BlockedBy, u64(task.blocked_by))
	offset += write_field_i64(buf[offset:], .CompletedAt, task.completed_at)
	offset += write_field_bytes(buf[offset:], .CompletedBy, task.completed_by)
	offset += write_field_bytes(buf[offset:], .Project, task.project)

	// Serialize attachments if present
	if len(task.attachments) > 0 {
		offset += write_field_attachments(buf[offset:], task.attachments)
	}

	return offset
}

write_field_u8 :: proc(buf: []byte, tag: Task_Field_Tag, value: u8) -> int {
	buf[0] = u8(tag)
	endian.put_u16(buf[1:], .Big, 1)
	buf[3] = value
	return 4
}

write_field_u16 :: proc(buf: []byte, tag: Task_Field_Tag, value: u16) -> int {
	buf[0] = u8(tag)
	endian.put_u16(buf[1:], .Big, 2)
	endian.put_u16(buf[3:], .Big, value)
	return 5
}

write_field_u64 :: proc(buf: []byte, tag: Task_Field_Tag, value: u64) -> int {
	buf[0] = u8(tag)
	endian.put_u16(buf[1:], .Big, 8)
	endian.put_u64(buf[3:], .Big, value)
	return 11
}

write_field_i64 :: proc(buf: []byte, tag: Task_Field_Tag, value: i64) -> int {
	buf[0] = u8(tag)
	endian.put_u16(buf[1:], .Big, 8)
	endian.put_u64(buf[3:], .Big, cast(u64)value)
	return 11
}

write_field_bytes :: proc(buf: []byte, tag: Task_Field_Tag, value: []byte) -> int {
	buf[0] = u8(tag)
	endian.put_u16(buf[1:], .Big, u16(len(value)))
	if len(value) > 0 {
		copy(buf[3:], value)
	}
	return 3 + len(value)
}

write_field_attachments :: proc(buf: []byte, attachments: []pr.Attachment) -> int {
	buf[0] = u8(Task_Field_Tag.Attachments)

	// Calculate payload size
	payload_size := 2 // attachment count
	for att in attachments {
		payload_size += 2 + len(att.file_id)
		payload_size += 2 + len(att.filename)
		payload_size += 8
		payload_size += 2 + len(att.mime_type)
		payload_size += 8
	}

	endian.put_u16(buf[1:], .Big, u16(payload_size))
	offset := 3

	// Write attachment count
	endian.put_u16(buf[offset:], .Big, u16(len(attachments)))
	offset += 2

	// Write each attachment
	for att in attachments {
		endian.put_u16(buf[offset:], .Big, u16(len(att.file_id)))
		offset += 2
		if len(att.file_id) > 0 {
			copy(buf[offset:], att.file_id)
			offset += len(att.file_id)
		}

		endian.put_u16(buf[offset:], .Big, u16(len(att.filename)))
		offset += 2
		if len(att.filename) > 0 {
			copy(buf[offset:], att.filename)
			offset += len(att.filename)
		}

		endian.put_u64(buf[offset:], .Big, att.size)
		offset += 8

		endian.put_u16(buf[offset:], .Big, u16(len(att.mime_type)))
		offset += 2
		if len(att.mime_type) > 0 {
			copy(buf[offset:], att.mime_type)
			offset += len(att.mime_type)
		}

		endian.put_u64(buf[offset:], .Big, cast(u64)att.uploaded_at)
		offset += 8
	}

	return 3 + payload_size
}

// ============================================================================
// Read Path (Replay)
// ============================================================================

apply_task_log_record :: proc(op: Task_Log_Op, version: u16, payload: []byte) -> (task_id: u64) {
	workspace_id, offset, ok := persistence.parse_workspace_prefix(payload)
	if !ok {
		return 0
	}
	return apply_task_log_record_for_workspace(workspace_id, op, version, payload[offset:])
}

apply_task_log_record_for_workspace :: proc(workspace_id: string, op: Task_Log_Op, version: u16, payload: []byte) -> (task_id: u64) {
	#partial switch op {
	case .Create, .Update, .Move:
		parsed, parse_ok := parse_task_fields(payload, version)
		if !parse_ok {
			return 0
		}
		parsed.conv_id = workspace_data_replay_scope(parsed.conv_id)
		if !apply_persisted_task(workspace_id, &parsed) do return 0
		return u64(parsed.id)

	case .Delete:
		if len(payload) < 16 {
			return 0
		}
		conv_id, _ := endian.get_u64(payload, .Big)
		tid, _ := endian.get_u64(payload[8:], .Big)

		apply_persisted_delete(workspace_id, workspace_data_replay_scope(pr.ConversationID(conv_id)), pr.TaskID(tid))
		return tid
	}

	return 0
}

// Parsed task data with slices pointing into source buffer (no allocation)
Parsed_Task_Data :: struct {
	id:               pr.TaskID,
	conv_id:          pr.ConversationID,
	title:            []byte, // Points into source data
	description:      []byte,
	assignee:         []byte,
	created_by:       []byte,
	external_ref:     []byte,
	status:           pr.TaskStatus,
	order_index:      u16,
	priority:         u8,
	color:            pr.TaskColor,
	created_at:       i64,
	updated_at:       i64,
	due_at:           i64,
	blocked_by:       pr.TaskID,
	completed_at:     i64,
	completed_by:     []byte,
	project:          []byte,
	attachments:      [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment, // Fixed array, slices point into source data
	attachment_count: int,
}

// parse_task_fields parses task fields without allocating - slices point into source data
parse_task_fields :: proc(data: []byte, version: u16) -> (parsed: Parsed_Task_Data, ok: bool) {
	offset := 0
	parsed = Parsed_Task_Data{}

	for offset < len(data) {
		if len(data) - offset < 3 {
			return parsed, false
		}
		tag := Task_Field_Tag(data[offset])
		field_len, _ := endian.get_u16(data[offset + 1:], .Big)
		offset += 3

		if int(field_len) > len(data) - offset {
			log.warnf("[T%d] Field extends past end of data", td.thread_index)
			return parsed, false
		}

		field_data := data[offset:][:field_len]

		#partial switch tag {
		case .TaskID:
			if field_len != 8 do return parsed, false
			id, _ := endian.get_u64(field_data, .Big)
			parsed.id = pr.TaskID(id)
		case .ConvID:
			if field_len != 8 do return parsed, false
			id, _ := endian.get_u64(field_data, .Big)
			parsed.conv_id = pr.ConversationID(id)
		case .Title:
			parsed.title = field_data // No clone - points into source
		case .Description:
			parsed.description = field_data
		case .Status:
			if field_len != 1 do return parsed, false
			parsed.status = pr.TaskStatus(field_data[0])
		case .OrderIndex:
			if field_len != 2 do return parsed, false
			idx, _ := endian.get_u16(field_data, .Big)
			parsed.order_index = idx
		case .Assignee:
			parsed.assignee = field_data
		case .Priority:
			if field_len != 1 do return parsed, false
			parsed.priority = field_data[0]
		case .Color:
			if field_len != 1 do return parsed, false
			parsed.color = pr.TaskColor(field_data[0])
		case .CreatedBy:
			parsed.created_by = field_data
		case .CreatedAt:
			if field_len != 8 do return parsed, false
			parsed.created_at, _ = endian.get_i64(field_data, .Big)
		case .UpdatedAt:
			if field_len != 8 do return parsed, false
			parsed.updated_at, _ = endian.get_i64(field_data, .Big)
		case .ExternalRef:
			parsed.external_ref = field_data
		case .DueAt:
			if field_len != 8 do return parsed, false
			parsed.due_at, _ = endian.get_i64(field_data, .Big)
		case .BlockedBy:
			if field_len != 8 do return parsed, false
			id, _ := endian.get_u64(field_data, .Big)
			parsed.blocked_by = pr.TaskID(id)
		case .CompletedAt:
			if field_len != 8 do return parsed, false
			parsed.completed_at, _ = endian.get_i64(field_data, .Big)
		case .CompletedBy:
			parsed.completed_by = field_data
		case .Project:
			parsed.project = field_data
		case .Attachments:
			// Parse attachments directly into the fixed array in parsed struct
			attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			attachment_count: int
			attachments, attachment_count, ok = parse_attachments_field(field_data)
			if !ok {
				return parsed, false
			}
			parsed.attachments = attachments
			parsed.attachment_count = attachment_count
		case:
			// Unknown tag - skip (forward compatibility)
			when ODIN_DEBUG do debug_log("[T%d] Unknown field tag %d, skipping", td.thread_index, u8(tag))
		}

		offset += int(field_len)
	}

	return parsed, true
}

// parse_attachments_field parses attachment data from WAL field - stack-allocated, returns slice
parse_attachments_field :: proc(field_data: []byte) -> (attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment, count: int, ok: bool) {
	if len(field_data) < 2 {
		return attachments, 0, false
	}

	offset := 0
	att_count, _ := endian.get_u16(field_data[offset:], .Big)
	offset += 2
	att_count_int := int(att_count)

	if att_count_int > pr.MAX_ATTACHMENTS_PER_TASK {
		log.warnf("[T%d] Attachment count %d exceeds max", td.thread_index, att_count_int)
		return attachments, 0, false
	}

	for i := 0; i < att_count_int; i += 1 {
		att := pr.Attachment{}

		// Parse file_id
		if len(field_data) - offset < 2 {
			return attachments, 0, false
		}
		file_id_len, _ := endian.get_u16(field_data[offset:], .Big)
		offset += 2

		if int(file_id_len) > len(field_data) - offset {
			return attachments, 0, false
		}
		att.file_id = field_data[offset:][:file_id_len]
		offset += int(file_id_len)

		// Parse filename
		if len(field_data) - offset < 2 {
			return attachments, 0, false
		}
		filename_len, _ := endian.get_u16(field_data[offset:], .Big)
		offset += 2

		if int(filename_len) > len(field_data) - offset {
			return attachments, 0, false
		}
		att.filename = field_data[offset:][:filename_len]
		offset += int(filename_len)

		// Parse size
		if len(field_data) - offset < 8 {
			return attachments, 0, false
		}
		att.size, _ = endian.get_u64(field_data[offset:], .Big)
		offset += 8

		// Parse mime_type
		if len(field_data) - offset < 2 {
			return attachments, 0, false
		}
		mime_type_len, _ := endian.get_u16(field_data[offset:], .Big)
		offset += 2

		if int(mime_type_len) > len(field_data) - offset {
			return attachments, 0, false
		}
		att.mime_type = field_data[offset:][:mime_type_len]
		offset += int(mime_type_len)

		// Parse uploaded_at
		if len(field_data) - offset < 8 {
			return attachments, 0, false
		}
		att.uploaded_at, _ = endian.get_i64(field_data[offset:], .Big)
		offset += 8

		attachments[i] = att
		count += 1
	}

	return attachments, count, offset == len(field_data)
}

// ============================================================================
// Apply Helpers (Map-only, no network side effects)
// ============================================================================

apply_persisted_task :: proc(workspace_id: string, parsed: ^Parsed_Task_Data) -> bool {
	ws := get_or_create_workspace(workspace_id)
	conv := get_or_create_conversation(ws, parsed.conv_id)

	// Allocate new task with single-alloc pattern (copies strings into trailing buffer)
	// Attachments are loaded from persistent storage if available
	new_task := alloc_task(
		parsed.title,
		parsed.description,
		parsed.assignee,
		parsed.created_by,
		parsed.external_ref,
		parsed.completed_by,
		parsed.project,
		parsed.attachments[:parsed.attachment_count],
	)
	if new_task == nil {
		log.errorf("[T%d] Failed to allocate task", td.thread_index)
		return false
	}

	// Set non-string fields
	new_task.id = parsed.id
	new_task.conv_id = parsed.conv_id
	new_task.status = parsed.status
	new_task.order_index = parsed.order_index
	new_task.priority = parsed.priority
	new_task.color = parsed.color
	new_task.created_at = parsed.created_at
	new_task.updated_at = parsed.updated_at
	new_task.due_at = parsed.due_at
	new_task.blocked_by = parsed.blocked_by
	new_task.completed_at = parsed.completed_at

	task_store_put(conv, new_task)
	return true
}

apply_persisted_delete :: proc(workspace_id: string, conv_id: pr.ConversationID, task_id: pr.TaskID) {
	ws := get_workspace(workspace_id)
	if ws == nil {
		return
	}

	conv := get_conversation(ws, conv_id)
	if conv == nil {
		return
	}

	task_store_remove(conv, task_id)
}
