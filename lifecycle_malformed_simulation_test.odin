package main

import "core:log"
import "core:os"
import "core:testing"

import "btree"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: hgl.run
	_ :: log.nil_logger
	_ :: os.remove
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	Malformed_Lifecycle_Kind :: enum {
		Create_Task,
		Update_Task,
		Move_Task,
		Delete_Task,
		Create_Asset,
		Update_Asset,
		Delete_Asset,
		Create_Edge,
		Delete_Edge,
		List_Tasks_Paged,
		List_Notes_By_Project,
		List_Edges,
		Graph_Query,
		Graph_Shortest_Path,
		Graph_Degree,
		Graph_Common_Neighbors,
	}

	Malformed_Lifecycle_State :: struct {
		task_payload:        [2_048]byte,
		task_payload_len:    int,
		asset_payload:       [2_048]byte,
		asset_payload_len:   int,
		edge_payload:        [256]byte,
		edge_payload_len:    int,
		task_count:          int,
		asset_count:         int,
		edge_count:          int,
		adjacency_count:     int,
		active_task_count:   int,
		task_index_count:    int,
		task_btree_count:    int,
		task_index_key:      Task_Sort_Key,
		task_index_present:  bool,
		task_btree_contains: bool,
		note_index_count:    int,
		note_btree_count:    int,
		note_index_key:      Note_Sort_Key,
		note_index_present:  bool,
		note_btree_contains: bool,
		note_projects:       int,
		note_tags:           int,
		wal_records:         u64,
		wal_last_hash:       [32]byte,
		task_floor:          u64,
		asset_floor:         u64,
		edge_floor:          u64,
		task_seq:            u64,
		asset_seq:           u64,
		edge_seq:            u64,
	}

	malformed_lifecycle_capture_state :: proc(workspace_id: string, conv_id: pr.ConversationID) -> (Malformed_Lifecycle_State, bool) {
		result: Malformed_Lifecycle_State
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, conv_id)
		if conv == nil do return result, false
		task := conv.tasks[1]
		asset := conv.assets[1]
		edge := conv.edges[1]
		if task == nil || asset == nil || edge == nil do return result, false
		result.task_payload_len = pr.serializeTask(task^, result.task_payload[:])
		result.asset_payload_len = pr.serializeAsset(asset^, result.asset_payload[:])
		result.edge_payload_len = pr.serializeEdge(edge^, result.edge_payload[:])
		if result.task_payload_len <= 0 || result.asset_payload_len <= 0 || result.edge_payload_len <= 0 do return result, false
		result.task_count = len(conv.tasks)
		result.asset_count = len(conv.assets)
		result.edge_count = len(conv.edges)
		result.adjacency_count = len(conv.edges_by_entity)
		result.active_task_count = conv.active_task_count
		result.task_index_count = len(conv.task_index_keys)
		result.task_btree_count = btree.count(&conv.task_index)
		result.task_index_key, result.task_index_present = conv.task_index_keys[1]
		if result.task_index_present do result.task_btree_contains = btree.contains(&conv.task_index, result.task_index_key)
		result.note_index_count = len(conv.note_index_keys)
		result.note_btree_count = btree.count(&conv.note_index)
		result.note_index_key, result.note_index_present = conv.note_index_keys[1]
		if result.note_index_present do result.note_btree_contains = btree.contains(&conv.note_index, result.note_index_key)
		result.note_projects = len(conv.note_project_assets)
		result.note_tags = len(conv.note_tag_assets)
		result.wal_records = td.shard_writers.writers[0].wal.record_count
		result.wal_last_hash = td.shard_writers.writers[0].wal.last_hash
		result.task_floor = td.shard_writers.writers[0].floors.task
		result.asset_floor = td.shard_writers.writers[0].floors.asset
		result.edge_floor = td.shard_writers.writers[0].floors.edge
		result.task_seq = td.task_seq
		result.asset_seq = td.asset_seq
		result.edge_seq = td.edge_seq
		project_assets := conv.note_project_assets["baseline"]
		tag_assets := conv.note_tag_assets["stable"]
		task_adjacency := conv.edges_by_entity[Edge_Entity_Key{target_type = .Task, target_id = 1}]
		asset_adjacency := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}]
		valid :=
			result.task_count == 1 &&
			result.asset_count == 1 &&
			result.edge_count == 1 &&
			result.adjacency_count == 2 &&
			len(task_adjacency) == 1 &&
			task_adjacency[0] == 1 &&
			len(asset_adjacency) == 1 &&
			asset_adjacency[0] == 1 &&
			result.active_task_count == 1 &&
			result.task_index_count == 1 &&
			result.task_btree_count == 1 &&
			result.task_index_present &&
			result.task_btree_contains &&
			result.note_index_count == 1 &&
			result.note_btree_count == 1 &&
			result.note_index_present &&
			result.note_btree_contains &&
			result.note_projects == 1 &&
			note_secondary_index_count(project_assets) == 1 &&
			note_secondary_index_contains_asset(project_assets, 1) &&
			result.note_tags == 1 &&
			note_secondary_index_count(tag_assets) == 1 &&
			note_secondary_index_contains_asset(tag_assets, 1) &&
			result.wal_records == 3 &&
			result.wal_last_hash != ([32]byte{}) &&
			result.task_floor == 1 &&
			result.asset_floor == 1 &&
			result.edge_floor == 1 &&
			result.task_seq == 1 &&
			result.asset_seq == 1 &&
			result.edge_seq == 1
		return result, valid
	}

	malformed_lifecycle_states_equal :: proc(a, b: Malformed_Lifecycle_State) -> bool {
		if a.task_payload_len != b.task_payload_len || a.asset_payload_len != b.asset_payload_len || a.edge_payload_len != b.edge_payload_len do return false
		for index in 0 ..< a.task_payload_len do if a.task_payload[index] != b.task_payload[index] do return false
		for index in 0 ..< a.asset_payload_len do if a.asset_payload[index] != b.asset_payload[index] do return false
		for index in 0 ..< a.edge_payload_len do if a.edge_payload[index] != b.edge_payload[index] do return false
		return(
			a.task_count == b.task_count &&
			a.asset_count == b.asset_count &&
			a.edge_count == b.edge_count &&
			a.adjacency_count == b.adjacency_count &&
			a.active_task_count == b.active_task_count &&
			a.task_index_count == b.task_index_count &&
			a.task_btree_count == b.task_btree_count &&
			a.task_index_key == b.task_index_key &&
			a.task_index_present == b.task_index_present &&
			a.task_btree_contains == b.task_btree_contains &&
			a.note_index_count == b.note_index_count &&
			a.note_btree_count == b.note_btree_count &&
			a.note_index_key == b.note_index_key &&
			a.note_index_present == b.note_index_present &&
			a.note_btree_contains == b.note_btree_contains &&
			a.note_projects == b.note_projects &&
			a.note_tags == b.note_tags &&
			a.wal_records == b.wal_records &&
			a.wal_last_hash == b.wal_last_hash &&
			a.task_floor == b.task_floor &&
			a.asset_floor == b.asset_floor &&
			a.edge_floor == b.edge_floor &&
			a.task_seq == b.task_seq &&
			a.asset_seq == b.asset_seq &&
			a.edge_seq == b.edge_seq \
		)
	}

	malformed_lifecycle_serialize_request :: proc(kind: Malformed_Lifecycle_Kind, correlation_id: u32, buf: []byte) -> (pr.Opcode, int) {
		conv_id := pr.ConversationID(90)
		switch kind {
		case .Create_Task:
			req := pr.CreateTaskRequest {
				conv_id        = conv_id,
				title          = transmute([]byte)string("must not be created"),
				status         = .Todo,
				correlation_id = correlation_id,
				project        = transmute([]byte)string("malformed"),
			}
			return .C_CreateTask, pr.serializeCreateTaskRequest(req, buf)
		case .Update_Task:
			req := pr.UpdateTaskRequest {
				conv_id        = conv_id,
				task_id        = 1,
				title          = transmute([]byte)string("must not update"),
				status         = .Done,
				priority       = 4,
				color          = .Red,
				correlation_id = correlation_id,
			}
			return .C_UpdateTask, pr.serializeUpdateTaskRequest(req, buf)
		case .Move_Task:
			req := pr.MoveTaskRequest {
				conv_id        = conv_id,
				task_id        = 1,
				status         = .Done,
				order_index    = 99,
				correlation_id = correlation_id,
			}
			return .C_MoveTask, pr.serializeMoveTaskRequest(req, buf)
		case .Delete_Task:
			return .C_DeleteTask, pr.serializeDeleteTaskRequest(conv_id, 1, buf, correlation_id)
		case .Create_Asset:
			payload := transmute([]byte)string("must not be created")
			req := pr.CreateAssetRequest {
				conv_id          = conv_id,
				asset_type       = .Document,
				payload_encoding = .Plain,
				payload_raw_len  = u32(len(payload)),
				preview          = transmute([]byte)string("malformed create"),
				payload          = payload,
				correlation_id   = correlation_id,
			}
			return .C_CreateAsset, pr.serializeCreateAssetRequest(req, buf)
		case .Update_Asset:
			payload := transmute([]byte)string("must not update")
			req := pr.UpdateAssetRequest {
				conv_id          = conv_id,
				asset_id         = 1,
				payload_encoding = .Plain,
				payload_raw_len  = u32(len(payload)),
				preview          = transmute([]byte)string(`{"project":"mutated","tags":["lost"]}`),
				payload          = payload,
				correlation_id   = correlation_id,
			}
			return .C_UpdateAsset, pr.serializeUpdateAssetRequest(req, buf)
		case .Delete_Asset:
			return .C_DeleteAsset, pr.serializeDeleteAssetRequest(conv_id, 1, buf, correlation_id)
		case .Create_Edge:
			req := pr.CreateEdgeRequest {
				conv_id        = conv_id,
				source_type    = .Asset,
				source_id      = 1,
				target_type    = .Task,
				target_id      = 1,
				relation       = .Blocks,
				correlation_id = correlation_id,
			}
			return .C_CreateEdge, pr.serializeCreateEdgeRequest(req, buf)
		case .Delete_Edge:
			return .C_DeleteEdge, pr.serializeDeleteEdgeRequest(conv_id, 1, buf, correlation_id)
		case .List_Tasks_Paged:
			req := pr.ListTasksPagedRequest {
				conv_id        = conv_id,
				status_mask    = 0x1f,
				limit          = 10,
				has_cursor     = true,
				cursor_sort_at = 123,
				cursor_task_id = 1,
				correlation_id = correlation_id,
			}
			return .C_ListTasksPaged, pr.serializeListTasksPagedRequest(req, buf)
		case .List_Notes_By_Project:
			return .C_ListAssetsPagedByProject, pr.serializeListAssetsPagedByProjectRequest(
				conv_id,
				.Note,
				true,
				10,
				true,
				123,
				1,
				"baseline",
				buf,
				correlation_id,
			)
		case .List_Edges:
			req := pr.ListEdgesRequest {
				conv_id        = conv_id,
				target_type    = .Task,
				target_id      = 1,
				correlation_id = correlation_id,
			}
			return .C_ListEdges, pr.serializeListEdgesRequest(req, buf)
		case .Graph_Query:
			req := pr.GraphQueryRequest {
				conv_id        = conv_id,
				start_type     = .Task,
				start_id       = 1,
				max_depth      = 3,
				relation_mask  = 0b11_1111,
				direction      = .Both,
				correlation_id = correlation_id,
			}
			return .C_GraphQuery, pr.serializeGraphQueryRequest(req, buf)
		case .Graph_Shortest_Path:
			req := pr.GraphShortestPathRequest {
				conv_id        = conv_id,
				from_type      = .Task,
				from_id        = 1,
				to_type        = .Asset,
				to_id          = 1,
				relation_mask  = 0b11_1111,
				direction      = .Both,
				max_depth      = 3,
				correlation_id = correlation_id,
			}
			return .C_GraphShortestPath, pr.serializeGraphShortestPathRequest(req, buf)
		case .Graph_Degree:
			req := pr.GraphDegreeRequest {
				conv_id        = conv_id,
				top_n          = 10,
				type_filter    = 0,
				relation_mask  = 0b11_1111,
				correlation_id = correlation_id,
			}
			return .C_GraphDegree, pr.serializeGraphDegreeRequest(req, buf)
		case .Graph_Common_Neighbors:
			req := pr.GraphCommonNeighborsRequest {
				conv_id        = conv_id,
				a_type         = .Task,
				a_id           = 1,
				b_type         = .Asset,
				b_id           = 1,
				relation_mask  = 0b11_1111,
				direction      = .Both,
				correlation_id = correlation_id,
			}
			return .C_GraphCommonNeighbors, pr.serializeGraphCommonNeighborsRequest(req, buf)
		}
		return {}, -1
	}

	malformed_lifecycle_query_request_is_valid :: proc(kind: Malformed_Lifecycle_Kind, payload: []byte) -> bool {
		#partial switch kind {
		case .List_Tasks_Paged:
			_, err := pr.parseListTasksPagedRequest(payload)
			return err == nil
		case .List_Notes_By_Project:
			_, err := pr.parseListAssetsPagedByProjectRequest(payload)
			return err == nil
		case .List_Edges:
			_, err := pr.parseListEdgesRequest(payload)
			return err == nil
		case .Graph_Query:
			_, err := pr.parseGraphQueryRequest(payload)
			return err == nil
		case .Graph_Shortest_Path:
			_, err := pr.parseGraphShortestPathRequest(payload)
			return err == nil
		case .Graph_Degree:
			_, err := pr.parseGraphDegreeRequest(payload)
			return err == nil
		case .Graph_Common_Neighbors:
			_, err := pr.parseGraphCommonNeighborsRequest(payload)
			return err == nil
		case:
			return true
		}
	}

	malformed_lifecycle_run :: proc(kind: Malformed_Lifecycle_Kind, trailing_variant: bool, selector: int) -> (string, bool) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 142)
		defer simulation_test_end(&ctx)
		workspace_id := "malformed-lifecycle-state"
		wal_path, writer_ok := task_handler_test_init_sim_writer(workspace_id, "malformed_lifecycle_state.log")
		defer os.remove(wal_path)
		if !writer_ok do return "initialize malformed lifecycle WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return "install malformed lifecycle client", false
		ctx.conns[1] = client
		conv_id := pr.ConversationID(90)
		subscribe_to_conversation(client, conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)
		process_create_task(
			client,
			pr.CreateTaskRequest {
				conv_id = conv_id,
				title = transmute([]byte)string("baseline task"),
				status = .Todo,
				project = transmute([]byte)string("baseline"),
			},
		)
		asset_payload := transmute([]byte)string("baseline asset")
		handle_create_asset(
			client,
			pr.CreateAssetRequest {
				conv_id = conv_id,
				asset_type = .Note,
				payload_encoding = .Plain,
				payload_raw_len = u32(len(asset_payload)),
				preview = transmute([]byte)string(`{"project":"baseline","tags":["stable"]}`),
				payload = asset_payload,
			},
		)
		handle_create_edge(
			client,
			pr.CreateEdgeRequest{conv_id = conv_id, source_type = .Task, source_id = 1, target_type = .Asset, target_id = 1, relation = .References},
		)
		before, before_ok := malformed_lifecycle_capture_state(workspace_id, conv_id)
		if !before_ok do return "create malformed lifecycle baseline", false
		if !simulation_test_commit_shards(&ctx.sim) do return "commit malformed lifecycle baseline", false
		nrc_sim_clear_inboxes(&ctx.sim)

		request_buf: [2_048]byte
		correlation_id := u32(0x7600 + selector)
		opcode, valid_len := malformed_lifecycle_serialize_request(kind, correlation_id, request_buf[:len(request_buf) - 1])
		if valid_len <= 2 do return "serialize malformed lifecycle request", false
		if !malformed_lifecycle_query_request_is_valid(kind, request_buf[2:valid_len]) do return "query fixture was invalid before corruption", false
		malformed_len := 2 + selector % min(4, valid_len - 2)
		if trailing_variant {
			request_buf[valid_len] = 0xA5
			malformed_len = valid_len + 1
		}
		previous_logger := context.logger
		context.logger = log.nil_logger()
		delivered := handler_equivalence_deliver_wire(&ctx.sim, client, request_buf[:malformed_len], selector + 1, selector + 7)
		context.logger = previous_logger
		if !delivered do return "deliver malformed lifecycle request", false
		if client.state != .Idle || client.receive_accumulator.buf != nil || client.fragment_buf != nil || client.fragment_len != 0 {
			return "malformed request left connection unusable", false
		}
		if nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 do return "unexpected malformed lifecycle response count", false
		error_payload, error_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, 0))
		if !error_ok do return "capture malformed lifecycle error", false
		error_response, error_parse_err := pr.parseErrorResponseMessage(error_payload)
		if error_parse_err != nil || error_response.origin_opcode != opcode || error_response.correlation_id != 0 {
			return "malformed lifecycle error response differs", false
		}
		after_error, after_error_ok := malformed_lifecycle_capture_state(workspace_id, conv_id)
		if !after_error_ok || !malformed_lifecycle_states_equal(before, after_error) do return "malformed lifecycle request mutated state", false

		nrc_sim_clear_inboxes(&ctx.sim)
		ping_buf: [32]byte
		ping_timestamp := i64(0x1234_0000 + selector)
		ping_len := pr.serializePingRequest(ping_timestamp, ping_buf[:])
		if ping_len <= 0 || !handler_equivalence_deliver_wire(&ctx.sim, client, ping_buf[:ping_len], selector + 2, selector + 11) {
			return "deliver post-error ping", false
		}
		if client.state != .Idle ||
		   client.receive_accumulator.buf != nil ||
		   client.fragment_buf != nil ||
		   client.fragment_len != 0 ||
		   nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 {
			return "post-error ping left connection unusable", false
		}
		pong_payload, pong_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, 0))
		if !pong_ok do return "capture post-error pong", false
		pong, pong_err := pr.parsePongResponseMessage(pong_payload)
		if pong_err != nil || pong.timestamp != ping_timestamp do return "post-error pong differs", false
		after_ping, after_ping_ok := malformed_lifecycle_capture_state(workspace_id, conv_id)
		if !after_ping_ok || !malformed_lifecycle_states_equal(before, after_ping) do return "post-error ping mutated lifecycle state", false
		return "", true
	}

	prop_malformed_lifecycle_state_nonmutation :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		kind_value, kind_err := hgl.draw_i64(tc, 0, i64(len(Malformed_Lifecycle_Kind) - 1))
		if kind_err == .Stop_Test do return hgl.abort()
		if kind_err != nil do return hgl.interesting("malformed lifecycle kind draw failed")
		variant, variant_err := hgl.draw_i64(tc, 0, 1)
		if variant_err == .Stop_Test do return hgl.abort()
		if variant_err != nil do return hgl.interesting("malformed lifecycle variant draw failed")
		selector, selector_err := hgl.draw_i64(tc, 0, 4_095)
		if selector_err == .Stop_Test do return hgl.abort()
		if selector_err != nil do return hgl.interesting("malformed lifecycle selector draw failed")
		reason, ok := malformed_lifecycle_run(Malformed_Lifecycle_Kind(kind_value), variant != 0, int(selector))
		if !ok do return hgl.interesting(reason)
		return hgl.valid()
	}

	malformed_lifecycle_mandatory_cases :: proc(t: ^testing.T) -> bool {
		for kind_index in 0 ..< len(Malformed_Lifecycle_Kind) {
			for variant_index in 0 ..< 2 {
				reason, ok := malformed_lifecycle_run(Malformed_Lifecycle_Kind(kind_index), variant_index != 0, kind_index * 2 + variant_index)
				testing.expectf(t, ok, "mandatory malformed lifecycle kind=%d variant=%d failed: %s", kind_index, variant_index, reason)
				if !ok do return false
			}
		}
		return true
	}
}

@(test)
test_hegel_malformed_lifecycle_state_nonmutation_and_connection_usability :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !malformed_lifecycle_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_malformed_lifecycle_state_nonmutation, nil, {test_cases = 72})
		testing.expectf(t, err == nil, "generated malformed lifecycle state property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
