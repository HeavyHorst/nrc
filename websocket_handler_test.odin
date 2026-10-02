package main

// Exercises the WebSocket connection handler at the boundary between raw frames,
// protocol messages, authentication, HTTP upgrade handoff, and worker queues.
// This file intentionally mixes focused parser/handler checks with deterministic
// handoff stress fixtures because regressions here usually appear as lost frames,
// leaked temporary upgrade connections, or incorrectly routed authenticated users.

import "base:runtime"

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:time"

import "byte_pool"
import hgl "hegel"
import nbio "nbio/poly"
import pr "protocol"
import ws "websocket"

when !NRC_SIMULATION {
	_ :: bytes.equal
	_ :: endian.put_u16
}

@(test)
test_deferred_protocol_mutation_replays_after_fsync_without_early_visibility :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 118)
	defer worker_state_destroy_core_for_test()
	td.asset_seq = 0

	data_dir := storage_layout_test_setup("deferred-protocol-replay")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 1))
	workspace := "deferred-protocol-replay"
	workspace_bytes := transmute([]byte)workspace
	shard := int(shard_for_workspace(workspace_bytes))
	generation_dir := sharded_generation_path(data_dir, 1)
	defer delete(generation_dir)
	testing.expect(t, init_shard_writer_registry(&td.shard_writers, generation_dir, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_writer_registry(&td.shard_writers)
	writer := shard_writer_for_workspace(&td.shard_writers, workspace_bytes)
	testing.expect(t, writer != nil)
	if writer == nil do return

	c := connection_test_install_fake(
		Fake_Connection_Options {
			sock = connection_test_fake_socket(118),
			state = .Idle,
			workspace_id = workspace,
			verified_username = "deferred-user",
			authenticated = true,
			cache_workspace = true,
			init_send_queue = true,
		},
	)
	testing.expect(t, c != nil)
	if c == nil do return
	defer connection_test_uninstall(c)
	c.is_sending = true

	req := pr.CreateAssetRequest {
		conv_id          = pr.WORKSPACE_DATA_ID,
		asset_type       = .Document,
		payload_encoding = .Plain,
		payload_raw_len  = 4,
		payload          = transmute([]byte)string("body"),
		correlation_id   = 91,
	}
	payload := make([]byte, pr.getSizeCreateAssetRequest(req))
	defer delete(payload)
	payload_len := pr.serializeCreateAssetRequest(req, payload)
	testing.expect_value(t, payload_len, len(payload))
	update_req := pr.UpdateAssetRequest {
		conv_id          = req.conv_id,
		asset_id         = 1,
		payload_encoding = .Plain,
		payload_raw_len  = 7,
		payload          = transmute([]byte)string("updated"),
		correlation_id   = 92,
	}
	update_payload := make([]byte, pr.getSizeUpdateAssetRequest(update_req))
	defer delete(update_payload)
	update_len := pr.serializeUpdateAssetRequest(update_req, update_payload)
	testing.expect_value(t, update_len, len(update_payload))

	writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES
	writer.fsync_in_flight = true
	persistent_mutation_failure_seen = false
	process_protocol_payload(c, payload)
	// The dependent update fits physically, but must queue behind the deferred
	// create instead of observing pre-create state or acknowledging first.
	writer.wal.file_size_bytes = 0
	process_protocol_payload(c, update_payload)

	conv := get_conversation(get_workspace(workspace), req.conv_id)
	testing.expect(t, conv != nil)
	if conv != nil do testing.expect_value(t, len(conv.assets), 0)
	testing.expect_value(t, writer.wal.record_count, u64(0))
	testing.expect_value(t, len(writer.deferred_requests), 2)
	testing.expect_value(t, c.pending_io, 2)
	testing.expect_value(t, c.deferred_shard_requests, u16(2))
	testing.expect_value(t, send_queue_len(c), 0)
	testing.expect(t, !persistent_mutation_failure_seen)

	// Model successful completion before invoking the production replay drain.
	// Keeping this test's WAL physically small avoids testing rotation mechanics
	// a second time; the append test covers the full-WAL defer decision itself.
	writer.fsync_in_flight = false
	writer.wal.file_size_bytes = 0
	drain_shard_deferred_requests(writer)

	testing.expect_value(t, len(writer.deferred_requests), 0)
	testing.expect_value(t, c.pending_io, 0)
	testing.expect_value(t, c.deferred_shard_requests, u16(0))
	testing.expect_value(t, writer.wal.record_count, u64(0))
	testing.expect_value(t, writer.wal.buffered_record_count, u64(2))
	testing.expect_value(t, send_queue_len(c), 2)
	conv = get_conversation(get_workspace(workspace), req.conv_id)
	testing.expect(t, conv != nil && len(conv.assets) == 1, "replay should create exactly one asset before applying its dependent update")
	if conv != nil && conv.assets[1] != nil do testing.expect(t, string(conv.assets[1].payload) == "updated", "dependent update must run after deferred create")
}

@(test)
test_http_upgrade_sharded_routing_matches_writer_owner :: proc(t: ^testing.T) {
	for i in 0 ..< 100 {
		workspace := fmt.tprintf("sharded-route-%d", i)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		owner, owner_ok := logical_shard_worker(shard, 3)
		testing.expect(t, owner_ok)
		testing.expect_value(t, http_upgrade_target_worker_index(workspace, 3), owner)
	}
}

http_upgrade_receive_test_mu: sync.Mutex

HTTP_Upgrade_Fail_Size_Allocator :: struct {
	backing:   runtime.Allocator,
	fail_size: int,
}

http_upgrade_fail_size_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	state := (^HTTP_Upgrade_Fail_Size_Allocator)(allocator_data)
	if (mode == .Alloc || mode == .Alloc_Non_Zeroed) && size == state.fail_size {
		return nil, .Out_Of_Memory
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}

make_masked_test_frame :: proc(payload_len: int, opcode: ws.opcode, fin: bool) -> []byte {
	mask_key :: u32(0x01020304)
	mask_key_bytes := transmute([4]byte)mask_key

	h := ws.header {
		fin           = fin,
		opcode        = opcode,
		mask          = true,
		payloadLength = u64(payload_len),
		maskKey       = mask_key,
	}
	header, header_len := ws.writeFrameHeader(h)
	frame := make([]byte, header_len + payload_len)
	copy(frame[:header_len], header[:header_len])
	for i in 0 ..< payload_len {
		payload_byte := byte((i * 17 + 23) & 0xff)
		frame[header_len + i] = payload_byte ~ mask_key_bytes[i & 3]
	}
	return frame
}

make_test_ws_frame :: proc(
	payload: []byte,
	opcode: ws.opcode,
	fin: bool,
	mask: bool = true,
	rsv1: bool = false,
	rsv2: bool = false,
	rsv3: bool = false,
) -> []byte {
	mask_key :: u32(0x01020304)
	mask_key_bytes := transmute([4]byte)mask_key
	h := ws.header {
		fin           = fin,
		rsv1          = rsv1,
		rsv2          = rsv2,
		rsv3          = rsv3,
		opcode        = opcode,
		mask          = mask,
		payloadLength = u64(len(payload)),
		maskKey       = mask_key,
	}
	header, header_len := ws.writeFrameHeader(h)
	frame := make([]byte, header_len + len(payload))
	copy(frame[:header_len], header[:header_len])
	for byte_value, i in payload {
		if mask {
			frame[header_len + i] = byte_value ~ mask_key_bytes[i & 3]
		} else {
			frame[header_len + i] = byte_value
		}
	}
	return frame
}

when NRC_SIMULATION {
	Websocket_Dispatch_Family :: enum {
		Messaging,
		Direct_Messages,
		Tasks,
		Assets,
		Edges,
		Graph,
	}

	websocket_dispatch_test_request :: proc(family: Websocket_Dispatch_Family, correlation_id: u32, buf: []byte) -> int {
		conv_id := pr.WORKSPACE_DATA_ID
		switch family {
		case .Messaging:
			return pr.serializeUnsubscribeConvsRequest(nil, buf, correlation_id)
		case .Direct_Messages:
			if len(buf) < 6 do return -1
			endian.put_u16(buf[0:2], .Big, u16(pr.Opcode.C_ListDMs))
			endian.put_u32(buf[2:6], .Big, correlation_id)
			return 6
		case .Tasks:
			return pr.serializeGetTasksRequest(pr.GetTasksRequest{conv_id = conv_id, correlation_id = correlation_id}, buf)
		case .Assets:
			return pr.serializeListAssetsRequest(conv_id, false, .Note, false, buf, correlation_id)
		case .Edges:
			return pr.serializeListAllEdgesRequest(pr.ListAllEdgesRequest{conv_id = conv_id, correlation_id = correlation_id}, buf)
		case .Graph:
			return pr.serializeGraphDegreeRequest(pr.GraphDegreeRequest{conv_id = conv_id, top_n = 5, correlation_id = correlation_id}, buf)
		}
		return -1
	}

	websocket_dispatch_test_response_correlation :: proc(payload: []byte, expected_opcode: pr.Opcode) -> (u32, pr.ProtocolParseError) {
		#partial switch expected_opcode {
		case .S_AckUnsubscribeConvs:
			msg, err := pr.parseAckUnsubscribeConvsMessage(payload)
			return msg.correlation_id, err
		case .S_DMList:
			entries: [1]pr.DMEntry
			msg, err := pr.parseDMListMessage(payload, entries[:])
			return msg.correlation_id, err
		case .S_TaskListResponse:
			tasks: [1]pr.Task
			attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			msg, err := pr.parseTaskListResponse(payload, tasks[:], attachments[:])
			return msg.correlation_id, err
		case .S_AssetList:
			msg, err := pr.parseAssetListMessage(payload)
			return msg.correlation_id, err
		case .S_AllEdgeList:
			edges: [1]pr.Edge
			msg, err := pr.parseAllEdgeListMessage(payload, edges[:])
			return msg.correlation_id, err
		case .S_GraphDegreeResult:
			entries: [1]pr.GraphDegreeEntry
			msg, err := pr.parseGraphDegreeResult(payload, entries[:])
			return msg.correlation_id, err
		}
		return 0, .InvalidOpcode
	}

	websocket_dispatch_test_expect_pong :: proc(t: ^testing.T, sim: ^Sim_Runtime, sock: net.TCP_Socket, index: int, label: string) {
		frame := nrc_sim_client_frame(sim, sock, index)
		header, _, header_err := ws.readFrameHeader(frame)
		testing.expectf(t, header_err == nil, "%s response should have a valid WebSocket header", label)
		if header_err != nil do return
		testing.expectf(t, header.fin && !header.mask && header.opcode == .opBinary, "%s response should be a final unmasked binary frame", label)

		payload, payload_ok := nrc_sim_frame_protocol_payload(frame)
		testing.expectf(t, payload_ok, "%s response should contain a protocol payload", label)
		if !payload_ok do return
		testing.expectf(t, pr.get_opcode(payload) == .S_Pong, "%s response should dispatch to application pong", label)
		pong, parse_err := pr.parsePongResponseMessage(payload)
		testing.expectf(t, parse_err == nil, "%s pong response should parse", label)
		testing.expectf(t, pong.timestamp == 1234, "%s pong should echo the request timestamp", label)
	}

	websocket_dispatch_test_expect_error :: proc(
		t: ^testing.T,
		sim: ^Sim_Runtime,
		conn: ^NRC_Connection,
		expected_origin: pr.Opcode,
		expected_correlation: u32,
		label: string,
	) {
		testing.expectf(t, nrc_sim_client_frame_count(sim, conn.sock) == 1, "%s should send exactly one response", label)
		if nrc_sim_client_frame_count(sim, conn.sock) != 1 do return

		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(sim, conn.sock, 0))
		testing.expectf(t, payload_ok, "%s response should be a binary protocol frame", label)
		if !payload_ok do return

		error_response, parse_err := pr.parseErrorResponseMessage(payload)
		testing.expectf(t, parse_err == nil, "%s response should decode as S_ErrorResponse", label)
		if parse_err != nil do return
		testing.expectf(t, error_response.origin_opcode == expected_origin, "%s should report the originating opcode", label)
		testing.expectf(t, error_response.correlation_id == expected_correlation, "%s should use the expected correlation behavior", label)
	}

	WebSocket_Segmentation_Output_Kind :: enum {
		None,
		Application_Pong,
		Native_Pong,
	}

	WebSocket_Segmentation_Frame_Model :: struct {
		start:              int,
		end:                int,
		header_len:         int,
		fragment_len_after: int,
		output_kind:        WebSocket_Segmentation_Output_Kind,
		output_value:       u64,
	}

	WEBSOCKET_SEGMENTATION_TAIL_LENGTHS :: [11]int{1, 2, 124, 125, 126, 127, 255, 256, 65_535, 65_536, MAX_FRAME_SIZE - 14}

	websocket_segmentation_append_frame :: proc(
		wire: ^[dynamic]byte,
		models: ^[dynamic]WebSocket_Segmentation_Frame_Model,
		payload: []byte,
		opcode: ws.opcode,
		fin: bool,
		fragment_len_after: int,
		output_kind: WebSocket_Segmentation_Output_Kind = .None,
		output_value: u64 = 0,
	) {
		frame := make_test_ws_frame(payload, opcode, fin)
		defer delete(frame)
		start := len(wire^)
		header_len := 6 // Two-byte base header plus the required four-byte client mask.
		if len(payload) > 125 do header_len = 8
		if len(payload) > 65_535 do header_len = 14
		append(wire, ..frame)
		append(
			models,
			WebSocket_Segmentation_Frame_Model {
				start = start,
				end = len(wire^),
				header_len = header_len,
				fragment_len_after = fragment_len_after,
				output_kind = output_kind,
				output_value = output_value,
			},
		)
	}

	websocket_segmentation_progress_matches :: proc(
		conn: ^NRC_Connection,
		sim: ^Sim_Runtime,
		wire: []byte,
		models: []WebSocket_Segmentation_Frame_Model,
		delivered: int,
	) -> bool {
		if conn == nil || conn.state >= .Will_Close do return false
		complete_count := 0
		last_complete_end := 0
		expected_output_count := 0
		expected_fragment_len := 0
		for model in models {
			if model.end > delivered do break
			complete_count += 1
			last_complete_end = model.end
			expected_fragment_len = model.fragment_len_after
			if model.output_kind != .None do expected_output_count += 1
		}
		if nrc_sim_client_frame_count(sim, conn.sock) != expected_output_count do return false
		if expected_fragment_len == 0 {
			if conn.fragment_buf != nil || conn.fragment_len != 0 do return false
		} else if conn.fragment_buf == nil || conn.fragment_len != expected_fragment_len {
			return false
		}

		suffix_len := delivered - last_complete_end
		if suffix_len == 0 {
			return conn.receive_accumulator.buf == nil && conn.receive_accumulator.used == 0 && conn.receive_accumulator.target == 0
		}
		if complete_count >= len(models) ||
		   conn.receive_accumulator.buf == nil ||
		   conn.receive_accumulator.used != suffix_len ||
		   !bytes.equal(conn.receive_accumulator.buf[:suffix_len], wire[last_complete_end:delivered]) {
			return false
		}
		next_model := models[complete_count]
		expected_target := 0
		if suffix_len >= next_model.header_len do expected_target = next_model.end - next_model.start
		return conn.receive_accumulator.target == expected_target
	}

	websocket_segmentation_output_matches :: proc(frame: []byte, model: WebSocket_Segmentation_Frame_Model) -> bool {
		header, header_len, header_err := ws.readFrameHeader(frame)
		if header_err != nil || !header.fin || header.mask || len(frame) != header_len + int(header.payloadLength) do return false
		payload := frame[header_len:]
		switch model.output_kind {
		case .Application_Pong:
			if header.opcode != .opBinary || pr.get_opcode(payload) != .S_Pong do return false
			pong, parse_err := pr.parsePongResponseMessage(payload)
			return parse_err == nil && u64(pong.timestamp) == model.output_value
		case .Native_Pong:
			if header.opcode != .opPong || len(payload) != 4 do return false
			value, _ := endian.get_u32(payload, .Big)
			return u64(value) == model.output_value
		case .None:
			return false
		}
		return false
	}

	prop_websocket_receive_segmentation_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		message_count, message_count_err := hgl.draw_i64(tc, 1, 4)
		if message_count_err == .Stop_Test do return hgl.abort()
		if message_count_err != nil do return hgl.interesting("draw application message count")

		wire := make([dynamic]byte, 0, 256)
		defer delete(wire)
		models := make([dynamic]WebSocket_Segmentation_Frame_Model, 0, 20)
		defer delete(models)
		for _ in 0 ..< int(message_count) {
			timestamp, timestamp_err := hgl.draw_i64(tc, 0, max(i64))
			if timestamp_err == .Stop_Test do return hgl.abort()
			if timestamp_err != nil do return hgl.interesting("draw application ping timestamp")
			fragment_count, fragment_count_err := hgl.draw_i64(tc, 1, 3)
			if fragment_count_err == .Stop_Test do return hgl.abort()
			if fragment_count_err != nil do return hgl.interesting("draw application fragment count")
			control_kind, control_kind_err := hgl.draw_i64(tc, 0, 2)
			if control_kind_err == .Stop_Test do return hgl.abort()
			if control_kind_err != nil do return hgl.interesting("draw control frame kind")
			control_position, control_position_err := hgl.draw_i64(tc, 0, fragment_count)
			if control_position_err == .Stop_Test do return hgl.abort()
			if control_position_err != nil do return hgl.interesting("draw control frame position")
			control_value, control_value_err := hgl.draw_u32(tc, 0, max(u32))
			if control_value_err == .Stop_Test do return hgl.abort()
			if control_value_err != nil do return hgl.interesting("draw control frame payload")

			request_buf: [16]byte
			request_len := pr.serializePingRequest(timestamp, request_buf[:])
			if request_len <= 0 do return hgl.interesting("serialize application ping")
			fragment_len := 0
			for position in 0 ..< int(fragment_count) + 1 {
				if position == int(control_position) && control_kind != 0 {
					control_payload: [4]byte
					endian.put_u32(control_payload[:], .Big, control_value)
					control_opcode := ws.opcode.opPong
					output_kind := WebSocket_Segmentation_Output_Kind.None
					if control_kind == 1 {
						control_opcode = .opPing
						output_kind = .Native_Pong
					}
					websocket_segmentation_append_frame(
						&wire,
						&models,
						control_payload[:],
						control_opcode,
						true,
						fragment_len,
						output_kind,
						u64(control_value),
					)
				}
				if position == int(fragment_count) do continue
				fragment_start := position * request_len / int(fragment_count)
				fragment_end := (position + 1) * request_len / int(fragment_count)
				fin := position + 1 == int(fragment_count)
				opcode := ws.opcode.opContinuation
				if position == 0 do opcode = .opBinary
				output_kind := WebSocket_Segmentation_Output_Kind.None
				if fin {
					fragment_len = 0
					output_kind = .Application_Pong
				} else {
					fragment_len += fragment_end - fragment_start
				}
				websocket_segmentation_append_frame(
					&wire,
					&models,
					request_buf[fragment_start:fragment_end],
					opcode,
					fin,
					fragment_len,
					output_kind,
					u64(timestamp),
				)
			}
		}
		include_unfinished_tail, tail_err := hgl.draw_bool(tc)
		if tail_err == .Stop_Test do return hgl.abort()
		if tail_err != nil do return hgl.interesting("draw unfinished fragmented tail")
		if include_unfinished_tail {
			tail_lengths := WEBSOCKET_SEGMENTATION_TAIL_LENGTHS
			tail_index, tail_index_err := hgl.draw_i64(tc, 0, len(tail_lengths) - 1)
			if tail_index_err == .Stop_Test do return hgl.abort()
			if tail_index_err != nil do return hgl.interesting("draw unfinished tail length")
			tail := make([]byte, tail_lengths[tail_index])
			for &value, index in tail do value = byte((index * 29 + 7) & 0xff)
			websocket_segmentation_append_frame(&wire, &models, tail, .opBinary, false, len(tail))
			delete(tail)
		}

		chunk_count, chunk_count_err := hgl.draw_i64(tc, 1, i64(min(len(wire), 16)))
		if chunk_count_err == .Stop_Test do return hgl.abort()
		if chunk_count_err != nil do return hgl.interesting("draw TCP chunk count")
		chunk_ends := make([dynamic]int, 0, int(chunk_count))
		defer delete(chunk_ends)
		offset := 0
		for chunk_index in 0 ..< int(chunk_count) {
			remaining_chunks := int(chunk_count) - chunk_index
			if remaining_chunks == 1 {
				offset = len(wire)
			} else {
				max_size := len(wire) - offset - (remaining_chunks - 1)
				size, size_err := hgl.draw_i64(tc, 1, i64(max_size))
				if size_err == .Stop_Test do return hgl.abort()
				if size_err != nil do return hgl.interesting("draw TCP chunk size")
				offset += int(size)
			}
			append(&chunk_ends, offset)
		}

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 180)
		defer simulation_test_end(&ctx)
		baseline := simulation_test_install_client(&ctx.sim, 0, "websocket-segmentation", "baseline")
		segmented := simulation_test_install_client(&ctx.sim, 1, "websocket-segmentation", "segmented")
		if baseline == nil || segmented == nil do return hgl.interesting("install segmentation clients")
		ctx.conns[0] = baseline
		ctx.conns[1] = segmented
		nrc_sim_clear_inboxes(&ctx.sim)

		baseline_wire := make([]byte, len(wire))
		defer delete(baseline_wire)
		copy(baseline_wire, wire[:])
		on_recv_websocket_fixed(connection_io_context_make(baseline), len(baseline_wire), baseline_wire, {}, nil)
		nrc_sim_run_all_send_completions(&ctx.sim)
		if !websocket_segmentation_progress_matches(baseline, &ctx.sim, wire[:], models[:], len(wire)) {
			return hgl.interesting("one-shot receive differs from independent frame model")
		}

		segmented_wire := make([]byte, len(wire))
		defer delete(segmented_wire)
		copy(segmented_wire, wire[:])
		offset = 0
		for end in chunk_ends {
			on_recv_websocket_fixed(connection_io_context_make(segmented), end - offset, segmented_wire[offset:end], {}, nil)
			nrc_sim_run_all_send_completions(&ctx.sim)
			if !websocket_segmentation_progress_matches(segmented, &ctx.sim, wire[:], models[:], end) {
				return hgl.interesting("segmented receive differs from independent frame model")
			}
			offset = end
		}

		baseline_count := nrc_sim_client_frame_count(&ctx.sim, baseline.sock)
		if nrc_sim_client_frame_count(&ctx.sim, segmented.sock) != baseline_count do return hgl.interesting("one-shot and segmented response counts differ")
		output_index := 0
		for model in models {
			if model.output_kind == .None do continue
			baseline_frame := nrc_sim_client_frame(&ctx.sim, baseline.sock, output_index)
			segmented_frame := nrc_sim_client_frame(&ctx.sim, segmented.sock, output_index)
			if !bytes.equal(baseline_frame, segmented_frame) do return hgl.interesting("one-shot and segmented response bytes differ")
			if !websocket_segmentation_output_matches(baseline_frame, model) do return hgl.interesting("response differs from independent semantic model")
			output_index += 1
		}
		if output_index != baseline_count do return hgl.interesting("independent response count differs")
		return hgl.valid()
	}
}

