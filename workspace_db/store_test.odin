package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

test_database_path :: proc(t: ^testing.T) -> (directory: string, path: cstring) {
	dir, err := os.make_directory_temp("", "nrc-sqlite-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	name := fmt.aprintf("%s/workspace.db", dir)
	defer delete(name)
	return dir, strings.clone_to_cstring(name)
}

test_remove_database :: proc(directory: string, path: cstring) {
	os.remove_all(directory)
	delete(directory)
	delete(path)
}

expect_task :: proc(t: ^testing.T, got, expected: pr.Task) {
	// Compare the public wire representation: all scalar fields, binary byte
	// fields and attachment order, independent of SQL column/allocator layout.
	actual := make([]byte, pr.getSizeTask(got))
	want := make([]byte, pr.getSizeTask(expected))
	defer delete(actual); defer delete(want)
	testing.expect_value(t, pr.serializeTask(got, actual), len(actual))
	testing.expect_value(t, pr.serializeTask(expected, want), len(want))
	testing.expect_value(t, string(actual), string(want))
}

@(test)
test_slice_finalization_reuse_after_rollback_and_failure :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, execute(&store, `
 INSERT INTO assets VALUES(x'77',x'0000000000000002',0,0,zeroblob(8),x'',1,1,0,0,x'',x'');
 INSERT INTO slice_metadata(workspace,asset_id,name,owner,outcome,closed,closed_at,closed_by) VALUES(x'77',x'0000000000000002',x'73',x'',x'',0,0,x'');
 INSERT INTO edges VALUES(x'77',x'0000000000000003',2,x'0000000000000001',1,x'0000000000000002',7,1,x'');`), sql.OK)
	task := pr.Task{id = 1, status = .Todo, created_at = 17, updated_at = 29}
	// First initialization is rolled back, including its TEMP schema. Later
	// calls must recreate it and must not reuse any rolled-back contributions.
	for attempt in 0 ..< 4 {
		testing.expect_value(t, begin(&store), sql.OK)
		task.status = attempt == 3 ? .Done : .Todo
		testing.expect_value(t, put_task(&store, "w", &task), sql.OK)
		if attempt == 2 {
			testing.expect_value(t, execute(&store, "CREATE TEMP TRIGGER fail_finalize BEFORE DELETE ON main.slice_pending BEGIN SELECT RAISE(ABORT,'test'); END"), sql.OK)
			testing.expect_value(t, finalize_slices(&store), sql.CONSTRAINT)
			testing.expect_value(t, rollback(&store), sql.OK)
			continue
		}
		testing.expect_value(t, finalize_slices(&store), sql.OK)
		if attempt == 0 {
			testing.expect_value(t, rollback(&store), sql.OK)
			continue
		}
		testing.expect_value(t, commit(&store), sql.OK)
		value, status := scalar(&store, "SELECT todo*10+done FROM slice_summaries")
		testing.expect_value(t, status, sql.OK)
		testing.expect_value(t, value, attempt == 3 ? 1 : 10)
		covered, covered_rc := scalar(&store, "SELECT sum(covered) FROM workspace_task_counts")
		testing.expect(t, covered_rc == sql.OK && covered == 1)
	}
}

