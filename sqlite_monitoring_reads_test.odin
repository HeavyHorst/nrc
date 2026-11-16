package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

@(test)
test_sqlite_monitor_status_reads :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "nrc-status-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	store, rc := db.open(strings.clone_to_cstring(fmt.aprintf("%s/model.db", dir)), true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	execute :: proc(store: ^db.Store, output: ^db.Command_Output, wire: []byte, at: i64, actor := "alice", workspace := "w") -> c.int {
		db.destroy_command_output(output); output.limit = 1024 * 1024
		r := db.Request {
			opcode    = pr.get_opcode(wire),
			workspace = workspace,
			actor     = actor,
			subject   = actor,
			timestamp = at,
			body      = wire[2:],
		}
		if rc := db.begin(store); rc != sql.OK do return rc
		rc := sqlite_execute_task_command(store, &r, output)
		if rc != sql.OK {db.rollback(store); return rc}
		return db.commit(store)
	}
	base := nrc_time_unix_nanos() - 15_000_000_000
	wire: [pr.MAX_PROTOCOL_PAYLOAD_SIZE]byte
	for id in 1 ..< 10 {
		preview, preview_err := json.marshal(
			Monitor_Config {
				version = 1,
				name = fmt.aprintf("Monitor %d", id),
				evaluator = "checker",
				enabled = id != 6,
				interval_ns = 1_000_000_000,
				failures = 2,
				recoveries = 2,
				missing = 3,
			},
		)
		if !testing.expect(t, preview_err == nil) do return
		payload := transmute([]byte)string(`{"kind":"tcp"}`)
		n := pr.serializeCreateAssetRequest({asset_type = .Monitor, preview = preview, payload = payload, payload_raw_len = u32(len(payload))}, wire[:])
		if !testing.expect_value(t, execute(&store, &output, wire[:n], base), sql.OK) do return
		if !testing.expect_value(t, pr.get_opcode(output.frames[0].payload), .S_AssetCreated) do return
	}
	large := strings.repeat("\x01", 4090)
	rows: [20]pr.Monitor_Observation
	for &row, i in rows do row = {fmt.aprintf("%s%02d", large, i), 0, 42.25}
	for id in ([6]u64{1, 2, 3, 4, 7, 8}) {
		observations := rows[:1]
		if id != 1 do rows[0].identity = "disk"
		rows[0].condition = 0
		if id == 1 do observations = rows[:]
		if id == 2 || id == 3 do rows[0].condition = 1
		if id == 7 do rows[0].condition = 2
		if id == 4 do observations = nil
		run := pr.ApplyMonitorRunRequest {
			monitor_id   = id,
			revision     = base,
			sequence     = 1,
			failed       = id == 4,
			observations = observations,
		}
		n := pr.serializeApplyMonitorRunRequest(run, wire[:])
		if !testing.expect_value(t, execute(&store, &output, wire[:n], id == 8 ? base : base + 3_000_000_000, "checker"), sql.OK) do return
		if id == 2 {
			run.sequence = 2
			n = pr.serializeApplyMonitorRunRequest(run, wire[:])
			if !testing.expect_value(t, execute(&store, &output, wire[:n], base + 3_000_000_001, "checker"), sql.OK) do return
		}
	}
	// Manual controls preserve the run/config fence while changing visibility.
	n := pr.serializeControlMonitorInstanceRequest({monitor_id = 1, instance_id = 1, revision = base, action = 0}, wire[:])
	if !testing.expect_value(t, execute(&store, &output, wire[:n], base + 3_000_000_002), sql.OK) do return
	n = pr.serializeControlMonitorInstanceRequest({monitor_id = 1, instance_id = 2, revision = base + 3_000_000_002, action = 2}, wire[:])
	if !testing.expect_value(t, execute(&store, &output, wire[:n], base + 3_000_000_003), sql.OK) do return
	n = pr.serializeActOnIncidentRequest({incident_id = 10, revision = base + 3_000_000_001, action = 0}, wire[:])
	if !testing.expect_value(t, execute(&store, &output, wire[:n], base + 3_000_000_004), sql.OK) do return
	n = pr.serializeActOnIncidentRequest({incident_id = 10, revision = base + 3_000_000_004, action = 1, assignee = "bob"}, wire[:])
	if !testing.expect_value(t, execute(&store, &output, wire[:n], base + 3_000_000_005), sql.OK) do return
	query :: proc(
		store: ^db.Store,
		output: ^db.Command_Output,
		monitor: u64,
		at: i64,
		limit: u8,
		cursor: u64 = 0,
		rank: u8 = 0,
		retired := false,
		workspace := "w",
	) -> (
		Monitor_Status_Page,
		c.int,
	) {
		body: [33]byte
		endian.put_u16(body[:], .Big, u16(pr.Opcode.C_QueryMonitorStatus))
		endian.put_u32(body[2:], .Big, 123)
		endian.put_u64(body[6:], .Big, monitor)
		endian.put_u64(body[14:], .Big, cursor)
		body[22] = rank; endian.put_i64(body[23:], .Big, at); body[31] = limit; body[32] = retired ? 1 : 0
		rc := execute(store, output, body[:], at, "viewer", workspace)
		if rc != sql.OK do return {}, rc
		page: Monitor_Status_Page
		if len(output.frames) != 1 do return {}, sql.CORRUPT
		frame := output.frames[0].payload
		correlation, _ := endian.get_u32(frame[2:], .Big)
		if pr.get_opcode(frame) != .S_MonitorStatusPage || correlation != 123 || len(frame) > pr.MAX_PROTOCOL_PAYLOAD_SIZE do return {}, sql.CORRUPT
		if json.unmarshal(frame[6:], &page) != nil do return {}, sql.CORRUPT
		return page, sql.OK
	}
	at := base + 4_000_000_000
	page, status := query(&store, &output, 0, at, 16)
	if !testing.expect_value(t, status, sql.OK) do return
	if !testing.expect_value(t, len(page.rows), 9) do return
	expected := [9]string{"2", "3", "4", "8", "5", "9", "7", "1", "6"}
	for row, i in page.rows do testing.expect_value(t, row.id, expected[i])
	testing.expect_value(t, page.rows[0].status, "firing")
	testing.expect_value(t, page.rows[2].status, "error") // Failed run with zero instances.
	testing.expect_value(t, page.rows[3].status, "no_data") // No maintenance needed for stale display.
	testing.expect_value(t, page.rows[7].counts, ([9]u64{6 = 18, 7 = 1, 8 = 1}))
	before, before_rc := query(&store, &output, 8, base + 2_999_999_999, 16)
	after, after_rc := query(&store, &output, 8, base + 3_000_000_000, 16)
	testing.expect(t, before_rc == sql.OK && after_rc == sql.OK && before.rows[0].status == "healthy" && after.rows[0].status == "no_data")
	first, first_rc := query(&store, &output, 0, at, 1)
	testing.expect_value(t, first_rc, sql.OK)
	last_id, _ := strconv.parse_u64(first.cursor_id)
	second, second_rc := query(&store, &output, 0, at, 1, last_id, first.cursor_rank)
	testing.expect_value(t, second_rc, sql.OK)
	testing.expect(t, first.has_more && second.rows[0].id == "3")
	// Escaped 4KiB identities hit the byte cap before the requested row cap.
	seen := make(map[string]bool)
	cursor: u64; rank: u8
	for _ in 0 ..< 25 {
		part, part_rc := query(&store, &output, 1, at, 16, cursor, rank)
		if !testing.expect_value(t, part_rc, sql.OK) do return
		if !testing.expect(t, len(part.rows) > 0 && len(part.rows) < 16) do return
		for row in part.rows {
			testing.expect(t, !seen[row.id] && row.id != "2")
			seen[row.id] = true
			value, present := row.value.(f64)
			testing.expect(t, present && value == 42.25)
		}
		if !part.has_more do break
		cursor, _ = strconv.parse_u64(part.cursor_id); rank = part.cursor_rank
	}
	testing.expect_value(t, len(seen), 19)
	retired, retired_rc := query(&store, &output, 1, at, 16, 1, 7, true)
	testing.expect_value(t, retired_rc, sql.OK)
	testing.expect(t, len(retired.rows) == 1 && retired.rows[0].id == "2" && retired.rows[0].status == "retired")
	incident, incident_rc := query(&store, &output, 2, at, 16)
	testing.expect_value(t, incident_rc, sql.OK)
	testing.expect(t, len(incident.rows) == 1 && incident.rows[0].incident_open && incident.rows[0].incident_id == "10")
	testing.expect(
		t,
		incident.rows[0].acknowledged_by == "alice" &&
		incident.rows[0].assigned_to == "bob" &&
		incident.rows[0].acknowledged_at == fmt.aprintf("%d", base + 3_000_000_004),
	)
	other, other_rc := query(&store, &output, 0, at, 16, workspace = "other")
	testing.expect(t, other_rc == sql.OK && len(other.rows) == 0)
	_, denied := query(&store, &output, 1, at, 16, workspace = "other")
	testing.expect_value(t, denied, sql.CONSTRAINT)
	_, future := query(&store, &output, 0, nrc_time_unix_nanos() + 60_000_000_000, 16)
	testing.expect_value(t, future, sql.CONSTRAINT)
	// Resume does not make the retained measurement current.
	n = pr.serializeControlMonitorInstanceRequest({monitor_id = 1, instance_id = 1, revision = base + 3_000_000_003, action = 1}, wire[:])
	if !testing.expect_value(t, execute(&store, &output, wire[:n], base + 3_000_000_006), sql.OK) do return
	resumed, resumed_rc := query(&store, &output, 1, at, 1)
	testing.expect(t, resumed_rc == sql.OK && resumed.rows[0].id == "1" && resumed.rows[0].status == "unknown")
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	pre_maintenance := db.Request {
		operation = .Monitor_Maintenance,
		timestamp = base + 7_000_000_000,
	}
	if !testing.expect_value(t, db.begin(&store), sql.OK) do return
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &pre_maintenance, &output), sql.OK) do return
	if !testing.expect_value(t, db.commit(&store), sql.OK) do return
	resumed, resumed_rc = query(&store, &output, 1, at, 1)
	testing.expect(t, resumed_rc == sql.OK && resumed.rows[0].id == "1" && resumed.rows[0].status == "unknown")
	rows[0] = {fmt.aprintf("%s00", large), 0, 43}
	n = pr.serializeApplyMonitorRunRequest({monitor_id = 1, revision = base + 3_000_000_006, sequence = 2, observations = rows[:]}, wire[:])
	if !testing.expect_value(t, execute(&store, &output, wire[:n], base + 8_000_000_000, "checker"), sql.OK) do return
	at = base + 8_000_000_000
	current, current_rc := query(&store, &output, 1, at, 1)
	testing.expect(t, current_rc == sql.OK && current.rows[0].id == "1" && current.rows[0].status == "healthy")
	// Maintenance after the fixed page time must not move remaining healthy
	// rows behind a healthy cursor solely through materialized staleness.
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	maintenance := db.Request {
		operation = .Monitor_Maintenance,
		timestamp = base + 12_000_000_000,
	}
	if !testing.expect_value(t, db.begin(&store), sql.OK) do return
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &maintenance, &output), sql.OK) do return
	if !testing.expect_value(t, db.commit(&store), sql.OK) do return
	continued, continued_rc := query(&store, &output, 1, at, 1, 1, 6)
	testing.expect(t, continued_rc == sql.OK && len(continued.rows) == 1 && continued.rows[0].id == "2" && continued.rows[0].status == "healthy")
}
