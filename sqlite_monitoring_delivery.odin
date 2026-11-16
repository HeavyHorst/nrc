package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_monitor_delivery :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	r, err := pr.parseMonitorDeliveryRequest(request.body)
	if err != nil do return sql.CONSTRAINT
	monitor, found, rc := sqlite_read_asset(store, request.workspace, request.actor, r.monitor_id, true)
	if rc != sql.OK do return rc
	if !found do return sql.CONSTRAINT
	config, _, valid := parse_monitor_config(&monitor, context.allocator)
	// Workspace members may inspect lanes and explicitly discard a dead head.
	// Leasing, delivery results and resync snapshots remain evaluator-only.
	if !valid || (config.evaluator != request.actor && r.action != 0 && r.action != 5 && r.action != 6) do return sql.CONSTRAINT
	routes: [32]string
	route_count := 0
	next_route := ""
	row: db.Monitor_Delivery
	state: u8
	incident_ids: [32]string
	incident_count := 0
	next_id: u64
	if r.action == 6 {
		s: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			`SELECT route FROM monitor_deliveries WHERE workspace=?1 AND monitor_id=?2 AND stream=1 AND route>?3
 UNION SELECT route FROM monitor_delivery_lanes WHERE workspace=?1 AND monitor_id=?2 AND stream=1 AND lost>0 AND route>?3
 ORDER BY route LIMIT 33`,
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 3, transmute([]byte)r.route); rc != sql.OK do return rc
		for {
			rc = sql.step(s)
			if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			if route_count == len(routes) {next_route = routes[route_count - 1]; break}
			routes[route_count] = strings.clone(string(sql.column_bytes_view(s, 0)))
			route_count += 1
		}
		state = 5
	} else if r.action == 7 {
		present: bool
		row, present, rc = db.monitor_delivery_head(store, request.workspace, r.monitor_id, 1, r.route)
		if rc != sql.OK do return rc
		if !present || row.sync_version == 0 || row.dead || row.lease_until <= request.timestamp || row.actor != request.actor || row.subject != request.subject do return sql.CONSTRAINT
		// A delayed page must never expose a replacement token as stale.
		if r.generation != row.sync_version do return sql.CONSTRAINT
		loss, loss_rc := db.monitor_delivery_loss(store, request.workspace, r.monitor_id, 1, r.route)
		if loss_rc != sql.OK do return loss_rc
		state = 7 // Stale snapshot: settle the obsolete token without publishing it.
		if loss.version == row.sync_version {
			state = 6
			s: ^sql.Statement
			rc = sql.prepare_v2(
				store.db,
				`SELECT e.incident_id FROM monitor_episodes e JOIN monitor_instances i
 ON i.workspace=e.workspace AND i.id=e.instance_id
 WHERE e.workspace=?1 AND i.monitor_id=?2 AND e.close_reason=0 AND e.incident_id>?3
 ORDER BY e.incident_id LIMIT 33`,
				-1,
				&s,
				nil,
			)
			if rc != sql.OK do return rc
			defer sql.finalize(s)
			if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 3, r.id); rc != sql.OK do return rc
			last: u64
			for {
				rc = sql.step(s); if rc == sql.DONE do break
				if rc != sql.ROW do return rc
				if incident_count == len(incident_ids) {next_id = last; break}
				if last, rc = sql.column_id(s, 0); rc != sql.OK do return rc
				incident_ids[incident_count] = fmt.aprintf("%d", last); incident_count += 1
			}
		}
	} else {
		if r.action == 1 {
			if rc = sqlite_monitor_prepare_resync(store, request.workspace, r.monitor_id, r.stream, r.route, request.timestamp); rc != sql.OK do return rc
		}
		// Draining old route references remains possible after configuration changes.
		row, state, rc = db.act_on_monitor_delivery(
			store,
			request.workspace,
			r.monitor_id,
			r.stream,
			r.route,
			request.actor,
			request.subject,
			r.action,
			r.id,
			r.generation,
			request.timestamp,
		)
		if rc != sql.OK do return rc
	}
	loss: db.Monitor_Delivery_Loss
	if r.action != 6 {
		if loss, rc = db.monitor_delivery_loss(store, request.workspace, r.monitor_id, r.stream, r.route); rc != sql.OK do return rc
	}
	response := struct {
		version:                                                  int,
		state:                                                    u8,
		id, generation, created_at, available_at, lease_until:    string,
		attempts:                                                 i64,
		payload:                                                  string,
		routes:                                                   []string,
		next_route:                                               string,
		incident_ids:                                             []string,
		next_id, sync_version, lost, loss_first_at, loss_last_at: string,
	} {
		1,
		state,
		fmt.aprintf("%d", row.id),
		fmt.aprintf("%d", row.generation),
		fmt.aprintf("%d", row.created_at),
		fmt.aprintf("%d", row.available_at),
		fmt.aprintf("%d", row.lease_until),
		row.attempts,
		row.body,
		routes[:route_count],
		next_route,
		incident_ids[:incident_count],
		fmt.aprintf("%d", next_id),
		fmt.aprintf("%d", row.sync_version),
		fmt.aprintf("%d", loss.lost),
		fmt.aprintf("%d", loss.first_at),
		fmt.aprintf("%d", loss.last_at),
	}
	body, json_err := json.marshal(response)
	if json_err != nil do return sql.CONSTRAINT
	context.allocator = backing
	buf, frame_rc := db.command_frame(output, 6 + len(body))
	if frame_rc != sql.OK do return frame_rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_MonitorDelivery))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	copy(buf[6:], body)
	return sql.OK
}
