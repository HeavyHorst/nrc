package main

import "core:c"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// The creator borrows the statement until its next step/finalize.
sqlite_edge_row :: proc(s: ^sql.Statement) -> (e: pr.Edge, rc: c.int) {
	e.edge_id, rc = sql.column_id(s, 0); if rc != sql.OK do return
	e.source_type = pr.TargetType(sql.column_int64(s, 1))
	e.source_id, rc = sql.column_id(s, 2); if rc != sql.OK do return
	e.target_type = pr.TargetType(sql.column_int64(s, 3))
	e.target_id, rc = sql.column_id(s, 4); if rc != sql.OK do return
	e.relation = pr.RelationType(sql.column_int64(s, 5))
	e.created_at = sql.column_int64(s, 6)
	e.created_by = sql.column_bytes_view(s, 7)
	if len(e.created_by) > 65535 do return e, sql.TOOBIG
	return e, sql.OK
}

sqlite_execute_edges :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output, transaction_batch := false, created_id: u64 = 0) -> c.int {
	if request.opcode != .C_CreateEdge && request.opcode != .C_DeleteEdge do return sqlite_list_edges(store, request, output)
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	creating := request.opcode == .C_CreateEdge
	e: pr.Edge
	correlation: u32
	error_text := ""
	rc := sql.OK
	if creating {
		req, err := pr.parseCreateEdgeRequest(request.body)
		if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
		correlation = req.correlation_id
		e = {
			source_type = req.source_type,
			source_id   = req.source_id,
			target_type = req.target_type,
			target_id   = req.target_id,
			relation    = req.relation,
			created_at  = request.timestamp,
			created_by  = transmute([]byte)request.actor,
		}
		if e.relation < min(pr.RelationType) || e.relation > max(pr.RelationType) {
			error_text = "Invalid edge relation"
		} else {
			personal := false
			for endpoint, i in ([2]struct {
					kind: pr.TargetType,
					id:   u64,
				}{{e.source_type, e.source_id}, {e.target_type, e.target_id}}) {
				found := false
				if endpoint.kind == .Task {
					kind: u16
					found, rc = sqlite_history_available(store, request.workspace, request.actor, 1, endpoint.id, &kind)
				} else if endpoint.kind == .Asset {
					a: pr.Asset
					a, found, rc = sqlite_read_asset(store, request.workspace, request.actor, endpoint.id, false)
					if found && reminder_is_personal(&a) do personal = true
				}
				if rc != sql.OK do return rc
				if !found {error_text = i == 0 ? "Edge source entity not found" : "Edge target entity not found"; break}
			}
			if error_text == "" && personal do error_text = "Personal reminders cannot have shared relations"
			if error_text == "" && e.source_type == e.target_type && e.source_id == e.target_id do error_text = "Self-edge not allowed"
		}
		if error_text == "" && e.relation == .MemberOf {
			s: ^sql.Statement
			rc = sql.prepare_v2(
				store.db,
				`SELECT 1 FROM edges INDEXED BY edges_source WHERE workspace=?1 AND relation=?6
 AND source_type=?2 AND source_id=?3 AND target_type=?4 AND target_id=?5
 UNION ALL SELECT 1 FROM edges INDEXED BY edges_target WHERE workspace=?1 AND relation=?6
 AND target_type=?2 AND target_id=?3 AND source_type=?4 AND source_id=?5 LIMIT 1`,
				-1,
				&s,
				nil,
			)
			if rc != sql.OK do return rc
			defer sql.finalize(s)
			if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
			if rc = sql.bind_int64(s, 2, i64(e.source_type)); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 3, e.source_id); rc != sql.OK do return rc
			if rc = sql.bind_int64(s, 4, i64(e.target_type)); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 5, e.target_id); rc != sql.OK do return rc
			if rc = sql.bind_int64(s, 6, i64(e.relation)); rc != sql.OK do return rc
			rc = sql.step(s)
			if rc != sql.ROW && rc != sql.DONE do return rc
			if rc == sql.ROW do error_text = "Member is already assigned to this slice"
		}
	} else {
		req, err := pr.parseDeleteEdgeRequest(request.body)
		if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
		correlation = req.correlation_id
		s: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			"SELECT id,source_type,source_id,target_type,target_id,relation,created_at,created_by FROM edges WHERE workspace=?1 AND id=?2",
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, req.edge_id); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc == sql.DONE {error_text = "Edge not found"} else if rc != sql.ROW {return rc} else {
			e, rc = sqlite_edge_row(s); if rc != sql.OK do return rc
			// Deletion/history need endpoint identities, not the borrowed creator.
			e.created_by = nil
		}
	}
	if error_text != "" {
		if transaction_batch do return sql.CONSTRAINT
		context.allocator = backing
		return sqlite_command_error(output, request.opcode, correlation, error_text)
	}
	if creating {
		e.edge_id = created_id
		if !transaction_batch {e.edge_id, rc = db.next_id(store, .Edge); if rc != sql.OK do return rc}
		key := pr.Asset {
			asset_id = e.edge_id,
		}
		rc = sqlite_projection_write(
			store,
			"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
			request.workspace,
			&key,
			{i64(e.source_type), u64(e.source_id), i64(e.target_type), u64(e.target_id), i64(e.relation), e.created_at, string(e.created_by)},
		)
		if rc != sql.OK do return rc
	} else {
		key := pr.Asset {
			asset_id = e.edge_id,
		}
		if rc = sqlite_projection_write(store, "DELETE FROM edges WHERE workspace=?1 AND id=?2", request.workspace, &key, nil); rc != sql.OK do return rc
	}
	if rc = sqlite_edge_history(store, request, e, creating); rc != sql.OK do return rc
	context.allocator = backing
	for audience in ([2]db.Command_Audience{.Requester, .Other_Subscribers}) {
		if transaction_batch && audience == .Requester do continue
		corr := audience == .Requester ? correlation : 0
		if creating {
			msg := pr.EdgeCreatedMessage {
				edge           = e,
				correlation_id = corr,
			}
			buf, frame_rc := db.command_frame(output, pr.getSizeEdgeCreatedMessage(msg), audience); if frame_rc != sql.OK do return frame_rc
			if pr.serializeEdgeCreatedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		} else {
			msg := pr.EdgeDeletedMessage {
				edge_id        = e.edge_id,
				correlation_id = corr,
			}
			buf, frame_rc := db.command_frame(output, pr.getSizeEdgeDeletedMessage(msg), audience); if frame_rc != sql.OK do return frame_rc
			if pr.serializeEdgeDeletedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
		}
	}
	return sql.OK
}

