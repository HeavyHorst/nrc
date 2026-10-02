package ulid

import "core:math/rand"
import "core:time"

ULID :: struct {
	random: [16]u8,
}

EncodedSize :: 26 // EncodedSize is the length of a text encoded ULID.
Encoding: [32]u8 : "0123456789ABCDEFGHJKMNPQRSTVWXYZ" // Crockford's Base32 encoding

generate_ulid :: proc() -> [EncodedSize]byte {
	ulid: ULID
	u64_to_bytes(time_now_milliseconds(), ulid.random[:])
	_ = rand.read(ulid.random[6:])

	return ulid_to_string(ulid)
}

time_now_milliseconds :: proc() -> u64 {
	return u64(time.to_unix_nanoseconds(time_now()) / 1_000_000)
}

u64_to_bytes :: proc(value: u64, dst: []u8) {
	dst[0] = byte(value >> 40)
	dst[1] = byte(value >> 32)
	dst[2] = byte(value >> 24)
	dst[3] = byte(value >> 16)
	dst[4] = byte(value >> 8)
	dst[5] = byte(value)
}

// ulid_time extracts the 48-bit Unix millisecond timestamp from a ULID.
ulid_time :: proc(ulid: ULID) -> u64 {
	return(
		u64(ulid.random[5]) |
		u64(ulid.random[4]) << 8 |
		u64(ulid.random[3]) << 16 |
		u64(ulid.random[2]) << 24 |
		u64(ulid.random[1]) << 32 |
		u64(ulid.random[0]) << 40 \
	)
}

// ulid_set_time sets the 48-bit Unix millisecond timestamp on a ULID.
// Returns false if the timestamp exceeds the maximum representable value.
ulid_set_time :: proc(ulid: ^ULID, ms: u64) -> bool {
	if ms > 0xFFFF_FFFF_FFFF {
		return false
	}
	ulid.random[0] = byte(ms >> 40)
	ulid.random[1] = byte(ms >> 32)
	ulid.random[2] = byte(ms >> 24)
	ulid.random[3] = byte(ms >> 16)
	ulid.random[4] = byte(ms >> 8)
	ulid.random[5] = byte(ms)
	return true
}

// decode_base32_char converts a single Crockford Base32 character to its
// 5-bit index. Returns false for invalid characters (including I, L, O, U).
decode_base32_char :: proc(c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'z':
		return decode_base32_char(c - 32)
	case c >= 'A' && c <= 'Z':
		switch c {
		case 'I', 'L', 'O', 'U':
			return 0, false
		case:
			// A=10, B=11, ... but skipping I(9→skip), L(12→skip), O(15→skip), U(21→skip)
			// Simple: base offset, then subtract skipped letters before this one.
			idx := c - 'A' + 10
			if c > 'U' do idx -= 4
			else if c > 'O' do idx -= 3
			else if c > 'L' do idx -= 2
			else if c > 'I' do idx -= 1
			return idx, true
		}
	}
	return 0, false
}

// ulid_from_string decodes a Crockford Base32 encoded ULID string back into a ULID.
// Returns false if the string is the wrong length or contains invalid characters.
ulid_from_string :: proc(s: string) -> (ULID, bool) {
	if len(s) != EncodedSize {
		return {}, false
	}

	v := transmute([]u8)s

	// First character > '7' means the 128-bit value would overflow
	if v[0] > '7' {
		return {}, false
	}

	// Decode all 26 characters into 5-bit values
	vals: [26]u8
	for i in 0 ..< 26 {
		val, ok := decode_base32_char(v[i])
		if !ok {
			return {}, false
		}
		vals[i] = val
	}

	ulid: ULID

	// 6 bytes timestamp (48 bits)
	ulid.random[0] = (vals[0] << 5) | vals[1]
	ulid.random[1] = (vals[2] << 3) | (vals[3] >> 2)
	ulid.random[2] = (vals[3] << 6) | (vals[4] << 1) | (vals[5] >> 4)
	ulid.random[3] = (vals[5] << 4) | (vals[6] >> 1)
	ulid.random[4] = (vals[6] << 7) | (vals[7] << 2) | (vals[8] >> 3)
	ulid.random[5] = (vals[8] << 5) | vals[9]

	// 10 bytes of entropy (80 bits)
	ulid.random[6] = (vals[10] << 3) | (vals[11] >> 2)
	ulid.random[7] = (vals[11] << 6) | (vals[12] << 1) | (vals[13] >> 4)
	ulid.random[8] = (vals[13] << 4) | (vals[14] >> 1)
	ulid.random[9] = (vals[14] << 7) | (vals[15] << 2) | (vals[16] >> 3)
	ulid.random[10] = (vals[16] << 5) | vals[17]
	ulid.random[11] = (vals[18] << 3) | (vals[19] >> 2)
	ulid.random[12] = (vals[19] << 6) | (vals[20] << 1) | (vals[21] >> 4)
	ulid.random[13] = (vals[21] << 4) | (vals[22] >> 1)
	ulid.random[14] = (vals[22] << 7) | (vals[23] << 2) | (vals[24] >> 3)
	ulid.random[15] = (vals[24] << 5) | vals[25]

	return ulid, true
}

