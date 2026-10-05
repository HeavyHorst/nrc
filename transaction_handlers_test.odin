package main

import "core:encoding/endian"
import "core:testing"

import pr "protocol"
import ws "websocket"

@(test)
test_oversized_cascade_deletes_reject_without_storage_failure :: proc(t: ^testing.T) {
	workspace := "oversized-cascade"
	if !init_room_mapping_test_state("oversized_cascade.log", workspace) {
		testing.expect(t, false, "initialize cascade fixture")
		return
	}
	defer cleanup_room_mapping_test_state()
	server: NRC_Server
	previous_server := td.server
	td.server = &server
	persistent_mutation_failure_seen = false
	defer {td.server = previous_server; persistent_mutation_failure_seen = false}
	c := make_room_mapping_test_connection(workspace)
	c.state = .Idle
	c.is_sending = true
	defer send_queue_destroy(&c)
	workspace_state := get_or_create_connection_workspace(&c)
	conv := get_or_create_conversation(workspace_state, pr.WORKSPACE_DATA_ID)
	asset := alloc_asset(nil, nil, nil, nil)
	asset.asset_id = 1; asset.asset_type = .File; asset.conv_id = pr.WORKSPACE_DATA_ID
	asset_store_put(workspace_state, workspace, conv, asset)
	task := alloc_task(nil, nil, nil, nil, nil, nil, nil, nil)
	task.id = 1; task.status = .Backlog; task.conv_id = pr.WORKSPACE_DATA_ID
	task_store_put(conv, task)
	for i in 0 ..< SHARD_TRANSACTION_MAX_MUTATIONS {
		edge := alloc_edge(nil)
		edge.edge_id = pr.EdgeID(i + 1); edge.conv_id = pr.WORKSPACE_DATA_ID
		edge.source_type = .Asset; edge.source_id = 1
		edge.target_type = .Task; edge.target_id = 1; edge.relation = .RelatedTo
		edge_store_put(conv, edge)
	}
	// Each root plus its edges exceeds the mutation bound by exactly one.
	for mode in 0 ..< 4 {
		if mode == 0 {
			handle_delete_asset(&c, {conv_id = pr.WORKSPACE_DATA_ID, asset_id = 1})
		} else if mode == 1 {
			process_delete_task(&c, {conv_id = pr.WORKSPACE_DATA_ID, task_id = 1})
		} else {
			typ := mode == 2 ? pr.TransactionEntityType.Asset : pr.TransactionEntityType.Task
			body := transaction_test_delete_body(pr.WORKSPACE_DATA_ID, typ, 1)
			ops := [1]pr.TransactionOperation{{op_type = mode == 2 ? .AssetDelete : .TaskDelete, body = body[:]}}
			process_apply_transaction(&c, {operations = ops[:]})
		}
		testing.expect(
			t,
			!server.closing && !server.fatal_storage_error && !persistent_mutation_failure_seen,
			"oversized request must not shut down the server",
		)
		testing.expect(t, conv.assets[1] == asset && conv.tasks[1] == task, "rejection preserves root records")
		testing.expect_value(t, len(conv.edges), SHARD_TRANSACTION_MAX_MUTATIONS)
		testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, u64(0))
		testing.expect_value(t, send_queue_len(&c), 1)
		if item := send_queue_peek(&c); item != nil {
			frame := frame_lease_data(item.lease)
			_, header_size, frame_err := ws.readFrameHeader(frame)
			testing.expect_value(t, frame_err, nil)
			payload := frame[header_size:]
			if mode == 0 {
				response, err := pr.parseErrorResponseMessage(payload)
				testing.expect_value(t, err, nil)
				testing.expect_value(t, string(response.error_msg), "Asset deletion exceeds atomic transaction size limit")
			} else if mode == 1 {
				response, err := pr.parseTaskListResponse(payload, nil, nil)
				testing.expect_value(t, err, nil)
				testing.expect(t, !response.success)
				testing.expect_value(t, string(response.error), "Task deletion exceeds atomic transaction size limit")
			} else {
				testing.expect_value(t, pr.get_opcode(payload), pr.Opcode.S_TransactionResult)
				testing.expect_value(t, payload[3], u8(pr.TransactionResultStatus.Rejected))
			}
		}
		send_queue_drain(&c)
	}
}

