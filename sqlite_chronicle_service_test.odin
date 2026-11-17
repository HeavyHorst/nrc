package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Requests cross the public serialized command boundary and a real transaction.
// The caller's test arena owns decoded responses.
sqlite_chronicle_service_call :: proc(
	t: ^testing.T,
	store: ^db.Store,
	q: pr.Chronicle_Request,
	access := pr.CHRONICLE_ACCESS_SERVICE | pr.CHRONICLE_ACCESS_READ,
	subject := "worker",
	workspace := "service",
	output_limit := 131072,
) -> (
	r: SQLite_Chronicle_Response,
	rc: c.int,
) {
	wire: [16384]byte
	n := pr.serializeChronicleRequest(q, 73, wire[:])
	if !testing.expect(t, n > 0) do return {}, sql.MISUSE
	request := db.Request {
		workspace        = workspace,
		subject          = subject,
		chronicle_access = access,
		opcode           = .C_Chronicle,
		body             = wire[2:n],
	}
	output := db.Command_Output {
		limit = output_limit,
	}
	defer db.destroy_command_output(&output)
	rc = db.begin(store)
	if rc != sql.OK do return
	rc = sqlite_execute_task_command(store, &request, &output)
	if rc == sql.OK do rc = db.commit(store)
	if rc != sql.OK {db.rollback(store); return}
	if !testing.expect_value(t, output.count, 1) do return
	frame := output.frames[0].payload
	testing.expect_value(t, pr.get_opcode(frame), pr.Opcode.S_Chronicle)
	testing.expect(t, json.unmarshal(frame[6:], &r) == nil)
	// Public collections are arrays even when empty, never JSON null.
	value, parse_err := json.parse(frame[6:])
	if testing.expect(t, parse_err == nil) {
		object, is_object := value.(json.Object)
		if testing.expect(t, is_object) {
			for key in ([4]string{"sources", "inputs", "entries", "gaps"}) {
				collection, exists := object[key]
				_, is_array := collection.(json.Array)
				testing.expect(t, exists && is_array, key)
			}
		}
	}
	return
}

sqlite_chronicle_service_seed :: proc(t: ^testing.T, store: ^db.Store) {
	wire: [4096]byte
	q := pr.CreateAssetRequest {
		asset_type      = .Note,
		preview         = transmute([]byte)string(`{"title":"Chronik"}`),
		payload         = transmute([]byte)string("Text"),
		payload_raw_len = 4,
	}
	n := pr.serializeCreateAssetRequest(q, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(store, "service", nrc_time_unix_nanos(), wire[:n]), sql.OK)
}

