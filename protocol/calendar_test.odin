package protocol

import "core:bytes"
import "core:encoding/endian"
import "core:testing"

calendar_request_body :: proc() -> [52]byte {
	b: [52]byte
	endian.put_u64(b[:], .Big, 7)
	endian.put_i64(b[8:], .Big, 100)
	endian.put_i64(b[16:], .Big, 200)
	endian.put_u16(b[24:], .Big, 25)
	endian.put_u32(b[48:], .Big, 99)
	return b
}

@(test)
test_calendar_request_strict_wire_parsing :: proc(t: ^testing.T) {
	body := calendar_request_body()
	r, err := parseCalendarRequest(body[:])
	testing.expect_value(t, err, ProtocolParseError.None)
	testing.expect_value(t, r.conv_id, ConversationID(7))
	testing.expect_value(t, r.start, i64(100))
	testing.expect_value(t, r.end, i64(200))
	testing.expect_value(t, r.limit, u16(25))
	testing.expect_value(t, r.correlation_id, u32(99))
	for n in 0 ..< len(body) {
		_, short_err := parseCalendarRequest(body[:n])
		testing.expect(t, short_err != nil, "every truncation must fail")
	}
	extra: [53]byte; copy(extra[:], body[:])
	_, err = parseCalendarRequest(extra[:]); testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)

	invalid := body; invalid[26] = 2
	_, err = parseCalendarRequest(invalid[:]); testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	invalid = body; invalid[35] = 1 // cursor bytes must be zero when cursor flag is clear
	_, err = parseCalendarRequest(invalid[:]); testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	invalid = body; invalid[26] = 1; endian.put_i64(invalid[27:], .Big, 100); invalid[35] = 3; endian.put_u64(invalid[36:], .Big, 1)
	_, err = parseCalendarRequest(invalid[:]); testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	invalid[35] = 0; endian.put_u64(invalid[36:], .Big, 0)
	_, err = parseCalendarRequest(invalid[:]); testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	invalid_limits := [?]u16{0, 101}
	for limit in invalid_limits {
		invalid = body; endian.put_u16(invalid[24:], .Big, limit)
		_, err = parseCalendarRequest(invalid[:]); testing.expect(t, err != nil)
	}
	invalid = body; endian.put_i64(invalid[16:], .Big, 100)
	_, err = parseCalendarRequest(invalid[:]); testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	invalid = body; endian.put_u16(invalid[44:], .Big, 1); invalid[46] = 0xff
	_, err = parseCalendarRequest(invalid[:]); testing.expect_value(t, err, ProtocolParseError.InvalidValue)
}

@(test)
test_calendar_page_serialization_independent_decode :: proc(t: ^testing.T) {
	rows := [?]CalendarRow {
		{
			key = {at = 100, kind = 0, id = 9},
			blocked = true,
			title = transmute([]byte)string("task"),
			assignee = transmute([]byte)string("alice"),
			project = transmute([]byte)string("alpha"),
		},
		{key = {at = 100, kind = 1, id = 4}, title = transmute([]byte)string("bell")},
		{key = {at = 100, kind = 2, id = 7}, title = transmute([]byte)string("meet"), actual_start_at = 90, end_at = 110},
	}
	buf: [256]byte
	written := serializeCalendarPage(rows[:], true, 0xa1a2a3a4, buf[:])
	testing.expect_value(t, written, 34 + calendar_row_size(rows[0]) + calendar_row_size(rows[1]) + calendar_row_size(rows[2]))
	opcode, _ := endian.get_u16(buf[:], .Big); testing.expect_value(t, opcode, u16(Opcode.S_CalendarPage))
	conv, ok := endian.get_u64(buf[2:], .Big); testing.expect(t, ok); testing.expect_value(t, conv, u64(0))
	count, _ := endian.get_u16(buf[10:], .Big); testing.expect_value(t, count, u16(3))
	testing.expect_value(t, buf[12], u8(1))
	cursor_at, _ := endian.get_i64(buf[13:], .Big); cursor_id, _ := endian.get_u64(buf[22:], .Big)
	testing.expect_value(t, cursor_at, i64(100)); testing.expect_value(t, buf[21], u8(2)); testing.expect_value(t, cursor_id, u64(7))
	offset := 30
	for expected in rows {
		testing.expect_value(t, buf[offset], expected.key.kind); offset += 1
		id, _ := endian.get_u64(buf[offset:], .Big); offset += 8
		at, _ := endian.get_i64(buf[offset:], .Big); offset += 8
		testing.expect_value(t, id, expected.key.id); testing.expect_value(t, at, expected.key.at)
		testing.expect_value(t, buf[offset], expected.blocked ? u8(1) : u8(0)); offset += 1
		texts := [?][]byte{expected.title, expected.assignee, expected.project}
		for text in texts {
			length, _ := endian.get_u16(buf[offset:], .Big); offset += 2
			testing.expect_value(t, length, u16(len(text)))
			testing.expect(t, bytes.equal(buf[offset:offset + int(length)], text)); offset += int(length)
		}
		if expected.key.kind == 2 {
			actual_start, _ := endian.get_i64(buf[offset:], .Big); offset += 8
			end_at, _ := endian.get_i64(buf[offset:], .Big); offset += 8
			testing.expect_value(t, actual_start, expected.actual_start_at)
			testing.expect_value(t, end_at, expected.end_at)
		}
	}
	correlation, _ := endian.get_u32(buf[offset:], .Big)
	testing.expect_value(t, correlation, u32(0xa1a2a3a4)); testing.expect_value(t, offset + 4, written)
	testing.expect_value(t, serializeCalendarPage(rows[:], true, 1, buf[:written - 1]), -1)
	many: [101]CalendarRow
	large_buf: [34 + 101 * 24]byte
	testing.expect_value(t, serializeCalendarPage(many[:], false, 1, large_buf[:]), -1)
}
