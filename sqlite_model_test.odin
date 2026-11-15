package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import hgl "hegel"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Value-only reference state: no production folds, projection reads or indexes
// are used to derive expectations. IDs deliberately overlap across entity types
// and workspaces; memberships may outlive either endpoint.
SQLite_Model_Task :: struct {
	exists:         bool,
	status:         pr.TaskStatus,
	created, moved: i64,
	blocked:        bool,
	project:        int,
}
SQLite_Model_Workspace :: struct {
	tasks:         [4]SQLite_Model_Task,
	assets:        [4]struct {
		exists:  bool,
		moved:   i64,
		project: int,
	},
	asset_edges:   [2][4]bool,
	slices:        [2]bool,
	slice_created: [2]i64,
	edges:         [2][4]bool,
}
SQLITE_MODEL_WORKSPACES :: [2]string{"model-a", "model-b"}
SQLITE_MODEL_PROJECTS :: [3]string{"", "P", "Q"}
SQLITE_MODEL_ASSET_TYPES :: [4]pr.AssetType{.Note, .Note, .File, .Ticket}
SQLITE_MODEL_PREVIEWS :: [3]string{`{"project":""}`, `{"project":"P"}`, `{"project":"Q"}`}
SQLITE_MODEL_TICKET_PREVIEWS :: [3]string {
	`{"version":1,"title":"Model ticket","company_id":"","contact_id":"","requester":"","requester_name":"","status":"open","assignee":"","project":""}`,
	`{"version":1,"title":"Model ticket","company_id":"","contact_id":"","requester":"","requester_name":"","status":"open","assignee":"","project":"P"}`,
	`{"version":1,"title":"Model ticket","company_id":"","contact_id":"","requester":"","requester_name":"","status":"open","assignee":"","project":"Q"}`,
}

sqlite_model_slice :: proc(store: ^db.Store, workspace: string, id: u64, exists: bool, created: i64) -> bool {
	a := pr.Asset {
		asset_id   = id,
		asset_type = .Slice,
		created_at = created,
		preview    = transmute([]byte)string(`{"version":1,"name":"Model"}`),
	}
	if exists do return sqlite_put_asset(store, workspace, &a) == sql.OK
	return sqlite_projection_write(store, "DELETE FROM assets WHERE workspace=?1 AND id=?2", workspace, &a, nil) == sql.OK
}

