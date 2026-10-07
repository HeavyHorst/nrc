//
// message_handlers.odin - Protocol Message Processing
//
// This file contains handlers for specific protocol messages including:
// - SendMessage: Processes chat messages and broadcasts to subscribers
// - SetAgenda/GetAgenda: Manages conversation agenda content
// - Ping: Handles client keepalive messages
// - Server-ready notifications and acknowledgments
//
package main

import "core:c"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:sync"

import "byte_pool"
import nbio "nbio/poly"
import pr "protocol"
import ws "websocket"

when ODIN_OS == .Linux {
	@(default_calling_convention = "c")
	foreign _ {
		getpagesize :: proc() -> c.int ---
	}
}

// Cached page size in bytes (initialized once at startup)
@(private = "file")
cached_page_size: int = 0

get_page_size :: proc() -> int {
	if cached_page_size == 0 {
		when ODIN_OS == .Linux {
			cached_page_size = int(getpagesize())
		} else {
			cached_page_size = 4096 // fallback for non-Linux
		}
	}
	return cached_page_size
}

// Process C_SendMessage: send ack and broadcast to subscribers
process_send_message :: proc(c: ^NRC_Connection, req: pr.SendMessageRequest) {
	if req.conv_id == pr.WORKSPACE_DATA_ID {
		send_error_response(c, .C_SendMessage, "Workspace data scope is not a chat", req.client_req_id)
		return
	}
	if pr.is_dm_conversation(req.conv_id) && !validate_dm_access(c, req.conv_id) {
		send_error_response(c, .C_SendMessage, "DM access denied", req.client_req_id)
		return
	}

	assigned_seq := generate_message_seq()
	timestamp := nrc_time_unix_nanos()

	// 1. Send immediate ack to sender
	ack := pr.AckSendMessage {
		client_req_id = req.client_req_id,
		assigned_seq  = assigned_seq,
		timestamp     = timestamp,
	}
	send_ack_message_direct(c, ack)

	// 2. Create and broadcast new message event
	author_username := get_connection_nickname(c) // Get effective identity (verified user or service nickname)

	broadcast_msg := pr.NewMessageEvent {
		conv_id         = req.conv_id,
		seq             = assigned_seq,
		author_username = transmute([]byte)author_username,
		timestamp       = timestamp,
		content_type    = req.content_type,
		content         = req.content, // Safe to reference - same thread
	}

	// 3. Broadcast to all subscribers (excluding sender)
	broadcast_new_message(broadcast_msg, c.sock, get_connection_workspace(c))
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil && !nrc_sim_runtime.world.callback_wave_active {
			_ = drain_deferred_outbox_pumps()
		}
	}
}

// Send S_AckSendMessage response to client
send_ack_message_direct :: proc(c: ^NRC_Connection, ack: pr.AckSendMessage) {
	protocol_size := pr.getSizeAckSendMessage(ack)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "ack message")
	if buf == nil do return

	// Serialize protocol data directly at correct offset (zero-copy)
	protocol_len := pr.serializeAckSendMessage(ack, buf[header_len:])

	if protocol_len > 0 {
		total_len := header_len + protocol_len
		if send_pooled_buffer_priority(c, buf[:total_len]) {
			when NRC_SIMULATION {
				if nrc_sim_runtime == nil {
					_ = nbio.submit_pending(&td.io)
				}
			} else {
				_ = nbio.submit_pending(&td.io)
			}
		}
	} else {
		log.errorf("[T%d] Failed to serialize AckSendMessage for sock %v", td.thread_index, c.sock)
	}
}

server_ready_message :: proc(c: ^NRC_Connection) -> pr.ServerReady {
	return pr.ServerReady {
		build_version = transmute([]byte)(string(BUILD_VERSION)),
		protocol_version = PROTOCOL_VERSION,
		cpu_model = transmute([]byte)(string(CPU_MODEL_NAME)),
		username = transmute([]byte)get_connection_nickname(c),
		is_authenticated = c.authenticated,
	}
}

serialize_server_ready_frame :: proc(msg: pr.ServerReady, buf: []byte) -> int {
	protocol_size := pr.getSizeServerReady(msg)
	header_len := get_ws_header_size(protocol_size)
	if len(buf) < header_len + protocol_size do return -1

	ws_header := create_binary_header(u64(protocol_size))
	header_data, _ := ws.writeFrameHeader(ws_header)
	copy(buf[:header_len], header_data[:header_len])
	protocol_len := pr.serializeServerReady(msg, buf[header_len:])
	if protocol_len <= 0 do return protocol_len
	return header_len + protocol_len
}

