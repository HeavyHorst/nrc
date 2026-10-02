package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"

import hgl "hegel"
import "persistence"
import "storage_io"

when !NRC_SIMULATION {
	_ :: fmt.tprintf
	_ :: log.nil_logger
	_ :: strings.clone
	_ :: hgl.run
	_ :: persistence.force_fsync
	_ :: storage_io.Context
}

when NRC_SIMULATION {
	GENERATED_SEMANTIC_FAULT_MAX_PENDING_RECORDS :: 12
	GENERATED_SEMANTIC_FAULT_STABLE_RECORDS :: 4
	GENERATED_SEMANTIC_FAULT_OP_KINDS :: [6]Generated_Shard_Op_Kind{.Create_Task, .Update_Task, .Move_Task, .Create_Asset, .Update_Asset, .Create_Edge}
	GENERATED_SEMANTIC_FAULT_FOUNDATION_V1 :: [GENERATED_SEMANTIC_FAULT_STABLE_RECORDS]Generated_Shard_Op {
		{kind = .Create_Task},
		{kind = .Create_Asset},
		{kind = .Create_Asset, selector = 1},
		{kind = .Create_Edge},
	}

	Generated_Semantic_Fault_Choice :: struct {
		durable_count: int,
		cut_len:       int,
		drawn:         bool,
	}

	Generated_Semantic_Fault_Fixture :: struct {
		scope:       string,
		workspace:   string,
		stable_end:  int,
		op_count:    int,
		ops:         [GENERATED_SEMANTIC_FAULT_MAX_PENDING_RECORDS]Generated_Shard_Op,
		record_ends: [GENERATED_SEMANTIC_FAULT_MAX_PENDING_RECORDS]int,
		models:      [GENERATED_SEMANTIC_FAULT_MAX_PENDING_RECORDS + 1]Generated_Shard_Model,
	}

	Generated_Compaction_Interruption :: enum u8 {
		Clean,
		Crash_Before_Job,
		Crash_Before_Result,
		Fail_Stop_Job,
		Fail_Stop_Result,
		Fail_Stop_Rotation_Effect_1,
		Fail_Stop_Rotation_Effect_2,
		Fail_Stop_Rotation_Effect_3,
		Fail_Stop_Rotation_Effect_4,
		Fail_Stop_Rotation_Effect_5,
		Fail_Stop_Rotation_Effect_6,
		Fail_Stop_Rotation_Effect_7,
		Fail_Stop_Rotation_Effect_8,
		Fail_Stop_Rotation_Effect_9,
	}

	GENERATED_GLOBAL_GRAPH_WORKLOAD_KINDS :: [?]Generated_Shard_Op_Kind {
		.Create_Task,
		.Update_Task,
		.Move_Task,
		.Query_Tasks_Paged,
		.Create_Asset,
		.Create_Slice,
		.Create_File,
		.Create_Customer,
		.Create_Contact,
		.Update_Asset,
		.Query_Assets_Paged,
		.Create_Edge,
		.Create_Membership,
		.Query_Slices,
		.Query_Graph,
		.Delete_Asset,
		.Delete_Task,
		.Delete_Edge,
	}

	generated_compaction_rotation_effect :: proc(choice: Generated_Compaction_Interruption) -> (int, bool) {
		if choice < .Fail_Stop_Rotation_Effect_1 || choice > .Fail_Stop_Rotation_Effect_9 do return 0, false
		return int(choice) - int(Generated_Compaction_Interruption.Fail_Stop_Rotation_Effect_1) + 1, true
	}

	generated_semantic_fault_fixture_destroy :: proc(fixture: ^Generated_Semantic_Fault_Fixture) {
		fixture^ = {}
	}

	generated_semantic_virtual_storage_prepare :: proc(world: ^Sim_World, shard_dir: string) -> (storage_io.Context, bool) {
		if world == nil do return {}, false
		storage := sim_world_storage_context(world)
		if storage_io.make_directory(storage, shard_dir) != nil do return {}, false
		if storage_io.sync_directory(storage, "/") != nil do return {}, false
		active_path := shard_generation_wal_path(shard_dir, 0)
		defer delete(active_path)
		active, open_err := storage_io.open(storage, active_path, {.Write, .Create, .Excl})
		if open_err != nil do return {}, false
		sync_err := storage_io.sync(active)
		close_err := storage_io.close(active)
		if sync_err != nil || close_err != nil do return {}, false
		return storage, true
	}

	generated_semantic_virtual_storage_init :: proc(world: ^Sim_World, shard_dir: string) -> (storage_io.Context, bool) {
		if !sim_world_init(world) do return {}, false
		return generated_semantic_virtual_storage_prepare(world, shard_dir)
	}

	generated_semantic_fault_fixture_init :: proc(fixture: ^Generated_Semantic_Fault_Fixture, pending_ops: []Generated_Shard_Op, scope: string) -> bool {
		fixture^ = {}
		if scope == "" || len(pending_ops) == 0 || len(pending_ops) > GENERATED_SEMANTIC_FAULT_MAX_PENDING_RECORDS do return false
		fixture.scope = scope
		fixture.workspace = "generated-semantic-persistence-fault"
		fixture.op_count = len(pending_ops)
		copy(fixture.ops[:], pending_ops)
		workspace := transmute([]byte)fixture.workspace
		shard := int(shard_for_workspace(workspace))
		shard_dir := "/shard"
		world: Sim_World
		storage, storage_ok := generated_semantic_virtual_storage_init(&world, shard_dir)
		if !storage_ok {
			sim_world_destroy(&world)
			return false
		}
		defer sim_world_destroy(&world)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, shard)
		defer simulation_test_end(&ctx)
		writer: Shard_Transaction_Writer
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) do return false
		defer shutdown_shard_transaction_writer(&writer)

		model: Generated_Shard_Model
		stable_ops := GENERATED_SEMANTIC_FAULT_FOUNDATION_V1
		for op in stable_ops {
			if !generated_shard_apply_op(&model, &writer, workspace, shard_dir, op) do return false
		}
		persistence.force_fsync(&writer.wal)
		if writer.wal.durable_record_count != GENERATED_SEMANTIC_FAULT_STABLE_RECORDS do return false
		stable_size, stable_size_err := storage_io.file_size(writer.wal.file)
		if stable_size_err != nil do return false
		fixture.stable_end = int(stable_size)
		fixture.models[0] = model

		previous_end := fixture.stable_end
		for op, op_index in pending_ops {
			if !generated_shard_apply_op(&model, &writer, workspace, shard_dir, op) do return false
			size, size_err := storage_io.file_size(writer.wal.file)
			if size_err != nil || int(size) <= previous_end do return false
			fixture.record_ends[op_index] = int(size)
			fixture.models[op_index + 1] = model
			previous_end = int(size)
		}
		if writer.wal.record_count != u64(GENERATED_SEMANTIC_FAULT_STABLE_RECORDS + len(pending_ops)) ||
		   writer.wal.durable_record_count != GENERATED_SEMANTIC_FAULT_STABLE_RECORDS {
			return false
		}
		return true
	}

	generated_semantic_virtual_process_discard :: proc(writer: ^Shard_Transaction_Writer) {
		persistence.simulate_wal_crash_for_test(&writer.wal)
		persistence.cleanup_init_wal_state(&writer.wal)
		discard_shard_deferred_requests(writer)
		delete(writer.durability_waiters)
		destroy_shard_segment_catalog(&writer.catalog)
		if writer.shard_dir != "" do delete(writer.shard_dir)
		writer^ = {}
	}

	generated_semantic_fault_execute :: proc(
		tc: ^hgl.Test_Case,
		fixture: ^Generated_Semantic_Fault_Fixture,
		durable_count: int,
		cut_len: int,
	) -> hgl.Body_Result {
		if durable_count < 0 || durable_count > fixture.op_count {
			return hgl.interesting("semantic durable-prefix choice is out of range")
		}
		stable_end := fixture.stable_end
		if durable_count > 0 do stable_end = fixture.record_ends[durable_count - 1]
		if durable_count == fixture.op_count {
			if cut_len != 0 do return hgl.interesting("complete semantic history cannot have a torn-record cut")
		} else {
			next_end := fixture.record_ends[durable_count]
			if cut_len < 0 || cut_len >= next_end - stable_end {
				return hgl.interesting("semantic torn-record cut is out of range")
			}
		}

		shard_dir := "/shard"
		world: Sim_World
		storage, storage_ok := generated_semantic_virtual_storage_init(&world, shard_dir)
		if !storage_ok {
			sim_world_destroy(&world)
			return hgl.interesting("semantic virtual storage initialization failed")
		}
		defer sim_world_destroy(&world)
		active_path := shard_generation_wal_path(shard_dir, 0)
		defer delete(active_path)

		ctx: Sim_Test_Context
		workspace := transmute([]byte)fixture.workspace
		shard := int(shard_for_workspace(workspace))
		simulation_test_begin(&ctx, shard)
		defer simulation_test_end(&ctx)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		defer {context.logger = previous_logger}
		writer: Shard_Transaction_Writer
		defer if writer.wal.enabled || writer.shard_dir != "" do shutdown_shard_transaction_writer(&writer)
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return hgl.interesting("semantic initial writer initialization failed")
		}
		model: Generated_Shard_Model
		for op in GENERATED_SEMANTIC_FAULT_FOUNDATION_V1 {
			if !generated_shard_apply_op(&model, &writer, workspace, shard_dir, op) {
				return hgl.interesting("semantic foundation transaction failed")
			}
		}
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != GENERATED_SEMANTIC_FAULT_STABLE_RECORDS {
			return hgl.interesting("semantic foundation fsync failed")
		}
		for op_index in 0 ..< durable_count {
			if !generated_shard_apply_op(&model, &writer, workspace, shard_dir, fixture.ops[op_index]) {
				return hgl.interesting("semantic durable transaction failed")
			}
			persistence.force_fsync(&writer.wal)
			if !writer.wal.enabled do return hgl.interesting("semantic durable transaction fsync failed")
		}
		if durable_count < fixture.op_count {
			if !generated_shard_apply_op(&model, &writer, workspace, shard_dir, fixture.ops[durable_count]) {
				return hgl.interesting("semantic pending transaction failed")
			}
		}
		generated_semantic_virtual_process_discard(&writer)
		sim_world_crash(&world, active_path, cut_len)
		storage = sim_world_storage_context(&world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return hgl.interesting("semantic recovery writer initialization failed")
		}
		if !generated_shard_restore_state(&writer) do return hgl.interesting("semantic durable-prefix replay failed")
		expected := fixture.models[durable_count]
		if compare_reason, equal := generated_shard_compare(&expected, fixture.workspace, writer.floors); !equal {
			if tc != nil do hgl.note(tc, compare_reason)
			return hgl.interesting("semantic recovered state differs from durable model prefix")
		}
		expected_end := fixture.stable_end
		if durable_count > 0 do expected_end = fixture.record_ends[durable_count - 1]
		recovered_size, size_err := storage_io.file_size(writer.wal.file)
		if size_err != nil || recovered_size != i64(expected_end) {
			return hgl.interesting("semantic recovery did not truncate torn transaction tail")
		}
		expected_record_count := u64(GENERATED_SEMANTIC_FAULT_STABLE_RECORDS + durable_count)
		if writer.wal.record_count != expected_record_count || writer.wal.durable_record_count != expected_record_count {
			return hgl.interesting("semantic recovered WAL head differs from durable model prefix")
		}
		if !generated_shard_create_task(&expected, &writer, workspace) {
			return hgl.interesting("semantic recovery rejected subsequent transaction")
		}
		if compare_reason, equal := generated_shard_compare(&expected, fixture.workspace, writer.floors); !equal {
			if tc != nil do hgl.note(tc, compare_reason)
			return hgl.interesting("semantic post-recovery transaction diverged from model")
		}
		post_append_size, post_append_size_err := storage_io.file_size(writer.wal.file)
		if post_append_size_err != nil || post_append_size <= recovered_size || writer.wal.record_count != expected_record_count + 1 {
			return hgl.interesting("semantic post-recovery transaction did not advance WAL")
		}
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
			return hgl.interesting("semantic post-recovery transaction fsync failed")
		}
		generated_semantic_virtual_process_discard(&writer)
		sim_world_crash(&world)
		storage = sim_world_storage_context(&world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) || !generated_shard_restore_state(&writer) {
			return hgl.interesting("semantic post-recovery transaction was not replayable")
		}
		if compare_reason, equal := generated_shard_compare(&expected, fixture.workspace, writer.floors); !equal {
			if tc != nil do hgl.note(tc, compare_reason)
			return hgl.interesting("semantic post-recovery replay diverged from model")
		}
		return hgl.valid()
	}

	generated_semantic_fault_case :: proc(
		tc: ^hgl.Test_Case,
		fixture: ^Generated_Semantic_Fault_Fixture,
		choice: ^Generated_Semantic_Fault_Choice,
	) -> hgl.Body_Result {
		durable_count_raw, durable_err := hgl.draw_i64(tc, 0, i64(fixture.op_count))
		if durable_err == .Stop_Test do return hgl.abort()
		if durable_err != nil do return hgl.interesting("semantic durable-prefix draw failed")
		durable_count := int(durable_count_raw)
		stable_end := fixture.stable_end
		if durable_count > 0 do stable_end = fixture.record_ends[durable_count - 1]
		cut_len := 0
		if durable_count < fixture.op_count {
			next_end := fixture.record_ends[durable_count]
			cut_raw, cut_err := hgl.draw_i64(tc, 0, i64(next_end - stable_end - 1))
			if cut_err == .Stop_Test do return hgl.abort()
			if cut_err != nil do return hgl.interesting("semantic torn-record cut draw failed")
			cut_len = int(cut_raw)
		}
		choice^ = {
			durable_count = durable_count,
			cut_len       = cut_len,
			drawn         = true,
		}
		return generated_semantic_fault_execute(tc, fixture, durable_count, cut_len)
	}

	generated_semantic_fixed_fault_property :: proc(tc: ^hgl.Test_Case, user_data: rawptr) -> hgl.Body_Result {
		choice: Generated_Semantic_Fault_Choice
		return generated_semantic_fault_case(tc, cast(^Generated_Semantic_Fault_Fixture)user_data, &choice)
	}

	generated_semantic_fault_log_replay_v1 :: proc(ops: []Generated_Shard_Op, choice: Generated_Semantic_Fault_Choice, reason: string) {
		fmt.eprintf("generated semantic persistence fault: reason=%s\n", reason)
		fmt.eprintf("Foundation v1 (applied before pending_ops):\n")
		fmt.eprintf("foundation_ops := [?]Generated_Shard_Op {{\n")
		for op, index in GENERATED_SEMANTIC_FAULT_FOUNDATION_V1 {
			fmt.eprintf("\t// %d\n\t{{kind = .%v, selector = %d}},\n", index, op.kind, op.selector)
		}
		fmt.eprintf("}}\n")
		fmt.eprintf("pending_ops := [?]Generated_Shard_Op {{\n")
		for op, index in ops {
			fmt.eprintf("\t// %d\n\t{{kind = .%v, selector = %d}},\n", index, op.kind, op.selector)
		}
		fmt.eprintf("}}\n")
		fmt.eprintf("generated_semantic_fault_replay_v1(t, foundation_ops[:], pending_ops[:], %d, %d)\n", choice.durable_count, choice.cut_len)
	}

	generated_semantic_fault_replay_v1 :: proc(
		t: ^testing.T,
		foundation_ops: []Generated_Shard_Op,
		pending_ops: []Generated_Shard_Op,
		durable_count: int,
		cut_len: int,
	) {
		expected_foundation := GENERATED_SEMANTIC_FAULT_FOUNDATION_V1
		foundation_matches := len(foundation_ops) == len(expected_foundation)
		if foundation_matches {
			for op, index in foundation_ops {
				if op != expected_foundation[index] {
					foundation_matches = false
					break
				}
			}
		}
		testing.expect(t, foundation_matches, "semantic fault replay requires the v1 foundation")
		if !foundation_matches do return
		fixture: Generated_Semantic_Fault_Fixture
		testing.expect(t, generated_semantic_fault_fixture_init(&fixture, pending_ops, "replay-v1"), "semantic fault replay fixture should initialize")
		defer generated_semantic_fault_fixture_destroy(&fixture)
		result := generated_semantic_fault_execute(nil, &fixture, durable_count, cut_len)
		testing.expectf(t, result.status == .Valid, "semantic fault replay failed: %s", result.origin)
	}

	generated_semantic_history_fault_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count_raw, op_count_err := hgl.draw_i64(tc, 1, GENERATED_SEMANTIC_FAULT_MAX_PENDING_RECORDS)
		if op_count_err == .Stop_Test do return hgl.abort()
		if op_count_err != nil do return hgl.interesting("semantic history operation-count draw failed")
		op_count := int(op_count_raw)
		ops: [GENERATED_SEMANTIC_FAULT_MAX_PENDING_RECORDS]Generated_Shard_Op
		kinds := GENERATED_SEMANTIC_FAULT_OP_KINDS
		for op_index in 0 ..< op_count {
			kind_index, kind_err := hgl.draw_i64(tc, 0, len(kinds) - 1)
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("semantic history operation-kind draw failed")
			selector, selector_err := hgl.draw_u64(tc, 0, 255)
			if selector_err == .Stop_Test do return hgl.abort()
			if selector_err != nil do return hgl.interesting("semantic history selector draw failed")
			ops[op_index] = {
				kind     = kinds[kind_index],
				selector = selector,
			}
		}

		fixture: Generated_Semantic_Fault_Fixture
		if !generated_semantic_fault_fixture_init(&fixture, ops[:op_count], "generated") {
			if tc.is_final {
				generated_semantic_fault_log_replay_v1(ops[:op_count], {}, "semantic fault fixture initialization")
			}
			return hgl.interesting("generated semantic fault fixture initialization failed")
		}
		defer generated_semantic_fault_fixture_destroy(&fixture)
		choice: Generated_Semantic_Fault_Choice
		result := generated_semantic_fault_case(tc, &fixture, &choice)
		if result.status == .Interesting && tc.is_final && choice.drawn {
			generated_semantic_fault_log_replay_v1(ops[:op_count], choice, result.origin)
		}
		return result
	}

	virtual_rotation_crash_window_run :: proc(
		point: Shard_Compaction_Fault_Point,
		persist_uncertain_rename := false,
		fail_stop_after_effect := 0,
		effect_count_out: ^int = nil,
	) -> string {
		if persist_uncertain_rename && point != .Manifest_Directory_Sync {
			return "uncertain manifest persistence requires the directory-sync boundary"
		}
		if fail_stop_after_effect < 0 || (fail_stop_after_effect > 0 && point != .None) {
			return "virtual rotation fail-stop selector is invalid"
		}
		shard_dir := "/shard"
		world: Sim_World
		storage, storage_ok := generated_semantic_virtual_storage_init(&world, shard_dir)
		if !storage_ok {
			sim_world_destroy(&world)
			return "virtual rotation storage initialization failed"
		}
		defer sim_world_destroy(&world)

		workspace_id := "virtual-rotation-crash-window"
		workspace := transmute([]byte)workspace_id
		shard := int(shard_for_workspace(workspace))
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, shard)
		defer simulation_test_end(&ctx)
		defer shard_replay_state_destroy()
		writer: Shard_Transaction_Writer
		defer if writer.wal.enabled || writer.shard_dir != "" do shutdown_shard_transaction_writer(&writer)
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return "virtual rotation writer initialization failed"
		}
		initial_manifest := writer.manifest
		model: Generated_Shard_Model
		if !generated_shard_create_task(&model, &writer, workspace) {
			return "virtual rotation semantic append failed"
		}
		candidate_generation, candidate_ok := shard_compaction_next_file_generation(storage, shard_dir, initial_manifest)
		if !candidate_ok {
			return "virtual rotation could not select candidate generation"
		}
		candidate_path := shard_generation_wal_path(shard_dir, candidate_generation)
		defer delete(candidate_path)

		using_fail_stop := fail_stop_after_effect > 0
		if using_fail_stop do storage_io.virtual_set_fail_stop_after_effect_for_test(&world.storage, fail_stop_after_effect)
		effects_before_rotation := world.storage.effect_count
		if point != .None do set_shard_compaction_fault_for_test(point)
		previous_logger := context.logger
		context.logger = point == .Sealed_WAL_Sync ? log.nil_logger() : previous_logger
		rotated := rotate_shard_writer_for_compaction(&writer)
		context.logger = previous_logger
		pending_became_durable := point != .Sealed_WAL_Sync
		if effect_count_out != nil do effect_count_out^ = world.storage.effect_count - effects_before_rotation
		triggered := shard_compaction_fault_triggered_for_test()
		clear_shard_compaction_fault_for_test()
		if using_fail_stop {
			if !storage_io.virtual_fail_stop_triggered_for_test(&world.storage) {
				return "virtual rotation did not reach selected storage-effect fail-stop"
			}
		} else if rotated != (point == .None) || (point != .None && !triggered) {
			return "virtual rotation fault did not reach expected boundary"
		}
		if !using_fail_stop {
			expected_poisoned := point == .Sealed_WAL_Sync || point == .Manifest_Directory_Sync
			if writer.poisoned != expected_poisoned {
				return "virtual rotation poison outcome differed"
			}
		}

		generated_semantic_virtual_process_discard(&writer)
		if persist_uncertain_rename && storage_io.sync_directory(storage, shard_dir) != nil {
			return "virtual rotation could not select durable uncertain rename outcome"
		}
		sim_world_crash(&world)
		storage = sim_world_storage_context(&world)
		candidate_survived, candidate_exists_err := storage_io.exists(storage, candidate_path)
		if candidate_exists_err != nil {
			return "virtual rotation could not inspect candidate after crash"
		}
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return "virtual rotation recovery writer initialization failed"
		}
		expected_manifest := initial_manifest
		expected_manifest.manifest_generation += 1
		expected_manifest.checkpoint_present = true
		expected_manifest.checkpoint_generation = candidate_generation
		expected_manifest.sealed_present = false
		expected_manifest.sealed_generation = 0
		expected_manifest.active_generation = candidate_generation
		expected_manifest.segmented = true
		publication_survives := writer.manifest == expected_manifest
		if writer.manifest != initial_manifest && !publication_survives {
			return "virtual rotation recovered neither legal manifest authority"
		}
		if (!using_fail_stop && point == .None || persist_uncertain_rename) && !publication_survives {
			return "successful virtual rotation catalog manifest was not durable"
		}
		if publication_survives {
			if writer.manifest.sealed_present ||
			   !writer.manifest.checkpoint_present ||
			   !writer.manifest.segmented ||
			   writer.manifest.checkpoint_generation != candidate_generation ||
			   !candidate_survived {
				return "successful virtual rotation segmented authority differed"
			}
		}
		if !generated_shard_restore_state(&writer) {
			return "virtual rotation durable state did not replay"
		}
		durable_model: Generated_Shard_Model
		if pending_became_durable do durable_model = model
		if reason, equal := generated_shard_compare(&durable_model, workspace_id, writer.floors); !equal {
			_ = reason
			return "virtual rotation replay differed from semantic model"
		}

		if !publication_survives {
			expected_retry_generation := candidate_generation
			if candidate_survived do expected_retry_generation += 1
			if !rotate_shard_writer_for_compaction(&writer) ||
			   writer.manifest.sealed_present ||
			   !writer.manifest.checkpoint_present ||
			   !writer.manifest.segmented ||
			   writer.manifest.checkpoint_generation != expected_retry_generation ||
			   writer.manifest.active_generation != expected_retry_generation {
				return "virtual rotation retry did not skip leftovers and publish"
			}
			if candidate_survived {
				orphan_still_exists, orphan_exists_err := storage_io.exists(storage, candidate_path)
				if orphan_exists_err != nil ||
				   !orphan_still_exists ||
				   writer.manifest.active_generation == candidate_generation ||
				   writer.manifest.checkpoint_generation == candidate_generation {
					return "virtual rotation retry made a surviving orphan authoritative"
				}
			}
		}

		post_retry_active_generation := writer.manifest.active_generation
		post_retry_active_path := shard_generation_wal_path(shard_dir, post_retry_active_generation)
		defer delete(post_retry_active_path)
		if writer.wal.path != post_retry_active_path {
			return "virtual rotation writer was not attached to post-retry active WAL"
		}
		active_size_before, size_before_err := storage_io.file_size(writer.wal.file)
		if size_before_err != nil {
			return "virtual rotation could not inspect post-retry active WAL"
		}
		if !generated_shard_create_task(&durable_model, &writer, workspace) {
			return "virtual rotation post-retry active WAL rejected continued write"
		}
		if writer.manifest.active_generation != post_retry_active_generation {
			return "virtual rotation continued write changed active generation"
		}
		active_size_after, size_after_err := storage_io.file_size(writer.wal.file)
		if size_after_err != nil || active_size_after <= active_size_before {
			return "virtual rotation continued write did not extend post-retry active WAL"
		}
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
			return "virtual rotation post-retry continued write did not become durable"
		}
		generated_semantic_virtual_process_discard(&writer)
		sim_world_crash(&world)
		storage = sim_world_storage_context(&world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return "virtual rotation continued-write writer did not reopen"
		}
		if !generated_shard_restore_state(&writer) do return "virtual rotation continued-write replay failed"
		if reason, equal := generated_shard_compare(&durable_model, workspace_id, writer.floors); !equal {
			_ = reason
			return "virtual rotation second restart differed from semantic model"
		}
		return ""
	}

	Virtual_Segment_Publication_Cycle :: enum u8 {
		Adoption,
		Retained_Prefix_Cleaning,
	}

	virtual_segment_publication_effect_run :: proc(
		cycle: Virtual_Segment_Publication_Cycle,
		fail_stop_after_effect := 0,
	) -> (
		diagnostic: string,
		effect_count: int,
	) {
		if fail_stop_after_effect < 0 do return "negative segment-publication effect boundary", 0
		shard_dir := "/shard"
		world: Sim_World
		storage, storage_ok := generated_semantic_virtual_storage_init(&world, shard_dir)
		if !storage_ok {
			sim_world_destroy(&world)
			return "segment-publication virtual storage initialization failed", 0
		}
		defer sim_world_destroy(&world)

		workspace_id := "virtual-segment-publication-effects"
		workspace := transmute([]byte)workspace_id
		shard := int(shard_for_workspace(workspace))
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, shard)
		defer simulation_test_end(&ctx)
		defer shard_replay_state_destroy()
		writer: Shard_Transaction_Writer
		defer if writer.wal.enabled || writer.shard_dir != "" do shutdown_shard_transaction_writer(&writer)
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return "segment-publication writer initialization failed", 0
		}
		model: Generated_Shard_Model
		if !generated_shard_create_task(&model, &writer, workspace) || !rotate_shard_writer_for_compaction(&writer) {
			return "segment-publication first immutable WAL preparation failed", 0
		}

		retained_prefix: Shard_Segment_Descriptor
		cleanup_paths: [2]string
		defer for path in cleanup_paths do if path != "" do delete(path)
		if cycle == .Retained_Prefix_Cleaning {
			// Offline compaction owns its replay state; release the live fixture first.
			shard_replay_state_destroy()
			first := shard_compaction_test_build_result(&writer)
			first_published := first.ok && publish_shard_compaction_result(&writer, first)
			destroy_shard_segment_clean_result(&first.segments)
			second := shard_compaction_test_build_result(&writer)
			second_published := second.ok && publish_shard_compaction_result(&writer, second)
			destroy_shard_segment_clean_result(&second.segments)
			if !first_published ||
			   !second_published ||
			   !generated_shard_restore_state(&writer) ||
			   !generated_shard_apply_op(&model, &writer, workspace, shard_dir, {kind = .Update_Task}) ||
			   !generated_shard_apply_op(&model, &writer, workspace, shard_dir, {kind = .Update_Task}) ||
			   !rotate_shard_writer_for_compaction(&writer) {
				return "retained-prefix cleaning preparation failed", 0
			}
			prefix_catalog, prefix_ok := load_shard_segment_catalog(writer.storage, writer.shard_dir, writer.manifest.checkpoint_generation)
			defer destroy_shard_segment_catalog(&prefix_catalog)
			if !prefix_ok || len(prefix_catalog.segments) != 2 {
				return "retained-prefix catalog fixture has wrong shape", 0
			}
			retained_prefix = prefix_catalog.segments[0]
			cleanup_paths[0] = shard_segment_catalog_path(writer.shard_dir, writer.manifest.checkpoint_generation)
			cleanup_paths[1] = shard_segment_descriptor_path(writer.shard_dir, prefix_catalog.segments[1])
		}

		shard_replay_state_destroy()
		writer.compaction = .Building
		boundary := fail_stop_after_effect > 0 ? fail_stop_after_effect : max(int)
		storage_io.virtual_set_fail_stop_after_effect_for_test(&world.storage, boundary)
		effects_before_publication := world.storage.effect_count
		result := shard_compaction_test_build_result(&writer)
		defer destroy_shard_segment_clean_result(&result.segments)
		if !result.ok && (cap(result.segments.catalog.segments) != 0 || cap(result.segments.removed) != 0 || cap(result.segments.outputs) != 0) {
			return "failed segment build returned owning allocations", world.storage.effect_count - effects_before_publication
		}
		published := result.ok && publish_shard_compaction_result(&writer, result)
		effect_count = world.storage.effect_count - effects_before_publication
		if fail_stop_after_effect == 0 && (!result.ok || !published) {
			return "segment-publication baseline did not complete", effect_count
		}
		if fail_stop_after_effect > 0 && !storage_io.virtual_fail_stop_triggered_for_test(&world.storage) {
			return "segment-publication did not reach selected storage-effect boundary", effect_count
		}

		generated_semantic_virtual_process_discard(&writer)
		sim_world_crash(&world)
		storage = sim_world_storage_context(&world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) || !generated_shard_restore_state(&writer) {
			return "segment-publication durable authority did not reopen", effect_count
		}
		publication_recovered := writer.manifest.checkpoint_generation == result.checkpoint_generation
		if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
			_ = reason
			return "segment-publication recovered authority differed from semantic model", effect_count
		}
		if writer.compaction == .Sealed {
			if !generated_shard_compact(&writer) {
				return "segment-publication sealed authority could not retry", effect_count
			}
		} else if writer.compaction != .Idle || writer.manifest.sealed_present || !writer.manifest.segmented {
			return "segment-publication recovery selected invalid authority shape", effect_count
		} else if !publication_recovered && shard_writer_catalog_cleaning_ready(&writer) {
			shard_replay_state_destroy()
			retry := shard_compaction_test_build_result(&writer)
			retry_published := retry.ok && publish_shard_compaction_result(&writer, retry)
			destroy_shard_segment_clean_result(&retry.segments)
			if !retry_published do return "segment-publication catalog authority could not retry", effect_count
			if !generated_shard_restore_state(&writer) do return "segment-publication retry state restore failed", effect_count
		}
		if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
			_ = reason
			return "segment-publication retry changed semantic state", effect_count
		}
		if cycle == .Retained_Prefix_Cleaning {
			catalog, catalog_ok := load_shard_segment_catalog(writer.storage, writer.shard_dir, writer.manifest.checkpoint_generation)
			defer destroy_shard_segment_catalog(&catalog)
			if !catalog_ok || len(catalog.segments) != 2 || catalog.segments[0] != retained_prefix || catalog.segments[1].kind != .Cleaned_Segment {
				return fmt.tprintf(
						"retained-prefix cleaning shape ok=%v len=%d prefix=%v expected=%v tail=%v",
						catalog_ok,
						len(catalog.segments),
						len(catalog.segments) > 0 ? catalog.segments[0] : Shard_Segment_Descriptor{},
						retained_prefix,
						len(catalog.segments) > 1 ? catalog.segments[1] : Shard_Segment_Descriptor{},
					),
					effect_count
			}
			if fail_stop_after_effect == 0 {
				for path in cleanup_paths {
					exists, exists_err := storage_io.exists(writer.storage, path)
					if exists_err != nil || exists {
						return "successful retained-prefix cleaning did not durably remove replaced input", effect_count
					}
				}
			}
		}

		if !generated_shard_create_task(&model, &writer, workspace) {
			return "segment-publication retry rejected continued write", effect_count
		}
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
			return "segment-publication continued write was not durable", effect_count
		}
		generated_semantic_virtual_process_discard(&writer)
		sim_world_crash(&world)
		storage = sim_world_storage_context(&world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) || !generated_shard_restore_state(&writer) {
			return "segment-publication continued-write authority did not reopen", effect_count
		}
		if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
			_ = reason
			return "segment-publication continued-write replay differed from semantic model", effect_count
		}
		return "", effect_count
	}

	virtual_segment_metadata_fallback_run :: proc(fail_stop_after_effect := 0, effect_count_out: ^int = nil) -> string {
		if fail_stop_after_effect < 0 do return "negative segment-metadata effect boundary"
		shard_dir := "/shard"
		world: Sim_World
		storage, storage_ok := generated_semantic_virtual_storage_init(&world, shard_dir)
		if !storage_ok {
			sim_world_destroy(&world)
			return "segment-metadata virtual storage initialization failed"
		}
		defer sim_world_destroy(&world)

		workspace_id := "virtual-segment-metadata-fallback"
		workspace := transmute([]byte)workspace_id
		shard := int(shard_for_workspace(workspace))
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, shard)
		defer simulation_test_end(&ctx)
		defer shard_replay_state_destroy()
		writer: Shard_Transaction_Writer
		defer if writer.wal.enabled || writer.shard_dir != "" do shutdown_shard_transaction_writer(&writer)
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return "segment-metadata writer initialization failed"
		}

		model: Generated_Shard_Model
		for _ in 0 ..< 3 {
			if !generated_shard_create_task(&model, &writer, workspace) || !rotate_shard_writer_for_compaction(&writer) {
				return "segment-metadata raw segment preparation failed"
			}
			result := shard_compaction_test_build_result(&writer)
			if !result.ok || !result.segments.raw_fast_path_used || !publish_shard_compaction_result(&writer, result) {
				destroy_shard_segment_clean_result(&result.segments)
				return "segment-metadata raw normalization failed"
			}
			destroy_shard_segment_clean_result(&result.segments)
		}
		source, source_ok := shard_segment_source_for_writer(&writer)
		if !source_ok || len(source.segments) != 3 {
			destroy_shard_segment_clean_source(&source)
			return "segment-metadata normalized source shape differed"
		}
		for descriptor in source.segments {
			path := shard_segment_metadata_path(writer.shard_dir, descriptor)
			exists, exists_err := storage_io.exists(writer.storage, path)
			delete(path)
			if exists_err != nil || !exists {
				destroy_shard_segment_clean_source(&source)
				return "segment-metadata raw normalization omitted a sidecar"
			}
		}
		corrupt_descriptor := source.segments[0]
		corrupt_size, corrupt_size_ok := shard_segment_descriptor_size(writer.storage, writer.shard_dir, corrupt_descriptor)
		if !corrupt_size_ok {
			destroy_shard_segment_clean_source(&source)
			return "segment-metadata corrupt descriptor size missing"
		}
		metadata_path := shard_segment_metadata_path(writer.shard_dir, corrupt_descriptor)
		metadata_exists, metadata_exists_err := storage_io.exists(writer.storage, metadata_path)
		if metadata_exists_err != nil || !metadata_exists {
			destroy_shard_segment_clean_source(&source)
			delete(metadata_path)
			return "segment-metadata raw normalization did not persist sidecar"
		}
		metadata_file, metadata_open_err := storage_io.open(writer.storage, metadata_path, {.Write})
		if metadata_open_err != nil || storage_io.truncate(metadata_file, 0) != nil {
			if metadata_file != nil do storage_io.discard(metadata_file)
			destroy_shard_segment_clean_source(&source)
			delete(metadata_path)
			return "segment-metadata sidecar corruption setup failed"
		}
		corrupt := []byte{0xA5}
		written, write_err := storage_io.write(metadata_file, corrupt)
		write_ok := write_err == nil && written == len(corrupt)
		sync_ok := write_ok && storage_io.sync(metadata_file) == nil
		close_ok := storage_io.close(metadata_file) == nil
		corruption_ok := write_ok && sync_ok && close_ok
		if !corruption_ok || storage_io.sync_directory(writer.storage, writer.shard_dir) != nil {
			destroy_shard_segment_clean_source(&source)
			delete(metadata_path)
			return "segment-metadata corrupt sidecar did not become durable"
		}

		ordinary_runs_before := writer.sweep_metrics.ordinary_runs
		fallbacks_before := writer.sweep_metrics.metadata_fallbacks
		written_before := writer.sweep_metrics.metadata_written_bytes
		writer.clean_cursor = 1
		writer.clean_sweep_generation = 0
		if !shard_writer_catalog_cleaning_ready(&writer) {
			destroy_shard_segment_clean_source(&source)
			delete(metadata_path)
			return "segment-metadata ordinary sweep was not production-eligible"
		}
		storage_io.virtual_set_fail_stop_after_effect_for_test(&world.storage, fail_stop_after_effect > 0 ? fail_stop_after_effect : max(int))
		ordinary := shard_compaction_test_build_result(&writer)
		destroy_shard_segment_clean_source(&source)
		published := ordinary.ok && publish_shard_compaction_result(&writer, ordinary)
		if effect_count_out != nil do effect_count_out^ = world.storage.effect_count
		if fail_stop_after_effect > 0 {
			destroy_shard_segment_clean_result(&ordinary.segments)
			delete(metadata_path)
			if !storage_io.virtual_fail_stop_triggered_for_test(&world.storage) {
				return "segment-metadata did not reach selected storage-effect boundary"
			}
			generated_semantic_virtual_process_discard(&writer)
			sim_world_crash(&world)
			storage = sim_world_storage_context(&world)
			shard_replay_state_destroy()
			if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) ||
			   !generated_shard_restore_state(&writer) {
				return "segment-metadata effect boundary did not reopen"
			}
			if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
				_ = reason
				return "segment-metadata effect boundary changed semantic authority"
			}
			if !generated_shard_create_task(&model, &writer, workspace) {
				return "segment-metadata effect boundary rejected continuation"
			}
			persistence.force_fsync(&writer.wal)
			if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
				return "segment-metadata effect-boundary continuation did not become durable"
			}
			generated_semantic_virtual_process_discard(&writer)
			sim_world_crash(&world)
			storage = sim_world_storage_context(&world)
			shard_replay_state_destroy()
			if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) ||
			   !generated_shard_restore_state(&writer) {
				return "segment-metadata effect-boundary continuation did not reopen"
			}
			if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
				_ = reason
				return "segment-metadata effect-boundary continuation changed semantic state"
			}
			return ""
		}
		if !ordinary.ok ||
		   ordinary.segments.raw_fast_path_used ||
		   ordinary.segments.metadata_fallbacks != 1 ||
		   ordinary.segments.metadata_written_bytes == 0 ||
		   !published {
			destroy_shard_segment_clean_result(&ordinary.segments)
			delete(metadata_path)
			return "segment-metadata ordinary sweep did not rebuild corrupt sidecar"
		}
		ordinary_fallbacks := ordinary.segments.metadata_fallbacks
		ordinary_written_bytes := ordinary.segments.metadata_written_bytes
		destroy_shard_segment_clean_result(&ordinary.segments)
		if writer.sweep_metrics.ordinary_runs != ordinary_runs_before + 1 ||
		   writer.sweep_metrics.metadata_fallbacks != fallbacks_before + ordinary_fallbacks ||
		   writer.sweep_metrics.metadata_written_bytes != written_before + ordinary_written_bytes {
			delete(metadata_path)
			return "segment-metadata ordinary sweep telemetry differed"
		}
		repaired, _, repaired_ok := load_shard_segment_metadata_summary(writer.storage, writer.shard_dir, shard, corrupt_descriptor, corrupt_size)
		destroy_shard_segment_metadata_summary(&repaired)
		if !repaired_ok {
			delete(metadata_path)
			return "segment-metadata ordinary sweep did not persist repaired sidecar"
		}

		generated_semantic_virtual_process_discard(&writer)
		sim_world_crash(&world)
		storage = sim_world_storage_context(&world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(&writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) || !generated_shard_restore_state(&writer) {
			delete(metadata_path)
			return "segment-metadata ordinary sweep did not reopen"
		}
		repaired, _, repaired_ok = load_shard_segment_metadata_summary(writer.storage, writer.shard_dir, shard, corrupt_descriptor, corrupt_size)
		destroy_shard_segment_metadata_summary(&repaired)
		delete(metadata_path)
		if !repaired_ok do return "segment-metadata repaired sidecar did not survive crash"
		if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
			_ = reason
			return "segment-metadata ordinary sweep changed semantic state"
		}
		return ""
	}

	virtual_checkpoint_event_run :: proc() -> string {
		shard_dir := "/shard"
		storage_world: Sim_World
		storage, storage_ok := generated_semantic_virtual_storage_init(&storage_world, shard_dir)
		if !storage_ok {
			sim_world_destroy(&storage_world)
			return "virtual checkpoint event storage initialization failed"
		}
		defer sim_world_destroy(&storage_world)

		workspace_id := "virtual-checkpoint-event"
		workspace := transmute([]byte)workspace_id
		shard := int(shard_for_workspace(workspace))
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 0)
		defer simulation_test_end(&ctx)
		server: NRC_Server
		td.server = &server
		defer {td.server = nil}
		registry := &td.shard_writers
		for &index in registry.writer_index do index = -1
		registry.worker = 0
		registry.worker_count = 1
		registry.writers = make([dynamic]Shard_Transaction_Writer, 1)
		registry.mode = .Active
		defer shutdown_shard_writer_registry(registry)
		writer := &registry.writers[0]
		if !init_managed_shard_transaction_writer(writer, storage, shard_dir, shard, 0, 1) {
			return "virtual checkpoint event writer initialization failed"
		}
		registry.writer_index[shard] = 0
		defer shard_replay_state_destroy()

		model: Generated_Shard_Model
		if !generated_shard_create_task(&model, writer, workspace) || !rotate_shard_writer_for_compaction(writer) {
			return "virtual checkpoint event could not prepare sealed writer"
		}
		if !enqueue_shard_compaction_job_event(&ctx.sim.world, writer) ||
		   sim_world_event_count(&ctx.sim.world, .Compaction_Job) != 1 ||
		   writer.compaction != .Building {
			return "virtual checkpoint job did not transfer to kernel"
		}
		if !sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) ||
		   sim_world_event_count(&ctx.sim.world, .Compaction_Job) != 0 ||
		   sim_world_event_count(&ctx.sim.world, .Compaction_Result) != 1 ||
		   writer.compaction != .Building {
			return "virtual checkpoint job execution did not enqueue one result"
		}
		if !sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Result)) ||
		   sim_world_event_count(&ctx.sim.world, .Compaction_Result) != 0 ||
		   writer.compaction != .Idle ||
		   writer.manifest.sealed_present ||
		   !writer.manifest.checkpoint_present {
			return "virtual checkpoint result did not publish through owner writer"
		}
		first_checkpoint_generation := writer.manifest.checkpoint_generation

		if !generated_shard_create_task(&model, writer, workspace) {
			return "virtual checkpoint active WAL rejected continued write"
		}
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
			return "virtual checkpoint continued write did not become durable"
		}
		if !rotate_shard_writer_for_compaction(writer) || !enqueue_shard_compaction_job_event(&ctx.sim.world, writer) {
			return "virtual checkpoint stale-event case could not enqueue job"
		}
		sim_world_crash(&ctx.sim.world)
		if !sim_world_run_next_event(&ctx.sim.world) ||
		   sim_world_event_count(&ctx.sim.world, .Compaction_Job) != 0 ||
		   sim_world_event_count(&ctx.sim.world, .Compaction_Result) != 0 ||
		   writer.compaction != .Building {
			return "stale virtual checkpoint job was not discarded without delivery"
		}
		generated_semantic_virtual_process_discard(writer)
		sim_world_crash(&storage_world)
		storage = sim_world_storage_context(&storage_world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(writer, storage, shard_dir, shard, 0, 1) || !generated_shard_restore_state(writer) {
			return "virtual checkpoint event state did not reopen"
		}
		if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
			_ = reason
			return "virtual checkpoint event restart differed from semantic model"
		}
		if writer.compaction != .Idle ||
		   !writer.manifest.segmented ||
		   !shard_writer_catalog_cleaning_ready(writer) ||
		   !enqueue_shard_compaction_job_event(&ctx.sim.world, writer) ||
		   !sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) ||
		   !sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Result)) ||
		   writer.compaction != .Idle ||
		   !writer.manifest.checkpoint_present ||
		   writer.manifest.checkpoint_generation == first_checkpoint_generation {
			return "virtual checkpoint retry did not publish second generation through kernel"
		}
		if !generated_shard_create_task(&model, writer, workspace) {
			return "second virtual checkpoint rejected continued write"
		}
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
			return "second virtual checkpoint continued write did not become durable"
		}
		generated_semantic_virtual_process_discard(writer)
		sim_world_crash(&storage_world)
		storage = sim_world_storage_context(&storage_world)
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(writer, storage, shard_dir, shard, 0, 1) || !generated_shard_restore_state(writer) {
			return "second virtual checkpoint generation did not reopen"
		}
		if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
			_ = reason
			return "second virtual checkpoint restart differed from semantic model"
		}
		return ""
	}

	generated_compaction_raw_segment_count :: proc(writer: ^Shard_Transaction_Writer) -> int {
		count := 0
		for descriptor in writer.catalog.segments do if descriptor.kind == .Generation_WAL do count += 1
		return count
	}

	generated_compaction_owned_path_equal :: proc(path, candidate: string) -> bool {
		equal := path == candidate
		delete(candidate)
		return equal
	}

	generated_compaction_path_is_authoritative :: proc(writer: ^Shard_Transaction_Writer, path: string) -> bool {
		if writer == nil do return false
		manifest := writer.manifest
		if generated_compaction_owned_path_equal(path, shard_compaction_manifest_path(writer.shard_dir)) do return true
		if generated_compaction_owned_path_equal(path, shard_generation_wal_path(writer.shard_dir, manifest.active_generation)) do return true
		if manifest.checkpoint_present {
			if manifest.segmented {
				if generated_compaction_owned_path_equal(path, shard_segment_catalog_path(writer.shard_dir, manifest.checkpoint_generation)) do return true
				for descriptor in writer.catalog.segments {
					if generated_compaction_owned_path_equal(path, shard_segment_descriptor_path(writer.shard_dir, descriptor)) do return true
					if generated_compaction_owned_path_equal(path, shard_segment_metadata_path(writer.shard_dir, descriptor)) do return true
				}
			} else if generated_compaction_owned_path_equal(path, shard_checkpoint_wal_path(writer.shard_dir, manifest.checkpoint_generation)) {
				return true
			}
		}
		if manifest.sealed_present && generated_compaction_owned_path_equal(path, shard_generation_wal_path(writer.shard_dir, manifest.sealed_generation)) {
			return true
		}
		if writer.prepared_active_generation != 0 &&
		   generated_compaction_owned_path_equal(path, shard_generation_wal_path(writer.shard_dir, writer.prepared_active_generation)) {
			return true
		}
		return false
	}

	generated_compaction_virtual_orphan_file_count :: proc(world: ^Sim_World, writer: ^Shard_Transaction_Writer, durable: bool) -> int {
		if world == nil do return 0
		entries := durable ? world.storage.durable_entries : world.storage.volatile_entries
		count := 0
		for path, inode_id in entries {
			if len(path) <= len(writer.shard_dir) || path[:len(writer.shard_dir)] != writer.shard_dir || path[len(writer.shard_dir)] != '/' do continue
			inode := world.storage.inodes[inode_id]
			if inode != nil && inode.kind == .File && !generated_compaction_path_is_authoritative(writer, path) do count += 1
		}
		return count
	}

	generated_compaction_run_clean :: proc(world: ^Sim_World, writer: ^Shard_Transaction_Writer) -> bool {
		raw_segments := generated_compaction_raw_segment_count(writer)
		for {
			previous_backlog := writer.clean_backlog_bytes
			previous_raw_segments := raw_segments
			previous_cursor := writer.clean_cursor
			previous_sweep_generation := writer.clean_sweep_generation
			previous_manifest_generation := writer.manifest.manifest_generation
			if !enqueue_shard_compaction_job_event(world, writer) ||
			   !sim_world_run_runnable_rank(world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) ||
			   !sim_world_run_runnable_rank(world, 0, Maybe(Sim_Event_Domain)(.Compaction_Result)) ||
			   writer.compaction != .Idle ||
			   writer.manifest.sealed_present ||
			   !writer.manifest.checkpoint_present {
				return false
			}
			raw_segments = generated_compaction_raw_segment_count(writer)
			progressed :=
				writer.manifest.manifest_generation > previous_manifest_generation ||
				writer.clean_cursor != previous_cursor ||
				writer.clean_sweep_generation != previous_sweep_generation ||
				writer.clean_backlog_bytes < previous_backlog ||
				raw_segments < previous_raw_segments
			if !progressed do return false
			if raw_segments == 0 do return true
			if writer.clean_backlog_bytes >= previous_backlog && raw_segments >= previous_raw_segments {
				return false
			}
		}
	}

	generated_compaction_crash_reopen :: proc(
		world: ^Sim_World,
		writer: ^Shard_Transaction_Writer,
		server: ^NRC_Server,
		shard_dir: string,
		shard: int,
		workspace_id: string,
		model: ^Generated_Shard_Model,
	) -> string {
		generated_semantic_virtual_process_discard(writer)
		sim_world_crash(world)
		_, drain_result := sim_world_drain_bounded(world, 64)
		if drain_result != .Reached do return fmt.tprintf("drain stale compaction events: %v", drain_result)
		server.closing = false
		server.fatal_storage_error = false
		shard_replay_state_destroy()
		storage := sim_world_storage_context(world)
		if !init_managed_shard_transaction_writer(writer, storage, shard_dir, shard, 0, 1) || !generated_shard_restore_state(writer) {
			return "reopen generated compaction state"
		}
		if reason, equal := generated_shard_compare(model, workspace_id, writer.floors); !equal {
			_ = reason
			return "generated compaction restart differed from semantic model"
		}
		return ""
	}

	generated_compaction_history_run :: proc(
		choices: []Generated_Compaction_Interruption,
		workload_ops: []Generated_Shard_Op = nil,
		// Fine-grained crash injection: interrupt the ordinary clean publication of
		// one later generation at an exact storage-effect boundary instead of only at
		// coarse kernel-event boundaries. -1 disables the fine cut.
		fine_generation: int = -1,
		fine_effect: int = 0,
		// When non-nil, records each generation's clean storage-effect span (with the
		// fine cut disabled) so a caller can draw an in-range fine_effect.
		effect_spans_out: []int = nil,
	) -> string {
		if len(choices) == 0 || len(choices) > 16 do return "generated compaction history length is invalid"
		if fine_generation < -1 || fine_generation >= len(choices) do return "generated compaction fine generation is out of range"
		if fine_effect < 0 do return "generated compaction fine effect is negative"
		if fine_effect > 0 && (effect_spans_out != nil || fine_generation < 0) {
			return "generated compaction fine effect requires a target generation and cannot also measure spans"
		}
		shard_dir := "/shard"
		workspace_id := "generated-compaction-kernel-history"
		workspace := transmute([]byte)workspace_id
		shard := int(shard_for_workspace(workspace))
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 0)
		defer simulation_test_end(&ctx)
		defer shard_replay_state_destroy()
		storage, storage_ok := generated_semantic_virtual_storage_prepare(&ctx.sim.world, shard_dir)
		if !storage_ok do return "generated compaction storage initialization failed"
		server: NRC_Server
		td.server = &server
		defer {td.server = nil}
		registry := &td.shard_writers
		for &index in registry.writer_index do index = -1
		registry.worker = 0
		registry.worker_count = 1
		registry.writers = make([dynamic]Shard_Transaction_Writer, 1)
		registry.mode = .Active
		defer shutdown_shard_writer_registry(registry)
		writer := &registry.writers[0]
		if !init_managed_shard_transaction_writer(writer, storage, shard_dir, shard, 0, 1) {
			return "generated compaction writer initialization failed"
		}
		registry.writer_index[shard] = 0
		quiescence_baseline := sim_worker_quiescence_baseline()

		model: Generated_Shard_Model
		foundation := [?]Generated_Shard_Op {
			{kind = .Create_Task},
			{kind = .Create_Task},
			{kind = .Create_Asset},
			{kind = .Create_Asset, selector = 1},
			{kind = .Create_Asset},
			{kind = .Create_Edge, selector = 0},
			{kind = .Create_Edge, selector = 1},
			{kind = .Create_Edge, selector = 20},
			{kind = .Query_Graph, selector = 35},
			{kind = .Create_Slice},
			{kind = .Create_Slice},
			{kind = .Create_File},
			{kind = .Create_Customer},
			{kind = .Create_Contact},
			{kind = .Create_Membership, selector = 0},
			{kind = .Create_Membership, selector = 1},
			{kind = .Create_Membership, selector = 4},
			{kind = .Create_Membership, selector = 8},
			{kind = .Create_Membership, selector = 9},
			{kind = .Create_Membership, selector = 128},
			{kind = .Update_Asset, selector = 3},
			{kind = .Query_Slices, selector = 1},
		}
		for op, op_index in foundation {
			if !generated_shard_apply_op(&model, writer, workspace, shard_dir, op) {
				return fmt.tprintf("graph foundation operation=%d kind=%v failed", op_index, op.kind)
			}
			if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
				_ = reason
				return fmt.tprintf("graph foundation operation=%d kind=%v differed", op_index, op.kind)
			}
		}
		previous_checkpoint_generation: u64
		previous_manifest_generation := writer.manifest.manifest_generation
		previous_floors := writer.floors
		for choice, generation_index in choices {
			volatile_orphans_before := generated_compaction_virtual_orphan_file_count(&ctx.sim.world, writer, false)
			durable_orphans_before := generated_compaction_virtual_orphan_file_count(&ctx.sim.world, writer, true)
			if !generated_shard_create_task(&model, writer, workspace) {
				return fmt.tprintf("generation=%d semantic prepare", generation_index)
			}
			for _ in 0 ..< 4 {
				if !generated_shard_mutate_task(&model, writer, workspace, .Update, generated_shard_live_task_count(&model) - 1) {
					return fmt.tprintf("generation=%d semantic prepare update", generation_index)
				}
			}
			for op, op_index in workload_ops {
				if op_index * len(choices) / len(workload_ops) != generation_index do continue
				if !generated_shard_apply_op(&model, writer, workspace, shard_dir, op) {
					return fmt.tprintf("generation=%d workload operation=%d kind=%v failed", generation_index, op_index, op.kind)
				}
				if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
					_ = reason
					return fmt.tprintf("generation=%d workload operation=%d kind=%v differed", generation_index, op_index, op.kind)
				}
			}
			catalog_segments_before_rotation := writer.catalog_segments
			rotation_effect, interrupts_rotation := generated_compaction_rotation_effect(choice)
			if interrupts_rotation {
				storage_io.virtual_set_fail_stop_after_effect_for_test(&ctx.sim.world.storage, rotation_effect)
				_ = rotate_shard_writer_for_compaction(writer)
				if !storage_io.virtual_fail_stop_triggered_for_test(&ctx.sim.world.storage) {
					return fmt.tprintf("generation=%d rotation effect=%d did not trigger", generation_index, rotation_effect)
				}
				if diagnostic := generated_compaction_crash_reopen(&ctx.sim.world, writer, &server, shard_dir, shard, workspace_id, &model); diagnostic != "" {
					return fmt.tprintf("generation=%d interruption=%v %s", generation_index, choice, diagnostic)
				}
				if writer.catalog_segments <= catalog_segments_before_rotation && !rotate_shard_writer_for_compaction(writer) {
					return fmt.tprintf("generation=%d rotation effect=%d retry interrupted rotation", generation_index, rotation_effect)
				}
			} else {
				if !rotate_shard_writer_for_compaction(writer) {
					return fmt.tprintf("generation=%d prepare rotation", generation_index)
				}
				switch choice {
				case .Clean:
				case .Crash_Before_Job:
					if !enqueue_shard_compaction_job_event(&ctx.sim.world, writer) {
						return fmt.tprintf("generation=%d enqueue before-job crash", generation_index)
					}
				case .Crash_Before_Result:
					if !enqueue_shard_compaction_job_event(&ctx.sim.world, writer) ||
					   !sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) {
						return fmt.tprintf("generation=%d execute before-result crash", generation_index)
					}
				case .Fail_Stop_Job:
					storage_io.virtual_set_fail_stop_after_effect_for_test(&ctx.sim.world.storage, 1)
					if !enqueue_shard_compaction_job_event(&ctx.sim.world, writer) ||
					   !sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) ||
					   !storage_io.virtual_fail_stop_triggered_for_test(&ctx.sim.world.storage) {
						return fmt.tprintf("generation=%d job fail-stop", generation_index)
					}
				case .Fail_Stop_Result:
					if !enqueue_shard_compaction_job_event(&ctx.sim.world, writer) ||
					   !sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) {
						return fmt.tprintf("generation=%d prepare result fail-stop", generation_index)
					}
					storage_io.virtual_set_fail_stop_after_effect_for_test(&ctx.sim.world.storage, 1)
					previous_logger := context.logger
					context.logger = log.nil_logger()
					dispatched := sim_world_run_runnable_rank(&ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Result))
					context.logger = previous_logger
					if !dispatched || !storage_io.virtual_fail_stop_triggered_for_test(&ctx.sim.world.storage) {
						return fmt.tprintf("generation=%d result fail-stop", generation_index)
					}
				case .Fail_Stop_Rotation_Effect_1 ..= .Fail_Stop_Rotation_Effect_9:
					unreachable()
				}

				if choice != .Clean {
					if diagnostic := generated_compaction_crash_reopen(&ctx.sim.world, writer, &server, shard_dir, shard, workspace_id, &model);
					   diagnostic != "" {
						return fmt.tprintf("generation=%d interruption=%v %s", generation_index, choice, diagnostic)
					}
					if writer.compaction != .Idle || writer.manifest.sealed_present || writer.catalog_segments < 1 {
						return fmt.tprintf("generation=%d interruption=%v did not reopen cleaner-eligible catalog", generation_index, choice)
					}
				}
			}
			clean_start_effects := ctx.sim.world.storage.effect_count
			fine_armed := fine_generation == generation_index && fine_effect > 0
			if fine_armed {
				storage_io.virtual_set_fail_stop_after_effect_for_test(&ctx.sim.world.storage, fine_effect)
			}
			sweep_runs_before := writer.sweep_metrics.runs
			previous_logger := context.logger
			context.logger = fine_armed ? log.nil_logger() : previous_logger
			clean_ok := generated_compaction_run_clean(&ctx.sim.world, writer)
			if effect_spans_out != nil && generation_index < len(effect_spans_out) {
				effect_spans_out[generation_index] = ctx.sim.world.storage.effect_count - clean_start_effects
			}
			fine_triggered := fine_armed && storage_io.virtual_fail_stop_triggered_for_test(&ctx.sim.world.storage)
			if fine_triggered {
				if diagnostic := generated_compaction_crash_reopen(&ctx.sim.world, writer, &server, shard_dir, shard, workspace_id, &model); diagnostic != "" {
					return fmt.tprintf("generation=%d fine effect=%d reopen %s", generation_index, fine_effect, diagnostic)
				}
				if generated_compaction_raw_segment_count(writer) > 0 {
					resume_ready := (writer.manifest.sealed_present && writer.compaction == .Sealed) || shard_writer_catalog_cleaning_ready(writer)
					if !resume_ready || !generated_compaction_run_clean(&ctx.sim.world, writer) {
						return fmt.tprintf("generation=%d fine effect=%d clean resume failed", generation_index, fine_effect)
					}
				}
				if generated_compaction_raw_segment_count(writer) != 0 {
					return fmt.tprintf("generation=%d fine effect=%d retained raw segments after recovery", generation_index, fine_effect)
				}
			} else if fine_armed {
				return fmt.tprintf("generation=%d fine effect=%d did not interrupt the clean publication", generation_index, fine_effect)
			} else if !clean_ok {
				return fmt.tprintf("generation=%d interruption=%v clean retry", generation_index, choice)
			}
			context.logger = previous_logger
			if !fine_triggered && writer.sweep_metrics.runs <= sweep_runs_before {
				return fmt.tprintf("generation=%d interruption=%v cleaner made no measured progress", generation_index, choice)
			}
			if reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
				_ = reason
				return fmt.tprintf("generation=%d interruption=%v live state changed after compaction", generation_index, choice)
			}
			if writer.manifest.checkpoint_generation <= previous_checkpoint_generation {
				return fmt.tprintf(
					"generation=%d interruption=%v checkpoint generation=%d did not advance beyond %d",
					generation_index,
					choice,
					writer.manifest.checkpoint_generation,
					previous_checkpoint_generation,
				)
			}
			if writer.manifest.manifest_generation <= previous_manifest_generation {
				return fmt.tprintf("generation=%d interruption=%v manifest generation did not advance", generation_index, choice)
			}
			previous_manifest_generation = writer.manifest.manifest_generation
			if writer.floors.task < previous_floors.task || writer.floors.asset < previous_floors.asset || writer.floors.edge < previous_floors.edge {
				return fmt.tprintf("generation=%d interruption=%v high-water floor regressed", generation_index, choice)
			}
			previous_floors = writer.floors
			if !shard_segment_catalog_is_valid(writer.catalog) ||
			   !shard_compaction_manifest_files_are_valid_with_storage(writer.storage, writer.shard_dir, writer.manifest) {
				return fmt.tprintf("generation=%d interruption=%v published catalog files are invalid", generation_index, choice)
			}
			if writer.clean_cursor < 0 ||
			   (writer.clean_cursor != 0 && writer.clean_cursor >= len(writer.catalog.segments)) ||
			   (writer.clean_sweep_generation != 0 && writer.clean_sweep_generation != writer.manifest.checkpoint_generation) {
				return fmt.tprintf("generation=%d interruption=%v cleaner cursor state is invalid", generation_index, choice)
			}
			volatile_orphans := generated_compaction_virtual_orphan_file_count(&ctx.sim.world, writer, false)
			durable_orphans := generated_compaction_virtual_orphan_file_count(&ctx.sim.world, writer, true)
			if choice == .Clean && !fine_triggered && (volatile_orphans > volatile_orphans_before || durable_orphans > durable_orphans_before) {
				return fmt.tprintf(
					"generation=%d clean churn accumulated orphan files: volatile=%d/%d durable=%d/%d",
					generation_index,
					volatile_orphans,
					volatile_orphans_before,
					durable_orphans,
					durable_orphans_before,
				)
			}
			previous_checkpoint_generation = writer.manifest.checkpoint_generation
		}

		if !generated_shard_create_task(&model, writer, workspace) {
			return "generated compaction continued write failed"
		}
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
			return "generated compaction continued write was not durable"
		}
		if diagnostic := generated_compaction_crash_reopen(&ctx.sim.world, writer, &server, shard_dir, shard, workspace_id, &model); diagnostic != "" {
			return diagnostic
		}
		if reason := sim_worker_quiescence_reason(nil, quiescence_baseline); reason != "" do return reason
		if diagnostic := generated_compaction_crash_reopen(&ctx.sim.world, writer, &server, shard_dir, shard, workspace_id, &model); diagnostic != "" {
			return fmt.tprintf("second clean restart: %s", diagnostic)
		}
		return sim_worker_quiescence_reason(nil, quiescence_baseline)
	}

	generated_compaction_history_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		generation_count_raw, count_err := hgl.draw_i64(tc, 1, 3)
		if count_err == .Stop_Test do return hgl.abort()
		if count_err != nil do return hgl.interesting("draw compaction generation count")
		generation_count := int(generation_count_raw)
		choices: [3]Generated_Compaction_Interruption
		for index in 0 ..< generation_count {
			choice_raw, choice_err := hgl.draw_i64(tc, 0, i64(len(Generated_Compaction_Interruption) - 1))
			if choice_err == .Stop_Test do return hgl.abort()
			if choice_err != nil do return hgl.interesting("draw compaction interruption")
			choices[index] = Generated_Compaction_Interruption(choice_raw)
		}
		op_count_raw, op_count_err := hgl.draw_i64(tc, 1, 9)
		if op_count_err == .Stop_Test do return hgl.abort()
		if op_count_err != nil do return hgl.interesting("draw global graph workload operation count")
		op_count := int(op_count_raw)
		ops: [9]Generated_Shard_Op
		kinds := GENERATED_GLOBAL_GRAPH_WORKLOAD_KINDS
		for index in 0 ..< op_count {
			kind_index, kind_err := hgl.draw_i64(tc, 0, len(kinds) - 1)
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("draw global graph workload operation kind")
			selector, selector_err := hgl.draw_u64(tc, 0, 255)
			if selector_err == .Stop_Test do return hgl.abort()
			if selector_err != nil do return hgl.interesting("draw global graph workload selector")
			ops[index] = {
				kind     = kinds[kind_index],
				selector = selector,
			}
		}
		diagnostic := generated_compaction_history_run(choices[:generation_count], ops[:op_count])
		if diagnostic != "" do return hgl.interesting(diagnostic)
		return hgl.valid()
	}

	// Fine-grained publication crash property. The coarse kernel-history property
	// crashes only at event boundaries and then drives every clean to completion
	// uninterrupted. This property additionally picks one (possibly later)
	// generation whose ordinary clean publication is interrupted at an exact
	// storage-effect boundary, then recovers and resumes.
	generated_fine_publication_history_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		generation_count_raw, count_err := hgl.draw_i64(tc, 1, 3)
		if count_err == .Stop_Test do return hgl.abort()
		if count_err != nil do return hgl.interesting("draw fine publication generation count")
		generation_count := int(generation_count_raw)

		choices: [3]Generated_Compaction_Interruption
		for index in 0 ..< generation_count do choices[index] = .Clean

		op_count_raw, op_count_err := hgl.draw_i64(tc, 1, 9)
		if op_count_err == .Stop_Test do return hgl.abort()
		if op_count_err != nil do return hgl.interesting("draw fine publication workload operation count")
		op_count := int(op_count_raw)
		ops: [9]Generated_Shard_Op
		kinds := GENERATED_GLOBAL_GRAPH_WORKLOAD_KINDS
		for index in 0 ..< op_count {
			kind_index, kind_err := hgl.draw_i64(tc, 0, len(kinds) - 1)
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("draw fine publication workload operation kind")
			selector, selector_err := hgl.draw_u64(tc, 0, 255)
			if selector_err == .Stop_Test do return hgl.abort()
			if selector_err != nil do return hgl.interesting("draw fine publication workload selector")
			ops[index] = {
				kind     = kinds[kind_index],
				selector = selector,
			}
		}

		// Crash-free measurement pass: per-generation clean storage-effect spans.
		spans: [3]int
		measure_diagnostic := generated_compaction_history_run(choices[:generation_count], ops[:op_count], effect_spans_out = spans[:generation_count])
		if measure_diagnostic != "" do return hgl.interesting(measure_diagnostic)

		target_raw, target_err := hgl.draw_i64(tc, 0, i64(generation_count - 1))
		if target_err == .Stop_Test do return hgl.abort()
		if target_err != nil do return hgl.interesting("draw fine publication target generation")
		target := int(target_raw)
		span := spans[target]
		if span <= 0 do return hgl.valid()

		effect_raw, effect_err := hgl.draw_i64(tc, 1, i64(span))
		if effect_err == .Stop_Test do return hgl.abort()
		if effect_err != nil do return hgl.interesting("draw fine publication storage-effect boundary")
		effect := int(effect_raw)

		crash_diagnostic := generated_compaction_history_run(choices[:generation_count], ops[:op_count], fine_generation = target, fine_effect = effect)
		if crash_diagnostic != "" do return hgl.interesting(crash_diagnostic)
		return hgl.valid()
	}

}

