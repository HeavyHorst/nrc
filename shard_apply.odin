package main

import "core:strings"

apply_shard_mutation :: proc(workspace: []byte, mutation: Shard_Mutation) -> bool {
	if len(workspace) == 0 || len(workspace) > int(max(u16)) do return false
	id: u64
	switch mutation.domain {
	case .Task:
		id = apply_task_log_record_for_workspace(string(workspace), Task_Log_Op(mutation.op), mutation.entity_record_version, mutation.payload)
	case .Asset:
		id = apply_asset_log_record_for_workspace(string(workspace), Asset_Log_Op(mutation.op), mutation.entity_record_version, mutation.payload)
	case .Edge:
		id = apply_edge_log_record_for_workspace(string(workspace), Edge_Log_Op(mutation.op), mutation.payload)
	}
	return id != 0
}

apply_shard_transaction_mutation :: proc(mutation: Shard_Mutation, user_data: rawptr) -> bool {
	view := cast(^Shard_Transaction_View)user_data
	return view != nil && apply_shard_mutation(view.workspace, mutation)
}

// Isolated state used by shard replay tests and offline validation.
shard_replay_state_init :: proc() {
	if err := strings.intern_init(&td.workspace_intern); err != nil do panic("failed to initialize replay intern pool")
	td.workspaces = make(map[string]^Workspace_State, 256)
}

shard_replay_state_destroy :: proc() {
	cleanup_workspaces()
	td.workspaces = nil
	strings.intern_destroy(&td.workspace_intern)
	td.workspace_intern = {}
}

// Compaction may remove an obsolete endpoint post-image that originally appeared
// before an edge while retaining a newer complete endpoint image after it. Replay
// therefore materializes edges independent of transient endpoint order and checks
// the final shard state before it can become authoritative.
validate_replayed_shard_edges :: proc(shard: int) -> bool {
	if shard < 0 || shard >= LOGICAL_SHARD_COUNT || td.workspaces == nil do return false
	for workspace_id, ws in td.workspaces {
		if int(shard_for_workspace(transmute([]byte)workspace_id)) != shard do continue
		for _, conv in ws.conversations {
			for _, edge in conv.edges {
				if !entity_exists(conv, edge.source_type, edge.source_id) || !entity_exists(conv, edge.target_type, edge.target_id) {
					return false
				}
			}
		}
	}
	return true
}
