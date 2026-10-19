package work_order

import hgl "../hegel"
import "core:testing"

check :: proc(t: ^testing.T, nodes: []Node, want, blocked: []u64) {
	copy_nodes := make([]Node, len(nodes))
	defer delete(copy_nodes)
	copy(copy_nodes, nodes)
	a, b := order(nodes)
	defer delete(a)
	defer delete(b)
	if testing.expect_value(t, len(a), len(want)) {
		for value, i in a {testing.expect_value(t, value, want[i])}
	}
	if testing.expect_value(t, len(b), len(blocked)) {
		for value, i in b {testing.expect_value(t, value, blocked[i])}
	}
	for node, i in nodes {testing.expect_value(t, node, copy_nodes[i])}
}

@(test)
ready_frontier :: proc(t: ^testing.T) {
	// Unlocking a high priority child must immediately outrank an existing root;
	// its low priority sibling must not inherit the parent's position.
	check(t, []Node{{4, 1, -10, 0}, {3, 1, 100, 0}, {2, 0, 0, 0}, {1, 0, 1, 0}}, []u64{1, 3, 2, 4}, nil)
}

@(test)
priority_due_id :: proc(t: ^testing.T) {
	check(t, []Node{{9, 0, 2, 100}, {8, 0, 1, -1}, {7, 0, 1, 0}, {6, 0, 1, 20}, {5, 0, 1, 10}, {4, 0, 1, 10}, {3, 0, -1, 1}}, []u64{9, 4, 5, 6, 7, 8, 3}, nil)
}

@(test)
unresolved_not_only_cycles :: proc(t: ^testing.T) {
	check(
		t,
		[]Node{{1, 99, 0, 0}, {2, 1, 5, 0}, {3, 4, 2, 10}, {4, 3, 2, 5}, {5, 4, 2, 5}, {6, 6, 2, -1}, {7, 6, 2, 0}, {8, 0, -1, 0}, {9, 8, 9, 0}},
		[]u64{8, 9},
		[]u64{2, 4, 5, 3, 6, 7, 1},
	)
}

@(test)
empty_and_chain :: proc(t: ^testing.T) {
	check(t, nil, nil, nil)
	check(t, []Node{{3, 2, 100, 1}, {2, 1, 0, 0}, {1, 0, -1, 0}}, []u64{1, 2, 3}, nil)
}

// Deliberately quadratic reference: repeatedly scan every remaining node for
// the best eligible item. No heap, adjacency list or production comparator.
prop_scan_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	n, err := hgl.draw_i64(tc, 0, 32)
	if err == .Stop_Test do return hgl.abort()
	if err != nil do return hgl.interesting("node count draw")
	storage: [32]Node
	nodes := storage[:int(n)]
	for &node, i in nodes {
		dependency, e1 := hgl.draw_i64(tc, 0, n + 2)
		priority, e2 := hgl.draw_i64(tc, -2, 3)
		due, e3 := hgl.draw_i64(tc, -1, 3)
		if e1 == .Stop_Test || e2 == .Stop_Test || e3 == .Stop_Test do return hgl.abort()
		if e1 != nil || e2 != nil || e3 != nil do return hgl.interesting("node field draw")
		node = Node{u64(i + 1), u64(dependency), priority, due}
	}
	ordered, unresolved := order(nodes)
	defer delete(ordered)
	defer delete(unresolved)
	remaining: [32]bool
	for i in 0 ..< int(n) do remaining[i] = true
	emitted: [32]bool
	for phase in 0 ..< 2 {
		actual := phase == 0 ? ordered[:] : unresolved[:]
		count := 0
		for {
			best := -1
			for candidate, i in nodes {
				if !remaining[i] do continue
				if phase == 0 && candidate.dependency != 0 {
					if candidate.dependency > u64(n) || !emitted[candidate.dependency - 1] do continue
				}
				if best < 0 {best = i; continue}
				chosen := nodes[best]
				a_date := candidate.due_at > 0 ? candidate.due_at : max(i64)
				b_date := chosen.due_at > 0 ? chosen.due_at : max(i64)
				if candidate.priority > chosen.priority ||
				   (candidate.priority == chosen.priority && (a_date < b_date || (a_date == b_date && candidate.id < chosen.id))) {best = i}
			}
			if best < 0 do break
			if count >= len(actual) || actual[count] != nodes[best].id do return hgl.interesting("heap differs from scan model")
			remaining[best] = false
			emitted[best] = true
			count += 1
		}
		if count != len(actual) do return hgl.interesting("missing or duplicate output")
	}
	// Input enumeration must not select a different ready task or unresolved tie.
	for i in 0 ..< int(n) / 2 {nodes[i], nodes[int(n) - 1 - i] = nodes[int(n) - 1 - i], nodes[i]}
	a, b := order(nodes)
	defer delete(a)
	defer delete(b)
	if len(a) != len(ordered) || len(b) != len(unresolved) do return hgl.interesting("permutation changes partition")
	for id, i in a {if id != ordered[i] do return hgl.interesting("permutation changes order")}
	for id, i in b {if id != unresolved[i] do return hgl.interesting("permutation changes unresolved")}
	return hgl.valid()
}

@(test)
hegel_scan_model_equivalence :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_scan_model, nil, {test_cases = 1000})
	testing.expectf(t, err == nil && result.passed, "work order model equivalence: %v", err)
}
