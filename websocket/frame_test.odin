package websocket

// Tests WebSocket frame header parsing/writing and payload handling at the wire
// level. Explicit byte examples pin RFC edge cases while Hegel properties stress
// roundtrips and malformed/truncated frames used by handler-side input tests.

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import hgl "../hegel"

@(test)
// Test a WebSocket frame with a small payload length (within 7 bits).
// Header data breakdown:
// - 227 (11100011): FIN=1, RSV1=1, RSV2=1, RSV3=0, Opcode=011 (reserved)
// - 124 (01111100): Mask=0, Payload Length=124 (fits in 7 bits, no extended length field needed)
// This test ensures that the parser correctly interprets a small payload length
// directly from the Payload Length field in the header and handles reserved opcodes.
testHeaderSmallPayload :: proc(t: ^testing.T) {
	header_data := [2]byte{227, 124}
	header, _, frameErr := readFrameHeader(header_data[:])

	testing.expect_value(t, header.fin, true)
	testing.expect_value(t, header.rsv1, true)
	testing.expect_value(t, header.rsv2, true)
	testing.expect_value(t, header.rsv3, false)
	testing.expect_value(t, header.opcode, opcode._reserved_3)
	testing.expect_value(t, header.payloadLength, 124)
	testing.expect_value(t, frameErr, nil)
}

@(test)
// Test a WebSocket frame with a medium payload length (within 16 bits).
// Header data breakdown:
// - 31 (00011111): FIN=0, RSV1=0, RSV2=0, RSV3=1, Opcode=1111 (reserved)
// - 126 (01111110): Mask=0, Payload Length=126 (indicates that the actual length
//   is in the next 2 bytes)
// - 0, 127 (00000000, 01111111): Extended payload length = 127 (16-bit value)
// This test checks that the parser correctly handles a medium payload length that
// is specified in the extended 16-bit length field and verifies the correct interpretation
// of reserved bits and opcodes.
testHeaderMediumPayload :: proc(t: ^testing.T) {
	header_data := [4]byte{31, 126, 0, 127}
	header, _, frameErr := readFrameHeader(header_data[:])

	testing.expect_value(t, header.fin, false)
	testing.expect_value(t, header.rsv1, false)
	testing.expect_value(t, header.rsv2, false)
	testing.expect_value(t, header.rsv3, true)
	testing.expect_value(t, header.opcode, opcode._reserved_15)
	testing.expect_value(t, header.payloadLength, 127)
	testing.expect_value(t, frameErr, nil)
}

@(test)
// Test a WebSocket frame with a large payload length (within 64 bits).
// Header data breakdown:
// - 216 (11011000): FIN=1, RSV1=1, RSV2=0, RSV3=1, Opcode=1000 (close connection)
// - 127 (01111111): Mask=0, Payload Length=127 (indicates that the actual length
//   is in the next 8 bytes)
// - 0, 0, 0, 0, 0, 1, 0, 1: Extended payload length = 65537 (64-bit value)
// This test verifies that the parser correctly handles a large payload length that
// is specified in the extended 64-bit length field. It also checks for correct
// interpretation of the FIN bit, reserved bits, and the opcode for closing a connection.
testHeaderBigPayload :: proc(t: ^testing.T) {
	header_data := [10]byte{216, 127, 0, 0, 0, 0, 0, 1, 0, 1}
	header, _, frameErr := readFrameHeader(header_data[:])

	testing.expect_value(t, header.fin, true)
	testing.expect_value(t, header.rsv1, true)
	testing.expect_value(t, header.rsv2, false)
	testing.expect_value(t, header.rsv3, true)
	testing.expect_value(t, header.opcode, opcode.opClose)
	testing.expect_value(t, header.payloadLength, 65537)
	testing.expect_value(t, frameErr, nil)
}

@(test)
testWriteReadHeaderLargePayload :: proc(t: ^testing.T) {
	h := header {
		fin           = true,
		rsv1          = true,
		rsv2          = false,
		rsv3          = true,
		opcode        = .opContinuation,
		mask          = true,
		payloadLength = MaxUint16 * 10,
		maskKey       = transmute(u32)[4]byte{4, 7, 10, 2},
	}

	header_data, header_length := writeFrameHeader(h)

	read_header, _, frameErr := readFrameHeader(header_data[:header_length])
	testing.expect_value(t, read_header, h)
	testing.expect_value(t, header_length, 14)
	testing.expect_value(t, frameErr, nil)
}

