package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import hgl "hegel"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// This model covers the original generic types. Monitoring's machine-owned
// lifecycle and config validation are exercised by sqlite_monitoring_test.odin.
#assert(min(pr.AssetType) == .Comment && int(pr.AssetType.TicketEntry) == 14 && max(pr.AssetType) == .MonitorSource)
#assert(pr.TRANSACTION_ASSET_PATCH_PREVIEW == 1 && pr.TRANSACTION_ASSET_PATCH_PAYLOAD == 2)

sqlite_command_asset_preview :: proc(kind: pr.AssetType) -> string {
	#partial switch kind {
	case .Note:
		return `{"title":"First","project":"P","tags":["old"]}`
	case .Reminder:
		return `{"visibility":"personal","title":"First"}`
	case .Slice:
		return `{"version":1,"name":"First"}`
	case .Appointment:
		return(
			`{"version":2,"title":"First","start_at":"1792404000000000000","end_at":"1792407600000000000","timezone":"UTC","repeat":"weekly","weekdays":[1,3],"until":"","participants":["bob"],"conference":"nrc","exceptions":[],"assignee":"alice"}` \
		)
	case .Ticket:
		return `{"version":1,"title":"First","company_id":"","contact_id":"","requester":"","requester_name":"","status":"open","assignee":""}`
	case .TicketEntry:
		return `{"version":1,"kind":"internal_note","author":"First"}`
	case .CustomerCompany, .CustomerContact, .CustomerActivity:
		return `{"version":1,"title":"First","email":"first@example.test","archived":false}`
	case .RoomMapping:
		return "MODEL-ROOM"
	}
	return "First"
}

sqlite_command_special_asset_create :: proc(store: ^db.Store, kind: pr.AssetType, id: u64) -> string {
	wire: [4096]byte
	n := pr.serializeCreateAssetRequest({asset_type = kind, preview = transmute([]byte)sqlite_command_asset_preview(kind), correlation_id = 55}, wire[:])
	if n < 2 do return "serialize special asset"
	if db.begin(store) != sql.OK do return "begin special asset"
	output := db.Command_Output {
		limit = 256 * 1024,
	}; defer db.destroy_command_output(&output)
	r := db.Request {
		opcode    = .C_CreateAsset,
		workspace = "assets",
		actor     = "alice",
		subject   = "actor-a",
		timestamp = 100,
		body      = wire[2:n],
	}
	if sqlite_execute_task_command(store, &r, &output) != sql.OK {db.rollback(store); return "special asset command"}
	if db.commit(store) != sql.OK {db.rollback(store); return "special asset commit"}
	seen := false
	for frame in output.frames[:output.count] {
		if frame.audience != .Requester do continue
		if pr.get_opcode(frame.payload) == .S_AssetCreated {
			message, err := pr.parseAssetCreatedMessage(frame.payload)
			if err != nil || message.asset.asset_id != id || message.correlation_id != 55 do return "special create result"
		} else if pr.get_opcode(frame.payload) == .S_AssetUpdated && kind == .Agenda {
			message, err := pr.parseAssetUpdatedMessage(frame.payload)
			if err != nil || message.asset.asset_id != id do return "agenda stable ID"
		} else {return "special create rejected"}
		seen = true
	}
	if !seen do return "missing special response"
	return ""
}

