package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

@(test)
test_sqlite_task_mutation_timestamps_follow_execution_order :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-task-timestamps-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	for opcode in ([2]pr.Opcode{.C_UpdateTask, .C_MoveTask}) {
		// A newer request has already committed at 200 before a delayed
		// request admitted at 100 reaches this same command boundary.
		task := pr.Task {
			id         = 7,
			title      = transmute([]byte)string("Task"),
			status     = .Todo,
			updated_at = 200,
		}
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, db.put_task(&store, "w", &task), sql.OK)
		testing.expect_value(t, db.commit(&store), sql.OK)
		for f in ([3]struct {
				admitted, expected: i64,
				status:             pr.TaskStatus,
			}{{100, 201, .Done}, {201, 202, .Todo}, {500, 500, .Done}}) {
			buffer: [1024]byte
			n: int
			if opcode == .C_UpdateTask {
				n = pr.serializeUpdateTaskRequest(
					{task_id = 7, status = f.status, priority = 255, color = transmute(pr.TaskColor)u8(255), preserve_attachments = true},
					buffer[:],
				)
			} else {
				n = pr.serializeMoveTaskRequest({task_id = 7, status = f.status}, buffer[:])
			}
			assert(n > 2)
			output := db.Command_Output {
				limit = 65536,
			}
			defer db.destroy_command_output(&output)
			request := db.Request {
				workspace = "w",
				actor     = "alice",
				opcode    = opcode,
				body      = buffer[2:n],
				timestamp = f.admitted,
			}
			testing.expect_value(t, db.begin(&store), sql.OK)
			testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
			testing.expect_value(t, db.commit(&store), sql.OK)
			actual, found, read_rc := db.get_task(&store, "w", 0, 7)
			defer db.destroy_task(&actual)
			testing.expect(t, read_rc == sql.OK && found)
			testing.expect_value(t, actual.updated_at, f.expected)
			testing.expect_value(t, actual.completed_at, f.status == .Done ? f.expected : 0)
			testing.expect_value(t, actual.status, f.status)
			// Overflow must reject the mutation without wrapping its version.
			if f.admitted == 500 {
				task = actual; task.updated_at = max(i64)
				testing.expect_value(t, db.begin(&store), sql.OK)
				testing.expect_value(t, db.put_task(&store, "w", &task), sql.OK)
				testing.expect_value(t, db.commit(&store), sql.OK)
				testing.expect_value(t, db.begin(&store), sql.OK)
				frames_before := output.count
				testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.FULL)
				testing.expect_value(t, output.count, frames_before)
				unchanged, exists, unchanged_rc := db.get_task(&store, "w", 0, 7)
				defer db.destroy_task(&unchanged)
				testing.expect(t, exists && unchanged_rc == sql.OK)
				testing.expect_value(t, unchanged.updated_at, max(i64))
				db.rollback(&store)
			}
		}
	}
}

