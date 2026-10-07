package storage_io

import "core:os"
import "core:strings"
import "core:sys/linux"

NRC_SIMULATION :: #config(NRC_SIMULATION, false)

Backend :: enum u8 {
	Invalid,
	Host,
	Virtual,
}

Storage_Space :: struct {
	capacity_bytes:  u64,
	used_bytes:      u64,
	available_bytes: u64,
}

when NRC_SIMULATION {
	Context :: struct {
		backend:     Backend,
		virtual_fs:  ^Virtual_FS,
		incarnation: u64,
	}

	File :: struct {
		real:        ^os.File,
		read_fd:     Maybe(linux.Fd), // Read-only descriptor adopted after async open.
		virtual_fs:  ^Virtual_FS,
		inode:       ^Virtual_Inode,
		incarnation: u64,
		offset:      int,
		append_mode: bool,
		readable:    bool,
		writable:    bool,
	}

	Sync_Snapshot :: struct {
		host_file:   ^File,
		virtual_fs:  ^Virtual_FS,
		inode_id:    u64,
		incarnation: u64,
		version:     u64,
		data:        []byte,
	}

} else {
	Context :: struct {
		backend: Backend,
	}

	File :: struct {
		real:    ^os.File,
		read_fd: Maybe(linux.Fd),
	}

	Sync_Snapshot :: struct {}
}

host_context :: #force_inline proc() -> Context {
	return Context{backend = .Host}
}

context_is_virtual :: #force_inline proc(storage: Context) -> bool {
	when NRC_SIMULATION {
		return storage.backend == .Virtual && storage.virtual_fs != nil
	}
	return false
}

context_is_host :: #force_inline proc(storage: Context) -> bool {
	return storage.backend == .Host
}

invalid_context_error :: #force_inline proc() -> os.Error {
	return os.Platform_Error(linux.Errno.EBADF)
}

file_is_virtual :: #force_inline proc(file: ^File) -> bool {
	when NRC_SIMULATION {
		return file != nil && file.virtual_fs != nil
	}
	return false
}

open :: proc(storage: Context, path: string, flags: os.File_Flags = {.Read}, perm: os.Permissions = os.Permissions_Default) -> (^File, os.Error) {
	when NRC_SIMULATION {
		if storage.backend == .Virtual {
			return virtual_open(storage, path, flags)
		}
	}
	if !context_is_host(storage) do return nil, invalid_context_error()
	real, err := os.open(path, flags, perm)
	if err != nil do return nil, err
	file := new(File)
	file.real = real
	return file, nil
}

// Takes ownership without os.new_file's synchronous /proc descriptor lookup.
read_file_from_fd :: proc(handle: linux.Fd) -> ^File {
	file := new(File)
	file.read_fd = handle
	return file
}

close :: proc(file: ^File) -> os.Error {
	if file == nil do return nil
	if handle, ok := file.read_fd.?; ok {
		err := linux.close(handle)
		free(file)
		if err != .NONE do return os.Platform_Error(err)
		return nil
	}
	when NRC_SIMULATION {
		if file.virtual_fs != nil {
			return virtual_close(file)
		}
	}
	err := os.close(file.real)
	file.real = nil
	free(file)
	return err
}

discard :: proc(file: ^File) {
	if file == nil do return
	if handle, ok := file.read_fd.?; ok {
		_ = linux.close(handle)
		free(file)
		return
	}
	when NRC_SIMULATION {
		if file.virtual_fs != nil {
			virtual_discard(file)
			return
		}
	}
	if file.real != nil do _ = os.close(file.real)
	file.real = nil
	free(file)
}

write :: proc(file: ^File, data: []byte) -> (int, os.Error) {
	when NRC_SIMULATION {
		if file_is_virtual(file) do return virtual_write(file, data)
	}
	if file == nil || file.real == nil do return 0, os.Platform_Error(linux.Errno.EBADF)
	return os.write(file.real, data)
}

read_at :: proc(file: ^File, out: []byte, offset: int) -> (int, os.Error) {
	if file != nil {
		if handle, ok := file.read_fd.?; ok {
			n, err := linux.pread(handle, out, i64(offset))
			if err != .NONE do return n, os.Platform_Error(err)
			return n, nil
		}
	}
	when NRC_SIMULATION {
		if file_is_virtual(file) do return virtual_read_at(file, out, offset)
	}
	if file == nil || file.real == nil || offset < 0 do return 0, os.Platform_Error(linux.Errno.EINVAL)
	return os.read_at(file.real, out, i64(offset))
}

sync :: proc(file: ^File) -> os.Error {
	when NRC_SIMULATION {
		if file_is_virtual(file) do return virtual_sync(file)
	}
	if file == nil || file.real == nil do return os.Platform_Error(linux.Errno.EBADF)
	return os.sync(file.real)
}

capture_sync_snapshot :: proc(file: ^File) -> (Sync_Snapshot, os.Error) {
	when NRC_SIMULATION {
		if file_is_virtual(file) do return virtual_capture_sync_snapshot(file)
		if file == nil || file.real == nil do return {}, os.Platform_Error(linux.Errno.EBADF)
		return Sync_Snapshot{host_file = file}, nil
	}
	return {}, os.Platform_Error(linux.Errno.ENOSYS)
}

commit_sync_snapshot :: proc(snapshot: ^Sync_Snapshot) -> os.Error {
	when NRC_SIMULATION {
		if snapshot == nil do return os.Platform_Error(linux.Errno.EINVAL)
		if snapshot.virtual_fs != nil do return virtual_commit_sync_snapshot(snapshot)
		if snapshot.host_file != nil do return sync(snapshot.host_file)
	}
	return os.Platform_Error(linux.Errno.ENOSYS)
}

