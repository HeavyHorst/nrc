package main

import "clock"
import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import nbio "nbio/poly"
import pr "protocol"
import sql "sqlite"
import tlsf "vendor/tlsf"
import ws "websocket"
import db "workspace_db"

Worker_DB_Test_Result :: struct {
	correlation: u32,
	handle:      Connection_Handle,
	status:      c.int,
	found:       bool,
	title:       [8]byte,
}
@(thread_local)
worker_db_test_results: [128]Worker_DB_Test_Result
@(thread_local)
worker_db_test_count: int

worker_db_test_callback :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	index := worker_db_test_count
	assert(index < len(worker_db_test_results))
	worker_db_test_count += 1
	result := &worker_db_test_results[index]
	result^ = {
		correlation = correlation,
		status      = job.result.status,
		found       = job.result.found,
	}
	if c != nil do result.handle = c.handle
	copy(result.title[:], job.result.task.title)
}

worker_db_test_pump :: proc(t: ^testing.T) {
	deadline := clock.now_monotonic()
	for len(td.database.pending) > 0 {
		begin_input_turn()
		begin_presence_batch_wave()
		_ = worker_run_pre_tick()
		if len(td.database.pending) > 0 {
			testing.expect_value(t, worker_wait_io(100 * time.Millisecond), linux.Errno.NONE)
		}
		_, ok := worker_finish_callback_wave()
		testing.expect(t, ok)
		if time.diff(deadline, clock.now_monotonic()) > 5 * time.Second do testing.fail_now(t, "DB completion failed to reach the worker")
	}
}

worker_db_test_fixture :: proc(t: ^testing.T, budget_case: bool, task_handler_case := false, spool_failure_case := false) {
	// Real io_uring + DB executor, with a worker-local TLSF heap and thread-safe
	// backing allocations. No persistence initialization/replay is invoked.
	backing := context.allocator
	old_td := new(Server_Thread, backing)
	old_td^ = td
	td = {}
	defer {td = old_td^; free(old_td, backing)}
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &backing, mem.Megabyte))
	defer tlsf.destroy(&heap)
	td.backing_allocator = backing
	context.allocator = worker_heap_allocator(&heap)
	worker_state_init_core(nil, 0, 8)
	defer worker_state_destroy_core_for_test()
	td.my_pending_queue, _ = pending_queue_create(4)
	defer pending_queue_destroy(td.my_pending_queue)
	io_err := nbio.init(&td.io, ring_entries = 16, alloc = backing)
	if !testing.expect_value(t, io_err, .NONE) do return
	defer nbio.destroy(&td.io)
	directory, dir_err := os.make_directory_temp("", "nrc-worker-sqlite-*", backing)
	if !testing.expect(t, dir_err == nil) do return
	defer {os.remove_all(directory); delete(directory, backing)}
	name := fmt.aprintf("%s/shard.db", directory)
	defer delete(name)
	path := strings.clone_to_cstring(name)
	defer delete(path)
	paths: [LOGICAL_SHARD_COUNT]cstring
	paths[0] = path
	broken_name := fmt.aprintf("%s/absent/shard.db", directory)
	defer delete(broken_name)
	broken_path := strings.clone_to_cstring(broken_name)
	defer delete(broken_path)
	if task_handler_case {
		paths = {}
		shard := shard_for_workspace(transmute([]byte)string("worker-sqlite"))
		broken_shard := shard_for_workspace(transmute([]byte)string("broken"))
		assert(shard != broken_shard && shard != 0)
		paths[shard] = path
		paths[broken_shard] = broken_path
		store, rc := db.open(path, true)
		if !testing.expect_value(t, rc, sql.OK) do return
		defer db.close(&store)
		testing.expect_value(t, db.begin(&store), sql.OK)
		attachments := [1]pr.Attachment{{file_id = transmute([]byte)string("file-7"), filename = transmute([]byte)string("proof.txt"), size = 937}}
		task := pr.Task {
			id          = 7,
			title       = transmute([]byte)string("sqlite"),
			attachments = attachments[:],
		}
		testing.expect_value(t, db.put_task(&store, "worker-sqlite", &task), sql.OK)
		task.title = transmute([]byte)string("foreign")
		testing.expect_value(t, db.put_task(&store, "another-workspace", &task), sql.OK)
		task.id = 11
		testing.expect_value(t, db.put_task(&store, "another-workspace", &task), sql.OK)
		task.id = 13; task.conv_id = 77
		testing.expect_value(t, db.put_task(&store, "worker-sqlite", &task), sql.CONSTRAINT)
		task.id = 17; task.conv_id = 0
		invalid_title: [pr.MAX_TASK_TITLE_LENGTH + 1]byte
		task.title = invalid_title[:]
		testing.expect_value(t, db.put_task(&store, "worker-sqlite", &task), sql.OK)
		task.id = 19; task.title = transmute([]byte)string("large")
		large_description: [5000]byte
		task.description = large_description[:]
		testing.expect_value(t, db.put_task(&store, "worker-sqlite", &task), sql.OK)
		testing.expect_value(t, db.commit(&store), sql.OK)
	}
	capacity := budget_case ? WORKER_DB_COMPLETION_BUDGET + 1 : 2
	executor, start_err := db.start_executor(
		paths[:],
		1,
		capacity,
		mem.Megabyte,
		4096,
		backing,
		create_databases = true,
		command_handler = spool_failure_case ? worker_db_test_spool_command : sqlite_execute_task_command,
	)
	if !testing.expect_value(t, start_err, .None) do return
	defer db.destroy_executor(executor)
	worker_db_attach(&executor.ports[0])
	// Explicit ordered teardown also covers early assertions in this fixture.
	defer {
		worker_db_begin_shutdown()
		for len(td.database.pending) > 0 do _ = worker_db_drain()
		db.join_executor(executor)
		worker_db_detach()
	}
	worker_db_test_count = 0
	worker_db_test_results = {}
	c := connection_test_install_fake(
		{sock = connection_test_fake_socket(3), state = .New, workspace_id = "worker-sqlite", authenticated = true, verified_username = "alice"},
	)
	assert(c != nil)
	defer if c != nil do connection_test_uninstall(c)
	c.verified_subject = "subject-a"
	if spool_failure_case {
		worker_db_test_spool_failure(t, c, path)
		return
	}
	if task_handler_case {
		send_queue_init(c)
		c.is_sending = true // Retain actual response frames without sending a fake FD.
		worker_db_test_task_handler(t, c)
		worker_db_test_create_handler(t, c, path)
		worker_db_test_update_move(t, c, path)
		worker_db_test_history(t, c, path)
		worker_db_test_task_page(t, c, path)
		worker_db_test_task_facets(t, c, path)
		worker_db_test_record_reads(t, c, path)
		worker_db_test_asset_handlers(t, c, path)
		worker_db_test_task_dependents(t, c, path)
		worker_db_test_sqlite_edges(t, c, path)
		worker_db_test_sqlite_task_delete(t, c, path)
		worker_db_test_overview(t, c, path)
		worker_db_test_customer_search(t, c, path)
		worker_db_test_task_queries(t, c, path)
		worker_db_test_slices(t, c, path)
		worker_db_test_graph_reads(t, c, path)
		worker_db_test_calendar(t, c, path)
		worker_db_test_tickets(t, c, path)
		worker_db_test_transactions(t, c, path)
		worker_db_test_dms(t, c, path)
		worker_db_test_dm_retained(t, c, path)
		return
	}
	get := db.Request {
		operation = .Get_Task,
		workspace = "must-not-be-used",
		task_id   = 7,
	}
	if budget_case {
		// Fill the worker's drain budget across connection generations. One
		// WebSocket can no longer supply all 65 outstanding requests itself.
		for i in 0 ..< capacity {
			if i > 0 && i % 4 == 0 {
				testing.expect(t, !worker_db_submit(c, get, 999, worker_db_test_callback))
				connection_test_uninstall(c)
				c = connection_test_install_fake(
					{sock = connection_test_fake_socket(3), state = .New, workspace_id = "worker-sqlite", authenticated = true, verified_username = "alice"},
				)
				assert(c != nil)
				c.verified_subject = "subject-a"
			}
			testing.expect(t, worker_db_submit(c, get, u32(i + 1), worker_db_test_callback))
		}
		testing.expect(t, !worker_db_submit(c, get, 999, worker_db_test_callback))
		worker_db_begin_shutdown()
		testing.expect(t, !worker_db_submit(c, get, 998, worker_db_test_callback))
		db.join_executor(executor) // All completions ready, including the next batch.
		_, wave_ok := worker_finish_callback_wave()
		testing.expect(t, wave_ok)
		testing.expect_value(t, worker_db_test_count, WORKER_DB_COMPLETION_BUDGET)
		fds := [1]linux.Poll_Fd{{fd = worker_db_wake_fd(), events = {.IN}}}
		n, err := linux.poll(fds[:], 0)
		testing.expect(t, n == 1 && err == .NONE, "budget yield must preserve a readable completion wake")
		connection_test_uninstall(c); c = nil
		_server_thread_shutdown(nil)
		testing.expect_value(t, worker_db_test_count, capacity)
		for result, i in worker_db_test_results[:capacity] {
			testing.expect(t, result.correlation == u32(i + 1) && result.status == sql.OK && result.handle == {})
		}
		testing.expect(t, td.database.port == nil && executor.ports[0].in_flight == 0)
		return
	}

	// Put then Get share a queue, even when both finish before the first tick.
	put := db.Request {
		operation = .Put_Task,
		task = pr.Task{id = 7, title = transmute([]byte)string("sqlite")},
	}
	testing.expect(t, worker_db_submit(c, put, 41, worker_db_test_callback))
	testing.expect(t, worker_db_submit(c, get, 93, worker_db_test_callback))
	testing.expect(t, !worker_db_submit(c, get, 999, worker_db_test_callback))
	worker_db_test_pump(t)
	testing.expect_value(t, worker_db_test_count, 2)
	testing.expect(t, worker_db_test_results[0].correlation == 41 && worker_db_test_results[0].status == sql.OK)
	result := worker_db_test_results[1]
	testing.expect(t, result.correlation == 93 && result.handle == c.handle && result.status == sql.OK && result.found)
	testing.expect_value(t, string(result.title[:6]), "sqlite")
	testing.expect(t, len(td.workspaces) == 0, "DB reads must not populate workspace entity maps")

	// Delay consumption until after the original handle is destroyed and its FD
	// reused by the same authenticated identity. FD-only routing would leak here.
	testing.expect(t, worker_db_submit(c, get, 107, worker_db_test_callback))
	old_handle := c.handle
	sock := c.sock
	connection_test_uninstall(c)
	c = connection_test_install_fake({sock = sock, state = .Idle, workspace_id = "worker-sqlite", authenticated = true, verified_username = "alice"})
	c.verified_subject = "subject-a"
	testing.expect(t, c.handle != old_handle)
	worker_db_test_pump(t)
	testing.expect(t, worker_db_test_results[2].correlation == 107 && worker_db_test_results[2].found && worker_db_test_results[2].handle == {})

	// Same allocation, but another authenticated subject with the same nickname.
	testing.expect(t, worker_db_submit(c, get, 211, worker_db_test_callback))
	c.verified_subject = "subject-b"
	worker_db_test_pump(t)
	testing.expect(t, worker_db_test_results[3].correlation == 211 && worker_db_test_results[3].handle == {})
	// A late mutation still completes during real worker shutdown. The callback
	// runs with no recipient; future domain callbacks can still publish its event.
	put.task.id = 11
	testing.expect(t, worker_db_submit(c, put, 307, worker_db_test_callback))
	connection_test_uninstall(c); c = nil
	_server_thread_shutdown(nil)
	testing.expect(
		t,
		worker_db_test_count == 5 &&
		worker_db_test_results[4].correlation == 307 &&
		worker_db_test_results[4].status == sql.OK &&
		worker_db_test_results[4].handle == {},
	)
	db.join_executor(executor)
	store, open_rc := db.open(path)
	testing.expect_value(t, open_rc, sql.OK)
	defer db.close(&store)
	persisted, found, read_rc := db.get_task(&store, "worker-sqlite", 0, 11)
	defer db.destroy_task(&persisted)
	testing.expect(t, read_rc == sql.OK && found && string(persisted.title) == "sqlite")
}