@(test)
testWriteReadHeaderSmallPayload :: proc(t: ^testing.T) {
	h := header {
		fin           = true,
		rsv1          = true,
		rsv2          = false,
		rsv3          = true,
		opcode        = .opText,
		mask          = true,
		payloadLength = 64,
		maskKey       = transmute(u32)[4]byte{6, 7, 11, 2},
	}

	header_data, header_length := writeFrameHeader(h)

	read_header, _, frameErr := readFrameHeader(header_data[:header_length])
	testing.expect_value(t, read_header, h)
	testing.expect_value(t, header_length, 6)
	testing.expect_value(t, frameErr, nil)
}

@(test)
testWriteReadHeaderMediumPayload :: proc(t: ^testing.T) {
	h := header {
		fin           = false,
		rsv1          = true,
		rsv2          = false,
		rsv3          = true,
		opcode        = .opBinary,
		mask          = true,
		payloadLength = 8654,
		maskKey       = transmute(u32)[4]byte{1, 2, 3, 4},
	}

	header_data, header_length := writeFrameHeader(h)

	read_header, _, frameErr := readFrameHeader(header_data[:header_length])
	testing.expect_value(t, read_header, h)
	testing.expect_value(t, header_length, 8)
	testing.expect_value(t, frameErr, nil)
}

@(test)
testWriteReadHeaderTruncatedPayload :: proc(t: ^testing.T) {
	h := header {
		fin           = false,
		rsv1          = true,
		rsv2          = false,
		rsv3          = true,
		opcode        = .opBinary,
		mask          = true,
		payloadLength = MaxUint16 * 10,
		maskKey       = transmute(u32)[4]byte{1, 2, 3, 4},
	}

	header_data, header_length := writeFrameHeader(h)

	_, _, frameErr := readFrameHeader(header_data[:4])
	testing.expect_value(t, frameErr, frame_error.tooShort)

	// Suppress unused warning
	_ = header_length
}

@(test)
testReadHeaderRejectsNonMinimalExtendedLengthsAndHighBit :: proc(t: ^testing.T) {
	non_minimal_16 := [?]byte{0x82, 126, 0, 125}
	_, _, frameErr := readFrameHeader(non_minimal_16[:])
	testing.expect_value(t, frameErr, frame_error.protocolError)

	non_minimal_64 := [?]byte{0x82, 127, 0, 0, 0, 0, 0, 0, 255, 255}
	_, _, frameErr = readFrameHeader(non_minimal_64[:])
	testing.expect_value(t, frameErr, frame_error.protocolError)

	high_bit_64 := [?]byte{0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0}
	_, _, frameErr = readFrameHeader(high_bit_64[:])
	testing.expect_value(t, frameErr, frame_error.protocolError)
}

Frame_Oracle_Result :: struct {
	status:         frame_iterator_status,
	header_size:    int,
	payload_length: u64,
	consumed:       int,
}

frame_oracle_classify :: proc(data: []byte) -> Frame_Oracle_Result {
	if len(data) < 2 do return {status = .Incomplete}
	length_code := data[1] & 0x7f
	payload_length := u64(length_code)
	header_size := 2
	if length_code == 126 {
		if len(data) < 4 do return {status = .Incomplete}
		payload_length = u64(data[2]) << 8 | u64(data[3])
		if payload_length <= 125 do return {status = .Protocol_Error}
		header_size = 4
	} else if length_code == 127 {
		if len(data) < 10 do return {status = .Incomplete}
		payload_length = 0
		for index in 2 ..< 10 do payload_length = payload_length << 8 | u64(data[index])
		if payload_length <= 65535 || payload_length & (u64(1) << 63) != 0 {
			return {status = .Protocol_Error}
		}
		header_size = 10
	}
	if data[1] & 0x80 != 0 {
		header_size += 4
		if len(data) < header_size do return {status = .Incomplete}
	}
	if payload_length > u64(max(int)) - u64(header_size) do return {status = .Protocol_Error}
	consumed := header_size + int(payload_length)
	if len(data) < consumed do return {status = .Incomplete, header_size = header_size, payload_length = payload_length}
	return {status = .Ok, header_size = header_size, payload_length = payload_length, consumed = consumed}
}

