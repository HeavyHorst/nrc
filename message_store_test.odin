package main

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sys/linux"
import "core:testing"
import "core:time"

import hgl "hegel"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import "storage_io"

when !NRC_SIMULATION {
	_ :: hgl.run
	_ :: linux.Errno
	_ :: nbio.init
	_ :: pr.MessageRangeRequest
	_ :: storage_io.Context
}

test_retained_message :: proc(workspace: string, conversation, marker: u64, accepted_at: i64) -> Retained_Message {
	id: [16]byte
	message_put_u64(id[:], marker)
	return {
		workspace = workspace,
		conversation_id = conversation,
		client_message_id = id,
		sender_name = "alice",
		sender_principal = "alice-principal",
		accepted_at_ns = accepted_at,
		content_type = 0,
		content = transmute([]byte)string("hello retained world"),
	}
}

crash_message_store_for_test :: proc(store: ^Message_Store) {
	assert(store.async_readers == 0, "message store crash simulation requires drained async readers")
	persistence.simulate_wal_crash_for_test(&store.wal)
	persistence.cleanup_init_wal_state(&store.wal)
	if store.active_read_file != nil do storage_io.discard(store.active_read_file)
	destroy_frozen_message_store(store, false)
	destroy_active_message_indexes(store)
	destroy_message_segment_metadata(store, store.segments[:])
	delete(store.segments)
	delete(store.pending_appends)
	delete(store.pending_dedup)
	delete(store.deferred_appends)
	delete(store.deferred_dedup)
	delete(store.durability_waiters)
	delete(store.directory)
	store^ = {}
}

when NRC_SIMULATION {
	Retained_Fsync_Outcome :: enum u8 {
		Crash_Pending,
		Success,
		Error,
	}

	retained_message_fsync_durability_case :: proc(outcome: Retained_Fsync_Outcome) -> string {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 128 + int(outcome))
		defer simulation_test_end(&ctx)

		storage := sim_world_storage_context(&ctx.sim.world)
		shard_dir := "/retained-fsync-shard"
		if storage_io.make_directory(storage, shard_dir) != nil do return "create shard directory"
		if storage_io.sync_directory(storage, "/") != nil do return "publish shard directory"
		workspace := "retained-message-generated-fsync"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		accepted_at := nrc_time_unix_nanos()
		store: Message_Store
		if !init_message_store_with_storage(&store, storage, shard_dir, shard, 24 * time.Hour, 0) {
			return "initialize message store"
		}

		first := test_retained_message(workspace, 42, 1, accepted_at)
		result, sequence := append_or_deduplicate_message(&store, &first)
		if result != .Appended || sequence != 1 do return "append first message"
		store.commit_pending = true
		store.commit_started = {}
		if !schedule_retained_message_fsync(&store) do return "schedule first durability snapshot"
		if !store.fsync_in_flight || store.fsync_snapshot.record_count != 1 || nrc_sim_fsync_completion_count(&ctx.sim) != 1 {
			return "first fsync captured the wrong active-WAL prefix"
		}

		// A later append is accepted while the first snapshot is pending, but
		// must not become durable when that earlier snapshot completes.
		store.wal.last_fsync = store.wal.get_time()
		second := test_retained_message(workspace, 42, 2, accepted_at + i64(time.Second))
		result, sequence = append_or_deduplicate_message(&store, &second)
		if result != .Appended || sequence != 2 do return "append second message behind pending fsync"
		if store.wal.record_count != 2 || store.wal.durable_record_count != 0 {
			return "speculative active-WAL counts do not match the two-message model"
		}

		expected_durable := u64(0)
		switch outcome {
		case .Crash_Pending:
		case .Success:
			if !nrc_sim_run_next_fsync_completion(&ctx.sim) do return "deliver successful fsync"
			expected_durable = 1
			if store.wal.durable_record_count != 1 || store.wal.pending_bytes == 0 {
				return "successful fsync advanced beyond its captured prefix"
			}
		case .Error:
			previous_logger := context.logger
			context.logger = log.nil_logger()
			completed := nrc_sim_run_next_fsync_completion(&ctx.sim, .EIO)
			context.logger = previous_logger
			if !completed || !store.poisoned || store.wal.enabled do return "failed fsync did not poison the store"
		}

		crash_message_store_for_test(&store)
		sim_world_crash(&ctx.sim.world)
		if outcome == .Crash_Pending && !nrc_sim_run_next_fsync_completion(&ctx.sim) {
			return "pending pre-crash fsync event was not stale-discarded"
		}
		storage = sim_world_storage_context(&ctx.sim.world)
		if !init_message_store_with_storage(&store, storage, shard_dir, shard, 24 * time.Hour, 0) {
			return "reopen message store after durability selection"
		}
		if store.high_water != expected_durable || store.wal.record_count != expected_durable {
			return fmt.tprintf("recovered prefix mismatch: high_water=%d records=%d expected=%d", store.high_water, store.wal.record_count, expected_durable)
		}

		first_retry := test_retained_message(workspace, 42, 1, accepted_at + i64(2 * time.Second))
		result, sequence = append_or_deduplicate_message(&store, &first_retry)
		expected_first_result := Message_Store_Result.Appended
		if expected_durable == 1 do expected_first_result = .Duplicate
		if result != expected_first_result || sequence != 1 do return "first-message dedup model mismatch after recovery"
		second_retry := test_retained_message(workspace, 42, 2, accepted_at + i64(3 * time.Second))
		result, sequence = append_or_deduplicate_message(&store, &second_retry)
		if result != .Appended || sequence != 2 do return "second speculative message survived outside the durable subset"
		third := test_retained_message(workspace, 42, 3, accepted_at + i64(4 * time.Second))
		result, sequence = append_or_deduplicate_message(&store, &third)
		if result != .Appended || sequence != 3 do return "continuation append after recovery"
		if !shutdown_message_store(&store) do return "durably shut down recovered message store"

		sim_world_crash(&ctx.sim.world)
		storage = sim_world_storage_context(&ctx.sim.world)
		if !init_message_store_with_storage(&store, storage, shard_dir, shard, 24 * time.Hour, 0) {
			return "second reopen"
		}
		if store.high_water != 3 || store.wal.record_count != 3 do return "second restart lost continuation history"
		for marker in u64(1) ..= 3 {
			retry := test_retained_message(workspace, 42, marker, accepted_at + i64(5 + marker) * i64(time.Second))
			result, sequence = append_or_deduplicate_message(&store, &retry)
			if result != .Duplicate || sequence != marker do return "second-restart dedup model mismatch"
		}
		if !shutdown_message_store(&store) do return "final message-store shutdown"
		return ""
	}

	@(test)
	test_retained_message_fsync_durability_mandatory_outcomes :: proc(t: ^testing.T) {
		for outcome in Retained_Fsync_Outcome {
			diagnostic := retained_message_fsync_durability_case(outcome)
			testing.expectf(t, diagnostic == "", "retained fsync outcome=%v failed: %s", outcome, diagnostic)
		}
	}
}

@(test)
test_message_fingerprint_stream_matches_canonical_request_encoding :: proc(t: ^testing.T) {
	message := test_retained_message("fingerprint-workspace", 42, 99, nrc_time_unix_nanos())
	message.content_type = 1
	message.content = transmute([]byte)string("fingerprint payload")
	canonical := message
	canonical.sequence = 0
	canonical.accepted_at_ns = 0
	canonical.sender_name = ""
	canonical.client_message_id = {}
	canonical.fingerprint = 0
	size, valid := message_record_size(&canonical)
	testing.expect(t, valid)
	buf := make([]byte, size - 8, context.temp_allocator)
	testing.expect(t, encode_message_record(&canonical, buf, false))
	testing.expect_value(t, message_fingerprint(&message), u64(xxhash.XXH64(buf)))
}

@(test)
test_borrowed_message_decode_aliases_variable_record_fields :: proc(t: ^testing.T) {
	message := test_retained_message("borrowed-workspace", 42, 99, nrc_time_unix_nanos())
	message.content = transmute([]byte)string("borrowed retained payload")
	message.fingerprint = message_fingerprint(&message)
	size, valid := message_record_size(&message)
	testing.expect(t, valid)
	payload := make([]byte, size); defer delete(payload)
	testing.expect(t, encode_message_record(&message, payload))
	decoded, ok := decode_message_record_borrowed(payload)
	testing.expect(t, ok)
	testing.expect_value(t, decoded.workspace, message.workspace)
	testing.expect_value(t, decoded.sender_name, message.sender_name)
	testing.expect_value(t, decoded.sender_principal, message.sender_principal)
	testing.expect_value(t, string(decoded.content), string(message.content))
	payload[2] = 'B'
	testing.expect_value(t, decoded.workspace[0], byte('B'))
	payload[len(payload) - 9] = 'X'
	testing.expect_value(t, decoded.content[len(decoded.content) - 1], byte('X'))
	_, ok = decode_message_record_borrowed(payload[:len(payload) - 1])
	testing.expect(t, !ok)
}

@(test)
test_message_scan_borrowed_lifetime_and_allocations :: proc(t: ^testing.T) {
	message := test_retained_message("scan-lifetime", 42, 1, nrc_time_unix_nanos())
	message.sequence = 1
	message.fingerprint = message_fingerprint(&message)
	size, valid := message_record_size(&message)
	if !testing.expect(t, valid) do return
	payload := make([]byte, size); defer delete(payload)
	testing.expect(t, encode_message_record(&message, payload))
	records := make([dynamic]Message_Index_Record, 0, 1); defer delete(records)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	message_scan_context = {
		mode    = .Build_Index,
		records = records,
	}
	defer message_scan_context = {}
	original_allocator := context.allocator
	context.allocator = mem.tracking_allocator(&tracker)
	indexed := message_scan_record(1, MESSAGE_WAL_VERSION, payload)
	context.allocator = original_allocator
	testing.expect(t, indexed)
	testing.expect_value(t, tracker.total_allocation_count, 0)
	testing.expect_value(t, message_scan_context.records[0].workspace_hash, message_string_hash(message.workspace))

	dir := test_wal_path("message-scan-lifetime")
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	budget := Message_Active_Cache_Budget {
		limit_bytes = u64(size),
	}
	store: Message_Store
	if !testing.expect(t, init_message_store(&store, dir, 0, 24 * time.Hour, 0, active_cache_budget = &budget)) do return
	defer shutdown_message_store(&store)
	message_scan_context = {
		mode  = .Recover_Active,
		store = &store,
	}
	testing.expect(t, message_scan_record(1, MESSAGE_WAL_VERSION, payload))
	for &b in payload do b = 0xff
	key := message_dedup_key(message.workspace, message.sender_principal, message.client_message_id); defer delete(key)
	entry, present := store.active_dedup[key]
	testing.expect(t, present && entry.fingerprint == message.fingerprint)
	entries := store.active_offsets[Message_Conversation_Key{message.workspace, message.conversation_id}]
	if !testing.expect_value(t, len(entries), 1) do return
	cached, ok := decode_message_record_borrowed(entries[0].cached_payload)
	testing.expect(t, ok && cached.workspace == message.workspace && cached.sender_principal == message.sender_principal)
	testing.expect(t, bytes.equal(cached.content, message.content))
	testing.expect_value(t, cached.fingerprint, message_fingerprint(&cached))
	stored_workspace, stored_dedup_key: string
	for k in store.active_offsets do stored_workspace = k.workspace
	for k in store.active_dedup do stored_dedup_key = k
	// Reinsert equal keys with an exhausted cache, then no cache at all.
	// Map updates must preserve the first insertion's arena-backed keys.
	for sequence in u64(2) ..< 4 {
		if sequence == 3 do store.active_cache_budget = nil
		message.sequence = sequence
		testing.expect(t, encode_message_record(&message, payload))
		testing.expect(t, message_scan_record(1, MESSAGE_WAL_VERSION, payload))
		for &b in payload do b = 0xff
		testing.expect_value(t, len(store.active_offsets), 1)
		testing.expect_value(t, len(store.active_dedup), 1)
		for k in store.active_offsets do testing.expect(t, raw_data(k.workspace) == raw_data(stored_workspace))
		for k in store.active_dedup do testing.expect(t, raw_data(k) == raw_data(stored_dedup_key))
		testing.expect_value(t, store.active_dedup[key].sequence, sequence)
		entries = store.active_offsets[Message_Conversation_Key{message.workspace, message.conversation_id}]
		if !testing.expect_value(t, len(entries), int(sequence)) do return
		testing.expect(t, entries[len(entries) - 1].cached_payload == nil)
		testing.expect(t, bytes.equal(cached.content, message.content))
	}
	store.active_cache_budget = &budget
}

@(test)
test_parse_message_retention_configuration :: proc(t: ^testing.T) {
	value, ok := parse_message_retention(""); testing.expect(t, ok); testing.expect_value(t, value, time.Duration(0))
	value, ok = parse_message_retention("24h"); testing.expect(t, ok); testing.expect_value(t, value, 24 * time.Hour)
	value, ok = parse_message_retention("7d"); testing.expect(t, ok); testing.expect_value(t, value, 7 * 24 * time.Hour)
	_, ok = parse_message_retention("24"); testing.expect(t, !ok)
	_, ok = parse_message_retention("-1h"); testing.expect(t, !ok)
	value, ok = parse_message_dedup_window(""); testing.expect(t, ok); testing.expect_value(t, value, 2 * time.Minute)
	value, ok = parse_message_dedup_window("30s"); testing.expect(t, ok); testing.expect_value(t, value, 30 * time.Second)
	_, ok = parse_message_dedup_window("0"); testing.expect(t, !ok)
}

@(test)
test_parse_message_active_cache_configuration :: proc(t: ^testing.T) {
	value, ok := parse_message_active_cache_bytes(""); testing.expect(t, ok); testing.expect_value(t, value, DEFAULT_MESSAGE_ACTIVE_CACHE_BYTES)
	value, ok = parse_message_active_cache_bytes(" 0 "); testing.expect(t, ok); testing.expect_value(t, value, u64(0))
	value, ok = parse_message_active_cache_bytes("1048576"); testing.expect(t, ok); testing.expect_value(t, value, u64(1048576))
	_, ok = parse_message_active_cache_bytes("1MiB"); testing.expect(t, !ok)
	_, ok = parse_message_active_cache_bytes("-1"); testing.expect(t, !ok)
	value, ok = parse_message_sealed_index_cache_bytes(""); testing.expect(t, ok); testing.expect_value(t, value, DEFAULT_MESSAGE_SEALED_INDEX_CACHE_BYTES)
	value, ok = parse_message_sealed_index_cache_bytes(" 0 "); testing.expect(t, ok); testing.expect_value(t, value, u64(0))
	value, ok = parse_message_sealed_index_cache_bytes("1048576"); testing.expect(t, ok); testing.expect_value(t, value, u64(1048576))
	_, ok = parse_message_sealed_index_cache_bytes("1MiB"); testing.expect(t, !ok)
}

@(test)
test_parse_message_write_batch_records_configuration :: proc(t: ^testing.T) {
	value, ok := parse_message_write_batch_records(""); testing.expect(t, ok); testing.expect_value(t, value, DEFAULT_MESSAGE_WRITE_BATCH_RECORDS)
	value, ok = parse_message_write_batch_records(" 0 "); testing.expect(t, ok); testing.expect_value(t, value, 0)
	value, ok = parse_message_write_batch_records("4"); testing.expect(t, ok); testing.expect_value(t, value, 4)
	value, ok = parse_message_write_batch_records("16"); testing.expect(t, ok); testing.expect_value(t, value, 16)
	value, ok = parse_message_write_batch_records("1024"); testing.expect(t, ok); testing.expect_value(t, value, MAX_MESSAGE_WRITE_BATCH_RECORDS)
	_, ok = parse_message_write_batch_records("1025"); testing.expect(t, !ok)
	_, ok = parse_message_write_batch_records("-1"); testing.expect(t, !ok)
	_, ok = parse_message_write_batch_records("records"); testing.expect(t, !ok)
}

@(test)
test_message_store_rejects_dedup_window_longer_than_retention :: proc(t: ^testing.T) {
	workspace := "retained-message-invalid-dedup-window"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-invalid-dedup-window"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store
	testing.expect(t, !init_message_store(&store, dir, shard, time.Minute, 0, 2 * time.Minute))
}

@(test)
test_message_store_disable_resets_active_and_sealed_dedup :: proc(t: ^testing.T) {
	cases := [2]bool{false, true}
	for sealed, case_index in cases {
		workspace := sealed ? "retained-message-reset-sealed" : "retained-message-reset-active"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path(case_index == 0 ? "message-store-reset-active" : "message-store-reset-sealed")
		_ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
		store: Message_Store
		testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0, 2 * time.Minute))
		now := nrc_time_unix_nanos()
		message := test_retained_message(workspace, 42, 1, now)
		result, sequence := append_or_deduplicate_message(&store, &message)
		testing.expect_value(t, result, Message_Store_Result.Appended); testing.expect_value(t, sequence, u64(1))
		if sealed do testing.expect(t, rotate_message_store(&store, now + 1))
		testing.expect(t, shutdown_message_store(&store))
		disabled_at := now + 2
		testing.expect(t, mark_message_store_disabled(dir, shard, disabled_at))
		testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0, 2 * time.Minute))
		retry := test_retained_message(workspace, 42, 1, now + i64(time.Second))
		result, sequence = append_or_deduplicate_message(&store, &retry)
		testing.expect_value(t, result, Message_Store_Result.Appended); testing.expect_value(t, sequence, u64(2))
		testing.expect(t, shutdown_message_store(&store))
	}
}

