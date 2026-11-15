package main

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:testing"

import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

Transaction_Group_Gate :: struct {
	entered, resume: chan.Chan(bool),
}

transaction_group_test_handler :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	pointer: rawptr
	copy(([^]byte)(&pointer)[:size_of(pointer)], request.body)
	gate := (^Transaction_Group_Gate)(pointer)
	if request.request_id == 1 || request.request_id == 3 {
		chan.send(gate.entered, true); _, _ = chan.recv(gate.resume)
	}
	actual := request^; actual.body = request.body[size_of(pointer):]
	return sqlite_execute_task_command(store, &actual, output)
}

@(test)
test_transaction_group_rejection_preserves_prior_and_dependent_requests :: proc(t: ^testing.T) {
	directory, dir_err := os.make_directory_temp("", "nrc-transaction-group-*", context.allocator)
	if !testing.expect(t, dir_err == nil) do return
	defer {os.remove_all(directory); delete(directory)}
	name := fmt.aprintf("%s/shard.db", directory); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	gate: Transaction_Group_Gate
	gate.entered, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	gate.resume, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	defer chan.destroy(gate.entered)
	defer chan.destroy(gate.resume)
	pointer := rawptr(&gate)
	paths := [1]cstring{path}
	e, err := db.start_executor(paths[:], 1, 3, 64 * 1024, 8192, context.allocator, command_handler = transaction_group_test_handler)
	if !testing.expect_value(t, err, .None) do return
	p := &e.ports[0]
	first := transaction_test_task_create_body(0, .Existing, 0, 'a')
	missing := transaction_test_task_create_body(0, .Existing, 999, 'x')
	dependent := transaction_test_task_create_body(0, .Existing, 1, 'b')
	for operations, i in ([3][]pr.TransactionOperation{{{.TaskCreate, first[:]}}, {{.TaskCreate, first[:]}, {.TaskCreate, missing[:]}}, {{.TaskCreate, dependent[:]}}}) {
		wire: [1024]byte
		n := pr.serializeApplyTransactionRequest(u32(i + 1), operations, wire[:]); assert(n > 2)
		body: [1024]byte
		copy(body[:size_of(pointer)], ([^]byte)(&pointer)[:size_of(pointer)])
		copy(body[size_of(pointer):], wire[2:n])
		assert(
			db.submit(
				p,
				{
					request_id = u64(i + 1),
					operation = .Command,
					opcode = .C_ApplyTransaction,
					workspace = "w",
					subject = "alice",
					actor = "alice",
					timestamp = 123,
					body = body[:size_of(pointer) + n - 2],
				},
			),
		)
		if i == 0 {_, _ = chan.recv(gate.entered)}
	}
	db.finish_submissions(p)
	chan.send(gate.resume, true); _, _ = chan.recv(gate.entered)
	// The first success and semantic rejection share an uncommitted group.
	task, found, read_rc := db.get_task(&store, "w", 0, 1)
	testing.expect(t, read_rc == sql.OK && !found); db.destroy_task(&task)
	chan.send(gate.resume, true); db.join_executor(e)
	for i in 0 ..< 3 {
		job, ready := db.receive(p); assert(ready)
		testing.expect_value(t, job.result.status, sql.OK)
		testing.expect_value(t, job.request.request_id, u64(i + 1))
		responses := 0
		for frame in job.result.command.frames[:job.result.command.count] {
			if pr.get_opcode(frame.payload) != .S_TransactionResult do continue
			responses += 1
			expected: [64]byte
			results := [1]pr.TransactionOperationResult{{.TaskCreate, i == 0 ? 1 : 2}}
			n := pr.serializeTransactionResult(u32(i + 1), i == 1 ? .Rejected : .Committed, i == 1 ? 1 : max(u16), results[:i == 1 ? 0 : 1], expected[:])
			testing.expect_value(t, string(frame.payload), string(expected[:n]))
		}
		testing.expect_value(t, responses, 1)
		db.release_completion(p, job)
	}
	db.destroy_executor(e)
	for id in 1 ..= 3 {
		task, found, read_rc = db.get_task(&store, "w", 0, u64(id))
		testing.expect(t, read_rc == sql.OK && found == (id < 3))
		if found {
			testing.expect_value(t, string(task.title), id == 1 ? "a" : "b")
			testing.expect_value(t, task.blocked_by, id == 1 ? u64(0) : u64(1))
		}
		db.destroy_task(&task)
	}
}

