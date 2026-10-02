package protocol

// Focused tests for graph-query protocol helpers and response encoders/decoders.
// These conventional cases pin relation-mask semantics, fixed wire layout, and
// parser error handling that the generated response-parser properties then stress
// across many valid and malformed payload shapes.

import "core:encoding/endian"
import "core:testing"

// ============================================================================
// Shared Helper Tests
// ============================================================================

@(test)
test_relation_matches_mask_zero_matches_all :: proc(t: ^testing.T) {
	for r in RelationType.References ..= RelationType.MemberOf {
		testing.expect(t, relation_matches_mask(r, 0), "mask=0 should match all relations")
	}
}

@(test)
test_relation_matches_mask_specific_bits :: proc(t: ^testing.T) {
	testing.expect(t, relation_matches_mask(.References, 0b000001), "bit 0 should match References")
	testing.expect(t, !relation_matches_mask(.RelatedTo, 0b000001), "bit 0 should not match RelatedTo")
	testing.expect(t, relation_matches_mask(.RelatedTo, 0b000010), "bit 1 should match RelatedTo")
	testing.expect(t, relation_matches_mask(.DependsOn, 0b000100), "bit 2 should match DependsOn")
	testing.expect(t, relation_matches_mask(.Blocks, 0b001000), "bit 3 should match Blocks")
	testing.expect(t, relation_matches_mask(.DerivedFrom, 0b010000), "bit 4 should match DerivedFrom")
	testing.expect(t, relation_matches_mask(.Supersedes, 0b100000), "bit 5 should match Supersedes")
	testing.expect(t, relation_matches_mask(.MemberOf, 0b1000000), "bit 6 should match MemberOf")
}

@(test)
test_relation_matches_mask_combined :: proc(t: ^testing.T) {
	mask: u16 = 0b001100 // DependsOn + Blocks
	testing.expect(t, !relation_matches_mask(.References, mask), "References should not match")
	testing.expect(t, !relation_matches_mask(.RelatedTo, mask), "RelatedTo should not match")
	testing.expect(t, relation_matches_mask(.DependsOn, mask), "DependsOn should match")
	testing.expect(t, relation_matches_mask(.Blocks, mask), "Blocks should match")
	testing.expect(t, !relation_matches_mask(.DerivedFrom, mask), "DerivedFrom should not match")
}

@(test)
test_relation_matches_mask_invalid_relation :: proc(t: ^testing.T) {
	testing.expect(t, !relation_matches_mask(RelationType(0), 0b1111111), "relation 0 should not match")
	testing.expect(t, !relation_matches_mask(RelationType(8), 0b1111111), "relation 8 should not match")
	testing.expect(t, !relation_matches_mask(RelationType(255), 0b1111111), "relation 255 should not match")
}

@(test)
test_relation_matches_mask_invalid_relation_mask_zero :: proc(t: ^testing.T) {
	testing.expect(t, relation_matches_mask(RelationType(0), 0), "mask=0 returns true even for invalid relation")
}

@(test)
test_resolve_neighbor_outgoing :: proc(t: ^testing.T) {
	edge := Edge {
		source_type = .Task,
		source_id   = 1,
		target_type = .Asset,
		target_id   = 2,
	}

	// Node is source, direction=Both -> return target
	neighbor, ok := resolve_neighbor(&edge, .Task, 1, .Both)
	testing.expect(t, ok, "should resolve")
	testing.expect_value(t, neighbor.target_type, TargetType.Asset)
	testing.expect_value(t, neighbor.target_id, 2)

	// Node is source, direction=Outgoing -> return target
	neighbor2, ok2 := resolve_neighbor(&edge, .Task, 1, .Outgoing)
	testing.expect(t, ok2, "should resolve outgoing from source")
	testing.expect_value(t, neighbor2.target_type, TargetType.Asset)

	// Node is source, direction=Incoming -> skip (would be outgoing edge)
	_, ok3 := resolve_neighbor(&edge, .Task, 1, .Incoming)
	testing.expect(t, !ok3, "should not resolve incoming from source")
}

