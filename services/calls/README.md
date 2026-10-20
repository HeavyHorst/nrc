# NRC optional conferences backend

Standalone Go signaling service; **no audio/video forwarding or processing**.
Invitations use 1:1 DMs; an existing conference can receive additional invitees.
The NRC proxy and web client integrate this service;
Jitsi is hosted separately. Run one replica: DM call state is ephemeral, in memory,
not shared or persisted; scheduled room identities are persisted locally. Conferences open in a separate provider tab. Acceptance
completes the NRC invitation and releases both users for new calls. NRC does not
track attendance or terminate delivered conferences.

## Build and test

From the repository root (Go 1.26+):

```sh
go -C services/calls test -race ./...
go -C services/calls build -o /tmp/nrc-calls ./cmd/nrc-calls
docker build -f services/calls/Dockerfile -t nrc-calls .
```

The local replace directive uses `../../protocol-go`; Docker needs the repository
root as build context. The image runs as UID 10001 and contains CA certificates.

## Configuration

| Environment variable | Contract/default |
| --- | --- |
| `CALLS_LISTEN` | `:8090` (internal HTTP; TLS termination is the proxy's responsibility) |
| `CALLS_DATA_DIR` | `data/calls`; durable scheduled provider room identities, private writable directory, one service instance. Compose mounts `calls-data` at `/data`. Back up with NRC data. No personal tokens are stored here. |
| `NRC_JWT_SECRET` | Required, at least 32 bytes; rejects the known development default. Shared with proxy and NRC server. Use a randomly generated secret. |
| `NRC_JWT_ISSUER` | `nrc-tailscale-proxy`; must match proxy and server configuration |
| `NRC_JWT_AUDIENCE` | `nrc`; audience for **upstream NRC** assertions, not calls assertions |
| `NRC_SERVER` | `ws://server:8080`; ws/wss origin, no path/query/credentials |
| `JITSI_URL` | Required HTTPS origin, e.g. `https://meet.example.org`; no tenant/path/query/credentials |
| `JITSI_APP_ID` | Required; Jitsi shared-secret app ID / token issuer |
| `JITSI_SECRET` | Required, at least 32 bytes; Jitsi's shared app secret |

Enable with the optional overlay (after supplying the variables above):

```sh
docker compose --env-file .env -f docker/docker-compose.yml -f docker/compose.calls.yml up -d --build
```

The overlay sets proxy `NRC_CALLS_BACKEND=http://calls:8090`; without it the UI
has no call controls. The proxy exposes `/calls/ws/<workspace>` with same-origin
and workspace checks. No calls port is published. A fresh production client
build is required, as for all frontend changes. Configure HTTPS and camera/microphone
permissions on your conference deployment; NRC embeds no provider code.

Open a DM and choose **VIDEO CALL**. The other user's connected NRC devices show
**ACCEPT / DECLINE**. The caller can cancel. After acceptance, each selected device
gets **JOIN**, an explicit link opening a separate tab. **CONFERENCES** lists
available conferences with stable titles and link expiry. Closing the compact
panel only hides it; reopen it from that list. Leave the provider tab to stop audio/video. Leaving
that tab is not reported to NRC. Other devices retain status without a join link. Incoming
calls do not steal keyboard focus. Ring audio needs prior browser interaction;
there are no push notifications when NRC is closed. State is not chat history.

Choose **INVITE PERSON** in the accepted conference panel, select a person,
then **INVITE**. The recipient receives the usual accept/decline invitation.
Acceptance issues a participant-specific link to the **same** provider meeting;
the inviter's bearer link is never forwarded. Any accepted participant can invite
others, subject to mutual DM access. Declining, canceling or failing an additional
invitation never ends the existing conference. Its recipient/status appears
separately from the stable conference title. Reloading or returning to a workspace
restores unexpired entries after authentication; links are not stored in browser
storage or chat history. Expired entries disable joining/inviting without claiming
the media session ended. Restarting the calls service loses these ephemeral entries,
not external media. People without an existing DM are not listed in the picker.

There is **no public/anonymous Jitsi fallback**. The configured deployment must
enforce tokens (`authentication = "token"`, `allow_empty_token = false`) and
MUC `token_verification`, accepting this app's issuer and audience `jitsi`.
Do not enable an anonymous guest domain that bypasses these restrictions.

The Jitsi adapter follows the official
[Jitsi token documentation](https://github.com/jitsi/lib-jitsi-meet/blob/master/doc/tokens.md):
HS256, `iss=JITSI_APP_ID`, `aud=jitsi`, `sub=lowercase JITSI_URL hostname`,
`room=unguessable exact room name` (never `*`), `nbf`, `exp`, and
`context.user={id,name}` per selected participant. `join.url` is the HTTPS room
URL with a participant-specific `jwt` query parameter. Room creation is lazy on Jitsi's first join,
so Create allocates an unpredictable name locally, not a fictitious REST API.

## HTTP and proxy trust boundary

* `GET /health`: unauthenticated `200 {"status":"ok"}`; process liveness only,
  not an upstream/Jitsi connectivity probe.
* `GET /ws`: WebSocket upgrade with exactly one `X-NRC-Calls-Auth` header.
  Invalid/missing assertions return 401; connection capacity returns 503.
* Other paths return 404; other methods return 405.

The trusted proxy must strip any incoming calls auth header, authenticate NRC
identity, authorize workspace access, validate browser Origin, then inject a
signed assertion. Keep this backend on the private network; never expose the
signing secret to clients. The backend deliberately accepts forwarded Origin
without origin matching, **but never without the signed assertion**.

The assertion is raw JWT (not `Bearer`), with header `alg=HS256, typ=JWT` and:

```json
{"iss":"nrc-tailscale-proxy","aud":"nrc-calls","username":"alice","sub":"alice","workspace":"team","nbf":1792367998,"exp":1792375200}
```

`username` must be the verified NRC username (1–255 UTF-8 bytes, no NUL/CR/LF).
`sub` must equal it, not the separate full Tailscale account ID.
Workspace is 1–128 ASCII letters/digits/underscore/hyphen. Times are required
integer Unix seconds; no future nbf, no expired exp, exp must exceed nbf. There
is no clock leeway. Socket closes at assertion expiry; the proxy issues a
two-hour assertion and the client reconnects on expiry (pending invitations end).
No identity from JSON, URL, or other
headers is trusted. No bot/admin bypass is used.

For start and acceptance the service dials NRC separately as **each user**, with
a workspace-scoped 30-second ordinary-user `X-NRC-Auth` assertion (same issuer
and secret, upstream audience). It sends correlated `C_ListDMs` and decodes
`S_DMList` via protocol-go. Both lists must contain the requested DM ID and
reciprocally name the other user. The DM flag is only a format check, never
membership evidence. Connections are closed after lookup. NRC must permit
these short-lived normal connections; they can briefly affect presence.

## WebSocket JSON contract

### Scheduled appointments and series

The calendar stores v2 appointment previews as durable NRC assets. The creator
is the organizer; only that user can change/delete the appointment or upgrade a
v1 record. Other workspace members can still read it. Participants may be added
or removed after creation for the series or a specific occurrence. The organizer
is always included; being an assignee alone does not authorize conference access.

The editor supports daily, weekly selected ISO weekdays, or monthly recurrence
in an IANA timezone, with an optional inclusive end date. Starts retain local
wall time across DST; nonexistent local times and missing monthly dates are
skipped, ambiguous times use the first instant. Duration is elapsed time.
An occurrence keeps its original start timestamp as identity after rescheduling.
Exceptions can cancel, move, change duration, or replace participants. Without
a participants override, later series participant changes apply. Changing a
series rule with exceptions requires explicitly resetting those exceptions.
Bounds: 64 additional participants, 32 exceptions, 4096 preview bytes, recurring
duration at most 24 hours. Overlapping occurrences of one series are rejected.
Calendar queries expand only the requested range, not the series' entire history.
The Odin runtime requires installed IANA tzdata (included in the server image).

Choose **NRC CONFERENCE**, **EXTERNAL URL**, or **NONE** in the editor.
**PREPARE CONFERENCE** obtains a fresh personal link; **JOIN CONFERENCE ↗**
opens it in a new tab. No automatic ringing or popup. Join admission runs from
15 minutes before start through 15 minutes after end; an absent end defaults to
one hour after start. Tickets last at most five minutes and may be prepared
again. Each series occurrence has its own provider room. Scheduled conferences
do not appear in the DM conference library and cannot use DM invitations to
bypass their appointment participant list.

```json
{"action":"appointment","appointment_id":"42","occurrence_at":"1793095200000000000","request_id":"1"}
{"type":"appointment","request_id":"1","join":{"url":"https://meet.example.org/nrc...?jwt=...","title":"Weekly review","expires_at":1793095500}}
{"type":"appointment","request_id":"1","message":"Conference unavailable: check participants, appointment time and provider"}
```

IDs are canonical decimal strings; `occurrence_at` is the original positive
nanosecond start (current start for a single appointment). Requests carry no
participant list or client-selected meeting. The service fetches the authoritative
asset, queries NRC's calendar for the occurrence, and rereads the asset to reject
mixed revisions. It checks again after provider provisioning. Removed people
cannot obtain new tickets; previously issued bearer links remain usable until
expiry, and NRC does not evict already connected endpoints.

Provider room identities are atomically written and synced before issuing links.
They survive calls-service restarts; personal tickets are always regenerated.
The directory must be private and on a durable local filesystem; never share it
between replicas. Room files are not automatically deleted: retain them alongside
NRC backups and perform any archival while the service is stopped. A provider
Create interrupted before durable save can leave an orphan external room; adapters
must expire their resources. A moved occurrence can allocate a fresh room once
its previous room's lifetime has expired. No external provider API is contacted
by tests; Jitsi media/policy needs separate deployment verification.

### Spontaneous DM invitations

Text commands only, at most 4096 bytes. Unknown fields, non-string IDs,
trailing JSON and unknown actions are rejected. Do not send a partner identity.

```json
{"action":"start","dm_id":"9223372036854775809","call_id":""}
{"action":"start","dm_id":"9223372036854775810","call_id":"","conference_id":"server-issued-conference-id"}
{"action":"accept","dm_id":"9223372036854775809","call_id":"server-issued-id"}
```

Actions: `start`, `accept`, `decline`, `cancel`. `dm_id` is a canonical
unsigned decimal string (no leading zeros). `start` ignores `call_id`; other
actions must match both identifiers. Callee must have a connected calls device.
One ringing/provisioning invitation reserves both users **per workspace**.
Acceptance releases both reservations immediately; a conference does not mark
either user busy in NRC. `start` without `conference_id` creates a new conference.
With it, the caller must be an accepted participant in that workspace, and the
meeting must be unexpired. The target DM is reauthorized at start and acceptance.
An additional invitation preserves the existing link; starting a fresh conference
or accepting a different one replaces it.

Server events:

```json
{"type":"ready","username":"alice","conferences":[]}
{"type":"state","call":{"id":"...","dm_id":"9223372036854775809","caller":"alice","callee":"bob","state":"ringing"}}
{"type":"state","call":{"id":"...","dm_id":"9223372036854775809","caller":"alice","callee":"bob","state":"accepted"},"join":{"url":"https://meet.example.org/nrc...?jwt=...","conference_id":"...","title":"alice · bob","expires_at":1792375200}}
{"type":"state","call":{"id":"...","dm_id":"9223372036854775809","caller":"alice","callee":"bob","state":"ended","reason":"cancel"}}
{"type":"error","message":"not authorized or unavailable"}
```

Every device receives `ready` first. All devices of both identities in that
workspace receive state. `ready.conferences` restores unexpired Join records only
for the authenticated participant in this workspace. This intentionally allows
another authenticated device of that same user to recover their own link.
Only the initiating caller socket and the one winning callee socket receive join
on acceptance; no credentials are issued while ringing. Accepts
are exclusive. Cancel/decline/disconnect/timeout during provisioning prevent
late results from resurrecting a call and clean up the created provider resource.
Cancel is caller-selected-device only while ringing; decline is any callee
device while ringing. An idle callee device disconnect does not end another
device's invitation. A selected device disconnect does; the last callee device
leaving during ringing also ends it. After acceptance the server retains no busy session;
disconnect, dismissal and new calls do not clean up the delivered conference.
Errors have no call details and do not distinguish outsiders' calls from missing
calls. End reasons are `cancel`, `decline`, `disconnect`, `timeout`,
or `unavailable` (membership/provider/operation failure).

## Bounds, extension and limitations

Fixed production bounds: 1024 sockets (including pending upgrades), 8 devices
per identity/workspace, 32 outbound events and one queued inbound command per
socket, 128 concurrent commands, 5-second membership/provisioning/write timeout,
1 MiB upstream message limit, 30-second ringing and one-hour provider token
lifetime (not a conference duration limit). Overflow closes a slow/abusive socket; command
concurrency exhaustion gives the same generic error. Maps/indexes/timers are
removed on termination; no retained call history. Conference references retain
the provider meeting, stable title, workspace and each participant's own Join record until
the original token expiry. At most 1024 references with 256 participants each are
retained; expired entries are pruned on the next start command. Adding invitees
does not extend expiry. No live attendance is inferred. State locking never encloses
provider calls or NRC I/O; completion checks the original session's identity.

`Provider` exposes `Create(ctx, expiry)` and
`Join(ctx, meeting, participant)`. Implementations must honor deadlines and the
requested absolute token expiry: `Meeting.Expires` passed to Join can be shorter
than the room lifetime supplied to Create. `EndProvider` is the optional cleanup extension,
called with a bounded context for failed/canceled **new** provisioning only, including late results.
Existing meetings are reused via `Join`; their failures never invoke `End`.
Successful conferences are provider-owned; adapters must arrange their own resource expiry.
Jitsi does not implement End: there is no per-room termination/revocation API
in this shared-secret integration.

The importable Go package is `github.com/heavyhorst/nrc/services/calls`.
An adapter implements `calls.Provider`; a custom service entry point passes it to
`calls.NewServer`, as `cmd/nrc-calls` does for Jitsi. No dynamic Go plugin loader
is needed. `Meeting.Room` is the adapter's opaque external conference ID.
`Join.URL` is an absolute participant-specific HTTPS URL without URL userinfo.
No browser adapter or vendor SDK is needed. The client offers it as a normal link
with `noopener`, `noreferrer` and no referrer policy. It never opens a popup on
acceptance. Dismissal hides the panel; starting a fresh conference changes selection
without deleting previous entries. Workspace change clears all local links; authenticated
reconnection restores only the matching workspace and participant's unexpired entries.
`accepted` completes the invitation, not verified attendance at the provider.

Membership is checked again on acceptance, but two NRC snapshots are not a
transaction. Membership changes **during established media sessions cannot
immediately revoke issued provider tokens**. Token expiry bounds admission;
it does not guarantee Jitsi will evict an already connected endpoint. Likewise,
signaling restart cannot close or observe an external provider session.
Provider tokens are bearer credentials, not cryptographically bound to sockets;
URLs may expose them in browser history and provider access logs; protect/redact
those records and do not share the links. This is not a provider-side maximum-two-person
enforcement mechanism. Deploy and verify Jitsi policy independently.

Service tests use real HTTP/WebSocket test servers, a fake provider for controlled
races, and an NRC wire-format fixture. Proxy tests exercise authenticated upgrades;
`client/calls.e2e.mjs` exercises browser call states with controlled signaling and
external-page fixtures. They do not claim a real Jitsi audio/video connection.
