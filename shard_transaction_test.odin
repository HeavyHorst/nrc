package main

import "core:bytes"
import "core:encoding/endian"
import "core:testing"

import hgl "hegel"

Shard_Test_Visit_Context :: struct {
	expected:  []Shard_Mutation,
	seen:      int,
	reject_at: int,
	valid:     bool,
}

shard_test_visit :: proc(mutation: Shard_Mutation, data: rawptr) -> bool {
	ctx := (^Shard_Test_Visit_Context)(data)
	if ctx.seen >= len(ctx.expected) {
		ctx.valid = false
		return false
	}
	expected := ctx.expected[ctx.seen]
	if mutation.domain != expected.domain ||
	   mutation.op != expected.op ||
	   mutation.entity_record_version != expected.entity_record_version ||
	   !bytes.equal(mutation.payload, expected.payload) {
		ctx.valid = false
	}
	current := ctx.seen
	ctx.seen += 1
	return current != ctx.reject_at
}

shard_test_transaction :: proc(mutations: ^[3]Shard_Mutation) -> Shard_Transaction {
	mutations^ = [3]Shard_Mutation {
		{domain = .Task, op = 1, entity_record_version = 1, payload = transmute([]byte)string("\xaa\xbb")},
		{domain = .Asset, op = 3, entity_record_version = 3, payload = transmute([]byte)string("\x00\xff")},
		{domain = .Edge, op = 2, entity_record_version = 1},
	}
	return {workspace = transmute([]byte)string("ws"), task_high_water = 1, asset_high_water = 2, edge_high_water = 3, mutations = mutations[:]}
}

@(test)
test_shard_schema_fixed_identity_and_hash_vectors :: proc(t: ^testing.T) {
	testing.expect_value(t, SHARD_WAL_MAGIC, u32(0x4e524357))
	testing.expect_value(t, SHARD_WAL_VERSION, u16(1))
	testing.expect_value(t, Shard_Log_Op.Transaction, Shard_Log_Op(1))
	testing.expect_value(t, LOGICAL_SHARD_COUNT, 256)
	testing.expect_value(t, shard_for_workspace(nil), u8(0x99)) // XXH64(empty)=ef46db3751d8e999
	testing.expect_value(t, shard_for_workspace({byte('a')}), u8(0x5b)) // d24ec4f1a98c6e5b
	testing.expect(t, shard_for_workspace({byte('A')}) != shard_for_workspace({byte('a')}))
	raw := [?]byte{0, 0xff, 0xc3, 0xa9}
	testing.expect_value(t, shard_for_workspace(raw[:]), u8(0x4a)) // f3ec84cbf994164a
	for i in 0 ..< 1000 {
		workspace := [?]byte{byte(i >> 8), byte(i)}
		shard := shard_for_workspace(workspace[:])
		testing.expect(t, int(shard) < LOGICAL_SHARD_COUNT)
		testing.expect_value(t, shard_for_workspace(workspace[:]), shard)
	}
}

@(test)
test_shard_transaction_fixed_vector_and_exact_roundtrip :: proc(t: ^testing.T) {
	mutations: [3]Shard_Mutation
	tx := shard_test_transaction(&mutations)
	expected := [?]byte {
		0x00,
		0x02,
		0x77,
		0x73,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x01,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x02,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x03,
		0x00,
		0x00,
		0x00,
		0x03,
		0x00,
		0x00,
		0x00,
		0x00,
		0x01,
		0x01,
		0x00,
		0x01,
		0x00,
		0x00,
		0x00,
		0x02,
		0xaa,
		0xbb,
		0x02,
		0x03,
		0x00,
		0x03,
		0x00,
		0x00,
		0x00,
		0x02,
		0x00,
		0xff,
		0x03,
		0x02,
		0x00,
		0x01,
		0x00,
		0x00,
		0x00,
		0x00,
	}
	size, size_err := shard_transaction_size(&tx)
	testing.expect_value(t, size_err, Shard_Transaction_Error.None)
	testing.expect_value(t, size, len(expected))
	buf: [len(expected)]byte
	testing.expect_value(t, encode_shard_transaction(&tx, buf[:]), Shard_Transaction_Error.None)
	testing.expect(t, bytes.equal(buf[:], expected[:]))

	view, err := decode_shard_transaction(buf[:])
	testing.expect_value(t, err, Shard_Transaction_Error.None)
	testing.expect(t, bytes.equal(view.workspace, tx.workspace))
	testing.expect_value(t, view.task_high_water, tx.task_high_water)
	testing.expect_value(t, view.asset_high_water, tx.asset_high_water)
	testing.expect_value(t, view.edge_high_water, tx.edge_high_water)
	ctx := Shard_Test_Visit_Context {
		expected  = tx.mutations,
		reject_at = -1,
		valid     = true,
	}
	testing.expect(t, visit_shard_transaction_mutations(&view, shard_test_visit, &ctx))
	testing.expect(t, ctx.valid)
	testing.expect_value(t, ctx.seen, len(tx.mutations))
}