sqlite_command_asset_check :: proc(store: ^db.Store, a: pr.Asset, exists: bool, expected_floor: u64) -> string {
	s: ^sql.Statement
	if sql.prepare_v2(store.db, "SELECT asset_type,parent_type,parent_id,owner,created_at,updated_at,preview,payload,payload_encoding,payload_raw_len FROM assets WHERE workspace=x'617373657473' AND id=?1", -1, &s, nil) != sql.OK do return "prepare asset check"
	defer sql.finalize(s)
	if sql.bind_id(s, 1, a.asset_id) != sql.OK do return "bind asset check"
	rc := sql.step(s)
	if !exists {
		if rc != sql.DONE do return "deleted asset survived"
	} else {
		if rc != sql.ROW do return "missing asset"
		parent, parent_rc := sql.column_id(s, 2)
		if parent_rc != sql.OK || parent != a.parent_id || sql.column_int64(s, 0) != i64(a.asset_type) || sql.column_int64(s, 1) != i64(a.parent_type) || string(sql.column_bytes_view(s, 3)) != "alice" || sql.column_int64(s, 4) != 100 || sql.column_int64(s, 5) != a.updated_at || string(sql.column_bytes_view(s, 6)) != string(a.preview) do return "asset fields changed"
		// RoomMapping payload is server-generated; its normalized key and
		// stable ID are checked separately rather than copied into this model.
		if a.asset_type != .RoomMapping && (string(sql.column_bytes_view(s, 7)) != string(a.payload) || sql.column_int64(s, 8) != i64(a.payload_encoding) || sql.column_int64(s, 9) != i64(a.payload_raw_len)) do return "asset payload or omitted fields changed"
	}
	f: ^sql.Statement
	if sql.prepare_v2(store.db, "SELECT high_water FROM sequences WHERE domain='asset'", -1, &f, nil) != sql.OK do return "prepare asset floor"
	defer sql.finalize(f)
	if sql.step(f) != sql.ROW do return "read asset floor"
	floor, floor_rc := sql.column_id(f, 0)
	if floor_rc != sql.OK || floor != expected_floor do return "asset floor leaked"
	return ""
}

