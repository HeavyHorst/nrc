package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync/chan"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

reader_writer_test_command :: proc(store: ^Store, request: ^Request, output: ^Command_Output) -> c.int {
	pointer: rawptr
	copy(([^]byte)(&pointer)[:size_of(pointer)], request.body)
	gate := (^Group_Commit_Test_Gate)(pointer)
	if request.request_id == 1 || request.request_id == 3 {
		task := pr.Task {
			id     = request.request_id,
			status = .Todo,
		}
		if rc := put_task(store, "w", &task); rc != sql.OK do return rc
	}
	before, rc := scalar(store, "SELECT count(*) FROM tasks")
	if rc != sql.OK do return rc
	if request.request_id <= 2 {
		chan.send(gate.entered, true)
		_, _ = chan.recv(gate.resume)
	}
	after, after_rc := scalar(store, "SELECT count(*) FROM tasks")
	if after_rc != sql.OK do return after_rc
	if request.request_id == 4 {
		// Reader scratch tables remain writable; main is opened read-only.
		if temp_rc := execute(store, "CREATE TEMP TABLE scratch(n); INSERT INTO scratch VALUES(7); DROP TABLE scratch"); temp_rc != sql.OK do return temp_rc
		for _ in 0 ..< 9 {
			if _, frame_rc := command_frame(output, 700); frame_rc != sql.OK do return frame_rc
		}
		return sql.OK
	}
	frame, frame_rc := command_frame(output, 2)
	if frame_rc != sql.OK do return frame_rc
	frame[0] = byte(before); frame[1] = byte(after)
	return sql.OK
}

@(test)
test_reader_writer_snapshot_barrier_and_spool :: proc(t: ^testing.T) {
	for same_port in ([2]bool{false, true}) do exercise_reader_writer_snapshot(t, same_port)
}

exercise_reader_writer_snapshot :: proc(t: ^testing.T, same_port: bool) {
	dir, path := test_database_path(t)
	defer test_remove_database(dir, path)
	gate: Group_Commit_Test_Gate
	gate.entered, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	gate.resume, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	defer chan.destroy(gate.entered)
	defer chan.destroy(gate.resume)
	pointer := rawptr(&gate)
	paths := [1]cstring{path}
	e, err := start_executor(
		paths[:],
		same_port ? 1 : 2,
		4,
		64 * 1024,
		1024,
		context.allocator,
		create_databases = true,
		command_handler = reader_writer_test_command,
	)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	a, b := &e.ports[0], &e.ports[same_port ? 0 : 1]
	request := Request {
		ordering_key = 1,
		operation    = .Command,
		opcode       = .C_ApplyTransaction,
		workspace    = "w",
		request_id   = 1,
		body         = ([^]byte)(&pointer)[:size_of(pointer)],
	}
	assert(submit(a, request)); _, _ = chan.recv(gate.entered)
	// An independent reader completes while the writer has uncommitted data.
	// The same-connection reader must wait. An independent read behind that
	// blocked read must complete even when both use the same worker port.
	read := Request {
		ordering_key = 1,
		operation    = .Get_Task,
		workspace    = "w",
		task_id      = 1,
		request_id   = 100,
	}
	assert(submit(a, read)); read.ordering_key = 2; assert(submit(b, read))
	job := await_completion(b)
	testing.expect(t, job.result.status == sql.OK && !job.result.found)
	release_completion(b, job)
	_, early := receive(a); testing.expect(t, !early)
	chan.send(gate.resume, true)
	job = await_completion(a); testing.expect_value(t, job.result.status, sql.OK); release_completion(a, job)
	job = await_completion(a)
	testing.expect(t, job.request.request_id == 100 && job.result.status == sql.OK && job.result.found)
	release_completion(a, job)
	// Conversely, a reader holding a snapshot cannot stall the writer. Both
	// SELECTs in its response must see one snapshot, then the next read is fresh.
	request.request_id = 2; request.opcode = .C_GetTasks; request.ordering_key = 2
	assert(submit(b, request)); _, _ = chan.recv(gate.entered)
	// Skip a blocked write too, without overtaking its connection's read.
	assert(submit(b, {operation = .Put_Task, workspace = "w", task = {id = 6, status = .Todo}, ordering_key = 2, request_id = 106}))
	assert(submit(a, {operation = .Put_Task, workspace = "w", task = {id = 7, status = .Todo}, ordering_key = 1}))
	job = await_completion(a); testing.expect_value(t, job.result.status, sql.OK); release_completion(a, job)
	chan.send(gate.resume, true)
	job = await_completion(b)
	testing.expect_value(t, job.result.status, sql.OK)
	if testing.expect_value(t, job.result.command.count, 1) {
		testing.expect_value(t, string(job.result.command.frames[0].payload), "\x01\x01")
	}
	release_completion(b, job)
	job = await_completion(b); testing.expect(t, job.result.status == sql.OK && job.request.request_id == 106); release_completion(b, job)
	read.task_id = 7; assert(submit(b, read))
	job = await_completion(b); testing.expect(t, job.result.status == sql.OK && job.result.found); release_completion(b, job)
	// A misclassified read cannot mutate main, and does not poison later work.
	request.request_id = 3; assert(submit(b, request))
	job = await_completion(b); testing.expect(t, job.result.status != sql.OK && job.result.command.count == 0); release_completion(b, job)
	read.task_id = 3; assert(submit(b, read))
	job = await_completion(b); testing.expect(t, job.result.status == sql.OK && !job.result.found); release_completion(b, job)
	// An unread spool holds credits/FIFO, but no SQLite snapshot. Checkpointing
	// must still finish while the network consumer retains the first chunk.
	request.request_id = 4; assert(submit(b, request))
	job = await_completion(b)
	testing.expect(t, job.result.status == sql.OK && job.result.command.more)
	assert(submit(b, {operation = .Put_Task, workspace = "w", task = {id = 8, status = .Todo}, ordering_key = 2}))
	assert(submit(a, {operation = .Put_Task, workspace = "w", task = {id = 9, status = .Todo}, ordering_key = 1}))
	written := await_completion(a); testing.expect_value(t, written.result.status, sql.OK); release_completion(a, written)
	// A new generation with the same slot must not inherit the old spool's
	// dependency. Independent readers can pass a held read spool too.
	assert(submit(b, {operation = .Get_Task, workspace = "w", task_id = 9, ordering_key = (u64(1) << 32) | 2}))
	fresh := await_completion(b); testing.expect(t, fresh.result.status == sql.OK && fresh.result.found); release_completion(b, fresh)
	assert(submit(b, {operation = .Get_Task, workspace = "w", task_id = 8, ordering_key = 2}))
	store, rc := open(path); testing.expect_value(t, rc, sql.OK)
	checkpoint, checkpoint_rc := scalar(&store, "PRAGMA wal_checkpoint(TRUNCATE)")
	testing.expect(t, checkpoint_rc == sql.OK && checkpoint == 0, "spooled reader retained a WAL snapshot")
	close(&store)
	for &port in e.ports do finish_submissions(&port)
	frames := 0
	for {
		frames += job.result.command.count
		more := job.result.command.more
		release_completion(b, job)
		if !more do break
		job = await_completion(b); testing.expect_value(t, job.result.status, sql.OK)
	}
	testing.expect_value(t, frames, 9)
	job = await_completion(b); testing.expect_value(t, job.result.status, sql.OK); release_completion(b, job)
	job = await_completion(b); testing.expect(t, job.result.status == sql.OK && job.result.found); release_completion(b, job)
	join_executor(e)
}

