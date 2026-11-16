package workspace_db

import sql "../sqlite"
import "core:c"
import "core:strings"

Monitor_Delivery :: struct {
	id:                                                          u64,
	body:                                                        string, // Owned by the caller's allocator.
	created_at, available_at, lease_until, generation, attempts: i64,
	actor, subject:                                              string,
	dead:                                                        bool,
	sync_version:                                                i64,
}

// All operations require the executor's outer write transaction. The caller
// rolls back on errors, including allocated IDs and queue-budget counters.
enqueue_monitor_delivery :: proc(
	store: ^Store,
	workspace: string,
	monitor_id: u64,
	stream: u8,
	route: string,
	at: i64,
	body: []byte,
	sync_version: i64 = 0,
) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	id, rc := next_id(store, .Monitor_Delivery)
	if rc != sql.OK do return rc
	s, status := prepare(
		store,
		`INSERT INTO monitor_deliveries(workspace,monitor_id,stream,route,id,body,created_at,available_at,sync_version)
 VALUES(?1,?2,?3,?4,?5,?6,?7,?7,?8)`,
	)
	if status != sql.OK do return status
	defer sql.finalize(s)
	if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 5, id); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 6, body); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 7, at); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 8, sync_version); rc != sql.OK do return rc
	rc = sql.step(s)
	return rc == sql.DONE ? sql.OK : rc
}

@(private)
bind_monitor_delivery :: proc(s: ^sql.Statement, workspace: string, monitor_id: u64, stream: u8, route: string) -> c.int {
	if len(workspace) == 0 || monitor_id == 0 || stream != 1 || len(route) > 64 || len(route) == 0 do return sql.CONSTRAINT
	if rc := bind_task_key(s, workspace, monitor_id); rc != sql.OK do return rc
	if rc := sql.bind_int64(s, 3, i64(stream)); rc != sql.OK do return rc
	return sql.bind_bytes(s, 4, transmute([]byte)route)
}

