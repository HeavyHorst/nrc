package main

import "btree"
import "core:testing"
import hgl "hegel"
import pr "protocol"

task_query_test_add :: proc(conv: ^Conversation_State, task: ^pr.Task) {
	state_map_set(&conv.tasks, task.id, task)
	index_task(conv, task)
}

task_query_test_bytes :: proc(value: string) -> []byte {return transmute([]byte)value}

// Independent full ordering, without the production comparator or adapter.
task_query_test_less :: proc(a, b: Task_Query_Key, descending: bool) -> bool {
	if a.due_missing != b.due_missing do return !a.due_missing
	if a.number != b.number do return descending ? a.number > b.number : a.number < b.number
	// Compare bytes independently, including nil and nonnil empty slices.
	for i in 0 ..< min(len(a.text), len(b.text)) {
		if a.text[i] != b.text[i] do return descending ? a.text[i] > b.text[i] : a.text[i] < b.text[i]
	}
	if len(a.text) != len(b.text) do return descending ? len(a.text) > len(b.text) : len(a.text) < len(b.text)
	return a.task_id < b.task_id
}

task_query_test_expect_key :: proc(t: ^testing.T, actual, expected: Task_Query_Key) {
	testing.expect_value(t, actual.number, expected.number)
	testing.expect_value(t, actual.due_missing, expected.due_missing)
	testing.expect_value(t, string(actual.text), string(expected.text))
	testing.expect_value(t, actual.task_id, expected.task_id)
}

task_numeric_model_equal :: proc(a, b: Task_Query_Key) -> bool {
	return a.number == b.number && a.due_missing == b.due_missing && string(a.text) == string(b.text) && a.task_id == b.task_id
}

task_numeric_model_lower :: proc(model: []Task_Query_Key, key: Task_Query_Key, descending: bool) -> int {
	i := 0
	for i < len(model) && task_query_test_less(model[i], key, descending) do i += 1
	return i
}

// Both implementations receive the same operation; only the independently
// ordered slice decides presence, prior values and the resulting state.
task_numeric_model_mutate :: proc(
	trees: []btree.BTreeG(Task_Query_Key, Task_Query_Order),
	hints: []btree.Path_Hint,
	model: ^[dynamic]Task_Query_Key,
	key: Task_Query_Key,
	descending, remove, hinted: bool,
) -> string {
	i := task_numeric_model_lower(model^[:], key, descending)
	present := i < len(model^) && task_numeric_model_equal(model^[i], key)
	for &tree, n in trees {
		prior: Task_Query_Key
		found: bool
		if remove {
			if hinted {
				prior, found = btree.remove_hint(&tree, key, &hints[n])
			} else {
				prior, found = btree.remove(&tree, key)
			}
		} else {
			if hinted {
				prior, found = btree.set_hint(&tree, key, &hints[n])
			} else {
				prior, found = btree.set(&tree, key)
			}
		}
		if found != present do return "mutation presence/prior flag"
		if found && !task_numeric_model_equal(prior, model^[i]) do return "mutation prior value"
	}
	if remove {
		if present {
			for j in i ..< len(model^) - 1 do model^[j] = model^[j + 1]
			resize(model, len(model^) - 1)
		}
	} else if present {
		model^[i] = key
	} else {
		append(model, key)
		for j := len(model^) - 1; j > i; j -= 1 do model^[j] = model^[j - 1]
		model^[i] = key
	}
	return ""
}

task_numeric_model_check :: proc(
	trees: []btree.BTreeG(Task_Query_Key, Task_Query_Order),
	model: []Task_Query_Key,
	probe: Task_Query_Key,
	descending: bool,
	page_size: int,
) -> string {
	lower := task_numeric_model_lower(model, probe, descending)
	present := lower < len(model) && task_numeric_model_equal(model[lower], probe)
	for &tree in trees {
		if btree.count(&tree) != len(model) do return "count"
		got, found := btree.get(&tree, probe)
		if found != present do return "get presence"
		if found && !task_numeric_model_equal(got, model[lower]) do return "get value"
		// Iteration alone need not build search caches: search every live key.
		for key in model {
			value, exists := btree.get(&tree, key)
			if !exists || !task_numeric_model_equal(value, key) do return "live get value"
		}
		it := btree.iter(&tree)
		defer btree.iter_destroy(&it)
		// Full walks independently check count/order in both directions.
		for reverse in ([?]bool{false, true}) {
			has := reverse ? btree.iter_last(&it) : btree.iter_first(&it)
			for j in 0 ..< len(model) {
				i := reverse ? len(model) - 1 - j : j
				if !has do return "short full walk"
				if !task_numeric_model_equal(btree.item(&it), model[i]) do return "full walk order"
				has = reverse ? btree.iter_prev(&it) : btree.iter_next(&it)
			}
			if has do return "long full walk"
		}
		// Pages start at lower_bound, including absent/gap/out-of-range probes.
		for reverse in ([?]bool{false, true}) {
			i := lower
			has := btree.iter_seek(&it, probe)
			if has != (lower < len(model)) do return "seek presence"
			if has && !task_numeric_model_equal(btree.item(&it), model[lower]) do return "seek value"
			if reverse {
				// Reverse page is strictly before the probe (exclusive cursor).
				i -= 1
				has = has ? btree.iter_prev(&it) : btree.iter_last(&it)
			}
			for j in 0 ..< page_size {
				if has != (i >= 0 && i < len(model)) do return "page presence"
				if !has do break
				if !task_numeric_model_equal(btree.item(&it), model[i]) do return "page value"
				i += reverse ? -1 : 1
				has = reverse ? btree.iter_prev(&it) : btree.iter_next(&it)
			}
		}
	}
	return ""
}

