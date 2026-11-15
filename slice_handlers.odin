package main

import "byte_pool"
import "core:encoding/json"
import "core:mem"
import pr "protocol"

Slice_Preview :: struct {
	version:   int,
	name:      string,
	owner:     string,
	outcome:   string,
	closed:    bool,
	closed_at: i64,
	closed_by: string,
}

slice_preview :: proc(asset: ^pr.Asset, allocator: mem.Allocator) -> (m: Slice_Preview, ok: bool) {
	if asset == nil do return
	return decode_slice_preview(asset.preview, allocator)
}

// Keep the JSON decoder and its default semantics identical for reads and writes.
decode_slice_preview :: proc(preview: []byte, allocator: mem.Allocator) -> (m: Slice_Preview, ok: bool) {
	if json.unmarshal(preview, &m, allocator = allocator) != nil do return
	ok = m.version == 1 && len(m.name) > 0 && len(m.name) <= pr.MAX_PROJECT_LENGTH
	return
}

slice_has_flag :: proc(slice: pr.TaskSlice, flag: pr.TaskSliceFlags) -> bool {
	return flag <= slice.flags
}

// Names need not be unique; the asset ID is the slice's identity.
slice_preview_name :: proc(preview: []byte, allocator: mem.Allocator) -> (name: string, ok: bool) {
	m, valid := decode_slice_preview(preview, allocator)
	if !valid do return
	return m.name, true
}

// A retired task is not work; Done members do not hold the active age back.
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
	if task.status != .Done && task.created_at != 0 && (entry.oldest_active_at == 0 || task.created_at < entry.oldest_active_at) {
		entry.oldest_active_at = task.created_at
	}
	if task.updated_at > entry.last_moved_at do entry.last_moved_at = task.updated_at
	return true
}

fold_asset_member :: proc(entry: ^pr.TaskSlice, asset: ^pr.Asset, overflow: ^bool = nil) {
	if asset == nil do return
	#partial switch asset.asset_type {
	case .Note:
		slice_increment_count(&entry.notes, overflow)
	case .File:
		slice_increment_count(&entry.files, overflow)
	case .Ticket:
		slice_increment_count(&entry.tickets, overflow)
	case:
		return
	}
	if asset.updated_at > entry.last_moved_at do entry.last_moved_at = asset.updated_at
}

// Wire counters are independent u16 categories, not a bound on total members.
slice_increment_count :: proc(count: ^u16, overflow: ^bool) {
	if count^ == max(u16) {
		if overflow != nil do overflow^ = true
		return
	}
	count^ += 1
}

Slice_Cursor :: struct {
	closed:   bool,
	sort_at:  i64,
	slice_id: pr.AssetID,
}

Slice_Page :: struct {
	total_count:      u32,
	has_more:         bool,
	next_cursor:      Slice_Cursor,
	assigned_tasks:   u32,
	unassigned_tasks: u32,
	error:            string,
}

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
