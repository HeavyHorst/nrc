package main

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

import pr "protocol"

workspace_migration_append_fixture :: proc(t: ^testing.T, writer: ^Shard_Transaction_Writer, workspace: string, scope: pr.ConversationID, id: u64) {
	attachment := [1]pr.Attachment {
		{
			file_id = transmute([]byte)string("migration-file"),
			filename = transmute([]byte)string("preserved.txt"),
			size = 1234,
			mime_type = transmute([]byte)string("text/plain"),
			uploaded_at = 4321,
		},
	}
	task := pr.Task {
		id          = id,
		conv_id     = scope,
		title       = transmute([]byte)string("legacy"),
		status      = .Todo,
		attachments = attachment[:],
	}
	testing.expect(t, shard_segment_test_append_task(writer, workspace, .Create, &task))
	asset := pr.Asset {
		asset_id        = id,
		conv_id         = scope,
		asset_type      = .Document,
		parent_type     = .Task,
		parent_id       = id,
		payload         = transmute([]byte)string("preserved body"),
		payload_raw_len = 14,
		attachments     = attachment[:],
	}
	built, ok := build_shard_asset_mutation(transmute([]byte)workspace, .Create, &asset, writer.floors)
	defer destroy_shard_mutation_transaction(&built)
	testing.expect(t, ok && append_shard_transaction(writer, &built.tx))
	edge := pr.Edge {
		edge_id     = id,
		conv_id     = scope,
		source_type = .Task,
		source_id   = id,
		target_type = .Asset,
		target_id   = id,
		relation    = .References,
	}
	testing.expect(t, shard_segment_test_append_edge(writer, workspace, &edge))
}

workspace_migration_expect_state :: proc(t: ^testing.T, workspace: string, public_count: int, updated: bool) {
	ws := get_workspace(workspace)
	testing.expect(t, ws != nil)
	if ws == nil do return
	for legacy_scope in ([?]pr.ConversationID{77, 78, 79}) do testing.expect(t, get_conversation(ws, legacy_scope) == nil)
	for scope in ([?]pr.ConversationID{pr.WORKSPACE_DATA_ID, pr.ConversationID(pr.DM_CONV_FLAG | 77)}) {
		conv := get_conversation(ws, scope)
		testing.expect(t, conv != nil)
		if conv == nil do continue
		count := scope == pr.WORKSPACE_DATA_ID ? public_count : 1
		testing.expect_value(t, len(conv.tasks), count)
		testing.expect_value(t, len(conv.assets), count)
		testing.expect_value(t, len(conv.edges), count)
		testing.expect_value(t, len(conv.edges_by_entity), count * 2)
		task, asset, edge := conv.tasks[1], conv.assets[1], conv.edges[1]
		testing.expect(t, task != nil && asset != nil && edge != nil)
		if task == nil || asset == nil || edge == nil do continue
		testing.expect_value(t, task.conv_id, scope)
		testing.expect_value(t, asset.conv_id, scope)
		testing.expect_value(t, edge.conv_id, scope)
		testing.expect_value(t, string(task.title), updated && scope == pr.WORKSPACE_DATA_ID ? "current" : "legacy")
		testing.expect(t, asset.parent_type == .Task && asset.parent_id == 1)
		testing.expect(t, edge.source_type == .Task && edge.source_id == 1 && edge.target_type == .Asset && edge.target_id == 1)
		testing.expect_value(t, string(asset.payload), "preserved body")
		for attachments in ([?][]pr.Attachment{task.attachments, asset.attachments}) {
			testing.expect_value(t, len(attachments), 1)
			if len(attachments) != 1 do continue
			testing.expect_value(t, string(attachments[0].file_id), "migration-file")
			testing.expect_value(t, string(attachments[0].filename), "preserved.txt")
			testing.expect_value(t, string(attachments[0].mime_type), "text/plain")
			testing.expect_value(t, attachments[0].size, u64(1234))
			testing.expect_value(t, attachments[0].uploaded_at, i64(4321))
		}
	}
}

