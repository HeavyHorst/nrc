package personalmemory

import (
	"context"
	"database/sql"
	"fmt"
)

type Changes struct {
	Enabled  bool  `json:"enabled"`
	Epoch    int64 `json:"epoch"`
	Revision int64 `json:"revision"`
}

// Changes reads one indexed policy row, never originals or another owner's
// activity. Revisions are durable invalidation tokens, not event counts.
func (s *Scope) Changes(ctx context.Context) (Changes, error) {
	var c Changes
	err := s.store.db.QueryRowContext(ctx, `SELECT enabled,epoch,revision FROM retention WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&c.Enabled, &c.Epoch, &c.Revision)
	return c, err
}

// UserInputGeneration excludes assistant output, summaries and receipts so a
// proposal cannot invalidate itself. Capture and approval checks serialize on mu.
func (s *Scope) UserInputGeneration(ctx context.Context) (int64, error) {
	return s.userInputGeneration(ctx, s.store.db)
}

func (s *Scope) userInputGeneration(ctx context.Context, db rowReader) (int64, error) {
	var generation int64
	err := db.QueryRowContext(ctx, `SELECT user_input_generation FROM retention WHERE owner=? AND workspace=?`, s.owner, s.workspace).Scan(&generation)
	return generation, err
}

func (s *Scope) advanceUserInput(ctx context.Context, tx *sql.Tx, records []Record) error {
	for _, record := range records {
		if record.Role == "user" {
			_, err := tx.ExecContext(ctx, `UPDATE retention SET user_input_generation=user_input_generation+1 WHERE owner=? AND workspace=?`, s.owner, s.workspace)
			return err
		}
	}
	return nil
}

func migrateChanges(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRow(`SELECT count(*) FROM pragma_table_info('retention') WHERE name='revision'`).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		if _, err := tx.Exec(`ALTER TABLE retention ADD COLUMN revision INTEGER NOT NULL DEFAULT 0`); err != nil {
			return err
		}
	}
	if err := tx.QueryRow(`SELECT count(*) FROM pragma_table_info('retention') WHERE name='user_input_generation'`).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		if _, err := tx.Exec(`ALTER TABLE retention ADD COLUMN user_input_generation INTEGER NOT NULL DEFAULT 0`); err != nil {
			return err
		}
	}
	for _, table := range []string{"segments", "receipts"} {
		for _, event := range []string{"INSERT", "UPDATE", "DELETE"} {
			row := "NEW"
			if event == "DELETE" {
				row = "OLD"
			}
			query := fmt.Sprintf(`CREATE TRIGGER IF NOT EXISTS changes_%s_%s AFTER %s ON %s BEGIN
UPDATE retention SET revision=revision+1 WHERE owner=%s.owner AND workspace=%s.workspace; END`, table, event, event, table, row, row)
			if _, err := tx.Exec(query); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(`CREATE TRIGGER IF NOT EXISTS changes_policy AFTER UPDATE OF epoch,enabled ON retention
WHEN NEW.epoch!=OLD.epoch OR NEW.enabled!=OLD.enabled BEGIN
UPDATE retention SET revision=revision+1 WHERE owner=NEW.owner AND workspace=NEW.workspace; END`); err != nil {
		return err
	}
	return tx.Commit()
}
