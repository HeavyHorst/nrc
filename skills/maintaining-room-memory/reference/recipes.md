# NRC Memory Command Recipes

Read this reference when exact note, project, tag, paging, or edge command syntax is needed.

## Retrieve And Load

```bash
nrc retrieve "What prior decisions and tasks affect auth retry logic?"
nrc search query --type note --top 5 --fields id,title,project,tags,teaser "auth retry logic"
nrc note get 123
```

Use filtered `search query` when only note matches are wanted or fused retrieval is unavailable.

## Update Notes

Read the note before preparing an update. Set `reviewed_updated_at` to the exact decimal `updated_at` value from that reviewed body; preserve nanosecond precision rather than converting it through a floating-point number. The following commands are alternatives, not a sequence. Apply the guard to partial metadata updates too. If it rejects a stale version, read and reconcile the new body before retrying; never substitute a newer timestamp onto an old proposal.

```bash
# Replace prepared content.
nrc note update 123 --expect-updated-at "${reviewed_updated_at:?Set the reviewed timestamp}" --content-file /tmp/nrc-note.md

# Update only the title; omitted content and project remain unchanged.
nrc note update 123 --expect-updated-at "${reviewed_updated_at:?Set the reviewed timestamp}" --title "Decision: revised title"

# Update only the project.
nrc note update 123 --expect-updated-at "${reviewed_updated_at:?Set the reviewed timestamp}" --project "heavyhorst/nrc"

# Update title and content together.
nrc note update 123 \
  --expect-updated-at "${reviewed_updated_at:?Set the reviewed timestamp}" \
  --title "Decision: revised title" \
  --content-file /tmp/nrc-note.md
```

For attachment replacement/removal/download, patch diagnostics, backups, and revert commands, read `operations.md` only when needed.

## Canonical Note Write Loop

Search before creating, load the strongest candidate, then update the canonical note or create only a distinct durable concept:

```bash
nrc search query --type note --top 5 "taskcards import logic"
nrc note get 123
```

If the reviewed note is the canonical destination, update it using its exact timestamp as described above:

```bash
nrc note update 123 --expect-updated-at "${reviewed_updated_at:?Set the reviewed timestamp}" --content-file /tmp/nrc-note.md
```

Alternatively, create a note only when no existing note covers the distinct durable concept:

```bash
nrc note create "Context: taskcards import logic" \
  --project "heavyhorst/nrc" \
  --tag import \
  --tag taskcards \
  --content-file /tmp/nrc-note.md
```

For an explicit partial metadata update to a known note ID, skip the search, but still read the note and guard the update with its reviewed timestamp; omitted fields are preserved. Prefer `note patch` for a localized content change and `note update --content-file` for an intentional replacement or substantial rewrite.

Capture the affected ID from the structured mutation result. Verify the saved content against the intended change using a complete returned payload or a direct readback; search rank alone does not establish correctness. Add deliberate edges after the note write; when several new notes/tasks and their edges form one fact, use one atomic batch.

Preserve durable source files when they matter:

```bash
nrc note create "Evidence: websocket trace" \
  --content-file /tmp/nrc-note.md \
  --attach "/tmp/trace.log,/tmp/screenshot.png"
nrc note attach 123 /tmp/diagram.pdf /tmp/error.log
```

Read `operations.md` for attachment replacement, removal, download, `att:N`, patch, backup, revert, and atomic transaction rules.

## Inspect And Create Relationships

```bash
# Walk relationships around a task.
nrc graph walk --start-type task --start-id 42 --depth 2 --relation depends-on,blocks

# List direct outgoing references from a note.
nrc edge list --source-type asset --source-id 123

# Check whether one note already references another.
nrc edge list \
  --source-type asset --source-id 123 \
  --target-type asset --target-id 456

# Connect a decision note to a task.
nrc edge create \
  --source-type asset --source-id 123 \
  --target-type task --target-id 42 \
  --relation references

# Connect one note to another.
nrc edge create \
  --source-type asset --source-id 123 \
  --target-type asset --target-id 456 \
  --relation supersedes
```

Read `graph.md` for direction, traversal, degree, and common-neighbor semantics.

## List Projects, Tags, And Notes

```bash
nrc note projects
nrc note tags
nrc note list --project Marketplace --limit 10
nrc note list --tag incident --limit 10
nrc note list --project Marketplace --page-size 10 --cursor '<next_cursor>'
nrc note list --all
```

Use `--all` only when every workspace note was explicitly requested. Do not combine it with `--limit`.
