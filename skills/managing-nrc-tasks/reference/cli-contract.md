## NRC CLI Contract For Tasks

Use this reference when exact flags or JSON shapes matter.

### Global Machine Output

- Compact JSON is the default for every non-streaming command; `--human` opts into tables or prose.
- `--pretty` indents JSON documents. Streaming commands such as `chat watch` remain compact JSONL.
- `--fields <field,...>` projects object fields or each item in a collection envelope while preserving envelope metadata. It is rejected with `--human` and on mutations.
- The hidden `--json` flag is a backward-compatible alias and overrides `--human` when both are present.
- In default machine mode, ordinary failures exit nonzero, leave stdout empty, and write `{"error":{"code":"...","message":"...","retryable":false}}` to stderr. With `--human`, errors are prose. `batch apply` is the exception: its result envelope is written to stdout and rejection or partial failure exits nonzero. Always check exit status; use `pipefail` when piping output through tools such as `jq` and failure detection matters.
- `nrc capabilities` describes the visible command tree, effective flags, mutation commands, and output contract.

### Workspace Scope And Rooms

Command:

```bash
nrc room list
```

JSON shape:

```json
{
  "default_room_id": 1,
  "rooms": [
    {
      "id": 1,
      "name": "lobby",
      "label": "LOBBY",
      "is_default": true
    }
  ]
}
```

Use room commands only for chat. Every data command in this reference targets workspace scope 0 and rejects `--room`.

### Appointments

Appointments are AssetType 12 records with an empty plain payload and a version
1 JSON preview. They are separate from tasks and reminders, and CLI mutations do
not schedule notifications (notifications are browser-only behavior).

```bash
nrc appointment create "Design review" --start 2026-09-27T10:00:00+02:00 [--end 2026-09-27T11:00:00+02:00] [--description text] [--assignee name] [--project name] [--url URL]
nrc appointment list --from 2026-09-01T00:00:00Z --to 2026-11-01T00:00:00Z [--assignee name] [--project name]
nrc appointment show 42
nrc appointment update 42 [--title text] [--start time] [--end time] [--description text] [--assignee name] [--project name] [--url URL]
nrc appointment delete 42
```

`--from` is inclusive and `--to` exclusive. The bounded list range must be no
more than 62 days and all server pages are drained internally. Every time value
must be either positive absolute Unix nanoseconds or RFC3339 including `Z` or an
explicit numeric timezone offset; timezone-less local dates are rejected.
RFC3339 fractions may contain at most nine digits; invalid offsets and times
outside positive signed 64-bit nanoseconds are rejected rather than normalized.
`update` patches only explicitly supplied flags and preserves the other preview
values. Pass `--end ""`, or an empty string for another optional metadata flag,
to clear it. Default machine JSON represents `start_at` and a present `end_at`
as decimal nanosecond strings. A missing/empty end is a point appointment.

### Task List

Command:

```bash
nrc task list
```

Supported flags:

- `--human` (switches from default JSON to human-readable output)
- `--ready`
- `--blocked`
- `--project <exact-project>`
- `--status <status>` (repeat or comma-separate values)
- `--priority <0-254>`
- `--created-by <exact-creator>`
- `--title-contains <case-insensitive-substring>`

Important constraints:

- `--ready` and `--blocked` are mutually exclusive.
- There is no `--limit` flag.
- The JSON result is an object with a `tasks` field, not a top-level array.
- The CLI follows every server page internally and does not expose page cursors or page metadata.
- With no `--status`, the list includes every task status, including retained Done history. Use `--status backlog,todo,progress` for active tasks only or `--status done` for completed history.

JSON shape:

```json
{
  "tasks": [
    {
      "id": 183,
      "title": "Allow naming scenes",
      "description": "",
      "status": "backlog",
      "priority": "0",
      "project": "Meet",
      "blocked_by": 0,
      "created_by": "rene",
      "timestamp": 1745300000000000000
    }
  ]
}
```

Notes:

- `priority` is emitted as a string, not a number.
- `project` is emitted as a string and is empty when unset.
- The in-progress status is emitted as `in-progress`.
- `blocked_by` is `0` when no native blocker is set.
- Status selection is sent to the server for paged loading; the other list filters are applied by the CLI after loading the selected statuses. Combine them freely; `progress` and `in-progress` are accepted status aliases.

### Task Get

```bash
nrc task get 183
```

