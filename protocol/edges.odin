package protocol

import "core:encoding/endian"
import "core:log"

// ============================================================================
// Edge Types
// ============================================================================
// Edges are non-ownership references between assets (or assets and tasks).
// Unlike parent_type/parent_id which imply containment with cascade delete,
// edges are symmetric links - deleting either endpoint deletes the edge only.

EdgeID :: u64

// RelationType defines the semantic meaning of an edge.
// Frontend maps these to display strings.
RelationType :: enum u16 {
	References  = 1, // Generic reference
	RelatedTo   = 2, // Bidirectional relation
	DependsOn   = 3, // Source depends on target
	Blocks      = 4, // Source blocks target
	DerivedFrom = 5, // Source is derived from target
	Supersedes  = 6, // Source supersedes/replaces target
	MemberOf    = 7, // Source belongs to the target container (work slice or customer company)
}

// TargetType specifies what kind of entity the edge endpoints reference.
// Both source and target can be different types.
TargetType :: enum u16 {
	Asset = 1,
	Task  = 2,
}

Edge :: struct {
	edge_id:     EdgeID,
	conv_id:     ConversationID,
	source_type: TargetType,
	source_id:   u64,
	target_type: TargetType,
	target_id:   u64,
	relation:    RelationType,
	created_at:  i64,
	created_by:  []byte,
}

// ============================================================================
// CreateEdge (C_CreateEdge = 40)
// ============================================================================

CreateEdgeRequest :: struct {
	conv_id:        ConversationID,
	source_type:    TargetType,
	source_id:      u64,
	target_type:    TargetType,
	target_id:      u64,
	relation:       RelationType,
	correlation_id: u32, // Client-generated, echoed in S_EdgeCreated for request/response correlation
}

parseCreateEdgeRequest :: proc(data: []byte) -> (CreateEdgeRequest, ProtocolParseError) {
	result := CreateEdgeRequest{}
	EXPECTED_SIZE :: 34

	// conv_id(8) + source_type(2) + source_id(8) + target_type(2) + target_id(8) + relation(2) + correlation_id(4)
	if len(data) < EXPECTED_SIZE {
		log.debugf("CreateEdgeRequest payload too short. Need %v, got %v", EXPECTED_SIZE, len(data))
		return result, .TooShort
	}
	if len(data) != EXPECTED_SIZE {
		return result, .ContentLengthMismatch
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	source_type, _ := endian.get_u16(data[offset:], .Big)
	result.source_type = TargetType(source_type)
	offset += 2

	source_id, _ := endian.get_u64(data[offset:], .Big)
	result.source_id = source_id
	offset += 8

	target_type, _ := endian.get_u16(data[offset:], .Big)
	result.target_type = TargetType(target_type)
	offset += 2

	target_id, _ := endian.get_u64(data[offset:], .Big)
	result.target_id = target_id
	offset += 8

	relation, _ := endian.get_u16(data[offset:], .Big)
	result.relation = RelationType(relation)

	offset += 2
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// DeleteEdge (C_DeleteEdge = 41)
// ============================================================================

DeleteEdgeRequest :: struct {
	conv_id:        ConversationID,
	edge_id:        EdgeID,
	correlation_id: u32, // Client-generated, echoed in S_EdgeDeleted for request/response correlation
}

parseDeleteEdgeRequest :: proc(data: []byte) -> (DeleteEdgeRequest, ProtocolParseError) {
	result := DeleteEdgeRequest{}

	// conv_id(8) + edge_id(8)
	if len(data) < 16 {
		log.debugf("DeleteEdgeRequest payload too short. Need 16, got %v", len(data))
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

	edge_id, _ := endian.get_u64(data[8:], .Big)
	result.edge_id = EdgeID(edge_id)

	result.correlation_id, _ = endian.get_u32(data[16:], .Big)

	return result, nil
}

// ============================================================================
// ListEdges (C_ListEdges = 42)
// ============================================================================

ListEdgesRequest :: struct {
	conv_id:        ConversationID,
	target_type:    TargetType,
	target_id:      u64,
	correlation_id: u32, // Client-generated, echoed in S_EdgeList for request/response correlation
}

parseListEdgesRequest :: proc(data: []byte) -> (ListEdgesRequest, ProtocolParseError) {
	result := ListEdgesRequest{}

	// conv_id(8) + target_type(2) + target_id(8)
	if len(data) < 18 {
		log.debugf("ListEdgesRequest payload too short. Need 18, got %v", len(data))
		return result, .TooShort
	}
	if len(data) != 22 {
		if len(data) < 22 {
			return result, .TooShort
		}
		return result, .ContentLengthMismatch
	}

	offset := 0

	conv_id, _ := endian.get_u64(data[offset:], .Big)
	result.conv_id = ConversationID(conv_id)
	offset += 8

	target_type, _ := endian.get_u16(data[offset:], .Big)
	result.target_type = TargetType(target_type)
	offset += 2

	target_id, _ := endian.get_u64(data[offset:], .Big)
	result.target_id = target_id

	offset += 8
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)

	return result, nil
}

// ============================================================================
// ListAllEdges (C_ListAllEdges = 43)
// ============================================================================

ListAllEdgesRequest :: struct {
	conv_id:        ConversationID,
	correlation_id: u32, // Client-generated, echoed in S_AllEdgeList for request/response correlation
}

parseListAllEdgesRequest :: proc(data: []byte) -> (ListAllEdgesRequest, ProtocolParseError) {
	result := ListAllEdgesRequest{}

	// conv_id(8)
	if len(data) < 8 {
		log.debugf("ListAllEdgesRequest payload too short. Need 8, got %v", len(data))
		return result, .TooShort
	}
	if len(data) != 12 {
		if len(data) < 12 {
			return result, .TooShort
		}
		return result, .ContentLengthMismatch
	}

	conv_id, _ := endian.get_u64(data[0:], .Big)
	result.conv_id = ConversationID(conv_id)

	result.correlation_id, _ = endian.get_u32(data[8:], .Big)

	return result, nil
}

// ============================================================================
// S_EdgeCreated (Server -> Client, opcode 150)
// ============================================================================

EdgeCreatedMessage :: struct {
	edge:           Edge,
	correlation_id: u32, // Echoed from client's CreateEdge request (0 for broadcasts)
}

getSizeEdgeCreatedMessage :: proc(msg: EdgeCreatedMessage) -> int {
	return 2 + getSizeEdge(msg.edge) + 4 // opcode + edge + correlation_id
}

serializeEdgeCreatedMessage :: proc(msg: EdgeCreatedMessage, buf: []byte) -> int {
	total_size := getSizeEdgeCreatedMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for EdgeCreatedMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_EdgeCreated))
	offset := 2
	edge_size := serializeEdge(msg.edge, buf[offset:])
	if edge_size < 0 {
		return -1
	}
	offset += edge_size
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)

	return total_size
}

