package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_review_reply :: proc(output: ^db.Command_Output, correlation: u32, response: pr.Review_Response, allocator: mem.Allocator) -> c.int {
	payload, err := json.marshal(response)
	if err != nil do return sql.ERROR
	context.allocator = allocator
	buf, rc := db.command_frame(output, len(payload) + 6)
	if rc != sql.OK do return rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_Review))
	endian.put_u32(buf[2:], .Big, correlation)
	copy(buf[6:], payload)
	return sql.OK
}

// Called on the workspace writer inside the executor's transaction. A stale
// draft cannot be released accidentally; all canonical fields freeze together.
sqlite_execute_review :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	q, correlation, err := pr.parseReviewRequest(request.body)
	r := pr.Review_Response {
		status = "invalid",
	}
	if err != nil do return sqlite_review_reply(output, correlation, r, backing)
	if request.actor == "" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
	if q.op == "run_create" ||
	   q.op == "run_get" ||
	   q.op == "run_list" ||
	   q.op == "participant_add" ||
	   q.op == "answer" ||
	   q.op == "close" ||
	   q.op == "invite" ||
	   q.op == "revoke" ||
	   q.op == "invitation_info" ||
	   q.op == "guest_join" {
		return sqlite_review_run_command(store, request, q, correlation, output, backing)
	}
	if request.review_portal {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
	creating := q.op == "create" || q.op == "copy"
	old: pr.Asset
	form := q.form
	if q.op != "create" {
		id, _ := pr.chronicle_decimal(q.form_id)
		found: bool
		rc: c.int
		old, found, rc = sqlite_read_asset(store, request.workspace, request.actor, id, true)
		if rc != sql.OK do return rc
		if !found || old.asset_type != .ReviewForm {r.status = "not_found"; return sqlite_review_reply(output, correlation, r, backing)}
		if old.payload_encoding != .Plain ||
		   json.unmarshal(old.payload, &form, spec = .JSON) != nil ||
		   !pr.validate_review_form(form, form.released_at != "") {return sql.CORRUPT}
		if q.op == "get" {
			r = {
				status   = "ok",
				form_id  = q.form_id,
				revision = fmt.aprintf("%d", old.updated_at),
				form     = form,
			}
			return sqlite_review_reply(output, correlation, r, backing)
		}
		if !creating {
			if form.released_at != "" {r.status = "released"; return sqlite_review_reply(output, correlation, r, backing)}
			if q.if_revision != fmt.aprintf("%d", old.updated_at) {r.status = "conflict"; return sqlite_review_reply(output, correlation, r, backing)}
		}
	}
	if request.timestamp <= 0 || (!creating && old.updated_at == max(i64)) do return sql.FULL
	revision := creating ? request.timestamp : max(request.timestamp, old.updated_at + 1)
	switch q.op {
	case "update":
		form = q.form
	case "copy":
		form.released_at = ""
	case "release":
		if !pr.validate_review_form(form, true) do return sqlite_review_reply(output, correlation, r, backing)
		form.released_at = fmt.aprintf("%d", revision)
	}
	payload, je := json.marshal(form)
	if je != nil do return sql.ERROR
	if len(payload) > pr.MAX_REVIEW_FORM_BYTES do return sqlite_review_reply(output, correlation, r, backing)
	preview, pe := json.marshal(struct {
		title:       string,
		build:       string,
		released_at: string,
	}{form.title, form.build, form.released_at})
	if pe != nil do return sql.ERROR
	a := old
	if creating {
		id, rc := db.next_id(store, .Asset)
		if rc != sql.OK do return rc
		a = {
			asset_id   = id,
			asset_type = .ReviewForm,
			owner      = transmute([]byte)request.actor,
			created_at = revision,
		}
	}
	a.updated_at = revision
	a.preview = preview; a.payload = payload; a.payload_raw_len = u32(len(payload)); a.payload_encoding = .Plain
	if rc := sqlite_put_asset(store, request.workspace, &a, insert_only = creating); rc != sql.OK do return rc
	if rc := sqlite_asset_history(store, request, &old, &a, creating); rc != sql.OK do return rc
	r = {
		status   = "ok",
		form_id  = fmt.aprintf("%d", a.asset_id),
		revision = fmt.aprintf("%d", a.updated_at),
		form     = form,
	}
	if rc := sqlite_review_reply(output, correlation, r, backing); rc != sql.OK do return rc
	context.allocator = backing
	// Existing subscribers see the public form, never private invite/run state.
	if creating {
		msg := pr.AssetCreatedMessage {
			asset = a,
		}
		buf, rc := db.command_frame(output, pr.getSizeAssetCreatedMessage(msg), .Other_Subscribers)
		if rc != sql.OK do return rc
		return pr.serializeAssetCreatedMessage(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	msg := pr.AssetUpdatedMessage {
		asset = a,
	}
	buf, rc := db.command_frame(output, pr.getSizeAssetUpdatedMessage(msg), .Other_Subscribers)
	if rc != sql.OK do return rc
	return pr.serializeAssetUpdatedMessage(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
