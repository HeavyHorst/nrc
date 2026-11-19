package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

worker_db_submit_tickets :: proc(c: ^NRC_Connection, body: []byte, req: pr.TicketQueryRequest) {
	if !c.authenticated {send_error_response(c, .C_QueryTickets, "Access denied", req.correlation_id); return}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {send_error_response(c, .C_QueryTickets, "Ticket query allocation failed", req.correlation_id); return}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	q, error := parse_ticket_query(req.query, a)
	if error != "" {send_error_response(c, .C_QueryTickets, error, req.correlation_id); return}
	request := db.Request {
		operation = .Command,
		shard     = int(shard_for_workspace(transmute([]byte)c.workspace_id)),
		opcode    = .C_QueryTickets,
		body      = body,
		timestamp = nrc_time_unix_nanos(),
	}
	if q.mode == "read" {
		if q.read_snapshot == 0 || (!q.read_start && c.ticket_read_upload != q.read_snapshot) {
			send_error_response(c, .C_QueryTickets, "Invalid ticket read upload", req.correlation_id); return
		}
		request.read_generation = c.ticket_read_generation
		if q.read_start {
			if request.read_generation == max(u64) {send_error_response(c, .C_QueryTickets, "Invalid ticket read upload", req.correlation_id); return}
			request.read_generation += 1
		}
		request.ticket_reads = make([]db.Ticket_Read_Cursor, len(q.read), a)
		i := 0
		for key, value in q.read {
			id, id_ok := strconv.parse_u64(key); through, through_ok := strconv.parse_u64(value)
			if !id_ok || !through_ok {send_error_response(c, .C_QueryTickets, "Invalid ticket read cursor", req.correlation_id); return}
			request.ticket_reads[i] = {id, through}; i += 1
		}
	} else if q.read_snapshot != 0 {
		if q.read_snapshot != c.ticket_read_snapshot {send_error_response(c, .C_QueryTickets, "Ticket read snapshot unavailable", req.correlation_id); return}
		request.ticket_reads = make([]db.Ticket_Read_Cursor, len(c.ticket_read_cursors), a)
		i := 0; for id, through in c.ticket_read_cursors {request.ticket_reads[i] = {u64(id), u64(through)}; i += 1}
	}
	admission_error: string
	if !worker_db_submit(
		c,
		request,
		req.correlation_id,
		worker_db_complete_tickets,
		&admission_error,
	) {send_error_response(c, .C_QueryTickets, admission_error, req.correlation_id); return}
	if q.mode == "read" && q.read_start {
		if c.ticket_read_cursors == nil do c.ticket_read_cursors = make(map[pr.AssetID]pr.AssetID)
		clear(&c.ticket_read_cursors)
		c.ticket_read_snapshot = 0; c.ticket_read_upload = q.read_snapshot; c.ticket_read_generation = request.read_generation
	}
}

worker_db_complete_tickets :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	if c == nil do return
	if job.request.read_generation != 0 {
		if job.request.read_generation != c.ticket_read_generation || c.ticket_read_upload == 0 {
			send_error_response(c, .C_QueryTickets, "Ticket read upload superseded", correlation); return
		}
		if job.result.status == sql.OK {
			arena: virtual.Arena
			if virtual.arena_init_growing(&arena) !=
			   nil {c.ticket_read_upload = 0; send_error_response(c, .C_QueryTickets, "Ticket query allocation failed", correlation); return}
			defer virtual.arena_destroy(&arena)
			req, _ := pr.parseTicketQueryRequest(job.request.body)
			q, _ := parse_ticket_query(req.query, virtual.arena_allocator(&arena))
			for read in job.result.command.ticket_reads do c.ticket_read_cursors[pr.AssetID(read.id)] = pr.AssetID(read.through)
			if q.read_end {c.ticket_read_snapshot = q.read_snapshot; c.ticket_read_upload = 0}
		} else {
			// A failed chunk cannot later be certified by an already queued end.
			c.ticket_read_snapshot = 0; c.ticket_read_upload = 0
		}
	}
	worker_db_complete_command(c, correlation, job)
}

