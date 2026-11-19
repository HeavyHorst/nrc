package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import mon "monitoring"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

@(test)
test_webhook_route_immutable :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-route-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	preview := `{"version":1,"name":"ops-v1","kind":"webhook","base_url":"http://receiver/hook"}`
	wire: [4096]byte
	n := pr.serializeTransactionAssetCreate({asset_type = .MonitorSource, preview = transmute([]byte)preview}, wire[:])
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 100, {{.AssetCreate, wire[:n]}}, {1}), "")
	n = pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 1}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)preview},
		wire[:],
	)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 101, {{.AssetPatch, wire[:n]}}, nil, 0), "")
	n = pr.serializeTransactionDelete({entity = {.Existing, .Asset, 1}}, wire[:], .Asset)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 102, {{.AssetDelete, wire[:n]}}, nil, 0), "")
	victoria := `{"version":1,"name":"metrics","kind":"victoriametrics","base_url":"http://metrics:8428"}`
	n = pr.serializeTransactionAssetCreate({asset_type = .MonitorSource, preview = transmute([]byte)victoria}, wire[:])
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 103, {{.AssetCreate, wire[:n]}}, {2}), "")
	// Neither changing an existing route's kind nor converting a mutable source
	// into a route may circumvent immutable destination versions.
	for id in u64(1) ..= 2 {
		replacement := id == 1 ? victoria : preview
		n = pr.serializeTransactionAssetPatch(
			{asset = {.Existing, .Asset, id}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)replacement},
			wire[:],
		)
		testing.expect_value(t, sqlite_command_model_apply(&store, "w", 104, {{.AssetPatch, wire[:n]}}, nil, 0), "")
	}
	for opcode in ([2]pr.Opcode{.C_UpdateAsset, .C_DeleteAsset}) {
		if opcode == .C_UpdateAsset {
			n = pr.serializeUpdateAssetRequest({asset_id = 1, preview = transmute([]byte)preview}, wire[:])
		} else {
			n = pr.serializeDeleteAssetRequest(0, 1, wire[:])
		}
		output := db.Command_Output {
			limit = 1024 * 1024,
		}
		defer db.destroy_command_output(&output)
		request := db.Request {
			opcode    = opcode,
			workspace = "w",
			actor     = "alice",
			timestamp = 103,
			body      = wire[2:n],
		}
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
		testing.expect_value(t, db.commit(&store), sql.OK)
		testing.expect(t, output.count == 1 && pr.get_opcode(output.frames[0].payload) == .S_ErrorResponse)
	}
}

@(test)
test_sqlite_monitor_source_revision_fence :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-source-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	execute := proc(store: ^db.Store, output: ^db.Command_Output, wire: []byte, at: i64, workspace := "w") -> c.int {
		db.destroy_command_output(output); output.limit = 1024 * 1024
		r := db.Request {
			opcode    = pr.get_opcode(wire),
			workspace = workspace,
			actor     = "checker",
			timestamp = at,
			body      = wire[2:],
		}
		if rc := db.begin(store); rc != sql.OK do return rc
		rc := sqlite_execute_task_command(store, &r, output)
		if rc != sql.OK {db.rollback(store); return rc}
		return db.commit(store)
	}
	wire: [4096]byte
	source := `{"version":1,"name":"logs-short","kind":"victorialogs","base_url":"http://logs:9428","retention":"7d"}`
	n := pr.serializeCreateAssetRequest({asset_type = .MonitorSource, preview = transmute([]byte)source}, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 100), sql.OK)
	if !testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[0].payload) == .S_AssetCreated) do return
	preview := `{"version":1,"name":"Errors","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":1,"recoveries":1,"missing":3}`
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	cases: struct {
		urls:       []struct {
			value: string,
			valid: bool,
		},
		references: []struct {
			id, revision: string,
			valid:        bool,
		},
	}
	testing.expect(t, json.unmarshal(#load("protocol-go/testdata/monitor_source_validation.json"), &cases, allocator = allocator) == nil)
	for tc in cases.urls {
		config := Monitor_Source_Config {
			version  = 1,
			name     = "test",
			kind     = "victorialogs",
			base_url = tc.value,
		}
		body, err := json.marshal(config, allocator = allocator)
		testing.expect(t, err == nil)
		if tc.valid {
			a := pr.Asset {
				asset_type = .MonitorSource,
				preview    = body,
			}
			_, valid := parse_monitor_source(&a, allocator)
			testing.expect(t, valid, tc.value)
		} else {
			n = pr.serializeCreateAssetRequest({asset_type = .MonitorSource, preview = body}, wire[:])
			testing.expect_value(t, execute(&store, &output, wire[:n], 100), sql.OK)
			testing.expect(t, output.count == 1 && pr.get_opcode(output.frames[0].payload) == .S_ErrorResponse, tc.value)
			n = pr.serializeUpdateAssetRequest({asset_id = 1, preview = body}, wire[:])
			testing.expect_value(t, execute(&store, &output, wire[:n], 100), sql.OK)
			testing.expect(t, output.count == 1 && pr.get_opcode(output.frames[0].payload) == .S_ErrorResponse, tc.value)
		}
	}
	for tc in cases.references {
		body, err := json.marshal(Monitor_Source_Ref{"victorialogs", tc.id, tc.revision}, allocator = allocator)
		testing.expect(t, err == nil)
		a := pr.Asset {
			asset_type      = .Monitor,
			preview         = transmute([]byte)preview,
			payload         = body,
			payload_raw_len = u32(len(body)),
		}
		_, _, valid := parse_monitor_config(&a, allocator)
		testing.expect(t, valid == tc.valid, string(body))
	}
	payload := `{"kind":"victorialogs","source_id":"1","source_revision":"100","trigger":{"op":">","value":18446744073709551615}}`
	n = pr.serializeCreateAssetRequest(
		{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	testing.expect_value(t, execute(&store, &output, wire[:n], 101), sql.OK)
	if !testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[0].payload) == .S_AssetCreated, "large threshold create") do return
	created, create_err := pr.parseAssetCreatedMessage(output.frames[0].payload)
	testing.expect(t, create_err == nil && string(created.asset.payload) == payload)
	rows := [2]pr.Monitor_Observation{{`{"host":"a"}`, 1, 20}, {`{"host":"b"}`, 0, 0}}
	run := pr.ApplyMonitorRunRequest {
		monitor_id   = 2,
		revision     = 101,
		sequence     = 1,
		observations = rows[:],
	}
	n = pr.serializeApplyMonitorRunRequest(run, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 102, "other"), sql.CONSTRAINT)
	testing.expect_value(t, execute(&store, &output, wire[:n], 102), sql.OK)
	// Shared source edits invalidate in-flight runs, even with a current Monitor revision.
	n = pr.serializeUpdateAssetRequest({asset_id = 1, preview = transmute([]byte)source}, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 103), sql.OK)
	run.sequence = 2
	n = pr.serializeApplyMonitorRunRequest(run, wire[:])
	before, why := sqlite_command_snapshot(&store); defer delete(before)
	testing.expect_value(t, why, "")
	testing.expect_value(t, execute(&store, &output, wire[:n], 104), sql.CONSTRAINT)
	run.failed, run.observations = true, nil
	n = pr.serializeApplyMonitorRunRequest(run, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 104), sql.CONSTRAINT)
	run.failed, run.observations = false, rows[:]
	after, why2 := sqlite_command_snapshot(&store); defer delete(after)
	testing.expect(t, why2 == "" && string(before[:]) == string(after[:]))
	payload = `{"kind":"victorialogs","source_id":"1","source_revision":"103","trigger":{"op":">","value":18446744073709551615}}`
	n = pr.serializeUpdateAssetRequest(
		{asset_id = 2, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	testing.expect_value(t, execute(&store, &output, wire[:n], 105), sql.OK)
	if !testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[0].payload) == .S_AssetUpdated, "large threshold update") do return
	updated, update_err := pr.parseAssetUpdatedMessage(output.frames[0].payload)
	testing.expect(t, update_err == nil && string(updated.asset.payload) == payload)
	run.revision = 105
	n = pr.serializeApplyMonitorRunRequest(run, wire[:])
	testing.expect_value(t, execute(&store, &output, wire[:n], 106), sql.OK)
}

