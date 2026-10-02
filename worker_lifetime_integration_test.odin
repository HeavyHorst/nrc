package main

import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"

import "byte_pool"
import hgl "hegel"
import nbio "nbio/poly"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: chan.try_send
	_ :: fmt.tprintf
	_ :: mem.mutex_allocator
	_ :: net.TCP_Socket
	_ :: runtime.Allocator_Error
	_ :: strings.clone
	_ :: sync.Wait_Group
	_ :: thread.Thread
	_ :: time.Duration
	_ :: byte_pool.alloc
	_ :: hgl.run
	_ :: nbio.iovec
	_ :: pr.User_Type
}

when NRC_SIMULATION {
	THREADED_WORKER_LIFETIME_WORKER_COUNT :: 4
	THREADED_WORKER_LIFETIME_CONNECTION_COUNT :: 16

	Threaded_Worker_Lifetime_Failure :: enum {
		None,
		Thread_Start_Failed,
		Result_Channel_Full,
		Initial_Invariant,
		Adopted_Count,
		Adopted_Connection_Missing,
		Adopted_Connection_Metadata,
		Server_Ready_Frame,
		Stale_Setup,
		Reuse_Enqueue,
		Reuse_Adoption,
		Stale_Completion_Target,
		Pool_Not_Drained,
		Batch_State_Not_Released,
		Final_Invariant,
	}

	Threaded_Worker_Lifetime_Result :: struct {
		worker_index:      int,
		ok:                bool,
		reason:            Threaded_Worker_Lifetime_Failure,
		expected_count:    int,
		adopted_count:     int,
		connection_count:  int,
		active_count:      int,
		callback_count:    int,
		nil_count:         int,
		new_target_count:  int,
		unexpected_target: int,
		pool_live:         uint,
		pool_used:         u64,
	}

	Threaded_Worker_Lifetime_Data :: struct {
		server:         ^NRC_Server,
		worker_index:   int,
		expected_count: int,
		plan:           Threaded_Worker_Lifetime_Worker_Plan,
		wg:             ^sync.Wait_Group,
		results:        chan.Chan(Threaded_Worker_Lifetime_Result),
	}

	Threaded_Worker_Lifetime_Stale_Action :: enum {
		Complete_Send,
		Enqueue_Batch,
	}

	Threaded_Worker_Lifetime_Error_Kind :: enum {
		None,
		Timeout,
		Connection_Closed,
		Not_Connected,
	}

	THREADED_WORKER_LIFETIME_MAX_ACTIONS :: 2

	Threaded_Worker_Lifetime_Worker_Plan :: struct {
		chosen_connection_ordinal: int,
		action_count:              int,
		actions:                   [THREADED_WORKER_LIFETIME_MAX_ACTIONS]Threaded_Worker_Lifetime_Stale_Action,
		send_error:                Threaded_Worker_Lifetime_Error_Kind,
		batch_error:               Threaded_Worker_Lifetime_Error_Kind,
	}

	Threaded_Worker_Lifetime_Case :: struct {
		plans: [THREADED_WORKER_LIFETIME_WORKER_COUNT]Threaded_Worker_Lifetime_Worker_Plan,
	}

	threaded_worker_lifetime_workspace :: proc(index: int) -> string {
		switch index % THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
		case 0:
			return "threaded_worker_alpha"
		case 1:
			return "threaded_worker_beta"
		case 2:
			return "threaded_worker_gamma"
		case 3:
			return "threaded_worker_delta"
		case 4:
			return "threaded_worker_epsilon"
		case 5:
			return "threaded_worker_zeta"
		case 6:
			return "threaded_worker_eta"
		case 7:
			return "threaded_worker_theta"
		case 8:
			return "threaded_worker_iota"
		case 9:
			return "threaded_worker_kappa"
		case 10:
			return "threaded_worker_lambda"
		case 11:
			return "threaded_worker_mu"
		case 12:
			return "threaded_worker_nu"
		case 13:
			return "threaded_worker_xi"
		case 14:
			return "threaded_worker_omicron"
		case:
			return "threaded_worker_pi"
		}
	}

	threaded_worker_lifetime_username :: proc(index: int) -> string {
		switch index % THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
		case 0:
			return "thread-user-00"
		case 1:
			return "thread-user-01"
		case 2:
			return "thread-user-02"
		case 3:
			return "thread-user-03"
		case 4:
			return "thread-user-04"
		case 5:
			return "thread-user-05"
		case 6:
			return "thread-user-06"
		case 7:
			return "thread-user-07"
		case 8:
			return "thread-user-08"
		case 9:
			return "thread-user-09"
		case 10:
			return "thread-user-10"
		case 11:
			return "thread-user-11"
		case 12:
			return "thread-user-12"
		case 13:
			return "thread-user-13"
		case 14:
			return "thread-user-14"
		case:
			return "thread-user-15"
		}
	}

	threaded_worker_lifetime_reuse_username :: proc(worker_index: int) -> string {
		switch worker_index {
		case 0:
			return "thread-reuse-00"
		case 1:
			return "thread-reuse-01"
		case 2:
			return "thread-reuse-02"
		case:
			return "thread-reuse-03"
		}
	}

	threaded_worker_lifetime_sock :: proc(index: int) -> net.TCP_Socket {
		return connection_test_fake_socket(200 + index)
	}

	threaded_worker_lifetime_active_count :: proc() -> int {
		count := 0
		for _ in td.active_sockets do count += 1
		return count
	}

	threaded_worker_lifetime_target :: proc(index: int) -> int {
		return http_upgrade_target_worker_index(threaded_worker_lifetime_workspace(index), THREADED_WORKER_LIFETIME_WORKER_COUNT)
	}

	threaded_worker_lifetime_first_for_worker :: proc(worker_index: int) -> int {
		for index in 0 ..< THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
			if threaded_worker_lifetime_target(index) == worker_index {
				return index
			}
		}
		return -1
	}

	threaded_worker_lifetime_nth_for_worker :: proc(worker_index: int, ordinal: int) -> int {
		selected_ordinal := ordinal
		if selected_ordinal < 0 {
			selected_ordinal = 0
		}
		seen := 0
		for index in 0 ..< THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
			if threaded_worker_lifetime_target(index) != worker_index {
				continue
			}
			if seen == selected_ordinal {
				return index
			}
			seen += 1
		}
		return threaded_worker_lifetime_first_for_worker(worker_index)
	}

	threaded_worker_lifetime_error :: proc(kind: Threaded_Worker_Lifetime_Error_Kind) -> net.Network_Error {
		switch kind {
		case .None:
			return nil
		case .Timeout:
			return net.TCP_Send_Error(.Timeout)
		case .Connection_Closed:
			return net.TCP_Send_Error(.Connection_Closed)
		case .Not_Connected:
			return net.TCP_Send_Error(.Not_Connected)
		}
		return nil
	}

	threaded_worker_lifetime_default_plan :: proc() -> Threaded_Worker_Lifetime_Worker_Plan {
		return Threaded_Worker_Lifetime_Worker_Plan {
			chosen_connection_ordinal = 0,
			action_count = 2,
			actions = {.Complete_Send, .Enqueue_Batch},
			send_error = .None,
			batch_error = .None,
		}
	}

	threaded_worker_lifetime_default_case :: proc() -> Threaded_Worker_Lifetime_Case {
		case_plan: Threaded_Worker_Lifetime_Case
		for worker_index in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			case_plan.plans[worker_index] = threaded_worker_lifetime_default_plan()
		}
		return case_plan
	}

	threaded_worker_lifetime_plan_from_permutation :: proc(
		ordinal: int,
		permutation: int,
		send_error: Threaded_Worker_Lifetime_Error_Kind,
		batch_error: Threaded_Worker_Lifetime_Error_Kind,
	) -> Threaded_Worker_Lifetime_Worker_Plan {
		plan := threaded_worker_lifetime_default_plan()
		plan.chosen_connection_ordinal = ordinal
		plan.send_error = send_error
		plan.batch_error = batch_error
		switch permutation % 2 {
		case 0:
			plan.actions = {.Complete_Send, .Enqueue_Batch}
		case:
			plan.actions = {.Enqueue_Batch, .Complete_Send}
		}
		return plan
	}

	threaded_worker_lifetime_fill_counts :: proc(result: ^Threaded_Worker_Lifetime_Result) {
		result.connection_count = td.connection_count
		result.active_count = threaded_worker_lifetime_active_count()
		result.callback_count = connection_completion_callback_count
		result.nil_count = connection_completion_nil_count
		result.new_target_count = connection_completion_new_conn_count
		result.unexpected_target = connection_completion_unexpected_target_count
		if td.spool != nil {
			result.pool_live = connection_lifetime_pool_live_alloc_count(td.spool)
			result.pool_used = td.spool.used
		}
	}

	threaded_worker_lifetime_fail :: proc(result: ^Threaded_Worker_Lifetime_Result, reason: Threaded_Worker_Lifetime_Failure) {
		result.ok = false
		result.reason = reason
		threaded_worker_lifetime_fill_counts(result)
	}

	threaded_worker_lifetime_cleanup_connections :: proc() {
		for index in 0 ..< THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
			if threaded_worker_lifetime_target(index) != td.thread_index {
				continue
			}
			if conn := connection_get(threaded_worker_lifetime_sock(index)); conn != nil {
				connection_test_uninstall(conn)
			}
		}
	}

	threaded_worker_lifetime_invariants_hold :: proc(expected_count: int) -> bool {
		return td.connection_count == expected_count && threaded_worker_lifetime_active_count() == expected_count
	}

	threaded_worker_lifetime_drain_pending_queue :: proc(queue: Pending_Connection_Queue) {
		for {
			pending, ok := pending_queue_try_recv(queue)
			if !ok {
				return
			}
			if pending.upgrade != nil do http_temp_connection_free(pending.upgrade)
		}
	}

	threaded_worker_lifetime_worker :: proc(data: Threaded_Worker_Lifetime_Data) {
		result := Threaded_Worker_Lifetime_Result {
			worker_index   = data.worker_index,
			ok             = true,
			reason         = .None,
			expected_count = data.expected_count,
		}
		defer sync.wait_group_done(data.wg)
		defer {
			if !chan.try_send(data.results, result) {
				fallback := result
				fallback.ok = false
				fallback.reason = .Result_Channel_Full
				_ = chan.try_send(data.results, fallback)
			}
		}

		worker_state_init_core(data.server, data.worker_index, data.expected_count)
		defer worker_state_destroy_core_for_test()
		sim: Sim_Runtime
		nrc_sim_runtime_init(&sim)
		defer nrc_sim_runtime_destroy(&sim)
		defer threaded_worker_lifetime_cleanup_connections()

		for index in 0 ..< THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
			if threaded_worker_lifetime_target(index) == data.worker_index {
				nrc_sim_register_client(&sim, threaded_worker_lifetime_sock(index))
			}
		}

		if !threaded_worker_lifetime_invariants_hold(0) {
			threaded_worker_lifetime_fail(&result, .Initial_Invariant)
			return
		}

		for {
			pending, ok := pending_queue_try_recv(td.my_pending_queue)
			if !ok do break
			worker_adopt_upgraded_connection(pending.upgrade)
		}
		nrc_sim_run_all_send_completions(&sim)
		result.adopted_count = td.connection_count
		if !threaded_worker_lifetime_invariants_hold(data.expected_count) {
			threaded_worker_lifetime_fail(&result, .Adopted_Count)
			return
		}

		for index in 0 ..< THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
			if threaded_worker_lifetime_target(index) != data.worker_index {
				continue
			}
			sock := threaded_worker_lifetime_sock(index)
			conn := connection_get(sock)
			if conn == nil {
				threaded_worker_lifetime_fail(&result, .Adopted_Connection_Missing)
				return
			}
			if conn.thread_index != data.worker_index ||
			   conn.sock != sock ||
			   conn.workspace_id != threaded_worker_lifetime_workspace(index) ||
			   conn.verified_username != threaded_worker_lifetime_username(index) ||
			   !conn.authenticated ||
			   conn.user_type != .User {
				threaded_worker_lifetime_fail(&result, .Adopted_Connection_Metadata)
				return
			}
			if nrc_sim_client_frame_count(&sim, sock) != 1 {
				threaded_worker_lifetime_fail(&result, .Server_Ready_Frame)
				return
			}
		}

		first_index := threaded_worker_lifetime_nth_for_worker(data.worker_index, data.plan.chosen_connection_ordinal % data.expected_count)
		if first_index < 0 {
			result.ok = true
			threaded_worker_lifetime_fill_counts(&result)
			return
		}

		sock := threaded_worker_lifetime_sock(first_index)
		old_conn := connection_get(sock)
		if old_conn == nil {
			threaded_worker_lifetime_fail(&result, .Stale_Setup)
			return
		}
		old_handle := old_conn.handle
		batch_releases_before := td.batch_state_pool.pooled_releases
		send_buf: []byte
		batch_state: ^Batch_Send_State
		send_owned := false
		batch_owned := false
		batch_enqueued := false
		batch_buf_count := 0
		defer {
			if send_owned {
				byte_pool.release(td.spool, send_buf)
			}
			if batch_owned {
				for release_index in 0 ..< batch_buf_count {
					frame_lease_dispose(&batch_state.items[release_index].lease)
				}
				free_batch_state(batch_state)
			}
		}

		send_err: runtime.Allocator_Error
		send_buf, send_err = byte_pool.alloc(td.spool, 32)
		if send_err != .None {
			threaded_worker_lifetime_fail(&result, .Stale_Setup)
			return
		}
		send_owned = true

		batch_state = alloc_batch_state(2)
		if batch_state == nil {
			threaded_worker_lifetime_fail(&result, .Stale_Setup)
			return
		}
		batch_owned = true

		send_item := Send_Item {
			lease = Frame_Lease(Pooled_Frame_Lease{data = send_buf, pool = td.spool}),
			handle = old_handle,
			observer = Send_Completion_Observer{callback = connection_lifetime_tracking_ack_sent},
		}

		batch_state.count = 2
		batch_state.items = batch_state.items[:2]
		batch_state.iovec = batch_state.iovec[:2]
		for batch_index in 0 ..< 2 {
			buf, buf_err := byte_pool.alloc(td.spool, uint(40 + batch_index))
			if buf_err != .None {
				threaded_worker_lifetime_fail(&result, .Stale_Setup)
				return
			}
			batch_state.items[batch_index] = Batch_Item {
				observer = Send_Completion_Observer{callback = connection_lifetime_tracking_ack_sent},
				handle = old_handle,
				lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			}
			batch_state.iovec[batch_index] = nbio.iovec {
				iov_base = raw_data(buf),
				iov_len  = uint(len(buf)),
			}
			batch_buf_count += 1
		}

		connection_test_uninstall(old_conn)
		if !threaded_worker_lifetime_invariants_hold(data.expected_count - 1) {
			threaded_worker_lifetime_fail(&result, .Final_Invariant)
			return
		}

		reuse_upgrade := new(HTTP_Upgrade_Connection)
		reuse_upgrade.sock = sock
		reuse_upgrade.server = td.server
		reuse_upgrade.workspace_id = strings.clone(threaded_worker_lifetime_workspace(first_index))
		reuse_upgrade.verified_username = strings.clone(threaded_worker_lifetime_reuse_username(data.worker_index))
		reuse_upgrade.user_type = .User
		reuse_upgrade.authenticated = true
		nrc_sim_register_client(&sim, sock)
		worker_adopt_upgraded_connection(reuse_upgrade)
		nrc_sim_run_all_send_completions(&sim)

		new_conn := connection_get(sock)
		if new_conn == nil || new_conn.handle == old_handle || new_conn.verified_username != threaded_worker_lifetime_reuse_username(data.worker_index) {
			threaded_worker_lifetime_fail(&result, .Reuse_Adoption)
			return
		}
		// The simulated transport observer is generation-aware: the replacement
		// sees its own ready frame, not the prior generation's captured frame.
		if nrc_sim_client_frame_count(&sim, sock) != 1 {
			threaded_worker_lifetime_fail(&result, .Server_Ready_Frame)
			return
		}
		if !threaded_worker_lifetime_invariants_hold(data.expected_count) {
			threaded_worker_lifetime_fail(&result, .Final_Invariant)
			return
		}

		stale_releases_before := td.spool.release_count
		stale_live_before := connection_lifetime_pool_live_alloc_count(td.spool)
		connection_completion_test_reset()
		connection_completion_expected_handle = old_handle
		send_completed := false
		for action_index in 0 ..< data.plan.action_count {
			if action_index < 0 || action_index >= THREADED_WORKER_LIFETIME_MAX_ACTIONS {
				break
			}
			switch data.plan.actions[action_index] {
			case .Complete_Send:
				if !send_completed {
					send_err := threaded_worker_lifetime_error(data.plan.send_error)
					sent := len(frame_lease_data(send_item.lease))
					if send_err != nil do sent = 0
					on_queued_send_complete(sock, send_item, sent, send_err)
					send_owned = false
					send_completed = true
				}

			case .Enqueue_Batch:
				if !batch_enqueued {
					on_batch_send_complete(sock, batch_state, 0, threaded_worker_lifetime_error(data.plan.batch_error))
					batch_owned = false
					batch_enqueued = true
				}

			}
		}
		if !send_completed {
			send_err := threaded_worker_lifetime_error(data.plan.send_error)
			sent := len(frame_lease_data(send_item.lease))
			if send_err != nil do sent = 0
			on_queued_send_complete(sock, send_item, sent, send_err)
			send_owned = false
			send_completed = true
		}
		if !batch_enqueued {
			on_batch_send_complete(sock, batch_state, 0, threaded_worker_lifetime_error(data.plan.batch_error))
			batch_owned = false
			batch_enqueued = true
		}
		connection_completion_expected_handle = {}

		if connection_completion_callback_count != 3 ||
		   connection_completion_nil_count != 3 ||
		   connection_completion_new_conn_count != 0 ||
		   connection_completion_unexpected_target_count != 0 ||
		   connection_get(sock) != new_conn {
			threaded_worker_lifetime_fail(&result, .Stale_Completion_Target)
			return
		}
		if stale_live_before < 3 ||
		   td.spool.release_count != stale_releases_before + 3 ||
		   connection_lifetime_pool_live_alloc_count(td.spool) != stale_live_before - 3 {
			threaded_worker_lifetime_fail(&result, .Pool_Not_Drained)
			return
		}
		if td.batch_state_pool.pooled_releases != batch_releases_before + 1 {
			threaded_worker_lifetime_fail(&result, .Batch_State_Not_Released)
			return
		}
		if !threaded_worker_lifetime_invariants_hold(data.expected_count) {
			threaded_worker_lifetime_fail(&result, .Final_Invariant)
			return
		}

		result.ok = true
		result.reason = .None
		threaded_worker_lifetime_fill_counts(&result)
	}

	threaded_worker_lifetime_worker_entry :: proc(data_raw: rawptr) {
		threaded_worker_lifetime_worker((^Threaded_Worker_Lifetime_Data)(data_raw)^)
	}
	threaded_worker_lifetime_run_case :: proc(
		case_plan: Threaded_Worker_Lifetime_Case,
		results: ^[THREADED_WORKER_LIFETIME_WORKER_COUNT]Threaded_Worker_Lifetime_Result,
	) -> bool {
		// Odin's test runner uses a per-test allocator that is not safe for the
		// parent and these worker threads to access concurrently. Serialize the
		// shared allocator for the complete lifetime of every worker allocation.
		mutex_allocator: mem.Mutex_Allocator
		mem.mutex_allocator_init(&mutex_allocator, context.allocator)
		context.allocator = mem.mutex_allocator(&mutex_allocator)

		case_started_at := time.now()
		queue_setup_elapsed, handoff_elapsed, thread_start_elapsed, worker_wait_elapsed, thread_destroy_elapsed, result_elapsed: time.Duration
		defer {
			total_elapsed := time.since(case_started_at)
			if total_elapsed >= 250 * time.Millisecond {
				measured_elapsed :=
					queue_setup_elapsed + handoff_elapsed + thread_start_elapsed + worker_wait_elapsed + thread_destroy_elapsed + result_elapsed
				fmt.eprintf(
					"[hegel worker lifetime phase] total=%.3fs queue_setup=%.3fs handoff=%.3fs thread_start=%.3fs worker_wait=%.3fs thread_destroy=%.3fs results=%.3fs cleanup_other=%.3fs\n",
					time.duration_seconds(total_elapsed),
					time.duration_seconds(queue_setup_elapsed),
					time.duration_seconds(handoff_elapsed),
					time.duration_seconds(thread_start_elapsed),
					time.duration_seconds(worker_wait_elapsed),
					time.duration_seconds(thread_destroy_elapsed),
					time.duration_seconds(result_elapsed),
					time.duration_seconds(total_elapsed - measured_elapsed),
				)
			}
		}

		queue_setup_started_at := time.now()
		results^ = {}
		queues: [THREADED_WORKER_LIFETIME_WORKER_COUNT]Pending_Connection_Queue
		for worker_index in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			queue, queue_err := pending_queue_create(THREADED_WORKER_LIFETIME_CONNECTION_COUNT)
			if queue_err != .None {
				for cleanup_index in 0 ..< worker_index {
					pending_queue_destroy(queues[cleanup_index])
				}
				return false
			}
			queues[worker_index] = queue
		}
		defer for queue in queues {
			threaded_worker_lifetime_drain_pending_queue(queue)
			pending_queue_destroy(queue)
		}

		pending_queues := make([]Pending_Connection_Queue, THREADED_WORKER_LIFETIME_WORKER_COUNT)
		defer delete(pending_queues)
		for worker_index in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			pending_queues[worker_index] = queues[worker_index]
		}

		result_ch, result_ch_err := chan.create_buffered(chan.Chan(Threaded_Worker_Lifetime_Result), THREADED_WORKER_LIFETIME_WORKER_COUNT, context.allocator)
		if result_ch_err != .None {
			return false
		}
		defer chan.destroy(result_ch)

		server := NRC_Server {
			main_thread         = -1,
			pending_connections = pending_queues,
		}

		expected_counts: [THREADED_WORKER_LIFETIME_WORKER_COUNT]int
		for index in 0 ..< THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
			workspace_id := threaded_worker_lifetime_workspace(index)
			target_worker := http_upgrade_target_worker_index(workspace_id, THREADED_WORKER_LIFETIME_WORKER_COUNT)
			expected_counts[target_worker] += 1
		}
		for worker_index in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			if expected_counts[worker_index] <= 0 {
				return false
			}
		}
		queue_setup_elapsed = time.since(queue_setup_started_at)

		handoff_started_at := time.now()
		for index in 0 ..< THREADED_WORKER_LIFETIME_CONNECTION_COUNT {
			workspace_id := threaded_worker_lifetime_workspace(index)
			target_worker := http_upgrade_target_worker_index(workspace_id, THREADED_WORKER_LIFETIME_WORKER_COUNT)
			conn := new(HTTP_Upgrade_Connection)
			conn.server = &server
			conn.sock = threaded_worker_lifetime_sock(index)
			conn.state = .New
			conn.workspace_id = strings.clone(workspace_id)
			conn.verified_username = strings.clone(threaded_worker_lifetime_username(index))
			conn.user_type = .User
			conn.authenticated = true
			conn.target_worker_index = target_worker
			if !http_upgrade_commit_handoff(conn, queues[target_worker]) {
				http_temp_connection_free(conn)
				return false
			}
		}
		handoff_elapsed = time.since(handoff_started_at)

		wg: sync.Wait_Group
		threads: [THREADED_WORKER_LIFETIME_WORKER_COUNT]^thread.Thread
		worker_data: [THREADED_WORKER_LIFETIME_WORKER_COUNT]Threaded_Worker_Lifetime_Data
		thread_start_started_at := time.now()
		for worker_index in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			worker_data[worker_index] = Threaded_Worker_Lifetime_Data {
				server         = &server,
				worker_index   = worker_index,
				expected_count = expected_counts[worker_index],
				plan           = case_plan.plans[worker_index],
				wg             = &wg,
				results        = result_ch,
			}
			sync.wait_group_add(&wg, 1)
			threads[worker_index] = thread.create_and_start_with_data(&worker_data[worker_index], threaded_worker_lifetime_worker_entry, context)
			if threads[worker_index] == nil {
				_ = chan.try_send(
					result_ch,
					Threaded_Worker_Lifetime_Result {
						worker_index = worker_index,
						ok = false,
						reason = .Thread_Start_Failed,
						expected_count = expected_counts[worker_index],
					},
				)
				sync.wait_group_done(&wg)
			}
		}
		thread_start_elapsed = time.since(thread_start_started_at)

		worker_wait_started_at := time.now()
		sync.wait(&wg)
		worker_wait_elapsed = time.since(worker_wait_started_at)

		thread_destroy_started_at := time.now()
		for worker_thread in threads {
			if worker_thread != nil do thread.destroy(worker_thread)
		}
		thread_destroy_elapsed = time.since(thread_destroy_started_at)

		result_started_at := time.now()
		seen: [THREADED_WORKER_LIFETIME_WORKER_COUNT]bool
		ok := true
		for _ in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			result, recv_ok := chan.try_recv(result_ch)
			if !recv_ok {
				ok = false
				continue
			}
			if result.worker_index < 0 || result.worker_index >= THREADED_WORKER_LIFETIME_WORKER_COUNT || seen[result.worker_index] {
				ok = false
				continue
			}
			seen[result.worker_index] = true
			results[result.worker_index] = result
			if !result.ok {
				ok = false
			}
		}
		for worker_index in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			if !seen[worker_index] {
				ok = false
			}
		}
		result_elapsed = time.since(result_started_at)
		return ok
	}

	threaded_worker_lifetime_expect_results :: proc(
		t: ^testing.T,
		ok: bool,
		results: ^[THREADED_WORKER_LIFETIME_WORKER_COUNT]Threaded_Worker_Lifetime_Result,
	) {
		testing.expect(t, ok, "threaded worker lifetime runner should succeed")
		for result in results {
			testing.expectf(
				t,
				result.ok,
				"threaded worker %d lifetime invariant failed: reason=%v expected=%d adopted=%d connections=%d active=%d callbacks=%d nil=%d new=%d unexpected=%d pool_live=%d pool_used=%d",
				result.worker_index,
				result.reason,
				result.expected_count,
				result.adopted_count,
				result.connection_count,
				result.active_count,
				result.callback_count,
				result.nil_count,
				result.new_target_count,
				result.unexpected_target,
				result.pool_live,
				result.pool_used,
			)
		}
	}
}

