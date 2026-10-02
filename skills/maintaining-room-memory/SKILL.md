---
name: maintaining-room-memory
description: Uses NRC notes, semantic search, and graph edges as durable workspace memory. Use when an agent should remember decisions, recover prior context, connect tasks to notes, or maintain a lightweight project knowledge graph.
---

# Maintaining Workspace Memory

Uses NRC as a durable memory layer: notes hold the text, search retrieves it, and edges make relationships explicit.

Use this skill when asked to remember decisions, maintain project context, build a knowledge base, reconnect prior work to current tasks, or answer from workspace memory instead of only the current chat. The directory and skill name remain `maintaining-room-memory` for compatibility.

## Command Discipline

1. Use the exact `nrc` subcommand forms shown in this skill. Do not collapse or rename subcommands.
2. Prefer these exact shapes:
   - `nrc retrieve <question>` for fused asset/task search and graph evidence
   - `nrc search query <text>`
   - `nrc search query <text> --entity task` for tasks
   - `nrc search query <text> --entity asset,task` for unified memory and task results
   - `nrc search similar <asset-id>`
   - `nrc note list`, `nrc note get`, `nrc note create`, `nrc note update`, `nrc note attach`, `nrc note replace-attachment`, `nrc note remove-attachment`, `nrc note download-attachment`, `nrc note patch`, `nrc note backups`, `nrc note revert`, `nrc note delete`, `nrc task get`
   - `nrc graph walk`, `nrc graph path`, `nrc graph degree`, `nrc graph common`, `nrc edge list`, `nrc edge create`
   - `nrc batch apply --atomic --input <transaction.json>` for all-or-nothing task, note/asset, and edge graph writes
3. Do not invent alternate command shapes such as `nrc search <text>` when the CLI expects `nrc search query <text>`.
4. Every non-streaming command emits one compact JSON document by default. Mutations return structured objects with `operation`, `resource_type`, and the affected ID when known. Use `--human` only when a person explicitly needs the table or text renderer; its box-drawing/control characters can cause tool wrappers to misclassify output as binary.
5. In default machine mode, ordinary failures exit nonzero, leave stdout empty, and emit structured JSON on stderr. With `--human`, errors are prose. `batch apply` is the exception: its result envelope goes to stdout and rejection or partial failure exits nonzero. Always check exit status before trusting stdout; use `pipefail` when failure detection matters in a shell pipeline.
6. Use `--fields` for object resources and object collections when a smaller result preserves everything needed. Note listings expose both `updated_at` (Unix nanoseconds, suitable for `--expect-updated-at`) and `updated` (human-readable time). Do not use `--fields` on primitive arrays such as `note projects` or `note tags`, or with `--human` or mutations. Use `--pretty` only for human inspection.
7. Legacy asset/note `search query` output remains compatible by default, with `asset_id`, `score`, `similarity`, `preview`, and `asset_type`. When `--fields` is present, note results also support decoded `id`, `title`, `project`, `tags`, `teaser`, and `format` fields. Prefer `--fields id,title,project,tags,teaser` for compact note-search results, then load the selected note with `note get` before relying on or editing it.
8. Use `--help` or `nrc capabilities` to verify commands and flags. They do not describe command-specific response fields; when fields are not documented here, inspect one unprojected compact JSON result before selecting them.
9. If an `nrc` command returns a structured `invalid_argument` error, stop and inspect the relevant `--help` or `nrc capabilities`, then retry with the supported command shape. Do not keep guessing.

## Workspace Scope

Notes, tasks, customers, files, reminders, agendas, edges, transactions, search, and retrieval all use workspace scope 0. Data commands do not accept `--room`; do not resolve a room before reading or writing memory. Relationships are workspace-wide. Load `using-nrc-chat` for room chat, retained messages, presence, or direct messages.

## Retrieval Workflow

1. If an exact note, asset, or task ID is supplied, load it directly with `nrc note get`, `nrc asset get`, or `nrc task get` instead of ranking a search.
2. For an open-ended question, start with fused retrieval.
   - CLI: `nrc retrieve "<question>"`
   - The default bundle returns up to 10 hydrated asset/task results and traverses one graph hop from the strongest search anchors in both directions.
   - Graph candidates are always ranked with query-personalized PageRank seeded by those anchors. There is no ranking-mode selector; use `--no-graph` only for a search-only diagnostic or ablation.
   - Treat `results` as the ranked evidence, each result's `evidence` as its anchor-to-result traversal records, and response-level `edges` as the corresponding raw relationship facts.
   - Inspect each result's `payload_state`: `complete` is safe to synthesize from, `omitted` requires loading the entity when relevant, and `truncated` requires loading the entity before drawing conclusions about its full content. The response-level `truncation.payloads` remains a summary and does not identify the affected result.
   - Surface material `warnings`, `stale`, or response-level `truncation` state in the answer instead of presenting incomplete evidence as exhaustive.
   - Use `--depth 2` to broaden bounded traversal only when the question needs it. Use `--relation` or `--direction` when relationship semantics are known. Depth is limited to 1-4.
   - `--no-graph` is not the normal memory workflow.
