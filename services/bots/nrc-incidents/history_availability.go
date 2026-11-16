package main

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"math"
	"sync"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

type historySnapshot struct {
	Workspace string
	p.MonitorSnapshotPage
}

func (h *historyWriter) requestAvailability(state p.MonitorState) {
	state.CorrelationID = 1
	select {
	case h.availability <- state:
	default:
		h.dropped.Add(1)
		slog.Warn("history gap: availability requests full", "monitor_id", state.MonitorID)
	}
}

// Read-only collection has its own workers; slow history requests never hold a
// check worker, delay its submission, or publish a partial instance snapshot.
func collectAvailability(ctx context.Context, h *historyWriter, source interface {
	snapshot(context.Context, p.MonitorState) (p.MonitorSnapshotPage, error)
}, workspace string, workers int) {
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case state := <-h.availability:
					readCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
					page, err := source.snapshot(readCtx, state)
					cancel()
					if err == nil {
						select {
						case h.snapshots <- historySnapshot{workspace, page}:
							continue
						default:
						}
					}
					h.dropped.Add(1)
					slog.Warn("history gap: availability snapshot unavailable", "monitor_id", state.MonitorID)
				}
			}
		}()
	}
	wg.Wait()
}

const historyAvailabilitySchema = `
CREATE TABLE IF NOT EXISTS uptime_snapshots (
 workspace VARCHAR, monitor_id UBIGINT, observed_at BIGINT, revision BIGINT, sequence UBIGINT,
 PRIMARY KEY(workspace,monitor_id,observed_at));
CREATE TABLE IF NOT EXISTS uptime_states (
 workspace VARCHAR, monitor_id UBIGINT, observed_at BIGINT, identity VARCHAR, state UTINYINT, valid_until BIGINT);
CREATE TABLE IF NOT EXISTS uptime_dirty_hours (hour_ns BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS uptime_buckets (
 resolution_ns BIGINT,bucket_ns BIGINT,workspace VARCHAR,monitor_id UBIGINT,revision BIGINT,identity VARCHAR,
 healthy_ns BIGINT,failing_ns BIGINT,unknown_ns BIGINT,paused_ns BIGINT);
CREATE OR REPLACE VIEW uptime_summary AS SELECT *,
 healthy_ns::DOUBLE/nullif(healthy_ns+failing_ns,0) uptime,
 (healthy_ns+failing_ns)::DOUBLE/nullif(healthy_ns+failing_ns+unknown_ns,0) coverage
 FROM uptime_buckets;
INSERT INTO history_meta VALUES ('uptime_tail',0),('uptime_now',0) ON CONFLICT DO NOTHING;
`

func writeAvailability(ctx context.Context, db *sql.DB, s historySnapshot) error {
	if s.Workspace == "" || s.MonitorID == 0 || s.Revision <= 0 || s.At <= 0 || s.Horizon <= 0 || s.At > math.MaxInt64-s.Horizon || s.Next != 0 {
		return errors.New("invalid availability snapshot")
	}
	seen := map[string]bool{}
	bytes := 0
	for _, r := range s.Instances {
		bytes += len(r.Identity) + 19
		if len(r.Identity) == 0 || len(r.Identity) > 4096 || seen[r.Identity] || r.State > 3 || r.ValidUntil < s.At || r.ValidUntil > s.At+s.Horizon || r.State == 2 && r.ValidUntil != s.At || bytes > 4<<20 {
			return errors.New("invalid availability instance")
		}
		seen[r.Identity] = true
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var floor, through int64
	if err = tx.QueryRowContext(ctx, "SELECT (SELECT value FROM history_meta WHERE key='raw_floor'),(SELECT value FROM history_meta WHERE key='uptime_now')").Scan(&floor, &through); err != nil {
		return err
	}
	if s.At < floor {
		return errors.New("availability snapshot predates retained raw window")
	}
	var exists bool
	if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM uptime_snapshots WHERE workspace=? AND monitor_id=? AND observed_at=?)", s.Workspace, s.MonitorID, s.At).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return tx.Commit()
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO uptime_snapshots VALUES(?,?,?,?,?)", s.Workspace, s.MonitorID, s.At, s.Revision, s.Sequence); err != nil {
		return err
	}
	for _, r := range s.Instances {
		if _, err = tx.ExecContext(ctx, "INSERT INTO uptime_states VALUES(?,?,?,?,?,?)", s.Workspace, s.MonitorID, s.At, r.Identity, r.State, r.ValidUntil); err != nil {
			return err
		}
	}
	hour := s.At / historyHour * historyHour
	// An out-of-order complete snapshot can change every subsequent interval up
	// to the already aggregated frontier, never an interval preceding its time.
	if _, err = tx.ExecContext(ctx, `INSERT INTO uptime_dirty_hours SELECT range FROM range(?,?,?) ON CONFLICT DO NOTHING`, hour, max(hour, through/historyHour*historyHour)+historyHour, historyHour); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE history_meta SET value=CASE WHEN value=0 THEN ? ELSE least(value,?) END WHERE key='uptime_tail'", hour, hour); err != nil {
		return err
	}
	return tx.Commit()
}

