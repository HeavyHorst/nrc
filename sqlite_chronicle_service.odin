package main

import "core:c"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

CHRONICLE_LEASE :: i64(5 * 60 * 1_000_000_000)
CHRONICLE_DAY :: i64(24 * 60 * 60 * 1_000_000_000)

SQLite_Chronicle_Input :: struct {
	source_id, note_id, captured_at, expires_at, before_version, after_version: string,
	actor_id, actor_name, before_hash, after_hash:                              string,
	operation, attempts:                                                        i64,
	before_present, after_present:                                              bool,
	lengths:                                                                    [6]i64,
}
SQLite_Chronicle_Entry :: struct {
	generation, note_id, created_at, first_at, last_at:         string,
	sources:                                                    []string,
	note_title, summary, model, prompt_version, schema_version: string,
	source_available:                                           bool,
}
SQLite_Chronicle_Gap :: struct {
	first_source, last_source, note_id, first_at, last_at: string,
	note_title, reason:                                    string,
	input_count:                                           i64,
	source_available:                                      bool,
}
SQLite_Chronicle_Response :: struct {
	status:                                                           string,
	error:                                                            string `json:"error,omitempty"`,
	epoch, generation, lease_until, note_id, cursor, deleted_through: string,
	enabled, more:                                                    bool,
	pending, raw_bytes, calls, input_tokens, output_tokens:           i64,
	sources:                                                          []string,
	inputs:                                                           []SQLite_Chronicle_Input,
	entries:                                                          []SQLite_Chronicle_Entry,
	gaps:                                                             []SQLite_Chronicle_Gap,
	can_delete:                                                       bool,
	processing, failed, acknowledged, gap_count, expired:             i64,
	chunk, summary:                                                   string,
}
SQLite_Chronicle_Workspace :: struct {
	enabled:                             bool,
	epoch, disabled, pending, raw_bytes: i64,
	generation:                          u64,
}
SQLite_Chronicle_Job :: struct {
	epoch, lease_until, state, reserved, input_tokens, output_tokens: i64,
	reservation_day:                                                  i64,
	owner, consumer, result_hash, summary:                            string,
}

// Only the authenticated worker can supply Request.chronicle_access. The same
// check is repeated in the executor; client JSON never supplies capabilities.
process_chronicle :: proc(c: ^NRC_Connection, body: []byte) {
	_, correlation, err := pr.parseChronicleEnvelope(body)
	if err != nil {send_error_response(c, .C_Chronicle, "Invalid chronicle envelope", correlation); return}
	worker_db_submit_command(c, .C_Chronicle, body, correlation)
}

sqlite_chronicle_statement :: proc(store: ^db.Store, query: cstring, workspace: string, values: []SQLite_Projection_Value) -> (s: ^sql.Statement, rc: c.int) {
	rc = sql.prepare_v2(store.db, query, -1, &s, nil)
	if rc != sql.OK do return
	rc = sql.bind_bytes(s, 1, transmute([]byte)workspace)
	for value, i in values {
		if rc != sql.OK do break
		switch v in value {
		case string:
			rc = sql.bind_bytes(s, c.int(i + 2), transmute([]byte)v)
		case i64:
			rc = sql.bind_int64(s, c.int(i + 2), v)
		case u64:
			rc = sql.bind_id(s, c.int(i + 2), v)
		}
	}
	if rc != sql.OK {sql.finalize(s); s = nil}
	return
}
sqlite_chronicle_execute :: proc(store: ^db.Store, query: cstring, workspace: string, values: []SQLite_Projection_Value) -> c.int {
	s, rc := sqlite_chronicle_statement(store, query, workspace, values)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	rc = sql.step(s)
	return rc == sql.DONE ? sql.OK : rc
}
sqlite_chronicle_hex :: proc(bytes: []byte) -> string {
	result := make([]byte, len(bytes) * 2)
	digits := "0123456789abcdef"
	for b, i in bytes {result[i * 2] = digits[b >> 4]; result[i * 2 + 1] = digits[b & 15]}
	return string(result)
}
sqlite_chronicle_hash :: proc(bytes: []byte) -> [32]byte {
	h: sha2.Context_256
	sha2.init_256(&h); sha2.update(&h, bytes)
	result: [32]byte
	sha2.final(&h, result[:])
	return result
}
sqlite_chronicle_reply :: proc(output: ^db.Command_Output, correlation: u32, response: SQLite_Chronicle_Response, allocator: mem.Allocator) -> c.int {
	payload, err := json.marshal(response)
	if err != nil do return sql.ERROR
	// Command frames outlive this handler and its scratch arena.
	context.allocator = allocator
	buf, rc := db.command_frame(output, 6 + len(payload))
	if rc != sql.OK do return rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_Chronicle)); endian.put_u32(buf[2:], .Big, correlation)
	copy(buf[6:], payload)
	return sql.OK
}