@(test)
test_workspace_migration_legacy_and_current_tombstones_survive_cleaning_and_checkpoint :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("workspace-migration")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 1))
	workspace := "workspace-migration"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 1)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	for scope, i in ([?]pr.ConversationID{77, 78, 79}) do workspace_migration_append_fixture(t, &writer, workspace, scope, u64(i + 1))
	workspace_migration_append_fixture(t, &writer, workspace, pr.ConversationID(pr.DM_CONV_FLAG | 77), 1)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	shard_replay_state_init()
	_, ok := replay_shard_compaction_sequence(shard_dir, writer.manifest, true, false)
	testing.expect(t, ok)
	workspace_migration_expect_state(t, workspace, 3, false)
	shard_replay_state_destroy()

	// A legacy post-image and a subsequent canonical post-image address one
	// public entity. Private same-ID records must not change.
	task := pr.Task {
		id      = 1,
		conv_id = 77,
		title   = transmute([]byte)string("legacy updated"),
		status  = .Todo,
	}
	attachment := [1]pr.Attachment {
		{
			file_id = transmute([]byte)string("migration-file"),
			filename = transmute([]byte)string("preserved.txt"),
			size = 1234,
			mime_type = transmute([]byte)string("text/plain"),
			uploaded_at = 4321,
		},
	}
	task.attachments = attachment[:]
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Update, &task))
	task.conv_id = pr.WORKSPACE_DATA_ID
	task.title = transmute([]byte)string("current")
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Update, &task))
	for scope, i in ([?]pr.ConversationID{pr.WORKSPACE_DATA_ID, 79}) {
		id := u64(i + 2)
		assets := [1]pr.AssetID{id}
		edges := [1]pr.EdgeID{id}
		remove, remove_ok := build_shard_task_delete_transaction(transmute([]byte)workspace, scope, id, assets[:], edges[:], nil, writer.floors)
		testing.expect(t, remove_ok && append_shard_transaction(&writer, &remove.tx))
		destroy_shard_task_delete_transaction(&remove)
	}
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && publish_shard_compaction_result(&writer, result))
	manifest := writer.manifest
	testing.expect(t, shutdown_shard_transaction_writer(&writer))

	shard_replay_state_init()
	floors, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
	testing.expect(t, replay_ok)
	workspace_migration_expect_state(t, workspace, 1, true)
	checkpoint := test_wal_path("workspace-migration-checkpoint.log")
	defer os.remove(checkpoint)
	testing.expect(t, build_shard_checkpoint_from_replayed_state(checkpoint, shard, floors))
	shard_replay_state_destroy()
	shard_replay_state_init()
	defer shard_replay_state_destroy()
	_, checkpoint_floors, checkpoint_ok := replay_shard_transaction_wal(checkpoint, shard)
	testing.expect(t, checkpoint_ok)
	testing.expect_value(t, checkpoint_floors, floors)
	workspace_migration_expect_state(t, workspace, 1, true)
}

@(test)
test_workspace_migration_collisions_cross_segments_and_tombstones_without_truncation :: proc(t: ^testing.T) {
	for domain in ([?]Shard_Mutation_Domain{.Task, .Asset, .Edge}) {
		data_dir := storage_layout_test_setup(fmt.tprintf("workspace-collision-%v", domain))
		defer os.remove_all(data_dir)
		testing.expect(t, storage_layout_test_create_generation(data_dir, 1))
		workspace := "workspace-collision"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		generation_dir := sharded_generation_path(data_dir, 1)
		defer delete(generation_dir)
		shard_dir := sharded_shard_path(generation_dir, shard)
		defer delete(shard_dir)
		writer: Shard_Transaction_Writer
		testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
		workspace_migration_append_fixture(t, &writer, workspace, 77, 1)
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
		// Canonical tombstone must not erase the original room's provenance.
		for scope in ([?]pr.ConversationID{pr.WORKSPACE_DATA_ID, 78}) {
			remove: Shard_Mutation_Transaction
			ok: bool
			switch domain {
			case .Task:
				remove, ok = build_shard_task_delete_mutation(transmute([]byte)workspace, scope, 1, writer.floors)
			case .Asset:
				remove, ok = build_shard_asset_delete_mutation(transmute([]byte)workspace, scope, 1, writer.floors)
			case .Edge:
				remove, ok = build_shard_edge_delete_mutation(transmute([]byte)workspace, scope, 1, writer.floors)
			}
			testing.expect(t, ok && append_shard_transaction(&writer, &remove.tx))
			destroy_shard_mutation_transaction(&remove)
		}
		manifest := writer.manifest
		testing.expect(t, shutdown_shard_transaction_writer(&writer))
		active := shard_generation_wal_path(shard_dir, manifest.active_generation)
		defer delete(active)
		before, read_err := os.read_entire_file(active, context.allocator)
		defer delete(before)
		testing.expect(t, read_err == nil && len(before) > 0)
		for apply in ([?]bool{false, true}) {
			shard_replay_state_init()
			previous_logger := context.logger
			context.logger = log.nil_logger()
			_, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, apply, true)
			context.logger = previous_logger
			testing.expect(t, !replay_ok, "different legacy rooms reusing one entity ID must fail even after a scope-zero tombstone")
			shard_replay_state_destroy()
			after, after_err := os.read_entire_file(active, context.allocator)
			testing.expect(t, after_err == nil && bytes.equal(before, after), "migration conflict is not a torn tail and must not truncate evidence")
			delete(after)
		}
		checkpoint := test_wal_path(fmt.tprintf("workspace-collision-%v-checkpoint.log", domain))
		defer os.remove(checkpoint)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		_, checkpoint_ok := build_and_verify_shard_checkpoint(shard_dir, manifest, checkpoint)
		context.logger = previous_logger
		testing.expect(t, !checkpoint_ok, "checkpoint must inspect active suffix before discarding legacy origins")
	}
}

