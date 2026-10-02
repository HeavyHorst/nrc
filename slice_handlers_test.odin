package main

import "core:encoding/endian"
import "core:testing"

import pr "protocol"

slice_test_bytes :: proc(value: string) -> []byte {return transmute([]byte)value}

slice_test_state :: proc(conv: ^Conversation_State) {
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	conv.edges = make(map[pr.EdgeID]^pr.Edge)
	conv.edges_by_entity = make(map[Edge_Entity_Key][dynamic]pr.EdgeID)
	init_task_index(conv)
	init_note_index(conv)
}

slice_test_destroy :: proc(conv: ^Conversation_State) {
	destroy_task_index(conv)
	destroy_note_index(conv)
	for _, edge in conv.edges do free(edge)
	for _, edge_ids in conv.edges_by_entity do delete(edge_ids)
	delete(conv.edges_by_entity)
	delete(conv.edges)
	delete(conv.tasks)
	delete(conv.assets)
}

slice_test_add_task :: proc(conv: ^Conversation_State, task: ^pr.Task) {
	conv.tasks[task.id] = task
	index_task(conv, task)
}

// slice_test_add_asset registers an asset and returns it, so a test can link
// notes and files the way a client does.
slice_test_add_asset :: proc(conv: ^Conversation_State, asset: ^pr.Asset) {
	conv.assets[asset.asset_id] = asset
}

// slice_test_member_of links a member to a slice with one MemberOf edge and
// indexes it for both endpoints, which is what the create-edge handler does.
slice_test_member_of :: proc(
	conv: ^Conversation_State,
	member_type: pr.TargetType,
	member_id: u64,
	slice_id: pr.AssetID,
	relation := pr.RelationType.MemberOf,
) {
	edge := new(pr.Edge)
	edge.edge_id = pr.EdgeID(len(conv.edges) + 1)
	edge.source_type = member_type
	edge.source_id = member_id
	edge.target_type = .Asset
	edge.target_id = u64(slice_id)
	edge.relation = relation
	conv.edges[edge.edge_id] = edge
	add_edge_to_adjacency(conv, edge.source_type, edge.source_id, edge.edge_id)
	add_edge_to_adjacency(conv, edge.target_type, edge.target_id, edge.edge_id)
}

// slice_test_slice_asset registers a slice record. The preview is spelled out at
// each call site so a test shows exactly what it stores. The record's own creation
// time is the floor of the register's order, so a test that cares about the order
// sets it; every other test leaves it at zero.
slice_test_slice_asset :: proc(id: pr.AssetID, preview: string, created_at: i64 = 0) -> pr.Asset {
	return pr.Asset{asset_type = .Slice, asset_id = id, created_at = created_at, updated_at = 4000, preview = slice_test_bytes(preview)}
}

// slice_test_query is the register's default request: every open slice, the
// workspace counters folded, and a page bound the whole fixture fits in. A test
// that exercises a filter or a later page builds its own query.
slice_test_query :: proc(include_closed := false) -> Slice_Query {
	return {include_closed = include_closed, limit = pr.MAX_TASK_SLICE_COUNT, with_work_counters = true}
}

slice_test_slice_by_name :: proc(slices: []pr.TaskSlice, name: string) -> (pr.TaskSlice, bool) {
	for entry in slices do if string(entry.name) == name do return entry, true
	return {}, false
}

// A membership edge is read as an unordered pair: the member is whichever endpoint
// is not the slice. The slice itself is never a member, even if a self-edge were
// ever replayed from a record this server did not write.
@(test)
test_slice_member_endpoint_reads_either_direction :: proc(t: ^testing.T) {
	slice_id := pr.AssetID(11)

	member_first := pr.Edge {
		edge_id     = 1,
		source_type = .Task,
		source_id   = 13,
		target_type = .Asset,
		target_id   = u64(slice_id),
		relation    = .MemberOf,
	}
	member_type, member_id, found := slice_member_endpoint(&member_first, slice_id)
	testing.expect(t, found && member_type == .Task && member_id == 13, "a member -> slice edge names the member")

	slice_first := pr.Edge {
		edge_id     = 2,
		source_type = .Asset,
		source_id   = u64(slice_id),
		target_type = .Asset,
		target_id   = 12,
		relation    = .MemberOf,
	}
	member_type, member_id, found = slice_member_endpoint(&slice_first, slice_id)
	testing.expect(t, found && member_type == .Asset && member_id == 12, "a slice -> member edge names the member")

	self_edge := pr.Edge {
		edge_id     = 3,
		source_type = .Asset,
		source_id   = u64(slice_id),
		target_type = .Asset,
		target_id   = u64(slice_id),
		relation    = .MemberOf,
	}
	_, _, found = slice_member_endpoint(&self_edge, slice_id)
	testing.expect(t, !found, "a slice is not its own member")

	unrelated := pr.Edge {
		edge_id     = 4,
		source_type = .Task,
		source_id   = 1,
		target_type = .Task,
		target_id   = 2,
		relation    = .MemberOf,
	}
	_, _, found = slice_member_endpoint(&unrelated, slice_id)
	testing.expect(t, !found, "an edge that does not touch the slice is not a membership")
}