sqlite_execute_chronicle :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	output_allocator := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	q, correlation, err := pr.parseChronicleRequest(request.body)
	r := SQLite_Chronicle_Response {
		status = "invalid",
	}
	if err != nil do return sqlite_chronicle_reply(output, correlation, r, output_allocator)
	read := q.op == "history" || q.op == "status" || q.op == "gaps"
	needed := read ? pr.CHRONICLE_ACCESS_READ : (q.op == "delete" ? pr.CHRONICLE_ACCESS_DELETE : pr.CHRONICLE_ACCESS_SERVICE)
	if request.chronicle_access & needed == 0 || request.subject == "" {
		r.status = "forbidden"
		return sqlite_chronicle_reply(output, correlation, r, output_allocator)
	}
	if !read && q.op != "delete" && q.consumer != pr.CHRONICLE_CONSUMER_VERSION do return sqlite_chronicle_reply(output, correlation, r, output_allocator)
	// Use trusted execution time, never the worker admission timestamp or JSON.
	now := nrc_time_unix_nanos()
	w: SQLite_Chronicle_Workspace
	s, rc := sqlite_chronicle_statement(
		store,
		`SELECT enabled,epoch,disabled_through_epoch,pending_inputs,raw_bytes,claim_generation
 FROM chronicle_workspaces WHERE workspace=?1`,
		request.workspace,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	rc = sql.step(s)
	if rc != sql.ROW && rc != sql.DONE do return rc
	if rc == sql.ROW {
		w.enabled = sql.column_int64(s, 0) == 1; w.epoch = sql.column_int64(s, 1); w.disabled = sql.column_int64(s, 2)
		w.pending = sql.column_int64(s, 3); w.raw_bytes = sql.column_int64(s, 4)
		w.generation, rc = sql.column_id(s, 5); if rc != sql.OK do return rc
	}
	if rc = sql.reset(s); rc != sql.OK do return rc
	r.epoch = fmt.aprintf("%d", w.epoch); r.enabled = w.enabled; r.pending = w.pending; r.raw_bytes = w.raw_bytes
	switch q.op {
	case "status":
		r.can_delete = request.chronicle_access & pr.CHRONICLE_ACCESS_DELETE != 0
		if rc = sqlite_chronicle_status(store, request.workspace, q, w, now, &r); rc != sql.OK do return rc
		r.status = "ok"
		budget, budget_rc := sqlite_chronicle_statement(
			store,
			"SELECT calls,input_tokens,output_tokens FROM chronicle_budgets WHERE workspace=?1 AND day=?2",
			request.workspace,
			{now / CHRONICLE_DAY},
		)
		if budget_rc != sql.OK do return budget_rc
		defer sql.finalize(budget)
		rc = sql.step(budget)
		if rc ==
		   sql.ROW {r.calls = sql.column_int64(budget, 0); r.input_tokens = sql.column_int64(budget, 1); r.output_tokens = sql.column_int64(budget, 2)} else if rc != sql.DONE do return rc
		rc = sql.OK
	case "history":
		rc = sqlite_chronicle_history(store, request.workspace, q, &r)
	case "gaps":
		rc = sqlite_chronicle_gaps(store, request.workspace, q, &r)
	case "delete":
		if q.note_id == "" || q.note_id == "0" do break
		if w.epoch == 0 {r.status = "deleted"; r.deleted_through = "0"; break}
		rc = sqlite_chronicle_delete(store, request.workspace, q, now, &r)
	case "list", "claim":
		if q.limit == 0 || q.limit > 32 do break
		if !w.enabled {r.status = "disabled"; break}
		if q.op ==
		   "list" {rc = sqlite_chronicle_list(store, request.workspace, q, w, now, &r)} else {rc = sqlite_chronicle_claim(store, request, q, w, now, &r)}
	case "chunk", "reserve", "commit", "retry":
		rc = sqlite_chronicle_job_command(store, request, q, w, now, &r)
	}
	if rc != sql.OK do return rc
	return sqlite_chronicle_reply(output, correlation, r, output_allocator)
}

sqlite_chronicle_list :: proc(
	store: ^db.Store,
	workspace: string,
	q: pr.Chronicle_Request,
	w: SQLite_Chronicle_Workspace,
	now: i64,
	r: ^SQLite_Chronicle_Response,
) -> c.int {
	cursor, _ := strconv.parse_u64(q.cursor)
	s, rc := sqlite_chronicle_statement(
		store,
		`SELECT i.source_id,i.note_id,i.captured_at,i.expires_at,i.before_version,i.after_version,
 i.actor_id,i.actor_name,i.before_hash,i.after_hash,i.operation,i.attempts,i.before_present,i.after_present,
 length(r.before_title),length(r.before_format),length(r.before_body),length(r.after_title),length(r.after_format),length(r.after_body)
 FROM chronicle_inputs i JOIN chronicle_raw r USING(workspace,source_id)
 WHERE i.workspace=?1 AND i.state=0 AND i.source_id>?2 AND i.expires_at>?3 AND i.epoch>?4
 ORDER BY i.source_id LIMIT ?5`,
		workspace,
		{cursor, now, w.disabled, i64(q.limit) + 1},
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	rows := make([dynamic]SQLite_Chronicle_Input)
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if len(rows) == int(q.limit) {r.more = true; break}
		row: SQLite_Chronicle_Input
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		note, note_rc := sql.column_id(s, 1); if note_rc != sql.OK do return note_rc
		row.source_id = fmt.aprintf("%d", id); row.note_id = fmt.aprintf("%d", note)
		row.captured_at = fmt.aprintf("%d", sql.column_int64(s, 2)); row.expires_at = fmt.aprintf("%d", sql.column_int64(s, 3))
		row.before_version = fmt.aprintf("%d", sql.column_int64(s, 4)); row.after_version = fmt.aprintf("%d", sql.column_int64(s, 5))
		row.actor_id = strings.clone(string(sql.column_bytes_view(s, 6))); row.actor_name = strings.clone(string(sql.column_bytes_view(s, 7)))
		row.before_hash = sqlite_chronicle_hex(sql.column_bytes_view(s, 8)); row.after_hash = sqlite_chronicle_hex(sql.column_bytes_view(s, 9))
		row.operation = sql.column_int64(s, 10); row.attempts = sql.column_int64(s, 11)
		row.before_present = sql.column_int64(s, 12) == 1; row.after_present = sql.column_int64(s, 13) == 1
		for &length, i in row.lengths do length = sql.column_int64(s, c.int(14 + i))
		append(&rows, row); r.cursor = row.source_id
	}
	r.inputs = rows[:]; r.status = "ok"
	return sql.OK
}