destroy_sync_snapshot :: proc(snapshot: ^Sync_Snapshot) {
	when NRC_SIMULATION {
		if snapshot == nil do return
		delete(snapshot.data)
		snapshot^ = {}
	}
}

truncate :: proc(file: ^File, size: int) -> os.Error {
	when NRC_SIMULATION {
		if file_is_virtual(file) do return virtual_truncate(file, size)
	}
	if file == nil || file.real == nil || size < 0 do return os.Platform_Error(linux.Errno.EINVAL)
	return os.truncate(file.real, i64(size))
}

file_size :: proc(file: ^File) -> (i64, os.Error) {
	if file != nil {
		if handle, ok := file.read_fd.?; ok {
			stat: linux.Stat
			if err := linux.fstat(handle, &stat); err != .NONE do return 0, os.Platform_Error(err)
			return i64(stat.size), nil
		}
	}
	when NRC_SIMULATION {
		if file_is_virtual(file) do return virtual_file_size(file)
	}
	if file == nil || file.real == nil do return 0, os.Platform_Error(linux.Errno.EBADF)
	return os.file_size(file.real)
}

storage_space :: proc(storage: Context, path: string) -> (space: Storage_Space, err: os.Error) {
	when NRC_SIMULATION {
		if storage.backend == .Virtual {
			if storage.virtual_fs == nil do return {}, invalid_context_error()
			used: u64
			for _, inode in storage.virtual_fs.inodes {
				if inode == nil || inode.kind != .File do continue
				size := u64(len(inode.volatile_data))
				used = size > max(u64) - used ? max(u64) : used + size
			}
			space.capacity_bytes = storage.virtual_fs.capacity_bytes
			space.used_bytes = min(used, space.capacity_bytes)
			space.available_bytes = space.capacity_bytes - space.used_bytes
			return space, nil
		}
	}
	if !context_is_host(storage) || path == "" do return {}, invalid_context_error()
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if cpath == nil do return {}, os.Platform_Error(linux.Errno.ENOMEM)
	stat: linux.Stat_FS
	if errno := linux.statfs(cpath, &stat); errno != .NONE do return {}, os.Platform_Error(errno)
	if stat.bsize <= 0 || stat.blocks < 0 || stat.bfree < 0 || stat.bavail < 0 do return {}, os.Platform_Error(linux.Errno.EOVERFLOW)
	block_size := u64(stat.bsize)
	capacity := u64(stat.blocks) > max(u64) / block_size ? max(u64) : u64(stat.blocks) * block_size
	free := u64(stat.bfree) > max(u64) / block_size ? max(u64) : u64(stat.bfree) * block_size
	available := u64(stat.bavail) > max(u64) / block_size ? max(u64) : u64(stat.bavail) * block_size
	space.capacity_bytes = capacity
	space.used_bytes = capacity - min(capacity, free)
	space.available_bytes = min(capacity, available)
	return space, nil
}

read_entire_file :: proc(storage: Context, path: string, allocator := context.allocator) -> ([]byte, os.Error) {
	file, open_err := open(storage, path, {.Read})
	if open_err != nil do return nil, open_err
	defer discard(file)
	size, size_err := file_size(file)
	if size_err != nil do return nil, size_err
	if size < 0 || u64(size) > u64(max(int)) do return nil, os.Platform_Error(linux.Errno.EOVERFLOW)
	data := make([]byte, int(size), allocator)
	read := 0
	for read < len(data) {
		count, read_err := read_at(file, data[read:], read)
		if read_err != nil {
			delete(data, allocator)
			return nil, read_err
		}
		if count == 0 {
			delete(data, allocator)
			return nil, os.Platform_Error(linux.Errno.EIO)
		}
		read += count
	}
	return data, nil
}

fd :: proc(file: ^File) -> linux.Fd {
	if file != nil do if handle, ok := file.read_fd.?; ok do return handle
	if file == nil || file.real == nil do return -1
	return linux.Fd(os.fd(file.real))
}

exists :: proc(storage: Context, path: string) -> (bool, os.Error) {
	when NRC_SIMULATION {
		if storage.backend == .Virtual do return virtual_exists(storage, path)
	}
	if !context_is_host(storage) do return false, invalid_context_error()
	return os.exists(path), nil
}

make_directory :: proc(storage: Context, path: string) -> os.Error {
	when NRC_SIMULATION {
		if storage.backend == .Virtual do return virtual_make_directory(storage, path)
	}
	if !context_is_host(storage) do return invalid_context_error()
	return os.make_directory(path)
}

rename :: proc(storage: Context, source, destination: string) -> os.Error {
	when NRC_SIMULATION {
		if storage.backend == .Virtual do return virtual_rename(storage, source, destination)
	}
	if !context_is_host(storage) do return invalid_context_error()
	return os.rename(source, destination)
}

remove :: proc(storage: Context, path: string) -> os.Error {
	when NRC_SIMULATION {
		if storage.backend == .Virtual do return virtual_remove(storage, path)
	}
	if !context_is_host(storage) do return invalid_context_error()
	return os.remove(path)
}

sync_directory :: proc(storage: Context, path: string) -> os.Error {
	when NRC_SIMULATION {
		if storage.backend == .Virtual do return virtual_sync_directory(storage, path)
	}
	if !context_is_host(storage) do return invalid_context_error()
	directory, open_err := os.open(path, {.Read})
	if open_err != nil do return open_err
	sync_err := os.sync(directory)
	close_err := os.close(directory)
	if sync_err != nil do return sync_err
	return close_err
}
