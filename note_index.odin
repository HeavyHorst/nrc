package main

import "btree"
import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import pr "protocol"

Note_Secondary_Index :: struct {
	key:  string,
	tree: btree.BTreeG(Note_Sort_Key),
}

note_sort_key_compare :: proc(a, b: Note_Sort_Key) -> int {
	if a.updated_at < b.updated_at {
		return -1
	}
	if a.updated_at > b.updated_at {
		return 1
	}

	if a.asset_id < b.asset_id {
		return -1
	}
	if a.asset_id > b.asset_id {
		return 1
	}

	return 0
}

init_note_index :: proc(conv: ^Conversation_State) {
	conv.note_index = btree.create(Note_Sort_Key, note_sort_key_compare, btree.Options{degree = 32})
	conv.note_index_keys = make(map[pr.AssetID]Note_Sort_Key, 64)
	conv.note_project_assets = make(map[string]^Note_Secondary_Index, 8)
	conv.note_tag_assets = make(map[string]^Note_Secondary_Index, 16)
	conv.asset_parents = relation_tree_create()
}

destroy_note_index :: proc(conv: ^Conversation_State) {
	btree.destroy(&conv.note_index)
	delete(conv.note_index_keys)
	for _, index in conv.note_project_assets {
		btree.destroy(&index.tree)
		delete(index.key)
		free(index)
	}
	delete(conv.note_project_assets)
	for _, index in conv.note_tag_assets {
		btree.destroy(&index.tree)
		delete(index.key)
		free(index)
	}
	delete(conv.note_tag_assets)
	btree.destroy(&conv.asset_parents)
}

make_note_sort_key :: proc(asset: ^pr.Asset) -> Note_Sort_Key {
	return Note_Sort_Key{updated_at = asset.updated_at, asset_id = asset.asset_id}
}

index_note_asset :: proc(conv: ^Conversation_State, asset: ^pr.Asset) {
	if asset == nil {
		return
	}
	index_asset_parent(conv, asset)
	calendar_index_asset(conv, asset)
	if asset.asset_type != .Note do return

	key := make_note_sort_key(asset)
	_, replaced := btree.set(&conv.note_index, key)
	if replaced {
		log.warnf("[T%d] Replaced existing key for note %d in note index", td.thread_index, asset.asset_id)
	}

	state_map_set(&conv.note_index_keys, asset.asset_id, key)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("failed to allocate note metadata arena")
	defer virtual.arena_destroy(&arena)
	tags := make([dynamic]string, 0, 4)
	defer delete(tags)
	project := json_note_metadata_fields(asset.preview, &tags, virtual.arena_allocator(&arena))

	index_note_project(conv, asset.asset_id, project, key)
	for tag in tags {
		index_note_tag(conv, asset.asset_id, tag, key)
	}
}

remove_note_asset_from_index :: proc(conv: ^Conversation_State, asset_id: pr.AssetID) {
	asset := conv.assets[asset_id]
	calendar_index_asset(conv, asset, true)
	key, ok := conv.note_index_keys[asset_id]
	when ODIN_DEBUG {
		if asset != nil && asset.asset_type == .Note {
			assert(ok, "stored note is missing its index key")
			assert(key == make_note_sort_key(asset), "note changed without reindexing")
		}
	}
	if asset != nil do remove_asset_parent_from_index(conv, asset)
	if !ok {
		return
	}

	remove_note_project_and_tags(conv, asset_id, key)
	_, _ = btree.remove(&conv.note_index, key)
	delete_key(&conv.note_index_keys, asset_id)
}

// ============================================================================
// Project/Tag Index
// ============================================================================

// Invalid documents or wrongly typed metadata publish no partial facets.
// Missing/null fields are empty; decoded values are trimmed and tags deduplicated.
json_note_metadata_fields :: proc(data: []byte, tags: ^[dynamic]string, allocator: mem.Allocator) -> string {
	fields, object, valid := json_metadata_fields(data, [?]string{"project", "tags"}, allocator)
	if !valid || !object do return ""
	if fields[0].kind != .Invalid && fields[0].kind != .Null && fields[0].kind != .String do return ""
	if fields[1].kind != .Invalid && fields[1].kind != .Null && fields[1].kind != .Open_Bracket do return ""
	start := len(tags^)
	if fields[1].kind == .Open_Bracket {
		tok := json.make_tokenizer(fields[1].text, .JSON, true)
		_, _ = json.get_token(&tok) // Opening bracket; the full grammar is already validated.
		for {
			token, _ := json.get_token(&tok)
			if token.kind == .Close_Bracket do break
			if token.kind == .Comma do continue
			if token.kind != .String {
				resize(tags, start)
				return ""
			}
			value := strings.trim_space(json_metadata_string(token, allocator))
			if value != "" && !note_metadata_has_tag(tags[:], value) {
				if _, err := append(tags, value); err != nil do panic("failed to append note metadata tag")
			}
		}
	}
	return strings.trim_space(json_metadata_string(fields[0], allocator))
}

