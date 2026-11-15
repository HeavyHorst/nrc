package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_query_expect :: proc(t: ^testing.T, c: ^NRC_Connection, initial: pr.TaskQueryRequest, fixtures: []pr.Task, order: []int, start := 0) {
	req := initial
	position := start
	for {
		buffer: [1024]byte
		n := pr.serializeTaskQueryRequest(req, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do return
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, header, _ := ws.readFrameHeader(frame)
		selected: [16]pr.Task
		end := min(position + int(req.limit), len(order))
		for i in position ..< end do selected[i - position] = fixtures[order[i]]
		want := pr.TaskQueryPage {
			success        = true,
			tasks          = selected[:end - position],
			total_count    = u32(len(order)),
			has_more       = end < len(order),
			correlation_id = req.correlation_id,
		}
		if end > position {
			last := selected[end - position - 1]
			want.next_cursor_task_id = last.id
			switch req.sort {
			case .Priority:
				want.next_cursor_number = i64(last.priority)
			case .Status:
				want.next_cursor_number = i64(last.status)
			case .Assignee:
				want.next_cursor_text = last.assignee
			case .DueAt:
				want.next_cursor_number = last.due_at
			case .CreatedAt:
				want.next_cursor_number = last.created_at
			case .Title:
				want.next_cursor_text = last.title
			case .Color:
				want.next_cursor_number = i64(last.color)
			case .Project:
				want.next_cursor_text = last.project
			case .WorkOrder:
				want.next_cursor_number = i64(end)
			}
		}
		encoded: [4096]byte
		written := pr.serializeTaskQueryPage(want, encoded[:]); assert(written > 0)
		testing.expect_value(t, string(frame[header:]), string(encoded[:written]))
		if !want.has_more do break
		position =
			end; req.has_cursor = true; req.cursor_number = want.next_cursor_number; req.cursor_text = want.next_cursor_text; req.cursor_task_id = want.next_cursor_task_id
	}
}

worker_db_test_task_queries :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks", nil, nil, nil), sql.OK)
	fixtures := [4]pr.Task {
		{
			id = 1,
			priority = 1,
			status = .Todo,
			assignee = task_query_test_bytes("z"),
			title = task_query_test_bytes("B"),
			color = .Red,
			project = task_query_test_bytes("z"),
			created_at = 30,
			blocked_by = 2,
		},
		{
			id = 2,
			priority = 3,
			status = .Backlog,
			assignee = task_query_test_bytes("a"),
			title = task_query_test_bytes("A"),
			color = .Cyan,
			project = task_query_test_bytes("a"),
			due_at = 20,
			created_at = 10,
		},
		{
			id = 3,
			priority = 3,
			status = .Done,
			assignee = task_query_test_bytes("a"),
			title = task_query_test_bytes("A"),
			color = .Cyan,
			project = task_query_test_bytes("b"),
			due_at = -1,
			created_at = 10,
		},
		{id = max(u64), priority = 2, status = .InProgress, title = task_query_test_bytes("Z"), due_at = 10, created_at = 20},
	}
	for &task in fixtures do testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	testing.expect_value(t, db.put_task(&store, "foreign-query", &fixtures[0]), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	ascending := [8][4]int{{0, 3, 1, 2}, {1, 0, 3, 2}, {3, 1, 2, 0}, {2, 3, 1, 0}, {1, 2, 3, 0}, {1, 2, 0, 3}, {3, 1, 2, 0}, {3, 1, 2, 0}}
	descending := [8][4]int{{1, 2, 3, 0}, {2, 3, 0, 1}, {0, 1, 2, 3}, {1, 3, 2, 0}, {0, 3, 1, 2}, {3, 0, 1, 2}, {0, 1, 2, 3}, {0, 2, 1, 3}}
	req := pr.TaskQueryRequest {
		status_mask    = 15,
		limit          = 2,
		color          = 255,
		correlation_id = 920,
	}
	for i in 0 ..< 8 {
		req.sort = pr.TaskQuerySort(i); req.descending = false
		worker_db_test_query_expect(t, c, req, fixtures[:], ascending[i][:])
		req.descending = true
		worker_db_test_query_expect(t, c, req, fixtures[:], descending[i][:])
	}
	req.sort = .Priority; req.descending = false
	req.color = u8(pr.TaskColor.Cyan); req.status_mask = 7
	worker_db_test_query_expect(t, c, req, fixtures[:], {1})
	req.status_mask = 15
	worker_db_test_query_expect(t, c, req, fixtures[:], {1, 2})
	req.color = 255
	req.has_assignee = true; req.assignee = task_query_test_bytes("a"); req.overdue_before = 21
	worker_db_test_query_expect(t, c, req, fixtures[:], {1}) // Done excluded by overdue.
	req.overdue_before = 20
	worker_db_test_query_expect(t, c, req, fixtures[:], nil) // Strict deadline boundary.
	req.overdue_before = 0; req.assignee = nil
	worker_db_test_query_expect(t, c, req, fixtures[:], {3}) // Explicit unassigned filter.
	req.has_assignee = false; req.blocked = 1
	worker_db_test_query_expect(t, c, req, fixtures[:], {0})
	req.blocked = 2; req.has_project = true; req.project = task_query_test_bytes("b")
	worker_db_test_query_expect(t, c, req, fixtures[:], {2})
	req.has_project = false; req.project = nil; req.blocked = 0; req.sort = .WorkOrder
	worker_db_test_query_expect(t, c, req, fixtures[:], {1, 3, 0, 2})
	// A newly-ready high priority child outranks existing roots. Cycles,
	// missing prerequisites and their descendants precede all Done tasks.
	work := [10]pr.Task {
		{id = 1, priority = 1},
		{id = 2},
		{id = 3, priority = 3, blocked_by = 1},
		{id = 4, blocked_by = 1},
		{id = 5, priority = 2, blocked_by = 999},
		{id = 6, priority = 3, blocked_by = 5},
		{id = 7, priority = 1, blocked_by = 8},
		{id = 8, priority = 1, blocked_by = 7},
		{id = 9, priority = 3, status = .Done},
		{id = 10, priority = 2, blocked_by = 9},
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM tasks", nil, nil, nil), sql.OK)
	for &task in work do testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	worker_db_test_query_expect(t, c, req, work[:], {9, 0, 2, 1, 3, 5, 4, 6, 7, 8})
	req.status_mask = 7 // Completed prerequisite outside result still satisfies task 10.
	worker_db_test_query_expect(t, c, req, work[:], {9, 0, 2, 1, 3, 5, 4, 6, 7})
	req.has_cursor = true; req.cursor_task_id = 1; req.cursor_number = 8
	worker_db_test_query_expect(t, c, req, work[:], {9, 0, 2, 1, 3, 5, 4, 6, 7}, start = 2)
	req.cursor_task_id = 999; req.cursor_number = 2
	worker_db_test_query_expect(t, c, req, work[:], {9, 0, 2, 1, 3, 5, 4, 6, 7}, start = 2)
	// A late surviving ID wins over a stale early numeric cursor, including
	// an empty last page. Missing IDs retain clamped numeric fallback semantics.
	req.cursor_task_id = 8; req.cursor_number = 0
	worker_db_test_query_expect(t, c, req, work[:], {9, 0, 2, 1, 3, 5, 4, 6, 7}, start = 9)
	req.cursor_task_id = 999; req.cursor_number = max(i64)
	worker_db_test_query_expect(t, c, req, work[:], {9, 0, 2, 1, 3, 5, 4, 6, 7}, start = 9)
	req.cursor_number = -1; req.limit = 1
	worker_db_test_query_expect(t, c, req, work[:], {9, 0, 2, 1, 3, 5, 4, 6, 7})
	// Slice selection must preserve both directions, endpoint types, workspace
	// isolation and external prerequisite checks across WorkOrder pages.
	testing.expect_value(t, db.begin(&store), sql.OK)
	assets := [3]pr.Asset {
		slice_test_slice_asset(77, `{"version":1,"name":"Work"}`),
		slice_test_slice_asset(78, `{"version":1,"name":"Empty"}`),
		{asset_id = 79, asset_type = .Note},
	}
	for &asset in assets do testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &asset), sql.OK)
	edges := [?]pr.Edge {
		{source_type = .Task, source_id = 3, target_type = .Asset, target_id = 77, relation = .MemberOf},
		{source_type = .Asset, source_id = 77, target_type = .Task, target_id = 10, relation = .MemberOf},
		{source_type = .Task, source_id = 5, target_type = .Asset, target_id = 77, relation = .MemberOf},
		{source_type = .Asset, source_id = 77, target_type = .Asset, target_id = 2, relation = .MemberOf},
		{source_type = .Asset, source_id = 77, target_type = .Task, target_id = 999, relation = .MemberOf},
		{source_type = .Task, source_id = 4, target_type = .Asset, target_id = 77, relation = .RelatedTo},
		{source_type = .Task, source_id = 1, target_type = .Asset, target_id = 79, relation = .MemberOf},
		{source_type = .Task, source_id = 1, target_type = .Asset, target_id = 80, relation = .MemberOf},
		{source_type = .Task, source_id = 2, target_type = .Asset, target_id = 77, relation = .MemberOf},
	}
	for edge, i in edges {
		key := pr.Asset {
			asset_id = u64(i + 1),
		}
		workspace := i == len(edges) - 1 ? "foreign-query" : c.workspace_id
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,0,x'')",
				workspace,
				&key,
				{i64(edge.source_type), edge.source_id, i64(edge.target_type), edge.target_id, i64(edge.relation)},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	req = pr.TaskQueryRequest {
		status_mask    = 7,
		sort           = .WorkOrder,
		color          = 255,
		limit          = 2,
		slice_id       = 77,
		correlation_id = 921,
	}
	worker_db_test_query_expect(t, c, req, work[:], {9, 2, 4}) // Done 9 satisfies 10; excluded Todo 1 does not satisfy 3.
	req.has_project = true; req.project = task_query_test_bytes("absent")
	worker_db_test_query_expect(t, c, req, work[:], nil)
	req.has_project = false; req.project = nil
	for slice in ([3]u64{78, 79, 80}) {
		req.slice_id = slice
		worker_db_test_query_expect(t, c, req, work[:], nil)
	}
	req.slice_id = 77
	// Failed output and rolled-back reads must not publish a cache.
	buffer: [1024]byte
	n := pr.serializeTaskQueryRequest(req, buffer[:])
	request := db.Request {
		workspace = c.workspace_id,
		opcode    = .C_QueryTasks,
		body      = buffer[2:n],
	}
	for budget in ([2]int{1, 4096}) {
		output := db.Command_Output {
			limit = budget,
		}; defer db.destroy_command_output(&output)
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), budget == 1 ? sql.TOOBIG : sql.OK)
		testing.expect_value(t, output.count, budget == 1 ? 0 : 1)
		testing.expect_value(t, db.rollback(&store), sql.OK)
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM sqlite_temp_master WHERE name LIKE 'nrc_work%'")
	}
}

