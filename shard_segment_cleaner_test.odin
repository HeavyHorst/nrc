#+feature dynamic-literals

package main

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:os"
import "core:testing"

import "persistence"
import pr "protocol"

shard_segment_test_append_task :: proc(writer: ^Shard_Transaction_Writer, workspace: string, op: Task_Log_Op, task: ^pr.Task) -> bool {
	built, ok := build_shard_task_mutation(transmute([]byte)workspace, op, task, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

shard_segment_test_append_edge :: proc(writer: ^Shard_Transaction_Writer, workspace: string, edge: ^pr.Edge) -> bool {
	built, ok := build_shard_edge_mutation(transmute([]byte)workspace, .Create, edge, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

shard_segment_test_convert_single_record_to_legacy_header :: proc(path: string) -> bool {
	current, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil || len(current) < persistence.LOG_HEADER_SIZE do return false
	defer delete(current)
	payload_size, _ := endian.get_u32(current[8:], .Big)
	if len(current) != persistence.LOG_HEADER_SIZE + int(payload_size) do return false
	legacy := make([]byte, persistence.LEGACY_LOG_HEADER_SIZE + int(payload_size))
	defer delete(legacy)
	copy(legacy[:44], current[:44])
	legacy[7] = 0
	copy(legacy[persistence.LEGACY_LOG_HEADER_SIZE:], current[persistence.LOG_HEADER_SIZE:])
	state: xxhash.XXH32_state
	xxhash.XXH32_reset_state(&state, 0)
	xxhash.XXH32_update(&state, legacy[:44])
	xxhash.XXH32_update(&state, legacy[persistence.LEGACY_LOG_HEADER_SIZE:])
	endian.put_u32(legacy[44:], .Big, xxhash.XXH32_digest(&state))
	return os.write_entire_file(path, legacy) == nil
}

@(test)
test_shard_segment_clean_result_publication_invariants :: proc(t: ^testing.T) {
	adoption := Shard_Segment_Clean_Result {
		catalog = {shard = 1, catalog_generation = 5, segments = {{.Generation_WAL, 1}}},
		ok = true,
	}
	defer destroy_shard_segment_clean_result(&adoption)
	testing.expect(t, shard_segment_clean_result_is_publishable(adoption))
	adoption.removed_count = 1
	testing.expect(t, !shard_segment_clean_result_is_publishable(adoption))
	adoption.removed_count = 0

	raw_adoption := Shard_Segment_Clean_Result {
		catalog = {shard = 1, catalog_generation = 6, segments = {{.Adopted_Generation_WAL, 1}}},
		removed_count = 1,
		removed = {{.Generation_WAL, 1}},
		outputs = {{.Adopted_Generation_WAL, 1}},
		raw_adopted = true,
		ok = true,
	}
	defer destroy_shard_segment_clean_result(&raw_adoption)
	testing.expect(t, shard_segment_clean_result_is_publishable(raw_adoption))
	raw_adoption.outputs[0].generation = 2
	testing.expect(t, !shard_segment_clean_result_is_publishable(raw_adoption))

	cleaned := Shard_Segment_Clean_Result {
		catalog = {shard = 1, catalog_generation = 6, segments = {{.Cleaned_Segment, 6}}},
		removed_count = 2,
		removed = {{.Generation_WAL, 1}, {.Generation_WAL, 2}},
		outputs = {{.Cleaned_Segment, 6}},
		output_present = true,
		output_generation = 6,
		ok = true,
	}
	defer destroy_shard_segment_clean_result(&cleaned)
	testing.expect(t, shard_segment_clean_result_is_publishable(cleaned))
	cleaned.removed[0] = cleaned.catalog.segments[0]
	testing.expect(t, !shard_segment_clean_result_is_publishable(cleaned))
	cleaned.removed[0] = {.Generation_WAL, 1}
	cleaned.removed_count = 1
	testing.expect(t, !shard_segment_clean_result_is_publishable(cleaned))
	cleaned.removed_count = 2

	removal := Shard_Segment_Clean_Result {
		catalog = {shard = 1, catalog_generation = 7, segments = {{.Cleaned_Segment, 5}}},
		removed_start = 1,
		removed_count = 1,
		removed = {{.Generation_WAL, 6}},
		ok = true,
	}
	defer destroy_shard_segment_clean_result(&removal)
	testing.expect(t, shard_segment_clean_result_is_publishable(removal))
	removal.removed_start = 2
	testing.expect(t, !shard_segment_clean_result_is_publishable(removal))
}

@(test)
test_shard_segment_clean_result_must_exactly_replace_source_suffix :: proc(t: ^testing.T) {
	source := Shard_Segment_Clean_Source {
		shard    = 1,
		segments = {{.Generation_WAL, 1}, {.Generation_WAL, 2}, {.Generation_WAL, 3}},
	}
	defer destroy_shard_segment_clean_source(&source)
	result := Shard_Segment_Clean_Result {
		catalog = {shard = 1, catalog_generation = 4, segments = {{.Generation_WAL, 1}, {.Cleaned_Segment, 4}}},
		removed_start = 1,
		removed_count = 2,
		removed = {{.Generation_WAL, 2}, {.Generation_WAL, 3}},
		outputs = {{.Cleaned_Segment, 4}},
		output_present = true,
		output_generation = 4,
		ok = true,
	}
	defer destroy_shard_segment_clean_result(&result)
	testing.expect(t, shard_segment_clean_result_matches_source(result, source))

	result.removed[1] = {.Generation_WAL, 99}
	testing.expect(t, !shard_segment_clean_result_matches_source(result, source))
	result.removed[1] = {.Generation_WAL, 3}
	result.catalog.segments[0] = {.Generation_WAL, 99}
	testing.expect(t, !shard_segment_clean_result_matches_source(result, source))
	result.catalog.segments[0] = {.Generation_WAL, 1}
	result.removed_count = 1
	testing.expect(t, !shard_segment_clean_result_matches_source(result, source))

	adoption := Shard_Segment_Clean_Result {
		catalog = {shard = 1, catalog_generation = 4, segments = {{.Generation_WAL, 1}, {.Generation_WAL, 2}}},
		ok = true,
	}
	defer destroy_shard_segment_clean_result(&adoption)
	testing.expect(t, !shard_segment_clean_result_matches_source(adoption, source))
}

@(test)
test_shard_segment_clean_group_is_bounded_but_accepts_one_oversized_input :: proc(t: ^testing.T) {
	all_fit := [3]u64{100, 200, 300}
	end, ok := shard_segment_clean_group_end(all_fit[:], 0, 1000)
	testing.expect(t, ok)
	testing.expect_value(t, end, 3)

	target_pair := [3]u64{100, 200, 300}
	end, ok = shard_segment_clean_group_end(target_pair[:], 0, 500)
	testing.expect(t, ok)
	testing.expect_value(t, end, 2)

	oversized := [3]u64{100, 600, 700}
	end, ok = shard_segment_clean_group_end(oversized[:], 1, 500)
	testing.expect(t, ok)
	testing.expect_value(t, end, 2)

	_, ok = shard_segment_clean_group_end(oversized[:], 3, 500)
	testing.expect(t, !ok)
}

@(test)
test_shard_segment_cleaner_preserves_edge_when_superseded_endpoint_create_is_removed :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-edge-order")
	defer os.remove_all(data_dir)
	generation: u64 = 1
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "segment-cleaner-edge-order"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	task_a := pr.Task {
		id      = 1,
		conv_id = 77,
		title   = transmute([]byte)string("A"),
	}
	task_b := pr.Task {
		id      = 2,
		conv_id = 77,
		title   = transmute([]byte)string("B"),
	}
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 77,
		source_type = .Task,
		source_id   = 1,
		target_type = .Task,
		target_id   = 2,
		relation    = .Blocks,
	}
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task_a))
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task_b))
	testing.expect(t, shard_segment_test_append_edge(&writer, workspace, &edge))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	first := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&first.segments)
	testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))
	testing.expect(t, writer.manifest.segmented)

	task_a.title = transmute([]byte)string("A moved")
	task_a.order_index = 9
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Move, &task_a))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	second := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&second.segments)
	testing.expect(t, second.ok && second.segments.raw_adopted)
	testing.expect(t, publish_shard_compaction_result(&writer, second))

	shard_replay_state_init()
	floors, replay_ok := replay_shard_compaction_sequence(shard_dir, writer.manifest, true, false)
	testing.expect(t, replay_ok)
	testing.expect_value(t, floors, writer.floors)
	replayed_a := get_task(workspace, pr.WORKSPACE_DATA_ID, 1)
	replayed_b := get_task(workspace, pr.WORKSPACE_DATA_ID, 2)
	ws := get_workspace(workspace)
	conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
	testing.expect(t, replayed_a != nil && string(replayed_a.title) == "A moved")
	testing.expect(t, replayed_b != nil)
	testing.expect(t, conv != nil && conv.edges[1] != nil)
	shard_replay_state_destroy()
}

