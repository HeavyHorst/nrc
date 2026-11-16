package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_put_asset :: proc(store: ^db.Store, workspace: string, a: ^pr.Asset, insert_only := false) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	query: cstring = `INSERT INTO assets VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
 ON CONFLICT(workspace,id) DO UPDATE SET preview=excluded.preview,payload=excluded.payload,
 payload_encoding=excluded.payload_encoding,payload_raw_len=excluded.payload_raw_len,updated_at=excluded.updated_at`
	if insert_only do query = "INSERT INTO assets VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)"
	rc := sqlite_projection_write(
		store,
		query,
		workspace,
		a,
		{
			i64(a.asset_type),
			i64(a.parent_type),
			u64(a.parent_id),
			string(a.owner),
			a.created_at,
			a.updated_at,
			i64(a.payload_encoding),
			i64(a.payload_raw_len),
			string(a.preview),
			string(a.payload),
		},
	)
	if rc != sql.OK do return rc
	if a.asset_type == .Monitor {
		if rc = sqlite_monitor_register_lanes(store, workspace, a); rc != sql.OK do return rc
	}
	if rc = sqlite_projection_write(store, "DELETE FROM asset_attachments WHERE workspace=?1 AND asset_id=?2", workspace, a, nil); rc != sql.OK do return rc
	for attachment, i in a.attachments {
		if rc = sqlite_projection_write(store, "INSERT INTO asset_attachments VALUES(?1,?2,?3,?4,?5,?6,?7,?8)", workspace, a, {i64(i), string(attachment.file_id), string(attachment.filename), attachment.size, string(attachment.mime_type), attachment.uploaded_at}); rc != sql.OK do return rc
	}
	if rc = db.advance_floor(store, a.asset_id, .Asset); rc != sql.OK do return rc
	if a.parent_type != .None {
		if rc = db.advance_floor(store, a.parent_id, a.parent_type == .Asset ? .Asset : .Task); rc != sql.OK do return rc
	}
	return sqlite_project_asset(store, workspace, a)
}

sqlite_asset_history :: proc(store: ^db.Store, request: ^db.Request, old, a: ^pr.Asset, created: bool, deleted := false) -> c.int {
	fields: [dynamic]string; defer delete(fields)
	if !deleted {
		if created || old.asset_type != a.asset_type do append(&fields, "asset_type")
		if created || old.parent_type != a.parent_type do append(&fields, "parent_type")
		if created || old.parent_id != a.parent_id do append(&fields, "parent_id")
		if created || string(old.owner) != string(a.owner) do append(&fields, "owner")
		if created || string(old.preview) != string(a.preview) do append(&fields, "preview")
		if created || string(old.payload) != string(a.payload) || old.payload_encoding != a.payload_encoding || old.payload_raw_len != a.payload_raw_len do append(&fields, "payload")
		if created || !history_attachment_equal(old.attachments, a.attachments) do append(&fields, "attachments")
	}
	if !created && !deleted && len(fields) == 0 do return sql.OK
	label, kind := history_asset_label(a, context.allocator); defer delete(label)
	id := fmt.aprintf("%d", a.asset_id); defer delete(id)
	timestamp := fmt.aprintf("%d", request.timestamp); defer delete(timestamp)
	actor := request.subject
	service_actor := ""; defer delete(service_actor)
	if actor == "" {service_actor = fmt.aprintf("service:%s", request.actor); actor = service_actor}
	event := pr.History_Event {
		timestamp    = timestamp,
		actor_id     = actor,
		actor_name   = request.actor,
		entity_type  = "asset",
		entity_id    = id,
		entity_label = label,
		asset_type   = kind,
		action       = deleted ? "deleted" : (created ? "created" : "updated"),
		fields       = fields[:],
	}
	return db.append_history_event(store, request.workspace, event, {2, a.asset_id}, private_owner = reminder_is_personal(a) ? string(a.owner) : "")
}

SQLite_Asset_Mutation :: struct {
	asset:              pr.Asset,
	created, broadcast: bool,
	correlation:        u32,
	error:              string,
	rc:                 c.int,
}

