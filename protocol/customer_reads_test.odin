package protocol

import "core:bytes"
import "core:encoding/endian"
import "core:testing"

@(test)
test_customer_read_request_wire_layouts :: proc(t: ^testing.T) {
	edge: [32]byte
	endian.put_u64(edge[:], .Big, 7)
	endian.put_u16(edge[8:], .Big, u16(TargetType.Asset))
	endian.put_u64(edge[10:], .Big, 9)
	endian.put_u16(edge[18:], .Big, 50)
	endian.put_u64(edge[20:], .Big, 11)
	endian.put_u32(edge[28:], .Big, 13)
	r, err := parseListEdgesPagedRequest(edge[:])
	testing.expect(t, err == nil)
	testing.expect_value(t, r.conv_id, ConversationID(7))
	testing.expect_value(t, r.target_id, u64(9))
	testing.expect_value(t, r.after_edge_id, EdgeID(11))
	testing.expect_value(t, r.correlation_id, u32(13))
	_, err = parseListEdgesPagedRequest(edge[:31]); testing.expect_value(t, err, ProtocolParseError.TooShort)
	endian.put_u16(edge[8:], .Big, 99)
	_, err = parseListEdgesPagedRequest(edge[:]); testing.expect_value(t, err, ProtocolParseError.InvalidValue)

	search: [28]byte
	endian.put_u64(search[:], .Big, 17); endian.put_u16(search[8:], .Big, 51)
	endian.put_u64(search[10:], .Big, 19); search[18] = 1; endian.put_u16(search[19:], .Big, 3)
	copy(search[21:], []byte{'A', 'b', 'c'}); endian.put_u32(search[24:], .Big, 23)
	s, search_err := parseSearchCustomersRequest(search[:])
	testing.expect(t, search_err == nil && s.include_archived && bytes.equal(s.query, []byte{'A', 'b', 'c'}))
	testing.expect_value(t, s.correlation_id, u32(23))
	search[18] = 2; _, search_err = parseSearchCustomersRequest(search[:]); testing.expect_value(t, search_err, ProtocolParseError.InvalidValue)
}

@(test)
test_customer_read_response_header_layouts :: proc(t: ^testing.T) {
	edge_msg := EdgeListPageMessage {
		conv_id        = 1,
		target_type    = .Asset,
		target_id      = 2,
		has_more       = true,
		next_edge_id   = 3,
		total_count    = 4,
		correlation_id = 5,
	}
	edge_wire: [39]byte
	testing.expect_value(t, serializeEdgeListPageMessage(edge_msg, edge_wire[:]), 39)
	testing.expect_value(t, get_opcode(edge_wire[:]), Opcode.S_EdgeListPage)
	count, _ := endian.get_u16(edge_wire[33:], .Big)
	testing.expect_value(t, count, u16(0))
	asset_msg := CustomerSearchPageMessage {
		conv_id         = 6,
		has_more        = true,
		next_company_id = 7,
		total_count     = 8,
		correlation_id  = 9,
	}
	asset_wire: [29]byte
	testing.expect_value(t, serializeCustomerSearchPageMessage(asset_msg, asset_wire[:]), 29)
	testing.expect_value(t, get_opcode(asset_wire[:]), Opcode.S_CustomerSearchPage)
	correlation, _ := endian.get_u32(asset_wire[25:], .Big)
	testing.expect_value(t, correlation, u32(9))
}
