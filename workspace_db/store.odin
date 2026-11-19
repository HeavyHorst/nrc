// Disk-backed workspace storage. Callers supply an explicit path; this package
// does not select a data directory or perform implicit migrations.
package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:c"
import "core:strings"

Store :: struct {
	metrics:               ^pr.DatabaseStats, // Executor-owned handle; atomic port counters only.
	db:                    ^sql.Database,
	read_only:             bool,
	// Fixed finalization program, owned exclusively by this connection.
	slice_statements:      [64]^sql.Statement,
	slice_statement_count: int,
}

SCHEMA_VERSION :: 9
APPLICATION_ID :: 0x4e524351
SCHEMA ::
	#load("schema.sql", string) +
	#load("slice_summaries.sql", string) +
	#load("slice_incremental.sql", string) +
	#load("slice_pagination.sql", string) +
	#load("monitoring.sql", string) +
	#load("chronicle.sql", string) +
	#load("chronicle_input_budget.sql", string) +
	#load("monitor_snapshots.sql", string) +
	#load("ticket_trigram.sql", string)

// create permits initialization of an empty database only. Existing NRC files
// must match the schema version; other databases are never adopted or migrated.
// The caller exclusively owns the returned handle and must close it.
open :: proc(path: cstring, create := false, read_only := false) -> (store: Store, status: c.int) {
	// STRICT tables require 3.37.0. Release pinning belongs to the eventual
	// deployment integration; this isolated slice links the system library.
	if sql.libversion_number() < 3_037_000 do return {}, sql.MISUSE
	if create && read_only do return {}, sql.MISUSE
	store.read_only = read_only
	flags := (read_only ? sql.OPEN_READONLY : sql.OPEN_READWRITE) | sql.OPEN_NOMUTEX
	if create do flags |= sql.OPEN_CREATE
	status = sql.open_v2(path, &store.db, flags, nil)
	// Independent lanes may open the same WAL concurrently. Its initial recovery
	// and shared-memory setup briefly require exclusive locks. Bound that wait
	// to initialization; ordinary requests retain immediate BUSY errors.
	if status == sql.OK do status = sql.busy_timeout(store.db, 100)
	if status == sql.OK do status = sql.register_lower(store.db)
	if status == sql.OK do status = initialize(&store, create)
	if status == sql.OK do status = sql.busy_timeout(store.db, 0)
	if status != sql.OK {
		if store.db != nil do sql.close(store.db)
		return {}, status
	}
	return store, sql.OK
}

@(private)
initialize :: proc(store: ^Store, create: bool) -> c.int {
	application, rc := scalar(store, "PRAGMA application_id")
	if rc != sql.OK do return rc
	version, version_rc := scalar(store, "PRAGMA user_version")
	if version_rc != sql.OK do return version_rc
	if application == 0 && version == 0 && create {
		objects, objects_rc := scalar(store, "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'")
		if objects_rc != sql.OK do return objects_rc
		if objects != 0 do return sql.NOTADB
		status := execute(store, "BEGIN IMMEDIATE")
		if status != sql.OK do return status
		status = execute(store, SCHEMA)
		if status == sql.OK do status = execute(store, "COMMIT")
		if status != sql.OK {
			execute(store, "ROLLBACK")
			return status
		}
	} else if application != APPLICATION_ID || version != SCHEMA_VERSION {
		return sql.NOTADB
	}
	// WAL plus FULL preserves the future fsync-before-ACK contract. The suggested
	// 4 MiB page-cache budget is per connection, not a hard process memory cap.
	rc = execute(
		store,
		store.read_only ? "PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA cache_size=-4096; PRAGMA temp_store=FILE;" : "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA cache_size=-4096; PRAGMA temp_store=FILE;",
	)
	if rc != sql.OK do return rc
	// Setting journal_mode can succeed without selecting WAL (e.g. :memory:).
	wal, wal_rc := scalar(store, "SELECT journal_mode = 'wal' FROM pragma_journal_mode")
	if wal_rc != sql.OK do return wal_rc
	return wal == 1 ? sql.OK : sql.ERROR
}

close :: proc(store: ^Store) -> c.int {
	if store.db == nil do return sql.OK
	clear_slice_statements(store)
	status := sql.close(store.db)
	if status == sql.OK do store.db = nil
	return status
}

begin :: proc(store: ^Store) -> c.int {return execute(store, store.read_only ? "BEGIN" : "BEGIN IMMEDIATE")}
commit :: proc(store: ^Store) -> c.int {
	if !store.read_only {
		started := metrics_now()
		rc := finalize_slices(store)
		metrics_observe(store.metrics, 6, started)
		if rc != sql.OK do return rc
	}
	started := metrics_now()
	defer if !store.read_only do metrics_observe(store.metrics, 7, started)
	return execute(store, "COMMIT")
}
rollback :: proc(store: ^Store) -> c.int {return execute(store, "ROLLBACK")}

