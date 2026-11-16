package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

@(test)
test_sqlite_monitor_availability_snapshot :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-availability-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	base := nrc_time_unix_nanos() - 200_000_000_000
	preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60000000000,"timeout_ns":10000000000,"failures":2,"recoveries":2,"missing":3,"webhooks":[]}`
	payload := `{"kind":"tcp"}`
	wire: [16384]byte
	n := pr.serializeCreateAssetRequest(
		{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	r := db.Request {
		opcode    = .C_CreateAsset,
		workspace = "w",
		actor     = "alice",
		timestamp = base - 1,
		body      = wire[2:n],
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	testing.expect_value(t, db.commit(&store), sql.OK)
	rows: [18]pr.Monitor_Observation
	for &row, i in rows {row = {fmt.aprintf("disk-%02d", i), 0, 42}}
	defer {for row in rows do delete(row.identity)}
	rows[0].condition = 1; rows[1].condition = 2
	n = pr.serializeApplyMonitorRunRequest({monitor_id = 1, revision = base - 1, sequence = 1, observations = rows[:]}, wire[:])
	r = {
		opcode    = .C_ApplyMonitorRun,
		workspace = "w",
		actor     = "checker",
		timestamp = base,
		body      = wire[2:n],
	}
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	testing.expect_value(t, db.begin(&store), sql.OK)
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"UPDATE monitor_instances SET paused=1 WHERE id=x'0000000000000003'; UPDATE monitor_instances SET retired=1 WHERE id=x'0000000000000004'",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	body: [44]byte
	endian.put_u32(body[:], .Big, 5)
	endian.put_u64(body[4:], .Big, 1)
	endian.put_u64(body[20:], .Big, u64(base - 1))
	endian.put_u64(body[28:], .Big, 1)
	endian.put_u64(body[36:], .Big, u64(base + 1_000_000_000))
	r = {
		opcode    = .C_GetMonitorState,
		workspace = "w",
		actor     = "checker",
		body      = body[:],
	}
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	frame := output.frames[0].payload
	count, _ := endian.get_u16(frame[54:], .Big); next, _ := endian.get_u64(frame[46:], .Big)
	testing.expect(t, count == 16 && next == 17)
	offset := 56
	for i in 0 ..< 16 {
		id, _ := endian.get_u64(frame[offset:], .Big)
		length, _ := endian.get_u16(frame[offset + 8:], .Big)
		offset += 10 + int(length)
		expected: u8 = 0
		if i == 0 do expected = 1
		if i == 1 do expected = 2
		if i == 2 do expected = 3
		testing.expect(t, frame[offset] == expected && id != 4)
		offset += 9
	}
	endian.put_u64(body[12:], .Big, next)
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	frame = output.frames[0].payload
	count, _ = endian.get_u16(frame[54:], .Big); next, _ = endian.get_u64(frame[46:], .Big)
	id, _ := endian.get_u64(frame[56:], .Big)
	testing.expect(t, count == 1 && next == 0 && id == 18)
	// Exact staleness boundary, independent of whether maintenance has run.
	endian.put_u64(body[36:], .Big, u64(base + 190_000_000_000))
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	frame = output.frames[0].payload
	length, _ := endian.get_u16(frame[64:], .Big)
	testing.expect_value(t, frame[66 + int(length)], 2)
	for which in 0 ..< 4 {
		query := r
		switch which {
		case 0:
			query.actor = "intruder"
		case 1:
			query.workspace = "other"
		case 2:
			endian.put_u64(body[20:], .Big, u64(base - 2))
		case 3:
			endian.put_u64(body[20:], .Big, u64(base - 1)); endian.put_u64(body[28:], .Big, 2)
		}
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		testing.expect_value(t, sqlite_execute_task_command(&store, &query, &output), sql.CONSTRAINT)
		testing.expect_value(t, output.count, 0)
	}
	// Commit actual lifecycle commands/new runs between pages, rather than
	// merely putting a wrong revision in an otherwise unchanged database.
	revision := base - 1
	sequence: u64 = 1
	for change in 0 ..< 3 {
		at := base + i64(192 + change * 2) * 1_000_000_000
		endian.put_u64(body[12:], .Big, 0)
		endian.put_u64(body[20:], .Big, u64(revision))
		endian.put_u64(body[28:], .Big, sequence)
		endian.put_u64(body[36:], .Big, u64(at - 1_000_000_000))
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
		cursor, _ := endian.get_u64(output.frames[0].payload[46:], .Big)
		if !testing.expect(t, cursor != 0) do return
		endian.put_u64(body[12:], .Big, cursor)
		if change < 2 {
			n = pr.serializeControlMonitorInstanceRequest({monitor_id = 1, revision = revision, instance_id = 18, action = u8(change)}, wire[:])
		} else {
			n = pr.serializeApplyMonitorRunRequest({monitor_id = 1, revision = revision, sequence = sequence + 1, observations = rows[:]}, wire[:])
		}
		mutation := db.Request {
			opcode    = pr.get_opcode(wire[:n]),
			workspace = "w",
			actor     = "checker",
			subject   = "checker",
			timestamp = at,
			body      = wire[2:n],
		}
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		testing.expect_value(t, db.begin(&store), sql.OK)
		if !testing.expect_value(t, sqlite_execute_task_command(&store, &mutation, &output), sql.OK) {db.rollback(&store); return}
		testing.expect_value(t, db.commit(&store), sql.OK)
		if change < 2 {
			ack := output.frames[output.count - 1].payload
			if !testing.expect(t, pr.get_opcode(ack) == .S_MonitorInstanceControlled) do return
			new_revision, _ := endian.get_u64(ack[22:], .Big)
			testing.expect(t, i64(new_revision) > revision)
			revision = i64(new_revision)
		} else {
			sequence += 1
		}
		// The old continuation must fail even if the affected row is on page two.
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.CONSTRAINT)
		testing.expect_value(t, output.count, 0)
		// Restart with the new fence, then read the second page and check the
		// changed instance: paused, unknown after resume, healthy after a new run.
		endian.put_u64(body[12:], .Big, 0)
		endian.put_u64(body[20:], .Big, u64(revision))
		endian.put_u64(body[28:], .Big, sequence)
		endian.put_u64(body[36:], .Big, u64(at))
		if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
		cursor, _ = endian.get_u64(output.frames[0].payload[46:], .Big)
		if !testing.expect(t, cursor != 0) do return
		endian.put_u64(body[12:], .Big, cursor)
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
		page := output.frames[0].payload
		page_count, _ := endian.get_u16(page[54:], .Big)
		position, found := 56, false
		for _ in 0 ..< int(page_count) {
			instance, _ := endian.get_u64(page[position:], .Big)
			label_len, _ := endian.get_u16(page[position + 8:], .Big)
			position += 10 + int(label_len)
			if instance == 18 {
				found = true
				expected := [3]u8{3, 2, 0}
				testing.expect_value(t, page[position], expected[change])
			}
			position += 9
		}
		testing.expect(t, found)
	}
}
