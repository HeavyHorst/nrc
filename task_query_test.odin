package main

import "btree"
import "core:testing"
import pr "protocol"

task_query_test_add :: proc(conv: ^Conversation_State, task: ^pr.Task) {
	state_map_set(&conv.tasks, task.id, task)
	index_task(conv, task)
}

task_query_test_bytes :: proc(value: string) -> []byte {return transmute([]byte)value}

@(test)
test_task_query_order_filters_cursor_and_indexes :: proc(t: ^testing.T) {
	conv: Conversation_State
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)
	tasks := [5]pr.Task {
		{
			id = 5,
			status = .Todo,
			priority = 2,
			due_at = 0,
			created_at = 50,
			title = task_query_test_bytes("z"),
			assignee = task_query_test_bytes("ann"),
			project = task_query_test_bytes("Beta"),
			color = .Red,
		},
		{
			id = 2,
			status = .Todo,
			priority = 2,
			due_at = 20,
			created_at = 40,
			title = task_query_test_bytes("a"),
			assignee = task_query_test_bytes("ann"),
			project = task_query_test_bytes("Alpha"),
			color = .Red,
			blocked_by = 9,
		},
		{
			id = 8,
			status = .Backlog,
			priority = 1,
			due_at = 10,
			created_at = 30,
			title = task_query_test_bytes("a"),
			assignee = task_query_test_bytes("bob"),
			project = task_query_test_bytes("Alpha"),
			color = .Gold,
		},
		{id = 1, status = .Done, priority = 3, due_at = 5, created_at = 20, title = task_query_test_bytes("m")},
		{
			id = 9,
			status = .Todo,
			priority = 2,
			due_at = 20,
			created_at = 10,
			title = task_query_test_bytes("x"),
			assignee = task_query_test_bytes("ann"),
			project = task_query_test_bytes("Alpha"),
			color = .Red,
			blocked_by = 2,
		},
	}
	for &task in tasks do task_query_test_add(&conv, &task)
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			expected := sort_kind == 0 && direction == 0
			testing.expect_value(t, conv.task_query_indexes.initialized[sort_kind][direction], expected)
		}
	}

	// Expectations are derived from fixture fields, not the query comparator.
	expected_orders := [8][2][5]pr.TaskID {
		{{8, 2, 5, 9, 1}, {1, 2, 5, 9, 8}}, // priority
		{{8, 2, 5, 9, 1}, {1, 2, 5, 9, 8}}, // status
		{{1, 2, 5, 9, 8}, {8, 2, 5, 9, 1}}, // assignee
		{{1, 8, 2, 9, 5}, {2, 9, 8, 1, 5}}, // due, missing last
		{{9, 1, 8, 2, 5}, {5, 2, 8, 1, 9}}, // created
		{{2, 8, 1, 9, 5}, {5, 9, 1, 2, 8}}, // title
		{{1, 2, 5, 9, 8}, {8, 2, 5, 9, 1}}, // color
		{{1, 2, 8, 9, 5}, {5, 2, 8, 9, 1}}, // project
	}
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			reference_req := pr.TaskQueryRequest {
				status_mask = 0x0f,
				limit       = 2,
				sort        = pr.TaskQuerySort(sort_kind),
				descending  = direction == 1,
				color       = 255,
			}
			expected := expected_orders[sort_kind][direction]
			actual := make([dynamic]pr.TaskID)
			for {
				page := make([dynamic]pr.Task)
				page_result := collect_task_query_page(&conv, reference_req, &page)
				for task in page do append(&actual, task.id)
				if !page_result.has_more {
					delete(page)
					break
				}
				reference_req.has_cursor = true
				reference_req.cursor_number = page_result.next_cursor_number
				reference_req.cursor_task_id = page_result.next_cursor_task_id
				delete(reference_req.cursor_text)
				reference_req.cursor_text = make([]byte, len(page_result.next_cursor_text))
				copy(reference_req.cursor_text, page_result.next_cursor_text)
				delete(page)
			}
			testing.expect_value(t, len(actual), len(expected))
			for index in 0 ..< min(len(actual), len(expected)) {
				testing.expect_value(t, actual[index], expected[index])
			}
			delete(reference_req.cursor_text)
			delete(actual)
		}
	}

	out := make([dynamic]pr.Task); defer delete(out)
	req := pr.TaskQueryRequest {
		status_mask = 0x0f,
		limit       = 10,
		sort        = .Priority,
		descending  = true,
		color       = 255,
	}
	result := collect_task_query_page(&conv, req, &out)
	testing.expect_value(t, result.total_count, u32(5))
	testing.expect(
		t,
		len(out) == 5 && out[0].id == 1 && out[1].id == 2 && out[2].id == 5 && out[3].id == 9 && out[4].id == 8,
		"descending ties must retain task id ascending",
	)

	clear(&out)
	req = {
		status_mask = 0x0f,
		limit       = 10,
		sort        = .DueAt,
		descending  = true,
		color       = 255,
	}
	_ = collect_task_query_page(&conv, req, &out)
	testing.expect(t, len(out) == 5 && out[0].id == 2 && out[1].id == 9 && out[4].id == 5, "due zero must remain last in descending order")

	clear(&out)
	req = {
		status_mask    = 0x02,
		limit          = 1,
		sort           = .Title,
		color          = u8(pr.TaskColor.Red),
		blocked        = 1,
		overdue_before = 25,
		has_assignee   = true,
		assignee       = task_query_test_bytes("ann"),
		has_project    = true,
		project        = task_query_test_bytes("Alpha"),
	}
	result = collect_task_query_page(&conv, req, &out)
	testing.expect(t, result.total_count == 2 && result.has_more && out[0].id == 2, "combined predicates should count before limit")
	cursor := result
	owned_cursor := make([]byte, len(cursor.next_cursor_text))
	defer delete(owned_cursor)
	copy(owned_cursor, cursor.next_cursor_text)
	remove_task_from_index(&conv, &tasks[1])
	delete_key(&conv.tasks, tasks[1].id)
	clear(&out)
	req.has_cursor = true
	req.cursor_text = owned_cursor
	req.cursor_task_id = cursor.next_cursor_task_id
	result = collect_task_query_page(&conv, req, &out)
	testing.expect(t, len(out) == 1 && out[0].id == 9 && result.total_count == 1, "deleted cursor must seek by value")

	old := tasks[4]; tasks[4].project = task_query_test_bytes("Delta"); tasks[4].assignee = task_query_test_bytes("zoe")
	replace_task_in_index(&conv, &old, &tasks[4])
	testing.expect_value(t, btree.count(&conv.task_project_indexes["Alpha"].indexes.trees[0][0]), 1)
	testing.expect_value(t, btree.count(&conv.task_assignee_indexes["ann"].indexes.trees[0][0]), 1)
	testing.expect_value(t, btree.count(&conv.task_project_indexes["Delta"].indexes.trees[0][0]), 1)

	clear(&out)
	empty := pr.TaskQueryRequest {
		status_mask  = 0x0f,
		limit        = 10,
		sort         = .Project,
		color        = 255,
		has_project  = true,
		has_assignee = true,
	}
	empty_result := collect_task_query_page(&conv, empty, &out)
	testing.expect(t, empty_result.total_count == 1 && len(out) == 1 && out[0].id == 1, "exact empty filters must use indexed empty values")

	// The title order was instantiated above; replacing a task must update it.
	old = tasks[0]
	tasks[0].title = task_query_test_bytes("0-first")
	replace_task_in_index(&conv, &old, &tasks[0])
	clear(&out)
	empty = {
		status_mask = 0x0f,
		limit       = 10,
		sort        = .Title,
		color       = 255,
	}
	_ = collect_task_query_page(&conv, empty, &out)
	testing.expect(t, len(out) > 0 && out[0].id == 5, "instantiated lazy order must stay current after mutation")
}