@(test)
test_message_dedup_filter_has_no_false_negatives_and_rejects_new_ids :: proc(t: ^testing.T) {
	filter := make([]u64, (1_000 * MESSAGE_DEDUP_FILTER_BITS_PER_ENTRY + 63) / 64)
	defer delete(filter)
	workspace := "dedup-filter-workspace"
	principal := "dedup-filter-principal"
	workspace_hash := message_string_hash(workspace)
	principal_hash := message_string_hash(principal)
	for marker in 1 ..= 1_000 {
		id: [16]byte; message_put_u64(id[:], u64(marker))
		message_dedup_filter_add(filter, workspace_hash, principal_hash, id)
	}
	for marker in 1 ..= 1_000 {
		id: [16]byte; message_put_u64(id[:], u64(marker))
		testing.expect(t, message_dedup_filter_maybe_contains(filter, workspace, principal, id))
	}
	rejected := 0
	for marker in 10_001 ..= 11_000 {
		id: [16]byte; message_put_u64(id[:], u64(marker))
		if !message_dedup_filter_maybe_contains(filter, workspace, principal, id) do rejected += 1
	}
	testing.expect(t, rejected >= 950)
}

@(test)
test_message_store_append_dedup_and_recovery :: proc(t: ^testing.T) {
	workspace := "retained-message-recovery-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-recovery"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	now := nrc_time_unix_nanos(); original_at := now
	message := test_retained_message(workspace, 42, 1, original_at)
	result, sequence := append_or_deduplicate_message(&store, &message)
	testing.expect_value(t, result, Message_Store_Result.Appended); testing.expect_value(t, sequence, u64(1))
	duplicate := test_retained_message(workspace, 42, 1, original_at + i64(time.Second))
	result, sequence = append_or_deduplicate_message(&store, &duplicate)
	testing.expect_value(t, result, Message_Store_Result.Duplicate); testing.expect_value(t, sequence, u64(1))
	conflict := test_retained_message(workspace, 42, 1, original_at + i64(time.Second)); conflict.content = transmute([]byte)string("different")
	result, _ = append_or_deduplicate_message(&store, &conflict); testing.expect_value(t, result, Message_Store_Result.Conflict)
	reused_at := now + i64(3 * time.Minute)
	reused := test_retained_message(workspace, 42, 1, reused_at)
	result, sequence = append_or_deduplicate_message(&store, &reused)
	testing.expect_value(t, result, Message_Store_Result.Appended); testing.expect_value(t, sequence, u64(2))
	retry := test_retained_message(workspace, 42, 1, reused_at + i64(time.Second))
	result, sequence = append_or_deduplicate_message(&store, &retry)
	testing.expect_value(t, result, Message_Store_Result.Duplicate); testing.expect_value(t, sequence, u64(2))
	testing.expect(t, shutdown_message_store(&store))
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	testing.expect_value(t, store.high_water, u64(2)); testing.expect_value(t, store.active_bytes > 0, true)
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_simulation_message_store_rotation_and_index_rebuild_use_virtual_storage :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 131)
		defer simulation_test_end(&ctx)

		storage := sim_world_storage_context(&ctx.sim.world)
		shard_dir := "/retained-rotation-shard"
		testing.expect(t, storage_io.make_directory(storage, shard_dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		workspace := "retained-message-virtual-rotation"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		accepted_at := nrc_time_unix_nanos()
		store: Message_Store
		testing.expect(t, init_message_store_with_storage(&store, storage, shard_dir, shard, 48 * time.Hour, 0))
		conversations := [3]u64{7, 3, 7}
		for conversation, i in conversations {
			message := test_retained_message(workspace, conversation, u64(i + 1), accepted_at + i64(i))
			result, sequence := append_or_deduplicate_message(&store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			testing.expect_value(t, sequence, u64(i + 1))
		}
		testing.expect(t, rotate_message_store(&store, accepted_at + i64(time.Hour)))
		testing.expect_value(t, store.active_generation, u64(3))
		testing.expect_value(t, len(store.segments), 1)
		testing.expect_value(t, store.segments[0].generation, u64(2))
		testing.expect_value(t, store.segments[0].first_seq, u64(1))
		testing.expect_value(t, store.segments[0].last_seq, u64(3))
		testing.expect(t, validate_message_segment_index(&store, store.segments[0]))
		testing.expect_value(t, len(store.segments[0].conversation_ranges), 2)

		fourth := test_retained_message(workspace, 3, 4, accepted_at + i64(time.Hour + time.Second))
		result, sequence := append_or_deduplicate_message(&store, &fourth)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect_value(t, sequence, u64(4))
		persistence.force_fsync(&store.wal)
		crash_message_store_for_test(&store)
		sim_world_crash(&ctx.sim.world)

		storage = sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, init_message_store_with_storage(&store, storage, shard_dir, shard, 48 * time.Hour, 0))
		testing.expect_value(t, store.high_water, u64(4))
		testing.expect_value(t, store.wal.record_count, u64(1))
		testing.expect_value(t, len(store.segments), 1)
		testing.expect(t, validate_message_segment_index(&store, store.segments[0]))
		sealed_path := message_store_path(store.directory, store.segments[0].generation, "wal")
		message_scan_context = {
			mode = .Validate,
		}
		inspection := persistence.inspect_wal_file_strict_with_storage(storage, sealed_path, MESSAGE_WAL_MAGIC, shard, message_scan_record)
		message_scan_context = {}
		delete(sealed_path)
		testing.expect(t, inspection.ok)
		testing.expect_value(t, inspection.record_count, u64(3))

		// Startup must rebuild a missing sealed index through the same storage
		// context rather than falling back to the host filesystem.
		index_path := message_store_path(store.directory, store.segments[0].generation, "idx")
		testing.expect(t, storage_io.remove(storage, index_path) == nil)
		testing.expect(t, storage_io.sync_directory(storage, store.directory) == nil)
		testing.expect(t, shutdown_message_store(&store))
		sim_world_crash(&ctx.sim.world)
		storage = sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, init_message_store_with_storage(&store, storage, shard_dir, shard, 48 * time.Hour, 0))
		index_exists, index_exists_err := storage_io.exists(storage, index_path)
		testing.expect(t, index_exists_err == nil && index_exists)
		testing.expect(t, validate_message_segment_index(&store, store.segments[0]))
		delete(index_path)

		fifth := test_retained_message(workspace, 7, 5, accepted_at + i64(time.Hour + 2 * time.Second))
		result, sequence = append_or_deduplicate_message(&store, &fifth)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect_value(t, sequence, u64(5))
		testing.expect(t, shutdown_message_store(&store))
		sim_world_crash(&ctx.sim.world)
		storage = sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, init_message_store_with_storage(&store, storage, shard_dir, shard, 48 * time.Hour, 0))
		testing.expect_value(t, store.high_water, u64(5))
		testing.expect_value(t, store.wal.record_count, u64(2))
		testing.expect_value(t, len(store.segments), 1)
		testing.expect(t, shutdown_message_store(&store))
	}
}

@(test)
test_simulation_retained_history_reads_sealed_and_active_virtual_wals :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 132)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)

		workspace := "retained-message-virtual-history"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "virtual-reader", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return

		storage := sim_world_storage_context(&ctx.sim.world)
		shard_dir := "/retained-history-shard"
		testing.expect(t, storage_io.make_directory(storage, shard_dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		testing.expect(t, init_message_store_with_storage(&td.message_stores.stores[0], storage, shard_dir, shard, 48 * time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		accepted_at := nrc_time_unix_nanos()

		for marker in u64(1) ..= 3 {
			message := test_retained_message(workspace, 42, marker, accepted_at + i64(marker))
			result, sequence := append_or_deduplicate_message(store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			testing.expect_value(t, sequence, marker)
		}
		testing.expect(t, rotate_message_store(store, accepted_at + i64(time.Hour)))
		fourth := test_retained_message(workspace, 42, 4, accepted_at + i64(time.Hour + time.Second))
		result, sequence := append_or_deduplicate_message(store, &fourth)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect_value(t, sequence, u64(4))
		subscribe_to_conversation(conn, 42)

		file_reads := 0
		page, page_ok := retained_history_simulation_page(
			conn,
			pr.MessageRangeRequest{conv_id = 42, cursor = 0, limit = 10, correlation_id = 77},
			true,
			&file_reads,
		)
		testing.expect(t, page_ok)
		testing.expect_value(t, len(page.messages), 4)
		for message, i in page.messages do testing.expect_value(t, u64(message.seq), u64(i + 1))
		testing.expect(t, file_reads >= 3, "sealed index/WAL and active WAL should execute as scheduled storage reads")
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 0)
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect_value(t, store.segments[0].readers, 0)
		testing.expect(t, store.active_read_file != nil)

		nrc_sim_clear_inboxes(&ctx.sim)
		process_message_history(conn, pr.MessageRangeRequest{conv_id = 42, cursor = 0, limit = 10, correlation_id = 78}, true)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)
		testing.expect_value(t, conn.retained_io, 1)
		testing.expect_value(t, store.async_readers, u32(1))
		sim_world_crash(&ctx.sim.world)
		testing.expect(t, nrc_sim_run_next_file_read(&ctx.sim), "pre-crash read should stale-discard")
		testing.expect(t, !store.poisoned)
		testing.expect_value(t, conn.retained_io, 0)
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect_value(t, store.segments[0].readers, 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_ErrorResponse), 0)

		crash_message_store_for_test(store)
		storage = sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, init_message_store_with_storage(store, storage, shard_dir, shard, 48 * time.Hour, 0))
		nrc_sim_clear_inboxes(&ctx.sim)
		process_message_history(conn, pr.MessageRangeRequest{conv_id = 42, cursor = 0, limit = 10, correlation_id = 79}, true)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_file_read(&ctx.sim, .EIO))
		testing.expect(t, store.poisoned)
		testing.expect_value(t, conn.retained_io, 0)
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect_value(t, store.segments[0].readers, 0)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_ErrorResponse), 0)
		testing.expect(t, !store.fsync_in_flight && store.wal.pending_bytes == 0, "read-only failure has no future fsync to wake the outbox")
		_, maintenance_ok := maintain_message_store_registry(&td.message_stores)
		testing.expect(t, !maintenance_ok, "poisoned retained storage must fail worker maintenance")
		server: NRC_Server
		td.server = &server
		defer {td.server = nil}
		pending_queue, queue_err := pending_queue_create(1)
		testing.expect(t, queue_err == nil)
		if queue_err != nil do return
		td.my_pending_queue = pending_queue
		defer {td.my_pending_queue = {}; pending_queue_destroy(pending_queue)}
		previous_logger := context.logger
		context.logger = log.nil_logger()
		_ = worker_run_pre_tick()
		context.logger = previous_logger
		testing.expect(t, server.closing && server.fatal_storage_error, "read failure must request fatal server shutdown")
	}
}

@(test)
test_simulation_message_store_init_publishes_existing_directory_and_resets_after_failure :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 127)
		defer simulation_test_end(&ctx)

		storage := sim_world_storage_context(&ctx.sim.world)
		shard_dir := "/retained-existing-shard"
		message_dir := "/retained-existing-shard/messages"
		testing.expect(t, storage_io.make_directory(storage, shard_dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		// Deliberately leave the messages entry unsynced in its parent. Init must
		// publish it even though the directory already exists.
		testing.expect(t, storage_io.make_directory(storage, message_dir) == nil)
		workspace := "retained-existing-directory"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		store: Message_Store
		testing.expect(t, init_message_store_with_storage(&store, storage, shard_dir, shard, 24 * time.Hour, 0))
		testing.expect(t, shutdown_message_store(&store))

		sim_world_crash(&ctx.sim.world)
		storage = sim_world_storage_context(&ctx.sim.world)
		directory_exists, exists_err := storage_io.exists(storage, message_dir)
		testing.expect(t, exists_err == nil && directory_exists, "existing messages directory should survive init publication")
		testing.expect(t, init_message_store_with_storage(&store, storage, shard_dir, shard, 24 * time.Hour, 0))
		testing.expect(t, shutdown_message_store(&store))

		broken_shard_dir := "/retained-broken-shard"
		broken_message_dir := "/retained-broken-shard/messages"
		testing.expect(t, storage_io.make_directory(storage, broken_shard_dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		testing.expect(t, storage_io.make_directory(storage, broken_message_dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, broken_shard_dir) == nil)
		manifest_path := "/retained-broken-shard/messages/manifest"
		manifest, open_err := storage_io.open(storage, manifest_path, {.Write, .Create, .Excl})
		testing.expect(t, open_err == nil && manifest != nil)
		if manifest != nil {
			_, write_err := storage_io.write(manifest, []byte{1, 2, 3})
			testing.expect(t, write_err == nil)
			testing.expect(t, storage_io.sync(manifest) == nil)
			testing.expect(t, storage_io.close(manifest) == nil)
			testing.expect(t, storage_io.sync_directory(storage, broken_message_dir) == nil)
		}
		testing.expect(t, !init_message_store_with_storage(&store, storage, broken_shard_dir, shard, 24 * time.Hour, 0))
		testing.expect(
			t,
			!store.enabled && store.directory == "" && store.wal.file == nil && store.wal.path == "" && len(store.segments) == 0,
			"failed init should reset the destination store",
		)
	}
}

@(test)
test_message_store_sealed_dedup_search_honors_independent_window :: proc(t: ^testing.T) {
	workspace := "retained-message-sealed-dedup-window"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-sealed-dedup-window"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0, 2 * time.Minute))
	now := nrc_time_unix_nanos()
	old := test_retained_message(workspace, 42, 1, now - i64(3 * time.Minute))
	result, sequence := append_or_deduplicate_message(&store, &old)
	testing.expect_value(t, result, Message_Store_Result.Appended); testing.expect_value(t, sequence, u64(1))
	testing.expect(t, rotate_message_store(&store, old.accepted_at_ns + 1))
	testing.expect_value(t, len(store.segments), 1)
	testing.expect_value(t, message_store_next_dedup_segment(&store, 0, message_store_dedup_cutoff(&store, now)), -1)

	reused := test_retained_message(workspace, 42, 1, now)
	result, sequence = append_or_deduplicate_message(&store, &reused)
	testing.expect_value(t, result, Message_Store_Result.Appended); testing.expect_value(t, sequence, u64(2))
	testing.expect_value(t, len(store.segments), 1)
	testing.expect(t, rotate_message_store(&store, now + 1))
	testing.expect(t, len(store.segments[1].dedup_filter) > 0)
	retry := test_retained_message(workspace, 42, 1, now + i64(time.Second))
	result, _ = append_or_deduplicate_message(&store, &retry)
	testing.expect_value(t, result, Message_Store_Result.Lookup_Required)
	testing.expect_value(
		t,
		message_store_next_dedup_segment(&store, len(store.segments) - 1, message_store_dedup_cutoff(&store, retry.accepted_at_ns), &retry),
		1,
	)
	recent := test_retained_message(workspace, 42, 2, now + i64(time.Second))
	result, sequence = append_or_deduplicate_message(&store, &recent)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	testing.expect_value(t, sequence, u64(3))
	testing.expect(t, shutdown_message_store(&store))
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0, 2 * time.Minute))
	testing.expect(t, len(store.segments[1].dedup_filter) > 0)
	testing.expect(t, maintain_message_store(&store, now + i64(3 * time.Minute)))
	testing.expect_value(t, len(store.segments), 1)
	testing.expect_value(t, len(store.segments[0].dedup_filter), 0)
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_direct_append_capacity_while_required_rotation_is_pinned :: proc(t: ^testing.T) {
	workspace := "retained-direct-pinned-capacity"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-direct-pinned-capacity"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	now := nrc_time_unix_nanos()
	seed := test_retained_message(workspace, 42, 1, now)
	result, _ := append_or_deduplicate_message(&store, &seed)
	testing.expect_value(t, result, Message_Store_Result.Appended)

	// Model an active generation at the exact sealed-index ceiling. A genuine
	// lazy WAL reader prevents rotation, but this is backpressure, not poison.
	store.wal.record_count = MESSAGE_MAX_INDEX_RECORDS
	store.async_readers = 1
	next := test_retained_message(workspace, 42, 2, now + 1)
	result, _ = append_or_deduplicate_message(&store, &next)
	testing.expect_value(t, result, Message_Store_Result.Capacity)
	testing.expect(t, !store.poisoned)
	testing.expect_value(t, store.high_water, u64(1))

	store.async_readers = 0
	store.wal.record_count = 1
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_active_index_arena_resets_only_after_safe_rotation :: proc(t: ^testing.T) {
	workspace := "retained-message-arena-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-arena"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	cache_budget := Message_Active_Cache_Budget {
		limit_bytes = 1024 * 1024,
	}
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0, active_cache_budget = &cache_budget))
	testing.expect(t, store.active_read_file == nil)
	testing.expect(t, !store.active_arena_ready)
	now := nrc_time_unix_nanos()
	for marker in 1 ..= 300 {
		message := test_retained_message(workspace, u64(marker % 8 + 1), u64(marker), now + i64(marker))
		result, _ := append_or_deduplicate_message(&store, &message)
		testing.expect_value(t, result, Message_Store_Result.Appended)
	}
	testing.expect(t, store.active_arena_ready)
	used_before_rotation := store.active_index_arena.total_used
	cached_before_rotation := cache_budget.used_bytes
	testing.expect(t, used_before_rotation > 0)
	testing.expect(t, cached_before_rotation > 0)
	testing.expect_value(t, len(store.active_dedup), 300)
	testing.expect_value(t, len(store.active_offsets), 8)

	store.async_readers = 1
	generation := store.active_generation
	testing.expect(t, !rotate_message_store(&store, now + i64(time.Hour)))
	testing.expect_value(t, store.active_generation, generation)
	testing.expect_value(t, store.active_index_arena.total_used, used_before_rotation)
	testing.expect_value(t, cache_budget.used_bytes, cached_before_rotation)
	testing.expect(t, store.wal.enabled)
	testing.expect(t, store.active_read_file == nil)
	store.async_readers = 0

	testing.expect(t, rotate_message_store(&store, now + i64(time.Hour)))
	testing.expect(t, store.active_read_file == nil)
	testing.expect_value(t, store.active_generation, generation + 2)
	testing.expect_value(t, len(store.active_dedup), 0)
	testing.expect_value(t, len(store.active_offsets), 0)
	testing.expect(t, store.active_index_arena.total_used < used_before_rotation)
	testing.expect_value(t, cache_budget.used_bytes, u64(0))

	message := test_retained_message(workspace, 9, 301, now + i64(time.Hour))
	result, sequence := append_or_deduplicate_message(&store, &message)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	testing.expect_value(t, sequence, u64(301))
	testing.expect_value(t, len(store.active_dedup), 1)
	testing.expect_value(t, len(store.active_offsets), 1)
	testing.expect(t, shutdown_message_store(&store))
	testing.expect_value(t, cache_budget.used_bytes, u64(0))
	testing.expect(t, !store.active_arena_ready)
}