sqlite_model_action :: proc(store: ^db.Store, model: ^[2]SQLite_Model_Workspace, values: [8]i64) -> bool {
	w, task, slice := int(values[1]), int(values[2]), int(values[3])
	m := &model[w]
	workspaces, projects := SQLITE_MODEL_WORKSPACES, SQLITE_MODEL_PROJECTS
	asset_types, previews := SQLITE_MODEL_ASSET_TYPES, SQLITE_MODEL_PREVIEWS
	workspace := workspaces[w]
	switch values[0] {
	case 0, 1:
		times := [4]i64{-3, 0, 7, 19}
		entry := SQLite_Model_Task{true, pr.TaskStatus(values[4]), times[values[5]], times[values[6]], values[7] >= 3, int(values[7] % 3)}
		t := pr.Task {
			id         = u64(task + 1),
			title      = transmute([]byte)string("Model task"),
			status     = entry.status,
			created_at = entry.created,
			updated_at = entry.moved,
			blocked_by = entry.blocked ? 99 : 0,
			project    = transmute([]byte)projects[entry.project],
		}
		if db.put_task(store, workspace, &t) != sql.OK do return false
		m.tasks[task] = entry
	case 2:
		if db.remove_task(store, workspace, 0, u64(task + 1)) != sql.OK do return false
		m.tasks[task] = {}
	case 3:
		key := pr.Asset {
			asset_id = u64(slice * 4 + task + 1),
		}
		if m.edges[slice][task] {
			if sqlite_projection_write(store, "DELETE FROM edges WHERE workspace=?1 AND id=?2", workspace, &key, nil) != sql.OK do return false
		} else {
			// Alternate endpoint direction without changing membership identity.
			query := cstring("INSERT INTO edges VALUES(?1,?2,2,?3,1,?4,7,0,x'')")
			if task % 2 != 0 do query = "INSERT INTO edges VALUES(?1,?2,1,?4,2,?3,7,0,x'')"
			if sqlite_projection_write(store, query, workspace, &key, {u64(task + 1), u64(slice + 1)}) != sql.OK do return false
		}
		m.edges[slice][task] = !m.edges[slice][task]
	case 4, 5:
		live := values[0] == 4 ? !m.slices[slice] : m.slices[slice]
		times := [4]i64{0, 5, 23, 80}
		created := live ? times[values[5]] : 0
		if values[0] == 5 {
			// Exercise the storage trigger used by offline timestamp corrections.
			// Ordinary asset updates intentionally preserve created_at.
			key := pr.Asset {
				asset_id = u64(slice + 1),
			}
			if sqlite_projection_write(store, "UPDATE assets SET created_at=?3 WHERE workspace=?1 AND id=?2", workspace, &key, {created}) != sql.OK do return false
		} else if !sqlite_model_slice(store, workspace, u64(slice + 1), live, created) do return false
		m.slices[slice] = live
		m.slice_created[slice] = created
	case 6:
		// Asset IDs 3..6 overlap tasks, but never the Slice assets (1..2).
		// Types stay fixed: ordinary upserts preserve the original asset type.
		times := [4]i64{-5, 0, 13, 97}
		project := int(values[7] % 3)
		if asset_types[task] == .Ticket do previews = SQLITE_MODEL_TICKET_PREVIEWS
		a := pr.Asset {
			asset_id   = u64(task + 3),
			asset_type = asset_types[task],
			updated_at = times[values[6]],
			preview    = transmute([]byte)previews[project],
		}
		if sqlite_put_asset(store, workspace, &a) != sql.OK do return false
		m.assets[task] = {true, a.updated_at, project}
	case 7:
		key := pr.Asset {
			asset_id = u64(task + 3),
		}
		if sqlite_projection_write(store, "DELETE FROM assets WHERE workspace=?1 AND id=?2", workspace, &key, nil) != sql.OK do return false
		m.assets[task] = {}
	case 8:
		key := pr.Asset {
			asset_id = u64(9 + slice * 4 + task),
		}
		if m.asset_edges[slice][task] {
			if sqlite_projection_write(store, "DELETE FROM edges WHERE workspace=?1 AND id=?2", workspace, &key, nil) != sql.OK do return false
		} else {
			query := cstring("INSERT INTO edges VALUES(?1,?2,1,?3,1,?4,7,0,x'')")
			if task % 2 != 0 do query = "INSERT INTO edges VALUES(?1,?2,1,?4,1,?3,7,0,x'')"
			if sqlite_projection_write(store, query, workspace, &key, {u64(task + 3), u64(slice + 1)}) != sql.OK do return false
		}
		m.asset_edges[slice][task] = !m.asset_edges[slice][task]
	}
	return true
}

