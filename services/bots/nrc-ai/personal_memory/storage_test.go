package personalmemory_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"

	memory "nrc-ai/personal_memory"
)

func TestChangesScopedDurableAndRunIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { store.Close() }()
	a := scope(t, store, "a", "one")
	b := scope(t, store, "b", "one")
	c := scope(t, store, "a", "two")
	previous, err := a.Changes(t.Context())
	if err != nil || !previous.Enabled {
		t.Fatalf("initial: %+v %v", previous, err)
	}
	changed := func() {
		t.Helper()
		next, err := a.Changes(t.Context())
		if err != nil || next.Revision <= previous.Revision {
			t.Fatalf("not changed: %+v -> %+v: %v", previous, next, err)
		}
		previous = next
		for _, other := range []*memory.Scope{b, c} {
			value, err := other.Changes(t.Context())
			if err != nil || value.Revision != 0 {
				t.Fatalf("cross-scope signal: %+v %v", value, err)
			}
		}
	}
	run, created, err := a.BeginRun(t.Context(), "run-one", "chat", []byte("request"), []memory.Record{{Role: "user", Text: "hello"}})
	if err != nil || !created {
		t.Fatal(err)
	}
	changed()
	read, err := a.Read(t.Context(), run.Segment.Sequence)
	if err != nil || read.RunID != "run-one" {
		t.Fatalf("run identity: %+v %v", read, err)
	}
	history, err := a.History(t.Context(), previous.Epoch, -1, 10)
	if err != nil || len(history) != 1 || history[0].RunID != "run-one" {
		t.Fatalf("history run identity: %+v %v", history, err)
	}
	if err := a.Finish(t.Context(), read.Sequence, read.Revision, "complete", read.Records); err != nil {
		t.Fatal(err)
	}
	changed()
	build(t, a)
	afterBuild, _ := a.Changes(t.Context())
	if afterBuild != previous {
		t.Fatal("summary invalidated UI")
	}
	r, created, err := a.ConsumeApproval(t.Context(), "chat", "s", "p", "a", []byte("proposal"))
	if err != nil || !created {
		t.Fatal(err)
	}
	changed()
	if err := a.CompleteApproval(t.Context(), r, "applied", json.RawMessage(`{"id":1}`)); err != nil {
		t.Fatal(err)
	}
	changed()
	if _, created, err := a.ConsumeApproval(t.Context(), "chat", "s", "p", "a", []byte("proposal")); err != nil || created {
		t.Fatal("approval replay")
	}
	unchanged, _ := a.Changes(t.Context())
	if unchanged != previous {
		t.Fatal("retry invalidated UI")
	}
	voice, err := a.Append(t.Context(), "voice", "voice", "active", []memory.Record{{Role: "user", Text: "voice"}})
	if err != nil {
		t.Fatal(err)
	}
	changed()
	voiceRead, err := a.Read(t.Context(), voice.Sequence)
	if err != nil || voiceRead.RunID != "" {
		t.Fatal("raw capture exposed run id")
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	a = scope(t, store, "a", "one")
	b = scope(t, store, "b", "one")
	c = scope(t, store, "a", "two")
	changed() // active -> incomplete recovery is visible.
	if err := a.Forget(t.Context(), read.Sequence, read.Revision+1); err != nil {
		t.Fatal(err)
	}
	changed()
	if err := a.Configure(t.Context(), memory.Retention{Epoch: previous.Epoch, Enabled: false}); err != nil {
		t.Fatal(err)
	}
	changed()
	if previous.Enabled {
		t.Fatal("disablement not coherent")
	}
	if err := a.ForgetAll(t.Context(), previous.Epoch); err != nil {
		t.Fatal(err)
	}
	changed()
}