@(test)
test_hegel_websocket_receive_segmentation_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_websocket_receive_segmentation_equivalence, nil, {test_cases = 240, database_key = "websocket-receive-segmentation-v1"})
		testing.expectf(t, err == nil, "websocket receive segmentation property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_valid_websocket_protocol_dispatch :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 120)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "websocket_dispatch", "dispatcher")
		testing.expect(t, conn != nil, "dispatch client should install")
		if conn == nil do return
		ctx.conns[0] = conn

		cases := [?]struct {
			name:            string,
			family:          Websocket_Dispatch_Family,
			expected_opcode: pr.Opcode,
		} {
			{name = "messaging", family = .Messaging, expected_opcode = .S_AckUnsubscribeConvs},
			{name = "direct messages", family = .Direct_Messages, expected_opcode = .S_DMList},
			{name = "tasks", family = .Tasks, expected_opcode = .S_TaskListResponse},
			{name = "assets", family = .Assets, expected_opcode = .S_AssetList},
			{name = "edges", family = .Edges, expected_opcode = .S_AllEdgeList},
			{name = "graph", family = .Graph, expected_opcode = .S_GraphDegreeResult},
		}

		for test_case, case_index in cases {
			nrc_sim_clear_inboxes(&ctx.sim)
			correlation_id := u32(0x1400 + case_index)
			request_buf: [128]byte
			request_len := websocket_dispatch_test_request(test_case.family, correlation_id, request_buf[:])
			testing.expectf(t, request_len > 0, "case %d (%s) should serialize", case_index, test_case.name)
			if request_len <= 0 do continue

			frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
			processed, closed := process_websocket_frames(conn, frame)
			testing.expectf(t, !closed, "case %d (%s) should keep connection open", case_index, test_case.name)
			testing.expectf(t, processed == len(frame), "case %d (%s) should consume its frame", case_index, test_case.name)
			delete(frame)
			nrc_sim_run_all_send_completions(&ctx.sim)

			testing.expectf(
				t,
				nrc_sim_client_frame_count(&ctx.sim, conn.sock) == 1,
				"case %d (%s) should dispatch exactly one response",
				case_index,
				test_case.name,
			)
			response := nrc_sim_client_frame(&ctx.sim, conn.sock, 0)
			payload, payload_ok := nrc_sim_frame_protocol_payload(response)
			testing.expectf(t, payload_ok, "case %d (%s) response should be a binary protocol frame", case_index, test_case.name)
			if !payload_ok do continue
			testing.expectf(
				t,
				pr.get_opcode(payload) == test_case.expected_opcode,
				"case %d (%s) should reach the expected handler",
				case_index,
				test_case.name,
			)
			response_correlation, parse_err := websocket_dispatch_test_response_correlation(payload, test_case.expected_opcode)
			testing.expectf(t, parse_err == nil, "case %d (%s) response should parse", case_index, test_case.name)
			testing.expectf(t, response_correlation == correlation_id, "case %d (%s) should preserve request correlation", case_index, test_case.name)
		}

		ping_buf: [16]byte
		ping_len := pr.serializePingRequest(1234, ping_buf[:])

		nrc_sim_clear_inboxes(&ctx.sim)
		first_fragment := make_test_ws_frame(ping_buf[:3], .opBinary, false)
		last_fragment := make_test_ws_frame(ping_buf[3:ping_len], .opContinuation, true)
		processed, closed := process_websocket_frames(conn, first_fragment)
		testing.expect(t, !closed && processed == len(first_fragment), "first application fragment should be retained")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		processed, closed = process_websocket_frames(conn, last_fragment)
		testing.expect(t, !closed && processed == len(last_fragment), "final application fragment should dispatch the assembled payload")
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
		websocket_dispatch_test_expect_pong(t, &ctx.sim, conn.sock, 0, "fragmented")
		delete(first_fragment)
		delete(last_fragment)

		nrc_sim_clear_inboxes(&ctx.sim)
		first_ping := make_test_ws_frame(ping_buf[:ping_len], .opBinary, true)
		second_ping := make_test_ws_frame(ping_buf[:ping_len], .opBinary, true)
		coalesced := make([]byte, len(first_ping) + len(second_ping))
		copy(coalesced, first_ping)
		copy(coalesced[len(first_ping):], second_ping)
		processed, closed = process_websocket_frames(conn, coalesced)
		testing.expect(t, !closed && processed == len(coalesced), "coalesced application frames should both dispatch")
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 2)
		websocket_dispatch_test_expect_pong(t, &ctx.sim, conn.sock, 0, "first coalesced")
		websocket_dispatch_test_expect_pong(t, &ctx.sim, conn.sock, 1, "second coalesced")
		delete(first_ping)
		delete(second_ping)
		delete(coalesced)

		nrc_sim_clear_inboxes(&ctx.sim)
		partial_ping := make_test_ws_frame(ping_buf[:ping_len], .opBinary, true)
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, partial_ping[:1]), "partial frame header should enqueue")
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, partial_ping[1:5]), "partial frame body should enqueue")
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, partial_ping[5:]), "partial frame completion should enqueue")
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "partial header should run")
		testing.expect(t, conn.receive_accumulator.buf != nil, "partial header should start receive accumulation")
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "partial body should run")
		testing.expect(t, conn.receive_accumulator.buf != nil, "partial body should remain accumulated")
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "partial completion should run")
		testing.expect(t, conn.receive_accumulator.buf == nil, "complete frame should clear receive accumulation")
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
		websocket_dispatch_test_expect_pong(t, &ctx.sim, conn.sock, 0, "partial receive")
		delete(partial_ping)

		nrc_sim_clear_inboxes(&ctx.sim)
		malformed := [?]byte{0, byte(pr.Opcode.C_GetTasks), 0xDE, 0xAD, 0xBE, 0xEF}
		malformed_frame := make_test_ws_frame(malformed[:], .opBinary, true)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		processed, closed = process_websocket_frames(conn, malformed_frame)
		context.logger = previous_logger
		testing.expect(t, !closed && processed == len(malformed_frame), "parse error should not close the connection")
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
		error_payload, error_payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, 0))
		testing.expect(t, error_payload_ok, "parse error should produce a binary protocol response")
		if error_payload_ok {
			error_response, parse_err := pr.parseErrorResponseMessage(error_payload)
			testing.expect(t, parse_err == nil, "parse error response should parse")
			testing.expect_value(t, error_response.origin_opcode, pr.Opcode.C_GetTasks)
			testing.expect_value(t, error_response.correlation_id, u32(0))
		}
		delete(malformed_frame)
	}
}

