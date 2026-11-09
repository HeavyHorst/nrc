package personalmemory_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	memory "nrc-ai/personal_memory"
)

func scope(t *testing.T, store *memory.Store, owner, workspace string) *memory.Scope {
	t.Helper()
	s, err := store.Personal(owner, workspace, true)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func summarize(_ context.Context, input memory.SummaryInput) (string, error) {
	if input.Original != nil {
		return fmt.Sprintf("historical leaf %d (%s)", input.Original.Sequence, input.Original.State), nil
	}
	return fmt.Sprintf("historical range %d to %d", input.Node.Lo, input.Node.Hi), nil
}

func build(t *testing.T, s *memory.Scope) {
	t.Helper()
	for i := 0; i < 1000; i++ {
		ok, err := s.BuildNext(t.Context(), "fixture-v1", summarize)
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			return
		}
	}
	t.Fatal("tree did not settle")
}

func TestSummaryRetriesSurviveRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s := scope(t, store, "owner", "workspace")
	seg, err := s.Append(t.Context(), "source", "chat", "complete", []memory.Record{{Role: "user", Text: "original"}})
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	fail := func(context.Context, memory.SummaryInput) (string, error) {
		calls++
		return "", errors.New("provider unavailable")
	}
	for i := 0; i < 6; i++ {
		s.BuildNext(t.Context(), "test", fail)
		if err := store.Close(); err != nil {
			t.Fatal(err)
		}
		store, err = memory.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		s = scope(t, store, "owner", "workspace")
	}
	defer store.Close()
	if calls != 3 {
		t.Fatalf("expected three durable attempts, got %d", calls)
	}
	if got, err := s.Read(t.Context(), seg.Sequence); err != nil || got.Records[0].Text != "original" {
		t.Fatal("original lost", got, err)
	}
	if err := s.Finish(t.Context(), seg.Sequence, seg.Revision, "complete", append(seg.Records, memory.Record{Role: "assistant", Text: "late captured response"})); err != nil {
		t.Fatal(err)
	}
	if worked, err := s.BuildNext(t.Context(), "test", summarize); !worked || err != nil {
		t.Fatal("new source revision cannot progress", worked, err)
	}
}

func TestFailedSummaryDoesNotBlockLaterEvidence(t *testing.T) {
	for _, deadline := range []bool{false, true} {
		t.Run(fmt.Sprint(deadline), func(t *testing.T) {
			store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			s := scope(t, store, "owner", "workspace")
			for i := 0; i < 2; i++ {
				if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: fmt.Sprint(i)}}); err != nil {
					t.Fatal(err)
				}
			}
			failing := func(ctx context.Context, in memory.SummaryInput) (string, error) {
				if in.Node.Lo == 0 {
					if deadline {
						<-ctx.Done()
						return "", ctx.Err()
					}
					return "", errors.New("source cannot fit provider budget")
				}
				return summarize(ctx, in)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
			defer cancel()
			if worked, err := s.BuildNext(ctx, "test", failing); worked || err == nil {
				t.Fatal(worked, err)
			}
			if worked, err := s.BuildNext(t.Context(), "test", failing); !worked || err != nil {
				t.Fatal("failed source blocked later evidence", worked, err)
			}
			view, err := s.View(t.Context(), 6000)
			if err != nil {
				t.Fatal(err)
			}
			children, _, err := s.Expand(t.Context(), view.Roots[0])
			if err != nil || len(children) != 2 || children[0].State != "pending" || children[1].State != "ready" {
				t.Fatal("unexpected progress", children, err)
			}
			build(t, s)
			for i := int64(0); i < 2; i++ {
				original, err := s.Read(t.Context(), i)
				if err != nil || original.Records[0].Text != fmt.Sprint(i) {
					t.Fatal("original changed", err)
				}
			}
		})
	}
}

