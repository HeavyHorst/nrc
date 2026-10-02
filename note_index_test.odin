package main

// Tests the note asset index used by paginated semantic queries. Stateful fixtures
// compare every index against independent reference models; pagination assertions
// decode responses emitted by the real handlers.

import "btree"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:testing"

import hgl "hegel"
import pr "protocol"
import ws "websocket"

make_test_asset :: proc(asset_id: pr.AssetID, updated_at: i64, asset_type: pr.AssetType = .Note) -> ^pr.Asset {
	asset := new(pr.Asset)
	asset.asset_id = asset_id
	asset.asset_type = asset_type
	asset.updated_at = updated_at
	asset.conv_id = 1
	return asset
}

@(test)
test_note_index_orders_by_updated_at_then_asset_id :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	a := make_test_asset(5, 100)
	b := make_test_asset(1, 50)
	c := make_test_asset(3, 100)
	non_note := make_test_asset(2, 999, .Document)
	defer {
		free(a)
		free(b)
		free(c)
		free(non_note)
	}

	index_note_asset(&conv, a)
	index_note_asset(&conv, b)
	index_note_asset(&conv, c)
	index_note_asset(&conv, non_note)

	actual := make([dynamic]Note_Sort_Key, 0, 4)
	defer delete(actual)

	it := btree.iter(&conv.note_index)
	defer btree.iter_destroy(&it)
	for has_item := btree.iter_first(&it); has_item; has_item = btree.iter_next(&it) {
		append(&actual, btree.item(&it))
	}

	testing.expect_value(t, len(actual), 3)
	testing.expect_value(t, actual[0], Note_Sort_Key{updated_at = 50, asset_id = 1})
	testing.expect_value(t, actual[1], Note_Sort_Key{updated_at = 100, asset_id = 3})
	testing.expect_value(t, actual[2], Note_Sort_Key{updated_at = 100, asset_id = 5})

	_, has_non_note := conv.note_index_keys[non_note.asset_id]
	testing.expect(t, !has_non_note, "non-note asset should not be indexed")
}

@(test)
test_note_index_remove_and_reinsert_update_key :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	note := make_test_asset(42, 10)
	defer free(note)

	index_note_asset(&conv, note)
	testing.expect_value(t, btree.count(&conv.note_index), 1)

	remove_note_asset_from_index(&conv, note.asset_id)
	testing.expect_value(t, btree.count(&conv.note_index), 0)
	_, has_old_key := conv.note_index_keys[note.asset_id]
	testing.expect(t, !has_old_key, "note index key should be removed")

	note.updated_at = 99
	index_note_asset(&conv, note)
	testing.expect_value(t, btree.count(&conv.note_index), 1)

	new_key, has_new_key := conv.note_index_keys[note.asset_id]
	testing.expect(t, has_new_key, "note index key should be present after reinsert")
	testing.expect_value(t, new_key, Note_Sort_Key{updated_at = 99, asset_id = 42})
}

@(test)
test_note_index_delete_removes_from_tree_and_cursor_map :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	assets := [3]pr.Asset {
		{asset_type = .Note, asset_id = 11, updated_at = 100, conv_id = 1},
		{asset_type = .Note, asset_id = 12, updated_at = 200, conv_id = 1},
		{asset_type = .Note, asset_id = 13, updated_at = 300, conv_id = 1},
	}

	for i in 0 ..< len(assets) {
		index_note_asset(&conv, &assets[i])
	}
	testing.expect_value(t, btree.count(&conv.note_index), 3)

	remove_note_asset_from_index(&conv, 12)
	testing.expect_value(t, btree.count(&conv.note_index), 2)
	_, has_deleted_key := conv.note_index_keys[12]
	testing.expect(t, !has_deleted_key, "deleted note key should be removed from key map")

	seen_deleted := false
	it := btree.iter(&conv.note_index)
	defer btree.iter_destroy(&it)
	for has_item := btree.iter_first(&it); has_item; has_item = btree.iter_next(&it) {
		if btree.item(&it).asset_id == 12 {
			seen_deleted = true
			break
		}
	}
	testing.expect(t, !seen_deleted, "deleted note should not appear in tree iteration")

}

// ============================================================================
// Project Index Tests
// ============================================================================