task_query_test_bytes :: proc(value: string) -> []byte {return transmute([]byte)value}

task_query_cache_expect :: proc(
	t: ^testing.T,
	store: ^db.Store,
	workspace: string,
	req: pr.TaskQueryRequest,
	tasks: []pr.Task,
	total: u32,
	position: i64,
	more: bool,
) {
	own := sql.get_autocommit(store.db) != 0
	if own {if !testing.expect_value(t, db.begin(store), sql.OK) do return}
	defer if own && sql.get_autocommit(store.db) == 0 do db.rollback(store)
	body: [1024]byte
	n := pr.serializeTaskQueryRequest(req, body[:]); assert(n > 0)
	r := db.Request {
		workspace = workspace,
		opcode    = .C_QueryTasks,
		body      = body[2:n],
	}
	out := db.Command_Output {
		limit = 8192,
	}; defer db.destroy_command_output(&out)
	if !testing.expect_value(t, sqlite_execute_task_command(store, &r, &out), sql.OK) do return
	if !testing.expect_value(t, out.count, 1) do return
	want := pr.TaskQueryPage {
		success            = true,
		tasks              = tasks,
		total_count        = total,
		has_more           = more,
		correlation_id     = req.correlation_id,
		next_cursor_number = position,
	}
	if len(tasks) > 0 do want.next_cursor_task_id = tasks[len(tasks) - 1].id
	expected: [8192]byte
	size := pr.serializeTaskQueryPage(want, expected[:]); assert(size > 0)
	testing.expect_value(t, string(out.frames[0].payload), string(expected[:size]))
	if own do testing.expect_value(t, db.commit(store), sql.OK)
}

