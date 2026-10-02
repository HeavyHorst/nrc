package protocol

import "core:encoding/endian"

TRANSACTION_WIRE_VERSION :: 1
MAX_TRANSACTION_OPERATIONS :: 256

TransactionOperationType :: enum u8 {
	TaskCreate  = 1,
	TaskPatch   = 2,
	AssetCreate = 3,
	AssetPatch  = 4,
	EdgeCreate  = 5,
	TaskDelete  = 6,
	AssetDelete = 7,
	EdgeDelete  = 8,
}

TransactionEntityType :: enum u8 {
	Task  = 1,
	Asset = 2,
	Edge  = 3,
}

TransactionReferenceKind :: enum u8 {
	Existing  = 0,
	CreatedBy = 1,
}

// A reference is encoded as kind:u8, entity_type:u8, reserved:u16, value:u64.
// Existing.value is an entity ID. CreatedBy.value is a zero-based operation
// index and its entity_type must agree with that create operation.
TransactionReference :: struct {
	kind:        TransactionReferenceKind,
	entity_type: TransactionEntityType,
	value:       u64,
}

TransactionOperation :: struct {
	op_type: TransactionOperationType,
	body:    []byte, // borrowed, operation-specific version-1 body
}

TransactionTaskCreate :: struct {
	conv_id:                                   ConversationID,
	status:                                    TaskStatus,
	priority:                                  u8,
	color:                                     TaskColor,
	due_at:                                    i64,
	blocked_by:                                TransactionReference,
	title, description, external_ref, project: []byte,
}

TransactionTaskPatch :: struct {
	conv_id:                                             ConversationID,
	task:                                                TransactionReference,
	if_updated_at:                                       i64, // 0 disables optimistic concurrency
	present:                                             u16,
	status:                                              TaskStatus,
	priority:                                            u8,
	color:                                               TaskColor,
	due_at:                                              i64,
	blocked_by:                                          TransactionReference,
	title, description, assignee, external_ref, project: []byte,
}

TransactionAssetCreate :: struct {
	conv_id:          ConversationID,
	asset_type:       AssetType,
	parent_type:      ParentType,
	parent:           TransactionReference,
	payload_encoding: PayloadEncoding,
	payload_raw_len:  u32,
	preview, payload: []byte,
}

TransactionAssetPatch :: struct {
	conv_id:          ConversationID,
	asset:            TransactionReference,
	if_updated_at:    i64, // 0 disables optimistic concurrency
	present:          u8,
	payload_encoding: PayloadEncoding,
	payload_raw_len:  u32,
	preview, payload: []byte,
}

TransactionEdgeCreate :: struct {
	conv_id:        ConversationID,
	source, target: TransactionReference,
	relation:       RelationType,
}

TransactionDelete :: struct {
	conv_id:       ConversationID,
	entity:        TransactionReference,
	if_updated_at: i64, // Task/Asset only; EdgeDelete remains exactly conv_id + reference.
}

TRANSACTION_TASK_PATCH_TITLE :: u16(1 << 0)
TRANSACTION_TASK_PATCH_DESCRIPTION :: u16(1 << 1)
TRANSACTION_TASK_PATCH_STATUS :: u16(1 << 2)
TRANSACTION_TASK_PATCH_PRIORITY :: u16(1 << 3)
TRANSACTION_TASK_PATCH_COLOR :: u16(1 << 4)
TRANSACTION_TASK_PATCH_DUE_AT :: u16(1 << 5)
TRANSACTION_TASK_PATCH_BLOCKED_BY :: u16(1 << 6)
TRANSACTION_TASK_PATCH_ASSIGNEE :: u16(1 << 7)
TRANSACTION_TASK_PATCH_EXTERNAL_REF :: u16(1 << 8)
TRANSACTION_TASK_PATCH_PROJECT :: u16(1 << 9)
TRANSACTION_TASK_PATCH_ALL :: u16(0x03ff)
TRANSACTION_ASSET_PATCH_PREVIEW :: u8(1 << 0)
TRANSACTION_ASSET_PATCH_PAYLOAD :: u8(1 << 1)

transaction_read_bytes :: proc(data: []byte, offset: ^int, limit: int) -> ([]byte, ProtocolParseError) {
	if len(data) - offset^ < 2 do return nil, .TooShort
	n, _ := endian.get_u16(data[offset^:], .Big); offset^ += 2
	if int(n) > limit do return nil, .ContentLengthExceedsMax
	if len(data) - offset^ < int(n) do return nil, .ContentLengthMismatch
	result := data[offset^:offset^ + int(n)]; offset^ += int(n)
	return result, nil
}

