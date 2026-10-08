package protocol

import "core:encoding/endian"

// ============================================================================
// Client-side serialization functions
// These are used by clients to send messages to the server
// ============================================================================

// ----------------------------------------------------------------------------
// C_SendMessage (opcode 1)
// ----------------------------------------------------------------------------

getSizeSendMessageRequest :: proc(content: []byte) -> int {
	return 2 + 8 + 4 + 1 + 2 + len(content)
}

serializeSendMessageRequest :: proc(conv_id: ConversationID, client_req_id: u32, content_type: MessageContentType, content: []byte, buf: []byte) -> int {
	content_len := len(content)
	total_size := getSizeSendMessageRequest(content)

	if len(buf) < total_size {
		return -1
	}
	if content_len > MAX_ALLOWED_CONTENT_LENGTH {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_SendMessage))

	payload := buf[2:]
	offset := 0

	endian.put_u64(payload[offset:], .Big, u64(conv_id))
	offset += 8

	endian.put_u32(payload[offset:], .Big, client_req_id)
	offset += 4

	payload[offset] = u8(content_type)
	offset += 1

	endian.put_u16(payload[offset:], .Big, u16(content_len))
	offset += 2

	if content_len > 0 {
		copy(payload[offset:], content)
	}

	return total_size
}

// ----------------------------------------------------------------------------
// C_SubscribeConvs (opcode 2)
// ----------------------------------------------------------------------------

getSizeSubscribeConvsRequest :: proc(count: int) -> int {
	return 2 + 2 + count * size_of(ConversationID)
}

serializeSubscribeConvsRequest :: proc(conv_ids: []ConversationID, buf: []byte) -> int {
	count := len(conv_ids)
	total_size := getSizeSubscribeConvsRequest(count)

	if len(buf) < total_size {
		return -1
	}
	if count > MAX_SUBSCRIBE_CONVS {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_SubscribeConvs))
	endian.put_u16(buf[2:4], .Big, u16(count))

	offset := 4
	for conv_id in conv_ids {
		endian.put_u64(buf[offset:], .Big, u64(conv_id))
		offset += 8
	}

	return total_size
}

// ----------------------------------------------------------------------------
// C_UnsubscribeConvs (opcode 3)
// ----------------------------------------------------------------------------

getSizeUnsubscribeConvsRequest :: proc(count: int) -> int {
	return 2 + 2 + count * size_of(ConversationID) + size_of(u32)
}

serializeUnsubscribeConvsRequest :: proc(conv_ids: []ConversationID, buf: []byte, correlation_id: u32 = 0) -> int {
	count := len(conv_ids)
	total_size := getSizeUnsubscribeConvsRequest(count)

	if len(buf) < total_size {
		return -1
	}
	if count > MAX_SUBSCRIBE_CONVS {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_UnsubscribeConvs))
	endian.put_u16(buf[2:4], .Big, u16(count))

	offset := 4
	for conv_id in conv_ids {
		endian.put_u64(buf[offset:], .Big, u64(conv_id))
		offset += 8
	}
	endian.put_u32(buf[offset:], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_Stats (opcode 8)
// ----------------------------------------------------------------------------

getSizeStatsRequest :: proc() -> int {
	return 2 + 8
}

serializeStatsRequest :: proc(timestamp: i64, buf: []byte) -> int {
	total_size := getSizeStatsRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_Stats))
	endian.put_u64(buf[2:], .Big, cast(u64)timestamp)

	return total_size
}

// ----------------------------------------------------------------------------
// C_Ping (opcode 19)
// ----------------------------------------------------------------------------

getSizePingRequest :: proc() -> int {
	return 2 + 8
}

serializePingRequest :: proc(timestamp: i64, buf: []byte) -> int {
	total_size := getSizePingRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_Ping))
	endian.put_u64(buf[2:], .Big, cast(u64)timestamp)

	return total_size
}

// ----------------------------------------------------------------------------
// C_CreateTask (opcode 20)
// ----------------------------------------------------------------------------

getSizeCreateTaskRequest :: proc(req: CreateTaskRequest) -> int {
	size := 2 + 8 + 2 + len(req.title) + 2 + len(req.description) + 1 + 1 + 2 + len(req.external_ref) + 8 + 2 + 1 + 4 + 2 + len(req.project)
	for att in req.attachments {
		size += 2 + len(att.file_id) + 2 + len(att.filename) + 8 + 2 + len(att.mime_type) + 8
	}
	return size
}

serializeCreateTaskRequest :: proc(req: CreateTaskRequest, buf: []byte) -> int {
	total_size := getSizeCreateTaskRequest(req)

	if len(buf) < total_size {
		return -1
	}
	if len(req.title) > MAX_TASK_TITLE_LENGTH ||
	   len(req.description) > MAX_TASK_DESCRIPTION_LENGTH ||
	   len(req.external_ref) > MAX_EXTERNAL_REF_LENGTH ||
	   len(req.project) > MAX_PROJECT_LENGTH {
		return -1
	}
	if len(req.attachments) > MAX_ATTACHMENTS_PER_TASK {
		return -1
	}
	for att in req.attachments {
		if len(att.file_id) > MAX_FILE_ID_LENGTH || len(att.filename) > MAX_FILENAME_LENGTH || len(att.mime_type) > MAX_MIME_TYPE_LENGTH {
			return -1
		}
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_CreateTask)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(len(req.title))); offset += 2
	copy(buf[offset:], req.title); offset += len(req.title)
	endian.put_u16(buf[offset:], .Big, u16(len(req.description))); offset += 2
	copy(buf[offset:], req.description); offset += len(req.description)
	buf[offset] = req.priority; offset += 1
	buf[offset] = u8(req.color); offset += 1
	endian.put_u16(buf[offset:], .Big, u16(len(req.external_ref))); offset += 2
	copy(buf[offset:], req.external_ref); offset += len(req.external_ref)
	endian.put_u64(buf[offset:], .Big, u64(req.due_at)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(len(req.attachments))); offset += 2

	for att in req.attachments {
		endian.put_u16(buf[offset:], .Big, u16(len(att.file_id))); offset += 2
		copy(buf[offset:], att.file_id); offset += len(att.file_id)
		endian.put_u16(buf[offset:], .Big, u16(len(att.filename))); offset += 2
		copy(buf[offset:], att.filename); offset += len(att.filename)
		endian.put_u64(buf[offset:], .Big, att.size); offset += 8
		endian.put_u16(buf[offset:], .Big, u16(len(att.mime_type))); offset += 2
		copy(buf[offset:], att.mime_type); offset += len(att.mime_type)
		endian.put_u64(buf[offset:], .Big, u64(att.uploaded_at)); offset += 8
	}

	buf[offset] = u8(req.status); offset += 1
	endian.put_u32(buf[offset:], .Big, req.correlation_id); offset += 4
	endian.put_u16(buf[offset:], .Big, u16(len(req.project))); offset += 2
	copy(buf[offset:], req.project); offset += len(req.project)

	return total_size
}

