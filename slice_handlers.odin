package main

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import "byte_pool"
import pr "protocol"

// ============================================================================
// Slices
// ============================================================================
//
// A slice is an explicit work stream: an asset of type `AssetType.Slice` whose
// members are the tasks, notes and files linked to it with a `MemberOf` edge.
//
// Nothing is derived from project labels. A label says which repository or
// module something belongs to, and that is a different question from which work
// stream it moves; keeping them apart is what lets a slice span repositories and
// lets one task belong to more than one slice.
//
// Membership is explicit, so the register's counters and the record's member
// lists read the same edges and cannot drift apart. Closure stays an act by the
// owner: a slice is closed by setting `closed_at`, never by its last member
// reaching Done, because a slice is frequently finished before its members are
// and frequently keeps members that will never be finished.

Slice_Preview :: struct {
	version:   int,
	name:      string,
	owner:     string,
	outcome:   string,
	closed:    bool,
	closed_at: i64,
	closed_by: string,
}

// slice_preview decodes a slice record. A record that does not decode, or that
// carries no name, is not a slice: it is skipped rather than repaired, so a
// corrupt record cannot invent a slice identity.
slice_preview :: proc(asset: ^pr.Asset, allocator: mem.Allocator) -> (m: Slice_Preview, ok: bool) {
	if asset == nil || json.unmarshal(asset.preview, &m, allocator = allocator) != nil do return
	ok = m.version == 1 && len(m.name) > 0 && len(m.name) <= pr.MAX_PROJECT_LENGTH
	return
}

slice_has_flag :: proc(slice: pr.TaskSlice, flag: pr.TaskSliceFlags) -> bool {
	return flag <= slice.flags
}

// slice_preview_name decodes just the identity a write has to validate. A record
// that does not decode, or that carries no name, is refused rather than stored:
// the register skips such a record, so accepting it would create an asset that
// no command and no register can address.
slice_preview_name :: proc(preview: []byte, allocator: mem.Allocator) -> (name: string, ok: bool) {
	m: Slice_Preview
	if json.unmarshal(preview, &m, allocator = allocator) != nil do return
	if m.version != 1 || len(m.name) == 0 || len(m.name) > pr.MAX_PROJECT_LENGTH do return
	return m.name, true
}

// slice_name_taken reports whether a slice other than `except` already carries
// the name. Renaming is not offered, so the only caller passes 0.
slice_name_taken :: proc(conv: ^Conversation_State, name: string, except: pr.AssetID) -> bool {
	if conv == nil do return false
	for id, asset in conv.assets {
		if id == except || asset.asset_type != .Slice do continue
		m, ok := slice_preview(asset, context.temp_allocator)
		if ok && m.name == name do return true
	}
	return false
}

// slice_member_endpoint returns the endpoint of a MemberOf edge that is not the
// slice itself. An edge between a slice and itself is not a membership.
slice_member_endpoint :: proc(edge: ^pr.Edge, slice_id: pr.AssetID) -> (member_type: pr.TargetType, member_id: u64, found: bool) {
	slice_is_target := edge.target_type == .Asset && edge.target_id == u64(slice_id)
	slice_is_source := edge.source_type == .Asset && edge.source_id == u64(slice_id)
	// A slice is not its own member: the server refuses self-edges, and the read
	// path does not assume that every record it replays was written by this server.
	if slice_is_target && slice_is_source do return {}, 0, false
	if slice_is_target {
		return edge.source_type, edge.source_id, true
	}
	if slice_is_source {
		return edge.target_type, edge.target_id, true
	}
	return {}, 0, false
}

// unassigned_task_count reports how much work has no slice, so the register can
// say it out loud instead of letting it hide. Retired tasks are not work, and a
// task that belongs to any slice is assigned even when that slice is closed.
unassigned_task_count :: proc(conv: ^Conversation_State, assigned: ^map[pr.TaskID]struct{}) -> u32 {
	if conv == nil do return 0
	count: u32
	for id, task in conv.tasks {
		if task == nil || task.status == .Note do continue
		if assigned != nil && id in assigned^ do continue
		count += 1
	}
	return count
}