sqlite_list_edges :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	incident := request.opcode == .C_ListEdges || request.opcode == .C_ListEdgesPaged
	paged := request.opcode == .C_ListAllEdgesPaged || request.opcode == .C_ListEdgesPaged
	target_type: pr.TargetType
	target_id, after: u64
	correlation: u32
	limit := 65535
	#partial switch request.opcode {
	case .C_ListEdges:
		r, err := pr.parseListEdgesRequest(request.body); if err != nil || r.conv_id != 0 do return sql.CONSTRAINT
		target_type = r.target_type; target_id = r.target_id; correlation = r.correlation_id
	case .C_ListEdgesPaged:
		r, err := pr.parseListEdgesPagedRequest(request.body); if err != nil || r.conv_id != 0 do return sql.CONSTRAINT
		target_type = r.target_type; target_id = r.target_id; correlation = r.correlation_id; after = r.after_edge_id
		limit = r.limit == 0 ? CUSTOMER_READ_DEFAULT_LIMIT : min(int(r.limit), CUSTOMER_READ_MAX_LIMIT)
	case .C_ListAllEdges:
		r, err := pr.parseListAllEdgesRequest(request.body); if err != nil || r.conv_id != 0 do return sql.CONSTRAINT
		correlation = r.correlation_id
	case .C_ListAllEdgesPaged:
		r, err := pr.parseListAllEdgesPagedRequest(request.body); if err != nil || r.conv_id != 0 do return sql.CONSTRAINT
		correlation = r.correlation_id; after = r.after_edge_id
		limit = r.limit == 0 ? DEFAULT_EDGE_PAGE_LIMIT : min(int(r.limit), MAX_EDGE_PAGE_LIMIT)
	case:
		return sql.MISUSE
	}
	page := pr.AllEdgeListPageMessage {
		correlation_id = correlation,
	}
	if paged {
		query: cstring = "SELECT count(*) FROM edges WHERE workspace=?1"
		if incident do query = `SELECT
 (SELECT count(*) FROM edges WHERE workspace=?1 AND source_type=?2 AND source_id=?3) +
 (SELECT count(*) FROM edges WHERE workspace=?1 AND target_type=?2 AND target_id=?3 AND NOT(source_type=?2 AND source_id=?3))`
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, query, -1, &s, nil); if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if incident {
			if rc = sql.bind_int64(s, 2, i64(target_type)); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 3, target_id); rc != sql.OK do return rc
		}
		if rc = sql.step(s); rc != sql.ROW do return rc
		total := sql.column_int64(s, 0); if total > i64(max(u32)) do return sql.TOOBIG
		page.total_count = u32(total)
	}
	size := paged ? pr.getSizeAllEdgeListPageMessage(page) : pr.getSizeAllEdgeListMessage({})
	if incident do size = paged ? pr.getSizeEdgeListPageMessage({}) : pr.getSizeEdgeListMessage({})
	byte_limit := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	limit = min(limit, max(0, (byte_limit - size) / pr.getSizeEdge({})))
	query: cstring = `SELECT id,source_type,source_id,target_type,target_id,relation,created_at,created_by
 FROM edges WHERE workspace=?1 AND id>?2 ORDER BY id LIMIT ?5`
	// Each endpoint index contributes only a bounded page. UNION removes a
	// legacy self-edge once; the outer sort sees at most two pages, not the graph.
	if incident do query = `SELECT id,source_type,source_id,target_type,target_id,relation,created_at,created_by
 FROM edges WHERE workspace=?1 AND id IN (
 SELECT id FROM (SELECT id FROM edges INDEXED BY edges_source_page WHERE workspace=?1 AND source_type=?3 AND source_id=?4 AND id>?2 ORDER BY id LIMIT ?5)
 UNION SELECT id FROM (SELECT id FROM edges INDEXED BY edges_target_page WHERE workspace=?1 AND target_type=?3 AND target_id=?4 AND id>?2 ORDER BY id LIMIT ?5)
 ) ORDER BY id LIMIT ?5`
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &s, nil); if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, after); rc != sql.OK do return rc
	if incident {
		if rc = sql.bind_int64(s, 3, i64(target_type)); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 4, target_id); rc != sql.OK do return rc
	}
	if rc = sql.bind_int64(s, 5, i64(limit) + 1); rc != sql.OK do return rc
	edges := make([dynamic]pr.Edge, 0, limit)
	defer {for e in edges do delete(e.created_by); delete(edges)}
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		e, row_rc := sqlite_edge_row(s); if row_rc != sql.OK do return row_rc
		if len(edges) == limit || pr.getSizeEdge(e) > byte_limit - size {
			if !paged do return sqlite_command_error(output, request.opcode, correlation, "Edge list too large; use ListAllEdgesPaged")
			if len(edges) == 0 do return sqlite_command_error(output, request.opcode, correlation, "Edge exceeds page byte limit")
			page.has_more = true; break
		}
		e.created_by = transmute([]byte)strings.clone(string(e.created_by))
		append(&edges, e); size += pr.getSizeEdge(e); page.next_edge_id = e.edge_id
	}
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	written: int
	if incident && paged {
		written = pr.serializeEdgeListPageMessage(
			{
				target_type = target_type,
				target_id = target_id,
				edges = edges[:],
				has_more = page.has_more,
				next_edge_id = page.next_edge_id,
				total_count = page.total_count,
				correlation_id = correlation,
			},
			buf,
		)
	} else if incident {
		written = pr.serializeEdgeListMessage({target_type = target_type, target_id = target_id, edges = edges[:], correlation_id = correlation}, buf)
	} else if paged {
		page.edges = edges[:]; written = pr.serializeAllEdgeListPageMessage(page, buf)
	} else {
		written = pr.serializeAllEdgeListMessage({edges = edges[:], correlation_id = correlation}, buf)
	}
	return written == len(buf) ? sql.OK : sql.CONSTRAINT
}