@(test)
test_peer_close_echoes_payload_and_closes_without_grace_timer :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "peer_close_workspace", "peer-close-user")
		testing.expect(t, conn != nil, "peer-close client should install")
		if conn == nil do return
		ctx.conns[0] = conn
		nrc_sim_clear_inboxes(&ctx.sim)
		sock := conn.sock

		close_payload := [?]byte{0x03, 0xe8, 'b', 'y', 'e'}
		frame := make_test_ws_frame(close_payload[:], .opClose, true)
		defer delete(frame)
		processed, closed := process_websocket_frames(conn, frame)

		testing.expect(t, closed, "peer close should stop frame processing")
		testing.expect_value(t, processed, len(frame))
		testing.expect_value(t, conn.state, Connection_State.Will_Close)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, conn.state, Connection_State.Closing)
		testing.expect(t, nrc_sim_client_has_close_frame(&ctx.sim, sock, 1000, "bye"), "peer close payload should be echoed")
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 0)
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "peer close completion should run")
		reclaimed := connection_get(sock) == nil
		testing.expect(t, reclaimed, "peer-close connection should be reclaimed")
		if reclaimed do connection_test_live_count -= 1
		ctx.conns[0] = nil
	}
}

@(test)
test_malformed_websocket_protocol_dispatch :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 121)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "malformed_websocket_dispatch", "dispatcher")
		testing.expect(t, conn != nil, "malformed dispatch client should install")
		if conn == nil do return
		ctx.conns[0] = conn

		cases := [?]struct {
			name:            string,
			wire_opcode:     u16,
			expected_origin: pr.Opcode,
			body:            []byte,
		} {
			{name = "messaging", wire_opcode = u16(pr.Opcode.C_SendMessage), expected_origin = .C_SendMessage, body = []byte{0xA5}},
			{name = "direct messages", wire_opcode = u16(pr.Opcode.C_StartDM), expected_origin = .C_StartDM, body = []byte{0xA5}},
			{name = "tasks", wire_opcode = u16(pr.Opcode.C_GetTasks), expected_origin = .C_GetTasks, body = []byte{0xA5}},
			{name = "assets", wire_opcode = u16(pr.Opcode.C_GetAsset), expected_origin = .C_GetAsset, body = []byte{0xA5}},
			{name = "edges", wire_opcode = u16(pr.Opcode.C_ListAllEdges), expected_origin = .C_ListAllEdges, body = []byte{0xA5}},
			{name = "graph", wire_opcode = u16(pr.Opcode.C_GraphDegree), expected_origin = .C_GraphDegree, body = []byte{0xA5}},
			{name = "invalid opcode", wire_opcode = 9, expected_origin = pr.Opcode(0xFFFF)},
			{name = "valid but unhandled opcode", wire_opcode = u16(pr.Opcode.S_ServerReady), expected_origin = .S_ServerReady},
		}

		for test_case, case_index in cases {
			nrc_sim_clear_inboxes(&ctx.sim)
			payload := make([]byte, 2 + len(test_case.body))
			endian.put_u16(payload[:2], .Big, test_case.wire_opcode)
			copy(payload[2:], test_case.body)
			frame := make_test_ws_frame(payload, .opBinary, true)

			previous_logger := context.logger
			context.logger = log.nil_logger()
			processed, closed := process_websocket_frames(conn, frame)
			context.logger = previous_logger
			testing.expectf(t, processed == len(frame), "case %d (%s) should consume its frame", case_index, test_case.name)
			testing.expectf(t, !closed, "case %d (%s) should not close the connection", case_index, test_case.name)
			testing.expectf(t, conn.state == .Idle, "case %d (%s) should leave the connection idle", case_index, test_case.name)
			websocket_dispatch_test_expect_error(t, &ctx.sim, conn, test_case.expected_origin, 0, test_case.name)

			delete(frame)
			delete(payload)
		}

		too_short_payloads := [?][]byte{{}, {0xA5}}
		for payload, payload_index in too_short_payloads {
			nrc_sim_clear_inboxes(&ctx.sim)
			frame := make_test_ws_frame(payload, .opBinary, true)
			previous_logger := context.logger
			context.logger = log.nil_logger()
			processed, closed := process_websocket_frames(conn, frame)
			context.logger = previous_logger
			testing.expectf(t, processed == len(frame), "too-short case %d should consume its frame", payload_index)
			testing.expectf(t, !closed, "too-short case %d should not close the connection", payload_index)
			testing.expectf(t, conn.state == .Idle, "too-short case %d should leave the connection idle", payload_index)
			websocket_dispatch_test_expect_error(t, &ctx.sim, conn, pr.Opcode(0xFFFF), 0, "too-short protocol payload")
			delete(frame)
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		oversized := make([]byte, MAX_PROTOCOL_PAYLOAD_SIZE + 1)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		process_protocol_payload(conn, oversized)
		context.logger = previous_logger
		testing.expect(t, conn.state >= .Will_Close, "oversized protocol payload should close the connection")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		delete(oversized)
	}
}

@(test)
test_validate_websocket_frame_target_reports_incomplete_masked_header :: proc(t: ^testing.T) {
	conn := NRC_Connection{}
	frame := make_masked_test_frame(65_536, .opBinary, true)
	defer delete(frame)
	target, complete, success := validate_websocket_frame_target(&conn, frame[:13])
	testing.expect(t, success && !complete, "13-byte masked header prefix should remain incomplete")
	testing.expect_value(t, target, 0)
}

@(test)
test_validate_websocket_frame_target_learns_exact_wire_size :: proc(t: ^testing.T) {
	conn := NRC_Connection{}
	frame := make_masked_test_frame(24_000, .opBinary, true)
	defer delete(frame)
	target, complete, success := validate_websocket_frame_target(&conn, frame[:8])
	testing.expect(t, success && complete, "complete masked extended header should determine target")
	testing.expect_value(t, target, len(frame))
}

@(test)
test_fragment_accumulator_initial_allocation_is_bounded :: proc(t: ^testing.T) {
	original_spool := td.spool
	pool := byte_pool.init_buffer_pool()
	testing.expect(t, pool != nil, "byte pool should initialize")
	if pool == nil do return
	td.spool = pool
	defer {
		td.spool = original_spool
		byte_pool.destroy_buffer_pool(pool)
	}
	conn := NRC_Connection{}
	testing.expect(t, start_fragment_accumulator(&conn, []byte{1, 2, 3}), "fragment accumulator should start")
	testing.expect(t, len(conn.fragment_buf) < MAX_PROTOCOL_PAYLOAD_SIZE, "fragment storage should start below the protocol maximum")
	reset_fragment_accumulator(&conn)
}

@(test)
test_fragment_accumulator_grows_preserves_bytes_and_rejects_oversized_aggregate :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 138)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "fragment_growth", "fragment")
		testing.expect(t, conn != nil, "fragment client should install")
		if conn == nil do return
		ctx.conns[0] = conn

		initial := []byte{1, 2, 3, 4}
		testing.expect(t, start_fragment_accumulator(conn, initial), "fragment accumulator should start")
		testing.expect(t, len(conn.fragment_buf) < MAX_PROTOCOL_PAYLOAD_SIZE, "initial fragment allocation should be bounded")
		old_storage := raw_data(conn.fragment_buf)
		releases_before := td.spool.release_count
		appended := make([]byte, 80)
		defer delete(appended)
		for i in 0 ..< len(appended) do appended[i] = byte(i + 5)
		testing.expect(t, append_fragment_accumulator(conn, appended), "fragment accumulator should grow")
		testing.expect(t, raw_data(conn.fragment_buf) != old_storage, "growth should replace old storage")
		testing.expect_value(t, td.spool.release_count, releases_before + 1)
		for value, i in initial do testing.expect_value(t, conn.fragment_buf[i], value)
		for value, i in appended do testing.expect_value(t, conn.fragment_buf[len(initial) + i], value)

		previous_logger := context.logger
		context.logger = log.nil_logger()
		releases_before = td.spool.release_count
		oversized := make([]byte, MAX_PROTOCOL_PAYLOAD_SIZE)
		defer delete(oversized)
		append_ok := append_fragment_accumulator(conn, oversized)
		context.logger = previous_logger
		testing.expect(t, !append_ok, "oversized fragmented aggregate should be rejected")
		testing.expect(t, conn.fragment_buf == nil && conn.fragment_len == 0, "rejected aggregate should release fragment state")
		testing.expect_value(t, td.spool.release_count, releases_before + 1)
	}
}


@(test)
test_live_recv_parser_state_cleanup_on_error_and_uninstall :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		cases := [?]struct {
			name:       string,
			model:      WebSocket_Parser_Lifetime_Model,
			completion: WebSocket_Parser_Lifetime_Completion,
		} {
			{name = "accumulator recv error", model = .Accumulator, completion = .Recv_Error},
			{name = "fragment recv error", model = .Fragment, completion = .Recv_Error},
			{name = "accumulator plus fragment uninstall", model = .Accumulator_And_Fragment, completion = .Uninstall},
			{name = "accumulator plus fragment eof", model = .Accumulator_And_Fragment, completion = .Zero_Bytes},
		}

		for test_case, case_index in cases {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx, 120 + case_index)
			defer simulation_test_end(&ctx)

			conn := websocket_parser_lifetime_install_sim_connection(&ctx.sim, case_index)
			testing.expectf(t, conn != nil, "case %d (%s) should install connection", case_index, test_case.name)
			if conn != nil {
				ctx.conns[case_index] = conn
				conn_handle := conn.handle
				allocs_before := td.spool.allocation_count
				releases_before := td.spool.release_count
				used_before := td.spool.used

				pool_allocs, setup_ok := websocket_parser_lifetime_setup_state(conn, test_case.model)
				testing.expectf(t, setup_ok, "case %d (%s) should set up parser state", case_index, test_case.name)
				if setup_ok {
					testing.expectf(
						t,
						websocket_parser_lifetime_state_matches(conn, test_case.model),
						"case %d (%s) should hold requested parser state",
						case_index,
						test_case.name,
					)
					testing.expect_value(t, td.spool.allocation_count, allocs_before + pool_allocs)
					testing.expect_value(t, td.spool.release_count, releases_before)

					previous_logger := context.logger
					context.logger = log.nil_logger()
					websocket_parser_lifetime_apply_completion(conn, test_case.completion)
					context.logger = previous_logger
					if test_case.completion != .Uninstall {
						testing.expectf(t, conn.state == .Closing, "case %d (%s) should await physical close after recv terminal", case_index, test_case.name)
						testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)
						nrc_sim_run_all_close_completions(&ctx.sim)
						testing.expectf(
							t,
							connection_get_by_handle(conn_handle) == nil,
							"case %d (%s) should reclaim after physical close completion",
							case_index,
							test_case.name,
						)
						if connection_test_live_count > 0 do connection_test_live_count -= 1
						ctx.conns[case_index] = nil
					} else {
						connection_test_uninstall(conn)
						ctx.conns[case_index] = nil
					}

					testing.expectf(
						t,
						td.spool.allocation_count == allocs_before + pool_allocs,
						"case %d (%s) should not allocate unexpected pool buffers",
						case_index,
						test_case.name,
					)
					testing.expectf(
						t,
						td.spool.release_count == releases_before + pool_allocs,
						"case %d (%s) should release parser pool buffers exactly once",
						case_index,
						test_case.name,
					)
					testing.expectf(t, td.spool.used == used_before, "case %d (%s) should drain parser pool bytes", case_index, test_case.name)
				} else if ctx.conns[case_index] != nil {
					connection_test_uninstall(conn)
					ctx.conns[case_index] = nil
				}
			}
		}
	}
}

@(test)
test_hegel_live_recv_parser_state_cleanup :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_live_recv_parser_state_cleanup, nil, {test_cases = 160})
		testing.expectf(t, err == nil, "hegel live recv parser-state cleanup property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

when NRC_SIMULATION {
	WebSocket_Parser_Lifetime_Model :: enum {
		Accumulator,
		Fragment,
		Accumulator_And_Fragment,
	}

	WebSocket_Parser_Lifetime_Completion :: enum {
		Recv_Error,
		Zero_Bytes,
		Uninstall,
	}

	websocket_parser_lifetime_install_sim_connection :: proc(sim: ^Sim_Runtime, client_id: int) -> ^NRC_Connection {
		sock := connection_test_fake_socket(220 + client_id)
		nrc_sim_register_client(sim, sock)
		conn := connection_test_install_fake(
			Fake_Connection_Options {
				sock = sock,
				state = .Idle,
				verified_username = "parser-lifetime",
				authenticated = true,
				user_type = .User,
				track_active_socket = true,
			},
		)
		return conn
	}

	websocket_parser_lifetime_setup_state :: proc(conn: ^NRC_Connection, model: WebSocket_Parser_Lifetime_Model) -> (pool_allocs: u64, ok: bool) {
		switch model {
		case .Accumulator:
			frame := make_masked_test_frame(8, .opBinary, true)
			defer delete(frame)
			on_recv_websocket_fixed(connection_io_context_make(conn), 7, frame[:7], {}, nil)
			return 1, websocket_parser_lifetime_state_matches(conn, model)

		case .Fragment:
			payload := []byte{0, byte(pr.Opcode.C_Ping)}
			frame := make_test_ws_frame(payload, .opBinary, false)
			defer delete(frame)
			on_recv_websocket_fixed(connection_io_context_make(conn), len(frame), frame, {}, nil)
			return 1, websocket_parser_lifetime_state_matches(conn, model)

		case .Accumulator_And_Fragment:
			payload := []byte{0, byte(pr.Opcode.C_Ping)}
			start_frame := make_test_ws_frame(payload, .opBinary, false)
			defer delete(start_frame)
			on_recv_websocket_fixed(connection_io_context_make(conn), len(start_frame), start_frame, {}, nil)
			continuation_frame := make_masked_test_frame(8, .opContinuation, true)
			defer delete(continuation_frame)
			on_recv_websocket_fixed(connection_io_context_make(conn), 7, continuation_frame[:7], {}, nil)
			return 2, websocket_parser_lifetime_state_matches(conn, model)

		}
		return 0, false
	}

	websocket_parser_lifetime_state_matches :: proc(conn: ^NRC_Connection, model: WebSocket_Parser_Lifetime_Model) -> bool {
		accumulator_active := conn.receive_accumulator.buf != nil
		fragment_active := conn.fragment_buf != nil && conn.fragment_len > 0

		switch model {
		case .Accumulator:
			return accumulator_active && !fragment_active
		case .Fragment:
			return fragment_active && !accumulator_active
		case .Accumulator_And_Fragment:
			return fragment_active && accumulator_active
		}
		return false
	}

	websocket_parser_lifetime_apply_completion :: proc(conn: ^NRC_Connection, completion: WebSocket_Parser_Lifetime_Completion) {
		switch completion {
		case .Recv_Error:
			on_recv_websocket_fixed(connection_io_context_make(conn), 0, {}, {}, net.TCP_Recv_Error(.Connection_Closed))
		case .Zero_Bytes:
			on_recv_websocket_fixed(connection_io_context_make(conn), 0, {}, {}, nil)
		case .Uninstall:
		}
	}

	prop_live_recv_parser_state_cleanup :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		model_raw, model_err := hgl.draw_i64(tc, 0, i64(len(WebSocket_Parser_Lifetime_Model) - 1))
		if model_err == .Stop_Test do return hgl.abort()
		if model_err != nil do return hgl.interesting("draw parser lifetime model")

		completion_raw, completion_err := hgl.draw_i64(tc, 0, i64(len(WebSocket_Parser_Lifetime_Completion) - 1))
		if completion_err == .Stop_Test do return hgl.abort()
		if completion_err != nil do return hgl.interesting("draw parser lifetime completion")

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 130)
		defer simulation_test_end(&ctx)

		previous_logger := context.logger
		context.logger = log.nil_logger()
		defer context.logger = previous_logger

		conn := websocket_parser_lifetime_install_sim_connection(&ctx.sim, 0)
		if conn == nil {
			return hgl.interesting("install live parser lifetime connection")
		}
		ctx.conns[0] = conn
		conn_handle := conn.handle

		model := WebSocket_Parser_Lifetime_Model(model_raw)
		completion := WebSocket_Parser_Lifetime_Completion(completion_raw)
		allocs_before := td.spool.allocation_count
		releases_before := td.spool.release_count
		used_before := td.spool.used

		pool_allocs, setup_ok := websocket_parser_lifetime_setup_state(conn, model)
		if !setup_ok {
			return hgl.interesting("setup live parser lifetime state")
		}
		if td.spool.allocation_count != allocs_before + pool_allocs || td.spool.release_count != releases_before {
			return hgl.interesting("unexpected parser lifetime setup pool accounting")
		}

		websocket_parser_lifetime_apply_completion(conn, completion)
		if completion != .Uninstall {
			if conn.state != .Closing || nrc_sim_close_completion_count(&ctx.sim) != 1 {
				return hgl.interesting("terminal recv did not submit physical close")
			}
			nrc_sim_run_all_close_completions(&ctx.sim)
			if connection_get_by_handle(conn_handle) != nil {
				return hgl.interesting("terminal recv close completion did not reclaim parser connection")
			}
			connection_test_live_count -= 1
			ctx.conns[0] = nil
		} else {
			connection_test_uninstall(conn)
			ctx.conns[0] = nil
		}

		if td.spool.allocation_count != allocs_before + pool_allocs ||
		   td.spool.release_count != releases_before + pool_allocs ||
		   td.spool.used != used_before {
			hgl.note(
				tc,
				fmt.tprintf(
					"model=%v completion=%v allocs=%d/%d releases=%d/%d used=%d/%d",
					model,
					completion,
					td.spool.allocation_count,
					allocs_before + pool_allocs,
					td.spool.release_count,
					releases_before + pool_allocs,
					td.spool.used,
					used_before,
				),
			)
			return hgl.interesting("live parser lifetime pool buffers were not released exactly once")
		}

		return {}
	}
}

