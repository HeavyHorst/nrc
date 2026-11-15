package main

import "core:c"
import "core:encoding/endian"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_dm_error :: proc(output: ^db.Command_Output, correlation: u32, code: pr.DM_Error_Code, target, text: string) -> c.int {
	buf, rc := db.command_frame(output, pr.dm_error_size(target, text))
	if rc != sql.OK do return rc
	pr.write_dm_error(buf, code, target, text, correlation)
	return sql.OK
}

// Reserve both the owned result and the worker's eventual wire/list storage.
// No membership cache or unbounded list is built on the executor.
sqlite_dm_capacity :: proc(output: ^db.Command_Output) -> int {
	header := pr.dm_list_header_size() + pr.dm_left_size() + pr.dm_started_size("")
	available := min(output.limit, pr.MAX_PROTOCOL_PAYLOAD_SIZE) - output.bytes
	if available < header do return -1
	return min(65535, (available - header) / (size_of(db.DM_State) + size_of(pr.DMEntry)))
}

sqlite_dm_reserve :: proc(output: ^db.Command_Output, count: int) -> c.int {
	if count < 0 || count > sqlite_dm_capacity(output) do return sql.TOOBIG
	header := pr.dm_list_header_size() + pr.dm_left_size() + pr.dm_started_size("")
	states, err := make([]db.DM_State, count)
	if err != .None do return sql.NOMEM
	output.dm_states = states
	output.bytes += header + count * (size_of(db.DM_State) + size_of(pr.DMEntry))
	return sql.OK
}

sqlite_dm_copy :: proc(output: ^db.Command_Output, index: int, state: db.DM_State) -> c.int {
	cost := len(state.user_a) + len(state.user_b) + pr.dm_entry_size(state.user_a) + pr.dm_entry_size(state.user_b)
	if cost > min(output.limit, pr.MAX_PROTOCOL_PAYLOAD_SIZE) - output.bytes do return sql.TOOBIG
	owned := &output.dm_states[index]
	owned^ = state; owned.user_a = ""; owned.user_b = ""
	a, err := strings.clone(state.user_a); if err != .None do return sql.NOMEM
	owned.user_a = a
	owned.user_b, err = strings.clone(state.user_b); if err != .None do return sql.NOMEM
	output.bytes += cost
	return sql.OK
}

sqlite_dm_row :: proc(s: ^sql.Statement) -> (state: db.DM_State, rc: c.int) {
	state.id, rc = sql.column_id(s, 0); if rc != sql.OK do return
	state.user_a = string(sql.column_bytes_view(s, 1)); state.user_b = string(sql.column_bytes_view(s, 2))
	state.members = u8(sql.column_int64(s, 3)); state.previous_members = state.members
	if state.user_a == "" || state.user_a >= state.user_b || len(state.user_a) + 1 + len(state.user_b) > 512 || state.members > 3 || state.id != pr.make_dm_conversation_id(state.user_a, state.user_b) do return state, sql.CORRUPT
	return state, sql.OK
}

