package main

import "core:testing"

import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: hgl.run
	_ :: pr.parseDMErrorMessage
}

when NRC_SIMULATION {
	dm_sim_install :: proc(ctx: ^Sim_Test_Context, client_id: int, workspace_id: string, username: string, authenticated: bool = true) -> ^NRC_Connection {
		conn := simulation_test_install_client(&ctx.sim, client_id, workspace_id, username)
		if conn == nil {
			return nil
		}
		ctx.conns[client_id] = conn
		if !authenticated {
			untrack_user_connection(conn)
			conn.authenticated = false
			conn.verified_username = ""
		}
		return conn
	}

	dm_sim_track_connected :: proc(conn: ^NRC_Connection) -> ^Workspace_State {
		ws := get_connection_workspace(conn)
		if ws != nil {
			on_user_connect(ws, intern_username(conn.verified_username), conn.authenticated)
		}
		return ws
	}

	dm_sim_payload :: proc(t: ^testing.T, ctx: ^Sim_Test_Context, conn: ^NRC_Connection, index: int = 0) -> []u8 {
		frame := nrc_sim_client_frame(&ctx.sim, conn.sock, index)
		payload, ok := nrc_sim_frame_protocol_payload(frame)
		testing.expect(t, ok, "expected captured WebSocket frame to decode")
		return payload
	}

	dm_sim_find_payload :: proc(ctx: ^Sim_Test_Context, conn: ^NRC_Connection, opcode: pr.Opcode) -> ([]u8, bool) {
		for i in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
			payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, i))
			if ok && pr.get_opcode(payload) == opcode {
				return payload, true
			}
		}
		return nil, false
	}

	dm_sim_opcode_count :: proc(ctx: ^Sim_Test_Context, conn: ^NRC_Connection, opcode: pr.Opcode) -> int {
		count := 0
		for i in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
			payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, i))
			if ok && pr.get_opcode(payload) == opcode do count += 1
		}
		return count
	}

	dm_sim_expect_error :: proc(
		t: ^testing.T,
		ctx: ^Sim_Test_Context,
		conn: ^NRC_Connection,
		code: pr.DM_Error_Code,
		target: string,
		message: string,
		correlation_id: u32,
	) {
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
		payload := dm_sim_payload(t, ctx, conn)
		if payload == nil do return
		response, err := pr.parseDMErrorMessage(payload)
		testing.expect(t, err == nil, "expected S_DMError response to parse")
		testing.expect_value(t, response.code, code)
		testing.expect(t, response.target_username == target, "S_DMError target should match exactly")
		testing.expect(t, response.message == message, "S_DMError message should match exactly")
		testing.expect_value(t, response.correlation_id, correlation_id)
	}

	dm_sim_expect_left :: proc(t: ^testing.T, ctx: ^Sim_Test_Context, conn: ^NRC_Connection, conv_id: pr.ConversationID, correlation_id: u32) {
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
		payload := dm_sim_payload(t, ctx, conn)
		if payload == nil do return
		response, err := pr.parseDMLeftMessage(payload)
		testing.expect(t, err == nil, "expected S_DMLeft response to parse")
		testing.expect_value(t, response.conv_id, conv_id)
		testing.expect_value(t, response.correlation_id, correlation_id)
	}

	// Membership changes are committed inputs to this transport campaign. The
	// SQLite executor's start/leave/read ordering is tested in worker_db_test_dms
	// and worker_db_test_dm_retained, not modeled as synchronous receive effects.
	dm_cached_transport_run :: proc(split: int, newest: bool) -> string {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 186)
		defer simulation_test_end(&ctx)
		alice := dm_sim_install(&ctx, 1, "cached-dm", "alice")
		bob := dm_sim_install(&ctx, 2, "cached-dm", "bob")
		outsider := dm_sim_install(&ctx, 3, "cached-dm", "mallory")
		foreign_client := dm_sim_install(&ctx, 4, "other-dm", "bob")
		if alice == nil || bob == nil || outsider == nil || foreign_client == nil do return "client installation"
		id := pr.make_dm_conversation_id("alice", "bob")
		workspace := get_connection_workspace(alice)
		worker_db_apply_dm_state(workspace, {id = id, user_a = "alice", user_b = "bob", members = 3})
		buffer: [256]byte
		for conn, index in ([4]^NRC_Connection{alice, bob, outsider, foreign_client}) {
			n := pr.serializeSubscribeConvsV2Request({conv_ids = {id}, correlation_id = u32(100 + index)}, buffer[:])
			if !handler_equivalence_deliver_wire(&ctx.sim, conn, buffer[:n], split + index, split + index + 3) do return "split subscription"
		}
		if !simulation_test_publish_output(&ctx.sim) do return "subscription publication"
		nrc_sim_run_all_send_completions(&ctx.sim)
		for conn, index in ([4]^NRC_Connection{alice, bob, outsider, foreign_client}) {
			if index < 2 {
				payload, ok := dm_sim_find_payload(&ctx, conn, .S_SubscriptionReady)
				if !ok do return "missing subscription ACK"
				ready, err := pr.parseSubscriptionReady(payload[2:])
				if err != nil || ready.correlation_id != u32(100 + index) do return "subscription ACK correlation"
			} else {
				payload, ok := dm_sim_find_payload(&ctx, conn, .S_ErrorResponse)
				if !ok do return "missing unauthorized subscription rejection"
				err, parse_err := pr.parseErrorResponseMessage(payload)
				if parse_err != nil || err.correlation_id != u32(100 + index) || string(err.error_msg) != "DM access denied" do return "subscription rejection"
				if len(conn.rooms) != 0 do return "unauthorized subscription installed"
			}
		}
		nrc_sim_clear_inboxes(&ctx.sim)
		for conn, index in ([3]^NRC_Connection{alice, outsider, foreign_client}) {
			n := pr.serializeSendMessageRequest(id, u32(200 + index), .PlainText, []byte{'p', 'r', 'i', 'v', 'a', 't', 'e'}, buffer[:])
			frame := make_test_ws_frame(buffer[:n], .opBinary, true)
			cut := 1 + (split + index) % (len(frame) - 1)
			ok := nrc_sim_enqueue_receive(&ctx.sim, conn, frame[:cut]) && nrc_sim_enqueue_receive(&ctx.sim, conn, frame[cut:])
			delete(frame)
			if !ok do return "split message enqueue"
		}
		for len(ctx.sim.world.events) > 0 {
			count := sim_world_prepare_runnable(&ctx.sim.world)
			if count <= 0 || !sim_world_run_runnable_rank(&ctx.sim.world, newest ? count - 1 : 0) do return "transport event stalled"
		}
		if !simulation_test_publish_output(&ctx.sim) do return "message publication"
		nrc_sim_run_all_send_completions(&ctx.sim)
		if dm_sim_opcode_count(&ctx, alice, .S_AckSendMessage) != 1 || dm_sim_opcode_count(&ctx, bob, .S_NewMessage) != 1 do return "authorized fanout"
		payload, found := dm_sim_find_payload(&ctx, bob, .S_NewMessage)
		if !found do return "missing private message"
		message, err := pr.parseNewMessageEventMessage(payload)
		if err != nil || message.conv_id != id || string(message.content) != "private" || string(message.author_username) != "alice" do return "private message content"
		for conn in ([2]^NRC_Connection{outsider, foreign_client}) {
			if nrc_sim_client_frame_count(&ctx.sim, conn.sock) != 1 || dm_sim_opcode_count(&ctx, conn, .S_ErrorResponse) != 1 do return "private fanout escaped ACL"
		}
		for conn in ([4]^NRC_Connection{alice, bob, outsider, foreign_client}) {
			if conn.receive_accumulator.buf != nil || conn.fragment_buf != nil || conn.fragment_len != 0 do return "receive ownership retained"
		}
		if td.spool.used != 0 do return "send ownership retained"
		return ""
	}

	prop_cached_dm_transport :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		split, err := hgl.draw_i64(tc, 0, 255)
		if err == .Stop_Test do return hgl.abort()
		if err != nil do return hgl.interesting("split draw")
		order, order_err := hgl.draw_i64(tc, 0, 1)
		if order_err == .Stop_Test do return hgl.abort()
		if order_err != nil do return hgl.interesting("order draw")
		if reason := dm_cached_transport_run(int(split), order != 0); reason != "" do return hgl.interesting(reason)
		return hgl.valid()
	}
}

