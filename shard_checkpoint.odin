package main

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:fmt"
import "core:slice"

import "persistence"
import pr "protocol"
import "storage_io"

SHARD_CHECKPOINT_DIGEST_VERSION :: u16(1)

shard_checkpoint_sha_u8 :: proc(ctx: ^sha2.Context_256, value: u8) {sha2.update(ctx, []byte{value})}
shard_checkpoint_sha_u16 :: proc(ctx: ^sha2.Context_256, value: u16) {buf: [2]byte; endian.put_u16(buf[:], .Big, value); sha2.update(ctx, buf[:])}
shard_checkpoint_sha_u32 :: proc(ctx: ^sha2.Context_256, value: u32) {buf: [4]byte; endian.put_u32(buf[:], .Big, value); sha2.update(ctx, buf[:])}
shard_checkpoint_sha_u64 :: proc(ctx: ^sha2.Context_256, value: u64) {buf: [8]byte; endian.put_u64(buf[:], .Big, value); sha2.update(ctx, buf[:])}

shard_checkpoint_sha_bytes :: proc(ctx: ^sha2.Context_256, value: []byte) {
	shard_checkpoint_sha_u64(ctx, u64(len(value)))
	sha2.update(ctx, value)
}

shard_checkpoint_sha_attachment :: proc(ctx: ^sha2.Context_256, attachment: pr.Attachment) {
	shard_checkpoint_sha_bytes(ctx, attachment.file_id)
	shard_checkpoint_sha_bytes(ctx, attachment.filename)
	shard_checkpoint_sha_u64(ctx, attachment.size)
	shard_checkpoint_sha_bytes(ctx, attachment.mime_type)
	shard_checkpoint_sha_u64(ctx, cast(u64)attachment.uploaded_at)
}

shard_checkpoint_sha_task :: proc(ctx: ^sha2.Context_256, task: ^pr.Task) {
	shard_checkpoint_sha_u64(ctx, u64(task.id)); shard_checkpoint_sha_u64(ctx, u64(task.conv_id))
	shard_checkpoint_sha_bytes(ctx, task.title); shard_checkpoint_sha_bytes(ctx, task.description)
	shard_checkpoint_sha_u8(ctx, u8(task.status)); shard_checkpoint_sha_u16(ctx, task.order_index)
	shard_checkpoint_sha_bytes(ctx, task.assignee); shard_checkpoint_sha_u8(ctx, task.priority); shard_checkpoint_sha_u8(ctx, u8(task.color))
	shard_checkpoint_sha_bytes(
		ctx,
		task.created_by,
	); shard_checkpoint_sha_u64(ctx, cast(u64)task.created_at); shard_checkpoint_sha_u64(ctx, cast(u64)task.updated_at)
	shard_checkpoint_sha_bytes(
		ctx,
		task.external_ref,
	); shard_checkpoint_sha_u64(ctx, cast(u64)task.due_at); shard_checkpoint_sha_u64(ctx, u64(task.blocked_by))
	shard_checkpoint_sha_u64(
		ctx,
		cast(u64)task.completed_at,
	); shard_checkpoint_sha_bytes(ctx, task.completed_by); shard_checkpoint_sha_bytes(ctx, task.project)
	shard_checkpoint_sha_u64(ctx, u64(len(task.attachments)))
	for attachment in task.attachments do shard_checkpoint_sha_attachment(ctx, attachment)
}

shard_checkpoint_sha_asset :: proc(ctx: ^sha2.Context_256, asset: ^pr.Asset) {
	shard_checkpoint_sha_u16(ctx, u16(asset.asset_type)); shard_checkpoint_sha_u64(ctx, u64(asset.asset_id))
	shard_checkpoint_sha_u16(ctx, u16(asset.parent_type)); shard_checkpoint_sha_u64(ctx, asset.parent_id)
	shard_checkpoint_sha_bytes(
		ctx,
		asset.owner,
	); shard_checkpoint_sha_u64(ctx, cast(u64)asset.created_at); shard_checkpoint_sha_u64(ctx, cast(u64)asset.updated_at)
	shard_checkpoint_sha_u64(
		ctx,
		u64(asset.conv_id),
	); shard_checkpoint_sha_u8(ctx, u8(asset.payload_encoding)); shard_checkpoint_sha_u32(ctx, asset.payload_raw_len)
	shard_checkpoint_sha_bytes(ctx, asset.preview); shard_checkpoint_sha_bytes(ctx, asset.payload)
	shard_checkpoint_sha_u64(ctx, u64(len(asset.attachments)))
	for attachment in asset.attachments do shard_checkpoint_sha_attachment(ctx, attachment)
}