make_test_note_asset :: proc(asset_id: pr.AssetID, updated_at: i64, preview: string) -> ^pr.Asset {
	asset := new(pr.Asset)
	asset.asset_id = asset_id
	asset.asset_type = .Note
	asset.updated_at = updated_at
	asset.conv_id = 1
	asset.preview = transmute([]byte)preview
	return asset
}

@(test)
test_note_metadata_validated_fields :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	for fixture in ([?]struct {
			data, project: string,
			tags:          []string,
		}{{`{"project":" heavyhorst/srv ","tags":["infra"," ops ","infra",""]}`, "heavyhorst/srv", []string{"infra", "ops"}}, {`{"tags":["first"],"project":"after-tags"}`, "after-tags", []string{"first"}}, {`{"pro\u006aect":" caf\u00e9 ","ta\u0067s":["\uD83D\uDE00","😀","end\\","quote\""]}`, "café", []string{"😀", "end\\", "quote\""}}, {`{"extra":{"project":"fake","tags":["fake"]},"project":"real","tags":["yes"]}`, "real", []string{"yes"}}, {`{"extra":{"project":"fake","tags":["fake"]}}`, "", nil}, {`{"title":"Idea [proj1] [proj2]"}`, "", nil}, {`{"project":null,"tags":["alpha"]}`, "", []string{"alpha"}}, {`{"project":"p","tags":null}`, "p", nil}, {`{"project":"p","tags":[],"extra":[{"tags":["fake"]}]}`, "p", nil}}) {
		tags := make([dynamic]string)
		project := json_note_metadata_fields(transmute([]byte)fixture.data, &tags, a)
		testing.expect_value(t, project, fixture.project)
		testing.expect_value(t, len(tags), len(fixture.tags))
		if len(tags) == len(fixture.tags) {for tag, i in fixture.tags do testing.expect_value(t, tags[i], tag)}
		delete(tags)
	}
	for data in ([?]string{`{"project":17,"tags":["valid"]}`, `{"project":"p","tags":"bad"}`, `{"project":"p","tags":["valid",17]}`, `{"project":"p","tags":["valid",[]]}`, `{"project":"p","tags":["valid",{}]}`, `{"tags":["project":"p"]}`, `{"project":"p","project":"q"}`, `{"project":"p","pro\u006aect":"q"}`, `{"tags":["a"],"ta\u0067s":["b"]}`, `{"project":"p","tags":["ok"]} garbage`, `{"project":"p","tags":["ok"],}`, `{"project":"p","tags":["ok",]}`, `[]`, `{broken`}) {
		tags := make([dynamic]string)
		append(&tags, "existing")
		project := json_note_metadata_fields(transmute([]byte)data, &tags, a)
		testing.expect_value(t, project, "")
		testing.expect_value(t, len(tags), 1)
		testing.expect_value(t, tags[0], "existing")
		delete(tags)
	}
	complete := `{"project":"p","tags":["ok"],"extra":{"nested":true}}`
	for n in 0 ..< len(complete) {
		tags := make([dynamic]string)
		testing.expect_value(t, json_note_metadata_fields(transmute([]byte)complete[:n], &tags, a), "")
		testing.expect_value(t, len(tags), 0)
		delete(tags)
	}
}

test_note_project_index_insert_and_remove :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	a1 := make_test_note_asset(1, 300, `{"title":"A","teaser":"","project":"proj1"}`)
	a2 := make_test_note_asset(2, 200, `{"title":"B","teaser":"","project":"proj1"}`)
	a3 := make_test_note_asset(3, 100, `{"title":"C","teaser":"","project":"proj2"}`)
	defer free(a1)
	defer free(a2)
	defer free(a3)

	index_note_asset(&conv, a1)
	index_note_asset(&conv, a2)
	index_note_asset(&conv, a3)

	// proj1 should have 2 notes, sorted by updated_at desc
	proj1_list := note_secondary_index_asset_ids(conv.note_project_assets["proj1"])
	defer delete(proj1_list)
	testing.expect_value(t, len(proj1_list), 2)
	testing.expect_value(t, proj1_list[0], pr.AssetID(1)) // updated_at=300 first
	testing.expect_value(t, proj1_list[1], pr.AssetID(2)) // updated_at=200 second

	// proj2 should have 1 note
	proj2_list := note_secondary_index_asset_ids(conv.note_project_assets["proj2"])
	defer delete(proj2_list)
	testing.expect_value(t, len(proj2_list), 1)
	testing.expect_value(t, proj2_list[0], pr.AssetID(3))

	// Remove a1 from proj1
	remove_note_asset_from_index(&conv, 1)
	delete(proj1_list)
	proj1_list = note_secondary_index_asset_ids(conv.note_project_assets["proj1"])
	testing.expect_value(t, len(proj1_list), 1)
	testing.expect_value(t, proj1_list[0], pr.AssetID(2))

	// Remove last item from proj2 -> key should be deleted
	remove_note_asset_from_index(&conv, 3)
	_, has_proj2 := conv.note_project_assets["proj2"]
	testing.expect(t, !has_proj2, "proj2 should be removed when empty")
}

