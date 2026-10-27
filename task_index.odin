package main

import "btree"
import "core:strings"
import pr "protocol"

Task_Numeric_Projection :: enum u8 {
	Time,
	Enum_Value,
}

Task_Query_Order :: btree.Static_Order(Task_Query_Key, Task_Numeric_Projection, task_query_compare_static, task_query_text_key_static, task_query_numeric_key)
Task_Sort_Order :: btree.Static_Order(Task_Sort_Key, btree.No_Projection, task_sort_compare_static)

task_query_numeric_key :: #force_inline proc(item: rawptr, descending: bool, projection: rawptr) -> u64 {
	key := (cast(^Task_Query_Key)item)^
	missing := key.due_missing ? u64(1) << 63 : 0
	if (cast(^Task_Numeric_Projection)projection)^ == .Enum_Value {
		// 1 missing bit, 8 ordered number bits, 1 text-emptiness bit, 54 ID bits.
		// Saturated number buckets omit ALL suffix fields, including at the
		// endpoints: distinct numbers there must never be reordered by an ID.
		number := u64(clamp(key.number, -128, 127) + 128)
		suffix: u64
		if number != 0 && number != 255 {
			nonempty := len(key.text) != 0
			if nonempty != descending do suffix = u64(1) << 54
			if !nonempty do suffix |= min(u64(key.task_id), (u64(1) << 54) - 1)
		}
		if descending do number = 255 - number
		return missing | (number << 55) | suffix
	}
	number := u64(key.number) ~ (u64(1) << 63)
	if descending do number = ~number
	// Retain missing-last for arbitrary cursors; lost low bits only create ties.
	return missing | (number >> 1)
}

task_query_compare_static :: #force_inline proc(a, b: rawptr, descending: bool) -> int {
	if descending do return task_query_key_compare_desc((cast(^Task_Query_Key)a)^, (cast(^Task_Query_Key)b)^)
	return task_query_key_compare_asc((cast(^Task_Query_Key)a)^, (cast(^Task_Query_Key)b)^)
}

task_query_text_key_static :: proc(item: rawptr) -> (text: string, ok: bool) {
	return task_query_text_key((cast(^Task_Query_Key)item)^)
}

task_sort_compare_static :: proc(a, b: rawptr, descending: bool) -> int {
	return task_sort_key_compare((cast(^Task_Sort_Key)a)^, (cast(^Task_Sort_Key)b)^)
}

task_query_bytes_compare :: proc(a, b: []byte) -> int {
	// Empty slices compare equally regardless of their backing pointer.
	if len(a) == 0 || len(b) == 0 {
		if len(a) < len(b) do return -1
		if len(a) > len(b) do return 1
		return 0
	}
	return strings.compare(string(a), string(b))
}

task_query_text_key :: proc(key: Task_Query_Key) -> (text: string, ok: bool) {
	// Non-text cursor fields retain the full comparator's ordering semantics.
	return string(key.text), key.number == 0 && !key.due_missing
}

task_query_key_compare_asc :: #force_inline proc(a, b: Task_Query_Key) -> int {
	if a.due_missing != b.due_missing do return a.due_missing ? 1 : -1
	if a.number < b.number do return -1
	if a.number > b.number do return 1
	text_cmp := task_query_bytes_compare(a.text, b.text); if text_cmp != 0 do return text_cmp
	if a.task_id < b.task_id do return -1; if a.task_id > b.task_id do return 1; return 0
}

task_query_key_compare_desc :: #force_inline proc(a, b: Task_Query_Key) -> int {
	if a.due_missing != b.due_missing do return a.due_missing ? 1 : -1
	if a.number > b.number do return -1
	if a.number < b.number do return 1
	text_cmp := task_query_bytes_compare(a.text, b.text); if text_cmp > 0 do return -1; if text_cmp < 0 do return 1
	if a.task_id < b.task_id do return -1; if a.task_id > b.task_id do return 1; return 0
}

task_query_index_set_init :: proc(set: ^Task_Query_Index_Set) {
	set.trees[0][0] = btree.create_ordered(
		Task_Query_Key,
		Task_Query_Order,
		btree.Options{degree = 32},
		cache = .Numeric,
		projection = Task_Numeric_Projection(.Enum_Value),
	)
	set.initialized[0][0] = true
}
task_query_index_set_destroy :: proc(set: ^Task_Query_Index_Set) {
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			if set.initialized[sort_kind][direction] {
				btree.destroy(&set.trees[sort_kind][direction])
				set.initialized[sort_kind][direction] = false
			}
		}
	}
}