// The returned asset borrows the request and this explicitly owned scratch
// arena. Output frames are allocated by the caller after restoring its allocator.
sqlite_mutate_asset :: proc(store: ^db.Store, request: ^db.Request, allocator: mem.Allocator) -> (result: SQLite_Asset_Mutation) {
	context.allocator = allocator
	result.rc = sql.OK
	result.broadcast = true
	creating := request.opcode == .C_CreateAsset
	create: pr.CreateAssetRequest
	update: pr.UpdateAssetRequest
	attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	err: pr.ProtocolParseError
	if creating {
		create, err = pr.parseCreateAssetRequestWithAttachments(request.body, attachments[:])
		result.correlation = create.correlation_id
		if err != nil || create.conv_id != 0 {result.rc = sql.CONSTRAINT; return}
	} else {
		update, err = pr.parseUpdateAssetRequestWithAttachments(request.body, attachments[:])
		result.correlation = update.correlation_id
		if err != nil || update.conv_id != 0 {result.rc = sql.CONSTRAINT; return}
	}
	old: pr.Asset
	if creating && create.asset_type == .RoomMapping {
		if create.parent_type != .None || create.parent_id != 0 {result.error = "Room mappings cannot have a parent"; return}
		name_buf: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
		name, valid := normalize_room_mapping_name(create.preview, name_buf[:])
		if !valid {result.error = "Invalid room name"; return}
		if _, reserved := builtin_room_id_for_name(name); reserved {result.error = "Room name is reserved"; return}
		s: ^sql.Statement
		result.rc = sql.prepare_v2(store.db, "SELECT asset_id FROM room_mappings WHERE workspace=?1 AND name=?2", -1, &s, nil)
		if result.rc != sql.OK do return
		defer sql.finalize(s)
		if result.rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); result.rc != sql.OK do return
		if result.rc = sql.bind_bytes(s, 2, transmute([]byte)name); result.rc != sql.OK do return
		rc := sql.step(s)
		if rc == sql.ROW {
			id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK {result.rc = id_rc; return}
			found: bool
			result.asset, found, result.rc = sqlite_read_asset(store, request.workspace, request.actor, id, true)
			if !found && result.rc == sql.OK do result.rc = sql.CORRUPT
			result.created = true; result.broadcast = false
			return
		}
		if rc != sql.DONE {result.rc = rc; return}
		// Copy normalized stack bytes into scratch before leaving this block.
		create.preview = make([]byte, len(name)); copy(create.preview, transmute([]byte)name)
		create.payload = transmute([]byte)build_room_mapping_payload(name, make_room_mapping_conv_id(request.workspace, name))
		create.payload_raw_len = u32(len(create.payload)); create.payload_encoding = .Plain; create.attachments = nil
	}
	if creating {
		if create.if_parent_updated_at != 0 {
			parent, found, rc := sqlite_read_asset(store, request.workspace, request.actor, create.parent_id, false)
			if rc != sql.OK {result.rc = rc; return}
			if create.parent_type != .Asset ||
			   !found ||
			   parent.updated_at != create.if_parent_updated_at {result.error = "Asset parent version conflict"; return}
		}
		if create.asset_type == .Agenda {
			s: ^sql.Statement
			result.rc = sql.prepare_v2(store.db, "SELECT id FROM assets WHERE workspace=?1 AND asset_type=?2 LIMIT 2", -1, &s, nil)
			if result.rc != sql.OK do return
			defer sql.finalize(s)
			if result.rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); result.rc != sql.OK do return
			if result.rc = sql.bind_int64(s, 2, i64(pr.AssetType.Agenda)); result.rc != sql.OK do return
			rc := sql.step(s)
			if rc == sql.ROW {
				id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK {result.rc = id_rc; return}
				rc = sql.step(s)
				if rc == sql.ROW {result.error = "Multiple migrated agendas: update an explicit asset ID"; return}
				if rc != sql.DONE {result.rc = rc; return}
				creating = false
				update = {
					asset_id         = id,
					preview          = create.preview,
					payload          = create.payload,
					payload_encoding = create.payload_encoding,
					payload_raw_len  = create.payload_raw_len,
					attachments      = create.attachments,
				}
			} else if rc != sql.DONE {result.rc = rc; return}
		}
	}
	a: pr.Asset
	if creating {
		if create.parent_type == .Asset {
			parent, found, rc := sqlite_read_asset(store, request.workspace, request.actor, create.parent_id, false)
			if rc != sql.OK {result.rc = rc; return}
			if !found {result.error = "Asset parent not found"; return}
			if create.asset_type == .TicketEntry && parent.asset_type != .Ticket {result.error = "Ticket parent not found"; return}
			if reminder_is_personal(&parent) {result.error = "Personal reminders cannot have shared children"; return}
			// Floyd's cycle check rejects legacy cyclic ancestor chains without
			// retaining the chain in a map or materializing a recursive CTE.
			slow, fast := create.parent_id, create.parent_id
			for fast != 0 {
				slow, result.rc = sqlite_asset_parent(store, request.workspace, slow); if result.rc != sql.OK do return
				fast, result.rc = sqlite_asset_parent(store, request.workspace, fast); if result.rc != sql.OK do return
				if fast != 0 {fast, result.rc = sqlite_asset_parent(store, request.workspace, fast); if result.rc != sql.OK do return}
				if fast != 0 && fast == slow {result.error = "Asset parent cycle not allowed"; return}
			}
		} else if create.parent_type == .Task {
			task, found, rc := db.get_task(store, request.workspace, 0, create.parent_id)
			defer db.destroy_task(&task)
			if rc != sql.OK {result.rc = rc; return}
			if !found {result.error = "Asset parent not found"; return}
		}
		a = {
			asset_type       = create.asset_type,
			parent_type      = create.parent_type,
			parent_id        = create.parent_id,
			owner            = transmute([]byte)request.actor,
			created_at       = request.timestamp,
			updated_at       = request.timestamp,
			preview          = create.preview,
			payload          = create.payload,
			payload_encoding = create.payload_encoding,
			payload_raw_len  = create.payload_raw_len,
			attachments      = create.attachments,
		}
	} else {
		found: bool
		old, found, result.rc = sqlite_read_asset(store, request.workspace, request.actor, update.asset_id, true)
		if result.rc != sql.OK do return
		if !found {result.error = "Asset not found"; return}
		if old.asset_type == .RoomMapping {result.error = "Room mappings are immutable"; return}
		if old.updated_at == max(i64) {result.rc = sql.FULL; return}
		a = old
		a.preview =
			update.preview; a.payload = update.payload; a.payload_encoding = update.payload_encoding; a.payload_raw_len = update.payload_raw_len; a.attachments = update.attachments
		a.updated_at = max(request.timestamp, old.updated_at + 1)
		if !appointment_mutation_allowed(&old, a.preview, request.actor) {result.error = "Invalid appointment record"; return}
	}
	if !validate_ticket_asset(
		a.asset_type,
		a.parent_type,
		a.parent_id,
		a.payload_encoding,
		a.payload_raw_len,
		a.preview,
		a.payload,
	) {result.error = "Invalid ticket record"; return}
	if !validate_appointment_asset(
		a.asset_type,
		a.payload_encoding,
		a.payload_raw_len,
		a.preview,
		a.payload,
	) {result.error = "Invalid appointment record"; return}
	if a.asset_type == .Slice {
		if _, valid := slice_preview_name(a.preview, context.allocator); !valid {result.error = "Slice record must carry a version and a name"; return}
	}
	if !validate_reminder_asset(&a) || (!creating && reminder_is_personal(&a) != reminder_is_personal(&old)) {
		result.error = creating ? "Invalid reminder visibility or personal reminder links/attachments" : "Reminder visibility is fixed at creation"
		return
	}
	if !monitoring_asset_mutation_valid(&a, allocator) {result.error = "Invalid monitor or machine-owned incident"; return}
	if !creating &&
	   (monitoring_is_webhook_route(&old) || monitoring_is_webhook_route(&a)) {result.error = "Webhook routes are immutable; create a new route"; return}
	// No business-error response may commit a consumed ID or partial mutation.
	if creating {
		a.asset_id, result.rc = db.next_id(store, .Asset)
		if result.rc != sql.OK do return
	}
	if result.rc = sqlite_put_asset(store, request.workspace, &a, insert_only = creating); result.rc != sql.OK do return
	if result.rc = sqlite_asset_history(store, request, &old, &a, creating); result.rc != sql.OK do return
	result.asset = a
	// Request attachments were parsed on this procedure's stack.
	result.asset.attachments = make([]pr.Attachment, len(a.attachments)); copy(result.asset.attachments, a.attachments)
	result.created = creating
	return
}