sqlite_chronicle_claim :: proc(
	store: ^db.Store,
	request: ^db.Request,
	q: pr.Chronicle_Request,
	w: SQLite_Chronicle_Workspace,
	now: i64,
	r: ^SQLite_Chronicle_Response,
) -> c.int {
	if rc := db.cleanup_chronicle_batch(store, now); rc != sql.OK do return rc
	active, rc := sqlite_chronicle_statement(store, "SELECT epoch,lease_until FROM chronicle_jobs WHERE workspace=?1 AND state=0", request.workspace, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(active)
	rc = sql.step(active)
	if rc == sql.ROW && sql.column_int64(active, 0) == w.epoch && sql.column_int64(active, 1) > now {r.status = "busy"; return sql.OK}
	if rc != sql.ROW && rc != sql.DONE do return rc
	if rc = sql.reset(active); rc != sql.OK do return rc
	if rc = sqlite_chronicle_execute(store, "DELETE FROM chronicle_jobs WHERE workspace=?1 AND state=0", request.workspace, nil); rc != sql.OK do return rc
	head, head_rc := sqlite_chronicle_statement(
		store,
		"SELECT note_id FROM chronicle_inputs WHERE workspace=?1 AND state=0 ORDER BY source_id LIMIT 1",
		request.workspace,
		nil,
	)
	if head_rc != sql.OK do return head_rc
	defer sql.finalize(head)
	rc = sql.step(head)
	if rc == sql.DONE {r.status = "empty"; return sql.OK}
	if rc != sql.ROW do return rc
	note, note_rc := sql.column_id(head, 0); if note_rc != sql.OK do return note_rc
	if rc = sql.reset(head); rc != sql.OK do return rc
	if q.note_id != "" && q.note_id != fmt.aprintf("%d", note) do return sql.OK
	s, select_rc := sqlite_chronicle_statement(
		store,
		`SELECT source_id,before_hash,after_hash,captured_at,expires_at,epoch,attempts,retry_at,note_id
 FROM chronicle_inputs WHERE workspace=?1 AND state=0 ORDER BY source_id LIMIT ?2`,
		request.workspace,
		{i64(q.limit)},
	)
	if select_rc != sql.OK do return select_rc
	defer sql.finalize(s)
	sources: [32]struct {
		id:            u64,
		before, after: string,
	}
	count := 0
	lease := min(now, max(i64) - CHRONICLE_LEASE) + CHRONICLE_LEASE
	first_at, last_at := max(i64), min(i64)
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		input_note, input_note_rc := sql.column_id(s, 8)
		if input_note_rc != sql.OK do return input_note_rc
		// A batch is one note's prefix of the global pending order. Never
		// jump over another note's unresolved input to enlarge this batch.
		if input_note != note do break
		if sql.column_int64(s, 4) <= now || sql.column_int64(s, 5) <= w.disabled {r.status = "expired"; break}
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		if sql.column_int64(s, 6) >= 5 {
			// Keep an observable failed input until TTL or authorized deletion;
			// exhausted attempts alone must not turn coverage into a gap.
			r.status = "exhausted"
			break
		}
		if sql.column_int64(s, 7) > now {
			r.status = sql.column_int64(s, 7) == sql.column_int64(s, 4) ? "parked" : "backoff"
			break
		}
		sources[count] = {id, strings.clone(string(sql.column_bytes_view(s, 1))), strings.clone(string(sql.column_bytes_view(s, 2)))}
		count += 1; lease = min(lease, sql.column_int64(s, 4))
		first_at = min(first_at, sql.column_int64(s, 3)); last_at = max(last_at, sql.column_int64(s, 3))
	}
	if rc = sql.reset(s); rc != sql.OK do return rc
	if count == 0 do return sql.OK
	if w.generation == max(u64) do return sql.FULL
	generation := w.generation + 1
	// Length-frame binary hashes directly; JSON's UTF-8 replacement must never
	// make different binary source hashes share an idempotency identity.
	h: sha2.Context_256
	sha2.init_256(&h)
	for value in ([2]string{request.workspace, q.consumer}) {
		length: [8]byte; endian.put_u64(length[:], .Big, u64(len(value)))
		sha2.update(&h, length[:]); sha2.update(&h, transmute([]byte)value)
	}
	for source in sources[:count] {
		id: [8]byte; endian.put_u64(id[:], .Big, source.id); sha2.update(&h, id[:])
		for value in ([2]string{source.before, source.after}) {
			length := [1]byte{byte(len(value))}; sha2.update(&h, length[:]); sha2.update(&h, transmute([]byte)value)
		}
	}
	digest: [32]byte; sha2.final(&h, digest[:])
	if rc = sqlite_chronicle_execute(store, `INSERT INTO chronicle_jobs
 (workspace,generation,note_id,epoch,owner,consumer,lease_until,source_key,created_at,first_at,last_at)
 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)`, request.workspace, {generation, note, w.epoch, request.subject, q.consumer, lease, string(digest[:]), now, first_at, last_at}); rc != sql.OK do return rc
	ids := make([]string, count)
	for source, i in sources[:count] {
		if rc = sqlite_chronicle_execute(store, "INSERT INTO chronicle_job_inputs VALUES(?1,?2,?3,?4,?5,?6)", request.workspace, {generation, i64(i), source.id, source.before, source.after}); rc != sql.OK do return rc
		ids[i] = fmt.aprintf("%d", source.id)
	}
	if rc = sqlite_chronicle_execute(store, "UPDATE chronicle_workspaces SET claim_generation=?2 WHERE workspace=?1", request.workspace, {generation}); rc != sql.OK do return rc
	r.status = "claimed"; r.generation = fmt.aprintf("%d", generation); r.lease_until = fmt.aprintf("%d", lease); r.note_id = fmt.aprintf("%d", note); r.sources = ids
	return sql.OK
}