@(test)
test_writer_publication_waits_for_reader_predecessor :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	defer test_remove_database(dir, path)
	gate: Group_Commit_Test_Gate
	gate.entered, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	gate.resume, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	defer chan.destroy(gate.entered)
	defer chan.destroy(gate.resume)
	pointer := rawptr(&gate)
	paths := [1]cstring{path}
	e, err := start_executor(paths[:], 1, 4, 64 * 1024, 1024, context.allocator, create_databases = true, command_handler = reader_writer_test_command)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	port := &e.ports[0]
	request := Request {
		ordering_key = 1,
		operation    = .Command,
		opcode       = .C_GetTasks,
		workspace    = "w",
		request_id   = 2,
		body         = ([^]byte)(&pointer)[:size_of(pointer)],
	}
	assert(submit(port, request)); _, _ = chan.recv(gate.entered)
	// Keep the reader's result unconsumed while its dependent writer and an
	// independent writer complete. Non-groupable commands give the final gate
	// a separate transaction, proving both earlier writers have published.
	request.opcode = .C_ListDMs; request.request_id = 1; assert(submit(port, request))
	chan.send(gate.resume, true)
	_, _ = chan.recv(gate.entered)
	request.ordering_key = 2; request.request_id = 6; assert(submit(port, request))
	request.ordering_key = 3; request.request_id = 2; assert(submit(port, request))
	chan.send(gate.resume, true)
	_, _ = chan.recv(gate.entered)
	for expected in ([3]u64{2, 1, 6}) {
		job := await_completion(port)
		testing.expect_value(t, job.request.request_id, expected)
		testing.expect_value(t, job.result.status, sql.OK)
		release_completion(port, job)
	}
	chan.send(gate.resume, true)
	finish_submissions(port)
	job := await_completion(port)
	testing.expect(t, job.request.request_id == 2 && job.result.status == sql.OK)
	release_completion(port, job)
	join_executor(e)
}

Group_Commit_Test_Gate :: struct {
	entered, resume: chan.Chan(bool),
	mode:            int,
}

group_commit_test_command :: proc(store: ^Store, request: ^Request, output: ^Command_Output) -> c.int {
	pointer: rawptr
	copy(([^]byte)(&pointer)[:size_of(pointer)], request.body)
	gate := (^Group_Commit_Test_Gate)(pointer)
	if request.request_id <= 2 {
		chan.send(gate.entered, true)
		_, _ = chan.recv(gate.resume)
	}
	task := pr.Task {
		id     = request.request_id,
		status = .Todo,
	}
	if rc := put_task(store, request.workspace, &task); rc != sql.OK do return rc
	_, rc := command_frame(output, 2, .Subscribers)
	if rc != sql.OK do return rc
	if request.request_id == 2 {
		switch gate.mode {
		case 0:
			return sql.CONSTRAINT
		case 1:
			return execute(store, "INSERT INTO fault_child VALUES(1)")
		case 2:
			return sql.TOOBIG
		case 3:
			return execute(store, "INSERT INTO fault_rollback VALUES(1)")
		case 4:
			return execute(store, "CREATE TEMP TRIGGER fail_summary BEFORE DELETE ON slice_pending BEGIN SELECT RAISE(ABORT,'finalization fixture'); END")
		case 5, 7:
			for _ in 0 ..< 9 {
				if _, frame_rc := command_frame(output, 700); frame_rc != sql.OK do return frame_rc
			}
			assert(output.spool.open)
			if gate.mode == 5 {linux.close(output.spool.fd); output.spool.fd = -1}
		}
	}
	return sql.OK
}

@(test)
test_group_commit_create_before_finalization_and_spool_failure :: proc(t: ^testing.T) {
	for mode in 4 ..= 7 {
		dir, path := test_database_path(t)
		defer test_remove_database(dir, path)
		store, rc := open(path, true)
		if !testing.expect_value(t, rc, sql.OK) do return
		defer close(&store)
		gate := Group_Commit_Test_Gate {
			mode = mode,
		}
		gate.entered, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
		gate.resume, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
		defer chan.destroy(gate.entered)
		defer chan.destroy(gate.resume)
		pointer := rawptr(&gate)
		paths := [1]cstring{path}
		e, err := start_executor(paths[:], 1, 4, 64 * 1024, 1024, context.allocator, command_handler = group_commit_test_command)
		if !testing.expect_value(t, err, .None) do return
		p := &e.ports[0]
		request := Request {
			ordering_key = 10,
			operation    = .Command,
			opcode       = .C_ApplyTransaction,
			workspace    = "w",
			body         = ([^]byte)(&pointer)[:size_of(pointer)],
			request_id   = 1,
		}
		assert(submit(p, request)); _, _ = chan.recv(gate.entered)
		attachment := [1]pr.Attachment{{file_id = transmute([]byte)string("owned-file"), size = 73}}
		assert(
			submit(
				p,
				{
					operation = .Create_Task,
					request_id = 99,
					workspace = "created",
					subject = "alice",
					task = {title = transmute([]byte)string("owned title"), status = .Todo, attachments = attachment[:]},
				},
			),
		)
		request.request_id = 2; request.ordering_key = 20; assert(submit(p, request))
		request.request_id = 3; request.ordering_key = 30; assert(submit(p, request))
		finish_submissions(p)
		chan.send(gate.resume, true); _, _ = chan.recv(gate.entered)
		count, count_rc := scalar(&store, "SELECT count(*) FROM tasks")
		testing.expect(t, count_rc == sql.OK && count == 0)
		chan.send(gate.resume, true)
		early: ^Completion
		for id in ([4]u64{1, 99, 2, 3}) {
			frames := 0
			for {
				job := early; early = nil
				if job == nil do job = await_completion(p)
				testing.expect_value(t, job.request.request_id, id)
				failed := mode == 4 || mode == 5 && id != 3
				testing.expect(t, (job.result.status != sql.OK) == failed)
				frames += job.result.command.count
				if id == 99 {
					testing.expect_value(t, job.result.found, !failed)
					testing.expect_value(t, string(job.result.task.title), failed ? "" : "owned title")
					testing.expect_value(t, string(job.request.task.title), failed ? "owned title" : "")
				}
				if mode == 7 && id == 2 {
					count, count_rc = scalar(&store, "SELECT count(*) FROM tasks WHERE workspace=x'77' AND id=x'0000000000000003'")
					testing.expect(t, count_rc == sql.OK && count == 0, "spooled output did not gate subsequent write")
					ready: bool
					early, ready = receive(p)
					testing.expect(t, !ready, "later response overtook spool during shutdown")
				}
				more := job.result.command.more
				release_completion(p, job)
				if !more do break
			}
			failed := mode == 4 || mode == 5 && id != 3
			testing.expect_value(t, frames, failed || id == 99 ? 0 : (mode == 7 && id == 2 ? 10 : 1))
		}
		join_executor(e)
		testing.expect(t, p.in_flight == 0 && p.charged_bytes == 0)
		destroy_executor(e)
		count, count_rc = scalar(&store, "SELECT count(*) FROM tasks")
		testing.expect(t, count_rc == sql.OK && count == (mode == 4 ? 0 : (mode == 5 ? 1 : 4)))
		count, count_rc = scalar(&store, "SELECT count(*) FROM history")
		testing.expect(t, count_rc == sql.OK && count == (mode < 6 ? 0 : 1))
		count, count_rc = scalar(&store, "SELECT count(*) FROM task_attachments")
		testing.expect(t, count_rc == sql.OK && count == (mode < 6 ? 0 : 1))
	}
}

