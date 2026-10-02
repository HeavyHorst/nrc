package main

// Deterministic ownership coverage for the production background-compaction
// queues: owner writer -> compactor job -> owner result -> publication.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:testing"

import hgl "hegel"
import "persistence"
import "spsc"
import "storage_io"

when !NRC_SIMULATION {
	_ :: fmt.eprintf
	_ :: log.nil_logger
	_ :: os.remove_all
	_ :: runtime.Allocator_Error
	_ :: chan.try_recv
	_ :: strings.clone
	_ :: testing.T
	_ :: hgl.run
	_ :: persistence.force_fsync
	_ :: spsc.can_pop
	_ :: storage_io.Context
}

when NRC_SIMULATION {
	Shard_Compaction_Result_Disposition :: enum {
		Publish,
		Stale_Manifest,
		Wrong_Owner,
		Foreign_Shard,
		Negative_Shard,
		Upper_Bound_Shard,
		Wrong_Floors,
		Discard,
	}

	Shard_Compaction_Queue_Campaign :: struct {
		ctx:                  Sim_Test_Context,
		ctx_started:          bool,
		server:               NRC_Server,
		job_channel_started:  bool,
		result_queue_started: bool,
		registry_started:     bool,
		data_dir:             string,
		generation_dir:       string,
		primary_workspace:    string,
		secondary_workspace:  string,
		primary_shard:        int,
		secondary_shard:      int,
	}

	shard_compaction_queue_writer :: proc(campaign: ^Shard_Compaction_Queue_Campaign, index: int) -> ^Shard_Transaction_Writer {
		if campaign == nil || index < 0 || index >= len(td.shard_writers.writers) do return nil
		return &td.shard_writers.writers[index]
	}

	shard_compaction_queue_campaign_begin :: proc(campaign: ^Shard_Compaction_Queue_Campaign, name: string) -> string {
		campaign^ = {}
		simulation_test_begin(&campaign.ctx, 0)
		campaign.ctx_started = true

		channel_err: runtime.Allocator_Error
		campaign.server.shard_compaction_jobs, channel_err = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
		if channel_err != .None do return "create compaction job channel"
		campaign.job_channel_started = true
		campaign.server.shard_compaction_results = make([]^spsc.Queue(Shard_Compaction_Result), 1)
		campaign.server.shard_compaction_results[0], channel_err = spsc.create(Shard_Compaction_Result, 1, context.allocator)
		if channel_err != .None do return "create compaction result queue"
		campaign.result_queue_started = true
		td.server = &campaign.server

		campaign.primary_workspace = "generated-compaction-queue-primary"
		campaign.primary_shard = int(shard_for_workspace(transmute([]byte)campaign.primary_workspace))
		for candidate_index in 0 ..< LOGICAL_SHARD_COUNT {
			candidate := fmt.aprintf("generated-compaction-queue-secondary-%d", candidate_index)
			candidate_shard := int(shard_for_workspace(transmute([]byte)candidate))
			if candidate_shard != campaign.primary_shard {
				campaign.secondary_workspace = candidate
				campaign.secondary_shard = candidate_shard
				break
			}
			delete(candidate)
		}
		if campaign.secondary_workspace == "" do return "find distinct secondary shard"

		case_name := fmt.tprintf("generated-compaction-queue-%s", name)
		campaign.data_dir = storage_layout_test_setup(case_name)
		if !storage_layout_test_create_generation(campaign.data_dir, 1) do return "create sharded generation"
		campaign.generation_dir = sharded_generation_path(campaign.data_dir, 1)

		registry := &td.shard_writers
		for &writer_index in registry.writer_index do writer_index = -1
		registry.worker = 0
		registry.worker_count = 1
		registry.writers = make([dynamic]Shard_Transaction_Writer, 2)
		campaign.registry_started = true
		shards := [2]int{campaign.primary_shard, campaign.secondary_shard}
		for shard, writer_index in shards {
			shard_dir := sharded_shard_path(campaign.generation_dir, shard)
			initialized := init_managed_shard_transaction_writer(&registry.writers[writer_index], shard_dir, shard, 0, 1)
			delete(shard_dir)
			if !initialized do return fmt.tprintf("initialize managed writer %d", writer_index)
			registry.writer_index[shard] = i16(writer_index)
		}
		registry.mode = .Active

		primary := shard_compaction_queue_writer(campaign, 0)
		secondary := shard_compaction_queue_writer(campaign, 1)
		if !shard_compaction_test_append_task(primary, campaign.primary_workspace, 10, "primary-sealed") ||
		   !rotate_shard_writer_for_compaction(primary) ||
		   !shard_compaction_test_append_task(primary, campaign.primary_workspace, 11, "primary-active") ||
		   !rotate_shard_writer_for_compaction(primary) {
			return "prepare primary writer"
		}
		persistence.force_fsync(&primary.wal)
		if !primary.wal.enabled || primary.wal.durable_record_count != 0 do return "sync primary active WAL"
		if !shard_compaction_test_append_task(secondary, campaign.secondary_workspace, 20, "secondary-sealed") ||
		   !rotate_shard_writer_for_compaction(secondary) ||
		   !shard_compaction_test_append_task(secondary, campaign.secondary_workspace, 21, "secondary-active") ||
		   !rotate_shard_writer_for_compaction(secondary) {
			return "prepare secondary writer"
		}
		return ""
	}

	shard_compaction_queue_campaign_end :: proc(campaign: ^Shard_Compaction_Queue_Campaign) {
		if campaign.job_channel_started do discard_queued_shard_compaction_jobs(&campaign.server)
		if campaign.result_queue_started do discard_queued_shard_compaction_results(&campaign.server)
		td.server = nil
		if campaign.registry_started {
			shutdown_shard_writer_registry(&td.shard_writers)
			campaign.registry_started = false
		}
		if campaign.result_queue_started {
			spsc.destroy(campaign.server.shard_compaction_results[0])
			campaign.result_queue_started = false
		}
		if campaign.server.shard_compaction_results != nil do delete(campaign.server.shard_compaction_results)
		if campaign.job_channel_started {
			_ = chan.destroy(campaign.server.shard_compaction_jobs)
			campaign.job_channel_started = false
		}
		if campaign.generation_dir != "" do delete(campaign.generation_dir)
		if campaign.data_dir != "" {
			_ = os.remove_all(campaign.data_dir)
		}
		if campaign.secondary_workspace != "" do delete(campaign.secondary_workspace)
		if campaign.ctx_started {
			simulation_test_end(&campaign.ctx)
			campaign.ctx_started = false
		}
		campaign^ = {}
	}

	shard_compaction_queue_publish_check :: proc(campaign: ^Shard_Compaction_Queue_Campaign) -> string {
		writer := shard_compaction_queue_writer(campaign, 0)
		if writer == nil do return "published writer missing"
		if writer.compaction != .Idle || writer.manifest.sealed_present || !writer.manifest.checkpoint_present {
			return fmt.tprintf(
				"published writer state mismatch: compaction=%v sealed=%v checkpoint=%v",
				writer.compaction,
				writer.manifest.sealed_present,
				writer.manifest.checkpoint_present,
			)
		}
		if writer.floors != (Shard_High_Water_Requirements{task = 11}) || writer.compaction_floors != {} {
			return fmt.tprintf("published floor mismatch: floors=%v compaction_floors=%v", writer.floors, writer.compaction_floors)
		}
		record_count, records_ok := shard_compaction_test_referenced_record_count(writer.shard_dir, writer.manifest)
		if !records_ok || record_count != 2 {
			return fmt.tprintf("published record mismatch: ok=%v records=%d expected=2", records_ok, record_count)
		}
		if campaign.server.closing || campaign.server.fatal_storage_error {
			return "successful publication requested server shutdown"
		}
		return ""
	}

	shard_compaction_queue_campaign_run :: proc(name: string, discard_job: bool, disposition: Shard_Compaction_Result_Disposition) -> string {
		campaign: Shard_Compaction_Queue_Campaign
		diagnostic := shard_compaction_queue_campaign_begin(&campaign, name)
		defer shard_compaction_queue_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic

		primary := shard_compaction_queue_writer(&campaign, 0)
		secondary := shard_compaction_queue_writer(&campaign, 1)
		if !enqueue_shard_compaction_job(&campaign.server, primary) do return "enqueue primary compaction job"
		if primary.compaction != .Building do return "primary writer did not transfer to building state"
		// The queued job owns a value snapshot, so later rotation may publish and
		// remove the old catalog before the background service starts.
		if !rotate_shard_writer_for_compaction(primary) do return "rotate while queued compaction waits"
		if enqueue_shard_compaction_job(&campaign.server, secondary) {
			return "full compaction queue accepted secondary job"
		}
		if secondary.compaction != .Idle do return "queue-full rejection changed secondary ownership state"

		if discard_job {
			discard_queued_shard_compaction_jobs(&campaign.server)
			if service_shard_compaction_job(&campaign.server) do return "discarded job remained serviceable"
			if primary.compaction != .Building do return "job discard changed writer ownership state"
			return ""
		}

		if !service_shard_compaction_job(&campaign.server) do return "service primary compaction job"
		if service_shard_compaction_job(&campaign.server) do return "compaction job ran twice"
		result, received := spsc.try_pop(campaign.server.shard_compaction_results[0])
		if !received || !result.ok do return "receive successful compaction result"
		if disposition == .Discard {
			if primary.compaction != .Building do return "result discard changed writer ownership state"
			if result.active_reservation_generation == 0 || result.active_reservation_path == "" do return "discarded result did not carry prepared reservation ownership"
			reservation_path, clone_err := strings.clone(result.active_reservation_path)
			if clone_err != nil do return "clone discarded result reservation path"
			defer delete(reservation_path)
			if !spsc.try_push(campaign.server.shard_compaction_results[0], result) do return "return discarded result to owner queue"
			discard_queued_shard_compaction_results(&campaign.server)
			exists, exists_err := storage_io.exists(primary.storage, reservation_path)
			if exists_err != nil || exists do return "discarded result retained prepared reservation"
			return ""
		}

		switch disposition {
		case .Publish:
		case .Stale_Manifest:
			result.manifest_generation = primary.manifest.manifest_generation + 1
		case .Wrong_Owner:
			result.owner_worker = 1
		case .Foreign_Shard:
			result.shard = campaign.secondary_shard
			result.active_reservation_generation = secondary.manifest.active_generation
			result.active_reservation_prepared = true
		case .Negative_Shard:
			result.shard = -1
		case .Upper_Bound_Shard:
			result.shard = LOGICAL_SHARD_COUNT
		case .Wrong_Floors:
			result.floors.task += 1
		case .Discard:
			unreachable()
		}
		if !spsc.try_push(campaign.server.shard_compaction_results[0], result) do return "return compaction result to owner queue"

		previous_logger := context.logger
		if disposition != .Publish do context.logger = log.nil_logger()
		processed := process_shard_compaction_results()
		context.logger = previous_logger
		if !processed do return "owner worker did not process compaction result"
		if disposition == .Publish {
			return shard_compaction_queue_publish_check(&campaign)
		}
		if !campaign.server.closing || !campaign.server.fatal_storage_error {
			return "invalid result did not request fatal storage shutdown"
		}
		if primary.compaction != .Building {
			return "invalid result changed primary writer ownership state"
		}
		if disposition == .Foreign_Shard {
			secondary_active := shard_generation_wal_path(secondary.shard_dir, secondary.manifest.active_generation)
			defer delete(secondary_active)
			exists, exists_err := storage_io.exists(secondary.storage, secondary_active)
			if exists_err != nil || !exists do return "foreign result removed secondary authoritative WAL"
		}
		return ""
	}

	shard_compaction_kernel_campaign_run :: proc(name: string, discard_job: bool, disposition: Shard_Compaction_Result_Disposition) -> string {
		campaign: Shard_Compaction_Queue_Campaign
		diagnostic := shard_compaction_queue_campaign_begin(&campaign, name)
		defer shard_compaction_queue_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic

		primary := shard_compaction_queue_writer(&campaign, 0)
		if !enqueue_shard_compaction_job_event(&campaign.ctx.sim.world, primary) do return "enqueue kernel compaction job"
		if primary.compaction != .Building || sim_world_event_count(&campaign.ctx.sim.world, .Compaction_Job) != 1 {
			return "kernel job did not transfer writer ownership"
		}
		if discard_job {
			index := sim_world_domain_event_index(&campaign.ctx.sim.world, .Compaction_Job, 0)
			if index < 0 || !sim_world_cancel_event(&campaign.ctx.sim.world, campaign.ctx.sim.world.events[index].id) {
				return "discard kernel compaction job"
			}
			if sim_world_event_count(&campaign.ctx.sim.world, .Compaction_Job) != 0 || primary.compaction != .Building {
				return "kernel job discard changed writer ownership state"
			}
			return ""
		}

		if !sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) {
			return "execute kernel compaction job"
		}
		result, received := sim_world_take_compaction_result_for_test(&campaign.ctx.sim.world)
		if !received || !result.ok do return "take successful kernel compaction result"
		if disposition == .Discard {
			if primary.compaction != .Building do return "kernel result discard changed writer ownership state"
			destroy_shard_compaction_result(&result, true)
			return ""
		}

		switch disposition {
		case .Publish:
		case .Stale_Manifest:
			result.manifest_generation = primary.manifest.manifest_generation + 1
		case .Wrong_Owner:
			result.owner_worker = 1
		case .Foreign_Shard:
			result.shard = campaign.secondary_shard
		case .Negative_Shard:
			result.shard = -1
		case .Upper_Bound_Shard:
			result.shard = LOGICAL_SHARD_COUNT
		case .Wrong_Floors:
			result.floors.task += 1
		case .Discard:
			unreachable()
		}
		if sim_world_enqueue_compaction_result(&campaign.ctx.sim.world, result) == 0 {
			return "return compaction result to kernel"
		}
		previous_logger := context.logger
		if disposition != .Publish do context.logger = log.nil_logger()
		processed := sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Result))
		context.logger = previous_logger
		if !processed do return "owner worker did not process kernel compaction result"
		if disposition == .Publish {
			return shard_compaction_queue_publish_check(&campaign)
		}
		if !campaign.server.closing || !campaign.server.fatal_storage_error {
			return "invalid kernel result did not request fatal storage shutdown"
		}
		if primary.compaction != .Building {
			return "invalid kernel result changed primary writer ownership state"
		}
		return ""
	}

	@(test)
	test_shard_compaction_queue_mandatory_ownership_branches :: proc(t: ^testing.T) {
		previous_logger := context.logger
		cases := [?]struct {
			name:        string,
			discard_job: bool,
			disposition: Shard_Compaction_Result_Disposition,
		} {
			{"discard-job", true, .Publish},
			{"publish", false, .Publish},
			{"stale-manifest", false, .Stale_Manifest},
			{"wrong-owner", false, .Wrong_Owner},
			{"foreign-shard", false, .Foreign_Shard},
			{"negative-shard", false, .Negative_Shard},
			{"upper-bound-shard", false, .Upper_Bound_Shard},
			{"wrong-floors", false, .Wrong_Floors},
			{"discard-result", false, .Discard},
		}
		for test_case in cases {
			context.logger = log.nil_logger()
			queue_diagnostic := shard_compaction_queue_campaign_run(test_case.name, test_case.discard_job, test_case.disposition)
			kernel_diagnostic := shard_compaction_kernel_campaign_run(test_case.name, test_case.discard_job, test_case.disposition)
			context.logger = previous_logger
			testing.expect_value(t, queue_diagnostic, "")
			testing.expect_value(t, kernel_diagnostic, "")
		}
	}

	@(test)
	test_worker_pre_tick_publishes_compaction_result_before_followup_scheduling :: proc(t: ^testing.T) {
		campaign: Shard_Compaction_Queue_Campaign
		diagnostic := shard_compaction_queue_campaign_begin(&campaign, "pre-tick-result-followup")
		defer shard_compaction_queue_campaign_end(&campaign)
		if !testing.expect_value(t, diagnostic, "") do return

		pending_queue, queue_err := pending_queue_create(1)
		if !testing.expect_value(t, queue_err, runtime.Allocator_Error.None) do return
		td.my_pending_queue = pending_queue
		defer {
			td.my_pending_queue = {}
			pending_queue_destroy(pending_queue)
		}

		writer := shard_compaction_queue_writer(&campaign, 0)
		if !testing.expect(t, writer != nil && enqueue_shard_compaction_job(&campaign.server, writer)) do return
		initial_manifest := writer.manifest
		// A concurrent rotation extends the authoritative source while the
		// background job still owns its earlier snapshot. Publishing that result
		// leaves follow-up cleaning work, but the writer remains Building until
		// the owner drains the result queue.
		if !testing.expect(t, rotate_shard_writer_for_compaction(writer)) do return
		extended_source, source_ok := shard_segment_source_for_writer(writer)
		if !testing.expect(t, source_ok) do return
		defer destroy_shard_segment_clean_source(&extended_source)
		testing.expect_value(t, len(extended_source.segments), 3)
		testing.expect_value(t, writer.compaction, Shard_Compaction_Status.Building)

		if !testing.expect(t, service_shard_compaction_job(&campaign.server)) do return
		testing.expect_value(t, chan.len(campaign.server.shard_compaction_jobs), 0)
		testing.expect(t, spsc.can_pop(campaign.server.shard_compaction_results[0]))
		td.shard_writers.compaction_cursor = 0

		testing.expect(t, worker_run_pre_tick(), "pre-tick should publish and schedule follow-up work")
		testing.expect(t, !spsc.can_pop(campaign.server.shard_compaction_results[0]))
		testing.expect_value(t, writer.compaction, Shard_Compaction_Status.Building)
		testing.expect(t, writer.manifest.manifest_generation > initial_manifest.manifest_generation)
		testing.expect(t, writer.manifest.checkpoint_present && !writer.manifest.sealed_present)

		followup, received := chan.try_recv(campaign.server.shard_compaction_jobs)
		if !testing.expect(t, received, "result publication should make one follow-up job eligible in the same turn") do return
		defer {
			if followup.active_reservation_generation != 0 {
				remove_shard_active_reservation(followup.storage, followup.shard_dir, followup.active_reservation_generation)
			}
			if followup.shard_dir != "" do delete(followup.shard_dir)
			if followup.source_present do destroy_shard_segment_clean_source(&followup.source)
		}
		testing.expect_value(t, followup.owner_worker, 0)
		testing.expect_value(t, followup.shard, campaign.primary_shard)
		testing.expect_value(t, followup.manifest, writer.manifest)
		testing.expect_value(t, followup.expected_source_floors, writer.catalog_floors)
		testing.expect(t, followup.source_present && len(followup.source.segments) > 0)
		testing.expect_value(t, chan.len(campaign.server.shard_compaction_jobs), 0)
	}

	@(test)
	test_shard_compaction_failed_result_delivery_removes_prepared_reservation :: proc(t: ^testing.T) {
		campaign: Shard_Compaction_Queue_Campaign
		diagnostic := shard_compaction_queue_campaign_begin(&campaign, "failed-result-delivery")
		defer shard_compaction_queue_campaign_end(&campaign)
		testing.expect_value(t, diagnostic, "")
		if diagnostic != "" do return

		primary := shard_compaction_queue_writer(&campaign, 0)
		testing.expect(t, enqueue_shard_compaction_job(&campaign.server, primary))
		job, received := chan.try_recv(campaign.server.shard_compaction_jobs)
		testing.expect(t, received && job.active_reservation_generation != 0)
		if !received || job.active_reservation_generation == 0 do return
		reservation_path := shard_generation_wal_path(primary.shard_dir, job.active_reservation_generation)
		defer delete(reservation_path)
		testing.expect(t, chan.send(campaign.server.shard_compaction_jobs, job))
		testing.expect(t, spsc.try_push(campaign.server.shard_compaction_results[0], Shard_Compaction_Result{}))
		testing.expect(t, service_shard_compaction_job(&campaign.server))
		exists, exists_err := storage_io.exists(primary.storage, reservation_path)
		testing.expect(t, exists_err == nil && !exists, "failed result delivery must remove its prepared active WAL")
		dummy, dummy_received := spsc.try_pop(campaign.server.shard_compaction_results[0])
		if dummy_received do destroy_shard_compaction_result(&dummy, false)
	}

	@(test)
	test_shard_compaction_failed_build_removes_prepared_reservation_before_delivery :: proc(t: ^testing.T) {
		campaign: Shard_Compaction_Queue_Campaign
		diagnostic := shard_compaction_queue_campaign_begin(&campaign, "failed-build-reservation")
		defer shard_compaction_queue_campaign_end(&campaign)
		testing.expect_value(t, diagnostic, "")
		if diagnostic != "" do return

		writer := shard_compaction_queue_writer(&campaign, 0)
		if writer.shard == 0 {
			writer = shard_compaction_queue_writer(&campaign, 1)
		}
		testing.expect(t, writer != nil && writer.shard != 0)
		if writer == nil || writer.shard == 0 do return
		testing.expect(t, enqueue_shard_compaction_job(&campaign.server, writer))
		job, received := chan.try_recv(campaign.server.shard_compaction_jobs)
		testing.expect(t, received && job.active_reservation_generation != 0)
		if !received || job.active_reservation_generation == 0 do return
		reservation_path := shard_generation_wal_path(writer.shard_dir, job.active_reservation_generation)
		defer delete(reservation_path)
		job.clean_start = len(job.source.segments)
		testing.expect(t, chan.send(campaign.server.shard_compaction_jobs, job))
		testing.expect(t, service_shard_compaction_job(&campaign.server))
		exists, exists_err := storage_io.exists(writer.storage, reservation_path)
		testing.expect(t, exists_err == nil && !exists, "failed compaction build must remove its unaccepted active reservation")

		previous_logger := context.logger
		context.logger = log.nil_logger()
		processed := process_shard_compaction_results()
		context.logger = previous_logger
		testing.expect(t, processed)
		testing.expect(t, campaign.server.closing && campaign.server.fatal_storage_error)
	}

	@(test)
	test_hegel_shard_compaction_queue_ownership_transfer :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_shard_compaction_queue_ownership_transfer, nil, {test_cases = 48})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "shard compaction queue ownership property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	prop_shard_compaction_queue_ownership_transfer :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		discard_job, discard_err := hgl.draw_bool(tc)
		if discard_err == .Stop_Test do return hgl.abort()
		if discard_err != nil do return hgl.interesting("draw job disposition")
		disposition_raw, disposition_err := hgl.draw_i64(tc, 0, i64(len(Shard_Compaction_Result_Disposition) - 1))
		if disposition_err == .Stop_Test do return hgl.abort()
		if disposition_err != nil do return hgl.interesting("draw result disposition")
		diagnostic := shard_compaction_queue_campaign_run("hegel", discard_job, Shard_Compaction_Result_Disposition(disposition_raw))
		if diagnostic != "" do return hgl.interesting(diagnostic)
		diagnostic = shard_compaction_kernel_campaign_run("hegel-kernel", discard_job, Shard_Compaction_Result_Disposition(disposition_raw))
		if diagnostic != "" do return hgl.interesting(diagnostic)
		return hgl.valid()
	}
}
