package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import nbio "nbio/poly"
import pr "protocol"
import sql "sqlite"
import wire "websocket"
import db "workspace_db"

// Synchronous SQLite boundary for simulated transport tests. This deliberately
// does not model executor scheduling: worker_db_test_dms covers that lifecycle.
// Each caller owns a disposable SQLite database and closes it after the test.
DM_Test_Database :: struct {
	store:     db.Store,
	directory: string,
}

dm_test_database :: proc() -> DM_Test_Database {
	directory, err := os.make_directory_temp("", "nrc-dm-simulation-", context.allocator)
	assert(err == nil)
	name := fmt.aprintf("%s/shard.db", directory); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	assert(rc == sql.OK)
	return {store, directory}
}

dm_test_database_destroy :: proc(database: ^DM_Test_Database) {
	db.close(&database.store)
	os.remove_all(database.directory)
	delete(database.directory)
}

dm_test_command :: proc(database: ^DM_Test_Database, c: ^NRC_Connection, opcode: pr.Opcode, correlation: u32, target := "", id: u64 = 0) {
	store := &database.store
	buf: [600]byte
	n := 0
	if opcode == .C_StartDM {
		endian.put_u16(buf[:], .Big, u16(len(target))); n = 2
		copy(buf[n:], target); n += len(target)
	} else if opcode == .C_LeaveDM {endian.put_u64(buf[:], .Big, id); n = 8}
	endian.put_u32(buf[n:], .Big, correlation); n += 4
	if get_connection_username(c) == "" {
		// Exercise the production authentication rejection, before any DB access.
		worker_db_submit_dm(c, opcode, buf[:n], correlation, target)
		return
	}
	job := db.Completion {
		request = {
			operation = .Command,
			opcode = opcode,
			body = buf[:n],
			workspace = c.workspace_id,
			actor = get_connection_username(c),
			dm_target_online = find_user_in_workspace(get_connection_workspace(c), target),
		},
	}
	job.result.command.limit = pr.MAX_PROTOCOL_PAYLOAD_SIZE
	defer db.destroy_command_output(&job.result.command)
	assert(db.begin(store) == sql.OK)
	job.result.status = sqlite_execute_dm(store, &job.request, &job.result.command)
	assert(job.result.status == sql.OK)
	assert(db.commit(store) == sql.OK)
	worker_db_complete_dm(c, correlation, &job)
	for state in job.result.command.dm_states do dm_test_evict_idle(get_connection_workspace(c), state.id)
}

// The synchronous adapter has no worker port, so explicitly provide the same
// idle-cache candidates the real completion marks for callback-wave cleanup.
dm_test_evict_idle :: proc(ws: ^Workspace_State, id: pr.ConversationID) {
	previous := td.database.idle_dms
	td.database.idle_dms = make(map[Worker_DB_DM_Key]bool)
	defer {delete(td.database.idle_dms); td.database.idle_dms = previous}
	td.database.idle_dms[{ws, id}] = true
	_ = worker_db_evict_idle_dms()
}

dm_test_start :: proc(store: ^DM_Test_Database, c: ^NRC_Connection, request: pr.StartDMRequest) {
	dm_test_command(store, c, .C_StartDM, request.correlation_id, request.username)
}

dm_test_list :: proc(store: ^DM_Test_Database, c: ^NRC_Connection, request: pr.ListDMsRequest) {
	dm_test_command(store, c, .C_ListDMs, request.correlation_id)
}

dm_test_leave :: proc(store: ^DM_Test_Database, c: ^NRC_Connection, request: pr.LeaveDMRequest) {
	dm_test_command(store, c, .C_LeaveDM, request.correlation_id, id = request.conv_id)
}

worker_db_test_dm_request :: proc(c: ^NRC_Connection, opcode: pr.Opcode, target := "", id: u64 = 0) {
	buf: [600]byte
	endian.put_u16(buf[:], .Big, u16(opcode))
	n := 2
	if opcode == .C_StartDM {
		endian.put_u16(buf[n:], .Big, u16(len(target))); n += 2
		copy(buf[n:], target); n += len(target)
	} else if opcode == .C_LeaveDM {endian.put_u64(buf[n:], .Big, id); n += 8}
	endian.put_u32(buf[n:], .Big, 1700); n += 4
	process_protocol_payload(c, buf[:n])
}

