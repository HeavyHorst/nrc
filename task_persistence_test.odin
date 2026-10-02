package main

import "core:bytes"
import "core:encoding/endian"
import "core:testing"

import hgl "hegel"
import pr "protocol"

task_codec_fill :: proc(data: []byte, seed: u64) {
	for i in 0 ..< len(data) {
		data[i] = byte((seed + u64(i) * 131) & 0xff)
	}
}

task_codec_equal_attachment :: proc(a, b: pr.Attachment) -> bool {
	return(
		bytes.equal(a.file_id, b.file_id) &&
		bytes.equal(a.filename, b.filename) &&
		a.size == b.size &&
		bytes.equal(a.mime_type, b.mime_type) &&
		a.uploaded_at == b.uploaded_at \
	)
}

task_codec_equal_parsed :: proc(task: ^pr.Task, parsed: ^Parsed_Task_Data) -> bool {
	if parsed.id != task.id ||
	   parsed.conv_id != task.conv_id ||
	   !bytes.equal(parsed.title, task.title) ||
	   !bytes.equal(parsed.description, task.description) ||
	   parsed.status != task.status ||
	   parsed.order_index != task.order_index ||
	   !bytes.equal(parsed.assignee, task.assignee) ||
	   parsed.priority != task.priority ||
	   parsed.color != task.color ||
	   !bytes.equal(parsed.created_by, task.created_by) ||
	   parsed.created_at != task.created_at ||
	   parsed.updated_at != task.updated_at ||
	   !bytes.equal(parsed.external_ref, task.external_ref) ||
	   parsed.due_at != task.due_at ||
	   parsed.blocked_by != task.blocked_by ||
	   parsed.completed_at != task.completed_at ||
	   !bytes.equal(parsed.completed_by, task.completed_by) ||
	   !bytes.equal(parsed.project, task.project) ||
	   parsed.attachment_count != len(task.attachments) {
		return false
	}
	for i in 0 ..< parsed.attachment_count {
		if !task_codec_equal_attachment(parsed.attachments[i], task.attachments[i]) do return false
	}
	return true
}

