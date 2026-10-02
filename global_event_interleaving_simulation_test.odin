package main

// Cross-queue deterministic simulation for connection lifetime events. Unlike
// the focused queue tests, this campaign chooses the next runnable operation
// from receive, send, timer, close, graceful-close initiation, and socket reuse.

import "core:fmt"
import "core:net"
import "core:testing"
import "core:time"

import "byte_pool"
import hgl "hegel"

when !NRC_SIMULATION {
	_ :: fmt.eprintf
	_ :: net.TCP_Socket
	_ :: testing.T
	_ :: time.Second
	_ :: byte_pool.alloc
	_ :: hgl.run
}

when NRC_SIMULATION {
	Global_Event_Close_Mode :: enum {
		Physical,
		Graceful,
		Watchdog,
		Partial_Send,
		Partial_Send_Error,
	}

	Global_Event_Action :: enum {
		Start_Close,
		Start_Physical_Close,
		Run_Event,
		Run_Receive,
		Run_Send,
		Run_Timer,
		Run_Close,
		Run_Maintenance,
		Install_Replacement,
	}

	Global_Event_Campaign :: struct {
		ctx:                     Sim_Test_Context,
		mode:                    Global_Event_Close_Mode,
		old_handle:              Connection_Handle,
		old_sock:                net.TCP_Socket,
		old_counted:             bool,
		close_started:           bool,
		maintenance_ran:         bool,
		partial_send_ran:        bool,
		replacement:             ^NRC_Connection,
		send_record:             Sim_Delayed_Send_Test_Record,
		send_started_at:         time.Time,
		send_watchdog_slot:      u32,
		quiescence_baseline:     Sim_Quiescence_Baseline,
		pool_live_before:        uint,
		invalid_releases_before: u64,
	}

	global_event_run_maintenance :: proc(user: rawptr) {
		campaign := (^Global_Event_Campaign)(user)
		campaign.maintenance_ran = true
		run_worker_maintenance()
		old_conn := global_event_old_connection(campaign)
		if old_conn != nil && old_conn.state >= .Closing {
			campaign.close_started = true
		}
	}

	global_event_old_connection :: proc(campaign: ^Global_Event_Campaign) -> ^NRC_Connection {
		return connection_get_by_handle(campaign.old_handle)
	}

	global_event_partial_mode :: proc(mode: Global_Event_Close_Mode) -> bool {
		return mode == .Partial_Send || mode == .Partial_Send_Error
	}

	global_event_old_queued_io_count :: proc(campaign: ^Global_Event_Campaign) -> u32 {
		count: u32
		for ordinal in 0 ..< nrc_sim_send_completion_count(&campaign.ctx.sim) {
			completion, ok := nrc_sim_send_completion_at(&campaign.ctx.sim, ordinal)
			if !ok do continue
			switch completion.kind {
			case .Queued_Send:
				if completion.item.handle == campaign.old_handle do count += 1
			case .Writev:
				if completion.batch_state != nil && completion.batch_state.count > 0 && completion.batch_state.items[0].handle == campaign.old_handle {
					count += 1
				}
			}
		}
		for ordinal in 0 ..< nrc_sim_receive_event_count(&campaign.ctx.sim) {
			event, ok := nrc_sim_receive_event_at(&campaign.ctx.sim, ordinal)
			if !ok do continue
			if event.ctx.handle == campaign.old_handle do count += 1
		}
		for ordinal in 0 ..< nrc_sim_close_completion_count(&campaign.ctx.sim) {
			event, ok := nrc_sim_close_event_at(&campaign.ctx.sim, ordinal)
			if !ok do continue
			if event.ctx.handle == campaign.old_handle do count += 1
		}
		for ordinal in 0 ..< nrc_sim_shutdown_send_count(&campaign.ctx.sim) {
			event, ok := nrc_sim_shutdown_send_at(&campaign.ctx.sim, ordinal)
			if !ok do continue
			if event.ctx.handle == campaign.old_handle do count += 1
		}
		return count
	}

	global_event_campaign_check :: proc(campaign: ^Global_Event_Campaign) -> string {
		old_conn := global_event_old_connection(campaign)
		queued_io := global_event_old_queued_io_count(campaign)
		if old_conn == nil {
			if queued_io != 0 {
				return "old handle reclaimed while queued I/O still references it"
			}
		} else {
			// Closing reserves one pin before cancellation. It becomes the close
			// completion's pin only after every earlier I/O context has retired.
			reserved_close := old_conn.state >= .Closing && !old_conn.close_submitted ? u32(1) : u32(0)
			if old_conn.pending_io != queued_io + reserved_close {
				return fmt.tprintf("old pending_io mismatch: connection=%d queued=%d reserved_close=%d", old_conn.pending_io, queued_io, reserved_close)
			}
			if old_conn.close_completed && queued_io == 0 {
				return "closed old handle retained without queued I/O"
			}
		}

		if campaign.replacement != nil {
			if connection_get(campaign.old_sock) != campaign.replacement {
				return "stale event changed the replacement socket mapping"
			}
			if campaign.replacement.verified_username != "replacement" ||
			   campaign.replacement.state != .Idle ||
			   campaign.replacement.is_sending ||
			   campaign.replacement.pending_io != 0 {
				return "stale event mutated replacement connection state"
			}
		}
		return ""
	}

	global_event_campaign_begin :: proc(campaign: ^Global_Event_Campaign, mode: Global_Event_Close_Mode) -> bool {
		campaign^ = {}
		campaign.mode = mode
		simulation_test_begin(&campaign.ctx, 124)

		old_conn := simulation_test_install_client(&campaign.ctx.sim, 0, "global_events", "old", init_send_queue = true)
		if old_conn == nil do return false
		campaign.ctx.conns[0] = old_conn
		campaign.old_handle = old_conn.handle
		campaign.old_sock = old_conn.sock
		campaign.old_counted = true
		campaign.quiescence_baseline = sim_worker_quiescence_baseline()
		campaign.pool_live_before = connection_lifetime_pool_live_alloc_count(td.spool)
		campaign.invalid_releases_before = td.spool.invalid_release_count
		campaign.send_record.expected_handle = old_conn.handle
		if global_event_partial_mode(mode) {
			nrc_sim_inject_next_queued_send_partial(&campaign.ctx.sim, 3)
			if mode == .Partial_Send_Error {
				nrc_sim_inject_next_queued_send_error(&campaign.ctx.sim, net.TCP_Send_Error(.Not_Connected))
			}
		}

		buf, alloc_err := byte_pool.alloc(td.spool, 8)
		if alloc_err != .None do return false
		copy(buf, []byte{1, 2, 3, 4, 5, 6, 7, 8})
		if !nrc_send_frame(
			old_conn,
			Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			observer = {callback = simulation_delayed_send_test_callback, ctx = &campaign.send_record},
		) {
			return false
		}
		if mode == .Watchdog {
			send_watchdog_started(old_conn, time.time_add(old_conn.send_started_at, -Conn_Send_Timeout))
		}
		campaign.send_started_at = old_conn.send_started_at
		campaign.send_watchdog_slot = old_conn.send_watchdog_slot

		masked_ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		if !nrc_sim_enqueue_receive(&campaign.ctx.sim, old_conn, masked_ping[:]) do return false
		if mode == .Watchdog {
			if sim_world_enqueue_driver_action(&campaign.ctx.sim.world, campaign, global_event_run_maintenance) == 0 do return false
		}
		return true
	}

	global_event_campaign_end :: proc(campaign: ^Global_Event_Campaign) {
		// Hegel may stop after the socket mapping is released but before another
		// selected event observes final old-generation reclamation. Settle the
		// fake-install counter here; production callbacks still own the handle.
		if campaign.old_counted {
			connection_test_live_count -= 1
			campaign.old_counted = false
		}
		// A generated case can exhaust its Hegel choices after scheduling a
		// graceful-close timer. Run it so its heap context follows the production
		// callback cleanup path before generic runtime destruction frees timers.
		nrc_sim_run_all_timers(&campaign.ctx.sim)
		simulation_test_end(&campaign.ctx)
	}

	global_event_campaign_actions :: proc(campaign: ^Global_Event_Campaign, actions: ^[8]Global_Event_Action) -> int {
		count := 0
		old_conn := global_event_old_connection(campaign)
		if !campaign.close_started &&
		   old_conn != nil &&
		   (campaign.mode != .Watchdog || campaign.maintenance_ran) &&
		   (!global_event_partial_mode(campaign.mode) || campaign.partial_send_ran) {
			actions[count] = .Start_Close
			count += 1
		}
		if campaign.mode == .Graceful &&
		   campaign.close_started &&
		   old_conn != nil &&
		   connection_get(campaign.old_sock) == old_conn &&
		   old_conn.state == .Will_Close &&
		   nrc_sim_timer_event_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Start_Physical_Close
			count += 1
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Run_Receive
			count += 1
		}
		if nrc_sim_send_completion_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Run_Send
			count += 1
		}
		if nrc_sim_timer_event_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Run_Timer
			count += 1
		}
		if nrc_sim_close_completion_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Run_Close
			count += 1
		}
		if sim_world_event_count(&campaign.ctx.sim.world, .Driver_Action) > 0 {
			actions[count] = .Run_Maintenance
			count += 1
		}

		old_reclaimed := connection_get_by_handle(campaign.old_handle) == nil
		if campaign.replacement == nil && old_reclaimed {
			actions[count] = .Install_Replacement
			count += 1
		}
		return count
	}

	global_event_campaign_generated_actions :: proc(campaign: ^Global_Event_Campaign, actions: ^[4]Global_Event_Action) -> int {
		count := 0
		old_conn := global_event_old_connection(campaign)
		if !campaign.close_started &&
		   old_conn != nil &&
		   (campaign.mode != .Watchdog || campaign.maintenance_ran) &&
		   (!global_event_partial_mode(campaign.mode) || campaign.partial_send_ran) {
			actions[count] = .Start_Close
			count += 1
		}
		if campaign.mode == .Graceful &&
		   campaign.close_started &&
		   old_conn != nil &&
		   connection_get(campaign.old_sock) == old_conn &&
		   old_conn.state == .Will_Close &&
		   nrc_sim_timer_event_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Start_Physical_Close
			count += 1
		}
		if len(campaign.ctx.sim.world.events) > 0 {
			actions[count] = .Run_Event
			count += 1
		}
		if campaign.replacement == nil && connection_get_by_handle(campaign.old_handle) == nil {
			actions[count] = .Install_Replacement
			count += 1
		}
		return count
	}

	global_event_campaign_run :: proc(campaign: ^Global_Event_Campaign, action: Global_Event_Action, runnable_rank: int = 0) -> string {
		old_before := global_event_old_connection(campaign)
		old_state_before := Connection_State.Closed
		if old_before != nil do old_state_before = old_before.state
		sends_before := nrc_sim_send_completion_count(&campaign.ctx.sim)
		ran_domain: Maybe(Sim_Event_Domain)
		ran_partial_progress := false

		switch action {
		case .Start_Close:
			if old_before == nil || campaign.close_started do return "close start was not runnable"
			if campaign.mode == .Watchdog && !campaign.maintenance_ran do return "fallback close ran before watchdog maintenance"
			campaign.close_started = true
			if campaign.mode == .Physical || campaign.mode == .Watchdog || global_event_partial_mode(campaign.mode) {
				connection_close(old_before, false)
			} else {
				send_websocket_close_frame_and_close(old_before, 1013, "Global event campaign")
			}

		case .Start_Physical_Close:
			if campaign.mode != .Graceful ||
			   old_before == nil ||
			   old_before.state != .Will_Close ||
			   connection_get(campaign.old_sock) != old_before ||
			   nrc_sim_timer_event_count(&campaign.ctx.sim) == 0 {
				return "physical close was not runnable during graceful timer delay"
			}
			connection_close(old_before, false)

		case .Run_Event:
			runnable_count := sim_world_prepare_runnable(&campaign.ctx.sim.world)
			if runnable_rank < 0 || runnable_rank >= runnable_count do return "event rank was not runnable"
			index := sim_world_runnable_rank_index(&campaign.ctx.sim.world, runnable_rank)
			if index < 0 do return "ranked event was not found"
			ran_domain = campaign.ctx.sim.world.events[index].domain
			if completion, ok := campaign.ctx.sim.world.events[index].payload.(Sim_Send_Completion); ok {
				ran_partial_progress = completion.continues
			}
			if !sim_world_dispatch_event(&campaign.ctx.sim.world, index) do return "ranked event did not run"

		case .Run_Receive:
			ran_domain = Sim_Event_Domain.Receive
			if !nrc_sim_run_next_receive(&campaign.ctx.sim) do return "receive event was not runnable"

		case .Run_Send:
			ran_domain = Sim_Event_Domain.Send
			completion, ok := nrc_sim_send_completion_at(&campaign.ctx.sim, 0)
			if !ok do return "send event was not found"
			ran_partial_progress = completion.continues
			if !nrc_sim_run_next_send_completion(&campaign.ctx.sim) do return "send event was not runnable"

		case .Run_Timer:
			ran_domain = Sim_Event_Domain.Timer
			if !nrc_sim_run_next_timer(&campaign.ctx.sim) do return "timer event was not runnable"

		case .Run_Close:
			ran_domain = Sim_Event_Domain.Close
			if !nrc_sim_run_next_close_completion(&campaign.ctx.sim) do return "close event was not runnable"

		case .Run_Maintenance:
			ran_domain = Sim_Event_Domain.Driver_Action
			if !sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Driver_Action)) {
				return "maintenance event was not runnable"
			}

		case .Install_Replacement:
			if campaign.replacement != nil do return "replacement was already installed"
			if connection_get_by_handle(campaign.old_handle) != nil do return "replacement cannot install before prior I/O and close retire"
			campaign.ctx.conns[0] = nil
			campaign.replacement = simulation_test_install_client(&campaign.ctx.sim, 0, "global_events", "replacement", init_send_queue = true)
			if campaign.replacement == nil || campaign.replacement.sock != campaign.old_sock {
				return "replacement did not reuse the old socket"
			}
			campaign.ctx.conns[0] = campaign.replacement
		}

		if ran_partial_progress {
			campaign.partial_send_ran = true
			if campaign.send_record.callback_count != 0 do return "partial send invoked terminal observer"
			old_during_partial := global_event_old_connection(campaign)
			queued_during_partial := global_event_old_queued_io_count(campaign)
			watchdog_index := int(campaign.send_watchdog_slot) - 1
			if old_during_partial == nil ||
			   queued_during_partial == 0 ||
			   old_during_partial.pending_io != queued_during_partial ||
			   !old_during_partial.is_sending ||
			   old_during_partial.send_started_at != campaign.send_started_at ||
			   old_during_partial.send_watchdog_slot != campaign.send_watchdog_slot ||
			   watchdog_index < 0 ||
			   watchdog_index >= len(td.inflight_send_handles) ||
			   td.inflight_send_handles[watchdog_index] != campaign.old_handle {
				return "partial send released connection I/O ownership"
			}
		}

		old_after := global_event_old_connection(campaign)
		if old_after != nil && old_after.state >= .Closing {
			campaign.close_started = true
		}
		if campaign.old_counted && old_after == nil {
			connection_test_live_count -= 1
			campaign.old_counted = false
		}
		if campaign.replacement == nil && (old_after == nil || connection_get(campaign.old_sock) != old_after) {
			campaign.ctx.conns[0] = nil
		}

		old_closed_after := old_after != nil && old_after.state >= .Closing
		if old_state_before >= .Closing || old_closed_after {
			executed_send := false
			if domain, ok := ran_domain.?; ok do executed_send = domain == .Send
			expected_max := sends_before
			if executed_send do expected_max -= 1
			if nrc_sim_send_completion_count(&campaign.ctx.sim) > expected_max {
				return "event submitted a send after physical close began"
			}
		}
		return global_event_campaign_check(campaign)
	}

	global_event_campaign_finish_check :: proc(campaign: ^Global_Event_Campaign) -> string {
		if !campaign.close_started do return "campaign never started close"
		if global_event_partial_mode(campaign.mode) && !campaign.partial_send_ran do return "campaign never ran partial send progress"
		if campaign.replacement == nil do return "campaign never installed replacement"
		if global_event_old_connection(campaign) != nil do return "old connection survived drained campaign"
		if len(campaign.ctx.sim.world.events) != 0 {
			return "campaign left deterministic events queued"
		}
		expected_error_count := 0
		expected_sent := 8
		if campaign.mode == .Partial_Send_Error {
			expected_error_count = 1
			expected_sent = 3
		}
		if campaign.send_record.callback_count != 1 ||
		   campaign.send_record.nil_count != 0 ||
		   campaign.send_record.error_count != expected_error_count ||
		   campaign.send_record.total_sent != expected_sent ||
		   campaign.send_record.unexpected_target_count != 0 {
			return "initial delayed-send observer mismatch"
		}
		if connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before {
			return "campaign leaked a pooled frame lease"
		}
		if td.spool.invalid_release_count != campaign.invalid_releases_before {
			return "campaign attempted an invalid pooled frame release"
		}
		replacement_handles := [?]Connection_Handle{campaign.replacement.handle}
		if reason := sim_worker_transport_quiescence_reason(replacement_handles[:], campaign.quiescence_baseline); reason != "" {
			return fmt.tprintf("campaign did not reach transport quiescence: %s", reason)
		}
		return global_event_campaign_check(campaign)
	}

	global_event_run_fixed :: proc(mode: Global_Event_Close_Mode, actions: []Global_Event_Action) -> string {
		campaign: Global_Event_Campaign
		if !global_event_campaign_begin(&campaign, mode) {
			global_event_campaign_end(&campaign)
			return "campaign setup failed"
		}
		defer global_event_campaign_end(&campaign)
		for action in actions {
			if reason := global_event_campaign_run(&campaign, action); reason != "" do return reason
		}
		return global_event_campaign_finish_check(&campaign)
	}

	@(test)
	test_global_event_interleaving_mandatory_orderings :: proc(t: ^testing.T) {
		physical_receive_stale := [?]Global_Event_Action{.Start_Close, .Run_Receive, .Run_Send, .Run_Close, .Install_Replacement}
		testing.expect_value(t, global_event_run_fixed(.Physical, physical_receive_stale[:]), "")

		physical_send_stale := [?]Global_Event_Action{.Start_Close, .Run_Send, .Run_Receive, .Run_Close, .Install_Replacement}
		testing.expect_value(t, global_event_run_fixed(.Physical, physical_send_stale[:]), "")

		graceful_live_receive := [?]Global_Event_Action {
			.Run_Receive,
			.Run_Send,
			.Start_Close,
			.Run_Send,
			.Run_Send,
			.Run_Event,
			.Run_Timer,
			.Run_Close,
			.Install_Replacement,
		}
		testing.expect_value(t, global_event_run_fixed(.Graceful, graceful_live_receive[:]), "")

		graceful_stale_timer := [?]Global_Event_Action {
			.Start_Close,
			.Run_Receive,
			.Run_Send,
			.Run_Send,
			.Run_Event,
			.Start_Physical_Close,
			.Run_Close,
			.Install_Replacement,
			.Run_Timer,
		}
		testing.expect_value(t, global_event_run_fixed(.Graceful, graceful_stale_timer[:]), "")

		watchdog_closes_stalled_send := [?]Global_Event_Action{.Run_Maintenance, .Run_Receive, .Run_Send, .Run_Close, .Install_Replacement}
		testing.expect_value(t, global_event_run_fixed(.Watchdog, watchdog_closes_stalled_send[:]), "")

		watchdog_ignores_completed_send := [?]Global_Event_Action{.Run_Send, .Run_Maintenance, .Start_Close, .Run_Receive, .Run_Close, .Install_Replacement}
		testing.expect_value(t, global_event_run_fixed(.Watchdog, watchdog_ignores_completed_send[:]), "")

		partial_send_survives_close_reuse := [?]Global_Event_Action{.Run_Send, .Start_Close, .Run_Receive, .Run_Send, .Run_Close, .Install_Replacement}
		testing.expect_value(t, global_event_run_fixed(.Partial_Send, partial_send_survives_close_reuse[:]), "")
		testing.expect_value(t, global_event_run_fixed(.Partial_Send_Error, partial_send_survives_close_reuse[:]), "")
	}

	@(test)
	test_hegel_global_event_interleaving_campaign :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_global_event_interleaving_campaign, nil, {test_cases = 240})
		testing.expectf(t, err == nil, "global event interleaving campaign failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	prop_global_event_interleaving_campaign :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		mode_raw, mode_err := hgl.draw_i64(tc, 0, i64(len(Global_Event_Close_Mode) - 1))
		if mode_err == .Stop_Test do return hgl.abort()
		if mode_err != nil do return hgl.interesting("draw global event close mode")

		campaign: Global_Event_Campaign
		if !global_event_campaign_begin(&campaign, Global_Event_Close_Mode(mode_raw)) {
			global_event_campaign_end(&campaign)
			return hgl.interesting("initialize global event campaign")
		}
		defer global_event_campaign_end(&campaign)

		for step in 0 ..< 16 {
			actions: [4]Global_Event_Action
			action_count := global_event_campaign_generated_actions(&campaign, &actions)
			if action_count == 0 do break
			action_raw, action_err := hgl.draw_i64(tc, 0, i64(action_count - 1))
			if action_err == .Stop_Test do return hgl.abort()
			if action_err != nil do return hgl.interesting("draw next global event")
			action := actions[int(action_raw)]
			runnable_rank := 0
			if action == .Run_Event {
				runnable_count := sim_world_prepare_runnable(&campaign.ctx.sim.world)
				if runnable_count == 0 do return hgl.interesting("selected global event with no runnable event")
				rank_raw, rank_err := hgl.draw_i64(tc, 0, i64(runnable_count - 1))
				if rank_err == .Stop_Test do return hgl.abort()
				if rank_err != nil do return hgl.interesting("draw global runnable rank")
				runnable_rank = int(rank_raw)
				index := sim_world_runnable_rank_index(&campaign.ctx.sim.world, runnable_rank)
				if index < 0 do return hgl.interesting("resolve global runnable rank")
				event := campaign.ctx.sim.world.events[index]
				hgl.note(
					tc,
					fmt.tprintf("step=%d runnable_rank=%d event_id=%d domain=%v ready_at=%v", step, runnable_rank, event.id, event.domain, event.ready_at),
				)
			}
			if reason := global_event_campaign_run(&campaign, action, runnable_rank); reason != "" {
				hgl.note(tc, fmt.tprintf("step=%d mode=%v action=%v reason=%s", step, campaign.mode, action, reason))
				return hgl.interesting("global event invariant failed")
			}
		}

		if reason := global_event_campaign_finish_check(&campaign); reason != "" {
			hgl.note(tc, fmt.tprintf("mode=%v reason=%s", campaign.mode, reason))
			return hgl.interesting("global event final invariant failed")
		}
		return hgl.valid()
	}
}