@(test)
test_task_slice_counts_its_members_from_member_of_edges :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	slice_asset := slice_test_slice_asset(77, `{"version":1,"name":"Shard hardening","owner":"rene","outcome":"Ship it.","closed":false}`)
	slice_test_add_asset(&conv, &slice_asset)

	tasks := [5]pr.Task {
		{id = 1, status = .Backlog, created_at = 100, updated_at = 500},
		{id = 2, status = .Todo, created_at = 200, updated_at = 900, blocked_by = 4},
		{id = 3, status = .Done, created_at = 50, updated_at = 300},
		{id = 4, status = .InProgress, created_at = 400, updated_at = 700},
		// A task retired into a note is not work, even when it is linked.
		{id = 5, status = .Note, created_at = 20, updated_at = 950},
	}
	for i in 0 ..< len(tasks) {
		slice_test_add_task(&conv, &tasks[i])
		slice_test_member_of(&conv, .Task, u64(tasks[i].id), 77)
	}

	notes := [2]pr.Asset{{asset_type = .Note, asset_id = 11, updated_at = 4100}, {asset_type = .Note, asset_id = 12, updated_at = 4200}}
	files := [1]pr.Asset{{asset_type = .File, asset_id = 21, updated_at = 4300}}
	// A reminder that ends up linked is not a member of a work stream.
	reminders := [1]pr.Asset{{asset_type = .Reminder, asset_id = 31, updated_at = 4400}}
	for i in 0 ..< len(notes) {
		slice_test_add_asset(&conv, &notes[i])
		slice_test_member_of(&conv, .Asset, u64(notes[i].asset_id), 77)
	}
	for i in 0 ..< len(files) {
		slice_test_add_asset(&conv, &files[i])
		slice_test_member_of(&conv, .Asset, u64(files[i].asset_id), 77)
	}
	for i in 0 ..< len(reminders) {
		slice_test_add_asset(&conv, &reminders[i])
		slice_test_member_of(&conv, .Asset, u64(reminders[i].asset_id), 77)
	}

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)
	page := collect_task_slices(&conv, slice_test_query(), &slices, &assigned, context.temp_allocator)

	testing.expect_value(t, page.total_count, 1)
	testing.expect(t, !page.has_more, "one slice fits one response")

	entry, ok := slice_test_slice_by_name(slices[:], "Shard hardening")
	testing.expect(t, ok, "the slice asset is the slice")
	testing.expect_value(t, entry.slice_id, pr.AssetID(77))
	testing.expect_value(t, string(entry.owner), "rene")
	testing.expect(t, !slice_has_flag(entry, pr.TaskSliceFlag_CLOSED), "an open slice is not closed")
	testing.expect_value(t, entry.backlog, u16(1))
	testing.expect_value(t, entry.todo, u16(1))
	testing.expect_value(t, entry.in_progress, u16(1))
	testing.expect_value(t, entry.done, u16(1))
	testing.expect_value(t, entry.blocked, u16(1))
	testing.expect_value(t, entry.notes, u16(2))
	testing.expect_value(t, entry.files, u16(1))
	testing.expect_value(t, pr.task_slice_open_count(entry), u16(3))
	// The linked reminder is not a member, so it does not widen the count.
	testing.expect_value(t, pr.task_slice_member_count(entry), 7)
	// Done members do not hold the oldest-active age back.
	testing.expect_value(t, entry.oldest_active_at, i64(100))
	// Movement is the newest member change, notes and files included.
	testing.expect_value(t, entry.last_moved_at, i64(4300))

	// Only the four work tasks have a home; the retired one does not.
	testing.expect_value(t, len(assigned), 4)
	testing.expect(t, pr.TaskID(5) not_in assigned, "a task retired into a note is not assigned work")
}

@(test)
test_task_slice_without_members_is_still_a_slice :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	// A slice is what a human created, not what its members imply: an empty
	// slice is a slice, and it reports no movement because nothing moved.
	slice_asset := slice_test_slice_asset(78, `{"version":1,"name":"Customer records","owner":"anke","closed":false}`)
	slice_test_add_asset(&conv, &slice_asset)

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)
	page := collect_task_slices(&conv, slice_test_query(), &slices, &assigned, context.temp_allocator)

	testing.expect_value(t, page.total_count, 1)
	entry, ok := slice_test_slice_by_name(slices[:], "Customer records")
	testing.expect(t, ok, "an empty slice is still a slice")
	testing.expect_value(t, pr.task_slice_member_count(entry), 0)
	testing.expect_value(t, entry.oldest_active_at, i64(0))
	testing.expect_value(t, entry.last_moved_at, i64(0))
	testing.expect_value(t, len(assigned), 0)
}

