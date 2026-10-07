//
// websocket_handler.odin - WebSocket Message Processing
//
// This file handles WebSocket frame processing and protocol operations including:
// - Receiving and parsing WebSocket frames from clients
// - Protocol message dispatching and opcode handling
// - WebSocket flow control and send rate limiting
// - WebSocket close frame generation and transmission
// - Buffer overflow protection and connection state management
//
package main

import "base:intrinsics"
import "core:container/queue"
import "core:log"
import "core:net"
import "core:sync"

import "byte_pool"
import nbio "nbio/poly"
import pr "protocol"
import ws "websocket"

// Maximum allowed frame size (128KB) - prevents memory exhaustion attacks
MAX_FRAME_SIZE :: 131072
// Maximum allowed protocol payload size (bytes), excluding WebSocket frame header
MAX_PROTOCOL_PAYLOAD_SIZE :: 131072

// Helper function to create binary WebSocket frame header
create_binary_header :: proc(payload_len: u64) -> ws.header {
	return ws.header {
		fin           = true,
		opcode        = .opBinary,
		payloadLength = payload_len,
		mask          = false, // Server doesn't mask
	}
}

// Helper function to create close WebSocket frame header
create_close_header :: proc(payload_len: u64) -> ws.header {
	return ws.header {
		fin           = true,
		opcode        = .opClose,
		payloadLength = payload_len,
		mask          = false, // Server doesn't mask
	}
}

// Calculate WebSocket header size based on payload length
// Returns the number of bytes needed for the WebSocket frame header
get_ws_header_size :: proc(payload_len: int) -> int {
	if payload_len > 65535 do return 10 // 2 bytes base + 8 bytes for u64 length
	if payload_len > 125 do return 4 // 2 bytes base + 2 bytes for u16 length
	return 2 // Just 2 bytes for small payloads
}

get_ws_received_header_size :: proc(h: ws.header) -> int {
	size := get_ws_header_size(int(h.payloadLength))
	if h.mask {
		size += 4
	}
	return size
}

// Allocates buffer and writes WebSocket header, ready for protocol serialization
// Returns (buffer, header_len) where protocol data should be written at buf[header_len:]
// Returns (nil, 0) on allocation failure
allocate_websocket_frame_buffer :: proc(protocol_size: int, error_context: string) -> ([]u8, int) {
	if protocol_size > MAX_PROTOCOL_PAYLOAD_SIZE {
		log.errorf(
			"[T%d] Protocol payload size %d exceeds maximum allowed %d for %s",
			td.thread_index,
			protocol_size,
			MAX_PROTOCOL_PAYLOAD_SIZE,
			error_context,
		)
		return nil, 0
	}

	header_len := get_ws_header_size(protocol_size)
	buf_size := header_len + protocol_size

	buf, err := byte_pool.alloc(td.spool, uint(buf_size))
	if err != .None {
		log.errorf("[T%d] Failed to allocate buffer for %s", td.thread_index, error_context)
		return nil, 0
	}

	// Write WebSocket header first
	ws_header := create_binary_header(u64(protocol_size))
	header_data, _ := ws.writeFrameHeader(ws_header)
	copy(buf[:header_len], header_data[:header_len])

	return buf, header_len
}

validate_websocket_frame_target :: proc(c: ^NRC_Connection, data: []byte) -> (target: int, complete_header: bool, success: bool) {
	h, header_size, header_err := ws.readFrameHeader(data)
	if header_err == .tooShort {
		return 0, false, true
	}
	if header_err != nil {
		log.errorf("[T%d] Malformed WebSocket frame header from %v: %v", td.thread_index, c.sock, header_err)
		connection_close(c, false)
		return 0, false, false
	}

	// Security check: enforce protocol payload size (decoded data only, no WS header)
	if h.payloadLength > u64(MAX_PROTOCOL_PAYLOAD_SIZE) {
		log.errorf(
			"[T%d] Protocol payload length %d exceeds maximum allowed %d - closing connection %v",
			td.thread_index,
			h.payloadLength,
			MAX_PROTOCOL_PAYLOAD_SIZE,
			c.sock,
		)
		connection_close(c, false)
		return 0, true, false
	}
	if h.payloadLength > cast(u64)max(int) - cast(u64)header_size {
		log.errorf("[T%d] WebSocket frame payload length %d overflows platform int on %v", td.thread_index, h.payloadLength, c.sock)
		connection_close(c, false)
		return 0, true, false
	}

	total_frame_size := header_size + int(h.payloadLength)

	// Security check: enforce WebSocket envelope size (header + payload)
	if total_frame_size > MAX_FRAME_SIZE {
		log.errorf("[T%d] Frame size %d exceeds maximum allowed %d - closing connection %v", td.thread_index, total_frame_size, MAX_FRAME_SIZE, c.sock)
		connection_close(c, false)
		return 0, true, false
	}
	return total_frame_size, true, true
}

start_receive_accumulator :: proc(c: ^NRC_Connection, data: []byte) -> bool {
	target, header_complete, success := validate_websocket_frame_target(c, data)
	if !success do return false
	assert(!header_complete || len(data) < target, "receive accumulator requires a parser-reported incomplete suffix")
	capacity := 14 // Largest masked WebSocket header.
	if header_complete do capacity = target
	buf_data, buf_err := byte_pool.alloc(td.spool, uint(capacity))
	if buf_err != nil {
		log.errorf("[T%d] Failed to allocate receive accumulator (%d bytes) for connection %v: %v", td.thread_index, capacity, c.sock, buf_err)
		connection_close(c, false)
		return false
	}
	copy(buf_data[:len(data)], data)
	c.receive_accumulator = Receive_Accumulator {
		buf    = buf_data,
		used   = len(data),
		target = target,
	}
	return true
}

reset_receive_accumulator :: proc(c: ^NRC_Connection) {
	if c.receive_accumulator.buf != nil {
		byte_pool.release(td.spool, c.receive_accumulator.buf)
	}
	c.receive_accumulator = {}
}

// on_recv_websocket_fixed is defined in callbacks.odin (Category 1 callback).
// See callbacks.odin for the implementation and buffer architecture documentation.

SHARD_DEFERRED_REQUEST_MAX_COUNT :: 512
SHARD_DEFERRED_REQUEST_MAX_BYTES :: 32 * 1024 * 1024

Shard_Deferred_Request :: struct {
	connection: Connection_IO_Context,
	payload:    []byte,
}

Shard_Protocol_Dispatch_Context :: struct {
	connection: ^NRC_Connection,
	payload:    []byte,
}

