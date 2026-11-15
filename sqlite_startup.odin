package main

import "core:mem"
import "core:os"
import "core:strings"
import db "workspace_db"

SQLITE_EXECUTOR_LIMIT :: 4
SQLITE_QUEUE_CAPACITY :: 64
SQLITE_PORT_BYTES :: 16 * mem.Megabyte
SQLITE_RESULT_BYTES :: mem.Megabyte

sqlite_shard_path :: proc(dir: string, generation: u64, shard: int) -> string {
	root := sharded_generation_path(dir, generation); defer delete(root)
	leaf := sharded_shard_path(root, shard); defer delete(leaf)
	return storage_layout_path(leaf, "workspace.sqlite3")
}

sqlite_generation_valid :: proc(dir: string, generation: u64) -> bool {
	root := sharded_generation_path(dir, generation); defer delete(root)
	if !storage_layout_is_real_directory(root) do return false
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		leaf := sharded_shard_path(root, shard); defer delete(leaf)
		if !storage_layout_is_real_directory(leaf) do return false
		path := sqlite_shard_path(dir, generation, shard); defer delete(path)
		info, err := os.lstat(path, context.allocator)
		if err != nil do return false
		regular := info.type == .Regular
		os.file_info_delete(info, context.allocator)
		if !regular do return false
	}
	return true
}

// Exclusive ownership makes bootstrap fail closed after interruption: a partial
// generation without a manifest is never silently reused or repaired.
sqlite_storage_layout_gate :: proc(dir: string, workers: int) -> (lock: Data_Directory_Lock, ok: bool) {
	if !valid_storage_layout_worker_count(workers) do return
	lock, ok = acquire_data_directory_lock(dir)
	if !ok do return
	ok = false
	defer if !ok do release_data_directory_lock(&lock)
	m, found, valid := load_storage_layout_manifest(dir)
	if found {return lock, valid && m.mode == .SQLite_V1 && sqlite_generation_valid(dir, m.generation)}
	if !valid || !data_directory_is_cold(dir) do return
	root := sharded_generation_path(dir, FRESH_STORAGE_LAYOUT_GENERATION); defer delete(root)
	if os.make_directory(root) != nil do return
	paths: [LOGICAL_SHARD_COUNT]cstring
	defer for path in paths do delete(path)
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		leaf := sharded_shard_path(root, shard); defer delete(leaf)
		if os.make_directory(leaf) != nil do return
		path := sqlite_shard_path(dir, FRESH_STORAGE_LAYOUT_GENERATION, shard); defer delete(path)
		paths[shard] = strings.clone_to_cstring(path)
	}
	e, err := db.start_executor(paths[:], 1, 1, SQLITE_PORT_BYTES, SQLITE_RESULT_BYTES, context.allocator, create_databases = true, validate_paths = true)
	if err != .None do return
	db.finish_submissions(&e.ports[0]); db.join_executor(e); db.destroy_executor(e)
	// Persist database directory entries before publishing the layout manifest.
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		leaf := sharded_shard_path(root, shard); defer delete(leaf)
		if !sqlite_sync_directory(leaf) do return
	}
	if !sqlite_sync_directory(root) do return
	m = {
		generation          = FRESH_STORAGE_LAYOUT_GENERATION,
		mode                = .SQLite_V1,
		workspace_hash      = .XXH64_Seed_0_Raw,
		logical_shard_count = LOGICAL_SHARD_COUNT,
		shard_wal_version   = SHARD_WAL_VERSION,
	}
	ok = install_storage_layout_manifest(dir, m)
	return
}

sqlite_sync_directory :: proc(path: string) -> bool {
	f, err := os.open(path, {.Read}); if err != nil do return false
	defer os.close(f)
	return os.sync(f) == nil
}

// Shard -> worker remains unchanged; every worker owns one port. At most
// four writer/reader pairs share workers; each shard belongs to one pair.
start_server_databases :: proc(server: ^NRC_Server, dir: string, generation: u64, workers: int) -> bool {
	if !valid_storage_layout_worker_count(workers) || !sqlite_generation_valid(dir, generation) do return false
	count := min(workers, SQLITE_EXECUTOR_LIMIT)
	server.databases = make([]^db.Executor, count)
	success := false
	defer if !success do stop_server_databases(server)
	for index in 0 ..< count {
		paths: [LOGICAL_SHARD_COUNT]cstring
		defer for path in paths do delete(path)
		for shard in 0 ..< LOGICAL_SHARD_COUNT {
			if (shard % workers) % count != index do continue
			path := sqlite_shard_path(dir, generation, shard); defer delete(path)
			paths[shard] = strings.clone_to_cstring(path)
		}
		ports := (workers - 1 - index) / count + 1
		e, err := db.start_executor(
			paths[:],
			ports,
			SQLITE_QUEUE_CAPACITY,
			SQLITE_PORT_BYTES,
			SQLITE_RESULT_BYTES,
			context.allocator,
			command_handler = sqlite_execute_task_command,
			validate_paths = true,
			read_reserved_requests = 16,
			read_reserved_bytes = 6 * mem.Megabyte,
		)
		if err != .None do return false
		server.databases[index] = e
	}
	success = true
	return true
}

server_database_port :: proc(server: ^NRC_Server, worker: int) -> ^db.Worker_Port {
	count := len(server.databases)
	return &server.databases[worker % count].ports[worker / count]
}

// Coordinator only, before workers start or after all workers have joined.
stop_server_databases :: proc(server: ^NRC_Server) {
	for e in server.databases {
		if e == nil do continue
		for &port in e.ports do db.finish_submissions(&port)
		db.join_executor(e)
		db.destroy_executor(e)
	}
	delete(server.databases); server.databases = nil
}
