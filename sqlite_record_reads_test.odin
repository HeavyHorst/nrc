package main

import "core:mem"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_record_reads :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM tasks; DELETE FROM assets", nil, nil, nil), sql.OK)
	for f in ([?]struct {
			id:                        u64,
			scope:                     u64,
			workspace, owner, preview: string,
			kind:                      pr.AssetType,
		}{{7, 0, c.workspace_id, "alice", `{"title":"note"}`, .Note}, {8, 0, c.workspace_id, "alice", `{"visibility":"personal"}`, .Reminder}, {9, 0, c.workspace_id, "bob", `{"visibility":"personal"}`, .Reminder}, {10, 0, "foreign", "alice", `{}`, .Note}, {11, 77, c.workspace_id, "alice", `{}`, .Note}}) {
		a := pr.Asset {
			asset_id = f.id,
			conv_id  = f.scope,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO assets VALUES(?1,?2,?3,0,x'0000000000000000',?4,17,29,0,3,?5,x'610062')",
				f.workspace,
				&a,
				{i64(f.kind), f.owner, f.preview},
			),
			f.scope == 0 ? sql.OK : sql.CONSTRAINT,
		)
		if f.id == 7 || f.id == 8 {
			task := pr.Task {
				id    = f.id,
				title = transmute([]byte)f.owner,
			}
			testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
		}
	}
	asset := pr.Asset {
		asset_id = 7,
	}
	testing.expect_value(
		t,
		sqlite_projection_write(
			&store,
			"INSERT INTO asset_attachments VALUES(?1,?2,0,x'66696c65',x'612e62696e',x'ffffffffffffffff',x'6170706c69636174696f6e2f6f637465742d73747265616d',-9)",
			c.workspace_id,
			&asset,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	buffer: [1024]byte
	ids := [7]u64{9, 7, 10, 8, 7, 11, 999}
	for opcode in ([2]pr.Opcode{.C_GetTasksByIDs, .C_GetAssetsByIDs}) {
		for full in ([2]bool{false, true}) {
			n := pr.serializeGetRecordsByIDsRequest({ids = ids[:], full_content = full, correlation_id = 701}, buffer[:], opcode); assert(n > 0)
			process_protocol_payload(c, buffer[:n]); mem.zero(raw_data(buffer[:]), len(buffer)); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do continue
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			if opcode == .C_GetAssetsByIDs {
				page, err := pr.parseAssetListPageMessage(frame[offset:], attachments = attachments[:]); defer delete(page.assets)
				if !testing.expect(t, err == nil && page.total_count == 2 && len(page.assets) == 2 && !page.has_more && page.correlation_id == 701) do continue
				testing.expect(t, page.assets[0].asset_id == 7 && page.assets[1].asset_id == 8 && page.full_content == full)
				testing.expect_value(t, string(page.assets[0].payload), full ? "a\x00b" : "")
				if testing.expect_value(t, len(page.assets[0].attachments), 1) do testing.expect_value(t, page.assets[0].attachments[0].size, max(u64))
			} else {
				tasks: [2]pr.Task
				page, err := pr.parseTaskListPage(frame[offset:], tasks[:], attachments[:])
				if testing.expect(t, err == nil && len(page.tasks) == 2 && page.total_count == 2 && page.success && page.correlation_id == 701) {
					testing.expect(t, page.tasks[0].id == 7 && page.tasks[1].id == 8 && !page.has_more)
				}
			}
		}
	}
	// Empty and missing-only batches still return one successful empty page.
	missing := [2]u64{999, 999}
	for opcode in ([2]pr.Opcode{.C_GetTasksByIDs, .C_GetAssetsByIDs}) {
		for requested in ([2][]u64{nil, missing[:]}) {
			n := pr.serializeGetRecordsByIDsRequest({ids = requested, correlation_id = 704}, buffer[:], opcode)
			assert(n > 0)
			process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
			if !testing.expect_value(t, send_queue_len(c), 1) do continue
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			if opcode == .C_GetAssetsByIDs {
				page, err := pr.parseAssetListPageMessage(frame[offset:]); defer delete(page.assets)
				testing.expect(t, err == nil && len(page.assets) == 0 && page.total_count == 0 && !page.has_more && page.correlation_id == 704)
			} else {
				page, err := pr.parseTaskListPage(frame[offset:], nil, nil)
				testing.expect(t, err == nil && page.success && len(page.tasks) == 0 && page.total_count == 0 && !page.has_more && page.correlation_id == 704)
			}
		}
	}
	for id in ([4]u64{7, 8, 9, 999}) {
		n := pr.serializeGetAssetRequest(0, id, buffer[:], 702); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		if id == 9 || id == 999 {
			e, err := pr.parseErrorResponseMessage(frame[offset:])
			testing.expect(t, err == nil && e.correlation_id == 702 && string(e.error_msg) == "Asset not found")
		} else {
			attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
			response, err := pr.parseAssetFullMessage(frame[offset:], attachments[:])
			testing.expect(t, err == nil && response.asset.asset_id == id && response.correlation_id == 702 && string(response.asset.payload) == "a\x00b")
		}
	}
	// Three full payloads require two protocol chunks. Use the same command
	// callback and SQLite transaction with a larger output budget for this case.
	large := make([]byte, 65000); defer delete(large)
	for &b in large do b = 0xa5
	testing.expect_value(t, db.begin(&store), sql.OK)
	for id in ([3]u64{21, 22, 23}) {
		a := pr.Asset {
			asset_id = id,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO assets VALUES(?1,?2,5,0,x'0000000000000000',x'616c696365',1,2,0,65000,x'7b7d',?3)",
				c.workspace_id,
				&a,
				{string(large)},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	big_ids := [3]u64{23, 21, 22}
	n := pr.serializeGetRecordsByIDsRequest({ids = big_ids[:], full_content = true, correlation_id = 703}, buffer[:], .C_GetAssetsByIDs); assert(n > 0)
	testing.expect_value(t, db.begin(&store), sql.OK)
	output := db.Command_Output {
		limit = 300000,
	}
	defer db.destroy_command_output(&output)
	testing.expect_value(
		t,
		sqlite_execute_task_command(&store, &db.Request{workspace = c.workspace_id, actor = "alice", opcode = .C_GetAssetsByIDs, body = buffer[2:n]}, &output),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	if testing.expect_value(t, output.count, 2) {
		seen := 0
		for f, i in output.frames[:output.count] {
			page, err := pr.parseAssetListPageMessage(f.payload); defer delete(page.assets)
			testing.expect(t, err == nil && page.total_count == 3 && page.has_more == (i == 0) && page.correlation_id == 703)
			for a in page.assets {
				testing.expect_value(t, a.asset_id, big_ids[seen]); seen += 1
				testing.expect_value(t, string(a.payload), string(large))
			}
		}
		testing.expect_value(t, seen, 3)
	}
	// The worker's tiny test budget rejects the whole response, never a prefix.
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		e, err := pr.parseErrorResponseMessage(frame[offset:]); testing.expect(t, err == nil && e.correlation_id == 703)
	}
	// Header-only retrieval of the same large records fits the worker budget.
	n = pr.serializeGetRecordsByIDsRequest({ids = big_ids[:], full_content = false, correlation_id = 705}, buffer[:], .C_GetAssetsByIDs)
	assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		page, err := pr.parseAssetListPageMessage(frame[offset:]); defer delete(page.assets)
		if testing.expect(
			t,
			err == nil && len(page.assets) == 3 && page.total_count == 3 && !page.has_more && !page.full_content && page.correlation_id == 705,
		) {
			for a, i in page.assets do testing.expect(t, a.asset_id == big_ids[i] && len(a.payload) == 0 && a.payload_raw_len == 65000)
		}
	}
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}