@(test)
test_hegel_mixed_semantic_history_recovers_exact_durable_prefix :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		pending_ops := [?]Generated_Shard_Op {
			{kind = .Update_Task, selector = 0},
			{kind = .Move_Task, selector = 3},
			{kind = .Update_Asset, selector = 0},
			{kind = .Create_Edge, selector = 1},
			{kind = .Delete_Asset, selector = 0},
		}
		fixture: Generated_Semantic_Fault_Fixture
		testing.expect(t, generated_semantic_fault_fixture_init(&fixture, pending_ops[:], "fixed"), "mixed semantic persistence fixture should initialize")
		defer generated_semantic_fault_fixture_destroy(&fixture)
		result, err := hgl.run(generated_semantic_fixed_fault_property, &fixture, {test_cases = 96})
		testing.expectf(t, err == nil, "mixed semantic durable-prefix property failed: err=%v interesting=%v", err, result.interesting_test_cases)
		foundation_ops := GENERATED_SEMANTIC_FAULT_FOUNDATION_V1
		generated_semantic_fault_replay_v1(t, foundation_ops[:], pending_ops[:], 2, 1)
	}
}

@(test)
test_hegel_slice_membership_recovers_exact_durable_prefix :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		// Foundation v1 already owns task 1 and note 1. Each pending operation
		// appends exactly one record, so torn writes can land on either side of
		// assignment, closure, unassignment and container deletion.
		pending_ops := [?]Generated_Shard_Op {
			{kind = .Create_Slice},
			{kind = .Create_Slice},
			{kind = .Create_File},
			{kind = .Create_Membership, selector = 0},
			{kind = .Create_Membership, selector = 4},
			{kind = .Create_Membership, selector = 5},
			{kind = .Create_Membership, selector = 2},
			{kind = .Update_Asset, selector = 2},
			{kind = .Move_Task, selector = 3},
			{kind = .Delete_Edge, selector = 1},
			{kind = .Update_Asset, selector = 2},
			{kind = .Delete_Asset, selector = 2},
		}
		fixture: Generated_Semantic_Fault_Fixture
		initialized := generated_semantic_fault_fixture_init(&fixture, pending_ops[:], "slice-membership")
		testing.expect(t, initialized, "slice membership persistence fixture should initialize")
		if !initialized do return
		defer generated_semantic_fault_fixture_destroy(&fixture)
		// Exact boundaries are mandatory, rather than hoping a random seed
		// reaches the first and last bytes of every new record kind.
		for durable_count in 0 ..= len(pending_ops) {
			result := generated_semantic_fault_execute(nil, &fixture, durable_count, 0)
			testing.expectf(t, result.status == .Valid, "slice durable prefix %d: %s", durable_count, result.origin)
			if durable_count < len(pending_ops) {
				start := durable_count == 0 ? fixture.stable_end : fixture.record_ends[durable_count - 1]
				cut := fixture.record_ends[durable_count] - start - 1
				torn := generated_semantic_fault_execute(nil, &fixture, durable_count, cut)
				testing.expectf(t, torn.status == .Valid, "slice torn prefix %d: %s", durable_count, torn.origin)
			}
		}
		result, err := hgl.run(generated_semantic_fixed_fault_property, &fixture, {test_cases = 64})
		testing.expectf(t, err == nil, "slice membership durable-prefix property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_semantic_histories_recover_exact_durable_prefix :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(generated_semantic_history_fault_property, nil, {test_cases = 64, database_key = "generated-semantic-durable-history-v1"})
		testing.expectf(t, err == nil, "generated semantic durable-history property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_virtual_rotation_crash_windows_recover_manifest_authority :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
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
		effect_count := 0
		baseline := virtual_rotation_crash_window_run(.None, effect_count_out = &effect_count)
		testing.expectf(t, baseline == "" && effect_count > 9, "virtual segmented rotation baseline failed after %d effects: %s", effect_count, baseline)
		for point in points {
			diagnostic := virtual_rotation_crash_window_run(point)
			testing.expectf(t, diagnostic == "", "virtual rotation point=%v failed: %s", point, diagnostic)
		}
		uncertain_published := virtual_rotation_crash_window_run(.Manifest_Directory_Sync, true)
		testing.expectf(t, uncertain_published == "", "virtual rotation durable uncertain-rename outcome failed: %s", uncertain_published)
		for effect_boundary in 1 ..= effect_count {
			observed_effects := 0
			diagnostic := virtual_rotation_crash_window_run(.None, fail_stop_after_effect = effect_boundary, effect_count_out = &observed_effects)
			testing.expectf(
				t,
				diagnostic == "" && observed_effects == effect_boundary,
				"virtual rotation storage-effect boundary=%d observed=%d failed: %s",
				effect_boundary,
				observed_effects,
				diagnostic,
			)
		}
	}
}