@(test)
test_shard_transaction_zero_mutation_watermark_and_workspace_bounds :: proc(t: ^testing.T) {
	tx := Shard_Transaction {
		workspace        = {1},
		task_high_water  = 9,
		asset_high_water = 8,
		edge_high_water  = 7,
	}
	size, err := shard_transaction_size(&tx)
	testing.expect_value(t, err, Shard_Transaction_Error.None)
	buf: [35]byte
	testing.expect_value(t, size, len(buf))
	testing.expect_value(t, encode_shard_transaction(&tx, buf[:]), Shard_Transaction_Error.None)
	view, decode_err := decode_shard_transaction(buf[:])
	testing.expect_value(t, decode_err, Shard_Transaction_Error.None)
	testing.expect_value(t, view.mutation_count, u32(0))
	testing.expect_value(t, view.task_high_water, u64(9))

	empty := tx; empty.workspace = nil
	_, empty_err := shard_transaction_size(&empty)
	testing.expect_value(t, empty_err, Shard_Transaction_Error.Malformed)

	max_workspace := make([]byte, int(max(u16))); defer delete(max_workspace)
	for &b in max_workspace do b = 0x5a
	max_tx := tx; max_tx.workspace = max_workspace
	max_size, max_err := shard_transaction_size(&max_tx)
	testing.expect_value(t, max_err, Shard_Transaction_Error.None)
	max_buf := make([]byte, max_size); defer delete(max_buf)
	testing.expect_value(t, encode_shard_transaction(&max_tx, max_buf), Shard_Transaction_Error.None)
	max_view, max_decode_err := decode_shard_transaction(max_buf)
	testing.expect_value(t, max_decode_err, Shard_Transaction_Error.None)
	testing.expect_value(t, len(max_view.workspace), int(max(u16)))

	too_long_workspace := make([]byte, int(max(u16)) + 1); defer delete(too_long_workspace)
	too_long := tx; too_long.workspace = too_long_workspace
	_, too_long_err := shard_transaction_size(&too_long)
	testing.expect_value(t, too_long_err, Shard_Transaction_Error.Too_Large)
}