note_metadata_has_tag :: proc(tags: []string, tag: string) -> bool {
	for existing in tags {
		if existing == tag {
			return true
		}
	}
	return false
}

note_secondary_index_create :: proc(key: string) -> ^Note_Secondary_Index {
	owned_key, clone_err := strings.clone(key)
	if clone_err != nil do panic("failed to clone note secondary index key")
	index := new(Note_Secondary_Index)
	if index == nil do panic("failed to allocate note secondary index")
	index.key = owned_key
	index.tree = btree.create(Note_Sort_Key, note_sort_key_compare, btree.Options{degree = 32})
	return index
}

note_secondary_index_get_or_create :: proc(indexes: ^map[string]^Note_Secondary_Index, key: string) -> ^Note_Secondary_Index {
	if index, ok := indexes^[key]; ok do return index
	index := note_secondary_index_create(key)
	_, value_ptr, replaced := map_upsert(indexes, index.key, index)
	if value_ptr == nil {
		btree.destroy(&index.tree)
		delete(index.key)
		free(index)
		panic("failed to insert note secondary index")
	}
	if replaced do panic("unexpected duplicate note secondary index")
	return index
}

note_secondary_index_count :: proc(index: ^Note_Secondary_Index) -> int {
	if index == nil do return 0
	return btree.count(&index.tree)
}

note_secondary_index_contains_asset :: proc(index: ^Note_Secondary_Index, asset_id: pr.AssetID) -> bool {
	if index == nil do return false
	it := btree.iter(&index.tree)
	defer btree.iter_destroy(&it)
	for has_item := btree.iter_first(&it); has_item; has_item = btree.iter_next(&it) {
		if btree.item(&it).asset_id == asset_id do return true
	}
	return false
}

note_secondary_index_newest :: proc(index: ^Note_Secondary_Index) -> (Note_Sort_Key, bool) {
	if index == nil do return {}, false
	it := btree.iter(&index.tree)
	defer btree.iter_destroy(&it)
	if !btree.iter_last(&it) do return {}, false
	return btree.item(&it), true
}

note_secondary_index_asset_ids :: proc(index: ^Note_Secondary_Index) -> [dynamic]pr.AssetID {
	ids := make([dynamic]pr.AssetID)
	if index == nil do return ids
	it := btree.iter(&index.tree)
	defer btree.iter_destroy(&it)
	for has_item := btree.iter_last(&it); has_item; has_item = btree.iter_prev(&it) {
		if _, err := append(&ids, btree.item(&it).asset_id); err != nil do panic("failed to append note index id")
	}
	return ids
}

index_note_project :: proc(conv: ^Conversation_State, asset_id: pr.AssetID, project: string, key: Note_Sort_Key) {
	_ = asset_id
	if project == "" {
		return
	}

	index := note_secondary_index_get_or_create(&conv.note_project_assets, project)
	_, _ = btree.set(&index.tree, key)
}

index_note_tag :: proc(conv: ^Conversation_State, asset_id: pr.AssetID, tag: string, key: Note_Sort_Key) {
	_ = asset_id
	if tag == "" {
		return
	}

	index := note_secondary_index_get_or_create(&conv.note_tag_assets, tag)
	_, _ = btree.set(&index.tree, key)
}

// Remove only this note's project/tag keys, leaving unrelated buckets intact.
remove_note_project_and_tags :: proc(conv: ^Conversation_State, asset_id: pr.AssetID, key: Note_Sort_Key) {
	asset := conv.assets[asset_id]
	if asset == nil {
		return
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("failed to allocate note metadata arena")
	defer virtual.arena_destroy(&arena)
	tags := make([dynamic]string, 0, 4)
	defer delete(tags)
	project := json_note_metadata_fields(asset.preview, &tags, virtual.arena_allocator(&arena))

	remove_note_project(conv, project, asset_id, key)
	for tag in tags {
		remove_note_tag(conv, tag, asset_id, key)
	}
}

remove_note_project :: proc(conv: ^Conversation_State, project: string, asset_id: pr.AssetID, key: Note_Sort_Key) {
	if project == "" {
		return
	}

	if index, ok := conv.note_project_assets[project]; ok {
		_, _ = btree.remove(&index.tree, key)
		if btree.count(&index.tree) == 0 {
			delete_key(&conv.note_project_assets, project)
			btree.destroy(&index.tree)
			delete(index.key)
			free(index)
		}
	}
}

remove_note_tag :: proc(conv: ^Conversation_State, tag: string, asset_id: pr.AssetID, key: Note_Sort_Key) {
	if tag == "" {
		return
	}

	if index, ok := conv.note_tag_assets[tag]; ok {
		_, _ = btree.remove(&index.tree, key)
		if btree.count(&index.tree) == 0 {
			delete_key(&conv.note_tag_assets, tag)
			btree.destroy(&index.tree)
			delete(index.key)
			free(index)
		}
	}
}