// ----------------------------------------------------------------------------
// C_UpdateTask (opcode 21)
// ----------------------------------------------------------------------------

getSizeUpdateTaskRequest :: proc(req: UpdateTaskRequest) -> int {
	size :=
		2 +
		8 +
		8 +
		2 +
		len(req.title) +
		2 +
		len(req.description) +
		1 +
		2 +
		len(req.assignee) +
		1 +
		1 +
		2 +
		len(req.external_ref) +
		8 +
		8 +
		2 +
		4 +
		2 +
		len(req.project)
	if !req.preserve_attachments {
		for att in req.attachments {
			size += 2 + len(att.file_id) + 2 + len(att.filename) + 8 + 2 + len(att.mime_type) + 8
		}
	}
	return size
}

serializeUpdateTaskRequest :: proc(req: UpdateTaskRequest, buf: []byte) -> int {
	total_size := getSizeUpdateTaskRequest(req)

	if len(buf) < total_size {
		return -1
	}
	if len(req.title) > MAX_TASK_TITLE_LENGTH ||
	   len(req.description) > MAX_TASK_DESCRIPTION_LENGTH ||
	   len(req.assignee) > MAX_ASSIGNEE_LENGTH ||
	   len(req.external_ref) > MAX_EXTERNAL_REF_LENGTH ||
	   len(req.project) > MAX_PROJECT_LENGTH {
		return -1
	}
	if !req.preserve_attachments && len(req.attachments) > MAX_ATTACHMENTS_PER_TASK {
		return -1
	}
	for att in req.attachments do if !req.preserve_attachments {
		if len(att.file_id) > MAX_FILE_ID_LENGTH || len(att.filename) > MAX_FILENAME_LENGTH || len(att.mime_type) > MAX_MIME_TYPE_LENGTH {
			return -1
		}
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_UpdateTask)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u64(buf[offset:], .Big, u64(req.task_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(len(req.title))); offset += 2
	copy(buf[offset:], req.title); offset += len(req.title)
	endian.put_u16(buf[offset:], .Big, u16(len(req.description))); offset += 2
	copy(buf[offset:], req.description); offset += len(req.description)
	buf[offset] = u8(req.status); offset += 1
	endian.put_u16(buf[offset:], .Big, u16(len(req.assignee))); offset += 2
	copy(buf[offset:], req.assignee); offset += len(req.assignee)
	buf[offset] = req.priority; offset += 1
	buf[offset] = u8(req.color); offset += 1
	endian.put_u16(buf[offset:], .Big, u16(len(req.external_ref))); offset += 2
	copy(buf[offset:], req.external_ref); offset += len(req.external_ref)
	endian.put_u64(buf[offset:], .Big, u64(req.due_at)); offset += 8
	endian.put_u64(buf[offset:], .Big, u64(req.blocked_by)); offset += 8
	attachment_count := req.preserve_attachments ? max(u16) : u16(len(req.attachments))
	endian.put_u16(buf[offset:], .Big, attachment_count); offset += 2

	for att in req.attachments do if !req.preserve_attachments {
		endian.put_u16(buf[offset:], .Big, u16(len(att.file_id))); offset += 2
		copy(buf[offset:], att.file_id); offset += len(att.file_id)
		endian.put_u16(buf[offset:], .Big, u16(len(att.filename))); offset += 2
		copy(buf[offset:], att.filename); offset += len(att.filename)
		endian.put_u64(buf[offset:], .Big, att.size); offset += 8
		endian.put_u16(buf[offset:], .Big, u16(len(att.mime_type))); offset += 2
		copy(buf[offset:], att.mime_type); offset += len(att.mime_type)
		endian.put_u64(buf[offset:], .Big, u64(att.uploaded_at)); offset += 8
	}

	endian.put_u32(buf[offset:], .Big, req.correlation_id); offset += 4
	endian.put_u16(buf[offset:], .Big, u16(len(req.project))); offset += 2
	copy(buf[offset:], req.project); offset += len(req.project)

	return total_size
}

// ----------------------------------------------------------------------------
// C_DeleteTask (opcode 22)
// ----------------------------------------------------------------------------

getSizeDeleteTaskRequest :: proc() -> int {
	return 2 + 8 + 8 + 4 // opcode + conv_id + task_id + correlation_id
}

serializeDeleteTaskRequest :: proc(conv_id: ConversationID, task_id: TaskID, buf: []byte, correlation_id: u32 = 0) -> int {
	total_size := getSizeDeleteTaskRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_DeleteTask))
	endian.put_u64(buf[2:10], .Big, u64(conv_id))
	endian.put_u64(buf[10:18], .Big, u64(task_id))
	endian.put_u32(buf[18:22], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_MoveTask (opcode 23)
// ----------------------------------------------------------------------------

getSizeMoveTaskRequest :: proc() -> int {
	return 2 + 8 + 8 + 1 + 1 + 2 + 4 // opcode + conv_id + task_id + status + flags + order_index + correlation_id
}

serializeMoveTaskRequest :: proc(req: MoveTaskRequest, buf: []byte) -> int {
	total_size := getSizeMoveTaskRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_MoveTask))
	endian.put_u64(buf[2:10], .Big, u64(req.conv_id))
	endian.put_u64(buf[10:18], .Big, u64(req.task_id))
	buf[18] = u8(req.status)
	buf[19] = transmute(u8)req.flags
	endian.put_u16(buf[20:22], .Big, req.order_index)
	endian.put_u32(buf[22:26], .Big, req.correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_GetTasks (opcode 24)
// ----------------------------------------------------------------------------

getSizeGetTasksRequest :: proc() -> int {
	return 2 + 8 + 4 // opcode + conv_id + correlation_id
}

serializeGetTasksRequest :: proc(req: GetTasksRequest, buf: []byte) -> int {
	total_size := getSizeGetTasksRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_GetTasks))
	endian.put_u64(buf[2:10], .Big, u64(req.conv_id))
	endian.put_u32(buf[10:14], .Big, req.correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListTasksPaged (opcode 25) / C_GetTask (opcode 26)
// ----------------------------------------------------------------------------

getSizeListTasksPagedRequest :: proc(has_cursor: bool) -> int {
	return 2 + 8 + 1 + 2 + 1 + (has_cursor ? 16 : 0) + 4
}

serializeListTasksPagedRequest :: proc(req: ListTasksPagedRequest, buf: []byte) -> int {
	total_size := getSizeListTasksPagedRequest(req.has_cursor)
	if len(buf) < total_size do return -1

	endian.put_u16(buf[0:], .Big, u16(Opcode.C_ListTasksPaged))
	endian.put_u64(buf[2:], .Big, u64(req.conv_id))
	buf[10] = req.status_mask
	endian.put_u16(buf[11:], .Big, req.limit)
	buf[13] = req.has_cursor ? 1 : 0
	offset := 14
	if req.has_cursor {
		endian.put_i64(buf[offset:], .Big, req.cursor_sort_at)
		offset += 8
		endian.put_u64(buf[offset:], .Big, u64(req.cursor_task_id))
		offset += 8
	}
	endian.put_u32(buf[offset:], .Big, req.correlation_id)
	return total_size
}

getSizeGetTaskRequest :: proc() -> int {
	return 2 + 8 + 8 + 4
}

serializeGetTaskRequest :: proc(req: GetTaskRequest, buf: []byte) -> int {
	if len(buf) < getSizeGetTaskRequest() do return -1
	endian.put_u16(buf[0:], .Big, u16(Opcode.C_GetTask))
	endian.put_u64(buf[2:], .Big, u64(req.conv_id))
	endian.put_u64(buf[10:], .Big, u64(req.task_id))
	endian.put_u32(buf[18:], .Big, req.correlation_id)
	return getSizeGetTaskRequest()
}

// ----------------------------------------------------------------------------
// C_CreateAsset (opcode 30)
// ----------------------------------------------------------------------------

getSizeCreateAssetRequest :: proc(req: CreateAssetRequest) -> int {
	return 2 + 8 + 2 + 2 + 8 + 1 + 4 + 2 + len(req.preview) + 2 + len(req.payload) + getSizeAssetAttachments(req.attachments) + 4
}

serializeCreateAssetRequest :: proc(req: CreateAssetRequest, buf: []byte) -> int {
	total_size := getSizeCreateAssetRequest(req)

	if len(buf) < total_size {
		return -1
	}
	if len(req.preview) > MAX_PREVIEW_LENGTH || len(req.payload) > MAX_PAYLOAD_LENGTH || req.payload_raw_len > MAX_PAYLOAD_LENGTH {
		return -1
	}
	if req.payload_encoding == .Plain && req.payload_raw_len != u32(len(req.payload)) {
		return -1
	}
	if req.payload_encoding != .Plain && req.payload_encoding != .Zstd {
		return -1
	}
	if !validateAssetAttachments(req.attachments) {
		return -1
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_CreateAsset)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.asset_type)); offset += 2
	endian.put_u16(buf[offset:], .Big, u16(req.parent_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.parent_id); offset += 8
	buf[offset] = u8(req.payload_encoding); offset += 1
	endian.put_u32(buf[offset:], .Big, req.payload_raw_len); offset += 4
	endian.put_u16(buf[offset:], .Big, u16(len(req.preview))); offset += 2
	copy(buf[offset:], req.preview); offset += len(req.preview)
	endian.put_u16(buf[offset:], .Big, u16(len(req.payload))); offset += 2
	copy(buf[offset:], req.payload); offset += len(req.payload)
	attachments_size := serializeAssetAttachments(req.attachments, buf[offset:])
	if attachments_size < 0 do return -1
	offset += attachments_size
	endian.put_u32(buf[offset:], .Big, req.correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_UpdateAsset (opcode 31)
// ----------------------------------------------------------------------------

getSizeUpdateAssetRequest :: proc(req: UpdateAssetRequest) -> int {
	return 2 + 8 + 8 + 1 + 4 + 2 + len(req.preview) + 2 + len(req.payload) + getSizeAssetAttachments(req.attachments) + 4
}

serializeUpdateAssetRequest :: proc(req: UpdateAssetRequest, buf: []byte) -> int {
	total_size := getSizeUpdateAssetRequest(req)

	if len(buf) < total_size {
		return -1
	}
	if len(req.preview) > MAX_PREVIEW_LENGTH || len(req.payload) > MAX_PAYLOAD_LENGTH || req.payload_raw_len > MAX_PAYLOAD_LENGTH {
		return -1
	}
	if req.payload_encoding == .Plain && req.payload_raw_len != u32(len(req.payload)) {
		return -1
	}
	if req.payload_encoding != .Plain && req.payload_encoding != .Zstd {
		return -1
	}
	if !validateAssetAttachments(req.attachments) {
		return -1
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_UpdateAsset)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u64(buf[offset:], .Big, u64(req.asset_id)); offset += 8
	buf[offset] = u8(req.payload_encoding); offset += 1
	endian.put_u32(buf[offset:], .Big, req.payload_raw_len); offset += 4
	endian.put_u16(buf[offset:], .Big, u16(len(req.preview))); offset += 2
	copy(buf[offset:], req.preview); offset += len(req.preview)
	endian.put_u16(buf[offset:], .Big, u16(len(req.payload))); offset += 2
	copy(buf[offset:], req.payload); offset += len(req.payload)
	attachments_size := serializeAssetAttachments(req.attachments, buf[offset:])
	if attachments_size < 0 do return -1
	offset += attachments_size
	endian.put_u32(buf[offset:], .Big, req.correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_CreateEdge (opcode 40)
// ----------------------------------------------------------------------------

getSizeCreateEdgeRequest :: proc() -> int {
	return 2 + 8 + 2 + 8 + 2 + 8 + 2 + 4 // opcode + conv_id + source + target + relation + correlation_id
}

serializeCreateEdgeRequest :: proc(req: CreateEdgeRequest, buf: []byte) -> int {
	total_size := getSizeCreateEdgeRequest()

	if len(buf) < total_size {
		return -1
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_CreateEdge)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.source_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.source_id); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.target_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.target_id); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.relation)); offset += 2
	endian.put_u32(buf[offset:], .Big, req.correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_DeleteEdge (opcode 41)
// ----------------------------------------------------------------------------

getSizeDeleteEdgeRequest :: proc() -> int {
	return 2 + 8 + 8 + 4 // opcode + conv_id + edge_id + correlation_id
}

serializeDeleteEdgeRequest :: proc(conv_id: ConversationID, edge_id: EdgeID, buf: []byte, correlation_id: u32 = 0) -> int {
	total_size := getSizeDeleteEdgeRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_DeleteEdge))
	endian.put_u64(buf[2:10], .Big, u64(conv_id))
	endian.put_u64(buf[10:18], .Big, u64(edge_id))
	endian.put_u32(buf[18:22], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListEdges (opcode 42)
// ----------------------------------------------------------------------------

getSizeListEdgesRequest :: proc() -> int {
	return 2 + 8 + 2 + 8 + 4 // opcode + conv_id + target_type + target_id + correlation_id
}

serializeListEdgesRequest :: proc(req: ListEdgesRequest, buf: []byte) -> int {
	total_size := getSizeListEdgesRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_ListEdges))
	endian.put_u64(buf[2:10], .Big, u64(req.conv_id))
	endian.put_u16(buf[10:12], .Big, u16(req.target_type))
	endian.put_u64(buf[12:20], .Big, req.target_id)
	endian.put_u32(buf[20:24], .Big, req.correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListAllEdges (opcode 43)
// ----------------------------------------------------------------------------

getSizeListAllEdgesRequest :: proc() -> int {
	return 2 + 8 + 4 // opcode + conv_id + correlation_id
}

serializeListAllEdgesRequest :: proc(req: ListAllEdgesRequest, buf: []byte) -> int {
	total_size := getSizeListAllEdgesRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_ListAllEdges))
	endian.put_u64(buf[2:10], .Big, u64(req.conv_id))
	endian.put_u32(buf[10:14], .Big, req.correlation_id)

	return total_size
}