@(test)
test_chronicle_service_result_replay_delete_and_ack :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "chronicle-service-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	path := strings.clone_to_cstring(fmt.aprintf("%s/service.db", dir))
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	db.begin(&store); testing.expect_value(t, db.configure_chronicle(&store, {"service"}), sql.OK); db.commit(&store)
	sqlite_chronicle_service_seed(t, &store)
	claim := pr.Chronicle_Request {
		op       = "claim",
		consumer = pr.CHRONICLE_CONSUMER_VERSION,
		limit    = 2,
	}
	r, _ := sqlite_chronicle_service_call(t, &store, claim, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, r.status, "forbidden")
	r, rc = sqlite_chronicle_service_call(t, &store, claim)
	if !testing.expect_value(t, rc, sql.OK) || !testing.expect_value(t, r.status, "claimed") do return
	testing.expect_value(t, len(r.sources), 1)
	job := pr.Chronicle_Request {
		op         = "chunk",
		consumer   = claim.consumer,
		epoch      = r.epoch,
		generation = r.generation,
		sources    = r.sources,
		cursor     = r.sources[0],
		field      = 5,
		length     = 16,
	}
	chunk, _ := sqlite_chronicle_service_call(t, &store, job, subject = "other-worker")
	testing.expect_value(t, chunk.status, "forbidden")
	chunk, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, chunk.status, "ok"); testing.expect_value(t, chunk.chunk, "VGV4dA==")
	busy, _ := sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, busy.status, "busy")
	job.op = "reserve"; job.input_tokens = 777; job.output_tokens = 1000
	reserved, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, reserved.status, "reserved")
	reserved, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, reserved.status, "reserved")
	sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=777 AND output_tokens=1000 FROM chronicle_budgets")
	job.op = "commit"; job.outcome = "result"; job.summary = "Die Notiz wurde angelegt."; job.model = "fake"; job.prompt_version = "p1"; job.schema_version = "s1"
	for usage in ([4][2]u32{{778, 30}, {64, 1001}, {0, 30}, {64, 0}}) {
		job.input_tokens = usage[0]; job.output_tokens = usage[1]
		invalid, _ := sqlite_chronicle_service_call(t, &store, job)
		testing.expect_value(t, invalid.status, "invalid")
		sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=777 AND output_tokens=1000 FROM chronicle_budgets")
	}
	job.input_tokens = 64; job.output_tokens = 30
	// Output reservation failure must roll back the result AND raw deletion.
	_, rc = sqlite_chronicle_service_call(t, &store, job, output_limit = 1)
	testing.expect_value(t, rc, sql.TOOBIG)
	sqlite_projection_test_assert(t, &store, "SELECT (SELECT count(*) FROM chronicle_raw)=1 AND (SELECT state FROM chronicle_jobs)=0")
	sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=777 AND output_tokens=1000 FROM chronicle_budgets")
	result, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "committed"); testing.expect_value(t, result.summary, job.summary)
	sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=64 AND output_tokens=30 FROM chronicle_budgets")
	sqlite_projection_test_assert(t, &store, "SELECT raw_bytes=0 AND pending_inputs=0 FROM chronicle_workspaces")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM chronicle_raw")
	// Replay survives reopening and returns the stored result, not a second row.
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	result, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "committed"); testing.expect_value(t, result.summary, job.summary)
	sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=64 AND output_tokens=30 FROM chronicle_budgets")
	job.input_tokens = 63
	result, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "conflict")
	sqlite_projection_test_assert(t, &store, "SELECT input_tokens=64 AND output_tokens=30 FROM chronicle_budgets")
	job.input_tokens = 64
	job.summary = "changed"
	result, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "conflict")
	job.summary = "Die Notiz wurde angelegt."
	history := pr.Chronicle_Request {
		op    = "history",
		limit = 16,
	}
	page, _ := sqlite_chronicle_service_call(t, &store, history, access = pr.CHRONICLE_ACCESS_READ, subject = "reader")
	if testing.expect_value(
		t,
		len(page.entries),
		1,
	) {testing.expect_value(t, page.entries[0].summary, job.summary); testing.expect(t, page.entries[0].source_available)}
	testing.expect_value(t, page.entries[0].note_title, "Chronik")
	// Canonical source deletion retains the result, but disables its source link.
	wire: [128]byte
	note_id, _ := strconv.parse_u64(r.note_id)
	n := pr.serializeDeleteAssetRequest(0, note_id, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "service", nrc_time_unix_nanos(), wire[:n]), sql.OK)
	page, _ = sqlite_chronicle_service_call(t, &store, history)
	if testing.expect_value(t, len(page.entries), 1) {
		testing.expect(t, !page.entries[0].source_available)
		testing.expect_value(t, page.entries[0].summary, job.summary)
		testing.expect_value(t, page.entries[0].note_title, "Chronik")
	}
	other_page, _ := sqlite_chronicle_service_call(t, &store, history, workspace = "other")
	testing.expect_value(t, len(other_page.entries), 0)
	delete_request := pr.Chronicle_Request {
		op      = "delete",
		note_id = r.note_id,
	}
	denied, _ := sqlite_chronicle_service_call(t, &store, delete_request)
	testing.expect_value(t, denied.status, "forbidden")
	deleted, _ := sqlite_chronicle_service_call(t, &store, delete_request, access = pr.CHRONICLE_ACCESS_DELETE, subject = "human")
	testing.expect_value(t, deleted.status, "deleted")
	result, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "deleted"); testing.expect_value(t, result.summary, "")
	page, _ = sqlite_chronicle_service_call(t, &store, history)
	testing.expect_value(t, len(page.entries), 0)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM chronicle_jobs WHERE state=3 AND length(summary)=0 AND length(model)=0")
	// No-relevant-change Ack is durable but not a visible history entry.
	sqlite_chronicle_service_seed(t, &store)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	job = pr.Chronicle_Request {
		op            = "reserve",
		consumer      = claim.consumer,
		epoch         = r.epoch,
		generation    = r.generation,
		sources       = r.sources,
		input_tokens  = 88,
		output_tokens = 1000,
	}
	sqlite_chronicle_service_call(t, &store, job)
	job.op = "commit"; job.outcome = "ack"; job.model = "fake"; job.prompt_version = "p1"; job.schema_version = "s1"
	job.input_tokens = 20; job.output_tokens = 11
	result, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "acknowledged")
	result, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "acknowledged")
	sqlite_projection_test_assert(t, &store, "SELECT calls=2 AND input_tokens=84 AND output_tokens=41 FROM chronicle_budgets")
	sqlite_projection_test_assert(t, &store, "SELECT (SELECT count(*) FROM chronicle_raw)=0 AND (SELECT count(*) FROM chronicle_jobs WHERE state=2)=1")
	status, _ := sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "status", note_id = r.note_id}, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, status.acknowledged, i64(1)); testing.expect_value(t, status.gap_count, i64(0)); testing.expect_value(t, status.pending, i64(0))
	page, _ = sqlite_chronicle_service_call(t, &store, history, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, len(page.entries), 0)
	testing.expect_value(t, page.cursor, "0")
	history.cursor = "18446744073709551615"
	page, _ = sqlite_chronicle_service_call(t, &store, history, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, len(page.entries), 0); testing.expect_value(t, page.cursor, history.cursor)
	gaps, _ := sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "gaps", limit = 16}, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, len(gaps.gaps), 0)
	testing.expect_value(t, gaps.cursor, "0")
}