@(test)
test_worker_db_eventloop_routing_and_disconnect :: proc(t: ^testing.T) {worker_db_test_fixture(t, false)}

@(test)
test_worker_db_budget_and_shutdown :: proc(t: ^testing.T) {worker_db_test_fixture(t, true)}

worker_db_test_spool_command :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	task := pr.Task {
		id    = 77,
		title = transmute([]byte)string("committed"),
	}
	if rc := db.put_task(store, request.workspace, &task); rc != sql.OK do return rc
	for i in 0 ..< 200 {
		msg := pr.AssetDeletedMessage {
			asset_id = u64(i + 1),
		}
		body, rc := db.command_frame(output, pr.getSizeAssetDeletedMessage(msg), .Subscribers)
		if rc != sql.OK do return rc
		pr.serializeAssetDeletedMessage(msg, body)
	}
	return sql.OK
}

worker_db_test_spool_callback :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	worker_db_test_count += 1
	assert(job.result.status == sql.OK && job.result.command.more)
	worker_db_complete_command(c, correlation, job)
	assert(job.result.command.count > 0 && job.result.command.count < 200)
	for sock in td.active_sockets {
		client := connection_get(sock)
		if client.workspace_id == job.request.workspace {
			assert(send_queue_len(client) == job.result.command.count)
		}
	}
	// The worker owns this completion until release; the executor cannot read
	// the next chunk yet. Truncate only this disposable, already committed job.
	assert(linux.ftruncate(job.result.command.spool.fd, 0) == .NONE)
}

