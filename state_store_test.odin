package main

import "btree"
import "core:strings"
import "core:testing"
import pr "protocol"

// Scan the primary map independently of index membership and cached sort keys.
store_test_check_tasks :: proc(t: ^testing.T, conv: ^Conversation_State) {
	active := 0
	blockers := 0
	for id, task in conv.tasks {
		if task.status == .Backlog || task.status == .Todo || task.status == .InProgress do active += 1
		timestamp := task.status == .Done ? task.completed_at : task.updated_at
		_, found := btree.get(&conv.task_index, Task_Sort_Key{timestamp, id})
		testing.expect(t, found)
		testing.expect_value(t, conv.task_index_keys[id], Task_Sort_Key{timestamp, id})
		if task.blocked_by != 0 {
			blockers += 1
			_, found = btree.get(&conv.task_blockers, Entity_Reference_Key{parent_id = u64(task.blocked_by), entity_id = u64(id)})
			testing.expect(t, found)
		}
	}
	testing.expect_value(t, conv.active_task_count, active)
	testing.expect_value(t, btree.count(&conv.task_index), len(conv.tasks))
	testing.expect_value(t, len(conv.task_index_keys), len(conv.tasks))
	testing.expect_value(t, btree.count(&conv.task_blockers), blockers)
	store_test_check_task_query(t, conv, &conv.task_query_indexes)
	for &set, status in conv.task_status_indexes do store_test_check_task_query(t, conv, &set, status)
	for project, index in conv.task_project_indexes do store_test_check_task_query(t, conv, &index.indexes, project = project, by_project = true)
	for assignee, index in conv.task_assignee_indexes do store_test_check_task_query(t, conv, &index.indexes, assignee = assignee, by_assignee = true)
}

store_test_check_task_query :: proc(
	t: ^testing.T,
	conv: ^Conversation_State,
	set: ^Task_Query_Index_Set,
	status: int = -1,
	project: string = "",
	assignee: string = "",
	by_project: bool = false,
	by_assignee: bool = false,
) {
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			if !set.initialized[sort_kind][direction] do continue
			expected_count := 0
			for id, task in conv.tasks {
				if task.status == .Note || status >= 0 && int(task.status) != status do continue
				if by_project && string(task.project) != project || by_assignee && string(task.assignee) != assignee do continue
				expected_count += 1
				key := Task_Query_Key {
					task_id = id,
				}
				switch pr.TaskQuerySort(sort_kind) {
				case .Priority:
					key.number = i64(task.priority)
				case .Status:
					key.number = i64(task.status)
				case .Assignee:
					key.text = task.assignee
				case .DueAt:
					key.number = task.due_at; key.due_missing = task.due_at == 0
				case .CreatedAt:
					key.number = task.created_at
				case .Title:
					key.text = task.title
				case .Color:
					key.number = i64(task.color)
				case .Project:
					key.text = task.project
				}
				_, found := btree.get(&set.trees[sort_kind][direction], key)
				testing.expect(t, found, "map member missing from query index")
			}
			testing.expect_value(t, btree.count(&set.trees[sort_kind][direction]), expected_count)
		}
	}
}

@(test)
test_state_store_task_replace_move_remove :: proc(t: ^testing.T) {
	conv := new(Conversation_State)
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	init_task_index(conv)
	defer destroy_conversation(conv)
	for id in 1 ..< 4 {
		task := alloc_task(transmute([]byte)string("old title"), nil, transmute([]byte)string("alice"), nil, nil, nil, transmute([]byte)string("alpha"), nil)
		task.id = pr.TaskID(id)
		task.status = .Todo
		task.updated_at = i64(id * 10)
		task.blocked_by = 99
		task_store_put(conv, task)
	}
	// Materialize every lazy order before replacing string storage and sort fields.
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			_ = task_query_index_set_ensure_order(&conv.task_query_indexes, &conv.tasks, pr.TaskQuerySort(sort_kind), direction == 1)
			_ = task_query_index_set_ensure_order(&conv.task_status_indexes[1], &conv.tasks, pr.TaskQuerySort(sort_kind), direction == 1)
			_ = task_query_index_set_ensure_order(&conv.task_project_indexes["alpha"].indexes, &conv.tasks, pr.TaskQuerySort(sort_kind), direction == 1)
			_ = task_query_index_set_ensure_order(&conv.task_assignee_indexes["alice"].indexes, &conv.tasks, pr.TaskQuerySort(sort_kind), direction == 1)
		}
	}
	store_test_check_tasks(t, conv)
	next := alloc_task(transmute([]byte)string("new title"), nil, transmute([]byte)string("bob"), nil, nil, nil, transmute([]byte)string("beta"), nil)
	next.id = 2
	next.status = .Done
	next.updated_at = 123
	next.completed_at = 87
	next.due_at = 55
	next.blocked_by = 77
	task_store_put(conv, next)
	store_test_check_tasks(t, conv)
	testing.expect(t, conv.task_project_indexes["beta"] != nil && conv.task_assignee_indexes["bob"] != nil)
	// Move a snapshot without replacing the owned allocation.
	snapshot := next^
	snapshot.status = .InProgress
	snapshot.completed_at = 0
	snapshot.updated_at = 155
	snapshot.order_index = 35
	task_store_move(conv, &snapshot)
	testing.expect(t, conv.tasks[2] == next)
	testing.expect_value(t, next.order_index, snapshot.order_index)
	store_test_check_tasks(t, conv)
	// Note tasks retain pagination membership but leave all query indexes.
	snapshot = conv.tasks[1]^
	snapshot.status = .Note
	snapshot.updated_at = 211
	task_store_move(conv, &snapshot)
	store_test_check_tasks(t, conv)
	snapshot.status = .Todo
	snapshot.updated_at = 233
	task_store_move(conv, &snapshot)
	store_test_check_tasks(t, conv)
	deletions := [?]pr.TaskID{2, 1, 3, 2}
	for id in deletions {
		task_store_remove(conv, id)
		store_test_check_tasks(t, conv)
	}
	testing.expect_value(t, len(conv.task_project_indexes), 0)
	testing.expect_value(t, len(conv.task_assignee_indexes), 0)
}