transaction_read_ref :: proc(data: []byte, offset: ^int, expected: TransactionEntityType) -> (TransactionReference, ProtocolParseError) {
	if len(data) - offset^ < 12 do return {}, .TooShort
	r, err := parseTransactionReference(data[offset^:offset^ + 12]); offset^ += 12
	if err != nil do return {}, err
	if r.entity_type != expected do return {}, .InvalidValue
	return r, nil
}

parseTransactionTaskCreate :: proc(data: []byte) -> (r: TransactionTaskCreate, err: ProtocolParseError) {
	if len(data) < 40 do return r, .TooShort
	v, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v)
	r.status = TaskStatus(data[8]); r.priority = data[9]; r.color = TaskColor(data[10]); if data[11] != 0 do return r, .InvalidValue
	v, _ = endian.get_u64(data[12:], .Big); r.due_at = i64(v); o := 20
	r.blocked_by, err = transaction_read_ref(data, &o, .Task); if err != nil do return
	r.title, err = transaction_read_bytes(data, &o, MAX_TASK_TITLE_LENGTH); if err != nil do return
	r.description, err = transaction_read_bytes(data, &o, MAX_TASK_DESCRIPTION_LENGTH); if err != nil do return
	r.external_ref, err = transaction_read_bytes(data, &o, MAX_EXTERNAL_REF_LENGTH); if err != nil do return
	r.project, err = transaction_read_bytes(data, &o, MAX_PROJECT_LENGTH); if err != nil do return
	if o != len(data) || len(r.title) == 0 || r.status < min(TaskStatus) || r.status > max(TaskStatus) || r.color < min(TaskColor) || r.color > max(TaskColor) do return r, .InvalidValue
	return r, nil
}

parseTransactionTaskPatch :: proc(data: []byte) -> (r: TransactionTaskPatch, err: ProtocolParseError) {
	if len(data) < 30 do return r, .TooShort
	v, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v); o := 8
	r.task, err = transaction_read_ref(data, &o, .Task); if err != nil do return
	v, _ = endian.get_u64(data[o:], .Big); r.if_updated_at = i64(v); o += 8
	r.present, _ = endian.get_u16(data[o:], .Big); o += 2; if r.present == 0 || r.present &~ TRANSACTION_TASK_PATCH_ALL != 0 do return r, .InvalidValue
	if r.present & TRANSACTION_TASK_PATCH_TITLE != 0 {r.title, err = transaction_read_bytes(data, &o, MAX_TASK_TITLE_LENGTH); if err != nil do return}
	if r.present & TRANSACTION_TASK_PATCH_DESCRIPTION !=
	   0 {r.description, err = transaction_read_bytes(data, &o, MAX_TASK_DESCRIPTION_LENGTH); if err != nil do return}
	if r.present & TRANSACTION_TASK_PATCH_STATUS != 0 {if o >= len(data) do return r, .TooShort; r.status = TaskStatus(data[o]); o += 1}
	if r.present & TRANSACTION_TASK_PATCH_PRIORITY != 0 {if o >= len(data) do return r, .TooShort; r.priority = data[o]; o += 1}
	if r.present & TRANSACTION_TASK_PATCH_COLOR != 0 {if o >= len(data) do return r, .TooShort; r.color = TaskColor(data[o]); o += 1}
	if r.present & TRANSACTION_TASK_PATCH_DUE_AT !=
	   0 {if len(data) - o < 8 do return r, .TooShort; v, _ = endian.get_u64(data[o:], .Big); r.due_at = i64(v); o += 8}
	if r.present & TRANSACTION_TASK_PATCH_BLOCKED_BY != 0 {r.blocked_by, err = transaction_read_ref(data, &o, .Task); if err != nil do return}
	if r.present & TRANSACTION_TASK_PATCH_ASSIGNEE != 0 {r.assignee, err = transaction_read_bytes(data, &o, MAX_ASSIGNEE_LENGTH); if err != nil do return}
	if r.present & TRANSACTION_TASK_PATCH_EXTERNAL_REF !=
	   0 {r.external_ref, err = transaction_read_bytes(data, &o, MAX_EXTERNAL_REF_LENGTH); if err != nil do return}
	if r.present & TRANSACTION_TASK_PATCH_PROJECT != 0 {r.project, err = transaction_read_bytes(data, &o, MAX_PROJECT_LENGTH); if err != nil do return}
	if o != len(data) do return r, .ContentLengthMismatch
	return r, nil
}