@(test)
test_virtual_segment_publication_and_cleanup_effect_sweep :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		cycles := [?]Virtual_Segment_Publication_Cycle{.Adoption, .Retained_Prefix_Cleaning}
		for cycle in cycles {
			baseline_diagnostic, effect_count := virtual_segment_publication_effect_run(cycle)
			testing.expectf(
				t,
				baseline_diagnostic == "" && effect_count > 0,
				"virtual segment-publication cycle=%v baseline failed after %d effects: %s",
				cycle,
				effect_count,
				baseline_diagnostic,
			)
			if baseline_diagnostic != "" || effect_count <= 0 do continue
			for effect_boundary in 1 ..= effect_count {
				diagnostic, observed_effects := virtual_segment_publication_effect_run(cycle, effect_boundary)
				testing.expectf(
					t,
					diagnostic == "" && observed_effects == effect_boundary,
					"virtual segment-publication cycle=%v boundary=%d observed=%d failed: %s",
					cycle,
					effect_boundary,
					observed_effects,
					diagnostic,
				)
			}
		}
	}
}

@(test)
test_virtual_segment_multi_output_restoration_failure :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		// The last successful build effects are one restoration rename per output.
		// Measure that suffix, then stop after its first rename in a fresh world.
		restoration_boundary: int
		first_generation, second_generation: u64
		cases := [?]bool{false, true}
		for inject_failure in cases {
			world: Sim_World
			storage, storage_ok := generated_semantic_virtual_storage_init(&world, "/shard")
			defer sim_world_destroy(&world)
			testing.expect(t, storage_ok)
			if !storage_ok do return
			workspace_id := "multi-output-restoration"
			workspace := transmute([]byte)workspace_id
			shard := int(shard_for_workspace(workspace))
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx, shard)
			defer simulation_test_end(&ctx)
			defer shard_replay_state_destroy()
			writer: Shard_Transaction_Writer
			defer shutdown_shard_transaction_writer(&writer)
			testing.expect(t, init_managed_shard_transaction_writer(&writer, storage, "/shard", shard, shard, LOGICAL_SHARD_COUNT))
			model: Generated_Shard_Model
			for _ in 0 ..< 12 do testing.expect(t, generated_shard_create_task(&model, &writer, workspace))
			testing.expect(t, rotate_shard_writer_for_compaction(&writer))
			manifest := writer.manifest
			generation, generation_ok := shard_compaction_next_file_generation(storage, "/shard", manifest)
			testing.expect(t, generation_ok)
			shard_replay_state_destroy()
			storage_io.virtual_set_fail_stop_after_effect_for_test(&world.storage, inject_failure ? restoration_boundary : max(int))
			result := build_shard_segment_catalog(storage, "/shard", manifest, generation, output_max_bytes = 512)
			defer destroy_shard_segment_clean_result(&result)
			if !inject_failure {
				testing.expect(t, result.ok && len(result.outputs) > 1)
				if !result.ok || len(result.outputs) <= 1 do return
				first_generation = result.outputs[0].generation
				second_generation = result.outputs[1].generation
				restoration_boundary = world.storage.effect_count - len(result.outputs) + 1
				testing.expect(t, restoration_boundary > 0)
			} else {
				testing.expect(t, storage_io.virtual_fail_stop_triggered_for_test(&world.storage))
				testing.expect_value(t, world.storage.effect_count, restoration_boundary)
				testing.expect(t, !result.ok)
				testing.expect_value(t, cap(result.catalog.segments), 0)
				testing.expect_value(t, cap(result.removed), 0)
				testing.expect_value(t, cap(result.outputs), 0)
				// Inspect volatile names directly: stopped storage rejects ordinary reads.
				generations := [?]u64{first_generation, second_generation}
				for output_generation, index in generations {
					temp_path := shard_cleaned_segment_temp_path("/shard", output_generation)
					final_path := shard_cleaned_segment_path("/shard", output_generation)
					_, temp_exists := world.storage.volatile_entries[temp_path]
					_, final_exists := world.storage.volatile_entries[final_path]
					testing.expect_value(t, temp_exists, index == 0)
					testing.expect_value(t, final_exists, index != 0)
					delete(temp_path)
					delete(final_path)
				}
			}
			generated_semantic_virtual_process_discard(&writer)
			sim_world_crash(&world)
			storage = sim_world_storage_context(&world)
			testing.expect(t, init_managed_shard_transaction_writer(&writer, storage, "/shard", shard, shard, LOGICAL_SHARD_COUNT))
			testing.expect_value(t, writer.manifest, manifest)
			testing.expect(t, generated_shard_restore_state(&writer))
			reason, equal := generated_shard_compare(&model, workspace_id, writer.floors)
			testing.expectf(t, equal, "restoration failure changed durable state: %s", reason)
		}
	}
}

