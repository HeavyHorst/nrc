---
name: managing-nrc-tasks
description: Manages NRC tasks, work slices, reminders and appointments through the nrc CLI. Use for project work, blockers, backlog, deadlines, calendar appointments, reminders, slices, and status changes.
---

# Managing NRC Tasks, Reminders & Appointments

Manages NRC tasks, reminders and appointments with the `nrc` CLI, including both read queries and mutations.

Use this skill when asked to create, update, list, filter, summarize, or explain NRC tasks or reminders.

When exact flags, unsupported options, or JSON field names matter, read `reference/cli-contract.md` before running commands.

If an `nrc` command returns usage text, `unknown flag`, or `unknown command`, stop and read the relevant `--help` or `reference/cli-contract.md`, then retry with the supported command shape. Do not guess at alternate flags or subcommands.

## Default Behavior

1. Always use the `nrc` CLI for this skill.
2. Non-streaming commands emit one compact JSON document by default. Use `--human` only when a person explicitly needs the human-readable table or text view. The hidden `--json` flag remains accepted for compatibility but is unnecessary.
3. In default machine mode, ordinary failures exit nonzero, leave stdout empty, and emit JSON on stderr with `code`, `message`, and `retryable`. With `--human`, errors are prose. `batch apply` is the exception: its result envelope is written to stdout and rejection or partial failure exits nonzero. Always check exit status before trusting stdout; use `pipefail` when failure detection matters in a shell pipeline.
4. Use `--pretty` only for human inspection, and use `--fields <field,...>` to reduce read-result payloads when only a few resource fields are needed. Do not combine `--fields` with `--human` or mutation commands.
5. For read-only questions, answer directly from CLI results instead of proposing manual steps.
6. For create or update requests, perform the change instead of only suggesting it.
7. Ask at most one short clarifying question when a required detail is missing and guessing would likely use the wrong task, reminder, or project label.
8. Tasks, notes, reminders, appointments, agendas, files, edges, transactions, search, and retrieval use workspace scope 0. Their CLI commands do not accept `--room`; rooms select chat only.
9. Done tasks are retained as history. Do not routinely delete completed tasks or recreate a "Clear Done" workflow; use explicit individual deletion only when the user asks to remove a task.

## Appointment Management

Use `nrc appointment` for scheduled calendar events. Read the exact flags and
timestamp rules in `reference/cli-contract.md`. Appointments are not tasks (no
status, priority, or blocker), and are not reminders (no urgency/window state).
The CLI does not run a notification scheduler. An open NRC browser tab can notify
the assignee 15 minutes before start when browser permission is granted. Closed
or suspended browsers cannot guarantee timely alerts. The browser palette's
Appointment notifications command accepts `mine` or `off`; the setting is local
to the browser, workspace and nickname, not stored on the appointment.

## Workspace Scope

Do not select or resolve a room for task, slice or reminder work. IDs and relationships are workspace-wide. Organize tasks with their structured `project` field; tasks do not have a tag flag. Notes may use both projects and tags. A `project` label says which repository or module something belongs to; a slice is a separate, explicitly created work stream. Tasks, notes and files are assigned to a slice, one task can belong to several slices, and a slice can span projects. Do not treat a project label as a slice.

## Query Workflow

Use this sequence for task questions:

1. For an exact ID, use `nrc task get <id>` instead of listing every task.
2. For structured list questions, use `nrc task list` with `--project`, `--status`, `--priority`, `--created-by`, or `--title-contains` filters when they match the question. It includes all statuses, including Done, by default and transparently drains the server's task pages. Use `--status backlog,todo,progress` when only active tasks are needed.
3. For text or semantic discovery, especially retained Done history, use `nrc search query <text> --entity task`. Use `--entity asset,task` only when unified note/asset and task results are useful. Omitting `--entity` intentionally retains legacy asset-only search.
4. For an open-ended question that spans tasks, notes, dependencies, provenance, or related context, use `nrc retrieve <question>`. It fuses typed task/asset search with bounded graph traversal, ranks graph candidates with query-personalized PageRank, and returns explicit path evidence. Before synthesis, inspect `stale`, `truncation`, `warnings`, and required result payloads: a successful command may still be degraded. Do not make complete, count, or blocker claims from a degraded bundle; use deterministic task/graph commands or explicitly state the limitation. If the retrieval endpoint is unavailable, fall back to typed search and explicit graph commands.
5. If the question is about blocked or ready tasks, prefer `nrc task list --blocked` or `nrc task list --ready`.
6. If the question is about blockers for a specific task, use the exact blocker workflow below; fused retrieval may provide background but is not an exhaustive blocker query.
7. Prefer CLI filters and `--fields` over transferring data only to discard it. Apply any remaining compound or legacy-prefix logic in the agent.
8. Remember that `nrc task list` returns an object with a `tasks` array, not a top-level array; internal page metadata is not exposed.