@(test)
test_sqlite_monitor_route_discovery :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-monitor-discovery-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	context.allocator = virtual.arena_allocator(&arena)
	preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":2,"recoveries":2,"missing":3,"webhooks":["ops-v1"]}`
	payload := `{"kind":"tcp"}`
	wire: [4096]byte
	n := pr.serializeCreateAssetRequest(
		{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	request := db.Request {
		opcode    = .C_CreateAsset,
		workspace = "w",
		actor     = "alice",
		timestamp = 100,
		body      = wire[2:n],
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
	for i in 0 ..< 34 {
		route := fmt.aprintf("old-%02d", i)
		testing.expect_value(t, db.enqueue_monitor_delivery(&store, "w", 1, 1, route, 101, transmute([]byte)payload), sql.OK)
	}
	for _ in 0 ..< 2 {testing.expect_value(t, db.enqueue_monitor_delivery(&store, "w", 1, 1, "ops-v1", 101, transmute([]byte)payload), sql.OK)}
	// Old lanes survive both a route/evaluator change and a restart. Include dead-only lanes.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`UPDATE assets SET preview=CAST(replace(replace(replace(CAST(preview AS TEXT),'ops-v1','ops-v2'),'checker','replacement'),'true','false') AS BLOB),updated_at=104;
 UPDATE monitor_deliveries SET dead=1 WHERE route=x'6f6c642d3030';`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	Result :: struct {
		state:                      u8,
		routes:                     []string,
		next_route, id, generation: string,
	}
	execute := proc(store: ^db.Store, output: ^db.Command_Output, r: pr.MonitorDeliveryRequest, actor, workspace: string) -> (result: Result, status: c.int) {
		buf: [128]byte
		size := pr.serializeMonitorDeliveryRequest(r, buf[:])
		if size < 2 do return {}, sql.MISUSE
		req := db.Request {
			opcode    = .C_MonitorDelivery,
			workspace = workspace,
			actor     = actor,
			timestamp = 105,
			body      = buf[2:size],
		}
		db.destroy_command_output(output); output.limit = 1024 * 1024
		if status = db.begin(store); status != sql.OK do return
		status = sqlite_execute_task_command(store, &req, output)
		if status != sql.OK {db.rollback(store); return}
		if status = db.commit(store); status != sql.OK do return
		if output.count != 1 || json.unmarshal(output.frames[0].payload[6:], &result) != nil do return {}, sql.CORRUPT
		return
	}
	r := pr.MonitorDeliveryRequest {
		monitor_id = 1,
		stream     = 1,
		action     = 6,
	}
	claim := r; claim.action = 1; claim.route = "old-00"
	_, denied := execute(&store, &output, claim, "checker", "w"); testing.expect_value(t, denied, sql.CONSTRAINT)
	_, denied = execute(&store, &output, r, "replacement", "other"); testing.expect_value(t, denied, sql.CONSTRAINT)
	page, status := execute(&store, &output, r, "replacement", "w")
	if !testing.expect(t, status == sql.OK && page.state == 5 && len(page.routes) == 32 && page.next_route == "old-31") do return
	for route, i in page.routes {testing.expect_value(t, route, fmt.aprintf("old-%02d", i))}
	// Removing the cursor row must not break continuation.
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM monitor_deliveries WHERE route=x'6f6c642d3331'", nil, nil, nil), sql.OK)
	r.route = page.next_route
	page, status = execute(&store, &output, r, "replacement", "w")
	if !testing.expect(t, status == sql.OK && len(page.routes) == 3 && page.routes[0] == "old-32" && page.routes[1] == "old-33" && page.routes[2] == "ops-v1" && page.next_route == "") do return
	// Use only the discovered old name to claim and settle both old notifications.
	r.route = page.routes[2]
	for _ in 0 ..< 2 {
		r.action = 1; r.id = 0; r.generation = 0
		job, job_rc := execute(&store, &output, r, "replacement", "w")
		testing.expect(t, job_rc == sql.OK && job.state == 2)
		id, id_ok := json_metadata_integer(job.id); generation, g_ok := json_metadata_integer(job.generation)
		testing.expect(t, id_ok && g_ok)
		r.action = 2; r.id = u64(id); r.generation = generation
		_, job_rc = execute(&store, &output, r, "replacement", "w"); testing.expect_value(t, job_rc, sql.OK)
	}
	r.action = 6; r.id = 0; r.generation = 0; r.route = "old-33"
	page, status = execute(&store, &output, r, "replacement", "w")
	testing.expect(t, status == sql.OK && page.state == 5 && len(page.routes) == 0 && page.next_route == "")
	// Human intervention can inspect and discard dead heads, never lease them.
	// Use the lane reserved by the real Monitor configuration, not synthetic
	// discovery-only fixture routes without overflow metadata.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.enqueue_monitor_delivery(&store, "w", 1, 1, "ops-v1", 101, transmute([]byte)payload), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	claim.route = "ops-v1"
	job, job_rc := execute(&store, &output, claim, "replacement", "w")
	if !testing.expect(t, job_rc == sql.OK && job.state == 2) do return
	id, _ := json_metadata_integer(job.id); generation, _ := json_metadata_integer(job.generation)
	claim.id = u64(id); claim.generation = generation; claim.action = 5
	_, job_rc = execute(&store, &output, claim, "human", "w"); testing.expect_value(t, job_rc, sql.CONSTRAINT)
	claim.action = 4
	_, job_rc = execute(&store, &output, claim, "replacement", "w"); testing.expect_value(t, job_rc, sql.OK)
	claim.action = 5; claim.generation += 1
	_, job_rc = execute(&store, &output, claim, "human", "w"); testing.expect_value(t, job_rc, sql.CONSTRAINT)
	claim.generation -= 1
	_, job_rc = execute(&store, &output, claim, "human", "other"); testing.expect_value(t, job_rc, sql.CONSTRAINT)
	for _ in 0 ..< 2 {
		job, job_rc = execute(&store, &output, claim, "human", "w")
		testing.expect(t, job_rc == sql.OK && job.state == 4)
	}
}

@(test)
test_monitor_config_display_unit :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	expected_units := [5]string{"", "", "number", "percent", "bytes"}
	for field, i in ([]string {
			``,
			`,"unit":""`,
			`,"unit":"number"`,
			`,"unit":"percent"`,
			`,"unit":"bytes"`,
			`,"unit":"Bytes"`,
			`,"unit":"kilobytes"`,
			`,"unit":100`,
			`,"unit":null`,
			`,"unit":true`,
		}) {
		virtual.arena_free_all(&arena)
		preview := fmt.aprintf(
			"%s%s%s",
			`{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":5,"recoveries":2,"missing":3`,
			field,
			"}",
		)
		defer delete(preview)
		payload := `{"kind":"tcp"}`
		asset := pr.Asset {
			asset_type      = .Monitor,
			preview         = transmute([]byte)preview,
			payload         = transmute([]byte)payload,
			payload_raw_len = u32(len(payload)),
		}
		config, policy, valid := parse_monitor_config(&asset, virtual.arena_allocator(&arena))
		testing.expect(t, valid == (i < 5), preview)
		if valid && i < len(expected_units) {
			testing.expect(t, config.unit == expected_units[i] && policy.failures == 5 && policy.recoveries == 2 && policy.missing == 3)
		}
	}
}

@(test)
test_monitor_config_threshold_bounds :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	for field in 0 ..< 3 {
		for value in ([]i64{-1, 0, 1, 4294967295, 4294967296, 4294967297}) {
			virtual.arena_free_all(&arena)
			values := [3]i64{5, 2, 3}; values[field] = value
			preview := fmt.aprintf(
				`%s%d,"recoveries":%d,"missing":%d%s`,
				`{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":`,
				values[0],
				values[1],
				values[2],
				"}",
			)
			payload := `{"kind":"tcp"}`
			asset := pr.Asset {
				asset_type      = .Monitor,
				preview         = transmute([]byte)preview,
				payload         = transmute([]byte)payload,
				payload_raw_len = u32(len(payload)),
			}
			_, policy, valid := parse_monitor_config(&asset, virtual.arena_allocator(&arena))
			expected := value >= 1 && value <= 4294967295
			testing.expect(t, valid == expected, preview)
			delete(preview)
			if valid && expected {
				testing.expect(t, policy.failures == u32(values[0]) && policy.recoveries == u32(values[1]) && policy.missing == u32(values[2]))
			}
		}
	}
}

