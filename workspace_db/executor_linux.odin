package workspace_db

import "../clock"
import pr "../protocol"
import "../spsc"
import sql "../sqlite"
import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "core:thread"
import "core:time"

// Storage transport with explicit shard paths. Domain handlers enforce protocol
// and ACL rules; validate_paths checks assigned databases before startup returns.
Operation :: enum {
	Get_Task,
	Put_Task,
	Remove_Task,
	Create_Task,
	Command,
	Monitor_Maintenance, // Internal writer job; never selected by a wire opcode.
}
Request :: struct {
	request_id:       u64,
	ordering_key:     u64, // Generational connection identity; zero is the internal default stream.
	shard:            int, // Index into the executor's explicit path list.
	operation:        Operation,
	workspace:        string,
	subject:          string, // Authenticated actor for domain mutations.
	chronicle_access: u8, // Immutable verified rights copied by the owning worker.
	scope, task_id:   u64, // Get/Remove; Put uses task.conv_id/task.id.
	task:             pr.Task, // Borrowed only for the duration of submit.
	actor:            string,
	opcode:           pr.Opcode,
	body:             []byte,
	timestamp:        i64,
	monitor_cursor:   u64, // Last globally allocated instance ID scanned in this shard.
	monitor_through:  u64, // Fixed scan boundary, captured with the first page.
	ticket_reads:     []Ticket_Read_Cursor,
	read_generation:  u64,
	dm_target_online: bool, // Worker presence snapshot; SQLite still checks persistent identity.
}
Result :: struct {
	status:          c.int,
	delivery_failed: bool, // Read failure after commit; must resync, never claim rollback.
	create_error:    Create_Task_Error,
	found:           bool,
	task:            pr.Task,
	command:         Command_Output,
}
Completion :: struct {
	admitted_at: i64,
	request:     Request,
	result:      Result,
	charge:      int,
	sequence:    u64,
	lane:        int,
	order:       ^Order_Stream,
	next:        ^Completion, // Owned by exactly one pending list at a time.
}
Order_Stream :: struct {
	submitted, received: u64, // Worker-only.
	outstanding:         int, // Worker-only; includes queued and held results.
	writes_outstanding:  int, // Worker-only; first writes may use the admission headroom.
	charged_bytes:       int, // Worker-only; released with the final result chunk.
	finished:            u64, // Atomic execution frontier.
	references:          int, // Atomic: worker map plus one per owned job.
}

CONNECTION_MAX_REQUESTS :: 4
CONNECTION_MAX_BYTES :: 8 * mem.Megabyte

Admission_Rejection :: enum {
	None,
	Unavailable,
	Connection_Limit,
	Worker_Limit,
}

Wake :: struct {
	fd:      linux.Fd,
	pending: bool,
}
Worker_Lane :: struct {
	requests:    ^spsc.Queue(^Completion),
	completions: ^spsc.Queue(^Completion),
	returns:     ^spsc.Queue(^Completion), // Worker returns a consumed spool chunk.
	streaming:   int, // Executor-only outstanding spools.
	head, tail:  ^Completion, // Executor-only admitted requests awaiting their dependency.
	owner:       ^Worker_Port,
}
Worker_Port :: struct {
	metrics_sequence:                       u64, // Worker-owned ordering across all monitoring connections.
	metrics:                                pr.DatabaseStats,
	lanes:                                  [2]Worker_Lane, // Writer, reader; each queue remains SPSC.
	head, tail:                             ^Completion, // Worker-only completion merge.
	orders:                                 map[u64]^Order_Stream, // Worker-only; removed when final result is released.
	wake:                                   Wake, // Register fd with the worker's event loop; do not close it.
	executor:                               ^Executor,
	closed:                                 bool, // Written by this port's worker, acquired by the executor.
	in_flight, charged_bytes:               int, // Worker-only, including received but held results.
	writer_in_flight, writer_charged_bytes: int, // Same lifetime, writer lane only.
}
Executor :: struct {
	ports:                                       []Worker_Port,
	paths:                                       []cstring,
	wakes:                                       [2]Wake,
	threads:                                     [2]^thread.Thread,
	allocator:                                   mem.Allocator, // Must support concurrent allocation and cross-thread free.
	capacity, byte_budget, max_result_bytes:     int,
	read_reserved_requests, read_reserved_bytes: int,
	create_databases:                            bool,
	validate_paths:                              bool,
	chronicle_maintenance:                       bool,
	command_handler:                             Command_Handler,
	startup:                                     chan.Chan(bool),
}
Executor_Error :: enum {
	None,
	Invalid_Config,
	Allocation,
	Wakeup,
	Thread,
	Storage,
}

