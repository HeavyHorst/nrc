package personalmemory

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

// Fault injection is local to a disposable SQLite database. Assertions use the
// public memory operations, including retrying the same idempotency key.
func TestFailedRunAcceptanceIsAtomic(t *testing.T) {
	for _, fault := range []string{"disk-full", "commit-failure"} {
		t.Run(fault, func(t *testing.T) {
			store, err := Open(filepath.Join(t.TempDir(), "private", "memory.db"))
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			s, err := store.Personal("alice", "team", true)
			if err != nil {
				t.Fatal(err)
			}
			ctx := t.Context()
			original := []Record{{Role: "user", Text: "preserved"}}
			if _, err := s.Append(ctx, "first", "chat", "complete", original); err != nil {
				t.Fatal(err)
			}
			if fault == "disk-full" {
				var pages int
				if err := store.db.QueryRow(`PRAGMA page_count`).Scan(&pages); err != nil {
					t.Fatal(err)
				}
				if _, err := store.db.Exec(fmt.Sprintf(`PRAGMA max_page_count=%d`, pages)); err != nil {
					t.Fatal(err)
				}
			} else {
				// Deferred FK validation runs at COMMIT, after all Append writes.
				_, err := store.db.Exec(`CREATE TABLE fault_parent(id INTEGER PRIMARY KEY);
CREATE TABLE fault_child(id INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED);
CREATE TRIGGER fault_commit AFTER INSERT ON nodes BEGIN INSERT INTO fault_child VALUES(1); END;`)
				if err != nil {
					t.Fatal(err)
				}
			}
			records := []Record{{Role: "user", Text: strings.Repeat("rollbacktoken ", 2000)}}
			_, _, err = s.BeginRun(ctx, "retry", "chat", []byte("request"), records)
			if err == nil {
				t.Fatal("fault did not reject append")
			}
			var sqliteErr *sqlite.Error
			if fault == "disk-full" && (!errors.As(err, &sqliteErr) || sqliteErr.Code() != sqlite3.SQLITE_FULL) {
				t.Fatal("wrong fault", err)
			}
			if fault == "commit-failure" && !strings.Contains(err.Error(), "FOREIGN KEY") {
				t.Fatal("wrong fault", err)
			}
			if fault == "disk-full" {
				_, err = store.db.Exec(`PRAGMA max_page_count=1073741823`)
			} else {
				_, err = store.db.Exec(`DROP TRIGGER fault_commit`)
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.Read(ctx, 1); !errors.Is(err, ErrNotFound) {
				t.Fatal("partial original", err)
			}
			if _, err := s.ReadRun(ctx, "chat", "retry"); !errors.Is(err, ErrNotFound) {
				t.Fatal("partial run", err)
			}
			ids, err := s.Search(ctx, "rollbacktoken", 5)
			if err != nil || len(ids) != 0 {
				t.Fatal("partial search entry", ids, err)
			}
			old, err := s.Read(ctx, 0)
			if err != nil || len(old.Records) != 1 || old.Records[0] != original[0] {
				t.Fatal("prior commit damaged", old, err)
			}
			run, created, err := s.BeginRun(ctx, "retry", "chat", []byte("request"), records)
			if err != nil || !created || run.Segment.Sequence != 1 {
				t.Fatal("failed transaction consumed key or sequence", run, err)
			}
			if err := s.Finish(ctx, run.Segment.Sequence, run.Segment.Revision, "complete", records); err != nil {
				t.Fatal(err)
			}
			for {
				ok, err := s.BuildNext(ctx, "fixture", func(_ context.Context, _ SummaryInput) (string, error) { return "summary", nil })
				if err != nil {
					t.Fatal(err)
				}
				if !ok {
					break
				}
			}
			view, err := s.View(ctx, 2048)
			if err != nil || !view.Complete {
				t.Fatal("tree damaged", view, err)
			}
		})
	}
}
