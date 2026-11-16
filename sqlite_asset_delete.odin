package main

import "core:c"
import "core:fmt"
import "core:mem/virtual"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

MAX_DELETE_RECORDS :: 1024
MAX_DELETE_SLICES :: 16

// All callers count distinct tasks, assets and edges, including cascades.
sqlite_delete_limit_check :: proc(store: ^db.Store, workspace: string, query: cstring, extra: i64 = 0) -> (edges: u64, rc: c.int) {
	s: ^sql.Statement
	rc = sql.prepare_v2(store.db, query, -1, &s, nil); if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_int64(s, 2, i64(pr.AssetType.Slice)); rc != sql.OK do return
	if rc = sql.bind_int64(s, 3, extra); rc != sql.OK do return
	rc = sql.step(s); if rc != sql.ROW do return
	if sql.column_int64(s, 0) > MAX_DELETE_RECORDS || sql.column_int64(s, 1) > MAX_DELETE_SLICES do return 0, sql.CONSTRAINT
	return u64(sql.column_int64(s, 2)), sql.OK
}

SQLITE_DELETE_COUNTS :: `SELECT
 (SELECT count(*) FROM temp.nrc_asset_delete)+(SELECT count(*) FROM temp.nrc_edge_delete)+?3,
 (SELECT count(*) FROM temp.nrc_asset_delete d CROSS JOIN assets a ON a.workspace=?1 AND a.id=d.id WHERE a.asset_type=?2),
 (SELECT count(*) FROM temp.nrc_edge_delete)`