// Fully constructs queues before starting the consumer. Each port has exactly
// one submitting/receiving worker. Paths are copied; the caller owns its originals.
// Empty entries are unassigned shards and reject submissions, not SQLite's
// special empty filename (which would create a temporary database).
start_executor :: proc(
	paths: []cstring,
	workers, capacity, byte_budget, max_result_bytes: int,
	allocator: mem.Allocator,
	create_databases := false,
	command_handler: Command_Handler = nil,
	validate_paths := false,
	read_reserved_requests: int = 0,
	read_reserved_bytes: int = 0,
	chronicle_maintenance := false,
) -> (
	e: ^Executor,
	error: Executor_Error,
) {
	if len(paths) == 0 ||
	   workers <= 0 ||
	   capacity <= 0 ||
	   capacity == max(int) ||
	   byte_budget <= size_of(Completion) ||
	   max_result_bytes < size_of(pr.Task) ||
	   max_result_bytes > byte_budget - size_of(Completion) ||
	   read_reserved_requests < 0 ||
	   read_reserved_requests >= capacity ||
	   read_reserved_bytes < 0 ||
	   read_reserved_bytes >= byte_budget {return nil, .Invalid_Config}
	context.allocator = allocator
	allocation_error: mem.Allocator_Error
	e, allocation_error = new(Executor)
	if allocation_error != .None do return nil, .Allocation
	e.allocator = allocator
	for &wake in e.wakes do wake.fd = -1
	success := false
	owned := e
	defer if !success do free_executor(owned)
	e.capacity = capacity
	e.byte_budget = byte_budget
	e.max_result_bytes = max_result_bytes
	e.read_reserved_requests = read_reserved_requests
	e.read_reserved_bytes = read_reserved_bytes
	e.create_databases = create_databases
	e.validate_paths = validate_paths
	e.chronicle_maintenance = chronicle_maintenance
	e.command_handler = command_handler
	e.paths, allocation_error = make([]cstring, len(paths))
	if allocation_error != .None do return nil, .Allocation
	for path, i in paths {
		e.paths[i], allocation_error = strings.clone_to_cstring(string(path))
		if allocation_error != .None do return nil, .Allocation
	}
	e.ports, allocation_error = make([]Worker_Port, workers)
	if allocation_error != .None do return nil, .Allocation
	for &port in e.ports do port.wake.fd = -1
	for &wake in e.wakes {
		fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
		if err != .NONE do return nil, .Wakeup
		wake.fd = fd
	}
	for &port in e.ports {
		port.executor = e
		port.orders, allocation_error = make(map[u64]^Order_Stream, capacity, allocator)
		if allocation_error != .None do return nil, .Allocation
		for &lane in port.lanes {
			lane.owner = &port
			lane.requests, allocation_error = spsc.create(^Completion, capacity, allocator)
			if allocation_error != .None do return nil, .Allocation
			lane.completions, allocation_error = spsc.create(^Completion, capacity, allocator)
			if allocation_error != .None do return nil, .Allocation
			lane.returns, allocation_error = spsc.create(^Completion, capacity, allocator)
			if allocation_error != .None do return nil, .Allocation
		}
		fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
		if err != .NONE do return nil, .Wakeup
		port.wake.fd = fd
	}
	// Creation must finish before the read-only connection can open a shard.
	if validate_paths || create_databases {
		e.startup, allocation_error = chan.create_buffered(chan.Chan(bool), 1, allocator)
		if allocation_error != .None do return nil, .Allocation
	}
	e.threads[0] = thread.create_and_start_with_poly_data(e, writer_run)
	if e.threads[0] == nil do return nil, .Thread
	if e.startup.impl != nil {
		ready, received := chan.recv(e.startup)
		if !received || !ready {
			thread.join(e.threads[0])
			thread.destroy(e.threads[0])
			return nil, .Storage
		}
	}
	e.threads[1] = thread.create_and_start_with_poly_data(e, reader_run)
	if e.threads[1] == nil {
		for &port in e.ports do finish_submissions(&port)
		thread.join(e.threads[0]); thread.destroy(e.threads[0])
		return nil, .Thread
	}
	success = true
	return e, .None
}

