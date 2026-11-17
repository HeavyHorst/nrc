-- Explicit offline schema 5 -> 6 migration. No historical text backfill.
CREATE TEMP TABLE nrc_chronicle_v6_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_chronicle_v6_guard SELECT application_id=0x4e524351 AND user_version=5
 FROM pragma_application_id,pragma_user_version;
DROP TABLE nrc_chronicle_v6_guard;

CREATE TABLE chronicle_workspaces (
 workspace BLOB PRIMARY KEY CHECK(length(workspace)>0),
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
 epoch INTEGER NOT NULL CHECK(epoch>0),
 disabled_through_epoch INTEGER NOT NULL DEFAULT 0 CHECK(disabled_through_epoch>=0 AND disabled_through_epoch<=epoch),
 raw_bytes INTEGER NOT NULL DEFAULT 0 CHECK(raw_bytes>=0),
 raw_limit INTEGER NOT NULL DEFAULT 67108864 CHECK(raw_limit>=0),
 pending_inputs INTEGER NOT NULL DEFAULT 0 CHECK(pending_inputs>=0),
 input_limit INTEGER NOT NULL DEFAULT 4096 CHECK(input_limit>=0),
 claim_generation BLOB NOT NULL DEFAULT x'0000000000000000' CHECK(length(claim_generation)=8)
) STRICT, WITHOUT ROWID;

-- IDs share the durable technical source order, but not its retention/lifetime.
-- No FK to assets/history: deleting a source must not delete its chronicle.
CREATE TABLE chronicle_inputs (
 workspace BLOB NOT NULL,
 source_id BLOB NOT NULL CHECK(length(source_id)=8 AND source_id!=x'0000000000000000'),
 note_id BLOB NOT NULL CHECK(length(note_id)=8 AND note_id!=x'0000000000000000'),
 epoch INTEGER NOT NULL CHECK(epoch>0),
 captured_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL CHECK(expires_at>captured_at),
 actor_id BLOB NOT NULL CHECK(length(actor_id)<=256 OR state!=0),
 actor_name BLOB NOT NULL CHECK(length(actor_name)<=256 OR state!=0),
 operation INTEGER NOT NULL CHECK(operation IN (1,2,3)),
 before_present INTEGER NOT NULL CHECK(before_present IN (0,1)),
 after_present INTEGER NOT NULL CHECK(after_present IN (0,1)),
 before_version INTEGER NOT NULL,
 after_version INTEGER NOT NULL,
 before_bytes INTEGER NOT NULL CHECK(before_bytes>=0),
 after_bytes INTEGER NOT NULL CHECK(after_bytes>=0),
 before_hash BLOB NOT NULL CHECK(length(before_hash) IN (0,32)),
 after_hash BLOB NOT NULL CHECK(length(after_hash) IN (0,32)),
 state INTEGER NOT NULL CHECK(state IN (0,1,2,3,4)),
 reason BLOB NOT NULL CHECK(length(reason)<=64),
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 retry_at INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(workspace,source_id),
 FOREIGN KEY(workspace) REFERENCES chronicle_workspaces(workspace),
 CHECK((operation=1 AND before_present=0 AND after_present=1) OR
       (operation=2 AND before_present=1 AND after_present=1) OR
       (operation=3 AND before_present=1 AND after_present=0)),
 CHECK((state=0 AND length(reason)=0) OR state!=0)
) STRICT, WITHOUT ROWID;
-- state: 0 pending, 1 processed, 2 acknowledged without entry, 3 gap, 4 suppressed.
CREATE INDEX chronicle_note_order ON chronicle_inputs(workspace,note_id,source_id);
CREATE INDEX chronicle_pending_order ON chronicle_inputs(workspace,source_id) WHERE state=0;
CREATE INDEX chronicle_pending_epoch ON chronicle_inputs(workspace,epoch,source_id) WHERE state=0;
CREATE INDEX chronicle_expiry ON chronicle_inputs(expires_at,workspace,source_id) WHERE state=0;

