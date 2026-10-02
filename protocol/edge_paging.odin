package protocol

import "core:encoding/endian"

// Pages enumerate the live room in ascending edge_id order, strictly after the
// supplied cursor (zero starts a scan). They are not a retained snapshot.
ListAllEdgesPagedRequest :: struct {
	conv_id:        ConversationID,
	limit:          u16,
	after_edge_id:  EdgeID,
	correlation_id: u32,
}

getSizeListAllEdgesPagedRequest :: proc() -> int {return 24}

serializeListAllEdgesPagedRequest :: proc(req: ListAllEdgesPagedRequest, buf: []byte) -> int {
	if len(buf) < 24 do return -1
	endian.put_u16(buf[0:], .Big, u16(Opcode.C_ListAllEdgesPaged))
	endian.put_u64(buf[2:], .Big, u64(req.conv_id))
	endian.put_u16(buf[10:], .Big, req.limit)
	endian.put_u64(buf[12:], .Big, u64(req.after_edge_id))
	endian.put_u32(buf[20:], .Big, req.correlation_id)
	return 24
}

parseListAllEdgesPagedRequest :: proc(data: []byte) -> (result: ListAllEdgesPagedRequest, err: ProtocolParseError) {
	if len(data) < 22 do return result, .TooShort
	if len(data) != 22 do return result, .ContentLengthMismatch
	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.limit, _ = endian.get_u16(data[8:], .Big)
	cursor, _ := endian.get_u64(data[10:], .Big)
	result.after_edge_id = EdgeID(cursor)
	result.correlation_id, _ = endian.get_u32(data[18:], .Big)
	return
}

// opcode(2), conv_id(8), has_more(1), next_edge_id(8), total_count(4),
// count(2), correlation_id(4), then count standard Edge records.
AllEdgeListPageMessage :: struct {
	conv_id:        ConversationID,
	has_more:       bool,
	next_edge_id:   EdgeID,
	total_count:    u32,
	edges:          []Edge,
	correlation_id: u32,
}

getSizeAllEdgeListPageMessage :: proc(msg: AllEdgeListPageMessage) -> int {
	size := 29
	for edge in msg.edges do size += getSizeEdge(edge)
	return size
}

serializeAllEdgeListPageMessage :: proc(msg: AllEdgeListPageMessage, buf: []byte) -> int {
	if len(msg.edges) > 65535 || len(buf) < getSizeAllEdgeListPageMessage(msg) do return -1
	endian.put_u16(buf[0:], .Big, u16(Opcode.S_AllEdgeListPage))
	endian.put_u64(buf[2:], .Big, u64(msg.conv_id))
	buf[10] = msg.has_more ? 1 : 0
	endian.put_u64(buf[11:], .Big, u64(msg.next_edge_id))
	endian.put_u32(buf[19:], .Big, msg.total_count)
	endian.put_u16(buf[23:], .Big, u16(len(msg.edges)))
	endian.put_u32(buf[25:], .Big, msg.correlation_id)
	pos := 29
	for edge in msg.edges {
		written := serializeEdge(edge, buf[pos:])
		if written < 0 do return -1
		pos += written
	}
	return pos
}

parseAllEdgeListPageMessage :: proc(data: []byte, edges: []Edge) -> (result: AllEdgeListPageMessage, err: ProtocolParseError) {
	if len(data) < 29 do return result, .TooShort
	if get_opcode(data) != .S_AllEdgeListPage do return result, .InvalidOpcode
	if data[10] > 1 do return result, .InvalidValue
	conv_id, _ := endian.get_u64(data[2:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.has_more = data[10] == 1
	cursor, _ := endian.get_u64(data[11:], .Big)
	result.next_edge_id = EdgeID(cursor)
	result.total_count, _ = endian.get_u32(data[19:], .Big)
	count, _ := endian.get_u16(data[23:], .Big)
	result.correlation_id, _ = endian.get_u32(data[25:], .Big)
	if int(count) > len(edges) do return result, .TooMany
	pos := 29
	for i in 0 ..< int(count) {
		edge, next, parse_err := parse_edge_from_payload(data, pos)
		if parse_err != nil do return result, parse_err
		edges[i] = edge
		pos = next
	}
	if pos != len(data) do return result, .ContentLengthMismatch
	result.edges = edges[:count]
	return
}
