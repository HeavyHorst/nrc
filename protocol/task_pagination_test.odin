package protocol

import "core:encoding/endian"
import "core:testing"

@(test)
test_task_pagination_request_round_trip_and_malformed :: proc(t: ^testing.T) {
	req := ListTasksPagedRequest {
		conv_id        = 77,
		status_mask    = 0x0f,
		limit          = 25,
		has_cursor     = true,
		cursor_sort_at = 1234,
		cursor_task_id = 99,
		correlation_id = 42,
	}
	buf: [64]byte
	written := serializeListTasksPagedRequest(req, buf[:])
	testing.expect_value(t, written, 34)
	parsed, err := parseListTasksPagedRequest(buf[2:written])
	testing.expect(t, err == nil, "serialized paged request should parse")
	testing.expect_value(t, parsed, req)

	_, err = parseListTasksPagedRequest(buf[2:written - 1])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
	_, err = parseListTasksPagedRequest(buf[2:written + 1])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
	invalid_mask := buf
	invalid_mask[10] = 0
	_, err = parseListTasksPagedRequest(invalid_mask[2:written])
	testing.expect_value(t, err, ProtocolParseError.InvalidContentType)
	invalid_cursor := buf
	invalid_cursor[13] = 2
	_, err = parseListTasksPagedRequest(invalid_cursor[2:written])
	testing.expect_value(t, err, ProtocolParseError.InvalidContentType)

	get_req := GetTaskRequest {
		conv_id        = 7,
		task_id        = 8,
		correlation_id = 9,
	}
	get_written := serializeGetTaskRequest(get_req, buf[:])
	parsed_get, get_err := parseGetTaskRequest(buf[2:get_written])
	testing.expect(t, get_err == nil, "serialized get-task request should parse")
	testing.expect_value(t, parsed_get, get_req)
	_, get_err = parseGetTaskRequest(buf[2:get_written - 1])
	testing.expect_value(t, get_err, ProtocolParseError.TooShort)
}

@(test)
test_task_query_request_complete_truncation_and_validation :: proc(t: ^testing.T) {
	// Minimal valid cursorless request body (the opcode is handled by the
	// outer protocol parser).
	data: [52]byte
	endian.put_u64(data[0:], .Big, 7)
	data[8] = 0x0f
	endian.put_u16(data[9:], .Big, 10)
	data[11] = u8(TaskQuerySort.Priority)
	data[13] = 255
	endian.put_u32(data[48:], .Big, 9)
	parsed, err := parseTaskQueryRequest(data[:])
	testing.expect(t, err == nil, "minimal task query should parse")
	testing.expect_value(t, parsed.correlation_id, u32(9))

	for length in 0 ..< len(data) {
		_, truncated_err := parseTaskQueryRequest(data[:length])
		testing.expect(t, truncated_err != nil, "every truncated task query must be rejected")
	}

	// The assignee occupies the entire remaining body. This used to index the
	// absent project flag immediately after the slice and panic.
	tail_assignee := data
	tail_assignee[23] = 1
	endian.put_u16(tail_assignee[24:], .Big, u16(len(data) - 26))
	_, err = parseTaskQueryRequest(tail_assignee[:])
	testing.expect(t, err != nil, "assignee consuming the tail must be rejected")

	for invalid_sort in u8(TaskQuerySort.Project) + 1 ..= u8(255) {
		invalid := data
		invalid[11] = invalid_sort
		_, err = parseTaskQueryRequest(invalid[:])
		testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	}
	invalid := data
	invalid[12] = 2
	_, err = parseTaskQueryRequest(invalid[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	invalid = data
	invalid[29] = 2
	_, err = parseTaskQueryRequest(invalid[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	invalid = data
	invalid[29] = 1
	endian.put_i64(invalid[30:], .Big, 1)
	invalid[11] = u8(TaskQuerySort.Title)
	_, err = parseTaskQueryRequest(invalid[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidValue)
}

@(test)
test_task_page_and_full_response_round_trip_and_malformed :: proc(t: ^testing.T) {
	task := Task {
		id           = 5,
		conv_id      = 7,
		title        = transmute([]byte)string("paged"),
		status       = .Done,
		updated_at   = 100,
		completed_at = 200,
	}
	page := TaskListPage {
		conv_id             = 7,
		success             = true,
		tasks               = []Task{task},
		has_more            = true,
		next_cursor_sort_at = 200,
		next_cursor_task_id = 5,
		total_count         = 9,
		correlation_id      = 44,
	}
	buf: [1024]byte
	written := serializeTaskListPage(page, buf[:])
	tasks: [1]Task
	attachments: [MAX_ATTACHMENTS_PER_TASK]Attachment
	parsed, err := parseTaskListPage(buf[:written], tasks[:], attachments[:])
	testing.expect(t, err == nil, "serialized task page should parse")
	testing.expect_value(t, parsed.conv_id, ConversationID(7))
	testing.expect_value(t, len(parsed.tasks), 1)
	testing.expect_value(t, parsed.tasks[0].id, TaskID(5))
	testing.expect_value(t, parsed.next_cursor_sort_at, i64(200))
	testing.expect_value(t, parsed.correlation_id, u32(44))

	wrong_opcode := buf
	endian.put_u16(wrong_opcode[0:], .Big, u16(Opcode.S_TaskFull))
	_, err = parseTaskListPage(wrong_opcode[:written], tasks[:], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)
	_, err = parseTaskListPage(buf[:written - 1], tasks[:], attachments[:])
	testing.expect(t, err != nil, "truncated page should be rejected")
	_, err = parseTaskListPage(buf[:written], tasks[:0], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.TooMany)

	full := TaskFull {
		conv_id        = 7,
		success        = true,
		has_task       = true,
		task           = task,
		correlation_id = 55,
	}
	full_written := serializeTaskFull(full, buf[:])
	parsed_full, full_err := parseTaskFull(buf[:full_written], attachments[:])
	testing.expect(t, full_err == nil, "serialized task full should parse")
	testing.expect(t, parsed_full.has_task, "task full should contain task")
	testing.expect_value(t, parsed_full.task.id, TaskID(5))
	testing.expect_value(t, parsed_full.correlation_id, u32(55))
	_, full_err = parseTaskFull(buf[:full_written + 1], attachments[:])
	testing.expect_value(t, full_err, ProtocolParseError.ContentLengthMismatch)
}
