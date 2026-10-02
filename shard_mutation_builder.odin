package main

import "core:encoding/endian"

import "persistence"
import pr "protocol"

Shard_Mutation_Transaction :: struct {
	tx:       Shard_Transaction,
	mutation: [dynamic]Shard_Mutation,
	payload:  []byte,
}

destroy_shard_mutation_transaction :: proc(built: ^Shard_Mutation_Transaction) {
	if built == nil do return
	delete(built.mutation)
	delete(built.payload)
	built^ = {}
}

finish_shard_mutation_transaction :: proc(
	built: ^Shard_Mutation_Transaction,
	workspace: []byte,
	domain: Shard_Mutation_Domain,
	op: u8,
	version: u16,
	previous: Shard_High_Water_Requirements,
) -> bool {
	built.mutation = make([dynamic]Shard_Mutation, 0, 1)
	_, append_err := append(&built.mutation, Shard_Mutation{domain = domain, op = op, entity_record_version = version, payload = built.payload})
	if append_err != nil do return false
	built.tx = {
		workspace        = workspace,
		task_high_water  = previous.task,
		asset_high_water = previous.asset,
		edge_high_water  = previous.edge,
		mutations        = built.mutation[:],
	}
	requirements, err := validate_shard_mutation(built.mutation[0])
	if err != .None do return false
	shard_max_requirement(&built.tx.task_high_water, requirements.task)
	shard_max_requirement(&built.tx.asset_high_water, requirements.asset)
	shard_max_requirement(&built.tx.edge_high_water, requirements.edge)
	// append_shard_transaction validates the complete envelope once against the
	// writer's current floors; do not repeat that payload traversal here.
	return true
}

build_shard_task_mutation :: proc(
	workspace: []byte,
	op: Task_Log_Op,
	task: ^pr.Task,
	previous: Shard_High_Water_Requirements,
) -> (
	built: Shard_Mutation_Transaction,
	ok: bool,
) {
	if len(workspace) == 0 || task == nil || !task_persistence_lengths_supported(task) do return
	built.payload = make([]byte, calculate_task_fields_size(task^))
	serialize_task_fields(task^, built.payload)
	ok = finish_shard_mutation_transaction(&built, workspace, .Task, u8(op), 1, previous)
	if !ok do destroy_shard_mutation_transaction(&built)
	return
}

build_shard_task_delete_mutation :: proc(
	workspace: []byte,
	conv_id: pr.ConversationID,
	task_id: pr.TaskID,
	previous: Shard_High_Water_Requirements,
) -> (
	built: Shard_Mutation_Transaction,
	ok: bool,
) {
	if len(workspace) == 0 do return
	built.payload = make([]byte, 16)
	endian.put_u64(built.payload, .Big, u64(conv_id))
	endian.put_u64(built.payload[8:], .Big, u64(task_id))
	ok = finish_shard_mutation_transaction(&built, workspace, .Task, u8(Task_Log_Op.Delete), 1, previous)
	if !ok do destroy_shard_mutation_transaction(&built)
	return
}

build_shard_asset_mutation :: proc(
	workspace: []byte,
	op: Asset_Log_Op,
	asset: ^pr.Asset,
	previous: Shard_High_Water_Requirements,
) -> (
	built: Shard_Mutation_Transaction,
	ok: bool,
) {
	if len(workspace) == 0 || asset == nil || !asset_persistence_lengths_supported(asset) do return
	built.payload = make([]byte, calculate_asset_fields_size(asset))
	assert(serialize_asset_fields(built.payload, asset) == len(built.payload))
	ok = finish_shard_mutation_transaction(&built, workspace, .Asset, u8(op), ASSET_LOG_VERSION, previous)
	if !ok do destroy_shard_mutation_transaction(&built)
	return
}

build_shard_asset_delete_mutation :: proc(
	workspace: []byte,
	conv_id: pr.ConversationID,
	asset_id: pr.AssetID,
	previous: Shard_High_Water_Requirements,
) -> (
	built: Shard_Mutation_Transaction,
	ok: bool,
) {
	if len(workspace) == 0 do return
	built.payload = make([]byte, 16)
	endian.put_u64(built.payload, .Big, u64(conv_id))
	endian.put_u64(built.payload[8:], .Big, u64(asset_id))
	ok = finish_shard_mutation_transaction(&built, workspace, .Asset, u8(Asset_Log_Op.Delete), 1, previous)
	if !ok do destroy_shard_mutation_transaction(&built)
	return
}

