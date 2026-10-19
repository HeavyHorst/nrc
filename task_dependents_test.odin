package main

import "core:testing"
import pr "protocol"

@(test)
test_task_dependents_pages :: proc(t: ^testing.T) {
	conv := Conversation_State{}
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)
	wide :: pr.TaskID(1) << 60
	fixtures := [?]pr.Task{{id = 1}, {id = 2}, {id = 3}, {id = wide + 3, blocked_by = 1}, {id = wide + 1, blocked_by = 1}, {id = wide + 2, blocked_by = 2}}
	for &task in fixtures {
		conv.tasks[task.id] = &task
		index_task(&conv, &task)
	}
	rows: [dynamic]pr.Task
	defer delete(rows)
	req := pr.ListTaskDependentsRequest {
		task_id        = 1,
		limit          = 1,
		correlation_id = 19,
	}
	page := collect_task_dependents_page(&conv, req, &rows)
	testing.expect(t, page.success && page.has_more)
	testing.expect_value(t, len(page.tasks), 1)
	testing.expect_value(t, page.tasks[0].id, wide + 1)
	testing.expect_value(t, page.next_task_id, wide + 1)
	testing.expect_value(t, page.correlation_id, u32(19))
	clear(&rows)
	req.after_task_id = wide + 1
	page = collect_task_dependents_page(&conv, req, &rows)
	testing.expect(t, page.success && !page.has_more)
	testing.expect_value(t, page.tasks[0].id, wide + 3)
	clear(&rows)
	req.after_task_id = wide + 2 // absent cursor must seek the next ID
	page = collect_task_dependents_page(&conv, req, &rows)
	testing.expect_value(t, page.tasks[0].id, wide + 3)
	clear(&rows)
	req.after_task_id = wide + 3
	page = collect_task_dependents_page(&conv, req, &rows)
	testing.expect(t, page.success && !page.has_more && len(page.tasks) == 0 && page.next_task_id == 0)
	req.task_id = 3
	req.after_task_id = 0
	page = collect_task_dependents_page(&conv, req, &rows)
	testing.expect(t, page.success && len(page.tasks) == 0)
	req.task_id = 99
	page = collect_task_dependents_page(&conv, req, &rows)
	testing.expect(t, !page.success && string(page.error) == "task_not_found")
	page = collect_task_dependents_page(nil, req, &rows)
	testing.expect(t, !page.success && string(page.error) == "task_not_found")
	testing.expect(t, is_workspace_data_opcode(.C_ListTaskDependents))

	// Valid, serializable records must split at the existing byte budget.
	large := make([]byte, pr.MAX_TASK_DESCRIPTION_LENGTH)
	defer delete(large)
	bulk: [40]pr.Task
	for &task, i in bulk {
		task = pr.Task {
			id          = wide + 100 + pr.TaskID(i),
			blocked_by  = 3,
			description = large,
		}
		conv.tasks[task.id] = &task
		index_task(&conv, &task)
	}
	buf := make([]byte, MAX_PROTOCOL_PAYLOAD_SIZE)
	defer delete(buf)
	req.task_id = 3
	req.limit = pr.MAX_TASK_PAGE_SIZE
	page = collect_task_dependents_page(&conv, req, &rows)
	testing.expect(t, page.success && page.has_more && len(page.tasks) > 0 && len(page.tasks) < len(bulk))
	testing.expect(t, pr.getSizeTaskDependentsPage(page) <= MAX_PROTOCOL_PAYLOAD_SIZE)
	testing.expect(t, pr.serializeTaskDependentsPage(page, buf) > 0)
	first_count := len(page.tasks)
	clear(&rows)
	req.after_task_id = page.next_task_id
	page = collect_task_dependents_page(&conv, req, &rows)
	testing.expect(t, page.success && !page.has_more && len(page.tasks) + first_count == len(bulk))
	testing.expect(t, pr.serializeTaskDependentsPage(page, buf) > 0)
}
