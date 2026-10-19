package work_order

Node :: struct {
	id:         u64,
	dependency: u64,
	priority:   i64,
	due_at:     i64,
}

// IDs must be unique. Dependency zero means none; due_at <= 0 means missing.
// Both results belong to the caller and use context.allocator. Input is untouched.
// Unresolved includes missing dependencies, cycles, and their blocked descendants.
// Expected O(E + V log V) time (hash lookup), O(V) auxiliary space.
order :: proc(nodes: []Node) -> (ordered: [dynamic]u64, unresolved: [dynamic]u64) {
	n := len(nodes)
	ordered = make([dynamic]u64, 0, n)
	unresolved = make([dynamic]u64, 0, n)
	indices := make(map[u64]int, n)
	defer delete(indices)
	heads := make([]int, n)
	defer delete(heads)
	next := make([]int, n)
	defer delete(next)
	emitted := make([]bool, n)
	defer delete(emitted)
	heap := make([dynamic]int, 0, n)
	defer delete(heap)
	for node, i in nodes {
		_, exists := indices[node.id]
		assert(!exists, "work_order requires unique IDs")
		indices[node.id] = i
		heads[i] = -1
	}
	for node, i in nodes {
		if node.dependency == 0 {
			push(&heap, i, nodes)
		} else if parent, ok := indices[node.dependency]; ok {
			next[i] = heads[parent]
			heads[parent] = i
		}
	}
	for len(heap) > 0 {
		i := pop(&heap, nodes)
		emitted[i] = true
		append(&ordered, nodes[i].id)
		for child := heads[i]; child != -1; child = next[child] {
			push(&heap, child, nodes)
		}
	}
	for done, i in emitted {
		if !done {push(&heap, i, nodes)}
	}
	for len(heap) > 0 {append(&unresolved, nodes[pop(&heap, nodes)].id)}
	return
}

@(private)
before :: proc(a, b: Node) -> bool {
	if a.priority != b.priority {return a.priority > b.priority}
	a_due, b_due := a.due_at > 0, b.due_at > 0
	if a_due != b_due {return a_due}
	if a_due && a.due_at != b.due_at {return a.due_at < b.due_at}
	return a.id < b.id
}

@(private)
push :: proc(heap: ^[dynamic]int, value: int, nodes: []Node) {
	append(heap, value)
	i := len(heap^) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !before(nodes[heap^[i]], nodes[heap^[p]]) {break}
		heap^[i], heap^[p] = heap^[p], heap^[i]
		i = p
	}
}

@(private)
pop :: proc(heap: ^[dynamic]int, nodes: []Node) -> int {
	result := heap^[0]
	last := len(heap^) - 1
	heap^[0] = heap^[last]
	resize(heap, last)
	i := 0
	for 2 * i + 1 < last {
		child := 2 * i + 1
		if child + 1 < last && before(nodes[heap^[child + 1]], nodes[heap^[child]]) {
			child += 1
		}
		if !before(nodes[heap^[child]], nodes[heap^[i]]) {break}
		heap^[i], heap^[child] = heap^[child], heap^[i]
		i = child
	}
	return result
}
