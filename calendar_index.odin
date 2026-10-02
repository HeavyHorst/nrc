package main

import "btree"
import "byte_pool"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import pr "protocol"

foreign import calendar_zstd "system:zstd"
foreign calendar_zstd {
	ZSTD_decompress :: proc(dst: rawptr, capacity: uintptr, src: rawptr, size: uintptr) -> uintptr ---
	ZSTD_isError :: proc(code: uintptr) -> u32 ---
}

Appointment_Index_Key :: struct {
	bucket:           u8,
	slot:             i64,
	end_at, start_at: i64,
	id:               pr.AssetID,
}

appointment_index_compare :: proc(a, b: Appointment_Index_Key) -> int {
	if a.bucket != b.bucket do return a.bucket < b.bucket ? -1 : 1
	if a.slot != b.slot do return a.slot < b.slot ? -1 : 1
	if a.start_at != b.start_at do return a.start_at < b.start_at ? -1 : 1
	if a.id != b.id do return a.id < b.id ? -1 : 1
	return 0
}

// One entry in the smallest power-of-two time bucket containing the interval.
// Queries seek only intersecting buckets at each level, skipping both historical
// and future records. No duration cap or per-day expansion is needed.
appointment_index_key :: proc(start, end: i64, id: pr.AssetID) -> Appointment_Index_Key {
	last := end == 0 ? start : end - 1
	bucket: u8
	for different := start ~ last; different != 0; different >>= 1 do bucket += 1
	return {bucket, start >> bucket, end, start, id}
}

calendar_key_compare :: proc(a, b: pr.CalendarKey) -> int {
	if a.at != b.at do return a.at < b.at ? -1 : 1
	if a.kind != b.kind do return a.kind < b.kind ? -1 : 1
	if a.id != b.id do return a.id < b.id ? -1 : 1
	return 0
}

// Payload wins over preview, including legacy camelCase fields. Parse real JSON
// so nested fields or quoted field names in a title cannot invent deadlines.
calendar_reminder :: proc(asset: ^pr.Asset, allocator: mem.Allocator) -> (at: i64, title: []byte) {
	if asset == nil || asset.asset_type != .Reminder do return
	payload := asset.payload
	if asset.payload_encoding == .Zstd {
		payload = nil
		if asset.payload_raw_len > 0 && asset.payload_raw_len <= pr.MAX_PAYLOAD_LENGTH {
			decoded := make([]byte, int(asset.payload_raw_len), allocator)
			size := ZSTD_decompress(raw_data(decoded), uintptr(len(decoded)), raw_data(asset.payload), uintptr(len(asset.payload)))
			if ZSTD_isError(size) == 0 && size == uintptr(len(decoded)) do payload = decoded
		}
	}
	for data in ([?][]byte{payload, asset.preview}) {
		fields, object, valid := json_metadata_fields(data, [?]string{"deadline_at", "deadlineAt", "title", "name"}, allocator)
		if !valid do continue
		if !object do return
		deadline := fields[0]
		if deadline.kind == .Invalid || deadline.kind == .Null do deadline = fields[1]
		#partial switch deadline.kind {
		case .String, .Integer:
			text := deadline.kind == .String ? json_metadata_string(deadline, allocator) : deadline.text
			parsed, ok := json_metadata_integer(text)
			if ok do at = parsed
		case .Float:
			v, ok := strconv.parse_f64(deadline.text)
			if ok && v > 0 && v < 9223372036854775808.0 do at = i64(v)
		}
		name := json_metadata_string(fields[2], allocator)
		if name == "" do name = json_metadata_string(fields[3], allocator)
		if name == "" do name = string(asset.preview)
		name = strings.trim_space(name)
		if at <= 0 || name == "" do return 0, nil
		return at, transmute([]byte)name
	}
	return
}

calendar_index_task :: proc(conv: ^Conversation_State, task: ^pr.Task, remove := false) {
	if !conv.calendar_ready || task == nil || task.due_at <= 0 || !task_status_is_active(task.status) do return
	key := pr.CalendarKey{task.due_at, 0, u64(task.id)}
	if remove {_, _ = btree.remove(&conv.calendar_index, key)} else {_, _ = btree.set(&conv.calendar_index, key)}
}
calendar_index_asset :: proc(conv: ^Conversation_State, asset: ^pr.Asset, remove := false) {
	if !conv.calendar_ready || asset == nil do return
	if old, ok := conv.calendar_reminder_keys[asset.asset_id]; ok {
		_, _ = btree.remove(&conv.calendar_index, old)
		delete_key(&conv.calendar_reminder_keys, asset.asset_id)
	}
	if old, ok := conv.calendar_appointment_keys[asset.asset_id]; ok {
		_, _ = btree.remove(&conv.calendar_appointments, old)
		delete_key(&conv.calendar_appointment_keys, asset.asset_id)
	}
	if !remove && asset.asset_type == .Appointment {
		record, valid := parse_appointment_preview(asset.preview, context.temp_allocator)
		if valid {
			key := appointment_index_key(record.start_at, record.end_at, asset.asset_id)
			_, _ = btree.set(&conv.calendar_appointments, key)
			state_map_set(&conv.calendar_appointment_keys, asset.asset_id, key)
		}
		return
	}
	if remove || asset.asset_type != .Reminder do return
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	at, _ := calendar_reminder(asset, virtual.arena_allocator(&arena))
	if at <= 0 do return
	key := pr.CalendarKey{at, 1, u64(asset.asset_id)}
	_, _ = btree.set(&conv.calendar_index, key)
	state_map_set(&conv.calendar_reminder_keys, asset.asset_id, key)
}
calendar_index_ensure :: proc(conv: ^Conversation_State) {
	if conv.calendar_ready do return
	conv.calendar_index = btree.create(pr.CalendarKey, calendar_key_compare, btree.Options{degree = 32})
	conv.calendar_reminder_keys = make(map[pr.AssetID]pr.CalendarKey)
	conv.calendar_appointments = btree.create(Appointment_Index_Key, appointment_index_compare, btree.Options{degree = 32})
	conv.calendar_appointment_keys = make(map[pr.AssetID]Appointment_Index_Key)
	conv.calendar_ready = true
	for _, task in conv.tasks do calendar_index_task(conv, task)
	for _, asset in conv.assets do calendar_index_asset(conv, asset)
}
calendar_index_destroy :: proc(conv: ^Conversation_State) {
	if !conv.calendar_ready do return
	btree.destroy(&conv.calendar_index)
	delete(conv.calendar_reminder_keys)
	btree.destroy(&conv.calendar_appointments)
	delete(conv.calendar_appointment_keys)
	conv.calendar_ready = false
}

