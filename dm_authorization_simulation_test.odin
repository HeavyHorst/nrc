package main

import "core:container/queue"
import "core:encoding/endian"
import "core:fmt"
import "core:testing"

import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: endian.put_u16
	_ :: fmt.eprintf
	_ :: hgl.run
	_ :: pr.parseDMErrorMessage
	_ :: queue.len
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

	DM_GENERATED_CLIENTS :: 4
	DM_GENERATED_WORKSPACES :: 2
	DM_GENERATED_CASES :: 96
	DM_GENERATED_MAX_OPS :: 16
	DM_PENDING_SEND_CONTENTS :: [?]string {
		"pending-send-0",
		"pending-send-1",
		"pending-send-2",
		"pending-send-3",
		"pending-send-4",
		"pending-send-5",
		"pending-send-6",
		"pending-send-7",
		"pending-send-8",
		"pending-send-9",
		"pending-send-10",
		"pending-send-11",
	}

	DM_Generated_Op_Kind :: enum u8 {
		Start,
		Leave,
		Subscribe,
		Send,
		Disconnect,
		Reconnect,
	}

	DM_Generated_Op :: struct {
		kind:         DM_Generated_Op_Kind,
		client_id:    int,
		split_choice: u8,
	}

	DM_Pending_Generated_Op :: struct {
		op:                      DM_Generated_Op,
		completion_id:           u64,
		output_group:            int,
		applied:                 bool,
		canceled:                bool,
		send_authorized:         bool,
		response_canceled:       bool,
		expected_recipient_mask: u8,
		seen_recipient_mask:     u8,
		canceled_recipient_mask: u8,
		expected_started_mask:   u8,
		seen_started_mask:       u8,
		canceled_started_mask:   u8,
		expected_left_mask:      u8,
		seen_left_mask:          u8,
		canceled_left_mask:      u8,
		expected_dm_error_mask:  u8,
		seen_dm_error_mask:      u8,
		canceled_dm_error_mask:  u8,
		expected_user_list_mask: u8,
		seen_user_list_mask:     u8,
		canceled_user_list_mask: u8,
		expected_user_join_mask: u8,
		seen_user_join_mask:     u8,
		canceled_user_join_mask: u8,
		expected_user_list:      u8,
		dm_error_code:           pr.DM_Error_Code,
		ack_count:               int,
		denial_count:            int,
		ack_seq:                 pr.MessageSeq,
		ack_timestamp:           i64,
		message_seq:             pr.MessageSeq,
		message_timestamp:       i64,
		message_content_type:    pr.MessageContentType,
	}

	DM_Pending_Lifecycle_Connection :: struct {
		client_id: int,
		handle:    Connection_Handle,
		counted:   bool,
	}

	DM_Generated_Model :: struct {
		connected:  [DM_GENERATED_CLIENTS]bool,
		member:     [DM_GENERATED_WORKSPACES][2]bool,
		subscribed: [DM_GENERATED_CLIENTS]bool,
	}

	dm_generated_workspace_index :: proc(client_id: int) -> int {
		return client_id / 2
	}

	dm_generated_user_index :: proc(client_id: int) -> int {
		return client_id % 2
	}

	dm_generated_workspace :: proc(client_id: int) -> string {
		if dm_generated_workspace_index(client_id) == 0 do return "dm_generated_a"
		return "dm_generated_b"
	}

	dm_generated_username :: proc(client_id: int) -> string {
		if dm_generated_user_index(client_id) == 0 do return "alice"
		return "bob"
	}

	dm_generated_conv_id :: proc() -> pr.ConversationID {
		return pr.make_dm_conversation_id("alice", "bob")
	}

	dm_pending_send_content :: proc(index: int) -> string {
		contents := DM_PENDING_SEND_CONTENTS
		return contents[index]
	}

	dm_generated_install :: proc(ctx: ^Sim_Test_Context, model: ^DM_Generated_Model, client_id: int) -> bool {
		conn := dm_sim_install(ctx, client_id + 1, dm_generated_workspace(client_id), dm_generated_username(client_id))
		if conn == nil do return false
		_ = dm_sim_track_connected(conn)
		model.connected[client_id] = true
		return true
	}

	dm_generated_connection :: proc(ctx: ^Sim_Test_Context, client_id: int) -> ^NRC_Connection {
		return ctx.conns[client_id + 1]
	}

	dm_generated_opcode :: proc(ctx: ^Sim_Test_Context, client_id: int, frame_index: int = 0) -> (pr.Opcode, bool) {
		sock := connection_test_fake_socket(client_id + 1)
		payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, sock, frame_index))
		if !ok do return {}, false
		return pr.get_opcode(payload), true
	}

	dm_generated_expect_exact_dm_error :: proc(
		ctx: ^Sim_Test_Context,
		client_id: int,
		code: pr.DM_Error_Code,
		target, message: string,
		correlation_id: u32,
	) -> (
		string,
		bool,
	) {
		for candidate in 0 ..< DM_GENERATED_CLIENTS {
			expected := candidate == client_id ? 1 : 0
			actual := nrc_sim_client_frame_count(&ctx.sim, connection_test_fake_socket(candidate + 1))
			if actual != expected do return "denied DM operation reached an unintended recipient", false
		}
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, connection_test_fake_socket(client_id + 1), 0))
		if !payload_ok do return "denied DM operation produced invalid frame", false
		response, err := pr.parseDMErrorMessage(payload)
		if err != nil ||
		   response.code != code ||
		   response.target_username != target ||
		   response.message != message ||
		   response.correlation_id != correlation_id {
			return "denied DM operation response differs from model", false
		}
		return "", true
	}

	dm_generated_expect_no_frames :: proc(ctx: ^Sim_Test_Context) -> (string, bool) {
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			if nrc_sim_client_frame_count(&ctx.sim, connection_test_fake_socket(client_id + 1)) != 0 {
				return "denied DM subscription emitted a frame", false
			}
		}
		return "", true
	}

	dm_generated_check_state :: proc(ctx: ^Sim_Test_Context, model: ^DM_Generated_Model) -> (string, bool) {
		conv_id := dm_generated_conv_id()
		for workspace_index in 0 ..< DM_GENERATED_WORKSPACES {
			first_client := workspace_index * 2
			ws := td.workspaces[dm_generated_workspace(first_client)]
			if ws == nil do return "generated DM workspace missing", false

			expected_conversation := model.member[workspace_index][0] || model.member[workspace_index][1]
			conv := get_conversation(ws, conv_id)
			if (conv != nil) != expected_conversation do return "DM conversation existence differs from model", false
			expected_conversation_count := expected_conversation ? 1 : 0
			if len(ws.conversations) != expected_conversation_count do return "DM conversation map cardinality differs from model", false
			if expected_conversation && conv.dm_participants == nil do return "DM participants missing", false
			if expected_conversation && (conv.dm_participants.user_a != "alice" || conv.dm_participants.user_b != "bob") {
				return "DM participant identities differ from model", false
			}

			expected_members := 0
			for user_index in 0 ..< 2 {
				client_id := first_client + user_index
				username := dm_generated_username(client_id)
				if model.member[workspace_index][user_index] do expected_members += 1
				if is_user_in_dm(ws, username, conv_id) != model.member[workspace_index][user_index] {
					return "DM durable-in-memory membership differs from model", false
				}
				dms, has_dms := ws.user_dms[username]
				if has_dms != model.member[workspace_index][user_index] || (has_dms && (len(dms) != 1 || dms[0] != conv_id)) {
					return "DM membership index shape differs from model", false
				}
				if is_user_online(ws, username) != model.connected[client_id] {
					return "DM online state differs from model", false
				}

				conn := dm_generated_connection(ctx, client_id)
				if model.connected[client_id] != (conn != nil) do return "DM connection state differs from model", false
				expected_subscribed := model.connected[client_id] && model.subscribed[client_id]
				if expected_conversation && conversation_has_subscriber(conv, connection_test_fake_socket(client_id + 1)) != expected_subscribed {
					return "DM subscriber index differs from model", false
				}
				if conn != nil {
					_, in_rooms := conn.rooms[conv_id]
					expected_room_count := expected_subscribed ? 1 : 0
					if in_rooms != expected_subscribed || len(conn.rooms) != expected_room_count {
						return "connection DM room membership differs from model", false
					}
				}
			}
			if len(ws.user_dms) != expected_members do return "DM membership map cardinality differs from model", false
			expected_subscribers := 0
			for client_id in first_client ..< first_client + 2 {
				if model.subscribed[client_id] do expected_subscribers += 1
			}
			if expected_conversation && subscriber_count(conv) != expected_subscribers {
				return "DM subscriber count differs from model", false
			}
		}

		ws_a := td.workspaces[dm_generated_workspace(0)]
		ws_b := td.workspaces[dm_generated_workspace(2)]
		if ws_a != nil && ws_b != nil {
			conv_a := get_conversation(ws_a, conv_id)
			conv_b := get_conversation(ws_b, conv_id)
			if conv_a != nil && conv_a == conv_b do return "workspaces share DM conversation state", false
		}
		return "", true
	}

	dm_generated_validate_send :: proc(ctx: ^Sim_Test_Context, model: ^DM_Generated_Model, client_id: int, client_req_id: u32) -> (string, bool) {
		workspace_index := dm_generated_workspace_index(client_id)
		user_index := dm_generated_user_index(client_id)
		authorized := model.member[workspace_index][user_index]
		for candidate in 0 ..< DM_GENERATED_CLIENTS {
			sock := connection_test_fake_socket(candidate + 1)
			expected := 0
			if candidate == client_id {
				expected = 1
			} else if authorized && dm_generated_workspace_index(candidate) == workspace_index && model.subscribed[candidate] {
				expected = 1
			}
			actual := nrc_sim_client_frame_count(&ctx.sim, sock)
			if actual != expected do return "DM send recipient set differs from model", false
			if expected == 0 do continue

			payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, sock, 0))
			if !payload_ok do return "DM send produced invalid frame", false
			if candidate == client_id {
				if authorized {
					ack, err := pr.parseAckSendMessageMessage(payload)
					if err != nil || ack.client_req_id != client_req_id do return "authorized DM send did not return exact acknowledgment", false
				} else {
					response, err := pr.parseErrorResponseMessage(payload)
					if err != nil ||
					   response.origin_opcode != .C_SendMessage ||
					   response.correlation_id != client_req_id ||
					   string(response.error_msg) != "DM access denied" {
						return "unauthorized DM send did not return exact denial", false
					}
				}
			} else {
				message, err := pr.parseNewMessageEventMessage(payload)
				if err != nil || message.conv_id != dm_generated_conv_id() || string(message.author_username) != dm_generated_username(client_id) {
					return "DM recipient message differs from model", false
				}
			}
		}
		return "", true
	}

	dm_generated_apply :: proc(ctx: ^Sim_Test_Context, model: ^DM_Generated_Model, op: DM_Generated_Op, op_index: int) -> (string, bool) {
		if op.client_id < 0 || op.client_id >= DM_GENERATED_CLIENTS do return "generated DM client out of range", false
		nrc_sim_clear_inboxes(&ctx.sim)
		conn := dm_generated_connection(ctx, op.client_id)
		workspace_index := dm_generated_workspace_index(op.client_id)
		user_index := dm_generated_user_index(op.client_id)
		other_user_index := 1 - user_index
		other_client_id := workspace_index * 2 + other_user_index
		correlation_id := u32(op_index + 1)

		switch op.kind {
		case .Start:
			if conn == nil do break
			target_connected := model.connected[other_client_id]
			if !dm_kernel_enqueue_start(ctx, conn, dm_generated_username(other_client_id), correlation_id, -1, int(op.split_choice)) ||
			   !dm_kernel_run_operation_receives(&ctx.sim) {
				return "generated DM start did not dispatch through kernel receive", false
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			if target_connected {
				model.member[workspace_index][0] = true
				model.member[workspace_index][1] = true
				for candidate in workspace_index * 2 ..< workspace_index * 2 + 2 {
					model.subscribed[candidate] = model.connected[candidate]
				}
			} else {
				if reason, ok := dm_generated_expect_exact_dm_error(ctx, op.client_id, .User_Not_Found, dm_generated_username(other_client_id), "User not found", correlation_id); !ok do return reason, false
			}

		case .Leave:
			if conn == nil do break
			was_member := model.member[workspace_index][user_index]
			if !dm_kernel_enqueue_leave(ctx, conn, correlation_id, int(op.split_choice)) || !dm_kernel_run_operation_receives(&ctx.sim) {
				return "generated DM leave did not dispatch through kernel receive", false
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			if was_member {
				model.member[workspace_index][user_index] = false
				model.subscribed[op.client_id] = false
				if opcode, ok := dm_generated_opcode(ctx, op.client_id); !ok || opcode != .S_DMLeft {
					return "successful DM leave did not return S_DMLeft", false
				}
			} else {
				if reason, ok := dm_generated_expect_exact_dm_error(ctx, op.client_id, .DM_Not_Found, "", "Not in this DM", correlation_id); !ok do return reason, false
			}

		case .Subscribe:
			if conn == nil do break
			if !dm_kernel_enqueue_subscribe(ctx, conn, int(op.split_choice)) || !dm_kernel_run_operation_receives(&ctx.sim) {
				return "generated DM subscribe did not dispatch through kernel receive", false
			}
			if model.member[workspace_index][user_index] {
				model.subscribed[op.client_id] = true
			} else {
				nrc_sim_run_all_send_completions(&ctx.sim)
				if reason, ok := dm_generated_expect_no_frames(ctx); !ok do return reason, false
			}

		case .Send:
			if conn == nil do break
			content := "generated DM message"
			if !dm_kernel_enqueue_send(ctx, conn, correlation_id, content, int(op.split_choice)) || !dm_kernel_run_operation_receives(&ctx.sim) {
				return "generated DM send did not dispatch through kernel receive", false
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			if reason, ok := dm_generated_validate_send(ctx, model, op.client_id, correlation_id); !ok do return reason, false

		case .Disconnect:
			if conn == nil do break
			connection_run_logical_cleanup(conn, false)
			nrc_sim_run_all_send_completions(&ctx.sim)
			simulation_test_uninstall_client(conn)
			ctx.conns[op.client_id + 1] = nil
			model.connected[op.client_id] = false
			model.subscribed[op.client_id] = false

		case .Reconnect:
			if conn != nil do break
			if !dm_generated_install(ctx, model, op.client_id) do return "generated DM reconnect failed", false
		}

		// All generated operations are workspace-local. Presence and protocol fanout
		// may vary by operation, but no frame may cross the workspace boundary.
		for candidate in 0 ..< DM_GENERATED_CLIENTS {
			if dm_generated_workspace_index(candidate) == workspace_index do continue
			if nrc_sim_client_frame_count(&ctx.sim, connection_test_fake_socket(candidate + 1)) != 0 {
				return "generated DM operation crossed workspace boundary", false
			}
		}
		return dm_generated_check_state(ctx, model)
	}

	dm_generated_run :: proc(ops: []DM_Generated_Op, log_failure: bool) -> (string, bool) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 186)
		defer simulation_test_end(&ctx)
		model: DM_Generated_Model
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			if !dm_generated_install(&ctx, &model, client_id) do return "generated DM initial connection failed", false
		}
		nrc_sim_clear_inboxes(&ctx.sim)

		for op, op_index in ops {
			if reason, ok := dm_generated_apply(&ctx, &model, op, op_index); !ok {
				if log_failure {
					fmt.eprintf("Generated DM replay failure: op=%d reason=%s\nops := [?]DM_Generated_Op {\n", op_index, reason)
					for replay_op in ops[:op_index + 1] {
						fmt.eprintf("\t{kind = .%v, client_id = %d, split_choice = %d},\n", replay_op.kind, replay_op.client_id, replay_op.split_choice)
					}
					fmt.eprintf("}\n")
				}
				return reason, false
			}
		}
		return "", true
	}

	prop_generated_dm_authorization :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count, count_err := hgl.draw_i64(tc, 0, DM_GENERATED_MAX_OPS)
		if count_err == .Stop_Test do return hgl.abort()
		if count_err != nil do return hgl.interesting("draw generated DM operation count")
		prefix := [?]DM_Generated_Op {
			{kind = .Start, client_id = 0, split_choice = 1},
			{kind = .Start, client_id = 2, split_choice = 64},
			{kind = .Send, client_id = 0, split_choice = 255},
			{kind = .Leave, client_id = 1, split_choice = 128},
			{kind = .Leave, client_id = 1},
			{kind = .Send, client_id = 1},
			{kind = .Disconnect, client_id = 1},
			{kind = .Reconnect, client_id = 1},
			{kind = .Subscribe, client_id = 1},
			{kind = .Disconnect, client_id = 0},
			{kind = .Start, client_id = 1},
			{kind = .Reconnect, client_id = 0},
			{kind = .Subscribe, client_id = 0},
			{kind = .Send, client_id = 0},
			{kind = .Leave, client_id = 0},
			{kind = .Start, client_id = 1},
			{kind = .Send, client_id = 1},
		}
		ops := make([dynamic]DM_Generated_Op, 0, len(prefix) + int(op_count))
		defer delete(ops)
		append(&ops, ..prefix[:])
		for _ in 0 ..< int(op_count) {
			kind, kind_err := hgl.draw_i64(tc, 0, i64(DM_Generated_Op_Kind.Reconnect))
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("draw generated DM operation kind")
			client_id, client_err := hgl.draw_i64(tc, 0, DM_GENERATED_CLIENTS - 1)
			if client_err == .Stop_Test do return hgl.abort()
			if client_err != nil do return hgl.interesting("draw generated DM client")
			split_choice, split_err := hgl.draw_i64(tc, 0, 255)
			if split_err == .Stop_Test do return hgl.abort()
			if split_err != nil do return hgl.interesting("draw generated DM receive split")
			append(&ops, DM_Generated_Op{kind = DM_Generated_Op_Kind(kind), client_id = int(client_id), split_choice = u8(split_choice)})
		}
		reason, ok := dm_generated_run(ops[:], tc.is_final)
		if !ok do return hgl.interesting(reason)
		return hgl.valid()
	}

	dm_kernel_enqueue_protocol_frame :: proc(ctx: ^Sim_Test_Context, conn: ^NRC_Connection, payload: []byte, split: int = -1, split_choice: int = 0) -> bool {
		frame := make_test_ws_frame(payload, .opBinary, true)
		defer delete(frame)
		split_at := split
		if split_choice > 0 {
			split_at = 1 + (split_choice - 1) * (len(frame) - 1) / 255
		}
		if split_at <= 0 || split_at >= len(frame) {
			return nrc_sim_enqueue_receive(&ctx.sim, conn, frame)
		}
		return nrc_sim_enqueue_receive(&ctx.sim, conn, frame[:split_at]) && nrc_sim_enqueue_receive(&ctx.sim, conn, frame[split_at:])
	}

	dm_kernel_enqueue_start :: proc(
		ctx: ^Sim_Test_Context,
		conn: ^NRC_Connection,
		target: string,
		correlation_id: u32,
		split: int = -1,
		split_choice: int = 0,
	) -> bool {
		buf: [128]byte
		endian.put_u16(buf[0:2], .Big, u16(pr.Opcode.C_StartDM))
		endian.put_u16(buf[2:4], .Big, u16(len(target)))
		copy(buf[4:], transmute([]byte)target)
		endian.put_u32(buf[4 + len(target):], .Big, correlation_id)
		return dm_kernel_enqueue_protocol_frame(ctx, conn, buf[:8 + len(target)], split, split_choice)
	}

	dm_kernel_enqueue_leave :: proc(ctx: ^Sim_Test_Context, conn: ^NRC_Connection, correlation_id: u32, split_choice: int = 0) -> bool {
		buf: [14]byte
		endian.put_u16(buf[0:2], .Big, u16(pr.Opcode.C_LeaveDM))
		endian.put_u64(buf[2:10], .Big, u64(dm_generated_conv_id()))
		endian.put_u32(buf[10:14], .Big, correlation_id)
		return dm_kernel_enqueue_protocol_frame(ctx, conn, buf[:], -1, split_choice)
	}

	dm_kernel_enqueue_subscribe :: proc(ctx: ^Sim_Test_Context, conn: ^NRC_Connection, split_choice: int = 0) -> bool {
		buf: [12]byte
		conv_ids := [?]pr.ConversationID{dm_generated_conv_id()}
		written := pr.serializeSubscribeConvsRequest(conv_ids[:], buf[:])
		if written <= 0 do return false
		return dm_kernel_enqueue_protocol_frame(ctx, conn, buf[:written], -1, split_choice)
	}

	dm_kernel_enqueue_send :: proc(ctx: ^Sim_Test_Context, conn: ^NRC_Connection, client_req_id: u32, content: string, split_choice: int = 0) -> bool {
		buf: [256]byte
		written := pr.serializeSendMessageRequest(dm_generated_conv_id(), client_req_id, .PlainText, transmute([]byte)content, buf[:])
		if written <= 0 do return false
		return dm_kernel_enqueue_protocol_frame(ctx, conn, buf[:written], -1, split_choice)
	}

	dm_kernel_run_operation_receives :: proc(sim: ^Sim_Runtime) -> bool {
		for nrc_sim_receive_event_count(sim) > 0 {
			if !nrc_sim_run_next_receive(sim) do return false
		}
		return true
	}

	dm_kernel_pending_semantics_validate_frames :: proc(ctx: ^Sim_Test_Context, with_reuse: bool = false) -> string {
		ack_counts: [2]int
		message_counts: [2]int
		started_counts: [DM_GENERATED_CLIENTS]int
		presence_count := 0
		partner_status_count := 0
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			sock := connection_test_fake_socket(client_id + 1)
			expected_frame_count := with_reuse && client_id == 0 ? 4 : (with_reuse && client_id == 1 ? 1 : 2)
			if nrc_sim_client_frame_count(&ctx.sim, sock) != expected_frame_count {
				return "pending semantic campaign complete frame count mismatch"
			}
			for frame_index in 0 ..< nrc_sim_client_frame_count(&ctx.sim, sock) {
				payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, sock, frame_index))
				if !ok do return "pending semantic campaign captured invalid frame"
				#partial switch pr.get_opcode(payload) {
				case .S_AckSendMessage:
					ack, err := pr.parseAckSendMessageMessage(payload)
					workspace_index := dm_generated_workspace_index(client_id)
					expected_req_id := workspace_index == 0 ? u32(102) : u32(202)
					expected_sender := workspace_index == 0 ? 0 : 1
					if err != nil || dm_generated_user_index(client_id) != expected_sender || ack.client_req_id != expected_req_id {
						return "pending semantic campaign acknowledgment crossed requester or workspace"
					}
					ack_counts[workspace_index] += 1
				case .S_NewMessage:
					message, err := pr.parseNewMessageEventMessage(payload)
					workspace_index := dm_generated_workspace_index(client_id)
					expected_content := workspace_index == 0 ? "workspace zero" : "workspace one"
					expected_recipient := workspace_index == 0 ? 1 : 0
					expected_author := workspace_index == 0 ? "alice" : "bob"
					if err != nil ||
					   dm_generated_user_index(client_id) != expected_recipient ||
					   message.conv_id != dm_generated_conv_id() ||
					   string(message.author_username) != expected_author ||
					   string(message.content) != expected_content {
						return "pending semantic campaign message crossed recipient or workspace"
					}
					message_counts[workspace_index] += 1
				case .S_DMStarted:
					if with_reuse && client_id == 1 do return "old DM-start response reached replacement generation"
					started, err := pr.parseDMStartedMessage(payload)
					workspace_index := dm_generated_workspace_index(client_id)
					initiator :=
						(workspace_index == 0 && dm_generated_user_index(client_id) == 0) || (workspace_index == 1 && dm_generated_user_index(client_id) == 1)
					expected_username := dm_generated_user_index(client_id) == 0 ? "bob" : "alice"
					expected_correlation := initiator ? (workspace_index == 0 ? u32(101) : u32(201)) : 0
					if err != nil ||
					   started.conv_id != dm_generated_conv_id() ||
					   started.username != expected_username ||
					   !started.authenticated ||
					   !started.online ||
					   started.is_initiator != initiator ||
					   started.correlation_id != expected_correlation {
						return "pending semantic campaign DM-start response crossed recipient or workspace"
					}
					started_counts[client_id] += 1
				case .S_ErrorResponse:
					response, err := pr.parseErrorResponseMessage(payload)
					if !with_reuse ||
					   client_id != 1 ||
					   err != nil ||
					   response.origin_opcode != .C_SendMessage ||
					   response.correlation_id != 103 ||
					   string(response.error_msg) != "DM access denied" {
						return "pending semantic replacement denial mismatch"
					}
				case .S_RoomPresenceUpdate:
					presence, err := pr.parseRoomPresenceUpdateMessage(payload)
					valid :=
						with_reuse &&
						client_id == 0 &&
						err == nil &&
						presence.conv_id == dm_generated_conv_id() &&
						presence.event_type == .UserLeft &&
						presence.sequence > 0 &&
						string(presence.username) == "bob" &&
						presence.is_authenticated &&
						presence.user_type == .User &&
						len(presence.old_username) == 0 &&
						len(presence.user_list) == 0 &&
						len(presence.user_auth_flags) == 0 &&
						len(presence.user_types) == 0
					if len(presence.user_list) > 0 {
						delete(presence.user_list)
						delete(presence.user_auth_flags)
						delete(presence.user_types)
					}
					if !valid do return "pending semantic disconnect presence mismatch"
					presence_count += 1
				case .S_DMPartnerStatus:
					status, err := pr.parseDMPartnerStatusMessage(payload)
					ws := td.workspaces[dm_generated_workspace(0)]
					if !with_reuse ||
					   client_id != 0 ||
					   err != nil ||
					   ws == nil ||
					   status.conv_id != dm_generated_conv_id() ||
					   status.username != "bob" ||
					   status.online ||
					   status.last_seen == 0 ||
					   status.last_seen != ws.user_last_seen["bob"] {
						return "pending semantic DM partner status mismatch"
					}
					partner_status_count += 1
				case:
					return "pending semantic campaign emitted unexpected opcode"
				}
			}
		}
		for workspace_index in 0 ..< DM_GENERATED_WORKSPACES {
			expected_messages := with_reuse && workspace_index == 0 ? 0 : 1
			if ack_counts[workspace_index] != 1 || message_counts[workspace_index] != expected_messages {
				return "pending semantic campaign final delivery count mismatch"
			}
		}
		for count, client_id in started_counts {
			expected := with_reuse && client_id == 1 ? 0 : 1
			if count != expected do return "pending semantic campaign DM-start response count mismatch"
		}
		if with_reuse && (presence_count != 1 || partner_status_count != 1) {
			return "pending semantic disconnect notification count mismatch"
		}
		return ""
	}

	dm_kernel_pending_semantics_run :: proc(choices: []u8, newest_fallback: bool = false, with_reuse: bool = false) -> string {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 188)
		old_counted := false
		defer if old_counted do connection_test_live_count -= 1
		defer simulation_test_end(&ctx)
		model: DM_Generated_Model
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			if !dm_generated_install(&ctx, &model, client_id) do return "pending semantic campaign client install failed"
		}
		nrc_sim_clear_inboxes(&ctx.sim)

		first := dm_generated_connection(&ctx, 0)
		second := dm_generated_connection(&ctx, 3)
		if !dm_kernel_enqueue_start(&ctx, first, "bob", 101, -1, 64) do return "first pending start did not enqueue"
		first_start_id := ctx.sim.world.next_event_id
		if !dm_kernel_enqueue_send(&ctx, first, 102, "workspace zero", 128) do return "first pending send did not enqueue"
		first_send_id := ctx.sim.world.next_event_id
		if !dm_kernel_enqueue_start(&ctx, second, "alice", 201, -1, 192) do return "second pending start did not enqueue"
		second_start_id := ctx.sim.world.next_event_id
		if !dm_kernel_enqueue_send(&ctx, second, 202, "workspace one", 255) do return "second pending send did not enqueue"
		second_send_id := ctx.sim.world.next_event_id
		old_handle: Connection_Handle
		old_sock := connection_test_fake_socket(2)
		replacement: ^NRC_Connection

		choice_index := 0
		for len(ctx.sim.world.events) > 0 {
			runnable_count := sim_world_prepare_runnable(&ctx.sim.world)
			if runnable_count <= 0 do return "pending semantic campaign event queue stalled"
			rank := 0
			if choice_index < len(choices) {
				rank = int(choices[choice_index]) * runnable_count / 256
				choice_index += 1
			} else if newest_fallback {
				rank = runnable_count - 1
			}
			index := sim_world_runnable_rank_index(&ctx.sim.world, rank)
			if index < 0 do return "pending semantic campaign runnable rank missing"
			event_id := ctx.sim.world.events[index].id
			if !sim_world_dispatch_event(&ctx.sim.world, index) do return "pending semantic campaign event dispatch failed"

			switch event_id {
			case first_start_id:
				model.member[0] = {true, true}
				model.subscribed[0] = true
				model.subscribed[1] = true
				if with_reuse {
					old := dm_generated_connection(&ctx, 1)
					old_handle = old.handle
					old_sock = old.sock
					connection_close(old, false)
					ctx.conns[2] = nil
					model.connected[1] = false
					model.subscribed[1] = false
					old_counted = true
				}
			case second_start_id:
				model.member[1] = {true, true}
				model.subscribed[2] = true
				model.subscribed[3] = true
			case first_send_id:
				if !model.member[0][0] do return "first send overtook same-stream start"
			case second_send_id:
				if !model.member[1][0] do return "second send overtook same-stream start"
			case:
			}
			if with_reuse && replacement == nil && old_handle != {} && connection_get(old_sock) == nil {
				replacement = dm_sim_install(&ctx, 2, dm_generated_workspace(1), "mallory")
				if replacement == nil || replacement.sock != old_sock || replacement.handle == old_handle {
					return "pending semantic replacement did not reuse socket generation"
				}
				_ = dm_sim_track_connected(replacement)
				if !dm_kernel_enqueue_send(&ctx, replacement, 103, "replacement denied", 32) {
					return "pending semantic replacement denial did not enqueue"
				}
			}
			if replacement != nil {
				ws := td.workspaces[dm_generated_workspace(0)]
				conv := get_conversation(ws, dm_generated_conv_id())
				_, replacement_in_room := replacement.rooms[dm_generated_conv_id()]
				if connection_get(old_sock) != replacement ||
				   connection_get_by_handle(replacement.handle) != replacement ||
				   replacement.workspace_id != dm_generated_workspace(1) ||
				   replacement.verified_username != "mallory" ||
				   replacement.state >= .Will_Close ||
				   replacement.logical_cleanup_done ||
				   replacement_in_room ||
				   (conv != nil && conversation_has_subscriber(conv, replacement.sock)) {
					return "pending semantic stale event mutated replacement generation"
				}
			}
			if old_counted && connection_get_by_handle(old_handle) == nil {
				connection_test_live_count -= 1
				old_counted = false
			}
			saved_replacement := ctx.conns[2]
			if replacement != nil do ctx.conns[2] = nil
			reason, state_ok := dm_generated_check_state(&ctx, &model)
			ctx.conns[2] = saved_replacement
			if !state_ok do return reason
		}
		if !model.member[0][0] || !model.member[1][0] do return "pending semantic campaign did not dispatch both starts"
		if with_reuse && (replacement == nil || connection_get_by_handle(old_handle) != nil) {
			return "pending semantic campaign did not finish replacement lifecycle"
		}
		if with_reuse && (replacement.state != .Idle || replacement.pending_io != 0 || replacement.is_sending) {
			return "pending semantic replacement did not finish idle"
		}
		return dm_kernel_pending_semantics_validate_frames(&ctx, with_reuse)
	}

	dm_pending_generated_apply_model :: proc(model: ^DM_Generated_Model, op: DM_Generated_Op) {
		workspace_index := dm_generated_workspace_index(op.client_id)
		user_index := dm_generated_user_index(op.client_id)
		#partial switch op.kind {
		case .Start:
			target_client := workspace_index * 2 + 1 - user_index
			if !model.connected[target_client] do return
			model.member[workspace_index] = {true, true}
			first_client := workspace_index * 2
			model.subscribed[first_client] = model.connected[first_client]
			model.subscribed[first_client + 1] = model.connected[first_client + 1]
		case .Leave:
			if model.member[workspace_index][user_index] {
				model.member[workspace_index][user_index] = false
				model.subscribed[op.client_id] = false
			}
		case .Subscribe:
			if model.member[workspace_index][user_index] do model.subscribed[op.client_id] = true
		case:
		}
	}

	dm_pending_generated_record_send :: proc(model: ^DM_Generated_Model, entry: ^DM_Pending_Generated_Op) {
		workspace_index := dm_generated_workspace_index(entry.op.client_id)
		user_index := dm_generated_user_index(entry.op.client_id)
		entry.send_authorized = model.member[workspace_index][user_index]
		if !entry.send_authorized do return
		for candidate in workspace_index * 2 ..< workspace_index * 2 + 2 {
			if candidate != entry.op.client_id && model.connected[candidate] && model.subscribed[candidate] {
				entry.expected_recipient_mask |= u8(1) << u8(candidate)
			}
		}
	}

	dm_pending_generated_record_lifecycle :: proc(model: ^DM_Generated_Model, entry: ^DM_Pending_Generated_Op) {
		client_id := entry.op.client_id
		workspace_index := dm_generated_workspace_index(client_id)
		user_index := dm_generated_user_index(client_id)
		partner_id := workspace_index * 2 + 1 - user_index
		client_bit := u8(1) << u8(client_id)
		partner_bit := u8(1) << u8(partner_id)
		#partial switch entry.op.kind {
		case .Start:
			if !model.connected[partner_id] {
				entry.expected_dm_error_mask = client_bit
				entry.dm_error_code = .User_Not_Found
				return
			}
			entry.expected_started_mask = client_bit
			if !model.member[workspace_index][1 - user_index] {
				entry.expected_started_mask |= partner_bit
			}
		case .Leave:
			if model.member[workspace_index][user_index] {
				entry.expected_left_mask = client_bit
			} else {
				entry.expected_dm_error_mask = client_bit
				entry.dm_error_code = .DM_Not_Found
			}
		case .Subscribe:
			if !model.member[workspace_index][user_index] do return
			entry.expected_user_list_mask = client_bit
			entry.expected_user_list = client_bit
			for candidate in workspace_index * 2 ..< workspace_index * 2 + 2 {
				if model.connected[candidate] && model.subscribed[candidate] {
					entry.expected_user_list |= u8(1) << u8(candidate)
				}
			}
			if !model.subscribed[client_id] {
				entry.expected_user_join_mask = entry.expected_user_list
			}
		case:
		}
	}

	dm_pending_generated_record_output :: proc(model: ^DM_Generated_Model, entry: ^DM_Pending_Generated_Op, output_group: int) {
		entry.output_group = output_group
		if entry.op.kind == .Send {
			dm_pending_generated_record_send(model, entry)
		} else {
			dm_pending_generated_record_lifecycle(model, entry)
		}
	}

	dm_pending_generated_presence_destroy :: proc(presence: ^pr.RoomPresenceUpdate) {
		if len(presence.user_list) > 0 do delete(presence.user_list)
		if len(presence.user_auth_flags) > 0 do delete(presence.user_auth_flags)
		if len(presence.user_types) > 0 do delete(presence.user_types)
	}

	dm_pending_generated_user_list_mask :: proc(presence: ^pr.RoomPresenceUpdate, workspace_index: int) -> (u8, bool) {
		if len(presence.user_list) != len(presence.user_auth_flags) || len(presence.user_list) != len(presence.user_types) {
			return 0, false
		}
		mask: u8
		for username, index in presence.user_list {
			client_id := workspace_index * 2
			if string(username) == "bob" {
				client_id += 1
			} else if string(username) != "alice" {
				return 0, false
			}
			bit := u8(1) << u8(client_id)
			if mask & bit != 0 || !presence.user_auth_flags[index] || presence.user_types[index] != .User {
				return 0, false
			}
			mask |= bit
		}
		return mask, true
	}

	dm_pending_generated_accumulate_client_frames :: proc(
		ctx: ^Sim_Test_Context,
		pending: []DM_Pending_Generated_Op,
		client_id: int,
		frame_cursor: ^int = nil,
		last_lifecycle_group: ^int = nil,
	) -> string {
		sock := connection_test_fake_socket(client_id + 1)
		first_frame := frame_cursor == nil ? 0 : frame_cursor^
		last_lifecycle_entry := last_lifecycle_group == nil ? -1 : last_lifecycle_group^
		frame_count := nrc_sim_client_frame_count(&ctx.sim, sock)
		for frame_index in first_frame ..< frame_count {
			payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, sock, frame_index))
			if !ok do return "pending generated send ledger captured invalid frame"
			#partial switch pr.get_opcode(payload) {
			case .S_DMStarted:
				started, err := pr.parseDMStartedMessage(payload)
				if err != nil do return "pending generated DM-start response malformed"
				recipient_bit := u8(1) << u8(client_id)
				matched := false
				for &entry, entry_index in pending {
					if entry.op.kind != .Start || entry.expected_started_mask & recipient_bit == 0 || entry.seen_started_mask & recipient_bit != 0 {
						continue
					}
					initiator := entry.op.client_id == client_id
					partner_id := dm_generated_workspace_index(entry.op.client_id) * 2 + 1 - dm_generated_user_index(entry.op.client_id)
					expected_username := initiator ? dm_generated_username(partner_id) : dm_generated_username(entry.op.client_id)
					expected_correlation := initiator ? u32(301 + entry_index) : u32(0)
					if started.conv_id == dm_generated_conv_id() &&
					   started.username == expected_username &&
					   started.authenticated &&
					   started.online &&
					   started.is_initiator == initiator &&
					   started.correlation_id == expected_correlation {
						if entry.output_group < last_lifecycle_entry do return "pending generated lifecycle output crossed recipient order"
						last_lifecycle_entry = entry.output_group
						entry.seen_started_mask |= recipient_bit
						matched = true
						break
					}
				}
				if !matched do return "pending generated DM-start response differs from ledger"
			case .S_DMLeft:
				left, err := pr.parseDMLeftMessage(payload)
				if err != nil || left.correlation_id < 301 do return "pending generated DM-left response malformed"
				entry_index := int(left.correlation_id - 301)
				recipient_bit := u8(1) << u8(client_id)
				if entry_index < 0 ||
				   entry_index >= len(pending) ||
				   pending[entry_index].op.kind != .Leave ||
				   pending[entry_index].expected_left_mask & recipient_bit == 0 ||
				   pending[entry_index].seen_left_mask & recipient_bit != 0 ||
				   left.conv_id != dm_generated_conv_id() {
					return "pending generated DM-left response differs from ledger"
				}
				if pending[entry_index].output_group < last_lifecycle_entry do return "pending generated lifecycle output crossed recipient order"
				last_lifecycle_entry = pending[entry_index].output_group
				pending[entry_index].seen_left_mask |= recipient_bit
			case .S_DMError:
				response, err := pr.parseDMErrorMessage(payload)
				if err != nil || response.correlation_id < 301 do return "pending generated DM error malformed"
				entry_index := int(response.correlation_id - 301)
				recipient_bit := u8(1) << u8(client_id)
				if entry_index < 0 || entry_index >= len(pending) {
					return "pending generated DM error correlation not in ledger"
				}
				entry := &pending[entry_index]
				expected_target :=
					entry.op.kind == .Start ? dm_generated_username(dm_generated_workspace_index(entry.op.client_id) * 2 + 1 - dm_generated_user_index(entry.op.client_id)) : ""
				expected_message := entry.dm_error_code == .User_Not_Found ? "User not found" : "Not in this DM"
				if entry.expected_dm_error_mask & recipient_bit == 0 ||
				   entry.seen_dm_error_mask & recipient_bit != 0 ||
				   entry.op.client_id != client_id ||
				   response.code != entry.dm_error_code ||
				   response.target_username != expected_target ||
				   response.message != expected_message {
					return "pending generated DM error differs from ledger"
				}
				if entry.output_group < last_lifecycle_entry do return "pending generated lifecycle output crossed recipient order"
				last_lifecycle_entry = entry.output_group
				entry.seen_dm_error_mask |= recipient_bit
			case .S_RoomPresenceUpdate:
				presence, err := pr.parseRoomPresenceUpdateMessage(payload)
				if err != nil {
					dm_pending_generated_presence_destroy(&presence)
					return "pending generated subscription presence malformed"
				}
				if presence.event_type == .UserListSync || presence.event_type == .UserJoined {
					recipient_bit := u8(1) << u8(client_id)
					matched := false
					for &entry, entry_index in pending {
						if entry.op.kind != .Subscribe do continue
						if presence.event_type == .UserListSync {
							list_mask, list_ok := dm_pending_generated_user_list_mask(&presence, dm_generated_workspace_index(entry.op.client_id))
							if entry.expected_user_list_mask & recipient_bit != 0 &&
							   entry.seen_user_list_mask & recipient_bit == 0 &&
							   presence.conv_id == dm_generated_conv_id() &&
							   presence.sequence > 0 &&
							   len(presence.username) == 0 &&
							   !presence.is_authenticated &&
							   presence.user_type == .User &&
							   len(presence.old_username) == 0 &&
							   list_ok &&
							   list_mask == entry.expected_user_list {
								if entry.output_group < last_lifecycle_entry do return "pending generated lifecycle output crossed recipient order"
								last_lifecycle_entry = entry.output_group
								entry.seen_user_list_mask |= recipient_bit
								matched = true
								break
							}
						} else if entry.expected_user_join_mask & recipient_bit != 0 &&
						   entry.seen_user_join_mask & recipient_bit == 0 &&
						   presence.conv_id == dm_generated_conv_id() &&
						   presence.sequence > 0 &&
						   string(presence.username) == dm_generated_username(entry.op.client_id) &&
						   presence.is_authenticated &&
						   presence.user_type == .User &&
						   len(presence.old_username) == 0 &&
						   len(presence.user_list) == 0 {
							if entry.output_group < last_lifecycle_entry do return "pending generated lifecycle output crossed recipient order"
							last_lifecycle_entry = entry.output_group
							entry.seen_user_join_mask |= recipient_bit
							matched = true
							break
						}
					}
					dm_pending_generated_presence_destroy(&presence)
					if !matched do return "pending generated subscription presence differs from ledger"
				} else if presence.event_type == .UserLeft {
					partner_id := dm_generated_workspace_index(client_id) * 2 + 1 - dm_generated_user_index(client_id)
					valid :=
						presence.conv_id == dm_generated_conv_id() &&
						presence.sequence > 0 &&
						string(presence.username) == dm_generated_username(partner_id) &&
						presence.is_authenticated &&
						presence.user_type == .User &&
						len(presence.old_username) == 0 &&
						len(presence.user_list) == 0 &&
						len(presence.user_auth_flags) == 0 &&
						len(presence.user_types) == 0
					dm_pending_generated_presence_destroy(&presence)
					if !valid do return "pending generated disconnect presence malformed"
				} else {
					dm_pending_generated_presence_destroy(&presence)
					return "pending generated history emitted unexpected presence event"
				}
			case .S_DMPartnerStatus:
				status, err := pr.parseDMPartnerStatusMessage(payload)
				partner_id := dm_generated_workspace_index(client_id) * 2 + 1 - dm_generated_user_index(client_id)
				if err != nil ||
				   status.conv_id != dm_generated_conv_id() ||
				   status.username != dm_generated_username(partner_id) ||
				   (!status.online && status.last_seen == 0) {
					return "pending generated DM partner status malformed"
				}
			case .S_AckSendMessage:
				ack, err := pr.parseAckSendMessageMessage(payload)
				if err != nil || ack.client_req_id < 301 do return "pending generated send acknowledgment malformed"
				entry_index := int(ack.client_req_id - 301)
				if entry_index < 0 ||
				   entry_index >= len(pending) ||
				   pending[entry_index].op.kind != .Send ||
				   pending[entry_index].canceled ||
				   !pending[entry_index].send_authorized ||
				   pending[entry_index].op.client_id != client_id {
					return "pending generated send acknowledgment differs from ledger"
				}
				pending[entry_index].ack_count += 1
				pending[entry_index].ack_seq = ack.assigned_seq
				pending[entry_index].ack_timestamp = ack.timestamp
			case .S_ErrorResponse:
				response, err := pr.parseErrorResponseMessage(payload)
				if err != nil || response.origin_opcode != .C_SendMessage || response.correlation_id < 301 {
					return "pending generated send denial malformed"
				}
				entry_index := int(response.correlation_id - 301)
				if entry_index < 0 ||
				   entry_index >= len(pending) ||
				   pending[entry_index].op.kind != .Send ||
				   pending[entry_index].canceled ||
				   pending[entry_index].send_authorized ||
				   pending[entry_index].op.client_id != client_id ||
				   string(response.error_msg) != "DM access denied" {
					return "pending generated send denial differs from ledger"
				}
				pending[entry_index].denial_count += 1
			case .S_NewMessage:
				message, err := pr.parseNewMessageEventMessage(payload)
				if err != nil do return "pending generated send message malformed"
				entry_index := -1
				for content, candidate in DM_PENDING_SEND_CONTENTS {
					if string(message.content) == content {
						entry_index = candidate
						break
					}
				}
				if entry_index < 0 || entry_index >= len(pending) || pending[entry_index].op.kind != .Send || pending[entry_index].canceled {
					return "pending generated send message content not in ledger"
				}
				entry := &pending[entry_index]
				recipient_bit := u8(1) << u8(client_id)
				if !entry.send_authorized ||
				   entry.expected_recipient_mask & recipient_bit == 0 ||
				   entry.seen_recipient_mask & recipient_bit != 0 ||
				   message.conv_id != dm_generated_conv_id() ||
				   string(message.author_username) != dm_generated_username(entry.op.client_id) {
					return "pending generated send message differs from ledger"
				}
				entry.seen_recipient_mask |= recipient_bit
				entry.message_seq = message.seq
				entry.message_timestamp = message.timestamp
				entry.message_content_type = message.content_type
			case:
				return "pending generated history emitted unexpected opcode"
			}
		}
		if frame_cursor != nil do frame_cursor^ = frame_count
		if last_lifecycle_group != nil do last_lifecycle_group^ = last_lifecycle_entry
		return ""
	}

	dm_pending_generated_cancel_queued_payload :: proc(pending: []DM_Pending_Generated_Op, client_id: int, payload: []byte) -> string {
		recipient_bit := u8(1) << u8(client_id)
		#partial switch pr.get_opcode(payload) {
		case .S_DMStarted:
			started, err := pr.parseDMStartedMessage(payload)
			if err != nil do return "queued DM-start response malformed"
			for &entry, entry_index in pending {
				if entry.op.kind != .Start ||
				   entry.expected_started_mask & recipient_bit == 0 ||
				   (entry.seen_started_mask | entry.canceled_started_mask) & recipient_bit != 0 {
					continue
				}
				initiator := entry.op.client_id == client_id
				partner_id := dm_generated_workspace_index(entry.op.client_id) * 2 + 1 - dm_generated_user_index(entry.op.client_id)
				expected_username := initiator ? dm_generated_username(partner_id) : dm_generated_username(entry.op.client_id)
				expected_correlation := initiator ? u32(301 + entry_index) : u32(0)
				if started.conv_id == dm_generated_conv_id() &&
				   started.username == expected_username &&
				   started.authenticated &&
				   started.online &&
				   started.is_initiator == initiator &&
				   started.correlation_id == expected_correlation {
					entry.canceled_started_mask |= recipient_bit
					return ""
				}
			}
			return "queued DM-start response not in ledger"
		case .S_DMLeft:
			left, err := pr.parseDMLeftMessage(payload)
			if err != nil || left.correlation_id < 301 do return "queued DM-left response malformed"
			entry_index := int(left.correlation_id - 301)
			if entry_index < 0 ||
			   entry_index >= len(pending) ||
			   pending[entry_index].op.kind != .Leave ||
			   pending[entry_index].expected_left_mask & recipient_bit == 0 ||
			   (pending[entry_index].seen_left_mask | pending[entry_index].canceled_left_mask) & recipient_bit != 0 ||
			   left.conv_id != dm_generated_conv_id() {
				return "queued DM-left response not in ledger"
			}
			pending[entry_index].canceled_left_mask |= recipient_bit
			return ""
		case .S_DMError:
			response, err := pr.parseDMErrorMessage(payload)
			if err != nil || response.correlation_id < 301 do return "queued DM error malformed"
			entry_index := int(response.correlation_id - 301)
			if entry_index < 0 || entry_index >= len(pending) do return "queued DM error correlation not in ledger"
			entry := &pending[entry_index]
			expected_target :=
				entry.op.kind == .Start ? dm_generated_username(dm_generated_workspace_index(entry.op.client_id) * 2 + 1 - dm_generated_user_index(entry.op.client_id)) : ""
			expected_message := entry.dm_error_code == .User_Not_Found ? "User not found" : "Not in this DM"
			if entry.expected_dm_error_mask & recipient_bit == 0 ||
			   (entry.seen_dm_error_mask | entry.canceled_dm_error_mask) & recipient_bit != 0 ||
			   entry.op.client_id != client_id ||
			   response.code != entry.dm_error_code ||
			   response.target_username != expected_target ||
			   response.message != expected_message {
				return "queued DM error not in ledger"
			}
			entry.canceled_dm_error_mask |= recipient_bit
			return ""
		case .S_RoomPresenceUpdate:
			presence, err := pr.parseRoomPresenceUpdateMessage(payload)
			if err != nil {
				dm_pending_generated_presence_destroy(&presence)
				return "queued presence response malformed"
			}
			if presence.event_type == .UserListSync || presence.event_type == .UserJoined {
				for &entry in pending {
					if entry.op.kind != .Subscribe do continue
					if presence.event_type == .UserListSync {
						list_mask, list_ok := dm_pending_generated_user_list_mask(&presence, dm_generated_workspace_index(entry.op.client_id))
						if entry.expected_user_list_mask & recipient_bit != 0 &&
						   (entry.seen_user_list_mask | entry.canceled_user_list_mask) & recipient_bit == 0 &&
						   presence.conv_id == dm_generated_conv_id() &&
						   presence.sequence > 0 &&
						   len(presence.username) == 0 &&
						   !presence.is_authenticated &&
						   presence.user_type == .User &&
						   len(presence.old_username) == 0 &&
						   list_ok &&
						   list_mask == entry.expected_user_list {
							entry.canceled_user_list_mask |= recipient_bit
							dm_pending_generated_presence_destroy(&presence)
							return ""
						}
					} else if entry.expected_user_join_mask & recipient_bit != 0 &&
					   (entry.seen_user_join_mask | entry.canceled_user_join_mask) & recipient_bit == 0 &&
					   presence.conv_id == dm_generated_conv_id() &&
					   presence.sequence > 0 &&
					   string(presence.username) == dm_generated_username(entry.op.client_id) &&
					   presence.is_authenticated &&
					   presence.user_type == .User &&
					   len(presence.old_username) == 0 &&
					   len(presence.user_list) == 0 {
						entry.canceled_user_join_mask |= recipient_bit
						dm_pending_generated_presence_destroy(&presence)
						return ""
					}
				}
				dm_pending_generated_presence_destroy(&presence)
				return "queued subscription presence not in ledger"
			}
			if presence.event_type == .UserLeft {
				partner_id := dm_generated_workspace_index(client_id) * 2 + 1 - dm_generated_user_index(client_id)
				valid :=
					presence.conv_id == dm_generated_conv_id() &&
					presence.sequence > 0 &&
					string(presence.username) == dm_generated_username(partner_id) &&
					presence.is_authenticated &&
					presence.user_type == .User &&
					len(presence.old_username) == 0 &&
					len(presence.user_list) == 0 &&
					len(presence.user_auth_flags) == 0 &&
					len(presence.user_types) == 0
				dm_pending_generated_presence_destroy(&presence)
				if !valid do return "queued disconnect presence malformed"
				return ""
			}
			dm_pending_generated_presence_destroy(&presence)
			return "queued lifecycle history emitted unexpected presence event"
		case .S_AckSendMessage:
			ack, err := pr.parseAckSendMessageMessage(payload)
			if err != nil || ack.client_req_id < 301 do return "queued send acknowledgment malformed"
			entry_index := int(ack.client_req_id - 301)
			if entry_index < 0 ||
			   entry_index >= len(pending) ||
			   pending[entry_index].op.kind != .Send ||
			   pending[entry_index].canceled ||
			   !pending[entry_index].send_authorized ||
			   pending[entry_index].op.client_id != client_id ||
			   pending[entry_index].response_canceled ||
			   pending[entry_index].ack_count != 0 {
				return "queued send acknowledgment not in ledger"
			}
			pending[entry_index].response_canceled = true
			return ""
		case .S_ErrorResponse:
			response, err := pr.parseErrorResponseMessage(payload)
			if err != nil || response.origin_opcode != .C_SendMessage || response.correlation_id < 301 {
				return "queued send denial malformed"
			}
			entry_index := int(response.correlation_id - 301)
			if entry_index < 0 ||
			   entry_index >= len(pending) ||
			   pending[entry_index].op.kind != .Send ||
			   pending[entry_index].canceled ||
			   pending[entry_index].send_authorized ||
			   pending[entry_index].op.client_id != client_id ||
			   pending[entry_index].response_canceled ||
			   pending[entry_index].denial_count != 0 ||
			   string(response.error_msg) != "DM access denied" {
				return "queued send denial not in ledger"
			}
			pending[entry_index].response_canceled = true
			return ""
		case .S_NewMessage:
			message, err := pr.parseNewMessageEventMessage(payload)
			if err != nil do return "queued send message malformed"
			entry_index := -1
			for content, candidate in DM_PENDING_SEND_CONTENTS {
				if string(message.content) == content {
					entry_index = candidate
					break
				}
			}
			if entry_index < 0 || entry_index >= len(pending) do return "queued send message not in ledger"
			entry := &pending[entry_index]
			if entry.op.kind != .Send ||
			   entry.canceled ||
			   !entry.send_authorized ||
			   entry.expected_recipient_mask & recipient_bit == 0 ||
			   (entry.seen_recipient_mask | entry.canceled_recipient_mask) & recipient_bit != 0 ||
			   message.conv_id != dm_generated_conv_id() ||
			   string(message.author_username) != dm_generated_username(entry.op.client_id) ||
			   message.content_type != .PlainText {
				return "queued send message differs from ledger"
			}
			entry.canceled_recipient_mask |= recipient_bit
			return ""
		case .S_DMPartnerStatus:
			status, err := pr.parseDMPartnerStatusMessage(payload)
			partner_id := dm_generated_workspace_index(client_id) * 2 + 1 - dm_generated_user_index(client_id)
			if err != nil || status.conv_id != dm_generated_conv_id() || status.username != dm_generated_username(partner_id) {
				return "queued DM partner status malformed"
			}
			return ""
		case:
			return "queued lifecycle history emitted unexpected opcode"
		}
		return ""
	}

	dm_pending_lifecycle_cancel_queued_item :: proc(item: ^Send_Item, pending: []DM_Pending_Generated_Op, client_id: int) -> string {
		if item == nil do return "queued lifecycle history contained nil send item"
		frame := frame_lease_data(item.lease)
		payload, ok := nrc_sim_frame_protocol_payload(frame)
		if !ok do return "queued lifecycle history contained invalid WebSocket frame"
		return dm_pending_generated_cancel_queued_payload(pending, client_id, payload)
	}

	dm_pending_lifecycle_cancel_queued_outputs :: proc(conn: ^NRC_Connection, pending: []DM_Pending_Generated_Op, client_id: int) -> string {
		for index in 0 ..< queue.len(conn.priority_queue) {
			if reason := dm_pending_lifecycle_cancel_queued_item(queue.get_ptr(&conn.priority_queue, index), pending, client_id); reason != "" do return reason
		}
		for index in 0 ..< int(conn.inline_len) {
			queue_index := (int(conn.inline_head) + index) % Inline_Queue_Size
			if reason := dm_pending_lifecycle_cancel_queued_item(&conn.inline_queue[queue_index], pending, client_id); reason != "" do return reason
		}
		for index in 0 ..< queue.len(conn.spill_queue) {
			if reason := dm_pending_lifecycle_cancel_queued_item(queue.get_ptr(&conn.spill_queue, index), pending, client_id); reason != "" do return reason
		}
		return ""
	}

	dm_pending_generated_reconcile_sends :: proc(pending: []DM_Pending_Generated_Op) -> string {
		for entry in pending {
			if entry.op.kind != .Send do continue
			if entry.canceled {
				if entry.ack_count != 0 || entry.denial_count != 0 || entry.seen_recipient_mask != 0 {
					return "canceled pending send emitted output"
				}
				continue
			}
			expected_acks := entry.send_authorized && !entry.response_canceled ? 1 : 0
			expected_denials := !entry.send_authorized && !entry.response_canceled ? 1 : 0
			if entry.ack_count != expected_acks ||
			   entry.denial_count != expected_denials ||
			   entry.seen_recipient_mask & entry.canceled_recipient_mask != 0 ||
			   entry.seen_recipient_mask | entry.canceled_recipient_mask != entry.expected_recipient_mask {
				fmt.eprintf(
					"send ledger mismatch: op=%v authorized=%v ack=%d/%d denial=%d/%d recipients=%02x/%02x canceled=%v\n",
					entry.op,
					entry.send_authorized,
					entry.ack_count,
					expected_acks,
					entry.denial_count,
					expected_denials,
					entry.seen_recipient_mask | entry.canceled_recipient_mask,
					entry.expected_recipient_mask,
					entry.canceled,
				)
				return "pending generated send ledger did not reconcile"
			}
			// Canceled queued deliveries are validated by the cancellation ledger;
			// they never populate the received-message metadata below.
			if entry.seen_recipient_mask != 0 && entry.message_content_type != .PlainText {
				return "pending generated send message content type differs"
			}
			if entry.seen_recipient_mask != 0 &&
			   entry.ack_count != 0 &&
			   (entry.message_seq != entry.ack_seq || entry.message_timestamp != entry.ack_timestamp) {
				return "pending generated send acknowledgment and message metadata differ"
			}
		}
		return ""
	}

	dm_pending_generated_reconcile_lifecycle :: proc(pending: []DM_Pending_Generated_Op) -> string {
		for entry in pending {
			if entry.op.kind == .Send do continue
			if entry.canceled {
				if entry.seen_started_mask != 0 ||
				   entry.seen_left_mask != 0 ||
				   entry.seen_dm_error_mask != 0 ||
				   entry.seen_user_list_mask != 0 ||
				   entry.seen_user_join_mask != 0 {
					return "canceled pending lifecycle operation emitted output"
				}
				continue
			}
			if entry.seen_started_mask & entry.canceled_started_mask != 0 ||
			   entry.seen_left_mask & entry.canceled_left_mask != 0 ||
			   entry.seen_dm_error_mask & entry.canceled_dm_error_mask != 0 ||
			   entry.seen_user_list_mask & entry.canceled_user_list_mask != 0 ||
			   entry.seen_user_join_mask & entry.canceled_user_join_mask != 0 ||
			   entry.seen_started_mask | entry.canceled_started_mask != entry.expected_started_mask ||
			   entry.seen_left_mask | entry.canceled_left_mask != entry.expected_left_mask ||
			   entry.seen_dm_error_mask | entry.canceled_dm_error_mask != entry.expected_dm_error_mask ||
			   entry.seen_user_list_mask | entry.canceled_user_list_mask != entry.expected_user_list_mask ||
			   entry.seen_user_join_mask | entry.canceled_user_join_mask != entry.expected_user_join_mask {
				fmt.eprintf(
					"lifecycle ledger mismatch: op=%v started=%02x/%02x left=%02x/%02x error=%02x/%02x list=%02x/%02x join=%02x/%02x canceled=%v\n",
					entry.op,
					entry.seen_started_mask | entry.canceled_started_mask,
					entry.expected_started_mask,
					entry.seen_left_mask | entry.canceled_left_mask,
					entry.expected_left_mask,
					entry.seen_dm_error_mask | entry.canceled_dm_error_mask,
					entry.expected_dm_error_mask,
					entry.seen_user_list_mask | entry.canceled_user_list_mask,
					entry.expected_user_list_mask,
					entry.seen_user_join_mask | entry.canceled_user_join_mask,
					entry.expected_user_join_mask,
					entry.canceled,
				)
				return "pending generated lifecycle ledger did not reconcile"
			}
		}
		return ""
	}

	dm_pending_generated_reconcile_outputs :: proc(pending: []DM_Pending_Generated_Op) -> string {
		if reason := dm_pending_generated_reconcile_sends(pending); reason != "" do return reason
		return dm_pending_generated_reconcile_lifecycle(pending)
	}

	dm_pending_generated_validate_sends :: proc(ctx: ^Sim_Test_Context, pending: []DM_Pending_Generated_Op) -> string {
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			if reason := dm_pending_generated_accumulate_client_frames(ctx, pending, client_id); reason != "" do return reason
		}
		return dm_pending_generated_reconcile_outputs(pending)
	}

	dm_pending_generated_response_count :: proc(pending: []DM_Pending_Generated_Op) -> int {
		count := 0
		for entry in pending {
			count += entry.ack_count + entry.denial_count
			if entry.seen_started_mask != 0 do count += 1
			if entry.seen_left_mask != 0 do count += 1
			if entry.seen_dm_error_mask != 0 do count += 1
			if entry.seen_user_list_mask != 0 do count += 1
			if entry.seen_user_join_mask != 0 do count += 1
		}
		return count
	}

	dm_pending_generated_queued_cancellation_count :: proc(pending: []DM_Pending_Generated_Op) -> int {
		count := 0
		for entry in pending {
			if entry.response_canceled do count += 1
			if entry.canceled_recipient_mask != 0 do count += 1
			if entry.canceled_started_mask != 0 do count += 1
			if entry.canceled_left_mask != 0 do count += 1
			if entry.canceled_dm_error_mask != 0 do count += 1
			if entry.canceled_user_list_mask != 0 do count += 1
			if entry.canceled_user_join_mask != 0 do count += 1
		}
		return count
	}

	dm_pending_generated_history_run :: proc(ops: []DM_Generated_Op, choices: []u8, newest_fallback: bool = false) -> string {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 189)
		defer simulation_test_end(&ctx)
		model: DM_Generated_Model
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			if !dm_generated_install(&ctx, &model, client_id) do return "pending generated history client install failed"
		}
		nrc_sim_clear_inboxes(&ctx.sim)

		pending := make([]DM_Pending_Generated_Op, len(ops))
		defer delete(pending)
		for op, op_index in ops {
			if op.client_id < 0 || op.client_id >= DM_GENERATED_CLIENTS {
				return "pending generated history client out of range"
			}
			conn := dm_generated_connection(&ctx, op.client_id)
			correlation_id := u32(301 + op_index)
			enqueued := false
			#partial switch op.kind {
			case .Start:
				target_client := dm_generated_workspace_index(op.client_id) * 2 + 1 - dm_generated_user_index(op.client_id)
				enqueued = dm_kernel_enqueue_start(&ctx, conn, dm_generated_username(target_client), correlation_id, -1, int(op.split_choice))
			case .Leave:
				enqueued = dm_kernel_enqueue_leave(&ctx, conn, correlation_id, int(op.split_choice))
			case .Subscribe:
				enqueued = dm_kernel_enqueue_subscribe(&ctx, conn, int(op.split_choice))
			case .Send:
				enqueued = dm_kernel_enqueue_send(&ctx, conn, correlation_id, dm_pending_send_content(op_index), int(op.split_choice))
			}
			if !enqueued do return "pending generated history operation did not enqueue"
			pending[op_index] = {
				op            = op,
				completion_id = ctx.sim.world.next_event_id,
			}
		}

		choice_index := 0
		applied_count := 0
		for len(ctx.sim.world.events) > 0 {
			runnable_count := sim_world_prepare_runnable(&ctx.sim.world)
			if runnable_count <= 0 do return "pending generated history event queue stalled"
			rank := 0
			if choice_index < len(choices) {
				rank = int(choices[choice_index]) * runnable_count / 256
				choice_index += 1
			} else if newest_fallback {
				rank = runnable_count - 1
			}
			index := sim_world_runnable_rank_index(&ctx.sim.world, rank)
			if index < 0 do return "pending generated history runnable rank missing"
			event_id := ctx.sim.world.events[index].id
			if !sim_world_dispatch_event(&ctx.sim.world, index) do return "pending generated history event dispatch failed"

			for &entry in pending {
				if entry.applied || entry.completion_id != event_id do continue
				conn := dm_generated_connection(&ctx, entry.op.client_id)
				if conn.receive_accumulator.buf != nil ||
				   conn.receive_accumulator.used != 0 ||
				   conn.receive_accumulator.target != 0 ||
				   conn.fragment_buf != nil ||
				   conn.fragment_len != 0 {
					return "pending generated history completed request with parser state retained"
				}
				dm_pending_generated_record_output(&model, &entry, applied_count)
				dm_pending_generated_apply_model(&model, entry.op)
				entry.applied = true
				applied_count += 1
				break
			}
			if reason, ok := dm_generated_check_state(&ctx, &model); !ok do return reason
		}
		if applied_count != len(pending) do return "pending generated history did not apply every operation"
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			conn := dm_generated_connection(&ctx, client_id)
			if conn == nil ||
			   conn.state != .Idle ||
			   conn.pending_io != 0 ||
			   conn.is_sending ||
			   send_queue_len(conn) != 0 ||
			   conn.receive_accumulator.buf != nil ||
			   conn.receive_accumulator.used != 0 ||
			   conn.receive_accumulator.target != 0 ||
			   conn.fragment_buf != nil ||
			   conn.fragment_len != 0 {
				return "pending generated history did not finish transport-quiescent"
			}
		}
		return dm_pending_generated_validate_sends(&ctx, pending)
	}

	dm_pending_lifecycle_dispatch :: proc(
		ctx: ^Sim_Test_Context,
		model: ^DM_Generated_Model,
		pending: []DM_Pending_Generated_Op,
		old_connections: []DM_Pending_Lifecycle_Connection,
		output_group: ^int,
		choice: u8,
	) -> string {
		runnable_count := sim_world_prepare_runnable(&ctx.sim.world)
		if runnable_count <= 0 do return "pending lifecycle history event queue stalled"
		rank := int(choice) * runnable_count / 256
		index := sim_world_runnable_rank_index(&ctx.sim.world, rank)
		if index < 0 do return "pending lifecycle history runnable rank missing"
		event_id := ctx.sim.world.events[index].id
		if !sim_world_dispatch_event(&ctx.sim.world, index) do return "pending lifecycle history event dispatch failed"
		for &entry in pending {
			if entry.applied || entry.completion_id != event_id do continue
			entry.applied = true
			if entry.canceled do break
			conn := dm_generated_connection(ctx, entry.op.client_id)
			if conn == nil ||
			   conn.receive_accumulator.buf != nil ||
			   conn.receive_accumulator.used != 0 ||
			   conn.receive_accumulator.target != 0 ||
			   conn.fragment_buf != nil ||
			   conn.fragment_len != 0 {
				return "pending lifecycle history completed request with parser state retained"
			}
			dm_pending_generated_record_output(model, &entry, output_group^)
			output_group^ += 1
			dm_pending_generated_apply_model(model, entry.op)
			break
		}
		if reason := dm_pending_lifecycle_check_old_connections(old_connections); reason != "" do return reason
		if reason, ok := dm_generated_check_state(ctx, model); !ok do return reason
		return ""
	}

	dm_pending_lifecycle_check_old_connections :: proc(old_connections: []DM_Pending_Lifecycle_Connection) -> string {
		for &record in old_connections {
			old := connection_get_by_handle(record.handle)
			if old == nil {
				if record.counted {
					connection_test_live_count -= 1
					record.counted = false
				}
				continue
			}
			if !old.logical_cleanup_done || old.state < .Closing || len(old.rooms) != 0 {
				return "pending lifecycle old generation retained logical state"
			}
			if old.sock != connection_test_fake_socket(record.client_id + 1) ||
			   old.workspace_id != dm_generated_workspace(record.client_id) ||
			   old.verified_username != dm_generated_username(record.client_id) ||
			   !old.authenticated {
				return "pending lifecycle old generation identity changed"
			}
		}
		return ""
	}

	dm_pending_generated_lifecycle_run :: proc(
		ops: []DM_Generated_Op,
		choices: []u8,
		require_old_generation_response: bool = false,
		require_queued_cancellation: bool = false,
	) -> string {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 190)
		defer simulation_test_end(&ctx)
		model: DM_Generated_Model
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			if !dm_generated_install(&ctx, &model, client_id) do return "pending lifecycle history client install failed"
		}
		nrc_sim_clear_inboxes(&ctx.sim)
		pending := make([]DM_Pending_Generated_Op, len(ops))
		defer delete(pending)
		old_connections := make([dynamic]DM_Pending_Lifecycle_Connection, 0, len(ops))
		defer {
			for record in old_connections do if record.counted do connection_test_live_count -= 1
			delete(old_connections)
		}
		choice_index := 0
		old_generation_response_count := 0
		output_group := 0
		frame_cursors: [DM_GENERATED_CLIENTS]int
		last_lifecycle_groups: [DM_GENERATED_CLIENTS]int
		for &group in last_lifecycle_groups do group = -1

		for op, op_index in ops {
			if op.client_id < 0 || op.client_id >= DM_GENERATED_CLIENTS do return "pending lifecycle history client out of range"
			conn := dm_generated_connection(&ctx, op.client_id)
			for op.kind == .Reconnect && conn == nil && connection_get(connection_test_fake_socket(op.client_id + 1)) != nil {
				if len(ctx.sim.world.events) == 0 do return "pending lifecycle reconnect blocked without events"
				choice := choice_index < len(choices) ? choices[choice_index] : 0
				choice_index += 1
				if reason := dm_pending_lifecycle_dispatch(&ctx, &model, pending, old_connections[:], &output_group, choice); reason != "" do return reason
				conn = dm_generated_connection(&ctx, op.client_id)
			}

			pending[op_index].op = op
			switch op.kind {
			case .Start, .Leave, .Subscribe, .Send:
				if conn != nil {
					correlation_id := u32(301 + op_index)
					enqueued := false
					#partial switch op.kind {
					case .Start:
						target_client := dm_generated_workspace_index(op.client_id) * 2 + 1 - dm_generated_user_index(op.client_id)
						enqueued = dm_kernel_enqueue_start(&ctx, conn, dm_generated_username(target_client), correlation_id, -1, int(op.split_choice))
					case .Leave:
						enqueued = dm_kernel_enqueue_leave(&ctx, conn, correlation_id, int(op.split_choice))
					case .Subscribe:
						enqueued = dm_kernel_enqueue_subscribe(&ctx, conn, int(op.split_choice))
					case .Send:
						enqueued = dm_kernel_enqueue_send(&ctx, conn, correlation_id, dm_pending_send_content(op_index), int(op.split_choice))
					}
					if !enqueued do return "pending lifecycle semantic operation did not enqueue"
					pending[op_index].completion_id = ctx.sim.world.next_event_id
				} else {
					pending[op_index].applied = true
					pending[op_index].canceled = true
				}
			case .Disconnect:
				pending[op_index].applied = true
				if conn != nil {
					for &entry in pending[:op_index] do if !entry.applied && entry.op.client_id == op.client_id do entry.canceled = true
					responses_before := dm_pending_generated_response_count(pending)
					if reason := dm_pending_generated_accumulate_client_frames(&ctx, pending, op.client_id, &frame_cursors[op.client_id], &last_lifecycle_groups[op.client_id]); reason != "" do return reason
					old_generation_response_count += dm_pending_generated_response_count(pending) - responses_before
					if reason := dm_pending_lifecycle_cancel_queued_outputs(conn, pending, op.client_id); reason != "" do return reason
					append(&old_connections, DM_Pending_Lifecycle_Connection{client_id = op.client_id, handle = conn.handle, counted = true})
					connection_close(conn, false)
					if !conn.logical_cleanup_done || conn.state != .Closing || len(conn.rooms) != 0 {
						return "pending lifecycle disconnect did not complete logical cleanup"
					}
					ctx.conns[op.client_id + 1] = nil
					model.connected[op.client_id] = false
					model.subscribed[op.client_id] = false
				}
			case .Reconnect:
				pending[op_index].applied = true
				if conn == nil {
					responses_before := dm_pending_generated_response_count(pending)
					if reason := dm_pending_generated_accumulate_client_frames(&ctx, pending, op.client_id, &frame_cursors[op.client_id], &last_lifecycle_groups[op.client_id]); reason != "" do return reason
					old_generation_response_count += dm_pending_generated_response_count(pending) - responses_before
					if !dm_generated_install(&ctx, &model, op.client_id) do return "pending lifecycle reconnect failed"
					frame_cursors[op.client_id] = 0
					last_lifecycle_groups[op.client_id] = -1
					replacement := dm_generated_connection(&ctx, op.client_id)
					prior_handle: Connection_Handle
					for record in old_connections do if record.client_id == op.client_id do prior_handle = record.handle
					if replacement == nil ||
					   replacement.sock != connection_test_fake_socket(op.client_id + 1) ||
					   replacement.handle == {} ||
					   replacement.handle == prior_handle ||
					   connection_get(replacement.sock) != replacement ||
					   connection_get_by_handle(replacement.handle) != replacement ||
					   replacement.workspace_id != dm_generated_workspace(op.client_id) ||
					   replacement.verified_username != dm_generated_username(op.client_id) ||
					   !replacement.authenticated ||
					   replacement.logical_cleanup_done ||
					   len(replacement.rooms) != 0 {
						return "pending lifecycle reconnect did not install a clean identity generation"
					}
				}
			}

			if reason := dm_pending_lifecycle_check_old_connections(old_connections[:]); reason != "" do return reason
			if reason, ok := dm_generated_check_state(&ctx, &model); !ok do return reason
			if len(ctx.sim.world.events) > 0 {
				choice := choice_index < len(choices) ? choices[choice_index] : 0
				choice_index += 1
				if choice & 1 != 0 {
					if reason := dm_pending_lifecycle_dispatch(&ctx, &model, pending, old_connections[:], &output_group, choice); reason != "" do return reason
				}
			}
		}

		for len(ctx.sim.world.events) > 0 {
			choice := choice_index < len(choices) ? choices[choice_index] : 0
			choice_index += 1
			if reason := dm_pending_lifecycle_dispatch(&ctx, &model, pending, old_connections[:], &output_group, choice); reason != "" do return reason
		}
		if reason := dm_pending_lifecycle_check_old_connections(old_connections[:]); reason != "" do return reason
		for record in old_connections do if connection_get_by_handle(record.handle) != nil do return "pending lifecycle history retained old generation"
		for entry in pending do if !entry.applied do return "pending lifecycle history did not account for operation"
		for client_id in 0 ..< DM_GENERATED_CLIENTS {
			if reason := dm_pending_generated_accumulate_client_frames(&ctx, pending, client_id, &frame_cursors[client_id], &last_lifecycle_groups[client_id]); reason != "" do return reason
		}
		if require_old_generation_response && old_generation_response_count == 0 do return "pending lifecycle fixture did not harvest old-generation send output"
		if require_queued_cancellation && dm_pending_generated_queued_cancellation_count(pending) == 0 {
			return "pending lifecycle fixture did not cancel an exact queued output"
		}
		return dm_pending_generated_reconcile_outputs(pending)
	}

	dm_kernel_close_reuse_run :: proc(choices: []u8) -> string {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 187)
		old_counted := false
		defer if old_counted do connection_test_live_count -= 1
		defer simulation_test_end(&ctx)

		alice := dm_sim_install(&ctx, 1, "dm_kernel", "alice", true)
		bob := dm_sim_install(&ctx, 2, "dm_kernel", "bob", true)
		if alice == nil || bob == nil do return "kernel DM clients did not install"
		_ = dm_sim_track_connected(alice)
		ws := dm_sim_track_connected(bob)
		conv_id := dm_generated_conv_id()

		if !dm_kernel_enqueue_start(&ctx, alice, "bob", 1, 7) || nrc_sim_receive_event_count(&ctx.sim) != 2 {
			return "split kernel DM start did not enqueue"
		}
		if !sim_world_run_runnable_rank(&ctx.sim.world, 0, Sim_Event_Domain.Receive) ||
		   !sim_world_run_runnable_rank(&ctx.sim.world, 0, Sim_Event_Domain.Receive) {
			return "split kernel DM start did not dispatch"
		}
		nrc_sim_run_all_send_completions(&ctx.sim)
		conv := get_conversation(ws, conv_id)
		if conv == nil || !is_user_in_dm(ws, "alice", conv_id) || !is_user_in_dm(ws, "bob", conv_id) || subscriber_count(conv) != 2 {
			return "kernel parser path did not establish exact DM state"
		}
		nrc_sim_clear_inboxes(&ctx.sim)

		if !dm_kernel_enqueue_send(&ctx, alice, 2, "before reuse") || !nrc_sim_run_next_receive(&ctx.sim) {
			return "kernel DM send did not dispatch"
		}
		if !dm_kernel_enqueue_send(&ctx, bob, 3, "stale receive") do return "old Bob receive did not enqueue"
		old_handle := bob.handle
		old_sock := bob.sock
		connection_close(bob, false)
		if nrc_sim_close_completion_count(&ctx.sim) != 0 || bob.close_submitted {
			return "Bob close bypassed pending receive barrier"
		}
		ctx.conns[2] = nil
		old_counted = true
		choice_index := 0
		for nrc_sim_close_completion_count(&ctx.sim) == 0 {
			runnable_count := sim_world_prepare_runnable(&ctx.sim.world)
			if runnable_count <= 0 do return "Bob pending I/O did not make close runnable"
			rank := 0
			if choice_index < len(choices) {
				rank = int(choices[choice_index]) * runnable_count / 256
				choice_index += 1
			}
			if !sim_world_run_runnable_rank(&ctx.sim.world, rank) do return "chosen pre-close DM event did not dispatch"
			if connection_get_by_handle(old_handle) != bob || connection_get(old_sock) != nil {
				return "Bob generation changed before close submission"
			}
		}
		if !bob.close_submitted || bob.pending_io != 1 {
			return "Bob close did not reserve exactly its submitted completion"
		}
		if !nrc_sim_run_next_close_completion(&ctx.sim) || connection_get(old_sock) != nil {
			return "Bob close did not release the socket mapping"
		}

		replacement := dm_sim_install(&ctx, 2, "dm_kernel", "mallory", true)
		ctx.conns[2] = replacement
		if replacement == nil || replacement.sock != old_sock || replacement.handle == old_handle {
			return "replacement did not reuse the socket with a new generation"
		}
		_ = dm_sim_track_connected(replacement)

		for len(ctx.sim.world.events) > 0 {
			runnable_count := sim_world_prepare_runnable(&ctx.sim.world)
			if runnable_count <= 0 do return "kernel DM event queue stalled"
			rank := 0
			if choice_index < len(choices) {
				rank = int(choices[choice_index]) * runnable_count / 256
				choice_index += 1
			}
			if !sim_world_run_runnable_rank(&ctx.sim.world, rank) do return "chosen kernel DM event did not dispatch"
			if connection_get(old_sock) != replacement ||
			   replacement.state != .Idle ||
			   replacement.pending_io != 0 ||
			   replacement.is_sending ||
			   nrc_sim_client_frame_count(&ctx.sim, replacement.sock) != 0 {
				return "stale kernel DM event targeted replacement generation"
			}
		}
		if connection_get_by_handle(old_handle) != nil do return "kernel DM events retained old generation"
		connection_test_live_count -= 1
		old_counted = false
		if !is_user_in_dm(ws, "alice", conv_id) ||
		   !is_user_in_dm(ws, "bob", conv_id) ||
		   conversation_has_subscriber(conv, old_sock) ||
		   subscriber_count(conv) != 1 {
			return "kernel close/reuse changed DM membership or subscription semantics"
		}
		ack_payload, ack_ok := dm_sim_find_payload(&ctx, alice, .S_AckSendMessage)
		if !ack_ok do return "kernel semantic send acknowledgment missing"
		ack, ack_err := pr.parseAckSendMessageMessage(ack_payload)
		if ack_err != nil || ack.client_req_id != 2 do return "kernel semantic send acknowledgment mismatch"

		nrc_sim_clear_inboxes(&ctx.sim)
		if !dm_kernel_enqueue_send(&ctx, replacement, 4, "replacement denied") || !nrc_sim_run_next_receive(&ctx.sim) {
			return "replacement parser request did not dispatch"
		}
		nrc_sim_run_all_send_completions(&ctx.sim)
		if nrc_sim_client_frame_count(&ctx.sim, replacement.sock) != 1 do return "replacement denial recipient count mismatch"
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, replacement.sock, 0))
		if !payload_ok do return "replacement denial frame did not decode"
		response, err := pr.parseErrorResponseMessage(payload)
		if err != nil || response.origin_opcode != .C_SendMessage || response.correlation_id != 4 || string(response.error_msg) != "DM access denied" {
			return "replacement inherited old DM authorization"
		}
		return ""
	}

	prop_generated_dm_kernel_event_orderings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		choices: [16]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw kernel DM runnable rank")
			choice = u8(drawn)
		}
		if reason := dm_kernel_close_reuse_run(choices[:]); reason != "" {
			if tc.is_final do fmt.eprintf("Generated DM kernel replay: choices=%v reason=%s\n", choices, reason)
			return hgl.interesting(reason)
		}
		return hgl.valid()
	}

	prop_generated_dm_pending_semantic_orderings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		choices: [48]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw pending semantic runnable rank")
			choice = u8(drawn)
		}
		if reason := dm_kernel_pending_semantics_run(choices[:]); reason != "" {
			if tc.is_final do fmt.eprintf("Generated pending DM semantic replay: choices=%v reason=%s\n", choices, reason)
			return hgl.interesting(reason)
		}
		return hgl.valid()
	}

	prop_generated_dm_pending_lifecycle_orderings :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		choices: [64]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw pending lifecycle runnable rank")
			choice = u8(drawn)
		}
		if reason := dm_kernel_pending_semantics_run(choices[:], false, true); reason != "" {
			if tc.is_final do fmt.eprintf("Generated pending DM lifecycle replay: choices=%v reason=%s\n", choices, reason)
			return hgl.interesting(reason)
		}
		return hgl.valid()
	}

	prop_generated_dm_pending_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count, count_err := hgl.draw_i64(tc, 1, 12)
		if count_err == .Stop_Test do return hgl.abort()
		if count_err != nil do return hgl.interesting("draw pending history operation count")
		ops := make([]DM_Generated_Op, int(op_count))
		defer delete(ops)
		for &op in ops {
			kind, kind_err := hgl.draw_i64(tc, 0, i64(DM_Generated_Op_Kind.Send))
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("draw pending history operation kind")
			client_id, client_err := hgl.draw_i64(tc, 0, DM_GENERATED_CLIENTS - 1)
			if client_err == .Stop_Test do return hgl.abort()
			if client_err != nil do return hgl.interesting("draw pending history client")
			split_choice, split_err := hgl.draw_i64(tc, 0, 255)
			if split_err == .Stop_Test do return hgl.abort()
			if split_err != nil do return hgl.interesting("draw pending history receive split")
			op = {
				kind         = DM_Generated_Op_Kind(kind),
				client_id    = int(client_id),
				split_choice = u8(split_choice),
			}
		}
		choices: [64]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw pending history runnable rank")
			choice = u8(drawn)
		}
		if reason := dm_pending_generated_history_run(ops, choices[:]); reason != "" {
			if tc.is_final {
				fmt.eprintf("Generated pending DM history failure: reason=%s choices=%v\nops := [?]DM_Generated_Op {\n", reason, choices)
				for op in ops do fmt.eprintf("\t{kind = .%v, client_id = %d, split_choice = %d},\n", op.kind, op.client_id, op.split_choice)
				fmt.eprintf("}\n")
			}
			return hgl.interesting(reason)
		}
		return hgl.valid()
	}

	prop_generated_dm_pending_lifecycle_histories :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count, count_err := hgl.draw_i64(tc, 1, 12)
		if count_err == .Stop_Test do return hgl.abort()
		if count_err != nil do return hgl.interesting("draw pending lifecycle history operation count")
		ops := make([]DM_Generated_Op, int(op_count))
		defer delete(ops)
		kinds := [?]DM_Generated_Op_Kind{.Start, .Leave, .Subscribe, .Send, .Disconnect, .Reconnect}
		for &op in ops {
			kind_index, kind_err := hgl.draw_i64(tc, 0, len(kinds) - 1)
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("draw pending lifecycle history operation kind")
			client_id, client_err := hgl.draw_i64(tc, 0, DM_GENERATED_CLIENTS - 1)
			if client_err == .Stop_Test do return hgl.abort()
			if client_err != nil do return hgl.interesting("draw pending lifecycle history client")
			split_choice, split_err := hgl.draw_i64(tc, 0, 255)
			if split_err == .Stop_Test do return hgl.abort()
			if split_err != nil do return hgl.interesting("draw pending lifecycle history receive split")
			op = {
				kind         = kinds[int(kind_index)],
				client_id    = int(client_id),
				split_choice = u8(split_choice),
			}
		}
		choices: [96]u8
		for &choice in choices {
			drawn, draw_err := hgl.draw_i64(tc, 0, 255)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw pending lifecycle history runnable rank")
			choice = u8(drawn)
		}
		if reason := dm_pending_generated_lifecycle_run(ops, choices[:]); reason != "" {
			if tc.is_final do fmt.eprintf("Generated pending lifecycle history failure: reason=%s choices=%v ops=%v\n", reason, choices, ops)
			return hgl.interesting(reason)
		}
		return hgl.valid()
	}
}