@(test)
test_reader_open_transient_wal_lock :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	writer, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	// An exclusive WAL owner reproduces the lock seen during concurrent WAL
	// initialization. Transfer its handle to the releasing thread exclusively.
	testing.expect_value(t, execute(&writer, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE"), sql.OK)
	blocked, blocked_rc := open(path, read_only = true)
	testing.expect(t, blocked_rc == sql.BUSY && blocked.db == nil, "failed initialization must close its handle")
	if blocked.db != nil do close(&blocked)
	releaser := thread.create_and_start_with_poly_data(&writer, proc(store: ^Store) {
		time.sleep(10 * time.Millisecond)
		assert(rollback(store) == sql.OK)
		assert(close(store) == sql.OK)
	})
	reader, read_rc := open(path, read_only = true)
	thread.join(releaser); thread.destroy(releaser)
	if !testing.expect_value(t, read_rc, sql.OK) do return
	defer close(&reader)
	count, count_rc := scalar(&reader, "SELECT count(*) FROM tasks")
	testing.expect(t, count_rc == sql.OK && count == 0)
	timeout, timeout_rc := scalar(&reader, "PRAGMA busy_timeout")
	testing.expect(t, timeout_rc == sql.OK && timeout == 0, "initialization wait leaked into ordinary reads")
}

@(test)
test_history_batch_unsigned_boundary_and_rollback :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	for persist in ([2]bool{false, true}) {
		testing.expect_value(t, begin(&store), sql.OK)
		testing.expect_value(t, sql.exec(store.db, "INSERT INTO history_sequences VALUES(x'77',x'fffffffffffffffd')", nil, nil, nil), sql.OK)
		_, overflow := begin_history_batch(&store, "w", 3); testing.expect_value(t, overflow, sql.FULL)
		batch, status := begin_history_batch(&store, "w", 2); testing.expect_value(t, status, sql.OK)
		if status == sql.OK {
			for id in ([2]u64{1, 2}) {testing.expect_value(t, append_history_event(&store, "w", {entity_type = "edge", action = "deleted"}, {3, id}, batch = &batch), sql.OK)}
			sql.finalize(batch.insert)
		}
		if persist {testing.expect_value(t, commit(&store), sql.OK)} else {testing.expect_value(t, rollback(&store), sql.OK)}
		count, count_rc := scalar(
			&store,
			"SELECT count(*) FROM history",
		); testing.expect_value(t, count_rc, sql.OK); testing.expect_value(t, count, persist ? 2 : 0)
	}
	s, status := prepare(
		&store,
		"SELECT id,CAST(json_extract(body,'$.id') AS BLOB) FROM history ORDER BY id",
	); if !testing.expect_value(t, status, sql.OK) do return
	defer sql.finalize(s)
	for expected in ([2]u64{max(u64) - 1, max(u64)}) {
		testing.expect_value(t, sql.step(s), sql.ROW)
		id, id_rc := sql.column_id(s, 0); testing.expect_value(t, id_rc, sql.OK); testing.expect_value(t, id, expected)
		text := fmt.aprintf("%d", expected); defer delete(text)
		testing.expect_value(t, string(sql.column_bytes_view(s, 1)), text)
	}
	testing.expect_value(t, sql.step(s), sql.DONE)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, append_history_event(&store, "w", {entity_type = "edge"}, {3, 3}), sql.FULL)
	testing.expect_value(t, rollback(&store), sql.OK)
}