@(test)
test_workspace_migration_multiple_agendas_require_explicit_update :: proc(t: ^testing.T) {
	workspace := "migration-agendas"
	testing.expect(t, init_room_mapping_test_state("migration-agendas.log", workspace))
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	writer := &td.shard_writers.writers[0]
	for scope, i in ([?]pr.ConversationID{77, 78}) {
		asset := pr.Asset {
			asset_id        = u64(i + 1),
			conv_id         = scope,
			asset_type      = .Agenda,
			preview         = transmute([]byte)string("agenda"),
			payload         = transmute([]byte)string("legacy agenda"),
			payload_raw_len = 13,
		}
		built, ok := build_shard_asset_mutation(transmute([]byte)workspace, .Create, &asset, writer.floors)
		testing.expect(t, ok && append_shard_transaction(writer, &built.tx))
		testing.expect(t, apply_shard_mutation(built.tx.workspace, built.tx.mutations[0]))
		destroy_shard_mutation_transaction(&built)
	}
	td.asset_seq = 2
	conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.assets) == 2)
	if conv == nil do return
	before := writer.wal.record_count
	handle_create_asset(
		&c,
		{conv_id = pr.WORKSPACE_DATA_ID, asset_type = .Agenda, payload = transmute([]byte)string("must not overwrite"), payload_raw_len = 18},
	)
	testing.expect_value(t, writer.wal.record_count, before)
	testing.expect_value(t, len(conv.assets), 2)
	testing.expect_value(t, td.asset_seq, u64(2))
	for id in u64(1) ..= 2 {
		testing.expect(t, conv.assets[id] != nil && string(conv.assets[id].payload) == "legacy agenda")
	}
	handle_update_asset(&c, {conv_id = pr.WORKSPACE_DATA_ID, asset_id = 2, payload = transmute([]byte)string("chosen agenda"), payload_raw_len = 13})
	testing.expect_value(t, writer.wal.record_count, before + 1)
	testing.expect_value(t, len(conv.assets), 2)
	testing.expect(t, conv.assets[1] != nil && string(conv.assets[1].payload) == "legacy agenda")
	testing.expect(t, conv.assets[2] != nil && string(conv.assets[2].payload) == "chosen agenda")
}

@(test)
test_workspace_migration_post_image_collision_and_legacy_zero_alias :: proc(t: ^testing.T) {
	// The old format cannot distinguish legacy room zero from current workspace
	// data. It aliases a later public origin, but must not erase a known origin.
	for first_scope in ([?]pr.ConversationID{77, pr.WORKSPACE_DATA_ID}) {
		path := test_wal_path(fmt.tprintf("workspace-origin-%d.log", first_scope))
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, nil) == nil)
		workspace := "workspace-origin"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		writer: Shard_Transaction_Writer
		testing.expect(t, init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
		task := pr.Task {
			id      = 1,
			conv_id = first_scope,
			title   = transmute([]byte)string("first"),
			status  = .Todo,
		}
		testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
		task.conv_id = pr.WORKSPACE_DATA_ID
		task.title = transmute([]byte)string("canonical")
		testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Update, &task))
		task.conv_id = 78
		task.title = transmute([]byte)string("later legacy")
		testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
		testing.expect(t, shutdown_shard_transaction_writer(&writer))
		before, read_err := os.read_entire_file(path, context.allocator)
		defer delete(before)
		testing.expect(t, read_err == nil && len(before) > 0)
		shard_replay_state_init()
		previous_logger := context.logger
		context.logger = log.nil_logger()
		_, _, ok := scan_shard_transaction_wal(path, shard, {}, true, true)
		context.logger = previous_logger
		testing.expect_value(t, ok, first_scope == pr.WORKSPACE_DATA_ID)
		if ok {
			conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
			testing.expect(t, conv != nil && len(conv.tasks) == 1)
			if conv != nil do testing.expect(t, conv.tasks[1] != nil && string(conv.tasks[1].title) == "later legacy")
		}
		shard_replay_state_destroy()
		after, after_err := os.read_entire_file(path, context.allocator)
		testing.expect(t, after_err == nil && bytes.equal(before, after))
		delete(after)
	}
}
