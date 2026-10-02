package ulid

// Tests ULID encoding/decoding, ordering, monotonic generation, and generated
// roundtrips. The server relies on these IDs for stable identity and cursor order,
// so this file keeps both byte/string forms and sort behavior pinned.

import "core:testing"

import hgl "../hegel"

// ============================================================================
// Basic unit tests
// ============================================================================

@(test)
test_ulid_from_string_rejects_short_string :: proc(t: ^testing.T) {
	_, ok := ulid_from_string("SHORT")
	testing.expect(t, !ok, "short string should be rejected")
}

@(test)
test_ulid_from_string_rejects_long_string :: proc(t: ^testing.T) {
	_, ok := ulid_from_string("THISSTRINGISWAYTOOLONGFORAULIDENCODING123")
	testing.expect(t, !ok, "long string should be rejected")
}

@(test)
test_ulid_from_string_rejects_empty_string :: proc(t: ^testing.T) {
	_, ok := ulid_from_string("")
	testing.expect(t, !ok, "empty string should be rejected")
}

@(test)
test_ulid_from_string_rejects_invalid_characters :: proc(t: ^testing.T) {
	// 'I', 'L', 'O', 'U' are not valid Crockford Base32 characters
	_, ok := ulid_from_string("IAAAAAAAAAAAAAAAAAAAAAAAAA")
	testing.expect(t, !ok, "string with invalid char I should be rejected")
}

@(test)
test_ulid_from_string_rejects_overflow :: proc(t: ^testing.T) {
	// First character > '7' means the 128-bit value would overflow
	_, ok := ulid_from_string("8AAAAAAAAAAAAAAAAAAAAAAAAA")
	testing.expect(t, !ok, "string starting with '8' should overflow")

	_, ok = ulid_from_string("ZAAAAAAAAAAAAAAAAAAAAAAAAA")
	testing.expect(t, !ok, "string starting with 'Z' should overflow")
}

@(test)
test_ulid_time_default_zero :: proc(t: ^testing.T) {
	ulid: ULID
	ms := ulid_time(ulid)
	testing.expect_value(t, ms, u64(0))
}

@(test)
test_ulid_set_time_and_get :: proc(t: ^testing.T) {
	ulid: ULID
	expected: u64 = 0x0123456789AB
	set_ok := ulid_set_time(&ulid, expected)
	testing.expect(t, set_ok, "set_time should succeed")
	testing.expect_value(t, ulid_time(ulid), expected)
}

@(test)
test_ulid_set_time_rejects_overflow :: proc(t: ^testing.T) {
	ulid: ULID
	// 2^48 is one too many
	set_ok := ulid_set_time(&ulid, 0x1_0000_0000_0000)
	testing.expect(t, !set_ok, "set_time should reject timestamp >= 2^48")
}

@(test)
test_ulid_known_roundtrip :: proc(t: ^testing.T) {
	// Known ULID from Go reference: timestamp=0, entropy=0
	ulid: ULID
	encoded := ulid_to_string(ulid)
	s := string(encoded[:])
	decoded, decode_ok := ulid_from_string(s)
	testing.expect(t, decode_ok, "zero ULID should round-trip")
	if decode_ok {
		testing.expect_value(t, ulid_time(decoded), u64(0))
	}
}

@(test)
test_ulid_max_time_roundtrip :: proc(t: ^testing.T) {
	ulid: ULID
	set_ok := ulid_set_time(&ulid, 0xFFFF_FFFF_FFFF)
	testing.expect(t, set_ok, "max timestamp should be accepted")

	encoded := ulid_to_string(ulid)
	decoded, decode_ok := ulid_from_string(string(encoded[:]))
	testing.expect(t, decode_ok, "max time ULID should round-trip")
	if decode_ok {
		testing.expect_value(t, ulid_time(decoded), u64(0xFFFF_FFFF_FFFF))
	}
}

@(test)
test_ulid_alizain_compatibility :: proc(t: ^testing.T) {
	// Known reference ULID from the spec (Go oklog/ulid):
	//   timestamp = 1469918176385
	//   entropy   = all zeros
	//   expected  = "01ARYZ6S410000000000000000"
	ulid: ULID
	set_ok := ulid_set_time(&ulid, 1469918176385)
	testing.expect(t, set_ok, "set_time should succeed for reference timestamp")

	// Zero entropy bytes
	for i in 6 ..< 16 {
		ulid.random[i] = 0
	}

	encoded := ulid_to_string(ulid)
	s := string(encoded[:])
	want := "01ARYZ6S410000000000000000"
	testing.expectf(t, s == want, "got %q, want %q", s, want)

	// Also verify decode round-trips back to the same ULID
	decoded, decode_ok := ulid_from_string(want)
	testing.expect(t, decode_ok, "reference ULID should decode")
	if decode_ok {
		for i in 0 ..< 16 {
			testing.expect_value(t, decoded.random[i], ulid.random[i])
		}
		ms := ulid_time(decoded)
		testing.expect_value(t, ms, u64(1469918176385))
	}
}