-- Lossless terminal identity, not a second copy of input metadata. A range
-- contains only consecutive unsigned source IDs of one note and reason.
-- Each row is bounded; arbitrary alternating reasons/notes still require
-- separate rows. This is deliberately not a global disk-retention limit.
CREATE TABLE chronicle_gaps (
 workspace BLOB NOT NULL,
 first_source BLOB NOT NULL CHECK(length(first_source)=8 AND first_source!=x'0000000000000000'),
 last_source BLOB NOT NULL CHECK(length(last_source)=8 AND last_source>=first_source),
 note_id BLOB NOT NULL CHECK(length(note_id)=8 AND note_id!=x'0000000000000000'),
 reason BLOB NOT NULL CHECK(length(reason) BETWEEN 1 AND 64),
 first_at INTEGER NOT NULL,
 last_at INTEGER NOT NULL CHECK(last_at>=first_at),
 input_count INTEGER NOT NULL CHECK(input_count BETWEEN 1 AND 4096),
 PRIMARY KEY(workspace,first_source),
 FOREIGN KEY(workspace) REFERENCES chronicle_workspaces(workspace)
) STRICT, WITHOUT ROWID;
CREATE INDEX chronicle_gap_note_order ON chronicle_gaps(workspace,note_id,first_source);
CREATE TRIGGER chronicle_input_insert BEFORE INSERT ON chronicle_inputs BEGIN
 SELECT CASE WHEN NEW.state=0 AND (SELECT pending_inputs>=input_limit FROM chronicle_workspaces WHERE workspace=NEW.workspace)
 THEN RAISE(ABORT,'chronicle input quota') END;
 SELECT CASE WHEN NEW.source_id<=(SELECT last_source FROM chronicle_gaps
  WHERE workspace=NEW.workspace AND first_source<=NEW.source_id ORDER BY first_source DESC LIMIT 1)
 THEN RAISE(ABORT,'terminal chronicle gap') END;
END;
CREATE TRIGGER chronicle_input_account_insert AFTER INSERT ON chronicle_inputs WHEN NEW.state=0 BEGIN
 UPDATE chronicle_workspaces SET pending_inputs=pending_inputs+1 WHERE workspace=NEW.workspace;
END;
CREATE TRIGGER chronicle_input_account_terminal AFTER UPDATE OF state ON chronicle_inputs WHEN OLD.state=0 AND NEW.state!=0 BEGIN
 UPDATE chronicle_workspaces SET pending_inputs=pending_inputs-1 WHERE workspace=NEW.workspace;
END;
CREATE TRIGGER chronicle_input_account_delete AFTER DELETE ON chronicle_inputs WHEN OLD.state=0 BEGIN
 UPDATE chronicle_workspaces SET pending_inputs=pending_inputs-1 WHERE workspace=OLD.workspace;
END;

