package main

import "core:log"
import "core:os"
import "core:testing"

import "btree"
import hgl "hegel"
import "persistence"
import pr "protocol"
import ws "websocket"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: os.remove
	_ :: hgl.run
}

@(test)
test_alloc_task_deep_copies_attachment_strings :: proc(t: ^testing.T) {
	// Create source buffers that we'll modify after allocation
	// to verify the task has independent copies
	file_id_buf := [?]byte{'f', 'i', 'l', 'e', '1', '2', '3'}
	filename_buf := [?]byte{'t', 'e', 's', 't', '.', 'p', 'n', 'g'}
	mime_type_buf := [?]byte{'i', 'm', 'a', 'g', 'e', '/', 'p', 'n', 'g'}

	attachments := []pr.Attachment{{file_id = file_id_buf[:], filename = filename_buf[:], size = 1024, mime_type = mime_type_buf[:], uploaded_at = 1234567890}}

	title := transmute([]byte)string("Test Task")
	description := transmute([]byte)string("Description")

	task := alloc_task(title, description, nil, nil, nil, nil, nil, attachments)
	defer free_task(task)

	testing.expect(t, task != nil, "alloc_task should succeed")
	testing.expect_value(t, len(task.attachments), 1)

	// Verify attachment data was copied correctly
	testing.expect(t, string(task.attachments[0].file_id) == "file123", "file_id mismatch")
	testing.expect(t, string(task.attachments[0].filename) == "test.png", "filename mismatch")
	testing.expect(t, string(task.attachments[0].mime_type) == "image/png", "mime_type mismatch")
	testing.expect_value(t, task.attachments[0].size, 1024)
	testing.expect_value(t, task.attachments[0].uploaded_at, 1234567890)

	// Verify attachment strings point to different memory than source (deep copy)
	testing.expect(t, raw_data(task.attachments[0].file_id) != raw_data(file_id_buf[:]), "file_id should be deep copied, not pointing to source")
	testing.expect(t, raw_data(task.attachments[0].filename) != raw_data(filename_buf[:]), "filename should be deep copied, not pointing to source")
	testing.expect(t, raw_data(task.attachments[0].mime_type) != raw_data(mime_type_buf[:]), "mime_type should be deep copied, not pointing to source")

	// Modify source buffers to verify task data is independent
	file_id_buf[0] = 'X'
	filename_buf[0] = 'X'
	mime_type_buf[0] = 'X'

	// Task data should be unchanged
	testing.expect(t, string(task.attachments[0].file_id) == "file123", "file_id should be independent of source")
	testing.expect(t, string(task.attachments[0].filename) == "test.png", "filename should be independent of source")
	testing.expect(t, string(task.attachments[0].mime_type) == "image/png", "mime_type should be independent of source")
}

@(test)
test_alloc_task_multiple_attachments :: proc(t: ^testing.T) {
	attachments := []pr.Attachment {
		{
			file_id = transmute([]byte)string("id1"),
			filename = transmute([]byte)string("file1.txt"),
			size = 100,
			mime_type = transmute([]byte)string("text/plain"),
			uploaded_at = 1000,
		},
		{
			file_id = transmute([]byte)string("id2"),
			filename = transmute([]byte)string("file2.jpg"),
			size = 2000,
			mime_type = transmute([]byte)string("image/jpeg"),
			uploaded_at = 2000,
		},
		{
			file_id = transmute([]byte)string("id3"),
			filename = transmute([]byte)string("file3.pdf"),
			size = 30000,
			mime_type = transmute([]byte)string("application/pdf"),
			uploaded_at = 3000,
		},
	}

	task := alloc_task(transmute([]byte)string("Multi-attachment task"), transmute([]byte)string("Has 3 attachments"), nil, nil, nil, nil, nil, attachments)
	defer free_task(task)

	testing.expect(t, task != nil, "alloc_task should succeed")
	testing.expect_value(t, len(task.attachments), 3)

	// Verify each attachment
	testing.expect(t, string(task.attachments[0].file_id) == "id1", "attachment 0 file_id")
	testing.expect(t, string(task.attachments[0].filename) == "file1.txt", "attachment 0 filename")
	testing.expect_value(t, task.attachments[0].size, 100)

	testing.expect(t, string(task.attachments[1].file_id) == "id2", "attachment 1 file_id")
	testing.expect(t, string(task.attachments[1].filename) == "file2.jpg", "attachment 1 filename")
	testing.expect_value(t, task.attachments[1].size, 2000)

	testing.expect(t, string(task.attachments[2].file_id) == "id3", "attachment 2 file_id")
	testing.expect(t, string(task.attachments[2].filename) == "file3.pdf", "attachment 2 filename")
	testing.expect_value(t, task.attachments[2].size, 30000)
}

@(test)
test_alloc_task_no_attachments :: proc(t: ^testing.T) {
	task := alloc_task(
		transmute([]byte)string("Task without attachments"),
		transmute([]byte)string("No files"),
		transmute([]byte)string("assignee"),
		transmute([]byte)string("creator"),
		transmute([]byte)string("EXT-123"),
		nil,
		nil,
		nil,
	)
	defer free_task(task)

	testing.expect(t, task != nil, "alloc_task should succeed")
	testing.expect_value(t, len(task.attachments), 0)
	testing.expect(t, string(task.title) == "Task without attachments", "title mismatch")
	testing.expect(t, string(task.description) == "No files", "description mismatch")
	testing.expect(t, string(task.assignee) == "assignee", "assignee mismatch")
	testing.expect(t, string(task.created_by) == "creator", "created_by mismatch")
	testing.expect(t, string(task.external_ref) == "EXT-123", "external_ref mismatch")
}

@(test)
test_alloc_task_copies_project :: proc(t: ^testing.T) {
	project_buf := [?]byte{'n', 'r', 'c'}
	task := alloc_task(transmute([]byte)string("Task"), nil, nil, nil, nil, nil, project_buf[:], nil)
	defer free_task(task)

	testing.expect(t, task != nil, "alloc_task should succeed")
	testing.expect(t, string(task.project) == "nrc", "project mismatch")
	testing.expect(t, raw_data(task.project) != raw_data(project_buf[:]), "project should be deep copied")

	project_buf[0] = 'X'
	testing.expect(t, string(task.project) == "nrc", "project should be independent of source")
}

@(test)
test_alloc_task_empty_attachment_strings :: proc(t: ^testing.T) {
	// Test attachment with some empty string fields
	attachments := []pr.Attachment {
		{
			file_id     = transmute([]byte)string("someid"),
			filename    = nil, // empty filename
			size        = 500,
			mime_type   = nil, // empty mime_type
			uploaded_at = 9999,
		},
	}

	task := alloc_task(transmute([]byte)string("Task"), nil, nil, nil, nil, nil, nil, attachments)
	defer free_task(task)

	testing.expect(t, task != nil, "alloc_task should succeed")
	testing.expect_value(t, len(task.attachments), 1)
	testing.expect(t, string(task.attachments[0].file_id) == "someid", "file_id mismatch")
	testing.expect_value(t, len(task.attachments[0].filename), 0)
	testing.expect_value(t, len(task.attachments[0].mime_type), 0)
	testing.expect_value(t, task.attachments[0].size, 500)
}