sqlite_execute_dm :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	if request.opcode == .C_ListDMs do return sqlite_list_dms(store, request, output)
	correlation: u32
	target: string
	state: db.DM_State
	if request.opcode == .C_StartDM {
		r, err := pr.parseStartDMRequest(request.body); if err != nil do return sql.CONSTRAINT
		correlation = r.correlation_id; target = r.username
		if target == request.actor do return sqlite_dm_error(output, correlation, .Cannot_DM_Self, target, "Cannot start DM with yourself")
		if request.actor == "" || target == "" || len(request.actor) + 1 + len(target) > 512 do return sqlite_dm_error(output, correlation, .User_Not_Found, target, "Invalid DM identity")
		state.user_a, state.user_b = request.actor, target
		if state.user_a > state.user_b do state.user_a, state.user_b = state.user_b, state.user_a
		state.id = pr.make_dm_conversation_id(state.user_a, state.user_b)
	} else {
		r, err := pr.parseLeaveDMRequest(request.body); if err != nil do return sql.CONSTRAINT
		correlation = r.correlation_id; state.id = r.conv_id
		if !pr.is_dm_conversation(state.id) do return sqlite_dm_error(output, correlation, .DM_Not_Found, "", "Not a DM conversation")
	}
	if rc := sqlite_dm_reserve(output, 1); rc != sql.OK do return rc
	found := false
	{
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT id,user_a,user_b,members FROM dm_conversations WHERE workspace=?1 AND id=?2", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, state.id); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc == sql.ROW {
			stored, read_rc := sqlite_dm_row(s); if read_rc != sql.OK do return read_rc
			if request.opcode == .C_StartDM && (stored.user_a != state.user_a || stored.user_b != state.user_b) do return sqlite_dm_error(output, correlation, .DM_Not_Found, target, "DM identity conflict")
			if rc = sqlite_dm_copy(output, 0, stored); rc != sql.OK do return rc
			state = output.dm_states[0]; found = true
		} else if rc != sql.DONE {return rc}
	}
	if request.opcode == .C_StartDM {
		if !found && !request.dm_target_online do return sqlite_dm_error(output, correlation, .User_Not_Found, target, "User not found")
		state.members = 3
	} else {
		bit := request.actor == state.user_a ? u8(1) : (request.actor == state.user_b ? u8(2) : u8(0))
		if !found || bit == 0 || state.members & bit == 0 do return sqlite_dm_error(output, correlation, .DM_Not_Found, "", "Not in this DM")
		state.members &= ~bit
	}
	if !found {if rc := sqlite_dm_copy(output, 0, state); rc != sql.OK do return rc}
	output.dm_states[0].members = state.members
	s: ^sql.Statement
	rc := sql.prepare_v2(
		store.db,
		"INSERT INTO dm_conversations VALUES(?1,?2,?3,?4,?5) ON CONFLICT(workspace,id) DO UPDATE SET members=excluded.members",
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, state.id); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 3, transmute([]byte)state.user_a); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 4, transmute([]byte)state.user_b); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 5, i64(state.members)); rc != sql.OK do return rc
	rc = sql.step(s)
	return rc == sql.DONE ? sql.OK : rc
}

sqlite_list_dms :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	r, err := pr.parseListDMsRequest(request.body); if err != nil do return sql.CONSTRAINT
	query :: `SELECT id,user_a,user_b,members FROM dm_conversations INDEXED BY dm_user_a WHERE workspace=?1 AND user_a=?2 AND (members & 1)!=0
 UNION ALL SELECT id,user_a,user_b,members FROM dm_conversations INDEXED BY dm_user_b WHERE workspace=?1 AND user_b=?2 AND (members & 2)!=0`
	count: int
	capacity := sqlite_dm_capacity(output)
	if capacity < 0 do return sql.TOOBIG
	{
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT count(*) FROM (" + query + " LIMIT ?3)", -1, &s, nil); if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 2, transmute([]byte)request.actor); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 3, i64(capacity + 1)); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.ROW do return rc
		count = int(sql.column_int64(s, 0))
	}
	if rc := sqlite_dm_reserve(output, count); rc != sql.OK do return rc
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query + " ORDER BY id", -1, &s, nil); if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 2, transmute([]byte)request.actor); rc != sql.OK do return rc
	for i in 0 ..< count {
		if rc = sql.step(s); rc != sql.ROW do return rc == sql.DONE ? sql.CORRUPT : rc
		state, read_rc := sqlite_dm_row(s); if read_rc != sql.OK do return read_rc
		if rc = sqlite_dm_copy(output, i, state); rc != sql.OK do return rc
	}
	_ = r
	return sql.OK
}

