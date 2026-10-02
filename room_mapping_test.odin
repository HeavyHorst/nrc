package main

// Tests workspace/conversation room mapping and subscription bookkeeping in the
// main server state. The generated cases model joins/leaves/lookups to catch stale
// room membership, duplicate entries, and workspace cleanup mistakes.

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "byte_pool"
import hgl "hegel"
import pr "protocol"

@(thread_local)
room_mapping_test_wal_path: string

init_room_mapping_test_state :: proc(wal_suffix, workspace_id: string) -> bool {
	td.thread_index = 91
	td.workspaces = make(map[string]^Workspace_State)
	strings.intern_init(&td.workspace_intern)
	td.spool = byte_pool.init_buffer_pool()
	room_mapping_test_wal_path = test_wal_path(wal_suffix)
	_ = os.remove(room_mapping_test_wal_path)
	if os.write_entire_file(room_mapping_test_wal_path, nil) != nil {
		cleanup_room_mapping_test_state()
		return false
	}
	workspace := transmute([]byte)workspace_id
	shard := int(shard_for_workspace(workspace))
	td.shard_writers.worker = 0
	td.shard_writers.worker_count = 1
	for &index in td.shard_writers.writer_index do index = -1
	_, append_err := append(&td.shard_writers.writers, Shard_Transaction_Writer{})
	if append_err != nil || !init_shard_transaction_writer(&td.shard_writers.writers[0], room_mapping_test_wal_path, shard, 0, 1) {
		cleanup_room_mapping_test_state()
		return false
	}
	td.shard_writers.writer_index[shard] = 0
	td.shard_writers.mode = .Active
	td.asset_seq = 0
	return true
}

cleanup_room_mapping_test_state :: proc() {
	shutdown_shard_writer_registry(&td.shard_writers)
	if room_mapping_test_wal_path != "" {
		_ = os.remove(room_mapping_test_wal_path)
		room_mapping_test_wal_path = ""
	}
	cleanup_workspaces()
	strings.intern_destroy(&td.workspace_intern)
	if td.spool != nil {
		byte_pool.destroy_buffer_pool(td.spool)
		td.spool = nil
	}
}

make_room_mapping_test_connection :: proc(workspace_id: string) -> NRC_Connection {
	c := NRC_Connection {
		state             = .Closed,
		workspace_id      = workspace_id,
		verified_username = "tester",
		authenticated     = true,
	}
	send_queue_init(&c)
	return c
}

@(test)
test_room_mapping_normalize_examples :: proc(t: ^testing.T) {
	out: [MAX_ROOM_MAPPING_NAME_LENGTH]byte

	name, ok := normalize_room_mapping_name(transmute([]byte)string("  #ops-room_1  "), out[:])
	testing.expect(t, ok, "valid room name should normalize")
	testing.expect(t, name == "OPS-ROOM_1", "room name should trim, strip #, and uppercase")

	_, ok = normalize_room_mapping_name(transmute([]byte)string(""), out[:])
	testing.expect(t, !ok, "empty room name should be rejected")

	_, ok = normalize_room_mapping_name(transmute([]byte)string("bad room"), out[:])
	testing.expect(t, !ok, "spaces inside a room name should be rejected")

	_, ok = normalize_room_mapping_name(transmute([]byte)string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), out[:])
	testing.expect(t, !ok, "room names longer than 32 bytes should be rejected")

	short_out: [MAX_ROOM_MAPPING_NAME_LENGTH - 1]byte
	_, ok = normalize_room_mapping_name(transmute([]byte)string("OPS"), short_out[:])
	testing.expect(t, !ok, "output buffer must be large enough for max room names")
}