@(test)
test_alloc_task_attachment_alignment :: proc(t: ^testing.T) {
	// Use odd-length strings to create misaligned offset before attachments
	// This ensures the alignment fix is working correctly
	odd_title := transmute([]byte)string("ABC") // 3 bytes
	odd_description := transmute([]byte)string("DEFGH") // 5 bytes
	odd_assignee := transmute([]byte)string("I") // 1 byte
	// Total string bytes: 9, which is not aligned to 8

	attachments := []pr.Attachment {
		{
			file_id     = transmute([]byte)string("file_id_1"),
			filename    = transmute([]byte)string("test.png"),
			size        = 0x123456789ABCDEF0, // Use a distinctive value to detect corruption
			mime_type   = transmute([]byte)string("image/png"),
			uploaded_at = 0x0FEDCBA987654321,
		},
	}

	task := alloc_task(odd_title, odd_description, odd_assignee, nil, nil, nil, nil, attachments)
	defer free_task(task)

	testing.expect(t, task != nil, "alloc_task should succeed")

	// Verify the attachments slice is properly aligned
	attachments_ptr := uintptr(raw_data(task.attachments))
	required_alignment := uintptr(align_of(pr.Attachment))
	testing.expect(t, attachments_ptr % required_alignment == 0, "attachments array must be properly aligned")

	// Verify u64/i64 fields are accessible without issues (would crash or corrupt on strict alignment archs)
	testing.expect_value(t, task.attachments[0].size, 0x123456789ABCDEF0)
	testing.expect_value(t, task.attachments[0].uploaded_at, 0x0FEDCBA987654321)

	// Verify strings still work correctly
	testing.expect(t, string(task.title) == "ABC", "title mismatch")
	testing.expect(t, string(task.description) == "DEFGH", "description mismatch")
	testing.expect(t, string(task.attachments[0].file_id) == "file_id_1", "file_id mismatch")
}