@(test)
test_generated_dm_authorization_replay_fixture :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ops := [?]DM_Generated_Op {
			{kind = .Start, client_id = 0},
			{kind = .Start, client_id = 2},
			{kind = .Send, client_id = 0},
			{kind = .Leave, client_id = 1},
			{kind = .Leave, client_id = 1},
			{kind = .Send, client_id = 1},
			{kind = .Disconnect, client_id = 1},
			{kind = .Reconnect, client_id = 1},
			{kind = .Subscribe, client_id = 1},
			{kind = .Disconnect, client_id = 0},
			{kind = .Start, client_id = 1},
			{kind = .Reconnect, client_id = 0},
			{kind = .Subscribe, client_id = 0},
			{kind = .Send, client_id = 0},
			{kind = .Leave, client_id = 0},
			{kind = .Start, client_id = 1},
			{kind = .Send, client_id = 1},
		}
		reason, ok := dm_generated_run(ops[:], true)
		testing.expectf(t, ok, "generated DM replay fixture failed: %s", reason)
	}
}

@(test)
test_hegel_generated_dm_authorization_and_workspace_isolation :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_generated_dm_authorization, nil, {test_cases = DM_GENERATED_CASES})
		testing.expectf(t, err == nil, "generated DM authorization property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_simulation_dm_semantics_compose_with_kernel_close_and_socket_reuse :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		oldest_first := [?]u8{0, 0, 0, 0, 0, 0, 0, 0}
		newest_first := [?]u8{255, 255, 255, 255, 255, 255, 255, 255}
		testing.expect_value(t, dm_kernel_close_reuse_run(oldest_first[:]), "")
		testing.expect_value(t, dm_kernel_close_reuse_run(newest_first[:]), "")
	}
}