@(test)
test_resolve_neighbor_incoming :: proc(t: ^testing.T) {
	edge := Edge {
		source_type = .Task,
		source_id   = 1,
		target_type = .Asset,
		target_id   = 2,
	}

	// Node is target, direction=Both -> return source
	neighbor, ok := resolve_neighbor(&edge, .Asset, 2, .Both)
	testing.expect(t, ok, "should resolve")
	testing.expect_value(t, neighbor.target_type, TargetType.Task)
	testing.expect_value(t, neighbor.target_id, 1)

	// Node is target, direction=Incoming -> return source
	neighbor2, ok2 := resolve_neighbor(&edge, .Asset, 2, .Incoming)
	testing.expect(t, ok2, "should resolve incoming from target")
	testing.expect_value(t, neighbor2.target_type, TargetType.Task)

	// Node is target, direction=Outgoing -> skip
	_, ok3 := resolve_neighbor(&edge, .Asset, 2, .Outgoing)
	testing.expect(t, !ok3, "should not resolve outgoing from target")
}

@(test)
test_resolve_neighbor_not_endpoint :: proc(t: ^testing.T) {
	edge := Edge {
		source_type = .Task,
		source_id   = 1,
		target_type = .Asset,
		target_id   = 2,
	}

	_, ok := resolve_neighbor(&edge, .Task, 99, .Both)
	testing.expect(t, !ok, "should not resolve for non-endpoint node")
}

// ============================================================================
// Parser Roundtrip Tests
// ============================================================================