prop_sqlite_command_assets :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	dir, err := os.make_directory_temp("", "nrc-command-assets-*", context.allocator)
	if err != nil do return hgl.interesting("temporary directory")
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if rc != sql.OK do return hgl.interesting("open assets database")
	defer db.close(&store)
	rotation, e := hgl.draw_i64(tc, 0, 13); if e == .Stop_Test do return hgl.abort(); if e != nil do return hgl.interesting("draw asset order")
	buffer: [8192]byte
	// Stable Ticket parent makes TicketEntry valid regardless of type order.
	n := pr.serializeTransactionAssetCreate({asset_type = .Ticket, preview = transmute([]byte)sqlite_command_asset_preview(.Ticket)}, buffer[:])
	if why := sqlite_command_model_apply(&store, "assets", 100, {{.AssetCreate, buffer[:n]}}, {1}); why != "" do return hgl.interesting(why)
	floor: u64 = 1
	coverage: [14]u16
	for offset in 0 ..< 14 {
		index := (offset + int(rotation)) % 14
		kind := pr.AssetType(index + 1)
		preview := sqlite_command_asset_preview(kind)
		changed, allocated := strings.replace_all(preview, "First", "Second"); defer {if allocated do delete(changed)}
		payload :=
			kind == .Reminder ? `{"visibility":"personal","title":"First"}` : (kind == .Appointment || kind == .RoomMapping || kind == .Agenda ? "" : "body")
		m := pr.Asset {
			asset_id        = floor + 1,
			asset_type      = kind,
			preview         = transmute([]byte)preview,
			payload         = transmute([]byte)payload,
			payload_raw_len = u32(len(payload)),
			created_at      = 100,
			updated_at      = 100,
		}
		if kind == .TicketEntry {m.parent_type = .Asset; m.parent_id = 1}
		create := pr.TransactionAssetCreate {
			asset_type      = kind,
			parent_type     = m.parent_type,
			parent          = {.Existing, .Asset, m.parent_id},
			preview         = m.preview,
			payload         = m.payload,
			payload_raw_len = m.payload_raw_len,
		}
		n = pr.serializeTransactionAssetCreate(create, buffer[:]); if n <= 0 do return hgl.interesting("serialize asset type")
		forbidden := kind == .Agenda || kind == .RoomMapping
		ids := [1]u64{m.asset_id}
		if why := sqlite_command_model_apply(&store, "assets", 100, {{.AssetCreate, buffer[:n]}}, ids[:forbidden ? 0 : 1], forbidden ? 0 : max(u16)); why != "" do return hgl.interesting(why)
		if forbidden {
			if why := sqlite_command_asset_check(&store, m, false, floor); why != "" do return hgl.interesting(why)
			if why := sqlite_command_special_asset_create(&store, kind, m.asset_id); why != "" do return hgl.interesting(why)
		}
		floor += 1
		if why := sqlite_command_asset_check(&store, m, true, floor); why != "" do return hgl.interesting(why)
		coverage[index] |= 1
		if forbidden {
			if why := sqlite_command_special_asset_create(&store, kind, m.asset_id); why != "" do return hgl.interesting(why)
			if kind == .Agenda do m.updated_at += 1
			if why := sqlite_command_asset_check(&store, m, true, floor); why != "" do return hgl.interesting(why)
			if kind == .RoomMapping {
				s: ^sql.Statement
				if sql.prepare_v2(store.db, "SELECT count(*) FROM room_mappings WHERE workspace=x'617373657473' AND name=x'4d4f44454c2d524f4f4d'", -1, &s, nil) != sql.OK do return hgl.interesting("prepare room mapping")
				unique := sql.step(s) == sql.ROW && sql.column_int64(s, 0) == 1
				sql.finalize(s)
				if !unique do return hgl.interesting("room mapping not unique")
			}
		}
		for step in 0 ..< 9 {
			p := pr.TransactionAssetPatch {
				asset         = {.Existing, .Asset, m.asset_id},
				if_updated_at = m.updated_at,
			}
			next := m
			accepted := kind != .RoomMapping
			actor := "alice"
			switch step {
			case 0:
				p.present = pr.TRANSACTION_ASSET_PATCH_PREVIEW; p.preview = transmute([]byte)changed; next.preview = p.preview
			case 1:
				p.present = pr.TRANSACTION_ASSET_PATCH_PAYLOAD
				body: string = kind == .Reminder ? `{"visibility":"personal","title":"Second"}` : "changed"
				p.payload = transmute([]byte)body
				p.payload_raw_len = u32(len(p.payload)); next.payload = p.payload; next.payload_raw_len = p.payload_raw_len
				if kind == .Appointment do accepted = false
			case 2:
				p.present = pr.TRANSACTION_ASSET_PATCH_PREVIEW; next.preview = nil
				if kind == .Slice || kind == .Ticket || kind == .TicketEntry || kind == .Appointment || kind == .Reminder do accepted = false
			case 3:
				p.present = pr.TRANSACTION_ASSET_PATCH_PAYLOAD; next.payload = nil; next.payload_raw_len = 0
				if kind == .Reminder || kind == .TicketEntry do accepted = false
			case 4:
				p.present = pr.TRANSACTION_ASSET_PATCH_PREVIEW; p.preview = m.preview; p.if_updated_at += 1; accepted = false
			case 5:
				p.present = pr.TRANSACTION_ASSET_PATCH_PREVIEW; p.preview = m.preview
				if kind == .Reminder || kind == .Appointment {actor = "bob"; accepted = false}
			case 6, 7:
				p.present = pr.TRANSACTION_ASSET_PATCH_PAYLOAD
				accepted = false
			case 8:
				p.present = pr.TRANSACTION_ASSET_PATCH_PREVIEW | pr.TRANSACTION_ASSET_PATCH_PAYLOAD
				p.preview = transmute([]byte)preview; p.payload = transmute([]byte)payload; p.payload_raw_len = u32(len(payload))
				next.preview = p.preview; next.payload = p.payload; next.payload_raw_len = p.payload_raw_len
			}
			n = pr.serializeTransactionAssetPatch(p, buffer[:]); if n <= 0 do return hgl.interesting("serialize asset patch")
			// Bypass serializer checks to send malformed encoding / Plain length
			// through the same command boundary used by actual clients.
			if step == 6 do buffer[29] = 255
			if step == 7 do endian.put_u32(buffer[30:], .Big, 1)
			if why := sqlite_command_model_apply(&store, "assets", m.updated_at - 2, {{.AssetPatch, buffer[:n]}}, ids[:accepted ? 1 : 0], accepted ? max(u16) : 0, actor); why != "" do return hgl.interesting(why)
			if accepted {next.updated_at = m.updated_at + 1; m = next}
			if db.close(&store) != sql.OK do return hgl.interesting("close assets")
			store, rc = db.open(path); if rc != sql.OK do return hgl.interesting("reopen assets")
			if why := sqlite_command_asset_check(&store, m, true, floor); why != "" do return hgl.interesting(why)
			coverage[index] |= u16(1 << uint(step + 1))
		}
		n = pr.serializeTransactionDelete({entity = {.Existing, .Asset, m.asset_id}}, buffer[:], .Asset)
		immutable := kind == .RoomMapping
		if kind == .Reminder || kind == .Appointment {
			if why := sqlite_command_model_apply(&store, "assets", m.updated_at + 1, {{.AssetDelete, buffer[:n]}}, nil, 0, "bob"); why != "" do return hgl.interesting(why)
			if db.close(&store) != sql.OK do return hgl.interesting("close rejected delete")
			store, rc = db.open(path); if rc != sql.OK do return hgl.interesting("reopen rejected delete")
			if why := sqlite_command_asset_check(&store, m, true, floor); why != "" do return hgl.interesting(why)
			coverage[index] |= 2048
		}
		if why := sqlite_command_model_apply(&store, "assets", m.updated_at + 1, {{.AssetDelete, buffer[:n]}}, ids[:immutable ? 0 : 1], immutable ? 0 : max(u16)); why != "" do return hgl.interesting(why)
		if why := sqlite_command_asset_check(&store, m, immutable, floor); why != "" do return hgl.interesting(why)
		coverage[index] |= 1024
	}
	for covered, index in coverage {
		kind := pr.AssetType(index + 1)
		expected: u16 = kind == .Reminder || kind == .Appointment ? 4095 : 2047
		if covered != expected do return hgl.interesting("missing mandatory AssetType case")
	}
	return hgl.valid()
}