// Peek/claim only the head of one stream/route. A waiting or dead head blocks
// later events, so a recovery cannot overtake its firing notification.
monitor_delivery_head :: proc(
	store: ^Store,
	workspace: string,
	monitor_id: u64,
	stream: u8,
	route: string,
) -> (
	row: Monitor_Delivery,
	found: bool,
	rc: c.int,
) {
	s: ^sql.Statement
	s, rc = prepare(
		store,
		`SELECT id,body,created_at,available_at,lease_until,generation,attempts,actor,subject,dead,sync_version
 FROM monitor_deliveries WHERE workspace=?1 AND monitor_id=?2 AND stream=?3 AND route=?4 ORDER BY id LIMIT 1`,
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return {}, false, sql.OK
	if rc != sql.ROW do return
	if row.id, rc = sql.column_id(s, 0); rc != sql.OK do return
	row.body = strings.clone(string(sql.column_bytes_view(s, 1)))
	row.created_at, row.available_at = sql.column_int64(s, 2), sql.column_int64(s, 3)
	row.lease_until, row.generation, row.attempts = sql.column_int64(s, 4), sql.column_int64(s, 5), sql.column_int64(s, 6)
	row.actor = strings.clone(string(sql.column_bytes_view(s, 7)))
	row.subject = strings.clone(string(sql.column_bytes_view(s, 8)))
	row.dead = sql.column_int64(s, 9) != 0
	row.sync_version = sql.column_int64(s, 10)
	return row, true, sql.OK
}

// action: 0 peek, 1 claim, 2 delivered, 3 retry, 4 permanent failure,
// 5 explicitly discard a dead webhook and request resynchronization.
// state: 0 empty, 1 waiting, 2 leased, 3 dead, 4 settled (including latest retry).
act_on_monitor_delivery :: proc(
	store: ^Store,
	workspace: string,
	monitor_id: u64,
	stream: u8,
	route, actor, subject: string,
	action: u8,
	id: u64,
	generation, at: i64,
) -> (
	row: Monitor_Delivery,
	state: u8,
	rc: c.int,
) {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return {}, 0, sql.MISUSE
	if action > 5 || at <= 0 || at > max(i64) - 3600_000_000_000 || len(actor) == 0 do return {}, 0, sql.CONSTRAINT
	if action >= 2 {
		s, status := prepare(
			store,
			`SELECT id,generation,action,actor,subject FROM monitor_delivery_receipts
 WHERE workspace=?1 AND monitor_id=?2 AND stream=?3 AND route=?4`,
		)
		if status != sql.OK do return {}, 0, status
		defer sql.finalize(s)
		if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return
		rc = sql.step(s)
		if rc == sql.ROW {
			old_id, e := sql.column_id(s, 0); if e != sql.OK do return {}, 0, e
			if old_id == id && sql.column_int64(s, 1) == generation && sql.column_int64(s, 2) == i64(action) && string(sql.column_bytes_view(s, 3)) == actor && string(sql.column_bytes_view(s, 4)) == subject do return {id = id, generation = generation}, 4, sql.OK
		} else if rc != sql.DONE do return
	}
	found: bool
	row, found, rc = monitor_delivery_head(store, workspace, monitor_id, stream, route)
	if rc != sql.OK do return
	if !found {if action >= 2 do return {}, 0, sql.CONSTRAINT; return {}, 0, sql.OK}
	state = row.dead ? 3 : 1
	if action == 0 do return
	if action == 1 {
		if row.dead || row.available_at > at do return
		if row.lease_until > at {
			if row.actor == actor && row.subject == subject do state = 2
			return
		}
		if row.generation == max(i64) do return {}, 0, sql.FULL
		if stream == 1 && row.attempts >= 10 {
			row.dead = true; row.lease_until = 0; state = 3
		} else {
			row.generation += 1
			row.attempts = min(row.attempts, max(i64) - 1) + 1
			row.lease_until = at + 60_000_000_000
			row.actor, row.subject = actor, subject
			state = 2
		}
	} else {
		if row.id != id || row.generation != generation do return row, state, sql.CONSTRAINT
		if action == 5 {
			if stream != 1 || !row.dead do return row, state, sql.CONSTRAINT
		} else if row.dead || row.lease_until <= at || row.actor != actor || row.subject != subject do return row, state, sql.CONSTRAINT
		if action == 2 || action == 5 {
			// Discarding a failed notification requires a later state reconciliation too.
			if stream == 1 && action == 5 {
				if rc = mark_monitor_delivery_loss(store, workspace, monitor_id, stream, route, at); rc != sql.OK do return
			}
			if action == 2 && row.sync_version > 0 {
				if rc = clear_monitor_delivery_loss(store, workspace, monitor_id, stream, route, row.sync_version); rc != sql.OK do return
			}
			s, status := prepare(store, "DELETE FROM monitor_deliveries WHERE workspace=?1 AND monitor_id=?2 AND stream=?3 AND route=?4 AND id=?5")
			if status != sql.OK do return row, state, status
			defer sql.finalize(s)
			if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return
			if rc = sql.bind_id(s, 5, id); rc != sql.OK do return
			if rc = sql.step(s); rc != sql.DONE do return
		} else {
			row.lease_until = 0
			row.dead = action == 4 || (stream == 1 && row.attempts >= 10)
			row.available_at = at + min(i64(1) << u64(min(row.attempts, 9)), 300) * 1_000_000_000
		}
		state = 4
		s, status := prepare(
			store,
			`INSERT INTO monitor_delivery_receipts VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
 ON CONFLICT(workspace,monitor_id,stream,route) DO UPDATE SET id=excluded.id,generation=excluded.generation,action=excluded.action,actor=excluded.actor,subject=excluded.subject`,
		)
		if status != sql.OK do return row, state, status
		defer sql.finalize(s)
		if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return
		if rc = sql.bind_id(s, 5, id); rc != sql.OK do return
		if rc = sql.bind_int64(s, 6, generation); rc != sql.OK do return
		if rc = sql.bind_int64(s, 7, i64(action)); rc != sql.OK do return
		if rc = sql.bind_bytes(s, 8, transmute([]byte)actor); rc != sql.OK do return
		if rc = sql.bind_bytes(s, 9, transmute([]byte)subject); rc != sql.OK do return
		if rc = sql.step(s); rc != sql.DONE do return
		if action == 2 || action == 5 do return row, state, sql.OK
	}
	s, status := prepare(
		store,
		`UPDATE monitor_deliveries SET available_at=?6,lease_until=?7,generation=?8,attempts=?9,actor=?10,subject=?11,dead=?12
 WHERE workspace=?1 AND monitor_id=?2 AND stream=?3 AND route=?4 AND id=?5`,
	)
	if status != sql.OK do return row, state, status
	defer sql.finalize(s)
	if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return
	if rc = sql.bind_id(s, 5, row.id); rc != sql.OK do return
	for value, i in ([4]i64{row.available_at, row.lease_until, row.generation, row.attempts}) {if rc = sql.bind_int64(s, c.int(6 + i), value); rc != sql.OK do return}
	if rc = sql.bind_bytes(s, 10, transmute([]byte)row.actor); rc != sql.OK do return
	if rc = sql.bind_bytes(s, 11, transmute([]byte)row.subject); rc != sql.OK do return
	if rc = sql.bind_int64(s, 12, i64(row.dead)); rc != sql.OK do return
	rc = sql.step(s); if rc == sql.DONE do rc = sql.OK
	return
}