func TestSummaryWorkerResumesAndCancels(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	a := scope(t, store, "a", "team")
	b := scope(t, store, "b", "team")
	for _, s := range []*memory.Scope{a, b} {
		text := "other owner"
		if s == a {
			text = "cancel this owner"
		}
		for i := 0; i < 2; i++ {
			if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: text}}); err != nil {
				t.Fatal(err)
			}
		}
	}
	// Pending work must be discovered without a request or an in-memory wakeup.
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	a = scope(t, store, "a", "team")
	b = scope(t, store, "b", "team")
	ctx, cancel := context.WithCancel(t.Context())
	done, started, cancelled, parent := make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{}, 1)
	go func() {
		defer close(done)
		store.RunSummaries(ctx, "test-worker", func(ctx context.Context, in memory.SummaryInput) (string, error) {
			if in.Original != nil && in.Original.Records[0].Text == "cancel this owner" {
				close(started)
				<-ctx.Done()
				close(cancelled)
				return "forgotten provider output", nil // Deliberately ignores cancellation.
			}
			if len(in.Children) > 0 && in.Children[0].Summary != "" {
				parent <- struct{}{}
			}
			return summarize(ctx, in)
		})
	}()
	defer func() { cancel(); <-done }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("worker did not discover pending work")
	}
	if err := a.ForgetAll(t.Context(), 0); err != nil {
		t.Fatal(err)
	}
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("forget did not cancel model call")
	}
	select {
	case <-parent:
	case <-time.After(8 * time.Second):
		t.Fatal("other scope did not build a parent")
	}
	deadline := time.Now().Add(time.Second)
	for {
		v, err := b.View(t.Context(), 250)
		if err == nil && v.Complete {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("parent summary not published", v, err)
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	<-done
	for _, s := range []*memory.Scope{a, b} {
		v, err := s.View(t.Context(), 6000)
		if err != nil || !v.Complete {
			t.Fatal(v, err)
		}
		for _, n := range v.Nodes {
			if strings.Contains(n.Summary, "forgotten") {
				t.Fatal("late summary resurrected history")
			}
		}
	}
}

func TestSummaryWorkerSkipsDisabledAndActiveAndRetries(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for _, name := range []string{"a-failing", "b-ready", "c-disabled", "d-active"} {
		s := scope(t, store, name, "team")
		state := "complete"
		if name == "d-active" {
			state = "active"
		}
		if _, err := s.Append(t.Context(), name, "chat", state, []memory.Record{{Role: "user", Text: name}}); err != nil {
			t.Fatal(err)
		}
		if name == "c-disabled" {
			p, _ := s.Retention(t.Context())
			p.Enabled = false
			if err := s.Configure(t.Context(), p); err != nil {
				t.Fatal(err)
			}
		}
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	done, ready, retried := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		failures := 0
		store.RunSummaries(ctx, "test", func(_ context.Context, in memory.SummaryInput) (string, error) {
			switch in.Original.Records[0].Text {
			case "a-failing":
				failures++
				if failures == 1 {
					return "", errors.New("provider unavailable")
				}
				close(retried)
				return "recovered", nil
			case "b-ready":
				close(ready)
				return "ready", nil
			default:
				t.Error("summarized disabled or active evidence")
				return "", errors.New("unexpected input")
			}
		})
	}()
	defer func() { cancel(); <-done }()
	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		t.Fatal("failed scope starved others")
	}
	select {
	case <-retried:
	case <-time.After(5 * time.Second):
		t.Fatal("pending failure not retried")
	}
}