@(test)
test_hegel_cached_dm_transport_authorization_and_ownership :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		for split in ([4]int{0, 1, 127, 255}) {
			for order in 0 ..< 2 do testing.expect_value(t, dm_cached_transport_run(split, order != 0), "")
		}
		if !hgl.can_run() do return
		result, err := hgl.run(prop_cached_dm_transport, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "cached DM transport: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_simulation_dm_rejects_unauthenticated_self_and_unknown_start :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 181)
		defer simulation_test_end(&ctx)
		database := dm_test_database()
		defer dm_test_database_destroy(&database)

		guest := dm_sim_install(&ctx, 1, "dm_start_denials", "guest", false)
		alice := dm_sim_install(&ctx, 2, "dm_start_denials", "alice")
		testing.expect(t, guest != nil && alice != nil, "expected denial clients to install")
		if guest == nil || alice == nil do return
		ws := dm_sim_track_connected(alice)
		testing.expect(t, ws != nil, "expected denial workspace")
		if ws == nil do return

		dm_test_start(&database, guest, pr.StartDMRequest{username = "alice", correlation_id = 101})
		dm_sim_expect_error(t, &ctx, guest, .Not_Authenticated, "alice", "Not authenticated", 101)
		testing.expect_value(t, len(ws.conversations), 0)
		testing.expect_value(t, len(ws.user_dms), 0)
		testing.expect_value(t, len(guest.rooms), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_list(&database, guest, pr.ListDMsRequest{correlation_id = 104})
		dm_sim_expect_error(t, &ctx, guest, .Not_Authenticated, "", "Not authenticated", 104)
		testing.expect_value(t, len(ws.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_leave(&database, guest, pr.LeaveDMRequest{conv_id = pr.make_dm_conversation_id("alice", "guest"), correlation_id = 105})
		dm_sim_expect_error(t, &ctx, guest, .Not_Authenticated, "", "Not authenticated", 105)
		testing.expect_value(t, len(ws.conversations), 0)
		testing.expect_value(t, len(ws.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_start(&database, alice, pr.StartDMRequest{username = "alice", correlation_id = 102})
		dm_sim_expect_error(t, &ctx, alice, .Cannot_DM_Self, "alice", "Cannot start DM with yourself", 102)
		testing.expect_value(t, len(ws.conversations), 0)
		testing.expect_value(t, len(ws.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_start(&database, alice, pr.StartDMRequest{username = "missing", correlation_id = 103})
		dm_sim_expect_error(t, &ctx, alice, .User_Not_Found, "missing", "User not found", 103)
		testing.expect_value(t, len(ws.conversations), 0)
		testing.expect_value(t, len(ws.user_dms), 0)
		testing.expect_value(t, len(alice.rooms), 0)
	}
}

@(test)
test_simulation_dm_non_member_cannot_subscribe_leave_or_send :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 182)
		defer simulation_test_end(&ctx)
		database := dm_test_database()
		defer dm_test_database_destroy(&database)

		alice := dm_sim_install(&ctx, 1, "dm_access", "alice")
		bob := dm_sim_install(&ctx, 2, "dm_access", "bob")
		mallory := dm_sim_install(&ctx, 3, "dm_access", "mallory")
		testing.expect(t, alice != nil && bob != nil && mallory != nil, "expected access clients to install")
		if alice == nil || bob == nil || mallory == nil do return
		ws := dm_sim_track_connected(alice)
		_ = dm_sim_track_connected(bob)
		_ = dm_sim_track_connected(mallory)
		conv_id := pr.make_dm_conversation_id("alice", "bob")
		dm_test_start(&database, alice, pr.StartDMRequest{username = "bob", correlation_id = 201})
		conv := get_conversation(ws, conv_id)
		testing.expect(t, conv != nil, "expected DM conversation")
		if conv == nil do return
		testing.expect_value(t, subscriber_count(conv), 2)

		nrc_sim_clear_inboxes(&ctx.sim)
		subscribe_to_conversation(mallory, conv_id)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, mallory.sock), 0)
		testing.expect(t, !conversation_has_subscriber(conv, mallory.sock), "non-member subscription must be denied")
		testing.expect(t, conv_id not_in mallory.rooms, "denied DM must not enter socket membership map")
		testing.expect_value(t, subscriber_count(conv), 2)

		dm_test_leave(&database, mallory, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 202})
		dm_sim_expect_error(t, &ctx, mallory, .DM_Not_Found, "", "Not in this DM", 202)
		testing.expect(t, "mallory" not_in ws.user_dms, "leave denial must not create user DM membership")
		testing.expect_value(t, subscriber_count(conv), 2)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_leave(&database, mallory, pr.LeaveDMRequest{conv_id = 44, correlation_id = 203})
		dm_sim_expect_error(t, &ctx, mallory, .DM_Not_Found, "", "Not a DM conversation", 203)

		nrc_sim_clear_inboxes(&ctx.sim)
		content := "intrusion"
		process_send_message(
			mallory,
			pr.SendMessageRequest{conv_id = conv_id, client_req_id = 204, content_type = .PlainText, content = transmute([]byte)content},
		)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, mallory.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		payload := dm_sim_payload(t, &ctx, mallory)
		if payload != nil {
			response, err := pr.parseErrorResponseMessage(payload)
			testing.expect(t, err == nil, "expected unauthorized DM send error to parse")
			testing.expect_value(t, response.origin_opcode, pr.Opcode.C_SendMessage)
			testing.expect(t, string(response.error_msg) == "DM access denied", "DM send error should be exact")
			testing.expect_value(t, response.correlation_id, u32(204))
		}
		testing.expect_value(t, subscriber_count(conv), 2)
	}
}