shard_checkpoint_sha_edge :: proc(ctx: ^sha2.Context_256, edge: ^pr.Edge) {
	shard_checkpoint_sha_u64(ctx, u64(edge.edge_id)); shard_checkpoint_sha_u64(ctx, u64(edge.conv_id))
	shard_checkpoint_sha_u16(ctx, u16(edge.source_type)); shard_checkpoint_sha_u64(ctx, edge.source_id)
	shard_checkpoint_sha_u16(ctx, u16(edge.target_type)); shard_checkpoint_sha_u64(ctx, edge.target_id)
	shard_checkpoint_sha_u16(
		ctx,
		u16(edge.relation),
	); shard_checkpoint_sha_u64(ctx, cast(u64)edge.created_at); shard_checkpoint_sha_bytes(ctx, edge.created_by)
}

Shard_Checkpoint_Workspace :: struct {
	id:    string,
	state: ^Workspace_State,
}

shard_checkpoint_workspace_less :: proc(a, b: Shard_Checkpoint_Workspace) -> bool {return a.id < b.id}

shard_checkpoint_state_digest :: proc(shard: int) -> (digest: [32]byte) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)string("NRC-SHARD-CHECKPOINT-STATE"))
	shard_checkpoint_sha_u16(&ctx, SHARD_CHECKPOINT_DIGEST_VERSION)
	workspaces := make([dynamic]Shard_Checkpoint_Workspace, 0, len(td.workspaces)); defer delete(workspaces)
	for id, state in td.workspaces {
		if int(shard_for_workspace(transmute([]byte)id)) == shard do append(&workspaces, Shard_Checkpoint_Workspace{id, state})
	}
	slice.sort_by(workspaces[:], shard_checkpoint_workspace_less)
	for workspace in workspaces {
		conv_ids := make([dynamic]pr.ConversationID, 0, len(workspace.state.conversations))
		for conv_id in workspace.state.conversations do append(&conv_ids, conv_id)
		slice.sort_by(conv_ids[:], proc(a, b: pr.ConversationID) -> bool {return a < b})
		for conv_id in conv_ids {
			conv := workspace.state.conversations[conv_id]
			task_ids := make([dynamic]pr.TaskID, 0, len(conv.tasks))
			asset_ids := make([dynamic]pr.AssetID, 0, len(conv.assets))
			edge_ids := make([dynamic]pr.EdgeID, 0, len(conv.edges))
			for id in conv.tasks do append(&task_ids, id)
			for id in conv.assets do append(&asset_ids, id)
			for id in conv.edges do append(&edge_ids, id)
			slice.sort_by(task_ids[:], proc(a, b: pr.TaskID) -> bool {return a < b})
			slice.sort_by(asset_ids[:], proc(a, b: pr.AssetID) -> bool {return a < b})
			slice.sort_by(edge_ids[:], proc(a, b: pr.EdgeID) -> bool {return a < b})
			for id in task_ids {shard_checkpoint_sha_u8(&ctx, 1); shard_checkpoint_sha_bytes(&ctx, transmute([]byte)workspace.id)
				shard_checkpoint_sha_task(&ctx, conv.tasks[id])}
			for id in asset_ids {shard_checkpoint_sha_u8(&ctx, 2); shard_checkpoint_sha_bytes(&ctx, transmute([]byte)workspace.id)
				shard_checkpoint_sha_asset(&ctx, conv.assets[id])}
			for id in edge_ids {shard_checkpoint_sha_u8(&ctx, 3); shard_checkpoint_sha_bytes(&ctx, transmute([]byte)workspace.id)
				shard_checkpoint_sha_edge(&ctx, conv.edges[id])}
			delete(task_ids); delete(asset_ids); delete(edge_ids)
		}
		delete(conv_ids)
	}
	sha2.final(&ctx, digest[:])
	return
}

Shard_Checkpoint_Emitter :: struct {
	builder:   persistence.WAL_File_Builder,
	mutations: [dynamic]Shard_Mutation,
	storage:   [dynamic][]byte,
	size:      int,
}