worker_db_test_dm_response :: proc(
	t: ^testing.T,
	c: ^NRC_Connection,
	opcode: pr.Opcode,
	correlation: u32 = 1700,
	partner := "",
	id: u64 = 0,
	error_code: pr.DM_Error_Code = .DM_Not_Found,
) {
	if !testing.expect(t, send_queue_len(c) > 0, "expected DM response") do return
	item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease); _, h, _ := wire.readFrameHeader(frame); payload := frame[h:]
	if !testing.expect_value(t, pr.get_opcode(payload), opcode) do return
	#partial switch opcode {
	case .S_DMStarted:
		r, e := pr.parseDMStartedMessage(payload); testing.expect(t, e == nil)
		testing.expect(t, r.correlation_id == correlation && r.username == partner && r.conv_id == id)
	case .S_DMLeft:
		r, e := pr.parseDMLeftMessage(payload); testing.expect(t, e == nil)
		testing.expect(t, r.correlation_id == correlation && r.conv_id == id)
	case .S_DMList:
		entries: [8]pr.DMEntry
		r, e := pr.parseDMListMessage(payload, entries[:]); testing.expect(t, e == nil)
		testing.expect_value(t, r.correlation_id, correlation)
		testing.expect_value(t, len(r.entries), partner == "" ? 0 : 1)
		if len(r.entries) > 0 do testing.expect(t, r.entries[0].username == partner && r.entries[0].conv_id == id)
	case .S_DMError:
		r, e := pr.parseDMErrorMessage(payload); testing.expect(t, e == nil)
		testing.expect(t, r.correlation_id == correlation && r.code == error_code)
	}
}

