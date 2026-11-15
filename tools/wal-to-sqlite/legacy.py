"""Frozen Sharded-V1 readers; no imports from the changing NRC server.

Ported from snapshot a14a7bb5e462855a7ba810ecf830b8fc19f717be082e9fda8d0177011d6963cf.
Strictly read-only: unlike server recovery, even an incomplete tail is fatal.
"""
import ctypes
import hashlib
import json
import struct


class InvalidSource(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise InvalidSource(reason)


_xx = ctypes.CDLL("libxxhash.so.0")
for _bits, _type in ((32, ctypes.c_uint32), (64, ctypes.c_uint64)):
    _fn = getattr(_xx, f"XXH{_bits}")
    _fn.argtypes = (ctypes.c_void_p, ctypes.c_size_t, _type)
    _fn.restype = _type


def xx(data, bits=64):
    return getattr(_xx, f"XXH{bits}")(data, len(data), 0)


def uint(data):
    return int.from_bytes(data, "big")


def ident(value):
    return value.to_bytes(8, "big")


ZERO = ident(0)
DM_FLAG = 1 << 63


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, count):
        require(0 <= count <= len(self.data) - self.pos, "truncated field")
        result = self.data[self.pos:self.pos + count]
        self.pos += count
        return result

    def n(self, count, signed=False):
        return int.from_bytes(self.take(count), "big", signed=signed)

    def blob(self):
        return self.take(self.n(2))

    def done(self):
        require(self.pos == len(self.data), "trailing bytes")


def checked(data, size, magic, version=1):
    require(len(data) == size, "wrong metadata size")
    require(data[:4] == magic and uint(data[4:6]) == version, "unsupported metadata")
    require(uint(data[-8:]) == xx(data[:-8]), "metadata checksum mismatch")


def read_metadata(path, maximum):
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, "oversized metadata file")
    return data


def layout(data):
    checked(data, 40, b"NRCL")
    require(not any(data[6:8] + data[18:24] + data[30:32]), "layout reserved bytes")
    generation = uint(data[8:16])
    require(generation and data[16:18] == b"\x02\x01" and
            uint(data[24:28]) == 256 and uint(data[28:30]) == 1, "not Sharded-V1 XXH64/256")
    return generation


def wal_name(generation):
    return f"wal-{generation:020d}.wal" if generation else "active.wal"


def catalog(data, shard, generation):
    require(40 <= len(data) <= 64 * 1024 * 1024, "catalog size")
    version = uint(data[4:6])
    require(version in (1, 2), "catalog version")
    checked(data, len(data), b"NRCS", version)
    require(uint(data[6:8]) == shard and uint(data[8:16]) == generation, "catalog identity")
    count = uint(data[16:18 if version == 1 else 20])
    require(not any(data[18 if version == 1 else 20:32]), "catalog reserved bytes")
    require(len(data) == (1064 if version == 1 else 40 + 16 * count), "catalog length")
    require(version != 1 or count <= 64, "legacy catalog count")
    result = []
    for i in range(count):
        descriptor = data[32 + i * 16:48 + i * 16]
        kind, gen = descriptor[0], uint(descriptor[8:])
        require(not any(descriptor[1:8]) and kind in (1, 2, 3, 4), "catalog descriptor")
        require(kind in (2, 4) or gen != 0, "zero segment generation")
        name = (f"checkpoint-{gen:020d}.wal" if kind == 1 else
                f"cleaned-{gen:020d}.seg" if kind == 3 else wal_name(gen))
        require(name not in result, "duplicate catalog file")
        result.append(name)
    require(not any(data[32 + count * 16:-8]), "catalog padding")
    return result


