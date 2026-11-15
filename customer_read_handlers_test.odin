package main

import "core:encoding/endian"
import "core:testing"

import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_customer_search :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets", nil, nil, nil), sql.OK)
	for f in ([?]struct {
			id:      u64,
			kind:    pr.AssetType,
			preview: string,
		}{{10, .CustomerCompany, `{"version":1,"title":"Delta"}`}, {20, .CustomerCompany, `{"version":1,"title":"Beta"}`}, {30, .CustomerCompany, `{"version":1,"title":"Archived","archived":true}`}, {40, .CustomerCompany, `{"version":2,"title":"Invalid"}`}, {50, .CustomerContact, `{"version":1,"title":"ÄNNE","email":"person@example.test","archived":true}`}, {60, .CustomerActivity, `{"version":1,"title":"Activity"}`}, {max(u64), .CustomerCompany, `{"version":1,"title":"Omega"}`}}) {
		a := pr.Asset {
			asset_id        = f.id,
			asset_type      = f.kind,
			preview         = transmute([]byte)f.preview,
			payload         = transmute([]byte)string("not a header"),
			payload_raw_len = 12,
		}
		testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &a), sql.OK)
	}
	for f in ([?]struct {
			id, source, target: u64,
			relation:           pr.RelationType,
			workspace:          string,
		}{{1, 50, 10, .MemberOf, c.workspace_id}, {2, 20, 50, .MemberOf, c.workspace_id}, {3, 50, 30, .MemberOf, c.workspace_id}, {4, 50, max(u64), .RelatedTo, c.workspace_id}, {5, 60, max(u64), .MemberOf, c.workspace_id}, {6, 50, max(u64), .MemberOf, "foreign"}}) {
		key := pr.Asset {
			asset_id = f.id,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(&store, "INSERT INTO edges VALUES(?1,?2,1,?3,1,?4,?5,0,x'')", f.workspace, &key, {f.source, f.target, i64(f.relation)}),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	for f, index in ([?]struct {
			query:    string,
			archived: bool,
			after:    u64,
			limit:    u16,
			ids:      []u64,
			total:    u32,
			more:     bool,
		}{{"", false, 0, 0, {10, 20, max(u64)}, 3, false}, {"", true, 0, 250, {10, 20, 30, max(u64)}, 4, false}, {"ÄNNE", false, 0, 1, {10}, 2, true}, {"änne", false, 10, 1, {20}, 2, false}, {"person@", true, 0, 250, {10, 20, 30}, 3, false}, {"50", false, 0, 250, {}, 0, false}, {"activity", false, 0, 250, {}, 0, false}, {"18446744073709551615", false, 0, 250, {max(u64)}, 1, false}, {"", false, max(u64), 250, {}, 3, false}}) {
		request := pr.SearchCustomersRequest {
			query            = transmute([]byte)f.query,
			include_archived = f.archived,
			after_company_id = f.after,
			limit            = f.limit,
			correlation_id   = u32(700 + index),
		}
		buffer: [512]byte
		n := pr.serializeSearchCustomersRequest(request, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, header, _ := ws.readFrameHeader(frame)
		payload := frame[header:]
		if !testing.expect(t, len(payload) >= 29 && pr.get_opcode(payload) == .S_CustomerSearchPage) do continue
		total, _ := endian.get_u32(payload[19:], .Big); count, _ := endian.get_u16(payload[23:], .Big)
		correlation, _ := endian.get_u32(payload[25:], .Big); next, _ := endian.get_u64(payload[11:], .Big)
		testing.expect_value(t, total, f.total); testing.expect_value(t, int(count), len(f.ids))
		testing.expect_value(t, correlation, request.correlation_id); testing.expect_value(t, payload[10] != 0, f.more)
		testing.expect_value(t, next, len(f.ids) == 0 ? 0 : f.ids[len(f.ids) - 1])
		offset := 29
		for id in f.ids {
			a, end, err := pr.parseAssetHeaderFromPayload(payload, offset, false)
			if !testing.expect(t, err == nil) do break
			testing.expect_value(t, a.asset_id, id); testing.expect(t, len(a.payload) == 0)
			offset = end + 2
		}
		testing.expect_value(t, offset, len(payload))
	}
	// One header fits exactly; one byte less must return an error rather than
	// an empty continuation page. Counting must still include later matches.
	request := pr.SearchCustomersRequest {
		limit          = 250,
		correlation_id = 750,
	}
	buffer: [64]byte
	n := pr.serializeSearchCustomersRequest(request, buffer[:]); assert(n > 0)
	first := pr.Asset {
		preview = transmute([]byte)string(`{"version":1,"title":"Delta"}`),
	}
	for smaller in 0 ..< 2 {
		output := db.Command_Output {
			limit = size_of(db.Command_Frame) + 29 + pr.getSizeAssetHeader(first) - smaller,
		}
		defer db.destroy_command_output(&output)
		job := db.Request {
			opcode    = .C_SearchCustomers,
			workspace = c.workspace_id,
			actor     = "alice",
			body      = buffer[2:n],
		}
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &job, &output), sql.OK)
		testing.expect_value(t, db.commit(&store), sql.OK)
		if !testing.expect_value(t, output.count, 1) do continue
		testing.expect(t, output.bytes <= output.limit)
		payload := output.frames[0].payload
		if smaller == 0 {
			testing.expect_value(t, pr.get_opcode(payload), pr.Opcode.S_CustomerSearchPage)
			count, _ := endian.get_u16(payload[23:], .Big); total, _ := endian.get_u32(payload[19:], .Big)
			next, _ := endian.get_u64(payload[11:], .Big)
			testing.expect(t, count == 1 && total == 3 && next == 10 && payload[10] == 1)
		} else {
			err, parse_err := pr.parseErrorResponseMessage(payload)
			testing.expect(t, parse_err == nil && err.origin_opcode == .C_SearchCustomers && err.correlation_id == 750)
			testing.expect_value(t, string(err.error_msg), "Company exceeds page byte limit")
		}
	}
	c.authenticated = false
	process_protocol_payload(c, buffer[:n]); c.authenticated = true
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, header, _ := ws.readFrameHeader(frame)
		err, parse_err := pr.parseErrorResponseMessage(frame[header:])
		testing.expect(t, parse_err == nil && err.origin_opcode == .C_SearchCustomers && err.correlation_id == 750)
		testing.expect_value(t, string(err.error_msg), "Access denied")
	}
}
