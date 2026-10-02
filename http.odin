//
// http.odin - HTTP to WebSocket Upgrade Handling
//
// This file manages the HTTP to WebSocket protocol upgrade process including:
// - HTTP request parsing and path extraction
// - WebSocket handshake validation and response generation
// - Workspace-based connection routing to worker threads
// - Error response handling for invalid upgrade requests
// - SHA-1 key validation and Sec-WebSocket-Accept generation
//
package main

import "base:runtime"

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:log"
import "core:net"
import "core:strings"

import nbio "nbio/poly"
import pr "protocol"

magic_string :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

http_upgrade_target_worker_index :: proc(workspace_id: string, worker_count: int) -> int {
	return int(shard_for_workspace(transmute([]byte)workspace_id)) % worker_count
}

upgrade_response :: `HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: `


handshake_error_response :: `HTTP/1.1 500 Internal Server Error
Content-Type: text/plain
Content-Length: 27

Invalid WebSocket handshake`


auth_error_response :: `HTTP/1.1 401 Unauthorized
Content-Type: text/plain
Content-Length: 28

Invalid authentication token`


retry_response :: `HTTP/1.1 503 Service Unavailable
Content-Type: text/plain
Content-Length: 40
Retry-After: 5

Server queue full, retry after 5 seconds`


// HTTP_Upgrade_Connection owns a socket while it moves from main-thread HTTP
// receive to target-worker authentication and HTTP 101 completion.
HTTP_Upgrade_Connection :: struct {
	sock:                net.TCP_Socket,
	server:              ^NRC_Server,
	allocator:           runtime.Allocator,
	state:               Connection_State,
	workspace_id:        string,
	verified_username:   string,
	user_type:           pr.User_Type,
	authenticated:       bool,

	// HTTP upgrade tracking
	http_received:       int,
	http_remainder_buf:  []u8,
	http_header_end:     int,
	target_worker_index: int,
	httpResponseBuffer:  [126]byte,
}

http_upgrade_allocator :: #force_inline proc(c: ^HTTP_Upgrade_Connection) -> runtime.Allocator {
	if c.allocator.procedure != nil do return c.allocator
	return context.allocator
}

http_upgrade_commit_handoff :: proc(c: ^HTTP_Upgrade_Connection, target_queue: Pending_Connection_Queue) -> bool {
	// Publication transfers the upgrade object. On success the worker may already
	// have freed it, so neither this helper nor its caller may access c again.
	return pending_queue_try_send(target_queue, Pending_Connection{upgrade = c})
}

http_upgrade_close :: proc(c: ^HTTP_Upgrade_Connection) {
	if c.state >= .Closing {
		return
	}
	c.state = .Closing
	net.shutdown(c.sock, net.Shutdown_Manner.Send)
	nbio.close(&td.io, c.sock, c, proc(c_hint: ^HTTP_Upgrade_Connection, ok: bool) {
		allocator := http_upgrade_allocator(c_hint)
		if c_hint.workspace_id != "" {
			delete(c_hint.workspace_id, allocator)
			c_hint.workspace_id = ""
		}
		if c_hint.verified_username != "" {
			delete(c_hint.verified_username, allocator)
			c_hint.verified_username = ""
		}
		if c_hint.http_remainder_buf != nil {
			delete(c_hint.http_remainder_buf, allocator)
			c_hint.http_remainder_buf = nil
		}
		free(c_hint, allocator)
	})
}

http_temp_connection_free :: proc(c: ^HTTP_Upgrade_Connection) {
	allocator := http_upgrade_allocator(c)
	if c.workspace_id != "" {
		delete(c.workspace_id, allocator)
		c.workspace_id = ""
	}
	if c.verified_username != "" {
		delete(c.verified_username, allocator)
		c.verified_username = ""
	}
	if c.http_remainder_buf != nil {
		delete(c.http_remainder_buf, allocator)
		c.http_remainder_buf = nil
	}
	free(c, allocator)
}