3. For narrow semantic filtering, or if fused retrieval is unavailable, use search directly.
   - CLI: `nrc search query` for legacy asset-only memory search
   - CLI: `nrc search query --entity task` for tasks, including retained Done history
   - CLI: `nrc search query --entity asset,task` when both memory assets and tasks are relevant
   - If relationships still matter after fallback search, run `nrc graph walk` from the strongest relevant result.
4. If one asset is clearly relevant and similarity rather than explicit relationships is useful, expand around it.
   - CLI: `nrc search similar`
   - Similar search is asset-oriented; use a typed task query rather than `search similar` for tasks.
5. Load the full note, asset, or task before editing it or when the retrieval payload is absent, warned as incomplete, or lacks required authoritative fields.
   - CLI: `nrc note get`, `nrc asset get`, `nrc task get`
   - `nrc note get` includes up to 20 directly related notes in `related_notes` by default. Use this context before issuing separate graph commands.
   - Use `--related=false` when you need the note content without appended context, such as exact content migration, scripting, or comparing raw note bodies.
   - Use `--related-limit <n>` when you need a different cap.
   - For an exact domain identifier, load the strongest result whose full indexed body plausibly produced the match even if the static title and teaser describe a broader topic.
6. Treat shell or UI clipping separately from NRC payload state. Output limited by `head`, `sed`, another byte/line limiter, or a collapsed tool panel is not evidence that the payload lacks a passage; rerun without the limiter or load the entity directly.
7. When a known endpoint, exact path, shared neighbor, hub ranking, or relationship audit matters beyond the fused evidence, query the graph explicitly.
   - CLI: `nrc graph walk`, `nrc graph path`, `nrc graph degree`, `nrc graph common`, `nrc edge list`

## Project- And Tag-Scoped Notes

Notes carry structured preview metadata: a single `project` field plus zero or more independent `tags`. Use `project` for the canonical repo/product/workstream scope, and use `tags` for topical labels that can cross projects.

When the memory is likely organized by project or topical tags, narrow the note search before you start opening individual notes.

1. Discover available projects only when the value is unknown or ambiguous; when the user supplies an exact project, list that scope directly.
   - CLI: `nrc note projects`
2. Discover available tags only when the value is unknown or ambiguous; when the user supplies an exact tag, list that scope directly.
   - CLI: `nrc note tags`
3. Pull the newest notes for the relevant project or tag.
   - CLI: `nrc note list --project <project> --limit <n>`
   - CLI: `nrc note list --tag <tag> --limit <n>`
4. Treat `nrc note list` as an object with a `notes` array plus `has_more` and `next_cursor`, not as a top-level array.
5. Use unfiltered `nrc note list` only with `--limit` or `--page-size` when project and tag filters do not help.
6. Use `--cursor <next_cursor>` to fetch another page only when the first page is insufficient.
7. Use `--all` only when the user explicitly wants every note in the workspace.
8. Do not combine `--all` with `--limit`; they are mutually exclusive.

## What Belongs In Memory

Persist information that will still matter later:

- architecture decisions
- implementation constraints
- incident timelines and conclusions
- working agreements
- canonical references to tasks, documents, or prior notes
- distilled findings from a debugging or investigation session

Do not persist raw transient chatter unless the user explicitly wants a transcript.

Do not store secrets, tokens, or incidental private data in notes.

## Writing Workflow

Use this workflow only after an explicit persistence request or clearly established standing authorization. A useful or durable finding alone is not permission to mutate workspace memory.