when NRC_SIMULATION {
	WebSocket_Policy_Violation :: enum {
		Unmasked,
		RSV1,
		RSV2,
		RSV3,
		Reserved_Data_Opcode,
		Reserved_Control_Opcode,
		Text,
		Fragmented_Ping,
		Fragmented_Pong,
		Fragmented_Close,
		One_Byte_Close,
		Oversized_Control,
		Continuation_Without_Fragment,
		Binary_During_Fragment,
		Configured_Payload_Limit,
		Configured_Frame_Limit,
		Fragmented_Aggregate_Limit,
	}

	websocket_policy_violation_frame :: proc(violation: WebSocket_Policy_Violation) -> (frame: []byte, terminal_size: int, needs_fragment: bool) {
		payload := []byte{0, byte(pr.Opcode.C_Ping)}
		switch violation {
		case .Unmasked:
			frame = make_test_ws_frame(payload, .opBinary, true, false)
		case .RSV1:
			frame = make_test_ws_frame(payload, .opBinary, true, true, true)
		case .RSV2:
			frame = make_test_ws_frame(payload, .opBinary, true, true, false, true)
		case .RSV3:
			frame = make_test_ws_frame(payload, .opBinary, true, true, false, false, true)
		case .Reserved_Data_Opcode:
			frame = make_test_ws_frame(payload, ._reserved_3, true)
		case .Reserved_Control_Opcode:
			frame = make_test_ws_frame(payload, ._reserved_11, true)
		case .Text:
			frame = make_test_ws_frame(payload, .opText, true)
		case .Fragmented_Ping:
			frame = make_test_ws_frame(payload[:1], .opPing, false)
		case .Fragmented_Pong:
			frame = make_test_ws_frame(payload[:1], .opPong, false)
		case .Fragmented_Close:
			frame = make_test_ws_frame({}, .opClose, false)
		case .One_Byte_Close:
			frame = make_test_ws_frame(payload[:1], .opClose, true)
		case .Oversized_Control:
			oversized: [126]byte
			frame = make_test_ws_frame(oversized[:], .opPing, true)
		case .Continuation_Without_Fragment:
			frame = make_test_ws_frame(payload, .opContinuation, true)
		case .Binary_During_Fragment:
			frame = make_test_ws_frame(payload, .opBinary, true)
			needs_fragment = true
		case .Configured_Payload_Limit:
			h := ws.header {
				fin           = true,
				opcode        = .opBinary,
				mask          = true,
				payloadLength = u64(MAX_PROTOCOL_PAYLOAD_SIZE) + 1,
				maskKey       = 0x01020304,
			}
			header, header_len := ws.writeFrameHeader(h)
			frame = make([]byte, header_len)
			copy(frame, header[:header_len])
			terminal_size = header_len
			return
		case .Configured_Frame_Limit:
			h := ws.header {
				fin           = true,
				opcode        = .opBinary,
				mask          = true,
				payloadLength = MAX_PROTOCOL_PAYLOAD_SIZE,
				maskKey       = 0x01020304,
			}
			header, header_len := ws.writeFrameHeader(h)
			frame = make([]byte, header_len)
			copy(frame, header[:header_len])
			terminal_size = header_len
			return
		case .Fragmented_Aggregate_Limit:
			continuation: [15]byte
			frame = make_test_ws_frame(continuation[:], .opContinuation, true)
			needs_fragment = true
		}
		terminal_size = len(frame)
		return
	}

	websocket_policy_run_segmented_case :: proc(tc: ^hgl.Test_Case, violation: WebSocket_Policy_Violation, chunk_sizes: []int) -> hgl.Body_Result {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 181)
		defer simulation_test_end(&ctx)

		previous_logger := context.logger
		context.logger = log.nil_logger()
		defer context.logger = previous_logger

		conn := websocket_parser_lifetime_install_sim_connection(&ctx.sim, 0)
		if conn == nil do return hgl.interesting("install policy-classifier connection")
		ctx.conns[0] = conn
		conn_handle := conn.handle
		used_before := td.spool.used

		frame, terminal_size, needs_fragment := websocket_policy_violation_frame(violation)
		defer delete(frame)
		if violation == .RSV1 && (len(frame) == 0 || frame[0] & 0x40 == 0) do return hgl.interesting("RSV1 policy fixture did not encode RSV1")
		_, header_size, header_err := ws.readFrameHeader(frame)
		if header_err != nil do return hgl.interesting("policy fixture did not contain a complete header")
		if needs_fragment {
			start_payload := []byte{0, byte(pr.Opcode.C_Ping)}
			large_start: []byte
			if violation == .Fragmented_Aggregate_Limit {
				large_start = make([]byte, MAX_FRAME_SIZE - 14)
				start_payload = large_start
			}
			start_frame := make_test_ws_frame(start_payload, .opBinary, false)
			on_recv_websocket_fixed(connection_io_context_make(conn), len(start_frame), start_frame, {}, nil)
			delete(start_frame)
			delete(large_start)
			if conn.fragment_buf == nil || conn.state >= .Will_Close {
				return hgl.interesting("failed to establish fragmented-message precondition")
			}
		}

		delivered := 0
		for requested_size in chunk_sizes {
			if delivered >= len(frame) do break
			end := min(len(frame), delivered + max(1, requested_size))
			on_recv_websocket_fixed(connection_io_context_make(conn), end - delivered, frame[delivered:end], {}, nil)
			delivered = end
			if delivered < terminal_size {
				expected_target := 0
				if delivered >= header_size {
					expected_target = len(frame)
				}
				capacity_valid := len(conn.receive_accumulator.buf) == 14
				if expected_target > 0 {
					capacity_valid = len(conn.receive_accumulator.buf) == expected_target || len(conn.receive_accumulator.buf) == max(14, expected_target)
				}
				if conn.state >= .Will_Close ||
				   conn.receive_accumulator.buf == nil ||
				   conn.receive_accumulator.used != delivered ||
				   conn.receive_accumulator.target != expected_target ||
				   !capacity_valid ||
				   !bytes.equal(conn.receive_accumulator.buf[:delivered], frame[:delivered]) {
					return hgl.interesting(
						fmt.tprintf(
							"policy violation terminated before independent envelope boundary: violation=%v delivered=%d/%d header=%d state=%v acc=%d/%d cap=%d expected=%d/%d bytes=%v",
							violation,
							delivered,
							terminal_size,
							header_size,
							conn.state,
							conn.receive_accumulator.used,
							conn.receive_accumulator.target,
							len(conn.receive_accumulator.buf),
							delivered,
							expected_target,
							bytes.equal(conn.receive_accumulator.buf[:delivered], frame[:delivered]),
						),
					)
				}
			} else {
				break
			}
		}
		if delivered < terminal_size do return hgl.interesting("generated chunks did not reach policy boundary")
		if conn.state != .Closing || nrc_sim_close_completion_count(&ctx.sim) != 1 {
			return hgl.interesting(
				fmt.tprintf(
					"policy violation did not submit exactly one terminal close: violation=%v state=%v closes=%d delivered=%d/%d acc=%d/%d",
					violation,
					conn.state,
					nrc_sim_close_completion_count(&ctx.sim),
					delivered,
					terminal_size,
					conn.receive_accumulator.used,
					conn.receive_accumulator.target,
				),
			)
		}
		if conn.receive_accumulator.buf != nil {
			return hgl.interesting("policy violation retained receive accumulator state")
		}

		nrc_sim_run_all_close_completions(&ctx.sim)
		if connection_get_by_handle(conn_handle) != nil do return hgl.interesting("policy close did not reclaim connection")
		connection_test_live_count -= 1
		ctx.conns[0] = nil
		if td.spool.used != used_before do return hgl.interesting("policy terminal path did not release pool storage exactly")
		return hgl.valid()
	}

	prop_websocket_handler_policy_classification :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		violation_raw, violation_err := hgl.draw_i64(tc, 0, i64(len(WebSocket_Policy_Violation) - 1))
		if violation_err == .Stop_Test do return hgl.abort()
		if violation_err != nil do return hgl.interesting("draw WebSocket policy violation")
		violation := WebSocket_Policy_Violation(violation_raw)
		frame, terminal_size, _ := websocket_policy_violation_frame(violation)
		delete(frame)

		chunk_sizes: [16]int
		chunk_count := 0
		remaining := terminal_size
		for remaining > 0 && chunk_count < len(chunk_sizes) {
			if chunk_count == len(chunk_sizes) - 1 {
				chunk_sizes[chunk_count] = remaining
				chunk_count += 1
				break
			}
			size, size_err := hgl.draw_i64(tc, 1, i64(remaining))
			if size_err == .Stop_Test do return hgl.abort()
			if size_err != nil do return hgl.interesting("draw WebSocket policy TCP chunk")
			chunk_sizes[chunk_count] = int(size)
			chunk_count += 1
			remaining -= int(size)
		}
		return websocket_policy_run_segmented_case(tc, violation, chunk_sizes[:chunk_count])
	}
}

@(test)
test_hegel_websocket_handler_policy_classification :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		for violation_index in 0 ..< len(WebSocket_Policy_Violation) {
			chunks := [?]int{1, 1, 1, 1, 1, 1, 1, MAX_FRAME_SIZE}
			fixture_result := websocket_policy_run_segmented_case(nil, WebSocket_Policy_Violation(violation_index), chunks[:])
			testing.expectf(t, fixture_result.status == .Valid, "mandatory policy fixture %d failed: %s", violation_index, fixture_result.origin)
		}

		if !hgl.can_run() do return
		result, err := hgl.run(prop_websocket_handler_policy_classification, nil, {test_cases = 300, database_key = "websocket-handler-policy-v1"})
		testing.expectf(t, err == nil, "WebSocket handler policy property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_process_websocket_frames_rejects_client_protocol_violations :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)
	defer connection_test_storage_destroy()

	payload := []byte{0, byte(pr.Opcode.C_Ping)}
	cases := [?]struct {
		name:   string,
		opcode: ws.opcode,
		mask:   bool,
		rsv1:   bool,
		rsv2:   bool,
		rsv3:   bool,
	} {
		{name = "unmasked binary", opcode = .opBinary, mask = false},
		{name = "rsv1", opcode = .opBinary, mask = true, rsv1 = true},
		{name = "rsv2", opcode = .opBinary, mask = true, rsv2 = true},
		{name = "rsv3", opcode = .opBinary, mask = true, rsv3 = true},
		{name = "reserved data opcode", opcode = ._reserved_3, mask = true},
		{name = "reserved control opcode", opcode = ._reserved_11, mask = true},
		{name = "text frame", opcode = .opText, mask = true},
	}

	for test_case, case_index in cases {
		listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
		if !ok do return
		defer net.close(listen_sock)
		defer net.close(client_sock)

		conn := connection_test_install(accepted_sock, .Idle)
		testing.expect(t, conn != nil, "violation test connection should install")
		if conn == nil do continue

		frame := make_test_ws_frame(payload, test_case.opcode, true, test_case.mask, test_case.rsv1, test_case.rsv2, test_case.rsv3)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		processed, closed := process_websocket_frames(conn, frame)
		context.logger = previous_logger
		testing.expectf(t, closed, "case %d (%s) should close", case_index, test_case.name)
		testing.expectf(t, processed == len(frame), "case %d (%s) should consume the violating frame", case_index, test_case.name)
		delete(frame)
		connection_test_uninstall(conn)
	}
}

@(test)
test_process_websocket_frames_rejects_invalid_length_encodings :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)
	defer connection_test_storage_destroy()

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "invalid length test connection should install")
	if conn == nil do return
	defer connection_test_uninstall(conn)

	previous_logger := context.logger
	context.logger = log.nil_logger()

	frame := [?]byte{0x82, 0xFE, 0, 125, 1, 2, 3, 4}
	processed, closed := process_websocket_frames(conn, frame[:])
	context.logger = previous_logger
	testing.expect(t, closed, "non-minimal extended length should close the connection")
	testing.expect_value(t, processed, len(frame))
}

@(test)
test_validate_websocket_frame_target_rejects_huge_valid_length_without_overflow :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)
	defer connection_test_storage_destroy()

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "huge length test connection should install")
	if conn == nil do return
	defer connection_test_uninstall(conn)

	previous_logger := context.logger
	context.logger = log.nil_logger()

	frame_header := [?]byte{0x82, 0xFF, 0x40, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4}
	_, _, success := validate_websocket_frame_target(conn, frame_header[:])
	context.logger = previous_logger
	testing.expect(t, !success, "huge valid 64-bit length should be rejected cleanly")
	testing.expect(t, conn.state >= .Will_Close, "huge valid 64-bit length should close the connection")
}

