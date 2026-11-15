package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

foreign import spool_libc "system:c"
foreign spool_libc {
	mkostemp :: proc "c" (template: cstring, flags: c.int) -> c.int ---
}

// Executor-owned, unlinked temporary file on the database filesystem. It is
// an ephemeral delivery buffer, not a durable outbox or a recovery format.
Command_Spool :: struct {
	fd:           linux.Fd,
	open:         bool,
	size, offset: i64,
}
Spool_Header :: struct {
	size, owner: u32,
	scope:       u64,
	audience:    Command_Audience,
}

@(private)
close_command_spool :: proc(output: ^Command_Output) {
	if output.spool.open do linux.close(output.spool.fd)
	output.spool = {}
}

@(private)
spool_write :: proc(spool: ^Command_Spool, data: []byte) -> bool {
	remaining := data
	for len(remaining) > 0 {
		n, err := linux.pwrite(spool.fd, remaining, spool.size)
		if err == .EINTR do continue
		if err != .NONE || n <= 0 do return false
		spool.size += i64(n); remaining = remaining[n:]
	}
	return true
}

@(private)
spool_read :: proc(spool: ^Command_Spool, data: []byte, offset: i64) -> bool {
	remaining := data
	position := offset
	for len(remaining) > 0 {
		n, err := linux.pread(spool.fd, remaining, position)
		if err == .EINTR do continue
		if err != .NONE || n <= 0 do return false
		position += i64(n); remaining = remaining[n:]
	}
	return true
}

@(private)
spill_command_frames :: proc(output: ^Command_Output) -> c.int {
	if !output.spool.open {
		name := fmt.aprintf("%s/.nrc-output-XXXXXX", output.spool_directory); defer delete(name)
		path := strings.clone_to_cstring(name); defer delete(path)
		// mkostemp creates mode 0600; unlink before writing private payloads.
		fd := mkostemp(path, 0x80000) // O_CLOEXEC
		if fd < 0 do return sql.IOERR
		if linux.unlink(path) != .NONE {linux.close(linux.Fd(fd)); return sql.IOERR}
		output.spool = {
			fd   = linux.Fd(fd),
			open = true,
		}
	}
	for frame in output.frames[:output.count] {
		header := Spool_Header{u32(len(frame.payload)), u32(len(frame.private_owner)), frame.scope, frame.audience}
		if !spool_write(&output.spool, ([^]byte)(&header)[:size_of(header)]) ||
		   !spool_write(&output.spool, transmute([]byte)frame.private_owner) ||
		   !spool_write(&output.spool, frame.payload) {return sql.IOERR}
	}
	clear_command_frames(output)
	return sql.OK
}

// Finalize and load the first bounded chunk BEFORE commit. Write/allocation
// failures here roll back mutations and discard every prepared frame.
@(private)
seal_command_output :: proc(output: ^Command_Output) -> c.int {
	if !output.spool.open do return sql.OK
	if rc := spill_command_frames(output); rc != sql.OK do return rc
	for {
		err := linux.fdatasync(output.spool.fd)
		if err == .EINTR do continue
		if err != .NONE do return sql.IOERR
		break
	}
	output.reading = true
	return read_command_chunk(output)
}

@(private)
read_command_chunk :: proc(output: ^Command_Output) -> c.int {
	clear_command_frames(output)
	output.more = false
	for output.spool.offset < output.spool.size {
		header: Spool_Header
		position := output.spool.offset
		if !spool_read(&output.spool, ([^]byte)(&header)[:size_of(header)], position) do return sql.IOERR
		if header.size < 2 ||
		   header.size > pr.MAX_PROTOCOL_PAYLOAD_SIZE ||
		   header.owner > pr.MAX_OWNER_LENGTH ||
		   header.audience < min(Command_Audience) ||
		   header.audience > max(Command_Audience) {return sql.CORRUPT}
		capacity := len(output.frames)
		if output.count == capacity do capacity = max(1, capacity * 2)
		growth := capacity != len(output.frames) ? capacity * size_of(Command_Frame) : 0
		cost := growth + int(header.size) + int(header.owner)
		if cost > output.limit - output.bytes {
			if output.count == 0 do return sql.TOOBIG
			break
		}
		owner: [pr.MAX_OWNER_LENGTH]byte
		position += size_of(header)
		if !spool_read(&output.spool, owner[:header.owner], position) do return sql.IOERR
		position += i64(header.owner)
		body, rc := command_frame(output, int(header.size), header.audience, header.scope, string(owner[:header.owner]))
		if rc != sql.OK do return rc
		if !spool_read(&output.spool, body, position) do return sql.IOERR
		output.spool.offset = position + i64(header.size)
	}
	output.more = output.spool.offset < output.spool.size
	return sql.OK
}