func TestSummaryWorkerCrossesScopePage(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for i := 0; i < 65; i++ {
		name := fmt.Sprintf("workspace-%02d", i)
		s := scope(t, store, "same-owner", name)
		if _, err := s.Append(t.Context(), name, "chat", "complete", []memory.Record{{Role: "user", Text: name}}); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	seen := make(chan string, 65)
	go func() {
		defer close(done)
		store.RunSummaries(ctx, "test", func(_ context.Context, in memory.SummaryInput) (string, error) {
			name := in.Original.Records[0].Text
			seen <- name
			return name, nil
		})
	}()
	defer func() { cancel(); <-done }()
	deadline := time.After(5 * time.Second)
	processed := make(map[string]bool)
	for i := 0; i < 65; i++ {
		select {
		case name := <-seen:
			if processed[name] {
				t.Fatalf("scope repeated before all pending scopes were processed: %s", name)
			}
			processed[name] = true
		case <-deadline:
			t.Fatal("pending scope beyond first page was not processed")
		}
	}
}

func TestDurableTreeZoomAndScope(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	alice := scope(t, store, "issuer/alice", "team")
	if _, err = store.Personal("issuer/alice", "team", false); !errors.Is(err, memory.ErrScope) {
		t.Fatal("accepted absent consent")
	}
	for i := 0; i < 13; i++ {
		text := fmt.Sprintf("unrelated discussion %d", i)
		if i == 2 {
			text = "Kühlschrank: exact recovery code 7391, not 7319."
		}
		records := []memory.Record{{Role: "user", Text: text}}
		seg, err := alice.Append(t.Context(), fmt.Sprint(i), "chat", "complete", records)
		if err != nil || seg.Sequence != int64(i) {
			t.Fatalf("append %d: %+v %v", i, seg, err)
		}
		duplicate, err := alice.Append(t.Context(), fmt.Sprint(i), "chat", "complete", records)
		if err != nil || duplicate.Sequence != seg.Sequence {
			t.Fatal("duplicate allocated a leaf", err)
		}
	}
	// Pending jobs and original evidence must survive a process/storage reopen.
	if err = store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	alice = scope(t, store, "issuer/alice", "team")
	build(t, alice)
	view, err := alice.View(t.Context(), 700)
	if err != nil || !view.Complete {
		t.Fatalf("view: %+v %v", view, err)
	}
	data, _ := json.Marshal(view)
	if len(data) > 700 {
		t.Fatal("view exceeded budget")
	}
	covered := int64(0)
	var target memory.Node
	for _, n := range view.Nodes {
		if n.Lo != covered {
			t.Fatal("overlap or gap", view)
		}
		covered = n.Hi + 1
		if n.Lo <= 2 && n.Hi >= 2 {
			target = n
		}
	}
	if covered != 13 || target.Hi == target.Lo {
		t.Fatal("fixture needs compressed history", view)
	}
	// Do not call Search: summary clues deliberately omit the recovery code.
	for target.Lo != target.Hi {
		children, _, err := alice.Expand(t.Context(), target)
		if err != nil {
			t.Fatal(err)
		}
		if len(children) != 2 {
			t.Fatal("not binary")
		}
		if children[0].Hi >= 2 {
			target = children[0]
		} else {
			target = children[1]
		}
	}
	_, original, err := alice.Expand(t.Context(), target)
	if err != nil || original.Records[0].Text != "Kühlschrank: exact recovery code 7391, not 7319." {
		t.Fatal("lost originals", original, err)
	}
	for _, other := range []*memory.Scope{scope(t, store, "issuer/bob", "team"), scope(t, store, "issuer/alice", "elsewhere")} {
		if _, err = other.Read(t.Context(), 2); !errors.Is(err, memory.ErrNotFound) {
			t.Fatal("cross-scope read")
		}
		if _, _, err = other.Expand(t.Context(), target); !errors.Is(err, memory.ErrNotFound) {
			t.Fatal("cross-scope expansion")
		}
		ids, err := other.Search(t.Context(), "Kühlschrank", 5)
		if err != nil || len(ids) != 0 {
			t.Fatal("cross-scope search", ids, err)
		}
	}
	ids, err := alice.Search(t.Context(), "Kühlschrank", 5)
	if err != nil || len(ids) != 1 || ids[0] != 2 {
		t.Fatal("FTS5 missing", ids, err)
	}
	tiny, err := alice.View(t.Context(), 128)
	if err != nil || tiny.Complete {
		t.Fatal("hidden coverage gap", tiny, err)
	}
}

func TestRevisionFencesDeletionAndActiveTail(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	ctx := t.Context()
	segment, err := s.Append(ctx, "voice-event", "voice", "active", []memory.Record{{Role: "user", Text: " repeated repeated ", EventID: "e1", ProviderSession: "live1"}})
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := s.BuildNext(ctx, "v1", summarize); err != nil || ok {
		t.Fatal("summarized active voice", err)
	}
	view, err := s.View(ctx, 2048)
	if err != nil || !view.Complete || len(view.Active) != 1 || view.Active[0].Records[0].Text != " repeated repeated " {
		t.Fatal("active tail lost", view, err)
	}
	if err = s.Finish(ctx, segment.Sequence, segment.Revision, "incomplete", segment.Records); err != nil {
		t.Fatal(err)
	}
	started, release := make(chan struct{}), make(chan struct{})
	result := make(chan error, 1)
	go func() {
		_, err := s.BuildNext(ctx, "v1", func(context.Context, memory.SummaryInput) (string, error) {
			close(started)
			<-release
			return "stale private secret", nil
		})
		result <- err
	}()
	<-started
	if err = s.Forget(ctx, 0, 2); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err = <-result; !errors.Is(err, memory.ErrConflict) {
		t.Fatal("stale job resurrected forgotten content", err)
	}
	if err = s.Finish(ctx, 0, 2, "complete", segment.Records); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("late fragment resurrected deletion", err)
	}
	if _, err = s.Append(ctx, "voice-event", "voice", "active", segment.Records); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("retry resurrected deletion", err)
	}
	if _, err = s.Read(ctx, 0); !errors.Is(err, memory.ErrNotFound) {
		t.Fatal("forgotten original readable", err)
	}
	ids, err := s.Search(ctx, "repeated", 5)
	if err != nil || len(ids) != 0 {
		t.Fatal("forgotten FTS data", ids, err)
	}
	build(t, s)
	next, err := s.Append(ctx, "next", "chat", "complete", []memory.Record{{Role: "user", Text: "retained"}})
	if err != nil || next.Sequence != 1 {
		t.Fatal("deletion renumbered history", next, err)
	}
	build(t, s)
	before, err := s.View(ctx, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Finish(ctx, 1, 1, "complete", []memory.Record{{Role: "user", Text: "replacement"}}); err == nil {
		t.Fatal("original evidence overwritten")
	}
	if err = s.Finish(ctx, 1, 1, "complete", []memory.Record{{Role: "user", Text: "retained"}, {Role: "user", Text: "late fragment"}}); err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.Expand(ctx, before.Nodes[len(before.Nodes)-1]); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("stale view accepted", err)
	}
	after, err := s.View(ctx, 1000)
	if err != nil || after.Complete || len(after.Active) != 0 {
		t.Fatal("invalidated summary served", after, err)
	}
	if ok, err := s.BuildNext(ctx, "v2", func(context.Context, memory.SummaryInput) (string, error) {
		return strings.Repeat("x", memory.MaxSummaryBytes+1), nil
	}); err == nil || ok {
		t.Fatal("oversize summary accepted")
	}
	build(t, s)
	after, err = s.View(ctx, 1000)
	if err != nil || !after.Complete {
		t.Fatal("failed job not recoverable", after, err)
	}
}