@(test)
test_message_store_active_cache_is_bounded_recovered_and_released :: proc(t: ^testing.T) {
	workspace := "retained-message-active-cache-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-active-cache"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	budget := Message_Active_Cache_Budget {
		limit_bytes = 1,
	}
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0, active_cache_budget = &budget))
	now := nrc_time_unix_nanos()
	first := test_retained_message(workspace, 42, 1, now)
	first_size, valid := message_record_size(&first); testing.expect(t, valid)
	budget.limit_bytes = u64(first_size)
	result, _ := append_or_deduplicate_message(&store, &first); testing.expect_value(t, result, Message_Store_Result.Appended)
	entries := store.active_offsets[Message_Conversation_Key{workspace, 42}]
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, len(entries[0].cached_payload), first_size)
	testing.expect_value(t, budget.used_bytes, u64(first_size))

	second := test_retained_message(workspace, 42, 2, now + 1)
	result, _ = append_or_deduplicate_message(&store, &second); testing.expect_value(t, result, Message_Store_Result.Appended)
	entries = store.active_offsets[Message_Conversation_Key{workspace, 42}]
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, len(entries[1].cached_payload), 0)
	testing.expect_value(t, budget.used_bytes, u64(first_size))

	crash_message_store_for_test(&store)
	testing.expect_value(t, budget.used_bytes, u64(0))
	budget.limit_bytes = u64(first_size * 2)
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0, active_cache_budget = &budget))
	entries = store.active_offsets[Message_Conversation_Key{workspace, 42}]
	testing.expect_value(t, len(entries), 2)
	testing.expect(t, len(entries[0].cached_payload) > 0 && len(entries[1].cached_payload) > 0)
	testing.expect_value(t, budget.used_bytes, u64(first_size * 2))
	testing.expect(t, rotate_message_store(&store, now + i64(time.Hour)))
	testing.expect_value(t, budget.used_bytes, u64(0))
	third := test_retained_message(workspace, 42, 3, now + i64(time.Hour))
	result, _ = append_or_deduplicate_message(&store, &third); testing.expect_value(t, result, Message_Store_Result.Appended)
	testing.expect(t, budget.used_bytes > 0)
	testing.expect(t, shutdown_message_store(&store))
	testing.expect_value(t, budget.used_bytes, u64(0))
}

@(test)
test_message_store_active_cache_budget_is_shared_between_stores :: proc(t: ^testing.T) {
	workspace_a := "retained-message-cache-shared-a"
	workspace_b := "retained-message-cache-shared-b"
	dir_a := test_wal_path("message-cache-shared-a"); _ = os.remove_all(dir_a)
	dir_b := test_wal_path("message-cache-shared-b"); _ = os.remove_all(dir_b)
	testing.expect(t, os.make_directory(dir_a) == nil); defer os.remove_all(dir_a)
	testing.expect(t, os.make_directory(dir_b) == nil); defer os.remove_all(dir_b)
	message_a := test_retained_message(workspace_a, 42, 1, nrc_time_unix_nanos())
	size, valid := message_record_size(&message_a); testing.expect(t, valid)
	budget := Message_Active_Cache_Budget {
		limit_bytes = u64(size),
	}
	stores := new([2]Message_Store)
	defer free(stores)
	testing.expect(
		t,
		init_message_store(&stores[0], dir_a, int(shard_for_workspace(transmute([]byte)workspace_a)), 24 * time.Hour, 0, active_cache_budget = &budget),
	)
	testing.expect(
		t,
		init_message_store(&stores[1], dir_b, int(shard_for_workspace(transmute([]byte)workspace_b)), 24 * time.Hour, 0, active_cache_budget = &budget),
	)
	result, _ := append_or_deduplicate_message(&stores[0], &message_a); testing.expect_value(t, result, Message_Store_Result.Appended)
	message_b := test_retained_message(workspace_b, 42, 2, message_a.accepted_at_ns)
	result, _ = append_or_deduplicate_message(&stores[1], &message_b); testing.expect_value(t, result, Message_Store_Result.Appended)
	entries_a := stores[0].active_offsets[Message_Conversation_Key{workspace_a, 42}]
	entries_b := stores[1].active_offsets[Message_Conversation_Key{workspace_b, 42}]
	testing.expect(t, len(entries_a[0].cached_payload) > 0)
	testing.expect_value(t, len(entries_b[0].cached_payload), 0)
	testing.expect_value(t, budget.used_bytes, u64(size))
	testing.expect(t, shutdown_message_store(&stores[0]))
	testing.expect_value(t, budget.used_bytes, u64(0))
	testing.expect(t, shutdown_message_store(&stores[1]))
}

@(test)
test_message_store_registry_reserve_keeps_embedded_arena_address_stable :: proc(t: ^testing.T) {
	registry: Message_Store_Registry
	testing.expect(t, reserve_message_store_registry_capacity(&registry, 0, 1))
	testing.expect(t, cap(registry.stores) >= LOGICAL_SHARD_COUNT)
	_, append_err := append(&registry.stores, Message_Store{})
	testing.expect(t, append_err == nil)
	testing.expect(t, init_active_message_indexes(&registry.stores[0]))
	arena := &registry.stores[0].active_index_arena
	for _ in 1 ..< LOGICAL_SHARD_COUNT {
		_, err := append(&registry.stores, Message_Store{})
		testing.expect(t, err == nil)
	}
	testing.expect(t, &registry.stores[0].active_index_arena == arena)
	testing.expect(t, append_active_message_offset(&registry.stores[0], "workspace", 42, {sequence = 1}))
	testing.expect_value(t, len(registry.stores[0].active_offsets), 1)
	destroy_active_message_indexes(&registry.stores[0])
	delete(registry.stores)
}

@(test)
test_retained_record_zero_progress_releases_store_reader :: proc(t: ^testing.T) {
	store: Message_Store
	store.async_readers = 1
	dedup := new(Retained_Dedup_Context)
	dedup.store = &store
	dedup.phase = .Record
	dedup.record = make([]byte, 16)
	dedup.holds_store_reader = true
	retained_dedup_on_read(dedup, 0, .NONE)
	testing.expect(t, store.poisoned)
	testing.expect_value(t, store.async_readers, u32(0))

	store.poisoned = false
	store.async_readers = 1
	history := new(Retained_History_Context)
	history.store = &store
	history.record_batch_count = 1
	mem.dynamic_arena_init(&history.message_arena)
	history.message_arena_ready = true
	history.record_storage = make([]byte, 16, mem.dynamic_arena_allocator(&history.message_arena))
	history.holds_store_reader = true
	retained_history_on_record_read(history, 0, .NONE)
	testing.expect(t, store.poisoned)
	testing.expect_value(t, store.async_readers, u32(0))
}

@(test)
test_retained_parallel_read_error_waits_for_all_callbacks :: proc(t: ^testing.T) {
	store: Message_Store
	store.async_readers = 1
	history := new(Retained_History_Context)
	history.store = &store
	history.record_batch_count = 2
	history.parallel_reads = make([]Retained_Parallel_Read, 2)
	history.parallel_pending = 2
	history.holds_store_reader = true
	mem.dynamic_arena_init(&history.message_arena)
	history.message_arena_ready = true
	for &read in history.parallel_reads {
		read.parent = history
		read.storage = make([]byte, 16, mem.dynamic_arena_allocator(&history.message_arena))
	}

	retained_history_on_parallel_record_read(&history.parallel_reads[0], 0, .NONE)
	testing.expect(t, history.parallel_failed)
	testing.expect_value(t, history.parallel_pending, 1)
	testing.expect_value(t, store.async_readers, u32(1))

	retained_history_on_parallel_record_read(&history.parallel_reads[1], 0, .NONE)
	testing.expect_value(t, store.async_readers, u32(0))
}

@(test)
test_retained_async_open_error_and_stale_event_release_reader :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 135)
		defer simulation_test_end(&ctx)
		storage := sim_world_storage_context(&ctx.sim.world)
		outcomes := [4]linux.Errno{.EIO, .EMFILE, .ENFILE, .NONE}
		for fault, index in outcomes {
			stale := index == 3
			store := Message_Store {
				storage       = storage,
				async_readers = 1,
			}
			history := new(Retained_History_Context)
			history.store = &store
			history.holds_store_reader = true
			history.active_wal_source = &store
			store.active_open_pending = true
			pool_before := td.spool.live_allocs
			nrc_io_open_read_file(storage, "/missing-history.wal", history, retained_history_on_active_open, retained_history_read_discard_raw)
			testing.expect_value(t, store.async_readers, u32(1))
			testing.expect(t, !store.poisoned, "open must not complete synchronously")
			testing.expect_value(t, td.spool.live_allocs, pool_before + 1)
			// A second cache miss must not open a duplicate descriptor.
			second := new(Retained_History_Context)
			second.store = &store; second.holds_store_reader = true
			store.async_readers += 1
			append(&second.specs, Retained_Read_Spec{length = 100})
			retained_history_submit_active_batch(second)
			testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)
			testing.expect_value(t, store.async_readers, u32(1))
			if stale do sim_world_crash(&ctx.sim.world)
			testing.expect(t, nrc_sim_run_next_file_read(&ctx.sim, fault))
			testing.expect_value(t, store.async_readers, u32(0))
			testing.expect_value(t, store.poisoned, index == 0)
			testing.expect(t, !store.active_open_pending)
			testing.expect_value(t, td.spool.live_allocs, pool_before)
			storage = sim_world_storage_context(&ctx.sim.world)
		}
	}
}

@(test)
test_retained_sealed_open_reserves_capacity_and_releases_on_failure :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 136)
		defer simulation_test_end(&ctx)
		cache := Message_Sealed_WAL_Cache {
			limit = 1,
		}
		defer delete(cache.entries)
		store := Message_Store {
			storage          = sim_world_storage_context(&ctx.sim.world),
			sealed_wal_cache = &cache,
		}
		append(&store.segments, Message_Segment_Descriptor{generation = 1})
		defer delete(store.segments)
		append(&store.segments[0].conversation_ranges, Message_Conversation_Range{workspace_hash = message_string_hash(""), conversation_id = 42, end = 1})
		defer delete(store.segments[0].conversation_ranges)
		for _ in 0 ..< 2 {
			history := new(Retained_History_Context)
			history.store = &store; history.holds_store_reader = true
			history.sealed_count = 1; history.segment_step = -1
			history.conversation_id = 42
			store.async_readers += 1
			retained_history_open_sealed(history)
		}
		testing.expect_value(t, cache.opening, 1)
		testing.expect_value(t, store.async_readers, u32(1))
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_file_read(&ctx.sim, .EMFILE))
		testing.expect(t, !store.poisoned && !store.segments[0].read_open_pending)
		testing.expect_value(t, cache.opening, 0)
		testing.expect_value(t, store.async_readers, u32(0))
		// A fully reserved cache rejects before submitting another open.
		cache.opening = 1
		history := new(Retained_History_Context)
		history.store = &store; history.holds_store_reader = true
		history.sealed_count = 1; history.segment_step = -1
		history.conversation_id = 42; store.async_readers = 1
		retained_history_open_sealed(history)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 0)
		testing.expect_value(t, store.async_readers, u32(0))
		cache.opening = 0
	}
}

@(test)
test_retained_parallel_read_stale_discard_releases_only_after_last_event :: proc(t: ^testing.T) {
	store: Message_Store
	store.enabled = true
	store.async_readers = 1
	store.rotation_pending = true
	pending_writes := td.message_stores.pending_write_count
	history := new(Retained_History_Context)
	history.store = &store
	history.parallel_reads = make([]Retained_Parallel_Read, 2)
	history.parallel_pending = 2
	history.holds_store_reader = true
	for &read in history.parallel_reads do read.parent = history
	first := &history.parallel_reads[0]
	second := &history.parallel_reads[1]

	retained_history_parallel_read_discard_raw(first)
	testing.expect_value(t, store.async_readers, u32(1))
	testing.expect_value(t, history.parallel_pending, 1)
	testing.expect_value(t, td.message_stores.pending_write_count, pending_writes)

	retained_history_on_parallel_record_read(second, 0, .NONE)
	testing.expect_value(t, store.async_readers, u32(0))
	testing.expect(t, !store.poisoned)
	testing.expect_value(t, td.message_stores.pending_write_count, pending_writes)
}

@(test)
test_simulation_parallel_file_read_cancel_then_completion_is_cleanup_only :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 134)
		defer simulation_test_end(&ctx)
		storage := sim_world_storage_context(&ctx.sim.world)
		file, open_err := storage_io.open(storage, "/parallel-cancel.wal", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		defer storage_io.discard(file)
		_, write_err := storage_io.write(file, []byte{1})
		testing.expect(t, write_err == nil)

		store: Message_Store
		store.enabled = true
		store.async_readers = 1
		store.rotation_pending = true
		pending_writes := td.message_stores.pending_write_count
		history := new(Retained_History_Context)
		history.store = &store
		history.wal_file = file
		history.parallel_reads = make([]Retained_Parallel_Read, 2)
		history.parallel_pending = 2
		history.holds_store_reader = true
		buffers: [2][1]byte
		for &parallel, i in history.parallel_reads {
			parallel.parent = history
			parallel.storage = buffers[i][:]
			_ = nrc_io_read_file_at(
				file,
				parallel.storage,
				0,
				&parallel,
				retained_history_on_parallel_record_read_raw,
				retained_history_parallel_read_discard_raw,
			)
		}
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 2)
		first_index := sim_world_domain_event_index(&ctx.sim.world, .File_Read, 0)
		testing.expect(t, first_index >= 0)
		if first_index < 0 do return
		first_id := ctx.sim.world.events[first_index].id
		testing.expect(t, sim_world_cancel_event(&ctx.sim.world, first_id))
		testing.expect_value(t, history.parallel_pending, 1)
		testing.expect(t, history.parallel_discarded)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)

		testing.expect(t, nrc_sim_run_next_file_read(&ctx.sim))
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 0)
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect(t, !store.poisoned)
		testing.expect_value(t, td.message_stores.pending_write_count, pending_writes)
	}
}

@(test)
test_retained_active_sequence_bound :: proc(t: ^testing.T) {
	entries := [?]Message_Offset_Entry{{sequence = 1}, {sequence = 7}, {sequence = 13}}
	testing.expect_value(t, retained_history_active_sequence_bound(entries[:], 0, false), 0)
	testing.expect_value(t, retained_history_active_sequence_bound(entries[:], 1, false), 0)
	testing.expect_value(t, retained_history_active_sequence_bound(entries[:], 1, true), 1)
	testing.expect_value(t, retained_history_active_sequence_bound(entries[:], 6, false), 1)
	testing.expect_value(t, retained_history_active_sequence_bound(entries[:], 7, false), 1)
	testing.expect_value(t, retained_history_active_sequence_bound(entries[:], 7, true), 2)
	testing.expect_value(t, retained_history_active_sequence_bound(entries[:], 14, false), len(entries))
}