worker_db_test_transaction :: proc(
	t: ^testing.T,
	c: ^NRC_Connection,
	operations: []pr.TransactionOperation,
	status: pr.TransactionResultStatus,
	failed: u16,
	ids: []u64 = nil,
) {
	buffer := make([]byte, pr.getSizeApplyTransactionRequest(operations)); defer delete(buffer)
	testing.expect_value(t, pr.serializeApplyTransactionRequest(1400, operations, buffer), len(buffer))
	process_protocol_payload(c, buffer); worker_db_test_pump(t)
	seen := false
	for send_queue_len(c) != 0 {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, h, _ := ws.readFrameHeader(frame)
		payload := frame[h:]
		if pr.get_opcode(payload) != .S_TransactionResult {
			testing.expect(t, status == .Committed && (pr.get_opcode(payload) == .S_TaskUpdated || pr.get_opcode(payload) == .S_TaskCreated))
			continue
		}
		testing.expect(t, !seen); seen = true
		results: [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionOperationResult
		for id, i in ids do results[i] = {operations[i].op_type, id}
		expected: [4096]byte
		n := pr.serializeTransactionResult(1400, status, failed, results[:len(ids)], expected[:])
		testing.expect_value(t, string(payload), string(expected[:n]))
	}
	testing.expect(t, seen)
}

worker_db_test_transactions :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks; DELETE FROM history; DELETE FROM history_sequences; UPDATE sequences SET high_water=x'0000000000000000'",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	a := transaction_test_task_create_body(0, .CreatedBy, 1, 'a')
	b := transaction_test_task_create_body(0, .Existing, 0, 'b')
	ops := [2]pr.TransactionOperation{{.TaskCreate, a[:]}, {.TaskCreate, b[:]}}
	worker_db_test_transaction(t, c, ops[:], .Committed, max(u16), {1, 2})
	first, found, read_rc := db.get_task(&store, c.workspace_id, 0, 1)
	testing.expect(t, read_rc == sql.OK && found && first.blocked_by == 2 && string(first.title) == "a")
	db.destroy_task(&first)
	// A stale guard after reserving a create ID rejects both operations.
	stale := transaction_test_delete_body(0, .Task, 1, 1)
	bad := [2]pr.TransactionOperation{{.TaskCreate, b[:]}, {.TaskDelete, stale[:]}}
	worker_db_test_transaction(t, c, bad[:], .Rejected, 1)
	worker_db_test_transaction(t, c, ops[1:], .Committed, max(u16), {3})
	// Patching the dependent before completing its blocker must not restore it.
	patch1, patch2: [256]byte
	n1 := pr.serializeTransactionTaskPatch(
		{task = {.Existing, .Task, 1}, present = pr.TRANSACTION_TASK_PATCH_DESCRIPTION, description = task_query_test_bytes("changed")},
		patch1[:],
	)
	n2 := pr.serializeTransactionTaskPatch({task = {.Existing, .Task, 2}, present = pr.TRANSACTION_TASK_PATCH_STATUS, status = .Done}, patch2[:])
	patches := [2]pr.TransactionOperation{{.TaskPatch, patch1[:n1]}, {.TaskPatch, patch2[:n2]}}
	worker_db_test_transaction(t, c, patches[:], .Committed, max(u16), {1, 2})
	first, found, read_rc = db.get_task(&store, c.workspace_id, 0, 1)
	testing.expect(t, read_rc == sql.OK && found && first.blocked_by == 0 && string(first.title) == "a" && string(first.description) == "changed")
	db.destroy_task(&first)
	// Inspect the persisted user/system history split, not helper call order.
	s: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		"SELECT count(*) FROM history WHERE entity_id=x'0000000000000001' AND json_extract(body,'$.actorId')='system' AND json_extract(body,'$.fields')='[\"blocked_by\"]'",
		-1,
		&s,
		nil,
	)
	testing.expect_value(t, rc, sql.OK)
	if rc == sql.OK {testing.expect_value(t, sql.step(s), sql.ROW); testing.expect_value(t, sql.column_int64(s, 0), i64(1)); sql.finalize(s)}
	// Invalid dependencies after ID reservation must release those IDs too.
	// A following success gets the same next ID.
	missing := transaction_test_task_create_body(0, .Existing, 999, 'm')
	bad = {{.TaskCreate, b[:]}, {.TaskCreate, missing[:]}}
	worker_db_test_transaction(t, c, bad[:], .Rejected, 1)
	worker_db_test_transaction(t, c, ops[1:], .Committed, max(u16), {4})
	// Late deletion integrity failure occurs after prepared writes and events.
	block := transaction_test_task_create_body(0, .Existing, 4, 'd')
	worker_db_test_transaction(t, c, {{.TaskCreate, block[:]}}, .Committed, max(u16), {5})
	del4 := transaction_test_delete_body(0, .Task, 4)
	bad = {{.TaskCreate, b[:]}, {.TaskDelete, del4[:]}}
	worker_db_test_transaction(t, c, bad[:], .Rejected, 1)
	worker_db_test_transaction(t, c, ops[1:], .Committed, max(u16), {6})
	// Deleting both the blocker and its dependent is legal in either order.
	del5 := transaction_test_delete_body(0, .Task, 5)
	worker_db_test_transaction(t, c, {{.TaskDelete, del4[:]}, {.TaskDelete, del5[:]}}, .Committed, max(u16), {4, 5})
	for id in ([2]u64{4, 5}) {task, exists, code := db.get_task(&store, c.workspace_id, 0, id); testing.expect(t, code == sql.OK && !exists); db.destroy_task(&task)}
	// Storage failure rolls back the already-written first task and its floor.
	testing.expect_value(
		t,
		sql.exec(store.db, "CREATE TRIGGER fail_batch BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil),
		sql.OK,
	)
	worker_db_test_transaction(t, c, ops[1:], .Rejected, 0)
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER fail_batch", nil, nil, nil), sql.OK)
	worker_db_test_transaction(t, c, ops[1:], .Committed, max(u16), {7})
	// Exhausting response credit is atomic, including the reserved create IDs.
	large: [pr.MAX_TASK_DESCRIPTION_LENGTH]byte
	create: [6000]byte
	n := pr.serializeTransactionTaskCreate({title = task_query_test_bytes("large"), description = large[:], blocked_by = {.Existing, .Task, 0}}, create[:])
	if !testing.expect(t, n > 0) do return
	worker_db_test_transaction(t, c, {{.TaskCreate, create[:n]}}, .Rejected, max(u16))
	worker_db_test_transaction(t, c, ops[1:], .Committed, max(u16), {8})
	// Task cascades retain organizer authorization and remove owned assets only
	// when the entire batch succeeds.
	appointment := pr.Asset {
		asset_id    = 100,
		asset_type  = .Appointment,
		parent_type = .Task,
		parent_id   = 8,
		owner       = task_query_test_bytes("bob"),
		preview     = task_query_test_bytes(
			`{"version":2,"title":"Series","start_at":"1730000000000000000","end_at":"1730003600000000000","timezone":"UTC","repeat":"none","weekdays":[],"until":"","participants":[],"conference":"nrc","exceptions":[],"assignee":"bob"}`,
		),
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &appointment), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	del8 := transaction_test_delete_body(0, .Task, 8)
	worker_db_test_transaction(t, c, {{.TaskCreate, b[:]}, {.TaskDelete, del8[:]}}, .Rejected, 1)
	unchanged, exists, code := db.get_task(&store, c.workspace_id, 0, 8)
	testing.expect(t, code == sql.OK && exists); db.destroy_task(&unchanged)
	absent, exists_new, absent_rc := db.get_task(&store, c.workspace_id, 0, 9)
	testing.expect(t, absent_rc == sql.OK && !exists_new); db.destroy_task(&absent)
	c.verified_username = "bob"
	worker_db_test_transaction(t, c, {{.TaskDelete, del8[:]}}, .Committed, max(u16), {8})
	c.verified_username = "alice"
	unchanged, exists, code = db.get_task(&store, c.workspace_id, 0, 8)
	testing.expect(t, code == sql.OK && !exists); db.destroy_task(&unchanged)
	rc = sql.prepare_v2(store.db, "SELECT count(*) FROM assets", -1, &s, nil)
	testing.expect_value(t, rc, sql.OK)
	if rc == sql.OK {testing.expect_value(t, sql.step(s), sql.ROW); testing.expect_value(t, sql.column_int64(s, 0), i64(0)); sql.finalize(s)}
	// Mixed creates persist only in SQLite and share one atomic result.
	mixed_body: [128]byte
	m := pr.serializeTransactionAssetCreate({asset_type = .Note, preview = task_query_test_bytes("note")}, mixed_body[:])
	if testing.expect(t, m > 0) do worker_db_test_transaction(t, c, {{.TaskCreate, b[:]}, {.AssetCreate, mixed_body[:m]}}, .Committed, max(u16), {9, 101})
	worker_db_test_transaction(t, c, ops[1:], .Committed, max(u16), {10})
	worker_db_test_transaction_records(t, c, &store)
	worker_db_test_delete_limits(t, c, &store)
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_delete_limits :: proc(t: ^testing.T, c: ^NRC_Connection, store: ^db.Store) {
	bodies: [17][28]byte
	ops: [17]pr.TransactionOperation
	ids: [17]u64
	testing.expect_value(t, db.begin(store), sql.OK)
	for i in 0 ..< 17 {
		ids[i] = u64(20000 + i)
		a := pr.Asset {
			asset_id   = ids[i],
			asset_type = .Slice,
			preview    = task_query_test_bytes(`{"version":1,"name":"limit"}`),
		}
		testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &a), sql.OK)
		bodies[i] = transaction_test_delete_body(0, .Asset, ids[i]); ops[i] = {.AssetDelete, bodies[i][:]}
	}
	testing.expect_value(t, db.commit(store), sql.OK)
	worker_db_test_transaction(t, c, ops[:], .Rejected, 16)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=17 FROM assets WHERE id>=x'0000000000004e20' AND id<=x'0000000000004e30'")
	worker_db_test_transaction(t, c, ops[:16], .Committed, max(u16), ids[:16])
	sqlite_projection_test_assert(t, store, "SELECT count(*)=1 FROM assets WHERE id>=x'0000000000004e20' AND id<=x'0000000000004e30'")
	// A single parent may not bypass the slice limit via its descendants.
	testing.expect_value(t, db.begin(store), sql.OK)
	for i in 0 ..< 18 {
		a := pr.Asset {
			asset_id    = u64(30000 + i),
			asset_type  = i == 0 ? .Note : .Slice,
			parent_type = i == 0 ? .None : .Asset,
			parent_id   = i == 0 ? 0 : 30000,
			preview     = task_query_test_bytes(`{"version":1,"name":"child"}`),
		}
		testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &a), sql.OK)
	}
	testing.expect_value(t, db.commit(store), sql.OK)
	body := transaction_test_delete_body(0, .Asset, 30000)
	worker_db_test_transaction(t, c, {{.AssetDelete, body[:]}}, .Rejected, 0)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=18 FROM assets WHERE id>=x'0000000000007530' AND id<=x'0000000000007541'")
	single: [64]byte
	n := pr.serializeDeleteAssetRequest(0, 30000, single[:], 1500)
	process_protocol_payload(c, single[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 1500)
	testing.expect_value(t, db.begin(store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM assets WHERE id=x'0000000000007541'", nil, nil, nil), sql.OK)
	last_child := pr.Asset {
		asset_id    = 30017,
		asset_type  = .Note,
		parent_type = .Asset,
		parent_id   = 30000,
	}
	testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &last_child), sql.OK)
	testing.expect_value(t, db.commit(store), sql.OK)
	process_protocol_payload(c, single[:n]); worker_db_test_pump(t)
	testing.expect_value(t, send_queue_len(c), 18)
	for send_queue_len(c) > 0 {item := send_queue_pop(c); frame_lease_dispose(&item.lease)}
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM assets WHERE id>=x'0000000000007530' AND id<=x'0000000000007541'")
	// Two individually admissible roots together exceed the record budget.
	testing.expect_value(t, db.begin(store), sql.OK)
	for id in ([2]u64{31000, 31001}) {
		a := pr.Asset {
			asset_id   = id,
			asset_type = .Note,
		}
		testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &a), sql.OK)
	}
	for i in 0 ..< 1023 {
		key := pr.Asset {
			asset_id = u64(40000 + i),
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				store,
				"INSERT INTO edges VALUES(?1,?2,1,?3,?4,?5,1,0,x'')",
				c.workspace_id,
				&key,
				{u64(31000 + i % 2), i64(i < 2 ? 1 : 2), u64(i < 2 ? 31001 : 999999)},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(store), sql.OK)
	for i in 0 ..< 2 {ids[i] = u64(31000 + i); bodies[i] = transaction_test_delete_body(0, .Asset, ids[i]); ops[i] = {.AssetDelete, bodies[i][:]}}
	worker_db_test_transaction(t, c, ops[:2], .Rejected, 1)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=1023 FROM edges WHERE id>=x'0000000000009c40' AND id<=x'000000000000a03e'")
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM history WHERE entity_id>=x'0000000000007918' AND entity_id<=x'000000000000a03e'")
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges WHERE id=x'000000000000a03e'", nil, nil, nil), sql.OK)
	worker_db_test_transaction(t, c, ops[:2], .Committed, max(u16), ids[:2])
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM edges WHERE id>=x'0000000000009c40' AND id<=x'000000000000a03e'")
	sqlite_projection_test_assert(t, store, "SELECT count(*)=1024 FROM history WHERE entity_id>=x'0000000000007918' AND entity_id<=x'000000000000a03e'")
	// A single dense root is subject to the same aggregate record limit.
	testing.expect_value(t, db.begin(store), sql.OK)
	dense := pr.Asset {
		asset_id   = 32000,
		asset_type = .Note,
	}
	testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &dense), sql.OK)
	for i in 0 ..< 1024 {
		key := pr.Asset {
			asset_id = u64(50000 + i),
		}
		testing.expect_value(
			t,
			sqlite_projection_write(store, "INSERT INTO edges VALUES(?1,?2,1,?3,2,?4,1,0,x'')", c.workspace_id, &key, {u64(32000), u64(999999)}),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(store), sql.OK)
	n = pr.serializeDeleteAssetRequest(0, 32000, single[:], 1501)
	process_protocol_payload(c, single[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 1501)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=1024 FROM edges WHERE id>=x'000000000000c350' AND id<=x'000000000000c74f'")
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges WHERE id=x'000000000000c74f'", nil, nil, nil), sql.OK)
	process_protocol_payload(c, single[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseAssetDeletedMessage(frame[offset:])
		testing.expect(t, err == nil && msg.asset_id == 32000 && msg.correlation_id == 1501)
	}
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM edges WHERE id>=x'000000000000c350' AND id<=x'000000000000c74f'")
}

worker_db_test_transaction_records :: proc(t: ^testing.T, c: ^NRC_Connection, store: ^db.Store) {
	child, parent, edge, patch: [1024]byte
	cn := pr.serializeTransactionAssetCreate(
		{
			asset_type = .Note,
			parent_type = .Asset,
			parent = {.CreatedBy, .Asset, 2},
			preview = task_query_test_bytes("child"),
			payload = task_query_test_bytes("preserved"),
			payload_raw_len = 9,
		},
		child[:],
	)
	pn := pr.serializeTransactionAssetCreate({asset_type = .Slice, preview = task_query_test_bytes(`{"version":1,"name":"Batch"}`)}, parent[:])
	en := pr.serializeTransactionEdgeCreate({source = {.CreatedBy, .Asset, 0}, target = {.CreatedBy, .Asset, 2}, relation = .MemberOf}, edge[:])
	worker_db_test_transaction(t, c, {{.AssetCreate, child[:cn]}, {.EdgeCreate, edge[:en]}, {.AssetCreate, parent[:pn]}}, .Committed, max(u16), {102, 1, 103})
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=1 FROM assets WHERE id=x'0000000000000066' AND parent_id=x'0000000000000067' AND payload=cast('preserved' AS BLOB)",
	)
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=1 FROM edges WHERE id=x'0000000000000001' AND source_id=x'0000000000000066' AND target_id=x'0000000000000067'",
	)
	// Partial patch keeps omitted payload; reversed membership is still a duplicate.
	patch_n := pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 102}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = task_query_test_bytes("changed")},
		patch[:],
	)
	worker_db_test_transaction(t, c, {{.AssetPatch, patch[:patch_n]}}, .Committed, max(u16), {102})
	en = pr.serializeTransactionEdgeCreate({source = {.Existing, .Asset, 103}, target = {.Existing, .Asset, 102}, relation = .MemberOf}, edge[:])
	worker_db_test_transaction(t, c, {{.AssetCreate, parent[:pn]}, {.EdgeCreate, edge[:en]}}, .Rejected, 1)
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=1 FROM assets WHERE id=x'0000000000000066' AND preview=cast('changed' AS BLOB) AND payload=cast('preserved' AS BLOB)",
	)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM assets WHERE id=x'0000000000000068'")
	// Replacing membership is atomic even when create precedes delete on the wire.
	del_edge := transaction_test_delete_body(0, .Edge, 1)
	worker_db_test_transaction(t, c, {{.EdgeCreate, edge[:en]}, {.EdgeDelete, del_edge[:20]}}, .Committed, max(u16), {2, 1})
	// Cyclic forward parents must roll back rows, projections, history and floors.
	cn = pr.serializeTransactionAssetCreate({asset_type = .Note, parent_type = .Asset, parent = {.CreatedBy, .Asset, 1}}, child[:])
	pn = pr.serializeTransactionAssetCreate({asset_type = .Note, parent_type = .Asset, parent = {.CreatedBy, .Asset, 0}}, parent[:])
	worker_db_test_transaction(t, c, {{.AssetCreate, child[:cn]}, {.AssetCreate, parent[:pn]}}, .Rejected, 0)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM history WHERE entity_kind=2 AND entity_id>=x'0000000000000068'")
	// Deletion closures use the initial snapshot regardless of operation order.
	del_parent := transaction_test_delete_body(0, .Asset, 103)
	del_child := transaction_test_delete_body(0, .Asset, 102)
	worker_db_test_transaction(t, c, {{.AssetPatch, patch[:patch_n]}, {.AssetDelete, del_parent[:]}}, .Rejected, 0)
	cn = pr.serializeTransactionAssetCreate({asset_type = .Note, parent_type = .Asset, parent = {.Existing, .Asset, 102}}, child[:])
	worker_db_test_transaction(t, c, {{.AssetCreate, child[:cn]}, {.AssetDelete, del_parent[:]}}, .Rejected, 0)
	del_edge = transaction_test_delete_body(0, .Edge, 2)
	worker_db_test_transaction(
		t,
		c,
		{{.AssetDelete, del_parent[:]}, {.AssetDelete, del_child[:]}, {.EdgeDelete, del_edge[:20]}},
		.Committed,
		max(u16),
		{103, 102, 2},
	)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM assets WHERE id IN (x'0000000000000066',x'0000000000000067')")
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM edges")
	pn = pr.serializeTransactionAssetCreate({asset_type = .Note}, parent[:])
	worker_db_test_transaction(t, c, {{.AssetCreate, parent[:pn]}}, .Committed, max(u16), {104})
	// Private reminders cannot be read by a different actor or acquire edges.
	pn = pr.serializeTransactionAssetCreate(
		{
			asset_type = .Reminder,
			preview = task_query_test_bytes(`{"visibility":"personal","title":"Private"}`),
			payload = task_query_test_bytes(`{"visibility":"personal"}`),
			payload_raw_len = 25,
		},
		parent[:],
	)
	worker_db_test_transaction(t, c, {{.AssetCreate, parent[:pn]}}, .Committed, max(u16), {105})
	patch_n = pr.serializeTransactionAssetPatch(
		{
			asset = {.Existing, .Asset, 105},
			present = pr.TRANSACTION_ASSET_PATCH_PREVIEW,
			preview = task_query_test_bytes(`{"visibility":"personal","title":"Changed"}`),
		},
		patch[:],
	)
	c.verified_username = "bob"
	worker_db_test_transaction(t, c, {{.AssetPatch, patch[:patch_n]}}, .Rejected, 0)
	c.verified_username = "alice"
	en = pr.serializeTransactionEdgeCreate({source = {.Existing, .Asset, 105}, target = {.Existing, .Task, 10}, relation = .RelatedTo}, edge[:])
	worker_db_test_transaction(t, c, {{.EdgeCreate, edge[:en]}}, .Rejected, 0)
	// Same numeric ID in different entity namespaces is not a duplicate mutation.
	task_body := transaction_test_task_create_body(0, .Existing, 0, 'n')
	testing.expect_value(t, db.begin(store), sql.OK)
	testing.expect_value(t, db.advance_floor(store, 104), sql.OK)
	testing.expect_value(t, db.commit(store), sql.OK)
	worker_db_test_transaction(t, c, {{.TaskCreate, task_body[:]}, {.AssetPatch, patch[:patch_n]}}, .Committed, max(u16), {105, 105})
	// A late history failure rolls back asset/projection writes and reserved IDs.
	pn = pr.serializeTransactionAssetCreate({asset_type = .Slice, preview = task_query_test_bytes(`{"version":1,"name":"Rollback"}`)}, parent[:])
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"CREATE TRIGGER fail_asset_batch BEFORE INSERT ON history WHEN NEW.entity_kind=2 BEGIN SELECT RAISE(ABORT,'fixture'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	worker_db_test_transaction(t, c, {{.AssetCreate, parent[:pn]}}, .Rejected, 0)
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER fail_asset_batch", nil, nil, nil), sql.OK)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM slice_metadata WHERE asset_id=x'000000000000006a'")
	worker_db_test_transaction(t, c, {{.AssetCreate, parent[:pn]}}, .Committed, max(u16), {106})
}

