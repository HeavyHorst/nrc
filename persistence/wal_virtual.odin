package persistence

import "core:log"
import "core:strings"
import "core:time"

when !NRC_SIMULATION {
	_ :: log.errorf
	_ :: strings.clone
	_ :: time.Time
}

when NRC_SIMULATION {
	Virtual_WAL_File :: struct {
		path:    string,
		stable:  [dynamic]byte,
		pending: [dynamic]byte,
	}

	Virtual_WAL_Device :: struct {
		files: map[string]^Virtual_WAL_File,
	}

	virtual_wal_device_init :: proc(device: ^Virtual_WAL_Device) {
		device^ = {}
		device.files = make(map[string]^Virtual_WAL_File)
	}

	virtual_wal_device_destroy :: proc(device: ^Virtual_WAL_Device) {
		if device.files != nil {
			for _, file in device.files {
				virtual_wal_file_destroy(file)
			}
			delete(device.files)
		}
		device^ = {}
	}

	virtual_wal_open_file :: proc(device: ^Virtual_WAL_Device, path: string) -> ^Virtual_WAL_File {
		if device.files == nil {
			virtual_wal_device_init(device)
		}
		if file := device.files[path]; file != nil {
			return file
		}

		cloned_path, clone_err := strings.clone(path)
		if clone_err != nil {
			return nil
		}

		file := new(Virtual_WAL_File)
		file.path = cloned_path
		file.stable = make([dynamic]byte, 0, 4096)
		file.pending = make([dynamic]byte, 0, 4096)
		device.files[file.path] = file
		return file
	}

	virtual_wal_file_destroy :: proc(file: ^Virtual_WAL_File) {
		if file == nil {
			return
		}
		delete(file.stable)
		delete(file.pending)
		if file.path != "" {
			delete(file.path)
		}
		free(file)
	}

	virtual_wal_write :: proc(file: ^Virtual_WAL_File, data: []byte) -> bool {
		if file == nil {
			return false
		}
		old_len := len(file.pending)
		resize(&file.pending, old_len + len(data))
		copy(file.pending[old_len:], data)
		return true
	}

	virtual_wal_sync :: proc(file: ^Virtual_WAL_File) {
		if file == nil || len(file.pending) == 0 {
			return
		}
		old_len := len(file.stable)
		resize(&file.stable, old_len + len(file.pending))
		copy(file.stable[old_len:], file.pending[:])
		clear(&file.pending)
	}

	// A crash may expose any contiguous prefix of bytes already accepted by
	// write(2) but not covered by fsync. Keeping this choice explicit lets fault
	// tests model both total loss and a torn final append without pretending that
	// pending bytes are atomically durable or atomically lost.
	virtual_wal_crash :: proc(file: ^Virtual_WAL_File, persist_pending_prefix := 0) {
		if file == nil {
			return
		}
		prefix_len := clamp(persist_pending_prefix, 0, len(file.pending))
		if prefix_len > 0 {
			old_len := len(file.stable)
			resize(&file.stable, old_len + prefix_len)
			copy(file.stable[old_len:], file.pending[:prefix_len])
		}
		clear(&file.pending)
	}

	virtual_wal_replace_durable :: proc(file: ^Virtual_WAL_File, data: []byte) -> bool {
		if file == nil {
			return false
		}
		clear(&file.pending)
		resize(&file.stable, len(data))
		copy(file.stable[:], data)
		return true
	}

	virtual_wal_durable_bytes :: proc(file: ^Virtual_WAL_File) -> []byte {
		if file == nil {
			return nil
		}
		return file.stable[:]
	}

	init_virtual_wal :: proc(
		state: ^WAL_State,
		file: ^Virtual_WAL_File,
		path: string,
		magic: u32,
		version: u16,
		thread_index: int,
		get_time: proc "contextless" () -> time.Time,
	) -> bool {
		if file == nil {
			return false
		}

		cloned_path, clone_err := strings.clone(path)
		if clone_err != nil {
			log.errorf("[T%d] Failed to clone virtual WAL path", thread_index)
			return false
		}
		state^ = WAL_State {
			file           = nil,
			path           = cloned_path,
			path_allocator = context.allocator,
			enabled        = true,
			magic          = magic,
			version        = version,
			thread_index   = thread_index,
			get_time       = get_time,
			virtual_file   = rawptr(file),
		}

		now := get_time()
		state.last_fsync = now
		return true
	}

	replay_virtual_wal :: proc(file: ^Virtual_WAL_File, magic: u32, thread_index: int, apply_fn: Apply_Record_Proc) -> Replay_Result {
		return replay_wal_data(virtual_wal_durable_bytes(file), magic, thread_index, apply_fn)
	}
}
