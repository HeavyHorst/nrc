package main

import "btree"
import pr "protocol"

// The sole production writers of conversation entity maps (except teardown).
// Call only after WAL acceptance, on the owning worker. Put takes ownership of
// a distinct, single-allocation entity and frees the previous owner. Remove is
// idempotent. These operations neither persist nor broadcast nor cascade deletes.
// Borrowed map pointers must not be mutated or retained across replacement.
task_store_put :: proc(conv: ^Conversation_State, task: ^pr.Task) {
	if old := conv.tasks[task.id]; old != nil {
		assert(old != task, "task_store_put requires a distinct owned post-image")
		remove_task_from_index(conv, old)
		free_task(old)
	}
	state_map_set(&conv.tasks, task.id, task)
	index_task(conv, task)
	when ODIN_DEBUG do task_store_assert_counts(conv)
}

task_store_remove :: proc(conv: ^Conversation_State, id: pr.TaskID) {
	if old := conv.tasks[id]; old != nil {
		remove_task_from_index(conv, old)
		delete_key(&conv.tasks, id)
		free_task(old)
	}
	when ODIN_DEBUG do task_store_assert_counts(conv)
}

task_store_unblock :: proc(conv: ^Conversation_State, snapshot: ^pr.Task) {
	task := conv.tasks[snapshot.id]
	remove_task_from_index(conv, task)
	task.blocked_by = 0
	task.updated_at = snapshot.updated_at
	index_task(conv, task)
	when ODIN_DEBUG do task_store_assert_counts(conv)
}

// Preserve the task allocation on moves. The snapshot borrows all string
// storage; only these scalar fields may change, and old index keys are removed
// before the stored entity is touched.
task_store_move :: proc(conv: ^Conversation_State, snapshot: ^pr.Task) {
	task := conv.tasks[snapshot.id]
	assert(task != nil && task != snapshot)
	remove_task_from_index(conv, task)
	task.status = snapshot.status
	task.order_index = snapshot.order_index
	task.completed_at = snapshot.completed_at
	task.updated_at = snapshot.updated_at
	index_task(conv, task)
	when ODIN_DEBUG do task_store_assert_counts(conv)
}

task_store_assert_counts :: proc(conv: ^Conversation_State) {
	assert(len(conv.tasks) == len(conv.task_index_keys))
	assert(len(conv.tasks) == btree.count(&conv.task_index))
	assert(conv.active_task_count >= 0 && conv.active_task_count <= len(conv.tasks))
}

asset_store_put :: proc(ws: ^Workspace_State, workspace_id: string, conv: ^Conversation_State, asset: ^pr.Asset) {
	if old := conv.assets[asset.asset_id]; old != nil {
		assert(old != asset, "asset_store_put requires a distinct owned post-image")
		remove_room_mapping_asset(ws, old)
		// Removal reads the old asset's metadata from the map.
		remove_note_asset_from_index(conv, old.asset_id)
		free_asset(old)
	}
	state_map_set(&conv.assets, asset.asset_id, asset)
	index_note_asset(conv, asset)
	index_room_mapping_asset(ws, workspace_id, asset)
	when ODIN_DEBUG do asset_store_assert_counts(conv)
}

asset_store_remove :: proc(ws: ^Workspace_State, conv: ^Conversation_State, id: pr.AssetID) {
	if old := conv.assets[id]; old != nil {
		remove_room_mapping_asset(ws, old)
		remove_note_asset_from_index(conv, id)
		delete_key(&conv.assets, id)
		free_asset(old)
	}
	when ODIN_DEBUG do asset_store_assert_counts(conv)
}

asset_store_assert_counts :: proc(conv: ^Conversation_State) {
	assert(len(conv.note_index_keys) == btree.count(&conv.note_index))
	assert(len(conv.note_index_keys) <= len(conv.assets))
	assert(btree.count(&conv.asset_parents) <= len(conv.assets))
}

edge_store_put :: proc(conv: ^Conversation_State, edge: ^pr.Edge) {
	if old := conv.edges[edge.edge_id]; old != nil {
		assert(old != edge, "edge_store_put requires a distinct owned post-image")
		remove_edge_from_adjacency(conv, old.source_type, old.source_id, old.edge_id)
		remove_edge_from_adjacency(conv, old.target_type, old.target_id, old.edge_id)
		free_edge(old)
	}
	state_map_set(&conv.edges, edge.edge_id, edge)
	add_edge_to_adjacency(conv, edge.source_type, edge.source_id, edge.edge_id)
	add_edge_to_adjacency(conv, edge.target_type, edge.target_id, edge.edge_id)
}

edge_store_remove :: proc(conv: ^Conversation_State, id: pr.EdgeID) {
	if old := conv.edges[id]; old != nil {
		remove_edge_from_adjacency(conv, old.source_type, old.source_id, id)
		remove_edge_from_adjacency(conv, old.target_type, old.target_id, id)
		delete_key(&conv.edges, id)
		free_edge(old)
	}
}
