# NRC Memory Operations Reference

Read this reference only when the request needs attachment management, patch/backup mechanics, an atomic task/note/edge write, or Markdown diagrams.

## Atomic Task, Note, And Edge Writes

Use `nrc batch apply --atomic --input <file>` when related memory and graph mutations must all commit or all be rejected. A transaction accepts 1-256 operations and must fit the normal 128 KiB WebSocket request limit. Supported operations are `task.create/update/delete`, `note.create/update/delete`, `asset.create/update/delete`, and `edge.create/delete`.

This example atomically creates a task, a note parented to it, and an edge between them. Symbolic references are typed, local to this transaction, and may point forward or backward:

```json
{
  "operations": [
    {
      "op": "edge.create",
      "source_type": "note",
      "source_ref": "decision",
      "target_type": "task",
      "target_ref": "implementation",
      "relation": "references"
    },
    {
      "op": "task.create",
      "ref": "implementation",
      "title": "Implement the compaction decision",
      "project": "NRC"
    },
    {
      "op": "note.create",
      "ref": "decision",
      "title": "Decision: compaction contract",
      "project": "heavyhorst/nrc",
      "tags": ["persistence"],
      "content": "Compaction preserves the latest record for every live key.",
      "parent_type": "task",
      "parent_ref": "implementation"
    }
  ]
}
```

Use numeric `*_id` for existing parent, blocker, and edge endpoints, or symbolic `*_ref` for an entity created by this request, never both. References, parents, blockers, and edges are workspace-wide. Batch documents and operations reject `room` fields.

Supported operations and fields:

- `task.create`: required `title`; optional `description`, `project`, `status`, `priority`, `blocked_by_id` or `blocked_by_ref`
- `task.update`: required numeric `id`; one or more of `title`, `description`, `project`, `status`, `priority`, `blocked_by_id` or `blocked_by_ref`; optional `if_updated_at`
- `task.delete`: required numeric `id`; optional `if_updated_at`
- `note.create`: required `title`; optional `content`, `project`, `tags`, `format`, and a parent selected by `parent_type` plus `parent_id` or `parent_ref`
- `note.update`: required numeric `id`; one or more of `title`, `project`, `tags`, `format`, `preview`, or `content`; optional `if_updated_at`
- `note.delete`: required numeric `id`; optional `if_updated_at`
- `asset.create`: required numeric `asset_type`; optional `preview`, `content` (or `description` as a payload alias), and a parent selected by `parent_type` plus `parent_id` or `parent_ref`
- `asset.update`: required numeric `id`; one or both of `preview` and `content`; optional `if_updated_at`
- `asset.delete`: required numeric `id`; optional `if_updated_at`
- `edge.create`: required `source_type`, `target_type`, `relation`, and for each endpoint exactly one numeric `*_id` or symbolic `*_ref`; `note` is accepted as an asset endpoint alias
- `edge.delete`: required numeric `id`; edges have no `updated_at`, so `if_updated_at` is invalid

`ref` is valid only on creates. It names the created entity in the result and can be consumed by `blocked_by_ref`, `parent_ref`, `source_ref`, or `target_ref`. References are transaction-local, strongly typed, may point forward or backward, cannot be combined with the corresponding numeric ID, and cannot target update or delete operations.

Task and asset patches are partial: omitted fields are preserved. Use an explicit empty string only to clear a field that permits one, such as `project` or `description`; titles remain required. For note metadata, the CLI reads the current note, builds a complete preview, and automatically adds its `updated_at` as a compare-and-swap precondition when the caller omitted `if_updated_at`. Supply a fresh `if_updated_at` explicitly when concurrent changes must reject the whole transaction; `0` disables the precondition.

Atomic operations do not support attachments. Use ordinary attachment commands separately. Transactions also have no durable idempotency receipt.

Interpret results strictly:

- `committed:true`: every operation committed; `results` contains assigned IDs and `refs` maps symbolic names to IDs.
- `committed:false`: no operation took effect; `failed_operation` identifies the rejecting operation.
- `unknown_outcome:true`: the request transport failed and the server may have committed it. Reconcile workspace state before retrying; never blindly resend the transaction.