sqlite_ticket_upload :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	// Return only still-existing canonical tickets, matching legacy upload pruning.
	if len(request.ticket_reads) > (output.limit - output.bytes) / size_of(db.Ticket_Read_Cursor) do return sql.TOOBIG
	output.ticket_reads = make([]db.Ticket_Read_Cursor, len(request.ticket_reads))
	output.bytes += len(output.ticket_reads) * size_of(db.Ticket_Read_Cursor)
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, "SELECT 1 FROM assets WHERE workspace=?1 AND id=?2 AND asset_type=?3", -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 3, i64(pr.AssetType.Ticket)); rc != sql.OK do return rc
	count := 0
	for read in request.ticket_reads {
		if rc = sql.bind_id(s, 2, read.id); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc != sql.ROW && rc != sql.DONE do return rc
		if rc == sql.ROW {output.ticket_reads[count] = read; count += 1}
		if rc = sql.reset(s); rc != sql.OK do return rc
	}
	output.ticket_reads = output.ticket_reads[:count]
	return sql.OK
}

sqlite_bind_ticket_filters :: proc(s: ^sql.Statement, q: Ticket_Query, now: i64) -> c.int {
	for value, i in ([4]string{q.status, q.assignee, q.company, q.priority}) {
		if value == "" do continue
		if rc := sql.bind_bytes(s, c.int(5 + i), transmute([]byte)value); rc != sql.OK do return rc
	}
	if q.follow_up == "due" do return sql.bind_int64(s, 9, now / 1_000_000)
	return sql.OK
}

TICKET_FTS_NUL :: "\uE000"

