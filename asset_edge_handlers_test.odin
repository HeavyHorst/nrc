package main

import "core:log"
import "core:mem/virtual"
import "core:testing"

import "btree"
import "persistence"
import pr "protocol"

asset_handler_test_create :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	asset_type: pr.AssetType,
	parent_type: pr.ParentType,
	parent_id: u64,
	preview, payload: string,
) {
	handle_create_asset(
		c,
		pr.CreateAssetRequest {
			conv_id = conv_id,
			asset_type = asset_type,
			parent_type = parent_type,
			parent_id = parent_id,
			payload_encoding = .Plain,
			payload_raw_len = u32(len(payload)),
			preview = transmute([]byte)preview,
			payload = transmute([]byte)payload,
		},
	)
}

asset_handler_test_expect_adjacency :: proc(t: ^testing.T, conv: ^Conversation_State, target_type: pr.TargetType, target_id: u64, edge_id: pr.EdgeID) {
	key := Edge_Entity_Key {
		target_type = target_type,
		target_id   = target_id,
	}
	edge_ids, ok := conv.edges_by_entity[key]
	testing.expect(t, ok, "edge endpoint should have an adjacency entry")
	testing.expect_value(t, len(edge_ids), 1)
	if len(edge_ids) == 1 {
		testing.expect_value(t, edge_ids[0], edge_id)
	}
}

asset_handler_test_arm_persistence_failure :: proc(c: ^NRC_Connection) {
	c.state = .Idle
	c.is_sending = true
	persistent_mutation_failure_seen = false
	persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)
}

asset_handler_test_expect_single_note_key :: proc(t: ^testing.T, conv: ^Conversation_State, asset_id: pr.AssetID) -> Note_Sort_Key {
	testing.expect_value(t, btree.count(&conv.note_index), 1)
	expected, ok := conv.note_index_keys[asset_id]
	testing.expect(t, ok, "note cursor map should contain the indexed asset")
	it := btree.iter(&conv.note_index)
	defer btree.iter_destroy(&it)
	testing.expect(t, btree.iter_first(&it), "note B-tree should contain one key")
	if btree.count(&conv.note_index) == 1 {
		testing.expect_value(t, btree.item(&it), expected)
		testing.expect(t, !btree.iter_next(&it), "note B-tree should not contain a stale key")
	}
	return expected
}

Asset_Cascade_WAL_Inspection :: struct {
	ok:             bool,
	candidate:      bool,
	mutation_count: int,
	asset_ids:      [3]u64,
	asset_count:    int,
	edge_ids:       [3]u64,
	edge_count:     int,
}

@(thread_local)
asset_cascade_wal_inspection: Asset_Cascade_WAL_Inspection

asset_cascade_wal_visit_mutation :: proc(mutation: Shard_Mutation, data: rawptr) -> bool {
	requirements, err := validate_shard_mutation(mutation)
	if err != .None do return false
	inspection := cast(^Asset_Cascade_WAL_Inspection)data
	inspection.mutation_count += 1
	switch mutation.domain {
	case .Asset:
		if mutation.op != u8(Asset_Log_Op.Delete) {
			inspection.candidate = false
			return true
		}
		if inspection.asset_count >= len(inspection.asset_ids) do return false
		inspection.asset_ids[inspection.asset_count] = requirements.asset
		inspection.asset_count += 1
	case .Edge:
		if mutation.op != u8(Edge_Log_Op.Delete) {
			inspection.candidate = false
			return true
		}
		if inspection.edge_count >= len(inspection.edge_ids) do return false
		inspection.edge_ids[inspection.edge_count] = requirements.edge
		inspection.edge_count += 1
	case .Task:
		inspection.candidate = false
	}
	return true
}

asset_cascade_wal_inspect_record :: proc(op: u8, version: u16, payload: []byte) -> bool {
	if op != u8(Shard_Log_Op.Transaction) || version != SHARD_WAL_VERSION do return false
	view, err := decode_shard_transaction(payload)
	if err != .None do return false
	inspection := Asset_Cascade_WAL_Inspection {
		candidate = true,
	}
	inspection.ok = visit_shard_transaction_mutations(&view, asset_cascade_wal_visit_mutation, &inspection)
	if inspection.ok && inspection.candidate {
		asset_cascade_wal_inspection = inspection
	}
	return inspection.ok
}