parseTransactionAssetCreate :: proc(data: []byte) -> (r: TransactionAssetCreate, err: ProtocolParseError) {
	if len(data) < 21 do return r, .TooShort; v, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v); a, _ := endian.get_u16(data[8:], .Big); r.asset_type = AssetType(a); p, _ := endian.get_u16(data[10:], .Big); r.parent_type = ParentType(p); o := 12
	if r.parent_type !=
	   .None {expected := TransactionEntityType.Task; if r.parent_type == .Asset do expected = .Asset; r.parent, err = transaction_read_ref(data, &o, expected); if err != nil do return}
	if len(data) - o < 5 do return r, .TooShort; r.payload_encoding = PayloadEncoding(data[o]); o += 1; r.payload_raw_len, _ = endian.get_u32(data[o:], .Big); o += 4
	r.preview, err = transaction_read_bytes(
		data,
		&o,
		MAX_PREVIEW_LENGTH,
	); if err != nil do return; r.payload, err = transaction_read_bytes(data, &o, MAX_PAYLOAD_LENGTH); if err != nil do return
	if o != len(data) do return r, .ContentLengthMismatch
	if r.asset_type < min(AssetType) || r.asset_type > max(AssetType) || r.parent_type < min(ParentType) || r.parent_type > max(ParentType) || r.payload_encoding < min(PayloadEncoding) || r.payload_encoding > max(PayloadEncoding) || r.payload_encoding == .Plain && r.payload_raw_len != u32(len(r.payload)) do return r, .InvalidValue
	return r, nil
}

parseTransactionAssetPatch :: proc(data: []byte) -> (r: TransactionAssetPatch, err: ProtocolParseError) {
	if len(data) < 29 do return r, .TooShort; v, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v); o := 8; r.asset, err = transaction_read_ref(data, &o, .Asset); if err != nil do return; v, _ = endian.get_u64(data[o:], .Big); r.if_updated_at = i64(v); o += 8; r.present = data[o]; o += 1
	if r.present == 0 || r.present &~ u8(3) != 0 do return r, .InvalidValue
	if r.present & TRANSACTION_ASSET_PATCH_PREVIEW != 0 {r.preview, err = transaction_read_bytes(data, &o, MAX_PREVIEW_LENGTH); if err != nil do return}
	if r.present & TRANSACTION_ASSET_PATCH_PAYLOAD !=
	   0 {if len(data) - o < 5 do return r, .TooShort; r.payload_encoding = PayloadEncoding(data[o]); o += 1; r.payload_raw_len, _ = endian.get_u32(data[o:], .Big); o += 4; r.payload, err = transaction_read_bytes(data, &o, MAX_PAYLOAD_LENGTH); if err != nil do return}
	if o != len(data) do return r, .ContentLengthMismatch
	return r, nil
}

parseTransactionEdgeCreate :: proc(data: []byte) -> (r: TransactionEdgeCreate, err: ProtocolParseError) {
	if len(data) != 34 do return r, (len(data) < 34 ? .TooShort : .ContentLengthMismatch); v, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v); o := 8
	// Endpoint references carry their entity type, so parse without an expected type.
	r.source, err = parseTransactionReference(
		data[o:o + 12],
	); if err != nil do return; o += 12; r.target, err = parseTransactionReference(data[o:o + 12]); if err != nil do return; o += 12; v16, _ := endian.get_u16(data[o:], .Big); r.relation = RelationType(v16)
	if (r.source.entity_type != .Task && r.source.entity_type != .Asset) ||
	   (r.target.entity_type != .Task && r.target.entity_type != .Asset) ||
	   r.relation < min(RelationType) ||
	   r.relation > max(RelationType) {
		return r, .InvalidValue
	}
	return r, nil
}

parseTransactionDelete :: proc(data: []byte, expected: TransactionEntityType) -> (r: TransactionDelete, err: ProtocolParseError) {
	// Edges do not have updated_at, so EdgeDelete intentionally retains its 20-byte body.
	expected_len := expected == .Edge ? 20 : 28
	if len(data) != expected_len do return r, (len(data) < expected_len ? .TooShort : .ContentLengthMismatch)
	v, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v); o := 8; r.entity, err = transaction_read_ref(data, &o, expected)
	if err == nil && expected != .Edge {v, _ = endian.get_u64(data[o:], .Big); r.if_updated_at = i64(v)}
	return
}

ApplyTransactionRequest :: struct {
	version:        u8,
	correlation_id: u32,
	operations:     []TransactionOperation, // borrowed descriptors supplied by caller
}

TransactionResultStatus :: enum u8 {
	Committed = 0,
	Rejected  = 1,
}

TransactionOperationResult :: struct {
	op_type:   TransactionOperationType,
	entity_id: u64, // zero for non-create operations
}

