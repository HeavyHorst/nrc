package main

import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:sys/linux"
import "core:testing"

import hgl "hegel"
import pr "protocol"
import "storage_io"

when !NRC_SIMULATION {
	_ :: endian.put_u64
	_ :: fmt.eprintf
	_ :: log.nil_logger
	_ :: linux.Errno
	_ :: testing.T
	_ :: hgl.run
	_ :: pr.Opcode
	_ :: storage_io.Context
}

when NRC_SIMULATION {
	transaction_simulation_prepare_storage :: proc(ctx: ^Sim_Test_Context, shard_dir: string) -> bool {
		storage := sim_world_storage_context(&ctx.sim.world)
		if storage_io.make_directory(storage, shard_dir) != nil do return false
		if storage_io.sync_directory(storage, "/") != nil do return false
		active_path := shard_generation_wal_path(shard_dir, 0)
		defer delete(active_path)
		active, open_err := storage_io.open(storage, active_path, {.Write, .Create, .Excl})
		if open_err != nil do return false
		sync_err := storage_io.sync(active)
		close_err := storage_io.close(active)
		return sync_err == nil && close_err == nil
	}

	transaction_simulation_init_writer :: proc(ctx: ^Sim_Test_Context, shard_dir: string, shard: int) -> bool {
		registry := &td.shard_writers
		if registry.mode != .Inactive || len(registry.writers) != 0 do return false
		for &writer_index in registry.writer_index do writer_index = -1
		registry.worker = 0
		registry.worker_count = 1
		registry.writers = make([dynamic]Shard_Transaction_Writer, 1)
		if !init_managed_shard_transaction_writer(&registry.writers[0], sim_world_storage_context(&ctx.sim.world), shard_dir, shard, 0, 1) {
			shutdown_shard_writer_registry(registry)
			return false
		}
		registry.writer_index[shard] = 0
		registry.mode = .Active
		return true
	}

	transaction_simulation_asset_create_body :: proc(conv_id: pr.ConversationID) -> [41]byte {
		body: [41]byte
		endian.put_u64(body[:], .Big, u64(conv_id))
		endian.put_u16(body[8:], .Big, u16(pr.AssetType.Note))
		endian.put_u16(body[10:], .Big, u16(pr.ParentType.Task))
		transaction_test_ref(body[12:], .CreatedBy, .Task, 0)
		body[24] = u8(pr.PayloadEncoding.Plain)
		endian.put_u32(body[25:], .Big, 4)
		endian.put_u16(body[29:], .Big, 4)
		copy(body[31:], transmute([]byte)string("note"))
		endian.put_u16(body[35:], .Big, 4)
		copy(body[37:], transmute([]byte)string("body"))
		return body
	}

	transaction_simulation_edge_create_body :: proc(conv_id: pr.ConversationID) -> [34]byte {
		body: [34]byte
		endian.put_u64(body[:], .Big, u64(conv_id))
		transaction_test_ref(body[8:], .CreatedBy, .Task, 0)
		transaction_test_ref(body[20:], .CreatedBy, .Asset, 1)
		endian.put_u16(body[32:], .Big, u16(pr.RelationType.References))
		return body
	}

	transaction_simulation_enqueue_request :: proc(
		ctx: ^Sim_Test_Context,
		conn: ^NRC_Connection,
		correlation_id: u32,
		operations: []pr.TransactionOperation,
	) -> bool {
		request: [512]byte
		request_len := pr.serializeApplyTransactionRequest(correlation_id, operations, request[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request[:request_len], .opBinary, true)
		defer delete(frame)
		first := min(5, len(frame))
		second := min(29, len(frame))
		return(
			nrc_sim_enqueue_receive(&ctx.sim, conn, frame[:first]) &&
			nrc_sim_enqueue_receive(&ctx.sim, conn, frame[first:second]) &&
			nrc_sim_enqueue_receive(&ctx.sim, conn, frame[second:]) \
		)
	}

	transaction_simulation_result_matches :: proc(
		sim: ^Sim_Runtime,
		conn: ^NRC_Connection,
		status: pr.TransactionResultStatus,
		correlation_id: u32,
		failed_operation: u16,
		expected_results: []pr.TransactionOperationResult,
	) -> bool {
		if nrc_sim_client_frame_count(sim, conn.sock) != 1 do return false
		frame := nrc_sim_client_frame(sim, conn.sock, 0)
		payload, ok := nrc_sim_frame_protocol_payload(frame)
		if !ok || len(payload) != 12 + len(expected_results) * 10 || pr.get_opcode(payload) != .S_TransactionResult do return false
		correlation, _ := endian.get_u32(payload[4:], .Big)
		failed, _ := endian.get_u16(payload[8:], .Big)
		count, _ := endian.get_u16(payload[10:], .Big)
		if payload[2] != pr.TRANSACTION_WIRE_VERSION ||
		   payload[3] != u8(status) ||
		   correlation != correlation_id ||
		   failed != failed_operation ||
		   count != u16(len(expected_results)) {
			return false
		}
		for expected, index in expected_results {
			offset := 12 + index * 10
			id, _ := endian.get_u64(payload[offset + 2:], .Big)
			if payload[offset] != u8(expected.op_type) || payload[offset + 1] != 0 || id != expected.entity_id do return false
		}
		return true
	}

	@(test)
	test_simulation_atomic_transaction_transport_durability_rejection_and_replay :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 151)
		server: NRC_Server
		td.server = &server
		registry_started := false
		defer {
			nrc_sim_run_all_receives(&ctx.sim)
			nrc_sim_run_all_send_completions(&ctx.sim)
			for conn, client_id in ctx.conns {
				if conn == nil do continue
				_ = simulation_test_disconnect_client(&ctx, client_id)
			}
			if registry_started do shutdown_shard_writer_registry(&td.shard_writers)
			td.server = nil
			shard_replay_state_destroy()
			simulation_test_end(&ctx)
		}

		workspace := "transaction-simulation"
		workspace_bytes := transmute([]byte)workspace
		shard := int(shard_for_workspace(workspace_bytes))
		shard_dir := "/shard"
		testing.expect(t, transaction_simulation_prepare_storage(&ctx, shard_dir), "prepare virtual transaction storage")
		if !transaction_simulation_init_writer(&ctx, shard_dir, shard) {
			testing.expect(t, false, "initialize simulated transaction writer")
			return
		}
		registry_started = true
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0

		requester := simulation_test_install_client(&ctx.sim, 1, workspace, "requester", init_send_queue = true)
		peer := simulation_test_install_client(&ctx.sim, 2, workspace, "peer", init_send_queue = true)
		ctx.conns[1] = requester
		ctx.conns[2] = peer
		testing.expect(t, requester != nil && peer != nil, "install transaction simulation clients")
		if requester == nil || peer == nil do return
		subscribe_to_conversation(requester, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(peer, pr.WORKSPACE_DATA_ID)
		nrc_sim_clear_inboxes(&ctx.sim)

		task_body := transaction_test_task_create_body(pr.WORKSPACE_DATA_ID, .Existing, 0, 't')
		asset_body := transaction_simulation_asset_create_body(pr.WORKSPACE_DATA_ID)
		edge_body := transaction_simulation_edge_create_body(pr.WORKSPACE_DATA_ID)
		operations := [3]pr.TransactionOperation {
			{op_type = .TaskCreate, body = task_body[:]},
			{op_type = .AssetCreate, body = asset_body[:]},
			{op_type = .EdgeCreate, body = edge_body[:]},
		}
		testing.expect(t, transaction_simulation_enqueue_request(&ctx, requester, 0xA701, operations[:]), "enqueue segmented atomic transaction")
		testing.expect_value(t, nrc_sim_receive_event_count(&ctx.sim), 3)
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "run transaction frame prefix")
		conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
		testing.expect(
			t,
			td.shard_writers.writers[0].wal.record_count == 0 &&
			td.task_seq == 0 &&
			td.asset_seq == 0 &&
			td.edge_seq == 0 &&
			conv != nil &&
			len(conv.tasks) == 0 &&
			len(conv.assets) == 0 &&
			len(conv.edges) == 0 &&
			nrc_sim_send_completion_count(&ctx.sim) == 0,
			"partial transaction must not mutate state or enqueue output",
		)
		if conv == nil do return
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "run transaction frame middle")
		testing.expect(
			t,
			td.shard_writers.writers[0].wal.record_count == 0 &&
			td.task_seq == 0 &&
			td.asset_seq == 0 &&
			td.edge_seq == 0 &&
			len(conv.tasks) == 0 &&
			len(conv.assets) == 0 &&
			len(conv.edges) == 0 &&
			nrc_sim_send_completion_count(&ctx.sim) == 0,
			"incomplete transaction must remain inert",
		)
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "run complete atomic transaction")

		writer := &td.shard_writers.writers[0]
		conv = get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
		task := conv == nil ? nil : conv.tasks[1]
		asset := conv == nil ? nil : conv.assets[1]
		edge := conv == nil ? nil : conv.edges[1]
		testing.expect(
			t,
			writer.wal.record_count == 1 &&
			writer.wal.durable_record_count == 0 &&
			writer.floors == (Shard_High_Water_Requirements{task = 1, asset = 1, edge = 1}),
			"heterogeneous transaction should append exactly one pending WAL record",
		)
		testing.expect(t, task != nil && string(task.title) == "t" && task.blocked_by == 0, "transaction task should publish")
		testing.expect(
			t,
			asset != nil && asset.parent_type == .Task && asset.parent_id == 1 && string(asset.payload) == "body",
			"created-by parent should publish",
		)
		testing.expect(
			t,
			edge != nil && edge.source_type == .Task && edge.source_id == 1 && edge.target_type == .Asset && edge.target_id == 1,
			"created-by edge endpoints should publish",
		)

		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, requester.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 0)
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		testing.expect(t, sync_ok && did_work && nrc_sim_fsync_completion_count(&ctx.sim) == 1, "transaction WAL fsync should enter simulation queue")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, requester.sock), 0)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim), "complete simulated transaction fsync")
		testing.expect_value(t, writer.wal.durable_record_count, u64(1))
		nrc_sim_run_all_send_completions(&ctx.sim)
		expected_results := [3]pr.TransactionOperationResult {
			{op_type = .TaskCreate, entity_id = 1},
			{op_type = .AssetCreate, entity_id = 1},
			{op_type = .EdgeCreate, entity_id = 1},
		}
		testing.expect(
			t,
			transaction_simulation_result_matches(&ctx.sim, requester, .Committed, 0xA701, max(u16), expected_results[:]),
			"requester should receive committed transaction result",
		)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_TaskCreated), 1)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_AssetCreated), 1)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, peer.sock, .S_EdgeCreated), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		stale_delete := transaction_test_delete_body(pr.WORKSPACE_DATA_ID, .Task, 1, task.updated_at - 1)
		rejected_task := transaction_test_task_create_body(pr.WORKSPACE_DATA_ID, .Existing, 0, 'x')
		rejected := [2]pr.TransactionOperation{{op_type = .TaskCreate, body = rejected_task[:]}, {op_type = .TaskDelete, body = stale_delete[:]}}
		testing.expect(t, transaction_simulation_enqueue_request(&ctx, requester, 0xA702, rejected[:]), "enqueue stale atomic transaction")
		nrc_sim_run_all_receives(&ctx.sim)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, transaction_simulation_result_matches(&ctx.sim, requester, .Rejected, 0xA702, 1, nil), "stale transaction should report rejection")
		testing.expect(
			t,
			writer.wal.record_count == 1 &&
			td.task_seq == 1 &&
			td.asset_seq == 1 &&
			td.edge_seq == 1 &&
			len(conv.tasks) == 1 &&
			len(conv.assets) == 1 &&
			len(conv.edges) == 1 &&
			conv.tasks[1] == task &&
			conv.assets[1] == asset &&
			conv.edges[1] == edge,
			"rejected transaction must not append or publish any domain state",
		)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 0)

		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		testing.expect(t, sync_ok && !did_work, "rejection must not create a new commit batch")
		testing.expect_value(t, writer.wal.durable_record_count, u64(1))

		testing.expect(t, shutdown_shard_writer_registry(&td.shard_writers), "shutdown durable transaction writer")
		registry_started = false
		testing.expect(t, simulation_test_disconnect_client(&ctx, 1), "disconnect requester before workspace replay")
		testing.expect(t, simulation_test_disconnect_client(&ctx, 2), "disconnect peer before workspace replay")
		requester = nil
		peer = nil
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
		shard_replay_state_destroy()
		testing.expect(t, transaction_simulation_init_writer(&ctx, shard_dir, shard), "reopen simulated transaction writer")
		registry_started = true
		writer = &td.shard_writers.writers[0]
		shard_replay_state_init()
		floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
		testing.expect(
			t,
			replay_ok && floors == (Shard_High_Water_Requirements{task = 1, asset = 1, edge = 1}),
			"replay heterogeneous transaction as one durable record",
		)
		conv = get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
		task = conv == nil ? nil : conv.tasks[1]
		asset = conv == nil ? nil : conv.assets[1]
		edge = conv == nil ? nil : conv.edges[1]
		testing.expect(t, task != nil && asset != nil && edge != nil, "all transaction domains should survive replay")
		if asset != nil do testing.expect(t, asset.parent_type == .Task && asset.parent_id == 1, "replay should preserve symbolic parent resolution")
		if edge != nil do testing.expect(t, edge.source_id == 1 && edge.target_id == 1, "replay should preserve symbolic edge resolution")
	}

	// This campaign deliberately keeps its oracle independent of the live maps: the
	// ledger is advanced only by completed fsync snapshots.  In particular, a
	// transaction visible in memory before a failed fsync is not added to it.
	Transaction_Crash_Outcome :: enum {
		Pending,
		Success,
		Error,
	}

	transaction_compaction_published :: proc(writer: ^Shard_Transaction_Writer, previous: Shard_Compaction_Manifest) -> bool {
		return(
			writer.manifest.manifest_generation == previous.manifest_generation + 1 &&
			writer.manifest.checkpoint_generation > previous.checkpoint_generation &&
			writer.catalog_segments == 1 &&
			writer.raw_catalog_segments == 1 &&
			writer.compaction == .Idle &&
			!writer.poisoned &&
			writer.wal.enabled &&
			!td.server.closing &&
			!td.server.fatal_storage_error \
		)
	}

	transaction_generated_failure_history :: proc(compact: bool, outcome: Transaction_Crash_Outcome, disconnect: bool, schedule: u8) -> string {
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "client-transaction-history", 1, 7, thread_index = 0, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic

		// Ordinary CreateTask goes through the same production WebSocket parser and
		// establishes ledger task 1.
		for nrc_sim_receive_event_count(&campaign.ctx.sim) > 0 {
			if !nrc_sim_run_next_receive(&campaign.ctx.sim) {
				return "ordinary receive schedule stalled"
			}
		}
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "ordinary mutation did not append"
		if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 {
			return "ordinary mutation emitted output before durability"
		}
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) do return "ordinary mutation fsync failed"
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		nrc_sim_clear_inboxes(&campaign.ctx.sim)

		if compact {
			if !rotate_shard_writer_for_compaction(writer) ||
			   !rotate_shard_writer_for_compaction(writer) ||
			   !enqueue_shard_compaction_job_event(&campaign.ctx.sim.world, writer) {
				return "transaction history compaction did not start"
			}
		}
		before_compaction := writer.manifest

		// A rejected mixed transaction must affect neither the ledger nor any WAL
		// snapshot.  Its first operation would otherwise allocate task 2.
		foundation := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)
		if foundation == nil do return "ordinary ledger task missing"
		rejected_create := transaction_test_task_create_body(pr.WORKSPACE_DATA_ID, .Existing, 0, 'r')
		stale_delete := transaction_test_delete_body(pr.WORKSPACE_DATA_ID, .Task, 1, foundation.updated_at - 1)
		rejected := [2]pr.TransactionOperation{{op_type = .TaskCreate, body = rejected_create[:]}, {op_type = .TaskDelete, body = stale_delete[:]}}
		baseline_records := writer.wal.record_count
		baseline_durable := writer.wal.durable_record_count
		if !transaction_simulation_enqueue_request(&campaign.ctx, campaign.requester, 0xB001, rejected[:]) do return "enqueue rejected mixed transaction"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if !transaction_simulation_result_matches(&campaign.ctx.sim, campaign.requester, .Rejected, 0xB001, 1, nil) ||
		   td.task_seq != 1 ||
		   writer.wal.record_count != baseline_records {
			return "rejected mixed transaction changed durable history"
		}
		nrc_sim_clear_inboxes(&campaign.ctx.sim)

		task_body := transaction_test_task_create_body(pr.WORKSPACE_DATA_ID, .Existing, 0, 'a')
		asset_body := transaction_simulation_asset_create_body(pr.WORKSPACE_DATA_ID)
		edge_body := transaction_simulation_edge_create_body(pr.WORKSPACE_DATA_ID)
		operations := [3]pr.TransactionOperation {
			{op_type = .TaskCreate, body = task_body[:]},
			{op_type = .AssetCreate, body = asset_body[:]},
			{op_type = .EdgeCreate, body = edge_body[:]},
		}
		if !transaction_simulation_enqueue_request(&campaign.ctx, campaign.requester, 0xB002, operations[:]) do return "enqueue accepted mixed transaction"
		// Vary publication relative to fragmented transaction admission, while
		// preserving the FIFO byte order of each TCP stream.
		if compact && schedule & 1 == 0 {
			if !sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, .Compaction_Job) ||
			   !sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, .Compaction_Result) {
				return "publish compaction before transaction admission"
			}
			if !transaction_compaction_published(writer, before_compaction) do return "transaction history pre-admission compaction was not published"
		}
		for nrc_sim_receive_event_count(&campaign.ctx.sim) > 0 {
			if !nrc_sim_run_next_receive(&campaign.ctx.sim) {
				return "transaction receive schedule stalled"
			}
		}
		if writer.wal.record_count != baseline_records + 1 ||
		   writer.wal.durable_record_count != baseline_durable ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 {
			return "accepted transaction crossed pre-durability boundary"
		}

		if disconnect {
			if !simulation_test_disconnect_client(&campaign.ctx, 1) do return "requester disconnect failed"
			campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "replacement", init_send_queue = true)
			campaign.ctx.conns[1] = campaign.requester
			if campaign.requester == nil do return "requester replacement failed"
		}
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work do return "transaction fsync was not submitted"
		// This ordinary mutation lands after the captured fsync prefix. It must
		// disappear on restart even when the preceding transaction survives.
		tail := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("undurable tail"),
			status         = .Todo,
			correlation_id = 0xB004,
		}
		if !semantic_transport_persistence_enqueue_create(&campaign, tail, 2, 9) do return "enqueue ordinary tail"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if td.task_seq != 3 || writer.wal.record_count != baseline_records + 2 do return "ordinary tail missing from speculative history"
		if compact && schedule & 1 != 0 {
			if !sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, .Compaction_Job) ||
			   !sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, .Compaction_Result) {
				return "publish compaction over pending transaction and ordinary tail"
			}
			if !transaction_compaction_published(writer, before_compaction) do return "transaction history post-admission compaction was not published"
		}
		if outcome != .Pending {
			// Keep expected EIO logging out of the test runner's error logger.
			context.logger = outcome == .Error ? log.nil_logger() : context.logger
			fsync_errno := outcome == .Error ? linux.Errno.EIO : linux.Errno.NONE
			completed := nrc_sim_run_next_fsync_completion(&campaign.ctx.sim, fsync_errno)
			if !completed do return "transaction fsync completion missing"
		}
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if outcome != .Success || disconnect {
			if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 do return "undurable or stale transaction response escaped"
		} else {
			results := [3]pr.TransactionOperationResult {
				{op_type = .TaskCreate, entity_id = 2},
				{op_type = .AssetCreate, entity_id = 1},
				{op_type = .EdgeCreate, entity_id = 1},
			}
			if !transaction_simulation_result_matches(&campaign.ctx.sim, campaign.requester, .Committed, 0xB002, max(u16), results[:]) do return "durable transaction result differs"
		}
		if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != (outcome == .Success ? 3 : 0) do return "transaction peer durability ledger differs"

		// A real virtual process loss discards speculative pages, callbacks,
		// connections and process memory before reopening storage.
		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		if !replay_ok do return "transaction virtual crash replay failed"
		expected := Shard_High_Water_Requirements {
			task = 1,
		}
		if outcome == .Success do expected = {
			task  = 2,
			asset = 1,
			edge  = 1,
		}
		if floors != expected do return fmt.tprintf("ledger/replay floors differ: got=%v expected=%v", floors, expected)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if conv == nil || len(conv.tasks) != int(expected.task) || len(conv.assets) != int(expected.asset) || len(conv.edges) != int(expected.edge) {
			return "recovery violated all-or-none transaction ledger"
		}
		if !semantic_transport_persistence_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) do return "recovery lost ordinary durable mutation"
		if outcome == .Success {
			task := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)
			asset := conv.assets[1]
			edge := conv.edges[1]
			if task == nil ||
			   string(task.title) != "a" ||
			   asset == nil ||
			   asset.parent_id != 2 ||
			   string(asset.payload) != "body" ||
			   edge == nil ||
			   edge.source_id != 2 ||
			   edge.target_id != 1 {
				return "recovered transaction content or symbolic references differ"
			}
		}

		// Correct continuation is part of the property, not merely successful replay.
		campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "continued", init_send_queue = true)
		campaign.ctx.conns[1] = campaign.requester
		if campaign.requester == nil do return "install continuation requester"
		continuation := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("continued"),
			status         = .Todo,
			correlation_id = 0xB003,
		}
		if !semantic_transport_persistence_enqueue_create(&campaign, continuation, 2, 9) do return "enqueue continuation mutation"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		writer = semantic_transport_persistence_writer(&campaign)
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) do return "continuation fsync failed"
		if get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, pr.TaskID(expected.task + 1)) == nil {
			return "continued mutation used wrong recovered sequence"
		}
		return ""
	}

	@(test)
	test_client_atomic_transaction_mandatory_failure_boundaries :: proc(t: ^testing.T) {
		for compact in ([?]bool{false, true}) {
			for outcome in Transaction_Crash_Outcome {
				for disconnect in ([?]bool{false, true}) {
					for schedule in 0 ..< 2 {
						diagnostic := transaction_generated_failure_history(compact, outcome, disconnect, u8(schedule))
						testing.expectf(
							t,
							diagnostic == "",
							"transaction boundary compact=%v outcome=%v disconnect=%v schedule=%d: %s",
							compact,
							outcome,
							disconnect,
							schedule,
							diagnostic,
						)
					}
				}
			}
		}
	}

	prop_client_atomic_transaction_failure_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		compact, err := hgl.draw_bool(tc)
		if err == .Stop_Test do return hgl.abort()
		if err != nil do return hgl.interesting("draw transaction compaction choice")
		outcome, outcome_err := hgl.draw_i64(tc, 0, 2)
		if outcome_err == .Stop_Test do return hgl.abort()
		if outcome_err != nil do return hgl.interesting("draw transaction fsync result")
		disconnect, disconnect_err := hgl.draw_bool(tc)
		if disconnect_err == .Stop_Test do return hgl.abort()
		if disconnect_err != nil do return hgl.interesting("draw transaction requester lifetime")
		rank, rank_err := hgl.draw_i64(tc, 0, 1)
		if rank_err == .Stop_Test do return hgl.abort()
		if rank_err != nil do return hgl.interesting("draw transaction publication schedule")
		if diagnostic := transaction_generated_failure_history(compact, Transaction_Crash_Outcome(outcome), disconnect, u8(rank)); diagnostic != "" {
			if tc.is_final do fmt.eprintf("client transaction history failed: %s choices=%v/%v/%v/%d\n", diagnostic, compact, outcome, disconnect, rank)
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	@(test)
	test_hegel_client_atomic_transaction_failure_histories :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_client_atomic_transaction_failure_histories, nil, {test_cases = 32})
		testing.expectf(t, err == nil, "client atomic transaction history property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