shard_checkpoint_emitter_clear :: proc(emitter: ^Shard_Checkpoint_Emitter) {
	for payload in emitter.storage do delete(payload)
	clear(&emitter.storage)
	clear(&emitter.mutations)
	emitter.size = 0
}

shard_checkpoint_emitter_destroy :: proc(emitter: ^Shard_Checkpoint_Emitter) {
	shard_checkpoint_emitter_clear(emitter)
	delete(emitter.storage)
	delete(emitter.mutations)
}

shard_checkpoint_emit :: proc(emitter: ^Shard_Checkpoint_Emitter, workspace: string, floors: Shard_High_Water_Requirements) -> bool {
	if len(emitter.mutations) == 0 do return true
	tx := Shard_Transaction {
		workspace        = transmute([]byte)workspace,
		task_high_water  = floors.task,
		asset_high_water = floors.asset,
		edge_high_water  = floors.edge,
		mutations        = emitter.mutations[:],
	}
	payload_size, size_err := shard_transaction_size(&tx)
	if size_err != .None do return false
	record := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(record)
	if encode_shard_transaction(&tx, record[persistence.LOG_HEADER_SIZE:]) != .None do return false
	if !persistence.append_wal_file_builder(&emitter.builder, u8(Shard_Log_Op.Transaction), record) do return false
	shard_checkpoint_emitter_clear(emitter)
	return true
}

shard_checkpoint_add :: proc(
	emitter: ^Shard_Checkpoint_Emitter,
	workspace: string,
	floors: Shard_High_Water_Requirements,
	domain: Shard_Mutation_Domain,
	op: u8,
	version: u16,
	payload: []byte,
) -> bool {
	base_size := 34 + len(workspace)
	if emitter.size == 0 do emitter.size = base_size
	if len(emitter.mutations) >= SHARD_TRANSACTION_MAX_MUTATIONS || emitter.size > SHARD_TRANSACTION_MAX_SIZE - 8 - len(payload) {
		if !shard_checkpoint_emit(emitter, workspace, floors) do return false
		emitter.size = base_size
	}
	if base_size > SHARD_TRANSACTION_MAX_SIZE - 8 - len(payload) do return false
	append(&emitter.storage, payload)
	append(&emitter.mutations, Shard_Mutation{domain = domain, op = op, entity_record_version = version, payload = payload})
	emitter.size += 8 + len(payload)
	return true
}

shard_checkpoint_task_payload :: proc(task: ^pr.Task) -> []byte {
	payload := make([]byte, calculate_task_fields_size(task^))
	if serialize_task_fields(task^, payload) != len(payload) {delete(payload); return nil}
	return payload
}

shard_checkpoint_asset_payload :: proc(workspace: string, asset: ^pr.Asset) -> []byte {
	record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_asset_payload_size(workspace, asset))
	defer delete(record)
	serialize_asset_to_record(record, workspace, asset)
	_, offset, ok := persistence.parse_workspace_prefix(record[persistence.LOG_HEADER_SIZE:])
	if !ok do return nil
	payload := make([]byte, len(record) - persistence.LOG_HEADER_SIZE - offset)
	copy(payload, record[persistence.LOG_HEADER_SIZE + offset:])
	return payload
}

shard_checkpoint_edge_payload :: proc(workspace: string, edge: ^pr.Edge) -> []byte {
	record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_edge_payload_size(workspace, edge))
	defer delete(record)
	serialize_edge_to_record(record, workspace, edge)
	_, offset, ok := persistence.parse_workspace_prefix(record[persistence.LOG_HEADER_SIZE:])
	if !ok do return nil
	payload := make([]byte, len(record) - persistence.LOG_HEADER_SIZE - offset)
	copy(payload, record[persistence.LOG_HEADER_SIZE + offset:])
	return payload
}

// Empty checkpoints still need a workspace-routed transaction to preserve
// shard-wide high-water floors. The witness has no mutations and therefore
// creates no visible workspace or entity state during replay.
shard_checkpoint_floor_witness :: proc(shard: int) -> string {
	for nonce: u64 = 0; nonce < 1_000_000; nonce += 1 {
		candidate := fmt.aprintf("__nrc_checkpoint_floor_%d_%d", shard, nonce)
		if int(shard_for_workspace(transmute([]byte)candidate)) == shard do return candidate
		delete(candidate)
	}
	return ""
}