// Nonblocking queue admission. Capacity rejection copies nothing. Allocation
// failure cleans up without publication. Success owns a deep copy; the caller
// may immediately reuse its receive buffer and Task descriptors.
submit :: proc(port: ^Worker_Port, request: Request, rejection: ^Admission_Rejection = nil) -> bool {
	local_rejection: Admission_Rejection
	rejection := rejection == nil ? &local_rejection : rejection
	defer {
		#partial switch rejection^ {
		case .Connection_Limit:
			sync.atomic_add(&port.metrics.counters[.Rejected_Connection], 1)
		case .Worker_Limit:
			sync.atomic_add(&port.metrics.counters[.Rejected_Worker], 1)
		case .Unavailable:
			sync.atomic_add(&port.metrics.counters[.Rejected_Unavailable], 1)
		}
	}
	if rejection != nil do rejection^ = .Unavailable
	e := port.executor
	if !chronicle_request_allowed(request) do return false
	if port.closed || request.shard < 0 || request.shard >= len(e.paths) do return false
	if len(string(e.paths[request.shard])) == 0 do return false
	if (request.operation == .Command || request.operation == .Monitor_Maintenance) && (e.command_handler == nil || len(request.body) > pr.MAX_PROTOCOL_PAYLOAD_SIZE) do return false
	if (request.operation == .Put_Task || request.operation == .Create_Task) && len(request.task.attachments) > pr.MAX_ATTACHMENTS_PER_TASK do return false
	order, exists := port.orders[request.ordering_key]
	// Key zero is the internal stream, not a WebSocket connection.
	if request.ordering_key != 0 && exists && order.outstanding >= CONNECTION_MAX_REQUESTS {
		if rejection != nil do rejection^ = .Connection_Limit
		return false
	}
	if rejection != nil do rejection^ = .Worker_Limit
	if port.in_flight == e.capacity do return false
	remaining := e.byte_budget - port.charged_bytes
	lane := read_eligible(request) ? 1 : 0
	if lane == 0 {
		writer_capacity := e.capacity - e.read_reserved_requests
		writer_bytes := e.byte_budget - e.read_reserved_bytes
		if port.writer_in_flight >= writer_capacity do return false
		remaining = min(remaining, writer_bytes - port.writer_charged_bytes)
		// With read isolation enabled, repeated writes cannot take the last
		// half of the writer budget. Those credits admit first writes from
		// other connections; there is no unbounded queue of refused requests.
		if (e.read_reserved_requests > 0 || e.read_reserved_bytes > 0) && request.ordering_key != 0 && exists && order.writes_outstanding > 0 {
			if port.writer_in_flight >= max(1, writer_capacity / 2) {
				if rejection != nil do rejection^ = .Connection_Limit
				return false
			}
			repeat_remaining := max(0, writer_bytes / 2 - port.writer_charged_bytes)
			if repeat_remaining <= remaining {
				remaining = repeat_remaining
				if rejection != nil do rejection^ = .Connection_Limit
			}
		}
	}
	if request.ordering_key != 0 {
		connection_remaining := CONNECTION_MAX_BYTES - (exists ? order.charged_bytes : 0)
		if connection_remaining <= remaining {
			remaining = connection_remaining
			if rejection != nil do rejection^ = .Connection_Limit
		}
	}
	available := remaining
	if !take_credit(&remaining, size_of(Completion) + size_of(Order_Stream)) || !take_credit(&remaining, len(request.workspace)) do return false
	if !take_credit(&remaining, len(request.subject)) do return false
	if !take_credit(&remaining, len(request.actor)) || !take_credit(&remaining, len(request.body)) do return false
	if len(request.ticket_reads) > remaining / size_of(Ticket_Read_Cursor) do return false
	remaining -= len(request.ticket_reads) * size_of(Ticket_Read_Cursor)
	if (request.operation == .Get_Task || request.operation == .Command || request.operation == .Monitor_Maintenance) && !take_credit(&remaining, e.max_result_bytes) do return false
	if request.operation == .Put_Task || request.operation == .Create_Task {
		for bytes in ([7][]byte {
				request.task.title,
				request.task.description,
				request.task.assignee,
				request.task.created_by,
				request.task.external_ref,
				request.task.completed_by,
				request.task.project,
			}) {
			if !take_credit(&remaining, len(bytes)) do return false
		}
		for attachment in request.task.attachments {
			if !take_credit(&remaining, size_of(pr.Attachment)) ||
			   !take_credit(&remaining, len(attachment.file_id)) ||
			   !take_credit(&remaining, len(attachment.filename)) ||
			   !take_credit(&remaining, len(attachment.mime_type)) {return false}
		}
	}
	charge := available - remaining
	if rejection != nil do rejection^ = .Unavailable
	context.allocator = e.allocator
	job, err := new(Completion)
	if err != .None do return false
	published := false
	defer if !published do free_completion(job, e.allocator)
	job.charge = charge
	job.request = request
	job.request.workspace = ""
	job.request.subject = ""
	job.request.task = {}
	job.request.actor = ""
	job.request.body = nil
	job.request.ticket_reads = nil
	job.request.workspace, err = strings.clone(request.workspace)
	if err != .None do return false
	job.request.subject, err = strings.clone(request.subject)
	if err != .None do return false
	job.request.actor, err = strings.clone(request.actor)
	if err != .None do return false
	job.request.body, err = clone_bytes(request.body)
	if err != .None do return false
	job.request.ticket_reads, err = make([]Ticket_Read_Cursor, len(request.ticket_reads))
	if err != .None do return false
	copy(job.request.ticket_reads, request.ticket_reads)
	if request.operation == .Put_Task || request.operation == .Create_Task {
		job.request.task = request.task
		fields := [7]^[]byte {
			&job.request.task.title,
			&job.request.task.description,
			&job.request.task.assignee,
			&job.request.task.created_by,
			&job.request.task.external_ref,
			&job.request.task.completed_by,
			&job.request.task.project,
		}
		sources := [7][]byte {
			request.task.title,
			request.task.description,
			request.task.assignee,
			request.task.created_by,
			request.task.external_ref,
			request.task.completed_by,
			request.task.project,
		}
		// Clear borrowed pointers before any fallible allocation or cleanup.
		for field in fields do field^ = nil
		job.request.task.attachments = nil
		for field, i in fields {
			field^, err = clone_bytes(sources[i])
			if err != .None do return false
		}
		job.request.task.attachments, err = make([]pr.Attachment, len(request.task.attachments))
		if err != .None do return false
		for attachment, i in request.task.attachments {
			owned := &job.request.task.attachments[i]
			owned.size = attachment.size
			owned.uploaded_at = attachment.uploaded_at
			owned.file_id, err = clone_bytes(attachment.file_id)
			if err != .None do return false
			owned.filename, err = clone_bytes(attachment.filename)
			if err != .None do return false
			owned.mime_type, err = clone_bytes(attachment.mime_type)
			if err != .None do return false
		}
	}
	if !exists {
		order, err = new(Order_Stream)
		if err != .None do return false
		order.references = 1
		port.orders[request.ordering_key] = order
	}
	order.outstanding += 1
	order.charged_bytes += job.charge
	order.submitted += 1
	sync.atomic_add(&order.references, 1)
	job.order = order
	job.sequence = order.submitted
	port.in_flight += 1
	port.charged_bytes += job.charge
	job.lane = lane
	if lane == 0 {
		port.writer_in_flight += 1
		port.writer_charged_bytes += job.charge
		order.writes_outstanding += 1
	}
	// Credits include every queued, executing, completed and held job, so a
	// request slot and its eventual completion slot are both guaranteed.
	job.admitted_at = metrics_now()
	sync.atomic_add(&port.metrics.counters[lane == 0 ? .Admitted_Write : .Admitted_Read], 1)
	pushed := spsc.try_push(port.lanes[job.lane].requests, job)
	assert(pushed)
	published = true
	if rejection != nil do rejection^ = .None
	wake_signal(&e.wakes[job.lane])
	return true
}

