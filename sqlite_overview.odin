package main

import "core:c"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Counts are maintained with mutations; time buckets use the request clock.
sqlite_collect_overview :: proc(store: ^db.Store, workspace: string, now: i64) -> (msg: pr.WorkspaceOverview, rc: c.int) {
	msg.sampled_at = now
	if rc = db.finalize_slices(store); rc != sql.OK do return
	s: ^sql.Statement
	rc = sql.prepare_v2(store.db, "SELECT status,total,covered FROM workspace_task_counts WHERE workspace=?1 AND total>0 ORDER BY status", -1, &s, nil)
	if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	total: i64
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return
		status := sql.column_int64(s, 0)
		count := sql.column_int64(s, 1)
		total += count
		if total > i64(max(u32)) {
			msg.error = transmute([]byte)string("Overview counter representation limit exceeded")
			return msg, sql.OK
		}
		if status == i64(pr.TaskStatus.Note) do continue
		if status < 0 || status >= i64(len(msg.status_counts)) {
			msg.error = transmute([]byte)string("Overview found an unsupported stored task status")
			return msg, sql.OK
		}
		assigned := sql.column_int64(s, 2)
		msg.status_counts[int(status)] = u32(count)
		msg.assigned_tasks += u32(assigned)
		msg.unassigned_tasks += u32(count - assigned)
	}
	// Coverage includes closed slices; the buckets include open slices only.
	slices: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT s.work,s.blocked,s.oldest FROM slice_metadata m
 CROSS JOIN slice_summaries s ON s.workspace=m.workspace AND s.slice_id=m.asset_id
 WHERE m.workspace=?1 AND m.closed=0`,
		-1,
		&slices,
		nil,
	)
	if rc != sql.OK do return
	defer sql.finalize(slices)
	if rc = sql.bind_bytes(slices, 1, transmute([]byte)workspace); rc != sql.OK do return
	for {
		rc = sql.step(slices); if rc == sql.DONE do break
		if rc != sql.ROW do return
		size := sql.column_int64(slices, 0)
		blocked := sql.column_int64(slices, 1)
		oldest := sql.column_int64(slices, 2)
		if msg.open_slices == max(u32) {
			msg.error = transmute([]byte)string("Overview counter representation limit exceeded")
			return msg, sql.OK
		}
		msg.open_slices += 1
		msg.size_buckets[size == 0 ? 0 : size <= 5 ? 1 : size <= 15 ? 2 : size <= 30 ? 3 : 4] += 1
		msg.blocked_buckets[blocked == 0 ? 0 : blocked <= 2 ? 1 : 2] += 1
		age_bucket := 4
		if oldest > 0 {
			// Clamp before subtraction, so a future timestamp cannot underflow.
			age := (max(now, oldest) - oldest) / (24 * 60 * 60 * 1_000_000_000)
			age_bucket = age <= 7 ? 0 : age <= 30 ? 1 : age <= 90 ? 2 : 3
		}
		msg.age_buckets[age_bucket] += 1
	}
	msg.success = true
	return msg, sql.OK
}

sqlite_workspace_overview :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseListTaskProjectsRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	msg, rc := sqlite_collect_overview(store, request.workspace, request.timestamp)
	if rc != sql.OK do return rc
	msg.correlation_id = req.correlation_id
	buf, frame_rc := db.command_frame(output, pr.getSizeWorkspaceOverview(msg))
	if frame_rc != sql.OK do return frame_rc
	return pr.serializeWorkspaceOverview(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