@(test)
test_virtual_segment_metadata_fallback_and_ordinary_sweep :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		effect_count := 0
		baseline := virtual_segment_metadata_fallback_run(effect_count_out = &effect_count)
		testing.expectf(t, baseline == "" && effect_count > 0, "segment-metadata baseline failed after %d effects: %s", effect_count, baseline)
		if baseline != "" || effect_count <= 0 do return
		for effect_boundary in 1 ..= effect_count {
			observed_effects := 0
			diagnostic := virtual_segment_metadata_fallback_run(effect_boundary, &observed_effects)
			testing.expectf(
				t,
				diagnostic == "" && observed_effects == effect_boundary,
				"segment-metadata effect boundary=%d observed=%d failed: %s",
				effect_boundary,
				observed_effects,
				diagnostic,
			)
		}
	}
}

@(test)
test_virtual_checkpoint_job_and_result_are_kernel_events :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		testing.expect_value(t, virtual_checkpoint_event_run(), "")
	}
}

@(test)
test_hegel_generated_compaction_kernel_histories :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(generated_compaction_history_property, nil, {test_cases = 48, database_key = "generated-compaction-kernel-history-v1"})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "generated compaction kernel history failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_generated_compaction_kernel_interruption_coverage :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		for choice_index in 0 ..< len(Generated_Compaction_Interruption) {
			choice := Generated_Compaction_Interruption(choice_index)
			choices := [1]Generated_Compaction_Interruption{choice}
			diagnostic := generated_compaction_history_run(choices[:])
			testing.expectf(t, diagnostic == "", "generated compaction interruption=%v failed: %s", choice, diagnostic)
		}
		multi_generation_cases := [?][3]Generated_Compaction_Interruption {
			{.Clean, .Clean, .Clean},
			{.Crash_Before_Job, .Crash_Before_Result, .Clean},
			{.Fail_Stop_Job, .Fail_Stop_Result, .Crash_Before_Job},
		}
		graph_workload := [?]Generated_Shard_Op {
			{kind = .Update_Asset, selector = 1},
			{kind = .Create_Edge, selector = 31},
			{kind = .Query_Graph, selector = 95},
			{kind = .Delete_Asset, selector = 0},
			{kind = .Query_Graph, selector = 43},
			{kind = .Delete_Task, selector = 0},
			{kind = .Query_Graph, selector = 35},
		}
		for &choices, case_index in multi_generation_cases {
			diagnostic := generated_compaction_history_run(choices[:], graph_workload[:])
			testing.expectf(t, diagnostic == "", "generated compaction multi-generation case=%d failed: %s", case_index, diagnostic)
		}
	}
}