@(test)
test_chronicle_service_usage_retry_and_reservation_day :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for scenario in ([3]string{"known_retry", "unknown_retry", "new_day"}) {
		dir, err := os.make_directory_temp("", "chronicle-usage-*", context.allocator)
		if !testing.expect(t, err == nil) do return
		defer os.remove_all(dir)
		store, rc := db.open(strings.clone_to_cstring(fmt.aprintf("%s/usage.db", dir)), create = true)
		if !testing.expect_value(t, rc, sql.OK) do return
		defer db.close(&store)
		db.begin(&store); db.configure_chronicle(&store, {"service"}); db.commit(&store)
		sqlite_chronicle_service_seed(t, &store)
		claim, _ := sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "claim", consumer = pr.CHRONICLE_CONSUMER_VERSION, limit = 1})
		if !testing.expect_value(t, claim.status, "claimed") do return
		job := pr.Chronicle_Request {
			op            = "reserve",
			consumer      = pr.CHRONICLE_CONSUMER_VERSION,
			epoch         = claim.epoch,
			generation    = claim.generation,
			sources       = claim.sources,
			input_tokens  = 777,
			output_tokens = 1000,
		}
		reserved, _ := sqlite_chronicle_service_call(t, &store, job)
		testing.expect_value(t, reserved.status, "reserved")
		job.op = "retry"; job.reason = "invalid_output"
		job.input_tokens = 64; job.output_tokens = 30
		if scenario == "unknown_retry" {
			job.reason = "timeout"; job.input_tokens = 0; job.output_tokens = 0
		}
		if scenario == "new_day" {
			// A later day's budget must never receive an old reservation's credit,
			// even if the wall clock returns to this live claim's day.
			testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_budgets SET day=day+1,input_tokens=333,output_tokens=444", nil, nil, nil), sql.OK)
			job.op = "commit"; job.outcome = "ack"; job.reason = ""
			job.model = "fake"; job.prompt_version = "p1"; job.schema_version = "s1"
		}
		result, _ := sqlite_chronicle_service_call(t, &store, job)
		testing.expect_value(t, result.status, scenario == "new_day" ? "acknowledged" : "released")
		// Retrying the terminal command cannot release budget again.
		sqlite_chronicle_service_call(t, &store, job)
		switch scenario {
		case "known_retry":
			sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=64 AND output_tokens=30 FROM chronicle_budgets")
		case "unknown_retry":
			sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=777 AND output_tokens=1000 FROM chronicle_budgets")
		case "new_day":
			sqlite_projection_test_assert(t, &store, "SELECT calls=1 AND input_tokens=333 AND output_tokens=444 FROM chronicle_budgets")
		}
	}
}

