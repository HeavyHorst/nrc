package main

import "core:mem"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_asset_handlers :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"DELETE FROM assets; DELETE FROM history; DELETE FROM history_sequences; UPDATE sequences SET high_water=x'0000000000000064' WHERE domain='asset'",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	for f in ([4]struct {
			id:        u64,
			workspace: string,
			scope:     u64,
			at:        i64,
		}{{91, c.workspace_id, 0, 17}, {92, c.workspace_id, 0, 17}, {93, "foreign", 0, 19}, {94, c.workspace_id, 77, 20}}) {
		a := pr.Asset {
			asset_id   = f.id,
			conv_id    = f.scope,
			asset_type = .Note,
			owner      = transmute([]byte)string("alice"),
			preview    = transmute([]byte)string(`{"title":"seed","project":"sdk","tags":["one","two"]}`),
			updated_at = f.at,
		}
		testing.expect_value(t, sqlite_put_asset(&store, f.workspace, &a), f.scope == 0 ? sql.OK : sql.CONSTRAINT)
	}
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
	buffer: [8192]byte
	attachment := [1]pr.Attachment{{file_id = transmute([]byte)string("f1"), filename = transmute([]byte)string("bin"), size = max(u64)}}
	create := pr.CreateAssetRequest {
		asset_type      = .Note,
		preview         = transmute([]byte)string(`{"title":"created","project":"old","tags":["old"]}`),
		payload         = transmute([]byte)string("a\x00b"),
		payload_raw_len = 3,
		attachments     = attachment[:],
		correlation_id  = 801,
	}
	n := pr.serializeCreateAssetRequest(create, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); mem.zero(raw_data(buffer[:]), len(buffer)); worker_db_test_pump(t)
	created_at: i64
	for recipient in ([2]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
		item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		items: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		msg, err := pr.parseAssetCreatedMessage(frame[offset:], items[:])
		if testing.expect(t, err == nil && msg.asset.asset_id == 101 && string(msg.asset.payload) == "a\x00b" && len(msg.asset.attachments) == 1) {
			testing.expect(
				t,
				msg.asset.attachments[0].size == max(u64) && string(msg.asset.owner) == "alice" && msg.correlation_id == (recipient == c ? 801 : 0),
			)
			created_at = msg.asset.created_at
		}
	}
	update := pr.UpdateAssetRequest {
		asset_id        = 101,
		preview         = transmute([]byte)string(`{"title":"updated","project":"sdk","tags":["one"]}`),
		payload         = transmute([]byte)string("new"),
		payload_raw_len = 3,
		correlation_id  = 802,
	}
	n = pr.serializeUpdateAssetRequest(update, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	for recipient in ([2]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
		item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseAssetUpdatedMessage(frame[offset:])
		testing.expect(
			t,
			err == nil &&
			msg.asset.asset_id == 101 &&
			len(msg.asset.attachments) == 0 &&
			msg.asset.updated_at > created_at &&
			msg.asset.created_at == created_at,
		)
	}
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM note_tags WHERE tag=x'6f6c64'")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM history WHERE json_extract(body,'$.fields')='[\"preview\",\"payload\",\"attachments\"]'")
	// Inject a failure after the canonical row/projections, before history commit.
	testing.expect_value(
		t,
		sql.exec(store.db, "CREATE TRIGGER reject_asset_history BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil),
		sql.OK,
	)
	update.preview = transmute([]byte)string(`{"title":"must roll back","project":"bad"}`)
	n = pr.serializeUpdateAssetRequest(update, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	worker_db_test_asset_error(t, c, 802)
	testing.expect_value(t, send_queue_len(observer), 0)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM note_metadata WHERE project=x'626164'")
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_asset_history", nil, nil, nil), sql.OK)
	// A single frame exceeding the RAM budget must still roll back IDs and rows;
	// multiple individually bounded frames may now spill instead.
	large := make([]byte, 5000); defer delete(large)
	create.payload = large; create.payload_raw_len = u32(len(large)); create.correlation_id = 803
	n = pr.serializeCreateAssetRequest(create, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	worker_db_test_asset_error(t, c, 803)
	testing.expect_value(t, send_queue_len(observer), 0)
	sqlite_projection_test_assert(t, &store, "SELECT high_water=x'0000000000000065' FROM sequences WHERE domain='asset'")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM history")
	// Personal reminders never reach another user's subscription or totals.
	create = {
		asset_type      = .Reminder,
		preview         = transmute([]byte)string(`{"visibility":"personal"}`),
		payload         = transmute([]byte)string(`{"visibility":"personal"}`),
		payload_raw_len = 25,
		correlation_id  = 804,
	}
	n = pr.serializeCreateAssetRequest(create, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseAssetCreatedMessage(frame[offset:]); testing.expect(t, err == nil && msg.asset.asset_id == 102)
	}
	testing.expect_value(t, send_queue_len(observer), 0)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM history WHERE private_owner=x'616c696365'")
	for recipient in ([2]^NRC_Connection{c, observer}) {
		n = pr.serializeListAssetsPagedRequest(0, .Reminder, false, 0, false, 0, 0, buffer[:], 805); assert(n > 0)
		process_protocol_payload(recipient, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(recipient), 1) do continue
		item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		page, err := pr.parseAssetListPageMessage(frame[offset:]); defer delete(page.assets)
		testing.expect(t, err == nil && page.total_count == (recipient == c ? 1 : 0) && len(page.assets) == int(page.total_count))
	}
	// Global/project/tag pages share descending timestamps and unsigned ID ties.
	for opcode in ([3]pr.Opcode{.C_ListAssetsPaged, .C_ListAssetsPagedByProject, .C_ListAssetsPagedByTag}) {
		cursor_at: i64; cursor_id: u64
		for expected, i in ([3]u64{101, 92, 91}) {
			#partial switch opcode {
			case .C_ListAssetsPaged:
				n = pr.serializeListAssetsPagedRequest(0, .Note, false, 1, i > 0, cursor_at, cursor_id, buffer[:], 806)
			case .C_ListAssetsPagedByProject:
				n = pr.serializeListAssetsPagedByProjectRequest(0, .Note, false, 1, i > 0, cursor_at, cursor_id, "sdk", buffer[:], 806)
			case .C_ListAssetsPagedByTag:
				n = pr.serializeListAssetsPagedByTagRequest(0, .Note, false, 1, i > 0, cursor_at, cursor_id, "one", buffer[:], 806)
			}
			assert(n > 0); process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do continue
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			page, err := pr.parseAssetListPageMessage(frame[offset:]); defer delete(page.assets)
			if testing.expect(t, err == nil && len(page.assets) == 1 && page.total_count == 3 && page.has_more == (i < 2) && page.correlation_id == 806) {
				testing.expect_value(t, page.assets[0].asset_id, expected)
				cursor_at = page.next_cursor_updated_at; cursor_id = page.next_cursor_asset_id
			}
		}
		// A cursor note moved below its old timestamp must not appear again;
		// totals still include it. Also request a page after the final row.
		for empty in ([2]bool{false, true}) {
			at: i64 = empty ? 0 : 18
			#partial switch opcode {
			case .C_ListAssetsPaged:
				n = pr.serializeListAssetsPagedRequest(0, .Note, false, 1, true, at, 92, buffer[:], 806)
			case .C_ListAssetsPagedByProject:
				n = pr.serializeListAssetsPagedByProjectRequest(0, .Note, false, 1, true, at, 92, "sdk", buffer[:], 806)
			case .C_ListAssetsPagedByTag:
				n = pr.serializeListAssetsPagedByTagRequest(0, .Note, false, 1, true, at, 92, "one", buffer[:], 806)
			}
			assert(n > 0); process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do continue
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			page, err := pr.parseAssetListPageMessage(frame[offset:]); defer delete(page.assets)
			if testing.expect(t, err == nil && page.total_count == 3 && !page.has_more && len(page.assets) == (empty ? 0 : 1)) {
				if !empty do testing.expect_value(t, page.assets[0].asset_id, u64(91))
			}
		}
	}
	n = pr.serializeListAssetsRequest(0, true, .Note, false, buffer[:], 807); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		list, err := pr.parseAssetListMessage(frame[offset:]); defer delete(list.assets)
		testing.expect(t, err == nil && len(list.assets) == 3 && list.correlation_id == 807)
	}
	// Domain validation rejects writes without consuming an ID or publishing.
	for rejected in ([6]pr.CreateAssetRequest{{asset_type = .Appointment}, {asset_type = .Ticket}, {asset_type = .Slice}, {asset_type = .Note, parent_type = .Asset, parent_id = 102}, {asset_type = .Note, parent_type = .Asset, parent_id = 101, if_parent_updated_at = 1}, {asset_type = .Note, parent_type = .Task, parent_id = 999}}) {
		r := rejected; r.correlation_id = 808
		n = pr.serializeCreateAssetRequest(r, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		worker_db_test_asset_error(t, c, 808)
		testing.expect_value(t, send_queue_len(observer), 0)
	}
	update = {
		asset_id        = 102,
		preview         = transmute([]byte)string(`{"visibility":"team"}`),
		payload         = transmute([]byte)string(`{"visibility":"team"}`),
		payload_raw_len = 21,
		correlation_id  = 809,
	}
	n = pr.serializeUpdateAssetRequest(update, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 809)
	process_protocol_payload(observer, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, observer, 809)
	sqlite_projection_test_assert(t, &store, "SELECT high_water=x'0000000000000066' FROM sequences WHERE domain='asset'")
	// Room mapping creation is idempotent after normalization. Agenda creation
	// updates the sole existing agenda, preserving its stable asset ID.
	for kind, k in ([2]pr.AssetType{.RoomMapping, .Agenda}) {
		for i in 0 ..< 2 {
			create = {
				asset_type     = kind,
				preview        = transmute([]byte)string(i == 0 ? " #review-room " : "REVIEW-ROOM"),
				correlation_id = 810,
			}
			n = pr.serializeCreateAssetRequest(create, buffer[:]); assert(n > 0)
			process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if testing.expect_value(t, send_queue_len(c), 1) {
				item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
				frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
				if kind == .Agenda && i == 1 {
					msg, err := pr.parseAssetUpdatedMessage(frame[offset:]); testing.expect(t, err == nil && msg.asset.asset_id == u64(103 + k))
				} else {
					msg, err := pr.parseAssetCreatedMessage(frame[offset:]); testing.expect(t, err == nil && msg.asset.asset_id == u64(103 + k))
				}
			}
			broadcast_count := kind == .RoomMapping && i == 1 ? 0 : 1
			if testing.expect_value(t, send_queue_len(observer), broadcast_count) && broadcast_count > 0 {
				item := send_queue_pop(observer); frame_lease_dispose(&item.lease)
			}
		}
	}
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM room_mappings WHERE name=x'5245564945572d524f4f4d'")
	update = {
		asset_id       = 103,
		correlation_id = 811,
	}
	n = pr.serializeUpdateAssetRequest(update, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 811)
	testing.expect_value(t, send_queue_len(observer), 0)
	// The default count limit is secondary to the byte budget. Paging makes
	// progress even when only one full record fits; unpaged lists fail atomically.
	large = large[:3000]
	testing.expect_value(t, db.begin(&store), sql.OK)
	for id in ([2]u64{201, 202}) {
		a := pr.Asset {
			asset_id        = id,
			asset_type      = .Document,
			updated_at      = 29,
			payload         = large,
			payload_raw_len = u32(len(large)),
		}
		testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &a), sql.OK)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	for full in ([2]bool{false, true}) {
		n = pr.serializeListAssetsPagedRequest(0, .Document, full, 250, false, 0, 0, buffer[:], 812); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		page, err := pr.parseAssetListPageMessage(frame[offset:]); defer delete(page.assets)
		if testing.expect(t, err == nil && page.total_count == 2 && len(page.assets) == (full ? 1 : 2) && page.has_more == full) {
			testing.expect(t, page.next_cursor_asset_id == (full ? 202 : 201) && page.next_cursor_updated_at == 29)
		}
	}
	n = pr.serializeListAssetsRequest(0, true, .Document, true, buffer[:], 813); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 813)
	// Active-contact filtering uses the canonical preview parser, including its
	// strict version typing. IDs above 2^63 retain descending order.
	testing.expect_value(t, db.begin(&store), sql.OK)
	for preview, i in ([4]string{`{"version":1,"title":"A"}`, `{"version":1,"title":"B","archived":false}`, `{"version":"1","title":"wrong type"}`, `{"version":1,"title":"archived","archived":true}`}) {
		a := pr.Asset {
			asset_id   = max(u64) - u64(i),
			asset_type = .CustomerContact,
			updated_at = 37,
			preview    = transmute([]byte)preview,
		}
		testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &a), sql.OK)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	for active in ([2]bool{false, true}) {
		n = pr.serializeListAssetsPagedRequest(0, .CustomerContact, false, 50, false, 0, 0, buffer[:], 814); assert(n > 0)
		buffer[n] = active ? 1 : 0; n += 1
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		page, err := pr.parseAssetListPageMessage(frame[offset:]); defer delete(page.assets)
		if testing.expect(t, err == nil && page.total_count == (active ? 2 : 4) && len(page.assets) == int(page.total_count)) {
			for a, i in page.assets do testing.expect_value(t, a.asset_id, max(u64) - u64(i))
		}
	}
	worker_db_test_asset_delete(t, &store, c, observer)
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}

