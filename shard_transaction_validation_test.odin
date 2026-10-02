package main

import "core:encoding/endian"
import "core:testing"

import hgl "hegel"
import pr "protocol"

shard_test_delete_body :: proc(buf: []byte, conv_id, id: u64) {
	endian.put_u64(buf, .Big, conv_id)
	endian.put_u64(buf[8:], .Big, id)
}

shard_test_put_u16_bytes :: proc(buf: []byte, offset: ^int, value: []byte) {
	endian.put_u16(buf[offset^:], .Big, u16(len(value)))
	offset^ += 2
	copy(buf[offset^:], value)
	offset^ += len(value)
}

shard_test_asset_body :: proc(buf: []byte, version: u16, id: u64, parent_type: pr.ParentType, parent_id: u64, encoding: pr.PayloadEncoding = .Plain) -> int {
	o := 0
	endian.put_u16(buf[o:], .Big, 99); o += 2 // AssetType is intentionally opaque to migration.
	endian.put_u64(buf[o:], .Big, id); o += 8
	endian.put_u16(buf[o:], .Big, u16(parent_type)); o += 2
	endian.put_u64(buf[o:], .Big, parent_id); o += 8
	shard_test_put_u16_bytes(buf, &o, transmute([]byte)string("owner"))
	endian.put_u64(buf[o:], .Big, 10); o += 8
	endian.put_u64(buf[o:], .Big, 11); o += 8
	endian.put_u64(buf[o:], .Big, 12); o += 8
	if version >= 2 {
		buf[o] = u8(encoding); o += 1
		endian.put_u32(buf[o:], .Big, 0); o += 4
	}
	shard_test_put_u16_bytes(buf, &o, nil)
	shard_test_put_u16_bytes(buf, &o, nil)
	if version == 3 {
		endian.put_u16(buf[o:], .Big, 0); o += 2
	}
	return o
}

shard_test_edge_body :: proc(
	buf: []byte,
	id: u64,
	source_type: pr.TargetType,
	source_id: u64,
	target_type: pr.TargetType,
	target_id: u64,
	relation: u16 = 1,
) -> int {
	o := 0
	endian.put_u64(buf[o:], .Big, id); o += 8
	endian.put_u64(buf[o:], .Big, 7); o += 8
	endian.put_u16(buf[o:], .Big, u16(source_type)); o += 2
	endian.put_u64(buf[o:], .Big, source_id); o += 8
	endian.put_u16(buf[o:], .Big, u16(target_type)); o += 2
	endian.put_u64(buf[o:], .Big, target_id); o += 8
	endian.put_u16(buf[o:], .Big, relation); o += 2
	endian.put_u64(buf[o:], .Big, 8); o += 8
	shard_test_put_u16_bytes(buf, &o, transmute([]byte)string("user"))
	return o
}

shard_test_attachment_body :: proc(buf: []byte) -> int {
	o := 0
	endian.put_u16(buf[o:], .Big, 1); o += 2
	shard_test_put_u16_bytes(buf, &o, transmute([]byte)string("id"))
	shard_test_put_u16_bytes(buf, &o, transmute([]byte)string("name"))
	endian.put_u64(buf[o:], .Big, 123); o += 8
	shard_test_put_u16_bytes(buf, &o, transmute([]byte)string("type"))
	endian.put_u64(buf[o:], .Big, 456); o += 8
	return o
}

@(test)
test_shard_semantic_task_operations_references_and_field_order :: proc(t: ^testing.T) {
	body: [64]byte
	// Reference before primary proves requirement aggregation is tag-order independent.
	o := write_field_u64(body[:], .BlockedBy, 55)
	o += write_field_u64(body[o:], .TaskID, 12)
	o += write_field_u64(body[o:], .ConvID, 7)
	for op in 1 ..= 3 {
		req, err := validate_shard_mutation({domain = .Task, op = u8(op), entity_record_version = 1, payload = body[:o]})
		testing.expect_value(t, err, Shard_Transaction_Error.None)
		testing.expect_value(t, req.task, u64(55))
	}

	zero_primary := body
	endian.put_u64(zero_primary[14:], .Big, 0)
	_, zero_err := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = zero_primary[:o]})
	testing.expect_value(t, zero_err, Shard_Transaction_Error.Malformed)
}