@(test)
test_sqlite_monitor_run_assets_and_guards :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-monitor-command-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	wire: [16384]byte
	preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":2,"recoveries":2,"missing":3,"webhooks":["ops-v1","audit-v1"]}`
	payload := `{"kind":"http"}` // Adapter-independent server command fixture.
	n := pr.serializeCreateAssetRequest(
		{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	request := db.Request {
		opcode    = .C_CreateAsset,
		workspace = "w",
		actor     = "alice",
		subject   = "alice-id",
		timestamp = 100,
		body      = wire[2:n],
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	if !testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK) do return
	testing.expect_value(t, db.commit(&store), sql.OK)
	if !testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[0].payload) == .S_AssetCreated) do return
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	rows := [2]pr.Monitor_Observation{{"host=a;mount=/data", 1, 7.25}, {"host=b;mount=/", 0, 81.5}}
	run := pr.ApplyMonitorRunRequest {
		monitor_id     = 1,
		revision       = 100,
		sequence       = 1,
		correlation_id = 77,
		observations   = rows[:],
	}
	apply := proc(store: ^db.Store, run: pr.ApplyMonitorRunRequest, output: ^db.Command_Output, actor := "checker", workspace := "w", at: i64 = 101) -> c.int {
		wire: [pr.MAX_PROTOCOL_PAYLOAD_SIZE]byte
		n := pr.serializeApplyMonitorRunRequest(run, wire[:]); if n <= 2 do return sql.MISUSE
		r := db.Request {
			opcode    = .C_ApplyMonitorRun,
			workspace = workspace,
			actor     = actor,
			timestamp = at,
			body      = wire[2:n],
		}
		db.destroy_command_output(output); output.limit = 1024 * 1024
		if rc := db.begin(store); rc != sql.OK do return rc
		rc := sqlite_execute_task_command(store, &r, output)
		if rc != sql.OK {db.rollback(store); db.destroy_command_output(output); return rc}
		return db.commit(store)
	}
	testing.expect_value(t, apply(&store, run, &output, "intruder"), sql.CONSTRAINT)
	testing.expect_value(t, apply(&store, run, &output, workspace = "other"), sql.CONSTRAINT)
	run.revision = 99
	testing.expect_value(t, apply(&store, run, &output), sql.CONSTRAINT)
	run.revision = 100
	testing.expect_value(t, apply(&store, run, &output), sql.OK)
	testing.expect(t, output.count == 1 && pr.get_opcode(output.frames[0].payload) == .S_MonitorRunApplied)
	queue_count := proc(store: ^db.Store, stream: i64) -> i64 {
		s: ^sql.Statement
		if sql.prepare_v2(store.db, "SELECT count(*) FROM monitor_deliveries WHERE stream=?1", -1, &s, nil) != sql.OK do return -1
		defer sql.finalize(s)
		if sql.bind_int64(s, 1, stream) != sql.OK || sql.step(s) != sql.ROW do return -1
		return sql.column_int64(s, 0)
	}
	testing.expect_value(t, queue_count(&store, 0), 0) // Measurements never enter NRC's outbox.
	run.sequence = 2
	// Failure after state/episode writes must leave no incident, receipt or ID.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"CREATE TEMP TRIGGER reject_incident BEFORE INSERT ON assets WHEN NEW.asset_type=16 BEGIN SELECT RAISE(ABORT,'injected'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	before, why := sqlite_command_snapshot(&store); defer delete(before)
	testing.expect_value(t, why, "")
	testing.expect_value(t, apply(&store, run, &output, at = 102), sql.CONSTRAINT)
	after, why2 := sqlite_command_snapshot(&store); defer delete(after)
	testing.expect(t, why2 == "" && string(before[:]) == string(after[:]))
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_incident", nil, nil, nil), sql.OK)
	// A real outbox write failure still rolls back the incident and earlier route inserts.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"CREATE TEMP TRIGGER reject_outbox BEFORE INSERT ON monitor_deliveries WHEN NEW.route=x'61756469742d7631' BEGIN SELECT RAISE(ABORT,'injected'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, apply(&store, run, &output, at = 102), sql.CONSTRAINT)
	queue_snapshot, queue_why := sqlite_command_snapshot(&store); defer delete(queue_snapshot)
	testing.expect(t, queue_why == "" && string(before[:]) == string(queue_snapshot[:]))
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_outbox", nil, nil, nil), sql.OK)
	testing.expect_value(t, apply(&store, run, &output, at = 102), sql.OK)
	testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[0].payload) == .S_AssetCreated)
	created, parse_err := pr.parseAssetCreatedMessage(output.frames[0].payload)
	testing.expect(
		t,
		parse_err == nil && created.asset.asset_id == 2 && created.asset.asset_type == .Incident && string(created.asset.payload) == rows[0].identity,
	)
	// Reopen and retry with a new correlation and server time: no repeated broadcast.
	testing.expect_value(t, db.close(&store), sql.OK); store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	run.correlation_id = 88
	testing.expect_value(t, apply(&store, run, &output, at = 500), sql.OK)
	testing.expect(t, output.count == 1 && output.frames[0].payload[22] == 1)
	testing.expect_value(t, queue_count(&store, 0), 0)
	testing.expect_value(t, queue_count(&store, 1), 2) // Replay creates no duplicate notifications.
	// A restarted evaluator reads the committed sequence without mutating state.
	{
		state_body: [12]byte
		endian.put_u32(state_body[:], .Big, 31)
		endian.put_u64(state_body[4:], .Big, 1)
		before_state, before_error := sqlite_command_snapshot(&store); defer delete(before_state)
		testing.expect_value(t, before_error, "")
		for actor in ([2]string{"intruder", "checker"}) {
			db.destroy_command_output(&output); output.limit = 1024 * 1024
			query := db.Request {
				opcode    = .C_GetMonitorState,
				workspace = "w",
				actor     = actor,
				body      = state_body[:],
			}
			status := sqlite_execute_task_command(&store, &query, &output)
			if actor == "intruder" {testing.expect_value(t, status, sql.CONSTRAINT); testing.expect_value(t, output.count, 0); continue}
			if !testing.expect(t, status == sql.OK && output.count == 1) do return
			frame := output.frames[0].payload
			testing.expect(t, len(frame) == 30 && pr.get_opcode(frame) == .S_MonitorState)
			revision, _ := endian.get_u64(frame[14:], .Big)
			sequence, _ := endian.get_u64(frame[22:], .Big)
			testing.expect(t, revision == 100 && sequence == 2)
			query.workspace = "other"
			testing.expect_value(t, sqlite_execute_task_command(&store, &query, &output), sql.CONSTRAINT)
		}
		after_state, after_error := sqlite_command_snapshot(&store); defer delete(after_state)
		testing.expect(t, after_error == "" && string(before_state[:]) == string(after_state[:]))
	}
	// Exercise the dispatched delivery command, including authorization and output ownership.
	{
		delivery := pr.MonitorDeliveryRequest {
			correlation_id = 99,
			monitor_id     = 1,
			stream         = 1,
			route          = "ops-v1",
			action         = 1,
		}
		delivery_wire: [128]byte
		delivery_n := pr.serializeMonitorDeliveryRequest(delivery, delivery_wire[:])
		for actor in ([2]string{"intruder", "checker"}) {
			db.destroy_command_output(&output); output.limit = 1024 * 1024
			req := db.Request {
				opcode    = .C_MonitorDelivery,
				workspace = "w",
				actor     = actor,
				subject   = "delivery-worker",
				timestamp = 501,
				body      = delivery_wire[2:delivery_n],
			}
			testing.expect_value(t, db.begin(&store), sql.OK)
			result := sqlite_execute_task_command(&store, &req, &output)
			if actor == "intruder" {
				testing.expect_value(t, result, sql.CONSTRAINT)
				testing.expect_value(t, db.rollback(&store), sql.OK)
				continue
			}
			testing.expect_value(t, result, sql.OK)
			testing.expect_value(t, db.commit(&store), sql.OK)
			if !testing.expect(t, output.count == 1 && pr.get_opcode(output.frames[0].payload) == .S_MonitorDelivery) do return
			response: struct {
				state:                   u8,
				id, generation, payload: string,
			}
			testing.expect(t, json.unmarshal(output.frames[0].payload[6:], &response) == nil)
			defer {delete(response.id); delete(response.generation); delete(response.payload)}
			testing.expect(t, response.state == 2 && response.generation == "1")
			event: struct {
				incident_id: string,
				identity:    []u8,
			}
			testing.expect(t, json.unmarshal(transmute([]byte)response.payload, &event) == nil)
			defer {delete(event.incident_id); delete(event.identity)}
			testing.expect(t, event.incident_id == "2" && string(event.identity) == rows[0].identity)
		}
	}
	rows[0].value = 6
	testing.expect_value(t, apply(&store, run, &output), sql.CONSTRAINT)
	rows[0].value = 7.25
	run.sequence = 1
	testing.expect_value(t, apply(&store, run, &output), sql.CONSTRAINT)
	// Successful omission differs from a failed query, neither recovers the alarm.
	run.sequence = 3; run.observations = rows[1:]
	testing.expect_value(t, apply(&store, run, &output, at = 103), sql.OK)
	saved, found, read_rc := db.get_monitor_instance(&store, "w", 1, rows[0].identity)
	testing.expect(t, read_rc == sql.OK && found && saved.state.incident_open && saved.state.freshness == .Missing)
	run.sequence = 4; run.failed = true; run.observations = nil
	testing.expect_value(t, apply(&store, run, &output, at = 104), sql.OK)
	saved, found, read_rc = db.get_monitor_instance(&store, "w", 1, rows[0].identity)
	testing.expect(t, read_rc == sql.OK && found && saved.state.incident_open && saved.state.last_observation == mon.Observation.Evaluation_Error)
	run.failed = false; rows[0].condition = 0; run.observations = rows[:]
	for sequence in u64(5) ..= 6 {
		run.sequence = sequence
		testing.expect_value(t, apply(&store, run, &output, at = 100 + i64(sequence)), sql.OK)
	}
	if !testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[0].payload) == .S_AssetUpdated) do return
	updated, update_err := pr.parseAssetUpdatedMessage(output.frames[0].payload)
	arena: virtual.Arena; if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	record: Incident_Record
	testing.expect(
		t,
		update_err == nil &&
		json.unmarshal(updated.asset.preview, &record, allocator = virtual.arena_allocator(&arena)) == nil &&
		record.status == "recovered" &&
		record.opened_at == "102" &&
		record.closed_at == "106",
	)
	// General asset mutation cannot create, overwrite or delete incidents.
	n = pr.serializeCreateAssetRequest({asset_type = .Incident, preview = transmute([]byte)string(`{}`)}, wire[:])
	request.opcode = .C_CreateAsset; request.body = wire[2:n]
	db.destroy_command_output(&output); output.limit = 1024 * 1024
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	testing.expect(t, output.count == 1 && pr.get_opcode(output.frames[0].payload) == .S_ErrorResponse)
	n = pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 2}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)string(`{"status":"firing"}`)},
		wire[:],
	)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 200, {{.AssetPatch, wire[:n]}}, nil, 0), "")
	n = pr.serializeTransactionDelete({entity = {.Existing, .Asset, 2}}, wire[:], .Asset)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 200, {{.AssetDelete, wire[:n]}}, nil, 0), "")
	// Config changes break old streaks and reject in-flight work for the old revision.
	// Historical rows exceed the active budget. Seed retirement directly until
	// the manual retirement command is implemented; runs still use the wire API.
	testing.expect_value(t, db.begin(&store), sql.OK)
	for i in 0 ..< 1025 {
		identity := fmt.aprintf("archived%d", i)
		seed := [1]db.Monitor_Evaluation{{1, identity, {2, 2, 3, 190}, {1, 1, .Passing, 50}}}
		result: [1]db.Monitor_Application
		testing.expect_value(t, db.apply_monitor_evaluations(&store, "w", seed[:], result[:]), sql.OK)
		delete(identity)
	}
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"UPDATE monitor_instances SET retired=1,freshness=0 WHERE CAST(identity AS TEXT) GLOB 'archived*'; UPDATE monitor_instances SET retired=0,paused=1 WHERE identity=x'617263686976656431'",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	historical, historical_found, historical_rc := db.get_monitor_instance(&store, "w", 1, "archived0")
	testing.expect(t, historical_found && historical_rc == sql.OK && historical.state.retired)
	paused, paused_found, paused_rc := db.get_monitor_instance(&store, "w", 1, "archived1")
	testing.expect(t, paused_found && paused_rc == sql.OK && paused.state.paused)
	rows[0].condition = 1; run.sequence = 7
	testing.expect_value(t, apply(&store, run, &output, at = 107), sql.OK)
	changed := `{"version":1,"name":"Disk edited","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":2,"recoveries":2,"missing":3}`
	n = pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 1}, if_updated_at = 100, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)changed},
		wire[:],
	)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 110, {{.AssetPatch, wire[:n]}}, {1}), "")
	run.sequence = 8
	testing.expect_value(t, apply(&store, run, &output, at = 111), sql.CONSTRAINT)
	run.revision = 110
	testing.expect_value(t, apply(&store, run, &output, at = 111), sql.OK)
	saved, found, read_rc = db.get_monitor_instance(&store, "w", 1, rows[0].identity)
	testing.expect(t, read_rc == sql.OK && found && saved.state.failures == 1 && !saved.state.incident_open)
	run.sequence = 9
	testing.expect_value(t, apply(&store, run, &output, at = 112), sql.OK)
	created, parse_err = pr.parseAssetCreatedMessage(output.frames[0].payload)
	testing.expect(t, parse_err == nil && created.asset.asset_id == 3)
	// Duplicate and oversized unions must be rejected without admitting a prefix.
	rows[1] = rows[0]; run.sequence = 10
	testing.expect_value(t, apply(&store, run, &output, at = 113), sql.CONSTRAINT)
	large: [pr.MAX_MONITOR_INSTANCES]pr.Monitor_Observation
	for &row, i in large {row = {fmt.aprintf("new%d", i), 0, 50}}
	defer for row in large {delete(row.identity)}
	run.observations = large[:]
	testing.expect_value(t, apply(&store, run, &output, at = 113), sql.TOOBIG)
	_, found, read_rc = db.get_monitor_instance(&store, "w", 1, "new0")
	testing.expect(t, read_rc == sql.OK && !found)
	// History does not block recovery or reappearance with the same stable ID.
	rows[0].condition = 0; rows[1] = {"archived0", 0, 75}; run.observations = rows[:]
	for sequence in u64(10) ..= 11 {
		run.sequence = sequence
		testing.expect_value(t, apply(&store, run, &output, at = 100 + i64(sequence)), sql.OK)
	}
	saved, found, read_rc = db.get_monitor_instance(&store, "w", 1, rows[0].identity)
	testing.expect(t, read_rc == sql.OK && found && !saved.state.incident_open)
	reappeared, reappeared_found, reappeared_rc := db.get_monitor_instance(&store, "w", 1, "archived0")
	testing.expect(
		t,
		reappeared_found && reappeared_rc == sql.OK && reappeared.id == historical.id && !reappeared.state.retired && reappeared.state.last_value == 75,
	)
	run.sequence = 12; run.failed = true; run.observations = nil
	testing.expect_value(t, apply(&store, run, &output, at = 114), sql.OK)
	still_paused, _, _ := db.get_monitor_instance(&store, "w", 1, "archived1")
	testing.expect(t, still_paused == paused)
	still_retired, _, _ := db.get_monitor_instance(&store, "w", 1, "archived2")
	testing.expect(t, still_retired.state.retired && still_retired.state.last_sequence == 1)
	// Exactly 1024 active identities (three existing plus 1021 new) still fit.
	run.sequence = 13; run.failed = false; run.observations = large[:1021]
	testing.expect_value(t, apply(&store, run, &output, at = 115), sql.OK)
	run.sequence = 14; run.observations = large[:1022]
	testing.expect_value(t, apply(&store, run, &output, at = 116), sql.TOOBIG)
	disabled, allocated := strings.replace_all(changed, `"enabled":true`, `"enabled":false`)
	defer if allocated do delete(disabled)
	n = pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 1}, if_updated_at = 110, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)disabled},
		wire[:],
	)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 115, {{.AssetPatch, wire[:n]}}, {1}), "")
	run.revision = 115; run.observations = nil
	testing.expect_value(t, apply(&store, run, &output, at = 116), sql.CONSTRAINT)
	n = pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 1}, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)string(`{"version":1}`)},
		wire[:],
	)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 117, {{.AssetPatch, wire[:n]}}, nil, 0), "")
}