test_note_project_index_update_changes_project :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	a1 := make_test_note_asset(1, 100, `{"title":"A","teaser":"","project":"proj1"}`)
	defer free(a1)
	index_note_asset(&conv, a1)

	testing.expect_value(t, btree.count(&conv.note_project_assets["proj1"].tree), 1)
	_, has_old := conv.note_project_assets["proj1"]
	testing.expect(t, has_old, "proj1 should exist")

	// Simulate update: remove old, index new
	remove_note_asset_from_index(&conv, 1)

	// Update preview
	new_preview := `{"title":"A","teaser":"","project":"proj2"}`
	a1.preview = transmute([]byte)new_preview
	index_note_asset(&conv, a1)

	_, has_proj1 := conv.note_project_assets["proj1"]
	testing.expect(t, !has_proj1, "proj1 should be gone after update")
	testing.expect_value(t, btree.count(&conv.note_project_assets["proj2"].tree), 1)
}

test_note_project_index_same_timestamp_orders_by_asset_id_desc :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	a1 := make_test_note_asset(1, 100, `{"title":"A","teaser":"","project":"proj1"}`)
	a2 := make_test_note_asset(3, 100, `{"title":"B","teaser":"","project":"proj1"}`)
	a3 := make_test_note_asset(2, 100, `{"title":"C","teaser":"","project":"proj1"}`)
	defer free(a1)
	defer free(a2)
	defer free(a3)

	index_note_asset(&conv, a1)
	index_note_asset(&conv, a2)
	index_note_asset(&conv, a3)

	proj1_list := note_secondary_index_asset_ids(conv.note_project_assets["proj1"])
	defer delete(proj1_list)
	testing.expect_value(t, len(proj1_list), 3)
	testing.expect_value(t, proj1_list[0], pr.AssetID(3))
	testing.expect_value(t, proj1_list[1], pr.AssetID(2))
	testing.expect_value(t, proj1_list[2], pr.AssetID(1))

	remove_note_asset_from_index(&conv, 2)
	delete(proj1_list)
	proj1_list = note_secondary_index_asset_ids(conv.note_project_assets["proj1"])
	testing.expect_value(t, len(proj1_list), 2)
	testing.expect_value(t, proj1_list[0], pr.AssetID(3))
	testing.expect_value(t, proj1_list[1], pr.AssetID(1))
}

test_note_project_find_cursor_idx_returns_first_older_note :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	a1 := make_test_note_asset(5, 300, `{"title":"A","teaser":"","project":"proj1"}`)
	a2 := make_test_note_asset(4, 200, `{"title":"B","teaser":"","project":"proj1"}`)
	a3 := make_test_note_asset(3, 200, `{"title":"C","teaser":"","project":"proj1"}`)
	a4 := make_test_note_asset(1, 100, `{"title":"D","teaser":"","project":"proj1"}`)
	defer free(a1)
	defer free(a2)
	defer free(a3)
	defer free(a4)

	index_note_asset(&conv, a1)
	index_note_asset(&conv, a2)
	index_note_asset(&conv, a3)
	index_note_asset(&conv, a4)

	cursor_key := conv.note_index_keys[4]
	it := btree.iter(&conv.note_project_assets["proj1"].tree)
	defer btree.iter_destroy(&it)
	testing.expect(t, btree.iter_seek(&it, cursor_key), "cursor should seek to indexed note")
	testing.expect(t, btree.iter_prev(&it), "cursor should have an older note")
	testing.expect_value(t, btree.item(&it).asset_id, pr.AssetID(3))
}

