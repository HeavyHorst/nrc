package protocol

import "core:encoding/endian"

// One worker-owned snapshot, independent of register pagination. Every bucket
// counts open slices; coverage counts unique tasks in open OR closed slices.
// Request body is the existing scope:u64 + correlation:u32 metadata layout.
WorkspaceOverview :: struct {
	conv_id:          ConversationID,
	success:          bool,
	sampled_at:       i64, // Unix nanoseconds, also the age calculation boundary.
	status_counts:    [4]u32, // Backlog, Todo, InProgress, Done; excludes retired Notes.
	assigned_tasks:   u32,
	unassigned_tasks: u32,
	open_slices:      u32,
	size_buckets:     [5]u32, // 0, 1–5, 6–15, 16–30, 31+ tasks (includes Done).
	blocked_buckets:  [3]u32, // 0, 1–2, 3+ blocked task members.
	age_buckets:      [5]u32, // ≤7, 8–30, 31–90, 91+ completed days; no open tasks.
	error:            []byte,
	correlation_id:   u32,
}

getSizeWorkspaceOverview :: proc(msg: WorkspaceOverview) -> int {
	return 2 + 8 + 1 + 8 + 20 * 4 + 2 + len(msg.error) + 4
}

serializeWorkspaceOverview :: proc(msg: WorkspaceOverview, buf: []byte) -> int {
	if len(msg.error) > int(max(u16)) || len(buf) < getSizeWorkspaceOverview(msg) do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_WorkspaceOverview))
	endian.put_u64(buf[2:], .Big, u64(msg.conv_id))
	buf[10] = msg.success ? 1 : 0
	endian.put_u64(buf[11:], .Big, u64(msg.sampled_at))
	offset := 19
	for count in msg.status_counts {endian.put_u32(buf[offset:], .Big, count); offset += 4}
	coverage := [3]u32{msg.assigned_tasks, msg.unassigned_tasks, msg.open_slices}
	for count in coverage {endian.put_u32(buf[offset:], .Big, count); offset += 4}
	for count in msg.size_buckets {endian.put_u32(buf[offset:], .Big, count); offset += 4}
	for count in msg.blocked_buckets {endian.put_u32(buf[offset:], .Big, count); offset += 4}
	for count in msg.age_buckets {endian.put_u32(buf[offset:], .Big, count); offset += 4}
	endian.put_u16(buf[offset:], .Big, u16(len(msg.error))); offset += 2
	copy(buf[offset:], msg.error); offset += len(msg.error)
	endian.put_u32(buf[offset:], .Big, msg.correlation_id); offset += 4
	return offset
}