Common commands:

```bash
nrc task list
nrc task list --status backlog,todo,progress
nrc task list --status done
nrc task get 42
nrc task list --project Marketplace --status todo,progress --fields id,title,status
nrc search query "pagination" --entity task --top 10
nrc search query "pagination" --entity asset,task --top 10
nrc retrieve "What decisions and dependencies affect pagination?"
nrc task list --blocked
nrc task list --ready
nrc slice list
nrc slice list --include-closed
nrc slice get "Marketplace"
nrc edge list
```

## Project Queries

Tasks have a structured `project` field. Legacy tasks may still encode project identity in a `[Project] ` title prefix.

- Prefer exact matching on the task JSON `project` field when it is present.
- Fall back to exact `[Project] ` title-prefix matching for older tasks that do not have `project` set.
- Use the CLI's client-side `--project <name>` filter only when structured-project matches are sufficient. When legacy prefixed tasks must also be included, fetch the task list once with the required `--fields`, then union exact `project == <name>` matches with tasks whose project is empty and whose title starts with the exact `[<name>] ` prefix.
- If the project label is not clear from the request or surrounding context, ask one short question.

Examples:

- `Show me all tasks related to project Marketplace`
- `Which [Eudopool] tasks are blocked?`
- `List ready tasks for Marketplace`

## Slice Queries

A slice is an explicit work stream. It is created by name, and its members are
the tasks, notes and files assigned to it. The server reads those assignments, so
`nrc slice list` is the authoritative answer to "what work is in flight" — do not
answer that by listing tasks and grouping them yourself, and never derive
membership from project labels or titles. A task can belong to more than one
slice, and a slice can span projects.

Use slices when the question is about work streams, load, or staleness:

- `What is in flight?` → `nrc slice list`
- `Which work streams are stalled or overloaded?` → `nrc slice list`, then read
  `open`, `blocked` and `last_moved_at`
- `Which work is in no slice?` → `unassigned_tasks` in `nrc slice list`
- `What is the outcome of the X work stream?` → `nrc slice get "X"`
- `What is in the X work stream?` → `nrc slice members "X"`
- `Close the X work stream` → `nrc slice close "X"`
- `Put task 42 into the X work stream` → `nrc slice assign "X" --task 42`
- `Delete the X work stream` → `nrc slice delete "X"` (see the delete rule below)

```bash
nrc slice list
nrc slice list --include-closed
nrc slice list --fields name,members,open,blocked,last_moved_at
nrc slice get "Marketplace"
nrc slice members "Marketplace"
nrc slice members "Marketplace" --fields kind,id,title
nrc slice create "Marketplace" --owner rene --outcome "Pricing agreed and shipped."
nrc slice assign "Marketplace" --task 42 --task 51 --note 331
nrc slice assign "Marketplace" --file 204
nrc slice unassign "Marketplace" --task 51
nrc slice update "Marketplace" --outcome "Pricing agreed, shipped, and measured."
nrc slice close "Marketplace" --by rene
nrc slice reopen "Marketplace"
nrc slice delete "Marketplace"
nrc slice delete "Marketplace" --force
```

Rules that differ from tasks:

- **A slice must exist before anything is assigned to it.** Create it first; an
  unknown name is an error, not an implicitly created slice.
- **Assignment is the only membership.** A task joins a slice by being assigned
  to it (`--task`), a note or file likewise (`--note`, `--file`). Nothing joins
  by carrying a project label, and a project label alone never makes a slice.
- **One task, several slices.** Assignment is not exclusive; do not assume a task
  belongs to one work stream, and never unassign it from one to move it to
  another.
- **`create` is not idempotent.** Creating a name that already exists is refused;
  use `update` for the record and `assign` for members.
- **Closure is an act, not a derivation.** A slice whose members are all Done
  stays open until someone closes it, and a slice can be closed with work still
  open. Never infer slice state from member statuses; read `closed`.
- **`members` counts every member; `tasks` counts the ones with a status.**
  Read `members`, `tasks`, `notes` and `files` before describing a slice's size.
- **Closed slices are hidden by default.** Pass `--include-closed` when the
  question is about finished work.