task_codec_complete_roundtrip_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed, seed_err := hgl.draw_u64(tc, 1, u64(max(i64)))
	attachment_count_raw, count_err := hgl.draw_i64(tc, 1, pr.MAX_ATTACHMENTS_PER_TASK)
	if seed_err == .Stop_Test || count_err == .Stop_Test do return hgl.abort()
	if seed_err != nil || count_err != nil do return hgl.interesting("draw complete task")

	title: [pr.MAX_TASK_TITLE_LENGTH]byte
	description: [pr.MAX_TASK_DESCRIPTION_LENGTH]byte
	assignee: [pr.MAX_ASSIGNEE_LENGTH]byte
	created_by: [pr.MAX_USER_ID_LENGTH]byte
	external_ref: [pr.MAX_EXTERNAL_REF_LENGTH]byte
	completed_by: [pr.MAX_USER_ID_LENGTH]byte
	project: [pr.MAX_PROJECT_LENGTH]byte
	task_codec_fill(title[:], seed)
	task_codec_fill(description[:], seed + 1)
	task_codec_fill(assignee[:], seed + 2)
	task_codec_fill(created_by[:], seed + 3)
	task_codec_fill(external_ref[:], seed + 4)
	task_codec_fill(completed_by[:], seed + 5)
	task_codec_fill(project[:], seed + 6)

	attachment_count := int(attachment_count_raw)
	attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	file_ids: [pr.MAX_ATTACHMENTS_PER_TASK][pr.MAX_FILE_ID_LENGTH]byte
	filenames: [pr.MAX_ATTACHMENTS_PER_TASK][pr.MAX_FILENAME_LENGTH]byte
	mime_types: [pr.MAX_ATTACHMENTS_PER_TASK][pr.MAX_MIME_TYPE_LENGTH]byte
	for i in 0 ..< attachment_count {
		file_id_len := 1 + int((seed + u64(i)) % pr.MAX_FILE_ID_LENGTH)
		filename_len := 1 + int((seed + u64(i) * 3) % pr.MAX_FILENAME_LENGTH)
		mime_len := 1 + int((seed + u64(i) * 5) % pr.MAX_MIME_TYPE_LENGTH)
		task_codec_fill(file_ids[i][:file_id_len], seed + u64(i) + 10)
		task_codec_fill(filenames[i][:filename_len], seed + u64(i) + 20)
		task_codec_fill(mime_types[i][:mime_len], seed + u64(i) + 30)
		attachments[i] = {
			file_id     = file_ids[i][:file_id_len],
			filename    = filenames[i][:filename_len],
			size        = seed * 17 + u64(i),
			mime_type   = mime_types[i][:mime_len],
			uploaded_at = i64(seed >> 1) - i64(i),
		}
	}

	task := pr.Task {
		id           = pr.TaskID(seed),
		conv_id      = pr.ConversationID(seed + 1),
		title        = title[:1 + int(seed % pr.MAX_TASK_TITLE_LENGTH)],
		description  = description[:1 + int(seed % pr.MAX_TASK_DESCRIPTION_LENGTH)],
		status       = pr.TaskStatus(seed % 5),
		order_index  = u16(seed),
		assignee     = assignee[:1 + int(seed % pr.MAX_ASSIGNEE_LENGTH)],
		priority     = u8(seed),
		color        = pr.TaskColor(seed % 6),
		created_by   = created_by[:1 + int(seed % pr.MAX_USER_ID_LENGTH)],
		created_at   = i64(seed >> 1),
		updated_at   = -i64(seed >> 2),
		external_ref = external_ref[:1 + int(seed % pr.MAX_EXTERNAL_REF_LENGTH)],
		due_at       = i64(seed >> 3),
		blocked_by   = pr.TaskID(seed + 2),
		completed_at = -i64(seed >> 4),
		completed_by = completed_by[:1 + int(seed % pr.MAX_USER_ID_LENGTH)],
		project      = project[:1 + int(seed % pr.MAX_PROJECT_LENGTH)],
		attachments  = attachments[:attachment_count],
	}
	if !task_persistence_lengths_supported(&task) do return hgl.interesting("generated task unsupported")
	encoded := make([]byte, calculate_task_fields_size(task))
	defer delete(encoded)
	written := serialize_task_fields(task, encoded)
	if written != len(encoded) do return hgl.interesting("complete task encoded size")
	parsed, ok := parse_task_fields(encoded, TASK_LOG_VERSION)
	if !ok || !task_codec_equal_parsed(&task, &parsed) do return hgl.interesting("complete task roundtrip")
	return hgl.valid()
}

task_codec_boundary_string_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	field_raw, field_err := hgl.draw_i64(tc, 0, 6)
	length_raw, length_err := hgl.draw_i64(tc, 0, 5)
	if field_err == .Stop_Test || length_err == .Stop_Test do return hgl.abort()
	if field_err != nil || length_err != nil do return hgl.interesting("draw boundary string")
	lengths := [6]int{0, 1, 255, 256, int(max(u16)) - 1, int(max(u16))}
	value := make([]byte, lengths[int(length_raw)])
	defer delete(value)
	task_codec_fill(value, u64(field_raw) + 41)
	task := pr.Task {
		id      = 1,
		conv_id = 2,
	}
	switch field_raw {
	case 0:
		task.title = value
	case 1:
		task.description = value
	case 2:
		task.assignee = value
	case 3:
		task.created_by = value
	case 4:
		task.external_ref = value
	case 5:
		task.completed_by = value
	case 6:
		task.project = value
	}
	if !task_persistence_lengths_supported(&task) do return hgl.interesting("supported boundary rejected")
	encoded := make([]byte, calculate_task_fields_size(task))
	defer delete(encoded)
	serialize_task_fields(task, encoded)
	parsed, ok := parse_task_fields(encoded, TASK_LOG_VERSION)
	if !ok || !task_codec_equal_parsed(&task, &parsed) do return hgl.interesting("boundary string roundtrip")
	return hgl.valid()
}

