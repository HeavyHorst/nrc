package main

import "core:fmt"
import "core:os"

SHARDED_GENERATION_DIRECTORY_PREFIX :: "sharded-"
SHARDED_ACTIVE_WAL_NAME :: "active.wal"

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

active_sharded_generation_structure_is_valid :: proc(data_dir: string, generation: u64) -> bool {
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	if !storage_layout_is_real_directory(generation_dir) do return false
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		shard_dir := sharded_shard_path(generation_dir, shard)
		if !storage_layout_is_real_directory(shard_dir) {
			delete(shard_dir)
			return false
		}
		_, manifest_found, manifest_ok := load_shard_compaction_manifest(shard_dir)
		valid := manifest_found && manifest_ok
		if !manifest_found {
			active_path := sharded_active_wal_path(generation_dir, shard)
			info, stat_err := os.lstat(active_path, context.temp_allocator)
			valid = stat_err == nil && info.type == .Regular
			if stat_err == nil do os.file_info_delete(info, context.temp_allocator)
			delete(active_path)
		}
		delete(shard_dir)
		if !valid do return false
	}
	return true
}
