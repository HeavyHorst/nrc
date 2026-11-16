package main

import "core:c"
import "core:encoding/endian"
import "core:mem/virtual"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_transaction_reference :: proc(
	ref: pr.TransactionReference,
	expected: pr.TransactionEntityType,
	operations: []pr.TransactionOperation,
	results: []pr.TransactionOperationResult,
) -> (
	u64,
	bool,
) {
	if ref.entity_type != expected do return 0, false
	if ref.kind == .Existing do return ref.value, ref.value != 0
	if ref.value >= u64(len(operations)) do return 0, false
	create := expected == .Task ? pr.TransactionOperationType.TaskCreate : .AssetCreate
	if operations[ref.value].op_type != create do return 0, false
	return results[ref.value].entity_id, true
}

sqlite_transaction_deleted :: proc(store: ^db.Store, kind: pr.TransactionEntityType, id: u64) -> (bool, c.int) {
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, "SELECT 1 FROM temp.nrc_batch_delete WHERE kind=?1 AND id=?2", -1, &s, nil)
	if rc != sql.OK do return false, rc
	defer sql.finalize(s)
	if rc = sql.bind_int64(s, 1, i64(kind)); rc != sql.OK do return false, rc
	if rc = sql.bind_id(s, 2, id); rc != sql.OK do return false, rc
	rc = sql.step(s)
	return rc == sql.ROW, (rc == sql.ROW || rc == sql.DONE ? sql.OK : rc)
}

