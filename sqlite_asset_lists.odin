package main

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_list_assets :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	paged := request.opcode != .C_ListAssets
	req: pr.ListAssetsPagedRequest
	filter := ""
	filter_type := true
	#partial switch request.opcode {
	case .C_ListAssets:
		r, err := pr.parseListAssetsRequest(request.body)
		if err != nil do return sql.CONSTRAINT
		req.conv_id = r.conv_id; req.asset_type = r.asset_type; req.full_content = r.full_content; req.correlation_id = r.correlation_id
		filter_type = r.filter_by_type
	case .C_ListAssetsPaged:
		err: pr.ProtocolParseError
		req, err = pr.parseListAssetsPagedRequest(request.body)
		if err != nil do return sql.CONSTRAINT
	case .C_ListAssetsPagedByProject:
		r, err := pr.parseListAssetsPagedByProjectRequest(request.body)
		if err != nil do return sql.CONSTRAINT
		req = {
			conv_id           = r.conv_id,
			asset_type        = r.asset_type,
			full_content      = r.full_content,
			limit             = r.limit,
			has_cursor        = r.has_cursor,
			cursor_updated_at = r.cursor_updated_at,
			cursor_asset_id   = r.cursor_asset_id,
			correlation_id    = r.correlation_id,
		}
		filter = r.project
	case .C_ListAssetsPagedByTag:
		r, err := pr.parseListAssetsPagedByTagRequest(request.body)
		if err != nil do return sql.CONSTRAINT
		req = {
			conv_id           = r.conv_id,
			asset_type        = r.asset_type,
			full_content      = r.full_content,
			limit             = r.limit,
			has_cursor        = r.has_cursor,
			cursor_updated_at = r.cursor_updated_at,
			cursor_asset_id   = r.cursor_asset_id,
			correlation_id    = r.correlation_id,
		}
		filter = r.tag
	case:
		return sql.MISUSE
	}
	if req.conv_id != 0 do return sql.CONSTRAINT
	if paged && (req.asset_type < min(pr.AssetType) || req.asset_type > max(pr.AssetType)) do return sql.CONSTRAINT
	if req.limit == 0 do req.limit = DEFAULT_ASSET_PAGE_LIMIT
	req.limit = min(req.limit, MAX_ASSET_PAGE_LIMIT)
	page := pr.AssetListPageMessage {
		full_content   = req.full_content,
		correlation_id = req.correlation_id,
	}
	list := pr.AssetListMessage {
		full_content   = req.full_content,
		correlation_id = req.correlation_id,
	}
	size := paged ? pr.getSizeAssetListPageMessage(page) : pr.getSizeAssetListMessage(list)
	byte_limit := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	if size > byte_limit do return sql.TOOBIG
	// The typed index streams in cursor order. Untyped legacy lists have no
	// ordering contract; use primary-key order instead of sorting all assets.
	query: cstring = "SELECT id,updated_at,asset_type,owner,preview FROM assets WHERE workspace=?1 ORDER BY id"
	if filter_type do query = "SELECT id,updated_at,asset_type,owner,preview FROM assets INDEXED BY assets_type_updated WHERE workspace=?1 AND asset_type=?2 ORDER BY updated_at DESC,id DESC"
	if request.opcode == .C_ListAssetsPagedByProject do query = `SELECT a.id,a.updated_at,a.asset_type,a.owner,a.preview FROM note_metadata m INDEXED BY note_project_order
 JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id
 WHERE m.workspace=?1 AND m.project=?3 AND a.asset_type=?2
 ORDER BY m.updated_at DESC,m.asset_id DESC`
	if request.opcode == .C_ListAssetsPagedByTag do query = `SELECT a.id,a.updated_at,a.asset_type,a.owner,a.preview FROM note_tags m INDEXED BY note_tag_order
 JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id
 WHERE m.workspace=?1 AND m.tag=?3 AND a.asset_type=?2
 ORDER BY m.updated_at DESC,m.asset_id DESC`
	// Notes have no per-record visibility filter. Count index entries in this
	// snapshot, then seek only the requested page; never load every preview.
	note_page := paged && req.asset_type == .Note
	owned_query: cstring
	defer if owned_query != nil do delete(owned_query)
	if note_page {
		source := "SELECT id,updated_at FROM assets WHERE workspace=?1 AND asset_type=?2"
		if request.opcode == .C_ListAssetsPagedByProject do source = "SELECT asset_id AS id,updated_at FROM note_metadata WHERE workspace=?1 AND project=?3"
		if request.opcode == .C_ListAssetsPagedByTag do source = "SELECT asset_id AS id,updated_at FROM note_tags WHERE workspace=?1 AND tag=?3"
		count_text := fmt.aprintf("SELECT count(*) FROM (%s)", source); defer delete(count_text)
		count_query := strings.clone_to_cstring(count_text); defer delete(count_query)
		count: ^sql.Statement
		rc := sql.prepare_v2(store.db, count_query, -1, &count, nil); if rc != sql.OK do return rc
		defer sql.finalize(count)
		if rc = sql.bind_bytes(count, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if request.opcode == .C_ListAssetsPaged {
			if rc = sql.bind_int64(count, 2, i64(req.asset_type)); rc != sql.OK do return rc
		} else {
			if rc = sql.bind_bytes(count, 3, transmute([]byte)filter); rc != sql.OK do return rc
		}
		if rc = sql.step(count); rc != sql.ROW do return rc
		total := sql.column_int64(count, 0); if total > i64(max(u32)) do return sql.TOOBIG
		page.total_count = u32(total)
		page_text := fmt.aprintf(
			"SELECT id,updated_at,%d,x'',x'' FROM (%s)%s ORDER BY updated_at DESC,id DESC LIMIT ?6",
			int(pr.AssetType.Note),
			source,
			req.has_cursor ? " WHERE (updated_at,id)<(?4,?5) AND id!=?5" : "",
		); defer delete(page_text)
		owned_query = strings.clone_to_cstring(page_text)
		query = owned_query
	}
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &s, nil); if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if filter_type {if rc = sql.bind_int64(s, 2, i64(req.asset_type)); rc != sql.OK do return rc}
	if request.opcode == .C_ListAssetsPagedByProject || request.opcode == .C_ListAssetsPagedByTag {
		if rc = sql.bind_bytes(s, 3, transmute([]byte)filter); rc != sql.OK do return rc
	}
	if note_page {
		if req.has_cursor {
			if rc = sql.bind_int64(s, 4, req.cursor_updated_at); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 5, req.cursor_asset_id); rc != sql.OK do return rc
		}
		if rc = sql.bind_int64(s, 6, i64(req.limit) + 1); rc != sql.OK do return rc
	}
	ids := make([dynamic]u64); defer delete(ids)
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	// Other asset lists still count through the parser-based ACL/filter.
	// Note totals were counted above; only their bounded page is visited here.
	for {
		virtual.arena_free_all(&arena)
		if note_page && page.has_more do break
		rc = sql.step(s)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		a := pr.Asset {
			asset_id   = id,
			updated_at = sql.column_int64(s, 1),
			asset_type = pr.AssetType(sql.column_int64(s, 2)),
			owner      = sql.column_bytes_view(s, 3),
			preview    = sql.column_bytes_view(s, 4),
		}
		if !asset_visible_to(&a, request.actor) do continue
		if req.active_contacts_only && req.asset_type != .Note && !customer_preview_is_active_contact(a.preview, context.allocator) do continue
		if !note_page {
			if page.total_count == max(u32) do return sql.TOOBIG
			page.total_count += 1
		}
		if req.has_cursor && req.asset_type == .Note && id == req.cursor_asset_id do continue
		if req.has_cursor && !is_note_after_cursor_desc({a.updated_at, id}, req.cursor_updated_at, req.cursor_asset_id) do continue
		if page.has_more do continue
		if paged && len(ids) == int(req.limit) {page.has_more = true; continue}
		row, found, read_rc := sqlite_read_asset(store, request.workspace, request.actor, id, req.full_content)
		if read_rc != sql.OK do return read_rc
		if !found do return sql.CORRUPT
		row_size := req.full_content ? pr.getSizeAsset(row) : pr.getSizeAssetHeader(row)
		if row_size > byte_limit - size {
			if !paged || len(ids) == 0 do return sql.TOOBIG
			page.has_more = true; continue
		}
		context.allocator = backing
		_, alloc_err := append(&ids, id)
		context.allocator = virtual.arena_allocator(&arena)
		if alloc_err != nil do return sql.NOMEM
		size += row_size
		page.next_cursor_updated_at = row.updated_at; page.next_cursor_asset_id = id
	}
	virtual.arena_free_all(&arena)
	rows := make([]pr.Asset, len(ids))
	for id, i in ids {
		found: bool
		rows[i], found, rc = sqlite_read_asset(store, request.workspace, request.actor, id, req.full_content)
		if rc != sql.OK do return rc
		if !found do return sql.CORRUPT
	}
	context.allocator = backing
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	if paged {page.assets = rows; return pr.serializeAssetListPageMessage(page, buf) == size ? sql.OK : sql.CONSTRAINT}
	list.assets = rows
	return pr.serializeAssetListMessage(list, buf) == size ? sql.OK : sql.CONSTRAINT
}

