package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import hgl "hegel"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// One live family at a time; history and ID floors survive deletion. Expected
// values come from the generated commands, never from returned IDs or SQL folds.
SQLite_Command_Model :: struct {
	cycle, workspace, phase: int,
	created, updated:        i64,
	priority:                u8,
	project:                 string,
	history:                 [2][3]i64, // created, updated, deleted events
	system_updates:          [2]i64,
}

// Logical snapshot of every persistent table, including history, ID floors and
// projections. Hex preserves embedded NULs; typeof preserves SQL types, and
// JSON framing preserves boundaries (the schema contains no REAL columns).
// Sort complete rows rather than relying on physical layout or index order.
sqlite_command_snapshot :: proc(store: ^db.Store) -> (snapshot: [dynamic]byte, why: string) {
	tables: ^sql.Statement
	query :: `SELECT name, 'SELECT json_group_array(r) FROM (SELECT json_array(' ||
 (SELECT group_concat('typeof("' || replace(name,'"','""') || '") || '':'' || hex("' || replace(name,'"','""') || '")', ',') FROM pragma_table_info(s.name)) ||
 ') r FROM "' || replace(name,'"','""') || '" ORDER BY r)'
 FROM sqlite_schema s WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`
	if sql.prepare_v2(store.db, query, -1, &tables, nil) != sql.OK do return snapshot, "snapshot table enumeration"
	defer sql.finalize(tables)
	for {
		rc := sql.step(tables)
		if rc == sql.DONE do break
		if rc != sql.ROW do return snapshot, "snapshot schema read"
		append(&snapshot, ..sql.column_bytes_view(tables, 0)); append(&snapshot, '\n')
		text := strings.clone_to_cstring(string(sql.column_bytes_view(tables, 1))); defer delete(text)
		rows: ^sql.Statement
		if sql.prepare_v2(store.db, text, -1, &rows, nil) != sql.OK do return snapshot, "snapshot table prepare"
		defer sql.finalize(rows)
		if sql.step(rows) != sql.ROW do return snapshot, "snapshot table read"
		append(&snapshot, ..sql.column_bytes_view(rows, 0)); append(&snapshot, '\n')
	}
	return snapshot, ""
}

sqlite_command_model_apply :: proc(
	store: ^db.Store,
	workspace: string,
	timestamp: i64,
	operations: []pr.TransactionOperation,
	ids: []u64,
	failed := max(u16),
	actor := "alice",
) -> string {
	wire: [8192]byte
	n := pr.serializeApplyTransactionRequest(701, operations, wire[:])
	if n < 2 do return "serialize command"
	before: [dynamic]byte
	defer delete(before)
	if failed != max(u16) {
		why: string
		before, why = sqlite_command_snapshot(store)
		if why != "" do return why
	}
	output := db.Command_Output {
		limit = 256 * 1024,
	}
	defer db.destroy_command_output(&output)
	if db.begin(store) != sql.OK do return "begin command"
	request := db.Request {
		opcode    = .C_ApplyTransaction,
		workspace = workspace,
		actor     = actor,
		subject   = "actor-a",
		timestamp = timestamp,
		body      = wire[2:n],
	}
	if sqlite_execute_task_command(store, &request, &output) != sql.OK {db.rollback(store); return "execute command"}
	if db.commit(store) != sql.OK {db.rollback(store); return "commit command"}
	results: [8]pr.TransactionOperationResult
	for id, i in ids {results[i] = {operations[i].op_type, id}}
	expected: [128]byte
	size := pr.serializeTransactionResult(701, failed == max(u16) ? .Committed : .Rejected, failed, results[:len(ids)], expected[:])
	seen := 0
	for frame in output.frames[:output.count] {
		if pr.get_opcode(frame.payload) == .S_TransactionResult {
			if string(frame.payload) != string(expected[:size]) do return "transaction result differs"
			seen += 1
		} else if failed != max(u16) {return "rejected command published events"}
	}
	if seen != 1 do return "missing or repeated transaction result"
	if failed != max(u16) {
		after, why := sqlite_command_snapshot(store); defer delete(after)
		if why != "" do return why
		if string(before[:]) != string(after[:]) do return "rejected command changed persistent tables"
	}
	return ""
}

