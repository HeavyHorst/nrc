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

// All ten v1 patch fields must be deliberately specified here. A new protocol
// field fails compilation until its mandatory cases and model are added.
#assert(pr.TRANSACTION_TASK_PATCH_ALL == (1 << 10) - 1)

sqlite_command_task_fields_equal :: proc(a, b: pr.Task) -> bool {
	return(
		a.id == b.id &&
		a.status == b.status &&
		a.priority == b.priority &&
		a.color == b.color &&
		a.due_at == b.due_at &&
		a.blocked_by == b.blocked_by &&
		a.created_at == b.created_at &&
		a.updated_at == b.updated_at &&
		a.completed_at == b.completed_at &&
		string(a.completed_by) == string(b.completed_by) &&
		string(a.title) == string(b.title) &&
		string(a.description) == string(b.description) &&
		string(a.assignee) == string(b.assignee) &&
		string(a.external_ref) == string(b.external_ref) &&
		string(a.project) == string(b.project) \
	)
}

prop_sqlite_command_fields :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	dir, err := os.make_directory_temp("", "nrc-command-fields-*", context.allocator)
	if err != nil do return hgl.interesting("temporary directory")
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if rc != sql.OK do return hgl.interesting("open fields database")
	defer db.close(&store)
	rotation, draw_err := hgl.draw_i64(tc, 0, 9)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw rotation")
	buffer: [8192]byte
	create := pr.TransactionTaskCreate {
		title      = transmute([]byte)string("seed"),
		blocked_by = {.Existing, .Task, 0},
	}
	n := pr.serializeTransactionTaskCreate(create, buffer[:])
	if n <= 0 do return hgl.interesting("serialize field fixture")
	if why := sqlite_command_model_apply(&store, "fields", 100, {{.TaskCreate, buffer[:n]}, {.TaskCreate, buffer[:n]}, {.TaskCreate, buffer[:n]}}, {1, 2, 3}); why != "" do return hgl.interesting(why)
	m := pr.Task {
		id         = 2,
		title      = create.title,
		created_at = 100,
		updated_at = 100,
	}
	// Distinct max-length values remain owned by this case for the whole history.
	text: [5][pr.MAX_TASK_DESCRIPTION_LENGTH + 1]byte
	for &value, i in text {for &b in value {b = byte('a' + i)}}
	limits := [10]int {
		pr.MAX_TASK_TITLE_LENGTH,
		pr.MAX_TASK_DESCRIPTION_LENGTH,
		0,
		0,
		0,
		0,
		0,
		pr.MAX_ASSIGNEE_LENGTH,
		pr.MAX_EXTERNAL_REF_LENGTH,
		pr.MAX_PROJECT_LENGTH,
	}
	text_slot := [10]int{0, 1, 0, 0, 0, 0, 0, 2, 3, 4}
	coverage: [10]u8
	status_count :: int(max(pr.TaskStatus)) + 1
	color_count :: int(max(pr.TaskColor)) + 1
	status_coverage: [status_count]bool
	color_coverage: [color_count]bool
	for step in 0 ..< 64 + status_count + color_count {
		field, mode := (step + int(rotation)) % 10, step / 10
		stale := false
		enum_value := -1
		if step >= 40 && step < 40 + status_count + color_count {
			field = step < 40 + status_count ? 2 : 4
			enum_value = step - 40 - (field == 2 ? 0 : status_count)
			mode = 0
		} else if step >= 40 {
			f, e := hgl.draw_i64(tc, 0, 9); if e == .Stop_Test do return hgl.abort(); if e != nil do return hgl.interesting("draw field")
			v, ve := hgl.draw_i64(tc, 0, 3); if ve == .Stop_Test do return hgl.abort(); if ve != nil do return hgl.interesting("draw value")
			field, mode = int(f), int(v)
			stale = step % 5 == 0
		}
		p := pr.TransactionTaskPatch {
			task          = {.Existing, .Task, 2},
			present       = u16(1 << uint(field)),
			if_updated_at = m.updated_at + (stale ? 1 : 0),
		}
		next := m
		accepted := !stale
		value: []byte
		if limits[field] > 0 {
			switch mode {
			case 0:
				value = text[text_slot[field]][:limits[field]]
			case 1:
				value = transmute([]byte)string("changed")
			case 2:
				value = nil
			case 3:
				value = text[text_slot[field]][:limits[field] + 1]; accepted = false
			}
		}
		switch field {
		case 0:
			p.title = value; next.title = value; if len(value) == 0 do accepted = false
		case 1:
			p.description = value; next.description = value
		case 2:
			values := [4]pr.TaskStatus{.Note, .Done, .Backlog, pr.TaskStatus(255)}
			p.status = values[mode]; next.status = p.status; if mode == 3 do accepted = false
		case 3:
			values := [4]u8{254, 1, 0, 255}; p.priority = values[mode]; next.priority = p.priority
		case 4:
			values := [4]pr.TaskColor{.Gold, .Red, .None, pr.TaskColor(255)}
			p.color = values[mode]; next.color = p.color; if mode == 3 do accepted = false
		case 5:
			values := [4]i64{max(i64), 123, 0, min(i64)}; p.due_at = values[mode]; next.due_at = p.due_at
		case 6:
			values := [4]u64{1, 3, 0, 9999}; p.blocked_by = {.Existing, .Task, values[mode]}; next.blocked_by = values[mode]; if mode == 3 do accepted = false
		case 7:
			p.assignee = value; next.assignee = value
		case 8:
			p.external_ref = value; next.external_ref = value
		case 9:
			p.project = value; next.project = value
		}
		if enum_value >= 0 {
			if field == 2 {p.status = pr.TaskStatus(enum_value); next.status = p.status} else {p.color = pr.TaskColor(enum_value); next.color = p.color}
		}
		n = pr.serializeTransactionTaskPatch(p, buffer[:])
		if limits[field] > 0 && mode == 3 {
			// The SDK serializer correctly refuses this boundary. Send the actual
			// malformed wire body as well, to exercise the command's rejection.
			if n != -1 do return hgl.interesting("serializer accepted oversized field")
			valid := p; valid.title = nil; valid.description = nil; valid.assignee = nil; valid.external_ref = nil; valid.project = nil
			n = pr.serializeTransactionTaskPatch(valid, buffer[:])
			if n != 32 do return hgl.interesting("invalid oversized fixture header")
			endian.put_u16(buffer[30:], .Big, u16(len(value))); copy(buffer[32:], value); n = 32 + len(value)
		}
		if n <= 0 do return hgl.interesting("serialize patch")
		at := m.updated_at - 3
		if step % 2 != 0 do at = m.updated_at + 7
		ids := [1]u64{2}
		if why := sqlite_command_model_apply(&store, "fields", at, {{.TaskPatch, buffer[:n]}}, ids[:accepted ? 1 : 0], accepted ? max(u16) : 0); why != "" do return hgl.interesting(why)
		if accepted {
			next.updated_at = m.updated_at + (step % 2 == 0 ? 1 : 7)
			if next.status == .Done && m.status != .Done {next.completed_at = next.updated_at; next.completed_by = transmute([]byte)string("alice")}
			if next.status != .Done && m.status == .Done {next.completed_at = 0; next.completed_by = nil}
			m = next
		}
		if step % 7 == 0 {
			if db.close(&store) != sql.OK do return hgl.interesting("close fields")
			store, rc = db.open(path); if rc != sql.OK do return hgl.interesting("reopen fields")
		}
		actual, found, code := db.get_task(&store, "fields", 0, 2)
		equal := code == sql.OK && found && sqlite_command_task_fields_equal(actual, m)
		db.destroy_task(&actual)
		if !equal do return hgl.interesting("patch changed selected or omitted fields")
		if step < 40 do coverage[field] |= u8(1 << uint(mode))
		if enum_value >= 0 {
			if field == 2 do status_coverage[enum_value] = true
			else do color_coverage[enum_value] = true
		}
	}
	for covered in coverage {if covered != 15 do return hgl.interesting("missing mandatory TaskPatch field case")}
	for covered in status_coverage {if !covered do return hgl.interesting("missing mandatory task status")}
	for covered in color_coverage {if !covered do return hgl.interesting("missing mandatory task color")}
	return hgl.valid()
}

@(test)
test_hegel_sqlite_command_fields :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_sqlite_command_fields, nil, {test_cases = 40})
	testing.expectf(t, err == nil && result.passed, "Task command field coverage: %v", err)
}
