package main

import "btree"
import "core:encoding/endian"
import "core:os"
import "core:testing"
import pr "protocol"
import ws "websocket"

when !NRC_SIMULATION do _ :: os.remove

@(test)
test_oversized_completion_rejects_without_storage_failure :: proc(t: ^testing.T) {
	workspace := "oversized-completion"
	if !init_room_mapping_test_state("oversized_completion.log", workspace) {
		testing.expect(t, false, "initialize completion fixture")
		return
	}
	defer cleanup_room_mapping_test_state()
	server: NRC_Server
	previous_server := td.server
	td.server = &server
	persistent_mutation_failure_seen = false
	defer {td.server = previous_server; persistent_mutation_failure_seen = false}
	c := make_room_mapping_test_connection(workspace)
	c.state = .Idle; c.is_sending = true
	defer send_queue_destroy(&c)
	conv := get_or_create_conversation(get_or_create_connection_workspace(&c), pr.WORKSPACE_DATA_ID)
	description: [pr.MAX_TASK_DESCRIPTION_LENGTH]byte
	for &b in description do b = 'd'
	// The expanded completion exceeds the 16 MiB WAL record size while its
	// mutation count remains well below 65535.
	for i in 0 ..< 8_501 {
		task := alloc_task(transmute([]byte)string("task"), description[:], nil, nil, nil, nil, nil, nil)
		task.id = pr.TaskID(i + 1); task.conv_id = pr.WORKSPACE_DATA_ID
		task.status = .Backlog; task.blocked_by = i == 0 ? 0 : 1
		task_store_put(conv, task)
	}
	td.task_seq = 8_501
	for mode in 0 ..< 3 {
		if mode == 0 {
			process_update_task(&c, {conv_id = pr.WORKSPACE_DATA_ID, task_id = 1, status = .Done})
		} else if mode == 1 {
			process_move_task(&c, {conv_id = pr.WORKSPACE_DATA_ID, task_id = 1, status = .Done})
		} else {
			body := task_unblock_test_status_patch(pr.WORKSPACE_DATA_ID, 1, .Done)
			ops := [1]pr.TransactionOperation{{op_type = .TaskPatch, body = body[:]}}
			process_apply_transaction(&c, {operations = ops[:]})
		}
		testing.expect(t, !server.closing && !server.fatal_storage_error && !persistent_mutation_failure_seen, "oversized completion is not a storage failure")
		testing.expect_value(t, conv.tasks[1].status, pr.TaskStatus.Backlog)
		for id, task in conv.tasks do testing.expect_value(t, task.blocked_by, id == 1 ? pr.TaskID(0) : pr.TaskID(1))
		testing.expect_value(t, btree.count(&conv.task_blockers), 8_500)
		testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, u64(0))
		testing.expect_value(t, send_queue_len(&c), 1)
		if item := send_queue_peek(&c); item != nil {
			frame := frame_lease_data(item.lease)
			_, header_size, frame_err := ws.readFrameHeader(frame)
			testing.expect_value(t, frame_err, nil)
			payload := frame[header_size:]
			if mode < 2 {
				response, err := pr.parseTaskListResponse(payload, nil, nil)
				testing.expect_value(t, err, nil)
				testing.expect(t, !response.success)
				testing.expect_value(t, string(response.error), "Task completion exceeds atomic transaction size limit")
			} else {
				testing.expect_value(t, pr.get_opcode(payload), pr.Opcode.S_TransactionResult)
				testing.expect_value(t, payload[3], u8(pr.TransactionResultStatus.Rejected))
			}
		}
		send_queue_drain(&c)
	}
}

task_unblock_test_seed :: proc(t: ^testing.T, workspace: string, conv: ^Conversation_State, conv_id: pr.ConversationID, id, blocker: pr.TaskID) {
	task := alloc_task(transmute([]byte)string("preserved title"), transmute([]byte)string("preserved description"), nil, nil, nil, nil, nil, nil)
	task.id = id; task.conv_id = conv_id; task.status = .Backlog; task.blocked_by = blocker
	task.updated_at = 123; task.priority = 2; task.due_at = 456
	testing.expect(t, persist_task_created(workspace, task))
	task_store_put(conv, task)
	td.task_seq = max(td.task_seq, u64(id))
}

task_unblock_test_status_patch :: proc(conv_id: pr.ConversationID, id: pr.TaskID, status: pr.TaskStatus) -> [31]byte {
	body: [31]byte
	endian.put_u64(body[:], .Big, u64(conv_id))
	transaction_test_ref(body[8:], .Existing, .Task, u64(id))
	endian.put_u16(body[28:], .Big, pr.TRANSACTION_TASK_PATCH_STATUS)
	body[30] = u8(status)
	return body
}

