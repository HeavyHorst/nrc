"""Synthetic fixtures only. Run: python3 -m unittest discover -s tools/wal-to-sqlite -v."""
from contextlib import closing
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import import_wal as importer
import activate_import as activation
import legacy


def u(value, width=8):
    return value.to_bytes(width, "big", signed=value < 0)


def b(value):
    return u(len(value), 2) + value


def checksum(data):
    return data + u(legacy.xx(data))


def mutation(domain, op, payload, version=1):
    return struct.pack(">BBHI", domain, op, version, len(payload)) + payload


def transaction(workspace, mutations, floors=(2**64 - 1,) * 3):
    return b(workspace) + b"".join(u(n) for n in floors) + u(len(mutations), 4) + bytes(4) + b"".join(mutations)


def wal(transactions, flags=1):
    previous, result = bytes(32), b""
    for tx in transactions:
        prefix = struct.pack(">4sHBBI", b"NRCW", 1, 1, flags, len(tx)) + previous
        record = prefix + u(legacy.xx(prefix + tx, 64 if flags else 32), 8 if flags else 4) + tx
        result += record
        previous = hashlib.sha256(record).digest()
    return result


def task(identity, scope=0, fields=None):
    values = {1: u(identity), 2: u(scope), 3: b"raw\xff\x00title"}
    values.update(fields or {})
    return b"".join(bytes([tag]) + b(value) for tag, value in values.items())


ATTACHMENTS = [(b"z\xff", b"first\x00.bin", u(2**64 - 2), b"application/x-one", -10),
               (b"a", b"second", u(7), b"text/plain", 500)]


def attachments(values=ATTACHMENTS):
    return u(len(values), 2) + b"".join(b(fid) + b(name) + size + b(mime) + u(at) for fid, name, size, mime, at in values)


def asset(identity, kind=2, version=3, preview=b"preview\x00\xff", payload=b"payload\x00\xfe", encoding=0, raw_len=None, parent=(0, 0), scope=0):
    if raw_len is None:
        raw_len = len(payload)
    result = u(kind, 2) + u(identity) + u(parent[0], 2) + u(parent[1]) + b(b"owner\xff") + u(-20) + u(71) + u(scope)
    if version >= 2:
        result += bytes([encoding]) + u(raw_len, 4)
    result += b(preview) + b(payload)
    if version >= 3:
        result += attachments()
    return result


def edge(identity, source=(2, 13), target=(1, 17), relation=2, scope=0):
    return u(identity) + u(scope) + u(source[0], 2) + u(source[1]) + u(target[0], 2) + u(target[1]) + u(relation, 2) + u(-42) + b(b"creator\xff")


def dm(mask):
    identity = legacy.xx(b"alice\0bob") | (1 << 63)
    return u(identity) + b(b"alice") + b(b"bob") + bytes([mask])


