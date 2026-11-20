package workspace_db

import sql "../sqlite"
import "core:c"
import "core:strings"

// Operator configuration, once per shard at server startup before executors
// open their handles. The caller holds the data-directory lock and transaction.
// No backfill. Pending inputs survive enabled restarts, but no old claim epoch
// can publish. Disable fences all old inputs immediately; raw cleanup is bounded.
configure_chronicle :: proc(store: ^Store, enabled_workspaces: []string) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	rc := execute(store, "UPDATE chronicle_workspaces SET epoch=epoch+1,enabled=0")
	if rc != sql.OK do return rc
	s, prepare_rc := prepare(store, `INSERT INTO chronicle_workspaces(workspace,enabled,epoch) VALUES(?1,1,1)
 ON CONFLICT(workspace) DO UPDATE SET enabled=1`)
	if prepare_rc != sql.OK do return prepare_rc
	defer sql.finalize(s)
	for workspace in enabled_workspaces {
		if rc = sql.reset(s); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.DONE do return rc
	}
	rc = execute(store, "UPDATE chronicle_workspaces SET disabled_through_epoch=epoch WHERE enabled=0")
	if rc != sql.OK do return rc
	return cleanup_chronicle_batch(store, min(i64))
}

// Missing configuration is disabled. Read within the canonical write's same
// transaction so quota/epoch cannot change between checking and capture.
chronicle_workspace :: proc(store: ^Store, workspace: string) -> (epoch, available, input_slots: i64, enabled: bool, rc: c.int) {
	s: ^sql.Statement
	s, rc = prepare(store, "SELECT epoch,raw_limit-raw_bytes,input_limit-pending_inputs,enabled FROM chronicle_workspaces WHERE workspace=?1")
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return 0, 0, 0, false, sql.OK
	if rc != sql.ROW do return
	return sql.column_int64(s, 0), sql.column_int64(s, 1), sql.column_int64(s, 2), sql.column_int64(s, 3) == 1, sql.OK
}

CHRONICLE_CLEANUP_BATCH :: 128
CHRONICLE_CHUNK_BYTES :: 16 * 1024
CHRONICLE_GAP_RANGE_INPUTS :: 4096
CHRONICLE_WINDOW :: 10