receive :: proc(port: ^Worker_Port) -> (^Completion, bool) {
	for lane in port.lanes {
		for {
			job, ok := spsc.try_pop(lane.completions); if !ok do break
			append_job(&port.head, &port.tail, job)
		}
	}
	previous: ^Completion
	writer_blocked := false
	for job := port.head; job != nil; job = job.next {
		if job.sequence == job.order.received + 1 && !(job.lane == 0 && writer_blocked) {
			unlink_job(&port.head, &port.tail, previous, job)
			if !job.result.command.more do job.order.received += 1
			return job, true
		}
		if job.lane == 0 do writer_blocked = true
		previous = job
	}
	return nil, false
}

// Worker-only, exactly once after receive, including disconnected recipients.
// Do not retain any pointers into the completion after this call.
release_completion :: proc(port: ^Worker_Port, job: ^Completion) {
	if !job.result.command.more {
		port.in_flight -= 1
		port.charged_bytes -= job.charge
		job.order.outstanding -= 1
		job.order.charged_bytes -= job.charge
		if job.lane == 0 {
			port.writer_in_flight -= 1
			port.writer_charged_bytes -= job.charge
			job.order.writes_outstanding -= 1
		}
		if job.order.outstanding == 0 {
			delete_key(&port.orders, job.request.ordering_key)
			release_order(job.order, port.executor.allocator)
		}
	}
	if job.result.command.spool.open {
		// Reading and final close/unlink eviction stay off the network thread.
		lane := job.lane
		pushed := spsc.try_push(port.lanes[lane].returns, job); assert(pushed)
		wake_signal(&port.executor.wakes[lane])
		return
	}
	free_completion(job, port.executor.allocator)
}

@(private)
release_order :: proc(order: ^Order_Stream, allocator: mem.Allocator) {
	if order != nil && sync.atomic_sub(&order.references, 1) == 1 do free(order, allocator)
}