1. Check whether a canonical note already exists.
2. Update that note if the new information extends or corrects it.
3. Create a new note only when the information is a separate durable concept.
4. For project-specific memory, set `--project` to the canonical repo/project identifier.
5. Do not add the project/repo identifier to the title when it is already available as the structured `project` field. Make the title specific by naming the durable concept, not by appending `[project]`.
6. Add `--tag` values for durable topics that should be filterable across projects.
7. Prefer `--content-file <path>` for prepared Markdown or HTML instead of shell-substituting file contents into `--content`; use either `--content` or `--content-file`, not both. Notes default to Markdown. Pass `--format html` only for a self-contained visual document, and load `designing-nrc-content` before authoring it.
8. Attach durable source files, diagrams, logs, screenshots, or PDFs when preserving the file itself matters. For attachment add/replace/remove/download commands and `att:N` safety, read `reference/operations.md`.
9. For localized edits, prefer `note patch`; use `--dry-run` when practical and `--expect-updated-at` with a fresh timestamp. Read `reference/operations.md` for patch diagnostics and backup/revert workflows.
10. Use `nrc note update --content-file` when intentionally replacing or substantially rewriting the whole note.
11. `note update`, `note patch`, and `note revert --force` write local pre-change backups; inspect and dry-run before restoration. See `reference/operations.md`.
12. Add edges so future retrieval can find the note by relationship, not just wording.

Prefer one stable note per durable concept over many overlapping notes.

## Atomic Graph Writes

Use `nrc batch apply --atomic` when several task, note/asset, and edge changes form one durable fact and partial application would leave misleading memory. Typical uses include creating several notes and their relationships together, creating a task plus its context note and edge, bulk-changing project or status fields, or deleting an entity with related explicit changes. The server validates the projected final graph and commits the request as one WAL transaction.

Create operations may define symbolic `ref` names. A task blocker, note/asset parent, or edge endpoint can use a matching `*_ref`, including a forward reference to a later create operation. References are transaction-local and typed; parents, blockers, and edge endpoints are workspace-wide.

Use `if_updated_at` from a fresh read for updates and deletes of existing tasks or notes/assets when concurrent edits must reject the whole transaction. Atomic note metadata updates automatically read the current note and add this compare-and-swap when the caller did not supply one. A confirmed rejection applies nothing. If the CLI reports `unknown_outcome:true` after a transport failure, reconcile current state before retrying because there is no transaction idempotency receipt.

Atomic operations do not support attachments. Keep attachment changes in their explicit workflows; do not claim an attachment-plus-graph sequence is atomic. Read **Atomic Task, Note, And Edge Writes** in `reference/operations.md` for the JSON shape and result contract.

When an incident, decision, or troubleshooting result has a distinct future retrieval intent, give it its own note instead of appending it deep inside a broader note. Put stable identifiers that people are likely to search for—media/product numbers, ticket IDs, service names, producer/customer names—in the title when they identify the concept, otherwise in the opening metadata or finding. After writing, verify one exact-identifier query and one likely natural-language query; both should surface the canonical note near the top.

## Edge Semantics

Use relation types deliberately:

- `references`: the source cites or points to the target
- `related-to`: loose association without stronger semantics
- `depends-on`: the source cannot complete without the target
- `blocks`: the source prevents the target from progressing
- `derived-from`: the source was synthesized from the target
- `supersedes`: the source replaces the target as the canonical memory
- `member-of`: the source is an actual member of the target container

For note memory, `references`, `derived-from`, and `supersedes` are usually the most valuable.

Slice membership is not a loose relationship. When a note is part of a work slice, assign it with
`nrc slice assign "<slice>" --note <id>`; use the corresponding `--task` or `--file` flag for those
kinds. Only the resulting `member-of` edge makes the entity appear under the slice UI's TASKS,
NOTES, or FILES section and contribute to its member counters. A `related-to` edge appears only as
a link and does not make the note a slice member. Use `nrc slice unassign` to remove membership;
do not create, replace, or delete slice-membership edges through generic edge commands.

For ordinary `edge` and `graph` commands, endpoint types are only `asset` and `task`. Notes are assets, so use `--source-type asset` or `--target-type asset` for note IDs. Atomic transaction JSON additionally accepts `note` as an alias for an asset endpoint.

Use `nrc edge list` for direct relationships, `nrc graph walk` for multi-hop expansion, `nrc graph path` for shortest paths, `nrc graph degree` for hub discovery, and `nrc graph common` for shared neighbors. Read `reference/graph.md` before an exact graph query or relationship explanation; it defines endpoint filters, direction, ranking limits, and command shapes.

## Note Shape

Prefer concise, durable notes with stable `Type: subject` titles. Use a type prefix that describes the note's role, such as `Context:`, `Decision:`, `Runbook:`, `Reference:`, `Architecture:`, `Troubleshooting:`, `Config:`, `Report:`, or `Plan:`.