@(thread_local)
shard_protocol_dispatch_context: Shard_Protocol_Dispatch_Context

@(thread_local)
shard_protocol_replay_active: bool

defer_current_shard_protocol_request :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	c := shard_protocol_dispatch_context.connection
	payload := shard_protocol_dispatch_context.payload
	if writer == nil ||
	   c == nil ||
	   len(payload) == 0 ||
	   len(writer.deferred_requests) >= SHARD_DEFERRED_REQUEST_MAX_COUNT ||
	   len(payload) > SHARD_DEFERRED_REQUEST_MAX_BYTES - min(SHARD_DEFERRED_REQUEST_MAX_BYTES, writer.deferred_request_bytes) {
		return false
	}
	owned := make([]byte, len(payload))
	copy(owned, payload)
	if !connection_io_pin(c) {
		delete(owned)
		return false
	}
	io := connection_io_context_make(c)
	io.pinned = true
	if _, append_err := append(&writer.deferred_requests, Shard_Deferred_Request{connection = io, payload = owned}); append_err != nil {
		connection_io_unpin(io)
		delete(owned)
		return false
	}
	writer.deferred_request_bytes += len(owned)
	c.deferred_shard_requests += 1
	return true
}

release_shard_deferred_connection :: proc(request: Shard_Deferred_Request) {
	c := connection_from_io_context(request.connection)
	assert(c != nil && c.deferred_shard_requests > 0, "deferred shard request must retain its connection gate")
	if c != nil && c.deferred_shard_requests > 0 do c.deferred_shard_requests -= 1
}

discard_shard_deferred_requests :: proc(writer: ^Shard_Transaction_Writer) {
	if writer == nil do return
	for request in writer.deferred_requests {
		delete(request.payload)
		release_shard_deferred_connection(request)
		connection_io_unpin(request.connection)
	}
	delete(writer.deferred_requests)
	writer.deferred_requests = nil
	writer.deferred_request_bytes = 0
}

drain_shard_deferred_requests :: proc(writer: ^Shard_Transaction_Writer) {
	if writer == nil || len(writer.deferred_requests) == 0 do return
	requests := writer.deferred_requests
	writer.deferred_requests = nil
	writer.deferred_request_bytes = 0
	defer delete(requests)
	for request, index in requests {
		c := connection_from_io_context(request.connection)
		server_running := td.server == nil || !sync.atomic_load(&td.server.closing)
		if !writer.poisoned && td.state == .Running && server_running && c != nil && c.state < .Will_Close {
			previous_replay := shard_protocol_replay_active
			shard_protocol_replay_active = true
			process_protocol_payload(c, request.payload)
			shard_protocol_replay_active = previous_replay
		}
		delete(request.payload)
		release_shard_deferred_connection(request)
		connection_io_unpin(request.connection)
		if len(writer.deferred_requests) > 0 {
			// A replay that re-defers remains ahead of the untouched tail. Move
			// its existing ownership, rather than dispatching or pinning it again.
			_, err := append(&writer.deferred_requests, ..requests[index + 1:])
			assert(err == nil)
			for pending in requests[index + 1:] do writer.deferred_request_bytes += len(pending.payload)
			break
		}
	}
}

reset_fragment_accumulator :: proc(c: ^NRC_Connection) {
	if c.fragment_buf != nil {
		byte_pool.release(td.spool, c.fragment_buf)
	}
	c.fragment_buf = nil
	c.fragment_len = 0
}

start_fragment_accumulator :: proc(c: ^NRC_Connection, initial_payload: []byte) -> bool {
	if len(initial_payload) > MAX_PROTOCOL_PAYLOAD_SIZE {
		log.errorf("[T%d] Fragmented frame start exceeds protocol payload maximum %d on %v", td.thread_index, MAX_PROTOCOL_PAYLOAD_SIZE, c.sock)
		connection_close(c, false)
		return false
	}

	initial_capacity := max(len(initial_payload), 64)
	buf_data, buf_err := byte_pool.alloc(td.spool, uint(initial_capacity))
	if buf_err != nil {
		log.errorf("[T%d] Failed to allocate fragment buffer (%d bytes) for connection %v: %v", td.thread_index, initial_capacity, c.sock, buf_err)
		connection_close(c, false)
		return false
	}

	copy(buf_data[:len(initial_payload)], initial_payload)
	c.fragment_buf = buf_data
	c.fragment_len = len(initial_payload)

	return true
}

append_fragment_accumulator :: proc(c: ^NRC_Connection, payload: []byte) -> bool {
	if c.fragment_buf == nil {
		log.errorf("[T%d] append_fragment_accumulator called without active fragment on %v", td.thread_index, c.sock)
		connection_close(c, false)
		return false
	}

	new_len := c.fragment_len + len(payload)
	if new_len > MAX_PROTOCOL_PAYLOAD_SIZE {
		log.errorf("[T%d] Fragmented frame size %d exceeds protocol payload maximum %d on %v", td.thread_index, new_len, MAX_PROTOCOL_PAYLOAD_SIZE, c.sock)
		reset_fragment_accumulator(c)
		connection_close(c, false)
		return false
	}
	if new_len > len(c.fragment_buf) {
		new_capacity := len(c.fragment_buf)
		for new_capacity < new_len {
			new_capacity = min(MAX_PROTOCOL_PAYLOAD_SIZE, max(new_capacity * 2, new_len))
		}
		grown, grow_err := byte_pool.alloc(td.spool, uint(new_capacity))
		if grow_err != .None {
			log.errorf("[T%d] Failed to grow fragment buffer to %d bytes for connection %v: %v", td.thread_index, new_capacity, c.sock, grow_err)
			reset_fragment_accumulator(c)
			connection_close(c, false)
			return false
		}
		copy(grown[:c.fragment_len], c.fragment_buf[:c.fragment_len])
		byte_pool.release(td.spool, c.fragment_buf)
		c.fragment_buf = grown
	}

	copy(c.fragment_buf[c.fragment_len:new_len], payload)
	c.fragment_len = new_len
	return true
}