@(test)
test_sqlite_monitor_instance_controls :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-monitor-control-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	execute :: proc(store: ^db.Store, wire: []byte, output: ^db.Command_Output, at: i64, actor := "alice", workspace := "w") -> c.int {
		request := db.Request {
			opcode    = pr.get_opcode(wire),
			workspace = workspace,
			actor     = actor,
			subject   = actor,
			timestamp = at,
			body      = wire[2:],
		}
		db.destroy_command_output(output); output.limit = 1024 * 1024
		if rc := db.begin(store); rc != sql.OK do return rc
		rc := sqlite_execute_task_command(store, &request, output)
		if rc != sql.OK {db.rollback(store); db.destroy_command_output(output); return rc}
		return db.commit(store)
	}
	apply := proc(store: ^db.Store, r: pr.ApplyMonitorRunRequest, output: ^db.Command_Output, at: i64) -> c.int {
		wire: [pr.MAX_PROTOCOL_PAYLOAD_SIZE]byte
		n := pr.serializeApplyMonitorRunRequest(r, wire[:]); if n < 2 do return sql.MISUSE
		return execute(store, wire[:n], output, at, "checker")
	}
	control := proc(store: ^db.Store, r: pr.ControlMonitorInstanceRequest, output: ^db.Command_Output, at: i64, actor := "alice", workspace := "w") -> c.int {
		wire: [31]byte
		n := pr.serializeControlMonitorInstanceRequest(r, wire[:]); if n < 2 do return sql.MISUSE
		return execute(store, wire[:n], output, at, actor, workspace)
	}
	wire: [1024]byte
	preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":2,"recoveries":2,"missing":3}`
	payload := `{"kind":"http"}`
	n := pr.serializeCreateAssetRequest(
		{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	testing.expect_value(t, execute(&store, wire[:n], &output, 100), sql.OK)
	testing.expect_value(t, execute(&store, wire[:n], &output, 100), sql.OK) // Another monitor for ID isolation.
	rows := [2]pr.Monitor_Observation{{"disk-a", 1, 3}, {"disk-b", 0, 50}}
	run := pr.ApplyMonitorRunRequest {
		monitor_id   = 1,
		revision     = 100,
		sequence     = 1,
		observations = rows[:],
	}
	testing.expect_value(t, apply(&store, run, &output, 101), sql.OK)
	rows[1].condition = 1; run.sequence = 2
	testing.expect_value(t, apply(&store, run, &output, 102), sql.OK)
	a, found, read_rc := db.get_monitor_instance(&store, "w", 1, "disk-a")
	if !testing.expect(t, found && read_rc == sql.OK && a.state.incident_open) do return
	action := pr.ControlMonitorInstanceRequest{77, 1, 100, a.id, 0}
	testing.expect_value(t, control(&store, action, &output, 103, workspace = "other"), sql.CONSTRAINT)
	action.monitor_id = 2
	testing.expect_value(t, control(&store, action, &output, 103), sql.CONSTRAINT)
	action.monitor_id = 1
	// A late failure must roll back the revision, action receipt and state together.
	testing.expect_value(
		t,
		sql.exec(store.db, "CREATE TEMP TRIGGER reject_control_history BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'injected'); END", nil, nil, nil),
		sql.OK,
	)
	before_pause, before_why := sqlite_command_snapshot(&store); defer delete(before_pause)
	testing.expect_value(t, control(&store, action, &output, 103), sql.CONSTRAINT)
	after_pause, after_why := sqlite_command_snapshot(&store); defer delete(after_pause)
	testing.expect(t, before_why == "" && after_why == "" && string(before_pause[:]) == string(after_pause[:]))
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_control_history", nil, nil, nil), sql.OK)
	testing.expect_value(t, control(&store, action, &output, 103), sql.OK)
	testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[1].payload) == .S_MonitorInstanceControlled)
	ack_revision, _ := endian.get_u64(output.frames[1].payload[22:], .Big)
	testing.expect_value(t, ack_revision, u64(103))
	paused, _, _ := db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, paused.state.paused && paused.state.incident_open && paused.state.failures == 0 && paused.state.last_value == 3)
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	action.correlation_id = 88
	testing.expect_value(t, control(&store, action, &output, 900), sql.OK)
	testing.expect(t, output.count == 1 && output.frames[0].payload[30] == 1)
	correlation, _ := endian.get_u32(output.frames[0].payload[2:], .Big); testing.expect_value(t, correlation, u32(88))
	testing.expect_value(t, control(&store, action, &output, 104, actor = "bob"), sql.CONSTRAINT)
	run.sequence = 3; rows[0].condition = 0
	testing.expect_value(t, apply(&store, run, &output, 104), sql.CONSTRAINT) // In-flight old revision fenced.
	run.revision = 103
	testing.expect_value(t, apply(&store, run, &output, 104), sql.OK)
	still_paused, _, _ := db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, still_paused == paused)
	b, _, _ := db.get_monitor_instance(&store, "w", 1, "disk-b")
	testing.expect(t, b.state.incident_open) // Manual action did not reset the other instance's streak.
	action.revision = 103; action.action = 1
	testing.expect_value(t, control(&store, action, &output, 105), sql.OK)
	run.revision = 105; run.sequence = 4
	testing.expect_value(t, apply(&store, run, &output, 106), sql.OK)
	a, _, _ = db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, a.state.incident_open && a.state.recoveries == 1)
	action.revision = 105; action.action = 0
	testing.expect_value(t, control(&store, action, &output, 107), sql.OK)
	action.revision = 107; action.action = 1
	testing.expect_value(t, control(&store, action, &output, 108), sql.OK)
	run.revision = 108; run.sequence = 5
	testing.expect_value(t, apply(&store, run, &output, 109), sql.OK)
	a, _, _ = db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, a.state.incident_open && a.state.recoveries == 1) // Recovery restarted after pause.
	// Retire a paused, firing instance. Inject failure after state/episode writes.
	action.revision = 108; action.action = 0
	testing.expect_value(t, control(&store, action, &output, 110), sql.OK)
	action.revision = 110; action.action = 2
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"CREATE TEMP TRIGGER reject_removed BEFORE UPDATE ON assets WHEN NEW.asset_type=16 BEGIN SELECT RAISE(ABORT,'injected'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	before, why := sqlite_command_snapshot(&store); defer delete(before)
	testing.expect_value(t, why, "")
	testing.expect_value(t, control(&store, action, &output, 111), sql.CONSTRAINT)
	after, why2 := sqlite_command_snapshot(&store); defer delete(after)
	testing.expect(t, why2 == "" && string(before[:]) == string(after[:]))
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_removed", nil, nil, nil), sql.OK)
	testing.expect_value(t, control(&store, action, &output, 111), sql.OK)
	testing.expect(t, output.count == 3)
	closed, parse_err := pr.parseAssetUpdatedMessage(output.frames[0].payload)
	testing.expect(t, parse_err == nil && strings.contains(string(closed.asset.preview), `"status":"removed"`))
	old_incident := closed.asset.asset_id
	a, _, _ = db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, a.state.retired && !a.state.paused && !a.state.incident_open && a.state.episode == 1)
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, control(&store, action, &output, 112), sql.OK)
	testing.expect(t, output.count == 1 && output.frames[0].payload[30] == 1)
	action.revision = 111; action.action = 1
	testing.expect_value(t, control(&store, action, &output, 112), sql.CONSTRAINT) // Only a present result reactivates.
	run.revision = 108; run.sequence = 6; rows[0].condition = 1
	testing.expect_value(t, apply(&store, run, &output, 112), sql.CONSTRAINT)
	run.revision = 111; run.failed = true; run.observations = nil
	testing.expect_value(t, apply(&store, run, &output, 112), sql.OK)
	run.failed = false; run.sequence = 7
	testing.expect_value(t, apply(&store, run, &output, 113), sql.OK)
	a, _, _ = db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, a.state.retired && a.state.last_sequence == 5)
	run.sequence = 8; run.observations = rows[:]
	testing.expect_value(t, apply(&store, run, &output, 114), sql.OK)
	a, _, _ = db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, a.id == action.instance_id && !a.state.retired && !a.state.incident_open && a.state.failures == 1)
	run.sequence = 9
	testing.expect_value(t, apply(&store, run, &output, 115), sql.OK)
	created, create_err := pr.parseAssetCreatedMessage(output.frames[0].payload)
	testing.expect(t, create_err == nil && created.asset.asset_id != old_incident)
	// Retrying the last retirement after reactivation acknowledges its old result,
	// without retiring the new episode or generating another history event.
	retire_retry := action; retire_retry.revision = 110; retire_retry.action = 2
	testing.expect_value(t, control(&store, retire_retry, &output, 116), sql.OK)
	testing.expect(t, output.count == 1 && output.frames[0].payload[30] == 1)
	a, _, _ = db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, !a.state.retired && a.state.incident_open && a.state.episode == 2)
	{
		arena: virtual.Arena
		if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		old, old_found, old_rc := sqlite_read_asset(&store, "w", "alice", old_incident, true)
		testing.expect(t, old_found && old_rc == sql.OK && strings.contains(string(old.preview), `"status":"removed"`))
	}
	// Pause frees a slot; a different identity may use it. Resume must respect capacity.
	action.action = 0
	testing.expect_value(t, control(&store, action, &output, 116), sql.OK)
	large: [1023]pr.Monitor_Observation
	for &row, i in large {row = {fmt.aprintf("new%d", i), 0, 50}}
	defer for row in large {delete(row.identity)}
	run.revision = 116; run.sequence = 10; run.observations = large[:]
	testing.expect_value(t, apply(&store, run, &output, 117), sql.OK)
	action.revision = 116; action.action = 1
	testing.expect_value(t, control(&store, action, &output, 118), sql.TOOBIG)
	// Retiring another active instance frees the slot without deleting its history.
	action.instance_id = b.id; action.action = 2
	testing.expect_value(t, control(&store, action, &output, 118), sql.OK)
	action.revision = 118; action.instance_id = a.id; action.action = 1
	testing.expect_value(t, control(&store, action, &output, 119), sql.OK)
	a, _, _ = db.get_monitor_instance(&store, "w", 1, "disk-a")
	testing.expect(t, !a.state.paused && a.state.incident_open && a.state.freshness == .Unknown)
	// A manual fence must not hide a configuration change awaiting its first run.
	single := [1]pr.Monitor_Observation{{"new0", 1, 2}}
	run.revision = 119; run.sequence = 11; run.observations = single[:]
	testing.expect_value(t, apply(&store, run, &output, 120), sql.OK)
	changed, allocated := strings.replace_all(preview, "Disk", "Disk edited"); defer if allocated do delete(changed)
	n = pr.serializeTransactionAssetPatch(
		{asset = {.Existing, .Asset, 1}, if_updated_at = 119, present = pr.TRANSACTION_ASSET_PATCH_PREVIEW, preview = transmute([]byte)changed},
		wire[:],
	)
	testing.expect_value(t, sqlite_command_model_apply(&store, "w", 121, {{.AssetPatch, wire[:n]}}, {1}), "")
	action.revision = 121; action.action = 0
	testing.expect_value(t, control(&store, action, &output, 122), sql.OK)
	run.revision = 122; run.sequence = 12
	testing.expect_value(t, apply(&store, run, &output, 123), sql.OK)
	new0, _, _ := db.get_monitor_instance(&store, "w", 1, "new0")
	testing.expect(t, new0.state.failures == 1 && !new0.state.incident_open)
}