worker_db_test_asset_error :: proc(t: ^testing.T, c: ^NRC_Connection, correlation: u32) {
	if !testing.expect_value(t, send_queue_len(c), 1) do return
	item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
	e, err := pr.parseErrorResponseMessage(frame[offset:])
	testing.expect(t, err == nil && e.correlation_id == correlation)
}

worker_db_test_asset_delete :: proc(t: ^testing.T, store: ^db.Store, c, observer: ^NRC_Connection) {
	testing.expect_value(t, db.begin(store), sql.OK)
	for f in ([2]struct {
			id, parent: u64,
		}{{301, 101}, {302, 301}}) {
		a := pr.Asset {
			asset_id    = f.id,
			asset_type  = .Note,
			parent_type = .Asset,
			parent_id   = f.parent,
			preview     = transmute([]byte)string(`{"title":"child"}`),
		}
		testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &a), sql.OK)
	}
	// Incoming edges and self-loops must be emitted once, in unsigned ID order;
	// an unrelated edge must survive, and a dangling endpoint must not hide its edge.
	for f in ([5]struct {
			id, source, target: u64,
		}{{401, 101, 999}, {402, 302, 101}, {403, 91, 91}, {0x8000000000000000, 91, 301}, {0xffffffffffffffff, 302, 302}}) {
		key := pr.Asset {
			asset_id = f.id,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(store, "INSERT INTO edges VALUES(?1,?2,1,?3,1,?4,1,0,x'')", c.workspace_id, &key, {f.source, f.target}),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(store), sql.OK)
	buffer: [64]byte
	// A descendant's organizer ACL blocks the whole cascade, including edges.
	testing.expect_value(t, db.begin(store), sql.OK)
	appointment := pr.Asset {
		asset_id    = 303,
		asset_type  = .Appointment,
		parent_type = .Asset,
		parent_id   = 101,
		owner       = transmute([]byte)string("bob"),
		preview     = transmute([]byte)string(
			`{"version":2,"title":"Series","start_at":"1730000000000000000","end_at":"1730003600000000000","timezone":"UTC","repeat":"none","weekdays":[],"until":"","participants":[],"conference":"nrc","exceptions":[],"assignee":"bob"}`,
		),
	}
	testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &appointment), sql.OK)
	testing.expect_value(t, db.commit(store), sql.OK)
	for id in ([2]u64{101, 303}) {
		length := pr.serializeDeleteAssetRequest(0, id, buffer[:], 819)
		process_protocol_payload(c, buffer[:length]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 819)
		testing.expect_value(t, send_queue_len(observer), 0)
	}
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=4 FROM assets WHERE id IN (x'0000000000000065',x'000000000000012d',x'000000000000012e',x'000000000000012f')",
	)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM assets WHERE id=x'000000000000012f'", nil, nil, nil), sql.OK)
	n := pr.serializeDeleteAssetRequest(0, 101, buffer[:], 820)
	// Fail during the bulk edge delete and after child deletion. Neither may
	// publish the already prepared history/events or leave a partial cascade.
	for trigger in ([2]cstring{"CREATE TRIGGER reject_delete_history BEFORE DELETE ON edges WHEN OLD.id=x'0000000000000192' BEGIN SELECT RAISE(ABORT,'fixture'); END", "CREATE TRIGGER reject_delete_history BEFORE INSERT ON history WHEN NEW.entity_kind=2 AND NEW.entity_id=x'0000000000000065' AND json_extract(NEW.body,'$.action')='deleted' BEGIN SELECT RAISE(ABORT,'fixture'); END"}) {
		testing.expect_value(t, sql.exec(store.db, trigger, nil, nil, nil), sql.OK)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 820)
		testing.expect_value(t, send_queue_len(observer), 0)
		sqlite_projection_test_assert(t, store, "SELECT count(*)=3 FROM assets WHERE id IN (x'0000000000000065',x'000000000000012d',x'000000000000012e')")
		sqlite_projection_test_assert(
			t,
			store,
			"SELECT count(*)=4 FROM edges WHERE id IN (x'0000000000000191',x'0000000000000192',x'8000000000000000',x'ffffffffffffffff')",
		)
		sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM history WHERE json_extract(body,'$.action')='deleted'")
		testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_delete_history", nil, nil, nil), sql.OK)
	}
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	for recipient in ([2]^NRC_Connection{c, observer}) {
		if !testing.expect_value(t, send_queue_len(recipient), recipient == c ? 6 : 7) do continue
		asset_index := 0; edge_count := 0
		for send_queue_len(recipient) > 0 {
			item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			if pr.get_opcode(frame[offset:]) == .S_AssetDeleted {
				msg, err := pr.parseAssetDeletedMessage(frame[offset:])
				expected := [3]u64{302, 301, 101}
				if testing.expect(t, err == nil && asset_index < len(expected)) {
					testing.expect(
						t,
						msg.asset_id == expected[asset_index] && msg.correlation_id == (recipient == c && asset_index == 2 ? 820 : 0),
					); asset_index += 1
				}
			} else {
				msg, err := pr.parseEdgeDeletedMessage(frame[offset:])
				expected := [4]u64{401, 402, 0x8000000000000000, 0xffffffffffffffff}
				index := edge_count + (recipient == c ? 1 : 0)
				testing.expect(t, err == nil && index < len(expected) && msg.edge_id == expected[index])
				testing.expect_value(t, asset_index, 0)
				edge_count += 1
			}
		}
		testing.expect(t, asset_index == 3 && edge_count == (recipient == c ? 3 : 4))
	}
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM assets WHERE id IN (x'0000000000000065',x'000000000000012d',x'000000000000012e')")
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=0 FROM note_metadata WHERE asset_id IN (x'0000000000000065',x'000000000000012d',x'000000000000012e')",
	)
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=0 FROM edges WHERE id IN (x'0000000000000191',x'0000000000000192',x'8000000000000000',x'ffffffffffffffff')",
	)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=1 FROM edges WHERE id=x'0000000000000193'")
	sqlite_projection_test_assert(t, store, "SELECT count(*)=7 FROM history WHERE json_extract(body,'$.action')='deleted'")
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=1 FROM history WHERE entity_id=x'0000000000000192' AND source_kind=2 AND source_id=x'000000000000012e' AND target_kind=2 AND target_id=x'0000000000000065' AND json_extract(body,'$.sourceLabel')='child' AND json_extract(body,'$.targetLabel')='updated'",
	)
	sqlite_projection_test_assert(
		t,
		store,
		"SELECT count(*)=1 FROM history WHERE entity_kind=3 AND entity_id=x'0000000000000191' AND target_id=x'00000000000003e7' AND json_extract(body,'$.sourceLabel')='updated' AND coalesce(json_extract(body,'$.targetLabel'),'')='' AND coalesce(json_extract(body,'$.targetAssetType'),0)=0",
	)
	for id in ([2]u64{103, 999}) {
		n = pr.serializeDeleteAssetRequest(0, id, buffer[:], 821)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, c, 821)
	}
	n = pr.serializeDeleteAssetRequest(0, 102, buffer[:], 822)
	process_protocol_payload(observer, buffer[:n]); worker_db_test_pump(t); worker_db_test_asset_error(t, observer, 822)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseAssetDeletedMessage(frame[offset:]); testing.expect(t, err == nil && msg.asset_id == 102 && msg.correlation_id == 822)
	}
	testing.expect_value(t, send_queue_len(observer), 0)
	sqlite_projection_test_assert(t, store, "SELECT count(*)=1 FROM history WHERE private_owner=x'616c696365' AND json_extract(body,'$.action')='deleted'")
	// A large cascade spills its output and delivers every child before the root.
	testing.expect_value(t, db.begin(store), sql.OK)
	for id in u64(1000) ..< 1064 {
		a := pr.Asset {
			asset_id    = id,
			asset_type  = .Note,
			parent_type = .Asset,
			parent_id   = 201,
		}
		testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &a), sql.OK)
	}
	testing.expect_value(t, db.commit(store), sql.OK)
	n = pr.serializeDeleteAssetRequest(0, 201, buffer[:], 823)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	for recipient in ([2]^NRC_Connection{c, observer}) {
		testing.expect_value(t, send_queue_len(recipient), 65)
		index := 0
		for send_queue_len(recipient) > 0 {
			item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			msg, err := pr.parseAssetDeletedMessage(frame[offset:])
			testing.expect(t, err == nil && msg.asset_id == (index < 64 ? u64(1000 + index) : 201))
			testing.expect_value(t, msg.correlation_id, recipient == c && index == 64 ? u32(823) : 0)
			index += 1
		}
	}
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM assets WHERE parent_type=2 AND parent_id=x'00000000000000c9'")
	sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM assets WHERE id=x'00000000000000c9'")
	sqlite_projection_test_assert(t, store, "SELECT count(*)=73 FROM history WHERE json_extract(body,'$.action')='deleted'")
	// Schema-admissible legacy endpoints must keep the old reader contract.
	// Only the final case is valid: task titles and attachment names are not
	// restricted by the task reader's protocol-field limits.
	for fixture in ([?]struct {
			task, valid: bool,
			change:      cstring,
		}{{false, false, "UPDATE assets SET payload_raw_len=-1 WHERE id=x'0000000000001389'"}, {false, false, "UPDATE assets SET payload_raw_len=9223372036854775807 WHERE id=x'0000000000001389'"}, {false, false, "UPDATE assets SET owner=zeroblob(65) WHERE id=x'0000000000001389'"}, {false, false, "INSERT INTO asset_attachments SELECT workspace,id,0,x'66',zeroblob(257),zeroblob(8),x'',0 FROM assets WHERE id=x'0000000000001389'"}, {false, false, "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<10) INSERT INTO asset_attachments SELECT workspace,id,i,x'66',x'',zeroblob(8),x'',0 FROM assets,n WHERE id=x'0000000000001389'"}, {true, false, "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<10) INSERT INTO task_attachments SELECT workspace,id,i,x'66',x'',zeroblob(8),x'',0 FROM tasks,n WHERE id=x'0000000000001389'"}, {true, true, "UPDATE tasks SET title=CAST(printf('%0257d',0) AS BLOB) WHERE id=x'0000000000001389'; INSERT INTO task_attachments SELECT workspace,id,0,x'66',zeroblob(257),zeroblob(8),x'',0 FROM tasks WHERE id=x'0000000000001389'"}}) {
		testing.expect_value(t, db.begin(store), sql.OK)
		testing.expect_value(
			t,
			sql.exec(
				store.db,
				"DELETE FROM edges WHERE id=x'000000000000138a'; DELETE FROM assets WHERE id IN (x'0000000000001388',x'0000000000001389'); DELETE FROM tasks WHERE id=x'0000000000001389'; DELETE FROM history WHERE entity_id IN (x'0000000000001388',x'000000000000138a')",
				nil,
				nil,
				nil,
			),
			sql.OK,
		)
		for id in ([2]u64{5000, 5001}) {
			a := pr.Asset {
				asset_id   = id,
				asset_type = .Note,
				preview    = transmute([]byte)string(`{"title":"validation"}`),
			}
			testing.expect_value(t, sqlite_put_asset(store, c.workspace_id, &a), sql.OK)
		}
		task := pr.Task {
			id    = 5001,
			title = transmute([]byte)string("validation"),
		}
		testing.expect_value(t, db.put_task(store, c.workspace_id, &task), sql.OK)
		key := pr.Asset {
			asset_id = 5002,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				store,
				"INSERT INTO edges VALUES(?1,?2,1,?3,?4,?5,1,0,x'')",
				c.workspace_id,
				&key,
				{u64(5000), i64(fixture.task ? 2 : 1), u64(5001)},
			),
			sql.OK,
		)
		testing.expect_value(t, sql.exec(store.db, fixture.change, nil, nil, nil), sql.OK)
		testing.expect_value(t, db.commit(store), sql.OK)
		// The validation readers themselves allocate no owned record/attachment data.
		testing.expect_value(t, db.begin(store), sql.OK)
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		allocator := context.allocator
		context.allocator = mem.tracking_allocator(&tracker)
		read_rc := sql.OK
		if fixture.task {
			_, _, result := db.get_task(store, c.workspace_id, 0, 5001, validate_only = true); read_rc = result
		} else {
			_, _, result := sqlite_read_asset(
				store,
				c.workspace_id,
				c.verified_username,
				5001,
				false,
				check_visibility = false,
				validate_only = true,
			); read_rc = result
		}
		context.allocator = allocator
		testing.expect_value(t, db.rollback(store), sql.OK)
		testing.expect_value(t, tracker.peak_memory_allocated, 0)
		mem.tracking_allocator_destroy(&tracker)
		testing.expect_value(t, read_rc, fixture.valid ? sql.OK : sql.CORRUPT)
		n = pr.serializeDeleteAssetRequest(0, 5000, buffer[:], 824)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if fixture.valid {
			if testing.expect_value(t, send_queue_len(c), 1) {
				item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
				frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
				msg, err := pr.parseAssetDeletedMessage(frame[offset:])
				testing.expect(t, err == nil && msg.asset_id == 5000 && msg.correlation_id == 824)
			}
			testing.expect_value(t, send_queue_len(observer), 2)
			sqlite_projection_test_assert(
				t,
				store,
				"SELECT count(*)=1 FROM history WHERE entity_kind=3 AND entity_id=x'000000000000138a' AND json_extract(body,'$.targetLabel')=printf('%0256d',0)",
			)
		} else {
			worker_db_test_asset_error(t, c, 824)
			testing.expect_value(t, send_queue_len(observer), 0)
			sqlite_projection_test_assert(t, store, "SELECT count(*)=1 FROM assets WHERE id=x'0000000000001388'")
			sqlite_projection_test_assert(t, store, "SELECT count(*)=1 FROM edges WHERE id=x'000000000000138a'")
			sqlite_projection_test_assert(t, store, "SELECT count(*)=0 FROM history WHERE entity_id IN (x'0000000000001388',x'000000000000138a')")
		}
		for send_queue_len(observer) > 0 {item := send_queue_pop(observer); frame_lease_dispose(&item.lease)}
	}
}