@(test)
test_task_slice_closed_is_excluded_unless_requested :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	open_asset := slice_test_slice_asset(77, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`)
	closed_asset := slice_test_slice_asset(78, `{"version":1,"name":"Beta","owner":"marco","closed":true,"closed_at":9000,"closed_by":"marco"}`)
	slice_test_add_asset(&conv, &open_asset)
	slice_test_add_asset(&conv, &closed_asset)

	task := pr.Task {
		id         = 1,
		status     = .Todo,
		created_at = 100,
		updated_at = 200,
	}
	slice_test_add_task(&conv, &task)
	// Closing a slice does not unassign its tasks.
	slice_test_member_of(&conv, .Task, 1, 78)

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)
	page := collect_task_slices(&conv, slice_test_query(), &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, page.total_count, 1)
	_, open_ok := slice_test_slice_by_name(slices[:], "Alpha")
	testing.expect(t, open_ok, "the open slice is listed")
	testing.expect_value(t, len(assigned), 1)

	with_closed := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(with_closed)
	closed_page := collect_task_slices(&conv, slice_test_query(true), &with_closed, &assigned, context.temp_allocator)
	testing.expect_value(t, closed_page.total_count, 2)

	beta, beta_ok := slice_test_slice_by_name(with_closed[:], "Beta")
	testing.expect(t, beta_ok, "include_closed should surface closed slices")
	testing.expect(t, slice_has_flag(beta, pr.TaskSliceFlag_CLOSED), "Beta is closed")
	testing.expect_value(t, string(beta.owner), "marco")
	testing.expect_value(t, beta.todo, u16(1))
}

@(test)
test_task_slice_counts_only_membership_relations :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	alpha := slice_test_slice_asset(77, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`)
	beta := slice_test_slice_asset(78, `{"version":1,"name":"Beta","owner":"rene","closed":false}`)
	slice_test_add_asset(&conv, &alpha)
	slice_test_add_asset(&conv, &beta)

	task := pr.Task {
		id         = 1,
		status     = .Todo,
		created_at = 100,
		updated_at = 200,
	}
	slice_test_add_task(&conv, &task)
	// A reference to a slice is not a membership, and an edge between two
	// slices is not a member of either one.
	slice_test_member_of(&conv, .Task, 1, 77, pr.RelationType.References)
	slice_test_member_of(&conv, .Asset, 78, 77, pr.RelationType.MemberOf)

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)
	page := collect_task_slices(&conv, slice_test_query(), &slices, &assigned, context.temp_allocator)

	testing.expect_value(t, page.total_count, 2)
	testing.expect_value(t, len(assigned), 0)
	entry, ok := slice_test_slice_by_name(slices[:], "Alpha")
	testing.expect(t, ok, "Alpha is listed")
	testing.expect_value(t, pr.task_slice_member_count(entry), 0)
	beta_entry, beta_ok := slice_test_slice_by_name(slices[:], "Beta")
	testing.expect(t, beta_ok, "Beta is listed")
	testing.expect_value(t, pr.task_slice_member_count(beta_entry), 0)
}

@(test)
test_task_slice_invalid_preview_does_not_invent_identity :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	// Not JSON, JSON without a version, an empty name, and a version from the
	// future are all rejected: a corrupt record is not a slice.
	broken := [4]pr.Asset {
		{asset_type = .Slice, asset_id = 1, preview = slice_test_bytes("not json")},
		{asset_type = .Slice, asset_id = 2, preview = slice_test_bytes(`{"name":"Alpha"}`)},
		{asset_type = .Slice, asset_id = 3, preview = slice_test_bytes(`{"version":1,"name":""}`)},
		{asset_type = .Slice, asset_id = 4, preview = slice_test_bytes(`{"version":2,"name":"Alpha"}`)},
	}
	for i in 0 ..< len(broken) do slice_test_add_asset(&conv, &broken[i])

	good := slice_test_slice_asset(5, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`)
	slice_test_add_asset(&conv, &good)

	slices := make([dynamic]pr.TaskSlice, 0, 4)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 4)
	defer delete(assigned)
	page := collect_task_slices(&conv, slice_test_query(), &slices, &assigned, context.temp_allocator)

	testing.expect_value(t, page.total_count, 1)
	entry, ok := slice_test_slice_by_name(slices[:], "Alpha")
	testing.expect(t, ok, "the valid record is the slice")
	testing.expect_value(t, entry.slice_id, pr.AssetID(5))
}

@(test)
test_unassigned_task_count_reports_work_without_a_slice :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	slice_asset := slice_test_slice_asset(77, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`)
	slice_test_add_asset(&conv, &slice_asset)

	tasks := [4]pr.Task {
		{id = 1, status = .Todo, created_at = 100, updated_at = 200},
		{id = 2, status = .Done, created_at = 100, updated_at = 200},
		{id = 3, status = .Backlog, created_at = 100, updated_at = 200},
		// A retired task is not work, so it is neither assigned nor waiting.
		{id = 4, status = .Note, created_at = 100, updated_at = 200},
	}
	for i in 0 ..< len(tasks) do slice_test_add_task(&conv, &tasks[i])
	slice_test_member_of(&conv, .Task, 1, 77)

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)
	_ = collect_task_slices(&conv, slice_test_query(), &slices, &assigned, context.temp_allocator)

	testing.expect_value(t, len(assigned), 1)
	testing.expect_value(t, unassigned_task_count(&conv, &assigned), u32(2))
}