@(test)
test_message_index_pointer_comparators_match_value_order :: proc(t: ^testing.T) {
	index_less := proc(a, b: Message_Index_Record) -> bool {
		if a.workspace_hash != b.workspace_hash do return a.workspace_hash < b.workspace_hash
		if a.conversation_id != b.conversation_id do return a.conversation_id < b.conversation_id
		return a.sequence < b.sequence
	}
	dedup_less := proc(a, b: Message_Index_Record) -> bool {
		if a.workspace_hash != b.workspace_hash do return a.workspace_hash < b.workspace_hash
		if a.principal_hash != b.principal_hash do return a.principal_hash < b.principal_hash
		for value, i in a.client_id {
			if value != b.client_id[i] do return value < b.client_id[i]
		}
		return false
	}
	input: [128]Message_Index_Record
	for &record, i in input {
		record.workspace_hash = i < 64 ? 0 : u64(i % 3) * (max(u64) / 2)
		record.conversation_id = u64(i % 5)
		record.principal_hash = i < 64 ? 0 : u64(i % 7)
		record.sequence = u64(i % 11)
		record.client_id[i % 16] = byte((i / 16) % 2) * 255
		record.offset = u64(i) // Distinct non-key data, including equal-key records.
	}
	for kind in 0 ..< 2 {
		less := kind == 0 ? index_less : dedup_less
		cmp := kind == 0 ? message_index_record_cmp : message_dedup_record_cmp
		for &a in input {
			for &b in input {
				expected: slice.Ordering = less(a, b) ? .Less : (less(b, a) ? .Greater : .Equal)
				testing.expect_value(t, cmp(&a, &b, nil), expected)
			}
		}
		expected, actual := input, input
		slice.sort_by(expected[:], less)
		slice.sort_by_generic_cmp(actual[:], cmp, nil)
		for record, i in actual do testing.expect_value(t, record, expected[i])
	}
}

@(test)
test_message_store_clustering_rejects_legacy_offsets :: proc(t: ^testing.T) {
	dir := test_wal_path("message-legacy-clustering")
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store := Message_Store {
		directory = dir,
		storage   = storage_io.host_context(),
	}
	source_path := message_store_path(dir, 1, "wal"); defer delete(source_path)
	sealed_path := message_store_path(dir, 2, "wal"); defer delete(sealed_path)
	message := test_retained_message("legacy-offsets", 1, 1, nrc_time_unix_nanos())
	message.sequence = 1
	message.fingerprint = message_fingerprint(&message)
	size, valid := message_record_size(&message)
	if !testing.expect(t, valid) do return
	record := make([]byte, persistence.LEGACY_LOG_HEADER_SIZE + size); defer delete(record)
	endian.put_u32(record[0:], .Big, MESSAGE_WAL_MAGIC)
	endian.put_u16(record[4:], .Big, MESSAGE_WAL_VERSION)
	record[6] = 1
	endian.put_u32(record[8:], .Big, u32(size))
	testing.expect(t, encode_message_record(&message, record[persistence.LEGACY_LOG_HEADER_SIZE:]))
	endian.put_u32(record[44:], .Big, persistence.compute_record_crc(record, size))
	testing.expect(t, os.write_entire_file(source_path, record) == nil)
	message_scan_context = {
		mode = .Validate,
	}
	inspection := persistence.inspect_wal_file_strict(source_path, MESSAGE_WAL_MAGIC, 0, message_scan_record)
	message_scan_context = {}
	if !testing.expect(t, inspection.ok) do return
	_, clustered := cluster_message_segment_wal(&store, 1, 2)
	testing.expect(t, !clustered)
	testing.expect(t, !os.exists(sealed_path))
	testing.expect(t, os.exists(source_path))
}

@(test)
test_message_store_clustered_read_runs :: proc(t: ^testing.T) {
	// Single-conversation runs cross the read-buffer boundary; interleaved and
	// grouped conversations exercise gaps, backward seeks and short final runs.
	for layout in 0 ..< 3 {
		workspace := "retained-read-runs"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path(fmt.tprintf("message-read-runs-%d", layout))
		_ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
		store: Message_Store
		if !testing.expect(t, init_message_store(&store, dir, shard, 48 * time.Hour, 0)) do return
		defer shutdown_message_store(&store)
		now := nrc_time_unix_nanos()
		content: [persistence.WRITE_BATCH_MAX_BYTES + 1]byte
		for &value, index in content do value = byte(index % 251)
		for i in 0 ..< 512 {
			conversation := layout == 0 ? 1 : (layout == 1 ? i % 3 + 1 : (i / 40) % 3 + 1)
			message := test_retained_message(workspace, u64(conversation), u64(i + 1), now)
			message.content = content[:i == 255 ? len(content) : 1024 + (i % 8) * 128]
			result, _ := append_or_deduplicate_message(&store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
		}
		testing.expect(t, rotate_message_store(&store, now + i64(time.Hour)))
		testing.expect_value(t, store.high_water, u64(512))
		segment := store.segments[0]
		index := read_validated_message_segment_index(&store, segment); defer delete(index)
		if !testing.expect(t, index != nil) do return
		path := message_store_path(store.directory, segment.generation, "wal"); defer delete(path)
		wal, err := os.read_entire_file(path, context.allocator); defer delete(wal)
		if !testing.expect(t, err == nil) do return
		message_scan_context = {
			mode = .Validate,
		}
		inspection := persistence.inspect_wal_file_strict(path, MESSAGE_WAL_MAGIC, shard, message_scan_record)
		message_scan_context = {}
		testing.expect(t, inspection.ok)
		testing.expect_value(t, inspection.record_count, u64(512))
		for entry in 0 ..< 512 {
			indexed := index[MESSAGE_INDEX_HEADER_SIZE + entry * MESSAGE_INDEX_ENTRY_SIZE:]
			offset := int(message_get_u64(indexed[32:])); length := int(message_get_u32(indexed[40:]))
			message, ok := decode_message_record(wal[offset + persistence.LOG_HEADER_SIZE:offset + length])
			if !testing.expect(t, ok) do return
			defer destroy_retained_message(&message)
			i := int(message_get_u64(message.client_message_id[:])) - 1
			if !testing.expect(t, i >= 0 && i < 512) do return
			conversation := layout == 0 ? 1 : (layout == 1 ? i % 3 + 1 : (i / 40) % 3 + 1)
			testing.expect_value(t, message.conversation_id, u64(conversation))
			testing.expect_value(t, message.sequence, u64(i + 1))
			testing.expect_value(t, message.sequence, message_get_u64(indexed[16:]))
			testing.expect(t, bytes.equal(message.content, content[:i == 255 ? len(content) : 1024 + (i % 8) * 128]))
			testing.expect_value(t, message.fingerprint, message_fingerprint(&message))
		}
	}
}

@(test)
test_message_store_sealed_index_is_sorted_and_rebuilt :: proc(t: ^testing.T) {
	workspace := "retained-message-index-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-index"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store; testing.expect(t, init_message_store(&store, dir, shard, 48 * time.Hour, 0))
	now := nrc_time_unix_nanos()
	conversations := [5]u64{9, 2, 9, 3, 2}
	for conversation, marker in conversations {
		message := test_retained_message(workspace, conversation, u64(marker) + store.high_water * 100, now)
		result, _ := append_or_deduplicate_message(&store, &message); testing.expect_value(t, result, Message_Store_Result.Appended)
	}
	testing.expect(t, rotate_message_store(&store, now + i64(time.Hour)))
	testing.expect_value(t, len(store.segments), 1)
	testing.expect_value(t, len(store.segments[0].conversation_ranges), 3)
	expected_conversations := [3]u64{2, 3, 9}
	expected_starts := [3]u64{0, 2, 3}
	for conversation, expected_index in expected_conversations {
		start, end, found := retained_history_conversation_range(&store.segments[0], message_string_hash(workspace), conversation)
		testing.expect(t, found)
		testing.expect_value(t, end - start, conversation == 3 ? u64(1) : u64(2))
		testing.expect_value(t, start, expected_starts[expected_index])
	}
	index_path := message_store_path(store.directory, store.segments[0].generation, "idx")
	data, err := os.read_entire_file(
		index_path,
		context.allocator,
	); testing.expect(t, err == nil); testing.expect(t, validate_message_segment_index(&store, store.segments[0]))
	defer delete(data)
	checksum := message_get_u64(data[56:])
	testing.expect(t, validate_message_segment_index_data(&store, store.segments[0], data))
	testing.expect(t, validate_message_segment_index_data(&store, store.segments[0], data))
	testing.expect_value(t, message_get_u64(data[56:]), checksum)
	wal_path := message_store_path(store.directory, store.segments[0].generation, "wal")
	wal_data, wal_err := os.read_entire_file(wal_path, context.allocator)
	delete(wal_path)
	defer delete(wal_data)
	testing.expect(t, wal_err == nil)
	count := int(message_get_u64(data[24:])); previous_workspace, previous_conversation, previous_sequence: u64
	expected_offset: u64
	expected_physical_conversations := [5]u64{2, 2, 3, 9, 9}
	for i in 0 ..< count {
		entry := data[MESSAGE_INDEX_HEADER_SIZE + i * MESSAGE_INDEX_ENTRY_SIZE:]
		workspace_hash, conversation, sequence := message_get_u64(entry), message_get_u64(entry[8:]), message_get_u64(entry[16:])
		offset := message_get_u64(entry[32:])
		length := message_get_u32(entry[40:])
		if i > 0 do testing.expect(t, workspace_hash > previous_workspace || workspace_hash == previous_workspace && (conversation > previous_conversation || conversation == previous_conversation && sequence > previous_sequence))
		testing.expect_value(t, offset, expected_offset)
		testing.expect_value(t, conversation, expected_physical_conversations[i])
		message, decoded := decode_message_record(wal_data[int(offset) + persistence.LOG_HEADER_SIZE:int(offset) + int(length)])
		testing.expect(t, decoded)
		testing.expect_value(t, message.workspace, workspace)
		testing.expect_value(t, message.conversation_id, conversation)
		testing.expect_value(t, message.sequence, sequence)
		destroy_retained_message(&message)
		expected_offset += u64(length)
		previous_workspace, previous_conversation, previous_sequence = workspace_hash, conversation, sequence
	}
	testing.expect_value(t, expected_offset, u64(len(wal_data)))
	for corruption in 0 ..< 5 {
		bad := make([]byte, len(data)); defer delete(bad)
		copy(bad, data)
		switch corruption {
		case 0:
			bad[56] ~= 1 // checksum
		case 1:
			message_put_u64(bad[8:], store.segments[0].generation + 1)
		case 2:
			message_put_u64(bad[MESSAGE_INDEX_HEADER_SIZE + 32:], 1) // noncontiguous offset
		case 3:
			message_put_u64(bad[MESSAGE_INDEX_HEADER_SIZE + MESSAGE_INDEX_ENTRY_SIZE + 16:], message_get_u64(bad[MESSAGE_INDEX_HEADER_SIZE + 16:])) // repeated sequence
		case 4:
			message_put_u64(bad[40:], 0) // index layout
		}
		if corruption != 0 {
			message_put_u64(bad[56:], 0)
			message_put_u64(bad[56:], xxhash.XXH64(bad))
		}
		testing.expect(t, os.write_entire_file(index_path, bad) == nil)
		invalid := read_validated_message_segment_index(&store, store.segments[0])
		testing.expect(t, invalid == nil)
		delete(invalid)
		testing.expect(t, shutdown_message_store(&store))
		testing.expect(t, init_message_store(&store, dir, shard, 48 * time.Hour, 0))
		rebuilt := read_validated_message_segment_index(&store, store.segments[0])
		testing.expect(t, bytes.equal(rebuilt, data), "rebuild must preserve both serialized index orders and checksum")
		delete(rebuilt)
		testing.expect_value(t, len(store.segments[0].conversation_ranges), 3)
	}
	_ = os.remove(index_path); testing.expect(t, shutdown_message_store(&store))
	testing.expect(
		t,
		init_message_store(&store, dir, shard, 48 * time.Hour, 0),
	); testing.expect(t, os.exists(index_path)); testing.expect(t, validate_message_segment_index(&store, store.segments[0]))
	testing.expect_value(t, len(store.segments[0].conversation_ranges), 3)
	delete(index_path); testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_sealed_index_cache_is_bounded_and_keeps_newest_segment :: proc(t: ^testing.T) {
	workspace := "retained-message-sealed-index-cache"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-sealed-index-cache"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	budget := Message_Sealed_Index_Cache_Budget {
		limit_bytes = 2 * MESSAGE_INDEX_ENTRY_SIZE,
	}
	defer delete(budget.entries)
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 48 * time.Hour, 0, sealed_index_cache = &budget))
	now := nrc_time_unix_nanos()
	for segment_index in 0 ..< 2 {
		for i in 0 ..< 2 {
			marker := u64(segment_index * 2 + i + 1)
			message := test_retained_message(workspace, 42, marker, now + i64(marker))
			result, _ := append_or_deduplicate_message(&store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
		}
		testing.expect(t, rotate_message_store(&store, now + i64(segment_index + 1)))
	}
	testing.expect_value(t, len(store.segments), 2)
	testing.expect_value(t, len(store.segments[0].cached_message_index), 0)
	testing.expect_value(t, len(store.segments[1].cached_message_index), 2 * MESSAGE_INDEX_ENTRY_SIZE)
	testing.expect_value(t, budget.used_bytes, u64(2 * MESSAGE_INDEX_ENTRY_SIZE))
	testing.expect(t, shutdown_message_store(&store))
	testing.expect_value(t, budget.used_bytes, u64(0))
}

@(test)
test_message_store_sealed_index_cache_does_not_evict_pinned_reader :: proc(t: ^testing.T) {
	budget := Message_Sealed_Index_Cache_Budget {
		limit_bytes = MESSAGE_INDEX_ENTRY_SIZE,
	}
	defer delete(budget.entries)
	stores := [2]^Message_Store{new(Message_Store), new(Message_Store)}
	defer {for store in stores {free(store)}}
	for store, i in stores {
		store.sealed_index_cache = &budget
		_, append_err := append(&store.segments, Message_Segment_Descriptor{generation = u64(i + 1)})
		testing.expect(t, append_err == nil)
	}
	entries: [MESSAGE_INDEX_ENTRY_SIZE]byte
	cache_message_segment_index(stores[0], &stores[0].segments[0], entries[:])
	stores[0].async_readers = 1
	cache_message_segment_index(stores[1], &stores[1].segments[0], entries[:])
	testing.expect_value(t, len(stores[0].segments[0].cached_message_index), MESSAGE_INDEX_ENTRY_SIZE)
	testing.expect_value(t, len(stores[1].segments[0].cached_message_index), 0)
	stores[0].async_readers = 0
	cache_message_segment_index(stores[1], &stores[1].segments[0], entries[:])
	testing.expect_value(t, len(stores[0].segments[0].cached_message_index), 0)
	testing.expect_value(t, len(stores[1].segments[0].cached_message_index), MESSAGE_INDEX_ENTRY_SIZE)
	for store in stores {destroy_message_segment_metadata(store, store.segments[:]); delete(store.segments)}
	testing.expect_value(t, budget.used_bytes, u64(0))
	testing.expect_value(t, len(budget.entries), 0)
}

