package main

import "core:log"
import "core:os"
import "core:testing"

import pr "protocol"

when !NRC_SIMULATION {
	_ :: log.nil_logger
	_ :: os.remove
	_ :: pr.parseErrorResponseMessage
}

when NRC_SIMULATION {
	edge_handler_test_init_writer :: proc(workspace_id: string) -> (path: string, ok: bool) {
		path = test_wal_path("edge_handler_simulation.log")
		_ = os.remove(path)
		if os.write_entire_file(path, nil) != nil do return path, false
		shard := int(shard_for_workspace(transmute([]byte)workspace_id))
		td.shard_writers.worker = 0
		td.shard_writers.worker_count = 1
		for &index in td.shard_writers.writer_index do index = -1
		_, append_err := append(&td.shard_writers.writers, Shard_Transaction_Writer{})
		if append_err != nil || !init_shard_transaction_writer(&td.shard_writers.writers[0], path, shard, 0, 1) {
			shutdown_shard_writer_registry(&td.shard_writers)
			return path, false
		}
		td.shard_writers.writer_index[shard] = 0
		td.shard_writers.mode = .Active
		return path, true
	}

	edge_handler_test_install_client :: proc(
		ctx: ^Sim_Test_Context,
		client_id: int,
		workspace_id, username: string,
		cache_workspace: bool = true,
	) -> ^NRC_Connection {
		sock := connection_test_fake_socket(client_id)
		nrc_sim_register_client(&ctx.sim, sock)
		conn := connection_test_install_fake(
			Fake_Connection_Options {
				sock = sock,
				state = .Idle,
				workspace_id = workspace_id,
				verified_username = username,
				authenticated = true,
				user_type = .User,
				track_active_socket = true,
				cache_workspace = cache_workspace,
			},
		)
		if conn != nil {
			conn.rooms = make(map[pr.ConversationID]bool, 4)
			ctx.conns[client_id] = conn
		}
		return conn
	}

	edge_handler_test_payload :: proc(t: ^testing.T, sim: ^Sim_Runtime, conn: ^NRC_Connection, expected: pr.Opcode) -> (payload: []u8, ok: bool) {
		testing.expect(t, simulation_test_commit_shards(sim))
		frame_count := nrc_sim_client_frame_count(sim, conn.sock)
		testing.expect_value(t, frame_count, 1)
		if frame_count != 1 do return
		payload, ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(sim, conn.sock, 0))
		testing.expect(t, ok, "captured edge response should be a complete WebSocket frame")
		if !ok do return
		testing.expect_value(t, pr.get_opcode(payload), expected)
		return
	}

	edge_handler_test_expect_error :: proc(t: ^testing.T, sim: ^Sim_Runtime, conn: ^NRC_Connection, origin: pr.Opcode, message: string, correlation_id: u32) {
		payload, ok := edge_handler_test_payload(t, sim, conn, .S_ErrorResponse)
		if !ok do return
		response, parse_err := pr.parseErrorResponseMessage(payload)
		testing.expect(t, parse_err == nil, "S_ErrorResponse should decode")
		if parse_err != nil do return
		testing.expect_value(t, response.origin_opcode, origin)
		testing.expect(t, string(response.error_msg) == message, "S_ErrorResponse should preserve the rejection reason")
		testing.expect_value(t, response.correlation_id, correlation_id)
	}

	edge_handler_test_add_asset :: proc(conv: ^Conversation_State, conv_id: pr.ConversationID, asset_id: pr.AssetID) -> bool {
		asset := alloc_asset(transmute([]byte)string("edge-test"), nil, nil)
		if asset == nil do return false
		asset.asset_id = asset_id
		asset.conv_id = conv_id
		asset.asset_type = .Document
		conv.assets[asset_id] = asset
		return true
	}

	edge_handler_test_add_edge :: proc(
		conv: ^Conversation_State,
		conv_id: pr.ConversationID,
		edge_id: pr.EdgeID,
		source_id, target_id: u64,
		relation: pr.RelationType,
	) -> ^pr.Edge {
		edge := alloc_edge(transmute([]byte)string("edge-test"))
		if edge == nil do return nil
		edge.edge_id = edge_id
		edge.conv_id = conv_id
		edge.source_type = .Asset
		edge.source_id = source_id
		edge.target_type = .Asset
		edge.target_id = target_id
		edge.relation = relation
		conv.edges[edge_id] = edge
		add_edge_to_adjacency(conv, .Asset, source_id, edge_id)
		add_edge_to_adjacency(conv, .Asset, target_id, edge_id)
		return edge
	}
}