// The register's order is the one its rows can explain: the work stream moved most
// recently stands on top, a slice that carries no members yet falls back to the time
// it was created, closed slices sink below the active ones, and the slice ID breaks
// the remaining ties.
@(test)
test_task_slice_listing_is_ordered_by_movement :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	assets := [6]pr.Asset {
		slice_test_slice_asset(71, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`, created_at = 1000),
		slice_test_slice_asset(72, `{"version":1,"name":"Beta","owner":"rene","closed":false}`, created_at = 2000),
		slice_test_slice_asset(73, `{"version":1,"name":"Gamma","owner":"rene","closed":false}`, created_at = 8000),
		slice_test_slice_asset(74, `{"version":1,"name":"Delta","owner":"rene","closed":true}`, created_at = 500),
		slice_test_slice_asset(75, `{"version":1,"name":"Epsilon","owner":"rene","closed":false}`, created_at = 3000),
		slice_test_slice_asset(76, `{"version":1,"name":"Zeta","owner":"rene","closed":false}`, created_at = 3000),
	}
	for i in 0 ..< len(assets) do slice_test_add_asset(&conv, &assets[i])

	// Movement is a member's change, so the two slices with the newest members stand
	// above the empty ones, and the empty ones above the slice created first.
	tasks := [3]pr.Task {
		{id = 1, status = .Todo, created_at = 10, updated_at = 5000},
		{id = 2, status = .Todo, created_at = 10, updated_at = 9000},
		{id = 3, status = .Todo, created_at = 10, updated_at = 9500},
	}
	for i in 0 ..< len(tasks) do slice_test_add_task(&conv, &tasks[i])
	slice_test_member_of(&conv, .Task, 1, 71) // Alpha moved at 5000
	slice_test_member_of(&conv, .Task, 2, 72) // Beta moved at 9000
	slice_test_member_of(&conv, .Task, 3, 74) // Delta moved at 9500, but is closed

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)
	page := collect_task_slices(&conv, slice_test_query(true), &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, page.total_count, 6)

	expected := [6]string{"Beta", "Gamma", "Alpha", "Epsilon", "Zeta", "Delta"}
	for name, i in expected {
		testing.expect_value(t, string(slices[i].name), name)
	}

	// The active register drops the closed slice without disturbing the order.
	open := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(open)
	_ = collect_task_slices(&conv, slice_test_query(), &open, &assigned, context.temp_allocator)
	testing.expect_value(t, len(open), 5)
	testing.expect_value(t, string(open[4].name), "Zeta")
}

// A workspace may carry more slices than one response fits. The cap keeps the front
// of the order, so what arrives is the most recently created or moved work and not
// whichever slices the asset map handed out first.
@(test)
test_task_slice_listing_keeps_the_front_when_capped :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	count := pr.MAX_TASK_SLICE_COUNT + 1
	assets := make([]pr.Asset, count)
	defer delete(assets)
	for i in 0 ..< count {
		// One slice is created after every other one, so it is the only one with a
		// creation time to sort by.
		created_at: i64 = i == count - 1 ? 1 : 0
		assets[i] = slice_test_slice_asset(pr.AssetID(i + 1), `{"version":1,"name":"Filler","owner":"rene","closed":false}`, created_at = created_at)
		slice_test_add_asset(&conv, &assets[i])
	}

	slices := make([dynamic]pr.TaskSlice, 0, count)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)
	page := collect_task_slices(&conv, slice_test_query(), &slices, &assigned, context.temp_allocator)

	testing.expect_value(t, page.total_count, u32(count))
	testing.expect_value(t, len(slices), pr.MAX_TASK_SLICE_COUNT)
	testing.expect(t, page.has_more, "a listing that dropped a slice says so")
	testing.expect_value(t, slices[0].slice_id, pr.AssetID(count))
}

@(test)
test_slice_names_are_unique_and_records_must_carry_one :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	alpha := slice_test_slice_asset(77, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`)
	slice_test_add_asset(&conv, &alpha)

	testing.expect(t, slice_name_taken(&conv, "Alpha", 0), "an existing slice name is taken")
	testing.expect(t, !slice_name_taken(&conv, "Beta", 0), "an unused name is free")
	testing.expect(t, !slice_name_taken(&conv, "Alpha", 77), "the slice itself does not block its own name")

	// A write has to carry a usable record: the register skips one that does
	// not, so accepting it would create an asset nothing can address.
	_, ok := slice_preview_name(slice_test_bytes(`{"version":1,"name":"Beta"}`), context.temp_allocator)
	testing.expect(t, ok, "a well-formed record names its slice")
	broken_records := [4]string{`not json`, `{"name":"Beta"}`, `{"version":1,"name":""}`, `{"version":2,"name":"Beta"}`}
	for broken in broken_records {
		_, broken_ok := slice_preview_name(slice_test_bytes(broken), context.temp_allocator)
		testing.expect(t, !broken_ok, "a record without a usable name is refused")
	}
}