@(test)
test_shard_transaction_supported_matrix_and_error_classes :: proc(t: ^testing.T) {
	for op in 1 ..= 4 do testing.expect(t, shard_mutation_supported(.Task, u8(op), 1))
	for version in 1 ..= 3 do for op in 1 ..= 3 do testing.expect(t, shard_mutation_supported(.Asset, u8(op), u16(version)))
	for op in 1 ..= 2 do testing.expect(t, shard_mutation_supported(.Edge, u8(op), 1))
	for domain in ([?]Shard_Mutation_Domain{.Task, .Asset, .Edge}) {
		for version in 0 ..= 4 {
			for op in 0 ..= 5 {
				expected :=
					(domain == .Task && version == 1 && op >= 1 && op <= 4) ||
					(domain == .Asset && version >= 1 && version <= 3 && op >= 1 && op <= 3) ||
					(domain == .Edge && version == 1 && op >= 1 && op <= 2)
				testing.expect_value(t, shard_mutation_supported(domain, u8(op), u16(version)), expected)
			}
		}
	}
	testing.expect(t, !shard_mutation_supported(Shard_Mutation_Domain(0xff), 1, 1))

	mutations: [3]Shard_Mutation
	tx := shard_test_transaction(&mutations)
	unsupported := tx
	unsupported.mutations = []Shard_Mutation{{domain = .Task, op = 1, entity_record_version = 2}}
	_, unsupported_err := shard_transaction_size(&unsupported)
	testing.expect_value(t, unsupported_err, Shard_Transaction_Error.Unsupported)

	size, _ := shard_transaction_size(&tx)
	buf := make([]byte, size); defer delete(buf)
	testing.expect_value(t, encode_shard_transaction(&tx, buf), Shard_Transaction_Error.None)
	first_entry := 2 + len(tx.workspace) + 32
	for field in ([?]int{0, 1, 2}) {
		bad := make([]byte, len(buf)); copy(bad, buf)
		switch field {
		case 0:
			bad[first_entry] = 0xff
		case 1:
			bad[first_entry + 1] = 0xff
		case 2:
			endian.put_u16(bad[first_entry + 2:], .Big, 0xffff)
		}
		_, bad_err := decode_shard_transaction(bad)
		testing.expect_value(t, bad_err, Shard_Transaction_Error.Unsupported)
		delete(bad)
	}

	bad_reserved := make([]byte, len(buf)); defer delete(bad_reserved); copy(bad_reserved, buf)
	bad_reserved[first_entry - 4] = 1
	_, malformed := decode_shard_transaction(bad_reserved)
	testing.expect_value(t, malformed, Shard_Transaction_Error.Malformed)

	oversized := make([]byte, SHARD_TRANSACTION_MAX_SIZE + 1); defer delete(oversized)
	_, too_large := decode_shard_transaction(oversized)
	testing.expect_value(t, too_large, Shard_Transaction_Error.Too_Large)
}

@(test)
test_shard_transaction_validates_before_traversal_and_rejection_stops :: proc(t: ^testing.T) {
	mutations: [3]Shard_Mutation
	tx := shard_test_transaction(&mutations)
	size, _ := shard_transaction_size(&tx)
	buf := make([]byte, size); defer delete(buf)
	testing.expect_value(t, encode_shard_transaction(&tx, buf), Shard_Transaction_Error.None)

	for n in 0 ..< len(buf) {
		_, err := decode_shard_transaction(buf[:n])
		testing.expect(t, err != .None, "every truncated prefix must fail")
	}

	trailing := make([]byte, len(buf) + 1); defer delete(trailing); copy(trailing, buf)
	_, trailing_err := decode_shard_transaction(trailing)
	testing.expect_value(t, trailing_err, Shard_Transaction_Error.Malformed)

	count_offset := 2 + len(tx.workspace) + 24
	count_mismatch := make([]byte, len(buf)); defer delete(count_mismatch); copy(count_mismatch, buf)
	endian.put_u32(count_mismatch[count_offset:], .Big, 4)
	_, count_err := decode_shard_transaction(count_mismatch)
	testing.expect_value(t, count_err, Shard_Transaction_Error.Malformed)

	too_many := make([]byte, len(buf)); defer delete(too_many); copy(too_many, buf)
	endian.put_u32(too_many[count_offset:], .Big, SHARD_TRANSACTION_MAX_MUTATIONS + 1)
	_, too_many_err := decode_shard_transaction(too_many)
	testing.expect_value(t, too_many_err, Shard_Transaction_Error.Too_Large)

	last_entry := len(buf) - 8
	bad_final := make([]byte, len(buf)); defer delete(bad_final); copy(bad_final, buf)
	bad_final[last_entry] = 0xff
	bad_view, final_err := decode_shard_transaction(bad_final)
	testing.expect_value(t, final_err, Shard_Transaction_Error.Unsupported)
	callbacks := Shard_Test_Visit_Context {
		expected  = tx.mutations,
		reject_at = -1,
		valid     = true,
	}
	if final_err == .None do _ = visit_shard_transaction_mutations(&bad_view, shard_test_visit, &callbacks)
	testing.expect_value(t, callbacks.seen, 0)

	view, valid_err := decode_shard_transaction(buf)
	testing.expect_value(t, valid_err, Shard_Transaction_Error.None)
	reject := Shard_Test_Visit_Context {
		expected  = tx.mutations,
		reject_at = 1,
		valid     = true,
	}
	testing.expect(t, !visit_shard_transaction_mutations(&view, shard_test_visit, &reject))
	testing.expect(t, reject.valid)
	testing.expect_value(t, reject.seen, 2)
}