@(test)
test_group_commit_job_read_and_shard_boundaries :: proc(t: ^testing.T) {
	for mode in 0 ..< 3 {
		dir, path := test_database_path(t); defer test_remove_database(dir, path)
		dir_b, path_b := test_database_path(t); defer test_remove_database(dir_b, path_b)
		store, rc := open(path, true); if !testing.expect_value(t, rc, sql.OK) do return
		defer close(&store)
		other, other_rc := open(path_b, true); if !testing.expect_value(t, other_rc, sql.OK) do return
		defer close(&other)
		gate := Group_Commit_Test_Gate {
			mode = 6,
		}
		gate.entered, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
		gate.resume, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
		defer chan.destroy(gate.entered)
		defer chan.destroy(gate.resume)
		pointer := rawptr(&gate)
		paths := [2]cstring{path, path_b}
		e, err := start_executor(paths[:], 1, 33, mem.Megabyte, 1024, context.allocator, command_handler = group_commit_test_command)
		if !testing.expect_value(t, err, .None) do return
		p := &e.ports[0]
		request := Request {
			operation  = .Command,
			opcode     = .C_ApplyTransaction,
			workspace  = "w",
			body       = ([^]byte)(&pointer)[:size_of(pointer)],
			request_id = 1,
		}
		assert(submit(p, request)); _, _ = chan.recv(gate.entered)
		if mode == 0 {
			for id in 3 ..= 33 {request.request_id = u64(id); assert(submit(p, request))}
		} else if mode == 1 {
			assert(submit(p, {operation = .Get_Task, request_id = 99, workspace = "w", task_id = 1}))
		} else {
			request.shard = 1
		}
		request.request_id = 2; assert(submit(p, request))
		finish_submissions(p)
		chan.send(gate.resume, true); _, _ = chan.recv(gate.entered)
		// The final handler is blocked: the previous group must already be
		// durable and published, including a read barrier's response.
		count, count_rc := scalar(&store, "SELECT count(*) FROM tasks")
		testing.expect(t, count_rc == sql.OK && count == (mode == 0 ? 32 : 1))
		count, count_rc = scalar(&other, "SELECT count(*) FROM tasks")
		testing.expect(t, count_rc == sql.OK && count == 0)
		published := 0
		for {
			job, ok := receive(p); if !ok do break
			expected := published == 0 ? u64(1) : (mode == 0 ? u64(published + 2) : u64(99))
			testing.expect_value(t, job.request.request_id, expected)
			testing.expect_value(t, job.result.status, sql.OK)
			if mode == 1 && published == 1 do testing.expect(t, job.result.found && job.result.task.id == 1)
			published += 1; release_completion(p, job)
		}
		testing.expect_value(t, published, mode == 0 ? 32 : (mode == 1 ? 2 : 1))
		chan.send(gate.resume, true); join_executor(e)
		total := mode == 0 ? 33 : (mode == 1 ? 3 : 2)
		for _ in published ..< total {
			job := await_completion(p)
			testing.expect_value(t, job.result.status, sql.OK)
			release_completion(p, job)
		}
		testing.expect(t, p.in_flight == 0 && p.charged_bytes == 0)
		destroy_executor(e)
	}
}

@(test)
test_group_commit_visibility_savepoints_and_failed_commit :: proc(t: ^testing.T) {
	for mode in 0 ..< 4 {
		dir, path := test_database_path(t); if path == nil do return
		defer test_remove_database(dir, path)
		store, rc := open(path, true)
		if !testing.expect_value(t, rc, sql.OK) do return
		defer close(&store)
		testing.expect_value(
			t,
			execute(
				&store,
				`CREATE TABLE fault_parent(id INTEGER PRIMARY KEY);
CREATE TABLE fault_child(id INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED);
CREATE TABLE fault_rollback(id INTEGER);
CREATE TRIGGER force_rollback BEFORE INSERT ON fault_rollback BEGIN SELECT RAISE(ROLLBACK,'fixture'); END;`,
			),
			sql.OK,
		)
		gate := Group_Commit_Test_Gate {
			mode = mode,
		}
		gate.entered, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
		gate.resume, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
		defer chan.destroy(gate.entered)
		defer chan.destroy(gate.resume)
		pointer := rawptr(&gate)
		paths := [1]cstring{path}
		e, err := start_executor(paths[:], 1, 3, 64 * 1024, 1024, context.allocator, command_handler = group_commit_test_command)
		if !testing.expect_value(t, err, .None) do return
		p := &e.ports[0]
		request := Request {
			operation  = .Command,
			opcode     = .C_ApplyTransaction,
			workspace  = "w",
			body       = ([^]byte)(&pointer)[:size_of(pointer)],
			request_id = 1,
		}
		assert(submit(p, request))
		_, _ = chan.recv(gate.entered)
		request.request_id = 2; assert(submit(p, request))
		request.request_id = 3; assert(submit(p, request))
		finish_submissions(p)
		chan.send(gate.resume, true)
		_, _ = chan.recv(gate.entered)
		// Job one has finished, but neither its event nor its row may escape
		// while the second member of its group is still running.
		early, received := receive(p)
		testing.expect(t, !received, "response escaped before group commit")
		if received do release_completion(p, early)
		count, count_rc := scalar(&store, "SELECT count(*) FROM tasks")
		testing.expect(t, count_rc == sql.OK && count == 0)
		chan.send(gate.resume, true)
		join_executor(e)
		for id in 1 ..= 3 {
			if received && id == 1 do continue
			job := await_completion(p)
			testing.expect_value(t, job.request.request_id, u64(id))
			failed := mode == 1 || mode == 3 && id < 3 || id == 2
			testing.expect(t, (job.result.status != sql.OK) == failed)
			testing.expect_value(t, job.result.command.count, failed ? 0 : 1)
			release_completion(p, job)
		}
		if mode == 0 {
			stats := metrics_snapshot(p)
			testing.expect_value(t, stats.counters[.Admitted_Write], u64(3))
			testing.expect_value(t, stats.counters[.Completed_Write], u64(3))
			testing.expect_value(t, stats.counters[.Group_Transactions], u64(1))
			testing.expect_value(t, stats.counters[.Group_Jobs], u64(3))
			testing.expect_value(t, stats.counters[.Errors], u64(1))
			testing.expect_value(t, stats.counters[.In_Flight], u64(0))
			testing.expect(t, stats.counters[.Cache_Hits] > 0)
			for hist, index in stats.histograms {
				count: u64
				for bucket in hist.buckets do count += bucket
				expected := index < 3 ? u64(3) : (index >= 6 ? u64(1) : u64(0))
				testing.expect_value(t, count, expected)
			}
		}
		destroy_executor(e)
		count, count_rc = scalar(&store, "SELECT count(*) FROM tasks")
		testing.expect(t, count_rc == sql.OK && count == (mode == 1 ? 0 : (mode == 3 ? 1 : 2)))
		count, count_rc = scalar(&store, "SELECT coalesce(sum(total),0) FROM workspace_task_counts")
		testing.expect(t, count_rc == sql.OK && count == (mode == 1 ? 0 : (mode == 3 ? 1 : 2)))
	}
}