@(test)
test_hegel_task_query_numeric_model :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_task_query_numeric_model, nil, {test_cases = 144})
	testing.expectf(t, err == nil, "numeric task model: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_task_query_numeric_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	config, err := hgl.draw_i64(tc, 0, 11)
	if err == .Stop_Test do return hgl.abort()
	if err != nil do return hgl.interesting("draw numeric configuration")
	degrees := [?]int{2, 3, 32}
	descending := config % 2 != 0
	projection: Task_Numeric_Projection = config / 6 == 0 ? .Time : .Enum_Value
	trees := [2]btree.BTreeG(Task_Query_Key, Task_Query_Order) {
		btree.create_ordered(
			Task_Query_Key,
			Task_Query_Order,
			{degree = degrees[(config / 2) % 3]},
			cache = .Numeric,
			descending = descending,
			projection = projection,
		),
		btree.create_ordered(
			Task_Query_Key,
			Task_Query_Order,
			{degree = degrees[(config / 2) % 3]},
			cache = .None,
			descending = descending,
			projection = projection,
		),
	}
	defer for &tree in trees do btree.destroy(&tree)
	hints: [2]btree.Path_Hint
	model := make([dynamic]Task_Query_Key)
	defer delete(model)
	generated_text, text_err := hgl.draw_bytes(tc, 0, 24)
	if text_err == .Stop_Test do return hgl.abort()
	if text_err != nil do return hgl.interesting("draw numeric text")
	defer delete(generated_text)
	texts := [?]string{"", "a", "aa", "\x00", "\xff", string(generated_text)}
	numbers := [?]i64{min(i64), min(i64) + 1, -129, -128, -127, -1, 0, 1, 126, 127, 128, 129, max(i64) - 1, max(i64)}
	ids := [?]u64{0, (1 << 54) - 1, 1 << 54, (1 << 54) + 1, max(u64)}
	pool: [96]Task_Query_Key
	for &key, i in pool {
		number, e1 := hgl.draw_i64(tc, min(i64), max(i64))
		choice, e2 := hgl.draw_i64(tc, 0, 83)
		if e1 == .Stop_Test || e2 == .Stop_Test do return hgl.abort()
		if e1 != nil || e2 != nil do return hgl.interesting("draw numeric pool")
		key = {
			number      = i < 28 ? numbers[i % len(numbers)] : number,
			text        = task_query_test_bytes(texts[i < 28 ? i % len(texts) : int(choice) % len(texts)]),
			due_missing = i < 28 ? i >= 14 : choice % 2 != 0,
			task_id     = u64(i),
		}
		if i < len(ids) {
			key.task_id = ids[i]
		} else if choice % 3 == 1 {
			key.task_id += 1 << 54
		} else if choice % 3 == 2 {
			key.task_id = max(u64) - u64(i)
		}
		// Further pool keys deliberately collide in the saturated projections.
		if i >= 28 && choice % 2 == 0 do key.number = numbers[choice % len(numbers)]
	}
	// Unique IDs guarantee 96 records: enough to split even degree 32.
	for j in 0 ..< len(pool) {
		key := pool[(j * 37) % len(pool)]
		failure := task_numeric_model_mutate(trees[:], hints[:], &model, key, descending, false, j % 2 == 0)
		if failure != "" do return hgl.interesting(failure)
	}
	for round in 0 ..< 16 {
		choice, e1 := hgl.draw_i64(tc, 0, 95)
		burst, e2 := hgl.draw_i64(tc, 1, 8)
		if e1 == .Stop_Test || e2 == .Stop_Test do return hgl.abort()
		if e1 != nil || e2 != nil do return hgl.interesting("draw numeric burst")
		key := pool[choice]
		failure := task_numeric_model_check(trees[:], model[:], key, descending, int(burst))
		if failure != "" do return hgl.interesting(failure)
		for step in 0 ..< int(burst) {
			index, e3 := hgl.draw_i64(tc, 0, 95)
			op, e4 := hgl.draw_i64(tc, 0, 3)
			if e3 == .Stop_Test || e4 == .Stop_Test do return hgl.abort()
			if e3 != nil || e4 != nil do return hgl.interesting("draw numeric operation")
			failure = task_numeric_model_mutate(trees[:], hints[:], &model, pool[index], descending, op >= 2, op % 2 == 0)
			if failure != "" do return hgl.interesting(failure)
		}
		// Guaranteed replacement, successful removal, absent removal and restore,
		// with reads warming the cache between every operation and both hint modes.
		for step in 0 ..< 5 {
			failure = task_numeric_model_check(trees[:], model[:], key, descending, int(burst))
			if failure != "" do return hgl.interesting(failure)
			failure = task_numeric_model_mutate(trees[:], hints[:], &model, key, descending, step == 2 || step == 3, (round + step) % 2 == 0)
			if failure != "" do return hgl.interesting(failure)
		}
		// A guaranteed absent ID also supplies a noncanonical seek cursor.
		key.task_id = 1 << 53
		failure = task_numeric_model_check(trees[:], model[:], key, descending, int(burst))
		if failure != "" do return hgl.interesting(failure)
	}
	for len(model) > 0 {
		key := model[len(model) / 2]
		failure := task_numeric_model_check(trees[:], model[:], key, descending, 7)
		if failure != "" do return hgl.interesting(failure)
		failure = task_numeric_model_mutate(trees[:], hints[:], &model, key, descending, true, len(model) % 2 == 0)
		if failure != "" do return hgl.interesting(failure)
	}
	failure := task_numeric_model_check(trees[:], model[:], pool[0], descending, 7)
	if failure != "" do return hgl.interesting(failure)
	return hgl.valid()
}