Do not repeat the note title as the first heading or first body line. The title is already displayed separately by NRC, so the note body should start with metadata, the actual finding/decision, or the first distinct section. If a note needs an internal heading, make it more specific than the title and avoid duplicating the same headline text.

Do not write `Project:` or `Tags:` lines into the note body when those values are already provided through `--project` and `--tag`. Use body lines such as `Related repos:`, `Local path:`, or `Scope:` only when they add information that is not captured by structured metadata.

For project-specific notes, prefer a stable repo/project identifier such as `owner/repo` in the structured `project` field.
Use the local git repo basename only when a better canonical identifier is unavailable. Do not append the project to the title.

Good note patterns:

- `Decision: switch search retrieval to note-first flow`
- `Incident: websocket handshake regression 2026-04-07`
- `Context: auth token validation boundaries`
- `Runbook: rebuilding the nrc-search index`

Inside the note, bias toward:

- the decision or finding
- why it matters
- the current status
- the canonical repo/project identity when project-specific
- linked task or asset IDs
- what superseded older understanding

## Markdown Diagrams

Use a fenced `text` diagram only when it communicates structure better than prose, and keep it grounded in known data. Before writing one, read the alignment and character rules in `reference/operations.md`.

Example body shape for a note titled `Context: auth token validation boundaries` with `--project "heavyhorst/nrc"`:

```markdown
## Current boundary

JWT structure is parsed at the HTTP edge, but workspace authorization is enforced after room resolution.
```

Avoid this duplicate shape:

```markdown
# Context: auth token validation boundaries

Context: auth token validation boundaries
Project: heavyhorst/nrc
Tags: auth, tokens
```

## HTML Notes

Use HTML format when the note is genuinely a document-like interface, dashboard, visualization, or rich visual artifact that Markdown cannot express. Keep ordinary durable memory in Markdown so it remains easy to search, patch, diff, and export.

- Create with `nrc note create <title> --format html --content-file <file>`.
- Convert an existing note only when explicitly intended: `nrc note update <id> --format html --content-file <file>`.
- Load and follow `designing-nrc-content` for the complete visual, interaction, accessibility, theme, attachment, and sandbox contract.
- Keep the UTF-8 document below the protocol's 65,535-byte limit. Search indexes readable HTML text but excludes script and style content.

## Common Note Write Loop

Use this exact flow for requests like "add a note about X":

1. Search for an existing canonical note before writing anything.
   - Example: `nrc search query --type note --top 5 "taskcards import logic"`
2. Load the strongest hit before deciding whether to update or create. For an explicit partial metadata update to a known note ID, direct `note update` is sufficient because omitted fields are preserved.
   - Example: `nrc note get 123`
3. If an existing note already covers the durable concept, update it instead of creating a duplicate. Prefer `nrc note patch` for a small/localized content change, and `nrc note update --content-file` for a full replacement.
   - Example: `nrc note update 123 --content-file /tmp/nrc-note.md`
4. If no canonical note exists, create one with a stable title and structured metadata.
   - Example: `nrc note create "Context: taskcards import logic" --project "heavyhorst/nrc" --tag import --tag taskcards --content-file /tmp/nrc-note.md`
5. If the note should preserve files, attach them during creation or immediately after.
   - Example: `nrc note create "Evidence: websocket trace" --content-file /tmp/nrc-note.md --attach "/tmp/trace.log,/tmp/screenshot.png"`
   - Example: `nrc note attach 123 /tmp/diagram.pdf /tmp/error.log`
   - For replacement, removal, download, and `att:N` rules, read `reference/operations.md`.
6. Capture the note ID from the structured mutation result. Read it back only when you need to verify content or searchability.
   - Example: `nrc note get <new-note-id>`
7. Add edges when the note should remain discoverable from related tasks or assets. If the note and its edges are all new and must appear together, create them with one atomic batch instead of separate commands.

## Exact Command Recipes

Read `reference/recipes.md` when exact syntax is needed for note updates, project/tag paging, direct edge operations, or graph traversal. Do not load it for a straightforward retrieval or note write whose command shape is already clear.

## Quality Bar

Before finishing, make sure:

- the memory is easy to find with likely future search terms
- exact identifiers and distinctive names needed for future lookup appear in the title or opening searchable context
- a distinct incident/decision is not buried as a late section in a broader note
- one exact-identifier query and one natural-language query surface the canonical note near the top when new memory was written
- the note title is stable and specific
- project-specific notes set the structured project field and do not duplicate that project in the title
- important related tasks or assets are linked with edges
- stale notes are updated or superseded instead of silently duplicated