@(test)
test_message_store_sealed_wal_cache_is_bounded_and_does_not_evict_pinned_reader :: proc(t: ^testing.T) {
	dir := test_wal_path("message-store-sealed-wal-cache"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	cache := Message_Sealed_WAL_Cache {
		limit = 1,
	}
	defer delete(cache.entries)
	stores := [2]^Message_Store{new(Message_Store), new(Message_Store)}
	defer {for store in stores do free(store)}
	paths: [2]string
	defer {for path in paths do delete(path)}
	for store, i in stores {
		store.sealed_wal_cache = &cache
		store.storage = storage_io.host_context()
		_, append_err := append(&store.segments, Message_Segment_Descriptor{generation = u64(i + 1)})
		testing.expect(t, append_err == nil)
		paths[i] = fmt.aprintf("%s/%d.wal", dir, i + 1)
		testing.expect(t, os.write_entire_file(paths[i], nil) == nil)
	}
	opened, open_err := storage_io.open(stores[0].storage, paths[0])
	testing.expect(t, open_err == nil)
	file, owned, capacity := cache_message_segment_read_file(stores[0], &stores[0].segments[0], opened)
	testing.expect(t, file != nil && !owned && !capacity)
	testing.expect_value(t, len(cache.entries), 1)
	opened, open_err = storage_io.open(stores[1].storage, paths[1])
	testing.expect(t, open_err == nil)
	fallback, fallback_owned, fallback_capacity := cache_message_segment_read_file(stores[1], &stores[1].segments[0], opened)
	testing.expect(t, fallback == nil && !fallback_owned && fallback_capacity)
	testing.expect(t, stores[1].segments[0].read_file == nil)
	testing.expect_value(t, len(cache.entries), 1)
	release_message_segment_read_borrow(&stores[0].segments[0])
	opened, open_err = storage_io.open(stores[1].storage, paths[1])
	testing.expect(t, open_err == nil)
	file, owned, capacity = cache_message_segment_read_file(stores[1], &stores[1].segments[0], opened)
	testing.expect(t, file != nil && !owned && !capacity)
	testing.expect(t, stores[0].segments[0].read_file == nil)
	testing.expect(t, stores[1].segments[0].read_file != nil)
	testing.expect_value(t, len(cache.entries), 1)
	release_message_segment_read_borrow(&stores[1].segments[0])
	destroy_message_segment_metadata(stores[1], stores[1].segments[:])
	testing.expect(t, stores[1].segments[0].read_file == nil)
	testing.expect_value(t, len(cache.entries), 0)
	delete(stores[0].segments)
	delete(stores[1].segments)
}

@(test)
test_message_store_failed_purge_publication_releases_sealed_index_cache :: proc(t: ^testing.T) {
	workspace := "retained-message-failed-purge-cache"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-failed-purge-cache"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	budget := Message_Sealed_Index_Cache_Budget {
		limit_bytes = MESSAGE_INDEX_ENTRY_SIZE,
	}
	defer delete(budget.entries)
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, time.Hour, 0, sealed_index_cache = &budget))
	now := nrc_time_unix_nanos()
	message := test_retained_message(workspace, 42, 1, now - i64(2 * time.Hour))
	result, _ := append_or_deduplicate_message(&store, &message)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	testing.expect(t, rotate_message_store(&store, now))
	testing.expect_value(t, budget.used_bytes, u64(MESSAGE_INDEX_ENTRY_SIZE))
	hidden_directory := fmt.aprintf("%s-hidden", store.directory); defer delete(hidden_directory)
	testing.expect(t, os.rename(store.directory, hidden_directory) == nil)
	testing.expect(t, !maintain_message_store(&store, now))
	testing.expect_value(t, budget.used_bytes, u64(0))
	testing.expect_value(t, len(budget.entries), 0)
	testing.expect(t, os.rename(hidden_directory, store.directory) == nil)
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_clustered_seal_staging_is_invisible_until_manifest_publish :: proc(t: ^testing.T) {
	workspace := "retained-message-cluster-staging-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-cluster-staging"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 48 * time.Hour, 0))
	now := nrc_time_unix_nanos()
	conversations := [3]u64{7, 3, 7}
	for conversation, marker in conversations {
		message := test_retained_message(workspace, conversation, u64(marker + 1), now + i64(marker))
		result, _ := append_or_deduplicate_message(&store, &message)
		testing.expect_value(t, result, Message_Store_Result.Appended)
	}
	source_generation := store.active_generation
	testing.expect(t, persistence.shutdown_wal(&store.wal))
	sealed_bytes, clustered := cluster_message_segment_wal(&store, source_generation, source_generation + 1)
	testing.expect(t, clustered)
	testing.expect_value(t, sealed_bytes, store.active_bytes)
	orphan_active := message_store_path(store.directory, source_generation + 2, "wal")
	testing.expect(t, create_empty_message_wal(orphan_active))
	delete(orphan_active)

	crash_message_store_for_test(&store)
	testing.expect(t, init_message_store(&store, dir, shard, 48 * time.Hour, 0))
	testing.expect_value(t, store.active_generation, source_generation)
	testing.expect_value(t, store.high_water, u64(3))
	testing.expect_value(t, len(store.segments), 0)
	store.fsync_in_flight = true
	testing.expect(t, !rotate_message_store(&store, now + i64(time.Hour)))
	store.fsync_in_flight = false
	testing.expect(t, rotate_message_store(&store, now + i64(time.Hour)))
	testing.expect_value(t, store.active_generation, source_generation + 2)
	testing.expect_value(t, len(store.segments), 1)
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_async_message_fsync_failure_clears_rotation_for_shutdown :: proc(t: ^testing.T) {
	workspace := "retained-message-async-fsync-failure"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-async-fsync-failure"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, time.Hour, 0))
	store.fsync_in_flight = true
	store.rotation_pending = true
	store.fsync_snapshot = {
		last_hash     = store.wal.last_hash,
		record_count  = store.wal.record_count,
		pending_bytes = store.wal.pending_bytes,
	}
	store.fsync_started = time.now()
	previous_logger := context.logger
	context.logger = log.nil_logger()
	retained_message_fsync_complete(&store, .EIO)
	context.logger = previous_logger
	testing.expect(t, store.poisoned && !store.wal.enabled)
	testing.expect(t, !store.fsync_in_flight && !store.rotation_pending)
	testing.expect(t, shutdown_message_store(&store))
}