func maintainAvailability(ctx context.Context, tx *sql.Tx, now, rawFloor, fiveFloor, hourFloor int64) error {
	var tail int64
	if err := tx.QueryRowContext(ctx, "SELECT value FROM history_meta WHERE key='uptime_tail'").Scan(&tail); err != nil {
		return err
	}
	if tail == 0 {
		return nil
	}
	nowHour := now / historyHour * historyHour
	// After downtime, schedule at most 24 additional hours per transaction.
	if tail <= nowHour {
		through := min(nowHour, tail+23*historyHour)
		if _, err := tx.ExecContext(ctx, "INSERT INTO uptime_dirty_hours SELECT range FROM range(?,?,?) ON CONFLICT DO NOTHING", tail, through+historyHour, historyHour); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE history_meta SET value=? WHERE key='uptime_tail'", through); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, "UPDATE history_meta SET value=greatest(value,?) WHERE key='uptime_now'", now); err != nil {
		return err
	}
	var hour sql.NullInt64
	if err := tx.QueryRowContext(ctx, "SELECT min(hour_ns) FROM uptime_dirty_hours WHERE hour_ns<=?", nowHour).Scan(&hour); err != nil {
		return err
	}
	if hour.Valid {
		if err := aggregateAvailabilityHour(ctx, tx, hour.Int64, now, fiveFloor, hourFloor); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM uptime_dirty_hours WHERE hour_ns=?", hour.Int64); err != nil {
			return err
		}
	}
	// Keep the latest snapshot before the cleanup frontier as a per-monitor
	// anchor. An outage then remains unknown, instead of disappearing from coverage.
	_, err := tx.ExecContext(ctx, `CREATE OR REPLACE TEMP TABLE uptime_expired AS
 WITH cutoff AS (SELECT least(?,(SELECT value FROM history_meta WHERE key='uptime_tail'),
 coalesce((SELECT min(hour_ns) FROM uptime_dirty_hours),?)) boundary), anchors AS (
 SELECT workspace,monitor_id,max(observed_at) observed_at FROM uptime_snapshots,cutoff
 WHERE observed_at<=boundary GROUP BY workspace,monitor_id), candidates AS (
 SELECT s.* FROM uptime_snapshots s JOIN anchors a USING(workspace,monitor_id)
 WHERE s.observed_at<a.observed_at)
 SELECT * FROM candidates WHERE observed_at // ? = (SELECT min(observed_at // ?) FROM candidates)`, rawFloor, rawFloor, historyHour, historyHour)
	if err != nil {
		return err
	}
	for _, table := range []string{"uptime_states", "uptime_snapshots"} {
		if _, err = tx.ExecContext(ctx, "DELETE FROM "+table+" s USING uptime_expired e WHERE s.workspace=e.workspace AND s.monitor_id=e.monitor_id AND s.observed_at=e.observed_at"); err != nil {
			return err
		}
	}
	return nil
}

func aggregateAvailabilityHour(ctx context.Context, tx *sql.Tx, hour, now, fiveFloor, hourFloor int64) error {
	_, err := tx.ExecContext(ctx, `CREATE OR REPLACE TEMP TABLE uptime_stage AS
 WITH points AS (
 SELECT workspace,monitor_id,max(observed_at) observed_at,arg_max(revision,observed_at) revision
 FROM uptime_snapshots WHERE observed_at<? GROUP BY workspace,monitor_id
 UNION ALL SELECT workspace,monitor_id,observed_at,revision
 FROM uptime_snapshots WHERE observed_at>=? AND observed_at<?), timeline AS (
 SELECT *,lead(observed_at,1,?) OVER(PARTITION BY workspace,monitor_id ORDER BY observed_at) next_at
 FROM points), segments AS (
 SELECT t.workspace,t.monitor_id,t.revision,s.identity,s.state,s.valid_until,
 greatest(t.observed_at,?) start_at,least(t.next_at,?,?) end_at
 FROM timeline t JOIN uptime_states s USING(workspace,monitor_id,observed_at)
 WHERE t.next_at>? AND t.observed_at<?), pieces AS (
 SELECT segments.*,b.range bucket_start,greatest(start_at,b.range) lo,least(end_at,b.range+?) hi
 FROM segments,range(?,?,?) b WHERE start_at<b.range+? AND end_at>b.range)
 SELECT ?::BIGINT resolution_ns,bucket_start bucket_ns,workspace,monitor_id,revision,identity,
 sum(CASE WHEN state=0 THEN greatest(0,least(hi,valid_until)-lo) ELSE 0 END)::BIGINT healthy_ns,
 sum(CASE WHEN state=1 THEN greatest(0,least(hi,valid_until)-lo) ELSE 0 END)::BIGINT failing_ns,
 sum(CASE WHEN state=2 THEN hi-lo ELSE hi-greatest(lo,least(hi,valid_until)) END)::BIGINT unknown_ns,
 sum(CASE WHEN state=3 THEN greatest(0,least(hi,valid_until)-lo) ELSE 0 END)::BIGINT paused_ns
 FROM pieces WHERE hi>lo GROUP BY ALL`,
		hour, hour, hour+historyHour, now, hour, hour+historyHour, now, hour, hour+historyHour,
		historyFiveMinutes, hour, hour+historyHour, historyFiveMinutes, historyFiveMinutes, historyFiveMinutes)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM uptime_buckets WHERE bucket_ns>=? AND bucket_ns<?", hour, hour+historyHour); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO uptime_buckets SELECT * FROM uptime_stage WHERE bucket_ns>=?", fiveFloor); err != nil {
		return err
	}
	if hour >= hourFloor {
		_, err = tx.ExecContext(ctx, `INSERT INTO uptime_buckets SELECT ?::BIGINT,?::BIGINT,workspace,monitor_id,revision,identity,
 sum(healthy_ns),sum(failing_ns),sum(unknown_ns),sum(paused_ns)
 FROM uptime_stage GROUP BY workspace,monitor_id,revision,identity`, historyHour, hour)
	}
	return err
}