@(private)
free_completion :: proc(job: ^Completion, allocator: mem.Allocator) {
	context.allocator = allocator
	delete(job.request.workspace, allocator)
	delete(job.request.subject, allocator)
	delete(job.request.actor, allocator)
	delete(job.request.body, allocator)
	delete(job.request.ticket_reads, allocator)
	destroy_task(&job.request.task, allocator)
	destroy_task(&job.result.task, allocator)
	destroy_command_output(&job.result.command)
	release_order(job.order, allocator)
	free(job, allocator)
}

// Call before the worker sleeps, also after a budget-limited partial drain.
// Exchange synchronizes with publication while the previous wake was pending.
rearm_completions :: proc(port: ^Worker_Port) {
	wake_drain(&port.wake)
	_ = sync.atomic_exchange(&port.wake.pending, false)
	writer_blocked := false
	for job := port.head; job != nil; job = job.next {
		if job.sequence == job.order.received + 1 && !(job.lane == 0 && writer_blocked) do wake_signal(&port.wake)
		if job.lane == 0 do writer_blocked = true
	}
	for lane in port.lanes {
		if spsc.can_pop(lane.completions) do wake_signal(&port.wake)
	}
}

// Worker-only, after its final submit. Other ports continue independently.
finish_submissions :: proc(port: ^Worker_Port) {
	sync.atomic_store(&port.closed, true)
	for &wake in port.executor.wakes do wake_signal(&wake)
}

// Coordinator-only after every worker has finished submissions. Streaming
// outputs must continue to be consumed/released before joining the executor.
join_executor :: proc(e: ^Executor) {
	for &port in e.ports do assert(sync.atomic_load(&port.closed))
	for t in e.threads do thread.join(t)
}

// After join AND all workers have released every received completion.
destroy_executor :: proc(e: ^Executor) {
	for &port in e.ports {
		assert(port.in_flight == 0 && port.charged_bytes == 0)
		assert(port.writer_in_flight == 0 && port.writer_charged_bytes == 0)
		assert(len(port.orders) == 0 && port.head == nil)
	}
	for t in e.threads do thread.destroy(t)
	free_executor(e)
}

@(private)
free_executor :: proc(e: ^Executor) {
	if e.startup.impl != nil do chan.destroy(e.startup)
	for &port in e.ports {
		delete(port.orders)
		for lane in port.lanes {
			if lane.requests != nil do spsc.destroy(lane.requests)
			if lane.completions != nil do spsc.destroy(lane.completions)
			if lane.returns != nil do spsc.destroy(lane.returns)
		}
		if port.wake.fd >= 0 do linux.close(port.wake.fd)
	}
	for wake in e.wakes do if wake.fd >= 0 do linux.close(wake.fd)
	for path in e.paths do delete(path, e.allocator)
	delete(e.paths, e.allocator)
	delete(e.ports, e.allocator)
	free(e, e.allocator)
}

@(private)
writer_run :: proc(e: ^Executor) {executor_run(e, 0)}
@(private)
reader_run :: proc(e: ^Executor) {executor_run(e, 1)}

// Advance after commit/rollback, before publishing ownership to the worker.
// The worker merges responses by stream sequence even if another lane wins
// publication. A spool advances only after its final chunk is returned.
@(private)
finish_lane_job :: proc(port: ^Worker_Lane, job: ^Completion, lane: int) {
	sync.atomic_store(&job.order.finished, job.sequence)
	wake_signal(&port.owner.executor.wakes[1 - lane])
}

@(private)
append_job :: proc(head, tail: ^^Completion, job: ^Completion) {
	job.next = nil
	if tail^ == nil {head^ = job} else {tail^.next = job}
	tail^ = job
}

@(private)
unlink_job :: proc(head, tail: ^^Completion, previous, job: ^Completion) {
	if previous == nil {head^ = job.next} else {previous.next = job.next}
	if tail^ == job do tail^ = previous
	job.next = nil
}

// The admission budget bounds this list. Skip only blocked connections, never
// a dependency within one connection. Group-local predecessors are speculative
// until the entire transaction commits or rolls back.
@(private)
ready_job :: proc(job: ^Completion, group: []^Completion = nil) -> bool {
	finished := sync.atomic_load(&job.order.finished)
	for predecessor in group {
		if predecessor.order == job.order do finished = predecessor.sequence
	}
	return job.sequence == finished + 1
}

@(private)
take_lane_job :: proc(port: ^Worker_Lane, group: []^Completion = nil, bytes_left := max(int)) -> ^Completion {
	for {
		job, ok := spsc.try_pop(port.requests); if !ok do break
		append_job(&port.head, &port.tail, job)
	}
	previous: ^Completion
	for job := port.head; job != nil; job = job.next {
		if ready_job(job, group) {
			if len(group) > 0 && (job.request.shard != group[0].request.shard || !group_commit_eligible(job.request) || job.charge > bytes_left) do return nil
			unlink_job(&port.head, &port.tail, previous, job)
			return job
		}
		previous = job
	}
	return nil
}

