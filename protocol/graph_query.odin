package protocol

import "core:encoding/endian"
import "core:log"

// ============================================================================
// Graph Query Types
// ============================================================================

Direction :: enum u8 {
	Both     = 0,
	Outgoing = 1,
	Incoming = 2,
}

GraphEntityKey :: struct {
	target_type: TargetType,
	target_id:   u64,
}

GraphQueryNode :: struct {
	target_type: TargetType,
	target_id:   u64,
	depth:       u8,
}

GraphPathNode :: struct {
	target_type: TargetType,
	target_id:   u64,
}

GraphDegreeEntry :: struct {
	target_type: TargetType,
	target_id:   u64,
	degree:      u16,
}

// ============================================================================
// Shared Helpers
// ============================================================================

relation_matches_mask :: proc(relation: RelationType, mask: u16) -> bool {
	if mask == 0 {
		return true
	}
	r := u16(relation)
	if r < 1 || r > 7 {
		return false
	}
	return (mask & (1 << (r - 1))) != 0
}

resolve_neighbor :: proc(edge: ^Edge, node_type: TargetType, node_id: u64, direction: Direction) -> (GraphEntityKey, bool) {
	if edge.source_type == node_type && edge.source_id == node_id {
		if direction == .Incoming {
			return {}, false
		}
		return GraphEntityKey{edge.target_type, edge.target_id}, true
	}
	if edge.target_type == node_type && edge.target_id == node_id {
		if direction == .Outgoing {
			return {}, false
		}
		return GraphEntityKey{edge.source_type, edge.source_id}, true
	}
	return {}, false
}

parse_edge_from_payload :: proc(data: []byte, offset: int) -> (edge: Edge, next_offset: int, err: ProtocolParseError) {
	if offset + 48 > len(data) do return {}, offset, .TooShort
	pos := offset

	edge_id_raw, edge_id_ok := endian.get_u64(data[pos:], .Big)
	if !edge_id_ok do return {}, offset, .TooShort
	edge.edge_id = EdgeID(edge_id_raw)
	pos += 8

	conv_id_raw, conv_id_ok := endian.get_u64(data[pos:], .Big)
	if !conv_id_ok do return {}, offset, .TooShort
	edge.conv_id = ConversationID(conv_id_raw)
	pos += 8

	source_type_raw, source_type_ok := endian.get_u16(data[pos:], .Big)
	if !source_type_ok do return {}, offset, .TooShort
	edge.source_type = TargetType(source_type_raw)
	pos += 2

	source_id, source_id_ok := endian.get_u64(data[pos:], .Big)
	if !source_id_ok do return {}, offset, .TooShort
	edge.source_id = source_id
	pos += 8

	target_type_raw, target_type_ok := endian.get_u16(data[pos:], .Big)
	if !target_type_ok do return {}, offset, .TooShort
	edge.target_type = TargetType(target_type_raw)
	pos += 2

	target_id, target_id_ok := endian.get_u64(data[pos:], .Big)
	if !target_id_ok do return {}, offset, .TooShort
	edge.target_id = target_id
	pos += 8

	relation_raw, relation_ok := endian.get_u16(data[pos:], .Big)
	if !relation_ok do return {}, offset, .TooShort
	edge.relation = RelationType(relation_raw)
	pos += 2

	created_at_raw, created_at_ok := endian.get_u64(data[pos:], .Big)
	if !created_at_ok do return {}, offset, .TooShort
	edge.created_at = i64(created_at_raw)
	pos += 8

	created_by_len_raw, created_by_len_ok := endian.get_u16(data[pos:], .Big)
	if !created_by_len_ok do return {}, offset, .TooShort
	pos += 2
	created_by_len := int(created_by_len_raw)
	if pos + created_by_len > len(data) do return {}, offset, .TooShort
	edge.created_by = data[pos:pos + created_by_len]
	pos += created_by_len

	return edge, pos, nil
}