sqlite_model_check :: proc(store: ^db.Store, model: [2]SQLite_Model_Workspace) -> string {
	workspaces, project_names := SQLITE_MODEL_WORKSPACES, SQLITE_MODEL_PROJECTS
	asset_types := SQLITE_MODEL_ASSET_TYPES
	for m, w in model {
		workspace := workspaces[w]
		totals, covered: [5]i64
		for expected, i in m.tasks {
			actual, found, rc := db.get_task(store, workspace, 0, u64(i + 1))
			defer db.destroy_task(&actual)
			if rc != sql.OK || found != expected.exists do return "canonical task presence differs"
			if !found do continue
			if actual.status != expected.status ||
			   actual.created_at != expected.created ||
			   actual.updated_at != expected.moved ||
			   (actual.blocked_by != 0) != expected.blocked ||
			   string(actual.project) != project_names[expected.project] {
				return "canonical task fields differ"
			}
			totals[int(expected.status)] += 1
			if expected.status != .Note && ((m.slices[0] && m.edges[0][i]) || (m.slices[1] && m.edges[1][i])) do covered[int(expected.status)] += 1
		}
		for expected, i in m.assets {
			member_previews := asset_types[i] == .Ticket ? SQLITE_MODEL_TICKET_PREVIEWS : SQLITE_MODEL_PREVIEWS
			a: ^sql.Statement
			if sql.prepare_v2(store.db, "SELECT asset_type,updated_at,preview FROM assets WHERE workspace=?1 AND id=?2", -1, &a, nil) != sql.OK do return "prepare asset"
			defer sql.finalize(a)
			if sql.bind_bytes(a, 1, transmute([]byte)workspace) != sql.OK || sql.bind_id(a, 2, u64(i + 3)) != sql.OK do return "bind asset"
			rc := sql.step(a)
			if !expected.exists {if rc != sql.DONE do return "deleted asset survived"} else {
				if rc != sql.ROW || sql.column_int64(a, 0) != i64(asset_types[i]) || sql.column_int64(a, 1) != expected.moved || string(sql.column_bytes_view(a, 2)) != member_previews[expected.project] do return "canonical asset differs"
			}
		}
		for live, slice in m.slices {
			counts: [4]i64
			asset_counts: [3]i64
			projects: [3]i64
			blocked, work, oldest, moved: i64
			for task, i in m.tasks {
				edge: ^sql.Statement
				if sql.prepare_v2(store.db, "SELECT count(*) FROM edges WHERE workspace=?1 AND id=?2 AND relation=7 AND ((source_type=2 AND source_id=?3 AND target_type=1 AND target_id=?4) OR (source_type=1 AND source_id=?4 AND target_type=2 AND target_id=?3))", -1, &edge, nil) != sql.OK do return "prepare membership"
				defer sql.finalize(edge)
				if sql.bind_bytes(edge, 1, transmute([]byte)workspace) != sql.OK || sql.bind_id(edge, 2, u64(slice * 4 + i + 1)) != sql.OK || sql.bind_id(edge, 3, u64(i + 1)) != sql.OK || sql.bind_id(edge, 4, u64(slice + 1)) != sql.OK do return "bind membership"
				if sql.step(edge) != sql.ROW || sql.column_int64(edge, 0) != i64(m.edges[slice][i]) do return "canonical membership differs"
				if !m.edges[slice][i] || !task.exists || task.status == .Note do continue
				counts[int(task.status)] += 1
				work += 1
				if task.blocked do blocked += 1
				if task.project != 0 do projects[task.project] += 1
				if task.moved > moved do moved = task.moved
				if task.status != .Done && task.created != 0 && (oldest == 0 || task.created < oldest) do oldest = task.created
			}
			for asset, i in m.assets {
				edge: ^sql.Statement
				if sql.prepare_v2(store.db, "SELECT count(*) FROM edges WHERE workspace=?1 AND id=?2 AND relation=7 AND source_type=1 AND target_type=1 AND ((source_id=?3 AND target_id=?4) OR (source_id=?4 AND target_id=?3))", -1, &edge, nil) != sql.OK do return "prepare asset membership"
				defer sql.finalize(edge)
				if sql.bind_bytes(edge, 1, transmute([]byte)workspace) != sql.OK || sql.bind_id(edge, 2, u64(9 + slice * 4 + i)) != sql.OK || sql.bind_id(edge, 3, u64(i + 3)) != sql.OK || sql.bind_id(edge, 4, u64(slice + 1)) != sql.OK do return "bind asset membership"
				if sql.step(edge) != sql.ROW || sql.column_int64(edge, 0) != i64(m.asset_edges[slice][i]) do return "canonical asset membership differs"
				if !m.asset_edges[slice][i] || !asset.exists do continue
				#partial switch asset_types[i] {
				case .Note:
					asset_counts[0] += 1
					if asset.project != 0 do projects[asset.project] += 1
				case .File:
					asset_counts[1] += 1
				case .Ticket:
					asset_counts[2] += 1
				}
				if asset.moved > moved do moved = asset.moved
			}
			s: ^sql.Statement
			if sql.prepare_v2(store.db, "SELECT backlog,todo,in_progress,done,blocked,work,oldest,last_moved,notes,files,tickets FROM slice_summaries WHERE workspace=?1 AND slice_id=?2", -1, &s, nil) != sql.OK do return "prepare summary"
			defer sql.finalize(s)
			if sql.bind_bytes(s, 1, transmute([]byte)workspace) != sql.OK || sql.bind_id(s, 2, u64(slice + 1)) != sql.OK do return "bind summary"
			rc := sql.step(s)
			if !live {if rc != sql.DONE do return "deleted slice summary survived"} else {
				if rc != sql.ROW do return "missing summary"
				for expected, col in ([11]i64{counts[0], counts[1], counts[2], counts[3], blocked, work, oldest, moved, asset_counts[0], asset_counts[1], asset_counts[2]}) {
					if sql.column_int64(s, i32(col)) != expected do return "slice fold differs from model"
				}
			}
			order: ^sql.Statement
			if sql.prepare_v2(store.db, "SELECT m.sort_at,a.created_at FROM slice_metadata m JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id WHERE m.workspace=?1 AND m.asset_id=?2", -1, &order, nil) != sql.OK do return "prepare slice order"
			defer sql.finalize(order)
			if sql.bind_bytes(order, 1, transmute([]byte)workspace) != sql.OK || sql.bind_id(order, 2, u64(slice + 1)) != sql.OK do return "bind slice order"
			order_rc := sql.step(order)
			if live {
				expected_order := moved > m.slice_created[slice] ? moved : m.slice_created[slice]
				if order_rc != sql.ROW || sql.column_int64(order, 0) != expected_order || sql.column_int64(order, 1) != m.slice_created[slice] do return "slice order differs"
			} else if order_rc != sql.DONE do return "deleted slice metadata survived"
			p: ^sql.Statement
			if sql.prepare_v2(store.db, "SELECT project,refs FROM slice_projects WHERE workspace=?1 AND slice_id=?2", -1, &p, nil) != sql.OK do return "prepare project"
			defer sql.finalize(p)
			if sql.bind_bytes(p, 1, transmute([]byte)workspace) != sql.OK || sql.bind_id(p, 2, u64(slice + 1)) != sql.OK do return "bind project"
			seen: [3]bool
			for {
				project_rc := sql.step(p)
				if project_rc == sql.DONE do break
				if project_rc != sql.ROW do return "read project"
				name := string(sql.column_bytes_view(p, 0))
				index := -1
				for candidate in 1 ..< 3 {if name == project_names[candidate] do index = candidate}
				if !live || index < 0 do return "unexpected project row"
				if seen[index] || projects[index] <= 0 || sql.column_int64(p, 1) != projects[index] do return "project refs differ"
				seen[index] = true
			}
			for project in 1 ..< 3 {
				if seen[project] != (live && projects[project] > 0) do return "missing project row"
			}
		}
		for total, status in totals {
			s: ^sql.Statement
			if sql.prepare_v2(store.db, "SELECT coalesce(sum(total),0),coalesce(sum(covered),0) FROM workspace_task_counts WHERE workspace=?1 AND status=?2", -1, &s, nil) != sql.OK do return "prepare coverage"
			defer sql.finalize(s)
			if sql.bind_bytes(s, 1, transmute([]byte)workspace) != sql.OK || sql.bind_int64(s, 2, i64(status)) != sql.OK do return "bind coverage"
			if sql.step(s) != sql.ROW || sql.column_int64(s, 0) != total || sql.column_int64(s, 1) != covered[status] do return "workspace coverage differs"
		}
	}
	pending: ^sql.Statement
	if sql.prepare_v2(store.db, "SELECT count(*) FROM slice_pending", -1, &pending, nil) != sql.OK do return "prepare pending"
	defer sql.finalize(pending)
	if sql.step(pending) != sql.ROW || sql.column_int64(pending, 0) != 0 do return "pending contributions survived transaction"
	return ""
}

