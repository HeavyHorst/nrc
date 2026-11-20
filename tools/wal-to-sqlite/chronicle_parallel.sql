-- Explicit offline schema 9 -> 10. Caller owns BEGIN IMMEDIATE / COMMIT
-- and must roll back on any error. No parent rebuild or FK disabling needed.
CREATE TEMP TABLE nrc_chronicle_v10_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_chronicle_v10_guard
 SELECT application_id=0x4e524351 AND user_version=9
 FROM pragma_application_id,pragma_user_version;

ALTER TABLE chronicle_jobs ADD COLUMN publication_generation BLOB
 CHECK(publication_generation IS NULL OR
       (length(publication_generation)=8 AND publication_generation!=x'0000000000000000'));
-- Preserve all existing public identities, including no-change and gap receipts.
UPDATE chronicle_jobs SET publication_generation=generation WHERE state IN (1,2,4);
ALTER TABLE chronicle_workspaces ADD COLUMN publication_generation BLOB NOT NULL
 DEFAULT x'0000000000000000' CHECK(length(publication_generation)=8);
-- Fixed-width big-endian BLOB order is unsigned generation order. Include
-- active/deleted jobs and the claim floor, not just visible results.
UPDATE chronicle_workspaces SET publication_generation=max(claim_generation,
 coalesce((SELECT max(generation) FROM chronicle_jobs j
           WHERE j.workspace=chronicle_workspaces.workspace),x'0000000000000000'));

DROP INDEX chronicle_active_job;
CREATE INDEX chronicle_active_job ON chronicle_jobs(workspace) WHERE state=0;
DROP INDEX chronicle_result_order;
CREATE INDEX chronicle_result_order ON chronicle_jobs(workspace,publication_generation)
 WHERE state=1 AND publication_generation IS NOT NULL;
DROP INDEX chronicle_result_note;
CREATE INDEX chronicle_result_note ON chronicle_jobs(workspace,note_id,publication_generation)
 WHERE state=1 AND publication_generation IS NOT NULL;
CREATE INDEX chronicle_pending_publication ON chronicle_jobs(workspace,generation)
 WHERE state IN (1,2,4) AND publication_generation IS NULL;
CREATE INDEX chronicle_job_input_source ON chronicle_job_inputs(workspace,source_id,generation);

INSERT INTO nrc_chronicle_v10_guard SELECT NOT EXISTS(SELECT 1 FROM pragma_foreign_key_check);
DROP TABLE nrc_chronicle_v10_guard;
PRAGMA user_version=10;
