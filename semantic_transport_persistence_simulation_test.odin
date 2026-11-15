package main

import "core:fmt"
import "core:sys/linux"
import "core:testing"
import "core:time"
import hgl "hegel"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import "storage_io"

when !NRC_SIMULATION {
	_ :: fmt.eprintf
	_ :: linux.Errno
	_ :: testing.T
	_ :: time.Hour
	_ :: hgl.run
	_ :: nbio.init
	_ :: persistence.force_fsync
	_ :: pr.SendMessageV2Request
	_ :: storage_io.Context
}

when NRC_SIMULATION {
	Semantic_Transport_Persistence_Campaign :: struct {
		ctx:             Sim_Test_Context,
		requester, peer: ^NRC_Connection,
	}

	Semantic_Retained_Flush_Action :: struct {
		store:      ^Message_Store,
		flushed:    bool,
		diagnostic: string,
	}

	semantic_retained_flush_driver_action :: proc(user: rawptr) {
		action := (^Semantic_Retained_Flush_Action)(user)
		if action.store == nil || len(action.store.pending_appends) != 1 || td.message_stores.pending_write_count != 1 || action.store.fsync_in_flight {
			action.diagnostic = "semantic retained flush driver action was no longer eligible"
			return
		}
		action.store.commit_pending = true
		action.store.commit_started = {}
		did_work, flush_ok := flush_pending_retained_message_writes(&td.message_stores)
		if action.store.write_in_flight {
			if !did_work || !flush_ok || action.store.high_water != 1 || action.store.wal.record_count != 0 || action.store.fsync_in_flight {
				action.diagnostic = "semantic retained flush driver action queued state differed"
				return
			}
			action.flushed = true
			return
		}
		if !did_work ||
		   !flush_ok ||
		   action.store.high_water != 2 ||
		   action.store.wal.record_count != 1 ||
		   !action.store.fsync_in_flight ||
		   action.store.fsync_snapshot.record_count != 1 {
			action.diagnostic = "semantic retained flush driver action failed"
			return
		}
		action.flushed = true
	}

	semantic_global_segmented_outbound_count :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, conn: ^NRC_Connection) -> int {
		count := send_queue_len(conn)
		for event in campaign.ctx.sim.world.events {
			if event.domain != .Send do continue
			completion, ok := event.payload.(Sim_Send_Completion)
			if ok && completion.sock == conn.sock do count += 1
		}
		return count
	}

	semantic_retained_read_event_index :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, correlation_id: u32, phase: Retained_Dedup_Phase) -> int {
		for event, index in campaign.ctx.sim.world.events {
			if event.domain != .File_Read do continue
			completion, completion_ok := event.payload.(Sim_File_Read_Completion)
			if !completion_ok || completion.user == nil || completion.callback != retained_dedup_on_read_raw do continue
			ctx := (^Retained_Dedup_Context)(completion.user)
			if ctx.correlation_id == correlation_id && ctx.phase == phase do return index
		}
		return -1
	}

	semantic_retained_fsync_event_count :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, store: ^Message_Store) -> int {
		count := 0
		for event in campaign.ctx.sim.world.events {
			if event.domain != .Fsync do continue
			completion, completion_ok := event.payload.(Sim_Fsync_Completion)
			if completion_ok && completion.user == rawptr(store) do count += 1
		}
		return count
	}

	Semantic_Retained_Callback_Wave_Observer :: struct {
		campaign:          ^Semantic_Transport_Persistence_Campaign,
		store:             ^Message_Store,
		original_user:     rawptr,
		original_callback: proc(user: rawptr, read: int, err: linux.Errno),
		original_discard:  proc(user: rawptr),
		before_observed:   bool,
		after_observed:    bool,
		diagnostic:        string,
	}

	semantic_retained_callback_wave_observer :: proc(user: rawptr, read: int, err: linux.Errno) {
		observer := (^Semantic_Retained_Callback_Wave_Observer)(user)
		store := observer.store
		if store.high_water != 1 ||
		   store.wal.write_count != 0 ||
		   store.wal.record_count != 0 ||
		   len(store.pending_appends) != 1 ||
		   td.message_stores.pending_write_count != 1 ||
		   store.fsync_in_flight ||
		   semantic_retained_fsync_event_count(observer.campaign, store) != 0 {
			observer.diagnostic = "global segmented deferred retained append published before final callback"
		} else {
			observer.before_observed = true
		}
		observer.original_callback(observer.original_user, read, err)
		if store.high_water != 1 ||
		   store.wal.write_count != 0 ||
		   store.wal.record_count != 0 ||
		   len(store.pending_appends) != 1 ||
		   td.message_stores.pending_write_count != 1 ||
		   store.fsync_in_flight ||
		   semantic_retained_fsync_event_count(observer.campaign, store) != 0 {
			if observer.diagnostic == "" {
				observer.diagnostic = "global segmented deferred retained append published inside final callback"
			}
		} else {
			observer.after_observed = true
		}
	}

	semantic_retained_callback_wave_observer_discard :: proc(user: rawptr) {
		observer := (^Semantic_Retained_Callback_Wave_Observer)(user)
		if observer.original_discard != nil do observer.original_discard(observer.original_user)
	}

	semantic_retained_prepare_batched_callback_wave :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, store: ^Message_Store) -> string {
		if store == nil ||
		   store.async_readers != 1 ||
		   nrc_sim_file_read_count(&campaign.ctx.sim) != 1 ||
		   len(store.pending_appends) != 1 ||
		   td.message_stores.pending_write_count != 1 {
			return "global segmented deferred retained callback-wave readers did not start"
		}
		// The index and WAL opens precede the header read, and neither may
		// flush the unrelated staged append while the duplicate lookup waits.
		for _ in 0 ..< 2 {
			if !nrc_sim_run_next_file_read(&campaign.ctx.sim) || store.wal.write_count != 0 || store.fsync_in_flight {
				return "global segmented deferred retained callback-wave open failed"
			}
		}
		header_index := semantic_retained_read_event_index(campaign, 0xDA05, .Header)
		if header_index < 0 || !sim_world_dispatch_event(&campaign.ctx.sim.world, header_index) {
			return "global segmented deferred retained callback-wave header failed"
		}
		for _ in 0 ..< 2 {
			index := semantic_retained_read_event_index(campaign, 0xDA05, .Probe)
			if index < 0 || !sim_world_dispatch_event(&campaign.ctx.sim.world, index) {
				return "global segmented deferred retained duplicate probe failed"
			}
		}

		duplicate_index := semantic_retained_read_event_index(campaign, 0xDA05, .Record)
		if duplicate_index < 0 do return "global segmented deferred retained final callback wave was not runnable"
		completion, completion_ok := campaign.ctx.sim.world.events[duplicate_index].payload.(Sim_File_Read_Completion)
		if !completion_ok do return "global segmented deferred retained final callback payload differed"
		observer := Semantic_Retained_Callback_Wave_Observer {
			campaign          = campaign,
			store             = store,
			original_user     = completion.user,
			original_callback = completion.callback,
			original_discard  = completion.discard,
		}
		completion.user = &observer
		completion.callback = semantic_retained_callback_wave_observer
		completion.discard = semantic_retained_callback_wave_observer_discard
		campaign.ctx.sim.world.events[duplicate_index].payload = Sim_Event_Payload(completion)
		requester_outbound_before := semantic_global_segmented_outbound_count(campaign, campaign.requester)
		peer_outbound_before := semantic_global_segmented_outbound_count(campaign, campaign.peer)
		duplicate_event_id := campaign.ctx.sim.world.events[duplicate_index].id
		event_ids := [1]u64{duplicate_event_id}
		store.commit_pending = true
		store.commit_started = {}
		if !sim_world_dispatch_callback_wave(&campaign.ctx.sim.world, event_ids[:]) {
			// Validation/allocation failure leaves the event queued. Restore its
			// production callback because this stack observer is about to expire.
			for queued, index in campaign.ctx.sim.world.events {
				if queued.id != duplicate_event_id do continue
				queued_completion, queued_ok := queued.payload.(Sim_File_Read_Completion)
				if queued_ok {
					queued_completion.user = observer.original_user
					queued_completion.callback = observer.original_callback
					queued_completion.discard = observer.original_discard
					campaign.ctx.sim.world.events[index].payload = Sim_Event_Payload(queued_completion)
				}
				break
			}
			return "global segmented deferred retained final callback wave failed"
		}
		if observer.diagnostic != "" do return observer.diagnostic
		if !observer.before_observed || !observer.after_observed {
			return "global segmented deferred retained final callback observer did not run"
		}
		if store.write_in_flight {
			if store.async_readers != 0 ||
			   campaign.requester.retained_io != 1 ||
			   store.high_water != 1 ||
			   store.wal.write_count != 0 ||
			   store.wal.record_count != 0 ||
			   store.wal.durable_record_count != 0 ||
			   len(store.pending_appends) != 1 ||
			   td.message_stores.pending_write_count != 0 ||
			   store.fsync_in_flight ||
			   semantic_retained_fsync_event_count(campaign, store) != 0 ||
			   sim_world_domain_event_index(&campaign.ctx.sim.world, .File_Write, 0) < 0 {
				return "global segmented deferred retained callback-wave queued state differed"
			}
			if semantic_global_segmented_outbound_count(campaign, campaign.requester) != requester_outbound_before + 1 ||
			   semantic_global_segmented_outbound_count(campaign, campaign.peer) != peer_outbound_before {
				return "global segmented deferred retained callback-wave premature output"
			}
			return ""
		}
		if store.async_readers != 0 ||
		   campaign.requester.retained_io != 0 ||
		   store.high_water != 2 ||
		   store.wal.write_count != 1 ||
		   store.wal.record_count != 1 ||
		   store.wal.durable_record_count != 0 ||
		   len(store.pending_appends) != 0 ||
		   td.message_stores.pending_write_count != 0 ||
		   !store.fsync_in_flight ||
		   store.fsync_snapshot.record_count != 1 ||
		   store.fsync_snapshot.pending_bytes != store.wal.pending_bytes ||
		   store.fsync_snapshot.last_hash != store.wal.last_hash ||
		   semantic_retained_fsync_event_count(campaign, store) != 1 {
			return fmt.tprintf(
				"global segmented deferred retained callback-wave batch state differed: readers=%d retained_io=%d high=%d writes=%d records=%d durable=%d pending=%d registry=%d fsync=%v snapshot=%d",
				store.async_readers,
				campaign.requester.retained_io,
				store.high_water,
				store.wal.write_count,
				store.wal.record_count,
				store.wal.durable_record_count,
				len(store.pending_appends),
				td.message_stores.pending_write_count,
				store.fsync_in_flight,
				store.fsync_snapshot.record_count,
			)
		}
		if semantic_global_segmented_outbound_count(campaign, campaign.requester) != requester_outbound_before + 2 ||
		   semantic_global_segmented_outbound_count(campaign, campaign.peer) != peer_outbound_before + 1 {
			return "global segmented deferred retained callback-wave output ownership differed"
		}
		return ""
	}

	// Complements the larger segmented/deferred campaign. That campaign already
	// composes retained dedup, staged publication, fsync, compaction and restart;
	// this one deliberately keeps a history reader pinned while its source rolls
	// over, cancels it, and then verifies expiry and history after a crash/reopen.
	semantic_retained_lifecycle_run :: proc(order_seed: u8, descending: bool, cancel_after_publish: bool) -> string {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 0xB100 + int(order_seed))
		defer simulation_test_end(&ctx)
		ctx.sim.storage_job_event_submission = true
		server: NRC_Server
		td.server = &server
		if nbio.init(&td.io) != linux.Errno.NONE do return "retained lifecycle simulated io initialization failed"
		defer nbio.destroy(&td.io)

		workspace := "semantic-retained-lifecycle"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice-principal", init_send_queue = true)
		ctx.conns[1] = conn
		if conn == nil do return "retained lifecycle reader installation failed"
		subscribe_to_conversation(conn, 42)
		storage := sim_world_storage_context(&ctx.sim.world)
		dir := "/semantic-retained-lifecycle"
		if storage_io.make_directory(storage, dir) != nil || storage_io.sync_directory(storage, "/") != nil {
			return "retained lifecycle virtual directory initialization failed"
		}
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		if _, err := append(&td.message_stores.stores, Message_Store{}); err != nil {
			return "retained lifecycle store allocation failed"
		}
		defer {
			// Diagnostics can return with a reader pinned or a seal/fsync queued.
			// Discard those callbacks before destroying anything they reference.
			connections: [1]^NRC_Connection
			count := 0
			if ctx.conns[1] != nil {
				connections[0] = ctx.conns[1]
				count = 1
			}
			assert(nrc_sim_process_crash_discard_connections(&ctx.sim, connections[:count]), "retained lifecycle teardown could not discard callbacks")
			for &store in td.message_stores.stores do crash_message_store_for_test(&store)
			_ = shutdown_message_store_registry(&td.message_stores)
		}
		td.message_stores.active_cache.limit_bytes = 0
		store := &td.message_stores.stores[0]
		if !init_message_store_with_storage(
			store,
			storage,
			dir,
			shard,
			time.Hour,
			0,
			dedup_window = time.Hour,
			active_cache_budget = &td.message_stores.active_cache,
		) {
			return "retained lifecycle store initialization failed"
		}
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0

		now := nrc_time_unix_nanos()
		sequences: [8]u64
		live: [8]bool
		markers: [8]u64
		start := int(order_seed) % len(markers)
		for append_index in 0 ..< len(markers) {
			logical := (start + append_index) % len(markers)
			if order_seed & 1 != 0 do logical = len(markers) - 1 - logical
			marker := u64(logical + 1)
			// Include values immediately on both sides of the expiry boundary,
			// interleaved in sequence order rather than as an expired prefix.
			is_live := logical % 3 != 0
			accepted_at := is_live ? now + 1 : now
			message := test_retained_message(workspace, 42, marker, accepted_at)
			result, sequence := append_or_deduplicate_message(store, &message)
			if result != .Appended || sequence != u64(append_index + 1) do return "retained lifecycle append sequence differs from model"
			sequences[append_index] = u64(append_index + 1)
			live[append_index] = is_live
			markers[append_index] = marker
		}
		duplicate := test_retained_message(workspace, 42, markers[2], now + 2)
		duplicate_result, duplicate_sequence := append_or_deduplicate_message(store, &duplicate)
		if duplicate_result != .Duplicate || duplicate_sequence != sequences[2] || store.high_water != u64(len(markers)) {
			return "retained lifecycle in-window dedup differed from model"
		}
		persistence.force_fsync(&store.wal)
		all_live: [8]bool
		for &value in all_live do value = true
		before, before_ok := retained_history_simulation_page(conn, {conv_id = 42, limit = 20}, !descending)
		if !before_ok || !retained_history_page_matches_model(before, 42, sequences[:], all_live[:], 0, 20, !descending) {
			return "retained lifecycle history before expiry differs from model"
		}
		nrc_sim_clear_captured_frames(&ctx.sim)
		store.rotation_pending = true
		if !retained_message_flush_store(store) ||
		   !simulation_test_complete_message_lifecycle(&ctx.sim, .Message_Roll) ||
		   store.frozen == nil ||
		   !store.seal_in_flight {
			return "retained lifecycle rollover did not enter sealing"
		}

		process_message_history(conn, {conv_id = 42, limit = 20, correlation_id = 0xB101}, !descending)
		if store.async_readers != 1 || store.frozen.async_readers != 1 || conn.retained_io != 1 || nrc_sim_file_read_count(&ctx.sim) == 0 {
			return "retained lifecycle history did not pin the rolling source"
		}
		// Cross expiry while the old snapshot is pinned. The cancelled query
		// must emit nothing; a fresh query after restart uses the new cutoff.
		ctx.sim.world.now += time.Hour + time.Nanosecond
		if !cancel_after_publish {
			read_index := sim_world_domain_event_index(&ctx.sim.world, .File_Read, 0)
			if read_index < 0 || !sim_world_cancel_event(&ctx.sim.world, ctx.sim.world.events[read_index].id) {
				return "retained lifecycle pre-publication reader cancellation failed"
			}
		}
		if !sim_world_run_runnable_rank(&ctx.sim.world, 0, .Storage_Job) || !sim_world_run_runnable_rank(&ctx.sim.world, 0, .Storage_Result) {
			return "retained lifecycle seal build/publication result failed"
		}
		_, flush_ok := flush_pending_retained_message_writes(&td.message_stores)
		if !simulation_test_flush_message_writes(&ctx.sim) do return "retained lifecycle seal publication write failed"
		if !simulation_test_complete_message_lifecycle(&ctx.sim, .Message_Seal) do return "retained lifecycle seal publication dispatch failed"
		if !flush_ok || len(store.segments) != 1 || (cancel_after_publish && (store.frozen == nil || !store.frozen_published)) {
			return "retained lifecycle seal publication failed"
		}
		if cancel_after_publish {
			read_index := sim_world_domain_event_index(&ctx.sim.world, .File_Read, 0)
			if read_index < 0 || !sim_world_cancel_event(&ctx.sim.world, ctx.sim.world.events[read_index].id) {
				return "retained lifecycle post-publication reader cancellation failed"
			}
		}
		if conn.retained_io != 0 || store.async_readers != 0 || (store.frozen != nil && store.frozen.async_readers != 0) {
			return "retained lifecycle cancellation leaked connection or store pins"
		}
		_, maintenance_ok := maintain_message_store_registry(&td.message_stores)
		if !maintenance_ok || store.frozen != nil || nrc_sim_client_frame_count(&ctx.sim, conn.sock) != 0 {
			return "retained lifecycle cancelled reader retained rollover ownership or output"
		}

		connections := [?]^NRC_Connection{conn}
		if !nrc_sim_process_crash_discard_connections(&ctx.sim, connections[:]) do return "retained lifecycle process crash failed"
		simulation_test_uninstall_client(conn)
		ctx.conns[1] = nil
		crash_message_store_for_test(store)
		storage = sim_world_storage_context(&ctx.sim.world)
		if !init_message_store_with_storage(
			store,
			storage,
			dir,
			shard,
			time.Hour,
			0,
			dedup_window = time.Hour,
			active_cache_budget = &td.message_stores.active_cache,
		) {
			return "retained lifecycle crash recovery failed"
		}
		conn = simulation_test_install_client(&ctx.sim, 1, workspace, "alice-principal", init_send_queue = true)
		ctx.conns[1] = conn
		if conn == nil do return "retained lifecycle reconnect failed"
		subscribe_to_conversation(conn, 42)
		page, page_ok := retained_history_simulation_page(conn, {conv_id = 42, limit = 20, correlation_id = 0xB102}, !descending)
		if !page_ok || !retained_history_page_matches_model(page, 42, sequences[:], live[:], 0, 20, !descending) {
			return "retained lifecycle recovery history ordering/expiry differed from model"
		}
		for &message in page.messages {
			sequence_index := int(u64(message.seq) - 1)
			if sequence_index < 0 ||
			   sequence_index >= len(markers) ||
			   message_get_u64(message.client_message_id[:]) != markers[sequence_index] ||
			   string(message.content) != "hello retained world" {
				return "retained lifecycle recovery history content differed from model"
			}
		}
		// Retry a message exactly at the live/dedup boundary through the handler,
		// forcing the recovered sealed index lookup rather than an active-map hit.
		retry_index := 0
		for !live[retry_index] do retry_index += 1
		retry := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = 0xB103,
			content_type   = .PlainText,
			content        = transmute([]byte)string("hello retained world"),
		}
		message_put_u64(retry.client_message_id[:], markers[retry_index])
		nrc_sim_clear_captured_frames(&ctx.sim)
		process_send_message_v2(conn, retry)
		_, retry_ok := flush_pending_retained_message_writes(&td.message_stores)
		if !simulation_test_flush_message_writes(&ctx.sim) do return "retained lifecycle recovered retry write failed"
		if !retry_ok || nrc_sim_file_read_count(&ctx.sim) == 0 do return "retained lifecycle recovered retry did not enter sealed lookup"
		for nrc_sim_run_next_file_read(&ctx.sim) {}
		if !simulation_test_publish_output(&ctx.sim) do return "publish retained lifecycle retry output"
		if store.high_water != 8 || store.wal.record_count != 0 || nrc_sim_client_frame_count(&ctx.sim, conn.sock) != 1 {
			return "retained lifecycle recovered retry duplicated a live message"
		}
		ack_payload, ack_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, 0))
		ack, ack_err := pr.parseAckSendMessageMessage(ack_payload)
		if !ack_ok || ack_err != nil || ack.client_req_id != 0xB103 || ack.assigned_seq != pr.MessageSeq(retry_index + 1) || ack.timestamp != now + 1 {
			return "retained lifecycle recovered retry acknowledgement differs from model"
		}
		if conn.retained_io != 0 ||
		   store.async_readers != 0 ||
		   len(store.segments) != 1 ||
		   store.segments[0].readers != 0 ||
		   nrc_sim_file_read_count(&ctx.sim) != 0 {
			return "retained lifecycle recovery history leaked reader ownership"
		}
		return ""
	}
	@(test)
	test_hegel_retained_expiry_cancel_rollover_crash_histories :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		// Mandatory adversarial schedules cover cancellation on each side of
		// seal publication and both history directions even if generation shrinks.
		testing.expect_value(t, semantic_retained_lifecycle_run(0, false, false), "")
		testing.expect_value(t, semantic_retained_lifecycle_run(7, true, true), "")
		result, err := hgl.run(prop_retained_expiry_cancel_rollover_crash_histories, nil, {test_cases = 24})
		testing.expectf(
			t,
			err == nil,
			"retained expiry/cancel/rollover/crash history property failed: err=%v interesting=%v",
			err,
			result.interesting_test_cases,
		)
	}

	prop_retained_expiry_cancel_rollover_crash_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		order_raw, order_err := hgl.draw_i64(tc, 0, 255)
		if order_err == .Stop_Test do return hgl.abort()
		if order_err != nil do return hgl.interesting("draw retained lifecycle history order")
		direction_raw, direction_err := hgl.draw_i64(tc, 0, 1)
		if direction_err == .Stop_Test do return hgl.abort()
		if direction_err != nil do return hgl.interesting("draw retained lifecycle history direction")
		cancel_raw, cancel_err := hgl.draw_i64(tc, 0, 1)
		if cancel_err == .Stop_Test do return hgl.abort()
		if cancel_err != nil do return hgl.interesting("draw retained lifecycle cancellation phase")
		diagnostic := semantic_retained_lifecycle_run(u8(order_raw), direction_raw != 0, cancel_raw != 0)
		if diagnostic != "" {
			if tc.is_final {
				fmt.eprintf(
					"retained lifecycle failure: reason=%s order=%d descending=%v cancel_after_publish=%v\n",
					diagnostic,
					order_raw,
					direction_raw != 0,
					cancel_raw != 0,
				)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}
}