// fold_task_member adds one task member to a slice's counters and returns whether
// it was counted as work. A task retired into a note is not work: it leaves the
// task indexes and the member query, so it is not counted here either, and the
// counters and the record stay in agreement.
fold_task_member :: proc(entry: ^pr.TaskSlice, task: ^pr.Task, overflow: ^bool = nil) -> bool {
	if task == nil || task.status == .Note do return false
	switch task.status {
	case .Backlog:
		slice_increment_count(&entry.backlog, overflow)
	case .Todo:
		slice_increment_count(&entry.todo, overflow)
	case .InProgress:
		slice_increment_count(&entry.in_progress, overflow)
	case .Done:
		slice_increment_count(&entry.done, overflow)
	case .Note:
		return false
	}
	if task.blocked_by != 0 do slice_increment_count(&entry.blocked, overflow)
	// Done members do not hold the oldest-active age back.
	if task.status != .Done && (entry.oldest_active_at == 0 || task.created_at < entry.oldest_active_at) {
		entry.oldest_active_at = task.created_at
	}
	if task.updated_at > entry.last_moved_at do entry.last_moved_at = task.updated_at
	return true
}

// fold_asset_member adds one note or file member. Other asset kinds are not
// members of a work stream, so a link to one does not invent a member.
fold_asset_member :: proc(entry: ^pr.TaskSlice, asset: ^pr.Asset, overflow: ^bool = nil) {
	if asset == nil do return
	#partial switch asset.asset_type {
	case .Note:
		slice_increment_count(&entry.notes, overflow)
	case .File:
		slice_increment_count(&entry.files, overflow)
	case:
		return
	}
	if asset.updated_at > entry.last_moved_at do entry.last_moved_at = asset.updated_at
}

// Wire counters are independent u16 categories, not a bound on total members.
// Keep a counter representable and let the listing reject the entire result.
slice_increment_count :: proc(count: ^u16, overflow: ^bool) {
	if count^ == max(u16) {
		if overflow != nil do overflow^ = true
		return
	}
	count^ += 1
}

// Slice_Order_Entry pairs a listing entry with the slice record's own creation
// time, which is the floor of the register's sort key: a slice that carries no
// members yet has no movement to report, and sorting it to the bottom would bury
// the slice that was just created.
Slice_Order_Entry :: struct {
	entry:      pr.TaskSlice,
	created_at: i64,
}

// Slice_Cursor names the last slice of a page in the register's own order:
// closure, then movement, then ID. Closure is part of the key because closed
// slices sink below the active ones, so movement alone cannot place the cursor.
Slice_Cursor :: struct {
	closed:   bool,
	sort_at:  i64,
	slice_id: pr.AssetID,
}

// slice_cursor_entry rebuilds the sort key a cursor names. The entry carries no
// members, so its own creation time is the cursor's sort key and its movement is
// left at zero; the register's comparison reads the maximum of the two.
slice_cursor_entry :: proc(cursor: Slice_Cursor) -> Slice_Order_Entry {
	entry := pr.TaskSlice {
		slice_id = cursor.slice_id,
	}
	if cursor.closed do entry.flags += pr.TaskSliceFlag_CLOSED
	return {entry = entry, created_at = cursor.sort_at}
}

slice_entry_cursor :: proc(item: Slice_Order_Entry) -> Slice_Cursor {
	return {
		closed = slice_has_flag(item.entry, pr.TaskSliceFlag_CLOSED),
		sort_at = max(item.entry.last_moved_at, item.created_at),
		slice_id = item.entry.slice_id,
	}
}

// Slice_Query is one page request of the register: the filters the reader set,
// the page bound and the cursor the previous page ended on.
Slice_Query :: struct {
	include_closed:     bool,
	// An owner filter names one owner exactly; an empty name with `has_owner` is
	// the slices nobody owns.
	has_owner:          bool,
	owner:              string,
	// A name filter matches a substring of the slice name. The caller lowers it
	// once, because every record's name is lowered to compare.
	has_name:           bool,
	name:               string,
	limit:              int,
	has_cursor:         bool,
	cursor_closed:      bool,
	cursor_sort_at:     i64,
	cursor_slice_id:    pr.AssetID,
	// The work counters speak about every slice in the workspace, closed ones
	// included, so they are folded only for the first page of an unfiltered
	// listing. Every other request folds just the rows it can draw.
	with_work_counters: bool,
}

// Slice_Page is what one page carries beyond its rows: how many slices the
// filters match, whether another page follows, where that page continues, and the
// workspace counters when this request folded them.
Slice_Page :: struct {
	total_count:      u32,
	has_more:         bool,
	next_cursor:      Slice_Cursor,
	assigned_tasks:   u32,
	unassigned_tasks: u32,
	error:            string,
}

