package protocol

import "core:encoding/endian"
import "core:log"
import "core:unicode/utf8"

// ============================================================================
// Task Types
// ============================================================================

TaskID :: u64

TaskStatus :: enum u8 {
	Backlog    = 0,
	Todo       = 1,
	InProgress = 2,
	Done       = 3,
	Note       = 4,
}

TaskColor :: enum u8 {
	None  = 0,
	Cyan  = 1, // Active/Focus (#00aeef)
	Red   = 2, // Blocked/Critical (#ed1c24)
	Green = 3, // Ready/Approved (#00a651)
	Gray  = 4, // Deferred/Low (#939598)
	Gold  = 5, // Test (#ffb700)
}

Attachment :: struct {
	file_id:     []byte, // ULID as string
	filename:    []byte, // Original filename
	size:        u64, // File size in bytes
	mime_type:   []byte, // MIME type string
	uploaded_at: i64, // Unix nanoseconds
}

Task :: struct {
	id:           TaskID,
	conv_id:      ConversationID,
	title:        []byte,
	description:  []byte,
	status:       TaskStatus,
	order_index:  u16,
	assignee:     []byte,
	priority:     u8,
	color:        TaskColor,
	created_by:   []byte,
	created_at:   i64,
	updated_at:   i64,
	external_ref: []byte, // External reference (URL, ticket ID, etc.)
	due_at:       i64, // 0 = no due date, else Unix nanoseconds
	blocked_by:   TaskID, // 0 = not blocked, else blocking task ID
	completed_at: i64, // 0 = not completed, auto-set when status becomes Done
	completed_by: []byte, // Empty if not completed, auto-set when status becomes Done
	project:      []byte, // Optional project/workstream label
	attachments:  []Attachment, // File attachments for this task
}

// ============================================================================
// CreateTask (C_CreateTask = 20)
// ============================================================================

CreateTaskRequest :: struct {
	conv_id:        ConversationID,
	title:          []byte,
	description:    []byte,
	priority:       u8,
	color:          TaskColor,
	external_ref:   []byte,
	due_at:         i64, // 0 = no due date
	attachments:    []Attachment,
	status:         TaskStatus, // Default Backlog, or Note for notes
	project:        []byte,
	correlation_id: u32, // Client-generated, echoed in S_TaskCreated for request/response correlation
}

_CTR_OFFSET_CONV_ID :: 0
_CTR_SIZE_CONV_ID :: size_of(ConversationID)
_CTR_OFFSET_TITLE_LEN :: _CTR_OFFSET_CONV_ID + _CTR_SIZE_CONV_ID
_CTR_SIZE_TITLE_LEN :: size_of(u16)
_CTR_MIN_HEADER_SIZE :: _CTR_OFFSET_TITLE_LEN + _CTR_SIZE_TITLE_LEN