// get_request_path extracts the path (Request-URI) from an HTTP/1.x request line.
//
// It expects the line to be in the format "METHOD /path/maybe?query HTTP/VERSION".
// It assumes the trailing CRLF (\r\n) has already been stripped from the input line.
//
// Returns the extracted path string and 'true' on success.
// Returns an empty string and 'false' if the line format is invalid.
get_request_path :: proc(request_line: string) -> (path: string, ok: bool) {
	if len(request_line) < 14 {
		return "", false
	}

	// Find the first space (after METHOD)
	first_space_index := strings.index_byte(request_line, ' ')
	if first_space_index <= 0 { 	// Must exist and not be the first character
		return "", false
	}

	// Find the *last* space (before HTTP-Version).
	// In a well-formed request line, this is the second space.
	second_space_index := strings.last_index_byte(request_line, ' ')

	if second_space_index < 0 || second_space_index <= first_space_index + 1 {
		// No second space found, or path part is empty
		return "", false
	}

	// The path is the substring between the first and second space
	path = request_line[first_space_index + 1:second_space_index]
	path = strings.trim_prefix(path, "/")
	ok = true
	return
}

HTTP_Upgrade_Decision_Kind :: enum {
	Accept,
	Reject_Handshake,
	Reject_Auth,
}

HTTP_Upgrade_Decision :: struct {
	kind:                    HTTP_Upgrade_Decision_Kind,
	workspace_id:            string,
	sec_websocket_key:       string,
	target_worker_index:     int,
	verified_username:       string,
	verified_username_owned: bool,
	user_type:               pr.User_Type,
	authenticated:           bool,
	key_present:             bool,
	upgrade_present:         bool,
	version:                 string,
	workspace_present:       bool,
	reason:                  string,
}

http_ascii_equal_fold :: #force_inline proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		c := a[i]
		other := b[i]
		if c >= 'A' && c <= 'Z' do c += 'a' - 'A'
		if other >= 'A' && other <= 'Z' do other += 'a' - 'A'
		if c != other do return false
	}
	return true
}

http_trim_optional_whitespace :: #force_inline proc(value: string) -> string {
	start := 0
	end := len(value)
	for start < end && (value[start] == ' ' || value[start] == '\t') do start += 1
	for end > start && (value[end - 1] == ' ' || value[end - 1] == '\t') do end -= 1
	return value[start:end]
}

http_find_headers_end :: #force_inline proc(data: []byte) -> int {
	for i := 3; i < len(data); i += 1 {
		if data[i - 3] == '\r' && data[i - 2] == '\n' && data[i - 1] == '\r' && data[i] == '\n' {
			return i - 3
		}
	}
	return -1
}

http_upgrade_workspace_from_request :: proc(request: string) -> (workspace_id: string, ok: bool) {
	line_end := strings.index_byte(request, '\n')
	if line_end < 0 do line_end = len(request)
	request_line := request[:line_end]
	if len(request_line) > 0 && request_line[len(request_line) - 1] == '\r' {
		request_line = request_line[:len(request_line) - 1]
	}
	return get_request_path(request_line)
}