// Plan deletions from the initial snapshot. Only IDs enter the temp table;
// cascades can exceed the input batch without a workspace-sized RAM copy.
sqlite_transaction_prepare_records :: proc(
	store: ^db.Store,
	request: ^db.Request,
	operations: []pr.TransactionOperation,
	results: []pr.TransactionOperationResult,
	failed: ^u16,
) -> c.int {
	rc := sql.exec(
		store.db,
		"CREATE TEMP TABLE IF NOT EXISTS nrc_batch_delete(kind INTEGER,id BLOB,PRIMARY KEY(kind,id)) WITHOUT ROWID; DELETE FROM temp.nrc_batch_delete",
		nil,
		nil,
		nil,
	)
	if rc != sql.OK do return rc
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	slice_roots := 0
	has_deletes := false
	for op, i in operations {
		virtual.arena_free_all(&arena)
		failed^ = u16(i); results[i].op_type = op.op_type
		if len(op.body) < 8 do return sql.CONSTRAINT
		scope, _ := endian.get_u64(op.body, .Big); if scope != 0 do return sql.CONSTRAINT
		#partial switch op.op_type {
		case .AssetCreate, .EdgeCreate:
			results[i].entity_id, rc = db.next_id(store, op.op_type == .AssetCreate ? .Asset : .Edge)
			if rc != sql.OK do return rc
		case .AssetPatch:
			r, e := pr.parseTransactionAssetPatch(op.body)
			if e != nil || r.asset.kind != .Existing do return sql.CONSTRAINT
			for j in 0 ..< i {if operations[j].op_type == .AssetPatch && results[j].entity_id == r.asset.value do return sql.CONSTRAINT}
			a, found, read_rc := sqlite_read_asset(store, request.workspace, request.actor, r.asset.value, false)
			if read_rc != sql.OK do return read_rc
			if !found || a.asset_type == .RoomMapping || r.if_updated_at != 0 && a.updated_at != r.if_updated_at do return sql.CONSTRAINT
			results[i].entity_id = r.asset.value
		case .TaskDelete, .AssetDelete, .EdgeDelete:
			has_deletes = true
			kind := op.op_type == .TaskDelete ? pr.TransactionEntityType.Task : (op.op_type == .AssetDelete ? .Asset : .Edge)
			r, e := pr.parseTransactionDelete(op.body, kind)
			if e != nil || r.entity.kind != .Existing do return sql.CONSTRAINT
			results[i].entity_id = r.entity.value
			if kind == .Asset {
				a, found, read_rc := sqlite_read_asset(store, request.workspace, request.actor, r.entity.value, false)
				if read_rc != sql.OK do return read_rc
				if !found || a.asset_type == .RoomMapping || r.if_updated_at != 0 && a.updated_at != r.if_updated_at || !appointment_mutation_allowed(&a, nil, request.actor) do return sql.CONSTRAINT
				if a.asset_type == .Monitor || a.asset_type == .Incident do return sql.CONSTRAINT
				if monitoring_is_webhook_route(&a) do return sql.CONSTRAINT
				if a.asset_type == .Slice {slice_roots += 1; if slice_roots > MAX_DELETE_SLICES do return sql.CONSTRAINT}
			} else if kind == .Edge {
				s: ^sql.Statement
				rc = sql.prepare_v2(store.db, "SELECT 1 FROM edges WHERE workspace=?1 AND id=?2", -1, &s, nil); if rc != sql.OK do return rc
				defer sql.finalize(s)
				if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
				if rc = sql.bind_id(s, 2, r.entity.value); rc != sql.OK do return rc
				rc = sql.step(s); if rc == sql.DONE do return sql.CONSTRAINT
				if rc != sql.ROW do return rc
			}
			key := pr.Asset {
				asset_id = r.entity.value,
			}
			if rc = sqlite_projection_write(store, "INSERT INTO temp.nrc_batch_delete SELECT ?3,?2 WHERE length(?1)>0", request.workspace, &key, {i64(kind)}); rc != sql.OK do return rc
		}
	}
	// Keep the empty staging table for parent/endpoint checks, but do not
	// compile or traverse deletion closures for ordinary create/patch batches.
	if !has_deletes do return sql.OK
	// UNION deduplicates overlapping roots and terminates imported parent cycles.
	key: pr.Asset
	rc = sqlite_projection_write(
		store,
		`WITH RECURSIVE doomed(id) AS (
 SELECT id FROM temp.nrc_batch_delete WHERE kind=2
 UNION SELECT a.id FROM temp.nrc_batch_delete d CROSS JOIN assets a INDEXED BY assets_parent
 WHERE d.kind=1 AND a.workspace=?1 AND a.parent_type=1 AND a.parent_id=d.id
 UNION SELECT a.id FROM doomed d CROSS JOIN assets a INDEXED BY assets_parent
 WHERE a.workspace=?1 AND a.parent_type=2 AND a.parent_id=d.id LIMIT ?3)
 INSERT OR IGNORE INTO temp.nrc_batch_delete SELECT 2,id FROM doomed WHERE ?2=x'0000000000000000'`,
		request.workspace,
		&key,
		{i64(MAX_DELETE_RECORDS + 1)},
	)
	if rc != sql.OK do return rc
	_, rc = sqlite_delete_limit_check(
		store,
		request.workspace,
		`SELECT count(*)+?3,
 coalesce(sum(CASE WHEN d.kind=2 AND a.asset_type=?2 THEN 1 ELSE 0 END),0),0
 FROM temp.nrc_batch_delete d LEFT JOIN assets a ON d.kind=2 AND a.workspace=?1 AND a.id=d.id`,
	)
	if rc != sql.OK do return rc
	// Include incident edges, deduplicating explicit edge deletes and edges
	// shared by roots. Each endpoint scan stops after the rejection sentinel.
	_, rc = sqlite_delete_limit_check(
		store,
		request.workspace,
		`WITH affected(kind,id) AS (
 SELECT kind,id FROM temp.nrc_batch_delete
 UNION SELECT 3,id FROM (SELECT e.id FROM temp.nrc_batch_delete d CROSS JOIN edges e INDEXED BY edges_source_page
 ON e.workspace=?1 AND e.source_type=3-d.kind AND e.source_id=d.id WHERE d.kind IN (1,2) LIMIT ?3)
 UNION SELECT 3,id FROM (SELECT e.id FROM temp.nrc_batch_delete d CROSS JOIN edges e INDEXED BY edges_target_page
 ON e.workspace=?1 AND e.target_type=3-d.kind AND e.target_id=d.id WHERE d.kind IN (1,2) LIMIT ?3)
 LIMIT ?3)
 SELECT count(*),coalesce(sum(CASE WHEN d.kind=2 AND a.asset_type=?2 THEN 1 ELSE 0 END),0),0
 FROM affected d LEFT JOIN assets a ON d.kind=2 AND a.workspace=?1 AND a.id=d.id`,
		MAX_DELETE_RECORDS + 1,
	)
	if rc != sql.OK do return rc
	for op, i in operations {
		if op.op_type != .AssetPatch do continue
		failed^ = u16(i)
		deleted, read_rc := sqlite_transaction_deleted(store, .Asset, results[i].entity_id)
		if read_rc != sql.OK do return read_rc
		if deleted do return sql.CONSTRAINT
	}
	return sql.OK
}