// ============================================================================
// Client-side parsing functions
// These are used by clients to parse messages from the server
// ============================================================================

// ----------------------------------------------------------------------------
// S_ServerReady (opcode 100)
// ----------------------------------------------------------------------------

parseServerReady :: proc(data: []byte) -> (ServerReady, ProtocolParseError) {
	result := ServerReady{}

	if len(data) < 2 {
		return result, .TooShort
	}

	build_len, _ := endian.get_u16(data[0:2], .Big)
	offset := 2

	if len(data) < offset + int(build_len) + 4 + 2 {
		return result, .TooShort
	}

	if build_len > 0 {
		result.build_version = data[offset:offset + int(build_len)]
		offset += int(build_len)
	}

	result.protocol_version, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	cpu_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if len(data) < offset + int(cpu_len) {
		return result, .TooShort
	}

	if cpu_len > 0 {
		result.cpu_model = data[offset:offset + int(cpu_len)]
	}

	offset += int(cpu_len)

	// Optional fields for newer ServerReady payloads:
	// username_len(2) + username + is_authenticated(1)
	if len(data) >= offset + 2 {
		username_len, _ := endian.get_u16(data[offset:], .Big)
		offset += 2

		if len(data) < offset + int(username_len) + 1 {
			return result, .TooShort
		}

		if username_len > 0 {
			result.username = data[offset:offset + int(username_len)]
			offset += int(username_len)
		}

		result.is_authenticated = data[offset] == 1
	}

	return result, nil
}

