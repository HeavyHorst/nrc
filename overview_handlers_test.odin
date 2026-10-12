package main

import "core:encoding/endian"
import "core:fmt"
import "core:testing"
import pr "protocol"

@(test)
test_workspace_overview_membership_and_bucket_boundaries :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)
	day :: i64(24 * 60 * 60 * 1_000_000_000)
	now :: 200 * day
	previews := [10]string {
		`{"version":1,"name":"Empty"}`,
		`{"version":1,"name":"One"}`,
		`{"version":1,"name":"Five"}`,
		`{"version":1,"name":"Six"}`,
		`{"version":1,"name":"Fifteen"}`,
		`{"version":1,"name":"Sixteen"}`,
		`{"version":1,"name":"Thirty"}`,
		`{"version":1,"name":"Thirty-one"}`,
		`{"version":1,"name":"Done only"}`,
		`{"version":1,"name":"Closed","closed":true}`,
	}
	sizes := [10]int{0, 1, 5, 6, 15, 16, 30, 31, 4, 1}
	blocked := [10]int{0, 1, 2, 3, 0, 2, 3, 0, 0, 1}
	ages := [10]i64{0, 7, 8, 30, 31, 90, 91, -1, 0, 180}
	assets: [12]pr.Asset
	tasks: [111]pr.Task
	next := 0
	for size, i in sizes {
		assets[i] = slice_test_slice_asset(pr.AssetID(i + 1), previews[i])
		slice_test_add_asset(&conv, &assets[i])
		for member in 0 ..< size {
			task := &tasks[next]
			task^ = pr.Task {
				id         = pr.TaskID(next + 1),
				status     = .Done,
				created_at = now - 199 * day,
			}
			if member == 0 && i != 8 {
				task.status = i == 9 ? .Todo : .Backlog
				task.created_at = now - ages[i] * day
				if i == 1 do task.created_at -= day / 2 // 7.5 completed days still belongs to ≤7.
			}
			if member < blocked[i] do task.blocked_by = 999
			slice_test_add_task(&conv, task)
			slice_test_member_of(&conv, .Task, u64(task.id), assets[i].asset_id)
			next += 1
		}
	}
	// Shared work and reversed edges must not change unique workspace totals.
	slice_test_member_of(&conv, .Task, 1, assets[9].asset_id)
	edge := conv.edges[pr.EdgeID(len(conv.edges))]
	edge.source_type, edge.target_type = edge.target_type, edge.source_type
	edge.source_id, edge.target_id = edge.target_id, edge.source_id
	tasks[109] = pr.Task {
		id     = 110,
		status = .InProgress,
	}
	tasks[110] = pr.Task {
		id     = 111,
		status = .Note,
	}
	slice_test_add_task(&conv, &tasks[109]); slice_test_add_task(&conv, &tasks[110])
	slice_test_member_of(&conv, .Task, 111, assets[0].asset_id)
	assets[10] = pr.Asset {
		asset_id   = 11,
		asset_type = .CustomerCompany,
	}
	assets[11] = slice_test_slice_asset(12, `{"version":1,"name":""}`)
	for i in 10 ..< 12 {
		slice_test_add_asset(&conv, &assets[i])
		slice_test_member_of(&conv, .Task, 110, assets[i].asset_id)
	}
	slice_test_member_of(&conv, .Task, 110, assets[0].asset_id, .RelatedTo)
	slice_test_member_of(&conv, .Task, 9999, assets[0].asset_id) // Dangling task.

	result := collect_workspace_overview(&conv, now)
	testing.expect(t, result.success)
	testing.expect_value(t, result.status_counts, [4]u32{7, 1, 1, 101})
	testing.expect_value(t, result.assigned_tasks, u32(109))
	testing.expect_value(t, result.unassigned_tasks, u32(1))
	testing.expect_value(t, result.open_slices, u32(9))
	testing.expect_value(t, result.size_buckets, [5]u32{1, 3, 2, 2, 1})
	testing.expect_value(t, result.blocked_buckets, [3]u32{4, 3, 2})
	testing.expect_value(t, result.age_buckets, [5]u32{2, 2, 2, 1, 2})
	testing.expect_value(t, result.sampled_at, now)
	// Empty/uncreated workspaces are successful zero snapshots, not read errors.
	empty := collect_workspace_overview(nil, now)
	testing.expect(t, empty.success)
	testing.expect_value(t, empty.status_counts, [4]u32{})
	testing.expect_value(t, empty.size_buckets, [5]u32{})
}

@(test)
test_workspace_overview_exceeds_listing_limits :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)
	// Beyond 50 maximum-size listing pages and beyond one u16 member category.
	assets := make([]pr.Asset, 50 * pr.MAX_TASK_SLICE_COUNT + 1)
	defer delete(assets)
	for &asset, i in assets {
		preview := fmt.aprintf("%s%d%s", `{"version":1,"name":"Scale `, i, `"}`)
		asset = slice_test_slice_asset(pr.AssetID(i + 1), preview)
		slice_test_add_asset(&conv, &asset)
	}
	defer for asset in assets do delete(string(asset.preview))
	tasks := make([]pr.Task, 65536)
	defer delete(tasks)
	for &task, i in tasks {
		task = pr.Task {
			id         = pr.TaskID(i + 1),
			status     = .Backlog,
			created_at = 1,
			blocked_by = 99999,
		}
		slice_test_add_task(&conv, &task)
		slice_test_member_of(&conv, .Task, u64(task.id), 1)
	}
	result := collect_workspace_overview(&conv, 100 * 24 * 60 * 60 * 1_000_000_000)
	testing.expect(t, result.success)
	testing.expect_value(t, result.open_slices, u32(25601))
	testing.expect_value(t, result.status_counts, [4]u32{65536, 0, 0, 0})
	testing.expect_value(t, result.assigned_tasks, u32(65536))
	testing.expect_value(t, result.unassigned_tasks, u32(0))
	testing.expect_value(t, result.size_buckets, [5]u32{25600, 0, 0, 0, 1})
	testing.expect_value(t, result.blocked_buckets, [3]u32{25600, 0, 1})
	testing.expect_value(t, result.age_buckets, [5]u32{0, 0, 0, 1, 25600})
	buf: [105]byte
	testing.expect_value(t, pr.serializeWorkspaceOverview(result, buf[:]), 105)
	status, _ := endian.get_u32(buf[19:], .Big)
	testing.expect_value(t, status, u32(65536))
}
