# nrc-ai

AI turns pasted text into task or note previews and answers questions about
workspace data. The web client calls the assistant Sullivan. It can search records,
follow graph links and propose task, note and edge changes for approval.

## Start

First set up the [core deployment](../../../README.md#quickstart).
Use the same `NRC_BOT_SECRET` for the server and AI. In `.env`, set:

- `LLM_PROVIDER`: the provider to use; the default is `openai`.
- `LLM_MODEL`: a model supported by that provider; the default is `gpt-4o-mini`.
- `LLM_API_KEY`: the provider key. Hosted providers require it.
- `LLM_BASE_URL`: required for `openai-compat`; optional for other providers,
  with the limitations below.

**AI sends supplied text and retrieved workspace content to the LLM provider.**
Choose a provider that is suitable for your data. Search computes embeddings
locally, but that does not make AI processing local.

Run from the repository root. The AI profile also starts Search and downloads
its embedding model during the first build:

```sh
docker compose --env-file .env -f docker/docker-compose.yml --profile ai up -d --build
docker compose --env-file .env -f docker/docker-compose.yml logs ai search
docker compose --env-file .env -f docker/docker-compose.yml exec ai curl -fsS http://localhost:8091/health
```

Missing required provider credentials prevent startup. If the paste LLM initializes
but the Ask engine fails, paste remains available and Ask returns HTTP 503.
Health alone does not prove that your provider can complete requests.

## Use

Ask exposes read-only `search_customers(query, limit, include_archived)` for the
company register. Query must be nonblank; limit defaults to 6 and caps at 12.
It sends typed-v1 asset filters `[8,9]` plus `customer.include_archived` (false
by default). Search folds matching contacts into companies before top-N and
returns companies only. Results contain decimal-string `asset_id` and complete
structured `customer` metadata, not clipped preview JSON.

`search_assets` remains raw semantic asset search: company/contact/activity,
their plurals and CustomerCompany/CustomerContact/CustomerActivity aliases are
supported; selecting `[8,9,10]` does not enable company-register semantics.
Both tools preserve `stale` and an explicit warning on reconciliation failure.
`complete=false` means ranked evidence is not an inventory; `limit_reached`
indicates possible additional matches, not a known total. Use exact listing tools
for inventory. Legacy Search/Similar consumers remain unchanged. These Ask tools
require the Search server's typed-v1 response header.

Customer results in `list_assets` and `get_asset` also expose complete structured
metadata without losing fields to the clipped display preview. In the new
`customer` object, numeric metadata values (including nested arrays/objects) are
exact decimal strings to avoid ADK's float64 rounding; only the fixed `version:1`
remains numeric. Booleans, nulls and strings retain their types. Stored NRC
metadata and CLI JSON are unchanged. Malformed raw
customer records remain available with `metadata_warning`; only the company
register requires valid metadata. Search traces/progress and citation titles use
the same integration as the existing tools. Customer mutation tools are not added.

### Exact reads, domain pages and attachments

`get_task` reads directly from NRC, including completed or uncached tasks. It
never substitutes a cache snapshot for the exact record or stale-write timestamp.
`search_tasks`, like asset/customer search, returns ranked top-N evidence with
`complete:false`, `stale`, `limit`, `limit_reached` and a ranking hint. Use paginated
`list_tasks`/`list_assets` for inventory, not relevance search.

Additional bounded, read-only tools use the existing server APIs:

- `query_calendar`: explicit RFC3339 range (max 62 days), assignee/project filters,
  limit 1–100 and server cursor. Includes overlapping appointments and task/reminder dates.
- `list_task_slices`: slice register with server membership counters, optional
  owner/name/include_closed filters, limit 1–100 and server cursor.
- `list_entity_links`: incident edges of a task/asset, including company and slice
  membership; limit 1–100, `has_more` and `next_edge_id` continuation.
- `list_attachments`: fresh owner metadata; no file download.
- `read_attachment`: default text mode reads PDF/DOCX/XLSX/UTF-8 text via Search's
  private `/attachment/text` endpoint. Default 16 KiB, max 32 KiB per page; follow
  `next_offset` while `has_more`. `complete` describes extraction coverage, not
  page coverage. PDF uses its text layer, at most 20 pages, without OCR; Office
  covers body/cell values only and explicitly reports partial coverage.

`get_asset` accepts optional byte `offset`/`limit` and returns `next_offset`,
`has_more`, `total_bytes` and `payload_truncated`; offsets preserve original
UTF-8 text, including whitespace. Search/list payloads explicitly distinguish
omitted from clipped content. `graph_walk` marks its bounded traversal as
non-exhaustive and reports clipping; use paginated links for exact incident edges.
New domain/attachment IDs and timestamps are decimal strings. All reads remain
in workspace data scope (`conv_id=0`), not private chat/DM history.

Attachment text requires the updated Search service and its configured `FILES_URL`
and `NRC_BOT_SECRET`. Native `mode:"media"` additionally requires AI's private
`FILES_URL` (wired in Docker Compose) and the shared bot secret. It sends at most
4 MiB of PNG/JPEG/GIF (max 16 megapixels) or WAV/MP3, after a fresh ownership read;
no arbitrary URLs, redirects or silent byte truncation are permitted.
The pinned provider adapter supports images on OpenAI/Anthropic and images/audio
on OpenAI Chat-compatible adapters; OpenAI Responses (gpt-5.6/gpt-6) is image-only.
OpenRouter/DeepSeek are explicitly unsupported for media tool results. Adapter
support is not a guarantee that the selected model accepts media. There is no
automatic image OCR or audio transcription fallback. Retrieved files may be
sent to the external LLM; the existing data-processing warning applies to them too.

- **Paste-to-Task:** paste unstructured text, edit the extracted task and confirm.
  The browser creates the task through its own WebSocket connection.
- **Paste-to-Note:** preview a cleaned-up note and optional extracted tasks.
  The browser creates the records after confirmation.
- **Sullivan:** ask a question about workspace work. It reads records and graph
  context and returns an answer with sources. In Plan mode, it can stage changes.
  Review the proposed actions before you approve them.

For example, ask what blocks the rollout. Then request a note that records the
decision and links to the relevant tasks. Review the note and links before applying.
An answer is not proof that work has been saved; check the apply result.

The configured CLI can retrieve the same kind of search and graph evidence:

```sh
nrc retrieve "What is connected to the rollout?" --depth 2 --paths best
```

Retrieve returns evidence, not an LLM-generated answer, and does not apply changes.
See the [CLI guide](../../../cli/README.md#search-and-retrieval).

## Limits and access

All durable context is workspace-wide. Selecting a room or DM changes where
progress is displayed, not which tasks, notes or files AI can read.
Sessions and pending plans exist in memory and expire; a restart removes them.
Keep durable decisions in notes and work in tasks, not only in an AI session.

Keep the HTTP API on the private Docker network. Public calls must pass through
the Tailscale proxy's identity, origin and workspace checks. The bot connection
can read and write workspace data. A restricted workspace does not prevent
operator access or LLM processing. See [Operations](../../../docs/OPERATIONS.md#trust-boundary).

Search-backed task queries include unloaded and Done tasks. If Search is
unavailable, the task-search tool can fall back to loaded records and reports
`complete: false`. Do not treat that fallback as a complete task inventory.

## API reference

The paths below are public paths through the Tailscale site. The internal AI
service uses the same paths without `/ai`, for example `/ask` and `/retrieve`.
Use `conv_id: 0`, or `context_conv_id: 0` for Ask. Nonzero durable scopes are rejected.
Ask's optional `display_conv_id` selects a chat progress destination, not a data filter.

| Method and public path | Purpose |
| --- | --- |
| `POST /ai/paste-to-task` | Return a task preview from `raw_text` |
| `POST /ai/paste-to-note` | Return a note preview; `extract_tasks` enables task extraction |
| `POST /ai/retrieve` | Return search and graph evidence without an LLM answer |
| `POST /ai/ask/ready` | Check workspace readiness for Ask |
| `POST /ai/ask` | Answer or stage a plan |
| `POST /ai/ask/apply` | Execute selected actions from a pending plan |
| `GET /ai/ask/session/{id}` | Read session state and pending plans |
| `POST /ai/ask/session/reset` | Clear a session |
| `GET /ai/health` | Report process status and provider settings; blocked with HTTP 403 when workspace restrictions are configured |

A paste request needs `workspace`, `conv_id` and `raw_text`:

```json
{
  "workspace": "workspace1",
  "conv_id": 0,
  "raw_text": "Test the rollout UI before Friday."
}
```

Paste-to-task returns `task`. Paste-to-note returns `note` and optional
`extracted_tasks`. These responses do not create records.

An Ask request:

```json
{
  "workspace": "workspace1",
  "context_conv_id": 0,
  "question": "What blocks the rollout?",
  "mode": "ask"
}
```

The response includes `answer`, `sources` and session identifiers. Reuse the
returned `agent_session_id` for follow-up requests. Use `mode: "plan"` and an
explicit change request to stage actions. The response then includes any
`proposed_actions` and `plan_id`.

**Apply writes to NRC.** Missing, null or empty `action_ids` selects every action.
Omitting `plan_id` selects the latest pending plan. Review the plan and send its
explicit ID with a nonempty list of approved action IDs. If you approve no actions,
do not call Apply.

```json
{
  "workspace": "workspace1",
  "agent_session_id": "RETURNED_SESSION_ID",
  "plan_id": "RETURNED_PLAN_ID",
  "action_ids": ["RETURNED_ACTION_ID"]
}
```

Supported actions create/update tasks, create/update/delete notes and create/delete
edges. Task deletion is not supported by this flow.
Actions can succeed or fail separately; a plan is not one atomic transaction.
Check `ok`, `applied` and `failed`, even with HTTP 200. If a request loses its
response, inspect the session and affected records before sending new mutations.

Retrieval accepts a query and bounded graph/content options:

```json
{
  "workspace": "workspace1",
  "conv_id": "0",
  "query": "rollout decision",
  "top_n": 10,
  "depth": 1,
  "direction": "both",
  "payload": "top",
  "payload_top": 3,
  "max_payload_bytes": 30000,
  "paths": "best"
}
```

Set `no_graph: true` for search only. `relations` filters graph relation types.
Each result reports `payload_state`: `complete`, `omitted` or `truncated`.
Load the record directly if the returned content is insufficient for your decision.

## Providers and configuration

| Provider | `LLM_PROVIDER` | API key | Base URL |
| --- | --- | --- | --- |
| OpenAI | `openai` | Required | Optional |
| OpenAI-compatible | `openai-compat` | Required | Required |
| OpenRouter | `openrouter` | Required | Override affects paste, not Ask |
| DeepSeek | `deepseek` | Required | Optional |
| Mistral | `mistral` | Required | Optional |
| Anthropic | `anthropic` | Required | Optional |
| Ollama | `ollama` | Not required | See below |

For Ollama, the model server must be reachable from the AI container. Its own
`localhost` address cannot reach a model server on the host.
Paste appends `/api/chat` to `LLM_BASE_URL`. Ask uses an OpenAI-compatible API
and defaults to `http://localhost:11434/v1` when the variable is unset.
Both use the same override when it is set. Check both API layouts on your endpoint;
one URL that works for paste is not necessarily suitable for Ask.

These are standalone defaults. Compose overrides service addresses and the nickname.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NRC_SERVER` | `ws://localhost:8080` | NRC WebSocket endpoint |
| `NRC_BOT_SECRET` | None | Must match the server's bot secret |
| `NRC_NICKNAME` | `Sullivan-{hostname}` | Bot nickname |
| `AI_PORT` | `8091` | Internal HTTP port |
| `SEARCH_URL` | `http://localhost:8090` | Search endpoint |
| `FILES_URL` | None | Private files endpoint for native attachment media reads |
| `LLM_PROVIDER` | `openai` | Provider from the table above |
| `LLM_MODEL` | `gpt-4o-mini` | Provider model name |
| `LLM_API_KEY` | None | Provider credential |
| `LLM_BASE_URL` | Provider default | Endpoint override |
| `MAX_CONTEXT_TOKENS` | `128000` | Workspace context budget |
| `LLM_MAX_OUTPUT_TOKENS` | Model-dependent | Output token budget |
| `SOURCEBOT_URL` | None | Enables optional code-search tools |
| `SOURCEBOT_ALLOWED_REPOS` | None | Required with Sourcebot: exact repository names or explicit `*` |
| `SOURCEBOT_API_KEY` | None | Optional `X-Sourcebot-Api-Key` credential |
| `SOURCEBOT_BEARER_TOKEN` | None | Optional bearer credential |

## Development

Requires Go 1.27.0 or newer (Fantasy v0.45.2). No native libraries are required.
Run from this directory:

```sh
CGO_ENABLED=0 go build -o nrc-ai .
go test ./...
```

Unit tests use local fixtures and fake providers. They do not prove that a hosted
provider or a local model can answer your production requests.