when NRC_SIMULATION {
	@(test)
	test_retained_process_crash_discards_pending_and_deferred_callbacks :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 133)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)

		workspace := "retained-process-crash-discard"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "crash-writer", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return

		storage := sim_world_storage_context(&ctx.sim.world)
		shard_dir := "/retained-process-crash-shard"
		testing.expect(t, storage_io.make_directory(storage, shard_dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, shard_dir, shard, 24 * time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		td.message_stores.write_batch_records = 1
		defer shutdown_message_store_registry(&td.message_stores)

		initial := Retained_Message {
			workspace        = workspace,
			conversation_id  = 42,
			sender_name      = "crash-writer",
			sender_principal = "crash-writer",
			accepted_at_ns   = NRC_SIM_TIME_EPOCH_NANOS,
			content_type     = u8(pr.MessageContentType.PlainText),
			content          = transmute([]byte)string("durable foundation"),
		}
		message_put_u64(initial.client_message_id[:], 1)
		result, sequence := append_or_deduplicate_message(store, &initial)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect_value(t, sequence, u64(1))
		persistence.force_fsync(&store.wal)
		testing.expect(t, rotate_message_store(store, NRC_SIM_TIME_EPOCH_NANOS + i64(time.Hour)))

		duplicate_id: [16]byte
		message_put_u64(duplicate_id[:], 1)
		process_send_message_v2(
			conn,
			pr.SendMessageV2Request {
				conv_id = 42,
				client_message_id = duplicate_id,
				correlation_id = 1,
				content_type = .PlainText,
				content = transmute([]byte)string("durable foundation"),
			},
		)
		for nrc_sim_run_next_file_read(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
		nrc_sim_clear_inboxes(&ctx.sim)

		for marker in 2 ..= 3 {
			client_message_id: [16]byte
			message_put_u64(client_message_id[:], u64(marker))
			process_send_message_v2(
				conn,
				pr.SendMessageV2Request {
					conv_id = 42,
					client_message_id = client_message_id,
					correlation_id = u32(marker),
					content_type = .PlainText,
					content = transmute([]byte)string("speculative"),
				},
			)
			if marker == 2 {
				process_send_message_v2(
					conn,
					pr.SendMessageV2Request {
						conv_id = 42,
						client_message_id = client_message_id,
						correlation_id = 22,
						content_type = .PlainText,
						content = transmute([]byte)string("speculative"),
					},
				)
			}
		}

		testing.expect_value(t, len(store.pending_appends), 2)
		testing.expect_value(t, len(store.deferred_appends), 1)
		testing.expect_value(t, td.message_stores.pending_write_count, 1)
		testing.expect(t, store.write_batch_pending)
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect_value(t, conn.retained_io, 3)
		testing.expect_value(t, conn.pending_io, u32(3))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)

		connections := [?]^NRC_Connection{conn}
		incarnation_before_rejected_crash := ctx.sim.world.process_incarnation
		conn.close_completed = true
		testing.expect(t, !nrc_sim_process_crash_discard_connections(&ctx.sim, connections[:]))
		testing.expect_value(t, ctx.sim.world.process_incarnation, incarnation_before_rejected_crash)
		testing.expect_value(t, len(store.pending_appends), 2)
		testing.expect_value(t, len(store.deferred_appends), 1)
		testing.expect_value(t, conn.pending_io, u32(3))
		conn.close_completed = false
		testing.expect(t, nrc_sim_process_crash_discard_connections(&ctx.sim, connections[:]))
		testing.expect_value(t, len(store.pending_appends), 0)
		testing.expect_value(t, len(store.deferred_appends), 0)
		testing.expect_value(t, td.message_stores.pending_write_count, 0)
		testing.expect(t, !store.write_batch_pending && !store.rotation_pending)
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect_value(t, conn.retained_io, 0)
		testing.expect_value(t, conn.pending_io, u32(0))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)

		crash_message_store_for_test(store)
		storage = sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, init_message_store_with_storage(store, storage, shard_dir, shard, 24 * time.Hour, 0))
		testing.expect_value(t, store.high_water, u64(1))
		testing.expect_value(t, len(store.segments), 1)
		testing.expect_value(t, store.wal.record_count, u64(0))
	}

	@(test)
	test_retained_deferred_readers_drain_during_rotation :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect(t, nbio.init(&td.io) == .NONE)
		defer nbio.destroy(&td.io)
		workspace := "retained-reader-drain"
		conn := simulation_test_install_client(&ctx.sim, 0, workspace, "alice", init_send_queue = true)
		ctx.conns[0] = conn
		if !testing.expect(t, conn != nil) do return
		storage := sim_world_storage_context(&ctx.sim.world)
		dir := "/retained-reader-drain"
		testing.expect(t, storage_io.make_directory(storage, dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		td.message_stores.write_batch_records = 1
		defer shutdown_message_store_registry(&td.message_stores)
		seed := test_retained_message(workspace, 42, 200, nrc_time_unix_nanos())
		result, _ := append_or_deduplicate_message(store, &seed)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect(t, rotate_message_store(store, nrc_time_unix_nanos()))
		seed.client_message_id[0] = 201
		result, _ = append_or_deduplicate_message(store, &seed)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		_ = schedule_retained_message_fsync(store)
		store.commit_started = {}
		testing.expect(t, schedule_retained_message_fsync(store))
		store.active_started_hour -= 1
		for &word in store.segments[0].dedup_filter do word = 0
		req := pr.SendMessageV2Request {
			conv_id      = 42,
			content_type = .PlainText,
			content      = transmute([]byte)string("miss"),
		}
		req.client_message_id[0] = 1; req.correlation_id = 1
		process_send_message_v2(conn, req)
		testing.expect(t, store.rotation_pending && store.async_readers == 0)
		// Deterministic Bloom false positives launch real sealed lookup misses
		// while rotation is waiting on fsync. Completed negative lookups release
		// their store pins before deferred/dedup admission.
		for &word in store.segments[0].dedup_filter do word = max(u64)
		for id in 2 ..= 3 {
			req.client_message_id[0] = u8(id); req.correlation_id = u32(id)
			process_send_message_v2(conn, req)
		}
		req.correlation_id = 4
		process_send_message_v2(conn, req)
		for nrc_sim_run_next_file_read(&ctx.sim) {}
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect_value(t, len(store.pending_appends), 0)
		testing.expect_value(t, len(store.deferred_appends), 3)
		for deferred in store.deferred_appends {
			deferred_ctx := (^Retained_Dedup_Context)(deferred.ctx)
			testing.expect(t, !deferred_ctx.holds_store_reader)
		}
		primary := (^Retained_Dedup_Context)(store.deferred_appends[2].ctx)
		testing.expect_value(t, len(primary.duplicates), 1)
		testing.expect(t, !primary.duplicates[0].holds_store_reader)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		generation := store.active_generation
		for round in 0 ..< 16 {
			if td.message_stores.pending_write_count == 0 do break
			_, ok := flush_pending_retained_message_writes(&td.message_stores)
			testing.expect(t, ok)
			for nrc_sim_run_next_file_write(&ctx.sim) {}
			for nrc_sim_run_next_fsync_completion(&ctx.sim) {}
		}
		testing.expect_value(t, store.high_water, u64(5))
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect_value(t, conn.retained_io, 0)
		store.commit_started = {}
		if schedule_retained_message_fsync(store) do testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, conn.pending_io, u32(0))
		testing.expect_value(t, len(store.deferred_appends), 0)
		testing.expect(t, !store.rotation_pending && store.active_generation > generation)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 4)
		acks: [4]pr.AckSendMessage
		for frame in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
			payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, frame))
			if !testing.expect(t, valid) do continue
			ack, err := pr.parseAckSendMessageMessage(payload)
			if !testing.expect(t, err == nil && ack.client_req_id >= 1 && ack.client_req_id <= 4) do continue
			acks[ack.client_req_id - 1] = ack
		}
		testing.expect_value(t, acks[2].assigned_seq, acks[3].assigned_seq)
		testing.expect_value(t, acks[2].timestamp, acks[3].timestamp)
	}

	@(test)
	test_retained_deferred_incremental_drain :: proc(t: ^testing.T) {
		// Success crosses a rotation; the other cases terminate with a consumed
		// prefix still in the backing array, exercising exactly-once cleanup.
		for outcome in 0 ..< 4 {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			testing.expect(t, nbio.init(&td.io) == .NONE)
			defer nbio.destroy(&td.io)
			workspace := "retained-incremental"
			for client in 0 ..< 5 {
				conn := simulation_test_install_client(&ctx.sim, client, workspace, "alice", init_send_queue = true)
				ctx.conns[client] = conn
				if !testing.expect(t, conn != nil) do return
			}
			storage := sim_world_storage_context(&ctx.sim.world)
			dir := "/retained-incremental"
			testing.expect(t, storage_io.make_directory(storage, dir) == nil)
			testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
			shard := int(shard_for_workspace(transmute([]byte)workspace))
			for &index in td.message_stores.store_index do index = -1
			append(&td.message_stores.stores, Message_Store{})
			store := &td.message_stores.stores[0]
			testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
			td.message_stores.enabled = true
			td.message_stores.store_index[shard] = 0
			td.message_stores.write_batch_records = 1
			defer shutdown_message_store_registry(&td.message_stores)
			req := pr.SendMessageV2Request {
				conv_id      = 42,
				content_type = .PlainText,
				content      = transmute([]byte)string("queued"),
			}
			for id in 1 ..= 16 {
				req.client_message_id[0] = u8(id); req.correlation_id = u32(id)
				process_send_message_v2(ctx.conns[(id - 1) / 4], req)
			}
			// A follower keeps its admitted primary despite cutoff expiry,
			// later ID reuse and rotation; it never repeats key-based admission.
			store.dedup_window = time.Nanosecond
			ctx.sim.world.now += 2 * time.Nanosecond
			req.client_message_id[0] = 2; req.correlation_id = 100
			process_send_message_v2(ctx.conns[4], req)
			testing.expect_value(t, len(store.deferred_appends), 15)
			primary := (^Retained_Dedup_Context)(store.deferred_appends[0].ctx)
			testing.expect_value(t, len(primary.duplicates), 1)
			duplicate := primary.duplicates[0]
			testing.expect(t, duplicate.dedup_cutoff_ns > duplicate.message.accepted_at_ns)
			tail_key := store.deferred_appends[14].dedup_key
			tail_ctx := store.deferred_appends[14].ctx
			for wave in 1 ..= 3 {
				_, ok := flush_pending_retained_message_writes(&td.message_stores)
				testing.expect(t, ok)
				testing.expect(t, store.write_in_flight)
				testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
				testing.expect_value(t, store.deferred_head, wave)
				testing.expect_value(t, len(store.deferred_appends), 15)
				testing.expect(t, raw_data(store.deferred_appends[14].dedup_key) == raw_data(tail_key))
				testing.expect(t, store.deferred_appends[14].ctx == tail_ctx)
				index, found := store.deferred_dedup[tail_key]
				testing.expect(t, found && index == 14)
			}
			// Reusing an expired ID is a new record, not the earlier follower's primary.
			req.client_message_id[0] = 2; req.correlation_id = 103
			process_send_message_v2(ctx.conns[4], req)
			// New retries must still find an untouched primary after partial drain.
			req.client_message_id[0] = 16; req.correlation_id = 101
			process_send_message_v2(ctx.conns[4], req)
			req.correlation_id = 102; req.content = transmute([]byte)string("conflict")
			process_send_message_v2(ctx.conns[4], req)
			testing.expect_value(t, ctx.conns[4].retained_io, 2)
			if outcome == 3 {
				retained_message_discard_speculative_process_state(&td.message_stores)
				testing.expect_value(t, store.deferred_head, 0)
				testing.expect_value(t, len(store.deferred_appends), 0)
				crash_message_store_for_test(store)
			} else if outcome == 1 {
				persistence.set_wal_short_write_for_test(1)
				previous_logger := context.logger
				context.logger = log.nil_logger()
				_, ok := flush_pending_retained_message_writes(&td.message_stores)
				testing.expect(t, ok && store.write_in_flight)
				testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
				ok = !store.poisoned
				context.logger = previous_logger
				testing.expect(t, persistence.wal_write_fault_triggered_for_test())
				persistence.clear_wal_write_fault_for_test()
				testing.expect(t, !ok && store.poisoned)
			} else if outcome == 2 {
				store.commit_started = {}
				testing.expect(t, schedule_retained_message_fsync(store))
				previous_logger := context.logger
				context.logger = log.nil_logger()
				completed := nrc_sim_run_next_fsync_completion(&ctx.sim, .EIO)
				_, ok := flush_pending_retained_message_writes(&td.message_stores)
				context.logger = previous_logger
				testing.expect(t, completed && !ok && store.poisoned)
			} else {
				generation := store.active_generation
				store.commit_started = {}
				testing.expect(t, schedule_retained_message_fsync(store))
				store.active_started_hour -= 1
				_, ok := flush_pending_retained_message_writes(&td.message_stores)
				for nrc_sim_run_next_file_write(&ctx.sim) {}
				testing.expect(t, ok && store.rotation_pending && store.deferred_head == 3)
				testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
				for round in 0 ..< 100 {
					if td.message_stores.pending_write_count > 0 {
						_, ok = flush_pending_retained_message_writes(&td.message_stores)
						testing.expect(t, ok)
					}
					for nrc_sim_run_next_file_write(&ctx.sim) {}
					for nrc_sim_run_next_file_read(&ctx.sim) {}
					for nrc_sim_run_next_fsync_completion(&ctx.sim) {}
					for item, index in store.deferred_appends[store.deferred_head:] {
						mapped, found := store.deferred_dedup[item.dedup_key]
						testing.expect(t, found && mapped == index + store.deferred_head)
					}
					if td.message_stores.pending_write_count == 0 && store.async_readers == 0 do break
				}
				testing.expect(t, store.active_generation > generation)
				testing.expect_value(t, store.high_water, u64(17))
				store.commit_started = {}
				if schedule_retained_message_fsync(store) {testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))}
			}
			testing.expect_value(t, store.deferred_head, 0)
			testing.expect_value(t, len(store.deferred_appends), 0)
			testing.expect_value(t, len(store.deferred_dedup), 0)
			// An fsync failure abandons the already-staged WAL suffix rather
			// than performing the normal, successful-store shutdown protocol.
			if outcome == 1 || outcome == 2 do crash_message_store_for_test(store)
			nrc_sim_run_all_send_completions(&ctx.sim)
			for client in 0 ..< 5 {
				conn := ctx.conns[client]
				testing.expect_value(t, conn.retained_io, 0)
				testing.expect_value(t, conn.pending_io, u32(0))
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), outcome == 0 ? (client == 4 ? 3 : 4) : 0)
				if outcome != 0 do continue
				for frame in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
					payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, frame))
					if !testing.expect(t, valid) do continue
					if pr.get_opcode(payload) != .S_AckSendMessage do continue
					ack, err := pr.parseAckSendMessageMessage(payload)
					testing.expect(t, err == nil)
					expected := ack.client_req_id == 100 ? 2 : (ack.client_req_id == 101 ? 16 : (ack.client_req_id == 103 ? 17 : int(ack.client_req_id)))
					testing.expect_value(t, u64(ack.assigned_seq), u64(expected))
				}
			}
		}
	}

	@(test)
	test_retained_send_group_commits_one_callback_wave :: proc(t: ^testing.T) {
		workspace := "retained-send-group-commit"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("retained-send-group-commit"); _ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "group-writer", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		testing.expect(t, init_message_store(&td.message_stores.stores[0], dir, shard, 24 * time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		// This tests callback-wave/byte-triggered commits, not wall-clock speed.
		// Slow host I/O must not expire the 1 ms timer between assertions.
		group_commit_test_now = time.Time {
			_nsec = i64(time.Hour),
		}
		store.wal.get_time = group_commit_test_clock

		for correlation_id in 1 ..= 4 {
			marker := correlation_id == 3 ? 2 : correlation_id
			client_message_id: [16]byte
			message_put_u64(client_message_id[:], u64(marker))
			content := correlation_id == 4 ? "conflict" : "same"
			if correlation_id == 4 do message_put_u64(client_message_id[:], 2)
			process_send_message_v2(
				conn,
				pr.SendMessageV2Request {
					conv_id = 42,
					client_message_id = client_message_id,
					content_type = .PlainText,
					content = transmute([]byte)content,
					correlation_id = u32(correlation_id),
				},
			)
		}
		nrc_sim_run_all_send_completions(&ctx.sim)

		direct := test_retained_message(workspace, 42, 50, nrc_time_unix_nanos())
		direct_result, _ := append_or_deduplicate_message(store, &direct)
		testing.expect_value(t, direct_result, Message_Store_Result.Poisoned)
		testing.expect(t, !rotate_message_store(store, nrc_time_unix_nanos()))
		testing.expect_value(t, store.wal.write_count, u64(0))
		testing.expect_value(t, store.wal.record_count, u64(0))
		testing.expect_value(t, store.high_water, u64(0))
		testing.expect_value(t, len(store.pending_appends), 3)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_ErrorResponse), 0)

		did_write, write_ok := flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect_value(t, store.wal.write_count, u64(1))
		testing.expect_value(t, store.wal.record_count, u64(2))
		testing.expect_value(t, store.high_water, u64(2))
		testing.expect_value(t, len(store.pending_appends), 0)
		testing.expect_value(t, conn.retained_io, 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		store.commit_started = {}
		testing.expect(t, schedule_retained_message_fsync(store))
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 3)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_ErrorResponse), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		committed_duplicate_id: [16]byte
		message_put_u64(committed_duplicate_id[:], 1)
		process_send_message_v2(
			conn,
			pr.SendMessageV2Request {
				conv_id = 42,
				client_message_id = committed_duplicate_id,
				content_type = .PlainText,
				content = transmute([]byte)string("same"),
				correlation_id = 8,
			},
		)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect_value(t, store.wal.write_count, u64(1))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		store.wal.pending_bytes = persistence.FSYNC_BYTE_THRESHOLD
		testing.expect(t, schedule_retained_message_fsync(store))
		testing.expect(t, store.fsync_in_flight)
		testing.expect_value(t, store.fsync_snapshot.record_count, u64(2))
		td.message_stores.write_batch_records = 2
		for correlation_id in 20 ..= 23 {
			client_message_id: [16]byte
			message_put_u64(client_message_id[:], u64(correlation_id))
			process_send_message_v2(
				conn,
				pr.SendMessageV2Request {
					conv_id = 42,
					client_message_id = client_message_id,
					content_type = .PlainText,
					content = transmute([]byte)string("capped"),
					correlation_id = u32(correlation_id),
				},
			)
		}
		testing.expect_value(t, len(store.pending_appends), 2)
		testing.expect_value(t, len(store.deferred_appends), 2)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect_value(t, store.wal.write_count, u64(2))
		testing.expect_value(t, store.high_water, u64(4))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		testing.expect_value(t, len(store.pending_appends), 2)
		testing.expect_value(t, len(store.deferred_appends), 0)
		testing.expect_value(t, td.message_stores.pending_write_count, 1)
		testing.expect(t, store.fsync_in_flight)
		testing.expect_value(t, store.wal.durable_record_count, u64(2))
		testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		testing.expect(t, !store.fsync_in_flight)
		testing.expect_value(t, store.wal.record_count, u64(4))
		testing.expect_value(t, store.wal.durable_record_count, u64(2))
		testing.expect(t, store.wal.pending_bytes > 0)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect_value(t, store.wal.write_count, u64(3))
		testing.expect_value(t, store.high_water, u64(6))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		testing.expect_value(t, len(store.pending_appends), 0)
		testing.expect_value(t, len(store.deferred_appends), 0)
		testing.expect_value(t, td.message_stores.pending_write_count, 0)
		testing.expect_value(t, conn.retained_io, 0)
		td.message_stores.write_batch_records = 0
		if !store.fsync_in_flight {
			store.wal.pending_bytes = persistence.FSYNC_BYTE_THRESHOLD
			maintenance_work, maintenance_ok := maintain_message_store_registry(&td.message_stores)
			testing.expect(t, maintenance_work && maintenance_ok)
		}
		testing.expect(t, store.fsync_in_flight)
		testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		testing.expect(t, !store.fsync_in_flight)
		testing.expect_value(t, store.wal.durable_record_count, u64(6))
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 4)

		nrc_sim_clear_inboxes(&ctx.sim)
		generation_before_rotation := store.active_generation
		store.active_started_hour -= 1
		store.wal.pending_bytes = persistence.FSYNC_BYTE_THRESHOLD
		testing.expect(t, schedule_retained_message_fsync(store))
		rotation_id: [16]byte
		message_put_u64(rotation_id[:], 9)
		process_send_message_v2(
			conn,
			pr.SendMessageV2Request {
				conv_id = 42,
				client_message_id = rotation_id,
				content_type = .PlainText,
				content = transmute([]byte)string("after rotation"),
				correlation_id = 9,
			},
		)
		testing.expect(t, store.rotation_pending)
		testing.expect_value(t, store.active_generation, generation_before_rotation)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		store.async_readers += 1
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect(t, store.rotation_pending && !store.poisoned)
		testing.expect_value(t, store.active_generation, generation_before_rotation)
		testing.expect_value(t, td.message_stores.pending_write_count, 0)
		retained_message_release_store_reader(store)
		testing.expect_value(t, td.message_stores.pending_write_count, 1)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect(t, store.rotation_pending && store.fsync_in_flight)
		testing.expect_value(t, store.active_generation, generation_before_rotation)
		testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 1)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		testing.expect(t, !store.fsync_in_flight)
		testing.expect_value(t, td.message_stores.pending_write_count, 1)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect_value(t, store.active_generation, generation_before_rotation + 2)
		testing.expect_value(t, store.wal.write_count, u64(0))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, did_write && write_ok)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		testing.expect_value(t, store.wal.write_count, u64(1))
		testing.expect_value(t, store.high_water, u64(7))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		store.commit_started = {}
		testing.expect(t, schedule_retained_message_fsync(store))
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)

		nrc_sim_clear_inboxes(&ctx.sim)
		large_content := make([]byte, pr.MAX_ALLOWED_CONTENT_LENGTH)
		defer delete(large_content)
		for correlation_id in 10 ..= 12 {
			client_message_id: [16]byte
			message_put_u64(client_message_id[:], u64(correlation_id))
			process_send_message_v2(
				conn,
				pr.SendMessageV2Request {
					conv_id = 42,
					client_message_id = client_message_id,
					content_type = .PlainText,
					content = large_content,
					correlation_id = u32(correlation_id),
				},
			)
		}
		testing.expect_value(t, len(store.pending_appends), 2)
		testing.expect_value(t, len(store.deferred_appends), 1)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect_value(t, store.wal.write_count, u64(2))
		testing.expect_value(t, store.high_water, u64(9))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		testing.expect_value(t, len(store.pending_appends), 1)
		testing.expect_value(t, len(store.deferred_appends), 0)
		testing.expect_value(t, td.message_stores.pending_write_count, 1)
		did_write, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, did_write && write_ok)
		testing.expect_value(t, store.wal.write_count, u64(3))
		testing.expect_value(t, store.high_water, u64(10))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		for nrc_sim_run_next_fsync_completion(&ctx.sim) {}
		store.commit_started = {}
		if schedule_retained_message_fsync(store) {
			testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 3)
		testing.expect_value(t, conn.retained_io, 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		failed_id: [16]byte
		message_put_u64(failed_id[:], 99)
		process_send_message_v2(
			conn,
			pr.SendMessageV2Request {
				conv_id = 42,
				client_message_id = failed_id,
				content_type = .PlainText,
				content = transmute([]byte)string("must-not-ack"),
				correlation_id = 99,
			},
		)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		persistence.set_wal_short_write_for_test(1)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		_, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, write_ok && store.write_in_flight)
		testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
		write_ok = !store.poisoned
		context.logger = previous_logger
		testing.expect(t, persistence.wal_write_fault_triggered_for_test())
		persistence.clear_wal_write_fault_for_test()
		testing.expect(t, !write_ok)
		testing.expect(t, store.poisoned && !store.wal.enabled)
		testing.expect_value(t, store.high_water, u64(10))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_ErrorResponse), 0)
	}

	retained_history_simulation_page :: proc(
		conn: ^NRC_Connection,
		request: pr.MessageRangeRequest,
		ascending: bool,
		file_read_count: ^int = nil,
	) -> (
		pr.MessagePage,
		bool,
	) {
		if !simulation_test_commit_messages(nrc_sim_runtime) do return {}, false
		nrc_sim_clear_inboxes(nrc_sim_runtime)
		started := time.now()
		process_message_history(conn, request, ascending)
		for conn.retained_io > 0 && time.since(started) < 10 * time.Second {
			if nrc_sim_run_next_file_read(nrc_sim_runtime) {
				if file_read_count != nil do file_read_count^ += 1
				continue
			}
			if nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true) != linux.Errno.NONE do return {}, false
		}
		if conn.retained_io != 0 || nrc_sim_client_frame_count(nrc_sim_runtime, conn.sock) != 1 do return {}, false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(nrc_sim_runtime, conn.sock, 0))
		if !payload_ok || pr.get_opcode(payload) != .S_MessagePage do return {}, false
		page, parse_err := pr.parseMessagePage(payload[2:])
		return page, parse_err == nil
	}

	retained_history_page_matches_model :: proc(
		page: pr.MessagePage,
		conversation_id: pr.ConversationID,
		sequences: []u64,
		live: []bool,
		cursor: u64,
		limit: int,
		ascending: bool,
	) -> bool {
		expected: [220]u64
		expected_count := 0
		if ascending {
			for sequence, i in sequences {
				if live[i] && sequence > cursor {
					expected[expected_count] = sequence
					expected_count += 1
				}
			}
		} else {
			for i := len(sequences) - 1; i >= 0; i -= 1 {
				if live[i] && (cursor == 0 || sequences[i] < cursor) {
					expected[expected_count] = sequences[i]
					expected_count += 1
				}
			}
		}
		page_count := min(expected_count, limit)
		if page.conv_id != conversation_id || page.ascending != ascending || len(page.messages) != page_count || page.has_more != (expected_count > limit) do return false
		for message, i in page.messages {
			if message.conv_id != conversation_id || u64(message.seq) != expected[i] do return false
		}
		expected_cursor := u64(0)
		if page_count > 0 do expected_cursor = expected[page_count - 1]
		return u64(page.continuation_cursor) == expected_cursor
	}

	@(test)
	test_retained_history_cursor_u64_boundary :: proc(t: ^testing.T) {
		for cached in ([2]bool{false, true}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
			defer nbio.destroy(&td.io)
			workspace := "history-cursor-boundary"
			conn := simulation_test_install_client(&ctx.sim, 1, workspace, "reader", init_send_queue = true)
			ctx.conns[1] = conn
			if !testing.expect(t, conn != nil) do return
			subscribe_to_conversation(conn, 42)
			storage := sim_world_storage_context(&ctx.sim.world)
			shard_dir := "/history-cursor-boundary"
			testing.expect(t, storage_io.make_directory(storage, shard_dir) == nil)
			shard := int(shard_for_workspace(transmute([]byte)workspace))
			for &index in td.message_stores.store_index do index = -1
			append(&td.message_stores.stores, Message_Store{})
			td.message_stores.sealed_index_cache.limit_bytes = cached ? 100 * MESSAGE_INDEX_ENTRY_SIZE : 0
			store := &td.message_stores.stores[0]
			if !testing.expect(t, init_message_store_with_storage(store, storage, shard_dir, shard, 48 * time.Hour, 0, sealed_index_cache = &td.message_stores.sealed_index_cache)) do return
			td.message_stores.enabled = true
			td.message_stores.store_index[shard] = 0
			defer shutdown_message_store_registry(&td.message_stores)
			// Seed near the boundary without generating billions of records.
			store.high_water = max(u64) - 2
			now := nrc_time_unix_nanos()
			for marker in u64(1) ..= 2 {
				message := test_retained_message(workspace, 42, marker, now)
				result, sequence := append_or_deduplicate_message(store, &message)
				testing.expect_value(t, result, Message_Store_Result.Appended)
				testing.expect_value(t, sequence, max(u64) - 2 + marker)
			}
			for sealed in ([2]bool{false, true}) {
				if sealed {
					if !testing.expect(t, rotate_message_store(store, now + 1)) do return
					testing.expect_value(t, len(store.segments[0].cached_message_index) > 0, cached)
				}
				for ascending in ([2]bool{false, true}) {
					for cursor in ([3]u64{0, max(u64) - 1, max(u64)}) {
						page, ok := retained_history_simulation_page(
							conn,
							pr.MessageRangeRequest{conv_id = 42, cursor = pr.MessageSeq(cursor), limit = 10, correlation_id = 77},
							ascending,
						)
						if !testing.expect(t, ok) do return
						expected: [2]u64
						count := 0
						if cursor == 0 {
							expected = ascending ? [2]u64{max(u64) - 1, max(u64)} : [2]u64{max(u64), max(u64) - 1}
							count = 2
						} else if ascending && cursor == max(u64) - 1 {
							expected[0] = max(u64)
							count = 1
						} else if !ascending && cursor == max(u64) {
							expected[0] = max(u64) - 1
							count = 1
						}
						testing.expect_value(t, len(page.messages), count)
						for message, i in page.messages {
							if i < count do testing.expect_value(t, u64(message.seq), expected[i])
						}
						testing.expect_value(t, u64(page.high_water_seq), max(u64))
						testing.expect_value(t, u64(page.continuation_cursor), count > 0 ? expected[max(0, count - 1)] : 0)
						testing.expect(t, !page.has_more && !page.truncated)
						testing.expect_value(t, conn.retained_io, 0)
						testing.expect_value(t, store.async_readers, u32(0))
						testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 0)
						if sealed do testing.expect_value(t, store.segments[0].readers, 0)
					}
				}
			}
		}
	}

	@(test)
	test_sealed_history_borrowed_records_survive_multiple_arena_slabs :: proc(t: ^testing.T) {
		workspace := "retained-history-borrowed-multi-slab"
		conversation_id := pr.ConversationID(42)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("retained-history-borrowed-multi-slab"); _ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "history-reader", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return
		subscribe_to_conversation(conn, conversation_id)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		td.message_stores.sealed_index_cache.limit_bytes = 100 * MESSAGE_INDEX_ENTRY_SIZE
		testing.expect(
			t,
			init_message_store(&td.message_stores.stores[0], dir, shard, 24 * time.Hour, 0, sealed_index_cache = &td.message_stores.sealed_index_cache),
		)
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		now := nrc_time_unix_nanos()
		principal_storage: [1024]byte
		for &value in principal_storage do value = 'p'
		for segment_index in 0 ..< 2 {
			for record_index in 0 ..< 50 {
				sequence := segment_index * 50 + record_index + 1
				content_storage: [512]byte
				marker := fmt.aprintf("message-%03d", sequence)
				copy(content_storage[:], marker); delete(marker)
				for i in 11 ..< len(content_storage) do content_storage[i] = byte('a' + sequence % 26)
				message := test_retained_message(workspace, u64(conversation_id), u64(sequence), now + i64(sequence))
				message.sender_principal = transmute(string)principal_storage[:]
				message.content = content_storage[:]
				result, _ := append_or_deduplicate_message(store, &message)
				if result == .Lookup_Required do result, _ = append_message_after_sealed_lookup(store, &message)
				testing.expect_value(t, result, Message_Store_Result.Appended)
			}
			testing.expect(t, rotate_message_store(store, now + i64(segment_index + 1)))
		}
		testing.expect_value(t, len(store.segments), 2)
		testing.expect(t, store.segments[0].bytes + store.segments[1].bytes > RETAINED_PAGE_ARENA_BLOCK_BYTES)

		page, ok := retained_history_simulation_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = 0, limit = 100, correlation_id = 1},
			false,
		)
		testing.expect(t, ok)
		testing.expect_value(t, len(page.messages), 100)
		for message, i in page.messages {
			expected_sequence := 100 - i
			testing.expect_value(t, u64(message.seq), u64(expected_sequence))
			expected_marker := fmt.aprintf("message-%03d", expected_sequence)
			testing.expect_value(t, string(message.content[:len(expected_marker)]), expected_marker)
			delete(expected_marker)
		}
	}

	@(test)
	test_sealed_history_scans_past_expired_index_chunks :: proc(t: ^testing.T) {
		workspace := "retained-history-expired-chunks-workspace"
		expired_count :: 10_101
		total_count :: expired_count + 5
		ascending_conversation_id := pr.ConversationID(42)
		descending_conversation_id := pr.ConversationID(43)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("retained-history-expired-chunks"); _ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "history-reader", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return
		subscribe_to_conversation(conn, ascending_conversation_id)
		subscribe_to_conversation(conn, descending_conversation_id)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		td.message_stores.sealed_index_cache.limit_bytes = u64(total_count * 2 * MESSAGE_INDEX_ENTRY_SIZE)
		testing.expect(
			t,
			init_message_store(&td.message_stores.stores[0], dir, shard, 24 * time.Hour, 0, sealed_index_cache = &td.message_stores.sealed_index_cache),
		)
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		now := nrc_time_unix_nanos()
		cutoff := now / i64(time.Hour) * i64(time.Hour) + i64(time.Hour / 2)
		store.purge_floor_ns = cutoff
		for i in 0 ..< total_count {
			accepted_at := i < expired_count ? cutoff - i64(time.Second) : cutoff + i64(time.Second)
			message := test_retained_message(workspace, u64(ascending_conversation_id), u64(i + 1), accepted_at)
			result, _ := append_or_deduplicate_message(store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
		}
		for i in 0 ..< total_count {
			accepted_at := i < 5 ? cutoff + i64(time.Second) : cutoff - i64(time.Second)
			message := test_retained_message(workspace, u64(descending_conversation_id), u64(total_count + i + 1), accepted_at)
			result, _ := append_or_deduplicate_message(store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
		}
		testing.expect(t, rotate_message_store(store, cutoff + i64(2 * time.Second)))
		testing.expect_value(t, len(store.segments), 1)
		testing.expect_value(t, len(store.segments[0].conversation_ranges), 2)
		testing.expect_value(t, store.segments[0].conversation_ranges[0].end - store.segments[0].conversation_ranges[0].start, u64(total_count))
		testing.expect_value(t, store.segments[0].conversation_ranges[1].end - store.segments[0].conversation_ranges[1].start, u64(total_count))

		_, count, page_ok := message_history_benchmark_page(
			conn,
			pr.MessageRangeRequest{conv_id = ascending_conversation_id, cursor = 0, limit = 5, correlation_id = 1},
			true,
		)
		testing.expect(t, page_ok)
		testing.expect_value(t, count, 5)

		_, count, page_ok = message_history_benchmark_page(
			conn,
			pr.MessageRangeRequest{conv_id = descending_conversation_id, cursor = 0, limit = 5, correlation_id = 2},
			false,
		)
		testing.expect(t, page_ok)
		testing.expect_value(t, count, 5)
	}

	@(test)
	test_active_history_reads_sparse_records_in_parallel :: proc(t: ^testing.T) {
		workspace := "retained-history-active-parallel-workspace"
		conversation_id := pr.ConversationID(42)
		distractor_conversation_id := pr.ConversationID(43)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("retained-history-active-parallel"); _ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "history-reader", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return
		subscribe_to_conversation(conn, conversation_id)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		testing.expect(t, init_message_store(&td.message_stores.stores[0], dir, shard, 24 * time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		now := nrc_time_unix_nanos()
		marker: u64 = 1
		for _ in 0 ..< 101 {
			message := test_retained_message(workspace, u64(conversation_id), marker, now)
			marker += 1
			result, _ := append_or_deduplicate_message(store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			for _ in 0 ..< 5 {
				distractor := test_retained_message(workspace, u64(distractor_conversation_id), marker, now)
				marker += 1
				result, _ = append_or_deduplicate_message(store, &distractor)
				testing.expect_value(t, result, Message_Store_Result.Appended)
			}
		}
		testing.expect_value(t, len(store.segments), 0)
		testing.expect(t, store.active_read_file == nil)

		_, count, page_ok := message_history_benchmark_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = 0, limit = 100, correlation_id = 1},
			false,
		)
		testing.expect(t, page_ok)
		testing.expect_value(t, count, 100)
		testing.expect(t, store.active_read_file != nil)
		active_read_file := store.active_read_file

		_, count, page_ok = message_history_benchmark_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = 0, limit = 100, correlation_id = 2},
			true,
		)
		testing.expect(t, page_ok)
		testing.expect_value(t, count, 100)
		testing.expect_value(t, store.active_read_file, active_read_file)

		previous_high_water := store.high_water
		testing.expect(t, rotate_message_store(store, now + i64(time.Hour)))
		testing.expect(t, store.active_read_file == nil)
		td.message_stores.active_cache.limit_bytes = 1024 * 1024
		store.active_cache_budget = &td.message_stores.active_cache
		message := test_retained_message(workspace, u64(conversation_id), marker, now + i64(time.Hour))
		result, sequence := append_or_deduplicate_message(store, &message)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect_value(t, sequence, previous_high_water + 1)
		new_sequences: [3]u64
		new_sequences[0] = sequence
		_, count, page_ok = message_history_benchmark_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = pr.MessageSeq(previous_high_water), limit = 100, correlation_id = 3},
			true,
		)
		testing.expect(t, page_ok)
		testing.expect_value(t, count, 1)
		testing.expect(t, store.active_read_file == nil)

		// Exhaust the budget after one cached record. A page spanning cached and
		// uncached active records must preserve cursor order through the WAL fallback.
		td.message_stores.active_cache.limit_bytes = td.message_stores.active_cache.used_bytes
		for extra in 1 ..= 2 {
			message = test_retained_message(workspace, u64(conversation_id), marker + u64(extra), now + i64(time.Hour + time.Duration(extra)))
			result, sequence = append_or_deduplicate_message(store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			new_sequences[extra] = sequence
		}
		mixed_entries := store.active_offsets[Message_Conversation_Key{workspace, u64(conversation_id)}]
		testing.expect_value(t, len(mixed_entries), 3)
		testing.expect(t, len(mixed_entries[0].cached_payload) > 0)
		testing.expect_value(t, len(mixed_entries[1].cached_payload), 0)
		testing.expect_value(t, len(mixed_entries[2].cached_payload), 0)
		page, mixed_page_ok := retained_history_simulation_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = pr.MessageSeq(previous_high_water), limit = 2, correlation_id = 4},
			true,
		)
		testing.expect(t, mixed_page_ok)
		testing.expect_value(t, len(page.messages), 2)
		testing.expect(t, page.ascending && page.has_more)
		testing.expect_value(t, u64(page.messages[0].seq), new_sequences[0])
		testing.expect_value(t, u64(page.messages[1].seq), new_sequences[1])
		testing.expect_value(t, u64(page.continuation_cursor), new_sequences[1])
		testing.expect(t, store.active_read_file != nil)

		page, mixed_page_ok = retained_history_simulation_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = pr.MessageSeq(new_sequences[2]), limit = 2, correlation_id = 5},
			false,
		)
		testing.expect(t, mixed_page_ok)
		testing.expect_value(t, len(page.messages), 2)
		testing.expect(t, !page.ascending && page.has_more)
		testing.expect_value(t, u64(page.messages[0].seq), new_sequences[1])
		testing.expect_value(t, u64(page.messages[1].seq), new_sequences[0])
		testing.expect_value(t, u64(page.continuation_cursor), new_sequences[0])
	}

	mixed_cached_reader_rollover_case :: proc(t: ^testing.T, fail_old_reader: bool, cancel_old_reader: bool = false) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, fail_old_reader ? 246 : 245)
		defer simulation_test_end(&ctx)
		ctx.sim.compaction_job_event_submission = true
		server: NRC_Server
		td.server = &server
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)

		workspace := fail_old_reader ? "mixed-cache-rollover-error" : "mixed-cache-rollover-success"
		old_conn := simulation_test_install_client(&ctx.sim, 1, workspace, "old-reader", init_send_queue = true)
		new_conn := simulation_test_install_client(&ctx.sim, 2, workspace, "new-reader", init_send_queue = true)
		ctx.conns[1], ctx.conns[2] = old_conn, new_conn
		if !testing.expect(t, old_conn != nil && new_conn != nil) do return
		subscribe_to_conversation(old_conn, 42)
		subscribe_to_conversation(new_conn, 42)

		storage := sim_world_storage_context(&ctx.sim.world)
		dir := fail_old_reader ? "/mixed-cache-rollover-error" : "/mixed-cache-rollover-success"
		testing.expect(t, storage_io.make_directory(storage, dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		if !testing.expect(t, append_err == nil) do return
		store := &td.message_stores.stores[0]
		budget := &td.message_stores.active_cache
		budget.limit_bytes = 1
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, 24 * time.Hour, 0, active_cache_budget = budget))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)

		now := nrc_time_unix_nanos()
		messages: [4]Retained_Message
		contents := [?]string{"A cached", "A uncached", "B cached", "B uncached"}
		for &message, i in messages {
			message = test_retained_message(workspace, 42, u64(i + 1), now + i64(i))
			message.content = transmute([]byte)contents[i]
		}
		a_cached_bytes, valid := message_record_size(&messages[0])
		if !testing.expect(t, valid) do return
		budget.limit_bytes = u64(a_cached_bytes)
		result, sequence := append_or_deduplicate_message(store, &messages[0])
		testing.expect(t, result == .Appended && sequence == 1)
		budget.limit_bytes = budget.used_bytes
		result, sequence = append_or_deduplicate_message(store, &messages[1])
		testing.expect(t, result == .Appended && sequence == 2)
		a_entries := store.active_offsets[Message_Conversation_Key{workspace, 42}]
		testing.expect(t, len(a_entries) == 2 && len(a_entries[0].cached_payload) == a_cached_bytes && len(a_entries[1].cached_payload) == 0)
		testing.expect_value(t, budget.used_bytes, u64(a_cached_bytes))

		store.rotation_pending = true
		testing.expect(t, retained_message_flush_store(store))
		testing.expect(t, store.frozen != nil && store.seal_in_flight)
		b_cached_bytes, b_valid := message_record_size(&messages[2])
		if !testing.expect(t, b_valid) do return
		budget.limit_bytes = budget.used_bytes + u64(b_cached_bytes)
		result, sequence = append_or_deduplicate_message(store, &messages[2])
		testing.expect(t, result == .Appended && sequence == 3)
		budget.limit_bytes = budget.used_bytes
		result, sequence = append_or_deduplicate_message(store, &messages[3])
		testing.expect(t, result == .Appended && sequence == 4)
		b_entries := store.active_offsets[Message_Conversation_Key{workspace, 42}]
		a_entries = store.frozen.active_offsets[Message_Conversation_Key{workspace, 42}]
		testing.expect(t, len(a_entries) == 2 && len(a_entries[0].cached_payload) > 0 && len(a_entries[1].cached_payload) == 0)
		testing.expect(t, len(b_entries) == 2 && len(b_entries[0].cached_payload) > 0 && len(b_entries[1].cached_payload) == 0)
		expected_total := u64(a_cached_bytes + b_cached_bytes)
		testing.expect_value(t, budget.used_bytes, expected_total)
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
		nrc_sim_clear_inboxes(&ctx.sim)

		// This snapshot borrows both A and B, and stalls on A's uncached record.
		process_message_history(old_conn, {conv_id = 42, limit = 10, correlation_id = 71}, true)
		testing.expect(t, store.async_readers == 1 && store.frozen.async_readers == 1)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result))
		_, ok := flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok && store.frozen_published)

		// A reader created after publication sees only the published segment plus
		// B. Cursor 2 proves that it does not pin or borrow frozen A itself.
		process_message_history(new_conn, {conv_id = 42, cursor = 2, limit = 10, correlation_id = 72}, true)
		testing.expect(t, store.async_readers == 2 && store.frozen.async_readers == 1)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 2)

		if cancel_old_reader {
			index := sim_world_domain_event_index(&ctx.sim.world, .File_Read, 0)
			if !testing.expect(t, index >= 0) do return
			testing.expect(t, sim_world_cancel_event(&ctx.sim.world, ctx.sim.world.events[index].id))
			testing.expect(t, !store.poisoned && old_conn.retained_io == 0 && old_conn.pending_io == 0)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, old_conn.sock), 0)
		} else if fail_old_reader {
			// The first queued read belongs to old_conn. EIO must release both its
			// A borrow and root pin without consuming new_conn's independent read.
			testing.expect(t, nrc_sim_run_file_read_at(&ctx.sim, 0, .EIO))
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, old_conn.sock, .S_MessagePage), 0)
		} else {
			testing.expect(t, nrc_sim_run_file_read_at(&ctx.sim, 0))
			// old_conn's B fallback was appended after new_conn's read event.
			for old_conn.retained_io > 0 {
				if !testing.expect(t, nrc_sim_run_file_read_at(&ctx.sim, 1)) do break
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, old_conn.sock, .S_MessagePage), 1)
			payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, old_conn.sock, 0))
			if testing.expect(t, payload_ok) {
				page, parse_err := pr.parseMessagePage(payload[2:])
				testing.expect(t, parse_err == nil && page.correlation_id == 71 && len(page.messages) == 4)
				if parse_err == nil && len(page.messages) == 4 {
					for message, i in page.messages {
						testing.expect_value(t, u64(message.seq), u64(i + 1))
						testing.expect_value(t, string(message.content), contents[i])
					}
				}
			}
		}
		testing.expect(t, store.async_readers == 1 && store.frozen.async_readers == 0)
		_, ok = maintain_message_store_registry(&td.message_stores)
		if fail_old_reader {
			testing.expect(t, !ok && store.poisoned && store.frozen != nil)
			testing.expect_value(t, budget.used_bytes, expected_total)
		} else {
			testing.expect(t, ok && store.frozen == nil)
			testing.expect_value(t, budget.used_bytes, u64(b_cached_bytes))
		}
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)

		for nrc_sim_run_next_file_read(&ctx.sim) {}
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, store.async_readers, u32(0))
		testing.expect(t, old_conn.retained_io == 0 && new_conn.retained_io == 0)
		if fail_old_reader {
			// Poisoning gates the outbox, including the independent reader's page.
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, new_conn.sock, .S_MessagePage), 0)
			testing.expect(t, shutdown_message_store_registry(&td.message_stores))
			testing.expect_value(t, budget.used_bytes, u64(0))
			return
		}
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, new_conn.sock, .S_MessagePage), 1)
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, new_conn.sock, 0))
		if testing.expect(t, payload_ok) {
			page, parse_err := pr.parseMessagePage(payload[2:])
			testing.expect(t, parse_err == nil && page.correlation_id == 72 && len(page.messages) == 2)
			if parse_err == nil && len(page.messages) == 2 {
				for message, i in page.messages {
					testing.expect_value(t, u64(message.seq), u64(i + 3))
					testing.expect_value(t, string(message.content), contents[i + 2])
				}
			}
		}
		shutdown_ok := shutdown_message_store_registry(&td.message_stores)
		testing.expect(t, shutdown_ok)
		testing.expect_value(t, budget.used_bytes, u64(0))
	}

	@(test)
	test_simulation_mixed_cached_readers_survive_rollover_retirement :: proc(t: ^testing.T) {
		mixed_cached_reader_rollover_case(t, false)
	}

	@(test)
	test_simulation_mixed_cached_old_reader_error_releases_rollover :: proc(t: ^testing.T) {
		mixed_cached_reader_rollover_case(t, true)
	}

	@(test)
	test_simulation_mixed_cached_old_reader_cancel_releases_rollover :: proc(t: ^testing.T) {
		mixed_cached_reader_rollover_case(t, false, cancel_old_reader = true)
	}
}