def sequence(directory, shard):
    path = directory / "shard.manifest"
    if not path.exists():
        return [directory / "active.wal"]
    data = read_metadata(path, 56)
    checked(data, 56, b"NRCK")
    flags = uint(data[6:8])
    checkpoint, sealed, active = (uint(data[i:i + 8]) for i in (24, 32, 40))
    require(flags & ~7 == 0 and not any(data[10:16]), "manifest flags/reserved")
    require(uint(data[8:10]) == shard and uint(data[16:24]), "manifest identity")
    require(bool(flags & 1) == bool(checkpoint), "checkpoint presence")
    require(not flags & 4 or flags & 1, "catalog without checkpoint")
    require(flags & 2 or sealed == 0, "sealed presence")
    require(not flags & 2 or sealed != active, "sealed aliases active")
    names = []
    if flags & 4:
        names += catalog(read_metadata(directory / f"catalog-{checkpoint:020d}.cat", 64 * 1024 * 1024), shard, checkpoint)
    elif flags & 1:
        names.append(f"checkpoint-{checkpoint:020d}.wal")
    if flags & 2:
        names.append(wal_name(sealed))
    names.append(wal_name(active))
    require(len(set(names)) == len(names), "manifest references a file twice")
    return [directory / name for name in names]


def records(path):
    previous = bytes(32)
    with path.open("rb") as stream:
        while True:
            header = stream.read(48)
            if not header:
                return
            require(len(header) == 48, f"{path.name}: incomplete WAL header")
            magic, version, op, flags, size = struct.unpack(">4sHBBI", header[:12])
            require(magic == b"NRCW" and version == 1 and op == 1 and flags in (0, 1),
                    f"{path.name}: unsupported WAL header")
            require(size <= 16 * 1024 * 1024, "oversized WAL payload")
            require(header[12:44] == previous, f"{path.name}: broken SHA256 chain")
            if flags:
                header += stream.read(4)
                require(len(header) == 52, "incomplete checksum")
            payload = stream.read(size)
            require(len(payload) == size, f"{path.name}: incomplete WAL payload")
            require(uint(header[44:]) == xx(header[:44] + payload, 64 if flags else 32),
                    f"{path.name}: checksum mismatch")
            previous = hashlib.sha256(header + payload).digest()
            yield payload


def attachments(reader):
    count = reader.n(2)
    require(count <= 10, "too many attachments")
    result = []
    for _ in range(count):
        file_id, name, size, mime, uploaded = reader.blob(), reader.blob(), reader.take(8), reader.blob(), reader.n(8, True)
        require(len(file_id) <= 36 and len(name) <= 256 and len(mime) <= 128, "attachment length")
        result.append((file_id, name, size, mime, uploaded))
    return result


# tag: (SQL column, encoded width, signed integer); width None means BLOB.
TASK_FIELDS = {
    1: ("id", 8, None), 2: ("scope", 8, None), 3: ("title", None, None),
    4: ("description", None, None), 5: ("status", 1, False), 6: ("order_index", 2, False),
    7: ("assignee", None, None), 8: ("priority", 1, False), 9: ("created_by", None, None),
    10: ("created_at", 8, True), 11: ("updated_at", 8, True), 12: ("external_ref", None, None),
    13: ("color", 1, False), 14: ("due_at", 8, True), 15: ("blocked_by", 8, None),
    16: ("completed_at", 8, True), 17: ("completed_by", None, None), 19: ("project", None, None),
}


def task(data):
    r = Reader(data)
    row = {name: (0 if signed is not None else ZERO if width == 8 else b"")
           for name, width, signed in TASK_FIELDS.values()}
    seen, attached = set(), []
    while r.pos < len(data):
        tag, value = r.n(1), r.blob()
        require(1 <= tag <= 19 and tag not in seen, "unsupported/duplicate task tag")
        seen.add(tag)
        if tag == 18:
            a = Reader(value)
            attached = attachments(a)
            a.done()
        else:
            name, width, signed = TASK_FIELDS[tag]
            require(width is None or len(value) == width, "task field width")
            row[name] = int.from_bytes(value, "big", signed=signed) if signed is not None else value
    require({1, 2} <= seen and row["id"] != ZERO, "missing task identity")
    return row, attached, [uint(row["id"]), uint(row["blocked_by"])]


def asset(data, version):
    r = Reader(data)
    row = dict(asset_type=r.n(2), id=r.take(8), parent_type=r.n(2), parent_id=r.take(8),
               owner=r.blob(), created_at=r.n(8, True), updated_at=r.n(8, True), scope=r.take(8))
    require(row["id"] != ZERO and row["parent_type"] in (0, 1, 2), "asset identity/parent")
    row["payload_encoding"] = r.n(1) if version >= 2 else 0
    row["payload_raw_len"] = r.n(4) if version >= 2 else 0
    require(row["payload_encoding"] in (0, 1), "payload encoding")
    row["preview"], row["payload"] = r.blob(), r.blob()
    attached = attachments(r) if version >= 3 else []
    r.done()
    # Keep raw_len unnormalized until the original mutation has been validated.
    return row, attached


