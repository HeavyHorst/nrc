-- Explicit offline schema 10 -> 11. The caller owns BEGIN IMMEDIATE/COMMIT
-- and must roll back on error. Access data is not a searchable/broadcast asset.
CREATE TEMP TABLE nrc_reviews_v11_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_reviews_v11_guard
 SELECT application_id=0x4e524351 AND user_version=10
 FROM pragma_application_id,pragma_user_version;

CREATE TABLE review_runs (
 workspace BLOB NOT NULL,
 id BLOB NOT NULL CHECK(length(id)=8),
 form_id BLOB NOT NULL CHECK(length(form_id)=8),
 label BLOB NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('qa','customer')),
 previous_run BLOB NOT NULL CHECK(length(previous_run)=8),
 revision INTEGER NOT NULL CHECK(revision>0),
 decision TEXT NOT NULL DEFAULT '',
 comment BLOB NOT NULL DEFAULT x'',
 closed_at INTEGER NOT NULL DEFAULT 0,
 closed_by BLOB NOT NULL DEFAULT x'',
 closed_name BLOB NOT NULL DEFAULT x'',
 closed_source TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(workspace,id),
 FOREIGN KEY(workspace,form_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
CREATE INDEX review_runs_form ON review_runs(workspace,form_id,id);

CREATE TABLE review_invites (
 workspace BLOB NOT NULL,
 run_id BLOB NOT NULL,
 id BLOB NOT NULL CHECK(length(id)=8),
 token_hash BLOB NOT NULL CHECK(length(token_hash)=32),
 expires_at INTEGER NOT NULL CHECK(expires_at>0),
 revoked_at INTEGER NOT NULL DEFAULT 0,
 can_close INTEGER NOT NULL CHECK(can_close IN (0,1)),
 PRIMARY KEY(workspace,run_id,id),
 UNIQUE(workspace,token_hash),
 FOREIGN KEY(workspace,run_id) REFERENCES review_runs(workspace,id)
) STRICT, WITHOUT ROWID;
CREATE TABLE review_participants (
 workspace BLOB NOT NULL,
 run_id BLOB NOT NULL,
 id BLOB NOT NULL CHECK(length(id)=8),
 source TEXT NOT NULL CHECK(source IN ('staff','portal','guest')),
 identity BLOB NOT NULL CHECK(length(identity)>0),
 name BLOB NOT NULL CHECK(length(name)>0),
 can_close INTEGER NOT NULL CHECK(can_close IN (0,1)),
 invite_id BLOB NOT NULL CHECK(length(invite_id)=8),
 PRIMARY KEY(workspace,run_id,id),
 UNIQUE(workspace,run_id,source,identity),
 FOREIGN KEY(workspace,run_id) REFERENCES review_runs(workspace,id)
) STRICT, WITHOUT ROWID;
CREATE INDEX review_participants_identity ON review_participants(workspace,source,identity,run_id);
CREATE TABLE review_answers (
 workspace BLOB NOT NULL,
 run_id BLOB NOT NULL,
 participant_id BLOB NOT NULL,
 point_id BLOB NOT NULL,
 asset_id BLOB NOT NULL CHECK(length(asset_id)=8),
 PRIMARY KEY(workspace,run_id,participant_id,point_id),
 UNIQUE(workspace,asset_id),
 FOREIGN KEY(workspace,run_id,participant_id) REFERENCES review_participants(workspace,run_id,id),
 FOREIGN KEY(workspace,asset_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;

INSERT INTO nrc_reviews_v11_guard SELECT NOT EXISTS(SELECT 1 FROM pragma_foreign_key_check);
DROP TABLE nrc_reviews_v11_guard;
PRAGMA user_version=11;