@(test)
test_process_websocket_frames_replies_to_native_ping :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)
	defer connection_test_storage_destroy()

	orig_spool := td.spool
	pool := byte_pool.init_buffer_pool()
	testing.expect(t, pool != nil, "byte pool should initialize")
	if pool == nil do return
	td.spool = pool
	defer {
		td.spool = orig_spool
		byte_pool.destroy_buffer_pool(pool)
	}

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "native ping test connection should install")
	if conn == nil do return
	defer connection_test_uninstall(conn)

	ping_payload := [?]byte{'p', 'i', 'n', 'g'}
	frame := make_test_ws_frame(ping_payload[:], .opPing, true)
	processed, closed := process_websocket_frames(conn, frame)
	testing.expect_value(t, processed, len(frame))
	testing.expect(t, !closed, "valid native ping should not close")
	delete(frame)

	response_buf: [64]byte
	response_len := fast_ack_test_recv_until(t, client_sock, response_buf[:], 2 + len(ping_payload), time.Second, &td.io)
	testing.expect(t, response_len >= 2 + len(ping_payload), "native ping should receive a pong frame")
	if response_len >= 2 + len(ping_payload) {
		header, header_len, err := ws.readFrameHeader(response_buf[:response_len])
		testing.expect_value(t, err, nil)
		testing.expect_value(t, header.opcode, ws.opcode.opPong)
		testing.expect_value(t, header.mask, false)
		testing.expect_value(t, header.payloadLength, u64(len(ping_payload)))
		testing.expect(t, string(response_buf[header_len:header_len + len(ping_payload)]) == "ping", "pong payload should echo ping payload")
	}
}

@(test)
test_process_websocket_frames_rejects_control_frame_violations :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)
	defer connection_test_storage_destroy()

	oversized_payload: [126]byte
	one_payload := [?]byte{1}
	zero_payload := [?]byte{}
	cases := [?]struct {
		name:    string,
		opcode:  ws.opcode,
		fin:     bool,
		payload: []byte,
	} {
		{name = "fragmented ping", opcode = .opPing, fin = false, payload = one_payload[:]},
		{name = "fragmented pong", opcode = .opPong, fin = false, payload = one_payload[:]},
		{name = "fragmented close", opcode = .opClose, fin = false, payload = zero_payload[:]},
		{name = "one-byte close", opcode = .opClose, fin = true, payload = one_payload[:]},
		{name = "oversized ping", opcode = .opPing, fin = true, payload = oversized_payload[:]},
		{name = "oversized close", opcode = .opClose, fin = true, payload = oversized_payload[:]},
	}

	for test_case, case_index in cases {
		listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
		if !ok do return
		defer net.close(listen_sock)
		defer net.close(client_sock)

		conn := connection_test_install(accepted_sock, .Idle)
		testing.expect(t, conn != nil, "control violation test connection should install")
		if conn == nil do continue

		frame := make_test_ws_frame(test_case.payload, test_case.opcode, test_case.fin)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		processed, closed := process_websocket_frames(conn, frame)
		context.logger = previous_logger
		testing.expectf(t, closed, "case %d (%s) should close", case_index, test_case.name)
		testing.expectf(t, processed == len(frame), "case %d (%s) should consume the violating frame", case_index, test_case.name)
		delete(frame)
		connection_test_uninstall(conn)
	}
}

@(test)
test_on_recv_websocket_fixed_closes_on_garbage_after_upgrade :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)
	defer connection_test_storage_destroy()

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "garbage test connection should install")
	if conn == nil do return
	defer connection_test_uninstall(conn)

	previous_logger := context.logger
	context.logger = log.nil_logger()

	garbage := transmute([]byte)string("I'm not a good WS frame. Nope!")
	on_recv_websocket_fixed(connection_io_context_make(conn), len(garbage), garbage, {}, nil)
	context.logger = previous_logger

	testing.expect(t, conn.state >= .Will_Close, "garbage post-upgrade bytes should close the connection")
	testing.expect(t, conn.receive_accumulator.buf == nil, "garbage post-upgrade bytes should not be retained")
}

@(test)
test_on_recv_websocket_fixed_rejects_one_megabyte_frame_cleanly :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)
	defer connection_test_storage_destroy()

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := connection_test_install(accepted_sock, .Idle)
	testing.expect(t, conn != nil, "large over-limit test connection should install")
	if conn == nil do return
	defer connection_test_uninstall(conn)

	previous_logger := context.logger
	context.logger = log.nil_logger()

	payload_len :: 1_000_000
	frame := make_masked_test_frame(payload_len, .opBinary, true)
	defer delete(frame)

	initial_len :: nbio.BUFFER_SIZE / 2
	on_recv_websocket_fixed(connection_io_context_make(conn), initial_len, frame[:initial_len], {}, nil)
	context.logger = previous_logger

	testing.expect(t, conn.state >= .Will_Close, "1MB client frame should be rejected by the configured frame/payload limit")
	testing.expect(t, conn.receive_accumulator.buf == nil, "rejected 1MB frame should not leave receive state active")
}

@(test)
test_partial_http_upgrade_allocates_remainder_buffer :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok {
		return
	}
	defer net.close(listen_sock)
	defer net.close(client_sock)
	defer net.close(accepted_sock)

	server := NRC_Server {
		main_thread = 0,
	}
	conn := new(HTTP_Upgrade_Connection)
	conn.server = &server
	conn.sock = accepted_sock
	conn.state = .New

	partial := "GET /workspace HTTP/1.1\r\nHost: localhost\r\n"
	buf: [nbio.BUFFER_SIZE]byte
	copy(buf[:], partial)

	result := http_upgrade_process_received(conn, len(partial), buf[:len(partial)])
	testing.expect_value(t, result, HTTP_Upgrade_Recv_Result.Need_More)

	testing.expect(t, conn.http_remainder_buf != nil, "partial HTTP upgrade should allocate an HTTP remainder buffer")
	testing.expect_value(t, conn.http_received, len(partial))
	if conn.http_remainder_buf != nil {
		for i in 0 ..< len(partial) {
			testing.expect(t, conn.http_remainder_buf[i] == partial[i], "HTTP remainder buffer should preserve partial header bytes")
		}
	}

	http_temp_connection_free(conn)
}

@(test)
test_partial_http_upgrade_remainder_cleanup_on_terminal_recv :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)

	cases := [?]struct {
		name: string,
		kind: enum {
			Recv_Error,
			EOF,
			Oversize,
		},
	}{{name = "recv error", kind = .Recv_Error}, {name = "eof", kind = .EOF}, {name = "oversize continuation", kind = .Oversize}}

	for test_case, case_index in cases {
		listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
		if !ok {
			return
		}
		defer net.close(listen_sock)
		defer net.close(client_sock)

		server := NRC_Server {
			main_thread = 0,
		}
		conn := new(HTTP_Upgrade_Connection)
		conn.server = &server
		conn.sock = accepted_sock
		conn.state = .New
		conn_owned := true
		defer if conn_owned do http_temp_connection_free(conn)

		partial_len := len("GET /workspace HTTP/1.1\r\nHost: localhost\r\n")
		if test_case.kind == .Oversize {
			partial_len = nbio.BUFFER_SIZE - 8
		}

		buf: [nbio.BUFFER_SIZE]byte
		for i in 0 ..< partial_len {
			buf[i] = 'A'
		}
		result := http_upgrade_process_received(conn, partial_len, buf[:partial_len])
		testing.expectf(t, result == .Need_More, "case %d (%s) should need more bytes after partial header", case_index, test_case.name)
		testing.expectf(t, conn.http_remainder_buf != nil, "case %d (%s) should allocate HTTP remainder", case_index, test_case.name)
		testing.expectf(t, conn.http_received == partial_len, "case %d (%s) should record partial byte count", case_index, test_case.name)

		switch test_case.kind {
		case .Recv_Error:
			conn_owned = false
			previous_logger := context.logger
			context.logger = log.nil_logger()
			on_recv_http_upgrade(conn, 0, {}, {}, net.TCP_Recv_Error(.Connection_Closed))
			context.logger = previous_logger
		// on_recv_http_upgrade frees the temporary connection immediately on recv error.
		// Do not touch conn after this point; Odin's test allocator catches leaks.

		case .EOF:
			conn_owned = false
			previous_logger := context.logger
			context.logger = log.nil_logger()
			on_recv_http_upgrade(conn, 0, {}, {}, nil)
			context.logger = previous_logger
			for tick_index := 0; tick_index < 8; tick_index += 1 {
				terr := nbio.tick(&td.io, time.Millisecond)
				testing.expectf(t, terr == .NONE, "case %d (%s) close tick should succeed", case_index, test_case.name)
			}
		// http_upgrade_close frees the temporary connection from the close callback.
		// Do not touch conn after draining close completion.

		case .Oversize:
			extra: [16]byte
			for i in 0 ..< len(extra) {
				extra[i] = 'B'
			}
			conn_owned = false
			previous_logger := context.logger
			context.logger = log.nil_logger()
			http_upgrade_process_received(conn, len(extra), extra[:])
			context.logger = previous_logger
		// The oversized continuation path closes the socket and frees conn immediately.
		// Do not touch conn after this point; leak detection covers http_remainder_buf.
		}
	}
}

@(test)
test_http_upgrade_accepts_request_split_inside_sec_websocket_key :: proc(t: ^testing.T) {
	sync.mutex_lock(&http_upgrade_receive_test_mu)
	defer sync.mutex_unlock(&http_upgrade_receive_test_mu)

	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)

	WORKER_COUNT :: 2
	old_thread_count := thread_count
	old_bot_secret := bot_auth_secret
	thread_count = WORKER_COUNT
	bot_auth_secret = "upgrade-route-secret"
	defer {
		thread_count = old_thread_count
		bot_auth_secret = old_bot_secret
	}

	queues: [WORKER_COUNT]Pending_Connection_Queue
	for worker_index in 0 ..< WORKER_COUNT {
		queue, queue_err := pending_queue_create(2)
		testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
		if queue_err != .None {
			for cleanup_index in 0 ..< worker_index {
				pending_queue_destroy(queues[cleanup_index])
			}
			return
		}
		queues[worker_index] = queue
	}
	defer for queue in queues do pending_queue_destroy(queue)

	pending_queues := make([]Pending_Connection_Queue, WORKER_COUNT)
	defer delete(pending_queues)
	for worker_index in 0 ..< WORKER_COUNT {
		pending_queues[worker_index] = queues[worker_index]
	}

	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok {
		return
	}
	defer net.close(listen_sock)
	defer net.close(client_sock)
	// accepted_sock is handed to the pending queue on success and closed below.

	conn := new(HTTP_Upgrade_Connection)
	conn.server = &server
	conn.sock = accepted_sock
	conn.state = .New

	workspace_id := "split_key_workspace"
	username := "split-key-bot"
	request := fmt.tprintf(
		"GET /%s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: %s\r\n\r\n",
		workspace_id,
		username,
	)
	key_prefix := "Sec-WebSocket-Key: "
	key_start := strings.index(request, key_prefix)
	testing.expect(t, key_start >= 0, "split request should contain Sec-WebSocket-Key")
	if key_start < 0 do return
	write1 := key_start + len(key_prefix) + 4
	write2 := 5
	testing.expect(t, len(request) > write1 + write2, "split request should be long enough")

	buf: [nbio.BUFFER_SIZE]byte
	copy(buf[:write1], request[:write1])
	result := http_upgrade_process_received(conn, write1, buf[:write1])
	testing.expect_value(t, result, HTTP_Upgrade_Recv_Result.Need_More)
	testing.expect(t, conn.http_remainder_buf != nil, "first split should allocate HTTP remainder")
	testing.expect_value(t, conn.http_received, write1)
	for worker_index in 0 ..< WORKER_COUNT {
		_, pending_ok := pending_queue_try_recv(queues[worker_index])
		testing.expect(t, !pending_ok, "partial split 1 should not enqueue handoff")
	}

	copy(buf[:write2], request[write1:write1 + write2])
	result = http_upgrade_process_received(conn, write2, buf[:write2])
	testing.expect_value(t, result, HTTP_Upgrade_Recv_Result.Need_More)
	testing.expect_value(t, conn.http_received, write1 + write2)
	for worker_index in 0 ..< WORKER_COUNT {
		_, pending_ok := pending_queue_try_recv(queues[worker_index])
		testing.expect(t, !pending_ok, "partial split 2 should not enqueue handoff")
	}

	remaining := len(request) - write1 - write2
	copy(buf[:remaining], request[write1 + write2:])
	result = http_upgrade_process_received(conn, remaining, buf[:remaining])
	testing.expect_value(t, result, HTTP_Upgrade_Recv_Result.Done)

	expected_worker := http_upgrade_target_worker_index(workspace_id, WORKER_COUNT)
	for worker_index in 0 ..< WORKER_COUNT {
		pending, pending_ok := pending_queue_try_recv(queues[worker_index])
		if worker_index == expected_worker {
			testing.expect(t, pending_ok, "split request should enqueue on expected worker")
			if pending_ok {
				testing.expect(t, pending.upgrade == conn, "split request should transfer the exact HTTP upgrade state")
				testing.expect_value(t, pending.upgrade.sock, accepted_sock)
				testing.expect_value(t, pending.upgrade.target_worker_index, expected_worker)
				testing.expect(
					t,
					string(pending.upgrade.http_remainder_buf[:pending.upgrade.http_header_end]) == request,
					"worker should receive the complete request",
				)
				net.close(pending.upgrade.sock)
				http_temp_connection_free(pending.upgrade)
			}
		} else {
			testing.expect(t, !pending_ok, "split request should not enqueue on non-target worker")
			if pending_ok {
				net.close(pending.upgrade.sock)
				http_temp_connection_free(pending.upgrade)
			}
		}
	}
}

