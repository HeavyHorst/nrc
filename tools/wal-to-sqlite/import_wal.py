#!/usr/bin/env python3
"""Explicit, non-activating offline import. See README.md before running."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile

import legacy as old


CANONICAL = ("sequences", "tasks", "task_attachments", "assets", "asset_attachments",
             "edges", "dm_conversations", "history_sequences", "history",
             "monitor_instances", "monitor_episodes", "monitor_runs", "monitor_actions", "incident_actions",
             "monitor_queue_usage", "monitor_deliveries", "monitor_delivery_receipts", "monitor_delivery_lanes")
SCHEMA = Path(__file__).with_name("schema.sql")
SLICE_SCHEMA = Path(__file__).with_name("slice_summaries.sql")
INCREMENTAL_SCHEMA = Path(__file__).with_name("slice_incremental.sql")
PAGINATION_SCHEMA = Path(__file__).with_name("slice_pagination.sql")
MONITORING_SCHEMA = Path(__file__).with_name("monitoring.sql")
CHRONICLE_SCHEMA = Path(__file__).with_name("chronicle.sql")
CHRONICLE_INPUT_BUDGET_SCHEMA = Path(__file__).with_name("chronicle_input_budget.sql")
SCHEMA_VERSION = 7


def schema_text():
    return (SCHEMA.read_text() + SLICE_SCHEMA.read_text() + INCREMENTAL_SCHEMA.read_text()
            + PAGINATION_SCHEMA.read_text() + MONITORING_SCHEMA.read_text() + CHRONICLE_SCHEMA.read_text()
            + CHRONICLE_INPUT_BUDGET_SCHEMA.read_text())


def schema_hash():
    return hashlib.sha256(schema_text().encode()).hexdigest()


def put(db, table, row, keys):
    columns = list(row)
    updates = ",".join(f"{c}=excluded.{c}" for c in columns if c not in keys)
    db.execute(f"INSERT INTO {table} ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)}) "
               f"ON CONFLICT ({','.join(keys)}) DO UPDATE SET {updates}", list(row.values()))


class AssetValidation:
    """Disk-backed intermediate images; no historical image may evade Odin validation."""
    def __init__(self, path, schema):
        self.path, self.schema, self.db, self.count = path, schema, None, 0

    def add(self, row):
        if row["asset_type"] not in (12, 13, 14):
            return
        if self.db is None:
            self.db = sqlite3.connect(self.path)
            self.db.executescript("PRAGMA cache_size=-1024; PRAGMA temp_store=FILE;" + self.schema)
        self.count += 1
        # Only the scratch workspace changes. The validators depend on the exact
        # asset type, parent, encoding/raw length, preview and payload, not workspace.
        candidate = dict(row, workspace=b"mutation-validation-" + old.ident(self.count))
        candidate.pop("scope")
        put(self.db, "assets", candidate, ("workspace", "id"))
        if self.count % 1000 == 0:
            self.db.commit()

    def finish(self, builder):
        if self.db is not None:
            self.db.commit()
            self.close()
            subprocess.run([str(builder), str(self.path)], check=True)
            for suffix in ("", "-wal", "-shm", "-journal"):
                Path(str(self.path) + suffix).unlink(missing_ok=True)

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None


def check_legacy_scope(db, workspace, domain, entity, raw):
    if uint := old.uint(raw):
        old.require(not uint & old.DM_FLAG,
                    "legacy DM-scoped task/asset/edge cannot be imported as a workspace record")
        previous = db.execute("SELECT room FROM replay_origins WHERE workspace=? AND domain=? AND id=?",
                              (workspace, domain, entity)).fetchone()
        old.require(previous is None or previous[0] == raw, "conflicting legacy public room origins")
        db.execute("INSERT OR IGNORE INTO replay_origins VALUES (?,?,?,?)", (workspace, domain, entity, raw))


def replay(db, payload, shard, previous, validation):
    r = old.Reader(payload)
    workspace = r.blob()
    old.require(workspace and old.xx(workspace) % 256 == shard, "transaction workspace/shard")
    floors = [r.n(8) for _ in range(3)]
    count, reserved = r.n(4), r.n(4)
    old.require(count <= 65535 and reserved == 0 and all(a >= b for a, b in zip(floors, previous)), "transaction header/floors")
    required = [0, 0, 0]
    for _ in range(count):
        domain, op, version = r.n(1), r.n(1), r.n(2)
        data = r.take(r.n(4))
        supported = (domain == 1 and version == 1 and 1 <= op <= 4 or
                     domain == 2 and 1 <= version <= 3 and 1 <= op <= 3 or
                     domain == 3 and version == 1 and op in (1, 2) or
                     domain in (4, 5) and version == 1 and op == 1)
        old.require(supported, "unsupported mutation")
        if domain <= 3:
            table = ("tasks", "assets", "edges")[domain - 1]
            deleting = op == (4, 3, 2)[domain - 1]
            attached = []
            if deleting:
                old.require(len(data) == 16 and data[8:] != old.ZERO, "delete identity")
                row = dict(scope=data[:8], id=data[8:])
            elif domain == 1:
                row, attached, refs = old.task(data)
                required[0] = max(required[0], *refs)
            elif domain == 2:
                row, attached = old.asset(data, version)
                validation.add(row)
                # Match parse_asset_from_payload after validating the raw image.
                if row["payload_raw_len"] == 0:
                    row["payload_raw_len"] = len(row["payload"])
                parent = row["parent_type"]
                if parent:
                    required[parent - 1] = max(required[parent - 1], old.uint(row["parent_id"]))
            else:
                row = old.edge(data)
                for side in ("source", "target"):
                    index = 1 if row[side + "_type"] == 1 else 0
                    required[index] = max(required[index], old.uint(row[side + "_id"]))
            required[domain - 1] = max(required[domain - 1], old.uint(row["id"]))
            check_legacy_scope(db, workspace, domain, row["id"], row.pop("scope"))
            row["workspace"] = workspace
            key = (workspace, row["id"])
            if deleting:
                db.execute(f"DELETE FROM {table} WHERE workspace=? AND id=?", key)
            else:
                put(db, table, row, ("workspace", "id"))
                if domain in (1, 2):
                    singular = "task" if domain == 1 else "asset"
                    attachment_table = singular + "_attachments"
                    db.execute(f"DELETE FROM {attachment_table} WHERE workspace=? AND {singular}_id=?", key)
                    db.executemany(f"INSERT INTO {attachment_table} VALUES (?,?,?,?,?,?,?,?)",
                                   (key + (ordinal,) + item for ordinal, item in enumerate(attached)))
        elif domain == 4:
            row = old.dm(data)
            row["workspace"] = workspace
            prior = db.execute("SELECT user_a,user_b FROM dm_conversations WHERE workspace=? AND id=?",
                               (workspace, row["id"])).fetchone()
            old.require(prior is None or prior == (row["user_a"], row["user_b"]), "conflicting DM identity")
            put(db, "dm_conversations", row, ("workspace", "id"))
        else:
            row = old.history(data)
            row["workspace"] = workspace
            prior = db.execute(f"SELECT {','.join(row)} FROM history WHERE workspace=? AND id=?",
                               (workspace, row["id"])).fetchone()
            old.require(prior is None or prior == tuple(row.values()), "conflicting immutable history event")
            high = db.execute("SELECT high_water FROM history_sequences WHERE workspace=?", (workspace,)).fetchone()
            old.require(prior is not None or high is None or row["id"] > high[0], "out-of-order history event")
            if prior is None:
                put(db, "history", row, ("workspace", "id"))
                put(db, "history_sequences", dict(workspace=workspace, high_water=row["id"]), ("workspace",))
    r.done()
    old.require(all(a >= b for a, b in zip(floors, required)), "transaction floor below referenced ID")
    for domain, floor in zip(("task", "asset", "edge"), floors):
        db.execute("UPDATE sequences SET high_water=? WHERE domain=?", (old.ident(floor), domain))
    return floors


def canonical_digest(db):
    """Stable, typed, streaming digest: never fetch a workspace into RAM."""
    digest = hashlib.sha256()
    counts = {}
    for table in CANONICAL:
        digest.update(table.encode() + b"\0")
        columns = db.execute(f"PRAGMA table_info({table})").fetchall()
        order = ",".join(column[1] for column in sorted(columns, key=lambda c: c[5]) if column[5])
        counts[table] = 0
        for row in db.execute(f"SELECT * FROM {table} ORDER BY {order}"):
            counts[table] += 1
            digest.update(b"R")
            for value in row:
                if isinstance(value, bytes):
                    tag, encoded = b"B", value
                elif isinstance(value, str):
                    tag, encoded = b"T", value.encode()
                elif isinstance(value, int):
                    tag, encoded = b"I", str(value).encode()
                else:
                    raise ValueError("unexpected canonical SQL type")
                digest.update(tag + len(encoded).to_bytes(8, "big") + encoded)
    return digest.hexdigest(), counts


def verify(db):
    old.require(db.execute("PRAGMA application_id").fetchone() == (0x4E524351,), "application ID")
    old.require(db.execute("PRAGMA user_version").fetchone() == (SCHEMA_VERSION,), "schema version")
    old.require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "SQLite integrity check")
    old.require(not db.execute("PRAGMA foreign_key_check").fetchall(), "SQLite foreign key check")


def sha_file(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(source):
    result = {}
    def fail(error):
        raise error
    for base, directories, files in os.walk(source, followlinks=False, onerror=fail):
        for name in sorted(directories + files):
            path = Path(base) / name
            mode = path.lstat().st_mode
            old.require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), "source contains symlink or special file")
            if stat.S_ISREG(mode):
                result[str(path.relative_to(source))] = sha_file(path)
    return result


def fsync_path(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish(staging, target, completion_files=("IMPORT_COMPLETE.json",)):
    # Linux atomic no-replace rename: a racing target must never be overwritten.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(staging), -100, os.fsencode(target), 1) != 0:
        raise OSError(ctypes.get_errno(), "cannot publish target without replacement")
    try:
        fsync_path(target.parent)
    except OSError:
        # Persist invalidation too: a crash must not resurrect the startup marker.
        try:
            for name in completion_files:
                (target / name).unlink(missing_ok=True)
            fsync_path(target)
        except OSError as cleanup_error:
            raise OSError(f"Publication state indeterminate at {target}; inspect it before use: "
                          f"could not durably invalidate completion files: {cleanup_error}") from cleanup_error
        raise


def import_directory(source, target, builder):
    source, target, builder = Path(source).absolute(), Path(target).absolute(), Path(builder).absolute()
    old.require(source.is_dir() and not source.is_symlink(), "source must be a real directory")
    source = source.resolve(strict=True)
    old.require(target.parent.is_dir(), "target parent must exist")
    target = target.parent.resolve(strict=True) / target.name
    old.require(not target.exists() and not target.is_symlink(), "target already exists")
    old.require(not target.is_relative_to(source) and not source.is_relative_to(target), "source and target overlap")
    old.require(builder.is_file() and os.access(builder, os.X_OK), "projection builder missing/not executable")
    old.require(sqlite3.sqlite_version_info >= (3, 37, 0), "SQLite 3.37+ required")
    # An existing server lock is opened read-only, never created or rewritten.
    lock_fd = os.open(source / "storage-layout.lock", os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = inventory(source)
        generation = old.layout(old.read_metadata(source / "storage-layout.manifest", 40))
        generation_dir = source / f"sharded-{generation:020d}"
        old.require(generation_dir.is_dir(), "missing source generation")
        staging = Path(tempfile.mkdtemp(prefix=f".{target.name}.incomplete-", dir=target.parent))
        try:
            report = dict(format="nrc-wal-to-sqlite-v1", status="verified-not-activated", schema_version=SCHEMA_VERSION,
                          application_id="0x4e524351", source_generation=generation,
                          retained_message_generation=generation, source_sha256=before,
                          schema_sha256=schema_hash(), projection_builder_sha256=sha_file(builder), shards=[])
            schema = schema_text()
            for shard in range(256):
                directory = generation_dir / f"shard_{shard:03d}"
                old.require(directory.is_dir(), f"missing shard directory {shard}")
                paths = old.sequence(directory, shard)
                # Missing files are errors even for empty shards.
                occupied = any(path.stat().st_size for path in paths)
                if not occupied:
                    continue
                path = staging / f"shard_{shard:03d}.sqlite3"
                validation = AssetValidation(staging / ".mutation-validation.sqlite3", schema)
                db = sqlite3.connect(path)
                try:
                    db.executescript("PRAGMA foreign_keys=OFF; PRAGMA synchronous=FULL; PRAGMA temp_store=FILE; "
                                     "PRAGMA cache_size=-1024;" + schema + ";PRAGMA foreign_keys=ON;")
                    db.execute("CREATE TEMP TABLE replay_origins (workspace BLOB, domain INTEGER, id BLOB, room BLOB, PRIMARY KEY(workspace,domain,id)) WITHOUT ROWID")
                    floors, count = [0, 0, 0], 0
                    for wal in paths:
                        for payload in old.records(wal):
                            floors = replay(db, payload, shard, floors, validation)
                            count += 1
                            # Bound the output journal; incomplete staging is never published.
                            if count % 1000 == 0:
                                db.commit()
                    db.commit()
                    verify(db)
                    expected, counts = canonical_digest(db)
                    schema_before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY name").fetchall()
                    validation.finish(builder)
                finally:
                    db.close()
                    validation.close()
                subprocess.run([str(builder), str(path)], check=True)
                db = sqlite3.connect(path)
                try:
                    verify(db)
                    old.require(canonical_digest(db) == (expected, counts), "projection builder changed canonical data")
                    old.require(db.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY name").fetchall() == schema_before,
                                "projection builder changed schema")
                    old.require(db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] == 0, "SQLite WAL checkpoint busy")
                    db.execute("PRAGMA journal_mode=DELETE")
                    projections = {name: db.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0]
                                   for (name,) in db.execute("SELECT name FROM sqlite_schema WHERE type='table'") if name not in CANONICAL}
                finally:
                    db.close()
                # Verify again through a fresh read-only handle after checkpoint/close.
                db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
                try:
                    verify(db)
                    old.require(canonical_digest(db) == (expected, counts), "reopen canonical mismatch")
                finally:
                    db.close()
                fsync_path(path)
                report["shards"].append(dict(shard=shard, file=path.name, sha256=sha_file(path),
                                             canonical_sha256=expected, records=count, counts=counts,
                                             validated_asset_images=validation.count,
                                             projections=projections, high_water=[str(floor) for floor in floors],
                                             replay_files=[str(p.relative_to(source)) for p in paths]))
            old.require(inventory(source) == before, "source changed during import")
            old.require(sha_file(builder) == report["projection_builder_sha256"], "projection builder changed during import")
            old.require(schema_hash() == report["schema_sha256"], "schema changed during import")
            completion = staging / "IMPORT_COMPLETE.json"
            completion.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            fsync_path(completion)
            fsync_path(staging)
            publish(staging, target)
            return report
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    finally:
        os.close(lock_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path, help="must not exist; never activated")
    parser.add_argument("--projection-builder", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = import_directory(args.source, args.target, args.projection_builder)
    except (OSError, ValueError, sqlite3.Error, subprocess.CalledProcessError) as exc:
        print(f"Import failed; no activation performed: {exc}", file=sys.stderr)
        return 1
    print(f"Verified {len(report['shards'])} shards; NOT ACTIVATED. Report: {args.target / 'IMPORT_COMPLETE.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
