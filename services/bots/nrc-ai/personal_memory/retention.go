package personalmemory

import (
	"context"
	"database/sql"
	"errors"
)

// Retention is keep-until-deleted. Disabling does not silently delete history.
type Retention struct {
	Enabled  bool  `json:"enabled"`
	Epoch    int64 `json:"epoch"`
	Bytes    int64 `json:"bytes"`
	Segments int64 `json:"segments"`
}

func (s *Scope) Retention(ctx context.Context) (Retention, error) {
	var p Retention
	err := s.store.db.QueryRowContext(ctx, `SELECT enabled,epoch,
 (SELECT coalesce(sum(length(CAST(body AS BLOB))),0) FROM segments WHERE owner=r.owner AND workspace=r.workspace AND state!='deleted'),
 (SELECT count(*) FROM segments WHERE owner=r.owner AND workspace=r.workspace AND state!='deleted')
 FROM retention r WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&p.Enabled, &p.Epoch, &p.Bytes, &p.Segments)
	return p, err
}

func (s *Scope) checkEpoch(ctx context.Context, db rowReader) error {
	if !s.fenced {
		return ctx.Err()
	}
	var epoch int64
	var enabled bool
	if err := db.QueryRowContext(ctx, `SELECT epoch,enabled FROM retention WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&epoch, &enabled); err != nil {
		return err
	}
	if epoch != s.epoch || !enabled {
		return ErrConflict
	}
	return nil
}

func (s *Scope) Epoch() int64 { return s.epoch }

// Execution fences background finalization as well as cancellable model work.
// Forgetting conservatively cancels every execution in this owner/workspace.
func (s *Scope) Execution(parent context.Context) (*Scope, context.Context, func(), error) {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if err := s.checkEpoch(parent, s.store.db); err != nil {
		return nil, nil, nil, err
	}
	p, err := s.Retention(parent)
	if err != nil {
		return nil, nil, nil, err
	}
	if !p.Enabled {
		return nil, nil, nil, ErrScope
	}
	lease := &Scope{store: s.store, owner: s.owner, workspace: s.workspace, epoch: p.Epoch, fenced: true}
	ctx, cancel := context.WithCancel(parent)
	s.store.executions[lease] = cancel
	release := func() {
		cancel()
		s.store.mu.Lock()
		delete(s.store.executions, lease)
		s.store.mu.Unlock()
	}
	return lease, ctx, release, nil
}

func (s *Scope) checkWrite(ctx context.Context, db rowReader) error {
	if err := s.checkEpoch(ctx, db); err != nil {
		return err
	}
	var enabled bool
	err := db.QueryRowContext(ctx, `SELECT enabled FROM retention WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&enabled)
	if err != nil {
		return err
	}
	if !enabled {
		return ErrScope
	}
	return nil
}

// Called under the store mutex, within the deletion/policy transaction.
func (s *Scope) invalidate(ctx context.Context, tx *sql.Tx) error {
	for _, q := range []string{
		`UPDATE retention SET epoch=epoch+1 WHERE owner=? AND workspace=?`,
		`DELETE FROM memory_views WHERE owner=? AND workspace=?`,
		`DELETE FROM summary_views WHERE owner=? AND workspace=?`,
		`UPDATE nodes SET revision=revision+1,state='pending',summary='',version='' WHERE owner=? AND workspace=? AND EXISTS (SELECT 1 FROM segments s WHERE s.owner=nodes.owner AND s.workspace=nodes.workspace AND s.state='active' AND s.seq BETWEEN nodes.lo AND nodes.hi)`,
		`UPDATE segments SET revision=revision+1,state='incomplete' WHERE owner=? AND workspace=? AND state='active'`,
	} {
		if _, err := tx.ExecContext(ctx, q, s.owner, s.workspace); err != nil {
			return err
		}
	}
	return nil
}

func (s *Scope) cancelExecutions() {
	for scope, cancel := range s.store.executions {
		if scope.owner == s.owner && scope.workspace == s.workspace {
			cancel()
			delete(s.store.executions, scope)
		}
	}
}

// Configure requires the epoch returned by inspection. Enabling is explicit;
// minting another internal capability never changes an existing disabled policy.
func (s *Scope) Configure(ctx context.Context, p Retention) error {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	tx, err := s.store.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	r, err := tx.ExecContext(ctx, `UPDATE retention SET enabled=? WHERE owner=? AND workspace=? AND epoch=?`, p.Enabled, s.owner, s.workspace, p.Epoch)
	if err != nil {
		return err
	}
	n, _ := r.RowsAffected()
	if n != 1 {
		return ErrConflict
	}
	if err := s.invalidate(ctx, tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.cancelExecutions()
	return nil
}

func (s *Scope) ForgetAll(ctx context.Context, epoch int64) error {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	tx, err := s.store.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var current int64
	if err := tx.QueryRowContext(ctx, `SELECT epoch FROM retention WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&current); err != nil {
		return err
	}
	if current != epoch {
		return ErrConflict
	}
	// Every existing subtree is empty after deleting all originals. Publish that
	// empty state locally, retaining the revision fence against in-flight builds;
	// tombstones must not queue provider work ahead of newly captured evidence.
	for _, q := range []string{
		`UPDATE segments SET revision=revision+1,state='deleted',body='' WHERE owner=? AND workspace=? AND state!='deleted'`,
		`DELETE FROM originals_fts WHERE owner=? AND workspace=?`,
		`UPDATE nodes SET revision=revision+1,state='ready',summary='',version='' WHERE owner=? AND workspace=?`,
	} {
		if _, err := tx.ExecContext(ctx, q, s.owner, s.workspace); err != nil {
			return err
		}
	}
	if err := s.invalidate(ctx, tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.cancelExecutions()
	return nil
}

// Export is paginated and epoch-bound: a deletion invalidates the next page.
func (s *Scope) Export(ctx context.Context, epoch, after int64, limit int) ([]Segment, error) {
	return s.segmentPage(ctx, epoch, after, limit, false)
}

// History starts with the most recent evidence; -1 means the first page.
// It never restores executable plans from historical text.
func (s *Scope) History(ctx context.Context, epoch, before int64, limit int) ([]Segment, error) {
	return s.segmentPage(ctx, epoch, before, limit, true)
}

func (s *Scope) segmentPage(ctx context.Context, epoch, cursor int64, limit int, reverse bool) ([]Segment, error) {
	if limit < 1 || limit > 100 || cursor < -1 {
		return nil, errors.New("invalid export page")
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	p, err := s.Retention(ctx)
	if err != nil {
		return nil, err
	}
	if p.Epoch != epoch {
		return nil, ErrConflict
	}
	query := `SELECT seq FROM segments WHERE owner=? AND workspace=? AND state!='deleted' AND seq>? ORDER BY seq LIMIT ?`
	if reverse {
		query = `SELECT seq FROM segments WHERE owner=? AND workspace=? AND state!='deleted' AND seq<? ORDER BY seq DESC LIMIT ?`
		if cursor == -1 {
			cursor = 1<<63 - 1
		}
	}
	rows, err := s.store.db.QueryContext(ctx, query, s.owner, s.workspace, cursor, limit)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	out := make([]Segment, 0, len(ids))
	for _, id := range ids {
		seg, err := s.Read(ctx, id)
		if err != nil {
			return nil, err
		}
		out = append(out, seg)
	}
	return out, nil
}
