# nrc-search

Search indexes workspace records and combines local semantic search with
case-insensitive substring matching. It indexes tasks, including Done history,
and selected asset types. It does not index room or DM chat.

## Start

First set up the [core deployment](../../../README.md#quickstart).
Use the same `NRC_BOT_SECRET` for the server and Search. No LLM API key is needed.
The image build downloads the embedding model and native libraries; allow roughly
1.2 GiB for model downloads.

Run from the repository root:

```sh
docker compose --env-file .env -f docker/docker-compose.yml --profile search up -d --build
docker compose --env-file .env -f docker/docker-compose.yml logs search
docker compose --env-file .env -f docker/docker-compose.yml exec search curl -fsS http://localhost:8090/health
```

The health response reports that the process is running. It does not prove that
a workspace has been indexed. The first query loads that workspace's data.

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

The Docker image downloads EmbeddingGemma model weights. They use the
[Gemma Terms of Use](https://ai.google.dev/gemma/terms), not NRC's MIT license.
Check the use and distribution requirements before offering a hosted service or
redistributing the image. See [third-party notices](../../../THIRD_PARTY_NOTICES.md).

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
| `EMBED_ASSET_TYPES` | `1,2,4,5` | Comments, documents, workspace memos and notes |
| `EMBED_TASKS` | `true` | Index tasks, including Done history |
| `RECONCILE_INTERVAL` | `15m` | Reconciliation interval |
| `EMBEDDING_SCHEMA` | `embeddinggemma-300m-v1` | Change to rebuild embeddings after model/prompt changes |

## Development

Requires Go 1.26 or newer. A normal build needs libtokenizers. Running the service
also needs ONNX Runtime and the model files. Use the [Dockerfile](Dockerfile)
for the dependency versions and installation steps.

From this directory:

```sh
go build -o nrc-search .
go test ./...
```

Without native dependencies, run tests with fake embedders:

```sh
go test -tags noembed ./...
```

The `noembed` build cannot run real model inference or serve semantic search.
The normal service uses EmbeddingGemma vectors and substring matches, merged
with Reciprocal Rank Fusion. It scans candidates within each workspace.
Measure your workload rather than assume a fixed latency:

```sh
go test -tags noembed -run '^$' -bench '^BenchmarkSearchVsParallel$' -benchmem
```

This benchmark measures search with test embeddings, not model inference.
