package protocol

import "core:encoding/endian"

MAX_ID_BATCH_SIZE :: 64

// Exact set lookup. Missing/invisible IDs are omitted. Responses reuse the
// corresponding list-page codec, with one correlation across all chunks.
// has_more means another response chunk follows, not another request is needed.
// Cursor fields are zero. No list/filter cache is made complete by these reads.
GetRecordsByIDsRequest :: struct {
	conv_id:        ConversationID,
	correlation_id: u32,
	full_content:   bool,
	ids:            []u64,
}

parseGetRecordsByIDsRequest :: proc(data: []byte, ids: []u64) -> (result: GetRecordsByIDsRequest, err: ProtocolParseError) {
	if len(data) < 15 do return result, .TooShort
	scope, _ := endian.get_u64(data, .Big)
	result.conv_id = ConversationID(scope)
	result.correlation_id, _ = endian.get_u32(data[8:], .Big)
	if data[12] > 1 do return result, .InvalidContentType
	result.full_content = data[12] == 1
	count, _ := endian.get_u16(data[13:], .Big)
	if count > MAX_ID_BATCH_SIZE || int(count) > len(ids) do return result, .TooMany
	if len(data) != 15 + 8 * int(count) do return result, .ContentLengthMismatch
	result.ids = ids[:count]
	for &id, i in result.ids {
		id, _ = endian.get_u64(data[15 + 8 * i:], .Big)
	}
	return result, nil
}
