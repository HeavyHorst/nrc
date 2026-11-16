package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestHistoryPersistsAcceptanceAndMultipleInstances(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "history.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	var version string
	if err = db.QueryRow("SELECT version()").Scan(&version); err != nil || !strings.HasPrefix(version, "v2.0.") {
		t.Fatalf("DuckDB %s: %v", version, err)
	}
	t.Log("real DuckDB", version)
	r := historyRun{ID: "attempt1", Workspace: "test", Acceptance: "unknown", ObservedAt: 123, Duration: 456, Run: p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 4, Observations: []p.MonitorObservation{{Identity: "host-a:/", Condition: 1, Value: 97.5}, {Identity: "host-b:/data", Condition: 0, Value: 21.25}}}}
	if err = writeHistory(ctx, db, r); err != nil {
		t.Fatal(err)
	}
	if err = writeHistory(ctx, db, r); err != nil {
		t.Fatal(err)
	}
	bad := r
	bad.ID = "bad"
	bad.Acceptance = "invalid"
	if err = writeHistory(ctx, db, bad); err == nil {
		t.Fatal("invalid acceptance stored")
	}
	db.Close()
	db, err = openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count int
	var value float64
	var acceptance string
	if err = db.QueryRow("SELECT count(*) FROM runs").Scan(&count); err != nil || count != 1 {
		t.Fatalf("runs %d %v", count, err)
	}
	if err = db.QueryRow("SELECT count(*),sum(value) FROM samples").Scan(&count, &value); err != nil || count != 2 || value != 118.75 {
		t.Fatalf("samples %d %v %v", count, value, err)
	}
	if err = db.QueryRow("SELECT acceptance FROM runs").Scan(&acceptance); err != nil || acceptance != "unknown" {
		t.Fatalf("acceptance %s %v", acceptance, err)
	}
}

func TestHistoryBacklogDoesNotBlock(t *testing.T) {
	h := newHistoryWriter()
	for i := 0; i < 257; i++ {
		h.offer(historyRun{})
	}
	if h.dropped.Load() != 1 || len(h.queue) != 256 {
		t.Fatal("incorrect bounded overflow")
	}
}

