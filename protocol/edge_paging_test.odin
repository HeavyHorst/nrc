package protocol

import "core:bytes"
import "core:testing"

@(test)
test_edge_page_wire_contract :: proc(t: ^testing.T) {
	req := ListAllEdgesPagedRequest {
		conv_id        = 0x0102030405060708,
		limit          = 513,
		after_edge_id  = 0x1112131415161718,
		correlation_id = 0xa1a2a3a4,
	}
	expected := [?]byte{0, 53, 1, 2, 3, 4, 5, 6, 7, 8, 2, 1, 17, 18, 19, 20, 21, 22, 23, 24, 161, 162, 163, 164}
	buf: [25]byte
	testing.expect_value(t, serializeListAllEdgesPagedRequest(req, buf[:]), 24)
	testing.expect(t, bytes.equal(buf[:24], expected[:]))
	testing.expect_value(t, get_opcode(buf[:24]), Opcode.C_ListAllEdgesPaged)
	parsed, err := parseListAllEdgesPagedRequest(expected[2:])
	testing.expect_value(t, err, ProtocolParseError.None)
	testing.expect_value(t, parsed, req)
	for n in 0 ..< 22 {
		_, short_err := parseListAllEdgesPagedRequest(expected[2:2 + n])
		testing.expect(t, short_err != nil)
	}
	_, trailing_err := parseListAllEdgesPagedRequest(buf[2:])
	testing.expect_value(t, trailing_err, ProtocolParseError.ContentLengthMismatch)
	testing.expect_value(t, serializeListAllEdgesPagedRequest(req, buf[:23]), -1)

	edges := [?]Edge {
		{
			edge_id = 11,
			conv_id = 23,
			source_type = .Asset,
			source_id = 31,
			target_type = .Task,
			target_id = 47,
			relation = .References,
			created_at = -17,
			created_by = []byte{'x', 'y'},
		},
	}
	msg := AllEdgeListPageMessage {
		conv_id        = 23,
		has_more       = true,
		next_edge_id   = 11,
		total_count    = 321,
		edges          = edges[:],
		correlation_id = 0xa1a2a3a4,
	}
	response: [80]byte
	written := serializeAllEdgeListPageMessage(msg, response[:])
	testing.expect_value(t, written, 79) // 29-byte page header + 48-byte edge header + 2 creator bytes
	header := [?]byte{0, 161, 0, 0, 0, 0, 0, 0, 0, 23, 1, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 1, 65, 0, 1, 161, 162, 163, 164}
	testing.expect(t, bytes.equal(response[:29], header[:]))
	decoded_edges: [1]Edge
	decoded, decode_err := parseAllEdgeListPageMessage(response[:written], decoded_edges[:])
	testing.expect_value(t, decode_err, ProtocolParseError.None)
	testing.expect_value(t, decoded.conv_id, ConversationID(23))
	testing.expect_value(t, decoded.next_edge_id, EdgeID(11))
	testing.expect_value(t, decoded.total_count, u32(321))
	testing.expect_value(t, decoded.correlation_id, u32(0xa1a2a3a4))
	testing.expect(t, decoded.has_more)
	testing.expect_value(t, decoded_edges[0].target_id, u64(47))
	testing.expect_value(t, decoded_edges[0].created_at, i64(-17))
	testing.expect(t, bytes.equal(decoded_edges[0].created_by, []byte{'x', 'y'}))
	for n in 0 ..< written {
		_, short_err := parseAllEdgeListPageMessage(response[:n], decoded_edges[:])
		testing.expect(t, short_err != nil)
	}
	_, capacity_err := parseAllEdgeListPageMessage(response[:written], nil)
	testing.expect_value(t, capacity_err, ProtocolParseError.TooMany)
	_, extra_err := parseAllEdgeListPageMessage(response[:], decoded_edges[:])
	testing.expect_value(t, extra_err, ProtocolParseError.ContentLengthMismatch)
	response[10] = 2
	_, flag_err := parseAllEdgeListPageMessage(response[:written], decoded_edges[:])
	testing.expect_value(t, flag_err, ProtocolParseError.InvalidValue)
}
