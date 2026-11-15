"""Publish a new SQLite server data directory from a verified offline import."""
import argparse
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import tempfile

import import_wal as imp
import legacy as old


def activate(source, imported, target):
    source, imported, target = map(lambda p: Path(p).absolute(), (source, imported, target))
    for directory in (source, imported):
        old.require(directory.is_dir() and not directory.is_symlink(), "input must be a real directory")
    source, imported = source.resolve(strict=True), imported.resolve(strict=True)
    target = target.parent.resolve(strict=True) / target.name
    old.require(not target.exists() and not target.is_symlink(), "target already exists")
    for a, b in ((source, imported), (source, target), (imported, target)):
        old.require(not a.is_relative_to(b) and not b.is_relative_to(a), "directories overlap")
    lock = os.open(source / "storage-layout.lock", os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        source_before, import_before = imp.inventory(source), imp.inventory(imported)
        report = json.loads((imported / "IMPORT_COMPLETE.json").read_text())
        old.require(report["format"] == "nrc-wal-to-sqlite-v1" and report["status"] == "verified-not-activated", "unverified import")
        old.require(report["schema_version"] == imp.SCHEMA_VERSION and report["schema_sha256"] == imp.schema_hash(), "schema mismatch")
        old.require(report["source_sha256"] == source_before, "source no longer matches import")
        generation = old.layout((source / "storage-layout.manifest").read_bytes())
        old.require(generation == report["source_generation"] == report["retained_message_generation"], "generation mismatch")
        shards = {}
        for entry in report["shards"]:
            shard = entry["shard"]
            old.require(type(shard) is int and 0 <= shard < 256 and shard not in shards, "invalid/duplicate shard")
            name = f"shard_{shard:03d}.sqlite3"
            old.require(entry["file"] == name and import_before.get(name) == entry["sha256"], "database hash mismatch")
            shards[shard] = name
        old.require(set(import_before) == {"IMPORT_COMPLETE.json", *shards.values()}, "unexpected import files")
        for shard in range(256):
            original = source / f"sharded-{generation:020d}" / f"shard_{shard:03d}"
            occupied = any(path.stat().st_size for path in old.sequence(original, shard))
            old.require(occupied == (shard in shards), "import shard coverage mismatch")
        staging = Path(tempfile.mkdtemp(prefix=f".{target.name}.incomplete-", dir=target.parent))
        try:
            root = staging / f"sharded-{generation:020d}"
            root.mkdir()
            for shard in range(256):
                leaf = root / f"shard_{shard:03d}"
                leaf.mkdir()
                database = leaf / "workspace.sqlite3"
                if shard in shards:
                    shutil.copyfile(imported / shards[shard], database)
                    old.require(imp.sha_file(database) == import_before[shards[shard]], "copied database hash mismatch")
                else:
                    with closing(sqlite3.connect(database)) as db:
                        db.executescript("PRAGMA synchronous=FULL;" + imp.schema_text())
                        db.commit()
                with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
                    imp.verify(db)
                messages = source / root.name / leaf.name / "messages"
                if messages.exists():
                    old.require(messages.is_dir() and not messages.is_symlink(), "invalid retained directory")
                    shutil.copytree(messages, leaf / "messages")
                    expected = {name[len(str(messages.relative_to(source))) + 1:]: digest
                                for name, digest in source_before.items()
                                if name.startswith(str(messages.relative_to(source)) + "/")}
                    old.require(imp.inventory(leaf / "messages") == expected, "retained copy mismatch")
                for base, dirs, files in os.walk(leaf, topdown=False):
                    for name in files:
                        imp.fsync_path(Path(base) / name)
                    imp.fsync_path(Path(base))
            imp.fsync_path(root)
            old.require(imp.inventory(source) == source_before, "source changed during activation")
            old.require(imp.inventory(imported) == import_before, "import changed during activation")
            old.require(imp.schema_hash() == report["schema_sha256"], "schema changed during activation")
            # Keep the frozen layout fields, changing only the backend mode and checksum.
            manifest = bytearray((source / "storage-layout.manifest").read_bytes())
            manifest[16] = 3
            manifest[32:] = struct.pack(">Q", old.xx(bytes(manifest[:32])))
            (staging / "storage-layout.lock").touch()
            (staging / "storage-layout.manifest").write_bytes(manifest)
            activation = dict(format="nrc-sqlite-activation-v1", schema_version=imp.SCHEMA_VERSION,
                              generation=generation, import_sha256=import_before["IMPORT_COMPLETE.json"],
                              source_sha256=source_before, attachments="external; not copied")
            (staging / "ACTIVATION_COMPLETE.json").write_text(json.dumps(activation, indent=2, sort_keys=True) + "\n")
            for name in ("storage-layout.lock", "storage-layout.manifest", "ACTIVATION_COMPLETE.json"):
                imp.fsync_path(staging / name)
            imp.fsync_path(staging)
            imp.publish(staging, target, ("storage-layout.manifest", "ACTIVATION_COMPLETE.json"))
            return activation
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    finally:
        os.close(lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="same offline WAL snapshot used by importer")
    parser.add_argument("--import-dir", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path, help="new server data directory; must not exist")
    args = parser.parse_args()
    try:
        activate(args.source, args.import_dir, args.target)
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
        parser.exit(1, f"Activation refused: {error}\n")
    print(f"Published SQLite data directory: {args.target}. No server started; external attachment blobs were not copied.")


if __name__ == "__main__":
    main()
