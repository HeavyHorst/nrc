# nrc-publish

Publish serves a public knowledge base from approved copies of NRC Markdown notes
and their attachments. It reads NRC but never writes to it. Editing a source note
does not change the public article; each update needs a new draft and human approval.

Readers can browse categories, search article text and download published files.
Pages are server-rendered, with no JavaScript, external fonts or tracking.

Reading order is stored per category using NRC note IDs, separately from approved
article snapshots. Reviewers can choose **Kategorien und Artikel sortieren** in the
dashboard and assign each position once. Agents use the existing private gateway:

```sh
nrc publish list
nrc publish order --category "Marketplace" 596 5351 5348
```

Only already-published articles in that exact category are accepted. Listed IDs
come first; omitted and newly published articles follow alphabetically. With no
IDs, `nrc publish order --category "Marketplace"` restores alphabetical order.
The order applies to category cards, result lists and article navigation, survives
restarts and slug/title updates, and takes effect immediately without publishing
any drafts. Concurrent order edits use the last saved order.
The HTTP operation is `PUT /publish/api/order` with
`{"category":"Marketplace","note_ids":["596","5351","5348"]}`;
`GET /publish/api/publications` returns published articles in reading order.
Note IDs are strings to preserve full uint64 precision.

Main categories can also be reordered in that editor, independently of article
positions. Agents use exact published category names (quote names containing spaces):

```sh
nrc publish category-order "Marketplace" "Erste Schritte" "Referenz"
nrc publish category-order # Restore alphabetical category order
```

Listed categories come first; omitted and new categories follow alphabetically.
The order applies to the homepage, category navigation and publication list,
persists across restarts and takes effect immediately. Unknown or duplicate names
reject the entire change. Concurrent edits use the last saved order. The operation
is `PUT /publish/api/category-order` with `{"categories":["Marketplace","Erste Schritte"]}`;
an empty array resets the order. Article positions and approvals remain unchanged.

Categories support one optional subtopic level. In the same editor, enter a name
beside each article; matching names form a group, and an empty name leaves the
article directly in its category. Groups follow their first article's reading
position, and articles within each group retain their reading order. Topic pages
show group headings; the sidebar has collapsible groups and opens the active
article's group automatically.

Agents can assign several articles at once:

```sh
nrc publish subtopic --category "Marketplace" --name "Einstieg & Überblick" 595 596 597
nrc publish subtopic --category "Marketplace" --name "" 595
```

`PUT /publish/api/subtopics` accepts
`{"category":"Marketplace","assignments":{"595":"Einstieg & Überblick","596":""}}`.
Only specified IDs change, and an invalid assignment rejects the whole request.
The publication list includes `subtopic` for assigned articles. Assignments are
separate navigation metadata keyed by category and NRC note ID: they survive
restart and slug/revision changes without requiring approval. Moving an article
to a different category does not carry the old category's assignment with it.

The NRC note ID identifies an article. The dashboard shows only the newest pending
version per note, even if earlier drafts used different slugs. Approval replaces
the existing public article for that note rather than publishing a second one.
The comparison and the Update label follow the note ID too.

In Markdown prose, `[note:123]` becomes a link to `/articles/by-note/123`, labelled
with the reviewed public title. This stable route redirects to the note's current
published slug with a non-cacheable 302 response. It never reads unpublished NRC
notes. Retired public slugs also redirect to the current article for that note;
withdrawal makes both the ID route and old URLs unavailable.
Missing targets do not block draft creation: the private preview marks each
unresolved reference and disables individual approval.
Prepare the target articles too, select the related drafts in the dashboard and
choose **Auswahl gemeinsam prüfen**. This also works for circular references.
The group review resolves missing references against the selected drafts and
published articles in this workspace, then stores the exact URLs and titles for
human review. Nothing is public until the reviewer confirms the whole selection.
All selected articles are published in one transaction, or none are.

Group selection rejects multiple versions of the same note. Code spans, code blocks
and existing link labels are left unchanged. Already-resolved links retain their
reviewed titles and URLs; new ID-based links keep working after slug changes.
Approval refuses missing targets outside the selected group, discarded drafts and
publication conflicts. A target withdrawn after publication can still break links
in existing articles; those articles need a separately reviewed update.
Older published snapshots remain unchanged. To resolve their note references,
create a new draft or include an existing pending draft in a new group review.

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

### Internal test on the deployment host

On `lti1`, keep publisher settings in `/root/nrc/publish.env` with mode `0600`.
The source workspace is `workspace1`. Do not configure public ingress during the
internal test. Forward both loopback listeners from your own machine:

```sh
ssh -N -L 127.0.0.1:18093:127.0.0.1:8093 \
  -L 127.0.0.1:18094:127.0.0.1:8094 root@lti1
```

Open `http://127.0.0.1:18093` for the reader site and
`http://127.0.0.1:18094` for review. The reviewer username is `rene`;
retrieve the generated password yourself from the private server file, without
sharing it with agents. No article is published until a human approves a draft.

`docker/deploy.sh` detects the remote `publish.env` and uses the overlay for all
Compose operations. It tests and rebuilds Publish when its source changes.
`docker/backup.sh` is installed as `/usr/local/sbin/nrc-backup`; it stops and
restarts Publish along with the running stack and backs up all project volumes,
including `docker_publish-data`. Back up `.env` and `publish.env` separately with
your private credential backup mechanism; they are not part of the volume backup.

## Use

1. Sign into the **internal** listener and choose a workspace note (paginated picker
   or explicit note ID). Set public title, URL slug, summary, category and type.
2. Create a draft: copy that exact note body and all listed attachments into the
   publishing database. Nothing is public yet. HTML notes are refused.
3. Compare the stored draft with the published version, including metadata,
   Markdown source and downloadable attachments. Check the confirmation box and
   approve. Approval publishes the **stored** revision, never a fresh source read.
   For missing link targets, prepare their drafts and select all related articles
   in the dashboard. Review the resolved links and all article comparisons before
   confirming the group. If the target is already published, the draft's
   **Linkziele erneut auflösen & prüfen** button prepares a fresh link review
   without rereading the source note.
4. Later NRC/agent edits do not update the public article. Prepare another draft
   from the current note, review it and approve it. The review flags source changes
   observed since draft creation; there is no automatic subscription or publishing.
5. Withdraw removes the article from navigation, search and direct serving, and
   makes its revision's public file URLs inaccessible. Private history is retained.

Approval and withdrawal are atomic bbolt transactions. A draft records a publication
generation for its source note; concurrent approvals or an intervening withdrawal
invalidate older drafts, even when the article returns to an unpublished state. A stale withdrawal
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
  listing, preparing/inspecting drafts and changing article order, **never approval, withdrawal, HTML
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
| `PUBLISH_BRAND` | `Dokumentation`; escaped site name in header and page title, no fixed product suffix |
| `PUBLISH_FOOTER_TEXT` | Optional plain-text footer; empty by default |
| `PUBLISH_IMPRINT_URL` | Optional Impressum link: HTTP(S) URL or root-relative path |
| `PUBLISH_PRIVACY_URL` | Optional Datenschutz link: HTTP(S) URL or root-relative path |
| `PUBLISH_TERMS_URL` | Optional Nutzungsbedingungen link: HTTP(S) URL or root-relative path |
| `PUBLISH_CONTACT_URL` | Optional Kontakt link: HTTP(S) URL or root-relative path |
| `PUBLISH_THEME_FILE` | Optional trusted local CSS file, loaded at startup and appended to the base stylesheet |
| `PUBLISH_DATA_DIR` | `data`; contains `publish.db` |
| `PUBLISH_FILES_DIR` | Existing NRC attachment directory; required for notes with files |

### Corporate design and legal links

Set the site name, footer text and legal URLs in the private `publish.env` file.
Without footer text or links, no footer is displayed. Legal links point to your
existing pages or approved `/articles/<slug>` pages; configuring a URL does not
create an Impressum or privacy statement. Verify their content before public launch.

The Compose overlay mounts the host directory `publish-branding` read-only at
`/branding`. Put your stylesheet in `publish-branding/theme.css` and set
`PUBLISH_THEME_FILE=/branding/theme.css`. For example:

```css
:root {
  --accent: #165a91;
  --accent-hover: #10436c;
  --background: #f6f8fb;
  --ink: #172a3a;
  --muted: #526676;
  --line: #cbd6df;
  --pale: #e6eef5;
  --surface: #ffffff;
  font-family: Arial, sans-serif;
}
```

The theme can override CSS selectors as well as these tokens. Only operators
should supply theme files; CSS is not user-generated content. External resources
remain blocked by the existing CSP. An unreadable configured theme prevents
startup rather than silently falling back. Recreate Publish after changing its
environment or theme file; neither requires new article approvals. Protect
deployment-specific files separately: Git synchronization and the volume backup
do not include `publish.env` or `publish-branding`.

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

The gateway allowlists `GET /publish/api/publications`, `POST /publish/api/drafts`,
`GET /publish/api/drafts/{id}`, `PUT /publish/api/order`, `PUT /publish/api/category-order`
and `PUT /publish/api/subtopics`, forwarding them without `/publish` to the
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
