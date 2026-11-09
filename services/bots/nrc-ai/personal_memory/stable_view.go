package personalmemory

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math/bits"
	"slices"
)

type viewLayout struct {
	Nodes    []Node `json:"nodes"`
	Capacity int    `json:"capacity"`
	Target   int    `json:"target"`
}

// StableView persists a chronological partition, not a second copy of private
// text. Ready nodes append without rewriting earlier entries. Only crossing the
// byte high-water mark merges siblings, in a batch toward half the budget.
// Pending work stays outside this prefix; ViewFrom supplies the bounded suffix.
func (s *Scope) StableView(ctx context.Context, budget int) ([]Node, error) {
	return s.stableView(ctx, budget, -1, false)
}

func (s *Scope) stableView(ctx context.Context, budget int, limit int64, summary bool) ([]Node, error) {
	if budget < 512 || budget > 64<<10 {
		return nil, errors.New("invalid stable view budget")
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if err := s.checkEpoch(ctx, s.store.db); err != nil {
		return nil, err
	}
	table := "memory_views"
	if summary {
		table = "summary_views"
	}
	var count int64
	if err := s.store.db.QueryRowContext(ctx, `SELECT next_seq FROM scopes WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&count); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if limit < 0 || limit > count {
		limit = count
	}
	var saved string
	var savedEnd int64
	err := s.store.db.QueryRowContext(ctx, `SELECT layout,end_seq FROM `+table+` WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&saved, &savedEnd)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	layout := viewLayout{Capacity: budget}
	if saved != "" {
		var err error
		if saved[0] == '[' {
			err = json.Unmarshal([]byte(saved), &layout.Nodes)
		} else {
			err = json.Unmarshal([]byte(saved), &layout)
		}
		if err != nil {
			return nil, err
		}
	}
	// A smaller request or an older compaction may need a temporary projection,
	// but must not replace the persisted partition used by subsequent calls.
	persist := limit >= savedEnd && budget >= layout.Capacity
	budget = min(budget, layout.Capacity)
	refs := layout.Nodes
	if limit < savedEnd {
		refs = nil
	}
	nodes := []Node{}
	end := int64(0)
	for _, ref := range refs {
		n, err := readNode(ctx, s.store.db, s, ref.Lo, ref.Hi)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return nil, err
		}
		if err != nil || n.State != "ready" || n.Revision != ref.Revision || n.Lo != end {
			// Recovery or a revised source makes the old layout unusable.
			nodes, end = []Node{}, 0
			break
		}
		nodes = append(nodes, n)
		end = n.Hi + 1
	}
	size := func(ns []Node) int { b, _ := json.Marshal(ns); return len(b) }
	fit := func() error {
		if size(nodes) > budget {
			layout.Target = budget / 2
		}
		if layout.Target == 0 {
			return nil
		}
		for size(nodes) > layout.Target {
			best := -1
			var chosen Node
			var bestAge, bestWidth uint64
			for i := 0; i+1 < len(nodes); i++ {
				a, b := nodes[i], nodes[i+1]
				width := a.Hi - a.Lo + 1
				if a.Lo%(2*width) != 0 || a.Hi+1 != b.Lo || b.Hi-b.Lo+1 != width {
					continue
				}
				parent, err := readNode(ctx, s.store.db, s, a.Lo, b.Hi)
				if err != nil {
					return err
				}
				if parent.State != "ready" || size([]Node{parent}) >= size(nodes[i:i+2]) {
					continue
				}
				age := uint64(limit - b.Hi)
				// Compare age/width exactly; age starts at the pair's LAST
				// message. Chronological traversal breaks equal scores oldest-first.
				ah, al := bits.Mul64(age, bestWidth)
				bh, bl := bits.Mul64(bestAge, uint64(width))
				if best < 0 || ah > bh || (ah == bh && al > bl) {
					best, chosen, bestAge, bestWidth = i, parent, age, uint64(width)
				}
			}
			if best < 0 {
				break
			}
			nodes = slices.Replace(nodes, best, best+2, chosen)
		}
		if size(nodes) <= layout.Target {
			layout.Target = 0
		}
		// A pending parent must not stall admission or exceed the budget. Leave
		// the suffix available through ViewFrom and exact-original tools instead.
		for size(nodes) > budget {
			nodes = nodes[:len(nodes)-1]
		}
		end = 0
		if len(nodes) > 0 {
			end = nodes[len(nodes)-1].Hi + 1
		}
		return nil
	}
	if err := fit(); err != nil {
		return nil, err
	}
	// Independently bound catch-up work on a large pre-existing history.
	for visits := 0; visits < budget/64+64; visits++ {
		if end >= limit {
			break
		}
		n, err := readNode(ctx, s.store.db, s, end, end)
		if errors.Is(err, ErrNotFound) || (err == nil && n.State != "ready") {
			break
		}
		if err != nil {
			return nil, err
		}
		previousEnd := end
		previousNodes := slices.Clone(nodes)
		for depth := 0; depth < 62; depth++ {
			nodes = slices.Clone(previousNodes)
			for len(nodes) > 0 && nodes[len(nodes)-1].Lo >= n.Lo {
				nodes = nodes[:len(nodes)-1]
			}
			nodes = append(nodes, n)
			end = n.Hi + 1
			if err := fit(); err != nil {
				return nil, err
			}
			if end > previousEnd {
				break
			}
			// A leaf can exceed the budget even though its ready parent fits.
			// Ancestors may absorb earlier prefix entries too. Retry from the
			// original partition so an unsuccessful merge cannot erase it.
			// At most 62 indexed reads, never an unbounded leaf scan.
			width := n.Hi - n.Lo + 1
			lo := previousEnd / (2 * width) * (2 * width)
			if lo+2*width > limit {
				break
			}
			n, err = readNode(ctx, s.store.db, s, lo, lo+2*width-1)
			if errors.Is(err, ErrNotFound) || (err == nil && n.State != "ready") {
				break
			}
			if err != nil {
				return nil, err
			}
		}
		if end <= previousEnd {
			nodes, end = previousNodes, previousEnd
			break
		}
	}
	refs = make([]Node, len(nodes))
	for i, n := range nodes {
		refs[i] = Node{Lo: n.Lo, Hi: n.Hi, Revision: n.Revision}
	}
	layout.Nodes = refs
	encoded, _ := json.Marshal(layout)
	err = nil
	if persist && string(encoded) != saved {
		_, err = s.store.db.ExecContext(ctx, `INSERT INTO `+table+` VALUES(?,?,?,?) ON CONFLICT(owner,workspace) DO UPDATE SET end_seq=excluded.end_seq,layout=excluded.layout`, s.owner, s.workspace, end, string(encoded))
	}
	return nodes, err
}