sqlite_delete_record :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output, transaction_batch := false) -> c.int {
	task_root := request.opcode == .C_DeleteTask
	root_id: u64
	correlation: u32
	if task_root {
		req, err := pr.parseDeleteTaskRequest(request.body)
		if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
		root_id = req.task_id; correlation = req.correlation_id
	} else {
		req, err := pr.parseDeleteAssetRequest(request.body)
		if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
		root_id = req.asset_id; correlation = req.correlation_id
	}
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	rc := sql.OK
	error_text := ""
	if task_root {
		_, found, read_rc := db.get_task(store, request.workspace, 0, root_id)
		if read_rc != sql.OK do return read_rc
		if !found do error_text = "Task not found"
	} else {
		root, found, read_rc := sqlite_read_asset(store, request.workspace, request.actor, root_id, false)
		if read_rc != sql.OK do return read_rc
		if !found {error_text = "Asset not found"} else if root.asset_type == .RoomMapping {error_text = "Room mappings are immutable"} else if !appointment_mutation_allowed(&root, nil, request.actor) {error_text = "Only the organizer may delete this appointment"}
		if found && (root.asset_type == .Monitor || root.asset_type == .Incident) do error_text = "Monitoring records cannot be deleted; disable the monitor instead"
		if found && monitoring_is_webhook_route(&root) do error_text = "Webhook routes are immutable"
	}
	if error_text != "" {
		if transaction_batch do return sql.CONSTRAINT
		context.allocator = backing
		return sqlite_command_error(output, request.opcode, correlation, error_text)
	}
	// Only IDs and pending-child counts enter the disk-backed temp table. UNION terminates even for an
	// imported parent cycle. Canonical rows remain untouched during preflight.
	rc = sql.exec(
		store.db,
		"CREATE TEMP TABLE IF NOT EXISTS nrc_asset_delete(id BLOB PRIMARY KEY,pending INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS temp.nrc_asset_delete_pending ON nrc_asset_delete(pending,id); DELETE FROM temp.nrc_asset_delete; CREATE TEMP TABLE IF NOT EXISTS nrc_edge_delete(id BLOB PRIMARY KEY) WITHOUT ROWID; DELETE FROM temp.nrc_edge_delete",
		nil,
		nil,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.exec(store.db, "DROP TABLE IF EXISTS temp.nrc_edge_delete; DROP TABLE IF EXISTS temp.nrc_asset_delete", nil, nil, nil)
	key := pr.Asset {
		asset_id = root_id,
	}
	// Drive indexed lookups from the small deletion frontier, not all asset parents.
	seed: cstring = `WITH RECURSIVE descendants(id) AS (
 SELECT ?2 UNION SELECT a.id FROM descendants d CROSS JOIN assets a INDEXED BY assets_parent ON a.parent_id=d.id
 WHERE a.workspace=?1 AND a.parent_type=2 LIMIT ?3)
 INSERT INTO temp.nrc_asset_delete(id) SELECT id FROM descendants`
	if task_root do seed = `WITH RECURSIVE descendants(id) AS (
 SELECT id FROM assets WHERE workspace=?1 AND parent_type=1 AND parent_id=?2
 UNION SELECT a.id FROM descendants d CROSS JOIN assets a INDEXED BY assets_parent ON a.parent_id=d.id
 WHERE a.workspace=?1 AND a.parent_type=2 LIMIT ?3)
 INSERT INTO temp.nrc_asset_delete(id) SELECT id FROM descendants`
	rc = sqlite_projection_write(store, seed, request.workspace, &key, {i64(MAX_DELETE_RECORDS + 1)})
	if rc != sql.OK do return rc
	_, rc = sqlite_delete_limit_check(store, request.workspace, SQLITE_DELETE_COUNTS, task_root ? 1 : 0)
	if rc == sql.CONSTRAINT &&
	   !transaction_batch {context.allocator = backing; return sqlite_command_error(output, request.opcode, correlation, "Deletion limit exceeded: at most 16 slices and 1024 records including cascades and edges")}
	if rc != sql.OK do return rc
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			"UPDATE temp.nrc_asset_delete AS d SET pending=(SELECT count(*) FROM assets a WHERE a.workspace=?1 AND a.parent_type=2 AND a.parent_id=d.id)",
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.DONE do return rc
	}
	// Authorization is checked for the whole cascade before any history/write.
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT id FROM temp.nrc_asset_delete", -1, &s, nil); if rc != sql.OK do return rc
		defer sql.finalize(s)
		for {
			virtual.arena_free_all(&arena)
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
			a, exists, read_rc := sqlite_read_asset(store, request.workspace, request.actor, id, false, check_visibility = false)
			if read_rc != sql.OK do return read_rc
			if !exists do return sql.CORRUPT
			if !appointment_mutation_allowed(&a, nil, request.actor) {
				if transaction_batch do return sql.CONSTRAINT
				context.allocator = backing
				return sqlite_command_error(output, request.opcode, correlation, "Deletion contains another organizer's appointment")
			}
		}
	}
	// Edge history resolves labels while every endpoint still exists; duplicate
	// incident edges are removed once, after finishing the read cursor.
	// Collect via endpoint indexes once, instead of rescanning the workspace's
	// edge-ID range for every next match. Only IDs enter the disk-backed set.
	rc = sqlite_projection_write(
		store,
		`INSERT INTO temp.nrc_edge_delete
 SELECT id FROM (SELECT e.id FROM temp.nrc_asset_delete d CROSS JOIN edges e INDEXED BY edges_source_page
 ON e.workspace=?1 AND e.source_type=1 AND e.source_id=d.id LIMIT ?4)
 UNION
 SELECT id FROM (SELECT e.id FROM temp.nrc_asset_delete d CROSS JOIN edges e INDEXED BY edges_target_page
 ON e.workspace=?1 AND e.target_type=1 AND e.target_id=d.id LIMIT ?4)
 UNION
 SELECT id FROM (SELECT id FROM edges INDEXED BY edges_source_page WHERE ?3 AND workspace=?1 AND source_type=2 AND source_id=?2 LIMIT ?4)
 UNION
 SELECT id FROM (SELECT id FROM edges INDEXED BY edges_target_page WHERE ?3 AND workspace=?1 AND target_type=2 AND target_id=?2 LIMIT ?4)
 LIMIT ?4`,
		request.workspace,
		&key,
		{i64(task_root ? 1 : 0), i64(MAX_DELETE_RECORDS + 1)},
	)
	if rc != sql.OK do return rc
	edge_count: u64
	edge_count, rc = sqlite_delete_limit_check(store, request.workspace, SQLITE_DELETE_COUNTS, task_root ? 1 : 0)
	if rc == sql.CONSTRAINT &&
	   !transaction_batch {context.allocator = backing; return sqlite_command_error(output, request.opcode, correlation, "Deletion limit exceeded: at most 16 slices and 1024 records including cascades and edges")}
	if rc != sql.OK do return rc
	// Preserve the record readers' checks without copying complete records.
	// UNION validates repeated endpoints once; cascade assets passed preflight.
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			`SELECT kind,id FROM (
 SELECT e.source_type AS kind,e.source_id AS id FROM temp.nrc_edge_delete d CROSS JOIN edges e ON e.workspace=?1 AND e.id=d.id
 UNION SELECT e.target_type,e.target_id FROM temp.nrc_edge_delete d CROSS JOIN edges e ON e.workspace=?1 AND e.id=d.id
 ) WHERE kind!=1 OR id NOT IN (SELECT id FROM temp.nrc_asset_delete)`,
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			id, id_rc := sql.column_id(s, 1); if id_rc != sql.OK do return id_rc
			if pr.TargetType(sql.column_int64(s, 0)) == .Task {
				_, _, read_rc := db.get_task(store, request.workspace, 0, id, validate_only = true)
				if read_rc != sql.OK do return read_rc
			} else {
				_, _, read_rc := sqlite_read_asset(store, request.workspace, request.actor, id, false, check_visibility = false, validate_only = true)
				if read_rc != sql.OK do return read_rc
			}
		}
	}
	history_batch, history_rc := db.begin_history_batch(store, request.workspace, edge_count)
	if history_rc != sql.OK do return history_rc
	defer sql.finalize(history_batch.insert)
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			`SELECT e.id,source_type,source_id,target_type,target_id,
 ((source_type=1 AND (?3=1 OR source_id!=?2) AND source_id IN (SELECT id FROM temp.nrc_asset_delete)) OR
 (target_type=1 AND (?3=1 OR target_id!=?2) AND target_id IN (SELECT id FROM temp.nrc_asset_delete))),
 st.title,sa.id,sa.asset_type,sa.preview,tt.title,ta.id,ta.asset_type,ta.preview
 FROM temp.nrc_edge_delete d CROSS JOIN edges e ON e.workspace=?1 AND e.id=d.id
 LEFT JOIN tasks st ON e.source_type=2 AND st.workspace=?1 AND st.id=e.source_id
 LEFT JOIN assets sa ON e.source_type=1 AND sa.workspace=?1 AND sa.id=e.source_id
 LEFT JOIN tasks tt ON e.target_type=2 AND tt.workspace=?1 AND tt.id=e.target_id
 LEFT JOIN assets ta ON e.target_type=1 AND ta.workspace=?1 AND ta.id=e.target_id
 ORDER BY d.id`,
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, root_id); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 3, task_root ? 1 : 0); rc != sql.OK do return rc
		for {
			virtual.arena_free_all(&arena)
			edge: pr.Edge
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			edge.edge_id, rc = sql.column_id(s, 0); if rc != sql.OK do return rc
			edge.source_type = pr.TargetType(sql.column_int64(s, 1)); edge.target_type = pr.TargetType(sql.column_int64(s, 3))
			edge.source_id, rc = sql.column_id(s, 2); if rc != sql.OK do return rc
			edge.target_id, rc = sql.column_id(s, 4); if rc != sql.OK do return rc
			child_incident := sql.column_int64(s, 5) != 0
			labels: [2]SQLite_History_Label
			for kind, i in ([2]pr.TargetType{edge.source_type, edge.target_type}) {
				column := c.int(6 + i * 4)
				if kind == .Task {
					title := sql.column_bytes_view(s, column)
					labels[i].text = pr.history_short_label(string(title), context.allocator)
				} else if sql.column_bytes(s, column + 1) != 0 {
					a := pr.Asset {
						asset_type = pr.AssetType(sql.column_int64(s, column + 2)),
						preview    = sql.column_bytes_view(s, column + 3),
					}
					if len(a.preview) > pr.MAX_PREVIEW_LENGTH do return sql.CORRUPT
					labels[i].text, labels[i].asset_type = history_asset_label(&a, context.allocator)
				}
			}
			if rc = sqlite_edge_history(store, request, edge, labels = &labels, batch = &history_batch); rc != sql.OK do return rc
			context.allocator = backing
			msg := pr.EdgeDeletedMessage {
				edge_id = edge.edge_id,
			}
			buf, frame_rc := db.command_frame(
				output,
				pr.getSizeEdgeDeletedMessage(msg),
				!transaction_batch && child_incident ? .Subscribers : .Other_Subscribers,
			)
			context.allocator = virtual.arena_allocator(&arena)
			if frame_rc != sql.OK do return frame_rc
			if pr.serializeEdgeDeletedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		}
	}
	// The cursor is closed before mutating edges. Row triggers still invalidate
	// every affected slice; history and frames roll back with this bulk delete.
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, "DELETE FROM edges WHERE workspace=?1 AND id IN (SELECT id FROM temp.nrc_edge_delete)", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.DONE do return rc
	}
	// Remove leaves first, preserving child-before-parent notifications. Cyclic
	// legacy components have no leaf; pick one ID to break the cycle deterministically.
	for {
		virtual.arena_free_all(&arena)
		id: u64
		{
			s: ^sql.Statement
			rc = sql.prepare_v2(store.db, "SELECT id FROM temp.nrc_asset_delete WHERE pending=0 ORDER BY id LIMIT 1", -1, &s, nil)
			if rc != sql.OK do return rc
			defer sql.finalize(s)
			rc = sql.step(s)
			if rc == sql.ROW {id, rc = sql.column_id(s, 0); if rc != sql.OK do return rc} else if rc != sql.DONE {return rc}
		}
		if id == 0 {
			s: ^sql.Statement
			rc = sql.prepare_v2(store.db, "SELECT id FROM temp.nrc_asset_delete ORDER BY id LIMIT 1", -1, &s, nil); if rc != sql.OK do return rc
			defer sql.finalize(s)
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			id, rc = sql.column_id(s, 0); if rc != sql.OK do return rc
		}
		a, exists, read_rc := sqlite_read_asset(store, request.workspace, request.actor, id, true, check_visibility = false)
		if read_rc != sql.OK do return read_rc
		if !exists do return sql.CORRUPT
		if rc = sqlite_asset_history(store, request, nil, &a, false, deleted = true); rc != sql.OK do return rc
		if rc = sqlite_projection_write(store, "DELETE FROM assets WHERE workspace=?1 AND id=?2", request.workspace, &a, nil); rc != sql.OK do return rc
		if rc = sqlite_projection_write(store, "DELETE FROM temp.nrc_asset_delete WHERE id=?2", request.workspace, &a, nil); rc != sql.OK do return rc
		if a.parent_type == .Asset {
			parent_key := pr.Asset {
				asset_id = a.parent_id,
			}
			if rc = sqlite_projection_write(store, "UPDATE temp.nrc_asset_delete SET pending=pending-1 WHERE id=?2", request.workspace, &parent_key, nil); rc != sql.OK do return rc
		}
		context.allocator = backing
		owner := reminder_is_personal(&a) ? string(a.owner) : ""
		msg := pr.AssetDeletedMessage {
			asset_id = id,
		}
		buf, frame_rc := db.command_frame(
			output,
			pr.getSizeAssetDeletedMessage(msg),
			transaction_batch || !task_root && id == root_id ? .Other_Subscribers : .Subscribers,
			0,
			owner,
		)
		if frame_rc != sql.OK do return frame_rc
		if pr.serializeAssetDeletedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		if !transaction_batch && !task_root && id == root_id {
			msg.correlation_id = correlation
			buf, frame_rc = db.command_frame(output, pr.getSizeAssetDeletedMessage(msg)); if frame_rc != sql.OK do return frame_rc
			if pr.serializeAssetDeletedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		}
		context.allocator = virtual.arena_allocator(&arena)
	}
	if task_root {
		virtual.arena_free_all(&arena)
		task, found, read_rc := db.get_task(store, request.workspace, 0, root_id)
		if read_rc != sql.OK do return read_rc
		if !found do return sql.CORRUPT
		event := pr.History_Event {
			entity_type  = "task",
			entity_id    = fmt.aprintf("%d", root_id),
			entity_label = pr.history_short_label(string(task.title), context.allocator),
			action       = "deleted",
			timestamp    = fmt.aprintf("%d", request.timestamp),
			actor_id     = request.subject,
			actor_name   = request.actor,
		}
		if event.actor_id == "" do event.actor_id = fmt.aprintf("service:%s", request.actor)
		if rc = db.append_history_event(store, request.workspace, event, {1, root_id}); rc != sql.OK do return rc
		if rc = db.remove_task(store, request.workspace, 0, root_id); rc != sql.OK do return rc
		context.allocator = backing
		for audience in ([2]db.Command_Audience{.Requester, .Other_Subscribers}) {
			if transaction_batch && audience == .Requester do continue
			msg := pr.TaskDeleted {
				task_id        = root_id,
				correlation_id = audience == .Requester ? correlation : 0,
			}
			buf, frame_rc := db.command_frame(output, pr.getSizeTaskDeleted(msg), audience)
			if frame_rc != sql.OK do return frame_rc
			if pr.serializeTaskDeleted(msg, buf) != len(buf) do return sql.CONSTRAINT
		}
	}
	return sql.OK
}