@(test)
test_shard_semantic_task_rejects_ambiguous_or_incomplete_fields :: proc(t: ^testing.T) {
	body: [64]byte
	task_end := write_field_u64(body[:], .TaskID, 12)
	conv_end := task_end + write_field_u64(body[task_end:], .ConvID, 7)

	_, missing_conv := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = body[:task_end]})
	testing.expect_value(t, missing_conv, Shard_Transaction_Error.Malformed)
	_, missing_task := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = body[task_end:conv_end]})
	testing.expect_value(t, missing_task, Shard_Transaction_Error.Malformed)

	duplicate_end := conv_end + write_field_u64(body[conv_end:], .TaskID, 13)
	_, duplicate := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = body[:duplicate_end]})
	testing.expect_value(t, duplicate, Shard_Transaction_Error.Malformed)

	unknown := body
	unknown[0] = 99
	_, unknown_err := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = unknown[:conv_end]})
	testing.expect_value(t, unknown_err, Shard_Transaction_Error.Unsupported)

	wrong_width := body
	endian.put_u16(wrong_width[1:], .Big, 7)
	_, width_err := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = wrong_width[:conv_end]})
	testing.expect_value(t, width_err, Shard_Transaction_Error.Malformed)
	_, truncated := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = body[:conv_end - 1]})
	testing.expect_value(t, truncated, Shard_Transaction_Error.Malformed)
	one_trailing := body
	one_trailing[conv_end] = 1
	_, trailing := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = one_trailing[:conv_end + 1]})
	testing.expect_value(t, trailing, Shard_Transaction_Error.Malformed)
}

@(test)
test_shard_semantic_attachment_codec_is_exact_and_bounded :: proc(t: ^testing.T) {
	body: [128]byte
	o := shard_test_attachment_body(body[:])
	testing.expect(t, validate_shard_attachment_codec(body[:o]))
	for n in 0 ..< o do testing.expect(t, !validate_shard_attachment_codec(body[:n]))
	body[o] = 0
	testing.expect(t, !validate_shard_attachment_codec(body[:o + 1]))

	too_many := [2]byte{}
	endian.put_u16(too_many[:], .Big, pr.MAX_ATTACHMENTS_PER_TASK + 1)
	testing.expect(t, !validate_shard_attachment_codec(too_many[:]))

	oversized_file_id: [2 + 2 + pr.MAX_FILE_ID_LENGTH + 1]byte
	endian.put_u16(oversized_file_id[:], .Big, 1)
	endian.put_u16(oversized_file_id[2:], .Big, pr.MAX_FILE_ID_LENGTH + 1)
	testing.expect(t, !validate_shard_attachment_codec(oversized_file_id[:]))

	task: [256]byte
	task_end := write_field_u64(task[:], .TaskID, 1)
	task_end += write_field_u64(task[task_end:], .ConvID, 2)
	task[task_end] = u8(Task_Field_Tag.Attachments)
	endian.put_u16(task[task_end + 1:], .Big, u16(o))
	copy(task[task_end + 3:], body[:o])
	task_end += 3 + o
	_, task_err := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = task[:task_end]})
	testing.expect_value(t, task_err, Shard_Transaction_Error.None)
	endian.put_u16(task[task_end - o:], .Big, 2)
	_, task_attachment_err := validate_shard_mutation({domain = .Task, op = 1, entity_record_version = 1, payload = task[:task_end]})
	testing.expect_value(t, task_attachment_err, Shard_Transaction_Error.Malformed)
}

@(test)
test_shard_semantic_asset_versions_and_parent_references :: proc(t: ^testing.T) {
	for version in 1 ..= 3 {
		for op in 1 ..= 2 {
			body: [128]byte
			o := shard_test_asset_body(body[:], u16(version), 20, .Task, 91)
			req, err := validate_shard_mutation({domain = .Asset, op = u8(op), entity_record_version = u16(version), payload = body[:o]})
			testing.expect_value(t, err, Shard_Transaction_Error.None)
			testing.expect_value(t, req.asset, u64(20))
			testing.expect_value(t, req.task, u64(91))
		}
	}
	body: [128]byte
	o := shard_test_asset_body(body[:], 3, 20, .Asset, 92, .Zstd)
	req, err := validate_shard_mutation({domain = .Asset, op = 1, entity_record_version = 3, payload = body[:o]})
	testing.expect_value(t, err, Shard_Transaction_Error.None)
	testing.expect_value(t, req.asset, u64(92))
}

