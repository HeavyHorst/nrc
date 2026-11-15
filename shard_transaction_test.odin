package main

import "core:testing"

@(test)
test_workspace_shard_hash_vectors :: proc(t: ^testing.T) {
	testing.expect_value(t, LOGICAL_SHARD_COUNT, 256)
	testing.expect_value(t, shard_for_workspace(nil), u8(0x99)) // XXH64(empty)=ef46db3751d8e999
	testing.expect_value(t, shard_for_workspace({byte('a')}), u8(0x5b)) // d24ec4f1a98c6e5b
	testing.expect(t, shard_for_workspace({byte('A')}) != shard_for_workspace({byte('a')}))
	raw := [?]byte{0, 0xff, 0xc3, 0xa9}
	testing.expect_value(t, shard_for_workspace(raw[:]), u8(0x4a)) // f3ec84cbf994164a
	for i in 0 ..< 1000 {
		workspace := [?]byte{byte(i >> 8), byte(i)}
		shard := shard_for_workspace(workspace[:])
		testing.expect(t, int(shard) < LOGICAL_SHARD_COUNT)
		testing.expect_value(t, shard_for_workspace(workspace[:]), shard)
	}
}

@(test)
test_logical_shard_worker_routing_bounds :: proc(t: ^testing.T) {
	for workers in ([4]int{1, 3, 5, MAX_SERVER_WORKER_COUNT}) {
		for shard in 0 ..< LOGICAL_SHARD_COUNT {
			owner, ok := logical_shard_worker(shard, workers)
			testing.expect(t, ok)
			testing.expect_value(t, owner, shard % workers)
		}
	}
	for shard in ([2]int{-1, LOGICAL_SHARD_COUNT}) {
		_, ok := logical_shard_worker(shard, 1)
		testing.expect(t, !ok)
	}
	for workers in ([3]int{-1, 0, MAX_SERVER_WORKER_COUNT + 1}) {
		_, ok := logical_shard_worker(0, workers)
		testing.expect(t, !ok)
	}
}