test_note_tag_index_multiple_tags_indexes_all :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	init_note_index(&conv)
	defer destroy_note_index(&conv)

	a1 := make_test_note_asset(1, 300, `{"title":"A","teaser":"","project":"proj","tags":["alpha","beta","alpha"]}`)
	defer free(a1)
	index_note_asset(&conv, a1)

	alpha_list := note_secondary_index_asset_ids(conv.note_tag_assets["alpha"])
	beta_list := note_secondary_index_asset_ids(conv.note_tag_assets["beta"])
	defer delete(alpha_list)
	defer delete(beta_list)

	testing.expect_value(t, len(alpha_list), 1)
	testing.expect_value(t, alpha_list[0], pr.AssetID(1))
	testing.expect_value(t, len(beta_list), 1)
	testing.expect_value(t, beta_list[0], pr.AssetID(1))

	remove_note_asset_from_index(&conv, 1)
	_, has_alpha := conv.note_tag_assets["alpha"]
	_, has_beta := conv.note_tag_assets["beta"]
	testing.expect(t, !has_alpha, "alpha tag should be removed when empty")
	testing.expect(t, !has_beta, "beta tag should be removed when empty")
}

NOTE_INDEX_MODEL_CAPACITY :: 16

Note_Index_Model_Entry :: struct {
	active:           bool,
	updated_at:       i64,
	metadata_variant: int,
}

note_index_model_metadata :: proc(variant: int) -> string {
	switch variant {
	case 0:
		return `{"project":"alpha","tags":["odin","server"]}`
	case 1:
		return `{"project":"beta","tags":["server"]}`
	case 2:
		return `{"tags":["odin","odin"]}`
	case 3:
		return `{broken metadata`
	case 4:
		return `{"project":17,"tags":"odin"}`
	case:
		return "  { \"project\" : \"alpha\", \"tags\" : [ \"graph\" ] }  "
	}
}

note_index_model_has_project :: proc(variant: int, project: string) -> bool {
	return (variant == 0 || variant == 5) && project == "alpha" || variant == 1 && project == "beta"
}

note_index_model_has_tag :: proc(variant: int, tag: string) -> bool {
	return(
		(variant == 0 && (tag == "odin" || tag == "server")) ||
		(variant == 1 && tag == "server") ||
		(variant == 2 && tag == "odin") ||
		(variant == 5 && tag == "graph") \
	)
}

note_index_model_expected :: proc(model: ^[NOTE_INDEX_MODEL_CAPACITY]Note_Index_Model_Entry, project, tag: string) -> [dynamic]Note_Sort_Key {
	expected := make([dynamic]Note_Sort_Key, 0, NOTE_INDEX_MODEL_CAPACITY)
	for i in 0 ..< NOTE_INDEX_MODEL_CAPACITY {
		entry := model[i]
		if !entry.active {
			continue
		}
		if project != "" && !note_index_model_has_project(entry.metadata_variant, project) {
			continue
		}
		if tag != "" && !note_index_model_has_tag(entry.metadata_variant, tag) {
			continue
		}
		append(&expected, Note_Sort_Key{updated_at = entry.updated_at, asset_id = pr.AssetID(i + 1)})
	}
	slice.sort_by(expected[:], proc(a, b: Note_Sort_Key) -> bool {
		return a.updated_at > b.updated_at || a.updated_at == b.updated_at && a.asset_id > b.asset_id
	})
	return expected
}

note_index_model_list_matches :: proc(conv: ^Conversation_State, actual: ^Note_Secondary_Index, expected: []Note_Sort_Key) -> bool {
	if actual == nil || btree.count(&actual.tree) != len(expected) {
		return false
	}
	it := btree.iter(&actual.tree)
	defer btree.iter_destroy(&it)
	has_item := btree.iter_last(&it)
	for item in expected {
		if !has_item || btree.item(&it) != item {
			return false
		}
		key, ok := conv.note_index_keys[item.asset_id]
		if !ok || key != item {
			return false
		}
		has_item = btree.iter_prev(&it)
	}
	return !has_item
}