// Search the projected fields and canonical bodies without hydrating every
// ticket. Only matching IDs survive this pass, in request-local SQLite storage.
sqlite_ticket_search_ids :: proc(store: ^db.Store, request: ^db.Request, source: cstring, q: Ticket_Query) -> c.int {
	query := strings.to_lower(strings.trim_space(q.search)); defer delete(query)
	// MATCH needs at least three Unicode code points. Quote the entire term
	// (including embedded quotes) so FTS operators remain literal substrings.
	if strings.rune_count(query) >= 3 && !strings.contains(query, "\x00") && !strings.contains(query, TICKET_FTS_NUL) {
		pending: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT 1 FROM ticket_search_backfill", -1, &pending, nil); if rc != sql.OK do return rc
		defer sql.finalize(pending)
		rc = sql.step(pending)
		if rc == sql.DONE {
			hits: ^sql.Statement
			rc = sql.prepare_v2(
				store.db,
				`INSERT OR IGNORE INTO temp.nrc_ticket_hits
 SELECT d.ticket_id FROM ticket_trigrams CROSS JOIN ticket_search_docs d ON d.docid=ticket_trigrams.rowid
 WHERE ticket_trigrams MATCH ('"'||replace(CAST(?2 AS TEXT),'"','""')||'"') AND d.workspace=?1`,
				-1,
				&hits,
				nil,
			)
			if rc != sql.OK do return rc
			defer sql.finalize(hits)
			if rc = sql.bind_bytes(hits, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
			if rc = sql.bind_bytes(hits, 2, transmute([]byte)query); rc != sql.OK do return rc
			rc = sql.step(hits); return rc == sql.DONE ? sql.OK : rc
		}
		if rc != sql.ROW do return rc
	}
	rows, entries, insert: ^sql.Statement
	rc := sql.prepare_v2(store.db, source, -1, &rows, nil); if rc != sql.OK do return rc
	defer sql.finalize(rows)
	if rc = sql.bind_bytes(rows, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sqlite_bind_ticket_filters(rows, q, request.timestamp); rc != sql.OK do return rc
	rc = sql.prepare_v2(
		store.db,
		`SELECT a.payload_encoding,a.payload_raw_len,a.payload FROM ticket_entry_metadata e
 CROSS JOIN assets a ON a.workspace=e.workspace AND a.id=e.asset_id WHERE e.workspace=?1 AND e.ticket_id=?2`,
		-1,
		&entries,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(entries)
	if rc = sql.bind_bytes(entries, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	rc = sql.prepare_v2(store.db, "INSERT INTO temp.nrc_ticket_hits VALUES(?1)", -1, &insert, nil); if rc != sql.OK do return rc
	defer sql.finalize(insert)
	body_matches :: proc(s: ^sql.Statement, col: c.int, query: string) -> bool {
		asset := pr.Asset {
			payload_encoding = pr.PayloadEncoding(sql.column_int64(s, col)),
			payload_raw_len  = u32(sql.column_int64(s, col + 1)),
			payload          = sql.column_bytes_view(s, col + 2),
		}
		return ticket_body_matches(&asset, query)
	}
	for {
		rc = sql.step(rows); if rc == sql.DONE do return sql.OK
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(rows, 0); if id_rc != sql.OK do return id_rc
		fields := fmt.aprint(
			string(sql.column_bytes_view(rows, 1)),
			"\n",
			string(sql.column_bytes_view(rows, 2)),
			"\n",
			string(sql.column_bytes_view(rows, 3)),
			"\n#",
			id,
		)
		lower := strings.to_lower(fields); matched := strings.contains(lower, query); delete(lower); delete(fields)
		if !matched do matched = body_matches(rows, 4, query)
		if !matched {
			if rc = sql.bind_id(entries, 2, id); rc != sql.OK do return rc
			for {
				rc = sql.step(entries); if rc == sql.DONE do break
				if rc != sql.ROW do return rc
				if body_matches(entries, 0, query) {matched = true; break}
			}
			if rc = sql.reset(entries); rc != sql.OK do return rc
		}
		if !matched do continue
		if rc = sql.bind_id(insert, 1, id); rc != sql.OK do return rc
		if rc = sql.step(insert); rc != sql.DONE do return rc
		if rc = sql.reset(insert); rc != sql.OK do return rc
	}
}

// One candidate's canonical data and decoded text live only in this arena.
// The returned values are inserted into SQLite before the arena is destroyed.
sqlite_ticket_candidate :: proc(store: ^db.Store, request: ^db.Request, q: Ticket_Query, id: u64, insert: ^sql.Statement, accepted: ^bool) -> c.int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	asset, found, rc := sqlite_read_asset(store, request.workspace, request.actor, id, false)
	if rc != sql.OK do return rc
	if !found do return sql.CORRUPT
	m, valid := parse_ticket_preview(asset.preview, context.allocator)
	if !valid do return sql.OK
	if m.priority == "" do m.priority = "normal"
	now_ms := request.timestamp / 1_000_000
	follow_up, valid_follow_up := ticket_follow_up_time(m.follow_up_at)
	if q.priority != "" && m.priority != q.priority do return sql.OK
	if q.follow_up == "due" && (!valid_follow_up || follow_up <= 0 || follow_up > now_ms) do return sql.OK
	if q.status != "" && m.status != q.status || q.assignee != "" && m.assignee != q.assignee || q.company != "" && m.company_id != q.company do return sql.OK
	if q.mode == "attention" && m.assignee != "" && m.assignee != request.actor do return sql.OK
	if q.search_results {
		selected := false
		for value in q.ids {n, _ := strconv.parse_u64(value); if n == id {selected = true; break}}
		if !selected do return sql.OK
	}
	s: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT
 coalesce((SELECT through FROM temp.nrc_ticket_reads WHERE id=?2),x'0000000000000000'),
 coalesce(max(created_at),?3),
 coalesce(max(CASE WHEN kind=x'637573746f6d65725f7265706c79' THEN asset_id END),x'0000000000000000'),
 coalesce(max(CASE WHEN kind=x'7075626c69635f7265706c79' THEN asset_id END),x'0000000000000000'),
 coalesce(sum(kind=x'637573746f6d65725f7265706c79' AND asset_id>coalesce((SELECT through FROM temp.nrc_ticket_reads WHERE id=?2),x'0000000000000000')),0)
 FROM ticket_entry_metadata INDEXED BY ticket_entry_time WHERE workspace=?1 AND ticket_id=?2`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, id); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 3, asset.created_at); rc != sql.OK do return rc
	if rc = sql.step(s); rc != sql.ROW do return rc
	read, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
	latest, latest_rc := sql.column_id(s, 2); if latest_rc != sql.OK do return latest_rc
	reply, reply_rc := sql.column_id(s, 3); if reply_rc != sql.OK do return reply_rc
	latest = max(latest, id); timestamp := max(asset.created_at, sql.column_int64(s, 1))
	unread := sql.column_int64(s, 4) + (id > read && string(asset.owner) != request.actor ? 1 : 0)
	paused := latest == id && (m.status == "waiting_customer" || m.status == "resolved" || m.status == "closed")
	waiting := reply <= latest && !paused
	due := valid_follow_up && follow_up > 0 && follow_up <= now_ms
	if q.mode == "attention" && !waiting && unread == 0 && !due do return sql.OK
	number: i64; text: string
	switch q.sort {
	case "id":
		number = i64(id) // Preserve the existing signed value cursor.
	case "unread":
		number = unread
	case "priority":
		switch m.priority {case "low":
			number = 0; case "normal":
			number = 1; case "high":
			number = 2; case "urgent":
			number = 3}
	case "follow_up_at":
		number = follow_up
	case "activity", "":
		number = timestamp
	case "title":
		text = m.title
	case "status":
		text = m.status
	case "assignee":
		text = m.assignee
	case "company_id", "contact_id":
		value := q.sort == "company_id" ? m.company_id : m.contact_id
		linked_id, _ := strconv.parse_u64(value)
		linked, present, linked_rc := sqlite_read_asset(store, request.workspace, request.actor, linked_id, false)
		if linked_rc != sql.OK do return linked_rc
		name: struct {
			title: string,
		}
		if present do _ = json.unmarshal(linked.preview, &name)
		text = name.title
		if text == "" && value != "" do text = fmt.aprint("#", value)
		if q.sort == "contact_id" && value == "" do text = m.requester_name != "" ? m.requester_name : m.requester
	}
	text = strings.to_lower(text)
	if rc = sql.bind_id(insert, 1, id); rc != sql.OK do return rc
	for value, i in ([4]i64{number, unread, waiting ? 1 : 0, due ? 1 : 0}) {if rc = sql.bind_int64(insert, c.int(i + 2), value); rc != sql.OK do return rc}
	for value, i in ([3]string{text, fmt.aprint(latest), fmt.aprint(timestamp)}) {if rc = sql.bind_bytes(insert, c.int(i + 6), transmute([]byte)value); rc != sql.OK do return rc}
	if rc = sql.step(insert); rc != sql.DONE do return rc
	accepted^ = true
	return sql.reset(insert)
}

sqlite_query_tickets :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseTicketQueryRequest(request.body); if err != nil do return sql.CONSTRAINT
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	q, error := parse_ticket_query(req.query, a)
	if error != "" do return sqlite_command_error(output, .C_QueryTickets, req.correlation_id, error)
	page: Ticket_Page_Metadata
	assets: [250]pr.Asset
	count := 0
	if q.mode == "read" {
		if rc := sqlite_ticket_upload(store, request, output); rc != sql.OK do return rc
	} else {
		defer sql.exec(
			store.db,
			"DROP TABLE IF EXISTS temp.nrc_ticket_candidates; DROP TABLE IF EXISTS temp.nrc_ticket_reads; DROP TABLE IF EXISTS temp.nrc_ticket_hits",
			nil,
			nil,
			nil,
		)
		rc := sql.exec(
			store.db,
			`CREATE TEMP TABLE nrc_ticket_reads(id BLOB PRIMARY KEY,through BLOB) WITHOUT ROWID;
 CREATE TEMP TABLE nrc_ticket_candidates(id BLOB PRIMARY KEY,number INTEGER,unread INTEGER,waiting INTEGER,due INTEGER,text BLOB,latest BLOB,timestamp BLOB) WITHOUT ROWID`,
			nil,
			nil,
			nil,
		)
		if rc != sql.OK do return rc
		reads: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			"INSERT INTO temp.nrc_ticket_reads VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET through=excluded.through",
			-1,
			&reads,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(reads)
		for read in request.ticket_reads {
			if rc = sql.bind_id(reads, 1, read.id); rc != sql.OK do return rc
			if rc = sql.bind_id(reads, 2, read.through); rc != sql.OK do return rc
			if rc = sql.step(reads); rc != sql.DONE do return rc
			if rc = sql.reset(reads); rc != sql.OK do return rc
		}
		// Apply projected filters before ranking. Text search and attention still
		// need bodies or per-actor reply state to decide which tickets qualify.
		title_key := q.sort == "title"
		ranked_page :=
			q.mode == "" &&
			!q.search_results &&
			(title_key ? q.cursor.number == "0" || q.cursor.number == "" : q.cursor.text == "" && (q.sort == "activity" || q.sort == "" || q.sort == "priority" || q.sort == "unread"))
		filter := "m.workspace=?1"
		if q.mode != "entries" {
			filter = fmt.aprintf(
				"%s%s%s%s%s%s",
				filter,
				q.status == "" ? "" : " AND m.status=?5",
				q.assignee == "" ? "" : " AND m.assignee=?6",
				q.company == "" ? "" : " AND m.company_id=?7",
				q.priority == "" ? "" : (q.priority == "normal" ? " AND m.priority IN (x'',?8)" : " AND m.priority=?8"),
				q.follow_up == "due" ? " AND m.follow_up_at>0 AND m.follow_up_at<=?9" : "",
				allocator = a,
			)
		}
		if q.mode != "entries" && q.search != "" {
			rc = sql.exec(store.db, "CREATE TEMP TABLE nrc_ticket_hits(id BLOB PRIMARY KEY) WITHOUT ROWID", nil, nil, nil)
			if rc != sql.OK do return rc
			source := fmt.aprintf(
				`SELECT m.asset_id,m.title,m.requester,m.requester_name,a.payload_encoding,a.payload_raw_len,a.payload
 FROM ticket_metadata m CROSS JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id WHERE %s`,
				filter,
				allocator = a,
			)
			if rc = sqlite_ticket_search_ids(store, request, strings.clone_to_cstring(source, a), q); rc != sql.OK do return rc
			filter = fmt.aprintf("%s AND m.asset_id IN (SELECT id FROM temp.nrc_ticket_hits)", filter, allocator = a)
		}
		direction := q.descending ? "DESC" : "ASC"; comparison := q.descending ? "<" : ">"
		cursor, _ := strconv.parse_u64(q.cursor.id); number, _ := strconv.parse_i64(q.cursor.number)
		limit := q.limit == 0 ? 50 : q.limit
		if q.mode == "entries" {
			parent, _ := strconv.parse_u64(q.parent)
			key := pr.Asset {
				asset_id = parent,
			}
			rc = sqlite_projection_write(
				store,
				`INSERT INTO temp.nrc_ticket_candidates SELECT id,created_at,0,0,0,x'',x'',x'' FROM assets
 WHERE workspace=?1 AND parent_id=?2 AND parent_type=?3 AND asset_type=?4`,
				request.workspace,
				&key,
				{i64(pr.ParentType.Asset), i64(pr.AssetType.TicketEntry)},
			)
			if rc != sql.OK do return rc
		} else {
			s: ^sql.Statement; insert: ^sql.Statement
			fast :=
				q.omit_total_count &&
				q.mode == "attention" &&
				q.sort == "id" &&
				q.descending &&
				(cursor == 0 || (number == i64(cursor) && q.cursor.text == ""))
			source: cstring
			if !ranked_page && !fast {
				if q.mode == "attention" do filter = fmt.aprintf("%s AND m.assignee IN (x'',?2)", filter, allocator = a)
				source = strings.clone_to_cstring(fmt.aprintf("SELECT m.asset_id FROM ticket_metadata m WHERE %s", filter, allocator = a), a)
			}
			if fast do source = `SELECT asset_id FROM ticket_metadata INDEXED BY ticket_assignee WHERE workspace=?1 AND assignee=?2 AND asset_id<=?3 AND asset_id>=?4
 UNION ALL SELECT asset_id FROM ticket_metadata INDEXED BY ticket_assignee WHERE workspace=?1 AND assignee=x'' AND ?2!=x'' AND asset_id<=?3 AND asset_id>=?4 ORDER BY asset_id DESC`
			if fast && q.search != "" do source = `SELECT h.id FROM temp.nrc_ticket_hits h CROSS JOIN ticket_metadata m
 WHERE h.id BETWEEN ?4 AND ?3 AND m.workspace=?1 AND m.asset_id=h.id AND m.assignee IN (x'',?2) ORDER BY h.id DESC`
			if ranked_page {
				join := " CROSS JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id"
				key := `max(a.created_at,coalesce((SELECT e.created_at FROM ticket_entry_metadata e
 WHERE e.workspace=m.workspace AND e.ticket_id=m.asset_id ORDER BY e.created_at DESC LIMIT 1),a.created_at))`
				switch q.sort {
				case "title":
					join = ""; key = "nrc_lower(m.title)"
				case "priority":
					join = ""; key = "CASE CAST(m.priority AS TEXT) WHEN '' THEN 1 WHEN 'normal' THEN 1 WHEN 'high' THEN 2 WHEN 'urgent' THEN 3 ELSE 0 END"
				case "unread":
					join = fmt.aprint(join, " LEFT JOIN temp.nrc_ticket_reads r ON r.id=m.asset_id", allocator = a)
					key = `((m.asset_id>coalesce(r.through,zeroblob(8)) AND a.owner!=?10) +
 (SELECT count(*) FROM ticket_entry_metadata e WHERE e.workspace=m.workspace AND e.ticket_id=m.asset_id
 AND e.kind=x'637573746f6d65725f7265706c79' AND e.asset_id>coalesce(r.through,zeroblob(8))))`
				}
				query := fmt.aprintf(
					`SELECT id FROM (SELECT m.asset_id id,%s sort_key FROM ticket_metadata m%s WHERE %s)
 WHERE ?2=zeroblob(8) OR sort_key%s?3 OR (sort_key=?3 AND id<?2)
 ORDER BY sort_key %s,id DESC LIMIT ?4`,
					key,
					join,
					filter,
					comparison,
					direction,
					allocator = a,
				)
				source = strings.clone_to_cstring(query, a)
			}
			rc = sql.prepare_v2(store.db, source, -1, &s, nil)
			if rc != sql.OK do return rc
			defer sql.finalize(s)
			if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
			if !fast {
				if rc = sqlite_bind_ticket_filters(s, q, request.timestamp); rc != sql.OK do return rc
			}
			if ranked_page {
				if rc = sql.bind_id(s, 2, cursor); rc != sql.OK do return rc
				if title_key {rc = sql.bind_bytes(s, 3, transmute([]byte)q.cursor.text)} else {rc = sql.bind_int64(s, 3, number)}
				if rc != sql.OK do return rc
				if q.sort == "unread" {if rc = sql.bind_bytes(s, 10, transmute([]byte)request.actor); rc != sql.OK do return rc}
				if rc = sql.bind_int64(s, 4, i64(limit + 1)); rc != sql.OK do return rc
			}
			if q.mode == "attention" {
				if rc = sql.bind_bytes(s, 2, transmute([]byte)request.actor); rc != sql.OK do return rc
			}
			rc = sql.prepare_v2(store.db, "INSERT INTO temp.nrc_ticket_candidates VALUES(?1,?2,?3,?4,?5,?6,?7,?8)", -1, &insert, nil)
			if rc != sql.OK do return rc
			defer sql.finalize(insert)
			matched := 0
			// The wire cursor orders IDs as signed numbers. Seek positive IDs
			// first, then negative IDs, retaining bounded unsigned index scans.
			for phase in 0 ..< (fast ? 2 : 1) {
				if fast {
					if phase == 0 && cursor != 0 && i64(cursor) < 0 do continue
					lower := phase == 0 ? u64(0) : u64(max(i64)) + 1
					upper := phase == 0 ? u64(max(i64)) : max(u64)
					if cursor != 0 && (phase == 0 || i64(cursor) < 0) do upper = cursor - 1
					if upper < lower do continue
					if rc = sql.bind_id(s, 3, upper); rc != sql.OK do return rc
					if rc = sql.bind_id(s, 4, lower); rc != sql.OK do return rc
				}
				for {
					rc = sql.step(s); if rc == sql.DONE do break
					if rc != sql.ROW do return rc
					id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
					accepted := false
					if rc = sqlite_ticket_candidate(store, request, q, id, insert, &accepted); rc != sql.OK do return rc
					if accepted do matched += 1
					if fast && matched > (q.limit == 0 ? 50 : q.limit) do break
				}
				if fast && matched > (q.limit == 0 ? 50 : q.limit) do break
				if rc = sql.reset(s); rc != sql.OK do return rc
			}
		}
		page.total_count_omitted = q.omit_total_count
		if !q.omit_total_count {
			s: ^sql.Statement
			count_sql: cstring = "SELECT count(*) FROM temp.nrc_ticket_candidates"
			if ranked_page do count_sql = strings.clone_to_cstring(fmt.aprintf("SELECT count(*) FROM ticket_metadata m WHERE %s", filter, allocator = a), a)
			rc = sql.prepare_v2(store.db, count_sql, -1, &s, nil); if rc != sql.OK do return rc
			defer sql.finalize(s)
			if ranked_page {
				if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
				if rc = sqlite_bind_ticket_filters(s, q, request.timestamp); rc != sql.OK do return rc
			}
			if rc = sql.step(s); rc != sql.ROW do return rc
			page.total_count = int(sql.column_int64(s, 0))
		}
		query := fmt.aprintf(
			`SELECT id,number,unread,waiting,due,text,latest,timestamp FROM temp.nrc_ticket_candidates
 WHERE ?1=x'0000000000000000' OR number%s?2 OR (number=?2 AND (text%s?3 OR (text=?3 AND id<?1)))
 ORDER BY number %s,text %s,id DESC LIMIT ?4`,
			comparison,
			comparison,
			direction,
			direction,
		)
		defer delete(query)
		text := strings.clone_to_cstring(query); defer delete(text)
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, text, -1, &s, nil); if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_id(s, 1, cursor); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 2, number); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 3, transmute([]byte)q.cursor.text); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 4, i64(limit) + 1); rc != sql.OK do return rc
		page.activity = make([dynamic]Ticket_Activity, 0, limit, a)
		budget := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - output.bytes - size_of(db.Command_Frame))
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			if count == limit {page.has_more = true; break}
			id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
			{
				context.allocator = a
				asset, found, read_rc := sqlite_read_asset(store, request.workspace, request.actor, id, q.mode == "entries")
				if read_rc != sql.OK do return read_rc
				if !found do return sql.CORRUPT
				assets[count] = asset
			}
			activity := Ticket_Activity {
				unread        = int(sql.column_int64(s, 2)),
				waiting       = sql.column_int64(s, 3) != 0,
				follow_up_due = sql.column_int64(s, 4) != 0,
				latest        = strings.clone(string(sql.column_bytes_view(s, 6)), a),
				timestamp     = strings.clone(string(sql.column_bytes_view(s, 7)), a),
			}
			previous := page.cursor
			page.cursor = {
				fmt.aprint(id, allocator = a),
				fmt.aprint(sql.column_int64(s, 1), allocator = a),
				strings.clone(string(sql.column_bytes_view(s, 5)), a),
			}
			append(&page.activity, activity)
			metadata, metadata_error := json.marshal(page)
			if metadata_error != nil do return sql.CONSTRAINT
			size := pr.getSizeTicketPage({metadata = metadata, assets = assets[:count + 1], full_content = q.mode == "entries"})
			delete(metadata)
			if size > budget {
				pop(&page.activity); page.cursor = previous; page.has_more = true
				if count == 0 do return sqlite_command_error(output, .C_QueryTickets, req.correlation_id, "Ticket exceeds page byte limit")
				break
			}
			count += 1
		}
	}
	if count == 0 do page.activity = nil
	metadata, encode_err := json.marshal(page, allocator = a); if encode_err != nil do return sql.CONSTRAINT
	msg := pr.TicketPage {
		correlation_id = req.correlation_id,
		metadata       = metadata,
		assets         = assets[:count],
		full_content   = q.mode == "entries",
	}
	context.allocator = backing
	buf, rc := db.command_frame(output, pr.getSizeTicketPage(msg)); if rc != sql.OK do return rc
	return pr.serializeTicketPage(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
