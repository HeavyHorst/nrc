package main

import pr "protocol"
import wo "work_order"

// Unlike scalar indexes, this order depends on other tasks. Build it for the
// requested scope before paging; never initialize a scalar B-tree for WorkOrder.
collect_task_work_order_page :: proc(conv: ^Conversation_State, req: pr.TaskQueryRequest, tasks: ^[dynamic]pr.Task) -> Task_Query_Collection {
	result: Task_Query_Collection
	nodes := make([dynamic]wo.Node)
	done := make([dynamic]wo.Node)
	defer delete(nodes)
	defer delete(done)
	members := make(map[pr.TaskID]bool)
	defer delete(members)
	if req.slice_id != 0 {
		asset := conv.assets[req.slice_id]
		if asset == nil || asset.asset_type != .Slice do return result
		if ids, ok := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = u64(req.slice_id)}]; ok {
			for id in ids {
				edge := conv.edges[id]
				if edge == nil || edge.relation != .MemberOf do continue
				kind, member, found := slice_member_endpoint(edge, req.slice_id)
				if found && kind == .Task do members[pr.TaskID(member)] = true
			}
		}
	}
	// Slice queries visit only their membership, not every workspace task.
	if req.slice_id != 0 {
		for id in members {append_task_work_node(conv, conv.tasks[id], req, &nodes, &done)}
	} else {
		for _, task in conv.tasks {append_task_work_node(conv, task, req, &nodes, &done)}
	}
	ordered, unresolved := wo.order(nodes[:])
	defer delete(ordered)
	defer delete(unresolved)
	completed, unused := wo.order(done[:])
	defer delete(completed)
	defer delete(unused)
	append(&ordered, ..unresolved[:])
	append(&ordered, ..completed[:])
	result.total_count = u32(len(ordered))
	start := 0
	if req.has_cursor {
		// Re-anchor on the last row if priorities changed. If it disappeared,
		// resume at its old position. Like other queries this is a live view,
		// not a snapshot; clients refresh their pages on task/edge mutations.
		start = int(clamp(req.cursor_number, 0, i64(len(ordered))))
		for id, i in ordered {if id == u64(req.cursor_task_id) {start = i + 1; break}}
	}
	size := pr.getSizeTaskQueryPage(pr.TaskQueryPage{})
	for i in start ..< len(ordered) {
		task := conv.tasks[pr.TaskID(ordered[i])]
		item_size := pr.getSizeTask(task^)
		if len(tasks) >= int(req.limit) || (len(tasks) > 0 && size + item_size > MAX_PROTOCOL_PAYLOAD_SIZE) {
			result.has_more = true
			break
		}
		append(tasks, task^)
		size += item_size
		result.next_cursor_number = i64(i + 1)
		result.next_cursor_task_id = task.id
	}
	return result
}

append_task_work_node :: proc(conv: ^Conversation_State, task: ^pr.Task, req: pr.TaskQueryRequest, nodes, done: ^[dynamic]wo.Node) {
	if !task_matches_query(task, req) do return
	node := wo.Node {
		id         = u64(task.id),
		dependency = u64(task.blocked_by),
		priority   = i64(task.priority),
		due_at     = task.due_at,
	}
	if task.status == .Done {
		node.dependency = 0
		append(done, node)
		return
	}
	// Completed prerequisites are satisfied even when excluded by the filter.
	// Missing, retired or out-of-scope unfinished prerequisites stay unresolved.
	if parent := conv.tasks[task.blocked_by]; parent != nil && parent.status == .Done {node.dependency = 0}
	append(nodes, node)
}
