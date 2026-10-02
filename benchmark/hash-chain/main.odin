package main

import "core:crypto/blake2b"
import "core:crypto/blake2s"
import "core:crypto/sha2"
import "core:crypto/sha3"
import "core:crypto/sm3"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

Hash_Algorithm :: enum {
	SHA_256,
	SHA_512_256,
	SHA3_256,
	BLAKE2s_256,
	BLAKE2b_256,
	SM3,
}

env_positive_int :: proc(name: string, fallback: int) -> int {
	value, found := os.lookup_env_alloc(name, context.allocator)
	if !found do return fallback
	defer delete(value)
	parsed, ok := strconv.parse_int(value)
	if !ok || parsed <= 0 do return fallback
	return int(parsed)
}

configured_algorithm :: proc() -> (Hash_Algorithm, string, bool) {
	value := os.get_env_alloc("NRC_HASH_BENCH_ALGORITHM", context.allocator)
	defer delete(value)
	switch value {
	case "sha256":
		return .SHA_256, "sha256", true
	case "sha512_256":
		return .SHA_512_256, "sha512_256", true
	case "sha3_256":
		return .SHA3_256, "sha3_256", true
	case "blake2s_256":
		return .BLAKE2s_256, "blake2s_256", true
	case "blake2b_256":
		return .BLAKE2b_256, "blake2b_256", true
	case "sm3":
		return .SM3, "sm3", true
	}
	return {}, "", false
}

chain_sha256 :: proc(data: []byte, rounds: int, digest: ^[32]byte) {
	ctx: sha2.Context_256
	for _ in 0 ..< rounds {
		copy(data[12:44], digest[:])
		sha2.init_256(&ctx)
		sha2.update(&ctx, data)
		sha2.final(&ctx, digest[:])
	}
}

chain_sha512_256 :: proc(data: []byte, rounds: int, digest: ^[32]byte) {
	ctx: sha2.Context_512
	for _ in 0 ..< rounds {
		copy(data[12:44], digest[:])
		sha2.init_512_256(&ctx)
		sha2.update(&ctx, data)
		sha2.final(&ctx, digest[:])
	}
}

chain_sha3_256 :: proc(data: []byte, rounds: int, digest: ^[32]byte) {
	ctx: sha3.Context
	for _ in 0 ..< rounds {
		copy(data[12:44], digest[:])
		sha3.init_256(&ctx)
		sha3.update(&ctx, data)
		sha3.final(&ctx, digest[:])
	}
}

chain_blake2s_256 :: proc(data: []byte, rounds: int, digest: ^[32]byte) {
	ctx: blake2s.Context
	for _ in 0 ..< rounds {
		copy(data[12:44], digest[:])
		blake2s.init(&ctx, 32)
		blake2s.update(&ctx, data)
		blake2s.final(&ctx, digest[:])
	}
}

chain_blake2b_256 :: proc(data: []byte, rounds: int, digest: ^[32]byte) {
	ctx: blake2b.Context
	for _ in 0 ..< rounds {
		copy(data[12:44], digest[:])
		blake2b.init(&ctx, 32)
		blake2b.update(&ctx, data)
		blake2b.final(&ctx, digest[:])
	}
}

chain_sm3 :: proc(data: []byte, rounds: int, digest: ^[32]byte) {
	ctx: sm3.Context
	for _ in 0 ..< rounds {
		copy(data[12:44], digest[:])
		sm3.init(&ctx)
		sm3.update(&ctx, data)
		sm3.final(&ctx, digest[:])
	}
}

run_chain :: proc(algorithm: Hash_Algorithm, data: []byte, rounds: int, digest: ^[32]byte) {
	switch algorithm {
	case .SHA_256:
		chain_sha256(data, rounds, digest)
	case .SHA_512_256:
		chain_sha512_256(data, rounds, digest)
	case .SHA3_256:
		chain_sha3_256(data, rounds, digest)
	case .BLAKE2s_256:
		chain_blake2s_256(data, rounds, digest)
	case .BLAKE2b_256:
		chain_blake2b_256(data, rounds, digest)
	case .SM3:
		chain_sm3(data, rounds, digest)
	}
}

main :: proc() {
	algorithm, label, valid := configured_algorithm()
	if !valid {
		fmt.eprintln("NRC_HASH_BENCH_ALGORITHM must name a supported hash")
		os.exit(2)
	}
	record_bytes := env_positive_int("NRC_HASH_BENCH_RECORD_BYTES", 116)
	rounds := env_positive_int("NRC_HASH_BENCH_ROUNDS", 1_000_000)
	if record_bytes < 44 {
		fmt.eprintln("record size must leave room for the WAL chain predecessor")
		os.exit(2)
	}
	data := make([]byte, record_bytes)
	defer delete(data)
	for &value, i in data do value = byte('a' + i % 26)

	warmup_digest: [32]byte
	run_chain(algorithm, data, min(rounds, 4096), &warmup_digest)
	for i in 12 ..< 44 do data[i] = 0
	digest: [32]byte
	started := time.tick_now()
	run_chain(algorithm, data, rounds, &digest)
	elapsed := time.tick_since(started)
	elapsed_ns := time.duration_nanoseconds(elapsed)
	seconds := time.duration_seconds(elapsed)
	processed_bytes := u64(record_bytes) * u64(rounds)
	checksum: u64
	for value, i in digest do checksum = checksum ~ (u64(value) << u64((i % 8) * 8))
	fmt.printf(
		"HASH_CHAIN_RESULT algorithm=%s record_bytes=%d rounds=%d processed_bytes=%d elapsed_ns=%d hashes_per_s=%.3f mib_per_s=%.3f checksum=%d\n",
		label,
		record_bytes,
		rounds,
		processed_bytes,
		elapsed_ns,
		f64(rounds) / seconds,
		f64(processed_bytes) / (1024 * 1024) / seconds,
		checksum,
	)
}
