package main

import "core:fmt"
import "core:hash/xxhash"

SHARDED_GENERATION_DIRECTORY_PREFIX :: "sharded-"
SHARDED_ACTIVE_WAL_NAME :: "active.wal"

// Workspace routing is shared by SQLite ownership and retained message stores.
shard_for_workspace :: proc(workspace: []byte) -> u8 {
	return u8(xxhash.XXH64(workspace) % LOGICAL_SHARD_COUNT)
}

logical_shard_worker :: proc(shard, worker_count: int) -> (worker: int, ok: bool) {
	if shard < 0 || shard >= LOGICAL_SHARD_COUNT || !valid_storage_layout_worker_count(worker_count) do return
	return shard % worker_count, true
}

sharded_generation_name :: proc(generation: u64) -> string {
	return fmt.aprintf("%s%020d", SHARDED_GENERATION_DIRECTORY_PREFIX, generation)
}

sharded_generation_path :: proc(data_dir: string, generation: u64) -> string {
	name := sharded_generation_name(generation)
	defer delete(name)
	return storage_layout_path(data_dir, name)
}

sharded_shard_name :: proc(shard: int) -> string {
	return fmt.aprintf("shard_%03d", shard)
}

sharded_shard_path :: proc(generation_dir: string, shard: int) -> string {
	name := sharded_shard_name(shard)
	defer delete(name)
	return storage_layout_path(generation_dir, name)
}

sharded_active_wal_path :: proc(generation_dir: string, shard: int) -> string {
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	return storage_layout_path(shard_dir, SHARDED_ACTIVE_WAL_NAME)
}