@(test)
test_task_query_numeric_cache_full_order_boundaries :: proc(t: ^testing.T) {
	numbers := [?]i64{min(i64), min(i64) + 1, -129, -128, -127, -1, 0, 1, 126, 127, 128, max(i64) - 1, max(i64)}
	ids := [?]pr.TaskID{1, (1 << 54) - 1, 1 << 54, (1 << 54) + 1, max(u64)}
	texts := [?]string{"", "a", "aa", "b"}
	for projection in ([?]Task_Numeric_Projection{.Time, .Enum_Value}) {
		for descending in ([?]bool{false, true}) {
			tree := btree.create_ordered(
				Task_Query_Key,
				Task_Query_Order,
				btree.Options{degree = 4},
				cache = .Numeric,
				descending = descending,
				projection = projection,
			)
			defer btree.destroy(&tree)
			testing.expect_value(t, tree.cache, btree.Cache_Mode.Numeric)
			testing.expect_value(t, tree.projection, projection)
			testing.expect_value(t, tree.descending, descending)
			expected := make([dynamic]Task_Query_Key)
			defer delete(expected)
			for missing in ([?]bool{false, true}) {
				for number in numbers {
					for text in texts {
						for id in ids {
							key := Task_Query_Key {
								number      = number,
								text        = task_query_test_bytes(text),
								task_id     = id,
								due_missing = missing,
							}
							append(&expected, key)
							// Insertion-sort the independent model.
							j := len(expected) - 1
							for j > 0 && task_query_test_less(key, expected[j - 1], descending) {
								expected[j] = expected[j - 1]
								j -= 1
							}
							expected[j] = key
						}
					}
				}
			}
			for i := len(expected) - 1; i >= 0; i -= 1 {_, _ = btree.set(&tree, expected[i])}
			for pass in 0 ..< 2 {
				it := btree.iter(&tree)
				has := btree.iter_first(&it)
				for key in expected {
					testing.expect(t, has)
					if has do task_query_test_expect_key(t, btree.item(&it), key)
					has = btree.iter_next(&it)
					got, found := btree.get(&tree, key)
					testing.expect(t, found)
					if found do task_query_test_expect_key(t, got, key)
				}
				testing.expect(t, !has)
				for key in expected {
					for gap in ([?]bool{false, true}) {
						probe := key
						if gap do probe.task_id -= 1
						lower := 0
						for lower < len(expected) && task_query_test_less(expected[lower], probe, descending) do lower += 1
						found := btree.iter_seek(&it, probe)
						testing.expect_value(t, found, lower < len(expected))
						if found && lower < len(expected) do task_query_test_expect_key(t, btree.item(&it), expected[lower])
					}
				}
				btree.iter_destroy(&it)
				if pass == 0 {
					for key, i in expected {
						if i % 2 != 0 do continue
						removed, ok := btree.remove(&tree, key)
						testing.expect(t, ok)
						if ok do task_query_test_expect_key(t, removed, key)
						_, present := btree.get(&tree, key)
						testing.expect(t, !present)
					}
					for key, i in expected {if i % 2 == 0 {_, _ = btree.set(&tree, key)}}
				}
			}
		}
	}
}