`task get` retrieves the exact task directly from the server, including a retained Done task that is not present in an active-only list. It returns one task object or a structured `not_found` error.

### Task Search

Use typed search for semantic task discovery, retained Done history, exact task IDs or external references, and server-side task facets:

```bash
nrc search query "pagination" --entity task --top 10
nrc search query "pagination" --entity asset,task --top 10
nrc search query "#29" --entity task --status done --task-id 29 --top 3
```

Important constraints:

- Omitting `--entity` preserves the legacy asset-only request and output contract; it does not search tasks.
- `--entity task` searches tasks, while `--entity asset,task` returns unified typed results.
- Task search includes active and Done tasks unless `--status` narrows it.
- Task facet flags include `--status`, `--assignee`, `--project`, `--priority`, `--color`, `--creator`, `--completer`, `--blocked`, `--blocked-by`, `--overdue-before`, `--task-id`, and `--external-ref`.
- `--overdue-before` accepts a positive Unix-nanosecond timestamp.

Done tasks are retained as history. Do not routinely delete them or recreate a "Clear Done" workflow; use `nrc task delete` only when the user explicitly asks to remove an individual task.

### Fused Task And Workspace Retrieval

Use fused retrieval for open-ended questions that need semantically relevant tasks and assets plus their graph-connected evidence:

```bash
nrc retrieve "What decisions and dependencies affect pagination?"
nrc retrieve "What decisions and dependency context affect the authentication rollout?" --depth 2 --relation depends-on,blocks
```

Supported flags:

- `--top <n>` (default 10; nonpositive values normalize to 10 and values above 50 are capped at 50)
- `--depth <n>` (default 1; zero normalizes to 1, values 1-4 are accepted, negative values are rejected by the CLI, and values above 4 fail)
- `--relation <relation>` (repeat or comma-separate)
- `--direction <both|outgoing|incoming>` (default `both`)
- `--no-graph` (search-only diagnostic/ablation)
- `--payload <none|top|all>` (default `top`)
- `--payload-top <n>` (default 3; number of ranked results hydrated with `--payload=top`)
- `--max-payload-bytes <n>` (default 30000; combined payload budget)
- `--paths <none|best|all>` (default `best`)

The default JSON object contains:

- `results`: ranked, best-effort hydrated task/asset evidence with `type`, `id`, `rank`, `score`, `origins`, descriptive metadata, `payload_state`, optional `payload`, and optional `evidence`
- each `evidence` entry: an anchor-to-result path with `anchor`, `depth`, and ordered edge IDs in `edges`
- `edges`: raw directed edge facts referenced by returned paths
- `graph_enabled` and `graph_contributed`: whether traversal ran and whether it contributed returned evidence
- `stale`, `truncation`, and `warnings`: conditional evidence-quality fields; absence means false/no warnings, while present values must not be silently discarded

Important constraints:

- Retrieval is workspace-scoped and requires the configured `nrc-ai` proxy endpoint.
- It searches both tasks and assets, expands from at most the strongest five search anchors, and deterministically ranks the union with search relevance plus query-personalized PageRank. There is no graph-ranking selector.
- It is bounded relevance retrieval, not an exhaustive task list, blocker set, edge audit, or shortest-path query.
- Never answer “what blocks X?” from retrieval alone; use task state and correctly oriented edges.
- Use `task get/list` for exact task state and filters. Use `graph walk/path` or `edge list` when exact traversal semantics or exhaustive relationship facts are required.
- If the endpoint is unavailable, fall back to typed `search query` and explicit graph commands rather than repeatedly retrying guessed command shapes.

Example `jq` filters:

```bash
nrc task list | jq '.tasks[] | select(.project == "Meet" or ((.project == "" or .project == null) and (.title | startswith("[Meet] "))))'
nrc task list | jq '.tasks[] | {id, title, project, status, blocked_by}'
```

### Task Create

Command:

```bash
nrc task create "Allow naming scenes" --project Meet --priority 0 --description "Detailed context"
```

Supported flags:

- `--description <text>`
- `--priority <0-254>`
- `--project <name>`
- `--attach <comma-separated-paths>`

Important constraints:

- There is no `--status` flag.
- Success is a structured mutation result containing `operation`, `resource_type`, `id`, and the created task under `resource`.

### Task Update

Command:

```bash
nrc task update 183 --status progress --project Meet --blk 170
```

Supported flags:

- `--title <text>`
- `--description <text>`
- `--status <backlog|todo|progress|done|note>`
- `--priority <0-254>`
- `--project <name>`
- `--blk <task-id|clear>`
- `--attach <comma-separated-paths>`

Important constraints:

- Success is a structured mutation result containing `operation`, `resource_type`, and `id`.
- Input accepts both `progress` and `in-progress`, but help text shows `progress`.
- Pass `--project ""` only when intentionally clearing the project field.
- Use `--blk clear` to remove a blocker.

### Slice List

A slice is an explicit work stream: an asset created by name whose members are
the tasks, notes and files assigned to it. The server reads those assignments, so
`nrc slice list` is the authoritative answer to "what work is in flight" — it is
not the CLI grouping tasks by project, and the CLI never assembles slices itself.

Command:

```bash
nrc slice list
```

Supported flags:

- `--human` (switches from default JSON to a table)
- `--include-closed`

Important constraints:

- Closed slices are excluded by default. Use `--include-closed` to see them.
- The JSON result is an object with a `slices` field, not a top-level array.
- Membership is the assignments, not the project label: a task, note or file is
  a member because it was assigned to the slice. A task can belong to several
  slices, and a slice can span projects.
- `assigned_tasks` and `unassigned_tasks` report how many tasks belong to at
  least one slice and how many belong to none, so work cannot hide behind an
  empty register.

JSON shape:

```json
{
  "slices": [
    {
      "name": "Sharded Persistence",
      "slice_id": 2,
      "closed": false,
      "owner": "rene",
      "outcome": "Restart-safe shard persistence.",
      "members": 14,
      "tasks": 11,
      "notes": 2,
      "files": 1,
      "open": 8,
      "backlog": 3,
      "todo": 2,
      "in_progress": 3,
      "done": 3,
      "blocked": 2,
      "oldest_active_at": 1789943416222892408,
      "last_moved_at": 1789943416343705336
    }
  ],
  "count": 1,
  "total_count": 7,
  "assigned_tasks": 24,
  "unassigned_tasks": 5,
  "has_more": false
}
```

Notes:

- `members` counts every member; `tasks`, `notes` and `files` are the per-kind
  counts. The register's strip is drawn from the task members.
- `open` is `backlog + todo + in_progress` and is what a slice's load is read
  from.
- `blocked` counts task members whose `blocked_by` points at another task.
- `oldest_active_at` is the `created_at` of the oldest non-Done task member, and
  `0` when every member is Done.
- `last_moved_at` is the newest `updated_at` across members.
- `outcome` is only present on `nrc slice get`; the list carries the record's
  name, owner and closure.

### Slice Get

```bash
nrc slice get "Sharded Persistence"
```

Returns one slice object with the same fields as a list entry, plus `outcome`,
`closed_at` and `closed_by`. A name that does not exist returns a structured
`not_found` error.

### Slice Create, Assign, Unassign, Update, Close, Reopen, Delete

```bash
nrc slice create "Sharded Persistence" --owner rene --outcome "Restart-safe shard persistence."
nrc slice assign "Sharded Persistence" --task 42 --task 51 --note 331
nrc slice assign "Sharded Persistence" --file 204
nrc slice unassign "Sharded Persistence" --task 51
nrc slice update "Sharded Persistence" --outcome "Restart-safe with no migration commands."
nrc slice close "Sharded Persistence" --by rene
nrc slice reopen "Sharded Persistence"
nrc slice delete "Draft"
nrc slice delete "Sharded Persistence" --force
```

Important constraints:

- `create` is what makes a slice exist. It carries the name, and optionally the
  owner and the outcome. A name that already exists is refused; use `update` for
  the record or `assign` for members.
- `assign` and `unassign` take `--task`, `--note` and `--file` with positive IDs,
  and any mix of them in one call. Assignment is the only membership: nothing
  joins by carrying a project label, and a task may be assigned to several
  slices. Assigning an ID that is already a member, or unassigning one that is
  not, is an error rather than a silent no-op.
- `update` sends only the flags you pass. It requires at least one of `--owner`
  or `--outcome`.
- `close` records the act: it sets `closed_at` and, when given, `closed_by`.
  Closure is never derived from member statuses, so a slice whose members are all
  Done stays open until someone closes it.
- `--by` is optional. The CLI has no authenticated identity of its own, so
  `closed_by` is empty unless you pass it.