task_codec_unknown_field_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	unknown, draw_err := hgl.draw_bytes(tc, 0, 512)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw unknown field")
	defer delete(unknown)
	task := pr.Task {
		id      = 91,
		conv_id = 27,
		title   = transmute([]byte)string("known-title"),
		status  = .InProgress,
	}
	known_size := calculate_task_fields_size(task)
	encoded := make([]byte, known_size + 3 + len(unknown))
	defer delete(encoded)
	written := serialize_task_fields(task, encoded[:known_size])
	encoded[written] = 200
	endian.put_u16(encoded[written + 1:], .Big, u16(len(unknown)))
	copy(encoded[written + 3:], unknown)
	parsed, ok := parse_task_fields(encoded, TASK_LOG_VERSION)
	if !ok || !task_codec_equal_parsed(&task, &parsed) do return hgl.interesting("unknown field was not skipped")
	return hgl.valid()
}

task_codec_attachment_boundary_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	field_raw, field_err := hgl.draw_i64(tc, 0, 2)
	length_raw, length_err := hgl.draw_i64(tc, 0, 4)
	if field_err == .Stop_Test || length_err == .Stop_Test do return hgl.abort()
	if field_err != nil || length_err != nil do return hgl.interesting("draw attachment boundary")
	// A one-attachment payload has 24 bytes of count, length prefixes, and fixed fields.
	lengths := [5]int{0, 1, 255, 256, int(max(u16)) - 24}
	value := make([]byte, lengths[int(length_raw)])
	defer delete(value)
	task_codec_fill(value, u64(field_raw) + 71)
	attachment := pr.Attachment {
		size        = 0xffff_ffff_ffff_ffff,
		uploaded_at = min(i64),
	}
	switch field_raw {
	case 0:
		attachment.file_id = value
	case 1:
		attachment.filename = value
	case 2:
		attachment.mime_type = value
	}
	task := pr.Task {
		id          = 1,
		conv_id     = 2,
		attachments = []pr.Attachment{attachment},
	}
	if !task_persistence_lengths_supported(&task) do return hgl.interesting("supported attachment boundary rejected")
	encoded := make([]byte, calculate_task_fields_size(task))
	defer delete(encoded)
	serialize_task_fields(task, encoded)
	parsed, ok := parse_task_fields(encoded, TASK_LOG_VERSION)
	if !ok || !task_codec_equal_parsed(&task, &parsed) do return hgl.interesting("attachment boundary roundtrip")

	too_long := make([]byte, int(max(u16)) - 23)
	defer delete(too_long)
	attachment.file_id = too_long
	attachment.filename = nil
	attachment.mime_type = nil
	task.attachments = []pr.Attachment{attachment}
	if task_persistence_lengths_supported(&task) do return hgl.interesting("oversized attachment payload accepted")
	return hgl.valid()
}

