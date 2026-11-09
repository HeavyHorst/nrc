package personalmemory

import (
	"context"
	"log/slog"
	"time"
)

// RunSummaries drains the durable pending-node queue fairly across scopes.
// Up to eight scopes build concurrently, with one job per scope. Completed slots
// refill without waiting for slower peers. Failed scopes cool down. Keyset
// pages bound each database scan without losing jobs across restarts.
func (s *Store) RunSummaries(ctx context.Context, version string, summarize Summarize) {
	ctx, cancel := context.WithCancel(ctx)
	type result struct {
		key [2]string
		err error
	}
	results := make(chan result, 8)
	running := make(map[[2]string]bool)
	defer func() {
		cancel()
		for len(running) > 0 {
			r := <-results
			delete(running, r.key)
		}
	}()
	owner, workspace := "", ""
	progressed := false
	retryAfter := make(map[[2]string]time.Time)
	complete := func(r result) {
		delete(running, r.key)
		if r.err != nil && ctx.Err() == nil {
			retryAfter[r.key] = time.Now().Add(time.Second)
			slog.Warn("personal memory summary deferred")
		}
	}
	for ctx.Err() == nil {
		select {
		case r := <-results:
			complete(r)
		default:
		}
		// Expire entries even for scopes that were disabled or forgotten during
		// cooldown; the retry map must not retain every historical failure.
		now := time.Now()
		for key, until := range retryAfter {
			if !now.Before(until) {
				delete(retryAfter, key)
			}
		}
		var scopes []*Scope
		var err error
		if len(running) < 8 {
			rows, queryErr := s.db.QueryContext(ctx, `SELECT r.owner,r.workspace FROM retention r
WHERE r.enabled=1 AND (r.owner,r.workspace)>(?,?)
AND EXISTS(SELECT 1 FROM summary_ready n WHERE n.owner=r.owner AND n.workspace=r.workspace)
ORDER BY r.owner,r.workspace LIMIT 8`, owner, workspace)
			err = queryErr
			if err == nil {
				for rows.Next() {
					scope := &Scope{store: s}
					if err = rows.Scan(&scope.owner, &scope.workspace); err != nil {
						break
					}
					scopes = append(scopes, scope)
				}
				if err == nil {
					err = rows.Err()
				}
				rows.Close() // Never hold the DB connection during provider work.
			}
		}
		if err != nil || len(scopes) == 0 {
			if err != nil && ctx.Err() == nil {
				slog.Warn("personal memory summary queue unavailable")
			}
			wait := err != nil || !progressed || len(running) == 8
			if len(running) < 8 {
				owner, workspace = "", ""
				progressed = false
			}
			if !wait {
				continue
			}
			timer := time.NewTimer(time.Second)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case r := <-results:
				timer.Stop()
				complete(r)
			case <-timer.C:
			}
			continue
		}
		for _, scope := range scopes {
			if len(running) == 8 {
				break
			}
			owner, workspace = scope.owner, scope.workspace
			key := [2]string{owner, workspace}
			if running[key] || time.Now().Before(retryAfter[key]) {
				continue
			}
			running[key] = true
			progressed = true
			go func() {
				callCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
				defer cancel()
				_, err := scope.BuildNext(callCtx, version, summarize)
				results <- result{key, err}
			}()
		}
	}
}