def history(identity, entity=17, kind=2, owner=b"alice", **changes):
    event = dict(id=str(identity), entityId=str(entity), entityType={1: "task", 2: "asset", 3: "edge"}[kind],
                 timestamp="123", actorId="u", actorName="User", action="deleted", fields=[])
    event.update(changes)
    body = json.dumps(event, separators=(",", ": "), ensure_ascii=False).encode()
    return u(identity) + bytes([kind]) + u(entity) + bytes(18) + b(owner) + body


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source, self.target = self.root / "source", self.root / "target"
        self.source.mkdir()
        (self.source / "storage-layout.lock").touch()
        manifest = b"NRCL" + u(1, 2) + bytes(2) + u(9) + bytes([2, 1]) + bytes(6) + u(256, 4) + u(1, 2) + bytes(2)
        (self.source / "storage-layout.manifest").write_bytes(checksum(manifest))
        self.generation = self.source / f"sharded-{9:020d}"
        for shard in range(256):
            directory = self.generation / f"shard_{shard:03d}"
            directory.mkdir(parents=True)
            (directory / "active.wal").touch()
        (self.source / "retained-generation-9.bin").write_bytes(b"retained bytes must not change\0\xff")
        self.workspace = b"synthetic\xff"
        self.shard = legacy.xx(self.workspace) % 256
        self.directory = self.generation / f"shard_{self.shard:03d}"
        self.builder = self.root / "builder"
        # A no-op is intentionally only a test double, never distributed as a builder.
        self.builder.write_text("#!/bin/sh\nexit 0\n")
        self.builder.chmod(0o700)

    def write(self, mutations, **kw):
        (self.directory / "active.wal").write_bytes(wal([transaction(self.workspace, mutations, **kw)]))

    def run_import(self):
        before = importer.inventory(self.source)
        result = importer.import_directory(self.source, self.target, self.builder)
        self.assertEqual(importer.inventory(self.source), before)
        self.assertTrue((self.target / "IMPORT_COMPLETE.json").is_file())
        self.assertFalse((self.target / "storage-layout.manifest").exists())
        self.assertEqual(result["retained_message_generation"], 9)
        self.assertEqual(result["schema_version"], 4)
        self.assertEqual(json.loads((self.target / "IMPORT_COMPLETE.json").read_text())["schema_version"], 4)
        return result

    def connection(self):
        db = sqlite3.connect(self.target / f"shard_{self.shard:03d}.sqlite3")
        self.addCleanup(db.close)
        return db

    def fails_unchanged(self):
        before = importer.inventory(self.source)
        with self.assertRaises((ValueError, OSError, sqlite3.Error, subprocess.CalledProcessError)):
            importer.import_directory(self.source, self.target, self.builder)
        self.assertEqual(importer.inventory(self.source), before)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.root.glob(".target.incomplete-*")), [])

    def test_canonical_bytes_ids_attachments_history_revocation_and_deleted_floors(self):
        tid, aid, eid = 2**63 + 13, 2**63 + 17, 2**63 + 19
        fields = {4: b"desc\xfe", 5: b"\x03", 6: u(4321, 2), 7: b"assignee\xff", 8: b"\x04",
                  9: b"creator\x00", 10: u(-10), 11: u(20), 12: b"ext\x00", 13: b"\x05",
                  14: u(-30), 15: u(2**63 + 5), 16: u(40), 17: b"done\xfe", 18: attachments(), 19: b"project\xff"}
        h = history(2**63 + 100, entity=aid)
        first = [mutation(1, 1, task(tid, fields=fields)), mutation(2, 1, asset(aid), 3),
                 mutation(3, 1, edge(eid, (2, tid), (1, aid))), mutation(4, 1, dm(3)), mutation(5, 1, h)]
        last = [mutation(1, 4, u(0) + u(2**64 - 1)), mutation(2, 3, u(0) + u(2**64 - 1), 3),
                mutation(3, 2, u(0) + u(2**64 - 1)), mutation(4, 1, dm(0)), mutation(5, 1, h)]
        (self.directory / "active.wal").write_bytes(wal([transaction(self.workspace, first), transaction(self.workspace, last)]))
        result = self.run_import()
        self.assertEqual(len(result["shards"]), 1)
        db = self.connection()
        self.assertEqual(db.execute("SELECT * FROM tasks").fetchone(),
                         (self.workspace, u(tid), b"raw\xff\x00title", b"desc\xfe", 3, 4321, b"assignee\xff", 4, 5,
                          b"creator\x00", -10, 20, b"ext\x00", -30, u(2**63 + 5), 40, b"done\xfe", b"project\xff"))
        self.assertEqual(db.execute("SELECT * FROM assets").fetchone(),
                         (self.workspace, u(aid), 2, 0, u(0), b"owner\xff", -20, 71, 0, 9, b"preview\x00\xff", b"payload\x00\xfe"))
        for table in ("task_attachments", "asset_attachments"):
            self.assertEqual(db.execute(f"SELECT file_id,filename,size,mime_type,uploaded_at FROM {table} ORDER BY ordinal").fetchall(), ATTACHMENTS)
        self.assertEqual(db.execute("SELECT id,source_type,source_id,target_type,target_id,created_at,created_by FROM edges").fetchone(),
                         (u(eid), 2, u(tid), 1, u(aid), -42, b"creator\xff"))
        self.assertEqual(db.execute("SELECT members FROM dm_conversations").fetchone(), (0,))
        self.assertEqual(db.execute("SELECT high_water FROM sequences").fetchall(), [(u(2**64 - 1),)] * 3)
        self.assertEqual(db.execute("SELECT high_water FROM history_sequences").fetchone(), (u(2**63 + 100),))
        row = db.execute("SELECT id,entity_kind,entity_id,source_kind,source_id,target_kind,target_id,private_owner,body FROM history").fetchone()
        restored = row[0] + bytes([row[1]]) + row[2] + bytes([row[3]]) + row[4] + bytes([row[5]]) + row[6] + b(row[7]) + row[8]
        self.assertEqual(restored, h)

    def test_checkpoint_sealed_active_order_and_tombstones(self):
        checkpoint = wal([transaction(self.workspace, [mutation(1, 1, task(13)), mutation(1, 1, task(14))])], flags=0)
        (self.directory / f"checkpoint-{1:020d}.wal").write_bytes(checkpoint)
        (self.directory / "active.wal").write_bytes(wal([transaction(self.workspace, [mutation(1, 4, u(0) + u(13))])]))
        (self.directory / f"wal-{2:020d}.wal").write_bytes(wal([transaction(self.workspace, [mutation(1, 2, task(14, fields={3: b"new"}))])]))
        manifest = b"NRCK" + u(1, 2) + u(3, 2) + u(self.shard, 2) + bytes(6) + u(3) + u(1) + u(0) + u(2)
        (self.directory / "shard.manifest").write_bytes(checksum(manifest))
        self.run_import()
        self.assertEqual(self.connection().execute("SELECT id,title FROM tasks").fetchall(), [(u(14), b"new")])

    def test_both_catalog_versions_all_segment_kinds(self):
        for version in (1, 2):
            with self.subTest(version=version):
                target = self.root / f"target-{version}"
                names = [f"checkpoint-{1:020d}.wal", f"wal-{2:020d}.wal", f"cleaned-{3:020d}.seg", f"wal-{4:020d}.wal"]
                for i, name in enumerate(names):
                    (self.directory / name).write_bytes(wal([transaction(self.workspace, [mutation(1, 1, task(i + 1))])]))
                header = b"NRCS" + u(version, 2) + u(self.shard, 2) + u(5) + u(4, 2 if version == 1 else 4) + bytes(14 if version == 1 else 12)
                descriptors = b"".join(bytes([i]) + bytes(7) + u(i) for i in range(1, 5))
                if version == 1:
                    descriptors += bytes(60 * 16)
                (self.directory / f"catalog-{5:020d}.cat").write_bytes(checksum(header + descriptors))
                manifest = b"NRCK" + u(1, 2) + u(5, 2) + u(self.shard, 2) + bytes(6) + u(6) + u(5) + u(0) + u(0)
                (self.directory / "shard.manifest").write_bytes(checksum(manifest))
                importer.import_directory(self.source, target, self.builder)
                with closing(sqlite3.connect(target / f"shard_{self.shard:03d}.sqlite3")) as db:
                    self.assertEqual(db.execute("SELECT id FROM tasks ORDER BY id").fetchall(), [(u(i),) for i in range(1, 5)])

    def test_public_scopes_normalize_without_scope_columns(self):
        self.write([mutation(1, 1, task(13, 42)), mutation(1, 4, u(0) + u(13)),
                    mutation(1, 1, task(14, 43)), mutation(2, 1, asset(17, scope=42), 3),
                    mutation(3, 1, edge(19, scope=43)), mutation(4, 1, dm(0))])
        self.run_import()
        db = self.connection()
        self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (4,))
        for table in ("tasks", "assets", "edges", "task_attachments", "asset_attachments",
                      "room_mappings", "note_metadata", "note_tags", "reminder_metadata",
                      "appointment_metadata", "appointment_people", "slice_metadata",
                      "customer_metadata", "ticket_metadata", "ticket_entry_metadata"):
            self.assertNotIn("scope", [c[1] for c in db.execute(f"PRAGMA table_info({table})")])
        self.assertEqual(db.execute("SELECT id FROM tasks").fetchall(), [(u(14),)])
        self.assertEqual(db.execute("SELECT id FROM assets").fetchall(), [(u(17),)])
        self.assertEqual(db.execute("SELECT id FROM edges").fetchall(), [(u(19),)])
        self.assertEqual(db.execute("SELECT id,members FROM dm_conversations").fetchall(),
                         [(dm(0)[:8], 0)])

    def test_private_workspace_records_and_tombstones_are_rejected(self):
        private = legacy.xx(b"alice\0bob") | (1 << 63)
        for domain, version, image, delete_op in ((1, 1, task(13, private), 4),
                                                (2, 3, asset(13, scope=private), 3),
                                                (3, 1, edge(13, scope=private), 2)):
            for op, payload in ((1, image), (delete_op, u(private) + u(13))):
                with self.subTest(domain=domain, op=op):
                    self.write([mutation(domain, op, payload, version)])
                    self.fails_unchanged()

    def test_conflicting_room_origins_including_deleted_ids_fail(self):
        self.write([mutation(1, 1, task(13, 42)), mutation(1, 4, u(42) + u(13)), mutation(1, 1, task(13, 43))])
        self.fails_unchanged()

    def test_unordered_membership_duplicate_fails(self):
        self.write([mutation(3, 1, edge(1, (1, 17), (2, 13), 7)), mutation(3, 1, edge(2, (2, 13), (1, 17), 7))])
        self.fails_unchanged()

    def test_truncated_corrupt_chain_and_unsupported_sources_fail(self):
        valid = wal([transaction(self.workspace, [mutation(1, 1, task(13))])])
        for data in (valid[:-1], valid + b"partial", valid[:44] + bytes(8) + valid[52:], valid + valid,
                     wal([transaction(self.workspace, [mutation(9, 1, b"bad")])])):
            with self.subTest(size=len(data)):
                (self.directory / "active.wal").write_bytes(data)
                self.fails_unchanged()

    def test_floor_regression_and_below_reference_fail(self):
        for txs in ([transaction(self.workspace, [mutation(1, 1, task(13))], floors=(12, 0, 0))],
                    [transaction(self.workspace, [], floors=(99, 0, 0)), transaction(self.workspace, [], floors=(98, 0, 0))]):
            (self.directory / "active.wal").write_bytes(wal(txs))
            self.fails_unchanged()

    def test_history_workspace_local_high_water_and_conflict(self):
        # Find a second synthetic workspace in the same shard.
        other = next(f"other-{i}".encode() for i in range(100000) if legacy.xx(f"other-{i}".encode()) % 256 == self.shard)
        first = transaction(self.workspace, [mutation(5, 1, history(99))])
        second = transaction(other, [mutation(5, 1, history(2))])
        (self.directory / "active.wal").write_bytes(wal([first, second]))
        self.run_import()
        self.assertEqual(dict(self.connection().execute("SELECT workspace,high_water FROM history_sequences")), {self.workspace: u(99), other: u(2)})
        self.target = self.root / "conflict-target"
        (self.directory / "active.wal").write_bytes(wal([first, transaction(self.workspace, [mutation(5, 1, history(99, owner=b"bob"))])]))
        self.fails_unchanged()

    def test_missing_generation_or_referenced_file_fails(self):
        (self.directory / "active.wal").unlink()
        self.fails_unchanged()

    def test_corrupt_layout_fails(self):
        path = self.source / "storage-layout.manifest"
        path.write_bytes(path.read_bytes()[:-1])
        self.fails_unchanged()

    def test_lock_and_symlink_are_rejected(self):
        with (self.source / "storage-layout.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.fails_unchanged()
        (self.directory / "active.wal").unlink()
        (self.directory / "active.wal").symlink_to(self.source / "retained-generation-9.bin")
        with self.assertRaises(ValueError):
            importer.import_directory(self.source, self.target, self.builder)
        self.assertFalse(self.target.exists())

    def test_builder_failure_and_canonical_tampering_fail(self):
        self.write([mutation(1, 1, task(13))])
        self.builder.write_text("#!/bin/sh\nexit 19\n")
        self.fails_unchanged()
        self.builder.write_text(f"#!{sys.executable}\nimport sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\ndb.execute('DELETE FROM tasks')\ndb.commit()\n")
        self.fails_unchanged()
        self.builder.unlink()
        self.fails_unchanged()

    def test_existing_target_never_overwritten_and_cli_is_explicit(self):
        self.target.mkdir()
        sentinel = self.target / "keep"
        sentinel.write_bytes(b"unchanged")
        with self.assertRaises(ValueError):
            importer.import_directory(self.source, self.target, self.builder)
        self.assertEqual(sentinel.read_bytes(), b"unchanged")
        result = subprocess.run([sys.executable, str(Path(importer.__file__))], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"required", result.stderr)

    def test_cli_success_and_source_change_detection(self):
        self.write([mutation(1, 1, task(13))])
        result = subprocess.run([sys.executable, str(Path(importer.__file__)), "--source", str(self.source),
                                 "--target", str(self.target), "--projection-builder", str(self.builder)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"NOT ACTIVATED", result.stdout)
        self.target = self.root / "changed-source-target"
        # Simulate an uncooperative writer on disposable synthetic data.
        self.builder.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(self.source / 'concurrent-write')!r}).write_bytes(b'new')\n")
        with self.assertRaisesRegex(ValueError, "source changed"):
            importer.import_directory(self.source, self.target, self.builder)
        self.assertFalse(self.target.exists())

    def test_history_edge_prefix_uses_domain_kinds_not_edge_types(self):
        body = json.dumps(dict(id="41", entityId="9", entityType="edge", timestamp="99", actorId="u", actorName="U",
                               action="deleted", fields=[], sourceType="task", sourceId="13", targetType="asset", targetId="17")).encode()
        original = u(41) + b"\x03" + u(9) + b"\x01" + u(13) + b"\x02" + u(17) + b(b"") + body
        self.write([mutation(5, 1, original)])
        self.run_import()
        row = self.connection().execute("SELECT body,source_kind,source_id,target_kind,target_id FROM history").fetchone()
        self.assertEqual(row, (body, 1, u(13), 2, u(17)))

    def test_old_asset_versions_and_compressed_bytes_are_preserved(self):
        # A valid small Zstd frame for "hello" (single-segment, raw block).
        compressed = bytes.fromhex("28b52ffd200529000068656c6c6f")
        self.write([mutation(2, 1, asset(1, version=1), 1), mutation(2, 1, asset(2, version=2), 2),
                    mutation(2, 1, asset(3, encoding=1, payload=compressed, raw_len=5), 3)])
        self.run_import()
        self.assertEqual(self.connection().execute("SELECT payload_encoding,payload_raw_len,payload FROM assets WHERE id=?", (u(3),)).fetchone(), (1, 5, compressed))


