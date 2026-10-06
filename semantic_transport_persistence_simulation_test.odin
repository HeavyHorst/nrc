package main

// Small cross-domain composition: one split WebSocket task mutation drives the
// production parser, handler, WAL, requester response, peer broadcast, async
// fsync callback, and restart replay while send/fsync completions interleave.

import "core:bytes"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:time"

import "btree"
import hgl "hegel"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import "storage_io"

when !NRC_SIMULATION {
	_ :: bytes.equal
	_ :: queue.len
	_ :: fmt.eprintf
	_ :: log.nil_logger
	_ :: os.remove_all
	_ :: strings.clone
	_ :: sync.atomic_load
	_ :: linux.Errno
	_ :: testing.T
	_ :: time.Hour
	_ :: btree.count
	_ :: hgl.run
	_ :: nbio.init
	_ :: persistence.force_fsync
	_ :: pr.CreateTaskRequest
	_ :: storage_io.Context
}

when NRC_SIMULATION {
	Semantic_Transport_Persistence_Action :: enum {
		Run_Receive,
		Run_Requester_Send,
		Run_Peer_Send,
		Submit_Fsync,
		Run_Fsync,
	}

	Semantic_Update_Action :: enum {
		Run_Requester_Send,
		Run_Peer_Send,
		Run_Fsync,
		Submit_Second_Fsync,
	}

	Semantic_Global_Compaction_Crash :: enum {
		None,
		Before_Active_Fsync,
		Before_Compaction_Result,
	}

	Semantic_Global_Compaction_Mutation :: enum {
		Create_Task,
		Update_Task,
		Delete_Task,
		Delete_Task_Cascade,
	}

	Semantic_Transport_Persistence_Campaign :: struct {
		ctx:                      Sim_Test_Context,
		ctx_started:              bool,
		server:                   NRC_Server,
		registry_started:         bool,
		data_dir:                 string,
		generation_dir:           string,
		shard_dir:                string,
		workspace:                string,
		shard:                    int,
		requester:                ^NRC_Connection,
		peer:                     ^NRC_Connection,
		fsync_submitted:          bool,
		fsync_completed:          bool,
		fsync_error:              bool,
		requester_send_completed: bool,
		peer_send_completed:      bool,
		requester_reused:         bool,
		frames_verified:          bool,
		reused_old_counted:       bool,
		reused_old_handle:        Connection_Handle,
		virtual_storage:          bool,
		wal_pending_bytes:        u64,
		initial_wal_hash:         [32]u8,
		pool_live_before:         uint,
		invalid_releases_before:  u64,
	}

	Semantic_Update_Campaign :: struct {
		base:                       Semantic_Transport_Persistence_Campaign,
		first_snapshot_bytes:       u64,
		first_snapshot_hash:        [32]u8,
		update_pending_bytes:       u64,
		update_hash:                [32]u8,
		fsync_completions:          int,
		second_fsync_submitted:     bool,
		requester_send_completions: int,
		peer_send_completions:      int,
	}

	Semantic_Dependent_Task_Kind :: enum u8 {
		Original,
		Created,
		Updated,
		Deleted,
	}

	Semantic_Dependent_Task_Model :: struct {
		kind:        Semantic_Dependent_Task_Kind,
		live:        bool,
		asset_live:  bool,
		edge_live:   bool,
		task_id:     pr.TaskID,
		task_floor:  u64,
		asset_floor: u64,
		edge_floor:  u64,
		create_req:  pr.CreateTaskRequest,
		update_req:  pr.UpdateTaskRequest,
	}

	semantic_transport_persistence_writer :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> ^Shard_Transaction_Writer {
		if campaign == nil || len(td.shard_writers.writers) != 1 do return nil
		return &td.shard_writers.writers[0]
	}

	semantic_transport_persistence_pending_item :: proc(conn: ^NRC_Connection, index: int) -> ^Send_Item {
		priority_len := queue.len(conn.priority_queue)
		if index < priority_len do return queue.get_ptr(&conn.priority_queue, index)
		offset := index - priority_len
		if offset < int(conn.inline_len) {
			return &conn.inline_queue[(int(conn.inline_head) + offset) % Inline_Queue_Size]
		}
		offset -= int(conn.inline_len)
		if offset < queue.len(conn.spill_queue) do return queue.get_ptr(&conn.spill_queue, offset)
		return nil
	}

	// Read an immutable queued frame without making speculative output visible to
	// the simulated client. The newest matching opcode is the response generated
	// by the observer currently being checked.
	semantic_transport_persistence_pending_payload :: proc(conn: ^NRC_Connection, opcode: pr.Opcode) -> ([]byte, bool) {
		candidate: []byte
		for index in 0 ..< send_queue_len(conn) {
			item := semantic_transport_persistence_pending_item(conn, index)
			if item == nil || outbox_item_is_durable(item) do continue
			payload, ok := nrc_sim_frame_protocol_payload(frame_lease_data(item.lease))
			if ok && pr.get_opcode(payload) == opcode do candidate = payload
		}
		return candidate, candidate != nil
	}

	semantic_transport_persistence_init_writer :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> bool {
		registry := &td.shard_writers
		if registry.mode != .Inactive || len(registry.writers) != 0 do return false
		for &writer_index in registry.writer_index do writer_index = -1
		registry.worker = 0
		registry.worker_count = 1
		registry.writers = make([dynamic]Shard_Transaction_Writer, 1)
		initialized := false
		if campaign.virtual_storage {
			initialized = init_managed_shard_transaction_writer(
				&registry.writers[0],
				sim_world_storage_context(&campaign.ctx.sim.world),
				campaign.shard_dir,
				campaign.shard,
				0,
				1,
			)
		} else {
			initialized = init_managed_shard_transaction_writer(&registry.writers[0], campaign.shard_dir, campaign.shard, 0, 1)
		}
		if !initialized {
			shutdown_shard_writer_registry(registry)
			return false
		}
		registry.writer_index[campaign.shard] = 0
		registry.mode = .Active
		campaign.registry_started = true
		return true
	}

	semantic_transport_persistence_enqueue_create :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.CreateTaskRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [1_024]byte
		request_len := pr.serializeCreateTaskRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_update :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.UpdateTaskRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [4_096]byte
		request_len := pr.serializeUpdateTaskRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_move :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.MoveTaskRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [64]byte
		request_len := pr.serializeMoveTaskRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_task_page :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.ListTasksPagedRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [64]byte
		request_len := pr.serializeListTasksPagedRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		if len(frame) < 3 do return false
		interior_count := len(frame) - 1
		first := 1 + split_a % interior_count
		second := 1 + split_b % interior_count
		if first == second do second = 1 + second % interior_count
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_delete :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		conv_id: pr.ConversationID,
		task_id: pr.TaskID,
		correlation_id: u32,
		split_a, split_b: int,
	) -> bool {
		request_buf: [64]byte
		request_len := pr.serializeDeleteTaskRequest(conv_id, task_id, request_buf[:], correlation_id)
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_create_asset :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.CreateAssetRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [4_096]byte
		request_len := pr.serializeCreateAssetRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_update_asset :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.UpdateAssetRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [4_096]byte
		request_len := pr.serializeUpdateAssetRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_delete_asset :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		conv_id: pr.ConversationID,
		asset_id: pr.AssetID,
		correlation_id: u32,
		split_a, split_b: int,
	) -> bool {
		request_buf: [32]byte
		request_len := pr.serializeDeleteAssetRequest(conv_id, asset_id, request_buf[:], correlation_id)
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_create_edge :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.CreateEdgeRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [64]byte
		request_len := pr.serializeCreateEdgeRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_graph_query :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.GraphQueryRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [64]byte
		request_len := pr.serializeGraphQueryRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_shortest_path :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.GraphShortestPathRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [64]byte
		request_len := pr.serializeGraphShortestPathRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_enqueue_common_neighbors :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: pr.GraphCommonNeighborsRequest,
		split_a, split_b: int,
	) -> bool {
		request_buf: [64]byte
		request_len := pr.serializeGraphCommonNeighborsRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		first := clamp(split_a, 0, len(frame))
		second := clamp(split_b, 0, len(frame))
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[start:end]) do return false
		}
		return true
	}

	semantic_transport_persistence_campaign_begin :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		name: string,
		split_a, split_b: int,
		fsync_error: bool = false,
		thread_index: int = 127,
		virtual_storage: bool = false,
	) -> string {
		campaign^ = {}
		simulation_test_begin(&campaign.ctx, thread_index)
		campaign.ctx_started = true
		td.server = &campaign.server
		campaign.fsync_error = fsync_error
		campaign.virtual_storage = virtual_storage
		campaign.workspace = "semantic-transport-persistence"
		campaign.shard = int(shard_for_workspace(transmute([]byte)campaign.workspace))

		if virtual_storage {
			campaign.shard_dir = "/shard"
			if _, storage_ok := generated_semantic_virtual_storage_prepare(&campaign.ctx.sim.world, campaign.shard_dir); !storage_ok {
				return "initialize virtual campaign storage"
			}
		} else {
			case_name := fmt.aprintf("semantic-transport-persistence-%s", name)
			defer delete(case_name)
			setup_dir := storage_layout_test_setup(case_name)
			data_dir, clone_err := strings.clone(setup_dir)
			if clone_err != nil {
				_ = os.remove_all(setup_dir)
				return "clone campaign data directory"
			}
			campaign.data_dir = data_dir
			if !storage_layout_test_create_generation(campaign.data_dir, 1) do return "create sharded generation"
			campaign.generation_dir = sharded_generation_path(campaign.data_dir, 1)
			campaign.shard_dir = sharded_shard_path(campaign.generation_dir, campaign.shard)
		}
		if !semantic_transport_persistence_init_writer(campaign) do return "initialize managed shard writer"
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
		campaign.initial_wal_hash = semantic_transport_persistence_writer(campaign).wal.last_hash

		campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "requester", init_send_queue = true)
		campaign.ctx.conns[1] = campaign.requester
		if campaign.requester == nil do return "install simulated requester"
		campaign.peer = simulation_test_install_client(&campaign.ctx.sim, 2, campaign.workspace, "peer", init_send_queue = true)
		campaign.ctx.conns[2] = campaign.peer
		if campaign.peer == nil do return "install simulated peer"
		subscribe_to_conversation(campaign.requester, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.requester, 77)
		subscribe_to_conversation(campaign.peer, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.peer, 77)
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		campaign.pool_live_before = connection_lifetime_pool_live_alloc_count(td.spool)
		campaign.invalid_releases_before = td.spool.invalid_release_count

		req := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("cross-domain task"),
			description    = transmute([]byte)string("parser transport persistence"),
			priority       = 3,
			status         = .Todo,
			correlation_id = 0xC0DE,
			project        = transmute([]byte)string("simulation"),
		}
		if !semantic_transport_persistence_enqueue_create(campaign, req, split_a, split_b) do return "enqueue split create-task request"
		return semantic_transport_persistence_check(campaign)
	}

	semantic_transport_persistence_task_exact :: proc(task: ^pr.Task) -> bool {
		return(
			task != nil &&
			task.id == 1 &&
			task.conv_id == pr.WORKSPACE_DATA_ID &&
			string(task.title) == "cross-domain task" &&
			string(task.description) == "parser transport persistence" &&
			task.status == .Todo &&
			task.order_index == 0 &&
			len(task.assignee) == 0 &&
			task.priority == 3 &&
			task.color == .None &&
			string(task.created_by) == "requester" &&
			task.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			task.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			len(task.external_ref) == 0 &&
			task.due_at == 0 &&
			task.blocked_by == 0 &&
			task.completed_at == 0 &&
			len(task.completed_by) == 0 &&
			string(task.project) == "simulation" &&
			len(task.attachments) == 0 \
		)
	}

	semantic_transport_persistence_updated_task_exact :: proc(task: ^pr.Task) -> bool {
		return(
			task != nil &&
			task.id == 1 &&
			task.conv_id == pr.WORKSPACE_DATA_ID &&
			string(task.title) == "updated cross-domain task" &&
			string(task.description) == "update appended during create fsync" &&
			task.status == .Done &&
			task.order_index == 0 &&
			string(task.assignee) == "peer" &&
			task.priority == 7 &&
			task.color == .Gold &&
			string(task.created_by) == "requester" &&
			task.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			task.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			string(task.external_ref) == "SIM-UPDATE-1" &&
			task.due_at == NRC_SIM_TIME_EPOCH_NANOS + 60_000_000_000 &&
			task.blocked_by == 0 &&
			task.completed_at == NRC_SIM_TIME_EPOCH_NANOS &&
			string(task.completed_by) == "requester" &&
			string(task.project) == "updated-simulation" &&
			len(task.attachments) == 0 \
		)
	}

	semantic_transport_persistence_active_task_exact :: proc(task: ^pr.Task) -> bool {
		return(
			task != nil &&
			task.id == 2 &&
			task.conv_id == pr.WORKSPACE_DATA_ID &&
			string(task.title) == "active during compaction" &&
			string(task.description) == "must remain in the active WAL" &&
			task.status == .Todo &&
			task.order_index == 1 &&
			len(task.assignee) == 0 &&
			task.priority == 5 &&
			task.color == .None &&
			string(task.created_by) == "requester" &&
			task.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			task.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			len(task.external_ref) == 0 &&
			task.due_at == 0 &&
			task.blocked_by == 0 &&
			task.completed_at == 0 &&
			len(task.completed_by) == 0 &&
			string(task.project) == "simulation" &&
			len(task.attachments) == 0 \
		)
	}

	semantic_global_compaction_continued_task_exact :: proc(task: ^pr.Task, id: pr.TaskID, order_index: u16) -> bool {
		return(
			task != nil &&
			task.id == id &&
			task.conv_id == pr.WORKSPACE_DATA_ID &&
			string(task.title) == "continued after global crash" &&
			string(task.description) == "must survive the verification restart" &&
			task.status == .Todo &&
			task.order_index == order_index &&
			len(task.assignee) == 0 &&
			task.priority == 7 &&
			task.color == .None &&
			string(task.created_by) == "requester" &&
			task.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			task.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			len(task.external_ref) == 0 &&
			task.due_at == 0 &&
			task.blocked_by == 0 &&
			task.completed_at == 0 &&
			len(task.completed_by) == 0 &&
			string(task.project) == "simulation" &&
			len(task.attachments) == 0 \
		)
	}

	semantic_global_compaction_asset_exact :: proc(asset: ^pr.Asset) -> bool {
		return(
			asset != nil &&
			asset.asset_id == 1 &&
			asset.conv_id == pr.WORKSPACE_DATA_ID &&
			asset.asset_type == .Document &&
			asset.parent_type == .Task &&
			asset.parent_id == 1 &&
			string(asset.owner) == "requester" &&
			asset.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			asset.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			asset.payload_encoding == .Plain &&
			asset.payload_raw_len == 13 &&
			string(asset.preview) == "owned cascade" &&
			string(asset.payload) == "owned cascade" &&
			len(asset.attachments) == 0 \
		)
	}

	semantic_global_compaction_edge_exact :: proc(edge: ^pr.Edge) -> bool {
		return(
			edge != nil &&
			edge.edge_id == 1 &&
			edge.conv_id == pr.WORKSPACE_DATA_ID &&
			edge.source_type == .Task &&
			edge.source_id == 1 &&
			edge.target_type == .Asset &&
			edge.target_id == 1 &&
			edge.relation == .References &&
			edge.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			string(edge.created_by) == "requester" \
		)
	}

	semantic_transport_persistence_uninstall_client :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, client_id: int) {
		conn := campaign.ctx.conns[client_id]
		if conn == nil do return
		simulation_test_uninstall_client(conn)
		campaign.ctx.conns[client_id] = nil
	}

	semantic_transport_persistence_campaign_end :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) {
		if campaign.ctx_started {
			nrc_sim_run_all_receives(&campaign.ctx.sim)
			nrc_sim_run_all_send_completions(&campaign.ctx.sim)
			nrc_sim_run_all_close_completions(&campaign.ctx.sim)
			nrc_sim_run_all_send_completions(&campaign.ctx.sim)
			for nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {}
			if campaign.reused_old_counted {
				old := connection_get_by_handle(campaign.reused_old_handle)
				if old == nil {
					connection_test_live_count -= 1
				} else {
					simulation_test_uninstall_client(old)
				}
				campaign.reused_old_counted = false
			}
			semantic_transport_persistence_uninstall_client(campaign, 1)
			semantic_transport_persistence_uninstall_client(campaign, 2)
		}
		if campaign.registry_started {
			shutdown_shard_writer_registry(&td.shard_writers)
			campaign.registry_started = false
		}
		td.server = nil
		if !campaign.virtual_storage && campaign.shard_dir != "" do delete(campaign.shard_dir)
		if !campaign.virtual_storage && campaign.generation_dir != "" do delete(campaign.generation_dir)
		if !campaign.virtual_storage && campaign.data_dir != "" {
			_ = os.remove_all(campaign.data_dir)
			delete(campaign.data_dir)
		}
		if campaign.ctx_started {
			simulation_test_end(&campaign.ctx)
			campaign.ctx_started = false
		}
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
		campaign^ = {}
	}

	semantic_transport_persistence_check_frames :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> string {
		if campaign.requester_reused {
			if !campaign.frames_verified do return "requester reused before semantic frames were verified"
			if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 {
				return "stale task response reached replacement requester"
			}
			return ""
		}
		if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 1 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 1 {
			return fmt.tprintf(
				"task frame count mismatch: requester=%d peer=%d",
				nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock),
				nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock),
			)
		}
		request_frame := nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, 0)
		peer_frame := nrc_sim_client_frame(&campaign.ctx.sim, campaign.peer.sock, 0)
		request_payload, request_ok := nrc_sim_frame_protocol_payload(request_frame)
		peer_payload, peer_ok := nrc_sim_frame_protocol_payload(peer_frame)
		if !request_ok || !peer_ok do return "decode captured task WebSocket frames"
		request_attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		peer_attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		request_event, request_err := pr.parseTaskCreated(request_payload, request_attachments[:])
		peer_event, peer_err := pr.parseTaskCreated(peer_payload, peer_attachments[:])
		if request_err != nil || peer_err != nil {
			return fmt.tprintf("parse task-created frames: requester=%v peer=%v", request_err, peer_err)
		}
		if request_event.correlation_id != 0xC0DE ||
		   peer_event.correlation_id != 0 ||
		   !semantic_transport_persistence_task_exact(&request_event.task) ||
		   !semantic_transport_persistence_task_exact(&peer_event.task) {
			return "task-created requester/broadcast semantics mismatch"
		}
		expected_request_payload: [1_024]byte
		expected_peer_payload: [1_024]byte
		expected_request_len := pr.serializeTaskCreated(request_event, expected_request_payload[:])
		expected_peer_len := pr.serializeTaskCreated(peer_event, expected_peer_payload[:])
		if expected_request_len <= 0 || expected_peer_len <= 0 do return "serialize expected task-created frames"
		expected_request_frame := make_test_ws_frame(expected_request_payload[:expected_request_len], .opBinary, true, false)
		defer delete(expected_request_frame)
		expected_peer_frame := make_test_ws_frame(expected_peer_payload[:expected_peer_len], .opBinary, true, false)
		defer delete(expected_peer_frame)
		if !bytes.equal(request_frame, expected_request_frame) || !bytes.equal(peer_frame, expected_peer_frame) {
			return "task-created WebSocket frame bytes mismatch"
		}
		campaign.frames_verified = true
		return ""
	}

	semantic_transport_persistence_check :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "campaign writer missing"
		accepted_records := writer.wal.record_count + writer.wal.buffered_record_count
		mutation_visible := accepted_records == 1
		if accepted_records > 1 do return "task request appended more than one WAL record"
		ws := get_workspace(campaign.workspace)
		conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
		task := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)
		if !mutation_visible {
			if task != nil ||
			   nrc_sim_send_completion_count(&campaign.ctx.sim) != 0 ||
			   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 ||
			   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 ||
			   int(campaign.requester.pending_io) != nrc_sim_receive_event_count(&campaign.ctx.sim) ||
			   campaign.peer.pending_io != 0 {
				return "partial request mutated state or changed receive ownership"
			}
			if td.task_seq != 0 ||
			   td.asset_seq != 0 ||
			   td.edge_seq != 0 ||
			   writer.floors != {} ||
			   writer.wal.durable_record_count != 0 ||
			   writer.wal.pending_bytes != 0 ||
			   writer.wal.last_hash != campaign.initial_wal_hash ||
			   conv == nil ||
			   len(conv.tasks) != 0 {
				return "partial request changed sequence, floor, WAL, or conversation state"
			}
			return ""
		}
		if !semantic_transport_persistence_task_exact(task) ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1}) ||
		   td.task_seq != 1 ||
		   td.asset_seq != 0 ||
		   td.edge_seq != 0 {
			return "visible task/WAL floor mismatch"
		}
		outputs_released := campaign.fsync_completed && !campaign.fsync_error
		if outputs_released {
			if diagnostic := semantic_transport_persistence_check_frames(campaign); diagnostic != "" do return diagnostic
		} else if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) != 0 {
			return "task output escaped before shard durability"
		}
		if campaign.wal_pending_bytes == 0 {
			campaign.wal_pending_bytes = writer.wal.pending_bytes
		}
		if !campaign.fsync_submitted {
			if writer.poisoned ||
			   !writer.wal.enabled ||
			   writer.fsync_in_flight ||
			   nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 0 ||
			   writer.wal.durable_record_count != 0 ||
			   writer.wal.pending_bytes != campaign.wal_pending_bytes ||
			   sync.atomic_load(&campaign.server.closing) ||
			   sync.atomic_load(&campaign.server.fatal_storage_error) {
				return "unsubmitted fsync phase mismatch"
			}
		} else if !campaign.fsync_completed {
			if writer.poisoned ||
			   !writer.wal.enabled ||
			   !writer.fsync_in_flight ||
			   nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 1 ||
			   writer.fsync_snapshot.record_count != 1 ||
			   writer.fsync_snapshot.pending_bytes != campaign.wal_pending_bytes ||
			   writer.wal.durable_record_count != 0 ||
			   writer.wal.pending_bytes != campaign.wal_pending_bytes ||
			   sync.atomic_load(&campaign.server.closing) ||
			   sync.atomic_load(&campaign.server.fatal_storage_error) {
				return "in-flight fsync phase mismatch"
			}
		} else if campaign.fsync_error {
			if !writer.poisoned ||
			   writer.wal.enabled ||
			   writer.fsync_in_flight ||
			   nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 0 ||
			   writer.wal.durable_record_count != 0 ||
			   writer.wal.pending_bytes != campaign.wal_pending_bytes ||
			   !sync.atomic_load(&campaign.server.closing) ||
			   !sync.atomic_load(&campaign.server.fatal_storage_error) {
				return "failed fsync did not poison the writer and request fatal shutdown"
			}
		} else if writer.poisoned ||
		   !writer.wal.enabled ||
		   writer.fsync_in_flight ||
		   nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 0 ||
		   writer.wal.durable_record_count != 1 ||
		   writer.wal.pending_bytes != 0 ||
		   sync.atomic_load(&campaign.server.closing) ||
		   sync.atomic_load(&campaign.server.fatal_storage_error) {
			return "successful fsync phase mismatch"
		}
		expected_requester_pending := 0
		expected_peer_pending := 0
		if outputs_released {
			expected_requester_pending = 1
			if campaign.requester_send_completed do expected_requester_pending = 0
			expected_peer_pending = 1
			if campaign.peer_send_completed do expected_peer_pending = 0
		}
		expected_sends := expected_requester_pending + expected_peer_pending
		if nrc_sim_send_completion_count(&campaign.ctx.sim) != expected_sends ||
		   int(campaign.requester.pending_io) != expected_requester_pending ||
		   int(campaign.peer.pending_io) != expected_peer_pending {
			return fmt.tprintf(
				"send callback ownership mismatch: queued=%d/%d requester=%d/%d peer=%d/%d",
				nrc_sim_send_completion_count(&campaign.ctx.sim),
				expected_sends,
				campaign.requester.pending_io,
				expected_requester_pending,
				campaign.peer.pending_io,
				expected_peer_pending,
			)
		}
		if td.spool.invalid_release_count != campaign.invalid_releases_before {
			return "semantic send performed an invalid pooled release"
		}
		if campaign.requester_send_completed &&
		   campaign.peer_send_completed &&
		   (campaign.requester.pending_io != 0 ||
				   campaign.peer.pending_io != 0 ||
				   connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before) {
			return "completed semantic sends retained I/O pins or pooled leases"
		}
		return ""
	}

	semantic_transport_persistence_send_completion_index :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, conn: ^NRC_Connection) -> int {
		if campaign == nil || conn == nil do return -1
		for ordinal in 0 ..< nrc_sim_send_completion_count(&campaign.ctx.sim) {
			completion, ok := nrc_sim_send_completion_at(&campaign.ctx.sim, ordinal)
			if ok && completion.sock == conn.sock do return ordinal
		}
		return -1
	}

	semantic_transport_persistence_actions :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		actions: ^[5]Semantic_Transport_Persistence_Action,
	) -> int {
		count := 0
		if nrc_sim_receive_event_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Run_Receive
			count += 1
		}
		if semantic_transport_persistence_send_completion_index(campaign, campaign.requester) >= 0 {
			actions[count] = .Run_Requester_Send
			count += 1
		}
		if semantic_transport_persistence_send_completion_index(campaign, campaign.peer) >= 0 {
			actions[count] = .Run_Peer_Send
			count += 1
		}
		writer := semantic_transport_persistence_writer(campaign)
		if writer != nil && writer.wal.record_count + writer.wal.buffered_record_count == 1 && !campaign.fsync_submitted {
			actions[count] = .Submit_Fsync
			count += 1
		}
		if nrc_sim_fsync_completion_count(&campaign.ctx.sim) > 0 {
			actions[count] = .Run_Fsync
			count += 1
		}
		return count
	}

	semantic_transport_persistence_run_action :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		action: Semantic_Transport_Persistence_Action,
	) -> string {
		switch action {
		case .Run_Receive:
			if !nrc_sim_run_next_receive(&campaign.ctx.sim) do return "selected receive was not runnable"
		case .Run_Requester_Send:
			index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if campaign.requester_send_completed || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, index) {
				return "selected requester send was not runnable"
			}
			campaign.requester_send_completed = true
		case .Run_Peer_Send:
			index := semantic_transport_persistence_send_completion_index(campaign, campaign.peer)
			if campaign.peer_send_completed || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, index) {
				return "selected peer send was not runnable"
			}
			campaign.peer_send_completed = true
		case .Submit_Fsync:
			writer := semantic_transport_persistence_writer(campaign)
			if writer == nil || campaign.fsync_submitted do return "selected fsync submission was not runnable"
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work do return "submit semantic task fsync"
			campaign.fsync_submitted = true
		case .Run_Fsync:
			previous_logger := context.logger
			if campaign.fsync_error do context.logger = log.nil_logger()
			err := linux.Errno.NONE
			if campaign.fsync_error do err = .EIO
			completed := nrc_sim_run_next_fsync_completion(&campaign.ctx.sim, err)
			context.logger = previous_logger
			if !completed do return "selected fsync completion was not runnable"
			campaign.fsync_completed = true
		}
		return semantic_transport_persistence_check(campaign)
	}

	semantic_transport_persistence_restart :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil || writer.fsync_in_flight {
			return "restart attempted before task durability"
		}
		if campaign.fsync_error {
			if !writer.poisoned || writer.wal.enabled || writer.wal.durable_record_count != 0 do return "restart attempted before failed fsync was observed"
		} else if writer.poisoned || !writer.wal.enabled || writer.wal.durable_record_count != 1 {
			return "restart attempted before task durability"
		}
		semantic_transport_persistence_uninstall_client(campaign, 1)
		semantic_transport_persistence_uninstall_client(campaign, 2)
		campaign.requester = nil
		campaign.peer = nil
		if !shutdown_shard_writer_registry(&td.shard_writers) do return "shutdown task writer before restart"
		campaign.registry_started = false
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		if !semantic_transport_persistence_init_writer(campaign) do return "reopen task writer"
		writer = semantic_transport_persistence_writer(campaign)
		floors, replay_ok := replay_shard_compaction_sequence(writer.shard_dir, writer.manifest, true, false)
		if !replay_ok || floors != (Shard_High_Water_Requirements{task = 1}) || writer.floors != floors {
			return fmt.tprintf("task replay floor mismatch: ok=%v replay=%v writer=%v", replay_ok, floors, writer.floors)
		}
		td.task_seq = floors.task
		ws := get_workspace(campaign.workspace)
		conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
		task := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)
		if !semantic_transport_persistence_task_exact(task) ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   td.task_seq != 1 ||
		   td.asset_seq != 0 ||
		   td.edge_seq != 0 {
			return "kernel-accepted task did not survive restart"
		}
		if sync.atomic_load(&campaign.server.closing) != campaign.fsync_error ||
		   sync.atomic_load(&campaign.server.fatal_storage_error) != campaign.fsync_error {
			return "restart changed fatal storage shutdown state"
		}
		return ""
	}

	semantic_transport_persistence_run_fixed :: proc(name: string, actions: []Semantic_Transport_Persistence_Action, fsync_error: bool = false) -> string {
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, name, 1, 7, fsync_error)
		defer semantic_transport_persistence_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic
		for action in actions {
			diagnostic = semantic_transport_persistence_run_action(&campaign, action)
			if diagnostic != "" do return diagnostic
		}
		action_storage: [5]Semantic_Transport_Persistence_Action
		for {
			count := semantic_transport_persistence_actions(&campaign, &action_storage)
			if count == 0 do break
			diagnostic = semantic_transport_persistence_run_action(&campaign, action_storage[0])
			if diagnostic != "" do return diagnostic
		}
		return semantic_transport_persistence_restart(&campaign)
	}

	semantic_update_campaign_check :: proc(campaign: ^Semantic_Update_Campaign) -> string {
		base := &campaign.base
		writer := semantic_transport_persistence_writer(base)
		if writer == nil do return "dependent update writer missing"
		conv := get_conversation(get_workspace(base.workspace), pr.WORKSPACE_DATA_ID)
		if !semantic_transport_persistence_updated_task_exact(get_task(base.workspace, pr.WORKSPACE_DATA_ID, 1)) ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   td.task_seq != 1 ||
		   td.asset_seq != 0 ||
		   td.edge_seq != 0 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1}) ||
		   writer.wal.record_count != 2 ||
		   writer.poisoned ||
		   !writer.wal.enabled ||
		   sync.atomic_load(&base.server.closing) ||
		   sync.atomic_load(&base.server.fatal_storage_error) {
			return "dependent update state/WAL floor mismatch"
		}

		expected_durable: u64
		expected_pending := campaign.first_snapshot_bytes + campaign.update_pending_bytes
		expected_fsyncs := 1
		if campaign.fsync_completions >= 1 {
			expected_durable = 1
			expected_pending = campaign.update_pending_bytes
			expected_fsyncs = 0
		}
		if campaign.second_fsync_submitted && campaign.fsync_completions == 1 do expected_fsyncs = 1
		if campaign.fsync_completions == 2 {
			expected_durable = 2
			expected_pending = 0
			expected_fsyncs = 0
		}
		if writer.wal.durable_record_count != expected_durable ||
		   writer.wal.pending_bytes != expected_pending ||
		   nrc_sim_fsync_completion_count(&base.ctx.sim) != expected_fsyncs ||
		   writer.fsync_in_flight != (expected_fsyncs == 1) {
			return fmt.tprintf(
				"dependent update fsync phase mismatch: durable=%d/%d pending=%d/%d completions=%d/%d in_flight=%v",
				writer.wal.durable_record_count,
				expected_durable,
				writer.wal.pending_bytes,
				expected_pending,
				nrc_sim_fsync_completion_count(&base.ctx.sim),
				expected_fsyncs,
				writer.fsync_in_flight,
			)
		}
		if campaign.fsync_completions == 0 &&
		   (writer.fsync_snapshot.record_count != 1 ||
				   writer.fsync_snapshot.pending_bytes != campaign.first_snapshot_bytes ||
				   writer.fsync_snapshot.last_hash != campaign.first_snapshot_hash) {
			return "update append changed the in-flight create fsync snapshot"
		}
		if writer.wal.last_hash != campaign.update_hash do return "dependent update WAL head hash changed"
		if campaign.fsync_completions == 0 && writer.wal.durable_last_hash == campaign.first_snapshot_hash {
			return "create hash became durable before first fsync completion"
		}
		if campaign.fsync_completions == 1 && writer.wal.durable_last_hash != campaign.first_snapshot_hash {
			return "first fsync completion advanced the wrong durable hash"
		}
		if campaign.second_fsync_submitted &&
		   campaign.fsync_completions == 1 &&
		   (writer.fsync_snapshot.record_count != 2 ||
				   writer.fsync_snapshot.pending_bytes != campaign.update_pending_bytes ||
				   writer.fsync_snapshot.last_hash != campaign.update_hash) {
			return "second fsync did not snapshot only the pending update"
		}
		if campaign.fsync_completions == 2 && writer.wal.durable_last_hash != campaign.update_hash {
			return "second fsync completion did not make the update hash durable"
		}

		expected_send_completions := 0
		sends := [?]struct {
			conn:      ^NRC_Connection,
			completed: int,
		}{{conn = base.requester, completed = campaign.requester_send_completions}, {conn = base.peer, completed = campaign.peer_send_completions}}
		for send in sends {
			expected_frames := min(campaign.fsync_completions, send.completed + 1)
			expected_pending_io: u32
			if expected_frames > send.completed {
				expected_send_completions += 1
				expected_pending_io = 1
			}
			expected_queued := 2 - expected_frames
			if send.conn.pending_io != expected_pending_io ||
			   send_queue_len(send.conn) != expected_queued ||
			   nrc_sim_client_frame_count(&base.ctx.sim, send.conn.sock) != expected_frames {
				return "dependent update send ownership mismatch"
			}
		}
		if nrc_sim_send_completion_count(&base.ctx.sim) != expected_send_completions || td.spool.invalid_release_count != base.invalid_releases_before {
			return "dependent update completion/release mismatch"
		}
		return ""
	}

	semantic_update_campaign_begin :: proc(campaign: ^Semantic_Update_Campaign, name: string, split_a, split_b: int, virtual_storage: bool = false) -> string {
		campaign^ = {}
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign.base, name, 1, 7, virtual_storage = virtual_storage)
		if diagnostic != "" do return diagnostic
		for nrc_sim_receive_event_count(&campaign.base.ctx.sim) > 0 {
			diagnostic = semantic_transport_persistence_run_action(&campaign.base, .Run_Receive)
			if diagnostic != "" do return diagnostic
		}
		diagnostic = semantic_transport_persistence_run_action(&campaign.base, .Submit_Fsync)
		if diagnostic != "" do return diagnostic
		writer := semantic_transport_persistence_writer(&campaign.base)
		campaign.first_snapshot_bytes = writer.fsync_snapshot.pending_bytes
		campaign.first_snapshot_hash = writer.fsync_snapshot.last_hash
		update := pr.UpdateTaskRequest {
			conv_id              = pr.WORKSPACE_DATA_ID,
			task_id              = 1,
			title                = transmute([]byte)string("updated cross-domain task"),
			description          = transmute([]byte)string("update appended during create fsync"),
			status               = .Done,
			assignee             = transmute([]byte)string("peer"),
			priority             = 7,
			color                = .Gold,
			external_ref         = transmute([]byte)string("SIM-UPDATE-1"),
			due_at               = NRC_SIM_TIME_EPOCH_NANOS + 60_000_000_000,
			preserve_attachments = true,
			project              = transmute([]byte)string("updated-simulation"),
			correlation_id       = 0xD00D,
		}
		if !semantic_transport_persistence_enqueue_update(&campaign.base, update, split_a, split_b) {
			return "enqueue segmented dependent update"
		}
		nrc_sim_run_all_receives(&campaign.base.ctx.sim)
		if writer.wal.pending_bytes <= campaign.first_snapshot_bytes do return "dependent update appended no pending WAL bytes"
		campaign.update_pending_bytes = writer.wal.pending_bytes - campaign.first_snapshot_bytes
		campaign.update_hash = writer.wal.last_hash
		if campaign.update_hash == campaign.first_snapshot_hash do return "dependent update did not advance the WAL hash"
		return semantic_update_campaign_check(campaign)
	}

	semantic_update_campaign_crash_after_first_prefix :: proc() -> string {
		campaign: Semantic_Update_Campaign
		diagnostic := semantic_update_campaign_begin(&campaign, "dependent-prefix-crash", 11, 23, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign.base)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		diagnostic = semantic_update_campaign_run_action(&campaign, .Run_Fsync)
		if diagnostic != "" do return diagnostic
		writer := semantic_transport_persistence_writer(&campaign.base)
		if writer == nil ||
		   campaign.fsync_completions != 1 ||
		   writer.wal.record_count != 2 ||
		   writer.wal.durable_record_count != 1 ||
		   writer.wal.pending_bytes != campaign.update_pending_bytes ||
		   writer.wal.durable_last_hash != campaign.first_snapshot_hash ||
		   writer.wal.last_hash != campaign.update_hash {
			return "dependent prefix crash did not isolate the completed fsync snapshot"
		}
		return semantic_global_compaction_crash_reopen(&campaign.base, .Update_Task, false)
	}

	semantic_dependent_history_update :: proc(index: int, choice: u8) -> pr.UpdateTaskRequest {
		titles := [?]string {
			"dependent history one",
			"dependent history two",
			"dependent history three",
			"dependent history four",
			"dependent history five",
			"dependent history six",
			"dependent history seven",
			"dependent history eight",
		}
		descriptions := [?]string {
			"first dependent replacement",
			"second dependent replacement",
			"third dependent replacement",
			"fourth dependent replacement",
			"fifth dependent replacement",
			"sixth dependent replacement",
			"seventh dependent replacement",
			"eighth dependent replacement",
		}
		statuses := [?]pr.TaskStatus{.Backlog, .Todo, .InProgress, .Done, .Note}
		colors := [?]pr.TaskColor{.None, .Cyan, .Red, .Green, .Gray, .Gold}
		assignees := [?]string{"requester", "peer", "history-owner"}
		projects := [?]string{"history-alpha", "history-beta", "history-gamma"}
		external_refs := [?]string{"HISTORY-1", "HISTORY-2", "HISTORY-3", "HISTORY-4"}
		return pr.UpdateTaskRequest {
			conv_id = pr.WORKSPACE_DATA_ID,
			task_id = 1,
			title = transmute([]byte)titles[index],
			description = transmute([]byte)descriptions[index],
			status = statuses[int(choice) % len(statuses)],
			assignee = transmute([]byte)assignees[int(choice / 5) % len(assignees)],
			priority = u8(1 + int(choice) % 9),
			color = colors[int(choice / 3) % len(colors)],
			external_ref = transmute([]byte)external_refs[int(choice / 7) % len(external_refs)],
			due_at = NRC_SIM_TIME_EPOCH_NANOS + i64(index + 1) * 60_000_000_000,
			preserve_attachments = true,
			project = transmute([]byte)projects[int(choice / 11) % len(projects)],
			correlation_id = 0xD100 + u32(index),
		}
	}

	semantic_dependent_history_task_exact :: proc(task: ^pr.Task, req: pr.UpdateTaskRequest) -> bool {
		expected_completed := req.status == .Done ? NRC_SIM_TIME_EPOCH_NANOS : i64(0)
		expected_completed_by := req.status == .Done ? "requester" : ""
		return(
			task != nil &&
			task.id == req.task_id &&
			task.conv_id == req.conv_id &&
			string(task.title) == string(req.title) &&
			string(task.description) == string(req.description) &&
			task.status == req.status &&
			task.order_index == 0 &&
			string(task.assignee) == string(req.assignee) &&
			task.priority == req.priority &&
			task.color == req.color &&
			string(task.created_by) == "requester" &&
			task.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			task.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			string(task.external_ref) == string(req.external_ref) &&
			task.due_at == req.due_at &&
			task.blocked_by == 0 &&
			task.completed_at == expected_completed &&
			string(task.completed_by) == expected_completed_by &&
			string(task.project) == string(req.project) &&
			len(task.attachments) == 0 \
		)
	}

	semantic_dependent_history_created_task_exact :: proc(task: ^pr.Task, task_id: pr.TaskID, req: pr.CreateTaskRequest) -> bool {
		return(
			task != nil &&
			task.id == task_id &&
			task.conv_id == req.conv_id &&
			string(task.title) == string(req.title) &&
			string(task.description) == string(req.description) &&
			task.status == req.status &&
			task.order_index == 0 &&
			len(task.assignee) == 0 &&
			task.priority == req.priority &&
			task.color == req.color &&
			string(task.created_by) == "requester" &&
			task.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			task.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			string(task.external_ref) == string(req.external_ref) &&
			task.due_at == req.due_at &&
			task.blocked_by == 0 &&
			task.completed_at == 0 &&
			len(task.completed_by) == 0 &&
			string(task.project) == string(req.project) &&
			len(task.attachments) == 0 \
		)
	}

	semantic_dependent_history_create :: proc(index: int, choice: u8) -> pr.CreateTaskRequest {
		titles := [?]string {
			"dependent create one",
			"dependent create two",
			"dependent create three",
			"dependent create four",
			"dependent create five",
			"dependent create six",
			"dependent create seven",
			"dependent create eight",
		}
		descriptions := [?]string {
			"first dependent creation",
			"second dependent creation",
			"third dependent creation",
			"fourth dependent creation",
			"fifth dependent creation",
			"sixth dependent creation",
			"seventh dependent creation",
			"eighth dependent creation",
		}
		statuses := [?]pr.TaskStatus{.Backlog, .Todo, .InProgress, .Note}
		colors := [?]pr.TaskColor{.None, .Cyan, .Red, .Green, .Gray, .Gold}
		projects := [?]string{"created-alpha", "created-beta", "created-gamma"}
		external_refs := [?]string{"CREATE-1", "CREATE-2", "CREATE-3", "CREATE-4"}
		return pr.CreateTaskRequest {
			conv_id = pr.WORKSPACE_DATA_ID,
			title = transmute([]byte)titles[index],
			description = transmute([]byte)descriptions[index],
			priority = u8(1 + int(choice) % 9),
			color = colors[int(choice / 3) % len(colors)],
			external_ref = transmute([]byte)external_refs[int(choice / 7) % len(external_refs)],
			due_at = NRC_SIM_TIME_EPOCH_NANOS + i64(index + 1) * 90_000_000_000,
			status = statuses[int(choice / 5) % len(statuses)],
			project = transmute([]byte)projects[int(choice / 11) % len(projects)],
			correlation_id = 0xD300 + u32(index),
		}
	}

	semantic_dependent_history_split :: proc(choice: u8, second: bool) -> int {
		if second do return 17 + int(choice % 8)
		return 1 + int(choice % 16)
	}

	semantic_dependent_history_enqueue :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Dependent_Task_Model,
		index: int,
		variant: u8,
		split_a, split_b: int,
	) -> bool {
		if !model.live {
			req := semantic_dependent_history_create(index, variant)
			if !semantic_transport_persistence_enqueue_create(campaign, req, split_a, split_b) do return false
			model.kind = .Created
			model.live = true
			model.task_floor += 1
			model.task_id = pr.TaskID(model.task_floor)
			model.create_req = req
			model.update_req = {}
			model.asset_live = false
			model.edge_live = false
			return true
		}
		if model.task_id == 1 && !model.asset_live && model.asset_floor == 0 && variant & 7 == 1 {
			payload := "owned cascade"
			req := pr.CreateAssetRequest {
				conv_id          = pr.WORKSPACE_DATA_ID,
				asset_type       = .Document,
				parent_type      = .Task,
				parent_id        = 1,
				payload_encoding = .Plain,
				payload_raw_len  = u32(len(payload)),
				preview          = transmute([]byte)payload,
				payload          = transmute([]byte)payload,
				correlation_id   = 0xD500 + u32(index),
			}
			if !semantic_transport_persistence_enqueue_create_asset(campaign, req, split_a, split_b) do return false
			model.asset_live = true
			model.asset_floor = 1
			return true
		}
		if model.task_id == 1 && model.asset_live && !model.edge_live && model.edge_floor == 0 && variant & 7 == 2 {
			req := pr.CreateEdgeRequest {
				conv_id        = pr.WORKSPACE_DATA_ID,
				source_type    = .Task,
				source_id      = 1,
				target_type    = .Asset,
				target_id      = 1,
				relation       = .References,
				correlation_id = 0xD500 + u32(index),
			}
			if !semantic_transport_persistence_enqueue_create_edge(campaign, req, split_a, split_b) do return false
			model.edge_live = true
			model.edge_floor = 1
			return true
		}
		if variant & 3 == 0 {
			if !semantic_transport_persistence_enqueue_delete(campaign, pr.WORKSPACE_DATA_ID, model.task_id, 0xD400 + u32(index), split_a, split_b) do return false
			model.kind = .Deleted
			model.live = false
			model.create_req = {}
			model.update_req = {}
			model.asset_live = false
			model.edge_live = false
			return true
		}
		req := semantic_dependent_history_update(index, variant)
		req.task_id = model.task_id
		if !semantic_transport_persistence_enqueue_update(campaign, req, split_a, split_b) do return false
		model.kind = .Updated
		model.create_req = {}
		model.update_req = req
		return true
	}

	semantic_dependent_history_model_check :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, model: Semantic_Dependent_Task_Model) -> string {
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if conv == nil ||
		   td.task_seq != model.task_floor ||
		   td.asset_seq != model.asset_floor ||
		   td.edge_seq != model.edge_floor ||
		   len(conv.tasks) != (model.live ? 1 : 0) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent generated task model shape differs"
		}
		if model.edge_live && !model.asset_live do return "dependent generated edge outlived its asset"
		if model.edge_live {
			if diagnostic := semantic_global_compaction_check_cascade_entities(campaign, true); diagnostic != "" do return diagnostic
		} else if model.asset_live {
			if diagnostic := semantic_dependent_cascade_asset_only_check(campaign); diagnostic != "" do return diagnostic
		} else {
			if diagnostic := semantic_global_compaction_check_cascade_entities(campaign, false); diagnostic != "" do return diagnostic
		}
		if !model.live {
			if model.kind != .Deleted do return "dependent generated non-live model is not a deletion"
			return ""
		}
		task := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, model.task_id)
		switch model.kind {
		case .Original:
			if model.task_id != 1 || !semantic_transport_persistence_task_exact(task) {
				return "dependent generated original task differs"
			}
		case .Created:
			if !semantic_dependent_history_created_task_exact(task, model.task_id, model.create_req) {
				return "dependent generated created task differs"
			}
		case .Updated:
			if !semantic_dependent_history_task_exact(task, model.update_req) {
				return "dependent generated updated task differs"
			}
		case .Deleted:
			return "dependent generated live model is a deletion"
		}
		return ""
	}

	semantic_dependent_history_observe_graph :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: Semantic_Dependent_Task_Model,
		choice: u8,
		split_a, split_b: int,
		operation_index: int,
	) -> string {
		if !model.live do return ""
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "dependent graph observer writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		sends_before := nrc_sim_send_completion_count(&campaign.ctx.sim)

		direction := pr.Direction(choice % 3)
		relation_choice := (choice / 3) % 3
		relation_mask: u16
		if relation_choice == 1 {
			relation_mask = u16(1) << (u16(pr.RelationType.References) - 1)
		} else if relation_choice == 2 {
			relation_mask = u16(1) << (u16(pr.RelationType.Blocks) - 1)
		}
		req := pr.GraphQueryRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			start_type     = .Task,
			start_id       = u64(model.task_id),
			max_depth      = 1 + (choice / 9) % 4,
			relation_mask  = relation_mask,
			direction      = direction,
			flags          = choice,
			correlation_id = 0xD700 + u32(operation_index),
		}
		if !semantic_transport_persistence_enqueue_graph_query(campaign, req, split_a, split_b) {
			return "dependent graph observer failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		response_frame_index := -1
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		queued_payload: []byte
		queued_payload_ok := false
		if queued_response {
			queued_payload, queued_payload_ok = semantic_transport_persistence_pending_payload(campaign.requester, .S_GraphQueryResult)
		}
		next_frame_index := requester_frames_before
		for _ in 0 ..< (queued_response ? 0 : 16) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && pr.get_opcode(payload) == .S_GraphQueryResult {
					candidate_nodes: [2]pr.GraphQueryNode
					candidate_edges: [1]pr.Edge
					candidate, candidate_err := pr.parseGraphQueryResult(payload, candidate_nodes[:], candidate_edges[:])
					if candidate_err == nil && candidate.correlation_id == req.correlation_id {
						response_frame_index = next_frame_index
						break
					}
				}
				next_frame_index += 1
			}
			if response_frame_index >= 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "dependent graph observer response remained blocked without requester completion"
			}
		}
		if writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before ||
		   (!queued_response && response_frame_index < requester_frames_before) ||
		   (queued_response && (!queued_payload_ok || nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before)) ||
		   (!queued_response && semantic_transport_persistence_send_completion_index(campaign, campaign.requester) < 0) ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) < sends_before ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) > sends_before + 1 {
			return "dependent graph observer mutated persistence or emitted unexpected fanout"
		}

		payload, payload_ok := queued_payload, queued_payload_ok
		if !queued_response {
			payload, payload_ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, response_frame_index))
		}
		nodes: [2]pr.GraphQueryNode
		edges: [1]pr.Edge
		result, parse_err := pr.parseGraphQueryResult(payload, nodes[:], edges[:])
		expect_edge := model.edge_live && direction != .Incoming && relation_choice != 2
		expected_node_count := expect_edge ? 2 : 1
		expected_edge_count := expect_edge ? 1 : 0
		if !payload_ok ||
		   parse_err != nil ||
		   result.conv_id != req.conv_id ||
		   result.start_type != req.start_type ||
		   result.start_id != req.start_id ||
		   result.truncated ||
		   result.correlation_id != req.correlation_id ||
		   len(result.nodes) != expected_node_count ||
		   len(result.edges) != expected_edge_count ||
		   result.nodes[0] != (pr.GraphQueryNode{target_type = .Task, target_id = u64(model.task_id), depth = 0}) {
			return "dependent graph observer response differs from model"
		}
		if expect_edge &&
		   (result.nodes[1] != (pr.GraphQueryNode{target_type = .Asset, target_id = 1, depth = 1}) ||
				   !semantic_global_compaction_edge_exact(&result.edges[0])) {
			return "dependent graph observer edge traversal differs from model"
		}
		if model_diagnostic := semantic_dependent_history_model_check(campaign, model); model_diagnostic != "" {
			return fmt.tprintf("dependent graph observer mutated semantic state: %s", model_diagnostic)
		}
		return ""
	}

	semantic_multihop_task_two_create :: proc() -> pr.CreateTaskRequest {
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			title = transmute([]byte)string("multi-hop endpoint"),
			description = transmute([]byte)string("reachable through an asset"),
			priority = 4,
			status = .Todo,
			project = transmute([]byte)string("simulation"),
			correlation_id = 0xD801,
		}
	}

	semantic_multihop_task_two_update :: proc() -> pr.UpdateTaskRequest {
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			task_id = 2,
			title = transmute([]byte)string("updated multi-hop endpoint"),
			description = transmute([]byte)string("continued after durable-prefix recovery"),
			status = .InProgress,
			assignee = transmute([]byte)string("peer"),
			priority = 8,
			color = .Cyan,
			external_ref = transmute([]byte)string("MULTIHOP-2"),
			due_at = NRC_SIM_TIME_EPOCH_NANOS + 900_000_000_000,
			preserve_attachments = true,
			project = transmute([]byte)string("simulation-updated"),
			correlation_id = 0xD802,
		}
	}

	semantic_multihop_task_two_exact :: proc(task: ^pr.Task, updated: bool) -> bool {
		if task == nil ||
		   task.id != 2 ||
		   task.conv_id != pr.WORKSPACE_DATA_ID ||
		   task.order_index != 1 ||
		   string(task.created_by) != "requester" ||
		   task.created_at != NRC_SIM_TIME_EPOCH_NANOS ||
		   task.updated_at != NRC_SIM_TIME_EPOCH_NANOS ||
		   task.blocked_by != 0 ||
		   task.completed_at != 0 ||
		   len(task.completed_by) != 0 ||
		   len(task.attachments) != 0 {
			return false
		}
		if !updated {
			req := semantic_multihop_task_two_create()
			return(
				string(task.title) == string(req.title) &&
				string(task.description) == string(req.description) &&
				task.status == req.status &&
				len(task.assignee) == 0 &&
				task.priority == req.priority &&
				task.color == .None &&
				len(task.external_ref) == 0 &&
				task.due_at == 0 &&
				string(task.project) == string(req.project) \
			)
		}
		req := semantic_multihop_task_two_update()
		return(
			string(task.title) == string(req.title) &&
			string(task.description) == string(req.description) &&
			task.status == req.status &&
			string(task.assignee) == string(req.assignee) &&
			task.priority == req.priority &&
			task.color == req.color &&
			string(task.external_ref) == string(req.external_ref) &&
			task.due_at == req.due_at &&
			string(task.project) == string(req.project) \
		)
	}

	semantic_multihop_edge_exact :: proc(edge: ^pr.Edge, edge_id: pr.EdgeID) -> bool {
		if edge == nil ||
		   edge.edge_id != edge_id ||
		   edge.conv_id != pr.WORKSPACE_DATA_ID ||
		   edge.relation != .References ||
		   edge.created_at != NRC_SIM_TIME_EPOCH_NANOS ||
		   string(edge.created_by) != "requester" {
			return false
		}
		if edge_id == 1 {
			return edge.source_type == .Task && edge.source_id == 1 && edge.target_type == .Asset && edge.target_id == 1
		}
		return edge.source_type == .Asset && edge.source_id == 1 && edge.target_type == .Task && edge.target_id == 2
	}

	semantic_multihop_check_state :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, expect_path, task_two_updated: bool) -> string {
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if conv == nil ||
		   td.task_seq != 2 ||
		   td.asset_seq != 1 ||
		   td.edge_seq != 2 ||
		   len(conv.tasks) != 2 ||
		   !semantic_transport_persistence_task_exact(conv.tasks[1]) ||
		   !semantic_multihop_task_two_exact(conv.tasks[2], task_two_updated) ||
		   !semantic_global_compaction_task_indexes_exact(conv) ||
		   len(conv.note_index_keys) != 0 ||
		   len(conv.note_project_assets) != 0 ||
		   len(conv.note_tag_assets) != 0 ||
		   btree.count(&conv.note_index) != 0 {
			return "multi-hop task/index state differs from exact model"
		}
		if !expect_path {
			if len(conv.assets) != 0 || len(conv.edges) != 0 || len(conv.edges_by_entity) != 0 {
				return "multi-hop deleted intermediate remains reachable"
			}
			return ""
		}
		task_one_edges := conv.edges_by_entity[Edge_Entity_Key{target_type = .Task, target_id = 1}]
		asset_edges := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}]
		task_two_edges := conv.edges_by_entity[Edge_Entity_Key{target_type = .Task, target_id = 2}]
		if len(conv.assets) != 1 ||
		   len(conv.edges) != 2 ||
		   len(conv.edges_by_entity) != 3 ||
		   !semantic_global_compaction_asset_exact(conv.assets[1]) ||
		   !semantic_multihop_edge_exact(conv.edges[1], 1) ||
		   !semantic_multihop_edge_exact(conv.edges[2], 2) ||
		   len(task_one_edges) != 1 ||
		   task_one_edges[0] != 1 ||
		   len(asset_edges) != 2 ||
		   asset_edges[0] != 1 ||
		   asset_edges[1] != 2 ||
		   len(task_two_edges) != 1 ||
		   task_two_edges[0] != 2 {
			return "multi-hop graph state differs from exact model"
		}
		return ""
	}

	semantic_multihop_observe_shortest_path :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		expect_path: bool,
		correlation_id: u32,
		split_a, split_b: int,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "multi-hop query writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		req := pr.GraphShortestPathRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			from_type      = .Task,
			from_id        = 1,
			to_type        = .Task,
			to_id          = 2,
			direction      = .Outgoing,
			max_depth      = 2,
			correlation_id = correlation_id,
		}
		if !semantic_transport_persistence_enqueue_shortest_path(campaign, req, split_a, split_b) {
			return "multi-hop shortest-path query failed to enqueue"
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "multi-hop shortest-path query was not three-way segmented"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		response_frame_index := -1
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		queued_payload: []byte
		queued_payload_ok := false
		if queued_response {
			queued_payload, queued_payload_ok = semantic_transport_persistence_pending_payload(campaign.requester, .S_GraphShortestPathResult)
		}
		next_frame_index := requester_frames_before
		for _ in 0 ..< (queued_response ? 0 : 32) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && pr.get_opcode(payload) == .S_GraphShortestPathResult {
					nodes: [3]pr.GraphPathNode
					edges: [2]pr.Edge
					candidate, candidate_err := pr.parseGraphShortestPathResult(payload, nodes[:], edges[:])
					if candidate_err == nil && candidate.correlation_id == correlation_id {
						response_frame_index = next_frame_index
						break
					}
				}
				next_frame_index += 1
			}
			if response_frame_index >= 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "multi-hop shortest-path response remained blocked"
			}
		}
		if (!queued_response && response_frame_index < requester_frames_before) ||
		   (queued_response && (!queued_payload_ok || nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before)) ||
		   writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before ||
		   (!queued_response && semantic_transport_persistence_send_completion_index(campaign, campaign.requester) < 0) {
			return "multi-hop shortest-path query mutated state or fanout"
		}
		payload, payload_ok := queued_payload, queued_payload_ok
		if !queued_response {
			payload, payload_ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, response_frame_index))
		}
		nodes: [3]pr.GraphPathNode
		edges: [2]pr.Edge
		result, parse_err := pr.parseGraphShortestPathResult(payload, nodes[:], edges[:])
		expected_count := expect_path ? 2 : 0
		expected_nodes := expect_path ? 3 : 0
		if !payload_ok ||
		   parse_err != nil ||
		   result.conv_id != pr.WORKSPACE_DATA_ID ||
		   result.from_type != .Task ||
		   result.from_id != 1 ||
		   result.to_type != .Task ||
		   result.to_id != 2 ||
		   result.found != expect_path ||
		   result.path_length != u8(expected_count) ||
		   result.correlation_id != correlation_id ||
		   len(result.nodes) != expected_nodes ||
		   len(result.edges) != expected_count {
			return "multi-hop shortest-path response differs from model"
		}
		if expect_path &&
		   (result.nodes[0] != (pr.GraphPathNode{target_type = .Task, target_id = 1}) ||
				   result.nodes[1] != (pr.GraphPathNode{target_type = .Asset, target_id = 1}) ||
				   result.nodes[2] != (pr.GraphPathNode{target_type = .Task, target_id = 2}) ||
				   !semantic_multihop_edge_exact(&result.edges[0], 1) ||
				   !semantic_multihop_edge_exact(&result.edges[1], 2)) {
			return "multi-hop shortest-path sequence differs from model"
		}
		return ""
	}

	semantic_multihop_install_clients :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> bool {
		campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "requester", init_send_queue = true)
		campaign.ctx.conns[1] = campaign.requester
		campaign.peer = simulation_test_install_client(&campaign.ctx.sim, 2, campaign.workspace, "peer", init_send_queue = true)
		campaign.ctx.conns[2] = campaign.peer
		if campaign.requester == nil || campaign.peer == nil do return false
		subscribe_to_conversation(campaign.requester, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.requester, 77)
		subscribe_to_conversation(campaign.peer, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.peer, 77)
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		return true
	}

	semantic_multihop_split :: proc(choice: u8, second: bool) -> int {
		// Every request in this campaign is at least 28 framed bytes. Keep both
		// boundaries distinct and strictly interior so every parser dispatch is
		// guaranteed to consume three non-empty receive events.
		if second do return 17 + int(choice % 8)
		return 1 + int(choice % 16)
	}

	semantic_multihop_shortest_path_run :: proc(choices: []u8, durable_delete: bool) -> string {
		if len(choices) < 16 do return "multi-hop choices are incomplete"
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(
			&campaign,
			"multi-hop-shortest-path",
			semantic_multihop_split(choices[0], false),
			semantic_multihop_split(choices[1], true),
			virtual_storage = true,
		)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "multi-hop foundation request was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "multi-hop foundation task missing"

		task_two := semantic_multihop_task_two_create()
		payload := "owned cascade"
		asset := pr.CreateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_type       = .Document,
			parent_type      = .Task,
			parent_id        = 1,
			payload_encoding = .Plain,
			payload_raw_len  = u32(len(payload)),
			preview          = transmute([]byte)payload,
			payload          = transmute([]byte)payload,
			correlation_id   = 0xD803,
		}
		edge_one := pr.CreateEdgeRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			source_type    = .Task,
			source_id      = 1,
			target_type    = .Asset,
			target_id      = 1,
			relation       = .References,
			correlation_id = 0xD804,
		}
		edge_two := pr.CreateEdgeRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			source_type    = .Asset,
			source_id      = 1,
			target_type    = .Task,
			target_id      = 2,
			relation       = .References,
			correlation_id = 0xD805,
		}
		if !semantic_transport_persistence_enqueue_create(
			   &campaign,
			   task_two,
			   semantic_multihop_split(choices[2], false),
			   semantic_multihop_split(choices[3], true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "multi-hop second task was not three-way segmented"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if !semantic_transport_persistence_enqueue_create_asset(
			   &campaign,
			   asset,
			   semantic_multihop_split(choices[4], false),
			   semantic_multihop_split(choices[5], true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "multi-hop asset was not three-way segmented"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if !semantic_transport_persistence_enqueue_create_edge(
			   &campaign,
			   edge_one,
			   semantic_multihop_split(choices[6], false),
			   semantic_multihop_split(choices[7], true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "multi-hop first edge was not three-way segmented"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if !semantic_transport_persistence_enqueue_create_edge(
			   &campaign,
			   edge_two,
			   semantic_multihop_split(choices[8], false),
			   semantic_multihop_split(choices[9], true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "multi-hop second edge was not three-way segmented"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if writer.wal.record_count != 5 || writer.floors != (Shard_High_Water_Requirements{task = 2, asset = 1, edge = 2}) {
			return "multi-hop graph WAL differs from model"
		}
		if diagnostic = semantic_multihop_check_state(&campaign, true, false); diagnostic != "" do return diagnostic
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != 5 {
			return "multi-hop graph prefix fsync failed"
		}
		if diagnostic = semantic_multihop_observe_shortest_path(&campaign, true, 0xD810, semantic_multihop_split(choices[10], false), semantic_multihop_split(choices[11], true)); diagnostic != "" do return diagnostic

		if !semantic_transport_persistence_enqueue_delete_asset(
			   &campaign,
			   pr.WORKSPACE_DATA_ID,
			   1,
			   0xD806,
			   semantic_multihop_split(choices[12], false),
			   semantic_multihop_split(choices[13], true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "multi-hop intermediate deletion was not three-way segmented"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if writer.wal.record_count != 6 || writer.floors != (Shard_High_Water_Requirements{task = 2, asset = 1, edge = 2}) {
			return "multi-hop intermediate deletion WAL differs from model"
		}
		if diagnostic = semantic_multihop_check_state(&campaign, false, false); diagnostic != "" do return diagnostic
		if diagnostic = semantic_multihop_observe_shortest_path(&campaign, false, 0xD811, semantic_multihop_split(choices[14], false), semantic_multihop_split(choices[15], true)); diagnostic != "" do return diagnostic
		if durable_delete {
			writer.commit_started = {}
			did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != 6 {
				return "multi-hop deletion fsync failed"
			}
		}

		expect_path := !durable_delete
		expected_records := durable_delete ? u64(6) : u64(5)
		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		if !replay_ok ||
		   writer == nil ||
		   floors != (Shard_High_Water_Requirements{task = 2, asset = 1, edge = 2}) ||
		   writer.floors != floors ||
		   writer.wal.record_count != expected_records ||
		   writer.wal.durable_record_count != expected_records {
			return "multi-hop recovery differs from durable prefix"
		}
		if diagnostic = semantic_multihop_check_state(&campaign, expect_path, false); diagnostic != "" do return diagnostic
		if !semantic_multihop_install_clients(&campaign) do return "multi-hop continuation clients failed to install"
		if diagnostic = semantic_multihop_observe_shortest_path(&campaign, expect_path, 0xD812, semantic_multihop_split(choices[15], false), semantic_multihop_split(choices[0], true)); diagnostic != "" do return diagnostic

		update := semantic_multihop_task_two_update()
		if !semantic_transport_persistence_enqueue_update(
			   &campaign,
			   update,
			   semantic_multihop_split(choices[3], false),
			   semantic_multihop_split(choices[12], true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "multi-hop continuation update was not three-way segmented"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if writer.wal.record_count != expected_records + 1 || writer.floors != floors {
			return "multi-hop continuation WAL differs from model"
		}
		if diagnostic = semantic_multihop_check_state(&campaign, expect_path, true); diagnostic != "" do return diagnostic
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != expected_records + 1 {
			return "multi-hop continuation fsync failed"
		}
		floors, replay_ok, crash_diagnostic = semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		if !replay_ok ||
		   writer == nil ||
		   writer.floors != floors ||
		   writer.wal.record_count != expected_records + 1 ||
		   writer.wal.durable_record_count != expected_records + 1 {
			return "multi-hop second recovery differs from continued state"
		}
		if diagnostic = semantic_multihop_check_state(&campaign, expect_path, true); diagnostic != "" do return diagnostic
		if !semantic_multihop_install_clients(&campaign) do return "multi-hop final query clients failed to install"
		if diagnostic = semantic_multihop_observe_shortest_path(&campaign, expect_path, 0xD813, semantic_multihop_split(choices[7], false), semantic_multihop_split(choices[8], true)); diagnostic != "" do return diagnostic
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before ||
		   td.spool.invalid_release_count != campaign.invalid_releases_before {
			return "multi-hop final query did not release pooled ownership"
		}
		return ""
	}

	semantic_dependent_delete_recreate_run :: proc(split_choices, send_choices: []u8) -> string {
		if len(split_choices) < 8 || len(send_choices) < 4 do return "dependent delete/recreate choices are incomplete"
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "dependent-delete-recreate", 1, 7, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "dependent delete/recreate foundation missing"
		diagnostic = semantic_transport_persistence_run_action(&campaign, .Submit_Fsync)
		if diagnostic != "" do return diagnostic
		diagnostic = semantic_transport_persistence_run_action(&campaign, .Run_Fsync)
		if diagnostic != "" do return diagnostic

		update_one := semantic_dependent_history_update(0, 173)
		if !semantic_transport_persistence_enqueue_update(&campaign, update_one, int(split_choices[0]), int(split_choices[1])) {
			return "dependent delete/recreate first update failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 2 ||
		   !semantic_dependent_history_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1), update_one) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent delete/recreate first update differs from model"
		}
		if send_choices[0] & 1 != 0 && nrc_sim_send_completion_count(&campaign.ctx.sim) > 0 {
			ordinal := int(send_choices[0] / 2) % nrc_sim_send_completion_count(&campaign.ctx.sim)
			if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, ordinal) do return "dependent delete/recreate first send was not runnable"
		}

		if !semantic_transport_persistence_enqueue_delete(&campaign, pr.WORKSPACE_DATA_ID, 1, 0xD201, int(split_choices[2]), int(split_choices[3])) {
			return "dependent delete/recreate delete failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 3 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1}) ||
		   td.task_seq != 1 ||
		   conv == nil ||
		   len(conv.tasks) != 0 ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent delete/recreate zero-task state differs from model"
		}
		if send_choices[1] & 1 != 0 && nrc_sim_send_completion_count(&campaign.ctx.sim) > 0 {
			ordinal := int(send_choices[1] / 2) % nrc_sim_send_completion_count(&campaign.ctx.sim)
			if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, ordinal) do return "dependent delete/recreate delete send was not runnable"
		}

		create_two := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("dependent recreated task"),
			description    = transmute([]byte)string("must retain high-water identity"),
			priority       = 6,
			color          = .Green,
			external_ref   = transmute([]byte)string("HISTORY-RECREATE-2"),
			due_at         = NRC_SIM_TIME_EPOCH_NANOS + 600_000_000_000,
			status         = .Todo,
			project        = transmute([]byte)string("history-recreated"),
			correlation_id = 0xD202,
		}
		if !semantic_transport_persistence_enqueue_create(&campaign, create_two, int(split_choices[4]), int(split_choices[5])) {
			return "dependent delete/recreate create failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 4 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 2}) ||
		   td.task_seq != 2 ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1) != nil ||
		   !semantic_dependent_history_created_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2), 2, create_two) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent delete/recreate recreated task differs from model"
		}
		if send_choices[2] & 1 != 0 && nrc_sim_send_completion_count(&campaign.ctx.sim) > 0 {
			ordinal := int(send_choices[2] / 2) % nrc_sim_send_completion_count(&campaign.ctx.sim)
			if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, ordinal) do return "dependent delete/recreate create send was not runnable"
		}

		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != 4 {
			return "dependent delete/recreate prefix fsync submission failed"
		}
		update_two := semantic_dependent_history_update(1, 251)
		update_two.task_id = 2
		if !semantic_transport_persistence_enqueue_update(&campaign, update_two, int(split_choices[6]), int(split_choices[7])) {
			return "dependent delete/recreate final update failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 5 ||
		   writer.wal.durable_record_count != 1 ||
		   writer.fsync_snapshot.record_count != 4 ||
		   !semantic_dependent_history_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2), update_two) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent delete/recreate final live update differs from model"
		}
		if send_choices[3] & 1 != 0 && nrc_sim_send_completion_count(&campaign.ctx.sim) > 0 {
			ordinal := int(send_choices[3] / 2) % nrc_sim_send_completion_count(&campaign.ctx.sim)
			if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, ordinal) do return "dependent delete/recreate final send was not runnable"
		}
		if !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) ||
		   writer.wal.durable_record_count != 4 ||
		   writer.wal.record_count != 5 ||
		   writer.wal.pending_bytes == 0 ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) == 0 {
			return "dependent delete/recreate did not retain final live suffix"
		}

		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if !replay_ok ||
		   writer == nil ||
		   writer.wal.record_count != 4 ||
		   writer.wal.durable_record_count != 4 ||
		   floors != (Shard_High_Water_Requirements{task = 2}) ||
		   writer.floors != floors ||
		   td.task_seq != 2 ||
		   td.asset_seq != 0 ||
		   td.edge_seq != 0 ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1) != nil ||
		   !semantic_dependent_history_created_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2), 2, create_two) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent delete/recreate recovery differs from captured recreated task"
		}
		return semantic_global_compaction_check_cascade_entities(&campaign, false)
	}

	semantic_dependent_cascade_optional_send :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, choice: u8, operation: string) -> string {
		completion_count := nrc_sim_send_completion_count(&campaign.ctx.sim)
		if choice & 1 == 0 || completion_count == 0 do return ""
		ordinal := int(choice / 2) % completion_count
		if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, ordinal) {
			return fmt.tprintf("dependent cascade %s send was not runnable", operation)
		}
		return ""
	}

	semantic_dependent_cascade_asset_only_check :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> string {
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if conv == nil ||
		   len(conv.assets) != 1 ||
		   len(conv.edges) != 0 ||
		   len(conv.edges_by_entity) != 0 ||
		   len(conv.note_index_keys) != 0 ||
		   len(conv.note_project_assets) != 0 ||
		   len(conv.note_tag_assets) != 0 ||
		   btree.count(&conv.note_index) != 0 ||
		   !semantic_global_compaction_asset_exact(conv.assets[1]) {
			return "dependent cascade asset-only state differs from exact model"
		}
		return ""
	}

	semantic_dependent_cascade_run :: proc(durable_cascade: bool, split_choices, send_choices: []u8) -> string {
		if len(split_choices) < 10 || len(send_choices) < 5 do return "dependent cascade choices are incomplete"
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "dependent-cascade", 1, 7, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "dependent cascade foundation missing"
		diagnostic = semantic_transport_persistence_run_action(&campaign, .Submit_Fsync)
		if diagnostic != "" do return diagnostic
		diagnostic = semantic_transport_persistence_run_action(&campaign, .Run_Fsync)
		if diagnostic != "" do return diagnostic

		payload := "owned cascade"
		asset_req := pr.CreateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_type       = .Document,
			parent_type      = .Task,
			parent_id        = 1,
			payload_encoding = .Plain,
			payload_raw_len  = u32(len(payload)),
			preview          = transmute([]byte)payload,
			payload          = transmute([]byte)payload,
			correlation_id   = 0xD501,
		}
		if !semantic_transport_persistence_enqueue_create_asset(&campaign, asset_req, int(split_choices[0]), int(split_choices[1])) {
			return "dependent cascade asset failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 2 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1, asset = 1}) ||
		   td.task_seq != 1 ||
		   td.asset_seq != 1 ||
		   td.edge_seq != 0 ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   !semantic_transport_persistence_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent cascade asset creation differs from model"
		}
		if diagnostic = semantic_dependent_cascade_asset_only_check(&campaign); diagnostic != "" do return diagnostic
		if diagnostic = semantic_dependent_cascade_optional_send(&campaign, send_choices[0], "asset"); diagnostic != "" do return diagnostic

		edge_req := pr.CreateEdgeRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			source_type    = .Task,
			source_id      = 1,
			target_type    = .Asset,
			target_id      = 1,
			relation       = .References,
			correlation_id = 0xD502,
		}
		if !semantic_transport_persistence_enqueue_create_edge(&campaign, edge_req, int(split_choices[2]), int(split_choices[3])) {
			return "dependent cascade edge failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if writer.wal.record_count != 3 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1, asset = 1, edge = 1}) ||
		   td.task_seq != 1 ||
		   td.asset_seq != 1 ||
		   td.edge_seq != 1 {
			return "dependent cascade edge creation differs from model"
		}
		if diagnostic = semantic_global_compaction_check_cascade_entities(&campaign, true); diagnostic != "" do return diagnostic
		if diagnostic = semantic_dependent_cascade_optional_send(&campaign, send_choices[1], "edge"); diagnostic != "" do return diagnostic
		if !durable_cascade {
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != 3 {
				return "dependent cascade graph prefix fsync submission failed"
			}
		}

		update_req := semantic_dependent_history_update(0, 173)
		if !semantic_transport_persistence_enqueue_update(&campaign, update_req, int(split_choices[4]), int(split_choices[5])) {
			return "dependent cascade update failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 4 ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   !semantic_dependent_history_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1), update_req) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent cascade update differs from model"
		}
		if diagnostic = semantic_global_compaction_check_cascade_entities(&campaign, true); diagnostic != "" do return diagnostic
		if diagnostic = semantic_dependent_cascade_optional_send(&campaign, send_choices[2], "update"); diagnostic != "" do return diagnostic

		if !semantic_transport_persistence_enqueue_delete(&campaign, pr.WORKSPACE_DATA_ID, 1, 0xD503, int(split_choices[6]), int(split_choices[7])) {
			return "dependent cascade delete failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 5 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1, asset = 1, edge = 1}) ||
		   conv == nil ||
		   len(conv.tasks) != 0 ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent cascade atomic deletion differs from model"
		}
		if diagnostic = semantic_global_compaction_check_cascade_entities(&campaign, false); diagnostic != "" do return diagnostic
		if diagnostic = semantic_dependent_cascade_optional_send(&campaign, send_choices[3], "delete"); diagnostic != "" do return diagnostic
		if durable_cascade {
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != 5 {
				return "dependent cascade deletion prefix fsync submission failed"
			}
		}

		create_two := semantic_dependent_history_create(5, 211)
		if !semantic_transport_persistence_enqueue_create(&campaign, create_two, int(split_choices[8]), int(split_choices[9])) {
			return "dependent cascade recreation failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer.wal.record_count != 6 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 2, asset = 1, edge = 1}) ||
		   td.task_seq != 2 ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   !semantic_dependent_history_created_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2), 2, create_two) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent cascade speculative recreation differs from model"
		}
		if diagnostic = semantic_global_compaction_check_cascade_entities(&campaign, false); diagnostic != "" do return diagnostic
		if diagnostic = semantic_dependent_cascade_optional_send(&campaign, send_choices[4], "recreation"); diagnostic != "" do return diagnostic

		expected_records := durable_cascade ? u64(5) : u64(3)
		if !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) ||
		   writer.wal.durable_record_count != expected_records ||
		   writer.wal.record_count != 6 ||
		   writer.wal.pending_bytes == 0 ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) == 0 {
			return "dependent cascade did not retain the expected live suffix"
		}

		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		expected_floors := Shard_High_Water_Requirements {
			task  = 1,
			asset = 1,
			edge  = 1,
		}
		expected_tasks := durable_cascade ? 0 : 1
		if !replay_ok ||
		   writer == nil ||
		   writer.wal.record_count != expected_records ||
		   writer.wal.durable_record_count != expected_records ||
		   floors != expected_floors ||
		   writer.floors != floors ||
		   td.task_seq != 1 ||
		   td.asset_seq != 1 ||
		   td.edge_seq != 1 ||
		   conv == nil ||
		   len(conv.tasks) != expected_tasks ||
		   get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2) != nil ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "dependent cascade recovery differs from captured prefix"
		}
		if durable_cascade {
			return semantic_global_compaction_check_cascade_entities(&campaign, false)
		}
		if !semantic_transport_persistence_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) {
			return "dependent cascade graph-prefix recovery lost original task"
		}
		return semantic_global_compaction_check_cascade_entities(&campaign, true)
	}

	semantic_dependent_history_crash_reopen :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		models: []Semantic_Dependent_Task_Model,
		durable_records: u64,
		continuation_variant: u8,
		split_a, split_b: int,
		send_choice: u8,
	) -> string {
		if durable_records < 1 || durable_records > u64(len(models)) do return "dependent history durable prefix out of range"
		expected := models[int(durable_records - 1)]
		floors, replay_ok, diagnostic := semantic_transport_persistence_virtual_crash_reopen(campaign)
		if diagnostic != "" do return diagnostic
		writer := semantic_transport_persistence_writer(campaign)
		expected_floors := Shard_High_Water_Requirements {
			task  = expected.task_floor,
			asset = expected.asset_floor,
			edge  = expected.edge_floor,
		}
		if !replay_ok ||
		   writer == nil ||
		   floors != expected_floors ||
		   writer.floors != floors ||
		   writer.wal.record_count != durable_records ||
		   writer.wal.durable_record_count != durable_records ||
		   td.task_seq != expected.task_floor ||
		   td.asset_seq != expected.asset_floor ||
		   td.edge_seq != expected.edge_floor {
			return fmt.tprintf(
				"dependent history recovery differs from durable prefix: durable=%d floors=%v records=%d/%d",
				durable_records,
				floors,
				writer != nil ? writer.wal.record_count : 0,
				writer != nil ? writer.wal.durable_record_count : 0,
			)
		}
		if model_diagnostic := semantic_dependent_history_model_check(campaign, expected); model_diagnostic != "" {
			return fmt.tprintf("dependent history recovered record %d: %s", durable_records, model_diagnostic)
		}

		campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "requester", init_send_queue = true)
		campaign.ctx.conns[1] = campaign.requester
		campaign.peer = simulation_test_install_client(&campaign.ctx.sim, 2, campaign.workspace, "peer", init_send_queue = true)
		campaign.ctx.conns[2] = campaign.peer
		if campaign.requester == nil || campaign.peer == nil do return "dependent history continuation clients failed to install"
		subscribe_to_conversation(campaign.requester, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.requester, 77)
		subscribe_to_conversation(campaign.peer, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.peer, 77)
		nrc_sim_clear_inboxes(&campaign.ctx.sim)

		continued := expected
		enqueued := false
		if continued.asset_live {
			enqueued = semantic_transport_persistence_enqueue_delete(campaign, pr.WORKSPACE_DATA_ID, continued.task_id, 0xD600, split_a, split_b)
			continued.kind = .Deleted
			continued.live = false
			continued.asset_live = false
			continued.edge_live = false
			continued.create_req = {}
			continued.update_req = {}
		} else if !continued.live {
			req := semantic_dependent_history_create(7, continuation_variant)
			enqueued = semantic_transport_persistence_enqueue_create(campaign, req, split_a, split_b)
			continued.kind = .Created
			continued.live = true
			continued.task_floor += 1
			continued.task_id = pr.TaskID(continued.task_floor)
			continued.create_req = req
			continued.update_req = {}
		} else {
			req := semantic_dependent_history_update(7, continuation_variant)
			req.task_id = continued.task_id
			enqueued = semantic_transport_persistence_enqueue_update(campaign, req, split_a, split_b)
			continued.kind = .Updated
			continued.create_req = {}
			continued.update_req = req
		}
		if !enqueued do return "dependent history continuation failed to enqueue"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		continued_records := durable_records + 1
		expected_continued_floors := Shard_High_Water_Requirements {
			task  = continued.task_floor,
			asset = continued.asset_floor,
			edge  = continued.edge_floor,
		}
		if writer.wal.record_count != continued_records || writer.floors != expected_continued_floors {
			return "dependent history continuation WAL differs from model"
		}
		if model_diagnostic := semantic_dependent_history_model_check(campaign, continued); model_diagnostic != "" {
			return fmt.tprintf("dependent history continuation: %s", model_diagnostic)
		}
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok ||
		   !did_work ||
		   !writer.fsync_in_flight ||
		   writer.fsync_snapshot.record_count != continued_records ||
		   !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) ||
		   writer.wal.durable_record_count != continued_records {
			return "dependent history continuation fsync failed"
		}

		completion_count := nrc_sim_send_completion_count(&campaign.ctx.sim)
		if completion_count == 0 do return "dependent history continuation produced no pending sends"
		if send_choice & 1 != 0 {
			ordinal := int(send_choice / 2) % completion_count
			if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, ordinal) do return "dependent history continuation send was not runnable"
		}
		if nrc_sim_send_completion_count(&campaign.ctx.sim) == 0 do return "dependent history continuation did not retain a pending send"

		floors, replay_ok, diagnostic = semantic_transport_persistence_virtual_crash_reopen(campaign)
		if diagnostic != "" do return diagnostic
		writer = semantic_transport_persistence_writer(campaign)
		if !replay_ok ||
		   writer == nil ||
		   floors != expected_continued_floors ||
		   writer.floors != floors ||
		   writer.wal.record_count != continued_records ||
		   writer.wal.durable_record_count != continued_records {
			return "dependent history second recovery differs from continued durable model"
		}
		if model_diagnostic := semantic_dependent_history_model_check(campaign, continued); model_diagnostic != "" {
			return fmt.tprintf("dependent history second recovery: %s", model_diagnostic)
		}
		return ""
	}

	semantic_dependent_history_run :: proc(op_count: int, variants, split_as, split_bs, send_choices, fsync_choices: []u8) -> string {
		if op_count < 4 ||
		   op_count > 8 ||
		   len(variants) < op_count ||
		   len(split_as) < op_count ||
		   len(split_bs) < op_count ||
		   len(send_choices) < op_count ||
		   len(fsync_choices) < op_count {
			return "dependent history choices are incomplete"
		}
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "dependent-history", 1, 7, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "dependent history foundation missing"
		diagnostic = semantic_transport_persistence_run_action(&campaign, .Submit_Fsync)
		if diagnostic != "" do return diagnostic
		if writer.fsync_snapshot.record_count != 1 do return "dependent history foundation fsync captured wrong prefix"
		models: [9]Semantic_Dependent_Task_Model
		model := Semantic_Dependent_Task_Model {
			kind       = .Original,
			live       = true,
			task_id    = 1,
			task_floor = 1,
		}
		models[0] = model
		durable_records: u64
		inflight_snapshot_records := u64(1)
		fsync_completions := 0

		for index in 0 ..< op_count {
			if !semantic_dependent_history_enqueue(&campaign, &model, index, variants[index], int(split_as[index]), int(split_bs[index])) {
				return fmt.tprintf("dependent history operation %d failed to enqueue", index)
			}
			nrc_sim_run_all_receives(&campaign.ctx.sim)
			models[index + 1] = model
			if writer.wal.record_count != u64(index + 2) ||
			   writer.wal.durable_record_count != durable_records ||
			   (writer.fsync_in_flight && writer.fsync_snapshot.record_count != inflight_snapshot_records) ||
			   writer.floors != (Shard_High_Water_Requirements{task = model.task_floor, asset = model.asset_floor, edge = model.edge_floor}) {
				return fmt.tprintf("dependent history operation %d diverged from live model", index)
			}
			if model_diagnostic := semantic_dependent_history_model_check(&campaign, model); model_diagnostic != "" {
				return fmt.tprintf("dependent history operation %d: %s", index, model_diagnostic)
			}
			if observer_diagnostic := semantic_dependent_history_observe_graph(
				&campaign,
				model,
				variants[index],
				int(split_bs[index]),
				int(split_as[index] ~ variants[index]),
				index,
			); observer_diagnostic != "" {
				return fmt.tprintf("dependent history operation %d: %s", index, observer_diagnostic)
			}
			completion_count := nrc_sim_send_completion_count(&campaign.ctx.sim)
			if send_choices[index] & 1 != 0 && completion_count > 0 {
				ordinal := int(send_choices[index] / 2) % completion_count
				if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, ordinal) {
					return fmt.tprintf("dependent history operation %d send choice was not runnable", index)
				}
			}
			if index < op_count - 1 && writer.fsync_in_flight && fsync_completions < 3 && (index == 0 || fsync_choices[index] & 1 != 0) {
				if !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {
					return fmt.tprintf("dependent history operation %d fsync completion was not runnable", index)
				}
				durable_records = inflight_snapshot_records
				fsync_completions += 1
				if writer.wal.durable_record_count != durable_records {
					return fmt.tprintf("dependent history operation %d completed wrong durable prefix", index)
				}
			}
			if index < op_count - 1 && !writer.fsync_in_flight && fsync_completions < 3 && (index == 0 || fsync_choices[index] & 2 != 0) {
				writer.commit_started = {}
				did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
				if !sync_ok || !did_work || !writer.fsync_in_flight {
					return fmt.tprintf("dependent history operation %d next fsync submission failed", index)
				}
				inflight_snapshot_records = writer.fsync_snapshot.record_count
				if inflight_snapshot_records != writer.wal.record_count {
					return fmt.tprintf("dependent history operation %d next fsync captured wrong prefix", index)
				}
			}
		}
		if fsync_completions < 1 ||
		   fsync_completions > 3 ||
		   durable_records < 1 ||
		   durable_records >= writer.wal.record_count ||
		   writer.wal.durable_record_count != durable_records ||
		   writer.wal.record_count != u64(op_count + 1) ||
		   writer.wal.pending_bytes == 0 ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) + send_queue_len(campaign.requester) + send_queue_len(campaign.peer) == 0 {
			return "dependent history did not retain live suffix and pending sends after selected fsync prefixes"
		}
		last := op_count - 1
		return semantic_dependent_history_crash_reopen(
			&campaign,
			models[:op_count + 1],
			durable_records,
			variants[last],
			int(split_as[last]),
			int(split_bs[last]),
			send_choices[last],
		)
	}

	semantic_update_campaign_actions :: proc(campaign: ^Semantic_Update_Campaign, actions: ^[4]Semantic_Update_Action) -> int {
		count := 0
		if semantic_transport_persistence_send_completion_index(&campaign.base, campaign.base.requester) >= 0 {
			actions[count] = .Run_Requester_Send
			count += 1
		}
		if semantic_transport_persistence_send_completion_index(&campaign.base, campaign.base.peer) >= 0 {
			actions[count] = .Run_Peer_Send
			count += 1
		}
		if nrc_sim_fsync_completion_count(&campaign.base.ctx.sim) > 0 {
			actions[count] = .Run_Fsync
			count += 1
		}
		if campaign.fsync_completions == 1 && !campaign.second_fsync_submitted {
			actions[count] = .Submit_Second_Fsync
			count += 1
		}
		return count
	}

	semantic_update_campaign_run_action :: proc(campaign: ^Semantic_Update_Campaign, action: Semantic_Update_Action) -> string {
		switch action {
		case .Run_Requester_Send:
			index := semantic_transport_persistence_send_completion_index(&campaign.base, campaign.base.requester)
			if campaign.requester_send_completions >= 2 || !nrc_sim_run_send_completion_at(&campaign.base.ctx.sim, index) {
				return "dependent requester send was not runnable"
			}
			campaign.requester_send_completions += 1
		case .Run_Peer_Send:
			index := semantic_transport_persistence_send_completion_index(&campaign.base, campaign.base.peer)
			if campaign.peer_send_completions >= 2 || !nrc_sim_run_send_completion_at(&campaign.base.ctx.sim, index) {
				return "dependent peer send was not runnable"
			}
			campaign.peer_send_completions += 1
		case .Run_Fsync:
			if campaign.fsync_completions >= 2 || !nrc_sim_run_next_fsync_completion(&campaign.base.ctx.sim) {
				return "dependent fsync completion was not runnable"
			}
			campaign.fsync_completions += 1
		case .Submit_Second_Fsync:
			if campaign.fsync_completions != 1 || campaign.second_fsync_submitted do return "second dependent fsync was not runnable"
			writer := semantic_transport_persistence_writer(&campaign.base)
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work do return "submit second dependent fsync"
			campaign.second_fsync_submitted = true
		}
		return semantic_update_campaign_check(campaign)
	}

	semantic_update_campaign_check_frames :: proc(campaign: ^Semantic_Update_Campaign) -> string {
		base := &campaign.base
		if campaign.requester_send_completions != 2 || campaign.peer_send_completions != 2 {
			return "dependent update frames checked before send drain"
		}
		responses := [?]struct {
			conn:           ^NRC_Connection,
			correlation_id: u32,
		}{{conn = base.requester, correlation_id = 0xD00D}, {conn = base.peer, correlation_id = 0}}
		for response in responses {
			frame := nrc_sim_client_frame(&base.ctx.sim, response.conn.sock, 1)
			payload, payload_ok := nrc_sim_frame_protocol_payload(frame)
			attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			event, parse_err := pr.parseTaskUpdated(payload, attachments[:])
			if !payload_ok ||
			   parse_err != nil ||
			   event.correlation_id != response.correlation_id ||
			   !semantic_transport_persistence_updated_task_exact(&event.task) {
				return "dependent task-updated response semantics mismatch"
			}
			expected_payload: [1_024]byte
			expected_len := pr.serializeTaskUpdated(event, expected_payload[:])
			if expected_len <= 0 do return "serialize expected dependent task update"
			expected_frame := make_test_ws_frame(expected_payload[:expected_len], .opBinary, true, false)
			if !bytes.equal(frame, expected_frame) {
				delete(expected_frame)
				return "dependent task-updated WebSocket frame bytes mismatch"
			}
			delete(expected_frame)
		}
		if connection_lifetime_pool_live_alloc_count(td.spool) != base.pool_live_before || td.spool.invalid_release_count != base.invalid_releases_before {
			return "dependent create/update sends did not release pooled ownership"
		}
		return ""
	}

	semantic_update_campaign_restart :: proc(campaign: ^Semantic_Update_Campaign) -> string {
		base := &campaign.base
		writer := semantic_transport_persistence_writer(base)
		if writer == nil ||
		   campaign.fsync_completions != 2 ||
		   writer.fsync_in_flight ||
		   writer.wal.durable_record_count != 2 ||
		   writer.wal.pending_bytes != 0 {
			return "dependent update restart attempted before both fsyncs"
		}
		if diagnostic := semantic_update_campaign_check_frames(campaign); diagnostic != "" do return diagnostic
		semantic_transport_persistence_uninstall_client(base, 1)
		semantic_transport_persistence_uninstall_client(base, 2)
		base.requester = nil
		base.peer = nil
		if !shutdown_shard_writer_registry(&td.shard_writers) do return "shutdown dependent update writer"
		base.registry_started = false
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
		if !semantic_transport_persistence_init_writer(base) do return "reopen dependent update writer"
		writer = semantic_transport_persistence_writer(base)
		floors, replay_ok := replay_shard_compaction_sequence(writer.shard_dir, writer.manifest, true, false)
		td.task_seq = floors.task
		td.asset_seq = floors.asset
		td.edge_seq = floors.edge
		conv := get_conversation(get_workspace(base.workspace), pr.WORKSPACE_DATA_ID)
		if !replay_ok ||
		   floors != (Shard_High_Water_Requirements{task = 1}) ||
		   writer.floors != floors ||
		   writer.wal.record_count != 2 ||
		   writer.wal.durable_record_count != 2 ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   !semantic_transport_persistence_updated_task_exact(get_task(base.workspace, pr.WORKSPACE_DATA_ID, 1)) ||
		   td.task_seq != 1 ||
		   td.asset_seq != 0 ||
		   td.edge_seq != 0 {
			return "dependent update did not replay exact final state"
		}
		return ""
	}

	semantic_update_campaign_run_fixed :: proc(name: string, prefix: []Semantic_Update_Action) -> string {
		campaign: Semantic_Update_Campaign
		diagnostic := semantic_update_campaign_begin(&campaign, name, 2, 11)
		defer semantic_transport_persistence_campaign_end(&campaign.base)
		if diagnostic != "" do return diagnostic
		for action in prefix {
			diagnostic = semantic_update_campaign_run_action(&campaign, action)
			if diagnostic != "" do return diagnostic
		}
		actions: [4]Semantic_Update_Action
		for {
			count := semantic_update_campaign_actions(&campaign, &actions)
			if count == 0 do break
			diagnostic = semantic_update_campaign_run_action(&campaign, actions[0])
			if diagnostic != "" do return diagnostic
		}
		return semantic_update_campaign_restart(&campaign)
	}

	semantic_transport_persistence_run_compaction_publication :: proc() -> string {
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "compaction-publication", 1, 7, thread_index = 0, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic

		for nrc_sim_receive_event_count(&campaign.ctx.sim) > 0 {
			diagnostic = semantic_transport_persistence_run_action(&campaign, .Run_Receive)
			if diagnostic != "" do return diagnostic
		}
		first_actions := [?]Semantic_Transport_Persistence_Action{.Submit_Fsync, .Run_Fsync, .Run_Requester_Send, .Run_Peer_Send}
		for action in first_actions {
			diagnostic = semantic_transport_persistence_run_action(&campaign, action)
			if diagnostic != "" do return diagnostic
		}

		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.owner_worker != 0 do return "semantic writer owner mismatch"
		if writer.floors != (Shard_High_Water_Requirements{task = 1}) ||
		   !rotate_shard_writer_for_compaction(writer) ||
		   !rotate_shard_writer_for_compaction(writer) {
			return "rotate durable semantic task into cleaner catalog"
		}
		if writer.compaction != .Idle ||
		   writer.manifest.sealed_present ||
		   writer.catalog_floors != (Shard_High_Water_Requirements{task = 1}) ||
		   writer.catalog_segments != 2 ||
		   writer.wal.record_count != 0 ||
		   !enqueue_shard_compaction_job_event(&campaign.ctx.sim.world, writer) ||
		   writer.compaction != .Building ||
		   sim_world_event_count(&campaign.ctx.sim.world, .Compaction_Job) != 1 {
			return "transfer sealed semantic task to compaction job"
		}

		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		second := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("active during compaction"),
			description    = transmute([]byte)string("must remain in the active WAL"),
			priority       = 5,
			status         = .Todo,
			correlation_id = 0xBEEF,
			project        = transmute([]byte)string("simulation"),
		}
		if !semantic_transport_persistence_enqueue_create(&campaign, second, 2, 11) do return "enqueue active-WAL semantic mutation"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		active_task := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if !semantic_transport_persistence_active_task_exact(active_task) ||
		   conv == nil ||
		   len(conv.tasks) != 2 ||
		   td.task_seq != 2 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 2}) ||
		   writer.compaction_floors != (Shard_High_Water_Requirements{task = 1}) ||
		   writer.wal.record_count != 1 ||
		   writer.wal.durable_record_count != 0 ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) != 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 {
			return "active-WAL semantic mutation crossed the sealed checkpoint boundary"
		}

		responses := [?]struct {
			conn:           ^NRC_Connection,
			correlation_id: u32,
		}{{conn = campaign.requester, correlation_id = 0xBEEF}, {conn = campaign.peer, correlation_id = 0}}
		for response in responses {
			payload, payload_ok := semantic_transport_persistence_pending_payload(response.conn, .S_TaskCreated)
			attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			event, parse_err := pr.parseTaskCreated(payload, attachments[:])
			if !payload_ok ||
			   parse_err != nil ||
			   event.correlation_id != response.correlation_id ||
			   !semantic_transport_persistence_active_task_exact(&event.task) {
				return "active-WAL task response semantics mismatch"
			}
		}

		if !sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Job)) ||
		   sim_world_event_count(&campaign.ctx.sim.world, .Compaction_Job) != 0 ||
		   sim_world_event_count(&campaign.ctx.sim.world, .Compaction_Result) != 1 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 2}) {
			return "semantic checkpoint included the post-rotation active mutation"
		}

		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 1 {
			return "submit active-WAL semantic fsync"
		}
		if !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.fsync_in_flight || writer.wal.durable_record_count != 1 {
			return "complete active-WAL semantic fsync"
		}
		response_connections := [?]^NRC_Connection{campaign.requester, campaign.peer}
		for conn in response_connections {
			index := semantic_transport_persistence_send_completion_index(&campaign, conn)
			if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, index) do return "complete active-WAL semantic send"
		}
		if nrc_sim_send_completion_count(&campaign.ctx.sim) != 0 ||
		   campaign.requester.pending_io != 0 ||
		   campaign.peer.pending_io != 0 ||
		   connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before ||
		   td.spool.invalid_release_count != campaign.invalid_releases_before {
			return "active-WAL semantic sends retained ownership"
		}
		processed := sim_world_run_runnable_rank(&campaign.ctx.sim.world, 0, Maybe(Sim_Event_Domain)(.Compaction_Result))
		if !processed ||
		   sim_world_event_count(&campaign.ctx.sim.world, .Compaction_Result) != 0 ||
		   writer.compaction != .Idle ||
		   writer.manifest.sealed_present ||
		   !writer.manifest.checkpoint_present ||
		   writer.floors != (Shard_High_Water_Requirements{task = 2}) ||
		   writer.compaction_floors != {} {
			return fmt.tprintf(
				"publish semantic checkpoint without preserving active floor: processed=%v compaction=%v sealed=%v checkpoint=%v floors=%v compaction_floors=%v closing=%v fatal=%v",
				processed,
				writer.compaction,
				writer.manifest.sealed_present,
				writer.manifest.checkpoint_present,
				writer.floors,
				writer.compaction_floors,
				sync.atomic_load(&campaign.server.closing),
				sync.atomic_load(&campaign.server.fatal_storage_error),
			)
		}
		record_count: u64
		replayed_floors, records_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, false, false, &record_count)
		// The selected empty raw generation is removed without an output;
		// the older raw WAL carries task 1 and the active WAL carries task 2.
		if !records_ok || replayed_floors != (Shard_High_Water_Requirements{task = 2}) || record_count != 2 {
			return "published semantic checkpoint/active record boundary mismatch"
		}

		semantic_transport_persistence_uninstall_client(&campaign, 1)
		semantic_transport_persistence_uninstall_client(&campaign, 2)
		campaign.requester = nil
		campaign.peer = nil
		if !shutdown_shard_writer_registry(&td.shard_writers) do return "shutdown published semantic writer"
		campaign.registry_started = false
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
		if !semantic_transport_persistence_init_writer(&campaign) do return "reopen published semantic writer"
		writer = semantic_transport_persistence_writer(&campaign)
		floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
		td.task_seq = floors.task
		td.asset_seq = floors.asset
		td.edge_seq = floors.edge
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if !replay_ok ||
		   floors != (Shard_High_Water_Requirements{task = 2}) ||
		   writer.floors != floors ||
		   td.task_seq != 2 ||
		   td.asset_seq != 0 ||
		   td.edge_seq != 0 ||
		   !writer.manifest.checkpoint_present ||
		   writer.manifest.sealed_present ||
		   conv == nil ||
		   len(conv.tasks) != 2 ||
		   !semantic_transport_persistence_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) ||
		   !semantic_transport_persistence_active_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)) {
			return "published semantic checkpoint and active WAL did not replay exactly"
		}
		return ""
	}

	semantic_global_compaction_prior_task_count :: proc(mutation: Semantic_Global_Compaction_Mutation, active_durable: bool) -> int {
		if !active_durable do return 1
		switch mutation {
		case .Create_Task:
			return 2
		case .Delete_Task:
			return 0
		case .Delete_Task_Cascade:
			return 0
		case .Update_Task:
			return 1
		}
		return 1
	}

	semantic_global_compaction_prior_task_floor :: proc(mutation: Semantic_Global_Compaction_Mutation, active_durable: bool) -> u64 {
		return mutation == .Create_Task && active_durable ? 2 : 1
	}

	semantic_global_compaction_prior_floors :: proc(mutation: Semantic_Global_Compaction_Mutation, active_durable: bool) -> Shard_High_Water_Requirements {
		floors := Shard_High_Water_Requirements {
			task = semantic_global_compaction_prior_task_floor(mutation, active_durable),
		}
		if mutation == .Delete_Task_Cascade {
			floors.asset = 1
			floors.edge = 1
		}
		return floors
	}

	semantic_global_compaction_prior_active_count :: proc(mutation: Semantic_Global_Compaction_Mutation, active_durable: bool) -> int {
		if active_durable && (mutation == .Update_Task || mutation == .Delete_Task || mutation == .Delete_Task_Cascade) do return 0
		return semantic_global_compaction_prior_task_count(mutation, active_durable)
	}

	semantic_global_compaction_check_cascade_entities :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, expect_fixture: bool) -> string {
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if conv == nil do return "global compaction cascade conversation missing"
		if !expect_fixture {
			if len(conv.assets) != 0 ||
			   len(conv.edges) != 0 ||
			   len(conv.edges_by_entity) != 0 ||
			   len(conv.note_index_keys) != 0 ||
			   len(conv.note_project_assets) != 0 ||
			   len(conv.note_tag_assets) != 0 ||
			   btree.count(&conv.note_index) != 0 {
				return "global compaction removed cascade remains reachable"
			}
			return ""
		}
		task_adjacency := conv.edges_by_entity[Edge_Entity_Key{target_type = .Task, target_id = 1}]
		asset_adjacency := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}]
		if len(conv.assets) != 1 ||
		   len(conv.edges) != 1 ||
		   len(conv.edges_by_entity) != 2 ||
		   len(conv.note_index_keys) != 0 ||
		   len(conv.note_project_assets) != 0 ||
		   len(conv.note_tag_assets) != 0 ||
		   btree.count(&conv.note_index) != 0 ||
		   !semantic_global_compaction_asset_exact(conv.assets[1]) ||
		   !semantic_global_compaction_edge_exact(conv.edges[1]) ||
		   len(task_adjacency) != 1 ||
		   task_adjacency[0] != 1 ||
		   len(asset_adjacency) != 1 ||
		   asset_adjacency[0] != 1 {
			return "global compaction cascade fixture differs from exact model"
		}
		return ""
	}

	semantic_global_compaction_setup_cascade :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil || writer.wal.record_count != 1 do return "global compaction cascade setup task missing"
		payload := "owned cascade"
		handle_create_asset(
			campaign.requester,
			pr.CreateAssetRequest {
				conv_id = pr.WORKSPACE_DATA_ID,
				asset_type = .Document,
				parent_type = .Task,
				parent_id = 1,
				payload_encoding = .Plain,
				payload_raw_len = u32(len(payload)),
				preview = transmute([]byte)payload,
				payload = transmute([]byte)payload,
				correlation_id = 0xA551,
			},
		)
		handle_create_edge(
			campaign.requester,
			pr.CreateEdgeRequest {
				conv_id = pr.WORKSPACE_DATA_ID,
				source_type = .Task,
				source_id = 1,
				target_type = .Asset,
				target_id = 1,
				relation = .References,
				correlation_id = 0xED61,
			},
		)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		for deferred_outbox_pump_count() > 0 {
			if !drain_deferred_outbox_pumps() do return "global compaction cascade setup outbox drain failed"
			nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		}
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		if writer.wal.record_count != 3 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1, asset = 1, edge = 1}) ||
		   td.task_seq != 1 ||
		   td.asset_seq != 1 ||
		   td.edge_seq != 1 {
			return "global compaction cascade setup WAL/floors mismatch"
		}
		return semantic_global_compaction_check_cascade_entities(campaign, true)
	}

	semantic_global_compaction_check_live_mutation :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		mutation: Semantic_Global_Compaction_Mutation,
		active_durable: bool,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		expected_durable_records := active_durable ? u64(1) : u64(0)
		if writer == nil || writer.wal.record_count != 1 || writer.wal.durable_record_count != expected_durable_records || conv == nil {
			return "global compaction live mutation WAL/state boundary mismatch"
		}
		switch mutation {
		case .Create_Task:
			if writer.floors != (Shard_High_Water_Requirements{task = 2}) ||
			   td.task_seq != 2 ||
			   len(conv.tasks) != 2 ||
			   !semantic_transport_persistence_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) ||
			   !semantic_transport_persistence_active_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)) {
				return "global compaction live create differs from exact model"
			}
		case .Update_Task:
			if writer.floors != (Shard_High_Water_Requirements{task = 1}) ||
			   td.task_seq != 1 ||
			   len(conv.tasks) != 1 ||
			   !semantic_transport_persistence_updated_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) ||
			   get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2) != nil {
				return "global compaction live update differs from exact model"
			}
		case .Delete_Task:
			if writer.floors != (Shard_High_Water_Requirements{task = 1}) ||
			   td.task_seq != 1 ||
			   len(conv.tasks) != 0 ||
			   len(conv.task_index_keys) != 0 ||
			   btree.count(&conv.task_index) != 0 ||
			   get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1) != nil {
				return "global compaction live delete differs from exact model"
			}
		case .Delete_Task_Cascade:
			if writer.floors != (Shard_High_Water_Requirements{task = 1, asset = 1, edge = 1}) ||
			   td.task_seq != 1 ||
			   len(conv.tasks) != 0 ||
			   len(conv.task_index_keys) != 0 ||
			   btree.count(&conv.task_index) != 0 ||
			   get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1) != nil {
				return "global compaction live cascade delete differs from exact model"
			}
		}
		expected_related_floor := mutation == .Delete_Task_Cascade ? u64(1) : u64(0)
		if td.asset_seq != expected_related_floor || td.edge_seq != expected_related_floor {
			return "global compaction live mutation advanced unrelated sequences"
		}
		return semantic_global_compaction_check_cascade_entities(campaign, false)
	}

	semantic_global_compaction_task_indexes_exact :: proc(conv: ^Conversation_State) -> bool {
		if conv == nil || len(conv.task_index_keys) != len(conv.tasks) || btree.count(&conv.task_index) != len(conv.tasks) {
			return false
		}
		for task_id, task in conv.tasks {
			key, indexed := conv.task_index_keys[task_id]
			expected := make_task_sort_key(task)
			if !indexed || key != expected || !btree.contains(&conv.task_index, expected) do return false
		}
		return true
	}

	semantic_global_compaction_check_state :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		mutation: Semantic_Global_Compaction_Mutation,
		active_durable: bool,
	) -> string {
		expected_tasks := semantic_global_compaction_prior_task_count(mutation, active_durable)
		expected_floors := semantic_global_compaction_prior_floors(mutation, active_durable)
		writer := semantic_transport_persistence_writer(campaign)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer == nil ||
		   expected_tasks < 0 ||
		   expected_tasks > 2 ||
		   writer.floors != expected_floors ||
		   td.task_seq != expected_floors.task ||
		   td.asset_seq != expected_floors.asset ||
		   td.edge_seq != expected_floors.edge ||
		   conv == nil ||
		   len(conv.tasks) != expected_tasks ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "global compaction recovered task state differs from durable model"
		}
		first := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)
		if (mutation == .Delete_Task || mutation == .Delete_Task_Cascade) && active_durable {
			if first != nil do return "global compaction durable delete restored checkpoint task"
		} else if mutation == .Update_Task && active_durable {
			if !semantic_transport_persistence_updated_task_exact(first) do return "global compaction durable update differs from model"
		} else if !semantic_transport_persistence_task_exact(first) {
			return "global compaction checkpoint task differs from model"
		}
		second := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)
		expect_second := mutation == .Create_Task && active_durable
		if expect_second != (second != nil) || (second != nil && !semantic_transport_persistence_active_task_exact(second)) {
			return "global compaction active task differs from durable model"
		}
		expect_cascade := mutation == .Delete_Task_Cascade && !active_durable
		return semantic_global_compaction_check_cascade_entities(campaign, expect_cascade)
	}

	semantic_global_compaction_check_final_state :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		mutation: Semantic_Global_Compaction_Mutation,
		active_durable: bool,
	) -> string {
		prior_tasks := semantic_global_compaction_prior_task_count(mutation, active_durable)
		prior_floors := semantic_global_compaction_prior_floors(mutation, active_durable)
		writer := semantic_transport_persistence_writer(campaign)
		final_tasks := prior_tasks + 1
		final_floors := prior_floors
		final_floors.task += 1
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer == nil ||
		   writer.floors != final_floors ||
		   td.task_seq != final_floors.task ||
		   td.asset_seq != final_floors.asset ||
		   td.edge_seq != final_floors.edge ||
		   conv == nil ||
		   len(conv.tasks) != final_tasks ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "global compaction final state shape differs from exact model"
		}
		first := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)
		if (mutation == .Delete_Task || mutation == .Delete_Task_Cascade) && active_durable {
			if first != nil do return "global compaction final state restored durable deletion"
		} else if mutation == .Update_Task && active_durable {
			if !semantic_transport_persistence_updated_task_exact(first) do return "global compaction final durable update differs from model"
		} else if !semantic_transport_persistence_task_exact(first) {
			return "global compaction final checkpoint task differs from model"
		}
		if mutation == .Create_Task &&
		   active_durable &&
		   !semantic_transport_persistence_active_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)) {
			return "global compaction final state lost durable active task"
		}
		continued_id := pr.TaskID(final_floors.task)
		continued_order := u16(semantic_global_compaction_prior_active_count(mutation, active_durable))
		if !semantic_global_compaction_continued_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, continued_id), continued_id, continued_order) {
			return "global compaction final continued task differs from exact model"
		}
		expect_cascade := mutation == .Delete_Task_Cascade && !active_durable
		return semantic_global_compaction_check_cascade_entities(campaign, expect_cascade)
	}

	semantic_transport_persistence_virtual_crash_reopen :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		world_already_crashed: bool = false,
	) -> (
		Shard_High_Water_Requirements,
		bool,
		string,
	) {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return {}, false, "virtual crash writer missing"
		discard_shard_deferred_requests(writer)
		generated_semantic_virtual_process_discard(writer)
		process_connections := [?]^NRC_Connection{campaign.requester, campaign.peer}
		if !nrc_sim_process_crash_discard_connections(&campaign.ctx.sim, process_connections[:], world_already_crashed) {
			return {}, false, "virtual process connection discard failed"
		}
		for conn in process_connections {
			if conn == nil || conn.pending_io != 0 || conn.retained_io != 0 || conn.deferred_shard_requests != 0 {
				return {}, false, "virtual process connection ownership remained after stale-event discard"
			}
		}
		semantic_transport_persistence_uninstall_client(campaign, 1)
		semantic_transport_persistence_uninstall_client(campaign, 2)
		if connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before ||
		   td.spool.invalid_release_count != campaign.invalid_releases_before {
			return {}, false, "virtual process discard did not restore pool ownership"
		}
		campaign.requester = nil
		campaign.peer = nil
		if !shutdown_shard_writer_registry(&td.shard_writers) do return {}, false, "virtual crashed writer shutdown failed"
		campaign.registry_started = false
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
		campaign.server.closing = false
		campaign.server.fatal_storage_error = false
		shard_replay_state_destroy()
		if !semantic_transport_persistence_init_writer(campaign) do return {}, false, "virtual crashed writer reopen failed"
		writer = semantic_transport_persistence_writer(campaign)
		shard_replay_state_init()
		floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
		td.task_seq = floors.task
		td.asset_seq = floors.asset
		td.edge_seq = floors.edge
		return floors, replay_ok, ""
	}

	semantic_global_compaction_crash_reopen :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		mutation: Semantic_Global_Compaction_Mutation,
		active_durable: bool,
	) -> string {
		expected_floors := semantic_global_compaction_prior_floors(mutation, active_durable)
		floors, replay_ok, diagnostic := semantic_transport_persistence_virtual_crash_reopen(campaign)
		if diagnostic != "" do return diagnostic
		writer := semantic_transport_persistence_writer(campaign)
		if !replay_ok || floors != expected_floors || writer.floors != floors {
			return fmt.tprintf(
				"global compaction crash replay floor differs from durable model: ok=%v replay=%v writer=%v expected=%v manifest=%v records=%d/%d",
				replay_ok,
				floors,
				writer.floors,
				expected_floors,
				writer.manifest,
				writer.wal.record_count,
				writer.wal.durable_record_count,
			)
		}
		return semantic_global_compaction_check_state(campaign, mutation, active_durable)
	}

	semantic_global_compaction_continue_and_restart :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		mutation: Semantic_Global_Compaction_Mutation,
		active_durable: bool,
	) -> string {
		expected_tasks := semantic_global_compaction_prior_task_count(mutation, active_durable)
		expected_floors := semantic_global_compaction_prior_floors(mutation, active_durable)
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "global compaction continued writer missing"
		if writer.compaction == .Sealed && !generated_compaction_run_clean(&campaign.ctx.sim.world, writer) {
			return "global compaction clean retry failed"
		}
		if writer.compaction != .Idle || !writer.manifest.checkpoint_present || writer.manifest.sealed_present {
			return "global compaction retry did not publish checkpoint"
		}
		campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "requester", init_send_queue = true)
		campaign.ctx.conns[1] = campaign.requester
		campaign.peer = simulation_test_install_client(&campaign.ctx.sim, 2, campaign.workspace, "peer", init_send_queue = true)
		campaign.ctx.conns[2] = campaign.peer
		if campaign.requester == nil || campaign.peer == nil do return "global compaction continued clients failed to install"
		subscribe_to_conversation(campaign.requester, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.requester, 77)
		subscribe_to_conversation(campaign.peer, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.peer, 77)
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		req := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("continued after global crash"),
			description    = transmute([]byte)string("must survive the verification restart"),
			priority       = 7,
			status         = .Todo,
			correlation_id = 0xCAFE,
			project        = transmute([]byte)string("simulation"),
		}
		if !semantic_transport_persistence_enqueue_create(campaign, req, 3, 13) do return "global compaction continued request failed to enqueue"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		continued_id := pr.TaskID(expected_floors.task + 1)
		continued := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, continued_id)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		continued_order := u16(semantic_global_compaction_prior_active_count(mutation, active_durable))
		if !semantic_global_compaction_continued_task_exact(continued, continued_id, continued_order) ||
		   conv == nil ||
		   len(conv.tasks) != expected_tasks + 1 ||
		   writer.floors != (Shard_High_Water_Requirements{task = expected_floors.task + 1, asset = expected_floors.asset, edge = expected_floors.edge}) {
			return "global compaction continued WebSocket mutation failed"
		}
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {
			return "global compaction continued mutation fsync failed"
		}
		if writer.wal.durable_record_count != writer.wal.record_count do return "global compaction continued mutation did not become durable"

		generated_semantic_virtual_process_discard(writer)
		process_connections := [?]^NRC_Connection{campaign.requester, campaign.peer}
		if !nrc_sim_process_crash_discard_connections(&campaign.ctx.sim, process_connections[:]) {
			return "global compaction verification process discard failed"
		}
		semantic_transport_persistence_uninstall_client(campaign, 1)
		semantic_transport_persistence_uninstall_client(campaign, 2)
		if connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before ||
		   td.spool.invalid_release_count != campaign.invalid_releases_before {
			return "global compaction verification discard did not restore pool ownership"
		}
		campaign.requester = nil
		campaign.peer = nil
		if !shutdown_shard_writer_registry(&td.shard_writers) do return "global compaction verification writer shutdown failed"
		campaign.registry_started = false
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		shard_replay_state_destroy()
		if !semantic_transport_persistence_init_writer(campaign) do return "global compaction verification writer reopen failed"
		writer = semantic_transport_persistence_writer(campaign)
		shard_replay_state_init()
		floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
		td.task_seq = floors.task
		td.asset_seq = floors.asset
		td.edge_seq = floors.edge
		expected_final_floors := expected_floors
		expected_final_floors.task += 1
		if !replay_ok || floors != expected_final_floors || writer.floors != floors {
			return "global compaction continued mutation did not survive verification restart"
		}
		return semantic_global_compaction_check_final_state(campaign, mutation, active_durable)
	}

	semantic_global_compaction_dependent_recover_and_continue :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		expected: Semantic_Dependent_Task_Model,
		durable_records: u64,
		continuation_variant: u8,
		split_a, split_b: int,
	) -> string {
		expected_floors := Shard_High_Water_Requirements {
			task  = expected.task_floor,
			asset = expected.asset_floor,
			edge  = expected.edge_floor,
		}
		floors, replay_ok, diagnostic := semantic_transport_persistence_virtual_crash_reopen(campaign)
		if diagnostic != "" do return diagnostic
		writer := semantic_transport_persistence_writer(campaign)
		if !replay_ok ||
		   writer == nil ||
		   floors != expected_floors ||
		   writer.floors != floors ||
		   writer.wal.record_count != durable_records ||
		   writer.wal.durable_record_count != durable_records {
			return "global dependent compaction recovery differs from durable active-WAL prefix"
		}
		if model_diagnostic := semantic_dependent_history_model_check(campaign, expected); model_diagnostic != "" {
			return fmt.tprintf("global dependent compaction recovery: %s", model_diagnostic)
		}
		if writer.compaction == .Sealed && !generated_compaction_run_clean(&campaign.ctx.sim.world, writer) {
			return "global dependent compaction retry failed"
		}
		if writer.compaction != .Idle || !writer.manifest.checkpoint_present || writer.manifest.sealed_present {
			return "global dependent compaction retry did not publish checkpoint"
		}

		campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "requester", init_send_queue = true)
		campaign.ctx.conns[1] = campaign.requester
		campaign.peer = simulation_test_install_client(&campaign.ctx.sim, 2, campaign.workspace, "peer", init_send_queue = true)
		campaign.ctx.conns[2] = campaign.peer
		if campaign.requester == nil || campaign.peer == nil do return "global dependent compaction continuation clients failed to install"
		subscribe_to_conversation(campaign.requester, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.requester, 77)
		subscribe_to_conversation(campaign.peer, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.peer, 77)
		nrc_sim_clear_inboxes(&campaign.ctx.sim)

		continued := expected
		if !semantic_dependent_history_enqueue(
			   campaign,
			   &continued,
			   7,
			   continuation_variant,
			   semantic_dependent_history_split(u8(split_a), false),
			   semantic_dependent_history_split(u8(split_b), true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "global dependent compaction continuation failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		continued_records := durable_records + 1
		continued_floors := Shard_High_Water_Requirements {
			task  = continued.task_floor,
			asset = continued.asset_floor,
			edge  = continued.edge_floor,
		}
		if writer.wal.record_count != continued_records || writer.floors != continued_floors {
			return "global dependent compaction continuation WAL differs from model"
		}
		if model_diagnostic := semantic_dependent_history_model_check(campaign, continued); model_diagnostic != "" {
			return fmt.tprintf("global dependent compaction continuation: %s", model_diagnostic)
		}
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok ||
		   !did_work ||
		   !writer.fsync_in_flight ||
		   writer.fsync_snapshot.record_count != continued_records ||
		   !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) ||
		   writer.wal.durable_record_count != continued_records {
			return "global dependent compaction continuation fsync failed"
		}

		floors, replay_ok, diagnostic = semantic_transport_persistence_virtual_crash_reopen(campaign)
		if diagnostic != "" do return diagnostic
		writer = semantic_transport_persistence_writer(campaign)
		if !replay_ok ||
		   writer == nil ||
		   floors != continued_floors ||
		   writer.floors != floors ||
		   writer.wal.record_count != continued_records ||
		   writer.wal.durable_record_count != continued_records {
			return "global dependent compaction continuation did not survive second restart"
		}
		if model_diagnostic := semantic_dependent_history_model_check(campaign, continued); model_diagnostic != "" {
			return fmt.tprintf("global dependent compaction second recovery: %s", model_diagnostic)
		}
		return ""
	}

	Semantic_Dependent_Enqueue_Action :: struct {
		campaign:   ^Semantic_Transport_Persistence_Campaign,
		model:      ^Semantic_Dependent_Task_Model,
		index:      int,
		variant:    u8,
		split_a:    int,
		split_b:    int,
		enqueued:   bool,
		diagnostic: string,
	}

	semantic_dependent_enqueue_driver_action :: proc(user: rawptr) {
		action := (^Semantic_Dependent_Enqueue_Action)(user)
		if !semantic_dependent_history_enqueue(action.campaign, action.model, action.index, action.variant, action.split_a, action.split_b) ||
		   nrc_sim_receive_event_count(&action.campaign.ctx.sim) != 3 {
			action.diagnostic = fmt.tprintf("global dependent compaction operation %d driver action failed", action.index)
			return
		}
		action.enqueued = true
	}

	semantic_global_compaction_dependent_run :: proc(
		op_count: int,
		variants, split_as, split_bs, choices: []u8,
		require_snapshot_overlap: bool = false,
	) -> string {
		if op_count < 3 || op_count > 4 || len(variants) < op_count || len(split_as) < op_count || len(split_bs) < op_count || len(choices) < 48 {
			return "global dependent compaction choices are incomplete"
		}
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "global-dependent-compaction", 1, 7, thread_index = 0, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "global dependent compaction foundation missing"
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != 1 {
			return "global dependent compaction foundation fsync failed"
		}
		if !rotate_shard_writer_for_compaction(writer) ||
		   !rotate_shard_writer_for_compaction(writer) ||
		   !enqueue_shard_compaction_job_event(&campaign.ctx.sim.world, writer) {
			return "global dependent compaction rotation/job enqueue failed"
		}
		nrc_sim_clear_inboxes(&campaign.ctx.sim)

		models: [5]Semantic_Dependent_Task_Model
		model := Semantic_Dependent_Task_Model {
			kind       = .Original,
			live       = true,
			task_id    = 1,
			task_floor = 1,
		}
		models[0] = model
		if !semantic_dependent_history_enqueue(
			   &campaign,
			   &model,
			   0,
			   variants[0],
			   semantic_dependent_history_split(split_as[0], false),
			   semantic_dependent_history_split(split_bs[0], true),
		   ) ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 {
			return "global dependent compaction first operation failed to enqueue"
		}
		models[1] = model
		enqueued_count := 1
		applied_count := 0
		second_prefix := op_count - 1
		first_fsync_submitted := false
		first_fsync_completed := false
		second_fsync_submitted := false
		second_fsync_completed := false
		first_snapshot_bytes: u64
		first_snapshot_hash: [32]u8
		second_snapshot_bytes: u64
		second_snapshot_hash: [32]u8
		first_snapshot_overlapped := false
		second_snapshot_overlapped := false
		choice_index := 0
		enqueue_action: Semantic_Dependent_Enqueue_Action
		enqueue_action_event_id: u64

		for _ in 0 ..< 128 {
			writer = semantic_transport_persistence_writer(&campaign)
			if writer == nil do return "global dependent compaction scheduled writer missing"
			if writer.wal.record_count > u64(applied_count) {
				if writer.wal.record_count != u64(applied_count + 1) || applied_count >= enqueued_count {
					return "global dependent compaction applied operations out of order"
				}
				applied_count += 1
				expected := models[applied_count]
				expected_floors := Shard_High_Water_Requirements {
					task  = expected.task_floor,
					asset = expected.asset_floor,
					edge  = expected.edge_floor,
				}
				if writer.floors != expected_floors {
					return fmt.tprintf("global dependent compaction operation %d floors differ from model", applied_count - 1)
				}
				if model_diagnostic := semantic_dependent_history_model_check(&campaign, expected); model_diagnostic != "" {
					return fmt.tprintf("global dependent compaction operation %d: %s", applied_count - 1, model_diagnostic)
				}
				if first_fsync_submitted && !first_fsync_completed && applied_count > 1 do first_snapshot_overlapped = true
				if second_fsync_submitted && !second_fsync_completed && applied_count > second_prefix do second_snapshot_overlapped = true
			}

			if applied_count == 1 && !first_fsync_submitted {
				writer.commit_started = {}
				did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
				if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != 1 || writer.wal.durable_record_count != 0 {
					return "global dependent compaction first fsync captured wrong prefix"
				}
				first_fsync_submitted = true
				first_snapshot_bytes = writer.fsync_snapshot.pending_bytes
				first_snapshot_hash = writer.fsync_snapshot.last_hash
			}
			if applied_count == second_prefix && first_fsync_completed && !second_fsync_submitted {
				writer.commit_started = {}
				did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
				if !sync_ok ||
				   !did_work ||
				   !writer.fsync_in_flight ||
				   writer.fsync_snapshot.record_count != u64(second_prefix) ||
				   writer.wal.durable_record_count != 1 {
					return "global dependent compaction second fsync captured wrong prefix"
				}
				second_fsync_submitted = true
				second_snapshot_bytes = writer.fsync_snapshot.pending_bytes
				second_snapshot_hash = writer.fsync_snapshot.last_hash
			}
			can_enqueue := enqueued_count == applied_count && enqueued_count < op_count && (applied_count != second_prefix || second_fsync_submitted)
			if can_enqueue && enqueue_action_event_id == 0 {
				index := enqueued_count
				enqueue_action = {
					campaign = &campaign,
					model    = &model,
					index    = index,
					variant  = variants[index],
					split_a  = semantic_dependent_history_split(split_as[index], false),
					split_b  = semantic_dependent_history_split(split_bs[index], true),
				}
				enqueue_action_event_id = sim_world_enqueue_driver_action(&campaign.ctx.sim.world, &enqueue_action, semantic_dependent_enqueue_driver_action)
				if enqueue_action_event_id == 0 {
					return fmt.tprintf("global dependent compaction operation %d driver action failed to enqueue", index)
				}
			}

			expected_durable := second_fsync_completed ? u64(second_prefix) : (first_fsync_completed ? u64(1) : u64(0))
			if writer.wal.durable_record_count != expected_durable {
				return "global dependent compaction durability differs from completed fsync snapshots"
			}
			if first_fsync_submitted &&
			   !first_fsync_completed &&
			   (writer.fsync_snapshot.record_count != 1 ||
					   writer.fsync_snapshot.pending_bytes != first_snapshot_bytes ||
					   writer.fsync_snapshot.last_hash != first_snapshot_hash) {
				return "global dependent compaction later append changed first fsync snapshot"
			}
			if second_fsync_submitted &&
			   !second_fsync_completed &&
			   (writer.fsync_snapshot.record_count != u64(second_prefix) ||
					   writer.fsync_snapshot.pending_bytes != second_snapshot_bytes ||
					   writer.fsync_snapshot.last_hash != second_snapshot_hash) {
				return "global dependent compaction speculative append changed second fsync snapshot"
			}
			if applied_count == op_count && second_fsync_completed {
				if writer.wal.pending_bytes == 0 || writer.wal.durable_last_hash != second_snapshot_hash || writer.wal.last_hash == second_snapshot_hash {
					return "global dependent compaction did not retain speculative suffix"
				}
				break
			}

			runnable_count := sim_world_prepare_runnable(&campaign.ctx.sim.world)
			if runnable_count == 0 do return "global dependent compaction schedule stalled"
			choice := choice_index < len(choices) ? choices[choice_index] : 0
			choice_index += 1
			rank := int(choice) * runnable_count / 256
			index := sim_world_runnable_rank_index(&campaign.ctx.sim.world, rank)
			if index < 0 do return "global dependent compaction runnable rank missing"
			event := campaign.ctx.sim.world.events[index]
			pending_before_dispatch := writer.wal.pending_bytes
			if !sim_world_dispatch_event(&campaign.ctx.sim.world, index) {
				return "global dependent compaction selected event dispatch failed"
			}
			if event.id == enqueue_action_event_id {
				if enqueue_action.diagnostic != "" do return enqueue_action.diagnostic
				if !enqueue_action.enqueued || enqueue_action.index != enqueued_count {
					return "global dependent compaction operation driver action state differs"
				}
				enqueued_count += 1
				models[enqueued_count] = model
				enqueue_action_event_id = 0
			}
			if event.domain == .Fsync {
				if !first_fsync_completed {
					if !first_fsync_submitted ||
					   writer.wal.durable_record_count != 1 ||
					   writer.wal.durable_last_hash != first_snapshot_hash ||
					   pending_before_dispatch < first_snapshot_bytes ||
					   writer.wal.pending_bytes != pending_before_dispatch - first_snapshot_bytes {
						return "global dependent compaction first fsync completion differs from snapshot"
					}
					first_fsync_completed = true
				} else {
					if !second_fsync_submitted ||
					   second_fsync_completed ||
					   writer.wal.durable_record_count != u64(second_prefix) ||
					   writer.wal.durable_last_hash != second_snapshot_hash ||
					   pending_before_dispatch < second_snapshot_bytes ||
					   writer.wal.pending_bytes != pending_before_dispatch - second_snapshot_bytes {
						return "global dependent compaction second fsync completion differs from snapshot"
					}
					second_fsync_completed = true
				}
			}
		}
		if applied_count != op_count || enqueued_count != op_count || !first_fsync_completed || !second_fsync_completed {
			return "global dependent compaction schedule exceeded event budget"
		}
		if require_snapshot_overlap && (!first_snapshot_overlapped || !second_snapshot_overlapped) {
			return "global dependent compaction mandatory schedule did not overlap both fsync snapshots with later appends"
		}
		return semantic_global_compaction_dependent_recover_and_continue(
			&campaign,
			models[second_prefix],
			u64(second_prefix),
			variants[op_count - 1],
			int(split_as[op_count - 1]),
			int(split_bs[op_count - 1]),
		)
	}

	semantic_global_compaction_run :: proc(
		choices: []u8,
		crash_point: Semantic_Global_Compaction_Crash,
		split_a, split_b: int,
		mutation: Semantic_Global_Compaction_Mutation = .Create_Task,
	) -> string {
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "global-compaction", 1, 7, thread_index = 0, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if mutation == .Delete_Task_Cascade {
			diagnostic = semantic_global_compaction_setup_cascade(&campaign)
			if diagnostic != "" do return diagnostic
		}
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil do return "global compaction initial writer missing"
		expected_checkpoint_records := mutation == .Delete_Task_Cascade ? u64(3) : u64(1)
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != expected_checkpoint_records {
			return "global compaction checkpoint fixture did not become durable"
		}
		if !rotate_shard_writer_for_compaction(writer) ||
		   !rotate_shard_writer_for_compaction(writer) ||
		   !enqueue_shard_compaction_job_event(&campaign.ctx.sim.world, writer) {
			return "global compaction initial rotation/job enqueue failed"
		}
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		enqueued := false
		switch mutation {
		case .Create_Task:
			second := pr.CreateTaskRequest {
				conv_id        = pr.WORKSPACE_DATA_ID,
				title          = transmute([]byte)string("active during compaction"),
				description    = transmute([]byte)string("must remain in the active WAL"),
				priority       = 5,
				status         = .Todo,
				correlation_id = 0xBEEF,
				project        = transmute([]byte)string("simulation"),
			}
			enqueued = semantic_transport_persistence_enqueue_create(&campaign, second, split_a, split_b)
		case .Update_Task:
			update := pr.UpdateTaskRequest {
				conv_id              = pr.WORKSPACE_DATA_ID,
				task_id              = 1,
				title                = transmute([]byte)string("updated cross-domain task"),
				description          = transmute([]byte)string("update appended during create fsync"),
				status               = .Done,
				assignee             = transmute([]byte)string("peer"),
				priority             = 7,
				color                = .Gold,
				external_ref         = transmute([]byte)string("SIM-UPDATE-1"),
				due_at               = NRC_SIM_TIME_EPOCH_NANOS + 60_000_000_000,
				preserve_attachments = true,
				project              = transmute([]byte)string("updated-simulation"),
				correlation_id       = 0xD00D,
			}
			enqueued = semantic_transport_persistence_enqueue_update(&campaign, update, split_a, split_b)
		case .Delete_Task:
			enqueued = semantic_transport_persistence_enqueue_delete(&campaign, pr.WORKSPACE_DATA_ID, 1, 0xDE1E, split_a, split_b)
		case .Delete_Task_Cascade:
			enqueued = semantic_transport_persistence_enqueue_delete(&campaign, pr.WORKSPACE_DATA_ID, 1, 0xCA5C, split_a, split_b)
		}
		if !enqueued {
			return "global compaction active mutation failed to enqueue"
		}

		choice_index := 0
		crashed := false
		active_fsync_submitted := false
		active_fsync_completed := false
		active_fsync_action := Semantic_Fsync_Submit_Action {
			campaign         = &campaign,
			expected_records = 1,
		}
		active_fsync_action_event_id: u64
		for _ in 0 ..< 64 {
			writer = semantic_transport_persistence_writer(&campaign)
			if writer == nil do return "global compaction scheduled writer missing"
			active_visible := writer.wal.record_count == 1
			if active_visible {
				if live_diagnostic := semantic_global_compaction_check_live_mutation(&campaign, mutation, active_fsync_completed); live_diagnostic != "" do return live_diagnostic
			}
			expected_durable_records := active_fsync_completed ? u64(1) : u64(0)
			if writer.wal.durable_record_count != expected_durable_records {
				return "global compaction production durability diverged from fsync model"
			}
			if crash_point == .Before_Active_Fsync && active_visible && !writer.fsync_in_flight && writer.wal.durable_record_count == 0 {
				crashed = true
				break
			}
			if crash_point == .Before_Compaction_Result && active_visible && sim_world_event_count(&campaign.ctx.sim.world, .Compaction_Result) == 1 {
				crashed = true
				break
			}
			can_submit_fsync := active_visible && !writer.fsync_in_flight && writer.wal.durable_record_count == 0
			if can_submit_fsync && active_fsync_action_event_id == 0 {
				active_fsync_action_event_id = sim_world_enqueue_driver_action(
					&campaign.ctx.sim.world,
					&active_fsync_action,
					semantic_submit_fsync_driver_action,
				)
				if active_fsync_action_event_id == 0 do return "global compaction fsync driver action failed to enqueue"
			}
			runnable_count := sim_world_prepare_runnable(&campaign.ctx.sim.world)
			allowed_indices: [64]int
			allowed_count := 0
			for rank in 0 ..< runnable_count {
				index := sim_world_runnable_rank_index(&campaign.ctx.sim.world, rank)
				if index < 0 do return "global compaction runnable rank missing"
				if crash_point == .Before_Compaction_Result && !active_visible && campaign.ctx.sim.world.events[index].domain == .Compaction_Result {
					continue
				}
				allowed_indices[allowed_count] = index
				allowed_count += 1
			}
			if allowed_count == 0 {
				if crash_point == .None && writer.compaction == .Idle && writer.wal.durable_record_count == 1 && len(campaign.ctx.sim.world.events) == 0 {
					break
				}
				return "global compaction schedule stalled"
			}
			choice := choice_index < len(choices) ? choices[choice_index] : 0
			choice_index += 1
			selected := int(choice) * allowed_count / 256
			selected_event := campaign.ctx.sim.world.events[allowed_indices[selected]]
			if !sim_world_dispatch_event(&campaign.ctx.sim.world, allowed_indices[selected]) {
				return "global compaction selected event dispatch failed"
			}
			if selected_event.id == active_fsync_action_event_id {
				if active_fsync_action.diagnostic != "" do return active_fsync_action.diagnostic
				if !active_fsync_action.submitted || active_fsync_submitted || writer.wal.durable_record_count != 0 {
					return "global compaction fsync driver action submission diverged from model"
				}
				active_fsync_submitted = true
			}
			if selected_event.domain == .Fsync {
				if !active_fsync_submitted || active_fsync_completed || writer.wal.durable_record_count != 1 {
					return "global compaction fsync completion diverged from model"
				}
				active_fsync_completed = true
			}
		}

		writer = semantic_transport_persistence_writer(&campaign)
		if writer == nil do return "global compaction terminal writer missing"
		active_durable := true
		if crashed {
			active_durable = active_fsync_completed
		} else if crash_point != .None {
			return "global compaction target crash was not reached"
		} else if !active_fsync_submitted ||
		   !active_fsync_completed ||
		   writer.compaction != .Idle ||
		   writer.wal.durable_record_count != 1 ||
		   len(campaign.ctx.sim.world.events) != 0 {
			return "global compaction clean schedule did not drain"
		}
		diagnostic = semantic_global_compaction_crash_reopen(&campaign, mutation, active_durable)
		if diagnostic != "" do return diagnostic
		return semantic_global_compaction_continue_and_restart(&campaign, mutation, active_durable)
	}

	semantic_transport_persistence_run_requester_close_reuse :: proc() -> string {
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "requester-close-reuse", 1, 7)
		defer semantic_transport_persistence_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic

		for nrc_sim_receive_event_count(&campaign.ctx.sim) > 0 {
			diagnostic = semantic_transport_persistence_run_action(&campaign, .Run_Receive)
			if diagnostic != "" do return diagnostic
		}
		diagnostic = semantic_transport_persistence_run_action(&campaign, .Submit_Fsync)
		if diagnostic != "" do return diagnostic
		diagnostic = semantic_transport_persistence_run_action(&campaign, .Run_Fsync)
		if diagnostic != "" do return diagnostic
		old_requester := campaign.requester
		old_handle := old_requester.handle
		old_sock := old_requester.sock
		retained_before := td.retained_connection_count
		if !campaign.frames_verified || old_requester.pending_io != 1 || campaign.peer.pending_io != 1 {
			return "task response submissions missing before requester close"
		}

		connection_close(old_requester, false)
		close_waiting := old_requester.state == .Closing && old_requester.pending_io == 2 && nrc_sim_close_completion_count(&campaign.ctx.sim) == 0
		if !close_waiting {
			// If close partially started, completion teardown must still own this
			// generation rather than generic teardown retaining a raw pointer.
			if old_requester.state >= .Closing {
				campaign.ctx.conns[1] = nil
				campaign.reused_old_counted = true
				campaign.reused_old_handle = old_handle
			}
			return "requester close did not wait for its task response"
		}
		// From this point the production close/send completions own the old
		// allocation. Never let generic teardown uninstall this pointer.
		campaign.ctx.conns[1] = nil
		campaign.reused_old_counted = true
		campaign.reused_old_handle = old_handle
		retained_requester := connection_get_by_handle(old_handle)
		if retained_requester == nil {
			return "requester close did not retain the old allocation"
		}
		requester_send_index := semantic_transport_persistence_send_completion_index(&campaign, retained_requester)
		if requester_send_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, requester_send_index) {
			return "requester task response completion was not runnable before close"
		}
		campaign.requester_send_completed = true
		if retained_requester == nil ||
		   retained_requester.state != .Closing ||
		   retained_requester.pending_io != 1 ||
		   nrc_sim_close_completion_count(&campaign.ctx.sim) != 1 ||
		   connection_get(old_sock) != nil {
			return "requester task response did not submit the reserved close"
		}

		nrc_sim_clear_captured_frames(&campaign.ctx.sim)
		replacement := simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "replacement-requester", init_send_queue = true)
		if replacement != nil do campaign.ctx.conns[1] = replacement
		if replacement == nil || replacement.sock != old_sock || replacement.handle == old_handle {
			return "replacement requester did not reuse the numeric socket with a new handle"
		}
		replacement_handle := replacement.handle

		if !nrc_sim_run_next_close_completion(&campaign.ctx.sim) {
			return "requester close completion was not runnable after socket reuse"
		}
		campaign.requester = replacement
		campaign.requester_reused = true
		if connection_get_by_handle(old_handle) != nil {
			return "stale requester task response did not reclaim the old generation"
		}
		connection_test_live_count -= 1
		campaign.reused_old_counted = false
		if connection_get(old_sock) != replacement ||
		   replacement.handle != replacement_handle ||
		   replacement.state != .Idle ||
		   replacement.pending_io != 0 ||
		   replacement.is_sending ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, replacement.sock) != 0 ||
		   td.retained_connection_count != retained_before {
			return "stale task response completion targeted the replacement requester"
		}
		diagnostic = semantic_transport_persistence_check(&campaign)
		if diagnostic != "" do return diagnostic

		peer_send_index := semantic_transport_persistence_send_completion_index(&campaign, campaign.peer)
		if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, peer_send_index) {
			return "peer task response completion was not runnable after requester reuse"
		}
		campaign.peer_send_completed = true
		peer_send_index = semantic_transport_persistence_send_completion_index(&campaign, campaign.peer)
		if nrc_sim_send_completion_count(&campaign.ctx.sim) != 1 ||
		   peer_send_index < 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 1 {
			return "requester close did not submit exactly one peer presence update"
		}
		presence_frame := nrc_sim_client_frame(&campaign.ctx.sim, campaign.peer.sock, 0)
		presence_payload, presence_ok := nrc_sim_frame_protocol_payload(presence_frame)
		if !presence_ok || pr.get_opcode(presence_payload) != .S_RoomPresenceUpdate {
			return "close-induced peer frame was not a room-presence update"
		}
		presence, presence_err := pr.parseRoomPresenceUpdateMessage(presence_payload)
		defer if len(presence.user_list) > 0 {
			delete(presence.user_list)
			delete(presence.user_auth_flags)
			delete(presence.user_types)
		}
		if presence_err != nil || presence.event_type != .UserLeft || presence.conv_id != 77 || string(presence.username) != "requester" {
			return "close-induced peer presence semantics mismatch"
		}
		if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, peer_send_index) {
			return "close-induced peer presence completion was not runnable"
		}
		if nrc_sim_send_completion_count(&campaign.ctx.sim) != 0 || campaign.peer.is_sending || send_queue_len(campaign.peer) != 0 {
			return "close-induced peer presence send did not fully drain"
		}
		diagnostic = semantic_transport_persistence_check(&campaign)
		if diagnostic != "" do return diagnostic
		if connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before ||
		   td.spool.invalid_release_count != campaign.invalid_releases_before {
			return "close/reuse task sends did not release pooled ownership exactly once"
		}
		return semantic_transport_persistence_restart(&campaign)
	}

	semantic_stale_generation_storage_run :: proc(choices, split_choices: []u8) -> string {
		if len(choices) < 32 || len(split_choices) < 4 do return "stale generation storage choices are incomplete"
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "stale-generation-storage", 1, 7, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "stale generation storage foundation missing"
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != 1 {
			return "stale generation storage durable foundation missing"
		}

		old_requester := campaign.requester
		old_handle := old_requester.handle
		old_sock := old_requester.sock
		retained_before := td.retained_connection_count
		old_update := semantic_dependent_history_update(0, 173)
		if !semantic_transport_persistence_enqueue_update(&campaign, old_update, int(split_choices[0]), int(split_choices[1])) {
			return "stale generation old update failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if writer.wal.record_count != 2 ||
		   writer.wal.durable_record_count != 1 ||
		   !semantic_dependent_history_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1), old_update) {
			return "stale generation old update differs from live model"
		}
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != 2 || writer.wal.durable_record_count != 1 {
			return "stale generation old update fsync submission failed"
		}
		masked_ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		if !nrc_sim_enqueue_receive(&campaign.ctx.sim, old_requester, masked_ping[:]) {
			return "stale generation old receive failed to enqueue"
		}
		connection_close(old_requester, false)
		if old_requester.state != .Closing ||
		   nrc_sim_receive_event_count(&campaign.ctx.sim) == 0 ||
		   nrc_sim_send_completion_count(&campaign.ctx.sim) < 2 ||
		   nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 1 ||
		   nrc_sim_close_completion_count(&campaign.ctx.sim) != 0 {
			return "stale generation close did not wait for receive/send/fsync overlap"
		}
		campaign.ctx.conns[1] = nil
		campaign.reused_old_counted = true
		campaign.reused_old_handle = old_handle
		if !nrc_sim_run_next_receive(&campaign.ctx.sim) {
			return "stale generation receive was not runnable before close"
		}
		retained_requester := connection_get_by_handle(old_handle)
		for {
			requester_send_index := semantic_transport_persistence_send_completion_index(&campaign, retained_requester)
			if requester_send_index < 0 do break
			if !nrc_sim_run_send_completion_at(&campaign.ctx.sim, requester_send_index) {
				return "stale generation requester send was not runnable before close"
			}
		}
		if retained_requester == nil ||
		   retained_requester.state != .Closing ||
		   retained_requester.pending_io != 1 ||
		   nrc_sim_close_completion_count(&campaign.ctx.sim) != 1 ||
		   connection_get(old_sock) != nil {
			return "stale generation transport completions did not submit reserved close"
		}

		nrc_sim_clear_captured_frames(&campaign.ctx.sim)
		replacement := simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "replacement-requester", init_send_queue = true)
		if replacement != nil do campaign.ctx.conns[1] = replacement
		if replacement == nil || replacement.sock != old_sock || replacement.handle == old_handle {
			return "stale generation replacement did not reuse socket with a new handle"
		}
		replacement_handle := replacement.handle
		if !nrc_sim_run_next_close_completion(&campaign.ctx.sim) {
			return "stale generation close completion was not runnable after socket reuse"
		}
		if connection_get(old_sock) != replacement || replacement.handle != replacement_handle {
			return "stale generation close completion altered the replacement generation"
		}
		campaign.requester = replacement
		subscribe_to_conversation(replacement, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(replacement, 77)
		replacement_update := semantic_dependent_history_update(1, 251)
		if !semantic_transport_persistence_enqueue_update(&campaign, replacement_update, int(split_choices[2]), int(split_choices[3])) {
			return "stale generation replacement update failed to enqueue"
		}

		choice_index := 0
		for _ in 0 ..< 64 {
			runnable_count := sim_world_prepare_runnable(&campaign.ctx.sim.world)
			if runnable_count == 0 do break
			choice := choices[choice_index % len(choices)]
			choice_index += 1
			selected := int(choice) * runnable_count / 256
			index := sim_world_runnable_rank_index(&campaign.ctx.sim.world, selected)
			if index < 0 || !sim_world_dispatch_event(&campaign.ctx.sim.world, index) {
				return "stale generation selected event failed to dispatch"
			}
		}
		if len(campaign.ctx.sim.world.events) != 0 || deferred_outbox_pump_count() != 0 {
			return "stale generation schedule did not drain"
		}
		writer = semantic_transport_persistence_writer(&campaign)
		if writer == nil ||
		   writer.wal.record_count != 3 ||
		   writer.wal.durable_record_count != 2 ||
		   writer.floors != (Shard_High_Water_Requirements{task = 1}) ||
		   !semantic_dependent_history_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1), replacement_update) {
			return "stale generation live replacement state differs from model"
		}
		if connection_get_by_handle(old_handle) != nil ||
		   connection_get(old_sock) != replacement ||
		   replacement.state != .Idle ||
		   replacement.pending_io != 0 ||
		   replacement.is_sending ||
		   td.retained_connection_count != retained_before {
			return "stale generation callback altered replacement ownership"
		}
		connection_test_live_count -= 1
		campaign.reused_old_counted = false
		replacement_frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, replacement.sock)
		list_sync_count := 0
		joined_count := 0
		update_count := 0
		for index in 0 ..< replacement_frame_count {
			frame := nrc_sim_client_frame(&campaign.ctx.sim, replacement.sock, index)
			payload, payload_ok := nrc_sim_frame_protocol_payload(frame)
			if !payload_ok do return "stale generation replacement received malformed frame"
			#partial switch pr.get_opcode(payload) {
			case .S_RoomPresenceUpdate:
				presence, presence_err := pr.parseRoomPresenceUpdateMessage(payload)
				defer if len(presence.user_list) > 0 {
					delete(presence.user_list)
					delete(presence.user_auth_flags)
					delete(presence.user_types)
				}
				if presence_err != nil || presence.conv_id != 77 do return "stale generation replacement presence frame malformed"
				#partial switch presence.event_type {
				case .UserListSync:
					members_exact :=
						len(presence.user_list) == 2 &&
						((string(presence.user_list[0]) == "replacement-requester" && string(presence.user_list[1]) == "peer") ||
								(string(presence.user_list[0]) == "peer" && string(presence.user_list[1]) == "replacement-requester"))
					if len(presence.username) != 0 ||
					   !members_exact ||
					   len(presence.user_auth_flags) != 2 ||
					   !presence.user_auth_flags[0] ||
					   !presence.user_auth_flags[1] ||
					   len(presence.user_types) != 2 ||
					   presence.user_types[0] != .User ||
					   presence.user_types[1] != .User {
						return "stale generation replacement user-list sync differs"
					}
					list_sync_count += 1
				case .UserJoined:
					if string(presence.username) != "replacement-requester" ||
					   !presence.is_authenticated ||
					   presence.user_type != .User ||
					   len(presence.old_username) != 0 ||
					   len(presence.user_list) != 0 {
						return "stale generation replacement joined presence differs"
					}
					joined_count += 1
				case:
					return "stale generation replacement received unexpected presence event"
				}
			case .S_TaskUpdated:
				attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
				event, parse_err := pr.parseTaskUpdated(payload, attachments[:])
				if parse_err != nil ||
				   event.correlation_id != replacement_update.correlation_id ||
				   !semantic_dependent_history_task_exact(&event.task, replacement_update) {
					return "stale generation replacement task response crossed generations"
				}
				update_count += 1
			case:
				return "stale generation replacement received unexpected opcode"
			}
		}
		queued_update, queued_update_ok := semantic_transport_persistence_pending_payload(replacement, .S_TaskUpdated)
		queued_attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		queued_event, queued_parse_err := pr.parseTaskUpdated(queued_update, queued_attachments[:])
		if list_sync_count != 1 ||
		   joined_count != 1 ||
		   update_count != 0 ||
		   replacement_frame_count != 2 ||
		   !queued_update_ok ||
		   queued_parse_err != nil ||
		   queued_event.correlation_id != replacement_update.correlation_id ||
		   !semantic_dependent_history_task_exact(&queued_event.task, replacement_update) {
			return fmt.tprintf(
				"stale generation replacement output mismatch: total=%d sync=%d joined=%d updates=%d",
				replacement_frame_count,
				list_sync_count,
				joined_count,
				update_count,
			)
		}

		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		if !replay_ok ||
		   floors != (Shard_High_Water_Requirements{task = 1}) ||
		   writer == nil ||
		   writer.floors != floors ||
		   writer.wal.record_count != 2 ||
		   writer.wal.durable_record_count != 2 ||
		   !semantic_dependent_history_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1), old_update) {
			return "stale generation recovery did not select captured old prefix"
		}
		return semantic_global_compaction_check_cascade_entities(&campaign, false)
	}

	Semantic_Deferred_Rotation_Outcome :: enum u8 {
		Success,
		Error,
		Crash_Before_Completion,
	}

	semantic_deferred_rotation_enqueue_update_asset :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, req: pr.UpdateAssetRequest) -> bool {
		request_buf: [4_096]byte
		request_len := pr.serializeUpdateAssetRequest(req, request_buf[:])
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		split := len(frame) / 2
		return(
			nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[:split]) &&
			nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[split:]) \
		)
	}

	semantic_deferred_rotation_asset_exact :: proc(asset: ^pr.Asset, payload: string) -> bool {
		return(
			asset != nil &&
			asset.asset_id == 1 &&
			asset.conv_id == pr.WORKSPACE_DATA_ID &&
			asset.asset_type == .Document &&
			asset.parent_type == .None &&
			asset.parent_id == 0 &&
			asset.payload_encoding == .Plain &&
			asset.payload_raw_len == u32(len(payload)) &&
			len(asset.preview) == 0 &&
			string(asset.payload) == payload &&
			string(asset.owner) == "requester" &&
			asset.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			asset.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			len(asset.attachments) == 0 \
		)
	}

	semantic_deferred_rotation_edge_exact :: proc(edge: ^pr.Edge) -> bool {
		return(
			edge != nil &&
			edge.edge_id == 1 &&
			edge.conv_id == pr.WORKSPACE_DATA_ID &&
			edge.source_type == .Task &&
			edge.source_id == 1 &&
			edge.target_type == .Asset &&
			edge.target_id == 1 &&
			edge.relation == .References &&
			edge.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			string(edge.created_by) == "requester" \
		)
	}

	semantic_deferred_rotation_adjacency_exact :: proc(conv: ^Conversation_State, edge_present: bool) -> bool {
		if conv == nil do return false
		if !edge_present do return len(conv.edges) == 0 && len(conv.edges_by_entity) == 0
		task_edges := conv.edges_by_entity[Edge_Entity_Key{target_type = .Task, target_id = 1}]
		asset_edges := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}]
		return(
			len(conv.edges) == 1 &&
			semantic_deferred_rotation_edge_exact(conv.edges[1]) &&
			len(conv.edges_by_entity) == 2 &&
			len(task_edges) == 1 &&
			task_edges[0] == 1 &&
			len(asset_edges) == 1 &&
			asset_edges[0] == 1 \
		)
	}

	semantic_deferred_rotation_edge_request_exact :: proc(payload: []byte, expected: pr.CreateEdgeRequest) -> bool {
		if pr.get_opcode(payload) != .C_CreateEdge do return false
		parsed, parse_err := pr.parseCreateEdgeRequest(payload[2:])
		return(
			parse_err == nil &&
			parsed.conv_id == expected.conv_id &&
			parsed.source_type == expected.source_type &&
			parsed.source_id == expected.source_id &&
			parsed.target_type == expected.target_type &&
			parsed.target_id == expected.target_id &&
			parsed.relation == expected.relation &&
			parsed.correlation_id == expected.correlation_id \
		)
	}

	semantic_global_segmented_retained_ack_exact :: proc(payload: []byte, correlation_id: u32 = 0xDA05, sequence: pr.MessageSeq = 1) -> bool {
		ack, parse_err := pr.parseAckSendMessageMessage(payload)
		return parse_err == nil && ack.client_req_id == correlation_id && ack.assigned_seq == sequence && ack.timestamp == NRC_SIM_TIME_EPOCH_NANOS
	}

	semantic_global_segmented_retained_page_exact :: proc(payload: []byte, marker: u64 = 2, content: string = "retained global append") -> bool {
		if pr.get_opcode(payload) != .S_MessagePage do return false
		page, parse_err := pr.parseMessagePage(payload[2:])
		if parse_err != nil ||
		   page.conv_id != 77 ||
		   !page.ascending ||
		   page.has_more ||
		   page.truncated ||
		   page.high_water_seq != pr.MessageSeq(marker) ||
		   page.retention_cutoff_seq != 0 ||
		   page.continuation_cursor != pr.MessageSeq(marker) ||
		   page.correlation_id != 0 ||
		   len(page.messages) != 1 {
			return false
		}
		message := page.messages[0]
		expected_id: [16]byte
		message_put_u64(expected_id[:], marker)
		return(
			message.conv_id == 77 &&
			message.seq == pr.MessageSeq(marker) &&
			message.client_message_id == expected_id &&
			string(message.author_username) == "requester" &&
			message.timestamp == NRC_SIM_TIME_EPOCH_NANOS &&
			message.content_type == .PlainText &&
			string(message.content) == content \
		)
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

	semantic_global_segmented_output_prefix_exact :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> bool {
		connections := [?]struct {
			conn:               ^NRC_Connection,
			task_correlation:   u32,
			asset_correlation:  u32,
			update_correlation: u32,
			edge_correlation:   u32,
			requester:          bool,
		}{{campaign.requester, 0xD00D, 0xDA01, 0xDA02, 0xDA03, true}, {campaign.peer, 0, 0, 0, 0, false}}
		for expected in connections {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, expected.conn.sock)
			max_frames := expected.requester ? 6 : 5
			if frame_count > max_frames do return false
			semantic_index := 0
			duplicate_ack_count := 0
			append_ack_count := 0
			retained_page_count := 0
			for frame_index in 0 ..< frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, expected.conn.sock, frame_index))
				if !payload_ok do return false
				#partial switch pr.get_opcode(payload) {
				case .S_TaskUpdated:
					if semantic_index != 0 do return false
					attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
					updated, parse_err := pr.parseTaskUpdated(payload, attachments[:])
					if parse_err != nil ||
					   updated.correlation_id != expected.task_correlation ||
					   !semantic_transport_persistence_updated_task_exact(&updated.task) {
						return false
					}
					semantic_index += 1
				case .S_AssetCreated:
					if semantic_index != 1 do return false
					created, parse_err := pr.parseAssetCreatedMessage(payload)
					if parse_err != nil ||
					   created.correlation_id != expected.asset_correlation ||
					   !semantic_deferred_rotation_asset_exact(&created.asset, "body") {
						return false
					}
					semantic_index += 1
				case .S_AssetUpdated:
					if semantic_index != 2 do return false
					updated, parse_err := pr.parseAssetUpdatedMessage(payload)
					if parse_err != nil ||
					   updated.correlation_id != expected.update_correlation ||
					   !semantic_deferred_rotation_asset_exact(&updated.asset, "updated") {
						return false
					}
					semantic_index += 1
				case .S_EdgeCreated:
					if semantic_index != 3 do return false
					created, parse_err := pr.parseEdgeCreatedMessage(payload)
					if parse_err != nil || created.correlation_id != expected.edge_correlation || !semantic_deferred_rotation_edge_exact(&created.edge) {
						return false
					}
					semantic_index += 1
				case .S_AckSendMessage:
					if !expected.requester do return false
					if semantic_global_segmented_retained_ack_exact(payload) {
						if duplicate_ack_count != 0 do return false
						duplicate_ack_count += 1
					} else if semantic_global_segmented_retained_ack_exact(payload, 0xDA06, 2) {
						if append_ack_count != 0 do return false
						append_ack_count += 1
					} else {
						return false
					}
				case .S_MessagePage:
					if expected.requester || retained_page_count != 0 || !semantic_global_segmented_retained_page_exact(payload) do return false
					retained_page_count += 1
				case:
					return false
				}
			}
		}
		return true
	}

	semantic_global_segmented_retained_message :: proc(workspace: string) -> Retained_Message {
		client_message_id: [16]byte
		message_put_u64(client_message_id[:], 1)
		return Retained_Message {
			workspace = workspace,
			conversation_id = 77,
			client_message_id = client_message_id,
			sender_name = "requester",
			sender_principal = "requester",
			accepted_at_ns = NRC_SIM_TIME_EPOCH_NANOS,
			content_type = u8(pr.MessageContentType.PlainText),
			content = transmute([]byte)string("retained global duplicate"),
		}
	}

	semantic_global_segmented_retry_retained :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) {
		message := semantic_global_segmented_retained_message(campaign.workspace)
		process_send_message_v2(
			campaign.requester,
			pr.SendMessageV2Request {
				conv_id = 77,
				client_message_id = message.client_message_id,
				correlation_id = 0xDA05,
				content_type = .PlainText,
				content = transmute([]byte)message.content,
			},
		)
	}

	semantic_global_segmented_append_retained :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) {
		client_message_id: [16]byte
		message_put_u64(client_message_id[:], 2)
		process_send_message_v2(
			campaign.requester,
			pr.SendMessageV2Request {
				conv_id = 77,
				client_message_id = client_message_id,
				correlation_id = 0xDA06,
				content_type = .PlainText,
				content = transmute([]byte)string("retained global append"),
			},
		)
	}

	semantic_global_segmented_continue_retained :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) {
		client_message_id: [16]byte
		message_put_u64(client_message_id[:], 3)
		process_send_message_v2(
			campaign.requester,
			pr.SendMessageV2Request {
				conv_id = 77,
				client_message_id = client_message_id,
				correlation_id = 0xDA07,
				content_type = .PlainText,
				content = transmute([]byte)string("retained global continuation"),
			},
		)
	}

	semantic_global_segmented_continued_task_exact :: proc(task: ^pr.Task, order_index: u16) -> bool {
		return(
			task != nil &&
			task.id == 2 &&
			task.conv_id == pr.WORKSPACE_DATA_ID &&
			string(task.title) == "continued after global segmented crash" &&
			string(task.description) == "must survive the second restart" &&
			task.status == .Todo &&
			task.order_index == order_index &&
			len(task.assignee) == 0 &&
			task.priority == 0 &&
			task.color == .None &&
			string(task.created_by) == "requester" &&
			task.created_at == NRC_SIM_TIME_EPOCH_NANOS &&
			task.updated_at == NRC_SIM_TIME_EPOCH_NANOS &&
			len(task.external_ref) == 0 &&
			task.due_at == 0 &&
			task.blocked_by == 0 &&
			task.completed_at == 0 &&
			len(task.completed_by) == 0 &&
			len(task.project) == 0 &&
			len(task.attachments) == 0 \
		)
	}

	semantic_deferred_rotation_check_responses :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> string {
		if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 2 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 2 {
			return "deferred rotation response count differed"
		}
		connections := [?]struct {
			conn:               ^NRC_Connection,
			create_correlation: u32,
			update_correlation: u32,
		}{{campaign.requester, 0xDA01, 0xDA02}, {campaign.peer, 0, 0}}
		for expected in connections {
			created_frame := nrc_sim_client_frame(&campaign.ctx.sim, expected.conn.sock, 0)
			updated_frame := nrc_sim_client_frame(&campaign.ctx.sim, expected.conn.sock, 1)
			created_payload, created_ok := nrc_sim_frame_protocol_payload(created_frame)
			updated_payload, updated_ok := nrc_sim_frame_protocol_payload(updated_frame)
			created, created_err := pr.parseAssetCreatedMessage(created_payload)
			updated, updated_err := pr.parseAssetUpdatedMessage(updated_payload)
			if !created_ok ||
			   !updated_ok ||
			   created_err != nil ||
			   updated_err != nil ||
			   created.correlation_id != expected.create_correlation ||
			   updated.correlation_id != expected.update_correlation ||
			   !semantic_deferred_rotation_asset_exact(&created.asset, "body") ||
			   !semantic_deferred_rotation_asset_exact(&updated.asset, "updated") {
				return "deferred rotation response order or semantics differed"
			}
		}
		return ""
	}

	semantic_deferred_rotation_install_clients :: proc(campaign: ^Semantic_Transport_Persistence_Campaign) -> bool {
		campaign.requester = simulation_test_install_client(&campaign.ctx.sim, 1, campaign.workspace, "requester", init_send_queue = true)
		campaign.ctx.conns[1] = campaign.requester
		campaign.peer = simulation_test_install_client(&campaign.ctx.sim, 2, campaign.workspace, "peer", init_send_queue = true)
		campaign.ctx.conns[2] = campaign.peer
		if campaign.requester == nil || campaign.peer == nil do return false
		subscribe_to_conversation(campaign.requester, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.requester, 77)
		subscribe_to_conversation(campaign.peer, pr.WORKSPACE_DATA_ID)
		subscribe_to_conversation(campaign.peer, 77)
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		return true
	}

	semantic_global_segmented_catalog_contains :: proc(writer: ^Shard_Transaction_Writer, expected: Shard_Segment_Descriptor) -> bool {
		if writer == nil do return false
		count := 0
		for descriptor in writer.catalog.segments do if descriptor == expected do count += 1
		return count == 1
	}

	Semantic_Global_Segmented_Crash_Phase :: enum {
		Any,
		Immediate,
		Late,
	}

	Semantic_Fsync_Submit_Action :: struct {
		campaign:         ^Semantic_Transport_Persistence_Campaign,
		expected_records: u64,
		submitted:        bool,
		diagnostic:       string,
	}

	semantic_submit_fsync_driver_action :: proc(user: rawptr) {
		action := (^Semantic_Fsync_Submit_Action)(user)
		writer := semantic_transport_persistence_writer(action.campaign)
		if writer == nil || writer.fsync_in_flight || writer.wal.record_count != action.expected_records || writer.wal.durable_record_count != 0 {
			action.diagnostic = "semantic fsync driver action was no longer eligible"
			return
		}
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != action.expected_records {
			action.diagnostic = "semantic fsync driver action failed"
			return
		}
		action.submitted = true
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

	semantic_global_segmented_deferred_run :: proc(
		choices: []u8,
		crash_after_events: int,
		require_stale_rebase: bool = false,
		rank_process_crash: bool = false,
		expected_crash_phase: Semantic_Global_Segmented_Crash_Phase = .Any,
		require_asset_fsync_completed: bool = false,
		require_retained_read_completed: bool = false,
		require_retained_fsync_completed: bool = false,
		crash_after_retained_flush: bool = false,
		require_retained_outputs_complete: bool = false,
		batch_retained_callback_wave: bool = false,
	) -> string {
		if len(choices) < 32 || crash_after_events < 0 do return "global segmented deferred choices are incomplete"
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "global-segmented-deferred", 1, 7, thread_index = 0, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		retained_registry_started := false
		defer {
			if retained_registry_started {
				for nrc_sim_run_next_file_read(&campaign.ctx.sim) {}
				for nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {}
				_ = shutdown_message_store_registry(&td.message_stores)
			}
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 do return "global segmented deferred foundation missing"
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != 1 {
			return "global segmented deferred foundation did not become durable"
		}
		if !rotate_shard_writer_for_compaction(writer) ||
		   !rotate_shard_writer_for_compaction(writer) ||
		   writer.catalog_segments != 2 ||
		   !enqueue_shard_compaction_job_event(&campaign.ctx.sim.world, writer) {
			return "global segmented deferred cleaner snapshot setup failed"
		}
		for &index in td.message_stores.store_index do index = -1
		if _, append_err := append(&td.message_stores.stores, Message_Store{}); append_err != nil {
			return "global segmented deferred retained registry allocation failed"
		}
		retained_store := &td.message_stores.stores[0]
		if !init_message_store_with_storage(
			retained_store,
			sim_world_storage_context(&campaign.ctx.sim.world),
			campaign.shard_dir,
			campaign.shard,
			24 * time.Hour,
			0,
		) {
			return "global segmented deferred retained store setup failed"
		}
		td.message_stores.enabled = true
		td.message_stores.store_index[campaign.shard] = 0
		retained_registry_started = true
		retained_message := semantic_global_segmented_retained_message(campaign.workspace)
		retained_result, retained_sequence := append_or_deduplicate_message(retained_store, &retained_message)
		if retained_result != .Appended || retained_sequence != 1 {
			return "global segmented deferred retained append foundation failed"
		}
		persistence.force_fsync(&retained_store.wal)
		if !rotate_message_store(retained_store, NRC_SIM_TIME_EPOCH_NANOS + i64(time.Hour)) ||
		   retained_store.high_water != 1 ||
		   len(retained_store.segments) != 1 {
			return "global segmented deferred retained sealed foundation failed"
		}

		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		update := pr.UpdateTaskRequest {
			conv_id              = pr.WORKSPACE_DATA_ID,
			task_id              = 1,
			title                = transmute([]byte)string("updated cross-domain task"),
			description          = transmute([]byte)string("update appended during create fsync"),
			status               = .Done,
			assignee             = transmute([]byte)string("peer"),
			priority             = 7,
			color                = .Gold,
			external_ref         = transmute([]byte)string("SIM-UPDATE-1"),
			due_at               = NRC_SIM_TIME_EPOCH_NANOS + 60_000_000_000,
			preserve_attachments = true,
			project              = transmute([]byte)string("updated-simulation"),
			correlation_id       = 0xD00D,
		}
		if !semantic_transport_persistence_enqueue_update(&campaign, update, 5, 17) {
			return "global segmented deferred task update failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if writer.wal.record_count != 1 ||
		   writer.wal.durable_record_count != 0 ||
		   !semantic_transport_persistence_updated_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) {
			return "global segmented deferred live task update differs"
		}
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != 1 {
			return "global segmented deferred task fsync submission failed"
		}
		rolled_generation := writer.manifest.active_generation
		writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES

		create_req := pr.CreateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_type       = .Document,
			payload_encoding = .Plain,
			payload_raw_len  = 4,
			payload          = transmute([]byte)string("body"),
			correlation_id   = 0xDA01,
		}
		update_req := pr.UpdateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_id         = 1,
			payload_encoding = .Plain,
			payload_raw_len  = 7,
			payload          = transmute([]byte)string("updated"),
			correlation_id   = 0xDA02,
		}
		edge_req := pr.CreateEdgeRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			source_type    = .Task,
			source_id      = 1,
			target_type    = .Asset,
			target_id      = 1,
			relation       = .References,
			correlation_id = 0xDA03,
		}
		if !semantic_transport_persistence_enqueue_create_asset(&campaign, create_req, 3, 11) ||
		   !semantic_deferred_rotation_enqueue_update_asset(&campaign, update_req) ||
		   !semantic_transport_persistence_enqueue_create_edge(&campaign, edge_req, 7, 19) {
			return "global segmented deferred asset/edge chain failed to enqueue"
		}
		edge_final_receive_id: u64
		for queued in campaign.ctx.sim.world.events {
			if queued.domain != .Receive do continue
			receive, receive_ok := queued.payload.(Sim_Receive_Event)
			if receive_ok && receive.ctx.handle == campaign.requester.handle && queued.id > edge_final_receive_id {
				edge_final_receive_id = queued.id
			}
		}
		if edge_final_receive_id == 0 do return "global segmented deferred edge receive identity missing"
		if !semantic_global_segmented_output_prefix_exact(&campaign) {
			return "global segmented deferred initial response prefix order or semantics differed"
		}

		task_fsync_completed := false
		asset_fsync_submitted := false
		asset_fsync_completed := false
		later_segment := Shard_Segment_Descriptor{.Generation_WAL, rolled_generation}
		later_rotation_observed := false
		deferred_chain_observed := false
		stale_rebase_observed := false
		edge_request_completed := false
		retained_read_started := false
		retained_read_completed := false
		retained_append_staged := false
		retained_flush_completed := false
		retained_fsync_completed := false
		dispatched_count := 0
		choice_index := 0
		crash_event_id: u64
		crash_incarnation_before := campaign.ctx.sim.world.process_incarnation
		if rank_process_crash {
			crash_event_id = sim_world_enqueue_process_crash(&campaign.ctx.sim.world, campaign.ctx.sim.world.now)
			if crash_event_id == 0 do return "global segmented deferred process crash failed to enqueue"
		}
		crash_dispatched := false
		crash_incarnation_after: u64
		fsync_action := Semantic_Fsync_Submit_Action {
			campaign         = &campaign,
			expected_records = 3,
		}
		fsync_action_event_id: u64
		retained_flush_action := Semantic_Retained_Flush_Action {
			store = retained_store,
		}
		retained_flush_action_event_id: u64
		for rank_process_crash || dispatched_count < crash_after_events {
			writer = semantic_transport_persistence_writer(&campaign)
			if writer == nil do return "global segmented deferred scheduled writer missing"
			conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
			asset := conv != nil ? conv.assets[1] : nil
			edge := conv != nil ? conv.edges[1] : nil
			asset_chain_applied := semantic_deferred_rotation_asset_exact(asset, "updated") && semantic_deferred_rotation_edge_exact(edge)
			can_submit_asset_fsync :=
				asset_chain_applied &&
				!writer.fsync_in_flight &&
				writer.wal.record_count == 3 &&
				writer.wal.durable_record_count == 0 &&
				!asset_fsync_submitted
			if can_submit_asset_fsync && fsync_action_event_id == 0 {
				fsync_action_event_id = sim_world_enqueue_driver_action(&campaign.ctx.sim.world, &fsync_action, semantic_submit_fsync_driver_action)
				if fsync_action_event_id == 0 do return "global segmented deferred fsync driver action failed to enqueue"
			}
			runnable_count := sim_world_prepare_runnable(&campaign.ctx.sim.world)
			if runnable_count == 0 do break
			choice := choices[choice_index % len(choices)]
			choice_index += 1
			selected := int(choice) * runnable_count / 256
			index := sim_world_runnable_rank_index(&campaign.ctx.sim.world, selected)
			if index < 0 do return "global segmented deferred runnable rank missing"
			event := campaign.ctx.sim.world.events[index]
			fsync_records: u64
			retained_fsync_event := false
			if event.domain == .Fsync {
				completion, completion_ok := event.payload.(Sim_Fsync_Completion)
				if !completion_ok {
					return "global segmented deferred fsync payload differs"
				}
				retained_fsync_event = completion.user == rawptr(retained_store)
				if !retained_fsync_event do fsync_records = writer.fsync_snapshot.record_count
			}
			result_after_later_rotation := event.domain == .Compaction_Result && later_rotation_observed
			manifest_generation_before_result := writer.manifest.manifest_generation
			requester_outbound_before := semantic_global_segmented_outbound_count(&campaign, campaign.requester)
			peer_outbound_before := semantic_global_segmented_outbound_count(&campaign, campaign.peer)
			if !sim_world_dispatch_event(&campaign.ctx.sim.world, index) {
				return "global segmented deferred event dispatch failed"
			}
			if event.id == crash_event_id {
				if event.domain != .Process_Crash || campaign.ctx.sim.world.process_incarnation <= crash_incarnation_before {
					return "global segmented deferred crash event did not advance the process incarnation"
				}
				crash_dispatched = true
				crash_incarnation_after = campaign.ctx.sim.world.process_incarnation
				dispatched_count += 1
				break
			}
			if event.id == edge_final_receive_id {
				edge_request_completed = true
				semantic_global_segmented_retry_retained(&campaign)
				if batch_retained_callback_wave do semantic_global_segmented_append_retained(&campaign)
				expected_retained_io := batch_retained_callback_wave ? u8(2) : u8(1)
				if retained_store.async_readers != 1 ||
				   campaign.requester.retained_io != expected_retained_io ||
				   nrc_sim_file_read_count(&campaign.ctx.sim) != 1 {
					return fmt.tprintf(
						"global segmented deferred retained lookup did not enter scheduled storage: readers=%d retained_io=%d reads=%d expected_io=%d",
						retained_store.async_readers,
						campaign.requester.retained_io,
						nrc_sim_file_read_count(&campaign.ctx.sim),
						expected_retained_io,
					)
				}
				retained_read_started = true
				if batch_retained_callback_wave {
					if wave_diagnostic := semantic_retained_prepare_batched_callback_wave(&campaign, retained_store); wave_diagnostic != "" {
						return wave_diagnostic
					}
					retained_read_completed = true
					retained_append_staged = true
					retained_flush_completed = !retained_store.write_in_flight
				}
			}
			if event.id == fsync_action_event_id {
				if fsync_action.diagnostic != "" do return fsync_action.diagnostic
				if !fsync_action.submitted || asset_fsync_submitted {
					return "global segmented deferred fsync driver action submission differs"
				}
				asset_fsync_submitted = true
			}
			if event.id == retained_flush_action_event_id {
				if retained_flush_action.diagnostic != "" do return retained_flush_action.diagnostic
				if !retained_flush_action.flushed || retained_flush_completed {
					return "global segmented deferred retained flush action completion differed"
				}
			}
			// Write submission is not publication. Let File_Write compete with
			// crash, reads, sends and fsyncs in the same runnable-rank scheduler.
			if !retained_flush_completed && retained_append_staged && retained_store.high_water == 2 && !retained_store.write_in_flight {
				if !retained_store.fsync_in_flight ||
				   retained_store.wal.write_count != 1 ||
				   retained_store.wal.record_count != 1 ||
				   retained_store.wal.durable_record_count != 0 ||
				   retained_store.fsync_snapshot.record_count != 1 ||
				   retained_store.fsync_snapshot.pending_bytes != retained_store.wal.pending_bytes ||
				   retained_store.fsync_snapshot.last_hash != retained_store.wal.last_hash ||
				   semantic_retained_fsync_event_count(&campaign, retained_store) != 1 {
					return "global segmented deferred retained write completion snapshot differed"
				}
				if semantic_global_segmented_outbound_count(&campaign, campaign.requester) != requester_outbound_before + 1 ||
				   semantic_global_segmented_outbound_count(&campaign, campaign.peer) != peer_outbound_before + 1 {
					return "global segmented deferred retained append emitted the wrong outbound ownership"
				}
				retained_flush_completed = true
				if crash_after_retained_flush {
					if retained_store.wal.record_count != 1 || retained_store.wal.durable_record_count != 0 {
						return "global segmented deferred retained pre-fsync crash boundary differed"
					}
					crash_event_id = sim_world_enqueue_process_crash(&campaign.ctx.sim.world, campaign.ctx.sim.world.now)
					crash_index := sim_world_domain_event_index(&campaign.ctx.sim.world, .Process_Crash, 0)
					if crash_event_id == 0 || crash_index < 0 || !sim_world_dispatch_event(&campaign.ctx.sim.world, crash_index) {
						return "global segmented deferred retained pre-fsync process crash failed"
					}
					crash_dispatched = true
					crash_incarnation_after = campaign.ctx.sim.world.process_incarnation
					dispatched_count += 1
					break
				}
			}
			if event.domain == .Fsync {
				if retained_fsync_event {
					if !retained_flush_completed || retained_fsync_completed || retained_store.wal.durable_record_count != 1 {
						return "global segmented deferred retained fsync completion differed"
					}
					retained_fsync_completed = true
				} else {
					switch fsync_records {
					case 1:
						if task_fsync_completed do return "global segmented deferred task fsync completed twice"
						task_fsync_completed = true
					case 3:
						if !asset_fsync_submitted || asset_fsync_completed do return "global segmented deferred asset fsync completion differs"
						asset_fsync_completed = true
					case:
						return "global segmented deferred unexpected fsync snapshot"
					}
				}
			}
			if event.domain == .Compaction_Result {
				if sync.atomic_load(&campaign.server.closing) || writer.poisoned || writer.manifest.manifest_generation <= manifest_generation_before_result {
					return "global segmented deferred cleaner publication failed"
				}
				if result_after_later_rotation do stale_rebase_observed = true
			}
			if retained_read_started && !retained_read_completed && retained_store.async_readers == 0 {
				if campaign.requester.retained_io != 0 || len(retained_store.pending_appends) != 0 || retained_store.high_water != 1 {
					return "global segmented deferred retained duplicate completion changed ownership or state"
				}
				if semantic_global_segmented_outbound_count(&campaign, campaign.requester) != requester_outbound_before + 1 ||
				   semantic_global_segmented_outbound_count(&campaign, campaign.peer) != peer_outbound_before {
					return "global segmented deferred retained duplicate emitted the wrong outbound ownership"
				}
				retained_read_completed = true
				semantic_global_segmented_append_retained(&campaign)
				if len(retained_store.pending_appends) != 1 ||
				   td.message_stores.pending_write_count != 1 ||
				   campaign.requester.retained_io != 1 ||
				   retained_store.high_water != 1 {
					return "global segmented deferred retained append did not stage"
				}
				retained_append_staged = true
				retained_flush_action_event_id = sim_world_enqueue_driver_action(
					&campaign.ctx.sim.world,
					&retained_flush_action,
					semantic_retained_flush_driver_action,
				)
				if retained_flush_action_event_id == 0 do return "global segmented deferred retained flush action failed to enqueue"
			}
			dispatched_count += 1

			writer = semantic_transport_persistence_writer(&campaign)
			if len(writer.deferred_requests) > 0 {
				if len(writer.deferred_requests) > 3 || int(campaign.requester.deferred_shard_requests) != len(writer.deferred_requests) {
					return "global segmented deferred request ownership differs"
				}
				if len(writer.deferred_requests) == 3 {
					if pr.get_opcode(writer.deferred_requests[0].payload) != .C_CreateAsset ||
					   pr.get_opcode(writer.deferred_requests[1].payload) != .C_UpdateAsset ||
					   pr.get_opcode(writer.deferred_requests[2].payload) != .C_CreateEdge {
						return "global segmented deferred request FIFO differs"
					}
					deferred_chain_observed = true
				}
			}
			if writer.manifest.active_generation != rolled_generation {
				later_rotation_observed = true
			}
			if later_rotation_observed && !semantic_global_segmented_catalog_contains(writer, later_segment) {
				return "global segmented deferred cleaner lost the later catalog member"
			}
			conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
			if conv == nil ||
			   writer.floors.task != 1 ||
			   writer.floors.asset > 1 ||
			   len(conv.assets) > 1 ||
			   !semantic_transport_persistence_updated_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) {
				return "global segmented deferred live semantic state differs"
			}
			if len(conv.assets) == 1 &&
			   !semantic_deferred_rotation_asset_exact(conv.assets[1], "body") &&
			   !semantic_deferred_rotation_asset_exact(conv.assets[1], "updated") {
				return "global segmented deferred live asset prefix differs"
			}
			edge_deferred :=
				len(writer.deferred_requests) == 3 &&
				int(campaign.requester.deferred_shard_requests) == 3 &&
				writer.deferred_requests[2].connection.handle == campaign.requester.handle &&
				semantic_deferred_rotation_edge_request_exact(writer.deferred_requests[2].payload, edge_req)
			if !edge_deferred {
				for request in writer.deferred_requests {
					if pr.get_opcode(request.payload) == .C_CreateEdge {
						return "global segmented deferred edge ownership or payload differs"
					}
				}
			}
			if !edge_request_completed || edge_deferred {
				if writer.floors.edge != 0 || td.edge_seq != 0 || !semantic_deferred_rotation_adjacency_exact(conv, false) {
					return "global segmented deferred edge became visible before apply"
				}
			} else if writer.wal.record_count != 3 || writer.floors.edge != 1 || td.edge_seq != 1 || !semantic_deferred_rotation_adjacency_exact(conv, true) {
				return "global segmented deferred applied edge state differs"
			}
			if retained_flush_completed {
				if retained_store.high_water != 2 ||
				   retained_store.wal.record_count != 1 ||
				   len(retained_store.pending_appends) != 0 ||
				   campaign.requester.retained_io != 0 {
					return "global segmented deferred retained flushed state differs"
				}
			} else if retained_append_staged &&
			   (retained_store.high_water != 1 || len(retained_store.pending_appends) != 1 || campaign.requester.retained_io != 1) {
				return "global segmented deferred retained staged state differs"
			}
			if retained_store.write_in_flight &&
			   (retained_store.wal.record_count != 0 ||
					   retained_store.wal.durable_record_count != 0 ||
					   retained_store.fsync_in_flight ||
					   td.message_stores.pending_write_count != 0 ||
					   sim_world_domain_event_index(&campaign.ctx.sim.world, .File_Write, 0) < 0) {
				return "global segmented deferred retained queued write state differs"
			}
			if !semantic_global_segmented_output_prefix_exact(&campaign) {
				return "global segmented deferred response prefix order or semantics differed"
			}
		}
		if rank_process_crash && !crash_dispatched {
			return "global segmented deferred ranked process crash did not dispatch"
		}
		if crash_after_retained_flush && !crash_dispatched {
			return "global segmented deferred retained pre-fsync crash boundary was not reached"
		}
		if require_asset_fsync_completed && !asset_fsync_completed {
			return "global segmented deferred fixed schedule did not complete the fsync driver action"
		}
		if require_retained_read_completed && !retained_read_completed {
			return "global segmented deferred fixed schedule did not complete the retained file-read chain"
		}
		if require_retained_fsync_completed && !retained_fsync_completed {
			return "global segmented deferred fixed schedule did not complete the retained fsync"
		}
		switch expected_crash_phase {
		case .Any:
		case .Immediate:
			if dispatched_count != 1 || task_fsync_completed || edge_request_completed || later_rotation_observed {
				return "global segmented deferred fixed immediate crash phase was not reached"
			}
		case .Late:
			if !task_fsync_completed || !edge_request_completed || !later_rotation_observed {
				return "global segmented deferred fixed late crash phase was not reached"
			}
		}
		if require_stale_rebase && !deferred_chain_observed {
			return "global segmented deferred fixed schedule did not reach deferred request ownership"
		}
		if require_stale_rebase && !stale_rebase_observed {
			return "global segmented deferred fixed schedule did not publish an older cleaner result over the later segment"
		}
		if !semantic_global_segmented_output_prefix_exact(&campaign) {
			return "global segmented deferred final response prefix order or semantics differed"
		}
		// A crash immediately after write publication must not expose that
		// message's ACK or broadcast before its retained fsync completes.
		expected_requester_frames := retained_fsync_completed ? 6 : 5
		expected_peer_frames := retained_fsync_completed ? 5 : 4
		if require_retained_outputs_complete &&
		   (nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != expected_requester_frames ||
				   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != expected_peer_frames) {
			return "global segmented deferred retained fixed output ledger was incomplete"
		}

		writer = semantic_transport_persistence_writer(&campaign)
		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign, crash_dispatched)
		if crash_diagnostic != "" do return crash_diagnostic
		if retained_store.async_readers != 0 ||
		   len(retained_store.pending_appends) != 0 ||
		   len(retained_store.deferred_appends) != 0 ||
		   td.message_stores.pending_write_count != 0 {
			return "global segmented deferred retained crash cleanup leaked ownership"
		}
		expected_retained_high_water := retained_fsync_completed ? u64(2) : u64(1)
		crash_message_store_for_test(retained_store)
		if !init_message_store_with_storage(
			   retained_store,
			   sim_world_storage_context(&campaign.ctx.sim.world),
			   campaign.shard_dir,
			   campaign.shard,
			   24 * time.Hour,
			   0,
		   ) ||
		   retained_store.high_water != expected_retained_high_water ||
		   len(retained_store.segments) != 1 ||
		   retained_store.wal.record_count != expected_retained_high_water - 1 {
			return "global segmented deferred retained first recovery differed"
		}
		if crash_dispatched && campaign.ctx.sim.world.process_incarnation != crash_incarnation_after {
			return "global segmented deferred reopen crashed the world twice"
		}
		writer = semantic_transport_persistence_writer(&campaign)
		expected_floors := Shard_High_Water_Requirements {
			task  = 1,
			asset = asset_fsync_completed ? 1 : 0,
			edge  = asset_fsync_completed ? 1 : 0,
		}
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if !replay_ok ||
		   writer == nil ||
		   floors != expected_floors ||
		   writer.floors != floors ||
		   td.task_seq != 1 ||
		   td.asset_seq != expected_floors.asset ||
		   td.edge_seq != expected_floors.edge ||
		   conv == nil ||
		   len(conv.tasks) != 1 ||
		   len(conv.assets) != int(expected_floors.asset) ||
		   len(conv.edges) != int(expected_floors.edge) ||
		   !semantic_deferred_rotation_adjacency_exact(conv, asset_fsync_completed) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "global segmented deferred first recovery shape differs"
		}
		if stale_rebase_observed && !semantic_global_segmented_catalog_contains(writer, later_segment) {
			return "global segmented deferred first recovery lost the authoritative later segment"
		}
		if task_fsync_completed {
			if !semantic_transport_persistence_updated_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) {
				return "global segmented deferred first recovery lost durable task update"
			}
		} else if !semantic_transport_persistence_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) {
			return "global segmented deferred first recovery selected an undurable task update"
		}
		if asset_fsync_completed && !semantic_deferred_rotation_asset_exact(conv.assets[1], "updated") {
			return "global segmented deferred first recovery lost durable asset chain"
		}
		if asset_fsync_completed && !semantic_deferred_rotation_edge_exact(conv.edges[1]) {
			return "global segmented deferred first recovery lost durable edge"
		}

		if !semantic_deferred_rotation_install_clients(&campaign) do return "global segmented deferred continuation clients failed to install"
		semantic_global_segmented_retry_retained(&campaign)
		if retained_store.async_readers != 1 || nrc_sim_file_read_count(&campaign.ctx.sim) != 1 {
			return "global segmented deferred retained continuation lookup did not schedule"
		}
		for nrc_sim_run_next_file_read(&campaign.ctx.sim) {}
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		retained_ack_payload, retained_ack_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, 0))
		if retained_store.async_readers != 0 ||
		   retained_store.high_water != expected_retained_high_water ||
		   len(retained_store.pending_appends) != 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 1 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 ||
		   !retained_ack_ok ||
		   !semantic_global_segmented_retained_ack_exact(retained_ack_payload) {
			return fmt.tprintf(
				"global segmented deferred retained continuation dedup/output differed: readers=%d high=%d pending=%d requester_frames=%d peer_frames=%d ack_payload=%v ack_exact=%v",
				retained_store.async_readers,
				retained_store.high_water,
				len(retained_store.pending_appends),
				nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock),
				nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock),
				retained_ack_ok,
				semantic_global_segmented_retained_ack_exact(retained_ack_payload),
			)
		}
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		second_was_durable := expected_retained_high_water == 2
		semantic_global_segmented_append_retained(&campaign)
		if len(retained_store.pending_appends) != 1 || td.message_stores.pending_write_count != 1 || campaign.requester.retained_io != 1 {
			return "global segmented deferred retained recovery retry did not stage"
		}
		retained_store.commit_pending = true
		retained_store.commit_started = {}
		retained_retry_work, retained_retry_ok := flush_pending_retained_message_writes(&td.message_stores)
		// Recovery is deliberately sequential: finish the retry's write, but
		// retain the separate fsync boundary and independently expected prefix.
		if !simulation_test_flush_message_writes(&campaign.ctx.sim) do return "global segmented deferred retained recovery retry write failed"
		if !retained_retry_work || !retained_retry_ok || retained_store.high_water != 2 {
			return "global segmented deferred retained recovery retry did not publish"
		}
		if second_was_durable {
			if retained_store.fsync_in_flight do return "global segmented deferred durable retained retry scheduled fsync"
		} else if !retained_store.fsync_in_flight || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {
			return "global segmented deferred missing retained retry did not become durable"
		}
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		retained_retry_ack, retained_retry_ack_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, 0))
		retained_retry_peer_frames := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		if retained_store.wal.record_count != 1 ||
		   retained_store.wal.durable_record_count != 1 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 1 ||
		   !retained_retry_ack_ok ||
		   !semantic_global_segmented_retained_ack_exact(retained_retry_ack, 0xDA06, 2) ||
		   retained_retry_peer_frames != (second_was_durable ? 0 : 1) {
			return "global segmented deferred retained recovery retry state/output differed"
		}
		if !second_was_durable {
			retained_retry_page, retained_retry_page_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.peer.sock, 0))
			if !retained_retry_page_ok || !semantic_global_segmented_retained_page_exact(retained_retry_page) {
				return "global segmented deferred retained recovery retry broadcast differed"
			}
		}

		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		semantic_global_segmented_continue_retained(&campaign)
		if len(retained_store.pending_appends) != 1 || td.message_stores.pending_write_count != 1 {
			return "global segmented deferred retained continuation did not stage"
		}
		retained_store.commit_pending = true
		retained_store.commit_started = {}
		retained_continuation_work, retained_continuation_ok := flush_pending_retained_message_writes(&td.message_stores)
		if !simulation_test_flush_message_writes(&campaign.ctx.sim) do return "global segmented deferred retained continuation write failed"
		if !retained_continuation_work ||
		   !retained_continuation_ok ||
		   !retained_store.fsync_in_flight ||
		   !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {
			return "global segmented deferred retained continuation did not become durable"
		}
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		retained_continuation_ack, retained_continuation_ack_ok := nrc_sim_frame_protocol_payload(
			nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, 0),
		)
		retained_continuation_page, retained_continuation_page_ok := nrc_sim_frame_protocol_payload(
			nrc_sim_client_frame(&campaign.ctx.sim, campaign.peer.sock, 0),
		)
		if retained_store.high_water != 3 ||
		   retained_store.wal.record_count != 2 ||
		   retained_store.wal.durable_record_count != 2 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 1 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 1 ||
		   !retained_continuation_ack_ok ||
		   !semantic_global_segmented_retained_ack_exact(retained_continuation_ack, 0xDA07, 3) ||
		   !retained_continuation_page_ok ||
		   !semantic_global_segmented_retained_page_exact(retained_continuation_page, 3, "retained global continuation") {
			return "global segmented deferred retained continuation state/output differed"
		}
		continuation_req := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("continued after global segmented crash"),
			description    = transmute([]byte)string("must survive the second restart"),
			status         = .Todo,
			correlation_id = 0xDA04,
		}
		if !semantic_transport_persistence_enqueue_create(&campaign, continuation_req, 2, 13) {
			return "global segmented deferred continuation failed to enqueue"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {
			return "global segmented deferred continuation did not become durable"
		}
		continuation_order := task_fsync_completed ? u16(0) : u16(1)
		continued := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)
		if !semantic_global_segmented_continued_task_exact(continued, continuation_order) {
			return "global segmented deferred continuation state differs"
		}

		floors, replay_ok, crash_diagnostic = semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		crash_message_store_for_test(retained_store)
		if !init_message_store_with_storage(
			   retained_store,
			   sim_world_storage_context(&campaign.ctx.sim.world),
			   campaign.shard_dir,
			   campaign.shard,
			   24 * time.Hour,
			   0,
		   ) ||
		   retained_store.high_water != 3 ||
		   len(retained_store.segments) != 1 ||
		   retained_store.wal.record_count != 2 {
			return "global segmented deferred retained second recovery differed"
		}
		writer = semantic_transport_persistence_writer(&campaign)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		expected_floors.task = 2
		if !replay_ok ||
		   writer == nil ||
		   floors != expected_floors ||
		   writer.floors != floors ||
		   td.task_seq != 2 ||
		   td.asset_seq != expected_floors.asset ||
		   td.edge_seq != expected_floors.edge ||
		   conv == nil ||
		   len(conv.tasks) != 2 ||
		   len(conv.assets) != int(expected_floors.asset) ||
		   len(conv.edges) != int(expected_floors.edge) ||
		   !semantic_deferred_rotation_adjacency_exact(conv, asset_fsync_completed) ||
		   !semantic_global_compaction_task_indexes_exact(conv) {
			return "global segmented deferred second recovery shape differs"
		}
		if task_fsync_completed {
			if !semantic_transport_persistence_updated_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) {
				return "global segmented deferred second recovery lost durable task update"
			}
		} else if !semantic_transport_persistence_task_exact(get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1)) {
			return "global segmented deferred second recovery selected an undurable task update"
		}
		continued = get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 2)
		if !semantic_global_segmented_continued_task_exact(continued, continuation_order) {
			return "global segmented deferred second recovery lost continuation"
		}
		if stale_rebase_observed && !semantic_global_segmented_catalog_contains(writer, later_segment) {
			return "global segmented deferred second recovery lost the authoritative later segment"
		}
		if asset_fsync_completed && !semantic_deferred_rotation_asset_exact(conv.assets[1], "updated") {
			return "global segmented deferred second recovery lost durable asset chain"
		}
		if asset_fsync_completed && !semantic_deferred_rotation_edge_exact(conv.edges[1]) {
			return "global segmented deferred second recovery lost durable edge"
		}
		return ""
	}

	semantic_deferred_rotation_run :: proc(outcome: Semantic_Deferred_Rotation_Outcome) -> string {
		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "deferred-segmented-rotation", 1, 7, thread_index = 0, virtual_storage = true)
		defer semantic_transport_persistence_campaign_end(&campaign)
		if diagnostic != "" do return diagnostic

		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 {
			return "deferred rotation published the initial task before fsync"
		}
		writer := semantic_transport_persistence_writer(&campaign)
		if writer == nil || writer.wal.record_count != 1 || writer.wal.durable_record_count != 0 {
			return "deferred rotation initial semantic prefix differed"
		}
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !writer.fsync_in_flight || nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 1 {
			return "deferred rotation initial fsync was not submitted"
		}
		writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES

		create_req := pr.CreateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_type       = .Document,
			payload_encoding = .Plain,
			payload_raw_len  = 4,
			payload          = transmute([]byte)string("body"),
			correlation_id   = 0xDA01,
		}
		update_req := pr.UpdateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_id         = 1,
			payload_encoding = .Plain,
			payload_raw_len  = 7,
			payload          = transmute([]byte)string("updated"),
			correlation_id   = 0xDA02,
		}
		if !semantic_transport_persistence_enqueue_create_asset(&campaign, create_req, 3, 11) ||
		   !semantic_deferred_rotation_enqueue_update_asset(&campaign, update_req) {
			return "deferred rotation requests were not enqueued"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if conv == nil ||
		   len(conv.assets) != 0 ||
		   writer.wal.record_count != 1 ||
		   len(writer.deferred_requests) != 2 ||
		   campaign.requester.deferred_shard_requests != 2 ||
		   campaign.requester.pending_io != 2 {
			return "deferred rotation requests became visible before fsync completion"
		}

		if outcome == .Crash_Before_Completion {
			discard_shard_deferred_requests(writer)
		} else {
			err := linux.Errno.NONE
			if outcome == .Error do err = .EIO
			previous_logger := context.logger
			if err != .NONE do context.logger = log.nil_logger()
			completed := nrc_sim_run_next_fsync_completion(&campaign.ctx.sim, err)
			context.logger = previous_logger
			if !completed do return "deferred rotation fsync completion was missing"
			if len(writer.deferred_requests) != 0 || campaign.requester.deferred_shard_requests != 0 {
				return "deferred rotation completion retained queued request ownership"
			}
		}

		if outcome == .Success {
			if writer.poisoned ||
			   !writer.manifest.segmented ||
			   writer.manifest.sealed_present ||
			   writer.catalog_segments != 1 ||
			   writer.wal.record_count != 2 ||
			   writer.wal.durable_record_count != 0 ||
			   !semantic_deferred_rotation_asset_exact(conv.assets[1], "updated") {
				return "successful deferred rotation did not publish and apply exact FIFO state"
			}
			nrc_sim_run_all_send_completions(&campaign.ctx.sim)
			if diagnostic = semantic_transport_persistence_check_frames(&campaign); diagnostic != "" do return diagnostic
			nrc_sim_clear_inboxes(&campaign.ctx.sim)
			writer.commit_started = {}
			did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != 2 {
				return "successful deferred rotation active WAL did not become durable"
			}
			nrc_sim_run_all_send_completions(&campaign.ctx.sim)
			if diagnostic = semantic_deferred_rotation_check_responses(&campaign); diagnostic != "" do return diagnostic
			if campaign.requester.pending_io != 0 ||
			   campaign.peer.pending_io != 0 ||
			   connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before ||
			   td.spool.invalid_release_count != campaign.invalid_releases_before {
				return "successful deferred rotation did not balance transport ownership"
			}
		} else if outcome == .Error {
			if !writer.poisoned ||
			   writer.wal.enabled ||
			   !sync.atomic_load(&campaign.server.closing) ||
			   !sync.atomic_load(&campaign.server.fatal_storage_error) {
				return "deferred rotation fsync error did not poison process state"
			}
		} else if writer.fsync_in_flight == false || nrc_sim_fsync_completion_count(&campaign.ctx.sim) != 1 {
			return "deferred rotation crash branch lost its pending fsync"
		}
		if outcome != .Success &&
		   (len(conv.assets) != 0 ||
				   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != 0 ||
				   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != 0 ||
				   campaign.requester.pending_io != 0) {
			return "failed deferred rotation applied or emitted a queued mutation"
		}

		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		expected_initial := outcome == .Success
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if !replay_ok ||
		   writer == nil ||
		   floors != (expected_initial ? Shard_High_Water_Requirements{task = 1, asset = 1} : Shard_High_Water_Requirements{}) ||
		   (get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, 1) != nil) != expected_initial ||
		   (conv != nil && len(conv.assets) != 0) != expected_initial {
			return "deferred rotation first restart differed from durable subset"
		}
		if expected_initial && (conv == nil || !semantic_deferred_rotation_asset_exact(conv.assets[1], "updated")) {
			return "deferred rotation first restart lost updated asset"
		}

		if !semantic_deferred_rotation_install_clients(&campaign) do return "install deferred rotation continuation clients"
		continuation_id := pr.TaskID(floors.task + 1)
		continuation_req := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("continued after deferred rotation"),
			description    = transmute([]byte)string("must survive the second restart"),
			status         = .Todo,
			correlation_id = 0xDA03,
		}
		if !semantic_transport_persistence_enqueue_create(&campaign, continuation_req, 2, 13) {
			return "enqueue deferred rotation continuation"
		}
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) {
			return "deferred rotation continuation did not become durable"
		}
		continued := get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, continuation_id)
		if continued == nil || string(continued.title) != "continued after deferred rotation" {
			return "deferred rotation continuation state differed"
		}

		floors, replay_ok, crash_diagnostic = semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		conv = get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if !replay_ok ||
		   writer == nil ||
		   floors.task != u64(continuation_id) ||
		   floors.asset != (expected_initial ? 1 : 0) ||
		   writer.wal.durable_record_count != (expected_initial ? 3 : 1) {
			return "deferred rotation second restart durable state differed"
		}
		continued = get_task(campaign.workspace, pr.WORKSPACE_DATA_ID, continuation_id)
		if continued == nil || string(continued.title) != "continued after deferred rotation" {
			return "deferred rotation second restart lost continuation"
		}
		if expected_initial {
			if conv == nil || !semantic_deferred_rotation_asset_exact(conv.assets[1], "updated") {
				return "deferred rotation second restart lost segmented asset state"
			}
		} else if conv != nil && len(conv.assets) != 0 {
			return "deferred rotation second restart recovered an undurable asset"
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
		ctx.sim.compaction_job_event_submission = true
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
		nrc_sim_clear_inboxes(&ctx.sim)
		store.rotation_pending = true
		if !retained_message_flush_store(store) || store.frozen == nil || !store.seal_in_flight {
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
		if !sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job) || !sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result) {
			return "retained lifecycle seal build/publication result failed"
		}
		_, flush_ok := flush_pending_retained_message_writes(&td.message_stores)
		if !simulation_test_flush_message_writes(&ctx.sim) do return "retained lifecycle seal publication write failed"
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
		nrc_sim_clear_inboxes(&ctx.sim)
		process_send_message_v2(conn, retry)
		_, retry_ok := flush_pending_retained_message_writes(&td.message_stores)
		if !simulation_test_flush_message_writes(&ctx.sim) do return "retained lifecycle recovered retry write failed"
		if !retry_ok || nrc_sim_file_read_count(&ctx.sim) == 0 do return "retained lifecycle recovered retry did not enter sealed lookup"
		for nrc_sim_run_next_file_read(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
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
	test_semantic_transport_persistence_mandatory_orders :: proc(t: ^testing.T) {
		previous_logger := context.logger
		requester_first := [?]Semantic_Transport_Persistence_Action {
			.Run_Receive,
			.Run_Receive,
			.Run_Receive,
			.Submit_Fsync,
			.Run_Fsync,
			.Run_Requester_Send,
			.Run_Peer_Send,
		}
		peer_first := [?]Semantic_Transport_Persistence_Action {
			.Run_Receive,
			.Run_Receive,
			.Run_Receive,
			.Submit_Fsync,
			.Run_Fsync,
			.Run_Peer_Send,
			.Run_Requester_Send,
		}
		fsync_error := [?]Semantic_Transport_Persistence_Action{.Run_Receive, .Run_Receive, .Run_Receive, .Submit_Fsync, .Run_Fsync}
		context.logger = log.nil_logger()
		diagnostics := [?]string {
			semantic_transport_persistence_run_fixed("requester-first", requester_first[:]),
			semantic_transport_persistence_run_fixed("peer-first", peer_first[:]),
			semantic_transport_persistence_run_fixed("fsync-error-no-sends", fsync_error[:], true),
		}
		context.logger = previous_logger
		for diagnostic in diagnostics do testing.expect_value(t, diagnostic, "")
	}

	@(test)
	test_deferred_protocol_fifo_crosses_segmented_rotation_outcomes :: proc(t: ^testing.T) {
		previous_logger := context.logger
		for outcome in Semantic_Deferred_Rotation_Outcome {
			context.logger = log.nil_logger()
			diagnostic := semantic_deferred_rotation_run(outcome)
			context.logger = previous_logger
			testing.expectf(t, diagnostic == "", "deferred segmented rotation outcome=%v failed: %s", outcome, diagnostic)
		}
	}

	@(test)
	test_hegel_semantic_transport_persistence_interleavings :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_semantic_transport_persistence_interleavings, nil, {test_cases = 64})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "semantic transport/persistence property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	@(test)
	test_semantic_transport_persistence_requester_close_reuse :: proc(t: ^testing.T) {
		testing.expect_value(t, semantic_transport_persistence_run_requester_close_reuse(), "")
	}

	@(test)
	test_hegel_semantic_stale_generation_storage_interleavings :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		oldest_first: [32]u8
		newest_first: [32]u8
		zero_splits: [4]u8
		max_splits: [4]u8
		for &choice in newest_first do choice = 255
		for &split in max_splits do split = 255
		testing.expect_value(t, semantic_stale_generation_storage_run(oldest_first[:], zero_splits[:]), "")
		testing.expect_value(t, semantic_stale_generation_storage_run(newest_first[:], max_splits[:]), "")
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_semantic_stale_generation_storage_interleavings, nil, {test_cases = 32})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "stale generation storage property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	prop_semantic_stale_generation_storage_interleavings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		choices: [32]u8
		splits: [4]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw stale generation runnable rank")
			choice = u8(drawn)
		}
		for &split in splits {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw stale generation receive split")
			split = u8(drawn)
		}
		if diagnostic := semantic_stale_generation_storage_run(choices[:], splits[:]); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf("stale generation storage failure: reason=%s choices=%v splits=%v\n", diagnostic, choices, splits)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	@(test)
	test_semantic_transport_persistence_compaction_publication :: proc(t: ^testing.T) {
		testing.expect_value(t, semantic_transport_persistence_run_compaction_publication(), "")
	}

	@(test)
	test_hegel_global_semantic_compaction_interleavings :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		oldest_first: [32]u8
		newest_first: [32]u8
		for &choice in newest_first do choice = 255
		testing.expect_value(t, semantic_global_compaction_run(oldest_first[:], .None, 1, 7), "")
		testing.expect_value(t, semantic_global_compaction_run(newest_first[:], .Before_Active_Fsync, 13, 29), "")
		testing.expect_value(t, semantic_global_compaction_run(oldest_first[:], .Before_Active_Fsync, 23, 41, .Update_Task), "")
		testing.expect_value(t, semantic_global_compaction_run(newest_first[:], .Before_Active_Fsync, 19, 37, .Delete_Task), "")
		testing.expect_value(t, semantic_global_compaction_run(oldest_first[:], .Before_Active_Fsync, 21, 39, .Delete_Task_Cascade), "")
		testing.expect_value(t, semantic_global_compaction_run(oldest_first[:], .Before_Compaction_Result, 31, 63), "")
		testing.expect_value(t, semantic_global_compaction_run(newest_first[:], .Before_Compaction_Result, 47, 95, .Update_Task), "")
		testing.expect_value(t, semantic_global_compaction_run(newest_first[:], .Before_Compaction_Result, 17, 27, .Delete_Task), "")
		testing.expect_value(t, semantic_global_compaction_run(newest_first[:], .Before_Compaction_Result, 25, 43, .Delete_Task_Cascade), "")
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_global_semantic_compaction_interleavings, nil, {test_cases = 24})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "global semantic compaction property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	@(test)
	test_hegel_global_dependent_compaction_histories :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		cascade_variants := [?]u8{1, 2, 0, 5}
		delete_recreate_variants := [?]u8{0, 7, 0, 0}
		zero: [64]u8
		maximal: [64]u8
		for &value in maximal do value = 255
		testing.expect_value(t, semantic_global_compaction_dependent_run(4, cascade_variants[:], zero[:], maximal[:], zero[:]), "")
		testing.expect_value(t, semantic_global_compaction_dependent_run(3, delete_recreate_variants[:], maximal[:], zero[:], maximal[:], true), "")
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_global_dependent_compaction_histories, nil, {test_cases = 24})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "global dependent compaction property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	@(test)
	test_hegel_global_segmented_deferred_interleavings :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		oldest_first: [32]u8
		newest_first: [32]u8
		composed_order: [32]u8
		for &choice in newest_first do choice = 255
		copy(composed_order[:10], []u8{205, 205, 205, 205, 205, 205, 205, 205, 0, 128})
		testing.expect_value(
			t,
			semantic_global_segmented_deferred_run(
				oldest_first[:],
				32,
				require_asset_fsync_completed = true,
				require_retained_read_completed = true,
				require_retained_fsync_completed = true,
				require_retained_outputs_complete = true,
			),
			"",
		)
		testing.expect_value(
			t,
			semantic_global_segmented_deferred_run(
				oldest_first[:],
				32,
				require_asset_fsync_completed = true,
				require_retained_read_completed = true,
				require_retained_fsync_completed = true,
				require_retained_outputs_complete = true,
				batch_retained_callback_wave = true,
			),
			"",
		)
		testing.expect_value(
			t,
			semantic_global_segmented_deferred_run(
				oldest_first[:],
				32,
				require_retained_read_completed = true,
				crash_after_retained_flush = true,
				require_retained_outputs_complete = true,
			),
			"",
		)
		testing.expect_value(t, semantic_global_segmented_deferred_run(composed_order[:], 32, true), "")
		testing.expect_value(t, semantic_global_segmented_deferred_run(newest_first[:], 8), "")
		testing.expect_value(t, semantic_global_segmented_deferred_run(oldest_first[:], 0, rank_process_crash = true, expected_crash_phase = .Late), "")
		testing.expect_value(t, semantic_global_segmented_deferred_run(newest_first[:], 0, rank_process_crash = true, expected_crash_phase = .Immediate), "")
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_global_segmented_deferred_interleavings, nil, {test_cases = 24})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "global segmented deferred property failed: err=%v interesting=%v", err, result.interesting_test_cases)
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

	@(test)
	test_semantic_transport_persistence_dependent_update_orders :: proc(t: ^testing.T) {
		testing.expect_value(t, semantic_update_campaign_crash_after_first_prefix(), "")
		fsyncs_first := [?]Semantic_Update_Action {
			.Run_Fsync,
			.Submit_Second_Fsync,
			.Run_Fsync,
			.Run_Requester_Send,
			.Run_Requester_Send,
			.Run_Peer_Send,
			.Run_Peer_Send,
		}
		sends_between_fsyncs := [?]Semantic_Update_Action {
			.Run_Fsync,
			.Run_Peer_Send,
			.Run_Requester_Send,
			.Submit_Second_Fsync,
			.Run_Fsync,
			.Run_Peer_Send,
			.Run_Requester_Send,
		}
		testing.expect_value(t, semantic_update_campaign_run_fixed("dependent-update-fsyncs-first", fsyncs_first[:]), "")
		testing.expect_value(t, semantic_update_campaign_run_fixed("dependent-update-sends-between-fsyncs", sends_between_fsyncs[:]), "")
	}

	@(test)
	test_hegel_semantic_transport_persistence_dependent_update_interleavings :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_semantic_transport_persistence_dependent_update_interleavings, nil, {test_cases = 64})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "dependent semantic update property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	@(test)
	test_hegel_semantic_multihop_shortest_path_durable_histories :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		oldest_first: [16]u8
		newest_first: [16]u8
		for &choice in newest_first do choice = 255
		testing.expect_value(t, semantic_multihop_shortest_path_run(oldest_first[:], false), "")
		testing.expect_value(t, semantic_multihop_shortest_path_run(newest_first[:], true), "")
		result, err := hgl.run(prop_semantic_multihop_shortest_path_durable_histories, nil, {test_cases = 24})
		testing.expectf(t, err == nil, "multi-hop shortest-path durable history property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	@(test)
	test_hegel_semantic_dependent_prefix_histories :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		zero: [8]u8
		maximal: [8]u8
		alternating_fsyncs: [8]u8
		cascade_variants: [8]u8
		graph_prefix_fsyncs: [8]u8
		cascade_prefix_fsyncs: [8]u8
		alternating_fsyncs[1] = 3
		alternating_fsyncs[2] = 1
		cascade_variants[0] = 1
		cascade_variants[1] = 2
		cascade_variants[2] = 3
		cascade_variants[3] = 4
		cascade_variants[4] = 55
		cascade_variants[5] = 3
		graph_prefix_fsyncs[1] = 3
		graph_prefix_fsyncs[2] = 1
		cascade_prefix_fsyncs[3] = 3
		cascade_prefix_fsyncs[4] = 1
		for &value in maximal do value = 255
		testing.expect_value(t, semantic_dependent_history_run(4, zero[:], zero[:], maximal[:], zero[:], zero[:]), "")
		testing.expect_value(t, semantic_dependent_history_run(4, zero[:], maximal[:], zero[:], maximal[:], alternating_fsyncs[:]), "")
		testing.expect_value(t, semantic_dependent_history_run(8, maximal[:], maximal[:], zero[:], maximal[:], maximal[:]), "")
		testing.expect_value(t, semantic_dependent_history_run(6, cascade_variants[:], zero[:], maximal[:], maximal[:], graph_prefix_fsyncs[:]), "")
		testing.expect_value(t, semantic_dependent_history_run(6, cascade_variants[:], maximal[:], zero[:], zero[:], cascade_prefix_fsyncs[:]), "")
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_semantic_dependent_prefix_histories, nil, {test_cases = 32})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "dependent prefix history property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	@(test)
	test_hegel_semantic_dependent_delete_recreate_histories :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		zero_splits: [8]u8
		max_splits: [8]u8
		zero_sends: [4]u8
		max_sends: [4]u8
		for &value in max_splits do value = 255
		for &value in max_sends do value = 255
		testing.expect_value(t, semantic_dependent_delete_recreate_run(zero_splits[:], max_sends[:]), "")
		testing.expect_value(t, semantic_dependent_delete_recreate_run(max_splits[:], zero_sends[:]), "")
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_semantic_dependent_delete_recreate_histories, nil, {test_cases = 32})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "dependent delete/recreate property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	@(test)
	test_hegel_semantic_dependent_cascade_histories :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		zero_splits: [10]u8
		max_splits: [10]u8
		zero_sends: [5]u8
		max_sends: [5]u8
		for &value in max_splits do value = 255
		for &value in max_sends do value = 255
		testing.expect_value(t, semantic_dependent_cascade_run(false, zero_splits[:], max_sends[:]), "")
		testing.expect_value(t, semantic_dependent_cascade_run(true, max_splits[:], zero_sends[:]), "")
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_semantic_dependent_cascade_histories, nil, {test_cases = 32})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "dependent cascade property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}

	prop_semantic_dependent_cascade_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		durable_cascade, outcome_err := hgl.draw_bool(tc)
		if outcome_err == .Stop_Test do return hgl.abort()
		if outcome_err != nil do return hgl.interesting("draw dependent cascade durable outcome")
		splits: [10]u8
		sends: [5]u8
		for &value in splits {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw dependent cascade receive split")
			value = u8(drawn)
		}
		for &value in sends {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw dependent cascade send choice")
			value = u8(drawn)
		}
		if diagnostic := semantic_dependent_cascade_run(durable_cascade, splits[:], sends[:]); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf("dependent cascade failure: reason=%s durable_cascade=%v splits=%v sends=%v\n", diagnostic, durable_cascade, splits, sends)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	prop_semantic_dependent_delete_recreate_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		splits: [8]u8
		sends: [4]u8
		for &value in splits {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw dependent delete/recreate receive split")
			value = u8(drawn)
		}
		for &value in sends {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw dependent delete/recreate send choice")
			value = u8(drawn)
		}
		if diagnostic := semantic_dependent_delete_recreate_run(splits[:], sends[:]); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf("dependent delete/recreate failure: reason=%s splits=%v sends=%v\n", diagnostic, splits, sends)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	prop_semantic_multihop_shortest_path_durable_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		durable_delete, durable_err := hgl.draw_bool(tc)
		if durable_err == .Stop_Test do return hgl.abort()
		if durable_err != nil do return hgl.interesting("draw multi-hop durable deletion")
		choices: [16]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw multi-hop receive split")
			choice = u8(drawn)
		}
		if diagnostic := semantic_multihop_shortest_path_run(choices[:], durable_delete); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf("multi-hop shortest-path failure: reason=%s durable_delete=%v choices=%v\n", diagnostic, durable_delete, choices)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	prop_semantic_dependent_prefix_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count_raw, op_count_err := hgl.draw_i64(tc, 4, 8)
		if op_count_err == .Stop_Test do return hgl.abort()
		if op_count_err != nil do return hgl.interesting("draw dependent history operation count")
		op_count := int(op_count_raw)
		variants, split_as, split_bs, send_choices, fsync_choices: [8]u8
		for index in 0 ..< op_count {
			destinations := [?]^u8{&variants[index], &split_as[index], &split_bs[index], &send_choices[index], &fsync_choices[index]}
			for destination in destinations {
				value, draw_err := hgl.draw_i64(tc, 0, 255)
				if draw_err == .Stop_Test do return hgl.abort()
				if draw_err != nil do return hgl.interesting("draw dependent history operation choice")
				destination^ = u8(value)
			}
		}
		if diagnostic := semantic_dependent_history_run(op_count, variants[:], split_as[:], split_bs[:], send_choices[:], fsync_choices[:]); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf(
					"dependent prefix history failure: reason=%s count=%d variants=%v split_as=%v split_bs=%v sends=%v fsyncs=%v\n",
					diagnostic,
					op_count,
					variants[:op_count],
					split_as[:op_count],
					split_bs[:op_count],
					send_choices[:op_count],
					fsync_choices[:op_count],
				)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	prop_semantic_transport_persistence_dependent_update_interleavings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		split_a, split_a_err := hgl.draw_i64(tc, 0, 255)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("draw dependent update first receive split")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 255)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("draw dependent update second receive split")

		campaign: Semantic_Update_Campaign
		diagnostic := semantic_update_campaign_begin(&campaign, "dependent-update-hegel", int(split_a), int(split_b))
		defer semantic_transport_persistence_campaign_end(&campaign.base)
		if diagnostic != "" do return hgl.interesting(diagnostic)
		actions: [4]Semantic_Update_Action
		for action_index in 0 ..< 12 {
			action_count := semantic_update_campaign_actions(&campaign, &actions)
			if action_count == 0 {
				diagnostic = semantic_update_campaign_restart(&campaign)
				if diagnostic != "" do return hgl.interesting(diagnostic)
				return hgl.valid()
			}
			choice, choice_err := hgl.draw_i64(tc, 0, i64(action_count - 1))
			if choice_err == .Stop_Test do return hgl.abort()
			if choice_err != nil do return hgl.interesting("draw next dependent semantic event")
			diagnostic = semantic_update_campaign_run_action(&campaign, actions[choice])
			if diagnostic != "" do return hgl.interesting(fmt.tprintf("dependent event %d: %s", action_index, diagnostic))
		}
		return hgl.interesting("dependent semantic update event campaign did not drain")
	}

	prop_semantic_transport_persistence_interleavings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		fsync_error, fsync_error_draw_err := hgl.draw_bool(tc)
		if fsync_error_draw_err == .Stop_Test do return hgl.abort()
		if fsync_error_draw_err != nil do return hgl.interesting("draw fsync completion result")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 255)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("draw first receive split")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 255)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("draw second receive split")

		campaign: Semantic_Transport_Persistence_Campaign
		diagnostic := semantic_transport_persistence_campaign_begin(&campaign, "hegel", int(split_a), int(split_b), fsync_error)
		defer semantic_transport_persistence_campaign_end(&campaign)
		if diagnostic != "" do return hgl.interesting(diagnostic)
		actions: [5]Semantic_Transport_Persistence_Action
		for action_index in 0 ..< 12 {
			action_count := semantic_transport_persistence_actions(&campaign, &actions)
			if action_count == 0 {
				diagnostic = semantic_transport_persistence_restart(&campaign)
				if diagnostic != "" do return hgl.interesting(diagnostic)
				return hgl.valid()
			}
			choice, choice_err := hgl.draw_i64(tc, 0, i64(action_count - 1))
			if choice_err == .Stop_Test do return hgl.abort()
			if choice_err != nil do return hgl.interesting("draw next semantic event")
			diagnostic = semantic_transport_persistence_run_action(&campaign, actions[choice])
			if diagnostic != "" do return hgl.interesting(fmt.tprintf("event %d: %s", action_index, diagnostic))
		}
		return hgl.interesting("semantic event campaign did not drain")
	}

	prop_global_semantic_compaction_interleavings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		crash_raw, crash_err := hgl.draw_i64(tc, 0, i64(len(Semantic_Global_Compaction_Crash) - 1))
		if crash_err == .Stop_Test do return hgl.abort()
		if crash_err != nil do return hgl.interesting("draw global semantic compaction crash point")
		mutation_raw, mutation_err := hgl.draw_i64(tc, 0, i64(len(Semantic_Global_Compaction_Mutation) - 1))
		if mutation_err == .Stop_Test do return hgl.abort()
		if mutation_err != nil do return hgl.interesting("draw global semantic compaction mutation")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 255)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("draw global semantic compaction first receive split")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 255)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("draw global semantic compaction second receive split")
		choices: [32]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw global semantic compaction runnable rank")
			choice = u8(drawn)
		}
		crash_point := Semantic_Global_Compaction_Crash(crash_raw)
		mutation := Semantic_Global_Compaction_Mutation(mutation_raw)
		if diagnostic := semantic_global_compaction_run(choices[:], crash_point, int(split_a), int(split_b), mutation); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf(
					"global semantic compaction failure: reason=%s crash=%v mutation=%v splits=%d/%d choices=%v\n",
					diagnostic,
					crash_point,
					mutation,
					split_a,
					split_b,
					choices,
				)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	prop_global_dependent_compaction_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count_raw, op_count_err := hgl.draw_i64(tc, 3, 4)
		if op_count_err == .Stop_Test do return hgl.abort()
		if op_count_err != nil do return hgl.interesting("draw global dependent compaction operation count")
		op_count := int(op_count_raw)
		variants, split_as, split_bs: [4]u8
		for index in 0 ..< op_count {
			destinations := [?]^u8{&variants[index], &split_as[index], &split_bs[index]}
			for destination in destinations {
				value, draw_err := hgl.draw_i64(tc, 0, 255)
				if draw_err == .Stop_Test do return hgl.abort()
				if draw_err != nil do return hgl.interesting("draw global dependent compaction operation choice")
				destination^ = u8(value)
			}
		}
		choices: [64]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw global dependent compaction runnable rank")
			choice = u8(drawn)
		}
		if diagnostic := semantic_global_compaction_dependent_run(op_count, variants[:], split_as[:], split_bs[:], choices[:]); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf(
					"global dependent compaction failure: reason=%s count=%d variants=%v split_as=%v split_bs=%v choices=%v\n",
					diagnostic,
					op_count,
					variants[:op_count],
					split_as[:op_count],
					split_bs[:op_count],
					choices,
				)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}

	prop_global_segmented_deferred_interleavings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		choices: [32]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw global segmented deferred runnable rank")
			choice = u8(drawn)
		}
		if diagnostic := semantic_global_segmented_deferred_run(choices[:], 0, rank_process_crash = true); diagnostic != "" {
			if tc.is_final {
				fmt.eprintf("global segmented deferred failure: reason=%s choices=%v\n", diagnostic, choices)
			}
			return hgl.interesting(diagnostic)
		}
		return hgl.valid()
	}
}