parseEdgeCreatedMessage :: proc(data: []byte) -> (result: EdgeCreatedMessage, err: ProtocolParseError) {
	if len(data) < 6 do return result, .TooShort
	if get_opcode(data) != .S_EdgeCreated do return result, .InvalidOpcode

	edge, offset, edge_err := parse_edge_from_payload(data, 2)
	if edge_err != nil do return result, edge_err
	if offset + 4 > len(data) do return result, .TooShort
	if offset + 4 != len(data) do return result, .ContentLengthMismatch

	result.edge = edge
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

// ============================================================================
// S_EdgeDeleted (Server -> Client, opcode 151)
// ============================================================================

EdgeDeletedMessage :: struct {
	conv_id:        ConversationID,
	edge_id:        EdgeID,
	correlation_id: u32, // Echoed from client's DeleteEdge request (0 for broadcasts)
}

getSizeEdgeDeletedMessage :: proc(msg: EdgeDeletedMessage) -> int {
	return 2 + 8 + 8 + 4 // opcode + conv_id + edge_id + correlation_id
}

serializeEdgeDeletedMessage :: proc(msg: EdgeDeletedMessage, buf: []byte) -> int {
	total_size := getSizeEdgeDeletedMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for EdgeDeletedMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_EdgeDeleted))
	endian.put_u64(buf[2:10], .Big, u64(msg.conv_id))
	endian.put_u64(buf[10:18], .Big, u64(msg.edge_id))
	endian.put_u32(buf[18:22], .Big, msg.correlation_id)

	return total_size
}

parseEdgeDeletedMessage :: proc(data: []byte) -> (result: EdgeDeletedMessage, err: ProtocolParseError) {
	if len(data) < getSizeEdgeDeletedMessage(result) do return result, .TooShort
	if get_opcode(data) != .S_EdgeDeleted do return result, .InvalidOpcode
	if len(data) != getSizeEdgeDeletedMessage(result) do return result, .ContentLengthMismatch

	conv_id, _ := endian.get_u64(data[2:], .Big)
	edge_id, _ := endian.get_u64(data[10:], .Big)
	result.conv_id = ConversationID(conv_id)
	result.edge_id = EdgeID(edge_id)
	result.correlation_id, _ = endian.get_u32(data[18:], .Big)
	return result, nil
}

// ============================================================================
// S_EdgeList (Server -> Client, opcode 152)
// ============================================================================

EdgeListMessage :: struct {
	conv_id:        ConversationID,
	target_type:    TargetType,
	target_id:      u64,
	edges:          []Edge,
	correlation_id: u32, // Echoed from client's ListEdges request (0 when not request-scoped)
}

