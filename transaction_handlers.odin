package main

import "core:encoding/endian"
import "core:log"
import "core:net"
import "core:slice"

import "btree"
import "byte_pool"
import pr "protocol"

Transaction_Prepared :: struct {
	results:                       [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionOperationResult,
	operation_ty:                  [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionOperationType,
	entity:                        [pr.MAX_TRANSACTION_OPERATIONS]rawptr,
	entity_ty:                     [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionEntityType,
	conv_ids:                      [pr.MAX_TRANSACTION_OPERATIONS]pr.ConversationID,
	mutations:                     [dynamic]Shard_Mutation,
	payloads:                      [dynamic][]byte,
	old:                           [pr.MAX_TRANSACTION_OPERATIONS]rawptr,
	delete_tasks:                  [dynamic]Transaction_Delete_Item,
	delete_assets:                 [dynamic]Transaction_Delete_Item,
	delete_edges:                  [dynamic]Transaction_Delete_Item,
	stages:                        [dynamic]Transaction_Conversation_Stage,
	unblocks:                      [dynamic]pr.Task,
	unblocked_operations:          [pr.MAX_TRANSACTION_OPERATIONS]bool,
	task_seq, asset_seq, edge_seq: u64,
}

Transaction_Conversation_Stage :: struct {
	conv_id: pr.ConversationID,
	staged:  ^Conversation_State,
}

Transaction_Delete_Item :: struct {
	conv_id: pr.ConversationID,
	id:      u64,
}

transaction_cleanup :: proc(p: ^Transaction_Prepared, committed := false) {
	if !committed {
		for stage in p.stages {
			transaction_destroy_staged_conversation(stage.staged)
		}
	}
	if !committed {
		for i in 0 ..< pr.MAX_TRANSACTION_OPERATIONS {
			if p.entity[i] == nil do continue
			switch p.entity_ty[i] {case .Task:
				free_task((^pr.Task)(p.entity[i])); case .Asset:
				free_asset((^pr.Asset)(p.entity[i])); case .Edge:
				free_edge((^pr.Edge)(p.entity[i]))}
		}
	}
	for payload in p.payloads do delete(payload)
	delete(p.payloads); delete(p.mutations)
	delete(p.delete_tasks); delete(p.delete_assets); delete(p.delete_edges)
	delete(p.stages)
	delete(p.unblocks)
}

transaction_destroy_domain_containers :: proc(conv: ^Conversation_State) {
	if conv == nil do return
	delete(conv.tasks)
	destroy_task_index(conv)
	delete(conv.assets)
	destroy_note_index(conv)
	delete(conv.edges)
	for _, ids in conv.edges_by_entity do delete(ids)
	delete(conv.edges_by_entity)
}

transaction_destroy_staged_conversation :: proc(conv: ^Conversation_State) {
	if conv == nil do return
	transaction_destroy_domain_containers(conv)
	destroy_subscriber_index(conv)
	free(conv)
}

transaction_stage_add :: proc(p: ^Transaction_Prepared, ws: ^Workspace_State, conv_id: pr.ConversationID) -> bool {
	for stage in p.stages do if stage.conv_id == conv_id do return true
	live := get_conversation(ws, conv_id)
	if live != nil do return true
	staged := new(Conversation_State)
	if staged == nil do return false
	init_subscriber_index(staged)
	staged.tasks = make(map[pr.TaskID]^pr.Task, 128)
	init_task_index(staged)
	staged.assets = make(map[pr.AssetID]^pr.Asset, 128)
	init_note_index(staged)
	staged.edges = make(map[pr.EdgeID]^pr.Edge, 64)
	staged.edges_by_entity = make(map[Edge_Entity_Key][dynamic]pr.EdgeID, 64)
	if _, err := append(&p.stages, Transaction_Conversation_Stage{conv_id = conv_id, staged = staged}); err != nil {
		transaction_destroy_staged_conversation(staged)
		return false
	}
	return true
}

transaction_projected_entity :: proc(p: ^Transaction_Prepared, typ: pr.TransactionEntityType, conv_id: pr.ConversationID, id: u64, live: rawptr) -> rawptr {
	for i in 0 ..< pr.MAX_TRANSACTION_OPERATIONS {
		if p.entity_ty[i] == typ && p.conv_ids[i] == conv_id && p.results[i].entity_id == id && p.entity[i] != nil do return p.entity[i]
	}
	return live
}

transaction_prepare_install :: proc(p: ^Transaction_Prepared, ws: ^Workspace_State, operations: []pr.TransactionOperation) -> bool {
	for _, i in operations do if !transaction_stage_add(p, ws, p.conv_ids[i]) do return false
	return true
}

transaction_resolve_id :: proc(
	p: ^Transaction_Prepared,
	ref: pr.TransactionReference,
	expected: pr.TransactionEntityType,
	conv_id: pr.ConversationID,
) -> (
	u64,
	bool,
) {
	if ref.entity_type != expected do return 0, false
	if ref.kind == .Existing do return ref.value, ref.value != 0
	i := int(ref.value)
	if i < 0 || i >= pr.MAX_TRANSACTION_OPERATIONS || p.entity_ty[i] != expected || p.conv_ids[i] != conv_id || p.results[i].entity_id == 0 {
		return 0, false
	}
	if (expected == .Task && p.operation_ty[i] != .TaskCreate) ||
	   (expected == .Asset && p.operation_ty[i] != .AssetCreate) ||
	   (expected == .Edge && p.operation_ty[i] != .EdgeCreate) {
		return 0, false
	}
	return p.results[i].entity_id, true
}

transaction_entity_exists :: proc(
	p: ^Transaction_Prepared,
	conv: ^Conversation_State,
	conv_id: pr.ConversationID,
	typ: pr.TransactionEntityType,
	id: u64,
) -> bool {
	for i in 0 ..< pr.MAX_TRANSACTION_OPERATIONS {
		if p.entity_ty[i] == typ && p.conv_ids[i] == conv_id && p.results[i].entity_id == id && p.entity[i] != nil {
			return true
		}
	}
	if conv == nil do return false
	switch typ {case .Task:
		return conv.tasks[pr.TaskID(id)] != nil; case .Asset:
		return conv.assets[pr.AssetID(id)] != nil; case .Edge:
		return conv.edges[pr.EdgeID(id)] != nil}
	return false
}

transaction_asset_parent_would_cycle :: proc(
	p: ^Transaction_Prepared,
	conv: ^Conversation_State,
	conv_id: pr.ConversationID,
	asset_id, parent_id: pr.AssetID,
) -> bool {
	current := parent_id
	for visited := 0; current != 0 && visited <= pr.MAX_TRANSACTION_OPERATIONS + (conv == nil ? 0 : len(conv.assets)); visited += 1 {
		if current == asset_id do return true
		parent_type := pr.ParentType.None
		next: u64
		for i in 0 ..< pr.MAX_TRANSACTION_OPERATIONS {
			if p.entity_ty[i] != .Asset || p.conv_ids[i] != conv_id || p.results[i].entity_id != u64(current) || p.entity[i] == nil do continue
			asset := (^pr.Asset)(p.entity[i])
			parent_type, next = asset.parent_type, asset.parent_id
			break
		}
		if parent_type == .None && conv != nil {
			if asset := conv.assets[current]; asset != nil {
				parent_type, next = asset.parent_type, asset.parent_id
			}
		}
		if parent_type != .Asset do return false
		current = pr.AssetID(next)
	}
	return current != 0
}

transaction_add_mutation :: proc(p: ^Transaction_Prepared, domain: Shard_Mutation_Domain, op: u8, version: u16, payload: []byte) -> bool {
	payload_copy := make([]byte, len(payload)); copy(payload_copy, payload)
	if _, err := append(&p.payloads, payload_copy); err != nil {delete(payload_copy); return false}
	_, err := append(&p.mutations, Shard_Mutation{domain = domain, op = op, entity_record_version = version, payload = payload_copy})
	return err == nil
}

transaction_add_task_mutation :: proc(p: ^Transaction_Prepared, i: int, task: ^pr.Task, op: Task_Log_Op) -> bool {
	buf := make(
		[]byte,
		calculate_task_fields_size(task^),
	); serialize_task_fields(task^, buf); ok := transaction_add_mutation(p, .Task, u8(op), 1, buf); delete(buf); return ok
}
transaction_add_asset_mutation :: proc(p: ^Transaction_Prepared, i: int, asset: ^pr.Asset, op: Asset_Log_Op) -> bool {
	buf := make(
		[]byte,
		calculate_asset_fields_size(asset),
	); serialize_asset_fields(buf, asset); ok := transaction_add_mutation(p, .Asset, u8(op), ASSET_LOG_VERSION, buf); delete(buf); return ok
}
transaction_add_edge_mutation :: proc(p: ^Transaction_Prepared, i: int, edge: ^pr.Edge) -> bool {
	built, ok := build_shard_edge_mutation(transmute([]byte)string("x"), .Create, edge, {}); if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return transaction_add_mutation(p, .Edge, u8(Edge_Log_Op.Create), 1, built.payload)
}

transaction_delete_contains :: proc(items: []Transaction_Delete_Item, conv_id: pr.ConversationID, id: u64) -> bool {
	for item in items do if item.conv_id == conv_id && item.id == id do return true
	return false
}

transaction_delete_add :: proc(items: ^[dynamic]Transaction_Delete_Item, conv_id: pr.ConversationID, id: u64) -> bool {
	if transaction_delete_contains(items^[:], conv_id, id) do return true
	_, err := append(items, Transaction_Delete_Item{conv_id = conv_id, id = id})
	return err == nil
}

transaction_add_delete_mutation :: proc(p: ^Transaction_Prepared, domain: Shard_Mutation_Domain, op: u8, item: Transaction_Delete_Item) -> bool {
	buf: [16]byte
	endian.put_u64(buf[:], .Big, u64(item.conv_id)); endian.put_u64(buf[8:], .Big, item.id)
	return transaction_add_mutation(p, domain, op, 1, buf[:])
}

transaction_delete_less :: proc(a, b: Transaction_Delete_Item) -> bool {
	return a.conv_id < b.conv_id || a.conv_id == b.conv_id && a.id < b.id
}

process_apply_transaction :: proc(c: ^NRC_Connection, req: pr.ApplyTransactionRequest) {
	p := Transaction_Prepared {
		task_seq  = td.task_seq,
		asset_seq = td.asset_seq,
		edge_seq  = td.edge_seq,
	}
	committed := false
	defer {transaction_cleanup(&p, committed)}
	p.mutations = make([dynamic]Shard_Mutation, 0, len(req.operations)); p.payloads = make([dynamic][]byte, 0, len(req.operations))
	p.delete_tasks = make(
		[dynamic]Transaction_Delete_Item,
		0,
		8,
	); p.delete_assets = make([dynamic]Transaction_Delete_Item, 0, 16); p.delete_edges = make([dynamic]Transaction_Delete_Item, 0, 16)
	failed: u16 = 0
	prepared := false
	ws := get_connection_workspace(c); if ws == nil do ws = get_or_create_connection_workspace(c)
	planning: {
		// Every operation body starts with its conversation ID. Resolve this table
		// before IDs so forward CreatedBy references can enforce room ownership.
		for op, i in req.operations {
			p.operation_ty[i] = op.op_type
			if len(op.body) < 8 {failed = u16(i); break planning}
			conv_id, _ := endian.get_u64(op.body, .Big)
			p.conv_ids[i] = pr.ConversationID(conv_id)
		}
		// Reserve create IDs and validate/expand all explicit deletes before any object is allocated.
		for op, i in req.operations {p.results[i].op_type = op.op_type; #partial switch op.op_type {case .TaskCreate:
				p.task_seq += 1; p.results[i].entity_id = p.task_seq; p.entity_ty[i] = .Task; case .AssetCreate:
				p.asset_seq += 1; p.results[i].entity_id = p.asset_seq; p.entity_ty[i] = .Asset; case .EdgeCreate:
				p.edge_seq += 1; p.results[i].entity_id = p.edge_seq; p.entity_ty[i] = .Edge}}
		// Check every CAS guard against initial live state before expanding delete
		// lists or allocating entities and mutation payloads.
		for op, i in req.operations {
			#partial switch op.op_type {
			case .TaskPatch:
				r, e := pr.parseTransactionTaskPatch(op.body); if e != nil {failed = u16(i); break planning}
				if r.if_updated_at !=
				   0 {conv := get_conversation(ws, r.conv_id); old := conv == nil ? nil : conv.tasks[pr.TaskID(r.task.value)]; if old == nil || old.updated_at != r.if_updated_at {failed = u16(i); break planning}}
			case .AssetPatch:
				r, e := pr.parseTransactionAssetPatch(op.body); if e != nil {failed = u16(i); break planning}
				if r.if_updated_at !=
				   0 {conv := get_conversation(ws, r.conv_id); old := conv == nil ? nil : conv.assets[pr.AssetID(r.asset.value)]; if old == nil || old.updated_at != r.if_updated_at {failed = u16(i); break planning}}
			case .TaskDelete, .AssetDelete:
				expected := op.op_type == .TaskDelete ? pr.TransactionEntityType.Task : pr.TransactionEntityType.Asset
				r, e := pr.parseTransactionDelete(op.body, expected); if e != nil {failed = u16(i); break planning}
				if r.if_updated_at !=
				   0 {conv := get_conversation(ws, r.conv_id); updated_at: i64; if conv != nil {if expected == .Task {old := conv.tasks[pr.TaskID(r.entity.value)]; if old != nil do updated_at = old.updated_at} else {old := conv.assets[pr.AssetID(r.entity.value)]; if old != nil do updated_at = old.updated_at}}; if updated_at != r.if_updated_at {failed = u16(i); break planning}}
			}
		}
		for op, i in req.operations {
			expected := pr.TransactionEntityType.Task
			#partial switch op.op_type {case .TaskDelete:
				expected = .Task; case .AssetDelete:
				expected = .Asset; case .EdgeDelete:
				expected = .Edge; case:
				continue}
			r, e := pr.parseTransactionDelete(op.body, expected)
			if e != nil || r.entity.kind != .Existing {failed = u16(i); break planning}
			p.conv_ids[i] = r.conv_id; p.results[i].entity_id = r.entity.value
			conv := get_conversation(ws, r.conv_id)
			items := &p.delete_tasks; if expected == .Asset do items = &p.delete_assets; if expected == .Edge do items = &p.delete_edges
			if transaction_delete_contains(items^[:], r.conv_id, r.entity.value) {failed = u16(i); break planning}
			if !transaction_entity_exists(&p, conv, r.conv_id, expected, r.entity.value) {failed = u16(i); break planning}
			if r.if_updated_at != 0 {
				if expected == .Task && conv.tasks[pr.TaskID(r.entity.value)].updated_at != r.if_updated_at {failed = u16(i); break planning}
				if expected == .Asset && conv.assets[pr.AssetID(r.entity.value)].updated_at != r.if_updated_at {failed = u16(i); break planning}
			}
			if expected == .Asset && conv.assets[pr.AssetID(r.entity.value)].asset_type == .RoomMapping {failed = u16(i); break planning}
			if !transaction_delete_add(items, r.conv_id, r.entity.value) {failed = u16(i); break planning}
		}
		// Expand ownership cascades, then collect every incident edge once.
		for item in p.delete_tasks {
			conv := get_conversation(ws, item.conv_id); ids := make([dynamic]pr.AssetID, 0, 8); collect_task_asset_delete_ids(conv, pr.TaskID(item.id), &ids)
			for id in ids do if !transaction_delete_add(&p.delete_assets, item.conv_id, u64(id)) {delete(ids); break planning}; delete(ids)
		}
		for ai := 0; ai < len(p.delete_assets); ai += 1 {
			item :=
				p.delete_assets[ai]; conv := get_conversation(ws, item.conv_id); ids := make([dynamic]pr.AssetID, 0, 8); collect_child_asset_delete_ids(conv, pr.AssetID(item.id), &ids)
			for id in ids do if !transaction_delete_add(&p.delete_assets, item.conv_id, u64(id)) {delete(ids); break planning}; delete(ids)
		}
		for item in p.delete_tasks {conv := get_conversation(ws, item.conv_id); plan: Edge_Delete_Plan; edge_delete_plan_init(&plan); collect_edges_for_entity_delete(conv, &plan, .Task, item.id); for id in plan.edge_ids do if !transaction_delete_add(&p.delete_edges, item.conv_id, u64(id)) {edge_delete_plan_destroy(&plan); break planning}; edge_delete_plan_destroy(&plan)}
		for item in p.delete_assets {conv := get_conversation(ws, item.conv_id); plan: Edge_Delete_Plan; edge_delete_plan_init(&plan); collect_edges_for_entity_delete(conv, &plan, .Asset, item.id); for id in plan.edge_ids do if !transaction_delete_add(&p.delete_edges, item.conv_id, u64(id)) {edge_delete_plan_destroy(&plan); break planning}; edge_delete_plan_destroy(&plan)}
		now := nrc_time_unix_nanos(); creator := transmute([]byte)get_connection_nickname(c)
		// Materialize task and asset creates first; endpoint and parent validation uses the complete projected set.
		for op, i in req.operations {
			#partial switch op.op_type {
			case .TaskCreate:
				r, e := pr.parseTransactionTaskCreate(op.body); if e != nil {failed = u16(i); break planning}; p.conv_ids[i] = r.conv_id
				blocked: u64
				if r.blocked_by.kind != .Existing || r.blocked_by.value != 0 {
					ok: bool
					blocked, ok = transaction_resolve_id(&p, r.blocked_by, .Task, r.conv_id)
					if !ok {failed = u16(i); break planning}
				}
				t := alloc_task(
					r.title,
					r.description,
					nil,
					creator,
					r.external_ref,
					nil,
					r.project,
					nil,
				); if t == nil {failed = u16(i); break planning}; t.id = pr.TaskID(p.results[i].entity_id); t.conv_id = r.conv_id; t.status = r.status; t.priority = r.priority; t.color = r.color; t.created_at = now; t.updated_at = now; t.due_at = r.due_at; t.blocked_by = pr.TaskID(blocked); p.entity[i] = t
			case .AssetCreate:
				r, e := pr.parseTransactionAssetCreate(op.body)
				if e != nil || r.asset_type == .RoomMapping || r.asset_type == .Agenda {failed = u16(i); break planning}
				if !validate_appointment_asset(
					r.asset_type,
					r.payload_encoding,
					r.payload_raw_len,
					r.preview,
					r.payload,
					context.temp_allocator,
				) {failed = u16(i); break planning}
				p.conv_ids[i] = r.conv_id
				parent: u64
				if r.parent_type !=
				   .None {expected := pr.TransactionEntityType.Task; if r.parent_type == .Asset do expected = .Asset; ok: bool; parent, ok = transaction_resolve_id(&p, r.parent, expected, r.conv_id)
					if !ok {failed = u16(i); break planning}}
				a := alloc_asset(creator, r.preview, r.payload, nil)
				if a == nil {failed = u16(i); break planning}
				a.asset_id = pr.AssetID(p.results[i].entity_id)
				a.conv_id = r.conv_id
				a.asset_type = r.asset_type
				a.parent_type = r.parent_type
				a.parent_id = parent
				a.created_at = now
				a.updated_at = now
				a.payload_encoding = r.payload_encoding
				a.payload_raw_len = r.payload_raw_len
				p.entity[i] = a
			case .TaskPatch:
				r, e := pr.parseTransactionTaskPatch(op.body); if e != nil || r.task.kind != .Existing {failed = u16(i); break planning}
				p.conv_ids[i] = r.conv_id
				p.results[i].entity_id = r.task.value
				p.entity_ty[i] = .Task
				for j in 0 ..< i do if p.entity_ty[j] == .Task && p.results[j].entity_id == r.task.value && p.conv_ids[j] == r.conv_id && req.operations[j].op_type != .TaskCreate {failed = u16(i); break planning}
				if transaction_delete_contains(p.delete_tasks[:], r.conv_id, r.task.value) {failed = u16(i); break planning}
				conv := get_conversation(ws, r.conv_id)
				old := conv == nil ? nil : conv.tasks[pr.TaskID(r.task.value)]
				if old == nil {failed = u16(i); break planning}
				if r.if_updated_at != 0 && old.updated_at != r.if_updated_at {failed = u16(i); break planning}
				blocked := old.blocked_by
				if r.present & pr.TRANSACTION_TASK_PATCH_BLOCKED_BY != 0 {
					if r.blocked_by.kind == .Existing && r.blocked_by.value == 0 {
						blocked = 0
					} else {
						resolved, ok := transaction_resolve_id(&p, r.blocked_by, .Task, r.conv_id)
						if !ok {failed = u16(i); break planning}
						blocked = pr.TaskID(resolved)
					}
				}
				title := old.title
				description := old.description
				assignee := old.assignee
				external_ref := old.external_ref
				project := old.project
				status := old.status
				if r.present & pr.TRANSACTION_TASK_PATCH_STATUS != 0 do status = r.status
				completed_by := old.completed_by
				if status == .Done && old.status != .Done do completed_by = creator
				if status != .Done && old.status == .Done do completed_by = nil
				if r.present & pr.TRANSACTION_TASK_PATCH_TITLE != 0 do title = r.title
				if r.present & pr.TRANSACTION_TASK_PATCH_DESCRIPTION != 0 do description = r.description
				if r.present & pr.TRANSACTION_TASK_PATCH_ASSIGNEE != 0 do assignee = r.assignee
				if r.present & pr.TRANSACTION_TASK_PATCH_EXTERNAL_REF != 0 do external_ref = r.external_ref
				if r.present & pr.TRANSACTION_TASK_PATCH_PROJECT != 0 do project = r.project
				if len(title) == 0 {failed = u16(i); break planning}
				t := alloc_task(title, description, assignee, old.created_by, external_ref, completed_by, project, old.attachments)
				if t == nil {failed = u16(i); break planning}
				t.id = old.id
				t.conv_id = old.conv_id
				t.status = old.status
				t.order_index = old.order_index
				t.priority = old.priority
				t.color = old.color
				t.created_at = old.created_at
				t.updated_at = old.updated_at
				t.due_at = old.due_at
				t.blocked_by = old.blocked_by
				t.completed_at = old.completed_at
				t.status = status
				if r.present & pr.TRANSACTION_TASK_PATCH_PRIORITY != 0 do t.priority = r.priority
				if r.present & pr.TRANSACTION_TASK_PATCH_COLOR != 0 do t.color = r.color
				if r.present & pr.TRANSACTION_TASK_PATCH_DUE_AT != 0 do t.due_at = r.due_at
				t.blocked_by = blocked
				if t.status < min(pr.TaskStatus) || t.status > max(pr.TaskStatus) || t.color < min(pr.TaskColor) || t.color > max(pr.TaskColor) {free_task(t)
					failed = u16(i)
					break planning}
				if t.status == .Done &&
				   old.status != .Done {t.completed_at = max(now, old.updated_at + 1)} else if t.status != .Done && old.status == .Done {t.completed_at = 0}
				t.updated_at = max(now, old.updated_at + 1)
				p.old[i] = old
				p.entity[i] = t
			case .AssetPatch:
				r, e := pr.parseTransactionAssetPatch(op.body); if e != nil || r.asset.kind != .Existing {failed = u16(i); break planning}
				p.conv_ids[i] = r.conv_id
				p.results[i].entity_id = r.asset.value
				p.entity_ty[i] = .Asset
				for j in 0 ..< i do if p.entity_ty[j] == .Asset && p.results[j].entity_id == r.asset.value && p.conv_ids[j] == r.conv_id && req.operations[j].op_type != .AssetCreate {failed = u16(i); break planning}
				if transaction_delete_contains(p.delete_assets[:], r.conv_id, r.asset.value) {failed = u16(i); break planning}
				conv := get_conversation(ws, r.conv_id)
				old := conv == nil ? nil : conv.assets[pr.AssetID(r.asset.value)]
				if old == nil || old.asset_type == .RoomMapping {failed = u16(i); break planning}
				if r.if_updated_at != 0 && old.updated_at != r.if_updated_at {failed = u16(i); break planning}
				preview := old.preview
				payload := old.payload
				encoding := old.payload_encoding
				raw_len := old.payload_raw_len
				if r.present & pr.TRANSACTION_ASSET_PATCH_PREVIEW != 0 do preview = r.preview
				if r.present & pr.TRANSACTION_ASSET_PATCH_PAYLOAD != 0 {payload = r.payload; encoding = r.payload_encoding; raw_len = r.payload_raw_len
					if encoding < min(pr.PayloadEncoding) ||
					   encoding > max(pr.PayloadEncoding) ||
					   encoding == .Plain && raw_len != u32(len(payload)) {failed = u16(i)
						break planning}}
				if !validate_appointment_asset(old.asset_type, encoding, raw_len, preview, payload, context.temp_allocator) {failed = u16(i); break planning}
				a := alloc_asset(old.owner, preview, payload, old.attachments)
				if a == nil {failed = u16(i); break planning}
				a.asset_type = old.asset_type
				a.asset_id = old.asset_id
				a.parent_type = old.parent_type
				a.parent_id = old.parent_id
				a.created_at = old.created_at
				a.updated_at = max(now, old.updated_at + 1)
				a.conv_id = old.conv_id
				a.payload_encoding = encoding
				a.payload_raw_len = raw_len
				p.old[i] = old
				p.entity[i] = a
			}
		}
		// Resolve completion cascades against the complete post-image set before
		// serializing anything, so patch order cannot restore a consumed dependency.
		for op, i in req.operations {
			if op.op_type != .TaskCreate && op.op_type != .TaskPatch do continue
			next := (^pr.Task)(p.entity[i])
			old := (^pr.Task)(p.old[i])
			if next.status == .Done && (old == nil || old.status != .Done) {
				collect_task_unblocks(get_conversation(ws, next.conv_id), next, &p.unblocks, &p)
			}
		}
		for &next in p.unblocks do if !transaction_add_task_mutation(&p, 0, &next, .Update) do break planning
		for op, i in req.operations {
			switch op.op_type {
			case .TaskCreate:
				t := (^pr.Task)(p.entity[i]); conv := get_conversation(ws, t.conv_id)
				if t.blocked_by != 0 &&
				   (!transaction_entity_exists(&p, conv, t.conv_id, .Task, u64(t.blocked_by)) ||
						   transaction_delete_contains(p.delete_tasks[:], t.conv_id, u64(t.blocked_by))) {failed = u16(i); break planning}
				if !transaction_add_task_mutation(&p, i, t, .Create) {failed = u16(i); break planning}
			case .AssetCreate:
				a := (^pr.Asset)(p.entity[i]); conv := get_conversation(ws, a.conv_id); if a.parent_type != .None {typ := pr.TransactionEntityType.Task
					if a.parent_type == .Asset do typ = .Asset
					if !transaction_entity_exists(&p, conv, a.conv_id, typ, a.parent_id) ||
					   (typ == .Task && transaction_delete_contains(p.delete_tasks[:], a.conv_id, a.parent_id)) ||
					   (typ == .Asset && transaction_delete_contains(p.delete_assets[:], a.conv_id, a.parent_id)) ||
					   (a.parent_type == .Asset &&
							   transaction_asset_parent_would_cycle(&p, conv, a.conv_id, a.asset_id, pr.AssetID(a.parent_id))) {failed = u16(i)
						break planning}}
				if !transaction_add_asset_mutation(&p, i, a, .Create) {failed = u16(i); break planning}
			case .EdgeCreate:
				r, e := pr.parseTransactionEdgeCreate(op.body); if e != nil {failed = u16(i); break planning}; p.conv_ids[i] = r.conv_id
				if (r.source.entity_type != .Task && r.source.entity_type != .Asset) ||
				   (r.target.entity_type != .Task && r.target.entity_type != .Asset) {failed = u16(i); break planning}
				sid, sok := transaction_resolve_id(&p, r.source, r.source.entity_type, r.conv_id)
				tid, tok := transaction_resolve_id(&p, r.target, r.target.entity_type, r.conv_id)
				conv := get_conversation(ws, r.conv_id)
				if !sok ||
				   !tok ||
				   r.source.entity_type == r.target.entity_type && sid == tid ||
				   !transaction_entity_exists(&p, conv, r.conv_id, r.source.entity_type, sid) ||
				   !transaction_entity_exists(&p, conv, r.conv_id, r.target.entity_type, tid) ||
				   r.source.kind == .Existing &&
					   ((r.source.entity_type == .Task && transaction_delete_contains(p.delete_tasks[:], r.conv_id, sid)) ||
							   (r.source.entity_type == .Asset && transaction_delete_contains(p.delete_assets[:], r.conv_id, sid))) ||
				   r.target.kind == .Existing &&
					   ((r.target.entity_type == .Task && transaction_delete_contains(p.delete_tasks[:], r.conv_id, tid)) ||
							   (r.target.entity_type == .Asset &&
									   transaction_delete_contains(p.delete_assets[:], r.conv_id, tid))) {failed = u16(i); break planning}
				edge := alloc_edge(creator)
				if edge == nil {failed = u16(i); break planning}
				edge.edge_id = pr.EdgeID(p.results[i].entity_id)
				edge.conv_id = r.conv_id
				edge.source_type = r.source.entity_type == .Task ? pr.TargetType.Task : pr.TargetType.Asset
				edge.source_id = sid
				edge.target_type = r.target.entity_type == .Task ? pr.TargetType.Task : pr.TargetType.Asset
				edge.target_id = tid
				edge.relation = r.relation
				edge.created_at = now
				p.entity[i] = edge
				if !transaction_add_edge_mutation(&p, i, edge) {failed = u16(i); break planning}
			case .TaskPatch:
				t := (^pr.Task)(p.entity[i])
				if t.blocked_by != 0 &&
				   (transaction_delete_contains(p.delete_tasks[:], t.conv_id, u64(t.blocked_by)) ||
						   !transaction_entity_exists(
								   &p,
								   get_conversation(ws, t.conv_id),
								   t.conv_id,
								   .Task,
								   u64(t.blocked_by),
							   )) {failed = u16(i); break planning}
				if !transaction_add_task_mutation(&p, i, t, .Update) {failed = u16(i); break planning}
			case .AssetPatch:
				if !transaction_add_asset_mutation(&p, i, (^pr.Asset)(p.entity[i]), .Update) {failed = u16(i); break planning}
			case .TaskDelete, .AssetDelete, .EdgeDelete:
			}
		}
		// Enforce projected limits after all creates, patches, and cascades are known.
		for item in p.delete_tasks {
			conv := get_conversation(ws, item.conv_id)
			it := btree.iter(&conv.task_blockers)
			defer btree.iter_destroy(&it)
			for found := btree.iter_seek(&it, Entity_Reference_Key{parent_id = item.id}); found; found = btree.iter_next(&it) {
				key := btree.item(&it)
				if key.parent_id != item.id do break
				if transaction_delete_contains(p.delete_tasks[:], item.conv_id, key.entity_id) do continue
				live := conv.tasks[pr.TaskID(key.entity_id)]
				next := (^pr.Task)(transaction_projected_entity(&p, .Task, item.conv_id, key.entity_id, live))
				if next.blocked_by == pr.TaskID(item.id) do break planning
			}
		}
		for op, i in req.operations {conv_id := p.conv_ids[i]; conv := get_conversation(ws, conv_id); tasks := 0; active := 0; assets := 0; edges := 0; if conv != nil {tasks = len(conv.tasks); active = conv.active_task_count; assets = len(conv.assets); edges = len(conv.edges)}
			for item in p.delete_tasks do if item.conv_id == conv_id {tasks -= 1; old := conv.tasks[pr.TaskID(item.id)]; if old != nil && task_status_is_active(old.status) do active -= 1}; for item in p.delete_assets do if item.conv_id == conv_id do assets -= 1; for item in p.delete_edges do if item.conv_id == conv_id do edges -= 1
			for _, j in req.operations {if p.conv_ids[j] != conv_id do continue; switch p.entity_ty[j] {case .Task:
					if req.operations[j].op_type ==
					   .TaskCreate {tasks += 1; if task_status_is_active((^pr.Task)(p.entity[j]).status) do active += 1} else if req.operations[j].op_type == .TaskPatch {old := (^pr.Task)(p.old[j]); next := (^pr.Task)(p.entity[j]); if task_status_is_active(old.status) != task_status_is_active(next.status) do active += task_status_is_active(next.status) ? 1 : -1}; case .Asset:
					if req.operations[j].op_type == .AssetCreate do assets += 1; case .Edge:
					if req.operations[j].op_type == .EdgeCreate do edges += 1}}
			if tasks > pr.MAX_TOTAL_TASKS_PER_CONVERSATION ||
			   active > pr.MAX_ACTIVE_TASKS_PER_CONVERSATION ||
			   assets > pr.MAX_ASSETS_PER_CONVERSATION ||
			   edges > pr.MAX_EDGES_PER_CONVERSATION {failed = u16(i); break planning}; _ = op
		}
		slice.sort_by(
			p.delete_edges[:],
			transaction_delete_less,
		); slice.sort_by(p.delete_assets[:], transaction_delete_less); slice.sort_by(p.delete_tasks[:], transaction_delete_less)
		for item in p.delete_edges do if !transaction_add_delete_mutation(&p, .Edge, u8(Edge_Log_Op.Delete), item) {break planning}
		for item in p.delete_assets do if !transaction_add_delete_mutation(&p, .Asset, u8(Asset_Log_Op.Delete), item) {break planning}
		for item in p.delete_tasks do if !transaction_add_delete_mutation(&p, .Task, u8(Task_Log_Op.Delete), item) {break planning}
		if !transaction_prepare_install(&p, ws, req.operations) do break planning
		writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)c.workspace_id); if writer == nil {break planning}
		tx := Shard_Transaction {
			workspace        = transmute([]byte)c.workspace_id,
			task_high_water  = p.task_seq,
			asset_high_water = p.asset_seq,
			edge_high_water  = p.edge_seq,
			mutations        = p.mutations[:],
		}
		if !append_shard_transaction(writer, &tx) {
			if consume_shard_append_deferred() do return
			if consume_shard_append_backpressure() do break planning
			persistent_mutation_failed("transaction", "apply", c.workspace_id)
			return
		}
		prepared = true
	}
	if !prepared {
		log.warnf("[T%d] Rejected transaction %d at operation %d", td.thread_index, req.correlation_id, failed)
		send_transaction_result(c, req.correlation_id, .Rejected, failed, nil)
		return
	}
	// The worker cannot interleave requests during this delta publication. After
	// WAL append, allocation failures must fail-stop; recovery replays the whole
	// transaction before serving. Never reject or emit a result mid-publication.
	for &stage in p.stages {
		state_map_set(&ws.conversations, stage.conv_id, stage.staged)
		stage.staged = nil
	}
	for item in p.delete_edges do apply_persisted_edge_delete(c.workspace_id, item.conv_id, pr.EdgeID(item.id))
	for item in p.delete_assets do apply_persisted_asset_delete(c.workspace_id, item.conv_id, pr.AssetID(item.id))
	for item in p.delete_tasks do apply_persisted_delete(c.workspace_id, item.conv_id, pr.TaskID(item.id))
	for _, i in req.operations {
		if p.entity[i] == nil do continue
		conv := get_conversation(ws, p.conv_ids[i])
		switch p.entity_ty[i] {
		case .Task:
			next := (^pr.Task)(p.entity[i])
			task_store_put(conv, next)
		case .Asset:
			next := (^pr.Asset)(p.entity[i])
			asset_store_put(ws, c.workspace_id, conv, next)
		case .Edge:
			next := (^pr.Edge)(p.entity[i])
			edge_store_put(conv, next)
		}
	}
	for i in 0 ..< pr.MAX_TRANSACTION_OPERATIONS do p.entity[i] = nil
	committed = true
	td.task_seq = p.task_seq; td.asset_seq = p.asset_seq; td.edge_seq = p.edge_seq
	apply_task_unblocks(ws, p.unblocks[:])
	for _, i in req.operations {switch req.operations[i].op_type {case .TaskCreate:
			t := get_conversation(ws, p.conv_ids[i]).tasks[pr.TaskID(p.results[i].entity_id)]
			broadcast_task_created(t^, p.unblocked_operations[i] ? net.TCP_Socket(-1) : c.sock, ws); case .TaskPatch:
			t := get_conversation(ws, p.conv_ids[i]).tasks[pr.TaskID(p.results[i].entity_id)]
			broadcast_task_updated(t^, p.unblocked_operations[i] ? net.TCP_Socket(-1) : c.sock, ws); case .AssetCreate:
			a := get_conversation(ws, p.conv_ids[i]).assets[pr.AssetID(p.results[i].entity_id)]; broadcast_asset_created(a^, c.sock, ws); case .AssetPatch:
			a := get_conversation(ws, p.conv_ids[i]).assets[pr.AssetID(p.results[i].entity_id)]; broadcast_asset_updated(a^, c.sock, ws); case .EdgeCreate:
			e := get_conversation(ws, p.conv_ids[i]).edges[pr.EdgeID(p.results[i].entity_id)]
			broadcast_edge_created(e^, c.sock, ws); case .TaskDelete, .AssetDelete, .EdgeDelete:}}
	for item in p.delete_edges do broadcast_edge_deleted(item.conv_id, pr.EdgeID(item.id), c.sock, ws)
	for item in p.delete_assets do broadcast_asset_deleted_to_room(item.conv_id, pr.AssetID(item.id), c.sock, ws)
	for item in p.delete_tasks do broadcast_task_deleted(pr.TaskID(item.id), item.conv_id, c.sock, ws)
	send_transaction_result(c, req.correlation_id, .Committed, max(u16), p.results[:len(req.operations)])
}

send_transaction_result :: proc(
	c: ^NRC_Connection,
	correlation_id: u32,
	status: pr.TransactionResultStatus,
	failed_operation: u16,
	results: []pr.TransactionOperationResult,
) {
	protocol_len := pr.getSizeTransactionResult(
		len(results),
	); buf, header_len := allocate_websocket_frame_buffer(protocol_len, "transaction result"); if buf == nil do return
	written := pr.serializeTransactionResult(
		correlation_id,
		status,
		failed_operation,
		results,
		buf[header_len:],
	); if written != protocol_len {byte_pool.release(td.spool, buf); return}; _ = send_pooled_buffer_priority(c, buf[:header_len + written])
}
