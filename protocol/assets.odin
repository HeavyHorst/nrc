package protocol

import "core:encoding/endian"
import "core:log"

// ============================================================================
// Asset Types
// ============================================================================

AssetID :: u64

AssetType :: enum u16 {
	Comment          = 1,
	Document         = 2,
	File             = 3,
	Agenda           = 4,
	Note             = 5,
	Reminder         = 6,
	RoomMapping      = 7,
	CustomerCompany  = 8,
	CustomerContact  = 9,
	CustomerActivity = 10,
	// A bound work slice. Slices are derived from task/note project labels at
	// read time; an asset of this type is materialized only once the slice is
	// written to (owner, outcome, or closure). Membership is expressed with
	// edges, so no member list is stored on the asset itself.
	Slice            = 11,
	Appointment      = 12,
}

MAX_APPOINTMENT_DESCRIPTION_LENGTH :: 2048
MAX_APPOINTMENT_URL_LENGTH :: 2048

ParentType :: enum u16 {
	None  = 0,
	Task  = 1,
	Asset = 2,
}

PayloadEncoding :: enum u8 {
	Plain = 0,
	Zstd  = 1,
}

Asset :: struct {
	asset_type:       AssetType,
	asset_id:         AssetID,
	parent_type:      ParentType,
	parent_id:        u64,
	owner:            []byte,
	created_at:       i64,
	updated_at:       i64,
	conv_id:          ConversationID,
	payload_encoding: PayloadEncoding,
	payload_raw_len:  u32,
	preview:          []byte,
	payload:          []byte,
	attachments:      []Attachment,
}

// Asset limits
MAX_OWNER_LENGTH :: 64
MAX_PREVIEW_LENGTH :: 4096
MAX_PAYLOAD_LENGTH :: 65535 // Payload length is encoded as u16 on the wire

// ============================================================================
// CreateAsset (C_CreateAsset = 30)
// ============================================================================

CreateAssetRequest :: struct {
	conv_id:          ConversationID,
	asset_type:       AssetType,
	parent_type:      ParentType,
	parent_id:        u64,
	payload_encoding: PayloadEncoding,
	payload_raw_len:  u32,
	preview:          []byte,
	payload:          []byte,
	attachments:      []Attachment,
	correlation_id:   u32, // Client-generated, echoed in S_AssetCreated for request/response correlation
}

// Returned fields borrow data and the caller's attachment descriptors. Without
// a descriptor buffer, only attachment-free requests can be parsed.
parseCreateAssetRequest :: proc(data: []byte, attachments: []Attachment = nil) -> (CreateAssetRequest, ProtocolParseError) {
	return parseCreateAssetRequestWithAttachments(data, attachments)
}