func TestConcurrentParentBuildersAndForgetSurviveRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	s := scope(t, store, "alice", "team")
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	for i := 0; i < 2; i++ {
		if _, err := s.Append(ctx, fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: fmt.Sprintf("secret%d", i)}}); err != nil {
			t.Fatal(err)
		}
		if ok, err := s.BuildNext(ctx, "v1", summarize); err != nil || !ok {
			t.Fatal(ok, err)
		}
	}
	// Both workers capture the same parent before either publishes.
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			_, err := s.BuildNext(ctx, "v1", func(ctx context.Context, input memory.SummaryInput) (string, error) {
				if len(input.Children) != 2 {
					return "", fmt.Errorf("expected parent: %+v", input)
				}
				started <- struct{}{}
				select {
				case <-release:
					return "stale secret0 parent", nil
				case <-ctx.Done():
					return "", ctx.Err()
				}
			})
			results <- err
		}()
	}
	for i := 0; i < 2; i++ {
		select {
		case <-started:
		case <-ctx.Done():
			t.Fatal("builders did not reach parent")
		}
	}
	if err := s.Forget(ctx, 0, 1); err != nil {
		t.Fatal(err)
	}
	close(release)
	for i := 0; i < 2; i++ {
		if err := <-results; !errors.Is(err, memory.ErrConflict) && !errors.Is(err, context.Canceled) {
			t.Fatal("stale parent published", err)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s = scope(t, store, "alice", "team")
	view, err := s.View(ctx, 2048)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(view)
	if strings.Contains(string(data), "secret0") {
		t.Fatal("forgotten parent survived", string(data))
	}
	if _, err := s.Read(ctx, 0); !errors.Is(err, memory.ErrNotFound) {
		t.Fatal("forgotten source survived", err)
	}
	ids, err := s.Search(ctx, "secret0", 5)
	if err != nil || len(ids) != 0 {
		t.Fatal("forgotten search entry survived", ids, err)
	}
	build(t, s)
	view, err = s.View(ctx, 2048)
	if err != nil || !view.Complete {
		t.Fatal("invalidation jobs did not recover", view, err)
	}
	// Race two fresh builders without invalidation: exactly one may publish.
	if _, err := s.Append(ctx, "next", "chat", "complete", []memory.Record{{Role: "user", Text: "retained"}}); err != nil {
		t.Fatal(err)
	}
	release = make(chan struct{})
	for i := 0; i < 2; i++ {
		go func() {
			_, err := s.BuildNext(ctx, "v2", func(ctx context.Context, _ memory.SummaryInput) (string, error) {
				started <- struct{}{}
				select {
				case <-release:
					return "new summary", nil
				case <-ctx.Done():
					return "", ctx.Err()
				}
			})
			results <- err
		}()
	}
	for i := 0; i < 2; i++ {
		select {
		case <-started:
		case <-ctx.Done():
			t.Fatal("builders blocked")
		}
	}
	close(release)
	first, second := <-results, <-results
	if !((first == nil && errors.Is(second, memory.ErrConflict)) || (second == nil && errors.Is(first, memory.ErrConflict))) {
		t.Fatal("concurrent publication", first, second)
	}
}

func TestCommittedMemorySurvivesProcessExit(t *testing.T) {
	if path := os.Getenv("NRC_MEMORY_CRASH_TEST_DB"); path != "" {
		store, err := memory.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		s := scope(t, store, "alice", "team")
		for i := 0; i < 3; i++ {
			if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: fmt.Sprintf("durable%d", i)}}); err != nil {
				t.Fatal(err)
			}
		}
		build(t, s)
		if err := s.Forget(t.Context(), 0, 1); err != nil {
			t.Fatal(err)
		}
		// Exit without Close, defers or SQLite checkpoint: recover committed WAL.
		os.Exit(0)
	}
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestCommittedMemorySurvivesProcessExit$")
	cmd.Env = append(os.Environ(), "NRC_MEMORY_CRASH_TEST_DB="+path)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("child: %v %s", err, out)
	}
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	for _, seq := range []int64{1, 2} {
		got, err := s.Read(t.Context(), seq)
		if err != nil || got.Records[0].Text != fmt.Sprintf("durable%d", seq) {
			t.Fatal("lost committed original", got, err)
		}
	}
	if _, err := s.Read(t.Context(), 0); !errors.Is(err, memory.ErrNotFound) {
		t.Fatal("lost committed deletion", err)
	}
	build(t, s)
	view, err := s.View(t.Context(), 2048)
	if err != nil || !view.Complete {
		t.Fatal("pending jobs lost", view, err)
	}
	seg, err := s.Append(t.Context(), "next", "chat", "complete", []memory.Record{{Role: "user", Text: "next"}})
	if err != nil || seg.Sequence != 3 {
		t.Fatal("sequence lost", seg, err)
	}
}

