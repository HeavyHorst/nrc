package main

import "byte_pool"
import "clock"
import "core:mem/virtual"
import "core:time"
import pr "protocol"

// Scan each task and each slice membership once, without sorting or producing
// register rows. Counters are u32, not the listing's per-category u16 counters.
// Scratch preview memory is reset per slice; only unique task IDs are retained.
collect_workspace_overview :: proc(conv: ^Conversation_State, now: i64) -> (result: pr.WorkspaceOverview) {
	result.sampled_at = now
	if conv == nil {result.success = true; return}
	if u64(len(conv.tasks)) > u64(max(u32)) || u64(len(conv.assets)) > u64(max(u32)) {
		result.error = transmute([]byte)string("Overview counter representation limit exceeded")
		return
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		result.error = transmute([]byte)string("Overview allocation failed")
		return
	}
	defer virtual.arena_destroy(&arena)
	assigned := make(map[pr.TaskID]struct{})
	defer delete(assigned)
	for _, task in conv.tasks {
		if task == nil || task.status == .Note do continue
		result.status_counts[int(task.status)] += 1
	}
	for _, asset in conv.assets {
		if asset == nil || asset.asset_type != .Slice do continue
		virtual.arena_free_all(&arena)
		preview, valid := slice_preview(asset, virtual.arena_allocator(&arena))
		if !valid do continue
		size, blocked: u32
		oldest: i64
		key := Edge_Entity_Key {
			target_type = .Asset,
			target_id   = u64(asset.asset_id),
		}
		if edge_ids, found := conv.edges_by_entity[key]; found {
			for edge_id in edge_ids {
				edge := conv.edges[edge_id]
				if edge == nil || edge.relation != .MemberOf do continue
				kind, id, member := slice_member_endpoint(edge, asset.asset_id)
				if !member || kind != .Task do continue
				task := conv.tasks[pr.TaskID(id)]
				if task == nil || task.status == .Note do continue
				assigned[task.id] = {}
				size += 1
				if task.blocked_by != 0 do blocked += 1
				if task.status != .Done && (oldest == 0 || task.created_at < oldest) do oldest = task.created_at
			}
		}
		if preview.closed do continue
		result.open_slices += 1
		size_bucket := size == 0 ? 0 : size <= 5 ? 1 : size <= 15 ? 2 : size <= 30 ? 3 : 4
		blocked_bucket := blocked == 0 ? 0 : blocked <= 2 ? 1 : 2
		result.size_buckets[size_bucket] += 1
		result.blocked_buckets[blocked_bucket] += 1
		age_bucket := 4
		if oldest > 0 {
			age := max(i64(0), (now - oldest) / (24 * 60 * 60 * 1_000_000_000))
			age_bucket = age <= 7 ? 0 : age <= 30 ? 1 : age <= 90 ? 2 : 3
		}
		result.age_buckets[age_bucket] += 1
	}
	result.assigned_tasks = u32(len(assigned))
	result.unassigned_tasks = unassigned_task_count(conv, &assigned)
	result.success = true
	return
}

process_workspace_overview :: proc(c: ^NRC_Connection, req: pr.ListTaskProjectsRequest) {
	// The dispatcher enforces workspace scope 0. The owning worker cannot apply
	// a concurrent mutation while this snapshot is folded and serialized.
	conv := get_conversation(get_connection_workspace(c), req.conv_id)
	msg := collect_workspace_overview(conv, time.to_unix_nanoseconds(clock.now()))
	msg.conv_id = req.conv_id
	msg.correlation_id = req.correlation_id
	size := pr.getSizeWorkspaceOverview(msg)
	buf, header_len := allocate_websocket_frame_buffer(size, "workspace overview")
	if buf == nil do return
	written := pr.serializeWorkspaceOverview(msg, buf[header_len:])
	if written <= 0 {byte_pool.release(td.spool, buf); return}
	send_pooled_buffer(c, buf[:header_len + written])
}
