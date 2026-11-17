package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Exercise the serialized domain commands and their real transaction boundary,
// not a stand-in capture implementation. Rejection must not commit partial data.
sqlite_chronicle_test_apply :: proc(store: ^db.Store, workspace: string, at: i64, wire: []byte) -> c.int {
	if len(wire) < 2 do return sql.MISUSE
	rc := db.begin(store)
	if rc != sql.OK do return rc
	out := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&out)
	r := db.Request {
		workspace = workspace,
		subject   = "human-id",
		actor     = "alice",
		timestamp = at,
		opcode    = pr.get_opcode(wire),
		body      = wire[2:],
	}
	rc = sqlite_execute_task_command(store, &r, &out)
	if rc == sql.OK do rc = db.commit(store)
	if rc != sql.OK do db.rollback(store)
	return rc
}

@(test)
test_sqlite_chronicle_capture_order_images_and_restart :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-chronicle-*", context.allocator); if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/capture.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	wire: [8192]byte
	create := pr.CreateAssetRequest {
		asset_type = .Note,
		preview    = transmute([]byte)string(`{"title":"seed"}`),
	}
	n := pr.serializeCreateAssetRequest(create, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 50, wire[:n]), sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT (SELECT count(*) FROM history)=1 AND (SELECT count(*) FROM chronicle_inputs)=0")
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.configure_chronicle(&store, {"capture"}), sql.OK)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`UPDATE sequences SET high_water=x'8000000000000000' WHERE domain='asset';
 UPDATE history_sequences SET high_water=x'8000000000000000'`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	// No backfill; exact unsigned IDs and decoded Unicode title/body.
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM chronicle_inputs")
	create.preview = transmute([]byte)string(`{"title":"\u00dcber","format":"html","tags":["secret-tag"]}`)
	create.payload = transmute([]byte)string("<p>α</p>"); create.payload_raw_len = u32(len(create.payload))
	n = pr.serializeCreateAssetRequest(create, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 100, wire[:n]), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT count(*)=1 FROM chronicle_inputs i JOIN chronicle_raw r USING(workspace,source_id)
 WHERE i.source_id=x'8000000000000001' AND note_id=x'8000000000000001' AND operation=1
 AND before_present=0 AND after_present=1 AND before_version=0 AND after_version=100
 AND before_bytes=0 AND after_bytes=14 AND captured_at=100 AND expires_at=259200000000100
 AND actor_id=x'68756d616e2d6964' AND actor_name=x'616c696365' AND length(before_hash)=0
 AND after_hash=x'7ee0e516ec5675fc90f8203609e942005288ad9c3b71a39633d324c94dfa73f4'
 AND before_title=x'' AND before_format=x'' AND before_body=x''
 AND cast(after_title AS TEXT)='Über' AND after_format=x'68746d6c' AND cast(after_body AS TEXT)='<p>α</p>'`,
	)
	update := pr.UpdateAssetRequest {
		asset_id        = (u64(1) << 63) + 1,
		preview         = transmute([]byte)string(`{"title":"Über","format":"html","project":"new","tags":["other"]}`),
		payload         = create.payload,
		payload_raw_len = create.payload_raw_len,
	}
	// Project/tags/attachment-only and encoded-but-decoded-identical changes
	// remain technical events, never extra model inputs.
	attachment := [1]pr.Attachment{{file_id = transmute([]byte)string("f"), filename = transmute([]byte)string("private.bin")}}
	update.attachments = attachment[:]
	n = pr.serializeUpdateAssetRequest(update, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 99, wire[:n]), sql.OK)
	compressed: [256]byte
	z := ZSTD_compress(raw_data(compressed[:]), len(compressed), raw_data(create.payload), uintptr(len(create.payload)), 3)
	if !testing.expect_value(t, ZSTD_isError(z), u32(0)) do return
	update.payload = compressed[:int(z)]; update.payload_encoding = .Zstd
	n = pr.serializeUpdateAssetRequest(update, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 99, wire[:n]), sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM chronicle_inputs")
	// An addition followed by its reversal is two ordered full inputs, even
	// with identical wall-clock timestamps. Versions are the canonical versions.
	update.payload_encoding = .Plain; update.payload = transmute([]byte)string("changed"); update.payload_raw_len = 7
	n = pr.serializeUpdateAssetRequest(update, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 99, wire[:n]), sql.OK)
	update.payload = create.payload; update.payload_raw_len = create.payload_raw_len
	n = pr.serializeUpdateAssetRequest(update, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 99, wire[:n]), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT count(*)=1 FROM chronicle_inputs i JOIN chronicle_raw r USING(workspace,source_id)
 WHERE source_id=x'8000000000000004' AND before_version=102 AND after_version=103
 AND cast(before_body AS TEXT)='<p>α</p>' AND after_body=x'6368616e676564'`,
	)
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT count(*)=1 FROM chronicle_inputs i JOIN chronicle_raw r USING(workspace,source_id)
 WHERE source_id=x'8000000000000005' AND before_version=103 AND after_version=104
 AND before_body=x'6368616e676564' AND cast(after_body AS TEXT)='<p>α</p>'`,
	)
	update.preview = transmute([]byte)string(`{"title":"Über","format":"markdown"}`)
	n = pr.serializeUpdateAssetRequest(update, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 99, wire[:n]), sql.OK)
	n = pr.serializeDeleteAssetRequest(0, update.asset_id, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 99, wire[:n]), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT count(*)=1 FROM chronicle_inputs i JOIN chronicle_raw r USING(workspace,source_id)
 WHERE source_id=x'8000000000000007' AND operation=3 AND before_present=1 AND after_present=0
 AND before_version=105 AND after_version=0 AND after_title=x'' AND after_format=x'' AND after_body=x''`,
	)
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT (SELECT count(*) FROM chronicle_inputs)=5 AND (SELECT count(*) FROM chronicle_raw)=5 AND (SELECT count(*) FROM assets)=1",
	)
	// Enabled restart preserves input identity and raw, advances the epoch.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.configure_chronicle(&store, {"capture"}), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT epoch=2 AND enabled=1 AND raw_bytes=(SELECT sum(byte_count) FROM chronicle_raw) FROM chronicle_workspaces",
	)
	// Disabled restart atomically gaps pending work, not the canonical note or
	// technical history; a re-enable must not reset epochs or revive old raw.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.configure_chronicle(&store, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT (SELECT count(*) FROM chronicle_raw)=0 AND (SELECT sum(input_count) FROM chronicle_gaps WHERE reason=x'64697361626c6564')=5 AND (SELECT count(*) FROM history)=8",
	)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.configure_chronicle(&store, {"capture"}), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	create.preview = nil; create.payload = nil; create.payload_raw_len = 0
	n = pr.serializeCreateAssetRequest(create, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "foreign", 200, wire[:n]), sql.OK)
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 200, wire[:n]), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT count(*)=1 FROM chronicle_inputs WHERE state=0 AND epoch=4 AND before_present=0 AND after_present=1 AND after_bytes=0 AND length(after_hash)=32`,
	)
	sqlite_projection_test_assert(t, &store, "SELECT raw_bytes=8 AND epoch=4 FROM chronicle_workspaces")
}

@(test)
test_sqlite_chronicle_quota_gaps_and_storage_rollback :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-chronicle-quota-*", context.allocator); if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/capture.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.configure_chronicle(&store, {"capture"}), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_workspaces SET raw_limit=9", nil, nil, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	wire: [8192]byte
	create := pr.CreateAssetRequest {
		asset_type      = .Note,
		payload         = transmute([]byte)string("A"),
		payload_raw_len = 1,
	}
	n := pr.serializeCreateAssetRequest(create, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 100, wire[:n]), sql.OK)
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 101, wire[:n]), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT (SELECT count(*) FROM assets)=2 AND (SELECT count(*) FROM history)=2 AND (SELECT count(*) FROM chronicle_raw)=1 AND (SELECT raw_bytes FROM chronicle_workspaces)=9",
	)
	sqlite_projection_test_assert(t, &store, "SELECT input_count=1 FROM chronicle_gaps WHERE reason=x'776f726b73706163655f71756f7461'")
	// Both the raw write and the required gap write must be durable, or the
	// complete canonical/history/ID/accounting mutation rolls back.
	for raw_failure in ([2]bool{false, true}) {
		query: cstring = `CREATE TRIGGER fail_capture BEFORE INSERT ON chronicle_gaps BEGIN SELECT RAISE(ABORT,'injected gap failure'); END;`
		if raw_failure {
			testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_workspaces SET raw_limit=1000000", nil, nil, nil), sql.OK)
			query = `CREATE TRIGGER fail_capture BEFORE INSERT ON chronicle_raw BEGIN SELECT RAISE(ABORT,'injected raw failure'); END;`
		}
		testing.expect_value(t, sql.exec(store.db, query, nil, nil, nil), sql.OK)
		before, why := sqlite_command_snapshot(&store); defer delete(before)
		if !testing.expect_value(t, why, "") do return
		testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 102, wire[:n]), sql.CONSTRAINT)
		after, after_why := sqlite_command_snapshot(&store); defer delete(after)
		testing.expect_value(t, after_why, ""); testing.expect_value(t, string(after[:]), string(before[:]))
		testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER fail_capture", nil, nil, nil), sql.OK)
	}
	// Exercise both sides near the existing wire maximum. It remains 65535
	// decoded bytes per note; the 256 KiB capture ceiling does not widen it.
	body := make([]byte, 65535); defer delete(body)
	for &b in body do b = 'x'
	compressed: [4096]byte
	for length in ([2]int{65534, 65535}) {
		z := ZSTD_compress(raw_data(compressed[:]), len(compressed), raw_data(body), uintptr(length), 3)
		if !testing.expect_value(t, ZSTD_isError(z), u32(0)) do return
		create.payload = compressed[:int(z)]; create.payload_encoding = .Zstd; create.payload_raw_len = u32(length)
		n = pr.serializeCreateAssetRequest(create, wire[:])
		if !testing.expect(t, n > 0) do return
		testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", i64(length), wire[:n]), sql.OK)
	}
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM chronicle_raw WHERE length(after_body)=65534")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM chronicle_raw WHERE length(after_body)=65535")
	create.payload = transmute([]byte)string("not-zstd"); create.payload_raw_len = 10
	n = pr.serializeCreateAssetRequest(create, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 400000, wire[:n]), sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT input_count=1 FROM chronicle_gaps WHERE reason=x'6465636f64655f6572726f72'")
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT (SELECT count(*) FROM assets)=5 AND (SELECT count(*) FROM history)=5 AND (SELECT count(*) FROM chronicle_inputs)=3 AND (SELECT count(*) FROM chronicle_raw)=3",
	)
	sqlite_projection_test_assert(t, &store, "SELECT raw_bytes=(SELECT sum(byte_count) FROM chronicle_raw) FROM chronicle_workspaces")
	// Small notes can exhaust metadata slots before the raw-byte budget. Their
	// canonical writes still succeed; consecutive gaps of one note compact.
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_workspaces SET input_limit=3", nil, nil, nil), sql.OK)
	update := pr.UpdateAssetRequest {
		asset_id        = 1,
		payload_raw_len = 1,
	}
	for text in ([3]string{"B", "C", "D"}) {
		update.payload = transmute([]byte)text
		n = pr.serializeUpdateAssetRequest(update, wire[:])
		testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 400001, wire[:n]), sql.OK)
	}
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT
 (SELECT count(*) FROM assets)=5 AND (SELECT count(*) FROM history)=8 AND
 (SELECT pending_inputs=3 FROM chronicle_workspaces) AND
 (SELECT count(*) FROM chronicle_inputs)=3 AND
 (SELECT input_count FROM chronicle_gaps WHERE reason=x'696e7075745f71756f7461')=3`,
	)
	// Ack releases both raw bytes and a metadata slot in its transaction.
	testing.expect_value(t, db.begin(&store), sql.OK)
	changed, finish_rc := db.finish_chronicle_input(&store, "capture", 1, 1, 400002, .Acknowledged)
	testing.expect(t, changed && finish_rc == sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	update.payload = transmute([]byte)string("E")
	n = pr.serializeUpdateAssetRequest(update, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 400003, wire[:n]), sql.OK)
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT
 (SELECT count(*) FROM history)=9 AND (SELECT count(*) FROM chronicle_raw)=3 AND
 (SELECT pending_inputs=3 AND raw_bytes=(SELECT sum(byte_count) FROM chronicle_raw) FROM chronicle_workspaces) AND
 (SELECT count(*) FROM chronicle_inputs WHERE state=2)=1 AND
 (SELECT input_count FROM chronicle_gaps WHERE reason=x'696e7075745f71756f7461')=3`,
	)
	// SQLite's real page ceiling produces SQLITE_FULL without filling the host
	// disk. This is a storage failure, not an AI quota gap: nothing may commit.
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_workspaces SET input_limit=100; PRAGMA max_page_count=1", nil, nil, nil), sql.OK)
	z := ZSTD_compress(raw_data(compressed[:]), len(compressed), raw_data(body), uintptr(len(body)), 3)
	if !testing.expect_value(t, ZSTD_isError(z), u32(0)) do return
	create.payload = compressed[:int(z)]; create.payload_raw_len = u32(len(body))
	n = pr.serializeCreateAssetRequest(create, wire[:])
	before_full, why_full := sqlite_command_snapshot(&store); defer delete(before_full)
	if !testing.expect_value(t, why_full, "") do return
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "capture", 400004, wire[:n]), sql.FULL)
	after_full, after_why_full := sqlite_command_snapshot(&store); defer delete(after_full)
	testing.expect_value(t, after_why_full, "")
	testing.expect_value(t, string(after_full[:]), string(before_full[:]))
}

@(test)
test_sqlite_chronicle_batch_cascade_and_late_failure :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-chronicle-cascade-*", context.allocator); if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/capture.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.configure_chronicle(&store, {"capture"}), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	b: [3][2048]byte
	n: [3]int
	n[0] = pr.serializeTransactionTaskCreate({title = transmute([]byte)string("root"), blocked_by = {.Existing, .Task, 0}}, b[0][:])
	n[1] = pr.serializeTransactionAssetCreate(
		{
			asset_type = .Note,
			parent_type = .Task,
			parent = {.CreatedBy, .Task, 0},
			preview = transmute([]byte)string(`{"title":"parent"}`),
			payload = transmute([]byte)string("first"),
			payload_raw_len = 5,
		},
		b[1][:],
	)
	n[2] = pr.serializeTransactionAssetCreate(
		{
			asset_type = .Note,
			parent_type = .Asset,
			parent = {.CreatedBy, .Asset, 1},
			preview = transmute([]byte)string(`{"title":"child"}`),
			payload = transmute([]byte)string("second"),
			payload_raw_len = 6,
		},
		b[2][:],
	)
	if !testing.expect_value(t, sqlite_command_model_apply(&store, "capture", 100, {{.TaskCreate, b[0][:n[0]]}, {.AssetCreate, b[1][:n[1]]}, {.AssetCreate, b[2][:n[2]]}}, {1, 1, 2}), "") do return
	n[0] = pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 1}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)string(`{"title":"renamed"}`)},
		b[0][:],
	)
	if !testing.expect_value(t, sqlite_command_model_apply(&store, "capture", 90, {{.AssetPatch, b[0][:n[0]]}}, {1}), "") do return
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT count(*)=1 FROM chronicle_inputs i JOIN chronicle_raw r USING(workspace,source_id)
 WHERE operation=2 AND before_title=x'706172656e74' AND after_title=x'72656e616d6564'
 AND before_body=x'6669727374' AND after_body=before_body AND before_version=100 AND after_version=101`,
	)
	// Fail on the parent AFTER the child's delete/capture has executed. The
	// existing batch SAVEPOINT must undo both, including quota accounting.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`CREATE TRIGGER fail_parent BEFORE INSERT ON chronicle_inputs
 WHEN NEW.operation=3 AND NEW.note_id=x'0000000000000001' BEGIN SELECT RAISE(ABORT,'late cascade capture failure'); END`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	n[0] = pr.serializeTransactionDelete({entity = {.Existing, .Task, 1}}, b[0][:], .Task)
	if !testing.expect_value(t, sqlite_command_model_apply(&store, "capture", 200, {{.TaskDelete, b[0][:n[0]]}}, nil, 0), "") do return
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT (SELECT count(*) FROM assets)=2 AND (SELECT count(*) FROM tasks)=1 AND (SELECT count(*) FROM chronicle_inputs)=3",
	)
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER fail_parent", nil, nil, nil), sql.OK)
	if !testing.expect_value(t, sqlite_command_model_apply(&store, "capture", 200, {{.TaskDelete, b[0][:n[0]]}}, {1}), "") do return
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT (SELECT count(*) FROM assets)=0 AND (SELECT count(*) FROM tasks)=0 AND (SELECT count(*) FROM chronicle_inputs)=5 AND (SELECT count(*) FROM chronicle_raw)=5",
	)
	sqlite_projection_test_assert(
		t,
		&store,
		`SELECT count(*)=1 FROM chronicle_inputs child JOIN chronicle_inputs parent ON child.workspace=parent.workspace
 WHERE child.operation=3 AND parent.operation=3 AND child.note_id=x'0000000000000002' AND parent.note_id=x'0000000000000001' AND child.source_id<parent.source_id`,
	)
	sqlite_projection_test_assert(t, &store, "SELECT raw_bytes=(SELECT sum(byte_count) FROM chronicle_raw) FROM chronicle_workspaces")
}
