package main

import "core:os"
import "core:testing"

import "btree"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: hgl.run
	_ :: os.remove
	_ :: pr.EdgeID
}

when NRC_SIMULATION {
	Edge_Equivalence_Kind :: enum {
		Create,
		Delete,
	}

	Edge_Equivalence_Result :: struct {
		response:              [512]byte,
		response_len:          int,
		edge_payload:          [256]byte,
		edge_payload_len:      int,
		endpoint_payloads:     [4][2_048]byte,
		endpoint_payload_lens: [4]int,
		task_count:            int,
		asset_count:           int,
		edge_count:            int,
		adjacency_count:       int,
		active_task_count:     int,
		task_index_keys:       [2]Task_Sort_Key,
		task_index_present:    [2]bool,
		task_btree_contains:   [2]bool,
		task_index_count:      int,
		task_btree_count:      int,
		note_index_count:      int,
		note_btree_count:      int,
		wal_records:           u64,
		wal_last_hash:         [32]byte,
		task_floor:            u64,
		asset_floor:           u64,
		edge_floor:            u64,
		task_seq:              u64,
		asset_seq:             u64,
		edge_seq:              u64,
		adjacency_valid:       bool,
	}

	edge_equivalence_request :: proc(endpoint_variant: int, relation: pr.RelationType, correlation_id: u32) -> pr.CreateEdgeRequest {
		req := pr.CreateEdgeRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			relation       = relation,
			correlation_id = correlation_id,
		}
		switch endpoint_variant {
		case 0:
			req.source_type, req.source_id = .Asset, 1
			req.target_type, req.target_id = .Asset, 2
		case 1:
			req.source_type, req.source_id = .Task, 1
			req.target_type, req.target_id = .Task, 2
		case 2:
			req.source_type, req.source_id = .Asset, 1
			req.target_type, req.target_id = .Task, 1
		case:
			req.source_type, req.source_id = .Task, 1
			req.target_type, req.target_id = .Asset, 1
		}
		return req
	}

	edge_equivalence_setup :: proc(client: ^NRC_Connection, conv_id: pr.ConversationID) {
		for task_index in 0 ..< 2 {
			process_create_task(
				client,
				pr.CreateTaskRequest {
					conv_id = conv_id,
					title = task_index == 0 ? transmute([]byte)string("edge task one") : transmute([]byte)string("edge task two"),
					status = .Todo,
					project = transmute([]byte)string("edge-equivalence"),
				},
			)
		}
		for asset_index in 0 ..< 2 {
			payload := asset_index == 0 ? "edge asset one" : "edge asset two"
			handle_create_asset(
				client,
				pr.CreateAssetRequest {
					conv_id = conv_id,
					asset_type = .Document,
					payload_encoding = .Plain,
					payload_raw_len = u32(len(payload)),
					preview = transmute([]byte)payload,
					payload = transmute([]byte)payload,
				},
			)
		}
	}

	edge_equivalence_capture_endpoints :: proc(result: ^Edge_Equivalence_Result, conv: ^Conversation_State) -> bool {
		for endpoint_index in 0 ..< 4 {
			if endpoint_index < 2 {
				task := conv.tasks[pr.TaskID(endpoint_index + 1)]
				if task == nil do return false
				result.endpoint_payload_lens[endpoint_index] = pr.serializeTask(task^, result.endpoint_payloads[endpoint_index][:])
				result.task_index_keys[endpoint_index], result.task_index_present[endpoint_index] = conv.task_index_keys[task.id]
				if result.task_index_present[endpoint_index] {
					result.task_btree_contains[endpoint_index] = btree.contains(&conv.task_index, result.task_index_keys[endpoint_index])
				}
			} else {
				asset := conv.assets[pr.AssetID(endpoint_index - 1)]
				if asset == nil do return false
				result.endpoint_payload_lens[endpoint_index] = pr.serializeAsset(asset^, result.endpoint_payloads[endpoint_index][:])
			}
			if result.endpoint_payload_lens[endpoint_index] <= 0 do return false
		}
		return true
	}

	edge_equivalence_run :: proc(
		kind: Edge_Equivalence_Kind,
		endpoint_variant: int,
		relation: pr.RelationType,
		correlation_id: u32,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Edge_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, through_wire ? 144 : 143)
		defer simulation_test_end(&ctx)
		workspace_id := "edge-parser-direct-equivalence"
		wal_path, writer_ok := task_handler_test_init_sim_writer(workspace_id, "edge_equivalence.log")
		defer os.remove(wal_path)
		if !writer_ok do return {}, "initialize edge equivalence WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return {}, "install edge equivalence client", false
		ctx.conns[1] = client
		conv_id := pr.WORKSPACE_DATA_ID
		subscribe_to_conversation(client, conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)
		edge_equivalence_setup(client, conv_id)
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, conv_id)
		if conv == nil ||
		   len(conv.tasks) != 2 ||
		   len(conv.assets) != 2 ||
		   len(conv.edges) != 0 ||
		   len(conv.task_index_keys) != 2 ||
		   btree.count(&conv.task_index) != 2 ||
		   len(conv.note_index_keys) != 0 {
			return {}, "create edge equivalence endpoint fixture", false
		}
		req := edge_equivalence_request(endpoint_variant, relation, correlation_id)
		if kind == .Delete {
			handle_create_edge(client, req)
			if len(conv.edges) != 1 || len(conv.edges_by_entity) != 2 do return {}, "create delete-edge baseline", false
		}
		if !simulation_test_commit_shards(&ctx.sim) do return {}, "commit edge baseline", false
		nrc_sim_clear_inboxes(&ctx.sim)

		if through_wire {
			request_buf: [64]byte
			request_len :=
				kind == .Create ? pr.serializeCreateEdgeRequest(req, request_buf[:]) : pr.serializeDeleteEdgeRequest(conv_id, 1, request_buf[:], correlation_id)
			if request_len <= 0 do return {}, "serialize edge equivalence request", false
			if !handler_equivalence_deliver_wire(&ctx.sim, client, request_buf[:request_len], split_a, split_b) do return {}, "deliver split edge equivalence request", false
		} else if kind == .Create {
			handle_create_edge(client, req)
		} else {
			handle_delete_edge(client, pr.DeleteEdgeRequest{conv_id = conv_id, edge_id = 1, correlation_id = correlation_id})
		}
		if !simulation_test_commit_shards(&ctx.sim) do return {}, "commit edge mutation", false

		result: Edge_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 do return result, "unexpected edge equivalence response count", false
		response, response_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, 0))
		if !response_ok || len(response) > len(result.response) do return result, "capture edge equivalence response", false
		copy(result.response[:], response)
		result.response_len = len(response)
		if !edge_equivalence_capture_endpoints(&result, conv) do return result, "capture edge equivalence endpoints", false
		result.task_count = len(conv.tasks)
		result.asset_count = len(conv.assets)
		result.edge_count = len(conv.edges)
		result.adjacency_count = len(conv.edges_by_entity)
		result.active_task_count = conv.active_task_count
		result.task_index_count = len(conv.task_index_keys)
		result.task_btree_count = btree.count(&conv.task_index)
		result.note_index_count = len(conv.note_index_keys)
		result.note_btree_count = btree.count(&conv.note_index)
		result.wal_records = td.shard_writers.writers[0].wal.record_count
		result.wal_last_hash = td.shard_writers.writers[0].wal.last_hash
		result.task_floor = td.shard_writers.writers[0].floors.task
		result.asset_floor = td.shard_writers.writers[0].floors.asset
		result.edge_floor = td.shard_writers.writers[0].floors.edge
		result.task_seq = td.task_seq
		result.asset_seq = td.asset_seq
		result.edge_seq = td.edge_seq

		if kind == .Create {
			created, parse_err := pr.parseEdgeCreatedMessage(response)
			if parse_err != nil || created.correlation_id != correlation_id do return result, "create-edge response correlation differs", false
			edge := conv.edges[1]
			if edge == nil do return result, "created edge missing", false
			result.edge_payload_len = pr.serializeEdge(edge^, result.edge_payload[:])
			source_adjacency := conv.edges_by_entity[Edge_Entity_Key{target_type = req.source_type, target_id = req.source_id}]
			target_adjacency := conv.edges_by_entity[Edge_Entity_Key{target_type = req.target_type, target_id = req.target_id}]
			result.adjacency_valid = len(source_adjacency) == 1 && source_adjacency[0] == 1 && len(target_adjacency) == 1 && target_adjacency[0] == 1
			if result.edge_payload_len <= 0 ||
			   created.edge.edge_id != 1 ||
			   created.edge.conv_id != conv_id ||
			   created.edge.source_type != req.source_type ||
			   created.edge.source_id != req.source_id ||
			   created.edge.target_type != req.target_type ||
			   created.edge.target_id != req.target_id ||
			   created.edge.relation != req.relation ||
			   string(created.edge.created_by) != "equivalence-user" ||
			   result.edge_count != 1 ||
			   result.adjacency_count != 2 ||
			   !result.adjacency_valid ||
			   result.wal_records != 5 {
				return result, "create-edge final semantics differ from request", false
			}
		} else {
			deleted, parse_err := pr.parseEdgeDeletedMessage(response)
			if parse_err != nil ||
			   deleted.conv_id != conv_id ||
			   deleted.edge_id != 1 ||
			   deleted.correlation_id != correlation_id ||
			   conv.edges[1] != nil ||
			   result.edge_count != 0 ||
			   result.adjacency_count != 0 ||
			   result.wal_records != 6 {
				return result, "delete-edge final semantics differ from request", false
			}
		}
		if result.task_count != 2 ||
		   result.asset_count != 2 ||
		   result.active_task_count != 2 ||
		   result.task_index_count != 2 ||
		   result.task_btree_count != 2 ||
		   result.note_index_count != 0 ||
		   result.note_btree_count != 0 ||
		   result.wal_last_hash == ([32]byte{}) ||
		   result.task_floor != 2 ||
		   result.asset_floor != 2 ||
		   result.edge_floor != 1 ||
		   result.task_seq != 2 ||
		   result.asset_seq != 2 ||
		   result.edge_seq != 1 {
			return result, "edge mutation changed endpoint or persistence metadata", false
		}
		for task_index in 0 ..< 2 {
			task := conv.tasks[pr.TaskID(task_index + 1)]
			if !result.task_index_present[task_index] ||
			   !result.task_btree_contains[task_index] ||
			   result.task_index_keys[task_index] != make_task_sort_key(task) {
				return result, "edge mutation changed exact task index state", false
			}
		}
		return result, "", true
	}

	edge_equivalence_results_equal :: proc(a, b: Edge_Equivalence_Result) -> bool {
		if a.response_len != b.response_len || a.edge_payload_len != b.edge_payload_len do return false
		for index in 0 ..< a.response_len do if a.response[index] != b.response[index] do return false
		for index in 0 ..< a.edge_payload_len do if a.edge_payload[index] != b.edge_payload[index] do return false
		for endpoint_index in 0 ..< len(a.endpoint_payload_lens) {
			if a.endpoint_payload_lens[endpoint_index] != b.endpoint_payload_lens[endpoint_index] do return false
			for index in 0 ..< a.endpoint_payload_lens[endpoint_index] do if a.endpoint_payloads[endpoint_index][index] != b.endpoint_payloads[endpoint_index][index] do return false
		}
		return(
			a.task_count == b.task_count &&
			a.asset_count == b.asset_count &&
			a.edge_count == b.edge_count &&
			a.adjacency_count == b.adjacency_count &&
			a.active_task_count == b.active_task_count &&
			a.task_index_keys == b.task_index_keys &&
			a.task_index_present == b.task_index_present &&
			a.task_btree_contains == b.task_btree_contains &&
			a.task_index_count == b.task_index_count &&
			a.task_btree_count == b.task_btree_count &&
			a.note_index_count == b.note_index_count &&
			a.note_btree_count == b.note_btree_count &&
			a.wal_records == b.wal_records &&
			a.wal_last_hash == b.wal_last_hash &&
			a.task_floor == b.task_floor &&
			a.asset_floor == b.asset_floor &&
			a.edge_floor == b.edge_floor &&
			a.task_seq == b.task_seq &&
			a.asset_seq == b.asset_seq &&
			a.edge_seq == b.edge_seq &&
			a.adjacency_valid == b.adjacency_valid \
		)
	}

	prop_edge_create_delete_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		kind_value, kind_err := hgl.draw_i64(tc, 0, 1)
		if kind_err == .Stop_Test do return hgl.abort()
		if kind_err != nil do return hgl.interesting("edge equivalence kind draw failed")
		endpoint_variant, endpoint_err := hgl.draw_i64(tc, 0, 3)
		if endpoint_err == .Stop_Test do return hgl.abort()
		if endpoint_err != nil do return hgl.interesting("edge endpoint variant draw failed")
		relation_value, relation_err := hgl.draw_i64(tc, i64(min(pr.RelationType)), i64(max(pr.RelationType)))
		if relation_err == .Stop_Test do return hgl.abort()
		if relation_err != nil do return hgl.interesting("edge relation draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("edge correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("edge first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("edge second split draw failed")
		kind := Edge_Equivalence_Kind(kind_value)
		direct, direct_reason, direct_ok := edge_equivalence_run(kind, int(endpoint_variant), pr.RelationType(relation_value), u32(correlation), false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := edge_equivalence_run(
			kind,
			int(endpoint_variant),
			pr.RelationType(relation_value),
			u32(correlation),
			true,
			int(split_a),
			int(split_b),
		)
		if !wire_ok do return hgl.interesting(wire_reason)
		if !edge_equivalence_results_equal(direct, wire) do return hgl.interesting("direct and split-wire edge semantics differ")
		return hgl.valid()
	}

	edge_equivalence_mandatory_cases :: proc(t: ^testing.T) -> bool {
		for relation in pr.RelationType {
			for kind_index in 0 ..< 2 {
				for endpoint_variant in 0 ..< 4 {
					kind := Edge_Equivalence_Kind(kind_index)
					direct, direct_reason, direct_ok := edge_equivalence_run(
						kind,
						endpoint_variant,
						relation,
						u32(0x7700 + kind_index * 4 + endpoint_variant),
						false,
						0,
						0,
					)
					testing.expectf(t, direct_ok, "mandatory edge kind=%d endpoints=%d direct failed: %s", kind_index, endpoint_variant, direct_reason)
					if !direct_ok do return false
					wire, wire_reason, wire_ok := edge_equivalence_run(
						kind,
						endpoint_variant,
						relation,
						u32(0x7700 + kind_index * 4 + endpoint_variant),
						true,
						endpoint_variant + 2,
						endpoint_variant + 13,
					)
					testing.expectf(t, wire_ok, "mandatory edge kind=%d endpoints=%d wire failed: %s", kind_index, endpoint_variant, wire_reason)
					if !wire_ok do return false
					equal := edge_equivalence_results_equal(direct, wire)
					testing.expectf(t, equal, "mandatory edge kind=%d endpoints=%d semantics should match", kind_index, endpoint_variant)
					if !equal do return false
				}
			}
		}
		return true
	}
}

@(test)
test_hegel_edge_create_delete_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !edge_equivalence_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_edge_create_delete_parser_direct_equivalence, nil, {test_cases = 64})
		testing.expectf(t, err == nil, "generated edge parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