// slice_matches_filters reports whether a record is part of what the query asks
// for. A name filter is a substring match, because a slice is addressed by its
// name and the register's query is a search; `query.name` is already lowered.
slice_matches_filters :: proc(m: Slice_Preview, query: Slice_Query, allocator: mem.Allocator) -> bool {
	if query.has_owner {
		if m.owner != query.owner do return false
	}
	if query.has_name {
		if !strings.contains(strings.to_lower(m.name, allocator), query.name) do return false
	}
	return true
}

// slice_order_less is the register's order, and the only one: closed slices sink
// below the active ones, the work stream moved most recently comes first, and the
// slice ID breaks the remaining ties. The comparison is total, so the listing does
// not depend on whether the sort is stable, and IDs are time-ordered, so slices
// that moved in the same instant keep the order they were created in.
slice_order_less :: proc(a, b: Slice_Order_Entry) -> bool {
	a_closed := slice_has_flag(a.entry, pr.TaskSliceFlag_CLOSED)
	b_closed := slice_has_flag(b.entry, pr.TaskSliceFlag_CLOSED)
	if a_closed != b_closed do return !a_closed
	a_moved := max(a.entry.last_moved_at, a.created_at)
	b_moved := max(b.entry.last_moved_at, b.created_at)
	if a_moved != b_moved do return a_moved > b_moved
	return a.entry.slice_id < b.entry.slice_id
}

// collect_task_slices lists one page of the register with its counters folded
// from the membership edges.
//
// Cost is O(slices + member edges): the adjacency index answers "what points at
// this slice" in one lookup, and each member is one map lookup. Nothing is
// scanned per label, and no index has to be maintained for slices to exist.
//
// The whole matching listing is ordered before the page is taken, so a page
// always holds the front of the register's order: the work streams that moved
// most recently, not an arbitrary window of the asset map's iteration order. The
// order is the register's, not a choice of the caller: the register, the record
// and the CLI read one listing.
//
// `assigned` collects the task members seen. It is the workspace counters' map,
// so it is only filled when the query asks for them; members of closed slices are
// counted then too, because closing a slice does not unassign its tasks.
collect_task_slices :: proc(
	conv: ^Conversation_State,
	query: Slice_Query,
	slices: ^[dynamic]pr.TaskSlice,
	assigned: ^map[pr.TaskID]struct{},
	allocator: mem.Allocator,
) -> (
	page: Slice_Page,
) {
	if conv == nil || slices == nil do return

	// The name filter is lowered once, because every record's name is lowered to
	// compare against it.
	effective := query
	if effective.has_name do effective.name = strings.to_lower(effective.name, allocator)

	// The entries are collected with their sort key and ordered afterwards: the
	// register's order is decided over every matching slice, so a page keeps the
	// front of it rather than the first slices the map happened to hand out.
	ordered := make([dynamic]Slice_Order_Entry, 0, 16, allocator)
	defer delete(ordered)

	for _, asset in conv.assets {
		if asset.asset_type != .Slice do continue
		m, ok := slice_preview(asset, allocator)
		if !ok do continue
		if !slice_matches_filters(m, effective, allocator) do continue

		// A closed slice the listing does not carry is not folded: the register
		// cannot draw it, and a workspace may hold many of them. The workspace
		// counters are the one request that folds them anyway.
		if m.closed && !query.include_closed && !query.with_work_counters do continue

		entry := pr.TaskSlice {
			name     = transmute([]byte)m.name,
			slice_id = asset.asset_id,
			owner    = transmute([]byte)m.owner,
		}
		if m.closed do entry.flags += pr.TaskSliceFlag_CLOSED

		overflow := false
		key := Edge_Entity_Key {
			target_type = .Asset,
			target_id   = u64(asset.asset_id),
		}
		if edge_ids, has_edges := conv.edges_by_entity[key]; has_edges {
			for edge_id in edge_ids {
				edge := conv.edges[edge_id]
				if edge == nil || edge.relation != .MemberOf do continue
				member_type, member_id, found := slice_member_endpoint(edge, asset.asset_id)
				if !found do continue
				switch member_type {
				case .Task:
					task_id := pr.TaskID(member_id)
					if fold_task_member(&entry, conv.tasks[task_id], &overflow) && assigned != nil {
						assigned[task_id] = {}
					}
				case .Asset:
					fold_asset_member(&entry, conv.assets[pr.AssetID(member_id)], &overflow)
				}
				if overflow {
					clear(slices)
					return Slice_Page{error = "Slice listing representation limit exceeded: member category exceeds 65535"}
				}
			}
		}

		if m.closed && !query.include_closed do continue

		page.total_count += 1
		append(&ordered, Slice_Order_Entry{entry = entry, created_at = asset.created_at})
	}

	slice.sort_by(ordered[:], slice_order_less)

	// The cursor is the last slice of the previous page, so this page starts at
	// the first entry that sorts after it.
	start := 0
	if query.has_cursor {
		cursor := slice_cursor_entry({closed = query.cursor_closed, sort_at = query.cursor_sort_at, slice_id = query.cursor_slice_id})
		for start < len(ordered) && !slice_order_less(cursor, ordered[start]) do start += 1
	}

	limit := query.limit
	if limit <= 0 do limit = pr.MAX_TASK_SLICE_COUNT
	end := min(start + limit, len(ordered))
	for item in ordered[start:end] do append(slices, item.entry)
	page.has_more = end < len(ordered)
	if end > start do page.next_cursor = slice_entry_cursor(ordered[end - 1])

	if query.with_work_counters && assigned != nil {
		page.assigned_tasks = u32(len(assigned))
		page.unassigned_tasks = unassigned_task_count(conv, assigned)
	}
	return
}