SQLite_History_Label :: struct {
	text:       string,
	asset_type: u16,
}

sqlite_edge_history :: proc(
	store: ^db.Store,
	request: ^db.Request,
	e: pr.Edge,
	created := false,
	labels: ^[2]SQLite_History_Label = nil,
	batch: ^db.History_Batch = nil,
) -> c.int {
	// Caller owns a one-record arena, so strings and endpoint copies are released
	// together before the next edge. Never reconstruct the workspace graph.
	source := db.History_Reference{e.source_type == .Task ? 1 : 2, e.source_id}
	target := db.History_Reference{e.target_type == .Task ? 1 : 2, e.target_id}
	event := pr.History_Event {
		entity_type = "edge",
		entity_id   = fmt.aprintf("%d", e.edge_id),
		action      = created ? "created" : "deleted",
		timestamp   = fmt.aprintf("%d", request.timestamp),
		actor_id    = request.subject,
		actor_name  = request.actor,
		source_type = history_kind_name(source.kind),
		source_id   = fmt.aprintf("%d", source.id),
		target_type = history_kind_name(target.kind),
		target_id   = fmt.aprintf("%d", target.id),
	}
	fields := [3]string{"source", "target", "relation"}
	if created do event.fields = fields[:]
	if event.actor_id == "" do event.actor_id = fmt.aprintf("service:%s", request.actor)
	for ref, i in ([2]db.History_Reference{source, target}) {
		label := ""; kind: u16
		if labels != nil {
			label = labels[i].text; kind = labels[i].asset_type
		} else if ref.kind == 1 {
			task, found, rc := db.get_task(store, request.workspace, 0, ref.id)
			if rc != sql.OK do return rc
			if found do label = pr.history_short_label(string(task.title), context.allocator)
		} else {
			a, found, rc := sqlite_read_asset(store, request.workspace, request.actor, ref.id, false, check_visibility = false)
			if rc != sql.OK do return rc
			if found {
				label, kind = history_asset_label(&a, context.allocator)
			}
		}
		if i == 0 {event.source_label = label; event.source_asset_type = kind} else {event.target_label = label; event.target_asset_type = kind}
	}
	return db.append_history_event(store, request.workspace, event, {3, e.edge_id}, source, target, batch = batch)
}
