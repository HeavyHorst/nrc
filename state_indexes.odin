package main

import "btree"

import pr "protocol"

// Entity_Reference_Key orders reverse relations by relation kind, parent, then child.
// The first two fields therefore form a contiguous range suitable for iter_seek.
Entity_Reference_Key :: struct {
	kind:      u8,
	parent_id: u64,
	entity_id: u64,
}

entity_reference_key_compare :: proc(a, b: Entity_Reference_Key) -> int {
	if a.kind < b.kind do return -1
	if a.kind > b.kind do return 1
	if a.parent_id < b.parent_id do return -1
	if a.parent_id > b.parent_id do return 1
	if a.entity_id < b.entity_id do return -1
	if a.entity_id > b.entity_id do return 1
	return 0
}

state_map_set :: proc(m: ^map[$K]$V, key: K, value: V) {
	_, value_ptr, _ := map_upsert(m, key, value)
	if value_ptr == nil do panic("failed to insert state map entry")
}

relation_tree_create :: proc() -> btree.BTreeG(Entity_Reference_Key) {
	return btree.create(Entity_Reference_Key, entity_reference_key_compare, btree.Options{degree = 32})
}

relation_tree_index :: proc(tree: ^btree.BTreeG(Entity_Reference_Key), key: Entity_Reference_Key) {
	_, replaced := btree.set(tree, key)
	if replaced do panic("duplicate reverse relation index entry")
}

relation_tree_remove :: proc(tree: ^btree.BTreeG(Entity_Reference_Key), key: Entity_Reference_Key) {
	_, _ = btree.remove(tree, key)
}

index_asset_parent :: proc(conv: ^Conversation_State, asset: ^pr.Asset) {
	if conv == nil || asset == nil do return
	if asset.parent_type == .None do return
	relation_tree_index(&conv.asset_parents, Entity_Reference_Key{kind = u8(asset.parent_type), parent_id = asset.parent_id, entity_id = u64(asset.asset_id)})
}

remove_asset_parent_from_index :: proc(conv: ^Conversation_State, asset: ^pr.Asset) {
	if conv == nil || asset == nil do return
	if asset.parent_type == .None do return
	relation_tree_remove(&conv.asset_parents, Entity_Reference_Key{kind = u8(asset.parent_type), parent_id = asset.parent_id, entity_id = u64(asset.asset_id)})
}
