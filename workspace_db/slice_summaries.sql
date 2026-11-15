-- Schema 1 -> 2. Run inside an explicit transaction on a stopped database.
-- These are derived records. Missing/dirty summaries are rebuilt by the reader
-- in its transaction; multiple writes to one slice only mark it dirty once.
CREATE TEMP TABLE nrc_slice_upgrade_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_slice_upgrade_guard SELECT application_id=0x4e524351 AND user_version=1
 FROM pragma_application_id,pragma_user_version;
DROP TABLE nrc_slice_upgrade_guard;
CREATE TABLE slice_summaries (
    workspace BLOB NOT NULL, slice_id BLOB NOT NULL,
    backlog INTEGER NOT NULL DEFAULT 0, todo INTEGER NOT NULL DEFAULT 0,
    in_progress INTEGER NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0,
    blocked INTEGER NOT NULL DEFAULT 0, notes INTEGER NOT NULL DEFAULT 0,
    files INTEGER NOT NULL DEFAULT 0, tickets INTEGER NOT NULL DEFAULT 0,
    oldest INTEGER NOT NULL DEFAULT 0, last_moved INTEGER NOT NULL DEFAULT 0,
    overflow INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(workspace,slice_id),
    FOREIGN KEY(workspace,slice_id) REFERENCES slice_metadata(workspace,asset_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE TABLE slice_task_members (
    workspace BLOB NOT NULL, slice_id BLOB NOT NULL, task_id BLOB NOT NULL,
    PRIMARY KEY(workspace,slice_id,task_id),
    FOREIGN KEY(workspace,slice_id) REFERENCES slice_summaries(workspace,slice_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX slice_task_coverage ON slice_task_members(workspace,task_id,slice_id);
CREATE TABLE slice_projects (
    workspace BLOB NOT NULL, slice_id BLOB NOT NULL, project BLOB NOT NULL,
    PRIMARY KEY(workspace,slice_id,project),
    FOREIGN KEY(workspace,slice_id) REFERENCES slice_summaries(workspace,slice_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

-- Record identities are immutable. Include inserts/deletes for dangling links
-- restored by import, and updated_at because it controls the register order.
CREATE TRIGGER slice_task_insert AFTER INSERT ON tasks BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=NEW.workspace AND source_type=2 AND source_id=NEW.id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=NEW.workspace AND target_type=2 AND target_id=NEW.id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_task_update AFTER UPDATE OF status,blocked_by,created_at,updated_at,project ON tasks BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=NEW.workspace AND source_type=2 AND source_id=NEW.id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=NEW.workspace AND target_type=2 AND target_id=NEW.id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_task_delete AFTER DELETE ON tasks BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=OLD.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=OLD.workspace AND source_type=2 AND source_id=OLD.id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=OLD.workspace AND target_type=2 AND target_id=OLD.id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_asset_insert AFTER INSERT ON assets BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=NEW.workspace AND source_type=1 AND source_id=NEW.id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=NEW.workspace AND target_type=1 AND target_id=NEW.id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_asset_update AFTER UPDATE OF asset_type,updated_at ON assets BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=NEW.workspace AND source_type=1 AND source_id=NEW.id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=NEW.workspace AND target_type=1 AND target_id=NEW.id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_asset_delete AFTER DELETE ON assets BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=OLD.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=OLD.workspace AND source_type=1 AND source_id=OLD.id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=OLD.workspace AND target_type=1 AND target_id=OLD.id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_note_insert AFTER INSERT ON note_metadata BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=NEW.workspace AND source_type=1 AND source_id=NEW.asset_id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=NEW.workspace AND target_type=1 AND target_id=NEW.asset_id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_note_update AFTER UPDATE OF project,updated_at ON note_metadata BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=NEW.workspace AND source_type=1 AND source_id=NEW.asset_id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=NEW.workspace AND target_type=1 AND target_id=NEW.asset_id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_note_delete AFTER DELETE ON note_metadata BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=OLD.workspace AND slice_id IN (
 SELECT target_id FROM edges INDEXED BY edges_source WHERE workspace=OLD.workspace AND source_type=1 AND source_id=OLD.asset_id AND target_type=1 AND relation=7
 UNION SELECT source_id FROM edges INDEXED BY edges_target WHERE workspace=OLD.workspace AND target_type=1 AND target_id=OLD.asset_id AND source_type=1 AND relation=7);
END;
CREATE TRIGGER slice_edge_insert AFTER INSERT ON edges WHEN NEW.relation=7 BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND
 ((NEW.source_type=1 AND slice_id=NEW.source_id) OR (NEW.target_type=1 AND slice_id=NEW.target_id));
END;
CREATE TRIGGER slice_edge_delete AFTER DELETE ON edges WHEN OLD.relation=7 BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=OLD.workspace AND
 ((OLD.source_type=1 AND slice_id=OLD.source_id) OR (OLD.target_type=1 AND slice_id=OLD.target_id));
END;
CREATE TRIGGER slice_edge_update AFTER UPDATE OF source_type,source_id,target_type,target_id,relation ON edges BEGIN
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=OLD.workspace AND OLD.relation=7 AND
 ((OLD.source_type=1 AND slice_id=OLD.source_id) OR (OLD.target_type=1 AND slice_id=OLD.target_id));
 UPDATE slice_summaries SET dirty=1 WHERE dirty=0 AND workspace=NEW.workspace AND NEW.relation=7 AND
 ((NEW.source_type=1 AND slice_id=NEW.source_id) OR (NEW.target_type=1 AND slice_id=NEW.target_id));
END;
PRAGMA user_version = 2;