@(test)
test_task_slice_list_wire_roundtrip :: proc(t: ^testing.T) {
	msg := pr.TaskSliceList {
		conv_id              = 0,
		success              = true,
		has_more             = true,
		next_cursor_closed   = true,
		next_cursor_sort_at  = 1234,
		next_cursor_slice_id = 78,
		total_count          = 9,
		assigned_tasks       = 7,
		unassigned_tasks     = 11,
		slices               = []pr.TaskSlice {
			{
				name = slice_test_bytes("Alpha"),
				slice_id = 77,
				owner = slice_test_bytes("rene"),
				flags = pr.TaskSliceFlag_CLOSED,
				backlog = 1,
				todo = 2,
				in_progress = 3,
				done = 4,
				blocked = 5,
				notes = 6,
				files = 7,
				oldest_active_at = 111,
				last_moved_at = 222,
			},
			{name = slice_test_bytes("Beta"), slice_id = 78, todo = 1, last_moved_at = 333},
		},
		error                = slice_test_bytes(""),
		correlation_id       = 4242,
	}

	buf := make([]byte, pr.getSizeTaskSliceList(msg))
	defer delete(buf)
	written := pr.serializeTaskSliceList(msg, buf)
	testing.expect_value(t, written, len(buf))

	parsed, err := pr.parseTaskSliceList(buf, context.temp_allocator)
	testing.expect_value(t, err, pr.ProtocolParseError.None)
	testing.expect_value(t, parsed.conv_id, msg.conv_id)
	testing.expect(t, parsed.success, "success flag should survive the roundtrip")
	testing.expect(t, parsed.has_more, "has_more should survive the roundtrip")
	testing.expect(t, parsed.next_cursor_closed, "the cursor carries the closure of the slice it names")
	testing.expect_value(t, parsed.next_cursor_sort_at, i64(1234))
	testing.expect_value(t, parsed.next_cursor_slice_id, pr.AssetID(78))
	testing.expect_value(t, parsed.total_count, u32(9))
	testing.expect_value(t, parsed.assigned_tasks, u32(7))
	testing.expect_value(t, parsed.unassigned_tasks, u32(11))
	testing.expect_value(t, parsed.correlation_id, u32(4242))
	testing.expect_value(t, len(parsed.slices), 2)

	first := parsed.slices[0]
	testing.expect_value(t, string(first.name), "Alpha")
	testing.expect_value(t, first.slice_id, pr.AssetID(77))
	testing.expect_value(t, string(first.owner), "rene")
	testing.expect(t, slice_has_flag(first, pr.TaskSliceFlag_CLOSED), "closed flag survives")
	testing.expect_value(t, first.backlog, u16(1))
	testing.expect_value(t, first.todo, u16(2))
	testing.expect_value(t, first.in_progress, u16(3))
	testing.expect_value(t, first.done, u16(4))
	testing.expect_value(t, first.blocked, u16(5))
	testing.expect_value(t, first.notes, u16(6))
	testing.expect_value(t, first.files, u16(7))
	testing.expect_value(t, first.oldest_active_at, i64(111))
	testing.expect_value(t, first.last_moved_at, i64(222))
	testing.expect_value(t, pr.task_slice_open_count(first), u16(6))
	testing.expect_value(t, pr.task_slice_member_count(first), 23)

	second := parsed.slices[1]
	testing.expect_value(t, string(second.name), "Beta")
	testing.expect_value(t, second.slice_id, pr.AssetID(78))
	testing.expect(t, !slice_has_flag(second, pr.TaskSliceFlag_CLOSED), "an open slice carries no closed flag")

	// Trailing bytes are rejected rather than ignored.
	padded := make([]byte, len(buf) + 1)
	defer delete(padded)
	copy(padded, buf)
	_, padded_err := pr.parseTaskSliceList(padded, context.temp_allocator)
	testing.expect_value(t, padded_err, pr.ProtocolParseError.ContentLengthMismatch)
}

