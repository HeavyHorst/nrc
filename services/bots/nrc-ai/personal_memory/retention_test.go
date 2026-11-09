package personalmemory_test

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"testing"

	memory "nrc-ai/personal_memory"
)

func TestLegacyQuotasDoNotLimitHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	legacy, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = legacy.Exec(`ALTER TABLE retention ADD COLUMN max_bytes INTEGER NOT NULL DEFAULT 1;
ALTER TABLE retention ADD COLUMN max_segments INTEGER NOT NULL DEFAULT 1;`)
	if err != nil {
		t.Fatal(err)
	}
	if err := legacy.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "alice", "team")
	other := scope(t, store, "bob", "team")
	for i := range 3 {
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: fmt.Sprintf("original %d", i)}}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := other.Append(t.Context(), "other", "voice", "complete", []memory.Record{{Role: "user", Text: "not Alice's"}}); err != nil {
		t.Fatal(err)
	}
	p, err := s.Retention(t.Context())
	if err != nil || p.Segments != 3 || p.Bytes <= 1 {
		t.Fatal(p, err)
	}
	page, err := s.History(t.Context(), p.Epoch, -1, 2)
	if err != nil || len(page) != 2 || page[0].Sequence != 2 || page[1].Sequence != 1 || page[0].Records[0].Text != "original 2" {
		t.Fatal(page, err)
	}
	next, err := s.History(t.Context(), p.Epoch, page[1].Sequence, 2)
	if err != nil || len(next) != 1 || next[0].Sequence != 0 {
		t.Fatal(next, err)
	}
	if err := s.ForgetAll(t.Context(), p.Epoch); err != nil {
		t.Fatal(err)
	}
	if _, err := s.History(t.Context(), p.Epoch, -1, 2); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("stale history page", err)
	}
}

func TestRetentionRevocationAndExport(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	db, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s := scope(t, db, "alice", "team")
	ctx := t.Context()
	p, err := s.Retention(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Configure(ctx, p); err != nil {
		t.Fatal(err)
	}
	lease, work, release, err := s.Execution(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	original := []memory.Record{{Role: "user", Text: "ü"}}
	seg, err := lease.Append(work, "one", "chat", "active", original)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lease.Append(work, "one", "chat", "active", original); err != nil {
		t.Fatal("duplicate failed", err)
	}
	r, consumed, err := lease.ConsumeApproval(ctx, "chat", "s", "p", "a", []byte("proposal"))
	if err != nil || !consumed {
		t.Fatal(r, err)
	}
	p, err = s.Retention(ctx)
	if err != nil || p.Bytes <= 0 || p.Segments != 1 {
		t.Fatal(p, err)
	}
	page, err := s.Export(ctx, p.Epoch, -1, 1)
	if err != nil || len(page) != 1 || page[0].Records[0].Text != "ü" {
		t.Fatal(page, err)
	}
	other := scope(t, db, "bob", "team")
	_, otherWork, otherRelease, err := other.Execution(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer otherRelease()
	if err := s.Forget(ctx, seg.Sequence, seg.Revision); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(work.Err(), context.Canceled) || otherWork.Err() != nil {
		t.Fatal("cancellation scope", work.Err(), otherWork.Err())
	}
	if _, err := lease.Append(ctx, "late", "voice", "active", original); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("late fragment accepted", err)
	}
	if err := lease.Finish(ctx, seg.Sequence, seg.Revision, "complete", original); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("late completion accepted", err)
	}
	if _, _, err := lease.ConsumeApproval(ctx, "chat", "s", "p", "b", []byte("new")); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("stale approval accepted", err)
	}
	if err := lease.CompleteApproval(ctx, r, "applied", []byte(`{"id":73}`)); err != nil {
		t.Fatal("dispatched receipt lost", err)
	}
	if _, err := s.Export(ctx, p.Epoch, -1, 1); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("stale export accepted", err)
	}
	p, err = s.Retention(ctx)
	if err != nil || p.Bytes != 0 || p.Segments != 0 {
		t.Fatal(p, err)
	}
	p.Enabled = false
	if err := s.Configure(ctx, p); err != nil {
		t.Fatal(err)
	}
	if err := s.Configure(ctx, p); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("stale policy accepted", err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(otherWork.Err(), context.Canceled) {
		t.Fatal("closing store did not cancel active execution", otherWork.Err())
	}
	db, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	s = scope(t, db, "alice", "team") // New capability must not silently re-enable retention.
	if _, _, _, err := s.Execution(ctx); !errors.Is(err, memory.ErrScope) {
		t.Fatal("disabled policy lost at restart", err)
	}
	p, err = s.Retention(ctx)
	if err != nil || p.Enabled {
		t.Fatal(p, err)
	}
	p.Enabled = true
	if err := s.Configure(ctx, p); err != nil {
		t.Fatal(err)
	}
	seg, err = s.Append(ctx, "fresh", "chat", "complete", original)
	if err != nil || seg.Sequence != 1 {
		t.Fatal(seg, err)
	}
	page, err = s.Export(ctx, p.Epoch+1, -1, 1)
	if err != nil || len(page) != 1 || page[0].Sequence != 1 {
		t.Fatal(page, err)
	}
	if err := s.ForgetAll(ctx, p.Epoch+1); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read(ctx, 1); !errors.Is(err, memory.ErrNotFound) {
		t.Fatal("forget all failed", err)
	}
	r, err = s.ReadReceipt(ctx, "chat", "s", "p", "a")
	if err != nil || r.State != "applied" {
		t.Fatal("forgot receipt tombstone", r, err)
	}
}