// ============================================================================
// C_GraphQuery (Client -> Server, opcode 44)
// ============================================================================

GraphQueryRequest :: struct {
	conv_id:        ConversationID,
	start_type:     TargetType,
	start_id:       u64,
	max_depth:      u8,
	relation_mask:  u16,
	direction:      Direction,
	flags:          u8,
	correlation_id: u32, // Client-generated, echoed in S_GraphQueryResult for request/response correlation
}

parseGraphQueryRequest :: proc(data: []byte) -> (GraphQueryRequest, ProtocolParseError) {
	result := GraphQueryRequest{}

	// conv_id(8) + start_type(2) + start_id(8) + max_depth(1) + relation_mask(2) + direction(1) + flags(1)
	if len(data) < 23 {
		log.debugf("GraphQueryRequest payload too short. Need 23, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	start_type, _ := endian.get_u16(data[offset:], .Big)
	result.start_type = TargetType(start_type)
	offset += 2

	start_id, _ := endian.get_u64(data[offset:], .Big)
	result.start_id = start_id
	offset += 8

	result.max_depth = data[offset]
	offset += 1

	relation_mask, _ := endian.get_u16(data[offset:], .Big)
	result.relation_mask = relation_mask
	offset += 2

	result.direction = Direction(data[offset])
	offset += 1

	result.flags = data[offset]
	offset += 1

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	if len(data) != offset + 4 {
		return result, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// C_GraphShortestPath (Client -> Server, opcode 45)
// ============================================================================

GraphShortestPathRequest :: struct {
	conv_id:        ConversationID,
	from_type:      TargetType,
	from_id:        u64,
	to_type:        TargetType,
	to_id:          u64,
	relation_mask:  u16,
	direction:      Direction,
	max_depth:      u8,
	flags:          u8,
	correlation_id: u32, // Client-generated, echoed in S_GraphShortestPathResult for request/response correlation
}

parseGraphShortestPathRequest :: proc(data: []byte) -> (GraphShortestPathRequest, ProtocolParseError) {
	result := GraphShortestPathRequest{}

	// conv_id(8) + from_type(2) + from_id(8) + to_type(2) + to_id(8) + relation_mask(2) + direction(1) + max_depth(1) + flags(1)
	if len(data) < 33 {
		log.debugf("GraphShortestPathRequest payload too short. Need 33, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	from_type, _ := endian.get_u16(data[offset:], .Big)
	result.from_type = TargetType(from_type)
	offset += 2

	from_id, _ := endian.get_u64(data[offset:], .Big)
	result.from_id = from_id
	offset += 8

	to_type, _ := endian.get_u16(data[offset:], .Big)
	result.to_type = TargetType(to_type)
	offset += 2

	to_id, _ := endian.get_u64(data[offset:], .Big)
	result.to_id = to_id
	offset += 8

	relation_mask, _ := endian.get_u16(data[offset:], .Big)
	result.relation_mask = relation_mask
	offset += 2

	result.direction = Direction(data[offset])
	offset += 1

	result.max_depth = data[offset]
	offset += 1

	result.flags = data[offset]
	offset += 1

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	if len(data) != offset + 4 {
		return result, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// C_GraphDegree (Client -> Server, opcode 46)
// ============================================================================

GraphDegreeRequest :: struct {
	conv_id:        ConversationID,
	top_n:          u16,
	type_filter:    u16,
	relation_mask:  u16,
	correlation_id: u32, // Client-generated, echoed in S_GraphDegreeResult for request/response correlation
}

parseGraphDegreeRequest :: proc(data: []byte) -> (GraphDegreeRequest, ProtocolParseError) {
	result := GraphDegreeRequest{}

	// conv_id(8) + top_n(2) + type_filter(2) + relation_mask(2)
	if len(data) < 14 {
		log.debugf("GraphDegreeRequest payload too short. Need 14, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	top_n, _ := endian.get_u16(data[offset:], .Big)
	result.top_n = top_n
	offset += 2

	type_filter, _ := endian.get_u16(data[offset:], .Big)
	result.type_filter = type_filter
	offset += 2

	relation_mask, _ := endian.get_u16(data[offset:], .Big)
	result.relation_mask = relation_mask

	offset += 2
	if len(data) < offset + 4 {
		return result, .TooShort
	}
	if len(data) != offset + 4 {
		return result, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// C_GraphCommonNeighbors (Client -> Server, opcode 47)
// ============================================================================

GraphCommonNeighborsRequest :: struct {
	conv_id:        ConversationID,
	a_type:         TargetType,
	a_id:           u64,
	b_type:         TargetType,
	b_id:           u64,
	relation_mask:  u16,
	direction:      Direction,
	correlation_id: u32, // Client-generated, echoed in S_GraphCommonNeighborsResult for request/response correlation
}

parseGraphCommonNeighborsRequest :: proc(data: []byte) -> (GraphCommonNeighborsRequest, ProtocolParseError) {
	result := GraphCommonNeighborsRequest{}

	// conv_id(8) + a_type(2) + a_id(8) + b_type(2) + b_id(8) + relation_mask(2) + direction(1)
	if len(data) < 31 {
		log.debugf("GraphCommonNeighborsRequest payload too short. Need 31, got %v", len(data))
		return result, .TooShort
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	a_type, _ := endian.get_u16(data[offset:], .Big)
	result.a_type = TargetType(a_type)
	offset += 2

	a_id, _ := endian.get_u64(data[offset:], .Big)
	result.a_id = a_id
	offset += 8

	b_type, _ := endian.get_u16(data[offset:], .Big)
	result.b_type = TargetType(b_type)
	offset += 2

	b_id, _ := endian.get_u64(data[offset:], .Big)
	result.b_id = b_id
	offset += 8

	relation_mask, _ := endian.get_u16(data[offset:], .Big)
	result.relation_mask = relation_mask
	offset += 2

	result.direction = Direction(data[offset])
	offset += 1

	if len(data) < offset + 4 {
		return result, .TooShort
	}
	if len(data) != offset + 4 {
		return result, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// S_GraphQueryResult (Server -> Client, opcode 154)
// ============================================================================

GraphQueryResultMessage :: struct {
	conv_id:        ConversationID,
	start_type:     TargetType,
	start_id:       u64,
	truncated:      bool,
	nodes:          []GraphQueryNode,
	edges:          []Edge,
	correlation_id: u32, // Echoed from client's GraphQuery request
}

getSizeGraphQueryResult :: proc(msg: GraphQueryResultMessage) -> int {
	// opcode(2) + conv_id(8) + start_type(2) + start_id(8) + truncated(1) + node_count(2) + nodes(11 each) + edge_count(2) + edges(var) + correlation_id(4)
	size := 2 + 8 + 2 + 8 + 1 + 2 + len(msg.nodes) * 11 + 2 + 4
	for edge in msg.edges {
		size += getSizeEdge(edge)
	}
	return size
}

serializeGraphQueryResult :: proc(msg: GraphQueryResultMessage, buf: []byte) -> int {
	if len(msg.nodes) > 65535 {
		log.errorf("Graph query node count %v exceeds maximum %v", len(msg.nodes), 65535)
		return -1
	}
	if len(msg.edges) > 65535 {
		log.errorf("Graph query edge count %v exceeds maximum %v", len(msg.edges), 65535)
		return -1
	}

	total_size := getSizeGraphQueryResult(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for GraphQueryResultMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_GraphQueryResult))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(msg.start_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, msg.start_id)
	offset += 8

	buf[offset] = msg.truncated ? 1 : 0
	offset += 1

	endian.put_u16(buf[offset:], .Big, u16(len(msg.nodes)))
	offset += 2

	for node in msg.nodes {
		endian.put_u16(buf[offset:], .Big, u16(node.target_type))
		offset += 2
		endian.put_u64(buf[offset:], .Big, node.target_id)
		offset += 8
		buf[offset] = node.depth
		offset += 1
	}

	endian.put_u16(buf[offset:], .Big, u16(len(msg.edges)))
	offset += 2

	for edge in msg.edges {
		edge_size := serializeEdge(edge, buf[offset:])
		if edge_size < 0 {
			return -1
		}
		offset += edge_size
	}

	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseGraphQueryResult :: proc(data: []byte, nodes: []GraphQueryNode, edges: []Edge) -> (result: GraphQueryResultMessage, err: ProtocolParseError) {
	if len(data) < 29 do return result, .TooShort
	if get_opcode(data) != .S_GraphQueryResult do return result, .InvalidOpcode

	conv_id_raw, conv_ok := endian.get_u64(data[2:], .Big)
	start_type_raw, start_type_ok := endian.get_u16(data[10:], .Big)
	start_id, start_id_ok := endian.get_u64(data[12:], .Big)
	node_count, node_count_ok := endian.get_u16(data[21:], .Big)
	if !conv_ok || !start_type_ok || !start_id_ok || !node_count_ok do return result, .TooShort
	if int(node_count) > len(nodes) do return result, .TooMany

	result.conv_id = ConversationID(conv_id_raw)
	result.start_type = TargetType(start_type_raw)
	result.start_id = start_id
	result.truncated = data[20] != 0
	result.nodes = nodes[:node_count]

	pos := 23
	for i := 0; i < int(node_count); i += 1 {
		if pos + 11 > len(data) do return result, .TooShort
		node_type_raw, node_type_ok := endian.get_u16(data[pos:], .Big)
		node_id, node_id_ok := endian.get_u64(data[pos + 2:], .Big)
		if !node_type_ok || !node_id_ok do return result, .TooShort
		nodes[i] = {
			target_type = TargetType(node_type_raw),
			target_id   = node_id,
			depth       = data[pos + 10],
		}
		pos += 11
	}

	if pos + 2 > len(data) do return result, .TooShort
	edge_count, edge_count_ok := endian.get_u16(data[pos:], .Big)
	if !edge_count_ok do return result, .TooShort
	pos += 2
	if int(edge_count) > len(edges) do return result, .TooMany
	result.edges = edges[:edge_count]

	for i := 0; i < int(edge_count); i += 1 {
		edge, next_pos, edge_err := parse_edge_from_payload(data, pos)
		if edge_err != nil do return result, edge_err
		edges[i] = edge
		pos = next_pos
	}
	if pos + 4 != len(data) do return result, .ContentLengthMismatch
	correlation_id, correlation_ok := endian.get_u32(data[pos:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id

	return result, nil
}

// ============================================================================
// S_GraphShortestPathResult (Server -> Client, opcode 155)
// ============================================================================

GraphShortestPathResultMessage :: struct {
	conv_id:        ConversationID,
	from_type:      TargetType,
	from_id:        u64,
	to_type:        TargetType,
	to_id:          u64,
	found:          bool,
	path_length:    u8,
	nodes:          []GraphPathNode,
	edges:          []Edge,
	correlation_id: u32, // Echoed from client's GraphShortestPath request
}

getSizeGraphShortestPathResult :: proc(msg: GraphShortestPathResultMessage) -> int {
	// opcode(2) + conv_id(8) + from_type(2) + from_id(8) + to_type(2) + to_id(8) + found(1) + path_length(1) + node_count(2) + nodes(10 each) + edge_count(2) + edges(var) + correlation_id(4)
	size := 2 + 8 + 2 + 8 + 2 + 8 + 1 + 1 + 2 + len(msg.nodes) * 10 + 2 + 4
	for edge in msg.edges {
		size += getSizeEdge(edge)
	}
	return size
}

serializeGraphShortestPathResult :: proc(msg: GraphShortestPathResultMessage, buf: []byte) -> int {
	if len(msg.nodes) > 65535 {
		log.errorf("Graph shortest-path node count %v exceeds maximum %v", len(msg.nodes), 65535)
		return -1
	}
	if len(msg.edges) > 65535 {
		log.errorf("Graph shortest-path edge count %v exceeds maximum %v", len(msg.edges), 65535)
		return -1
	}

	total_size := getSizeGraphShortestPathResult(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for GraphShortestPathResultMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_GraphShortestPathResult))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(msg.from_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, msg.from_id)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(msg.to_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, msg.to_id)
	offset += 8

	buf[offset] = msg.found ? 1 : 0
	offset += 1

	buf[offset] = msg.path_length
	offset += 1

	endian.put_u16(buf[offset:], .Big, u16(len(msg.nodes)))
	offset += 2

	for node in msg.nodes {
		endian.put_u16(buf[offset:], .Big, u16(node.target_type))
		offset += 2
		endian.put_u64(buf[offset:], .Big, node.target_id)
		offset += 8
	}

	endian.put_u16(buf[offset:], .Big, u16(len(msg.edges)))
	offset += 2

	for edge in msg.edges {
		edge_size := serializeEdge(edge, buf[offset:])
		if edge_size < 0 {
			return -1
		}
		offset += edge_size
	}

	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseGraphShortestPathResult :: proc(
	data: []byte,
	nodes: []GraphPathNode,
	edges: []Edge,
) -> (
	result: GraphShortestPathResultMessage,
	err: ProtocolParseError,
) {
	if len(data) < 40 do return result, .TooShort
	if get_opcode(data) != .S_GraphShortestPathResult do return result, .InvalidOpcode

	conv_id_raw, conv_ok := endian.get_u64(data[2:], .Big)
	from_type_raw, from_type_ok := endian.get_u16(data[10:], .Big)
	from_id, from_id_ok := endian.get_u64(data[12:], .Big)
	to_type_raw, to_type_ok := endian.get_u16(data[20:], .Big)
	to_id, to_id_ok := endian.get_u64(data[22:], .Big)
	node_count, node_count_ok := endian.get_u16(data[32:], .Big)
	if !conv_ok || !from_type_ok || !from_id_ok || !to_type_ok || !to_id_ok || !node_count_ok do return result, .TooShort
	if int(node_count) > len(nodes) do return result, .TooMany

	result.conv_id = ConversationID(conv_id_raw)
	result.from_type = TargetType(from_type_raw)
	result.from_id = from_id
	result.to_type = TargetType(to_type_raw)
	result.to_id = to_id
	result.found = data[30] != 0
	result.path_length = data[31]
	result.nodes = nodes[:node_count]

	pos := 34
	for i := 0; i < int(node_count); i += 1 {
		if pos + 10 > len(data) do return result, .TooShort
		node_type_raw, node_type_ok := endian.get_u16(data[pos:], .Big)
		node_id, node_id_ok := endian.get_u64(data[pos + 2:], .Big)
		if !node_type_ok || !node_id_ok do return result, .TooShort
		nodes[i] = {
			target_type = TargetType(node_type_raw),
			target_id   = node_id,
		}
		pos += 10
	}

	if pos + 2 > len(data) do return result, .TooShort
	edge_count, edge_count_ok := endian.get_u16(data[pos:], .Big)
	if !edge_count_ok do return result, .TooShort
	pos += 2
	if int(edge_count) > len(edges) do return result, .TooMany
	result.edges = edges[:edge_count]

	for i := 0; i < int(edge_count); i += 1 {
		edge, next_pos, edge_err := parse_edge_from_payload(data, pos)
		if edge_err != nil do return result, edge_err
		edges[i] = edge
		pos = next_pos
	}
	if pos + 4 != len(data) do return result, .ContentLengthMismatch
	correlation_id, correlation_ok := endian.get_u32(data[pos:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id

	return result, nil
}

// ============================================================================
// S_GraphDegreeResult (Server -> Client, opcode 156)
// ============================================================================

GraphDegreeResultMessage :: struct {
	conv_id:        ConversationID,
	entries:        []GraphDegreeEntry,
	correlation_id: u32, // Echoed from client's GraphDegree request
}

getSizeGraphDegreeResult :: proc(msg: GraphDegreeResultMessage) -> int {
	// opcode(2) + conv_id(8) + count(2) + entries(12 each) + correlation_id(4)
	return 2 + 8 + 2 + len(msg.entries) * 12 + 4
}

serializeGraphDegreeResult :: proc(msg: GraphDegreeResultMessage, buf: []byte) -> int {
	if len(msg.entries) > 65535 {
		log.errorf("Graph degree entry count %v exceeds maximum %v", len(msg.entries), 65535)
		return -1
	}

	total_size := getSizeGraphDegreeResult(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for GraphDegreeResultMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_GraphDegreeResult))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(len(msg.entries)))
	offset += 2

	for entry in msg.entries {
		endian.put_u16(buf[offset:], .Big, u16(entry.target_type))
		offset += 2
		endian.put_u64(buf[offset:], .Big, entry.target_id)
		offset += 8
		endian.put_u16(buf[offset:], .Big, entry.degree)
		offset += 2
	}

	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseGraphDegreeResult :: proc(data: []byte, entries: []GraphDegreeEntry) -> (result: GraphDegreeResultMessage, err: ProtocolParseError) {
	if len(data) < 16 do return result, .TooShort
	if get_opcode(data) != .S_GraphDegreeResult do return result, .InvalidOpcode

	conv_id_raw, conv_ok := endian.get_u64(data[2:], .Big)
	count, count_ok := endian.get_u16(data[10:], .Big)
	if !conv_ok || !count_ok do return result, .TooShort
	if int(count) > len(entries) do return result, .TooMany
	if 12 + int(count) * 12 + 4 != len(data) do return result, .ContentLengthMismatch

	result.conv_id = ConversationID(conv_id_raw)
	result.entries = entries[:count]

	pos := 12
	for i := 0; i < int(count); i += 1 {
		type_raw, type_ok := endian.get_u16(data[pos:], .Big)
		id, id_ok := endian.get_u64(data[pos + 2:], .Big)
		degree, degree_ok := endian.get_u16(data[pos + 10:], .Big)
		if !type_ok || !id_ok || !degree_ok do return result, .TooShort
		entries[i] = {
			target_type = TargetType(type_raw),
			target_id   = id,
			degree      = degree,
		}
		pos += 12
	}

	correlation_id, correlation_ok := endian.get_u32(data[pos:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id

	return result, nil
}

// ============================================================================
// S_GraphCommonNeighborsResult (Server -> Client, opcode 157)
// ============================================================================

GraphCommonNeighborsResultMessage :: struct {
	conv_id:        ConversationID,
	a_type:         TargetType,
	a_id:           u64,
	b_type:         TargetType,
	b_id:           u64,
	nodes:          []GraphPathNode,
	edges:          []Edge,
	correlation_id: u32, // Echoed from client's GraphCommonNeighbors request
}

getSizeGraphCommonNeighborsResult :: proc(msg: GraphCommonNeighborsResultMessage) -> int {
	// opcode(2) + conv_id(8) + a_type(2) + a_id(8) + b_type(2) + b_id(8) + node_count(2) + nodes(10 each) + edge_count(2) + edges(var) + correlation_id(4)
	size := 2 + 8 + 2 + 8 + 2 + 8 + 2 + len(msg.nodes) * 10 + 2 + 4
	for edge in msg.edges {
		size += getSizeEdge(edge)
	}
	return size
}

serializeGraphCommonNeighborsResult :: proc(msg: GraphCommonNeighborsResultMessage, buf: []byte) -> int {
	if len(msg.nodes) > 65535 {
		log.errorf("Graph common-neighbors node count %v exceeds maximum %v", len(msg.nodes), 65535)
		return -1
	}
	if len(msg.edges) > 65535 {
		log.errorf("Graph common-neighbors edge count %v exceeds maximum %v", len(msg.edges), 65535)
		return -1
	}

	total_size := getSizeGraphCommonNeighborsResult(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for GraphCommonNeighborsResultMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_GraphCommonNeighborsResult))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(msg.a_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, msg.a_id)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(msg.b_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, msg.b_id)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(len(msg.nodes)))
	offset += 2

	for node in msg.nodes {
		endian.put_u16(buf[offset:], .Big, u16(node.target_type))
		offset += 2
		endian.put_u64(buf[offset:], .Big, node.target_id)
		offset += 8
	}

	endian.put_u16(buf[offset:], .Big, u16(len(msg.edges)))
	offset += 2

	for edge in msg.edges {
		edge_size := serializeEdge(edge, buf[offset:])
		if edge_size < 0 {
			return -1
		}
		offset += edge_size
	}

	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseGraphCommonNeighborsResult :: proc(
	data: []byte,
	nodes: []GraphPathNode,
	edges: []Edge,
) -> (
	result: GraphCommonNeighborsResultMessage,
	err: ProtocolParseError,
) {
	if len(data) < 38 do return result, .TooShort
	if get_opcode(data) != .S_GraphCommonNeighborsResult do return result, .InvalidOpcode

	conv_id_raw, conv_ok := endian.get_u64(data[2:], .Big)
	a_type_raw, a_type_ok := endian.get_u16(data[10:], .Big)
	a_id, a_id_ok := endian.get_u64(data[12:], .Big)
	b_type_raw, b_type_ok := endian.get_u16(data[20:], .Big)
	b_id, b_id_ok := endian.get_u64(data[22:], .Big)
	node_count, node_count_ok := endian.get_u16(data[30:], .Big)
	if !conv_ok || !a_type_ok || !a_id_ok || !b_type_ok || !b_id_ok || !node_count_ok do return result, .TooShort
	if int(node_count) > len(nodes) do return result, .TooMany

	result.conv_id = ConversationID(conv_id_raw)
	result.a_type = TargetType(a_type_raw)
	result.a_id = a_id
	result.b_type = TargetType(b_type_raw)
	result.b_id = b_id
	result.nodes = nodes[:node_count]

	pos := 32
	for i := 0; i < int(node_count); i += 1 {
		if pos + 10 > len(data) do return result, .TooShort
		node_type_raw, node_type_ok := endian.get_u16(data[pos:], .Big)
		node_id, node_id_ok := endian.get_u64(data[pos + 2:], .Big)
		if !node_type_ok || !node_id_ok do return result, .TooShort
		nodes[i] = {
			target_type = TargetType(node_type_raw),
			target_id   = node_id,
		}
		pos += 10
	}

	if pos + 2 > len(data) do return result, .TooShort
	edge_count, edge_count_ok := endian.get_u16(data[pos:], .Big)
	if !edge_count_ok do return result, .TooShort
	pos += 2
	if int(edge_count) > len(edges) do return result, .TooMany
	result.edges = edges[:edge_count]

	for i := 0; i < int(edge_count); i += 1 {
		edge, next_pos, edge_err := parse_edge_from_payload(data, pos)
		if edge_err != nil do return result, edge_err
		edges[i] = edge
		pos = next_pos
	}
	if pos + 4 != len(data) do return result, .ContentLengthMismatch
	correlation_id, correlation_ok := endian.get_u32(data[pos:], .Big)
	if !correlation_ok do return result, .TooShort
	result.correlation_id = correlation_id

	return result, nil
}