// ----------------------------------------------------------------------------
// S_NewMessage (opcode 102)
// ----------------------------------------------------------------------------

parseNewMessageEvent :: proc(data: []byte) -> (NewMessageEvent, ProtocolParseError) {
	result := NewMessageEvent{}

	if len(data) < _NME_FIXED_HEADER_SIZE {
		return result, .TooShort
	}

	conv_id, _ := endian.get_u64(data[_NME_OFFSET_CONV_ID:], .Big)
	result.conv_id = ConversationID(conv_id)

	seq, _ := endian.get_u64(data[_NME_OFFSET_SEQ:], .Big)
	result.seq = MessageSeq(seq)

	username_len, _ := endian.get_u16(data[_NME_OFFSET_USERNAME_LEN:], .Big)
	offset := _NME_OFFSET_USERNAME

	if len(data) < offset + int(username_len) + 8 + 1 + 2 {
		return result, .TooShort
	}

	if username_len > 0 {
		result.author_username = data[offset:offset + int(username_len)]
		offset += int(username_len)
	}

	timestamp_u64, _ := endian.get_u64(data[offset:], .Big)
	result.timestamp = cast(i64)timestamp_u64
	offset += 8

	result.content_type = MessageContentType(data[offset])
	offset += 1

	content_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if len(data) < offset + int(content_len) {
		return result, .TooShort
	}

	if content_len > 0 {
		result.content = data[offset:offset + int(content_len)]
	}

	return result, nil
}

// ----------------------------------------------------------------------------
// S_AckSendMessage (opcode 103)
// ----------------------------------------------------------------------------

parseAckSendMessage :: proc(data: []byte) -> (AckSendMessage, ProtocolParseError) {
	result := AckSendMessage{}

	if len(data) < _ASM_TOTAL_SIZE {
		return result, .TooShort
	}

	result.client_req_id, _ = endian.get_u32(data[_ASM_OFFSET_REQ_ID:], .Big)

	seq, _ := endian.get_u64(data[_ASM_OFFSET_SEQ:], .Big)
	result.assigned_seq = MessageSeq(seq)

	timestamp_u64, _ := endian.get_u64(data[_ASM_OFFSET_TIMESTAMP:], .Big)
	result.timestamp = cast(i64)timestamp_u64

	return result, nil
}

// ----------------------------------------------------------------------------
// S_StatsResponse (opcode 110)
// ----------------------------------------------------------------------------