worker_db_test_spool_failure :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	observer := connection_test_install_fake(
		{
			sock = connection_test_fake_socket(5),
			state = .New,
			workspace_id = c.workspace_id,
			authenticated = true,
			verified_username = "bob",
			init_send_queue = true,
		},
	)
	unaffected := connection_test_install_fake(
		{
			sock = connection_test_fake_socket(6),
			state = .New,
			workspace_id = "unaffected",
			authenticated = true,
			verified_username = "carol",
			init_send_queue = true,
		},
	)
	defer connection_test_uninstall(observer)
	defer connection_test_uninstall(unaffected)
	send_queue_init(c)
	for client in ([3]^NRC_Connection{c, observer, unaffected}) {
		td.active_sockets[client.sock] = {}
		td.connection_count += 1
		client.is_sending = true
		subscribe_to_conversation(client, 0)
	}
	testing.expect(t, worker_db_submit(c, {operation = .Command}, 91, worker_db_test_spool_callback))
	worker_db_test_pump(t)
	testing.expect(t, worker_db_test_count == 1, "postcommit failure must not invoke the normal error callback")
	for client in ([2]^NRC_Connection{c, observer}) {
		testing.expect(t, client.state >= .Will_Close)
		events := 0; closes := 0
		for send_queue_len(client) > 0 {
			item := send_queue_pop(client); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			if frame[0] & 0x0f == 8 {
				closes += 1
				testing.expect(t, frame[offset] == 3 && frame[offset + 1] == 243) // 1011
			} else {
				msg, err := pr.parseAssetDeletedMessage(frame[offset:])
				testing.expect(t, err == nil && msg.asset_id == u64(events + 1))
				events += 1
			}
		}
		// Logical close discards the unsent first chunk and leaves only 1011,
		// never an application-level rejection of the committed transaction.
		testing.expect(t, events == 0 && closes == 1)
	}
	testing.expect_value(t, unaffected.state, .New)
	testing.expect_value(t, send_queue_len(unaffected), 0)
	testing.expect(t, len(td.database.pending) == 0 && td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	task, found, read_rc := db.get_task(&store, c.workspace_id, 0, 77)
	defer db.destroy_task(&task)
	testing.expect(t, read_rc == sql.OK && found && string(task.title) == "committed")
	// The fixture then drains shutdown and joins the actual executor.
}

@(test)
test_worker_db_spool_failure_resync :: proc(t: ^testing.T) {worker_db_test_fixture(t, false, spool_failure_case = true)}

// Feed serialized requests through the real dispatcher and inspect the queued
// WebSocket response, after the normal worker loop consumes the DB completion.
worker_db_test_get_request :: proc(c: ^NRC_Connection, id: u64, correlation: u32, scope: u64 = 0) {
	buffer: [22]byte
	n := pr.serializeGetTaskRequest({conv_id = scope, task_id = id, correlation_id = correlation}, buffer[:])
	assert(n == len(buffer))
	process_protocol_payload(c, buffer[:])
}

worker_db_test_task_response :: proc(t: ^testing.T, c: ^NRC_Connection, correlation: u32, error: string = "") {
	if !testing.expect(t, send_queue_len(c) > 0, "expected a task response") do return
	item := send_queue_pop(c)
	defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease)
	header, offset, header_error := ws.readFrameHeader(frame)
	if !testing.expect(t, header_error == nil && header.opcode == .opBinary) do return
	attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	response, parse_error := pr.parseTaskFull(frame[offset:], attachments[:])
	if !testing.expect(t, parse_error == nil) do return
	testing.expect_value(t, response.correlation_id, correlation)
	testing.expect_value(t, response.conv_id, pr.WORKSPACE_DATA_ID)
	testing.expect_value(t, response.success, error == "")
	testing.expect_value(t, response.has_task, error == "")
	testing.expect_value(t, string(response.error), error)
	if error == "" {
		testing.expect_value(t, response.task.id, pr.TaskID(7))
		testing.expect_value(t, string(response.task.title), "sqlite")
		if testing.expect_value(t, len(response.task.attachments), 1) {
			testing.expect_value(t, string(response.task.attachments[0].file_id), "file-7")
			testing.expect_value(t, string(response.task.attachments[0].filename), "proof.txt")
			testing.expect_value(t, response.task.attachments[0].size, u64(937))
		}
	}
}