CREATE TABLE chronicle_raw (
 workspace BLOB NOT NULL,
 source_id BLOB NOT NULL,
 before_title BLOB NOT NULL,
 before_format BLOB NOT NULL,
 before_body BLOB NOT NULL,
 after_title BLOB NOT NULL,
 after_format BLOB NOT NULL,
 after_body BLOB NOT NULL,
 byte_count INTEGER GENERATED ALWAYS AS (length(before_title)+length(before_format)+length(before_body)+
                                         length(after_title)+length(after_format)+length(after_body)) STORED,
 PRIMARY KEY(workspace,source_id),
 FOREIGN KEY(workspace,source_id) REFERENCES chronicle_inputs(workspace,source_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE TRIGGER chronicle_raw_insert BEFORE INSERT ON chronicle_raw BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM chronicle_inputs i JOIN chronicle_workspaces w USING(workspace)
  WHERE i.workspace=NEW.workspace AND i.source_id=NEW.source_id AND i.state=0 AND w.enabled=1
   AND i.epoch=w.epoch AND NEW.byte_count<=w.raw_limit-w.raw_bytes)
 THEN RAISE(ABORT,'invalid chronicle capture') END;
END;
CREATE TRIGGER chronicle_raw_account_insert AFTER INSERT ON chronicle_raw BEGIN
 UPDATE chronicle_workspaces SET raw_bytes=raw_bytes+NEW.byte_count WHERE workspace=NEW.workspace;
END;
CREATE TRIGGER chronicle_raw_account_delete AFTER DELETE ON chronicle_raw BEGIN
 UPDATE chronicle_workspaces SET raw_bytes=raw_bytes-OLD.byte_count WHERE workspace=OLD.workspace;
END;
CREATE TRIGGER chronicle_raw_terminal AFTER UPDATE OF state ON chronicle_inputs WHEN NEW.state!=0 BEGIN
 DELETE FROM chronicle_raw WHERE workspace=NEW.workspace AND source_id=NEW.source_id;
END;
CREATE TRIGGER chronicle_terminal_guard BEFORE UPDATE OF state ON chronicle_inputs
 WHEN OLD.state!=0 AND NEW.state!=OLD.state BEGIN
 SELECT RAISE(ABORT,'terminal chronicle input');
END;

-- A single active immutable claim per workspace. Expired unsuccessful claims
-- can be removed; the workspace generation and input attempt counters cannot.
-- Successful/deleted receipts have no FK to inputs or canonical note lifetime.
CREATE TABLE chronicle_jobs (
 workspace BLOB NOT NULL,
 generation BLOB NOT NULL CHECK(length(generation)=8 AND generation!=x'0000000000000000'),
 note_id BLOB NOT NULL CHECK(length(note_id)=8),
 epoch INTEGER NOT NULL CHECK(epoch>0),
 owner BLOB NOT NULL CHECK(length(owner) BETWEEN 1 AND 256),
 consumer BLOB NOT NULL CHECK(length(consumer) BETWEEN 1 AND 128),
 lease_until INTEGER NOT NULL,
 state INTEGER NOT NULL DEFAULT 0 CHECK(state BETWEEN 0 AND 4),
 reserved INTEGER NOT NULL DEFAULT 0 CHECK(reserved IN (0,1)),
 input_tokens INTEGER NOT NULL DEFAULT 0 CHECK(input_tokens BETWEEN 0 AND 16000),
 output_tokens INTEGER NOT NULL DEFAULT 0 CHECK(output_tokens BETWEEN 0 AND 1000),
 reservation_day INTEGER NOT NULL DEFAULT -1 CHECK(reservation_day>=-1),
 source_key BLOB NOT NULL CHECK(length(source_key)=32),
 result_hash BLOB NOT NULL DEFAULT x'' CHECK(length(result_hash) IN (0,32)),
 summary BLOB NOT NULL DEFAULT x'' CHECK(length(summary)<=4096),
 model BLOB NOT NULL DEFAULT x'' CHECK(length(model)<=128),
 prompt_version BLOB NOT NULL DEFAULT x'' CHECK(length(prompt_version)<=128),
 schema_version BLOB NOT NULL DEFAULT x'' CHECK(length(schema_version)<=128),
 created_at INTEGER NOT NULL,
 first_at INTEGER NOT NULL,
 last_at INTEGER NOT NULL,
 PRIMARY KEY(workspace,generation),
 UNIQUE(workspace,consumer,source_key),
 FOREIGN KEY(workspace) REFERENCES chronicle_workspaces(workspace)
) STRICT, WITHOUT ROWID;
-- state: 0 active, 1 result, 2 no relevant change, 3 explicitly deleted, 4 gap.
CREATE UNIQUE INDEX chronicle_active_job ON chronicle_jobs(workspace) WHERE state=0;
CREATE INDEX chronicle_result_order ON chronicle_jobs(workspace,generation) WHERE state=1;
CREATE INDEX chronicle_result_note ON chronicle_jobs(workspace,note_id,generation) WHERE state=1;
CREATE TABLE chronicle_job_inputs (
 workspace BLOB NOT NULL,
 generation BLOB NOT NULL,
 ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 31),
 source_id BLOB NOT NULL CHECK(length(source_id)=8),
 before_hash BLOB NOT NULL CHECK(length(before_hash) IN (0,32)),
 after_hash BLOB NOT NULL CHECK(length(after_hash) IN (0,32)),
 PRIMARY KEY(workspace,generation,ordinal),
 UNIQUE(workspace,generation,source_id),
 FOREIGN KEY(workspace,generation) REFERENCES chronicle_jobs(workspace,generation) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE TABLE chronicle_deletions (
 workspace BLOB NOT NULL,
 note_id BLOB NOT NULL CHECK(length(note_id)=8),
 through_source BLOB NOT NULL CHECK(length(through_source)=8),
 deleted_at INTEGER NOT NULL,
 PRIMARY KEY(workspace,note_id),
 FOREIGN KEY(workspace) REFERENCES chronicle_workspaces(workspace)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER chronicle_deleted_input BEFORE INSERT ON chronicle_inputs
 WHEN NEW.source_id<=(SELECT through_source FROM chronicle_deletions WHERE workspace=NEW.workspace AND note_id=NEW.note_id) BEGIN
 SELECT RAISE(ABORT,'deleted chronicle input');
END;
-- One current UTC day per workspace, never moved backwards by a wall-clock
-- correction. Unknown provider outcomes retain reservations across restarts.
CREATE TABLE chronicle_budgets (
 workspace BLOB PRIMARY KEY,
 day INTEGER NOT NULL,
 calls INTEGER NOT NULL CHECK(calls>=0),
 input_tokens INTEGER NOT NULL CHECK(input_tokens BETWEEN 0 AND 8000000),
 output_tokens INTEGER NOT NULL CHECK(output_tokens BETWEEN 0 AND 500000),
 FOREIGN KEY(workspace) REFERENCES chronicle_workspaces(workspace)
) STRICT, WITHOUT ROWID;
PRAGMA user_version=6;