@(test)
test_ulid_zero :: proc(t: ^testing.T) {
	zero: ULID
	ms := ulid_time(zero)
	testing.expect_value(t, ms, u64(0))

	// Zero ULID encodes to all '0's (timestamp=0, entropy=0)
	encoded := ulid_to_string(zero)
	encoded_str := string(encoded[:])
	want := "00000000000000000000000000"
	testing.expectf(t, encoded_str == want, "zero ULID: got %q, want %q", encoded_str, want)

	// Decode back
	decoded, ok := ulid_from_string(want)
	testing.expect(t, ok, "zero ULID string should decode")
	if ok {
		testing.expect_value(t, ulid_time(decoded), u64(0))
		cmp := ulid_compare(decoded, zero)
		testing.expect_value(t, cmp, 0)
	}
}

@(test)
test_ulid_overflow_boundaries :: proc(t: ^testing.T) {
	testing.expect(t, ulid_set_time(&{}, 0xFFFF_FFFF_FFFF), "max timestamp should be valid")

	check :: proc(t: ^testing.T, input: string, want_ok: bool) {
		_, ok := ulid_from_string(input)
		testing.expectf(t, ok == want_ok, "overflow test %q: got ok=%v, want ok=%v", input, ok, want_ok)
	}

	check(t, "00000000000000000000000000", true)
	check(t, "70000000000000000000000000", true)
	check(t, "7ZZZZZZZZZZZZZZZZZZZZZZZZZ", true)
	check(t, "80000000000000000000000000", false)
	check(t, "80000000000000000000000001", false)
	check(t, "ZZZZZZZZZZZZZZZZZZZZZZZZZZ", false)
}

@(test)
test_ulid_invalid_byte_positions :: proc(t: ^testing.T) {
	base := "0000XSNJG0MQJHBF4QX1EFD6Y3"

	// Invalid byte at every position
	invalid_bytes := []u8{0x00, 0xFF, 'I', 'L', 'O', 'U'}
	for bad in invalid_bytes {
		for pos in 0 ..< EncodedSize {
			buf := make([]u8, EncodedSize)
			for i in 0 ..< EncodedSize {
				if i == pos {
					buf[i] = bad
				} else {
					buf[i] = base[i]
				}
			}
			// Skip first-char overflow cases (handled by separate test)
			if pos == 0 && bad > '7' && bad <= 'Z' {
				delete(buf)
				continue
			}
			_, ok := ulid_from_string(string(buf))
			delete(buf)
			testing.expectf(t, !ok, "string with invalid byte 0x%02x at position %d should be rejected", bad, pos)
		}
	}
}

// ============================================================================
// Hegel property: encode/decode round-trip
// ============================================================================

@(test)
test_ulid_roundtrip_property :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_ulid_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ulid roundtrip property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_ulid_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	// Draw all 16 ULID bytes at once
	bytes, draw_err := hgl.draw_bytes(tc, 16, 16)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw_bytes failed")
	defer delete(bytes)

	ulid: ULID
	for i in 0 ..< 16 {
		ulid.random[i] = bytes[i]
	}

	// Encode to string
	encoded := ulid_to_string(ulid)
	encoded_str := string(encoded[:])

	// Decode back
	decoded, decode_ok := ulid_from_string(encoded_str)
	if !decode_ok {
		return hgl.interesting("roundtrip decode failed")
	}

	// Compare bytes
	for i in 0 ..< 16 {
		if decoded.random[i] != ulid.random[i] {
			return hgl.interesting("roundtrip byte mismatch")
		}
	}

	return hgl.valid()
}

// ============================================================================
// Hegel property: encode/decode round-trip with lowercase input
// ============================================================================

@(test)
test_ulid_roundtrip_lowercase_property :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_ulid_roundtrip_lowercase, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ulid lowercase roundtrip property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_ulid_roundtrip_lowercase :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	bytes, draw_err := hgl.draw_bytes(tc, 16, 16)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw_bytes failed")
	defer delete(bytes)

	ulid: ULID
	for i in 0 ..< 16 {
		ulid.random[i] = bytes[i]
	}

	// Encode to string then lowercase it
	encoded := ulid_to_string(ulid)
	lower_str := make([]u8, 26)
	defer delete(lower_str)
	for i in 0 ..< 26 {
		c := encoded[i]
		if c >= 'A' && c <= 'Z' {
			lower_str[i] = c + 32
		} else {
			lower_str[i] = c
		}
	}

	decoded, decode_ok := ulid_from_string(string(lower_str))
	if !decode_ok {
		return hgl.interesting("lowercase decode failed")
	}

	for i in 0 ..< 16 {
		if decoded.random[i] != ulid.random[i] {
			return hgl.interesting("lowercase roundtrip byte mismatch")
		}
	}

	return hgl.valid()
}