worker_db_test_task_handler :: proc(t: ^testing.T, c: ^NRC_Connection) {
	worker_db_test_get_request(c, 7, 81)
	testing.expect(t, send_queue_len(c) == 0, "no synchronous RAM response")
	worker_db_test_pump(t)
	worker_db_test_task_response(t, c, 81)
	for id, i in ([3]u64{999, 11, 13}) {
		worker_db_test_get_request(c, id, u32(90 + i))
		worker_db_test_pump(t)
		worker_db_test_task_response(t, c, u32(90 + i), "Task not found")
	}
	// Public dispatch must reject a private legacy scope before queue admission.
	worker_db_test_get_request(c, 13, 100, 77)
	testing.expect_value(t, len(td.database.pending), 0)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c)
		defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease)
		_, offset, _ := ws.readFrameHeader(frame)
		response, err := pr.parseErrorResponseMessage(frame[offset:])
		testing.expect(t, err == nil)
		testing.expect_value(t, string(response.error_msg), "Workspace data requires scope 0; update your client")
	}
	c.authenticated = false
	worker_db_test_get_request(c, 7, 101)
	worker_db_test_task_response(t, c, 101, "Access denied")
	testing.expect_value(t, len(td.database.pending), 0)
	c.authenticated = true

	// Credits stay charged even if the executor has already finished. The third
	// read is rejected deterministically until the worker drains the first two.
	worker_db_test_get_request(c, 7, 111)
	worker_db_test_get_request(c, 7, 112)
	worker_db_test_get_request(c, 7, 113)
	worker_db_test_task_response(t, c, 113, "db_worker_overloaded")
	worker_db_test_pump(t)
	testing.expect_value(t, send_queue_len(c), 2)
	worker_db_test_task_response(t, c, 111)
	worker_db_test_task_response(t, c, 112)

	worker_db_test_get_request(c, 17, 121)
	worker_db_test_pump(t)
	worker_db_test_task_response(t, c, 121, "Invalid task data")
	worker_db_test_get_request(c, 19, 122)
	worker_db_test_pump(t)
	worker_db_test_task_response(t, c, 122, "Failed to load task")
	c.workspace_id = "broken"
	worker_db_test_get_request(c, 7, 123)
	worker_db_test_pump(t)
	worker_db_test_task_response(t, c, 123, "Failed to load task")
	c.workspace_id = "unassigned"
	unassigned := int(shard_for_workspace(transmute([]byte)c.workspace_id))
	assert(string(td.database.port.executor.paths[unassigned]) == "")
	worker_db_test_get_request(c, 7, 124)
	worker_db_test_task_response(t, c, 124, "Server too busy")
	testing.expect_value(t, len(td.database.pending), 0)
	c.workspace_id = "worker-sqlite"

	// The owned-result budget and the protocol frame limit are separate bounds.
	huge_description: [MAX_PROTOCOL_PAYLOAD_SIZE]byte
	huge_task := pr.Task {
		id          = 7,
		description = huge_description[:],
	}
	send_task_full(c, 0, &huge_task, "", 125)
	worker_db_test_task_response(t, c, 125, "Task exceeds response limit")

	worker_db_test_get_request(c, 7, 131)
	c.verified_subject = "another-subject"
	worker_db_test_pump(t)
	testing.expect(t, send_queue_len(c) == 0, "stale identity must receive no task")
	c.verified_subject = "subject-a"
	worker_db_test_get_request(c, 7, 132)
	c.state = .Closed
	worker_db_test_pump(t)
	testing.expect(t, send_queue_len(c) == 0, "disconnected recipient must receive no task")
	c.state = .Idle
	testing.expect(t, len(td.workspaces) == 0, "protocol reads must not populate workspace maps")
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_history :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM history; DELETE FROM history_sequences", nil, nil, nil), sql.OK)
	for f in ([?]struct {
			entity, source, target: db.History_Reference,
			owner:                  string,
		} {
			{{1, 7}, {}, {}, ""},
			{{2, 90}, {}, {}, "bob"}, // Owner ACL remains after deletion of the asset.
			{{3, 81}, {1, 7}, {1, 7}, ""}, // Same endpoint twice must yield just one event.
			{{2, 88}, {}, {}, ""},
			{{3, 82}, {1, 999}, {2, 99}, ""},
		}) {
		entity := fmt.aprintf("%d", f.entity.id); defer delete(entity)
		event := pr.History_Event {
			entity_id   = entity,
			entity_type = f.entity.kind == 1 ? "task" : (f.entity.kind == 2 ? "asset" : "edge"),
			action      = "created",
		}
		testing.expect_value(t, db.append_history_event(&store, c.workspace_id, event, f.entity, f.source, f.target, f.owner), sql.OK)
	}
	for f in ([?]struct {
			id:      u64,
			kind:    pr.AssetType,
			preview: string,
		}{{88, .Note, `{}`}, {99, .Reminder, `{"visibility":"personal"}`}}) {
		a := pr.Asset {
			asset_id = f.id,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO assets VALUES(?1,?2,?3,0,x'0000000000000000',x'626f62',0,0,0,0,?4,x'')",
				c.workspace_id,
				&a,
				{i64(f.kind), f.preview},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, db.append_history_event(&store, "foreign", {entity_id = "7"}, {1, 7}), sql.OK)
	// Test the unsigned terminal ID, not just values fitting in signed INTEGER.
	testing.expect_value(t, sql.exec(store.db, "UPDATE history_sequences SET high_water=x'fffffffffffffffe'", nil, nil, nil), sql.OK)
	testing.expect_value(t, db.append_history_event(&store, c.workspace_id, {entity_id = "77", action = "deleted"}, {1, 77}), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	buffer: [128]byte
	for f in ([?]struct {
			kind:           u8,
			entity, before: u64,
			limit:          u16,
			ids:            []string,
			next:           string,
		}{{0, 0, 0, 3, {"18446744073709551615", "5", "4"}, "4"}, {0, 0, 4, 3, {"3", "1"}, "0"}, {1, 7, 0, 100, {"3", "1"}, "0"}, {2, 99, 0, 100, {"5"}, "0"}, {3, 81, 0, 100, {"3"}, "0"}, {2, 90, 0, 100, {}, "0"}}) {
		n := pr.serializeListHistoryRequest({kind = f.kind, entity = f.entity, before = f.before, limit = f.limit, correlation_id = 401}, buffer[:])
		assert(n > 0)
		process_protocol_payload(c, buffer[:n]); mem.zero(raw_data(buffer[:]), len(buffer))
		testing.expect_value(t, send_queue_len(c), 0)
		worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		testing.expect_value(t, pr.get_opcode(frame[offset:]), .S_HistoryPage)
		correlation, _ := endian.get_u32(frame[offset + 2:], .Big)
		testing.expect_value(t, correlation, u32(401))
		page: struct {
			events: []pr.History_Event,
			next:   string `json:"nextBefore"`,
		}
		virtual.arena_free_all(&arena)
		testing.expect(t, json.unmarshal(frame[offset + 6:], &page, allocator = virtual.arena_allocator(&arena)) == nil)
		testing.expect_value(t, page.next, f.next)
		if !testing.expect_value(t, len(page.events), len(f.ids)) do continue
		for e, i in page.events {
			testing.expect_value(t, e.id, f.ids[i])
			testing.expect(t, e.entity_available == (e.id == "1" || e.id == "4"))
			testing.expect(t, e.source_available == (e.id == "3") && e.target_available == (e.id == "3"))
			if e.id == "4" do testing.expect_value(t, e.asset_type, u16(pr.AssetType.Note))
		}
	}
	// Invalid stored JSON must become a correlated history error, never a task
	// error or a partial page. Rejected requests preserve authentication precedence.
	testing.expect_value(t, sql.exec(store.db, "UPDATE history SET body=x'7b' WHERE id=x'0000000000000001'", nil, nil, nil), sql.OK)
	for f in ([?]struct {
			authenticated: bool,
			limit:         u16,
			error:         string,
		}{{true, 100, "Failed to read history"}, {false, 0, "Authentication required"}, {true, 0, "Invalid history filter or limit"}}) {
		c.authenticated = f.authenticated
		n := pr.serializeListHistoryRequest({kind = 1, entity = 7, limit = 100, correlation_id = 402}, buffer[:]); assert(n > 0)
		endian.put_u16(buffer[2 + 25:], .Big, f.limit)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		testing.expect_value(t, pr.get_opcode(frame[offset:]), .S_HistoryPage)
		correlation, _ := endian.get_u32(frame[offset + 2:], .Big); testing.expect_value(t, correlation, u32(402))
		page: struct {
			error: string,
		}
		virtual.arena_free_all(&arena)
		testing.expect(t, json.unmarshal(frame[offset + 6:], &page, allocator = virtual.arena_allocator(&arena)) == nil)
		testing.expect_value(t, page.error, f.error)
	}
	c.authenticated = true
	// Byte-limited pages advance past exactly the emitted event. A single event
	// exceeding the admission budget fails instead of returning a looping cursor.
	label: [5000]byte
	for &b in label[:] do b = 'x'
	for length in ([2]int{2200, 5000}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sql.exec(store.db, "DELETE FROM history; DELETE FROM history_sequences", nil, nil, nil), sql.OK)
		for _ in 0 ..< 3 do testing.expect_value(t, db.append_history_event(&store, c.workspace_id, {entity_label = string(label[:length])}, {1, 7}, private_owner = "alice"), sql.OK)
		testing.expect_value(t, db.commit(&store), sql.OK)
		before: u64
		for expected in ([3]u64{3, 2, 1}) {
			n := pr.serializeListHistoryRequest({kind = 1, entity = 7, before = before, limit = 100, correlation_id = 403}, buffer[:]); assert(n > 0)
			process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do break
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			page: struct {
				events: []pr.History_Event,
				next:   string `json:"nextBefore"`,
				error:  string,
			}
			virtual.arena_free_all(&arena)
			testing.expect(t, json.unmarshal(frame[offset + 6:], &page, allocator = virtual.arena_allocator(&arena)) == nil)
			if length == 5000 {testing.expect_value(t, page.error, "Failed to read history"); break}
			testing.expect_value(t, page.error, "")
			id_text := fmt.aprintf("%d", expected); defer delete(id_text)
			if testing.expect_value(t, len(page.events), 1) do testing.expect_value(t, page.events[0].id, id_text)
			testing.expect_value(t, page.next, expected == 1 ? "0" : id_text)
			before = expected
		}
	}
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

@(test)
test_worker_db_task_protocol :: proc(t: ^testing.T) {worker_db_test_fixture(t, false, true)}

worker_db_test_task_dependents :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM tasks", nil, nil, nil), sql.OK)
	attachment := [1]pr.Attachment{{file_id = transmute([]byte)string("dependent-file"), size = max(u64)}}
	for f in ([?]struct {
			id, parent: u64,
		}{{100, 0}, {200, 0}, {800, 100}, {u64(1) << 63, 100}, {max(u64), 100}, {900, 200}}) {
		task := pr.Task {
			id          = f.id,
			blocked_by  = f.parent,
			title       = transmute([]byte)string("dependent"),
			attachments = attachment[:],
		}
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	}
	foreign_task := pr.Task {
		id         = 700,
		blocked_by = 100,
	}
	testing.expect_value(t, db.put_task(&store, "foreign-dependents", &foreign_task), sql.OK)
	foreign_task.id = 300
	testing.expect_value(t, db.put_task(&store, "foreign-dependents", &foreign_task), sql.OK)
	// The parent need not fit the result credit: only its existence is read.
	large: [5000]byte
	for &b in large[:] do b = 'x'
	parent := pr.Task {
		id          = 100,
		description = large[:],
	}
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &parent), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	buffer: [64]byte
	for f in ([?]struct {
			parent, after: u64,
			limit:         u16,
			ids:           []u64,
			more:          bool,
			error:         string,
		}{{100, 0, 2, {800, u64(1) << 63}, true, ""}, {100, 800, 1, {u64(1) << 63}, true, ""}, {100, 801, 2, {u64(1) << 63, max(u64)}, false, ""}, {100, max(u64), 2, {}, false, ""}, {800, 0, 2, {}, false, ""}, {300, 0, 2, {}, false, "task_not_found"}}) {
		n := pr.serializeListTaskDependentsRequest(
			{task_id = f.parent, after_task_id = f.after, limit = f.limit, correlation_id = 807},
			buffer[:],
		); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); mem.zero(raw_data(buffer[:]), len(buffer)); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		body := frame[offset:]
		if !testing.expect(t, len(body) >= 36 && pr.get_opcode(body) == .S_TaskDependentsPage) do continue
		conv, _ := endian.get_u64(body[2:], .Big); parent_id, _ := endian.get_u64(body[10:], .Big)
		count, _ := endian.get_u16(body[19:], .Big)
		testing.expect(t, conv == 0 && parent_id == f.parent && (body[18] == 1) == (f.error == ""))
		if !testing.expect_value(t, int(count), len(f.ids)) do continue
		pos := 21
		for id in f.ids {
			attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			task, next, _, err := pr.parse_task_from_payload(body, pos, attachments[:])
			if !testing.expect(t, err == nil) do break
			testing.expect_value(t, task.id, id)
			testing.expect_value(t, task.blocked_by, f.parent)
			if testing.expect_value(t, len(task.attachments), 1) {
				testing.expect_value(t, string(task.attachments[0].file_id), "dependent-file")
				testing.expect_value(t, task.attachments[0].size, max(u64))
			}
			pos = next
		}
		testing.expect_value(t, body[pos] == 1, f.more)
		next, _ := endian.get_u64(body[pos + 1:], .Big)
		testing.expect_value(t, next, len(f.ids) > 0 ? f.ids[len(f.ids) - 1] : 0)
		err_len, _ := endian.get_u16(body[pos + 9:], .Big)
		testing.expect_value(t, string(body[pos + 11:][:int(err_len)]), f.error)
		correlation, _ := endian.get_u32(body[len(body) - 4:], .Big)
		testing.expect_value(t, correlation, u32(807))
	}
	// A short page must continue at the last emitted ID; an oversized first
	// record returns the existing domain error rather than an empty success.
	for length in ([2]int{2200, 5000}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		for id in ([2]u64{800, u64(1) << 63}) {
			task := pr.Task {
				id          = id,
				blocked_by  = 100,
				description = large[:length],
			}
			testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
		}
		testing.expect_value(t, db.commit(&store), sql.OK)
		n := pr.serializeListTaskDependentsRequest({task_id = 100, limit = 10, correlation_id = 808}, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		body := frame[offset:]
		if !testing.expect(t, len(body) >= 36 && pr.get_opcode(body) == .S_TaskDependentsPage) do continue
		count, _ := endian.get_u16(body[19:], .Big)
		if length == 5000 {
			testing.expect(t, body[18] == 0 && count == 0 && string(body[32:len(body) - 4]) == "task_exceeds_page_byte_limit")
		} else {
			testing.expect(t, body[18] == 1 && count == 1)
			next, _ := endian.get_u64(body[len(body) - 14:], .Big)
			testing.expect(t, body[len(body) - 15] == 1 && next == 800)
		}
	}
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_task_page :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM tasks", nil, nil, nil), sql.OK)
	attachment := [1]pr.Attachment{{file_id = transmute([]byte)string("page-file"), size = max(u64)}}
	for f in ([?]struct {
			id:                 u64,
			status:             pr.TaskStatus,
			updated, completed: i64,
		}{{1, .Todo, 10, 0}, {9, .Done, 900, 10}, {max(u64), .Todo, 10, 0}, {4, .Backlog, 20, 0}, {5, .Note, 30, 0}, {6, .InProgress, -9, 0}}) {
		task := pr.Task {
			id           = f.id,
			status       = f.status,
			updated_at   = f.updated,
			completed_at = f.completed,
			title        = transmute([]byte)string("page"),
		}
		if f.id == 9 do task.attachments = attachment[:]
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
		task.updated_at = 1000
		testing.expect_value(t, db.put_task(&store, "foreign-page", &task), sql.OK)
		task.conv_id = 77
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.CONSTRAINT)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	buffer: [128]byte
	for f in ([?]struct {
			mask:       u8,
			has_cursor: bool,
			at:         i64,
			id:         u64,
			ids:        []u64,
			more:       bool,
			total:      u32,
			next_at:    i64,
			next_id:    u64,
		}{{15, false, 0, 0, {4, max(u64)}, true, 5, 10, max(u64)}, {15, true, 10, max(u64), {9, 1}, true, 5, 10, 1}, {15, true, 10, 1, {6}, false, 5, -9, 6}, {16, false, 0, 0, {5}, false, 1, 30, 5}, {15, true, -9, 6, {}, false, 5, 0, 0}}) {
		n := pr.serializeListTasksPagedRequest(
			{status_mask = f.mask, limit = 2, has_cursor = f.has_cursor, cursor_sort_at = f.at, cursor_task_id = f.id, correlation_id = 501},
			buffer[:],
		); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); mem.zero(raw_data(buffer[:]), len(buffer)); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		tasks: [2]pr.Task; attachments: [2 * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		page, err := pr.parseTaskListPage(frame[offset:], tasks[:], attachments[:])
		if !testing.expect(t, err == nil && page.success && page.correlation_id == 501) do continue
		testing.expect_value(t, page.total_count, f.total); testing.expect_value(t, page.has_more, f.more)
		testing.expect_value(t, page.next_cursor_sort_at, f.next_at); testing.expect_value(t, page.next_cursor_task_id, f.next_id)
		if !testing.expect_value(t, len(page.tasks), len(f.ids)) do continue
		for task, i in page.tasks {
			testing.expect_value(t, task.id, f.ids[i])
			if task.id == 9 && testing.expect_value(t, len(task.attachments), 1) {
				testing.expect_value(t, string(task.attachments[0].file_id), "page-file")
				testing.expect_value(t, task.attachments[0].size, max(u64))
			}
		}
	}
	large: [5000]byte
	for &b in large[:] do b = 'x'
	for length in ([2]int{2200, 5000}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		for id in ([2]u64{1, max(u64)}) {
			task := pr.Task {
				id          = id,
				status      = .Todo,
				updated_at  = 10,
				description = large[:length],
			}
			testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
		}
		testing.expect_value(t, db.commit(&store), sql.OK)
		for cursor in ([2]bool{false, true}) {
			n := pr.serializeListTasksPagedRequest(
				{status_mask = 2, limit = 1000, has_cursor = cursor, cursor_sort_at = 10, cursor_task_id = max(u64), correlation_id = 502},
				buffer[:],
			); assert(n > 0)
			process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do continue
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			tasks: [2]pr.Task; attachments: [2 * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			page, err := pr.parseTaskListPage(frame[offset:], tasks[:], attachments[:])
			if !testing.expect(t, err == nil && page.correlation_id == 502) do continue
			if length == 5000 {testing.expect(t, !page.success && string(page.error) == "Failed to read tasks"); continue}
			testing.expect(t, page.success && page.total_count == 2 && page.has_more == !cursor)
			if testing.expect_value(t, len(page.tasks), 1) {
				testing.expect_value(t, page.tasks[0].id, cursor ? 1 : max(u64))
				testing.expect_value(t, len(page.tasks[0].description), length)
				testing.expect_value(t, page.next_cursor_task_id, page.tasks[0].id)
			}
		}
	}
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_task_facets :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	for rows in ([4]int{3, 129, 0, 257}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sql.exec(store.db, "DELETE FROM tasks", nil, nil, nil), sql.OK)
		testing.expect_value(t, sql.exec(store.db, "DELETE FROM assets", nil, nil, nil), sql.OK)
		for i in 0 ..< rows + 3 {
			workspace := i == rows + 1 ? "foreign-facets" : c.workspace_id
			scope: u64 = i == rows + 2 ? 77 : 0
			{
				name := fmt.aprintf("n%03d", i); defer delete(name)
				project := fmt.aprintf(rows == 257 ? "note-project-%07d" : "n%03d", i); defer delete(project)
				preview :=
					i == rows ? strings.clone("{}") : fmt.aprint(`{"project":"`, project, `","tags":["tag","`, name, `"]}`, sep = ""); defer delete(preview)
				a := pr.Asset {
					asset_id   = u64(i * 32 + 1),
					conv_id    = scope,
					asset_type = .Note,
					preview    = transmute([]byte)preview,
				}
				testing.expect_value(t, sqlite_put_asset(&store, workspace, &a), scope == 0 ? sql.OK : sql.CONSTRAINT)
				a.asset_id += 100000
				testing.expect_value(t, sqlite_put_asset(&store, workspace, &a), scope == 0 ? sql.OK : sql.CONSTRAINT)
			}
			for kind in ([3]pr.AssetType{.Slice, .Ticket, .Appointment}) {
				if kind == .Appointment && i == 0 do continue // A task-only calendar person.
				prefix := kind == .Slice ? "s" : kind == .Ticket ? "t" : "u"
				name := i == rows ? strings.clone("") : fmt.aprintf("%s%03d", prefix, i); defer delete(name)
				preview := fmt.aprint(
					kind == .Slice ? `{"version":1,"name":"Work","owner":"` : kind == .Ticket ? `{"version":1,"title":"Ticket","status":"open","priority":"high","company_id":"","contact_id":"","requester":"","requester_name":"","assignee":"` : `{"version":1,"title":"Meet","start_at":"100","end_at":"200","assignee":"`,
					name,
					`"}`,
					sep = "",
				)
				defer delete(preview)
				a := pr.Asset {
					asset_id   = u64(i * 32 + int(kind) + 1),
					conv_id    = scope,
					asset_type = kind,
					preview    = transmute([]byte)preview,
				}
				testing.expect_value(t, sqlite_put_asset(&store, workspace, &a), scope == 0 ? sql.OK : sql.CONSTRAINT)
				// Shared names across assets collapse; calendar also overlaps task assignees.
				a.asset_id += 100000
				testing.expect_value(t, sqlite_put_asset(&store, workspace, &a), scope == 0 ? sql.OK : sql.CONSTRAINT)
			}
		}
		if rows == 3 {
			a := pr.Asset {
				asset_id   = 999999,
				asset_type = .Appointment,
				preview    = transmute([]byte)string(`{"version":1,"title":"Only appointment","start_at":"100","end_at":"200","assignee":"u003"}`),
			}
			testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &a), sql.OK)
		}
		for i in 0 ..< rows {
			project := fmt.aprintf(rows == 257 ? "project-%07d" : "p%03d", rows - 1 - i); defer delete(project)
			assignee := fmt.aprintf("u%03d", i); defer delete(assignee)
			task := pr.Task {
				id          = u64(i + 1),
				status      = pr.TaskStatus(i % 5),
				priority    = u8((i + 1) % 3),
				order_index = u16(rows - i),
				project     = transmute([]byte)project,
				assignee    = transmute([]byte)assignee,
			}
			testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
			// Duplicates across statuses disappear; empty names and other scopes do not leak.
			task.id += 1000; task.status = .Done
			testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
		}
		task := pr.Task {
			id = 9999,
		}
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
		task.project = transmute([]byte)string("foreign"); task.assignee = task.project
		testing.expect_value(t, db.put_task(&store, "foreign-facets", &task), sql.OK)
		task.conv_id = 77
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.CONSTRAINT)
		testing.expect_value(t, db.commit(&store), sql.OK)
		for opcode in ([5]pr.Opcode{.C_ListTaskProjects, .C_ListTaskAssignees, .C_ListSliceOwners, .C_ListTicketAssignees, .C_ListCalendarPeople}) {
			buffer: [32]byte
			n := pr.serializeListTaskProjectsRequest(0, 601, buffer[:], opcode); assert(n > 0)
			process_protocol_payload(c, buffer[:n]); mem.zero(raw_data(buffer[:]), len(buffer)); worker_db_test_pump(t)
			seen := 0
			expected_rows := rows + (rows == 3 && opcode == .C_ListCalendarPeople ? 1 : 0)
			expected_frames := max(1, (expected_rows + 127) / 128)
			response_opcode := pr.Opcode.S_TaskProjects
			prefix := "p"
			#partial switch opcode {
			case .C_ListTaskAssignees:
				response_opcode = .S_TaskAssignees; prefix = "u"
			case .C_ListSliceOwners:
				response_opcode = .S_SliceOwners; prefix = "s"
			case .C_ListTicketAssignees:
				response_opcode = .S_TicketAssignees; prefix = "t"
			case .C_ListCalendarPeople:
				response_opcode = .S_CalendarPeople; prefix = "u"
			}
			if !testing.expect_value(t, send_queue_len(c), expected_frames) do continue
			for chunk in 0 ..< expected_frames {
				item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
				frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
				body := frame[offset:]
				testing.expect_value(t, pr.get_opcode(body), response_opcode)
				count, _ := endian.get_u16(body[10:], .Big); pos := 12
				for _ in 0 ..< int(count) {
					length, _ := endian.get_u16(body[pos:], .Big); pos += 2
					expected :=
						rows == 257 && opcode == .C_ListTaskProjects ? fmt.aprintf("project-%07d", seen) : fmt.aprintf("%s%03d", prefix, seen); defer delete(expected)
					testing.expect_value(t, string(body[pos:pos + int(length)]), expected); pos += int(length); seen += 1
				}
				testing.expect_value(t, body[pos], u8(chunk + 1 < expected_frames ? 1 : 0))
				correlation, _ := endian.get_u32(body[pos + 1:], .Big); testing.expect_value(t, correlation, u32(601))
				testing.expect_value(t, len(body), pos + 5)
			}
			testing.expect_value(t, seen, expected_rows)
		}
		for opcode in ([2]pr.Opcode{.C_ListNoteProjects, .C_ListNoteTags}) {
			buffer: [32]byte
			n := pr.serializeListTaskProjectsRequest(0, 603, buffer[:], opcode); assert(n > 0)
			process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do continue
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			if rows == 257 && opcode == .C_ListNoteProjects {
				e, err := pr.parseErrorResponseMessage(frame[offset:])
				testing.expect(t, err == nil && e.correlation_id == 603 && e.origin_opcode == opcode)
				continue
			}
			names: []string
			defer delete(names)
			if opcode == .C_ListNoteProjects {
				msg, err := pr.parseNoteProjectListMessage(frame[offset:])
				names = msg.projects
				if !testing.expect(t, err == nil && msg.correlation_id == 603 && msg.conv_id == 0) do continue
			} else {
				msg, err := pr.parseNoteTagListMessage(frame[offset:])
				names = msg.tags
				if !testing.expect(t, err == nil && msg.correlation_id == 603 && msg.conv_id == 0) do continue
			}
			if testing.expect_value(t, len(names), rows + (opcode == .C_ListNoteTags && rows > 0 ? 1 : 0)) {
				for name, i in names {
					expected := i == rows ? strings.clone("tag") : fmt.aprintf("n%03d", i); defer delete(expected)
					testing.expect_value(t, name, expected)
				}
			}
		}
		buffer: [32]byte
		n := pr.serializeGetTasksRequest({correlation_id = 602}, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		tasks: [7]pr.Task
		response, err := pr.parseTaskListResponse(frame[offset:], tasks[:], nil)
		if !testing.expect(t, err == nil && response.correlation_id == 602) do continue
		if rows > 3 {
			testing.expect(t, !response.success && string(response.error) == "Task list exceeds transport limit; use paged task queries")
		} else {
			expected := [7]u64{2, 1002, 1, 1001, 9999, 3, 1003}
			ids := rows == 0 ? expected[4:5] : expected[:]
			testing.expect(t, response.success)
			if testing.expect_value(t, len(response.tasks), len(ids)) {
				for record, i in response.tasks do testing.expect_value(t, record.id, ids[i])
			}
		}
	}
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_create_request :: proc(c: ^NRC_Connection, correlation: u32) {
	attachments := [1]pr.Attachment{{file_id = transmute([]byte)string("created-file"), filename = transmute([]byte)string("create.txt"), size = 327}}
	buffer: [2048]byte
	n := pr.serializeCreateTaskRequest(
		{title = transmute([]byte)string("created"), status = .Todo, priority = 3, attachments = attachments[:], correlation_id = correlation},
		buffer[:],
	)
	assert(n > 0)
	process_protocol_payload(c, buffer[:n])
	for &b in buffer[:] do b = 0 // The executor must not borrow this receive buffer.
}