@(test)
test_http_upgrade_trailing_allocation_failure_releases_owned_handoff_state :: proc(t: ^testing.T) {
	sync.mutex_lock(&http_upgrade_receive_test_mu)
	defer sync.mutex_unlock(&http_upgrade_receive_test_mu)

	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE do return
	defer nbio.destroy(&td.io)

	old_thread_count := thread_count
	old_bot_secret := bot_auth_secret
	thread_count = 1
	bot_auth_secret = "upgrade-route-secret"
	defer {
		thread_count = old_thread_count
		bot_auth_secret = old_bot_secret
	}

	queue, queue_err := pending_queue_create(1)
	testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
	if queue_err != .None do return
	defer pending_queue_destroy(queue)
	pending_queues := make([]Pending_Connection_Queue, 1)
	defer delete(pending_queues)
	pending_queues[0] = queue
	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}

	listen_sock, client_sock, accepted_sock, pair_ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !pair_ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	request := "GET /trailing-failure-workspace HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: trailing-failure-user\r\n\r\n"
	TRAILING_SIZE :: 37
	buf: [nbio.BUFFER_SIZE]byte
	copy(buf[:], request)
	for byte_index in len(request) ..< len(request) + TRAILING_SIZE {
		buf[byte_index] = 0x5a
	}
	conn := new(HTTP_Upgrade_Connection)
	conn.server = &server
	conn.sock = accepted_sock
	conn.state = .New

	backing_allocator := context.allocator
	fail_state := HTTP_Upgrade_Fail_Size_Allocator {
		backing   = backing_allocator,
		fail_size = len(request) + TRAILING_SIZE,
	}
	context.allocator = runtime.Allocator {
		procedure = http_upgrade_fail_size_allocator_proc,
		data      = &fail_state,
	}
	previous_logger := context.logger
	context.logger = log.nil_logger()
	result := http_upgrade_process_received(conn, len(request) + TRAILING_SIZE, buf[:])
	context.logger = previous_logger
	context.allocator = backing_allocator
	testing.expect_value(t, result, HTTP_Upgrade_Recv_Result.Done)

	// Preparation failure must leave the sole queue slot available.
	testing.expect(t, pending_queue_can_send(queue), "allocation failure should preserve capacity")
	testing.expect(t, pending_queue_try_send(queue, {}), "the sole slot should still accept an item")
	testing.expect(t, !pending_queue_try_send(queue, {}), "capacity must remain exactly one")
	_, fixture_ok := pending_queue_try_recv(queue)
	testing.expect(t, fixture_ok, "capacity fixture should dequeue")

	response_buf: [512]byte
	retry_status := "HTTP/1.1 503 Service Unavailable"
	response_len := fast_ack_test_recv_until(t, client_sock, response_buf[:], len(retry_status), time.Second, &td.io)
	testing.expect(t, response_len >= len(retry_status), "trailing allocation failure should send HTTP 503")
	for _ in 0 ..< 8 {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, "nbio.tick should drain trailing-allocation failure close")
	}
	_, pending_ok := pending_queue_try_recv(queue)
	testing.expect(t, !pending_ok, "trailing allocation failure must not enqueue a handoff")
}

@(test)
test_upgrade_queue_full_error_send_failure_cleans_owned_fields :: proc(t: ^testing.T) {
	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE do return
	defer nbio.destroy(&td.io)

	queue, queue_err := pending_queue_create(1)
	testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
	if queue_err != .None do return
	defer pending_queue_destroy(queue)
	existing_upgrade := HTTP_Upgrade_Connection {
		sock = connection_test_fake_socket(55),
	}
	existing := Pending_Connection {
		upgrade = &existing_upgrade,
	}
	testing.expect(t, pending_queue_try_send(queue, existing), "queue-full fixture should consume admission")

	pending_queues := make([]Pending_Connection_Queue, 1)
	defer delete(pending_queues)
	pending_queues[0] = queue
	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}
	listen_sock, client_sock, accepted_sock, pair_ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !pair_ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	conn := new(HTTP_Upgrade_Connection)
	conn.server = &server
	conn.sock = accepted_sock
	conn.state = .New
	conn.workspace_id = strings.clone("queue-full-owned-workspace")
	conn.verified_username = strings.clone("queue-full-owned-user")
	conn.http_remainder_buf = make([]byte, 9)
	conn.target_worker_index = 0
	on_retry_error_send(conn, 0, net.TCP_Send_Error(.Connection_Closed))
	for _ in 0 ..< 8 {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, "nbio.tick should drain failed error-response close")
	}

	preserved, preserved_ok := pending_queue_try_recv(queue)
	testing.expect(t, preserved_ok, "failed queue-full response must preserve the existing pending item")
	if preserved_ok do testing.expect(t, preserved.upgrade == existing.upgrade, "queue-full response should preserve queued upgrade ownership")
	testing.expect(t, pending_queue_can_send(queue), "dequeue should restore capacity")
	testing.expect(t, pending_queue_try_send(queue, existing), "the sole slot should accept another item")
	testing.expect(t, !pending_queue_try_send(queue, existing), "failed error response must not increase capacity")
	_, fixture_ok := pending_queue_try_recv(queue)
	testing.expect(t, fixture_ok, "capacity fixture should dequeue")
}

@(test)
test_pending_connection_commit_signals_worker_wake :: proc(t: ^testing.T) {
	queue, queue_err := pending_queue_create(1)
	testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
	if queue_err != .None do return
	defer pending_queue_destroy(queue)

	pending := Pending_Connection{}
	testing.expect(t, pending_queue_try_send(queue, pending), "pending connection should enqueue")

	wake_count: u64
	read, read_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, read_err, linux.Errno.NONE)
	testing.expect_value(t, read, size_of(wake_count))
	testing.expect_value(t, wake_count, u64(1))

	_, ok := pending_queue_try_recv(queue)
	testing.expect(t, ok, "wake signaling must not consume the pending connection")
}

@(test)
test_pending_connection_wake_coalesces_burst_and_rearms :: proc(t: ^testing.T) {
	queue, queue_err := pending_queue_create(4)
	testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
	if queue_err != .None do return
	defer pending_queue_destroy(queue)

	for _ in 0 ..< 4 {
		pending := Pending_Connection{}
		testing.expect(t, pending_queue_try_send(queue, pending), "burst pending connection should enqueue")
	}

	wake_count: u64
	read, read_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, read_err, linux.Errno.NONE)
	testing.expect_value(t, read, size_of(wake_count))
	testing.expect_value(t, wake_count, u64(1))

	_, empty_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, empty_err, linux.Errno.EAGAIN)

	for _ in 0 ..< 4 {
		_, ok := pending_queue_try_recv(queue)
		testing.expect(t, ok, "all coalesced burst connections should remain queued")
	}
	pending_queue_rearm_wake(queue)
	_, drained_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, drained_err, linux.Errno.EAGAIN)

	next := Pending_Connection{}
	testing.expect(t, pending_queue_try_send(queue, next), "next burst should enqueue after rearm")
	_, next_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, next_err, linux.Errno.NONE)
	testing.expect_value(t, wake_count, u64(1))
	_, _ = pending_queue_try_recv(queue)
}

@(test)
test_pending_connection_rearm_recovers_publish_covered_by_old_wake :: proc(t: ^testing.T) {
	queue, queue_err := pending_queue_create(2)
	testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
	if queue_err != .None do return
	defer pending_queue_destroy(queue)

	first := Pending_Connection{}
	testing.expect(t, pending_queue_try_send(queue, first), "first pending connection should enqueue")
	wake_count: u64
	_, first_wake_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, first_wake_err, linux.Errno.NONE)

	// Simulate a producer publishing after ppoll drained the eventfd but before
	// the worker cleared the old wake state. This commit must be recovered by
	// the worker's clear-then-check rearm sequence.
	second := Pending_Connection{}
	testing.expect(t, pending_queue_try_send(queue, second), "covered pending connection should enqueue")
	_, covered_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, covered_err, linux.Errno.EAGAIN)

	pending_queue_rearm_wake(queue)
	_, recovered_err := linux.read(queue.wake_fd, ([^]byte)(&wake_count)[:size_of(wake_count)])
	testing.expect_value(t, recovered_err, linux.Errno.NONE)
	testing.expect_value(t, wake_count, u64(1))

	_, first_ok := pending_queue_try_recv(queue)
	_, second_ok := pending_queue_try_recv(queue)
	testing.expect(t, first_ok && second_ok, "rearm must preserve both pending connections")
}

@(test)
// A saturated queue must reject admission without disturbing its pending item.
test_upgrade_handoff_queue_saturation_rejects_send :: proc(t: ^testing.T) {
	queue, queue_err := pending_queue_create(1)
	testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
	if queue_err != .None {
		return
	}
	defer pending_queue_destroy(queue)

	existing_upgrade := HTTP_Upgrade_Connection {
		sock = connection_test_fake_socket(50),
	}
	existing := Pending_Connection {
		upgrade = &existing_upgrade,
	}
	testing.expect(t, pending_queue_try_send(queue, existing), "setup should fill pending queue")
	testing.expect(t, !pending_queue_can_send(queue), "saturated queue must reject handoff admission")
	testing.expect(t, !pending_queue_try_send(queue, {}), "saturated queue must not overwrite its pending item")

	preserved, preserved_ok := pending_queue_try_recv(queue)
	testing.expect(t, preserved_ok, "saturated handoff should preserve the existing queued item")
	if preserved_ok {
		testing.expect(t, preserved.upgrade == existing.upgrade, "saturated handoff should preserve upgrade ownership")
	}

	_, extra := pending_queue_try_recv(queue)
	testing.expect(t, !extra, "saturated handoff should not enqueue an extra pending connection")
	testing.expect(t, pending_queue_can_send(queue), "dequeue should restore capacity")
	testing.expect(t, pending_queue_can_send(queue), "capacity checks must not consume capacity")
	testing.expect(t, pending_queue_try_send(queue, existing), "send after capacity checks should succeed")
	refilled, refilled_ok := pending_queue_try_recv(queue)
	testing.expect(t, refilled_ok && refilled.upgrade == existing.upgrade, "refill should preserve ownership")
}

@(test)
// Pure upgrade-decision fixture: pins HTTP header parsing, service auth, and
// workspace routing without sockets so future generated tests have a clean target.
test_parse_http_upgrade_decision_service_auth_and_rejections :: proc(t: ^testing.T) {
	secret := "upgrade-route-secret"
	key := "dGhlIHNhbXBsZSBub25jZQ=="

	build_request :: proc(
		workspace: string,
		upgrade_value: string,
		key_value: string,
		version_value: string,
		user_type: string,
		service_secret: string,
		nickname: string,
		lowercase_headers := false,
	) -> string {
		upgrade_header := "Upgrade"
		connection_header := "Connection"
		key_header := "Sec-WebSocket-Key"
		version_header := "Sec-WebSocket-Version"
		user_type_header := "X-NRC-User-Type"
		secret_header := "X-NRC-Bot-Secret"
		nickname_header := "X-NRC-Bot-Nickname"
		if lowercase_headers {
			upgrade_header = "upgrade"
			connection_header = "connection"
			key_header = "sec-websocket-key"
			version_header = "sec-websocket-version"
			user_type_header = "x-nrc-user-type"
			secret_header = "x-nrc-bot-secret"
			nickname_header = "x-nrc-bot-nickname"
		}

		upgrade_line := ""
		if upgrade_value != "" do upgrade_line = fmt.tprintf("%s: %s\r\n", upgrade_header, upgrade_value)
		key_line := ""
		if key_value != "" do key_line = fmt.tprintf("%s: %s\r\n", key_header, key_value)
		version_line := ""
		if version_value != "" do version_line = fmt.tprintf("%s: %s\r\n", version_header, version_value)
		user_type_line := ""
		if user_type != "" do user_type_line = fmt.tprintf("%s: %s\r\n", user_type_header, user_type)
		secret_line := ""
		if service_secret != "" do secret_line = fmt.tprintf("%s: %s\r\n", secret_header, service_secret)
		nickname_line := ""
		if nickname != "" do nickname_line = fmt.tprintf("%s: %s\r\n", nickname_header, nickname)

		return fmt.tprintf(
			"GET /%s HTTP/1.1\r\nHost: localhost\r\n%s%s: Upgrade\r\n%s%s%s%s%s\r\n",
			workspace,
			upgrade_line,
			connection_header,
			key_line,
			version_line,
			user_type_line,
			secret_line,
			nickname_line,
		)
	}

	user_type_cases := [?]struct {
		header: string,
		parsed: pr.User_Type,
	}{{header = "bot", parsed = .Bot}, {header = "system", parsed = .System}, {header = "admin", parsed = .Admin}}
	for user_type_case in user_type_cases {
		request := build_request("decision_workspace", "websocket", key, "13", user_type_case.header, secret, "decision-bot")
		decision := parse_http_upgrade_decision(request, secret, 5)
		testing.expect_value(t, decision.kind, HTTP_Upgrade_Decision_Kind.Accept)
		testing.expect(t, decision.workspace_id == "decision_workspace", "accepted decision should expose parsed workspace")
		testing.expect(t, decision.sec_websocket_key == key, "accepted decision should expose parsed websocket key")
		testing.expect_value(t, decision.target_worker_index, http_upgrade_target_worker_index("decision_workspace", 5))
		testing.expect(t, decision.verified_username == "decision-bot", "accepted service decision should expose nickname identity")
		testing.expect_value(t, decision.user_type, user_type_case.parsed)
		testing.expect_value(t, decision.authenticated, true)
	}

	worker_count_cases := [?]int{1, 2, 16}
	for worker_count in worker_count_cases {
		request := build_request("decision_worker_edge", "websocket", key, "13", "bot", secret, "decision-bot")
		decision := parse_http_upgrade_decision(request, secret, worker_count)
		testing.expect_value(t, decision.kind, HTTP_Upgrade_Decision_Kind.Accept)
		testing.expect(t, decision.target_worker_index >= 0 && decision.target_worker_index < worker_count, "worker edge target should stay in range")
		testing.expect_value(t, decision.target_worker_index, http_upgrade_target_worker_index("decision_worker_edge", worker_count))
	}

	header_case_variant := build_request("decision_workspace", "websocket", key, "13", "BOT", secret, "decision-bot", true)
	case_decision := parse_http_upgrade_decision(header_case_variant, secret, 5)
	testing.expect_value(t, case_decision.kind, HTTP_Upgrade_Decision_Kind.Accept)
	testing.expect_value(t, case_decision.user_type, pr.User_Type.Bot)
	testing.expect(t, case_decision.verified_username == "decision-bot", "header casing should not change service identity")

	tab_ows_request := "GET /decision_workspace HTTP/1.1\r\nuPgRaDe:\twebsocket\t\r\nsEc-WeBsOcKeT-kEy:\tdGhlIHNhbXBsZSBub25jZQ==\t\r\nSeC-wEbSoCkEt-VeRsIoN:\t13\r\nx-NrC-uSeR-tYpE:\tBoT\r\nX-nRc-BoT-sEcReT:\tupgrade-route-secret\r\nx-NrC-bOt-NiCkNaMe:\tdecision-bot\t\r\n\r\n"
	tab_ows_decision := parse_http_upgrade_decision(tab_ows_request, secret, 5)
	testing.expect_value(t, tab_ows_decision.kind, HTTP_Upgrade_Decision_Kind.Accept)
	testing.expect_value(t, tab_ows_decision.user_type, pr.User_Type.Bot)
	testing.expect(t, tab_ows_decision.verified_username == "decision-bot", "ASCII parser should trim HTTP space and tab OWS")

	non_ascii_header_request := "GET /decision_workspace HTTP/1.1\r\nUpgrade: websocket\r\nſec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: decision-bot\r\n\r\n"
	non_ascii_header_decision := parse_http_upgrade_decision(non_ascii_header_request, secret, 5)
	testing.expect_value(t, non_ascii_header_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Handshake)
	testing.expect_value(t, non_ascii_header_decision.key_present, false)

	missing_workspace_decision := parse_http_upgrade_decision(build_request("", "websocket", key, "13", "bot", secret, "decision-bot"), secret, 5)
	testing.expect_value(t, missing_workspace_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Handshake)
	testing.expect_value(t, missing_workspace_decision.workspace_present, false)

	missing_upgrade_decision := parse_http_upgrade_decision(build_request("decision_workspace", "", key, "13", "bot", secret, "decision-bot"), secret, 5)
	testing.expect_value(t, missing_upgrade_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Handshake)
	testing.expect_value(t, missing_upgrade_decision.upgrade_present, false)

	missing_key_decision := parse_http_upgrade_decision(build_request("decision_workspace", "websocket", "", "13", "bot", secret, "decision-bot"), secret, 5)
	testing.expect_value(t, missing_key_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Handshake)
	testing.expect_value(t, missing_key_decision.key_present, false)
	testing.expect_value(t, missing_key_decision.upgrade_present, true)
	testing.expect_value(t, missing_key_decision.workspace_present, true)

	missing_version_decision := parse_http_upgrade_decision(
		build_request("decision_workspace", "websocket", key, "", "bot", secret, "decision-bot"),
		secret,
		5,
	)
	testing.expect_value(t, missing_version_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Handshake)
	testing.expect(t, missing_version_decision.version == "", "missing version should be exposed for logging")

	invalid_user_type_decision := parse_http_upgrade_decision(
		build_request("decision_workspace", "websocket", key, "13", "robot", secret, "decision-bot"),
		secret,
		5,
	)
	testing.expect_value(t, invalid_user_type_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Auth)
	testing.expect_value(t, invalid_user_type_decision.authenticated, false)
	testing.expect_value(t, invalid_user_type_decision.user_type, pr.User_Type.User)

	wrong_secret_decision := parse_http_upgrade_decision(
		build_request("decision_workspace", "websocket", key, "13", "bot", "wrong-secret", "decision-bot"),
		secret,
		5,
	)
	testing.expect_value(t, wrong_secret_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Auth)
	testing.expect_value(t, wrong_secret_decision.authenticated, false)
	testing.expect_value(t, wrong_secret_decision.user_type, pr.User_Type.User)

	missing_secret_decision := parse_http_upgrade_decision(build_request("decision_workspace", "websocket", key, "13", "bot", "", "decision-bot"), secret, 5)
	testing.expect_value(t, missing_secret_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Auth)
	testing.expect_value(t, missing_secret_decision.authenticated, false)
	testing.expect_value(t, missing_secret_decision.user_type, pr.User_Type.User)

	bad_nickname_decision := parse_http_upgrade_decision(build_request("decision_workspace", "websocket", key, "13", "bot", secret, "bad nickname"), secret, 5)
	testing.expect_value(t, bad_nickname_decision.kind, HTTP_Upgrade_Decision_Kind.Reject_Auth)
	testing.expect_value(t, bad_nickname_decision.authenticated, false)
}

