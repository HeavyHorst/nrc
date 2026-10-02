# NRC Memory Graph Reference

Read this reference when a memory task needs exact edge filtering, multi-hop traversal, shortest paths, hub ranking, or shared-neighbor analysis.

## Direct Edges

Edge endpoint types are only `asset` and `task`. Notes are assets, so use `asset` for note IDs; do not use `note` as an endpoint type.

```bash
# Outgoing edges from a note.
nrc edge list --source-type asset --source-id <note-id>

# Incoming edges to a note.
nrc edge list --target-type asset --target-id <note-id>

# One specific directed note-to-note edge.
nrc edge list \
  --source-type asset --source-id <from-note-id> \
  --target-type asset --target-id <to-note-id>

# Outgoing or incoming task edges.
nrc edge list --source-type task --source-id <task-id>
nrc edge list --target-type task --target-id <task-id>
```

Create an edge only after verifying both endpoints and orientation:

```bash
nrc edge create \
  --source-type asset --source-id 123 \
  --target-type task --target-id 42 \
  --relation references
```

## Traversal And Paths

Use `nrc graph walk` for multi-hop traversal or relation-limited expansion. Use `nrc graph path` for the shortest path between known endpoints. Direction is semantic: use `both` for neighborhood discovery, and `outgoing` or `incoming` only when edge orientation is part of the question.

```bash
nrc graph walk \
  --start-type task --start-id 42 \
  --depth 2 --relation depends-on,blocks
```

## Degree Ranking

Use `nrc graph degree` to identify highly connected nodes without downloading and ranking every edge locally:

```bash
# Most connected assets and tasks across all relation types.
nrc graph degree --top 10 --type all

# Notes/assets with the most incoming or outgoing references combined.
nrc graph degree --top 10 --type assets --relation references

# Tasks participating in the most blocking relationships.
nrc graph degree --top 10 --type tasks --relation blocks,depends-on
```

Degree counts matching incident edges in both directions; it does not distinguish incoming from outgoing edges. Treat the result as a discovery aid, not proof that a node is authoritative or currently blocking work. Load selected nodes and inspect directed edges before making semantic claims.

## Common Neighbors

Use `nrc graph common` when two known assets or tasks may share context. It performs the neighbor-set intersection on the server and returns the shared nodes plus connecting edges.

```bash
# Shared context around a task and a note.
nrc graph common \
  --a-type task --a-id 42 \
  --b-type asset --b-id 123

# Shared outgoing dependencies between two tasks.
nrc graph common \
  --a-type task --a-id 42 \
  --b-type task --b-id 77 \
  --direction outgoing --relation depends-on
```

Use `--direction both` unless orientation is part of the question. With `outgoing` or `incoming`, direction is evaluated from each queried endpoint. Explain relevance from the returned edges, not node overlap alone. `nrc graph common-neighbors` is an equivalent alias for `nrc graph common`.
