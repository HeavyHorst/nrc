-- Explicit offline schema 11 -> 12. The caller owns BEGIN IMMEDIATE/COMMIT
-- and must roll back on error. These tables are not workspace assets.
CREATE TEMP TABLE nrc_portal_v12_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_portal_v12_guard
 SELECT application_id=0x4e524351 AND user_version=11
 FROM pragma_application_id,pragma_user_version;

CREATE TABLE portal_accounts (
 workspace BLOB NOT NULL CHECK(length(workspace)>0),
 id BLOB NOT NULL CHECK(length(id)=8 AND id!=x'0000000000000000'),
 revision INTEGER NOT NULL CHECK(revision>0),
 login BLOB NOT NULL CHECK(length(login) BETWEEN 1 AND 320),
 requester BLOB NOT NULL CHECK(length(requester) BETWEEN 1 AND 320),
 name BLOB NOT NULL CHECK(length(name) BETWEEN 1 AND 256),
 company_id BLOB NOT NULL CHECK(length(company_id)=8),
 contact_id BLOB NOT NULL CHECK(length(contact_id)=8),
 password_hash BLOB NOT NULL CHECK(length(password_hash)=60),
 disabled INTEGER NOT NULL CHECK(disabled IN (0,1)),
 PRIMARY KEY(workspace,id),
 UNIQUE(workspace,login),
 UNIQUE(workspace,requester),
 CHECK(contact_id=x'0000000000000000' OR company_id!=x'0000000000000000')
) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX portal_accounts_contact ON portal_accounts(workspace,contact_id)
 WHERE contact_id!=x'0000000000000000';

CREATE TABLE portal_account_audit (
 workspace BLOB NOT NULL,
 account_id BLOB NOT NULL,
 revision INTEGER NOT NULL CHECK(revision>0),
 operation TEXT NOT NULL CHECK(operation IN ('create','import','disable','enable','reset_password')),
 actor_subject BLOB NOT NULL CHECK(length(actor_subject)>0),
 occurred_at INTEGER NOT NULL CHECK(occurred_at>0),
 PRIMARY KEY(workspace,account_id,revision),
 FOREIGN KEY(workspace,account_id) REFERENCES portal_accounts(workspace,id)
) STRICT, WITHOUT ROWID;

INSERT INTO nrc_portal_v12_guard SELECT NOT EXISTS(SELECT 1 FROM pragma_foreign_key_check);
DROP TABLE nrc_portal_v12_guard;
PRAGMA user_version=12;
