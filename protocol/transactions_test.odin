package protocol

import "core:encoding/endian"
import "core:testing"

@(test)
test_transaction_envelope_round_trip :: proc(t: ^testing.T) {
	body_a := []byte{1, 2, 3}
	body_b := []byte{4, 5}
	ops := []TransactionOperation{{op_type = .TaskCreate, body = body_a}, {op_type = .EdgeCreate, body = body_b}}
	buf: [64]byte
	written := serializeApplyTransactionRequest(77, ops, buf[:])
	testing.expect(t, written == getSizeApplyTransactionRequest(ops))
	parsed_ops: [MAX_TRANSACTION_OPERATIONS]TransactionOperation
	parsed, err := parseApplyTransactionRequest(buf[2:written], parsed_ops[:])
	testing.expect(t, err == nil)
	testing.expect_value(t, parsed.correlation_id, u32(77))
	testing.expect_value(t, len(parsed.operations), 2)
	testing.expect_value(t, parsed.operations[1].op_type, TransactionOperationType.EdgeCreate)
	testing.expect(t, len(parsed.operations[1].body) == 2 && parsed.operations[1].body[0] == 4 && parsed.operations[1].body[1] == 5)
}

@(test)
test_transaction_envelope_is_strict :: proc(t: ^testing.T) {
	body := []byte{1}
	ops := []TransactionOperation{{op_type = .TaskCreate, body = body}}
	buf: [32]byte
	written := serializeApplyTransactionRequest(1, ops, buf[:])
	parsed_ops: [MAX_TRANSACTION_OPERATIONS]TransactionOperation
	_, trailing_err := parseApplyTransactionRequest(buf[2:written + 1], parsed_ops[:])
	testing.expect_value(t, trailing_err, ProtocolParseError.ContentLengthMismatch)
	buf[3] = 1
	_, reserved_err := parseApplyTransactionRequest(buf[2:written], parsed_ops[:])
	testing.expect_value(t, reserved_err, ProtocolParseError.InvalidValue)
}

@(test)
test_transaction_edge_parser_rejects_edge_endpoints :: proc(t: ^testing.T) {
	body: [34]byte
	endian.put_u64(body[:], .Big, 1)
	body[8] = u8(TransactionReferenceKind.Existing)
	body[9] = u8(TransactionEntityType.Edge)
	endian.put_u64(body[12:], .Big, 1)
	body[20] = u8(TransactionReferenceKind.Existing)
	body[21] = u8(TransactionEntityType.Task)
	endian.put_u64(body[24:], .Big, 2)
	endian.put_u16(body[32:], .Big, u16(min(RelationType)))
	_, err := parseTransactionEdgeCreate(body[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidValue)
}

@(test)
test_transaction_asset_decompression_size_is_bounded :: proc(t: ^testing.T) {
	create: [21]byte
	endian.put_u16(create[8:], .Big, u16(AssetType.Reminder))
	create[12] = u8(PayloadEncoding.Zstd)
	patch: [36]byte
	patch[8] = u8(TransactionReferenceKind.Existing)
	patch[9] = u8(TransactionEntityType.Asset)
	endian.put_u64(patch[12:], .Big, 1)
	patch[28] = TRANSACTION_ASSET_PATCH_PAYLOAD
	patch[29] = u8(PayloadEncoding.Zstd)
	for raw_len in ([?]u32{MAX_PAYLOAD_LENGTH, MAX_PAYLOAD_LENGTH + 1, max(u32)}) {
		endian.put_u32(create[13:], .Big, raw_len)
		endian.put_u32(patch[30:], .Big, raw_len)
		_, create_err := parseTransactionAssetCreate(create[:])
		_, patch_err := parseTransactionAssetPatch(patch[:])
		if raw_len == MAX_PAYLOAD_LENGTH {
			testing.expect(t, create_err == nil && patch_err == nil)
		} else {
			testing.expect_value(t, create_err, ProtocolParseError.ContentLengthExceedsMax)
			testing.expect_value(t, patch_err, ProtocolParseError.ContentLengthExceedsMax)
		}
	}
}

@(test)
test_transaction_body_serializers_refuse_oversized_fields :: proc(t: ^testing.T) {
	// Field lengths travel as u16, so an oversized field must be refused rather
	// than truncated into a body the parser rejects.
	large: [MAX_PREVIEW_LENGTH + 1]byte
	buf: [8 * 1024]byte

	patch := TransactionTaskPatch {
		conv_id = 1,
		task = {kind = .Existing, entity_type = .Task, value = 2},
		present = TRANSACTION_TASK_PATCH_TITLE,
		title = large[:MAX_TASK_TITLE_LENGTH + 1],
	}
	testing.expect_value(t, serializeTransactionTaskPatch(patch, buf[:]), -1)
	patch.title = large[:MAX_TASK_TITLE_LENGTH]
	testing.expect(t, serializeTransactionTaskPatch(patch, buf[:]) > 0)

	create := TransactionAssetCreate {
		conv_id          = 1,
		asset_type       = .Note,
		payload_encoding = .Plain,
		payload_raw_len  = 1,
		preview          = large[:MAX_PREVIEW_LENGTH + 1],
		payload          = large[:1],
	}
	testing.expect_value(t, serializeTransactionAssetCreate(create, buf[:]), -1)
	create.preview = large[:MAX_PREVIEW_LENGTH]
	testing.expect(t, serializeTransactionAssetCreate(create, buf[:]) > 0)
	create.payload_raw_len = 2
	testing.expect_value(t, serializeTransactionAssetCreate(create, buf[:]), -1)

	asset_patch := TransactionAssetPatch {
		conv_id = 1,
		asset = {kind = .Existing, entity_type = .Asset, value = 3},
		present = TRANSACTION_ASSET_PATCH_PAYLOAD,
		payload_encoding = .Plain,
		payload_raw_len = u32(MAX_PAYLOAD_LENGTH + 1),
	}
	testing.expect_value(t, serializeTransactionAssetPatch(asset_patch, buf[:]), -1)
}
