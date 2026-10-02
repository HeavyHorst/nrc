package main

import "core:encoding/endian"
import "core:log"
import "core:strings"
import pr "protocol"

// Public legacy room data shares one workspace scope. Preserve legacy DM
// records under their private IDs; they are never addressable by the public
// data API. Apply this to every replayed post-image AND tombstone, rather than
// merging maps after replay (which would resurrect deleted legacy objects).
workspace_data_replay_scope :: proc(conv_id: pr.ConversationID) -> pr.ConversationID {
	if pr.is_dm_conversation(conv_id) do return conv_id
	return pr.WORKSPACE_DATA_ID
}

// Every standalone data request starts with conv_id:u64. Transactions carry
// that field in each operation body and are validated separately after parsing.
is_workspace_data_opcode :: proc(opcode: pr.Opcode) -> bool {
	return(
		opcode == .C_ListTaskAssignees ||
		opcode == .C_QueryCalendar ||
		(opcode >= .C_CreateTask && opcode <= .C_ListTaskProjects && opcode != .C_ApplyTransaction) ||
		(opcode >= .C_CreateAsset && opcode <= .C_GraphCommonNeighbors) ||
		(opcode >= .C_GraphRank && opcode <= .C_SearchCustomers) \
	)
}

workspace_data_scope_valid :: proc(body: []byte) -> bool {
	if len(body) < 8 do return false
	scope, ok := endian.get_u64(body, .Big)
	return ok && scope == u64(pr.WORKSPACE_DATA_ID)
}

Workspace_Data_Origin_Key :: struct {
	workspace: string,
	domain:    Shard_Mutation_Domain,
	id:        u64,
}

Workspace_Data_Replay_Origins :: struct {
	rooms: map[Workspace_Data_Origin_Key]pr.ConversationID,
}

@(thread_local)
workspace_data_replay_origins: ^Workspace_Data_Replay_Origins

// Nested scans borrow their sequence's tracker, including non-applying startup
// validation. Never reset origins at a transaction, segment or tombstone.
workspace_data_origins_begin :: proc(origins: ^Workspace_Data_Replay_Origins) -> bool {
	if workspace_data_replay_origins != nil do return false
	origins.rooms = make(map[Workspace_Data_Origin_Key]pr.ConversationID)
	workspace_data_replay_origins = origins
	return true
}

workspace_data_origins_end :: proc(origins: ^Workspace_Data_Replay_Origins, owned: bool) {
	if !owned do return
	for key in origins.rooms do delete(key.workspace)
	delete(origins.rooms)
	workspace_data_replay_origins = nil
}

validate_workspace_data_origin :: proc(mutation: Shard_Mutation, user_data: rawptr) -> bool {
	view := (^Shard_Transaction_View)(user_data)
	scope, scope_ok := shard_segment_mutation_conversation_id(mutation)
	id, id_ok := shard_mutation_entity_id(mutation)
	if !scope_ok || !id_ok do return false
	// Zero is the canonical alias, not a second origin. Legacy zero records are
	// assumed to describe the same object; the old format carries no cutover bit.
	if scope == u64(pr.WORKSPACE_DATA_ID) || pr.is_dm_conversation(pr.ConversationID(scope)) do return true
	key := Workspace_Data_Origin_Key{string(view.workspace), mutation.domain, id}
	origins := workspace_data_replay_origins
	if origins == nil do return false
	if previous, exists := origins.rooms[key]; exists {
		if previous == pr.ConversationID(scope) do return true
		log.errorf(
			"Workspace data migration conflict: workspace=%s domain=%v id=%d rooms=%d,%d; preserve WAL and resolve before startup",
			key.workspace,
			key.domain,
			id,
			previous,
			scope,
		)
		return false
	}
	key.workspace = strings.clone(key.workspace)
	origins.rooms[key] = pr.ConversationID(scope)
	return true
}
