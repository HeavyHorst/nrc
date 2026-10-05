package main

import "btree"
import "core:testing"

import pr "protocol"

@(test)
test_task_index_equal_timestamps_transitions_and_delete :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)

	tasks := [3]pr.Task {
		{id = 3, status = .Done, updated_at = 20, completed_at = 100},
		{id = 1, status = .Done, updated_at = 30, completed_at = 100},
		{id = 2, status = .Backlog, updated_at = 200},
	}
	for i in 0 ..< len(tasks) {
		conv.tasks[tasks[i].id] = &tasks[i]
		index_task(&conv, &tasks[i])
	}
	testing.expect_value(t, btree.count(&conv.task_index), 3)

	actual: [dynamic]Task_Sort_Key
	defer delete(actual)
	it := btree.iter(&conv.task_index)
	defer btree.iter_destroy(&it)
	for has_item := btree.iter_last(&it); has_item; has_item = btree.iter_prev(&it) {
		append(&actual, btree.item(&it))
	}
	testing.expect_value(t, actual[0], Task_Sort_Key{sort_at = 200, task_id = 2})
	testing.expect_value(t, actual[1], Task_Sort_Key{sort_at = 100, task_id = 3})
	testing.expect_value(t, actual[2], Task_Sort_Key{sort_at = 100, task_id = 1})

	old := tasks[1]
	tasks[1].status = .Todo
	tasks[1].completed_at = 0
	tasks[1].updated_at = 300
	replace_task_in_index(&conv, &old, &tasks[1])
	testing.expect_value(t, conv.task_index_keys[1], Task_Sort_Key{sort_at = 300, task_id = 1})

	remove_task_from_index(&conv, &tasks[0])
	testing.expect_value(t, btree.count(&conv.task_index), 2)
	_, present := conv.task_index_keys[3]
	testing.expect(t, !present, "deleted task should leave no cursor key")
}

@(test)
test_task_recovery_populates_and_replaces_paging_index :: proc(t: ^testing.T) {
	workspace_id := "task-index-recovery"
	if !init_room_mapping_test_state("task_index_recovery.log", workspace_id) {
		testing.expect(t, false, "task recovery fixture should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	parsed := Parsed_Task_Data {
		id           = 41,
		conv_id      = 9,
		title        = transmute([]byte)string("recovered"),
		status       = .Done,
		updated_at   = 100,
		completed_at = 700,
	}
	testing.expect(t, apply_persisted_task(workspace_id, &parsed), "recovered task should apply")
	conv := get_conversation(get_workspace(workspace_id), 9)
	testing.expect(t, conv != nil, "recovery should create conversation")
	if conv == nil do return
	testing.expect_value(t, conv.task_index_keys[41], Task_Sort_Key{sort_at = 700, task_id = 41})

	parsed.status = .Backlog
	parsed.updated_at = 900
	parsed.completed_at = 0
	testing.expect(t, apply_persisted_task(workspace_id, &parsed), "replayed update should replace task")
	testing.expect_value(t, btree.count(&conv.task_index), 1)
	testing.expect_value(t, conv.task_index_keys[41], Task_Sort_Key{sort_at = 900, task_id = 41})

	apply_persisted_delete(workspace_id, 9, 41)
	testing.expect_value(t, btree.count(&conv.task_index), 0)
}