task_codec_attachment_truncation_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	file_id, file_err := hgl.draw_bytes(tc, 0, pr.MAX_FILE_ID_LENGTH)
	if file_err == .Stop_Test do return hgl.abort()
	if file_err != nil do return hgl.interesting("draw truncated attachment file id")
	defer delete(file_id)
	filename, filename_err := hgl.draw_bytes(tc, 0, pr.MAX_FILENAME_LENGTH)
	if filename_err == .Stop_Test do return hgl.abort()
	if filename_err != nil do return hgl.interesting("draw truncated attachment filename")
	defer delete(filename)
	mime_type, mime_err := hgl.draw_bytes(tc, 0, pr.MAX_MIME_TYPE_LENGTH)
	if mime_err == .Stop_Test do return hgl.abort()
	if mime_err != nil do return hgl.interesting("draw truncated attachment MIME type")
	defer delete(mime_type)
	attachment := pr.Attachment {
		file_id     = file_id,
		filename    = filename,
		size        = 99,
		mime_type   = mime_type,
		uploaded_at = -77,
	}
	field_size := 3 + 2 + 2 + len(file_id) + 2 + len(filename) + 8 + 2 + len(mime_type) + 8
	field := make([]byte, field_size)
	defer delete(field)
	written := write_field_attachments(field, []pr.Attachment{attachment})
	if written != len(field) do return hgl.interesting("attachment truncation encoded size")
	truncate_raw, truncate_err := hgl.draw_i64(tc, 0, i64(len(field) - 4))
	if truncate_err == .Stop_Test do return hgl.abort()
	if truncate_err != nil do return hgl.interesting("draw attachment truncation")
	attachment_prefix_len := int(truncate_raw)
	_, _, attachment_ok := parse_attachments_field(field[3:3 + attachment_prefix_len])
	if attachment_ok do return hgl.interesting("attachment parser accepted truncation")
	endian.put_u16(field[1:], .Big, u16(attachment_prefix_len))
	_, fields_ok := parse_task_fields(field[:3 + attachment_prefix_len], TASK_LOG_VERSION)
	if fields_ok do return hgl.interesting("task parser accepted truncated attachment field")
	return hgl.valid()
}

task_codec_wrong_fixed_width_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	selector, selector_err := hgl.draw_i64(tc, 0, 10)
	length_raw, length_err := hgl.draw_i64(tc, 0, 9)
	if selector_err == .Stop_Test || length_err == .Stop_Test do return hgl.abort()
	if selector_err != nil || length_err != nil do return hgl.interesting("draw wrong fixed width")
	tags := [11]Task_Field_Tag{.TaskID, .ConvID, .CreatedAt, .UpdatedAt, .DueAt, .BlockedBy, .CompletedAt, .OrderIndex, .Status, .Priority, .Color}
	tag := tags[int(selector)]
	expected_length := 8
	if tag == .OrderIndex {
		expected_length = 2
	} else if tag == .Status || tag == .Priority || tag == .Color {
		expected_length = 1
	}
	wrong_length := int(length_raw)
	if wrong_length == expected_length do wrong_length = (wrong_length + 1) % 10
	field: [12]byte
	field[0] = u8(tag)
	endian.put_u16(field[1:], .Big, u16(wrong_length))
	_, ok := parse_task_fields(field[:3 + wrong_length], TASK_LOG_VERSION)
	if ok do return hgl.interesting("known fixed-width field accepted wrong length")
	return hgl.valid()
}

task_codec_attachment_shape_valid :: proc(data: []byte) -> bool {
	if len(data) < 2 do return false
	count, _ := endian.get_u16(data, .Big)
	if int(count) > pr.MAX_ATTACHMENTS_PER_TASK do return false
	offset := 2
	for _ in 0 ..< int(count) {
		if len(data) - offset < 2 do return false
		length, _ := endian.get_u16(data[offset:], .Big); offset += 2
		if int(length) > len(data) - offset do return false
		offset += int(length)
		if len(data) - offset < 2 do return false
		length, _ = endian.get_u16(data[offset:], .Big); offset += 2
		if int(length) > len(data) - offset do return false
		offset += int(length)
		if len(data) - offset < 8 do return false
		offset += 8
		if len(data) - offset < 2 do return false
		length, _ = endian.get_u16(data[offset:], .Big); offset += 2
		if int(length) > len(data) - offset do return false
		offset += int(length)
		if len(data) - offset < 8 do return false
		offset += 8
	}
	return offset == len(data)
}

