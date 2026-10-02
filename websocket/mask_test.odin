package websocket

import "base:runtime"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import hgl "../hegel"

@(test)
testMaskSimple :: proc(t: ^testing.T) {
	data := []byte{1, 2, 3, 4, 5, 6, 7}
	expect := []byte{3, 6, 5, 12, 7, 2, 1}
	key := [4]byte{2, 4, 6, 8}
	maskSimple(data, 0, key)
	for _, i in data {
		testing.expect_value(t, data[i], expect[i])
	}
}

@(test)
testMask :: proc(t: ^testing.T) {
	data := []byte{1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1, 2, 3, 4, 5, 6, 7, 6, 6, 6, 6, 6, 5, 4, 3, 2, 1}

	keyBytes := [4]byte{2, 4, 6, 8}
	key := transmute(u32)(keyBytes)
	expect := []byte{1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1, 2, 3, 4, 5, 6, 7, 6, 6, 6, 6, 6, 5, 4, 3, 2, 1}
	maskSimple(expect, 0, keyBytes)

	mask(data, key)
	for _, i in data {
		testing.expect_value(t, data[i], expect[i])
	}
}

@(test)
test_mask_wide_boundary :: proc(t: ^testing.T) {
	key_bytes := [4]byte{2, 4, 6, 8}
	key := transmute(u32)key_bytes
	sizes := [7]int{511, 512, 513, 528, 544, 575, 8654}
	for size in sizes {
		for offset in 0 ..< 64 {
			storage := make([]byte, offset + size + 64)
			for &value in storage do value = 0xa5
			simd_data := storage[offset:offset + size]
			for i in 0 ..< size do simd_data[i] = byte(i)
			scalar_data := make([]byte, size)
			copy(scalar_data, simd_data)

			mask(simd_data, key)
			maskSimple(scalar_data, 0, key_bytes)
			for value, i in simd_data do testing.expect_value(t, value, scalar_data[i])
			for value in storage[:offset] do testing.expect_value(t, value, byte(0xa5))
			for value in storage[offset + size:] do testing.expect_value(t, value, byte(0xa5))

			delete(scalar_data)
			delete(storage)
		}
	}
}

/*@(test)
benchmarkMaskSimple :: proc(t: ^testing.T) {
    key := [4]byte{2, 4, 6, 8}
    dataSize := 1024 * 1024 // 1 MB of data
    data := make([]byte, dataSize)
    defer delete(data)

    for i in 0..<len(data) {
        data[i] = byte(i & 0xFF)
    }

    iterations := 100

    start_time := time.now()
    for _ in 0..<iterations {
        maskSimple(data, 0, key)
    }
    duration := time.duration_seconds(time.since(start_time))
    throughput := f64(dataSize * iterations) / duration / (1024.0 * 1024.0)

    log.infof("Throughput: %.2f MB/s\n", throughput)
}*/

Mask_Benchmark_State :: struct {
	data:     []byte,
	key:      u32,
	checksum: u64,
}

benchmark_mask_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Mask_Benchmark_State)options.user_data
	for _ in 0 ..< options.rounds {
		mask(state.data, state.key)
		state.checksum += u64(state.data[0]) + u64(state.data[len(state.data) - 1])
	}
	options.count = options.rounds
	options.processed = options.rounds * len(state.data)
	options.hash = u128(state.checksum)
	return .Okay
}

@(test)
benchmarkMask :: proc(t: ^testing.T) {
	garbage, bok := os.lookup_env_alloc("BENCH_MASK", context.allocator)
	defer delete(garbage)

	if bok {
		key := transmute(u32)[4]byte{2, 4, 6, 8}
		dataSize := 1024 * 1024 // 1 MB of data
		data := make([]byte, dataSize)
		defer delete(data)

		for i in 0 ..< len(data) {
			data[i] = byte(i & 0xFF)
		}

		iterations := 15000
		check_data := make([]byte, len(data))
		defer delete(check_data)
		copy(check_data, data)
		mask(check_data, key)
		masked_sum := u64(check_data[0]) + u64(check_data[len(check_data) - 1])
		mask(check_data, key)
		unmasked_sum := u64(check_data[0]) + u64(check_data[len(check_data) - 1])

		state := Mask_Benchmark_State {
			data = data,
			key  = key,
		}
		options := time.Benchmark_Options {
			bench     = benchmark_mask_callback,
			rounds    = iterations,
			user_data = &state,
		}
		err := time.benchmark(&options)
		expected_checksum := (masked_sum + unmasked_sum) * u64(iterations / 2)
		testing.expect_value(t, err, time.Benchmark_Error.Okay)
		testing.expect_value(t, state.checksum, expected_checksum)
		testing.expect_value(t, data[0], byte(0))
		ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
		log.infof("Mask: %.2f ns/op, %.2f ops/s, %.2f MiB/s", ns_per_op, options.rounds_per_second, options.megabytes_per_second)
	}
}

@(test)
test_hegel_mask_involution :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_mask_involution, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "mask involution failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_mask_involution :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	key_bytes := [4]byte{2, 4, 6, 8}
	key := transmute(u32)key_bytes

	data, draw_err := hgl.draw_bytes(tc, 0, 256)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw_bytes error")
	}
	defer delete(data)

	original := make([]byte, len(data))
	defer delete(original)
	copy(original, data)

	mask(data, key)
	mask(data, key)

	for i in 0 ..< len(data) {
		if data[i] != original[i] {
			return hgl.interesting("double mask not identity")
		}
	}
	return hgl.valid()
}

@(test)
test_hegel_mask_simd_scalar_equivalence :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_mask_simd_scalar_equivalence, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "mask simd/scalar equiv failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_mask_simd_scalar_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	key_bytes := [4]byte{2, 4, 6, 8}
	key := transmute(u32)key_bytes

	data, draw_err := hgl.draw_bytes(tc, 0, 2048)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw_bytes error")
	}
	defer delete(data)

	simd_copy := make([]byte, len(data))
	defer delete(simd_copy)
	copy(simd_copy, data)

	scalar_copy := make([]byte, len(data))
	defer delete(scalar_copy)
	copy(scalar_copy, data)

	mask(simd_copy, key)
	maskSimple(scalar_copy, 0, key_bytes)

	for i in 0 ..< len(data) {
		if simd_copy[i] != scalar_copy[i] {
			return hgl.interesting("simd/scalar mask mismatch")
		}
	}
	return hgl.valid()
}