@(test)
test_state_store_asset_replace_type_and_parent :: proc(t: ^testing.T) {
	conv := new(Conversation_State)
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	init_note_index(conv)
	defer destroy_conversation(conv)
	ws := Workspace_State{}
	// Keep one note in the old buckets so replacement must remove exactly one key.
	for id in 1 ..< 3 {
		asset := alloc_asset(nil, transmute([]byte)string(`{"pro\u006aect":"al\u0070ha","tags":["o\u0064in","server"]}`), nil)
		asset.asset_id = pr.AssetID(id)
		asset.asset_type = .Note
		asset.updated_at = i64(id * 10)
		asset.parent_type = .Task
		asset.parent_id = 91
		asset_store_put(&ws, "store-test", conv, asset)
	}
	next := alloc_asset(nil, transmute([]byte)string(`{"project":"be\u0074a","tags":["gra\u0070h"]}`), nil)
	next.asset_id = 1
	next.asset_type = .Note
	next.updated_at = 77
	next.parent_type = .Asset
	next.parent_id = 92
	asset_store_put(&ws, "store-test", conv, next)
	testing.expect(t, note_index_model_list_matches(conv, conv.note_project_assets["alpha"], []Note_Sort_Key{{20, 2}}))
	testing.expect(t, note_index_model_list_matches(conv, conv.note_tag_assets["odin"], []Note_Sort_Key{{20, 2}}))
	testing.expect(t, note_index_model_list_matches(conv, conv.note_tag_assets["server"], []Note_Sort_Key{{20, 2}}))
	testing.expect(t, note_index_model_list_matches(conv, conv.note_project_assets["beta"], []Note_Sort_Key{{77, 1}}))
	testing.expect(t, note_index_model_list_matches(conv, conv.note_tag_assets["graph"], []Note_Sort_Key{{77, 1}}))
	testing.expect_value(t, btree.count(&conv.note_index), 2)
	testing.expect_value(t, btree.count(&conv.asset_parents), 2)
	_, old_parent := btree.get(&conv.asset_parents, Entity_Reference_Key{u8(pr.ParentType.Task), 91, 1})
	_, new_parent := btree.get(&conv.asset_parents, Entity_Reference_Key{u8(pr.ParentType.Asset), 92, 1})
	testing.expect(t, !old_parent && new_parent)
	// Replay can replace types even when the public patch API forbids it.
	document := alloc_asset(nil, nil, nil)
	document.asset_id = 1
	document.asset_type = .Document
	asset_store_put(&ws, "store-test", conv, document)
	testing.expect_value(t, btree.count(&conv.note_index), 1)
	testing.expect_value(t, btree.count(&conv.asset_parents), 1)
	testing.expect(t, "beta" not_in conv.note_project_assets && "graph" not_in conv.note_tag_assets)
	asset_store_remove(&ws, conv, 2)
	asset_store_remove(&ws, conv, 1)
	asset_store_remove(&ws, conv, 2)
	testing.expect_value(t, len(conv.assets), 0)
	testing.expect_value(t, len(conv.note_index_keys), 0)
	testing.expect_value(t, len(conv.note_project_assets), 0)
	testing.expect_value(t, len(conv.note_tag_assets), 0)
	testing.expect_value(t, btree.count(&conv.asset_parents), 0)
}

