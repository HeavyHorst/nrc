package workspace_db

import mon "../monitoring"
import sql "../sqlite"
import "core:c"
import "core:encoding/endian"

Monitor_Evaluation :: struct {
	monitor_id: u64,
	identity:   string,
	policy:     mon.Policy,
	evaluation: mon.Evaluation,
}
Monitor_Instance :: struct {
	id:      u64,
	state:   mon.Instance,
	// One bounded receipt per instance. Old sequences are rejected; only the
	// most recent evaluation can replay its response after a lost ACK.
	receipt: [45]byte,
	changes: mon.Changes,
}
Monitor_Application :: struct {
	instance_id: u64,
	changes:     mon.Changes,
	replayed:    bool, // Never emit side effects again for this result.
}

// Executor-only primitive, not yet a wire command. Requires the outer write
// transaction. On failure, this batch rolls back to its savepoint, including
// sequence allocation. No partial responses escape. Caller must still handle
// outer commit failure and only acknowledge after commit. Each monitor/identity
// pair may occur only once, so a batch cannot overwrite its own latest receipt.
apply_monitor_evaluations :: proc(store: ^Store, workspace: string, inputs: []Monitor_Evaluation, outputs: []Monitor_Application) -> c.int {
	for &out in outputs do out = {}
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	if len(workspace) == 0 || len(inputs) == 0 || len(inputs) > 1024 || len(outputs) != len(inputs) do return sql.CONSTRAINT
	seen := make(map[struct {
			monitor_id: u64,
			identity:   string,
		}]bool)
	defer delete(seen)
	for input in inputs {
		key := struct {
			monitor_id: u64,
			identity:   string,
		}{input.monitor_id, input.identity}
		if seen[key] do return sql.CONSTRAINT
		seen[key] = true
	}
	rc := execute(store, "SAVEPOINT monitor_evaluation_batch")
	if rc != sql.OK do return rc
	for input, i in inputs {
		outputs[i], rc = apply_monitor_evaluation(store, workspace, input)
		if rc != sql.OK do break
	}
	if rc != sql.OK {
		for &out in outputs do out = {}
		rollback_rc := execute(store, "ROLLBACK TO monitor_evaluation_batch; RELEASE monitor_evaluation_batch")
		return rollback_rc == sql.OK ? rc : rollback_rc
	}
	rc = execute(store, "RELEASE monitor_evaluation_batch")
	if rc != sql.OK {for &out in outputs do out = {}}
	return rc
}

get_monitor_instance :: proc(store: ^Store, workspace: string, monitor_id: u64, identity: string) -> (record: Monitor_Instance, found: bool, rc: c.int) {
	s, status := prepare(
		store,
		`SELECT id,sequence,evaluated_at,seen_at,value_bits,has_value,observation,freshness,
 failures,recoveries,missing,paused,retired,episode,incident_open,receipt,changes
 FROM monitor_instances WHERE workspace=?1 AND monitor_id=?2 AND identity=?3`,
	)
	if status != sql.OK do return {}, false, status
	defer sql.finalize(s)
	if rc = bind_monitor_key(s, workspace, monitor_id, identity); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return {}, false, sql.OK
	if rc != sql.ROW do return
	if record.id, rc = sql.column_id(s, 0); rc != sql.OK do return
	if record.state.last_sequence, rc = sql.column_id(s, 1); rc != sql.OK do return
	record.state.last_evaluated_at = sql.column_int64(s, 2)
	record.state.last_seen_at = sql.column_int64(s, 3)
	bits, bits_rc := sql.column_id(s, 4)
	if bits_rc != sql.OK do return {}, false, bits_rc
	record.state.last_value = transmute(f64)bits
	record.state.has_value = sql.column_int64(s, 5) != 0
	record.state.last_observation = mon.Observation(sql.column_int64(s, 6))
	record.state.freshness = mon.Freshness(sql.column_int64(s, 7))
	record.state.failures = u32(sql.column_int64(s, 8))
	record.state.recoveries = u32(sql.column_int64(s, 9))
	record.state.missing = u32(sql.column_int64(s, 10))
	record.state.paused = sql.column_int64(s, 11) != 0
	record.state.retired = sql.column_int64(s, 12) != 0
	if record.state.episode, rc = sql.column_id(s, 13); rc != sql.OK do return
	record.state.incident_open = sql.column_int64(s, 14) != 0
	receipt := sql.column_bytes_view(s, 15)
	if len(receipt) != len(record.receipt) do return {}, false, sql.CORRUPT
	copy(record.receipt[:], receipt)
	record.changes = transmute(mon.Changes)u8(sql.column_int64(s, 16))
	return record, true, sql.OK
}

