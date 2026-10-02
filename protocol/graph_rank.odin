package protocol

import "core:encoding/endian"
import "core:log"

MAX_GRAPH_RANK_ANCHORS :: 5
MAX_GRAPH_RANK_CANDIDATES :: 50
MAX_GRAPH_RANK_DEPTH :: 4

graph_rank_entity_valid :: proc(entity: GraphEntityKey) -> bool {
	return (entity.target_type == .Asset || entity.target_type == .Task) && entity.target_id != 0
}

GraphRankRequest :: struct {
	conv_id:         ConversationID,
	anchors:         [MAX_GRAPH_RANK_ANCHORS]GraphEntityKey,
	anchor_count:    u8,
	candidates:      [MAX_GRAPH_RANK_CANDIDATES]GraphEntityKey,
	candidate_count: u8,
	max_depth:       u8,
	relation_mask:   u16,
	direction:       Direction,
	top_n:           u8,
	correlation_id:  u32,
}

GraphRankPath :: struct {
	anchor_index: u8,
	depth:        u8,
	edge_ids:     []EdgeID,
}

GraphRankEntry :: struct {
	target_type: TargetType,
	target_id:   u64,
	score:       f64,
	paths:       []GraphRankPath,
}

GraphRankEdge :: struct {
	edge_id:     EdgeID,
	source_type: TargetType,
	source_id:   u64,
	target_type: TargetType,
	target_id:   u64,
	relation:    RelationType,
}

GraphRankResultMessage :: struct {
	conv_id:        ConversationID,
	truncated:      bool,
	entries:        []GraphRankEntry,
	edges:          []GraphRankEdge,
	correlation_id: u32,
}

parseGraphRankRequest :: proc(data: []byte) -> (result: GraphRankRequest, err: ProtocolParseError) {
	// conv_id + anchor_count + candidate_count + depth + relation + direction + top_n + correlation
	if len(data) < 19 do return result, .TooShort
	offset := 0
	conv_id, ok := endian.get_u64(data[offset:], .Big)
	if !ok do return result, .TooShort
	result.conv_id = ConversationID(conv_id)
	offset += 8

	result.anchor_count = data[offset]
	offset += 1
	if result.anchor_count == 0 || int(result.anchor_count) > MAX_GRAPH_RANK_ANCHORS do return result, .TooMany
	for i := 0; i < int(result.anchor_count); i += 1 {
		if offset + 10 > len(data) do return result, .TooShort
		type_raw, type_ok := endian.get_u16(data[offset:], .Big)
		id, id_ok := endian.get_u64(data[offset + 2:], .Big)
		if !type_ok || !id_ok do return result, .TooShort
		result.anchors[i] = {
			target_type = TargetType(type_raw),
			target_id   = id,
		}
		if !graph_rank_entity_valid(result.anchors[i]) do return result, .InvalidValue
		offset += 10
	}

	if offset >= len(data) do return result, .TooShort
	result.candidate_count = data[offset]
	offset += 1
	if int(result.candidate_count) > MAX_GRAPH_RANK_CANDIDATES do return result, .TooMany
	for i := 0; i < int(result.candidate_count); i += 1 {
		if offset + 10 > len(data) do return result, .TooShort
		type_raw, type_ok := endian.get_u16(data[offset:], .Big)
		id, id_ok := endian.get_u64(data[offset + 2:], .Big)
		if !type_ok || !id_ok do return result, .TooShort
		result.candidates[i] = {
			target_type = TargetType(type_raw),
			target_id   = id,
		}
		if !graph_rank_entity_valid(result.candidates[i]) do return result, .InvalidValue
		offset += 10
	}

	if offset + 9 != len(data) do return result, .ContentLengthMismatch
	result.max_depth = data[offset]
	offset += 1
	result.relation_mask, _ = endian.get_u16(data[offset:], .Big)
	offset += 2
	result.direction = Direction(data[offset])
	offset += 1
	result.top_n = data[offset]
	offset += 1
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

getSizeGraphRankResult :: proc(msg: GraphRankResultMessage) -> int {
	size := 2 + 8 + 1 + 2 + 2 + 4
	for entry in msg.entries {
		size += 2 + 8 + 8 + 1
		for path in entry.paths {
			size += 3 + len(path.edge_ids) * 8
		}
	}
	size += len(msg.edges) * 30
	return size
}

serializeGraphRankResult :: proc(msg: GraphRankResultMessage, buf: []byte) -> int {
	if len(msg.entries) > 65535 || len(msg.edges) > 65535 do return -1
	for entry in msg.entries {
		if len(entry.paths) > 255 do return -1
		for path in entry.paths {
			if len(path.edge_ids) > MAX_GRAPH_RANK_DEPTH do return -1
		}
	}
	total_size := getSizeGraphRankResult(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for GraphRankResultMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}
	offset := 0
	endian.put_u16(buf[offset:], .Big, u16(Opcode.S_GraphRankResult)); offset += 2
	endian.put_u64(buf[offset:], .Big, u64(msg.conv_id)); offset += 8
	buf[offset] = msg.truncated ? 1 : 0; offset += 1
	endian.put_u16(buf[offset:], .Big, u16(len(msg.entries))); offset += 2
	for entry in msg.entries {
		endian.put_u16(buf[offset:], .Big, u16(entry.target_type)); offset += 2
		endian.put_u64(buf[offset:], .Big, entry.target_id); offset += 8
		endian.put_u64(buf[offset:], .Big, transmute(u64)entry.score); offset += 8
		buf[offset] = u8(len(entry.paths)); offset += 1
		for path in entry.paths {
			buf[offset] = path.anchor_index
			buf[offset + 1] = path.depth
			buf[offset + 2] = u8(len(path.edge_ids))
			offset += 3
			for edge_id in path.edge_ids {
				endian.put_u64(buf[offset:], .Big, u64(edge_id))
				offset += 8
			}
		}
	}
	endian.put_u16(buf[offset:], .Big, u16(len(msg.edges))); offset += 2
	for edge in msg.edges {
		endian.put_u64(buf[offset:], .Big, u64(edge.edge_id)); offset += 8
		endian.put_u16(buf[offset:], .Big, u16(edge.source_type)); offset += 2
		endian.put_u64(buf[offset:], .Big, edge.source_id); offset += 8
		endian.put_u16(buf[offset:], .Big, u16(edge.target_type)); offset += 2
		endian.put_u64(buf[offset:], .Big, edge.target_id); offset += 8
		endian.put_u16(buf[offset:], .Big, u16(edge.relation)); offset += 2
	}
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	return total_size
}
