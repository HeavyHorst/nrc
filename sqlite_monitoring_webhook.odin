package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_monitor_webhook :: proc(store: ^db.Store, workspace: string, monitor: ^pr.Asset, incident: ^pr.Asset, record: Incident_Record, at: i64) -> c.int {
	config, _, valid := parse_monitor_config(monitor, context.allocator)
	if !valid do return sql.CORRUPT
	event := struct {
		version:     int,
		incident_id: string,
		incident:    Incident_Record,
		identity:    []u8,
	}{1, fmt.aprintf("%d", incident.asset_id), record, incident.payload}
	body, err := json.marshal(event)
	if err != nil do return sql.CONSTRAINT
	if len(body) > 32768 do return sql.TOOBIG
	for route in config.webhooks {
		loss, loss_rc := db.monitor_delivery_loss(store, workspace, monitor.asset_id, 1, route)
		if loss_rc != sql.OK do return loss_rc
		// Already-dirty lanes were updated for this transition by the caller.
		if loss.lost > 0 do continue
		fits, capacity_rc := db.monitor_delivery_capacity(store, workspace, 1, 1, i64(len(body)))
		if capacity_rc != sql.OK do return capacity_rc
		if !fits {
			if rc := db.mark_monitor_delivery_loss(store, workspace, monitor.asset_id, 1, route, at); rc != sql.OK do return rc
			continue
		}
		if rc := db.enqueue_monitor_delivery(store, workspace, monitor.asset_id, 1, route, at, body); rc != sql.OK do return rc
	}
	return sql.OK
}