parseStatsResponse :: proc(data: []byte) -> (StatsResponse, ProtocolParseError) {
	result := StatsResponse{}

	if len(data) < _STATS_RESPONSE_BASE_SIZE - 2 {
		return result, .TooShort
	}

	offset := 0

	timestamp_u64, _ := endian.get_u64(data[offset:], .Big)
	result.timestamp = cast(i64)timestamp_u64
	offset += 8

	server_ts_u64, _ := endian.get_u64(data[offset:], .Big)
	result.server_timestamp = cast(i64)server_ts_u64
	offset += 8

	result.thread_id, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.total_threads, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.connections, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.memory_total_mb, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.buffer_pool_percent, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.io_pending, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.io_ring_depth, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.io_ring_available, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.io_sq_overflow, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.io_total_completions, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.io_total_latency_ns, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.io_latency_count, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.send_queue_depth, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.send_queue_limit, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.send_backpressure = data[offset] == 1
	offset += 1

	result.send_dropped, _ = endian.get_u32(data[offset:], .Big)
	offset += 4

	result.wal_file_size, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.wal_pending_bytes, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.wal_record_count, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.wal_fsync_count, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.wal_total_fsync_ns, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.wal_total_write_ns, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	result.wal_write_count, _ = endian.get_u64(data[offset:], .Big)
	offset += 8

	if offset >= len(data) {
		return result, nil
	}

	if len(data) - offset < _PONG_WAL_DETAIL_HEADER_SIZE {
		return result, .TooShort
	}

	result.wal_details_version = data[offset]
	offset += 1

	reported_count := int(data[offset])
	offset += 1

	if len(data) - offset < reported_count * _PONG_WAL_DETAIL_SIZE {
		return result, .TooShort
	}

	for i := 0; i < reported_count; i += 1 {
		detail := PongWALDetail{}
		detail.kind = PongWALKind(data[offset])
		offset += 1
		detail.enabled = data[offset] == 1
		offset += 1
		detail.compaction_mode = data[offset]
		offset += 1
		detail.compaction_bg_status = data[offset]
		offset += 1

		detail.generation, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.snapshot_end, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.compact_count, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.install_cursor, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.install_last_backlog, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.install_budget_us, _ = endian.get_u32(data[offset:], .Big)
		offset += 4

		detail.file_size, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.pending_bytes, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.record_count, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.fsync_count, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.total_fsync_ns, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.write_count, _ = endian.get_u64(data[offset:], .Big)
		offset += 8
		detail.total_write_ns, _ = endian.get_u64(data[offset:], .Big)
		offset += 8

		if i < PONG_WAL_DETAIL_SLOT_COUNT {
			result.wal_details[i] = detail
		}
	}

	if reported_count > PONG_WAL_DETAIL_SLOT_COUNT {
		result.wal_details_count = PONG_WAL_DETAIL_MAX_COUNT
	} else {
		result.wal_details_count = u8(reported_count)
	}

	if offset == len(data) do return result, nil
	if len(data) - offset != _PONG_SHARD_SWEEP_SIZE do return result, .ContentLengthMismatch
	result.shard_sweep_version = data[offset]
	offset += 1
	if result.shard_sweep_version != PONG_SHARD_SWEEP_VERSION do return result, .ContentLengthMismatch
	result.shard_sweep.runs_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.ordinary_runs_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.raw_runs_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.input_bytes_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.dirty_bytes_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.prefix_read_bytes_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.latest_read_bytes_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.measure_read_bytes_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.copy_read_bytes_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.replay_read_bytes_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.metadata_fallbacks_total, _ = endian.get_u64(data[offset:], .Big); offset += 8
	result.shard_sweep.metadata_written_bytes_total, _ = endian.get_u64(data[offset:], .Big)

	return result, nil
}

// ----------------------------------------------------------------------------
// S_Pong (opcode 126)
// ----------------------------------------------------------------------------

parsePongResponse :: proc(data: []byte) -> (PongResponse, ProtocolParseError) {
	result := PongResponse{}

	if len(data) < _PONG_RESPONSE_SIZE - 2 {
		return result, .TooShort
	}

	timestamp_u64, _ := endian.get_u64(data[0:], .Big)
	result.timestamp = cast(i64)timestamp_u64

	server_ts_u64, _ := endian.get_u64(data[8:], .Big)
	result.server_timestamp = cast(i64)server_ts_u64

	return result, nil
}

// ----------------------------------------------------------------------------
// C_ListAssets (opcode 34)
// ----------------------------------------------------------------------------

getSizeListAssetsRequest :: proc() -> int {
	return 2 + 8 + 1 + 2 + 1 + 4 // opcode + conv_id + filter_by_type + asset_type + full_content + correlation_id
}