// Drains only changed identities, once after all command/batch mutations.
// Reads may also call this inside their transaction after explicit SQL fixtures
// or offline import. Errors require the caller to roll back the transaction.
finalize_slices :: proc(store: ^Store) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	pending, rc := scalar(store, "SELECT EXISTS(SELECT 1 FROM slice_pending)")
	if rc != sql.OK || pending == 0 do return rc
	// Runtime writers publish projections atomically with canonical records.
	// A reader must never repair an incomplete offline import or fixture.
	if store.read_only do return sql.MISUSE
	if store.slice_statement_count != 0 {
		for s in store.slice_statements[:store.slice_statement_count] {
			rc = sql.step(s)
			sql.reset(s)
			if rc != sql.DONE {
				clear_slice_statements(store)
				return rc
			}
		}
		return sql.OK
	}
	// Prepare in execution order: later statements refer to TEMP tables created
	// by earlier ones. SQLite reparses cached statements after schema rollback.
	cursor := cstring(#load("slice_finalize.sql", string))
	for (^u8)(cursor)^ != 0 {
		s: ^sql.Statement
		tail: cstring
		rc = sql.prepare_v2(store.db, cursor, -1, &s, &tail)
		if rc != sql.OK {clear_slice_statements(store); return rc}
		cursor = tail
		if s == nil do continue
		if store.slice_statement_count == len(store.slice_statements) {
			sql.finalize(s)
			clear_slice_statements(store)
			return sql.TOOBIG
		}
		store.slice_statements[store.slice_statement_count] = s
		store.slice_statement_count += 1
		rc = sql.step(s)
		sql.reset(s)
		if rc != sql.DONE {clear_slice_statements(store); return rc}
	}
	return sql.OK
}

@(private)
clear_slice_statements :: proc(store: ^Store) {
	for s in store.slice_statements[:store.slice_statement_count] do sql.finalize(s)
	store.slice_statements = {}
	store.slice_statement_count = 0
}

// Explicit offline rebuild after parsed asset metadata has been rebuilt.
// No canonical records change; failure requires rolling back the transaction.
rebuild_slices :: proc(store: ^Store) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	rc := execute(
		store,
		`DELETE FROM slice_pending; DELETE FROM slice_members;
 DELETE FROM slice_summaries; DELETE FROM slice_projects; DELETE FROM task_slice_coverage;
 DELETE FROM workspace_task_counts;
 INSERT INTO workspace_task_counts(workspace,status,total) SELECT workspace,status,count(*) FROM tasks GROUP BY workspace,status;
 INSERT INTO slice_pending SELECT workspace,3,id FROM edges WHERE relation=7;
 INSERT INTO slice_pending SELECT workspace,4,asset_id FROM slice_metadata;`,
	)
	if rc != sql.OK do return rc
	return finalize_slices(store)
}

@(private)
execute :: proc(store: ^Store, query: string) -> c.int {
	c_query := strings.clone_to_cstring(query)
	defer delete(c_query)
	return sql.exec(store.db, c_query, nil, nil, nil)
}

@(private)
prepare :: proc(store: ^Store, query: cstring) -> (statement: ^sql.Statement, status: c.int) {
	status = sql.prepare_v2(store.db, query, -1, &statement, nil)
	return
}

@(private)
scalar :: proc(store: ^Store, query: cstring) -> (value: i64, status: c.int) {
	statement, rc := prepare(store, query)
	if rc != sql.OK do return 0, rc
	defer sql.finalize(statement)
	status = sql.step(statement)
	if status != sql.ROW do return 0, status
	return sql.column_int64(statement, 0), sql.OK
}

ID_Domain :: enum {
	Task,
	Asset,
	Edge,
	Monitor_Instance,
	Monitor_Delivery,
	Monitor_Snapshot,
}

// Durable floors are independent of live rows and include referenced IDs.
// Import must advance them even when the highest record has been deleted.
advance_floor :: proc(store: ^Store, floor: u64, domain := ID_Domain.Task) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	queries := [ID_Domain]cstring {
		.Task             = "UPDATE sequences SET high_water = max(high_water, ?1) WHERE domain = 'task'",
		.Asset            = "UPDATE sequences SET high_water = max(high_water, ?1) WHERE domain = 'asset'",
		.Edge             = "UPDATE sequences SET high_water = max(high_water, ?1) WHERE domain = 'edge'",
		.Monitor_Instance = "UPDATE sequences SET high_water = max(high_water, ?1) WHERE domain = 'monitor_instance'",
		.Monitor_Delivery = "UPDATE sequences SET high_water = max(high_water, ?1) WHERE domain = 'monitor_delivery'",
		.Monitor_Snapshot = "UPDATE sequences SET high_water = max(high_water, ?1) WHERE domain = 'monitor_snapshot'",
	}
	statement, rc := prepare(store, queries[domain])
	if rc != sql.OK do return rc
	defer sql.finalize(statement)
	if rc = sql.bind_id(statement, 1, floor); rc != sql.OK do return rc
	rc = sql.step(statement)
	return rc == sql.DONE ? sql.OK : rc
}

next_id :: proc(store: ^Store, domain := ID_Domain.Task) -> (id: u64, status: c.int) {
	if sql.get_autocommit(store.db) != 0 do return 0, sql.MISUSE
	queries := [ID_Domain]cstring {
		.Task             = "SELECT high_water FROM sequences WHERE domain = 'task'",
		.Asset            = "SELECT high_water FROM sequences WHERE domain = 'asset'",
		.Edge             = "SELECT high_water FROM sequences WHERE domain = 'edge'",
		.Monitor_Instance = "SELECT high_water FROM sequences WHERE domain = 'monitor_instance'",
		.Monitor_Delivery = "SELECT high_water FROM sequences WHERE domain = 'monitor_delivery'",
		.Monitor_Snapshot = "SELECT high_water FROM sequences WHERE domain = 'monitor_snapshot'",
	}
	statement, rc := prepare(store, queries[domain])
	if rc != sql.OK do return 0, rc
	defer sql.finalize(statement)
	if rc = sql.step(statement); rc != sql.ROW do return 0, rc == sql.DONE ? sql.CORRUPT : rc
	floor, floor_rc := sql.column_id(statement, 0)
	if floor_rc != sql.OK do return 0, floor_rc
	if floor == max(u64) do return 0, sql.FULL
	id = floor + 1
	status = advance_floor(store, id, domain)
	return
}
