-- Explicit offline migration. Rebuild existing ticket documents with the projection builder.
CREATE TEMP TABLE ticket_v9_guard(ok INTEGER CHECK(ok=1));
INSERT INTO ticket_v9_guard SELECT application_id=0x4e524351 AND user_version=8 FROM pragma_application_id,pragma_user_version;
DROP TABLE ticket_v9_guard;
CREATE TABLE ticket_search_backfill(required INTEGER PRIMARY KEY CHECK(required=1));
INSERT INTO ticket_search_backfill SELECT 1 WHERE EXISTS(SELECT 1 FROM ticket_metadata) OR EXISTS(SELECT 1 FROM ticket_entry_metadata);
CREATE TABLE ticket_search_docs(
 docid INTEGER PRIMARY KEY, workspace BLOB NOT NULL, asset_id BLOB NOT NULL, ticket_id BLOB NOT NULL,
 UNIQUE(workspace,asset_id), FOREIGN KEY(workspace,asset_id) REFERENCES assets(workspace,id) ON DELETE CASCADE
) STRICT;
CREATE VIRTUAL TABLE ticket_trigrams USING fts5(fields,body, tokenize='trigram case_sensitive 1',columnsize=0);
CREATE TRIGGER ticket_doc_delete AFTER DELETE ON ticket_search_docs BEGIN
 DELETE FROM ticket_trigrams WHERE rowid=OLD.docid;
END;
CREATE TRIGGER ticket_search_delete AFTER DELETE ON ticket_metadata BEGIN
 DELETE FROM ticket_search_docs WHERE workspace=OLD.workspace AND asset_id=OLD.asset_id;
END;
CREATE TRIGGER ticket_entry_search_delete AFTER DELETE ON ticket_entry_metadata BEGIN
 DELETE FROM ticket_search_docs WHERE workspace=OLD.workspace AND asset_id=OLD.asset_id;
END;
PRAGMA user_version=9;
