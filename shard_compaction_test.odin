package main

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "btree"
import hgl "hegel"
import "persistence"
import pr "protocol"
import "storage_io"

shard_compaction_manifest_roundtrip_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	shard, shard_err := hgl.draw_i64(tc, 0, LOGICAL_SHARD_COUNT - 1)
	manifest_generation, manifest_err := hgl.draw_u64(tc, 1, u64(max(i64)))
	active_generation, active_err := hgl.draw_u64(tc, 0, u64(max(i64)))
	checkpoint_present, checkpoint_present_err := hgl.draw_bool(tc)
	checkpoint_generation, checkpoint_err := hgl.draw_u64(tc, 1, u64(max(i64)))
	sealed_present, sealed_present_err := hgl.draw_bool(tc)
	sealed_generation, sealed_err := hgl.draw_u64(tc, 0, u64(max(i64)))
	if shard_err == .Stop_Test ||
	   manifest_err == .Stop_Test ||
	   active_err == .Stop_Test ||
	   checkpoint_present_err == .Stop_Test ||
	   checkpoint_err == .Stop_Test ||
	   sealed_present_err == .Stop_Test ||
	   sealed_err == .Stop_Test {
		return hgl.abort()
	}
	if shard_err != nil ||
	   manifest_err != nil ||
	   active_err != nil ||
	   checkpoint_present_err != nil ||
	   checkpoint_err != nil ||
	   sealed_present_err != nil ||
	   sealed_err != nil {
		return hgl.interesting("draw")
	}
	if sealed_present && sealed_generation == active_generation {
		sealed_generation = active_generation == max(u64) ? active_generation - 1 : active_generation + 1
	}
	manifest := Shard_Compaction_Manifest {
		shard                 = int(shard),
		manifest_generation   = manifest_generation,
		checkpoint_present    = checkpoint_present,
		checkpoint_generation = checkpoint_present ? checkpoint_generation : 0,
		sealed_present        = sealed_present,
		sealed_generation     = sealed_present ? sealed_generation : 0,
		active_generation     = active_generation,
	}
	data: [SHARD_COMPACTION_MANIFEST_SIZE]byte
	if !encode_shard_compaction_manifest(manifest, data[:]) do return hgl.interesting("encode")
	decoded, ok := decode_shard_compaction_manifest(data[:])
	if !ok || decoded != manifest do return hgl.interesting("roundtrip")
	return hgl.valid()
}

@(test)
test_shard_compaction_manifest_roundtrip_and_corruption :: proc(t: ^testing.T) {
	manifest := Shard_Compaction_Manifest {
		shard                 = 17,
		manifest_generation   = 9,
		checkpoint_present    = true,
		checkpoint_generation = 7,
		sealed_present        = true,
		sealed_generation     = 8,
		active_generation     = 9,
	}
	data: [SHARD_COMPACTION_MANIFEST_SIZE]byte
	testing.expect(t, encode_shard_compaction_manifest(manifest, data[:]))
	decoded, ok := decode_shard_compaction_manifest(data[:])
	testing.expect(t, ok)
	testing.expect_value(t, decoded, manifest)
	data[24] ~= 1
	_, corrupt_ok := decode_shard_compaction_manifest(data[:])
	testing.expect(t, !corrupt_ok)
}

@(test)
test_hegel_shard_compaction_manifest_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(shard_compaction_manifest_roundtrip_property, nil, {test_cases = 300})
	testing.expectf(t, err == nil, "shard compaction manifest roundtrip failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

shard_compaction_test_crash_writer :: proc(writer: ^Shard_Transaction_Writer) {
	persistence.simulate_wal_crash_for_test(&writer.wal)
	persistence.cleanup_init_wal_state(&writer.wal)
	discard_shard_deferred_requests(writer)
	delete(writer.durability_waiters)
	destroy_shard_segment_catalog(&writer.catalog)
	if writer.shard_dir != "" do delete(writer.shard_dir)
	writer^ = {}
}

shard_compaction_test_append_task :: proc(writer: ^Shard_Transaction_Writer, workspace: string, id: u64, title: string) -> bool {
	task := pr.Task {
		id      = id,
		conv_id = 77,
		title   = transmute([]byte)title,
		status  = .Todo,
	}
	built, ok := build_shard_task_mutation(transmute([]byte)workspace, .Create, &task, writer.floors)
	defer destroy_shard_mutation_transaction(&built)
	return ok && append_shard_transaction(writer, &built.tx)
}

shard_compaction_test_update_task :: proc(writer: ^Shard_Transaction_Writer, workspace: string, id: u64, title: string) -> bool {
	task := pr.Task {
		id         = id,
		conv_id    = 77,
		title      = transmute([]byte)title,
		status     = .Todo,
		updated_at = 1,
	}
	built, ok := build_shard_task_mutation(transmute([]byte)workspace, .Update, &task, writer.floors)
	defer destroy_shard_mutation_transaction(&built)
	return ok && append_shard_transaction(writer, &built.tx)
}

shard_compaction_test_build_result :: proc(writer: ^Shard_Transaction_Writer, prepare_active := false) -> Shard_Compaction_Result {
	checkpoint_generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
	if !generation_ok do return {}
	job_dir, clone_err := strings.clone(writer.shard_dir)
	if clone_err != nil do return {}
	job := Shard_Compaction_Job {
		owner_worker          = writer.owner_worker,
		shard                 = writer.shard,
		storage               = writer.storage,
		manifest              = writer.manifest,
		checkpoint_generation = checkpoint_generation,
		shard_dir             = job_dir,
	}
	job.source, job.source_present = shard_segment_source_for_manifest(writer.storage, writer.shard_dir, writer.manifest)
	if !job.source_present {
		delete(job_dir)
		return {}
	}
	job.clean_start, job.source_max_bytes, job.raw_backlog_priority, generation_ok = shard_compaction_cleaning_plan(
		writer.storage,
		writer.shard_dir,
		job.source,
		writer.clean_cursor,
		writer.manifest.segmented,
	)
	job.expected_source_floors = writer.catalog_floors
	if !generation_ok {
		destroy_shard_segment_clean_source(&job.source)
		delete(job_dir)
		return {}
	}
	if prepare_active && job.raw_backlog_priority {
		job.active_reservation_generation, _ = reserve_shard_active_generation(writer.storage, writer.shard_dir, checkpoint_generation)
	}
	if !writer.manifest.sealed_present do writer.compaction_floors = writer.catalog_floors
	writer.compaction = .Building
	when NRC_SIMULATION {
		return sim_run_shard_compaction_job(job)
	} else {
		return run_shard_compaction_job(job)
	}
}

shard_compaction_test_referenced_record_count :: proc(shard_dir: string, manifest: Shard_Compaction_Manifest) -> (count: u64, ok: bool) {
	paths := make([dynamic]string, 0, 4)
	defer {
		for path in paths do delete(path)
		delete(paths)
	}
	if manifest.checkpoint_present {
		if manifest.segmented {
			catalog, catalog_ok := load_shard_segment_catalog(storage_io.host_context(), shard_dir, manifest.checkpoint_generation)
			if !catalog_ok do return count, false
			defer destroy_shard_segment_catalog(&catalog)
			for descriptor in catalog.segments {
				path := shard_segment_descriptor_path(shard_dir, descriptor)
				if path == "" do return count, false
				append(&paths, path)
			}
		} else {
			append(&paths, shard_checkpoint_wal_path(shard_dir, manifest.checkpoint_generation))
		}
	}
	if manifest.sealed_present {
		append(&paths, shard_generation_wal_path(shard_dir, manifest.sealed_generation))
	}
	append(&paths, shard_generation_wal_path(shard_dir, manifest.active_generation))

	for path in paths {
		inspection := persistence.inspect_wal_file_strict(path, SHARD_WAL_MAGIC, manifest.shard, proc(_: u8, _: u16, _: []byte) -> bool {return true})
		if !inspection.ok do return count, false
		count += inspection.record_count
	}
	return count, true
}

Shard_Compaction_Expected_Task :: struct {
	id:    pr.TaskID,
	title: string,
}

shard_compaction_test_restart_tasks_are_exact :: proc(
	shard_dir: string,
	shard: int,
	workspace: string,
	expected_sealed: bool,
	expected_checkpoint: bool,
	expected_tasks: []Shard_Compaction_Expected_Task,
	expected_record_count: u64,
	expected_floors: Shard_High_Water_Requirements,
	failure: ^string = nil,
) -> bool {
	writer: Shard_Transaction_Writer
	if !init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
		if failure != nil do failure^ = "open"
		return false
	}
	defer shutdown_shard_transaction_writer(&writer)
	if writer.manifest.sealed_present != expected_sealed || writer.manifest.checkpoint_present != expected_checkpoint {
		if failure != nil do failure^ = "manifest shape"
		return false
	}
	if writer.floors != expected_floors {
		if failure != nil do failure^ = "writer floors"
		return false
	}
	record_count, records_ok := shard_compaction_test_referenced_record_count(shard_dir, writer.manifest)
	if !records_ok {
		if failure != nil do failure^ = "referenced WAL inspection"
		return false
	}
	if expected_record_count != max(u64) && record_count != expected_record_count {
		if failure != nil do failure^ = "referenced record count"
		return false
	}

	shard_replay_state_init()
	defer shard_replay_state_destroy()
	replayed_record_count: u64
	floors, replay_ok := replay_shard_compaction_sequence(shard_dir, writer.manifest, true, false, &replayed_record_count)
	if !replay_ok {
		if failure != nil do failure^ = "semantic replay"
		return false
	}
	if floors != expected_floors {
		if failure != nil do failure^ = "replayed floors"
		return false
	}
	if expected_record_count != max(u64) && replayed_record_count != expected_record_count {
		if failure != nil do failure^ = "replayed record count"
		return false
	}
	ws := get_workspace(workspace)
	if len(expected_tasks) == 0 {
		if ws != nil && failure != nil do failure^ = "unexpected workspace"
		return ws == nil
	}
	conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
	if conv == nil {
		if failure != nil do failure^ = "missing conversation"
		return false
	}
	if len(conv.tasks) != len(expected_tasks) {
		if failure != nil do failure^ = "task count"
		return false
	}
	if len(conv.task_index_keys) != len(expected_tasks) ||
	   btree.count(&conv.task_index) != len(expected_tasks) ||
	   conv.active_task_count != len(expected_tasks) {
		if failure != nil do failure^ = "task index cardinality"
		return false
	}
	if len(conv.assets) != 0 || len(conv.edges) != 0 || len(conv.edges_by_entity) != 0 {
		if failure != nil do failure^ = "asset/edge cascade state"
		return false
	}
	for expected in expected_tasks {
		task := conv.tasks[expected.id]
		if task == nil {
			if failure != nil do failure^ = "missing task"
			return false
		}
		if task.id != expected.id || task.conv_id != pr.WORKSPACE_DATA_ID || task.status != .Todo || string(task.title) != expected.title {
			if failure != nil do failure^ = "task contents"
			return false
		}
		expected_key := make_task_sort_key(task)
		key, key_ok := conv.task_index_keys[expected.id]
		if !key_ok || key != expected_key || !btree.contains(&conv.task_index, expected_key) {
			if failure != nil do failure^ = "task index contents"
			return false
		}
	}
	return true
}