// Completion and publication share the caller's writer transaction. Accepted
// results need no raw data, live lease, current claim epoch or enabled capture.
// Maintenance must publish them too when expiry/disable removes an earlier
// blocker, even if no sidecar is running. Only the ten-slot ready window is read.
publish_chronicle :: proc(store: ^Store, workspace: string) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	ready, rc := prepare(
		store,
		`SELECT j.generation,ji.source_id,w.publication_generation
 FROM chronicle_jobs j INDEXED BY chronicle_pending_publication
 CROSS JOIN chronicle_job_inputs ji USING(workspace,generation)
 JOIN chronicle_workspaces w USING(workspace)
 WHERE j.workspace=?1 AND j.state IN(1,2,4) AND j.publication_generation IS NULL AND ji.ordinal=0
 ORDER BY ji.source_id LIMIT 1`,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(ready)
	if rc = sql.bind_bytes(ready, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	head, head_rc := prepare(store, "SELECT 1 FROM chronicle_inputs WHERE workspace=?1 AND state=0 AND source_id<?2 LIMIT 1")
	if head_rc != sql.OK do return head_rc
	defer sql.finalize(head)
	result, result_rc := prepare(store, "UPDATE chronicle_jobs SET publication_generation=?3 WHERE workspace=?1 AND generation=?2")
	if result_rc != sql.OK do return result_rc
	defer sql.finalize(result)
	floor, floor_rc := prepare(store, "UPDATE chronicle_workspaces SET publication_generation=?2 WHERE workspace=?1")
	if floor_rc != sql.OK do return floor_rc
	defer sql.finalize(floor)
	for _ in 0 ..< CHRONICLE_WINDOW {
		rc = sql.step(ready)
		if rc == sql.DONE do return sql.OK
		if rc != sql.ROW do return rc
		generation, gen_rc := sql.column_id(ready, 0)
		first, first_rc := sql.column_id(ready, 1)
		publication, pub_rc := sql.column_id(ready, 2)
		if gen_rc != sql.OK do return gen_rc
		if first_rc != sql.OK do return first_rc
		if pub_rc != sql.OK do return pub_rc
		if rc = sql.reset(ready); rc != sql.OK do return rc
		if rc = bind_task_key(head, workspace, first); rc != sql.OK do return rc
		rc = sql.step(head)
		if rc == sql.ROW do return sql.OK
		if rc != sql.DONE do return rc
		if rc = sql.reset(head); rc != sql.OK do return rc
		if publication == max(u64) do return sql.FULL
		publication += 1
		if rc = bind_task_key(result, workspace, generation); rc != sql.OK do return rc
		if rc = sql.bind_id(result, 3, publication); rc != sql.OK do return rc
		if rc = sql.step(result); rc != sql.DONE do return rc
		if rc = sql.reset(result); rc != sql.OK do return rc
		if rc = bind_task_key(floor, workspace, publication); rc != sql.OK do return rc
		if rc = sql.step(floor); rc != sql.DONE do return rc
		if rc = sql.reset(floor); rc != sql.OK do return rc
	}
	return sql.OK
}

Chronicle_Input_State :: enum i64 {
	Pending,
	Processed,
	Acknowledged,
	Gap,
	Suppressed,
}

Chronicle_Raw_Field :: enum {
	Before_Title,
	Before_Format,
	Before_Body,
	After_Title,
	After_Format,
	After_Body,
}

// Internal storage operations, not authorization boundaries. The service API
// must validate its capability and claim before using these in its transaction.
// now is server wall time at execution, not admission or a service timestamp.
// A held SQLite snapshot or an already returned chunk cannot be revoked.
read_chronicle_chunk :: proc(
	store: ^Store,
	workspace: string,
	source_id: u64,
	epoch, now: i64,
	field: Chronicle_Raw_Field,
	offset: int,
	buffer: []byte,
) -> (
	n: int,
	found: bool,
	rc: c.int,
) {
	if sql.get_autocommit(store.db) != 0 || offset < 0 || len(buffer) == 0 || len(buffer) > CHRONICLE_CHUNK_BYTES do return 0, false, sql.MISUSE
	s: ^sql.Statement
	s, rc = prepare(
		store,
		`SELECT substr(CASE ?7
 WHEN 0 THEN r.before_title WHEN 1 THEN r.before_format WHEN 2 THEN r.before_body
 WHEN 3 THEN r.after_title WHEN 4 THEN r.after_format WHEN 5 THEN r.after_body END,?5+1,?6)
 FROM chronicle_inputs i JOIN chronicle_workspaces w USING(workspace)
 JOIN chronicle_raw r USING(workspace,source_id)
 WHERE i.workspace=?1 AND i.source_id=?2 AND w.enabled=1 AND w.epoch=?3
 AND i.state=0 AND i.expires_at>?4 AND i.epoch>w.disabled_through_epoch`,
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_id(s, 2, source_id); rc != sql.OK do return
	for value, i in ([4]i64{epoch, now, i64(offset), i64(len(buffer))}) {
		if rc = sql.bind_int64(s, c.int(i + 3), value); rc != sql.OK do return
	}
	if rc = sql.bind_int64(s, 7, i64(field)); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return 0, false, sql.OK
	if rc != sql.ROW do return
	return copy(buffer, sql.column_bytes_view(s, 0)), true, sql.OK
}

// Result insertion/receipt and this transition belong to one transaction.
// False means no publish is allowed (expired, terminal, disabled, or fenced).
// The raw-delete trigger runs before commit, so rollback restores accounting.
finish_chronicle_input :: proc(
	store: ^Store,
	workspace: string,
	source_id: u64,
	epoch, now: i64,
	state: Chronicle_Input_State,
	reason := "",
) -> (
	changed: bool,
	rc: c.int,
) {
	if store.read_only ||
	   sql.get_autocommit(store.db) != 0 ||
	   state == .Pending ||
	   len(reason) > 64 ||
	   ((state == .Gap || state == .Suppressed) != (len(reason) > 0)) {
		return false, sql.MISUSE
	}
	s: ^sql.Statement
	s, rc = prepare(
		store,
		`UPDATE chronicle_inputs SET state=?5,reason=?6
 WHERE workspace=?1 AND source_id=?2 AND state=0 AND expires_at>?4
 AND EXISTS(SELECT 1 FROM chronicle_workspaces w WHERE w.workspace=?1 AND w.enabled=1
 AND w.epoch=?3 AND chronicle_inputs.epoch>w.disabled_through_epoch)
 RETURNING source_id`,
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_id(s, 2, source_id); rc != sql.OK do return
	for value, i in ([3]i64{epoch, now, i64(state)}) {
		if rc = sql.bind_int64(s, c.int(i + 3), value); rc != sql.OK do return
	}
	if rc = sql.bind_bytes(s, 6, transmute([]byte)reason); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return false, sql.OK
	if rc != sql.ROW do return
	rc = sql.step(s)
	if rc != sql.DONE do return false, rc
	if state == .Gap {
		if rc = compact_chronicle_gap(store, workspace, source_id); rc != sql.OK do return false, rc
	}
	return true, sql.OK
}

// One bounded, indexed writer transaction across all workspaces of this shard.
// Preserve source identity and terminal state; never delete history or ID floors.
// Cleanup latency must not be used as the eligibility check above.
cleanup_chronicle :: proc(store: ^Store, now: i64) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) == 0 do return sql.MISUSE
	rc := begin(store)
	if rc != sql.OK do return rc
	defer if sql.get_autocommit(store.db) == 0 {
		if rollback(store) != sql.OK {close_rc := close(store); assert(close_rc == sql.OK)}
	}
	if rc = cleanup_chronicle_batch(store, now); rc != sql.OK do return rc
	return commit(store)
}

// Also used inside the service command's writer transaction before claiming.
cleanup_chronicle_batch :: proc(store: ^Store, now: i64) -> c.int {
	s, prepare_rc := prepare(
		store,
		`WITH RECURSIVE pending(workspace) AS (
 SELECT min(workspace) FROM chronicle_inputs INDEXED BY chronicle_pending_epoch WHERE state=0
 UNION ALL SELECT (SELECT min(i.workspace) FROM chronicle_inputs i INDEXED BY chronicle_pending_epoch
 WHERE i.state=0 AND i.workspace>p.workspace) FROM pending p WHERE p.workspace IS NOT NULL)
 SELECT workspace,source_id FROM
   (SELECT i.workspace,i.source_id FROM pending p CROSS JOIN chronicle_workspaces w
    CROSS JOIN chronicle_inputs i INDEXED BY chronicle_pending_epoch
    WHERE w.workspace=p.workspace AND i.workspace=w.workspace AND i.state=0 AND i.epoch<=w.disabled_through_epoch LIMIT ?2)
  UNION ALL SELECT workspace,source_id FROM
   (SELECT workspace,source_id FROM chronicle_inputs INDEXED BY chronicle_expiry
    WHERE state=0 AND expires_at<=?1 ORDER BY expires_at,workspace,source_id LIMIT ?2)
  LIMIT ?2`,
	)
	if prepare_rc != sql.OK do return prepare_rc
	defer sql.finalize(s)
	if rc := sql.bind_int64(s, 1, now); rc != sql.OK do return rc
	if rc := sql.bind_int64(s, 2, CHRONICLE_CLEANUP_BATCH); rc != sql.OK do return rc
	// SQLite may scan the whole target table for a row-value IN UPDATE even
	// with a bounded subquery. Materialize only bounded identities, then seek
	// each primary key. No raw images or workspace-sized lists enter RAM.
	keys: [CHRONICLE_CLEANUP_BATCH]struct {
		workspace: string,
		source_id: u64,
	}
	count := 0
	defer for key in keys[:count] do delete(key.workspace)
	for {
		rc := sql.step(s)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(s, 1)
		if id_rc != sql.OK do return id_rc
		keys[count] = {strings.clone(string(sql.column_bytes_view(s, 0))), id}
		count += 1
	}
	if count == 0 do return sql.OK
	update, update_rc := prepare(
		store,
		`UPDATE chronicle_inputs SET state=3,reason=CASE
 WHEN epoch<=(SELECT disabled_through_epoch FROM chronicle_workspaces w WHERE w.workspace=?1)
 THEN x'64697361626c6564' ELSE x'74746c' END
 WHERE workspace=?1 AND source_id=?2 AND state=0`,
	)
	if update_rc != sql.OK do return update_rc
	defer sql.finalize(update)
	for key in keys[:count] {
		if rc := sql.reset(update); rc != sql.OK do return rc
		if rc := sql.bind_bytes(update, 1, transmute([]byte)key.workspace); rc != sql.OK do return rc
		if rc := sql.bind_id(update, 2, key.source_id); rc != sql.OK do return rc
		if rc := sql.step(update); rc != sql.DONE do return rc
		if rc := compact_chronicle_gap(store, key.workspace, key.source_id); rc != sql.OK do return rc
	}
	// Publish once per affected workspace after the whole bounded cleanup. This
	// also runs during disabled startup; no worker polling is needed for progress.
	for key, i in keys[:count] {
		seen := false
		for previous in keys[:i] do if previous.workspace == key.workspace {seen = true; break}
		if !seen do if rc := publish_chronicle(store, key.workspace); rc != sql.OK do return rc
	}
	return sql.OK
}

Chronicle_Gap :: struct {
	first_source, last_source, note_id: u64,
	first_at, last_at, input_count:     i64,
	reason:                             string,
}

// Exact indexed identity lookup, including IDs above signed/JS integer limits.
// The caller owns gap.reason. No source text, actor or hashes survive here.
read_chronicle_gap :: proc(store: ^Store, workspace: string, source_id: u64) -> (gap: Chronicle_Gap, found: bool, rc: c.int) {
	s: ^sql.Statement
	s, rc = prepare(
		store,
		`SELECT first_source,last_source,note_id,first_at,last_at,input_count,reason FROM
 (SELECT * FROM chronicle_gaps WHERE workspace=?1 AND first_source<=?2 ORDER BY first_source DESC LIMIT 1)
 WHERE last_source>=?2`,
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_id(s, 2, source_id); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return {}, false, sql.OK
	if rc != sql.ROW do return
	gap.first_source, rc = sql.column_id(s, 0); if rc != sql.OK do return
	gap.last_source, rc = sql.column_id(s, 1); if rc != sql.OK do return
	gap.note_id, rc = sql.column_id(s, 2); if rc != sql.OK do return
	gap.first_at = sql.column_int64(s, 3)
	gap.last_at = sql.column_int64(s, 4)
	gap.input_count = sql.column_int64(s, 5)
	gap.reason = strings.clone(string(sql.column_bytes_view(s, 6)))
	return gap, true, sql.OK
}

// Same transaction as capture/expiry/result finalization. Drop full input
// metadata immediately, retaining an exact, text-free terminal receipt. Only
// numeric adjacency can merge: never span a success, another note or an ID hole.
// At most two bounded neighbours are read, irrespective of workspace size.
compact_chronicle_gap :: proc(store: ^Store, workspace: string, source_id: u64) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	s, rc := prepare(store, "SELECT note_id,captured_at,reason FROM chronicle_inputs WHERE workspace=?1 AND source_id=?2 AND state=3")
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, source_id); rc != sql.OK do return rc
	rc = sql.step(s)
	if rc == sql.DONE do return sql.OK
	if rc != sql.ROW do return rc
	note_id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
	at := sql.column_int64(s, 1)
	gap := Chronicle_Gap{source_id, source_id, note_id, at, at, 1, strings.clone(string(sql.column_bytes_view(s, 2)))}
	defer delete(gap.reason)
	if rc = sql.reset(s); rc != sql.OK do return rc
	neighbours: [2]Chronicle_Gap
	defer for neighbour in neighbours do delete(neighbour.reason)
	if source_id > 1 {
		neighbours[0], _, rc = read_chronicle_gap(store, workspace, source_id - 1)
		if rc != sql.OK do return rc
	}
	if source_id < max(u64) {
		neighbours[1], _, rc = read_chronicle_gap(store, workspace, source_id + 1)
		if rc != sql.OK do return rc
	}
	remove, remove_rc := prepare(store, "DELETE FROM chronicle_gaps WHERE workspace=?1 AND first_source=?2")
	if remove_rc != sql.OK do return remove_rc
	defer sql.finalize(remove)
	for neighbour in neighbours {
		if neighbour.input_count == 0 ||
		   neighbour.note_id != note_id ||
		   neighbour.reason != gap.reason ||
		   gap.input_count + neighbour.input_count > CHRONICLE_GAP_RANGE_INPUTS {
			continue
		}
		gap.first_source = min(gap.first_source, neighbour.first_source)
		gap.last_source = max(gap.last_source, neighbour.last_source)
		gap.first_at = min(gap.first_at, neighbour.first_at)
		gap.last_at = max(gap.last_at, neighbour.last_at)
		gap.input_count += neighbour.input_count
		if rc = sql.reset(remove); rc != sql.OK do return rc
		if rc = sql.bind_bytes(remove, 1, transmute([]byte)workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(remove, 2, neighbour.first_source); rc != sql.OK do return rc
		if rc = sql.step(remove); rc != sql.DONE do return rc
	}
	insert, insert_rc := prepare(store, "INSERT INTO chronicle_gaps VALUES(?1,?2,?3,?4,?5,?6,?7,?8)")
	if insert_rc != sql.OK do return insert_rc
	defer sql.finalize(insert)
	if rc = sql.bind_bytes(insert, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	for value, i in ([3]u64{gap.first_source, gap.last_source, gap.note_id}) {
		if rc = sql.bind_id(insert, c.int(i + 2), value); rc != sql.OK do return rc
	}
	if rc = sql.bind_bytes(insert, 5, transmute([]byte)gap.reason); rc != sql.OK do return rc
	for value, i in ([3]i64{gap.first_at, gap.last_at, gap.input_count}) {
		if rc = sql.bind_int64(insert, c.int(i + 6), value); rc != sql.OK do return rc
	}
	if rc = sql.step(insert); rc != sql.DONE do return rc
	remove_input, remove_input_rc := prepare(store, "DELETE FROM chronicle_inputs WHERE workspace=?1 AND source_id=?2 AND state=3")
	if remove_input_rc != sql.OK do return remove_input_rc
	defer sql.finalize(remove_input)
	if rc = sql.bind_bytes(remove_input, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(remove_input, 2, source_id); rc != sql.OK do return rc
	rc = sql.step(remove_input)
	return rc == sql.DONE ? sql.OK : rc
}