@(test)
test_chronicle_service_fencing_ttl_retry_and_watermark :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "chronicle-fences-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	path := strings.clone_to_cstring(fmt.aprintf("%s/fences.db", dir))
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	db.begin(&store); db.configure_chronicle(&store, {"service"}); db.commit(&store)
	sqlite_chronicle_service_seed(t, &store)
	claim := pr.Chronicle_Request {
		op       = "claim",
		consumer = pr.CHRONICLE_CONSUMER_VERSION,
		limit    = 1,
	}
	r, _ := sqlite_chronicle_service_call(t, &store, claim)
	job := pr.Chronicle_Request {
		op         = "retry",
		consumer   = claim.consumer,
		epoch      = r.epoch,
		generation = r.generation,
		sources    = r.sources,
		reason     = "rebatch",
	}
	released, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, released.status, "released")
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.generation, "2")
	job.epoch = r.epoch; job.generation = r.generation; job.sources = r.sources
	job.op = "reserve"; job.input_tokens = 100; job.output_tokens = 1000
	sqlite_chronicle_service_call(t, &store, job)
	job.op = "retry"; job.reason = "timeout"
	sqlite_chronicle_service_call(t, &store, job)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.status, "backoff")
	backoff, _ := sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "status"})
	testing.expect_value(t, backoff.pending, i64(1)); testing.expect_value(t, backoff.processing, i64(0)); testing.expect_value(t, backoff.failed, i64(0))
	sqlite_projection_test_assert(t, &store, "SELECT attempts=1 FROM chronicle_inputs")
	sql.exec(store.db, "UPDATE chronicle_inputs SET retry_at=0", nil, nil, nil)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	job.epoch = r.epoch; job.generation = r.generation; job.sources = r.sources
	job.op = "reserve"
	reserved, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, reserved.status, "reserved")
	job.op = "retry"; job.reason = "permanent"
	parked, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, parked.status, "parked")
	// A deterministic failure must not buy another provider attempt on restart.
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	db.begin(&store); db.configure_chronicle(&store, {"service"}); db.commit(&store)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.status, "parked")
	sqlite_projection_test_assert(t, &store, "SELECT attempts=2 AND retry_at=expires_at AND state=0 FROM chronicle_inputs")
	sqlite_projection_test_assert(t, &store, "SELECT calls=2 FROM chronicle_budgets")
	sql.exec(store.db, "UPDATE chronicle_inputs SET retry_at=0", nil, nil, nil)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	job.epoch = r.epoch; job.generation = r.generation; job.sources = r.sources
	// Expiry must be enforced before the periodic cleaner has run.
	sql.exec(store.db, "UPDATE chronicle_inputs SET captured_at=1,expires_at=2", nil, nil, nil)
	job.op = "chunk"; job.cursor = r.sources[0]; job.field = 5; job.length = 16
	expired, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, expired.status, "expired")
	job.op = "commit"; job.outcome = "result"; job.reason = ""; job.summary = "must not publish"; job.model = "fake"; job.prompt_version = "p"; job.schema_version = "s"
	expired, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, expired.status, "expired")
	db.begin(&store); db.configure_chronicle(&store, nil); db.configure_chronicle(&store, {"service"}); db.commit(&store)
	expired, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, expired.status, "expired")
	sqlite_chronicle_service_seed(t, &store)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	job = pr.Chronicle_Request {
		op         = "commit",
		consumer   = claim.consumer,
		epoch      = r.epoch,
		generation = r.generation,
		sources    = r.sources,
		outcome    = "gap",
		reason     = "token_limit",
	}
	gap, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, gap.status, "gap")
	gap, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, gap.status, "gap")
	sqlite_chronicle_service_seed(t, &store)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	deleted, _ := sqlite_chronicle_service_call(
		t,
		&store,
		pr.Chronicle_Request{op = "delete", note_id = r.note_id},
		access = pr.CHRONICLE_ACCESS_DELETE,
		subject = "human",
	)
	testing.expect_value(t, deleted.status, "deleted")
	job.epoch = r.epoch; job.generation = r.generation; job.sources = r.sources
	result, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "deleted")
	sqlite_projection_test_assert(t, &store, "SELECT raw_bytes=0 AND pending_inputs=0 FROM chronicle_workspaces")
}