frame_oracle_write_u64_be :: proc(dst: []byte, value: u64) {
	for index in 0 ..< 8 {
		dst[index] = byte(value >> u64((7 - index) * 8))
	}
}

frame_oracle_case :: proc(first_byte, mask_key_choice: u8, encoding: int, requested_length: u64, payload_choice: u8, include_full: bool) -> bool {
	wire: [14 + 512 + 3]byte
	wire[0] = first_byte
	payload_length := requested_length
	header_size := 2
	switch encoding {
	case 0:
		payload_length %= 126
		wire[1] = byte(payload_length)
	case 1:
		payload_length &= 0xffff
		wire[1] = 126
		wire[2] = byte(payload_length >> 8)
		wire[3] = byte(payload_length)
		header_size = 4
	case:
		wire[1] = 127
		frame_oracle_write_u64_be(wire[2:10], payload_length)
		header_size = 10
	}
	masked := mask_key_choice & 1 != 0
	if masked {
		wire[1] |= 0x80
		for index in 0 ..< 4 do wire[header_size + index] = mask_key_choice + u8(index * 29)
		header_size += 4
	}
	payload_count := 0
	if include_full && payload_length <= 512 {
		payload_count = int(payload_length)
	} else if payload_length > 0 {
		payload_cap := payload_length > 512 ? 512 : int(payload_length)
		payload_count = int(payload_choice) % (payload_cap + 1)
	}
	for index in 0 ..< payload_count do wire[header_size + index] = byte(index * 37 + int(payload_choice))
	suffix_count := include_full && payload_length <= 512 ? 3 : 0
	for index in 0 ..< suffix_count do wire[header_size + payload_count + index] = byte(0xe0 + index)
	wire_length := header_size + payload_count + suffix_count

	for prefix_length in 0 ..= wire_length {
		expected := frame_oracle_classify(wire[:prefix_length])
		scratch := wire
		remaining := scratch[:prefix_length]
		original_data := raw_data(remaining)
		parsed, payload, status := frame_iterator(&remaining)
		if status != expected.status do return false
		if status != .Ok {
			if len(remaining) != prefix_length || raw_data(remaining) != original_data do return false
			continue
		}
		if len(remaining) != prefix_length - expected.consumed ||
		   len(payload) != int(expected.payload_length) ||
		   parsed.fin != (first_byte & 0x80 != 0) ||
		   parsed.rsv1 != (first_byte & 0x40 != 0) ||
		   parsed.rsv2 != (first_byte & 0x20 != 0) ||
		   parsed.rsv3 != (first_byte & 0x10 != 0) ||
		   parsed.opcode != opcode(first_byte & 0x0f) ||
		   parsed.mask != masked ||
		   parsed.payloadLength != expected.payload_length {
			return false
		}
		if masked {
			expected_mask_key := u32(mask_key_choice) | u32(mask_key_choice + 29) << 8 | u32(mask_key_choice + 58) << 16 | u32(mask_key_choice + 87) << 24
			if parsed.maskKey != expected_mask_key do return false
		}
		if suffix_count > 0 && prefix_length == wire_length {
			if len(remaining) != suffix_count do return false
			for index in 0 ..< suffix_count {
				if remaining[index] != byte(0xe0 + index) do return false
			}
		}
	}
	return true
}

@(test)
testFrameIteratorIndependentBoundaryClassification :: proc(t: ^testing.T) {
	lengths := [?]u64{0, 1, 124, 125, 126, 127, 255, 65535, 65536, 65537, u64(max(int)) - 14, u64(max(int)), u64(1) << 63}
	for encoding in 0 ..< 3 {
		for length in lengths {
			testing.expect(t, frame_oracle_case(0x82, 0, encoding, length, 173, true), "independent unmasked frame classification mismatch")
			testing.expect(t, frame_oracle_case(0x8f, 1, encoding, length, 91, true), "independent masked frame classification mismatch")
		}
	}
}