serializeListAssetsRequest :: proc(
	conv_id: ConversationID,
	filter_by_type: bool,
	asset_type: AssetType,
	full_content: bool,
	buf: []byte,
	correlation_id: u32 = 0,
) -> int {
	total_size := getSizeListAssetsRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_ListAssets))

	offset := 2

	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	buf[offset] = filter_by_type ? 1 : 0
	offset += 1

	endian.put_u16(buf[offset:], .Big, u16(asset_type))
	offset += 2

	buf[offset] = full_content ? 1 : 0
	offset += 1

	endian.put_u32(buf[offset:], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListAssetsPaged (opcode 35)
// ----------------------------------------------------------------------------

getSizeListAssetsPagedRequest :: proc(has_cursor: bool) -> int {
	size := 2 + 8 + 2 + 1 + 2 + 1 // opcode + conv_id + asset_type + full_content + limit + has_cursor
	if has_cursor {
		size += 16 // cursor_updated_at + cursor_asset_id
	}
	size += 4 // correlation_id
	return size
}

serializeListAssetsPagedRequest :: proc(
	conv_id: ConversationID,
	asset_type: AssetType,
	full_content: bool,
	limit: u16,
	has_cursor: bool,
	cursor_updated_at: i64,
	cursor_asset_id: AssetID,
	buf: []byte,
	correlation_id: u32 = 0,
) -> int {
	total_size := getSizeListAssetsPagedRequest(has_cursor)
	if len(buf) < total_size {
		return -1
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_ListAssetsPaged))
	offset += 2
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8
	endian.put_u16(buf[offset:], .Big, u16(asset_type))
	offset += 2
	buf[offset] = full_content ? 1 : 0
	offset += 1
	endian.put_u16(buf[offset:], .Big, limit)
	offset += 2
	buf[offset] = has_cursor ? 1 : 0
	offset += 1
	if has_cursor {
		endian.put_u64(buf[offset:], .Big, u64(cursor_updated_at))
		offset += 8
		endian.put_u64(buf[offset:], .Big, u64(cursor_asset_id))
		offset += 8
	}
	endian.put_u32(buf[offset:], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_DeleteAsset (opcode 32)
// ----------------------------------------------------------------------------

getSizeDeleteAssetRequest :: proc() -> int {
	return 2 + 8 + 8 + 4 // opcode + conv_id + asset_id + correlation_id
}

serializeDeleteAssetRequest :: proc(conv_id: ConversationID, asset_id: AssetID, buf: []byte, correlation_id: u32 = 0) -> int {
	total_size := getSizeDeleteAssetRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_DeleteAsset))
	endian.put_u64(buf[2:10], .Big, u64(conv_id))
	endian.put_u64(buf[10:18], .Big, u64(asset_id))
	endian.put_u32(buf[18:22], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_GetAsset (opcode 33)
// ----------------------------------------------------------------------------

getSizeGetAssetRequest :: proc() -> int {
	return 2 + 8 + 8 + 4 // opcode + conv_id + asset_id + correlation_id
}

serializeGetAssetRequest :: proc(conv_id: ConversationID, asset_id: AssetID, buf: []byte, correlation_id: u32 = 0) -> int {
	total_size := getSizeGetAssetRequest()

	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_GetAsset))
	endian.put_u64(buf[2:10], .Big, u64(conv_id))
	endian.put_u64(buf[10:18], .Big, u64(asset_id))
	endian.put_u32(buf[18:22], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListAssetsPagedByProject (opcode 36)
// ----------------------------------------------------------------------------

getSizeListAssetsPagedByProjectRequest :: proc(has_cursor: bool, project_len: int) -> int {
	size := 2 + 8 + 2 + 1 + 2 + 1 // opcode + conv_id + asset_type + full_content + limit + has_cursor
	if has_cursor {
		size += 16 // cursor_updated_at + cursor_asset_id
	}
	size += 2 + project_len + 4 // project_len + project + correlation_id
	return size
}

serializeListAssetsPagedByProjectRequest :: proc(
	conv_id: ConversationID,
	asset_type: AssetType,
	full_content: bool,
	limit: u16,
	has_cursor: bool,
	cursor_updated_at: i64,
	cursor_asset_id: AssetID,
	project: string,
	buf: []byte,
	correlation_id: u32 = 0,
) -> int {
	total_size := getSizeListAssetsPagedByProjectRequest(has_cursor, len(project))
	if len(buf) < total_size {
		return -1
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_ListAssetsPagedByProject))
	offset += 2
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8
	endian.put_u16(buf[offset:], .Big, u16(asset_type))
	offset += 2
	buf[offset] = full_content ? 1 : 0
	offset += 1
	endian.put_u16(buf[offset:], .Big, limit)
	offset += 2
	buf[offset] = has_cursor ? 1 : 0
	offset += 1
	if has_cursor {
		endian.put_u64(buf[offset:], .Big, u64(cursor_updated_at))
		offset += 8
		endian.put_u64(buf[offset:], .Big, u64(cursor_asset_id))
		offset += 8
	}
	endian.put_u16(buf[offset:], .Big, u16(len(project)))
	offset += 2
	copy(buf[offset:], project)
	offset += len(project)
	endian.put_u32(buf[offset:], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListAssetsPagedByTag (opcode 38)
// ----------------------------------------------------------------------------

getSizeListAssetsPagedByTagRequest :: proc(has_cursor: bool, tag_len: int) -> int {
	size := 2 + 8 + 2 + 1 + 2 + 1 // opcode + conv_id + asset_type + full_content + limit + has_cursor
	if has_cursor {
		size += 16 // cursor_updated_at + cursor_asset_id
	}
	size += 2 + tag_len + 4 // tag_len + tag + correlation_id
	return size
}

serializeListAssetsPagedByTagRequest :: proc(
	conv_id: ConversationID,
	asset_type: AssetType,
	full_content: bool,
	limit: u16,
	has_cursor: bool,
	cursor_updated_at: i64,
	cursor_asset_id: AssetID,
	tag: string,
	buf: []byte,
	correlation_id: u32 = 0,
) -> int {
	total_size := getSizeListAssetsPagedByTagRequest(has_cursor, len(tag))
	if len(buf) < total_size {
		return -1
	}

	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_ListAssetsPagedByTag))
	offset += 2
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8
	endian.put_u16(buf[offset:], .Big, u16(asset_type))
	offset += 2
	buf[offset] = full_content ? 1 : 0
	offset += 1
	endian.put_u16(buf[offset:], .Big, limit)
	offset += 2
	buf[offset] = has_cursor ? 1 : 0
	offset += 1
	if has_cursor {
		endian.put_u64(buf[offset:], .Big, u64(cursor_updated_at))
		offset += 8
		endian.put_u64(buf[offset:], .Big, u64(cursor_asset_id))
		offset += 8
	}
	endian.put_u16(buf[offset:], .Big, u16(len(tag)))
	offset += 2
	copy(buf[offset:], tag)
	offset += len(tag)
	endian.put_u32(buf[offset:], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListNoteProjects (opcode 37)
// ----------------------------------------------------------------------------

getSizeListNoteProjectsRequest :: proc() -> int {
	return 2 + 8 + 4 // opcode + conv_id + correlation_id
}

serializeListNoteProjectsRequest :: proc(conv_id: ConversationID, buf: []byte, correlation_id: u32 = 0) -> int {
	total_size := getSizeListNoteProjectsRequest()
	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_ListNoteProjects))
	endian.put_u64(buf[2:10], .Big, u64(conv_id))
	endian.put_u32(buf[10:14], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// C_ListNoteTags (opcode 39)
// ----------------------------------------------------------------------------

getSizeListNoteTagsRequest :: proc() -> int {
	return 2 + 8 + 4 // opcode + conv_id + correlation_id
}

serializeListNoteTagsRequest :: proc(conv_id: ConversationID, buf: []byte, correlation_id: u32 = 0) -> int {
	total_size := getSizeListNoteTagsRequest()
	if len(buf) < total_size {
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.C_ListNoteTags))
	endian.put_u64(buf[2:10], .Big, u64(conv_id))
	endian.put_u32(buf[10:14], .Big, correlation_id)

	return total_size
}

// ----------------------------------------------------------------------------
// Graph query requests (opcodes 44-47)
// ----------------------------------------------------------------------------

getSizeGraphQueryRequest :: proc() -> int {
	return 2 + 8 + 2 + 8 + 1 + 2 + 1 + 1 + 4
}

serializeGraphQueryRequest :: proc(req: GraphQueryRequest, buf: []byte) -> int {
	total_size := getSizeGraphQueryRequest()
	if len(buf) < total_size do return -1
	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_GraphQuery)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.start_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.start_id); offset += 8
	buf[offset] = req.max_depth; offset += 1
	endian.put_u16(buf[offset:], .Big, req.relation_mask); offset += 2
	buf[offset] = u8(req.direction); offset += 1
	buf[offset] = req.flags; offset += 1
	endian.put_u32(buf[offset:], .Big, req.correlation_id)
	return total_size
}

getSizeGraphShortestPathRequest :: proc() -> int {
	return 2 + 8 + 2 + 8 + 2 + 8 + 2 + 1 + 1 + 1 + 4
}

serializeGraphShortestPathRequest :: proc(req: GraphShortestPathRequest, buf: []byte) -> int {
	total_size := getSizeGraphShortestPathRequest()
	if len(buf) < total_size do return -1
	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_GraphShortestPath)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.from_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.from_id); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.to_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.to_id); offset += 8
	endian.put_u16(buf[offset:], .Big, req.relation_mask); offset += 2
	buf[offset] = u8(req.direction); offset += 1
	buf[offset] = req.max_depth; offset += 1
	buf[offset] = req.flags; offset += 1
	endian.put_u32(buf[offset:], .Big, req.correlation_id)
	return total_size
}