foreign import metrics_test_sqlite "system:sqlite3"
foreign metrics_test_sqlite {
	@(link_name = "sqlite3_busy_handler")
	metrics_test_busy_handler :: proc "c" (db: ^sql.Database, callback: proc "c" (_: rawptr, _: c.int) -> c.int, data: rawptr) -> c.int ---
}

metrics_busy_test_command :: proc(store: ^Store, request: ^Request, output: ^Command_Output) -> c.int {
	// Test-only delay makes BEGIN's contribution distinguishable from the
	// handler. Runtime connections retain their existing immediate BUSY policy.
	if rc := sql.busy_timeout(store.db, 50); rc != sql.OK do return rc
	if len(request.body) != 0 {
		pointer: rawptr
		copy(([^]byte)(&pointer)[:size_of(pointer)], request.body)
		rc := metrics_test_busy_handler(store.db, proc "c" (data: rawptr, calls: c.int) -> c.int {
				context = runtime.default_context()
				if calls != 0 do return 0
				gate := (^Group_Commit_Test_Gate)(data)
				chan.send(gate.entered, true)
				_, _ = chan.recv(gate.resume)
				return 1
			}, pointer)
		if rc != sql.OK do return rc
	}
	task := pr.Task {
		id     = request.task_id,
		status = .Todo,
	}
	return put_task(store, request.workspace, &task)
}

@(test)
test_group_begin_busy_metrics_and_recovery :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	paths := [1]cstring{path}
	e, err := start_executor(paths[:], 1, 4, 64 * 1024, 1024, context.allocator, command_handler = metrics_busy_test_command)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	p := &e.ports[0]
	// Warm the writer handle before taking the competing lock, so this probes
	// BEGIN, not the lazy-open initialization lock.
	request := Request {
		operation = .Command,
		opcode    = .C_UpdateTask,
		workspace = "w",
		task_id   = 7,
	}
	assert(submit(p, request))
	job := await_completion(p)
	testing.expect_value(t, job.result.status, sql.OK)
	release_completion(p, job)
	before := metrics_snapshot(p)
	testing.expect_value(t, begin(&store), sql.OK)
	request.task_id = 8
	assert(submit(p, request))
	job = await_completion(p)
	testing.expect_value(t, job.result.status, sql.BUSY)
	release_completion(p, job)
	busy := metrics_snapshot(p)
	testing.expect(t, busy.histograms[1].sum_ns - before.histograms[1].sum_ns >= 40_000_000, "BEGIN lock wait must count as execution")
	testing.expect_value(t, rollback(&store), sql.OK)
	assert(submit(p, request))
	finish_submissions(p); join_executor(e)
	job = await_completion(p)
	testing.expect_value(t, job.result.status, sql.OK)
	release_completion(p, job)
	stats := metrics_snapshot(p)
	testing.expect_value(t, stats.counters[.Completed_Write], u64(3))
	testing.expect_value(t, stats.counters[.Busy], u64(1))
	for hist, index in stats.histograms {
		count: u64
		for bucket in hist.buckets do count += bucket
		expected := index < 3 ? u64(3) : (index >= 6 ? u64(2) : u64(0))
		testing.expect_value(t, count, expected)
	}
	count, count_rc := scalar(&store, "SELECT count(*) FROM tasks")
	testing.expect(t, count_rc == sql.OK && count == 2)
}

@(test)
test_group_begin_delayed_success_metrics :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	gate: Group_Commit_Test_Gate
	gate.entered, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	gate.resume, _ = chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	defer chan.destroy(gate.entered)
	defer chan.destroy(gate.resume)
	pointer := rawptr(&gate)
	paths := [1]cstring{path}
	e, err := start_executor(paths[:], 1, 4, 64 * 1024, 1024, context.allocator, command_handler = metrics_busy_test_command)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	p := &e.ports[0]
	request := Request {
		operation = .Command,
		opcode    = .C_UpdateTask,
		workspace = "w",
		task_id   = 7,
		body      = ([^]byte)(&pointer)[:size_of(pointer)],
	}
	// Warm the handle and install the test-only busy callback on its owner.
	assert(submit(p, request))
	job := await_completion(p)
	testing.expect_value(t, job.result.status, sql.OK)
	release_completion(p, job)
	before := metrics_snapshot(p)
	testing.expect_value(t, begin(&store), sql.OK)
	request.task_id = 8
	assert(submit(p, request))
	// SQLite confirms BEGIN encountered the lock before the measured delay.
	// Release before permitting its retry: no race against a timeout/sleeper.
	_, _ = chan.recv(gate.entered)
	time.sleep(50 * time.Millisecond)
	testing.expect_value(t, rollback(&store), sql.OK)
	chan.send(gate.resume, true)
	finish_submissions(p); join_executor(e)
	job = await_completion(p)
	testing.expect_value(t, job.result.status, sql.OK)
	release_completion(p, job)
	stats := metrics_snapshot(p)
	testing.expect(t, stats.histograms[1].sum_ns - before.histograms[1].sum_ns >= 40_000_000, "successful BEGIN must retain its lock wait in execution")
	testing.expect_value(t, stats.counters[.Errors], u64(0))
	testing.expect_value(t, stats.counters[.Completed_Write], u64(2))
	for hist, index in stats.histograms {
		count: u64
		for bucket in hist.buckets do count += bucket
		testing.expect_value(t, count, index < 3 || index >= 6 ? u64(2) : u64(0))
	}
	count, count_rc := scalar(&store, "SELECT count(*) FROM tasks")
	testing.expect(t, count_rc == sql.OK && count == 2)
}