func TestViewBudgetPrefersRecentEvidenceWithPendingBacklog(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	for i := 0; i < 256; i++ {
		state, text := "complete", strings.Repeat("<&>", 500)
		if i%2 == 0 {
			state = "active"
		}
		if i == 255 {
			state, text = "active", "newest exact evidence"
		}
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", state, []memory.Record{{Role: "user", Text: text}}); err != nil {
			t.Fatal(err)
		}
	}
	for _, budget := range []int{128, 256, 512, 2048} {
		view, err := s.View(t.Context(), budget)
		data, _ := json.Marshal(view)
		if err != nil || view.Complete || len(data) > budget {
			t.Fatal("budget or coverage", budget, len(data), view.Complete, err)
		}
		if budget >= 256 && (len(view.Active) != 1 || view.Active[0].Sequence != 255 || view.Active[0].Records[0].Text != "newest exact evidence") {
			t.Fatal("recent evidence omitted", view)
		}
	}
	allocations := func() float64 {
		return testing.AllocsPerRun(2, func() {
			view, err := s.View(t.Context(), 512)
			data, _ := json.Marshal(view)
			if err != nil || view.Complete || len(data) > 512 {
				t.Fatal("bounded view failed", err)
			}
		})
	}
	small := allocations()
	for i := 256; i < 1024; i++ {
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "active", []memory.Record{{Role: "user", Text: strings.Repeat("<&>", 500)}}); err != nil {
			t.Fatal(err)
		}
	}
	large := allocations()
	// A fixed-budget view must not materialize a backlog four times larger.
	// Allow ample allocator variation; the old full traversal grows over 4x.
	if large > small*2 {
		t.Fatalf("view allocations scale with backlog: %.0f -> %.0f", small, large)
	}
	t.Logf("fixed-budget view allocations, 256 -> 1024 leaves: %.0f -> %.0f", small, large)
}