@(private)
executor_run :: proc(e: ^Executor, lane: int) {
	context.allocator = e.allocator
	if lane == 0 && e.startup.impl != nil {
		valid := true
		for path in e.paths {
			if len(string(path)) == 0 do continue
			store, rc := open(path, e.create_databases)
			if rc != sql.OK {
				if e.validate_paths {valid = false; break}
				// Without validation, report a bad shard on its request as before.
				continue
			}
			if close(&store) != sql.OK {valid = false; break}
		}
		_ = chan.send(e.startup, valid)
		if !valid do return
	}
	stores := make([]Store, len(e.paths))
	defer delete(stores)
	defer for &store in stores {rc := close(&store); assert(rc == sql.OK)}
	cleanup_shard := 0
	next_cleanup := metrics_now() + i64(time.Second)
	for {
		// One shard / bounded batch per second on the existing writer, even
		// under sustained request load or with no connected workers. Failed
		// batches roll back and are retried on the next shard sweep.
		if lane == 0 && e.chronicle_maintenance && metrics_now() >= next_cleanup {
			next_cleanup = metrics_now() + i64(time.Second)
			for _ in 0 ..< len(e.paths) {
				shard := cleanup_shard
				cleanup_shard = (cleanup_shard + 1) % len(e.paths)
				if len(string(e.paths[shard])) == 0 do continue
				store := &stores[shard]
				rc := sql.OK
				if store.db == nil do store^, rc = open(e.paths[shard])
				if rc == sql.OK do rc = cleanup_chronicle(store, time.to_unix_nanoseconds(clock.now()))
				if rc != sql.OK do log.warnf("Chronicle cleanup failed: shard=%d status=%d", shard, rc)
				break
			}
		}
		worked := false
		// One bounded group and at most one returned output chunk per lane/port.
		for &owner in e.ports {
			port := &owner.lanes[lane]
			if job, ok := spsc.try_pop(port.returns); ok {
				worked = true
				if !job.result.command.more {
					finish_lane_job(port, job, lane)
					free_completion(job, e.allocator)
					port.streaming -= 1
				} else {
					job.result.status = read_command_chunk(&job.result.command)
					if job.result.status != sql.OK {
						clear_command_frames(&job.result.command)
						job.result.command.more = false
						job.result.delivery_failed = true
					}
					pushed := spsc.try_push(port.completions, job); assert(pushed)
					wake_signal(&owner.wake)
				}
			}
			// Mutating spools may broadcast to other connections: keep their
			// event order on the writer. Independent reads still run separately.
			if lane == 0 && port.streaming != 0 do continue
			job := take_lane_job(port)
			if job == nil do continue
			worked = true
			store := &stores[job.request.shard]
			if store.db == nil {
				store^, job.result.status = open(e.paths[job.request.shard], read_only = lane == 1)
			}
			if job.result.status == sql.OK {
				store.metrics = &owner.metrics
				job.result.command.spool_directory = os.dir(string(e.paths[job.request.shard]))
				if group_commit_eligible(job.request) {
					execute_group(store, port, job)
					continue
				}
				execute_job(store, job, e.max_result_bytes, e.command_handler)
			}
			metrics_cache(store)
			metrics_complete(&owner, job)
			if job.result.command.spool.open {port.streaming += 1} else {finish_lane_job(port, job, lane)}
			pushed := spsc.try_push(port.completions, job)
			assert(pushed)
			wake_signal(&owner.wake)
		}
		if worked do continue
		wake_drain(&e.wakes[lane])
		_ = sync.atomic_exchange(&e.wakes[lane].pending, false)
		pending, all_closed := false, true
		for &owner in e.ports {
			port := &owner.lanes[lane]
			// Acquire closure BEFORE inspecting the queue: final publication
			// must be visible before deciding shutdown is drained.
			if !sync.atomic_load(&owner.closed) || port.streaming != 0 || port.head != nil do all_closed = false
			if spsc.can_pop(port.returns) do pending = true
			if lane == 0 && port.streaming != 0 do continue
			if spsc.can_pop(port.requests) do pending = true
			for job := port.head; job != nil; job = job.next {
				if ready_job(job) do pending = true
			}
		}
		if pending do continue
		if all_closed do return
		poll_fd := [1]linux.Poll_Fd{{fd = e.wakes[lane].fd, events = {.IN}}}
		_, err := linux.poll(poll_fd[:], lane == 0 && e.chronicle_maintenance ? 1000 : -1)
		assert(err == .NONE || err == .EINTR)
	}
}

