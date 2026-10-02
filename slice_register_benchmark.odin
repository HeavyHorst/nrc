// What one slice listing costs the server, measured before anything is serialized.
//
// A listing folds every slice's member edges on every request and keeps no slice
// index on purpose: the adjacency index answers "what points at this slice" in one
// lookup, so the fold is O(assets + slices + member edges) and cannot drift from
// the edges it is derived from. This benchmark puts a number on that fold, so the
// question "does it need an index?" is answered with a measurement instead of a
// feeling.
//
// Run with:
//   BENCH_SLICE_REGISTER=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false \
//     -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_slice_register
//
// Tunables: BENCH_SLICE_REGISTER_SLICES, _MEMBERS (members per slice), _TASKS
// (non-member tasks), _ASSETS (non-slice assets), _ROUNDS.
package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "core:mem/virtual"

import pr "protocol"

@(test)
benchmark_slice_register :: proc(t: ^testing.T) {
	enabled, found := os.lookup_env_alloc("BENCH_SLICE_REGISTER", context.allocator)
	if found do delete(enabled)
	if !found || enabled == "0" do return

	slice_count := message_store_benchmark_env_int("BENCH_SLICE_REGISTER_SLICES", 200)
	members_per_slice := message_store_benchmark_env_int("BENCH_SLICE_REGISTER_MEMBERS", 20)
	task_count := message_store_benchmark_env_int("BENCH_SLICE_REGISTER_TASKS", 2000)
	asset_count := message_store_benchmark_env_int("BENCH_SLICE_REGISTER_ASSETS", 2000)
	rounds := message_store_benchmark_env_int("BENCH_SLICE_REGISTER_ROUNDS", 500)

	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)

	// The listing walks the asset map to find the slices, so a workspace that also
	// holds notes, files and reminders is part of the cost.
	others := make([]pr.Asset, asset_count)
	defer delete(others)
	for i in 0 ..< asset_count {
		others[i] = pr.Asset {
			asset_type = .Note,
			asset_id   = pr.AssetID(1_000_000 + i),
			updated_at = 1000,
		}
		slice_test_add_asset(&conv, &others[i])
	}

	tasks := make([]pr.Task, task_count)
	defer delete(tasks)
	for i in 0 ..< task_count {
		tasks[i] = pr.Task {
			id         = pr.TaskID(i + 1),
			status     = .Todo,
			created_at = i64(i),
			updated_at = i64(i),
		}
		slice_test_add_task(&conv, &tasks[i])
	}

	// Slices carry the preview production stores, so the fold decodes what it
	// decodes in a real workspace.
	previews := make([]string, slice_count)
	defer {
		for preview in previews do delete(preview)
		delete(previews)
	}
	slice_assets := make([]pr.Asset, slice_count)
	defer delete(slice_assets)
	member_edges := 0
	for i in 0 ..< slice_count {
		previews[i] = fmt.aprintf(`{{"version":1,"name":"Slice %d","owner":"rene","outcome":"","closed":false}}`, i, allocator = context.allocator)
		slice_assets[i] = pr.Asset {
			asset_type = .Slice,
			asset_id   = pr.AssetID(500_000 + i),
			created_at = i64(i),
			updated_at = i64(i),
			preview    = transmute([]byte)previews[i],
		}
		slice_test_add_asset(&conv, &slice_assets[i])
		for _ in 0 ..< members_per_slice {
			if member_edges >= task_count do break
			slice_test_member_of(&conv, .Task, u64(member_edges + 1), pr.AssetID(500_000 + i))
			member_edges += 1
		}
	}

	// One round is what process_list_task_slices does for the first page of an
	// unfiltered listing: a growing arena for the names and previews, the fold, and
	// the workspace counters, which that page is the one to fold.
	checksum := 0
	started := time.now()
	for _ in 0 ..< rounds {
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil do break
		allocator := virtual.arena_allocator(&arena)
		slices := make([dynamic]pr.TaskSlice, 0, 16, allocator)
		assigned := make(map[pr.TaskID]struct{}, 64, allocator)
		query := Slice_Query {
			limit              = pr.MAX_TASK_SLICE_COUNT,
			with_work_counters = true,
		}
		page := collect_task_slices(&conv, query, &slices, &assigned, allocator)
		checksum += int(page.total_count) + len(slices) + int(page.unassigned_tasks) + (page.has_more ? 1 : 0)
		virtual.arena_destroy(&arena)
	}
	elapsed := time.since(started)

	expected_slices := min(slice_count, pr.MAX_TASK_SLICE_COUNT)
	expected_unassigned := task_count - member_edges
	per_round := slice_count + expected_slices + expected_unassigned + (slice_count > pr.MAX_TASK_SLICE_COUNT ? 1 : 0)
	testing.expect_value(t, checksum, rounds * per_round)

	fmt.printf(
		"SLICE_REGISTER_BENCH_RESULT slices=%d members_per_slice=%d member_edges=%d tasks=%d other_assets=%d rounds=%d total_ns=%d per_listing_ns=%d\n",
		slice_count,
		members_per_slice,
		member_edges,
		task_count,
		asset_count,
		rounds,
		elapsed,
		elapsed / time.Duration(rounds),
	)
}