@(test)
test_room_mapping_builtin_names_and_generated_ids_are_reserved_safe :: proc(t: ^testing.T) {
	conv_id, ok := builtin_room_id_for_name("ENGINEERING")
	testing.expect(t, ok, "ENGINEERING should be built in")
	testing.expect_value(t, conv_id, ENGINEERING_ROOM_ID)

	conv_id, ok = builtin_room_id_for_name("OPERATIONS")
	testing.expect(t, ok, "OPERATIONS should be built in")
	testing.expect_value(t, conv_id, OPERATIONS_ROOM_ID)

	conv_id, ok = builtin_room_id_for_name("SYSTEM")
	testing.expect(t, ok, "SYSTEM should be built in")
	testing.expect_value(t, conv_id, SYSTEM_ROOM_ID)

	testing.expect(t, is_reserved_room_id(ENGINEERING_ROOM_ID), "ENGINEERING id should be reserved")
	testing.expect(t, is_reserved_room_id(OPERATIONS_ROOM_ID), "OPERATIONS id should be reserved")
	testing.expect(t, is_reserved_room_id(SYSTEM_ROOM_ID), "SYSTEM id should be reserved")
	testing.expect(t, is_reserved_room_id(pr.ConversationID(pr.DM_CONV_FLAG | 123)), "DM high-bit ids should be reserved")

	dynamic_id := make_room_mapping_conv_id("workspace-a", "OPS")
	testing.expect(t, !is_reserved_room_id(dynamic_id), "generated dynamic room id must not collide with reserved ids")
	testing.expect_value(t, dynamic_id, make_room_mapping_conv_id("workspace-a", "OPS"))
	testing.expect(t, dynamic_id != make_room_mapping_conv_id("workspace-b", "OPS"), "workspace should participate in dynamic room id derivation")
}

@(test)
test_room_mapping_payload_is_valid_json_shape :: proc(t: ^testing.T) {
	payload := build_room_mapping_payload("REZEPTE", 123)
	defer delete(payload)

	testing.expect(
		t,
		payload == "{\"version\":1,\"normalized_name\":\"REZEPTE\",\"display_name\":\"REZEPTE\",\"conv_id\":\"123\"}",
		"room mapping payload should be parseable JSON without formatter artifacts",
	)
	testing.expect(t, !strings.contains(payload, "%!(MISSING"), "room mapping payload must not contain formatter errors")
}