- `delete` removes the slice record and its memberships. The members are other
  records and are never deleted: the tasks, notes and files stay, and the
  released tasks count as work without a slice again. A slice that carries
  members, an owner or an outcome is refused with `invalid_argument` until
  `--force` is passed; the refusal names what would be lost. A slice that
  carries nothing is deleted without the flag. Deleting cannot be undone —
  closure can, with `reopen`.
- `--outcome` is bounded by 2048 bytes and the slice name by 128.
- An empty name is refused: a slice needs an identity to be addressed by.

Each mutation returns the standard mutation envelope:

```json
{"operation":"created","resource_type":"slice","id":2,"message":"Slice created: Sharded Persistence (2)","details":{"name":"Sharded Persistence"}}
```

A delete reports how much it released:

```json
{"operation":"deleted","resource_type":"slice","id":2,"message":"Deleted slice Sharded Persistence (2), released 3 memberships","details":{"name":"Sharded Persistence","released_members":3}}
```

### Reading slice membership

`nrc slice members <name>` resolves the slice's `member-of` edges into the
entities behind them, in the order they were assigned:

```bash
nrc slice members "Sharded Persistence"
nrc slice members "Sharded Persistence" --fields kind,id,title
```

```json
{
  "name": "Sharded Persistence",
  "slice_id": 11,
  "closed": false,
  "count": 2,
  "members": [
    {"kind": "task", "id": 42, "title": "Compaction manifest survives crash mid-swap", "status": "in-progress", "assignee": "anke", "priority": 200, "blocked_by": 409},
    {"kind": "note", "id": 331, "title": "Shard layout v3", "project": "Antares/educap"}
  ]
}
```

Important constraints:

- `kind` is `task`, `note`, `file`, or `asset` when the member's type could not be
  read. A task carries `status`, `assignee`, `priority` and `blocked_by`; a note
  carries `project`; a file carries `category`. Absent fields are omitted.
- A member that cannot be read keeps its ID and loses only its title, so `count`
  stays the truth about the membership.
- The record carries the counters, not the member list, so this is the command to
  read membership; `nrc slice get` reads the owner, the outcome and the closure.
- The raw edges are one command away: `nrc edge list --target-type asset
  --target-id <slice_id>` lists a slice's membership, and `nrc edge list
  --source-type task --source-id <task_id>` lists the slices a task is in. Read
  the edges; never write them. `nrc slice assign` and `nrc slice unassign` own the
  membership direction, and a second `member-of` edge between one member and one
  slice is refused.

### Edge List

Command:

```bash
nrc edge list
```

Supported flags:

- `--human` (switches from default JSON to human-readable output)
- `--source-type <asset|task>`
- `--source-id <id>`
- `--target-type <asset|task>`
- `--target-id <id>`

Filtering semantics:

- `--source-type` and `--source-id` return edges whose source endpoint exactly matches.
- `--target-type` and `--target-id` return edges whose target endpoint exactly matches.
- Source and target filters can be combined to check for a specific directed edge.
- If an endpoint filter is used, both its type and ID flags are required.

JSON shape:

```json
[
  {
    "id": 51,
    "source_type": "task",
    "source_id": 123,
    "target_type": "task",
    "target_id": 98,
    "relation": "depends-on",
    "created_by": "rene",
    "created_at": "2026-04-22 10:15:00"
  }
]
```

Blocker semantics for task-to-task edges:

- `depends-on`: source task is blocked by target task
- `blocks`: source task blocks target task

For `What's blocking task #123?`, loading all task edges is usually simpler than relying only on a narrow target filter.

### Edge Create

Command:

```bash
nrc edge create --source-type task --source-id 123 --target-type task --target-id 98 --relation depends-on
```

Supported flags:

- `--source-type <asset|task>`
- `--source-id <id>`
- `--target-type <asset|task>`
- `--target-id <id>`
- `--relation <references|related-to|depends-on|blocks|derived-from|supersedes|member-of>`

Important constraints:

- Success is a structured mutation result containing the created edge ID and canonical edge resource.
- Endpoint types are only `asset` and `task`; notes are assets when referenced by edges.
- Edges and their endpoint relationships are workspace-wide.
- Use `depends-on` as `source task is blocked by target task`.
- Use `blocks` as `source task blocks target task`.
- `member-of` is the slice membership edge, whose target is the slice asset. It
  is written by `nrc slice assign` and `nrc slice unassign`; do not create or
  delete it here.

