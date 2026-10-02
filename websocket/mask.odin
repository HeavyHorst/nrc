package websocket

import "base:intrinsics"
import "core:math/bits"
import "core:simd"

/// maskSimple applies or removes the WebSocket XOR mask to a byte slice using a simple byte-by-byte loop.
/// It modifies the input slice `b` in-place. This version is straightforward but may be slower
/// than SIMD implementations for large slices.
/// @param b The byte slice to mask or unmask.
/// @param pos The starting offset (0-3) within the 4-byte mask key cycle. Determines which key byte is applied first.
/// @param key The 4-byte WebSocket mask key.
/// @return The offset (0-3) within the mask key cycle that should be used for the *next* byte after the end of slice `b`.
maskSimple :: proc(b: []byte, pos: int, key: [4]byte) -> int {
	pos := pos
	for _, i in b {
		b[i] ~= key[pos & 3]
		pos += 1
	}
	return pos & 3
}

/// fill_simd_with_u32_8x creates a 32-byte SIMD vector (simd.u8x32) by repeating
/// the four bytes of the input `value` eight times. This is useful for preparing a mask key
/// for SIMD XOR operations on 32-byte data chunks.
/// The byte order within the resulting vector depends on the host machine's endianness
/// due to the use of `transmute`.
/// @param value The u32 value whose byte pattern (b0, b1, b2, b3) will be repeated.
/// @return A simd.u8x32 vector containing [b0,b1,b2,b3, b0,b1,b2,b3, ... ] repeated eight times.
fill_simd_with_u32_8x :: proc(value: u32) -> simd.u8x32 {
	// Convert the u32 into four u8 values
	b := transmute([4]byte)value
	return simd.u8x32 {
		b[0],
		b[1],
		b[2],
		b[3],
		b[0],
		b[1],
		b[2],
		b[3],
		b[0],
		b[1],
		b[2],
		b[3],
		b[0],
		b[1],
		b[2],
		b[3],
		b[0],
		b[1],
		b[2],
		b[3],
		b[0],
		b[1],
		b[2],
		b[3],
		b[0],
		b[1],
		b[2],
		b[3],
		b[0],
		b[1],
		b[2],
		b[3],
	}
}

fill_simd_with_u32_16x :: proc(value: u32) -> simd.u8x64 {
	return transmute(simd.u8x64)(simd.u32x16(value))
}

/// fill_simd_with_u32_4x creates a 16-byte SIMD vector (simd.u8x16) by repeating
/// the four bytes of the input `value` four times. Useful for preparing a mask key
/// for SIMD XOR operations on 16-byte data chunks.
/// The byte order within the resulting vector depends on the host machine's endianness
/// due to the use of `transmute`.
/// @param value The u32 value whose byte pattern (b0, b1, b2, b3) will be repeated.
/// @return A simd.u8x16 vector containing [b0,b1,b2,b3, b0,b1,b2,b3, ... ] repeated four times.
fill_simd_with_u32_4x :: proc(value: u32) -> simd.u8x16 {
	b := transmute([4]byte)value
	return simd.u8x16{b[0], b[1], b[2], b[3], b[0], b[1], b[2], b[3], b[0], b[1], b[2], b[3], b[0], b[1], b[2], b[3]}
}

/// mask applies or removes the WebSocket XOR mask to a byte slice using SIMD instructions
/// for potentially improved performance on larger slices. It processes large data in 64-byte chunks,
/// then handles the tail in 32-byte and 16-byte chunks before a final scalar loop.
/// This function modifies the input slice `b` in-place.
/// @param b The byte slice to mask or unmask. Must be non-nil.
/// @param key The 32-bit WebSocket mask key. The byte order within this u32 is used directly
///            to construct the SIMD mask vectors via `fill_simd_with_u32_*x`, which depends
///            on system endianness via `transmute`. Ensure consistency with how the key was read.
/// @return The state of the mask key, rotated as if it were ready to process the byte immediately
///         following the end of slice `b`. This aligns the key state correctly for processing the
///         next chunk if the data is fragmented, matching the byte-by-byte rotation logic.
mask :: #force_inline proc(b: []byte, key: u32) -> u32 {
	length := len(b)
	i := 0
	// The wider vector reduces loop overhead on all targets and uses AVX-512 when enabled for the target,
	// but its extra setup is slower for some small, unaligned payloads.
	if length >= 512 {
		simd_key_16x := fill_simd_with_u32_16x(key)
		for ; i + 64 <= length; i += 64 {
			chunk := simd.from_slice(simd.u8x64, b[i:i + 64])
			masked := simd.bit_xor(chunk, simd_key_16x)
			intrinsics.unaligned_store((^simd.u8x64)(&b[i]), masked)
		}
	}

	simd_key_8x := fill_simd_with_u32_8x(key)
	// Process 32 bytes at a time
	for ; i + 32 <= length; i += 32 {
		// Load 32 bytes from the byte slice into a SIMD vector
		chunk := simd.from_slice(simd.u8x32, b[i:i + 32])

		// Apply the mask using the SIMD key
		chunka := simd.bit_xor(chunk, simd_key_8x)

		// Store the masked bytes back into the slice
		intrinsics.unaligned_store((^simd.u8x32)(&b[i]), chunka)
	}

	simd_key_4x := fill_simd_with_u32_4x(key)
	// Process 16 bytes at a time
	for ; i + 16 <= length; i += 16 {
		// Load 32 bytes from the byte slice into a SIMD vector
		chunk := simd.from_slice(simd.u8x16, b[i:i + 16])

		// Apply the mask using the SIMD key
		chunka := simd.bit_xor(chunk, simd_key_4x)

		// Store the masked bytes back into the slice
		intrinsics.unaligned_store((^simd.u8x16)(&b[i]), chunka)
	}

	k := key
	// Process any remaining bytes that don't fit in a 16-byte SIMD chunk
	for ; i < length; i += 1 {
		b[i] ~= u8(k)
		k = bits.rotate_left32(k, -8)
	}

	return k
}
