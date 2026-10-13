package main

import "core:encoding/endian"
import pr "protocol"

// Full post-images keep membership revocations through both cleaner paths.
decode_dm_state :: proc(payload: []byte) -> (id: pr.ConversationID, a, b: string, members: u8, ok: bool) {
	if len(payload) < 13 do return
	raw_id, _ := endian.get_u64(payload, .Big)
	id = pr.ConversationID(raw_id)
	o := 8
	a_bytes, a_ok := shard_read_u16_bytes(payload, &o)
	b_bytes, b_ok := shard_read_u16_bytes(payload, &o)
	if !a_ok || !b_ok || o + 1 != len(payload) do return
	a, b = string(a_bytes), string(b_bytes)
	members = payload[o]
	// make_dm_conversation_id uses a bounded 512-byte pair buffer.
	if len(a) == 0 || len(b) == 0 || len(a) + 1 + len(b) > 512 || a >= b || members > 3 do return
	ok = pr.is_dm_conversation(id) && id == pr.make_dm_conversation_id(a, b)
	return
}

encode_dm_state :: proc(id: pr.ConversationID, a, b: string, members: u8) -> []byte {
	payload := make([]byte, 13 + len(a) + len(b))
	endian.put_u64(payload, .Big, u64(id))
	o := 8
	names := [2]string{a, b}
	for name in names {
		endian.put_u16(payload[o:], .Big, u16(len(name))); o += 2
		copy(payload[o:], name); o += len(name)
	}
	payload[o] = members
	return payload
}

dm_membership_mask :: proc(ws: ^Workspace_State, id: pr.ConversationID, pair: ^DM_Participants) -> u8 {
	members: u8
	if is_user_in_dm(ws, pair.user_a, id) do members |= 1
	if is_user_in_dm(ws, pair.user_b, id) do members |= 2
	return members
}

apply_dm_state :: proc(workspace: string, payload: []byte) -> bool {
	id, a, b, members, ok := decode_dm_state(payload)
	if !ok do return false
	ws := get_or_create_workspace(workspace)
	conv := get_or_create_conversation(ws, id)
	pair := conv.dm_participants
	if pair != nil && (pair.user_a != a || pair.user_b != b) do return false
	if pair == nil {
		pair = new(DM_Participants)
		pair.user_a = intern_username(a); pair.user_b = intern_username(b)
		conv.dm_participants = pair
	}
	pair.persistent = true
	names := [2]string{pair.user_a, pair.user_b}
	for name, index in names {
		if members & (u8(1) << uint(index)) != 0 {
			add_user_dm(ws, name, id)
		} else {
			remove_user_dm(ws, name, id)
		}
	}
	return true
}

persist_dm_state :: proc(workspace: string, id: pr.ConversationID, a, b: string, members: u8) -> bool {
	writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)workspace)
	if writer == nil do return false
	built: Shard_Mutation_Transaction
	built.payload = encode_dm_state(id, a, b, members)
	defer destroy_shard_mutation_transaction(&built)
	if !finish_shard_mutation_transaction(&built, transmute([]byte)workspace, .DM, 1, 1, writer.floors) do return false
	if !append_shard_transaction(writer, &built.tx) do return false
	if !apply_dm_state(workspace, built.payload) do return false
	ws := get_workspace(workspace)
	pair := get_conversation(ws, id).dm_participants
	pair.durability_generation = writer.durability_generation
	pair.durability_record = writer.wal.record_count + writer.wal.buffered_record_count
	return true
}

dm_metadata_durable :: proc(c: ^NRC_Connection, id: pr.ConversationID) -> bool {
	conv := get_conversation(get_connection_workspace(c), id)
	if conv == nil || conv.dm_participants == nil || !conv.dm_participants.persistent do return false
	pair := conv.dm_participants
	if pair.durability_record == 0 do return true // Replayed state is already durable.
	writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)c.workspace_id)
	return(
		writer != nil &&
		!writer.poisoned &&
		writer.wal.enabled &&
		(pair.durability_generation < writer.durability_generation || pair.durability_record <= writer.wal.durable_record_count) \
	)
}