@(test)
test_shard_segment_cleaner_uses_newer_tail_to_measure_older_group :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-newer-tail")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 2))
	workspace := "segment-cleaner-newer-tail"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 2)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	task := pr.Task {
		id      = 10,
		conv_id = 77,
		title   = transmute([]byte)string("A"),
	}
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	first := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&first.segments)
	testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))

	task.title = transmute([]byte)string("B")
	task.updated_at = 1
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Update, &task))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	source, source_ok := shard_segment_source_for_manifest(writer.storage, writer.shard_dir, writer.manifest)
	defer destroy_shard_segment_clean_source(&source)
	testing.expect(t, source_ok && len(source.segments) == 2)
	if !source_ok || len(source.segments) != 2 do return
	first_size, size_ok := shard_segment_descriptor_size(writer.storage, writer.shard_dir, source.segments[0])
	testing.expect(t, size_ok)
	output_generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
	testing.expect(t, generation_ok)
	result := build_shard_segment_catalog(
		writer.storage,
		writer.shard_dir,
		writer.manifest,
		output_generation,
		&source,
		0,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		first_size,
	)
	defer destroy_shard_segment_clean_result(&result)
	testing.expect(t, result.ok && result.output_present)
	testing.expect(t, result.removed_start == 0 && result.removed_count == 1)
	testing.expect(t, result.dirty_bytes > 0 && len(result.catalog.segments) == 2)
	if !result.ok do return
	wrapped := Shard_Compaction_Result {
		owner_worker          = writer.owner_worker,
		shard                 = writer.shard,
		manifest_generation   = writer.manifest.manifest_generation,
		checkpoint_generation = output_generation,
		floors                = result.floors,
		segments              = result,
		ok                    = true,
	}
	writer.compaction = .Building
	writer.compaction_floors = writer.catalog_floors
	testing.expect(t, publish_shard_compaction_result(&writer, wrapped))

	shard_replay_state_init()
	defer shard_replay_state_destroy()
	_, replay_ok := replay_shard_compaction_sequence(shard_dir, writer.manifest, true, false)
	testing.expect(t, replay_ok)
	replayed := get_task(workspace, pr.WORKSPACE_DATA_ID, 10)
	testing.expect(t, replayed != nil && string(replayed.title) == "B")
}