def edge(data):
    r = Reader(data)
    row = dict(id=r.take(8), scope=r.take(8), source_type=r.n(2), source_id=r.take(8),
               target_type=r.n(2), target_id=r.take(8), relation=r.n(2),
               created_at=r.n(8, True), created_by=r.blob())
    r.done()
    require(row["id"] != ZERO and row["source_type"] in (1, 2) and
            row["target_type"] in (1, 2) and 1 <= row["relation"] <= 7, "edge type/identity")
    return row


def dm(data):
    r = Reader(data)
    row = dict(id=r.take(8), user_a=r.blob(), user_b=r.blob(), members=r.n(1))
    r.done()
    a, b = row["user_a"], row["user_b"]
    require(a and b and a < b and len(a) + 1 + len(b) <= 512 and row["members"] <= 3, "DM pair/mask")
    require(uint(row["id"]) == xx(a + b"\0" + b) | DM_FLAG, "DM hash identity")
    return row


HISTORY_FIELDS = set("title description status order_index assignee priority color external_ref due_at blocked_by completed_at completed_by project attachments asset_type parent_type parent_id owner preview payload source target relation".split())


def history(data):
    require(37 < len(data) <= 65536, "history size")
    r = Reader(data)
    row = dict(id=r.take(8), entity_kind=r.n(1), entity_id=r.take(8), source_kind=r.n(1),
               source_id=r.take(8), target_kind=r.n(1), target_id=r.take(8), private_owner=r.blob())
    row["body"] = r.take(len(data) - r.pos)
    kind = row["entity_kind"]
    require(row["id"] != ZERO and row["entity_id"] != ZERO and kind in (1, 2, 3), "history identity")
    require(len(row["private_owner"]) <= 64 and (not row["private_owner"] or kind == 2), "history owner")
    try:
        event = json.loads(row["body"])
    except (ValueError, UnicodeError) as exc:
        raise InvalidSource("history JSON") from exc
    names = {0: "", 1: "task", 2: "asset", 3: "edge"}
    require(isinstance(event, dict), "history object")
    for field, blob in (("id", row["id"]), ("entityId", row["entity_id"])):
        value = event.get(field)
        require(isinstance(value, str) and value.isascii() and value.isdigit() and int(value) == uint(blob), "history JSON identity")
    timestamp = event.get("timestamp", "")
    require(isinstance(timestamp, str) and timestamp.isascii() and timestamp.isdigit() and
            0 < int(timestamp) <= (1 << 63) - 1, "history timestamp")
    require(event.get("entityType") == names[kind] and all(isinstance(event.get(f), str) and event[f] for f in ("actorId", "actorName")), "history attribution")
    require(event.get("action") in ("created", "updated", "deleted"), "history action")
    fields = event.get("fields", [])
    require(isinstance(fields, list) and len(fields) <= 32 and all(isinstance(f, str) and f in HISTORY_FIELDS for f in fields), "history fields")
    require(len(fields) == len(set(fields)) and (event["action"] != "deleted" or not fields), "history field duplicates/deletion")
    for name in ("entityLabel", "sourceLabel", "targetLabel"):
        require(isinstance(event.get(name, ""), str) and len(event.get(name, "").encode()) <= 256, "history label")
    for side in ("source", "target"):
        k, value = row[side + "_kind"], row[side + "_id"]
        require(k in (0, 1, 2), "history endpoint kind")
        if kind != 3:
            require(k == 0 and value == ZERO and not event.get(side + "Type", "") and not event.get(side + "Id", ""), "history unexpected endpoint")
        else:
            text = event.get(side + "Id", "")
            require(k != 0 and value != ZERO and event.get(side + "Type") == names[k] and
                    isinstance(text, str) and text.isascii() and text.isdigit() and int(text) == uint(value), "history edge endpoint")
    return row
