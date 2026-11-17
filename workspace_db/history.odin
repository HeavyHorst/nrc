package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:c"
import "core:encoding/json"
import "core:fmt"

History_Reference :: struct {
	kind: u8,
	id:   u64,
}

History_Batch :: struct {
	insert:          ^sql.Statement,
	last, remaining: u64,
}

// Reserve consecutive IDs in the caller's transaction. Any failure requires
// rollback, including failure after some events have already been appended.
begin_history_batch :: proc(store: ^Store, workspace: string, count: u64) -> (batch: History_Batch, rc: c.int) {
	if sql.get_autocommit(store.db) != 0 do return {}, sql.MISUSE
	if count == 0 do return {}, sql.OK
	batch.last, rc = reserve_history_ids(store, workspace, count)
	if rc != sql.OK do return
	batch.insert, rc = prepare(store, "INSERT INTO history VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)")
	batch.remaining = count
	return
}

@(private)
reserve_history_ids :: proc(store: ^Store, workspace: string, count: u64) -> (u64, c.int) {
	seed, rc := prepare(store, "INSERT INTO history_sequences VALUES (?1,x'0000000000000000') ON CONFLICT DO NOTHING")
	if rc != sql.OK do return 0, rc
	defer sql.finalize(seed)
	if rc = sql.bind_bytes(seed, 1, transmute([]byte)workspace); rc != sql.OK do return 0, rc
	if rc = sql.step(seed); rc != sql.DONE do return 0, rc
	seq, seq_rc := prepare(store, "SELECT high_water FROM history_sequences WHERE workspace=?1")
	if seq_rc != sql.OK do return 0, seq_rc
	defer sql.finalize(seq)
	if rc = sql.bind_bytes(seq, 1, transmute([]byte)workspace); rc != sql.OK do return 0, rc
	if rc = sql.step(seq); rc != sql.ROW do return 0, rc
	floor, floor_rc := sql.column_id(seq, 0)
	if floor_rc != sql.OK do return 0, floor_rc
	if count > max(u64) - floor do return 0, sql.FULL
	advance, advance_rc := prepare(store, "UPDATE history_sequences SET high_water=?2 WHERE workspace=?1")
	if advance_rc != sql.OK do return 0, advance_rc
	defer sql.finalize(advance)
	if rc = sql.bind_bytes(advance, 1, transmute([]byte)workspace); rc != sql.OK do return 0, rc
	if rc = sql.bind_id(advance, 2, floor + count); rc != sql.OK do return 0, rc
	if rc = sql.step(advance); rc != sql.DONE do return 0, rc
	return floor, sql.OK
}

// History identity and private-owner ACL survive deletion of the record.
// Kinds follow history's Task=1, Asset=2, Edge=3, not Edge.TargetType.
append_history_event :: proc(
	store: ^Store,
	workspace: string,
	event: pr.History_Event,
	entity: History_Reference,
	source: History_Reference = {},
	target: History_Reference = {},
	private_owner := "",
	batch: ^History_Batch = nil,
	appended_id: ^u64 = nil,
) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	batch := batch
	local: History_Batch
	if batch == nil {
		rc: c.int
		local, rc = begin_history_batch(store, workspace, 1)
		if rc != sql.OK do return rc
		batch = &local
	}
	defer if local.insert != nil {sql.finalize(local.insert)}
	assert(batch.remaining > 0)
	batch.last += 1; batch.remaining -= 1
	id := batch.last
	id_text := fmt.aprintf("%d", id); defer delete(id_text)
	owned_event := event
	owned_event.id = id_text
	body, err := json.marshal(owned_event); defer delete(body)
	if err != nil || len(private_owner) > pr.MAX_OWNER_LENGTH || len(body) > 65536 - 37 - len(private_owner) do return sql.TOOBIG
	insert := batch.insert
	rc := sql.reset(insert)
	if rc != sql.OK do return rc
	if rc = sql.bind_bytes(insert, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(insert, 2, id); rc != sql.OK do return rc
	if rc = sql.bind_int64(insert, 3, i64(entity.kind)); rc != sql.OK do return rc
	if rc = sql.bind_id(insert, 4, entity.id); rc != sql.OK do return rc
	if rc = sql.bind_bytes(insert, 5, body); rc != sql.OK do return rc
	if rc = sql.bind_bytes(insert, 6, transmute([]byte)private_owner); rc != sql.OK do return rc
	if rc = sql.bind_int64(insert, 7, i64(source.kind)); rc != sql.OK do return rc
	if rc = sql.bind_id(insert, 8, source.id); rc != sql.OK do return rc
	if rc = sql.bind_int64(insert, 9, i64(target.kind)); rc != sql.OK do return rc
	if rc = sql.bind_id(insert, 10, target.id); rc != sql.OK do return rc
	rc = sql.step(insert)
	if rc == sql.DONE && appended_id != nil do appended_id^ = id
	return rc == sql.DONE ? sql.OK : rc
}