// ulid_compare compares two ULIDs lexicographically by their byte representation.
// Returns -1 if a < b, 0 if a == b, 1 if a > b.
ulid_compare :: proc(a, b: ULID) -> int {
	for i in 0 ..< 16 {
		if a.random[i] < b.random[i] do return -1
		if a.random[i] > b.random[i] do return 1
	}
	return 0
}

ulid_to_string :: proc(ulid: ULID) -> [EncodedSize]byte {
	Encoding := Encoding
	dst: [EncodedSize]byte

	// Optimized unrolled loop ahead.
	// From https://github.com/RobThree/NUlid

	// 10 byte timestamp
	dst[0] = Encoding[(ulid.random[0] & 224) >> 5]
	dst[1] = Encoding[ulid.random[0] & 31]
	dst[2] = Encoding[(ulid.random[1] & 248) >> 3]
	dst[3] = Encoding[((ulid.random[1] & 7) << 2) | ((ulid.random[2] & 192) >> 6)]
	dst[4] = Encoding[(ulid.random[2] & 62) >> 1]

	dst[5] = Encoding[((ulid.random[2] & 1) << 4) | ((ulid.random[3] & 240) >> 4)]
	dst[6] = Encoding[((ulid.random[3] & 15) << 1) | ((ulid.random[4] & 128) >> 7)]
	dst[7] = Encoding[(ulid.random[4] & 124) >> 2]
	dst[8] = Encoding[((ulid.random[4] & 3) << 3) | ((ulid.random[5] & 224) >> 5)]
	dst[9] = Encoding[ulid.random[5] & 31]

	// 16 bytes of entropy
	dst[10] = Encoding[(ulid.random[6] & 248) >> 3]
	dst[11] = Encoding[((ulid.random[6] & 7) << 2) | ((ulid.random[7] & 192) >> 6)]
	dst[12] = Encoding[(ulid.random[7] & 62) >> 1]
	dst[13] = Encoding[((ulid.random[7] & 1) << 4) | ((ulid.random[8] & 240) >> 4)]
	dst[14] = Encoding[((ulid.random[8] & 15) << 1) | ((ulid.random[9] & 128) >> 7)]
	dst[15] = Encoding[(ulid.random[9] & 124) >> 2]
	dst[16] = Encoding[((ulid.random[9] & 3) << 3) | ((ulid.random[10] & 224) >> 5)]
	dst[17] = Encoding[ulid.random[10] & 31]
	dst[18] = Encoding[(ulid.random[11] & 248) >> 3]
	dst[19] = Encoding[((ulid.random[11] & 7) << 2) | ((ulid.random[12] & 192) >> 6)]
	dst[20] = Encoding[(ulid.random[12] & 62) >> 1]
	dst[21] = Encoding[((ulid.random[12] & 1) << 4) | ((ulid.random[13] & 240) >> 4)]
	dst[22] = Encoding[((ulid.random[13] & 15) << 1) | ((ulid.random[14] & 128) >> 7)]
	dst[23] = Encoding[(ulid.random[14] & 124) >> 2]
	dst[24] = Encoding[((ulid.random[14] & 3) << 3) | ((ulid.random[15] & 224) >> 5)]
	dst[25] = Encoding[ulid.random[15] & 31]

	return dst
}

/*test: [EncodedSize]byte

main :: proc() {
	sync_tsc_with_clock()
	s := time.now()
	for i in 0 ..< 30_000_000 {
		test = generate_ulid()
	}

	fmt.println("Generated ULID: ", string(test[:]))
	fmt.println(time.duration_seconds(time.since(s)))
}*/