@(test)
test_shard_segment_cleaner_adopts_append_only_raw_wal_without_copying :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-adoption")
	defer os.remove_all(data_dir)
	generation: u64 = 2
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "segment-cleaner-adoption"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	task := pr.Task {
		id      = 10,
		conv_id = 77,
		title   = transmute([]byte)string("adopted"),
	}
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
	sealed_generation := writer.manifest.active_generation
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && !result.segments.output_present && result.segments.removed_count == 1 && result.segments.raw_adopted)
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	catalog, catalog_ok := load_shard_segment_catalog(writer.storage, writer.shard_dir, writer.manifest.checkpoint_generation)
	defer destroy_shard_segment_catalog(&catalog)
	testing.expect(t, catalog_ok && len(catalog.segments) == 1)
	if catalog_ok && len(catalog.segments) == 1 {
		testing.expect(t, catalog.segments[0].kind == .Adopted_Generation_WAL)
	}
	sealed_path := shard_generation_wal_path(shard_dir, sealed_generation)
	testing.expect(t, os.exists(sealed_path))
	delete(sealed_path)
	source, source_ok := shard_segment_source_for_manifest(writer.storage, writer.shard_dir, writer.manifest)
	testing.expect(t, source_ok)
	defer destroy_shard_segment_clean_source(&source)
	output_generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
	testing.expect(t, generation_ok)
	measured := build_shard_segment_catalog(writer.storage, writer.shard_dir, writer.manifest, output_generation, &source)
	defer destroy_shard_segment_clean_result(&measured)
	testing.expect(t, measured.ok && !measured.output_present && measured.dirty_bytes == 0)
}

