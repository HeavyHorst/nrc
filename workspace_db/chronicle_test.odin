package workspace_db

import sql "../sqlite"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"

// Seed real consecutive unsigned source IDs, without asset/history FKs.
chronicle_test_seed :: proc(store: ^Store, workspace: string, count: int, expires: i64, base := u64(0x3030303030303030)) -> c.int {
	query := fmt.aprintf(
		`INSERT INTO chronicle_inputs
 (workspace,source_id,note_id,epoch,captured_at,expires_at,actor_id,actor_name,operation,
 before_present,after_present,before_version,after_version,before_bytes,after_bytes,before_hash,after_hash,state,reason)
 VALUES(x'%s',?1,x'0000000000000001',1,1,%d,x'61',x'61',1,
 0,1,0,1,0,8,x'',zeroblob(32),0,x'')`,
		workspace,
		expires,
	)
	defer delete(query)
	text := strings.clone_to_cstring(query); defer delete(text)
	s, rc := prepare(store, text); if rc != sql.OK do return rc
	defer sql.finalize(s)
	for n in 0 ..< count {
		if rc = sql.reset(s); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 1, base + u64(n) + 1); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.DONE do return rc
	}
	raw := fmt.aprintf(
		`INSERT INTO chronicle_raw SELECT workspace,source_id,x'',x'',x'',x'c3bc',x'6d61726b646f776e',x'616263646566'
 FROM chronicle_inputs WHERE workspace=x'%s'`,
		workspace,
	)
	defer delete(raw)
	return execute(store, raw)
}

@(test)
test_chronicle_expiry_before_cleaner_and_terminal_fencing :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, {"w"}), sql.OK)
	testing.expect_value(t, chronicle_test_seed(&store, "77", 3, 1001), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	buffer: [3]byte
	first :: u64(0x3030303030303031)
	second :: u64(0x3030303030303032)
	// An ongoing caller can read before expiry, but neither read nor finish at
	// the exact expiry boundary, even though the cleaner has never run.
	testing.expect_value(t, begin(&store), sql.OK)
	oversized: [CHRONICLE_CHUNK_BYTES + 1]byte
	_, _, oversized_rc := read_chronicle_chunk(&store, "w", first, 1, 1000, .After_Body, 0, oversized[:])
	testing.expect_value(t, oversized_rc, sql.MISUSE)
	n, found, read_rc := read_chronicle_chunk(&store, "w", first, 1, 1000, .After_Body, 2, buffer[:])
	testing.expect(t, read_rc == sql.OK && found && n == 3)
	testing.expect_value(t, string(buffer[:]), "cde")
	n, found, read_rc = read_chronicle_chunk(&store, "w", first, 1, 1001, .After_Body, 0, buffer[:])
	testing.expect(t, read_rc == sql.OK && !found && n == 0)
	changed, finish_rc := finish_chronicle_input(&store, "w", first, 1, 1001, .Processed)
	testing.expect(t, finish_rc == sql.OK && !changed)
	changed, finish_rc = finish_chronicle_input(&store, "w", first, 1, 1002, .Acknowledged)
	testing.expect(t, finish_rc == sql.OK && !changed)
	// Acknowledgement removes raw/accounting in the same transaction; rollback
	// restores both. An empty relevant-result Ack is not an expiry gap.
	changed, finish_rc = finish_chronicle_input(&store, "w", second, 1, 1000, .Acknowledged)
	testing.expect(t, finish_rc == sql.OK && changed)
	bytes, bytes_rc := scalar(&store, "SELECT raw_bytes FROM chronicle_workspaces")
	testing.expect(t, bytes_rc == sql.OK && bytes == 32)
	testing.expect_value(t, rollback(&store), sql.OK)
	bytes, bytes_rc = scalar(&store, "SELECT raw_bytes FROM chronicle_workspaces")
	testing.expect(t, bytes_rc == sql.OK && bytes == 48)
	testing.expect_value(t, begin(&store), sql.OK)
	changed, finish_rc = finish_chronicle_input(&store, "w", second, 1, 1000, .Acknowledged)
	testing.expect(t, finish_rc == sql.OK && changed)
	testing.expect_value(t, commit(&store), sql.OK)
	// Restart advances the processing epoch but not the raw TTL or identity.
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path); if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, {"w"}), sql.OK)
	n, found, read_rc = read_chronicle_chunk(&store, "w", first, 1, 1000, .After_Title, 0, buffer[:])
	testing.expect(t, read_rc == sql.OK && !found)
	changed, finish_rc = finish_chronicle_input(&store, "w", first, 1, 1000, .Processed)
	testing.expect(t, finish_rc == sql.OK && !changed)
	n, found, read_rc = read_chronicle_chunk(&store, "w", first, 2, 1000, .After_Title, 0, buffer[:])
	testing.expect(t, read_rc == sql.OK && found && n == 2)
	testing.expect_value(t, string(buffer[:n]), "ü")
	n, found, read_rc = read_chronicle_chunk(&store, "other", first, 2, 1000, .After_Body, 0, buffer[:])
	testing.expect(t, read_rc == sql.OK && !found)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, cleanup_chronicle(&store, 1001), sql.OK)
	kept, kept_rc := scalar(&store, "SELECT count(*) FROM chronicle_inputs WHERE state=2 AND reason=x''")
	testing.expect(t, kept_rc == sql.OK && kept == 1)
	testing.expect_value(t, execute(&store, "UPDATE chronicle_inputs SET state=0 WHERE state=2"), sql.CONSTRAINT)
	testing.expect_value(t, chronicle_test_seed(&store, "77", 1, 1001), sql.CONSTRAINT)
	// Even a backwards wall-clock cannot resurrect an already terminal input.
	testing.expect_value(t, begin(&store), sql.OK)
	n, found, read_rc = read_chronicle_chunk(&store, "w", first, 2, 1000, .After_Body, 0, buffer[:])
	testing.expect(t, read_rc == sql.OK && !found)
	changed, finish_rc = finish_chronicle_input(&store, "w", first, 2, 1000, .Processed)
	testing.expect(t, finish_rc == sql.OK && !changed)
	testing.expect_value(t, configure_chronicle(&store, nil), sql.OK)
	n, found, read_rc = read_chronicle_chunk(&store, "w", first, 3, 1000, .After_Body, 0, buffer[:])
	testing.expect(t, read_rc == sql.OK && !found)
	testing.expect_value(t, commit(&store), sql.OK)
}

