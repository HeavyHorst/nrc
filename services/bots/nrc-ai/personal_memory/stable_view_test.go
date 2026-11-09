package personalmemory

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestStableViewDeferredCompactionUsesLastMessageAge(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { store.Close() }()
	s, err := store.Personal("owner", "workspace", true)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []Record{{Role: "user", Text: "original"}}); err != nil {
			t.Fatal(err)
		}
	}
	for {
		worked, err := s.BuildNext(t.Context(), "test", func(context.Context, SummaryInput) (string, error) { return strings.Repeat("x", 100), nil })
		if err != nil {
			t.Fatal(err)
		}
		if !worked {
			break
		}
	}
	// Resume a pending half-budget batch: both parents are initially unavailable.
	refs := []Node{{Lo: 0, Hi: 3, Revision: 1}, {Lo: 4, Hi: 7, Revision: 1}, {Lo: 8, Hi: 8, Revision: 1}, {Lo: 9, Hi: 9, Revision: 1}}
	for i, ref := range refs {
		n, err := readNode(t.Context(), store.db, s, ref.Lo, ref.Hi)
		if err != nil {
			t.Fatal(err)
		}
		refs[i] = n
	}
	b, _ := json.Marshal(refs)
	layout, _ := json.Marshal(viewLayout{Nodes: refs, Capacity: 2048, Target: len(b) - 1})
	if _, err := store.db.Exec(`INSERT INTO memory_views VALUES(?,?,?,?)`, "owner", "workspace", 10, string(layout)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE nodes SET state='pending' WHERE owner='owner' AND workspace='workspace' AND ((lo=0 AND hi=7) OR (lo=8 AND hi=9))`); err != nil {
		t.Fatal(err)
	}
	before, err := s.StableView(t.Context(), 2048)
	if err != nil || len(before) != 4 {
		t.Fatal(before, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s, err = store.Personal("owner", "workspace", true)
	if err != nil {
		t.Fatal(err)
	}
	for {
		worked, err := s.BuildNext(t.Context(), "test", func(context.Context, SummaryInput) (string, error) { return strings.Repeat("x", 100), nil })
		if err != nil {
			t.Fatal(err)
		}
		if !worked {
			break
		}
	}
	view, err := s.StableView(t.Context(), 2048)
	// At T=10: recent pair scores (10-9)/1=1, old pair (10-7)/4=.75.
	if err != nil || len(view) != 3 || view[0].Hi != 3 || view[1].Hi != 7 || view[2].Lo != 8 || view[2].Hi != 9 {
		t.Fatal("wrong merge priority or lost deferred target", view, err)
	}
	again, err := s.StableView(t.Context(), 2048)
	x, _ := json.Marshal(view)
	y, _ := json.Marshal(again)
	if err != nil || string(x) != string(y) {
		t.Fatal("settled view changed", err)
	}
}

func TestSummaryContextDoesNotReadFutureOrOtherScopes(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for _, owner := range []string{"alice", "bob"} {
		s, err := store.Personal(owner, "team", true)
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 12; i++ {
			if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []Record{{Role: "user", Text: owner}}); err != nil {
				t.Fatal(err)
			}
		}
	}
	s, _ := store.Personal("alice", "team", true)
	seen := 0
	for {
		worked, err := s.BuildNext(t.Context(), "test", func(ctx context.Context, in SummaryInput) (string, error) {
			nodes, err := in.Context(ctx)
			if err != nil {
				return "", err
			}
			limit := in.Node.Hi + 1
			if in.Original != nil {
				limit = in.Node.Lo
			}
			for _, n := range nodes {
				if n.Hi >= limit || n.Summary != "alice" {
					t.Errorf("unsafe context for %v: %v", in.Node, nodes)
				}
			}
			seen += len(nodes)
			return "alice", nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if !worked {
			break
		}
	}
	if seen == 0 {
		t.Fatal("context never populated")
	}
}