@(test)
test_simulation_dm_repeated_start_leave_and_orphan_cleanup :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 183)
		defer simulation_test_end(&ctx)
		database := dm_test_database()
		defer dm_test_database_destroy(&database)

		alice := dm_sim_install(&ctx, 1, "dm_repeat", "alice")
		bob := dm_sim_install(&ctx, 2, "dm_repeat", "bob")
		if alice == nil || bob == nil do return
		ws := dm_sim_track_connected(alice)
		_ = dm_sim_track_connected(bob)
		conv_id := pr.make_dm_conversation_id("alice", "bob")

		dm_test_start(&database, alice, pr.StartDMRequest{username = "bob", correlation_id = 301})
		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_start(&database, alice, pr.StartDMRequest{username = "bob", correlation_id = 302})
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		started_payload := dm_sim_payload(t, &ctx, alice)
		if started_payload != nil {
			started, err := pr.parseDMStartedMessage(started_payload)
			testing.expect(t, err == nil, "repeated S_DMStarted should parse")
			testing.expect_value(t, started.conv_id, conv_id)
			testing.expect_value(t, started.correlation_id, u32(302))
		}
		conv := get_conversation(ws, conv_id)
		testing.expect(t, conv != nil, "repeated start should retain conversation")
		if conv == nil do return
		testing.expect_value(t, len(ws.user_dms["alice"].ids), 1)
		testing.expect_value(t, len(ws.user_dms["bob"].ids), 1)
		testing.expect_value(t, subscriber_count(conv), 2)
		testing.expect_value(t, len(alice.rooms), 1)
		testing.expect_value(t, len(bob.rooms), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_leave(&database, alice, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 303})
		dm_sim_expect_left(t, &ctx, alice, conv_id, 303)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		testing.expect(t, "alice" not_in ws.user_dms, "first leave should remove alice membership")
		testing.expect_value(t, len(ws.user_dms["bob"].ids), 1)
		testing.expect(t, conv_id not_in alice.rooms, "first leave should remove alice socket membership")
		testing.expect(t, conversation_has_subscriber(conv, bob.sock), "first leave should retain bob subscriber")
		testing.expect_value(t, subscriber_count(conv), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		subscribe_to_conversation(alice, conv_id)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 0)
		testing.expect(t, conv_id not_in alice.rooms, "leaver must not restore socket membership by subscribing")
		testing.expect(t, !conversation_has_subscriber(conv, alice.sock), "leaver must not restore subscriber state")
		testing.expect_value(t, subscriber_count(conv), 1)

		content := "after leave"
		process_send_message(
			alice,
			pr.SendMessageRequest{conv_id = conv_id, client_req_id = 307, content_type = .PlainText, content = transmute([]byte)content},
		)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		denied_payload := dm_sim_payload(t, &ctx, alice)
		if denied_payload != nil {
			denied, err := pr.parseErrorResponseMessage(denied_payload)
			testing.expect(t, err == nil, "post-leave DM send error should parse")
			testing.expect_value(t, denied.origin_opcode, pr.Opcode.C_SendMessage)
			testing.expect(t, string(denied.error_msg) == "DM access denied", "post-leave DM send error should be exact")
			testing.expect_value(t, denied.correlation_id, u32(307))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_leave(&database, alice, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 304})
		dm_sim_expect_error(t, &ctx, alice, .DM_Not_Found, "", "Not in this DM", 304)
		testing.expect_value(t, subscriber_count(conv), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_leave(&database, bob, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 305})
		dm_sim_expect_left(t, &ctx, bob, conv_id, 305)
		testing.expect(t, get_conversation(ws, conv_id) == nil, "last leave should destroy orphaned DM")
		testing.expect(t, "bob" not_in ws.user_dms, "last leave should remove bob membership map")
		testing.expect(t, conv_id not_in bob.rooms, "last leave should remove bob socket membership")
		testing.expect_value(t, len(ws.conversations), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_leave(&database, bob, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 306})
		dm_sim_expect_error(t, &ctx, bob, .DM_Not_Found, "", "Not in this DM", 306)
	}
}

