package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import mon "monitoring"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Read in the executor's snapshot. The sequence survives configuration changes;
// a fresh sidecar must not restart at one or derive it from its wall clock.
sqlite_get_monitor_state :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	r, err := pr.parseGetMonitorStateRequest(request.body)
	if err != nil do return sql.CONSTRAINT
	monitor, found, rc := sqlite_read_asset(store, request.workspace, request.actor, r.monitor_id, true)
	if rc != sql.OK do return rc
	if !found do return sql.CONSTRAINT
	config, policy, valid := parse_monitor_config(&monitor, context.allocator)
	if !valid || config.evaluator != request.actor do return sql.CONSTRAINT
	s: ^sql.Statement
	rc = sql.prepare_v2(store.db, "SELECT sequence FROM monitor_runs WHERE workspace=?1 AND monitor_id=?2", -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
	sequence: u64
	rc = sql.step(s)
	if rc == sql.ROW {
		if sequence, rc = sql.column_id(s, 0); rc != sql.OK do return rc
	} else if rc != sql.DONE do return rc
	if r.detailed {
		if r.revision != monitor.updated_at || r.sequence != sequence do return sql.CONSTRAINT
		return sqlite_monitor_snapshot_page(store, request, output, r, config.enabled, policy, backing)
	}
	context.allocator = backing
	buf, status := db.command_frame(output, 30)
	if status != sql.OK do return status
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_MonitorState))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.monitor_id)
	endian.put_u64(buf[14:], .Big, u64(monitor.updated_at))
	endian.put_u64(buf[22:], .Big, sequence)
	return sql.OK
}

sqlite_monitor_ack :: proc(output: ^db.Command_Output, r: pr.ApplyMonitorRunRequest, replayed: bool) -> c.int {
	buf, rc := db.command_frame(output, 23)
	if rc != sql.OK do return rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_MonitorRunApplied))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.monitor_id)
	endian.put_u64(buf[14:], .Big, r.sequence)
	buf[22] = replayed ? 1 : 0
	return sql.OK
}

