package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"strconv"
	"sync/atomic"
	"time"

	_ "github.com/duckdb/duckdb-go/v2"
	p "github.com/heavyhorst/nrc/protocol-go"
)

type historyRun struct {
	ID, Workspace, Acceptance string
	Run                       p.ApplyMonitorRun
	ObservedAt                int64
	Duration                  int64
	Diagnostics               *checkDiagnostics
}

// Raw runs use a disposable handoff. Availability snapshots remain in NRC's
// durable outbox until this writer reports a successful DuckDB commit.
type historyWriter struct {
	queue     chan historyRun
	snapshots chan historySnapshot
	dropped   atomic.Uint64
	db        atomic.Pointer[sql.DB]

	availabilityReadFailures  atomic.Uint64
	availabilityWriteFailures atomic.Uint64
	availabilityWaits         atomic.Uint64
	availabilityWaitNS        atomic.Uint64
}

func newHistoryWriter() *historyWriter {
	return &historyWriter{queue: make(chan historyRun, 256), snapshots: make(chan historySnapshot, 8)}
}

// Process-local diagnostics, not a completeness watermark or per-monitor counts.
func (h *historyWriter) availabilityDiagnostics() map[string]string {
	return map[string]string{
		"request_drops_total":           "0", // Legacy keys: no disposable request queue remains.
		"snapshot_read_failures_total":  strconv.FormatUint(h.availabilityReadFailures.Load(), 10),
		"snapshot_write_failures_total": strconv.FormatUint(h.availabilityWriteFailures.Load(), 10),
		"backpressure_total":            strconv.FormatUint(h.availabilityWaits.Load(), 10),
		"backpressure_ns_total":         strconv.FormatUint(h.availabilityWaitNS.Load(), 10),
		"requests_pending":              "0",
		"snapshots_pending":             strconv.Itoa(len(h.snapshots)),
	}
}

func (h *historyWriter) offer(r historyRun) {
	select {
	case h.queue <- r:
	default:
		h.dropped.Add(1)
		slog.Warn("history gap: writer backlog full", "monitor_id", r.Run.MonitorID)
	}
}