@(test)
test_task_query_numeric_public_cursors :: proc(t: ^testing.T) {
	conv: Conversation_State
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)
	tasks := [?]pr.Task {
		{id = 1, status = .Todo, priority = 126, created_at = min(i64), updated_at = min(i64)},
		{id = (1 << 54) - 1, status = .Todo, priority = 127, created_at = -1, updated_at = -1},
		{id = 1 << 54, status = .Todo, priority = 128, created_at = 0, updated_at = 0},
		{id = (1 << 54) + 1, status = .Todo, priority = 255, created_at = max(i64), updated_at = max(i64)},
		{id = max(u64), status = .Todo, priority = 255, created_at = max(i64), updated_at = max(i64)},
	}
	for &task in tasks do task_query_test_add(&conv, &task)
	testing.expect_value(t, conv.task_index.cache, btree.Cache_Mode.Numeric)
	testing.expect_value(t, conv.task_index.projection, btree.No_Projection.None)
	rows := make([dynamic]pr.Task)
	defer delete(rows)
	legacy := pr.ListTasksPagedRequest {
		status_mask = 15,
		limit       = 1,
	}
	for i := len(tasks) - 1; i >= 0; i -= 1 {
		clear(&rows)
		page := collect_task_page(&conv, legacy, &rows)
		testing.expect_value(t, len(rows), 1)
		if len(rows) == 1 do testing.expect_value(t, rows[0].id, tasks[i].id)
		testing.expect_value(t, page.has_more, i != 0)
		legacy.has_cursor = true
		legacy.cursor_sort_at = page.next_cursor_sort_at
		legacy.cursor_task_id = page.next_cursor_task_id
	}
	for sort_kind in ([?]pr.TaskQuerySort{.Priority, .CreatedAt}) {
		for descending in ([?]bool{false, true}) {
			for number in ([?]i64{min(i64), -129, -128, -127, -1, 0, 126, 127, 128, 255, max(i64)}) {
				for text in ([?]string{"", "noncanonical"}) {
					clear(&rows)
					req := pr.TaskQueryRequest {
						status_mask    = 15,
						limit          = 10,
						color          = 255,
						sort           = sort_kind,
						descending     = descending,
						has_cursor     = true,
						cursor_number  = number,
						cursor_text    = task_query_test_bytes(text),
						cursor_task_id = 1 << 54,
					}
					page := collect_task_query_page(&conv, req, &rows)
					testing.expect_value(t, page.total_count, u32(len(tasks)))
					cursor := Task_Query_Key {
						number  = number,
						text    = req.cursor_text,
						task_id = req.cursor_task_id,
					}
					count := 0
					for task in tasks {
						key := Task_Query_Key {
							number  = sort_kind == .Priority ? i64(task.priority) : task.created_at,
							task_id = task.id,
						}
						if task_query_test_less(cursor, key, descending) do count += 1
					}
					testing.expect_value(t, len(rows), count)
					previous := cursor
					for row in rows {
						key := Task_Query_Key {
							number  = sort_kind == .Priority ? i64(row.priority) : row.created_at,
							task_id = row.id,
						}
						testing.expect(t, task_query_test_less(previous, key, descending))
						previous = key
					}
				}
			}
		}
	}
}

@(test)
test_task_query_text_order_and_empty_filters :: proc(t: ^testing.T) {
	conv: Conversation_State
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)

	// Explicit byte order, including embedded NUL, non-ASCII bytes, prefixes,
	// and differences on either side of the runtime's 32-byte SIMD boundary.
	titles := [?]string {
		"",
		"",
		"\x00",
		"\x00a",
		"a",
		"aa",
		"a\x7f",
		"a\x80",
		"a\xff",
		"012345678901234567890123456789012a",
		"012345678901234567890123456789012b",
		"012345678901234567890123456789012ba",
		"ä",
		"日本",
	}
	tasks: [len(titles)]pr.Task
	empty_backing := [1]byte{'x'}
	for title, i in titles {
		tasks[i] = pr.Task {
			id     = pr.TaskID(i + 1),
			status = .Todo,
			title  = task_query_test_bytes(title),
		}
		if i % 2 == 0 {
			tasks[i].project = empty_backing[:0]
			tasks[i].assignee = empty_backing[:0]
		}
	}
	tasks[0].title = nil
	tasks[1].title = empty_backing[:0]
	for i := len(tasks) - 1; i >= 0; i -= 1 {task_query_test_add(&conv, &tasks[i])}

	ascending := [?]pr.TaskID{1, 2, 3, 4, 10, 11, 12, 5, 6, 7, 8, 9, 13, 14}
	descending := [?]pr.TaskID{14, 13, 9, 8, 7, 6, 5, 12, 11, 10, 4, 3, 1, 2}
	rows := make([dynamic]pr.Task)
	defer delete(rows)
	for desc in ([?]bool{false, true}) {
		for empty in ([?][]byte{nil, empty_backing[:0]}) {
			req := pr.TaskQueryRequest {
				status_mask  = 0x0f,
				limit        = 3,
				sort         = .Title,
				descending   = desc,
				color        = 255,
				has_project  = true,
				project      = empty,
				has_assignee = true,
				assignee     = empty,
			}
			expected := desc ? descending[:] : ascending[:]
			seen := 0
			for _ in 0 ..< len(tasks) {
				clear(&rows)
				page := collect_task_query_page(&conv, req, &rows)
				testing.expect_value(t, page.total_count, u32(len(tasks)))
				for row in rows {
					if seen < len(expected) do testing.expect_value(t, row.id, expected[seen])
					seen += 1
				}
				if !page.has_more do break
				req.has_cursor = true
				req.cursor_text = page.next_cursor_text
				req.cursor_task_id = page.next_cursor_task_id
			}
			testing.expect_value(t, seen, len(expected))
			// Text cursors with a nonzero numeric field must retain the full
			// comparator's ordering, even when the text-search cache is warm.
			for number in ([?]i64{-1, 1}) {
				clear(&rows)
				req.has_cursor = true
				req.cursor_number = number
				_ = collect_task_query_page(&conv, req, &rows)
				before_all := desc ? number > 0 : number < 0
				testing.expect_value(t, len(rows), before_all ? 3 : 0)
				if before_all && len(rows) > 0 do testing.expect_value(t, rows[0].id, expected[0])
			}
		}
	}
}