worker_db_test_dms :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	ws := get_or_create_connection_workspace(c)
	bob := connection_test_install_fake(
		{sock = connection_test_fake_socket(4), state = .Idle, workspace_id = c.workspace_id, authenticated = true, verified_username = "bob"},
	)
	second := connection_test_install_fake(
		{sock = connection_test_fake_socket(5), state = .Idle, workspace_id = c.workspace_id, authenticated = true, verified_username = "alice"},
	)
	assert(bob != nil && second != nil)
	defer {connection_test_uninstall(bob); connection_test_uninstall(second)}
	for conn in ([3]^NRC_Connection{c, bob, second}) {
		if conn != c {send_queue_init(conn); conn.is_sending = true}
		on_user_connect(ws, intern_username(conn.verified_username), true); track_user_connection(conn)
	}
	defer for conn in ([3]^NRC_Connection{c, bob, second}) {cleanup_connection_subscriptions(conn); untrack_user_connection(conn); remove_all_rooms(conn)}
	id := pr.make_dm_conversation_id("alice", "bob")
	worker_db_test_dm_request(c, .C_StartDM, "missing"); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMError, error_code = .User_Not_Found)
	worker_db_test_dm_request(c, .C_StartDM, "alice"); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMError, error_code = .Cannot_DM_Self)
	worker_db_test_dm_request(c, .C_StartDM, "bob")
	testing.expect(t, !validate_dm_access(c, id), "membership must not appear before completion")
	worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMStarted, partner = "bob", id = id)
	worker_db_test_dm_response(t, second, .S_DMStarted, 0, "bob", id)
	worker_db_test_dm_response(t, bob, .S_DMStarted, 0, "alice", id)
	testing.expect(t, validate_dm_access(c, id) && validate_dm_access(bob, id) && dm_metadata_durable(c, id))
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM dm_conversations WHERE members=3")
	worker_db_test_dm_request(bob, .C_ListDMs); worker_db_test_pump(t)
	worker_db_test_dm_response(t, bob, .S_DMList, partner = "alice", id = id)
	// Authentication and membership checks cannot be supplied by the client.
	c.authenticated = false
	worker_db_test_dm_request(c, .C_ListDMs)
	worker_db_test_dm_response(t, c, .S_DMError, error_code = .Not_Authenticated)
	c.authenticated = true
	c.verified_username = "outsider"
	worker_db_test_dm_request(c, .C_LeaveDM, id = id); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMError)
	worker_db_test_dm_request(c, .C_ListDMs); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMList)
	c.verified_username = "alice"
	// A failed write must leave subscriptions and authorization unchanged.
	testing.expect_value(
		t,
		sql.exec(store.db, "CREATE TRIGGER fail_dm BEFORE UPDATE ON dm_conversations BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil),
		sql.OK,
	)
	worker_db_test_dm_request(c, .C_LeaveDM, id = id); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMError)
	testing.expect(t, validate_dm_access(c, id) && conversation_has_subscriber(get_conversation(ws, id), second.sock))
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER fail_dm", nil, nil, nil), sql.OK)
	worker_db_test_dm_request(c, .C_LeaveDM, id = id); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMLeft, id = id)
	worker_db_test_dm_response(t, second, .S_DMLeft, 0, id = id)
	testing.expect(t, !validate_dm_access(c, id) && !conversation_has_subscriber(get_conversation(ws, id), second.sock) && validate_dm_access(bob, id))
	worker_db_test_dm_request(c, .C_ListDMs); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMList)
	worker_db_test_dm_request(bob, .C_LeaveDM, id = id); worker_db_test_pump(t)
	worker_db_test_dm_response(t, bob, .S_DMLeft, id = id)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM dm_conversations WHERE members=0")
	// Revoked pairs survive in SQLite, not in the idle runtime cache.
	testing.expect(t, get_conversation(ws, id) == nil)
	delete_key(&ws.user_connection_count, "bob")
	worker_db_test_dm_request(c, .C_StartDM, "bob"); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMStarted, partner = "bob", id = id)
	worker_db_test_dm_response(t, second, .S_DMStarted, 0, "bob", id)
	worker_db_test_dm_response(t, bob, .S_DMStarted, 0, "alice", id)
	// List restores access without any workspace-wide DM replay.
	remove_user_dm(ws, "alice", id); remove_user_dm(ws, "bob", id)
	conv := get_conversation(ws, id)
	destroy_dm_participants(conv.dm_participants); conv.dm_participants = nil
	worker_db_test_dm_request(c, .C_ListDMs); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMList, partner = "bob", id = id)
	testing.expect(t, validate_dm_access(c, id) && dm_metadata_durable(c, id))
	// A disconnected initiator cannot suppress revocation on its other device.
	worker_db_test_dm_request(c, .C_LeaveDM, id = id); c.state = .Will_Close
	worker_db_test_pump(t); c.state = .Idle
	testing.expect_value(t, send_queue_len(c), 0)
	worker_db_test_dm_response(t, second, .S_DMLeft, 0, id = id)
	testing.expect(t, !validate_dm_access(second, id) && validate_dm_access(bob, id))
	// Queue rejection uses the DM protocol and changes no membership.
	worker_db_test_dm_request(c, .C_ListDMs); worker_db_test_dm_request(c, .C_ListDMs); worker_db_test_dm_request(c, .C_ListDMs)
	worker_db_test_dm_response(t, c, .S_DMError)
	worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMList); worker_db_test_dm_response(t, c, .S_DMList)
	// Large lists fail atomically instead of partially installing memberships.
	testing.expect_value(t, db.begin(&store), sql.OK)
	for i in 0 ..< 80 {
		partner := fmt.aprintf("bulk-%d", i); defer delete(partner)
		key := pr.Asset {
			asset_id = pr.make_dm_conversation_id("alice", partner),
		}
		testing.expect_value(
			t,
			sqlite_projection_write(&store, "INSERT INTO dm_conversations VALUES(?1,?2,?3,?4,3)", c.workspace_id, &key, {"alice", partner}),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	worker_db_test_dm_request(c, .C_ListDMs); worker_db_test_pump(t)
	worker_db_test_dm_response(t, c, .S_DMError)
	testing.expect(t, !is_user_in_dm(ws, "alice", pr.make_dm_conversation_id("alice", "bulk-0")))
	// Cycling through persisted DMs must not accumulate idle conversations or
	// membership names, while Bob's still-subscribed DM remains live.
	conversation_count := len(ws.conversations)
	membership_count := len(ws.user_dms)
	for i in 0 ..< 32 {
		partner := fmt.aprintf("bulk-%d", i); defer delete(partner)
		transient_id := pr.make_dm_conversation_id("alice", partner)
		packet: [12]byte
		endian.put_u16(packet[:], .Big, u16(pr.Opcode.C_SubscribeConvs))
		endian.put_u16(packet[2:], .Big, 1); endian.put_u64(packet[4:], .Big, transient_id)
		process_protocol_payload(c, packet[:]); worker_db_test_pump(t)
		testing.expect(t, conversation_has_subscriber(get_conversation(ws, transient_id), c.sock))
		worker_db_test_dm_io_frames(t, c)
		endian.put_u16(packet[:], .Big, u16(pr.Opcode.C_UnsubscribeConvs))
		process_protocol_payload(c, packet[:]); worker_db_test_pump(t)
		worker_db_test_dm_io_frames(t, c)
		testing.expect(t, get_conversation(ws, transient_id) == nil && partner not_in ws.user_dms)
		testing.expect_value(t, len(ws.conversations), conversation_count)
		testing.expect_value(t, len(ws.user_dms), membership_count)
		testing.expect(t, conversation_has_subscriber(get_conversation(ws, id), bob.sock))
	}
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM dm_conversations WHERE user_b!=cast('bob' AS BLOB)", nil, nil, nil), sql.OK)
	// Reopen the file and inspect the committed revocation, not the RAM cache.
	db.close(&store); store, rc = db.open(path)
	testing.expect_value(t, rc, sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM dm_conversations WHERE members=2")
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
	for conn in ([3]^NRC_Connection{c, bob, second}) {cleanup_connection_subscriptions(conn); remove_all_rooms(conn)}
	_, wave_ok := worker_finish_callback_wave(); testing.expect(t, wave_ok)
	testing.expect(t, get_conversation(ws, id) == nil && len(ws.user_dms) == 0, "last disconnect releases membership cache")
}

worker_db_test_dm_retained :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	directory, err := os.make_directory_temp("", "nrc-dm-io-", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(directory); delete(directory)}
	shard := int(shard_for_workspace(transmute([]byte)c.workspace_id))
	for &index in td.message_stores.store_index do index = -1
	append(&td.message_stores.stores, Message_Store{})
	store := &td.message_stores.stores[0]
	if !testing.expect(t, init_message_store(store, directory, shard, 24 * time.Hour, 0)) do return
	td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0; td.message_stores.write_batch_records = 16
	defer testing.expect(t, shutdown_message_store_registry(&td.message_stores))
	database, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&database)
	testing.expect_value(t, sql.exec(database.db, "UPDATE dm_conversations SET members=1", nil, nil, nil), sql.OK)
	workspace := get_connection_workspace(c)
	id := pr.make_dm_conversation_id("alice", "bob")
	conv := get_conversation(workspace, id)
	remove_user_dm(workspace, "alice", id); remove_user_dm(workspace, "bob", id)
	if conv != nil {destroy_dm_participants(conv.dm_participants); conv.dm_participants = nil}
	track_user_connection(c)
	defer {cleanup_connection_subscriptions(c); untrack_user_connection(c); remove_all_rooms(c)}
	packet: [256]byte
	req := pr.SendMessageV2Request {
		conv_id        = id,
		correlation_id = 1800,
		content        = task_query_test_bytes("cold message"),
	}
	req.client_message_id[0] = 1
	n := pr.serializeSendMessageV2Request(req, packet[:])
	process_protocol_payload(c, packet[:n])
	testing.expect_value(t, c.retained_io, 0)
	worker_db_test_pump(t); worker_db_test_dm_io_pump(t, c, store)
	worker_db_test_dm_io_frames(t, c, ack = 1800)
	testing.expect_value(t, store.wal.durable_record_count, u64(1))
	sqlite_projection_test_assert(t, &database, "SELECT count(*)=1 FROM dm_conversations WHERE members=1")
	testing.expect(t, !validate_dm_access(&NRC_Connection{workspace_id = c.workspace_id, authenticated = true, verified_username = "bob"}, id))
	// The legacy watch opcode also loads one cold membership without ListDMs.
	testing.expect(t, get_conversation(workspace, id) == nil, "cold send must release its transient membership")
	endian.put_u16(packet[:], .Big, u16(pr.Opcode.C_SubscribeConvs)); endian.put_u16(packet[2:], .Big, 1); endian.put_u64(packet[4:], .Big, id)
	process_protocol_payload(c, packet[:12]); worker_db_test_pump(t)
	conv = get_conversation(workspace, id)
	testing.expect(t, conversation_has_subscriber(conv, c.sock)); worker_db_test_dm_io_frames(t, c)
	// A queued subscription must not resurrect a subsequent unsubscribe.
	process_protocol_payload(c, packet[:12])
	endian.put_u16(packet[:], .Big, u16(pr.Opcode.C_UnsubscribeConvs)); process_protocol_payload(c, packet[:12])
	worker_db_test_pump(t); testing.expect(t, get_conversation(workspace, id) == nil); worker_db_test_dm_io_frames(t, c)
	// A different identity cannot receive or install an outstanding lookup.
	n = pr.serializeSubscribeConvsV2Request({conv_ids = {id}, correlation_id = 1810}, packet[:])
	process_protocol_payload(c, packet[:n]); subject := c.verified_subject; c.verified_subject = "replacement"
	worker_db_test_pump(t); c.verified_subject = subject
	testing.expect(t, get_conversation(workspace, id) == nil && send_queue_len(c) == 0)
	process_protocol_payload(c, packet[:n]); worker_db_test_pump(t)
	conv = get_conversation(workspace, id)
	testing.expect(t, conversation_has_subscriber(conv, c.sock)); worker_db_test_dm_io_frames(t, c)
	n = pr.serializeMessageRangeRequest(.C_ListMessagesBefore, {conv_id = id, limit = 10, correlation_id = 1801}, packet[:])
	process_protocol_payload(c, packet[:n]); worker_db_test_pump(t); worker_db_test_dm_io_pump(t, c, store)
	worker_db_test_dm_io_frames(t, c, page = 1801)
	// Wire order, no wait for the leave reply: the following send must be denied.
	worker_db_test_dm_request(c, .C_LeaveDM, id = id)
	req.correlation_id = 1802; req.client_message_id[0] = 2
	n = pr.serializeSendMessageV2Request(req, packet[:]); process_protocol_payload(c, packet[:n])
	worker_db_test_pump(t); worker_db_test_dm_io_pump(t, c, store)
	worker_db_test_dm_io_frames(t, c, denied = 1802)
	testing.expect_value(t, store.wal.durable_record_count, u64(1))
	// Reopening followed immediately by send must see the committed start.
	worker_db_test_dm_request(c, .C_StartDM, "bob")
	req.correlation_id = 1803; req.client_message_id[0] = 3
	n = pr.serializeSendMessageV2Request(req, packet[:]); process_protocol_payload(c, packet[:n])
	worker_db_test_pump(t); worker_db_test_dm_io_pump(t, c, store)
	worker_db_test_dm_io_frames(t, c, ack = 1803)
	testing.expect_value(t, store.wal.durable_record_count, u64(2))
	// A history read admitted before leave must recheck ACL on async completion.
	n = pr.serializeMessageRangeRequest(.C_ListMessagesBefore, {conv_id = id, limit = 10, correlation_id = 1804}, packet[:])
	process_protocol_payload(c, packet[:n]); worker_db_test_dm_request(c, .C_LeaveDM, id = id)
	// Wait for executor results without servicing retained read CQEs.
	deadline := nrc_time_now()
	for len(td.database.pending) > 0 && time.since(deadline) < 5 * time.Second {_ = worker_db_drain(); time.sleep(time.Millisecond)}
	testing.expect_value(t, len(td.database.pending), 0)
	testing.expect(t, c.retained_io > 0, "history read must still be in flight when leave applies")
	worker_db_test_dm_io_pump(t, c, store)
	worker_db_test_dm_io_frames(t, c, denied = 1804, forbidden_page = 1804)
	// Conversely, a send authorized before leave retains its admitted write.
	worker_db_test_dm_request(c, .C_StartDM, "bob"); worker_db_test_pump(t)
	worker_db_test_dm_io_frames(t, c)
	req.correlation_id = 1805; req.client_message_id[0] = 5
	n = pr.serializeSendMessageV2Request(req, packet[:]); process_protocol_payload(c, packet[:n])
	worker_db_test_dm_request(c, .C_LeaveDM, id = id)
	deadline = nrc_time_now()
	for len(td.database.pending) > 0 && time.since(deadline) < 5 * time.Second {_ = worker_db_drain(); time.sleep(time.Millisecond)}
	testing.expect_value(t, len(td.database.pending), 0)
	testing.expect(t, c.retained_io > 0 && !validate_dm_access(c, id))
	worker_db_test_dm_io_pump(t, c, store)
	worker_db_test_dm_io_frames(t, c, ack = 1805)
	testing.expect_value(t, store.wal.durable_record_count, u64(3))
}

