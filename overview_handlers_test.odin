package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

// Input records for SQLite fixtures, without runtime indexes or ownership.
Overview_Test_Records :: struct {
	tasks:  map[pr.TaskID]^pr.Task,
	assets: map[pr.AssetID]^pr.Asset,
	edges:  map[pr.EdgeID]^pr.Edge,
}

overview_test_state :: proc(records: ^Overview_Test_Records) {
	records.tasks = make(map[pr.TaskID]^pr.Task)
	records.assets = make(map[pr.AssetID]^pr.Asset)
	records.edges = make(map[pr.EdgeID]^pr.Edge)
}

overview_test_destroy :: proc(records: ^Overview_Test_Records) {
	for _, edge in records.edges do free(edge)
	delete(records.edges)
	delete(records.tasks)
	delete(records.assets)
}

overview_test_add_task :: proc(records: ^Overview_Test_Records, task: ^pr.Task) {
	records.tasks[task.id] = task
}

overview_test_add_asset :: proc(records: ^Overview_Test_Records, asset: ^pr.Asset) {
	records.assets[asset.asset_id] = asset
}

overview_test_member_of :: proc(
	records: ^Overview_Test_Records,
	member_type: pr.TargetType,
	member_id: u64,
	slice_id: pr.AssetID,
	relation := pr.RelationType.MemberOf,
) {
	edge := new(pr.Edge)
	edge^ = {
		edge_id     = pr.EdgeID(len(records.edges) + 1),
		source_type = member_type,
		source_id   = member_id,
		target_type = .Asset,
		target_id   = slice_id,
		relation    = relation,
	}
	records.edges[edge.edge_id] = edge
}