func openHistory(ctx context.Context, path string) (*sql.DB, error) {
	db, err := sql.Open("duckdb", path)
	if err != nil {
		return nil, err
	}
	// One serialized writer plus at most two admitted HTTP readers.
	db.SetMaxOpenConns(3)
	for _, statement := range []string{
		"SET threads=2", "SET memory_limit='256MB'", "SET enable_external_access=false",
		`CREATE TABLE IF NOT EXISTS runs (
 run_id VARCHAR PRIMARY KEY, workspace VARCHAR NOT NULL, monitor_id UBIGINT NOT NULL,
 revision BIGINT NOT NULL, sequence UBIGINT NOT NULL, observed_at BIGINT NOT NULL,
 duration_ns BIGINT NOT NULL, failed BOOLEAN NOT NULL,
 acceptance VARCHAR NOT NULL CHECK(acceptance IN ('confirmed','rejected','unknown')))`,
		`CREATE TABLE IF NOT EXISTS samples (
 run_id VARCHAR NOT NULL, identity VARCHAR NOT NULL, condition UTINYINT NOT NULL, value DOUBLE NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS check_diagnostics (run_id VARCHAR PRIMARY KEY, diagnostics VARCHAR NOT NULL)`,
	} {
		if _, err := db.ExecContext(ctx, statement); err != nil {
			db.Close()
			return nil, err
		}
	}
	if err = initializeHistoryRollups(ctx, db); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func writeHistory(ctx context.Context, db *sql.DB, runs ...historyRun) error {
	for _, r := range runs {
		if r.ID == "" || r.Workspace == "" {
			return errors.New("invalid history identity")
		}
		if _, err := p.EncodeApplyMonitorRun(r.Run); err != nil {
			return err
		}
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var floor int64
	if err = tx.QueryRowContext(ctx, "SELECT value FROM history_meta WHERE key='raw_floor'").Scan(&floor); err != nil {
		return err
	}
	hours := make(map[int64]struct{})
	for _, r := range runs {
		var exists bool
		if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM runs WHERE run_id=?)", r.ID).Scan(&exists); err != nil {
			return err
		}
		if exists {
			continue
		}
		if r.ObservedAt < floor {
			return errors.New("history observation predates retained raw window")
		}
		if _, err = tx.ExecContext(ctx, "INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,?)", r.ID, r.Workspace, r.Run.MonitorID, r.Run.Revision, r.Run.Sequence, r.ObservedAt, r.Duration, r.Run.Failed, r.Acceptance); err != nil {
			return err
		}
		for _, row := range r.Run.Observations {
			if _, err = tx.ExecContext(ctx, "INSERT INTO samples VALUES(?,?,?,?)", r.ID, row.Identity, row.Condition, row.Value); err != nil {
				return err
			}
		}
		if r.Diagnostics != nil {
			body, err := json.Marshal(r.Diagnostics)
			if err != nil {
				return err
			}
			if _, err = tx.ExecContext(ctx, "INSERT INTO check_diagnostics VALUES (?,?)", r.ID, string(body)); err != nil {
				return err
			}
		}
		hours[r.ObservedAt/historyHour*historyHour] = struct{}{}
	}
	for hour := range hours {
		if _, err = tx.ExecContext(ctx, "INSERT INTO history_dirty_hours VALUES (?) ON CONFLICT DO NOTHING", hour); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Drain only work that is already queued: no batching delay, larger admission
// buffers, or unbounded batch allocations. Isolate failed records after rollback
// so one rejected write cannot discard its otherwise valid batch neighbours.
func (h *historyWriter) writeBatch(ctx context.Context, db *sql.DB, runs []historyRun, snapshots []historySnapshot) error {
	writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	var err error
	if len(runs) > 0 {
		err = writeHistory(writeCtx, db, runs...)
	} else {
		err = writeAvailability(writeCtx, db, snapshots...)
	}
	cancel()
	if err == nil {
		for _, snapshot := range snapshots {
			if snapshot.committed != nil {
				snapshot.committed <- nil
			}
		}
		return nil
	}
	if len(runs)+len(snapshots) > 1 {
		var failures error
		for i := range runs {
			failures = errors.Join(failures, h.writeBatch(ctx, db, runs[i:i+1], nil))
		}
		for i := range snapshots {
			failures = errors.Join(failures, h.writeBatch(ctx, db, nil, snapshots[i:i+1]))
		}
		return failures
	}
	if len(runs) > 0 {
		h.dropped.Add(1)
		slog.Warn("history gap: DuckDB write failed", "monitor_id", runs[0].Run.MonitorID)
	} else {
		h.availabilityWriteFailures.Add(1)
		if snapshots[0].committed != nil {
			snapshots[0].committed <- err
			slog.Warn("availability write failed; durable snapshot retained", "monitor_id", snapshots[0].MonitorID)
		} else {
			h.dropped.Add(1)
			slog.Warn("history gap: availability write failed", "monitor_id", snapshots[0].MonitorID)
		}
	}
	return err
}

func (h *historyWriter) serve(ctx context.Context, path string) {
	var db *sql.DB
	maintenance := time.NewTimer(0)
	defer maintenance.Stop()
	defer func() {
		h.db.Store(nil)
		if db != nil {
			db.Close()
		}
	}()
	for {
		var runs [32]historyRun
		var snapshots [8]historySnapshot
		var runCount, snapshotCount int
		select {
		case <-ctx.Done():
			return
		case r := <-h.queue:
			runs[0], runCount = r, 1
		drainRuns:
			for runCount < len(runs) {
				select {
				case runs[runCount] = <-h.queue:
					runCount++
				default:
					break drainRuns
				}
			}
		case s := <-h.snapshots:
			snapshots[0], snapshotCount = s, 1
		drainSnapshots:
			for snapshotCount < len(snapshots) {
				select {
				case snapshots[snapshotCount] = <-h.snapshots:
					snapshotCount++
				default:
					break drainSnapshots
				}
			}
		case <-maintenance.C:
			maintenance.Reset(time.Minute)
		}
		var err error
		if db == nil {
			// First open may atomically adopt a large existing availability
			// table. Keep it cancelable, without the per-batch five-second cap.
			db, err = openHistory(ctx, path)
			if err == nil {
				h.db.Store(db)
			}
		}
		writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		if err == nil {
			if runCount+snapshotCount > 0 {
				err = h.writeBatch(ctx, db, runs[:runCount], snapshots[:snapshotCount])
			} else {
				err = maintainHistory(writeCtx, db, time.Now())
			}
		} else {
			// Opening the database failed before any batch was attempted.
			h.dropped.Add(uint64(runCount))
			h.availabilityWriteFailures.Add(uint64(snapshotCount))
			for _, snapshot := range snapshots[:snapshotCount] {
				if snapshot.committed != nil {
					snapshot.committed <- err
				} else {
					h.dropped.Add(1)
				}
			}
			slog.Warn("history gap: DuckDB open failed", "runs", runCount, "snapshots", snapshotCount)
		}
		cancel()
		if err != nil {
			if runCount+snapshotCount == 0 {
				slog.Warn("DuckDB history maintenance failed; retained data will be retried")
			}
			if db != nil {
				h.db.Store(nil)
				db.Close()
				db = nil
			}
		}
	}
}
