package main

import "core:testing"

import "btree"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: hgl.run
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	TASK_PAGING_EQ_CONV :: pr.WORKSPACE_DATA_ID
	TASK_PAGING_EQ_COUNT :: 6

	Task_Paging_Equivalence_State :: struct {
		task_bytes:      [TASK_PAGING_EQ_COUNT][512]byte,
		task_lens:       [TASK_PAGING_EQ_COUNT]int,
		keys:            [TASK_PAGING_EQ_COUNT]Task_Sort_Key,
		key_present:     [TASK_PAGING_EQ_COUNT]bool,
		btree_keys:      [TASK_PAGING_EQ_COUNT]Task_Sort_Key,
		btree_key_count: int,
		task_count:      int,
		active_count:    int,
		index_count:     int,
		btree_count:     int,
		task_seq:        u64,
	}

	Task_Paging_Equivalence_Result :: struct {
		response:     [4_096]byte,
		response_len: int,
	}

	task_paging_equivalence_setup :: proc(conv: ^Conversation_State) -> bool {
		fixtures := [?]struct {
			id:           pr.TaskID,
			status:       pr.TaskStatus,
			updated_at:   i64,
			completed_at: i64,
		}{{1, .Backlog, 100, 0}, {2, .Todo, 300, 0}, {3, .Done, 50, 300}, {4, .Done, 75, 300}, {5, .InProgress, 200, 0}, {6, .Note, 150, 0}}
		for fixture in fixtures {
			titles := [6]string{"backlog", "todo", "done-three", "done-four", "progress", "note"}
			task := alloc_task(
				transmute([]byte)titles[int(fixture.id) - 1],
				transmute([]byte)string("paged fixture"),
				nil,
				transmute([]byte)string("fixture-user"),
				nil,
				fixture.status == .Done ? transmute([]byte)string("closer") : nil,
				transmute([]byte)string("simulation"),
				nil,
			)
			if task == nil do return false
			task.id = fixture.id
			task.conv_id = TASK_PAGING_EQ_CONV
			task.status = fixture.status
			task.order_index = u16(fixture.id * 10)
			task.priority = u8(fixture.id % 5)
			task.created_at = 10 + i64(fixture.id)
			task.updated_at = fixture.updated_at
			task.completed_at = fixture.completed_at
			conv.tasks[fixture.id] = task
			index_task(conv, task)
		}
		return true
	}

	task_paging_equivalence_capture_state :: proc(conv: ^Conversation_State) -> (Task_Paging_Equivalence_State, bool) {
		state: Task_Paging_Equivalence_State
		if conv == nil do return state, false
		for id in 1 ..= TASK_PAGING_EQ_COUNT {
			task := conv.tasks[pr.TaskID(id)]
			if task == nil && len(conv.tasks) == 0 do continue
			if task == nil do return state, false
			state.task_lens[id - 1] = pr.serializeTask(task^, state.task_bytes[id - 1][:])
			if state.task_lens[id - 1] <= 0 do return state, false
			state.keys[id - 1], state.key_present[id - 1] = conv.task_index_keys[pr.TaskID(id)]
		}
		it := btree.iter(&conv.task_index)
		defer btree.iter_destroy(&it)
		for has_item := btree.iter_first(&it); has_item; has_item = btree.iter_next(&it) {
			if state.btree_key_count >= len(state.btree_keys) do return state, false
			state.btree_keys[state.btree_key_count] = btree.item(&it)
			state.btree_key_count += 1
		}
		state.task_count = len(conv.tasks)
		state.active_count = conv.active_task_count
		state.index_count = len(conv.task_index_keys)
		state.btree_count = btree.count(&conv.task_index)
		state.task_seq = td.task_seq
		return state, true
	}

	task_paging_equivalence_states_equal :: proc(a, b: Task_Paging_Equivalence_State) -> bool {
		if a.task_lens != b.task_lens || a.keys != b.keys || a.key_present != b.key_present || a.btree_keys != b.btree_keys {
			return false
		}
		for i in 0 ..< TASK_PAGING_EQ_COUNT do for j in 0 ..< a.task_lens[i] do if a.task_bytes[i][j] != b.task_bytes[i][j] do return false
		return(
			a.task_count == b.task_count &&
			a.btree_key_count == b.btree_key_count &&
			a.active_count == b.active_count &&
			a.index_count == b.index_count &&
			a.btree_count == b.btree_count &&
			a.task_seq == b.task_seq \
		)
	}

	task_paging_equivalence_model :: proc(conv: ^Conversation_State, req: pr.ListTasksPagedRequest, out: []byte) -> int {
		storage: [TASK_PAGING_EQ_COUNT]pr.Task
		if len(conv.tasks) == 0 {
			return pr.serializeTaskListPage(pr.TaskListPage{conv_id = req.conv_id, success = true, correlation_id = req.correlation_id}, out)
		}
		ordered := [TASK_PAGING_EQ_COUNT]pr.TaskID{4, 3, 2, 5, 6, 1}
		matching: [TASK_PAGING_EQ_COUNT]pr.TaskID
		matching_count := 0
		for id in ordered {
			task := conv.tasks[id]
			if req.status_mask & (u8(1) << u8(task.status)) == 0 do continue
			key_sort_at := task.updated_at
			if task.status == .Done do key_sort_at = task.completed_at
			if req.has_cursor && !(key_sort_at < req.cursor_sort_at || (key_sort_at == req.cursor_sort_at && id < req.cursor_task_id)) {
				continue
			}
			matching[matching_count] = id
			matching_count += 1
		}
		count := min(int(req.limit), matching_count)
		for i in 0 ..< count do storage[i] = conv.tasks[matching[i]]^
		message := pr.TaskListPage {
			conv_id        = req.conv_id,
			success        = true,
			tasks          = storage[:count],
			has_more       = matching_count > count,
			total_count    = 0,
			correlation_id = req.correlation_id,
		}
		for id in ordered {
			task := conv.tasks[id]
			if req.status_mask & (u8(1) << u8(task.status)) != 0 do message.total_count += 1
		}
		if count > 0 {
			last := storage[count - 1]
			message.next_cursor_sort_at = last.updated_at
			if last.status == .Done do message.next_cursor_sort_at = last.completed_at
			message.next_cursor_task_id = last.id
		}
		return pr.serializeTaskListPage(message, out)
	}

	task_paging_equivalence_serialize_and_validate :: proc(req: pr.ListTasksPagedRequest, buf: []byte) -> (int, bool) {
		n := pr.serializeListTasksPagedRequest(req, buf)
		if n <= 0 do return n, false
		parsed, parse_err := pr.parseListTasksPagedRequest(buf[2:n])
		return n,
			parse_err == nil &&
			parsed.conv_id == req.conv_id &&
			parsed.status_mask == req.status_mask &&
			parsed.limit == req.limit &&
			parsed.has_cursor == req.has_cursor &&
			parsed.cursor_sort_at == req.cursor_sort_at &&
			parsed.cursor_task_id == req.cursor_task_id &&
			parsed.correlation_id == req.correlation_id
	}

	task_paging_equivalence_run :: proc(
		req: pr.ListTasksPagedRequest,
		wire: bool,
		split_a, split_b: int,
		empty_workspace := false,
	) -> (
		Task_Paging_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, wire ? 183 : 182)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "task-paging-equivalence", "reader")
		if c == nil do return {}, "install task paging client", false
		ctx.conns[1] = c
		conv := get_or_create_conversation(get_connection_workspace(c), TASK_PAGING_EQ_CONV)
		if !empty_workspace && !task_paging_equivalence_setup(conv) do return {}, "install task paging fixture", false
		td.task_seq = 606
		before, before_ok := task_paging_equivalence_capture_state(conv)
		if !before_ok do return {}, "capture task paging baseline", false
		nrc_sim_clear_inboxes(&ctx.sim)
		if wire {
			request_buf: [64]byte
			request_len, parser_ok := task_paging_equivalence_serialize_and_validate(req, request_buf[:])
			if !parser_ok do return {}, "production task paging parser did not preserve request", false
			if !handler_equivalence_deliver_wire(&ctx.sim, c, request_buf[:request_len], split_a, split_b) {
				return {}, "deliver split task paging request", false
			}
		} else {
			process_list_tasks_paged(c, req)
		}

		result: Task_Paging_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim, c.sock) != 1 do return result, "unexpected task paging response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, c.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture task paging response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		parsed_tasks: [TASK_PAGING_EQ_COUNT]pr.Task
		parsed_attachments: [TASK_PAGING_EQ_COUNT * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		_, parse_err := pr.parseTaskListPage(payload, parsed_tasks[:], parsed_attachments[:])
		if parse_err != nil do return result, "parse task paging response", false
		expected: [4_096]byte
		expected_len := task_paging_equivalence_model(conv, req, expected[:])
		if expected_len != len(payload) do return result, "task paging model response length", false
		for value, i in payload do if value != expected[i] do return result, "task paging model response bytes", false
		after, after_ok := task_paging_equivalence_capture_state(conv)
		if !after_ok || !task_paging_equivalence_states_equal(before, after) {
			return result, "task paging query mutated state/index/ID sequence", false
		}
		return result, "", true
	}

	task_paging_equivalence_results_equal :: proc(a, b: Task_Paging_Equivalence_Result) -> bool {
		if a.response_len != b.response_len do return false
		for i in 0 ..< a.response_len do if a.response[i] != b.response[i] do return false
		return true
	}

	prop_task_paging_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		selector, selector_err := hgl.draw_i64(tc, 0, 255)
		if selector_err == .Stop_Test do return hgl.abort()
		if selector_err != nil do return hgl.interesting("task paging selector draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("task paging correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("task paging first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("task paging second split draw failed")
		masks := [4]u8{0x1f, 1 << u8(pr.TaskStatus.Done), 1 << u8(pr.TaskStatus.Todo), (1 << u8(pr.TaskStatus.InProgress)) | (1 << u8(pr.TaskStatus.Note))}
		limits := [3]u16{1, 2, pr.MAX_TASK_PAGE_SIZE}
		has_cursor := selector & 1 != 0
		cursor_sort_at: i64
		cursor_task_id: pr.TaskID
		switch (selector / 2) % 3 {
		case 0:
			cursor_sort_at, cursor_task_id = 300, 3
		case 1:
			cursor_sort_at, cursor_task_id = 225, 99
		case 2:
			cursor_sort_at, cursor_task_id = 50, 1
		}
		req := pr.ListTasksPagedRequest {
			conv_id        = TASK_PAGING_EQ_CONV,
			status_mask    = masks[(selector / 8) % i64(len(masks))],
			limit          = limits[(selector / 32) % i64(len(limits))],
			has_cursor     = has_cursor,
			cursor_sort_at = has_cursor ? cursor_sort_at : 0,
			cursor_task_id = has_cursor ? cursor_task_id : 0,
			correlation_id = u32(correlation),
		}
		direct, direct_reason, direct_ok := task_paging_equivalence_run(req, false, 0, 0, selector & 64 != 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := task_paging_equivalence_run(req, true, int(split_a), int(split_b), selector & 64 != 0)
		if !wire_ok do return hgl.interesting(wire_reason)
		if !task_paging_equivalence_results_equal(direct, wire) do return hgl.interesting("direct and split-wire task paging semantics differ")
		return hgl.valid()
	}

	task_paging_equivalence_mandatory_cases :: proc(t: ^testing.T) -> bool {
		requests := [?]pr.ListTasksPagedRequest {
			{conv_id = TASK_PAGING_EQ_CONV, status_mask = 0x1f, limit = 2, correlation_id = 0x8200},
			{conv_id = TASK_PAGING_EQ_CONV, status_mask = 1 << u8(pr.TaskStatus.Done), limit = 1, correlation_id = 0x8201},
			{
				conv_id = TASK_PAGING_EQ_CONV,
				status_mask = 0x1f,
				limit = 2,
				has_cursor = true,
				cursor_sort_at = 300,
				cursor_task_id = 3,
				correlation_id = 0x8202,
			},
			{
				conv_id = TASK_PAGING_EQ_CONV,
				status_mask = (1 << u8(pr.TaskStatus.InProgress)) | (1 << u8(pr.TaskStatus.Note)),
				limit = pr.MAX_TASK_PAGE_SIZE,
				has_cursor = true,
				cursor_sort_at = 225,
				cursor_task_id = 99,
				correlation_id = 0x8203,
			},
			{conv_id = TASK_PAGING_EQ_CONV, status_mask = 0x1f, limit = 2, correlation_id = 0x8204},
		}
		for req, i in requests {
			// The former missing-room case is now an empty workspace data scope.
			direct, direct_reason, direct_ok := task_paging_equivalence_run(req, false, 0, 0, i == 4)
			testing.expectf(t, direct_ok, "mandatory task paging direct case=%d failed: %s", i, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := task_paging_equivalence_run(req, true, i + 3, i + 17, i == 4)
			testing.expectf(t, wire_ok, "mandatory task paging wire case=%d failed: %s", i, wire_reason)
			if !wire_ok do return false
			equal := task_paging_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory task paging case=%d semantics should match", i)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_task_paging_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !task_paging_equivalence_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_task_paging_parser_direct_equivalence, nil, {test_cases = 64})
		testing.expectf(t, err == nil, "generated task paging parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