@(test)
test_chronicle_service_order_attempts_budget_and_exact_sources :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "chronicle-order-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	store, rc := db.open(strings.clone_to_cstring(fmt.aprintf("%s/order.db", dir)), create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	db.begin(&store); db.configure_chronicle(&store, {"service"}); db.commit(&store)
	sqlite_chronicle_service_seed(t, &store)
	sqlite_chronicle_service_seed(t, &store)
	wire: [4096]byte
	n := pr.serializeUpdateAssetRequest(
		pr.UpdateAssetRequest {
			asset_id = 1,
			preview = transmute([]byte)string(`{"title":"Later"}`),
			payload = transmute([]byte)string("changed"),
			payload_raw_len = 7,
		},
		wire[:],
	)
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "service", nrc_time_unix_nanos(), wire[:n]), sql.OK)
	claim := pr.Chronicle_Request {
		op       = "claim",
		consumer = pr.CHRONICLE_CONSUMER_VERSION,
		limit    = 32,
	}
	r, _ := sqlite_chronicle_service_call(t, &store, claim)
	// Sources 1 and 3 belong to note 1, but note 2 must not be skipped.
	if !testing.expect_value(t, len(r.sources), 1) do return
	testing.expect_value(t, r.sources[0], "1")
	job := pr.Chronicle_Request {
		op         = "commit",
		consumer   = claim.consumer,
		epoch      = r.epoch,
		generation = r.generation,
		sources    = {"1", "3"},
		outcome    = "gap",
		reason     = "token_limit",
	}
	rejected, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, rejected.status, "invalid")
	job.sources = r.sources
	result, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "gap")
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.note_id, "2")
	job.epoch = r.epoch; job.generation = r.generation; job.sources = r.sources
	sqlite_chronicle_service_call(t, &store, job)
	for _ in 0 ..< 5 {
		r, _ = sqlite_chronicle_service_call(t, &store, claim)
		if !testing.expect_value(t, r.status, "claimed") do return
		job = pr.Chronicle_Request {
			op            = "reserve",
			consumer      = claim.consumer,
			epoch         = r.epoch,
			generation    = r.generation,
			sources       = r.sources,
			input_tokens  = 100,
			output_tokens = 1000,
		}
		reserved, _ := sqlite_chronicle_service_call(t, &store, job)
		testing.expect_value(t, reserved.status, "reserved")
		job.op = "retry"; job.reason = "timeout"
		released, _ := sqlite_chronicle_service_call(t, &store, job)
		testing.expect_value(t, released.status, "released")
		testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_inputs SET retry_at=0", nil, nil, nil), sql.OK)
	}
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.status, "exhausted")
	sqlite_projection_test_assert(t, &store, "SELECT attempts=5 AND state=0 FROM chronicle_inputs")
	// Failure stays observable and blocks skipping until the real expiry boundary.
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.status, "exhausted")
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_inputs SET captured_at=1,expires_at=2", nil, nil, nil), sql.OK)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.status, "empty")
	sqlite_chronicle_service_seed(t, &store)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	job = pr.Chronicle_Request {
		op            = "reserve",
		consumer      = claim.consumer,
		epoch         = r.epoch,
		generation    = r.generation,
		sources       = r.sources,
		input_tokens  = 16000,
		output_tokens = 1000,
	}
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_budgets SET input_tokens=7984001", nil, nil, nil), sql.OK)
	limited, _ := sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, limited.status, "budget")
	sqlite_projection_test_assert(t, &store, "SELECT attempts=0 FROM chronicle_inputs")
	// Calls are telemetry only; both token budgets still fence reservations.
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_budgets SET calls=100,input_tokens=7984000,output_tokens=499001", nil, nil, nil), sql.OK)
	limited, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, limited.status, "budget")
	sqlite_projection_test_assert(t, &store, "SELECT attempts=0 FROM chronicle_inputs")
	sqlite_projection_test_assert(t, &store, "SELECT calls=100 AND input_tokens=7984000 AND output_tokens=499001 FROM chronicle_budgets")
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_budgets SET output_tokens=499000", nil, nil, nil), sql.OK)
	limited, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, limited.status, "reserved")
	sqlite_projection_test_assert(t, &store, "SELECT input_tokens=8000000 AND output_tokens=500000 AND calls=101 FROM chronicle_budgets")
	// New mutations of the same note remain eligible above its deletion watermark.
	deleted, _ := sqlite_chronicle_service_call(
		t,
		&store,
		pr.Chronicle_Request{op = "delete", note_id = r.note_id},
		access = pr.CHRONICLE_ACCESS_DELETE,
		subject = "human",
	)
	testing.expect_value(t, deleted.status, "deleted")
	note_id, _ := strconv.parse_u64(r.note_id)
	n = pr.serializeUpdateAssetRequest(pr.UpdateAssetRequest{asset_id = note_id, preview = transmute([]byte)string(`{"title":"After deletion"}`)}, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "service", nrc_time_unix_nanos(), wire[:n]), sql.OK)
	r, _ = sqlite_chronicle_service_call(t, &store, claim)
	testing.expect_value(t, r.status, "claimed")
	job = pr.Chronicle_Request {
		op         = "commit",
		consumer   = claim.consumer,
		epoch      = r.epoch,
		generation = r.generation,
		sources    = r.sources,
		outcome    = "gap",
		reason     = "token_limit",
	}
	result, _ = sqlite_chronicle_service_call(t, &store, job)
	testing.expect_value(t, result.status, "gap")
}

