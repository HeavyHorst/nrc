package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

@(test)
test_sqlite_monitor_overflow_and_resync :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-overflow-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	context.allocator = virtual.arena_allocator(&arena)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	execute :: proc(store: ^db.Store, output: ^db.Command_Output, frame: []byte, at: i64) -> c.int {
		r := db.Request {
			opcode    = pr.get_opcode(frame),
			workspace = "w",
			actor     = "checker",
			subject   = "worker",
			timestamp = at,
			body      = frame[2:],
		}
		db.destroy_command_output(output); output.limit = 1024 * 1024
		if e := db.begin(store); e != sql.OK do return e
		e := sqlite_execute_task_command(store, &r, output)
		if e != sql.OK {db.rollback(store); return e}
		return db.commit(store)
	}
	preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":1,"recoveries":1,"missing":3,"webhooks":["ops-v1"]}`
	payload := `{"kind":"tcp"}`
	wire: [4096]byte
	n := pr.serializeCreateAssetRequest(
		{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	testing.expect_value(t, execute(&store, &output, wire[:n], 100), sql.OK)
	rows := [1]pr.Monitor_Observation{{"disk", 1, 7}}
	run := pr.ApplyMonitorRunRequest {
		monitor_id   = 1,
		revision     = 100,
		sequence     = 1,
		observations = rows[:],
	}
	n = pr.serializeApplyMonitorRunRequest(run, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 101), sql.OK)
	// Saturate the webhook budget without evicting the original firing.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<9999)
 INSERT INTO monitor_deliveries(workspace,monitor_id,stream,route,id,body,created_at,available_at)
 SELECT x'77',x'0000000000000001',1,x'62757379',CAST(printf('%08d',i) AS BLOB),x'31',1,1 FROM n;`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	for sequence in u64(2) ..= 3 {
		rows[0].condition = sequence == 2 ? 0 : 1
		run.sequence = sequence; n = pr.serializeApplyMonitorRunRequest(run, wire[:])
		testing.expect_value(t, execute(&store, &output, wire[:n], 100 + i64(sequence)), sql.OK)
		testing.expect_value(t, execute(&store, &output, wire[:n], 900), sql.OK) // Retry must not count a loss twice.
	}
	instance, found, instance_rc := db.get_monitor_instance(&store, "w", 1, "disk")
	testing.expect(t, instance_rc == sql.OK && found && instance.state.incident_open && instance.state.episode == 2)
	webhook_loss, webhook_rc := db.monitor_delivery_loss(&store, "w", 1, 1, "ops-v1")
	testing.expect(t, webhook_rc == sql.OK && webhook_loss.lost == 2 && webhook_loss.first_at == 102 && webhook_loss.last_at == 103)
	// Overflow does not consume extra queue entries.
	testing.expect_value(t, db.begin(&store), sql.OK)
	fits, capacity_rc := db.monitor_delivery_capacity(&store, "w", 1, 1, 1)
	testing.expect(t, capacity_rc == sql.OK && !fits)
	testing.expect_value(t, db.commit(&store), sql.OK)
	// Manual lifecycle actions also succeed despite the backlog.
	control := pr.ControlMonitorInstanceRequest {
		monitor_id  = 1,
		revision    = 100,
		instance_id = instance.id,
		action      = 0,
	}
	n = pr.serializeControlMonitorInstanceRequest(control, wire[:]); testing.expect_value(t, execute(&store, &output, wire[:n], 104), sql.OK)
	control.revision = 104; control.action = 1
	n = pr.serializeControlMonitorInstanceRequest(control, wire[:]); testing.expect_value(t, execute(&store, &output, wire[:n], 105), sql.OK)
	run.revision = 105
	// Restart with durable loss metadata, then remove only synthetic backlog rows.
	testing.expect_value(t, db.close(&store), sql.OK); store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM monitor_deliveries WHERE route=x'62757379'", nil, nil, nil), sql.OK)
	Reply :: struct {
		state:                                                u8,
		id, generation, sync_version, payload, next_id, lost: string,
		incident_ids, routes:                                 []string,
	}
	deliver := proc(store: ^db.Store, output: ^db.Command_Output, request: pr.MonitorDeliveryRequest, at: i64) -> (reply: Reply, status: c.int) {
		buf: [256]byte
		size := pr.serializeMonitorDeliveryRequest(request, buf[:])
		if size < 2 do return {}, sql.MISUSE
		if status = execute(store, output, buf[:size], at); status != sql.OK do return
		if json.unmarshal(output.frames[0].payload[6:], &reply) != nil do return {}, sql.CORRUPT
		return
	}
	request := pr.MonitorDeliveryRequest {
		monitor_id = 1,
		stream     = 1,
		route      = "ops-v1",
		action     = 1,
	}
	old, old_rc := deliver(&store, &output, request, 106)
	testing.expect(t, old_rc == sql.OK && old.state == 2 && old.sync_version == "0") // Original firing retained, not evicted.
	id, _ := json_metadata_integer(old.id); lease, _ := json_metadata_integer(old.generation)
	request.action = 2; request.id = u64(id); request.generation = lease
	_, old_rc = deliver(&store, &output, request, 107); testing.expect_value(t, old_rc, sql.OK)
	request.action = 1; request.id = 0; request.generation = 0
	token, token_rc := deliver(&store, &output, request, 108)
	testing.expect(t, token_rc == sql.OK && token.state == 2 && token.sync_version != "0")
	snapshot_version, _ := json_metadata_integer(token.sync_version)
	id, _ = json_metadata_integer(token.id); lease, _ = json_metadata_integer(token.generation)
	request.action = 7; request.generation = snapshot_version
	page, page_rc := deliver(&store, &output, request, 109)
	testing.expect(t, page_rc == sql.OK && page.state == 6 && len(page.incident_ids) == 1 && page.incident_ids[0] == "3" && page.next_id == "0")
	// A recovery during the snapshot invalidates it and must survive the old token's ACK.
	rows[0].condition = 0; run.sequence = 4; n = pr.serializeApplyMonitorRunRequest(run, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 110), sql.OK)
	page, page_rc = deliver(&store, &output, request, 111)
	testing.expect(t, page_rc == sql.OK && page.state == 7)
	request.action = 2; request.id = u64(id); request.generation = lease
	_, token_rc = deliver(&store, &output, request, 112); testing.expect_value(t, token_rc, sql.OK)
	webhook_loss, webhook_rc = db.monitor_delivery_loss(&store, "w", 1, 1, "ops-v1")
	testing.expect(t, webhook_rc == sql.OK && webhook_loss.lost == 3 && webhook_loss.version != snapshot_version)
	request.action = 1; request.id = 0; request.generation = 0
	token, token_rc = deliver(&store, &output, request, 113)
	testing.expect(t, token_rc == sql.OK && token.state == 2)
	// A delayed page for T1 must not return T2's settlement credentials as stale.
	request.action = 7; request.generation = snapshot_version
	_, delayed_rc := deliver(&store, &output, request, 113)
	testing.expect_value(t, delayed_rc, sql.CONSTRAINT)
	testing.expect_value(t, output.count, 0)
	snapshot_version, _ = json_metadata_integer(token.sync_version)
	id, _ = json_metadata_integer(token.id); lease, _ = json_metadata_integer(token.generation)
	request.action = 7; request.generation = snapshot_version
	page, page_rc = deliver(&store, &output, request, 114)
	testing.expect(t, page_rc == sql.OK && page.state == 6 && len(page.incident_ids) == 0 && page.next_id == "0")
	request.action = 2; request.id = u64(id); request.generation = lease
	_, token_rc = deliver(&store, &output, request, 115); testing.expect_value(t, token_rc, sql.OK)
	webhook_loss, webhook_rc = db.monitor_delivery_loss(&store, "w", 1, 1, "ops-v1")
	testing.expect(t, webhook_rc == sql.OK && webhook_loss.lost == 0)
	// A dirty lane with no queued rows remains discoverable and snapshots page
	// across the 32-row boundary without skipping or repeating an Incident.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.mark_monitor_delivery_loss(&store, "w", 1, 1, "ops-v1", 116), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	many: [33]pr.Monitor_Observation
	for &row, i in many {row = {fmt.aprintf("host-%02d", i), 1, f64(i)}}
	run.observations = many[:]; run.sequence = 5
	n = pr.serializeApplyMonitorRunRequest(run, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 117), sql.OK)
	request = {
		monitor_id = 1,
		stream     = 1,
		action     = 6,
	}
	page, page_rc = deliver(&store, &output, request, 118)
	testing.expect(t, page_rc == sql.OK && page.state == 5 && len(page.routes) == 1 && page.routes[0] == "ops-v1")
	request.route = "ops-v1"; request.action = 1
	token, token_rc = deliver(&store, &output, request, 119)
	testing.expect(t, token_rc == sql.OK && token.state == 2)
	snapshot_version, _ = json_metadata_integer(token.sync_version)
	request.action = 7; request.generation = snapshot_version
	page, page_rc = deliver(&store, &output, request, 120)
	if !testing.expect(t, page_rc == sql.OK && page.state == 6 && len(page.incident_ids) == 32 && page.next_id == "35") do return
	for value, i in page.incident_ids {testing.expect_value(t, value, fmt.aprintf("%d", i + 4))}
	request.id = 35
	page, page_rc = deliver(&store, &output, request, 121)
	testing.expect(t, page_rc == sql.OK && page.state == 6 && len(page.incident_ids) == 1 && page.incident_ids[0] == "36" && page.next_id == "0")
	// Repeated route rotation must reclaim receipts too, while retaining the
	// dirty ops-v1 lane and its latest settlement receipt.
	previous: db.Monitor_Delivery
	for i in 0 ..< 260 {
		route := fmt.aprintf("rotation-%d", i)
		changed := fmt.aprintf(
			"%s%s%s",
			`{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":1,"recoveries":1,"missing":3,"webhooks":["`,
			route,
			`"]}`,
		)
		n = pr.serializeTransactionAssetPatch(
			{asset = {.Existing, .Asset, 1}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)changed},
			wire[:],
		)
		if i == 1 {
			// A failure after pruning must restore both the old lane and receipt.
			testing.expect_value(
				t,
				sql.exec(
					store.db,
					"CREATE TEMP TRIGGER reject_lane BEFORE INSERT ON monitor_delivery_lanes BEGIN SELECT RAISE(ABORT,'injected'); END",
					nil,
					nil,
					nil,
				),
				sql.OK,
			)
			testing.expect_value(t, sqlite_command_model_apply(&store, "w", 200 + i64(i), {{.AssetPatch, wire[:n]}}, nil, 0), "")
			testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_lane", nil, nil, nil), sql.OK)
		}
		if !testing.expect_value(t, sqlite_command_model_apply(&store, "w", 200 + i64(i), {{.AssetPatch, wire[:n]}}, {1}), "") do return
		testing.expect_value(t, db.begin(&store), sql.OK)
		if i > 0 {
			_, _, replay_rc := db.act_on_monitor_delivery(
				&store,
				"w",
				1,
				1,
				fmt.aprintf("rotation-%d", i - 1),
				"checker",
				"worker",
				2,
				previous.id,
				previous.generation,
				500,
			)
			testing.expect_value(t, replay_rc, sql.CONSTRAINT)
		}
		testing.expect_value(t, db.enqueue_monitor_delivery(&store, "w", 1, 1, route, 500, transmute([]byte)string("{}")), sql.OK)
		claimed, state, claim_rc := db.act_on_monitor_delivery(&store, "w", 1, 1, route, "checker", "worker", 1, 0, 0, 501)
		testing.expect(t, claim_rc == sql.OK && state == 2)
		_, _, ack_rc := db.act_on_monitor_delivery(&store, "w", 1, 1, route, "checker", "worker", 2, claimed.id, claimed.generation, 502)
		testing.expect_value(t, ack_rc, sql.OK)
		previous = claimed
		testing.expect_value(t, db.commit(&store), sql.OK)
	}
	s: ^sql.Statement
	testing.expect_value(
		t,
		sql.prepare_v2(store.db, "SELECT (SELECT count(*) FROM monitor_delivery_receipts),(SELECT count(*) FROM monitor_delivery_lanes)", -1, &s, nil),
		sql.OK,
	)
	defer sql.finalize(s)
	testing.expect_value(t, sql.step(s), sql.ROW)
	testing.expect_value(t, sql.column_int64(s, 0), 2)
	testing.expect_value(t, sql.column_int64(s, 1), 2)
}