worker_db_test_created_response :: proc(t: ^testing.T, c: ^NRC_Connection, correlation: u32, id: u64, order: u16) {
	if !testing.expect(t, send_queue_len(c) > 0) do return
	item := send_queue_pop(c)
	defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease)
	_, offset, frame_err := ws.readFrameHeader(frame)
	if !testing.expect(t, frame_err == nil) do return
	attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	response, err := pr.parseTaskCreated(frame[offset:], attachments[:])
	if !testing.expect(t, err == nil) do return
	testing.expect_value(t, response.correlation_id, correlation)
	testing.expect(t, response.task.id == id && response.task.order_index == order && response.task.conv_id == 0)
	testing.expect(t, string(response.task.title) == "created" && string(response.task.created_by) == "alice" && response.task.priority == 3)
	if testing.expect_value(t, len(response.task.attachments), 1) {
		testing.expect_value(t, string(response.task.attachments[0].file_id), "created-file")
		testing.expect_value(t, response.task.attachments[0].size, u64(327))
	}
}

worker_db_test_create_error :: proc(t: ^testing.T, c: ^NRC_Connection, correlation: u32, message: string) {
	if !testing.expect_value(t, send_queue_len(c), 1) do return
	item := send_queue_pop(c)
	defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease)
	_, offset, _ := ws.readFrameHeader(frame)
	response, err := pr.parseTaskListResponse(frame[offset:], nil, nil)
	testing.expect(t, err == nil && !response.success && response.correlation_id == correlation)
	testing.expect_value(t, string(response.error), message)
}