@(test)
test_simulation_dm_disconnect_cleans_subscriber_not_persistent_membership :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 184)
		defer simulation_test_end(&ctx)
		database := dm_test_database()
		defer dm_test_database_destroy(&database)

		alice := dm_sim_install(&ctx, 1, "dm_disconnect", "alice")
		bob := dm_sim_install(&ctx, 2, "dm_disconnect", "bob")
		if alice == nil || bob == nil do return
		ws := dm_sim_track_connected(alice)
		_ = dm_sim_track_connected(bob)
		conv_id := pr.make_dm_conversation_id("alice", "bob")
		dm_test_start(&database, alice, pr.StartDMRequest{username = "bob", correlation_id = 401})
		conv := get_conversation(ws, conv_id)
		if conv == nil do return

		nrc_sim_clear_inboxes(&ctx.sim)
		connection_run_logical_cleanup(alice, false)
		testing.expect(t, simulation_test_publish_output(&ctx.sim))
		testing.expect(t, alice.logical_cleanup_done, "disconnect should run logical cleanup")
		testing.expect(t, alice.rooms == nil, "disconnect should release socket membership map")
		testing.expect(t, !conversation_has_subscriber(conv, alice.sock), "disconnect should remove alice subscriber")
		testing.expect(t, conversation_has_subscriber(conv, bob.sock), "disconnect should retain bob subscriber")
		testing.expect_value(t, subscriber_count(conv), 1)
		testing.expect_value(t, len(ws.user_dms["alice"].ids), 1)
		testing.expect_value(t, len(ws.user_dms["bob"].ids), 1)
		testing.expect(t, !is_user_online(ws, "alice"), "last alice disconnect should clear online map")
		testing.expect(t, !is_user_authenticated(ws, "alice"), "last alice disconnect should clear authenticated map")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 2)
		testing.expect_value(t, dm_sim_opcode_count(&ctx, bob, .S_RoomPresenceUpdate), 1)
		testing.expect_value(t, dm_sim_opcode_count(&ctx, bob, .S_DMPartnerStatus), 1)
		status_payload, status_ok := dm_sim_find_payload(&ctx, bob, .S_DMPartnerStatus)
		testing.expect(t, status_ok, "disconnect should fan out one DM partner status")
		if status_ok {
			status, err := pr.parseDMPartnerStatusMessage(status_payload)
			testing.expect(t, err == nil, "disconnect status should parse")
			testing.expect_value(t, status.conv_id, conv_id)
			testing.expect(t, status.username == "alice", "disconnect status should identify alice")
			testing.expect(t, !status.online, "disconnect status should be offline")
			testing.expect(t, status.last_seen > 0, "disconnect status should include last_seen")
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		connection_run_logical_cleanup(alice, false)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		testing.expect_value(t, subscriber_count(conv), 1)
	}
}