parse_http_upgrade_decision :: proc(request_headers: string, service_secret: string, worker_count: int) -> HTTP_Upgrade_Decision {
	decision := HTTP_Upgrade_Decision {
		kind      = .Reject_Handshake,
		user_type = .User,
	}

	key, version: string
	workspace_id: string
	nrc_auth_token: string
	nrc_user_type: string
	nrc_bot_secret: string
	nrc_bot_nickname: string

	line_index := 0
	line_start := 0
	for line_start < len(request_headers) {
		line_end := line_start
		for line_end < len(request_headers) && request_headers[line_end] != '\n' do line_end += 1
		line := request_headers[line_start:line_end]
		if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		line_start = line_end + 1

		if line_index == 0 {
			ws_id, ok := get_request_path(line)
			if ok {
				workspace_id = ws_id
			}
			line_index += 1
			continue
		}
		if len(line) == 0 do break

		index := strings.index_byte(line, ':')
		if index < 0 {
			continue
		}

		value := http_trim_optional_whitespace(line[index + 1:])
		header_name := line[:index]
		if http_ascii_equal_fold(header_name, "Upgrade") && value == "websocket" {
			decision.upgrade_present = true
			continue
		}
		if http_ascii_equal_fold(header_name, "Sec-WebSocket-Key") {
			key = value
			continue
		}
		if http_ascii_equal_fold(header_name, "Sec-WebSocket-Version") {
			version = value
			continue
		}
		if http_ascii_equal_fold(header_name, "X-NRC-Auth") {
			nrc_auth_token = value
			continue
		}
		if http_ascii_equal_fold(header_name, "X-NRC-User-Type") {
			nrc_user_type = value
			continue
		}
		if http_ascii_equal_fold(header_name, "X-NRC-Bot-Secret") {
			nrc_bot_secret = value
			continue
		}
		if http_ascii_equal_fold(header_name, "X-NRC-Bot-Nickname") {
			nrc_bot_nickname = value
			continue
		}
	}

	decision.workspace_id = workspace_id
	decision.sec_websocket_key = key
	decision.version = version
	decision.key_present = key != ""
	decision.workspace_present = workspace_id != ""

	if key == "" || !decision.upgrade_present || version != "13" || workspace_id == "" {
		decision.reason = "invalid websocket handshake"
		return decision
	}

	user_type := pr.User_Type.User
	if nrc_user_type != "" && nrc_bot_secret != "" {
		if crypto.compare_constant_time(transmute([]u8)nrc_bot_secret, transmute([]u8)service_secret) == 1 {
			if http_ascii_equal_fold(nrc_user_type, "bot") {
				user_type = .Bot
			} else if http_ascii_equal_fold(nrc_user_type, "system") {
				user_type = .System
			} else if http_ascii_equal_fold(nrc_user_type, "admin") {
				user_type = .Admin
			}
		}
	}

	jwt_identity, jwt_ok, jwt_reason := validate_nrc_jwt(nrc_auth_token, workspace_id, workspace_access_enabled)
	if !jwt_ok && user_type == .User {
		decision.kind = .Reject_Auth
		decision.reason = jwt_reason
		return decision
	}

	verified_username := ""
	if jwt_ok {
		verified_username = jwt_identity.username
		if user_type == .User {
			user_type = jwt_identity.user_type
		}
	} else if user_type != .User {
		if !is_nickname_valid(nrc_bot_nickname) {
			decision.kind = .Reject_Auth
			decision.reason = "invalid service nickname"
			return decision
		}
		verified_username = nrc_bot_nickname
	}

	decision.kind = .Accept
	decision.target_worker_index = http_upgrade_target_worker_index(workspace_id, worker_count)
	decision.verified_username = verified_username
	decision.verified_username_owned = jwt_ok
	decision.user_type = user_type
	decision.authenticated = jwt_ok || user_type != .User
	return decision
}

// =============================================================================
// HTTP UPGRADE CALLBACKS - MAIN THREAD ONLY (SAFE)
// =============================================================================
//
// These callbacks run ONLY on the main thread, which is single-threaded for
// accept handling. Unlike worker thread callbacks, there is no concurrent
// I/O that could close/free the connection while we're processing.
//
// The connection pointer is valid because:
// 1. Main thread creates the connection on accept
// 2. Main thread handles all HTTP upgrade I/O sequentially
// 3. Connection is handed off to worker thread only AFTER upgrade completes
// 4. No other code path can free the connection during HTTP phase
//
// Therefore, we can safely use the connection pointer directly without
// the socket lookup pattern required for worker thread callbacks.
// =============================================================================

// Done means the receive callback must not schedule another HTTP recv. The
// connection may already be freed, closing asynchronously, sending an HTTP
// error, or sending the 101 response before worker handoff.
HTTP_Upgrade_Recv_Result :: enum {
	Done,
	Need_More,
}