worker_db_test_create_handler :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	observer := connection_test_install_fake(
		{
			sock = connection_test_fake_socket(4),
			state = .Idle,
			workspace_id = c.workspace_id,
			authenticated = true,
			verified_username = "bob",
			init_send_queue = true,
		},
	)
	defer connection_test_uninstall(observer)
	observer.is_sending = true
	outsider := connection_test_install_fake(
		{
			sock = connection_test_fake_socket(5),
			state = .Idle,
			workspace_id = "other",
			authenticated = true,
			verified_username = "eve",
			init_send_queue = true,
		},
	)
	defer connection_test_uninstall(outsider)
	outsider.is_sending = true
	subscribe_to_conversation(c, 0)
	subscribe_to_conversation(observer, 0)
	subscribe_to_conversation(outsider, 0)
	worker_db_test_create_request(c, 201)
	testing.expect(t, send_queue_len(c) == 0 && send_queue_len(observer) == 0)
	worker_db_test_pump(t)
	worker_db_test_created_response(t, c, 201, 20, 0)
	worker_db_test_created_response(t, observer, 0, 20, 0)
	probe, rc := db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&probe)
	persisted, found, read_rc := db.get_task(&probe, "worker-sqlite", 0, 20)
	defer db.destroy_task(&persisted)
	testing.expect(t, read_rc == sql.OK && found && string(persisted.title) == "created" && string(persisted.created_by) == "alice")

	// Failure late in the transaction must produce only an error, no event.
	testing.expect_value(
		t,
		sql.exec(probe.db, "CREATE TRIGGER reject_create BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil),
		sql.OK,
	)
	worker_db_test_create_request(c, 202)
	worker_db_test_pump(t)
	worker_db_test_create_error(t, c, 202, "Failed to create task")
	testing.expect_value(t, send_queue_len(observer), 0)
	testing.expect_value(t, sql.exec(probe.db, "DROP TRIGGER reject_create", nil, nil, nil), sql.OK)

	// A disconnected initiator still commits and broadcasts to the other subscriber.
	worker_db_test_create_request(c, 203)
	c.state = .Closed
	worker_db_test_pump(t)
	testing.expect_value(t, send_queue_len(c), 0)
	worker_db_test_created_response(t, observer, 0, 21, 1)
	c.state = .Idle
	c.authenticated = false
	worker_db_test_create_request(c, 204)
	worker_db_test_create_error(t, c, 204, "Access denied")
	testing.expect_value(t, len(td.database.pending), 0)
	c.authenticated = true
	worker_db_test_create_request(c, 205)
	worker_db_test_create_request(c, 206)
	worker_db_test_create_request(c, 207)
	worker_db_test_create_error(t, c, 207, "db_worker_overloaded")
	worker_db_test_pump(t)
	testing.expect(t, send_queue_len(c) == 2 && send_queue_len(observer) == 2)
	worker_db_test_created_response(t, c, 205, 22, 2)
	worker_db_test_created_response(t, c, 206, 23, 3)
	worker_db_test_created_response(t, observer, 0, 22, 2)
	worker_db_test_created_response(t, observer, 0, 23, 3)
	rejected, rejected_found, rejected_rc := db.get_task(&probe, "worker-sqlite", 0, 24)
	defer db.destroy_task(&rejected)
	testing.expect(t, rejected_rc == sql.OK && !rejected_found)
	testing.expect_value(t, send_queue_len(outsider), 0)
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_update_move :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	dependent := pr.Task {
		id         = 31,
		blocked_by = 7,
		title      = transmute([]byte)string("dependent"),
		updated_at = 99,
	}
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &dependent), sql.OK)
	dependent.id = 32
	testing.expect_value(t, db.put_task(&store, "other-workspace", &dependent), sql.OK)
	dependent.id = 33; dependent.conv_id = 77
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &dependent), sql.CONSTRAINT)
	column := pr.Task {
		id          = 34,
		status      = .Done,
		order_index = 41,
		title       = transmute([]byte)string("column"),
	}
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &column), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	observer := connection_test_install_fake(
		{
			sock = connection_test_fake_socket(4),
			state = .Idle,
			workspace_id = c.workspace_id,
			authenticated = true,
			verified_username = "bob",
			init_send_queue = true,
		},
	)
	defer connection_test_uninstall(observer)
	observer.is_sending = true
	subscribe_to_conversation(observer, 0)
	buffer: [1024]byte
	patch := pr.UpdateTaskRequest {
		task_id              = 7,
		title                = nil,
		description          = transmute([]byte)string("\x00"),
		assignee             = transmute([]byte)string("new assignee"),
		status               = pr.TaskStatus(255),
		priority             = 255,
		color                = pr.TaskColor(255),
		project              = transmute([]byte)string("sdk"),
		preserve_attachments = true,
		correlation_id       = 301,
	}
	n := pr.serializeUpdateTaskRequest(patch, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n])
	mem.zero(raw_data(buffer[:]), len(buffer)) // The executor must own bytes, including update sentinels.
	testing.expect_value(t, send_queue_len(c), 0)
	worker_db_test_pump(t)
	for recipient in ([?]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
		item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		msg, err := pr.parseTaskUpdated(frame[offset:], attachments[:])
		testing.expect(t, err == nil && msg.correlation_id == (recipient == c ? 301 : 0))
		testing.expect(t, string(msg.task.title) == "sqlite" && string(msg.task.assignee) == "new assignee" && string(msg.task.project) == "sdk")
		testing.expect(t, len(msg.task.description) == 0 && len(msg.task.attachments) == 1 && msg.task.status == .Backlog)
	}
	n = pr.serializeMoveTaskRequest({task_id = 7, status = .Done, flags = {.Append}, correlation_id = 302}, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	for recipient in ([?]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), 2) do continue
		seen_update, seen_move := false, false
		for _ in 0 ..< 2 {
			item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			if pr.get_opcode(frame[offset:]) == .S_TaskMoved {
				msg, err := pr.parseTaskMoved(frame[offset:])
				testing.expect(
					t,
					!seen_move &&
					err == nil &&
					msg.task_id == 7 &&
					msg.order_index == 42 &&
					msg.status == .Done &&
					msg.completed_at > 0 &&
					string(msg.completed_by) == "alice",
				)
				testing.expect_value(t, msg.correlation_id, u32(recipient == c ? 302 : 0))
				seen_move = true
			} else {
				attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
				msg, err := pr.parseTaskUpdated(frame[offset:], attachments[:])
				testing.expect(
					t,
					!seen_update && err == nil && msg.task.id == 31 && msg.task.blocked_by == 0 && msg.task.updated_at > 99 && msg.correlation_id == 0,
				)
				seen_update = true
			}
		}
		testing.expect(t, seen_update && seen_move)
	}
	other, foreign_found, foreign_rc := db.get_task(&store, "other-workspace", 0, 32); defer db.destroy_task(&other)
	private, private_found, private_rc := db.get_task(&store, c.workspace_id, 77, 33); defer db.destroy_task(&private)
	testing.expect(t, foreign_found && !private_found && foreign_rc == sql.OK && private_rc == sql.CONSTRAINT && other.blocked_by == 7)
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT count(*)=1 FROM history WHERE json_extract(body,'$.actorId')='system' AND json_extract(body,'$.entityId')='31' AND json_extract(body,'$.fields[0]')='blocked_by'",
	)
	testing.expect_value(
		t,
		sql.exec(store.db, "CREATE TRIGGER reject_update BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil),
		sql.OK,
	)
	n = pr.serializeMoveTaskRequest({task_id = 7, status = .Todo, order_index = 8, correlation_id = 303}, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	worker_db_test_create_error(t, c, 303, "Failed to change task")
	testing.expect_value(t, send_queue_len(observer), 0)
	kept, kept_found, kept_rc := db.get_task(&store, c.workspace_id, 0, 7); defer db.destroy_task(&kept)
	testing.expect(t, kept_found && kept_rc == sql.OK && kept.status == .Done && kept.order_index == 42)
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_update", nil, nil, nil), sql.OK)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	for recipient in ([?]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
		item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseTaskMoved(frame[offset:])
		testing.expect(t, err == nil && msg.status == .Todo && msg.completed_at == 0 && len(msg.completed_by) == 0)
	}
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT count(*)=2 FROM history WHERE json_extract(body,'$.entityId')='7' AND json_extract(body,'$.fields[0]')='status' AND json_extract(body,'$.fields[1]')='order_index'",
	)
	// A reorder is an edit; repeating the same position is only a timestamp change.
	for _ in 0 ..< 2 {
		n = pr.serializeMoveTaskRequest({task_id = 7, status = .Todo, order_index = 9, correlation_id = 304}, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		for recipient in ([?]^NRC_Connection{c, observer}) {
			if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
			item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			msg, err := pr.parseTaskMoved(frame[offset:])
			testing.expect(t, err == nil && msg.status == .Todo && msg.order_index == 9)
		}
	}
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT count(*)=1 FROM history WHERE json_extract(body,'$.entityId')='7' AND json_extract(body,'$.fields')='[\"order_index\"]'",
	)
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}