@(test)
test_task_work_order_scope_and_pages :: proc(t: ^testing.T) {
	conv: Conversation_State
	slice_test_state(&conv)
	defer slice_test_destroy(&conv)
	tasks := [?]pr.Task {
		{id = 1, status = .Todo, priority = 10},
		{id = 2, status = .Todo, priority = 90, blocked_by = 1},
		{id = 3, status = .Todo, priority = 5},
		{id = 4, status = .Todo, priority = 100, blocked_by = 99},
		{id = 5, status = .Todo, priority = 80, blocked_by = 6},
		{id = 6, status = .Todo, priority = 70, blocked_by = 5},
		{id = 7, status = .Done, priority = 200},
		{id = 8, status = .Todo, priority = 20, blocked_by = 7},
		{id = 9, status = .Note, priority = 250},
		{id = 10, status = .Todo, priority = 95, blocked_by = 4},
	}
	for &task in tasks {state_map_set(&conv.tasks, task.id, &task)}
	rows := make([dynamic]pr.Task)
	defer delete(rows)
	req := pr.TaskQueryRequest {
		status_mask = 15,
		sort        = .WorkOrder,
		color       = 255,
		limit       = 2,
	}
	expected := [?]pr.TaskID{8, 1, 2, 3, 4, 10, 5, 6, 7}
	i := 0
	for {
		clear(&rows)
		page := collect_task_query_page(&conv, req, &rows)
		testing.expect_value(t, page.total_count, u32(len(expected)))
		for row in rows {testing.expect_value(t, row.id, expected[i]); i += 1}
		if !page.has_more do break
		req.has_cursor = true
		req.cursor_task_id = page.next_cursor_task_id
		req.cursor_number = page.next_cursor_number
	}
	testing.expect_value(t, i, len(expected))
	// Member 2 cannot be planned before its excluded prerequisite 1. Done
	// prerequisite 7, however, is satisfied even though it is not a member.
	asset := slice_test_slice_asset(77, `{"version":1,"name":"Work"}`)
	slice_test_add_asset(&conv, &asset)
	for id in ([?]u64{2, 3, 8}) {slice_test_member_of(&conv, .Task, id, 77)}
	slice_test_member_of(&conv, .Task, 1, 77, .RelatedTo)
	req = pr.TaskQueryRequest {
		status_mask = 7,
		sort        = .WorkOrder,
		color       = 255,
		limit       = 100,
		slice_id    = 77,
	}
	clear(&rows)
	page := collect_task_query_page(&conv, req, &rows)
	testing.expect_value(t, page.total_count, u32(3))
	slice_expected := [3]pr.TaskID{8, 3, 2}
	for row, j in rows {testing.expect_value(t, row.id, slice_expected[j])}
	// Filter membership is applied before dependency ordering, too.
	req.slice_id = 0
	req.blocked = 1
	clear(&rows)
	page = collect_task_query_page(&conv, req, &rows)
	testing.expect_value(t, page.total_count, u32(6))
	filtered_expected := [6]pr.TaskID{8, 4, 10, 2, 5, 6}
	for row, j in rows {testing.expect_value(t, row.id, filtered_expected[j])}
	// A slice with no adjacency entry and a nonexistent slice are empty.
	empty := slice_test_slice_asset(78, `{"version":1,"name":"Empty"}`)
	slice_test_add_asset(&conv, &empty)
	for id in ([?]pr.AssetID{78, 79}) {
		clear(&rows); req.slice_id = id
		page = collect_task_query_page(&conv, req, &rows)
		testing.expect_value(t, page.total_count, u32(0))
	}
}