@(test)
test_executor_create_task_atomic_history_order_and_reopen :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	defer test_remove_database(dir, path)
	store, rc := open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, begin(&store), sql.OK)
	seed := pr.Task {
		id          = 7,
		status      = .Todo,
		order_index = 9,
	}
	testing.expect_value(t, put_task(&store, "w", &seed), sql.OK)
	seed.id = 40; seed.status = .Done; seed.order_index = max(u16) - 1
	testing.expect_value(t, put_task(&store, "w", &seed), sql.OK)
	seed.id = 99; seed.status = .Todo; seed.order_index = 65000
	testing.expect_value(t, put_task(&store, "other", &seed), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	paths := [1]cstring{path}
	e, err := start_executor(paths[:], 1, 2, 64 * 1024, 4096, context.allocator)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	p := &e.ports[0]
	defer {finish_submissions(p); join_executor(e)}
	attachments := [1]pr.Attachment{{file_id = transmute([]byte)string("file"), size = 73}}
	request := Request {
		operation = .Create_Task,
		workspace = "w",
		subject = "subject-1",
		task = pr.Task {
			title = transmute([]byte)string("  Created  "),
			created_by = transmute([]byte)string("alice"),
			status = .Todo,
			created_at = 173,
			updated_at = 173,
			attachments = attachments[:],
		},
	}
	testing.expect(t, submit(p, request))
	job := await_completion(p)
	testing.expect(t, job.result.status == sql.OK && job.result.found)
	testing.expect_value(t, job.result.task.id, u64(100))
	testing.expect_value(t, job.result.task.order_index, u16(10))
	testing.expect_value(t, len(job.result.task.attachments), 1)
	release_completion(p, job)

	// Fail after task, attachment and BOTH floors have been written. The next
	// successful create must reuse the uncommitted ID and column position.
	testing.expect_value(t, execute(&store, "CREATE TRIGGER fail_history BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture'); END"), sql.OK)
	testing.expect(t, submit(p, request))
	job = await_completion(p)
	testing.expect(t, job.result.status == sql.CONSTRAINT && !job.result.found)
	release_completion(p, job)
	count, count_rc := scalar(&store, "SELECT count(*) FROM tasks")
	testing.expect(t, count_rc == sql.OK && count == 4)
	count, count_rc = scalar(&store, "SELECT count(*) FROM task_attachments")
	testing.expect(t, count_rc == sql.OK && count == 1)
	testing.expect_value(t, execute(&store, "DROP TRIGGER fail_history"), sql.OK)
	testing.expect(t, submit(p, request))
	job = await_completion(p)
	testing.expect(t, job.result.status == sql.OK && job.result.task.id == 101 && job.result.task.order_index == 11)
	release_completion(p, job)
	count, count_rc = scalar(
		&store,
		`SELECT count(*) FROM history WHERE
		json_extract(body,'$.actorId')='subject-1' AND json_extract(body,'$.actorName')='alice'
		AND json_extract(body,'$.entityLabel')='Created' AND json_extract(body,'$.action')='created'
		AND json_extract(body,'$.timestamp')='173' AND json_array_length(json_extract(body,'$.fields'))=14
		AND json_extract(body,'$.id') IN ('1','2')`,
	)
	testing.expect(t, count_rc == sql.OK && count == 2)
	request.task.status = .Done
	request.subject = ""
	testing.expect(t, submit(p, request))
	job = await_completion(p)
	testing.expect(t, job.result.status == sql.OK && job.result.task.id == 102 && job.result.task.order_index == max(u16))
	release_completion(p, job)
	count, count_rc = scalar(&store, "SELECT count(*) FROM history WHERE json_extract(body,'$.actorId')='service:alice'")
	testing.expect(t, count_rc == sql.OK && count == 1)
	testing.expect(t, submit(p, request))
	job = await_completion(p)
	testing.expect(t, job.result.status == sql.FULL && job.result.create_error == .Column_Full)
	release_completion(p, job)
	request.task.status = .Todo
	testing.expect_value(t, execute(&store, "UPDATE history_sequences SET high_water=x'ffffffffffffffff'"), sql.OK)
	testing.expect(t, submit(p, request))
	job = await_completion(p)
	testing.expect(t, job.result.status == sql.FULL && !job.result.found)
	release_completion(p, job)
	count, count_rc = scalar(&store, "SELECT count(*) FROM tasks")
	testing.expect(t, count_rc == sql.OK && count == 6)
	// Reopen independently; success already means a committed durable record.
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path)
	testing.expect_value(t, rc, sql.OK)
	persisted, found, read_rc := get_task(&store, "w", 0, 101)
	defer destroy_task(&persisted)
	testing.expect(t, read_rc == sql.OK && found && persisted.order_index == 11 && string(persisted.title) == "  Created  ")
	testing.expect_value(t, len(persisted.attachments), 1)
}

// A missed wake fails in finite time instead of hanging the test suite.
await_completion :: proc(port: ^Worker_Port) -> ^Completion {
	for {
		if job, ok := receive(port); ok do return job
		rearm_completions(port)
		fds := [1]linux.Poll_Fd{{fd = port.wake.fd, events = {.IN}}}
		n, err := linux.poll(fds[:], 5000)
		if err == .EINTR do continue
		assert(err == .NONE && n == 1, "completion wake timed out")
	}
}

executor_test_command :: proc(store: ^Store, request: ^Request, output: ^Command_Output) -> c.int {
	task := pr.Task {
		id         = request.request_id,
		title      = request.body,
		created_by = transmute([]byte)request.actor,
	}
	if rc := put_task(store, request.workspace, &task); rc != sql.OK do return rc
	body, rc := command_frame(output, len(request.body), .Requester)
	if rc != sql.OK do return rc
	copy(body, request.body)
	if request.request_id == 2 {
		// Output exhaustion after a write and a prepared response must roll back
		// the write and suppress all responses, not merely the oversized frame.
		_, rc = command_frame(output, output.limit, .Subscribers)
		return rc
	}
	event, event_rc := command_frame(output, len(request.body), .Other_Subscribers, 0, request.actor)
	if event_rc != sql.OK do return event_rc
	copy(event, request.body)
	return sql.OK
}

@(test)
test_executor_commands_commit_with_bounded_output :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	if path == nil do return
	defer test_remove_database(dir, path)
	paths := [1]cstring{path}
	e, err := start_executor(paths[:], 1, 2, 64 * 1024, 4096, context.allocator, true, executor_test_command)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	p := &e.ports[0]
	body := [?]byte{'o', 'w', 'n', 'e', 'd'}
	reads := [1]Ticket_Read_Cursor{{17, 23}}
	request := Request {
		request_id   = 1,
		operation    = .Command,
		opcode       = .C_ApplyTransaction,
		workspace    = "w",
		actor        = "alice",
		body         = body[:],
		ticket_reads = reads[:],
	}
	testing.expect(t, submit(p, request))
	request.request_id = 2
	testing.expect(t, submit(p, request))
	copy(body[:], "reuse")
	reads[0] = {99, 100}
	testing.expect(t, !submit(p, request))
	finish_submissions(p); join_executor(e)
	store, rc := open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	for id in 1 ..= 2 {
		job := await_completion(p)
		testing.expect_value(t, job.request.request_id, u64(id))
		testing.expect_value(t, job.request.ticket_reads[0], Ticket_Read_Cursor{17, 23})
		if id == 1 {
			testing.expect_value(t, job.result.status, sql.OK)
			if testing.expect_value(t, job.result.command.count, 2) {
				testing.expect_value(t, string(job.result.command.frames[0].payload), "owned")
				testing.expect_value(t, job.result.command.frames[1].private_owner, "alice")
				testing.expect_value(t, job.result.command.frames[1].audience, Command_Audience.Other_Subscribers)
			}
		} else {
			testing.expect_value(t, job.result.status, sql.TOOBIG)
			testing.expect_value(t, job.result.command.count, 0)
		}
		persisted, found, read_rc := get_task(&store, "w", 0, u64(id))
		testing.expect(t, read_rc == sql.OK && found == (id == 1))
		if found {testing.expect_value(t, string(persisted.title), "owned"); testing.expect_value(t, string(persisted.created_by), "alice")}
		destroy_task(&persisted)
		release_completion(p, job)
	}
	testing.expect(t, p.in_flight == 0 && p.charged_bytes == 0)
}