@(test)
test_sqlite_incident_human_actions :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-incident-actions-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	output := db.Command_Output {
		limit = 1024 * 1024,
	}; defer db.destroy_command_output(&output)
	execute :: proc(
		store: ^db.Store,
		wire: []byte,
		output: ^db.Command_Output,
		at: i64,
		actor := "alice",
		workspace := "w",
		subject := "user-alice",
	) -> c.int {
		request := db.Request {
			opcode    = pr.get_opcode(wire),
			workspace = workspace,
			actor     = actor,
			subject   = subject,
			timestamp = at,
			body      = wire[2:],
		}
		db.destroy_command_output(output); output.limit = 1024 * 1024
		if rc := db.begin(store); rc != sql.OK do return rc
		rc := sqlite_execute_task_command(store, &request, output)
		if rc != sql.OK {db.rollback(store); db.destroy_command_output(output); return rc}
		return db.commit(store)
	}
	act := proc(
		store: ^db.Store,
		r: pr.ActOnIncidentRequest,
		output: ^db.Command_Output,
		at: i64,
		actor := "alice",
		workspace := "w",
		subject := "user-alice",
	) -> c.int {
		wire: [128]byte
		n := pr.serializeActOnIncidentRequest(r, wire[:]); if n < 2 do return sql.MISUSE
		return execute(store, wire[:n], output, at, actor, workspace, subject)
	}
	run := proc(store: ^db.Store, output: ^db.Command_Output, sequence: u64, condition: u8, at: i64) -> c.int {
		wire: [128]byte
		rows := [1]pr.Monitor_Observation{{"host=a;mount=/data", condition, 7}}
		n := pr.serializeApplyMonitorRunRequest({monitor_id = 1, revision = 100, sequence = sequence, observations = rows[:]}, wire[:])
		return execute(store, wire[:n], output, at, "checker", subject = "")
	}
	check := proc(t: ^testing.T, store: ^db.Store, id: u64, status, by, at, assignee: string) {
		arena: virtual.Arena
		if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		a, found, rc := sqlite_read_asset(store, "w", "alice", id, true)
		if !testing.expect(t, found && rc == sql.OK) do return
		r: Incident_Record
		testing.expect(t, json.unmarshal(a.preview, &r) == nil)
		testing.expect_value(t, r.status, status)
		testing.expect_value(t, r.acknowledged_by, by)
		testing.expect_value(t, r.acknowledged_at, at)
		testing.expect_value(t, r.assigned_to, assignee)
		testing.expect_value(t, string(a.payload), "host=a;mount=/data")
	}
	wire: [1024]byte
	preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":60,"timeout_ns":10,"failures":1,"recoveries":1,"missing":3}`
	payload := `{"kind":"http"}`
	n := pr.serializeCreateAssetRequest(
		{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
		wire[:],
	)
	testing.expect_value(t, execute(&store, wire[:n], &output, 100), sql.OK)
	testing.expect_value(t, run(&store, &output, 1, 1, 101), sql.OK)
	state_before, _, _ := db.get_monitor_instance(&store, "w", 1, "host=a;mount=/data")
	action := pr.ActOnIncidentRequest{77, 2, 101, 0, ""}
	testing.expect_value(t, act(&store, action, &output, 102, workspace = "other"), sql.CONSTRAINT)
	action.incident_id = 1; action.revision = 100
	testing.expect_value(t, act(&store, action, &output, 102), sql.CONSTRAINT) // A Monitor is not an Incident.
	action.incident_id = 2; action.revision = 101
	testing.expect_value(t, act(&store, action, &output, 102), sql.OK)
	testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[1].payload) == .S_IncidentActionApplied)
	ack_revision, _ := endian.get_u64(output.frames[1].payload[14:], .Big); testing.expect_value(t, ack_revision, u64(102))
	check(t, &store, 2, "firing", "alice", "102", "")
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	action.correlation_id = 88
	snapshot, why := sqlite_command_snapshot(&store); defer delete(snapshot)
	testing.expect_value(t, act(&store, action, &output, 900), sql.OK)
	testing.expect(t, output.count == 1 && output.frames[0].payload[22] == 1)
	corr, _ := endian.get_u32(output.frames[0].payload[2:], .Big); testing.expect_value(t, corr, u32(88))
	replayed, replay_why := sqlite_command_snapshot(&store); defer delete(replayed)
	testing.expect(t, why == "" && replay_why == "" && string(snapshot[:]) == string(replayed[:]))
	testing.expect_value(t, act(&store, action, &output, 103, subject = "different-user"), sql.CONSTRAINT)
	action.action = 1; action.assignee = "carol"
	testing.expect_value(t, act(&store, action, &output, 103, actor = "bob", subject = "user-bob"), sql.CONSTRAINT) // Lost concurrent edit.
	action.revision = 102
	testing.expect_value(
		t,
		sql.exec(store.db, "CREATE TEMP TRIGGER reject_incident_action BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'injected'); END", nil, nil, nil),
		sql.OK,
	)
	before, before_why := sqlite_command_snapshot(&store); defer delete(before)
	testing.expect_value(t, act(&store, action, &output, 103), sql.CONSTRAINT)
	after, after_why := sqlite_command_snapshot(&store); defer delete(after)
	testing.expect(t, before_why == "" && after_why == "" && string(before[:]) == string(after[:]))
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_incident_action", nil, nil, nil), sql.OK)
	testing.expect_value(t, act(&store, action, &output, 103, actor = "bob", subject = "user-bob"), sql.OK)
	check(t, &store, 2, "firing", "alice", "102", "carol")
	action.revision = 103; action.action = 0; action.assignee = ""
	testing.expect_value(t, act(&store, action, &output, 104, actor = "bob", subject = "user-bob"), sql.OK)
	check(t, &store, 2, "firing", "alice", "102", "carol") // The first acknowledgment remains.
	action.revision = 104; action.action = 1
	testing.expect_value(t, act(&store, action, &output, 105), sql.OK)
	check(t, &store, 2, "firing", "alice", "102", "")
	action.revision = 105; action.assignee = "dave"
	testing.expect_value(t, act(&store, action, &output, 106), sql.OK)
	state_after, _, _ := db.get_monitor_instance(&store, "w", 1, "host=a;mount=/data")
	testing.expect(t, state_before == state_after) // Human actions do not touch evaluator state.
	testing.expect_value(t, run(&store, &output, 2, 0, 107), sql.OK) // Same Monitor revision still accepted.
	check(t, &store, 2, "recovered", "alice", "102", "dave")
	testing.expect_value(t, act(&store, action, &output, 108), sql.CONSTRAINT) // Recovery invalidated the old receipt.
	action.revision = 107; action.assignee = "carol"
	testing.expect_value(t, act(&store, action, &output, 108), sql.OK) // Closed incidents still support work assignment.
	testing.expect_value(t, run(&store, &output, 3, 1, 109), sql.OK)
	check(t, &store, 3, "firing", "", "", "") // No human fields inherited by a new episode.
	action.incident_id = 3; action.revision = 109; action.action = 0; action.assignee = ""
	testing.expect_value(t, act(&store, action, &output, 110, actor = "bob", subject = "user-bob"), sql.OK)
	action.revision = 110; action.action = 1; action.assignee = "carol"
	testing.expect_value(t, act(&store, action, &output, 111), sql.OK)
	n = pr.serializeControlMonitorInstanceRequest({99, 1, 100, state_before.id, 2}, wire[:])
	testing.expect_value(t, execute(&store, wire[:n], &output, 112), sql.OK)
	check(t, &store, 3, "removed", "bob", "110", "carol")
	check(t, &store, 2, "recovered", "alice", "102", "carol")
	// Verify the persisted audit identifies the authenticated person, not the assignee.
	{
		s: ^sql.Statement
		testing.expect_value(
			t,
			sql.prepare_v2(
				store.db,
				"SELECT body FROM history WHERE json_extract(body,'$.action')='assigned' AND json_extract(body,'$.actorName')='bob'",
				-1,
				&s,
				nil,
			),
			sql.OK,
		)
		defer sql.finalize(s)
		testing.expect_value(t, sql.step(s), sql.ROW)
		testing.expect(t, strings.contains(string(sql.column_bytes_view(s, 0)), `"actorId":"user-bob"`))
		testing.expect_value(t, sql.step(s), sql.DONE)
	}
}