shard_compaction_test_restart_is_exact :: proc(
	shard_dir: string,
	shard: int,
	workspace: string,
	expected_sealed: bool,
	expected_checkpoint: bool,
	expected_titles: []string,
	expected_record_count: u64,
	expected_floors: Shard_High_Water_Requirements,
	failure: ^string = nil,
) -> bool {
	expected_tasks := make([dynamic]Shard_Compaction_Expected_Task, 0, len(expected_titles))
	defer delete(expected_tasks)
	for title, index in expected_titles {
		append(&expected_tasks, Shard_Compaction_Expected_Task{id = pr.TaskID(10 + index), title = title})
	}
	return shard_compaction_test_restart_tasks_are_exact(
		shard_dir,
		shard,
		workspace,
		expected_sealed,
		expected_checkpoint,
		expected_tasks[:],
		expected_record_count,
		expected_floors,
		failure,
	)
}

SHARD_COMPACTION_FUZZ_PUBLICATION_FAULTS :: [11]Shard_Compaction_Fault_Point {
	.Catalog_Create,
	.Catalog_Write,
	.Catalog_Sync,
	.Catalog_Rename,
	.Catalog_Directory_Sync,
	.Manifest_Create,
	.Manifest_Write,
	.Manifest_Sync,
	.Manifest_Rename,
	.Manifest_Directory_Sync,
	.Cleanup_Directory_Sync,
}

SHARD_COMPACTION_FUZZ_UNREFERENCED_FILE_CONTENTS :: [4]string {
	"orphan WAL must remain unreferenced",
	"stale checkpoint must remain unreferenced",
	"",
	"temporary candidate must remain unreferenced",
}

shard_compaction_fuzz_failure :: proc(stage: string, point: Shard_Compaction_Fault_Point, between_count: int, shard_dir: string, detail := "") -> string {
	manifest, found, loaded := load_shard_compaction_manifest(shard_dir)
	return fmt.tprintf(
		"stage=%s detail=%s fault=%v between=%d manifest_found=%v manifest_loaded=%v manifest=%v",
		stage,
		detail,
		point,
		between_count,
		found,
		loaded,
		manifest,
	)
}

shard_compaction_fuzz_create_unreferenced_files :: proc(
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	workspace: string,
	paths: ^[4]string,
	expected_contents: ^[4][]byte,
) -> (
	orphan_wal_generation: u64,
	ok: bool,
) {
	if !manifest.checkpoint_present || manifest.checkpoint_generation <= 1 || manifest.checkpoint_generation > max(u64) - 101 do return
	orphan_wal_generation = manifest.checkpoint_generation + 1
	paths^ = {
		shard_generation_wal_path(shard_dir, orphan_wal_generation),
		shard_checkpoint_wal_path(shard_dir, manifest.checkpoint_generation - 1),
		shard_checkpoint_wal_path(shard_dir, manifest.checkpoint_generation + 100),
		shard_checkpoint_temp_path(shard_dir, manifest.checkpoint_generation + 101),
	}
	for path in paths^ do if os.exists(path) do return orphan_wal_generation, false
	for content, index in SHARD_COMPACTION_FUZZ_UNREFERENCED_FILE_CONTENTS {
		if index == 2 do continue
		if os.write_entire_file(paths^[index], transmute([]byte)content) != nil do return orphan_wal_generation, false
	}
	if os.write_entire_file(paths^[2], nil) != nil do return orphan_wal_generation, false
	detached: Shard_Transaction_Writer
	detached_open := false
	defer if detached_open do shutdown_shard_transaction_writer(&detached)
	if !init_shard_transaction_writer(&detached, paths^[2], manifest.shard, manifest.shard, LOGICAL_SHARD_COUNT) do return orphan_wal_generation, false
	detached_open = true
	if !shard_compaction_test_append_task(&detached, workspace, 9000, "unreferenced-checkpoint-sentinel") do return orphan_wal_generation, false
	persistence.force_fsync(&detached.wal)
	if !detached.wal.enabled || detached.wal.durable_record_count != 1 || !shutdown_shard_transaction_writer(&detached) {
		return orphan_wal_generation, false
	}
	detached_open = false
	for path, index in paths^ {
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil do return orphan_wal_generation, false
		expected_contents^[index] = data
	}
	return orphan_wal_generation, true
}

shard_compaction_fuzz_unreferenced_files_match :: proc(paths: ^[4]string, expected_contents: ^[4][]byte, allow_absent: bool) -> bool {
	for path, index in paths^ {
		if allow_absent && !os.exists(path) do continue
		data, read_err := os.read_entire_file(paths^[index], context.temp_allocator)
		if read_err != nil || !bytes.equal(data, expected_contents^[index]) do return false
	}
	return true
}

