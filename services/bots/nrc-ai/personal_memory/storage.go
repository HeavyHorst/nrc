package personalmemory

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"syscall"
	"time"
)

// StorageStatus describes filesystem pressure, not a per-user quota. No
// maintenance operation removes originals, run identities or approval receipts.
type StorageStatus struct {
	AvailableBytes uint64
	DatabaseBytes  int64
	WALBytes       int64
	LowSpace       bool
	Compacted      bool
	CheckpointBusy bool
}

// Maintain serializes with capture mutations. Checkpoints reclaim WAL space;
// optional VACUUM reclaims only free pages, with room for SQLite's temporary
// copy and WAL. A cancelled/failed VACUUM leaves the original DB intact.
func (s *Store) Maintain(ctx context.Context, compact bool) (StorageStatus, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var status StorageStatus
	var fs syscall.Statfs_t
	if err := syscall.Statfs(s.path, &fs); err != nil {
		return status, err
	}
	status.AvailableBytes = fs.Bavail * uint64(fs.Bsize)
	status.LowSpace = status.AvailableBytes < 1<<30 || float64(fs.Bavail) < float64(fs.Blocks)*0.10
	info, err := os.Stat(s.path)
	if err != nil {
		return status, err
	}
	status.DatabaseBytes = info.Size()
	if info, err := os.Stat(s.path + "-wal"); err == nil {
		status.WALBytes = info.Size()
	}
	var busy, logPages, checkpointed int
	if err := s.db.QueryRowContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`).Scan(&busy, &logPages, &checkpointed); err != nil {
		return status, err
	}
	status.CheckpointBusy = busy != 0
	if !compact || busy != 0 || status.LowSpace {
		return status, nil
	}
	var pages, pageSize int64
	if err := s.db.QueryRowContext(ctx, `PRAGMA freelist_count`).Scan(&pages); err != nil {
		return status, err
	}
	if err := s.db.QueryRowContext(ctx, `PRAGMA page_size`).Scan(&pageSize); err != nil {
		return status, err
	}
	if pages*pageSize < 64<<20 || status.AvailableBytes < uint64(status.DatabaseBytes)*2+256<<20 {
		return status, nil
	}
	if _, err := s.db.ExecContext(ctx, `VACUUM`); err != nil {
		return status, fmt.Errorf("memory compaction: %w", err)
	}
	status.Compacted = true
	err = s.db.QueryRowContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`).Scan(&busy, &logPages, &checkpointed)
	status.CheckpointBusy = busy != 0
	return status, err
}

// RunMaintenance shares the service cancellation/join ownership with summaries.
// It runs immediately, then each minute; compaction is attempted once per day.
func (s *Store) RunMaintenance(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	var nextCompact time.Time
	for ctx.Err() == nil {
		compact := time.Now().After(nextCompact)
		callCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		status, err := s.Maintain(callCtx, compact)
		cancel()
		if compact {
			nextCompact = time.Now().Add(24 * time.Hour)
		}
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			slog.Warn("personal memory storage maintenance failed")
		}
		if status.LowSpace {
			slog.Warn("personal memory disk space low; expand storage, originals are not auto-deleted", "available_bytes", status.AvailableBytes, "database_bytes", status.DatabaseBytes, "wal_bytes", status.WALBytes)
		}
		if status.CheckpointBusy {
			slog.Warn("personal memory checkpoint deferred: database busy")
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