@(test)
test_hegel_active_retained_history_matches_sequence_model :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_active_retained_history_matches_sequence_model, nil, {test_cases = 30})
		testing.expectf(t, err == nil, "hegel active retained-history model property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

when NRC_SIMULATION {
	prop_active_retained_history_matches_sequence_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		target_count_raw, draw_err := hgl.draw_i64(tc, 102, 180)
		if draw_err == .Stop_Test do return hgl.abort()
		if draw_err != nil do return hgl.interesting("draw active target record count")
		distractors_raw, distractor_draw_err := hgl.draw_i64(tc, 1, 8)
		if distractor_draw_err == .Stop_Test do return hgl.abort()
		if distractor_draw_err != nil do return hgl.interesting("draw active distractor count")
		limit_raw, limit_draw_err := hgl.draw_i64(tc, 1, 100)
		if limit_draw_err == .Stop_Test do return hgl.abort()
		if limit_draw_err != nil do return hgl.interesting("draw active page limit")
		target_count := int(target_count_raw)
		distractors := int(distractors_raw)
		stride := u64(distractors + 1)
		cursor_raw, cursor_draw_err := hgl.draw_i64(tc, 0, target_count_raw * i64(stride))
		if cursor_draw_err == .Stop_Test do return hgl.abort()
		if cursor_draw_err != nil do return hgl.interesting("draw active cursor")

		workspace := "hegel-active-retained-history-workspace"
		conversation_id := pr.ConversationID(42)
		distractor_conversation_id := pr.ConversationID(43)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("hegel-active-retained-history"); _ = os.remove_all(dir)
		if os.make_directory(dir) != nil do return hgl.interesting("create active message store directory")
		defer os.remove_all(dir)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 97)
		defer simulation_test_end(&ctx)
		if nbio.init(&td.io) != linux.Errno.NONE do return hgl.interesting("initialize active simulated io")
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "active-history-reader", init_send_queue = true)
		ctx.conns[1] = conn
		if conn == nil do return hgl.interesting("install active simulated history client")
		subscribe_to_conversation(conn, conversation_id)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		if append_err != nil do return hgl.interesting("allocate active message store")
		// A deliberately small budget makes generated pages cross cached and WAL-backed records.
		td.message_stores.active_cache.limit_bytes = 16 * 1024
		if !init_message_store(&td.message_stores.stores[0], dir, shard, 24 * time.Hour, 0, active_cache_budget = &td.message_stores.active_cache) do return hgl.interesting("initialize active message store")
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		now := nrc_time_unix_nanos()
		sequences: [180]u64
		live: [180]bool
		marker: u64 = 1
		for i in 0 ..< target_count {
			message := test_retained_message(workspace, u64(conversation_id), marker, now + i64(marker))
			marker += 1
			result, sequence := append_or_deduplicate_message(store, &message)
			if result != .Appended do return hgl.interesting("append active target message")
			sequences[i] = sequence
			live[i] = true
			for _ in 0 ..< distractors {
				distractor := test_retained_message(workspace, u64(distractor_conversation_id), marker, now + i64(marker))
				marker += 1
				result, _ = append_or_deduplicate_message(store, &distractor)
				if result != .Appended do return hgl.interesting("append active distractor message")
			}
		}
		if len(store.segments) != 0 do return hgl.interesting("active fixture unexpectedly sealed")

		queries := [4]struct {
			ascending: bool,
			cursor:    u64,
		}{{true, 0}, {false, 0}, {true, u64(cursor_raw)}, {false, u64(cursor_raw)}}
		for query, query_index in queries {
			page, ok := retained_history_simulation_page(
				conn,
				pr.MessageRangeRequest {
					conv_id = conversation_id,
					cursor = pr.MessageSeq(query.cursor),
					limit = u16(limit_raw),
					correlation_id = u32(query_index + 1),
				},
				query.ascending,
			)
			if !ok do return hgl.interesting("execute active retained history page")
			if !retained_history_page_matches_model(
				page,
				conversation_id,
				sequences[:target_count],
				live[:target_count],
				u64(query.cursor),
				int(limit_raw),
				query.ascending,
			) {
				return hgl.interesting(query.ascending ? "ascending active history differs from model" : "descending active history differs from model")
			}
		}
		return hgl.valid()
	}
}