@(test)
test_hegel_frame_iterator_independent_classification :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_frame_iterator_independent_classification, nil, {test_cases = 2000})
	testing.expectf(t, err == nil, "independent frame classification failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_frame_iterator_independent_classification :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	first_byte, first_err := hgl.draw_u32(tc, 0, 255)
	if first_err == .Stop_Test do return hgl.abort()
	if first_err != nil do return hgl.interesting("draw independent frame first byte")
	mask_choice, mask_err := hgl.draw_u32(tc, 0, 255)
	if mask_err == .Stop_Test do return hgl.abort()
	if mask_err != nil do return hgl.interesting("draw independent frame mask key")
	encoding, encoding_err := hgl.draw_i64(tc, 0, 2)
	if encoding_err == .Stop_Test do return hgl.abort()
	if encoding_err != nil do return hgl.interesting("draw independent frame length encoding")
	lengths := [?]u64{0, 1, 2, 124, 125, 126, 127, 255, 65535, 65536, 65537, u64(max(int)) - 14, u64(max(int)), u64(1) << 63}
	length_index, length_err := hgl.draw_i64(tc, 0, i64(len(lengths) - 1))
	if length_err == .Stop_Test do return hgl.abort()
	if length_err != nil do return hgl.interesting("draw independent frame boundary length")
	payload_choice, payload_err := hgl.draw_u32(tc, 0, 255)
	if payload_err == .Stop_Test do return hgl.abort()
	if payload_err != nil do return hgl.interesting("draw independent frame payload prefix")
	include_full, full_err := hgl.draw_bool(tc)
	if full_err == .Stop_Test do return hgl.abort()
	if full_err != nil do return hgl.interesting("draw independent complete frame")
	if !frame_oracle_case(u8(first_byte), u8(mask_choice), int(encoding), lengths[length_index], u8(payload_choice), include_full) {
		return hgl.interesting("production frame iterator differs from independent classification")
	}
	return hgl.valid()
}

Frame_Benchmark_State :: struct {
	h:        header,
	data:     []byte,
	checksum: u64,
	valid:    bool,
}

benchmark_frame_write_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Frame_Benchmark_State)options.user_data
	last_length := 0
	for _ in 0 ..< options.rounds {
		h := intrinsics.volatile_load(&state.h)
		data, length := writeFrameHeader(h)
		state.checksum += u64(length) + u64(data[0])
		last_length = length
	}
	options.count = options.rounds
	options.processed = options.rounds * last_length
	options.hash = u128(state.checksum)
	return .Okay
}

benchmark_frame_read_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Frame_Benchmark_State)options.user_data
	state.valid = true
	for _ in 0 ..< options.rounds {
		data := intrinsics.volatile_load(&state.data)
		parsed, length, err := readFrameHeader(data)
		state.valid = state.valid && err == nil && parsed == state.h
		state.checksum += u64(length) + parsed.payloadLength
	}
	options.count = options.rounds
	options.processed = options.rounds * len(state.data)
	options.hash = u128(state.checksum)
	return .Okay
}

benchmark_frame_iterator_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Frame_Benchmark_State)options.user_data
	state.valid = true
	for _ in 0 ..< options.rounds {
		s := state.data
		parsed, _, status := frame_iterator(&s)
		state.valid = state.valid && status == .Ok && parsed.payloadLength == state.h.payloadLength
		state.checksum += parsed.payloadLength + u64(len(s))
	}
	options.count = options.rounds
	options.processed = options.rounds * len(state.data)
	options.hash = u128(state.checksum)
	return .Okay
}

log_frame_benchmark :: proc(name: string, options: ^time.Benchmark_Options) {
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof("%s: %.2f ns/op, %.2f ops/s, %.2f MiB/s", name, ns_per_op, options.rounds_per_second, options.megabytes_per_second)
}

