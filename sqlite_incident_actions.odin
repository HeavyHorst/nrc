package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:unicode/utf8"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_incident_action_ack :: proc(output: ^db.Command_Output, r: pr.ActOnIncidentRequest, revision: i64, replayed: bool) -> c.int {
	buf, rc := db.command_frame(output, 23)
	if rc != sql.OK do return rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_IncidentActionApplied))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.incident_id)
	endian.put_u64(buf[14:], .Big, u64(revision))
	buf[22] = replayed ? 1 : 0
	return sql.OK
}

// Human fields live only on the Incident asset. This command never changes the
// monitor revision, observations, episode state or technical incident status.
sqlite_act_on_incident :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	r, err := pr.parseActOnIncidentRequest(request.body)
	if err != nil || request.timestamp <= 0 || len(request.actor) == 0 || len(request.actor) > pr.MAX_OWNER_LENGTH || !utf8.valid_string(request.actor) do return sql.CONSTRAINT
	old, found, rc := sqlite_read_asset(store, request.workspace, request.actor, r.incident_id, true)
	if rc != sql.OK do return rc
	if !found || old.asset_type != .Incident do return sql.CONSTRAINT
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT revision,actor,subject,receipt FROM incident_actions WHERE workspace=?1 AND incident_id=?2", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, r.incident_id); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc == sql.ROW {
			revision := sql.column_int64(s, 0)
			if revision == old.updated_at &&
			   string(sql.column_bytes_view(s, 1)) == request.actor &&
			   string(sql.column_bytes_view(s, 2)) == request.subject &&
			   string(sql.column_bytes_view(s, 3)) == string(request.body[4:]) {
				context.allocator = backing
				return sqlite_incident_action_ack(output, r, revision, true)
			}
		} else if rc != sql.DONE do return rc
	}
	if old.updated_at != r.revision do return sql.CONSTRAINT
	if old.updated_at == max(i64) do return sql.FULL
	record: Incident_Record
	if json.unmarshal(old.preview, &record, allocator = context.allocator) != nil || record.version != 1 do return sql.CORRUPT
	a := old
	a.updated_at = max(request.timestamp, old.updated_at + 1)
	changed: bool
	if r.action == 0 {
		// First acknowledgment wins. A fresh command cannot impersonate or replace it.
		changed = record.acknowledged_by == ""
		if changed {
			record.acknowledged_by = request.actor
			record.acknowledged_at = fmt.aprintf("%d", a.updated_at)
		}
	} else {
		changed = record.assigned_to != r.assignee
		record.assigned_to = r.assignee
	}
	preview, json_err := json.marshal(record)
	if json_err != nil do return sql.CONSTRAINT
	if len(preview) > pr.MAX_PREVIEW_LENGTH do return sql.TOOBIG
	a.preview = preview
	if rc = sqlite_put_asset(store, request.workspace, &a, false); rc != sql.OK do return rc
	if rc = sqlite_projection_write(store, `INSERT INTO incident_actions VALUES(?1,?2,?3,?4,?5,?6)
 ON CONFLICT(workspace,incident_id) DO UPDATE SET revision=excluded.revision,actor=excluded.actor,subject=excluded.subject,receipt=excluded.receipt`, request.workspace, &a, {a.updated_at, request.actor, request.subject, string(request.body[4:])}); rc != sql.OK do return rc
	if changed {
		event := pr.History_Event {
			timestamp    = fmt.aprintf("%d", a.updated_at),
			actor_id     = request.subject == "" ? fmt.aprintf("service:%s", request.actor) : request.subject,
			actor_name   = request.actor,
			entity_type  = "asset",
			entity_id    = fmt.aprintf("%d", a.asset_id),
			entity_label = pr.history_short_label(record.title, context.allocator),
			asset_type   = u16(pr.AssetType.Incident),
			action       = r.action == 0 ? "acknowledged" : "assigned",
			fields       = r.action == 0 ? []string{"acknowledged_by", "acknowledged_at"} : []string{"assigned_to"},
		}
		if rc = db.append_history_event(store, request.workspace, event, {2, a.asset_id}); rc != sql.OK do return rc
	}
	context.allocator = backing
	msg := pr.AssetUpdatedMessage {
		asset = a,
	}
	buf, frame_rc := db.command_frame(output, pr.getSizeAssetUpdatedMessage(msg), .Subscribers)
	if frame_rc != sql.OK do return frame_rc
	if pr.serializeAssetUpdatedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
	return sqlite_incident_action_ack(output, r, a.updated_at, false)
}
