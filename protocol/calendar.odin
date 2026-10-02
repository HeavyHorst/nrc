package protocol

import "core:encoding/endian"
import "core:unicode/utf8"

CalendarKey :: struct {
	at:   i64,
	kind: u8, // 0 task, 1 reminder, 2 appointment; IDs are independent namespaces.
	id:   u64,
}
CalendarRequest :: struct {
	conv_id:           ConversationID,
	start, end:        i64, // Half-open interval of absolute nanosecond instants.
	limit:             u16,
	has_cursor:        bool,
	cursor:            CalendarKey,
	assignee, project: []byte,
	correlation_id:    u32,
}
CalendarRow :: struct {
	key:                      CalendarKey,
	blocked:                  bool,
	title, assignee, project: []byte,
	actual_start_at, end_at:  i64, // Appointment-only; end_at=0 is a point appointment.
}
parseCalendarRequest :: proc(data: []byte) -> (r: CalendarRequest, err: ProtocolParseError) {
	if len(data) < 52 do return r, .TooShort
	conv, _ := endian.get_u64(data, .Big); r.conv_id = ConversationID(conv)
	r.start, _ = endian.get_i64(data[8:], .Big); r.end, _ = endian.get_i64(data[16:], .Big)
	r.limit, _ = endian.get_u16(data[24:], .Big)
	if r.start < 0 || r.end <= r.start || r.end - r.start > 62 * 86400 * 1000000000 do return r, .InvalidValue
	if r.limit == 0 || r.limit > 100 do return r, .TooMany
	if data[26] > 1 do return r, .InvalidValue
	r.has_cursor = data[26] == 1
	r.cursor.at, _ = endian.get_i64(data[27:], .Big); r.cursor.kind = data[35]
	r.cursor.id, _ = endian.get_u64(data[36:], .Big)
	if r.has_cursor {
		if r.cursor.kind > 2 || r.cursor.at < r.start || r.cursor.at >= r.end || r.cursor.id == 0 do return r, .InvalidValue
	} else if r.cursor != (CalendarKey{}) do return r, .InvalidValue
	offset := 44
	for field, i in ([?]^[]byte{&r.assignee, &r.project}) {
		length, ok := endian.get_u16(data[offset:], .Big); if !ok do return r, .TooShort
		offset += 2
		if int(length) > (i == 0 ? MAX_ASSIGNEE_LENGTH : MAX_PROJECT_LENGTH) || offset + int(length) > len(data) do return r, .InvalidValue
		field^ = data[offset:offset + int(length)]; offset += int(length)
		if !utf8.valid_string(string(field^)) do return r, .InvalidValue
	}
	if offset + 4 != len(data) do return r, .ContentLengthMismatch
	r.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return r, nil
}
calendar_row_size :: proc(row: CalendarRow) -> int {return 24 + len(row.title) + len(row.assignee) + len(row.project) + (row.key.kind == 2 ? 16 : 0)}
serializeCalendarPage :: proc(rows: []CalendarRow, more: bool, correlation: u32, buf: []byte) -> int {
	size := 34
	for row in rows do size += calendar_row_size(row)
	if len(buf) < size || len(rows) > 100 do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_CalendarPage))
	endian.put_u64(buf[2:], .Big, 0)
	endian.put_u16(buf[10:], .Big, u16(len(rows)))
	buf[12] = more ? 1 : 0
	cursor: CalendarKey
	if len(rows) > 0 do cursor = rows[len(rows) - 1].key
	endian.put_i64(buf[13:], .Big, cursor.at); buf[21] = cursor.kind
	endian.put_u64(buf[22:], .Big, cursor.id)
	offset := 30
	for row in rows {
		buf[offset] = row.key.kind; offset += 1
		endian.put_u64(buf[offset:], .Big, row.key.id); offset += 8
		endian.put_i64(buf[offset:], .Big, row.key.at); offset += 8
		buf[offset] = row.blocked ? 1 : 0; offset += 1
		for text in ([?][]byte{row.title, row.assignee, row.project}) {
			if len(text) > 65535 do return -1
			endian.put_u16(buf[offset:], .Big, u16(len(text))); offset += 2
			copy(buf[offset:], text); offset += len(text)
		}
		if row.key.kind == 2 {
			endian.put_i64(buf[offset:], .Big, row.actual_start_at); offset += 8
			endian.put_i64(buf[offset:], .Big, row.end_at); offset += 8
		}
	}
	endian.put_u32(buf[offset:], .Big, correlation)
	return size
}