@(test)
benchmarkWriteReadHeader :: proc(t: ^testing.T) {
	garbage, enabled := os.lookup_env_alloc("BENCH_FRAME_HEADER", context.allocator)
	defer delete(garbage)
	if !enabled do return
	h := header {
		fin           = false,
		rsv1          = true,
		rsv2          = false,
		rsv3          = true,
		opcode        = .opBinary,
		mask          = true,
		payloadLength = 8654,
		maskKey       = transmute(u32)[4]byte{1, 2, 3, 4},
	}

	header_data, header_len := writeFrameHeader(h)
	state := Frame_Benchmark_State {
		h    = h,
		data = header_data[:header_len],
	}
	write_options := time.Benchmark_Options {
		bench     = benchmark_frame_write_callback,
		rounds    = 30_000_000,
		user_data = &state,
	}
	write_err := time.benchmark(&write_options)
	testing.expect_value(t, write_err, time.Benchmark_Error.Okay)
	testing.expect(t, state.checksum != 0, "write checksum must be observable")
	log_frame_benchmark("Write Frame Header", &write_options)

	state.checksum = 0
	read_options := time.Benchmark_Options {
		bench     = benchmark_frame_read_callback,
		rounds    = 100_000_000,
		user_data = &state,
	}
	read_err := time.benchmark(&read_options)
	testing.expect_value(t, read_err, time.Benchmark_Error.Okay)
	testing.expect(t, state.valid && state.checksum != 0, "read results must be valid and observable")
	log_frame_benchmark("Read Frame Header", &read_options)
}


