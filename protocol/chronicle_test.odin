package protocol

import "core:encoding/endian"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

@(test)
test_chronicle_interop_and_roundtrip :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	// Also emitted verbatim by the Go fixture (request correlation is trailing).
	fixture := `{"op":"claim","consumer":"chronicle-v1","note_id":"18446744073709551615","sources":["1","9007199254740993"]}`
	buf: [8192]byte
	copy(buf[:], fixture)
	endian.put_u32(buf[len(fixture):], .Big, 0x01020304)
	r, correlation, err := parseChronicleRequest(buf[:len(fixture) + 4], allocator)
	testing.expect_value(t, err, ProtocolParseError.None)
	testing.expect_value(t, correlation, u32(0x01020304))
	testing.expect_value(t, r.note_id, "18446744073709551615")
	testing.expect_value(t, r.sources[1], "9007199254740993")
	n := serializeChronicleRequest(r, correlation, buf[:])
	testing.expect(t, n > 6)
	testing.expect_value(t, get_opcode(buf[:n]), Opcode.C_Chronicle)
	decoded, cid, e := parseChronicleRequest(buf[2:n], allocator)
	testing.expect_value(t, e, ProtocolParseError.None)
	testing.expect_value(t, cid, correlation)
	testing.expect_value(t, decoded.note_id, r.note_id)
	testing.expect_value(t, serializeChronicleRequest(r, correlation, buf[:1]), 0)
	n = serializeChronicleRequest(Chronicle_Request{op = "status"}, 0, buf[:])
	_, _, e = parseChronicleRequest(buf[2:n], allocator)
	testing.expect_value(t, e, ProtocolParseError.None)
	endian.put_u16(buf[:], .Big, 180)
	testing.expect_value(t, get_opcode(buf[:2]), Opcode.S_Chronicle)
}

@(test)
test_chronicle_rejects_invalid_requests :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	for fixture in ([?]string{`[]`, `null`, `{}`, `{"op":"unknown"}`, `{"op":"list"} {}`, `{"op":"list","note_id":1}`, `{"op":"list","note_id":null}`, `{"op":"list","note_id":"01"}`, `{"op":"list","note_id":"-1"}`, `{"op":"list","note_id":"18446744073709551616"}`, `{"op":"list","sources":["0"]}`, `{"op":"list","sources":["2","1"]}`, `{"op":"list","sources":["1","1"]}`, `{"op":"list","sources":[1]}`, `{"op":"list","limit":65536}`, `{"op":"list","field":256}`, `{"op":"list","offset":4294967296}`, `{"op":"list","length":-1}`, `{"op":"list","input_tokens":1.0}`, `{"op":"list","output_tokens":null}`, `{"op":"list","unknown":1}`, `{"op":"list","op":"status"}`, `{"op":"list","sources":[["1"]]}`, `{"op":"list","summary":"` + "\xff" + `"}`}) {
		buf: [8192]byte
		copy(buf[:], fixture)
		_, _, err := parseChronicleRequest(buf[:len(fixture) + 4], virtual.arena_allocator(&arena))
		testing.expect(t, err != .None, fixture)
	}
}

@(test)
test_chronicle_boundaries :: proc(t: ^testing.T) {
	buf := make([]byte, MAX_PROTOCOL_PAYLOAD_SIZE)
	defer delete(buf)
	_, _, e := parseChronicleEnvelope(buf[:5])
	testing.expect_value(t, e, ProtocolParseError.TooShort)
	_, _, e = parseChronicleEnvelope(buf[:MAX_PROTOCOL_PAYLOAD_SIZE - 2])
	testing.expect_value(t, e, ProtocolParseError.None)
	_, _, e = parseChronicleEnvelope(buf[:MAX_PROTOCOL_PAYLOAD_SIZE - 1])
	testing.expect_value(t, e, ProtocolParseError.ContentLengthExceedsMax)
	summary := strings.repeat("é", 2048)
	defer delete(summary)
	r := Chronicle_Request {
		op            = "commit",
		summary       = summary,
		limit         = max(u16),
		field         = max(u8),
		offset        = max(u32),
		length        = max(u16),
		input_tokens  = max(u32),
		output_tokens = max(u32),
	}
	n := serializeChronicleRequest(r, max(u32), buf)
	testing.expect(t, n > 0)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	_, _, e = parseChronicleRequest(buf[2:n], virtual.arena_allocator(&arena))
	testing.expect_value(t, e, ProtocolParseError.None)
	// Parser frame cap includes the removed opcode, even for whitespace padding.
	copy(buf, `{"op":"status"}`)
	for i in len(`{"op":"status"}`) ..< MAX_PROTOCOL_PAYLOAD_SIZE - 6 {buf[i] = ' '}
	endian.put_u32(buf[MAX_PROTOCOL_PAYLOAD_SIZE - 6:], .Big, 7)
	_, _, e = parseChronicleRequest(buf[:MAX_PROTOCOL_PAYLOAD_SIZE - 2], virtual.arena_allocator(&arena))
	testing.expect_value(t, e, ProtocolParseError.None)
	sources: [33]string
	// Explicit canonical fixture avoids allocating strings just to form IDs.
	sources = {
		"1",
		"2",
		"3",
		"4",
		"5",
		"6",
		"7",
		"8",
		"9",
		"10",
		"11",
		"12",
		"13",
		"14",
		"15",
		"16",
		"17",
		"18",
		"19",
		"20",
		"21",
		"22",
		"23",
		"24",
		"25",
		"26",
		"27",
		"28",
		"29",
		"30",
		"31",
		"32",
		"33",
	}
	r.sources = sources[:32]
	n = serializeChronicleRequest(r, 0, buf)
	testing.expect(t, n > 0)
	_, _, e = parseChronicleRequest(buf[2:n], virtual.arena_allocator(&arena))
	testing.expect_value(t, e, ProtocolParseError.None)
	r.sources = sources[:]
	testing.expect_value(t, serializeChronicleRequest(r, 0, buf), 0)
	r.sources = nil
	metadata := strings.repeat("x", 129)
	defer delete(metadata)
	r.consumer = metadata[:128]
	testing.expect(t, validateChronicleRequest(r))
	r.consumer = metadata
	testing.expect(t, !validateChronicleRequest(r))
	r.consumer = ""
	r.summary = strings.concatenate({summary, "x"})
	defer delete(r.summary)
	testing.expect_value(t, serializeChronicleRequest(r, 0, buf), 0)
	for op in ([?]string{"list", "claim", "chunk", "reserve", "commit", "retry", "status", "history", "gaps", "delete"}) {
		testing.expect(t, validateChronicleRequest(Chronicle_Request{op = op}))
	}
}

@(test)
test_chronicle_gaps_exact_cursor_roundtrip :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	buf: [8192]byte
	q := Chronicle_Request {
		op      = "gaps",
		note_id = "18446744073709551615",
		cursor  = "9223372036854775808",
		limit   = 16,
	}
	n := serializeChronicleRequest(q, 19, buf[:])
	if !testing.expect(t, n > 6) do return
	r, correlation, err := parseChronicleRequest(buf[2:n], virtual.arena_allocator(&arena))
	testing.expect_value(t, err, ProtocolParseError.None)
	testing.expect_value(t, correlation, u32(19))
	testing.expect_value(t, r.op, q.op)
	testing.expect_value(t, r.note_id, q.note_id)
	testing.expect_value(t, r.cursor, q.cursor)
	testing.expect_value(t, r.limit, q.limit)
}
