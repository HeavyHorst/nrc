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

```bash
# Replace prepared content.
nrc note update 123 --content-file /tmp/nrc-note.md

# Update only the title; omitted content and project remain unchanged.
nrc note update 123 --title "Decision: revised title"

# Update only the project.
nrc note update 123 --project "heavyhorst/nrc"

# Update title and content together.
nrc note update 123 \
  --title "Decision: revised title" \
  --content-file /tmp/nrc-note.md
```

For attachment replacement/removal/download, patch diagnostics, backups, and revert commands, read `operations.md` only when needed.

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
