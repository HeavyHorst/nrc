package main

import "btree"
import "core:encoding/endian"
import "core:testing"

import pr "protocol"

@(test)
test_replayed_workspace_and_interned_names_own_borrowed_bytes :: proc(t: ^testing.T) {
	shard_replay_state_init()
	defer shard_replay_state_destroy()
	workspace := []byte{'r', 'e', 'p', 'l', 'a', 'y'}
	parsed := Parsed_Task_Data {
		id      = 1,
		conv_id = 2,
		status  = .Backlog,
	}
	testing.expect(t, apply_persisted_task(string(workspace), &parsed))
	ws := get_workspace("replay")
	owned := intern_workspace_id("replay")
	testing.expect(t, raw_data(owned) != raw_data(workspace), "workspace key must not borrow the replay buffer")
	for &b in workspace do b = 'x'
	testing.expect(t, get_workspace("replay") == ws && ws != nil)
	testing.expect(t, get_conversation(ws, 2).tasks[1] != nil)
	testing.expect(t, raw_data(intern_workspace_id("replay")) == raw_data(owned), "interning deduplicates owned storage")
	username := []byte{'u', 's', 'e', 'r'}
	room := []byte{'r', 'o', 'o', 'm'}
	owned_user := intern_username(string(username))
	owned_room := intern_room_mapping_name(string(room))
	for &b in username do b = 'x'
	for &b in room do b = 'x'
	testing.expect_value(t, owned_user, "user")
	testing.expect_value(t, owned_room, "room")
}

transaction_delta_task_blocked_by_patch_body :: proc(conv_id: pr.ConversationID, task_id, blocked_by: pr.TaskID) -> [42]byte {
	b: [42]byte
	endian.put_u64(b[:], .Big, u64(conv_id))
	transaction_test_ref(b[8:], .Existing, .Task, u64(task_id))
	endian.put_u16(b[28:], .Big, pr.TRANSACTION_TASK_PATCH_BLOCKED_BY)
	transaction_test_ref(b[30:], .Existing, .Task, u64(blocked_by))
	return b
}

transaction_delta_asset_preview_patch_body :: proc(conv_id: pr.ConversationID, asset_id: pr.AssetID, preview: string) -> [512]byte {
	b: [512]byte
	endian.put_u64(b[:], .Big, u64(conv_id))
	transaction_test_ref(b[8:], .Existing, .Asset, u64(asset_id))
	b[28] = pr.TRANSACTION_ASSET_PATCH_PREVIEW
	endian.put_u16(b[29:], .Big, u16(len(preview)))
	copy(b[31:], transmute([]byte)preview)
	return b
}

transaction_delta_relation_contains :: proc(tree: ^btree.BTreeG(Entity_Reference_Key), expected: Entity_Reference_Key) -> bool {
	it := btree.iter(tree)
	defer btree.iter_destroy(&it)
	if !btree.iter_seek(&it, expected) do return false
	return btree.item(&it) == expected
}