@(test)
// Generated pure upgrade-decision property: varies handshake fields, service
// auth headers, casing, and worker counts without socket/global-I/O state.
test_hegel_parse_http_upgrade_decision_service_auth_invariants :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_http_upgrade_decision_service_auth_invariants, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "hegel HTTP upgrade decision property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_http_upgrade_decision_service_auth_invariants :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	worker_count_raw, worker_err := hgl.draw_i64(tc, 1, 16)
	if worker_err == .Stop_Test do return hgl.abort()
	if worker_err != nil do return hgl.interesting("draw worker count")
	worker_count := int(worker_count_raw)

	workspace_choice, workspace_err := hgl.draw_i64(tc, 0, 2)
	if workspace_err == .Stop_Test do return hgl.abort()
	if workspace_err != nil do return hgl.interesting("draw workspace choice")
	upgrade_choice, upgrade_err := hgl.draw_i64(tc, 0, 2)
	if upgrade_err == .Stop_Test do return hgl.abort()
	if upgrade_err != nil do return hgl.interesting("draw upgrade choice")
	key_choice, key_err := hgl.draw_i64(tc, 0, 2)
	if key_err == .Stop_Test do return hgl.abort()
	if key_err != nil do return hgl.interesting("draw key choice")
	version_choice, version_err := hgl.draw_i64(tc, 0, 2)
	if version_err == .Stop_Test do return hgl.abort()
	if version_err != nil do return hgl.interesting("draw version choice")
	secret_choice, secret_err := hgl.draw_i64(tc, 0, 2)
	if secret_err == .Stop_Test do return hgl.abort()
	if secret_err != nil do return hgl.interesting("draw secret choice")
	nickname_choice, nickname_err := hgl.draw_i64(tc, 0, 2)
	if nickname_err == .Stop_Test do return hgl.abort()
	if nickname_err != nil do return hgl.interesting("draw nickname choice")
	case_choice, case_err := hgl.draw_i64(tc, 0, 1)
	if case_err == .Stop_Test do return hgl.abort()
	if case_err != nil do return hgl.interesting("draw header case")

	workspace := ""
	if workspace_choice == 1 {
		workspace = "hegel_upgrade_workspace"
	} else if workspace_choice == 2 {
		workspace = "hegel_upgrade_workspace_extra"
	}

	upgrade_value := ""
	if upgrade_choice == 1 {
		upgrade_value = "websocket"
	} else if upgrade_choice == 2 {
		upgrade_value = "not-websocket"
	}

	key_value := ""
	if key_choice == 1 {
		key_value = "dGhlIHNhbXBsZSBub25jZQ=="
	} else if key_choice == 2 {
		key_value = "short"
	}

	version_value := ""
	if version_choice == 1 {
		version_value = "13"
	} else if version_choice == 2 {
		version_value = "12"
	}

	secret_header := ""
	if secret_choice == 1 {
		secret_header = "upgrade-route-secret"
	} else if secret_choice == 2 {
		secret_header = "wrong-secret"
	}

	nickname := ""
	if nickname_choice == 1 {
		nickname = "hegel-bot"
	} else if nickname_choice == 2 {
		nickname = "bad nickname"
	}

	upgrade_header := "Upgrade"
	version_header := "Sec-WebSocket-Version"
	key_header := "Sec-WebSocket-Key"
	user_type_header := "X-NRC-User-Type"
	secret_name_header := "X-NRC-Bot-Secret"
	nickname_header := "X-NRC-Bot-Nickname"
	if case_choice == 1 {
		upgrade_header = "upgrade"
		version_header = "sec-websocket-version"
		key_header = "sec-websocket-key"
		user_type_header = "x-nrc-user-type"
		secret_name_header = "x-nrc-bot-secret"
		nickname_header = "x-nrc-bot-nickname"
	}

	request := fmt.tprintf(
		"GET /%s HTTP/1.1\r\nHost: localhost\r\n%s: %s\r\nConnection: Upgrade\r\n%s: %s\r\n%s: %s\r\n%s: bot\r\n%s: %s\r\n%s: %s\r\n\r\n",
		workspace,
		upgrade_header,
		upgrade_value,
		key_header,
		key_value,
		version_header,
		version_value,
		user_type_header,
		secret_name_header,
		secret_header,
		nickname_header,
		nickname,
	)
	decision := parse_http_upgrade_decision(request, "upgrade-route-secret", worker_count)

	valid_handshake := workspace != "" && upgrade_value == "websocket" && key_value != "" && version_value == "13"
	valid_service := secret_header == "upgrade-route-secret" && nickname == "hegel-bot"
	if !valid_handshake {
		if decision.kind != .Reject_Handshake {
			return hgl.interesting("invalid handshake accepted or auth-rejected")
		}
		return hgl.valid()
	}

	if !valid_service {
		if decision.kind != .Reject_Auth {
			return hgl.interesting("invalid service auth accepted")
		}
		if decision.authenticated {
			return hgl.interesting("invalid service auth marked authenticated")
		}
		return hgl.valid()
	}

	if decision.kind != .Accept {
		return hgl.interesting("valid service upgrade rejected")
	}
	if decision.target_worker_index < 0 || decision.target_worker_index >= worker_count {
		return hgl.interesting("target worker out of range")
	}
	if decision.target_worker_index != http_upgrade_target_worker_index(workspace, worker_count) {
		return hgl.interesting("target worker mismatch")
	}
	if decision.workspace_id != workspace || decision.verified_username != nickname || decision.user_type != .Bot || !decision.authenticated {
		return hgl.interesting("accepted service identity mismatch")
	}

	return hgl.valid()
}

@(test)
// Receive-side happy-path integration fixture: sends real HTTP upgrade requests
// through on_recv_http_upgrade so production parsing, service auth, workspace
// hash routing, send completion, and pending-queue handoff are checked together.
test_http_upgrade_receive_routes_to_expected_worker_queue :: proc(t: ^testing.T) {
	sync.mutex_lock(&http_upgrade_receive_test_mu)
	defer sync.mutex_unlock(&http_upgrade_receive_test_mu)

	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)

	WORKER_COUNT :: 4
	WORKSPACES := [?]string {
		"upgrade_route_alpha",
		"upgrade_route_beta",
		"upgrade_route_gamma",
		"upgrade_route_delta",
		"upgrade_route_epsilon",
		"upgrade_route_zeta",
		"upgrade_route_eta",
		"upgrade_route_theta",
	}

	old_thread_count := thread_count
	old_bot_secret := bot_auth_secret
	thread_count = WORKER_COUNT
	bot_auth_secret = "upgrade-route-secret"
	defer {
		thread_count = old_thread_count
		bot_auth_secret = old_bot_secret
	}

	queues: [WORKER_COUNT]Pending_Connection_Queue
	for worker_index in 0 ..< WORKER_COUNT {
		queue, queue_err := pending_queue_create(len(WORKSPACES))
		testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
		if queue_err != .None {
			for cleanup_index in 0 ..< worker_index {
				pending_queue_destroy(queues[cleanup_index])
			}
			return
		}
		queues[worker_index] = queue
	}
	defer for queue in queues do pending_queue_destroy(queue)

	pending_queues := make([]Pending_Connection_Queue, WORKER_COUNT)
	defer delete(pending_queues)
	for worker_index in 0 ..< WORKER_COUNT {
		pending_queues[worker_index] = queues[worker_index]
	}

	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}

	for workspace_id, i in WORKSPACES {
		listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
		if !ok {
			return
		}
		defer net.close(listen_sock)
		defer net.close(client_sock)
		// accepted_sock is handed to the pending queue on success and closed below.

		conn := new(HTTP_Upgrade_Connection)
		conn.server = &server
		conn.sock = accepted_sock
		conn.state = .New

		username := fmt.tprintf("route-bot-%02d", i)
		request := fmt.tprintf(
			"GET /%s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: %s\r\n\r\n",
			workspace_id,
			username,
		)

		// Coalesce a masked first binary frame with the HTTP request. HTTP upgrade
		// handling must transfer these bytes intact to the selected worker queue.
		first_payload := [?]byte{0x10, 0x20, 0x30, 0x40}
		first_frame := make_test_ws_frame(first_payload[:], .opBinary, true)
		defer delete(first_frame)
		buf: [nbio.BUFFER_SIZE]byte
		copy(buf[:], request)
		copy(buf[len(request):], first_frame)
		on_recv_http_upgrade(conn, len(request) + len(first_frame), buf[:], {}, nil)
		// nbio recycles this provided receive buffer immediately after the callback.
		// Simulate reuse before the asynchronous 101 send completion hands off.
		for byte_index in 0 ..< len(request) {
			buf[byte_index] = '#'
		}

		expected_worker := http_upgrade_target_worker_index(workspace_id, WORKER_COUNT)
		for worker_index in 0 ..< WORKER_COUNT {
			pending, pending_ok := pending_queue_try_recv(queues[worker_index])
			if worker_index == expected_worker {
				testing.expect(t, pending_ok, "expected worker queue should receive upgrade handoff")
				if pending_ok {
					testing.expect(t, pending.upgrade == conn, "main thread should transfer the exact HTTP upgrade state")
					testing.expect_value(t, pending.upgrade.sock, accepted_sock)
					testing.expect_value(t, pending.upgrade.target_worker_index, expected_worker)
					testing.expect(
						t,
						string(pending.upgrade.http_remainder_buf[pending.upgrade.http_header_end:pending.upgrade.http_received]) == string(first_frame),
						"coalesced first WebSocket frame should remain in worker-owned request storage",
					)
					testing.expect(
						t,
						strings.contains(string(pending.upgrade.http_remainder_buf[:pending.upgrade.http_header_end]), username),
						"worker-owned request should survive provided-buffer reuse",
					)
					net.close(pending.upgrade.sock)
					http_temp_connection_free(pending.upgrade)
				}
			} else {
				testing.expect(t, !pending_ok, "non-target worker queue should not receive upgrade handoff")
				if pending_ok {
					net.close(pending.upgrade.sock)
					http_temp_connection_free(pending.upgrade)
				}
			}
		}
	}
}

@(test)
// JWT validation allocates the verified username. A successful handoff must
// transfer that allocation rather than clone it and leak the original.
test_http_upgrade_jwt_username_ownership_transfers_to_handoff :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)
	sync.mutex_lock(&http_upgrade_receive_test_mu)
	defer sync.mutex_unlock(&http_upgrade_receive_test_mu)

	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE do return
	defer nbio.destroy(&td.io)

	old_thread_count := thread_count
	old_jwt_secret := jwt_auth_secret
	old_jwt_issuer := jwt_expected_issuer
	old_jwt_audience := jwt_expected_audience
	thread_count = 1
	jwt_auth_secret = "upgrade-jwt-lifetime-secret"
	jwt_expected_issuer = "nrc-proxy"
	jwt_expected_audience = "nrc"
	defer {
		thread_count = old_thread_count
		jwt_auth_secret = old_jwt_secret
		jwt_expected_issuer = old_jwt_issuer
		jwt_expected_audience = old_jwt_audience
	}

	queue, queue_err := pending_queue_create(1)
	testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
	if queue_err != .None do return
	defer pending_queue_destroy(queue)
	pending_queues := make([]Pending_Connection_Queue, 1)
	defer delete(pending_queues)
	pending_queues[0] = queue
	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}

	listen_sock, client_sock, accepted_sock, pair_ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !pair_ok do return
	defer net.close(listen_sock)
	defer net.close(client_sock)

	token, token_ok := build_test_jwt(
		`{"sub":"upgrade-user-id","username":"upgrade-jwt-user","iss":"nrc-proxy","aud":"nrc","exp":4102444800,"nbf":1,"user_type":"user"}`,
		jwt_auth_secret,
	)
	testing.expect(t, token_ok, "JWT fixture should build")
	if !token_ok {
		net.close(accepted_sock)
		return
	}
	defer delete(token)

	request := fmt.tprintf(
		"GET /jwt_lifetime_workspace HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-Auth: %s\r\n\r\n",
		token,
	)
	buf: [nbio.BUFFER_SIZE]byte
	copy(buf[:], request)
	conn := new(HTTP_Upgrade_Connection)
	conn.server = &server
	conn.sock = accepted_sock
	conn.state = .New
	on_recv_http_upgrade(conn, len(request), buf[:], {}, nil)
	for byte_index in 0 ..< len(request) {
		buf[byte_index] = '#'
	}

	pending, pending_ok := pending_queue_try_recv(queue)
	testing.expect(t, pending_ok, "JWT upgrade should enqueue worker-owned HTTP state")
	if !pending_ok {
		net.close(accepted_sock)
		return
	}
	defer net.close(pending.upgrade.sock)
	defer http_temp_connection_free(pending.upgrade)
	testing.expect(t, pending.upgrade == conn, "JWT request ownership should transfer without replacing HTTP state")
	testing.expect(t, pending.upgrade.verified_username == "", "main thread must not validate JWT identity")
	testing.expect(
		t,
		strings.contains(string(pending.upgrade.http_remainder_buf[:pending.upgrade.http_header_end]), token),
		"worker-owned request should preserve JWT after receive-buffer reuse",
	)
}

