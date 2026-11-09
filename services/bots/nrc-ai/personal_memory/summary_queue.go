package personalmemory

import (
	"database/sql"
	"fmt"
)

// Ready work is materialized when its dependencies change, not rediscovered by
// scanning historical nodes for every summary. Rebuild once on process startup
// after recovery; all runtime maintenance participates in the source transaction.
func installSummaryQueue(db *sql.DB) error {
	const eligible = `n.state='pending' AND NOT EXISTS(SELECT 1 FROM summary_attempts a WHERE a.owner=n.owner AND a.workspace=n.workspace AND a.lo=n.lo AND a.hi=n.hi AND a.revision=n.revision AND a.attempts>=3) AND (
 (n.lo=n.hi AND EXISTS(SELECT 1 FROM segments s WHERE s.owner=n.owner AND s.workspace=n.workspace AND s.seq=n.lo AND s.state!='active')) OR
 (n.lo<n.hi AND EXISTS(SELECT 1 FROM nodes c WHERE c.owner=n.owner AND c.workspace=n.workspace AND c.lo=n.lo AND c.hi=(n.lo+n.hi)/2 AND c.state='ready')
 AND EXISTS(SELECT 1 FROM nodes c WHERE c.owner=n.owner AND c.workspace=n.workspace AND c.lo=(n.lo+n.hi)/2+1 AND c.hi=n.hi AND c.state='ready')))`
	const parent = `lo=(NEW.lo/(2*(NEW.hi-NEW.lo+1)))*(2*(NEW.hi-NEW.lo+1)) AND hi=(NEW.lo/(2*(NEW.hi-NEW.lo+1))+1)*(2*(NEW.hi-NEW.lo+1))-1`
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// This index is derived and rebuilt at startup, never an execution ledger.
	if _, err = tx.Exec(`DROP TRIGGER IF EXISTS summary_ready_INSERT;
DROP TRIGGER IF EXISTS summary_ready_UPDATE;
DROP TRIGGER IF EXISTS summary_ready_segment;
DROP TABLE IF EXISTS summary_ready;
CREATE TABLE summary_ready(owner TEXT,workspace TEXT,lo INTEGER,hi INTEGER,attempts INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(owner,workspace,lo,hi));
CREATE INDEX summary_ready_order ON summary_ready(owner,workspace,attempts,lo,hi);`); err != nil {
		return err
	}
	for _, event := range []string{"INSERT", "UPDATE"} {
		q := fmt.Sprintf(`CREATE TRIGGER IF NOT EXISTS summary_ready_%s AFTER %s ON nodes BEGIN `, event, event)
		// Separate exact-key probes: an OR over ranges can make SQLite scan all
		// nodes in the workspace despite the composite primary key.
		for _, key := range []string{"lo=NEW.lo AND hi=NEW.hi", parent} {
			q += `DELETE FROM summary_ready WHERE owner=NEW.owner AND workspace=NEW.workspace AND ` + key + `;
INSERT OR IGNORE INTO summary_ready(owner,workspace,lo,hi) SELECT n.owner,n.workspace,n.lo,n.hi FROM nodes n WHERE n.owner=NEW.owner AND n.workspace=NEW.workspace AND ` + key + ` AND ` + eligible + `;`
		}
		q += `END;`
		if _, err = tx.Exec(q); err != nil {
			return err
		}
	}
	if _, err = tx.Exec(`CREATE TRIGGER IF NOT EXISTS summary_ready_segment AFTER UPDATE OF state ON segments BEGIN
DELETE FROM summary_ready WHERE owner=NEW.owner AND workspace=NEW.workspace AND lo=NEW.seq AND hi=NEW.seq;
INSERT OR IGNORE INTO summary_ready(owner,workspace,lo,hi) SELECT n.owner,n.workspace,n.lo,n.hi FROM nodes n WHERE n.owner=NEW.owner AND n.workspace=NEW.workspace AND n.lo=NEW.seq AND n.hi=NEW.seq AND ` + eligible + `; END;
DELETE FROM summary_ready;
INSERT INTO summary_ready(owner,workspace,lo,hi) SELECT n.owner,n.workspace,n.lo,n.hi FROM nodes n WHERE ` + eligible); err != nil {
		return err
	}
	return tx.Commit()
}