@(test)
test_task_handlers_lifecycle_updates_state_after_persistence :: proc(t: ^testing.T) {
	workspace_id := "task-handler-lifecycle"
	if !init_room_mapping_test_state("task_handler_lifecycle.log", workspace_id) {
		testing.expect(t, false, "task handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	conv_id := pr.ConversationID(77)
	process_create_task(&c, pr.CreateTaskRequest{conv_id = conv_id, correlation_id = 9})
	testing.expect(t, get_workspace(workspace_id) == nil, "empty task title should be rejected before workspace mutation")

	attachments := []pr.Attachment {
		{
			file_id = transmute([]byte)string("file-1"),
			filename = transmute([]byte)string("spec.txt"),
			size = 42,
			mime_type = transmute([]byte)string("text/plain"),
			uploaded_at = 123,
		},
	}

	process_create_task(
		&c,
		pr.CreateTaskRequest {
			conv_id = conv_id,
			title = transmute([]byte)string("Persistent task"),
			description = transmute([]byte)string("initial description"),
			priority = 2,
			color = .Gold,
			external_ref = transmute([]byte)string("EXT-1"),
			due_at = 456,
			attachments = attachments,
			status = .Backlog,
			project = transmute([]byte)string("NRC"),
			correlation_id = 10,
		},
	)

	ws := get_workspace(workspace_id)
	conv := get_conversation(ws, conv_id)
	testing.expect(t, conv != nil, "create should make the target conversation visible after persistence")
	if conv == nil do return
	task := conv.tasks[1]
	testing.expect(t, task != nil, "create should store the persisted task")
	if task == nil do return
	testing.expect(t, string(task.title) == "Persistent task", "create should preserve title")
	testing.expect(t, string(task.project) == "NRC", "create should preserve project")
	testing.expect_value(t, len(task.attachments), 1)
	testing.expect_value(t, td.shard_writers.writers[0].floors.task, u64(1))

	replacement_attachments := []pr.Attachment {
		{
			file_id = transmute([]byte)string("file-2"),
			filename = transmute([]byte)string("result.txt"),
			size = 84,
			mime_type = transmute([]byte)string("text/plain"),
			uploaded_at = 789,
		},
	}
	process_update_task(
		&c,
		pr.UpdateTaskRequest {
			conv_id = conv_id,
			task_id = 1,
			status = pr.TaskStatus(255),
			priority = 255,
			color = pr.TaskColor(255),
			attachments = replacement_attachments,
			correlation_id = 10,
		},
	)
	task = conv.tasks[1]
	testing.expect(t, task != nil, "attachment update should retain the task")
	if task == nil do return
	testing.expect_value(t, len(task.attachments), 1)
	testing.expect(t, string(task.attachments[0].file_id) == "file-2", "explicit attachment list should replace old attachments")
	testing.expect_value(t, task.status, pr.TaskStatus.Backlog)
	testing.expect_value(t, task.priority, u8(2))
	testing.expect_value(t, task.color, pr.TaskColor.Gold)

	clear_description := [1]byte{0}
	process_update_task(
		&c,
		pr.UpdateTaskRequest {
			conv_id = conv_id,
			task_id = 1,
			description = clear_description[:],
			status = .Done,
			assignee = transmute([]byte)string("alice"),
			priority = 255,
			color = pr.TaskColor(255),
			preserve_attachments = true,
			correlation_id = 11,
		},
	)

	task = conv.tasks[1]
	testing.expect(t, task != nil, "update should retain the task")
	if task == nil do return
	testing.expect(t, string(task.title) == "Persistent task", "empty update title should preserve the old title")
	testing.expect_value(t, len(task.description), 0)
	testing.expect(t, string(task.assignee) == "alice", "update should replace assignee")
	testing.expect_value(t, task.status, pr.TaskStatus.Done)
	testing.expect(t, task.completed_at > 0, "entering Done should set completed_at")
	testing.expect(t, string(task.completed_by) == "tester", "entering Done should record the actor")
	testing.expect_value(t, len(task.attachments), 1)
	testing.expect(t, string(task.attachments[0].file_id) == "file-2", "preserve sentinel should retain replacement attachments")

	process_move_task(&c, pr.MoveTaskRequest{conv_id = conv_id, task_id = 1, status = .Todo, order_index = 7, correlation_id = 12})

	task = conv.tasks[1]
	testing.expect(t, task != nil, "move should retain the task")
	if task == nil do return
	testing.expect_value(t, task.status, pr.TaskStatus.Todo)
	testing.expect_value(t, task.order_index, u16(7))
	testing.expect_value(t, task.completed_at, i64(0))
	testing.expect_value(t, len(task.completed_by), 0)

	process_get_tasks(&c, pr.GetTasksRequest{conv_id = conv_id, correlation_id = 13})
	process_delete_task(&c, pr.DeleteTaskRequest{conv_id = conv_id, task_id = 1, correlation_id = 14})
	testing.expect_value(t, len(conv.tasks), 0)
	testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, u64(5))
}

// A move may ask for the end of the target column instead of naming a position:
// a client that draws one page of a register does not hold the column, so the
// server folds it. The acknowledgement carries the folded index, never the
// sentinel, because the client stores what it is told.
@(test)
test_task_move_append_lands_at_the_end_of_the_target_column :: proc(t: ^testing.T) {
	workspace_id := "task-handler-move-append"
	if !init_room_mapping_test_state("task_handler_move_append.log", workspace_id) {
		testing.expect(t, false, "task handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	// The connection has a transport send in flight, so each response waits in the
	// queue this test reads instead of being submitted to a socket.
	c.state = .Idle
	c.is_sending = true
	conv_id := pr.ConversationID(93)

	// Two tasks in Todo (orders 0 and 1) and one in Done (order 0).
	process_create_task(&c, pr.CreateTaskRequest{conv_id = conv_id, title = transmute([]byte)string("todo first"), status = .Todo})
	process_create_task(&c, pr.CreateTaskRequest{conv_id = conv_id, title = transmute([]byte)string("todo second"), status = .Todo})
	process_create_task(&c, pr.CreateTaskRequest{conv_id = conv_id, title = transmute([]byte)string("done only"), status = .Done})

	conv := get_conversation(get_workspace(workspace_id), conv_id)
	testing.expect(t, conv != nil, "the append fixture should create its conversation")
	if conv == nil do return
	testing.expect_value(t, conv.tasks[1].order_index, u16(0))
	testing.expect_value(t, conv.tasks[2].order_index, u16(1))
	testing.expect_value(t, conv.tasks[3].order_index, u16(0))
	// Drain the creation acknowledgements, so each move's own frame is the one read.
	for send_queue_len(&c) > 0 {
		item := send_queue_pop(&c)
		frame_lease_dispose(&item.lease)
	}

	// Appending to a column that carries two tasks lands after both.
	process_move_task(&c, pr.MoveTaskRequest{conv_id = conv_id, task_id = 1, status = .Todo, flags = pr.MoveTaskFlag_APPEND, correlation_id = 21})
	moved := conv.tasks[1]
	testing.expect(t, moved != nil, "the append move should retain the task")
	if moved == nil do return
	testing.expect_value(t, moved.status, pr.TaskStatus.Todo)
	testing.expect_value(t, moved.order_index, u16(2))
	testing.expect_value(t, send_queue_len(&c), 1)
	item := send_queue_pop(&c)
	defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease)
	header, header_len, header_err := ws.readFrameHeader(frame)
	testing.expect(t, header_err == nil && header.opcode == .opBinary, "the append move should answer with one binary frame")
	if header_err != nil do return
	acknowledged, ack_err := pr.parseTaskMoved(frame[header_len:])
	testing.expect(t, ack_err == nil, "the append acknowledgement should parse")
	if ack_err != nil do return
	testing.expect_value(t, acknowledged.task_id, pr.TaskID(1))
	testing.expect_value(t, acknowledged.order_index, u16(2))

	// Appending to a column that carries one other task lands after it.
	process_move_task(&c, pr.MoveTaskRequest{conv_id = conv_id, task_id = 2, status = .Done, flags = pr.MoveTaskFlag_APPEND, correlation_id = 22})
	testing.expect_value(t, conv.tasks[2].order_index, u16(1))

	// Appending to a column that carries nothing lands at zero.
	process_move_task(&c, pr.MoveTaskRequest{conv_id = conv_id, task_id = 3, status = .Backlog, flags = pr.MoveTaskFlag_APPEND, correlation_id = 23})
	testing.expect_value(t, conv.tasks[3].status, pr.TaskStatus.Backlog)
	testing.expect_value(t, conv.tasks[3].order_index, u16(0))

	// An explicit position still names one, which is what a drag sends.
	process_move_task(&c, pr.MoveTaskRequest{conv_id = conv_id, task_id = 1, status = .Todo, order_index = 4, correlation_id = 24})
	testing.expect_value(t, conv.tasks[1].order_index, u16(4))

	// A column whose positions are exhausted cannot name another one: the append is
	// refused instead of folding an index that would wrap past the u16 space.
	process_move_task(&c, pr.MoveTaskRequest{conv_id = conv_id, task_id = 1, status = .Todo, order_index = max(u16), correlation_id = 25})
	testing.expect_value(t, conv.tasks[1].order_index, max(u16))
	for send_queue_len(&c) > 0 {
		drained := send_queue_pop(&c)
		frame_lease_dispose(&drained.lease)
	}
	process_move_task(&c, pr.MoveTaskRequest{conv_id = conv_id, task_id = 2, status = .Todo, flags = pr.MoveTaskFlag_APPEND, correlation_id = 26})
	testing.expect_value(t, conv.tasks[2].status, pr.TaskStatus.Done)
	testing.expect_value(t, send_queue_len(&c), 1)
	refusal_item := send_queue_pop(&c)
	defer frame_lease_dispose(&refusal_item.lease)
	refusal_frame := frame_lease_data(refusal_item.lease)
	refusal_header, refusal_header_len, refusal_header_err := ws.readFrameHeader(refusal_frame)
	testing.expect(t, refusal_header_err == nil && refusal_header.opcode == .opBinary, "an exhausted column should answer with one frame")
	if refusal_header_err != nil do return
	refusal_tasks: [1]pr.Task
	refusal_attachments: [1]pr.Attachment
	refusal, refusal_err := pr.parseTaskListResponse(refusal_frame[refusal_header_len:], refusal_tasks[:0], refusal_attachments[:0])
	testing.expect(t, refusal_err == nil, "the refusal should parse as a task list response")
	if refusal_err != nil do return
	testing.expect(t, !refusal.success, "the refusal should not claim success")
	testing.expect(t, string(refusal.error) == "Status column is full", "the refusal should name the exhausted column")
	testing.expect_value(t, refusal.correlation_id, u32(26))

	// Creating into the same column is refused for the same reason.
	process_create_task(&c, pr.CreateTaskRequest{conv_id = conv_id, title = transmute([]byte)string("no room"), status = .Todo, correlation_id = 27})
	testing.expect_value(t, len(conv.tasks), 3)
}

@(test)
test_task_create_persistence_failure_is_not_visible_or_acknowledged :: proc(t: ^testing.T) {
	workspace_id := "task-handler-create-failure"
	if !init_room_mapping_test_state("task_handler_create_failure.log", workspace_id) {
		testing.expect(t, false, "task handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0
	persistent_mutation_failure_seen = false
	defer {persistent_mutation_failure_seen = false}

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	c.state = .Idle
	c.is_sending = true
	previous_logger := context.logger
	context.logger = log.nil_logger()
	persistence.clear_wal_write_fault_for_test()
	defer persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)

	process_create_task(&c, pr.CreateTaskRequest{conv_id = 88, title = transmute([]byte)string("must not appear"), status = .Backlog, correlation_id = 99})
	context.logger = previous_logger

	ws := get_workspace(workspace_id)
	conv := get_conversation(ws, 88)
	testing.expect(t, conv != nil, "handler may create the conversation shell before persistence")
	if conv != nil {
		testing.expect_value(t, len(conv.tasks), 0)
	}
	testing.expect(t, persistent_mutation_failure_seen, "persistence rejection should trigger fail-closed handling")
	testing.expect(t, persistence.wal_write_fault_triggered_for_test(), "test write fault should reach the WAL")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "ambiguous write should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_task_mutations_exceed_former_workspace_limits :: proc(t: ^testing.T) {
	workspace_id := "task-handler-limits"
	if !init_room_mapping_test_state("task_handler_limits.log", workspace_id) {
		testing.expect(t, false, "task fixture should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	conv := get_or_create_conversation(get_or_create_workspace(workspace_id), pr.WORKSPACE_DATA_ID)
	// Populate real indexed records at both former boundaries, without timing
	// thousands of WAL writes. Expectations deliberately use the old numbers.
	for i in 0 ..< 10_000 {
		task := alloc_task(transmute([]byte)string("existing"), nil, nil, nil, nil, nil, nil, nil)
		task.id = pr.TaskID(i + 1)
		task.conv_id = pr.WORKSPACE_DATA_ID
		task.status = i < 1_000 ? .Backlog : .Done
		task.order_index = u16(i)
		task_store_put(conv, task)
	}
	td.task_seq = 10_000
	process_create_task(&c, pr.CreateTaskRequest{conv_id = pr.WORKSPACE_DATA_ID, title = transmute([]byte)string("new active"), status = .Backlog})
	testing.expect_value(t, len(conv.tasks), 10_001)
	testing.expect(t, conv.tasks[10_001] != nil, "active task creation exceeds both former quotas")
	process_move_task(&c, pr.MoveTaskRequest{conv_id = pr.WORKSPACE_DATA_ID, task_id = 1_001, status = .Todo, order_index = 0})
	testing.expect_value(t, conv.tasks[1_001].status, pr.TaskStatus.Todo)
	process_update_task(&c, pr.UpdateTaskRequest{conv_id = pr.WORKSPACE_DATA_ID, task_id = 1_002, status = .InProgress})
	testing.expect_value(t, conv.tasks[1_002].status, pr.TaskStatus.InProgress)
	body := transaction_test_task_create_body(pr.WORKSPACE_DATA_ID, .Existing, 0, 't')
	ops := [1]pr.TransactionOperation{{op_type = .TaskCreate, body = body[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{operations = ops[:]})
	testing.expect_value(t, len(conv.tasks), 10_002)
	testing.expect(t, conv.tasks[10_002] != nil, "transaction creation also exceeds former quotas")
	testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, u64(4))
}

@(test)
test_task_update_persistence_failure_preserves_owned_task :: proc(t: ^testing.T) {
	workspace_id := "task-handler-update-failure"
	if !init_room_mapping_test_state("task_handler_update_failure.log", workspace_id) {
		testing.expect(t, false, "task handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0
	persistent_mutation_failure_seen = false
	defer {persistent_mutation_failure_seen = false}

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	process_create_task(&c, pr.CreateTaskRequest{conv_id = 89, title = transmute([]byte)string("original"), priority = 2, color = .Gold, status = .Backlog})
	original := get_task(workspace_id, 89, 1)
	testing.expect(t, original != nil, "fixture task should be created")
	if original == nil do return

	c.state = .Idle
	c.is_sending = true
	previous_logger := context.logger
	context.logger = log.nil_logger()
	persistence.clear_wal_write_fault_for_test()
	defer persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)
	process_update_task(
		&c,
		pr.UpdateTaskRequest {
			conv_id = 89,
			task_id = 1,
			title = transmute([]byte)string("replacement"),
			status = .Done,
			priority = 5,
			color = .Red,
			preserve_attachments = true,
			correlation_id = 100,
		},
	)
	context.logger = previous_logger

	retained := get_task(workspace_id, 89, 1)
	testing.expect(t, retained == original, "failed update must not replace or free the owned task")
	if retained == nil do return
	testing.expect(t, string(retained.title) == "original", "failed update must preserve title")
	testing.expect_value(t, retained.status, pr.TaskStatus.Backlog)
	testing.expect_value(t, retained.priority, u8(2))
	testing.expect_value(t, retained.color, pr.TaskColor.Gold)
	testing.expect_value(t, retained.completed_at, i64(0))
	testing.expect(t, persistent_mutation_failure_seen, "failed update should trigger fail-closed handling")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed update should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_task_move_persistence_failure_preserves_owned_task :: proc(t: ^testing.T) {
	workspace_id := "task-handler-move-failure"
	if !init_room_mapping_test_state("task_handler_move_failure.log", workspace_id) {
		testing.expect(t, false, "task handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0
	persistent_mutation_failure_seen = false
	defer {persistent_mutation_failure_seen = false}

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	process_create_task(&c, pr.CreateTaskRequest{conv_id = 90, title = transmute([]byte)string("move original"), status = .Backlog})
	original := get_task(workspace_id, 90, 1)
	testing.expect(t, original != nil, "fixture task should be created")
	if original == nil do return

	c.state = .Idle
	c.is_sending = true
	previous_logger := context.logger
	context.logger = log.nil_logger()
	persistence.clear_wal_write_fault_for_test()
	defer persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)
	process_move_task(&c, pr.MoveTaskRequest{conv_id = 90, task_id = 1, status = .Done, order_index = 9, correlation_id = 101})
	context.logger = previous_logger

	retained := get_task(workspace_id, 90, 1)
	testing.expect(t, retained == original, "failed Done transition must not replace or free the owned task")
	if retained == nil do return
	testing.expect_value(t, retained.status, pr.TaskStatus.Backlog)
	testing.expect_value(t, retained.order_index, u16(0))
	testing.expect_value(t, retained.completed_at, i64(0))
	testing.expect_value(t, len(retained.completed_by), 0)
	testing.expect(t, persistent_mutation_failure_seen, "failed move should trigger fail-closed handling")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed move should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_task_delete_persistence_failure_preserves_owned_task :: proc(t: ^testing.T) {
	workspace_id := "task-handler-delete-failure"
	if !init_room_mapping_test_state("task_handler_delete_failure.log", workspace_id) {
		testing.expect(t, false, "task handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0
	persistent_mutation_failure_seen = false
	defer {persistent_mutation_failure_seen = false}

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	process_create_task(&c, pr.CreateTaskRequest{conv_id = 91, title = transmute([]byte)string("delete original"), status = .Backlog})
	original := get_task(workspace_id, 91, 1)
	testing.expect(t, original != nil, "fixture task should be created")
	if original == nil do return

	c.state = .Idle
	c.is_sending = true
	previous_logger := context.logger
	context.logger = log.nil_logger()
	persistence.clear_wal_write_fault_for_test()
	defer persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)
	process_delete_task(&c, pr.DeleteTaskRequest{conv_id = 91, task_id = 1, correlation_id = 102})
	context.logger = previous_logger

	retained := get_task(workspace_id, 91, 1)
	testing.expect(t, retained == original, "failed delete must retain the owned task")
	if retained == nil do return
	testing.expect(t, string(retained.title) == "delete original", "failed delete must retain task contents")
	testing.expect(t, persistent_mutation_failure_seen, "failed delete should trigger fail-closed handling")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed delete should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

when NRC_SIMULATION {
	task_handler_test_init_sim_writer :: proc(workspace_id: string, path_label: string = "task_handler_simulation.log") -> (path: string, ok: bool) {
		path = test_wal_path(path_label)
		_ = os.remove(path)
		if os.write_entire_file(path, nil) != nil do return path, false
		workspace := transmute([]byte)workspace_id
		shard := int(shard_for_workspace(workspace))
		td.shard_writers.worker = 0
		td.shard_writers.worker_count = 1
		for &index in td.shard_writers.writer_index do index = -1
		_, append_err := append(&td.shard_writers.writers, Shard_Transaction_Writer{})
		if append_err != nil || !init_shard_transaction_writer(&td.shard_writers.writers[0], path, shard, 0, 1) {
			shutdown_shard_writer_registry(&td.shard_writers)
			return path, false
		}
		td.shard_writers.writer_index[shard] = 0
		td.shard_writers.mode = .Active
		return path, true
	}

	task_handler_test_payload :: proc(t: ^testing.T, sim: ^Sim_Runtime, conn: ^NRC_Connection, expected: pr.Opcode) -> (payload: []u8, ok: bool) {
		testing.expect(t, simulation_test_commit_shards(sim))
		testing.expect_value(t, nrc_sim_client_frame_count(sim, conn.sock), 1)
		if nrc_sim_client_frame_count(sim, conn.sock) != 1 do return
		payload, ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(sim, conn.sock, 0))
		testing.expect(t, ok, "captured task response should be a complete WebSocket frame")
		if !ok do return
		testing.expect_value(t, pr.get_opcode(payload), expected)
		return
	}

	TASK_CREATE_EQUIVALENCE_PAYLOAD_CAPACITY :: 2_048

	Task_Create_Equivalence_Result :: struct {
		payload:        [TASK_CREATE_EQUIVALENCE_PAYLOAD_CAPACITY]byte,
		payload_len:    int,
		task_count:     int,
		wal_records:    u64,
		task_floor:     u64,
		response_count: int,
	}

	task_equivalence_deliver_wire :: proc(sim: ^Sim_Runtime, client: ^NRC_Connection, payload: []byte, split_a, split_b: int) -> bool {
		frame := make_test_ws_frame(payload, .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(sim, client, frame[start:end]) do return false
		}
		nrc_sim_run_all_receives(sim)
		return true
	}

	task_create_equivalence_run :: proc(
		req: pr.CreateTaskRequest,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Task_Create_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, through_wire ? 131 : 130)
		defer simulation_test_end(&ctx)
		workspace_id := "task-create-parser-direct-equivalence"
		wal_path, writer_ok := task_handler_test_init_sim_writer(workspace_id, "task_create_equivalence.log")
		defer os.remove(wal_path)
		if !writer_ok do return {}, "initialize task WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.task_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return {}, "install simulated client", false
		ctx.conns[1] = client
		subscribe_to_conversation(client, req.conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)

		if through_wire {
			request_buf: [1_024]byte
			request_len := pr.serializeCreateTaskRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize create-task request", false
			if !task_equivalence_deliver_wire(&ctx.sim, client, request_buf[:request_len], split_a, split_b) do return {}, "deliver split create-task request", false
		} else {
			process_create_task(client, req)
		}

		result: Task_Create_Equivalence_Result
		if !simulation_test_commit_shards(&ctx.sim) do return result, "commit create-task", false
		result.response_count = nrc_sim_client_frame_count(&ctx.sim, client.sock)
		if result.response_count != 1 do return result, "unexpected create-task response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, 0))
		if !payload_ok || len(payload) > len(result.payload) do return result, "capture create-task response", false
		copy(result.payload[:], payload)
		result.payload_len = len(payload)
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, req.conv_id)
		if conv == nil do return result, "created conversation missing", false
		result.task_count = len(conv.tasks)
		result.wal_records = td.shard_writers.writers[0].wal.record_count
		result.task_floor = td.shard_writers.writers[0].floors.task
		if pr.get_opcode(payload) != .S_TaskCreated || result.task_count != 1 || result.wal_records != 1 || result.task_floor != 1 {
			return result, "create-task path did not produce the expected successful mutation", false
		}
		return result, "", true
	}

	prop_task_create_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		selector, selector_err := hgl.draw_i64(tc, 0, 255)
		if selector_err == .Stop_Test do return hgl.abort()
		if selector_err != nil do return hgl.interesting("request selector draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 255)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 255)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("second split draw failed")

		titles := [?]string{"equivalence task", "x", "parser/direct boundaries"}
		descriptions := [?]string{"", "generated description", "split payload description"}
		projects := [?]string{"", "nrc", "simulation"}
		attachment_storage: [1]pr.Attachment
		attachments: []pr.Attachment
		if selector & 1 != 0 {
			attachment_storage[0] = {
				file_id     = transmute([]byte)string("generated-file"),
				filename    = transmute([]byte)string("equivalence.txt"),
				size        = u64(1_000 + selector),
				mime_type   = transmute([]byte)string("text/plain"),
				uploaded_at = 2_000 + selector,
			}
			attachments = attachment_storage[:]
		}
		req := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)titles[selector % i64(len(titles))],
			description    = transmute([]byte)descriptions[(selector / 3) % i64(len(descriptions))],
			priority       = u8(selector % 5),
			color          = pr.TaskColor(selector % 6),
			external_ref   = selector & 2 != 0 ? transmute([]byte)string("generated-ref") : nil,
			due_at         = selector & 4 != 0 ? 3_000 + selector : 0,
			attachments    = attachments,
			status         = pr.TaskStatus(selector % 5),
			correlation_id = u32(0x5000 + selector),
			project        = transmute([]byte)projects[(selector / 7) % i64(len(projects))],
		}
		direct, direct_reason, direct_ok := task_create_equivalence_run(req, false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := task_create_equivalence_run(req, true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		payloads_equal := direct.payload_len == wire.payload_len
		if payloads_equal {
			for value, index in direct.payload[:direct.payload_len] do if value != wire.payload[index] {payloads_equal = false; break}
		}
		if !payloads_equal || direct.task_count != wire.task_count || direct.wal_records != wire.wal_records || direct.task_floor != wire.task_floor {
			return hgl.interesting("direct and split-wire create-task semantics differ")
		}
		return hgl.valid()
	}

	Task_Update_Equivalence_Result :: struct {
		payload:        [TASK_CREATE_EQUIVALENCE_PAYLOAD_CAPACITY]byte,
		payload_len:    int,
		task_count:     int,
		wal_records:    u64,
		task_floor:     u64,
		index_count:    int,
		btree_count:    int,
		index_key:      Task_Sort_Key,
		index_present:  bool,
		btree_contains: bool,
		response_count: int,
	}

	task_update_equivalence_run :: proc(
		req: pr.UpdateTaskRequest,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Task_Update_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, through_wire ? 133 : 132)
		defer simulation_test_end(&ctx)
		workspace_id := "task-update-parser-direct-equivalence"
		wal_path, writer_ok := task_handler_test_init_sim_writer(workspace_id, "task_update_equivalence.log")
		defer os.remove(wal_path)
		if !writer_ok do return {}, "initialize update-task WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.task_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return {}, "install update-task simulated client", false
		ctx.conns[1] = client
		subscribe_to_conversation(client, req.conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)
		baseline_attachment := [1]pr.Attachment {
			{
				file_id = transmute([]byte)string("baseline-file"),
				filename = transmute([]byte)string("baseline.txt"),
				size = 100,
				mime_type = transmute([]byte)string("text/plain"),
				uploaded_at = 200,
			},
		}
		process_create_task(
			client,
			pr.CreateTaskRequest {
				conv_id = req.conv_id,
				title = transmute([]byte)string("baseline title"),
				description = transmute([]byte)string("baseline description"),
				priority = 2,
				color = .Gold,
				external_ref = transmute([]byte)string("baseline-ref"),
				due_at = 500,
				attachments = baseline_attachment[:],
				status = .Todo,
				project = transmute([]byte)string("baseline-project"),
			},
		)
		if !simulation_test_commit_shards(&ctx.sim) do return {}, "commit update-task baseline", false
		if nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 do return {}, "create update-task baseline", false
		nrc_sim_clear_inboxes(&ctx.sim)

		if through_wire {
			request_buf: [1_024]byte
			request_len := pr.serializeUpdateTaskRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize update-task request", false
			if !task_equivalence_deliver_wire(&ctx.sim, client, request_buf[:request_len], split_a, split_b) do return {}, "deliver split update-task request", false
		} else {
			process_update_task(client, req)
		}

		result: Task_Update_Equivalence_Result
		if !simulation_test_commit_shards(&ctx.sim) do return result, "commit update-task", false
		result.response_count = nrc_sim_client_frame_count(&ctx.sim, client.sock)
		if result.response_count != 1 do return result, "unexpected update-task response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, 0))
		if !payload_ok || len(payload) > len(result.payload) do return result, "capture update-task response", false
		copy(result.payload[:], payload)
		result.payload_len = len(payload)
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, req.conv_id)
		if conv == nil do return result, "updated conversation missing", false
		result.task_count = len(conv.tasks)
		result.wal_records = td.shard_writers.writers[0].wal.record_count
		result.task_floor = td.shard_writers.writers[0].floors.task
		result.index_count = len(conv.task_index_keys)
		result.index_key, result.index_present = conv.task_index_keys[req.task_id]
		result.btree_count = btree.count(&conv.task_index)
		if result.index_present do result.btree_contains = btree.contains(&conv.task_index, result.index_key)
		expected_task_floor := u64(1)
		if req.blocked_by != 0 && req.blocked_by != max(pr.TaskID) do expected_task_floor = max(expected_task_floor, u64(req.blocked_by))
		if pr.get_opcode(payload) != .S_TaskUpdated ||
		   result.task_count != 1 ||
		   result.wal_records != 2 ||
		   result.task_floor != expected_task_floor ||
		   result.index_count != 1 ||
		   result.btree_count != 1 ||
		   !result.index_present ||
		   !result.btree_contains {
			return result, "update-task path did not produce the expected successful mutation", false
		}
		return result, "", true
	}

	task_update_equivalence_results_equal :: proc(a, b: Task_Update_Equivalence_Result) -> bool {
		if a.payload_len != b.payload_len do return false
		for index in 0 ..< a.payload_len do if a.payload[index] != b.payload[index] do return false
		return(
			a.task_count == b.task_count &&
			a.wal_records == b.wal_records &&
			a.task_floor == b.task_floor &&
			a.index_count == b.index_count &&
			a.btree_count == b.btree_count &&
			a.index_present == b.index_present &&
			a.btree_contains == b.btree_contains &&
			a.index_key == b.index_key \
		)
	}

	task_update_equivalence_mandatory_cases :: proc(t: ^testing.T) -> bool {
		clear_value := [1]byte{0}
		replacement := transmute([]byte)string("mandatory replacement")
		replacement_attachment := [1]pr.Attachment {
			{
				file_id = transmute([]byte)string("mandatory-file"),
				filename = transmute([]byte)string("mandatory.bin"),
				size = 4_096,
				mime_type = transmute([]byte)string("application/octet-stream"),
				uploaded_at = 8_192,
			},
		}
		cases := [?]pr.UpdateTaskRequest {
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				task_id = 1,
				status = pr.TaskStatus(255),
				priority = 255,
				color = pr.TaskColor(255),
				preserve_attachments = true,
				correlation_id = 0x6100,
			},
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				task_id = 1,
				title = clear_value[:],
				description = clear_value[:],
				status = .Done,
				assignee = clear_value[:],
				priority = 0,
				color = .None,
				external_ref = clear_value[:],
				due_at = -1,
				blocked_by = max(pr.TaskID),
				correlation_id = 0x6101,
				project = clear_value[:],
			},
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				task_id = 1,
				title = replacement,
				description = replacement,
				status = .InProgress,
				assignee = replacement,
				priority = 4,
				color = .Green,
				external_ref = replacement,
				due_at = 9_000,
				blocked_by = 99,
				attachments = replacement_attachment[:],
				correlation_id = 0x6102,
				project = replacement,
			},
		}
		for req, case_index in cases {
			direct, direct_reason, direct_ok := task_update_equivalence_run(req, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory update case %d direct path failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := task_update_equivalence_run(req, true, 1 + case_index, 7 + case_index)
			testing.expectf(t, wire_ok, "mandatory update case %d split-wire path failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := task_update_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory update case %d direct and split-wire semantics should match", case_index)
			if !equal do return false
		}
		return true
	}

	prop_task_update_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		selector, selector_err := hgl.draw_i64(tc, 0, 2_047)
		if selector_err == .Stop_Test do return hgl.abort()
		if selector_err != nil do return hgl.interesting("update request selector draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 255)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("update first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 255)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("update second split draw failed")

		clear_value := [1]byte{0}
		string_values := [3][]byte{nil, clear_value[:], transmute([]byte)string("updated value")}
		replacement_attachment := [1]pr.Attachment {
			{
				file_id = transmute([]byte)string("updated-file"),
				filename = transmute([]byte)string("updated.bin"),
				size = u64(1_000 + selector),
				mime_type = transmute([]byte)string("application/octet-stream"),
				uploaded_at = 2_000 + selector,
			},
		}
		attachment_mode := selector % 3
		status_value := (selector / 3) % 6
		priority_value := (selector / 18) % 6
		color_value := (selector / 108) % 7
		due_variant := (selector / 756) % 3
		blocked_variant := (selector / 252) % 3
		req := pr.UpdateTaskRequest {
			conv_id              = pr.WORKSPACE_DATA_ID,
			task_id              = 1,
			title                = string_values[(selector / 2) % 3],
			description          = string_values[(selector / 5) % 3],
			status               = status_value == 5 ? pr.TaskStatus(255) : pr.TaskStatus(status_value),
			assignee             = string_values[(selector / 7) % 3],
			priority             = priority_value == 5 ? 255 : u8(priority_value),
			color                = color_value == 6 ? pr.TaskColor(255) : pr.TaskColor(color_value),
			external_ref         = string_values[(selector / 11) % 3],
			due_at               = due_variant == 0 ? 0 : (due_variant == 1 ? -1 : 9_000 + selector),
			blocked_by           = blocked_variant == 0 ? 0 : (blocked_variant == 1 ? max(pr.TaskID) : pr.TaskID(99)),
			attachments          = attachment_mode == 1 ? replacement_attachment[:] : nil,
			preserve_attachments = attachment_mode == 0,
			correlation_id       = u32(0x6000 + selector),
			project              = string_values[(selector / 13) % 3],
		}
		direct, direct_reason, direct_ok := task_update_equivalence_run(req, false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := task_update_equivalence_run(req, true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !task_update_equivalence_results_equal(direct, wire) {
			return hgl.interesting("direct and split-wire update-task semantics differ")
		}
		return hgl.valid()
	}

	Task_Final_Mutation_Kind :: enum {
		Move,
		Delete,
	}

	Task_Final_Mutation_Equivalence_Result :: struct {
		payload:          [TASK_CREATE_EQUIVALENCE_PAYLOAD_CAPACITY]byte,
		payload_len:      int,
		task_payload:     [TASK_CREATE_EQUIVALENCE_PAYLOAD_CAPACITY]byte,
		task_payload_len: int,
		task_count:       int,
		wal_records:      u64,
		wal_last_hash:    [32]byte,
		task_floor:       u64,
		index_count:      int,
		btree_count:      int,
		index_key:        Task_Sort_Key,
		index_present:    bool,
		btree_contains:   bool,
	}

	task_final_mutation_equivalence_run :: proc(
		kind: Task_Final_Mutation_Kind,
		move_req: pr.MoveTaskRequest,
		delete_req: pr.DeleteTaskRequest,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Task_Final_Mutation_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, through_wire ? 135 : 134)
		defer simulation_test_end(&ctx)
		workspace_id := "task-final-mutation-parser-direct-equivalence"
		wal_path, writer_ok := task_handler_test_init_sim_writer(workspace_id, "task_final_mutation_equivalence.log")
		defer os.remove(wal_path)
		if !writer_ok do return {}, "initialize final task mutation WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.task_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return {}, "install final task mutation client", false
		ctx.conns[1] = client
		conv_id := kind == .Move ? move_req.conv_id : delete_req.conv_id
		subscribe_to_conversation(client, conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)
		process_create_task(
			client,
			pr.CreateTaskRequest {
				conv_id = conv_id,
				title = transmute([]byte)string("final mutation baseline"),
				status = .Todo,
				project = transmute([]byte)string("equivalence"),
			},
		)
		if !simulation_test_commit_shards(&ctx.sim) do return {}, "commit final task baseline", false
		if nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 do return {}, "create final task mutation baseline", false
		nrc_sim_clear_inboxes(&ctx.sim)
		ctx.sim.world.now += 1

		// The fixture holds one Todo task, so an append request resolves against
		// that column: the model reads the fold the server folds, and the direct
		// and split-wire runs of one drawn request expect the same position.
		expected_order_index := move_req.order_index
		if kind == .Move && .Append in move_req.flags {
			pre_conv := get_conversation(get_workspace(workspace_id), conv_id)
			if pre_conv == nil do return {}, "final task mutation conversation missing before the move", false
			expected_order_index, _ = calculate_next_order_index(pre_conv.tasks, move_req.status)
		}

		if through_wire {
			request_buf: [64]byte
			request_len := -1
			switch kind {
			case .Move:
				request_len = pr.serializeMoveTaskRequest(move_req, request_buf[:])
			case .Delete:
				request_len = pr.serializeDeleteTaskRequest(delete_req.conv_id, delete_req.task_id, request_buf[:], delete_req.correlation_id)
			}
			if request_len <= 0 do return {}, "serialize final task mutation request", false
			if !task_equivalence_deliver_wire(&ctx.sim, client, request_buf[:request_len], split_a, split_b) do return {}, "deliver split final task mutation request", false
		} else {
			switch kind {
			case .Move:
				process_move_task(client, move_req)
			case .Delete:
				process_delete_task(client, delete_req)
			}
		}

		result: Task_Final_Mutation_Equivalence_Result
		if !simulation_test_commit_shards(&ctx.sim) do return result, "commit final task mutation", false
		if nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 do return result, "unexpected final task mutation response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, 0))
		if !payload_ok || len(payload) > len(result.payload) do return result, "capture final task mutation response", false
		copy(result.payload[:], payload)
		result.payload_len = len(payload)
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, conv_id)
		if conv == nil do return result, "final task mutation conversation missing", false
		result.task_count = len(conv.tasks)
		result.wal_records = td.shard_writers.writers[0].wal.record_count
		result.wal_last_hash = td.shard_writers.writers[0].wal.last_hash
		result.task_floor = td.shard_writers.writers[0].floors.task
		result.index_count = len(conv.task_index_keys)
		result.btree_count = btree.count(&conv.task_index)
		result.index_key, result.index_present = conv.task_index_keys[1]
		if result.index_present do result.btree_contains = btree.contains(&conv.task_index, result.index_key)
		if task := conv.tasks[1]; task != nil {
			result.task_payload_len = pr.serializeTask(task^, result.task_payload[:])
			if result.task_payload_len <= 0 do return result, "serialize final task state", false
		}

		switch kind {
		case .Move:
			task := conv.tasks[1]
			if task == nil do return result, "moved task missing", false
			expected_key := make_task_sort_key(task)
			if pr.get_opcode(payload) != .S_TaskMoved ||
			   result.task_count != 1 ||
			   result.wal_records != 2 ||
			   result.wal_last_hash == ([32]byte{}) ||
			   result.task_floor != 1 ||
			   task.status != move_req.status ||
			   task.order_index != expected_order_index ||
			   task.updated_at <= task.created_at ||
			   (task.status == .Done && (task.completed_at != task.updated_at || string(task.completed_by) != "equivalence-user")) ||
			   (task.status != .Done && (task.completed_at != 0 || len(task.completed_by) != 0)) ||
			   result.index_count != 1 ||
			   result.btree_count != 1 ||
			   !result.index_present ||
			   !result.btree_contains ||
			   result.index_key != expected_key ||
			   !btree.contains(&conv.task_index, expected_key) {
				return result, "move-task path did not produce the expected successful mutation", false
			}
		case .Delete:
			if pr.get_opcode(payload) != .S_TaskDeleted ||
			   result.task_count != 0 ||
			   result.wal_records != 2 ||
			   result.wal_last_hash == ([32]byte{}) ||
			   result.task_floor != 1 ||
			   result.task_payload_len != 0 ||
			   result.index_count != 0 ||
			   result.btree_count != 0 ||
			   result.index_present ||
			   result.btree_contains {
				return result, "delete-task path did not produce the expected successful mutation", false
			}
		}
		return result, "", true
	}

	task_final_mutation_equivalence_results_equal :: proc(a, b: Task_Final_Mutation_Equivalence_Result) -> bool {
		if a.payload_len != b.payload_len do return false
		for index in 0 ..< a.payload_len do if a.payload[index] != b.payload[index] do return false
		if a.task_payload_len != b.task_payload_len do return false
		for index in 0 ..< a.task_payload_len do if a.task_payload[index] != b.task_payload[index] do return false
		return(
			a.task_count == b.task_count &&
			a.wal_records == b.wal_records &&
			a.wal_last_hash == b.wal_last_hash &&
			a.task_floor == b.task_floor &&
			a.index_count == b.index_count &&
			a.btree_count == b.btree_count &&
			a.index_present == b.index_present &&
			a.btree_contains == b.btree_contains &&
			a.index_key == b.index_key \
		)
	}

	prop_task_final_mutation_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		kind_value, kind_err := hgl.draw_i64(tc, 0, 1)
		if kind_err == .Stop_Test do return hgl.abort()
		if kind_err != nil do return hgl.interesting("final task mutation kind draw failed")
		status, status_err := hgl.draw_i64(tc, 0, 4)
		if status_err == .Stop_Test do return hgl.abort()
		if status_err != nil do return hgl.interesting("move-task status draw failed")
		order_index, order_err := hgl.draw_i64(tc, 0, i64(max(u16)))
		if order_err == .Stop_Test do return hgl.abort()
		if order_err != nil do return hgl.interesting("move-task order draw failed")
		append_flag, append_err := hgl.draw_i64(tc, 0, 1)
		if append_err == .Stop_Test do return hgl.abort()
		if append_err != nil do return hgl.interesting("move-task flags draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("final task mutation correlation draw failed")
		kind := Task_Final_Mutation_Kind(kind_value)
		frame_len := kind == .Move ? 31 : 28
		split_a, split_a_err := hgl.draw_i64(tc, 1, i64(frame_len - 1))
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("final task mutation first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 1, i64(frame_len - 1))
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("final task mutation second split draw failed")
		move_req := pr.MoveTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			task_id        = 1,
			status         = pr.TaskStatus(status),
			flags          = append_flag == 1 ? pr.MoveTaskFlag_APPEND : pr.MoveTaskFlags{},
			order_index    = u16(order_index),
			correlation_id = u32(correlation),
		}
		delete_req := pr.DeleteTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			task_id        = 1,
			correlation_id = u32(correlation),
		}
		direct, direct_reason, direct_ok := task_final_mutation_equivalence_run(kind, move_req, delete_req, false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := task_final_mutation_equivalence_run(kind, move_req, delete_req, true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !task_final_mutation_equivalence_results_equal(direct, wire) {
			return hgl.interesting("direct and split-wire final task mutation semantics differ")
		}
		return hgl.valid()
	}

	task_final_mutation_equivalence_mandatory_cases :: proc(t: ^testing.T) -> bool {
		cases := [?]Task_Final_Mutation_Kind{.Move, .Delete}
		for kind, case_index in cases {
			move_req := pr.MoveTaskRequest {
				conv_id        = pr.WORKSPACE_DATA_ID,
				task_id        = 1,
				status         = .Done,
				order_index    = 321,
				correlation_id = 0x7200,
			}
			delete_req := pr.DeleteTaskRequest {
				conv_id        = pr.WORKSPACE_DATA_ID,
				task_id        = 1,
				correlation_id = 0x7201,
			}
			direct, direct_reason, direct_ok := task_final_mutation_equivalence_run(kind, move_req, delete_req, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory final mutation case %d direct path failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := task_final_mutation_equivalence_run(kind, move_req, delete_req, true, 2 + case_index, 9 + case_index)
			testing.expectf(t, wire_ok, "mandatory final mutation case %d split-wire path failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := task_final_mutation_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory final mutation case %d direct and split-wire semantics should match", case_index)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_task_create_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_task_create_parser_direct_equivalence, nil, {test_cases = 32})
		testing.expectf(t, err == nil, "generated create-task parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_task_update_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !task_update_equivalence_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_task_update_parser_direct_equivalence, nil, {test_cases = 48})
		testing.expectf(t, err == nil, "generated update-task parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_task_move_delete_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !task_final_mutation_equivalence_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_task_final_mutation_parser_direct_equivalence, nil, {test_cases = 48})
		testing.expectf(
			t,
			err == nil,
			"generated move/delete-task parser/direct equivalence failed: err=%v interesting=%v",
			err,
			result.interesting_test_cases,
		)
	}
}

@(test)
test_simulation_task_handlers_echo_correlations_and_broadcast_zero :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 124)
		defer simulation_test_end(&ctx)
		workspace_id := "task-handler-simulation"
		wal_path, writer_ok := task_handler_test_init_sim_writer(workspace_id)
		defer os.remove(wal_path)
		testing.expect(t, writer_ok, "task handler simulation writer should initialize")
		if !writer_ok do return
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.task_seq = 0

		ops := [?]Sim_Op {
			{kind = .Connect, client_id = 1, workspace_id = workspace_id, username = "alice"},
			{kind = .Connect, client_id = 2, workspace_id = workspace_id, username = "bob"},
			{kind = .Subscribe, client_id = 1, conv_id = 77},
			{kind = .Subscribe, client_id = 2, conv_id = 77},
			{kind = .Clear_Inboxes},
		}
		testing.expect(t, simulation_test_apply_ops(&ctx, ops[:]), "task handler simulation clients should initialize")
		sender := simulation_test_client(&ctx, 1)
		peer := simulation_test_client(&ctx, 2)
		if sender == nil || peer == nil do return

		process_create_task(
			sender,
			pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("simulated task"), status = .Backlog, correlation_id = 101},
		)
		attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		sender_payload, sender_ok := task_handler_test_payload(t, &ctx.sim, sender, .S_TaskCreated)
		peer_payload, peer_ok := task_handler_test_payload(t, &ctx.sim, peer, .S_TaskCreated)
		if sender_ok {
			created, parse_err := pr.parseTaskCreated(sender_payload, attachments[:])
			testing.expect(t, parse_err == nil, "requester TaskCreated should parse")
			testing.expect_value(t, created.correlation_id, u32(101))
		}
		if peer_ok {
			created, parse_err := pr.parseTaskCreated(peer_payload, attachments[:])
			testing.expect(t, parse_err == nil, "peer TaskCreated should parse")
			testing.expect_value(t, created.correlation_id, u32(0))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		process_update_task(
			sender,
			pr.UpdateTaskRequest {
				conv_id = 77,
				task_id = 1,
				status = .Done,
				priority = 255,
				color = pr.TaskColor(255),
				preserve_attachments = true,
				correlation_id = 102,
			},
		)
		sender_payload, sender_ok = task_handler_test_payload(t, &ctx.sim, sender, .S_TaskUpdated)
		peer_payload, peer_ok = task_handler_test_payload(t, &ctx.sim, peer, .S_TaskUpdated)
		if sender_ok {
			updated, parse_err := pr.parseTaskUpdated(sender_payload, attachments[:])
			testing.expect(t, parse_err == nil, "requester TaskUpdated should parse")
			testing.expect_value(t, updated.correlation_id, u32(102))
		}
		if peer_ok {
			updated, parse_err := pr.parseTaskUpdated(peer_payload, attachments[:])
			testing.expect(t, parse_err == nil, "peer TaskUpdated should parse")
			testing.expect_value(t, updated.correlation_id, u32(0))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		process_move_task(sender, pr.MoveTaskRequest{conv_id = 77, task_id = 1, status = .Todo, order_index = 4, correlation_id = 103})
		sender_payload, sender_ok = task_handler_test_payload(t, &ctx.sim, sender, .S_TaskMoved)
		peer_payload, peer_ok = task_handler_test_payload(t, &ctx.sim, peer, .S_TaskMoved)
		if sender_ok {
			moved, parse_err := pr.parseTaskMoved(sender_payload)
			testing.expect(t, parse_err == nil, "requester TaskMoved should parse")
			testing.expect_value(t, moved.correlation_id, u32(103))
		}
		if peer_ok {
			moved, parse_err := pr.parseTaskMoved(peer_payload)
			testing.expect(t, parse_err == nil, "peer TaskMoved should parse")
			testing.expect_value(t, moved.correlation_id, u32(0))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		process_get_tasks(sender, pr.GetTasksRequest{conv_id = 77, correlation_id = 104})
		sender_payload, sender_ok = task_handler_test_payload(t, &ctx.sim, sender, .S_TaskListResponse)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 0)
		if sender_ok {
			tasks: [2]pr.Task
			list_attachments: [2 * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			listed, parse_err := pr.parseTaskListResponse(sender_payload, tasks[:], list_attachments[:])
			testing.expect(t, parse_err == nil, "TaskListResponse should parse")
			testing.expect_value(t, listed.correlation_id, u32(104))
			testing.expect_value(t, len(listed.tasks), 1)
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		process_delete_task(sender, pr.DeleteTaskRequest{conv_id = 77, task_id = 1, correlation_id = 105})
		sender_payload, sender_ok = task_handler_test_payload(t, &ctx.sim, sender, .S_TaskDeleted)
		peer_payload, peer_ok = task_handler_test_payload(t, &ctx.sim, peer, .S_TaskDeleted)
		if sender_ok {
			deleted, parse_err := pr.parseTaskDeleted(sender_payload)
			testing.expect(t, parse_err == nil, "requester TaskDeleted should parse")
			testing.expect_value(t, deleted.correlation_id, u32(105))
		}
		if peer_ok {
			deleted, parse_err := pr.parseTaskDeleted(peer_payload)
			testing.expect(t, parse_err == nil, "peer TaskDeleted should parse")
			testing.expect_value(t, deleted.correlation_id, u32(0))
		}
	}
}

@(test)
test_simulation_task_paging_boundaries_filter_and_direct_get :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 125)
		defer simulation_test_end(&ctx)
		workspace_id := "task-paging-simulation"
		ops := [?]Sim_Op{{kind = .Connect, client_id = 1, workspace_id = workspace_id, username = "alice"}}
		testing.expect(t, simulation_test_apply_ops(&ctx, ops[:]), "task paging client should initialize")
		client := simulation_test_client(&ctx, 1)
		if client == nil do return
		conv := get_or_create_conversation(client.workspace, 88)

		tasks := [4]^pr.Task {
			alloc_task(transmute([]byte)string("done-1"), nil, nil, nil, nil, nil, nil, nil),
			alloc_task(transmute([]byte)string("done-2"), nil, nil, nil, nil, nil, nil, nil),
			alloc_task(transmute([]byte)string("done-3"), nil, nil, nil, nil, nil, nil, nil),
			alloc_task(transmute([]byte)string("active"), nil, nil, nil, nil, nil, nil, nil),
		}
		for i in 0 ..< len(tasks) {
			tasks[i].id = pr.TaskID(i + 1)
			tasks[i].conv_id = 88
			tasks[i].status = i < 3 ? .Done : .Todo
			tasks[i].completed_at = i < 3 ? 500 : 0
			tasks[i].updated_at = i < 3 ? 100 : 900
			conv.tasks[tasks[i].id] = tasks[i]
			index_task(conv, tasks[i])
		}

		process_list_tasks_paged(client, pr.ListTasksPagedRequest{conv_id = 88, status_mask = 1 << u8(pr.TaskStatus.Done), limit = 2, correlation_id = 71})
		payload, ok := task_handler_test_payload(t, &ctx.sim, client, .S_TaskListPage)
		if !ok do return
		page_tasks: [2]pr.Task
		attachments: [2 * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		page, parse_err := pr.parseTaskListPage(payload, page_tasks[:], attachments[:])
		testing.expect(t, parse_err == nil, "first task page should parse")
		testing.expect_value(t, len(page.tasks), 2)
		testing.expect_value(t, page.tasks[0].id, pr.TaskID(3))
		testing.expect_value(t, page.tasks[1].id, pr.TaskID(2))
		testing.expect(t, page.has_more, "first page should have another Done task")
		testing.expect_value(t, page.total_count, u32(3))

		nrc_sim_clear_inboxes(&ctx.sim)
		process_list_tasks_paged(
			client,
			pr.ListTasksPagedRequest {
				conv_id = 88,
				status_mask = 1 << u8(pr.TaskStatus.Done),
				limit = 2,
				has_cursor = true,
				cursor_sort_at = page.next_cursor_sort_at,
				cursor_task_id = page.next_cursor_task_id,
				correlation_id = 72,
			},
		)
		payload, ok = task_handler_test_payload(t, &ctx.sim, client, .S_TaskListPage)
		if !ok do return
		page, parse_err = pr.parseTaskListPage(payload, page_tasks[:], attachments[:])
		testing.expect(t, parse_err == nil, "second task page should parse")
		testing.expect_value(t, len(page.tasks), 1)
		testing.expect_value(t, page.tasks[0].id, pr.TaskID(1))
		testing.expect(t, !page.has_more, "second page should terminate")

		nrc_sim_clear_inboxes(&ctx.sim)
		process_get_task(client, pr.GetTaskRequest{conv_id = 88, task_id = 2, correlation_id = 73})
		payload, ok = task_handler_test_payload(t, &ctx.sim, client, .S_TaskFull)
		if !ok do return
		full_attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		full, full_err := pr.parseTaskFull(payload, full_attachments[:])
		testing.expect(t, full_err == nil, "direct task response should parse")
		testing.expect(t, full.has_task, "direct task response should materialize Done task")
		testing.expect_value(t, full.task.id, pr.TaskID(2))
		testing.expect_value(t, full.correlation_id, u32(73))

		// A count-only limit would exceed the transport frame cap with maximum
		// descriptions. The handler must end the page at a task boundary.
		large_conv := get_or_create_conversation(client.workspace, 89)
		description: [pr.MAX_TASK_DESCRIPTION_LENGTH]byte
		for &b in description do b = 'x'
		for i in 0 ..< 70 {
			large_task := alloc_task(transmute([]byte)string("large"), description[:], nil, nil, nil, nil, nil, nil)
			large_task.id = pr.TaskID(100 + i)
			large_task.conv_id = 89
			large_task.status = .Backlog
			large_task.updated_at = i64(i)
			large_conv.tasks[large_task.id] = large_task
			index_task(large_conv, large_task)
		}
		nrc_sim_clear_inboxes(&ctx.sim)
		process_list_tasks_paged(client, pr.ListTasksPagedRequest{conv_id = 89, status_mask = 1, limit = pr.MAX_TASK_PAGE_SIZE, correlation_id = 74})
		payload, ok = task_handler_test_payload(t, &ctx.sim, client, .S_TaskListPage)
		if !ok do return
		large_page_tasks: [70]pr.Task
		large_attachments: [70 * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		large_page, large_err := pr.parseTaskListPage(payload, large_page_tasks[:], large_attachments[:])
		testing.expect(t, large_err == nil, "byte-budgeted task page should parse")
		testing.expect(t, large_page.has_more, "byte-budgeted page should advertise remaining tasks")
		testing.expect(t, len(large_page.tasks) > 0 && len(large_page.tasks) < 70, "byte budget should split large task result")
		testing.expect(t, len(payload) <= MAX_PROTOCOL_PAYLOAD_SIZE, "task page must fit protocol payload cap")
	}
}