@(test)
test_asset_and_edge_mutations_exceed_former_workspace_limits :: proc(t: ^testing.T) {
	workspace := "record-counts-without-quotas"
	if !init_room_mapping_test_state("record_counts_without_quotas.log", workspace) {
		testing.expect(t, false, "initialize record-count fixture")
		return
	}
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	ws := get_or_create_connection_workspace(&c)
	conv := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
	for i in 0 ..< 10_000 {
		asset := alloc_asset(nil, nil, nil, nil)
		asset.asset_id = pr.AssetID(i + 1)
		asset.conv_id = pr.WORKSPACE_DATA_ID
		asset.asset_type = .File
		asset_store_put(ws, workspace, conv, asset)
	}
	td.asset_seq = 10_000
	asset_handler_test_create(&c, pr.WORKSPACE_DATA_ID, .File, .None, 0, "new file", "")
	testing.expect_value(t, len(conv.assets), 10_001)
	testing.expect(t, conv.assets[10_001] != nil, "standalone asset creation exceeds former quota")
	handle_create_asset(&c, pr.CreateAssetRequest{conv_id = pr.WORKSPACE_DATA_ID, asset_type = .RoomMapping, preview = transmute([]byte)string("UNBOUNDED")})
	testing.expect_value(t, len(conv.assets), 10_002)
	testing.expect(t, conv.assets[10_002] != nil && conv.assets[10_002].asset_type == .RoomMapping, "room creation exceeds former asset quota")
	for i in 0 ..< 50_000 {
		edge := alloc_edge(nil)
		edge.edge_id = pr.EdgeID(i + 1)
		edge.conv_id = pr.WORKSPACE_DATA_ID
		edge.source_type = .Asset
		edge.source_id = 1
		edge.target_type = .Asset
		edge.target_id = 2
		edge.relation = .RelatedTo
		edge_store_put(conv, edge)
	}
	td.edge_seq = 50_000
	handle_create_edge(
		&c,
		pr.CreateEdgeRequest{conv_id = pr.WORKSPACE_DATA_ID, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 2, relation = .RelatedTo},
	)
	testing.expect_value(t, len(conv.edges), 50_001)
	testing.expect(t, conv.edges[50_001] != nil, "standalone edge creation exceeds former quota")
	asset_body: [21]byte
	endian.put_u64(asset_body[:], .Big, u64(pr.WORKSPACE_DATA_ID))
	endian.put_u16(asset_body[8:], .Big, u16(pr.AssetType.File))
	edge_body: [34]byte
	endian.put_u64(edge_body[:], .Big, u64(pr.WORKSPACE_DATA_ID))
	transaction_test_ref(edge_body[8:], .Existing, .Asset, 1)
	transaction_test_ref(edge_body[20:], .Existing, .Asset, 2)
	endian.put_u16(edge_body[32:], .Big, u16(pr.RelationType.RelatedTo))
	ops := [2]pr.TransactionOperation{{op_type = .AssetCreate, body = asset_body[:]}, {op_type = .EdgeCreate, body = edge_body[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{operations = ops[:]})
	testing.expect_value(t, len(conv.assets), 10_003)
	testing.expect_value(t, len(conv.edges), 50_002)
	testing.expect(t, conv.assets[10_003] != nil && conv.edges[50_002] != nil, "transaction creation exceeds both former quotas")
	testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, u64(4))
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

@(test)
test_transaction_stages_only_new_conversations :: proc(t: ^testing.T) {
	workspace := "transaction-stage-cleanup-test"
	testing.expect(t, init_room_mapping_test_state("transaction_stage_cleanup.log", workspace), "initialize transaction fixture")
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	ws := get_or_create_connection_workspace(&c)
	_ = get_or_create_conversation(ws, 70)
	p := Transaction_Prepared{}
	testing.expect(t, transaction_stage_add(&p, ws, 70), "stage existing conversation")
	testing.expect_value(t, len(p.stages), 0)
	testing.expect(t, transaction_stage_add(&p, ws, 71), "stage new conversation")
	testing.expect_value(t, len(p.stages), 1)
	testing.expect(t, get_conversation(ws, 71) == nil, "preparation must not publish new conversation")
	transaction_cleanup(&p)
}

@(test)
test_transaction_created_by_operation_zero_blocker_is_retained :: proc(t: ^testing.T) {
	workspace := "transaction-created-by-zero-test"
	testing.expect(t, init_room_mapping_test_state("transaction_created_by_zero.log", workspace), "initialize transaction fixture")
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	td.task_seq = 0
	first := transaction_test_task_create_body(70, .Existing, 0, 'a')
	second := transaction_test_task_create_body(70, .CreatedBy, 0, 'b')
	ops := [2]pr.TransactionOperation{{op_type = .TaskCreate, body = first[:]}, {op_type = .TaskCreate, body = second[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 9, operations = ops[:]})
	conv := get_conversation(get_connection_workspace(&c), 70)
	testing.expect(t, conv != nil && len(conv.tasks) == 2, "transaction creates both tasks")
	if conv != nil && len(conv.tasks) == 2 {
		testing.expect_value(t, conv.tasks[2].blocked_by, pr.TaskID(1))
	}
}

@(test)
test_transaction_patches_preserve_omitted_fields_and_rejection_is_atomic :: proc(t: ^testing.T) {
	workspace := "transaction-patch-test"
	testing.expect(t, init_room_mapping_test_state("transaction_patch.log", workspace), "initialize transaction fixture")
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace); defer send_queue_destroy(&c)
	td.task_seq = 10; td.asset_seq = 20
	ws := get_or_create_connection_workspace(&c); conv := get_or_create_conversation(ws, 71)
	task := alloc_task(
		transmute([]byte)string("kept title"),
		transmute([]byte)string("old description"),
		nil,
		transmute([]byte)string("owner"),
		nil,
		nil,
		nil,
		nil,
	)
	task.id = 10; task.conv_id = 71; task.status = .Backlog; task.color = .None; task.created_at = 10; task.updated_at = 20; conv.tasks[10] = task; index_task(conv, task)
	asset := alloc_asset(transmute([]byte)string("owner"), transmute([]byte)string("old preview"), transmute([]byte)string("kept payload"), nil)
	asset.asset_id = 20; asset.conv_id = 71; asset.asset_type = .Note; asset.payload_encoding = .Plain; asset.payload_raw_len = 12; asset.created_at = 10; asset.updated_at = 20; conv.assets[20] = asset; index_note_asset(conv, asset)
	task_body: [47]byte; endian.put_u64(task_body[:], .Big, 71); transaction_test_ref(task_body[8:], .Existing, .Task, 10); endian.put_u64(task_body[20:], .Big, 20); endian.put_u16(task_body[28:], .Big, pr.TRANSACTION_TASK_PATCH_DESCRIPTION); endian.put_u16(task_body[30:], .Big, 15); copy(task_body[32:], transmute([]byte)string("new description"))
	asset_body: [42]byte; endian.put_u64(asset_body[:], .Big, 71); transaction_test_ref(asset_body[8:], .Existing, .Asset, 20); endian.put_u64(asset_body[20:], .Big, 20); asset_body[28] = pr.TRANSACTION_ASSET_PATCH_PREVIEW; endian.put_u16(asset_body[29:], .Big, 11); copy(asset_body[31:], transmute([]byte)string("new preview"))
	ops := [2]pr.TransactionOperation{{op_type = .TaskPatch, body = task_body[:]}, {op_type = .AssetPatch, body = asset_body[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 1, operations = ops[:]})
	testing.expect(
		t,
		string(conv.tasks[10].title) == "kept title" && string(conv.tasks[10].description) == "new description" && conv.tasks[10].updated_at > 20,
		"task patch keeps omitted fields and advances time",
	)
	testing.expect(
		t,
		string(conv.assets[20].preview) == "new preview" && string(conv.assets[20].payload) == "kept payload" && conv.assets[20].updated_at > 20,
		"asset patch keeps omitted fields and advances time",
	)
	before_seq := td.task_seq; before_task := conv.tasks[10]
	// The original timestamp is stale after the committed patch.
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 2, operations = ops[:1]})
	testing.expect(t, td.task_seq == before_seq && conv.tasks[10] == before_task, "stale patch leaves sequence and live state unchanged")
}

@(test)
test_transaction_mixed_delete_deduplicates_cascade :: proc(t: ^testing.T) {
	workspace := "transaction-delete-test"
	testing.expect(t, init_room_mapping_test_state("transaction_delete.log", workspace), "initialize transaction fixture")
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace); defer send_queue_destroy(&c)
	td.task_seq = 1; td.asset_seq = 2; td.edge_seq = 3
	ws := get_or_create_connection_workspace(&c); conv := get_or_create_conversation(ws, 72)
	task := alloc_task(
		transmute([]byte)string("task"),
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
	); task.id = 1; task.conv_id = 72; task.status = .Backlog; task.color = .None; task.updated_at = 30; conv.tasks[1] = task; index_task(conv, task)
	asset := alloc_asset(
		nil,
		nil,
		nil,
		nil,
	); asset.asset_id = 2; asset.conv_id = 72; asset.asset_type = .Note; asset.parent_type = .Task; asset.parent_id = 1; asset.payload_encoding = .Plain; asset.updated_at = 40; conv.assets[2] = asset; index_note_asset(conv, asset)
	edge := alloc_edge(
		nil,
	); edge.edge_id = 3; edge.conv_id = 72; edge.source_type = .Task; edge.source_id = 1; edge.target_type = .Asset; edge.target_id = 2; edge.relation = .RelatedTo; conv.edges[3] = edge; add_edge_to_adjacency(conv, .Task, 1, 3); add_edge_to_adjacency(conv, .Asset, 2, 3)
	task_delete := transaction_test_delete_body(72, .Task, 1, 30); asset_delete := transaction_test_delete_body(72, .Asset, 2, 40)
	ops := [2]pr.TransactionOperation{{op_type = .TaskDelete, body = task_delete[:]}, {op_type = .AssetDelete, body = asset_delete[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 3, operations = ops[:]})
	testing.expect(t, len(conv.tasks) == 0 && len(conv.assets) == 0 && len(conv.edges) == 0, "mixed explicit deletes install one deduplicated cascade")
}

@(test)
test_transaction_stale_delete_rejects_whole_transaction :: proc(t: ^testing.T) {
	workspace := "transaction-delete-cas-test"
	testing.expect(t, init_room_mapping_test_state("transaction_delete_cas.log", workspace), "initialize transaction fixture")
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace); defer send_queue_destroy(&c)
	td.task_seq = 1
	ws := get_or_create_connection_workspace(&c); conv := get_or_create_conversation(ws, 73)
	task := alloc_task(transmute([]byte)string("kept"), nil, nil, nil, nil, nil, nil, nil)
	task.id = 1; task.conv_id = 73; task.status = .Backlog; task.color = .None; task.updated_at = 50; conv.tasks[1] = task; index_task(conv, task)
	create := transaction_test_task_create_body(73, .Existing, 0, 'x')
	stale_delete := transaction_test_delete_body(73, .Task, 1, 49)
	ops := [2]pr.TransactionOperation{{op_type = .TaskCreate, body = create[:]}, {op_type = .TaskDelete, body = stale_delete[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 4, operations = ops[:]})
	testing.expect(t, td.task_seq == 1 && len(conv.tasks) == 1 && conv.tasks[1] == task, "stale delete rejects create and delete atomically")
}
