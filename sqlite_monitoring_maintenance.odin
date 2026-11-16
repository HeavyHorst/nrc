package main

import "core:c"
import "core:mem/virtual"
import "core:strings"
import sql "sqlite"
import db "workspace_db"

MONITOR_MAINTENANCE_BATCH :: 64

// Internal shard-wide writer job. No client, loaded workspace or running sidecar
// is required. The executor commits the batch before publishing its cursor.
sqlite_monitor_maintenance :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	if request.operation != .Monitor_Maintenance || request.timestamp <= 0 do return sql.CONSTRAINT
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	through := request.monitor_through
	if through == 0 {
		if request.monitor_cursor != 0 do return sql.CONSTRAINT
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT high_water FROM sequences WHERE domain='monitor_instance'", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if sql.step(s) != sql.ROW do return sql.CORRUPT
		if through, rc = sql.column_id(s, 0); rc != sql.OK do return rc
	}
	if request.monitor_cursor > through do return sql.CONSTRAINT
	rows: [MONITOR_MAINTENANCE_BATCH]struct {
		workspace, identity: string,
		id, monitor_id:      u64,
	}
	count := 0
	{
		s: ^sql.Statement
		rc := sql.prepare_v2(
			store.db,
			`SELECT workspace,identity,id,monitor_id FROM monitor_instances
 WHERE has_value=1 AND paused=0 AND retired=0 AND (freshness!=3 OR failures!=0 OR recoveries!=0)
 AND id>?1 AND id<=?3 ORDER BY id LIMIT ?2`,
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_id(s, 1, request.monitor_cursor); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 2, MONITOR_MAINTENANCE_BATCH); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 3, through); rc != sql.OK do return rc
		for {
			rc = sql.step(s)
			if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			row := &rows[count]
			row.workspace = strings.clone(string(sql.column_bytes_view(s, 0)))
			row.identity = strings.clone(string(sql.column_bytes_view(s, 1)))
			if row.id, rc = sql.column_id(s, 2); rc != sql.OK do return rc
			if row.monitor_id, rc = sql.column_id(s, 3); rc != sql.OK do return rc
			count += 1
		}
	}
	// Materialize the bounded page before updates remove rows from its index.
	for row in rows[:count] {
		monitor, found, rc := sqlite_read_asset(store, row.workspace, "", row.monitor_id, true, check_visibility = false)
		if rc != sql.OK do return rc
		if !found do return sql.CORRUPT
		_, policy, valid := parse_monitor_config(&monitor, context.allocator)
		if !valid do return sql.CORRUPT
		// Disabling evaluation does not make its last measurement stay fresh.
		if rc = db.mark_monitor_instance_stale(store, row.workspace, row.monitor_id, row.identity, policy, request.timestamp); rc != sql.OK do return rc
	}
	if count == len(rows) && rows[count - 1].id < through {
		output.monitor_cursor = rows[count - 1].id
		output.monitor_through = through
	}
	return sql.OK
}