@(test)
test_task_completion_unblocks_update_move_transaction_and_replay :: proc(t: ^testing.T) {
	for mode in 0 ..< 3 {
		workspace := "task-unblock-paths"
		testing.expect(t, init_room_mapping_test_state("task_unblock_paths.log", workspace))
		c := make_room_mapping_test_connection(workspace)
		ws := get_or_create_connection_workspace(&c)
		conv := get_or_create_conversation(ws, 81)
		td.task_seq = 0
		task_unblock_test_seed(t, workspace, conv, 81, 1, 0)
		task_unblock_test_seed(t, workspace, conv, 81, 2, 1)
		task_unblock_test_seed(t, workspace, conv, 81, 3, 2)
		task_unblock_test_seed(t, workspace, conv, 81, 4, 1)
		before := td.shard_writers.writers[0].wal.record_count
		if mode == 0 {
			process_update_task(&c, {conv_id = 81, task_id = 1, status = .Done, priority = 255, color = pr.TaskColor(255), preserve_attachments = true})
		} else if mode == 1 {
			process_move_task(&c, {conv_id = 81, task_id = 1, status = .Done, order_index = 91})
		} else {
			body := task_unblock_test_status_patch(81, 1, .Done)
			ops := [1]pr.TransactionOperation{{op_type = .TaskPatch, body = body[:]}}
			process_apply_transaction(&c, {operations = ops[:]})
		}
		testing.expect(t, td.shard_writers.writers[0].wal.record_count == before + 1, "completion and both dependent updates occupy one atomic record")
		testing.expect_value(t, conv.tasks[1].status, pr.TaskStatus.Done)
		for id in ([2]pr.TaskID{2, 4}) {
			testing.expect_value(t, conv.tasks[id].blocked_by, pr.TaskID(0))
			testing.expect(t, conv.tasks[id].updated_at > 123)
			testing.expect_value(t, string(conv.tasks[id].description), "preserved description")
			testing.expect_value(t, conv.tasks[id].due_at, i64(456))
			testing.expect_value(t, conv.tasks[id].priority, u8(2))
		}
		testing.expect(t, conv.tasks[3].blocked_by == 2, "unblocking is not completing: no transitive cascade")
		testing.expect_value(t, conv.tasks[3].updated_at, i64(123))
		testing.expect_value(t, btree.count(&conv.task_blockers), 1)
		page: [dynamic]pr.Task
		result := collect_task_query_page(conv, {status_mask = 0x0f, color = 255, blocked = 1, limit = 10}, &page)
		testing.expect(t, result.total_count == 1 && len(page) == 1 && page[0].id == 3, "blocked filter sees only the remaining dependency")
		delete(page)
		process_move_task(&c, {conv_id = 81, task_id = 1, status = .Backlog})
		testing.expect(t, conv.tasks[2].blocked_by == 0, "reopening never restores a consumed dependency")
		unblocked_at := conv.tasks[2].updated_at
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		send_queue_destroy(&c)
		shutdown_shard_writer_registry(&td.shard_writers)
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		inspection, _, ok := scan_shard_transaction_wal(room_mapping_test_wal_path, shard, {}, true, true)
		testing.expectf(t, ok, "replay complete WAL mode=%d inspection=%v", mode, inspection)
		conv = get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
		testing.expect(t, conv != nil)
		testing.expect_value(t, conv.tasks[1].status, pr.TaskStatus.Backlog)
		testing.expect_value(t, conv.tasks[2].blocked_by, pr.TaskID(0))
		testing.expect_value(t, conv.tasks[4].blocked_by, pr.TaskID(0))
		testing.expect_value(t, conv.tasks[2].updated_at, unblocked_at)
		testing.expect_value(t, btree.count(&conv.task_blockers), 1)
		cleanup_room_mapping_test_state()
	}
}