// Executor transaction owns state, episodes, Incident assets, history and receipt.
// Any failure discards every write and output frame before the worker sees it.
sqlite_apply_monitor_run :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	rows: [pr.MAX_MONITOR_INSTANCES]pr.Monitor_Observation
	r, err := pr.parseApplyMonitorRunRequest(request.body, rows[:])
	if err != nil || request.timestamp <= 0 do return sql.CONSTRAINT
	monitor, found, rc := sqlite_read_asset(store, request.workspace, request.actor, r.monitor_id, true)
	if rc != sql.OK do return rc
	if !found || monitor.asset_type != .Monitor || monitor.updated_at != r.revision do return sql.CONSTRAINT
	config, policy, valid := parse_monitor_config(&monitor, context.allocator)
	if !valid || !config.enabled || request.actor != config.evaluator do return sql.CONSTRAINT
	// A source change fences runs through the revision pinned in the Monitor.
	// Check on the writer, not just in the sidecar's earlier read snapshot.
	ref: Monitor_Source_Ref
	if json.unmarshal(monitor.payload, &ref, allocator = context.allocator) != nil do return sql.CONSTRAINT
	if ref.kind == "victoriametrics" || ref.kind == "victorialogs" {
		id, _ := strconv.parse_u64(ref.source_id)
		revision, _ := strconv.parse_i64(ref.source_revision)
		source, exists, source_rc := sqlite_read_asset(store, request.workspace, request.actor, id, true)
		if source_rc != sql.OK do return source_rc
		if !exists || source.updated_at != revision do return sql.CONSTRAINT
		source_config, source_valid := parse_monitor_source(&source, context.allocator)
		if !source_valid || source_config.kind != ref.kind do return sql.CONSTRAINT
	}
	last_sequence: u64
	last_revision, last_at: i64
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT sequence,revision,evaluated_at,receipt FROM monitor_runs WHERE workspace=?1 AND monitor_id=?2", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc == sql.ROW {
			if last_sequence, rc = sql.column_id(s, 0); rc != sql.OK do return rc
			last_revision, last_at = sql.column_int64(s, 1), sql.column_int64(s, 2)
			if r.sequence <= last_sequence {
				if r.sequence != last_sequence || string(sql.column_bytes_view(s, 3)) != string(request.body[4:]) do return sql.CONSTRAINT
				context.allocator = backing
				return sqlite_monitor_ack(output, r, true)
			}
		} else if rc != sql.DONE do return rc
	}
	if last_at == max(i64) do return sql.FULL
	at := max(request.timestamp, last_at + 1)
	inputs: [pr.MAX_MONITOR_INSTANCES]db.Monitor_Evaluation
	count := len(r.observations)
	seen := make(map[string]bool)
	for row, i in r.observations {
		if seen[row.identity] do return sql.CONSTRAINT
		seen[row.identity] = true
		inputs[i] = {r.monitor_id, row.identity, policy, {r.sequence, at, mon.Observation(row.condition), row.value}}
	}
	// Bound active plus returned identities, independently of retained history.
	// A returned retired identity is looked up normally and reactivated below.
	{
		s: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			"SELECT identity FROM monitor_instances WHERE workspace=?1 AND monitor_id=?2 AND paused=0 AND retired=0 LIMIT 1025",
			-1,
			&s,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
		known := 0
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			known += 1; if known > pr.MAX_MONITOR_INSTANCES do return sql.TOOBIG
			identity := string(sql.column_bytes_view(s, 0))
			if seen[identity] do continue
			if count == len(inputs) do return sql.TOOBIG
			copy_id := strings.clone(identity)
			inputs[count] = {r.monitor_id, copy_id, policy, {r.sequence, at, r.failed ? .Evaluation_Error : .Absent, 0}}
			count += 1
		}
	}
	if last_revision != 0 && last_revision != r.revision {
		if rc = sqlite_projection_write(store, "UPDATE monitor_instances SET failures=0,recoveries=0,missing=0 WHERE workspace=?1 AND monitor_id=?2 AND paused=0 AND retired=0", request.workspace, &monitor, nil); rc != sql.OK do return rc
	}
	for input in inputs[:count] {
		before, exists, read_rc := db.get_monitor_instance(store, request.workspace, r.monitor_id, input.identity)
		if read_rc != sql.OK do return read_rc
		if exists && (before.state.paused || before.state.retired && (input.evaluation.observation == .Absent || input.evaluation.observation == .Evaluation_Error)) do continue
		application: [1]db.Monitor_Application
		one := [1]db.Monitor_Evaluation{input}
		if rc = db.apply_monitor_evaluations(store, request.workspace, one[:], application[:]); rc != sql.OK do return rc
		after, _, state_rc := db.get_monitor_instance(store, request.workspace, r.monitor_id, input.identity)
		if state_rc != sql.OK do return state_rc
		if .Opened in application[0].changes || .Recovered in application[0].changes {
			context.allocator = backing
			rc = sqlite_monitor_incident(store, request, &monitor, config.name, input.identity, after, .Opened in application[0].changes, at, output)
			context.allocator = virtual.arena_allocator(&arena)
			if rc != sql.OK do return rc
		}
	}
	if rc = sqlite_projection_write(store, `INSERT INTO monitor_runs VALUES(?1,?2,?3,?4,?5,?6)
 ON CONFLICT(workspace,monitor_id) DO UPDATE SET sequence=excluded.sequence,revision=excluded.revision,evaluated_at=excluded.evaluated_at,receipt=excluded.receipt`, request.workspace, &monitor, {r.sequence, r.revision, at, string(request.body[4:])}); rc != sql.OK do return rc
	context.allocator = backing
	return sqlite_monitor_ack(output, r, false)
}