@(test)
test_roundtrip_graph_query_request :: proc(t: ^testing.T) {
	buf: [32]byte
	offset := 0

	conv_id: ConversationID = 12345
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	start_type: TargetType = .Task
	endian.put_u16(buf[offset:], .Big, u16(start_type))
	offset += 2

	start_id: u64 = 42
	endian.put_u64(buf[offset:], .Big, start_id)
	offset += 8

	max_depth: u8 = 3
	buf[offset] = max_depth
	offset += 1

	relation_mask: u16 = 0b001100
	endian.put_u16(buf[offset:], .Big, relation_mask)
	offset += 2

	direction: Direction = .Incoming
	buf[offset] = u8(direction)
	offset += 1

	flags: u8 = 1
	buf[offset] = flags
	offset += 1

	correlation_id: u32 = 0x01020304
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseGraphQueryRequest(buf[:offset])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.start_type, start_type)
	testing.expect_value(t, parsed.start_id, start_id)
	testing.expect_value(t, parsed.max_depth, max_depth)
	testing.expect_value(t, parsed.relation_mask, relation_mask)
	testing.expect_value(t, parsed.direction, direction)
	testing.expect_value(t, parsed.flags, flags)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_graph_query_too_short :: proc(t: ^testing.T) {
	buf: [10]byte
	_, err := parseGraphQueryRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_roundtrip_shortest_path_request :: proc(t: ^testing.T) {
	buf: [40]byte
	offset := 0

	conv_id: ConversationID = 99999
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	from_type: TargetType = .Task
	endian.put_u16(buf[offset:], .Big, u16(from_type))
	offset += 2

	from_id: u64 = 10
	endian.put_u64(buf[offset:], .Big, from_id)
	offset += 8

	to_type: TargetType = .Asset
	endian.put_u16(buf[offset:], .Big, u16(to_type))
	offset += 2

	to_id: u64 = 20
	endian.put_u64(buf[offset:], .Big, to_id)
	offset += 8

	relation_mask: u16 = 0
	endian.put_u16(buf[offset:], .Big, relation_mask)
	offset += 2

	direction: Direction = .Both
	buf[offset] = u8(direction)
	offset += 1

	max_depth: u8 = 4
	buf[offset] = max_depth
	offset += 1

	flags: u8 = 0
	buf[offset] = flags
	offset += 1

	correlation_id: u32 = 0x0A0B0C0D
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseGraphShortestPathRequest(buf[:offset])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.from_type, from_type)
	testing.expect_value(t, parsed.from_id, from_id)
	testing.expect_value(t, parsed.to_type, to_type)
	testing.expect_value(t, parsed.to_id, to_id)
	testing.expect_value(t, parsed.relation_mask, relation_mask)
	testing.expect_value(t, parsed.direction, direction)
	testing.expect_value(t, parsed.max_depth, max_depth)
	testing.expect_value(t, parsed.flags, flags)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_shortest_path_too_short :: proc(t: ^testing.T) {
	buf: [20]byte
	_, err := parseGraphShortestPathRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_roundtrip_degree_request :: proc(t: ^testing.T) {
	buf: [24]byte
	offset := 0

	conv_id: ConversationID = 777
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	top_n: u16 = 10
	endian.put_u16(buf[offset:], .Big, top_n)
	offset += 2

	type_filter: u16 = 2 // tasks only
	endian.put_u16(buf[offset:], .Big, type_filter)
	offset += 2

	relation_mask: u16 = 0b001000 // Blocks only
	endian.put_u16(buf[offset:], .Big, relation_mask)
	offset += 2

	correlation_id: u32 = 0x11223344
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseGraphDegreeRequest(buf[:offset])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.top_n, top_n)
	testing.expect_value(t, parsed.type_filter, type_filter)
	testing.expect_value(t, parsed.relation_mask, relation_mask)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_degree_too_short :: proc(t: ^testing.T) {
	buf: [8]byte
	_, err := parseGraphDegreeRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_roundtrip_common_neighbors_request :: proc(t: ^testing.T) {
	buf: [40]byte
	offset := 0

	conv_id: ConversationID = 555
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	a_type: TargetType = .Task
	endian.put_u16(buf[offset:], .Big, u16(a_type))
	offset += 2

	a_id: u64 = 1
	endian.put_u64(buf[offset:], .Big, a_id)
	offset += 8

	b_type: TargetType = .Asset
	endian.put_u16(buf[offset:], .Big, u16(b_type))
	offset += 2

	b_id: u64 = 3
	endian.put_u64(buf[offset:], .Big, b_id)
	offset += 8

	relation_mask: u16 = 0b000100 // DependsOn
	endian.put_u16(buf[offset:], .Big, relation_mask)
	offset += 2

	direction: Direction = .Outgoing
	buf[offset] = u8(direction)
	offset += 1

	correlation_id: u32 = 0x55667788
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseGraphCommonNeighborsRequest(buf[:offset])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.a_type, a_type)
	testing.expect_value(t, parsed.a_id, a_id)
	testing.expect_value(t, parsed.b_type, b_type)
	testing.expect_value(t, parsed.b_id, b_id)
	testing.expect_value(t, parsed.relation_mask, relation_mask)
	testing.expect_value(t, parsed.direction, direction)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_common_neighbors_too_short :: proc(t: ^testing.T) {
	buf: [20]byte
	_, err := parseGraphCommonNeighborsRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

// ============================================================================
// Serialization Tests
// ============================================================================

@(test)
test_serialize_graph_query_result_empty :: proc(t: ^testing.T) {
	msg := GraphQueryResultMessage {
		conv_id    = 12345,
		start_type = .Task,
		start_id   = 42,
		truncated  = false,
		nodes      = nil,
		edges      = nil,
	}

	buf: [64]byte
	written := serializeGraphQueryResult(msg, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeGraphQueryResult(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_GraphQueryResult)

	// Verify header fields
	conv_id, _ := endian.get_u64(buf[2:], .Big)
	testing.expect_value(t, ConversationID(conv_id), ConversationID(12345))

	start_type, _ := endian.get_u16(buf[10:], .Big)
	testing.expect_value(t, TargetType(start_type), TargetType.Task)

	start_id, _ := endian.get_u64(buf[12:], .Big)
	testing.expect_value(t, start_id, 42)

	testing.expect_value(t, buf[20], 0) // truncated = false

	node_count, _ := endian.get_u16(buf[21:], .Big)
	testing.expect_value(t, node_count, 0)

	edge_count, _ := endian.get_u16(buf[23:], .Big)
	testing.expect_value(t, edge_count, 0)
}

@(test)
test_serialize_graph_query_result_with_nodes :: proc(t: ^testing.T) {
	nodes := []GraphQueryNode {
		{target_type = .Task, target_id = 1, depth = 0},
		{target_type = .Asset, target_id = 2, depth = 1},
		{target_type = .Task, target_id = 3, depth = 2},
	}

	msg := GraphQueryResultMessage {
		conv_id    = 100,
		start_type = .Task,
		start_id   = 1,
		truncated  = true,
		nodes      = nodes,
		edges      = nil,
	}

	buf: [128]byte
	written := serializeGraphQueryResult(msg, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeGraphQueryResult(msg))

	testing.expect_value(t, buf[20], 1) // truncated = true

	node_count, _ := endian.get_u16(buf[21:], .Big)
	testing.expect_value(t, node_count, 3)

	// Verify first node: type(2) + id(8) + depth(1)
	node0_type, _ := endian.get_u16(buf[23:], .Big)
	testing.expect_value(t, TargetType(node0_type), TargetType.Task)
	node0_id, _ := endian.get_u64(buf[25:], .Big)
	testing.expect_value(t, node0_id, 1)
	testing.expect_value(t, buf[33], 0) // depth=0

	// Second node at offset 34
	node1_type, _ := endian.get_u16(buf[34:], .Big)
	testing.expect_value(t, TargetType(node1_type), TargetType.Asset)
	node1_id, _ := endian.get_u64(buf[36:], .Big)
	testing.expect_value(t, node1_id, 2)
	testing.expect_value(t, buf[44], 1) // depth=1
}

@(test)
test_serialize_shortest_path_not_found :: proc(t: ^testing.T) {
	msg := GraphShortestPathResultMessage {
		conv_id     = 100,
		from_type   = .Task,
		from_id     = 1,
		to_type     = .Asset,
		to_id       = 2,
		found       = false,
		path_length = 0,
		nodes       = nil,
		edges       = nil,
	}

	buf: [64]byte
	written := serializeGraphShortestPathResult(msg, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeGraphShortestPathResult(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_GraphShortestPathResult)

	// found flag at offset 2+8+2+8+2+8 = 30
	testing.expect_value(t, buf[30], 0) // not found
}

@(test)
test_serialize_shortest_path_found :: proc(t: ^testing.T) {
	nodes := []GraphPathNode{{target_type = .Task, target_id = 1}, {target_type = .Asset, target_id = 5}, {target_type = .Task, target_id = 2}}

	msg := GraphShortestPathResultMessage {
		conv_id     = 100,
		from_type   = .Task,
		from_id     = 1,
		to_type     = .Task,
		to_id       = 2,
		found       = true,
		path_length = 2,
		nodes       = nodes,
		edges       = nil,
	}

	buf: [128]byte
	written := serializeGraphShortestPathResult(msg, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeGraphShortestPathResult(msg))

	testing.expect_value(t, buf[30], 1) // found
	testing.expect_value(t, buf[31], 2) // path_length

	node_count, _ := endian.get_u16(buf[32:], .Big)
	testing.expect_value(t, node_count, 3)
}

@(test)
test_serialize_degree_result :: proc(t: ^testing.T) {
	entries := []GraphDegreeEntry{{target_type = .Task, target_id = 5, degree = 15}, {target_type = .Asset, target_id = 3, degree = 10}}

	msg := GraphDegreeResultMessage {
		conv_id = 100,
		entries = entries,
	}

	buf: [64]byte
	written := serializeGraphDegreeResult(msg, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeGraphDegreeResult(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_GraphDegreeResult)

	count, _ := endian.get_u16(buf[10:], .Big)
	testing.expect_value(t, count, 2)

	// First entry at offset 12: type(2)+id(8)+degree(2)
	entry0_type, _ := endian.get_u16(buf[12:], .Big)
	testing.expect_value(t, TargetType(entry0_type), TargetType.Task)
	entry0_id, _ := endian.get_u64(buf[14:], .Big)
	testing.expect_value(t, entry0_id, 5)
	entry0_degree, _ := endian.get_u16(buf[22:], .Big)
	testing.expect_value(t, entry0_degree, 15)
}

@(test)
test_serialize_common_neighbors_result_empty :: proc(t: ^testing.T) {
	msg := GraphCommonNeighborsResultMessage {
		conv_id = 100,
		a_type  = .Task,
		a_id    = 1,
		b_type  = .Task,
		b_id    = 2,
		nodes   = nil,
		edges   = nil,
	}

	buf: [64]byte
	written := serializeGraphCommonNeighborsResult(msg, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeGraphCommonNeighborsResult(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_GraphCommonNeighborsResult)
}

// ============================================================================
// Opcode Validation Tests
// ============================================================================

@(test)
test_get_opcode_graph_query_opcodes :: proc(t: ^testing.T) {
	buf: [2]byte

	endian.put_u16(buf[:], .Big, 44)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_GraphQuery)

	endian.put_u16(buf[:], .Big, 45)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_GraphShortestPath)

	endian.put_u16(buf[:], .Big, 46)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_GraphDegree)

	endian.put_u16(buf[:], .Big, 47)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_GraphCommonNeighbors)

	endian.put_u16(buf[:], .Big, 52)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_GraphRank)

	endian.put_u16(buf[:], .Big, 154)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_GraphQueryResult)

	endian.put_u16(buf[:], .Big, 155)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_GraphShortestPathResult)

	endian.put_u16(buf[:], .Big, 156)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_GraphDegreeResult)

	endian.put_u16(buf[:], .Big, 157)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_GraphCommonNeighborsResult)

	endian.put_u16(buf[:], .Big, 160)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_GraphRankResult)
}