Without `--atomic`, `batch apply` is sequential and can partially succeed. Reserve that mode for independent operations and follow its per-result retry semantics.

## Attachments

Attachments are capped at 10 per note. `note update --attach` and `note attach` append to existing attachments.

```bash
nrc note create "Evidence: production traceback" --content-file /tmp/nrc-note.md --attach "/tmp/trace.log,/tmp/screenshot.png"
nrc note update 123 --attach "/tmp/new-debug.log"
nrc note attach 123 /tmp/diagram.pdf /tmp/error.log
nrc note replace-attachment 123 att_a1b2c3 /tmp/current-diagram.pdf
nrc note remove-attachment 123 att_d4e5f6
nrc note download-attachment 123 att_a1b2c3 /tmp/downloaded-diagram.pdf
```

- Select attachments by zero-based index or exact file ID from `note get`; prefer file IDs in automation because indexes can change after removal.
- Replace/remove operations preserve note content and metadata.
- Downloads use the original filename when the output path is omitted.
- Inspect metadata with `nrc note get 123 --fields attachments` when only attachments are needed.
- Use `att:N` in note Markdown to reference the attachment at zero-based index `N`, for example `![screenshot](att:0)` or `[trace log](att:1)`.
- When attachment membership or order changes, rewrite and verify affected `att:N` references.

## Patches And Backups

For a localized content edit, prefer a unified diff over rewriting the whole note. Use enough context for a unique hunk. A stale hunk line number is accepted when its context has one unique match; reapplying an already-applied hunk is a successful no-op.

```bash
nrc note patch 123 --dry-run <<'PATCH'
@@
-Old sentence with enough surrounding context.
+New sentence with enough surrounding context.
PATCH

nrc note patch 123 --expect-updated-at 1782920000000000000 <<'PATCH'
@@
-Old sentence with enough surrounding context.
+New sentence with enough surrounding context.
PATCH
```

Successful default JSON includes per-hunk status, resolved lines, and offsets. On no-match or ambiguity failure, the CLI currently serializes diagnostic fields such as `kind` and `candidate_lines` into the `.error.message` string; parse that string as JSON when those details are needed. Hand-written patches may match a final note line without a `\ No newline at end of file` marker.

`note update`, successful non-dry-run `note patch`, and `note revert --force` write local pre-change backups. Existing backups retain their original server/workspace/room/note scope. New backups use workspace scope 0. Never automatically reinterpret or convert a legacy room or DM backup as workspace-public memory; manually inspect its metadata and content before restoration or a separately reviewed migration.

```bash
nrc note backups 123
nrc note revert 123 --dry-run
nrc note revert 123 --backup-id 20260701T120000.000000000Z --force
```

Run revert with `--dry-run` before `--force`. Use `note update --content-file` instead of patch when intentionally replacing or substantially rewriting the whole note.

## Markdown Diagrams

Use a fenced `text` diagram only when it communicates architecture, flow, state transitions, dependencies, or graph relationships more clearly than prose. Keep it concise and grounded in known data.

- Unicode box borders `┌`, `┐`, `└`, `┘`, `─`, and `│` are allowed.
- Use only ASCII `<`, `>`, `^`, `v`, and `+` for arrowheads and junctions, with `-` and `|` for connector lines.
- Do not use Unicode arrows, triangles, emoji, rendered diagram languages, SVG, tabs, or external validators.
- Keep labels short, preserve required source-language diacritics, and pad rows so borders align.
- Every box content row must have its `│` characters in the same columns as the border corners.
- Every vertical connector, arrowhead, and junction must remain in the column of the element it connects.
- Do not mistake Markdown tables for diagrams or realign them.

````markdown
```text
┌────────┐     ┌────────────┐     ┌────────────────┐
│ Client │ --> │ NRC server │ --> │ Search sidecar │
└────────┘     └────────────┘     └────────────────┘
                   |
                   v
              ┌────────────┐
              │ AI sidecar │
              └────────────┘
```
````