build_shard_edge_mutation :: proc(
	workspace: []byte,
	op: Edge_Log_Op,
	edge: ^pr.Edge,
	previous: Shard_High_Water_Requirements,
) -> (
	built: Shard_Mutation_Transaction,
	ok: bool,
) {
	if len(workspace) == 0 || edge == nil || len(edge.created_by) > int(max(u16)) do return
	workspace_id := string(workspace)
	prefix_size := 2 + len(workspace)
	record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_edge_payload_size(workspace_id, edge))
	serialize_edge_to_record(record, workspace_id, edge)
	built.payload = make([]byte, len(record) - persistence.LOG_HEADER_SIZE - prefix_size)
	copy(built.payload, record[persistence.LOG_HEADER_SIZE + prefix_size:])
	delete(record)
	ok = finish_shard_mutation_transaction(&built, workspace, .Edge, u8(op), 1, previous)
	if !ok do destroy_shard_mutation_transaction(&built)
	return
}

build_shard_edge_delete_mutation :: proc(
	workspace: []byte,
	conv_id: pr.ConversationID,
	edge_id: pr.EdgeID,
	previous: Shard_High_Water_Requirements,
) -> (
	built: Shard_Mutation_Transaction,
	ok: bool,
) {
	if len(workspace) == 0 do return
	built.payload = make([]byte, 16)
	endian.put_u64(built.payload, .Big, u64(conv_id))
	endian.put_u64(built.payload[8:], .Big, u64(edge_id))
	ok = finish_shard_mutation_transaction(&built, workspace, .Edge, u8(Edge_Log_Op.Delete), 1, previous)
	if !ok do destroy_shard_mutation_transaction(&built)
	return
}

persist_shard_task_mutation :: proc(workspace_id: string, op: Task_Log_Op, task: ^pr.Task) -> bool {
	workspace := transmute([]byte)workspace_id
	writer := shard_writer_for_workspace(&td.shard_writers, workspace)
	if writer == nil do return false
	built, ok := build_shard_task_mutation(workspace, op, task, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

persist_shard_task_delete_mutation :: proc(workspace_id: string, conv_id: pr.ConversationID, task_id: pr.TaskID) -> bool {
	workspace := transmute([]byte)workspace_id
	writer := shard_writer_for_workspace(&td.shard_writers, workspace)
	if writer == nil do return false
	built, ok := build_shard_task_delete_mutation(workspace, conv_id, task_id, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

persist_shard_asset_mutation :: proc(workspace_id: string, op: Asset_Log_Op, asset: ^pr.Asset) -> bool {
	workspace := transmute([]byte)workspace_id
	writer := shard_writer_for_workspace(&td.shard_writers, workspace)
	if writer == nil do return false
	built, ok := build_shard_asset_mutation(workspace, op, asset, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

persist_shard_asset_delete_mutation :: proc(workspace_id: string, conv_id: pr.ConversationID, asset_id: pr.AssetID) -> bool {
	workspace := transmute([]byte)workspace_id
	writer := shard_writer_for_workspace(&td.shard_writers, workspace)
	if writer == nil do return false
	built, ok := build_shard_asset_delete_mutation(workspace, conv_id, asset_id, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

persist_shard_edge_mutation :: proc(workspace_id: string, op: Edge_Log_Op, edge: ^pr.Edge) -> bool {
	workspace := transmute([]byte)workspace_id
	writer := shard_writer_for_workspace(&td.shard_writers, workspace)
	if writer == nil do return false
	built, ok := build_shard_edge_mutation(workspace, op, edge, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

persist_shard_edge_delete_mutation :: proc(workspace_id: string, conv_id: pr.ConversationID, edge_id: pr.EdgeID) -> bool {
	workspace := transmute([]byte)workspace_id
	writer := shard_writer_for_workspace(&td.shard_writers, workspace)
	if writer == nil do return false
	built, ok := build_shard_edge_delete_mutation(workspace, conv_id, edge_id, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}
