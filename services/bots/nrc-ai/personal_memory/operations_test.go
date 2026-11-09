package personalmemory_test

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	memory "nrc-ai/personal_memory"
)

func TestReceiptPagesRemainScopedAfterForgetting(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	other := scope(t, store, "bob", "team")
	otherWorkspace := scope(t, store, "alice", "other")
	for i, owner := range []*memory.Scope{s, other, s, otherWorkspace} {
		action := string(rune('a' + i))
		r, consumed, err := owner.ConsumeApproval(t.Context(), "chat", "session", "plan", action, []byte("private proposal"))
		if err != nil || !consumed {
			t.Fatal(r, consumed, err)
		}
		if i == 0 {
			if err := owner.CompleteApproval(t.Context(), r, "applied", []byte(`{"created_task_id":7319}`)); err != nil {
				t.Fatal(err)
			}
		}
	}
	p, err := s.Retention(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.ForgetAll(t.Context(), p.Epoch); err != nil {
		t.Fatal(err)
	}
	page, err := s.Receipts(t.Context(), -1, 1)
	if err != nil || len(page) != 1 || page[0].ActionID != "c" || page[0].State != "outcome_unknown" {
		t.Fatal(page, err)
	}
	page, err = s.Receipts(t.Context(), page[0].Position, 2)
	if err != nil || len(page) != 1 || page[0].ActionID != "a" || page[0].State != "applied" || string(page[0].Result) != `{"created_task_id":7319}` {
		t.Fatal(page, err)
	}
}

func TestApprovalGenerationTracksOnlyNewUserEvidence(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	ctx := t.Context()
	run, _, err := s.BeginRun(ctx, "request", "chat", []byte("request"), []memory.Record{{Role: "user", Text: "Create task"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Finish(ctx, run.Segment.Sequence, run.Segment.Revision, "complete", append(run.Segment.Records, memory.Record{Role: "assistant", Text: "Proposed"})); err != nil {
		t.Fatal(err)
	}
	if _, err := scope(t, store, "bob", "team").Append(ctx, "other", "chat", "complete", []memory.Record{{Role: "user", Text: "Unrelated"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := scope(t, store, "alice", "other").Append(ctx, "other", "chat", "complete", []memory.Record{{Role: "user", Text: "Unrelated"}}); err != nil {
		t.Fatal(err)
	}
	build(t, s)
	if _, consumed, err := s.ConsumeApproval(ctx, "chat", "session", "plan", "control", []byte("proposal"), run.UserInputGeneration); err != nil || !consumed {
		t.Fatal(consumed, err)
	}
	voice, err := s.Append(ctx, "voice", "voice", "active", []memory.Record{{Role: "user", Text: "Correction", EventID: "first"}})
	if err != nil {
		t.Fatal(err)
	}
	gen, err := s.UserInputGeneration(ctx)
	if err != nil || gen != run.UserInputGeneration+1 {
		t.Fatal(gen, err)
	}
	fragment := memory.Record{Role: "user", Text: "Withdraw the request", EventID: "second"}
	voice, err = s.AppendFragment(ctx, voice.Sequence, voice.Revision, fragment)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendFragment(ctx, voice.Sequence, voice.Revision, fragment); err != nil {
		t.Fatal(err)
	}
	latest, err := s.UserInputGeneration(ctx)
	if err != nil || latest != gen+1 {
		t.Fatal("replay changed generation", latest, err)
	}
	// A stale approval arriving after preparation but before consumption must
	// neither dispatch nor leave an ambiguous receipt.
	if _, consumed, err := s.ConsumeApproval(ctx, "voice", "session", "plan", "stale", []byte("proposal"), gen); consumed || !errors.Is(err, memory.ErrConflict) {
		t.Fatal(consumed, err)
	}
	if _, err := s.ReadReceipt(ctx, "voice", "session", "plan", "stale"); !errors.Is(err, memory.ErrNotFound) {
		t.Fatal(err)
	}
	if _, consumed, err := s.ConsumeApproval(ctx, "voice", "session", "fresh", "new", []byte("new proposal"), latest); err != nil || !consumed {
		t.Fatal(consumed, err)
	}
}

func TestRunAndApprovalRecovery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s := scope(t, store, "alice", "team")
	ctx := t.Context()
	input := []memory.Record{{Role: "user", Text: "exact original"}}
	var runs, claims atomic.Int32
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			_, created, err := s.BeginRun(ctx, "r1", "chat", []byte("request"), input)
			if err != nil {
				t.Error(err)
			}
			if created {
				runs.Add(1)
			}
			_, consumed, err := s.ConsumeApproval(ctx, "chat", "session", "plan", "a1", []byte("proposal"))
			if err != nil {
				t.Error(err)
			}
			if consumed {
				claims.Add(1)
			}
		})
	}
	wg.Wait()
	if runs.Load() != 1 || claims.Load() != 1 {
		t.Fatal("multiple dispatch grants", runs.Load(), claims.Load())
	}
	if other, err := memory.Open(path); err == nil {
		other.Close()
		t.Fatal("second store owner allowed")
	}
	if _, _, err := s.BeginRun(ctx, "r1", "chat", []byte("changed"), input); !errors.Is(err, memory.ErrConflict) {
		t.Fatal(err)
	}
	if _, _, err := s.ConsumeApproval(ctx, "chat", "session", "plan", "a1", []byte("changed")); !errors.Is(err, memory.ErrConflict) {
		t.Fatal(err)
	}
	r, err := s.ReadReceipt(ctx, "chat", "session", "plan", "a1")
	if err != nil || r.State != "outcome_unknown" {
		t.Fatal(r, err)
	}
	if err := s.CompleteApproval(ctx, r, "applied", []byte(`{"created_task_id":7319}`)); err != nil {
		t.Fatal(err)
	}
	if err := s.CompleteApproval(ctx, r, "failed", []byte(`{}`)); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("receipt overwritten", err)
	}
	if err := s.Finish(ctx, 0, 1, "complete", append(input, memory.Record{Role: "assistant", Text: "answer"})); err != nil {
		t.Fatal(err)
	}
	for _, other := range []*memory.Scope{scope(t, store, "bob", "team"), scope(t, store, "alice", "other")} {
		if _, err := other.ReadRun(ctx, "chat", "r1"); !errors.Is(err, memory.ErrNotFound) {
			t.Fatal("run leaked", err)
		}
		if _, err := other.ReadReceipt(ctx, "chat", "session", "plan", "a1"); !errors.Is(err, memory.ErrNotFound) {
			t.Fatal("receipt leaked", err)
		}
	}
	if _, err := s.ReadReceipt(ctx, "voice", "session", "plan", "a1"); !errors.Is(err, memory.ErrNotFound) {
		t.Fatal("channel leaked", err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s = scope(t, store, "alice", "team")
	run, created, err := s.BeginRun(ctx, "r1", "chat", []byte("request"), input)
	if err != nil || created || run.Segment.State != "complete" || run.Segment.Records[1].Text != "answer" {
		t.Fatal(run, created, err)
	}
	r, consumed, err := s.ConsumeApproval(ctx, "chat", "session", "plan", "a1", []byte("proposal"))
	if err != nil || consumed || r.State != "applied" || string(r.Result) != `{"created_task_id":7319}` {
		t.Fatal(r, consumed, err)
	}
	if err := s.Forget(ctx, 0, run.Segment.Revision); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ReadRun(ctx, "chat", "r1"); !errors.Is(err, memory.ErrNotFound) {
		t.Fatal("deleted run returned", err)
	}
	if _, created, err := s.BeginRun(ctx, "r1", "chat", []byte("request"), input); created || !errors.Is(err, memory.ErrNotFound) {
		t.Fatal("deleted run regenerated", created, err)
	}
}

func TestInterruptedRunAndApprovalSurviveProcessExit(t *testing.T) {
	if path := os.Getenv("NRC_OPERATION_CRASH_DB"); path != "" {
		store, err := memory.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		s := scope(t, store, "alice", "team")
		if _, _, err := s.BeginRun(t.Context(), "r1", "voice", []byte("request"), []memory.Record{{Role: "user", Text: "voice original"}}); err != nil {
			t.Fatal(err)
		}
		if _, _, err := s.ConsumeApproval(t.Context(), "voice", "session", "plan", "a1", []byte("proposal")); err != nil {
			t.Fatal(err)
		}
		os.Exit(0) // No checkpoint or close; acknowledgement of the write is lost.
	}
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestInterruptedRunAndApprovalSurviveProcessExit$")
	cmd.Env = append(os.Environ(), "NRC_OPERATION_CRASH_DB="+path)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("child: %v %s", err, out)
	}
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	run, created, err := s.BeginRun(t.Context(), "r1", "voice", []byte("request"), []memory.Record{{Role: "user", Text: "voice original"}})
	if err != nil || created || run.Segment.State != "incomplete" || run.Segment.Revision != 2 {
		t.Fatal(run, created, err)
	}
	if err := s.Finish(t.Context(), 0, 1, "complete", []memory.Record{{Role: "user", Text: "voice original"}}); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("stale completion accepted", err)
	}
	r, consumed, err := s.ConsumeApproval(t.Context(), "voice", "session", "plan", "a1", []byte("proposal"))
	if err != nil || consumed || r.State != "outcome_unknown" {
		t.Fatal(r, consumed, err)
	}
	build(t, s)
	view, err := s.View(t.Context(), 2048)
	if err != nil || !view.Complete {
		t.Fatal("recovered original not in tree", view, err)
	}
}
