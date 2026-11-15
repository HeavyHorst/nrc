package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_projection_test_assert :: proc(t: ^testing.T, store: ^db.Store, query: cstring) {
	s: ^sql.Statement
	if !testing.expect_value(t, sql.prepare_v2(store.db, query, -1, &s, nil), sql.OK) do return
	defer sql.finalize(s)
	if !testing.expect_value(t, sql.step(s), sql.ROW) do return
	testing.expect(t, sql.column_int64(s, 0) == 1, string(query))
}

@(test)
test_sqlite_projection_rebuild_semantics_and_rollback :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-projections-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	fixtures := [?]struct {
		kind:             pr.AssetType,
		preview, payload: string,
	} {
		{.Note, `{"project":" alpha ","tags":[" green ","green","blue"]}`, ""},
		{.Reminder, `{"visibility":"personal","title":"preview","deadline_at":"77"}`, `{"title":"payload","deadlineAt":19}`},
		{.Reminder, `{"title":"not a fallback","deadline_at":"99"}`, `{}`},
		{.Slice, `{"version":1,"name":"Work","owner":"bob","closed_at":27}`, ""},
		{.Appointment, `{"version":1,"title":"Meet","start_at":"100","end_at":"200","assignee":"carol"}`, ""},
		{.CustomerContact, `{"version":1,"title":"Contact","email":"c@example.test","archived":false}`, ""},
		{
			.Ticket,
			`{"version":1,"title":"Ticket","assignee":"dave","status":"open","priority":"high","company_id":"","contact_id":"","requester":"","requester_name":""}`,
			"",
		},
		{.TicketEntry, `{"version":1,"kind":"customer_reply","author":"alice"}`, "reply"},
		{.RoomMapping, " #support ", ""},
		{.Note, `{"project":"must disappear","tags":[1]}`, ""},
	}
	for f, i in fixtures {
		a := pr.Asset {
			asset_id = pr.AssetID(i + 1),
		}
		// A fixture insert is not the projection under test. Rebuild reads the
		// canonical rows, and assertions below independently inspect SQL values.
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO assets VALUES(?1,?2,?3,?6,?7,x'616c696365',13,29,0,?8,?4,?5)",
				"alpha",
				&a,
				{i64(f.kind), f.preview, f.payload, i64(f.kind == .TicketEntry ? 2 : 0), u64(f.kind == .TicketEntry ? 7 : 0), i64(len(f.payload))},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, sqlite_rebuild_projections(&store), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT count(*)=1 FROM note_metadata WHERE workspace=x'616c706861' AND asset_id=x'0000000000000001' AND project=x'616c706861'",
	)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM note_tags")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM reminder_metadata WHERE personal=1 AND deadline=19 AND title=x'7061796c6f6164'")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM reminder_metadata WHERE deadline=0")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM slice_metadata WHERE owner=x'626f62' AND closed_at=27")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM appointment_metadata WHERE start_at=100 AND end_at=200")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM appointment_people WHERE person=x'6361726f6c'")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM customer_metadata WHERE active_contact=1 AND email=x'63406578616d706c652e74657374'")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM ticket_metadata WHERE assignee=x'64617665' AND priority=x'68696768'")
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT count(*)=1 FROM ticket_entry_metadata WHERE ticket_id=x'0000000000000007' AND kind=x'637573746f6d65725f7265706c79' AND created_at=13",
	)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM room_mappings WHERE name=x'535550504f5254'")
	// One canonical asset cannot acquire a second projected room name.
	testing.expect_value(
		t,
		sql.exec(store.db, "INSERT INTO room_mappings SELECT workspace,x'4f54484552',conversation_id,asset_id FROM room_mappings", nil, nil, nil),
		sql.CONSTRAINT,
	)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM note_metadata WHERE asset_id=x'000000000000000a' AND project=x''")
	// Replacing a type must discard its old index rows. Inject a failure after
	// earlier rows changed and verify that the entire rebuild rolls back.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"UPDATE assets SET asset_type=3 WHERE id=x'0000000000000001'; CREATE TRIGGER fail_projection BEFORE INSERT ON ticket_metadata BEGIN SELECT RAISE(ABORT,'test'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, sqlite_rebuild_projections(&store), sql.CONSTRAINT)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM note_tags")
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER fail_projection", nil, nil, nil), sql.OK)
	testing.expect_value(t, sqlite_rebuild_projections(&store), sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM note_tags")
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, sqlite_rebuild_projections(&store), sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM note_tags")
	// Do not resolve ambiguous aliases according to incidental SQL row order.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"INSERT INTO assets SELECT workspace,x'0000000000000010',asset_type,parent_type,parent_id,owner,created_at,updated_at,payload_encoding,payload_raw_len,preview,payload FROM assets WHERE asset_type=7",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, sqlite_rebuild_projections(&store), sql.CONSTRAINT)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM room_mappings")
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM assets WHERE id=x'0000000000000009'", nil, nil, nil), sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM room_mappings")
}
