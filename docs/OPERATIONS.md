# Operations

Use the [README quickstart](../README.md#quickstart) for a new installation.
Run these commands from the repository root. Keep `.env` private and back it up
securely. Do not use the standalone server's development secrets in production.

## Configuration

Compose loads `.env` for the proxy, server and sidecars. After you change the
file, recreate the affected containers. Editing `.env` does not change running
containers. Generate random JWT and bot secrets. Compose rejects empty values
but does not check their randomness.
Pass `--env-file .env` in Compose commands. A service's `env_file` sets container
variables but does not supply values for Compose's `${...}` substitutions.

| Variable | Meaning |
| --- | --- |
| `NRC_JWT_SECRET` | Shared HS256 secret for proxy-issued human identity tokens |
| `NRC_BOT_SECRET` | Separate credential for trusted service connections |
| `TS_AUTHKEY` | Tailscale node enrollment; node state persists in `tailscale-state` |
| `NRC_WORKSPACE_ACCESS` | Optional workspace membership policy (below) |
| `NRC_MESSAGE_RETENTION` | `0` by default; positive integer with `s`, `m`, `h` or `d` enables room history |
| `NRC_THREAD_COUNT` | Worker override (1–256); default derives from allowed physical cores |
| `NRC_SERVICE_CPU` | Optional allowed logical CPU for service/main-thread work |
| `NRC_LOG_LEVEL` | Server console logging: `debug`, `info`, `warn`, `error`, `fatal` |
| `NRC_JWT_ISSUER`, `NRC_JWT_AUDIENCE` | Optional token checks; configure matching values on proxy and server |
| `NRC_CUSTOMERS_USERS` | Customer UI allowlist of full Tailscale logins; not a data-access restriction |

The server defaults to port 8080 (`NRC_PORT`). Keep this port in the supplied
stack. Nginx and sidecars connect to it. See [`.env.example`](../.env.example)
for retained-message cache, quota, retry-window and batch settings.
Cache budgets count serialized bytes, not total process memory. The default retry
window is 2m. If you enable retention, set the retry window to no more than the
retention period. If you reuse a message ID after that window, the server may
append a second message.

## Workspace access

If `NRC_WORKSPACE_ACCESS` is unset or empty, every workspace is open to
authenticated tailnet identities. To restrict a workspace, add its policy to
`.env` before you store private data:

```dotenv
NRC_WORKSPACE_ACCESS='{"private":{"owner":"alice@example.com","members":["bob@example.com","tag:nrc-client"]}}'
```

To restrict the quickstart workspace, use `workspace1` as the key instead of
`private`. To open `private`, append `/#workspace=private` to the site URL.

Only named workspaces are restricted. Unlisted workspaces, including `workspace1`,
remain tailnet-open; **deleting an entry opens that workspace again**. Identities
are full verified Tailscale logins or node tags, not display nicknames. For tagged
nodes, the proxy uses the alphabetically first valid `tag:` value, with at most
32 characters including the prefix. List that tag in the policy.
All members have normal workspace capabilities. There are no per-project roles.

After you change membership, stop the old proxy to close existing connections.
Then recreate the proxy, server and AI containers. Recreating AI cancels its
pending work and clears its sessions. Editing the configuration alone does not
close existing connections. You cannot revoke data that a user has downloaded.

**Existing file stores need special care:** once restrictions are enabled, legacy
unscoped files are denied until assigned or reuploaded. Read the
[proxy's file-grant migration procedure](../services/auth/tailscale-proxy/README.md#existing-files-in-any-workspace)
before enabling this on an existing installation.

## Trust boundary

```text
Tailnet client → Tailscale proxy → Nginx → NRC / optional Search and AI
```

The proxy verifies identity with WhoIs, rejects foreign browser origins, checks
configured workspace membership, and issues workspace-bound JWTs. The server
validates the JWT during the WebSocket upgrade. Caller-supplied identity/service
headers are discarded at the proxy boundary. Browsers use the same origin for all APIs.

Keep Nginx, the Odin server and Search/AI HTTP APIs on the private Docker network.
Their internal bot credential permits privileged data access; direct sidecar
access bypasses the public membership boundary. A custom auth gateway must
implement equivalent identity, workspace, origin and file-access checks; simply
adding an OIDC login in front of Nginx is not equivalent. NRC validates HS256
tokens, not arbitrary OIDC provider tokens.

Search embeds data locally. AI sends supplied text and retrieved workspace context
to the configured LLM provider. Private workspace membership does not prevent
operator/bot access or external LLM processing. Use a suitably configured local
provider if data must stay local.

Optional Publish has a separate public listener for approved articles and files.
Only that listener (port 8093) may be exposed through public HTTPS. Keep its review
interface and API (port 8094) private. The Tailscale proxy's agent gateway checks
membership in the publishing workspace and permits draft preparation, not approval.
See [Publish](../services/bots/nrc-publish/README.md#limits-and-access).

## Optional services

The default stack starts only `websocket-server`, `nginx` and `tailscale-proxy`.
If Search or AI is not running, requests to its API return HTTP 502.
Chat and durable data do not need these services.

Before you start AI, set `LLM_PROVIDER`, `LLM_MODEL` and the required credentials
in `.env`. OpenAI is the default provider and requires `LLM_API_KEY`.
Without that key, AI fails to start. For Ollama, start a model server that the
AI container can reach. Do not use the container's own `localhost` address.

```sh
# Local semantic + substring search; downloads the model during the image build.
docker compose --env-file .env -f docker/docker-compose.yml --profile search up -d --build

# Start AI and Search after you configure the LLM provider.
docker compose --env-file .env -f docker/docker-compose.yml --profile ai up -d --build

# Prometheus exporter. The example .env binds its host port to loopback.
docker compose --env-file .env -f docker/docker-compose.yml --profile metrics up -d --build
```

You can combine profiles. See [AI](../services/bots/nrc-ai/README.md),
[Search](../services/bots/nrc-search/README.md), [Metrics](../services/bots/nrc-metrics/README.md).
Search's image downloads roughly 1.2 GiB of model data and includes native libraries.
The `registry` profile is only a local image registry; it is not needed to run NRC.

To stop AI, run `docker compose --env-file .env -f docker/docker-compose.yml stop ai`.
Replace `ai` with `search` or `metrics-bot` to stop those services.
Removing a profile from a later `up` command does not stop a running service.

Publish uses `docker/compose.publish.yml`, not a profile. It copies Markdown notes
and their attachments into a separate database for human review. Source changes
do not update public articles automatically. Follow the
[Publish quickstart](../services/bots/nrc-publish/README.md#start) for credentials,
the overlay commands and the two listener boundaries.

## Backups and upgrades

- Stop the server and proxy before you back up the database and files.
  Back up the **complete** `task-data` and `attachments` volumes together,
  including manifests, `.workspace-access` grants and quarantine state.
- Back up `tailscale-state` and configuration securely. You can rebuild Search's
  `search-data` index. AI sessions exist only in memory.
- If you run Publish, stop it and back up its `publish-data` volume separately.
  It contains approved copies, private drafts, withdrawn revisions and audit history;
  it cannot be rebuilt from the current NRC notes alone.
- Keep the services stopped while you restore the database and attachments.
  Restore both from the same backup. Test the restore on a separate installation.
  Do not test it on a running shared installation.
- Back up before you upgrade. Upgrade the server, web client, CLI and bots
  together. Older binaries may not read newer protocol or manifest formats.
  To return to an older version, you may need to restore the pre-upgrade backup.
- **Do not use `docker compose down -v` for routine shutdown.** It deletes named
  volumes. Use `down` without `-v` to keep stored data.

Detailed procedures: [sharded persistence](SHARDED_PERSISTENCE.md),
[offline attachment GC](ATTACHMENT_GC.md), and the
[pinned legacy migration runbook](SHARDED_PERSISTENCE_MIGRATION.md).
Current binaries do not contain the historical worker-WAL migration commands.

## Troubleshooting

Run `docker compose --env-file .env -f docker/docker-compose.yml ps` and check service logs.

- If access fails, check Tailscale enrollment and ACLs, HTTPS certificates,
  matching JWT secrets and workspace membership with full login names.
- If the server fails to start, check the host's io_uring support, memlock limits
  and container policy.
- If Search or AI is unavailable, check that its profile is running. Then check
  its model and provider settings.