parseCreateAssetRequestWithAttachments :: proc(data: []byte, attachments: []Attachment) -> (CreateAssetRequest, ProtocolParseError) {
	result := CreateAssetRequest{}

	// Minimum: conv_id(8) + asset_type(2) + parent_type(2) + parent_id(8)
	//        + payload_encoding(1) + payload_raw_len(4) + preview_len(2) + payload_len(2)
	if len(data) < 29 {
		log.debugf("CreateAssetRequest payload too short. Need 29, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	asset_type, _ := endian.get_u16(data[offset:], .Big)
	result.asset_type = AssetType(asset_type)
	offset += 2

	parent_type, _ := endian.get_u16(data[offset:], .Big)
	result.parent_type = ParentType(parent_type)
	offset += 2

	parent_id, _ := endian.get_u64(data[offset:], .Big)
	result.parent_id = parent_id
	offset += 8

	payload_encoding := PayloadEncoding(data[offset])
	if payload_encoding != .Plain && payload_encoding != .Zstd {
		return result, .InvalidContentType
	}
	result.payload_encoding = payload_encoding
	offset += 1

	result.payload_raw_len, _ = endian.get_u32(data[offset:], .Big)
	offset += 4
	if int(result.payload_raw_len) > MAX_PAYLOAD_LENGTH {
		return result, .ContentLengthExceedsMax
	}

	// Parse preview
	if len(data) < offset + 2 {
		return result, .TooShort
	}
	preview_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if int(preview_len) > MAX_PREVIEW_LENGTH {
		log.debugf("Asset preview length %v exceeds maximum %v", preview_len, MAX_PREVIEW_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + int(preview_len) {
		return result, .ContentLengthMismatch
	}
	result.preview = data[offset:offset + int(preview_len)]
	offset += int(preview_len)

	// Parse payload
	if len(data) < offset + 2 {
		return result, .TooShort
	}
	payload_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if int(payload_len) > MAX_PAYLOAD_LENGTH {
		log.debugf("Asset payload length %v exceeds maximum %v", payload_len, MAX_PAYLOAD_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + int(payload_len) {
		return result, .ContentLengthMismatch
	}
	result.payload = data[offset:offset + int(payload_len)]
	offset += int(payload_len)

	if result.payload_encoding == .Plain && result.payload_raw_len != u32(payload_len) {
		return result, .ContentLengthMismatch
	}

	if len(data) < offset + 2 + 4 {
		return result, .TooShort
	}
	att_slice, new_offset, att_err := parseAssetAttachmentsFromPayload(data, offset, attachments[:])
	if att_err != nil do return result, att_err
	result.attachments = att_slice
	offset = new_offset

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	if len(data) != offset + 4 {
		return result, .ContentLengthMismatch
	}
	corr_id, _ := endian.get_u32(data[offset:], .Big)
	result.correlation_id = corr_id

	return result, nil
}

// ============================================================================
// UpdateAsset (C_UpdateAsset = 31)
// ============================================================================

UpdateAssetRequest :: struct {
	conv_id:          ConversationID,
	asset_id:         AssetID,
	payload_encoding: PayloadEncoding,
	payload_raw_len:  u32,
	preview:          []byte,
	payload:          []byte,
	attachments:      []Attachment,
	correlation_id:   u32, // Client-generated, echoed in S_AssetUpdated for request/response correlation
}

// Same borrowed-buffer lifetime as parseCreateAssetRequest.
parseUpdateAssetRequest :: proc(data: []byte, attachments: []Attachment = nil) -> (UpdateAssetRequest, ProtocolParseError) {
	return parseUpdateAssetRequestWithAttachments(data, attachments)
}

parseUpdateAssetRequestWithAttachments :: proc(data: []byte, attachments: []Attachment) -> (UpdateAssetRequest, ProtocolParseError) {
	result := UpdateAssetRequest{}

	// Minimum: conv_id(8) + asset_id(8) + payload_encoding(1)
	//        + payload_raw_len(4) + preview_len(2) + payload_len(2)
	if len(data) < 25 {
		log.debugf("UpdateAssetRequest payload too short. Need 25, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	asset_id, _ := endian.get_u64(data[offset:], .Big)
	result.asset_id = AssetID(asset_id)
	offset += 8

	payload_encoding := PayloadEncoding(data[offset])
	if payload_encoding != .Plain && payload_encoding != .Zstd {
		return result, .InvalidContentType
	}
	result.payload_encoding = payload_encoding
	offset += 1

	result.payload_raw_len, _ = endian.get_u32(data[offset:], .Big)
	offset += 4
	if int(result.payload_raw_len) > MAX_PAYLOAD_LENGTH {
		return result, .ContentLengthExceedsMax
	}

	// Parse preview
	if len(data) < offset + 2 {
		return result, .TooShort
	}
	preview_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if int(preview_len) > MAX_PREVIEW_LENGTH {
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + int(preview_len) {
		return result, .ContentLengthMismatch
	}
	result.preview = data[offset:offset + int(preview_len)]
	offset += int(preview_len)

	// Parse payload
	if len(data) < offset + 2 {
		return result, .TooShort
	}
	payload_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if int(payload_len) > MAX_PAYLOAD_LENGTH {
		return result, .ContentLengthExceedsMax
	}

	if len(data) < offset + int(payload_len) {
		return result, .ContentLengthMismatch
	}
	result.payload = data[offset:offset + int(payload_len)]
	offset += int(payload_len)

	if result.payload_encoding == .Plain && result.payload_raw_len != u32(payload_len) {
		return result, .ContentLengthMismatch
	}

	if len(data) < offset + 2 + 4 {
		return result, .TooShort
	}
	att_slice, new_offset, att_err := parseAssetAttachmentsFromPayload(data, offset, attachments[:])
	if att_err != nil do return result, att_err
	result.attachments = att_slice
	offset = new_offset

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	if len(data) != offset + 4 {
		return result, .ContentLengthMismatch
	}
	corr_id, _ := endian.get_u32(data[offset:], .Big)
	result.correlation_id = corr_id

	return result, nil
}

// ============================================================================
// DeleteAsset (C_DeleteAsset = 32)
// ============================================================================

DeleteAssetRequest :: struct {
	conv_id:        ConversationID,
	asset_id:       AssetID,
	correlation_id: u32, // Client-generated, echoed in S_AssetDeleted for request/response correlation
}

parseDeleteAssetRequest :: proc(data: []byte) -> (DeleteAssetRequest, ProtocolParseError) {
	result := DeleteAssetRequest{}

	if len(data) < 16 {
		log.debugf("DeleteAssetRequest payload too short. Need 16, got %v", len(data))
		return result, .TooShort
	}
	if len(data) != 20 {
		if len(data) < 20 {
			return result, .TooShort
		}
		return result, .ContentLengthMismatch
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	asset_id, _ := endian.get_u64(data[8:], .Big)
	result.asset_id = AssetID(asset_id)

	result.correlation_id, _ = endian.get_u32(data[16:], .Big)

	return result, nil
}

// ============================================================================
// GetAsset (C_GetAsset = 33)
// ============================================================================

GetAssetRequest :: struct {
	conv_id:        ConversationID,
	asset_id:       AssetID,
	correlation_id: u32, // Client-generated, echoed in S_AssetFull for request/response correlation
}

parseGetAssetRequest :: proc(data: []byte) -> (GetAssetRequest, ProtocolParseError) {
	result := GetAssetRequest{}

	if len(data) < 16 {
		log.debugf("GetAssetRequest payload too short. Need 16, got %v", len(data))
		return result, .TooShort
	}
	if len(data) != 20 {
		if len(data) < 20 {
			return result, .TooShort
		}
		return result, .ContentLengthMismatch
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	asset_id, _ := endian.get_u64(data[8:], .Big)
	result.asset_id = AssetID(asset_id)

	result.correlation_id, _ = endian.get_u32(data[16:], .Big)

	return result, nil
}

// ============================================================================
// ListAssets (C_ListAssets = 34)
// ============================================================================

ListAssetsRequest :: struct {
	conv_id:        ConversationID,
	asset_type:     AssetType,
	filter_by_type: bool,
	full_content:   bool,
	correlation_id: u32, // Client-generated, echoed in S_AssetList for request/response correlation
}

parseListAssetsRequest :: proc(data: []byte) -> (ListAssetsRequest, ProtocolParseError) {
	result := ListAssetsRequest{}

	if len(data) < 8 {
		log.debugf("ListAssetsRequest payload too short. Need 8, got %v", len(data))
		return result, .TooShort
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	// Optional asset_type filter
	if len(data) >= 11 {
		result.filter_by_type = data[8] == 1
		asset_type, _ := endian.get_u16(data[9:], .Big)
		result.asset_type = AssetType(asset_type)
	}

	// Optional full_content flag
	if len(data) >= 12 {
		result.full_content = data[11] == 1
	}

	if len(data) < 16 {
		return result, .TooShort
	}
	if len(data) != 16 {
		return result, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[12:], .Big)

	return result, nil
}

// ============================================================================
// ListAssetsPaged (C_ListAssetsPaged = 35)
// ============================================================================

ListAssetsPagedRequest :: struct {
	conv_id:           ConversationID,
	asset_type:        AssetType,
	full_content:      bool,
	limit:             u16,
	has_cursor:        bool,
	cursor_updated_at: i64,
	cursor_asset_id:   AssetID,
	correlation_id:    u32, // Client-generated, echoed in S_AssetListPage for request/response correlation
}

parseListAssetsPagedRequest :: proc(data: []byte) -> (ListAssetsPagedRequest, ProtocolParseError) {
	result := ListAssetsPagedRequest{}

	if len(data) < 18 {
		log.debugf("ListAssetsPagedRequest payload too short. Need 18, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	asset_type, _ := endian.get_u16(data[offset:], .Big)
	result.asset_type = AssetType(asset_type)
	offset += 2

	result.full_content = data[offset] == 1
	offset += 1

	limit, _ := endian.get_u16(data[offset:], .Big)
	result.limit = limit
	offset += 2

	result.has_cursor = data[offset] == 1
	offset += 1

	if result.has_cursor {
		if len(data) < offset + 16 {
			log.debugf("ListAssetsPagedRequest cursor payload too short. Need %v, got %v", offset + 16, len(data))
			return result, .TooShort
		}

		cursor_updated_at_u64, _ := endian.get_u64(data[offset:], .Big)
		result.cursor_updated_at = cast(i64)cursor_updated_at_u64
		offset += 8

		cursor_asset_id, _ := endian.get_u64(data[offset:], .Big)
		result.cursor_asset_id = AssetID(cursor_asset_id)
		offset += 8
	}

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	if len(data) != offset + 4 && !(result.has_cursor == false && len(data) == offset + 12) {
		return result, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// S_AssetCreated (Server -> Client, opcode 140)
// ============================================================================

AssetCreatedMessage :: struct {
	asset:          Asset,
	correlation_id: u32, // Echoed from client's CreateAsset request (0 for broadcasts)
}

getSizeAssetCreatedMessage :: proc(msg: AssetCreatedMessage) -> int {
	return 2 + getSizeAsset(msg.asset) + 4 // opcode + asset + correlation_id
}

serializeAssetCreatedMessage :: proc(msg: AssetCreatedMessage, buf: []byte) -> int {
	total_size := getSizeAssetCreatedMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for AssetCreatedMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AssetCreated))
	offset := 2
	asset_size := serializeAsset(msg.asset, buf[offset:])
	if asset_size < 0 {
		return -1
	}
	offset += asset_size
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	offset += 4

	return total_size
}

// Response parsers borrow bytes from data and descriptors from attachments.
// Both buffers must outlive the result. Nil attachments accepts only empty lists.
parseAssetCreatedMessage :: proc(data: []byte, attachments: []Attachment = nil) -> (AssetCreatedMessage, ProtocolParseError) {
	result := AssetCreatedMessage{}
	if len(data) < 6 do return result, .TooShort
	if get_opcode(data) != .S_AssetCreated do return result, .InvalidOpcode

	asset, offset, err := parseAssetFullFromPayload(data, 2, attachments)
	if err != nil do return result, err
	if offset + 4 > len(data) do return result, .TooShort
	if offset + 4 != len(data) do return result, .ContentLengthMismatch

	result.asset = asset
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

// ============================================================================
// S_AssetUpdated (Server -> Client, opcode 141)
// ============================================================================

AssetUpdatedMessage :: struct {
	asset:          Asset,
	correlation_id: u32, // Echoed from client's UpdateAsset request (0 for broadcasts)
}

getSizeAssetUpdatedMessage :: proc(msg: AssetUpdatedMessage) -> int {
	return 2 + getSizeAsset(msg.asset) + 4 // opcode + asset + correlation_id
}

serializeAssetUpdatedMessage :: proc(msg: AssetUpdatedMessage, buf: []byte) -> int {
	total_size := getSizeAssetUpdatedMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for AssetUpdatedMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AssetUpdated))
	offset := 2
	asset_size := serializeAsset(msg.asset, buf[offset:])
	if asset_size < 0 {
		return -1
	}
	offset += asset_size
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseAssetUpdatedMessage :: proc(data: []byte, attachments: []Attachment = nil) -> (AssetUpdatedMessage, ProtocolParseError) {
	result := AssetUpdatedMessage{}
	if len(data) < 6 do return result, .TooShort
	if get_opcode(data) != .S_AssetUpdated do return result, .InvalidOpcode

	asset, offset, err := parseAssetFullFromPayload(data, 2, attachments)
	if err != nil do return result, err
	if offset + 4 > len(data) do return result, .TooShort
	if offset + 4 != len(data) do return result, .ContentLengthMismatch

	result.asset = asset
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

// ============================================================================
// S_AssetDeleted (Server -> Client, opcode 142)
// ============================================================================

AssetDeletedMessage :: struct {
	conv_id:        ConversationID,
	asset_id:       AssetID,
	correlation_id: u32, // Echoed from client's DeleteAsset request (0 for broadcasts)
}

getSizeAssetDeletedMessage :: proc(msg: AssetDeletedMessage) -> int {
	return 2 + 8 + 8 + 4 // opcode + conv_id + asset_id + correlation_id
}

serializeAssetDeletedMessage :: proc(msg: AssetDeletedMessage, buf: []byte) -> int {
	total_size := getSizeAssetDeletedMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for AssetDeletedMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AssetDeleted))
	endian.put_u64(buf[2:10], .Big, u64(msg.conv_id))
	endian.put_u64(buf[10:18], .Big, u64(msg.asset_id))
	endian.put_u32(buf[18:22], .Big, msg.correlation_id)

	return total_size
}

parseAssetDeletedMessage :: proc(data: []byte) -> (AssetDeletedMessage, ProtocolParseError) {
	result := AssetDeletedMessage{}
	if len(data) < getSizeAssetDeletedMessage(result) do return result, .TooShort
	if get_opcode(data) != .S_AssetDeleted do return result, .InvalidOpcode
	if len(data) != getSizeAssetDeletedMessage(result) do return result, .ContentLengthMismatch

	conv_id, _ := endian.get_u64(data[2:], .Big)
	asset_id, _ := endian.get_u64(data[10:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.asset_id = AssetID(asset_id)
	result.correlation_id, _ = endian.get_u32(data[18:], .Big)
	return result, nil
}

// ============================================================================
// S_AssetFull (Server -> Client, opcode 143)
// ============================================================================

AssetFullMessage :: struct {
	asset:          Asset,
	correlation_id: u32, // Echoed from client's GetAsset request (0 when not request-scoped)
}

getSizeAssetFullMessage :: proc(msg: AssetFullMessage) -> int {
	return 2 + getSizeAsset(msg.asset) + 4 // opcode + asset + correlation_id
}

serializeAssetFullMessage :: proc(msg: AssetFullMessage, buf: []byte) -> int {
	total_size := getSizeAssetFullMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for AssetFullMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AssetFull))
	offset := 2
	asset_size := serializeAsset(msg.asset, buf[offset:])
	if asset_size < 0 {
		return -1
	}
	offset += asset_size
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseAssetFullMessage :: proc(data: []byte, attachments: []Attachment = nil) -> (AssetFullMessage, ProtocolParseError) {
	result := AssetFullMessage{}
	if len(data) < 6 do return result, .TooShort
	if get_opcode(data) != .S_AssetFull do return result, .InvalidOpcode

	asset, offset, err := parseAssetFullFromPayload(data, 2, attachments)
	if err != nil do return result, err
	if offset + 4 > len(data) do return result, .TooShort
	if offset + 4 != len(data) do return result, .ContentLengthMismatch

	result.asset = asset
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

// ============================================================================
// S_AssetList (Server -> Client, opcode 144)
// ============================================================================

AssetListMessage :: struct {
	conv_id:        ConversationID,
	assets:         []Asset,
	full_content:   bool,
	correlation_id: u32, // Echoed from client's ListAssets request (0 when not request-scoped)
}

getSizeAssetListMessage :: proc(msg: AssetListMessage) -> int {
	size := 2 + 8 + 1 + 2 + 4 // opcode + conv_id + full_content flag + count + correlation_id
	for asset in msg.assets {
		if msg.full_content {
			size += getSizeAsset(asset) // Full asset with payload
		} else {
			size += getSizeAssetHeader(asset) // Header + preview only, no payload
		}
	}
	return size
}

serializeAssetListMessage :: proc(msg: AssetListMessage, buf: []byte) -> int {
	if len(msg.assets) > 65535 {
		log.errorf("Asset count %v exceeds maximum %v", len(msg.assets), 65535)
		return -1
	}

	total_size := getSizeAssetListMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for AssetListMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AssetList))
	endian.put_u64(buf[2:10], .Big, u64(msg.conv_id))
	buf[10] = msg.full_content ? 1 : 0
	endian.put_u16(buf[11:13], .Big, u16(len(msg.assets)))
	endian.put_u32(buf[13:17], .Big, msg.correlation_id)

	offset := 17
	for asset in msg.assets {
		if msg.full_content {
			asset_size := serializeAsset(asset, buf[offset:])
			if asset_size < 0 {
				return -1
			}
			offset += asset_size
		} else {
			asset_size := serializeAssetHeader(asset, buf[offset:])
			if asset_size < 0 {
				return -1
			}
			offset += asset_size
		}
	}

	return total_size
}

// attachments holds the sum of descriptors across all assets, not just one.
// The caller owns result.assets (including on error) and deletes it with allocator.
parseAssetListMessage :: proc(
	data: []byte,
	allocator := context.allocator,
	attachments: []Attachment = nil,
) -> (
	result: AssetListMessage,
	err: ProtocolParseError,
) {
	if len(data) < 17 do return result, .TooShort
	if get_opcode(data) != .S_AssetList do return result, .InvalidOpcode

	conv_id, _ := endian.get_u64(data[2:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.full_content = data[10] != 0
	count, _ := endian.get_u16(data[11:], .Big)
	result.correlation_id, _ = endian.get_u32(data[13:], .Big)

	pos := 17
	attachment_pos := 0
	if count > 0 {
		result.assets = make([]Asset, count, allocator)
		for i in 0 ..< int(count) {
			asset: Asset
			asset_err: ProtocolParseError
			if result.full_content {
				asset, pos, asset_err = parseAssetFullFromPayload(data, pos, attachments[attachment_pos:])
			} else {
				asset, pos, asset_err = parseAssetFromPayload(data, pos, attachments[attachment_pos:])
			}
			if asset_err != nil do return result, asset_err
			result.assets[i] = asset
			attachment_pos += len(asset.attachments)
		}
	}
	if pos != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

// ============================================================================
// S_AssetListPage (Server -> Client, opcode 145)
// ============================================================================

AssetListPageMessage :: struct {
	conv_id:                ConversationID,
	assets:                 []Asset,
	full_content:           bool,
	has_more:               bool,
	next_cursor_updated_at: i64,
	next_cursor_asset_id:   AssetID,
	total_count:            u32,
	correlation_id:         u32, // Echoed from client's ListAssetsPaged request (0 when not request-scoped)
}

// Buffer lifetime and ownership are the same as parseAssetListMessage.
parseAssetListPageMessage :: proc(
	data: []byte,
	allocator := context.allocator,
	attachments: []Attachment = nil,
) -> (
	AssetListPageMessage,
	ProtocolParseError,
) {
	result := AssetListPageMessage{}
	if len(data) < 38 do return result, .TooShort
	if get_opcode(data) != .S_AssetListPage do return result, .InvalidOpcode

	conv_id, _ := endian.get_u64(data[2:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.full_content = data[10] != 0
	result.has_more = data[11] != 0
	next_cursor_updated_at, _ := endian.get_u64(data[12:], .Big)
	result.next_cursor_updated_at = cast(i64)next_cursor_updated_at
	next_cursor_asset_id, _ := endian.get_u64(data[20:], .Big)
	result.next_cursor_asset_id = AssetID(next_cursor_asset_id)
	result.total_count, _ = endian.get_u32(data[28:], .Big)
	count, _ := endian.get_u16(data[32:], .Big)
	result.correlation_id, _ = endian.get_u32(data[34:], .Big)

	pos := 38
	attachment_pos := 0
	if count > 0 {
		result.assets = make([]Asset, count, allocator)
		for i in 0 ..< int(count) {
			asset: Asset
			err: ProtocolParseError
			if result.full_content {
				asset, pos, err = parseAssetFullFromPayload(data, pos, attachments[attachment_pos:])
			} else {
				asset, pos, err = parseAssetFromPayload(data, pos, attachments[attachment_pos:])
			}
			if err != nil do return result, err
			result.assets[i] = asset
			attachment_pos += len(asset.attachments)
		}
	}
	if pos != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

getSizeAssetListPageMessage :: proc(msg: AssetListPageMessage) -> int {
	size := 2 + 8 + 1 + 1 + 8 + 8 + 4 + 2 + 4 // opcode + conv_id + full_content + has_more + next cursor + total_count + count + correlation_id
	for asset in msg.assets {
		if msg.full_content {
			size += getSizeAsset(asset)
		} else {
			size += getSizeAssetHeader(asset)
		}
	}
	return size
}

serializeAssetListPageMessage :: proc(msg: AssetListPageMessage, buf: []byte) -> int {
	if len(msg.assets) > 65535 {
		log.errorf("Asset count %v exceeds maximum %v", len(msg.assets), 65535)
		return -1
	}

	total_size := getSizeAssetListPageMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for AssetListPageMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AssetListPage))
	endian.put_u64(buf[2:10], .Big, u64(msg.conv_id))
	buf[10] = msg.full_content ? 1 : 0
	buf[11] = msg.has_more ? 1 : 0
	endian.put_u64(buf[12:20], .Big, cast(u64)msg.next_cursor_updated_at)
	endian.put_u64(buf[20:28], .Big, u64(msg.next_cursor_asset_id))
	endian.put_u32(buf[28:32], .Big, msg.total_count)
	endian.put_u16(buf[32:34], .Big, u16(len(msg.assets)))
	endian.put_u32(buf[34:38], .Big, msg.correlation_id)

	offset := 38
	for asset in msg.assets {
		if msg.full_content {
			asset_size := serializeAsset(asset, buf[offset:])
			if asset_size < 0 {
				return -1
			}
			offset += asset_size
		} else {
			asset_size := serializeAssetHeader(asset, buf[offset:])
			if asset_size < 0 {
				return -1
			}
			offset += asset_size
		}
	}

	return total_size
}

// ============================================================================
// Asset Serialization Helpers
// ============================================================================

getSizeAsset :: proc(asset: Asset) -> int {
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
		getSizeAssetAttachments(asset.attachments) \
	) // asset_type// asset_id// parent_type// parent_id// owner// created_at// updated_at// conv_id// payload_encoding// payload_raw_len// preview// payload// attachments
}

getSizeAssetHeader :: proc(asset: Asset) -> int {
	return 2 + 8 + 2 + 8 + 2 + len(asset.owner) + 8 + 8 + 8 + 1 + 4 + 2 + len(asset.preview) + getSizeAssetAttachments(asset.attachments) // asset_type// asset_id// parent_type// parent_id// owner// created_at// updated_at// conv_id// payload_encoding// payload_raw_len// preview// attachments, no payload
}

getSizeAssetAttachments :: proc(attachments: []Attachment) -> int {
	size := 2
	for att in attachments {
		size += 2 + len(att.file_id) + 2 + len(att.filename) + 8 + 2 + len(att.mime_type) + 8
	}
	return size
}

validateAssetAttachments :: proc(attachments: []Attachment) -> bool {
	if len(attachments) > MAX_ATTACHMENTS_PER_TASK {
		log.errorf("Asset attachment count %v exceeds maximum %v", len(attachments), MAX_ATTACHMENTS_PER_TASK)
		return false
	}
	for att in attachments {
		if len(att.file_id) > MAX_FILE_ID_LENGTH {
			log.errorf("Attachment file_id length %v exceeds maximum %v", len(att.file_id), MAX_FILE_ID_LENGTH)
			return false
		}
		if len(att.filename) > MAX_FILENAME_LENGTH {
			log.errorf("Attachment filename length %v exceeds maximum %v", len(att.filename), MAX_FILENAME_LENGTH)
			return false
		}
		if len(att.mime_type) > MAX_MIME_TYPE_LENGTH {
			log.errorf("Attachment mime_type length %v exceeds maximum %v", len(att.mime_type), MAX_MIME_TYPE_LENGTH)
			return false
		}
	}
	return true
}

serializeAssetAttachments :: proc(attachments: []Attachment, buf: []byte) -> int {
	if !validateAssetAttachments(attachments) do return -1
	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(len(attachments)))
	offset += 2
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
	return offset
}

serializeAsset :: proc(asset: Asset, buf: []byte) -> int {
	if len(asset.owner) > MAX_OWNER_LENGTH {
		log.errorf("Asset owner length %v exceeds maximum %v", len(asset.owner), MAX_OWNER_LENGTH)
		return -1
	}
	if len(asset.preview) > MAX_PREVIEW_LENGTH {
		log.errorf("Asset preview length %v exceeds maximum %v", len(asset.preview), MAX_PREVIEW_LENGTH)
		return -1
	}
	if len(asset.payload) > MAX_PAYLOAD_LENGTH {
		log.errorf("Asset payload length %v exceeds maximum %v", len(asset.payload), MAX_PAYLOAD_LENGTH)
		return -1
	}
	if int(asset.payload_raw_len) > MAX_PAYLOAD_LENGTH {
		log.errorf("Asset payload raw length %v exceeds maximum %v", asset.payload_raw_len, MAX_PAYLOAD_LENGTH)
		return -1
	}
	if !validateAssetAttachments(asset.attachments) do return -1
	if asset.payload_encoding == .Plain && asset.payload_raw_len != u32(len(asset.payload)) {
		log.errorf("Plain asset payload raw length %v does not match payload length %v", asset.payload_raw_len, len(asset.payload))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(asset.asset_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(asset.asset_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(asset.parent_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, asset.parent_id)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(len(asset.owner)))
	offset += 2
	if len(asset.owner) > 0 {
		copy(buf[offset:], asset.owner)
		offset += len(asset.owner)
	}

	endian.put_u64(buf[offset:], .Big, cast(u64)asset.created_at)
	offset += 8

	endian.put_u64(buf[offset:], .Big, cast(u64)asset.updated_at)
	offset += 8

	endian.put_u64(buf[offset:], .Big, u64(asset.conv_id))
	offset += 8

	buf[offset] = u8(asset.payload_encoding)
	offset += 1

	endian.put_u32(buf[offset:], .Big, asset.payload_raw_len)
	offset += 4

	endian.put_u16(buf[offset:], .Big, u16(len(asset.preview)))
	offset += 2
	if len(asset.preview) > 0 {
		copy(buf[offset:], asset.preview)
		offset += len(asset.preview)
	}

	endian.put_u16(buf[offset:], .Big, u16(len(asset.payload)))
	offset += 2
	if len(asset.payload) > 0 {
		copy(buf[offset:], asset.payload)
		offset += len(asset.payload)
	}

	attachments_size := serializeAssetAttachments(asset.attachments, buf[offset:])
	if attachments_size < 0 do return -1
	offset += attachments_size

	return offset
}

serializeAssetHeader :: proc(asset: Asset, buf: []byte) -> int {
	if len(asset.owner) > MAX_OWNER_LENGTH {
		log.errorf("Asset owner length %v exceeds maximum %v", len(asset.owner), MAX_OWNER_LENGTH)
		return -1
	}
	if len(asset.preview) > MAX_PREVIEW_LENGTH {
		log.errorf("Asset preview length %v exceeds maximum %v", len(asset.preview), MAX_PREVIEW_LENGTH)
		return -1
	}
	if int(asset.payload_raw_len) > MAX_PAYLOAD_LENGTH {
		log.errorf("Asset payload raw length %v exceeds maximum %v", asset.payload_raw_len, MAX_PAYLOAD_LENGTH)
		return -1
	}
	if !validateAssetAttachments(asset.attachments) do return -1

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(asset.asset_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(asset.asset_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(asset.parent_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, asset.parent_id)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(len(asset.owner)))
	offset += 2
	if len(asset.owner) > 0 {
		copy(buf[offset:], asset.owner)
		offset += len(asset.owner)
	}

	endian.put_u64(buf[offset:], .Big, cast(u64)asset.created_at)
	offset += 8

	endian.put_u64(buf[offset:], .Big, cast(u64)asset.updated_at)
	offset += 8

	endian.put_u64(buf[offset:], .Big, u64(asset.conv_id))
	offset += 8

	buf[offset] = u8(asset.payload_encoding)
	offset += 1

	endian.put_u32(buf[offset:], .Big, asset.payload_raw_len)
	offset += 4

	endian.put_u16(buf[offset:], .Big, u16(len(asset.preview)))
	offset += 2
	if len(asset.preview) > 0 {
		copy(buf[offset:], asset.preview)
		offset += len(asset.preview)
	}

	attachments_size := serializeAssetAttachments(asset.attachments, buf[offset:])
	if attachments_size < 0 do return -1
	offset += attachments_size

	return offset
}

// ============================================================================
// ListAssetsPagedByProject (C_ListAssetsPagedByProject = 36)
// ============================================================================

ListAssetsPagedByProjectRequest :: struct {
	conv_id:           ConversationID,
	asset_type:        AssetType,
	full_content:      bool,
	limit:             u16,
	has_cursor:        bool,
	cursor_updated_at: i64,
	cursor_asset_id:   AssetID,
	project:           string,
	correlation_id:    u32,
}

parseListAssetsPagedByProjectRequest :: proc(data: []byte) -> (ListAssetsPagedByProjectRequest, ProtocolParseError) {
	result := ListAssetsPagedByProjectRequest{}

	if len(data) < 20 {
		log.debugf("ListAssetsPagedByProjectRequest payload too short. Need 20, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	asset_type, _ := endian.get_u16(data[offset:], .Big)
	result.asset_type = AssetType(asset_type)
	offset += 2

	result.full_content = data[offset] == 1
	offset += 1

	limit, _ := endian.get_u16(data[offset:], .Big)
	result.limit = limit
	offset += 2

	result.has_cursor = data[offset] == 1
	offset += 1

	if result.has_cursor {
		if len(data) < offset + 16 {
			log.debugf("ListAssetsPagedByProjectRequest cursor payload too short. Need %v, got %v", offset + 16, len(data))
			return result, .TooShort
		}

		cursor_updated_at_u64, _ := endian.get_u64(data[offset:], .Big)
		result.cursor_updated_at = cast(i64)cursor_updated_at_u64
		offset += 8

		cursor_asset_id, _ := endian.get_u64(data[offset:], .Big)
		result.cursor_asset_id = AssetID(cursor_asset_id)
		offset += 8
	}

	if len(data) < offset + 2 {
		return result, .TooShort
	}

	project_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if len(data) < offset + int(project_len) + 4 {
		return result, .TooShort
	}
	if len(data) != offset + int(project_len) + 4 {
		return result, .ContentLengthMismatch
	}

	result.project = string(data[offset:offset + int(project_len)])
	offset += int(project_len)

	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// ListAssetsPagedByTag (C_ListAssetsPagedByTag = 38)
// ============================================================================

ListAssetsPagedByTagRequest :: struct {
	conv_id:           ConversationID,
	asset_type:        AssetType,
	full_content:      bool,
	limit:             u16,
	has_cursor:        bool,
	cursor_updated_at: i64,
	cursor_asset_id:   AssetID,
	tag:               string,
	correlation_id:    u32,
}

parseListAssetsPagedByTagRequest :: proc(data: []byte) -> (ListAssetsPagedByTagRequest, ProtocolParseError) {
	result := ListAssetsPagedByTagRequest{}

	if len(data) < 20 {
		log.debugf("ListAssetsPagedByTagRequest payload too short. Need 20, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	asset_type, _ := endian.get_u16(data[offset:], .Big)
	result.asset_type = AssetType(asset_type)
	offset += 2

	result.full_content = data[offset] == 1
	offset += 1

	limit, _ := endian.get_u16(data[offset:], .Big)
	result.limit = limit
	offset += 2

	result.has_cursor = data[offset] == 1
	offset += 1

	if result.has_cursor {
		if len(data) < offset + 16 {
			log.debugf("ListAssetsPagedByTagRequest cursor payload too short. Need %v, got %v", offset + 16, len(data))
			return result, .TooShort
		}

		cursor_updated_at_u64, _ := endian.get_u64(data[offset:], .Big)
		result.cursor_updated_at = cast(i64)cursor_updated_at_u64
		offset += 8

		cursor_asset_id, _ := endian.get_u64(data[offset:], .Big)
		result.cursor_asset_id = AssetID(cursor_asset_id)
		offset += 8
	}

	if len(data) < offset + 2 {
		return result, .TooShort
	}

	tag_len, _ := endian.get_u16(data[offset:], .Big)
	offset += 2

	if len(data) < offset + int(tag_len) + 4 {
		return result, .TooShort
	}
	if len(data) != offset + int(tag_len) + 4 {
		return result, .ContentLengthMismatch
	}

	result.tag = string(data[offset:offset + int(tag_len)])
	offset += int(tag_len)

	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// ListNoteProjects (C_ListNoteProjects = 37)
// ============================================================================

ListNoteProjectsRequest :: struct {
	conv_id:        ConversationID,
	correlation_id: u32,
}

parseListNoteProjectsRequest :: proc(data: []byte) -> (ListNoteProjectsRequest, ProtocolParseError) {
	result := ListNoteProjectsRequest{}

	if len(data) < 12 {
		return result, .TooShort
	}
	if len(data) != 12 {
		return result, .ContentLengthMismatch
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.correlation_id, _ = endian.get_u32(data[8:], .Big)

	return result, nil
}

// ============================================================================
// ListNoteTags (C_ListNoteTags = 39)
// ============================================================================

ListNoteTagsRequest :: struct {
	conv_id:        ConversationID,
	correlation_id: u32,
}

parseListNoteTagsRequest :: proc(data: []byte) -> (ListNoteTagsRequest, ProtocolParseError) {
	result := ListNoteTagsRequest{}

	if len(data) < 12 {
		return result, .TooShort
	}
	if len(data) != 12 {
		return result, .ContentLengthMismatch
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.correlation_id, _ = endian.get_u32(data[8:], .Big)

	return result, nil
}

// ============================================================================
// S_NoteProjectList (Server -> Client, opcode 146)
// ============================================================================

NoteProjectListMessage :: struct {
	conv_id:        ConversationID,
	projects:       []string,
	correlation_id: u32,
}

parseNoteProjectListMessage :: proc(data: []byte, allocator := context.allocator) -> (NoteProjectListMessage, ProtocolParseError) {
	result := NoteProjectListMessage{}
	if len(data) < 16 do return result, .TooShort
	if get_opcode(data) != .S_NoteProjectList do return result, .InvalidOpcode

	conv_id, _ := endian.get_u64(data[2:], .Big)
	result.conv_id = ConversationID(conv_id)
	count, _ := endian.get_u16(data[10:], .Big)
	result.correlation_id, _ = endian.get_u32(data[12:], .Big)

	pos := 16
	if count > 0 {
		result.projects = make([]string, count, allocator)
		for i in 0 ..< int(count) {
			if pos + 2 > len(data) do return result, .TooShort
			value_len, _ := endian.get_u16(data[pos:], .Big)
			pos += 2
			if pos + int(value_len) > len(data) do return result, .ContentLengthMismatch
			result.projects[i] = string(data[pos:pos + int(value_len)])
			pos += int(value_len)
		}
	}
	if pos != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

getSizeNoteProjectListMessage :: proc(msg: NoteProjectListMessage) -> int {
	size := 2 + 8 + 2 + 4 // opcode + conv_id + count + correlation_id
	for project in msg.projects {
		size += 2 + len(project)
	}
	return size
}

serializeNoteProjectListMessage :: proc(msg: NoteProjectListMessage, buf: []byte) -> int {
	if len(msg.projects) > 65535 {
		log.errorf("Project count %v exceeds maximum %v", len(msg.projects), 65535)
		return -1
	}

	total_size := getSizeNoteProjectListMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for NoteProjectListMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_NoteProjectList))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(len(msg.projects)))
	offset += 2

	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	offset += 4

	for project in msg.projects {
		endian.put_u16(buf[offset:], .Big, u16(len(project)))
		offset += 2
		if len(project) > 0 {
			copy(buf[offset:], project)
			offset += len(project)
		}
	}

	return offset
}

// ============================================================================
// S_NoteTagList (Server -> Client, opcode 147)
// ============================================================================

NoteTagListMessage :: struct {
	conv_id:        ConversationID,
	tags:           []string,
	correlation_id: u32,
}

parseNoteTagListMessage :: proc(data: []byte, allocator := context.allocator) -> (NoteTagListMessage, ProtocolParseError) {
	result := NoteTagListMessage{}
	if len(data) < 16 do return result, .TooShort
	if get_opcode(data) != .S_NoteTagList do return result, .InvalidOpcode

	conv_id, _ := endian.get_u64(data[2:], .Big)
	result.conv_id = ConversationID(conv_id)
	count, _ := endian.get_u16(data[10:], .Big)
	result.correlation_id, _ = endian.get_u32(data[12:], .Big)

	pos := 16
	if count > 0 {
		result.tags = make([]string, count, allocator)
		for i in 0 ..< int(count) {
			if pos + 2 > len(data) do return result, .TooShort
			value_len, _ := endian.get_u16(data[pos:], .Big)
			pos += 2
			if pos + int(value_len) > len(data) do return result, .ContentLengthMismatch
			result.tags[i] = string(data[pos:pos + int(value_len)])
			pos += int(value_len)
		}
	}
	if pos != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

getSizeNoteTagListMessage :: proc(msg: NoteTagListMessage) -> int {
	size := 2 + 8 + 2 + 4 // opcode + conv_id + count + correlation_id
	for tag in msg.tags {
		size += 2 + len(tag)
	}
	return size
}

serializeNoteTagListMessage :: proc(msg: NoteTagListMessage, buf: []byte) -> int {
	if len(msg.tags) > 65535 {
		log.errorf("Tag count %v exceeds maximum %v", len(msg.tags), 65535)
		return -1
	}

	total_size := getSizeNoteTagListMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for NoteTagListMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_NoteTagList))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(len(msg.tags)))
	offset += 2

	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	offset += 4

	for tag in msg.tags {
		endian.put_u16(buf[offset:], .Big, u16(len(tag)))
		offset += 2
		if len(tag) > 0 {
			copy(buf[offset:], tag)
			offset += len(tag)
		}
	}

	return offset
}