shard_compaction_fuzz_append_task :: proc(
	writer: ^Shard_Transaction_Writer,
	workspace: string,
	id: u64,
	expected_tasks: ^[dynamic]Shard_Compaction_Expected_Task,
) -> bool {
	title := fmt.aprintf("publication-task-%d", id)
	if !shard_compaction_test_append_task(writer, workspace, id, title) {
		delete(title)
		return false
	}
	append(expected_tasks, Shard_Compaction_Expected_Task{id = pr.TaskID(id), title = title})
	return true
}

shard_compaction_fuzz_update_task :: proc(
	writer: ^Shard_Transaction_Writer,
	workspace: string,
	id: pr.TaskID,
	expected_tasks: ^[dynamic]Shard_Compaction_Expected_Task,
) -> bool {
	expected_index := -1
	for expected, index in expected_tasks^ {
		if expected.id == id {
			expected_index = index
			break
		}
	}
	if expected_index < 0 do return false
	title := fmt.aprintf("publication-task-%d-updated", id)
	task := pr.Task {
		id      = id,
		conv_id = 77,
		title   = transmute([]byte)title,
		status  = .Todo,
	}
	built, ok := build_shard_task_mutation(transmute([]byte)workspace, .Update, &task, writer.floors)
	defer destroy_shard_mutation_transaction(&built)
	if !ok || !append_shard_transaction(writer, &built.tx) {
		delete(title)
		return false
	}
	delete(expected_tasks^[expected_index].title)
	expected_tasks^[expected_index].title = title
	return true
}

shard_compaction_fuzz_delete_task :: proc(
	writer: ^Shard_Transaction_Writer,
	workspace: string,
	id: pr.TaskID,
	expected_tasks: ^[dynamic]Shard_Compaction_Expected_Task,
) -> bool {
	expected_index := -1
	for expected, index in expected_tasks^ {
		if expected.id == id {
			expected_index = index
			break
		}
	}
	if expected_index < 0 do return false
	asset := pr.Asset {
		asset_type       = .Document,
		asset_id         = 20,
		parent_type      = .Task,
		parent_id        = u64(id),
		conv_id          = 77,
		payload_encoding = .Plain,
	}
	asset_create, asset_ok := build_shard_asset_mutation(transmute([]byte)workspace, .Create, &asset, writer.floors)
	defer destroy_shard_mutation_transaction(&asset_create)
	if !asset_ok || !append_shard_transaction(writer, &asset_create.tx) do return false

	edge := pr.Edge {
		edge_id     = 30,
		conv_id     = 77,
		source_type = .Task,
		source_id   = u64(id),
		target_type = .Asset,
		target_id   = 20,
		relation    = .References,
	}
	edge_create, edge_ok := build_shard_edge_mutation(transmute([]byte)workspace, .Create, &edge, writer.floors)
	defer destroy_shard_mutation_transaction(&edge_create)
	if !edge_ok || !append_shard_transaction(writer, &edge_create.tx) do return false

	asset_ids := [1]pr.AssetID{20}
	asset_edge_ids := [1]pr.EdgeID{30}
	cascade, cascade_ok := build_shard_task_delete_transaction(transmute([]byte)workspace, 77, id, asset_ids[:], asset_edge_ids[:], nil, writer.floors)
	defer destroy_shard_task_delete_transaction(&cascade)
	if !cascade_ok || !append_shard_transaction(writer, &cascade.tx) do return false
	delete(expected_tasks^[expected_index].title)
	ordered_remove(expected_tasks, expected_index)
	return true
}

shard_compaction_fuzz_publication_reached_manifest :: proc(point: Shard_Compaction_Fault_Point) -> bool {
	return point == .Manifest_Directory_Sync || point == .Sealed_WAL_Remove || point == .Cleanup_Directory_Sync
}