@(test)
test_task_reopen_workspace_and_owned_results :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	// A negative cache_size is KiB, not a count of database pages.
	cache, cache_rc := scalar(&store, "PRAGMA cache_size")
	testing.expect_value(t, cache_rc, sql.OK)
	testing.expect_value(t, cache, -4096)
	attachments := [2]pr.Attachment {
		{
			file_id = transmute([]byte)string("z-last"),
			filename = transmute([]byte)string("z.txt"),
			size = (u64(1) << 63) + 17,
			mime_type = transmute([]byte)string("text/plain"),
			uploaded_at = -17,
		},
		{
			file_id = transmute([]byte)string("a-first"),
			filename = transmute([]byte)string("a.bin"),
			size = 31,
			mime_type = transmute([]byte)string("application/octet-stream"),
			uploaded_at = 291,
		},
	}
	original := pr.Task {
		id           = (u64(1) << 63) + 255,
		title        = transmute([]byte)string("Grüße\x00'"),
		description  = transmute([]byte)string("description"),
		status       = .Note,
		order_index  = 513,
		assignee     = transmute([]byte)string("assignee"),
		priority     = 7,
		color        = .Gold,
		created_by   = transmute([]byte)string("creator"),
		created_at   = -99,
		updated_at   = 12345,
		external_ref = transmute([]byte)string("https://example.test/42"),
		due_at       = 8765,
		blocked_by   = max(u64),
		completed_at = 5432,
		completed_by = transmute([]byte)string("finisher"),
		project      = transmute([]byte)string("project"),
		attachments  = attachments[:],
	}
	testing.expect_value(t, put_task(&store, "alpha", &original), sql.MISUSE)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, put_task(&store, "alpha", &original), sql.OK)
	other := original
	other.title = transmute([]byte)string("other workspace")
	other.attachments = nil
	testing.expect_value(t, put_task(&store, "beta", &other), sql.OK)
	other.conv_id = (u64(1) << 63) + 13
	testing.expect_value(t, put_task(&store, "alpha", &other), sql.CONSTRAINT)
	testing.expect_value(t, remove_task(&store, "alpha", other.conv_id, other.id), sql.CONSTRAINT)
	private, private_found, private_rc := get_task(&store, "alpha", other.conv_id, other.id)
	defer destroy_task(&private)
	testing.expect(t, !private_found && private_rc == sql.CONSTRAINT)
	other.conv_id = 0
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	cache, cache_rc = scalar(&store, "PRAGMA cache_size")
	testing.expect_value(t, cache_rc, sql.OK)
	testing.expect_value(t, cache, -4096)
	got, found, read_rc := get_task(&store, "alpha", original.conv_id, original.id)
	if !testing.expect(t, read_rc == sql.OK && found) do return
	defer destroy_task(&got)
	expect_task(t, got, original)
	public, public_found, public_rc := get_task(&store, "beta", 0, original.id)
	defer destroy_task(&public)
	testing.expect(t, public_found && public_rc == sql.OK)
	expect_task(t, public, other)
	missing, present, missing_rc := get_task(&store, "absent", original.conv_id, original.id)
	defer destroy_task(&missing)
	testing.expect(t, !present && missing_rc == sql.OK)

	// Replacing the attachment set must not leave stale attachments; empty byte
	// fields must remain empty BLOBs rather than becoming SQL NULL.
	replacement := pr.Task {
		id      = original.id,
		conv_id = original.conv_id,
		title   = transmute([]byte)string("changed"),
	}
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, put_task(&store, "alpha", &replacement), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	changed, changed_found, changed_rc := get_task(&store, "alpha", original.conv_id, original.id)
	defer destroy_task(&changed)
	testing.expect(t, changed_found && changed_rc == sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	expect_task(t, changed, replacement)
	expect_task(t, got, original) // Still valid after another query, update and close.
}

