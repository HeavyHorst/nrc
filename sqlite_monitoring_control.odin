package main

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_monitor_control_ack :: proc(output: ^db.Command_Output, r: pr.ControlMonitorInstanceRequest, revision: i64, replayed: bool) -> c.int {
	buf, rc := db.command_frame(output, 31)
	if rc != sql.OK do return rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_MonitorInstanceControlled))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.monitor_id)
	endian.put_u64(buf[14:], .Big, r.instance_id)
	endian.put_u64(buf[22:], .Big, u64(revision))
	buf[30] = replayed ? 1 : 0
	return sql.OK
}

// Workspace members may control instances, like shared Monitor configuration.
// The asset revision fences in-flight evaluations and concurrent manual actions.
// All writes and output belong to the executor's outer transaction.
sqlite_control_monitor_instance :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	r, err := pr.parseControlMonitorInstanceRequest(request.body)
	if err != nil || request.timestamp <= 0 || len(request.actor) == 0 do return sql.CONSTRAINT
	monitor, found, rc := sqlite_read_asset(store, request.workspace, request.actor, r.monitor_id, true)
	if rc != sql.OK do return rc
	if !found || monitor.asset_type != .Monitor do return sql.CONSTRAINT
	config, _, valid := parse_monitor_config(&monitor, context.allocator)
	if !valid do return sql.CONSTRAINT
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT revision,actor,subject,receipt FROM monitor_actions WHERE workspace=?1 AND monitor_id=?2", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc == sql.ROW {
			revision := sql.column_int64(s, 0)
			if revision == monitor.updated_at &&
			   string(sql.column_bytes_view(s, 1)) == request.actor &&
			   string(sql.column_bytes_view(s, 2)) == request.subject &&
			   string(sql.column_bytes_view(s, 3)) == string(request.body[4:]) {
				context.allocator = backing
				return sqlite_monitor_control_ack(output, r, revision, true)
			}
		} else if rc != sql.DONE do return rc
	}
	if monitor.updated_at != r.revision do return sql.CONSTRAINT
	if monitor.updated_at == max(i64) do return sql.FULL
	identity: string
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT identity FROM monitor_instances WHERE workspace=?1 AND id=?2 AND monitor_id=?3", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, r.instance_id); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 3, r.monitor_id); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.ROW do return rc == sql.DONE ? sql.CONSTRAINT : rc
		identity = strings.clone(string(sql.column_bytes_view(s, 0)))
	}
	before, _, read_rc := db.get_monitor_instance(store, request.workspace, r.monitor_id, identity)
	if read_rc != sql.OK do return read_rc
	if r.action == 1 && before.state.paused && !before.state.retired {
		s: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			"SELECT 1 FROM monitor_instances WHERE workspace=?1 AND monitor_id=?2 AND paused=0 AND retired=0 LIMIT 1 OFFSET ?3",
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 3, pr.MAX_MONITOR_INSTANCES - 1); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc == sql.ROW do return sql.TOOBIG
		if rc != sql.DONE do return rc
	}
	at := max(request.timestamp, monitor.updated_at + 1, before.state.last_evaluated_at)
	after, changes, control_rc := db.control_monitor_instance(store, request.workspace, r.monitor_id, identity, r.action, at)
	if control_rc != sql.OK do return control_rc
	if .Removed in changes {
		context.allocator = backing
		rc = sqlite_monitor_incident(store, request, &monitor, config.name, identity, after, false, at, output, removed = true)
		context.allocator = virtual.arena_allocator(&arena)
		if rc != sql.OK do return rc
	}
	// Advance only the acceptance fence, not other instances' streaks. Preserve a
	// pending config reset if the last run still belongs to an older config.
	if rc = sqlite_projection_write(store, "UPDATE monitor_runs SET revision=CASE WHEN revision=?3 THEN ?4 ELSE revision END,evaluated_at=max(evaluated_at,?4) WHERE workspace=?1 AND monitor_id=?2", request.workspace, &monitor, {monitor.updated_at, at}); rc != sql.OK do return rc
	monitor.updated_at = at
	if rc = sqlite_projection_write(store, "UPDATE assets SET updated_at=?3 WHERE workspace=?1 AND id=?2", request.workspace, &monitor, {at}); rc != sql.OK do return rc
	if rc = sqlite_projection_write(store, `INSERT INTO monitor_actions VALUES(?1,?2,?3,?4,?5,?6)
 ON CONFLICT(workspace,monitor_id) DO UPDATE SET revision=excluded.revision,actor=excluded.actor,subject=excluded.subject,receipt=excluded.receipt`, request.workspace, &monitor, {at, request.actor, request.subject, string(request.body[4:])}); rc != sql.OK do return rc
	actions := [3]string{"instance_paused", "instance_resumed", "instance_retired"}
	event := pr.History_Event {
		timestamp    = fmt.aprintf("%d", at),
		actor_id     = request.subject == "" ? fmt.aprintf("service:%s", request.actor) : request.subject,
		actor_name   = request.actor,
		entity_type  = "asset",
		entity_id    = fmt.aprintf("%d", monitor.asset_id),
		entity_label = config.name,
		asset_type   = u16(pr.AssetType.Monitor),
		action       = actions[r.action],
		fields       = {"instances"},
		source_type  = "monitor_instance",
		source_id    = fmt.aprintf("%d", r.instance_id),
		source_label = pr.history_short_label(identity, context.allocator),
	}
	if rc = db.append_history_event(store, request.workspace, event, {2, monitor.asset_id}); rc != sql.OK do return rc
	context.allocator = backing
	msg := pr.AssetUpdatedMessage {
		asset = monitor,
	}
	buf, frame_rc := db.command_frame(output, pr.getSizeAssetUpdatedMessage(msg), .Subscribers)
	if frame_rc != sql.OK do return frame_rc
	if pr.serializeAssetUpdatedMessage(msg, buf) != len(buf) do return sql.CONSTRAINT
	return sqlite_monitor_control_ack(output, r, at, false)
}
