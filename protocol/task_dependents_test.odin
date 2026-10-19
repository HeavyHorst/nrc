package protocol

import "core:encoding/endian"
import "core:testing"

@(test)
test_task_dependents_wire :: proc(t: ^testing.T) {
	data: [31]byte
	wide :: u64(1) << 60 + 7
	endian.put_u64(data[0:], .Big, wide)
	endian.put_u64(data[8:], .Big, wide + 1)
	endian.put_u16(data[16:], .Big, 2)
	endian.put_u64(data[18:], .Big, wide + 2)
	endian.put_u32(data[26:], .Big, 123)
	req, err := parseListTaskDependentsRequest(data[:30])
	testing.expect(t, err == nil)
	testing.expect_value(t, u64(req.conv_id), wide)
	testing.expect_value(t, u64(req.task_id), wide + 1)
	testing.expect_value(t, u64(req.after_task_id), wide + 2)
	testing.expect_value(t, req.correlation_id, u32(123))
	for n in 0 ..< 30 {
		_, err = parseListTaskDependentsRequest(data[:n])
		testing.expect_value(t, err, ProtocolParseError.TooShort)
	}
	_, err = parseListTaskDependentsRequest(data[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
	limits := [2]u16{0, MAX_TASK_PAGE_SIZE + 1}
	for limit in limits {
		endian.put_u16(data[16:], .Big, limit)
		_, err = parseListTaskDependentsRequest(data[:30])
		testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	}
	buf: [1024]byte
	endian.put_u16(buf[:], .Big, 64)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_ListTaskDependents)
	tasks := [1]Task{{id = TaskID(wide + 3)}}
	msg := TaskDependentsPage {
		conv_id        = req.conv_id,
		task_id        = req.task_id,
		success        = true,
		tasks          = tasks[:],
		has_more       = true,
		next_task_id   = tasks[0].id,
		correlation_id = req.correlation_id,
	}
	written := serializeTaskDependentsPage(msg, buf[:])
	testing.expect_value(t, written, 36 + getSizeTask(tasks[0]))
	testing.expect_value(t, get_opcode(buf[:written]), Opcode.S_TaskDependentsPage)
	root, _ := endian.get_u64(buf[10:], .Big)
	testing.expect_value(t, root, wide + 1)
	testing.expect_value(t, buf[18], u8(1))
	count, _ := endian.get_u16(buf[19:], .Big)
	testing.expect_value(t, count, u16(1))
	parsed, offset, _, task_err := parse_task_from_payload(buf[:written], 21, nil)
	testing.expect(t, task_err == nil)
	testing.expect_value(t, parsed.id, tasks[0].id)
	testing.expect_value(t, buf[offset], u8(1))
	next, _ := endian.get_u64(buf[offset + 1:], .Big)
	testing.expect_value(t, next, u64(tasks[0].id))
	correlation, _ := endian.get_u32(buf[written - 4:], .Big)
	testing.expect_value(t, correlation, req.correlation_id)
	testing.expect_value(t, serializeTaskDependentsPage(msg, buf[:written - 1]), -1)
	msg.tasks = nil
	msg.success = false
	msg.has_more = false
	msg.next_task_id = 0
	msg.error = transmute([]byte)string("task_not_found")
	written = serializeTaskDependentsPage(msg, buf[:])
	testing.expect_value(t, written, 36 + len(msg.error))
	testing.expect_value(t, string(buf[32:written - 4]), "task_not_found")
}