- **`delete` is guarded and takes no members with it.** A slice that carries
  members, an owner or an outcome is refused until you pass `--force`; the
  refusal names what is at stake. Deleting removes the slice record and its
  memberships only — the tasks, notes and files themselves stay and become work
  without a slice. Never delete a slice to "unassign" its members: use
  `nrc slice unassign`, and never delete one as a substitute for `close`.
  Deleting is the one slice act that cannot be undone; closure has `reopen`.
- **`nrc slice` is the only writer of slice records.** Do not create
  `AssetTypeSlice` assets through `nrc asset create` or `batch apply`, do not
  write a task/note/file `member-of` edge to a slice through `nrc edge create`,
  and do not delete a slice through `nrc asset delete`: that path has no guard
  and no release report. The preview contract and the membership direction are
  enforced by the slice commands. Customer membership uses the same relation but
  is written only by `nrc customer`, never by `nrc slice` or a generic edge write.

Prefer slices over a task listing for any question about scope, load or
staleness. Fall back to `nrc task list --project <name>` when the question is
about individual tasks inside a repository or module rather than a work stream.

### Reading membership

`nrc slice members <name>` is the way to read what a slice carries. It resolves
each `member-of` edge into the entity behind it and reports the kind, the ID, the
title and the state that kind has:

```bash
nrc slice members "Marketplace"
nrc slice members "Marketplace" --fields kind,id,title
```

```json
{
  "name": "Shard hardening",
  "slice_id": 11,
  "closed": false,
  "count": 2,
  "members": [
    {"kind": "task", "id": 13, "title": "Manifest swap under fsync failure", "status": "backlog", "priority": 90, "blocked_by": 4},
    {"kind": "note", "id": 12, "title": "Shard layout v3", "project": "Antares/educap"}
  ]
}
```

- `kind` is `task`, `note`, `file`, or `asset` when the member's type could not be
  read. Members are listed in the order they were assigned.
- A task carries `status`, `assignee`, `priority` and `blocked_by`; a note carries
  `project`; a file carries `category`. Absent fields are omitted.
- A member that cannot be read keeps its ID and loses only its title, so `count`
  stays the truth about the membership.
- The raw edges are one command away when they matter:
  `nrc edge list --target-type asset --target-id <slice_id>` reads a slice's
  membership, and `nrc edge list --source-type task --source-id <task_id>` reads
  the slices a task belongs to. Read those edges; never write them, because
  `nrc slice assign` and `nrc slice unassign` own the membership direction.

## Blocker Analysis

To answer `What's blocking task #123?`, inspect both native task blockers and task-to-task edges.

Do not treat `nrc retrieve` as the authoritative blocker set: it is relevance-ranked, bounded by `--top`, and traverses both directions by default. It can supplement this workflow with related notes and provenance, but exact blocker conclusions must come from task state and correctly oriented edges.

1. Load all tasks with `nrc task list`.
2. Load all edges with `nrc edge list`.
3. For a targeted transitive dependency check, use `nrc graph walk` instead of loading all edges:
   ```bash
   # Direct blockers: depends-on and blocks at depth 1
   nrc graph walk --start-type task --start-id 42 --depth 1 --relation depends-on,blocks

   # Transitive blocker chain at depth 2-3
   nrc graph walk --start-type task --start-id 42 --depth 2 --relation depends-on,blocks
   ```
   The default `both` direction returns a dependency neighborhood, not a blocker-only list. Treat returned edges as candidates: when deriving blockers, follow outgoing `depends-on` and incoming `blocks` at every hop; never label every returned node as a blocker.
4. Check the task's native `blocked_by` field.
5. Check task-to-task edges using these semantics:
   - `depends-on`: the source task is blocked by the target task
   - `blocks`: the source task blocks the target task
6. Treat blockers whose status is `done` as no longer active.
7. If no active blocker remains, say so explicitly.

When replying, prefer naming both the blocker ID and title.

When creating task-to-task blocker edges, be careful not to invert the direction:

```bash
# Task 123 is blocked by task 98.
nrc edge create --source-type task --source-id 123 --target-type task --target-id 98 --relation depends-on

# Equivalent meaning: task 98 blocks task 123.
nrc edge create --source-type task --source-id 98 --target-type task --target-id 123 --relation blocks
```

## Create And Update Workflow

Use this sequence for task changes:

1. Create and update commands return structured mutation JSON, including the affected ID when known; capture it directly.
2. Create the task with `nrc task create` or update it with `nrc task update`.
3. If the task also needs a blocker, status, or title adjustment, immediately follow with `nrc task update`.
4. If a blocker is described by title instead of ID, resolve it first with `nrc task list`.
5. Run `nrc task get <id>` after creation only when authoritative read-back verification is useful.
6. If the user wants several tasks, complete all requested changes in one pass.

Task mutations return a stable object with `operation`, `resource_type`, and usually `id`; create responses also include the created task under `resource`. Read the mutation result directly instead of scraping confirmation prose.

For several related task, note/asset, or edge mutations that must succeed together, read the batch contract and use `nrc batch apply --atomic`. It submits one server-side WAL transaction. Create operations can define symbolic `ref` names, and task blockers, asset parents, and edge endpoints can use those names even before the corresponding create appears in the operation list. Use `if_updated_at` on updates and deletes of existing tasks or notes/assets when stale state must reject the whole transaction. Attachments are not supported in atomic operations.

Without `--atomic`, `nrc batch apply` retains its sequential, partial-success behavior. Use that mode only for independent operations that do not need generated IDs, blockers, attachments, or rollback. Never retry `ok:true`; resubmit `skipped:true`; correct deterministic validation/server failures before retrying; and reconcile uncertain outcomes against current workspace state before retrying a create. Never resubmit a whole sequential batch blindly.

An atomic transport failure is different from a server rejection: `unknown_outcome:true` means the server may have committed the transaction. Reconcile workspace state before any retry; there is no durable idempotency receipt. A response with `committed:false` confirms that none of the operations took effect.

Before creating, search with `--title-contains` and minimal `--fields` only when the request is idempotent (for example, “make sure this task exists”), appears to repeat an earlier request, or follows an uncertain mutation outcome. Treat the substring filter only as candidate narrowing: suppress creation only after an exact title and intended project comparison, including the legacy-project union rules when applicable. Do not pre-list for every explicit create.

Use `--project <name>` on `nrc task create` when the user names a project. Use `nrc task update <id> --project <name>` to change the project, and pass an explicitly empty `--project ""` only when the user asks to clear it.

`nrc task update` uses partial application — only the flags you explicitly pass are sent as changes. Status, priority, project, and blocker use `Changed()` internally, while title and description are sent as-is (server treats empty as no change). Do not pass flags the user didn't ask to change.

## Reminder Management

Reminders are assets (AssetType=6) with time-based state derivation. Use the `nrc reminder` command family.

### States (derived by the CLI from stored deadline/window/urgency and the current time)

| State | Condition |
|-------|-----------|
| LATE | Past deadline |
| URGENT | Within urgency window before deadline |
| OPEN | Active, outside urgency window |
| LOCKED | Before window-start |

### Common reminder commands

```bash
nrc reminder list
nrc reminder list --hide-locked
nrc reminder get <id>
nrc reminder create "Title" --deadline "2025-12-31T23:59" [--window-start "2025-12-01T00:00"] [--urgency-days 7] [--note-id 123]
nrc reminder update <id> [--title "New title"] [--deadline "..."] [--window-start "..."] [--urgency-days 5] [--note-id 456]
nrc reminder delete <id>
```

### Create workflow

1. `--deadline` is required. Accepts RFC3339, `YYYY-MM-DDTHH:MM`, or unix nanos.
2. `--window-start` is optional. Pass `"none"` or omit for no window.
3. `--urgency-days` defaults to 3 — controls how many days before the deadline the reminder enters URGENT state.
4. `--note-id` links the reminder to an existing note asset.

### Update workflow

Only changed fields need to be provided. The CLI fetches the existing reminder and merges flags that were explicitly set:

- Pass `--window-start ""` or `--window-start "none"` to clear the window start.
- Pass `--note-id ""` or `--note-id "none"` to unlink the note.
- Pass `--urgency-days` to override; must be >= 1.

### List details

- Results are sorted by state (LATE before URGENT before OPEN before LOCKED), then by deadline, then window-start, then title.
- Use `--hide-locked` to filter out LOCKED reminders.
- Default output is a top-level JSON array of reminder entries.

### Usage in queries

- For "what's overdue" questions, filter JSON for `"state": "LATE"`.
- For "upcoming reminders", filter for `"state": "URGENT"` or `"state": "OPEN"`.
- For "reminders for note #X", filter by `"note_asset_id"`.
- Reminder IDs resolve directly in the workspace; no room lookup is needed.

## Title And Project Convention