@(test)
test_task_completion_transaction_uses_projected_dependencies :: proc(t: ^testing.T) {
	for reverse in ([2]bool{false, true}) {
		workspace := "task-unblock-projected"
		testing.expect(t, init_room_mapping_test_state("task_unblock_projected.log", workspace))
		c := make_room_mapping_test_connection(workspace)
		conv := get_or_create_conversation(get_or_create_connection_workspace(&c), 82)
		td.task_seq = 0
		for id in 1 ..= 5 do task_unblock_test_seed(t, workspace, conv, 82, pr.TaskID(id), id == 1 ? 0 : 1)
		done := task_unblock_test_status_patch(82, 1, .Done)
		patch := task_unblock_test_status_patch(82, 2, .Todo)
		reassign := transaction_delta_task_blocked_by_patch_body(82, 3, 2)
		remove := transaction_test_delete_body(82, .Task, 4)
		create := transaction_test_task_create_body(82, .Existing, 1, 'n')
		ops := [5]pr.TransactionOperation {
			{op_type = .TaskPatch, body = done[:]},
			{op_type = .TaskPatch, body = patch[:]},
			{op_type = .TaskPatch, body = reassign[:]},
			{op_type = .TaskDelete, body = remove[:]},
			{op_type = .TaskCreate, body = create[:]},
		}
		if reverse do ops[0], ops[4] = ops[4], ops[0]
		before := td.shard_writers.writers[0].wal.record_count
		// Fail after cascade preparation; neither the staged patch nor an implicit
		// dependent update may escape a rejected transaction.
		transaction_test_ref(create[20:], .Existing, .Task, 999)
		process_apply_transaction(&c, {operations = ops[:]})
		testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, before)
		testing.expect_value(t, conv.tasks[1].status, pr.TaskStatus.Backlog)
		testing.expect_value(t, conv.tasks[2].blocked_by, pr.TaskID(1))
		testing.expect_value(t, conv.tasks[5].blocked_by, pr.TaskID(1))
		transaction_test_ref(create[20:], .Existing, .Task, 1)
		process_apply_transaction(&c, {operations = ops[:]})
		testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, before + 1)
		testing.expect_value(t, conv.tasks[1].status, pr.TaskStatus.Done)
		testing.expect_value(t, conv.tasks[2].status, pr.TaskStatus.Todo)
		testing.expect(t, conv.tasks[2].blocked_by == 0, "patch does not restore old blocker")
		testing.expect(t, conv.tasks[3].blocked_by == 2, "explicit different blocker survives")
		testing.expect(t, conv.tasks[4] == nil, "deleted dependent stays deleted")
		testing.expect(t, conv.tasks[5].blocked_by == 0, "untouched dependent unblocks")
		testing.expect(t, conv.tasks[6].blocked_by == 0, "new dependent uses final blocker status")
		testing.expect_value(t, btree.count(&conv.task_blockers), 1)
		send_queue_destroy(&c)
		cleanup_room_mapping_test_state()
	}
}

@(test)
test_task_completion_broadcasts_unblocks_to_requester_and_peer :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 125)
		defer simulation_test_end(&ctx)
		workspace := "task-unblock-broadcast"
		path, ok := task_handler_test_init_sim_writer(workspace, "task_unblock_broadcast.log")
		defer os.remove(path)
		testing.expect(t, ok)
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.task_seq = 0
		setup := [?]Sim_Op {
			{kind = .Connect, client_id = 1, workspace_id = workspace, username = "alice"},
			{kind = .Connect, client_id = 2, workspace_id = workspace, username = "bob"},
			{kind = .Subscribe, client_id = 1, conv_id = 0},
			{kind = .Subscribe, client_id = 2, conv_id = 0},
		}
		testing.expect(t, simulation_test_apply_ops(&ctx, setup[:]))
		sender := simulation_test_client(&ctx, 1)
		peer := simulation_test_client(&ctx, 2)
		conv := get_conversation(get_workspace(workspace), 0)
		for mode in 0 ..< 4 {
			a := pr.TaskID(mode * 2 + 1); b := a + 1
			task_unblock_test_seed(t, workspace, conv, 0, a, 0)
			task_unblock_test_seed(t, workspace, conv, 0, b, a)
			nrc_sim_clear_inboxes(&ctx.sim)
			if mode == 0 {
				process_update_task(sender, {conv_id = 0, task_id = a, status = .Done, priority = 255, color = pr.TaskColor(255), preserve_attachments = true})
			} else if mode == 1 {
				process_move_task(sender, {conv_id = 0, task_id = a, status = .Done})
			} else {
				done := task_unblock_test_status_patch(0, a, .Done)
				patch := task_unblock_test_status_patch(0, b, .Todo)
				ops := [2]pr.TransactionOperation{{op_type = .TaskPatch, body = done[:]}, {op_type = .TaskPatch, body = patch[:]}}
				process_apply_transaction(sender, {operations = ops[:mode - 1]})
			}
			testing.expect(t, simulation_test_commit_shards(&ctx.sim))
			for conn in ([2]^NRC_Connection{sender, peer}) {
				matches := 0
				for i in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
					payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, i))
					if !valid || pr.get_opcode(payload) != .S_TaskUpdated do continue
					attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
					updated, err := pr.parseTaskUpdated(payload, attachments[:])
					testing.expect(t, err == nil)
					if updated.task.id != b do continue
					matches += 1
					testing.expect_value(t, updated.task.blocked_by, pr.TaskID(0))
					testing.expect_value(t, updated.correlation_id, u32(0))
				}
				testing.expect_value(t, matches, 1)
			}
		}
	}
}