@(test)
test_get_opcode_rejects_out_of_range :: proc(t: ^testing.T) {
	buf: [2]byte

	// The highest allocated client and server opcodes are the boundary; one
	// above each must still be rejected.
	endian.put_u16(buf[:], .Big, 59)
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))

	endian.put_u16(buf[:], .Big, 167)
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))
}

// ============================================================================
// Size Calculation Tests
// ============================================================================

@(test)
test_graph_query_result_size :: proc(t: ^testing.T) {
	msg := GraphQueryResultMessage {
		conv_id    = 0,
		start_type = .Task,
		start_id   = 0,
		truncated  = false,
		nodes      = nil,
		edges      = nil,
	}
	// opcode(2) + conv_id(8) + start_type(2) + start_id(8) + truncated(1) + node_count(2) + edge_count(2) + correlation_id(4) = 29
	testing.expect_value(t, getSizeGraphQueryResult(msg), 29)
}

@(test)
test_shortest_path_result_size :: proc(t: ^testing.T) {
	msg := GraphShortestPathResultMessage {
		conv_id     = 0,
		from_type   = .Task,
		from_id     = 0,
		to_type     = .Task,
		to_id       = 0,
		found       = false,
		path_length = 0,
		nodes       = nil,
		edges       = nil,
	}
	// opcode(2) + conv_id(8) + from_type(2) + from_id(8) + to_type(2) + to_id(8) + found(1) + path_length(1) + node_count(2) + edge_count(2) + correlation_id(4) = 40
	testing.expect_value(t, getSizeGraphShortestPathResult(msg), 40)
}

@(test)
test_degree_result_size :: proc(t: ^testing.T) {
	msg := GraphDegreeResultMessage {
		conv_id = 0,
		entries = nil,
	}
	// opcode(2) + conv_id(8) + count(2) + correlation_id(4) = 16
	testing.expect_value(t, getSizeGraphDegreeResult(msg), 16)
}

@(test)
test_common_neighbors_result_size :: proc(t: ^testing.T) {
	msg := GraphCommonNeighborsResultMessage {
		conv_id = 0,
		a_type  = .Task,
		a_id    = 0,
		b_type  = .Task,
		b_id    = 0,
		nodes   = nil,
		edges   = nil,
	}
	// opcode(2) + conv_id(8) + a_type(2) + a_id(8) + b_type(2) + b_id(8) + node_count(2) + edge_count(2) + correlation_id(4) = 38
	testing.expect_value(t, getSizeGraphCommonNeighborsResult(msg), 38)
}