@(test)
test_state_store_note_invalid_metadata_replaces_facets :: proc(t: ^testing.T) {
	conv := new(Conversation_State)
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	init_note_index(conv)
	defer destroy_conversation(conv)
	ws := Workspace_State{}
	for preview, i in ([?]string{`{"project":"p","tags":["t"]}`, `{"project":"p","tags":["t",{}]}`, `{"project":"p","tags":["t"]}`}) {
		asset := alloc_asset(nil, transmute([]byte)preview, nil)
		asset.asset_id = 1
		asset.asset_type = .Note
		asset.updated_at = i64(i)
		asset_store_put(&ws, "store-test", conv, asset)
		testing.expect_value(t, btree.count(&conv.note_index), 1)
		testing.expect_value(t, note_secondary_index_count(conv.note_project_assets["p"]), i == 1 ? 0 : 1)
		testing.expect_value(t, note_secondary_index_count(conv.note_tag_assets["t"]), i == 1 ? 0 : 1)
	}
	asset_store_remove(&ws, conv, 1)
	testing.expect_value(t, len(conv.note_project_assets), 0)
	testing.expect_value(t, len(conv.note_tag_assets), 0)
}

@(test)
test_state_store_edge_replace_endpoints_and_self_loop :: proc(t: ^testing.T) {
	conv := new(Conversation_State)
	conv.edges = make(map[pr.EdgeID]^pr.Edge)
	conv.edges_by_entity = make(map[Edge_Entity_Key][dynamic]pr.EdgeID)
	defer destroy_conversation(conv)
	for id in 1 ..< 3 {
		edge := alloc_edge(nil)
		edge.edge_id = pr.EdgeID(id)
		edge.source_type = .Task; edge.source_id = 11
		edge.target_type = .Asset; edge.target_id = 22
		edge_store_put(conv, edge)
	}
	next := alloc_edge(nil)
	next.edge_id = 1
	next.source_type = .Asset; next.source_id = 33
	next.target_type = .Asset; next.target_id = 33
	edge_store_put(conv, next)
	old_source := conv.edges_by_entity[Edge_Entity_Key{.Task, 11}]
	old_target := conv.edges_by_entity[Edge_Entity_Key{.Asset, 22}]
	loop := conv.edges_by_entity[Edge_Entity_Key{.Asset, 33}]
	testing.expect_value(t, len(old_source), 1)
	testing.expect_value(t, len(old_target), 1)
	testing.expect_value(t, len(loop), 2) // one incidence per endpoint, even for a self-loop
	if len(old_source) == 1 do testing.expect_value(t, old_source[0], pr.EdgeID(2))
	if len(old_target) == 1 do testing.expect_value(t, old_target[0], pr.EdgeID(2))
	if len(loop) == 2 do testing.expect(t, loop[0] == 1 && loop[1] == 1)
	edge_store_remove(conv, 1)
	testing.expect(t, Edge_Entity_Key{.Asset, 33} not_in conv.edges_by_entity)
	edge_store_remove(conv, 2)
	edge_store_remove(conv, 1)
	testing.expect_value(t, len(conv.edges), 0)
	testing.expect_value(t, len(conv.edges_by_entity), 0)
}

@(test)
test_state_store_room_mapping_replacement :: proc(t: ^testing.T) {
	strings.intern_init(&td.workspace_intern)
	defer strings.intern_destroy(&td.workspace_intern)
	ws := Workspace_State {
		room_mappings = make(map[string]Room_Mapping_State),
	}
	defer delete(ws.room_mappings)
	conv := new(Conversation_State)
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	init_note_index(conv)
	defer destroy_conversation(conv)
	names := [?]string{" #incident ", " #followup "}
	for name in names {
		asset := alloc_asset(nil, transmute([]byte)name, nil)
		asset.asset_id = 7
		asset.asset_type = .RoomMapping
		asset.conv_id = pr.WORKSPACE_DATA_ID
		asset_store_put(&ws, "mapping-store", conv, asset)
		testing.expect_value(t, len(ws.room_mappings), 1)
	}
	testing.expect(t, "INCIDENT" not_in ws.room_mappings)
	mapping, present := ws.room_mappings["FOLLOWUP"]
	testing.expect(t, present)
	testing.expect_value(t, mapping.asset_id, pr.AssetID(7))
	testing.expect_value(t, mapping.conv_id, make_room_mapping_conv_id("mapping-store", "FOLLOWUP"))
	document := alloc_asset(nil, nil, nil)
	document.asset_id = 7
	document.asset_type = .Document
	document.conv_id = pr.WORKSPACE_DATA_ID
	asset_store_put(&ws, "mapping-store", conv, document)
	testing.expect_value(t, len(ws.room_mappings), 0)
	testing.expect(t, conv.assets[7] == document)
	asset_store_remove(&ws, conv, 7)
	testing.expect_value(t, len(conv.assets), 0)
}