shard_compaction_fuzz_run :: proc(
	point: Shard_Compaction_Fault_Point,
	second_point: Shard_Compaction_Fault_Point,
	between_count: int,
	campaign: string,
) -> string {
	clear_shard_compaction_fault_for_test()
	defer clear_shard_compaction_fault_for_test()
	case_name := fmt.tprintf("generated-compaction-publication-%s", campaign)
	data_dir := storage_layout_test_setup(case_name)
	defer os.remove_all(data_dir)
	if !storage_layout_test_create_generation(data_dir, 1) do return "stage=setup create-generation"
	workspace := "generated-compaction-publication"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 1)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	expected_tasks := make([dynamic]Shard_Compaction_Expected_Task, 0, 8)
	defer {
		for task in expected_tasks do delete(task.title)
		delete(expected_tasks)
	}
	writer: Shard_Transaction_Writer
	writer_open := false
	defer if writer_open do shutdown_shard_transaction_writer(&writer)
	if !init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
		return shard_compaction_fuzz_failure("open-initial", point, between_count, shard_dir)
	}
	writer_open = true
	if !shard_compaction_fuzz_append_task(&writer, workspace, 10, &expected_tasks) ||
	   !rotate_shard_writer_for_compaction(&writer) ||
	   !shard_compaction_fuzz_append_task(&writer, workspace, 11, &expected_tasks) ||
	   !rotate_shard_writer_for_compaction(&writer) {
		return shard_compaction_fuzz_failure("prepare-first-generation", point, between_count, shard_dir)
	}
	persistence.force_fsync(&writer.wal)
	if !writer.wal.enabled || writer.wal.durable_record_count != 0 {
		return shard_compaction_fuzz_failure("sync-first-active", point, between_count, shard_dir)
	}
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	if !result.ok do return shard_compaction_fuzz_failure("build-first-checkpoint", point, between_count, shard_dir)
	set_shard_compaction_fault_for_test(point)
	published := publish_shard_compaction_result(&writer, result)
	triggered := shard_compaction_fault_triggered_for_test()
	clear_shard_compaction_fault_for_test()
	if !triggered do return shard_compaction_fuzz_failure("fault-not-triggered", point, between_count, shard_dir)
	expected_publish_return := point == .Sealed_WAL_Remove || point == .Cleanup_Directory_Sync
	if published != expected_publish_return || writer.poisoned != (point == .Manifest_Directory_Sync) {
		return shard_compaction_fuzz_failure("faulted-publication-result", point, between_count, shard_dir)
	}
	shard_compaction_test_crash_writer(&writer)
	writer_open = false

	restart_failure: string
	if !shard_compaction_test_restart_tasks_are_exact(shard_dir, shard, workspace, false, true, expected_tasks[:], max(u64), {task = 11}, &restart_failure) {
		return shard_compaction_fuzz_failure("reopen-after-fault", point, between_count, shard_dir, restart_failure)
	}

	if !init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
		return shard_compaction_fuzz_failure("open-for-retry", point, between_count, shard_dir)
	}
	writer_open = true
	if writer.compaction == .Sealed {
		retry := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&retry.segments)
		if !retry.ok || !publish_shard_compaction_result(&writer, retry) {
			return shard_compaction_fuzz_failure("retry-first-publication", point, between_count, shard_dir)
		}
	}
	if writer.compaction != .Idle || writer.manifest.sealed_present || !writer.manifest.checkpoint_present {
		return shard_compaction_fuzz_failure("first-publication-not-idle", point, between_count, shard_dir)
	}
	unreferenced_paths: [4]string
	defer for path in unreferenced_paths do if path != "" do delete(path)
	unreferenced_contents: [4][]byte
	defer for content in unreferenced_contents do if content != nil do delete(content)
	orphan_wal_generation, unreferenced_ok := shard_compaction_fuzz_create_unreferenced_files(
		shard_dir,
		writer.manifest,
		workspace,
		&unreferenced_paths,
		&unreferenced_contents,
	)
	if !unreferenced_ok || !shard_compaction_fuzz_unreferenced_files_match(&unreferenced_paths, &unreferenced_contents, false) {
		return shard_compaction_fuzz_failure("inject-unreferenced-files", point, between_count, shard_dir)
	}
	if !shard_compaction_fuzz_update_task(&writer, workspace, 10, &expected_tasks) ||
	   !shard_compaction_fuzz_delete_task(&writer, workspace, 11, &expected_tasks) {
		return shard_compaction_fuzz_failure("semantic-update-cascade", point, between_count, shard_dir)
	}

	next_id: u64 = 12
	for _ in 0 ..< between_count {
		if !shard_compaction_fuzz_append_task(&writer, workspace, next_id, &expected_tasks) {
			return shard_compaction_fuzz_failure("append-between-generations", point, between_count, shard_dir)
		}
		next_id += 1
	}
	if !rotate_shard_writer_for_compaction(&writer) ||
	   writer.manifest.active_generation != orphan_wal_generation + 1 ||
	   !shard_compaction_fuzz_append_task(&writer, workspace, next_id, &expected_tasks) {
		return shard_compaction_fuzz_failure("prepare-second-generation", point, between_count, shard_dir)
	}
	next_id += 1
	persistence.force_fsync(&writer.wal)
	if !writer.wal.enabled || writer.wal.durable_record_count != 1 {
		return shard_compaction_fuzz_failure("sync-second-active", point, between_count, shard_dir)
	}
	second := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&second.segments)
	if !second.ok {
		return shard_compaction_fuzz_failure("build-second-generation", second_point, between_count, shard_dir)
	}
	if !shard_compaction_fuzz_unreferenced_files_match(&unreferenced_paths, &unreferenced_contents, false) {
		return shard_compaction_fuzz_failure("unreferenced-files-before-second-publication", second_point, between_count, shard_dir)
	}
	set_shard_compaction_fault_for_test(second_point)
	second_published := publish_shard_compaction_result(&writer, second)
	second_triggered := shard_compaction_fault_triggered_for_test()
	clear_shard_compaction_fault_for_test()
	if !second_triggered {
		return shard_compaction_fuzz_failure("second-fault-not-triggered", second_point, between_count, shard_dir)
	}
	second_expected_publish_return := second_point == .Sealed_WAL_Remove || second_point == .Cleanup_Directory_Sync
	if second_published != second_expected_publish_return || writer.poisoned != (second_point == .Manifest_Directory_Sync) {
		return shard_compaction_fuzz_failure("second-faulted-publication-result", second_point, between_count, shard_dir)
	}
	shard_compaction_test_crash_writer(&writer)
	writer_open = false
	restart_failure = ""
	if !shard_compaction_test_restart_tasks_are_exact(
		shard_dir,
		shard,
		workspace,
		false,
		true,
		expected_tasks[:],
		max(u64),
		{task = next_id - 1, asset = 20, edge = 30},
		&restart_failure,
	) {
		return shard_compaction_fuzz_failure("reopen-second-generation", second_point, between_count, shard_dir, restart_failure)
	}
	if !shard_compaction_fuzz_unreferenced_files_match(&unreferenced_paths, &unreferenced_contents, true) {
		return shard_compaction_fuzz_failure("unreferenced-files-after-second-reopen", second_point, between_count, shard_dir)
	}

	if !init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
		return shard_compaction_fuzz_failure("open-for-second-retry", second_point, between_count, shard_dir)
	}
	writer_open = true
	if writer.compaction == .Sealed {
		retry := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&retry.segments)
		if !retry.ok || !publish_shard_compaction_result(&writer, retry) {
			return shard_compaction_fuzz_failure("retry-second-publication", second_point, between_count, shard_dir)
		}
	}
	if writer.compaction != .Idle || writer.manifest.sealed_present || !writer.manifest.checkpoint_present {
		return shard_compaction_fuzz_failure("second-publication-not-idle", second_point, between_count, shard_dir)
	}
	if !shard_compaction_fuzz_unreferenced_files_match(&unreferenced_paths, &unreferenced_contents, true) {
		return shard_compaction_fuzz_failure("unreferenced-files-after-second-retry", second_point, between_count, shard_dir)
	}
	if !shard_compaction_fuzz_append_task(&writer, workspace, next_id, &expected_tasks) {
		return shard_compaction_fuzz_failure("continued-write", second_point, between_count, shard_dir)
	}
	persistence.force_fsync(&writer.wal)
	if !writer.wal.enabled || writer.wal.durable_record_count != 2 {
		return shard_compaction_fuzz_failure("sync-continued-write", second_point, between_count, shard_dir)
	}
	shard_compaction_test_crash_writer(&writer)
	writer_open = false
	restart_failure = ""
	if !shard_compaction_test_restart_tasks_are_exact(
		shard_dir,
		shard,
		workspace,
		false,
		true,
		expected_tasks[:],
		max(u64),
		{task = next_id, asset = 20, edge = 30},
		&restart_failure,
	) {
		return shard_compaction_fuzz_failure("final-reopen", second_point, between_count, shard_dir, restart_failure)
	}
	if !shard_compaction_fuzz_unreferenced_files_match(&unreferenced_paths, &unreferenced_contents, true) {
		return shard_compaction_fuzz_failure("unreferenced-files-after-final-reopen", second_point, between_count, shard_dir)
	}
	return ""
}

shard_compaction_publication_history_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	fault_index, fault_err := hgl.draw_i64(tc, 0, len(SHARD_COMPACTION_FUZZ_PUBLICATION_FAULTS) - 1)
	if fault_err == .Stop_Test do return hgl.abort()
	if fault_err != nil do return hgl.interesting("draw first compaction publication fault")
	second_fault_index, second_fault_err := hgl.draw_i64(tc, 0, len(SHARD_COMPACTION_FUZZ_PUBLICATION_FAULTS) - 1)
	if second_fault_err == .Stop_Test do return hgl.abort()
	if second_fault_err != nil do return hgl.interesting("draw second compaction publication fault")
	between_count, count_err := hgl.draw_i64(tc, 1, 3)
	if count_err == .Stop_Test do return hgl.abort()
	if count_err != nil do return hgl.interesting("draw writes between compaction generations")
	points := SHARD_COMPACTION_FUZZ_PUBLICATION_FAULTS
	point := points[fault_index]
	second_point := points[second_fault_index]
	diagnostic := shard_compaction_fuzz_run(point, second_point, int(between_count), "hegel")
	if diagnostic != "" {
		return hgl.interesting(fmt.tprintf("first_fault=%v second_fault=%v %s", point, second_point, diagnostic))
	}
	return hgl.valid()
}

@(test)
test_hegel_shard_compaction_repeated_publication_history :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	previous_logger := context.logger
	context.logger = log.nil_logger()
	result, err := hgl.run(shard_compaction_publication_history_property, nil, {test_cases = 48, database_key = "shard-compaction-repeated-publication-v3"})
	context.logger = previous_logger
	testing.expectf(t, err == nil, "repeated compaction publication property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_shard_compaction_repeated_publication_fault_coverage :: proc(t: ^testing.T) {
	previous_logger := context.logger
	points := SHARD_COMPACTION_FUZZ_PUBLICATION_FAULTS
	for point, first_index in points {
		for second_point, second_index in points {
			between_count := (first_index + second_index) % 3 + 1
			// Suppress expected storage errors, never testing.expect* failures.
			context.logger = log.nil_logger()
			diagnostic := shard_compaction_fuzz_run(point, second_point, between_count, "matrix")
			context.logger = previous_logger
			testing.expectf(
				t,
				diagnostic == "",
				"repeated publication first=%v second=%v between=%d failed: %s",
				point,
				second_point,
				between_count,
				diagnostic,
			)
		}
	}
}

@(test)
test_shard_checkpoint_floor_witness_routes_to_every_logical_shard :: proc(t: ^testing.T) {
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		witness := shard_checkpoint_floor_witness(shard)
		testing.expectf(t, witness != "", "missing floor witness for shard %d", shard)
		if witness == "" do continue
		testing.expect_value(t, int(shard_for_workspace(transmute([]byte)witness)), shard)
		delete(witness)
	}
}