@(test)
// Receive-side queue-full integration fixture: covers the same saturation
// contract as the direct callback test, but via real HTTP receive/auth/routing
// and send-callback plumbing to guard against full-path regressions.
test_http_upgrade_receive_queue_full_preserves_target_queue :: proc(t: ^testing.T) {
	sync.mutex_lock(&http_upgrade_receive_test_mu)
	defer sync.mutex_unlock(&http_upgrade_receive_test_mu)

	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)

	WORKER_COUNT :: 4
	workspace_id := "upgrade_route_queue_full"
	expected_worker := http_upgrade_target_worker_index(workspace_id, WORKER_COUNT)

	old_thread_count := thread_count
	old_bot_secret := bot_auth_secret
	thread_count = WORKER_COUNT
	bot_auth_secret = "upgrade-route-secret"
	defer {
		thread_count = old_thread_count
		bot_auth_secret = old_bot_secret
	}

	queues: [WORKER_COUNT]Pending_Connection_Queue
	for worker_index in 0 ..< WORKER_COUNT {
		queue, queue_err := pending_queue_create(1)
		testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
		if queue_err != .None {
			for cleanup_index in 0 ..< worker_index {
				pending_queue_destroy(queues[cleanup_index])
			}
			return
		}
		queues[worker_index] = queue
	}
	defer for queue in queues do pending_queue_destroy(queue)

	existing_upgrade := HTTP_Upgrade_Connection {
		sock = connection_test_fake_socket(60),
	}
	existing := Pending_Connection {
		upgrade = &existing_upgrade,
	}
	testing.expect(t, pending_queue_try_send(queues[expected_worker], existing), "setup should fill selected worker queue")

	pending_queues := make([]Pending_Connection_Queue, WORKER_COUNT)
	defer delete(pending_queues)
	for worker_index in 0 ..< WORKER_COUNT {
		pending_queues[worker_index] = queues[worker_index]
	}

	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}

	listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
	if !ok {
		return
	}
	defer net.close(listen_sock)
	defer net.close(client_sock)
	// accepted_sock is closed by the receive-side saturated handoff failure path.

	conn := new(HTTP_Upgrade_Connection)
	conn.server = &server
	conn.sock = accepted_sock
	conn.state = .New

	request := fmt.tprintf(
		"GET /%s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: rejected-route-bot\r\n\r\n",
		workspace_id,
	)

	buf: [nbio.BUFFER_SIZE]byte
	copy(buf[:], request)
	on_recv_http_upgrade(conn, len(request), buf[:], {}, nil)

	response_buf: [512]byte
	retry_status := "HTTP/1.1 503 Service Unavailable"
	response_len := fast_ack_test_recv_until(t, client_sock, response_buf[:], len(retry_status), time.Second, &td.io)
	testing.expect(t, response_len >= len(retry_status), "saturated upgrade should receive a complete HTTP 503 status")
	if response_len >= len(retry_status) {
		testing.expect(t, string(response_buf[:len(retry_status)]) == retry_status, "saturated worker queue must be rejected before HTTP 101")
	}
	for i := 0; i < 8; i += 1 {
		terr := nbio.tick(&td.io, time.Millisecond)
		testing.expect(t, terr == .NONE, "nbio.tick should drain saturated receive-side close")
	}

	for worker_index in 0 ..< WORKER_COUNT {
		pending, pending_ok := pending_queue_try_recv(queues[worker_index])
		if worker_index == expected_worker {
			testing.expect(t, pending_ok, "saturated receive-side handoff should preserve target queue item")
			if pending_ok {
				testing.expect(t, pending.upgrade == existing.upgrade, "saturated receive-side handoff should preserve queued ownership")
			}
			_, extra := pending_queue_try_recv(queues[worker_index])
			testing.expect(t, !extra, "saturated receive-side handoff should not enqueue rejected connection")
		} else {
			testing.expect(t, !pending_ok, "saturated receive-side handoff should not enqueue on non-target workers")
			if pending_ok {
				net.close(pending.upgrade.sock)
				http_temp_connection_free(pending.upgrade)
			}
		}
	}
}

@(test)
// Receive-side rejection fixture: malformed or unauthenticated upgrades should
// send the appropriate HTTP error, close the temp connection, and never enqueue
// half-authenticated handoffs into any worker queue.
test_http_upgrade_receive_rejects_bad_requests_without_handoff :: proc(t: ^testing.T) {
	sync.mutex_lock(&http_upgrade_receive_test_mu)
	defer sync.mutex_unlock(&http_upgrade_receive_test_mu)

	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)

	WORKER_COUNT :: 4
	old_thread_count := thread_count
	old_bot_secret := bot_auth_secret
	thread_count = WORKER_COUNT
	bot_auth_secret = "upgrade-route-secret"
	defer {
		thread_count = old_thread_count
		bot_auth_secret = old_bot_secret
	}

	queues: [WORKER_COUNT]Pending_Connection_Queue
	for worker_index in 0 ..< WORKER_COUNT {
		queue, queue_err := pending_queue_create(4)
		testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
		if queue_err != .None {
			for cleanup_index in 0 ..< worker_index {
				pending_queue_destroy(queues[cleanup_index])
			}
			return
		}
		queues[worker_index] = queue
	}
	defer for queue in queues do pending_queue_destroy(queue)

	pending_queues := make([]Pending_Connection_Queue, WORKER_COUNT)
	defer delete(pending_queues)
	for worker_index in 0 ..< WORKER_COUNT {
		pending_queues[worker_index] = queues[worker_index]
	}

	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}

	Request_Case :: struct {
		name:     string,
		request:  string,
		response: string,
	}

	cases := [?]Request_Case {
		{
			name = "missing bot secret falls back to unauthenticated user",
			request = "GET /reject_missing_secret HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Nickname: missing-secret-bot\r\n\r\n",
			response = "HTTP/1.1 401 Unauthorized",
		},
		{
			name = "invalid bot secret falls back to unauthenticated user",
			request = "GET /reject_invalid_secret HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: wrong-secret\r\nX-NRC-Bot-Nickname: invalid-secret-bot\r\n\r\n",
			response = "HTTP/1.1 401 Unauthorized",
		},
		{
			name = "missing workspace path is not a valid websocket handshake",
			request = "GET  HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: missing-workspace-bot\r\n\r\n",
			response = "HTTP/1.1 500 Internal Server Error",
		},
		{
			name = "missing upgrade header is not a valid websocket handshake",
			request = "GET /reject_missing_upgrade HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: missing-upgrade-bot\r\n\r\n",
			response = "HTTP/1.1 500 Internal Server Error",
		},
		{
			name = "missing websocket key is not a valid websocket handshake",
			request = "GET /reject_missing_key HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: missing-key-bot\r\n\r\n",
			response = "HTTP/1.1 500 Internal Server Error",
		},
		{
			name = "wrong websocket version is not a valid websocket handshake",
			request = "GET /reject_wrong_version HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 12\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: wrong-version-bot\r\n\r\n",
			response = "HTTP/1.1 500 Internal Server Error",
		},
		{
			name = "valid secret with invalid service nickname is rejected before handoff",
			request = "GET /reject_bad_nickname HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: bad nickname\r\n\r\n",
			response = "HTTP/1.1 401 Unauthorized",
		},
	}

	for test_case, case_index in cases {
		listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
		if !ok {
			return
		}
		defer net.close(listen_sock)
		defer net.close(client_sock)
		// accepted_sock is closed by the rejection send callback.

		conn := new(HTTP_Upgrade_Connection)
		conn.server = &server
		conn.sock = accepted_sock
		conn.state = .New

		buf: [nbio.BUFFER_SIZE]byte
		copy(buf[:], test_case.request)
		on_recv_http_upgrade(conn, len(test_case.request), buf[:], {}, nil)

		worker_handoff_count := 0
		old_thread_index := td.thread_index
		for worker_index in 0 ..< WORKER_COUNT {
			pending, pending_ok := pending_queue_try_recv(queues[worker_index])
			if pending_ok {
				worker_handoff_count += 1
				td.thread_index = worker_index
				worker_process_http_upgrade(pending.upgrade)
			}
		}
		if strings.contains(test_case.request, "GET  HTTP/1.1") {
			testing.expect_value(t, worker_handoff_count, 0)
		} else {
			testing.expect_value(t, worker_handoff_count, 1)
		}

		response_buf: [512]byte
		response_len := fast_ack_test_recv_until(t, client_sock, response_buf[:], len(test_case.response), time.Second, &td.io)
		testing.expectf(t, response_len >= len(test_case.response), "bad upgrade case %d (%s) should receive an HTTP error", case_index, test_case.name)
		if response_len >= len(test_case.response) {
			actual_prefix := string(response_buf[:len(test_case.response)])
			testing.expectf(
				t,
				actual_prefix == test_case.response,
				"bad upgrade case %d (%s) response prefix mismatch: %s",
				case_index,
				test_case.name,
				actual_prefix,
			)
		}

		for i := 0; i < 8; i += 1 {
			terr := nbio.tick(&td.io, time.Millisecond)
			testing.expect(t, terr == .NONE, "nbio.tick should drain rejected upgrade close")
		}
		td.thread_index = old_thread_index

		for worker_index in 0 ..< WORKER_COUNT {
			_, pending_ok := pending_queue_try_recv(queues[worker_index])
			testing.expectf(t, !pending_ok, "bad upgrade case %d (%s) must not enqueue on worker %d", case_index, test_case.name, worker_index)
		}
	}
}

@(test)
// Receive-side routing sweep fixture: samples many workspace IDs through real
// HTTP parsing/auth/send/handoff and verifies each lands only in the worker
// selected by http_upgrade_target_worker_index.
test_http_upgrade_receive_routes_many_workspaces_to_expected_workers :: proc(t: ^testing.T) {
	sync.mutex_lock(&http_upgrade_receive_test_mu)
	defer sync.mutex_unlock(&http_upgrade_receive_test_mu)

	ierr := nbio.init(&td.io)
	testing.expect(t, ierr == .NONE, "nbio.init should succeed")
	if ierr != .NONE {
		return
	}
	defer nbio.destroy(&td.io)

	WORKER_COUNT :: 6
	WORKSPACE_COUNT :: 48
	old_thread_count := thread_count
	old_bot_secret := bot_auth_secret
	thread_count = WORKER_COUNT
	bot_auth_secret = "upgrade-route-secret"
	defer {
		thread_count = old_thread_count
		bot_auth_secret = old_bot_secret
	}

	queues: [WORKER_COUNT]Pending_Connection_Queue
	for worker_index in 0 ..< WORKER_COUNT {
		queue, queue_err := pending_queue_create(WORKSPACE_COUNT)
		testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
		if queue_err != .None {
			for cleanup_index in 0 ..< worker_index {
				pending_queue_destroy(queues[cleanup_index])
			}
			return
		}
		queues[worker_index] = queue
	}
	defer for queue in queues do pending_queue_destroy(queue)

	pending_queues := make([]Pending_Connection_Queue, WORKER_COUNT)
	defer delete(pending_queues)
	for worker_index in 0 ..< WORKER_COUNT {
		pending_queues[worker_index] = queues[worker_index]
	}

	server := NRC_Server {
		main_thread         = 0,
		pending_connections = pending_queues,
	}

	expected_counts: [WORKER_COUNT]int
	for i in 0 ..< WORKSPACE_COUNT {
		workspace_id := fmt.tprintf("upgrade_route_sweep_%02d", i)
		username := fmt.tprintf("route-sweep-bot-%02d", i)
		expected_worker := http_upgrade_target_worker_index(workspace_id, WORKER_COUNT)
		expected_counts[expected_worker] += 1

		listen_sock, client_sock, accepted_sock, ok := fast_ack_test_accept_loopback_pair(t, &td.io)
		if !ok {
			return
		}
		defer net.close(listen_sock)
		defer net.close(client_sock)
		// accepted_sock is handed to the selected pending queue on success and closed below.

		conn := new(HTTP_Upgrade_Connection)
		conn.server = &server
		conn.sock = accepted_sock
		conn.state = .New

		request := fmt.tprintf(
			"GET /%s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: upgrade-route-secret\r\nX-NRC-Bot-Nickname: %s\r\n\r\n",
			workspace_id,
			username,
		)

		buf: [nbio.BUFFER_SIZE]byte
		copy(buf[:], request)
		on_recv_http_upgrade(conn, len(request), buf[:], {}, nil)
	}

	seen: [WORKSPACE_COUNT]bool
	for worker_index in 0 ..< WORKER_COUNT {
		actual_count := 0
		for {
			pending, pending_ok := pending_queue_try_recv(queues[worker_index])
			if !pending_ok {
				break
			}
			actual_count += 1
			decision := parse_http_upgrade_decision(
				string(pending.upgrade.http_remainder_buf[:pending.upgrade.http_header_end]),
				bot_auth_secret,
				WORKER_COUNT,
			)
			testing.expect_value(t, decision.kind, HTTP_Upgrade_Decision_Kind.Accept)

			matched := false
			for i in 0 ..< WORKSPACE_COUNT {
				workspace_id := fmt.tprintf("upgrade_route_sweep_%02d", i)
				username := fmt.tprintf("route-sweep-bot-%02d", i)
				expected_worker := http_upgrade_target_worker_index(workspace_id, WORKER_COUNT)
				if decision.workspace_id == workspace_id {
					matched = true
					testing.expect_value(t, worker_index, expected_worker)
					testing.expect(t, !seen[i], "routing sweep should not duplicate a workspace handoff")
					seen[i] = true
					testing.expect(t, decision.verified_username == username, "worker parser should preserve service identity")
					testing.expect_value(t, decision.target_worker_index, expected_worker)
					testing.expect_value(t, decision.user_type, pr.User_Type.Bot)
					testing.expect_value(t, decision.authenticated, true)
					break
				}
			}

			testing.expect(t, matched, "routing sweep pending workspace should come from the generated request set")
			net.close(pending.upgrade.sock)
			http_temp_connection_free(pending.upgrade)
		}
		testing.expect_value(t, actual_count, expected_counts[worker_index])
	}

	for seen_workspace, i in seen {
		testing.expectf(t, seen_workspace, "routing sweep workspace %d should be handed off exactly once", i)
	}
}
