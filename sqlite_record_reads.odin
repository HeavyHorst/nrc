package main

import "core:c"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Copies one visible asset into the caller's scoped arena. No SQLite view
// escapes. The executor transaction supplies a common snapshot for attachments.
// validate_only preserves all checks but returns an empty asset without copies.
sqlite_read_asset :: proc(
	store: ^db.Store,
	workspace, actor: string,
	id: u64,
	full: bool,
	check_visibility := true,
	validate_only := false,
) -> (
	a: pr.Asset,
	found: bool,
	rc: c.int,
) {
	defer if validate_only {a = {}}
	s: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT asset_type,parent_type,parent_id,owner,created_at,updated_at,payload_encoding,payload_raw_len,preview,
	 CASE WHEN ?3 THEN payload ELSE x'' END FROM assets WHERE workspace=?1 AND id=?2`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_id(s, 2, id); rc != sql.OK do return
	if rc = sql.bind_int64(s, 3, full ? 1 : 0); rc != sql.OK do return
	rc = sql.step(s)
	if rc == sql.DONE do return {}, false, sql.OK
	if rc != sql.ROW do return
	a.asset_id = id; a.asset_type = pr.AssetType(sql.column_int64(s, 0))
	a.parent_type = pr.ParentType(sql.column_int64(s, 1))
	a.parent_id, rc = sql.column_id(s, 2); if rc != sql.OK do return
	a.owner = sql.column_bytes_view(s, 3); a.preview = sql.column_bytes_view(s, 8)
	if len(a.owner) > pr.MAX_OWNER_LENGTH || len(a.preview) > pr.MAX_PREVIEW_LENGTH do return {}, false, sql.CORRUPT
	if check_visibility && !asset_visible_to(&a, actor) do return {}, false, sql.OK
	a.created_at = sql.column_int64(s, 4); a.updated_at = sql.column_int64(s, 5)
	a.payload_encoding = pr.PayloadEncoding(sql.column_int64(s, 6))
	raw_len := sql.column_int64(s, 7)
	if raw_len < 0 || raw_len > pr.MAX_PAYLOAD_LENGTH do return {}, false, sql.CORRUPT
	a.payload_raw_len = u32(raw_len); a.payload = sql.column_bytes_view(s, 9)
	if len(a.payload) > pr.MAX_PAYLOAD_LENGTH do return {}, false, sql.CORRUPT
	if !validate_only {
		a.owner = transmute([]byte)strings.clone(string(a.owner))
		a.preview = transmute([]byte)strings.clone(string(a.preview))
		a.payload = transmute([]byte)strings.clone(string(a.payload))
	}
	attachments: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		"SELECT file_id,filename,size,mime_type,uploaded_at FROM asset_attachments WHERE workspace=?1 AND asset_id=?2 ORDER BY ordinal",
		-1,
		&attachments,
		nil,
	)
	if rc != sql.OK do return
	defer sql.finalize(attachments)
	if rc = sql.bind_bytes(attachments, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_id(attachments, 2, id); rc != sql.OK do return
	items: []pr.Attachment
	if !validate_only do items = make([]pr.Attachment, pr.MAX_ATTACHMENTS_PER_TASK)
	count := 0
	for {
		rc = sql.step(attachments)
		if rc == sql.DONE do break
		if rc != sql.ROW do return
		if count == pr.MAX_ATTACHMENTS_PER_TASK do return {}, false, sql.CORRUPT
		if sql.column_bytes(attachments, 0) > pr.MAX_FILE_ID_LENGTH ||
		   sql.column_bytes(attachments, 1) > pr.MAX_FILENAME_LENGTH ||
		   sql.column_bytes(attachments, 3) > pr.MAX_MIME_TYPE_LENGTH {
			return {}, false, sql.CORRUPT
		}
		size: u64
		size, rc = sql.column_id(attachments, 2); if rc != sql.OK do return
		if !validate_only {
			item := &items[count]
			item.file_id = transmute([]byte)strings.clone(string(sql.column_bytes_view(attachments, 0)))
			item.filename = transmute([]byte)strings.clone(string(sql.column_bytes_view(attachments, 1)))
			item.size = size
			item.mime_type = transmute([]byte)strings.clone(string(sql.column_bytes_view(attachments, 3)))
			item.uploaded_at = sql.column_int64(attachments, 4)
		}
		count += 1
	}
	if validate_only do return {}, true, sql.OK
	a.attachments = items[:count]
	return a, true, sql.OK
}

sqlite_execute_record_reads :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	backing := context.allocator
	context.allocator = virtual.arena_allocator(&arena)
	if request.opcode == .C_GetAsset {
		req, err := pr.parseGetAssetRequest(request.body)
		if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
		a, found, rc := sqlite_read_asset(store, request.workspace, request.actor, req.asset_id, true)
		if rc != sql.OK do return rc
		context.allocator = backing
		if !found {
			msg := pr.ErrorResponse {
				origin_opcode  = .C_GetAsset,
				error_msg      = transmute([]byte)string("Asset not found"),
				correlation_id = req.correlation_id,
			}
			buf, frame_rc := db.command_frame(output, pr.getSizeErrorResponse(msg)); if frame_rc != sql.OK do return frame_rc
			return pr.serializeErrorResponse(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
		}
		msg := pr.AssetFullMessage {
			asset          = a,
			correlation_id = req.correlation_id,
		}
		buf, frame_rc := db.command_frame(output, pr.getSizeAssetFullMessage(msg)); if frame_rc != sql.OK do return frame_rc
		return pr.serializeAssetFullMessage(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	ids: [pr.MAX_ID_BATCH_SIZE]u64
	req, err := pr.parseGetRecordsByIDsRequest(request.body, ids[:])
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	assets := request.opcode == .C_GetAssetsByIDs
	selected: [pr.MAX_ID_BATCH_SIZE]u64
	sizes: [pr.MAX_ID_BATCH_SIZE]int
	count := 0
	// First pass keeps only IDs and wire sizes. Private/missing records do not
	// contribute to total_count. Input order survives deduplication.
	for id, i in req.ids {
		duplicate := false
		for previous in req.ids[:i] do if previous == id do duplicate = true
		if duplicate do continue
		virtual.arena_free_all(&arena)
		size := 0
		if assets {
			a, found, rc := sqlite_read_asset(store, request.workspace, request.actor, id, req.full_content)
			if rc != sql.OK do return rc
			if !found do continue
			size = req.full_content ? pr.getSizeAsset(a) : pr.getSizeAssetHeader(a)
		} else {
			task, found, rc := db.get_task(store, request.workspace, 0, id, max_bytes = 2 * pr.MAX_PROTOCOL_PAYLOAD_SIZE)
			if rc != sql.OK do return rc
			if !found do continue
			size = pr.getSizeTask(task)
		}
		selected[count] = id; sizes[count] = size; count += 1
	}
	base := assets ? pr.getSizeAssetListPageMessage({}) : pr.getSizeTaskListPage({})
	start := 0
	for {
		virtual.arena_free_all(&arena)
		end := start; size := base
		for end < count && sizes[end] <= pr.MAX_PROTOCOL_PAYLOAD_SIZE - size {size += sizes[end]; end += 1}
		if end == start && start < count do return sql.TOOBIG
		// Reserve the complete encoded chunk before copying its records.
		context.allocator = backing
		buf, rc := db.command_frame(output, size)
		context.allocator = virtual.arena_allocator(&arena)
		if rc != sql.OK do return rc
		if assets {
			rows: [pr.MAX_ID_BATCH_SIZE]pr.Asset
			for i in start ..< end {
				a, found, read_rc := sqlite_read_asset(store, request.workspace, request.actor, selected[i], req.full_content)
				if read_rc != sql.OK do return read_rc
				if !found do return sql.CORRUPT
				rows[i - start] = a
			}
			msg := pr.AssetListPageMessage {
				assets         = rows[:end - start],
				full_content   = req.full_content,
				has_more       = end < count,
				total_count    = u32(count),
				correlation_id = req.correlation_id,
			}
			if pr.serializeAssetListPageMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		} else {
			rows: [pr.MAX_ID_BATCH_SIZE]pr.Task
			for i in start ..< end {
				task, found, read_rc := db.get_task(store, request.workspace, 0, selected[i], max_bytes = 2 * pr.MAX_PROTOCOL_PAYLOAD_SIZE)
				if read_rc != sql.OK do return read_rc
				if !found do return sql.CORRUPT
				rows[i - start] = task
			}
			msg := pr.TaskListPage {
				success        = true,
				tasks          = rows[:end - start],
				has_more       = end < count,
				total_count    = u32(count),
				correlation_id = req.correlation_id,
			}
			if pr.serializeTaskListPage(msg, buf) != len(buf) do return sql.CONSTRAINT
		}
		if end == count do return sql.OK
		start = end
	}
}