sqlite_monitor_incident :: proc(
	store: ^db.Store,
	request: ^db.Request,
	monitor: ^pr.Asset,
	name, identity: string,
	instance: db.Monitor_Instance,
	opened: bool,
	at: i64,
	output: ^db.Command_Output,
	removed := false,
) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	a, old: pr.Asset
	record: Incident_Record
	rc := sql.OK
	if opened {
		id, id_rc := db.next_id(store, .Asset); if id_rc != sql.OK do return id_rc
		a = {
			asset_type      = .Incident,
			asset_id        = id,
			owner           = transmute([]byte)request.actor,
			created_at      = at,
			updated_at      = at,
			payload         = transmute([]byte)identity,
			payload_raw_len = u32(len(identity)),
		}
		record = {
			version     = 1,
			title       = fmt.aprintf("%s · %s", name, pr.history_short_label(identity, context.allocator)),
			monitor_id  = fmt.aprintf("%d", monitor.asset_id),
			instance_id = fmt.aprintf("%d", instance.id),
			episode     = fmt.aprintf("%d", instance.state.episode),
			status      = "firing",
			opened_at   = fmt.aprintf("%d", at),
		}
	} else {
		s: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT incident_id FROM monitor_episodes WHERE workspace=?1 AND instance_id=?2 AND episode=?3", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, instance.id); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 3, instance.state.episode); rc != sql.OK do return rc
		if sql.step(s) != sql.ROW do return sql.CORRUPT
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		found: bool
		old, found, rc = sqlite_read_asset(store, request.workspace, request.actor, id, true)
		if rc != sql.OK do return rc
		if !found || old.asset_type != .Incident || json.unmarshal(old.preview, &record, allocator = context.allocator) != nil do return sql.CORRUPT
		if old.updated_at == max(i64) do return sql.FULL
		a = old; a.updated_at = max(at, old.updated_at + 1)
		record.status = removed ? "removed" : "recovered"; record.closed_at = fmt.aprintf("%d", at)
	}
	preview, json_err := json.marshal(record)
	if json_err != nil do return sql.CONSTRAINT
	a.preview = preview
	if len(preview) > pr.MAX_PREVIEW_LENGTH do return sql.TOOBIG
	if rc = sqlite_put_asset(store, request.workspace, &a, opened); rc != sql.OK do return rc
	if opened {
		key := pr.Asset {
			asset_id = instance.id,
		}
		if rc = sqlite_projection_write(store, "UPDATE monitor_episodes SET incident_id=?4 WHERE workspace=?1 AND instance_id=?2 AND episode=?3", request.workspace, &key, {instance.state.episode, u64(a.asset_id)}); rc != sql.OK do return rc
	}
	if rc = sqlite_asset_history(store, request, &old, &a, opened); rc != sql.OK do return rc
	// Every technical transition, including retirement, invalidates pending snapshots
	// for old routes too. Human fields are not part of the open-ID snapshot.
	snapshot_version, version_rc := db.next_monitor_delivery_version(store)
	if version_rc != sql.OK do return version_rc
	if rc = sqlite_projection_write(store, `UPDATE monitor_delivery_lanes SET version=?4,lost=min(lost+1,9223372036854775807),last_at=max(last_at,?3)
 WHERE workspace=?1 AND monitor_id=?2 AND stream=1 AND lost>0`, request.workspace, monitor, {at, snapshot_version}); rc != sql.OK do return rc
	if !removed {
		if rc = sqlite_monitor_webhook(store, request.workspace, monitor, &a, record, at); rc != sql.OK do return rc
	}
	context.allocator = backing
	if opened {
		msg := pr.AssetCreatedMessage {
			asset = a,
		}
		buf, frame_rc := db.command_frame(output, pr.getSizeAssetCreatedMessage(msg), .Subscribers); if frame_rc != sql.OK do return frame_rc
		return pr.serializeAssetCreatedMessage(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	msg := pr.AssetUpdatedMessage {
		asset = a,
	}
	buf, frame_rc := db.command_frame(output, pr.getSizeAssetUpdatedMessage(msg), .Subscribers); if frame_rc != sql.OK do return frame_rc
	return pr.serializeAssetUpdatedMessage(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