@(test)
test_shard_transaction_size_caps_and_no_partial_encode :: proc(t: ^testing.T) {
	mutations: [3]Shard_Mutation
	tx := shard_test_transaction(&mutations)
	size, _ := shard_transaction_size(&tx)
	for output_size in ([?]int{size - 1, size + 1}) {
		out := make([]byte, output_size); defer delete(out)
		for &b in out do b = 0xa5
		before := make([]byte, len(out)); defer delete(before); copy(before, out)
		testing.expect_value(t, encode_shard_transaction(&tx, out), Shard_Transaction_Error.Malformed)
		testing.expect(t, bytes.equal(out, before), "wrong-sized output must remain untouched")
	}

	unsupported := tx; unsupported.mutations[2].entity_record_version = 2
	out := make([]byte, size); defer delete(out)
	for &b in out do b = 0x5a
	before := make([]byte, len(out)); defer delete(before); copy(before, out)
	testing.expect_value(t, encode_shard_transaction(&unsupported, out), Shard_Transaction_Error.Unsupported)
	testing.expect(t, bytes.equal(out, before), "invalid input must not partially encode")

	max_mutations := make([]Shard_Mutation, SHARD_TRANSACTION_MAX_MUTATIONS); defer delete(max_mutations)
	for &m in max_mutations do m = {
		domain                = .Edge,
		op                    = 2,
		entity_record_version = 1,
	}
	boundary := Shard_Transaction {
		workspace = {1},
		mutations = max_mutations,
	}
	boundary_size, boundary_err := shard_transaction_size(&boundary)
	testing.expect_value(t, boundary_err, Shard_Transaction_Error.None)
	boundary_buf := make([]byte, boundary_size); defer delete(boundary_buf)
	testing.expect_value(t, encode_shard_transaction(&boundary, boundary_buf), Shard_Transaction_Error.None)
	boundary_view, boundary_decode_err := decode_shard_transaction(boundary_buf)
	testing.expect_value(t, boundary_decode_err, Shard_Transaction_Error.None)
	testing.expect_value(t, boundary_view.mutation_count, u32(SHARD_TRANSACTION_MAX_MUTATIONS))

	too_many_mutations := make([]Shard_Mutation, SHARD_TRANSACTION_MAX_MUTATIONS + 1); defer delete(too_many_mutations)
	too_many_tx := Shard_Transaction {
		workspace = {1},
		mutations = too_many_mutations,
	}
	_, too_many_err := shard_transaction_size(&too_many_tx)
	testing.expect_value(t, too_many_err, Shard_Transaction_Error.Too_Large)

	max_payload := make([]byte, SHARD_TRANSACTION_MAX_SIZE - 43); defer delete(max_payload)
	max_size_tx := Shard_Transaction {
		workspace = {1},
		mutations = []Shard_Mutation{{domain = .Task, op = 1, entity_record_version = 1, payload = max_payload}},
	}
	exact_size, exact_err := shard_transaction_size(&max_size_tx)
	testing.expect_value(t, exact_err, Shard_Transaction_Error.None)
	testing.expect_value(t, exact_size, SHARD_TRANSACTION_MAX_SIZE)
	exact_buf := make([]byte, exact_size); defer delete(exact_buf)
	testing.expect_value(t, encode_shard_transaction(&max_size_tx, exact_buf), Shard_Transaction_Error.None)
	_, exact_decode_err := decode_shard_transaction(exact_buf)
	testing.expect_value(t, exact_decode_err, Shard_Transaction_Error.None)
	first_exact_entry := 2 + len(max_size_tx.workspace) + 32
	endian.put_u32(exact_buf[first_exact_entry + 4:], .Big, u32(len(max_payload) + 1))
	_, aggregate_decode_err := decode_shard_transaction(exact_buf)
	testing.expect_value(t, aggregate_decode_err, Shard_Transaction_Error.Too_Large)

	too_large_payload := make([]byte, len(max_payload) + 1); defer delete(too_large_payload)
	max_size_tx.mutations[0].payload = too_large_payload
	_, aggregate_err := shard_transaction_size(&max_size_tx)
	testing.expect_value(t, aggregate_err, Shard_Transaction_Error.Too_Large)

	declared_mutations: [3]Shard_Mutation
	declared := shard_test_transaction(&declared_mutations)
	declared_size, _ := shard_transaction_size(&declared)
	declared_buf := make([]byte, declared_size); defer delete(declared_buf)
	_ = encode_shard_transaction(&declared, declared_buf)
	first_entry := 2 + len(declared.workspace) + 32
	endian.put_u32(declared_buf[first_entry + 4:], .Big, max(u32))
	_, declared_err := decode_shard_transaction(declared_buf)
	testing.expect_value(t, declared_err, Shard_Transaction_Error.Too_Large)
}

