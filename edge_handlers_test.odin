package main

import "core:encoding/endian"
import "core:mem"
import "core:testing"

import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_sqlite_edges :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks; DELETE FROM history; DELETE FROM history_sequences; UPDATE sequences SET high_water=x'0000000000000064' WHERE domain='edge'",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	for id in ([2]u64{700, 701}) {
		task := pr.Task {
			id    = id,
			title = transmute([]byte)string("Task endpoint"),
		}
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	}
	foreign_task := pr.Task {
		id = 702,
	}
	testing.expect_value(t, db.put_task(&store, "foreign-edge", &foreign_task), sql.OK)
	a := pr.Asset {
		asset_id   = 700,
		asset_type = .Note,
		preview    = transmute([]byte)string(`{"title":"Asset endpoint"}`),
	}
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &a), sql.OK)
	a = {
		asset_id   = 950,
		asset_type = .Reminder,
		owner      = transmute([]byte)string("alice"),
		preview    = transmute([]byte)string(`{"visibility":"personal"}`),
	}
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &a), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	observer := connection_test_install_fake(
		{
			sock = connection_test_fake_socket(5),
			state = .Idle,
			workspace_id = c.workspace_id,
			authenticated = true,
			verified_username = "bob",
			init_send_queue = true,
		},
	)
	defer connection_test_uninstall(observer)
	observer.is_sending = true; subscribe_to_conversation(observer, 0)
	buffer: [128]byte
	create := pr.CreateEdgeRequest {
		source_type    = .Task,
		source_id      = 700,
		target_type    = .Asset,
		target_id      = 700,
		relation       = .MemberOf,
		correlation_id = 901,
	}
	for id in u64(101) ..= 103 {
		if id > 101 do create.relation = .RelatedTo
		n := pr.serializeCreateEdgeRequest(create, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); mem.zero(raw_data(buffer[:]), len(buffer)); worker_db_test_pump(t)
		for recipient in ([2]^NRC_Connection{c, observer}) {
			if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
			item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			msg, err := pr.parseEdgeCreatedMessage(frame[offset:])
			testing.expect(
				t,
				err == nil &&
				msg.edge.edge_id == id &&
				msg.edge.source_type == .Task &&
				msg.edge.target_type == .Asset &&
				msg.edge.source_id == 700 &&
				msg.edge.target_id == 700,
			)
			testing.expect(
				t,
				msg.edge.relation == create.relation &&
				string(msg.edge.created_by) == "alice" &&
				msg.edge.created_at > 0 &&
				msg.correlation_id == (recipient == c ? 901 : 0),
			)
		}
	}
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT count(*)=3 FROM history WHERE entity_kind=3 AND source_kind=1 AND target_kind=2 AND json_extract(body,'$.sourceLabel')='Task endpoint' AND json_extract(body,'$.targetLabel')='Asset endpoint' AND json_extract(body,'$.fields')='[\"source\",\"target\",\"relation\"]'",
	)
	for f in ([?]struct {
			source:   pr.TargetType,
			sid:      u64,
			target:   pr.TargetType,
			tid:      u64,
			relation: pr.RelationType,
			error:    string,
		}{{.Asset, 700, .Task, 700, .MemberOf, "Member is already assigned to this slice"}, {.Task, 700, .Asset, 700, .MemberOf, "Member is already assigned to this slice"}, {.Task, 700, .Task, 700, .RelatedTo, "Self-edge not allowed"}, {.Task, 702, .Task, 700, .RelatedTo, "Edge source entity not found"}, {.Task, 700, .Task, 702, .RelatedTo, "Edge target entity not found"}, {.Task, 700, .Asset, 950, .RelatedTo, "Personal reminders cannot have shared relations"}, {.Task, 700, .Asset, 700, pr.RelationType(0), "Invalid edge relation"}}) {
		n := pr.serializeCreateEdgeRequest(
			{source_type = f.source, source_id = f.sid, target_type = f.target, target_id = f.tid, relation = f.relation, correlation_id = 902},
			buffer[:],
		); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if testing.expect_value(t, send_queue_len(c), 1) {
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			msg, err := pr.parseErrorResponseMessage(
				frame[offset:],
			); testing.expect(t, err == nil && msg.correlation_id == 902 && string(msg.error_msg) == f.error)
		}
		testing.expect_value(t, send_queue_len(observer), 0)
	}
	// A history failure must roll back insertion/deletion and the sequence floor.
	testing.expect_value(
		t,
		sql.exec(store.db, "CREATE TRIGGER reject_edge_history BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil),
		sql.OK,
	)
	for deleting in ([2]bool{false, true}) {
		n := deleting ? pr.serializeDeleteEdgeRequest(0, 101, buffer[:], 901) : pr.serializeCreateEdgeRequest(create, buffer[:])
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 901)
		testing.expect_value(t, send_queue_len(observer), 0)
	}
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=3 FROM edges")
	sqlite_projection_test_assert(t, &store, "SELECT high_water=x'0000000000000067' FROM sequences WHERE domain='edge'")
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_edge_history", nil, nil, nil), sql.OK)
	n := pr.serializeDeleteEdgeRequest(0, 103, buffer[:], 903)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	for recipient in ([2]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
		item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseEdgeDeletedMessage(
			frame[offset:],
		); testing.expect(t, err == nil && msg.edge_id == 103 && msg.correlation_id == (recipient == c ? 903 : 0))
	}
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 903)
	// Disconnect after admission: commit still broadcasts, without a stale ACK.
	initiator := connection_test_install_fake(
		{sock = connection_test_fake_socket(6), state = .Idle, workspace_id = c.workspace_id, authenticated = true, verified_username = "alice"},
	)
	n = pr.serializeCreateEdgeRequest(
		create,
		buffer[:],
	); process_protocol_payload(initiator, buffer[:n]); connection_test_uninstall(initiator); worker_db_test_pump(t)
	for recipient in ([2]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
		item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseEdgeCreatedMessage(frame[offset:]); testing.expect(t, err == nil && msg.edge.edge_id == 104 && msg.correlation_id == 0)
	}
	worker_db_test_sqlite_edge_lists(t, c, &store)
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_sqlite_edge_lists :: proc(t: ^testing.T, c: ^NRC_Connection, store: ^db.Store) {
	testing.expect_value(t, db.begin(store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges", nil, nil, nil), sql.OK)
	// Mix endpoint directions, an imported self-edge, unsigned IDs, and a same-ID
	// task which is NOT the requested asset. No RAM graph is populated.
	for f in ([?]struct {
			id:     u64,
			source: pr.TargetType,
			sid:    u64,
			target: pr.TargetType,
			tid:    u64,
		}{{3, .Asset, 700, .Task, 701}, {5, .Task, 701, .Asset, 700}, {7, .Asset, 700, .Asset, 700}, {8, .Task, 700, .Task, 701}, {u64(1) << 63, .Asset, 700, .Task, 701}, {max(u64), .Task, 701, .Asset, 700}}) {
		key := pr.Asset {
			asset_id = f.id,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				store,
				"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,2,123,x'616c696365')",
				c.workspace_id,
				&key,
				{i64(f.source), f.sid, i64(f.target), f.tid},
			),
			sql.OK,
		)
	}
	key := pr.Asset {
		asset_id = 1,
	}
	testing.expect_value(
		t,
		sqlite_projection_write(store, "INSERT INTO edges VALUES(?1,?2,1,?3,2,?4,2,0,x'')", "foreign-edge", &key, {u64(700), u64(701)}),
		sql.OK,
	)
	testing.expect_value(t, db.commit(store), sql.OK)
	buffer: [128]byte
	for incident in ([2]bool{false, true}) {
		for f in ([?]struct {
				after: u64,
				ids:   []u64,
				more:  bool,
			}{{0, {3, 5}, true}, {5, {7}, true}, {8, {u64(1) << 63, max(u64)}, false}, {max(u64), {}, false}}) {
			// A one-item page at ID 5 has the same answer in both variants.
			limit: u16 = f.after == 5 ? 1 : 2
			n :=
				incident ? pr.serializeListEdgesPagedRequest({target_type = .Asset, target_id = 700, limit = limit, after_edge_id = f.after, correlation_id = 910}, buffer[:]) : pr.serializeListAllEdgesPagedRequest({limit = limit, after_edge_id = f.after, correlation_id = 910}, buffer[:])
			process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do continue
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame); body := frame[offset:]
			if !testing.expect(t, pr.get_opcode(body) == (incident ? .S_EdgeListPage : .S_AllEdgeListPage)) do continue
			base := incident ? 20 : 10
			cursor, _ := endian.get_u64(body[base + 1:], .Big); total, _ := endian.get_u32(body[base + 9:], .Big)
			count, _ := endian.get_u16(body[base + 13:], .Big); corr, _ := endian.get_u32(body[base + 15:], .Big)
			testing.expect(t, int(count) == len(f.ids) && body[base] == (f.more ? 1 : 0) && corr == 910 && total == (incident ? 5 : 6))
			testing.expect_value(t, cursor, len(f.ids) > 0 ? f.ids[len(f.ids) - 1] : 0)
			pos := base + 19
			for id in f.ids {
				actual, _ := endian.get_u64(body[pos:], .Big); testing.expect_value(t, actual, id)
				length, _ := endian.get_u16(body[pos + 46:], .Big); testing.expect_value(t, string(body[pos + 48:][:int(length)]), "alice")
				pos += 48 + int(length)
			}
			testing.expect_value(t, pos, len(body))
		}
		n :=
			incident ? pr.serializeListEdgesRequest({target_type = .Asset, target_id = 700, correlation_id = 911}, buffer[:]) : pr.serializeListAllEdgesRequest({correlation_id = 911}, buffer[:])
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		edges: [6]pr.Edge
		if incident {
			msg, err := pr.parseEdgeListMessage(
				frame[offset:],
				edges[:],
			); testing.expect(t, err == nil && len(msg.edges) == 5 && msg.target_type == .Asset && msg.target_id == 700 && msg.correlation_id == 911)
		} else {
			msg, err := pr.parseAllEdgeListMessage(frame[offset:], edges[:]); testing.expect(t, err == nil && len(msg.edges) == 6 && msg.correlation_id == 911)
		}
	}
	// The test output credit is 4 KiB: two large creator fields split a page.
	testing.expect_value(
		t,
		sql.exec(store.db, "UPDATE edges SET created_by=zeroblob(2200) WHERE id IN(x'0000000000000003',x'0000000000000005')", nil, nil, nil),
		sql.OK,
	)
	n := pr.serializeListAllEdgesPagedRequest({limit = 10, correlation_id = 912}, buffer[:]); process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		edges: [2]pr.Edge; page, err := pr.parseAllEdgeListPageMessage(frame[offset:], edges[:]); testing.expect(t, err == nil && page.has_more && len(page.edges) == 1 && page.next_edge_id == 3 && page.total_count == 6)
	}
	n = pr.serializeListAllEdgesRequest(
		{correlation_id = 913},
		buffer[:],
	); process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 913)
	// An empty incident set is a valid empty page, not a missing-entity error.
	n = pr.serializeListEdgesPagedRequest(
		{target_type = .Asset, target_id = 999, correlation_id = 914},
		buffer[:],
	); process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		testing.expect(t, len(frame[offset:]) == 39 && pr.get_opcode(frame[offset:]) == .S_EdgeListPage)
	}
}