@(test)
test_shard_semantic_asset_rejects_unknown_and_nonexact_bodies :: proc(t: ^testing.T) {
	body: [128]byte
	o := shard_test_asset_body(body[:], 3, 20, .Task, 30)
	for n in 0 ..< o {
		_, err := validate_shard_mutation({domain = .Asset, op = 1, entity_record_version = 3, payload = body[:n]})
		testing.expect_value(t, err, Shard_Transaction_Error.Malformed)
	}
	body[o] = 0
	_, trailing := validate_shard_mutation({domain = .Asset, op = 1, entity_record_version = 3, payload = body[:o + 1]})
	testing.expect_value(t, trailing, Shard_Transaction_Error.Malformed)

	unknown_parent := body
	endian.put_u16(unknown_parent[10:], .Big, 99)
	_, parent_err := validate_shard_mutation({domain = .Asset, op = 1, entity_record_version = 3, payload = unknown_parent[:o]})
	testing.expect_value(t, parent_err, Shard_Transaction_Error.Unsupported)

	v2: [128]byte
	v2_end := shard_test_asset_body(v2[:], 2, 20, .None, 0)
	v2[51] = 99 // Encoding follows fixed fields and five-byte owner in this fixture.
	_, encoding_err := validate_shard_mutation({domain = .Asset, op = 1, entity_record_version = 2, payload = v2[:v2_end]})
	testing.expect_value(t, encoding_err, Shard_Transaction_Error.Unsupported)

	v3_bad_attachments := body
	endian.put_u16(v3_bad_attachments[o - 2:], .Big, 1)
	_, attachments_err := validate_shard_mutation({domain = .Asset, op = 1, entity_record_version = 3, payload = v3_bad_attachments[:o]})
	testing.expect_value(t, attachments_err, Shard_Transaction_Error.Malformed)
}

@(test)
test_shard_semantic_edge_create_references_and_strictness :: proc(t: ^testing.T) {
	body: [96]byte
	o := shard_test_edge_body(body[:], 30, .Task, 100, .Asset, 200)
	req, err := validate_shard_mutation({domain = .Edge, op = 1, entity_record_version = 1, payload = body[:o]})
	testing.expect_value(t, err, Shard_Transaction_Error.None)
	testing.expect_value(t, req.edge, u64(30))
	testing.expect_value(t, req.task, u64(100))
	testing.expect_value(t, req.asset, u64(200))
	for n in 0 ..< o {
		_, trunc_err := validate_shard_mutation({domain = .Edge, op = 1, entity_record_version = 1, payload = body[:n]})
		testing.expect_value(t, trunc_err, Shard_Transaction_Error.Malformed)
	}
	body[o] = 0
	_, trailing := validate_shard_mutation({domain = .Edge, op = 1, entity_record_version = 1, payload = body[:o + 1]})
	testing.expect_value(t, trailing, Shard_Transaction_Error.Malformed)

	unknown_type := body
	endian.put_u16(unknown_type[16:], .Big, 99)
	_, type_err := validate_shard_mutation({domain = .Edge, op = 1, entity_record_version = 1, payload = unknown_type[:o]})
	testing.expect_value(t, type_err, Shard_Transaction_Error.Unsupported)

	// Every relation the protocol names is a valid edge, including the slice
	// membership relation, so the bound follows the enum rather than a fixed
	// number that would silently reject a new relation.
	for relation in 1 ..= int(max(pr.RelationType)) {
		named := body
		endian.put_u16(named[36:], .Big, u16(relation))
		_, named_err := validate_shard_mutation({domain = .Edge, op = 1, entity_record_version = 1, payload = named[:o]})
		testing.expect_value(t, named_err, Shard_Transaction_Error.None)
	}

	unknown_relation := body
	endian.put_u16(unknown_relation[36:], .Big, u16(max(pr.RelationType)) + 1)
	_, relation_err := validate_shard_mutation({domain = .Edge, op = 1, entity_record_version = 1, payload = unknown_relation[:o]})
	testing.expect_value(t, relation_err, Shard_Transaction_Error.Unsupported)
}

