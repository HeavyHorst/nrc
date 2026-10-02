package main

import "btree"
import "core:net"
import pr "protocol"

// Completion consumes the dependency. Reopening does not recreate it. Snapshots
// borrow live string storage until publication; only blocked_by/updated_at change.
collect_task_unblocks :: proc(conv: ^Conversation_State, completed: ^pr.Task, updates: ^[dynamic]pr.Task, projected: ^Transaction_Prepared = nil) {
	if projected != nil {
		// Include creates and patches that introduce a dependency in this transaction,
		// regardless of operation order. Never overwrite their other patched fields.
		for i in 0 ..< pr.MAX_TRANSACTION_OPERATIONS {
			if projected.entity_ty[i] != .Task || projected.conv_ids[i] != completed.conv_id || projected.entity[i] == nil do continue
			next := (^pr.Task)(projected.entity[i])
			if next.blocked_by == completed.id {
				next.blocked_by = 0
				projected.unblocked_operations[i] = true
			}
		}
	}
	if conv == nil do return
	it := btree.iter(&conv.task_blockers)
	defer btree.iter_destroy(&it)
	for found := btree.iter_seek(&it, Entity_Reference_Key{parent_id = u64(completed.id)}); found; found = btree.iter_next(&it) {
		key := btree.item(&it)
		if key.parent_id != u64(completed.id) do break
		if key.entity_id == u64(completed.id) do continue
		live := conv.tasks[pr.TaskID(key.entity_id)]
		if projected != nil {
			if transaction_delete_contains(projected.delete_tasks[:], completed.conv_id, key.entity_id) do continue
			if transaction_projected_entity(projected, .Task, completed.conv_id, key.entity_id, live) != live do continue
		}
		next := live^
		next.blocked_by = 0
		next.updated_at = max(completed.updated_at, live.updated_at + 1)
		append(updates, next)
	}
}

persist_task_with_unblocks :: proc(workspace_id: string, task: ^pr.Task, op: Task_Log_Op, updates: []pr.Task) -> bool {
	if len(updates) == 0 do return persist_shard_task_mutation(workspace_id, op, task)
	if !task_persistence_lengths_supported(task) do return false
	writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)workspace_id)
	if writer == nil do return false
	p: Transaction_Prepared
	defer transaction_cleanup(&p)
	if !transaction_add_task_mutation(&p, 0, task, op) do return false
	for &next in updates do if !transaction_add_task_mutation(&p, 0, &next, .Update) do return false
	tx := Shard_Transaction {
		workspace        = transmute([]byte)workspace_id,
		task_high_water  = max(writer.floors.task, u64(task.id), u64(task.blocked_by)),
		asset_high_water = writer.floors.asset,
		edge_high_water  = writer.floors.edge,
		mutations        = p.mutations[:],
	}
	return append_shard_transaction(writer, &tx)
}

apply_task_unblocks :: proc(ws: ^Workspace_State, updates: []pr.Task) {
	for &next in updates {
		conv := get_conversation(ws, next.conv_id)
		task_store_unblock(conv, &next)
		// Include the requester: its normal acknowledgement only describes A.
		broadcast_task_updated(conv.tasks[next.id]^, net.TCP_Socket(-1), ws)
	}
}