// The request body carries no opcode: conv_id, the two flags, the owner, the
// name, the page bound, the cursor and the correlation id.
@(test)
test_list_task_slices_request_parse :: proc(t: ^testing.T) {
	body := [22]byte{}
	endian.put_u64(body[:], .Big, 0)
	body[8] = 1 // include_closed
	body[9] = 0 // no owner filter
	endian.put_u16(body[10:], .Big, 0)
	body[12] = 0 // no name filter
	endian.put_u16(body[13:], .Big, 0)
	endian.put_u16(body[15:], .Big, 100)
	body[17] = 0 // first page
	endian.put_u32(body[18:], .Big, 7)

	req, err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, err, pr.ProtocolParseError.None)
	testing.expect(t, req.include_closed, "include_closed should parse")
	testing.expect(t, !req.has_owner, "an absent owner filter is no filter")
	testing.expect(t, !req.has_name, "an absent name filter is no filter")
	testing.expect_value(t, req.limit, u16(100))
	testing.expect(t, !req.has_cursor, "a first page carries no cursor")
	testing.expect_value(t, req.correlation_id, u32(7))

	// A flag outside its range, a page bound outside its range, a short body and
	// trailing bytes are all refused.
	body[8] = 2
	_, invalid_err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, invalid_err, pr.ProtocolParseError.InvalidValue)
	body[8] = 0

	endian.put_u16(body[15:], .Big, 0)
	_, zero_limit_err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, zero_limit_err, pr.ProtocolParseError.TooMany)
	endian.put_u16(body[15:], .Big, pr.MAX_TASK_SLICE_COUNT + 1)
	_, large_limit_err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, large_limit_err, pr.ProtocolParseError.TooMany)
	endian.put_u16(body[15:], .Big, 100)

	_, short_err := pr.parseListTaskSlicesRequest(body[:21])
	testing.expect_value(t, short_err, pr.ProtocolParseError.TooShort)

	long := [23]byte{}
	copy(long[:], body[:])
	_, long_err := pr.parseListTaskSlicesRequest(long[:])
	testing.expect_value(t, long_err, pr.ProtocolParseError.ContentLengthMismatch)
}

@(test)
test_list_task_slices_request_carries_filters_and_a_cursor :: proc(t: ^testing.T) {
	owner := "anke"
	name := "shard"
	body := make([]byte, 22 + len(owner) + len(name) + 17)
	defer delete(body)
	endian.put_u64(body[:], .Big, 0)
	body[8] = 0
	body[9] = 1
	endian.put_u16(body[10:], .Big, u16(len(owner)))
	copy(body[12:], slice_test_bytes(owner))
	offset := 12 + len(owner)
	body[offset] = 1
	offset += 1
	endian.put_u16(body[offset:], .Big, u16(len(name)))
	offset += 2
	copy(body[offset:], slice_test_bytes(name))
	offset += len(name)
	endian.put_u16(body[offset:], .Big, 50)
	offset += 2
	body[offset] = 1
	offset += 1
	body[offset] = 1 // the cursor names a closed slice
	offset += 1
	endian.put_i64(body[offset:], .Big, 9000)
	offset += 8
	endian.put_u64(body[offset:], .Big, 77)
	offset += 8
	endian.put_u32(body[offset:], .Big, 9)

	req, err := pr.parseListTaskSlicesRequest(body)
	testing.expect_value(t, err, pr.ProtocolParseError.None)
	testing.expect(t, req.has_owner && string(req.owner) == owner, "the owner filter parses")
	testing.expect(t, req.has_name && string(req.name) == name, "the name filter parses")
	testing.expect_value(t, req.limit, u16(50))
	testing.expect(t, req.has_cursor, "the cursor parses")
	testing.expect(t, req.cursor_closed, "the cursor carries the closure of the slice it names")
	testing.expect_value(t, req.cursor_sort_at, i64(9000))
	testing.expect_value(t, req.cursor_slice_id, pr.AssetID(77))
	testing.expect_value(t, req.correlation_id, u32(9))

	// A filter that is absent carries no name, and one that is present has to
	// name something.
	body[9] = 0
	_, owner_err := pr.parseListTaskSlicesRequest(body)
	testing.expect_value(t, owner_err, pr.ProtocolParseError.InvalidValue)
}