sqlite_chronicle_job_command :: proc(
	store: ^db.Store,
	request: ^db.Request,
	q: pr.Chronicle_Request,
	w: SQLite_Chronicle_Workspace,
	now: i64,
	r: ^SQLite_Chronicle_Response,
) -> c.int {
	generation, gen_ok := strconv.parse_u64(q.generation)
	epoch, epoch_ok := strconv.parse_i64(q.epoch)
	if !gen_ok || generation == 0 || !epoch_ok || epoch <= 0 do return sql.OK
	s, rc := sqlite_chronicle_statement(
		store,
		`SELECT note_id,epoch,owner,consumer,lease_until,state,reserved,input_tokens,output_tokens,result_hash,summary,reservation_day
 FROM chronicle_jobs WHERE workspace=?1 AND generation=?2`,
		request.workspace,
		{generation},
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	rc = sql.step(s)
	if rc == sql.DONE {r.status = "expired"; return sql.OK}
	if rc != sql.ROW do return rc
	job: SQLite_Chronicle_Job
	_, rc = sql.column_id(s, 0); if rc != sql.OK do return rc
	job.epoch = sql.column_int64(
		s,
		1,
	); job.owner = strings.clone(string(sql.column_bytes_view(s, 2))); job.consumer = strings.clone(string(sql.column_bytes_view(s, 3)))
	job.lease_until = sql.column_int64(s, 4); job.state = sql.column_int64(s, 5); job.reserved = sql.column_int64(s, 6)
	job.input_tokens = sql.column_int64(s, 7); job.output_tokens = sql.column_int64(s, 8)
	job.result_hash = strings.clone(string(sql.column_bytes_view(s, 9))); job.summary = strings.clone(string(sql.column_bytes_view(s, 10)))
	job.reservation_day = sql.column_int64(s, 11)
	if rc = sql.reset(s); rc != sql.OK do return rc
	if job.owner != request.subject || job.consumer != q.consumer || job.epoch != epoch {r.status = "forbidden"; return sql.OK}
	// Deletion wins over fingerprint comparisons and all success replay. No
	// deleted prose is read by this response, even after disable/re-enable.
	if job.state == 3 {r.status = "deleted"; return sql.OK}
	inputs, input_rc := sqlite_chronicle_statement(
		store,
		`SELECT j.source_id,j.before_hash,j.after_hash,i.source_id,i.state,i.expires_at,i.epoch,i.before_hash,i.after_hash,i.attempts
 FROM chronicle_job_inputs j LEFT JOIN chronicle_inputs i ON i.workspace=j.workspace AND i.source_id=j.source_id
 WHERE j.workspace=?1 AND j.generation=?2 ORDER BY j.ordinal`,
		request.workspace,
		{generation},
	)
	if input_rc != sql.OK do return input_rc
	defer sql.finalize(inputs)
	ids: [32]u64
	count, attempts := 0, i64(0)
	eligible := w.enabled && w.epoch == epoch && job.lease_until > now && job.state == 0
	for {
		rc = sql.step(inputs); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if count == len(ids) do return sql.CORRUPT
		ids[count], rc = sql.column_id(inputs, 0); if rc != sql.OK do return rc
		if len(sql.column_bytes_view(inputs, 3)) != 8 ||
		   sql.column_int64(inputs, 4) != 0 ||
		   sql.column_int64(inputs, 5) <= now ||
		   sql.column_int64(inputs, 6) <= w.disabled ||
		   string(sql.column_bytes_view(inputs, 1)) != string(sql.column_bytes_view(inputs, 7)) ||
		   string(sql.column_bytes_view(inputs, 2)) != string(sql.column_bytes_view(inputs, 8)) {
			eligible = false
		}
		attempts = max(attempts, sql.column_int64(inputs, 9)); count += 1
	}
	if rc = sql.reset(inputs); rc != sql.OK do return rc
	if count == 0 do return sql.CORRUPT
	if q.op != "chunk" {
		if len(q.sources) != count do return sql.OK
		for id, i in ids[:count] {if q.sources[i] != fmt.aprintf("%d", id) do return sql.OK}
	}
	// Hash only semantically committed fields, not JSON order, correlation or
	// irrelevant request fields. Source identity is fixed by the immutable job.
	fingerprint: [32]byte
	if q.op == "commit" {
		valid := false
		switch q.outcome {
		case "result":
			valid = len(strings.trim_space(q.summary)) > 0 && q.model != "" && q.prompt_version != "" && q.schema_version != "" && q.reason == ""
		case "ack":
			valid = q.summary == "" && q.model != "" && q.prompt_version != "" && q.schema_version != "" && q.reason == ""
		case "gap":
			valid = count == 1 && q.summary == "" && q.reason == "token_limit" && q.model == "" && q.prompt_version == "" && q.schema_version == ""
		}
		if !valid do return sql.OK
		payload, marshal_err := json.marshal(struct {
			outcome, summary, model, prompt_version, schema_version, reason: string,
			input_tokens, output_tokens:                                     u32,
		}{q.outcome, q.summary, q.model, q.prompt_version, q.schema_version, q.reason, q.input_tokens, q.output_tokens})
		if marshal_err != nil do return sql.ERROR
		fingerprint = sqlite_chronicle_hash(payload)
		if job.state != 0 {
			if job.result_hash != string(fingerprint[:]) {r.status = "conflict"; return sql.OK}
			r.status = job.state == 1 ? "committed" : (job.state == 2 ? "acknowledged" : "gap")
			r.summary = job.summary; r.generation = q.generation
			return sql.OK
		}
	}
	if !eligible {r.status = "expired"; return sql.OK}
	// Zero/zero means unknown usage (including legacy/fake consumers). Partial
	// or over-reservation reports must never release budget or finish the job.
	settle := (q.op == "commit" || q.op == "retry") && (q.input_tokens != 0 || q.output_tokens != 0)
	if settle &&
	   (job.reserved != 1 ||
			   q.input_tokens == 0 ||
			   q.output_tokens == 0 ||
			   i64(q.input_tokens) > job.input_tokens ||
			   i64(q.output_tokens) > job.output_tokens) {
		return sql.OK
	}
	switch q.op {
	case "chunk":
		source, source_ok := strconv.parse_u64(q.cursor)
		member := false; for id in ids[:count] do if source == id do member = true
		if !source_ok || !member || q.field > 5 || q.length == 0 || int(q.length) > db.CHRONICLE_CHUNK_BYTES do return sql.OK
		buffer: [db.CHRONICLE_CHUNK_BYTES]byte
		n, found, chunk_rc := db.read_chronicle_chunk(
			store,
			request.workspace,
			source,
			epoch,
			now,
			db.Chronicle_Raw_Field(q.field),
			int(q.offset),
			buffer[:int(q.length)],
		)
		if chunk_rc != sql.OK do return chunk_rc
		if !found {r.status = "expired"; return sql.OK}
		encoded, encode_err := base64.encode(buffer[:n]); if encode_err != nil do return sql.ERROR
		r.chunk = encoded; r.status = "ok"
	case "reserve":
		if q.input_tokens == 0 || q.input_tokens > 128000 || q.output_tokens != 1000 do return sql.OK
		if job.reserved == 1 {
			r.status = (job.input_tokens == i64(q.input_tokens) && job.output_tokens == i64(q.output_tokens)) ? "reserved" : "conflict"
			return sql.OK
		}
		if attempts >= 5 {r.status = "backoff"; return sql.OK}
		day := now / CHRONICLE_DAY
		if rc = sqlite_chronicle_execute(store, `INSERT INTO chronicle_budgets VALUES(?1,?2,0,0,0)
 ON CONFLICT(workspace) DO UPDATE SET day=excluded.day,calls=0,input_tokens=0,output_tokens=0 WHERE chronicle_budgets.day<excluded.day`, request.workspace, {day}); rc != sql.OK do return rc
		budget, budget_rc := sqlite_chronicle_statement(
			store,
			`UPDATE chronicle_budgets SET calls=calls+1,input_tokens=input_tokens+?3,output_tokens=output_tokens+?4
 WHERE workspace=?1 AND day=?2 AND input_tokens<=8000000-?3 AND output_tokens<=500000-?4 RETURNING calls`,
			request.workspace,
			{day, i64(q.input_tokens), i64(q.output_tokens)},
		)
		if budget_rc != sql.OK do return budget_rc
		defer sql.finalize(budget)
		rc = sql.step(budget)
		if rc == sql.DONE {r.status = "budget"; return sql.OK}
		if rc != sql.ROW do return rc
		if rc = sql.step(budget); rc != sql.DONE do return rc
		for id in ids[:count] {
			if rc = sqlite_chronicle_execute(store, "UPDATE chronicle_inputs SET attempts=attempts+1 WHERE workspace=?1 AND source_id=?2", request.workspace, {id}); rc != sql.OK do return rc
		}
		if rc = sqlite_chronicle_execute(store, "UPDATE chronicle_jobs SET reserved=1,input_tokens=?3,output_tokens=?4,reservation_day=?5 WHERE workspace=?1 AND generation=?2", request.workspace, {generation, i64(q.input_tokens), i64(q.output_tokens), day}); rc != sql.OK do return rc
		r.status = "reserved"
	case "retry":
		if job.reserved == 0 && q.reason != "rebatch" do return sql.OK
		if job.reserved == 1 && q.reason != "temporary" && q.reason != "timeout" && q.reason != "invalid_output" && q.reason != "permanent" do return sql.OK
		if job.reserved == 1 {
			delay := i64(1 << u64(min(attempts, 5))) * 1_000_000_000 + i64(generation % 500) * 1_000_000
			retry_at := min(now, max(i64) - delay) + delay
			if q.reason == "permanent" do retry_at = -1
			for id in ids[:count] {
				// Deterministic provider failures remain pending and visible, but
				// cannot spend more attempts after a service/server restart.
				if rc = sqlite_chronicle_execute(store, "UPDATE chronicle_inputs SET retry_at=CASE WHEN ?3<0 THEN expires_at ELSE ?3 END WHERE workspace=?1 AND source_id=?2", request.workspace, {id, retry_at}); rc != sql.OK do return rc
			}
		}
		if rc = sqlite_chronicle_execute(store, "DELETE FROM chronicle_jobs WHERE workspace=?1 AND generation=?2", request.workspace, {generation}); rc != sql.OK do return rc
		r.status = q.reason == "permanent" ? "parked" : "released"
	case "commit":
		if (q.outcome == "gap") != (job.reserved == 0) do return sql.OK
		state :=
			q.outcome == "result" ? db.Chronicle_Input_State.Processed : (q.outcome == "ack" ? db.Chronicle_Input_State.Acknowledged : db.Chronicle_Input_State.Gap)
		for id in ids[:count] {
			changed, finish_rc := db.finish_chronicle_input(store, request.workspace, id, epoch, now, state, q.reason)
			if finish_rc != sql.OK do return finish_rc
			if !changed do return sql.CONSTRAINT // Roll back the whole result, never a partial Ack.
		}
		job_state := q.outcome == "result" ? i64(1) : (q.outcome == "ack" ? i64(2) : i64(4))
		if rc = sqlite_chronicle_execute(store, `UPDATE chronicle_jobs SET state=?3,result_hash=?4,summary=?5,model=?6,prompt_version=?7,schema_version=?8,created_at=?9
 WHERE workspace=?1 AND generation=?2`, request.workspace, {generation, job_state, string(fingerprint[:]), q.summary, q.model, q.prompt_version, q.schema_version, now}); rc != sql.OK do return rc
		r.status = job_state == 1 ? "committed" : (job_state == 2 ? "acknowledged" : "gap"); r.summary = q.summary; r.generation = q.generation
	}
	if settle {
		// This transaction also terminalizes/removes the job. Replays return
		// above, so they cannot refund twice. Never credit a newer UTC day.
		if rc = sqlite_chronicle_execute(store, `UPDATE chronicle_budgets
 SET input_tokens=input_tokens-?3,output_tokens=output_tokens-?4
 WHERE workspace=?1 AND day=?2`, request.workspace, {job.reservation_day, job.input_tokens - i64(q.input_tokens), job.output_tokens - i64(q.output_tokens)}); rc != sql.OK do return rc
	}
	return sql.OK
}

// Pending is the logically live unresolved total; processing and failed are
// disjoint subsets. A fifth reserved attempt is still processing while leased.
// Reads never run cleanup or expose raw data merely to refresh these counters.
sqlite_chronicle_status :: proc(
	store: ^db.Store,
	workspace: string,
	q: pr.Chronicle_Request,
	w: SQLite_Chronicle_Workspace,
	now: i64,
	r: ^SQLite_Chronicle_Response,
) -> c.int {
	note, _ := strconv.parse_u64(q.note_id)
	s, rc := sqlite_chronicle_statement(
		store,
		`WITH classified AS (
 SELECT i.state,
 (i.expires_at<=?2 OR i.epoch<=?3) AS expired,
 EXISTS(SELECT 1 FROM chronicle_job_inputs ji JOIN chronicle_jobs j USING(workspace,generation)
 WHERE ji.workspace=i.workspace AND ji.source_id=i.source_id AND j.state=0 AND j.epoch=?4 AND j.lease_until>?2) AS active,
 (i.attempts>=5 OR i.retry_at=i.expires_at) AS failed
 FROM chronicle_inputs i WHERE i.workspace=?1 AND (?5=zeroblob(8) OR i.note_id=?5)
 ) SELECT coalesce(sum(state=0 AND NOT expired),0),
 coalesce(sum(state=0 AND NOT expired AND active),0),
 coalesce(sum(state=0 AND NOT expired AND NOT active AND failed),0),
 coalesce(sum(state=2),0),coalesce(sum(state=0 AND expired),0)
 FROM classified`,
		workspace,
		{now, w.disabled, w.epoch, note},
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.step(s); rc != sql.ROW do return rc
	r.pending = sql.column_int64(s, 0); r.processing = sql.column_int64(s, 1)
	r.failed = sql.column_int64(s, 2); r.acknowledged = sql.column_int64(s, 3); r.expired = sql.column_int64(s, 4)
	gaps, gap_rc := sqlite_chronicle_statement(
		store,
		`SELECT coalesce(sum(input_count),0) FROM chronicle_gaps
 WHERE workspace=?1 AND (?2=zeroblob(8) OR note_id=?2)`,
		workspace,
		{note},
	)
	if gap_rc != sql.OK do return gap_rc
	defer sql.finalize(gaps)
	if rc = sql.step(gaps); rc != sql.ROW do return rc
	r.gap_count = sql.column_int64(gaps, 0)
	return sql.OK
}

// Resolve names from metadata in the page transaction, independent of client
// caches. Deleted notes retain only their bounded technical-history label.
sqlite_chronicle_note :: proc(store: ^db.Store, workspace: string, note_id: u64) -> (title: string, available: bool, rc: c.int) {
	s, read_rc := sqlite_chronicle_statement(
		store,
		"SELECT preview FROM assets WHERE workspace=?1 AND id=?2 AND asset_type=?3",
		workspace,
		{note_id, i64(pr.AssetType.Note)},
	)
	if read_rc != sql.OK do return "", false, read_rc
	defer sql.finalize(s)
	rc = sql.step(s)
	if rc == sql.ROW {
		a := pr.Asset {
			asset_type = .Note,
			preview    = sql.column_bytes_view(s, 0),
		}
		title, _ = history_asset_label(&a, context.allocator)
		return title, true, sql.OK
	}
	if rc != sql.DONE do return "", false, rc
	h, history_rc := sqlite_chronicle_statement(
		store,
		`SELECT body FROM history INDEXED BY history_entity
 WHERE workspace=?1 AND entity_kind=2 AND entity_id=?2 AND private_owner=x'' ORDER BY id DESC LIMIT 1`,
		workspace,
		{note_id},
	)
	if history_rc != sql.OK do return "", false, history_rc
	defer sql.finalize(h)
	rc = sql.step(h)
	if rc == sql.DONE do return "", false, sql.OK
	if rc != sql.ROW do return "", false, rc
	event: pr.History_Event
	if json.unmarshal(sql.column_bytes_view(h, 0), &event) != nil do return "", false, sql.CORRUPT
	if event.asset_type == u16(pr.AssetType.Note) do title = pr.history_short_label(event.entity_label, context.allocator)
	return title, false, sql.OK
}

sqlite_chronicle_gaps :: proc(store: ^db.Store, workspace: string, q: pr.Chronicle_Request, r: ^SQLite_Chronicle_Response) -> c.int {
	r.cursor = q.cursor == "" ? "0" : q.cursor
	if q.limit == 0 || q.limit > 16 do return sql.OK
	note, _ := strconv.parse_u64(q.note_id); cursor, _ := strconv.parse_u64(q.cursor)
	query: cstring = `SELECT first_source,last_source,note_id,first_at,last_at,reason,input_count
 FROM chronicle_gaps WHERE workspace=?1 AND first_source>?2 ORDER BY first_source LIMIT ?3`
	values := [3]SQLite_Projection_Value{cursor, i64(q.limit) + 1, note}
	value_count := 2
	if note != 0 {
		query = `SELECT first_source,last_source,note_id,first_at,last_at,reason,input_count
 FROM chronicle_gaps INDEXED BY chronicle_gap_note_order
 WHERE workspace=?1 AND first_source>?2 AND note_id=?4 ORDER BY first_source LIMIT ?3`
		value_count = 3
	}
	s, rc := sqlite_chronicle_statement(store, query, workspace, values[:value_count])
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	rows := make([dynamic]SQLite_Chronicle_Gap)
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if len(rows) == int(q.limit) {r.more = true; break}
		first, first_rc := sql.column_id(s, 0); if first_rc != sql.OK do return first_rc
		last, last_rc := sql.column_id(s, 1); if last_rc != sql.OK do return last_rc
		note_id, note_rc := sql.column_id(s, 2); if note_rc != sql.OK do return note_rc
		row := SQLite_Chronicle_Gap {
			first_source = fmt.aprintf("%d", first),
			last_source  = fmt.aprintf("%d", last),
			note_id      = fmt.aprintf("%d", note_id),
			first_at     = fmt.aprintf("%d", sql.column_int64(s, 3)),
			last_at      = fmt.aprintf("%d", sql.column_int64(s, 4)),
			reason       = strings.clone(string(sql.column_bytes_view(s, 5))),
			input_count  = sql.column_int64(s, 6),
		}
		row.note_title, row.source_available, rc = sqlite_chronicle_note(store, workspace, note_id); if rc != sql.OK do return rc
		append(&rows, row); r.cursor = row.first_source
	}
	r.gaps = rows[:]; r.status = "ok"
	return sql.OK
}

sqlite_chronicle_history :: proc(store: ^db.Store, workspace: string, q: pr.Chronicle_Request, r: ^SQLite_Chronicle_Response) -> c.int {
	r.cursor = q.cursor == "" ? "0" : q.cursor
	if q.limit == 0 || q.limit > 16 do return sql.OK
	note, _ := strconv.parse_u64(q.note_id); cursor, _ := strconv.parse_u64(q.cursor)
	query: cstring = `SELECT generation,note_id,created_at,first_at,last_at,summary,model,prompt_version,schema_version
 FROM chronicle_jobs INDEXED BY chronicle_result_order WHERE workspace=?1 AND state=1 AND generation>?2 ORDER BY generation LIMIT ?3`
	values := [3]SQLite_Projection_Value{cursor, i64(q.limit) + 1, note}
	value_count := 2
	if note != 0 {
		query = `SELECT generation,note_id,created_at,first_at,last_at,summary,model,prompt_version,schema_version
 FROM chronicle_jobs INDEXED BY chronicle_result_note WHERE workspace=?1 AND state=1 AND generation>?2 AND note_id=?4 ORDER BY generation LIMIT ?3`
		value_count = 3
	}
	s, rc := sqlite_chronicle_statement(store, query, workspace, values[:value_count]); if rc != sql.OK do return rc
	defer sql.finalize(s)
	rows := make([dynamic]SQLite_Chronicle_Entry)
	bytes := 1024
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if len(rows) == int(q.limit) {r.more = true; break}
		generation, gen_rc := sql.column_id(s, 0); if gen_rc != sql.OK do return gen_rc
		note_id, note_rc := sql.column_id(s, 1); if note_rc != sql.OK do return note_rc
		entry := SQLite_Chronicle_Entry {
			generation     = fmt.aprintf("%d", generation),
			note_id        = fmt.aprintf("%d", note_id),
			created_at     = fmt.aprintf("%d", sql.column_int64(s, 2)),
			first_at       = fmt.aprintf("%d", sql.column_int64(s, 3)),
			last_at        = fmt.aprintf("%d", sql.column_int64(s, 4)),
			summary        = string(sql.column_bytes_view(s, 5)),
			model          = string(sql.column_bytes_view(s, 6)),
			prompt_version = string(sql.column_bytes_view(s, 7)),
			schema_version = string(sql.column_bytes_view(s, 8)),
		}
		sources, source_rc := sqlite_chronicle_statement(
			store,
			"SELECT source_id FROM chronicle_job_inputs WHERE workspace=?1 AND generation=?2 ORDER BY ordinal",
			workspace,
			{generation},
		)
		if source_rc != sql.OK do return source_rc
		ids := make([dynamic]string)
		for {
			source_rc = sql.step(sources); if source_rc == sql.DONE do break
			if source_rc != sql.ROW {sql.finalize(sources); return source_rc}
			id, id_rc := sql.column_id(sources, 0); if id_rc != sql.OK {sql.finalize(sources); return id_rc}
			append(&ids, fmt.aprintf("%d", id))
		}
		sql.finalize(sources); entry.sources = ids[:]
		entry.note_title, entry.source_available, rc = sqlite_chronicle_note(store, workspace, note_id); if rc != sql.OK do return rc
		encoded, encode_err := json.marshal(entry); if encode_err != nil do return sql.ERROR
		if bytes + len(encoded) > 60000 {r.more = true; break}
		bytes += len(encoded)
		entry.summary = strings.clone(entry.summary); entry.model = strings.clone(entry.model)
		entry.prompt_version = strings.clone(entry.prompt_version); entry.schema_version = strings.clone(entry.schema_version)
		append(&rows, entry); r.cursor = entry.generation
	}
	r.entries = rows[:]; r.status = "ok"
	return sql.OK
}

