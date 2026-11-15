-- Explicit schema 2 -> 3 migration. Run on a stopped database in a transaction,
-- then run slice_finalize.sql before COMMIT. Canonical rows are unchanged.
CREATE TEMP TABLE nrc_slice_v3_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_slice_v3_guard SELECT application_id=0x4e524351 AND user_version=2
 FROM pragma_application_id,pragma_user_version;
DROP TABLE nrc_slice_v3_guard;
DROP TRIGGER slice_task_insert;
DROP TRIGGER slice_task_update;
DROP TRIGGER slice_task_delete;
DROP TRIGGER slice_asset_insert;
DROP TRIGGER slice_asset_update;
DROP TRIGGER slice_asset_delete;
DROP TRIGGER slice_note_insert;
DROP TRIGGER slice_note_update;
DROP TRIGGER slice_note_delete;
DROP TRIGGER slice_edge_insert;
DROP TRIGGER slice_edge_update;
DROP TRIGGER slice_edge_delete;
DROP TABLE slice_task_members;
DROP TABLE slice_projects;
DROP TABLE slice_summaries;

-- Capture identities, not record bodies. The queue participates in savepoints
-- and is drained before commit. Kinds: asset=1, task=2, edge=3, slice=4.
CREATE TABLE slice_pending (
 workspace BLOB NOT NULL, kind INTEGER NOT NULL, id BLOB NOT NULL,
 PRIMARY KEY(workspace,kind,id)
) STRICT, WITHOUT ROWID;
-- Membership and its narrow, last-committed contribution share one row.
-- No member FK: canonical edges may refer to absent/imported records.
CREATE TABLE slice_members (
 workspace BLOB NOT NULL, slice_id BLOB NOT NULL, edge_id BLOB NOT NULL,
 member_type INTEGER NOT NULL, member_id BLOB NOT NULL,
 category INTEGER NOT NULL, work INTEGER NOT NULL, blocked INTEGER NOT NULL,
 active_at INTEGER, moved INTEGER NOT NULL, project BLOB NOT NULL,
 PRIMARY KEY(workspace,slice_id,edge_id)
) STRICT, WITHOUT ROWID;
CREATE INDEX slice_members_record ON slice_members(workspace,member_type,member_id,slice_id);
CREATE INDEX slice_members_edge ON slice_members(workspace,edge_id);
CREATE INDEX slice_members_age ON slice_members(workspace,slice_id,active_at) WHERE active_at IS NOT NULL;
CREATE INDEX slice_members_movement ON slice_members(workspace,slice_id,moved DESC);
CREATE TABLE slice_summaries (
 workspace BLOB NOT NULL, slice_id BLOB NOT NULL,
 backlog INTEGER NOT NULL DEFAULT 0, todo INTEGER NOT NULL DEFAULT 0,
 in_progress INTEGER NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0,
 blocked INTEGER NOT NULL DEFAULT 0, notes INTEGER NOT NULL DEFAULT 0,
 files INTEGER NOT NULL DEFAULT 0, tickets INTEGER NOT NULL DEFAULT 0,
 work INTEGER NOT NULL DEFAULT 0, oldest INTEGER NOT NULL DEFAULT 0,
 last_moved INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(workspace,slice_id)
) STRICT, WITHOUT ROWID;
CREATE TABLE slice_projects (
 workspace BLOB NOT NULL, slice_id BLOB NOT NULL, project BLOB NOT NULL,
 refs INTEGER NOT NULL,
 PRIMARY KEY(workspace,slice_id,project)
) STRICT, WITHOUT ROWID;
CREATE INDEX slice_projects_filter ON slice_projects(workspace,project,slice_id);
CREATE TABLE task_slice_coverage (
 workspace BLOB NOT NULL, task_id BLOB NOT NULL, status INTEGER NOT NULL, refs INTEGER NOT NULL,
 PRIMARY KEY(workspace,task_id)
) STRICT, WITHOUT ROWID;
CREATE TABLE workspace_task_counts (
 workspace BLOB NOT NULL, status INTEGER NOT NULL, total INTEGER NOT NULL DEFAULT 0,
 covered INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(workspace,status)
) STRICT, WITHOUT ROWID;

CREATE TRIGGER slice_task_insert AFTER INSERT ON tasks BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,2,NEW.id) ON CONFLICT DO NOTHING;
 INSERT INTO workspace_task_counts(workspace,status,total) VALUES(NEW.workspace,NEW.status,1)
 ON CONFLICT(workspace,status) DO UPDATE SET total=total+1;
END;
CREATE TRIGGER slice_task_update AFTER UPDATE OF status,blocked_by,created_at,updated_at,project ON tasks BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,2,NEW.id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_task_status AFTER UPDATE OF status ON tasks WHEN OLD.status!=NEW.status BEGIN
 UPDATE workspace_task_counts SET total=total-1 WHERE workspace=OLD.workspace AND status=OLD.status;
 INSERT INTO workspace_task_counts(workspace,status,total) VALUES(NEW.workspace,NEW.status,1)
 ON CONFLICT(workspace,status) DO UPDATE SET total=total+1;
END;
CREATE TRIGGER slice_task_delete AFTER DELETE ON tasks BEGIN
 INSERT INTO slice_pending VALUES(OLD.workspace,2,OLD.id) ON CONFLICT DO NOTHING;
 UPDATE workspace_task_counts SET total=total-1 WHERE workspace=OLD.workspace AND status=OLD.status;
END;
CREATE TRIGGER slice_asset_insert AFTER INSERT ON assets BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,1,NEW.id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_asset_update AFTER UPDATE OF asset_type,updated_at ON assets BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,1,NEW.id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_asset_delete AFTER DELETE ON assets BEGIN
 INSERT INTO slice_pending VALUES(OLD.workspace,1,OLD.id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_note_insert AFTER INSERT ON note_metadata BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,1,NEW.asset_id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_note_update AFTER UPDATE OF project,updated_at ON note_metadata BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,1,NEW.asset_id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_note_delete AFTER DELETE ON note_metadata BEGIN
 INSERT INTO slice_pending VALUES(OLD.workspace,1,OLD.asset_id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_metadata_insert AFTER INSERT ON slice_metadata BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,4,NEW.asset_id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_metadata_delete AFTER DELETE ON slice_metadata BEGIN
 INSERT INTO slice_pending VALUES(OLD.workspace,4,OLD.asset_id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_edge_insert AFTER INSERT ON edges WHEN NEW.relation=7 BEGIN
 INSERT INTO slice_pending VALUES(NEW.workspace,3,NEW.id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_edge_delete AFTER DELETE ON edges WHEN OLD.relation=7 BEGIN
 INSERT INTO slice_pending VALUES(OLD.workspace,3,OLD.id) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER slice_edge_update AFTER UPDATE OF source_type,source_id,target_type,target_id,relation ON edges BEGIN
 INSERT INTO slice_pending SELECT OLD.workspace,3,OLD.id WHERE OLD.relation=7 ON CONFLICT DO NOTHING;
 INSERT INTO slice_pending SELECT NEW.workspace,3,NEW.id WHERE NEW.relation=7 ON CONFLICT DO NOTHING;
END;

INSERT INTO workspace_task_counts(workspace,status,total) SELECT workspace,status,count(*) FROM tasks GROUP BY workspace,status;
INSERT INTO slice_pending SELECT workspace,3,id FROM edges WHERE relation=7;
INSERT INTO slice_pending SELECT workspace,4,asset_id FROM slice_metadata;
PRAGMA user_version=3;