- Prefer the structured `project` field over `[Project] ` title prefixes for new tasks.
- Use `nrc task create "Task title" --project "Project" ...` when creating project-scoped tasks.
- Do not duplicate the project in the title when it is already provided through `--project`, unless the user explicitly asks to preserve a legacy title convention.
- If the correct project label is not clear from the request or nearby context, ask one short question before creating the task.
- Reuse the user's existing project spelling and capitalization when it is visible in nearby tasks or explicitly stated.
- Keep titles short, actionable, and close to the user's original wording.
- Prefer imperative titles such as `Fix websocket handshake timeout` or `Document WAL compaction flow`.

Examples:

- `Produzentendaten anstatt DABI nehmen` with `--project Marketplace`
- `Hilfetexte fuer Einstellungen` with `--project Eudopool`

## Priority, Status, And Blockers

- Default `priority` to `0` unless the user clearly signals higher urgency.
- Raise priority only when the user explicitly indicates urgency, severity, or blocking impact.
- For `nrc task update --status`, use `backlog`, `todo`, `progress`, `done`, or `note`.
- In `nrc task list`, the in-progress state is emitted as `in-progress`.
- If the user says a task is blocked by `#42`, run `nrc task update <id> --blk 42`.
- If the blocker is described by title instead of ID, resolve that ID first from `nrc task list`.

## Descriptions And Attachments

NRC task descriptions render Markdown. Prefer `--description` when the user provides context worth preserving.

- Keep a simple one-sentence description as plain text.
- Format substantial implementation notes, plans, acceptance criteria, or completion reports as concise structured Markdown. Use short headings and lists so the task remains scannable instead of storing one dense paragraph.
- Preserve the user's wording and level of detail, but organize it when Markdown materially improves readability.
- Use real line breaks for multiline descriptions. Pass them safely with command substitution rather than writing literal `\n` escapes.

On an existing task, both update-time `--attach` and `task attach` replace the complete attachment list rather than appending; use them only when the task is known to have no attachments or when supplying the complete intended file set. Because task reads do not expose attachments, stop rather than risk replacement when existing attachments are uncertain. For multiline command examples, attachments, and Markdown diagram rules, read **Description, Attachment, And Diagram Patterns** in `reference/cli-contract.md`.

## Response Pattern

For read queries, answer with the relevant tasks, reminders, blockers, or counts instead of describing the command you ran.

For create or update actions, report the result succinctly with task IDs or reminder IDs.

In NRC chat messages, use typed references: `[task:42]` for tasks and `[note:456]` for notes. Preserve the exact decimal ID, including 64-bit IDs; never round it through a floating-point number. Write these tokens as plain message text, not inside Markdown backticks or links, so they remain clickable. The `#` title/ID picker is a client UI aid; agents send the complete token directly. Legacy `#42` task references still work, but prefer the typed format for new messages. Work slices have no typed reference token: name a slice in prose, and read it with `nrc slice get`.

Typed task and note references resolve workspace-wide, independently of the chat room. This is a chat text convention, not a change to CLI ID arguments or graph endpoint types.

Examples:

- `Created task [task:42] in Marketplace: Fix websocket handshake timeout`
- `Marketplace currently has 5 open tasks; 2 are blocked.`
- `Task [task:123] is blocked by [task:98] Marketplace: Update API schema.`
- `Created reminder #77: "Review deploy" due 2025-12-31 23:59`
- `Reminder #77 state is LATE (passed deadline)
- `Marketplace is open, 8 open of 14 members, 2 blocked, last moved 2h ago.`
- `Marketplace has 14 members: 11 tasks, 2 notes and 1 file.`

The backticks above delimit documentation examples only; omit them in actual NRC chat messages.

## Quality Bar

Before finishing, make sure:

- no data command was given `--room`
- project queries used `--project` only when structured matches were sufficient; legacy-inclusive queries used one unfiltered projection and unioned exact project and exact title-prefix matches
- blocker answers considered both `blocked_by` and task-to-task edges
- task-to-task edge creation used the correct direction for `depends-on` or `blocks`
- create and update replies include the affected task or reminder IDs
- reminder state is derived (LATE/URGENT/OPEN/LOCKED) — explain why it has that state when relevant
- work-stream, load and staleness questions were answered from `nrc slice list`, not by grouping a task listing
- slice membership was read from the assignments, never derived from a project label
- slice closure was read from `closed`, never inferred from member statuses
- slice creation, assignment and removal went through `nrc slice`, not through generic asset or edge commands
