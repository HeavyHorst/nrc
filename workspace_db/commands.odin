package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:c"

// Domain code runs on the executor inside one transaction. It receives owned
// request bytes and immutable identity, never a connection or worker pointer.
Command_Handler :: #type proc(store: ^Store, request: ^Request, output: ^Command_Output) -> c.int
Command_Audience :: enum {
	Requester,
	Subscribers,
	Other_Subscribers,
}
Command_Frame :: struct {
	audience:      Command_Audience,
	scope:         u64,
	private_owner: string,
	payload:       []byte,
}
Ticket_Read_Cursor :: struct {
	id, through: u64,
}

DM_State :: struct {
	id:                        u64,
	user_a, user_b:            string,
	members, previous_members: u8,
}

Command_Output :: struct {
	frames:              []Command_Frame,
	count, bytes, limit: int,
	spool_directory:     string, // Borrowed executor path; empty for memory-only callers.
	spool:               Command_Spool,
	reading, more:       bool,
	ticket_reads:        []Ticket_Read_Cursor, // Internal upload result, never a wire frame.
	dm_states:           []DM_State, // Committed membership snapshots for the owning worker.
}

// Reserve output before serialization/commit. Serialize before requesting the
// next frame: spilling may release previous buffers. RAM stays within admission
// credit; larger outputs spill on the executor, never on the network worker.
command_frame :: proc(
	output: ^Command_Output,
	size: int,
	audience := Command_Audience.Requester,
	scope: u64 = 0,
	private_owner := "",
) -> (
	payload: []byte,
	rc: c.int,
) {
	if size < 2 || size > pr.MAX_PROTOCOL_PAYLOAD_SIZE || len(private_owner) > pr.MAX_OWNER_LENGTH do return nil, sql.TOOBIG
	capacity := len(output.frames)
	if output.count == capacity do capacity = max(1, capacity * 2)
	extra := (capacity - len(output.frames)) * size_of(Command_Frame)
	// Growth keeps the old array alive until the new array has been copied.
	growth := capacity != len(output.frames) ? capacity * size_of(Command_Frame) : 0
	if growth > output.limit - output.bytes ||
	   size > output.limit - output.bytes - growth ||
	   len(private_owner) > output.limit - output.bytes - growth - size {
		if output.reading || output.spool_directory == "" || output.count == 0 do return nil, sql.TOOBIG
		if rc = spill_command_frames(output); rc != sql.OK do return nil, rc
		return command_frame(output, size, audience, scope, private_owner)
	}
	if capacity != len(output.frames) {
		grown, err := make([]Command_Frame, capacity)
		if err != nil do return nil, sql.NOMEM
		copy(grown, output.frames)
		delete(output.frames)
		output.frames = grown
		output.bytes += extra
	}
	frame := &output.frames[output.count]
	body, err := make([]byte, size)
	if err != nil do return nil, sql.NOMEM
	owner, owner_err := clone_bytes(transmute([]byte)private_owner)
	if owner_err != nil {delete(body); return nil, sql.NOMEM}
	frame^ = {audience, scope, string(owner), body}
	output.count += 1
	output.bytes += size + len(private_owner)
	return body, sql.OK
}

destroy_command_output :: proc(output: ^Command_Output) {
	close_command_spool(output)
	delete(output.ticket_reads)
	for state in output.dm_states {delete(state.user_a); delete(state.user_b)}
	delete(output.dm_states)
	clear_command_frames(output)
	output^ = {}
}

@(private)
clear_command_frames :: proc(output: ^Command_Output) {
	for frame in output.frames[:output.count] {
		output.bytes -= len(frame.payload) + len(frame.private_owner)
		delete(frame.payload); delete(frame.private_owner)
	}
	output.bytes -= len(output.frames) * size_of(Command_Frame)
	delete(output.frames); output.frames = nil; output.count = 0
}
