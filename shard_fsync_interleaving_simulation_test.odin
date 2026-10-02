package main

// Generated ordering coverage for the asynchronous shard-WAL fsync boundary.
// Production appends continue while a submitted durability snapshot is pending;
// only its callback may advance that snapshot's durable watermark.

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"
import "core:testing"

import hgl "hegel"

when !NRC_SIMULATION {
	_ :: fmt.eprintf
	_ :: log.nil_logger
	_ :: os.remove_all
	_ :: linux.Errno
	_ :: testing.T
	_ :: hgl.run
}

when NRC_SIMULATION {
	Shard_Fsync_Campaign :: struct {
		ctx:               Sim_Test_Context,
		ctx_started:       bool,
		registry:          Shard_Writer_Registry,
		registry_started:  bool,
		writer:            ^Shard_Transaction_Writer,
		test_data:         Shard_Writer_Test_Data,
		test_data_started: bool,
		data_dir:          string,
		generation_dir:    string,
		workspace:         string,
		shard:             int,
	}

	shard_fsync_campaign_begin :: proc(campaign: ^Shard_Fsync_Campaign, name: string) -> string {
		campaign^ = {}
		campaign.workspace = "generated-shard-fsync-interleaving"
		campaign.shard = int(shard_for_workspace(transmute([]byte)campaign.workspace))
		simulation_test_begin(&campaign.ctx, 126)
		campaign.ctx_started = true

		case_name := fmt.tprintf("generated-shard-fsync-interleaving-%s", name)
		campaign.data_dir = storage_layout_test_setup(case_name)
		if !storage_layout_test_create_generation(campaign.data_dir, 1) {
			return "create sharded generation"
		}
		campaign.generation_dir = sharded_generation_path(campaign.data_dir, 1)
		if !init_shard_writer_registry(&campaign.registry, campaign.generation_dir, campaign.shard, LOGICAL_SHARD_COUNT) {
			return "initialize shard writer registry"
		}
		campaign.registry_started = true
		campaign.writer = shard_writer_for_workspace(&campaign.registry, transmute([]byte)campaign.workspace)
		if campaign.writer == nil {
			return "find campaign shard writer"
		}

		shard_writer_test_transaction_init(&campaign.test_data, campaign.workspace)
		campaign.test_data_started = true
		if !append_shard_transaction(campaign.writer, &campaign.test_data.tx) {
			return "append first transaction"
		}
		campaign.writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&campaign.registry)
		if !sync_ok || !did_work {
			return "submit first fsync"
		}
		if campaign.writer.fsync_snapshot.record_count != 1 || campaign.writer.fsync_snapshot.pending_bytes == 0 {
			return "first fsync captured the wrong WAL snapshot"
		}
		first_record_bytes := campaign.writer.fsync_snapshot.pending_bytes
		campaign.test_data.tx.task_high_water = 11
		if !append_shard_transaction(campaign.writer, &campaign.test_data.tx) {
			return "append second transaction while first fsync is pending"
		}
		if campaign.writer.wal.pending_bytes != first_record_bytes || campaign.writer.wal.buffered_record_count != 1 {
			return "second append joined the in-flight WAL snapshot"
		}
		return shard_fsync_campaign_check(campaign, 2, 0, true, false, false)
	}

	shard_fsync_campaign_end :: proc(campaign: ^Shard_Fsync_Campaign) {
		if campaign.ctx_started {
			for nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {}
		}
		if campaign.registry_started {
			shutdown_shard_writer_registry(&campaign.registry)
			campaign.registry_started = false
		}
		if campaign.test_data_started {
			shard_writer_test_transaction_destroy(&campaign.test_data)
			campaign.test_data_started = false
		}
		if campaign.generation_dir != "" do delete(campaign.generation_dir)
		if campaign.data_dir != "" {
			_ = os.remove_all(campaign.data_dir)
		}
		if campaign.ctx_started {
			simulation_test_end(&campaign.ctx)
			campaign.ctx_started = false
		}
		campaign^ = {}
	}

	shard_fsync_campaign_check :: proc(campaign: ^Shard_Fsync_Campaign, record_count, durable_count: u64, in_flight, poisoned, rotated: bool) -> string {
		writer := campaign.writer
		if writer == nil do return "campaign writer missing"
		if writer.poisoned != poisoned {
			return fmt.tprintf("poison mismatch: got=%v expected=%v", writer.poisoned, poisoned)
		}
		if writer.fsync_in_flight != in_flight {
			return fmt.tprintf("in-flight mismatch: got=%v expected=%v", writer.fsync_in_flight, in_flight)
		}
		expected_completions := 0
		if in_flight do expected_completions = 1
		if nrc_sim_fsync_completion_count(&campaign.ctx.sim) != expected_completions {
			return fmt.tprintf("queued fsync mismatch: got=%d expected=%d", nrc_sim_fsync_completion_count(&campaign.ctx.sim), expected_completions)
		}
		if writer.wal.record_count + writer.wal.buffered_record_count != record_count || writer.wal.durable_record_count != durable_count {
			return fmt.tprintf(
				"WAL count mismatch: records=%d/%d durable=%d/%d",
				writer.wal.record_count,
				record_count,
				writer.wal.durable_record_count,
				durable_count,
			)
		}
		if writer.wal.enabled == poisoned {
			return fmt.tprintf("WAL enabled mismatch: enabled=%v poisoned=%v", writer.wal.enabled, poisoned)
		}
		rotation_published := writer.compaction == .Idle && !writer.manifest.sealed_present && writer.manifest.segmented && writer.catalog_segments == 1
		if rotated != rotation_published {
			return fmt.tprintf("rotation state mismatch: compaction=%v sealed=%v expected=%v", writer.compaction, writer.manifest.sealed_present, rotated)
		}
		if !poisoned && !rotated && writer.wal.buffered_record_count == 0 {
			if durable_count < record_count && writer.wal.pending_bytes == 0 {
				return "non-durable records lost their pending-byte watermark"
			}
			if durable_count == record_count && writer.wal.pending_bytes != 0 {
				return fmt.tprintf("fully durable WAL retained %d pending bytes", writer.wal.pending_bytes)
			}
		}
		return ""
	}

	shard_fsync_campaign_complete :: proc(campaign: ^Shard_Fsync_Campaign, err: linux.Errno) -> bool {
		previous_logger := context.logger
		if err != .NONE do context.logger = log.nil_logger()
		completed := nrc_sim_run_next_fsync_completion(&campaign.ctx.sim, err)
		context.logger = previous_logger
		return completed
	}

	shard_fsync_campaign_rotate_and_restart :: proc(campaign: ^Shard_Fsync_Campaign) -> string {
		if !rotate_shard_writer_for_compaction(campaign.writer) {
			return "rotation should succeed after the async fsync is drained"
		}
		diagnostic := shard_fsync_campaign_check(campaign, 0, 0, false, false, true)
		if diagnostic != "" do return diagnostic

		if !shutdown_shard_writer_registry(&campaign.registry) {
			return "shutdown rotated writer registry"
		}
		campaign.registry_started = false
		campaign.writer = nil
		if !init_shard_writer_registry(&campaign.registry, campaign.generation_dir, campaign.shard, LOGICAL_SHARD_COUNT) {
			return "restart rotated writer registry"
		}
		campaign.registry_started = true
		campaign.writer = shard_writer_for_workspace(&campaign.registry, transmute([]byte)campaign.workspace)
		if campaign.writer == nil do return "find restarted shard writer"
		diagnostic = shard_fsync_campaign_check(campaign, 0, 0, false, false, true)
		if diagnostic != "" do return diagnostic
		if campaign.writer.floors != (Shard_High_Water_Requirements{task = 11, asset = 20, edge = 30}) {
			return fmt.tprintf("restarted high-water mismatch: %v", campaign.writer.floors)
		}
		floors, replay_ok := replay_shard_checkpoint_input(campaign.writer.shard_dir, campaign.writer.manifest, false)
		if !replay_ok || floors != campaign.writer.floors {
			return fmt.tprintf("sealed WAL replay mismatch: ok=%v floors=%v expected=%v", replay_ok, floors, campaign.writer.floors)
		}
		sealed_path := shard_generation_wal_path(campaign.writer.shard_dir, campaign.writer.manifest.sealed_generation)
		defer delete(sealed_path)
		inspection, _, inspect_ok := scan_shard_transaction_wal(sealed_path, campaign.shard, {}, false, false)
		if !inspect_ok || inspection.record_count != 2 {
			return fmt.tprintf("sealed WAL record mismatch: ok=%v records=%d expected=2", inspect_ok, inspection.record_count)
		}
		return ""
	}

	shard_fsync_campaign_run :: proc(
		name: string,
		first_error, rotate_after_first, second_error: bool,
		attempt_rotation_while_first, attempt_rotation_while_second: bool,
	) -> string {
		campaign: Shard_Fsync_Campaign
		diagnostic := shard_fsync_campaign_begin(&campaign, name)
		defer shard_fsync_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic

		if attempt_rotation_while_first && rotate_shard_writer_for_compaction(campaign.writer) {
			return "rotation succeeded while first fsync was in flight"
		}
		first_err := linux.Errno.NONE
		if first_error do first_err = .EIO
		if !shard_fsync_campaign_complete(&campaign, first_err) {
			return "first fsync completion missing"
		}
		if first_error {
			diagnostic = shard_fsync_campaign_check(&campaign, 2, 0, false, true, false)
			if diagnostic != "" do return diagnostic
			if append_shard_transaction(campaign.writer, &campaign.test_data.tx) {
				return "poisoned writer accepted an append"
			}
			if rotate_shard_writer_for_compaction(campaign.writer) {
				return "poisoned writer rotated"
			}
			return ""
		}

		diagnostic = shard_fsync_campaign_check(&campaign, 2, 1, false, false, false)
		if diagnostic != "" do return diagnostic
		if campaign.writer.wal.pending_bytes != 0 || campaign.writer.wal.buffered_record_count != 1 {
			return "first completion consumed or flushed the next commit batch"
		}
		if rotate_after_first {
			return shard_fsync_campaign_rotate_and_restart(&campaign)
		}

		campaign.writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&campaign.registry)
		if !sync_ok || !did_work do return "submit second fsync"
		diagnostic = shard_fsync_campaign_check(&campaign, 2, 1, true, false, false)
		if diagnostic != "" do return diagnostic
		if attempt_rotation_while_second && rotate_shard_writer_for_compaction(campaign.writer) {
			return "rotation succeeded while second fsync was in flight"
		}

		second_err := linux.Errno.NONE
		if second_error do second_err = .EIO
		if !shard_fsync_campaign_complete(&campaign, second_err) {
			return "second fsync completion missing"
		}
		if second_error {
			diagnostic = shard_fsync_campaign_check(&campaign, 2, 1, false, true, false)
			if diagnostic != "" do return diagnostic
			if rotate_shard_writer_for_compaction(campaign.writer) {
				return "writer rotated after second fsync failure"
			}
			return ""
		}

		diagnostic = shard_fsync_campaign_check(&campaign, 2, 2, false, false, false)
		if diagnostic != "" do return diagnostic
		return shard_fsync_campaign_rotate_and_restart(&campaign)
	}

	@(test)
	test_shard_fsync_interleaving_mandatory_branches :: proc(t: ^testing.T) {
		previous_logger := context.logger
		context.logger = log.nil_logger()
		diagnostics := [?]string {
			shard_fsync_campaign_run("mandatory-rotate-after-first", false, true, false, true, false),
			shard_fsync_campaign_run("mandatory-complete-second", false, false, false, true, true),
			shard_fsync_campaign_run("mandatory-first-failure", true, false, false, true, false),
			shard_fsync_campaign_run("mandatory-second-failure", false, false, true, false, true),
		}
		context.logger = previous_logger
		for diagnostic in diagnostics do testing.expect_value(t, diagnostic, "")
	}

	@(test)
	test_shard_fsync_runtime_destroy_delivers_one_error_completion_before_writer_shutdown :: proc(t: ^testing.T) {
		previous_logger := context.logger
		campaign: Shard_Fsync_Campaign
		diagnostic := shard_fsync_campaign_begin(&campaign, "runtime-destroy")
		defer shard_fsync_campaign_end(&campaign)
		testing.expect_value(t, diagnostic, "")
		if diagnostic != "" do return

		testing.expect_value(t, nrc_sim_fsync_completion_count(&campaign.ctx.sim), 1)
		context.logger = log.nil_logger()
		nrc_sim_runtime_destroy(&campaign.ctx.sim)
		context.logger = previous_logger
		testing.expect(t, campaign.writer.poisoned && !campaign.writer.wal.enabled)
		testing.expect(t, !campaign.writer.fsync_in_flight)
		testing.expect_value(t, nrc_sim_fsync_completion_count(&campaign.ctx.sim), 0)
		testing.expect(t, !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim), "destroyed completion must not run twice")
		testing.expect(t, shutdown_shard_writer_registry(&campaign.registry))
		campaign.registry_started = false
		campaign.writer = nil
	}

	@(test)
	test_hegel_shard_fsync_completion_interleavings :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_shard_fsync_completion_interleavings, nil, {test_cases = 64})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "shard fsync interleaving property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	prop_shard_fsync_completion_interleavings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		first_error, draw_err := hgl.draw_bool(tc)
		if draw_err == .Stop_Test do return hgl.abort()
		if draw_err != nil do return hgl.interesting("draw first fsync result")
		rotate_after_first, rotate_draw_err := hgl.draw_bool(tc)
		if rotate_draw_err == .Stop_Test do return hgl.abort()
		if rotate_draw_err != nil do return hgl.interesting("draw early rotation")
		second_error, second_draw_err := hgl.draw_bool(tc)
		if second_draw_err == .Stop_Test do return hgl.abort()
		if second_draw_err != nil do return hgl.interesting("draw second fsync result")
		attempt_first, first_attempt_draw_err := hgl.draw_bool(tc)
		if first_attempt_draw_err == .Stop_Test do return hgl.abort()
		if first_attempt_draw_err != nil do return hgl.interesting("draw first in-flight rotation")
		attempt_second, second_attempt_draw_err := hgl.draw_bool(tc)
		if second_attempt_draw_err == .Stop_Test do return hgl.abort()
		if second_attempt_draw_err != nil do return hgl.interesting("draw second in-flight rotation")

		diagnostic := shard_fsync_campaign_run("hegel", first_error, rotate_after_first, second_error, attempt_first, attempt_second)
		if diagnostic != "" do return hgl.interesting(diagnostic)
		return hgl.valid()
	}
}
