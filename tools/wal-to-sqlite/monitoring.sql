-- Explicit offline schema 4 -> 5 migration. No runtime auto-upgrade.
CREATE TEMP TABLE nrc_monitor_v5_guard(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO nrc_monitor_v5_guard SELECT application_id=0x4e524351 AND user_version=4
 FROM pragma_application_id,pragma_user_version;
DROP TABLE nrc_monitor_v5_guard;
INSERT INTO sequences VALUES ('monitor_instance',x'0000000000000000');

-- Monitor IDs are reserved for the forthcoming Monitor asset integration.
-- Identity is the caller's canonical label encoding, never a display name.
CREATE TABLE monitor_instances (
 workspace BLOB NOT NULL CHECK(length(workspace)>0),
 id BLOB NOT NULL CHECK(length(id)=8 AND id!=zeroblob(8)),
 monitor_id BLOB NOT NULL CHECK(length(monitor_id)=8 AND monitor_id!=zeroblob(8)),
 identity BLOB NOT NULL CHECK(length(identity) BETWEEN 1 AND 4096),
 sequence BLOB NOT NULL CHECK(length(sequence)=8),
 evaluated_at INTEGER NOT NULL CHECK(evaluated_at>0),
 seen_at INTEGER NOT NULL CHECK(seen_at>=0),
 value_bits BLOB NOT NULL CHECK(length(value_bits)=8),
 has_value INTEGER NOT NULL CHECK(has_value IN (0,1)),
 observation INTEGER NOT NULL CHECK(observation BETWEEN 0 AND 4),
 freshness INTEGER NOT NULL CHECK(freshness BETWEEN 0 AND 4),
 failures INTEGER NOT NULL CHECK(failures BETWEEN 0 AND 4294967295),
 recoveries INTEGER NOT NULL CHECK(recoveries BETWEEN 0 AND 4294967295),
 missing INTEGER NOT NULL CHECK(missing BETWEEN 0 AND 4294967295),
 paused INTEGER NOT NULL CHECK(paused IN (0,1)),
 retired INTEGER NOT NULL CHECK(retired IN (0,1)),
 episode BLOB NOT NULL CHECK(length(episode)=8),
 incident_open INTEGER NOT NULL CHECK(incident_open IN (0,1)),
 receipt BLOB NOT NULL CHECK(length(receipt)=45),
 changes INTEGER NOT NULL CHECK(changes BETWEEN 0 AND 15),
 PRIMARY KEY(workspace,id),
 UNIQUE(workspace,monitor_id,identity)
) STRICT, WITHOUT ROWID;
CREATE INDEX monitor_stale ON monitor_instances(workspace,seen_at,id)
 WHERE has_value=1 AND paused=0 AND retired=0;
CREATE INDEX monitor_active ON monitor_instances(workspace,monitor_id,identity)
 WHERE paused=0 AND retired=0;
-- Instance IDs come from the shard-wide sequence. Seek through unfinished
-- freshness work without rescanning retired history or already stale rows.
CREATE INDEX monitor_maintenance ON monitor_instances(id)
 WHERE has_value=1 AND paused=0 AND retired=0 AND (freshness!=3 OR failures!=0 OR recoveries!=0);

-- Lifecycle records, not yet public Incident assets. Acknowledgment and
-- assignment belong exclusively to the forthcoming Incident asset.
CREATE TABLE monitor_episodes (
 workspace BLOB NOT NULL,
 instance_id BLOB NOT NULL,
 episode BLOB NOT NULL CHECK(length(episode)=8 AND episode!=zeroblob(8)),
 opened_at INTEGER NOT NULL CHECK(opened_at>0),
 closed_at INTEGER NOT NULL DEFAULT 0 CHECK(closed_at>=0),
 close_reason INTEGER NOT NULL DEFAULT 0 CHECK(close_reason BETWEEN 0 AND 2),
 incident_id BLOB CHECK(incident_id IS NULL OR length(incident_id)=8),
 CHECK((close_reason=0 AND closed_at=0) OR (close_reason!=0 AND closed_at>=opened_at)),
 PRIMARY KEY(workspace,instance_id,episode),
 FOREIGN KEY(workspace,incident_id) REFERENCES assets(workspace,id),
 FOREIGN KEY(workspace,instance_id) REFERENCES monitor_instances(workspace,id)
) STRICT, WITHOUT ROWID;
CREATE UNIQUE INDEX monitor_open_episode ON monitor_episodes(workspace,instance_id) WHERE close_reason=0;
CREATE UNIQUE INDEX monitor_incident_episode ON monitor_episodes(workspace,incident_id) WHERE incident_id IS NOT NULL;
CREATE TABLE monitor_runs (
 workspace BLOB NOT NULL,
 monitor_id BLOB NOT NULL CHECK(length(monitor_id)=8),
 sequence BLOB NOT NULL CHECK(length(sequence)=8),
 revision INTEGER NOT NULL CHECK(revision>0),
 evaluated_at INTEGER NOT NULL CHECK(evaluated_at>0),
 receipt BLOB NOT NULL CHECK(length(receipt) BETWEEN 27 AND 131066),
 PRIMARY KEY(workspace,monitor_id),
 FOREIGN KEY(workspace,monitor_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
-- One latest manual-action receipt per monitor, scoped to its authenticated actor.
CREATE TABLE monitor_actions (
 workspace BLOB NOT NULL,
 monitor_id BLOB NOT NULL CHECK(length(monitor_id)=8),
 revision INTEGER NOT NULL CHECK(revision>0),
 actor BLOB NOT NULL,
 subject BLOB NOT NULL,
 receipt BLOB NOT NULL CHECK(length(receipt)=25),
 PRIMARY KEY(workspace,monitor_id),
 FOREIGN KEY(workspace,monitor_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
-- Human action receipts are separate from evaluator runs and instance controls.
CREATE TABLE incident_actions (
 workspace BLOB NOT NULL,
 incident_id BLOB NOT NULL CHECK(length(incident_id)=8),
 revision INTEGER NOT NULL CHECK(revision>0),
 actor BLOB NOT NULL,
 subject BLOB NOT NULL,
 receipt BLOB NOT NULL CHECK(length(receipt) BETWEEN 19 AND 51),
 PRIMARY KEY(workspace,incident_id),
 FOREIGN KEY(workspace,incident_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
INSERT INTO sequences VALUES ('monitor_delivery',x'0000000000000000');
-- Bounded webhook outbox. Stream 1 is reserved; no measurement export stream exists.
CREATE TABLE monitor_queue_usage (
 workspace BLOB NOT NULL, stream INTEGER NOT NULL CHECK(stream=1),
 entries INTEGER NOT NULL DEFAULT 0 CHECK(entries>=0),
 bytes INTEGER NOT NULL DEFAULT 0 CHECK(bytes>=0),
 PRIMARY KEY(workspace,stream)
) STRICT, WITHOUT ROWID;
CREATE TABLE monitor_deliveries (
 workspace BLOB NOT NULL, monitor_id BLOB NOT NULL CHECK(length(monitor_id)=8),
 stream INTEGER NOT NULL CHECK(stream=1), route BLOB NOT NULL CHECK(length(route) BETWEEN 1 AND 64),
 id BLOB NOT NULL CHECK(length(id)=8), body BLOB NOT NULL CHECK(length(body) BETWEEN 1 AND 32768),
 created_at INTEGER NOT NULL CHECK(created_at>0), available_at INTEGER NOT NULL,
 lease_until INTEGER NOT NULL DEFAULT 0, generation INTEGER NOT NULL DEFAULT 0 CHECK(generation>=0),
 actor BLOB NOT NULL DEFAULT x'', subject BLOB NOT NULL DEFAULT x'',
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0), dead INTEGER NOT NULL DEFAULT 0 CHECK(dead IN (0,1)),
 sync_version INTEGER NOT NULL DEFAULT 0 CHECK(sync_version>=0),
 PRIMARY KEY(workspace,monitor_id,stream,route,id),
 FOREIGN KEY(workspace,monitor_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
CREATE TABLE monitor_delivery_receipts (
 workspace BLOB NOT NULL, monitor_id BLOB NOT NULL, stream INTEGER NOT NULL, route BLOB NOT NULL,
 id BLOB NOT NULL, generation INTEGER NOT NULL, action INTEGER NOT NULL,
 actor BLOB NOT NULL, subject BLOB NOT NULL,
 PRIMARY KEY(workspace,monitor_id,stream,route),
 FOREIGN KEY(workspace,monitor_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER monitor_queue_insert AFTER INSERT ON monitor_deliveries BEGIN
 INSERT INTO monitor_queue_usage VALUES(NEW.workspace,NEW.stream,1,length(NEW.body))
 ON CONFLICT(workspace,stream) DO UPDATE SET entries=entries+1,bytes=bytes+length(NEW.body);
 SELECT RAISE(ABORT,'monitor_queue_full') FROM monitor_queue_usage
 WHERE workspace=NEW.workspace AND stream=NEW.stream AND
 (entries>10000 OR bytes>16777216);
END;
CREATE TRIGGER monitor_queue_delete AFTER DELETE ON monitor_deliveries BEGIN
 UPDATE monitor_queue_usage SET entries=entries-1,bytes=bytes-length(OLD.body)
 WHERE workspace=OLD.workspace AND stream=OLD.stream;
END;
CREATE TRIGGER monitor_queue_immutable BEFORE UPDATE OF workspace,monitor_id,stream,route,id,body,created_at,sync_version ON monitor_deliveries BEGIN
 SELECT RAISE(ABORT,'monitor_delivery_immutable');
END;
-- Fixed loss metadata is reserved when configuration is accepted, not on overflow.
CREATE TABLE monitor_delivery_lanes (
 workspace BLOB NOT NULL, monitor_id BLOB NOT NULL, stream INTEGER NOT NULL CHECK(stream=1),
 route BLOB NOT NULL, configured INTEGER NOT NULL DEFAULT 1 CHECK(configured IN(0,1)),
 version INTEGER NOT NULL DEFAULT 0 CHECK(version>=0),
 lost INTEGER NOT NULL DEFAULT 0 CHECK(lost>=0),
 first_at INTEGER NOT NULL DEFAULT 0, last_at INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(workspace,monitor_id,stream,route),
 FOREIGN KEY(workspace,monitor_id) REFERENCES assets(workspace,id)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER monitor_lane_limit AFTER INSERT ON monitor_delivery_lanes WHEN NEW.stream=1 BEGIN
 SELECT RAISE(ABORT,'monitor_route_versions_full') WHERE
 (SELECT count(*) FROM monitor_delivery_lanes WHERE workspace=NEW.workspace AND monitor_id=NEW.monitor_id AND stream=1)>256;
END;
PRAGMA user_version=5;