process_protocol_payload :: proc(c: ^NRC_Connection, frame_data: []byte) {
	if len(frame_data) < 2 {
		log.errorf("[T%d] Protocol payload too short (%d bytes) from %v", td.thread_index, len(frame_data), c.sock)
		send_error_response(c, pr.Opcode(0xFFFF), "Protocol payload too short")
		return
	}

	if len(frame_data) > MAX_PROTOCOL_PAYLOAD_SIZE {
		log.errorf("[T%d] Protocol payload size %d exceeds maximum allowed %d from %v", td.thread_index, len(frame_data), MAX_PROTOCOL_PAYLOAD_SIZE, c.sock)
		connection_close(c, false)
		return
	}
	previous_dispatch := shard_protocol_dispatch_context
	shard_protocol_dispatch_context = {
		connection = c,
		payload    = frame_data,
	}
	defer shard_protocol_dispatch_context = previous_dispatch
	writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)c.workspace_id)
	if writer != nil && writer.write_in_flight || c.deferred_shard_requests > 0 && !shard_protocol_replay_active {
		if writer != nil && defer_current_shard_protocol_request(writer) do return
		send_websocket_close_frame_and_close(c, 1013, "Server too busy")
		return
	}

	opcode := pr.get_opcode(frame_data)
	if is_workspace_data_opcode(opcode) && !workspace_data_scope_valid(frame_data[2:]) {
		send_error_response(c, opcode, "Workspace data requires scope 0; update your client")
		return
	}
	#partial switch opcode {
	case .C_SendMessage:
		req, parse_err := pr.parseSendMessageRequest(frame_data[2:])
		if parse_err == nil {
			process_send_message(c, req)
		} else {
			log.errorf("[T%d] Failed to parse SendMessageRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_SendMessage, "Failed to parse request")
		}
	case .C_SendMessageV2:
		req, parse_err := pr.parseSendMessageV2Request(frame_data[2:])
		if parse_err == nil {
			process_send_message_v2(c, req)
		} else {
			log.errorf("[T%d] Failed to parse SendMessageV2Request: %v", td.thread_index, parse_err)
			send_error_response(c, .C_SendMessageV2, "Failed to parse request")
		}
	case .C_SubscribeConvs:
		req, parse_err := pr.parseSubscribeConvsRequest(frame_data[2:])
		if parse_err == nil {
			for conv_id in req.conv_ids {
				subscribe_to_conversation(c, conv_id)
			}
		} else {
			log.errorf("[T%d] Failed to parse SubscribeConvsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_SubscribeConvs, "Failed to parse request")
		}
	case .C_SubscribeConvsV2:
		req, parse_err := pr.parseSubscribeConvsV2Request(frame_data[2:])
		if parse_err == nil {
			process_subscribe_conversations_v2(c, req)
		} else {
			send_error_response(c, .C_SubscribeConvsV2, "Failed to parse request")
		}
	case .C_ListMessagesBefore, .C_ReplayMessagesAfter:
		req, parse_err := pr.parseMessageRangeRequest(frame_data[2:])
		if parse_err == nil {
			process_message_history(c, req, opcode == .C_ReplayMessagesAfter)
		} else {
			send_error_response(c, opcode, "Failed to parse request")
		}
	case .C_UnsubscribeConvs:
		req, parse_err := pr.parseUnsubscribeConvsRequest(frame_data[2:])
		if parse_err == nil {
			for conv_id in req.conv_ids {
				unsubscribe_from_conversation(c, conv_id)
			}
			send_ack_unsubscribe_convs(c, req.correlation_id)
		} else {
			log.errorf("[T%d] Failed to parse UnsubscribeConvsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_UnsubscribeConvs, "Failed to parse request")
		}
	case .C_Stats:
		req, parse_err := pr.parseStatsRequest(frame_data[2:])
		if parse_err == nil {
			process_stats(c, req)
		} else {
			log.errorf("[T%d] Failed to parse StatsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_Stats, "Failed to parse request")
		}
	case .C_Ping:
		req, parse_err := pr.parsePingRequest(frame_data[2:])
		if parse_err == nil {
			process_ping(c, req)
		} else {
			log.errorf("[T%d] Failed to parse PingRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_Ping, "Failed to parse request")
		}
	case .C_CreateTask:
		attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		req, parse_err := pr.parseCreateTaskRequest(frame_data[2:], attachments[:])
		if parse_err == nil {
			process_create_task(c, req)
		} else {
			log.errorf("[T%d] Failed to parse CreateTaskRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_CreateTask, "Failed to parse request")
		}
	case .C_UpdateTask:
		attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		req, parse_err := pr.parseUpdateTaskRequest(frame_data[2:], attachments[:])
		if parse_err == nil {
			process_update_task(c, req)
		} else {
			log.errorf("[T%d] Failed to parse UpdateTaskRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_UpdateTask, "Failed to parse request")
		}
	case .C_DeleteTask:
		req, parse_err := pr.parseDeleteTaskRequest(frame_data[2:])
		if parse_err == nil {
			process_delete_task(c, req)
		} else {
			log.errorf("[T%d] Failed to parse DeleteTaskRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_DeleteTask, "Failed to parse request")
		}
	case .C_MoveTask:
		req, parse_err := pr.parseMoveTaskRequest(frame_data[2:])
		if parse_err == nil {
			process_move_task(c, req)
		} else {
			log.errorf("[T%d] Failed to parse MoveTaskRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_MoveTask, "Failed to parse request")
		}
	case .C_GetTasks:
		req, parse_err := pr.parseGetTasksRequest(frame_data[2:])
		if parse_err == nil {
			process_get_tasks(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GetTasksRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GetTasks, "Failed to parse request")
		}
	case .C_ListTasksPaged:
		req, parse_err := pr.parseListTasksPagedRequest(frame_data[2:])
		if parse_err == nil {
			process_list_tasks_paged(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListTasksPagedRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListTasksPaged, "Failed to parse request")
		}
	case .C_GetTask:
		req, parse_err := pr.parseGetTaskRequest(frame_data[2:])
		if parse_err == nil {
			process_get_task(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GetTaskRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GetTask, "Failed to parse request")
		}
	case .C_ApplyTransaction:
		operations: [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionOperation
		req, parse_err := pr.parseApplyTransactionRequest(frame_data[2:], operations[:])
		if parse_err == nil {
			for operation in req.operations {
				if !workspace_data_scope_valid(operation.body) {
					send_error_response(c, .C_ApplyTransaction, "Workspace data requires scope 0; update your client", req.correlation_id)
					return
				}
			}
			process_apply_transaction(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ApplyTransactionRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ApplyTransaction, "Failed to parse request")
		}
	case .C_QueryTasks:
		req, parse_err := pr.parseTaskQueryRequest(frame_data[2:])
		if parse_err == nil {process_query_tasks(c, req)} else {send_error_response(c, .C_QueryTasks, "Failed to parse request")}
	case .C_ListTaskProjects:
		req, parse_err := pr.parseListTaskProjectsRequest(frame_data[2:])
		if parse_err == nil {process_list_task_projects(c, req)} else {send_error_response(c, .C_ListTaskProjects, "Failed to parse request")}
	case .C_ListTaskAssignees:
		// Assignee metadata uses the same scope/correlation request as projects.
		req, parse_err := pr.parseListTaskProjectsRequest(frame_data[2:])
		if parse_err == nil {process_list_task_assignees(c, req)} else {send_error_response(c, .C_ListTaskAssignees, "Failed to parse request")}
	case .C_QueryCalendar:
		req, parse_err := pr.parseCalendarRequest(frame_data[2:])
		if parse_err == nil {process_calendar_query(c, req)} else {send_error_response(c, .C_QueryCalendar, "Failed to parse request")}
	case .C_ListTaskSlices:
		req, parse_err := pr.parseListTaskSlicesRequest(frame_data[2:])
		if parse_err == nil {process_list_task_slices(c, req)} else {send_error_response(c, .C_ListTaskSlices, "Failed to parse request")}
	case .C_CreateAsset:
		attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		req, parse_err := pr.parseCreateAssetRequestWithAttachments(frame_data[2:], attachments[:])
		if parse_err == nil {
			handle_create_asset(c, req)
		} else {
			log.errorf("[T%d] Failed to parse CreateAssetRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_CreateAsset, "Failed to parse request")
		}
	case .C_UpdateAsset:
		attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		req, parse_err := pr.parseUpdateAssetRequestWithAttachments(frame_data[2:], attachments[:])
		if parse_err == nil {
			handle_update_asset(c, req)
		} else {
			log.errorf("[T%d] Failed to parse UpdateAssetRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_UpdateAsset, "Failed to parse request")
		}
	case .C_DeleteAsset:
		req, parse_err := pr.parseDeleteAssetRequest(frame_data[2:])
		if parse_err == nil {
			handle_delete_asset(c, req)
		} else {
			log.errorf("[T%d] Failed to parse DeleteAssetRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_DeleteAsset, "Failed to parse request")
		}
	case .C_GetAsset:
		req, parse_err := pr.parseGetAssetRequest(frame_data[2:])
		if parse_err == nil {
			handle_get_asset(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GetAssetRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GetAsset, "Failed to parse request")
		}
	case .C_ListAssets:
		req, parse_err := pr.parseListAssetsRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_assets(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListAssetsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListAssets, "Failed to parse request")
		}
	case .C_ListAssetsPaged:
		req, parse_err := pr.parseListAssetsPagedRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_assets_paged(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListAssetsPagedRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListAssetsPaged, "Failed to parse request")
		}
	case .C_ListAssetsPagedByProject:
		req, parse_err := pr.parseListAssetsPagedByProjectRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_assets_paged_by_project(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListAssetsPagedByProjectRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListAssetsPagedByProject, "Failed to parse request")
		}
	case .C_ListNoteProjects:
		req, parse_err := pr.parseListNoteProjectsRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_note_projects(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListNoteProjectsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListNoteProjects, "Failed to parse request")
		}
	case .C_ListAssetsPagedByTag:
		req, parse_err := pr.parseListAssetsPagedByTagRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_assets_paged_by_tag(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListAssetsPagedByTagRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListAssetsPagedByTag, "Failed to parse request")
		}
	case .C_ListNoteTags:
		req, parse_err := pr.parseListNoteTagsRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_note_tags(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListNoteTagsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListNoteTags, "Failed to parse request")
		}
	// Edge/Knowledge Graph operations
	case .C_CreateEdge:
		req, parse_err := pr.parseCreateEdgeRequest(frame_data[2:])
		if parse_err == nil {
			handle_create_edge(c, req)
		} else {
			log.errorf("[T%d] Failed to parse CreateEdgeRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_CreateEdge, "Failed to parse request")
		}
	case .C_DeleteEdge:
		req, parse_err := pr.parseDeleteEdgeRequest(frame_data[2:])
		if parse_err == nil {
			handle_delete_edge(c, req)
		} else {
			log.errorf("[T%d] Failed to parse DeleteEdgeRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_DeleteEdge, "Failed to parse request")
		}
	case .C_ListEdges:
		req, parse_err := pr.parseListEdgesRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_edges(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListEdgesRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListEdges, "Failed to parse request")
		}
	case .C_ListAllEdges:
		req, parse_err := pr.parseListAllEdgesRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_all_edges(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListAllEdgesRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListAllEdges, "Failed to parse request")
		}
	case .C_ListAllEdgesPaged:
		req, parse_err := pr.parseListAllEdgesPagedRequest(frame_data[2:])
		if parse_err == nil {
			handle_list_all_edges_paged(c, req)
		} else {
			send_error_response(c, .C_ListAllEdgesPaged, "Failed to parse request")
		}
	case .C_ListEdgesPaged:
		req, parse_err := pr.parseListEdgesPagedRequest(frame_data[2:])
		if parse_err == nil do handle_list_edges_paged(c, req)
		else do send_error_response(c, .C_ListEdgesPaged, "Failed to parse request")
	case .C_SearchCustomers:
		req, parse_err := pr.parseSearchCustomersRequest(frame_data[2:])
		if parse_err == nil do handle_search_customers(c, req)
		else do send_error_response(c, .C_SearchCustomers, "Failed to parse request")
	// Graph Query operations
	case .C_GraphQuery:
		req, parse_err := pr.parseGraphQueryRequest(frame_data[2:])
		if parse_err == nil {
			handle_graph_query(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GraphQueryRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GraphQuery, "Failed to parse request")
		}
	case .C_GraphShortestPath:
		req, parse_err := pr.parseGraphShortestPathRequest(frame_data[2:])
		if parse_err == nil {
			handle_shortest_path(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GraphShortestPathRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GraphShortestPath, "Failed to parse request")
		}
	case .C_GraphDegree:
		req, parse_err := pr.parseGraphDegreeRequest(frame_data[2:])
		if parse_err == nil {
			handle_degree_query(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GraphDegreeRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GraphDegree, "Failed to parse request")
		}
	case .C_GraphCommonNeighbors:
		req, parse_err := pr.parseGraphCommonNeighborsRequest(frame_data[2:])
		if parse_err == nil {
			handle_common_neighbors(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GraphCommonNeighborsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GraphCommonNeighbors, "Failed to parse request")
		}
	case .C_GraphRank:
		req, parse_err := pr.parseGraphRankRequest(frame_data[2:])
		if parse_err == nil {
			handle_graph_rank(c, req)
		} else {
			log.errorf("[T%d] Failed to parse GraphRankRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_GraphRank, "Failed to parse request")
		}
	case .C_StartDM:
		req, parse_err := pr.parseStartDMRequest(frame_data[2:])
		if parse_err == nil {
			process_start_dm(c, req)
		} else {
			log.errorf("[T%d] Failed to parse StartDMRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_StartDM, "Failed to parse request")
		}
	case .C_ListDMs:
		req, parse_err := pr.parseListDMsRequest(frame_data[2:])
		if parse_err == nil {
			process_list_dms(c, req)
		} else {
			log.errorf("[T%d] Failed to parse ListDMsRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_ListDMs, "Failed to parse request")
		}
	case .C_LeaveDM:
		req, parse_err := pr.parseLeaveDMRequest(frame_data[2:])
		if parse_err == nil {
			process_leave_dm(c, req)
		} else {
			log.errorf("[T%d] Failed to parse LeaveDMRequest: %v", td.thread_index, parse_err)
			send_error_response(c, .C_LeaveDM, "Failed to parse request")
		}
	case:
		if opcode == pr.Opcode(0xFFFF) {
			log.errorf("[T%d] Invalid/corrupted protocol opcode from %v (data: %x)", td.thread_index, c.sock, frame_data[:min(len(frame_data), 8)])
			send_error_response(c, pr.Opcode(0xFFFF), "Invalid protocol opcode")
		} else {
			log.warnf("[T%d] Unhandled protocol opcode %v (%d) from %v", td.thread_index, opcode, u16(opcode), c.sock)
			send_error_response(c, opcode, "Unhandled protocol opcode")
		}
	}
}

send_websocket_pong_control_frame :: proc(c: ^NRC_Connection, payload: []byte) -> bool {
	header := ws.header {
		fin           = true,
		opcode        = .opPong,
		mask          = false,
		payloadLength = u64(len(payload)),
	}
	header_data, header_len := ws.writeFrameHeader(header)
	frame, err := byte_pool.alloc(td.spool, uint(header_len + len(payload)))
	if err != .None {
		log.errorf("[T%d] Failed to allocate WebSocket pong control frame for %v", td.thread_index, c.sock)
		connection_close(c, false)
		return false
	}
	copy(frame[:header_len], header_data[:header_len])
	copy(frame[header_len:], payload)
	if !send_pooled_buffer_priority(c, frame) {
		if c.state < .Will_Close {
			connection_close(c, false)
		}
		return false
	}
	return true
}

// A non-nil yielded opts into worker admission. Direct parser-only callers keep
// the original API. Yield is distinct from an incomplete frame and happens
// before frame_iterator can unmask the next payload in place.
process_websocket_frames :: proc(c: ^NRC_Connection, buf: []byte, yielded: ^bool = nil) -> (processed: int, closed: bool) {
	if yielded != nil do yielded^ = false
	data := buf
	for {
		if len(data) > 0 && yielded != nil && input_budget_exhausted() {
			yielded^ = true
			td.input_budget_yields += 1
			return len(buf) - len(data), false
		}
		h, frame_data, frame_status := ws.frame_iterator(&data)
		if frame_status == .Incomplete do break
		if frame_status == .Protocol_Error {
			log.errorf("[T%d] Received malformed WebSocket frame from %v", td.thread_index, c.sock)
			connection_close(c, false)
			return len(buf), true
		}

		if !h.mask {
			log.errorf("[T%d] Received unmasked client WebSocket frame from %v", td.thread_index, c.sock)
			connection_close(c, false)
			return len(buf), true
		}
		if h.rsv1 || h.rsv2 || h.rsv3 {
			log.errorf("[T%d] Received WebSocket frame with reserved bits set from %v", td.thread_index, c.sock)
			connection_close(c, false)
			return len(buf), true
		}
		#partial switch h.opcode {
		case ._reserved_3, ._reserved_4, ._reserved_5, ._reserved_6, ._reserved_7, ._reserved_11, ._reserved_12, ._reserved_13, ._reserved_14, ._reserved_15:
			log.errorf("[T%d] Received WebSocket frame with reserved opcode %v from %v", td.thread_index, h.opcode, c.sock)
			connection_close(c, false)
			return len(buf), true
		}

		#partial switch h.opcode {
		case .opClose, .opPing, .opPong:
			if !h.fin || h.payloadLength > 125 || (h.opcode == .opClose && h.payloadLength == 1) {
				log.errorf("[T%d] Received invalid WebSocket control frame from %v", td.thread_index, c.sock)
				connection_close(c, false)
				return len(buf), true
			}
		}

		if h.payloadLength > u64(MAX_PROTOCOL_PAYLOAD_SIZE) || get_ws_received_header_size(h) + int(h.payloadLength) > MAX_FRAME_SIZE {
			log.errorf("[T%d] WebSocket frame size exceeds configured limits from %v", td.thread_index, c.sock)
			connection_close(c, false)
			return len(buf), true
		}

		if yielded != nil && td.input_budget_active do td.input_frames_remaining -= 1
		#partial switch h.opcode {
		case .opText:
			log.errorf("[T%d] Received unsupported WebSocket text frame from %v", td.thread_index, c.sock)
			connection_close(c, false)
			return len(buf), true
		case .opBinary:
			if c.fragment_buf != nil {
				log.errorf("[T%d] Received new data frame while fragmented message is in progress from %v", td.thread_index, c.sock)
				connection_close(c, false)
				return len(buf), true
			}
			if h.fin {
				process_protocol_payload(c, frame_data)
			} else {
				if !start_fragment_accumulator(c, frame_data) {
					return len(buf), true
				}
			}
		case .opContinuation:
			if c.fragment_buf == nil {
				log.errorf("[T%d] Received continuation frame without active fragmented message from %v", td.thread_index, c.sock)
				connection_close(c, false)
				return len(buf), true
			}
			if !append_fragment_accumulator(c, frame_data) do return len(buf), true
			if h.fin {
				assembled := c.fragment_buf[:c.fragment_len]
				process_protocol_payload(c, assembled)
				reset_fragment_accumulator(c)
			}
		case .opPing:
			if !send_websocket_pong_control_frame(c, frame_data) {
				return len(buf), true
			}
		case .opPong:
		// Native WebSocket pong frames are protocol-level keepalive responses; NRC's
		// application-level C_Ping/S_Pong messages are handled separately.
		case .opClose:
			when ODIN_DEBUG do debug_log("[T%d] Client %v sent close frame.", td.thread_index, c.sock)
			send_websocket_peer_close_reply(c, frame_data)
			return len(buf), true
		}
		if c.state >= .Will_Close do return len(buf), true
	}
	return len(buf) - len(data), false
}

// Schedule next receive operation with buffer allocation
schedule_next_recv :: proc(c: ^NRC_Connection) {
	if c == nil || c.state >= .Will_Close || c.deferred_input != nil {
		return
	}
	when NRC_SIMULATION {
		if nrc_sim_has_client(c.sock) {
			return
		}
	}

	// Buffer selection is handled by kernel from provided buffer ring.
	// Pass a generational socket/handle context so stale recv completions cannot
	// target a new connection if the OS reuses the socket descriptor.
	if !connection_io_pin(c) do return
	ctx := connection_io_context_make(c)
	ctx.pinned = true
	c.recv_completion = nbio.recv_provided(&td.io, c.sock, ctx, on_recv_websocket_fixed)
}

// Submit one item to the connection-owned outbox. Every outbound frame,
// including an idle connection's first frame, crosses this ownership boundary.
outbox_enqueue :: proc(c: ^NRC_Connection, item: Send_Item, priority: bool = false) {
	frame_lease_validate_owner(item.lease, item.handle)
	if priority {
		send_queue_push_priority(c, item)
	} else {
		send_queue_push(c, item)
		if td.defer_normal_outbox_pumps > 0 {
			if !c.outbox_pump_deferred {
				deferred_outbox_enqueue(c)
			}
		}
		if c.outbox_pump_deferred do return
	}
	if !c.is_sending {
		pump_outbox(c)
	}
}

// Queued bytes are immutable snapshots. Holding every application response from
// a dirty shard also prevents queries/broadcasts from exposing speculative state.
outbox_item_is_durable :: proc(item: ^Send_Item) -> bool {
	return outbox_item_shard_is_durable(item) && outbox_item_message_is_durable(item)
}

outbox_item_shard_is_durable :: proc(item: ^Send_Item) -> bool {
	if item == nil || item.durability_writer == nil do return true
	writer := item.durability_writer
	return(
		!writer.poisoned &&
		writer.wal.enabled &&
		(item.durability_generation < writer.durability_generation || item.durability_record <= writer.wal.durable_record_count) \
	)
}

outbox_item_message_is_durable :: proc(item: ^Send_Item) -> bool {
	if item == nil || item.message_store == nil do return true
	store := item.message_store
	return !store.poisoned && store.wal.enabled && (item.message_generation < store.active_generation || item.message_record <= store.wal.durable_record_count)
}

wait_for_durable_outbox :: proc(c: ^NRC_Connection, waiters: ^[dynamic]Connection_Handle) {
	if c.outbox_waiting_durability do return
	if len(waiters^) >= MAX_CONNECTIONS_PER_THREAD {
		live := 0
		for handle in waiters^ {
			conn := connection_get_by_handle(handle)
			if conn == nil || conn.state >= .Will_Close || !conn.outbox_waiting_durability do continue
			waiters^[live] = handle
			live += 1
		}
		resize(waiters, live)
	}
	if len(waiters^) >= MAX_CONNECTIONS_PER_THREAD {
		send_websocket_close_frame_and_close(c, 1013, "Server too busy")
		return
	}
	if _, err := append(waiters, c.handle); err != nil {
		send_websocket_close_frame_and_close(c, 1013, "Server too busy")
		return
	}
	c.outbox_waiting_durability = true
}

resume_shard_durable_outboxes :: proc(writer: ^Shard_Transaction_Writer) {
	resume_durable_outboxes(&writer.durability_waiters)
}

resume_durable_outboxes :: proc(pending: ^[dynamic]Connection_Handle) {
	waiters := pending^
	pending^ = nil
	defer delete(waiters)
	for handle in waiters {
		c := connection_get_by_handle(handle)
		if c == nil do continue
		c.outbox_waiting_durability = false
		if c.state < .Will_Close && !c.is_sending do pump_outbox(c)
	}
}

defer_normal_outbox_pumps_begin :: #force_inline proc() {
	td.defer_normal_outbox_pumps += 1
}

defer_normal_outbox_pumps_end :: #force_inline proc() {
	assert(td.defer_normal_outbox_pumps > 0, "deferred outbox pump depth underflow")
	td.defer_normal_outbox_pumps -= 1
}

// Bound each publication turn so one large callback wave cannot turn into a
// multi-thousand-SQE send burst that starves receive processing near saturation.
// The ring queue keeps each batch removal O(batch size), independent of the
// remaining backlog.
Deferred_Outbox_Publish_Batch :: 256
Deferred_Outbox_Max_Handles :: MAX_CONNECTIONS_PER_THREAD

deferred_outbox_pump_count :: #force_inline proc() -> int {
	return queue.len(td.deferred_outbox_handles)
}

// Reclaim queue capacity from closed connection generations without allocating.
// This full-queue path is rare; pop/reappend preserves surviving FIFO order.
compact_deferred_outbox_pumps :: proc() {
	entry_count := deferred_outbox_pump_count()
	for _ in 0 ..< entry_count {
		handle := queue.pop_front(&td.deferred_outbox_handles)
		conn := connection_get_by_handle(handle)
		if conn == nil do continue
		if conn.state >= .Will_Close {
			conn.outbox_pump_deferred = false
			continue
		}
		assert(conn.outbox_pump_deferred, "deferred outbox entry missing connection flag")
		if !conn.outbox_pump_deferred do continue
		if ok, _ := queue.push_back(&td.deferred_outbox_handles, handle); !ok {
			panic("failed to retain deferred outbox handle during compaction")
		}
	}
}

deferred_outbox_enqueue :: proc(c: ^NRC_Connection) {
	assert(!c.outbox_pump_deferred, "connection already has a deferred outbox entry")
	if deferred_outbox_pump_count() >= queue.cap(td.deferred_outbox_handles) {
		compact_deferred_outbox_pumps()
		if deferred_outbox_pump_count() >= queue.cap(td.deferred_outbox_handles) {
			panic("deferred outbox queue exceeded per-worker connection limit")
		}
	}
	if ok, _ := queue.push_back(&td.deferred_outbox_handles, c.handle); !ok {
		panic("failed to enqueue deferred outbox handle")
	}
	c.outbox_pump_deferred = true
}

drain_deferred_outbox_pumps :: proc() -> bool {
	if deferred_outbox_pump_count() == 0 do return false
	assert(td.defer_normal_outbox_pumps == 0, "cannot drain deferred outboxes while collecting fanout")

	drain_count := min(deferred_outbox_pump_count(), Deferred_Outbox_Publish_Batch)
	handles: [Deferred_Outbox_Publish_Batch]Connection_Handle
	for i in 0 ..< drain_count {
		handles[i] = queue.pop_front(&td.deferred_outbox_handles)
	}

	for handle in handles[:drain_count] {
		conn := connection_get_by_handle(handle)
		if conn == nil do continue
		conn.outbox_pump_deferred = false
		if conn.state < .Will_Close && !conn.is_sending {
			pump_outbox(conn)
		}
	}
	return true
}

discard_deferred_outbox_pumps :: proc() {
	assert(td.defer_normal_outbox_pumps == 0, "cannot discard deferred outboxes while collecting fanout")
	for deferred_outbox_pump_count() > 0 {
		handle := queue.pop_front(&td.deferred_outbox_handles)
		if conn := connection_get_by_handle(handle); conn != nil {
			conn.outbox_pump_deferred = false
		}
	}
}

// Pump the next item or bounded writev prefix from the connection-owned outbox.
// Uses hybrid strategy: batch when queue depth >= threshold, otherwise single send
// Optimization: prefetches next item while processing current to hide cache latency
pump_outbox :: proc(c: ^NRC_Connection) {
	// Guard: if already sending, return immediately (defensive)
	if c.is_sending {
		return
	}

	priority_len := send_queue_priority_len(c)
	use_priority := priority_len > 0
	q_len := priority_len
	if !use_priority {
		q_len = send_queue_normal_len(c)
	}
	if q_len == 0 {
		c.is_sending = false
		c.send_started_at = {}
		send_watchdog_untrack(c)
		return
	}

	if item := send_queue_peek(c); !outbox_item_is_durable(item) {
		if !outbox_item_shard_is_durable(item) {
			wait_for_durable_outbox(c, &item.durability_writer.durability_waiters)
		} else {
			wait_for_durable_outbox(c, &item.message_store.durability_waiters)
		}
		c.send_started_at = {}
		send_watchdog_untrack(c)
		return
	}
	send_watchdog_started(c, nrc_time_now_monotonic())

	// Check if we should batch
	if q_len >= Batch_Queue_Threshold {
		if send_batch(c, use_priority) {
			return // Batch sent successfully
		}
		// Batch failed to send - fall through to single send
	}

	// Single send path with prefetch optimization
	// Prefetch next item while we process this one (hides cache miss latency)
	next_ptr := send_queue_peek(c)
	if next_ptr != nil {
		intrinsics.prefetch_read_data(next_ptr, 3) // 3 = high temporal locality (keep in all caches)
	}

	item := send_queue_pop(c)

	// Send via runtime boundary - pass socket separately for safe lookup in callback
	// The worker watchdog prevents stalled peers from pinning send SQEs indefinitely.
	// See callbacks.odin for on_queued_send_complete safety documentation
	nrc_io_send_all(c, frame_lease_data(item.lease), item)
}

// Batch multiple send items into a single writev operation
// Returns true if batch was sent, false if not (caller should fall back to single send)
send_batch :: proc(c: ^NRC_Connection, priority: bool = false) -> bool {
	q_len := send_queue_normal_len(c)
	if priority {
		q_len = send_queue_priority_len(c)
	}
	if q_len < Batch_Queue_Threshold {
		return false
	}
	first := send_queue_peek_normal(c)
	if priority do first = send_queue_peek(c)
	if !outbox_item_is_durable(first) do return false

	// Determine batch size: min of queue length, Max_Batch_Size
	batch_count := min(q_len, Max_Batch_Size)

	// Allocate batch state (single allocation for header, items, and iovec)
	state := alloc_batch_state(batch_count)
	if state == nil {
		log.errorf("[T%d] Failed to allocate batch state for %d items", td.thread_index, batch_count)
		return false
	}

	// Pop items from queue and populate batch state
	// Also enforce Max_Batch_Bytes limit during iteration
	actual_count := 0
	for _ in 0 ..< batch_count {
		next := send_queue_peek_normal(c)
		if priority do next = send_queue_peek(c)
		if !outbox_item_is_durable(next) do break
		// Check bytes limit before adding next item
		if actual_count > 0 && state.total_bytes >= Max_Batch_Bytes {
			break
		}

		item: Send_Item
		if priority {
			item = send_queue_pop_priority(c)
		} else {
			item = send_queue_pop_normal(c)
		}

		state.items[actual_count] = Batch_Item {
			handle   = item.handle,
			lease    = item.lease,
			action   = item.action,
			observer = item.observer,
		}
		frame_lease_validate_owner(item.lease, item.handle)
		buf := frame_lease_data(item.lease)
		item.lease = {}

		state.iovec[actual_count] = nbio.iovec {
			iov_base = raw_data(buf),
			iov_len  = uint(len(buf)),
		}

		state.total_bytes += len(buf)
		actual_count += 1
	}
	state.count = actual_count

	// Adjust iovec slice to actual count
	state.iovec = state.iovec[:actual_count]
	state.items = state.items[:actual_count]

	// Send via runtime boundary with a direct batch completion callback. The
	// worker watchdog prevents stalled peers from pinning send SQEs indefinitely.
	nrc_io_writev_all(c, state)

	return true
}

// WebSocket send wrapper with queue-based serialization
// Returns true if send was initiated or queued, false if dropped/error
websocket_send_all_with_priority :: proc(
	c: ^NRC_Connection,
	lease: Frame_Lease,
	action := Send_Completion_Action.None,
	priority := false,
	observer := Send_Completion_Observer{},
	shard_independent := false,
) -> bool {
	owned_lease := lease
	// Check if connection is closing/closed
	if c.state >= .Will_Close {
		frame_lease_dispose(&owned_lease)
		return false
	}

	// Max_Queue_Size bounds frames waiting behind an active transport send. An
	// idle connection has no backlog, even though outbox_enqueue briefly places
	// its first frame in the queue before pump_outbox submits it. A deferred
	// connection likewise reserves its first queued frame as the next send; only
	// later frames count as backlog until the callback wave ends.
	queue_len := send_queue_len(c)
	queue_full :=
		(c.is_sending && queue_len >= Max_Queue_Size) ||
		(!c.is_sending && (c.outbox_pump_deferred || c.outbox_waiting_durability) && queue_len > Max_Queue_Size)
	if queue_full {
		log.warnf("[T%d] Connection %v send queue full (%d), closing with 'server busy'", td.thread_index, c.sock, Max_Queue_Size)
		frame_lease_dispose(&owned_lease)
		send_websocket_close_frame_and_close(c, 1013, "Server too busy")
		return false
	}
	// Only server-side durability waits feed back into admission. A slow
	// transport must hit its own cap/watchdog, not reduce other clients' budget.
	// Finish this handler atomically; never recurse into nbio or bypass fsync.
	if td.input_budget_active && queue_len + 1 >= max(1, Max_Queue_Size / 2) && !c.is_sending && !outbox_item_is_durable(send_queue_peek(c)) {
		td.input_pressure_handle = c.handle
		if td.input_frames_remaining > 0 {
			td.input_frames_remaining = 0
			td.input_pressure_yields += 1
		}
	}

	item := Send_Item {
		lease    = owned_lease,
		handle   = c.handle,
		action   = action,
		observer = observer,
	}
	if writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)c.workspace_id); !shard_independent && writer != nil {
		record := writer.wal.record_count + writer.wal.buffered_record_count
		if writer.poisoned || !writer.wal.enabled || record > writer.wal.durable_record_count {
			item.durability_writer = writer
			item.durability_generation = writer.durability_generation
			item.durability_record = record
		}
	}
	if store := message_store_for_workspace(&td.message_stores, transmute([]byte)c.workspace_id); !shard_independent && store != nil {
		record := store.wal.record_count + store.wal.buffered_record_count
		if store.poisoned || !store.wal.enabled || record > store.wal.durable_record_count {
			item.message_store = store
			item.message_generation = store.active_generation
			item.message_record = record
		}
	}
	outbox_enqueue(c, item, priority)
	return true
}