@(test)
test_task_query_payload_cursor_accounting_and_legacy_note_total :: proc(t: ^testing.T) {
	conv: Conversation_State
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)

	note := pr.Task {
		id     = 9000,
		status = .Note,
	}
	task_query_test_add(&conv, &note)
	legacy_out := make([dynamic]pr.Task)
	legacy := collect_task_page(&conv, pr.ListTasksPagedRequest{status_mask = 0x10, limit = 10}, &legacy_out)
	testing.expect_value(t, legacy.total_count, u32(1))
	delete(legacy_out)

	max_description := make([]byte, pr.MAX_TASK_DESCRIPTION_LENGTH)
	defer delete(max_description)
	for &value in max_description do value = 'd'
	long_title := make([]byte, pr.MAX_TASK_TITLE_LENGTH)
	defer delete(long_title)
	for &value in long_title do value = 'y'
	short_title := task_query_test_bytes("a")
	fixture := make([dynamic]pr.Task, 0, 1024)
	defer delete(fixture)
	base_page_size := pr.getSizeTaskQueryPage(pr.TaskQueryPage{})
	accumulated := 0
	probe := pr.Task {
		id          = 1,
		status      = .Todo,
		title       = short_title,
		description = max_description[:128],
	}
	max_task_size := pr.getSizeTask(probe)
	final_probe := pr.Task {
		id     = 2,
		status = .Todo,
		title  = long_title,
	}
	final_base_size := pr.getSizeTask(final_probe)
	for MAX_PROTOCOL_PAYLOAD_SIZE - base_page_size - accumulated - final_base_size - 1 > pr.MAX_TASK_DESCRIPTION_LENGTH {
		probe.id = pr.TaskID(len(fixture) + 1)
		append(&fixture, probe)
		accumulated += max_task_size
	}
	final_description_length := MAX_PROTOCOL_PAYLOAD_SIZE - base_page_size - accumulated - final_base_size - 1
	testing.expect(t, final_description_length >= 0 && final_description_length <= pr.MAX_TASK_DESCRIPTION_LENGTH, "boundary fixture must fit task limits")
	final_probe.id = pr.TaskID(len(fixture) + 1)
	final_probe.description = max_description[:final_description_length]
	append(&fixture, final_probe)
	append(&fixture, pr.Task{id = pr.TaskID(len(fixture) + 1), status = .Todo, title = task_query_test_bytes("z")})
	for &task in fixture do task_query_test_add(&conv, &task)

	out := make([dynamic]pr.Task)
	defer delete(out)
	req := pr.TaskQueryRequest {
		status_mask = 0x0f,
		limit       = pr.MAX_TASK_PAGE_SIZE,
		sort        = .Title,
		color       = 255,
	}
	result := collect_task_query_page(&conv, req, &out)
	page := pr.TaskQueryPage {
		tasks            = out[:],
		next_cursor_text = result.next_cursor_text,
	}
	testing.expect(t, result.has_more, "boundary fixture should leave another page")
	testing.expect(t, pr.getSizeTaskQueryPage(page) <= MAX_PROTOCOL_PAYLOAD_SIZE, "cursor text must be included in page payload accounting")
}

