package personalmemory

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"
	"unicode/utf8"
)

type Node struct {
	Lo       int64  `json:"lo"`
	Hi       int64  `json:"hi"`
	Revision int64  `json:"revision"`
	State    string `json:"state,omitempty"`
	Summary  string `json:"summary,omitempty"`
	Version  string `json:"version,omitempty"`
}

// SummaryInput is untrusted historical evidence, not a prompt. A model adapter
// must preserve roles, uncertainty and capture state in its trusted instructions.
type SummaryInput struct {
	Node     Node
	Original *Segment
	Children []Node
	// Lazy, owner/epoch-bound context; short exact summaries need no view work.
	Context func(context.Context) ([]Node, error) `json:"-"`
}
type Summarize func(context.Context, SummaryInput) (string, error)

func readNode(ctx context.Context, db rowReader, s *Scope, lo, hi int64) (Node, error) {
	if err := s.checkEpoch(ctx, db); err != nil {
		return Node{}, err
	}
	n := Node{Lo: lo, Hi: hi}
	err := db.QueryRowContext(ctx, `SELECT revision,state,summary,version FROM nodes WHERE owner=? AND workspace=? AND lo=? AND hi=?`, s.owner, s.workspace, lo, hi).Scan(&n.Revision, &n.State, &n.Summary, &n.Version)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrNotFound
	}
	return n, err
}