@(test)
test_simulation_dm_workspace_isolation_for_lookup_state_and_fanout :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 185)
		defer simulation_test_end(&ctx)
		database := dm_test_database()
		defer dm_test_database_destroy(&database)

		alice_a := dm_sim_install(&ctx, 1, "dm_workspace_a", "alice")
		bob_b := dm_sim_install(&ctx, 2, "dm_workspace_b", "bob")
		if alice_a == nil || bob_b == nil do return
		ws_a := dm_sim_track_connected(alice_a)
		ws_b := dm_sim_track_connected(bob_b)

		dm_test_start(&database, alice_a, pr.StartDMRequest{username = "bob", correlation_id = 501})
		dm_sim_expect_error(t, &ctx, alice_a, .User_Not_Found, "bob", "User not found", 501)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob_b.sock), 0)
		testing.expect_value(t, len(ws_a.user_dms), 0)
		testing.expect_value(t, len(ws_b.user_dms), 0)

		bob_a := dm_sim_install(&ctx, 3, "dm_workspace_a", "bob")
		alice_b := dm_sim_install(&ctx, 4, "dm_workspace_b", "alice")
		if bob_a == nil || alice_b == nil do return
		_ = dm_sim_track_connected(bob_a)
		_ = dm_sim_track_connected(alice_b)
		conv_id := pr.make_dm_conversation_id("alice", "bob")

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_start(&database, alice_a, pr.StartDMRequest{username = "bob", correlation_id = 502})
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_a.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob_a.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_b.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob_b.sock), 0)
		conv_a := get_conversation(ws_a, conv_id)
		testing.expect(t, conv_a != nil, "workspace A should own its DM conversation")
		testing.expect(t, get_conversation(ws_b, conv_id) == nil, "workspace B should remain independent")
		testing.expect_value(t, len(ws_a.user_dms["alice"].ids), 1)
		testing.expect_value(t, len(ws_a.user_dms["bob"].ids), 1)
		testing.expect_value(t, len(ws_b.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		dm_test_start(&database, alice_b, pr.StartDMRequest{username = "bob", correlation_id = 503})
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_a.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob_a.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_b.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob_b.sock), 1)
		conv_b := get_conversation(ws_b, conv_id)
		testing.expect(t, conv_b != nil && conv_b != conv_a, "each workspace should own distinct DM state")
		if conv_a != nil && conv_b != nil {
			testing.expect_value(t, subscriber_count(conv_a), 2)
			testing.expect_value(t, subscriber_count(conv_b), 2)
			testing.expect(t, conversation_has_subscriber(conv_a, alice_a.sock), "workspace A should contain alice A")
			testing.expect(t, !conversation_has_subscriber(conv_a, alice_b.sock), "workspace A must exclude alice B")
			testing.expect(t, conversation_has_subscriber(conv_b, alice_b.sock), "workspace B should contain alice B")
			testing.expect(t, !conversation_has_subscriber(conv_b, alice_a.sock), "workspace B must exclude alice A")
		}
	}
}
