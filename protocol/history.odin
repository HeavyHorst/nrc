package protocol

import "core:encoding/endian"

// C_ListHistory (62): scope:u64, kind:u8, entity:u64, before:u64, limit:u16,
// correlation_id:u32. Kind 0 selects every entity type and carries no entity
// id; 1, 2 and 3 select a task, an asset or an edge and require one.
ListHistoryRequest :: struct {
	conv_id:        ConversationID,
	kind:           u8,
	entity:         u64,
	before:         u64,
	limit:          u16,
	correlation_id: u32,
}

LIST_HISTORY_REQUEST_SIZE :: 31
MAX_HISTORY_PAGE_SIZE :: 100
MAX_HISTORY_KIND :: 3

parseListHistoryRequest :: proc(data: []byte) -> (result: ListHistoryRequest, err: ProtocolParseError) {
	// Every response echoes the correlation id, including the error response, so
	// it is read before the body is validated.
	if len(data) >= LIST_HISTORY_REQUEST_SIZE {
		result.correlation_id, _ = endian.get_u32(data[27:], .Big)
	}
	if len(data) < LIST_HISTORY_REQUEST_SIZE do return result, .TooShort
	if len(data) > LIST_HISTORY_REQUEST_SIZE do return result, .ContentLengthMismatch
	scope, scope_ok := endian.get_u64(data, .Big)
	if !scope_ok || ConversationID(scope) != WORKSPACE_DATA_ID do return result, .ContentLengthMismatch
	result.conv_id = WORKSPACE_DATA_ID
	result.kind = data[8]
	result.entity, _ = endian.get_u64(data[9:], .Big)
	result.before, _ = endian.get_u64(data[17:], .Big)
	result.limit, _ = endian.get_u16(data[25:], .Big)
	if result.kind > MAX_HISTORY_KIND ||
	   (result.kind == 0 && result.entity != 0) ||
	   (result.kind != 0 && result.entity == 0) ||
	   result.limit < 1 ||
	   result.limit > MAX_HISTORY_PAGE_SIZE {
		return result, .InvalidValue
	}
	return result, nil
}