@(test)
test_shard_segment_cleaner_rewrites_fifty_fifty_insert_update_raw_wal :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-fifty-fifty")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 3))
	workspace := "segment-cleaner-fifty-fifty"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 3)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	for id in pr.TaskID(1) ..= 10 {
		task := pr.Task {
			id      = id,
			conv_id = 77,
			title   = transmute([]byte)string("insert"),
		}
		testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
	}
	for id in pr.TaskID(1) ..= 10 {
		task := pr.Task {
			id         = id,
			conv_id    = 77,
			title      = transmute([]byte)string("updated"),
			updated_at = 1,
		}
		testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Update, &task))
	}
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && result.segments.output_present && result.segments.raw_direct_copy_used && !result.segments.raw_adopted)
	testing.expect(t, result.segments.dirty_bytes * 100 >= result.segments.input_bytes * SHARD_SEGMENT_CLEAN_MIN_DIRTY_PERCENT)
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	shutdown_shard_transaction_writer(&writer)

	manifest, found, loaded := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, found && loaded)
	shard_replay_state_init()
	defer shard_replay_state_destroy()
	_, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
	testing.expect(t, replay_ok)
	for id in pr.TaskID(1) ..= 10 {
		task := get_task(workspace, pr.WORKSPACE_DATA_ID, id)
		testing.expect(t, task != nil && string(task.title) == "updated")
	}
}

@(test)
test_shard_segment_cleaner_measures_legacy_header_bytes_exactly :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-legacy-header")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 3))
	workspace := "segment-cleaner-legacy-header"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 3)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	task := pr.Task {
		id      = 10,
		conv_id = 77,
		title   = transmute([]byte)string("legacy"),
	}
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
	sealed_generation := writer.manifest.active_generation
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	sealed_path := shard_generation_wal_path(shard_dir, sealed_generation)
	defer delete(sealed_path)
	testing.expect(t, shard_segment_test_convert_single_record_to_legacy_header(sealed_path))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && result.segments.raw_adopted && !result.segments.raw_direct_copy_used)
}

@(test)
test_shard_raw_normalization_falls_back_when_record_metadata_is_capped :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-raw-metadata-fallback")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 6))
	workspace := "segment-cleaner-raw-metadata-fallback"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 6)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	task := pr.Task {
		id      = 10,
		conv_id = 77,
		title   = transmute([]byte)string("A"),
	}
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
	task.title = transmute([]byte)string("B")
	task.updated_at = 1
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Update, &task))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	source, source_ok := shard_segment_source_for_manifest(writer.storage, writer.shard_dir, writer.manifest)
	defer destroy_shard_segment_clean_source(&source)
	testing.expect(t, source_ok && len(source.segments) == 1)
	if !source_ok || len(source.segments) != 1 do return
	output_generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
	testing.expect(t, generation_ok)
	result := build_shard_segment_catalog(
		writer.storage,
		writer.shard_dir,
		writer.manifest,
		output_generation,
		&source,
		0,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
		1,
		true,
		writer.catalog_floors,
		1,
	)
	defer destroy_shard_segment_clean_result(&result)
	testing.expect(t, result.ok && result.output_present && result.raw_fast_path_used && !result.raw_direct_copy_used)
	testing.expect_value(t, result.metadata_fallbacks, u64(1))
	if result.ok && len(result.outputs) == 1 {
		path := shard_cleaned_segment_temp_path(shard_dir, result.outputs[0].generation)
		inspection := persistence.inspect_wal_file_strict(path, SHARD_WAL_MAGIC, shard, proc(_: u8, _: u16, _: []byte) -> bool {return true})
		delete(path)
		testing.expect(t, inspection.ok)
		// Latest task update and the floor witness.
		testing.expect_value(t, inspection.record_count, u64(2))
	}
}

@(test)
test_shard_segment_cleaner_splits_live_output_at_file_size_limit :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-split-output")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 4))
	workspace := "segment-cleaner-split-output"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 4)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	for index in 0 ..< 12 {
		task := pr.Task {
			id      = u64(index + 1),
			conv_id = 77,
			title   = transmute([]byte)string("bounded-output"),
		}
		testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
	}
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	source, source_ok := shard_segment_source_for_manifest(writer.storage, writer.shard_dir, writer.manifest)
	testing.expect(t, source_ok)
	defer destroy_shard_segment_clean_source(&source)
	generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
	testing.expect(t, generation_ok)
	result := build_shard_segment_catalog(writer.storage, writer.shard_dir, writer.manifest, generation, &source, 0, 512)
	defer destroy_shard_segment_clean_result(&result)
	testing.expect(t, result.ok && len(result.outputs) > 1)
	for output in result.outputs {
		path := shard_cleaned_segment_temp_path(writer.shard_dir, output.generation)
		file, open_err := os.open(path)
		testing.expect(t, open_err == nil)
		if file != nil {
			size, size_err := os.file_size(file)
			testing.expect(t, size_err == nil && size <= 512)
			os.close(file)
		}
		_ = os.remove(path)
		delete(path)
	}
}