@(private)
execute_job :: proc(store: ^Store, job: ^Completion, max_result_bytes: int, handler: Command_Handler, grouped := false, execution_started: i64 = 0) {
	if !chronicle_request_allowed(job.request) {
		job.result.status = sql.CONSTRAINT
		return
	}
	started := execution_started
	if started == 0 {
		metrics_observe(store.metrics, job.lane * 3, job.admitted_at)
		started = metrics_now()
	}
	r := job.request
	rc := grouped ? execute(store, "SAVEPOINT nrc_group_job") : begin(store)
	if rc == sql.OK {
		switch r.operation {
		case .Command, .Monitor_Maintenance:
			job.result.command.limit = max_result_bytes
			rc = handler(store, &job.request, &job.result.command)
			if rc == sql.OK do rc = seal_command_output(&job.result.command)
		case .Create_Task:
			rc, job.result.create_error = create_task(store, r.workspace, &job.request.task, r.subject)
		case .Put_Task:
			rc = put_task(store, r.workspace, &r.task)
		case .Remove_Task:
			rc = remove_task(store, r.workspace, r.scope, r.task_id)
		case .Get_Task:
			job.result.task, job.result.found, rc = get_task(store, r.workspace, r.scope, r.task_id, max_bytes = max_result_bytes)
		}
		metrics_observe(store.metrics, job.lane * 3 + 1, started)
		if rc == sql.OK do rc = grouped ? execute(store, "RELEASE nrc_group_job") : commit(store)
		if rc == sql.OK && !grouped && r.operation == .Create_Task {
			// Move the already charged input into the committed result. No second
			// task copy or fallible result allocation occurs after commit.
			job.result.task = job.request.task
			job.request.task = {}
			job.result.found = true
		}
		if rc != sql.OK && sql.get_autocommit(store.db) == 0 {
			rollback_rc := grouped ? execute(store, "ROLLBACK TO nrc_group_job; RELEASE nrc_group_job") : rollback(store)
			// Never execute the next job inside a failed previous transaction.
			if rollback_rc != sql.OK {close_rc := close(store); assert(close_rc == sql.OK)}
		}
	} else {
		metrics_observe(store.metrics, job.lane * 3 + 1, started)
	}
	// A failed transaction cannot leak even a partially prepared ACK or event.
	if rc != sql.OK do destroy_command_output(&job.result.command)
	job.result.status = rc
}

GROUP_COMMIT_MAX_JOBS :: 32
GROUP_COMMIT_MAX_BYTES :: 100 * mem.Megabyte

// Service rights do not authorize general storage primitives, even if the
// caller stamps C_Chronicle onto a non-command operation.
chronicle_request_allowed :: proc(request: Request) -> bool {
	return request.chronicle_access & pr.CHRONICLE_ACCESS_SERVICE == 0 || (request.operation == .Command && request.opcode == .C_Chronicle)
}

// Explicit whitelist: a new opcode stays on the writer until its handler has
// been audited. Read-only SQLite handles also reject accidental main-DB writes.
@(private)
read_eligible :: proc(request: Request) -> bool {
	if request.operation != .Command do return request.operation == .Get_Task
	#partial switch request.opcode {
	case .C_MonitorDelivery:
		r, err := pr.parseMonitorDeliveryRequest(request.body)
		return err == nil && (r.action == 0 || r.action == 6 || r.action == 7)
	case .C_MonitorHistory:
		r, err := pr.parseMonitorHistoryRequest(request.body)
		// Initial polls can capture disabled-monitor pause evidence; ACKs delete it.
		// Only immutable continuation pages are unconditionally read-only.
		return err == nil && !r.acknowledge && r.cursor != 0
	case .C_GetTasks,
	     .C_GetTasksByIDs,
	     .C_GetAsset,
	     .C_GetMonitorState,
	     .C_QueryMonitorStatus,
	     .C_ListOpenIncidents,
	     .C_GetAssetsByIDs,
	     .C_ListTasksPaged,
	     .C_QueryTasks,
	     .C_ListTaskDependents,
	     .C_ListAssets,
	     .C_ListAssetsPaged,
	     .C_ListAssetsPagedByProject,
	     .C_ListAssetsPagedByTag,
	     .C_ListEdges,
	     .C_ListAllEdges,
	     .C_ListAllEdgesPaged,
	     .C_ListEdgesPaged,
	     .C_ListHistory,
	     .C_ListTaskSlices,
	     .C_GetWorkspaceOverview,
	     .C_ListTaskProjects,
	     .C_ListTaskAssignees,
	     .C_ListSliceOwners,
	     .C_ListTicketAssignees,
	     .C_ListCalendarPeople,
	     .C_ListNoteProjects,
	     .C_ListNoteTags,
	     .C_QueryTickets,
	     .C_QueryCalendar,
	     .C_SearchCustomers,
	     .C_GraphQuery,
	     .C_GraphShortestPath,
	     .C_GraphRank,
	     .C_GraphDegree,
	     .C_GraphCommonNeighbors:
		return true
	}
	return false
}