// Send S_ServerReady to client - indicates server is ready to receive messages
send_server_ready :: proc(c: ^NRC_Connection) -> bool {
	msg := server_ready_message(c)

	protocol_size := pr.getSizeServerReady(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "server ready message")
	if buf == nil do return false

	// Serialize protocol data directly at correct offset (zero-copy)
	protocol_len := pr.serializeServerReady(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		return send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize ServerReady for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
	return false
}

on_server_bootstrap_complete :: proc(c: ^NRC_Connection, raw_ctx: rawptr, sent: int, err: net.Network_Error) {
	upgrade := cast(^HTTP_Upgrade_Connection)raw_ctx
	if upgrade == nil do return
	defer http_temp_connection_free(upgrade)

	if c == nil do return
	if err != nil {
		connection_close(c, false)
		return
	}

	initial_ws_bytes := upgrade.http_remainder_buf[upgrade.http_header_end:upgrade.http_received]
	if len(initial_ws_bytes) > 0 {
		initial_ctx := connection_io_context_make(c)
		initial_ctx.pinned = connection_io_pin(c)
		on_recv_websocket_fixed(initial_ctx, len(initial_ws_bytes), initial_ws_bytes, {}, nil)
	} else {
		schedule_next_recv(c)
	}
}

// Consumes upgrade on every return path. Send completion owns it after enqueue.
send_server_bootstrap :: proc(c: ^NRC_Connection, http_response: []byte, upgrade: ^HTTP_Upgrade_Connection) -> bool {
	msg := server_ready_message(c)
	protocol_size := pr.getSizeServerReady(msg)
	if protocol_size > MAX_PROTOCOL_PAYLOAD_SIZE {
		http_temp_connection_free(upgrade)
		return false
	}
	frame_size := get_ws_header_size(protocol_size) + protocol_size
	bootstrap_size := uint(len(http_response)) + uint(frame_size)
	buf, alloc_err := byte_pool.alloc(td.spool, bootstrap_size)
	if alloc_err != .None {
		log.errorf("[T%d] Failed to allocate bootstrap response for sock %v", td.thread_index, c.sock)
		http_temp_connection_free(upgrade)
		return false
	}

	copy(buf[:len(http_response)], http_response)
	frame_len := serialize_server_ready_frame(msg, buf[len(http_response):])
	if frame_len <= 0 {
		log.errorf("[T%d] Failed to serialize bootstrap ServerReady for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
		http_temp_connection_free(upgrade)
		return false
	}
	observer := Send_Completion_Observer {
		callback = on_server_bootstrap_complete,
		ctx      = upgrade,
	}
	if !nrc_send_frame(c, Frame_Lease(Pooled_Frame_Lease{data = buf[:len(http_response) + frame_len], pool = td.spool}), observer = observer) {
		http_temp_connection_free(upgrade)
		return false
	}
	return true
}

// Helper to get resident set size (RSS) in MB from /proc/self/statm
rss_memory_mb_from_statm :: proc(data: []byte, page_size: int) -> u32 {
	if page_size <= 0 do return 0

	// /proc/self/statm format: size resident shared text lib data dt
	// fields are separated by spaces
	// Find first space
	first_space := -1
	for b, i in data {
		if b == ' ' {
			first_space = i
			break
		}
	}
	if first_space == -1 do return 0

	// Find second space
	second_space := -1
	for i in first_space + 1 ..< len(data) {
		if data[i] == ' ' {
			second_space = i
			break
		}
	}
	if second_space == -1 {
		// Might be end of string if it's the last field, but usually there are more
		second_space = len(data)
	}

	// Parse resident pages (between first and second space)
	resident_str := string(data[first_space + 1:second_space])
	pages, ok := strconv.parse_int(resident_str)
	if !ok || pages < 0 do return 0

	// Convert pages to MB: pages * page_size / 1024 / 1024
	bytes := pages * page_size
	return u32(bytes / (1024 * 1024))
}

get_rss_memory_mb :: proc() -> u32 {
	f, err := os.open("/proc/self/statm")
	if err != nil do return 0
	defer os.close(f)

	buf: [128]byte
	read, read_err := os.read(f, buf[:])
	if read_err != nil || read <= 0 do return 0

	return rss_memory_mb_from_statm(buf[:read], get_page_size())
}

// Process C_Stats: respond with S_StatsResponse containing thread metrics.
process_stats :: proc(c: ^NRC_Connection, req: pr.StatsRequest) {
	// The service thread samples procfs; requests only load its latest value.
	mem_mb: u32
	if td.server != nil do mem_mb = sync.atomic_load(&td.server.cached_rss_mb)

	// Connection count
	conn_count := u32(td.connection_count)

	// Server timestamp
	server_ts := nrc_time_unix_nanos()

	// Calculate memory buffer pool usage percentage
	mem_percent := u32(0)
	if td.spool.usage_budget > 0 {
		mem_percent = u32(f64(td.spool.used) / f64(td.spool.usage_budget) * 100.0)
	}

	// Get IO stats
	io_stats := nrc_io_stats()

	// Get Send Queue stats
	q_depth := u32(send_queue_len(c))
	q_limit := u32(Max_Queue_Size)
	// Backpressure active if queue has significant items (e.g. > 10% of capacity)
	backpressure := q_depth > 12 // ~10% of 128

	// Entity WAL slots are retained on the wire for compatibility. Shard WAL
	// metrics are not representable as three entity-specific details.
	wal_details: [pr.PONG_WAL_DETAIL_SLOT_COUNT]pr.PongWALDetail
	wal_details[0].kind = .Task
	wal_details[1].kind = .Asset
	wal_details[2].kind = .Edge

	wal_file_size := wal_details[0].file_size + wal_details[1].file_size + wal_details[2].file_size
	wal_pending := wal_details[0].pending_bytes + wal_details[1].pending_bytes + wal_details[2].pending_bytes
	wal_records := wal_details[0].record_count + wal_details[1].record_count + wal_details[2].record_count
	wal_fsyncs := wal_details[0].fsync_count + wal_details[1].fsync_count + wal_details[2].fsync_count
	wal_fsync_ns := wal_details[0].total_fsync_ns + wal_details[1].total_fsync_ns + wal_details[2].total_fsync_ns
	wal_write_ns := wal_details[0].total_write_ns + wal_details[1].total_write_ns + wal_details[2].total_write_ns
	wal_writes := wal_details[0].write_count + wal_details[1].write_count + wal_details[2].write_count
	sweep_metrics := shard_writer_registry_sweep_metrics(&td.shard_writers)

	stats_response := pr.StatsResponse {
		timestamp = req.timestamp,
		server_timestamp = server_ts,
		thread_id = u32(td.thread_index),
		total_threads = u32(thread_count),
		connections = conn_count,
		memory_total_mb = mem_mb,
		buffer_pool_percent = mem_percent,
		io_pending = u32(nrc_io_num_waiting()),
		io_ring_depth = io_stats.ring_depth,
		io_ring_available = io_stats.ring_available,
		io_sq_overflow = io_stats.unqueued_depth,
		io_total_completions = io_stats.total_completions,
		io_total_latency_ns = io_stats.total_latency_ns,
		io_latency_count = io_stats.latency_sample_count,
		send_queue_depth = q_depth,
		send_queue_limit = q_limit,
		send_backpressure = backpressure,
		send_dropped = 0, // Current policy disconnects, so drops are 0

		// WAL metrics
		wal_file_size = wal_file_size,
		wal_pending_bytes = wal_pending,
		wal_record_count = wal_records,
		wal_fsync_count = wal_fsyncs,
		wal_total_fsync_ns = wal_fsync_ns,
		wal_total_write_ns = wal_write_ns,
		wal_write_count = wal_writes,
		wal_details_version = pr.PONG_WAL_DETAIL_VERSION,
		wal_details_count = pr.PONG_WAL_DETAIL_MAX_COUNT,
		wal_details = wal_details,
		shard_sweep_version = pr.PONG_SHARD_SWEEP_VERSION,
		shard_sweep = {
			runs_total = sweep_metrics.runs,
			ordinary_runs_total = sweep_metrics.ordinary_runs,
			raw_runs_total = sweep_metrics.raw_runs,
			input_bytes_total = sweep_metrics.input_bytes,
			dirty_bytes_total = sweep_metrics.dirty_bytes,
			prefix_read_bytes_total = sweep_metrics.prefix_read_bytes,
			latest_read_bytes_total = sweep_metrics.latest_read_bytes,
			measure_read_bytes_total = sweep_metrics.measure_read_bytes,
			copy_read_bytes_total = sweep_metrics.copy_read_bytes,
			replay_read_bytes_total = sweep_metrics.replay_read_bytes,
			metadata_fallbacks_total = sweep_metrics.metadata_fallbacks,
			metadata_written_bytes_total = sweep_metrics.metadata_written_bytes,
		},
	}

	send_stats_response(c, stats_response)
}

send_stats_response :: proc(c: ^NRC_Connection, stats: pr.StatsResponse) {
	protocol_size := pr.getSizeStatsResponse(stats)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "stats response")
	if buf == nil do return

	// Serialize protocol data directly at correct offset (zero-copy)
	protocol_len := pr.serializeStatsResponse(stats, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer_priority(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize StatsResponse for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

// Process C_Ping: respond with lightweight S_Pong echo.
process_ping :: proc(c: ^NRC_Connection, req: pr.PingRequest) {
	pong := pr.PongResponse {
		timestamp        = req.timestamp,
		server_timestamp = nrc_time_unix_nanos(),
	}

	send_pong_response(c, pong)
}

// Send lightweight S_Pong response to client.
send_pong_response :: proc(c: ^NRC_Connection, pong: pr.PongResponse) {
	protocol_size := pr.getSizePongResponse(pong)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "pong response")
	if buf == nil do return

	protocol_len := pr.serializePongResponse(pong, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		// Heartbeats expose no shard state and must remain responsive during fsync.
		_ = nrc_send_frame(c, Frame_Lease(Pooled_Frame_Lease{data = buf[:total_len], pool = td.spool}), priority = true, shard_independent = true)
	} else {
		log.errorf("[T%d] Failed to serialize PongResponse for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}