func TestHistoryRollupsLateArrivalsAndDimensions(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "history.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { db.Close() }()
	base := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	makeRun := func(id string, offset time.Duration, value float64, condition uint8) historyRun {
		return historyRun{ID: id, Workspace: "ops", Acceptance: "confirmed", ObservedAt: base.Add(offset).UnixNano(), Duration: 1,
			Run: p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 1,
				Observations: []p.MonitorObservation{{Identity: "host-a:/", Condition: condition, Value: value}}}}
	}
	put := func(r historyRun) {
		t.Helper()
		if err := writeHistory(ctx, db, r); err != nil {
			t.Fatal(err)
		}
	}
	maintain := func() {
		t.Helper()
		if err := maintainHistory(ctx, db, base.Add(24*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	first := makeRun("a", 5*time.Minute-time.Nanosecond, 2, 0)
	first.Run.Observations = append(first.Run.Observations, p.MonitorObservation{Identity: "host-b:/data", Value: 600})
	put(first)
	second := makeRun("b", time.Minute, 4, 1)
	second.Duration = 2
	put(second)
	third := makeRun("c", 5*time.Minute, 30, 2)
	third.Duration = 3
	put(third)
	put(makeRun("next-hour", time.Hour, 99, 1))
	for _, dim := range []string{"workspace", "monitor", "revision", "unknown", "rejected"} {
		r := makeRun(dim, time.Minute, 100, 1)
		switch dim {
		case "workspace":
			r.Workspace = "elsewhere"
		case "monitor":
			r.Run.MonitorID = 9
		case "revision":
			r.Run.Revision = 8
		default:
			r.Acceptance = dim
		}
		put(r)
	}
	failed := makeRun("failed", 6*time.Minute, 0, 0)
	failed.Run.Observations = nil
	failed.Run.Failed = true
	failed.Duration = 7
	put(failed)
	empty := makeRun("empty", 7*time.Minute, 0, 0)
	empty.Run.Observations = nil
	empty.Duration = 11
	put(empty)
	maintain()
	maintain()
	maintain()
	var count, pass, fail, between, lastAt int64
	var sum, min, max, last float64
	check := func(wantCount int64, wantSum, wantLast float64, wantPass int64) {
		t.Helper()
		err := db.QueryRow(`SELECT value_count,sum_value,min_value,max_value,last_value,last_at,passing_count,failing_count,between_count
 FROM sample_buckets WHERE resolution_ns=? AND bucket_ns=? AND workspace='ops' AND monitor_id=2 AND revision=3 AND acceptance='confirmed' AND identity='host-a:/'`, historyHour, base.UnixNano()).Scan(&count, &sum, &min, &max, &last, &lastAt, &pass, &fail, &between)
		if err != nil || count != wantCount || sum != wantSum || min != 2 || max != wantLast || last != wantLast || lastAt != base.Add(5*time.Minute).UnixNano() || pass != wantPass || fail != 1 || between != 1 {
			t.Fatalf("hour count=%d sum=%g min/max=%g/%g last=%g@%d counts=%d/%d/%d: %v", count, sum, min, max, last, lastAt, pass, fail, between, err)
		}
	}
	check(3, 36, 30, 1) // 12, not the unweighted bucket mean of 16.5.
	if err = db.QueryRow("SELECT count(*) FROM sample_buckets WHERE resolution_ns=? AND bucket_ns=?", historyHour, base.UnixNano()).Scan(&count); err != nil || count != 7 {
		t.Fatalf("dimensions %d: %v", count, err)
	}
	if err = db.QueryRow(`SELECT value_count,sum_value FROM sample_buckets WHERE resolution_ns=? AND bucket_ns=? AND workspace='ops' AND monitor_id=2 AND revision=3 AND acceptance='confirmed' AND identity='host-a:/'`, historyFiveMinutes, base.UnixNano()).Scan(&count, &sum); err != nil || count != 2 || sum != 6 {
		t.Fatalf("5m boundary: %d %g %v", count, sum, err)
	}
	var runs, failedCount, durationSum, durationMax int64
	if err = db.QueryRow(`SELECT run_count,failed_count,duration_sum_ns::BIGINT,duration_max_ns FROM run_buckets WHERE resolution_ns=? AND bucket_ns=? AND workspace='ops' AND monitor_id=2 AND revision=3 AND acceptance='confirmed'`, historyHour, base.UnixNano()).Scan(&runs, &failedCount, &durationSum, &durationMax); err != nil || runs != 5 || failedCount != 1 || durationSum != 24 || durationMax != 11 {
		t.Fatalf("runs %d/%d duration %d/%d: %v", runs, failedCount, durationSum, durationMax, err)
	}
	late := makeRun("late", 2*time.Minute, 10, 0)
	put(late)
	put(late)
	maintain()
	check(4, 46, 30, 2)
	// Equal timestamp ordering is deterministic across restart and insertion order.
	put(makeRun("z-late", 5*time.Minute, 50, 0))
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	maintain()
	maintain()
	check(5, 96, 50, 3)
}

func TestHistoryRetentionBoundariesAndCalendarMonths(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "history.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { db.Close() }()
	base := time.Date(2025, 2, 28, 12, 0, 0, 0, time.UTC)
	r := historyRun{ID: "one", Workspace: "ops", Acceptance: "confirmed", ObservedAt: base.UnixNano(), Run: p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 1, Observations: []p.MonitorObservation{{Identity: "disk", Value: 17}}}}
	if err = writeHistory(ctx, db, r); err != nil {
		t.Fatal(err)
	}
	maintain := func(now time.Time) {
		t.Helper()
		if err := maintainHistory(ctx, db, now); err != nil {
			t.Fatal(err)
		}
	}
	check := func(raw, five, hour int) {
		t.Helper()
		for _, q := range []struct {
			sql  string
			want int
		}{
			{"SELECT count(*) FROM runs", raw}, {"SELECT count(*) FROM samples", raw},
			{"SELECT count(*) FROM sample_buckets WHERE resolution_ns=300000000000", five},
			{"SELECT count(*) FROM run_buckets WHERE resolution_ns=300000000000", five},
			{"SELECT count(*) FROM sample_buckets WHERE resolution_ns=3600000000000", hour},
			{"SELECT count(*) FROM run_buckets WHERE resolution_ns=3600000000000", hour},
		} {
			var n int
			if err := db.QueryRow(q.sql).Scan(&n); err != nil || n != q.want {
				t.Fatalf("%s: %d want %d: %v", q.sql, n, q.want, err)
			}
		}
	}
	// Whole UTC hours keep the boundary bucket, then aggregate before raw deletion.
	maintain(base.Add(14 * 24 * time.Hour))
	check(1, 1, 1)
	maintain(base.Add(14*24*time.Hour + time.Hour))
	check(0, 1, 1)
	db.Close()
	db, err = openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if err = writeHistory(ctx, db, r); err == nil {
		t.Fatal("expired run resurrected after restart")
	}
	maintain(base.Add(90 * 24 * time.Hour))
	check(0, 1, 1)
	maintain(base.Add(90*24*time.Hour + 5*time.Minute))
	check(0, 0, 1)
	// March 31 minus 13 calendar months clamps to February 28, not March 3
	// (Go AddDate normalization) or an approximation of 390 days.
	maintain(time.Date(2026, 3, 31, 12, 0, 0, 0, time.UTC))
	check(0, 0, 1)
	maintain(time.Date(2026, 3, 31, 13, 0, 0, 0, time.UTC))
	check(0, 0, 0)
}

func TestHistoryMaintenanceRollbackAndBoundedBacklog(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "history.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { db.Close() }()
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	r := historyRun{ID: "first", Workspace: "ops", Acceptance: "confirmed", ObservedAt: base.UnixNano(), Run: p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 1, Observations: []p.MonitorObservation{{Identity: "disk", Value: 17}}}}
	if err = writeHistory(ctx, db, r); err != nil {
		t.Fatal(err)
	}
	r.ID = "second"
	r.ObservedAt += historyHour
	if err = writeHistory(ctx, db, r); err != nil {
		t.Fatal(err)
	}
	// Reopen the previous raw-only schema: existing hours must be adopted.
	if _, err = db.Exec("DROP TABLE history_meta; DROP TABLE history_dirty_hours; DROP TABLE sample_buckets; DROP TABLE run_buckets"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	// Fail after aggregation, cleanup and watermark updates have started.
	if _, err = db.Exec("ALTER TABLE samples RENAME TO saved_samples; CREATE VIEW samples AS SELECT * FROM saved_samples"); err != nil {
		t.Fatal(err)
	}
	if err = maintainHistory(ctx, db, base.Add(15*24*time.Hour)); err == nil {
		t.Fatal("expected nonwritable raw table failure")
	}
	var raw, dirty, buckets, floor int
	if err = db.QueryRow(`SELECT (SELECT count(*) FROM runs),(SELECT count(*) FROM history_dirty_hours),(SELECT count(*) FROM sample_buckets),(SELECT value FROM history_meta WHERE key='raw_floor')`).Scan(&raw, &dirty, &buckets, &floor); err != nil || raw != 2 || dirty != 2 || buckets != 0 || floor != 0 {
		t.Fatalf("rollback %d/%d/%d/%d: %v", raw, dirty, buckets, floor, err)
	}
	if _, err = db.Exec("DROP VIEW samples; ALTER TABLE saved_samples RENAME TO samples"); err != nil {
		t.Fatal(err)
	}
	if err = maintainHistory(ctx, db, base.Add(15*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow(`SELECT (SELECT count(*) FROM runs),(SELECT count(*) FROM history_dirty_hours),(SELECT count(*) FROM sample_buckets WHERE resolution_ns=3600000000000)`).Scan(&raw, &dirty, &buckets); err != nil || raw != 1 || dirty != 1 || buckets != 1 {
		t.Fatalf("first batch %d/%d/%d: %v", raw, dirty, buckets, err)
	}
	if err = maintainHistory(ctx, db, base.Add(15*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow(`SELECT (SELECT count(*) FROM runs),(SELECT count(*) FROM history_dirty_hours),(SELECT count(*) FROM sample_buckets WHERE resolution_ns=3600000000000)`).Scan(&raw, &dirty, &buckets); err != nil || raw != 0 || dirty != 0 || buckets != 2 {
		t.Fatalf("second batch %d/%d/%d: %v", raw, dirty, buckets, err)
	}
}

func TestHistoryWriterMaintainsExistingDataWhileIdle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "history.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	r := historyRun{ID: "old", Workspace: "ops", Acceptance: "confirmed", ObservedAt: time.Now().Add(-15 * 24 * time.Hour).UnixNano(), Run: p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 1, Observations: []p.MonitorObservation{{Identity: "disk", Value: 17}}}}
	if err = writeHistory(ctx, db, r); err != nil {
		db.Close()
		t.Fatal(err)
	}
	db.Close()
	h := newHistoryWriter()
	done := make(chan struct{})
	go func() { defer close(done); h.serve(ctx, path) }()
	defer func() { cancel(); <-done }()
	reader, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		var raw, aggregate int
		if err = reader.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM runs),(SELECT count(*) FROM sample_buckets)").Scan(&raw, &aggregate); err != nil {
			t.Fatal(err)
		}
		if raw == 0 && aggregate == 2 {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal("idle writer did not aggregate and expire existing data")
		case <-tick.C:
		}
	}
}