parseCreateTaskRequest :: proc(data: []byte, attachments: []Attachment = nil) -> (CreateTaskRequest, ProtocolParseError) {
	result := CreateTaskRequest{}

	if len(data) < _CTR_MIN_HEADER_SIZE {
		log.debugf("CreateTaskRequest payload too short. Need %v, got %v", _CTR_MIN_HEADER_SIZE, len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	offset += 8

	title_len_u16, _ := endian.get_u16(data[offset:], .Big)
	offset += 2
	title_len := int(title_len_u16)

	if title_len > MAX_TASK_TITLE_LENGTH {
		log.debugf("Task title length %v exceeds maximum %v", title_len, MAX_TASK_TITLE_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + title_len + 2 + 1 {
		log.debugf("CreateTaskRequest data too short for title. Have: %v, Need: %v", len(data), offset + title_len + 2 + 1)
		return result, .ContentLengthMismatch
	}

	title := data[offset:offset + title_len]
	offset += title_len

	desc_len_u16, _ := endian.get_u16(data[offset:], .Big)
	offset += 2
	desc_len := int(desc_len_u16)

	if desc_len > MAX_TASK_DESCRIPTION_LENGTH {
		log.debugf("Task description length %v exceeds maximum %v", desc_len, MAX_TASK_DESCRIPTION_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + desc_len + 1 {
		log.debugf("CreateTaskRequest data too short for description. Have: %v, Need: %v", len(data), offset + desc_len + 1)
		return result, .ContentLengthMismatch
	}

	description := data[offset:offset + desc_len]
	offset += desc_len

	priority := data[offset]
	offset += 1

	// Parse color
	if len(data) < offset + 1 {
		return result, .TooShort
	}
	color := TaskColor(data[offset])
	offset += 1

	// Parse external_ref
	if len(data) < offset + 2 {
		return result, .TooShort
	}
	ext_ref_len_u16, _ := endian.get_u16(data[offset:], .Big)
	offset += 2
	ext_ref_len := int(ext_ref_len_u16)

	if ext_ref_len > MAX_EXTERNAL_REF_LENGTH {
		log.debugf("External ref length %v exceeds maximum %v", ext_ref_len, MAX_EXTERNAL_REF_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + ext_ref_len {
		return result, .ContentLengthMismatch
	}
	external_ref := data[offset:offset + ext_ref_len]
	offset += ext_ref_len

	// Parse due_at (optional, 0 if not enough data for backward compat)
	due_at: i64 = 0
	if len(data) >= offset + 8 {
		due_at_u64, _ := endian.get_u64(data[offset:], .Big)
		due_at = cast(i64)due_at_u64
		offset += 8
	}

	// Parse attachments into caller-owned bounded storage.
	att_count := 0

	if len(data) >= offset + 2 {
		att_count_u16, _ := endian.get_u16(data[offset:], .Big)
		offset += 2
		att_count = int(att_count_u16)

		if att_count > MAX_ATTACHMENTS_PER_TASK || att_count > len(attachments) {
			log.debugf("Attachment count %v exceeds available capacity %v", att_count, len(attachments))
			return result, .TooMany
		}

		for i := 0; i < att_count; i += 1 {
			att := Attachment{}

			// Parse file_id
			if len(data) < offset + 2 {
				return result, .ContentLengthMismatch
			}
			file_id_len_u16, _ := endian.get_u16(data[offset:], .Big)
			offset += 2
			file_id_len := int(file_id_len_u16)

			if file_id_len > MAX_FILE_ID_LENGTH {
				log.debugf("File ID length %v exceeds maximum %v", file_id_len, MAX_FILE_ID_LENGTH)
				return result, .ContentLengthExceedsMax
			}

			if len(data) < offset + file_id_len {
				return result, .ContentLengthMismatch
			}
			att.file_id = data[offset:][:file_id_len]
			offset += file_id_len

			// Parse filename
			if len(data) < offset + 2 {
				return result, .ContentLengthMismatch
			}
			filename_len_u16, _ := endian.get_u16(data[offset:], .Big)
			offset += 2
			filename_len := int(filename_len_u16)

			if filename_len > MAX_FILENAME_LENGTH {
				log.debugf("Filename length %v exceeds maximum %v", filename_len, MAX_FILENAME_LENGTH)
				return result, .ContentLengthExceedsMax
			}

			if len(data) < offset + filename_len {
				return result, .ContentLengthMismatch
			}
			att.filename = data[offset:][:filename_len]
			offset += filename_len

			// Parse size
			if len(data) < offset + 8 {
				return result, .ContentLengthMismatch
			}
			att.size, _ = endian.get_u64(data[offset:], .Big)
			offset += 8

			// Parse mime_type
			if len(data) < offset + 2 {
				return result, .ContentLengthMismatch
			}
			mime_type_len_u16, _ := endian.get_u16(data[offset:], .Big)
			offset += 2
			mime_type_len := int(mime_type_len_u16)

			if mime_type_len > MAX_MIME_TYPE_LENGTH {
				log.debugf("MIME type length %v exceeds maximum %v", mime_type_len, MAX_MIME_TYPE_LENGTH)
				return result, .ContentLengthExceedsMax
			}

			if len(data) < offset + mime_type_len {
				return result, .ContentLengthMismatch
			}
			att.mime_type = data[offset:][:mime_type_len]
			offset += mime_type_len

			// Parse uploaded_at
			if len(data) < offset + 8 {
				return result, .ContentLengthMismatch
			}
			uploaded_at_u64, _ := endian.get_u64(data[offset:], .Big)
			att.uploaded_at = cast(i64)uploaded_at_u64
			offset += 8

			attachments[i] = att
		}
	}

	// Parse status (optional, default Backlog for backward compat)
	status := TaskStatus.Backlog
	if len(data) >= offset + 1 {
		status = TaskStatus(data[offset])
		offset += 1
	}

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	correlation_id, _ := endian.get_u32(data[offset:], .Big)
	offset += 4

	project: []byte
	if len(data) >= offset + 2 {
		project_len_u16, _ := endian.get_u16(data[offset:], .Big)
		offset += 2
		project_len := int(project_len_u16)
		if project_len > MAX_PROJECT_LENGTH {
			log.debugf("Task project length %v exceeds maximum %v", project_len, MAX_PROJECT_LENGTH)
			return result, .ContentLengthExceedsMax
		}
		if len(data) < offset + project_len {
			return result, .ContentLengthMismatch
		}
		project = data[offset:offset + project_len]
		offset += project_len
	}

	if len(data) != offset {
		return result, .ContentLengthMismatch
	}

	result = CreateTaskRequest {
		conv_id        = ConversationID(conv_id),
		title          = title,
		description    = description,
		priority       = priority,
		color          = color,
		external_ref   = external_ref,
		due_at         = due_at,
		attachments    = attachments[:att_count],
		status         = status,
		project        = project,
		correlation_id = correlation_id,
	}

	return result, nil
}

// ============================================================================
// UpdateTask (C_UpdateTask = 21)
// ============================================================================

UpdateTaskRequest :: struct {
	conv_id:              ConversationID,
	task_id:              TaskID,
	title:                []byte,
	description:          []byte,
	status:               TaskStatus,
	assignee:             []byte,
	priority:             u8,
	color:                TaskColor,
	external_ref:         []byte,
	due_at:               i64, // 0 = no change, else new due date (use -1 to clear)
	blocked_by:           TaskID, // 0 = no change, max_u64 = clear, else set blocker
	attachments:          []Attachment, // Full attachment list when preserve_attachments is false
	preserve_attachments: bool, // Wire count max_u16 = no change
	project:              []byte,
	correlation_id:       u32, // Client-generated, echoed in S_TaskUpdated for request/response correlation
}

_UTR_MIN_HEADER_SIZE :: size_of(ConversationID) + size_of(TaskID)

parseUpdateTaskRequest :: proc(data: []byte, attachments: []Attachment = nil) -> (UpdateTaskRequest, ProtocolParseError) {
	result := UpdateTaskRequest{}

	if len(data) < _UTR_MIN_HEADER_SIZE {
		log.debugf("UpdateTaskRequest payload too short. Need %v, got %v", _UTR_MIN_HEADER_SIZE, len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	offset += 8

	task_id, _ := endian.get_u64(data[offset:], .Big)
	offset += 8

	if len(data) < offset + 2 {
		return result, .TooShort
	}
	title_len_u16, _ := endian.get_u16(data[offset:], .Big)
	offset += 2
	title_len := int(title_len_u16)

	if title_len > MAX_TASK_TITLE_LENGTH {
		log.debugf("Task title length %v exceeds maximum %v", title_len, MAX_TASK_TITLE_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + title_len {
		return result, .ContentLengthMismatch
	}
	title := data[offset:offset + title_len]
	offset += title_len

	if len(data) < offset + 2 {
		return result, .TooShort
	}
	desc_len_u16, _ := endian.get_u16(data[offset:], .Big)
	offset += 2
	desc_len := int(desc_len_u16)

	if desc_len > MAX_TASK_DESCRIPTION_LENGTH {
		log.debugf("Task description length %v exceeds maximum %v", desc_len, MAX_TASK_DESCRIPTION_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + desc_len {
		return result, .ContentLengthMismatch
	}
	description := data[offset:offset + desc_len]
	offset += desc_len

	if len(data) < offset + 1 + 2 + 1 {
		return result, .TooShort
	}

	status := TaskStatus(data[offset])
	offset += 1

	assignee_len_u16, _ := endian.get_u16(data[offset:], .Big)
	offset += 2
	assignee_len := int(assignee_len_u16)

	if assignee_len > MAX_ASSIGNEE_LENGTH {
		log.debugf("Assignee length %v exceeds maximum %v", assignee_len, MAX_ASSIGNEE_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + assignee_len + 1 {
		return result, .ContentLengthMismatch
	}
	assignee := data[offset:offset + assignee_len]
	offset += assignee_len

	priority := data[offset]
	offset += 1

	// Parse color
	if len(data) < offset + 1 {
		return result, .TooShort
	}
	color := TaskColor(data[offset])
	offset += 1

	// Parse external_ref
	if len(data) < offset + 2 {
		return result, .TooShort
	}
	ext_ref_len_u16, _ := endian.get_u16(data[offset:], .Big)
	offset += 2
	ext_ref_len := int(ext_ref_len_u16)

	if ext_ref_len > MAX_EXTERNAL_REF_LENGTH {
		log.debugf("External ref length %v exceeds maximum %v", ext_ref_len, MAX_EXTERNAL_REF_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + ext_ref_len {
		return result, .ContentLengthMismatch
	}
	external_ref := data[offset:offset + ext_ref_len]
	offset += ext_ref_len

	// Parse due_at (optional, 0 = no change for backward compat)
	due_at: i64 = 0
	if len(data) >= offset + 8 {
		due_at_u64, _ := endian.get_u64(data[offset:], .Big)
		due_at = cast(i64)due_at_u64
		offset += 8
	}

	// Parse blocked_by (optional, 0 = no change for backward compat)
	blocked_by: TaskID = 0
	if len(data) >= offset + 8 {
		blocked_by_u64, _ := endian.get_u64(data[offset:], .Big)
		blocked_by = TaskID(blocked_by_u64)
		offset += 8
	}

	// Parse attachments (optional, replaces existing) into caller-owned storage.
	// max_u16 is the no-change sentinel used by partial task updates.
	att_count := 0
	preserve_attachments := false

	if len(data) >= offset + 2 {
		att_count_u16, _ := endian.get_u16(data[offset:], .Big)
		offset += 2
		if att_count_u16 == max(u16) {
			preserve_attachments = true
		} else {
			att_count = int(att_count_u16)

			if att_count > MAX_ATTACHMENTS_PER_TASK || att_count > len(attachments) {
				log.debugf("Attachment count %v exceeds available capacity %v", att_count, len(attachments))
				return result, .TooMany
			}

			for i := 0; i < att_count; i += 1 {
				att := Attachment{}

				// Parse file_id
				if len(data) < offset + 2 {
					return result, .ContentLengthMismatch
				}
				file_id_len_u16, _ := endian.get_u16(data[offset:], .Big)
				offset += 2
				file_id_len := int(file_id_len_u16)

				if file_id_len > MAX_FILE_ID_LENGTH {
					log.debugf("File ID length %v exceeds maximum %v", file_id_len, MAX_FILE_ID_LENGTH)
					return result, .ContentLengthExceedsMax
				}

				if len(data) < offset + file_id_len {
					return result, .ContentLengthMismatch
				}
				att.file_id = data[offset:][:file_id_len]
				offset += file_id_len

				// Parse filename
				if len(data) < offset + 2 {
					return result, .ContentLengthMismatch
				}
				filename_len_u16, _ := endian.get_u16(data[offset:], .Big)
				offset += 2
				filename_len := int(filename_len_u16)

				if filename_len > MAX_FILENAME_LENGTH {
					log.debugf("Filename length %v exceeds maximum %v", filename_len, MAX_FILENAME_LENGTH)
					return result, .ContentLengthExceedsMax
				}

				if len(data) < offset + filename_len {
					return result, .ContentLengthMismatch
				}
				att.filename = data[offset:][:filename_len]
				offset += filename_len

				// Parse size
				if len(data) < offset + 8 {
					return result, .ContentLengthMismatch
				}
				att.size, _ = endian.get_u64(data[offset:], .Big)
				offset += 8

				// Parse mime_type
				if len(data) < offset + 2 {
					return result, .ContentLengthMismatch
				}
				mime_type_len_u16, _ := endian.get_u16(data[offset:], .Big)
				offset += 2
				mime_type_len := int(mime_type_len_u16)

				if mime_type_len > MAX_MIME_TYPE_LENGTH {
					log.debugf("MIME type length %v exceeds maximum %v", mime_type_len, MAX_MIME_TYPE_LENGTH)
					return result, .ContentLengthExceedsMax
				}

				if len(data) < offset + mime_type_len {
					return result, .ContentLengthMismatch
				}
				att.mime_type = data[offset:][:mime_type_len]
				offset += mime_type_len

				// Parse uploaded_at
				if len(data) < offset + 8 {
					return result, .ContentLengthMismatch
				}
				uploaded_at_u64, _ := endian.get_u64(data[offset:], .Big)
				att.uploaded_at = cast(i64)uploaded_at_u64
				offset += 8

				attachments[i] = att
			}
		}
	}

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	correlation_id, _ := endian.get_u32(data[offset:], .Big)
	offset += 4

	project: []byte
	if len(data) >= offset + 2 {
		project_len_u16, _ := endian.get_u16(data[offset:], .Big)
		offset += 2
		project_len := int(project_len_u16)
		if project_len > MAX_PROJECT_LENGTH {
			log.debugf("Task project length %v exceeds maximum %v", project_len, MAX_PROJECT_LENGTH)
			return result, .ContentLengthExceedsMax
		}
		if len(data) < offset + project_len {
			return result, .ContentLengthMismatch
		}
		project = data[offset:offset + project_len]
		offset += project_len
	}

	if len(data) != offset {
		return result, .ContentLengthMismatch
	}

	result = UpdateTaskRequest {
		conv_id              = ConversationID(conv_id),
		task_id              = TaskID(task_id),
		title                = title,
		description          = description,
		status               = status,
		assignee             = assignee,
		priority             = priority,
		color                = color,
		external_ref         = external_ref,
		due_at               = due_at,
		blocked_by           = blocked_by,
		attachments          = attachments[:att_count],
		preserve_attachments = preserve_attachments,
		project              = project,
		correlation_id       = correlation_id,
	}

	return result, nil
}

// ============================================================================
// DeleteTask (C_DeleteTask = 22)
// ============================================================================

DeleteTaskRequest :: struct {
	conv_id:        ConversationID,
	task_id:        TaskID,
	correlation_id: u32, // Client-generated, echoed in S_TaskDeleted for request/response correlation
}

_DTR_SIZE :: size_of(ConversationID) + size_of(TaskID)

parseDeleteTaskRequest :: proc(data: []byte) -> (DeleteTaskRequest, ProtocolParseError) {
	result := DeleteTaskRequest{}

	if len(data) < _DTR_SIZE {
		log.debugf("DeleteTaskRequest payload too short. Need %v, got %v", _DTR_SIZE, len(data))
		return result, .TooShort
	}
	if len(data) != _DTR_SIZE + 4 {
		if len(data) < _DTR_SIZE + 4 {
			return result, .TooShort
		}
		return result, .ContentLengthMismatch
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	task_id, _ := endian.get_u64(data[8:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.task_id = TaskID(task_id)

	result.correlation_id, _ = endian.get_u32(data[_DTR_SIZE:], .Big)

	return result, nil
}

// ============================================================================
// MoveTask (C_MoveTask = 23) - Optimized drag-drop reordering
// ============================================================================

// What a move asks for beyond the target column. A register draws one page at a
// time, so a client does not always hold the column and cannot name a position:
// Append asks the server to put the task at the end of the target column, and the
// position stays the server's to fold. A named position is what a drag between
// two drawn rows sends. An update never moves a task within its column: it
// preserves the order index it had, and the position of a status change comes
// from the move that follows it.
MoveTaskFlag :: enum u8 {
	Append,
}

MoveTaskFlags :: distinct bit_set[MoveTaskFlag;u8]

MoveTaskFlag_APPEND :: MoveTaskFlags{.Append}

MoveTaskRequest :: struct {
	conv_id:        ConversationID,
	task_id:        TaskID,
	status:         TaskStatus,
	flags:          MoveTaskFlags,
	order_index:    u16, // the position in the target column; ignored when flags carries Append
	correlation_id: u32, // Client-generated, echoed in S_TaskMoved for request/response correlation
}

_MTR_SIZE :: size_of(ConversationID) + size_of(TaskID) + size_of(u8) + size_of(u8) + size_of(u16)

parseMoveTaskRequest :: proc(data: []byte) -> (MoveTaskRequest, ProtocolParseError) {
	result := MoveTaskRequest{}

	if len(data) < _MTR_SIZE {
		log.debugf("MoveTaskRequest payload too short. Need %v, got %v", _MTR_SIZE, len(data))
		return result, .TooShort
	}
	if len(data) != _MTR_SIZE + 4 {
		if len(data) < _MTR_SIZE + 4 {
			return result, .TooShort
		}
		return result, .ContentLengthMismatch
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	offset += 8

	task_id, _ := endian.get_u64(data[offset:], .Big)
	offset += 8

	status := TaskStatus(data[offset])
	offset += 1

	// Only the flags this build defines are honored: an unknown bit is a request
	// the server cannot answer, and it must not quietly read as a named position.
	flags_raw := data[offset]
	if (flags_raw & (~transmute(u8)MoveTaskFlag_APPEND)) != 0 {
		return result, .InvalidValue
	}
	flags := transmute(MoveTaskFlags)flags_raw
	offset += 1

	order_index, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	correlation_id, _ := endian.get_u32(data[offset:], .Big)

	result = MoveTaskRequest {
		conv_id        = ConversationID(conv_id),
		task_id        = TaskID(task_id),
		status         = status,
		flags          = flags,
		order_index    = order_index,
		correlation_id = correlation_id,
	}

	return result, nil
}

// ============================================================================
// GetTasks (C_GetTasks = 24)
// ============================================================================

GetTasksRequest :: struct {
	conv_id:        ConversationID,
	correlation_id: u32, // Client-generated, echoed in S_TaskListResponse for request/response correlation
}

_GTR_SIZE :: size_of(ConversationID)

parseGetTasksRequest :: proc(data: []byte) -> (GetTasksRequest, ProtocolParseError) {
	result := GetTasksRequest{}

	if len(data) < _GTR_SIZE {
		log.debugf("GetTasksRequest payload too short. Need %v, got %v", _GTR_SIZE, len(data))
		return result, .TooShort
	}
	if len(data) != _GTR_SIZE + 4 {
		if len(data) < _GTR_SIZE + 4 {
			return result, .TooShort
		}
		return result, .ContentLengthMismatch
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	result.correlation_id, _ = endian.get_u32(data[_GTR_SIZE:], .Big)

	return result, nil
}

// ============================================================================
// TaskCreated (S_TaskCreated = 130)
// ============================================================================

TaskCreated :: struct {
	task:           Task,
	correlation_id: u32, // Echoed from client's CreateTask request (0 for broadcasts)
}

getSizeTaskCreated :: proc(msg: TaskCreated) -> int {
	return 2 + getSizeTask(msg.task) + 4 // opcode + task + correlation_id
}

serializeTaskCreated :: proc(msg: TaskCreated, buf: []byte) -> int {
	total_size := getSizeTaskCreated(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for TaskCreated. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_TaskCreated))
	offset := 2
	task_size := serializeTask(msg.task, buf[offset:])
	if task_size < 0 {
		return -1
	}
	offset += task_size
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseTaskCreated :: proc(data: []byte, attachments: []Attachment) -> (result: TaskCreated, err: ProtocolParseError) {
	if len(data) < 6 do return result, .TooShort
	if get_opcode(data) != .S_TaskCreated do return result, .InvalidOpcode

	task, offset, _, task_err := parse_task_from_payload(data, 2, attachments)
	if task_err != nil do return result, task_err
	if offset + 4 > len(data) do return result, .TooShort
	if offset + 4 != len(data) do return result, .ContentLengthMismatch

	result.task = task
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

// ============================================================================
// TaskUpdated (S_TaskUpdated = 131)
// ============================================================================

TaskUpdated :: struct {
	task:           Task,
	correlation_id: u32, // Echoed from client's UpdateTask request (0 for broadcasts)
}

getSizeTaskUpdated :: proc(msg: TaskUpdated) -> int {
	return 2 + getSizeTask(msg.task) + 4 // opcode + task + correlation_id
}

serializeTaskUpdated :: proc(msg: TaskUpdated, buf: []byte) -> int {
	total_size := getSizeTaskUpdated(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for TaskUpdated. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_TaskUpdated))
	offset := 2
	task_size := serializeTask(msg.task, buf[offset:])
	if task_size < 0 {
		return -1
	}
	offset += task_size
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseTaskUpdated :: proc(data: []byte, attachments: []Attachment) -> (result: TaskUpdated, err: ProtocolParseError) {
	if len(data) < 6 do return result, .TooShort
	if get_opcode(data) != .S_TaskUpdated do return result, .InvalidOpcode

	task, offset, _, task_err := parse_task_from_payload(data, 2, attachments)
	if task_err != nil do return result, task_err
	if offset + 4 > len(data) do return result, .TooShort
	if offset + 4 != len(data) do return result, .ContentLengthMismatch

	result.task = task
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

// ============================================================================
// TaskDeleted (S_TaskDeleted = 132)
// ============================================================================

TaskDeleted :: struct {
	task_id:        TaskID,
	conv_id:        ConversationID,
	correlation_id: u32, // Echoed from client's DeleteTask request (0 for broadcasts)
}

_TD_SIZE :: 2 + size_of(TaskID) + size_of(ConversationID) + size_of(u32)

getSizeTaskDeleted :: proc(msg: TaskDeleted) -> int {
	_ = msg
	return _TD_SIZE
}

serializeTaskDeleted :: proc(msg: TaskDeleted, buf: []byte) -> int {
	if len(buf) < _TD_SIZE {
		log.errorf("Buffer too small for TaskDeleted. Need %v, got %v", _TD_SIZE, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_TaskDeleted))

	payload := buf[2:]
	endian.put_u64(payload[0:], .Big, u64(msg.task_id))
	endian.put_u64(payload[8:], .Big, u64(msg.conv_id))
	endian.put_u32(payload[16:], .Big, msg.correlation_id)

	return _TD_SIZE
}

parseTaskDeleted :: proc(data: []byte) -> (result: TaskDeleted, err: ProtocolParseError) {
	if len(data) < _TD_SIZE do return result, .TooShort
	if get_opcode(data) != .S_TaskDeleted do return result, .InvalidOpcode
	if len(data) != _TD_SIZE do return result, .ContentLengthMismatch

	payload := data[2:]
	task_id, _ := endian.get_u64(payload[0:], .Big)
	conv_id, _ := endian.get_u64(payload[8:], .Big)
	result.task_id = TaskID(task_id)
	result.conv_id = ConversationID(conv_id)
	result.correlation_id, _ = endian.get_u32(payload[16:], .Big)
	return result, nil
}

// ============================================================================
// TaskMoved (S_TaskMoved = 133)
// ============================================================================

TaskMoved :: struct {
	task_id:        TaskID,
	conv_id:        ConversationID,
	status:         TaskStatus,
	order_index:    u16,
	completed_at:   i64,
	completed_by:   []byte,
	correlation_id: u32, // Echoed from client's MoveTask request (0 for broadcasts)
}

_TM_BASE_SIZE :: 2 + size_of(TaskID) + size_of(ConversationID) + size_of(u8) + size_of(u16) + size_of(i64) + size_of(u16) + size_of(u32)

getSizeTaskMoved :: proc(msg: TaskMoved) -> int {
	return _TM_BASE_SIZE + len(msg.completed_by)
}

serializeTaskMoved :: proc(msg: TaskMoved, buf: []byte) -> int {
	if len(msg.completed_by) > MAX_USERNAME_LENGTH {
		log.errorf("Completed-by username length %v exceeds maximum %v", len(msg.completed_by), MAX_USERNAME_LENGTH)
		return -1
	}

	required := getSizeTaskMoved(msg)
	if len(buf) < required {
		log.errorf("Buffer too small for TaskMoved. Need %v, got %v", required, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_TaskMoved))

	payload := buf[2:]
	offset := 0

	endian.put_u64(payload[offset:], .Big, u64(msg.task_id))
	offset += 8

	endian.put_u64(payload[offset:], .Big, u64(msg.conv_id))
	offset += 8

	payload[offset] = u8(msg.status)
	offset += 1

	endian.put_u16(payload[offset:], .Big, msg.order_index)
	offset += 2

	endian.put_i64(payload[offset:], .Big, msg.completed_at)
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(len(msg.completed_by)))
	offset += 2
	if len(msg.completed_by) > 0 {
		copy(payload[offset:], msg.completed_by)
		offset += len(msg.completed_by)
	}

	endian.put_u32(payload[offset:], .Big, msg.correlation_id)

	return required
}

parseTaskMoved :: proc(data: []byte) -> (result: TaskMoved, err: ProtocolParseError) {
	if len(data) < _TM_BASE_SIZE do return result, .TooShort
	if get_opcode(data) != .S_TaskMoved do return result, .InvalidOpcode

	payload := data[2:]
	offset := 0
	task_id, _ := endian.get_u64(payload[offset:], .Big)
	result.task_id = TaskID(task_id)
	offset += 8
	conv_id, _ := endian.get_u64(payload[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8
	result.status = TaskStatus(payload[offset])
	offset += 1
	result.order_index, _ = endian.get_u16(payload[offset:], .Big)
	offset += 2
	completed_at, _ := endian.get_i64(payload[offset:], .Big)
	result.completed_at = completed_at
	offset += 8
	completed_by_len_raw, _ := endian.get_u16(payload[offset:], .Big)
	offset += 2
	completed_by_len := int(completed_by_len_raw)
	if offset + completed_by_len + 4 > len(payload) do return result, .TooShort
	if offset + completed_by_len + 4 != len(payload) do return result, .ContentLengthMismatch
	result.completed_by = payload[offset:offset + completed_by_len]
	offset += completed_by_len
	result.correlation_id, _ = endian.get_u32(payload[offset:], .Big)
	return result, nil
}

// ============================================================================
// TaskListResponse (S_TaskListResponse = 134)
// ============================================================================

TaskListResponse :: struct {
	conv_id:        ConversationID,
	success:        bool,
	tasks:          []Task,
	error:          []byte,
	correlation_id: u32, // Echoed from client's GetTasks request (0 when not request-scoped)
}

getSizeTaskListResponse :: proc(msg: TaskListResponse) -> int {
	size := 2 + 8 + 1 + 2 + 2 + len(msg.error) + 4
	for task in msg.tasks {
		size += getSizeTask(task)
	}
	return size
}

serializeTaskListResponse :: proc(msg: TaskListResponse, buf: []byte) -> int {
	if len(msg.tasks) > 65535 {
		log.errorf("Task count %v exceeds maximum %v", len(msg.tasks), 65535)
		return -1
	}

	if len(msg.error) > 65535 {
		log.errorf("Error text length %v exceeds maximum %v", len(msg.error), 65535)
		return -1
	}

	total_size := getSizeTaskListResponse(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for TaskListResponse. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_TaskListResponse))

	payload := buf[2:]
	offset := 0

	endian.put_u64(payload[offset:], .Big, u64(msg.conv_id))
	offset += 8

	payload[offset] = msg.success ? 1 : 0
	offset += 1

	task_count := len(msg.tasks)
	endian.put_u16(payload[offset:], .Big, u16(task_count))
	offset += 2

	for task in msg.tasks {
		task_size := serializeTask(task, payload[offset:])
		if task_size < 0 {
			return -1
		}
		offset += task_size
	}

	error_len := len(msg.error)
	endian.put_u16(payload[offset:], .Big, u16(error_len))
	offset += 2
	if error_len > 0 {
		copy(payload[offset:], msg.error)
		offset += error_len
	}

	endian.put_u32(payload[offset:], .Big, msg.correlation_id)

	return total_size
}

parseTaskListResponse :: proc(data: []byte, tasks: []Task, attachments: []Attachment) -> (result: TaskListResponse, err: ProtocolParseError) {
	if len(data) < 17 do return result, .TooShort
	if get_opcode(data) != .S_TaskListResponse do return result, .InvalidOpcode

	conv_id_raw, conv_ok := endian.get_u64(data[2:], .Big)
	task_count_raw, task_count_ok := endian.get_u16(data[11:], .Big)
	if !conv_ok || !task_count_ok do return result, .TooShort
	if int(task_count_raw) > len(tasks) do return result, .TooMany

	result.conv_id = ConversationID(conv_id_raw)
	result.success = data[10] != 0
	result.tasks = tasks[:task_count_raw]

	pos := 13
	attachment_pos := 0
	for i := 0; i < int(task_count_raw); i += 1 {
		task, next_pos, used_attachments, task_err := parse_task_from_payload(data, pos, attachments[attachment_pos:])
		if task_err != nil do return result, task_err
		tasks[i] = task
		pos = next_pos
		attachment_pos += used_attachments
	}

	if pos + 2 > len(data) do return result, .TooShort
	error_len_raw, error_len_ok := endian.get_u16(data[pos:], .Big)
	if !error_len_ok do return result, .TooShort
	pos += 2
	error_len := int(error_len_raw)
	if pos + error_len + 4 != len(data) do return result, .ContentLengthMismatch
	result.error = data[pos:pos + error_len]
	pos += error_len

	correlation_id, correlation_ok := endian.get_u32(data[pos:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id

	return result, nil
}

// ============================================================================
// Paged task queries (C_ListTasksPaged=25, C_GetTask=26, C_QueryTasks=28)
// ============================================================================

ListTasksPagedRequest :: struct {
	conv_id:        ConversationID,
	status_mask:    u8,
	limit:          u16,
	has_cursor:     bool,
	cursor_sort_at: i64,
	cursor_task_id: TaskID,
	correlation_id: u32,
}

parseListTasksPagedRequest :: proc(data: []byte) -> (result: ListTasksPagedRequest, err: ProtocolParseError) {
	if len(data) < 16 do return result, .TooShort
	conv_id, conv_ok := endian.get_u64(data[0:], .Big)
	if !conv_ok do return result, .TooShort
	result.conv_id = ConversationID(conv_id)
	result.status_mask = data[8]
	if result.status_mask == 0 || result.status_mask & ~u8(0x1f) != 0 do return result, .InvalidContentType
	limit, limit_ok := endian.get_u16(data[9:], .Big)
	if !limit_ok do return result, .TooShort
	result.limit = limit
	if result.limit == 0 || result.limit > MAX_TASK_PAGE_SIZE do return result, .TooMany
	if data[11] > 1 do return result, .InvalidContentType
	result.has_cursor = data[11] == 1
	expected := result.has_cursor ? 32 : 16
	if len(data) < expected do return result, .TooShort
	if len(data) != expected do return result, .ContentLengthMismatch
	offset := 12
	if result.has_cursor {
		cursor_sort_at, sort_ok := endian.get_i64(data[offset:], .Big)
		if !sort_ok do return result, .TooShort
		result.cursor_sort_at = cursor_sort_at
		offset += 8
		cursor_task_id, task_ok := endian.get_u64(data[offset:], .Big)
		if !task_ok do return result, .TooShort
		result.cursor_task_id = TaskID(cursor_task_id)
		offset += 8
	}
	correlation_id, correlation_ok := endian.get_u32(data[offset:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id
	return result, nil
}

TaskQuerySort :: enum u8 {
	Priority,
	Status,
	Assignee,
	DueAt,
	CreatedAt,
	Title,
	Color,
	Project,
}

TaskQueryRequest :: struct {
	conv_id:        ConversationID,
	status_mask:    u8,
	limit:          u16,
	sort:           TaskQuerySort,
	descending:     bool,
	color:          u8,
	blocked:        u8,
	overdue_before: i64,
	has_assignee:   bool,
	assignee:       []byte,
	has_project:    bool,
	project:        []byte,
	has_cursor:     bool,
	cursor_number:  i64,
	cursor_text:    []byte,
	cursor_task_id: TaskID,
	correlation_id: u32,
}

parseTaskQueryRequest :: proc(data: []byte) -> (result: TaskQueryRequest, err: ProtocolParseError) {
	if len(data) < 52 do return result, .TooShort
	conv, ok := endian.get_u64(data, .Big); if !ok do return result, .TooShort
	result.conv_id = ConversationID(conv); result.status_mask = data[8]
	if result.status_mask == 0 || result.status_mask & ~u8(0x0f) != 0 do return result, .InvalidValue
	limit, limit_ok := endian.get_u16(data[9:], .Big); if !limit_ok do return result, .TooShort
	result.limit = limit; if limit == 0 || limit > MAX_TASK_PAGE_SIZE do return result, .TooMany
	if data[11] > u8(TaskQuerySort.Project) || data[12] > 1 || (data[13] != 255 && data[13] > 5) || data[14] > 2 do return result, .InvalidValue
	result.sort = TaskQuerySort(data[11]); result.descending = data[12] == 1; result.color = data[13]; result.blocked = data[14]
	overdue, overdue_ok := endian.get_i64(data[15:], .Big); if !overdue_ok do return result, .TooShort
	result.overdue_before = overdue
	offset := 23
	if data[offset] > 1 do return result, .InvalidValue
	result.has_assignee = data[offset] == 1; offset += 1
	assignee_len, assignee_ok := endian.get_u16(data[offset:], .Big); if !assignee_ok do return result, .TooShort
	offset += 2; if int(assignee_len) > MAX_ASSIGNEE_LENGTH || offset + int(assignee_len) > len(data) do return result, .InvalidValue
	result.assignee = data[offset:offset + int(assignee_len)]; offset += int(assignee_len)
	if !utf8.valid_string(string(result.assignee)) || (!result.has_assignee && len(result.assignee) != 0) do return result, .InvalidValue
	if offset >= len(data) do return result, .TooShort
	if data[offset] > 1 do return result, .InvalidValue
	result.has_project = data[offset] == 1; offset += 1
	project_len, project_ok := endian.get_u16(data[offset:], .Big); if !project_ok do return result, .TooShort
	offset += 2; if int(project_len) > MAX_PROJECT_LENGTH || offset + int(project_len) > len(data) do return result, .InvalidValue
	result.project = data[offset:offset + int(project_len)]; offset += int(project_len)
	if !utf8.valid_string(string(result.project)) || (!result.has_project && len(result.project) != 0) do return result, .InvalidValue
	if offset >= len(data) || data[offset] > 1 do return result, .InvalidValue
	result.has_cursor = data[offset] == 1; offset += 1
	if offset + 8 + 2 > len(data) do return result, .TooShort
	result.cursor_number, ok = endian.get_i64(data[offset:], .Big); if !ok do return result, .TooShort
	offset += 8; cursor_len, cursor_len_ok := endian.get_u16(data[offset:], .Big); if !cursor_len_ok do return result, .TooShort
	offset += 2; if int(cursor_len) > MAX_TASK_TITLE_LENGTH || offset + int(cursor_len) + 12 > len(data) do return result, .InvalidValue
	result.cursor_text = data[offset:offset + int(cursor_len)]; offset += int(cursor_len)
	if !utf8.valid_string(string(result.cursor_text)) do return result, .InvalidValue
	cursor_id, cursor_ok := endian.get_u64(data[offset:], .Big); if !cursor_ok do return result, .TooShort
	result.cursor_task_id = TaskID(cursor_id); offset += 8
	if !result.has_cursor && (result.cursor_number != 0 || len(result.cursor_text) != 0 || result.cursor_task_id != 0) do return result, .InvalidValue
	textual_sort := result.sort == .Assignee || result.sort == .Title || result.sort == .Project
	if result.has_cursor && ((textual_sort && result.cursor_number != 0) || (!textual_sort && len(result.cursor_text) != 0)) do return result, .InvalidValue
	result.correlation_id, ok = endian.get_u32(data[offset:], .Big); if !ok do return result, .TooShort
	offset += 4; if offset != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

ListTaskProjectsRequest :: struct {
	conv_id:        ConversationID,
	correlation_id: u32,
}

parseListTaskProjectsRequest :: proc(data: []byte) -> (result: ListTaskProjectsRequest, err: ProtocolParseError) {
	if len(data) < 12 do return result, .TooShort
	if len(data) != 12 do return result, .ContentLengthMismatch
	conv, a := endian.get_u64(data, .Big); correlation, b := endian.get_u32(data[8:], .Big)
	if !a || !b do return result, .TooShort
	result = {ConversationID(conv), correlation}; return result, nil
}

GetTaskRequest :: struct {
	conv_id:        ConversationID,
	task_id:        TaskID,
	correlation_id: u32,
}

parseGetTaskRequest :: proc(data: []byte) -> (result: GetTaskRequest, err: ProtocolParseError) {
	if len(data) < 20 do return result, .TooShort
	if len(data) != 20 do return result, .ContentLengthMismatch
	conv_id, conv_ok := endian.get_u64(data[0:], .Big)
	task_id, task_ok := endian.get_u64(data[8:], .Big)
	correlation_id, correlation_ok := endian.get_u32(data[16:], .Big)
	if !conv_ok || !task_ok || !correlation_ok do return result, .TooShort
	result.conv_id = ConversationID(conv_id)
	result.task_id = TaskID(task_id)
	result.correlation_id = correlation_id
	return result, nil
}

TaskListPage :: struct {
	conv_id:             ConversationID,
	success:             bool,
	tasks:               []Task,
	has_more:            bool,
	next_cursor_sort_at: i64,
	next_cursor_task_id: TaskID,
	total_count:         u32,
	error:               []byte,
	correlation_id:      u32,
}

TaskQueryPage :: struct {
	conv_id:             ConversationID,
	success:             bool,
	tasks:               []Task,
	has_more:            bool,
	next_cursor_number:  i64,
	next_cursor_task_id: TaskID,
	next_cursor_text:    []byte,
	total_count:         u32,
	error:               []byte,
	correlation_id:      u32,
}

getSizeTaskQueryPage :: proc(msg: TaskQueryPage) -> int {
	size := 2 + 8 + 1 + 2 + 1 + 8 + 8 + 2 + len(msg.next_cursor_text) + 4 + 2 + len(msg.error) + 4
	for task in msg.tasks do size += getSizeTask(task)
	return size
}

serializeTaskQueryPage :: proc(msg: TaskQueryPage, buf: []byte) -> int {
	if len(msg.tasks) > MAX_TASK_PAGE_SIZE || len(msg.next_cursor_text) > MAX_TASK_TITLE_LENGTH || len(msg.error) > 65535 do return -1
	total := getSizeTaskQueryPage(msg); if len(buf) < total do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_TaskQueryPage)); endian.put_u64(buf[2:], .Big, u64(msg.conv_id)); buf[10] = msg.success ? 1 : 0
	endian.put_u16(buf[11:], .Big, u16(len(msg.tasks))); offset := 13
	for task in msg.tasks {written := serializeTask(task, buf[offset:]); if written < 0 do return -1; offset += written}
	buf[offset] = msg.has_more ? 1 : 0; offset += 1
	endian.put_i64(buf[offset:], .Big, msg.next_cursor_number); offset += 8
	endian.put_u64(buf[offset:], .Big, u64(msg.next_cursor_task_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(len(msg.next_cursor_text))); offset += 2
	copy(buf[offset:], msg.next_cursor_text); offset += len(msg.next_cursor_text)
	endian.put_u32(buf[offset:], .Big, msg.total_count); offset += 4
	endian.put_u16(buf[offset:], .Big, u16(len(msg.error))); offset += 2; copy(buf[offset:], msg.error); offset += len(msg.error)
	endian.put_u32(buf[offset:], .Big, msg.correlation_id); return total
}

TaskProjects :: struct {
	conv_id:        ConversationID,
	projects:       []string,
	has_more:       bool, // Multiple frames share the request correlation ID.
	correlation_id: u32,
}
getSizeTaskProjects :: proc(msg: TaskProjects) -> int {size := 2 + 8 + 2 + 1 + 4; for project in msg.projects do size += 2 + len(project); return size}
// Both indexed task facets share this chunked string-list wire format.
serializeTaskProjects :: proc(msg: TaskProjects, buf: []byte, opcode: Opcode = .S_TaskProjects) -> int {
	if len(msg.projects) > 65535 do return -1
	total := getSizeTaskProjects(msg); if len(buf) < total do return -1
	endian.put_u16(
		buf,
		.Big,
		u16(opcode),
	); endian.put_u64(buf[2:], .Big, u64(msg.conv_id)); endian.put_u16(buf[10:], .Big, u16(len(msg.projects))); offset := 12
	for project in msg.projects {if len(project) > MAX_PROJECT_LENGTH do return -1; endian.put_u16(buf[offset:], .Big, u16(len(project))); offset += 2; copy(buf[offset:], project); offset += len(project)}
	buf[offset] = msg.has_more ? 1 : 0
	offset += 1
	endian.put_u32(buf[offset:], .Big, msg.correlation_id); return total
}

// ============================================================================
// Slices
// ============================================================================
//
// A slice is an explicit work stream: an asset of type `AssetType.Slice` whose
// members are the tasks, notes and files linked to it with a `MemberOf` edge.
// Nothing is derived from project labels, so a slice spans projects freely and
// one task can belong to more than one slice.

TaskSlice :: struct {
	name:             []byte, // From the record preview; never empty.
	slice_id:         AssetID, // The slice asset. Never zero.
	owner:            []byte,
	flags:            TaskSliceFlags,
	backlog:          u16,
	todo:             u16,
	in_progress:      u16,
	done:             u16,
	blocked:          u16, // Task members whose blocked_by points at another task.
	notes:            u16, // Note members.
	files:            u16, // File members.
	oldest_active_at: i64, // created_at of the oldest non-Done task member, 0 if none.
	last_moved_at:    i64, // updated_at of the most recently changed member.
}

// A slice is closed when its owner closed it. Closure is an act rather than a
// property of its members, so it is carried in flags instead of a status.
TaskSliceFlags :: distinct bit_set[TaskSliceFlag;u8]
TaskSliceFlag :: enum u8 {
	Closed,
}

TaskSliceFlag_CLOSED :: TaskSliceFlags{.Closed}

// A slice listing is paged. The register draws a window and asks for the next one
// as the reader walks it, and the CLI drains the pages it needs. A page is one
// frame: a slice row is bounded, so the largest page stays below the payload
// limit, and `has_more` says whether another page follows.
//
// The filters are the server's, the way the task query filters tasks: the owner
// is matched exactly (an empty owner with `has_owner` is the slices nobody owns),
// and the name is matched as a case-insensitive substring, because a slice is
// addressed by its name and nothing else in the listing is text. MY SLICES is
// resolved by the client into the reader's own name, exactly as MY TASKS resolves
// the assignee, so the request carries a name and never an identity.
ListTaskSlicesRequest :: struct {
	conv_id:         ConversationID,
	include_closed:  bool,
	has_owner:       bool,
	owner:           []byte,
	has_name:        bool,
	name:            []byte,
	limit:           u16,
	// The cursor is the last slice of the previous page, carried in the register's
	// own order: closure, then movement, then ID. Closure is part of the key
	// because closed slices sink below the active ones.
	has_cursor:      bool,
	cursor_closed:   bool,
	cursor_sort_at:  i64,
	cursor_slice_id: AssetID,
	correlation_id:  u32,
}

parseListTaskSlicesRequest :: proc(data: []byte) -> (result: ListTaskSlicesRequest, err: ProtocolParseError) {
	// The request body carries no opcode. conv_id, include_closed, has_owner,
	// owner_len, has_name, name_len, limit, has_cursor and the correlation id are
	// fixed; the owner and the name carry their own lengths.
	if len(data) < 22 do return result, .TooShort
	conv, conv_ok := endian.get_u64(data, .Big)
	if !conv_ok do return result, .TooShort
	result.conv_id = ConversationID(conv)
	if data[8] > 1 || data[9] > 1 do return result, .InvalidValue
	result.include_closed = data[8] == 1
	result.has_owner = data[9] == 1
	owner_len, owner_ok := endian.get_u16(data[10:], .Big)
	if !owner_ok do return result, .TooShort
	offset := 12
	if int(owner_len) > MAX_ASSIGNEE_LENGTH || offset + int(owner_len) > len(data) do return result, .InvalidValue
	result.owner = data[offset:offset + int(owner_len)]
	offset += int(owner_len)
	if !utf8.valid_string(string(result.owner)) || (!result.has_owner && len(result.owner) != 0) do return result, .InvalidValue
	if offset + 1 > len(data) || data[offset] > 1 do return result, .InvalidValue
	result.has_name = data[offset] == 1
	offset += 1
	name_len, name_ok := endian.get_u16(data[offset:], .Big)
	if !name_ok do return result, .TooShort
	offset += 2
	if int(name_len) > MAX_PROJECT_LENGTH || offset + int(name_len) > len(data) do return result, .InvalidValue
	result.name = data[offset:offset + int(name_len)]
	offset += int(name_len)
	if !utf8.valid_string(string(result.name)) || (!result.has_name && len(result.name) != 0) do return result, .InvalidValue
	limit, limit_ok := endian.get_u16(data[offset:], .Big)
	if !limit_ok do return result, .TooShort
	result.limit = limit
	offset += 2
	if result.limit == 0 || result.limit > MAX_TASK_SLICE_COUNT do return result, .TooMany
	if offset + 1 > len(data) || data[offset] > 1 do return result, .InvalidValue
	result.has_cursor = data[offset] == 1
	offset += 1
	expected := offset + (result.has_cursor ? 17 : 0) + 4
	if len(data) != expected do return result, .ContentLengthMismatch
	if result.has_cursor {
		if data[offset] > 1 do return result, .InvalidValue
		result.cursor_closed = data[offset] == 1
		offset += 1
		sort_at, sort_ok := endian.get_i64(data[offset:], .Big)
		if !sort_ok do return result, .TooShort
		result.cursor_sort_at = sort_at
		offset += 8
		slice_id, slice_ok := endian.get_u64(data[offset:], .Big)
		if !slice_ok do return result, .TooShort
		result.cursor_slice_id = AssetID(slice_id)
		offset += 8
	}
	correlation_id, correlation_ok := endian.get_u32(data[offset:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id
	return result, nil
}

TaskSliceList :: struct {
	conv_id:              ConversationID,
	success:              bool,
	slices:               []TaskSlice,
	has_more:             bool,
	// The cursor of the next page, carried in the register's own order. It is only
	// read when `has_more` is set.
	next_cursor_closed:   bool,
	next_cursor_sort_at:  i64,
	next_cursor_slice_id: AssetID,
	// Every slice the filters match, not only the ones this page carries, so the
	// register can say how much of the listing it has drawn.
	total_count:          u32,
	// Work counters are a statement about the whole workspace, so they are folded
	// on the first page of an unfiltered listing and are zero otherwise.
	assigned_tasks:       u32, // Tasks that belong to at least one slice.
	unassigned_tasks:     u32, // Tasks that belong to none, so work cannot hide.
	error:                []byte,
	correlation_id:       u32,
}

getSizeTaskSlice :: proc(slice: TaskSlice) -> int {
	size := 2 + len(slice.name) + 8 + 2 + len(slice.owner) + 1 + 2 * 7 + 8 + 8
	return size
}

getSizeTaskSliceList :: proc(msg: TaskSliceList) -> int {
	size := 2 + 8 + 1 + 2 + 1 + 1 + 8 + 8 + 4 + 4 + 4 + 2 + len(msg.error) + 4
	for slice in msg.slices do size += getSizeTaskSlice(slice)
	return size
}

serializeTaskSliceList :: proc(msg: TaskSliceList, buf: []byte) -> int {
	if len(msg.slices) > MAX_TASK_SLICE_COUNT || len(msg.error) > 65535 || len(msg.slices) > 65535 {
		return -1
	}
	total := getSizeTaskSliceList(msg)
	if len(buf) < total do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_TaskSliceList))
	endian.put_u64(buf[2:], .Big, u64(msg.conv_id))
	buf[10] = msg.success ? 1 : 0
	endian.put_u16(buf[11:], .Big, u16(len(msg.slices)))
	offset := 13
	for slice in msg.slices {
		if len(slice.name) > MAX_PROJECT_LENGTH || len(slice.owner) > MAX_ASSIGNEE_LENGTH do return -1
		endian.put_u16(buf[offset:], .Big, u16(len(slice.name))); offset += 2
		copy(buf[offset:], slice.name); offset += len(slice.name)
		endian.put_u64(buf[offset:], .Big, u64(slice.slice_id)); offset += 8
		endian.put_u16(buf[offset:], .Big, u16(len(slice.owner))); offset += 2
		copy(buf[offset:], slice.owner); offset += len(slice.owner)
		buf[offset] = transmute(u8)slice.flags; offset += 1
		endian.put_u16(buf[offset:], .Big, slice.backlog); offset += 2
		endian.put_u16(buf[offset:], .Big, slice.todo); offset += 2
		endian.put_u16(buf[offset:], .Big, slice.in_progress); offset += 2
		endian.put_u16(buf[offset:], .Big, slice.done); offset += 2
		endian.put_u16(buf[offset:], .Big, slice.blocked); offset += 2
		endian.put_u16(buf[offset:], .Big, slice.notes); offset += 2
		endian.put_u16(buf[offset:], .Big, slice.files); offset += 2
		endian.put_i64(buf[offset:], .Big, slice.oldest_active_at); offset += 8
		endian.put_i64(buf[offset:], .Big, slice.last_moved_at); offset += 8
	}
	buf[offset] = msg.has_more ? 1 : 0; offset += 1
	buf[offset] = msg.next_cursor_closed ? 1 : 0; offset += 1
	endian.put_i64(buf[offset:], .Big, msg.next_cursor_sort_at); offset += 8
	endian.put_u64(buf[offset:], .Big, u64(msg.next_cursor_slice_id)); offset += 8
	endian.put_u32(buf[offset:], .Big, msg.total_count); offset += 4
	endian.put_u32(buf[offset:], .Big, msg.assigned_tasks); offset += 4
	endian.put_u32(buf[offset:], .Big, msg.unassigned_tasks); offset += 4
	endian.put_u16(buf[offset:], .Big, u16(len(msg.error))); offset += 2
	copy(buf[offset:], msg.error); offset += len(msg.error)
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	return total
}

parseTaskSliceList :: proc(data: []byte, allocator := context.allocator) -> (TaskSliceList, ProtocolParseError) {
	result := TaskSliceList{}
	// An empty page is 2 + 8 + 1 + 2 + 1 + 1 + 8 + 8 + 4 + 4 + 4 + 2 + 4 bytes.
	if len(data) < 49 do return result, .TooShort
	if get_opcode(data) != .S_TaskSliceList do return result, .InvalidOpcode
	conv, _ := endian.get_u64(data[2:], .Big)
	result.conv_id = ConversationID(conv)
	result.success = data[10] != 0
	count, _ := endian.get_u16(data[11:], .Big)
	if int(count) > MAX_TASK_SLICE_COUNT do return result, .TooMany
	offset := 13
	if count > 0 {
		result.slices = make([]TaskSlice, int(count), allocator)
		for i in 0 ..< int(count) {
			if offset + 2 > len(data) do return result, .TooShort
			name_len, _ := endian.get_u16(data[offset:], .Big)
			offset += 2
			if int(name_len) > MAX_PROJECT_LENGTH do return result, .ContentLengthExceedsMax
			if offset + int(name_len) > len(data) do return result, .TooShort
			result.slices[i].name = data[offset:offset + int(name_len)]
			offset += int(name_len)
			if offset + 10 > len(data) do return result, .TooShort
			id, _ := endian.get_u64(data[offset:], .Big)
			result.slices[i].slice_id = AssetID(id)
			offset += 8
			owner_len, _ := endian.get_u16(data[offset:], .Big)
			offset += 2
			if int(owner_len) > MAX_ASSIGNEE_LENGTH do return result, .ContentLengthExceedsMax
			if offset + int(owner_len) > len(data) do return result, .TooShort
			result.slices[i].owner = data[offset:offset + int(owner_len)]
			offset += int(owner_len)
			if offset + 1 > len(data) do return result, .TooShort
			result.slices[i].flags = transmute(TaskSliceFlags)data[offset]
			offset += 1
			if offset + 14 + 16 > len(data) do return result, .TooShort
			result.slices[i].backlog, _ = endian.get_u16(data[offset:], .Big); offset += 2
			result.slices[i].todo, _ = endian.get_u16(data[offset:], .Big); offset += 2
			result.slices[i].in_progress, _ = endian.get_u16(data[offset:], .Big); offset += 2
			result.slices[i].done, _ = endian.get_u16(data[offset:], .Big); offset += 2
			result.slices[i].blocked, _ = endian.get_u16(data[offset:], .Big); offset += 2
			result.slices[i].notes, _ = endian.get_u16(data[offset:], .Big); offset += 2
			result.slices[i].files, _ = endian.get_u16(data[offset:], .Big); offset += 2
			result.slices[i].oldest_active_at, _ = endian.get_i64(data[offset:], .Big); offset += 8
			result.slices[i].last_moved_at, _ = endian.get_i64(data[offset:], .Big); offset += 8
		}
	}
	if offset + 1 + 1 + 8 + 8 + 4 + 4 + 4 + 2 > len(data) do return result, .TooShort
	result.has_more = data[offset] != 0; offset += 1
	if data[offset] > 1 do return result, .InvalidContentType
	result.next_cursor_closed = data[offset] == 1; offset += 1
	result.next_cursor_sort_at, _ = endian.get_i64(data[offset:], .Big); offset += 8
	next_cursor_slice_id, _ := endian.get_u64(data[offset:], .Big)
	result.next_cursor_slice_id = AssetID(next_cursor_slice_id); offset += 8
	result.total_count, _ = endian.get_u32(data[offset:], .Big); offset += 4
	result.assigned_tasks, _ = endian.get_u32(data[offset:], .Big); offset += 4
	result.unassigned_tasks, _ = endian.get_u32(data[offset:], .Big); offset += 4
	error_len, _ := endian.get_u16(data[offset:], .Big); offset += 2
	if offset + int(error_len) + 4 > len(data) do return result, .TooShort
	result.error = data[offset:offset + int(error_len)]; offset += int(error_len)
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big); offset += 4
	if offset != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

// task_slice_open_count is the number of task members that are not Done. A
// slice's open count is what its WIP load is read from, so it is derived rather
// than stored.
task_slice_open_count :: proc(slice: TaskSlice) -> u16 {
	return slice.backlog + slice.todo + slice.in_progress
}

// task_slice_member_count is every member the slice carries: tasks with a
// status, notes and files. It is widened because the counters are independent
// and their sum is not bounded by any single one of them.
task_slice_member_count :: proc(slice: TaskSlice) -> int {
	return int(slice.backlog) + int(slice.todo) + int(slice.in_progress) + int(slice.done) + int(slice.notes) + int(slice.files)
}

getSizeTaskListPage :: proc(msg: TaskListPage) -> int {
	size := 2 + 8 + 1 + 2 + 1 + 8 + 8 + 4 + 2 + len(msg.error) + 4
	for task in msg.tasks do size += getSizeTask(task)
	return size
}

serializeTaskListPage :: proc(msg: TaskListPage, buf: []byte) -> int {
	if len(msg.tasks) > MAX_TASK_PAGE_SIZE || len(msg.error) > 65535 do return -1
	total_size := getSizeTaskListPage(msg)
	if len(buf) < total_size do return -1
	endian.put_u16(buf[0:], .Big, u16(Opcode.S_TaskListPage))
	endian.put_u64(buf[2:], .Big, u64(msg.conv_id))
	buf[10] = msg.success ? 1 : 0
	endian.put_u16(buf[11:], .Big, u16(len(msg.tasks)))
	offset := 13
	for task in msg.tasks {
		written := serializeTask(task, buf[offset:])
		if written < 0 do return -1
		offset += written
	}
	buf[offset] = msg.has_more ? 1 : 0
	offset += 1
	endian.put_i64(buf[offset:], .Big, msg.next_cursor_sort_at)
	offset += 8
	endian.put_u64(buf[offset:], .Big, u64(msg.next_cursor_task_id))
	offset += 8
	endian.put_u32(buf[offset:], .Big, msg.total_count)
	offset += 4
	endian.put_u16(buf[offset:], .Big, u16(len(msg.error)))
	offset += 2
	copy(buf[offset:], msg.error)
	offset += len(msg.error)
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	return total_size
}

parseTaskListPage :: proc(data: []byte, tasks: []Task, attachments: []Attachment) -> (result: TaskListPage, err: ProtocolParseError) {
	if len(data) < 40 do return result, .TooShort
	if get_opcode(data) != .S_TaskListPage do return result, .InvalidOpcode
	conv_id, conv_ok := endian.get_u64(data[2:], .Big)
	if !conv_ok do return result, .TooShort
	result.conv_id = ConversationID(conv_id)
	if data[10] > 1 do return result, .InvalidContentType
	result.success = data[10] == 1
	count, count_ok := endian.get_u16(data[11:], .Big)
	if !count_ok do return result, .TooShort
	if count > MAX_TASK_PAGE_SIZE || int(count) > len(tasks) do return result, .TooMany
	result.tasks = tasks[:count]
	offset := 13
	attachment_pos := 0
	for i in 0 ..< int(count) {
		task, next_offset, used_attachments, parse_err := parse_task_from_payload(data, offset, attachments[attachment_pos:])
		if parse_err != nil do return result, parse_err
		tasks[i] = task
		offset = next_offset
		attachment_pos += used_attachments
	}
	if offset + 1 + 8 + 8 + 4 + 2 + 4 > len(data) do return result, .TooShort
	if data[offset] > 1 do return result, .InvalidContentType
	result.has_more = data[offset] == 1
	offset += 1
	next_sort_at, sort_ok := endian.get_i64(data[offset:], .Big)
	if !sort_ok do return result, .TooShort
	result.next_cursor_sort_at = next_sort_at
	offset += 8
	next_task_id, task_ok := endian.get_u64(data[offset:], .Big)
	if !task_ok do return result, .TooShort
	result.next_cursor_task_id = TaskID(next_task_id)
	offset += 8
	total_count, total_ok := endian.get_u32(data[offset:], .Big)
	if !total_ok do return result, .TooShort
	result.total_count = total_count
	offset += 4
	error_len_raw, error_ok := endian.get_u16(data[offset:], .Big)
	if !error_ok do return result, .TooShort
	error_len := int(error_len_raw)
	offset += 2
	if offset + error_len + 4 != len(data) do return result, .ContentLengthMismatch
	result.error = data[offset:offset + error_len]
	offset += error_len
	correlation_id, correlation_ok := endian.get_u32(data[offset:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id
	return result, nil
}

TaskFull :: struct {
	conv_id:        ConversationID,
	success:        bool,
	has_task:       bool,
	task:           Task,
	error:          []byte,
	correlation_id: u32,
}

getSizeTaskFull :: proc(msg: TaskFull) -> int {
	return 2 + 8 + 1 + 1 + (msg.has_task ? getSizeTask(msg.task) : 0) + 2 + len(msg.error) + 4
}

serializeTaskFull :: proc(msg: TaskFull, buf: []byte) -> int {
	if len(msg.error) > 65535 do return -1
	total_size := getSizeTaskFull(msg)
	if len(buf) < total_size do return -1
	endian.put_u16(buf[0:], .Big, u16(Opcode.S_TaskFull))
	endian.put_u64(buf[2:], .Big, u64(msg.conv_id))
	buf[10] = msg.success ? 1 : 0
	buf[11] = msg.has_task ? 1 : 0
	offset := 12
	if msg.has_task {
		written := serializeTask(msg.task, buf[offset:])
		if written < 0 do return -1
		offset += written
	}
	endian.put_u16(buf[offset:], .Big, u16(len(msg.error)))
	offset += 2
	copy(buf[offset:], msg.error)
	offset += len(msg.error)
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	return total_size
}

parseTaskFull :: proc(data: []byte, attachments: []Attachment) -> (result: TaskFull, err: ProtocolParseError) {
	if len(data) < 18 do return result, .TooShort
	if get_opcode(data) != .S_TaskFull do return result, .InvalidOpcode
	conv_id, conv_ok := endian.get_u64(data[2:], .Big)
	if !conv_ok do return result, .TooShort
	result.conv_id = ConversationID(conv_id)
	if data[10] > 1 || data[11] > 1 do return result, .InvalidContentType
	result.success = data[10] == 1
	result.has_task = data[11] == 1
	offset := 12
	if result.has_task {
		task, next_offset, _, parse_err := parse_task_from_payload(data, offset, attachments)
		if parse_err != nil do return result, parse_err
		result.task = task
		offset = next_offset
	}
	if offset + 2 > len(data) do return result, .TooShort
	error_len_raw, error_ok := endian.get_u16(data[offset:], .Big)
	if !error_ok do return result, .TooShort
	error_len := int(error_len_raw)
	offset += 2
	if offset + error_len + 4 != len(data) do return result, .ContentLengthMismatch
	result.error = data[offset:offset + error_len]
	offset += error_len
	correlation_id, correlation_ok := endian.get_u32(data[offset:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id
	return result, nil
}

// ============================================================================
// Task Serialization Helper
// ============================================================================

getSizeTask :: proc(task: Task) -> int {
	size :=
		(8 +
			8 +
			2 +
			len(task.title) +
			2 +
			len(task.description) +
			1 +
			2 +
			2 +
			len(task.assignee) +
			1 +
			1 +
			2 +
			len(task.created_by) +
			8 +
			8 +
			2 +
			len(task.external_ref) +
			8 +
			8 +
			8 +
			2 +
			len(task.completed_by) +
			2 +
			len(task.project))

	// Add attachments size
	size += 2 // attachment count
	for att in task.attachments {
		size += 2 + len(att.file_id) // file_id
		size += 2 + len(att.filename) // filename
		size += 8 // size (u64)
		size += 2 + len(att.mime_type) // mime_type
		size += 8 // uploaded_at
	}

	return size
}

serializeTask :: proc(task: Task, buf: []byte) -> int {
	if len(task.title) > MAX_TASK_TITLE_LENGTH {
		log.debugf("Task title length %v exceeds maximum %v", len(task.title), MAX_TASK_TITLE_LENGTH)
		return -1
	}
	if len(task.description) > MAX_TASK_DESCRIPTION_LENGTH {
		log.debugf("Task description length %v exceeds maximum %v", len(task.description), MAX_TASK_DESCRIPTION_LENGTH)
		return -1
	}
	if len(task.assignee) > MAX_ASSIGNEE_LENGTH {
		log.errorf("Task assignee length %v exceeds maximum %v", len(task.assignee), MAX_ASSIGNEE_LENGTH)
		return -1
	}
	if len(task.external_ref) > MAX_EXTERNAL_REF_LENGTH {
		log.errorf("Task external ref length %v exceeds maximum %v", len(task.external_ref), MAX_EXTERNAL_REF_LENGTH)
		return -1
	}
	if len(task.created_by) > MAX_USERNAME_LENGTH {
		log.errorf("Task created_by length %v exceeds maximum %v", len(task.created_by), MAX_USERNAME_LENGTH)
		return -1
	}
	if len(task.completed_by) > MAX_USERNAME_LENGTH {
		log.errorf("Task completed_by length %v exceeds maximum %v", len(task.completed_by), MAX_USERNAME_LENGTH)
		return -1
	}
	if len(task.project) > MAX_PROJECT_LENGTH {
		log.errorf("Task project length %v exceeds maximum %v", len(task.project), MAX_PROJECT_LENGTH)
		return -1
	}
	if len(task.attachments) > MAX_ATTACHMENTS_PER_TASK {
		log.errorf("Task attachment count %v exceeds maximum %v", len(task.attachments), MAX_ATTACHMENTS_PER_TASK)
		return -1
	}

	for att in task.attachments {
		if len(att.file_id) > MAX_FILE_ID_LENGTH {
			log.errorf("Attachment file_id length %v exceeds maximum %v", len(att.file_id), MAX_FILE_ID_LENGTH)
			return -1
		}
		if len(att.filename) > MAX_FILENAME_LENGTH {
			log.errorf("Attachment filename length %v exceeds maximum %v", len(att.filename), MAX_FILENAME_LENGTH)
			return -1
		}
		if len(att.mime_type) > MAX_MIME_TYPE_LENGTH {
			log.errorf("Attachment mime_type length %v exceeds maximum %v", len(att.mime_type), MAX_MIME_TYPE_LENGTH)
			return -1
		}
	}

	offset := 0

	endian.put_u64(buf[offset:], .Big, u64(task.id))
	offset += 8

	endian.put_u64(buf[offset:], .Big, u64(task.conv_id))
	offset += 8

	title_len := len(task.title)
	endian.put_u16(buf[offset:], .Big, u16(title_len))
	offset += 2
	if title_len > 0 {
		copy(buf[offset:], task.title)
		offset += title_len
	}

	desc_len := len(task.description)
	endian.put_u16(buf[offset:], .Big, u16(desc_len))
	offset += 2
	if desc_len > 0 {
		copy(buf[offset:], task.description)
		offset += desc_len
	}

	buf[offset] = u8(task.status)
	offset += 1

	endian.put_u16(buf[offset:], .Big, task.order_index)
	offset += 2

	assignee_len := len(task.assignee)
	endian.put_u16(buf[offset:], .Big, u16(assignee_len))
	offset += 2
	if assignee_len > 0 {
		copy(buf[offset:], task.assignee)
		offset += assignee_len
	}

	buf[offset] = task.priority
	offset += 1

	buf[offset] = u8(task.color)
	offset += 1

	created_by_len := len(task.created_by)
	endian.put_u16(buf[offset:], .Big, u16(created_by_len))
	offset += 2
	if created_by_len > 0 {
		copy(buf[offset:], task.created_by)
		offset += created_by_len
	}

	endian.put_u64(buf[offset:], .Big, cast(u64)task.created_at)
	offset += 8

	endian.put_u64(buf[offset:], .Big, cast(u64)task.updated_at)
	offset += 8

	ext_ref_len := len(task.external_ref)
	endian.put_u16(buf[offset:], .Big, u16(ext_ref_len))
	offset += 2
	if ext_ref_len > 0 {
		copy(buf[offset:], task.external_ref)
		offset += ext_ref_len
	}

	endian.put_u64(buf[offset:], .Big, cast(u64)task.due_at)
	offset += 8

	endian.put_u64(buf[offset:], .Big, u64(task.blocked_by))
	offset += 8

	endian.put_u64(buf[offset:], .Big, cast(u64)task.completed_at)
	offset += 8

	completed_by_len := len(task.completed_by)
	endian.put_u16(buf[offset:], .Big, u16(completed_by_len))
	offset += 2
	if completed_by_len > 0 {
		copy(buf[offset:], task.completed_by)
		offset += completed_by_len
	}

	project_len := len(task.project)
	endian.put_u16(buf[offset:], .Big, u16(project_len))
	offset += 2
	if project_len > 0 {
		copy(buf[offset:], task.project)
		offset += project_len
	}

	// Serialize attachments
	endian.put_u16(buf[offset:], .Big, u16(len(task.attachments)))
	offset += 2

	for att in task.attachments {
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

	return offset
}

parse_u16_bytes_from_payload :: proc(data: []byte, offset: int) -> (value: []byte, next_offset: int, err: ProtocolParseError) {
	if offset + 2 > len(data) do return nil, offset, .TooShort
	value_len_raw, value_len_ok := endian.get_u16(data[offset:], .Big)
	if !value_len_ok do return nil, offset, .TooShort
	next_offset = offset + 2
	value_len := int(value_len_raw)
	if next_offset + value_len > len(data) do return nil, offset, .TooShort
	value = data[next_offset:next_offset + value_len]
	next_offset += value_len
	return value, next_offset, nil
}

parse_task_from_payload :: proc(
	data: []byte,
	offset: int,
	attachments: []Attachment,
) -> (
	task: Task,
	next_offset: int,
	used_attachments: int,
	err: ProtocolParseError,
) {
	pos := offset
	if pos + 16 > len(data) do return {}, offset, 0, .TooShort

	task_id_raw, task_id_ok := endian.get_u64(data[pos:], .Big)
	if !task_id_ok do return {}, offset, 0, .TooShort
	task.id = TaskID(task_id_raw)
	pos += 8

	conv_id_raw, conv_id_ok := endian.get_u64(data[pos:], .Big)
	if !conv_id_ok do return {}, offset, 0, .TooShort
	task.conv_id = ConversationID(conv_id_raw)
	pos += 8

	task.title, pos, err = parse_u16_bytes_from_payload(data, pos)
	if err != nil do return {}, offset, 0, err
	task.description, pos, err = parse_u16_bytes_from_payload(data, pos)
	if err != nil do return {}, offset, 0, err

	if pos + 3 > len(data) do return {}, offset, 0, .TooShort
	task.status = TaskStatus(data[pos])
	pos += 1
	task.order_index, _ = endian.get_u16(data[pos:], .Big)
	pos += 2

	task.assignee, pos, err = parse_u16_bytes_from_payload(data, pos)
	if err != nil do return {}, offset, 0, err
	if pos + 2 > len(data) do return {}, offset, 0, .TooShort
	task.priority = data[pos]
	pos += 1
	task.color = TaskColor(data[pos])
	pos += 1

	task.created_by, pos, err = parse_u16_bytes_from_payload(data, pos)
	if err != nil do return {}, offset, 0, err
	if pos + 16 > len(data) do return {}, offset, 0, .TooShort
	created_at_raw, _ := endian.get_u64(data[pos:], .Big)
	task.created_at = i64(created_at_raw)
	pos += 8
	updated_at_raw, _ := endian.get_u64(data[pos:], .Big)
	task.updated_at = i64(updated_at_raw)
	pos += 8

	task.external_ref, pos, err = parse_u16_bytes_from_payload(data, pos)
	if err != nil do return {}, offset, 0, err
	if pos + 24 > len(data) do return {}, offset, 0, .TooShort
	due_at_raw, _ := endian.get_u64(data[pos:], .Big)
	task.due_at = i64(due_at_raw)
	pos += 8
	blocked_by_raw, _ := endian.get_u64(data[pos:], .Big)
	task.blocked_by = TaskID(blocked_by_raw)
	pos += 8
	completed_at_raw, _ := endian.get_u64(data[pos:], .Big)
	task.completed_at = i64(completed_at_raw)
	pos += 8

	task.completed_by, pos, err = parse_u16_bytes_from_payload(data, pos)
	if err != nil do return {}, offset, 0, err
	task.project, pos, err = parse_u16_bytes_from_payload(data, pos)
	if err != nil do return {}, offset, 0, err

	if pos + 2 > len(data) do return {}, offset, 0, .TooShort
	attachment_count_raw, attachment_count_ok := endian.get_u16(data[pos:], .Big)
	if !attachment_count_ok do return {}, offset, 0, .TooShort
	pos += 2
	attachment_count := int(attachment_count_raw)
	if attachment_count > len(attachments) do return {}, offset, 0, .TooMany
	task.attachments = attachments[:attachment_count]

	for i := 0; i < attachment_count; i += 1 {
		att: Attachment
		att.file_id, pos, err = parse_u16_bytes_from_payload(data, pos)
		if err != nil do return {}, offset, 0, err
		att.filename, pos, err = parse_u16_bytes_from_payload(data, pos)
		if err != nil do return {}, offset, 0, err
		if pos + 8 > len(data) do return {}, offset, 0, .TooShort
		att.size, _ = endian.get_u64(data[pos:], .Big)
		pos += 8
		att.mime_type, pos, err = parse_u16_bytes_from_payload(data, pos)
		if err != nil do return {}, offset, 0, err
		if pos + 8 > len(data) do return {}, offset, 0, .TooShort
		uploaded_at_raw, _ := endian.get_u64(data[pos:], .Big)
		att.uploaded_at = i64(uploaded_at_raw)
		pos += 8
		attachments[i] = att
	}

	return task, pos, attachment_count, nil
}