@(test)
benchmarkFrameIterator :: proc(t: ^testing.T) {
	garbage, bok := os.lookup_env_alloc("BENCH_FRAME_ITERATOR", context.allocator)
	defer delete(garbage)

	if !bok {
		return
	}

	iterations := 2_000_000

	payload_size := 8654
	h := header {
		fin           = true,
		opcode        = .opBinary,
		mask          = true,
		payloadLength = u64(payload_size),
		maskKey       = 0x01020304,
	}

	header_buf, header_len := writeFrameHeader(h)

	data := make([]byte, header_len + payload_size)
	defer delete(data)

	copy(data, header_buf[:header_len])
	for i := header_len; i < len(data); i += 1 {
		data[i] = byte(i & 0xFF)
	}
	mask(data[header_len:], h.maskKey)

	state := Frame_Benchmark_State {
		h    = h,
		data = data,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_frame_iterator_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect(t, state.valid && state.checksum != 0, "iterator results must be valid and observable")
	log_frame_benchmark("Frame Iterator (8KB payload)", &options)
}

@(test)
benchmarkFrameIteratorWithSmallPayload :: proc(t: ^testing.T) {
	garbage, bok := os.lookup_env_alloc("BENCH_FRAME_ITERATOR", context.allocator)
	defer delete(garbage)

	if !bok {
		return
	}

	iterations := 25_000_000

	payload_size := 125
	h := header {
		fin           = true,
		opcode        = .opText,
		mask          = true,
		payloadLength = u64(payload_size),
		maskKey       = 0xdeadbeef,
	}

	header_buf, header_len := writeFrameHeader(h)

	data := make([]byte, header_len + payload_size)
	defer delete(data)

	copy(data, header_buf[:header_len])
	for i := header_len; i < len(data); i += 1 {
		data[i] = byte((i * 17) & 0xFF)
	}
	mask(data[header_len:], h.maskKey)

	state := Frame_Benchmark_State {
		h    = h,
		data = data,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_frame_iterator_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect(t, state.valid && state.checksum != 0, "iterator results must be valid and observable")
	log_frame_benchmark("Frame Iterator (125B payload)", &options)
}

@(test)
test_hegel_frame_header_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_frame_header_roundtrip, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "frame header roundtrip failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_frame_header_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	fin, fin_err := hgl.draw_bool(tc)
	rsv1, rsv1_err := hgl.draw_bool(tc)
	rsv2, rsv2_err := hgl.draw_bool(tc)
	rsv3, rsv3_err := hgl.draw_bool(tc)
	mask_flag, mask_err := hgl.draw_bool(tc)

	if fin_err == .Stop_Test || rsv1_err == .Stop_Test || rsv2_err == .Stop_Test || rsv3_err == .Stop_Test || mask_err == .Stop_Test {
		return hgl.abort()
	}
	if fin_err != nil || rsv1_err != nil || rsv2_err != nil || rsv3_err != nil || mask_err != nil {
		return hgl.interesting("draw bool error")
	}

	opcode_raw, op_err := hgl.draw_u32(tc, 0, 15)
	if op_err == .Stop_Test {
		return hgl.abort()
	}
	if op_err != nil {
		return hgl.interesting("draw opcode error")
	}

	payload_len_raw, len_err := hgl.draw_u64(tc, 0, 1_000_000)
	if len_err == .Stop_Test {
		return hgl.abort()
	}
	if len_err != nil {
		return hgl.interesting("draw payload length error")
	}

	mask_key, key_err := hgl.draw_u32(tc, 0, 0xFFFF_FFFF)
	if key_err == .Stop_Test {
		return hgl.abort()
	}
	if key_err != nil {
		return hgl.interesting("draw mask key error")
	}

	h := header {
		fin           = fin,
		rsv1          = rsv1,
		rsv2          = rsv2,
		rsv3          = rsv3,
		opcode        = opcode(u8(opcode_raw)),
		mask          = mask_flag,
		payloadLength = payload_len_raw,
		maskKey       = mask_key,
	}

	buf, written := writeFrameHeader(h)
	read_h, _, frame_err := readFrameHeader(buf[:written])
	if frame_err != nil {
		return hgl.interesting("readFrameHeader rejected valid header")
	}

	if read_h.fin != h.fin {
		return hgl.interesting("roundtrip fin mismatch")
	}
	if read_h.rsv1 != h.rsv1 {
		return hgl.interesting("roundtrip rsv1 mismatch")
	}
	if read_h.rsv2 != h.rsv2 {
		return hgl.interesting("roundtrip rsv2 mismatch")
	}
	if read_h.rsv3 != h.rsv3 {
		return hgl.interesting("roundtrip rsv3 mismatch")
	}
	if read_h.opcode != h.opcode {
		return hgl.interesting("roundtrip opcode mismatch")
	}
	if read_h.mask != h.mask {
		return hgl.interesting("roundtrip mask mismatch")
	}
	if read_h.payloadLength != h.payloadLength {
		return hgl.interesting("roundtrip payloadLength mismatch")
	}
	if h.mask && read_h.maskKey != h.maskKey {
		return hgl.interesting("roundtrip maskKey mismatch")
	}
	return hgl.valid()
}

@(test)
test_hegel_frame_iterator_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_frame_iterator_roundtrip, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "frame iterator roundtrip failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_frame_iterator_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	payload, draw_err := hgl.draw_bytes(tc, 0, 512)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw payload error")
	}
	defer delete(payload)

	mask_key, key_err := hgl.draw_u32(tc, 0, 0xFFFF_FFFF)
	if key_err == .Stop_Test {
		return hgl.abort()
	}
	if key_err != nil {
		return hgl.interesting("draw mask key error")
	}

	h := header {
		fin           = true,
		opcode        = .opBinary,
		mask          = true,
		payloadLength = u64(len(payload)),
		maskKey       = mask_key,
	}

	header_buf, header_len := writeFrameHeader(h)

	frame_data := make([]byte, header_len + len(payload))
	defer delete(frame_data)
	copy(frame_data, header_buf[:header_len])
	copy(frame_data[header_len:], payload)
	mask(frame_data[header_len:], mask_key)

	remaining := frame_data[:]
	parsed_h, parsed_payload, status := frame_iterator(&remaining)
	if status != .Ok {
		return hgl.interesting("frame_iterator rejected valid frame")
	}
	if len(remaining) != 0 {
		return hgl.interesting("frame_iterator did not consume entire buffer")
	}
	if parsed_h.payloadLength != u64(len(payload)) {
		return hgl.interesting("payload length mismatch")
	}
	if len(parsed_payload) != len(payload) {
		return hgl.interesting("payload size mismatch")
	}
	for i in 0 ..< len(payload) {
		if parsed_payload[i] != payload[i] {
			return hgl.interesting("payload byte mismatch")
		}
	}
	return hgl.valid()
}

@(test)
test_hegel_read_frame_header_robustness :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_read_frame_header_robustness, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "parse robustness failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_read_frame_header_robustness :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	data, draw_err := hgl.draw_bytes(tc, 0, 64)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw_bytes error")
	}
	defer delete(data)

	_, _, _ = readFrameHeader(data)
	return hgl.valid()
}