task_codec_fields_shape_valid :: proc(data: []byte) -> bool {
	offset := 0
	for offset < len(data) {
		if len(data) - offset < 3 do return false
		tag := Task_Field_Tag(data[offset])
		length, _ := endian.get_u16(data[offset + 1:], .Big)
		offset += 3
		if int(length) > len(data) - offset do return false
		#partial switch tag {
		case .TaskID, .ConvID, .CreatedAt, .UpdatedAt, .DueAt, .BlockedBy, .CompletedAt:
			if length != 8 do return false
		case .OrderIndex:
			if length != 2 do return false
		case .Status, .Priority, .Color:
			if length != 1 do return false
		case:
		}
		if tag == .Attachments && !task_codec_attachment_shape_valid(data[offset:offset + int(length)]) do return false
		offset += int(length)
	}
	return true
}

task_codec_malformed_property :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	data, draw_err := hgl.draw_bytes(tc, 0, 2048)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw malformed data")
	defer delete(data)
	_, fields_ok := parse_task_fields(data, TASK_LOG_VERSION)
	if fields_ok != task_codec_fields_shape_valid(data) do return hgl.interesting("task parser bounded-consumption mismatch")
	attachments, count, attachments_ok := parse_attachments_field(data)
	if attachments_ok != task_codec_attachment_shape_valid(data) do return hgl.interesting("attachment parser bounded-consumption mismatch")
	if count < 0 || count > len(attachments) do return hgl.interesting("attachment parser count out of bounds")
	return hgl.valid()
}

@(test)
test_hegel_task_persistence_codec_properties :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	complete, complete_err := hgl.run(task_codec_complete_roundtrip_property, nil, {test_cases = 300, database_key = "task-codec-complete-roundtrip"})
	testing.expectf(t, complete_err == nil, "task codec complete roundtrip failed: err=%v interesting=%v", complete_err, complete.interesting_test_cases)
	boundary, boundary_err := hgl.run(task_codec_boundary_string_property, nil, {test_cases = 100, database_key = "task-codec-boundary-string"})
	testing.expectf(
		t,
		boundary_err == nil,
		"task codec boundary string roundtrip failed: err=%v interesting=%v",
		boundary_err,
		boundary.interesting_test_cases,
	)
	unknown, unknown_err := hgl.run(task_codec_unknown_field_property, nil, {test_cases = 200, database_key = "task-codec-unknown-field"})
	testing.expectf(t, unknown_err == nil, "task codec unknown field property failed: err=%v interesting=%v", unknown_err, unknown.interesting_test_cases)
	attachment_boundary, attachment_boundary_err := hgl.run(
		task_codec_attachment_boundary_property,
		nil,
		{test_cases = 100, database_key = "task-codec-attachment-boundary"},
	)
	testing.expectf(
		t,
		attachment_boundary_err == nil,
		"task codec attachment boundary property failed: err=%v interesting=%v",
		attachment_boundary_err,
		attachment_boundary.interesting_test_cases,
	)
	truncation, truncation_err := hgl.run(
		task_codec_attachment_truncation_property,
		nil,
		{test_cases = 300, database_key = "task-codec-attachment-truncation"},
	)
	testing.expectf(
		t,
		truncation_err == nil,
		"task codec attachment truncation property failed: err=%v interesting=%v",
		truncation_err,
		truncation.interesting_test_cases,
	)
	wrong_width, wrong_width_err := hgl.run(task_codec_wrong_fixed_width_property, nil, {test_cases = 200, database_key = "task-codec-wrong-fixed-width"})
	testing.expectf(
		t,
		wrong_width_err == nil,
		"task codec wrong fixed-width property failed: err=%v interesting=%v",
		wrong_width_err,
		wrong_width.interesting_test_cases,
	)
	malformed, malformed_err := hgl.run(task_codec_malformed_property, nil, {test_cases = 1000, database_key = "task-codec-malformed"})
	testing.expectf(t, malformed_err == nil, "task codec malformed property failed: err=%v interesting=%v", malformed_err, malformed.interesting_test_cases)
}