func TestPendingTreeKeepsOriginalsReachable(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	facts := []string{"Balloon Copper Heron, code 7319", "Correction: current code 8426, not 7319"}
	for i := 0; i < 260; i++ {
		text, state := " unrelated voice fragment ", "complete"
		if i < len(facts) {
			text = facts[i]
		}
		if i == 259 {
			text, state = strings.Repeat("<&>", 3000), "active"
		}
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "voice", state, []memory.Record{{Role: "user", Text: text}}); err != nil {
			t.Fatal(err)
		}
	}
	view, err := s.View(t.Context(), 6000)
	encoded, _ := json.Marshal(view)
	if err != nil || len(encoded) > 6000 || view.Complete {
		t.Fatal("pending view budget/coverage", err, len(encoded), view.Complete)
	}
	for sequence, expected := range facts {
		var target memory.Node
		found := false
		for _, root := range view.Roots {
			if root.Lo <= int64(sequence) && root.Hi >= int64(sequence) {
				target, found = root, true
				break
			}
		}
		if !found {
			t.Fatal("pending history has no navigation reference", sequence)
		}
		for target.Lo != target.Hi {
			children, _, err := s.Expand(t.Context(), target)
			if err != nil {
				t.Fatal(err)
			}
			target = children[0]
			if int64(sequence) > target.Hi {
				target = children[1]
			}
		}
		_, original, err := s.Expand(t.Context(), target)
		if err != nil || original.Records[0].Text != expected {
			t.Fatal("lost pending original", sequence, err)
		}
	}
	// A ready parent must become available before draining every newer leaf.
	for i := 0; i < 3; i++ {
		ok, err := s.BuildNext(t.Context(), "fixture", summarize)
		if err != nil || !ok {
			t.Fatal(ok, err)
		}
	}
	view, err = s.View(t.Context(), 6000)
	if err != nil {
		t.Fatal(err)
	}
	foundParent := false
	for _, root := range view.Roots {
		if root.Lo != 0 {
			continue
		}
		for root.Hi > 1 {
			children, _, err := s.Expand(t.Context(), root)
			if err != nil {
				t.Fatal(err)
			}
			root = children[0]
		}
		foundParent = root.Lo == 0 && root.Hi == 1 && root.State == "ready"
	}
	if !foundParent {
		t.Fatal("newer leaves starved the oldest parent")
	}
}