transaction_test_ref :: proc(buf: []byte, kind: pr.TransactionReferenceKind, typ: pr.TransactionEntityType, id: u64) {
	buf[0] = u8(kind); buf[1] = u8(typ); endian.put_u16(buf[2:], .Big, 0); endian.put_u64(buf[4:], .Big, id)
}

transaction_test_delete_body :: proc(conv_id: pr.ConversationID, typ: pr.TransactionEntityType, id: u64, if_updated_at: i64 = 0) -> [28]byte {
	b: [28]byte; endian.put_u64(b[:], .Big, u64(conv_id)); transaction_test_ref(b[8:], .Existing, typ, id); endian.put_u64(b[20:], .Big, u64(if_updated_at)); return b
}

transaction_test_task_create_body :: proc(conv_id: pr.ConversationID, blocked_kind: pr.TransactionReferenceKind, blocked_value: u64, title: byte) -> [41]byte {
	b: [41]byte
	endian.put_u64(b[:], .Big, u64(conv_id))
	b[8] = u8(pr.TaskStatus.Backlog)
	b[10] = u8(pr.TaskColor.None)
	transaction_test_ref(b[20:], blocked_kind, .Task, blocked_value)
	endian.put_u16(b[32:], .Big, 1)
	b[34] = title
	return b
}