http_upgrade_process_received :: proc(c: ^HTTP_Upgrade_Connection, received: int, buf: []byte) -> HTTP_Upgrade_Recv_Result {
	main_thread_id := c.server.main_thread

	if received > 0 {
		// Combine remainder data with new received data
		total_data: []byte
		total_len := c.http_received + received

		if c.http_received > 0 {
			// We have remainder data - combine it with new data
			if total_len > nbio.BUFFER_SIZE {
				log.warnf("[T%d Main] HTTP upgrade request headers too large from %v", main_thread_id, c.sock)
				net.close(c.sock)
				http_temp_connection_free(c)
				return .Done
			}
			if c.http_remainder_buf == nil {
				log.errorf("[T%d Main] HTTP upgrade state corrupt for %v: http_received=%d but no remainder buffer", main_thread_id, c.sock, c.http_received)
				net.close(c.sock)
				http_temp_connection_free(c)
				return .Done
			}
			if total_len > len(c.http_remainder_buf) {
				log.warnf("[T%d Main] HTTP upgrade headers exceed remainder buffer size from %v", main_thread_id, c.sock)
				net.close(c.sock)
				http_temp_connection_free(c)
				return .Done
			}

			copy(c.http_remainder_buf[c.http_received:total_len], buf[:received])
			total_data = c.http_remainder_buf[:total_len]
		} else {
			// No remainder, use buffer directly
			total_data = buf[:received]
		}

		// Check for incomplete headers and re-schedule recv if necessary
		end_of_headers := http_find_headers_end(total_data)
		if end_of_headers < 0 {
			// Buffer full, request too large
			if total_len >= nbio.BUFFER_SIZE {
				log.warnf("[T%d Main] HTTP upgrade request headers too large or incomplete from %v", main_thread_id, c.sock)
				net.close(c.sock)
				http_temp_connection_free(c)
				return .Done
			}

			// Save received data to remainder buffer for next recv
			if c.http_remainder_buf == nil {
				buf_data, buf_err := make([]u8, nbio.BUFFER_SIZE, http_upgrade_allocator(c))
				if buf_err != nil {
					log.errorf("[T%d Main] Failed to allocate HTTP remainder buffer for %v: %v", main_thread_id, c.sock, buf_err)
					net.close(c.sock)
					http_temp_connection_free(c)
					return .Done
				}
				c.http_remainder_buf = buf_data
			}
			if total_len > len(c.http_remainder_buf) {
				log.warnf("[T%d Main] HTTP upgrade headers exceed remainder buffer size from %v", main_thread_id, c.sock)
				net.close(c.sock)
				http_temp_connection_free(c)
				return .Done
			}

			when ODIN_DEBUG do debug_log("[T%d Main] Incomplete headers from %v, reading more...", main_thread_id, c.sock)
			copy(c.http_remainder_buf[:total_len], total_data)
			c.http_received = total_len

			return .Need_More
		}

		header_end := end_of_headers + len("\r\n\r\n")
		workspace_id, workspace_ok := http_upgrade_workspace_from_request(string(total_data[:header_end]))
		if !workspace_ok || workspace_id == "" {
			log.warnf("[T%d Main] HTTP upgrade request from %v has no routable workspace", main_thread_id, c.sock)
			response_len := copy(c.httpResponseBuffer[:], handshake_error_response[:])
			nbio.send_all(&td.io, c.sock, c.httpResponseBuffer[:response_len], Conn_Send_Timeout, c, on_handshake_error_send)
			return .Done
		}

		c.target_worker_index = http_upgrade_target_worker_index(workspace_id, thread_count)
		target_queue := c.server.pending_connections[c.target_worker_index]
		if !pending_queue_can_send(target_queue) {
			log.warnf("[T%d Main] Handoff queue for thread %d is full. Rejecting HTTP upgrade for sock %v.", main_thread_id, c.target_worker_index, c.sock)
			response_len := copy(c.httpResponseBuffer[:], retry_response[:])
			nbio.send_all(&td.io, c.sock, c.httpResponseBuffer[:response_len], Conn_Send_Timeout, c, on_retry_error_send)
			return .Done
		}

		if c.http_remainder_buf == nil {
			request_copy, alloc_err := make([]u8, total_len, http_upgrade_allocator(c))
			if alloc_err != nil {
				log.errorf("[T%d Main] Failed to preserve HTTP upgrade request for %v: %v", main_thread_id, c.sock, alloc_err)
				response_len := copy(c.httpResponseBuffer[:], retry_response[:])
				nbio.send_all(&td.io, c.sock, c.httpResponseBuffer[:response_len], Conn_Send_Timeout, c, on_retry_error_send)
				return .Done
			}
			copy(request_copy, total_data)
			c.http_remainder_buf = request_copy
		}
		c.http_received = total_len
		c.http_header_end = header_end

		if !http_upgrade_commit_handoff(c, target_queue) {
			log.warnf("[T%d Main] Worker %d queue rejected HTTP handoff for sock %v", main_thread_id, c.target_worker_index, c.sock)
			http_upgrade_close(c)
			return .Done
		}
		return .Done
	} else {
		log.infof("[T%d Main] Client %v disconnected before sending data.", main_thread_id, c.sock)
		// If no data is received, close the connection.
		http_upgrade_close(c)
		return .Done
	}
}

