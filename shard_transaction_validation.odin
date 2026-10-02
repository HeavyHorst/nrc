package main

import "core:encoding/endian"
import pr "protocol"

Shard_High_Water_Requirements :: struct {
	task:  u64,
	asset: u64,
	edge:  u64,
}

shard_max_requirement :: proc(dst: ^u64, value: u64) {
	if value > dst^ do dst^ = value
}

shard_merge_requirements :: proc(dst: ^Shard_High_Water_Requirements, src: Shard_High_Water_Requirements) {
	shard_max_requirement(&dst.task, src.task)
	shard_max_requirement(&dst.asset, src.asset)
	shard_max_requirement(&dst.edge, src.edge)
}

shard_mutation_entity_id :: proc(m: Shard_Mutation) -> (id: u64, ok: bool) {
	switch m.domain {
	case .Task:
		if m.op == u8(Task_Log_Op.Delete) {
			if len(m.payload) != 16 do return
			id, _ = endian.get_u64(m.payload[8:], .Big)
			return id, id != 0
		}
		o := 0
		for o < len(m.payload) {
			if len(m.payload) - o < 3 do return 0, false
			tag := m.payload[o]
			n, _ := endian.get_u16(m.payload[o + 1:], .Big)
			o += 3
			if int(n) > len(m.payload) - o do return 0, false
			if tag == u8(Task_Field_Tag.TaskID) {
				if n != 8 do return 0, false
				id, _ = endian.get_u64(m.payload[o:], .Big)
				return id, id != 0
			}
			o += int(n)
		}
	case .Asset:
		if m.op == u8(Asset_Log_Op.Delete) {
			if len(m.payload) != 16 do return
			id, _ = endian.get_u64(m.payload[8:], .Big)
		} else {
			if len(m.payload) < 10 do return
			id, _ = endian.get_u64(m.payload[2:], .Big)
		}
		return id, id != 0
	case .Edge:
		if m.op == u8(Edge_Log_Op.Delete) {
			if len(m.payload) != 16 do return
			id, _ = endian.get_u64(m.payload[8:], .Big)
		} else {
			if len(m.payload) < 8 do return
			id, _ = endian.get_u64(m.payload, .Big)
		}
		return id, id != 0
	}
	return 0, false
}

shard_read_u16_bytes :: proc(data: []byte, offset: ^int) -> (value: []byte, ok: bool) {
	if len(data) - offset^ < 2 do return nil, false
	n, _ := endian.get_u16(data[offset^:], .Big)
	offset^ += 2
	if int(n) > len(data) - offset^ do return nil, false
	value = data[offset^:offset^ + int(n)]
	offset^ += int(n)
	return value, true
}

validate_shard_attachment_codec :: proc(data: []byte) -> bool {
	if len(data) < 2 do return false
	count, _ := endian.get_u16(data, .Big)
	if count > pr.MAX_ATTACHMENTS_PER_TASK do return false
	o := 2
	for _ in 0 ..< int(count) {
		file_id, ok := shard_read_u16_bytes(data, &o); if !ok || len(file_id) > pr.MAX_FILE_ID_LENGTH do return false
		filename: []byte
		filename, ok = shard_read_u16_bytes(data, &o); if !ok || len(filename) > pr.MAX_FILENAME_LENGTH do return false
		if len(data) - o < 8 do return false
		o += 8
		mime: []byte
		mime, ok = shard_read_u16_bytes(data, &o); if !ok || len(mime) > pr.MAX_MIME_TYPE_LENGTH do return false
		if len(data) - o < 8 do return false
		o += 8
	}
	return o == len(data)
}