@(test)
test_simulation_edge_create_rejections_are_protocol_visible_and_non_mutating :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 125)
		defer simulation_test_end(&ctx)
		workspace_id := "edge-handler-validation"
		conn := edge_handler_test_install_client(&ctx, 1, workspace_id, "alice")
		if conn == nil do return
		conv_id := pr.ConversationID(81)
		conv := get_or_create_conversation(conn.workspace, conv_id)
		testing.expect(t, edge_handler_test_add_asset(conv, conv_id, 1), "source fixture should allocate")
		testing.expect(t, edge_handler_test_add_asset(conv, conv_id, 2), "target fixture should allocate")
		if len(conv.assets) != 2 do return

		requests := [?]struct {
			req:     pr.CreateEdgeRequest,
			message: string,
		} {
			{
				req = {
					conv_id = conv_id,
					source_type = .Asset,
					source_id = 1,
					target_type = .Asset,
					target_id = 2,
					relation = pr.RelationType(99),
					correlation_id = 201,
				},
				message = "Invalid edge relation",
			},
			{
				req = {
					conv_id = conv_id,
					source_type = .Asset,
					source_id = 99,
					target_type = .Asset,
					target_id = 2,
					relation = .References,
					correlation_id = 202,
				},
				message = "Edge source entity not found",
			},
			{
				req = {
					conv_id = conv_id,
					source_type = .Asset,
					source_id = 1,
					target_type = .Asset,
					target_id = 99,
					relation = .References,
					correlation_id = 203,
				},
				message = "Edge target entity not found",
			},
			{
				req = {
					conv_id = conv_id,
					source_type = .Asset,
					source_id = 1,
					target_type = .Asset,
					target_id = 1,
					relation = .References,
					correlation_id = 204,
				},
				message = "Self-edge not allowed",
			},
		}

		for test_case in requests {
			nrc_sim_clear_inboxes(&ctx.sim)
			edge_count := len(conv.edges)
			adjacency_count := len(conv.edges_by_entity)
			edge_seq := td.edge_seq
			previous_logger := context.logger
			context.logger = log.nil_logger()
			handle_create_edge(conn, test_case.req)
			context.logger = previous_logger
			edge_handler_test_expect_error(t, &ctx.sim, conn, .C_CreateEdge, test_case.message, test_case.req.correlation_id)
			testing.expect_value(t, len(conv.edges), edge_count)
			testing.expect_value(t, len(conv.edges_by_entity), adjacency_count)
			testing.expect_value(t, td.edge_seq, edge_seq)
		}
	}
}