@(test)
test_chronicle_cleanup_bounded_atomic_and_restart_safe :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, {"w", "x"}), sql.OK)
	testing.expect_value(t, chronicle_test_seed(&store, "77", 137, 1001), sql.OK)
	testing.expect_value(t, chronicle_test_seed(&store, "78", 2, 2000), sql.OK)
	// A successfully processed input must stay distinct, even after its expiry.
	changed, finish_rc := finish_chronicle_input(&store, "w", 0x3030303030303030 + 137, 1, 1000, .Processed)
	testing.expect(t, finish_rc == sql.OK && changed)
	testing.expect_value(t, advance_floor(&store, (u64(1) << 63) + 9, .Asset), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	// A locked database and a raw-delete failure cannot publish a partial gap
	// or release any quota. The next batch remains retryable.
	other, other_rc := open(path); if !testing.expect_value(t, other_rc, sql.OK) do return
	testing.expect_value(t, begin(&other), sql.OK)
	testing.expect_value(t, cleanup_chronicle(&store, 1001), sql.BUSY)
	testing.expect_value(t, rollback(&other), sql.OK)
	testing.expect_value(t, close(&other), sql.OK)
	testing.expect_value(
		t,
		execute(&store, "CREATE TEMP TRIGGER fail_expiry BEFORE DELETE ON main.chronicle_raw BEGIN SELECT RAISE(ABORT,'test'); END"),
		sql.OK,
	)
	testing.expect_value(t, cleanup_chronicle(&store, 1001), sql.CONSTRAINT)
	testing.expect_value(t, execute(&store, "DROP TRIGGER fail_expiry"), sql.OK)
	rows, rows_rc := scalar(&store, "SELECT count(*) FROM chronicle_gaps")
	testing.expect(t, rows_rc == sql.OK && rows == 0)
	bytes, bytes_rc := scalar(&store, "SELECT sum(raw_bytes) FROM chronicle_workspaces")
	testing.expect(t, bytes_rc == sql.OK && bytes == 2208)
	testing.expect_value(t, cleanup_chronicle(&store, 1001), sql.OK)
	rows, rows_rc = scalar(&store, "SELECT sum(input_count) FROM chronicle_gaps WHERE reason=x'74746c'")
	testing.expect(t, rows_rc == sql.OK && rows == 128)
	// Restart halfway through a backlog: the next bounded pass finishes only
	// expired inputs and leaves newer workspace data intact.
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path); if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, cleanup_chronicle(&store, 1001), sql.OK)
	testing.expect_value(t, cleanup_chronicle(&store, 1001), sql.OK)
	valid, valid_rc := scalar(
		&store,
		`SELECT
 (SELECT count(*) FROM chronicle_inputs)=3 AND
 (SELECT sum(input_count) FROM chronicle_gaps WHERE reason=x'74746c')=136 AND
 (SELECT count(*) FROM chronicle_inputs WHERE state=1)=1 AND
 (SELECT count(*) FROM chronicle_raw)=2 AND
 (SELECT raw_bytes FROM chronicle_workspaces WHERE workspace=x'77')=0 AND
 (SELECT raw_bytes FROM chronicle_workspaces WHERE workspace=x'78')=32 AND
 (SELECT high_water FROM sequences WHERE domain='asset')=x'8000000000000009'`,
	)
	testing.expect(t, valid_rc == sql.OK && valid == 1)
}