// Send helper for pooled buffers (ctx=nil) that must be released if enqueue/send fails.
send_pooled_buffer :: proc(c: ^NRC_Connection, buf: []byte) -> bool {
	return nrc_send_frame(c, Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}))
}

send_pooled_buffer_priority :: proc(c: ^NRC_Connection, buf: []byte) -> bool {
	return nrc_send_frame(c, Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}), priority = true)
}

Graceful_Close_Context :: struct {
	sock:   net.TCP_Socket,
	handle: Connection_Handle,
}

graceful_close_context_new :: proc(conn: ^NRC_Connection) -> ^Graceful_Close_Context {
	ctx := new(Graceful_Close_Context)
	ctx.sock = conn.sock
	ctx.handle = conn.handle
	return ctx
}

graceful_close_context_connection :: proc(ctx: ^Graceful_Close_Context) -> ^NRC_Connection {
	if ctx == nil {
		return nil
	}
	conn := connection_get_by_handle(ctx.handle)
	if conn == nil || conn.sock != ctx.sock {
		return nil
	}
	return conn
}

graceful_close_context_discard :: proc(user: rawptr) {
	ctx := (^Graceful_Close_Context)(user)
	if ctx == nil do return
	free(ctx)
}

on_graceful_close_delay_elapsed :: proc(ctx: ^Graceful_Close_Context) {
	defer free(ctx)
	if conn := graceful_close_context_connection(ctx); conn != nil {
		connection_close(conn, false)
	}
}