@(test)
test_simulation_edge_delete_missing_state_returns_correlated_errors_without_mutation :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 126)
		defer simulation_test_end(&ctx)
		workspace_id := "edge-handler-delete-errors"
		conn := edge_handler_test_install_client(&ctx, 1, workspace_id, "alice", false)
		if conn == nil do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		handle_delete_edge(conn, pr.DeleteEdgeRequest{conv_id = 82, edge_id = 1, correlation_id = 211})
		context.logger = previous_logger
		edge_handler_test_expect_error(t, &ctx.sim, conn, .C_DeleteEdge, "Workspace not found", 211)

		ws := get_or_create_workspace(workspace_id)
		conn.workspace = ws
		nrc_sim_clear_inboxes(&ctx.sim)
		context.logger = log.nil_logger()
		handle_delete_edge(conn, pr.DeleteEdgeRequest{conv_id = 82, edge_id = 1, correlation_id = 212})
		context.logger = previous_logger
		edge_handler_test_expect_error(t, &ctx.sim, conn, .C_DeleteEdge, "Conversation not found", 212)

		conv := get_or_create_conversation(ws, 82)
		testing.expect(t, edge_handler_test_add_asset(conv, 82, 1), "source fixture should allocate")
		testing.expect(t, edge_handler_test_add_asset(conv, 82, 2), "target fixture should allocate")
		testing.expect(t, edge_handler_test_add_edge(conv, 82, 7, 1, 2, .References) != nil, "edge fixture should allocate")
		existing_edge := conv.edges[7]
		nrc_sim_clear_inboxes(&ctx.sim)
		context.logger = log.nil_logger()
		handle_delete_edge(conn, pr.DeleteEdgeRequest{conv_id = 82, edge_id = 99, correlation_id = 213})
		context.logger = previous_logger
		edge_handler_test_expect_error(t, &ctx.sim, conn, .C_DeleteEdge, "Edge not found", 213)
		testing.expect_value(t, len(conv.edges), 1)
		testing.expect_value(t, len(conv.edges_by_entity), 2)
		testing.expect(t, conv.edges[7] == existing_edge, "missing-edge rejection must retain the existing edge allocation")
		for asset_id in 1 ..= 2 {
			edge_ids := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = u64(asset_id)}]
			testing.expect_value(t, len(edge_ids), 1)
			if len(edge_ids) == 1 do testing.expect_value(t, edge_ids[0], pr.EdgeID(7))
		}
	}
}

@(test)
test_simulation_edge_lists_decode_correlations_and_ignore_stale_entries :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 127)
		defer simulation_test_end(&ctx)
		workspace_id := "edge-handler-listing"
		conn := edge_handler_test_install_client(&ctx, 1, workspace_id, "alice")
		if conn == nil do return
		conv_id := pr.ConversationID(83)
		conv := get_or_create_conversation(conn.workspace, conv_id)
		for asset_id in 1 ..= 3 {
			testing.expect(t, edge_handler_test_add_asset(conv, conv_id, pr.AssetID(asset_id)), "asset fixture should allocate")
		}
		testing.expect(t, edge_handler_test_add_edge(conv, conv_id, 11, 1, 2, .References) != nil, "first edge fixture should allocate")
		testing.expect(t, edge_handler_test_add_edge(conv, conv_id, 12, 2, 3, .DependsOn) != nil, "second edge fixture should allocate")
		append(&conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}], 999)
		conv.edges[998] = nil

		handle_list_edges(conn, pr.ListEdgesRequest{conv_id = conv_id, target_type = .Asset, target_id = 1, correlation_id = 221})
		payload, ok := edge_handler_test_payload(t, &ctx.sim, conn, .S_EdgeList)
		if ok {
			edges: [4]pr.Edge
			listed, parse_err := pr.parseEdgeListMessage(payload, edges[:])
			testing.expect(t, parse_err == nil, "S_EdgeList should decode")
			testing.expect_value(t, listed.conv_id, conv_id)
			testing.expect_value(t, listed.target_type, pr.TargetType.Asset)
			testing.expect_value(t, listed.target_id, u64(1))
			testing.expect_value(t, listed.correlation_id, u32(221))
			testing.expect_value(t, len(listed.edges), 1)
			if len(listed.edges) == 1 do testing.expect_value(t, listed.edges[0].edge_id, pr.EdgeID(11))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_all_edges(conn, pr.ListAllEdgesRequest{conv_id = conv_id, correlation_id = 222})
		payload, ok = edge_handler_test_payload(t, &ctx.sim, conn, .S_AllEdgeList)
		if ok {
			edges: [4]pr.Edge
			listed, parse_err := pr.parseAllEdgeListMessage(payload, edges[:])
			testing.expect(t, parse_err == nil, "S_AllEdgeList should decode")
			testing.expect_value(t, listed.conv_id, conv_id)
			testing.expect_value(t, listed.correlation_id, u32(222))
			testing.expect_value(t, len(listed.edges), 2)
			seen_11, seen_12 := false, false
			for edge in listed.edges {
				seen_11 = seen_11 || edge.edge_id == 11
				seen_12 = seen_12 || edge.edge_id == 12
			}
			testing.expect(t, seen_11 && seen_12, "all-edge listing should contain each live edge and omit nil map entries")
		}

		testing.expect_value(t, len(conv.edges), 3)
		testing.expect_value(t, len(conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 1}]), 2)
	}
}