@(test)
test_chronicle_service_byte_bounded_pages_and_unsigned_identity :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "chronicle-pages-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	store, rc := db.open(strings.clone_to_cstring(fmt.aprintf("%s/pages.db", dir)), create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	db.begin(&store); db.configure_chronicle(&store, {"service"}); db.commit(&store)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`UPDATE sequences SET high_water=x'8000000000000000' WHERE domain='asset';
 UPDATE chronicle_workspaces SET claim_generation=x'0020000000000000'`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	// Eight escaped 4096-byte summaries cannot fit a 60 KB page, even though
	// the row limit is 16. IDs exceed both signed i64 and JavaScript precision.
	summary := strings.repeat("\"", 4096)
	for i in 0 ..< 8 {
		sqlite_chronicle_service_seed(t, &store)
		r, _ := sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "claim", consumer = pr.CHRONICLE_CONSUMER_VERSION, limit = 1})
		if !testing.expect_value(t, r.status, "claimed") do return
		testing.expect_value(t, r.note_id, fmt.aprintf("%d", u64(9223372036854775808) + u64(i) + 1))
		testing.expect_value(t, r.generation, fmt.aprintf("%d", u64(9007199254740992) + u64(i) + 1))
		job := pr.Chronicle_Request {
			op            = "reserve",
			consumer      = pr.CHRONICLE_CONSUMER_VERSION,
			epoch         = r.epoch,
			generation    = r.generation,
			sources       = r.sources,
			input_tokens  = 100,
			output_tokens = 1000,
		}
		sqlite_chronicle_service_call(t, &store, job)
		job.op = "commit"; job.outcome = "result"; job.summary = summary; job.model = "fake"; job.prompt_version = "p"; job.schema_version = "s"
		result, _ := sqlite_chronicle_service_call(t, &store, job)
		testing.expect_value(t, result.status, "committed")
	}
	q := pr.Chronicle_Request {
		op    = "history",
		limit = 16,
	}
	count := 0
	for _ in 0 ..< 8 {
		page, _ := sqlite_chronicle_service_call(t, &store, q)
		if !testing.expect_value(t, page.status, "ok") || !testing.expect(t, len(page.entries) > 0) do return
		if count == 0 {testing.expect(t, page.more); testing.expect(t, len(page.entries) < 8)}
		for entry in page.entries {
			testing.expect_value(t, entry.generation, fmt.aprintf("%d", u64(9007199254740992) + u64(count) + 1))
			testing.expect_value(t, entry.note_id, fmt.aprintf("%d", u64(9223372036854775808) + u64(count) + 1))
			testing.expect_value(t, entry.summary, summary)
			count += 1
		}
		if !page.more do break
		q.cursor = page.cursor
	}
	testing.expect_value(t, count, 8)
}

@(test)
test_chronicle_service_status_live_failure_and_scope :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "chronicle-status-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	store, rc := db.open(strings.clone_to_cstring(fmt.aprintf("%s/status.db", dir)), create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	db.begin(&store); db.configure_chronicle(&store, {"service"}); db.commit(&store)
	for _ in 0 ..< 4 do sqlite_chronicle_service_seed(t, &store)
	q := pr.Chronicle_Request {
		op = "status",
	}
	r, read_rc := sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, read_rc, sql.OK)
	testing.expect_value(t, r.pending, i64(4)); testing.expect_value(t, r.processing, i64(0)); testing.expect_value(t, r.failed, i64(0))
	testing.expect(t, !r.can_delete)
	raw_bytes := r.raw_bytes
	claim, _ := sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "claim", consumer = pr.CHRONICLE_CONSUMER_VERSION, limit = 1})
	// Fifth attempt remains running while its lease is live; another input is
	// parked, a third exhausted, and the fourth logically expired pre-cleanup.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`UPDATE chronicle_inputs SET attempts=5 WHERE note_id IN (x'0000000000000001',x'0000000000000003');
 UPDATE chronicle_inputs SET retry_at=expires_at WHERE note_id=x'0000000000000002';
 UPDATE chronicle_inputs SET captured_at=1,expires_at=2 WHERE note_id=x'0000000000000004'`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	r, _ = sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(
		t,
		r.pending,
		i64(3),
	); testing.expect_value(t, r.processing, i64(1)); testing.expect_value(t, r.failed, i64(2)); testing.expect_value(t, r.expired, i64(1))
	testing.expect_value(t, r.raw_bytes, raw_bytes)
	q.note_id = claim.note_id
	r, _ = sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ | pr.CHRONICLE_ACCESS_DELETE, subject = "human")
	testing.expect(t, r.can_delete)
	testing.expect_value(t, r.pending, i64(1)); testing.expect_value(t, r.processing, i64(1)); testing.expect_value(t, r.failed, i64(0))
	testing.expect_value(t, r.raw_bytes, raw_bytes)
	// Capabilities come from each authenticated request, not the prior reader.
	r, _ = sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ, subject = "human")
	testing.expect(t, !r.can_delete)
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_jobs SET lease_until=1", nil, nil, nil), sql.OK)
	r, _ = sqlite_chronicle_service_call(t, &store, q)
	testing.expect_value(t, r.processing, i64(0)); testing.expect_value(t, r.failed, i64(1))
	q.note_id = "4"
	r, _ = sqlite_chronicle_service_call(t, &store, q)
	testing.expect_value(t, r.pending, i64(0)); testing.expect_value(t, r.failed, i64(0)); testing.expect_value(t, r.expired, i64(1))
	q.note_id = ""
	r, _ = sqlite_chronicle_service_call(t, &store, q, workspace = "other")
	testing.expect_value(t, r.pending, i64(0)); testing.expect_value(t, r.failed, i64(0)); testing.expect_value(t, r.raw_bytes, i64(0))
	r, _ = sqlite_chronicle_service_call(t, &store, q, access = 0)
	testing.expect_value(t, r.status, "forbidden")
	r, _ = sqlite_chronicle_service_call(t, &store, q, subject = "")
	testing.expect_value(t, r.status, "forbidden")
	testing.expect_value(t, sql.exec(store.db, "UPDATE chronicle_workspaces SET enabled=0,disabled_through_epoch=epoch", nil, nil, nil), sql.OK)
	r, _ = sqlite_chronicle_service_call(t, &store, q)
	testing.expect_value(
		t,
		r.pending,
		i64(0),
	); testing.expect_value(t, r.processing, i64(0)); testing.expect_value(t, r.failed, i64(0)); testing.expect_value(t, r.expired, i64(4))
}

@(test)
test_chronicle_service_gaps_read_paging_and_loss_accounting :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "chronicle-gaps-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	store, rc := db.open(strings.clone_to_cstring(fmt.aprintf("%s/gaps.db", dir)), create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	db.begin(&store); db.configure_chronicle(&store, {"service"}); db.commit(&store)
	// Populate canonical notes, then exact high-ID compact receipts. A range
	// count deliberately differs from its row count and its cursor span.
	sqlite_chronicle_service_seed(t, &store); sqlite_chronicle_service_seed(t, &store)
	wire: [1024]byte
	n := pr.serializeUpdateAssetRequest(
		pr.UpdateAssetRequest{asset_id = 2, preview = transmute([]byte)string(`{"title":"Umbenannt <&> — Prüfung"}`)},
		wire[:],
	)
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "service", nrc_time_unix_nanos(), wire[:n]), sql.OK)
	for i in 0 ..< 18 {
		first := u64(9223372036854775808) + u64(i * 8)
		testing.expect_value(
			t,
			sqlite_chronicle_execute(
				&store,
				"INSERT INTO chronicle_gaps VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
				"service",
				{first, first + 2, u64(i % 2 + 1), "ttl", i64(9007199254740993), i64(9007199254740995), i64(3)},
			),
			sql.OK,
		)
	}
	q := pr.Chronicle_Request {
		op    = "gaps",
		limit = 16,
	}
	page, read_rc := sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ, subject = "reader")
	if !testing.expect_value(t, read_rc, sql.OK) || !testing.expect_value(t, len(page.gaps), 16) do return
	testing.expect(t, page.more)
	testing.expect_value(t, page.gaps[0].first_source, "9223372036854775808")
	testing.expect_value(t, page.gaps[0].last_source, "9223372036854775810")
	testing.expect_value(t, page.gaps[0].first_at, "9007199254740993")
	testing.expect_value(t, page.gaps[0].last_at, "9007199254740995")
	testing.expect_value(t, page.gaps[0].reason, "ttl"); testing.expect_value(t, page.gaps[0].input_count, i64(3))
	testing.expect(t, page.gaps[0].source_available)
	testing.expect_value(t, page.gaps[0].note_title, "Chronik")
	testing.expect_value(t, page.gaps[1].note_title, "Umbenannt <&> — Prüfung")
	testing.expect_value(t, len(page.inputs), 0); testing.expect_value(t, page.chunk, ""); testing.expect_value(t, page.summary, "")
	q.cursor = page.cursor
	page, _ = sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, len(page.gaps), 2); testing.expect(t, !page.more)
	q.cursor = page.cursor
	page, _ = sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ)
	testing.expect_value(t, len(page.gaps), 0); testing.expect_value(t, page.cursor, q.cursor)
	q.cursor = ""; q.note_id = "2"
	page, _ = sqlite_chronicle_service_call(t, &store, q)
	testing.expect_value(t, len(page.gaps), 9)
	for row in page.gaps do testing.expect_value(t, row.note_id, "2")
	status, _ := sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "status", note_id = "2"})
	testing.expect_value(t, status.gap_count, i64(27))
	status, _ = sqlite_chronicle_service_call(t, &store, pr.Chronicle_Request{op = "status"})
	testing.expect_value(t, status.gap_count, i64(54))
	other, _ := sqlite_chronicle_service_call(t, &store, q, workspace = "other")
	testing.expect_value(t, len(other.gaps), 0)
	for limit in ([3]u16{0, 17, max(u16)}) {
		q.limit = limit
		invalid, _ := sqlite_chronicle_service_call(t, &store, q)
		testing.expect_value(t, invalid.status, "invalid")
	}
	q.limit = 16
	denied, _ := sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_SERVICE)
	testing.expect_value(t, denied.status, "forbidden")
	// Canonical deletion changes the link, never the durable loss receipt.
	n = pr.serializeDeleteAssetRequest(0, 2, wire[:])
	testing.expect_value(t, sqlite_chronicle_test_apply(&store, "service", nrc_time_unix_nanos(), wire[:n]), sql.OK)
	page, _ = sqlite_chronicle_service_call(t, &store, q, access = pr.CHRONICLE_ACCESS_READ)
	if testing.expect_value(t, len(page.gaps), 9) {
		testing.expect(t, !page.gaps[0].source_available)
		testing.expect_value(t, page.gaps[0].note_title, "Umbenannt <&> — Prüfung")
	}
}
