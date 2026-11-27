-- Explicit offline schema 12 -> 13. Schema 12 has no slice groups.
CREATE TEMP TABLE nrc_slice_groups_v13_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_slice_groups_v13_guard SELECT application_id=0x4e524351 AND user_version=12
 FROM pragma_application_id,pragma_user_version;
DROP TABLE nrc_slice_groups_v13_guard;

ALTER TABLE slice_metadata ADD COLUMN group_id BLOB NOT NULL DEFAULT x'0000000000000000' CHECK(length(group_id)=8);
CREATE INDEX slice_group_page ON slice_metadata(workspace,group_id,closed,sort_at DESC,asset_id);

-- Dissolve only projected membership; canonical slices and their edges stay put.
CREATE TRIGGER slice_group_dissolve AFTER DELETE ON assets WHEN OLD.asset_type=20 BEGIN
 UPDATE slice_metadata SET group_id=zeroblob(8) WHERE workspace=OLD.workspace AND group_id=OLD.id;
END;
PRAGMA user_version=13;