sqlite_execute_asset_write :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	r := sqlite_mutate_asset(store, request, virtual.arena_allocator(&arena))
	if r.rc != sql.OK do return r.rc
	if r.error != "" {
		msg := pr.ErrorResponse {
			origin_opcode  = request.opcode,
			error_msg      = transmute([]byte)r.error,
			correlation_id = r.correlation,
		}
		buf, rc := db.command_frame(output, pr.getSizeErrorResponse(msg)); if rc != sql.OK do return rc
		return pr.serializeErrorResponse(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	for audience in ([2]db.Command_Audience{.Requester, .Other_Subscribers}) {
		if audience != .Requester && !r.broadcast do continue
		correlation := audience == .Requester ? r.correlation : 0
		owner := reminder_is_personal(&r.asset) ? string(r.asset.owner) : ""
		if r.created {
			msg := pr.AssetCreatedMessage {
				asset          = r.asset,
				correlation_id = correlation,
			}
			buf, rc := db.command_frame(output, pr.getSizeAssetCreatedMessage(msg), audience, 0, owner); if rc != sql.OK do return rc
			if pr.serializeAssetCreatedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		} else {
			msg := pr.AssetUpdatedMessage {
				asset          = r.asset,
				correlation_id = correlation,
			}
			buf, rc := db.command_frame(output, pr.getSizeAssetUpdatedMessage(msg), audience, 0, owner); if rc != sql.OK do return rc
			if pr.serializeAssetUpdatedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		}
	}
	return sql.OK
}

sqlite_asset_parent :: proc(store: ^db.Store, workspace: string, id: u64) -> (u64, c.int) {
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, "SELECT parent_id FROM assets WHERE workspace=?1 AND id=?2 AND parent_type=?3", -1, &s, nil)
	if rc != sql.OK do return 0, rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return 0, rc
	if rc = sql.bind_id(s, 2, id); rc != sql.OK do return 0, rc
	if rc = sql.bind_int64(s, 3, i64(pr.ParentType.Asset)); rc != sql.OK do return 0, rc
	rc = sql.step(s)
	if rc == sql.DONE do return 0, sql.OK
	if rc != sql.ROW do return 0, rc
	return sql.column_id(s, 0)
}