@(test)
test_shard_compaction_rotation_fault_matrix_restarts_from_durable_manifest :: proc(t: ^testing.T) {
	previous_logger := context.logger
	points := [?]Shard_Compaction_Fault_Point {
		.Sealed_WAL_Sync,
		.New_Active_Create,
		.New_Active_Sync,
		.New_Active_Directory_Sync,
		.Catalog_Create,
		.Catalog_Write,
		.Catalog_Sync,
		.Catalog_Rename,
		.Catalog_Directory_Sync,
		.Manifest_Create,
		.Manifest_Write,
		.Manifest_Sync,
		.Manifest_Rename,
		.Manifest_Directory_Sync,
	}
	for point, case_index in points {
		data_dir := storage_layout_test_setup(fmt.tprintf("shard-rotation-fault-%d", case_index))
		defer os.remove_all(data_dir)
		generation: u64 = 1
		testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
		workspace := fmt.tprintf("shard-rotation-fault-workspace-%d", case_index)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
		shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)

		writer: Shard_Transaction_Writer
		testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "before-rotation"))
		set_shard_compaction_fault_for_test(point)
		context.logger = log.nil_logger()
		rotated := rotate_shard_writer_for_compaction(&writer)
		context.logger = previous_logger
		testing.expect(t, !rotated)
		testing.expect(t, shard_compaction_fault_triggered_for_test())
		clear_shard_compaction_fault_for_test()
		expected_poisoned := point == .Sealed_WAL_Sync || point == .Manifest_Directory_Sync
		testing.expect_value(t, writer.poisoned, expected_poisoned)
		shard_compaction_test_crash_writer(&writer)

		published := point == .Manifest_Directory_Sync
		testing.expect(t, shard_compaction_test_restart_is_exact(shard_dir, shard, workspace, false, published, []string{"before-rotation"}, 1, {task = 10}))
	}
}

@(test)
test_shard_checkpoint_cleanup_failure_leaves_unreferenced_old_checkpoint :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("shard-old-checkpoint-cleanup-fault")
	defer os.remove_all(data_dir)
	generation: u64 = 1
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "shard-old-checkpoint-cleanup-fault"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first-checkpoint"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	first_checkpoint_generation := writer.manifest.checkpoint_generation
	first_checkpoint_path := shard_segment_catalog_path(shard_dir, first_checkpoint_generation)
	defer delete(first_checkpoint_path)
	testing.expect(t, os.exists(first_checkpoint_path))

	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "second-checkpoint"))
	set_shard_compaction_fault_for_test(.Old_Checkpoint_Remove)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect(t, shard_compaction_fault_triggered_for_test())
	clear_shard_compaction_fault_for_test()
	testing.expect(t, os.exists(first_checkpoint_path))
	shard_compaction_test_crash_writer(&writer)

	testing.expect(
		t,
		shard_compaction_test_restart_is_exact(
			shard_dir,
			shard,
			workspace,
			false,
			true,
			[]string{"first-checkpoint", "second-checkpoint"},
			max(u64),
			{task = 11},
		),
	)
	manifest, found, loaded := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, found && loaded)
	testing.expect(t, manifest.checkpoint_generation != first_checkpoint_generation)
}

@(test)
test_shard_checkpoint_publication_fault_matrix_restarts_without_loss_or_duplication :: proc(t: ^testing.T) {
	points := [?]Shard_Compaction_Fault_Point {
		.Catalog_Create,
		.Catalog_Write,
		.Catalog_Sync,
		.Catalog_Rename,
		.Catalog_Directory_Sync,
		.Manifest_Create,
		.Manifest_Write,
		.Manifest_Sync,
		.Manifest_Rename,
		.Manifest_Directory_Sync,
		.Cleanup_Directory_Sync,
	}
	for point, case_index in points {
		data_dir := storage_layout_test_setup(fmt.tprintf("shard-publish-fault-%d", case_index))
		defer os.remove_all(data_dir)
		generation: u64 = 1
		testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
		workspace := fmt.tprintf("shard-publish-fault-workspace-%d", case_index)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
		shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)

		writer: Shard_Transaction_Writer
		testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "sealed"))
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "active"))
		persistence.force_fsync(&writer.wal)
		result := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&result.segments)
		testing.expect(t, result.ok)

		set_shard_compaction_fault_for_test(point)
		published := publish_shard_compaction_result(&writer, result)
		testing.expect(t, shard_compaction_fault_triggered_for_test())
		clear_shard_compaction_fault_for_test()
		testing.expect_value(t, published, point == .Sealed_WAL_Remove || point == .Cleanup_Directory_Sync)
		testing.expect_value(t, writer.poisoned, point == .Manifest_Directory_Sync)
		shard_compaction_test_crash_writer(&writer)

		testing.expect(
			t,
			shard_compaction_test_restart_is_exact(shard_dir, shard, workspace, false, true, []string{"sealed", "active"}, max(u64), {task = 11}),
		)
	}
}

@(test)
test_shard_cleaned_segment_publication_faults_keep_old_catalog_authoritative :: proc(t: ^testing.T) {
	points := [?]Shard_Compaction_Fault_Point{.Checkpoint_Rename, .Checkpoint_Directory_Sync}
	for point, case_index in points {
		data_dir := storage_layout_test_setup(fmt.tprintf("shard-cleaned-publish-fault-%d", case_index))
		defer os.remove_all(data_dir)
		testing.expect(t, storage_layout_test_create_generation(data_dir, 1))
		workspace := fmt.tprintf("shard-cleaned-publish-fault-workspace-%d", case_index)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		generation_dir := sharded_generation_path(data_dir, 1); defer delete(generation_dir)
		shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)

		writer: Shard_Transaction_Writer
		testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first"))
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
		first := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&first.segments)
		testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "second"))
		testing.expect(t, shard_compaction_test_update_task(&writer, workspace, 11, "second-updated"))
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
		result := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&result.segments)
		testing.expect(t, result.ok && result.segments.output_present)

		set_shard_compaction_fault_for_test(point)
		testing.expect(t, !publish_shard_compaction_result(&writer, result))
		testing.expect(t, shard_compaction_fault_triggered_for_test())
		clear_shard_compaction_fault_for_test()
		shard_compaction_test_crash_writer(&writer)
		testing.expect(
			t,
			shard_compaction_test_restart_is_exact(shard_dir, shard, workspace, false, true, []string{"first", "second-updated"}, max(u64), {task = 11}),
		)
	}
}

@(test)
test_shard_checkpoint_build_disk_faults_leave_sealed_manifest_replayable :: proc(t: ^testing.T) {
	points := [?]Shard_Compaction_Fault_Point{.Checkpoint_Write, .Checkpoint_Sync}
	for point, case_index in points {
		data_dir := storage_layout_test_setup(fmt.tprintf("shard-build-disk-fault-%d", case_index))
		defer os.remove_all(data_dir)
		generation: u64 = 1
		testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
		workspace := fmt.tprintf("shard-build-disk-fault-workspace-%d", case_index)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
		shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)

		writer: Shard_Transaction_Writer
		testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "durable-before-build-failure"))
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
		first := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&first.segments)
		testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "durable-second-segment"))
		testing.expect(t, shard_compaction_test_update_task(&writer, workspace, 11, "durable-second-segment-updated"))
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
		set_shard_compaction_fault_for_test(point)
		result := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&result.segments)
		testing.expect(t, !result.ok)
		testing.expect(t, shard_compaction_fault_triggered_for_test())
		clear_shard_compaction_fault_for_test()
		testing.expect(t, writer.compaction == .Building && !writer.poisoned)
		temp_path := shard_cleaned_segment_temp_path(shard_dir, writer.manifest.manifest_generation + 1)
		testing.expect(t, !os.exists(temp_path))
		delete(temp_path)
		shard_compaction_test_crash_writer(&writer)

		testing.expect(
			t,
			shard_compaction_test_restart_is_exact(
				shard_dir,
				shard,
				workspace,
				false,
				true,
				[]string{"durable-before-build-failure", "durable-second-segment-updated"},
				max(u64),
				{task = 11},
			),
		)
	}
}