@(test)
test_task_projects_chunk_at_transport_boundary :: proc(t: ^testing.T) {
	labels: [1009][128]byte
	projects: [1009]string
	for &label, i in labels {
		for &b in label do b = 'x'
		label[0] = u8('A' + i / 26 / 26)
		label[1] = u8('A' + i / 26 % 26)
		label[2] = u8('A' + i % 26)
		projects[i] = string(label[:])
	}
	count := task_project_chunk_count(projects[:])
	testing.expect_value(t, count, 1008)
	first := pr.TaskProjects {
		conv_id        = 7,
		projects       = projects[:count],
		has_more       = true,
		correlation_id = 123,
	}
	last := pr.TaskProjects {
		conv_id        = 7,
		projects       = projects[count:],
		correlation_id = 123,
	}
	buf := make([]byte, MAX_PROTOCOL_PAYLOAD_SIZE)
	defer delete(buf)
	chunks := [2]pr.TaskProjects{first, last}
	for msg in chunks {
		written := pr.serializeTaskProjects(msg, buf)
		testing.expect(t, written > 0 && written <= MAX_PROTOCOL_PAYLOAD_SIZE)
		testing.expect_value(t, buf[written - 5], msg.has_more ? u8(1) : u8(0))
	}
	testing.expect_value(t, len(last.projects), 1)
	testing.expect_value(t, task_project_chunk_count(nil), 0)
}

@(test)
test_task_assignee_metadata_protocol :: proc(t: ^testing.T) {
	request := [?]byte{0, 57}
	testing.expect_value(t, pr.get_opcode(request[:]), pr.Opcode.C_ListTaskAssignees)
	testing.expect(t, is_workspace_data_opcode(.C_ListTaskAssignees))
	names := [?]string{"alex", "zoe"}
	msg := pr.TaskProjects {
		conv_id        = 0,
		projects       = names[:],
		correlation_id = 321,
	}
	buffer: [128]byte
	written := pr.serializeTaskProjects(msg, buffer[:], .S_TaskAssignees)
	testing.expect_value(t, written, 28)
	testing.expect_value(t, pr.get_opcode(buffer[:written]), pr.Opcode.S_TaskAssignees)
	testing.expect_value(t, buffer[10], u8(0))
	testing.expect_value(t, buffer[11], u8(2))
	testing.expect_value(t, string(buffer[14:18]), "alex")
	testing.expect_value(t, string(buffer[20:23]), "zoe")
	testing.expect_value(t, buffer[23], u8(0))
	testing.expect_value(t, buffer[26], u8(1))
	testing.expect_value(t, buffer[27], u8(65))
}