shard_transaction_roundtrip_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	workspace, workspace_err := hgl.draw_bytes(tc, 1, 64)
	if workspace_err == .Stop_Test do return hgl.abort()
	if workspace_err != nil do return hgl.interesting("draw workspace")
	defer delete(workspace)
	payload, payload_err := hgl.draw_bytes(tc, 0, 128)
	if payload_err == .Stop_Test do return hgl.abort()
	if payload_err != nil do return hgl.interesting("draw payload")
	defer delete(payload)
	combination, combination_err := hgl.draw_i64(tc, 0, 14)
	if combination_err == .Stop_Test do return hgl.abort()
	if combination_err != nil do return hgl.interesting("draw combination")

	mutations := [1]Shard_Mutation{}
	c := int(combination)
	if c < 4 {
		mutations[0] = {
			domain                = .Task,
			op                    = u8(c + 1),
			entity_record_version = 1,
			payload               = payload,
		}
	} else if c < 13 {
		asset := c - 4
		mutations[0] = {
			domain                = .Asset,
			op                    = u8(asset % 3 + 1),
			entity_record_version = u16(asset / 3 + 1),
			payload               = payload,
		}
	} else {
		mutations[0] = {
			domain                = .Edge,
			op                    = u8(c - 12),
			entity_record_version = 1,
			payload               = payload,
		}
	}
	tx := Shard_Transaction {
		workspace        = workspace,
		task_high_water  = 11,
		asset_high_water = 22,
		edge_high_water  = 33,
		mutations        = mutations[:],
	}
	size, size_err := shard_transaction_size(&tx)
	if size_err != .None do return hgl.interesting("size")
	buf := make([]byte, size); defer delete(buf)
	if encode_shard_transaction(&tx, buf) != .None do return hgl.interesting("encode")
	view, decode_err := decode_shard_transaction(buf)
	if decode_err != .None || !bytes.equal(view.workspace, workspace) || view.task_high_water != 11 || view.asset_high_water != 22 || view.edge_high_water != 33 do return hgl.interesting("decode")
	ctx := Shard_Test_Visit_Context {
		expected  = mutations[:],
		reject_at = -1,
		valid     = true,
	}
	if !visit_shard_transaction_mutations(&view, shard_test_visit, &ctx) || !ctx.valid || ctx.seen != 1 do return hgl.interesting("visit")
	return hgl.valid()
}

shard_transaction_arbitrary_decode_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	data, draw_err := hgl.draw_bytes(tc, 0, 256)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw bytes")
	defer delete(data)
	view, err := decode_shard_transaction(data)
	callbacks := Shard_Test_Visit_Context {
		reject_at = -1,
		valid     = true,
	}
	if err == .None {
		// Arbitrary accepted bytes are safe to traverse only after full decode.
		_ = visit_shard_transaction_mutations(&view, shard_test_visit, &callbacks)
	} else if callbacks.seen != 0 {
		return hgl.interesting("callback before complete validation")
	}
	return hgl.valid()
}

@(test)
test_hegel_shard_transaction_codec :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	roundtrip, roundtrip_err := hgl.run(shard_transaction_roundtrip_property, nil, {test_cases = 200, database_key = "shard-transaction-roundtrip"})
	testing.expectf(t, roundtrip_err == nil, "shard roundtrip property failed: err=%v interesting=%v", roundtrip_err, roundtrip.interesting_test_cases)
	arbitrary, arbitrary_err := hgl.run(
		shard_transaction_arbitrary_decode_property,
		nil,
		{test_cases = 500, database_key = "shard-transaction-arbitrary-decode"},
	)
	testing.expectf(t, arbitrary_err == nil, "shard arbitrary decode property failed: err=%v interesting=%v", arbitrary_err, arbitrary.interesting_test_cases)
}
