package protocol

import "core:encoding/endian"
import "core:unicode/utf8"

MAX_CUSTOMER_SEARCH_QUERY :: 256

ListEdgesPagedRequest :: struct {
	conv_id:        ConversationID,
	target_type:    TargetType,
	target_id:      u64,
	limit:          u16,
	after_edge_id:  EdgeID,
	correlation_id: u32,
}

parseListEdgesPagedRequest :: proc(data: []byte) -> (r: ListEdgesPagedRequest, err: ProtocolParseError) {
	if len(data) < 32 do return r, .TooShort
	if len(data) != 32 do return r, .ContentLengthMismatch
	v64, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v64)
	v16, _ := endian.get_u16(data[8:], .Big); r.target_type = TargetType(v16)
	if r.target_type != .Asset && r.target_type != .Task do return r, .InvalidValue
	r.target_id, _ = endian.get_u64(data[10:], .Big)
	r.limit, _ = endian.get_u16(data[18:], .Big)
	v64, _ = endian.get_u64(data[20:], .Big); r.after_edge_id = EdgeID(v64)
	r.correlation_id, _ = endian.get_u32(data[28:], .Big)
	return
}

EdgeListPageMessage :: struct {
	conv_id:        ConversationID,
	target_type:    TargetType,
	target_id:      u64,
	has_more:       bool,
	next_edge_id:   EdgeID,
	total_count:    u32,
	edges:          []Edge,
	correlation_id: u32,
}

getSizeEdgeListPageMessage :: proc(m: EdgeListPageMessage) -> int {
	n := 39
	for edge in m.edges do n += getSizeEdge(edge)
	return n
}

serializeEdgeListPageMessage :: proc(m: EdgeListPageMessage, buf: []byte) -> int {
	if len(m.edges) > 65535 || len(buf) < getSizeEdgeListPageMessage(m) do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_EdgeListPage)); endian.put_u64(buf[2:], .Big, u64(m.conv_id))
	endian.put_u16(buf[10:], .Big, u16(m.target_type)); endian.put_u64(buf[12:], .Big, m.target_id)
	buf[20] = m.has_more ? 1 : 0; endian.put_u64(buf[21:], .Big, u64(m.next_edge_id))
	endian.put_u32(buf[29:], .Big, m.total_count); endian.put_u16(buf[33:], .Big, u16(len(m.edges)))
	endian.put_u32(buf[35:], .Big, m.correlation_id)
	o := 39
	for edge in m.edges {n := serializeEdge(edge, buf[o:]); if n < 0 do return -1; o += n}
	return o
}

SearchCustomersRequest :: struct {
	conv_id:          ConversationID,
	limit:            u16,
	after_company_id: AssetID,
	include_archived: bool,
	query:            []byte,
	correlation_id:   u32,
}

parseSearchCustomersRequest :: proc(data: []byte) -> (r: SearchCustomersRequest, err: ProtocolParseError) {
	if len(data) < 25 do return r, .TooShort
	v64, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(v64)
	r.limit, _ = endian.get_u16(data[8:], .Big)
	v64, _ = endian.get_u64(data[10:], .Big); r.after_company_id = AssetID(v64)
	if data[18] > 1 do return r, .InvalidValue
	r.include_archived = data[18] == 1
	query_len, _ := endian.get_u16(data[19:], .Big)
	if query_len > MAX_CUSTOMER_SEARCH_QUERY do return r, .ContentLengthExceedsMax
	if len(data) != 25 + int(query_len) do return r, .ContentLengthMismatch
	r.query = data[21:21 + int(query_len)]
	if !utf8.valid_string(string(r.query)) do return r, .InvalidValue
	r.correlation_id, _ = endian.get_u32(data[21 + int(query_len):], .Big)
	return
}

CustomerSearchPageMessage :: struct {
	conv_id:         ConversationID,
	has_more:        bool,
	next_company_id: AssetID,
	total_count:     u32,
	assets:          []Asset,
	correlation_id:  u32,
}

getSizeCustomerSearchPageMessage :: proc(m: CustomerSearchPageMessage) -> int {
	n := 29
	for asset in m.assets do n += getSizeAssetHeader(asset)
	return n
}

serializeCustomerSearchPageMessage :: proc(m: CustomerSearchPageMessage, buf: []byte) -> int {
	if len(m.assets) > 65535 || len(buf) < getSizeCustomerSearchPageMessage(m) do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_CustomerSearchPage)); endian.put_u64(buf[2:], .Big, u64(m.conv_id))
	buf[10] = m.has_more ? 1 : 0; endian.put_u64(buf[11:], .Big, u64(m.next_company_id))
	endian.put_u32(buf[19:], .Big, m.total_count); endian.put_u16(buf[23:], .Big, u16(len(m.assets)))
	endian.put_u32(buf[25:], .Big, m.correlation_id)
	o := 29
	for asset in m.assets {n := serializeAssetHeader(asset, buf[o:]); if n < 0 do return -1; o += n}
	return o
}