func TestStableViewAppendMergeRestartAndInvalidation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { store.Close() }()
	s := scope(t, store, "owner", "workspace")
	var previous []memory.Node
	merges := 0
	for i := 0; i < 80; i++ {
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: fmt.Sprintf("original-%d", i)}}); err != nil {
			t.Fatal(err)
		}
		build(t, s)
		view, err := s.StableView(t.Context(), 1024)
		if err != nil {
			t.Fatal(err)
		}
		encoded, _ := json.Marshal(view)
		if len(encoded) > 1024 || len(view) == 0 {
			t.Fatal("invalid bounded view", string(encoded))
		}
		end := int64(0)
		for _, n := range view {
			if n.Lo != end || n.State != "ready" {
				t.Fatal("gap or pending stable entry", view)
			}
			end = n.Hi + 1
		}
		if end != int64(i+1) {
			t.Fatal("lost coverage", end, i)
		}
		if len(previous) > 0 {
			old, _ := json.Marshal(previous)
			if len(view) == len(previous)+1 {
				prefix, _ := json.Marshal(view[:len(previous)])
				if string(prefix) != string(old) {
					t.Fatal("append rewrote prefix")
				}
			} else {
				merges++
				if len(encoded) > 512 {
					t.Fatal("merge did not batch toward half", len(encoded))
				}
			}
		}
		previous = view
	}
	if merges < 2 {
		t.Fatal("did not cross multiple high-water marks")
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s = scope(t, store, "owner", "workspace")
	view, err := s.StableView(t.Context(), 1024)
	a, _ := json.Marshal(previous)
	b, _ := json.Marshal(view)
	if err != nil || string(a) != string(b) {
		t.Fatal("restart changed layout", err)
	}
	for _, other := range []*memory.Scope{scope(t, store, "other", "workspace"), scope(t, store, "owner", "other")} {
		v, err := other.StableView(t.Context(), 1024)
		if err != nil || len(v) != 0 {
			t.Fatal("scope leaked", v, err)
		}
	}
	if err := s.Finish(t.Context(), 0, 1, "complete", []memory.Record{{Role: "user", Text: "original-0"}, {Role: "assistant", Text: "late completion"}}); err != nil {
		t.Fatal(err)
	}
	view, err = s.StableView(t.Context(), 1024)
	if err != nil || len(view) != 0 {
		t.Fatal("late completion retained stale prefix", view, err)
	}
	tail, err := s.ViewFrom(t.Context(), 0, 6000)
	if err != nil || tail.Complete {
		t.Fatal("pending summary hidden", tail, err)
	}
	build(t, s)
	if _, err := s.StableView(t.Context(), 1024); err != nil {
		t.Fatal(err)
	}
	lease, ctx, release, err := s.Execution(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if err := s.ForgetAll(t.Context(), 0); err != nil {
		t.Fatal(err)
	}
	if _, err := lease.StableView(context.WithoutCancel(ctx), 1024); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("old epoch accepted", err)
	}
	view, err = s.StableView(t.Context(), 1024)
	encoded, _ := json.Marshal(view)
	if err != nil || strings.Contains(string(encoded), "historical") {
		t.Fatal("forgotten summary survived", err)
	}
}

func TestStableViewPendingSuffix(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "owner", "workspace")
	for i := 0; i < 3; i++ {
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: "closed"}}); err != nil {
			t.Fatal(err)
		}
	}
	build(t, s)
	before, err := s.StableView(t.Context(), 6000)
	if err != nil || len(before) != 3 {
		t.Fatal(before, err)
	}
	for i := 3; i < 9; i++ {
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: fmt.Sprint(i)}}); err != nil {
			t.Fatal(err)
		}
	}
	after, err := s.StableView(t.Context(), 6000)
	a, _ := json.Marshal(before)
	b, _ := json.Marshal(after)
	if err != nil || string(a) != string(b) {
		t.Fatal("pending suffix changed prefix", err)
	}
	tail, err := s.ViewFrom(t.Context(), 3, 6000)
	if err != nil || len(tail.Active) != 6 || tail.Active[0].Sequence != 3 || tail.Active[5].Sequence != 8 {
		t.Fatal("unaligned suffix lost originals", tail, err)
	}
}

func TestStableViewOversizedLeafUsesReadyParent(t *testing.T) {
	for _, count := range []int{2, 4} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			s := scope(t, store, "owner", "workspace")
			for i := 0; i < count; i++ {
				if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: "original"}}); err != nil {
					t.Fatal(err)
				}
			}
			for {
				ok, err := s.BuildNext(t.Context(), "test", func(_ context.Context, in memory.SummaryInput) (string, error) {
					if count == 4 {
						if in.Node.Lo == 0 && in.Node.Hi == 0 {
							return strings.Repeat("a", 400), nil
						}
						if in.Node.Lo == 0 && in.Node.Hi == 1 {
							return strings.Repeat("b", 1200), nil
						}
					}
					if in.Original != nil {
						return strings.Repeat("x", 1500), nil
					}
					return "compact parent", nil
				})
				if err != nil {
					t.Fatal(err)
				}
				if !ok {
					break
				}
			}
			for i := 0; i < 2; i++ {
				view, err := s.StableView(t.Context(), 1024)
				if err != nil || len(view) != 1 || view[0].Lo != 0 || view[0].Hi != int64(count-1) || view[0].Summary != "compact parent" {
					t.Fatal("ready parent blocked by oversized leaf", view, err)
				}
			}
		})
	}
}
