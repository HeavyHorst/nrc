package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
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

// This queue is only a bounded, disposable in-process handoff to the analytical
// writer. NRC acceptance and sequence allocation never depend on it or DuckDB.
type historyWriter struct {
	queue        chan historyRun
	availability chan p.MonitorState
	snapshots    chan historySnapshot
	dropped      atomic.Uint64
	db           atomic.Pointer[sql.DB]
}

func newHistoryWriter() *historyWriter {
	return &historyWriter{queue: make(chan historyRun, 256), availability: make(chan p.MonitorState, 256), snapshots: make(chan historySnapshot, 8)}
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

func writeHistory(ctx context.Context, db *sql.DB, r historyRun) error {
	if r.ID == "" || r.Workspace == "" {
		return errors.New("invalid history identity")
	}
	if _, err := p.EncodeApplyMonitorRun(r.Run); err != nil {
		return err
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists bool
	if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM runs WHERE run_id=?)", r.ID).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return tx.Commit()
	}
	var floor int64
	if err = tx.QueryRowContext(ctx, "SELECT value FROM history_meta WHERE key='raw_floor'").Scan(&floor); err != nil {
		return err
	}
	if r.ObservedAt < floor {
		return errors.New("history observation predates retained raw window")
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,?)", r.ID, r.Workspace, r.Run.MonitorID, r.Run.Revision, r.Run.Sequence, r.ObservedAt, r.Duration, r.Run.Failed, r.Acceptance)
	if err != nil {
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
	if _, err = tx.ExecContext(ctx, "INSERT INTO history_dirty_hours VALUES (?) ON CONFLICT DO NOTHING", r.ObservedAt/historyHour*historyHour); err != nil {
		return err
	}
	return tx.Commit()
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
		var run *historyRun
		var snapshot *historySnapshot
		select {
		case <-ctx.Done():
			return
		case r := <-h.queue:
			run = &r
		case s := <-h.snapshots:
			snapshot = &s
		case <-maintenance.C:
			maintenance.Reset(time.Minute)
		}
		writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		var err error
		if db == nil {
			db, err = openHistory(writeCtx, path)
			if err == nil {
				h.db.Store(db)
			}
		}
		if err == nil {
			if run != nil {
				err = writeHistory(writeCtx, db, *run)
			} else if snapshot != nil {
				err = writeAvailability(writeCtx, db, *snapshot)
			} else {
				err = maintainHistory(writeCtx, db, time.Now())
			}
		}
		cancel()
		if err != nil {
			if run != nil {
				h.dropped.Add(1)
				slog.Warn("history gap: DuckDB write failed", "monitor_id", run.Run.MonitorID)
			} else if snapshot != nil {
				h.dropped.Add(1)
				slog.Warn("history gap: availability write failed", "monitor_id", snapshot.MonitorID)
			} else {
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
