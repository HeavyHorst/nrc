# Tailscale proxy

NRC's public gateway: a Go `tsnet` node that verifies Tailscale identity with
WhoIs, issues HS256 JWTs for WebSocket connections, forwards requests to Nginx,
and handles file uploads/downloads and document exports. It serves HTTPS on
port 443 in the tailnet and redirects HTTP on port 80 to HTTPS.

Use the [root quickstart](../../../README.md#quickstart) and
[operations guide](../../../docs/OPERATIONS.md) for deployment, secrets,
workspace membership and trust boundaries. Compose supplies `TS_AUTHKEY` and
persists node state in `/var/lib/tailscale`; enable tailnet MagicDNS and HTTPS.
Incoming identity/service headers are removed before verified identity is injected.
Browser requests must be same-origin; native clients without Origin are supported.

## Files and directory API

- `POST /upload?workspace=NAME`: multipart `file`, maximum 100 MiB. Returns file
  ID, URL and metadata. Specify workspace on all new uploads; it is mandatory
  with membership restrictions enabled.
- `GET /files/ID`: authenticated download; `?inline=true` requests inline
  disposition. HEAD and byte ranges are supported. Downloads check stored grants,
  not a caller's claim that a file belongs to a workspace.
- `GET /api/users`: sorted, deduplicated nickname directory from Tailscale status
  and observed visitors. This is neither a membership grant nor online presence.

Blobs are content-addressed under `/data/files/att_<32 lowercase hex>`: the first
16 bytes of SHA256 identify the content. Multiple references or uploads can
share one blob. Task/asset metadata lives in NRC's database, not this directory.
Workspace grants live alongside blobs under `.workspace-access/`; back them up
together. Without workspace restrictions, authenticated users share file access.
With restrictions, a file is readable through any one of its authorized workspaces.
Unreferenced blobs are handled by [offline attachment GC](../../../docs/ATTACHMENT_GC.md).

## Existing files in any workspace

Old blobs have no trustworthy workspace information. With any restricted
workspace configured, unscoped files are denied until explicitly assigned or
reuploaded, even if they originally belonged to `workspace1`. Without restrictions
their existing behavior is unchanged. A download query cannot create a grant.

**Do not use the bulk command if old files belong to different workspaces.**
Reupload those files into their correct workspaces instead.

If all unscoped files belong to one known workspace:

1. Stop the proxy and attachment GC.
2. Back up the attachments volume.
3. Use the updated proxy image. From the repository root, run the command below.
   Replace `YOUR_WORKSPACE` with the workspace that owns the files.

```sh
docker compose --env-file .env -f docker/docker-compose.yml run --rm --no-deps tailscale-proxy \
  --assign-legacy-files YOUR_WORKSPACE
```

The command takes an exclusive storage lock. It assigns only active blobs that
have no workspace grant. You can run it again; it does not change existing grants.

After the command succeeds, restart services with the required membership policy.
If the target workspace is not listed in the policy, it remains tailnet-open.
Upgrade old upload clients before you enable restrictions.
There is no automatic file migration.

## Public knowledge-base preparation

The optional publishing sidecar is reached through `/publish/api/...`. Configure
`NRC_PUBLISH_BACKEND` to its trusted private origin (e.g. `http://publish:8094`) and
`NRC_PUBLISH_WORKSPACE` to the sidecar's fixed workspace; the publishing Compose
overlay supplies these values. Unconfigured gateways return 503. A private,
non-default `NRC_JWT_SECRET` shared with the sidecar is required, as is a matching
`NRC_JWT_ISSUER` (default `nrc-tailscale-proxy`). No CLI bearer token is used.

Only listing publications, preparing drafts and inspecting drafts are forwarded.
Every request requires successful WhoIs and membership in the configured workspace
under `NRC_WORKSPACE_ACCESS`; an unlisted workspace remains open to authenticated
tailnet identities. Foreign browser origins, path aliases and caller-supplied
identity/signing headers are refused or stripped. The gateway signs a five-minute
workspace-bound assertion with audience `nrc-publish-agent`; the backend validates
it, so direct identity-header spoofing and normal NRC JWTs cannot bypass the proxy.
The signing key stays infrastructure-only. Reviewer HTML, approval and withdrawal
are not exposed by this route; they retain their separate reviewer credentials.
No publishing route is added to nginx. See `services/bots/nrc-publish/README.md`.

## Development

Requires Go 1.26.6 or newer and a writable attachment/state directory for running
the gateway. A standalone launch also needs its expected `http://nginx:80` backend.
For a complete deployment use Compose, not a bare `go run`.

```sh
# From this directory.
go build .
go test ./...
```