worker_db_test_sqlite_task_delete :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks; DELETE FROM history; DELETE FROM history_sequences", nil, nil, nil),
		sql.OK,
	)
	attachments := [1]pr.Attachment{{file_id = transmute([]byte)string("cascade-file"), filename = transmute([]byte)string("proof")}}
	task := pr.Task {
		id          = 700,
		title       = transmute([]byte)string("Delete root"),
		attachments = attachments[:],
	}
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	testing.expect_value(t, db.put_task(&store, "foreign-delete", &task), sql.OK)
	task = {
		id         = 701,
		blocked_by = 700,
		title      = transmute([]byte)string("Keep dependent"),
	}
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	for f in ([?]struct {
			id:        u64,
			kind:      pr.ParentType,
			parent:    u64,
			workspace: string,
		}{{900, .Task, 700, c.workspace_id}, {901, .Asset, 900, c.workspace_id}, {700, .None, 0, c.workspace_id}, {900, .Task, 700, "foreign-delete"}}) {
		a := pr.Asset {
			asset_id    = f.id,
			asset_type  = .Note,
			parent_type = f.kind,
			parent_id   = f.parent,
			preview     = transmute([]byte)string(`{"title":"Child","tags":["cascade"]}`),
			attachments = attachments[:],
		}
		testing.expect_value(t, sqlite_put_asset(&store, f.workspace, &a), sql.OK)
	}
	for f in ([?]struct {
			id:        u64,
			source:    pr.TargetType,
			sid:       u64,
			target:    pr.TargetType,
			tid:       u64,
			workspace: string,
		}{{1, .Asset, 900, .Task, 700, c.workspace_id}, {2, .Task, 700, .Task, 701, c.workspace_id}, {3, .Asset, 700, .Task, 701, c.workspace_id}, {1, .Task, 700, .Asset, 900, "foreign-delete"}}) {
		key := pr.Asset {
			asset_id = f.id,
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,2,0,x'')",
				f.workspace,
				&key,
				{i64(f.source), f.sid, i64(f.target), f.tid},
			),
			sql.OK,
		)
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
	buffer: [64]byte
	n := pr.serializeDeleteTaskRequest(0, 700, buffer[:], 920)
	// Organizer rejection precedes all writes, including edge history.
	testing.expect_value(t, db.begin(&store), sql.OK)
	a := pr.Asset {
		asset_id    = 902,
		asset_type  = .Appointment,
		parent_type = .Task,
		parent_id   = 700,
		owner       = transmute([]byte)string("bob"),
		preview     = transmute([]byte)string(
			`{"version":2,"title":"Series","start_at":"1730000000000000000","end_at":"1730003600000000000","timezone":"UTC","repeat":"none","weekdays":[],"until":"","participants":[],"conference":"nrc","exceptions":[],"assignee":"bob"}`,
		),
	}
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &a), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	for blocked_by_acl in ([2]bool{true, false}) {
		if !blocked_by_acl {
			testing.expect_value(
				t,
				sql.exec(
					store.db,
					"DELETE FROM assets WHERE id=x'0000000000000386'; CREATE TRIGGER reject_task_delete BEFORE DELETE ON tasks BEGIN SELECT RAISE(ABORT,'fixture'); END",
					nil,
					nil,
					nil,
				),
				sql.OK,
			)
		}
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if testing.expect_value(t, send_queue_len(c), 1) {
			item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
			msg, err := pr.parseTaskListResponse(frame[offset:], nil, nil)
			testing.expect(
				t,
				err == nil &&
				!msg.success &&
				msg.correlation_id == 920 &&
				string(msg.error) == (blocked_by_acl ? "Deletion contains another organizer's appointment" : "Failed to change task"),
			)
		}
		testing.expect_value(t, send_queue_len(observer), 0)
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=3 FROM tasks")
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=4 FROM edges")
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=4 FROM note_metadata")
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM history")
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM history_sequences")
	}
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_task_delete", nil, nil, nil), sql.OK)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	for recipient in ([2]^NRC_Connection{c, observer}) {
		testing.expect_value(t, send_queue_len(recipient), recipient == c ? 4 : 5)
		assets := 0; edges := 0; deleted := false
		for send_queue_len(recipient) > 0 {
			item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
			frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame); body := frame[offset:]
			#partial switch pr.get_opcode(body) {
			case .S_EdgeDeleted:
				msg, err := pr.parseEdgeDeletedMessage(body); testing.expect(t, err == nil && msg.correlation_id == 0 && assets == 0 && !deleted)
				testing.expect_value(t, msg.edge_id, u64(edges + 1)); edges += 1
			case .S_AssetDeleted:
				msg, err := pr.parseAssetDeletedMessage(body); testing.expect(t, err == nil && msg.correlation_id == 0 && !deleted)
				testing.expect_value(t, msg.asset_id, assets == 0 ? u64(901) : 900); assets += 1
			case .S_TaskDeleted:
				msg, err := pr.parseTaskDeleted(body)
				testing.expect(t, err == nil && msg.task_id == 700 && msg.correlation_id == (recipient == c ? 920 : 0) && assets == 2)
				deleted = true
			case:
				testing.expect(t, false, "unexpected cascade frame")
			}
		}
		testing.expect(t, deleted && assets == 2 && edges == (recipient == c ? 1 : 2))
	}
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM tasks")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM tasks WHERE id=x'00000000000002bd' AND blocked_by=x'00000000000002bc'")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM assets")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM note_tags")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM task_attachments")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM asset_attachments")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=2 FROM edges")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=5 FROM history WHERE json_extract(body,'$.action')='deleted'")
	sqlite_projection_test_assert(
		t,
		&store,
		"SELECT count(*)=1 FROM history WHERE entity_kind=3 AND entity_id=x'0000000000000001' AND json_extract(body,'$.sourceLabel')='Child' AND json_extract(body,'$.targetLabel')='Delete root'",
	)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM history WHERE entity_kind=1 AND json_extract(body,'$.entityLabel')='Delete root'")
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
		msg, err := pr.parseTaskListResponse(
			frame[offset:],
			nil,
			nil,
		); testing.expect(t, err == nil && !msg.success && string(msg.error) == "Task not found" && msg.correlation_id == 920)
	}
	testing.expect_value(t, send_queue_len(observer), 0)
	// The prepared cascade is larger than the fixture's 4 KiB output budget.
	// It must commit and stream ordered events, including private audiences,
	// even when the initiating connection retires before completions arrive.
	for disconnected in ([2]bool{false, true}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		root := pr.Task {
			id    = 800,
			title = transmute([]byte)string("Spool cascade"),
		}
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &root), sql.OK)
		for i in 0 ..< 71 {
			child := pr.Asset {
				asset_id    = u64(10000 + i),
				asset_type  = i == 70 ? .Reminder : .Note,
				parent_type = .Task,
				parent_id   = 800,
				owner       = transmute([]byte)string("alice"),
				preview     = transmute([]byte)string(i == 70 ? `{"visibility":"personal","title":"Private"}` : `{}`),
			}
			testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &child), sql.OK)
		}
		testing.expect_value(t, db.commit(&store), sql.OK)
		n = pr.serializeDeleteTaskRequest(0, 800, buffer[:], 921)
		process_protocol_payload(c, buffer[:n])
		if disconnected do c.state = .Will_Close
		worker_db_test_pump(t)
		if disconnected do c.state = .New
		for recipient in ([2]^NRC_Connection{c, observer}) {
			children := recipient == observer ? 70 : 71
			expected := recipient == c && disconnected ? 0 : children + 1
			testing.expect_value(t, send_queue_len(recipient), expected)
			index := 0
			for send_queue_len(recipient) > 0 {
				item := send_queue_pop(recipient); defer frame_lease_dispose(&item.lease)
				frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
				if index < children {
					msg, err := pr.parseAssetDeletedMessage(frame[offset:])
					testing.expect(t, err == nil && msg.asset_id == u64(10000 + index) && msg.correlation_id == 0)
				} else {
					msg, err := pr.parseTaskDeleted(frame[offset:])
					testing.expect(t, err == nil && msg.task_id == 800 && msg.correlation_id == (recipient == c ? 921 : 0))
				}
				index += 1
			}
		}
		sqlite_projection_test_assert(
			t,
			&store,
			"SELECT NOT EXISTS(SELECT 1 FROM tasks WHERE id=x'0000000000000320') AND NOT EXISTS(SELECT 1 FROM assets WHERE parent_id=x'0000000000000320')",
		)
	}
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
}