@(test)
test_chronicle_disable_backlog_cannot_revive_after_restart :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, {"w"}), sql.OK)
	testing.expect_value(t, chronicle_test_seed(&store, "77", 300, 2000), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, nil), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	left, left_rc := scalar(&store, "SELECT count(*) FROM chronicle_raw")
	testing.expect(t, left_rc == sql.OK && left == 172)
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path); if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, {"w"}), sql.OK)
	left, left_rc = scalar(&store, "SELECT count(*) FROM chronicle_raw")
	testing.expect(t, left_rc == sql.OK && left == 44)
	// This input is still pending, unexpired and physically present. A current
	// epoch must nevertheless not read/publish it after a previous disable.
	buffer: [3]byte
	n, found, read_rc := read_chronicle_chunk(&store, "w", 0x3030303030303030 + 300, 3, 1000, .After_Body, 0, buffer[:])
	testing.expect(t, read_rc == sql.OK && !found && n == 0)
	changed, finish_rc := finish_chronicle_input(&store, "w", 0x3030303030303030 + 300, 3, 1000, .Processed)
	testing.expect(t, finish_rc == sql.OK && !changed)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, cleanup_chronicle(&store, 1000), sql.OK)
	valid, valid_rc := scalar(
		&store,
		`SELECT
 (SELECT count(*) FROM chronicle_raw)=0 AND
 (SELECT sum(input_count) FROM chronicle_gaps WHERE reason=x'64697361626c6564')=300 AND
 (SELECT count(*) FROM chronicle_inputs)=0 AND
 (SELECT epoch=3 AND enabled=1 AND disabled_through_epoch=2 AND raw_bytes=0 AND pending_inputs=0 FROM chronicle_workspaces)`,
	)
	testing.expect(t, valid_rc == sql.OK && valid == 1)
}

