# nrc-publish

Publish serves a public knowledge base from approved copies of NRC Markdown notes
and their attachments. It reads NRC but never writes to it. Editing a source note
does not change the public article; each update needs a new draft and human approval.

Readers can browse categories, search article text and download published files.
Pages are server-rendered, with no JavaScript, external fonts or tracking.

## Start

First set up the [core deployment](../../../README.md#quickstart).
Publish uses a separate [Compose overlay](../../../docker/compose.publish.yml),
not a profile. Docker Compose must support `!override`.

The stack's private `.env` supplies `NRC_BOT_SECRET`, `NRC_JWT_SECRET` and
`NRC_JWT_ISSUER` to NRC, the proxy and Publish. Use a non-default random signing
key. In a separate private environment file, set:

- `NRC_PUBLISH_WORKSPACE`: the workspace whose notes you want to publish.
- `PUBLISH_ADMIN_USER`: the human reviewer's login.
- `PUBLISH_ADMIN_PASSWORD`: a separate password of at least 16 characters.
  Do not give it to bots or agents.
- `PUBLISH_REVIEW_URL`: optional private HTTPS base URL for review links.
- `PUBLISH_BRAND`: optional site name; defaults to `NRC`.

Keep both files out of Git. Run from the repository root, replacing the second
environment-file path with your private file:

```sh
docker compose --env-file .env --env-file /private/publish.env \
  -f docker/docker-compose.yml -f docker/compose.publish.yml up -d --build
docker compose --env-file .env --env-file /private/publish.env \
  -f docker/docker-compose.yml -f docker/compose.publish.yml logs publish
```

Both host ports bind to loopback. Put **only port 8093** behind public HTTPS.
Port 8094 serves review pages and the private API. Reach review pages through a
separate private HTTPS ingress or a protected port forward, never the public site.
The overlay enables the restricted agent gateway on the Tailscale proxy; it does
not configure either public HTTPS or reviewer ingress.

For a standalone build, see [Configuration](#configuration) and
[Development](#development).

## Use

1. Sign into the **internal** listener and choose a workspace note (paginated picker
   or explicit note ID). Set public title, URL slug, summary, category and type.
2. Create a draft: copy that exact note body and all listed attachments into the
   publishing database. Nothing is public yet. HTML notes are refused.
3. Compare the stored draft with the published version, including metadata,
   Markdown source and downloadable attachments. Check the confirmation box and
   approve. Approval publishes the **stored** revision, never a fresh source read.
4. Later NRC/agent edits do not update the public article. Prepare another draft
   from the current note, review it and approve it. The review flags source changes
   observed since draft creation; there is no automatic subscription or publishing.
5. Withdraw removes the article from navigation, search and direct serving, and
   makes its revision's public file URLs inaccessible. Private history is retained.

Approval and withdrawal are atomic bbolt transactions. A draft records a publication
generation; concurrent approvals or an intervening withdrawal invalidate older
drafts, even when the article returns to an unpublished state. A stale withdrawal
cannot remove a newer version. Publication audit records retain actor and timestamp.
Revision history and audit are stored; a history/rollback UI is not provided yet.

## Limits and access

- Public listener (default `:8093`): only published articles, search and files; **no
  administrative routes or access to current NRC notes**.
- Administrative listener (default `127.0.0.1:8094`): HTTP Basic authentication with
  a dedicated human reviewer account and CSRF-protected writes. Deploy behind
  HTTPS on a private/Tailscale ingress. Do not give this password to bots/agents.
  This initial version uses one reviewer account, not an SSO/role-management system.
- The private agent API is reached only through the existing Tailscale proxy's
  `/publish/api/...` gateway. WhoIs verifies the connection identity and the proxy
  checks membership against the fixed publishing workspace. A signed, expiring
  workspace-bound assertion with a dedicated audience authenticates the backend;
  plain identity headers and ordinary NRC JWTs do not grant access. It permits
  listing and preparing/inspecting drafts, **never approval, withdrawal, HTML
  administration or attachment downloads**. Workspace members can read all pending
  drafts; this is not per-agent draft isolation. Missing WhoIs always fails closed,
  even with no membership policy. Unlisted workspaces remain tailnet-open, as in NRC.
- The NRC bot secret alone cannot approve anything. It is used only to read notes.
- Do not reverse-proxy the administrative listener under the public domain. This
  first version runs both listeners in one process; the process has NRC credentials,
  so process-level isolation of a read-only public renderer is not claimed.
- The attachment volume is trusted, read-only local infrastructure. Only files
  explicitly listed in the selected note **and granted to this workspace** are
  copied. Grant markers use the auth proxy's existing `.workspace-access/<file-id>/
  <sha256(workspace)>` format and must contain the same workspace name. `os.Root`
  confines filesystem reads. No arbitrary URL fetching, internal-file proxy, or
  file-ID-only public route. Old unscoped blobs are refused, not silently assigned;
  upload them through a workspace-aware client before publishing.
- Raw note HTML/scripts are not rendered. Images must be NRC attachments; relative
  `att:<index>` references generated by NRC and `/files/<file-id>` links resolve
  against the stored revision's attachments. Other relative internal links are
  refused except `/articles/...` and section anchors. Explicit
  HTTP(S) and mail links are shown for human review. Inspect them for internal URLs
  and confidential information before approval.
- File MIME is sniffed, only raster images render inline; other files download with
  sandbox CSP. No-store headers allow immediate origin withdrawal, but cannot revoke
  already downloaded copies or a misconfigured external cache.

## Configuration

| Variable | Default / requirement |
| --- | --- |
| `NRC_SERVER` | `ws://localhost:8080` (trusted internal NRC endpoint) |
| `NRC_WORKSPACE` | Required; one workspace per instance and data directory |
| `NRC_BOT_SECRET` | Required; existing NRC service secret |
| `PUBLISH_ADMIN_USER` | Required; human reviewer login |
| `PUBLISH_ADMIN_PASSWORD` | Required; at least 16 characters, separate from bot secret |
| `NRC_JWT_SECRET` | Existing private infrastructure signing key shared with Tailscale proxy; unset disables agent API, insecure default is rejected; never distribute to agents |
| `NRC_JWT_ISSUER` | `nrc-tailscale-proxy`, must match proxy |
| `PUBLISH_REVIEW_URL` | Optional private reviewer base URL; unset returns a relative review path, never an invented link under the API gateway |
| `PUBLISH_ADDR` | `:8093` |
| `PUBLISH_ADMIN_ADDR` | `127.0.0.1:8094` |
| `PUBLISH_BRAND` | `NRC` (escaped text in header/title/footer; wordmark adds `/ Wissen`) |
| `PUBLISH_DATA_DIR` | `data`; contains `publish.db` |
| `PUBLISH_FILES_DIR` | Existing NRC attachment directory; required for notes with files |

Provide credentials using your deployment's private secret mechanism, not command
history or tracked files. Mount a separate persistent data directory; do not
reuse it for another workspace (the database also enforces this). The process needs
read permission on both attachment bytes and private workspace-grant markers.
Back up `publish.db` with the service stopped or
using a bbolt-consistent snapshot, not an arbitrary copy during a write.

Categories are editor-selected names, independent of internal note projects/tags.
The initial model is flat, with one main category and one type per article
(`Anleitung`, `Referenz`, `Fehlerbehebung`); deeper trees/tags are not implemented.
Every attachment listed on the source note becomes part of the review/publication,
even if not referenced inline. Maximum 10 files, 20 MiB each, 64 MiB total per draft.
Drafts, withdrawn versions and their bytes remain in private storage; allow for
growth in backups. There is no retention/compaction command yet.

## CLI and private API

Use the existing `nrc` CLI on a Tailscale-connected machine or tagged runner. It
uses the existing configured proxy URL (`nrc config set proxy https://...`, or
derived from the configured WebSocket URL). `NRC_PUBLISH_URL` can override the
**Tailscale proxy base URL**, not the publishing backend. No agent token or identity
header is sent. The service instance fixes the workspace, independently of the
CLI's default workspace. Configure `NRC_PUBLISH_BACKEND` (e.g. `http://publish:8094`)
and `NRC_PUBLISH_WORKSPACE` on the proxy. The overlay supplies both. Proxy and
service must share the private non-default `NRC_JWT_SECRET` and issuer. Use HTTPS
on the tailnet; the backend and its signing key remain trusted infrastructure.

```sh
nrc publish list
nrc publish draft --note 41 --slug api-schluessel --title "API-Schlüssel erstellen" \
  --category "API & Integrationen" --kind Anleitung --summary "Schlüssel sicher anlegen."
nrc publish inspect <draft-id> --json
```

JSON is the default. Draft creation/inspection includes `review_path` and
`review_url` using the service's configured reviewer URL. `inspect` returns the
stored draft, current published version (or `null`) and advisory `stale` flag,
not a fresh NRC body. Note IDs are decimal strings, including IDs above JavaScript's
safe integer range; revision IDs are opaque hexadecimal strings. `--human` provides
an indented view of the same document.

The gateway allowlists `GET /publish/api/publications`, `POST /publish/api/drafts`
and `GET /publish/api/drafts/{id}` and forwards them without `/publish` to the
backend. Creation accepts `note_id` (decimal string), `slug`,
`title`, `summary`, `category`, `kind`; source body/files and creator cannot be
supplied. All snapshot/link/attachment validation is shared with human creation.
There is no agent approval or withdrawal endpoint. Human Basic credentials are
not accepted by the agent API, and proxy assertions cannot access human routes.
The public listener has no API routes. Do not expose the private listener publicly.

Creation is not idempotent. The CLI never retries mutations or follows redirects;
after a timeout/connection failure, inspect `list` before retrying to avoid duplicate
drafts. Creator identity is the full verified Tailscale login or deterministic
runner tag. Tailscale cannot distinguish an agent from a human on the same machine;
keep the reviewer password away from agents. The gateway does not expose the review
page itself: access it via the existing separately protected reviewer ingress or
an operator's local port forward. Assertion replay is bounded by its five-minute
expiry; policy changes require proxy restart as elsewhere in NRC.

### Compose details

The overlay mounts NRC attachments read-only. Its `!override` mappings remove the
base file's credential overrides so shared credentials come from the stack's `.env`.
The direct agent API rejects requests lacking a valid proxy assertion.
The container uses the auth proxy's root UID to read its `0700`/`0600` grant markers;
the overlay drops all capabilities, disables privilege escalation and makes the
root filesystem read-only. Only the dedicated publishing data volume is writable.
Compose interpolation does not use a service's `env_file`. The commands in
[Start](#start) pass `.env` explicitly for the base file's required-variable checks.
Keep the second environment file limited to publisher settings, not copies of the
shared credentials. Shell variables take precedence during interpolation; avoid
stale exports of publisher settings.

## Development

Requires Go 1.26 or newer. No native libraries are required. From this directory,
run `go build -o /tmp/nrc-publish .`. To run the service, set the required variables
from [Configuration](#configuration), then run `go run .`.

```sh
go test -race ./...
go vet ./...
# Real CLI/gateway/publisher; synthetic WhoIs and NRC source. Requires Playwright.
node browser.e2e.mjs
# Optional screenshots (use an absolute review-artifact directory):
PUBLISH_SCREENSHOTS=/absolute/path/to/artifacts node browser.e2e.mjs
# From the repository root; renders Compose only, no daemon or deployment:
python3 -m unittest test.test_publish_compose -v
```

For protocol integration, start a disposable NRC server with its own empty working
directory and configured bot secret. `PUBLISH_TEST_NRC_URL` **must not point to a
production installation**: this test creates, changes and deletes a fixture note.

```sh
PUBLISH_TEST_NRC_URL=ws://127.0.0.1:18083 go test -race -run '^TestLiveNRC$' -v
```

For interactive visual review, build the test binary with
`go test -c -o /tmp/nrc-publish-preview.test` and run its opt-in
`TestBrowserPreview` fixture with `PUBLISH_BROWSER_PREVIEW=1`, `-test.timeout 0`.
It uses temporary storage, illustrative content and the **test-only** credentials
`reviewer` / `only-for-tests-not-a-secret`; never use these in deployment.
Default preview ports are 8093/8094. `PUBLISH_PREVIEW_ADDR` and
`PUBLISH_PREVIEW_ADMIN_ADDR` override them. This fixture is excluded from the normal
application binary and does not seed production articles.