func TestChangesMigratesExistingPolicy(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "memory.db")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE retention(owner TEXT,workspace TEXT,epoch INTEGER NOT NULL DEFAULT 0,enabled INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(owner,workspace)); INSERT INTO retention VALUES('a','w',7,0)`)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	s, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	a := scope(t, s, "a", "w")
	change, err := a.Changes(t.Context())
	if err != nil || change.Epoch != 7 || change.Enabled || change.Revision != 0 {
		t.Fatalf("migration: %+v %v", change, err)
	}
}

func storageCommand(t *testing.T, success bool, args ...string) {
	t.Helper()
	// Call main directly so failures in disposable fixtures retain a traceback;
	// the operator CLI deliberately suppresses paths and SQLite error text.
	cmd := exec.CommandContext(t.Context(), "python3", append([]string{"-c", "import runpy; runpy.run_path('storage_ops.py')['main']()"}, args...)...)
	output, err := cmd.CombinedOutput()
	if (err == nil) != success {
		t.Fatalf("storage %v: %s %v", args, output, err)
	}
}

func TestStorageSnapshotConcurrentCaptureRestoreSafety(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 required for offline restore drill")
	}
	dir := filepath.Join(t.TempDir(), "private")
	path := filepath.Join(dir, "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	a := scope(t, store, "a", "w")
	forgotten, err := a.Append(t.Context(), "old", "chat", "complete", []memory.Record{{Role: "user", Text: "forgetmeunique"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := a.ConsumeApproval(t.Context(), "chat", "s", "p", "before", []byte("before")); err != nil {
		t.Fatal(err)
	}
	b := scope(t, store, "b", "w")
	if _, _, err := b.BeginRun(t.Context(), "run-before", "chat", []byte("request"), []memory.Record{{Role: "user", Text: "forgetallunique"}}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 30; i++ {
			if _, err := a.Append(t.Context(), fmt.Sprint(i), "voice", "complete", []memory.Record{{Role: "user", Text: "keep"}}); err != nil {
				t.Error(err)
				return
			}
			if _, err := store.Maintain(t.Context(), true); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	backup := filepath.Join(dir, "backup.db")
	storageCommand(t, true, "snapshot", path, backup)
	wg.Wait()
	if err := a.Forget(t.Context(), forgotten.Sequence, forgotten.Revision); err != nil {
		t.Fatal(err)
	}
	if err := b.ForgetAll(t.Context(), 0); err != nil {
		t.Fatal(err)
	}
	if _, _, err := a.ConsumeApproval(t.Context(), "chat", "s", "p", "after", []byte("after")); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "restored.db")
	storageCommand(t, false, "restore", backup, path, out, "--confirm-latest-safety") // live owner lock
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	storageCommand(t, false, "restore", path, backup, out, "--confirm-latest-safety") // stale safety source
	storageCommand(t, true, "restore", backup, path, out, "--confirm-latest-safety")
	storageCommand(t, true, "verify", out)
	storageCommand(t, false, "snapshot", path, out) // no overwrite
	info, err := os.Stat(out)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("restore permissions")
	}
	restored, err := memory.Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	a = scope(t, restored, "a", "w")
	if _, err := a.Read(t.Context(), forgotten.Sequence); !errors.Is(err, memory.ErrNotFound) {
		t.Fatalf("resurrection: %v", err)
	}
	ids, err := a.Search(t.Context(), "forgetmeunique", 10)
	if err != nil || len(ids) != 0 {
		t.Fatalf("FTS resurrection: %v %v", ids, err)
	}
	for _, action := range []string{"before", "after"} {
		if _, created, err := a.ConsumeApproval(t.Context(), "chat", "s", "p", action, []byte(action)); err != nil || created {
			t.Fatalf("receipt replay %s: %v", action, err)
		}
	}
	policy, err := a.Changes(t.Context())
	if err != nil || policy.Enabled {
		t.Fatal("restore must disable retention")
	}
	b = scope(t, restored, "b", "w")
	if _, created, err := b.BeginRun(t.Context(), "run-before", "chat", []byte("request"), []memory.Record{{Role: "user", Text: "forgetallunique"}}); created || !errors.Is(err, memory.ErrNotFound) {
		t.Fatalf("forgotten run replay: %v %v", created, err)
	}
	if err := a.Configure(t.Context(), memory.Retention{Enabled: true, Epoch: policy.Epoch}); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Append(t.Context(), "after-restore", "chat", "complete", []memory.Record{{Role: "user", Text: "new"}}); err != nil {
		t.Fatal(err)
	}
	build(t, a)
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	go func() { defer close(done); restored.RunMaintenance(ctx) }()
	cancel()
	<-done
}

func TestMaintenanceCompactsWithoutDeletingRecordsOrGuards(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "memory.db")
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	a := scope(t, store, "a", "w")
	segment, err := a.Append(t.Context(), "keep", "chat", "complete", []memory.Record{{Role: "user", Text: "original"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := a.ConsumeApproval(t.Context(), "chat", "s", "p", "a", []byte("proposal")); err != nil {
		t.Fatal(err)
	}
	// Construct free pages without generating 64 MiB of retained user data.
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE disposable_padding(body BLOB); INSERT INTO disposable_padding VALUES(zeroblob(70*1024*1024)); DROP TABLE disposable_padding`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	status, err := store.Maintain(t.Context(), true)
	if err != nil {
		t.Fatal(err)
	}
	if status.LowSpace {
		t.Skip("filesystem lacks compaction headroom")
	}
	if !status.Compacted {
		t.Fatalf("compaction did not run: %+v", status)
	}
	info, err := os.Stat(path)
	if err != nil || info.Size() >= status.DatabaseBytes {
		t.Fatalf("database did not shrink: %+v %v", status, err)
	}
	if _, err := a.Read(t.Context(), segment.Sequence); err != nil {
		t.Fatal(err)
	}
	if _, created, err := a.ConsumeApproval(t.Context(), "chat", "s", "p", "a", []byte("proposal")); err != nil || created {
		t.Fatal("compaction lost approval guard")
	}
}