worker_db_test_dm_io_pump :: proc(t: ^testing.T, c: ^NRC_Connection, store: ^Message_Store) {
	deadline := nrc_time_now()
	for c.retained_io > 0 || store.write_in_flight || store.fsync_in_flight || store.wal.pending_bytes > 0 {
		_, ok := flush_pending_retained_message_writes(&td.message_stores); testing.expect(t, ok)
		_ = schedule_retained_message_fsync(store)
		_ = nbio.submit_pending(&td.io); _ = nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true)
		if time.since(deadline) > 5 * time.Second do testing.fail_now(t, "retained I/O did not finish")
	}
}

worker_db_test_dm_io_frames :: proc(t: ^testing.T, c: ^NRC_Connection, ack: u32 = 0, denied: u32 = 0, page: u32 = 0, forbidden_page: u32 = 0) {
	seen_ack, seen_denied, seen_page := false, false, false
	for send_queue_len(c) > 0 {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, h, _ := wire.readFrameHeader(frame); payload := frame[h:]
		#partial switch pr.get_opcode(payload) {
		case .S_AckSendMessage:
			r, e := pr.parseAckSendMessageMessage(payload); testing.expect(t, e == nil && ack != 0 && r.client_req_id == ack); seen_ack = true
		case .S_ErrorResponse:
			r, e := pr.parseErrorResponseMessage(payload); testing.expect(t, e == nil && denied != 0 && r.correlation_id == denied); seen_denied = true
		case .S_MessagePage:
			r, e := pr.parseMessagePage(payload[2:])
			testing.expect(t, e == nil && r.correlation_id != forbidden_page && page != 0 && r.correlation_id == page)
			testing.expect(t, len(r.messages) == 1 && string(r.messages[0].content) == "cold message")
			seen_page = true
		}
	}
	testing.expect_value(t, seen_ack, ack != 0); testing.expect_value(t, seen_denied, denied != 0); testing.expect_value(t, seen_page, page != 0)
}