@(test)
test_shard_semantic_deletes_all_domains_are_exact_and_nonzero :: proc(t: ^testing.T) {
	body: [17]byte
	shard_test_delete_body(body[:16], 2, 77)
	domains := [3]Shard_Mutation_Domain{.Task, .Asset, .Edge}
	ops := [3]u8{4, 3, 2}
	for i in 0 ..< 3 {
		req, err := validate_shard_mutation({domain = domains[i], op = ops[i], entity_record_version = 1, payload = body[:16]})
		testing.expect_value(t, err, Shard_Transaction_Error.None)
		switch domains[i] {
		case .Task:
			testing.expect_value(t, req.task, u64(77))
		case .Asset:
			testing.expect_value(t, req.asset, u64(77))
		case .Edge:
			testing.expect_value(t, req.edge, u64(77))
		}
		_, trailing := validate_shard_mutation({domain = domains[i], op = ops[i], entity_record_version = 1, payload = body[:]})
		testing.expect_value(t, trailing, Shard_Transaction_Error.Malformed)
	}
	endian.put_u64(body[8:], .Big, 0)
	_, zero := validate_shard_mutation({domain = .Edge, op = 2, entity_record_version = 1, payload = body[:16]})
	testing.expect_value(t, zero, Shard_Transaction_Error.Malformed)
}

@(test)
test_shard_semantic_transaction_validates_requirements_and_regression :: proc(t: ^testing.T) {
	task_body: [64]byte
	task_end := write_field_u64(task_body[:], .TaskID, 10)
	task_end += write_field_u64(task_body[task_end:], .ConvID, 1)
	task_end += write_field_u64(task_body[task_end:], .BlockedBy, 100)
	asset_body: [128]byte
	asset_end := shard_test_asset_body(asset_body[:], 3, 20, .Asset, 200)
	edge_body: [96]byte
	edge_end := shard_test_edge_body(edge_body[:], 30, .Task, 300, .Asset, 400)
	mutations := [3]Shard_Mutation {
		{domain = .Task, op = 1, entity_record_version = 1, payload = task_body[:task_end]},
		{domain = .Asset, op = 1, entity_record_version = 3, payload = asset_body[:asset_end]},
		{domain = .Edge, op = 1, entity_record_version = 1, payload = edge_body[:edge_end]},
	}
	tx := Shard_Transaction {
		workspace        = transmute([]byte)string("ws"),
		task_high_water  = 300,
		asset_high_water = 400,
		edge_high_water  = 30,
		mutations        = mutations[:],
	}
	size, size_err := shard_transaction_size(&tx)
	testing.expect_value(t, size_err, Shard_Transaction_Error.None)
	encoded := make([]byte, size); defer delete(encoded)
	testing.expect_value(t, encode_shard_transaction(&tx, encoded), Shard_Transaction_Error.None)
	view, decode_err := decode_shard_transaction(encoded)
	testing.expect_value(t, decode_err, Shard_Transaction_Error.None)
	next, err := validate_shard_transaction_view(&view, {task = 299, asset = 399, edge = 29})
	testing.expect_value(t, err, Shard_Transaction_Error.None)
	testing.expect_value(t, next, Shard_High_Water_Requirements{task = 300, asset = 400, edge = 30})

	for domain in 0 ..< 3 {
		bad := view
		switch domain {
		case 0:
			bad.task_high_water = 299
		case 1:
			bad.asset_high_water = 399
		case 2:
			bad.edge_high_water = 29
		}
		failed_next, low := validate_shard_transaction_view(&bad, {})
		testing.expect_value(t, low, Shard_Transaction_Error.Malformed)
		testing.expect_value(t, failed_next, Shard_High_Water_Requirements{})
	}
	regressed_next, regression := validate_shard_transaction_view(&view, {task = 301})
	testing.expect_value(t, regression, Shard_Transaction_Error.Malformed)
	testing.expect_value(t, regressed_next, Shard_High_Water_Requirements{})

	// The envelope is structurally valid, but Task Create lacks the required ConvID.
	incomplete_task_body: [11]byte
	incomplete_end := write_field_u64(incomplete_task_body[:], .TaskID, 10)
	incomplete_mutations := [1]Shard_Mutation{{domain = .Task, op = 1, entity_record_version = 1, payload = incomplete_task_body[:incomplete_end]}}
	incomplete_tx := Shard_Transaction {
		workspace       = transmute([]byte)string("ws"),
		task_high_water = 10,
		mutations       = incomplete_mutations[:],
	}
	incomplete_size, incomplete_size_err := shard_transaction_size(&incomplete_tx)
	testing.expect_value(t, incomplete_size_err, Shard_Transaction_Error.None)
	incomplete_encoded := make([]byte, incomplete_size); defer delete(incomplete_encoded)
	testing.expect_value(t, encode_shard_transaction(&incomplete_tx, incomplete_encoded), Shard_Transaction_Error.None)
	incomplete_view, incomplete_decode_err := decode_shard_transaction(incomplete_encoded)
	testing.expect_value(t, incomplete_decode_err, Shard_Transaction_Error.None)
	incomplete_next, incomplete_err := validate_shard_transaction_view(&incomplete_view, {})
	testing.expect_value(t, incomplete_err, Shard_Transaction_Error.Malformed)
	testing.expect_value(t, incomplete_next, Shard_High_Water_Requirements{})

	watermark := Shard_Transaction_View {
		task_high_water  = 301,
		asset_high_water = 401,
		edge_high_water  = 31,
	}
	watermark_next, watermark_err := validate_shard_transaction_view(&watermark, {task = 300, asset = 400, edge = 30})
	testing.expect_value(t, watermark_err, Shard_Transaction_Error.None)
	testing.expect_value(t, watermark_next.task, u64(301))
}