sqlite_command_model_check :: proc(store: ^db.Store, m: SQLite_Command_Model) -> string {
	workspaces := SQLITE_MODEL_WORKSPACES
	for workspace, w in workspaces {
		live := w == m.workspace && m.phase != 2
		patched := m.phase == 1
		for i in 0 ..< 2 {
			id := u64(m.cycle * 2 + i + 1)
			task, found, rc := db.get_task(store, workspace, 0, id)
			defer db.destroy_task(&task)
			if rc != sql.OK || found != live do return "task presence"
			if !live do continue
			status := patched && i == 0 ? pr.TaskStatus.Done : .Backlog
			blocked := !patched && i == 1 ? u64(m.cycle * 2 + 1) : 0
			title := i == 0 ? "blocker" : (patched ? "patched" : "dependent")
			if string(task.title) != title || task.status != status || task.blocked_by != blocked || task.priority != m.priority || string(task.description) != "preserved" || string(task.project) != m.project || task.created_at != m.created || task.updated_at != (patched ? m.updated : m.created) do return "task fields"
			if task.completed_at != (patched && i == 0 ? m.updated : 0) || string(task.completed_by) != (patched && i == 0 ? "alice" : "") do return "task completion metadata"
		}
		// Counts detect leaked IDs/rows outside the currently expected family.
		for probe in ([?]struct {
				query:    cstring,
				expected: i64,
			}{{"SELECT count(*) FROM tasks WHERE workspace=?1", live ? 2 : 0}, {"SELECT count(*) FROM assets WHERE workspace=?1", live ? 1 : 0}, {"SELECT count(*) FROM edges WHERE workspace=?1", live ? 1 : 0}, {"SELECT count(*) FROM note_metadata WHERE workspace=?1", live ? 1 : 0}, {"SELECT count(*) FROM history WHERE workspace=?1 AND json_extract(body,'$.action')='created'", m.history[w][0]}, {"SELECT count(*) FROM history WHERE workspace=?1 AND json_extract(body,'$.action')='updated'", m.history[w][1]}, {"SELECT count(*) FROM history WHERE workspace=?1 AND json_extract(body,'$.action')='deleted'", m.history[w][2]}, {`SELECT count(*) FROM history WHERE workspace=?1 AND json_extract(body,'$.actorId')='system' AND json_extract(body,'$.fields')='["blocked_by"]'`, m.system_updates[w]}}) {
			s: ^sql.Statement
			if sql.prepare_v2(store.db, probe.query, -1, &s, nil) != sql.OK do return "prepare model count"
			defer sql.finalize(s)
			if sql.bind_bytes(s, 1, transmute([]byte)workspace) != sql.OK || sql.step(s) != sql.ROW || sql.column_int64(s, 0) != probe.expected do return string(probe.query)
		}
		if live {
			s: ^sql.Statement
			if sql.prepare_v2(store.db, "SELECT a.id,a.parent_id,a.created_at,a.updated_at,a.payload,n.project FROM assets a JOIN note_metadata n ON n.workspace=a.workspace AND n.asset_id=a.id WHERE a.workspace=?1", -1, &s, nil) != sql.OK do return "prepare note"
			defer sql.finalize(s)
			if sql.bind_bytes(s, 1, transmute([]byte)workspace) != sql.OK || sql.step(s) != sql.ROW do return "missing note projection"
			id, id_rc := sql.column_id(s, 0); parent, parent_rc := sql.column_id(s, 1)
			if id_rc != sql.OK || parent_rc != sql.OK || id != u64(m.cycle + 1) || parent != u64(m.cycle * 2 + 2) || sql.column_int64(s, 2) != m.created || sql.column_int64(s, 3) != (patched ? m.updated : m.created) || string(sql.column_bytes_view(s, 4)) != "body" || string(sql.column_bytes_view(s, 5)) != (patched ? "Q" : "P") do return "note fields or projection"
			e: ^sql.Statement
			if sql.prepare_v2(store.db, "SELECT id,source_type,source_id,target_type,target_id,relation FROM edges WHERE workspace=?1", -1, &e, nil) != sql.OK do return "prepare edge"
			defer sql.finalize(e)
			if sql.bind_bytes(e, 1, transmute([]byte)workspace) != sql.OK || sql.step(e) != sql.ROW do return "missing edge"
			edge_id, edge_rc := sql.column_id(e, 0); source, source_rc := sql.column_id(e, 2); target, target_rc := sql.column_id(e, 4)
			if edge_rc != sql.OK || source_rc != sql.OK || target_rc != sql.OK || edge_id != u64(m.cycle + 1) || source != u64(m.cycle + 1) || target != u64(m.cycle * 2 + 1) || sql.column_int64(e, 1) != i64(pr.TargetType.Asset) || sql.column_int64(e, 3) != i64(pr.TargetType.Task) || sql.column_int64(e, 5) != i64(pr.RelationType.RelatedTo) do return "edge identity or endpoints"
		}
		h: ^sql.Statement
		if sql.prepare_v2(store.db, "SELECT high_water FROM history_sequences WHERE workspace=?1", -1, &h, nil) != sql.OK do return "prepare history floor"
		defer sql.finalize(h)
		if sql.bind_bytes(h, 1, transmute([]byte)workspace) != sql.OK do return "bind history floor"
		expected_history := u64(m.history[w][0] + m.history[w][1] + m.history[w][2])
		rc := sql.step(h)
		if expected_history == 0 {
			if rc != sql.DONE do return "unexpected history sequence"
		} else {
			if rc != sql.ROW do return "missing history sequence"
			floor, floor_rc := sql.column_id(h, 0)
			if floor_rc != sql.OK || floor != expected_history do return "history floor differs"
		}
	}
	for domain, i in ([3]string{"task", "asset", "edge"}) {
		s: ^sql.Statement
		if sql.prepare_v2(store.db, "SELECT high_water FROM sequences WHERE domain=CAST(?1 AS TEXT)", -1, &s, nil) != sql.OK do return "prepare floor"
		defer sql.finalize(s)
		if sql.bind_bytes(s, 1, transmute([]byte)domain) != sql.OK || sql.step(s) != sql.ROW do return "read floor"
		floor, rc := sql.column_id(s, 0)
		if rc != sql.OK || floor != u64((m.cycle + 1) * (i == 0 ? 2 : 1)) do return "ID floor changed"
	}
	return ""
}

