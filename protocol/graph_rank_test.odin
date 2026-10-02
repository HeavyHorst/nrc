package protocol

import "core:encoding/endian"
import "core:testing"

@(test)
test_parse_graph_rank_request :: proc(t: ^testing.T) {
	buf: [39]byte
	offset := 0
	endian.put_u64(buf[offset:], .Big, 7); offset += 8
	buf[offset] = 1; offset += 1
	endian.put_u16(buf[offset:], .Big, u16(TargetType.Task)); offset += 2
	endian.put_u64(buf[offset:], .Big, 11); offset += 8
	buf[offset] = 1; offset += 1
	endian.put_u16(buf[offset:], .Big, u16(TargetType.Asset)); offset += 2
	endian.put_u64(buf[offset:], .Big, 22); offset += 8
	buf[offset] = 2; offset += 1
	endian.put_u16(buf[offset:], .Big, 3); offset += 2
	buf[offset] = u8(Direction.Outgoing); offset += 1
	buf[offset] = 50; offset += 1
	endian.put_u32(buf[offset:], .Big, 99)

	request, err := parseGraphRankRequest(buf[:])
	testing.expect(t, err == nil, "graph rank request should parse")
	testing.expect_value(t, request.conv_id, ConversationID(7))
	testing.expect_value(t, request.anchors[0], GraphEntityKey{target_type = .Task, target_id = 11})
	testing.expect_value(t, request.candidates[0], GraphEntityKey{target_type = .Asset, target_id = 22})
	testing.expect_value(t, request.max_depth, u8(2))
	testing.expect_value(t, request.correlation_id, u32(99))

	_, err = parseGraphRankRequest(buf[:len(buf) - 1])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)

	endian.put_u16(buf[9:], .Big, 99)
	_, err = parseGraphRankRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	endian.put_u16(buf[9:], .Big, u16(TargetType.Task))
	endian.put_u64(buf[11:], .Big, 0)
	_, err = parseGraphRankRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidValue)
}

@(test)
test_serialize_graph_rank_result :: proc(t: ^testing.T) {
	edge_ids := []EdgeID{42}
	paths := []GraphRankPath{{anchor_index = 0, depth = 1, edge_ids = edge_ids}}
	entries := []GraphRankEntry{{target_type = .Task, target_id = 11, score = 2.5, paths = paths}}
	msg := GraphRankResultMessage {
		conv_id        = 7,
		truncated      = true,
		entries        = entries,
		correlation_id = 99,
	}
	buf: [128]byte
	written := serializeGraphRankResult(msg, buf[:])
	testing.expect_value(t, written, getSizeGraphRankResult(msg))
	testing.expect_value(t, get_opcode(buf[:written]), Opcode.S_GraphRankResult)
	score_bits, ok := endian.get_u64(buf[23:], .Big)
	testing.expect(t, ok, "graph rank score should be encoded")
	testing.expect_value(t, transmute(f64)score_bits, 2.5)
}