asset_handler_test_contains_id :: proc(ids: []u64, expected: u64) -> bool {
	for id in ids {
		if id == expected do return true
	}
	return false
}

asset_handler_test_btree_contains :: proc(conv: ^Conversation_State, expected: Note_Sort_Key) -> bool {
	it := btree.iter(&conv.note_index)
	defer btree.iter_destroy(&it)
	for has_item := btree.iter_first(&it); has_item; has_item = btree.iter_next(&it) {
		if btree.item(&it) == expected do return true
	}
	return false
}

@(test)
test_asset_handlers_keep_note_indexes_synchronized_and_replace_agenda :: proc(t: ^testing.T) {
	workspace_id := "asset-handler-indexes"
	if !init_room_mapping_test_state("asset_handler_indexes.log", workspace_id) {
		testing.expect(t, false, "asset handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.asset_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	conv_id := pr.ConversationID(61)

	asset_handler_test_create(&c, conv_id, .Note, .None, 0, `{"title":"First","project":"alpha","tags":["odin","server"]}`, "first body")

	conv := get_conversation(get_workspace(workspace_id), conv_id)
	testing.expect(t, conv != nil, "create should store the conversation")
	if conv == nil do return
	testing.expect(t, conv.assets[1] != nil, "create should store the note")
	_, indexed := conv.note_index_keys[1]
	testing.expect(t, indexed, "create should add the note ordering key")
	_ = asset_handler_test_expect_single_note_key(t, conv, 1)
	testing.expect_value(t, note_secondary_index_count(conv.note_project_assets["alpha"]), 1)
	testing.expect_value(t, note_secondary_index_count(conv.note_tag_assets["odin"]), 1)
	testing.expect_value(t, note_secondary_index_count(conv.note_tag_assets["server"]), 1)

	replacement_preview := `{"title":"First revised","project":"beta","tags":["server","graph"]}`
	handle_update_asset(
		&c,
		pr.UpdateAssetRequest {
			conv_id = conv_id,
			asset_id = 1,
			payload_encoding = .Plain,
			payload_raw_len = 12,
			preview = transmute([]byte)replacement_preview,
			payload = transmute([]byte)string("revised body"),
		},
	)
	_, has_alpha := conv.note_project_assets["alpha"]
	_, has_odin := conv.note_tag_assets["odin"]
	testing.expect(t, !has_alpha, "update should remove the old project entry")
	testing.expect(t, !has_odin, "update should remove tags absent from the replacement")
	testing.expect_value(t, note_secondary_index_count(conv.note_project_assets["beta"]), 1)
	beta_newest, beta_ok := note_secondary_index_newest(conv.note_project_assets["beta"])
	testing.expect(t, beta_ok, "beta project should contain its note")
	testing.expect_value(t, beta_newest.asset_id, pr.AssetID(1))
	testing.expect_value(t, note_secondary_index_count(conv.note_tag_assets["server"]), 1)
	testing.expect_value(t, note_secondary_index_count(conv.note_tag_assets["graph"]), 1)
	_ = asset_handler_test_expect_single_note_key(t, conv, 1)

	asset_handler_test_create(&c, conv_id, .Agenda, .None, 0, "agenda-one", "first agenda")
	testing.expect(t, conv.assets[2] != nil, "first Agenda create should store an asset")
	asset_handler_test_create(&c, conv_id, .Agenda, .None, 0, "agenda-two", "replacement agenda")
	testing.expect_value(t, len(conv.assets), 2)
	testing.expect(t, conv.assets[2] != nil, "Agenda replacement should retain the singleton ID")
	testing.expect(t, string(conv.assets[2].preview) == "agenda-two", "Agenda replacement should update content")
	testing.expect(t, string(conv.assets[2].payload) == "replacement agenda", "Agenda replacement should update payload")
	testing.expect_value(t, td.asset_seq, u64(2))

	handle_delete_asset(&c, pr.DeleteAssetRequest{conv_id = conv_id, asset_id = 1})
	testing.expect(t, conv.assets[1] == nil, "delete should remove the note")
	_, indexed = conv.note_index_keys[1]
	_, has_beta := conv.note_project_assets["beta"]
	_, has_server := conv.note_tag_assets["server"]
	_, has_graph := conv.note_tag_assets["graph"]
	testing.expect(t, !indexed && !has_beta && !has_server && !has_graph, "delete should remove every note index entry")
	testing.expect_value(t, btree.count(&conv.note_index), 0)
	testing.expect_value(t, len(conv.note_index_keys), 0)
}

// A slice is addressed by its name, so the name is validated where slices are
// written: a second slice cannot take a name that is already in use, a record
// without a usable name is refused rather than stored as an unaddressable asset,
// and an update carries the record forward instead of renaming the slice.
@(test)
test_slice_create_and_update_keep_the_name_that_identifies_it :: proc(t: ^testing.T) {
	workspace_id := "slice-name-guard"
	if !init_room_mapping_test_state("slice_name_guard.log", workspace_id) {
		testing.expect(t, false, "slice name guard test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.asset_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	conv_id := pr.ConversationID(63)

	asset_handler_test_create(&c, conv_id, .Slice, .None, 0, `{"version":1,"name":"Shard hardening"}`, "")
	conv := get_conversation(get_workspace(workspace_id), conv_id)
	testing.expect(t, conv != nil, "create should store the conversation")
	if conv == nil do return
	testing.expect(t, conv.assets[1] != nil, "a well-formed slice record is stored")
	testing.expect_value(t, len(conv.assets), 1)

	asset_handler_test_create(&c, conv_id, .Slice, .None, 0, `{"version":1,"name":"Shard hardening"}`, "")
	testing.expect_value(t, len(conv.assets), 1)
	testing.expect_value(t, td.asset_seq, u64(1))

	asset_handler_test_create(&c, conv_id, .Slice, .None, 0, `{"version":1,"name":""}`, "")
	asset_handler_test_create(&c, conv_id, .Slice, .None, 0, `not json`, "")
	testing.expect_value(t, len(conv.assets), 1)
	testing.expect_value(t, td.asset_seq, u64(1))

	handle_update_asset(
		&c,
		pr.UpdateAssetRequest {
			conv_id = conv_id,
			asset_id = 1,
			payload_encoding = .Plain,
			payload_raw_len = 0,
			preview = transmute([]byte)string(`{"version":1,"name":"Renamed","owner":"rene"}`),
		},
	)
	testing.expect(t, string(conv.assets[1].preview) == `{"version":1,"name":"Shard hardening"}`, "a rename is refused and the record is untouched")

	handle_update_asset(
		&c,
		pr.UpdateAssetRequest {
			conv_id = conv_id,
			asset_id = 1,
			payload_encoding = .Plain,
			payload_raw_len = 0,
			preview = transmute([]byte)string(`{"version":1,"name":"Shard hardening","owner":"rene","outcome":"Restart-safe."}`),
		},
	)
	record, ok := slice_preview(conv.assets[1], context.temp_allocator)
	testing.expect(t, ok && record.owner == "rene", "an update that keeps the name is applied")
}

@(test)
test_membership_edge_is_a_set_while_other_relations_may_repeat :: proc(t: ^testing.T) {
	workspace_id := "slice-membership-set"
	if !init_room_mapping_test_state("slice_membership_set.log", workspace_id) {
		testing.expect(t, false, "membership set test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.asset_seq = 0
	td.edge_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	conv_id := pr.ConversationID(64)

	asset_handler_test_create(&c, conv_id, .Slice, .None, 0, `{"version":1,"name":"Shard hardening"}`, "")
	asset_handler_test_create(&c, conv_id, .Note, .None, 0, `{"title":"Shard layout v3"}`, "")

	conv := get_conversation(get_workspace(workspace_id), conv_id)
	testing.expect(t, conv != nil, "fixture conversation should exist")
	if conv == nil do return

	membership := pr.CreateEdgeRequest {
		conv_id     = conv_id,
		source_type = .Asset,
		source_id   = 2,
		target_type = .Asset,
		target_id   = 1,
		relation    = .MemberOf,
	}
	// A slice with no members has no adjacency entry at all, so the duplicate
	// check has to answer for a pair it has never seen.
	testing.expect(t, !duplicate_membership_edge(conv, membership), "nothing is assigned yet")
	handle_create_edge(&c, membership)
	testing.expect_value(t, len(conv.edges), 1)
	testing.expect(t, duplicate_membership_edge(conv, membership), "the pair is now a member of the slice")

	// The same member and slice cannot be joined twice, in either direction:
	// a second edge would count the member twice and render it twice.
	handle_create_edge(&c, membership)
	testing.expect_value(t, len(conv.edges), 1)
	handle_create_edge(
		&c,
		pr.CreateEdgeRequest{conv_id = conv_id, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 2, relation = .MemberOf},
	)
	testing.expect_value(t, len(conv.edges), 1)

	// A generic relation is not a membership, so the same pair may carry it.
	reference := pr.CreateEdgeRequest {
		conv_id     = conv_id,
		source_type = .Asset,
		source_id   = 2,
		target_type = .Asset,
		target_id   = 1,
		relation    = .References,
	}
	handle_create_edge(&c, reference)
	handle_create_edge(&c, reference)
	testing.expect_value(t, len(conv.edges), 3)

	// Removing the membership frees the pair to be assigned again.
	handle_delete_edge(&c, pr.DeleteEdgeRequest{conv_id = conv_id, edge_id = 1})
	testing.expect_value(t, len(conv.edges), 2)
	handle_create_edge(&c, membership)
	testing.expect_value(t, len(conv.edges), 3)
}

// Deleting a slice releases its memberships; it never takes a member with it.
// The tasks, notes and files are other people's records, so they stay exactly
// as they were and the register has to report them as work without a slice
// again. This is the guarantee the CLI's `slice delete` and the record's delete
// control are allowed to promise.
@(test)
test_slice_delete_releases_memberships_and_keeps_the_members :: proc(t: ^testing.T) {
	workspace_id := "slice-delete-release"
	if !init_room_mapping_test_state("slice_delete_release.log", workspace_id) {
		testing.expect(t, false, "slice delete test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.asset_seq = 0
	td.edge_seq = 0
	td.task_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	conv_id := pr.ConversationID(65)

	asset_handler_test_create(&c, conv_id, .Slice, .None, 0, `{"version":1,"name":"Shard hardening","owner":"rene","outcome":"Restart-safe."}`, "")
	asset_handler_test_create(&c, conv_id, .Note, .None, 0, `{"title":"Shard layout v3"}`, "")
	process_create_task(&c, pr.CreateTaskRequest{conv_id = conv_id, title = transmute([]byte)string("Manifest swap")})

	conv := get_conversation(get_workspace(workspace_id), conv_id)
	testing.expect(t, conv != nil, "fixture conversation should exist")
	if conv == nil do return
	testing.expect_value(t, len(conv.assets), 2)

	task_id := pr.TaskID(1)
	handle_create_edge(
		&c,
		pr.CreateEdgeRequest{conv_id = conv_id, source_type = .Asset, source_id = 2, target_type = .Asset, target_id = 1, relation = .MemberOf},
	)
	handle_create_edge(
		&c,
		pr.CreateEdgeRequest{conv_id = conv_id, source_type = .Task, source_id = u64(task_id), target_type = .Asset, target_id = 1, relation = .MemberOf},
	)
	testing.expect_value(t, len(conv.edges), 2)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		testing.expect(t, false, "slice delete test arena should initialize")
		return
	}
	defer virtual.arena_destroy(&arena)

	before := make([dynamic]pr.TaskSlice, 0, 4, virtual.arena_allocator(&arena))
	assigned_before := make(map[pr.TaskID]struct{}, 4, virtual.arena_allocator(&arena))
	before_page := collect_task_slices(conv, slice_test_query(true), &before, &assigned_before, virtual.arena_allocator(&arena))
	testing.expect_value(t, before_page.total_count, u32(1))
	testing.expect_value(t, pr.task_slice_member_count(before[0]), 2)
	testing.expect_value(t, unassigned_task_count(conv, &assigned_before), u32(0))

	handle_delete_asset(&c, pr.DeleteAssetRequest{conv_id = conv_id, asset_id = 1})

	testing.expect(t, conv.assets[1] == nil, "the slice asset is gone")
	testing.expect(t, conv.assets[2] != nil, "the note member survives the slice")
	testing.expect(t, conv.tasks[task_id] != nil, "the task member survives the slice")
	testing.expect_value(t, len(conv.edges), 0)
	testing.expect_value(t, len(conv.edges_by_entity), 0)

	after := make([dynamic]pr.TaskSlice, 0, 4, virtual.arena_allocator(&arena))
	assigned_after := make(map[pr.TaskID]struct{}, 4, virtual.arena_allocator(&arena))
	after_page := collect_task_slices(conv, slice_test_query(true), &after, &assigned_after, virtual.arena_allocator(&arena))
	testing.expect_value(t, after_page.total_count, u32(0))
	testing.expect_value(t, unassigned_task_count(conv, &assigned_after), u32(1))
}

@(test)
test_edge_handlers_update_both_adjacencies_and_asset_delete_cascades_once :: proc(t: ^testing.T) {
	workspace_id := "asset-edge-handler-cascade"
	if !init_room_mapping_test_state("asset_edge_handler_cascade.log", workspace_id) {
		testing.expect(t, false, "asset/edge handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	td.asset_seq = 0
	td.edge_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	conv_id := pr.ConversationID(62)
	asset_handler_test_create(&c, conv_id, .Note, .None, 0, `{"project":"root","tags":["tree"]}`, "root")
	asset_handler_test_create(&c, conv_id, .Note, .Asset, 1, `{"project":"child","tags":["tree"]}`, "child")
	asset_handler_test_create(&c, conv_id, .Document, .Asset, 2, "grandchild", "grandchild")
	asset_handler_test_create(&c, conv_id, .Document, .None, 0, "outside", "outside")

	edge_requests := [?]pr.CreateEdgeRequest {
		{conv_id = conv_id, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 2, relation = .References},
		{conv_id = conv_id, source_type = .Asset, source_id = 2, target_type = .Asset, target_id = 3, relation = .RelatedTo},
		{conv_id = conv_id, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 4, relation = .DependsOn},
	}
	for req in edge_requests do handle_create_edge(&c, req)

	conv := get_conversation(get_workspace(workspace_id), conv_id)
	testing.expect(t, conv != nil, "fixture conversation should exist")
	if conv == nil do return
	testing.expect_value(t, len(conv.edges), 3)
	asset_handler_test_expect_adjacency(t, conv, .Asset, 3, 2)
	asset_handler_test_expect_adjacency(t, conv, .Asset, 4, 3)
	testing.expect_value(t, len(conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}]), 2)
	testing.expect_value(t, len(conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 2}]), 2)
	handle_delete_edge(&c, pr.DeleteEdgeRequest{conv_id = conv_id, edge_id = 3})
	testing.expect(t, conv.edges[3] == nil, "edge delete should remove the edge map entry")
	testing.expect_value(t, len(conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}]), 1)
	_, outside_adjacency := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 4}]
	testing.expect(t, !outside_adjacency, "edge delete should remove the second endpoint adjacency")
	handle_create_edge(&c, edge_requests[2])
	testing.expect(t, conv.edges[4] != nil, "replacement incident edge should be stored")

	before_delete_records := td.shard_writers.writers[0].wal.record_count
	handle_delete_asset(&c, pr.DeleteAssetRequest{conv_id = conv_id, asset_id = 1})

	testing.expect(t, conv.assets[1] == nil && conv.assets[2] == nil && conv.assets[3] == nil, "root delete should remove every descendant")
	testing.expect(t, conv.assets[4] != nil, "cascade should retain unrelated assets")
	testing.expect_value(t, len(conv.edges), 0)
	testing.expect_value(t, len(conv.edges_by_entity), 0)
	_, root_project := conv.note_project_assets["root"]
	_, child_project := conv.note_project_assets["child"]
	_, tree_tag := conv.note_tag_assets["tree"]
	testing.expect(t, !root_project && !child_project && !tree_tag, "cascade should remove descendant note indexes")
	testing.expect_value(t, btree.count(&conv.note_index), 0)
	testing.expect_value(t, len(conv.note_index_keys), 0)
	testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, before_delete_records + 1)
	shard := int(shard_for_workspace(transmute([]byte)workspace_id))
	wal_inspection := persistence.inspect_wal_file_strict(room_mapping_test_wal_path, SHARD_WAL_MAGIC, shard, asset_cascade_wal_inspect_record)
	testing.expect(t, wal_inspection.ok && asset_cascade_wal_inspection.ok, "cascade WAL should decode")
	testing.expect_value(t, asset_cascade_wal_inspection.mutation_count, 6)
	testing.expect_value(t, asset_cascade_wal_inspection.asset_count, 3)
	testing.expect_value(t, asset_cascade_wal_inspection.edge_count, 3)
	expected_assets := [3]u64{1, 2, 3}
	for expected in expected_assets {
		testing.expect(
			t,
			asset_handler_test_contains_id(asset_cascade_wal_inspection.asset_ids[:], expected),
			"cascade WAL should contain each asset tombstone exactly once",
		)
	}
	expected_edges := [3]u64{1, 2, 4}
	for expected in expected_edges {
		testing.expect(
			t,
			asset_handler_test_contains_id(asset_cascade_wal_inspection.edge_ids[:], expected),
			"cascade WAL should contain each edge tombstone exactly once",
		)
	}
}