prop_sqlite_commands_match_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	dir, err := os.make_directory_temp("", "nrc-command-model-*", context.allocator)
	if err != nil do return hgl.interesting("temporary directory")
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if rc != sql.OK do return hgl.interesting("open command database")
	defer db.close(&store)
	m: SQLite_Command_Model
	workspaces := SQLITE_MODEL_WORKSPACES
	for cycle in 0 ..< 8 {
		choices: [4]i64
		for bound, i in ([4]i64{1, 5, 2, 1}) {
			value, draw_err := hgl.draw_i64(tc, 0, bound)
			if draw_err == .Stop_Test do return hgl.abort()
			if draw_err != nil do return hgl.interesting("draw command choice")
			choices[i] = value
		}
		m.cycle = cycle; m.workspace = int(choices[0]); m.phase = 0
		m.created = i64(100 + cycle * 10); m.priority = u8(choices[1]); m.project = choices[3] == 0 ? "P" : "Q"
		workspace := workspaces[m.workspace]
		blocker, dependent, asset, edge := u64(cycle * 2 + 1), u64(cycle * 2 + 2), u64(cycle + 1), u64(cycle + 1)
		b: [4][1024]byte
		sizes: [4]int
		sizes[0] = pr.serializeTransactionTaskCreate(
			{
				title = transmute([]byte)string("blocker"),
				description = transmute([]byte)string("preserved"),
				project = transmute([]byte)m.project,
				priority = m.priority,
				blocked_by = {.Existing, .Task, 0},
			},
			b[0][:],
		)
		sizes[1] = pr.serializeTransactionTaskCreate(
			{
				title = transmute([]byte)string("dependent"),
				description = transmute([]byte)string("preserved"),
				project = transmute([]byte)m.project,
				priority = m.priority,
				blocked_by = {.CreatedBy, .Task, 0},
			},
			b[1][:],
		)
		sizes[2] = pr.serializeTransactionAssetCreate(
			{
				asset_type = .Note,
				parent_type = .Task,
				parent = {.CreatedBy, .Task, 1},
				preview = transmute([]byte)string(`{"project":"P"}`),
				payload = transmute([]byte)string("body"),
				payload_raw_len = 4,
			},
			b[2][:],
		)
		sizes[3] = pr.serializeTransactionEdgeCreate({source = {.CreatedBy, .Asset, 2}, target = {.CreatedBy, .Task, 0}, relation = .RelatedTo}, b[3][:])
		for n in sizes {if n <= 0 do return hgl.interesting("serialize create")}
		creates := [4]pr.TransactionOperation {
			{.TaskCreate, b[0][:sizes[0]]},
			{.TaskCreate, b[1][:sizes[1]]},
			{.AssetCreate, b[2][:sizes[2]]},
			{.EdgeCreate, b[3][:sizes[3]]},
		}
		if why := sqlite_command_model_apply(&store, workspace, m.created, creates[:], {blocker, dependent, asset, edge}); why != "" do return hgl.interesting(why)
		m.history[m.workspace][0] += 4
		if why := sqlite_command_model_check(&store, m); why != "" do return hgl.interesting(why)
		// Reserve a Task ID, then reject a stale guard or deletion of a live
		// blocker. The latter rejects after the create wrote history and events.
		rejected_kind := pr.TransactionOperationType.TaskPatch
		sizes[2] = pr.serializeTransactionTaskPatch(
			{
				task = {.Existing, .Task, blocker},
				if_updated_at = m.created + 1,
				present = pr.TRANSACTION_TASK_PATCH_TITLE,
				title = transmute([]byte)string("rejected"),
			},
			b[2][:],
		)
		if cycle % 2 != 0 {
			rejected_kind = .TaskDelete
			sizes[2] = pr.serializeTransactionDelete({entity = {.Existing, .Task, blocker}}, b[2][:], .Task)
		}
		if why := sqlite_command_model_apply(&store, workspace, m.created, {{.TaskCreate, creates[0].body}, {rejected_kind, b[2][:sizes[2]]}}, nil, 1); why != "" do return hgl.interesting(why)
		if why := sqlite_command_model_check(&store, m); why != "" do return hgl.interesting(why)
		// Both patch orders must split user changes from automatic unblocking.
		sizes[0] = pr.serializeTransactionTaskPatch({task = {.Existing, .Task, blocker}, present = pr.TRANSACTION_TASK_PATCH_STATUS, status = .Done}, b[0][:])
		sizes[1] = pr.serializeTransactionTaskPatch(
			{task = {.Existing, .Task, dependent}, present = pr.TRANSACTION_TASK_PATCH_TITLE, title = transmute([]byte)string("patched")},
			b[1][:],
		)
		sizes[2] = pr.serializeTransactionAssetPatch(
			{asset = {.Existing, .Asset, asset}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)string(`{"project":"Q"}`)},
			b[2][:],
		)
		patches := [3]pr.TransactionOperation{{.TaskPatch, b[0][:sizes[0]]}, {.TaskPatch, b[1][:sizes[1]]}, {.AssetPatch, b[2][:sizes[2]]}}
		patch_ids := [3]u64{blocker, dependent, asset}
		if choices[3] != 0 {patches[0], patches[1] = patches[1], patches[0]; patch_ids[0], patch_ids[1] = patch_ids[1], patch_ids[0]}
		time_offsets := [3]i64{-3, 0, 7}
		at := m.created + time_offsets[choices[2]]
		if why := sqlite_command_model_apply(&store, workspace, at, patches[:], patch_ids[:]); why != "" do return hgl.interesting(why)
		m.phase = 1; m.updated = m.created + (choices[2] == 2 ? 7 : 1); m.history[m.workspace][1] += 4; m.system_updates[m.workspace] += 1
		if db.close(&store) != sql.OK do return hgl.interesting("close patched commands")
		store, rc = db.open(path)
		if rc != sql.OK do return hgl.interesting("reopen patched commands")
		if why := sqlite_command_model_check(&store, m); why != "" do return hgl.interesting(why)
		// Alternate explicit deletions and Task cascades. Every history covers
		// all eight operation types and both deletion contracts.
		sizes[0] = pr.serializeTransactionDelete({entity = {.Existing, .Edge, edge}}, b[0][:], .Edge)
		sizes[1] = pr.serializeTransactionDelete({entity = {.Existing, .Asset, asset}}, b[1][:], .Asset)
		sizes[2] = pr.serializeTransactionDelete({entity = {.Existing, .Task, dependent}}, b[2][:], .Task)
		sizes[3] = pr.serializeTransactionDelete({entity = {.Existing, .Task, blocker}}, b[3][:], .Task)
		deletes := [4]pr.TransactionOperation {
			{.EdgeDelete, b[0][:sizes[0]]},
			{.AssetDelete, b[1][:sizes[1]]},
			{.TaskDelete, b[2][:sizes[2]]},
			{.TaskDelete, b[3][:sizes[3]]},
		}
		delete_ids := [4]u64{edge, asset, dependent, blocker}
		start := cycle % 2 == 0 ? 0 : 2
		if why := sqlite_command_model_apply(&store, workspace, m.created + 3, deletes[start:], delete_ids[start:]); why != "" do return hgl.interesting(why)
		m.phase = 2; m.history[m.workspace][2] += 4
		if db.close(&store) != sql.OK do return hgl.interesting("close commands")
		store, rc = db.open(path)
		if rc != sql.OK do return hgl.interesting("reopen commands")
		if why := sqlite_command_model_check(&store, m); why != "" do return hgl.interesting(why)
	}
	return hgl.valid()
}

@(test)
test_hegel_sqlite_commands_match_model :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_sqlite_commands_match_model, nil, {test_cases = 40})
	testing.expectf(t, err == nil && result.passed, "SQLite command histories: %v", err)
}