validate_shard_task_body :: proc(m: Shard_Mutation) -> (req: Shard_High_Water_Requirements, err: Shard_Transaction_Error) {
	if m.entity_record_version != 1 do return req, .Unsupported
	if m.op == u8(Task_Log_Op.Delete) {
		if len(m.payload) != 16 do return req, .Malformed
		id, _ := endian.get_u64(m.payload[8:], .Big)
		if id == 0 do return req, .Malformed
		req.task = id
		return req, .None
	}
	if m.op < 1 || m.op > 3 do return req, .Unsupported
	seen: u32
	has_task, has_conv := false, false
	primary_id: u64
	o := 0
	for o < len(m.payload) {
		if len(m.payload) - o < 3 do return req, .Malformed
		tag := m.payload[o]
		n, _ := endian.get_u16(m.payload[o + 1:], .Big)
		o += 3
		if int(n) > len(m.payload) - o do return req, .Malformed
		field := m.payload[o:o + int(n)]; o += int(n)
		if tag < 1 || tag > 19 do return req, .Unsupported
		bit := u32(1) << (tag - 1)
		if seen & bit != 0 do return req, .Malformed
		seen |= bit
		#partial switch Task_Field_Tag(tag) {
		case .TaskID, .ConvID, .CreatedAt, .UpdatedAt, .DueAt, .BlockedBy, .CompletedAt:
			if len(field) != 8 do return req, .Malformed
			value, _ := endian.get_u64(field, .Big)
			if tag == u8(Task_Field_Tag.TaskID) {has_task = true; primary_id = value; shard_max_requirement(&req.task, value)}
			if tag == u8(Task_Field_Tag.ConvID) do has_conv = true
			if tag == u8(Task_Field_Tag.BlockedBy) do shard_max_requirement(&req.task, value)
		case .OrderIndex:
			if len(field) != 2 do return req, .Malformed
		case .Status, .Priority, .Color:
			if len(field) != 1 do return req, .Malformed
		case .Attachments:
			if !validate_shard_attachment_codec(field) do return req, .Malformed
		case:
		}
	}
	if !has_task || !has_conv || primary_id == 0 do return req, .Malformed
	return req, .None
}

validate_shard_asset_body :: proc(m: Shard_Mutation) -> (req: Shard_High_Water_Requirements, err: Shard_Transaction_Error) {
	if m.entity_record_version < 1 || m.entity_record_version > 3 do return req, .Unsupported
	if m.op == u8(Asset_Log_Op.Delete) {
		if len(m.payload) != 16 do return req, .Malformed
		id, _ := endian.get_u64(m.payload[8:], .Big); if id == 0 do return req, .Malformed
		req.asset = id; return req, .None
	}
	if m.op != 1 && m.op != 2 do return req, .Unsupported
	o := 0
	if len(m.payload) < 20 do return req, .Malformed
	asset_type_raw, _ := endian.get_u16(m.payload[o:], .Big); o += 2
	asset_type := pr.AssetType(asset_type_raw)
	id, _ := endian.get_u64(m.payload[o:], .Big); o += 8
	if id == 0 do return req, .Malformed
	req.asset = id
	parent, _ := endian.get_u16(m.payload[o:], .Big); o += 2
	parent_id, _ := endian.get_u64(m.payload[o:], .Big); o += 8
	switch pr.ParentType(parent) {
	case .None:
	case .Task:
		req.task = parent_id
	case .Asset:
		shard_max_requirement(&req.asset, parent_id)
	case:
		return req, .Unsupported
	}
	_, ok := shard_read_u16_bytes(m.payload, &o); if !ok || len(m.payload) - o < 24 do return req, .Malformed
	o += 24
	encoding := pr.PayloadEncoding.Plain
	raw_len: u32
	if m.entity_record_version >= 2 {
		if len(m.payload) - o < 5 do return req, .Malformed
		encoding = pr.PayloadEncoding(m.payload[o]); o += 1
		raw_len, _ = endian.get_u32(m.payload[o:], .Big); o += 4
		if encoding != .Plain && encoding != .Zstd do return req, .Unsupported
	}
	preview, preview_ok := shard_read_u16_bytes(m.payload, &o); if !preview_ok do return req, .Malformed
	payload, payload_ok := shard_read_u16_bytes(m.payload, &o); if !payload_ok do return req, .Malformed
	if !validate_appointment_asset(asset_type, encoding, raw_len, preview, payload, context.temp_allocator) do return req, .Malformed
	if m.entity_record_version == 3 {
		if !validate_shard_attachment_codec(m.payload[o:]) do return req, .Malformed
		o = len(m.payload)
	}
	if o != len(m.payload) do return req, .Malformed
	return req, .None
}