on_graceful_close_shutdown_complete :: proc(user: rawptr, shutdown_err: net.Shutdown_Error) {
	ctx := (^Graceful_Close_Context)(user)
	conn := graceful_close_context_connection(ctx)
	if conn == nil {
		free(ctx)
		return
	}

	if shutdown_err != .None {
		when ODIN_DEBUG do debug_log("[T%d] Error during graceful shutdown(Send) for %v: %v", td.thread_index, ctx.sock, shutdown_err)
		connection_close(conn, false)
		connection_io_unpin(Connection_IO_Context{sock = ctx.sock, handle = ctx.handle, pinned = true})
		free(ctx)
		return
	}

	nrc_schedule_timer(Conn_Close_Delay, ctx, on_graceful_close_delay_elapsed)
	connection_io_unpin(Connection_IO_Context{sock = ctx.sock, handle = ctx.handle, pinned = true})
}

send_websocket_close_payload_internal :: proc(conn: ^NRC_Connection, payload: []byte, action: Send_Completion_Action) {
	if conn.state >= .Closing || conn.close_frame_reserved {
		return
	}
	conn.close_frame_reserved = true

	payload_len := min(len(payload), 125)
	ws_header := create_close_header(u64(payload_len))

	header_data, header_len := ws.writeFrameHeader(ws_header)
	total_frame_len := header_len + payload_len

	frame_buf := conn.close_frame_buf[:]
	if total_frame_len <= len(frame_buf) {
		copy(frame_buf[:header_len], header_data[:header_len])
		copy(frame_buf[header_len:header_len + payload_len], payload[:payload_len])

		item := Send_Item {
			lease  = Frame_Lease(Connection_Stable_Frame_Lease{data = frame_buf[:total_frame_len], owner = conn.handle}),
			handle = conn.handle,
			action = action,
		}
		outbox_enqueue(conn, item, priority = true)
	} else {
		conn.close_frame_reserved = false
	}
}

