package main

import "core:log"
import "core:testing"

import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: hgl.run
	_ :: log.nil_logger
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
		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return "install malformed lifecycle client", false
		ctx.conns[1] = client
		conv_id := pr.ConversationID(90)
		subscribe_to_conversation(client, conv_id)
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
		return "", true
	}

	prop_malformed_lifecycle_connection_usability :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
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
test_hegel_malformed_lifecycle_connection_usability :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !malformed_lifecycle_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_malformed_lifecycle_connection_usability, nil, {test_cases = 72})
		testing.expectf(t, err == nil, "generated malformed lifecycle connection property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
