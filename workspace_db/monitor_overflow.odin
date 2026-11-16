package workspace_db

import sql "../sqlite"
import "core:c"

Monitor_Delivery_Loss :: struct {
	version, lost, first_at, last_at: i64,
}

// Capacity is checked under the same writer transaction as the eventual insert.
// A false result is the only failure callers may treat as lossy admission.
monitor_delivery_capacity :: proc(store: ^Store, workspace: string, stream: u8, entries, bytes: i64) -> (bool, c.int) {
	if sql.get_autocommit(store.db) != 0 do return false, sql.MISUSE
	if stream != 1 || entries < 0 || bytes < 0 do return false, sql.CONSTRAINT
	s, rc := prepare(store, "SELECT entries,bytes FROM monitor_queue_usage WHERE workspace=?1 AND stream=?2")
	if rc != sql.OK do return false, rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return false, rc
	if rc = sql.bind_int64(s, 2, i64(stream)); rc != sql.OK do return false, rc
	rc = sql.step(s)
	if rc != sql.ROW && rc != sql.DONE do return false, rc
	used_entries := rc == sql.ROW ? sql.column_int64(s, 0) : 0
	used_bytes := rc == sql.ROW ? sql.column_int64(s, 1) : 0
	return entries <= 10000 - used_entries && bytes <= 16777216 - used_bytes, sql.OK
}

monitor_delivery_loss :: proc(store: ^Store, workspace: string, monitor_id: u64, stream: u8, route: string) -> (loss: Monitor_Delivery_Loss, rc: c.int) {
	s: ^sql.Statement
	s, rc = prepare(store, "SELECT version,lost,first_at,last_at FROM monitor_delivery_lanes WHERE workspace=?1 AND monitor_id=?2 AND stream=?3 AND route=?4")
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return {}, sql.OK
	if rc != sql.ROW do return
	return {sql.column_int64(s, 0), sql.column_int64(s, 1), sql.column_int64(s, 2), sql.column_int64(s, 3)}, sql.OK
}

mark_monitor_delivery_loss :: proc(store: ^Store, workspace: string, monitor_id: u64, stream: u8, route: string, at: i64) -> c.int {
	version, version_rc := next_monitor_delivery_version(store)
	if version_rc != sql.OK do return version_rc
	s, rc := prepare(
		store,
		`UPDATE monitor_delivery_lanes SET version=?6,lost=min(lost+1,9223372036854775807),
 first_at=CASE WHEN lost=0 THEN ?5 ELSE min(first_at,?5) END,last_at=max(last_at,?5)
 WHERE workspace=?1 AND monitor_id=?2 AND stream=?3 AND route=?4 RETURNING version`,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 5, at); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 6, version); rc != sql.OK do return rc
	rc = sql.step(s)
	if rc == sql.DONE do return sql.CORRUPT // Configuration must reserve metadata first.
	if rc != sql.ROW do return rc
	rc = sql.step(s); return rc == sql.DONE ? sql.OK : rc
}

// Never reuse a snapshot version, even after a clean route was pruned/re-added.
next_monitor_delivery_version :: proc(store: ^Store) -> (i64, c.int) {
	id, rc := next_id(store, .Monitor_Delivery)
	if rc != sql.OK do return 0, rc
	if id > u64(max(i64)) do return 0, sql.FULL
	return i64(id), sql.OK
}

clear_monitor_delivery_loss :: proc(store: ^Store, workspace: string, monitor_id: u64, stream: u8, route: string, version: i64) -> c.int {
	s, rc := prepare(
		store,
		`UPDATE monitor_delivery_lanes SET lost=0,first_at=0,last_at=0
 WHERE workspace=?1 AND monitor_id=?2 AND stream=?3 AND route=?4 AND version=?5`,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = bind_monitor_delivery(s, workspace, monitor_id, stream, route); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 5, version); rc != sql.OK do return rc
	rc = sql.step(s); return rc == sql.DONE ? sql.OK : rc
}