@(test)
test_hegel_sealed_retained_history_matches_sequence_model :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_sealed_retained_history_matches_sequence_model, nil, {test_cases = 50})
		testing.expectf(t, err == nil, "hegel sealed retained-history model property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

when NRC_SIMULATION {
	prop_sealed_retained_history_matches_sequence_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		target_count_raw, draw_err := hgl.draw_i64(tc, 102, 220)
		if draw_err == .Stop_Test do return hgl.abort()
		if draw_err != nil do return hgl.interesting("draw target record count")
		target_count := int(target_count_raw)

		expired_prefix_raw, prefix_draw_err := hgl.draw_i64(tc, 0, target_count_raw - 1)
		if prefix_draw_err == .Stop_Test do return hgl.abort()
		if prefix_draw_err != nil do return hgl.interesting("draw expired prefix")
		expired_suffix_raw, suffix_draw_err := hgl.draw_i64(tc, 0, target_count_raw - expired_prefix_raw - 1)
		if suffix_draw_err == .Stop_Test do return hgl.abort()
		if suffix_draw_err != nil do return hgl.interesting("draw expired suffix")
		limit_raw, limit_draw_err := hgl.draw_i64(tc, 1, 100)
		if limit_draw_err == .Stop_Test do return hgl.abort()
		if limit_draw_err != nil do return hgl.interesting("draw page limit")
		cursor_raw, cursor_draw_err := hgl.draw_i64(tc, 0, target_count_raw * 2)
		if cursor_draw_err == .Stop_Test do return hgl.abort()
		if cursor_draw_err != nil do return hgl.interesting("draw cursor")

		workspace := "hegel-retained-history-workspace"
		conversation_id := pr.ConversationID(42)
		distractor_conversation_id := pr.ConversationID(43)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("hegel-retained-history"); _ = os.remove_all(dir)
		if os.make_directory(dir) != nil do return hgl.interesting("create message store directory")
		defer os.remove_all(dir)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 98)
		defer simulation_test_end(&ctx)
		if nbio.init(&td.io) != linux.Errno.NONE do return hgl.interesting("initialize simulated io")
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "history-reader", init_send_queue = true)
		ctx.conns[1] = conn
		if conn == nil do return hgl.interesting("install simulated history client")
		subscribe_to_conversation(conn, conversation_id)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		if append_err != nil do return hgl.interesting("allocate message store")
		td.message_stores.sealed_index_cache.limit_bytes = u64(target_count * 2 * MESSAGE_INDEX_ENTRY_SIZE)
		initialized := init_message_store(
			&td.message_stores.stores[0],
			dir,
			shard,
			24 * time.Hour,
			0,
			sealed_index_cache = &td.message_stores.sealed_index_cache,
		)
		if !initialized do return hgl.interesting("initialize message store")
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		now := nrc_time_unix_nanos()
		cutoff := now / i64(time.Hour) * i64(time.Hour) + i64(time.Hour / 2)
		store.purge_floor_ns = cutoff

		sequences: [220]u64
		live: [220]bool
		expired_prefix := int(expired_prefix_raw)
		expired_suffix := int(expired_suffix_raw)
		for i in 0 ..< target_count {
			live[i] = i >= expired_prefix && i < target_count - expired_suffix
			accepted_at := live[i] ? cutoff + i64(time.Second) : cutoff - i64(time.Second)
			message := test_retained_message(workspace, u64(conversation_id), u64(i * 2 + 1), accepted_at)
			result, sequence := append_or_deduplicate_message(store, &message)
			if result != .Appended do return hgl.interesting("append target message")
			sequences[i] = sequence

			distractor := test_retained_message(workspace, u64(distractor_conversation_id), u64(i * 2 + 2), cutoff + i64(time.Second))
			result, _ = append_or_deduplicate_message(store, &distractor)
			if result != .Appended do return hgl.interesting("append interleaved distractor")
		}
		if !rotate_message_store(store, cutoff + i64(2 * time.Second)) do return hgl.interesting("seal clustered message segment")

		queries := [4]struct {
			ascending: bool,
			cursor:    u64,
		}{{true, 0}, {false, 0}, {true, u64(cursor_raw)}, {false, u64(cursor_raw)}}
		cache_modes := [2]bool{true, false}
		for cache_enabled in cache_modes {
			if !cache_enabled do release_message_segment_index_cache(store, &store.segments[0])
			for query, query_index in queries {
				request := pr.MessageRangeRequest {
					conv_id        = conversation_id,
					cursor         = pr.MessageSeq(query.cursor),
					limit          = u16(limit_raw),
					correlation_id = u32(query_index + 1),
				}
				page, ok := retained_history_simulation_page(conn, request, query.ascending)
				if !ok do return hgl.interesting(cache_enabled ? "execute cached retained history page" : "execute fallback retained history page")
				if !retained_history_page_matches_model(
					page,
					conversation_id,
					sequences[:target_count],
					live[:target_count],
					query.cursor,
					int(limit_raw),
					query.ascending,
				) {
					return hgl.interesting(
						query.ascending ? "ascending retained history differs from model" : "descending retained history differs from model",
					)
				}
			}
		}
		return hgl.valid()
	}
}

@(test)
test_message_store_partial_prefix_purge_preserves_live_segments :: proc(t: ^testing.T) {
	workspace := "retained-message-partial-purge-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-partial-purge"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store; testing.expect(t, init_message_store(&store, dir, shard, time.Hour, 0))
	baseline := nrc_time_unix_nanos()
	timestamps := [3]i64{baseline - i64(2 * time.Hour), baseline + i64(time.Second), baseline + i64(2 * time.Second)}
	for accepted_at, i in timestamps {
		message := test_retained_message(workspace, 42, u64(i + 1), accepted_at)
		result, _ := append_or_deduplicate_message(&store, &message)
		if result == .Lookup_Required do result, _ = append_message_after_sealed_lookup(&store, &message)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect(t, rotate_message_store(&store, accepted_at + 1))
	}
	testing.expect_value(t, len(store.segments), 3)
	removed_generation := store.segments[0].generation
	live_a := store.segments[1]
	live_b := store.segments[2]
	expected_bytes := live_a.bytes + live_b.bytes + store.active_bytes
	testing.expect(t, maintain_message_store(&store, baseline))
	testing.expect_value(t, len(store.segments), 2)
	testing.expect_value(t, store.total_bytes, expected_bytes)
	testing.expect_value(t, store.segments[0].generation, live_a.generation)
	testing.expect_value(t, store.segments[1].generation, live_b.generation)
	live_generations := [2]u64{live_a.generation, live_b.generation}
	for generation in live_generations {
		wal_path := message_store_path(store.directory, generation, "wal")
		index_path := message_store_path(store.directory, generation, "idx")
		testing.expect(t, os.exists(wal_path)); testing.expect(t, os.exists(index_path))
		delete(wal_path); delete(index_path)
	}
	removed_wal := message_store_path(store.directory, removed_generation, "wal")
	removed_index := message_store_path(store.directory, removed_generation, "idx")
	testing.expect(t, !os.exists(removed_wal)); testing.expect(t, !os.exists(removed_index)); delete(removed_wal); delete(removed_index)
	testing.expect(t, shutdown_message_store(&store))
	testing.expect(t, init_message_store(&store, dir, shard, time.Hour, 0))
	testing.expect_value(t, len(store.segments), 2)
	testing.expect_value(t, store.segments[0].generation, live_a.generation)
	testing.expect_value(t, store.segments[1].generation, live_b.generation)
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_dirty_restart_recovers_and_deduplicates :: proc(t: ^testing.T) {
	workspace := "retained-message-dirty-restart-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-dirty-restart"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store; testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	now := nrc_time_unix_nanos()
	for marker in 1 ..= 2 {
		message := test_retained_message(workspace, 42, u64(marker), now + i64(marker))
		result, _ := append_or_deduplicate_message(&store, &message)
		testing.expect_value(t, result, Message_Store_Result.Appended)
	}
	crash_message_store_for_test(&store)
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	testing.expect_value(t, store.high_water, u64(2))
	retry := test_retained_message(workspace, 42, 2, now + i64(time.Second))
	result, sequence := append_or_deduplicate_message(&store, &retry)
	testing.expect_value(t, result, Message_Store_Result.Duplicate)
	testing.expect_value(t, sequence, u64(2))
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_short_write_poisons_and_restart_truncates_tail :: proc(t: ^testing.T) {
	workspace := "retained-message-short-write-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-short-write"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store; testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	persistence.clear_wal_write_fault_for_test(); defer persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)
	message := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
	previous_logger := context.logger; context.logger = log.nil_logger()
	result, _ := append_or_deduplicate_message(&store, &message)
	context.logger = previous_logger
	testing.expect_value(t, result, Message_Store_Result.Poisoned)
	testing.expect(t, persistence.wal_write_fault_triggered_for_test())
	testing.expect(t, store.poisoned && !store.wal.enabled)
	testing.expect_value(t, store.high_water, u64(0))
	crash_message_store_for_test(&store)
	persistence.clear_wal_write_fault_for_test()
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	testing.expect_value(t, store.high_water, u64(0))
	testing.expect_value(t, store.wal.record_count, u64(0))
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_fsync_failure_recovers_complete_kernel_accepted_record :: proc(t: ^testing.T) {
	workspace := "retained-message-fsync-failure-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-fsync-failure"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store; testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	persistence.clear_wal_sync_failure_for_test(); defer persistence.clear_wal_sync_failure_for_test()
	store.wal.pending_bytes = persistence.FSYNC_BYTE_THRESHOLD
	persistence.set_wal_sync_failure_for_test()
	message := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
	previous_logger := context.logger; context.logger = log.nil_logger()
	result, _ := append_or_deduplicate_message(&store, &message)
	context.logger = previous_logger
	testing.expect_value(t, result, Message_Store_Result.Poisoned)
	testing.expect(t, persistence.wal_sync_fault_triggered_for_test())
	testing.expect(t, store.poisoned && !store.wal.enabled)
	testing.expect_value(t, store.wal.record_count, u64(1))
	testing.expect_value(t, store.wal.durable_record_count, u64(0))
	crash_message_store_for_test(&store)
	persistence.clear_wal_sync_failure_for_test()
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	testing.expect_value(t, store.high_water, u64(1))
	testing.expect_value(t, store.wal.record_count, u64(1))
	testing.expect(t, shutdown_message_store(&store))
}

@(test)
test_message_store_exhaustive_active_wal_prefix_recovery :: proc(t: ^testing.T) {
	workspace := "retained-message-prefix-recovery-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-prefix-source"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store; testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	now := nrc_time_unix_nanos()
	ends: [3]int
	for marker in 1 ..= 3 {
		message := test_retained_message(workspace, 42, u64(marker), now + i64(marker))
		result, _ := append_or_deduplicate_message(&store, &message); testing.expect_value(t, result, Message_Store_Result.Appended)
		ends[marker - 1] = int(store.active_bytes)
	}
	active_path := message_store_path(store.directory, store.active_generation, "wal"); defer delete(active_path)
	testing.expect(t, shutdown_message_store(&store))
	wal_bytes, read_err := os.read_entire_file(active_path, context.allocator); testing.expect(t, read_err == nil); defer delete(wal_bytes)
	cut_path := test_wal_path("message-store-prefix-cut"); defer os.remove(cut_path)
	for cut in 0 ..= len(wal_bytes) {
		testing.expect(t, os.write_entire_file(cut_path, wal_bytes[:cut]) == nil)
		message_scan_context = {
			mode = .Validate,
		}
		previous_logger := context.logger; context.logger = log.nil_logger()
		inspection := persistence.inspect_wal_file_with_tail_recovery(cut_path, MESSAGE_WAL_MAGIC, shard, message_scan_record)
		context.logger = previous_logger
		message_scan_context = {}
		expected_count, expected_end := 0, 0
		for record_end in ends {if record_end <= cut {expected_count += 1; expected_end = record_end}}
		testing.expectf(t, inspection.ok, "cut=%d should recover", cut)
		testing.expectf(t, inspection.record_count == u64(expected_count), "cut=%d count=%d want=%d", cut, inspection.record_count, expected_count)
		testing.expectf(t, inspection.file_size == u64(expected_end), "cut=%d size=%d want=%d", cut, inspection.file_size, expected_end)
	}
}

@(test)
test_message_store_complete_record_corruption_fails_closed_without_truncation :: proc(t: ^testing.T) {
	workspace := "retained-message-corruption-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-corruption"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	store: Message_Store; testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	message := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
	result, _ := append_or_deduplicate_message(&store, &message); testing.expect_value(t, result, Message_Store_Result.Appended)
	active_path := message_store_path(store.directory, store.active_generation, "wal"); defer delete(active_path)
	testing.expect(t, shutdown_message_store(&store))
	wal_bytes, read_err := os.read_entire_file(active_path, context.allocator); testing.expect(t, read_err == nil); defer delete(wal_bytes)
	testing.expect(t, len(wal_bytes) > persistence.LOG_HEADER_SIZE)
	wal_bytes[persistence.LOG_HEADER_SIZE] ~= 0x80
	testing.expect(t, os.write_entire_file(active_path, wal_bytes) == nil)
	original_size := len(wal_bytes)
	previous_logger := context.logger; context.logger = log.nil_logger()
	initialized := init_message_store(&store, dir, shard, 24 * time.Hour, 0)
	context.logger = previous_logger
	testing.expect(t, !initialized)
	file, open_err := os.open(active_path); testing.expect(t, open_err == nil)
	if open_err == nil {size, _ := os.file_size(file); os.close(file); testing.expect_value(t, size, i64(original_size))}
	destroy_active_message_indexes(&store); delete(store.segments); delete(store.directory); store = {}
}