@(test)
test_transaction_delta_unblocks_and_deletes_blocker_atomically :: proc(t: ^testing.T) {
	workspace := "transaction-delta-blocker"
	testing.expect(t, init_room_mapping_test_state("transaction_delta_blocker.log", workspace), "initialize transaction fixture")
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	td.task_seq = 0
	ws := get_or_create_connection_workspace(&c)
	conv := get_or_create_conversation(ws, 81)
	untouched := alloc_task(transmute([]byte)string("untouched"), nil, nil, nil, nil, nil, nil, nil)
	untouched.id = 50; untouched.conv_id = 81; untouched.status = .Backlog; untouched.updated_at = 7
	conv.tasks[50] = untouched; index_task(conv, untouched)
	untouched_key := conv.task_index_keys[50]

	blocker_create := transaction_test_task_create_body(81, .Existing, 0, 'b')
	dependent_create := transaction_test_task_create_body(81, .CreatedBy, 0, 'd')
	create_ops := [2]pr.TransactionOperation{{op_type = .TaskCreate, body = blocker_create[:]}, {op_type = .TaskCreate, body = dependent_create[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 10, operations = create_ops[:]})
	blocker, dependent := conv.tasks[1], conv.tasks[2]
	testing.expect(t, blocker != nil && dependent != nil && dependent.blocked_by == 1, "transaction creates blocker and dependent")
	testing.expect(t, transaction_delta_relation_contains(&conv.task_blockers, {parent_id = 1, entity_id = 2}), "reverse blocker index contains dependent")

	delete_blocker := transaction_test_delete_body(81, .Task, 1)
	rejected_ops := [1]pr.TransactionOperation{{op_type = .TaskDelete, body = delete_blocker[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 11, operations = rejected_ops[:]})
	testing.expect(t, conv.tasks[1] == blocker && conv.tasks[2] == dependent, "rejected delete preserves changed entities")
	testing.expect(t, conv.tasks[50] == untouched && conv.task_index_keys[50] == untouched_key, "rejected delete preserves untouched task and index key")
	testing.expect(
		t,
		transaction_delta_relation_contains(&conv.task_blockers, {parent_id = 1, entity_id = 2}),
		"rejected delete preserves reverse blocker index",
	)

	clear_blocker := transaction_delta_task_blocked_by_patch_body(81, 2, 0)
	commit_ops := [2]pr.TransactionOperation{{op_type = .TaskPatch, body = clear_blocker[:]}, {op_type = .TaskDelete, body = delete_blocker[:]}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 12, operations = commit_ops[:]})
	testing.expect(t, conv.tasks[1] == nil && conv.tasks[2] != nil && conv.tasks[2].blocked_by == 0, "clear and blocker delete commit atomically")
	testing.expect_value(t, btree.count(&conv.task_blockers), 0)
	testing.expect(t, conv.tasks[50] == untouched && conv.task_index_keys[50] == untouched_key, "delta publication preserves untouched task and index entry")
}

@(test)
test_transaction_delta_note_update_preserves_unrelated_state_and_reverse_indexes :: proc(t: ^testing.T) {
	workspace := "transaction-delta-note"
	testing.expect(t, init_room_mapping_test_state("transaction_delta_note.log", workspace), "initialize transaction fixture")
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	td.task_seq = 40
	td.asset_seq = 12
	ws := get_or_create_connection_workspace(&c)
	conv := get_or_create_conversation(ws, 82)
	conversation_identity := conv

	task := alloc_task(transmute([]byte)string("stable task"), nil, nil, nil, nil, nil, nil, nil)
	task.id = 40; task.conv_id = 82; task.status = .Backlog; task.updated_at = 10
	conv.tasks[40] = task; index_task(conv, task)
	root_preview := `{"project":"alpha","tags":["shared","old"]}`
	root := alloc_asset(nil, transmute([]byte)root_preview, transmute([]byte)string("root"), nil)
	root.asset_id = 10; root.conv_id = 82; root.asset_type = .Note; root.payload_encoding = .Plain; root.payload_raw_len = 4; root.updated_at = 20
	conv.assets[10] = root; index_note_asset(conv, root)
	child := alloc_asset(nil, transmute([]byte)string(`{"project":"stable","tags":["shared","stable"]}`), nil, nil)
	child.asset_id = 11; child.conv_id = 82; child.asset_type = .Note; child.parent_type = .Asset; child.parent_id = 10; child.payload_encoding = .Plain; child.updated_at = 21
	conv.assets[11] = child; index_note_asset(conv, child)
	unrelated := alloc_asset(nil, transmute([]byte)string(`{"project":"unrelated","tags":["untouched"]}`), nil, nil)
	unrelated.asset_id = 12; unrelated.conv_id = 82; unrelated.asset_type = .Note; unrelated.payload_encoding = .Plain; unrelated.updated_at = 22
	conv.assets[12] = unrelated; index_note_asset(conv, unrelated)
	unrelated_project_bucket := conv.note_project_assets["unrelated"]
	unrelated_tag_bucket := conv.note_tag_assets["untouched"]

	replacement := `{"project":"beta","tags":["shared","new"]}`
	patch_storage := transaction_delta_asset_preview_patch_body(82, 11, replacement)
	patch_body := patch_storage[:31 + len(replacement)]
	ops := [1]pr.TransactionOperation{{op_type = .AssetPatch, body = patch_body}}
	process_apply_transaction(&c, pr.ApplyTransactionRequest{correlation_id = 20, operations = ops[:]})

	updated := conv.assets[11]
	testing.expect(t, get_conversation(ws, 82) == conversation_identity, "delta publication preserves conversation identity")
	testing.expect(t, updated != nil && updated != child && string(updated.preview) == replacement, "transaction replaces only the updated note")
	testing.expect(t, conv.tasks[40] == task && conv.assets[10] == root && conv.assets[12] == unrelated, "unrelated entity identities are preserved")
	testing.expect(
		t,
		conv.note_project_assets["unrelated"] == unrelated_project_bucket && conv.note_tag_assets["untouched"] == unrelated_tag_bucket,
		"unrelated secondary BTree buckets are preserved",
	)
	_, has_stable_project := conv.note_project_assets["stable"]
	_, has_stable_tag := conv.note_tag_assets["stable"]
	testing.expect(t, !has_stable_project && !has_stable_tag, "old project and tag index entries are removed")
	testing.expect(
		t,
		note_secondary_index_contains_asset(conv.note_project_assets["beta"], 11) && note_secondary_index_contains_asset(conv.note_tag_assets["new"], 11),
		"new project and tag indexes contain updated note",
	)
	testing.expect(
		t,
		note_secondary_index_contains_asset(conv.note_tag_assets["shared"], 10) && note_secondary_index_contains_asset(conv.note_tag_assets["shared"], 11),
		"retained shared tag contains both notes",
	)
	testing.expect(
		t,
		transaction_delta_relation_contains(&conv.asset_parents, {kind = u8(pr.ParentType.Asset), parent_id = 10, entity_id = 11}),
		"child cascade reverse reference survives child note update",
	)
	testing.expect_value(t, btree.count(&conv.asset_parents), 1)
}