// Requires an outer write transaction; caller rolls it back on any error.
// Does not consume an evaluation sequence or alter its receipt/last observation.
control_monitor_instance :: proc(
	store: ^Store,
	workspace: string,
	monitor_id: u64,
	identity: string,
	action: u8,
	at: i64,
) -> (
	record: Monitor_Instance,
	changes: mon.Changes,
	rc: c.int,
) {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return {}, {}, sql.MISUSE
	found: bool
	record, found, rc = get_monitor_instance(store, workspace, monitor_id, identity)
	if rc != sql.OK do return
	if !found || action > 2 || at <= 0 || at < record.state.last_evaluated_at do return {}, {}, sql.CONSTRAINT
	if action == 2 {
		// Retirement replaces a pause; a later present result may reactivate.
		mon.set_paused(&record.state, false)
		changes = mon.retire(&record.state)
	} else {
		if record.state.retired do return {}, {}, sql.CONSTRAINT
		mon.set_paused(&record.state, action == 0)
	}
	if rc = put_monitor_instance(store, workspace, {monitor_id = monitor_id, identity = identity}, record); rc != sql.OK do return
	if .Removed in changes {
		s: ^sql.Statement
		s, rc = prepare(
			store,
			"UPDATE monitor_episodes SET closed_at=?4,close_reason=2 WHERE workspace=?1 AND instance_id=?2 AND episode=?3 AND close_reason=0 RETURNING episode",
		)
		if rc != sql.OK do return
		defer sql.finalize(s)
		if rc = bind_task_key(s, workspace, record.id); rc != sql.OK do return
		if rc = sql.bind_id(s, 3, record.state.episode); rc != sql.OK do return
		if rc = sql.bind_int64(s, 4, at); rc != sql.OK do return
		if rc = sql.step(s); rc != sql.ROW do return record, changes, rc == sql.DONE ? sql.CORRUPT : rc
		if rc = sql.step(s); rc != sql.DONE do return
	}
	return record, changes, sql.OK
}

// Requires the caller's transaction. Staleness is not an observation: retain the
// latest receipt, sequence, value and episode, including its original changes.
mark_monitor_instance_stale :: proc(store: ^Store, workspace: string, monitor_id: u64, identity: string, policy: mon.Policy, at: i64) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	record, found, rc := get_monitor_instance(store, workspace, monitor_id, identity)
	if rc != sql.OK do return rc
	if !found do return sql.CORRUPT
	if !mon.mark_stale(&record.state, policy, at) do return sql.OK
	return put_monitor_instance(store, workspace, {monitor_id = monitor_id, identity = identity}, record)
}

@(private)
bind_monitor_key :: proc(s: ^sql.Statement, workspace: string, monitor_id: u64, identity: string) -> c.int {
	if len(workspace) == 0 || monitor_id == 0 || len(identity) == 0 || len(identity) > 4096 do return sql.CONSTRAINT
	if rc := sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	if rc := sql.bind_id(s, 2, monitor_id); rc != sql.OK do return rc
	return sql.bind_bytes(s, 3, transmute([]byte)identity)
}

@(private)
monitor_receipt :: proc(input: Monitor_Evaluation) -> (bytes: [45]byte) {
	e, p := input.evaluation, input.policy
	endian.put_u64(bytes[0:8], .Big, e.sequence)
	endian.put_u64(bytes[8:16], .Big, u64(e.at))
	bytes[16] = u8(e.observation)
	endian.put_u64(bytes[17:25], .Big, transmute(u64)e.value)
	endian.put_u32(bytes[25:29], .Big, p.failures)
	endian.put_u32(bytes[29:33], .Big, p.recoveries)
	endian.put_u32(bytes[33:37], .Big, p.missing)
	endian.put_u64(bytes[37:45], .Big, u64(p.stale_after))
	return
}