prop_sqlite_histories_match_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	dir, err := os.make_directory_temp("", "nrc-hegel-sqlite-*", context.allocator)
	if err != nil do return hgl.interesting("temporary directory")
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if rc != sql.OK do return hgl.interesting("open model database")
	defer db.close(&store)
	model: [2]SQLite_Model_Workspace
	// Dense initial membership makes overlapping coverage and extrema removal
	// observable even when generation chooses few edge additions.
	if db.begin(&store) != sql.OK do return hgl.interesting("begin fixture")
	for w in 0 ..< 2 {
		for slice in 0 ..< 2 {
			if !sqlite_model_action(&store, &model, {4, i64(w), 0, i64(slice), 0, i64(slice * 3), 0, 0}) do return hgl.interesting("seed slice")
			for task in 0 ..< 4 {
				if !sqlite_model_action(&store, &model, {3, i64(w), i64(task), i64(slice), 0, 0, 0, 0}) do return hgl.interesting("seed membership")
				if !sqlite_model_action(&store, &model, {8, i64(w), i64(task), i64(slice), 0, 0, 0, 0}) do return hgl.interesting("seed asset membership")
			}
		}
		for task in 0 ..< 4 {
			if !sqlite_model_action(&store, &model, {0, i64(w), i64(task), 0, i64(task), i64(task), i64(3 - task), i64(task % 3)}) do return hgl.interesting("seed task")
			if !sqlite_model_action(&store, &model, {6, i64(w), i64(task), 0, 0, 0, i64(task), 1}) do return hgl.interesting("seed asset")
		}
	}
	if db.commit(&store) != sql.OK do return hgl.interesting("commit fixture")
	if diagnostic := sqlite_model_check(&store, model); diagnostic != "" do return hgl.interesting(diagnostic)
	for round in 0 ..< 16 {
		mode, mode_err := hgl.draw_i64(tc, 0, 3)
		if mode_err == .Stop_Test do return hgl.abort()
		if mode_err != nil do return hgl.interesting("draw transaction mode")
		if round < 4 do mode = i64(round) // Every history exercises all boundaries.
		before := model
		if db.begin(&store) != sql.OK do return hgl.interesting("begin history")
		for operation in 0 ..< 3 {
			values: [8]i64
			for bound, field in ([8]i64{8, 1, 3, 1, 4, 3, 3, 5}) {
				value, draw_err := hgl.draw_i64(tc, 0, bound)
				if draw_err == .Stop_Test do return hgl.abort()
				if draw_err != nil do return hgl.interesting("draw operation")
				values[field] = value
			}
			saved := model
			if mode == 1 && operation == 1 && sql.exec(store.db, "SAVEPOINT model_patch", nil, nil, nil) != sql.OK do return hgl.interesting("savepoint")
			if !sqlite_model_action(&store, &model, values) do return hgl.interesting("apply generated operation")
			if mode == 1 && operation == 1 {
				if sql.exec(store.db, "ROLLBACK TO model_patch; RELEASE model_patch", nil, nil, nil) != sql.OK do return hgl.interesting("rollback savepoint")
				model = saved
			}
		}
		if mode == 0 {
			if db.rollback(&store) != sql.OK do return hgl.interesting("rollback transaction")
			model = before
		} else if db.commit(&store) != sql.OK do return hgl.interesting("commit history")
		if mode == 3 {
			if db.close(&store) != sql.OK do return hgl.interesting("close history")
			store, rc = db.open(path)
			if rc != sql.OK do return hgl.interesting("reopen history")
		}
		if diagnostic := sqlite_model_check(&store, model); diagnostic != "" do return hgl.interesting(diagnostic)
	}
	return hgl.valid()
}

