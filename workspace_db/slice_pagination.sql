-- Explicit offline schema 3 -> 4 migration. Finalize pending projections first.
CREATE TEMP TABLE nrc_slice_v4_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_slice_v4_guard SELECT application_id=0x4e524351 AND user_version=3
 AND NOT EXISTS(SELECT 1 FROM slice_pending) FROM pragma_application_id,pragma_user_version;
DROP TABLE nrc_slice_v4_guard;
ALTER TABLE slice_metadata ADD COLUMN sort_at INTEGER NOT NULL DEFAULT 0;
UPDATE slice_metadata AS m SET sort_at=max(
 (SELECT created_at FROM assets WHERE workspace=m.workspace AND id=m.asset_id),
 coalesce((SELECT last_moved FROM slice_summaries WHERE workspace=m.workspace AND slice_id=m.asset_id),0));
CREATE INDEX slice_page ON slice_metadata(workspace,closed,sort_at DESC,asset_id);
CREATE INDEX slice_owner_page ON slice_metadata(workspace,owner,closed,sort_at DESC,asset_id);
CREATE TRIGGER slice_order_metadata AFTER INSERT ON slice_metadata BEGIN
 UPDATE slice_metadata SET sort_at=max(
 (SELECT created_at FROM assets WHERE workspace=NEW.workspace AND id=NEW.asset_id),
 coalesce((SELECT last_moved FROM slice_summaries WHERE workspace=NEW.workspace AND slice_id=NEW.asset_id),0))
 WHERE workspace=NEW.workspace AND asset_id=NEW.asset_id;
END;
CREATE TRIGGER slice_order_summary_insert AFTER INSERT ON slice_summaries BEGIN
 UPDATE slice_metadata SET sort_at=max(
 (SELECT created_at FROM assets WHERE workspace=NEW.workspace AND id=NEW.slice_id),NEW.last_moved)
 WHERE workspace=NEW.workspace AND asset_id=NEW.slice_id;
END;
CREATE TRIGGER slice_order_summary_update AFTER UPDATE OF last_moved ON slice_summaries
 WHEN OLD.last_moved!=NEW.last_moved BEGIN
 UPDATE slice_metadata SET sort_at=max(
 (SELECT created_at FROM assets WHERE workspace=NEW.workspace AND id=NEW.slice_id),NEW.last_moved)
 WHERE workspace=NEW.workspace AND asset_id=NEW.slice_id;
END;
CREATE TRIGGER slice_order_created AFTER UPDATE OF created_at ON assets
 WHEN OLD.created_at!=NEW.created_at BEGIN
 UPDATE slice_metadata SET sort_at=max(NEW.created_at,
 coalesce((SELECT last_moved FROM slice_summaries WHERE workspace=NEW.workspace AND slice_id=NEW.id),0))
 WHERE workspace=NEW.workspace AND asset_id=NEW.id;
END;
PRAGMA user_version=4;