@(test)
test_command_spool_live_allocation_budget :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	defer test_remove_database(dir, path)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	output := Command_Output {
		limit           = mem.Megabyte,
		spool_directory = dir,
	}
	for i in 0 ..< 30000 {
		body, rc := command_frame(&output, 22)
		if !testing.expect_value(t, rc, sql.OK) do break
		for &b in body do b = byte(i % 251)
	}
	testing.expect(t, tracker.peak_memory_allocated <= mem.Megabyte, "preparation exceeded live allocation budget")
	testing.expect_value(t, seal_command_output(&output), sql.OK)
	testing.expect(t, tracker.peak_memory_allocated <= mem.Megabyte, "sealing exceeded live allocation budget")
	tracker.peak_memory_allocated = tracker.current_memory_allocated
	seen := 0
	for {
		for frame in output.frames[:output.count] {
			for b in frame.payload do testing.expect_value(t, b, byte(seen % 251))
			seen += 1
		}
		if !output.more do break
		if !testing.expect_value(t, read_command_chunk(&output), sql.OK) do break
	}
	testing.expect_value(t, seen, 30000)
	testing.expect(t, tracker.peak_memory_allocated <= mem.Megabyte, "chunk reading exceeded live allocation budget")
	destroy_command_output(&output)
	testing.expect_value(t, tracker.current_memory_allocated, i64(0))
}

executor_spool_test_command :: proc(store: ^Store, request: ^Request, output: ^Command_Output) -> c.int {
	task := pr.Task {
		id    = request.request_id,
		title = transmute([]byte)string("spooled"),
	}
	if rc := put_task(store, request.workspace, &task); rc != sql.OK do return rc
	count := request.request_id == 99 ? 1 : 9
	for i in 0 ..< count {
		owner := i % 2 == 0 ? "alice" : ""
		body, rc := command_frame(output, 700, Command_Audience(i % 3), (u64(1) << 63) + u64(i), owner)
		if rc != sql.OK do return rc
		for &b in body do b = byte(i + 1)
	}
	if request.body[0] == 1 do return sql.CONSTRAINT
	if request.body[0] == 2 {
		// Fail the final write/sync before commit without a production fault hook.
		assert(output.spool.open)
		linux.close(output.spool.fd); output.spool.fd = -1
	}
	return sql.OK
}

@(test)
test_executor_spool_order_credits_rollback_and_read_failure :: proc(t: ^testing.T) {
	for mode in 0 ..< 4 {
		dir, path := test_database_path(t)
		if path == nil do return
		defer test_remove_database(dir, path)
		paths := [1]cstring{path}
		e, err := start_executor(paths[:], 1, 2, 64 * 1024, 1024, context.allocator, true, executor_spool_test_command)
		if !testing.expect_value(t, err, .None) do return
		p := &e.ports[0]
		mode_bytes := [1]byte{byte(mode)}
		testing.expect(t, submit(p, {request_id = 7, operation = .Command, opcode = .C_ApplyTransaction, workspace = "w", body = mode_bytes[:]}))
		zero := [1]byte{0}
		testing.expect(t, submit(p, {request_id = 99, operation = .Command, opcode = .C_ApplyTransaction, workspace = "w", body = zero[:]}))
		finish_submissions(p)
		seen := 0
		for {
			job := await_completion(p)
			testing.expect_value(t, job.request.request_id, u64(7))
			if mode == 1 || mode == 2 {
				testing.expect_value(t, job.result.status, mode == 1 ? sql.CONSTRAINT : sql.IOERR)
				testing.expect_value(t, job.result.command.count, 0)
				testing.expect(t, !job.result.delivery_failed)
			} else if mode == 3 && seen > 0 {
				testing.expect_value(t, job.result.status, sql.IOERR)
				testing.expect(t, job.result.delivery_failed && !job.result.command.more)
				testing.expect_value(t, job.result.command.count, 0)
			} else {
				testing.expect_value(t, job.result.status, sql.OK)
				testing.expect(t, job.result.command.spool.open && job.result.command.bytes <= 1024)
				for frame in job.result.command.frames[:job.result.command.count] {
					testing.expect_value(t, frame.scope, (u64(1) << 63) + u64(seen))
					testing.expect_value(t, frame.audience, Command_Audience(seen % 3))
					testing.expect_value(t, frame.private_owner, seen % 2 == 0 ? "alice" : "")
					testing.expect_value(t, len(frame.payload), 700)
					for b in frame.payload do testing.expect_value(t, b, byte(seen + 1))
					seen += 1
				}
				if mode == 3 do testing.expect_value(t, linux.ftruncate(job.result.command.spool.fd, 0), linux.Errno.NONE)
				// A later job must not overtake a held chunk, even during shutdown.
				_, ready := receive(p); testing.expect(t, !ready)
			}
			more := job.result.command.more
			release_completion(p, job)
			if !more do break
			testing.expect_value(t, p.in_flight, 2)
		}
		if mode == 0 do testing.expect_value(t, seen, 9)
		control := await_completion(p)
		testing.expect_value(t, control.request.request_id, u64(99))
		testing.expect_value(t, control.result.status, sql.OK)
		testing.expect(t, !control.result.command.spool.open, "small outputs stay in RAM")
		release_completion(p, control)
		join_executor(e)
		testing.expect(t, p.in_flight == 0 && p.charged_bytes == 0)
		destroy_executor(e)
		store, rc := open(path)
		if !testing.expect_value(t, rc, sql.OK) do return
		persisted, found, read_rc := get_task(&store, "w", 0, 7)
		testing.expect(t, read_rc == sql.OK && found == (mode == 0 || mode == 3))
		destroy_task(&persisted)
		testing.expect_value(t, close(&store), sql.OK)
	}
}

// Run actual independent producers against two queues and two files on one DB
// executor. The same workspace/id in both files must remain independent.
Executor_Client :: struct {
	port:   ^Worker_Port,
	shard:  int,
	failed: bool,
}
exercise_executor_client :: proc(client: ^Executor_Client) {
	port := client.port
	for round in 0 ..< 100 {
		title := [3]byte{byte(client.shard + 7), byte(round), 19}
		file := [2]byte{byte(round), 61}
		attachments := [1]pr.Attachment{{file_id = file[:], filename = transmute([]byte)string("test.bin"), size = u64(round + 27)}}
		task := pr.Task {
			id          = (u64(1) << 63) + 7,
			conv_id     = 0,
			title       = title[:],
			attachments = attachments[:],
		}
		put := Request {
			request_id = u64(round * 3),
			shard      = client.shard,
			operation  = .Put_Task,
			workspace  = "shared",
			task       = task,
		}
		get := Request {
			request_id = u64(round * 3 + 1),
			shard      = client.shard,
			operation  = .Get_Task,
			workspace  = "shared",
			scope      = 0,
			task_id    = task.id,
		}
		remove := Request {
			request_id = u64(round * 3 + 2),
			shard      = client.shard,
			operation  = .Remove_Task,
			workspace  = "shared",
			scope      = 0,
			task_id    = task.id,
		}
		assert(submit(port, put))
		title[0] = 99; file[1] = 99 // Source storage may be overwritten immediately.
		assert(submit(port, get))
		assert(submit(port, remove))
		if submit(port, get) do client.failed = true
		for index in 0 ..< 3 {
			job := await_completion(port)
			if job.request.request_id != u64(round * 3 + index) || job.result.status != sql.OK do client.failed = true
			if index == 0 && submit(port, get) do client.failed = true // Pop is not credit release.
			if index == 1 {
				expected := [3]byte{byte(client.shard + 7), byte(round), 19}
				expected_file := [2]byte{byte(round), 61}
				if !job.result.found || string(job.result.task.title) != string(expected[:]) || len(job.result.task.attachments) != 1 {
					client.failed = true
				} else if string(job.result.task.attachments[0].file_id) != string(expected_file[:]) ||
				   job.result.task.attachments[0].size != u64(round + 27) {
					client.failed = true
				}
			}
			release_completion(port, job)
		}
	}
	finish_submissions(port)
}