sqlite_chronicle_delete :: proc(store: ^db.Store, workspace: string, q: pr.Chronicle_Request, now: i64, r: ^SQLite_Chronicle_Response) -> c.int {
	note, _ := strconv.parse_u64(q.note_id)
	s, rc := sqlite_chronicle_statement(store, "SELECT high_water FROM history_sequences WHERE workspace=?1", workspace, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	rc = sql.step(s)
	watermark: u64
	if rc == sql.ROW {watermark, rc = sql.column_id(s, 0); if rc != sql.OK do return rc} else if rc != sql.DONE do return rc
	if rc = sql.reset(s); rc != sql.OK do return rc
	if rc = sqlite_chronicle_execute(store, `INSERT INTO chronicle_deletions VALUES(?1,?2,?3,?4)
 ON CONFLICT(workspace,note_id) DO UPDATE SET through_source=max(chronicle_deletions.through_source,excluded.through_source),deleted_at=excluded.deleted_at`, workspace, {note, watermark, now}); rc != sql.OK do return rc
	if rc = sqlite_chronicle_execute(store, `UPDATE chronicle_jobs SET state=3,summary=x'',model=x'',prompt_version=x'',schema_version=x''
 WHERE workspace=?1 AND note_id=?2`, workspace, {note}); rc != sql.OK do return rc
	if rc = sqlite_chronicle_execute(store, "UPDATE chronicle_inputs SET state=4,reason=x'64656c65746564' WHERE workspace=?1 AND note_id=?2 AND state=0 AND source_id<=?3", workspace, {note, watermark}); rc != sql.OK do return rc
	if rc = sqlite_chronicle_execute(store, "DELETE FROM chronicle_inputs WHERE workspace=?1 AND note_id=?2 AND state=4 AND source_id<=?3", workspace, {note, watermark}); rc != sql.OK do return rc
	r.status = "deleted"; r.deleted_through = fmt.aprintf("%d", watermark)
	return sql.OK
}