shard_semantic_arbitrary_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	body, body_err := hgl.draw_bytes(tc, 0, 256)
	if body_err == .Stop_Test do return hgl.abort()
	if body_err != nil do return hgl.interesting("draw body")
	defer delete(body)
	domain, domain_err := hgl.draw_i64(tc, 1, 3)
	if domain_err == .Stop_Test do return hgl.abort()
	if domain_err != nil do return hgl.interesting("draw domain")
	op, op_err := hgl.draw_i64(tc, 0, 5)
	if op_err == .Stop_Test do return hgl.abort()
	if op_err != nil do return hgl.interesting("draw op")
	version, version_err := hgl.draw_i64(tc, 0, 4)
	if version_err == .Stop_Test do return hgl.abort()
	if version_err != nil do return hgl.interesting("draw version")
	_, _ = validate_shard_mutation({domain = Shard_Mutation_Domain(domain), op = u8(op), entity_record_version = u16(version), payload = body})
	return hgl.valid()
}

shard_semantic_delete_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	domain_raw, domain_err := hgl.draw_i64(tc, 1, 3)
	if domain_err == .Stop_Test do return hgl.abort()
	if domain_err != nil do return hgl.interesting("draw domain")
	id_raw, id_err := hgl.draw_i64(tc, 1, max(i64))
	if id_err == .Stop_Test do return hgl.abort()
	if id_err != nil do return hgl.interesting("draw id")
	domain := Shard_Mutation_Domain(domain_raw)
	ops := [3]u8{4, 3, 2}
	body: [16]byte
	shard_test_delete_body(body[:], 1, u64(id_raw))
	req, err := validate_shard_mutation({domain = domain, op = ops[int(domain_raw) - 1], entity_record_version = 1, payload = body[:]})
	if err != .None do return hgl.interesting("valid delete rejected")
	derived := req.task
	if domain == .Asset do derived = req.asset
	if domain == .Edge do derived = req.edge
	if derived != u64(id_raw) do return hgl.interesting("wrong delete requirement")
	return hgl.valid()
}

@(test)
test_hegel_shard_semantic_validation :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	arbitrary, arbitrary_err := hgl.run(shard_semantic_arbitrary_property, nil, {test_cases = 500, database_key = "shard-semantic-arbitrary"})
	testing.expectf(t, arbitrary_err == nil, "semantic arbitrary property failed: err=%v interesting=%v", arbitrary_err, arbitrary.interesting_test_cases)
	deletes, deletes_err := hgl.run(shard_semantic_delete_property, nil, {test_cases = 300, database_key = "shard-semantic-delete"})
	testing.expectf(t, deletes_err == nil, "semantic delete property failed: err=%v interesting=%v", deletes_err, deletes.interesting_test_cases)
}