@(test)
test_shard_compaction_rotates_builds_checkpoint_and_preserves_new_active_writes :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("shard-compaction-cycle")
	defer os.remove_all(data_dir)
	generation: u64 = 7
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "shard-compaction-cycle"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect(t, writer.manifest.segmented && !writer.manifest.sealed_present)
	testing.expect_value(t, writer.catalog_segments, 1)

	// A single roll is immediately authoritative; restart does not need to
	// reconstruct an in-flight sealed state.
	shutdown_shard_transaction_writer(&writer)
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	testing.expect(t, writer.compaction == .Idle && !writer.manifest.sealed_present)
	testing.expect_value(t, writer.catalog_segments, 1)
	testing.expect_value(t, writer.catalog_floors.task, u64(10))

	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "second"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect_value(t, writer.catalog_segments, 2)
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && result.segments.raw_adopted)

	// Rotation remains independent while the cleaner owns its older snapshot.
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 12, "during-build"))
	appended_generation := writer.manifest.active_generation
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect(t, writer.compaction == .Building)
	testing.expect_value(t, writer.catalog_segments, 3)
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	testing.expect(t, writer.compaction == .Idle && !writer.manifest.sealed_present)

	catalog, catalog_ok := load_shard_segment_catalog(writer.storage, writer.shard_dir, writer.manifest.checkpoint_generation)
	defer destroy_shard_segment_catalog(&catalog)
	testing.expect(t, catalog_ok && len(catalog.segments) == 3)
	if catalog_ok && len(catalog.segments) == 3 {
		testing.expect(t, catalog.segments[0].kind == .Generation_WAL)
		testing.expect(t, catalog.segments[1].kind == .Adopted_Generation_WAL)
		testing.expect_value(t, catalog.segments[2], Shard_Segment_Descriptor{.Generation_WAL, appended_generation})
	}
	next := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&next.segments)
	testing.expect(t, next.ok && next.segments.removed_count == 1)
	if len(next.segments.removed) == 1 {
		testing.expect_value(t, next.segments.removed[0], Shard_Segment_Descriptor{.Generation_WAL, appended_generation})
	}
	testing.expect(t, publish_shard_compaction_result(&writer, next))
	shutdown_shard_transaction_writer(&writer)

	shard_replay_state_init()
	defer shard_replay_state_destroy()
	manifest, found, loaded := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, found && loaded)
	floors, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
	testing.expect(t, replay_ok)
	testing.expect_value(t, floors.task, u64(12))
	for id in u64(10) ..= 12 do testing.expect(t, get_task(workspace, pr.WORKSPACE_DATA_ID, id) != nil)
}

@(test)
test_shard_compaction_normalizes_raw_backlog_newest_first :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("compaction-newest-raw-first")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "compaction-newest-raw-first"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	for id in u64(10) ..= 12 {
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, id, "raw backlog"))
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	}
	testing.expect_value(t, writer.catalog_segments, 3)
	raw_generations := [3]u64{writer.catalog.segments[0].generation, writer.catalog.segments[1].generation, writer.catalog.segments[2].generation}

	for expected_start := 2; expected_start >= 0; expected_start -= 1 {
		result := shard_compaction_test_build_result(&writer)
		testing.expect(t, result.ok && result.segments.raw_adopted && result.segments.raw_fast_path_used)
		testing.expect_value(t, result.segments.removed_start, expected_start)
		testing.expect_value(t, result.segments.removed_count, 1)
		if len(result.segments.removed) == 1 {
			testing.expect_value(t, result.segments.removed[0], Shard_Segment_Descriptor{.Generation_WAL, raw_generations[expected_start]})
		}
		testing.expect_value(t, result.segments.next_cursor, 0)
		testing.expect(t, publish_shard_compaction_result(&writer, result))
		destroy_shard_segment_clean_result(&result.segments)
		testing.expect_value(t, writer.clean_cursor, 0)
		testing.expect_value(t, writer.clean_sweep_generation, writer.manifest.checkpoint_generation)
	}
	testing.expect_value(t, writer.clean_backlog_bytes, u64(0))
	testing.expect_value(t, writer.raw_catalog_segments, 0)
	testing.expect(t, !shard_writer_catalog_cleaning_ready(&writer))
	for descriptor in writer.catalog.segments do testing.expect(t, descriptor.kind == .Adopted_Generation_WAL)

	// Empty raw generations still use exact one-member selection even though
	// their byte size cannot serve as a group boundary.
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	empty_generation := writer.catalog.segments[len(writer.catalog.segments) - 1].generation
	empty := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&empty.segments)
	testing.expect(t, empty.ok && empty.segments.raw_fast_path_used && !empty.segments.output_present && empty.segments.removed_count == 1)
	if len(empty.segments.removed) == 1 {
		testing.expect_value(t, empty.segments.removed[0], Shard_Segment_Descriptor{.Generation_WAL, empty_generation})
	}
	testing.expect(t, publish_shard_compaction_result(&writer, empty))
}

@(test)
test_shard_compaction_update_invalidates_append_only_sweep :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("compaction-update-invalidates-append-only")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "compaction-update-invalidates-append-only"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "created"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	created := shard_compaction_test_build_result(&writer)
	testing.expect(t, created.ok && created.segments.raw_append_only)
	testing.expect(t, publish_shard_compaction_result(&writer, created))
	destroy_shard_segment_clean_result(&created.segments)
	testing.expect(t, !shard_writer_catalog_cleaning_ready(&writer))

	testing.expect(t, shard_compaction_test_update_task(&writer, workspace, 10, "updated"))
	testing.expect(t, !writer.active_wal_append_only)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect_value(t, writer.clean_sweep_generation, u64(0))
	updated := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&updated.segments)
	testing.expect(t, updated.ok && updated.segments.raw_adopted && !updated.segments.raw_append_only)
	testing.expect(t, publish_shard_compaction_result(&writer, updated))
	testing.expect_value(t, writer.raw_catalog_segments, 0)
	testing.expect(t, shard_writer_catalog_cleaning_ready(&writer))
}

@(test)
test_shard_compaction_consumes_background_prepared_active_wal :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("compaction-prepared-active")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "compaction-prepared-active"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))

	result := shard_compaction_test_build_result(&writer, true)
	defer destroy_shard_compaction_result(&result, false)
	testing.expect(t, result.ok && result.active_reservation_prepared)
	reserved_generation := result.active_reservation_generation
	testing.expect(t, reserved_generation > writer.manifest.active_generation)
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	testing.expect(t, accept_shard_active_reservation(&writer, result))
	testing.expect_value(t, writer.prepared_active_generation, reserved_generation)

	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "second"))
	set_shard_compaction_fault_for_test(.New_Active_Sync)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect(t, !shard_compaction_fault_triggered_for_test())
	clear_shard_compaction_fault_for_test()
	testing.expect_value(t, writer.manifest.active_generation, reserved_generation)
	testing.expect_value(t, writer.prepared_active_generation, u64(0))
}

@(test)
test_shard_compaction_discards_prepared_active_wal_after_later_rotation :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("compaction-stale-prepared-active")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "compaction-stale-prepared-active"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer, true)
	defer destroy_shard_compaction_result(&result, false)
	testing.expect(t, result.ok && result.active_reservation_prepared)
	reserved_generation := result.active_reservation_generation
	reserved_path := shard_generation_wal_path(shard_dir, reserved_generation)
	defer delete(reserved_path)
	testing.expect(t, os.exists(reserved_path))

	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "second"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	testing.expect(t, shard_writer_authoritative_generation(&writer) > reserved_generation)
	testing.expect(t, accept_shard_active_reservation(&writer, result))
	testing.expect_value(t, writer.prepared_active_generation, u64(0))
	testing.expect(t, !os.exists(reserved_path))
}