@(test)
test_executor_concurrent_fifo_copies_and_shutdown :: proc(t: ^testing.T) {
	dir_a, path_a := test_database_path(t)
	defer test_remove_database(dir_a, path_a)
	dir_b, path_b := test_database_path(t)
	defer test_remove_database(dir_b, path_b)
	paths := [2]cstring{path_a, path_b}
	e, err := start_executor(paths[:], 2, 3, 64 * 1024, 4096, context.allocator, create_databases = true)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	clients := [2]Executor_Client{{port = &e.ports[0], shard = 0}, {port = &e.ports[1], shard = 1}}
	threads: [2]^thread.Thread
	for &client, i in clients do threads[i] = thread.create_and_start_with_poly_data(&client, exercise_executor_client)
	for worker in threads {thread.join(worker); thread.destroy(worker)}
	join_executor(e)
	for client in clients do testing.expect(t, !client.failed)
	// Reopen independently after the executor has closed all of its handles.
	for path in paths {
		store, rc := open(path)
		testing.expect_value(t, rc, sql.OK)
		task, found, read_rc := get_task(&store, "shared", 0, (u64(1) << 63) + 7)
		testing.expect(t, read_rc == sql.OK && !found)
		destroy_task(&task)
		testing.expect_value(t, close(&store), sql.OK)
	}
}

@(test)
test_executor_slow_port_byte_credits_and_full_shutdown :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	defer test_remove_database(dir, path)
	paths := [1]cstring{path}
	// Exactly two Get requests fit by bytes, despite three queue slots.
	budget := 2 * (size_of(Completion) + size_of(Order_Stream) + 1 + 1024)
	e, err := start_executor(paths[:], 2, 3, budget, 1024, context.allocator, create_databases = true)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	slow, fast := &e.ports[0], &e.ports[1]
	oversized := make([]byte, budget)
	defer delete(oversized)
	testing.expect(t, !submit(slow, Request{operation = .Put_Task, workspace = "w", task = pr.Task{id = 2, description = oversized}}))
	r := Request {
		operation = .Get_Task,
		workspace = "w",
		task_id   = 17,
	}
	testing.expect(t, submit(slow, r))
	testing.expect(t, submit(slow, r))
	rejection: Admission_Rejection
	testing.expect(t, !submit(slow, r, &rejection))
	testing.expect_value(t, rejection, .Worker_Limit)
	// Keep the slow port completely undrained while another port progresses.
	for i in 0 ..< 12 {
		r.request_id = u64(i + 100)
		testing.expect(t, submit(fast, r))
		job := await_completion(fast)
		testing.expect(t, job.request.request_id == u64(i + 100) && job.result.status == sql.OK && !job.result.found)
		release_completion(fast, job)
	}
	first := await_completion(slow)
	testing.expect(t, !submit(slow, r), "held completion retains its byte credit")
	release_completion(slow, first)
	testing.expect(t, submit(slow, r))
	finish_submissions(slow)
	finish_submissions(fast)
	testing.expect(t, !submit(slow, r))
	// Join with outstanding completions, without relying on concurrent draining.
	join_executor(e)
	rearm_completions(slow)
	fds := [1]linux.Poll_Fd{{fd = slow.wake.fd, events = {.IN}}}
	n, poll_err := linux.poll(fds[:], 0)
	testing.expect(t, n == 1 && poll_err == .NONE, "remaining completions keep the port readable")
	for _ in 0 ..< 2 {job := await_completion(slow); release_completion(slow, job)}
	rearm_completions(slow)
	n, poll_err = linux.poll(fds[:], 0)
	testing.expect(t, n == 0 && poll_err == .NONE, "drained port must not busy-loop")
}

@(test)
test_connection_admission_leaves_room_for_other_clients :: proc(t: ^testing.T) {
	for large_result in ([2]bool{false, true}) {
		dir, path := test_database_path(t)
		defer test_remove_database(dir, path)
		paths := [1]cstring{path}
		e, err := start_executor(paths[:], 1, 64, 16 * mem.Megabyte, large_result ? 5 * mem.Megabyte : 1024, context.allocator, create_databases = true)
		if !testing.expect_value(t, err, .None) do return
		defer destroy_executor(e)
		port := &e.ports[0]
		request := Request {
			operation    = .Get_Task,
			workspace    = "w",
			ordering_key = 1,
			task_id      = 7,
		}
		// Four small jobs hit the count limit; two 5 MiB reservations hit the
		// byte limit while the port itself still has room for both clients.
		count := large_result ? 1 : 4
		rejection: Admission_Rejection
		for i in 0 ..< count {
			r := request
			if i == 1 {r.operation = .Put_Task; r.task = {
					id     = 7,
					status = .Todo,
				}}
			testing.expect(t, submit(port, r))
		}
		testing.expect(t, !submit(port, request, &rejection))
		testing.expect_value(t, rejection, .Connection_Limit)
		held: [4]^Completion
		for i in 0 ..< count {
			held[i] = await_completion(port)
			testing.expect_value(t, held[i].result.status, sql.OK)
		}
		testing.expect(t, !submit(port, request), "receiving is not releasing admission credit")
		other := request; other.ordering_key = 2
		testing.expect(t, submit(port, other, &rejection))
		testing.expect_value(t, rejection, .None)
		job := await_completion(port)
		testing.expect(t, job.request.ordering_key == 2 && job.result.status == sql.OK)
		release_completion(port, job)
		testing.expect(t, !submit(port, request), "another client's release cannot refund this client")
		release_completion(port, held[0])
		testing.expect(t, submit(port, request), "final release restores this client's credit")
		job = await_completion(port); testing.expect_value(t, job.result.status, sql.OK); release_completion(port, job)
		for i in 1 ..< count do release_completion(port, held[i])
		// Reusing an idle connection starts with its full budget again.
		testing.expect(t, submit(port, request))
		finish_submissions(port)
		job = await_completion(port); testing.expect_value(t, job.result.status, sql.OK); release_completion(port, job)
		join_executor(e)
		testing.expect(t, port.in_flight == 0 && port.charged_bytes == 0)
	}
}

