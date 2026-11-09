package personalmemory_test

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	memory "nrc-ai/personal_memory"
)

func TestSummaryWorkerProductiveSweepProgress(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		for _, owner := range []string{"a", "b"} {
			s := scope(t, store, owner, "team")
			for i := 0; i < 4; i++ {
				if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: owner}}); err != nil {
					t.Fatal(err)
				}
			}
		}
		ctx, cancel := context.WithCancel(t.Context())
		done := make(chan struct{})
		var calls []string
		var mu sync.Mutex
		go func() {
			defer close(done)
			store.RunSummaries(ctx, "progress", func(_ context.Context, in memory.SummaryInput) (string, error) {
				owner := ""
				if in.Original != nil {
					owner = in.Original.Records[0].Text
				} else {
					owner = in.Children[0].Summary
				}
				mu.Lock()
				calls = append(calls, owner)
				mu.Unlock()
				return owner, nil
			})
		}()
		defer func() { cancel(); <-done }()
		synctest.Wait()
		// Four leaves and three parents per scope must drain without advancing
		// the clock. Every sweep gives both scopes a turn before wrapping.
		if len(calls) != 14 {
			t.Fatalf("productive sweep slept with work pending: calls=%v", calls)
		}
		counts := map[string]int{}
		for _, owner := range calls {
			counts[owner]++
		}
		if counts["a"] != 7 || counts["b"] != 7 {
			t.Fatalf("scope work skipped or repeated: %v", calls)
		}
	})
}

func TestSummaryWorkerSlowScopeDoesNotBlockFreeSlots(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		for _, owner := range []string{"a", "b", "c", "d", "e", "f", "g", "h", "i"} {
			s := scope(t, store, owner, "team")
			for i := 0; i < 2; i++ {
				if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: owner}}); err != nil {
					t.Fatal(err)
				}
			}
		}
		ctx, cancel := context.WithCancel(t.Context())
		done := make(chan struct{})
		var completed atomic.Int32
		go func() {
			defer close(done)
			store.RunSummaries(ctx, "slow", func(ctx context.Context, in memory.SummaryInput) (string, error) {
				if in.Original != nil && in.Original.Records[0].Text == "a" {
					<-ctx.Done()
					return "", ctx.Err()
				}
				completed.Add(1)
				return "ready", nil
			})
		}()
		defer func() { cancel(); <-done }()
		synctest.Wait()
		if completed.Load() != 24 {
			t.Fatalf("slow scope blocked productive scopes or ninth scope: %d/24", completed.Load())
		}
	})
}

func TestSummaryWorkerFailureBackoffDuringProgress(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		for _, owner := range []string{"a-failing", "b-ready"} {
			s := scope(t, store, owner, "team")
			for i := 0; i < 4; i++ {
				if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: owner}}); err != nil {
					t.Fatal(err)
				}
			}
		}
		ctx, cancel := context.WithCancel(t.Context())
		done := make(chan struct{})
		var failures, completed atomic.Int32
		go func() {
			defer close(done)
			store.RunSummaries(ctx, "backoff", func(_ context.Context, in memory.SummaryInput) (string, error) {
				if in.Original != nil && in.Original.Records[0].Text == "a-failing" {
					failures.Add(1)
					return "", errors.New("fixture provider unavailable")
				}
				completed.Add(1)
				return "ready", nil
			})
		}()
		defer func() { cancel(); <-done }()
		synctest.Wait()
		if failures.Load() != 1 || completed.Load() != 7 {
			t.Fatalf("failed scope retried hot or blocked healthy progress: failures=%d completed=%d", failures.Load(), completed.Load())
		}
		time.Sleep(time.Second)
		synctest.Wait()
		if failures.Load() != 2 || completed.Load() != 7 {
			t.Fatalf("failure did not back off and retry: failures=%d completed=%d", failures.Load(), completed.Load())
		}
	})
}

func TestSummaryWorkerIdleCancellation(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(fmt.Sprint(active), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
				if err != nil {
					t.Fatal(err)
				}
				defer store.Close()
				if active {
					s := scope(t, store, "a", "team")
					if _, err := s.Append(t.Context(), "active", "voice", "active", []memory.Record{{Role: "user", Text: "unfinished"}}); err != nil {
						t.Fatal(err)
					}
				}
				ctx, cancel := context.WithCancel(t.Context())
				done := make(chan struct{})
				go func() {
					defer close(done)
					store.RunSummaries(ctx, "idle", func(context.Context, memory.SummaryInput) (string, error) {
						t.Error("idle worker called provider")
						return "", errors.New("unexpected call")
					})
				}()
				synctest.Wait()
				before := time.Now()
				cancel()
				<-done
				if time.Since(before) != 0 {
					t.Fatal("idle cancellation waited for timer")
				}
			})
		})
	}
}

func TestForgetAllSettlesTombstonesBeforeFreshEvidence(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		s := scope(t, store, "a", "team")
		var last memory.Segment
		for i := 0; i < 128; i++ {
			state := "complete"
			if i == 127 {
				state = "active"
			}
			last, err = s.Append(t.Context(), fmt.Sprint(i), "voice", state, []memory.Record{{Role: "user", Text: "forgotten"}})
			if err != nil {
				t.Fatal(err)
			}
		}
		lease, execution, release, err := s.Execution(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		defer release()
		if err := s.ForgetAll(t.Context(), lease.Epoch()); err != nil {
			t.Fatal(err)
		}
		if execution.Err() != context.Canceled {
			t.Fatal("forget did not cancel execution")
		}
		if _, err := lease.Read(t.Context(), 0); !errors.Is(err, memory.ErrConflict) {
			t.Fatal("old epoch still readable", err)
		}
		if err := lease.Finish(t.Context(), last.Sequence, last.Revision, "complete", last.Records); !errors.Is(err, memory.ErrConflict) {
			t.Fatal("late capture escaped forget fence", err)
		}
		if worked, err := s.BuildNext(t.Context(), "forgotten", summarize); worked || err != nil {
			t.Fatalf("forgotten tree still queued: worked=%v err=%v", worked, err)
		}
		fresh, err := s.Append(t.Context(), "fresh", "chat", "complete", []memory.Record{{Role: "user", Text: "fresh evidence"}})
		if err != nil || fresh.Sequence != 128 {
			t.Fatal("fresh append", fresh, err)
		}
		ctx, cancel := context.WithCancel(t.Context())
		done := make(chan struct{})
		calls := 0
		go func() {
			defer close(done)
			store.RunSummaries(ctx, "fresh", func(_ context.Context, in memory.SummaryInput) (string, error) {
				calls++
				if in.Original == nil || in.Original.Sequence != fresh.Sequence {
					t.Error("forgotten tree sent to provider", in.Node)
				}
				return "fresh evidence", nil
			})
		}()
		defer func() { cancel(); <-done }()
		synctest.Wait()
		if calls != 1 {
			t.Fatalf("fresh evidence delayed by tombstones: calls=%d", calls)
		}
	})
}