@(test)
test_deterministic_compaction_kernel_long_churn :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		choices: [16]Generated_Compaction_Interruption
		for &choice in choices do choice = .Clean
		generation_counts := [2]int{8, 16}
		for generation_count in generation_counts {
			diagnostic := generated_compaction_history_run(choices[:generation_count])
			testing.expectf(t, diagnostic == "", "deterministic compaction generations=%d failed: %s", generation_count, diagnostic)
		}
	}
}

@(test)
test_hegel_fine_grained_publication_crashes_recover_later_generation_authority :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(generated_fine_publication_history_property, nil, {test_cases = 24, database_key = "generated-fine-publication-history-v1"})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "fine-grained publication history failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_fine_grained_publication_later_generation_effect_coverage :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		choices := [?]Generated_Compaction_Interruption{.Clean, .Clean}
		workload := [?]Generated_Shard_Op {
			{kind = .Create_Asset, selector = 1},
			{kind = .Update_Asset, selector = 0},
			{kind = .Create_Edge, selector = 0},
			{kind = .Delete_Asset, selector = 0},
			{kind = .Create_Task},
		}
		spans: [2]int
		baseline := generated_compaction_history_run(choices[:], workload[:], effect_spans_out = spans[:])
		testing.expect_value(t, baseline, "")
		if baseline != "" do return
		for target in 0 ..< 2 {
			boundaries := min(spans[target], 12)
			for effect in 1 ..= boundaries {
				diagnostic := generated_compaction_history_run(choices[:], workload[:], fine_generation = target, fine_effect = effect)
				testing.expectf(t, diagnostic == "", "fine publication target=%d effect=%d/%d failed: %s", target, effect, boundaries, diagnostic)
				if diagnostic != "" do return
			}
		}
	}
}