@(test)
test_shard_compaction_non_append_rotation_invalidates_in_flight_append_adoption :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("compaction-non-append-overlap")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "compaction-non-append-overlap"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)

	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	first := shard_compaction_test_build_result(&writer)
	testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))
	destroy_shard_segment_clean_result(&first.segments)
	testing.expect(t, !shard_writer_catalog_cleaning_ready(&writer))

	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "second"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	in_flight := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&in_flight.segments)
	testing.expect(t, in_flight.ok && in_flight.segments.raw_append_only)
	testing.expect(t, shard_compaction_test_update_task(&writer, workspace, 10, "updated-during-build"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect_value(t, writer.clean_sweep_generation, u64(0))
	testing.expect(t, publish_shard_compaction_result(&writer, in_flight))
	testing.expect_value(t, writer.clean_sweep_generation, u64(0))

	newer := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&newer.segments)
	testing.expect(t, newer.ok && newer.segments.raw_adopted && !newer.segments.raw_append_only)
	testing.expect(t, publish_shard_compaction_result(&writer, newer))
	testing.expect_value(t, writer.clean_cursor, 0)
	testing.expect_value(t, writer.clean_sweep_generation, u64(0))
	testing.expect(t, shard_writer_catalog_cleaning_ready(&writer))

	ordinary := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&ordinary.segments)
	testing.expect(t, ordinary.ok && !ordinary.segments.raw_fast_path_used)
	testing.expect_value(t, ordinary.segments.removed_start, 0)
}

@(test)
test_shard_compaction_restart_conservatively_invalidates_create_only_active_wal :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("compaction-restart-create-only-active")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "compaction-restart-create-only-active"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "before-restart"))
	testing.expect(t, writer.active_wal_append_only)
	shutdown_shard_transaction_writer(&writer)

	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	testing.expect(t, !writer.active_wal_append_only)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok && result.segments.raw_append_only)
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	testing.expect_value(t, writer.clean_sweep_generation, u64(0))
	testing.expect(t, shard_writer_catalog_cleaning_ready(&writer))
}

@(test)
test_shard_compaction_noop_scan_keeps_progress_across_later_rotation :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("compaction-noop-progress")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "compaction-noop-progress"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "clean"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	first := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&first.segments)
	testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))

	noop := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&noop.segments)
	testing.expect(t, noop.ok && !noop.segments.output_present && noop.segments.next_cursor == 1)
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "new tail"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	testing.expect_value(t, writer.catalog_segments, 2)
	testing.expect(t, publish_shard_compaction_result(&writer, noop))
	testing.expect_value(t, writer.clean_cursor, 1)
	testing.expect_value(t, writer.clean_sweep_generation, u64(0))
}

@(test)
test_shard_compaction_manifest_rejects_corrupt_or_missing_references :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("shard-compaction-manifest-references")
	defer os.remove_all(data_dir)
	generation: u64 = 9
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "shard-compaction-manifest-references"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	shutdown_shard_transaction_writer(&writer)
	active_path := shard_generation_wal_path(shard_dir, 0); defer delete(active_path)
	testing.expect(t, os.remove(active_path) == nil)
	_, missing_found, missing_ok := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, missing_found && !missing_ok)
	testing.expect(t, os.write_entire_file(active_path, nil) == nil)

	manifest_path := shard_compaction_manifest_path(shard_dir); defer delete(manifest_path)
	data, read_err := os.read_entire_file(manifest_path, context.temp_allocator)
	testing.expect(t, read_err == nil && len(data) == SHARD_COMPACTION_MANIFEST_SIZE)
	if len(data) == SHARD_COMPACTION_MANIFEST_SIZE {
		data[16] ~= 1
		testing.expect(t, os.write_entire_file(manifest_path, data) == nil)
	}
	_, corrupt_found, corrupt_ok := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, corrupt_found && !corrupt_ok)
}

@(test)
test_shard_checkpoint_preserves_floors_after_every_entity_is_deleted :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("shard-compaction-deleted-state")
	defer os.remove_all(data_dir)
	generation: u64 = 8
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "shard-compaction-deleted-state"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	asset_ids := []pr.AssetID{20}
	edge_ids := []pr.EdgeID{30}
	deleted, delete_ok := build_shard_task_delete_transaction(transmute([]byte)workspace, 77, 10, asset_ids, edge_ids, nil, writer.floors)
	testing.expect(t, delete_ok)
	if delete_ok do testing.expect(t, append_shard_transaction(&writer, &deleted.tx))
	destroy_shard_task_delete_transaction(&deleted)
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	// A second immutable member makes the catalog eligible for cleaning.
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result := shard_compaction_test_build_result(&writer)
	defer destroy_shard_segment_clean_result(&result.segments)
	testing.expect(t, result.ok)
	testing.expect_value(t, result.floors, Shard_High_Water_Requirements{task = 10, asset = 20, edge = 30})
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	destroy_shard_segment_clean_result(&result.segments)
	// Raw backlog is normalized newest-first. A later empty generation is
	// handled before the older generation containing the tombstones.
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	result = shard_compaction_test_build_result(&writer)
	testing.expect(t, result.ok)
	testing.expect_value(t, result.floors, Shard_High_Water_Requirements{task = 10, asset = 20, edge = 30})
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	destroy_shard_segment_clean_result(&result.segments)
	for writer.clean_backlog_bytes > 0 {
		result = shard_compaction_test_build_result(&writer)
		testing.expect(t, result.ok)
		testing.expect_value(t, result.floors, Shard_High_Water_Requirements{task = 10, asset = 20, edge = 30})
		testing.expect(t, publish_shard_compaction_result(&writer, result))
		destroy_shard_segment_clean_result(&result.segments)
	}
	// Raw normalization preserves graph-sensitive history exactly. The ordinary
	// semantic sweep performs cross-segment deduplication and removes the now
	// obsolete create transaction.
	result = shard_compaction_test_build_result(&writer)
	testing.expect(t, result.ok && !result.segments.raw_fast_path_used)
	testing.expect_value(t, result.floors, Shard_High_Water_Requirements{task = 10, asset = 20, edge = 30})
	testing.expect(t, publish_shard_compaction_result(&writer, result))
	destroy_shard_segment_clean_result(&result.segments)
	shutdown_shard_transaction_writer(&writer)

	manifest, found, loaded := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, found && loaded)
	catalog, catalog_ok := load_shard_segment_catalog(storage_io.host_context(), shard_dir, manifest.checkpoint_generation)
	defer destroy_shard_segment_catalog(&catalog)
	testing.expect(t, catalog_ok && len(catalog.segments) > 0)
	record_count: u64
	if catalog_ok {
		for descriptor in catalog.segments {
			testing.expect(t, descriptor.kind == .Cleaned_Segment)
			checkpoint_path := shard_segment_descriptor_path(shard_dir, descriptor)
			inspection := persistence.inspect_wal_file_strict(checkpoint_path, SHARD_WAL_MAGIC, shard, proc(_: u8, _: u16, _: []byte) -> bool {return true})
			delete(checkpoint_path)
			testing.expect(t, inspection.ok)
			record_count += inspection.record_count
		}
	}
	testing.expect(t, record_count >= 2)
	shard_replay_state_init(); defer shard_replay_state_destroy()
	floors, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
	testing.expect(t, replay_ok)
	testing.expect_value(t, floors, result.floors)
	testing.expect_value(t, len(td.workspaces), 0)
	replayed_workspace := get_workspace(workspace)
	testing.expect(t, replayed_workspace == nil)
	if replayed_workspace != nil {
		replayed_conv := get_conversation(replayed_workspace, pr.WORKSPACE_DATA_ID)
		testing.expect(t, replayed_conv == nil)
		if replayed_conv != nil {
			testing.expect(t, replayed_conv.tasks[10] == nil)
			testing.expect(t, replayed_conv.assets[20] == nil)
			testing.expect(t, replayed_conv.edges[30] == nil)
		}
	}
}