on_recv_http_upgrade :: proc(c: ^HTTP_Upgrade_Connection, received: int, buf: []byte, _: Maybe(net.Endpoint), err: net.Network_Error) {
	main_thread_id := c.server.main_thread
	if err != nil {
		log.errorf("[T%d Main] Error receiving initial HTTP data from client %v: %v", main_thread_id, c.sock, err)
		net.close(c.sock)
		http_temp_connection_free(c)
		return
	}

	if http_upgrade_process_received(c, received, buf) == .Need_More {
		// Use provided buffers for subsequent production receives. Tests that drive
		// chunks manually can call http_upgrade_process_received directly instead.
		nbio.recv_provided(&td.io, c.sock, c, on_recv_http_upgrade)
	}
}

on_retry_error_send :: proc(c: ^HTTP_Upgrade_Connection, sent: int, err: net.Network_Error) {
	http_upgrade_close(c)
}

on_handshake_error_send :: proc(c: ^HTTP_Upgrade_Connection, sent: int, err: net.Network_Error) {
	http_upgrade_close(c)
}

on_auth_error_send :: proc(c: ^HTTP_Upgrade_Connection, sent: int, err: net.Network_Error) {
	http_upgrade_close(c)
}

worker_process_http_upgrade :: proc(c: ^HTTP_Upgrade_Connection) {
	if c == nil || c.http_header_end <= 0 || c.http_header_end > c.http_received || c.http_received > len(c.http_remainder_buf) {
		if c != nil {
			log.errorf("[T%d] Invalid queued HTTP upgrade state for sock %v", td.thread_index, c.sock)
			net.close(c.sock)
			http_temp_connection_free(c)
		}
		return
	}

	parent_allocator := context.allocator
	context.allocator = http_upgrade_allocator(c)
	decision := parse_http_upgrade_decision(string(c.http_remainder_buf[:c.http_header_end]), bot_auth_secret, thread_count)
	context.allocator = parent_allocator
	switch decision.kind {
	case .Reject_Handshake:
		log.warnf("[T%d] Invalid WebSocket upgrade request for sock %v: %s", td.thread_index, c.sock, decision.reason)
		response_len := copy(c.httpResponseBuffer[:], handshake_error_response[:])
		nbio.send_all(&td.io, c.sock, c.httpResponseBuffer[:response_len], Conn_Send_Timeout, c, on_handshake_error_send)
		return
	case .Reject_Auth:
		log.warnf("[T%d] Rejected unauthenticated WebSocket upgrade for sock %v: %s", td.thread_index, c.sock, decision.reason)
		response_len := copy(c.httpResponseBuffer[:], auth_error_response[:])
		nbio.send_all(&td.io, c.sock, c.httpResponseBuffer[:response_len], Conn_Send_Timeout, c, on_auth_error_send)
		return
	case .Accept:
	}

	if decision.target_worker_index != td.thread_index {
		log.errorf("[T%d] HTTP upgrade for sock %v routed to worker %d", td.thread_index, c.sock, decision.target_worker_index)
		if decision.verified_username_owned do delete(decision.verified_username, http_upgrade_allocator(c))
		net.close(c.sock)
		http_temp_connection_free(c)
		return
	}

	c.workspace_id = strings.clone(decision.workspace_id, http_upgrade_allocator(c))
	if decision.verified_username_owned {
		c.verified_username = decision.verified_username
	} else {
		c.verified_username = strings.clone(decision.verified_username, http_upgrade_allocator(c))
	}
	c.user_type = decision.user_type
	c.authenticated = decision.authenticated

	websocket_accept: [60]byte
	copy(websocket_accept[:], decision.sec_websocket_key)
	copy(websocket_accept[24:], magic_string)

	digest: [20]byte
	hash.hash(hash.Algorithm.Insecure_SHA1, websocket_accept[:], digest[:])
	accept: [28]byte
	builder := strings.builder_from_bytes(accept[:])
	base64.encode_into(strings.to_stream(&builder), digest[:])

	copy(c.httpResponseBuffer[:], upgrade_response)
	copy(c.httpResponseBuffer[94:], accept[:])
	copy(c.httpResponseBuffer[122:], []byte{13, 10, 13, 10})
	worker_adopt_upgraded_connection(c, c.httpResponseBuffer[:])
}