// Copy parser TLS slices before returning. Only requested DM IDs cross the
// authorization boundary; public conversations keep their existing path.
sqlite_dm_access_ids :: proc(opcode: pr.Opcode, body: []byte, buffer: []u64) -> (ids: []u64, correlation: u32, valid: bool) {
	n := 0
	single: u64
	#partial switch opcode {
	case .C_SendMessage:
		r, e := pr.parseSendMessageRequest(body); if e != nil do return
		single = r.conv_id; correlation = r.client_req_id
	case .C_SendMessageV2:
		r, e := pr.parseSendMessageV2Request(body); if e != nil do return
		single = r.conv_id; correlation = r.correlation_id
	case .C_ListMessagesBefore, .C_ReplayMessagesAfter:
		r, e := pr.parseMessageRangeRequest(body); if e != nil do return
		single = r.conv_id; correlation = r.correlation_id
	case .C_SubscribeConvs, .C_UnsubscribeConvs:
		r, e := pr.parseSubscribeConvsRequest(body); if e != nil do return
		for id in r.conv_ids {if pr.is_dm_conversation(id) {buffer[n] = id; n += 1}}
	case .C_SubscribeConvsV2:
		r, e := pr.parseSubscribeConvsV2Request(body); if e != nil do return
		correlation = r.correlation_id
		for id in r.conv_ids {if pr.is_dm_conversation(id) {buffer[n] = id; n += 1}}
	case:
		return
	}
	if pr.is_dm_conversation(single) {buffer[n] = single; n += 1}
	return buffer[:n], correlation, true
}

sqlite_authorize_dm_request :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	buffer: [pr.MAX_SUBSCRIBE_CONVS]u64
	ids, correlation, valid := sqlite_dm_access_ids(request.opcode, request.body, buffer[:])
	if !valid || len(ids) == 0 do return sql.CONSTRAINT
	// Unsubscribe carries no private data, but must not overtake queued subscribe.
	if request.opcode == .C_UnsubscribeConvs do return sql.OK
	if rc := sqlite_dm_reserve(output, len(ids)); rc != sql.OK do return rc
	for id, i in ids {
		s: ^sql.Statement
		rc := sql.prepare_v2(
			store.db,
			"SELECT id,user_a,user_b,members FROM dm_conversations WHERE workspace=?1 AND id=?2 AND ((user_a=?3 AND (members & 1)!=0) OR (user_b=?3 AND (members & 2)!=0))",
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, id); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 3, transmute([]byte)request.actor); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc == sql.DONE {
			// V1 subscribes each allowed room independently; V2 is all-or-nothing.
			if request.opcode == .C_SubscribeConvs {output.dm_states[i].id = id; continue}
			return sqlite_command_error(output, request.opcode, correlation, "DM access denied")
		}
		if rc != sql.ROW do return rc
		state, read_rc := sqlite_dm_row(s); if read_rc != sql.OK do return read_rc
		if rc = sqlite_dm_copy(output, i, state); rc != sql.OK do return rc
	}
	return sql.OK
}

worker_db_defer_dm_access :: proc(c: ^NRC_Connection, opcode: pr.Opcode, body: []byte) -> bool {
	if td.database.port == nil || td.database.port.executor.command_handler == nil do return false
	buffer: [pr.MAX_SUBSCRIBE_CONVS]u64
	ids, correlation, valid := sqlite_dm_access_ids(opcode, body, buffer[:])
	if !valid || len(ids) == 0 do return false
	if get_connection_username(c) == "" {send_error_response(c, opcode, "DM access denied", correlation); return true}
	request := db.Request {
		operation = .Command,
		shard     = int(shard_for_workspace(transmute([]byte)c.workspace_id)),
		opcode    = opcode,
		body      = body,
	}
	admission_error: string
	if !worker_db_submit(c, request, correlation, worker_db_complete_dm_access, &admission_error) do send_error_response(c, opcode, admission_error, correlation)
	return true
}

worker_db_apply_dm_state :: proc(ws: ^Workspace_State, state: db.DM_State) {
	conv := get_or_create_conversation(ws, state.id)
	if conv.dm_participants == nil {
		conv.dm_participants = new(DM_Participants)
		conv.dm_participants.user_a = strings.clone(state.user_a)
		conv.dm_participants.user_b = strings.clone(state.user_b)
		conv.dm_participants.owned_names = true
	}
	pair := conv.dm_participants
	worker_db_mark_dm(ws, state.id)
	pair.persistent = true
	for name, bit in ([2]string{pair.user_a, pair.user_b}) {
		if state.members & (u8(1) << uint(bit)) != 0 {add_user_dm(ws, name, state.id)} else {remove_user_dm(ws, name, state.id)}
	}
}