init_dm_test_state :: proc() {
	td.thread_index = 99
	td.workspaces = make(map[string]^Workspace_State)
	strings.intern_init(&td.workspace_intern)
}

cleanup_dm_test_state :: proc() {
	cleanup_workspaces()
	strings.intern_destroy(&td.workspace_intern)
}

@(test)
test_dm_auth_index_tracks_authenticated_connections_unit :: proc(t: ^testing.T) {
	init_dm_test_state()
	defer cleanup_dm_test_state()

	ws := get_or_create_workspace("ws-auth-unit")
	username := intern_username("alice")

	on_user_connect(ws, username, false)
	testing.expect(t, !is_user_authenticated(ws, username), "unauthenticated connection should not mark user authenticated")

	on_user_connect(ws, username, true)
	testing.expect(t, is_user_authenticated(ws, username), "authenticated connection should mark user authenticated")

	on_user_disconnect(ws, username, false)
	testing.expect(t, is_user_authenticated(ws, username), "removing unauthenticated connection should not clear authenticated state")

	on_user_disconnect(ws, username, true)
	testing.expect(t, !is_user_authenticated(ws, username), "last authenticated connection should clear authenticated state")
}

@(test)
test_dm_auth_index_lifecycle_integration :: proc(t: ^testing.T) {
	init_dm_test_state()
	defer cleanup_dm_test_state()

	ws := get_or_create_workspace("ws-auth-e2e")
	username := intern_username("target-user")

	// Simulate three active connections for one user: two authenticated and one unauthenticated.
	on_user_connect(ws, username, true)
	on_user_connect(ws, username, true)
	on_user_connect(ws, username, false)

	testing.expect(t, find_user_in_workspace(ws, username), "user should exist while connected")
	testing.expect(t, is_user_online(ws, username), "user should be online while connected")
	testing.expect(t, is_user_authenticated(ws, username), "user should be authenticated while any authenticated connection exists")

	on_user_disconnect(ws, username, true)
	testing.expect(t, is_user_authenticated(ws, username), "one remaining authenticated connection should keep authenticated=true")
	testing.expect(t, is_user_online(ws, username), "user should remain online after one disconnect")

	on_user_disconnect(ws, username, true)
	testing.expect(t, !is_user_authenticated(ws, username), "no authenticated connections should set authenticated=false")
	testing.expect(t, is_user_online(ws, username), "unauthenticated connection should still keep user online")

	on_user_disconnect(ws, username, false)
	testing.expect(t, !is_user_online(ws, username), "user should be offline after all connections disconnect")
	testing.expect(t, !find_user_in_workspace(ws, username), "user should no longer exist in workspace when fully disconnected")
}