getSizeGraphDegreeRequest :: proc() -> int {
	return 2 + 8 + 2 + 2 + 2 + 4
}

serializeGraphDegreeRequest :: proc(req: GraphDegreeRequest, buf: []byte) -> int {
	total_size := getSizeGraphDegreeRequest()
	if len(buf) < total_size do return -1
	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_GraphDegree)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, req.top_n); offset += 2
	endian.put_u16(buf[offset:], .Big, req.type_filter); offset += 2
	endian.put_u16(buf[offset:], .Big, req.relation_mask); offset += 2
	endian.put_u32(buf[offset:], .Big, req.correlation_id)
	return total_size
}

getSizeGraphCommonNeighborsRequest :: proc() -> int {
	return 2 + 8 + 2 + 8 + 2 + 8 + 2 + 1 + 4
}

serializeGraphCommonNeighborsRequest :: proc(req: GraphCommonNeighborsRequest, buf: []byte) -> int {
	total_size := getSizeGraphCommonNeighborsRequest()
	if len(buf) < total_size do return -1
	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.C_GraphCommonNeighbors)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(req.conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.a_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.a_id); offset += 8
	endian.put_u16(buf[offset:], .Big, u16(req.b_type)); offset += 2
	endian.put_u64(buf[offset:], .Big, req.b_id); offset += 8
	endian.put_u16(buf[offset:], .Big, req.relation_mask); offset += 2
	buf[offset] = u8(req.direction); offset += 1
	endian.put_u32(buf[offset:], .Big, req.correlation_id)
	return total_size
}

// ============================================================================
// Client-side asset parsing helpers
// These parse the common asset wire format used by S_AssetCreated,
// S_AssetUpdated, S_AssetFull, and S_AssetList.
// Returned byte slices borrow data; attachment descriptors borrow the caller's
// attachments buffer. Both must outlive the parsed asset. A nil buffer accepts
// only assets without attachments; insufficient capacity returns TooMany.
// ============================================================================

parseAssetFromPayload :: proc(data: []byte, offset: int, attachments: []Attachment = nil) -> (Asset, int, ProtocolParseError) {
	return parseAssetHeaderFromPayload(data, offset, true, attachments)
}

parseAssetHeaderFromPayload :: proc(
	data: []byte,
	offset: int,
	include_attachments: bool,
	attachments: []Attachment = nil,
) -> (
	Asset,
	int,
	ProtocolParseError,
) {
	result := Asset{}
	pos := offset

	// asset_type(2) + asset_id(8) + parent_type(2) + parent_id(8) + owner_len(2) = 22
	if len(data) < pos + 22 {
		return result, pos, .TooShort
	}

	asset_type, _ := endian.get_u16(data[pos:], .Big)
	result.asset_type = AssetType(asset_type)
	pos += 2

	asset_id, _ := endian.get_u64(data[pos:], .Big)
	result.asset_id = AssetID(asset_id)
	pos += 8

	parent_type, _ := endian.get_u16(data[pos:], .Big)
	result.parent_type = ParentType(parent_type)
	pos += 2

	parent_id, _ := endian.get_u64(data[pos:], .Big)
	result.parent_id = parent_id
	pos += 8

	owner_len, _ := endian.get_u16(data[pos:], .Big)
	pos += 2

	if len(data) < pos + int(owner_len) {
		return result, pos, .TooShort
	}
	if owner_len > 0 {
		result.owner = data[pos:pos + int(owner_len)]
		pos += int(owner_len)
	}

	// created_at(8) + updated_at(8) + conv_id(8) + payload_encoding(1)
	// + payload_raw_len(4) + preview_len(2)
	if len(data) < pos + 31 {
		return result, pos, .TooShort
	}

	created_at, _ := endian.get_u64(data[pos:], .Big)
	result.created_at = cast(i64)created_at
	pos += 8

	updated_at, _ := endian.get_u64(data[pos:], .Big)
	result.updated_at = cast(i64)updated_at
	pos += 8

	conv_id, _ := endian.get_u64(data[pos:], .Big)
	result.conv_id = ConversationID(conv_id)
	pos += 8

	result.payload_encoding = PayloadEncoding(data[pos])
	if result.payload_encoding != .Plain && result.payload_encoding != .Zstd {
		return result, pos, .InvalidContentType
	}
	pos += 1

	result.payload_raw_len, _ = endian.get_u32(data[pos:], .Big)
	pos += 4

	preview_len, _ := endian.get_u16(data[pos:], .Big)
	pos += 2

	if len(data) < pos + int(preview_len) {
		return result, pos, .TooShort
	}
	if preview_len > 0 {
		result.preview = data[pos:pos + int(preview_len)]
		pos += int(preview_len)
	}

	if include_attachments {
		att_slice, new_pos, att_err := parseAssetAttachmentsFromPayload(data, pos, attachments)
		if att_err != nil do return result, pos, att_err
		result.attachments = att_slice
		pos = new_pos
	}

	return result, pos, nil
}

parseAssetFullFromPayload :: proc(data: []byte, offset: int, attachments: []Attachment = nil) -> (Asset, int, ProtocolParseError) {
	result, pos, err := parseAssetHeaderFromPayload(data, offset, false)
	if err != nil {
		return result, pos, err
	}

	if len(data) < pos + 2 {
		return result, pos, .TooShort
	}

	payload_len, _ := endian.get_u16(data[pos:], .Big)
	pos += 2

	if len(data) < pos + int(payload_len) {
		return result, pos, .ContentLengthMismatch
	}
	if payload_len > 0 {
		result.payload = data[pos:pos + int(payload_len)]
		pos += int(payload_len)
	}

	att_slice, new_pos, att_err := parseAssetAttachmentsFromPayload(data, pos, attachments)
	if att_err != nil do return result, pos, att_err
	result.attachments = att_slice
	pos = new_pos

	return result, pos, nil
}