make_task_query_key :: proc(task: ^pr.Task, sort_kind: pr.TaskQuerySort) -> Task_Query_Key {
	key := Task_Query_Key {
		task_id = task.id,
	}
	switch sort_kind {
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
	case .WorkOrder:
		panic("WorkOrder uses the dependency graph, not a scalar index")
	}
	return key
}

task_query_index_set_add :: proc(set: ^Task_Query_Index_Set, task: ^pr.Task) {
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			if set.initialized[sort_kind][direction] {
				_, _ = btree.set(&set.trees[sort_kind][direction], make_task_query_key(task, pr.TaskQuerySort(sort_kind)))
			}
		}
	}
}
task_query_index_set_remove :: proc(set: ^Task_Query_Index_Set, task: ^pr.Task) {
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			if set.initialized[sort_kind][direction] {
				_, removed := btree.remove(&set.trees[sort_kind][direction], make_task_query_key(task, pr.TaskQuerySort(sort_kind)))
				assert(!ODIN_DEBUG || removed, "task query key missing or changed without reindexing")
			}
		}
	}
}

task_query_index_set_ensure_order :: proc(
	set: ^Task_Query_Index_Set,
	tasks: ^map[pr.TaskID]^pr.Task,
	sort_kind: pr.TaskQuerySort,
	descending: bool,
) -> ^btree.BTreeG(Task_Query_Key, Task_Query_Order) {
	direction := descending ? 1 : 0
	sort_index := int(sort_kind)
	if set.initialized[sort_index][direction] do return &set.trees[sort_index][direction]
	cache: btree.Cache_Mode = .None
	projection: Task_Numeric_Projection = .Time
	if sort_kind == .Title || sort_kind == .Project || sort_kind == .Assignee do cache = .Text
	if sort_kind == .CreatedAt do cache = .Numeric
	if sort_kind == .Priority || sort_kind == .Status || sort_kind == .Color {
		cache = .Numeric
		projection = .Enum_Value
	}
	set.trees[sort_index][direction] = btree.create_ordered(
		Task_Query_Key,
		Task_Query_Order,
		btree.Options{degree = 32},
		cache = cache,
		descending = descending,
		projection = projection,
	)
	membership := &set.trees[0][0]
	it := btree.iter(membership)
	defer btree.iter_destroy(&it)
	for found := btree.iter_first(&it); found; found = btree.iter_next(&it) {
		task := tasks^[btree.item(&it).task_id]
		if task != nil {
			_, _ = btree.set(&set.trees[sort_index][direction], make_task_query_key(task, sort_kind))
		}
	}
	set.initialized[sort_index][direction] = true
	return &set.trees[sort_index][direction]
}

task_query_secondary_get :: proc(indexes: ^map[string]^Task_Query_Secondary_Index, value: []byte) -> ^Task_Query_Secondary_Index {
	key := string(value); if index, ok := indexes^[key]; ok do return index
	owned, err := strings.clone(key); if err != nil do panic("task query index key clone failed")
	index := new(Task_Query_Secondary_Index); index.key = owned; task_query_index_set_init(&index.indexes)
	state_map_set(indexes, index.key, index); return index
}
task_query_secondary_remove :: proc(indexes: ^map[string]^Task_Query_Secondary_Index, task: ^pr.Task, value: []byte) {
	index := indexes^[string(value)]; if index == nil do return
	task_query_index_set_remove(&index.indexes, task)
	if btree.count(&index.indexes.trees[0][0]) ==
	   0 {delete_key(indexes, index.key); task_query_index_set_destroy(&index.indexes); delete(index.key); free(index)}
}

task_sort_key_compare :: proc(a, b: Task_Sort_Key) -> int {
	if a.sort_at < b.sort_at do return -1
	if a.sort_at > b.sort_at do return 1
	if a.task_id < b.task_id do return -1
	if a.task_id > b.task_id do return 1
	return 0
}