@(test)
test_task_query_order_filters_cursor_and_indexes :: proc(t: ^testing.T) {
	conv: Conversation_State
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)
	tasks := [5]pr.Task {
		{
			id = 5,
			status = .Todo,
			priority = 2,
			due_at = 0,
			created_at = 50,
			title = task_query_test_bytes("z"),
			assignee = task_query_test_bytes("ann"),
			project = task_query_test_bytes("Beta"),
			color = .Red,
		},
		{
			id = 2,
			status = .Todo,
			priority = 2,
			due_at = 20,
			created_at = 40,
			title = task_query_test_bytes("a"),
			assignee = task_query_test_bytes("ann"),
			project = task_query_test_bytes("Alpha"),
			color = .Red,
			blocked_by = 9,
		},
		{
			id = 8,
			status = .Backlog,
			priority = 1,
			due_at = 10,
			created_at = 30,
			title = task_query_test_bytes("a"),
			assignee = task_query_test_bytes("bob"),
			project = task_query_test_bytes("Alpha"),
			color = .Gold,
		},
		{id = 1, status = .Done, priority = 3, due_at = 5, created_at = 20, title = task_query_test_bytes("m")},
		{
			id = 9,
			status = .Todo,
			priority = 2,
			due_at = 20,
			created_at = 10,
			title = task_query_test_bytes("x"),
			assignee = task_query_test_bytes("ann"),
			project = task_query_test_bytes("Alpha"),
			color = .Red,
			blocked_by = 2,
		},
	}
	for &task in tasks do task_query_test_add(&conv, &task)
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			expected := sort_kind == 0 && direction == 0
			testing.expect_value(t, conv.task_query_indexes.initialized[sort_kind][direction], expected)
		}
	}

	// Expectations are derived from fixture fields, not the query comparator.
	expected_orders := [8][2][5]pr.TaskID {
		{{8, 2, 5, 9, 1}, {1, 2, 5, 9, 8}}, // priority
		{{8, 2, 5, 9, 1}, {1, 2, 5, 9, 8}}, // status
		{{1, 2, 5, 9, 8}, {8, 2, 5, 9, 1}}, // assignee
		{{1, 8, 2, 9, 5}, {2, 9, 8, 1, 5}}, // due, missing last
		{{9, 1, 8, 2, 5}, {5, 2, 8, 1, 9}}, // created
		{{2, 8, 1, 9, 5}, {5, 9, 1, 2, 8}}, // title
		{{1, 2, 5, 9, 8}, {8, 2, 5, 9, 1}}, // color
		{{1, 2, 8, 9, 5}, {5, 2, 8, 9, 1}}, // project
	}
	for sort_kind in 0 ..< 8 {
		for direction in 0 ..< 2 {
			reference_req := pr.TaskQueryRequest {
				status_mask = 0x0f,
				limit       = 2,
				sort        = pr.TaskQuerySort(sort_kind),
				descending  = direction == 1,
				color       = 255,
			}
			expected := expected_orders[sort_kind][direction]
			actual := make([dynamic]pr.TaskID)
			for {
				page := make([dynamic]pr.Task)
				page_result := collect_task_query_page(&conv, reference_req, &page)
				expected_cache := [8]btree.Cache_Mode{.Numeric, .Numeric, .Text, .None, .Numeric, .Text, .Numeric, .Text}
				expected_projection := [8]Task_Numeric_Projection{.Enum_Value, .Enum_Value, .Time, .Time, .Time, .Time, .Enum_Value, .Time}
				testing.expect_value(t, conv.task_query_indexes.trees[sort_kind][direction].cache, expected_cache[sort_kind])
				testing.expect_value(t, conv.task_query_indexes.trees[sort_kind][direction].projection, expected_projection[sort_kind])
				testing.expect_value(t, conv.task_query_indexes.trees[sort_kind][direction].descending, reference_req.descending)
				for task in page do append(&actual, task.id)
				if !page_result.has_more {
					delete(page)
					break
				}
				reference_req.has_cursor = true
				reference_req.cursor_number = page_result.next_cursor_number
				reference_req.cursor_task_id = page_result.next_cursor_task_id
				delete(reference_req.cursor_text)
				reference_req.cursor_text = make([]byte, len(page_result.next_cursor_text))
				copy(reference_req.cursor_text, page_result.next_cursor_text)
				delete(page)
			}
			testing.expect_value(t, len(actual), len(expected))
			for index in 0 ..< min(len(actual), len(expected)) {
				testing.expect_value(t, actual[index], expected[index])
			}
			delete(reference_req.cursor_text)
			delete(actual)
		}
	}

	out := make([dynamic]pr.Task); defer delete(out)
	req := pr.TaskQueryRequest {
		status_mask = 0x0f,
		limit       = 10,
		sort        = .Priority,
		descending  = true,
		color       = 255,
	}
	result := collect_task_query_page(&conv, req, &out)
	testing.expect_value(t, result.total_count, u32(5))
	testing.expect(
		t,
		len(out) == 5 && out[0].id == 1 && out[1].id == 2 && out[2].id == 5 && out[3].id == 9 && out[4].id == 8,
		"descending ties must retain task id ascending",
	)

	clear(&out)
	req = {
		status_mask = 0x0f,
		limit       = 10,
		sort        = .DueAt,
		descending  = true,
		color       = 255,
	}
	_ = collect_task_query_page(&conv, req, &out)
	testing.expect(t, len(out) == 5 && out[0].id == 2 && out[1].id == 9 && out[4].id == 5, "due zero must remain last in descending order")

	clear(&out)
	req = {
		status_mask    = 0x02,
		limit          = 1,
		sort           = .Title,
		color          = u8(pr.TaskColor.Red),
		blocked        = 1,
		overdue_before = 25,
		has_assignee   = true,
		assignee       = task_query_test_bytes("ann"),
		has_project    = true,
		project        = task_query_test_bytes("Alpha"),
	}
	result = collect_task_query_page(&conv, req, &out)
	testing.expect(t, result.total_count == 2 && result.has_more && out[0].id == 2, "combined predicates should count before limit")
	cursor := result
	owned_cursor := make([]byte, len(cursor.next_cursor_text))
	defer delete(owned_cursor)
	copy(owned_cursor, cursor.next_cursor_text)
	remove_task_from_index(&conv, &tasks[1])
	delete_key(&conv.tasks, tasks[1].id)
	clear(&out)
	req.has_cursor = true
	req.cursor_text = owned_cursor
	req.cursor_task_id = cursor.next_cursor_task_id
	result = collect_task_query_page(&conv, req, &out)
	testing.expect(t, len(out) == 1 && out[0].id == 9 && result.total_count == 1, "deleted cursor must seek by value")

	old := tasks[4]; tasks[4].project = task_query_test_bytes("Delta"); tasks[4].assignee = task_query_test_bytes("zoe")
	replace_task_in_index(&conv, &old, &tasks[4])
	testing.expect_value(t, btree.count(&conv.task_project_indexes["Alpha"].indexes.trees[0][0]), 1)
	testing.expect_value(t, btree.count(&conv.task_assignee_indexes["ann"].indexes.trees[0][0]), 1)
	testing.expect_value(t, btree.count(&conv.task_project_indexes["Delta"].indexes.trees[0][0]), 1)

	clear(&out)
	empty := pr.TaskQueryRequest {
		status_mask  = 0x0f,
		limit        = 10,
		sort         = .Project,
		color        = 255,
		has_project  = true,
		has_assignee = true,
	}
	empty_result := collect_task_query_page(&conv, empty, &out)
	testing.expect(t, empty_result.total_count == 1 && len(out) == 1 && out[0].id == 1, "exact empty filters must use indexed empty values")

	// The title order was instantiated above; replacing a task must update it.
	old = tasks[0]
	tasks[0].title = task_query_test_bytes("0-first")
	replace_task_in_index(&conv, &old, &tasks[0])
	clear(&out)
	empty = {
		status_mask = 0x0f,
		limit       = 10,
		sort        = .Title,
		color       = 255,
	}
	_ = collect_task_query_page(&conv, empty, &out)
	testing.expect(t, len(out) > 0 && out[0].id == 5, "instantiated lazy order must stay current after mutation")
}