@(test)
test_storage_error_shutdown_marks_process_failure :: proc(t: ^testing.T) {
	server: NRC_Server
	server_shutdown_after_storage_error(&server)
	testing.expect(t, sync.atomic_load(&server.closing), "storage failure should request shutdown")
	testing.expect(t, sync.atomic_load(&server.fatal_storage_error), "storage failure should produce a failed process exit")
}

@(test)
test_simulation_threaded_worker_handoff_lifetime_invariants :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		results: [THREADED_WORKER_LIFETIME_WORKER_COUNT]Threaded_Worker_Lifetime_Result
		ok := threaded_worker_lifetime_run_case(threaded_worker_lifetime_default_case(), &results)
		threaded_worker_lifetime_expect_results(t, ok, &results)
	}
}

@(test)
test_hegel_generated_threaded_worker_handoff_lifetime_orderings :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_generated_threaded_worker_handoff_lifetime_orderings, nil, {test_cases = 40})
		testing.expectf(t, err == nil, "hegel threaded worker lifetime property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

when NRC_SIMULATION {
	prop_generated_threaded_worker_handoff_lifetime_orderings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		case_plan := threaded_worker_lifetime_default_case()
		for worker_index in 0 ..< THREADED_WORKER_LIFETIME_WORKER_COUNT {
			ordinal_raw, ordinal_err := hgl.draw_i64(tc, 0, 7)
			if ordinal_err == .Stop_Test do return hgl.abort()
			if ordinal_err != nil do return hgl.interesting("draw threaded worker chosen connection ordinal")

			permutation_raw, permutation_err := hgl.draw_i64(tc, 0, 5)
			if permutation_err == .Stop_Test do return hgl.abort()
			if permutation_err != nil do return hgl.interesting("draw threaded worker stale action permutation")

			send_error_raw, send_error_err := hgl.draw_i64(tc, 0, i64(len(Threaded_Worker_Lifetime_Error_Kind) - 1))
			if send_error_err == .Stop_Test do return hgl.abort()
			if send_error_err != nil do return hgl.interesting("draw threaded worker stale send error")

			batch_error_raw, batch_error_err := hgl.draw_i64(tc, 0, i64(len(Threaded_Worker_Lifetime_Error_Kind) - 1))
			if batch_error_err == .Stop_Test do return hgl.abort()
			if batch_error_err != nil do return hgl.interesting("draw threaded worker stale batch error")

			case_plan.plans[worker_index] = threaded_worker_lifetime_plan_from_permutation(
				int(ordinal_raw),
				int(permutation_raw),
				Threaded_Worker_Lifetime_Error_Kind(send_error_raw),
				Threaded_Worker_Lifetime_Error_Kind(batch_error_raw),
			)
		}

		results: [THREADED_WORKER_LIFETIME_WORKER_COUNT]Threaded_Worker_Lifetime_Result
		if !threaded_worker_lifetime_run_case(case_plan, &results) {
			for result in results {
				if !result.ok {
					hgl.note(
						tc,
						fmt.tprintf(
							"threaded worker=%d reason=%v expected=%d adopted=%d connections=%d active=%d callbacks=%d nil=%d new=%d unexpected=%d pool_live=%d pool_used=%d plan=%v",
							result.worker_index,
							result.reason,
							result.expected_count,
							result.adopted_count,
							result.connection_count,
							result.active_count,
							result.callback_count,
							result.nil_count,
							result.new_target_count,
							result.unexpected_target,
							result.pool_live,
							result.pool_used,
							case_plan.plans[result.worker_index],
						),
					)
				}
			}
			return hgl.interesting("generated threaded worker lifetime ordering failed")
		}

		return {}
	}
}