// Seek directly into the visible range; no workspace-wide count or payload scan.
collect_calendar_page :: proc(
	conv: ^Conversation_State,
	req: pr.CalendarRequest,
	rows: ^[dynamic]pr.CalendarRow,
	allocator: mem.Allocator,
) -> (
	more: bool,
	visited: int,
) {
	if conv == nil do return
	calendar_index_ensure(conv)
	it := btree.iter(&conv.calendar_index); defer btree.iter_destroy(&it)
	pivot := req.has_cursor ? req.cursor : pr.CalendarKey{at = req.start}
	found := btree.iter_seek(&it, pivot)
	if found && req.has_cursor && calendar_key_compare(btree.item(&it), pivot) <= 0 do found = btree.iter_next(&it)
	size := 34
	for found {
		key := btree.item(&it)
		if key.at >= req.end do break
		visited += 1
		found = btree.iter_next(&it)
		row := pr.CalendarRow {
			key = key,
		}
		if key.kind == 0 {
			task := conv.tasks[pr.TaskID(key.id)]
			if task == nil do continue
			if len(req.assignee) > 0 && string(req.assignee) != string(task.assignee) do continue
			if len(req.project) > 0 && string(req.project) != string(task.project) do continue
			row.title = task.title; row.assignee = task.assignee; row.project = task.project; row.blocked = task.blocked_by != 0
		} else {
			if len(req.assignee) > 0 || len(req.project) > 0 do continue
			_, row.title = calendar_reminder(conv.assets[pr.AssetID(key.id)], allocator)
		}
		append(rows, row)
		// Later point rows cannot enter a page already filled by earlier ones.
		if len(rows) > int(req.limit) do break
	}
	ai := btree.iter(&conv.calendar_appointments); defer btree.iter_destroy(&ai)
	for bucket: u8 = 0; bucket < 64; bucket += 1 {
		last_slot := (req.end - 1) >> bucket
		af := btree.iter_seek(&ai, Appointment_Index_Key{bucket = bucket, slot = req.start >> bucket})
		for af {
			ik := btree.item(&ai); af = btree.iter_next(&ai)
			if ik.bucket != bucket || ik.slot > last_slot do break
			visited += 1
			if ik.start_at >= req.end do continue
			if ik.end_at != 0 && ik.end_at <= req.start do continue
			if ik.end_at == 0 && ik.start_at < req.start do continue
			key := pr.CalendarKey{max(ik.start_at, req.start), 2, u64(ik.id)}
			if req.has_cursor && calendar_key_compare(key, req.cursor) <= 0 do continue
			asset := conv.assets[ik.id]; if asset == nil do continue
			record, valid := parse_appointment_preview(asset.preview, allocator); if !valid do continue
			if len(req.assignee) > 0 && string(req.assignee) != string(record.assignee) do continue
			if len(req.project) > 0 && string(req.project) != string(record.project) do continue
			append(
				rows,
				pr.CalendarRow {
					key = key,
					title = record.title,
					assignee = record.assignee,
					project = record.project,
					actual_start_at = record.start_at,
					end_at = record.end_at,
				},
			)
		}
	}
	slice.sort_by(rows^[:], proc(a, b: pr.CalendarRow) -> bool {return calendar_key_compare(a.key, b.key) < 0})
	keep := 0
	for row in rows^ {
		row_size := pr.calendar_row_size(row)
		if keep >= int(req.limit) || (keep > 0 && size + row_size > MAX_PROTOCOL_PAYLOAD_SIZE) {more = true; break}
		rows^[keep] = row; keep += 1; size += row_size
	}
	resize(rows, keep)
	return
}
process_calendar_query :: proc(c: ^NRC_Connection, req: pr.CalendarRequest) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {send_error_response(c, .C_QueryCalendar, "Calendar allocation failed", req.correlation_id); return}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	rows := make([dynamic]pr.CalendarRow, 0, int(req.limit), allocator)
	conv := get_conversation(get_connection_workspace(c), req.conv_id)
	more, _ := collect_calendar_page(conv, req, &rows, allocator)
	size := 34
	for row in rows do size += pr.calendar_row_size(row)
	buf, header := allocate_websocket_frame_buffer(size, "calendar page")
	if buf == nil do return
	written := pr.serializeCalendarPage(rows[:], more, req.correlation_id, buf[header:])
	if written < 0 {byte_pool.release(td.spool, buf); return}
	_ = send_pooled_buffer(c, buf[:header + written])
}