Equivalent blocker examples:

```bash
# Task 123 is blocked by task 98.
nrc edge create --source-type task --source-id 123 --target-type task --target-id 98 --relation depends-on

# Equivalent meaning: task 98 blocks task 123.
nrc edge create --source-type task --source-id 98 --target-type task --target-id 123 --relation blocks
```

### Atomic Batch Apply

Use `nrc batch apply --atomic` when related task, note/asset, and edge changes must all commit or all be rejected. Read the canonical `../../maintaining-room-memory/reference/operations.md`, section **Atomic Task, Note, And Edge Writes**, directly for the JSON shape, supported operations, symbolic references, compare-and-swap behavior, limits, and result contract. Keep the decision to use the transaction in this task workflow; do not delegate the user's task-management intent or load the full memory skill solely for this contract.

The essential safety rules remain: batch documents reject `room`; attachments are not atomic; `committed:false` means nothing changed; and `unknown_outcome:true` requires state reconciliation before any retry.

### Non-Atomic Batch Apply

Without `--atomic`, `nrc batch apply [--input file.json]` retains the original sequential behavior and accepts only `task.create`, `task.update`, `task.delete`, `edge.create`, and `edge.delete` operations.

```json
{
  "operations": [
    {"op": "task.create", "ref": "create-doc-task", "title": "Document compaction", "project": "NRC", "priority": 1},
    {"op": "task.update", "ref": "finish-42", "id": 42, "status": "done"}
  ]
}
```

Supported non-atomic operation fields:

- `task.create`: required `title`; optional `description`, `project`, `priority`
- `task.update`: required `id` plus at least one of `title`, `description`, `project`, `status`, `priority`
- `task.delete` and `edge.delete`: required `id`
- `edge.create`: required `source_type`, `source_id`, `target_type`, `target_id`, and `relation`

In this mode, `ref` is only copied into the corresponding result; it cannot substitute an ID produced by an earlier operation. Non-atomic task operations do not support blockers or attachments.

The CLI executes operations sequentially over one connection and returns an ordered `results` array. It continues after safe operation-level validation or server failures, but may skip remaining operations after a broken or unsafe connection. Any failure makes the command exit `1` even though the full result envelope is written to stdout. Never retry `ok:true`; resubmit `skipped:true`; correct deterministic validation/server failures before retrying; and reconcile uncertain `connection_failed` or `unexpected_response` outcomes against current workspace state before retrying a create, because the server may have applied it before the response was lost. Never retry the whole batch blindly.

### Description Pattern

For multiline descriptions, prefer a temporary file:

```bash
cat >/tmp/nrc-task-description.txt <<'EOF'
Line one

- bullet one
- bullet two
EOF

nrc task update 183 \
  --description "$(cat /tmp/nrc-task-description.txt)"
```

### Attachment And Diagram Patterns

Attach files during creation or afterward:

```bash
nrc task create "Title" --project Project --attach "/tmp/log.txt,/tmp/screenshot.png"
nrc task attach 42 /tmp/log.txt /tmp/screenshot.png
```

On an existing task, update-time `--attach` and `task attach` both replace the complete attachment list; they do not append. Use them only when the task is known to have no attachments or when supplying every file that should remain. Task read output does not expose attachment metadata, so stop rather than risk replacement when the existing state is uncertain.

Task descriptions are Markdown. Use a fenced `text` diagram only when it communicates a flow, dependency, or state transition more clearly than prose. Keep it concise and grounded in known context.

- Unicode box borders `┌`, `┐`, `└`, `┘`, `─`, and `│` are allowed.
- Use only ASCII `<`, `>`, `^`, `v`, and `+` for arrowheads and junctions, with `-` and `|` for connector lines.
- Do not use Unicode arrows, triangles, emoji, rendered diagram languages, SVG, tabs, or external validators.
- Keep labels short, preserve required source-language diacritics, and pad rows so borders align.
- Every box content row must have its `│` characters in the same columns as the border corners.
- Every vertical connector, arrowhead, and junction must remain in the column of the element it connects.
- Do not mistake Markdown tables for diagrams or realign them.

````markdown
```text
┌──────┐     ┌─────────────┐     ┌──────┐
│ TODO │ --> │ IN PROGRESS │ --> │ DONE │
└──────┘     └─────────────┘     └──────┘
```
````