@(test)
test_simulation_edge_create_delete_broadcasts_exclude_requester_and_zero_peer_correlation :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 128)
		defer simulation_test_end(&ctx)
		workspace_id := "edge-handler-broadcast"
		wal_path, writer_ok := edge_handler_test_init_writer(workspace_id)
		defer os.remove(wal_path)
		testing.expect(t, writer_ok, "edge handler simulation writer should initialize")
		if !writer_ok do return
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.edge_seq = 0

		sender := edge_handler_test_install_client(&ctx, 1, workspace_id, "alice")
		peer := edge_handler_test_install_client(&ctx, 2, workspace_id, "bob")
		outsider := edge_handler_test_install_client(&ctx, 3, workspace_id, "carol")
		if sender == nil || peer == nil || outsider == nil do return
		conv_id := pr.ConversationID(84)
		conv := get_or_create_conversation(sender.workspace, conv_id)
		testing.expect(t, edge_handler_test_add_asset(conv, conv_id, 1), "source fixture should allocate")
		testing.expect(t, edge_handler_test_add_asset(conv, conv_id, 2), "target fixture should allocate")
		conversation_add_subscriber(conv, sender)
		conversation_add_subscriber(conv, peer)

		handle_create_edge(
			sender,
			pr.CreateEdgeRequest {
				conv_id = conv_id,
				source_type = .Asset,
				source_id = 1,
				target_type = .Asset,
				target_id = 2,
				relation = .RelatedTo,
				correlation_id = 231,
			},
		)
		sender_payload, sender_ok := edge_handler_test_payload(t, &ctx.sim, sender, .S_EdgeCreated)
		peer_payload, peer_ok := edge_handler_test_payload(t, &ctx.sim, peer, .S_EdgeCreated)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, outsider.sock), 0)
		if sender_ok {
			created, parse_err := pr.parseEdgeCreatedMessage(sender_payload)
			testing.expect(t, parse_err == nil, "requester S_EdgeCreated should decode")
			testing.expect_value(t, created.correlation_id, u32(231))
			testing.expect_value(t, created.edge.edge_id, pr.EdgeID(1))
		}
		if peer_ok {
			created, parse_err := pr.parseEdgeCreatedMessage(peer_payload)
			testing.expect(t, parse_err == nil, "peer S_EdgeCreated should decode")
			testing.expect_value(t, created.correlation_id, u32(0))
			testing.expect_value(t, created.edge.edge_id, pr.EdgeID(1))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_delete_edge(sender, pr.DeleteEdgeRequest{conv_id = conv_id, edge_id = 1, correlation_id = 232})
		sender_payload, sender_ok = edge_handler_test_payload(t, &ctx.sim, sender, .S_EdgeDeleted)
		peer_payload, peer_ok = edge_handler_test_payload(t, &ctx.sim, peer, .S_EdgeDeleted)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, outsider.sock), 0)
		if sender_ok {
			deleted, parse_err := pr.parseEdgeDeletedMessage(sender_payload)
			testing.expect(t, parse_err == nil, "requester S_EdgeDeleted should decode")
			testing.expect_value(t, deleted.correlation_id, u32(232))
			testing.expect_value(t, deleted.edge_id, pr.EdgeID(1))
		}
		if peer_ok {
			deleted, parse_err := pr.parseEdgeDeletedMessage(peer_payload)
			testing.expect(t, parse_err == nil, "peer S_EdgeDeleted should decode")
			testing.expect_value(t, deleted.correlation_id, u32(0))
			testing.expect_value(t, deleted.edge_id, pr.EdgeID(1))
		}
		testing.expect_value(t, len(conv.edges), 0)
		testing.expect_value(t, len(conv.edges_by_entity), 0)
	}
}