@(private)
group_commit_eligible :: proc(request: Request) -> bool {
	if read_eligible(request) do return false
	if request.operation != .Command do return request.operation != .Get_Task
	#partial switch request.opcode {
	case .C_CreateTask,
	     .C_UpdateTask,
	     .C_DeleteTask,
	     .C_MoveTask,
	     .C_ApplyTransaction,
	     .C_ApplyMonitorRun,
	     .C_ControlMonitorInstance,
	     .C_ActOnIncident,
	     .C_MonitorDelivery,
	     .C_CreateAsset,
	     .C_UpdateAsset,
	     .C_DeleteAsset,
	     .C_CreateEdge,
	     .C_DeleteEdge,
	     .C_StartDM,
	     .C_LeaveDM:
		return true
	}
	return false
}

// A shard belongs to one worker port. Keep admitted jobs charged until the
// worker releases their durable results; grouping introduces no extra queue.
@(private)
execute_group :: proc(store: ^Store, port: ^Worker_Lane, first: ^Completion) {
	e := port.owner.executor
	if port.head == nil && !spsc.can_pop(port.requests) && !sync.atomic_load(&port.owner.closed) do time.sleep(time.Millisecond)
	jobs: [GROUP_COMMIT_MAX_JOBS]^Completion
	count, bytes := 0, 0
	job := first
	// The outer BEGIN belongs to the first job's execution, including BUSY.
	metrics_observe(store.metrics, 0, first.admitted_at)
	started := metrics_now()
	rc := begin(store)
	if rc != sql.OK do metrics_observe(store.metrics, 1, started)
	for {
		jobs[count] = job; count += 1; bytes += job.charge
		if rc != sql.OK do break
		job.result.command.spool_directory = os.dir(string(e.paths[job.request.shard]))
		execute_job(store, job, e.max_result_bytes, e.command_handler, grouped = true, execution_started = count == 1 ? started : 0)
		if store.db == nil ||
		   sql.get_autocommit(store.db) != 0 ||
		   (job.result.status != sql.OK && job.result.status != sql.CONSTRAINT && job.result.status != sql.TOOBIG) {
			rc = job.result.status == sql.OK ? sql.ERROR : job.result.status
			break
		}
		// Only the last result may stream: subsequent work cannot overtake it.
		if job.result.command.spool.open || count == len(jobs) || bytes >= GROUP_COMMIT_MAX_BYTES do break
		next := take_lane_job(port, jobs[:count], GROUP_COMMIT_MAX_BYTES - bytes)
		if next == nil do break
		job = next
	}
	sync.atomic_add(&port.owner.metrics.counters[.Group_Transactions], 1)
	sync.atomic_add(&port.owner.metrics.counters[.Group_Jobs], u64(count))
	if rc == sql.OK do rc = commit(store)
	if rc != sql.OK && store.db != nil && sql.get_autocommit(store.db) == 0 {
		if rollback(store) != sql.OK {close_rc := close(store); assert(close_rc == sql.OK)}
	}
	metrics_cache(store)
	for completed in jobs[:count] {
		if rc != sql.OK {
			destroy_command_output(&completed.result.command)
			completed.result.status = rc
		} else if completed.result.status == sql.OK && completed.request.operation == .Create_Task {
			completed.result.task = completed.request.task
			completed.request.task = {}
			completed.result.found = true
		}
		metrics_complete(port.owner, completed)
		if completed.result.command.spool.open {port.streaming += 1} else {finish_lane_job(port, completed, 0)}
		pushed := spsc.try_push(port.completions, completed); assert(pushed)
	}
	wake_signal(&port.owner.wake)
}

@(private)
take_credit :: proc(remaining: ^int, bytes: int) -> bool {
	if bytes > remaining^ do return false
	remaining^ -= bytes
	return true
}

@(private)
clone_bytes :: proc(bytes: []byte) -> (result: []byte, error: mem.Allocator_Error) {
	result, error = make([]byte, len(bytes))
	if error != .None do return
	copy(result, bytes)
	return
}

@(private)
wake_signal :: proc(wake: ^Wake) {
	if sync.atomic_exchange(&wake.pending, true) do return
	value := u64(1)
	for {
		_, err := linux.write(wake.fd, ([^]byte)(&value)[:size_of(value)])
		if err == .EINTR do continue
		assert(err == .NONE || err == .EAGAIN)
		return
	}
}

@(private)
wake_drain :: proc(wake: ^Wake) {
	value: u64
	for {
		_, err := linux.read(wake.fd, ([^]byte)(&value)[:size_of(value)])
		if err == .EINTR do continue
		assert(err == .NONE || err == .EAGAIN)
		return
	}
}