send_websocket_close_frame_internal :: proc(conn: ^NRC_Connection, code: u16, reason: string, action: Send_Completion_Action) {
	close_data: [125]byte
	close_data[0] = u8(code >> 8)
	close_data[1] = u8(code & 0xFF)
	reason_bytes := transmute([]byte)reason
	reason_len := min(len(reason_bytes), len(close_data) - 2)
	copy(close_data[2:2 + reason_len], reason_bytes[:reason_len])
	send_websocket_close_payload_internal(conn, close_data[:2 + reason_len], action)
}

send_websocket_peer_close_reply :: proc(conn: ^NRC_Connection, payload: []byte) {
	if !connection_begin_graceful_logical_close(conn, false) {
		return
	}
	send_websocket_close_payload_internal(conn, payload, .Peer_Close_After_Send)
}

// Send WebSocket close frame and then perform graceful FIN/close teardown.
send_websocket_close_frame_and_close :: proc(conn: ^NRC_Connection, code: u16, reason: string) {
	if !connection_begin_graceful_logical_close(conn, false) {
		return
	}
	send_websocket_close_frame_internal(conn, code, reason, .Close_After_Send)
}

send_error_response :: proc(c: ^NRC_Connection, origin_opcode: pr.Opcode, error_msg: string, correlation_id: u32 = 0) {
	// Parse failures can happen before request correlation_id is readable.
	// In that case callers intentionally send correlation_id=0.
	msg := pr.ErrorResponse {
		origin_opcode  = origin_opcode,
		error_msg      = transmute([]byte)error_msg,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeErrorResponse(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "error response")
	if buf == nil do return

	protocol_len := pr.serializeErrorResponse(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		byte_pool.release(td.spool, buf)
	}
}
