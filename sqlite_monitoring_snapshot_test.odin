package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
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
	base := nrc_time_unix_nanos() - i64(200 * time.Second)
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
	// The oldest accepted snapshot survives later runs, controls, process
	// restart and clock changes. Its second page contains the original rows.
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	history: [37]byte
	endian.put_u32(history[:], .Big, 9)
	endian.put_u64(history[4:], .Big, 1)
	r = {
		opcode    = .C_MonitorHistory,
		workspace = "w",
		actor     = "checker",
		body      = history[:],
	}
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	first := output.frames[0].payload
	captured, _ := endian.get_i64(first[30:], .Big)
	next_cursor, _ := endian.get_u64(first[46:], .Big)
	saved_sequence, _ := endian.get_u64(first[22:], .Big)
	saved_id, _ := endian.get_u64(first[len(first) - 9:], .Big)
	testing.expect(t, captured == base && next_cursor == 16 && saved_sequence == 1)
	endian.put_u64(history[12:], .Big, saved_id)
	endian.put_u64(history[20:], .Big, next_cursor)
	endian.put_u64(history[28:], .Big, u64(captured))
	// Exercise the real executor's read-only handles and published lane counters.
	// Initial history polls/ACKs and delivery mutations must retain the writer.
	{
		paths := [1]cstring{path}
		executor, start_err := db.start_executor(
			paths[:],
			1,
			8,
			4 * 1024 * 1024,
			1024 * 1024,
			context.allocator,
			command_handler = sqlite_execute_task_command,
		)
		if !testing.expect_value(t, start_err, .None) do return
		defer {db.finish_submissions(&executor.ports[0]); db.join_executor(executor); db.destroy_executor(executor)}
		port := &executor.ports[0]
		for which in 0 ..< 9 {
			query := r
			query.operation = .Command
			query.request_id = u64(which + 1)
			query.timestamp = nrc_time_unix_nanos()
			reader := which == 0 || which == 4 || which == 5 || which == 6
			expected := sql.OK
			history_body := history
			delivery_wire: [128]byte
			if which <= 3 {
				if which == 1 {history_body = {}; endian.put_u64(history_body[4:], .Big, 1)}
				if which == 2 {
					endian.put_u64(history_body[12:], .Big, max(u64))
					endian.put_u64(history_body[20:], .Big, 0)
					history_body[36] = 1
				}
				query.body = history_body[:]
				if which == 3 {query.body = history_body[:36]; expected = sql.CONSTRAINT}
			} else {
				actions := [5]u8{0, 6, 7, 1, 2}
				action := actions[which - 4]
				delivery_size := pr.serializeMonitorDeliveryRequest(
					{
						monitor_id = 1,
						stream = 1,
						action = action,
						route = action == 6 ? "" : "missing",
						id = action == 2 ? 1 : 0,
						generation = action == 7 || action == 2 ? 1 : 0,
					},
					delivery_wire[:],
				)
				if !testing.expect(t, delivery_size > 2) do return
				query.opcode = .C_MonitorDelivery
				query.body = delivery_wire[2:delivery_size]
				if action == 7 || action == 2 do expected = sql.CONSTRAINT
			}
			before := db.metrics_snapshot(port)
			if !testing.expect(t, db.submit(port, query)) do return
			job: ^db.Completion
			for {
				if result, ok := db.receive(port); ok {job = result; break}
				db.rearm_completions(port)
				fds := [1]linux.Poll_Fd{{fd = port.wake.fd, events = {.IN}}}
				ready, err := linux.poll(fds[:], 5000)
				if err == .EINTR do continue
				assert(err == .NONE && ready == 1, "monitor completion timed out")
			}
			testing.expect_value(t, job.result.status, expected)
			if which == 0 && job.result.status == sql.OK {
				page := job.result.command.frames[0].payload
				page_count, _ := endian.get_u16(page[54:], .Big)
				page_at, _ := endian.get_i64(page[30:], .Big)
				testing.expect(t, page_count == 2 && page_at == captured)
			}
			db.release_completion(port, job)
			after := db.metrics_snapshot(port)
			testing.expect_value(t, after.counters[.Completed_Read] - before.counters[.Completed_Read], reader ? u64(1) : 0)
			testing.expect_value(t, after.counters[.Completed_Write] - before.counters[.Completed_Write], reader ? u64(0) : 1)
			if reader do testing.expect_value(t, after.counters[.Group_Transactions], before.counters[.Group_Transactions])
		}
	}
	when NRC_SIMULATION {
		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)
		for reversal in ([3]i64{1, 255_477, 304_914}) {
			sim.world.now = time.Duration(captured - NRC_SIM_TIME_EPOCH_NANOS - reversal)
			db.destroy_command_output(&output); output.limit = 1024 * 1024
			testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK)
		}
		sim.world.now = time.Duration(captured - NRC_SIM_TIME_EPOCH_NANOS + 600_000_000_000)
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK)
	}
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	last := output.frames[0].payload
	last_at, _ := endian.get_i64(last[30:], .Big)
	last_count, _ := endian.get_u16(last[54:], .Big)
	testing.expect(t, last_at == captured && last_count == 2)
	pos := 56
	for expected_id in ([2]u64{17, 18}) {
		instance_id, _ := endian.get_u64(last[pos:], .Big)
		size, _ := endian.get_u16(last[pos + 8:], .Big)
		pos += 10 + int(size)
		until, _ := endian.get_i64(last[pos + 1:], .Big)
		testing.expect(t, instance_id == expected_id && last[pos] == 0 && until == base + 190_000_000_000)
		pos += 9
	}
	for invalid in 0 ..< 4 {
		query := r
		switch invalid {
		case 0:
			query.actor = "intruder"
		case 1:
			query.workspace = "other"
		case 2:
			endian.put_u64(history[28:], .Big, u64(captured + 1))
		case 3:
			endian.put_u64(history[28:], .Big, u64(captured)); endian.put_u64(history[12:], .Big, 999)
		}
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		testing.expect_value(t, sqlite_execute_task_command(&store, &query, &output), sql.CONSTRAINT)
		testing.expect_value(t, output.count, 0)
	}
	endian.put_u64(history[12:], .Big, saved_id)
	endian.put_u64(history[20:], .Big, 0)
	history[36] = 1
	// A lost ACK response may be retried without deleting the following run.
	for _ in 0 ..< 2 {
		db.destroy_command_output(&output); output.limit = 1024 * 1024
		testing.expect_value(t, db.begin(&store), sql.OK)
		if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) {db.rollback(&store); return}
		testing.expect_value(t, db.commit(&store), sql.OK)
	}
	endian.put_u64(history[12:], .Big, 0)
	endian.put_u64(history[28:], .Big, 0)
	history[36] = 0
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
	remaining, _ := endian.get_u64(output.frames[0].payload[22:], .Big)
	testing.expect_value(t, remaining, 2)
	// Reject a capture on its second page, after earlier page/state writes.
	// Retrying the exact run after rollback must succeed, not replay a receipt.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"CREATE TEMP TRIGGER reject_snapshot BEFORE INSERT ON monitor_snapshots WHEN NEW.cursor!=zeroblob(8) BEGIN SELECT RAISE(ABORT,'injected'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	n = pr.serializeApplyMonitorRunRequest({monitor_id = 1, revision = revision, sequence = 3, observations = rows[:]}, wire[:])
	mutation := db.Request {
		opcode    = .C_ApplyMonitorRun,
		workspace = "w",
		actor     = "checker",
		timestamp = base + 198_000_000_000,
		body      = wire[2:n],
	}
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_execute_task_command(&store, &mutation, &output), sql.CONSTRAINT)
	testing.expect_value(t, db.rollback(&store), sql.OK)
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	state_body := history[:12]
	state_request := db.Request {
		opcode    = .C_GetMonitorState,
		workspace = "w",
		actor     = "checker",
		body      = state_body,
	}
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &state_request, &output), sql.OK) do return
	remaining, _ = endian.get_u64(output.frames[0].payload[22:], .Big)
	testing.expect_value(t, remaining, 2)
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_snapshot", nil, nil, nil), sql.OK)
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	testing.expect_value(t, db.begin(&store), sql.OK)
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &mutation, &output), sql.OK) {db.rollback(&store); return}
	testing.expect_value(t, db.commit(&store), sql.OK)
	ack := output.frames[output.count - 1].payload
	testing.expect(t, pr.get_opcode(ack) == .S_MonitorRunApplied && ack[22] == 0)
}