note_index_model_matches :: proc(conv: ^Conversation_State, model: ^[NOTE_INDEX_MODEL_CAPACITY]Note_Index_Model_Entry) -> bool {
	global := note_index_model_expected(model, "", "")
	defer delete(global)
	if btree.count(&conv.note_index) != len(global) || len(conv.note_index_keys) != len(global) {
		return false
	}

	it := btree.iter(&conv.note_index)
	defer btree.iter_destroy(&it)
	has_item := btree.iter_last(&it)
	for expected in global {
		if !has_item || btree.item(&it) != expected {
			return false
		}
		has_item = btree.iter_prev(&it)
	}
	if has_item {
		return false
	}

	expected_project_count := 0
	projects := [?]string{"alpha", "beta"}
	for project in projects {
		expected := note_index_model_expected(model, project, "")
		actual, present := conv.note_project_assets[project]
		if len(expected) > 0 {
			expected_project_count += 1
		}
		if present != (len(expected) > 0) || present && !note_index_model_list_matches(conv, actual, expected[:]) {
			delete(expected)
			return false
		}
		delete(expected)
	}
	if len(conv.note_project_assets) != expected_project_count {
		return false
	}

	expected_tag_count := 0
	tags := [?]string{"odin", "server", "graph"}
	for tag in tags {
		expected := note_index_model_expected(model, "", tag)
		actual, present := conv.note_tag_assets[tag]
		if len(expected) > 0 {
			expected_tag_count += 1
		}
		if present != (len(expected) > 0) || present && !note_index_model_list_matches(conv, actual, expected[:]) {
			delete(expected)
			return false
		}
		delete(expected)
	}
	if len(conv.note_tag_assets) != expected_tag_count {
		return false
	}
	return true
}

prop_note_indexes_match_stateful_models :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	conv := Conversation_State{}
	conv.assets = make(map[pr.AssetID]^pr.Asset, NOTE_INDEX_MODEL_CAPACITY)
	init_note_index(&conv)
	defer {
		for _, asset in conv.assets do free_asset(asset)
		delete(conv.assets)
		destroy_note_index(&conv)
	}
	model: [NOTE_INDEX_MODEL_CAPACITY]Note_Index_Model_Entry

	op_count_raw, draw_err := hgl.draw_i64(tc, 1, 100)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw note index operation count")

	for op_index in 0 ..< int(op_count_raw) {
		id_raw, id_err := hgl.draw_i64(tc, 1, NOTE_INDEX_MODEL_CAPACITY)
		if id_err == .Stop_Test do return hgl.abort()
		if id_err != nil do return hgl.interesting("draw note index asset id")
		action, action_err := hgl.draw_i64(tc, 0, 2)
		if action_err == .Stop_Test do return hgl.abort()
		if action_err != nil do return hgl.interesting("draw note index action")

		id := pr.AssetID(id_raw)
		entry := &model[int(id) - 1]
		if action == 2 {
			if entry.active {
				asset := conv.assets[id]
				remove_note_asset_from_index(&conv, id)
				delete_key(&conv.assets, id)
				free_asset(asset)
				entry^ = {}
			}
		} else {
			updated_at, timestamp_err := hgl.draw_i64(tc, 0, 7)
			if timestamp_err == .Stop_Test do return hgl.abort()
			if timestamp_err != nil do return hgl.interesting("draw note index timestamp")
			variant_raw, variant_err := hgl.draw_i64(tc, 0, 5)
			if variant_err == .Stop_Test do return hgl.abort()
			if variant_err != nil do return hgl.interesting("draw note metadata variant")

			if entry.active {
				old_asset := conv.assets[id]
				remove_note_asset_from_index(&conv, id)
				free_asset(old_asset)
			}
			metadata := note_index_model_metadata(int(variant_raw))
			asset := alloc_asset(nil, transmute([]byte)metadata, nil)
			if asset == nil do return hgl.interesting("allocate generated note")
			asset.asset_type = .Note
			asset.asset_id = id
			asset.updated_at = updated_at
			asset.conv_id = 1
			conv.assets[id] = asset
			index_note_asset(&conv, asset)
			entry^ = {
				active           = true,
				updated_at       = updated_at,
				metadata_variant = int(variant_raw),
			}
		}

		if !note_index_model_matches(&conv, &model) {
			hgl.note(tc, fmt.tprintf("note index model mismatch op=%d action=%d id=%d", op_index, action, id))
			return hgl.interesting("global/project/tag note indexes diverged from reference models")
		}
	}
	return hgl.valid()
}