getSizeEdgeListMessage :: proc(msg: EdgeListMessage) -> int {
	// opcode(2) + conv_id(8) + target_type(2) + target_id(8) + count(2) + edges + correlation_id(4)
	size := 2 + 8 + 2 + 8 + 2 + 4
	for edge in msg.edges {
		size += getSizeEdge(edge)
	}
	return size
}

serializeEdgeListMessage :: proc(msg: EdgeListMessage, buf: []byte) -> int {
	if len(msg.edges) > 65535 {
		log.errorf("Edge count %v exceeds maximum %v", len(msg.edges), 65535)
		return -1
	}

	total_size := getSizeEdgeListMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for EdgeListMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_EdgeList))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(msg.target_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, msg.target_id)
	offset += 8

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

parseEdgeListMessage :: proc(data: []byte, edges: []Edge) -> (result: EdgeListMessage, err: ProtocolParseError) {
	if len(data) < 26 do return result, .TooShort
	if get_opcode(data) != .S_EdgeList do return result, .InvalidOpcode

	conv_id_raw, conv_ok := endian.get_u64(data[2:], .Big)
	target_type_raw, target_type_ok := endian.get_u16(data[10:], .Big)
	target_id, target_id_ok := endian.get_u64(data[12:], .Big)
	count_raw, count_ok := endian.get_u16(data[20:], .Big)
	if !conv_ok || !target_type_ok || !target_id_ok || !count_ok do return result, .TooShort
	if int(count_raw) > len(edges) do return result, .TooMany

	result.conv_id = ConversationID(conv_id_raw)
	result.target_type = TargetType(target_type_raw)
	result.target_id = target_id
	result.edges = edges[:count_raw]

	pos := 22
	for i := 0; i < int(count_raw); i += 1 {
		edge, next_pos, edge_err := parse_edge_from_payload(data, pos)
		if edge_err == .TooShort do return result, .ContentLengthMismatch
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
// S_AllEdgeList (Server -> Client, opcode 153)
// ============================================================================

AllEdgeListMessage :: struct {
	conv_id:        ConversationID,
	edges:          []Edge,
	correlation_id: u32, // Echoed from client's ListAllEdges request (0 when not request-scoped)
}

getSizeAllEdgeListMessage :: proc(msg: AllEdgeListMessage) -> int {
	// opcode(2) + conv_id(8) + count(4) + edges + correlation_id(4)
	size := 2 + 8 + 4 + 4
	for edge in msg.edges {
		size += getSizeEdge(edge)
	}
	return size
}

serializeAllEdgeListMessage :: proc(msg: AllEdgeListMessage, buf: []byte) -> int {
	total_size := getSizeAllEdgeListMessage(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for AllEdgeListMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	offset := 0

	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_AllEdgeList))
	offset += 2

	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u32(buf[offset:], .Big, u32(len(msg.edges)))
	offset += 4

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

parseAllEdgeListMessage :: proc(data: []byte, edges: []Edge) -> (result: AllEdgeListMessage, err: ProtocolParseError) {
	if len(data) < 18 do return result, .TooShort
	if get_opcode(data) != .S_AllEdgeList do return result, .InvalidOpcode

	conv_id_raw, conv_ok := endian.get_u64(data[2:], .Big)
	count_raw, count_ok := endian.get_u32(data[10:], .Big)
	if !conv_ok || !count_ok do return result, .TooShort
	if u32(len(edges)) < count_raw do return result, .TooMany

	result.conv_id = ConversationID(conv_id_raw)
	result.edges = edges[:count_raw]

	pos := 14
	for i := 0; i < int(count_raw); i += 1 {
		edge, next_pos, edge_err := parse_edge_from_payload(data, pos)
		if edge_err == .TooShort do return result, .ContentLengthMismatch
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
// Edge Serialization Helpers
// ============================================================================

getSizeEdge :: proc(edge: Edge) -> int {
	// edge_id(8) + conv_id(8) + source_type(2) + source_id(8) + target_type(2) + target_id(8) + relation(2) + created_at(8) + created_by_len(2) + created_by
	return 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + len(edge.created_by)
}

serializeEdge :: proc(edge: Edge, buf: []byte) -> int {
	if len(edge.created_by) > 65535 {
		log.errorf("Edge created_by length %v exceeds maximum %v", len(edge.created_by), 65535)
		return -1
	}

	offset := 0

	endian.put_u64(buf[offset:], .Big, u64(edge.edge_id))
	offset += 8

	endian.put_u64(buf[offset:], .Big, u64(edge.conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(edge.source_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, edge.source_id)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(edge.target_type))
	offset += 2

	endian.put_u64(buf[offset:], .Big, edge.target_id)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(edge.relation))
	offset += 2

	endian.put_u64(buf[offset:], .Big, cast(u64)edge.created_at)
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(len(edge.created_by)))
	offset += 2
	if len(edge.created_by) > 0 {
		copy(buf[offset:], edge.created_by)
		offset += len(edge.created_by)
	}

	return offset
}