@(test)
test_shard_checkpoint_verification_includes_complete_live_asset_state :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("shard-checkpoint-live-asset-digest")
	defer os.remove_all(data_dir)
	generation: u64 = 1
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "shard-checkpoint-live-asset-digest"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	checkpoint_path := shard_checkpoint_wal_path(shard_dir, 1)
	defer delete(checkpoint_path)
	output_path := shard_checkpoint_temp_path(shard_dir, 2)
	defer delete(output_path)

	testing.expect(t, os.write_entire_file(checkpoint_path, nil) == nil)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, checkpoint_path, shard, shard, LOGICAL_SHARD_COUNT))
	attachments := [1]pr.Attachment {
		{
			file_id = transmute([]byte)string("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
			filename = transmute([]byte)string("checkpoint.txt"),
			size = 4242,
			mime_type = transmute([]byte)string("text/plain"),
			uploaded_at = 123456789,
		},
	}
	asset := pr.Asset {
		asset_type       = .Document,
		asset_id         = 20,
		parent_type      = .None,
		owner            = transmute([]byte)string("checkpoint-owner"),
		created_at       = 111,
		updated_at       = 222,
		conv_id          = 77,
		payload_encoding = .Plain,
		payload_raw_len  = 15,
		preview          = transmute([]byte)string("asset-preview"),
		payload          = transmute([]byte)string("asset-body-data"),
		attachments      = attachments[:],
	}
	built, built_ok := build_shard_asset_mutation(transmute([]byte)workspace, .Create, &asset, writer.floors)
	testing.expect(t, built_ok)
	if built_ok do testing.expect(t, append_shard_transaction(&writer, &built.tx))
	destroy_shard_mutation_transaction(&built)
	testing.expect(t, shutdown_shard_transaction_writer(&writer))

	manifest := Shard_Compaction_Manifest {
		shard                 = shard,
		manifest_generation   = 2,
		checkpoint_present    = true,
		checkpoint_generation = 1,
		active_generation     = 0,
	}
	floors, verified := build_and_verify_shard_checkpoint(shard_dir, manifest, output_path)
	testing.expect(t, verified)
	testing.expect_value(t, floors, Shard_High_Water_Requirements{asset = 20})

	shard_replay_state_init()
	defer shard_replay_state_destroy()
	inspection, candidate_floors, replay_ok := replay_shard_transaction_wal(output_path, shard)
	testing.expect(t, replay_ok)
	// The asset transaction is followed by the explicit high-water witness.
	testing.expect_value(t, inspection.record_count, u64(2))
	testing.expect_value(t, candidate_floors, floors)
	replayed_workspace := get_workspace(workspace)
	testing.expect(t, replayed_workspace != nil)
	if replayed_workspace == nil do return
	replayed_conv := get_conversation(replayed_workspace, pr.WORKSPACE_DATA_ID)
	testing.expect(t, replayed_conv != nil)
	if replayed_conv == nil do return
	replayed := replayed_conv.assets[20]
	testing.expect(t, replayed != nil)
	if replayed == nil do return
	testing.expect_value(t, replayed.asset_type, asset.asset_type)
	testing.expect_value(t, replayed.parent_type, asset.parent_type)
	testing.expect_value(t, replayed.parent_id, asset.parent_id)
	testing.expect(t, bytes.equal(replayed.owner, asset.owner))
	testing.expect_value(t, replayed.created_at, asset.created_at)
	testing.expect_value(t, replayed.updated_at, asset.updated_at)
	testing.expect_value(t, replayed.payload_encoding, asset.payload_encoding)
	testing.expect_value(t, replayed.payload_raw_len, asset.payload_raw_len)
	testing.expect(t, bytes.equal(replayed.preview, asset.preview))
	testing.expect(t, bytes.equal(replayed.payload, asset.payload))
	testing.expect_value(t, len(replayed.attachments), 1)
	if len(replayed.attachments) == 1 {
		testing.expect(t, bytes.equal(replayed.attachments[0].file_id, attachments[0].file_id))
		testing.expect(t, bytes.equal(replayed.attachments[0].filename, attachments[0].filename))
		testing.expect_value(t, replayed.attachments[0].size, attachments[0].size)
		testing.expect(t, bytes.equal(replayed.attachments[0].mime_type, attachments[0].mime_type))
		testing.expect_value(t, replayed.attachments[0].uploaded_at, attachments[0].uploaded_at)
	}

	baseline_digest := shard_checkpoint_state_digest(shard)
	replayed.updated_at += 1
	testing.expect(t, shard_checkpoint_state_digest(shard) != baseline_digest)
	replayed.updated_at -= 1
	replayed.owner[0] ~= 1
	testing.expect(t, shard_checkpoint_state_digest(shard) != baseline_digest)
	replayed.owner[0] ~= 1
	if len(replayed.attachments) == 1 {
		replayed.attachments[0].size += 1
		testing.expect(t, shard_checkpoint_state_digest(shard) != baseline_digest)
		replayed.attachments[0].size -= 1
	}
	testing.expect_value(t, shard_checkpoint_state_digest(shard), baseline_digest)
}

@(test)
test_shard_tail_recovery_rejects_complete_corrupt_record :: proc(t: ^testing.T) {
	path := test_wal_path("shard-complete-corrupt-tail.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-complete-corrupt-tail"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	shutdown_shard_transaction_writer(&writer)

	corrupt: [persistence.LOG_HEADER_SIZE]byte
	file, open_err := os.open(path, {.Write, .Append})
	testing.expect(t, open_err == nil)
	if open_err == nil {
		written, write_err := os.write(file, corrupt[:])
		testing.expect(t, write_err == nil && written == len(corrupt))
		os.close(file)
	}
	before, _ := os.open(path)
	before_size, _ := os.file_size(before)
	os.close(before)
	testing.expect(t, !init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	after, _ := os.open(path)
	after_size, _ := os.file_size(after)
	os.close(after)
	testing.expect_value(t, after_size, before_size)
}

@(test)
test_shard_tail_recovery_rejects_corrupt_record_length :: proc(t: ^testing.T) {
	path := test_wal_path("shard-corrupt-tail-length.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-corrupt-tail-length"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	shutdown_shard_transaction_writer(&writer)

	data, read_err := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil && len(data) > persistence.LOG_HEADER_SIZE)
	if len(data) > persistence.LOG_HEADER_SIZE {
		endian.put_u32(data[8:], .Big, max(u32))
		testing.expect(t, os.write_entire_file(path, data) == nil)
	}
	before_size := len(data)
	delete(data)
	testing.expect(t, !init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	after, _ := os.open(path)
	after_size, _ := os.file_size(after)
	os.close(after)
	testing.expect_value(t, after_size, i64(before_size))
	replayed := persistence.replay_wal(path, SHARD_WAL_MAGIC, shard, proc(_: u8, _: u16, _: []byte) -> bool {return true})
	testing.expect(t, !replayed.ok)
	after_replay, _ := os.open(path)
	after_replay_size, _ := os.file_size(after_replay)
	os.close(after_replay)
	testing.expect_value(t, after_replay_size, i64(before_size))
}

@(test)
test_shard_sweep_metrics_accumulate_and_classify_runs :: proc(t: ^testing.T) {
	writer: Shard_Transaction_Writer
	ordinary := Shard_Segment_Clean_Result {
		ok                     = true,
		input_bytes            = 100,
		dirty_bytes            = 20,
		prefix_read_bytes      = 1,
		latest_read_bytes      = 2,
		measure_read_bytes     = 3,
		copy_read_bytes        = 4,
		replay_read_bytes      = 5,
		metadata_fallbacks     = 6,
		metadata_written_bytes = 7,
	}
	record_shard_sweep_metrics(&writer, ordinary)
	raw := ordinary
	raw.raw_fast_path_used = true
	record_shard_sweep_metrics(&writer, raw)
	testing.expect_value(t, writer.sweep_metrics.runs, u64(2))
	testing.expect_value(t, writer.sweep_metrics.ordinary_runs, u64(1))
	testing.expect_value(t, writer.sweep_metrics.raw_runs, u64(1))
	testing.expect_value(t, writer.sweep_metrics.input_bytes, u64(200))
	testing.expect_value(t, writer.sweep_metrics.replay_read_bytes, u64(10))
	testing.expect_value(t, writer.sweep_metrics.metadata_fallbacks, u64(12))
	testing.expect_value(t, writer.sweep_metrics.metadata_written_bytes, u64(14))
}