process_list_task_slices :: proc(c: ^NRC_Connection, req: pr.ListTaskSlicesRequest) {
	conv := get_conversation(get_connection_workspace(c), req.conv_id)
	if conv == nil {
		send_task_slice_list(c, req.conv_id, nil, {}, "", req.correlation_id)
		return
	}

	// One arena for the whole request: names and previews must stay valid until
	// the response has been serialized, so nothing is freed mid-collection.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		send_task_slice_list(c, req.conv_id, nil, {}, "Slice listing allocation failed", req.correlation_id)
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	slices := make([dynamic]pr.TaskSlice, 0, 16, allocator)
	defer delete(slices)
	assigned := make(map[pr.TaskID]struct{}, 64, allocator)
	defer delete(assigned)

	// The workspace counters are a statement about every slice, so they are folded
	// on the first page of an unfiltered listing; a filtered or continued listing
	// says how much work matches, not how much exists.
	query := Slice_Query {
		include_closed     = req.include_closed,
		has_owner          = req.has_owner,
		owner              = string(req.owner),
		has_name           = req.has_name,
		name               = string(req.name),
		limit              = int(req.limit),
		has_cursor         = req.has_cursor,
		cursor_closed      = req.cursor_closed,
		cursor_sort_at     = req.cursor_sort_at,
		cursor_slice_id    = req.cursor_slice_id,
		with_work_counters = !req.has_cursor && !req.has_owner && !req.has_name,
	}
	page := collect_task_slices(conv, query, &slices, &assigned, allocator)
	send_task_slice_list(c, req.conv_id, slices[:], page, page.error, req.correlation_id)
}

// ============================================================================
// Response Senders
// ============================================================================

// send_task_slice_list answers one page in one frame. A page is bounded by the
// request's limit, and a slice row is bounded too, so the largest page stays
// below the payload limit: the test suite asserts that bound rather than trusting
// it (test_slice_page_fits_one_frame).
send_task_slice_list :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	slices: []pr.TaskSlice,
	page: Slice_Page,
	error_msg: string,
	correlation_id: u32,
) {
	msg := pr.TaskSliceList {
		conv_id              = conv_id,
		success              = error_msg == "",
		slices               = slices,
		has_more             = page.has_more,
		next_cursor_closed   = page.next_cursor.closed,
		next_cursor_sort_at  = page.next_cursor.sort_at,
		next_cursor_slice_id = page.next_cursor.slice_id,
		total_count          = page.total_count,
		assigned_tasks       = page.assigned_tasks,
		unassigned_tasks     = page.unassigned_tasks,
		error                = transmute([]byte)error_msg,
		correlation_id       = correlation_id,
	}
	write_task_slice_list(c, msg)
}

write_task_slice_list :: proc(c: ^NRC_Connection, msg: pr.TaskSliceList) -> bool {
	size := pr.getSizeTaskSliceList(msg)
	buf, header_len := allocate_websocket_frame_buffer(size, "task slice list")
	if buf == nil do return false
	written := pr.serializeTaskSliceList(msg, buf[header_len:])
	if written <= 0 {
		byte_pool.release(td.spool, buf)
		return false
	}
	return send_pooled_buffer(c, buf[:header_len + written])
}