@(test)
test_chronicle_gap_ranges_preserve_exact_sources_and_rollback :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	base :: (u64(1) << 63) - 4
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, {"w"}), sql.OK)
	testing.expect_value(t, chronicle_test_seed(&store, "77", 12, 1001, base), sql.OK)
	// A successful island, an uncaptured source hole, a different note, and a
	// different reason must all split ranges, including across signed-u64 order.
	testing.expect_value(
		t,
		execute(
			&store,
			`DELETE FROM chronicle_inputs WHERE source_id=x'8000000000000004';
 UPDATE chronicle_inputs SET note_id=x'0000000000000002' WHERE source_id=x'8000000000000006';
 UPDATE chronicle_inputs SET captured_at=-7 WHERE source_id=x'7ffffffffffffffe'`,
		),
		sql.OK,
	)
	changed, finish_rc := finish_chronicle_input(&store, "w", base + 4, 1, 1000, .Processed)
	testing.expect(t, finish_rc == sql.OK && changed)
	for offset in ([2]u64{1, 3}) {
		changed, finish_rc = finish_chronicle_input(&store, "w", base + offset, 1, 1000, .Gap, "token_limit")
		testing.expect(t, finish_rc == sql.OK && changed)
	}
	testing.expect_value(t, commit(&store), sql.OK)
	// Failure after deleting both neighbours must roll the entire merge back,
	// including raw deletion, counters and the pending-to-gap transition.
	testing.expect_value(
		t,
		execute(&store, "CREATE TEMP TRIGGER fail_merge BEFORE INSERT ON main.chronicle_gaps BEGIN SELECT RAISE(ABORT,'test'); END"),
		sql.OK,
	)
	testing.expect_value(t, begin(&store), sql.OK)
	changed, finish_rc = finish_chronicle_input(&store, "w", base + 2, 1, 1000, .Gap, "token_limit")
	testing.expect(t, finish_rc == sql.CONSTRAINT && !changed)
	testing.expect_value(t, rollback(&store), sql.OK)
	testing.expect_value(t, execute(&store, "DROP TRIGGER fail_merge"), sql.OK)
	valid, valid_rc := scalar(
		&store,
		`SELECT (SELECT count(*) FROM chronicle_gaps)=2 AND
 (SELECT sum(input_count) FROM chronicle_gaps)=2 AND
 (SELECT pending_inputs=8 AND raw_bytes=128 FROM chronicle_workspaces)`,
	)
	testing.expect(t, valid_rc == sql.OK && valid == 1)
	testing.expect_value(t, begin(&store), sql.OK)
	for offset in ([8]u64{2, 5, 6, 7, 9, 10, 11, 12}) {
		reason := offset == 12 ? "provider_error" : "token_limit"
		changed, finish_rc = finish_chronicle_input(&store, "w", base + offset, 1, 1000, .Gap, reason)
		testing.expect(t, finish_rc == sql.OK && changed)
	}
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path); if !testing.expect_value(t, rc, sql.OK) do return
	for expected in ([6]struct {
			first, last, note, count: u64,
			reason:                   string,
		}{{1, 3, 1, 3, "token_limit"}, {5, 7, 1, 3, "token_limit"}, {9, 9, 1, 1, "token_limit"}, {10, 10, 2, 1, "token_limit"}, {11, 11, 1, 1, "token_limit"}, {12, 12, 1, 1, "provider_error"}}) {
		for offset in expected.first ..= expected.last {
			gap, found, gap_rc := read_chronicle_gap(&store, "w", base + offset)
			defer delete(gap.reason)
			testing.expect(t, gap_rc == sql.OK && found)
			testing.expect_value(t, gap.first_source, base + expected.first)
			testing.expect_value(t, gap.last_source, base + expected.last)
			testing.expect_value(t, gap.note_id, expected.note)
			testing.expect_value(t, gap.input_count, i64(expected.count))
			testing.expect_value(t, gap.reason, expected.reason)
			if expected.first == 1 do testing.expect(t, gap.first_at == -7 && gap.last_at == 1)
		}
	}
	for offset in ([4]u64{0, 4, 8, 13}) {
		gap, found, gap_rc := read_chronicle_gap(&store, "w", base + offset); defer delete(gap.reason)
		testing.expect(t, gap_rc == sql.OK && !found)
	}
	gap, found, gap_rc := read_chronicle_gap(&store, "other", base + 1); defer delete(gap.reason)
	testing.expect(t, gap_rc == sql.OK && !found)
	valid, valid_rc = scalar(
		&store,
		`SELECT (SELECT count(*) FROM chronicle_gaps)=6 AND
 (SELECT sum(input_count) FROM chronicle_gaps)=10 AND
 (SELECT count(*) FROM chronicle_inputs WHERE state=1)=1 AND
 (SELECT count(*) FROM chronicle_inputs)=1 AND
 (SELECT pending_inputs=0 AND raw_bytes=0 FROM chronicle_workspaces)`,
	)
	testing.expect(t, valid_rc == sql.OK && valid == 1)
	// Compaction is not permission to reuse the terminal source ID.
	testing.expect_value(t, chronicle_test_seed(&store, "77", 1, 1001, base), sql.CONSTRAINT)
}

@(test)
test_chronicle_gap_range_bound_and_unsigned_endpoints :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, configure_chronicle(&store, {"w", "x"}), sql.OK)
	testing.expect_value(t, execute(&store, "UPDATE chronicle_workspaces SET input_limit=5000"), sql.OK)
	testing.expect_value(t, chronicle_test_seed(&store, "77", 4097, 1001, 0), sql.OK)
	testing.expect_value(t, chronicle_test_seed(&store, "78", 2, 1001, max(u64) - 2), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	for _ in 0 ..< 33 do testing.expect_value(t, cleanup_chronicle(&store, 1001), sql.OK)
	valid, valid_rc := scalar(
		&store,
		`SELECT (SELECT count(*) FROM chronicle_gaps)=3 AND
 (SELECT sum(input_count) FROM chronicle_gaps)=4099 AND
 (SELECT count(*) FROM chronicle_gaps WHERE workspace=x'77' AND input_count=4096)=1 AND
 (SELECT count(*) FROM chronicle_gaps WHERE workspace=x'77' AND input_count=1)=1 AND
 (SELECT sum(pending_inputs)+sum(raw_bytes) FROM chronicle_workspaces)=0 AND
 (SELECT count(*) FROM chronicle_inputs)=0`,
	)
	testing.expect(t, valid_rc == sql.OK && valid == 1)
	gap, found, gap_rc := read_chronicle_gap(&store, "x", max(u64)); defer delete(gap.reason)
	testing.expect(t, gap_rc == sql.OK && found && gap.first_source == max(u64) - 1 && gap.last_source == max(u64) && gap.input_count == 2)
	missing, missing_found, missing_rc := read_chronicle_gap(&store, "w", 0); defer delete(missing.reason)
	testing.expect(t, missing_rc == sql.OK && !missing_found)
}
