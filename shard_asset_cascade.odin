package main

import "core:encoding/endian"

import pr "protocol"

Shard_Asset_Delete_Transaction :: struct {
	tx:        Shard_Transaction,
	mutations: [dynamic]Shard_Mutation,
	payloads:  []byte,
}

destroy_shard_asset_delete_transaction :: proc(cascade: ^Shard_Asset_Delete_Transaction) {
	if cascade == nil do return
	delete(cascade.mutations)
	delete(cascade.payloads)
	cascade^ = {}
}

shard_asset_delete_add :: proc(cascade: ^Shard_Asset_Delete_Transaction, domain: Shard_Mutation_Domain, op: u8, conv_id, entity_id: u64, index: int) -> bool {
	payload := cascade.payloads[index * 16:][:16]
	endian.put_u64(payload, .Big, conv_id)
	endian.put_u64(payload[8:], .Big, entity_id)
	_, append_err := append(&cascade.mutations, Shard_Mutation{domain = domain, op = op, entity_record_version = 1, payload = payload})
	return append_err == nil
}

build_shard_asset_delete_transaction :: proc(
	workspace: []byte,
	conv_id: pr.ConversationID,
	asset_ids: []pr.AssetID,
	first_edge_ids, second_edge_ids: []pr.EdgeID,
	previous: Shard_High_Water_Requirements,
) -> (
	cascade: Shard_Asset_Delete_Transaction,
	ok: bool,
) {
	if len(workspace) == 0 do return
	count := len(asset_ids)
	for edge_count in ([2]int{len(first_edge_ids), len(second_edge_ids)}) {
		if edge_count > SHARD_TRANSACTION_MAX_MUTATIONS - count do return
		count += edge_count
	}
	if count == 0 do return
	cascade.mutations = make([dynamic]Shard_Mutation, 0, count)
	cascade.payloads = make([]byte, count * 16)
	index := 0
	for edge_ids in ([2][]pr.EdgeID{first_edge_ids, second_edge_ids}) {
		for edge_id in edge_ids {
			if !shard_asset_delete_add(&cascade, .Edge, u8(Edge_Log_Op.Delete), u64(conv_id), u64(edge_id), index) {
				destroy_shard_asset_delete_transaction(&cascade)
				return cascade, false
			}
			index += 1
		}
	}
	for asset_id in asset_ids {
		if !shard_asset_delete_add(&cascade, .Asset, u8(Asset_Log_Op.Delete), u64(conv_id), u64(asset_id), index) {
			destroy_shard_asset_delete_transaction(&cascade)
			return cascade, false
		}
		index += 1
	}
	cascade.tx = {
		workspace        = workspace,
		task_high_water  = previous.task,
		asset_high_water = previous.asset,
		edge_high_water  = previous.edge,
		mutations        = cascade.mutations[:],
	}
	for mutation in cascade.mutations {
		requirements, validation_err := validate_shard_mutation(mutation)
		if validation_err != .None {
			destroy_shard_asset_delete_transaction(&cascade)
			return cascade, false
		}
		shard_max_requirement(&cascade.tx.task_high_water, requirements.task)
		shard_max_requirement(&cascade.tx.asset_high_water, requirements.asset)
		shard_max_requirement(&cascade.tx.edge_high_water, requirements.edge)
	}
	if _, validation_err := validate_shard_transaction(&cascade.tx, previous); validation_err != .None {
		destroy_shard_asset_delete_transaction(&cascade)
		return cascade, false
	}
	return cascade, true
}