sqlite_list_note_facets :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseListNoteProjectsRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	query: cstring = "SELECT DISTINCT project FROM note_metadata INDEXED BY note_project_order WHERE workspace=?1 AND project>x'' ORDER BY project"
	opcode := pr.Opcode.S_NoteProjectList
	if request.opcode == .C_ListNoteTags {
		query = "SELECT DISTINCT tag FROM note_tags INDEXED BY note_tag_order WHERE workspace=?1 AND tag>x'' ORDER BY tag"
		opcode = .S_NoteTagList
	}
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &s, nil); if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	// This protocol has no continuation flag. Count bytes in the same snapshot,
	// then encode straight into one admitted frame without retaining all names.
	size, count := 16, 0
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		length := len(sql.column_bytes_view(s, 0))
		if length > int(max(u16)) || count == int(max(u16)) || length + 2 > pr.MAX_PROTOCOL_PAYLOAD_SIZE - size do return sql.TOOBIG
		size += 2 + length; count += 1
	}
	if rc = sql.reset(s); rc != sql.OK do return rc
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	endian.put_u16(buf, .Big, u16(opcode))
	endian.put_u64(buf[2:], .Big, 0)
	endian.put_u16(buf[10:], .Big, u16(count))
	endian.put_u32(buf[12:], .Big, req.correlation_id)
	pos := 16
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		name := sql.column_bytes_view(s, 0)
		endian.put_u16(buf[pos:], .Big, u16(len(name))); pos += 2
		copy(buf[pos:], name); pos += len(name)
	}
	return pos == size ? sql.OK : sql.CORRUPT
}