@(test)
test_shard_segment_cleaner_rejects_final_dangling_edge :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-dangling-edge")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 3))
	workspace := "segment-cleaner-dangling-edge"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 3)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	task_a := pr.Task {
		id      = 1,
		conv_id = 77,
		title   = transmute([]byte)string("A"),
	}
	task_b := pr.Task {
		id      = 2,
		conv_id = 77,
		title   = transmute([]byte)string("B"),
	}
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 77,
		source_type = .Task,
		source_id   = 1,
		target_type = .Task,
		target_id   = 2,
		relation    = .Blocks,
	}
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task_a))
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task_b))
	testing.expect(t, shard_segment_test_append_edge(&writer, workspace, &edge))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	first := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&first.segments)
	testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))

	// This deliberately omits the edge cascade to model malformed durable
	// history. Raw normalization preserves the deletion exactly; the following
	// full semantic sweep must reject the dangling final graph.
	deleted, delete_ok := build_shard_task_delete_transaction(transmute([]byte)workspace, 77, 2, nil, nil, nil, writer.floors)
	testing.expect(t, delete_ok)
	if delete_ok do testing.expect(t, append_shard_transaction(&writer, &deleted.tx))
	destroy_shard_task_delete_transaction(&deleted)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && result.segments.raw_fast_path_used)
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	audit := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&audit.segments)
	testing.expect(t, !audit.ok)
}

@(test)
test_shard_raw_normalization_retains_graph_sensitive_transactions :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-retains-graph-history")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 4))
	workspace := "segment-cleaner-retains-graph-history"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 4)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	task_a := pr.Task {
		id      = 1,
		conv_id = 77,
		title   = transmute([]byte)string("A"),
	}
	task_b := pr.Task {
		id      = 2,
		conv_id = 77,
		title   = transmute([]byte)string("B"),
	}
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 77,
		source_type = .Task,
		source_id   = 1,
		target_type = .Task,
		target_id   = 2,
		relation    = .Blocks,
	}
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task_a))
	testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task_b))
	testing.expect(t, shard_segment_test_append_edge(&writer, workspace, &edge))
	deleted, delete_ok := build_shard_edge_delete_mutation(transmute([]byte)workspace, 77, 1, writer.floors)
	testing.expect(t, delete_ok)
	if delete_ok do testing.expect(t, append_shard_transaction(&writer, &deleted.tx))
	destroy_shard_mutation_transaction(&deleted)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))

	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && result.segments.raw_fast_path_used && result.segments.raw_adopted && len(result.segments.outputs) == 1)
}

@(test)
test_shard_raw_normalization_keys_entities_by_conversation :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-cleaner-conversation-key")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 5))
	workspace := "segment-cleaner-conversation-key"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 5)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	// Public IDs are worker-global; legacy rooms merge, while private records
	// with the same ID remain isolated from public data and each other.
	scopes := [?]pr.ConversationID{77, 78, pr.ConversationID(pr.DM_CONV_FLAG | 77), pr.ConversationID(pr.DM_CONV_FLAG | 78)}
	ids := [?]pr.TaskID{1, 2, 1, 1}
	for conversation_id, i in scopes {
		task := pr.Task {
			id      = ids[i],
			conv_id = conversation_id,
			title   = transmute([]byte)string("legacy record"),
		}
		testing.expect(t, shard_segment_test_append_task(&writer, workspace, .Create, &task))
	}
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && result.segments.raw_fast_path_used && result.segments.raw_adopted)
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	shutdown_shard_transaction_writer(&writer)

	manifest, found, loaded := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, found && loaded)
	shard_replay_state_init()
	defer shard_replay_state_destroy()
	_, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
	testing.expect(t, replay_ok)
	for conversation_id, i in scopes {
		expected_scope := conversation_id
		if i < 2 do expected_scope = pr.WORKSPACE_DATA_ID
		task := get_task(workspace, expected_scope, ids[i])
		testing.expect(t, task != nil)
		if task != nil do testing.expect_value(t, task.conv_id, expected_scope)
	}
	ws := get_workspace(workspace)
	conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 2)
	testing.expect(t, get_conversation(ws, 77) == nil && get_conversation(ws, 78) == nil)
}