@(test)
test_asset_create_persistence_failure_is_not_visible_or_acknowledged :: proc(t: ^testing.T) {
	workspace_id := "asset-handler-create-failure"
	if !init_room_mapping_test_state("asset_handler_create_failure.log", workspace_id) {
		testing.expect(t, false, "asset handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	defer persistence.clear_wal_write_fault_for_test()
	defer {persistent_mutation_failure_seen = false}
	td.asset_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	asset_handler_test_arm_persistence_failure(&c)
	previous_logger := context.logger
	context.logger = log.nil_logger()
	asset_handler_test_create(&c, 63, .Note, .None, 0, `{"project":"hidden","tags":["hidden"]}`, "must not appear")
	context.logger = previous_logger

	conv := get_conversation(get_workspace(workspace_id), 63)
	testing.expect(t, conv != nil, "handler may create the conversation shell before persistence")
	if conv != nil {
		testing.expect_value(t, len(conv.assets), 0)
		testing.expect_value(t, btree.count(&conv.note_index), 0)
		testing.expect_value(t, len(conv.note_index_keys), 0)
		testing.expect_value(t, len(conv.note_project_assets), 0)
		testing.expect_value(t, len(conv.note_tag_assets), 0)
	}
	testing.expect(t, persistent_mutation_failure_seen, "failed create should trigger fail-closed handling")
	testing.expect(t, persistence.wal_write_fault_triggered_for_test(), "create failure should reach the WAL fault")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed create should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_asset_update_persistence_failure_preserves_asset_and_indexes :: proc(t: ^testing.T) {
	workspace_id := "asset-handler-update-failure"
	if !init_room_mapping_test_state("asset_handler_update_failure.log", workspace_id) {
		testing.expect(t, false, "asset handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	defer persistence.clear_wal_write_fault_for_test()
	defer {persistent_mutation_failure_seen = false}
	td.asset_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	asset_handler_test_create(&c, 64, .Note, .None, 0, `{"project":"original","tags":["kept"]}`, "original")
	conv := get_conversation(get_workspace(workspace_id), 64)
	original := conv.assets[1]
	original_key := asset_handler_test_expect_single_note_key(t, conv, 1)
	asset_handler_test_arm_persistence_failure(&c)
	previous_logger := context.logger
	context.logger = log.nil_logger()
	handle_update_asset(
		&c,
		pr.UpdateAssetRequest {
			conv_id = 64,
			asset_id = 1,
			payload_encoding = .Plain,
			payload_raw_len = 11,
			preview = transmute([]byte)string(`{"project":"replacement","tags":["lost"]}`),
			payload = transmute([]byte)string("replacement"),
			correlation_id = 71,
		},
	)
	context.logger = previous_logger

	testing.expect(t, conv.assets[1] == original, "failed update should retain the owned asset")
	testing.expect(t, string(conv.assets[1].payload) == "original", "failed update should retain content")
	testing.expect_value(t, asset_handler_test_expect_single_note_key(t, conv, 1), original_key)
	testing.expect_value(t, note_secondary_index_count(conv.note_project_assets["original"]), 1)
	testing.expect_value(t, note_secondary_index_count(conv.note_tag_assets["kept"]), 1)
	_, replacement_project := conv.note_project_assets["replacement"]
	_, replacement_tag := conv.note_tag_assets["lost"]
	testing.expect(t, !replacement_project && !replacement_tag, "failed update should not install replacement indexes")
	testing.expect(t, persistent_mutation_failure_seen, "failed update should trigger fail-closed handling")
	testing.expect(t, persistence.wal_write_fault_triggered_for_test(), "update failure should reach the WAL fault")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed update should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_asset_delete_persistence_failure_preserves_cascade_and_adjacency :: proc(t: ^testing.T) {
	workspace_id := "asset-handler-delete-failure"
	if !init_room_mapping_test_state("asset_handler_delete_failure.log", workspace_id) {
		testing.expect(t, false, "asset handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	defer persistence.clear_wal_write_fault_for_test()
	defer {persistent_mutation_failure_seen = false}
	td.asset_seq = 0
	td.edge_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	asset_handler_test_create(&c, 65, .Note, .None, 0, `{"project":"root","tags":["tree"]}`, "root")
	asset_handler_test_create(&c, 65, .Note, .Asset, 1, `{"project":"child","tags":["tree"]}`, "child")
	handle_create_edge(
		&c,
		pr.CreateEdgeRequest{conv_id = 65, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 2, relation = .References},
	)
	conv := get_conversation(get_workspace(workspace_id), 65)
	root, child, edge := conv.assets[1], conv.assets[2], conv.edges[1]
	root_key := conv.note_index_keys[1]
	child_key := conv.note_index_keys[2]
	asset_handler_test_arm_persistence_failure(&c)
	previous_logger := context.logger
	context.logger = log.nil_logger()
	handle_delete_asset(&c, pr.DeleteAssetRequest{conv_id = 65, asset_id = 1, correlation_id = 72})
	context.logger = previous_logger

	testing.expect(t, conv.assets[1] == root && conv.assets[2] == child, "failed cascade should retain root and descendants")
	testing.expect(t, conv.edges[1] == edge, "failed cascade should retain incident edges")
	asset_handler_test_expect_adjacency(t, conv, .Asset, 1, 1)
	asset_handler_test_expect_adjacency(t, conv, .Asset, 2, 1)
	testing.expect_value(t, note_secondary_index_count(conv.note_project_assets["root"]), 1)
	testing.expect(t, note_secondary_index_contains_asset(conv.note_project_assets["root"], 1), "root project should contain root note")
	testing.expect_value(t, note_secondary_index_count(conv.note_project_assets["child"]), 1)
	testing.expect(t, note_secondary_index_contains_asset(conv.note_project_assets["child"], 2), "child project should contain child note")
	testing.expect_value(t, note_secondary_index_count(conv.note_tag_assets["tree"]), 2)
	testing.expect(t, note_secondary_index_contains_asset(conv.note_tag_assets["tree"], 1), "retained tree tag should contain the root note")
	testing.expect(t, note_secondary_index_contains_asset(conv.note_tag_assets["tree"], 2), "retained tree tag should contain the child note")
	testing.expect_value(t, btree.count(&conv.note_index), 2)
	testing.expect_value(t, conv.note_index_keys[1], root_key)
	testing.expect_value(t, conv.note_index_keys[2], child_key)
	testing.expect(t, asset_handler_test_btree_contains(conv, root_key), "failed delete should retain the root B-tree key")
	testing.expect(t, asset_handler_test_btree_contains(conv, child_key), "failed delete should retain the child B-tree key")
	testing.expect(t, persistent_mutation_failure_seen, "failed delete should trigger fail-closed handling")
	testing.expect(t, persistence.wal_write_fault_triggered_for_test(), "asset delete failure should reach the WAL fault")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed asset delete should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_edge_create_persistence_failure_is_not_visible_or_acknowledged :: proc(t: ^testing.T) {
	workspace_id := "edge-handler-create-failure"
	if !init_room_mapping_test_state("edge_handler_create_failure.log", workspace_id) {
		testing.expect(t, false, "edge handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	defer persistence.clear_wal_write_fault_for_test()
	defer {persistent_mutation_failure_seen = false}
	td.asset_seq = 0
	td.edge_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	asset_handler_test_create(&c, 66, .Document, .None, 0, "one", "one")
	asset_handler_test_create(&c, 66, .Document, .None, 0, "two", "two")
	conv := get_conversation(get_workspace(workspace_id), 66)
	asset_handler_test_arm_persistence_failure(&c)
	previous_logger := context.logger
	context.logger = log.nil_logger()
	handle_create_edge(
		&c,
		pr.CreateEdgeRequest {
			conv_id = 66,
			source_type = .Asset,
			source_id = 1,
			target_type = .Asset,
			target_id = 2,
			relation = .References,
			correlation_id = 73,
		},
	)
	context.logger = previous_logger

	testing.expect_value(t, len(conv.edges), 0)
	testing.expect_value(t, len(conv.edges_by_entity), 0)
	testing.expect(t, persistent_mutation_failure_seen, "failed edge create should trigger fail-closed handling")
	testing.expect(t, persistence.wal_write_fault_triggered_for_test(), "edge create failure should reach the WAL fault")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed edge create should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}

@(test)
test_edge_delete_persistence_failure_preserves_both_adjacencies :: proc(t: ^testing.T) {
	workspace_id := "edge-handler-delete-failure"
	if !init_room_mapping_test_state("edge_handler_delete_failure.log", workspace_id) {
		testing.expect(t, false, "edge handler test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()
	defer persistence.clear_wal_write_fault_for_test()
	defer {persistent_mutation_failure_seen = false}
	td.asset_seq = 0
	td.edge_seq = 0

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	asset_handler_test_create(&c, 67, .Document, .None, 0, "one", "one")
	asset_handler_test_create(&c, 67, .Document, .None, 0, "two", "two")
	handle_create_edge(
		&c,
		pr.CreateEdgeRequest{conv_id = 67, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 2, relation = .References},
	)
	conv := get_conversation(get_workspace(workspace_id), 67)
	edge := conv.edges[1]
	asset_handler_test_arm_persistence_failure(&c)
	previous_logger := context.logger
	context.logger = log.nil_logger()
	handle_delete_edge(&c, pr.DeleteEdgeRequest{conv_id = 67, edge_id = 1, correlation_id = 74})
	context.logger = previous_logger

	testing.expect(t, conv.edges[1] == edge, "failed delete should retain the owned edge")
	asset_handler_test_expect_adjacency(t, conv, .Asset, 1, 1)
	asset_handler_test_expect_adjacency(t, conv, .Asset, 2, 1)
	testing.expect(t, persistent_mutation_failure_seen, "failed edge delete should trigger fail-closed handling")
	testing.expect(t, persistence.wal_write_fault_triggered_for_test(), "edge delete failure should reach the WAL fault")
	testing.expect(t, td.shard_writers.writers[0].poisoned, "failed edge delete should poison the shard writer")
	testing.expect_value(t, send_queue_len(&c), 0)
}