parseAssetAttachmentsFromPayload :: proc(
	data: []byte,
	offset: int,
	attachments: []Attachment,
) -> (
	result: []Attachment,
	next_offset: int,
	err: ProtocolParseError,
) {
	pos := offset
	if pos + 2 > len(data) do return nil, offset, .TooShort
	attachment_count_raw, ok := endian.get_u16(data[pos:], .Big)
	if !ok do return nil, offset, .TooShort
	pos += 2
	attachment_count := int(attachment_count_raw)
	if attachment_count > MAX_ATTACHMENTS_PER_TASK || attachment_count > len(attachments) do return nil, offset, .TooMany

	for i := 0; i < attachment_count; i += 1 {
		att: Attachment
		att.file_id, pos, err = parse_u16_bytes_from_payload(data, pos)
		if err != nil do return nil, offset, err
		if len(att.file_id) > MAX_FILE_ID_LENGTH do return nil, offset, .ContentLengthExceedsMax
		att.filename, pos, err = parse_u16_bytes_from_payload(data, pos)
		if err != nil do return nil, offset, err
		if len(att.filename) > MAX_FILENAME_LENGTH do return nil, offset, .ContentLengthExceedsMax
		if pos + 8 > len(data) do return nil, offset, .TooShort
		att.size, _ = endian.get_u64(data[pos:], .Big)
		pos += 8
		att.mime_type, pos, err = parse_u16_bytes_from_payload(data, pos)
		if err != nil do return nil, offset, err
		if len(att.mime_type) > MAX_MIME_TYPE_LENGTH do return nil, offset, .ContentLengthExceedsMax
		if pos + 8 > len(data) do return nil, offset, .TooShort
		uploaded_at_raw, _ := endian.get_u64(data[pos:], .Big)
		att.uploaded_at = i64(uploaded_at_raw)
		pos += 8
		attachments[i] = att
	}

	return attachments[:attachment_count], pos, nil
}

// ----------------------------------------------------------------------------
// S_AssetCreated (opcode 140) — parse full asset with payload
// ----------------------------------------------------------------------------

parseAssetCreatedEvent :: proc(data: []byte, attachments: []Attachment = nil) -> (Asset, ProtocolParseError) {
	asset, _, err := parseAssetFullFromPayload(data, 0, attachments)
	return asset, err
}

// ----------------------------------------------------------------------------
// S_AssetUpdated (opcode 141) — parse full asset with payload
// ----------------------------------------------------------------------------

parseAssetUpdatedEvent :: proc(data: []byte, attachments: []Attachment = nil) -> (Asset, ProtocolParseError) {
	asset, _, err := parseAssetFullFromPayload(data, 0, attachments)
	return asset, err
}

// ----------------------------------------------------------------------------
// S_AssetDeleted (opcode 142) — conv_id + asset_id
// ----------------------------------------------------------------------------

AssetDeletedEvent :: struct {
	conv_id:  ConversationID,
	asset_id: AssetID,
}

parseAssetDeletedEvent :: proc(data: []byte) -> (AssetDeletedEvent, ProtocolParseError) {
	result := AssetDeletedEvent{}

	if len(data) < 16 {
		return result, .TooShort
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	asset_id, _ := endian.get_u64(data[8:], .Big)
	result.asset_id = AssetID(asset_id)

	return result, nil
}

// ----------------------------------------------------------------------------
// S_AssetFull (opcode 143) — parse full asset with payload
// ----------------------------------------------------------------------------

parseAssetFullEvent :: proc(data: []byte, attachments: []Attachment = nil) -> (Asset, ProtocolParseError) {
	asset, _, err := parseAssetFullFromPayload(data, 0, attachments)
	return asset, err
}

// ----------------------------------------------------------------------------
// S_AssetList (opcode 144)
// ----------------------------------------------------------------------------

AssetListEvent :: struct {
	conv_id:      ConversationID,
	full_content: bool,
	assets:       []Asset,
}

// attachments must have capacity for the sum of attachments across all assets.
// The caller owns result.assets (including on error) and deletes it with allocator.
parseAssetListEvent :: proc(data: []byte, allocator := context.allocator, attachments: []Attachment = nil) -> (AssetListEvent, ProtocolParseError) {
	result := AssetListEvent{}

	// conv_id(8) + full_content(1) + count(2)
	if len(data) < 11 {
		return result, .TooShort
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	result.full_content = data[8] == 1

	count, _ := endian.get_u16(data[9:], .Big)
	pos := 11
	attachment_pos := 0

	if count > 0 {
		result.assets = make([]Asset, count, allocator)

		for i in 0 ..< int(count) {
			if result.full_content {
				asset, new_pos, err := parseAssetFullFromPayload(data, pos, attachments[attachment_pos:])
				if err != nil {
					return result, err
				}
				result.assets[i] = asset
				pos = new_pos
			} else {
				asset, new_pos, err := parseAssetFromPayload(data, pos, attachments[attachment_pos:])
				if err != nil {
					return result, err
				}
				result.assets[i] = asset
				pos = new_pos
			}
			attachment_pos += len(result.assets[i].attachments)
		}
	}

	return result, nil
}

// ----------------------------------------------------------------------------
// S_RoomPresenceUpdate (opcode 109)
// ----------------------------------------------------------------------------

parseRoomPresenceUpdate :: proc(data: []byte, allocator := context.allocator) -> (RoomPresenceUpdate, ProtocolParseError) {
	result := RoomPresenceUpdate{}

	if len(data) < 19 {
		return result, .TooShort
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	result.event_type = PresenceEventType(data[8])

	result.sequence, _ = endian.get_u64(data[9:], .Big)

	username_len, _ := endian.get_u16(data[17:19], .Big)
	offset := 19

	if len(data) < offset + int(username_len) + 1 + 1 + 2 {
		return result, .TooShort
	}

	if username_len > 0 {
		result.username = data[offset:offset + int(username_len)]
		offset += int(username_len)
	}

	result.is_authenticated = data[offset] == 1
	offset += 1

	result.user_type = User_Type(data[offset])
	offset += 1

	old_username_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if len(data) < offset + int(old_username_len) + 2 {
		return result, .TooShort
	}

	if old_username_len > 0 {
		result.old_username = data[offset:offset + int(old_username_len)]
		offset += int(old_username_len)
	}

	user_count, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if user_count > 0 {
		result.user_list = make([][]byte, user_count, allocator)
		result.user_auth_flags = make([]bool, user_count, allocator)
		result.user_types = make([]User_Type, user_count, allocator)

		for i in 0 ..< int(user_count) {
			if len(data) < offset + 2 {
				return result, .TooShort
			}
			user_len, _ := endian.get_u16(data[offset:], .Big)
			offset += 2

			if len(data) < offset + int(user_len) + 1 + 1 {
				return result, .TooShort
			}

			if user_len > 0 {
				result.user_list[i] = data[offset:offset + int(user_len)]
				offset += int(user_len)
			}

			result.user_auth_flags[i] = data[offset] == 1
			offset += 1

			result.user_types[i] = User_Type(data[offset])
			offset += 1
		}
	}

	return result, nil
}
