package storage_io

import "core:bytes"
import "core:os"
import "core:strings"
import "core:sys/linux"

when !NRC_SIMULATION {
	_ :: bytes.equal
	_ :: os.Error
	_ :: strings.clone
	_ :: linux.Errno
}

when NRC_SIMULATION {
	Virtual_Inode_Kind :: enum u8 {
		File,
		Directory,
	}

	Virtual_Inode :: struct {
		id:               u64,
		kind:             Virtual_Inode_Kind,
		volatile_data:    [dynamic]byte,
		durable_data:     [dynamic]byte,
		volatile_version: u64,
		durable_version:  u64,
	}

	Virtual_FS :: struct {
		incarnation:         u64,
		capacity_bytes:      u64,
		next_inode_id:       u64,
		inodes:              map[u64]^Virtual_Inode,
		volatile_entries:    map[string]u64,
		durable_entries:     map[string]u64,
		open_files:          [dynamic]^File,
		fail_next_clone:     bool,
		effect_count:        int,
		fail_stop_after:     int,
		fail_stopped:        bool,
		fail_stop_triggered: bool,
	}

	virtual_error :: proc(err: linux.Errno) -> os.Error {
		return os.Platform_Error(err)
	}

	virtual_normalized_path :: proc(path: string) -> string {
		if len(path) == 0 do return "."
		end := len(path)
		for end > 1 && path[end - 1] == '/' do end -= 1
		return path[:end]
	}

	virtual_parent_path :: proc(path: string) -> string {
		normalized := virtual_normalized_path(path)
		if normalized == "/" || normalized == "." do return normalized
		for index := len(normalized) - 1; index >= 0; index -= 1 {
			if normalized[index] != '/' do continue
			if index == 0 do return "/"
			return normalized[:index]
		}
		return "."
	}

	virtual_clone_path :: proc(fs: ^Virtual_FS, path: string) -> (string, bool) {
		if fs.fail_next_clone {
			fs.fail_next_clone = false
			return "", false
		}
		owned, clone_err := strings.clone(path)
		return owned, clone_err == nil
	}

	virtual_entry_set :: proc(fs: ^Virtual_FS, entries: ^map[string]u64, path: string, inode_id: u64) -> bool {
		normalized := virtual_normalized_path(path)
		if _, exists := entries^[normalized]; exists {
			entries^[normalized] = inode_id
			return true
		}
		owned, cloned := virtual_clone_path(fs, normalized)
		if !cloned do return false
		entries^[owned] = inode_id
		return true
	}

	virtual_entry_remove :: proc(entries: ^map[string]u64, path: string) {
		normalized := virtual_normalized_path(path)
		for owned_path in entries^ {
			if owned_path != normalized do continue
			delete_key(entries, owned_path)
			delete(owned_path)
			return
		}
	}

	virtual_entries_destroy :: proc(entries: ^map[string]u64) {
		if entries^ == nil do return
		for path in entries^ do delete(path)
		delete(entries^)
		entries^ = nil
	}

	virtual_inode_create :: proc(fs: ^Virtual_FS, kind: Virtual_Inode_Kind) -> ^Virtual_Inode {
		if fs.next_inode_id == max(u64) do return nil
		fs.next_inode_id += 1
		inode := new(Virtual_Inode)
		inode.id = fs.next_inode_id
		inode.kind = kind
		inode.volatile_data = make([dynamic]byte)
		inode.durable_data = make([dynamic]byte)
		fs.inodes[inode.id] = inode
		return inode
	}

	virtual_inode_destroy :: proc(inode: ^Virtual_Inode) {
		if inode == nil do return
		delete(inode.volatile_data)
		delete(inode.durable_data)
		free(inode)
	}

	virtual_fs_init :: proc(fs: ^Virtual_FS, capacity_bytes: u64 = max(u64)) -> bool {
		fs^ = {}
		fs.incarnation = 1
		fs.capacity_bytes = capacity_bytes
		fs.inodes = make(map[u64]^Virtual_Inode)
		fs.volatile_entries = make(map[string]u64)
		fs.durable_entries = make(map[string]u64)
		fs.open_files = make([dynamic]^File)
		root := virtual_inode_create(fs, .Directory)
		return(
			root != nil &&
			virtual_entry_set(fs, &fs.volatile_entries, "/", root.id) &&
			virtual_entry_set(fs, &fs.durable_entries, "/", root.id) &&
			virtual_entry_set(fs, &fs.volatile_entries, ".", root.id) &&
			virtual_entry_set(fs, &fs.durable_entries, ".", root.id) \
		)
	}

	virtual_fs_destroy :: proc(fs: ^Virtual_FS) {
		if fs == nil do return
		for file in fs.open_files {
			if file != nil do free(file, file.allocator)
		}
		delete(fs.open_files)
		virtual_entries_destroy(&fs.volatile_entries)
		virtual_entries_destroy(&fs.durable_entries)
		if fs.inodes != nil {
			for _, inode in fs.inodes do virtual_inode_destroy(inode)
			delete(fs.inodes)
		}
		fs^ = {}
	}

	virtual_context :: proc(fs: ^Virtual_FS) -> Context {
		if fs == nil do return {}
		return Context{backend = .Virtual, virtual_fs = fs, incarnation = fs.incarnation}
	}

	virtual_fail_next_clone_for_test :: proc(fs: ^Virtual_FS) {
		if fs != nil do fs.fail_next_clone = true
	}

	virtual_set_fail_stop_after_effect_for_test :: proc(fs: ^Virtual_FS, after: int) {
		assert(fs != nil && after > 0 && !fs.fail_stopped)
		fs.effect_count = 0
		fs.fail_stop_after = after
		fs.fail_stop_triggered = false
	}

	virtual_fail_stop_triggered_for_test :: proc(fs: ^Virtual_FS) -> bool {
		return fs != nil && fs.fail_stop_triggered
	}

	virtual_effect_completed :: proc(fs: ^Virtual_FS) {
		if fs == nil || fs.fail_stopped do return
		fs.effect_count += 1
		if fs.fail_stop_after > 0 && fs.effect_count == fs.fail_stop_after {
			fs.fail_stop_triggered = true
			fs.fail_stopped = true
		}
	}

	virtual_context_valid :: proc(storage: Context) -> bool {
		return(
			storage.backend == .Virtual &&
			storage.virtual_fs != nil &&
			!storage.virtual_fs.fail_stopped &&
			storage.incarnation == storage.virtual_fs.incarnation \
		)
	}

	virtual_inode_for_path :: proc(storage: Context, path: string) -> ^Virtual_Inode {
		if !virtual_context_valid(storage) do return nil
		inode_id, exists := storage.virtual_fs.volatile_entries[virtual_normalized_path(path)]
		if !exists do return nil
		return storage.virtual_fs.inodes[inode_id]
	}

	virtual_file_valid :: proc(file: ^File) -> bool {
		return file != nil && file.virtual_fs != nil && !file.virtual_fs.fail_stopped && file.inode != nil && file.incarnation == file.virtual_fs.incarnation
	}

	virtual_track_file :: proc(fs: ^Virtual_FS, file: ^File) {
		append(&fs.open_files, file)
	}

	virtual_untrack_file :: proc(fs: ^Virtual_FS, file: ^File) {
		for tracked, index in fs.open_files {
			if tracked != file do continue
			ordered_remove(&fs.open_files, index)
			return
		}
	}

	virtual_open :: proc(storage: Context, path: string, flags: os.File_Flags) -> (^File, os.Error) {
		if !virtual_context_valid(storage) do return nil, virtual_error(.ESTALE)
		fs := storage.virtual_fs
		normalized := virtual_normalized_path(path)
		readable := .Read in flags
		writable := .Write in flags
		if !readable && !writable do return nil, virtual_error(.EINVAL)
		if .Trunc in flags && !writable do return nil, virtual_error(.EINVAL)
		inode := virtual_inode_for_path(storage, normalized)
		created := false
		if inode != nil && .Excl in flags && .Create in flags do return nil, virtual_error(.EEXIST)
		if inode == nil {
			if .Create not_in flags do return nil, virtual_error(.ENOENT)
			parent := virtual_inode_for_path(storage, virtual_parent_path(normalized))
			if parent == nil do return nil, virtual_error(.ENOENT)
			if parent.kind != .Directory do return nil, virtual_error(.ENOTDIR)
			inode = virtual_inode_create(fs, .File)
			if inode == nil || !virtual_entry_set(fs, &fs.volatile_entries, normalized, inode.id) {
				if inode != nil {
					delete_key(&fs.inodes, inode.id)
					virtual_inode_destroy(inode)
				}
				return nil, virtual_error(.ENOMEM)
			}
			created = true
		}
		if inode.kind != .File do return nil, virtual_error(.EISDIR)
		if .Trunc in flags {
			clear(&inode.volatile_data)
			inode.volatile_version += 1
		}
		file := new(File)
		file.allocator = context.allocator
		file.virtual_fs = fs
		file.inode = inode
		file.incarnation = fs.incarnation
		file.append_mode = .Append in flags
		file.readable = readable
		file.writable = writable
		virtual_track_file(fs, file)
		if created || .Trunc in flags do virtual_effect_completed(fs)
		return file, nil
	}

	virtual_close :: proc(file: ^File) -> os.Error {
		if file == nil do return nil
		valid := virtual_file_valid(file)
		fs := file.virtual_fs
		if fs != nil do virtual_untrack_file(fs, file)
		allocator := file.allocator
		file^ = {}
		free(file, allocator)
		return nil if valid else virtual_error(.ESTALE)
	}

	virtual_discard :: proc(file: ^File) {
		if file == nil do return
		if file.virtual_fs != nil do virtual_untrack_file(file.virtual_fs, file)
		allocator := file.allocator
		file^ = {}
		free(file, allocator)
	}

	virtual_write :: proc(file: ^File, data: []byte) -> (int, os.Error) {
		if !virtual_file_valid(file) do return 0, virtual_error(.ESTALE)
		if !file.writable do return 0, virtual_error(.EBADF)
		start := file.offset
		if file.append_mode do start = len(file.inode.volatile_data)
		if start < 0 || start > max(int) - len(data) do return 0, virtual_error(.EINVAL)
		end := start + len(data)
		if end > len(file.inode.volatile_data) do resize(&file.inode.volatile_data, end)
		copy(file.inode.volatile_data[start:end], data)
		if len(data) > 0 {
			file.inode.volatile_version += 1
			virtual_effect_completed(file.virtual_fs)
		}
		file.offset = end
		return len(data), nil
	}

	virtual_read_at :: proc(file: ^File, out: []byte, offset: int) -> (int, os.Error) {
		if !virtual_file_valid(file) do return 0, virtual_error(.ESTALE)
		if !file.readable do return 0, virtual_error(.EBADF)
		if offset < 0 do return 0, virtual_error(.EINVAL)
		if offset >= len(file.inode.volatile_data) do return 0, nil
		read := min(len(out), len(file.inode.volatile_data) - offset)
		copy(out[:read], file.inode.volatile_data[offset:offset + read])
		return read, nil
	}

	virtual_sync :: proc(file: ^File) -> os.Error {
		if !virtual_file_valid(file) do return virtual_error(.ESTALE)
		resize(&file.inode.durable_data, len(file.inode.volatile_data))
		copy(file.inode.durable_data[:], file.inode.volatile_data[:])
		file.inode.durable_version = file.inode.volatile_version
		virtual_effect_completed(file.virtual_fs)
		return nil
	}

	virtual_capture_sync_snapshot :: proc(file: ^File) -> (Sync_Snapshot, os.Error) {
		if !virtual_file_valid(file) do return {}, virtual_error(.ESTALE)
		data, alloc_err := make([]byte, len(file.inode.volatile_data))
		if alloc_err != nil do return {}, virtual_error(.ENOMEM)
		copy(data, file.inode.volatile_data[:])
		return Sync_Snapshot {
				virtual_fs = file.virtual_fs,
				inode_id = file.inode.id,
				incarnation = file.incarnation,
				version = file.inode.volatile_version,
				data = data,
			},
			nil
	}

	virtual_commit_sync_snapshot :: proc(snapshot: ^Sync_Snapshot) -> os.Error {
		if snapshot == nil || snapshot.virtual_fs == nil do return virtual_error(.EINVAL)
		if snapshot.virtual_fs.fail_stopped do return virtual_error(.ESTALE)
		if snapshot.incarnation != snapshot.virtual_fs.incarnation do return virtual_error(.ESTALE)
		inode := snapshot.virtual_fs.inodes[snapshot.inode_id]
		if inode == nil || inode.kind != .File do return virtual_error(.ESTALE)
		if snapshot.version >= inode.durable_version {
			resize(&inode.durable_data, len(snapshot.data))
			copy(inode.durable_data[:], snapshot.data)
			inode.durable_version = snapshot.version
		}
		virtual_effect_completed(snapshot.virtual_fs)
		return nil
	}

	virtual_truncate :: proc(file: ^File, size: int) -> os.Error {
		if !virtual_file_valid(file) do return virtual_error(.ESTALE)
		if !file.writable do return virtual_error(.EBADF)
		if size < 0 do return virtual_error(.EINVAL)
		resize(&file.inode.volatile_data, size)
		file.inode.volatile_version += 1
		virtual_effect_completed(file.virtual_fs)
		return nil
	}

	virtual_file_size :: proc(file: ^File) -> (i64, os.Error) {
		if !virtual_file_valid(file) do return 0, virtual_error(.ESTALE)
		return i64(len(file.inode.volatile_data)), nil
	}

	virtual_exists :: proc(storage: Context, path: string) -> (bool, os.Error) {
		if !virtual_context_valid(storage) do return false, virtual_error(.ESTALE)
		return virtual_inode_for_path(storage, path) != nil, nil
	}

	virtual_make_directory :: proc(storage: Context, path: string) -> os.Error {
		if !virtual_context_valid(storage) do return virtual_error(.ESTALE)
		normalized := virtual_normalized_path(path)
		if virtual_inode_for_path(storage, normalized) != nil do return virtual_error(.EEXIST)
		parent := virtual_inode_for_path(storage, virtual_parent_path(normalized))
		if parent == nil do return virtual_error(.ENOENT)
		if parent.kind != .Directory do return virtual_error(.ENOTDIR)
		inode := virtual_inode_create(storage.virtual_fs, .Directory)
		if inode == nil || !virtual_entry_set(storage.virtual_fs, &storage.virtual_fs.volatile_entries, normalized, inode.id) {
			if inode != nil {
				delete_key(&storage.virtual_fs.inodes, inode.id)
				virtual_inode_destroy(inode)
			}
			return virtual_error(.ENOMEM)
		}
		virtual_effect_completed(storage.virtual_fs)
		return nil
	}

	virtual_rename :: proc(storage: Context, source, destination: string) -> os.Error {
		if !virtual_context_valid(storage) do return virtual_error(.ESTALE)
		source_path := virtual_normalized_path(source)
		destination_path := virtual_normalized_path(destination)
		if source_path == destination_path do return nil
		if virtual_parent_path(source_path) != virtual_parent_path(destination_path) do return virtual_error(.EXDEV)
		inode_id, exists := storage.virtual_fs.volatile_entries[source_path]
		if !exists do return virtual_error(.ENOENT)
		if _, destination_exists := storage.virtual_fs.volatile_entries[destination_path]; destination_exists {
			storage.virtual_fs.volatile_entries[destination_path] = inode_id
		} else {
			owned_destination, cloned := virtual_clone_path(storage.virtual_fs, destination_path)
			if !cloned do return virtual_error(.ENOMEM)
			storage.virtual_fs.volatile_entries[owned_destination] = inode_id
		}
		virtual_entry_remove(&storage.virtual_fs.volatile_entries, source_path)
		virtual_effect_completed(storage.virtual_fs)
		return nil
	}

	virtual_remove :: proc(storage: Context, path: string) -> os.Error {
		if !virtual_context_valid(storage) do return virtual_error(.ESTALE)
		normalized := virtual_normalized_path(path)
		if _, exists := storage.virtual_fs.volatile_entries[normalized]; !exists do return virtual_error(.ENOENT)
		virtual_entry_remove(&storage.virtual_fs.volatile_entries, normalized)
		virtual_effect_completed(storage.virtual_fs)
		return nil
	}

	virtual_sync_directory :: proc(storage: Context, path: string) -> os.Error {
		if !virtual_context_valid(storage) do return virtual_error(.ESTALE)
		directory_path := virtual_normalized_path(path)
		directory := virtual_inode_for_path(storage, directory_path)
		if directory == nil do return virtual_error(.ENOENT)
		if directory.kind != .Directory do return virtual_error(.ENOTDIR)

		candidate := make(map[string]u64)
		prepared := false
		defer if !prepared do virtual_entries_destroy(&candidate)
		for durable_path, inode_id in storage.virtual_fs.durable_entries {
			if !virtual_entry_set(storage.virtual_fs, &candidate, durable_path, inode_id) do return virtual_error(.ENOMEM)
		}
		remove_paths := make([dynamic]string)
		defer delete(remove_paths)
		for candidate_path in candidate {
			if virtual_parent_path(candidate_path) != directory_path do continue
			if _, exists := storage.virtual_fs.volatile_entries[candidate_path]; exists do continue
			append(&remove_paths, candidate_path)
		}
		for removed in remove_paths do virtual_entry_remove(&candidate, removed)
		for volatile_path, inode_id in storage.virtual_fs.volatile_entries {
			if virtual_parent_path(volatile_path) != directory_path do continue
			if !virtual_entry_set(storage.virtual_fs, &candidate, volatile_path, inode_id) do return virtual_error(.ENOMEM)
		}
		old_durable := storage.virtual_fs.durable_entries
		storage.virtual_fs.durable_entries = candidate
		prepared = true
		virtual_entries_destroy(&old_durable)
		virtual_effect_completed(storage.virtual_fs)
		return nil
	}

	virtual_inode_reachable :: proc(fs: ^Virtual_FS, inode_id: u64) -> bool {
		for _, entry_inode_id in fs.durable_entries do if entry_inode_id == inode_id do return true
		return false
	}

	virtual_remove_durable_orphans :: proc(fs: ^Virtual_FS) {
		for {
			orphan_paths := make([dynamic]string)
			for path in fs.durable_entries {
				if path == "/" || path == "." do continue
				if _, parent_exists := fs.durable_entries[virtual_parent_path(path)]; parent_exists do continue
				append(&orphan_paths, path)
			}
			if len(orphan_paths) == 0 {
				delete(orphan_paths)
				return
			}
			for path in orphan_paths do virtual_entry_remove(&fs.durable_entries, path)
			delete(orphan_paths)
		}
	}

	virtual_fs_crash :: proc(fs: ^Virtual_FS, torn_path: string = "", persist_unsynced_prefix: int = 0) {
		if fs == nil do return
		if torn_path != "" {
			inode_id, exists := fs.volatile_entries[virtual_normalized_path(torn_path)]
			if exists {
				inode := fs.inodes[inode_id]
				if inode != nil &&
				   inode.kind == .File &&
				   len(inode.volatile_data) >= len(inode.durable_data) &&
				   bytes.equal(inode.volatile_data[:len(inode.durable_data)], inode.durable_data[:]) {
					prefix := clamp(persist_unsynced_prefix, 0, len(inode.volatile_data) - len(inode.durable_data))
					old_durable := len(inode.durable_data)
					resize(&inode.durable_data, old_durable + prefix)
					copy(inode.durable_data[old_durable:], inode.volatile_data[old_durable:old_durable + prefix])
				}
			}
		}

		assert(fs.incarnation != max(u64), "virtual storage process incarnation exhausted")
		fs.incarnation += 1
		fs.effect_count = 0
		fs.fail_stop_after = 0
		fs.fail_stopped = false
		fs.fail_stop_triggered = false
		virtual_remove_durable_orphans(fs)
		virtual_entries_destroy(&fs.volatile_entries)
		fs.volatile_entries = make(map[string]u64)
		for durable_path, inode_id in fs.durable_entries do _ = virtual_entry_set(fs, &fs.volatile_entries, durable_path, inode_id)
		remove_inodes := make([dynamic]u64)
		defer delete(remove_inodes)
		for inode_id, inode in fs.inodes {
			if !virtual_inode_reachable(fs, inode_id) {
				append(&remove_inodes, inode_id)
				continue
			}
			resize(&inode.volatile_data, len(inode.durable_data))
			copy(inode.volatile_data[:], inode.durable_data[:])
			inode.volatile_version = inode.durable_version
		}
		for inode_id in remove_inodes {
			inode := fs.inodes[inode_id]
			delete_key(&fs.inodes, inode_id)
			virtual_inode_destroy(inode)
		}
	}
}