class ActivationTests(unittest.TestCase):
    setUp = ImportTests.setUp
    write = ImportTests.write
    run_import = ImportTests.run_import

    def test_activation_preserves_generation_rows_and_retained_bytes(self):
        messages = self.directory / "messages"
        messages.mkdir()
        (messages / "retained-fixture").write_bytes(b"unchanged retained bytes\0\xff")
        self.write([mutation(1, 1, task(17))])
        self.run_import()
        before_source, before_import = importer.inventory(self.source), importer.inventory(self.target)
        target = self.root / "activated"
        activation.activate(self.source, self.target, target)
        self.assertEqual(importer.inventory(self.source), before_source)
        self.assertEqual(importer.inventory(self.target), before_import)
        manifest = (target / "storage-layout.manifest").read_bytes()
        self.assertEqual(manifest[16], 3)
        self.assertEqual(legacy.uint(manifest[8:16]), 9)
        self.assertEqual(legacy.uint(manifest[32:]), legacy.xx(manifest[:32]))
        root = target / self.generation.name
        self.assertEqual(len(list(root.glob("shard_*/workspace.sqlite3"))), 256)
        self.assertFalse(list(root.glob("shard_*/active.wal")))
        self.assertEqual((root / self.directory.name / "messages/retained-fixture").read_bytes(), b"unchanged retained bytes\0\xff")
        with closing(sqlite3.connect(root / self.directory.name / "workspace.sqlite3")) as db:
            self.assertEqual(db.execute("SELECT id,title FROM tasks").fetchone(), (u(17), b"raw\xff\x00title"))
        original = importer.inventory(target)
        with self.assertRaises(ValueError):
            activation.activate(self.source, self.target, target)
        self.assertEqual(importer.inventory(target), original)

    def test_activation_refuses_source_import_changes_and_source_lock(self):
        self.write([mutation(1, 1, task(17))])
        self.run_import()
        target = self.root / "activated"
        with (self.source / "storage-layout.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(OSError):
                activation.activate(self.source, self.target, target)
        source_file = self.source / "retained-generation-9.bin"
        original = source_file.read_bytes()
        source_file.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "source no longer matches"):
            activation.activate(self.source, self.target, target)
        source_file.write_bytes(original)
        database = self.target / f"shard_{self.shard:03d}.sqlite3"
        database.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "database hash"):
            activation.activate(self.source, self.target, target)
        self.assertFalse(target.exists())

    def test_activation_publication_sync_failure_invalidates_layout(self):
        self.run_import()
        target = self.root / "activated"
        real_sync = importer.fsync_path
        invalidation_synced = False
        def fail_parent(path):
            nonlocal invalidation_synced
            if path == target.parent:
                raise OSError("synthetic publication sync failure")
            if path == target:
                self.assertFalse((target / "storage-layout.manifest").exists())
                self.assertFalse((target / "ACTIVATION_COMPLETE.json").exists())
                invalidation_synced = True
            real_sync(path)
        with mock.patch.object(importer, "fsync_path", side_effect=fail_parent):
            with self.assertRaises(OSError):
                activation.activate(self.source, self.target, target)
        self.assertTrue(invalidation_synced)
        self.assertTrue(target.exists())
        self.assertFalse((target / "storage-layout.manifest").exists())
        self.assertFalse((target / "ACTIVATION_COMPLETE.json").exists())

    def test_publication_cleanup_failure_reports_indeterminate_target(self):
        for failure in ("unlink", "sync"):
            with self.subTest(failure=failure):
                staging, target = self.root / (failure + "-staging"), self.root / failure
                staging.mkdir()
                (staging / "IMPORT_COMPLETE.json").write_text("{}")
                real_unlink = Path.unlink
                def fail_unlink(path, *args, **kw):
                    if failure == "unlink" and path.parent == target:
                        raise OSError("synthetic unlink failure")
                    return real_unlink(path, *args, **kw)
                with mock.patch.object(importer, "fsync_path", side_effect=OSError("synthetic sync failure")), \
                     mock.patch.object(Path, "unlink", fail_unlink):
                    with self.assertRaisesRegex(OSError, "Publication state indeterminate") as error:
                        importer.publish(staging, target)
                self.assertIn(str(target), str(error.exception))


