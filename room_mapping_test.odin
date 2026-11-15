package main
import "core:strings"
import "core:testing"
import hgl "hegel"
import pr "protocol"
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