@(test)
test_hegel_note_indexes_match_stateful_models :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_note_indexes_match_stateful_models, nil, {test_cases = 500})
	testing.expectf(t, err == nil, "hegel note index state model failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

Note_Pagination_Test_Scope :: enum {
	Global,
	Project,
	Tag,
}

Note_Pagination_Test_Page :: struct {
	asset_ids:              [NOTE_INDEX_MODEL_CAPACITY]pr.AssetID,
	asset_count:            int,
	has_more:               bool,
	next_cursor_updated_at: i64,
	next_cursor_asset_id:   pr.AssetID,
	total_count:            u32,
	correlation_id:         u32,
}

note_pagination_test_query :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	scope: Note_Pagination_Test_Scope,
	filter: string,
	limit: u16,
	has_cursor: bool = false,
	cursor_updated_at: i64 = 0,
	cursor_asset_id: pr.AssetID = 0,
) -> (
	Note_Pagination_Test_Page,
	bool,
) {
	correlation_id := u32(700 + int(scope))
	switch scope {
	case .Global:
		handle_list_assets_paged(
			c,
			{
				conv_id = conv_id,
				asset_type = .Note,
				limit = limit,
				has_cursor = has_cursor,
				cursor_updated_at = cursor_updated_at,
				cursor_asset_id = cursor_asset_id,
				correlation_id = correlation_id,
			},
		)
	case .Project:
		handle_list_assets_paged_by_project(
			c,
			{
				conv_id = conv_id,
				asset_type = .Note,
				limit = limit,
				has_cursor = has_cursor,
				cursor_updated_at = cursor_updated_at,
				cursor_asset_id = cursor_asset_id,
				project = filter,
				correlation_id = correlation_id,
			},
		)
	case .Tag:
		handle_list_assets_paged_by_tag(
			c,
			{
				conv_id = conv_id,
				asset_type = .Note,
				limit = limit,
				has_cursor = has_cursor,
				cursor_updated_at = cursor_updated_at,
				cursor_asset_id = cursor_asset_id,
				tag = filter,
				correlation_id = correlation_id,
			},
		)
	}

	result: Note_Pagination_Test_Page
	if send_queue_len(c) != 1 {
		return result, false
	}
	item := send_queue_pop(c)
	defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease)
	header, header_len, frame_err := ws.readFrameHeader(frame)
	if frame_err != nil || header.opcode != .opBinary || len(frame) != header_len + int(header.payloadLength) {
		return result, false
	}
	parsed, parse_err := pr.parseAssetListPageMessage(frame[header_len:])
	defer if len(parsed.assets) > 0 do delete(parsed.assets)
	if parse_err != nil || len(parsed.assets) > len(result.asset_ids) {
		return result, false
	}
	result.asset_count = len(parsed.assets)
	for asset, i in parsed.assets do result.asset_ids[i] = asset.asset_id
	result.has_more = parsed.has_more
	result.next_cursor_updated_at = parsed.next_cursor_updated_at
	result.next_cursor_asset_id = parsed.next_cursor_asset_id
	result.total_count = parsed.total_count
	result.correlation_id = parsed.correlation_id
	return result, true
}

note_pagination_test_install :: proc(conv: ^Conversation_State, id: pr.AssetID, updated_at: i64, metadata: string) -> bool {
	asset := alloc_asset(nil, transmute([]byte)metadata, nil)
	if asset == nil {
		return false
	}
	asset.asset_type = .Note
	asset.asset_id = id
	asset.updated_at = updated_at
	asset.conv_id = 77
	conv.assets[id] = asset
	index_note_asset(conv, asset)
	return true
}

note_pagination_test_expect_ids :: proc(t: ^testing.T, page: Note_Pagination_Test_Page, expected: []pr.AssetID) {
	testing.expect_value(t, page.asset_count, len(expected))
	if page.asset_count != len(expected) {
		return
	}
	for id, i in expected do testing.expect_value(t, page.asset_ids[i], id)
}