sqlite_transaction_assets :: proc(
	store: ^db.Store,
	request: ^db.Request,
	operations: []pr.TransactionOperation,
	results: []pr.TransactionOperationResult,
	output: ^db.Command_Output,
	failed: ^u16,
) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for op, i in operations {
		if op.op_type != .AssetCreate && op.op_type != .AssetPatch do continue
		virtual.arena_free_all(&arena); failed^ = u16(i)
		creating := op.op_type == .AssetCreate
		a, old: pr.Asset
		if creating {
			r, e := pr.parseTransactionAssetCreate(op.body)
			if e != nil || r.asset_type == .RoomMapping || r.asset_type == .Agenda do return sql.CONSTRAINT
			parent: u64
			if r.parent_type != .None {
				valid: bool
				parent, valid = sqlite_transaction_reference(r.parent, r.parent_type == .Task ? .Task : .Asset, operations, results)
				if !valid do return sql.CONSTRAINT
			}
			a = {
				asset_id         = results[i].entity_id,
				asset_type       = r.asset_type,
				parent_type      = r.parent_type,
				parent_id        = parent,
				owner            = transmute([]byte)request.actor,
				created_at       = request.timestamp,
				updated_at       = request.timestamp,
				preview          = r.preview,
				payload          = r.payload,
				payload_encoding = r.payload_encoding,
				payload_raw_len  = r.payload_raw_len,
			}
		} else {
			r, e := pr.parseTransactionAssetPatch(op.body); if e != nil do return sql.CONSTRAINT
			found: bool; rc: c.int
			old, found, rc = sqlite_read_asset(store, request.workspace, request.actor, results[i].entity_id, true)
			if rc != sql.OK do return rc
			if !found do return sql.CONSTRAINT
			if old.updated_at == max(i64) do return sql.FULL
			a = old; a.updated_at = max(request.timestamp, old.updated_at + 1)
			if r.present & pr.TRANSACTION_ASSET_PATCH_PREVIEW != 0 do a.preview = r.preview
			if r.present & pr.TRANSACTION_ASSET_PATCH_PAYLOAD !=
			   0 {a.payload = r.payload; a.payload_encoding = r.payload_encoding; a.payload_raw_len = r.payload_raw_len}
			if !appointment_mutation_allowed(&old, a.preview, request.actor) || reminder_is_personal(&a) != reminder_is_personal(&old) do return sql.CONSTRAINT
		}
		if a.payload_encoding < min(pr.PayloadEncoding) || a.payload_encoding > max(pr.PayloadEncoding) || a.payload_encoding == .Plain && a.payload_raw_len != u32(len(a.payload)) do return sql.CONSTRAINT
		if !validate_appointment_asset(a.asset_type, a.payload_encoding, a.payload_raw_len, a.preview, a.payload) || !validate_ticket_asset(a.asset_type, a.parent_type, a.parent_id, a.payload_encoding, a.payload_raw_len, a.preview, a.payload) || !validate_reminder_asset(&a) do return sql.CONSTRAINT
		if a.asset_type == .Slice {if _, valid := slice_preview_name(a.preview, context.allocator); !valid do return sql.CONSTRAINT}
		if !monitoring_asset_mutation_valid(&a, context.allocator) do return sql.CONSTRAINT
		if !creating && (monitoring_is_webhook_route(&old) || monitoring_is_webhook_route(&a)) do return sql.CONSTRAINT
		// Parent checks follow after all post-images exist, allowing forward refs.
		if rc := sqlite_put_asset(store, request.workspace, &a, insert_only = creating); rc != sql.OK do return rc
		if rc := sqlite_asset_history(store, request, &old, &a, creating); rc != sql.OK do return rc
		owner := reminder_is_personal(&a) ? string(a.owner) : ""
		{
			context.allocator = backing
			if creating {
				msg := pr.AssetCreatedMessage {
					asset = a,
				}
				buf, rc := db.command_frame(output, pr.getSizeAssetCreatedMessage(msg), .Other_Subscribers, 0, owner); if rc != sql.OK do return rc
				if pr.serializeAssetCreatedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
			} else {
				msg := pr.AssetUpdatedMessage {
					asset = a,
				}
				buf, rc := db.command_frame(output, pr.getSizeAssetUpdatedMessage(msg), .Other_Subscribers, 0, owner); if rc != sql.OK do return rc
				if pr.serializeAssetUpdatedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
			}
		}
	}
	for op, i in operations {
		if op.op_type != .AssetCreate do continue
		virtual.arena_free_all(&arena); failed^ = u16(i)
		a, found, rc := sqlite_read_asset(store, request.workspace, request.actor, results[i].entity_id, false)
		if rc != sql.OK do return rc
		if !found do return sql.CONSTRAINT
		if a.parent_type == .None do continue
		kind := a.parent_type == .Task ? pr.TransactionEntityType.Task : .Asset
		deleted, delete_rc := sqlite_transaction_deleted(store, kind, a.parent_id)
		if delete_rc != sql.OK do return delete_rc
		if deleted do return sql.CONSTRAINT
		if kind == .Task {
			typ: u16
			parent_found, parent_rc := sqlite_history_available(store, request.workspace, request.actor, 1, a.parent_id, &typ)
			if parent_rc != sql.OK do return parent_rc
			if !parent_found do return sql.CONSTRAINT
		} else {
			parent, parent_found, parent_rc := sqlite_read_asset(store, request.workspace, request.actor, a.parent_id, false)
			if parent_rc != sql.OK do return parent_rc
			if !parent_found || reminder_is_personal(&parent) || a.asset_type == .TicketEntry && parent.asset_type != .Ticket do return sql.CONSTRAINT
			slow, fast := a.asset_id, a.asset_id
			for {
				slow, rc = sqlite_asset_parent(store, request.workspace, slow); if rc != sql.OK do return rc
				fast, rc = sqlite_asset_parent(store, request.workspace, fast); if rc != sql.OK do return rc
				if fast == 0 do break
				fast, rc = sqlite_asset_parent(store, request.workspace, fast); if rc != sql.OK do return rc
				if fast == 0 do break
				if slow == fast do return sql.CONSTRAINT
			}
		}
	}
	return sql.OK
}