overview_test_sqlite :: proc(t: ^testing.T, conv: ^Overview_Test_Records, expected: pr.WorkspaceOverview) {
	dir, err := os.make_directory_temp("", "nrc-overview-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	for _, task in conv.tasks do testing.expect_value(t, db.put_task(&store, "overview", task), sql.OK)
	for _, asset in conv.assets do testing.expect_value(t, sqlite_put_asset(&store, "overview", asset), sql.OK)
	for _, edge in conv.edges {
		key := pr.Asset {
			asset_id = edge.edge_id,
		}
		// SQLite rejects the legacy fixture's duplicate/reversed memberships.
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,0,x'') ON CONFLICT DO NOTHING",
				"overview",
				&key,
				{i64(edge.source_type), edge.source_id, i64(edge.target_type), edge.target_id, i64(edge.relation)},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	for workspace in ([2]string{"overview", "absent"}) {
		body: [12]byte
		endian.put_u32(body[8:], .Big, 319)
		request := db.Request {
			opcode    = .C_GetWorkspaceOverview,
			workspace = workspace,
			body      = body[:],
			timestamp = expected.sampled_at,
		}
		output := db.Command_Output {
			limit = 4096,
		}
		defer db.destroy_command_output(&output)
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
		testing.expect_value(t, db.commit(&store), sql.OK)
		want := workspace == "overview" ? expected : pr.WorkspaceOverview{success = true, sampled_at = expected.sampled_at}
		want.correlation_id = 319
		bytes: [105]byte
		testing.expect_value(t, pr.serializeWorkspaceOverview(want, bytes[:]), len(bytes))
		if testing.expect_value(t, output.count, 1) do testing.expect_value(t, string(output.frames[0].payload), string(bytes[:]))
	}
	// Imported invalid status values must fail, not silently disappear in SQL.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "UPDATE tasks SET status=5 WHERE id=(SELECT min(id) FROM tasks)", nil, nil, nil), sql.OK)
	bad, bad_rc := sqlite_collect_overview(&store, "overview", expected.sampled_at)
	testing.expect_value(t, bad_rc, sql.OK)
	testing.expect(t, !bad.success && len(bad.error) > 0)
	testing.expect_value(t, db.rollback(&store), sql.OK)
}

worker_db_test_overview :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks", nil, nil, nil), sql.OK)
	task := pr.Task {
		id     = max(u64),
		status = .InProgress,
	}
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	task.status = .Done
	testing.expect_value(t, db.put_task(&store, "foreign-overview", &task), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	request: [14]byte
	endian.put_u16(request[:], .Big, u16(pr.Opcode.C_GetWorkspaceOverview))
	endian.put_u32(request[10:], .Big, 320)
	process_protocol_payload(c, request[:]); worker_db_test_pump(t)
	if !testing.expect_value(t, send_queue_len(c), 1) do return
	item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
	response := frame[offset:]
	if !testing.expect_value(t, len(response), 105) do return
	at, _ := endian.get_i64(response[11:], .Big)
	testing.expect(t, at > 0)
	expected := pr.WorkspaceOverview {
		success          = true,
		sampled_at       = at,
		status_counts    = {0, 0, 1, 0},
		unassigned_tasks = 1,
		correlation_id   = 320,
	}
	bytes: [105]byte
	pr.serializeWorkspaceOverview(expected, bytes[:])
	testing.expect_value(t, string(response), string(bytes[:]))
	// Every failure must complete the overview correlation, not send a task-list
	// packet that the overview client ignores until its request timeout.
	for text, mode in ([3]string{"Access denied", "Server too busy", "Failed to read workspace overview"}) {
		c.authenticated = mode != 0
		td.database.stopping = mode == 1
		if mode == 2 do testing.expect_value(t, sql.exec(store.db, "ALTER TABLE slice_metadata RENAME TO unavailable_slice_metadata", nil, nil, nil), sql.OK)
		endian.put_u32(request[10:], .Big, u32(321 + mode))
		process_protocol_payload(c, request[:])
		c.authenticated = true; td.database.stopping = false
		worker_db_test_pump(t)
		if mode == 2 do testing.expect_value(t, sql.exec(store.db, "ALTER TABLE unavailable_slice_metadata RENAME TO slice_metadata", nil, nil, nil), sql.OK)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		failed := send_queue_pop(c); defer frame_lease_dispose(&failed.lease)
		data := frame_lease_data(failed.lease); _, header, _ := ws.readFrameHeader(data)
		want := pr.WorkspaceOverview {
			error          = transmute([]byte)text,
			correlation_id = u32(321 + mode),
		}
		error_bytes: [256]byte
		n := pr.serializeWorkspaceOverview(want, error_bytes[:])
		testing.expect_value(t, string(data[header:]), string(error_bytes[:n]))
	}
}

@(test)
test_workspace_overview_membership_and_bucket_boundaries :: proc(t: ^testing.T) {
	conv: Overview_Test_Records
	overview_test_state(&conv)
	defer overview_test_destroy(&conv)
	day :: i64(24 * 60 * 60 * 1_000_000_000)
	now :: 200 * day
	previews := [10]string {
		`{"version":1,"name":"Empty"}`,
		`{"version":1,"name":"One"}`,
		`{"version":1,"name":"Five"}`,
		`{"version":1,"name":"Six"}`,
		`{"version":1,"name":"Fifteen"}`,
		`{"version":1,"name":"Sixteen"}`,
		`{"version":1,"name":"Thirty"}`,
		`{"version":1,"name":"Thirty-one"}`,
		`{"version":1,"name":"Done only"}`,
		`{"version":1,"name":"Closed","closed":true}`,
	}
	sizes := [10]int{0, 1, 5, 6, 15, 16, 30, 31, 4, 1}
	blocked := [10]int{0, 1, 2, 3, 0, 2, 3, 0, 0, 1}
	ages := [10]i64{0, 7, 8, 30, 31, 90, 91, -1, 0, 180}
	assets: [12]pr.Asset
	tasks: [111]pr.Task
	next := 0
	for size, i in sizes {
		assets[i] = slice_test_slice_asset(pr.AssetID(i + 1), previews[i])
		overview_test_add_asset(&conv, &assets[i])
		for member in 0 ..< size {
			task := &tasks[next]
			task^ = pr.Task {
				id         = pr.TaskID(next + 1),
				status     = .Done,
				created_at = now - 199 * day,
			}
			if member == 0 && i != 8 {
				task.status = i == 9 ? .Todo : .Backlog
				task.created_at = now - ages[i] * day
				if i == 1 do task.created_at -= day / 2 // 7.5 completed days still belongs to ≤7.
			}
			if member < blocked[i] do task.blocked_by = 999
			overview_test_add_task(&conv, task)
			overview_test_member_of(&conv, .Task, u64(task.id), assets[i].asset_id)
			next += 1
		}
	}
	// Shared work and reversed edges must not change unique workspace totals.
	overview_test_member_of(&conv, .Task, 1, assets[9].asset_id)
	edge := conv.edges[pr.EdgeID(len(conv.edges))]
	edge.source_type, edge.target_type = edge.target_type, edge.source_type
	edge.source_id, edge.target_id = edge.target_id, edge.source_id
	// Persisted duplicate memberships must not push one task into the 6–15
	// size bucket or 3+ blocked bucket. Include a reversed duplicate too.
	for _ in 0 ..< 5 do overview_test_member_of(&conv, .Task, 1, assets[1].asset_id)
	duplicate := conv.edges[pr.EdgeID(len(conv.edges))]
	duplicate.source_type, duplicate.target_type = duplicate.target_type, duplicate.source_type
	duplicate.source_id, duplicate.target_id = duplicate.target_id, duplicate.source_id
	tasks[109] = pr.Task {
		id     = 110,
		status = .InProgress,
	}
	tasks[110] = pr.Task {
		id     = 111,
		status = .Note,
	}
	overview_test_add_task(&conv, &tasks[109]); overview_test_add_task(&conv, &tasks[110])
	overview_test_member_of(&conv, .Task, 111, assets[0].asset_id)
	assets[10] = pr.Asset {
		asset_id   = 11,
		asset_type = .CustomerCompany,
	}
	assets[11] = slice_test_slice_asset(12, `{"version":1,"name":""}`)
	for i in 10 ..< 12 {
		overview_test_add_asset(&conv, &assets[i])
		overview_test_member_of(&conv, .Task, 110, assets[i].asset_id)
	}
	overview_test_member_of(&conv, .Task, 110, assets[0].asset_id, .RelatedTo)
	overview_test_member_of(&conv, .Task, 9999, assets[0].asset_id) // Dangling task.

	overview_test_sqlite(
		t,
		&conv,
		{
			success = true,
			sampled_at = now,
			status_counts = {7, 1, 1, 101},
			assigned_tasks = 109,
			unassigned_tasks = 1,
			open_slices = 9,
			size_buckets = {1, 3, 2, 2, 1},
			blocked_buckets = {4, 3, 2},
			age_buckets = {2, 2, 2, 1, 2},
		},
	)
}

@(test)
test_workspace_overview_exceeds_listing_limits :: proc(t: ^testing.T) {
	conv: Overview_Test_Records
	overview_test_state(&conv)
	defer overview_test_destroy(&conv)
	// Beyond 50 maximum-size listing pages and beyond one u16 member category.
	assets := make([]pr.Asset, 50 * pr.MAX_TASK_SLICE_COUNT + 1)
	defer delete(assets)
	for &asset, i in assets {
		preview := fmt.aprintf("%s%d%s", `{"version":1,"name":"Scale `, i, `"}`)
		asset = slice_test_slice_asset(pr.AssetID(i + 1), preview)
		overview_test_add_asset(&conv, &asset)
	}
	defer for asset in assets do delete(string(asset.preview))
	tasks := make([]pr.Task, 65536)
	defer delete(tasks)
	for &task, i in tasks {
		task = pr.Task {
			id         = pr.TaskID(i + 1),
			status     = .Backlog,
			created_at = 1,
			blocked_by = 99999,
		}
		overview_test_add_task(&conv, &task)
		overview_test_member_of(&conv, .Task, u64(task.id), 1)
	}
	overview_test_sqlite(
		t,
		&conv,
		{
			success = true,
			sampled_at = 100 * 24 * 60 * 60 * 1_000_000_000,
			status_counts = {65536, 0, 0, 0},
			assigned_tasks = 65536,
			open_slices = 25601,
			size_buckets = {25600, 0, 0, 0, 1},
			blocked_buckets = {25600, 0, 1},
			age_buckets = {0, 0, 0, 1, 25600},
		},
	)
}