@(test)
test_hegel_sqlite_command_assets :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_sqlite_command_assets, nil, {test_cases = 20})
	testing.expectf(t, err == nil && result.passed, "Asset command type coverage: %v", err)
}

@(test)
test_sqlite_command_late_asset_rejection_rolls_back :: proc(t: ^testing.T) {
	for kind in ([4]pr.AssetType{.Slice, .Reminder, .Appointment, .TicketEntry}) {
		dir, err := os.make_directory_temp("", "nrc-command-rollback-*", context.allocator)
		if !testing.expect(t, err == nil) do return
		defer {os.remove_all(dir); delete(dir)}
		name := fmt.aprintf("%s/model.db", dir); defer delete(name)
		path := strings.clone_to_cstring(name); defer delete(path)
		store, rc := db.open(path, true)
		if !testing.expect_value(t, rc, sql.OK) do return
		defer db.close(&store)
		b: [4][2048]byte
		n: [4]int
		// A real membership gives the rollback nonempty projection state.
		n[0] = pr.serializeTransactionAssetCreate({asset_type = .Note, preview = transmute([]byte)string(`{"title":"before","project":"P"}`)}, b[0][:])
		n[1] = pr.serializeTransactionAssetCreate({asset_type = .Slice, preview = transmute([]byte)sqlite_command_asset_preview(.Slice)}, b[1][:])
		n[2] = pr.serializeTransactionEdgeCreate({source = {.CreatedBy, .Asset, 0}, target = {.CreatedBy, .Asset, 1}, relation = .MemberOf}, b[2][:])
		n[3] = pr.serializeTransactionAssetCreate({asset_type = .Ticket, preview = transmute([]byte)sqlite_command_asset_preview(.Ticket)}, b[3][:])
		if !testing.expect_value(t, sqlite_command_model_apply(&store, "rollback", 100, {{.AssetCreate, b[0][:n[0]]}, {.AssetCreate, b[1][:n[1]]}, {.EdgeCreate, b[2][:n[2]]}, {.AssetCreate, b[3][:n[3]]}}, {1, 2, 1, 3}), "") do return
		before, why := sqlite_command_snapshot(&store); defer delete(before)
		if !testing.expect_value(t, why, "") do return
		// Three valid operations precede a type-specific rejection in the
		// asset execution phase, after records, projections and history writes.
		n[0] = pr.serializeTransactionTaskCreate({title = transmute([]byte)string("new task"), blocked_by = {.Existing, .Task, 0}}, b[0][:])
		n[1] = pr.serializeTransactionAssetPatch(
			{
				asset = {.Existing, .Asset, 1},
				present = pr.TRANSACTION_ASSET_PATCH_PREVIEW,
				preview = transmute([]byte)string(`{"title":"after","project":"Q"}`),
			},
			b[1][:],
		)
		n[2] = pr.serializeTransactionAssetCreate({asset_type = .Note, preview = transmute([]byte)string(`{"title":"new note","project":"R"}`)}, b[2][:])
		bad := pr.TransactionAssetCreate {
			asset_type = kind,
			preview    = transmute([]byte)sqlite_command_asset_preview(kind),
		}
		#partial switch kind {
		case .Slice:
			bad.preview = nil
		case .Reminder:
			bad.payload = transmute([]byte)string(`{"visibility":"workspace"}`)
		case .Appointment:
			bad.payload = transmute([]byte)string("forbidden body")
		case .TicketEntry:
			bad.parent_type = .Asset; bad.parent = {.Existing, .Asset, 3} // Valid Ticket parent, missing mandatory body.
		}
		bad.payload_raw_len = u32(len(bad.payload))
		n[3] = pr.serializeTransactionAssetCreate(bad, b[3][:])
		for size in n {if !testing.expect(t, size > 0) do return}
		ops := [4]pr.TransactionOperation{{.TaskCreate, b[0][:n[0]]}, {.AssetPatch, b[1][:n[1]]}, {.AssetCreate, b[2][:n[2]]}, {.AssetCreate, b[3][:n[3]]}}
		if !testing.expect_value(t, sqlite_command_model_apply(&store, "rollback", 200, ops[:], nil, 3), "") do return
		if !testing.expect_value(t, db.close(&store), sql.OK) do return
		store, rc = db.open(path)
		if !testing.expect_value(t, rc, sql.OK) do return
		after, after_why := sqlite_command_snapshot(&store); defer delete(after)
		if !testing.expect_value(t, after_why, "") do return
		if !testing.expect_value(t, string(after[:]), string(before[:])) do return
		// Positive control: the identical prefix commits, reuses rolled-back
		// IDs, and actually changes the Note's project and history/projections.
		if !testing.expect_value(t, sqlite_command_model_apply(&store, "rollback", 200, ops[:3], {1, 1, 4}), "") do return
		s: ^sql.Statement
		if !testing.expect_value(
			t,
			sql.prepare_v2(
				store.db,
				`SELECT
 (SELECT count(*) FROM tasks)=1 AND (SELECT count(*) FROM assets)=4 AND
 (SELECT count(*) FROM history)=7 AND
 (SELECT count(*) FROM note_metadata WHERE project=x'51')=1 AND
 (SELECT count(*) FROM slice_projects WHERE project=x'51')=1 AND
 (SELECT count(*) FROM slice_projects WHERE project=x'50')=0`,
				-1,
				&s,
				nil,
			),
			sql.OK,
		) {return}
		defer sql.finalize(s)
		if !testing.expect_value(t, sql.step(s), sql.ROW) do return
		testing.expect_value(t, sql.column_int64(s, 0), i64(1))
	}
}