sqlite_transaction_edges :: proc(
	store: ^db.Store,
	request: ^db.Request,
	operations: []pr.TransactionOperation,
	results: []pr.TransactionOperationResult,
	output: ^db.Command_Output,
	failed: ^u16,
) -> c.int {
	// Remove explicit edges first so an atomic membership replacement does not
	// collide with its own pre-image. Cascades later deduplicate these deletions.
	for phase in 0 ..< 2 {
		for op, i in operations {
			if op.op_type != (phase == 0 ? pr.TransactionOperationType.EdgeDelete : .EdgeCreate) do continue
			failed^ = u16(i)
			body: [64]byte
			command := request^
			n: int
			if phase == 0 {
				n = pr.serializeDeleteEdgeRequest(0, results[i].entity_id, body[:]); command.opcode = .C_DeleteEdge
			} else {
				r, e := pr.parseTransactionEdgeCreate(op.body); if e != nil do return sql.CONSTRAINT
				source, source_ok := sqlite_transaction_reference(r.source, r.source.entity_type, operations, results)
				target, target_ok := sqlite_transaction_reference(r.target, r.target.entity_type, operations, results)
				if !source_ok || !target_ok do return sql.CONSTRAINT
				for endpoint in ([2]pr.TransactionReference{{.Existing, r.source.entity_type, source}, {.Existing, r.target.entity_type, target}}) {
					deleted, rc := sqlite_transaction_deleted(store, endpoint.entity_type, endpoint.value)
					if rc != sql.OK do return rc
					if deleted do return sql.CONSTRAINT
				}
				n = pr.serializeCreateEdgeRequest(
					{
						source_type = r.source.entity_type == .Task ? .Task : .Asset,
						source_id = source,
						target_type = r.target.entity_type == .Task ? .Task : .Asset,
						target_id = target,
						relation = r.relation,
					},
					body[:],
				); command.opcode = .C_CreateEdge
			}
			if n < 2 do return sql.CONSTRAINT
			command.body = body[2:n]
			if rc := sqlite_execute_edges(store, &command, output, transaction_batch = true, created_id = results[i].entity_id); rc != sql.OK do return rc
		}
	}
	return sql.OK
}