// ============================================================================
// Hegel property: time extraction after encode/decode
// ============================================================================

@(test)
test_ulid_time_roundtrip_property :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_ulid_time_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ulid time roundtrip property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_ulid_time_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	// Draw a random 48-bit timestamp as two halves
	ts_hi, err_hi := hgl.draw_u64(tc, 0, 0xFF_FFFF)
	if err_hi == .Stop_Test do return hgl.abort()
	if err_hi != nil do return hgl.interesting("draw_u64 failed")
	ts_lo, err_lo := hgl.draw_u64(tc, 0, 0xFF_FFFF_FFFF)
	if err_lo == .Stop_Test do return hgl.abort()
	if err_lo != nil do return hgl.interesting("draw_u64 failed")

	ms := (ts_hi << 24) | ts_lo

	// Construct ULID with known timestamp
	ulid: ULID
	if !ulid_set_time(&ulid, ms) {
		return hgl.invalid()
	}

	// Fill entropy with random bytes
	entropy, ent_err := hgl.draw_bytes(tc, 10, 10)
	if ent_err == .Stop_Test do return hgl.abort()
	if ent_err != nil do return hgl.interesting("draw_bytes failed")
	defer delete(entropy)
	for i in 0 ..< 10 {
		ulid.random[6 + i] = entropy[i]
	}

	// Encode
	encoded := ulid_to_string(ulid)

	// Decode
	decoded, decode_ok := ulid_from_string(string(encoded[:]))
	if !decode_ok {
		return hgl.interesting("time roundtrip decode failed")
	}

	// Verify timestamp
	extracted := ulid_time(decoded)
	if extracted != ms {
		return hgl.interesting("time mismatch after roundtrip")
	}

	return hgl.valid()
}

// ============================================================================
// Hegel property: lexicographic sortability
// ============================================================================

@(test)
test_ulid_sortability_property :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_ulid_sortability, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ulid sortability property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_ulid_sortability :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	// Draw two timestamps where t1 < t2
	// Use a base timestamp and a positive delta
	base, base_err := hgl.draw_u64(tc, 0, 0xFFFF_FFFF_FFFE)
	if base_err == .Stop_Test do return hgl.abort()
	if base_err != nil do return hgl.interesting("draw_u64 failed")

	delta, delta_err := hgl.draw_u64(tc, 1, 0xFFFF_FFFF_FFFF - base)
	if delta_err == .Stop_Test do return hgl.abort()
	if delta_err != nil do return hgl.interesting("draw_u64 failed")

	t1 := base
	t2 := base + delta

	ulid1: ULID
	ulid2: ULID
	if !ulid_set_time(&ulid1, t1) || !ulid_set_time(&ulid2, t2) {
		return hgl.invalid()
	}

	// Use same entropy for both so only timestamp affects ordering
	for i in 6 ..< 16 {
		ulid1.random[i] = 0
		ulid2.random[i] = 0
	}

	enc1 := ulid_to_string(ulid1)
	enc2 := ulid_to_string(ulid2)
	s1 := string(enc1[:])
	s2 := string(enc2[:])

	if s1 >= s2 {
		return hgl.interesting("sortability violated: t1 < t2 but encoded string s1 >= s2")
	}

	return hgl.valid()
}

// ============================================================================
// Hegel property: zero-entropy ULIDs compare by time
// ============================================================================

@(test)
test_ulid_zero_entropy_sort_property :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_ulid_zero_entropy_sort, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ulid zero-entropy sort property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_ulid_zero_entropy_sort :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	delta, draw_err := hgl.draw_u64(tc, 1, 1_000_000)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw_u64 failed")

	base, base_err := hgl.draw_u64(tc, 0, 0xFFFF_FFFF_FFFF - delta)
	if base_err == .Stop_Test do return hgl.abort()
	if base_err != nil do return hgl.interesting("draw_u64 failed")

	t1 := base
	t2 := base + delta

	ulid1: ULID
	ulid2: ULID
	if !ulid_set_time(&ulid1, t1) || !ulid_set_time(&ulid2, t2) {
		return hgl.invalid()
	}

	// Zero entropy for both
	for i in 6 ..< 16 {
		ulid1.random[i] = 0
		ulid2.random[i] = 0
	}

	cmp := ulid_compare(ulid1, ulid2)
	if cmp != -1 {
		return hgl.interesting("zero-entropy ULIDs should compare by time")
	}

	enc1 := ulid_to_string(ulid1)
	enc2 := ulid_to_string(ulid2)
	s1 := string(enc1[:])
	s2 := string(enc2[:])
	if s1 >= s2 {
		return hgl.interesting("zero-entropy ULID strings not sorted by time")
	}

	return hgl.valid()
}
