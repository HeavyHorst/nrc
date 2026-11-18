-- Explicit offline schema 7 -> 8. Run inside a transaction.
CREATE TEMP TABLE nrc_snapshots_v8_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_snapshots_v8_guard SELECT application_id=0x4e524351 AND user_version=7
 FROM pragma_application_id,pragma_user_version;
DROP TABLE nrc_snapshots_v8_guard;
INSERT INTO sequences VALUES ('monitor_snapshot',x'0000000000000000');

-- Immutable availability pages, committed with the accepted run. Only a sink
-- acknowledgment removes them; neither a full sidecar buffer nor a new run can.
-- body includes the opcode, durable capture ID and final capture-kind byte.
CREATE TABLE monitor_snapshots (
 workspace BLOB NOT NULL,
 monitor_id BLOB NOT NULL CHECK(length(monitor_id)=8),
 snapshot_id BLOB NOT NULL CHECK(length(snapshot_id)=8 AND snapshot_id!=zeroblob(8)),
 observed_at INTEGER NOT NULL CHECK(observed_at>0),
 cursor BLOB NOT NULL CHECK(length(cursor)=8),
 body BLOB NOT NULL CHECK(length(body) BETWEEN 65 AND 131072),
 PRIMARY KEY(workspace,monitor_id,snapshot_id,cursor),
 FOREIGN KEY(workspace,monitor_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
PRAGMA user_version=8;
