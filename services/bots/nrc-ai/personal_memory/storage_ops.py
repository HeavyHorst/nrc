#!/usr/bin/env python3
"""Local SQLite snapshot/verification and offline, safety-reconciled restore.

Never starts/stops services or replaces a source. See STORAGE_OPERATIONS.md.
"""
import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import sqlite3
import tempfile


def private(path):
    path = Path(path).absolute()
    if path.is_symlink() or not path.is_file():
        raise ValueError("source must be a regular, non-symlink file")
    if path.stat().st_mode & 0o077 or path.parent.stat().st_mode & 0o077:
        raise ValueError("source and parent must be private (0600/0700)")
    return path


def connect(path):
    return sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)


def verify(db):
    if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise ValueError("SQLite integrity check failed")
    if db.execute("PRAGMA foreign_key_check").fetchall():
        raise ValueError("foreign key check failed")
    identity = db.execute("SELECT id FROM storage_identity").fetchall()
    if len(identity) != 1:
        raise ValueError("missing storage lineage")
    for table in ("segments", "nodes", "originals_fts", "runs", "receipts", "retention"):
        db.execute(f"SELECT count(*) FROM {table}").fetchone()
    return identity


@contextlib.contextmanager
def offline(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def reconcile(db, latest):
    db.execute("ATTACH DATABASE ? AS safety", (latest.as_uri() + "?mode=ro",))
    if db.execute("SELECT id FROM storage_identity").fetchall() != db.execute("SELECT id FROM safety.storage_identity").fetchall():
        raise ValueError("different storage lineage")
    # These checks detect an accidentally older or divergent safety source, not
    # loss of the newest copy. The operator must attest source freshness.
    checks = [
        "SELECT 1 FROM retention b LEFT JOIN safety.retention s USING(owner,workspace) WHERE s.owner IS NULL OR s.revision<b.revision OR s.epoch<b.epoch",
        "SELECT 1 FROM segments b LEFT JOIN safety.segments s USING(owner,workspace,seq) WHERE s.seq IS NULL OR s.request_key!=b.request_key OR s.revision<b.revision",
        "SELECT 1 FROM receipts b LEFT JOIN safety.receipts s USING(owner,workspace,channel,session,plan,action) WHERE s.action IS NULL OR s.digest!=b.digest",
        "SELECT 1 FROM runs b LEFT JOIN safety.runs s USING(owner,workspace,channel,id) WHERE s.id IS NULL OR s.digest!=b.digest OR s.seq!=b.seq",
    ]
    for query in checks:
        if db.execute(query + " LIMIT 1").fetchone():
            raise ValueError("safety source is older or divergent")
    db.execute("PRAGMA secure_delete=ON")
    with db:
        # Keep every known segment identity, including newer captures absent
        # from this backup, but never pretend we recovered their original text.
        db.execute("INSERT OR IGNORE INTO segments SELECT owner,workspace,seq,revision,request_key,channel,'deleted','' FROM safety.segments")
        db.execute("UPDATE segments SET body='',state='deleted',revision=revision+1 WHERE EXISTS (SELECT 1 FROM safety.segments s WHERE s.owner=segments.owner AND s.workspace=segments.workspace AND s.seq=segments.seq AND s.state='deleted')")
        db.execute("DELETE FROM originals_fts")
        db.execute("INSERT INTO originals_fts SELECT owner,workspace,seq,body FROM segments WHERE state!='deleted'")
        db.execute("UPDATE segments SET revision=(SELECT revision+1 FROM safety.segments s WHERE s.owner=segments.owner AND s.workspace=segments.workspace AND s.seq=segments.seq)")
        db.execute("INSERT OR IGNORE INTO nodes SELECT owner,workspace,lo,hi,revision,'pending','','' FROM safety.nodes")
        db.execute("UPDATE nodes SET summary='',version='',state='pending',revision=revision+1")
        for table in ("memory_views", "summary_views"):
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                db.execute("DELETE FROM " + table)
        db.execute("INSERT OR REPLACE INTO scopes SELECT * FROM safety.scopes")
        db.execute("INSERT OR IGNORE INTO runs SELECT * FROM safety.runs")
        db.execute("INSERT OR REPLACE INTO receipts SELECT * FROM safety.receipts")
        # Restore is not consent to resume retention/model work. Each scope is
        # explicitly disabled, and old execution/poll tokens are invalidated.
        db.execute("INSERT OR REPLACE INTO retention(owner,workspace,epoch,enabled,revision) SELECT owner,workspace,epoch+1,0,revision+1 FROM safety.retention")
    db.execute("DETACH DATABASE safety")
    db.execute("VACUUM")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    check = sub.add_parser("verify")
    check.add_argument("source")
    snap = sub.add_parser("snapshot")
    snap.add_argument("source")
    snap.add_argument("output")
    restore = sub.add_parser("restore")
    restore.add_argument("source", help="old backup, extracted into private staging")
    restore.add_argument("latest", help="latest authoritative stopped DB, including WAL")
    restore.add_argument("output", help="NEW staged DB; never replaces a source")
    restore.add_argument("--confirm-latest-safety", action="store_true", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if sqlite3.sqlite_version_info < (3, 42, 0):
        raise ValueError("SQLite >=3.42 required for FTS5 secure deletion")
    source = private(args.source)
    with contextlib.ExitStack() as stack:
        if args.operation == "restore":
            latest = private(args.latest)
            stack.enter_context(offline(source))
            stack.enter_context(offline(latest))
            latest_db = stack.enter_context(contextlib.closing(connect(latest)))
            verify(latest_db)
        db = stack.enter_context(contextlib.closing(connect(source)))
        verify(db)
        if args.operation == "verify":
            print("SQLite integrity and personal-memory schema verified")
            return
        output = Path(args.output).absolute()
        if output.exists() or output.is_symlink() or output.parent.stat().st_mode & 0o077:
            raise ValueError("output must be new, in a private existing directory")
        fd, name = tempfile.mkstemp(prefix=".memory-staging-", dir=output.parent)
        os.close(fd)
        temp = Path(name)
        try:
            with contextlib.closing(sqlite3.connect(temp.as_uri(), uri=True)) as dest:
                db.backup(dest)
                dest.execute("PRAGMA journal_mode=DELETE")
                if args.operation == "restore":
                    reconcile(dest, latest)
                verify(dest)
            with temp.open("rb") as f:
                os.fsync(f.fileno())
            os.link(temp, output)  # Atomic no-clobber publication.
            dirfd = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
        finally:
            temp.unlink(missing_ok=True)
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(temp) + suffix).unlink(missing_ok=True)
        print("Verified private staged database created; no service or source changed")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, sqlite3.Error):
        # Paths and SQL errors may reveal private deployment metadata.
        raise SystemExit("Storage operation refused or failed; sources unchanged. Check permissions, locks, SQLite version, integrity and safety-source freshness.")