@(test)
test_hegel_sqlite_histories_match_model :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_sqlite_histories_match_model, nil, {test_cases = 40})
	testing.expectf(t, err == nil && result.passed, "SQLite model histories: %v", err)
}

@(test)
test_sqlite_model_mixed_member_lifecycle :: proc(t: ^testing.T) {
	// The model bypasses command validation, so pin the fixture contract here.
	// Extra project fields are valid but must not contribute Slice projects.
	for preview in SQLITE_MODEL_TICKET_PREVIEWS {
		if !testing.expect(t, validate_ticket_asset(.Ticket, .None, 0, .Plain, 0, transmute([]byte)preview, nil)) do return
	}
	for preview in SQLITE_MODEL_PREVIEWS {
		testing.expect(t, !validate_ticket_asset(.Ticket, .None, 0, .Plain, 0, transmute([]byte)preview, nil))
	}
	dir, err := os.make_directory_temp("", "nrc-model-mixed-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	model: [2]SQLite_Model_Workspace
	testing.expect_value(t, db.begin(&store), sql.OK)
	for slice in 0 ..< 2 {
		testing.expect(t, sqlite_model_action(&store, &model, {4, 0, 0, i64(slice), 0, 0, 0, 0}))
		for member in 0 ..< 4 {
			testing.expect(t, sqlite_model_action(&store, &model, {8, 0, i64(member), i64(slice), 0, 0, 0, 0}))
		}
		testing.expect(t, sqlite_model_action(&store, &model, {3, 0, 2, i64(slice), 0, 0, 0, 0}))
	}
	// Task 3 and Note 3 are distinct; two Notes share P with that task.
	testing.expect(t, sqlite_model_action(&store, &model, {0, 0, 2, 0, 1, 2, 3, 1}))
	for member in 0 ..< 4 {
		testing.expect(t, sqlite_model_action(&store, &model, {6, 0, i64(member), 0, 0, 0, i64(member), 1}))
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect_value(t, sqlite_model_check(&store, model), "")
	// Reject wrong category counters even when their total is unchanged, and
	// reject counting File/Ticket previews as project contributions.
	for query in ([3]cstring{"UPDATE slice_summaries SET notes=1,files=2", "UPDATE slice_summaries SET files=2,tickets=0", "UPDATE slice_projects SET refs=5"}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sql.exec(store.db, query, nil, nil, nil), sql.OK)
		testing.expect(t, sqlite_model_check(&store, model) != "")
		testing.expect_value(t, db.rollback(&store), sql.OK)
	}
	// Project P retains other references; then remove movement winners,
	// resurrect dangling members and exercise both membership directions.
	for action in ([?][8]i64{{6, 0, 0, 0, 0, 0, 2, 2}, {7, 0, 1, 0, 0, 0, 0, 0}, {7, 0, 3, 0, 0, 0, 0, 0}, {7, 0, 2, 0, 0, 0, 0, 0}, {6, 0, 1, 0, 0, 0, 3, 2}, {6, 0, 2, 0, 0, 0, 2, 0}, {6, 0, 3, 0, 0, 0, 0, 2}, {8, 0, 0, 0, 0, 0, 0, 0}, {8, 0, 1, 1, 0, 0, 0, 0}, {4, 0, 0, 0, 0, 0, 0, 0}, {4, 0, 0, 0, 0, 0, 0, 0}}) {
		before := model
		for rollback in ([2]bool{true, false}) {
			testing.expect_value(t, db.begin(&store), sql.OK)
			testing.expect(t, sqlite_model_action(&store, &model, action))
			if rollback {
				testing.expect_value(t, db.rollback(&store), sql.OK)
				model = before
			} else {
				testing.expect_value(t, db.commit(&store), sql.OK)
				testing.expect_value(t, db.close(&store), sql.OK)
				store, rc = db.open(path)
				if !testing.expect_value(t, rc, sql.OK) do return
			}
			testing.expect_value(t, sqlite_model_check(&store, model), "")
		}
	}
}

@(test)
test_sqlite_model_rejects_project_and_order_corruption :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-model-controls-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	model: [2]SQLite_Model_Workspace
	key := pr.Asset {
		asset_id = 1,
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect(t, sqlite_model_action(&store, &model, {4, 0, 0, 0, 0, 3, 0, 0}))
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect_value(t, sqlite_model_check(&store, model), "")
	// An absent project must not be represented by a zero-ref, empty or
	// unknown project row: the public project filter tests row existence.
	for project in ([3]string{"P", "", "unknown"}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_projection_write(&store, "INSERT INTO slice_projects VALUES(?1,?2,?3,0)", "model-a", &key, {project}), sql.OK)
		testing.expect(t, sqlite_model_check(&store, model) != "")
		testing.expect_value(t, db.rollback(&store), sql.OK)
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect(t, sqlite_model_action(&store, &model, {0, 0, 0, 0, 1, 2, 3, 1}))
	testing.expect(t, sqlite_model_action(&store, &model, {3, 0, 0, 0, 0, 0, 0, 0}))
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect_value(t, sqlite_model_check(&store, model), "")
	for query in ([3]cstring{"DELETE FROM slice_projects WHERE workspace=?1 AND slice_id=?2", "UPDATE slice_projects SET refs=0 WHERE workspace=?1 AND slice_id=?2", "UPDATE slice_metadata SET sort_at=19 WHERE workspace=?1 AND asset_id=?2"}) {
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_projection_write(&store, query, "model-a", &key, nil), sql.OK)
		testing.expect(t, sqlite_model_check(&store, model) != "")
		testing.expect_value(t, db.rollback(&store), sql.OK)
	}
	// Editing the live Slice moves its own timestamp below its member's;
	// the order key must follow the member rather than the Slice now.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect(t, sqlite_model_action(&store, &model, {5, 0, 0, 0, 0, 1, 0, 0}))
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect_value(t, sqlite_model_check(&store, model), "")
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sqlite_projection_write(&store, "UPDATE slice_metadata SET sort_at=5 WHERE workspace=?1 AND asset_id=?2", "model-a", &key, nil),
		sql.OK,
	)
	testing.expect(t, sqlite_model_check(&store, model) != "")
	testing.expect_value(t, db.rollback(&store), sql.OK)
}