when NRC_SIMULATION {
	@(test)
	test_sqlite_monitor_pause_identity_with_repeated_wall_time :: proc(t: ^testing.T) {
		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)
		dir, err := os.make_directory_temp("", "nrc-pause-id-*", context.allocator)
		if !testing.expect(t, err == nil) do return
		defer {os.remove_all(dir); delete(dir)}
		name := fmt.aprintf("%s/model.db", dir); defer delete(name)
		path := strings.clone_to_cstring(name); defer delete(path)
		store, rc := db.open(path, true)
		if !testing.expect_value(t, rc, sql.OK) do return
		defer db.close(&store)
		at := nrc_time_unix_nanos()
		preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":false,"interval_ns":60000000000,"timeout_ns":10000000000,"failures":2,"recoveries":2,"missing":3,"webhooks":[]}`
		payload := `{"kind":"tcp"}`
		wire: [2048]byte
		n := pr.serializeCreateAssetRequest(
			{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
			wire[:],
		)
		output := db.Command_Output {
			limit = 1024 * 1024,
		}
		defer db.destroy_command_output(&output)
		r := db.Request {
			opcode    = .C_CreateAsset,
			workspace = "w",
			actor     = "alice",
			timestamp = at - 1,
			body      = wire[2:n],
		}
		testing.expect_value(t, db.begin(&store), sql.OK)
		if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) {db.rollback(&store); return}
		testing.expect_value(t, db.commit(&store), sql.OK)
		history: [37]byte
		endian.put_u64(history[4:], .Big, 1)
		r = {
			opcode    = .C_MonitorHistory,
			workspace = "w",
			actor     = "checker",
			body      = history[:],
		}
		previous: u64
		for capture in 0 ..< 3 {
			// Keep the simulation wall clock exactly fixed, including across reopen.
			testing.expect_value(t, nrc_time_unix_nanos(), at)
			db.destroy_command_output(&output); output.limit = 1024 * 1024
			testing.expect_value(t, db.begin(&store), sql.OK)
			if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) {db.rollback(&store); return}
			testing.expect_value(t, db.commit(&store), sql.OK)
			body := output.frames[0].payload
			id, _ := endian.get_u64(body[len(body) - 9:], .Big)
			captured_at, _ := endian.get_i64(body[30:], .Big)
			testing.expect(t, id > previous && captured_at == at && body[len(body) - 1] == 1)
			if previous != 0 {
				endian.put_u64(history[12:], .Big, previous)
				endian.put_u64(history[28:], .Big, u64(at)); history[36] = 1
				db.destroy_command_output(&output); output.limit = 1024 * 1024
				testing.expect_value(t, db.begin(&store), sql.OK)
				if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) {db.rollback(&store); return}
				testing.expect_value(t, db.commit(&store), sql.OK)
				endian.put_u64(history[12:], .Big, 0); endian.put_u64(history[28:], .Big, 0); history[36] = 0
				db.destroy_command_output(&output); output.limit = 1024 * 1024
				if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) do return
				retained, _ := endian.get_u64(output.frames[0].payload[len(output.frames[0].payload) - 9:], .Big)
				testing.expect_value(t, retained, id)
			}
			endian.put_u64(history[12:], .Big, id); endian.put_u64(history[28:], .Big, u64(at)); history[36] = 1
			db.destroy_command_output(&output); output.limit = 1024 * 1024
			testing.expect_value(t, db.begin(&store), sql.OK)
			if !testing.expect_value(t, sqlite_execute_task_command(&store, &r, &output), sql.OK) {db.rollback(&store); return}
			testing.expect_value(t, db.commit(&store), sql.OK)
			endian.put_u64(history[12:], .Big, 0); endian.put_u64(history[28:], .Big, 0); history[36] = 0
			previous = id
			if capture == 1 {
				testing.expect_value(t, db.close(&store), sql.OK)
				store, rc = db.open(path)
				if !testing.expect_value(t, rc, sql.OK) do return
			}
		}
	}
}