// A page follows the cursor the previous page ended on, and the cursor carries
// closure because closed slices sink below the active ones: a boundary that falls
// between the two sections still lands where the previous page stopped.
@(test)
test_task_slice_paging_follows_the_cursor :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	assets := [4]pr.Asset {
		slice_test_slice_asset(71, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`, created_at = 1000),
		slice_test_slice_asset(72, `{"version":1,"name":"Beta","owner":"rene","closed":false}`, created_at = 2000),
		slice_test_slice_asset(73, `{"version":1,"name":"Gamma","owner":"rene","closed":false}`, created_at = 8000),
		slice_test_slice_asset(74, `{"version":1,"name":"Delta","owner":"rene","closed":true}`, created_at = 500),
	}
	for i in 0 ..< len(assets) do slice_test_add_asset(&conv, &assets[i])

	tasks := [3]pr.Task {
		{id = 1, status = .Todo, created_at = 10, updated_at = 5000},
		{id = 2, status = .Todo, created_at = 10, updated_at = 9000},
		{id = 3, status = .Todo, created_at = 10, updated_at = 9500},
	}
	for i in 0 ..< len(tasks) do slice_test_add_task(&conv, &tasks[i])
	slice_test_member_of(&conv, .Task, 1, 71) // Alpha moved at 5000
	slice_test_member_of(&conv, .Task, 2, 72) // Beta moved at 9000
	slice_test_member_of(&conv, .Task, 3, 74) // Delta moved at 9500, but is closed

	// The whole listing in pages of two: Beta, Gamma, Alpha, Delta. The closed
	// slice carries the newest movement of all, so a cursor that forgot closure
	// would drop it.
	slices := make([dynamic]pr.TaskSlice, 0, 4)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 4)
	defer delete(assigned)
	names := make([dynamic]string, 0, 4)
	defer delete(names)

	query := Slice_Query {
		include_closed = true,
		limit          = 2,
	}
	cursor: Slice_Cursor
	for page_index in 0 ..< 2 {
		clear(&slices)
		query.has_cursor = page_index > 0
		query.cursor_closed = cursor.closed
		query.cursor_sort_at = cursor.sort_at
		query.cursor_slice_id = cursor.slice_id
		page := collect_task_slices(&conv, query, &slices, &assigned, context.temp_allocator)
		for entry in slices do append(&names, string(entry.name))
		testing.expect_value(t, page.total_count, u32(4))
		if page_index == 0 {
			testing.expect(t, page.has_more, "a page that left slices behind says so")
		} else {
			testing.expect(t, !page.has_more, "the last page ends the listing")
		}
		cursor = page.next_cursor
	}

	expected := [4]string{"Beta", "Gamma", "Alpha", "Delta"}
	testing.expect_value(t, len(names), len(expected))
	for name, i in expected do testing.expect_value(t, names[i], name)

	// A page that starts where the listing ends is empty, not a repeat.
	clear(&slices)
	query.cursor_closed = cursor.closed
	query.cursor_sort_at = cursor.sort_at
	query.cursor_slice_id = cursor.slice_id
	empty := collect_task_slices(&conv, query, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, len(slices), 0)
	testing.expect(t, !empty.has_more, "an exhausted listing has no next page")
}

// The register's filters are the server's: the owner is one exact name, and the
// name is a substring matched case-insensitively.
@(test)
test_task_slice_listing_filters_by_owner_and_name :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	assets := [3]pr.Asset {
		slice_test_slice_asset(71, `{"version":1,"name":"Shard hardening","owner":"rene","closed":false}`),
		slice_test_slice_asset(72, `{"version":1,"name":"Websocket send path","owner":"anke","closed":false}`),
		slice_test_slice_asset(73, `{"version":1,"name":"Shard migration","owner":"","closed":false}`),
	}
	for i in 0 ..< len(assets) do slice_test_add_asset(&conv, &assets[i])

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)

	// One owner, exactly.
	page := collect_task_slices(&conv, Slice_Query{has_owner = true, owner = "anke", limit = 10}, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, page.total_count, u32(1))
	testing.expect_value(t, len(slices), 1)
	testing.expect_value(t, string(slices[0].name), "Websocket send path")

	// An empty owner is the slices nobody owns, which is not every slice.
	clear(&slices)
	unowned := collect_task_slices(&conv, Slice_Query{has_owner = true, owner = "", limit = 10}, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, unowned.total_count, u32(1))
	testing.expect_value(t, string(slices[0].name), "Shard migration")

	// A name filter is a substring, and the reader's case does not matter.
	clear(&slices)
	shard := collect_task_slices(&conv, Slice_Query{has_name = true, name = "SHARD", limit = 10}, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, shard.total_count, u32(2))
	testing.expect_value(t, len(slices), 2)
	testing.expect_value(t, string(slices[0].name), "Shard hardening")
	testing.expect_value(t, string(slices[1].name), "Shard migration")

	// Both filters at once narrow to their intersection.
	clear(&slices)
	both := collect_task_slices(
		&conv,
		Slice_Query{has_owner = true, owner = "rene", has_name = true, name = "shard", limit = 10},
		&slices,
		&assigned,
		context.temp_allocator,
	)
	testing.expect_value(t, both.total_count, u32(1))
	testing.expect_value(t, string(slices[0].name), "Shard hardening")

	// A filter that matches nothing is an empty page, not an error.
	clear(&slices)
	none := collect_task_slices(&conv, Slice_Query{has_name = true, name = "zzz", limit = 10}, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, none.total_count, u32(0))
	testing.expect_value(t, len(slices), 0)
	testing.expect(t, !none.has_more, "a listing with no match has no next page")
}

// The workspace counters speak about every slice, closed ones included, and only
// the unfiltered first page folds them: a filtered or continued listing says how
// much work matches, not how much exists.
@(test)
test_task_slice_work_counters_belong_to_the_unfiltered_first_page :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	open := slice_test_slice_asset(71, `{"version":1,"name":"Alpha","owner":"rene","closed":false}`)
	closed := slice_test_slice_asset(72, `{"version":1,"name":"Beta","owner":"anke","closed":true}`, created_at = 900)
	slice_test_add_asset(&conv, &open)
	slice_test_add_asset(&conv, &closed)

	tasks := [3]pr.Task {
		{id = 1, status = .Todo, created_at = 10, updated_at = 200},
		{id = 2, status = .Todo, created_at = 10, updated_at = 200},
		{id = 3, status = .Todo, created_at = 10, updated_at = 200},
	}
	for i in 0 ..< len(tasks) do slice_test_add_task(&conv, &tasks[i])
	slice_test_member_of(&conv, .Task, 1, 71)
	// Closing a slice does not unassign its work, so the counters still count it.
	slice_test_member_of(&conv, .Task, 2, 72)

	slices := make([dynamic]pr.TaskSlice, 0, 8)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 8)
	defer delete(assigned)

	page := collect_task_slices(&conv, Slice_Query{limit = 10, with_work_counters = true}, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, page.total_count, u32(1))
	testing.expect_value(t, page.assigned_tasks, u32(2))
	testing.expect_value(t, page.unassigned_tasks, u32(1))

	// A closed slice the listing does not draw is not folded either: its members
	// are the counters' business, not a page's.
	clear(&slices)
	clear(&assigned)
	open_only := collect_task_slices(&conv, Slice_Query{limit = 10}, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, open_only.total_count, u32(1))
	testing.expect_value(t, len(assigned), 1)
	testing.expect(t, pr.TaskID(2) not_in assigned, "a closed slice the page does not draw is not folded")

	// A filtered listing carries no workspace counters at all.
	clear(&slices)
	clear(&assigned)
	filtered := collect_task_slices(&conv, Slice_Query{has_owner = true, owner = "rene", limit = 10}, &slices, &assigned, context.temp_allocator)
	testing.expect_value(t, filtered.total_count, u32(1))
	testing.expect_value(t, filtered.assigned_tasks, u32(0))
	testing.expect_value(t, filtered.unassigned_tasks, u32(0))
}

// A page is one frame, so the largest page a request may ask for has to fit the
// payload limit. The bound is arithmetic, not a hope: a slice row is bounded by
// its name, its owner and its counters.
@(test)
test_slice_page_fits_one_frame :: proc(t: ^testing.T) {
	name := make([]byte, pr.MAX_PROJECT_LENGTH)
	defer delete(name)
	owner := make([]byte, pr.MAX_ASSIGNEE_LENGTH)
	defer delete(owner)
	slices := make([]pr.TaskSlice, pr.MAX_TASK_SLICE_COUNT)
	defer delete(slices)
	for i in 0 ..< len(slices) {
		slices[i] = pr.TaskSlice {
			name     = name,
			owner    = owner,
			slice_id = pr.AssetID(i + 1),
		}
	}

	msg := pr.TaskSliceList {
		slices = slices,
	}
	testing.expect(t, pr.getSizeTaskSliceList(msg) <= MAX_PROTOCOL_PAYLOAD_SIZE, "the largest page a request may ask for fits one frame")
}

@(test)
test_slice_opcodes_are_accepted_by_get_opcode :: proc(t: ^testing.T) {
	request := [2]byte{}
	request[0] = u8(u16(pr.Opcode.C_ListTaskSlices) >> 8)
	request[1] = u8(u16(pr.Opcode.C_ListTaskSlices) & 0xFF)
	testing.expect_value(t, pr.get_opcode(request[:]), pr.Opcode.C_ListTaskSlices)

	response := [2]byte{}
	response[0] = u8(u16(pr.Opcode.S_TaskSliceList) >> 8)
	response[1] = u8(u16(pr.Opcode.S_TaskSliceList) & 0xFF)
	testing.expect_value(t, pr.get_opcode(response[:]), pr.Opcode.S_TaskSliceList)
}