@(test)
test_task_query_payload_cursor_accounting_and_legacy_note_total :: proc(t: ^testing.T) {
	conv: Conversation_State
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	defer delete(conv.tasks)
	init_task_index(&conv)
	defer destroy_task_index(&conv)

	note := pr.Task {
		id     = 9000,
		status = .Note,
	}
	task_query_test_add(&conv, &note)
	legacy_out := make([dynamic]pr.Task)
	legacy := collect_task_page(&conv, pr.ListTasksPagedRequest{status_mask = 0x10, limit = 10}, &legacy_out)
	testing.expect_value(t, legacy.total_count, u32(1))
	delete(legacy_out)

	max_description := make([]byte, pr.MAX_TASK_DESCRIPTION_LENGTH)
	defer delete(max_description)
	for &value in max_description do value = 'd'
	long_title := make([]byte, pr.MAX_TASK_TITLE_LENGTH)
	defer delete(long_title)
	for &value in long_title do value = 'y'
	short_title := task_query_test_bytes("a")
	fixture := make([dynamic]pr.Task, 0, 1024)
	defer delete(fixture)
	base_page_size := pr.getSizeTaskQueryPage(pr.TaskQueryPage{})
	accumulated := 0
	probe := pr.Task {
		id          = 1,
		status      = .Todo,
		title       = short_title,
		description = max_description[:128],
	}
	max_task_size := pr.getSizeTask(probe)
	final_probe := pr.Task {
		id     = 2,
		status = .Todo,
		title  = long_title,
	}
	final_base_size := pr.getSizeTask(final_probe)
	for MAX_PROTOCOL_PAYLOAD_SIZE - base_page_size - accumulated - final_base_size - 1 > pr.MAX_TASK_DESCRIPTION_LENGTH {
		probe.id = pr.TaskID(len(fixture) + 1)
		append(&fixture, probe)
		accumulated += max_task_size
	}
	final_description_length := MAX_PROTOCOL_PAYLOAD_SIZE - base_page_size - accumulated - final_base_size - 1
	testing.expect(t, final_description_length >= 0 && final_description_length <= pr.MAX_TASK_DESCRIPTION_LENGTH, "boundary fixture must fit task limits")
	final_probe.id = pr.TaskID(len(fixture) + 1)
	final_probe.description = max_description[:final_description_length]
	append(&fixture, final_probe)
	append(&fixture, pr.Task{id = pr.TaskID(len(fixture) + 1), status = .Todo, title = task_query_test_bytes("z")})
	for &task in fixture do task_query_test_add(&conv, &task)

	out := make([dynamic]pr.Task)
	defer delete(out)
	req := pr.TaskQueryRequest {
		status_mask = 0x0f,
		limit       = pr.MAX_TASK_PAGE_SIZE,
		sort        = .Title,
		color       = 255,
	}
	result := collect_task_query_page(&conv, req, &out)
	page := pr.TaskQueryPage {
		tasks            = out[:],
		next_cursor_text = result.next_cursor_text,
	}
	testing.expect(t, result.has_more, "boundary fixture should leave another page")
	testing.expect(t, pr.getSizeTaskQueryPage(page) <= MAX_PROTOCOL_PAYLOAD_SIZE, "cursor text must be included in page payload accounting")
}

