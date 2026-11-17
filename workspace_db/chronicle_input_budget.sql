-- Offline schema 6 -> 7. Run inside a transaction with foreign_keys=OFF;
-- rebuilding the parent with FK enforcement enabled would cascade job inputs.
CREATE TEMP TABLE nrc_chronicle_v7_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_chronicle_v7_guard
 SELECT application_id=0x4e524351 AND user_version=6 AND foreign_keys=0
 FROM pragma_application_id,pragma_user_version,pragma_foreign_keys;

CREATE TABLE chronicle_jobs_v7 (
 workspace BLOB NOT NULL,
 generation BLOB NOT NULL CHECK(length(generation)=8 AND generation!=x'0000000000000000'),
 note_id BLOB NOT NULL CHECK(length(note_id)=8),
 epoch INTEGER NOT NULL CHECK(epoch>0),
 owner BLOB NOT NULL CHECK(length(owner) BETWEEN 1 AND 256),
 consumer BLOB NOT NULL CHECK(length(consumer) BETWEEN 1 AND 128),
 lease_until INTEGER NOT NULL,
 state INTEGER NOT NULL DEFAULT 0 CHECK(state BETWEEN 0 AND 4),
 reserved INTEGER NOT NULL DEFAULT 0 CHECK(reserved IN (0,1)),
 input_tokens INTEGER NOT NULL DEFAULT 0 CHECK(input_tokens BETWEEN 0 AND 128000),
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
INSERT INTO chronicle_jobs_v7 SELECT * FROM chronicle_jobs;
DROP TABLE chronicle_jobs;
ALTER TABLE chronicle_jobs_v7 RENAME TO chronicle_jobs;
CREATE UNIQUE INDEX chronicle_active_job ON chronicle_jobs(workspace) WHERE state=0;
CREATE INDEX chronicle_result_order ON chronicle_jobs(workspace,generation) WHERE state=1;
CREATE INDEX chronicle_result_note ON chronicle_jobs(workspace,note_id,generation) WHERE state=1;

INSERT INTO nrc_chronicle_v7_guard SELECT NOT EXISTS(SELECT 1 FROM pragma_foreign_key_check);
DROP TABLE nrc_chronicle_v7_guard;
PRAGMA user_version=7;
