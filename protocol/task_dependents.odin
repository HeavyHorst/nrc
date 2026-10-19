package protocol

import "core:encoding/endian"

ListTaskDependentsRequest :: struct {
	conv_id:        ConversationID,
	task_id:        TaskID,
	limit:          u16,
	after_task_id:  TaskID,
	correlation_id: u32,
}

parseListTaskDependentsRequest :: proc(data: []byte) -> (result: ListTaskDependentsRequest, err: ProtocolParseError) {
	if len(data) < 30 do return result, .TooShort
	if len(data) != 30 do return result, .ContentLengthMismatch
	conv, _ := endian.get_u64(data[0:], .Big)
	task, _ := endian.get_u64(data[8:], .Big)
	limit, _ := endian.get_u16(data[16:], .Big)
	after, _ := endian.get_u64(data[18:], .Big)
	correlation, _ := endian.get_u32(data[26:], .Big)
	if limit == 0 || limit > MAX_TASK_PAGE_SIZE do return result, .InvalidValue
	return ListTaskDependentsRequest{ConversationID(conv), TaskID(task), limit, TaskID(after), correlation}, nil
}

TaskDependentsPage :: struct {
	conv_id:        ConversationID,
	task_id:        TaskID,
	success:        bool,
	tasks:          []Task,
	has_more:       bool,
	next_task_id:   TaskID,
	error:          []byte,
	correlation_id: u32,
}

getSizeTaskDependentsPage :: proc(msg: TaskDependentsPage) -> int {
	size := 36 + len(msg.error)
	for task in msg.tasks do size += getSizeTask(task)
	return size
}

serializeTaskDependentsPage :: proc(msg: TaskDependentsPage, buf: []byte) -> int {
	if len(msg.tasks) > MAX_TASK_PAGE_SIZE || len(msg.error) > 65535 do return -1
	size := getSizeTaskDependentsPage(msg)
	if len(buf) < size do return -1
	endian.put_u16(buf[0:], .Big, u16(Opcode.S_TaskDependentsPage))
	endian.put_u64(buf[2:], .Big, u64(msg.conv_id))
	endian.put_u64(buf[10:], .Big, u64(msg.task_id))
	buf[18] = msg.success ? 1 : 0
	endian.put_u16(buf[19:], .Big, u16(len(msg.tasks)))
	offset := 21
	for task in msg.tasks {
		written := serializeTask(task, buf[offset:])
		if written < 0 do return -1
		offset += written
	}
	buf[offset] = msg.has_more ? 1 : 0
	offset += 1
	endian.put_u64(buf[offset:], .Big, u64(msg.next_task_id))
	offset += 8
	endian.put_u16(buf[offset:], .Big, u16(len(msg.error)))
	offset += 2
	copy(buf[offset:], msg.error)
	offset += len(msg.error)
	endian.put_u32(buf[offset:], .Big, msg.correlation_id)
	return size
}