task_status_is_active :: proc(status: pr.TaskStatus) -> bool {
	return status == .Backlog || status == .Todo || status == .InProgress
}

task_matches_status_mask :: proc(task: ^pr.Task, status_mask: u8) -> bool {
	if task == nil || u8(task.status) >= 5 do return false
	return status_mask & (u8(1) << u8(task.status)) != 0
}

make_task_sort_key :: proc(task: ^pr.Task) -> Task_Sort_Key {
	sort_at := task.updated_at
	if task.status == .Done do sort_at = task.completed_at
	return Task_Sort_Key{sort_at = sort_at, task_id = task.id}
}

init_task_index :: proc(conv: ^Conversation_State) {
	conv.task_index = btree.create_ordered(Task_Sort_Key, Task_Sort_Order, btree.Options{degree = 32})
	conv.task_index_keys = make(map[pr.TaskID]Task_Sort_Key, 128)
	task_query_index_set_init(&conv.task_query_indexes)
	for status in 0 ..< 4 do task_query_index_set_init(&conv.task_status_indexes[status])
	conv.task_project_indexes = make(map[string]^Task_Query_Secondary_Index, 16)
	conv.task_assignee_indexes = make(map[string]^Task_Query_Secondary_Index, 16)
	conv.task_blockers = relation_tree_create()
}

destroy_task_index :: proc(conv: ^Conversation_State) {
	calendar_index_destroy(conv)
	btree.destroy(&conv.task_index)
	delete(conv.task_index_keys)
	task_query_index_set_destroy(&conv.task_query_indexes)
	for status in 0 ..< 4 do task_query_index_set_destroy(&conv.task_status_indexes[status])
	for _, index in conv.task_project_indexes {task_query_index_set_destroy(&index.indexes); delete(index.key); free(index)}; delete(conv.task_project_indexes)
	for _, index in conv.task_assignee_indexes {task_query_index_set_destroy(&index.indexes); delete(index.key); free(index)}; delete(conv.task_assignee_indexes)
	btree.destroy(&conv.task_blockers)
}

index_task :: proc(conv: ^Conversation_State, task: ^pr.Task) {
	if conv == nil || task == nil do return
	calendar_index_task(conv, task)
	key := make_task_sort_key(task)
	_, _ = btree.set(&conv.task_index, key)
	state_map_set(&conv.task_index_keys, task.id, key)
	if u8(task.status) < 4 {
		task_query_index_set_add(&conv.task_query_indexes, task); task_query_index_set_add(&conv.task_status_indexes[u8(task.status)], task)
		task_query_index_set_add(&task_query_secondary_get(&conv.task_project_indexes, task.project).indexes, task)
		task_query_index_set_add(&task_query_secondary_get(&conv.task_assignee_indexes, task.assignee).indexes, task)
	}
	if task.blocked_by != 0 {
		relation_tree_index(&conv.task_blockers, Entity_Reference_Key{parent_id = u64(task.blocked_by), entity_id = u64(task.id)})
	}
}

remove_task_from_index :: proc(conv: ^Conversation_State, task: ^pr.Task) {
	if conv == nil || task == nil do return
	calendar_index_task(conv, task, true)
	key, ok := conv.task_index_keys[task.id]
	when ODIN_DEBUG do assert(ok, "stored task is missing its index key")
	if !ok do return
	when ODIN_DEBUG do assert(key == make_task_sort_key(task), "task changed without reindexing")
	if task.blocked_by != 0 {
		relation_tree_remove(&conv.task_blockers, Entity_Reference_Key{parent_id = u64(task.blocked_by), entity_id = u64(task.id)})
	}
	if u8(task.status) < 4 {
		task_query_index_set_remove(&conv.task_query_indexes, task); task_query_index_set_remove(&conv.task_status_indexes[u8(task.status)], task)
		task_query_secondary_remove(
			&conv.task_project_indexes,
			task,
			task.project,
		); task_query_secondary_remove(&conv.task_assignee_indexes, task, task.assignee)
	}
	_, _ = btree.remove(&conv.task_index, key)
	delete_key(&conv.task_index_keys, task.id)
}

replace_task_in_index :: proc(conv: ^Conversation_State, old_task, new_task: ^pr.Task) {
	remove_task_from_index(conv, old_task)
	index_task(conv, new_task)
}