@(test)
test_note_pagination_handlers_keep_cursors_stable_across_index_changes :: proc(t: ^testing.T) {
	workspace_id := "note-pagination-handlers"
	if !init_room_mapping_test_state("note_pagination_handlers.log", workspace_id) {
		testing.expect(t, false, "pagination fixture should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)
	c.state = .Idle
	c.is_sending = true // Keep handler responses queued for protocol-level inspection.
	conv_id := pr.ConversationID(77)
	conv := get_or_create_conversation(get_or_create_workspace(workspace_id), conv_id)

	fixtures := [?]struct {
		id:         pr.AssetID,
		updated_at: i64,
		metadata:   string,
	} {
		{1, 100, `{"project":"alpha","tags":["odin"]}`},
		{2, 200, `{"project":"alpha","tags":["odin"]}`},
		{3, 200, `{"project":"alpha","tags":["odin"]}`},
		{4, 300, `{"project":"beta","tags":["server"]}`},
		{5, 250, `{broken metadata`},
		{6, 50, `{"project":"alpha","tags":["odin"]}`},
		{7, 25, `{"project":"alpha","tags":["odin"]}`},
	}
	for fixture in fixtures {
		testing.expect(t, note_pagination_test_install(conv, fixture.id, fixture.updated_at, fixture.metadata), "note fixture allocation should succeed")
	}

	// Leave one deliberately stale entry in all indexes. Handlers must skip it.
	stale := conv.assets[6]
	delete_key(&conv.assets, 6)
	free_asset(stale)
	// Leave another asset live in project/tag arrays but remove its ordering
	// entries, exercising the handlers' missing-key stale-entry path.
	stale_key := conv.note_index_keys[7]
	_, _ = btree.remove(&conv.note_index, stale_key)
	delete_key(&conv.note_index_keys, 7)
	_, stale_key_present := conv.note_index_keys[7]
	testing.expect(t, conv.assets[7] != nil && !stale_key_present, "list-only stale fixture should remain live without an ordering key")
	testing.expect(t, note_secondary_index_contains_asset(conv.note_project_assets["alpha"], 7), "tree-only stale fixture should remain in the project index")
	testing.expect(t, note_secondary_index_contains_asset(conv.note_tag_assets["odin"], 7), "tree-only stale fixture should remain in the tag index")

	page1, ok := note_pagination_test_query(&c, conv_id, .Global, "", 2)
	testing.expect(t, ok, "global page 1 should decode")
	note_pagination_test_expect_ids(t, page1, []pr.AssetID{4, 5})
	testing.expect(t, page1.has_more, "global page 1 should report more live rows")
	testing.expect_value(t, page1.next_cursor_updated_at, i64(250))
	testing.expect_value(t, page1.next_cursor_asset_id, pr.AssetID(5))
	testing.expect_value(t, page1.total_count, u32(6))
	testing.expect_value(t, page1.correlation_id, u32(700))

	page2, page2_ok := note_pagination_test_query(&c, conv_id, .Global, "", 2, true, page1.next_cursor_updated_at, page1.next_cursor_asset_id)
	testing.expect(t, page2_ok, "global page 2 should decode")
	note_pagination_test_expect_ids(t, page2, []pr.AssetID{3, 2})
	testing.expect(t, page2.has_more, "equal-timestamp page should retain the final live row")

	page3, page3_ok := note_pagination_test_query(&c, conv_id, .Global, "", 2, true, page2.next_cursor_updated_at, page2.next_cursor_asset_id)
	testing.expect(t, page3_ok, "global page 3 should decode")
	note_pagination_test_expect_ids(t, page3, []pr.AssetID{1})
	testing.expect(t, !page3.has_more, "stale trailing index rows must not create a phantom page")

	project_page, project_ok := note_pagination_test_query(&c, conv_id, .Project, "alpha", 2)
	testing.expect(t, project_ok, "project page should decode")
	note_pagination_test_expect_ids(t, project_page, []pr.AssetID{3, 2})
	testing.expect(t, project_page.has_more, "project page should report the remaining live note")
	testing.expect_value(t, project_page.total_count, u32(5))
	project_tail, project_tail_ok := note_pagination_test_query(
		&c,
		conv_id,
		.Project,
		"alpha",
		2,
		true,
		project_page.next_cursor_updated_at,
		project_page.next_cursor_asset_id,
	)
	testing.expect(t, project_tail_ok, "project tail should decode")
	note_pagination_test_expect_ids(t, project_tail, []pr.AssetID{1})
	testing.expect(t, !project_tail.has_more, "project stale rows must not advertise a phantom page")

	tag_page, tag_ok := note_pagination_test_query(&c, conv_id, .Tag, "odin", 2)
	testing.expect(t, tag_ok, "tag page should decode")
	note_pagination_test_expect_ids(t, tag_page, []pr.AssetID{3, 2})
	testing.expect(t, tag_page.has_more, "tag page should report the remaining live note")
	tag_tail, tag_tail_ok := note_pagination_test_query(&c, conv_id, .Tag, "odin", 2, true, tag_page.next_cursor_updated_at, tag_page.next_cursor_asset_id)
	testing.expect(t, tag_tail_ok, "tag tail should decode")
	note_pagination_test_expect_ids(t, tag_tail, []pr.AssetID{1})
	testing.expect(t, !tag_tail.has_more, "tag stale rows must not advertise a phantom page")

	malformed_project, malformed_project_ok := note_pagination_test_query(&c, conv_id, .Project, "broken", 10)
	testing.expect(t, malformed_project_ok, "malformed project query should decode")
	note_pagination_test_expect_ids(t, malformed_project, nil)
	malformed_tag, malformed_tag_ok := note_pagination_test_query(&c, conv_id, .Tag, "server", 10)
	testing.expect(t, malformed_tag_ok, "malformed tag metadata query should decode")
	note_pagination_test_expect_ids(t, malformed_tag, []pr.AssetID{4})

	// Move the page-1 cursor note ahead of its original cursor. Continuing from
	// the wire cursor must neither duplicate it nor skip its equal-time sibling.
	old_cursor_updated_at := project_page.next_cursor_updated_at
	old_cursor_asset_id := project_page.next_cursor_asset_id
	old_asset := conv.assets[old_cursor_asset_id]
	remove_note_asset_from_index(conv, old_cursor_asset_id)
	old_asset.updated_at = 400
	index_note_asset(conv, old_asset)
	updated_global, updated_global_ok := note_pagination_test_query(&c, conv_id, .Global, "", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, updated_global_ok, "global continuation after forward cursor update should decode")
	note_pagination_test_expect_ids(t, updated_global, []pr.AssetID{1})
	updated_project, updated_project_ok := note_pagination_test_query(&c, conv_id, .Project, "alpha", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, updated_project_ok, "project continuation after forward cursor update should decode")
	note_pagination_test_expect_ids(t, updated_project, []pr.AssetID{1})
	updated_tag, updated_tag_ok := note_pagination_test_query(&c, conv_id, .Tag, "odin", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, updated_tag_ok, "tag continuation after forward cursor update should decode")
	note_pagination_test_expect_ids(t, updated_tag, []pr.AssetID{1})

	remove_note_asset_from_index(conv, old_cursor_asset_id)
	old_asset.updated_at = 50
	index_note_asset(conv, old_asset)
	backward_global, backward_global_ok := note_pagination_test_query(&c, conv_id, .Global, "", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, backward_global_ok, "global continuation after backward cursor update should decode")
	note_pagination_test_expect_ids(t, backward_global, []pr.AssetID{1})
	backward_project, backward_project_ok := note_pagination_test_query(&c, conv_id, .Project, "alpha", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, backward_project_ok, "project continuation after backward cursor update should decode")
	note_pagination_test_expect_ids(t, backward_project, []pr.AssetID{1})
	backward_tag, backward_tag_ok := note_pagination_test_query(&c, conv_id, .Tag, "odin", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, backward_tag_ok, "tag continuation after backward cursor update should decode")
	note_pagination_test_expect_ids(t, backward_tag, []pr.AssetID{1})

	remove_note_asset_from_index(conv, old_cursor_asset_id)
	delete_key(&conv.assets, old_cursor_asset_id)
	free_asset(old_asset)
	deleted_global, deleted_global_ok := note_pagination_test_query(&c, conv_id, .Global, "", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, deleted_global_ok, "global continuation after cursor delete should decode")
	note_pagination_test_expect_ids(t, deleted_global, []pr.AssetID{1})
	deleted_project, deleted_project_ok := note_pagination_test_query(&c, conv_id, .Project, "alpha", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, deleted_project_ok, "project continuation after cursor delete should decode")
	note_pagination_test_expect_ids(t, deleted_project, []pr.AssetID{1})
	deleted_tag, deleted_tag_ok := note_pagination_test_query(&c, conv_id, .Tag, "odin", 10, true, old_cursor_updated_at, old_cursor_asset_id)
	testing.expect(t, deleted_tag_ok, "tag continuation after cursor delete should decode")
	note_pagination_test_expect_ids(t, deleted_tag, []pr.AssetID{1})
}
