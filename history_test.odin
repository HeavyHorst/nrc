package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "persistence"
import pr "protocol"
import ws "websocket"

history_test_read :: proc(t: ^testing.T, c: ^NRC_Connection, kind: u8, entity, before: u64, limit: u16 = 100) -> []byte {
	send_queue_drain(c)
	request: [33]byte
	endian.put_u16(request[:], .Big, u16(pr.Opcode.C_ListHistory))
	request[10] = kind; endian.put_u64(request[11:], .Big, entity)
	endian.put_u64(request[19:], .Big, before); endian.put_u16(request[27:], .Big, limit); endian.put_u32(request[29:], .Big, 123)
	process_protocol_payload(c, request[:])
	item := send_queue_peek(c)
	if !testing.expect(t, item != nil) do return nil
	frame := frame_lease_data(item.lease)
	_, header, err := ws.readFrameHeader(frame)
	if !testing.expect(t, err == nil) do return nil
	response := frame[header:]
	testing.expect_value(t, pr.get_opcode(response), pr.Opcode.S_HistoryPage)
	correlation, _ := endian.get_u32(response[2:], .Big)
	testing.expect_value(t, correlation, u32(123))
	owned := make([]byte, len(response) - 6); copy(owned, response[6:])
	return owned
}

@(test)
test_history_wire_actor_fields_pagination_durability_and_checkpoint :: proc(t: ^testing.T) {
	workspace := "history-public-contract"
	if !testing.expect(t, init_room_mapping_test_state("history_contract.log", workspace)) do return
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0
	c := make_room_mapping_test_connection(workspace)
	c.verified_subject = "subject-123"; c.verified_username = "Alice Display"
	c.state = .Idle; c.is_sending = true
	defer send_queue_destroy(&c)
	req := pr.CreateTaskRequest {
		title       = transmute([]byte)string("secret title"),
		description = transmute([]byte)string("secret body"),
	}
	frame := make([]byte, pr.getSizeCreateTaskRequest(req)); defer delete(frame)
	pr.serializeCreateTaskRequest(req, frame)
	process_protocol_payload(&c, frame)
	state := get_workspace(workspace)
	if !testing.expect(t, state != nil && len(state.history) == 1) do return
	data := string(state.history[0][HISTORY_HEADER_SIZE:])
	testing.expect(t, strings.contains(data, `"actorId":"subject-123"`) && strings.contains(data, `"actorName":"Alice Display"`))
	testing.expect(
		t,
		strings.contains(data, `"entityLabel":"secret title"`) && !strings.contains(data, "secret body"),
		"only the identifying title, never the body, is retained",
	)
	page := history_test_read(t, &c, 0, 0, 0)
	testing.expect(t, strings.contains(string(page), "durability pending")); delete(page)
	page = history_test_read(t, &c, 0, 0, 0, 0)
	// A rejected filter keeps its own message while durability is pending:
	// retrying a malformed request cannot succeed, so the durability hint must not
	// hide the real problem.
	testing.expect(t, strings.contains(string(page), "Invalid history filter or limit"))
	testing.expect(t, !strings.contains(string(page), "durability pending")); delete(page)
	conv := get_conversation(state, 0)
	previous_dispatch := shard_protocol_dispatch_context
	shard_protocol_dispatch_context.connection = &c
	defer {shard_protocol_dispatch_context = previous_dispatch}
	process_move_task(&c, {task_id = 1, status = .Todo, order_index = 9})
	if !testing.expect_value(t, len(state.history), 2) do return
	testing.expect(t, strings.contains(string(state.history[1][HISTORY_HEADER_SIZE:]), `"fields":["status","order_index"]`))
	process_move_task(&c, {task_id = 1, status = .Todo, order_index = 9})
	testing.expect_value(t, len(state.history), 2) // No-op timestamp changes do not fabricate edits.
	process_delete_task(&c, {task_id = 99})
	testing.expect_value(t, len(state.history), 2)
	process_delete_task(&c, {task_id = 1})
	testing.expect(t, conv.tasks[1] == nil && len(state.history) == 3)
	writer := &td.shard_writers.writers[0]
	persistence.force_fsync(&writer.wal); writer.commit_pending = false
	page = history_test_read(t, &c, 1, 1, 0, 1)
	testing.expect(t, strings.contains(string(page), `"action":"deleted"`) && strings.contains(string(page), `"nextBefore":"3"`)); delete(page)
	page = history_test_read(t, &c, 1, 1, 3, 100)
	testing.expect(t, !strings.contains(string(page), `"action":"deleted"`) && strings.contains(string(page), `"nextBefore":"0"`)); delete(page)
	page = history_test_read(t, &c, 0, 0, 0, 0)
	testing.expect(t, strings.contains(string(page), `"error":`)); delete(page)
	c.authenticated = false
	page = history_test_read(t, &c, 0, 0, 0)
	testing.expect(t, strings.contains(string(page), "Authentication required")); delete(page)
	c.authenticated = true
	c.workspace_id = "another-workspace"; c.workspace = nil
	page = history_test_read(t, &c, 0, 0, 0)
	testing.expect_value(t, string(page), `{"events":[],"nextBefore":"0"}`); delete(page)
	c.workspace_id = workspace
	checkpoint := test_wal_path("history_checkpoint.log"); defer os.remove(checkpoint)
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	digest := shard_checkpoint_state_digest(shard)
	testing.expect(t, build_shard_checkpoint_from_replayed_state(checkpoint, shard, writer.floors))
	shutdown_shard_writer_registry(&td.shard_writers)
	cleanup_workspaces(); td.workspaces = make(map[string]^Workspace_State, 256)
	inspection, _, replay_ok := scan_shard_transaction_wal(checkpoint, shard, {}, true, true)
	testing.expectf(
		t,
		replay_ok && shard_checkpoint_state_digest(shard) == digest,
		"checkpoint retains history after entity deletion: replay=%v inspection=%v",
		replay_ok,
		inspection,
	)
	state = get_workspace(workspace)
	if !testing.expectf(t, state != nil && len(state.history) == 3, "history length after checkpoint: %d", state == nil ? -1 : len(state.history)) do return
	arena: virtual.Arena; assert(virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	event: History_Event
	testing.expect(t, json.unmarshal(state.history[0][HISTORY_HEADER_SIZE:], &event, allocator = virtual.arena_allocator(&arena)) == nil)
	testing.expect(t, event.timestamp != "0" && len(event.timestamp) >= 19)
	testing.expect_value(t, event.entity_label, "secret title")
}

@(test)
test_history_batch_unblock_cascade_endpoints_and_failed_append :: proc(t: ^testing.T) {
	workspace := "history-cascades"
	if !testing.expect(t, init_room_mapping_test_state("history_cascades.log", workspace)) do return
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0; td.asset_seq = 0; td.edge_seq = 0
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	c.verified_subject = "subject-cascade"
	previous := shard_protocol_dispatch_context
	shard_protocol_dispatch_context.connection = &c
	defer {shard_protocol_dispatch_context = previous}
	state := get_or_create_connection_workspace(&c)
	conv := get_or_create_conversation(state, 0)
	task_unblock_test_seed(t, workspace, conv, 0, 1, 0)
	task_unblock_test_seed(t, workspace, conv, 0, 2, 1)
	writer := &td.shard_writers.writers[0]
	before_records := writer.wal.record_count
	patch := task_unblock_test_status_patch(0, 1, .Done)
	ops := [1]pr.TransactionOperation{{op_type = .TaskPatch, body = patch[:]}}
	process_apply_transaction(&c, {operations = ops[:]})
	testing.expect_value(t, writer.wal.record_count, before_records + 1)
	if !testing.expect_value(t, len(state.history), 4) do return
	page := history_page_json(state, 1, 2, 0, 100)
	testing.expect(t, strings.contains(string(page), `"actorId":"system"`) && strings.contains(string(page), `"fields":["blocked_by"]`)); delete(page)
	// A user patch and automatic unblock on the same record retain distinct
	// actors and disjoint field lists, without duplicating entity WAL writes.
	task_unblock_test_seed(t, workspace, conv, 0, 3, 2)
	done := task_unblock_test_status_patch(0, 2, .Done)
	dependent := task_unblock_test_status_patch(0, 3, .Todo)
	mixed := [2]pr.TransactionOperation{{op_type = .TaskPatch, body = done[:]}, {op_type = .TaskPatch, body = dependent[:]}}
	mixed_before := len(state.history)
	process_apply_transaction(&c, {operations = mixed[:]})
	testing.expect_value(t, len(state.history), mixed_before + 3)
	page = history_page_json(state, 1, 3, 0, 100)
	testing.expect(
		t,
		strings.contains(string(page), `"actorId":"subject-cascade"`) &&
		strings.contains(string(page), `"fields":["status"]`) &&
		strings.contains(string(page), `"fields":["blocked_by"]`),
	); delete(page)
	handle_create_asset(
		&c,
		{
			asset_type = .Document,
			parent_type = .Task,
			parent_id = 1,
			preview = transmute([]byte)string("private preview"),
			payload = transmute([]byte)string("private payload"),
			payload_raw_len = 15,
		},
	)
	handle_update_asset(
		&c,
		{asset_id = 1, preview = transmute([]byte)string("changed preview"), payload = transmute([]byte)string("private payload"), payload_raw_len = 15},
	)
	testing.expect(t, strings.contains(string(state.history[len(state.history) - 1][HISTORY_HEADER_SIZE:]), `"fields":["preview"]`))
	handle_create_edge(&c, {source_type = .Task, source_id = 1, target_type = .Asset, target_id = 1, relation = .RelatedTo})
	if !testing.expect(t, len(conv.edges) == 1 && len(conv.assets) == 1) do return
	before_records = writer.wal.record_count
	process_delete_task(&c, {task_id = 1})
	testing.expect_value(t, writer.wal.record_count, before_records + 1)
	testing.expect(t, len(conv.edges) == 0 && len(conv.assets) == 0 && conv.tasks[1] == nil)
	page = history_page_json(state, 2, 1, 0, 100)
	testing.expect(
		t,
		strings.contains(string(page), `"entityType":"edge"`) &&
		strings.contains(string(page), `"sourceId":"1"`) &&
		strings.contains(string(page), `"targetType":"asset"`),
	)
	testing.expect(t, !strings.contains(string(page), "private")); delete(page)
	before := len(state.history)
	old_failure := persistent_mutation_failure_seen
	defer {persistent_mutation_failure_seen = old_failure}
	writer.poisoned = true
	old_logger := context.logger
	context.logger = log.nil_logger()
	process_move_task(&c, {task_id = 2, status = .Todo})
	context.logger = old_logger
	testing.expect_value(t, len(state.history), before)
	writer.poisoned = false
}

@(test)
test_history_personal_reminder_visibility_survives_deletion_and_checkpoint :: proc(t: ^testing.T) {
	workspace := "history-private"
	if !testing.expect(t, init_room_mapping_test_state("history_private.log", workspace)) do return
	defer cleanup_room_mapping_test_state()
	td.asset_seq = 0
	c := make_room_mapping_test_connection(workspace)
	c.verified_username = "Alice"; c.verified_subject = "alice-subject"
	c.state = .Idle; c.is_sending = true
	defer send_queue_destroy(&c)
	previous := shard_protocol_dispatch_context
	shard_protocol_dispatch_context.connection = &c
	defer {shard_protocol_dispatch_context = previous}
	team := transmute([]byte)string(`{"visibility":"team"}`)
	personal := transmute([]byte)string(`{"visibility":"personal"}`)
	edited := transmute([]byte)string(`{"visibility":"personal","title":"private"}`)
	// Public events surround private events, testing filtering before limit/cursor.
	handle_create_asset(&c, {asset_type = .Reminder, preview = team, payload = team, payload_raw_len = u32(len(team))})
	handle_create_asset(&c, {asset_type = .Reminder, preview = personal, payload = personal, payload_raw_len = u32(len(personal))})
	handle_update_asset(&c, {asset_id = 2, preview = edited, payload = edited, payload_raw_len = u32(len(edited))})
	handle_delete_asset(&c, {asset_id = 2})
	handle_create_asset(&c, {asset_type = .Reminder, preview = team, payload = team, payload_raw_len = u32(len(team))})
	writer := &td.shard_writers.writers[0]
	persistence.force_fsync(&writer.wal); writer.commit_pending = false
	if !testing.expect_value(t, len(get_workspace(workspace).history), 5) do return
	shard := writer.shard
	checkpoint := test_wal_path("history_private_checkpoint.log"); defer os.remove(checkpoint)
	floors := writer.floors
	for stage in 0 ..< 3 {
		c.verified_username = "Alice"; c.workspace = nil
		page := history_test_read(t, &c, 2, 2, 0)
		testing.expect(
			t,
			strings.contains(string(page), `"action":"created"`) &&
			strings.contains(string(page), `"action":"updated"`) &&
			strings.contains(string(page), `"action":"deleted"`),
		)
		testing.expect(
			t,
			strings.contains(string(page), `"entityLabel":"private"`) && !strings.contains(string(page), "visibility"),
			"private names stay owner-only, ACL metadata is not public JSON",
		); delete(page)
		c.verified_username = "Bob"
		page = history_test_read(t, &c, 2, 2, 0)
		testing.expect_value(t, string(page), `{"events":[],"nextBefore":"0"}`); delete(page)
		page = history_test_read(t, &c, 0, 0, 0, 1)
		testing.expect(t, strings.contains(string(page), `"entityId":"3"`) && strings.contains(string(page), `"nextBefore":"5"`)); delete(page)
		page = history_test_read(t, &c, 0, 0, 5, 1)
		testing.expect(t, strings.contains(string(page), `"entityId":"1"`) && strings.contains(string(page), `"nextBefore":"0"`)); delete(page)
		if stage == 2 do break
		path := room_mapping_test_wal_path
		if stage == 0 {
			shutdown_shard_writer_registry(&td.shard_writers)
		} else {
			testing.expect(t, build_shard_checkpoint_from_replayed_state(checkpoint, shard, floors))
			path = checkpoint
		}
		cleanup_workspaces(); td.workspaces = make(map[string]^Workspace_State, 256)
		_, _, ok := scan_shard_transaction_wal(path, shard, {}, true, true)
		testing.expect(t, ok)
	}
}

@(test)
test_history_created_task_automatic_unblock_is_system_update :: proc(t: ^testing.T) {
	for reverse in ([2]bool{false, true}) {
		workspace := "history-created-unblock"
		if !testing.expect(t, init_room_mapping_test_state("history_created_unblock.log", workspace)) do return
		td.task_seq = 0
		c := make_room_mapping_test_connection(workspace)
		c.verified_subject = "creator-subject"
		previous := shard_protocol_dispatch_context
		shard_protocol_dispatch_context.connection = &c
		conv := get_or_create_conversation(get_or_create_connection_workspace(&c), 0)
		task_unblock_test_seed(t, workspace, conv, 0, 1, 0)
		done := task_unblock_test_status_patch(0, 1, .Done)
		create := transaction_test_task_create_body(0, .Existing, 1, 'n')
		ops := [2]pr.TransactionOperation{{op_type = .TaskPatch, body = done[:]}, {op_type = .TaskCreate, body = create[:]}}
		if reverse do ops[0], ops[1] = ops[1], ops[0]
		process_apply_transaction(&c, {operations = ops[:]})
		page := history_page_json(get_workspace(workspace), 1, 2, 0, 100)
		arena: virtual.Arena; assert(virtual.arena_init_growing(&arena) == nil)
		result: struct {
			events:     []History_Event,
			nextBefore: string,
		}
		testing.expect(t, json.unmarshal(page, &result, allocator = virtual.arena_allocator(&arena)) == nil)
		if testing.expect_value(t, len(result.events), 2) {
			testing.expect_value(t, result.events[0].actor_id, "system")
			testing.expect_value(t, result.events[0].action, "updated")
			testing.expect(t, len(result.events[0].fields) == 1 && result.events[0].fields[0] == "blocked_by")
			testing.expect_value(t, result.events[1].actor_id, "creator-subject")
			testing.expect_value(t, result.events[1].action, "created")
			for field in result.events[1].fields do testing.expect(t, field != "blocked_by")
		}
		virtual.arena_destroy(&arena); delete(page)
		shard_protocol_dispatch_context = previous
		send_queue_destroy(&c)
		cleanup_room_mapping_test_state()
	}
}

@(test)
test_history_names_survive_rename_link_cascade_and_restart :: proc(t: ^testing.T) {
	workspace := "history-names"
	if !testing.expect(t, init_room_mapping_test_state("history_names.log", workspace)) do return
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0; td.asset_seq = 0; td.edge_seq = 0
	c := make_room_mapping_test_connection(workspace); defer send_queue_destroy(&c)
	process_create_task(&c, {title = transmute([]byte)string("Website relaunch")})
	preview := transmute([]byte)string(`{"title":"Meeting \"notes\"","teaser":"private excerpt"}`)
	content := transmute([]byte)string("private document body")
	handle_create_asset(
		&c,
		{asset_type = .Note, parent_type = .Task, parent_id = 1, preview = preview, payload = content, payload_raw_len = u32(len(content))},
	)
	handle_create_edge(&c, {source_type = .Asset, source_id = 1, target_type = .Task, target_id = 1, relation = .RelatedTo})
	state := get_workspace(workspace)
	page := history_page_json(state, 0, 0, 0, 100)
	testing.expect(
		t,
		strings.contains(string(page), `"sourceLabel":"Meeting \"notes\""`) && strings.contains(string(page), `"targetLabel":"Website relaunch"`),
	)
	testing.expect(t, strings.contains(string(page), `"sourceAvailable":true`) && strings.contains(string(page), `"entityAvailable":true`))
	testing.expect(t, !strings.contains(string(page), "private")); delete(page)
	// A multibyte label is bounded at a complete character, independently of body length.
	long_title := strings.repeat("界", 90); defer delete(long_title)
	long_preview := strings.concatenate({`{"title":"`, long_title, `"}`}); defer delete(long_preview)
	handle_update_asset(&c, {asset_id = 1, preview = transmute([]byte)long_preview, payload = content, payload_raw_len = u32(len(content))})
	process_delete_task(&c, {task_id = 1})
	expected_title := strings.repeat("界", 85); defer delete(expected_title)
	shard := td.shard_writers.writers[0].shard
	shutdown_shard_writer_registry(&td.shard_writers)
	cleanup_workspaces(); td.workspaces = make(map[string]^Workspace_State, 256)
	_, _, replay_ok := scan_shard_transaction_wal(room_mapping_test_wal_path, shard, {}, true, true)
	testing.expect(t, replay_ok)
	state = get_workspace(workspace)
	page = history_page_json(state, 2, 1, 0, 100)
	defer delete(page)
	arena: virtual.Arena; assert(virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	result: struct {
		events:     []History_Event,
		nextBefore: string,
	}
	testing.expect(t, json.unmarshal(page, &result, allocator = virtual.arena_allocator(&arena)) == nil)
	created, deleted, unlinked := false, false, false
	for event in result.events {
		testing.expect(t, !event.entity_available && !event.source_available && !event.target_available)
		if event.entity_type == "asset" && event.action == "created" {
			created = true; testing.expect_value(t, event.entity_label, "Meeting \"notes\"")
		}
		if event.entity_type == "asset" && event.action == "deleted" {
			deleted = true; testing.expect_value(t, event.entity_label, expected_title)
		}
		if event.entity_type == "edge" && event.action == "deleted" {
			unlinked = true; testing.expect_value(t, event.source_label, expected_title)
			testing.expect_value(t, event.target_label, "Website relaunch")
			testing.expect_value(t, event.source_asset_type, u16(pr.AssetType.Note))
		}
	}
	testing.expect(t, created && deleted && unlinked)
	testing.expect(t, !strings.contains(string(page), "private"))
}

@(test)
test_history_segment_catalog_publication_restart :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("history-segments")
	defer os.remove_all(data_dir)
	if !testing.expect(t, storage_layout_test_create_generation(data_dir, 1)) do return
	workspace := "history-segments"
	if !testing.expect(t, init_room_mapping_test_state("history_segments.log", workspace)) do return
	defer cleanup_room_mapping_test_state()
	writer := &td.shard_writers.writers[0]
	shard := writer.shard
	generation_dir := sharded_generation_path(data_dir, 1); defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)
	shutdown_shard_transaction_writer(writer); writer^ = {}
	if !testing.expect(t, init_managed_shard_transaction_writer(writer, shard_dir, shard, 0, 1)) do return
	c := make_room_mapping_test_connection(workspace); defer send_queue_destroy(&c)
	td.task_seq = 0
	process_create_task(&c, {title = transmute([]byte)string("not an audit value")})
	process_move_task(&c, {task_id = 1, status = .Todo})
	process_delete_task(&c, {task_id = 1})
	state := get_workspace(workspace)
	if !testing.expect(t, state != nil && len(state.history) == 3) do return
	digest := shard_checkpoint_state_digest(shard)
	testing.expect(t, rotate_shard_writer_for_compaction(writer))
	result := shard_compaction_test_build_result(writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	if !testing.expect(t, result.ok && publish_shard_compaction_result(writer, result)) do return
	manifest := writer.manifest
	shutdown_shard_writer_registry(&td.shard_writers)
	cleanup_workspaces(); td.workspaces = make(map[string]^Workspace_State, 256)
	_, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
	testing.expect(t, replay_ok && shard_checkpoint_state_digest(shard) == digest)
	state = get_workspace(workspace)
	testing.expect(t, state != nil && len(state.history) == 3)
}

@(test)
test_history_malformed_titles_and_nonobject_previews :: proc(t: ^testing.T) {
	workspace := "history-label-inputs"
	if !testing.expect(t, init_room_mapping_test_state("history_label_inputs.log", workspace)) do return
	defer cleanup_room_mapping_test_state()
	td.task_seq = 0; td.asset_seq = 0; td.edge_seq = 0
	c := make_room_mapping_test_connection(workspace); defer send_queue_destroy(&c)
	request := pr.CreateTaskRequest {
		title = []byte{'A', 0xff, 'B'},
	}
	frame := make([]byte, pr.getSizeCreateTaskRequest(request)); defer delete(frame)
	pr.serializeCreateTaskRequest(request, frame)
	process_protocol_payload(&c, frame)
	state := get_workspace(workspace)
	if !testing.expect(t, state != nil && len(state.history) == 1) do return
	previews := []string{`[{"teaser":"private-array","n":9223372036854775808}]`, `"private-scalar"`, "Legacy title"}
	for preview in previews {
		handle_create_asset(&c, {asset_type = .Note, preview = transmute([]byte)preview})
	}
	handle_create_edge(&c, {source_type = .Asset, source_id = 1, target_type = .Task, target_id = 1, relation = .RelatedTo})
	handle_create_edge(&c, {source_type = .Asset, source_id = 3, target_type = .Task, target_id = 1, relation = .RelatedTo})
	page := history_page_json(state, 0, 0, 0, 100)
	arena: virtual.Arena; assert(virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	result: struct {
		events:     []History_Event,
		nextBefore: string,
	}
	testing.expect(t, json.unmarshal(page, &result, allocator = virtual.arena_allocator(&arena)) == nil)
	if !testing.expect_value(t, len(result.events), 6) {delete(page); return}
	testing.expect_value(t, result.events[0].target_label, "A�B")
	testing.expect_value(t, result.events[5].entity_label, "A�B")
	testing.expect(t, !strings.contains(string(page), "private-") && strings.contains(string(page), "Legacy title"))
	delete(page)
	// Recreate the old event shape: no label or asset subtype. Read-time
	// navigation must resolve the live type without rewriting stored history.
	old := state.history[1]
	body := transmute([]byte)string(
		`{"id":"2","timestamp":"1","actorId":"system","actorName":"System","entityType":"asset","entityId":"1","action":"created","fields":[]}`,
	)
	legacy := make([]byte, HISTORY_HEADER_SIZE + len(body))
	copy(legacy, old[:HISTORY_HEADER_SIZE]); copy(legacy[HISTORY_HEADER_SIZE:], body)
	state.history[1] = legacy; delete(old)
	page = history_page_json(state, 2, 1, 0, 100)
	testing.expect(t, strings.contains(string(page), `"entityAvailable":true`) && strings.contains(string(page), `"assetType":5`))
	delete(page)
	process_delete_task(&c, {task_id = 1})
	testing.expect(t, !td.shard_writers.writers[0].poisoned)
	shard := td.shard_writers.writers[0].shard
	shutdown_shard_writer_registry(&td.shard_writers)
	cleanup_workspaces(); td.workspaces = make(map[string]^Workspace_State, 256)
	_, _, replay_ok := scan_shard_transaction_wal(room_mapping_test_wal_path, shard, {}, true, true)
	testing.expect(t, replay_ok)
	page = history_page_json(get_workspace(workspace), 1, 1, 0, 100)
	defer delete(page)
	testing.expect(t, !strings.contains(string(page), "private-"))
	testing.expect(t, json.unmarshal(page, &result, allocator = virtual.arena_allocator(&arena)) == nil)
	if !testing.expect(t, len(result.events) > 0) do return
	testing.expect_value(t, result.events[0].action, "deleted")
	testing.expect_value(t, result.events[0].entity_label, "A�B")
}