@(test)
test_task_projects_chunk_at_transport_boundary :: proc(t: ^testing.T) {
	labels: [1009][128]byte
	projects: [1009]string
	for &label, i in labels {
		for &b in label do b = 'x'
		label[0] = u8('A' + i / 26 / 26)
		label[1] = u8('A' + i / 26 % 26)
		label[2] = u8('A' + i % 26)
		projects[i] = string(label[:])
	}
	count := task_project_chunk_count(projects[:])
	testing.expect_value(t, count, 1008)
	first := pr.TaskProjects {
		conv_id        = 7,
		projects       = projects[:count],
		has_more       = true,
		correlation_id = 123,
	}
	last := pr.TaskProjects {
		conv_id        = 7,
		projects       = projects[count:],
		correlation_id = 123,
	}
	buf := make([]byte, MAX_PROTOCOL_PAYLOAD_SIZE)
	defer delete(buf)
	chunks := [2]pr.TaskProjects{first, last}
	for msg in chunks {
		written := pr.serializeTaskProjects(msg, buf)
		testing.expect(t, written > 0 && written <= MAX_PROTOCOL_PAYLOAD_SIZE)
		testing.expect_value(t, buf[written - 5], msg.has_more ? u8(1) : u8(0))
	}
	testing.expect_value(t, len(last.projects), 1)
	testing.expect_value(t, task_project_chunk_count(nil), 0)
}

@(test)
test_task_assignee_metadata_protocol :: proc(t: ^testing.T) {
	request := [?]byte{0, 57}
	testing.expect_value(t, pr.get_opcode(request[:]), pr.Opcode.C_ListTaskAssignees)
	testing.expect(t, is_workspace_data_opcode(.C_ListTaskAssignees))
	names := [?]string{"alex", "zoe"}
	msg := pr.TaskProjects {
		conv_id        = 0,
		projects       = names[:],
		correlation_id = 321,
	}
	buffer: [128]byte
	written := pr.serializeTaskProjects(msg, buffer[:], .S_TaskAssignees)
	testing.expect_value(t, written, 28)
	testing.expect_value(t, pr.get_opcode(buffer[:written]), pr.Opcode.S_TaskAssignees)
	testing.expect_value(t, buffer[10], u8(0))
	testing.expect_value(t, buffer[11], u8(2))
	testing.expect_value(t, string(buffer[14:18]), "alex")
	testing.expect_value(t, string(buffer[20:23]), "zoe")
	testing.expect_value(t, buffer[23], u8(0))
	testing.expect_value(t, buffer[26], u8(1))
	testing.expect_value(t, buffer[27], u8(65))
	// Calendar participants can use the full username length, beyond the
	// project codec's old cap. All person facets reuse its frame layout.
	long_name: [pr.MAX_USERNAME_LENGTH]byte
	for &b in long_name do b = 'x'
	people := [?]string{string(long_name[:])}
	msg.projects = people[:]
	person_buffer: [512]byte
	for pair in ([?][2]pr.Opcode{{.C_ListSliceOwners, .S_SliceOwners}, {.C_ListTicketAssignees, .S_TicketAssignees}, {.C_ListCalendarPeople, .S_CalendarPeople}}) {
		person_request := [?]byte{0, u8(pair[0])}
		testing.expect_value(t, pr.get_opcode(person_request[:]), pair[0])
		testing.expect(t, is_workspace_data_opcode(pair[0]))
		n := pr.serializeTaskProjects(msg, person_buffer[:], pair[1])
		testing.expect_value(t, n, 274)
		testing.expect_value(t, pr.get_opcode(person_buffer[:n]), pair[1])
	}
}