build_shard_checkpoint_from_replayed_state :: proc {
	build_shard_checkpoint_from_replayed_state_host,
	build_shard_checkpoint_from_replayed_state_with_storage,
}

build_shard_checkpoint_from_replayed_state_host :: proc(path: string, shard: int, floors: Shard_High_Water_Requirements) -> bool {
	return build_shard_checkpoint_from_replayed_state_with_storage(storage_io.host_context(), path, shard, floors)
}

build_shard_checkpoint_from_replayed_state_with_storage :: proc(
	storage: storage_io.Context,
	path: string,
	shard: int,
	floors: Shard_High_Water_Requirements,
) -> bool {
	emitter: Shard_Checkpoint_Emitter
	defer shard_checkpoint_emitter_destroy(&emitter)
	if !persistence.create_wal_file_builder(&emitter.builder, storage, path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION) do return false
	finished := false
	defer if !finished do persistence.abort_wal_file_builder(&emitter.builder)

	workspaces := make([dynamic]Shard_Checkpoint_Workspace, 0, len(td.workspaces)); defer delete(workspaces)
	for id, state in td.workspaces {
		if int(shard_for_workspace(transmute([]byte)id)) == shard do append(&workspaces, Shard_Checkpoint_Workspace{id, state})
	}
	slice.sort_by(workspaces[:], shard_checkpoint_workspace_less)
	witness := ""
	for workspace in workspaces {
		if witness == "" do witness = workspace.id
		conv_ids := make([dynamic]pr.ConversationID, 0, len(workspace.state.conversations))
		for conv_id in workspace.state.conversations do append(&conv_ids, conv_id)
		slice.sort_by(conv_ids[:], proc(a, b: pr.ConversationID) -> bool {return a < b})
		for conv_id in conv_ids {
			conv := workspace.state.conversations[conv_id]
			task_ids := make(
				[dynamic]pr.TaskID,
				0,
				len(conv.tasks),
			); for id in conv.tasks do append(&task_ids, id); slice.sort_by(task_ids[:], proc(a, b: pr.TaskID) -> bool {return a < b})
			for id in task_ids {payload := shard_checkpoint_task_payload(conv.tasks[id])
				if payload == nil ||
				   !shard_checkpoint_add(
						   &emitter,
						   workspace.id,
						   floors,
						   .Task,
						   u8(Task_Log_Op.Create),
						   1,
						   payload,
					   ) {delete(task_ids); delete(conv_ids); return false}}
			delete(task_ids)
			asset_ids := make(
				[dynamic]pr.AssetID,
				0,
				len(conv.assets),
			); for id in conv.assets do append(&asset_ids, id); slice.sort_by(asset_ids[:], proc(a, b: pr.AssetID) -> bool {return a < b})
			for id in asset_ids {payload := shard_checkpoint_asset_payload(workspace.id, conv.assets[id])
				if payload == nil ||
				   !shard_checkpoint_add(
						   &emitter,
						   workspace.id,
						   floors,
						   .Asset,
						   u8(Asset_Log_Op.Create),
						   ASSET_LOG_VERSION,
						   payload,
					   ) {delete(asset_ids); delete(conv_ids); return false}}
			delete(asset_ids)
			edge_ids := make(
				[dynamic]pr.EdgeID,
				0,
				len(conv.edges),
			); for id in conv.edges do append(&edge_ids, id); slice.sort_by(edge_ids[:], proc(a, b: pr.EdgeID) -> bool {return a < b})
			for id in edge_ids {payload := shard_checkpoint_edge_payload(workspace.id, conv.edges[id])
				if payload == nil ||
				   !shard_checkpoint_add(
						   &emitter,
						   workspace.id,
						   floors,
						   .Edge,
						   u8(Edge_Log_Op.Create),
						   EDGE_LOG_VERSION,
						   payload,
					   ) {delete(edge_ids); delete(conv_ids); return false}}
			delete(edge_ids)
		}
		delete(conv_ids)
		if !shard_checkpoint_emit(&emitter, workspace.id, floors) do return false
	}
	if floors != {} {
		floor_witness := ""
		if witness == "" {
			floor_witness = shard_checkpoint_floor_witness(shard)
			if floor_witness == "" do return false
			witness = floor_witness
		}
		tx := Shard_Transaction {
			workspace        = transmute([]byte)witness,
			task_high_water  = floors.task,
			asset_high_water = floors.asset,
			edge_high_water  = floors.edge,
		}
		payload_size, size_err := shard_transaction_size(&tx)
		if size_err != .None {
			if floor_witness != "" do delete(floor_witness)
			return false
		}
		record := make([]byte, persistence.LOG_HEADER_SIZE + payload_size); defer delete(record)
		appended :=
			encode_shard_transaction(&tx, record[persistence.LOG_HEADER_SIZE:]) == .None &&
			persistence.append_wal_file_builder(&emitter.builder, u8(Shard_Log_Op.Transaction), record)
		if floor_witness != "" do delete(floor_witness)
		if !appended do return false
	}
	finished = persistence.finish_wal_file_builder(&emitter.builder)
	return finished
}

