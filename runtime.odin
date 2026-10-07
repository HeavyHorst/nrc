//
// runtime.odin - Runtime boundary seams for production and deterministic simulation
//
// Keep these wrappers small and unconditional at call sites. Production builds
// should optimize down to the direct clock/IO calls, while simulation builds can
// intercept the environmental boundary without forking handler logic.
//
package main

import "core:net"
import "core:sys/linux"
import "core:time"

import "byte_pool"
import nbio_raw "nbio"
import nbio "nbio/poly"
import "persistence"
import "storage_io"
import "ulid"

NRC_SIMULATION :: #config(NRC_SIMULATION, false)

nrc_time_now :: #force_inline proc() -> time.Time {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			return nrc_sim_time_now()
		}
	}
	return ulid.time_now()
}

nrc_time_now_monotonic :: #force_inline proc() -> time.Time {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			return nrc_sim_time_now()
		}
	}
	return ulid.time_now_monotonic()
}

nrc_time_unix_nanos :: #force_inline proc() -> i64 {
	return time.to_unix_nanoseconds(nrc_time_now())
}

nrc_time_unix_seconds :: #force_inline proc() -> u64 {
	return u64(nrc_time_now()._nsec / 1_000_000_000)
}

nrc_wal_time_now :: #force_inline proc "contextless" () -> time.Time {
	return ulid.time_now_monotonic()
}

nrc_persistence_data_dir :: #force_inline proc() -> string {
	if td.persistence_data_dir != "" {
		return td.persistence_data_dir
	}
	return persistence.DATA_DIR
}

nrc_schedule_timer :: proc {
	nrc_schedule_timer1,
	nrc_schedule_timer2,
}

nrc_schedule_timer1 :: proc(dur: time.Duration, p: $T, callback: $C/proc(p: T)) -> ^nbio.Completion {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			return nrc_sim_schedule_timer1(dur, p, callback)
		}
	}
	return nbio.timeout(&td.io, dur, p, callback)
}

nrc_schedule_timer2 :: proc(dur: time.Duration, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^nbio.Completion {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			return nrc_sim_schedule_timer2(dur, p, p2, callback)
		}
	}
	return nbio.timeout(&td.io, dur, p, p2, callback)
}

nrc_cancel_timer :: #force_inline proc(completion: ^nbio.Completion) {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			nrc_sim_cancel_timer(completion)
			return
		}
	}
	nbio.cancel(&td.io, completion)
}

nrc_io_sync_file :: #force_inline proc(file: ^storage_io.File, user: rawptr, callback: nbio_raw.On_File_Sync) -> ^nbio_raw.Completion {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			nrc_sim_capture_fsync(nrc_sim_runtime, file, user, callback)
			return nil
		}
	}
	return nbio_raw.sync_file(&td.io, storage_io.fd(file), user, callback)
}

// The descriptor and buffered batch remain leased until the completion.
nrc_io_append_wal :: proc(file: ^storage_io.File, buf: []byte, user: rawptr, callback: nbio_raw.On_File_Write) -> ^nbio_raw.Completion {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			nrc_sim_capture_wal_append(nrc_sim_runtime, file, buf, user, callback)
			return nil
		}
	}
	return nbio_raw.write_file_at(&td.io, storage_io.fd(file), buf, max(u64), user, callback)
}

NRC_File_Open_Context :: struct {
	storage:  storage_io.Context,
	path:     []byte,
	user:     rawptr,
	callback: proc(user: rawptr, file: ^storage_io.File, err: linux.Errno),
	discard:  proc(user: rawptr),
}

nrc_io_open_read_file :: proc(
	storage: storage_io.Context,
	path: string,
	user: rawptr,
	callback: proc(user: rawptr, file: ^storage_io.File, err: linux.Errno),
	discard: proc(user: rawptr),
) {
	buffer, err := byte_pool.alloc(td.spool, uint(len(path) + 1))
	if err != .None {callback(user, nil, .ENOMEM); return}
	copy(buffer, transmute([]byte)path); buffer[len(path)] = 0
	ctx := new(NRC_File_Open_Context)
	ctx^ = {storage, buffer, user, callback, discard}
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			_ = sim_world_enqueue_event(
				&nrc_sim_runtime.world,
				nrc_sim_runtime.world.now,
				{kind = .Storage},
				.File_Read,
				Sim_Event_Payload(Sim_File_Open_Completion{ctx = ctx}),
			)
			return
		}
	}
	_ = nbio_raw.open_read_file(&td.io, cstring(raw_data(buffer)), ctx, proc(user: rawptr, fd: linux.Fd, err: linux.Errno) {
			ctx := (^NRC_File_Open_Context)(user)
			file: ^storage_io.File
			if err == .NONE do file = storage_io.read_file_from_fd(fd)
			nrc_io_finish_file_open(ctx, file, err)
		})
}