// C_ApplyTransaction payload:
// version:u8, reserved:u8(0), operation_count:u16, correlation_id:u32,
// then operation_count entries of type:u8, reserved:u8(0), body_len:u32, body.
parseApplyTransactionRequest :: proc(data: []byte, operations: []TransactionOperation) -> (ApplyTransactionRequest, ProtocolParseError) {
	result := ApplyTransactionRequest{}
	if len(data) < 8 do return result, .TooShort
	if data[0] != TRANSACTION_WIRE_VERSION || data[1] != 0 do return result, .InvalidValue
	count_u16, _ := endian.get_u16(data[2:], .Big)
	count := int(count_u16)
	if count == 0 do return result, .InvalidValue
	if count > MAX_TRANSACTION_OPERATIONS || count > len(operations) do return result, .TooMany
	result.version = data[0]
	result.correlation_id, _ = endian.get_u32(data[4:], .Big)
	offset := 8
	for i in 0 ..< count {
		if len(data) - offset < 6 do return ApplyTransactionRequest{}, .TooShort
		op_type := TransactionOperationType(data[offset])
		if op_type < min(TransactionOperationType) || op_type > max(TransactionOperationType) || data[offset + 1] != 0 {
			return ApplyTransactionRequest{}, .InvalidValue
		}
		body_len, _ := endian.get_u32(data[offset + 2:], .Big)
		offset += 6
		if u64(body_len) > u64(len(data) - offset) do return ApplyTransactionRequest{}, .ContentLengthMismatch
		operations[i] = {
			op_type = op_type,
			body    = data[offset:offset + int(body_len)],
		}
		offset += int(body_len)
	}
	if offset != len(data) do return ApplyTransactionRequest{}, .ContentLengthMismatch
	result.operations = operations[:count]
	return result, nil
}

parseTransactionReference :: proc(data: []byte) -> (TransactionReference, ProtocolParseError) {
	if len(data) != 12 do return {}, .ContentLengthMismatch
	kind := TransactionReferenceKind(data[0])
	entity_type := TransactionEntityType(data[1])
	reserved, _ := endian.get_u16(data[2:], .Big)
	if (kind != .Existing && kind != .CreatedBy) || entity_type < min(TransactionEntityType) || entity_type > max(TransactionEntityType) || reserved != 0 {
		return {}, .InvalidValue
	}
	value, _ := endian.get_u64(data[4:], .Big)
	return {kind = kind, entity_type = entity_type, value = value}, nil
}

getSizeApplyTransactionRequest :: proc(operations: []TransactionOperation) -> int {
	size := 2 + 8
	for op in operations do size += 6 + len(op.body)
	return size
}

serializeApplyTransactionRequest :: proc(correlation_id: u32, operations: []TransactionOperation, buf: []byte) -> int {
	total := getSizeApplyTransactionRequest(operations)
	if len(operations) == 0 || len(operations) > MAX_TRANSACTION_OPERATIONS || len(buf) < total do return -1
	endian.put_u16(buf, .Big, u16(Opcode.C_ApplyTransaction))
	buf[2] = TRANSACTION_WIRE_VERSION; buf[3] = 0
	endian.put_u16(buf[4:], .Big, u16(len(operations)))
	endian.put_u32(buf[6:], .Big, correlation_id)
	offset := 10
	for op in operations {
		if op.op_type < min(TransactionOperationType) || op.op_type > max(TransactionOperationType) do return -1
		buf[offset] = u8(op.op_type); buf[offset + 1] = 0
		endian.put_u32(buf[offset + 2:], .Big, u32(len(op.body))); offset += 6
		copy(buf[offset:], op.body); offset += len(op.body)
	}
	return offset
}

// S_TransactionResult: opcode:u16, version:u8, status:u8,
// correlation_id:u32, failed_operation:u16 (0xffff on commit), count:u16,
// then count entries type:u8, reserved:u8(0), entity_id:u64.
getSizeTransactionResult :: proc(count: int) -> int {return 12 + count * 10}

serializeTransactionResult :: proc(
	correlation_id: u32,
	status: TransactionResultStatus,
	failed_operation: u16,
	results: []TransactionOperationResult,
	buf: []byte,
) -> int {
	total := getSizeTransactionResult(len(results))
	if len(results) > MAX_TRANSACTION_OPERATIONS || len(buf) < total do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_TransactionResult))
	buf[2] = TRANSACTION_WIRE_VERSION; buf[3] = u8(status)
	endian.put_u32(buf[4:], .Big, correlation_id)
	endian.put_u16(buf[8:], .Big, failed_operation)
	endian.put_u16(buf[10:], .Big, u16(len(results)))
	offset := 12
	for result in results {
		buf[offset] = u8(result.op_type); buf[offset + 1] = 0
		endian.put_u64(buf[offset + 2:], .Big, result.entity_id); offset += 10
	}
	return offset
}
