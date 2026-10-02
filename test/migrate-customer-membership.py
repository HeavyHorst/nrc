#!/usr/bin/env python3
"""Migrate customer contact/activity membership from RelatedTo to MemberOf.

One-shot operator tool for the change that makes contact/activity membership use
the same `MemberOf` relation as work slices, in the member -> company direction.
It reads the workspace-scoped customer registers and the edge list through the
`nrc` CLI, then rewrites each company/contact or company/activity `related-to`
edge as a `member-of` edge.

Edges are rewritten in atomic transactions, each holding up to --batch-size
delete/create pairs (default 50). A transaction is all-or-nothing, so a failure
never leaves a half-migrated edge; the tool is idempotent and a rerun picks up
exactly the remaining `related-to` customer edges.

Run it only after the updated server and client are deployed, because the old
read path only recognizes `related-to` membership. Dry-run is the default; pass
`--apply` to mutate.

    nrc customer company list --all      # sanity check the target workspace first
    python3 test/migrate-customer-membership.py            # dry run
    python3 test/migrate-customer-membership.py --apply    # migrate
"""

import json
import os
import subprocess
import sys

# Point at a freshly built CLI when the installed `nrc` predates `member-of`.
NRC = os.environ.get("NRC_BIN", "nrc")
RELATED_TO = "related-to"

COMPANY = "company"
CONTACT = "contact"
ACTIVITY = "activity"

DEFAULT_BATCH_SIZE = 50


def cli_json(args):
    proc = subprocess.run([NRC, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"{NRC} {' '.join(args)} failed: {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        sys.exit(f"{NRC} {' '.join(args)} returned invalid JSON: {exc}")


def register_ids(kind):
    page = cli_json(["customer", kind, "list", "--all", "--fields", "id"])
    return {int(entry["id"]) for entry in page["entries"]}


def pending_edges(companies, members):
    pending = []
    for edge in cli_json(["edge", "list"]):
        if edge.get("relation") != RELATED_TO:
            continue
        if edge.get("source_type") != "asset" or edge.get("target_type") != "asset":
            continue
        source, target = int(edge["source_id"]), int(edge["target_id"])
        if source in companies and target in members:
            pending.append((int(edge["id"]), target, source))
        elif target in companies and source in members:
            pending.append((int(edge["id"]), source, target))
    return pending


def batch_document(chunk):
    operations = []
    for edge_id, member, company in chunk:
        operations.append({"op": "edge.delete", "id": str(edge_id)})
        operations.append(
            {
                "op": "edge.create",
                "source_type": "asset",
                "source_id": str(member),
                "target_type": "asset",
                "target_id": str(company),
                "relation": "member-of",
            }
        )
    return {"operations": operations}


def apply_chunk(chunk):
    proc = subprocess.run(
        [NRC, "batch", "apply", "--atomic"],
        input=json.dumps(batch_document(chunk)),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or '"committed":true' not in proc.stdout:
        ids = ", ".join(str(edge_id) for edge_id, _, _ in chunk)
        sys.exit(f"batch [{ids}] failed: {proc.stdout.strip()} {proc.stderr.strip()}")


def main():
    args = sys.argv[1:]
    apply = "--apply" in args
    batch_size = DEFAULT_BATCH_SIZE
    for index, value in enumerate(args):
        if value == "--batch-size" and index + 1 < len(args):
            batch_size = int(args[index + 1])
    if batch_size < 1 or batch_size * 2 > 256:
        sys.exit("--batch-size must be between 1 and 128")

    companies = register_ids(COMPANY)
    members = register_ids(CONTACT) | register_ids(ACTIVITY)
    pending = pending_edges(companies, members)

    print(f"{len(pending)} related-to customer edge(s) to migrate")
    if not apply:
        for edge_id, member, company in pending:
            print(f"dry-run edge {edge_id}: member {member} -> company {company}")
        print("dry run complete; pass --apply to migrate")
        return

    migrated = 0
    for start in range(0, len(pending), batch_size):
        chunk = pending[start : start + batch_size]
        apply_chunk(chunk)
        migrated += len(chunk)
        print(f"migrated {migrated}/{len(pending)} edge(s)")
    print(f"migration complete: {migrated} edge(s) now member-of")


if __name__ == "__main__":
    main()