worker_db_complete_dm_access :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	// The bridge has rechecked the handle generation and complete identity.
	if c == nil do return
	if job.result.status != sql.OK {send_error_response(c, job.request.opcode, "Failed to authorize DM request", correlation); return}
	if job.result.command.count != 0 {worker_db_complete_command(c, correlation, job); return}
	ws := get_or_create_connection_workspace(c)
	for state in job.result.command.dm_states {
		if state.user_a == "" {remove_user_dm(ws, job.request.actor, state.id)} else {worker_db_apply_dm_state(ws, state)}
	}
	packet := make([]byte, 2 + len(job.request.body)); defer delete(packet)
	endian.put_u16(packet, .Big, u16(job.request.opcode)); copy(packet[2:], job.request.body)
	process_protocol_payload(c, packet, dm_authorized = true)
}

worker_db_submit_dm :: proc(c: ^NRC_Connection, opcode: pr.Opcode, body: []byte, correlation: u32, target := "") {
	if get_connection_username(c) == "" {send_dm_error(c, .Not_Authenticated, target, "Not authenticated", correlation); return}
	ws := get_or_create_connection_workspace(c)
	request := db.Request {
		operation        = .Command,
		shard            = int(shard_for_workspace(transmute([]byte)c.workspace_id)),
		opcode           = opcode,
		body             = body,
		dm_target_online = find_user_in_workspace(ws, target),
	}
	admission_error: string
	if !worker_db_submit(c, request, correlation, worker_db_complete_dm, &admission_error) do send_dm_error(c, .DM_Not_Found, target, admission_error, correlation)
}

worker_db_complete_dm :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	if job.result.status != sql.OK {
		if c != nil do send_dm_error(c, .DM_Not_Found, "", job.result.status == sql.TOOBIG ? "DM list exceeds response limit" : "Failed to access DMs", correlation)
		return
	}
	if job.result.command.count != 0 {worker_db_complete_command(c, correlation, job); return} 	// Domain rejection, no membership changes.
	if td.database.stopping do return
	if job.request.opcode == .C_ListDMs && c == nil do return
	ws := get_or_create_workspace(job.request.workspace)
	actor := job.request.actor
	entries := make([]pr.DMEntry, len(job.result.command.dm_states)); defer delete(entries)
	for state, i in job.result.command.dm_states {
		worker_db_apply_dm_state(ws, state)
		partner := actor == state.user_a ? state.user_b : state.user_a
		if job.request.opcode == .C_ListDMs {
			subscribe_to_dm_internal(c, state.id)
			entries[i] = {state.id, partner, is_user_authenticated(ws, partner), is_user_online(ws, partner), ws.user_last_seen[partner]}
			continue
		}
		my_sockets := get_user_sockets(ws, actor); defer delete(my_sockets)
		for sock in my_sockets {
			conn := connection_get(sock); if conn == nil do continue
			corr := c != nil && conn == c ? correlation : u32(0)
			if job.request.opcode == .C_LeaveDM {
				unsubscribe_from_dm_internal(conn, state.id)
				send_dm_left(conn, state.id, corr)
			} else {
				subscribe_to_dm_internal(conn, state.id)
				send_dm_started(conn, state.id, partner, is_user_authenticated(ws, partner), is_user_online(ws, partner), true, corr)
			}
		}
		if job.request.opcode == .C_StartDM {
			partner_sockets := get_user_sockets(ws, partner); defer delete(partner_sockets)
			already := state.previous_members & (partner == state.user_a ? u8(1) : u8(2)) != 0
			for sock in partner_sockets {
				conn := connection_get(sock); if conn == nil do continue
				subscribe_to_dm_internal(conn, state.id)
				if !already do send_dm_started(conn, state.id, actor, is_user_authenticated(ws, actor), is_user_online(ws, actor), false)
			}
		}
	}
	if job.request.opcode == .C_ListDMs do send_dm_list(c, entries, correlation)
}