@(test)
test_admission_reserves_reads_and_first_writes :: proc(t: ^testing.T) {
	for bytes_bound in ([2]bool{false, true}) {
		dir, path := test_database_path(t)
		defer test_remove_database(dir, path)
		paths := [1]cstring{path}
		// Equal write/read charges isolate the count and byte boundaries.
		charge := size_of(Completion) + size_of(Order_Stream) + 1 + 1024
		e, err := start_executor(
			paths[:],
			1,
			bytes_bound ? 64 : 8,
			(bytes_bound ? 8 : 64) * charge,
			1024,
			context.allocator,
			create_databases = true,
			read_reserved_requests = bytes_bound ? 0 : 2,
			read_reserved_bytes = bytes_bound ? 2 * charge : 0,
		)
		if !testing.expect_value(t, err, .None) do return
		defer destroy_executor(e)
		port := &e.ports[0]
		body: [1024]byte
		write := Request {
			operation = .Put_Task,
			workspace = "w",
			ordering_key = 1,
			task = pr.Task{id = 7, description = body[:]},
		}
		testing.expect(t, submit(port, write))
		testing.expect(t, submit(port, write))
		write.ordering_key = 2
		testing.expect(t, submit(port, write))
		write.ordering_key = 1
		rejection: Admission_Rejection
		testing.expect(t, !submit(port, write, &rejection))
		testing.expect_value(t, rejection, .Connection_Limit)
		for key in u64(3) ..< 6 {
			write.ordering_key = key
			testing.expect(t, submit(port, write), "first writes can use the remaining writer credits")
		}
		write.ordering_key = 6
		testing.expect(t, !submit(port, write, &rejection))
		testing.expect_value(t, rejection, .Worker_Limit)
		read := Request {
			operation    = .Get_Task,
			workspace    = "w",
			ordering_key = 6,
			task_id      = 7,
		}
		testing.expect(t, submit(port, read), "writer saturation leaves read capacity")
		read.ordering_key = 7
		testing.expect(t, submit(port, read))
		read.ordering_key = 8
		testing.expect(t, !submit(port, read, &rejection))
		testing.expect_value(t, rejection, .Worker_Limit)
		stats := metrics_snapshot(port)
		testing.expect_value(t, stats.counters[.Rejected_Connection], u64(1))
		testing.expect_value(t, stats.counters[.Rejected_Worker], u64(2))
		testing.expect_value(t, stats.counters[.Rejected_Unavailable], u64(0))
		testing.expect_value(t, stats.counters[.Admitted_Write], u64(6))
		testing.expect_value(t, stats.counters[.Admitted_Read], u64(2))
		held: [8]^Completion
		for &job in held {
			job = await_completion(port)
			testing.expect_value(t, job.result.status, sql.OK)
		}
		testing.expect(t, !submit(port, write), "receiving does not release reserved capacity")
		// A released reader must not lend its reserved slot/bytes to writers.
		for &job in held {
			if job.request.operation == .Get_Task {
				release_completion(port, job); job = nil
				break
			}
		}
		testing.expect(t, !submit(port, write))
		testing.expect(t, submit(port, read))
		next := await_completion(port); release_completion(port, next)
		for &job in held {
			if job != nil {release_completion(port, job); job = nil}
		}
		testing.expect(t, submit(port, write), "final releases restore writer admission")
		next = await_completion(port); release_completion(port, next)
		// Readers can borrow idle write capacity. When they fill the shared
		// budget, a repeated write must report worker, not connection overload.
		testing.expect(t, submit(port, write))
		for key in u64(9) ..< 16 {
			read.ordering_key = key
			testing.expect(t, submit(port, read))
		}
		testing.expect(t, !submit(port, write, &rejection))
		testing.expect_value(t, rejection, .Worker_Limit)
		for _ in 0 ..< 8 {next = await_completion(port); release_completion(port, next)}
		finish_submissions(port)
		join_executor(e)
	}
}

@(test)
test_executor_errors_rollback_and_result_limit :: proc(t: ^testing.T) {
	dir, path := test_database_path(t)
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	original := pr.Task {
		id    = 7,
		title = transmute([]byte)string("old"),
	}
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, put_task(&store, "w", &original), sql.OK)
	// One result fits exactly; another exceeds the result budget in its second
	// attachment, after earlier fields have already been copied.
	attachments := [2]pr.Attachment{{file_id = transmute([]byte)string("a")}, {file_id = transmute([]byte)string("bc")}}
	large := pr.Task {
		id          = 8,
		title       = transmute([]byte)string("too large"),
		attachments = attachments[:],
	}
	testing.expect_value(t, put_task(&store, "w", &large), sql.OK)
	exact_attachments := attachments
	exact_attachments[1].file_id = transmute([]byte)string("b")
	exact := large
	exact.id = 9
	exact.attachments = exact_attachments[:]
	testing.expect_value(t, put_task(&store, "w", &exact), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(
		t,
		execute(&store, "CREATE TRIGGER reject_attachment BEFORE INSERT ON task_attachments BEGIN SELECT RAISE(ABORT, 'test failure'); END"),
		sql.OK,
	)
	testing.expect_value(t, close(&store), sql.OK)
	bad_name := fmt.aprintf("%s/absent.db", path)
	defer delete(bad_name)
	bad_path := strings.clone_to_cstring(bad_name)
	defer delete(bad_path)
	paths := [2]cstring{path, bad_path}
	result_limit := size_of(pr.Task) + 9 + 2 * size_of(pr.Attachment) + 2
	e, err := start_executor(paths[:], 1, 6, 64 * 1024, result_limit, context.allocator)
	if !testing.expect_value(t, err, .None) do return
	defer destroy_executor(e)
	p := &e.ports[0]
	broken := original
	broken.title = transmute([]byte)string("must roll back")
	broken.attachments = attachments[:]
	testing.expect(t, submit(p, Request{request_id = 1, operation = .Put_Task, workspace = "w", task = broken}))
	testing.expect(t, submit(p, Request{request_id = 2, operation = .Get_Task, workspace = "w", task_id = 7}))
	testing.expect(t, submit(p, Request{request_id = 3, operation = .Get_Task, workspace = "w", task_id = 8}))
	testing.expect(t, submit(p, Request{request_id = 4, shard = 1, operation = .Get_Task, workspace = "w", task_id = 7}))
	testing.expect(t, submit(p, Request{request_id = 5, operation = .Remove_Task, workspace = "w", task_id = 7}))
	testing.expect(t, submit(p, Request{request_id = 6, operation = .Get_Task, workspace = "w", task_id = 9}))
	finish_submissions(p)
	join_executor(e)
	for i in 1 ..= 6 {
		job := await_completion(p)
		testing.expect_value(t, job.request.request_id, u64(i))
		switch i {
		case 1:
			testing.expect_value(t, job.result.status, sql.CONSTRAINT)
		case 2:
			testing.expect(t, job.result.status == sql.OK && job.result.found)
			expect_task(t, job.result.task, original)
		case 3:
			testing.expect(t, job.result.status == sql.TOOBIG && !job.result.found && job.result.task.id == 0)
		case 4:
			testing.expect(t, job.result.status != sql.OK && !job.result.found)
		case 5:
			testing.expect_value(t, job.result.status, sql.OK)
		case 6:
			testing.expect(t, job.result.status == sql.OK && job.result.found)
			expect_task(t, job.result.task, exact)
		}
		release_completion(p, job)
	}
}