@(test)
test_transaction_visibility_rollback_and_id_floors :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	if path == nil do return
	defer test_remove_database(dir, path)
	writer, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&writer)
	reader, reader_rc := open(path)
	if !testing.expect_value(t, reader_rc, sql.OK) do return
	defer close(&reader)
	task := pr.Task {
		id    = 11,
		title = transmute([]byte)string("committed"),
	}
	testing.expect_value(t, begin(&writer), sql.OK)
	testing.expect_value(t, put_task(&writer, "w", &task), sql.OK)
	hidden, hidden_found, hidden_rc := get_task(&reader, "w", 0, 11)
	defer destroy_task(&hidden)
	testing.expect(t, !hidden_found && hidden_rc == sql.OK, "uncommitted writes must be invisible")
	testing.expect_value(t, commit(&writer), sql.OK)
	visible, visible_found, visible_rc := get_task(&reader, "w", 0, 11)
	defer destroy_task(&visible)
	testing.expect(t, visible_found && visible_rc == sql.OK)
	expect_task(t, visible, task)

	testing.expect_value(t, begin(&writer), sql.OK)
	testing.expect_value(t, remove_task(&writer, "w", 0, 11), sql.OK)
	issued, issued_rc := next_id(&writer)
	testing.expect(t, issued_rc == sql.OK && issued == 12)
	task.id = issued
	testing.expect_value(t, put_task(&writer, "w", &task), sql.OK)
	invalid := task
	invalid.id = 0
	testing.expect_value(t, put_task(&writer, "w", &invalid), sql.CONSTRAINT)
	testing.expect_value(t, rollback(&writer), sql.OK)
	still_present, still_found, still_rc := get_task(&reader, "w", 0, 11)
	defer destroy_task(&still_present)
	testing.expect(t, still_found && still_rc == sql.OK)
	not_committed, not_found, not_rc := get_task(&reader, "w", 0, 12)
	defer destroy_task(&not_committed)
	testing.expect(t, !not_found && not_rc == sql.OK)
	testing.expect_value(t, begin(&writer), sql.OK)
	again, again_rc := next_id(&writer)
	testing.expect(t, again_rc == sql.OK && again == 12, "sequence allocation rolls back with the transaction")
	testing.expect_value(t, remove_task(&writer, "w", 0, 11), sql.OK)
	// Import floors survive deletion and must compare unsigned across 2^63.
	testing.expect_value(t, advance_floor(&writer, (u64(1) << 63) + 255), sql.OK)
	testing.expect_value(t, advance_floor(&writer, (u64(1) << 63) - 1), sql.OK)
	testing.expect_value(t, commit(&writer), sql.OK)
	testing.expect_value(t, close(&writer), sql.OK)
	writer, rc = open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, begin(&writer), sql.OK)
	next, next_rc := next_id(&writer)
	testing.expect(t, next_rc == sql.OK && next == (u64(1) << 63) + 256)
	testing.expect_value(t, advance_floor(&writer, max(u64)), sql.OK)
	_, exhausted := next_id(&writer)
	testing.expect_value(t, exhausted, sql.FULL)
	testing.expect_value(t, rollback(&writer), sql.OK)
}

