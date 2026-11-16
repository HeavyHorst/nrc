package main

import (
	"context"
	"database/sql"
	"math"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestAvailabilityDurationsPauseLateArrivalAndRetirement(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "history.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { db.Close() }()
	base := time.Date(2026, 11, 15, 12, 58, 0, 0, time.UTC)
	snapshot := func(offset int64, state uint8, validFor int64) historySnapshot {
		at := base.Add(time.Duration(offset) * time.Second).UnixNano()
		return historySnapshot{"ops", p.MonitorSnapshotPage{MonitorState: p.MonitorState{MonitorID: 2, Revision: 3, Sequence: 1}, At: at, Horizon: int64(5 * time.Minute), Instances: []p.MonitorAvailability{
			{ID: 1, Identity: "host-a:/", State: state, ValidUntil: at + validFor*int64(time.Second)},
			{ID: 2, Identity: "host-b:/data", State: 2, ValidUntil: at},
		}}}
	}
	put := func(s historySnapshot) {
		t.Helper()
		if err := writeAvailability(ctx, db, s); err != nil {
			t.Fatal(err)
		}
	}
	first := snapshot(0, 0, 190)
	first.Instances[1].State = 0
	first.Instances[1].ValidUntil = first.At + int64(10*time.Second)
	put(first)
	put(snapshot(30, 1, 100))
	put(snapshot(50, 3, 200))
	put(snapshot(90, 2, 0))
	put(snapshot(130, 0, 40))
	retired := snapshot(200, 2, 0)
	retired.Instances = nil
	put(retired)
	maintain := func() {
		t.Helper()
		if err := maintainHistory(ctx, db, base.Add(220*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	maintain()
	maintain()
	maintain()
	check := func(up, down int64) {
		t.Helper()
		var healthy, failing, unknown, paused int64
		var uptime, coverage float64
		err := db.QueryRow(`SELECT sum(healthy_ns),sum(failing_ns),sum(unknown_ns),sum(paused_ns),
 sum(healthy_ns)::DOUBLE/nullif(sum(healthy_ns+failing_ns),0),
 sum(healthy_ns+failing_ns)::DOUBLE/nullif(sum(healthy_ns+failing_ns+unknown_ns),0)
 FROM uptime_summary WHERE resolution_ns=? AND identity='host-a:/'`, historyHour).Scan(&healthy, &failing, &unknown, &paused, &uptime, &coverage)
		if err != nil || healthy != up*int64(time.Second) || failing != down*int64(time.Second) || unknown != 70*int64(time.Second) || paused != 40*int64(time.Second) || math.Abs(uptime-float64(up)/90) > 1e-12 || coverage != 0.5625 {
			t.Fatalf("durations %d/%d/%d/%d uptime=%g coverage=%g: %v", healthy, failing, unknown, paused, uptime, coverage, err)
		}
	}
	check(70, 20)
	var up, down, unknown, paused int64
	if err = db.QueryRow(`SELECT healthy_ns,failing_ns,unknown_ns,paused_ns FROM uptime_buckets WHERE resolution_ns=? AND bucket_ns=? AND identity='host-a:/'`, historyFiveMinutes, time.Date(2026, 11, 15, 12, 55, 0, 0, time.UTC).UnixNano()).Scan(&up, &down, &unknown, &paused); err != nil || up != int64(30*time.Second) || down != int64(20*time.Second) || unknown != int64(30*time.Second) || paused != int64(40*time.Second) {
		t.Fatalf("UTC boundary %d/%d/%d/%d: %v", up, down, unknown, paused, err)
	}
	if err = db.QueryRow(`SELECT sum(healthy_ns),sum(unknown_ns) FROM uptime_buckets WHERE resolution_ns=? AND identity='host-b:/data'`, historyHour).Scan(&up, &unknown); err != nil || up != int64(10*time.Second) || unknown != int64(190*time.Second) {
		t.Fatalf("other instance %d/%d: %v", up, unknown, err)
	}
	late := snapshot(40, 0, 100)
	put(late)
	put(late)
	db.Close()
	db, err = openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	maintain()
	maintain()
	check(80, 10)
	// The same identity returns after a real gap in the complete instance set.
	returned := snapshot(250, 1, 20)
	returned.Sequence = 2
	returned.Instances = returned.Instances[:1]
	put(returned)
	if err = maintainHistory(ctx, db, base.Add(300*time.Second)); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow(`SELECT sum(healthy_ns),sum(failing_ns),sum(unknown_ns),sum(paused_ns)
 FROM uptime_buckets WHERE resolution_ns=? AND identity='host-a:/'`, historyHour).Scan(&up, &down, &unknown, &paused); err != nil || up != int64(80*time.Second) || down != int64(30*time.Second) || unknown != int64(100*time.Second) || paused != int64(40*time.Second) {
		t.Fatalf("reappearance %d/%d/%d/%d: %v", up, down, unknown, paused, err)
	}
}

func TestAvailabilityIdleGapAndExpiredPause(t *testing.T) {
	ctx := context.Background()
	db, err := openHistory(ctx, filepath.Join(t.TempDir(), "history.duckdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	base := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	s := historySnapshot{"ops", p.MonitorSnapshotPage{MonitorState: p.MonitorState{MonitorID: 2, Revision: 3}, At: base.UnixNano(), Horizon: int64(30 * time.Second), Instances: []p.MonitorAvailability{
		{ID: 1, Identity: "up", State: 0, ValidUntil: base.Add(30 * time.Second).UnixNano()},
		{ID: 2, Identity: "paused", State: 3, ValidUntil: base.Add(30 * time.Second).UnixNano()},
		{ID: 3, Identity: "unknown", State: 2, ValidUntil: base.UnixNano()},
	}}}
	if err = writeAvailability(ctx, db, s); err != nil {
		t.Fatal(err)
	}
	for _, seconds := range []int{30, 60, 90} {
		if err = maintainHistory(ctx, db, base.Add(time.Duration(seconds)*time.Second)); err != nil {
			t.Fatal(err)
		}
		var up, unknown int64
		var uptime, coverage sql.NullFloat64
		if err = db.QueryRow("SELECT healthy_ns,unknown_ns,uptime,coverage FROM uptime_summary WHERE resolution_ns=? AND identity='up'", historyHour).Scan(&up, &unknown, &uptime, &coverage); err != nil || up != int64(30*time.Second) || unknown != int64(time.Duration(seconds-30)*time.Second) || !uptime.Valid || uptime.Float64 != 1 || !coverage.Valid || math.Abs(coverage.Float64-30/float64(seconds)) > 1e-12 {
			t.Fatalf("idle %ds: %d/%d %+v/%+v %v", seconds, up, unknown, uptime, coverage, err)
		}
		if err = db.QueryRow("SELECT paused_ns,unknown_ns,uptime,coverage FROM uptime_summary WHERE resolution_ns=? AND identity='paused'", historyHour).Scan(&up, &unknown, &uptime, &coverage); err != nil || up != int64(30*time.Second) || unknown != int64(time.Duration(seconds-30)*time.Second) || uptime.Valid || coverage.Valid != (seconds > 30) || coverage.Valid && coverage.Float64 != 0 {
			t.Fatalf("pause %ds: %d/%d %+v/%+v %v", seconds, up, unknown, uptime, coverage, err)
		}
		if err = db.QueryRow("SELECT uptime,coverage FROM uptime_summary WHERE resolution_ns=? AND identity='unknown'", historyHour).Scan(&uptime, &coverage); err != nil || uptime.Valid || !coverage.Valid || coverage.Float64 != 0 {
			t.Fatalf("unknown %+v/%+v: %v", uptime, coverage, err)
		}
	}
}

func TestAvailabilityRetentionKeepsGapAnchorAndRollsBack(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "history.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { db.Close() }()
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	s := historySnapshot{"ops", p.MonitorSnapshotPage{MonitorState: p.MonitorState{MonitorID: 2, Revision: 3}, Horizon: int64(time.Minute)}}
	// Collector workers may finish out of order, even before the first rollup.
	for _, offset := range []time.Duration{48 * time.Hour, 10 * time.Second, 0} {
		s.At = base.Add(offset).UnixNano()
		s.Instances = []p.MonitorAvailability{{ID: 1, Identity: "disk", State: 0, ValidUntil: s.At + int64(time.Minute)}}
		if err = writeAvailability(ctx, db, s); err != nil {
			t.Fatal(err)
		}
	}
	// This failure happens after bucket replacement and progress updates.
	if _, err = db.Exec("ALTER TABLE uptime_states RENAME TO saved_uptime_states; CREATE VIEW uptime_states AS SELECT * FROM saved_uptime_states"); err != nil {
		t.Fatal(err)
	}
	if err = maintainHistory(ctx, db, base.Add(15*24*time.Hour)); err == nil {
		t.Fatal("expected cleanup failure")
	}
	var count int
	if err = db.QueryRow("SELECT count(*) FROM uptime_buckets").Scan(&count); err != nil || count != 0 {
		t.Fatalf("partial rollup %d: %v", count, err)
	}
	if _, err = db.Exec("DROP VIEW uptime_states; ALTER TABLE saved_uptime_states RENAME TO uptime_states"); err != nil {
		t.Fatal(err)
	}
	if err = maintainHistory(ctx, db, base.Add(15*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow("SELECT count(*) FROM uptime_snapshots").Scan(&count); err != nil || count != 2 {
		t.Fatalf("anchor count %d: %v", count, err)
	}
	var earliest int64
	if err = db.QueryRow("SELECT min(observed_at) FROM uptime_snapshots").Scan(&earliest); err != nil || earliest != base.Add(10*time.Second).UnixNano() {
		t.Fatalf("anchor %d: %v", earliest, err)
	}
	db.Close()
	db, err = openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if err = maintainHistory(ctx, db, base.Add(15*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	var healthy, unknown int64
	if err = db.QueryRow("SELECT healthy_ns,unknown_ns FROM uptime_buckets WHERE resolution_ns=? AND bucket_ns=?", historyHour, base.Add(time.Hour).UnixNano()).Scan(&healthy, &unknown); err != nil || healthy != 0 || unknown != historyHour {
		t.Fatalf("gap after cleanup %d/%d: %v", healthy, unknown, err)
	}
	s.At = base.UnixNano()
	s.Instances = nil
	if err = writeAvailability(ctx, db, s); err == nil {
		t.Fatal("expired snapshot resurrected")
	}
}

func TestAvailabilityCatchupWithLiveInputAndLateCorrectionAfterCleanup(t *testing.T) {
	ctx := context.Background()
	db, err := openHistory(ctx, filepath.Join(t.TempDir(), "history.duckdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	put := func(at time.Time, state uint8, lifetime time.Duration) {
		t.Helper()
		s := historySnapshot{"ops", p.MonitorSnapshotPage{MonitorState: p.MonitorState{MonitorID: 2, Revision: 3}, At: at.UnixNano(), Horizon: int64(time.Minute), Instances: []p.MonitorAvailability{{ID: 1, Identity: "disk", State: state, ValidUntil: at.Add(lifetime).UnixNano()}}}}
		if err := writeAvailability(ctx, db, s); err != nil {
			t.Fatal(err)
		}
	}
	put(base, 0, time.Minute)
	put(base.Add(10*time.Second), 1, 20*time.Second)
	now := base.Add(15 * 24 * time.Hour)
	// Each transaction advances one historical hour while new current snapshots
	// continue arriving every simulated minute. The frontier must catch up.
	drain := func(live bool) {
		t.Helper()
		for step := 0; step < 420; step++ {
			if live {
				now = now.Add(time.Minute)
				put(now, 0, time.Minute)
			}
			if err := maintainHistory(ctx, db, now); err != nil {
				t.Fatal(err)
			}
			var latest sql.NullInt64
			var pending int
			if err := db.QueryRow(`SELECT (SELECT max(bucket_ns) FROM uptime_buckets WHERE resolution_ns=?),
 (SELECT count(*) FROM uptime_dirty_hours)`, historyHour).Scan(&latest, &pending); err != nil {
				t.Fatal(err)
			}
			if pending == 0 && latest.Valid && latest.Int64 == now.Truncate(time.Hour).UnixNano() {
				t.Logf("caught up after %d transactions (live=%v)", step+1, live)
				return
			}
		}
		t.Fatal("historical hours were starved by current snapshots")
	}
	drain(true)
	var oldRows, anchors int
	if err := db.QueryRow(`SELECT count(*) FILTER(WHERE observed_at=?),count(*) FILTER(WHERE observed_at=?) FROM uptime_snapshots`, base.UnixNano(), base.Add(10*time.Second).UnixNano()).Scan(&oldRows, &anchors); err != nil || oldRows != 0 || anchors != 1 {
		t.Fatalf("cleanup/anchor %d/%d: %v", oldRows, anchors, err)
	}
	cutoff := now.Add(-14 * 24 * time.Hour).Truncate(time.Hour)
	// Capture every closed bucket before the raw cutoff, in both resolutions.
	older := func() map[[2]int64][4]int64 {
		t.Helper()
		rows, err := db.Query("SELECT resolution_ns,bucket_ns,healthy_ns,failing_ns,unknown_ns,paused_ns FROM uptime_buckets WHERE bucket_ns<? ORDER BY resolution_ns,bucket_ns", cutoff.UnixNano())
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		result := map[[2]int64][4]int64{}
		for rows.Next() {
			var key [2]int64
			var value [4]int64
			if err := rows.Scan(&key[0], &key[1], &value[0], &value[1], &value[2], &value[3]); err != nil {
				t.Fatal(err)
			}
			result[key] = value
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		return result
	}
	before := older()
	if got := before[[2]int64{historyHour, base.UnixNano()}]; got != [4]int64{int64(10 * time.Second), int64(20 * time.Second), int64(3570 * time.Second), 0} {
		t.Fatalf("oldest completed hour %v", got)
	}
	var healthy, unknown int64
	if err := db.QueryRow("SELECT healthy_ns,unknown_ns FROM uptime_buckets WHERE resolution_ns=? AND bucket_ns=?", historyHour, cutoff.UnixNano()).Scan(&healthy, &unknown); err != nil || healthy != 0 || unknown != historyHour {
		t.Fatalf("before correction %d/%d: %v", healthy, unknown, err)
	}
	put(cutoff.Add(time.Minute), 0, 20*time.Second)
	drain(false)
	if err := db.QueryRow("SELECT healthy_ns,unknown_ns FROM uptime_buckets WHERE resolution_ns=? AND bucket_ns=?", historyHour, cutoff.UnixNano()).Scan(&healthy, &unknown); err != nil || healthy != int64(20*time.Second) || unknown != int64(3580*time.Second) {
		t.Fatalf("late correction %d/%d: %v", healthy, unknown, err)
	}
	if !reflect.DeepEqual(before, older()) {
		t.Fatal("late correction changed completed buckets outside the retained raw window")
	}
}