@(private)
apply_monitor_evaluation :: proc(store: ^Store, workspace: string, input: Monitor_Evaluation) -> (Monitor_Application, c.int) {
	record, found, rc := get_monitor_instance(store, workspace, input.monitor_id, input.identity)
	if rc != sql.OK do return {}, rc
	receipt := monitor_receipt(input)
	if found && input.evaluation.sequence <= record.state.last_sequence {
		if input.evaluation.sequence == record.state.last_sequence && receipt == record.receipt {
			return {record.id, record.changes, true}, sql.OK
		}
		return {}, sql.CONSTRAINT
	}
	changes, result := mon.evaluate(&record.state, input.policy, input.evaluation)
	if result != .Applied do return {}, sql.CONSTRAINT
	if !found {
		// Absence/error does not discover an instance that has never been seen.
		if !record.state.has_value do return {}, sql.CONSTRAINT
		if record.id, rc = next_id(store, .Monitor_Instance); rc != sql.OK do return {}, rc
	}
	record.receipt, record.changes = receipt, changes
	if rc = put_monitor_instance(store, workspace, input, record); rc != sql.OK do return {}, rc
	if .Opened in changes {
		s, status := prepare(store, "INSERT INTO monitor_episodes(workspace,instance_id,episode,opened_at) VALUES(?1,?2,?3,?4)")
		if status != sql.OK do return {}, status
		defer sql.finalize(s)
		if rc = bind_task_key(s, workspace, record.id); rc != sql.OK do return {}, rc
		if rc = sql.bind_id(s, 3, record.state.episode); rc != sql.OK do return {}, rc
		if rc = sql.bind_int64(s, 4, input.evaluation.at); rc != sql.OK do return {}, rc
		if rc = sql.step(s); rc != sql.DONE do return {}, rc
	}
	if .Recovered in changes {
		s, status := prepare(
			store,
			`UPDATE monitor_episodes SET closed_at=?4,close_reason=1
 WHERE workspace=?1 AND instance_id=?2 AND episode=?3 AND close_reason=0 RETURNING episode`,
		)
		if status != sql.OK do return {}, status
		defer sql.finalize(s)
		if rc = bind_task_key(s, workspace, record.id); rc != sql.OK do return {}, rc
		if rc = sql.bind_id(s, 3, record.state.episode); rc != sql.OK do return {}, rc
		if rc = sql.bind_int64(s, 4, input.evaluation.at); rc != sql.OK do return {}, rc
		if rc = sql.step(s); rc != sql.ROW do return {}, rc == sql.DONE ? sql.CORRUPT : rc
		if rc = sql.step(s); rc != sql.DONE do return {}, rc
	}
	return {record.id, changes, false}, sql.OK
}

@(private)
put_monitor_instance :: proc(store: ^Store, workspace: string, input: Monitor_Evaluation, record: Monitor_Instance) -> c.int {
	s, rc := prepare(
		store,
		`INSERT INTO monitor_instances
 (workspace,monitor_id,identity,id,sequence,evaluated_at,seen_at,value_bits,has_value,observation,freshness,
 failures,recoveries,missing,paused,retired,episode,incident_open,receipt,changes)
 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)
 ON CONFLICT(workspace,id) DO UPDATE SET sequence=excluded.sequence,evaluated_at=excluded.evaluated_at,
 seen_at=excluded.seen_at,value_bits=excluded.value_bits,has_value=excluded.has_value,observation=excluded.observation,
 freshness=excluded.freshness,failures=excluded.failures,recoveries=excluded.recoveries,missing=excluded.missing,
 paused=excluded.paused,retired=excluded.retired,episode=excluded.episode,incident_open=excluded.incident_open,
 receipt=excluded.receipt,changes=excluded.changes`,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = bind_monitor_key(s, workspace, input.monitor_id, input.identity); rc != sql.OK do return rc
	v := record.state
	for field in ([4]struct {
			index: c.int,
			value: u64,
		}{{4, record.id}, {5, v.last_sequence}, {8, transmute(u64)v.last_value}, {17, v.episode}}) {
		if rc = sql.bind_id(s, field.index, field.value); rc != sql.OK do return rc
	}
	for field in ([12]struct {
			index: c.int,
			value: i64,
		}{{6, v.last_evaluated_at}, {7, v.last_seen_at}, {9, i64(v.has_value)}, {10, i64(v.last_observation)}, {11, i64(v.freshness)}, {12, i64(v.failures)}, {13, i64(v.recoveries)}, {14, i64(v.missing)}, {15, i64(v.paused)}, {16, i64(v.retired)}, {18, i64(v.incident_open)}, {20, i64(transmute(u8)record.changes)}}) {
		if rc = sql.bind_int64(s, field.index, field.value); rc != sql.OK do return rc
	}
	receipt := record.receipt
	if rc = sql.bind_bytes(s, 19, receipt[:]); rc != sql.OK do return rc
	rc = sql.step(s)
	return rc == sql.DONE ? sql.OK : rc
}