@(test)
test_room_mapping_index_and_remove :: proc(t: ^testing.T) {
	workspace_id := "room-index-test"
	if !init_room_mapping_test_state("room_mapping_create_handler.log", workspace_id) {
		testing.expect(t, false, "room mapping test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	ws := get_or_create_workspace(workspace_id)

	asset := pr.Asset {
		asset_type = .RoomMapping,
		asset_id   = 11,
		conv_id    = pr.WORKSPACE_DATA_ID,
		preview    = transmute([]byte)string("ops"),
	}
	index_room_mapping_asset(ws, workspace_id, &asset)

	mapping, exists := ws.room_mappings["OPS"]
	testing.expect(t, exists, "room mapping asset should index by normalized preview")
	testing.expect_value(t, mapping.asset_id, pr.AssetID(11))
	testing.expect_value(t, mapping.conv_id, make_room_mapping_conv_id(workspace_id, "OPS"))

	duplicate := pr.Asset {
		asset_type = .RoomMapping,
		asset_id   = 12,
		conv_id    = pr.WORKSPACE_DATA_ID,
		preview    = transmute([]byte)string("#OPS"),
	}
	index_room_mapping_asset(ws, workspace_id, &duplicate)
	mapping = ws.room_mappings["OPS"]
	testing.expect_value(t, mapping.asset_id, pr.AssetID(11))

	non_system := pr.Asset {
		asset_type = .RoomMapping,
		asset_id   = 13,
		conv_id    = ENGINEERING_ROOM_ID,
		preview    = transmute([]byte)string("ENG-ALIAS"),
	}
	index_room_mapping_asset(ws, workspace_id, &non_system)
	_, exists = ws.room_mappings["ENG-ALIAS"]
	testing.expect(t, !exists, "room mappings outside workspace data should not be indexed")

	remove_room_mapping_asset(ws, &duplicate)
	_, exists = ws.room_mappings["OPS"]
	testing.expect(t, exists, "removing a stale duplicate asset should not remove the active mapping")

	remove_room_mapping_asset(ws, &asset)
	_, exists = ws.room_mappings["OPS"]
	testing.expect(t, !exists, "removing the indexed asset should remove the mapping")
}

@(test)
test_room_mapping_persistence_replay_indexes_and_delete_removes_mapping :: proc(t: ^testing.T) {
	workspace_id := "room-persist-test"
	if !init_room_mapping_test_state("room_mapping_lookup_generated.log", workspace_id) {
		testing.expect(t, false, "room mapping test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	conv_id := make_room_mapping_conv_id(workspace_id, "INCIDENT")
	payload := build_room_mapping_payload("INCIDENT", conv_id)
	defer delete(payload)

	asset := pr.Asset {
		asset_type       = .RoomMapping,
		asset_id         = 21,
		parent_type      = .None,
		parent_id        = 0,
		owner            = transmute([]byte)string("tester"),
		created_at       = 100,
		updated_at       = 100,
		conv_id          = SYSTEM_ROOM_ID,
		payload_encoding = .Plain,
		payload_raw_len  = u32(len(payload)),
		preview          = transmute([]byte)string("INCIDENT"),
		payload          = transmute([]byte)payload,
	}

	// Exercise serialized legacy replay, not the generic map-only apply helper.
	create, create_ok := build_shard_asset_mutation(transmute([]byte)workspace_id, .Create, &asset, {})
	defer destroy_shard_mutation_transaction(&create)
	testing.expect(t, create_ok)
	if !create_ok do return
	testing.expect(t, apply_shard_mutation(create.tx.workspace, create.tx.mutations[0]))

	ws := get_workspace(workspace_id)
	testing.expect(t, ws != nil, "replay should create workspace")
	mapping, exists := ws.room_mappings["INCIDENT"]
	testing.expect(t, exists, "replayed room mapping asset should rebuild workspace registry")
	testing.expect_value(t, mapping.asset_id, pr.AssetID(21))
	testing.expect_value(t, mapping.conv_id, conv_id)

	conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil, "replay should create workspace data scope")
	testing.expect(t, conv.assets[21] != nil, "replayed room mapping asset should be stored in workspace data")
	if conv.assets[21] != nil do testing.expect_value(t, string(conv.assets[21].payload), payload)

	remove, remove_ok := build_shard_asset_delete_mutation(transmute([]byte)workspace_id, SYSTEM_ROOM_ID, 21, {asset = 21})
	defer destroy_shard_mutation_transaction(&remove)
	testing.expect(t, remove_ok)
	if !remove_ok do return
	testing.expect(t, apply_shard_mutation(remove.tx.workspace, remove.tx.mutations[0]))
	_, exists = ws.room_mappings["INCIDENT"]
	testing.expect(t, !exists, "persisted delete should remove workspace registry entry")
	testing.expect(t, conv.assets[21] == nil, "legacy persisted delete should remove workspace data asset")
}

@(test)
test_room_mapping_create_handler_is_authoritative_and_idempotent :: proc(t: ^testing.T) {
	workspace_id := "room-create-test"
	if !init_room_mapping_test_state("room_mapping_subscriptions_generated.log", workspace_id) {
		testing.expect(t, false, "room mapping test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)

	bad_conv_req := pr.CreateAssetRequest {
		conv_id        = ENGINEERING_ROOM_ID,
		asset_type     = .RoomMapping,
		parent_type    = .None,
		parent_id      = 0,
		preview        = transmute([]byte)string("ops"),
		payload        = transmute([]byte)string("{}"),
		correlation_id = 1,
	}
	handle_create_asset(&c, bad_conv_req)
	testing.expect(t, get_workspace(workspace_id) == nil, "room mappings outside workspace data should be rejected before workspace mutation")

	reserved_req := bad_conv_req
	reserved_req.conv_id = pr.WORKSPACE_DATA_ID
	reserved_req.preview = transmute([]byte)string("ENGINEERING")
	handle_create_asset(&c, reserved_req)
	testing.expect(t, get_workspace(workspace_id) == nil, "reserved room names should be rejected before workspace mutation")

	parent_req := bad_conv_req
	parent_req.conv_id = pr.WORKSPACE_DATA_ID
	parent_req.parent_type = .Task
	parent_req.parent_id = 9
	handle_create_asset(&c, parent_req)
	testing.expect(t, get_workspace(workspace_id) == nil, "room mappings with parents should be rejected before workspace mutation")

	create_req := bad_conv_req
	create_req.conv_id = pr.WORKSPACE_DATA_ID
	create_req.preview = transmute([]byte)string("  #ops  ")
	handle_create_asset(&c, create_req)

	ws := get_workspace(workspace_id)
	testing.expect(t, ws != nil, "valid room mapping create should create workspace")
	conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil, "valid room mapping create should create workspace data scope")
	testing.expect_value(t, len(conv.assets), 1)

	mapping, exists := ws.room_mappings["OPS"]
	testing.expect(t, exists, "valid room mapping create should index mapping")
	testing.expect_value(t, mapping.asset_id, pr.AssetID(1))
	testing.expect_value(t, mapping.conv_id, make_room_mapping_conv_id(workspace_id, "OPS"))

	asset := conv.assets[mapping.asset_id]
	testing.expect(t, asset != nil, "created mapping asset should be present")
	testing.expect(t, string(asset.preview) == "OPS", "created mapping preview should be normalized")
	expected_payload := build_room_mapping_payload("OPS", mapping.conv_id)
	defer delete(expected_payload)
	testing.expect(t, string(asset.payload) == expected_payload, "created mapping payload should be server-authored")

	duplicate_req := create_req
	duplicate_req.preview = transmute([]byte)string("OPS")
	handle_create_asset(&c, duplicate_req)
	testing.expect_value(t, len(conv.assets), 1)
	mapping = ws.room_mappings["OPS"]
	testing.expect_value(t, mapping.asset_id, pr.AssetID(1))
}

@(test)
test_room_mapping_stale_registry_entry_changes_only_after_persistence :: proc(t: ^testing.T) {
	workspace_id := "room-stale-registry-test"
	if !init_room_mapping_test_state("room_mapping_stale_registry.log", workspace_id) {
		testing.expect(t, false, "room mapping test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	ws := get_or_create_workspace(workspace_id)
	conv := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
	ws.room_mappings["OPS"] = {
		conv_id  = 999,
		asset_id = 77,
	}
	req := pr.CreateAssetRequest {
		conv_id        = pr.WORKSPACE_DATA_ID,
		asset_type     = .RoomMapping,
		parent_type    = .None,
		preview        = transmute([]byte)string("OPS"),
		correlation_id = 7,
	}
	writer := &td.shard_writers.writers[0]
	writer.clean_backlog_bytes = SHARD_CLEAN_BACKLOG_HARD_BYTES
	previous_logger := context.logger
	context.logger = log.nil_logger()
	handle_create_asset(&c, req)
	context.logger = previous_logger

	mapping := ws.room_mappings["OPS"]
	testing.expect_value(t, mapping.asset_id, pr.AssetID(77))
	testing.expect_value(t, len(conv.assets), 0)
	testing.expect_value(t, writer.wal.record_count, u64(0))

	writer.clean_backlog_bytes = 0
	handle_create_asset(&c, req)
	mapping = ws.room_mappings["OPS"]
	testing.expect(t, mapping.asset_id != 77 && conv.assets[mapping.asset_id] != nil, "accepted create should replace the stale registry entry")
	testing.expect_value(t, len(conv.assets), 1)
	testing.expect_value(t, writer.wal.record_count, u64(1))
	handle_create_asset(&c, req)
	testing.expect_value(t, len(conv.assets), 1)
	testing.expect_value(t, writer.wal.record_count, u64(1))
}

@(test)
test_room_mapping_assets_are_immutable_through_generic_handlers :: proc(t: ^testing.T) {
	workspace_id := "room-immutable-test"
	if !init_room_mapping_test_state("room_mapping_immutable_asset_update.log", workspace_id) {
		testing.expect(t, false, "room mapping test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)

	ws := get_or_create_workspace(workspace_id)
	conv := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
	payload := build_room_mapping_payload("OPS", make_room_mapping_conv_id(workspace_id, "OPS"))
	defer delete(payload)

	asset := alloc_asset(transmute([]byte)string("tester"), transmute([]byte)string("OPS"), transmute([]byte)payload)
	testing.expect(t, asset != nil, "test asset allocation should succeed")
	asset.asset_type = .RoomMapping
	asset.asset_id = 31
	asset.parent_type = .None
	asset.parent_id = 0
	asset.created_at = 100
	asset.updated_at = 100
	asset.conv_id = pr.WORKSPACE_DATA_ID
	asset.payload_encoding = .Plain
	asset.payload_raw_len = u32(len(payload))
	conv.assets[asset.asset_id] = asset
	index_room_mapping_asset(ws, workspace_id, asset)

	update_req := pr.UpdateAssetRequest {
		conv_id        = pr.WORKSPACE_DATA_ID,
		asset_id       = 31,
		preview        = transmute([]byte)string("OPS2"),
		payload        = transmute([]byte)string("{}"),
		correlation_id = 7,
	}
	handle_update_asset(&c, update_req)
	testing.expect(t, conv.assets[31] == asset, "generic update should not replace room mapping asset")
	testing.expect(t, string(conv.assets[31].preview) == "OPS", "generic update should not mutate room mapping preview")

	delete_req := pr.DeleteAssetRequest {
		conv_id        = pr.WORKSPACE_DATA_ID,
		asset_id       = 31,
		correlation_id = 8,
	}
	handle_delete_asset(&c, delete_req)
	testing.expect(t, conv.assets[31] == asset, "generic delete should not remove room mapping asset")
	_, exists := ws.room_mappings["OPS"]
	testing.expect(t, exists, "generic delete should not remove room mapping registry entry")
}

@(test)
test_hegel_room_mapping_normalize_idempotent :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_room_mapping_normalize_idempotent, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel room mapping normalize property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_room_mapping_normalize_idempotent :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	data, draw_err := hgl.draw_bytes(tc, 0, 64)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw room name bytes")
	}
	defer delete(data)

	out1: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
	name1, ok1 := normalize_room_mapping_name(data, out1[:])
	if !ok1 {
		return hgl.valid()
	}

	if len(name1) == 0 || len(name1) > MAX_ROOM_MAPPING_NAME_LENGTH {
		return hgl.interesting("normalized name length out of bounds")
	}
	for ch in transmute([]byte)name1 {
		is_valid := (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-'
		if !is_valid {
			return hgl.interesting("normalized name contains invalid byte")
		}
	}

	out2: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
	name2, ok2 := normalize_room_mapping_name(transmute([]byte)name1, out2[:])
	if !ok2 {
		return hgl.interesting("normalized name did not re-normalize")
	}
	if name1 != name2 {
		return hgl.interesting("normalization is not idempotent")
	}

	return hgl.valid()
}

@(test)
test_hegel_room_mapping_generated_ids_are_stable_and_unreserved :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_room_mapping_generated_ids_are_stable_and_unreserved, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel room mapping id property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_room_mapping_generated_ids_are_stable_and_unreserved :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	workspace_bytes, draw_err := hgl.draw_bytes(tc, 0, 64)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw workspace bytes")
	}
	defer delete(workspace_bytes)

	name_bytes, name_draw_err := hgl.draw_bytes(tc, 1, MAX_ROOM_MAPPING_NAME_LENGTH)
	if name_draw_err == .Stop_Test {
		return hgl.abort()
	}
	if name_draw_err != nil {
		return hgl.interesting("draw room name bytes")
	}
	defer delete(name_bytes)

	alphabet := transmute([]byte)string("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
	name_storage: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
	for b, i in name_bytes {
		name_storage[i] = alphabet[int(b) % len(alphabet)]
	}
	name := string(name_storage[:len(name_bytes)])
	if _, is_builtin := builtin_room_id_for_name(name); is_builtin {
		return hgl.valid()
	}

	workspace_id := string(workspace_bytes)
	conv_id := make_room_mapping_conv_id(workspace_id, name)
	if conv_id != make_room_mapping_conv_id(workspace_id, name) {
		return hgl.interesting("dynamic room id is not deterministic")
	}
	if is_reserved_room_id(conv_id) {
		return hgl.interesting("dynamic room id is reserved")
	}

	return hgl.valid()
}