validate_shard_edge_body :: proc(m: Shard_Mutation) -> (req: Shard_High_Water_Requirements, err: Shard_Transaction_Error) {
	if m.entity_record_version != 1 do return req, .Unsupported
	if m.op == u8(Edge_Log_Op.Delete) {
		if len(m.payload) != 16 do return req, .Malformed
		id, _ := endian.get_u64(m.payload[8:], .Big); if id == 0 do return req, .Malformed
		req.edge = id; return req, .None
	}
	if m.op != 1 do return req, .Unsupported
	if len(m.payload) < 48 do return req, .Malformed
	o := 0
	id, _ := endian.get_u64(m.payload, .Big); o += 16
	if id == 0 do return req, .Malformed
	req.edge = id
	for _ in 0 ..< 2 {
		typ, _ := endian.get_u16(m.payload[o:], .Big); o += 2
		ref, _ := endian.get_u64(m.payload[o:], .Big); o += 8
		switch pr.TargetType(typ) {
		case .Task:
			shard_max_requirement(&req.task, ref)
		case .Asset:
			shard_max_requirement(&req.asset, ref)
		case:
			return req, .Unsupported
		}
	}
	relation, _ := endian.get_u16(m.payload[o:], .Big); o += 2
	if relation < u16(min(pr.RelationType)) || relation > u16(max(pr.RelationType)) do return req, .Unsupported
	o += 8
	_, ok := shard_read_u16_bytes(m.payload, &o); if !ok || o != len(m.payload) do return req, .Malformed
	return req, .None
}

validate_shard_mutation :: proc(m: Shard_Mutation) -> (req: Shard_High_Water_Requirements, err: Shard_Transaction_Error) {
	if len(m.payload) > SHARD_TRANSACTION_MAX_SIZE do return req, .Too_Large
	if !shard_mutation_supported(m.domain, m.op, m.entity_record_version) do return req, .Unsupported
	switch m.domain {
	case .Task:
		return validate_shard_task_body(m)
	case .Asset:
		return validate_shard_asset_body(m)
	case .Edge:
		return validate_shard_edge_body(m)
	}
	return req, .Unsupported
}

Shard_Validation_Context :: struct {
	requirements: Shard_High_Water_Requirements,
	err:          Shard_Transaction_Error,
}

shard_validation_visit :: proc(m: Shard_Mutation, data: rawptr) -> bool {
	ctx := cast(^Shard_Validation_Context)data
	r, err := validate_shard_mutation(m)
	if err != .None {ctx.err = err; return false}
	shard_max_requirement(&ctx.requirements.task, r.task)
	shard_max_requirement(&ctx.requirements.asset, r.asset)
	shard_max_requirement(&ctx.requirements.edge, r.edge)
	return true
}

validate_shard_transaction_view :: proc(
	view: ^Shard_Transaction_View,
	previous: Shard_High_Water_Requirements,
) -> (
	next: Shard_High_Water_Requirements,
	err: Shard_Transaction_Error,
) {
	ctx := Shard_Validation_Context{}
	if !visit_shard_transaction_mutations(view, shard_validation_visit, &ctx) do return next, ctx.err
	next = {
		task  = view.task_high_water,
		asset = view.asset_high_water,
		edge  = view.edge_high_water,
	}
	if next.task < previous.task || next.asset < previous.asset || next.edge < previous.edge do return Shard_High_Water_Requirements{}, .Malformed
	if next.task < ctx.requirements.task || next.asset < ctx.requirements.asset || next.edge < ctx.requirements.edge do return Shard_High_Water_Requirements{}, .Malformed
	return next, .None
}

validate_shard_transaction :: proc(
	tx: ^Shard_Transaction,
	previous: Shard_High_Water_Requirements,
) -> (
	next: Shard_High_Water_Requirements,
	err: Shard_Transaction_Error,
) {
	if tx == nil do return next, .Malformed
	if _, size_err := shard_transaction_size(tx); size_err != .None do return next, size_err
	requirements: Shard_High_Water_Requirements
	for mutation in tx.mutations {
		mutation_requirements, mutation_err := validate_shard_mutation(mutation)
		if mutation_err != .None do return Shard_High_Water_Requirements{}, mutation_err
		shard_merge_requirements(&requirements, mutation_requirements)
	}
	next = {
		task  = tx.task_high_water,
		asset = tx.asset_high_water,
		edge  = tx.edge_high_water,
	}
	if next.task < previous.task || next.asset < previous.asset || next.edge < previous.edge do return Shard_High_Water_Requirements{}, .Malformed
	if next.task < requirements.task || next.asset < requirements.asset || next.edge < requirements.edge do return Shard_High_Water_Requirements{}, .Malformed
	return next, .None
}
