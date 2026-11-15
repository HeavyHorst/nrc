package main

import "core:c"
import "core:encoding/endian"
import "core:mem/virtual"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_transaction_result :: proc(
	output: ^db.Command_Output,
	correlation: u32,
	status: pr.TransactionResultStatus,
	failed: u16,
	results: []pr.TransactionOperationResult,
) -> c.int {
	buf, rc := db.command_frame(output, pr.getSizeTransactionResult(len(results)))
	if rc != sql.OK do return rc
	return pr.serializeTransactionResult(correlation, status, failed, results, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_apply_transaction :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	operations: [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionOperation
	req, err := pr.parseApplyTransactionRequest(request.body, operations[:])
	if err != nil do return sql.CONSTRAINT
	// SAVEPOINT lets a semantic rejection return its operation index while
	// rolling back every write, floor and prepared event before the outer commit.
	if rc := sql.exec(store.db, "SAVEPOINT nrc_batch", nil, nil, nil); rc != sql.OK do return rc
	failed: u16
	results: [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionOperationResult
	defer sql.exec(store.db, "DELETE FROM temp.nrc_batch_delete", nil, nil, nil)
	rc := sqlite_transaction_apply(store, request, req.operations, results[:], output, &failed)
	if rc == sql.CONSTRAINT {
		if rollback := sql.exec(store.db, "ROLLBACK TO nrc_batch; RELEASE nrc_batch", nil, nil, nil); rollback != sql.OK do return rollback
		limit := output.limit
		directory := output.spool_directory
		db.destroy_command_output(output); output.limit = limit; output.spool_directory = directory
		return sqlite_transaction_result(output, req.correlation_id, .Rejected, failed, nil)
	}
	if rc != sql.OK do return rc // Executor rolls back and discards all output.
	if rc = sql.exec(store.db, "RELEASE nrc_batch", nil, nil, nil); rc != sql.OK do return rc
	return sqlite_transaction_result(output, req.correlation_id, .Committed, max(u16), results[:len(req.operations)])
}

sqlite_transaction_apply :: proc(
	store: ^db.Store,
	request: ^db.Request,
	operations: []pr.TransactionOperation,
	results: []pr.TransactionOperationResult,
	output: ^db.Command_Output,
	failed: ^u16,
) -> c.int {
	if rc := sqlite_transaction_prepare_records(store, request, operations, results, failed); rc != sql.OK do return rc
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	old, next: [pr.MAX_TRANSACTION_OPERATIONS]pr.Task
	blockers: [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionReference
	unblocked: [pr.MAX_TRANSACTION_OPERATIONS]bool
	completed: [pr.MAX_TRANSACTION_OPERATIONS]bool
	// Existing bodies are bounded by the admitted output credit, not by the
	// workspace size. New bodies borrow the immutable queued request.
	remaining := output.limit
	for op, i in operations {
		failed^ = u16(i)
		results[i].op_type = op.op_type
		#partial switch op.op_type {
		case .TaskCreate:
			r, e := pr.parseTransactionTaskCreate(op.body)
			if e != nil || r.conv_id != 0 do return sql.CONSTRAINT
			id, rc := db.next_id(store); if rc != sql.OK do return rc
			results[i].entity_id = id
			blockers[i] = r.blocked_by
			next[i] = {
				id           = id,
				title        = r.title,
				description  = r.description,
				external_ref = r.external_ref,
				project      = r.project,
				status       = r.status,
				priority     = r.priority,
				color        = r.color,
				due_at       = r.due_at,
				created_by   = transmute([]byte)request.actor,
				created_at   = request.timestamp,
				updated_at   = request.timestamp,
			}
			completed[i] = r.status == .Done
		case .TaskPatch, .TaskDelete:
			id: u64; guard: i64
			patch: pr.TransactionTaskPatch
			if op.op_type == .TaskPatch {
				r, e := pr.parseTransactionTaskPatch(op.body)
				if e != nil || r.conv_id != 0 || r.task.kind != .Existing do return sql.CONSTRAINT
				patch = r; id = r.task.value; guard = r.if_updated_at
			} else {
				r, e := pr.parseTransactionDelete(op.body, .Task)
				if e != nil || r.conv_id != 0 || r.entity.kind != .Existing do return sql.CONSTRAINT
				id = r.entity.value; guard = r.if_updated_at
			}
			for j in 0 ..< i {if results[j].entity_id == id && (operations[j].op_type == .TaskPatch || operations[j].op_type == .TaskDelete) do return sql.CONSTRAINT}
			before, found, rc := db.get_task(store, request.workspace, 0, id, allocator = a, max_bytes = remaining)
			if rc != sql.OK do return rc
			if !found || guard != 0 && before.updated_at != guard do return sql.CONSTRAINT
			remaining -= size_of(pr.Task)
			for field in ([7][]byte{before.title, before.description, before.assignee, before.created_by, before.external_ref, before.completed_by, before.project}) do remaining -= len(field)
			for attachment in before.attachments do remaining -= size_of(pr.Attachment) + len(attachment.file_id) + len(attachment.filename) + len(attachment.mime_type)
			old[i] = before; results[i].entity_id = id
			if op.op_type == .TaskDelete do continue
			if before.updated_at == max(i64) do return sql.FULL
			n := before
			if patch.present & pr.TRANSACTION_TASK_PATCH_TITLE != 0 do n.title = patch.title
			if patch.present & pr.TRANSACTION_TASK_PATCH_DESCRIPTION != 0 do n.description = patch.description
			if patch.present & pr.TRANSACTION_TASK_PATCH_ASSIGNEE != 0 do n.assignee = patch.assignee
			if patch.present & pr.TRANSACTION_TASK_PATCH_EXTERNAL_REF != 0 do n.external_ref = patch.external_ref
			if patch.present & pr.TRANSACTION_TASK_PATCH_PROJECT != 0 do n.project = patch.project
			if patch.present & pr.TRANSACTION_TASK_PATCH_STATUS != 0 do n.status = patch.status
			if patch.present & pr.TRANSACTION_TASK_PATCH_PRIORITY != 0 do n.priority = patch.priority
			if patch.present & pr.TRANSACTION_TASK_PATCH_COLOR != 0 do n.color = patch.color
			if patch.present & pr.TRANSACTION_TASK_PATCH_DUE_AT != 0 do n.due_at = patch.due_at
			blockers[i] = {
				kind        = .Existing,
				entity_type = .Task,
				value       = before.blocked_by,
			}
			if patch.present & pr.TRANSACTION_TASK_PATCH_BLOCKED_BY != 0 do blockers[i] = patch.blocked_by
			if len(n.title) == 0 do return sql.CONSTRAINT
			n.updated_at = max(request.timestamp, before.updated_at + 1)
			completed[i] = n.status == .Done && before.status != .Done
			if completed[i] {n.completed_at = n.updated_at; n.completed_by = transmute([]byte)request.actor}
			if n.status != .Done && before.status == .Done {n.completed_at = 0; n.completed_by = nil}
			next[i] = n
		case:
			continue
		}
	}
	// Resolve all create IDs before checking dependencies, including forward refs.
	for op, i in operations {
		failed^ = u16(i)
		if op.op_type != .TaskCreate && op.op_type != .TaskPatch do continue
		ref := blockers[i]
		if ref.entity_type != .Task do return sql.CONSTRAINT
		id := ref.value
		if ref.kind == .CreatedBy {
			if id >= u64(len(operations)) || operations[id].op_type != .TaskCreate do return sql.CONSTRAINT
			id = results[id].entity_id
		}
		next[i].blocked_by = id
		if id == 0 do continue
		projected := false
		for other, j in operations {
			if other.op_type != .TaskCreate && other.op_type != .TaskPatch && other.op_type != .TaskDelete do continue
			if results[j].entity_id != id do continue
			if other.op_type == .TaskDelete do return sql.CONSTRAINT
			projected = true
			if completed[j] {next[i].blocked_by = 0; unblocked[i] = true}
		}
		if !projected {
			s: ^sql.Statement
			rc := sql.prepare_v2(store.db, "SELECT 1 FROM tasks WHERE workspace=?1 AND id=?2", -1, &s, nil); if rc != sql.OK do return rc
			defer sql.finalize(s)
			if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 2, id); rc != sql.OK do return rc
			rc = sql.step(s); if rc == sql.DONE do return sql.CONSTRAINT
			if rc != sql.ROW do return rc
		}
	}
	for op, i in operations {
		failed^ = u16(i)
		if op.op_type != .TaskCreate && op.op_type != .TaskPatch do continue
		n := &next[i]
		if op.op_type == .TaskCreate {
			if rc := db.put_task(store, request.workspace, n); rc != sql.OK do return rc
			if rc := db.append_task_created_history(store, request.workspace, n, request.subject, unblocked[i]); rc != sql.OK do return rc
			msg := pr.TaskCreated {
				task = n^,
			}
			buf, rc := db.command_frame(output, pr.getSizeTaskCreated(msg), unblocked[i] ? .Subscribers : .Other_Subscribers)
			if rc != sql.OK do return rc
			if pr.serializeTaskCreated(msg, buf) != len(buf) do return sql.CONSTRAINT
		} else {
			if rc := sqlite_update_task(store, request.workspace, &old[i], n); rc != sql.OK do return rc
			if rc := sqlite_task_update_history(store, request, &old[i], n, system_unblock = unblocked[i]); rc != sql.OK do return rc
			if rc := sqlite_emit_task_updated(output, n^, 0, unblocked[i] ? .Subscribers : .Other_Subscribers); rc != sql.OK do return rc
		}
	}
	// A delete must not leave a surviving task pointing at the deleted blocker.
	// Explicitly deleted dependents are allowed and need no RAM graph expansion.
	for op, i in operations {
		if op.op_type != .TaskDelete do continue
		failed^ = u16(i)
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT id FROM tasks WHERE workspace=?1 AND blocked_by=?2", -1, &s, nil); if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, results[i].entity_id); rc != sql.OK do return rc
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			id, read_rc := sql.column_id(s, 0); if read_rc != sql.OK do return read_rc
			deleted := false
			for other, j in operations {if other.op_type == .TaskDelete && results[j].entity_id == id do deleted = true}
			if !deleted do return sql.CONSTRAINT
		}
	}
	if rc := sqlite_transaction_assets(store, request, operations, results, output, failed); rc != sql.OK do return rc
	if rc := sqlite_transaction_edges(store, request, operations, results, output, failed); rc != sql.OK do return rc
	for op, i in operations {
		if op.op_type != .TaskDelete && op.op_type != .AssetDelete do continue
		failed^ = u16(i)
		if op.op_type == .AssetDelete {
			// An earlier root may already have removed this explicit descendant.
			kind: u16
			found, rc := sqlite_history_available(store, request.workspace, request.actor, 2, results[i].entity_id, &kind)
			if rc != sql.OK do return rc
			if !found do continue
		}
		body: [20]byte
		endian.put_u64(body[8:], .Big, results[i].entity_id)
		deletion := request^; deletion.opcode = op.op_type == .TaskDelete ? .C_DeleteTask : .C_DeleteAsset; deletion.body = body[:]
		if rc := sqlite_delete_record(store, &deletion, output, transaction_batch = true); rc != sql.OK do return rc
	}
	for done, i in completed[:len(operations)] {
		if !done do continue
		failed^ = u16(i)
		if rc := sqlite_unblock_tasks(store, request, &next[i], output); rc != sql.OK do return rc
	}
	return sql.OK
}
