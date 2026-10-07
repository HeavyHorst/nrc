# nrc-search

Search indexes workspace records and combines local semantic search with
case-insensitive substring matching. It indexes tasks, including Done history,
and selected asset types. It does not index room or DM chat.

## Start

First set up the [core deployment](../../../README.md#quickstart).
Use the same `NRC_BOT_SECRET` for the server and Search. No LLM API key is needed.
The image build downloads the embedding model and native libraries; allow roughly
4 GiB for model downloads and additional RAM for media inference. The image
contains the text backbone plus image and audio encoders and the previous 300M
model for migrations; no cloud API is used.

Run from the repository root:

```sh
docker compose --env-file .env -f docker/docker-compose.yml --profile search up -d --build
docker compose --env-file .env -f docker/docker-compose.yml logs search
docker compose --env-file .env -f docker/docker-compose.yml exec search curl -fsS http://localhost:8090/health
```

The health response reports that the process is running. It does not prove that
a workspace has been indexed. The first query loads a new workspace's data;
model migrations rebuild all previously known workspaces without waiting for queries.

## Use

Use Search through the web client or the configured [CLI](../../../cli/README.md):

```sh
# Search notes by meaning and text.
nrc search query "rollout decision" --type note

# Include tasks and notes.
nrc search query "release blocker" --entity task,asset --type note

# Find matching tasks in a project, including completed work.
nrc search query "rollout" --entity task --project Backend --status todo,progress,done
```

An unfiltered text query returns assets only. CLI task filters such as `--project`
select tasks when `--entity` is omitted. Use `--entity task,asset` to search both.
Results contain record identities, previews and scores, not an LLM-generated
answer. Use `--payload` to include content.

## Limits and access

Search reads workspace-wide data through its trusted bot connection. Keep its
HTTP API on the private Docker network. Public requests must pass through the
Tailscale proxy's identity and workspace checks. Do not expose port 8090 directly.
See [Operations](../../../docs/OPERATIONS.md#trust-boundary).

Embeddings and indexed text stay local. Index updates are asynchronous, so a new
or changed record may not appear immediately. Search periodically reconciles
against the server to recover missed updates. A response with `stale: true`
means reconciliation failed and the cached results may be out of date.
Search data is a derived index, not a database backup.

The Docker image downloads revision-pinned EmbeddingGemma 2 ONNX weights under
Apache-2.0 and legacy EmbeddingGemma 300M under Google's Gemma terms, not NRC's MIT license. See
[third-party notices](../../../THIRD_PARTY_NOTICES.md).

Search uses 768-dimensional normalized vectors and an 8,192-token text input
limit. File assets and attachments on indexed assets/tasks contribute independent
chunks to the owner's search result:

- PNG, JPEG, WebP and single-frame GIF: image embeddings, searchable by text.
- WAV, MP3, Ogg/Opus, FLAC, M4A and AAC: audio embeddings in 30-second windows,
  up to ten minutes. This is semantic audio search, not transcription.
- PDF: text extraction; PDFs without extractable text are rendered and embedded
  page by page (at most 20 pages). Diagrams in text-bearing PDFs are not separately
  embedded, and scanned PDFs do not receive a searchable OCR transcript.
- DOCX: document-body text. XLSX: worksheet cells, shared/inline strings and cached
  formula values. Macros, formula evaluation, embedded images and old DOC/XLS
  formats are not supported.

Downloads are limited to 100 MiB, extracted text/XML to 16 MiB, raster images to
16 megapixels and 8,192 pixels per side. Oversized/invalid attachments fail without
discarding the owner's text. `metadata.attachments` exposes each file's
`file_id`, `filename`, `status` (`indexed`, `failed`, `unavailable`, `unsupported`,
`disabled`) and optional error. Downloads returning HTTP 403/404 are logged and
marked `unavailable`; they do not block index activation. Failed and unavailable
attachments are retried on later reconciliation.
Original record payloads remain unchanged; extracted text persists in the derived
index for substring matching. Results identify the owning record, not an exact
page, cell or audio timestamp. Video and other file formats are not indexed.

Compose enables a separate private proxy listener for Search's authenticated
downloads. It requires an explicit grant for the requested workspace, even when
the public gateway runs without membership restrictions. Legacy unscoped files
therefore require correct reupload/assignment; see
[existing file grants](../../auth/tailscale-proxy/README.md#existing-files-in-any-workspace).
Never publish the private file listener's port.

Upgrading changes the default embedding schema to
`embeddinggemma-2-v2-attachments`. Search keeps the previous model and index serving
while it eagerly rebuilds every known workspace in a separate directory from the
canonical server inventory, including File assets and attachments. Live changes
are subscribed in both generations. Only when inventories, queues, source hashes
and attachment processing are complete does it switch model and index together.
Failed downloads/embedding jobs postpone activation and retry, except for HTTP
403/404 downloads. Unavailable files and unsupported formats are reported but
do not block activation. HTTP 401, network errors and server errors remain blocking.
The old derived database is deleted after
activation and in-flight searches finish. Source records and blobs are never deleted.

The durable `DATA_DIR/active-index.json` pointer selects the active generation.
An interrupted rebuild leaves the old index active and resumes on restart; a crash
after activation finishes old-index cleanup on restart. Keep room for both indexes
and both models in RAM during migration. There is no rebuild-induced search outage,
but the normal process restart still interrupts requests briefly.

Remove an old `EMBEDDING_SCHEMA` override or set it to the new value. Custom
`MODEL_PATH` and `TOKENIZER_PATH` identify the new model. When migrating a custom
previous model, set `PREVIOUS_MODEL_PATH` and `PREVIOUS_TOKENIZER_PATH` to its
matching retained files (the Docker defaults provide the old 300M model).
Paths saved in the active manifest must remain available across restarts until
that generation has been retired. Changing model weights requires a new schema;
300M and Gemma 2 text vectors are not treated as compatible.

## API reference

Send `POST /search` through the Tailscale site. The internal service uses the
same path. All durable scopes, including similarity seeds, must be `0`.

```json
{
  "workspace": "workspace1",
  "conv_id": "0",
  "query": "release blocker",
  "top_n": 10,
  "filters": {
    "entity_types": ["task", "asset"],
    "asset_types": [5],
    "task": {"statuses": [1, 2, 3], "projects": ["Backend"]}
  }
}
```

The response has `results` and `stale`. Each result has an `entity` identity
(`workspace`, `type`, string `id`, string `conv_id`), `metadata`, `score` and
`preview`. Set `include_payload: true` to request content.
Responses advertise `X-NRC-Search-Version: typed-v1`. Clients that require task
results must check that capability rather than assume an asset-only server supports it.

- `filters.entity_types`: `asset`, `task`, or both. Text queries default to assets;
  similarity queries default to the seed's entity type.
- `filters.asset_types`: asset-type filter; `5` selects notes. Applies only to
  assets. The legacy top-level `asset_types` field is also supported.
- `filters.task`: supports `statuses`, `assignees`, `projects`, `priorities`,
  `colors`, `created_by`, `completed_by`, `task_ids`, `external_refs`, `blocked`,
  `blocked_by` and `overdue_before`.
- Task statuses: `0` Backlog, `1` Todo, `2` In Progress, `3` Done. These are the
  defaults when no status filter is supplied. Legacy `4` Note requires an explicit filter.
- Values within a filter field are ORed; fields are ANDed. String filters are
  exact and case-insensitive. Filters run before ranking and the result limit.
- `blocked` tests whether the task has a blocker. `overdue_before` requires a
  positive due date before the supplied Unix-nanosecond cutoff and excludes Done.
- Omit `query` for filter-only task listing. Those results sort by most recent
  update, then entity identity.

For similarity to an indexed record, replace `query` with a seed:

```json
{
  "workspace": "workspace1",
  "similar_entity": {"type": "task", "id": "42", "conv_id": "0"},
  "filters": {"entity_types": ["task"]},
  "top_n": 10
}
```

Use decimal strings for task and blocker IDs to preserve uint64 precision.
Legacy `similar_asset_id`, `asset_id` and `asset_type` fields remain supported.
Legacy room/DM embeddings are not relabeled as workspace data.

## Configuration

These are standalone defaults. Compose sets container paths and the NRC server URL.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NRC_SERVER` | `ws://localhost:8080` | NRC WebSocket endpoint |
| `NRC_BOT_SECRET` | None | Must match the server's bot secret |
| `NRC_NICKNAME` | `search-{hostname}` | Bot nickname |
| `SEARCH_PORT` | `8090` | Internal HTTP port |
| `MODEL_PATH` | `./models/model.onnx` | ONNX model path |
| `TOKENIZER_PATH` | `./models/tokenizer.json` | Tokenizer path |
| `DATA_DIR` | `./data` | Persistent index directory |
| `EMBED_ASSET_TYPES` | `1,2,3,4,5` | Comments, documents, files, workspace memos and notes |
| `EMBED_TASKS` | `true` | Index tasks, including Done history |
| `FILES_URL` | Unset | Private proxy origin; unset disables attachment ingestion |
| `MEDIA_MODEL_DIR` | Unset | Absolute local directory with processor configs and `onnx/` media encoders |
| `MEDIA_WORKER_PATH` | `./media_worker.mjs` | Local Node media worker |
| `RECONCILE_INTERVAL` | `15m` | Reconciliation interval |
| `EMBEDDING_SCHEMA` | `embeddinggemma-2-v2-attachments` | Change to rebuild embeddings after model/prompt changes |

## Development

Requires Go 1.26 or newer. A normal build needs libtokenizers. Running the service
also needs ONNX Runtime and the model files. Use the [Dockerfile](Dockerfile)
for the dependency versions and installation steps. Media ingestion additionally
requires Node.js 24, `npm ci`, FFmpeg and Poppler (`poppler-utils`). The processor
configs and all three ONNX models must use the same pinned revision.

From this directory:

```sh
go build -o nrc-search .
go test ./...
```

Without native dependencies, run tests with fake embedders:

```sh
go test -tags noembed ./...
npm ci
npm test
```

Real inference tests are opt-in: set `TEST_MODEL_PATH`, `TEST_TOKENIZER_PATH`,
`ONNXRUNTIME_PATH` (and the libtokenizers link path) for Go tests;
also set `MEDIA_MODEL_DIR` to exercise image/audio inference in Go and Node tests.

The `noembed` build cannot run real model inference or serve semantic search.
The normal service uses EmbeddingGemma 2 vectors and substring matches, merged
with Reciprocal Rank Fusion. It scans candidates within each workspace.
Measure your workload rather than assume a fixed latency:

```sh
go test -tags noembed -run '^$' -bench '^BenchmarkSearchVsParallel$' -benchmem
```

This benchmark measures search with test embeddings, not model inference.