@(test)
test_sqlite_monitor_maintenance :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-monitor-maintenance-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	output: db.Command_Output
	defer db.destroy_command_output(&output)
	execute :: proc(store: ^db.Store, request: db.Request, output: ^db.Command_Output) -> c.int {
		db.destroy_command_output(output); output.limit = 1024 * 1024
		if rc := db.begin(store); rc != sql.OK do return rc
		r := request
		rc := sqlite_execute_task_command(store, &r, output)
		if rc != sql.OK {db.rollback(store); db.destroy_command_output(output); return rc}
		return db.commit(store)
	}
	// Two workspaces and different policies: elapsed time alone must not mark
	// the slow monitor stale.
	for workspace, i in ([2]string{"a", "z"}) {
		preview := fmt.aprintf(
			"%s%d%s",
			`{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":`,
			i == 0 ? 10 : 100,
			`,"timeout_ns":2,"failures":1,"recoveries":5,"missing":3}`,
		)
		defer delete(preview)
		payload := `{"kind":"http"}`
		wire: [1024]byte
		n := pr.serializeCreateAssetRequest(
			{asset_type = .Monitor, preview = transmute([]byte)preview, payload = transmute([]byte)payload, payload_raw_len = u32(len(payload))},
			wire[:],
		)
		testing.expect_value(
			t,
			execute(
				&store,
				{operation = .Command, opcode = .C_CreateAsset, workspace = workspace, actor = "checker", timestamp = 100, body = wire[2:n]},
				&output,
			),
			sql.OK,
		)
		if !testing.expect(t, output.count == 2 && pr.get_opcode(output.frames[0].payload) == .S_AssetCreated, preview) do return
	}
	// First monitor is asset 1, second is 2; instance IDs use their own sequence.
	rows: [MONITOR_MAINTENANCE_BATCH + 3]pr.Monitor_Observation
	for &row, i in rows {
		row = {fmt.aprintf("disk-%d", i), 1, f64(i + 7)}
	}
	defer for row in rows do delete(row.identity)
	run_wire: [8192]byte
	n := pr.serializeApplyMonitorRunRequest({monitor_id = 1, revision = 100, sequence = 1, observations = rows[:]}, run_wire[:])
	run := db.Request {
		operation = .Command,
		opcode    = .C_ApplyMonitorRun,
		workspace = "a",
		actor     = "checker",
		timestamp = 101,
		body      = run_wire[2:n],
	}
	testing.expect_value(t, execute(&store, run, &output), sql.OK)
	slow_wire: [128]byte
	n = pr.serializeApplyMonitorRunRequest({monitor_id = 2, revision = 100, sequence = 1, observations = rows[:1]}, slow_wire[:])
	testing.expect_value(
		t,
		execute(
			&store,
			{operation = .Command, opcode = .C_ApplyMonitorRun, workspace = "z", actor = "checker", timestamp = 101, body = slow_wire[2:n]},
			&output,
		),
		sql.OK,
	)
	// Human fields must survive maintenance on the first incident (asset 3).
	ack_wire: [128]byte
	n = pr.serializeActOnIncidentRequest({incident_id = 3, revision = 101, action = 0}, ack_wire[:])
	testing.expect_value(
		t,
		execute(
			&store,
			{operation = .Command, opcode = .C_ActOnIncident, workspace = "a", actor = "alice", subject = "user-alice", timestamp = 102, body = ack_wire[2:n]},
			&output,
		),
		sql.OK,
	)
	before, _, _ := db.get_monitor_instance(&store, "a", 1, rows[0].identity)
	maintenance := db.Request {
		operation = .Monitor_Maintenance,
		timestamp = 132,
	}
	// One nanosecond before the boundary: no writes, even with a full page.
	snapshot, why := sqlite_command_snapshot(&store); defer delete(snapshot)
	testing.expect_value(t, execute(&store, maintenance, &output), sql.OK)
	testing.expect_value(t, output.monitor_cursor, u64(MONITOR_MAINTENANCE_BATCH))
	unchanged, why2 := sqlite_command_snapshot(&store); defer delete(unchanged)
	testing.expect(t, why == "" && why2 == "" && string(snapshot[:]) == string(unchanged[:]))
	// A late failure must undo earlier rows, not leave a partial maintenance page.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"CREATE TEMP TRIGGER reject_stale BEFORE UPDATE ON monitor_instances WHEN NEW.id=x'0000000000000002' BEGIN SELECT RAISE(ABORT,'injected'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	maintenance.timestamp = 133
	testing.expect_value(t, execute(&store, maintenance, &output), sql.CONSTRAINT)
	after_failure, why3 := sqlite_command_snapshot(&store); defer delete(after_failure)
	testing.expect(t, why3 == "" && string(snapshot[:]) == string(after_failure[:]))
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_stale", nil, nil, nil), sql.OK)
	testing.expect_value(t, execute(&store, maintenance, &output), sql.OK)
	testing.expect(t, output.monitor_cursor == MONITOR_MAINTENANCE_BATCH && output.count == 0)
	maintenance.monitor_cursor = output.monitor_cursor
	maintenance.monitor_through = output.monitor_through
	after, _, _ := db.get_monitor_instance(&store, "a", 1, rows[0].identity)
	expected := before
	expected.state.freshness = .No_Data; expected.state.failures, expected.state.recoveries = 0, 0
	testing.expect_value(t, after, expected)
	tail, _, _ := db.get_monitor_instance(&store, "a", 1, rows[len(rows) - 1].identity)
	testing.expect_value(t, tail.state.freshness, .Current) // The batch really is bounded.
	testing.expect_value(t, execute(&store, maintenance, &output), sql.OK)
	testing.expect_value(t, output.monitor_cursor, u64(0))
	tail, _, _ = db.get_monitor_instance(&store, "a", 1, rows[len(rows) - 1].identity)
	testing.expect_value(t, tail.state.freshness, .No_Data)
	slow, _, _ := db.get_monitor_instance(&store, "z", 2, rows[0].identity)
	testing.expect_value(t, slow.state.freshness, .Current)
	// Retry confirms the original evaluation without refreshing stale state.
	testing.expect_value(t, execute(&store, run, &output), sql.OK)
	testing.expect(t, output.count == 1 && output.frames[0].payload[22] == 1)
	after, _, _ = db.get_monitor_instance(&store, "a", 1, rows[0].identity)
	testing.expect_value(t, after, expected)
	// Already-stale rows are no-ops. Paused/retired rows retain Unknown, while
	// a disabled monitor's remaining active samples still age using its policy.
	testing.expect_value(t, db.begin(&store), sql.OK)
	_, _, pause_rc := db.control_monitor_instance(&store, "a", 1, rows[1].identity, 0, 140)
	_, _, retire_rc := db.control_monitor_instance(&store, "a", 1, rows[2].identity, 2, 140)
	testing.expect(t, pause_rc == sql.OK && retire_rc == sql.OK)
	testing.expect_value(
		t,
		sql.exec(store.db, "UPDATE assets SET preview=CAST(json_set(preview,'$.enabled',json('false')) AS BLOB) WHERE asset_type=15", nil, nil, nil),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	maintenance.monitor_cursor = 0; maintenance.monitor_through = 0; maintenance.timestamp = 403
	testing.expect_value(t, execute(&store, maintenance, &output), sql.OK)
	slow, _, _ = db.get_monitor_instance(&store, "z", 2, rows[0].identity)
	testing.expect_value(t, slow.state.freshness, .No_Data)
	paused, _, _ := db.get_monitor_instance(&store, "a", 1, rows[1].identity)
	retired, _, _ := db.get_monitor_instance(&store, "a", 1, rows[2].identity)
	testing.expect(t, paused.state.paused && paused.state.freshness == .Unknown && retired.state.retired && retired.state.freshness == .Unknown)
	stable, stable_why := sqlite_command_snapshot(&store); defer delete(stable)
	testing.expect_value(t, execute(&store, maintenance, &output), sql.OK)
	stable_again, stable_again_why := sqlite_command_snapshot(&store); defer delete(stable_again)
	testing.expect(t, stable_why == "" && stable_again_why == "" && string(stable[:]) == string(stable_again[:]))
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	after, _, _ = db.get_monitor_instance(&store, "a", 1, rows[0].identity)
	testing.expect_value(t, after, expected)
	{
		arena: virtual.Arena
		if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		incident, found, read_rc := sqlite_read_asset(&store, "a", "alice", 3, true)
		record: Incident_Record
		testing.expect(t, found && read_rc == sql.OK && json.unmarshal(incident.preview, &record) == nil)
		testing.expect(t, incident.updated_at == 102 && record.status == "firing" && record.acknowledged_by == "alice" && record.acknowledged_at == "102")
	}
}