@(test)
test_hegel_generated_dm_kernel_event_orderings :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_generated_dm_kernel_event_orderings, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated DM kernel event ordering property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_dm_pending_semantic_orderings :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		oldest_first := [?]u8{0, 0, 0, 0, 0, 0, 0, 0}
		newest_first := [?]u8{255, 255, 255, 255, 255, 255, 255, 255}
		testing.expect_value(t, dm_kernel_pending_semantics_run(oldest_first[:]), "")
		testing.expect_value(t, dm_kernel_pending_semantics_run(newest_first[:], true), "")
		result, err := hgl.run(prop_generated_dm_pending_semantic_orderings, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated pending DM semantic ordering property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_dm_pending_lifecycle_orderings :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		oldest_first := [?]u8{0, 0, 0, 0, 0, 0, 0, 0}
		newest_first := [?]u8{255, 255, 255, 255, 255, 255, 255, 255}
		testing.expect_value(t, dm_kernel_pending_semantics_run(oldest_first[:], false, true), "")
		testing.expect_value(t, dm_kernel_pending_semantics_run(newest_first[:], true, true), "")
		result, err := hgl.run(prop_generated_dm_pending_lifecycle_orderings, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated pending DM lifecycle ordering property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_dm_pending_histories :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		ops := [?]DM_Generated_Op {
			{kind = .Start, client_id = 0, split_choice = 1},
			{kind = .Leave, client_id = 1, split_choice = 64},
			{kind = .Subscribe, client_id = 1, split_choice = 128},
			{kind = .Start, client_id = 1, split_choice = 255},
			{kind = .Leave, client_id = 0, split_choice = 32},
			{kind = .Start, client_id = 2, split_choice = 96},
			{kind = .Leave, client_id = 3, split_choice = 160},
			{kind = .Subscribe, client_id = 3, split_choice = 224},
			{kind = .Send, client_id = 0, split_choice = 48},
			{kind = .Send, client_id = 1, split_choice = 112},
			{kind = .Send, client_id = 2, split_choice = 176},
		}
		oldest_first := [?]u8{0, 0, 0, 0, 0, 0, 0, 0}
		newest_first := [?]u8{255, 255, 255, 255, 255, 255, 255, 255}
		testing.expect_value(t, dm_pending_generated_history_run(ops[:], oldest_first[:]), "")
		testing.expect_value(t, dm_pending_generated_history_run(ops[:], newest_first[:], true), "")
		result, err := hgl.run(prop_generated_dm_pending_histories, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated pending DM history property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_hegel_generated_dm_pending_lifecycle_histories :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		ops := [?]DM_Generated_Op {
			{kind = .Start, client_id = 0, split_choice = 64},
			{kind = .Start, client_id = 2, split_choice = 192},
			{kind = .Disconnect, client_id = 1},
			{kind = .Subscribe, client_id = 1, split_choice = 32},
			{kind = .Reconnect, client_id = 1},
			{kind = .Subscribe, client_id = 1, split_choice = 96},
			{kind = .Leave, client_id = 0, split_choice = 160},
			{kind = .Disconnect, client_id = 2},
			{kind = .Reconnect, client_id = 2},
			{kind = .Start, client_id = 3, split_choice = 224},
		}
		oldest_first: [96]u8
		newest_first: [96]u8
		for &choice in newest_first do choice = 255
		cancellation_ops := [?]DM_Generated_Op {
			{kind = .Start, client_id = 0, split_choice = 0},
			{kind = .Disconnect, client_id = 0},
			{kind = .Reconnect, client_id = 0},
		}
		send_generation_ops := [?]DM_Generated_Op {
			{kind = .Send, client_id = 0, split_choice = 0},
			{kind = .Disconnect, client_id = 0},
			{kind = .Reconnect, client_id = 0},
			{kind = .Start, client_id = 0, split_choice = 0},
			{kind = .Send, client_id = 0, split_choice = 0},
		}
		queued_cancellation_ops := [?]DM_Generated_Op {
			{kind = .Start, client_id = 0, split_choice = 0},
			{kind = .Leave, client_id = 0, split_choice = 0},
			{kind = .Disconnect, client_id = 0},
			{kind = .Reconnect, client_id = 0},
		}
		// Regression: sender ACK arrives, but every recipient delivery is canceled.
		canceled_delivery_ops := [?]DM_Generated_Op {
			{kind = .Start, client_id = 0},
			{kind = .Send, client_id = 0},
			{kind = .Start, client_id = 0},
			{kind = .Start, client_id = 0},
			{kind = .Disconnect, client_id = 1},
		}
		canceled_delivery_choices: [96]u8
		canceled_delivery_choices[2] = 1
		canceled_delivery_choices[3] = 1
		testing.expect_value(t, dm_pending_generated_lifecycle_run(canceled_delivery_ops[:], canceled_delivery_choices[:]), "")
		testing.expect_value(t, dm_pending_generated_lifecycle_run(cancellation_ops[:], oldest_first[:]), "")
		testing.expect_value(t, dm_pending_generated_lifecycle_run(send_generation_ops[:], newest_first[:], true), "")
		testing.expect_value(t, dm_pending_generated_lifecycle_run(queued_cancellation_ops[:], newest_first[:], false, true), "")
		testing.expect_value(t, dm_pending_generated_lifecycle_run(ops[:], oldest_first[:]), "")
		testing.expect_value(t, dm_pending_generated_lifecycle_run(ops[:], newest_first[:]), "")
		result, err := hgl.run(prop_generated_dm_pending_lifecycle_histories, nil, {test_cases = 96})
		testing.expectf(t, err == nil, "generated pending DM lifecycle history property failed: err=%v interesting=%v", err, result.interesting_test_cases)
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

		guest := dm_sim_install(&ctx, 1, "dm_start_denials", "guest", false)
		alice := dm_sim_install(&ctx, 2, "dm_start_denials", "alice")
		testing.expect(t, guest != nil && alice != nil, "expected denial clients to install")
		if guest == nil || alice == nil do return
		ws := dm_sim_track_connected(alice)
		testing.expect(t, ws != nil, "expected denial workspace")
		if ws == nil do return

		process_start_dm(guest, pr.StartDMRequest{username = "alice", correlation_id = 101})
		dm_sim_expect_error(t, &ctx, guest, .Not_Authenticated, "alice", "Not authenticated", 101)
		testing.expect_value(t, len(ws.conversations), 0)
		testing.expect_value(t, len(ws.user_dms), 0)
		testing.expect_value(t, len(guest.rooms), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice.sock), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_list_dms(guest, pr.ListDMsRequest{correlation_id = 104})
		dm_sim_expect_error(t, &ctx, guest, .Not_Authenticated, "", "Not authenticated", 104)
		testing.expect_value(t, len(ws.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_leave_dm(guest, pr.LeaveDMRequest{conv_id = pr.make_dm_conversation_id("alice", "guest"), correlation_id = 105})
		dm_sim_expect_error(t, &ctx, guest, .Not_Authenticated, "", "Not authenticated", 105)
		testing.expect_value(t, len(ws.conversations), 0)
		testing.expect_value(t, len(ws.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_start_dm(alice, pr.StartDMRequest{username = "alice", correlation_id = 102})
		dm_sim_expect_error(t, &ctx, alice, .Cannot_DM_Self, "alice", "Cannot start DM with yourself", 102)
		testing.expect_value(t, len(ws.conversations), 0)
		testing.expect_value(t, len(ws.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_start_dm(alice, pr.StartDMRequest{username = "missing", correlation_id = 103})
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

		alice := dm_sim_install(&ctx, 1, "dm_access", "alice")
		bob := dm_sim_install(&ctx, 2, "dm_access", "bob")
		mallory := dm_sim_install(&ctx, 3, "dm_access", "mallory")
		testing.expect(t, alice != nil && bob != nil && mallory != nil, "expected access clients to install")
		if alice == nil || bob == nil || mallory == nil do return
		ws := dm_sim_track_connected(alice)
		_ = dm_sim_track_connected(bob)
		_ = dm_sim_track_connected(mallory)
		conv_id := pr.make_dm_conversation_id("alice", "bob")
		process_start_dm(alice, pr.StartDMRequest{username = "bob", correlation_id = 201})
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

		process_leave_dm(mallory, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 202})
		dm_sim_expect_error(t, &ctx, mallory, .DM_Not_Found, "", "Not in this DM", 202)
		testing.expect(t, "mallory" not_in ws.user_dms, "leave denial must not create user DM membership")
		testing.expect_value(t, subscriber_count(conv), 2)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_leave_dm(mallory, pr.LeaveDMRequest{conv_id = 44, correlation_id = 203})
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

		alice := dm_sim_install(&ctx, 1, "dm_repeat", "alice")
		bob := dm_sim_install(&ctx, 2, "dm_repeat", "bob")
		if alice == nil || bob == nil do return
		ws := dm_sim_track_connected(alice)
		_ = dm_sim_track_connected(bob)
		conv_id := pr.make_dm_conversation_id("alice", "bob")

		process_start_dm(alice, pr.StartDMRequest{username = "bob", correlation_id = 301})
		nrc_sim_clear_inboxes(&ctx.sim)
		process_start_dm(alice, pr.StartDMRequest{username = "bob", correlation_id = 302})
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
		testing.expect_value(t, len(ws.user_dms["alice"]), 1)
		testing.expect_value(t, len(ws.user_dms["bob"]), 1)
		testing.expect_value(t, subscriber_count(conv), 2)
		testing.expect_value(t, len(alice.rooms), 1)
		testing.expect_value(t, len(bob.rooms), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_leave_dm(alice, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 303})
		dm_sim_expect_left(t, &ctx, alice, conv_id, 303)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob.sock), 0)
		testing.expect(t, "alice" not_in ws.user_dms, "first leave should remove alice membership")
		testing.expect_value(t, len(ws.user_dms["bob"]), 1)
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
		process_leave_dm(alice, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 304})
		dm_sim_expect_error(t, &ctx, alice, .DM_Not_Found, "", "Not in this DM", 304)
		testing.expect_value(t, subscriber_count(conv), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_leave_dm(bob, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 305})
		dm_sim_expect_left(t, &ctx, bob, conv_id, 305)
		testing.expect(t, get_conversation(ws, conv_id) == nil, "last leave should destroy orphaned DM")
		testing.expect(t, "bob" not_in ws.user_dms, "last leave should remove bob membership map")
		testing.expect(t, conv_id not_in bob.rooms, "last leave should remove bob socket membership")
		testing.expect_value(t, len(ws.conversations), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_leave_dm(bob, pr.LeaveDMRequest{conv_id = conv_id, correlation_id = 306})
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

		alice := dm_sim_install(&ctx, 1, "dm_disconnect", "alice")
		bob := dm_sim_install(&ctx, 2, "dm_disconnect", "bob")
		if alice == nil || bob == nil do return
		ws := dm_sim_track_connected(alice)
		_ = dm_sim_track_connected(bob)
		conv_id := pr.make_dm_conversation_id("alice", "bob")
		process_start_dm(alice, pr.StartDMRequest{username = "bob", correlation_id = 401})
		conv := get_conversation(ws, conv_id)
		if conv == nil do return

		nrc_sim_clear_inboxes(&ctx.sim)
		connection_run_logical_cleanup(alice, false)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, alice.logical_cleanup_done, "disconnect should run logical cleanup")
		testing.expect(t, alice.rooms == nil, "disconnect should release socket membership map")
		testing.expect(t, !conversation_has_subscriber(conv, alice.sock), "disconnect should remove alice subscriber")
		testing.expect(t, conversation_has_subscriber(conv, bob.sock), "disconnect should retain bob subscriber")
		testing.expect_value(t, subscriber_count(conv), 1)
		testing.expect_value(t, len(ws.user_dms["alice"]), 1)
		testing.expect_value(t, len(ws.user_dms["bob"]), 1)
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

		alice_a := dm_sim_install(&ctx, 1, "dm_workspace_a", "alice")
		bob_b := dm_sim_install(&ctx, 2, "dm_workspace_b", "bob")
		if alice_a == nil || bob_b == nil do return
		ws_a := dm_sim_track_connected(alice_a)
		ws_b := dm_sim_track_connected(bob_b)

		process_start_dm(alice_a, pr.StartDMRequest{username = "bob", correlation_id = 501})
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
		process_start_dm(alice_a, pr.StartDMRequest{username = "bob", correlation_id = 502})
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_a.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob_a.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, alice_b.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, bob_b.sock), 0)
		conv_a := get_conversation(ws_a, conv_id)
		testing.expect(t, conv_a != nil, "workspace A should own its DM conversation")
		testing.expect(t, get_conversation(ws_b, conv_id) == nil, "workspace B should remain independent")
		testing.expect_value(t, len(ws_a.user_dms["alice"]), 1)
		testing.expect_value(t, len(ws_a.user_dms["bob"]), 1)
		testing.expect_value(t, len(ws_b.user_dms), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_start_dm(alice_b, pr.StartDMRequest{username = "bob", correlation_id = 503})
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
