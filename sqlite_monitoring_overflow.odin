package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_monitor_register_lanes :: proc(store: ^db.Store, workspace: string, monitor: ^pr.Asset) -> c.int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	config, _, valid := parse_monitor_config(monitor, context.allocator)
	if !valid do return sql.CONSTRAINT
	if rc := sqlite_projection_write(store, "UPDATE monitor_delivery_lanes SET configured=0 WHERE workspace=?1 AND monitor_id=?2 AND stream=1", workspace, monitor, nil); rc != sql.OK do return rc
	// Mark retained references before pruning; dirty/queued old versions remain reserved.
	for route in config.webhooks {
		if rc := sqlite_projection_write(store, "UPDATE monitor_delivery_lanes SET configured=1 WHERE workspace=?1 AND monitor_id=?2 AND stream=1 AND route=?3", workspace, monitor, {route}); rc != sql.OK do return rc
	}
	if rc := sqlite_projection_write(store, `DELETE FROM monitor_delivery_lanes WHERE workspace=?1 AND monitor_id=?2 AND stream=1 AND configured=0 AND lost=0
 AND NOT EXISTS(SELECT 1 FROM monitor_deliveries d WHERE d.workspace=?1 AND d.monitor_id=?2 AND d.stream=1 AND d.route=monitor_delivery_lanes.route)`, workspace, monitor, nil); rc != sql.OK do return rc
	// Pruning a completed route ends its settlement replay window as well.
	if rc := sqlite_projection_write(store, `DELETE FROM monitor_delivery_receipts WHERE workspace=?1 AND monitor_id=?2 AND stream=1
 AND NOT EXISTS(SELECT 1 FROM monitor_delivery_lanes l WHERE l.workspace=?1 AND l.monitor_id=?2 AND l.stream=1 AND l.route=monitor_delivery_receipts.route)`, workspace, monitor, nil); rc != sql.OK do return rc
	for route in config.webhooks {
		if rc := sqlite_projection_write(store, "INSERT INTO monitor_delivery_lanes(workspace,monitor_id,stream,route) VALUES(?1,?2,1,?3) ON CONFLICT DO NOTHING", workspace, monitor, {route}); rc != sql.OK do return rc
	}
	return sql.OK
}

sqlite_monitor_loss_payload :: proc(monitor_id: u64, kind: string, loss: db.Monitor_Delivery_Loss) -> ([]byte, c.int) {
	value := struct {
		version:                                               int,
		kind, monitor_id, generation, lost, first_at, last_at: string,
	} {
		1,
		kind,
		fmt.aprintf("%d", monitor_id),
		fmt.aprintf("%d", loss.version),
		fmt.aprintf("%d", loss.lost),
		fmt.aprintf("%d", loss.first_at),
		fmt.aprintf("%d", loss.last_at),
	}
	body, err := json.marshal(value)
	return body, err == nil ? sql.OK : sql.CONSTRAINT
}

// Called only when a lane is drained. The queued token uses the normal lease/ACK path.
sqlite_monitor_prepare_resync :: proc(store: ^db.Store, workspace: string, monitor_id: u64, stream: u8, route: string, at: i64) -> c.int {
	_, found, rc := db.monitor_delivery_head(store, workspace, monitor_id, stream, route)
	if rc != sql.OK || found do return rc
	loss, status := db.monitor_delivery_loss(store, workspace, monitor_id, stream, route)
	if status != sql.OK || loss.lost == 0 do return status
	body, body_rc := sqlite_monitor_loss_payload(monitor_id, "webhook_resync", loss)
	if body_rc != sql.OK do return body_rc
	fits, capacity_rc := db.monitor_delivery_capacity(store, workspace, stream, 1, i64(len(body)))
	if capacity_rc != sql.OK || !fits do return capacity_rc
	return db.enqueue_monitor_delivery(store, workspace, monitor_id, stream, route, at, body, loss.version)
}