nrc_io_finish_file_open :: proc(ctx: ^NRC_File_Open_Context, file: ^storage_io.File, err: linux.Errno) {
	callback, user := ctx.callback, ctx.user
	byte_pool.release(td.spool, ctx.path)
	free(ctx)
	callback(user, file, err)
}

// Read descriptors acquired through io_uring close through the same loop.
nrc_io_discard_read_file :: proc(file: ^storage_io.File) {
	if file == nil do return
	if fd, ok := file.read_fd.?; ok {
		free(file, file.allocator)
		_ = nbio_raw.close(&td.io, fd)
	} else {
		// Virtual and standalone synchronous read handles have no kernel lease.
		storage_io.discard(file)
	}
}

nrc_io_read_file_at :: #force_inline proc(
	file: ^storage_io.File,
	buf: []byte,
	offset: u64,
	user: rawptr,
	callback: nbio_raw.On_File_Read,
	discard: proc(user: rawptr) = nil,
) -> ^nbio_raw.Completion {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			nrc_sim_capture_file_read(nrc_sim_runtime, file, buf, offset, user, callback, discard)
			return nil
		}
	}
	return nbio_raw.read_file_at(&td.io, storage_io.fd(file), buf, offset, user, callback)
}

nrc_send_frame :: #force_inline proc(
	c: ^NRC_Connection,
	lease: Frame_Lease,
	action := Send_Completion_Action.None,
	priority := false,
	observer := Send_Completion_Observer{},
	shard_independent := false,
) -> bool {
	return websocket_send_all_with_priority(c, lease, action, priority, observer, shard_independent)
}

nrc_io_stats :: #force_inline proc() -> nbio_raw.IO_Stats {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			return {}
		}
	}
	return nbio.get_stats(&td.io)
}

nrc_io_num_waiting :: #force_inline proc() -> int {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			return 0
		}
	}
	return nbio.num_waiting(&td.io)
}

nrc_io_send_all :: #force_inline proc(c: ^NRC_Connection, buf: []byte, item: Send_Item) {
	submitted_item := item
	if submitted_item.handle == {} {
		submitted_item.handle = c.handle
	}
	assert(submitted_item.handle == c.handle, "outbox send item/submitting connection handle mismatch")
	if !connection_io_pin(c) {
		on_queued_send_complete(c.sock, submitted_item, 0, net.TCP_Send_Error(.Not_Connected))
		return
	}
	submitted_item.io_pinned = true
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			if !nrc_sim_capture_queued_send(c, submitted_item) {
				on_queued_send_complete(c.sock, submitted_item, 0, net.TCP_Send_Error(.Not_Connected))
			}
			return
		}
	}
	completion := new(Queued_Send_Completion)
	completion.sock = c.sock
	completion.item = submitted_item
	nbio.send_all(&td.io, c.sock, buf, completion, on_queued_send_complete_context)
}

nrc_io_writev_all :: #force_inline proc(c: ^NRC_Connection, state: ^Batch_Send_State) {
	assert(state != nil && state.count > 0, "outbox writev operation must contain at least one item")
	state.io_pinned = false
	for i in 0 ..< state.count {
		if state.items[i].handle == {} {
			state.items[i].handle = c.handle
		}
		assert(state.items[i].handle == c.handle, "outbox batch item/submitting connection handle mismatch")
	}
	if !connection_io_pin(c) {
		on_batch_send_complete(c.sock, state, 0, net.TCP_Send_Error(.Not_Connected))
		return
	}
	state.io_pinned = true
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			if !nrc_sim_capture_writev_all(c, state) {
				on_batch_send_complete(c.sock, state, 0, net.TCP_Send_Error(.Not_Connected))
			}
			return
		}
	}
	nbio.writev_all(&td.io, c.sock, state.iovec, c.sock, state, on_batch_send_complete)
}

nrc_io_close :: #force_inline proc(
	conn: ^NRC_Connection,
	ctx: Connection_IO_Context,
	shutdown: bool,
	callback: proc(ctx: Connection_IO_Context, shutdown: bool, ok: bool),
) {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			nrc_sim_capture_close(nrc_sim_runtime, ctx, shutdown, callback)
			return
		}
	}
	nbio.close(&td.io, conn.sock, ctx, shutdown, callback)
}

nrc_io_shutdown_send :: #force_inline proc(
	ctx: Connection_IO_Context,
	user: rawptr,
	callback: proc(user: rawptr, err: net.Shutdown_Error),
	discard: proc(user: rawptr) = nil,
) {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			nrc_sim_capture_shutdown_send(nrc_sim_runtime, ctx, user, callback, discard)
			return
		}
	}
	nbio.shutdown(&td.io, ctx.sock, .Send, user, callback)
}