@(test)
test_slice_schema_upgrade_is_explicit_and_atomic :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	if path == nil do return
	defer test_remove_database(dir, path)
	store: Store
	if !testing.expect_value(t, sql.open_v2(path, &store.db, sql.OPEN_READWRITE | sql.OPEN_CREATE, nil), sql.OK) do return
	defer close(&store)
	testing.expect_value(t, execute(&store, #load("schema.sql", string)), sql.OK)
	task := pr.Task {
		id     = max(u64),
		title  = transmute([]byte)string("preserved"),
		status = .Todo,
	}
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, put_task(&store, "upgrade", &task), sql.OK)
	testing.expect_value(t, execute(&store, "COMMIT"), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	rejected, rc := open(path)
	testing.expect(t, rc == sql.NOTADB && rejected.db == nil)
	testing.expect_value(t, sql.open_v2(path, &store.db, sql.OPEN_READWRITE, nil), sql.OK)
	// Force a DDL failure partway through, then verify rollback retains v1.
	testing.expect_value(t, execute(&store, "CREATE TABLE slice_projects(dummy INTEGER)"), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect(t, execute(&store, #load("slice_summaries.sql", string)) != sql.OK)
	testing.expect_value(t, rollback(&store), sql.OK)
	version, version_rc := scalar(&store, "PRAGMA user_version")
	testing.expect(t, version_rc == sql.OK && version == 1)
	partial, partial_rc := scalar(&store, "SELECT count(*) FROM sqlite_schema WHERE name='slice_summaries'")
	testing.expect(t, partial_rc == sql.OK && partial == 0)
	testing.expect_value(t, execute(&store, "DROP TABLE slice_projects"), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, execute(&store, #load("slice_summaries.sql", string)), sql.OK)
	testing.expect_value(t, execute(&store, "COMMIT"), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	rejected, rc = open(path)
	testing.expect(t, rc == sql.NOTADB && rejected.db == nil)
	testing.expect_value(t, sql.open_v2(path, &store.db, sql.OPEN_READWRITE, nil), sql.OK)
	// A failed v3 migration must restore the v2 tables and triggers it dropped.
	testing.expect_value(t, execute(&store, "CREATE TABLE slice_members(dummy INTEGER)"), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect(t, execute(&store, #load("slice_incremental.sql", string)) != sql.OK)
	testing.expect_value(t, rollback(&store), sql.OK)
	version, version_rc = scalar(&store, "PRAGMA user_version")
	testing.expect(t, version_rc == sql.OK && version == 2)
	partial, partial_rc = scalar(&store, "SELECT count(*) FROM sqlite_schema WHERE name IN ('slice_summaries','slice_task_update')")
	testing.expect(t, partial_rc == sql.OK && partial == 2)
	testing.expect_value(t, execute(&store, "DROP TABLE slice_members"), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, execute(&store, #load("slice_incremental.sql", string)), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	rejected, rc = open(path)
	testing.expect(t, rc == sql.NOTADB && rejected.db == nil)
	testing.expect_value(t, sql.open_v2(path, &store.db, sql.OPEN_READWRITE, nil), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, execute(&store, #load("slice_pagination.sql", string)), sql.OK)
	testing.expect_value(t, rollback(&store), sql.OK)
	version, version_rc = scalar(&store, "PRAGMA user_version")
	testing.expect(t, version_rc == sql.OK && version == 3)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, execute(&store, #load("slice_pagination.sql", string)), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	preserved, preserved_rc := scalar(
		&store,
		"SELECT count(*) FROM tasks WHERE workspace=x'75706772616465' AND id=x'ffffffffffffffff' AND title=x'707265736572766564' AND status=1",
	)
	testing.expect(t, preserved_rc == sql.OK && preserved == 1)
	check, check_rc := scalar(&store, "SELECT count(*) FROM pragma_foreign_key_check")
	testing.expect(t, check_rc == sql.OK && check == 0)
}

@(test)
test_open_requires_recognized_schema_and_explicit_creation :: proc(t: ^testing.T) {
	memory, memory_rc := open(":memory:", create = true)
	defer close(&memory)
	testing.expect(t, memory_rc == sql.ERROR && memory.db == nil, "workspace storage requires WAL support")
	dir, path := test_database_path(t)
	if path == nil do return
	defer test_remove_database(dir, path)
	missing, rc := open(path)
	testing.expect(t, rc != sql.OK && missing.db == nil)
	testing.expect(t, !os.exists(string(path)), "open without create must not create a file")
	store, create_rc := open(path, create = true)
	if !testing.expect_value(t, create_rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, execute(&store, "PRAGMA user_version=999"), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	rejected, rejected_rc := open(path, create = true)
	testing.expect(t, rejected_rc == sql.NOTADB && rejected.db == nil)
	// An unrelated database must not be adopted just because its application ID
	// and user version are zero. Verify the existing data is untouched.
	foreign_db: ^sql.Database
	testing.expect_value(t, sql.open_v2(path, &foreign_db, sql.OPEN_READWRITE, nil), sql.OK)
	defer sql.close(foreign_db)
	testing.expect_value(
		t,
		sql.exec(foreign_db, "PRAGMA application_id=0; PRAGMA user_version=0; CREATE TABLE keep_me(value); INSERT INTO keep_me VALUES (73)", nil, nil, nil),
		sql.OK,
	)
	rejected, rejected_rc = open(path, create = true)
	testing.expect(t, rejected_rc == sql.NOTADB && rejected.db == nil)
	foreign_store := Store {
		db = foreign_db,
	}
	value, value_rc := scalar(&foreign_store, "SELECT value FROM keep_me")
	testing.expect(t, value_rc == sql.OK && value == 73)
}

@(test)
test_corrupt_attachment_returns_no_partial_task :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	attachments := [2]pr.Attachment {
		{file_id = transmute([]byte)string("first"), filename = transmute([]byte)string("first.txt"), size = 15},
		{file_id = transmute([]byte)string("second"), filename = transmute([]byte)string("second.txt"), size = 27},
	}
	task := pr.Task {
		id          = 5,
		title       = transmute([]byte)string("owned title"),
		attachments = attachments[:],
	}
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, put_task(&store, "w", &task), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	// Simulate malformed persisted input after one attachment has been decoded.
	// The normal writer cannot produce this value. Memory tracking checks cleanup.
	testing.expect_value(t, execute(&store, "PRAGMA ignore_check_constraints=ON; UPDATE task_attachments SET size=x'01' WHERE ordinal=1"), sql.OK)
	got, found, read_rc := get_task(&store, "w", 0, 5)
	defer destroy_task(&got)
	testing.expect(t, read_rc == sql.CORRUPT && !found)
	testing.expect(t, got.id == 0 && len(got.title) == 0 && len(got.attachments) == 0)
	testing.expect_value(t, close(&store), sql.OK)
}

@(test)
test_workspace_schema_membership_and_projection_isolation :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	// Mixed endpoint types and unsigned IDs exercise canonical pair ordering.
	testing.expect_value(
		t,
		execute(
			&store,
			`
		INSERT INTO edges VALUES (x'61',x'0000000000000001',1,x'ffffffffffffffff',2,x'0000000000000002',7,0,x'');
		INSERT INTO edges VALUES (x'62',x'0000000000000001',2,x'0000000000000002',1,x'ffffffffffffffff',7,0,x'');
		INSERT INTO edges VALUES (x'61',x'0000000000000003',2,x'0000000000000002',1,x'ffffffffffffffff',2,0,x'');
		INSERT INTO edges VALUES (x'61',x'0000000000000004',2,x'0000000000000002',1,x'ffffffffffffffff',2,0,x'');
	`,
		),
		sql.OK,
	)
	testing.expect_value(
		t,
		execute(&store, `INSERT INTO edges VALUES (x'61',x'0000000000000002',2,x'0000000000000002',1,x'ffffffffffffffff',7,0,x'')`),
		sql.CONSTRAINT,
	)
	testing.expect_value(
		t,
		execute(
			&store,
			`
		INSERT INTO assets VALUES (x'61',x'ffffffffffffffff',5,0,zeroblob(8),x'',0,0,0,0,x'00ff',x'00ff');
		INSERT INTO assets SELECT x'62',id,asset_type,parent_type,parent_id,owner,created_at,updated_at,payload_encoding,payload_raw_len,preview,payload FROM assets;
		INSERT INTO note_tags VALUES (x'61',x'ffffffffffffffff',x'746167',3);
		INSERT INTO note_tags VALUES (x'62',x'ffffffffffffffff',x'746167',5);
		INSERT INTO asset_attachments VALUES (x'61',x'ffffffffffffffff',0,x'66',x'6e',x'ffffffffffffffff',x'',-1);
	`,
		),
		sql.OK,
	)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, execute(&store, "DELETE FROM assets WHERE workspace=x'61'"), sql.OK)
	tags, tags_rc := scalar(&store, "SELECT sum(updated_at) FROM note_tags")
	testing.expect(t, tags_rc == sql.OK && tags == 5)
	files, files_rc := scalar(&store, "SELECT count(*) FROM asset_attachments")
	testing.expect(t, files_rc == sql.OK && files == 0)
	testing.expect_value(t, rollback(&store), sql.OK)
	tags, tags_rc = scalar(&store, "SELECT sum(updated_at) FROM note_tags")
	testing.expect(t, tags_rc == sql.OK && tags == 8)
	// A revoked DM must survive reopen; membership is not inferred from history.
	testing.expect_value(t, execute(&store, "INSERT INTO dm_conversations VALUES(x'61',x'8000000000000007',x'61',x'62',0)"), sql.OK)
	testing.expect_value(t, execute(&store, "INSERT INTO dm_conversations VALUES(x'61',x'8000000000000008',x'62',x'61',3)"), sql.CONSTRAINT)
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	revoked, revoked_rc := scalar(&store, "SELECT count(*) FROM dm_conversations WHERE members=0")
	testing.expect(t, revoked_rc == sql.OK && revoked == 1)
	check, check_rc := scalar(&store, "SELECT count(*) FROM pragma_foreign_key_check")
	testing.expect(t, check_rc == sql.OK && check == 0)
}