// BuildNext computes one pending node without holding a transaction during the
// model call. The revision fence rejects results after correction or forgetting.
// Concurrent workers may compute the same node, but only one can publish it.
func (s *Scope) BuildNext(ctx context.Context, version string, summarize Summarize) (bool, error) {
	if version == "" || len(version) > 128 || summarize == nil {
		return false, errors.New("summary version and builder required")
	}
	lease, workCtx, release, err := s.Execution(ctx)
	if err != nil {
		return false, err
	}
	defer release()
	s, ctx = lease, workCtx
	s.store.mu.Lock()
	input, found, err := s.nextInput(ctx)
	if err == nil && found {
		// Reserve before calling the provider: deadlines, crashes and restarts
		// must not replenish the three-build allowance for this source revision.
		tx, beginErr := s.store.db.BeginTx(ctx, nil)
		err = beginErr
		if err == nil {
			_, err = tx.ExecContext(ctx, `INSERT INTO summary_attempts(owner,workspace,lo,hi,revision,attempts) VALUES(?,?,?,?,?,1)
ON CONFLICT(owner,workspace,lo,hi) DO UPDATE SET attempts=attempts+1`, s.owner, s.workspace, input.Node.Lo, input.Node.Hi, input.Node.Revision)
			if err == nil {
				_, err = tx.ExecContext(ctx, `DELETE FROM summary_ready WHERE owner=? AND workspace=? AND lo=? AND hi=? AND EXISTS(SELECT 1 FROM summary_attempts a WHERE a.owner=summary_ready.owner AND a.workspace=summary_ready.workspace AND a.lo=summary_ready.lo AND a.hi=summary_ready.hi AND a.attempts>=3)`, s.owner, s.workspace, input.Node.Lo, input.Node.Hi)
			}
			if err == nil {
				err = tx.Commit()
			}
			tx.Rollback()
		}
	}
	s.store.mu.Unlock()
	if err != nil || !found {
		return false, err
	}
	input.Context = func(ctx context.Context) ([]Node, error) {
		limit := input.Node.Hi + 1
		if input.Original != nil {
			limit = input.Node.Lo
		}
		return s.stableView(ctx, 6000, limit, true)
	}
	text := ""
	if input.Original == nil || input.Original.State != "deleted" {
		text, err = summarize(ctx, input)
		if err == nil && (text == "" || len(text) > MaxSummaryBytes || !utf8.ValidString(text)) {
			err = errors.New("invalid or oversized summary")
		}
		if err != nil {
			// A permanently failing source must not monopolize its scope. Prefer
			// other ready work, while retaining the failed node for later retries.
			if ctx.Err() == nil || errors.Is(ctx.Err(), context.DeadlineExceeded) {
				queueCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
				defer cancel()
				s.store.mu.Lock()
				if s.checkEpoch(queueCtx, s.store.db) == nil {
					_, queueErr := s.store.db.ExecContext(queueCtx, `UPDATE summary_ready SET attempts=attempts+1 WHERE owner=? AND workspace=? AND lo=? AND hi=? AND EXISTS(SELECT 1 FROM nodes n WHERE n.owner=summary_ready.owner AND n.workspace=summary_ready.workspace AND n.lo=summary_ready.lo AND n.hi=summary_ready.hi AND n.revision=? AND n.state='pending')`, s.owner, s.workspace, input.Node.Lo, input.Node.Hi, input.Node.Revision)
					err = errors.Join(err, queueErr)
				}
				s.store.mu.Unlock()
			}
			return false, err
		}
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if err := s.checkEpoch(context.WithoutCancel(ctx), s.store.db); err != nil {
		return false, err
	}
	r, err := s.store.db.ExecContext(ctx, `UPDATE nodes SET state='ready',summary=?,version=? WHERE owner=? AND workspace=? AND lo=? AND hi=? AND revision=? AND state='pending'`, text, version, s.owner, s.workspace, input.Node.Lo, input.Node.Hi, input.Node.Revision)
	if err != nil {
		return false, err
	}
	n, _ := r.RowsAffected()
	if n != 1 {
		return false, ErrConflict
	}
	return true, nil
}

func (s *Scope) nextInput(ctx context.Context) (SummaryInput, bool, error) {
	// A leaf is ready to build only when closed. A parent requires both children.
	var lo, hi int64
	err := s.store.db.QueryRowContext(ctx, `SELECT lo,hi FROM summary_ready
WHERE owner=? AND workspace=? ORDER BY attempts,lo,hi LIMIT 1`, s.owner, s.workspace).Scan(&lo, &hi)
	if errors.Is(err, sql.ErrNoRows) {
		return SummaryInput{}, false, nil
	}
	if err != nil {
		return SummaryInput{}, false, err
	}
	n, err := readNode(ctx, s.store.db, s, lo, hi)
	if err != nil {
		return SummaryInput{}, false, err
	}
	input := SummaryInput{Node: n}
	if lo == hi {
		segment, err := s.Read(ctx, lo)
		if errors.Is(err, ErrNotFound) {
			segment = Segment{Sequence: lo, State: "deleted"}
		} else if err != nil {
			return input, false, err
		}
		input.Original = &segment
	} else {
		for _, bounds := range [][2]int64{{lo, (lo + hi) / 2}, {(lo+hi)/2 + 1, hi}} {
			child, err := readNode(ctx, s.store.db, s, bounds[0], bounds[1])
			if err != nil {
				return input, false, err
			}
			input.Children = append(input.Children, child)
		}
	}
	return input, true, nil
}

// Expand checks the revision returned in a view before returning more detail.
// A leaf returns a source sequence; Read retrieves its bounded exact originals.
func (s *Scope) Expand(ctx context.Context, node Node) ([]Node, *Segment, error) {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	current, err := readNode(ctx, s.store.db, s, node.Lo, node.Hi)
	if err != nil {
		return nil, nil, err
	}
	if current.Revision != node.Revision {
		return nil, nil, ErrConflict
	}
	if node.Lo == node.Hi {
		segment, err := s.Read(ctx, node.Lo)
		return nil, &segment, err
	}
	var children []Node
	for _, bounds := range [][2]int64{{node.Lo, (node.Lo + node.Hi) / 2}, {(node.Lo+node.Hi)/2 + 1, node.Hi}} {
		child, err := readNode(ctx, s.store.db, s, bounds[0], bounds[1])
		if err != nil {
			return nil, nil, err
		}
		children = append(children, child)
	}
	return children, nil, nil
}

type View struct {
	Roots    []Node    `json:"roots"`
	Nodes    []Node    `json:"nodes"`
	Active   []Segment `json:"active"`
	Complete bool      `json:"complete"`
}

// View bounds the entire encoded JSON, including references and active originals.
// Root references reserve navigation even when the summary queue is backlogged.
// Older history uses broad roots. Recent ready roots split while the byte budget
// permits. Missing summaries are explicit gaps, never advertised as complete.
// Byte budgets are conservative input bounds, not a provider token-count claim.
func (s *Scope) View(ctx context.Context, budget int) (View, error) {
	return s.viewFrom(ctx, 0, budget, false)
}

// ViewFrom renders the changing suffix after a persisted stable prefix.
func (s *Scope) ViewFrom(ctx context.Context, from int64, budget int) (View, error) {
	return s.viewFrom(ctx, from, budget, true)
}

func (s *Scope) viewFrom(ctx context.Context, from int64, budget int, includeClosed bool) (View, error) {
	view := View{Roots: []Node{}, Nodes: []Node{}, Active: []Segment{}, Complete: true}
	if budget < 128 || budget > 64<<10 || from < 0 {
		return view, errors.New("invalid view budget")
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if err := s.checkEpoch(ctx, s.store.db); err != nil {
		return view, err
	}
	var count int64
	err := s.store.db.QueryRowContext(ctx, `SELECT next_seq FROM scopes WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&count)
	if errors.Is(err, sql.ErrNoRows) {
		return view, nil
	}
	if err != nil {
		return view, err
	}
	var roots []Node
	for lo := from; lo < count; {
		width := int64(1)
		for width <= (count-lo)/2 && lo%(2*width) == 0 {
			width *= 2
		}
		n, err := readNode(ctx, s.store.db, s, lo, lo+width-1)
		if err != nil {
			return view, err
		}
		roots = append(roots, n)
		lo += width
	}
	// Reserve the larger (complete=false) envelope and array delimiters. Encode
	// each candidate once, never a repeatedly shrinking copy of the whole view.
	used := len(`{"roots":[],"nodes":[],"active":[],"complete":false}`)
	encodedSize := func(v any) int { b, _ := json.Marshal(v); return len(b) }
	// These compact references are independent of summary readiness and traversal
	// limits. Expand can navigate every pending subtree back to exact originals.
	for _, n := range roots {
		ref := Node{Lo: n.Lo, Hi: n.Hi, Revision: n.Revision}
		size := encodedSize(ref) + 1
		if used+size > budget {
			view.Complete = false
			continue
		}
		view.Roots = append(view.Roots, ref)
		used += size
	}
	// Pending subtrees can contain arbitrarily many unsummarized leaves. Bound
	// traversal independently of accepted bytes, including oversized originals.
	visits := budget/64 + 64
	var visit func(Node) error
	visit = func(n Node) error {
		if visits == 0 {
			view.Complete = false
			return nil
		}
		visits--
		if n.State == "ready" {
			size := encodedSize(n) + 1
			if used+size <= budget {
				view.Nodes = append(view.Nodes, n)
				used += size
			} else {
				view.Complete = false
			}
			return nil
		}
		if n.Lo == n.Hi {
			segment, err := s.Read(ctx, n.Lo)
			if errors.Is(err, ErrNotFound) {
				return nil
			}
			if err != nil {
				return err
			}
			if segment.State != "active" {
				view.Complete = false // Closed original awaiting its summary.
			}
			size := encodedSize(segment) + 1
			if (segment.State == "active" || includeClosed) && used+size <= budget {
				view.Active = append(view.Active, segment)
				used += size
			} else {
				view.Complete = false
			}
			return nil
		}
		for _, bounds := range [][2]int64{{(n.Lo+n.Hi)/2 + 1, n.Hi}, {n.Lo, (n.Lo + n.Hi) / 2}} {
			if visits == 0 {
				view.Complete = false
				break
			}
			child, err := readNode(ctx, s.store.db, s, bounds[0], bounds[1])
			if err != nil {
				return err
			}
			if err = visit(child); err != nil {
				return err
			}
		}
		return nil
	}
	// Spend the budget newest first, then restore chronological output order.
	for i := len(roots) - 1; i >= 0; i-- {
		if err = visit(roots[i]); err != nil {
			return view, err
		}
	}
	slices.Reverse(view.Nodes)
	slices.Reverse(view.Active)
	for i := len(view.Nodes) - 1; i >= 0; i-- {
		n := view.Nodes[i]
		if n.Lo == n.Hi || visits < 2 {
			continue
		}
		visits -= 2
		left, err := readNode(ctx, s.store.db, s, n.Lo, (n.Lo+n.Hi)/2)
		if err != nil {
			return view, err
		}
		right, err := readNode(ctx, s.store.db, s, (n.Lo+n.Hi)/2+1, n.Hi)
		if err != nil {
			return view, err
		}
		if left.State != "ready" || right.State != "ready" {
			return view, fmt.Errorf("ready parent has invalid children")
		}
		delta := encodedSize(left) + encodedSize(right) + 1 - encodedSize(n)
		if used+delta <= budget {
			view.Nodes = slices.Replace(view.Nodes, i, i+1, left, right)
			used += delta
			i += 2
		}
	}
	return view, nil
}