@(test)
test_work_order_cache_current_data_and_rollback :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-work-cache-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	other, other_rc := db.open(path); if !testing.expect_value(t, other_rc, sql.OK) do return
	defer db.close(&other)
	tasks := [4]pr.Task{{id = 1, priority = 1}, {id = 2, priority = 3, blocked_by = 1}, {id = 3, priority = 2}, {id = 4, status = .Done}}
	testing.expect_value(t, db.begin(&store), sql.OK)
	for &task in tasks do testing.expect_value(t, db.put_task(&store, "w", &task), sql.OK)
	testing.expect_value(t, db.put_task(&store, "other", &tasks[3]), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req := pr.TaskQueryRequest {
		status_mask    = 15,
		sort           = .WorkOrder,
		color          = 255,
		limit          = 1,
		correlation_id = 123,
	}
	task_query_cache_expect(t, &store, "w", req, tasks[2:3], 4, 1, true)
	req.has_cursor = true; req.cursor_task_id = 3; req.cursor_number = 1
	task_query_cache_expect(t, &store, "w", req, tasks[0:1], 4, 2, true)
	req.has_cursor = false; req.cursor_task_id = 0; req.cursor_number = 0
	// A different workspace/filter/limit/correlation must never reuse the wrong selection.
	task_query_cache_expect(t, &store, "other", req, tasks[3:4], 1, 1, false)
	req.status_mask = 8; req.limit = 2; req.correlation_id = 456
	task_query_cache_expect(t, &store, "w", req, tasks[3:4], 1, 1, false)
	req.status_mask = 15; req.limit = 1
	task_query_cache_expect(t, &store, "w", req, tasks[2:3], 4, 1, true)
	// Own writes invalidate, including a transaction whose cache and writes roll back together.
	testing.expect_value(t, db.begin(&store), sql.OK)
	tasks[0].priority = 3
	testing.expect_value(t, db.put_task(&store, "w", &tasks[0]), sql.OK)
	task_query_cache_expect(t, &store, "w", req, tasks[0:1], 4, 1, true)
	testing.expect_value(t, db.rollback(&store), sql.OK)
	tasks[0].priority = 1
	task_query_cache_expect(t, &store, "w", req, tasks[2:3], 4, 1, true)
	// Commit through another connection: a completed prerequisite outside the
	// selected statuses must release its child and invalidate this connection.
	req.status_mask = 7
	task_query_cache_expect(t, &store, "w", req, tasks[2:3], 3, 1, true)
	testing.expect_value(t, db.begin(&other), sql.OK)
	tasks[0].status = .Done
	testing.expect_value(t, db.put_task(&other, "w", &tasks[0]), sql.OK)
	testing.expect_value(t, db.commit(&other), sql.OK)
	task_query_cache_expect(t, &store, "w", req, tasks[1:2], 2, 1, true)
	// Reopen loses only derived state, not the result.
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	task_query_cache_expect(t, &store, "w", req, tasks[1:2], 2, 1, true)
	// Cached totals change with inserts/deletes, not merely with the first row.
	extra := pr.Task {
		id = 5,
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, "w", &extra), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	task_query_cache_expect(t, &store, "w", req, tasks[1:2], 3, 1, true)
	task_query_cache_expect(t, &store, "w", req, tasks[1:2], 3, 1, true)
	testing.expect_value(t, db.begin(&other), sql.OK)
	testing.expect_value(t, db.remove_task(&other, "w", 0, extra.id), sql.OK)
	testing.expect_value(t, db.commit(&other), sql.OK)
	task_query_cache_expect(t, &store, "w", req, tasks[1:2], 2, 1, true)
	// Membership changes invalidate even when no task row changed.
	testing.expect_value(t, db.begin(&store), sql.OK)
	slice := slice_test_slice_asset(77, `{"version":1,"name":"Cache"}`)
	testing.expect_value(t, sqlite_put_asset(&store, "w", &slice), sql.OK)
	edge := pr.Asset {
		asset_id = 1,
	}
	testing.expect_value(
		t,
		sqlite_projection_write(
			&store,
			"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,0,x'')",
			"w",
			&edge,
			{i64(pr.TargetType.Task), u64(3), i64(pr.TargetType.Asset), u64(77), i64(pr.RelationType.MemberOf)},
		),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req.slice_id = 77
	task_query_cache_expect(t, &store, "w", req, tasks[2:3], 1, 1, false)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges", nil, nil, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	task_query_cache_expect(t, &store, "w", req, nil, 0, 0, false)
	task_query_cache_expect(t, &store, "w", req, nil, 0, 0, false)
}

@(test)
test_task_projects_chunk_at_transport_boundary :: proc(t: ^testing.T) {
	labels: [1009][128]byte
	projects: [1009]string
	for &label, i in labels {
		for &b in label do b = 'x'
		label[0] = u8('A' + i / 26 / 26)
		label[1] = u8('A' + i / 26 % 26)
		label[2] = u8('A' + i % 26)
		projects[i] = string(label[:])
	}
	count := task_project_chunk_count(projects[:])
	testing.expect_value(t, count, 1008)
	first := pr.TaskProjects {
		conv_id        = 7,
		projects       = projects[:count],
		has_more       = true,
		correlation_id = 123,
	}
	last := pr.TaskProjects {
		conv_id        = 7,
		projects       = projects[count:],
		correlation_id = 123,
	}
	buf := make([]byte, MAX_PROTOCOL_PAYLOAD_SIZE)
	defer delete(buf)
	chunks := [2]pr.TaskProjects{first, last}
	for msg in chunks {
		written := pr.serializeTaskProjects(msg, buf)
		testing.expect(t, written > 0 && written <= MAX_PROTOCOL_PAYLOAD_SIZE)
		testing.expect_value(t, buf[written - 5], msg.has_more ? u8(1) : u8(0))
	}
	testing.expect_value(t, len(last.projects), 1)
	testing.expect_value(t, task_project_chunk_count(nil), 0)
}

@(test)
test_task_assignee_metadata_protocol :: proc(t: ^testing.T) {
	request := [?]byte{0, 57}
	testing.expect_value(t, pr.get_opcode(request[:]), pr.Opcode.C_ListTaskAssignees)
	testing.expect(t, is_workspace_data_opcode(.C_ListTaskAssignees))
	names := [?]string{"alex", "zoe"}
	msg := pr.TaskProjects {
		conv_id        = 0,
		projects       = names[:],
		correlation_id = 321,
	}
	buffer: [128]byte
	written := pr.serializeTaskProjects(msg, buffer[:], .S_TaskAssignees)
	testing.expect_value(t, written, 28)
	testing.expect_value(t, pr.get_opcode(buffer[:written]), pr.Opcode.S_TaskAssignees)
	testing.expect_value(t, buffer[10], u8(0))
	testing.expect_value(t, buffer[11], u8(2))
	testing.expect_value(t, string(buffer[14:18]), "alex")
	testing.expect_value(t, string(buffer[20:23]), "zoe")
	testing.expect_value(t, buffer[23], u8(0))
	testing.expect_value(t, buffer[26], u8(1))
	testing.expect_value(t, buffer[27], u8(65))
	// Calendar participants can use the full username length, beyond the
	// project codec's old cap. All person facets reuse its frame layout.
	long_name: [pr.MAX_USERNAME_LENGTH]byte
	for &b in long_name do b = 'x'
	people := [?]string{string(long_name[:])}
	msg.projects = people[:]
	person_buffer: [512]byte
	for pair in ([?][2]pr.Opcode{{.C_ListSliceOwners, .S_SliceOwners}, {.C_ListTicketAssignees, .S_TicketAssignees}, {.C_ListCalendarPeople, .S_CalendarPeople}}) {
		person_request := [?]byte{0, u8(pair[0])}
		testing.expect_value(t, pr.get_opcode(person_request[:]), pair[0])
		testing.expect(t, is_workspace_data_opcode(pair[0]))
		n := pr.serializeTaskProjects(msg, person_buffer[:], pair[1])
		testing.expect_value(t, n, 274)
		testing.expect_value(t, pr.get_opcode(person_buffer[:n]), pair[1])
	}
}