@unittest.skipUnless(os.environ.get("NRC_TEST_PROJECTION_BUILDER"), "set NRC_TEST_PROJECTION_BUILDER for real Odin integration")
class ProjectionTests(unittest.TestCase):
    write = ImportTests.write
    run_import = ImportTests.run_import
    connection = ImportTests.connection
    fails_unchanged = ImportTests.fails_unchanged

    def setUp(self):
        ImportTests.setUp(self)
        self.builder = Path(os.environ["NRC_TEST_PROJECTION_BUILDER"]).resolve(strict=True)

    def test_all_projection_families_with_real_builder_and_reopen(self):
        fixtures = [
            (5, b'{"project":" alpha ","tags":[" green ","green","blue"]}', b""),
            (6, b'{"visibility":"personal","title":"preview","deadline_at":"77"}', b'{"title":"payload","deadlineAt":19}'),
            (6, b'{"title":"not a fallback","deadline_at":"99"}', b'{}'),
            (11, b'{"version":1,"name":"Work","owner":"bob","closed_at":27}', b""),
            (12, b'{"version":1,"title":"Meet","start_at":"100","end_at":"200","assignee":"carol"}', b""),
            (9, b'{"version":1,"title":"Contact","email":"c@example.test","archived":false}', b""),
            (13, b'{"version":1,"title":"Ticket","assignee":"dave","status":"open","priority":"high","company_id":"","contact_id":"","requester":"","requester_name":""}', b""),
            (14, b'{"version":1,"kind":"customer_reply","author":"alice"}', b"reply"),
            (7, b" #support ", b""),
            (5, b'{"project":"must disappear","tags":[1]}', b""),
        ]
        images = [mutation(2, 1, asset(i + 1, kind, preview=preview, payload=payload,
                                     parent=(2, 7) if kind == 14 else (0, 0)), 3)
                  for i, (kind, preview, payload) in enumerate(fixtures)]
        images += [mutation(1, 1, task(4)),
                   mutation(3, 1, edge(21, source=(1, 1), target=(1, 4), relation=7)),
                   mutation(3, 1, edge(22, source=(1, 4), target=(2, 4), relation=7))]
        self.write(images)
        result = self.run_import()
        self.assertEqual(result["shards"][0]["validated_asset_images"], 3)
        self.assertEqual(sorted(p.name for p in self.target.iterdir()), ["IMPORT_COMPLETE.json", f"shard_{self.shard:03d}.sqlite3"])
        db = self.connection()
        self.assertEqual(db.execute("SELECT project FROM note_metadata WHERE asset_id=?", (u(1),)).fetchone(), (b"alpha",))
        self.assertEqual(db.execute("SELECT tag FROM note_tags ORDER BY tag").fetchall(), [(b"blue",), (b"green",)])
        self.assertEqual(db.execute("SELECT personal,deadline,title FROM reminder_metadata ORDER BY asset_id").fetchall(), [(1, 19, b"payload"), (0, 0, b"")])
        self.assertEqual(db.execute("SELECT owner,closed_at FROM slice_metadata").fetchone(), (b"bob", 27))
        self.assertEqual(db.execute("SELECT backlog,notes,oldest,last_moved FROM slice_summaries").fetchone(), (1, 1, 0, 71))
        self.assertEqual(db.execute("SELECT project,refs FROM slice_projects").fetchall(), [(b"alpha", 1)])
        self.assertEqual(db.execute("SELECT total,covered FROM workspace_task_counts WHERE status=0").fetchone(), (1, 1))
        self.assertEqual(db.execute("SELECT count(*) FROM slice_pending").fetchone(), (0,))
        self.assertEqual(db.execute("SELECT start_at,end_at FROM appointment_metadata").fetchone(), (100, 200))
        self.assertEqual(db.execute("SELECT person FROM appointment_people").fetchone(), (b"carol",))
        self.assertEqual(db.execute("SELECT active_contact,email FROM customer_metadata").fetchone(), (1, b"c@example.test"))
        self.assertEqual(db.execute("SELECT assignee,priority FROM ticket_metadata").fetchone(), (b"dave", b"high"))
        self.assertEqual(db.execute("SELECT ticket_id,kind FROM ticket_entry_metadata").fetchone(), (u(7), b"customer_reply"))
        self.assertEqual(db.execute("SELECT name FROM room_mappings").fetchone(), (b"SUPPORT",))

    def test_invalid_intermediate_images_cannot_hide_behind_delete_or_overwrite(self):
        for kind in (12, 13, 14):
            for replacement in (mutation(2, 3, u(0) + u(1), 3), mutation(2, 2, asset(1), 3)):
                with self.subTest(kind=kind, replacement=replacement[:2]):
                    self.write([mutation(2, 1, asset(1, kind, preview=b"{}", payload=b""), 3), replacement])
                    self.fails_unchanged()

    def test_duplicate_normalized_room_names_fail(self):
        self.write([mutation(2, 1, asset(1, 7, preview=b"#support", payload=b""), 3),
                    mutation(2, 1, asset(2, 7, preview=b" SUPPORT ", payload=b""), 3)])
        self.fails_unchanged()


if __name__ == "__main__":
    unittest.main()