replay_shard_checkpoint_input :: proc {
	replay_shard_checkpoint_input_host,
	replay_shard_checkpoint_input_with_storage,
}

replay_shard_checkpoint_input_host :: proc(
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	apply := true,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	return replay_shard_checkpoint_input_with_storage(storage_io.host_context(), shard_dir, manifest, apply)
}

replay_shard_checkpoint_input_with_storage :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	apply := true,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	origins: Workspace_Data_Replay_Origins
	owns_origins := workspace_data_origins_begin(&origins)
	defer workspace_data_origins_end(&origins, owns_origins)
	if manifest.checkpoint_present {
		if manifest.segmented {
			catalog, catalog_ok := load_shard_segment_catalog(storage, shard_dir, manifest.checkpoint_generation)
			if !catalog_ok || catalog.shard != manifest.shard do return floors, false
			defer destroy_shard_segment_catalog(&catalog)
			for descriptor in catalog.segments {
				path := shard_segment_descriptor_path(shard_dir, descriptor)
				if path == "" do return floors, false
				_, floors, ok = scan_shard_transaction_wal(storage, path, manifest.shard, floors, apply, false)
				delete(path)
				if !ok do return
			}
		} else {
			path := shard_checkpoint_wal_path(shard_dir, manifest.checkpoint_generation)
			_, floors, ok = scan_shard_transaction_wal(storage, path, manifest.shard, floors, apply, false)
			delete(path)
			if !ok do return
		}
	}
	if !manifest.sealed_present do return floors, true
	path := shard_generation_wal_path(shard_dir, manifest.sealed_generation)
	_, floors, ok = scan_shard_transaction_wal(storage, path, manifest.shard, floors, apply, false)
	delete(path)
	return
}

build_and_verify_shard_checkpoint :: proc {
	build_and_verify_shard_checkpoint_host,
	build_and_verify_shard_checkpoint_with_storage,
}

build_and_verify_shard_checkpoint_host :: proc(
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	output_path: string,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	return build_and_verify_shard_checkpoint_with_storage(storage_io.host_context(), shard_dir, manifest, output_path)
}

build_and_verify_shard_checkpoint_with_storage :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	output_path: string,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	origins: Workspace_Data_Replay_Origins
	owns_origins := workspace_data_origins_begin(&origins)
	defer workspace_data_origins_end(&origins, owns_origins)
	shard_replay_state_init()
	replay_ok: bool
	floors, replay_ok = replay_shard_checkpoint_input(storage, shard_dir, manifest)
	if !replay_ok {shard_replay_state_destroy(); return}
	// Check the retained suffix before a checkpoint erases the original room
	// identities. Do not apply active mutations to the checkpoint snapshot.
	active_path := shard_generation_wal_path(shard_dir, manifest.active_generation)
	_, _, active_ok := scan_shard_transaction_wal(storage, active_path, manifest.shard, floors, false, false)
	delete(active_path)
	if !active_ok {shard_replay_state_destroy(); return}
	source_digest := shard_checkpoint_state_digest(manifest.shard)
	if !build_shard_checkpoint_from_replayed_state(storage, output_path, manifest.shard, floors) {shard_replay_state_destroy(); return}
	shard_replay_state_destroy()

	shard_replay_state_init()
	_, candidate_floors, candidate_ok := scan_shard_transaction_wal(storage, output_path, manifest.shard, {}, true, false)
	if !candidate_ok {shard_replay_state_destroy(); return floors, false}
	candidate_digest := shard_checkpoint_state_digest(manifest.shard)
	shard_replay_state_destroy()
	return floors, candidate_floors == floors && candidate_digest == source_digest
}