@(test)
test_sqlite_monitor_maintenance_growing_scan :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-monitor-growth-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/model.db", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	preview := `{"version":1,"name":"Disk","evaluator":"checker","enabled":true,"interval_ns":10,"timeout_ns":2,"failures":5,"recoveries":5,"missing":3}`
	payload := `{"kind":"tcp"}`
	asset := pr.Asset {
		asset_id        = 1,
		asset_type      = .Monitor,
		preview         = transmute([]byte)preview,
		payload         = transmute([]byte)payload,
		payload_raw_len = u32(len(payload)),
	}
	testing.expect_value(t, sqlite_put_asset(&store, "w", &asset, true), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	request := db.Request {
		operation = .Monitor_Maintenance,
		timestamp = 132,
	}
	output: db.Command_Output
	defer db.destroy_command_output(&output)
	// Add a full page before EVERY scan step. Without a fixed upper bound,
	// the second step consumes new IDs instead of completing the first scan.
	for step in 0 ..< 3 {
		testing.expect_value(t, db.begin(&store), sql.OK)
		for i in 0 ..< 64 {
			identity := fmt.aprintf("disk-%d", step * 64 + i); defer delete(identity)
			input := [1]db.Monitor_Evaluation{{1, identity, {5, 5, 3, 32}, {1, 101, .Failing, 7}}}
			result: [1]db.Monitor_Application
			testing.expect_value(t, db.apply_monitor_evaluations(&store, "w", input[:], result[:]), sql.OK)
		}
		// First scan has 65 rows, so its first fresh page must continue.
		if step == 0 {
			input := [1]db.Monitor_Evaluation{{1, "boundary", {5, 5, 3, 32}, {1, 101, .Failing, 7}}}
			result: [1]db.Monitor_Application
			testing.expect_value(t, db.apply_monitor_evaluations(&store, "w", input[:], result[:]), sql.OK)
		}
		testing.expect_value(t, db.commit(&store), sql.OK)
		db.destroy_command_output(&output)
		testing.expect_value(t, db.begin(&store), sql.OK)
		if step > 0 do request.timestamp = 133
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
		testing.expect_value(t, db.commit(&store), sql.OK)
		if step == 0 do testing.expect(t, output.monitor_cursor == 64 && output.monitor_through == 65)
		if step == 1 do testing.expect(t, output.monitor_cursor == 0 && output.monitor_through == 0)
		request.monitor_cursor = output.monitor_cursor
		request.monitor_through = output.monitor_through
	}
	first, found, read_rc := db.get_monitor_instance(&store, "w", 1, "disk-0")
	testing.expect(t, found && read_rc == sql.OK && first.state.freshness == .No_Data && first.state.failures == 0)
}
